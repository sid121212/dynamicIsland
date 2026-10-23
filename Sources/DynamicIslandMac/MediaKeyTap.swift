import AppKit
import ApplicationServices
import Observation

struct MediaKey {
    let code: Int
    let down: Bool
    static func decode(subtype: Int, data: Int) -> MediaKey? {
        guard subtype == 8 else { return nil }
        let code = (data >> 16) & 0xFFFF
        guard [0, 1, 2, 3, 7].contains(code) else { return nil }
        let state = (data >> 8) & 0xFF
        guard state == 0xA || state == 0xB else { return nil }
        return MediaKey(code: code, down: state == 0xA)
    }
    static func step(fine: Bool) -> Double { fine ? 1.0 / 64 : 1.0 / 16 }
}

struct MediaKeyPolicy {
    private var swallowed = Set<Int>()
    mutating func consume(_ key: MediaKey, fine: Bool, apply: (Int, Double) -> Bool) -> Bool {
        if !key.down { return swallowed.remove(key.code) != nil }
        if key.code == 7 && swallowed.contains(7) { return true }
        guard apply(key.code, MediaKey.step(fine: fine)) else { return false }
        swallowed.insert(key.code); return true
    }
}

@MainActor @Observable final class MediaKeyTap {
    private(set) var enabled = false
    private(set) var active = false
    var onApplied: ((ActivityKind, Double) -> Void)?
    var onObservedBrightnessKey: (() -> Void)?
    private let volume: VolumeService
    private let brightness: BrightnessService
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?
    private var permissionState: Bool?
    private var policy = MediaKeyPolicy()

    init(volume: VolumeService, brightness: BrightnessService) { self.volume = volume; self.brightness = brightness }
    func start() {
        guard !enabled else { return }; enabled = true
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        refreshPermissions()
    }
    func stop() {
        enabled = false; removeTap(); permissionState = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        DiagnosticsModel.shared.update(.mediaKeys, .degraded, "Media-key HUDs disabled; event tap removed")
    }
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil; active = false; policy = MediaKeyPolicy()
    }
    func refreshPermissions() {
        guard enabled else { return }
        let canIntercept = AXIsProcessTrusted() && CGPreflightListenEventAccess()
        guard permissionState != canIntercept else { return }
        permissionState = canIntercept; removeTap()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: canIntercept ? .defaultTap : .listenOnly,
                                eventsOfInterest: CGEventMask(1) << 14, callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            permissionState = nil
            DiagnosticsModel.shared.update(.mediaKeys, .degraded, canIntercept ? "Event tap unavailable; native HUD may also appear" : "Permissions missing; CoreAudio observe-only · native HUD may also appear")
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        active = canIntercept
        DiagnosticsModel.shared.update(.mediaKeys, active ? .ok : .degraded, active ? "Active media-key tap · supported writes suppress native HUD" : "Observe-only media keys · native HUD may also appear", event: true)
    }
    nonisolated private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        return MainActor.assumeIsolated {
            Unmanaged<MediaKeyTap>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event)
        }
    }
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard enabled else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DiagnosticsModel.shared.update(.mediaKeys, active ? .ok : .degraded, "Media-key tap re-enabled after system timeout", event: true)
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let cocoa = NSEvent(cgEvent: event),
              let key = MediaKey.decode(subtype: Int(cocoa.subtype.rawValue), data: cocoa.data1) else { return Unmanaged.passUnretained(event) }
        if active && (!AXIsProcessTrusted() || !CGPreflightListenEventAccess()) {
            refreshPermissions(); return Unmanaged.passUnretained(event)
        }
        guard active else {
            if key.down && [2, 3].contains(key.code) { onObservedBrightnessKey?() }
            return Unmanaged.passUnretained(event)
        }
        let fine = cocoa.modifierFlags.contains([.shift, .option])
        var nextPolicy = policy
        let consumed = nextPolicy.consume(key, fine: fine) { code, step in
            let applied: Bool
            switch code {
            case 0, 1:
                applied = volume.apply(volume.level + (code == 0 ? step : -step))
                if applied { onApplied?(.volume, volume.isMuted ? 0 : volume.level) }
            case 7:
                applied = volume.toggleMute()
                if applied { onApplied?(.volume, volume.isMuted ? 0 : volume.level) }
            case 2, 3:
                // Idle brightness is intentionally not polled; sample before relative keys.
                brightness.refresh(emit: false)
                applied = brightness.apply(brightness.level + (code == 2 ? step : -step))
                if applied { onApplied?(.brightness, brightness.level) }
            default: applied = false
            }
            return applied
        }
        policy = nextPolicy
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
}
