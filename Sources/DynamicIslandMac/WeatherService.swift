import AppKit
import CoreLocation
import Network
import Observation

struct WeatherState: Codable, Equatable {
    let temperature: Int
    let high: Int
    let low: Int
    let code: Int
    let isDay: Bool
    let city: String
    let latitude: Double
    let longitude: Double
    let fahrenheit: Bool
    let fetchedAt: Date
    let selection: String

    var systemSymbol: String { Self.symbol(code: code, isDay: isDay) }
    static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "snowflake"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func decode(_ data: Data, city: String, latitude: Double, longitude: Double, fahrenheit: Bool, selection: String) throws -> WeatherState {
        struct Forecast: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current; let daily: Daily
        }
        let forecast = try JSONDecoder().decode(Forecast.self, from: data)
        guard let high = forecast.daily.temperature_2m_max.first, let low = forecast.daily.temperature_2m_min.first,
              forecast.current.temperature_2m.isFinite, high.isFinite, low.isFinite else {
            throw WeatherFailure.message("Incomplete daily forecast")
        }
        return WeatherState(temperature: Int(forecast.current.temperature_2m.rounded()), high: Int(high.rounded()), low: Int(low.rounded()), code: forecast.current.weather_code, isDay: forecast.current.is_day == 1, city: city, latitude: latitude, longitude: longitude, fahrenheit: fahrenheit, fetchedAt: Date(), selection: selection)
    }
}

enum WeatherFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

