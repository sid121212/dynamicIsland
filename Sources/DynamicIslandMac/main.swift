import AppKit
import Foundation
import ServiceManagement

private final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: IslandMetrics.idleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SystemMonitor()
    private var panel: IslandPanel!
    private var islandView: IslandView!
    private var statusItem: NSStatusItem!
    private var hoverExpansionTimer: Timer?
    private var hoverCollapseTimer: Timer?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var activityTimer: Timer?
    private var activityInboxTimer: Timer?
    private var preferredScreenIndex = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePanel()
        configureMenuBar()
        observeScreens()
        connectModel()
        installClickMonitors()
        activityInboxTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.drainActivityInbox()
        }
    }

    private func configurePanel() {
        panel = IslandPanel()
        let notch = targetScreen().map(collapsedSize(on:)) ?? IslandMetrics.idleSize
        let expanded = NotchGeometry.expandedSize(notch: notch)
        let host = NSSize(width: expanded.width + 40, height: expanded.height + 40)
        islandView = IslandView(frame: NSRect(origin: .zero, size: host), model: model)
        islandView.configure(notch: notch)
        islandView.autoresizingMask = [.width, .height]
        islandView.onExpansionChange = { [weak self] expanded in
            self?.resizePanel(expanded: expanded)
        }
        islandView.onSettings = { [weak self] in self?.showSettings() }
        islandView.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.panel.ignoresMouseEvents = !self.pointIsInsideShape(NSEvent.mouseLocation)
        }
        panel.contentView = islandView
        positionPanel(size: host)
        panel.ignoresMouseEvents = !pointIsInsideShape(NSEvent.mouseLocation)
        panel.orderFrontRegardless()
    }

    private func connectModel() {
        model.onChange = { [weak self] in
            self?.islandView.refresh()
            self?.syncMenuStates()
        }
        model.onActivity = { [weak self] activity in self?.present(activity) }
    }

    private func present(_ activity: IslandActivity) {
        activityTimer?.invalidate()
        islandView.activity = activity
        if !islandView.expanded { resizePanel(expanded: false) }
        activityTimer = Timer.scheduledTimer(withTimeInterval: max(0.25, activity.expiresAt.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.islandView.activity = nil
            if !self.islandView.expanded { self.resizePanel(expanded: false) }
        }
    }

    private func drainActivityInbox() {
        let url = URL(fileURLWithPath: "/tmp/dynamic-island-mac-activity.json")
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? FileManager.default.removeItem(at: url)
        let title = values["title"] as? String ?? "Live Activity"
        let subtitle = values["subtitle"] as? String ?? ""
        let duration = values["duration"] as? Double ?? 5
        model.post(title: title, subtitle: subtitle, duration: min(max(duration, 1), 60))
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Dynamic Island")
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "Toggle Island", action: #selector(toggleIsland), keyEquivalent: "i")
        toggle.target = self
        let recenterItem = menu.addItem(withTitle: "Recenter", action: #selector(recenter), keyEquivalent: "r")
        recenterItem.target = self
        menu.addItem(.separator())
        menu.addItem(toggleItem("Now Playing", action: #selector(toggleMusic), enabled: model.musicEnabled))
        menu.addItem(toggleItem("Volume & Brightness HUDs", action: #selector(toggleHUDs), enabled: model.hudsEnabled))
        menu.addItem(toggleItem("Charging & Battery Events", action: #selector(togglePowerEvents), enabled: model.powerEventsEnabled))
        menu.addItem(toggleItem("Calendar Widget", action: #selector(toggleCalendar), enabled: model.calendarEnabled))
        menu.addItem(toggleItem("Weather Widget", action: #selector(toggleWeather), enabled: model.weatherEnabled))
        menu.addItem(toggleItem("Clipboard History", action: #selector(toggleClipboard), enabled: model.clipboardEnabled))
        #if DEBUG
        let debug = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let debugMenu = NSMenu()
        let test = debugMenu.addItem(withTitle: "Test live activity", action: #selector(debugActivity), keyEquivalent: "")
        test.target = self
        let timer = debugMenu.addItem(withTitle: "Start 5 min timer", action: #selector(debugTimer), keyEquivalent: "")
        timer.target = self
        debug.submenu = debugMenu
        menu.addItem(debug)
        #endif
        menu.addItem(.separator())

        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let automatic = NSMenuItem(title: "Follow Pointer", action: #selector(selectDisplay(_:)), keyEquivalent: "")
        automatic.tag = -1
        automatic.target = self
        automatic.state = preferredScreenIndex == -1 ? .on : .off
        displayMenu.addItem(automatic)
        for (index, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let item = NSMenuItem(title: name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = preferredScreenIndex == index ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        let loginItem = toggleItem("Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), enabled: SMAppService.mainApp.status == .enabled)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dynamic Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func showSettings() {
        guard let menu = statusItem.menu else { return }
        let point = islandView.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: point, in: islandView)
    }

    #if DEBUG
    @objc private func debugActivity() {
        model.post(title: "Test activity", subtitle: "Debug build", duration: 5)
    }
    @objc private func debugTimer() {
        present(IslandActivity(kind: .timer, title: "Timer", subtitle: "5 minutes", progress: nil, expiresAt: Date().addingTimeInterval(300)))
    }
    #endif

    private func toggleItem(_ title: String, action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = enabled ? .on : .off
        return item
    }

    private func syncMenuStates() {
        guard let menu = statusItem?.menu else { return }
        let states: [String: Bool] = [
            "Now Playing": model.musicEnabled,
            "Volume & Brightness HUDs": model.hudsEnabled,
            "Charging & Battery Events": model.powerEventsEnabled,
            "Calendar Widget": model.calendarEnabled,
            "Weather Widget": model.weatherEnabled,
            "Clipboard History": model.clipboardEnabled
        ]
        for item in menu.items {
            if let enabled = states[item.title] { item.state = enabled ? .on : .off }
        }
    }

    private func observeScreens() {
        NotificationCenter.default.addObserver(self, selector: #selector(recenter), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func installClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.pointIsInsideShape(NSEvent.mouseLocation) { self.handleMonitoredClick() }
                else { self.islandView.pinned = false; self.islandView.setExpanded(false) }
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.panel, self.pointIsInsideShape(NSEvent.mouseLocation) else { return event }
            self.handleMonitoredClick()
            return nil
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverState() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateHoverState()
            return event
        }
    }

    private func handleMonitoredClick() {
        guard pointIsInsideShape(NSEvent.mouseLocation) else { return }
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = islandView.convert(windowPoint, from: nil)
        islandView.handleClick(at: viewPoint)
    }

    private func updateHoverState() {
        let pointerIsInside = pointIsInsideShape(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !pointerIsInside
        if pointerIsInside {
            hoverCollapseTimer?.invalidate()
            hoverCollapseTimer = nil
            guard !islandView.expanded, hoverExpansionTimer == nil else { return }
            hoverExpansionTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.hoverExpansionTimer = nil
                if self.pointIsInsideShape(NSEvent.mouseLocation) { self.islandView.setExpanded(true) }
            }
            return
        }

        hoverExpansionTimer?.invalidate()
        hoverExpansionTimer = nil
        guard islandView.expanded, !islandView.pinned else { return }
        guard hoverCollapseTimer == nil else { return }
        hoverCollapseTimer = Timer.scheduledTimer(withTimeInterval: 0.30, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hoverCollapseTimer = nil
            if !self.pointIsInsideShape(NSEvent.mouseLocation), !self.islandView.pinned {
                self.islandView.setExpanded(false)
            }
        }
    }

    @objc private func toggleMusic(_ sender: NSMenuItem) {
        model.musicEnabled.toggle()
        sender.state = model.musicEnabled ? .on : .off
    }

    @objc private func toggleHUDs(_ sender: NSMenuItem) {
        model.hudsEnabled.toggle()
        sender.state = model.hudsEnabled ? .on : .off
    }

    @objc private func togglePowerEvents(_ sender: NSMenuItem) {
        model.powerEventsEnabled.toggle()
        sender.state = model.powerEventsEnabled ? .on : .off
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        if !model.calendarEnabled { model.requestCalendarAccess() } else { model.calendarEnabled = false }
        sender.state = model.calendarEnabled ? .on : .off
    }

    @objc private func toggleWeather(_ sender: NSMenuItem) {
        model.weatherEnabled.toggle()
        sender.state = model.weatherEnabled ? .on : .off
    }

    @objc private func toggleClipboard(_ sender: NSMenuItem) {
        model.clipboardEnabled.toggle()
        sender.state = model.clipboardEnabled ? .on : .off
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        preferredScreenIndex = sender.tag
        if let menu = sender.menu {
            for item in menu.items { item.state = item === sender ? .on : .off }
        }
        recenter()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at Login"
            alert.informativeText = "Move Dynamic Island.app to /Applications before enabling launch at login. \(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func toggleIsland() {
        islandView.pinned = !islandView.expanded
        islandView.setExpanded(!islandView.expanded)
    }

    @objc private func recenter() {
        guard let screen = targetScreen() else { return }
        let notch = collapsedSize(on: screen)
        islandView.configure(notch: notch)
        let expanded = NotchGeometry.expandedSize(notch: notch)
        positionPanel(size: NSSize(width: expanded.width + 40, height: expanded.height + 40))
    }

    private func resizePanel(expanded: Bool) {
        islandView.transition(animated: true)
    }

    private func positionPanel(size: NSSize) {
        guard let screen = targetScreen() else { return }
        let origin = panelOrigin(on: screen, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func panelOrigin(on screen: NSScreen, size: NSSize) -> NSPoint {
        // Anchor to the actual top edge so the black idle surface disappears
        // into a physical notch and every expanded state grows downward from it.
        NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
    }

    private func targetScreen() -> NSScreen? {
        if preferredScreenIndex >= 0, preferredScreenIndex < NSScreen.screens.count {
            return NSScreen.screens[preferredScreenIndex]
        }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    }

    private func collapsedSize(on screen: NSScreen) -> NSSize {
        let notchHeight = screen.safeAreaInsets.top
        guard let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea else {
            return IslandMetrics.idleSize
        }
        let notchWidth = screen.frame.width - leftArea.width - rightArea.width
        if notchHeight > 0, notchWidth >= 120, notchWidth <= 320 {
            return NSSize(width: notchWidth, height: notchHeight)
        }
        return IslandMetrics.idleSize
    }

    private func pointIsInsideShape(_ screenPoint: NSPoint) -> Bool {
        guard panel.frame.contains(screenPoint) else { return false }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let viewPoint = islandView.convert(windowPoint, from: nil)
        return islandView.containsShapePoint(viewPoint)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "dynamicislandmac" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let title = values["title"] ?? "Live Activity"
            let subtitle = values["subtitle"] ?? ""
            let duration = Double(values["duration"] ?? "5") ?? 5
            model.post(title: title, subtitle: subtitle, duration: min(max(duration, 1), 60))
        }
    }
}

let application = NSApplication.shared
private let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
