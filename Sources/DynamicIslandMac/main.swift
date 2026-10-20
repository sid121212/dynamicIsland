import AppKit
import Foundation
import IOKit.ps
import ServiceManagement

private enum IslandMetrics {
    static let idleSize = NSSize(width: 188, height: 36)
    static let compactSize = NSSize(width: 286, height: 48)
    static let expandedSize = NSSize(width: 430, height: 230)
    static let topInset: CGFloat = 2
}

private final class IslandView: NSView {
    var expanded = false {
        didSet { needsDisplay = true; updateTrackingAreas() }
    }
    var onExpansionChange: ((Bool) -> Void)?
    var timerEnd: Date?
    var timerTick: Timer?
    var pinned = false
    var activity: IslandActivity? {
        didSet { needsDisplay = true }
    }
    let model: SystemMonitor
    private var tracking: NSTrackingArea?

    init(frame frameRect: NSRect, model: SystemMonitor) {
        self.model = model
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setExpanded(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard timerEnd == nil, !pinned else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.window?.frame.contains(NSEvent.mouseLocation) != true else { return }
            self.setExpanded(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handleClick(at: point)
    }

    func handleClick(at point: NSPoint) {
        if expanded, NSRect(x: 24, y: 178, width: 184, height: 36).contains(point) {
            toggleTimer()
            return
        }
        if expanded, NSRect(x: 220, y: 178, width: 186, height: 36).contains(point) {
            activity = nil
            model.post(title: "Live Activity", subtitle: "External activities can use dynamicisland://activity")
            return
        }
        if expanded, NSRect(x: 286, y: 52, width: 38, height: 38).contains(point) {
            model.mediaCommand("previous")
            return
        }
        if expanded, NSRect(x: 330, y: 48, width: 42, height: 42).contains(point) {
            model.mediaCommand("toggle")
            return
        }
        if expanded, NSRect(x: 378, y: 52, width: 38, height: 38).contains(point) {
            model.mediaCommand("next")
            return
        }
        if expanded, NSRect(x: 24, y: 116, width: 184, height: 48).contains(point), !model.calendarEnabled {
            model.requestCalendarAccess()
            return
        }
        if expanded, NSRect(x: 220, y: 116, width: 186, height: 48).contains(point), !model.weatherEnabled {
            model.weatherEnabled = true
            return
        }
        pinned = !expanded
        setExpanded(pinned)
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        onExpansionChange?(value)
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), abs(event.scrollingDeltaX) > 4 {
            model.mediaCommand(event.scrollingDeltaX > 0 ? "previous" : "next")
        } else if event.scrollingDeltaY < -3 {
            pinned = true
            setExpanded(true)
        } else if event.scrollingDeltaY > 3 {
            pinned = false
            setExpanded(false)
        }
    }

    private func toggleTimer() {
        if timerEnd != nil {
            timerEnd = nil
            timerTick?.invalidate()
            timerTick = nil
            needsDisplay = true
            return
        }
        timerEnd = Date().addingTimeInterval(5 * 60)
        timerTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let end = self.timerEnd, end <= Date() {
                self.timerEnd = nil
                self.timerTick?.invalidate()
                self.timerTick = nil
                NSSound.beep()
            }
            self.needsDisplay = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        let islandRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: islandRect, xRadius: expanded ? 27 : 18, yRadius: expanded ? 27 : 18)
        NSColor(calibratedWhite: 0.025, alpha: 0.98).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.20, alpha: 0.7).setStroke()
        path.lineWidth = 1
        path.stroke()