@MainActor @Observable final class WeatherService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var state: WeatherState?
    private(set) var enabled = false
    var onChange: (() -> Void)?
    var manualCity: String { defaults.string(forKey: "weatherManualCity") ?? "" }
    private let defaults: UserDefaults
    private let location = CLLocationManager()
    private var task: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var locationDeadline: Timer?
    private var waitingForLocation = false
    private var network: NWPathMonitor?
    private var online: Bool?
    private var generation = 0
    private let cacheKey = "weatherCacheV2"
    private var useFahrenheit: Bool { Locale.current.measurementSystem == .us }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        location.delegate = self; location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func start() {
        guard !enabled else { return }
        enabled = true; online = nil
        let monitor = NWPathMonitor(); network = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.enabled, self.network === monitor else { return }
                let previous = self.online; self.online = connected
                if !connected {
                    self.cancelRequest(); self.state = nil
                    DiagnosticsModel.shared.update(.weather, .degraded, "Offline — weather chip hidden", event: previous != false)
                    self.onChange?()
                } else if previous != true { self.refresh() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "DynamicIsland.weather.network", qos: .utility))
        let timer = Timer(timeInterval: 900, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh(force: true) } }
        timer.tolerance = 30; refreshTimer = timer; RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func stop() {
        enabled = false; cancelRequest()
        refreshTimer?.invalidate(); refreshTimer = nil
        network?.cancel(); network = nil; online = nil; state = nil
        DiagnosticsModel.shared.update(.weather, .degraded, "Weather disabled; location, requests and monitors stopped")
        onChange?()
    }

    private func cancelRequest() {
        generation += 1; task?.cancel(); task = nil
        location.stopUpdatingLocation(); waitingForLocation = false
        locationDeadline?.invalidate(); locationDeadline = nil
    }

    func setCity(_ city: String) {
        defaults.set(city.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "weatherManualCity")
        cancelRequest(); state = nil
        if enabled { refresh(force: true) }
        onChange?()
    }

    func requestLocationAccess() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if [.denied, .restricted].contains(location.authorizationStatus) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
        } else { location.requestWhenInUseAuthorization() }
    }

    func refresh(force: Bool = false) {
        guard enabled, online != false, task == nil, !waitingForLocation else { return }
        if !force, let data = defaults.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(WeatherState.self, from: data),
           cached.selection == manualCity, cached.fahrenheit == useFahrenheit,
           (0..<900).contains(Date().timeIntervalSince(cached.fetchedAt)) {
            state = cached
            DiagnosticsModel.shared.update(.weather, .ok, "Open-Meteo cached HTTP 200 · \(cached.city) · age \(Int(Date().timeIntervalSince(cached.fetchedAt))) s")
            onChange?(); return
        }
        if manualCity.isEmpty, [.authorized, .authorizedAlways].contains(location.authorizationStatus) {
            if let last = location.location, last.horizontalAccuracy >= 0, abs(last.timestamp.timeIntervalSinceNow) < 3600 {
                fetch(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude, city: "Current location"); return
            }
            waitingForLocation = true; location.requestLocation()
            let deadline = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.enabled, self.waitingForLocation else { return }
                    self.waitingForLocation = false; self.location.stopUpdatingLocation(); self.locationDeadline = nil
                    self.resolveFallback()
                }
            }
            locationDeadline = deadline; RunLoop.main.add(deadline, forMode: .common)
        } else { resolveFallback() }
    }

    private func resolveFallback() {
        guard enabled, task == nil, online != false else { return }
        let token = generation, city = manualCity
        DiagnosticsModel.shared.update(.weather, .degraded, city.isEmpty ? "Choose a city in Weather Settings" : "Looking up manual city")
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.enabled, self.generation == token else { return }
            defer { if self.generation == token { self.task = nil } }
            do {
                var latitude: Double; var longitude: Double; var resolvedCity: String
                if !city.isEmpty {
                    var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                    url.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"), URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en")]
                    let data = try await Self.get(url.url!, label: "City lookup")
                    struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double }
                    struct Response: Decodable { let results: [Result]? }
                    guard let found = try JSONDecoder().decode(Response.self, from: data).results?.first else { throw WeatherFailure.message("City not found — refine the city name in Weather Settings") }
                    latitude = found.latitude; longitude = found.longitude; resolvedCity = found.name
                } else {
                    throw WeatherFailure.message("Location unavailable — enter a city in Weather Settings")
                }
                try Task.checkCancellation()
                guard self.enabled, self.generation == token else { return }
                try await self.fetchForecast(latitude: latitude, longitude: longitude, city: resolvedCity, token: token)
            } catch { self.failed(error, token: token) }
        }
    }

    private func fetch(latitude: Double, longitude: Double, city: String) {
        guard enabled, task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.enabled, self.generation == token else { return }
            defer { if self.generation == token { self.task = nil } }
            do { try await self.fetchForecast(latitude: latitude, longitude: longitude, city: city, token: token) }
            catch { self.failed(error, token: token) }
        }
    }

    private func fetchForecast(latitude: Double, longitude: Double, city: String, token: Int) async throws {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw WeatherFailure.message("Invalid location coordinates") }
        let fahrenheit = useFahrenheit
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(latitude)), URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"), URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "1"), URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius")]
        let data = try await Self.get(url.url!, label: "Open-Meteo")
        try Task.checkCancellation()
        guard enabled, generation == token else { return }
        let result = try WeatherState.decode(data, city: city, latitude: latitude, longitude: longitude, fahrenheit: fahrenheit, selection: manualCity)
        state = result
        if let encoded = try? JSONEncoder().encode(result) { defaults.set(encoded, forKey: cacheKey) }
        DiagnosticsModel.shared.update(.weather, .ok, "Open-Meteo HTTP 200 · \(city) · current and high/low received", event: true)
        onChange?()
    }

    nonisolated private static func get(_ url: URL, label: String) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WeatherFailure.message("\(label): no HTTP response") }
        guard http.statusCode == 200 else { throw WeatherFailure.message("\(label) HTTP \(http.statusCode)") }
        return data
    }

    private func failed(_ error: Error, token: Int) {
        guard enabled, generation == token, !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled else { return }
        state = nil
        DiagnosticsModel.shared.update(.weather, .failed, error.localizedDescription, event: true)
        onChange?()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard enabled else { return }
        if [.authorized, .authorizedAlways].contains(manager.authorizationStatus), manualCity.isEmpty {
            cancelRequest(); refresh(force: true)
        }
        if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard enabled, waitingForLocation, let value = locations.last, value.horizontalAccuracy >= 0 else { return }
        waitingForLocation = false; locationDeadline?.invalidate(); locationDeadline = nil; manager.stopUpdatingLocation()
        fetch(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude, city: "Current location")
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard enabled, waitingForLocation else { return }
        waitingForLocation = false; locationDeadline?.invalidate(); locationDeadline = nil
        resolveFallback()
    }
}
