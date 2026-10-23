import AppKit
import ApplicationServices
import CoreLocation
import EventKit

@MainActor final class PermissionsManager: NSObject, NSWindowDelegate {
    private let diagnostics: DiagnosticsModel
    private let model: SystemMonitor
    private var window: NSWindow?
    private let rows = NSStackView()
    private var statusTimer: Timer?
    var onWeatherSettings: (() -> Void)?
    var onTraySettings: (() -> Void)?
    private let locationManager = CLLocationManager()
    private let heading = NSTextField(wrappingLabelWithString: "Enable only the permissions for modules you want to use.")
    private let services: [ServiceID] = [.calendar, .location, .accessibility, .inputMonitoring, .screenshots, .signature]

    init(model: SystemMonitor, diagnostics: DiagnosticsModel) {
        self.model = model; self.diagnostics = diagnostics
        super.init()
    }

    func refreshStatuses() {
        model.syncCalendarAuthorization()
        model.refreshMediaKeyPermissions()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: diagnostics.update(.calendar, .ok, "Full calendar access granted")
        case .notDetermined: diagnostics.update(.calendar, .failed, "Not requested — Calendar needs permission")
        case .denied: diagnostics.update(.calendar, .failed, "Denied — open Calendar privacy settings")
        case .restricted: diagnostics.update(.calendar, .failed, "Restricted by system policy")
        case .writeOnly: diagnostics.update(.calendar, .failed, "Write-only permission cannot read events")
        @unknown default: diagnostics.update(.calendar, .failed, "Unknown calendar authorization")
        }
        let status = locationManager.authorizationStatus
        switch status {
        case .authorized, .authorizedAlways: diagnostics.update(.location, .ok, "Location permission granted")
        case .notDetermined: diagnostics.update(.location, .failed, "Not requested — Weather needs Location or a manual city")
        case .denied: diagnostics.update(.location, .failed, "Location denied — open privacy settings")
        case .restricted: diagnostics.update(.location, .failed, "Location restricted by system policy")
        @unknown default: diagnostics.update(.location, .failed, "Unknown location authorization")
        }
        let trusted = AXIsProcessTrusted()
        diagnostics.update(.accessibility, trusted ? .ok : .failed, trusted ? "Accessibility trust granted" : "Not trusted — request in Permissions")
        let input = CGPreflightListenEventAccess()
        diagnostics.update(.inputMonitoring, input ? .ok : .failed, input ? "Input Monitoring granted" : "Not granted — media keys remain observe-only")
    }

    func present(focus: ServiceID? = nil) {
        if focus == .weather, let onWeatherSettings { onWeatherSettings(); return }
        if focus == .clipboard, let onTraySettings { onTraySettings(); return }
        activateForPermission()
        if window == nil { buildWindow() }
        if let focus {
            let entry = diagnostics.entries[focus]
            heading.stringValue = "\(focus.title): \(entry?.summary ?? "No status"). Use the relevant permission action below. Unsupported services remain amber until their implementation milestone passes."
        }
        refreshStatuses(); rebuildRows()
        window?.makeKeyAndOrderFront(nil)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
            guard let self, self.window?.isVisible == true else { return }
            self.refreshStatuses(); self.rebuildRows()
            }
        }
    }

    func activateForPermission() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func restoreAccessoryIfPossible() {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate(); statusTimer = nil
        DispatchQueue.main.async { [weak self] in self?.restoreAccessoryIfPossible() }
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dynamic Island — Permissions"
        window.isReleasedWhenClosed = false; window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor)
        ])
        heading.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalToConstant: 720).isActive = true
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10
        root.addArrangedSubview(rows)
        window.center(); self.window = window
    }
    private func rebuildRows() {
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        for (index, service) in services.enumerated() {
            let entry = diagnostics.entries[service]!
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            let dot = NSTextField(labelWithString: "●")
            dot.textColor = entry.severity == .ok ? .systemGreen : entry.severity == .failed ? .systemRed : .systemOrange
            row.addArrangedSubview(dot)
            let label = NSTextField(wrappingLabelWithString: "\(service.title)\n\(entry.summary)")
            label.font = .systemFont(ofSize: 11); label.maximumNumberOfLines = 2
            label.widthAnchor.constraint(equalToConstant: 540).isActive = true
            row.addArrangedSubview(label)
            let button = NSButton(title: service == .signature ? "Instructions…" : "Allow / Settings…", target: self, action: #selector(request(_:)))
            button.tag = index; row.addArrangedSubview(button)
            rows.addArrangedSubview(row)
        }
    }
    @objc private func request(_ sender: NSButton) {
        activateForPermission()
        let service = services[sender.tag]
        switch service {
        case .calendar:
            if [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) { openPrivacy("Calendars") }
            else { model.requestCalendarAccess() }
        case .location:
            if [.denied, .restricted].contains(locationManager.authorizationStatus) { openPrivacy("LocationServices") }
            else { model.requestWeatherAccess() }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if !AXIsProcessTrusted() { openPrivacy("Accessibility") }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openPrivacy("ListenEvent") }
        case .screenshots:
            model.restartScreenshots()
            if diagnostics.entries[.screenshots]?.severity == .failed { openPrivacy("FilesAndFolders") }
        case .signature:
            let alert = NSAlert()
            alert.messageText = "Stable signing identity required"
            alert.informativeText = "In Keychain Access choose Certificate Assistant → Create a Certificate. Name: NotchDev. Identity: Self Signed Root. Type: Code Signing. Then rebuild with the same identity. The build will not reset permissions automatically."
            alert.runModal()
        default: break
        }
        refreshStatuses(); rebuildRows()
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(url) }
    }
}