        if expanded { drawExpanded() } else if let activity { drawActivity(activity) } else { drawIdle() }
    }

    private func drawIdle() {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        drawText(time, in: NSRect(x: 17, y: 9, width: 94, height: 20), size: 13, weight: .semibold)
        let battery = model.batteryPercent.map { "\($0)%" } ?? "Mac"
        drawText(battery, in: NSRect(x: 112, y: 9, width: 58, height: 20), size: 12, color: .systemGreen, alignment: .right)
    }

    private func drawActivity(_ activity: IslandActivity) {
        let icon: String
        let color: NSColor
        switch activity.kind {
        case .volume: icon = "◖"; color = .systemBlue
        case .brightness: icon = "☀︎"; color = .systemYellow
        case .charging: icon = "ϟ"; color = .systemGreen
        case .battery: icon = "▰"; color = .systemGreen
        case .notification: icon = "●"; color = .systemPurple
        case .timer: icon = "◷"; color = .systemOrange
        }
        drawText(icon, in: NSRect(x: 17, y: 12, width: 28, height: 24), size: 17, color: color, weight: .bold, alignment: .center)
        drawText(activity.title, in: NSRect(x: 54, y: 8, width: 155, height: 19), size: 12, weight: .semibold)
        drawText(activity.subtitle, in: NSRect(x: 54, y: 25, width: 155, height: 16), size: 10, color: .secondaryLabelColor)
        if let progress = activity.progress {
            drawProgress(progress, in: NSRect(x: 220, y: 19, width: 48, height: 6), color: color)
            drawText("\(Int((progress * 100).rounded()))%", in: NSRect(x: 216, y: 28, width: 56, height: 14), size: 9, color: color, alignment: .center)
        } else {
            drawText("now", in: NSRect(x: 220, y: 17, width: 48, height: 18), size: 10, color: color, alignment: .center)
        }
    }

    private func drawExpanded() {
        drawText("DYNAMIC ISLAND", in: NSRect(x: 24, y: 16, width: 180, height: 18), size: 10, color: .secondaryLabelColor, weight: .bold)
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        drawText(time, in: NSRect(x: 24, y: 34, width: 90, height: 27), size: 21, weight: .semibold)
        let battery = model.batteryPercent.map { "\(model.isCharging ? "ϟ " : "")\($0)%" } ?? "Mac"
        drawText(battery, in: NSRect(x: 118, y: 38, width: 64, height: 20), size: 11, color: .systemGreen, weight: .medium)

        drawText(model.nowPlaying.title, in: NSRect(x: 194, y: 17, width: 218, height: 20), size: 12, weight: .semibold)
        drawText(model.nowPlaying.artist, in: NSRect(x: 194, y: 36, width: 86, height: 18), size: 10, color: .secondaryLabelColor)
        if model.nowPlaying.duration > 0 {
            drawProgress(model.nowPlaying.position / model.nowPlaying.duration, in: NSRect(x: 194, y: 67, width: 82, height: 5), color: .systemPink)
        }
        drawRoundControl(rect: NSRect(x: 286, y: 52, width: 38, height: 38), title: "‹")
        drawRoundControl(rect: NSRect(x: 330, y: 48, width: 42, height: 42), title: model.nowPlaying.isPlaying ? "Ⅱ" : "▶")
        drawRoundControl(rect: NSRect(x: 378, y: 52, width: 38, height: 38), title: "›")

        let eventTitle = model.nextEvent?.title ?? (model.calendarEnabled ? "No upcoming events" : "Enable Calendar")
        let eventSubtitle = model.nextEvent.map { DateFormatter.localizedString(from: $0.startDate, dateStyle: .none, timeStyle: .short) } ?? "Today"
        drawCard(rect: NSRect(x: 24, y: 116, width: 184, height: 48), title: eventTitle, subtitle: eventSubtitle, color: .systemRed)

        let weatherTitle = model.weather.map { "\($0.symbol)  \($0.temperature)°C" } ?? (model.weatherEnabled ? "Locating weather…" : "Enable Weather")
        let weatherSubtitle = model.weather?.description ?? "Current location"
        drawCard(rect: NSRect(x: 220, y: 116, width: 186, height: 48), title: weatherTitle, subtitle: weatherSubtitle, color: .systemCyan)

        drawButton(rect: NSRect(x: 24, y: 178, width: 184, height: 36), title: timerTitle(), color: .systemOrange)
        drawButton(rect: NSRect(x: 220, y: 178, width: 186, height: 36), title: "Test live activity", color: .systemPurple)
    }

    private func timerTitle() -> String {
        guard let end = timerEnd else { return "Start 5 min timer" }
        let remaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        return String(format: "Stop  %d:%02d", remaining / 60, remaining % 60)
    }

    private func drawButton(rect: NSRect, title: String, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        color.withAlphaComponent(0.19).setFill()
        path.fill()
        color.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        drawText(title, in: rect.offsetBy(dx: 0, dy: 10), size: 11, color: color, weight: .semibold, alignment: .center)
    }

    private func drawCard(rect: NSRect, title: String, subtitle: String, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        path.fill()
        drawText(title, in: NSRect(x: rect.minX + 12, y: rect.minY + 8, width: rect.width - 24, height: 17), size: 11, color: color, weight: .semibold)
        drawText(subtitle, in: NSRect(x: rect.minX + 12, y: rect.minY + 26, width: rect.width - 24, height: 14), size: 9, color: .secondaryLabelColor)
    }

    private func drawRoundControl(rect: NSRect, title: String) {
        let path = NSBezierPath(ovalIn: rect)
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        path.fill()
        drawText(title, in: rect.offsetBy(dx: 0, dy: rect.height / 2 - 9), size: 14, weight: .semibold, alignment: .center)
    }

    private func drawProgress(_ value: Double, in rect: NSRect, color: NSColor) {
        let clamped = max(0, min(1, value))
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        color.setFill()
        let fill = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * clamped), height: rect.height)
        NSBezierPath(roundedRect: fill, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        size: CGFloat,
        color: NSColor = .white,
        weight: NSFont.Weight = .regular,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attrs)
    }

}

