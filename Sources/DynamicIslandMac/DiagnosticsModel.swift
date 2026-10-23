import AppKit
import Observation
import OSLog
import Security

enum ServiceID: String, CaseIterable, Codable {
    case nowPlaying, calendar, location, weather, accessibility, inputMonitoring
    case mediaKeys, brightness, volume, battery, clipboard, screenshots, signature

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing adapter"
        case .calendar: return "Calendar authorization"
        case .location: return "Location authorization"
        case .weather: return "Weather request"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .mediaKeys: return "Media-key event tap"
        case .brightness: return "DisplayServices brightness"
        case .volume: return "CoreAudio output volume"
        case .battery: return "Battery notifications"
        case .clipboard: return "Clipboard monitor"
        case .screenshots: return "Screenshot watcher"
        case .signature: return "Code signature and app path"
        }
    }
}

enum DiagnosticSeverity: String, Codable { case ok, degraded, failed }

struct DiagnosticEntry: Codable, Equatable {
    let service: ServiceID
    var severity: DiagnosticSeverity
    var summary: String
    var lastEvent: Date?
}

@Observable final class DiagnosticsModel {
    static let shared = DiagnosticsModel()
    private(set) var entries: [ServiceID: DiagnosticEntry] = [:]
    private var loggers: [ServiceID: Logger] = [:]

    init() {
        for service in ServiceID.allCases {
            entries[service] = DiagnosticEntry(service: service, severity: .degraded, summary: "Not started; no event received", lastEvent: nil)
            loggers[service] = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.siddharth.dynamicisland.modern", category: service.rawValue)
        }
        update(.mediaKeys, .degraded, "No active event tap; native HUD may also appear")
        update(.screenshots, .degraded, "Screenshot watcher not implemented in this milestone")
        update(.battery, .degraded, "Polling only; battery notifications are not registered")
    }

    func update(_ id: ServiceID, _ severity: DiagnosticSeverity, _ summary: String, event: Bool = false) {
        precondition(Thread.isMainThread)
        let previous = entries[id]
        if previous?.severity != severity || previous?.summary != summary {
            if severity == .failed { loggers[id]?.error("\(summary, privacy: .public)") }
            else { loggers[id]?.info("\(summary, privacy: .public)") }
        }
        entries[id] = DiagnosticEntry(service: id, severity: severity, summary: summary, lastEvent: event ? Date() : previous?.lastEvent)
    }

    func refreshSignature() {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        let codeStatus = SecCodeCopySelf([], &code)
        guard codeStatus == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else {
            update(.signature, .failed, "Cannot inspect running code signature · \(Bundle.main.bundlePath)")
            return
        }
        let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let identity = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let hardened = flags & 0x10000 != 0
        let summary = "\(identity ?? "Ad-hoc / no signing certificate") · runtime \(hardened ? "on" : "off") · \(Bundle.main.bundlePath)"
        update(.signature, identity != nil && hardened ? .ok : .failed, summary, event: true)
    }

    // Explicitly requested reports contain service status, never clipboard contents.
    func writeReport(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ServiceID.allCases.compactMap { entries[$0] }).write(to: url, options: .atomic)
    }
}

final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    private let diagnostics: DiagnosticsModel
    private let permissions: PermissionsManager
    private let rows = NSStackView()
    private var statusTimer: Timer?
    var reportURL: URL?
    private var renderedEntries: [ServiceID: DiagnosticEntry] = [:]

    init(model: DiagnosticsModel, permissions: PermissionsManager) {
        diagnostics = model
        self.permissions = permissions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 590), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Dynamic Island — Diagnostics"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
        let heading = NSTextField(labelWithString: "Green = observed ready · Amber = limited / inactive · Red = failed or permission missing")
        heading.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(heading)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let note = NSTextField(wrappingLabelWithString: "Readiness is not a manual acceptance-test result. Fix opens Permissions and never grants access automatically. Logs are available in Console under the app's bundle identifier.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        root.addArrangedSubview(note)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        permissions.refreshStatuses(); diagnostics.refreshSignature(); rebuildRows()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
            guard let self, self.window?.isVisible == true else { return }
            self.permissions.refreshStatuses(); self.rebuildRows()
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate(); statusTimer = nil
        DispatchQueue.main.async { [weak self] in self?.permissions.restoreAccessoryIfPossible() }
    }
    private func rebuildRows() {
        guard renderedEntries != diagnostics.entries else { return }
        renderedEntries = diagnostics.entries
        if let reportURL {
            do { try diagnostics.writeReport(to: reportURL) }
            catch { NSLog("Diagnostics report failed: %@", error.localizedDescription) }
        }
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        for (index, id) in ServiceID.allCases.enumerated() {
            guard let entry = diagnostics.entries[id] else { continue }
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
            let dot = NSTextField(labelWithString: "●")
            dot.textColor = entry.severity == .ok ? .systemGreen : entry.severity == .failed ? .systemRed : .systemOrange
            dot.widthAnchor.constraint(equalToConstant: 16).isActive = true
            row.addArrangedSubview(dot)
            let text = NSStackView(); text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
            let title = NSTextField(labelWithString: id.title); title.font = .systemFont(ofSize: 12, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: entry.summary); detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 2
            text.addArrangedSubview(title); text.addArrangedSubview(detail)
            row.addArrangedSubview(text)
            text.widthAnchor.constraint(equalToConstant: 620).isActive = true
            let time = NSTextField(labelWithString: entry.lastEvent.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "No event")
            time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            time.widthAnchor.constraint(equalToConstant: 80).isActive = true
            row.addArrangedSubview(time)
            let fix = NSButton(title: "Fix…", target: self, action: #selector(fixService(_:)))
            fix.tag = index; row.addArrangedSubview(fix)
            rows.addArrangedSubview(row)
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 45).isActive = true
        }
    }
    @objc private func fixService(_ sender: NSButton) { permissions.present(focus: ServiceID.allCases[sender.tag]) }
}
