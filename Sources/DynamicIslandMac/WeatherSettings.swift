import AppKit

final class WeatherSettingsController: NSWindowController, NSWindowDelegate {
    private let model: SystemMonitor
    private let city = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(model: SystemMonitor) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dynamic Island — Weather"
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor)])
        let note = NSTextField(wrappingLabelWithString: "Choose a city, or use automatic location. Automatic uses Location permission when granted. If location is unavailable, enter a city. Weather data by Open-Meteo.com (CC BY 4.0), cached for 15 minutes.")
        note.font = .systemFont(ofSize: 12); note.widthAnchor.constraint(equalToConstant: 490).isActive = true
        stack.addArrangedSubview(note)
        city.placeholderString = "City, country or region (for example, Pune, India)"
        city.widthAnchor.constraint(equalToConstant: 490).isActive = true
        stack.addArrangedSubview(city)
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
        actions.addArrangedSubview(NSButton(title: "Apply City", target: self, action: #selector(applyCity)))
        actions.addArrangedSubview(NSButton(title: "Use Automatic", target: self, action: #selector(useAutomatic)))
        actions.addArrangedSubview(NSButton(title: "Allow Location…", target: self, action: #selector(allowLocation)))
        stack.addArrangedSubview(actions)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.widthAnchor.constraint(equalToConstant: 490).isActive = true; stack.addArrangedSubview(status)
        let refresh = NSButton(title: "Refresh Weather", target: self, action: #selector(refreshWeather))
        stack.addArrangedSubview(refresh)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        city.stringValue = model.weatherCity
        NSApp.setActivationPolicy(.regular); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refreshStatus(); timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshStatus() } }
    }
    private func refreshStatus() {
        if let weather = model.weather {
            status.stringValue = "\(weather.city): \(weather.temperature)°\(weather.fahrenheit ? "F" : "C") · High \(weather.high)° / Low \(weather.low)°\n\(DiagnosticsModel.shared.entries[.weather]?.summary ?? "")"
        } else { status.stringValue = DiagnosticsModel.shared.entries[.weather]?.summary ?? "Weather is off" }
    }
    @objc private func applyCity() {
        guard !city.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { window?.makeFirstResponder(city); return }
        model.setWeatherCity(city.stringValue); model.weatherEnabled = true; refreshStatus()
    }
    @objc private func useAutomatic() { city.stringValue = ""; model.setWeatherCity(""); model.weatherEnabled = true; refreshStatus() }
    @objc private func allowLocation() { model.requestWeatherAccess() }
    @objc private func refreshWeather() { model.weatherEnabled = true; model.refreshWeather() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
