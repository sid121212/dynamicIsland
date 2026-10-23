import AppKit
import CoreAudio
import Observation

@MainActor protocol LevelControl: AnyObject {
    var level: Double { get }
    var isMuted: Bool { get }
    var isSupported: Bool { get }
    func set(_ value: Double)
}

@MainActor @Observable final class VolumeService: LevelControl {
    private(set) var level: Double = 0
    private(set) var isMuted = false
    private(set) var isSupported = false
    private(set) var name = "No output device"
    private(set) var enabled = false
    var onChange: ((_ levelChanged: Bool) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private let virtualVolume: AudioObjectPropertySelector = 0x766d7663 // 'vmvc', AudioHardwareService.h
    private struct Binding {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var bindings: [Binding] = []

    func start() { guard !enabled else { return }; enabled = true; bindDevice() }
    func stop() {
        enabled = false; removeListeners(); isSupported = false
        DiagnosticsModel.shared.update(.volume, .degraded, "Volume disabled; CoreAudio listeners removed")
    }
    private func removeListeners() {
        for var binding in bindings { AudioObjectRemovePropertyListenerBlock(binding.object, &binding.address, .main, binding.block) }
        bindings = []
    }
    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, deviceChanged: Bool = false) {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                if deviceChanged { self.bindDevice() } else { self.refresh() }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        if status == noErr { bindings.append(Binding(object: object, address: address, block: block)) }
        else { DiagnosticsModel.shared.update(.volume, .degraded, "CoreAudio listener registration failed: \(status)") }
    }
    private func bindDevice() {
        guard enabled else { return }
        removeListeners()
        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &output, 0, nil, &size, &device)
        listen(AudioObjectID(kAudioObjectSystemObject), output, deviceChanged: true)
        guard status == noErr, device != kAudioObjectUnknown else {
            isSupported = false; name = "No output device"
            DiagnosticsModel.shared.update(.volume, .failed, "Cannot resolve default output: \(status)", event: true)
            onChange?(false); return
        }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceName: Unmanaged<CFString>?; size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &deviceName) == noErr, let deviceName { name = deviceName.takeRetainedValue() as String }
        else { name = "Default output" }
        listen(device, address(virtualVolume)); listen(device, address(kAudioDevicePropertyMute))
        refresh(emit: false)
    }
    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private func writable(_ selector: AudioObjectPropertySelector) -> Bool {
        var property = address(selector), writable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &property) && AudioObjectIsPropertySettable(device, &property, &writable) == noErr && writable.boolValue
    }
    func refresh(emit: Bool = true) {
        guard enabled else { return }
        let previous = level, previousMute = isMuted
        var property = address(virtualVolume), scalar: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let result = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &scalar)
        isSupported = result == noErr && writable(virtualVolume)
        if result == noErr { level = max(0, min(1, Double(scalar))) }
        var muted: UInt32 = 0; property = address(kAudioDevicePropertyMute); size = UInt32(MemoryLayout<UInt32>.size)
        isMuted = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &muted) == noErr && muted != 0
        let listening = bindings.contains { $0.object == device && $0.address.mSelector == virtualVolume }
        DiagnosticsModel.shared.update(.volume, isSupported && listening ? .ok : .degraded, isSupported ? "\(name) · vmvc \(Int(level * 100))% · \(isMuted ? "muted" : "unmuted") · \(listening ? "listeners active" : "listener unavailable")" : "\(name) · no writable volume (HDMI/DisplayPort may be fixed)", event: previous != level || previousMute != isMuted)
        onChange?(emit && (abs(previous - level) > 0.001 || previousMute != isMuted))
    }
    func set(_ value: Double) { _ = apply(value) }
    @discardableResult func apply(_ value: Double) -> Bool {
        guard enabled, isSupported, value.isFinite else { return false }
        var scalar = Float32(max(0, min(1, value))), property = address(virtualVolume)
        if isMuted && scalar > 0, !writeMute(false) { return false }
        let result = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
        guard result == noErr else { DiagnosticsModel.shared.update(.volume, .failed, "Volume write failed: \(result)", event: true); return false }
        refresh(); return true
    }
    @discardableResult func toggleMute() -> Bool {
        guard enabled, isSupported, writeMute(!isMuted) else { return false }
        refresh(); return true
    }
    private func writeMute(_ muted: Bool) -> Bool {
        guard writable(kAudioDevicePropertyMute) else { return false }
        var value: UInt32 = muted ? 1 : 0, property = address(kAudioDevicePropertyMute)
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
