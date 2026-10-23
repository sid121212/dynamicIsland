import AppKit
import CoreAudio
import CoreLocation
import EventKit
import Foundation
import IOKit.ps

enum ActivityKind {
    case volume, brightness, charging, battery, notification, timer, screenshot
}

struct IslandActivity {
    let kind: ActivityKind
    let title: String
    let subtitle: String
    let progress: Double?
    let expiresAt: Date
    var trayItem: TrayItem? = nil
}

@MainActor final class SystemMonitor: NSObject {
    var onChange: (() -> Void)?
    var onActivity: ((IslandActivity) -> Void)?

    private(set) var batteryPercent: Int?
    private(set) var isCharging = false
    let volumeControl = VolumeService()
    let brightnessControl = BrightnessService()
    private lazy var mediaKeys = MediaKeyTap(volume: volumeControl, brightness: brightnessControl)
    var volume: Double? { volumeControl.isSupported ? volumeControl.level : nil }
    var brightness: Double? { brightnessControl.isSupported ? brightnessControl.level : nil }
    private var islandExpanded = false
    private var levelActivityWork: DispatchWorkItem?
    private var observedBrightnessWork: DispatchWorkItem?
    private let media = NowPlayingService()
    var nowPlaying: NowPlayingState { media.state }
    func setMediaVisible(_ visible: Bool) { if !previewMode { media.setVisible(visible) } }
    func seekMedia(to seconds: Double) { media.seek(to: seconds) }
    func stopServices() {
        media.stop()
        mediaKeys.stop(); volumeControl.stop(); brightnessControl.stop()
        levelActivityWork?.cancel(); observedBrightnessWork?.cancel()
        pollTimer?.invalidate(); pollTimer = nil
        calendarService.stop(); weatherService.stop()
        clipboard.stop(); screenshotWatcher.stop(); trayStore.stop()
    }
    private let calendarService = CalendarService()
    private let weatherService = WeatherService()
    var calendarAccess: CalendarAccess { calendarService.access }
    var todayEvents: [EKEvent] { calendarService.events }
    var nextEvent: EKEvent? { todayEvents.first { $0.endDate > Date() } }
    var weatherCity: String { weatherService.manualCity }
    func setWeatherCity(_ city: String) { weatherService.setCity(city) }
    func refreshWeather() { weatherService.refresh(force: true) }
    func openCalendar() { calendarService.open() }
    func syncCalendarAuthorization() {
        if CalendarAccess.current() != calendarService.access { calendarService.refresh() }
    }
    var artwork: NSImage? { media.state.artwork }
    var weather: WeatherState? { weatherService.state }
    let trayStore = TrayStore()
    lazy var clipboard = ClipboardMonitor(store: trayStore)
    private lazy var screenshotWatcher = ScreenshotWatcher(store: trayStore)
    private var trayVisible = false
    func setTrayVisible(_ visible: Bool) {
        guard visible != trayVisible else { return }; trayVisible = visible
        if visible && !previewMode { trayStore.ensureLoaded() }
    }
    func restartScreenshots() { screenshotsEnabled = true; if !previewMode { screenshotWatcher.restart() } }
    func startTrayServices() { configureTrayServices() }
    private func configureTrayServices() {
        guard !previewMode else { return }
        if clipboardEnabled || screenshotsEnabled { trayStore.start() } else { trayStore.stop() }
        if clipboardEnabled { clipboard.start() } else { clipboard.stop() }
        if screenshotsEnabled { screenshotWatcher.start() } else { screenshotWatcher.stop() }
    }
    var screenshotsEnabled: Bool {
        get { defaults.bool(forKey: "screenshotsEnabled") }
        set { defaults.set(newValue, forKey: "screenshotsEnabled"); configureTrayServices(); onChange?() }
    }

