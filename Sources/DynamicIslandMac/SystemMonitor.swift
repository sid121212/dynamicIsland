import AppKit
import CoreAudio
import CoreLocation
import EventKit
import Foundation
import IOKit.ps

enum ActivityKind {
    case volume, brightness, charging, battery, notification, timer
}

struct IslandActivity {
    let kind: ActivityKind
    let title: String
    let subtitle: String
    let progress: Double?
    let expiresAt: Date
}

struct NowPlayingState {
    var title = "Nothing playing"
    var artist = "Start Music or Spotify"
    var duration: Double = 0
    var position: Double = 0
    var isPlaying = false
    var source = ""

    var isAvailable: Bool { title != "Nothing playing" }
}

struct WeatherState {
    let temperature: Int
    let symbol: String
    let description: String
}

final class SystemMonitor: NSObject, CLLocationManagerDelegate {
    var onChange: (() -> Void)?
    var onActivity: ((IslandActivity) -> Void)?

    private(set) var batteryPercent: Int?
    private(set) var isCharging = false
    private(set) var volume: Double?
    private(set) var brightness: Double?
    private(set) var nowPlaying = NowPlayingState()
    private(set) var nextEvent: EKEvent?
    private(set) var weather: WeatherState?

    var musicEnabled: Bool {
        get { defaults.object(forKey: "musicEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "musicEnabled"); onChange?() }
    }
    var hudsEnabled: Bool {
        get { defaults.object(forKey: "hudsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hudsEnabled"); onChange?() }
    }
    var powerEventsEnabled: Bool {
        get { defaults.object(forKey: "powerEventsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "powerEventsEnabled"); onChange?() }
    }
    var calendarEnabled: Bool {
        get { defaults.bool(forKey: "calendarEnabled") }
        set { defaults.set(newValue, forKey: "calendarEnabled"); refreshCalendar(); onChange?() }
    }
    var weatherEnabled: Bool {
        get { defaults.bool(forKey: "weatherEnabled") }
        set {
            defaults.set(newValue, forKey: "weatherEnabled")
            if newValue { requestWeatherAccess() } else { weather = nil; locationManager.stopUpdatingLocation() }
            onChange?()
        }
    }

    private let defaults = UserDefaults.standard
    private let eventStore = EKEventStore()
    private let locationManager = CLLocationManager()
    private var pollTimer: Timer?
    private var mediaPollInFlight = false
    private var calendarPollCounter = 0
    private var previousVolume: Double?
    private var previousBrightness: Double?
    private var previousCharging: Bool?
    private var displayServicesHandle: UnsafeMutableRawPointer?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        refreshAll(emitEvents: false)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshAll(emitEvents: true)
        }
    }

    deinit {
        if let displayServicesHandle { dlclose(displayServicesHandle) }
    }

    func post(title: String, subtitle: String, duration: TimeInterval = 5) {
        onActivity?(IslandActivity(kind: .notification, title: title, subtitle: subtitle, progress: nil, expiresAt: Date().addingTimeInterval(duration)))
    }

    func requestCalendarAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.calendarEnabled = granted
                    self?.refreshCalendar()
                }
            }
        }
    }

    func requestWeatherAccess() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func mediaCommand(_ command: String) {
        guard nowPlaying.isAvailable else { return }
        let app = nowPlaying.source == "Spotify" ? "Spotify" : "Music"
        let verb: String
        switch command {
        case "previous": verb = "previous track"
        case "next": verb = "next track"
        default: verb = "playpause"
        }
        let script = "tell application \"\(app)\" to \(verb)"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            weather = nil
            onChange?()
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        manager.stopUpdatingLocation()
        fetchWeather(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        weather = nil
        onChange?()
    }

    private func refreshAll(emitEvents: Bool) {
        refreshPower(emitEvents: emitEvents)
        refreshAudio(emitEvents: emitEvents)
        refreshBrightness(emitEvents: emitEvents)
        refreshMedia()
        calendarPollCounter += 1
        if calendarPollCounter >= 30 {
            calendarPollCounter = 0
            refreshCalendar()
        }
        onChange?()
    }

    private func refreshPower(emitEvents: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

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

    private func refreshAudio(emitEvents: Bool) {
        guard let level = outputVolume() else { return }
        volume = level
        if emitEvents, hudsEnabled, let previousVolume, abs(previousVolume - level) > 0.005 {
            onActivity?(IslandActivity(
                kind: .volume,
                title: level == 0 ? "Muted" : "Volume",
                subtitle: "\(Int((level * 100).rounded()))%",
                progress: level,
                expiresAt: Date().addingTimeInterval(1.8)
            ))
        }
        previousVolume = level
    }

    private func outputVolume() -> Double? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }

        var scalar: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) != noErr {
            address.mElement = 1
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr else { return nil }
        }
        return Double(scalar)
    }

    private func refreshBrightness(emitEvents: Bool) {
        guard let level = displayBrightness() else { return }
        brightness = level
        if emitEvents, hudsEnabled, let previousBrightness, abs(previousBrightness - level) > 0.005 {
            onActivity?(IslandActivity(
                kind: .brightness,
                title: "Brightness",
                subtitle: "\(Int((level * 100).rounded()))%",
                progress: level,
                expiresAt: Date().addingTimeInterval(1.8)
            ))
        }
        previousBrightness = level
    }

    private func displayBrightness() -> Double? {
        typealias BrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        if displayServicesHandle == nil {
            displayServicesHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        }
        guard let handle = displayServicesHandle,
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        let function = unsafeBitCast(symbol, to: BrightnessFunction.self)
        var value: Float = 0
        guard function(CGMainDisplayID(), &value) == 0 else { return nil }
        return Double(value)
    }

    private func refreshMedia() {
        guard musicEnabled, !mediaPollInFlight else {
            if !musicEnabled { nowPlaying = NowPlayingState() }
            return
        }
        let running = NSWorkspace.shared.runningApplications
        let source: String?
        if running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            source = "Spotify"
        } else if running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            source = "Music"
        } else {
            nowPlaying = NowPlayingState()
            return
        }
        guard let source else { return }
        mediaPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let script: String
            if source == "Spotify" {
                script = "tell application \"Spotify\" to if player state is not stopped then return (name of current track) & \"|||\" & (artist of current track) & \"|||\" & ((duration of current track) / 1000) & \"|||\" & player position & \"|||\" & (player state is playing)"
            } else {
                script = "tell application \"Music\" to if player state is not stopped then return (name of current track) & \"|||\" & (artist of current track) & \"|||\" & (duration of current track) & \"|||\" & player position & \"|||\" & (player state is playing)"
            }
            var error: NSDictionary?
            let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue ?? ""
            let parts = output.components(separatedBy: "|||")
            DispatchQueue.main.async {
                guard let self else { return }
                self.mediaPollInFlight = false
                if parts.count >= 5 {
                    self.nowPlaying = NowPlayingState(
                        title: parts[0], artist: parts[1],
                        duration: Double(parts[2]) ?? 0,
                        position: Double(parts[3]) ?? 0,
                        isPlaying: parts[4].lowercased() == "true",
                        source: source
                    )
                } else {
                    self.nowPlaying = NowPlayingState()
                }
                self.onChange?()
            }
        }
    }

    private func refreshCalendar() {
        guard calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            nextEvent = nil
            return
        }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        nextEvent = eventStore.events(matching: predicate).first(where: { !$0.isAllDay || $0.endDate > start })
    }

    private func fetchWeather(latitude: Double, longitude: Double) {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&temperature_unit=celsius"
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = root["current"] as? [String: Any],
                  let temperature = current["temperature_2m"] as? Double,
                  let code = current["weather_code"] as? Int else { return }
            let condition = Self.weatherCondition(code)
            DispatchQueue.main.async {
                self?.weather = WeatherState(temperature: Int(temperature.rounded()), symbol: condition.0, description: condition.1)
                self?.onChange?()
            }
        }.resume()
    }

    private static func weatherCondition(_ code: Int) -> (String, String) {
        switch code {
        case 0: return ("☀︎", "Clear")
        case 1...3: return ("☁︎", "Cloudy")
        case 45...48: return ("≋", "Fog")
        case 51...67, 80...82: return ("☂︎", "Rain")
        case 71...77, 85...86: return ("❄︎", "Snow")
        case 95...99: return ("ϟ", "Storm")
        default: return ("•", "Weather")
        }
    }
}