private final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: IslandMetrics.idleSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SystemMonitor()
    private var panel: IslandPanel!
    private var islandView: IslandView!
    private var statusItem: NSStatusItem!
    private var clockTimer: Timer?
    private var hoverTimer: Timer?
    private var pointerLeftAt: Date?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var activityTimer: Timer?
    private var activityObserver: NSObjectProtocol?
    private var preferredScreenIndex = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePanel()
        configureMenuBar()
        observeScreens()
        connectModel()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.islandView.needsDisplay = true
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.updateHoverState()
        }
        installClickMonitors()
        activityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.siddharth.dynamicisland.activity"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let values = notification.userInfo else { return }
            let title = values["title"] as? String ?? "Live Activity"
            let subtitle = values["subtitle"] as? String ?? ""
            let duration = values["duration"] as? Double ?? 5
            self?.model.post(title: title, subtitle: subtitle, duration: min(max(duration, 1), 60))
        }
    }

    private func configurePanel() {
        panel = IslandPanel()
        islandView = IslandView(frame: NSRect(origin: .zero, size: IslandMetrics.idleSize), model: model)
        islandView.autoresizingMask = [.width, .height]
        islandView.onExpansionChange = { [weak self] expanded in
            self?.resizePanel(expanded: expanded)
        }
        panel.contentView = islandView
        positionPanel(size: IslandMetrics.idleSize)
        panel.orderFrontRegardless()
    }

    private func connectModel() {
        model.onChange = { [weak self] in self?.islandView.needsDisplay = true }
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

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Dynamic Island")
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Island", action: #selector(toggleIsland), keyEquivalent: "i")
        menu.addItem(withTitle: "Recenter", action: #selector(recenter), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(toggleItem("Now Playing", action: #selector(toggleMusic), enabled: model.musicEnabled))
        menu.addItem(toggleItem("Volume & Brightness HUDs", action: #selector(toggleHUDs), enabled: model.hudsEnabled))
        menu.addItem(toggleItem("Charging & Battery Events", action: #selector(togglePowerEvents), enabled: model.powerEventsEnabled))
        menu.addItem(toggleItem("Calendar Widget", action: #selector(toggleCalendar), enabled: model.calendarEnabled))
        menu.addItem(toggleItem("Weather Widget", action: #selector(toggleWeather), enabled: model.weatherEnabled))
        menu.addItem(.separator())

        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let automatic = NSMenuItem(title: "Follow Pointer", action: #selector(selectDisplay(_:)), keyEquivalent: "")
        automatic.tag = -1
        automatic.state = preferredScreenIndex == -1 ? .on : .off
        displayMenu.addItem(automatic)
        for (index, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let item = NSMenuItem(title: name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.tag = index
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

    private func toggleItem(_ title: String, action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = enabled ? .on : .off
        return item
    }

    private func observeScreens() {
        NotificationCenter.default.addObserver(self, selector: #selector(recenter), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func installClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async { self?.handleMonitoredClick() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.panel.frame.contains(NSEvent.mouseLocation) else { return event }
            self.handleMonitoredClick()
            return nil
        }
    }

    private func handleMonitoredClick() {
        guard panel.frame.contains(NSEvent.mouseLocation) else { return }
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = islandView.convert(windowPoint, from: nil)
        islandView.handleClick(at: viewPoint)
    }

    private func updateHoverState() {
        let pointerIsInside = panel.frame.contains(NSEvent.mouseLocation)
        if pointerIsInside {
            pointerLeftAt = nil
            islandView.setExpanded(true)
            return
        }

        guard islandView.expanded, islandView.timerEnd == nil, !islandView.pinned else { return }
        if pointerLeftAt == nil {
            pointerLeftAt = Date()
        } else if Date().timeIntervalSince(pointerLeftAt!) > 0.30 {
            islandView.setExpanded(false)
            pointerLeftAt = nil
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
        islandView.expanded.toggle()
        islandView.pinned = islandView.expanded
        resizePanel(expanded: islandView.expanded)
    }

    @objc private func recenter() {
        positionPanel(size: panel.frame.size)
    }

    private func resizePanel(expanded: Bool) {
        let size = expanded ? IslandMetrics.expandedSize : (islandView.activity == nil ? IslandMetrics.idleSize : IslandMetrics.compactSize)
        guard let screen = targetScreen() else { return }
        let origin = panelOrigin(on: screen, size: size)
        let previousWidth = panel.frame.width
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        }
        if let layer = islandView.layer, previousWidth > 0 {
            let spring = CASpringAnimation(keyPath: "transform.scale.x")
            spring.fromValue = previousWidth / size.width
            spring.toValue = 1
            spring.mass = 0.7
            spring.stiffness = 280
            spring.damping = 24
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "islandSpring")
        }
    }

    private func positionPanel(size: NSSize) {
        guard let screen = targetScreen() else { return }
        let origin = panelOrigin(on: screen, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func panelOrigin(on screen: NSScreen, size: NSSize) -> NSPoint {
        // visibleFrame.maxY sits immediately below the menu bar and physical
        // notch. Keeping the panel below it makes the island visible and
        // clickable on both notched and notchless displays.
        NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - IslandMetrics.topInset
        )
    }

    private func targetScreen() -> NSScreen? {
        if preferredScreenIndex >= 0, preferredScreenIndex < NSScreen.screens.count {
            return NSScreen.screens[preferredScreenIndex]
        }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "dynamicisland" {
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