    var musicEnabled: Bool {
        get { defaults.object(forKey: "musicEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "musicEnabled")
            if newValue { media.start() } else { media.stop() }
            reconfigurePolling()
            onChange?()
        }
    }
    var hudsEnabled: Bool {
        get { defaults.object(forKey: "hudsEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "hudsEnabled")
            configureLevelServices()
            onChange?()
        }
    }
    var controlsEnabled: Bool {
        get { defaults.object(forKey: "controlsEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "controlsEnabled")
            configureLevelServices(); onChange?()
        }
    }
    func configureDisplay(_ screen: NSScreen) { if !previewMode { brightnessControl.configure(screen: screen) } }
    func setIslandState(expanded: Bool, controlsVisible: Bool, hudVisible: Bool) {
        islandExpanded = expanded
        if expanded { levelActivityWork?.cancel(); levelActivityWork = nil }
        if !previewMode { brightnessControl.setVisible(controlsVisible || hudVisible) }
    }
    func refreshMediaKeyPermissions() { if !previewMode { mediaKeys.refreshPermissions() } }
    private func configureLevelServices() {
        guard !previewMode else { return }
        if hudsEnabled || controlsEnabled { volumeControl.start(); brightnessControl.start() }
        else { volumeControl.stop(); brightnessControl.stop() }
        if hudsEnabled { mediaKeys.start() }
        else {
            mediaKeys.stop(); levelActivityWork?.cancel(); observedBrightnessWork?.cancel()
            levelActivityWork = nil; observedBrightnessWork = nil
        }
    }
    private func emitLevelActivity(_ kind: ActivityKind, level: Double) {
        guard hudsEnabled, !islandExpanded else { return }
        levelActivityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hudsEnabled, !self.islandExpanded else { return }
            self.levelActivityWork = nil
            self.onActivity?(IslandActivity(kind: kind, title: kind == .volume ? "Volume" : "Brightness", subtitle: "", progress: level, expiresAt: Date().addingTimeInterval(1.6)))
        }
        levelActivityWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30, execute: work)
    }
    var powerEventsEnabled: Bool {
        get { defaults.object(forKey: "powerEventsEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "powerEventsEnabled")
            if !newValue {
                batteryPercent = nil
                isCharging = false
                previousCharging = nil
            }
            reconfigurePolling()
            onChange?()
        }
    }
    var calendarEnabled: Bool {
        get { defaults.bool(forKey: "calendarEnabled") }
        set {
            defaults.set(newValue, forKey: "calendarEnabled")
            if newValue { calendarService.start() } else { calendarService.stop() }
            reconfigurePolling()
            onChange?()
        }
    }
    var weatherEnabled: Bool {
        get { defaults.bool(forKey: "weatherEnabled") }
        set {
            defaults.set(newValue, forKey: "weatherEnabled")
            if newValue { weatherService.start() } else { weatherService.stop() }
            onChange?()
        }
    }
    var clipboardEnabled: Bool {
        get { defaults.bool(forKey: "clipboardEnabled") }
        set {
            defaults.set(newValue, forKey: "clipboardEnabled")
            configureTrayServices()
            onChange?()
        }
    }

    private let defaults = UserDefaults.standard
    private var pollTimer: Timer?
    private var previousCharging: Bool?
    private let previewMode: Bool

    override convenience init() { self.init(preview: false) }

    init(preview: Bool) {
        previewMode = preview
        super.init()
        if preview { return }
        trayStore.onChange = { [weak self] in self?.onChange?() }
        clipboard.onChange = { [weak self] in self?.onChange?() }
        screenshotWatcher.onSaved = { [weak self] item in
            self?.onActivity?(IslandActivity(kind: .screenshot, title: "Screenshot saved", subtitle: "Saved", progress: nil, expiresAt: Date().addingTimeInterval(2.5), trayItem: item))
        }
        volumeControl.onChange = { [weak self] changed in
            guard let self else { return }
            if changed { self.emitLevelActivity(.volume, level: self.volumeControl.isMuted ? 0 : self.volumeControl.level) }
            self.onChange?()
        }
        brightnessControl.onChange = { [weak self] changed in
            guard let self else { return }
            if changed { self.emitLevelActivity(.brightness, level: self.brightnessControl.level) }
            self.onChange?()
        }
        mediaKeys.onApplied = { [weak self] kind, level in self?.emitLevelActivity(kind, level: level) }
        mediaKeys.onObservedBrightnessKey = { [weak self] in
            guard let self else { return }
            self.observedBrightnessWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.observedBrightnessWork = nil; self?.brightnessControl.refresh() }
            self.observedBrightnessWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
        configureLevelServices()
        calendarService.onChange = { [weak self] in self?.onChange?() }
        weatherService.onChange = { [weak self] in self?.onChange?() }
        if calendarEnabled { calendarService.start() }
        if weatherEnabled { weatherService.start() }
        media.onChange = { [weak self] in self?.onChange?() }
        if musicEnabled { media.start() }
        refreshAll(emitEvents: false)
        reconfigurePolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    func post(title: String, subtitle: String, duration: TimeInterval = 5) {
        onActivity?(IslandActivity(kind: .notification, title: title, subtitle: subtitle, progress: nil, expiresAt: Date().addingTimeInterval(duration)))
    }

    func requestCalendarAccess() {
        calendarEnabled = true
        calendarService.requestAccess()
    }

    func requestWeatherAccess() {
        weatherEnabled = true
        weatherService.requestLocationAccess()
    }

    func mediaCommand(_ command: String) {
        switch command {
        case "previous": media.previous()
        case "next": media.next()
        case "shuffle": media.shuffle()
        default: media.togglePlayPause()
        }
    }

    private func refreshAll(emitEvents: Bool) {
        if powerEventsEnabled { refreshPower(emitEvents: emitEvents) }
        onChange?()
    }

    private func reconfigurePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard powerEventsEnabled else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll(emitEvents: true) }
        }
    }

    private func refreshPower(emitEvents: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        DiagnosticsModel.shared.update(.battery, .degraded, "Power read succeeded; polling only, notifications not registered", event: emitEvents)

        var percent: Int?
        var charging = false
        for source in sources {
            guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let current = data[kIOPSCurrentCapacityKey] as? Int,
               let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                percent = Int((Double(current) / Double(maximum) * 100).rounded())
            }
            charging = (data[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue || (data[kIOPSIsChargingKey] as? Bool) == true
        }
        batteryPercent = percent
        isCharging = charging

        if emitEvents, powerEventsEnabled, let previousCharging, previousCharging != charging {
            onActivity?(IslandActivity(
                kind: .charging,
                title: charging ? "Power connected" : "Running on battery",
                subtitle: percent.map { "Battery \($0)%" } ?? "Power status changed",
                progress: percent.map { Double($0) / 100 },
                expiresAt: Date().addingTimeInterval(4)
            ))
        }
        self.previousCharging = charging
    }

}
