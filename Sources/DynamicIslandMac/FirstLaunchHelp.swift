import AppKit

#if !NOTARIZED
@MainActor
final class FirstLaunchHelp: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var completion: (() -> Void)?
    private let shownKey = "didShowUnnotarizedHelpV1"

    func presentOnce(then completion: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { completion(); return }
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 590), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Opening Dynamic Island"
        window.isReleasedWhenClosed = false; window.delegate = self
        let title = NSTextField(labelWithString: "A quick first-launch guide")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "This app is self-signed and not notarized by Apple. macOS may block the first launch. Only approve a download you trust; compare its SHA-256 with the release page.")
        let stack = NSStackView(views: [title, intro]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        for (index, text) in [
            "Try opening the app from Applications. If macOS blocks it, dismiss the message.",
            "Open System Settings → Privacy & Security. Scroll to the app’s security message and click Open Anyway.",
            "Authenticate if asked, confirm Open, and launch the app from Applications."
        ].enumerated() {
            let step = NSTextField(wrappingLabelWithString: "\(index + 1). \(text)")
            let placeholder = NSTextField(wrappingLabelWithString: "Screenshot placeholder · Step \(index + 1)")
            placeholder.textColor = .secondaryLabelColor; placeholder.alignment = .center
            let box = NSBox(); box.boxType = .custom; box.borderColor = .separatorColor; box.cornerRadius = 8
            box.contentView = placeholder
            box.translatesAutoresizingMaskIntoConstraints = false
            box.heightAnchor.constraint(equalToConstant: 52).isActive = true
            stack.addArrangedSubview(step); stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let actions = NSStackView(views: [NSButton(title: "Open Privacy & Security", target: self, action: #selector(openSecurity)), NSButton(title: "Continue", target: self, action: #selector(closeHelp))])
        actions.spacing = 16; stack.addArrangedSubview(actions)
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(true, forKey: shownKey)
    }
    @objc private func openSecurity() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(url) }
    }
    @objc private func closeHelp() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        let callback = completion; completion = nil; callback?()
    }
}
#endif
