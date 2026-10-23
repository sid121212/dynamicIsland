import AppKit
import Observation

@MainActor @Observable final class BrightnessService: LevelControl {
    private(set) var level: Double = 0
    var isMuted: Bool { false }
    private(set) var isSupported = false
    private(set) var name = "Display"
    private(set) var enabled = false
    var onChange: ((_ levelChanged: Bool) -> Void)?
    private var display = CGMainDisplayID()
    private var handle: UnsafeMutableRawPointer?
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var getBrightness: Get?
    private var setBrightness: Set?
    private var timer: Timer?
    private var visible = false
    var isPolling: Bool { timer != nil }

    func start() {
        guard !enabled else { return }; enabled = true
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let handle, let get = dlsym(handle, "DisplayServicesGetBrightness"), let set = dlsym(handle, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(get, to: Get.self); setBrightness = unsafeBitCast(set, to: Set.self)
        }
        refresh(emit: false); configurePolling()
    }
    func stop() {
        enabled = false; timer?.invalidate(); timer = nil; isSupported = false
        getBrightness = nil; setBrightness = nil
        if let handle { dlclose(handle) }; handle = nil
        DiagnosticsModel.shared.update(.brightness, .degraded, "Brightness disabled; DisplayServices unloaded and polling stopped")
    }
    func configure(screen: NSScreen) {
        let next = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let changed = display != next || name != screen.localizedName
        name = screen.localizedName
        guard changed else { return }; display = next
        if enabled { refresh(emit: false); configurePolling() }
    }
    func setVisible(_ value: Bool) { guard value != visible else { return }; visible = value; configurePolling() }
    private func configurePolling() {
        timer?.invalidate(); timer = nil
        guard enabled, visible, isSupported else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.015; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func refresh(emit: Bool = true) {
        guard enabled else { return }
        let previous = level
        var value: Float = 0
        let builtIn = CGDisplayIsBuiltin(display) != 0
        let result = builtIn ? getBrightness?(display, &value) : nil
        guard builtIn, getBrightness != nil, setBrightness != nil, result == 0 else {
            isSupported = false
            let reason = !builtIn ? "external display" : (getBrightness == nil || setBrightness == nil ? "DisplayServices symbols unavailable" : "read failed \(result.map(String.init) ?? "unknown")")
            DiagnosticsModel.shared.update(.brightness, .degraded, "\(name) · Not available on this display · \(reason)")
            timer?.invalidate(); timer = nil; onChange?(false); return
        }
        isSupported = true; level = max(0, min(1, Double(value)))
        DiagnosticsModel.shared.update(.brightness, .ok, "DisplayServices loaded · \(name) · \(Int(level * 100))% · \(isPolling ? "visible polling" : "idle polling off")", event: abs(previous - level) > 0.001)
        if abs(previous - level) > 0.001 { onChange?(emit) }
    }
    func set(_ value: Double) { _ = apply(value) }
    @discardableResult func apply(_ value: Double) -> Bool {
        guard enabled, isSupported, value.isFinite, let setBrightness else { return false }
        let result = setBrightness(display, Float(max(0, min(1, value))))
        guard result == 0 else { DiagnosticsModel.shared.update(.brightness, .failed, "Brightness write failed: \(result)", event: true); return false }
        refresh(); return true
    }
}
