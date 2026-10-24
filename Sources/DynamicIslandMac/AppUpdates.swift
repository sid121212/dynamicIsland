import AppKit
import Sparkle

@MainActor
final class AppUpdates: NSObject {
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var settingsWindow: NSWindow?
    private var automaticCheck: NSButton?

    func start() { controller.startUpdater() }

    func addMenuItems(to menu: NSMenu) {
        let check = menu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        check.target = controller
        let settings = menu.addItem(withTitle: "Update Settings…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Update Settings"
            window.isReleasedWhenClosed = false
            let checkbox = NSButton(checkboxWithTitle: "Check automatically", target: self, action: #selector(toggleAutomatic(_:)))
            let explanation = NSTextField(wrappingLabelWithString: "Check for new versions once a day. You can also use Check for Updates… from the menu bar.")
            explanation.textColor = .secondaryLabelColor
            let content = NSStackView(views: [checkbox, explanation])
            content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
            content.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)
            ])
            automaticCheck = checkbox
            settingsWindow = window
        }
        automaticCheck?.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
        settingsWindow?.center(); settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleAutomatic(_ sender: NSButton) {
        // Sparkle persists this setting. There is no separate preference to get out of sync.
        controller.updater.automaticallyChecksForUpdates = sender.state == .on
    }

    static func allowLaunchFromCurrentLocation() -> Bool {
        guard UpdatePolicy.requiresMovingToApplications(Bundle.main.bundlePath) else { return true }
        let alert = NSAlert()
        alert.messageText = "Move to Applications"
        alert.informativeText = "Drag the app to Applications, then open it from there so updates work"
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        return false
    }
}
