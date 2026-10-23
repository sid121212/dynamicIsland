import AppKit

final class TraySettingsController: NSWindowController, NSWindowDelegate {
    private let model: SystemMonitor
    private let pause = NSButton(checkboxWithTitle: "Pause clipboard monitoring", target: nil, action: nil)
    private let screenshots = NSButton(checkboxWithTitle: "Screenshots in Tray", target: nil, action: nil)
    private let retention = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exclusions = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private let durations: [Double] = [3600, 86400, 604800, 0]
    init(model: SystemMonitor) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dynamic Island — Tray Settings"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20); stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor)])
        pause.target = self; pause.action = #selector(togglePause)
        screenshots.target = self; screenshots.action = #selector(toggleScreenshots)
        stack.addArrangedSubview(pause); stack.addArrangedSubview(screenshots)
        let retentionRow = NSStackView(); retentionRow.spacing = 12
        retentionRow.addArrangedSubview(NSTextField(labelWithString: "Remove unpinned items after"))
        retention.addItems(withTitles: ["1 hour", "24 hours", "7 days", "Never"]); retention.target = self; retention.action = #selector(changeRetention)
        retentionRow.addArrangedSubview(retention); stack.addArrangedSubview(retentionRow)
        let note = NSTextField(wrappingLabelWithString: "Excluded apps (bundle identifiers, one per line). Password-manager apps are excluded by default; concealed/transient clipboard types are always ignored.")
        note.font = .systemFont(ofSize: 11); note.widthAnchor.constraint(equalToConstant: 530).isActive = true; stack.addArrangedSubview(note)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        exclusions.isRichText = false; exclusions.font = .monospacedSystemFont(ofSize: 11, weight: .regular); exclusions.isAutomaticQuoteSubstitutionEnabled = false
        exclusions.frame = NSRect(x: 0, y: 0, width: 530, height: 130)
        exclusions.isVerticallyResizable = true; exclusions.isHorizontallyResizable = false
        exclusions.autoresizingMask = .width; exclusions.textContainer?.widthTracksTextView = true
        scroll.documentView = exclusions; scroll.widthAnchor.constraint(equalToConstant: 530).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        stack.addArrangedSubview(scroll)
        let buttons = NSStackView(); buttons.spacing = 8
        buttons.addArrangedSubview(NSButton(title: "Save Exclusions", target: self, action: #selector(saveExclusions)))
        buttons.addArrangedSubview(NSButton(title: "Clipboard Access…", target: self, action: #selector(openClipboardSettings)))
        buttons.addArrangedSubview(NSButton(title: "Clear All History", target: self, action: #selector(clearAll)))
        stack.addArrangedSubview(buttons)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.widthAnchor.constraint(equalToConstant: 530).isActive = true
        stack.addArrangedSubview(status); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        NSApp.setActivationPolicy(.regular); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        exclusions.string = model.clipboard.exclusionText
        retention.selectItem(at: durations.firstIndex(of: model.trayStore.retention) ?? 1)
        model.trayStore.ensureLoaded(); updateStatus(); timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateStatus() } }
    }
    private func updateStatus() {
        pause.state = model.clipboardEnabled ? .off : .on; screenshots.state = model.screenshotsEnabled ? .on : .off
        model.clipboard.refreshStatus()
        status.stringValue = "\(model.trayStore.items.count) items · max 100 unpinned / 500 MB · pinned items survive retention\n\(model.trayStore.error ?? DiagnosticsModel.shared.entries[.clipboard]?.summary ?? "")"
    }
    @objc private func togglePause() { model.clipboardEnabled = pause.state != .on }
    @objc private func toggleScreenshots() { model.screenshotsEnabled = screenshots.state == .on }
    @objc private func changeRetention() { UserDefaults.standard.set(durations[retention.indexOfSelectedItem], forKey: "trayRetention"); model.trayStore.ensureLoaded() }
    @objc private func saveExclusions() { model.clipboard.setExclusions(exclusions.string) }
    @objc private func openClipboardSettings() { model.clipboard.openAccessSettings() }
    @objc private func clearAll() { model.trayStore.clear(includingPinned: true) }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        DispatchQueue.main.async { if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) } }
    }
}
