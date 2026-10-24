import AppKit

enum IslandMetrics {
    static let idleSize = NSSize(width: 200, height: 32)
}

enum TabTitles {
    static let all = ["Home", "Clipboard", "Controls"]
    static var home: String { all[0] }
    static var clipboard: String { all[1] }
    static var controls: String { all[2] }
}
enum IslandTab { case nook, tray, controls }

enum NotchGeometry {
    static func path(in rect: NSRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        func quad(_ end: NSPoint, _ control: NSPoint) {
            let start = p.currentPoint
            p.curve(to: end,
                controlPoint1: NSPoint(x: start.x + (control.x - start.x) * 2 / 3, y: start.y + (control.y - start.y) * 2 / 3),
                controlPoint2: NSPoint(x: end.x + (control.x - end.x) * 2 / 3, y: end.y + (control.y - end.y) * 2 / 3))
        }
        p.move(to: NSPoint(x: rect.minX, y: rect.minY))
        quad(NSPoint(x: rect.minX + top, y: rect.minY + top), NSPoint(x: rect.minX + top, y: rect.minY))
        p.line(to: NSPoint(x: rect.minX + top, y: rect.maxY - bottom))
        quad(NSPoint(x: rect.minX + top + bottom, y: rect.maxY), NSPoint(x: rect.minX + top, y: rect.maxY))
        p.line(to: NSPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        quad(NSPoint(x: rect.maxX - top, y: rect.maxY - bottom), NSPoint(x: rect.maxX - top, y: rect.maxY))
        p.line(to: NSPoint(x: rect.maxX - top, y: rect.minY + top))
        quad(NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.maxX - top, y: rect.minY))
        p.close()
        return p
    }

    static func expandedSize(notch: NSSize) -> NSSize {
        NSSize(width: min(560, max(500, notch.width * 2.9)), height: notch.height + 102)
    }
}

final class IslandView: NSView {
    let model: SystemMonitor
    var onExpansionChange: ((Bool) -> Void)?
    var onSettings: (() -> Void)?
    var onWeatherSettings: (() -> Void)?
    var onTraySettings: (() -> Void)?
    var onTrayFocus: ((NSView?) -> Void)?
    var onGeometryChange: (() -> Void)?
    private(set) var expanded = false
    var pinned = false
    var activity: IslandActivity? { didSet { animateHUDFill(); needsDisplay = true } }
    private(set) var notchSize = IslandMetrics.idleSize
    private(set) var expandedSize = NotchGeometry.expandedSize(notch: IslandMetrics.idleSize)
    private var selectedTab: IslandTab = .nook
    private var size = IslandMetrics.idleSize
    private var topRadius: CGFloat = 6
    private var bottomRadius: CGFloat = 14
    private var contentAlpha: CGFloat = 0 { didSet { updateControlsSurface() } }
    private var shapeExpansion: CGFloat = 0
    private var transitionTimer: Timer?
    private var transitionDestination: NSSize?
    private var tabTimer: Timer?
    private var hoveredPoint = NSPoint(x: -1, y: -1)
    private var lastTrackGesture = Date.distantPast
    private var compactClockTimer: Timer?
    private var visualizerTimer: Timer?
    private var barHeights: [CGFloat] = [4, 7, 5, 4]
    private var traySurface: TrayView!
    private var brightnessSlider: LevelSliderView!
    private var volumeSlider: LevelSliderView!
    private var hudLevel: Double = 0
    private var hudTimer: Timer?

    init(frame: NSRect, model: SystemMonitor) {
        self.model = model
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Notch \(TabTitles.home)")
        brightnessSlider = LevelSliderView(control: model.brightnessControl, brightness: true, name: { [weak model] in model?.brightnessControl.name ?? "Display" })
        volumeSlider = LevelSliderView(control: model.volumeControl, brightness: false, name: { [weak model] in model?.volumeControl.name ?? "Output" }, mute: { [weak model] in model?.volumeControl.toggleMute() })
        addSubview(brightnessSlider); addSubview(volumeSlider)
        traySurface = TrayView(model: model)
        traySurface.onSettings = { [weak self] in self?.onTraySettings?() }
        traySurface.onRequestFocus = { [weak self] view in self?.onTrayFocus?(view) }
        addSubview(traySurface)
        updateControlsSurface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var shapeRect: NSRect { NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height) }
    var shapePath: NSBezierPath { NotchGeometry.path(in: shapeRect, top: topRadius, bottom: bottomRadius) }
    var isCompact: Bool { activity != nil || (model.musicEnabled && model.nowPlaying.isAvailable) }

    func configure(notch: NSSize) {
        notchSize = notch
        expandedSize = NotchGeometry.expandedSize(notch: notch)
        transition(animated: false)
    }
    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        onExpansionChange?(value)
    }
    func refresh() {
        if !model.controlsEnabled && selectedTab == .controls { selectedTab = .nook }
        transition(animated: true)
        updateControlsSurface()
        needsDisplay = true
    }
    func containsShapePoint(_ point: NSPoint) -> Bool { shapePath.contains(point) }
    func triggersHover(at point: NSPoint) -> Bool {
        if expanded { return containsShapePoint(point) }
        // The hardware camera area can be unreachable by the pointer. A small
        // hover-only margin below it opens the shape without intercepting clicks.
        return NSRect(x: bounds.midX - notchSize.width / 2 - 8, y: 0, width: notchSize.width + 16, height: notchSize.height + 8).contains(point)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { containsShapePoint(point) ? (super.hitTest(point) ?? self) : nil }
    func wantsNativeMouse(at point: NSPoint) -> Bool {
        if expanded && selectedTab == .tray && traySurface.frame.contains(point) { return true }
        return expanded && selectedTab == .controls && model.controlsEnabled && (brightnessSlider.frame.contains(point) || volumeSlider.frame.contains(point))
    }
    override func mouseDown(with event: NSEvent) { handleClick(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        hoveredPoint = convert(event.locationInWindow, from: nil)
        toolTip = model.weatherEnabled && weatherChipRect.contains(hoveredPoint) ? "Weather data by Open-Meteo.com (CC BY 4.0)" : model.controlsEnabled && controlsRect.contains(hoveredPoint) ? "Controls (Brightness/Volume)" : nil
        needsDisplay = true
    }

    func transition(animated: Bool) {
        model.setTrayVisible(expanded && selectedTab == .tray)
        let compact = isCompact && !expanded
        let isHUD = activity?.kind == .volume || activity?.kind == .brightness
        model.setIslandState(expanded: expanded, controlsVisible: expanded && selectedTab == .controls && model.controlsEnabled, hudVisible: compact && isHUD)
        model.setMediaVisible((expanded && selectedTab == .nook) || compact)
        if compact, activity == nil, model.nowPlaying.isPlaying {
            if visualizerTimer == nil {
                visualizerTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.barHeights = (0..<4).map { _ in CGFloat.random(in: 4...14) }
                        self?.needsDisplay = true
                    }
                }
            }
        } else { visualizerTimer?.invalidate(); visualizerTimer = nil; barHeights = [4, 4, 4, 4] }
        let target = expanded ? expandedSize : NSSize(width: notchSize.width + (compact ? (isHUD ? 144 : 128) : 0), height: notchSize.height)
        let targetTop: CGFloat = expanded ? 20 : 6
        let targetBottom: CGFloat = expanded ? 26 : 14
        if compact, compactClockTimer == nil {
            compactClockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        } else if !compact {
            compactClockTimer?.invalidate()
            compactClockTimer = nil
        }
        if !animated {
            transitionTimer?.invalidate()
            transitionTimer = nil; transitionDestination = nil
            size = target; topRadius = targetTop; bottomRadius = targetBottom
            contentAlpha = expanded ? 1 : 0; shapeExpansion = expanded ? 1 : 0
            needsDisplay = true
            onGeometryChange?()
            return
        }
        guard target != size || abs(contentAlpha - (expanded ? 1 : 0)) > 0.01 else { return }
        // A model refresh must not restart a transition already heading to this state.
        if transitionTimer != nil {
            if transitionDestination == target { return }
            transitionTimer?.invalidate()
            transitionTimer = nil
        }
        transitionDestination = target
        let initialSize = size, initialTop = topRadius, initialBottom = bottomRadius
        let initialAlpha = contentAlpha, initialExpansion = shapeExpansion
        let opening = expanded
        let delay: Double = !opening && initialAlpha > 0 ? 0.10 : 0
        let started = Date()
        transitionTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(started)
            let t = max(0, (elapsed - delay) / 0.42)
            let omega = 2 * Double.pi / 0.42, damping = 0.82
            let s = max(0, min(1.015, 1 - exp(-damping * omega * max(0, elapsed - delay)) *
                (cos(omega * sqrt(1 - damping * damping) * max(0, elapsed - delay)) +
                 damping / sqrt(1 - damping * damping) * sin(omega * sqrt(1 - damping * damping) * max(0, elapsed - delay)))))
            let progress = CGFloat(t >= 1.5 ? 1 : s)
            self.size = NSSize(width: initialSize.width + (target.width - initialSize.width) * progress,
                               height: initialSize.height + (target.height - initialSize.height) * progress)
            self.topRadius = initialTop + (targetTop - initialTop) * progress
            self.bottomRadius = initialBottom + (targetBottom - initialBottom) * progress
            self.shapeExpansion = initialExpansion + ((opening ? 1 : 0) - initialExpansion) * progress
            self.contentAlpha = opening ? CGFloat(min(1, max(0, (elapsed - 0.22) / 0.18))) : initialAlpha * CGFloat(max(0, 1 - elapsed / 0.10))
            self.needsDisplay = true
            self.onGeometryChange?()
            if t >= 1.5 {
                timer.invalidate(); self.transitionTimer = nil; self.transitionDestination = nil
                self.size = target; self.topRadius = targetTop; self.bottomRadius = targetBottom
                self.contentAlpha = opening ? 1 : 0; self.shapeExpansion = opening ? 1 : 0
                self.transition(animated: true)
            }
        }
        RunLoop.main.add(transitionTimer!, forMode: .common)
    }

    private var dashboardOrigin: CGFloat { (bounds.width - expandedSize.width) / 2 }
    private var nookRect: NSRect { NSRect(x: dashboardOrigin + 34, y: (notchSize.height - 24) / 2, width: 60, height: 24) }
    private var trayRect: NSRect { NSRect(x: nookRect.maxX + 6, y: nookRect.minY, width: 56, height: 24) }
    private var gearRect: NSRect { NSRect(x: dashboardOrigin + expandedSize.width - 58, y: (notchSize.height - 24) / 2, width: 24, height: 24) }
    var controlsRect: NSRect {
        let x = bounds.midX + notchSize.width / 2 + 8
        let end = model.weatherEnabled && model.weather != nil ? weatherChipRect.minX : gearRect.minX
        return NSRect(x: x, y: (notchSize.height - 24) / 2, width: max(24, min(82, end - x - 6)), height: 24)
    }
    var weatherChipRect: NSRect { NSRect(x: gearRect.minX - 62, y: (notchSize.height - 22) / 2, width: 54, height: 22) }

    func handleClick(at point: NSPoint) {
        guard containsShapePoint(point) else { return }
        if !expanded {
            if let item = activity?.trayItem { select(.tray); traySurface.highlight(item.id) }
            pinned = true; setExpanded(true); return
        }
        if nookRect.contains(point) { select(.nook); return }
        if trayRect.contains(point) { select(.tray); return }
        if model.controlsEnabled && controlsRect.contains(point) { select(.controls); return }
        if gearRect.contains(point) { onSettings?(); return }
        if model.weatherEnabled, model.weather != nil, weatherChipRect.contains(point) { onWeatherSettings?(); return }
        if selectedTab == .controls { return }
        if selectedTab == .tray { return }
        let mediaX = dashboardOrigin + 34
        let calendarRect = NSRect(x: mediaX + 208, y: notchSize.height + 51, width: expandedSize.width - 276, height: 43)
        if calendarRect.contains(point) {
            if !model.calendarEnabled || model.calendarAccess != .authorized { model.requestCalendarAccess() }
            else { model.openCalendar() }
            return
        }
        let controlsY = notchSize.height + 65
        if model.musicEnabled && model.nowPlaying.isAvailable {
            let seekRect = NSRect(x: mediaX + 12, y: notchSize.height + 54, width: 152, height: 14)
            if seekRect.contains(point), model.nowPlaying.duration > 0 {
                model.seekMedia(to: max(0, min(1, (point.x - seekRect.minX) / seekRect.width)) * model.nowPlaying.duration)
                return
            }
            for (index, command) in ["previous", "toggle", "next"].enumerated() {
                if NSRect(x: mediaX + CGFloat(index) * 48 + 12, y: controlsY - 4, width: 36, height: 28).contains(point) {
                    model.mediaCommand(command); return
                }
            }
        }
        if point.y < notchSize.height { pinned = false; setExpanded(false) }
    }
    private func select(_ tab: IslandTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab; contentAlpha = 0
        model.setTrayVisible(expanded && tab == .tray)
        model.setIslandState(expanded: expanded, controlsVisible: expanded && tab == .controls, hudVisible: false)
        model.setMediaVisible(expanded && tab == .nook)
        tabTimer?.invalidate()
        let start = Date()
        tabTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.contentAlpha = min(1, Date().timeIntervalSince(start) / 0.15)
            self.needsDisplay = true
            if self.contentAlpha >= 1 { timer.invalidate(); self.tabTimer = nil }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), abs(event.scrollingDeltaX) > 6,
           Date().timeIntervalSince(lastTrackGesture) > 0.5 {
            lastTrackGesture = Date()
            if selectedTab == .nook, model.nowPlaying.isAvailable { model.mediaCommand(event.scrollingDeltaX > 0 ? "previous" : "next") }
            else {
                let tabs: [IslandTab] = model.controlsEnabled ? [.nook, .tray, .controls] : [.nook, .tray]
                let index = tabs.firstIndex(of: selectedTab) ?? 0
                select(tabs[(index + 1) % tabs.count])
            }
        } else if event.scrollingDeltaY < -4 { pinned = true; setExpanded(true) }
        else if event.scrollingDeltaY > 4 { pinned = false; setExpanded(false) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        let path = shapePath
        if shapeExpansion > 0.01 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45 * min(1, shapeExpansion))
            shadow.shadowBlurRadius = 14; shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set(); NSColor.black.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.black.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState(); path.addClip()
        if contentAlpha > 0.001 {
            let context = NSGraphicsContext.current!.cgContext
            context.setAlpha(contentAlpha)
            let scale = 0.96 + 0.04 * contentAlpha
            context.translateBy(x: bounds.midX * (1 - scale), y: 0)
            context.scaleBy(x: scale, y: scale)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawHeader()
            if selectedTab == .nook { drawDashboard() }
            context.endTransparencyLayer()
        } else if !expanded && transitionTimer == nil && isCompact { drawCompact() }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHeader() {
        for (rect, title, symbolName, tab) in [(nookRect, TabTitles.home, "house.fill", IslandTab.nook), (trayRect, TabTitles.clipboard, "tray.fill", IslandTab.tray)] {
            if selectedTab == tab || rect.contains(hoveredPoint) {
                NSColor.white.withAlphaComponent(selectedTab == tab ? 0.14 : 0.08).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            }
            let color = NSColor.white.withAlphaComponent(selectedTab == tab ? 1 : 0.55)
            symbol(symbolName, rect: NSRect(x: rect.minX + 8, y: rect.minY + 6, width: 11, height: 11), color: color)
            text(title, rect: NSRect(x: rect.minX + 23, y: rect.minY + 5, width: rect.width - 27, height: 15), size: 11, weight: .semibold, color: color)
        }
        symbol("gearshape.fill", rect: gearRect.insetBy(dx: 6, dy: 6), color: secondary)
        if model.controlsEnabled {
            let rect = controlsRect
            if selectedTab == .controls || rect.contains(hoveredPoint) {
                NSColor.white.withAlphaComponent(selectedTab == .controls ? 0.14 : 0.08).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            }
            let color = NSColor.white.withAlphaComponent(selectedTab == .controls ? 1 : 0.55)
            symbol("slider.horizontal.3", rect: NSRect(x: rect.minX + 7, y: rect.minY + 6, width: 12, height: 12), color: color)
            if rect.width >= 76 { text(TabTitles.controls, rect: NSRect(x: rect.minX + 24, y: rect.minY + 5, width: 56, height: 15), size: 11, weight: .semibold, color: color) }
        }
        if model.weatherEnabled, let weather = model.weather {
            let rect = weatherChipRect
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
            let color = NSColor.white.withAlphaComponent(0.85)
            symbol(weather.systemSymbol, rect: NSRect(x: rect.minX + 8, y: rect.minY + 5, width: 11, height: 11), color: color)
            text("\(weather.temperature)°", rect: NSRect(x: rect.minX + 23, y: rect.minY + 4, width: 28, height: 15), size: 11, weight: .semibold, color: color)
        }
    }

    private func drawDashboard() {
        let x = dashboardOrigin + 34, y = notchSize.height + 8
        let mediaWidth: CGFloat = 188
        let available = model.musicEnabled && model.nowPlaying.isAvailable
        let artRect = NSRect(x: x, y: y, width: 44, height: 44)
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: artRect, xRadius: 9, yRadius: 9).fill()
        if available, let art = model.artwork {
            drawArtwork(art, in: artRect, radius: 9)
        } else { symbol("music.note", rect: artRect.insetBy(dx: 13, dy: 13), color: tertiary) }
        text(available ? model.nowPlaying.title : "Not Playing", rect: NSRect(x: x + 52, y: y + 3, width: 132, height: 18), size: 13, weight: .semibold)
        text(available ? model.nowPlaying.artist : "Play audio in any app", rect: NSRect(x: x + 52, y: y + 24, width: 132, height: 16), size: 11, color: secondary)
        if available, let icon = model.nowPlaying.appIcon {
            icon.draw(in: NSRect(x: x + 32, y: y + 32, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if available && model.nowPlaying.duration > 0 {
            progress(model.nowPlaying.elapsed / model.nowPlaying.duration, rect: NSRect(x: x + 12, y: y + 53, width: 152, height: 3))
        }
        for (index, name) in ["backward.fill", available && model.nowPlaying.isPlaying ? "pause.fill" : "play.fill", "forward.fill"].enumerated() {
            let width: CGFloat = index == 1 ? 17 : 14
            symbol(name, rect: NSRect(x: x + CGFloat(index) * 48 + 22, y: notchSize.height + 68, width: width, height: 17), color: available ? .white : tertiary)
        }
        let calendarX = x + mediaWidth + 20
        let calendarWidth = expandedSize.width - 68 - mediaWidth - 20
        drawCalendar(x: calendarX, y: y, width: calendarWidth)
    }

    private func drawCalendar(x: CGFloat, y: CGFloat, width: CGFloat) {
        let calendar = Calendar.current, today = Date()
        let formatter = DateFormatter(); formatter.dateFormat = "MMM"
        text(formatter.string(from: today), rect: NSRect(x: x, y: y + 4, width: 30, height: 17), size: 13, weight: .semibold)
        let start = x + 34, cell = (width - 34) / 7
        let weekday = DateFormatter(); weekday.dateFormat = "EEEEE"
        for index in 0..<7 {
            let date = calendar.date(byAdding: .day, value: index - 3, to: today)!
            let cx = start + CGFloat(index) * cell
            text(weekday.string(from: date), rect: NSRect(x: cx, y: y, width: cell, height: 13), size: 9, color: NSColor.white.withAlphaComponent(0.4), alignment: .center)
            if index == 3 {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx + (cell - 22) / 2, y: y + 16, width: 22, height: 22)).fill()
            }
            text(String(calendar.component(.day, from: date)), rect: NSRect(x: cx, y: y + 20, width: cell, height: 15), size: 11, weight: .medium, alignment: .center, digits: true)
        }
        if model.calendarEnabled && model.calendarAccess != .authorized {
            let button = NSRect(x: x, y: y + 50, width: min(width, 172), height: 25)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: button, xRadius: 12.5, yRadius: 12.5).fill()
            text(model.calendarAccess.actionTitle, rect: button.offsetBy(dx: 0, dy: 5), size: 11, weight: .medium, alignment: .center)
        } else if model.calendarEnabled {
            let events = model.todayEvents.prefix(2)
            if events.isEmpty {
                symbol("calendar", rect: NSRect(x: x + 20, y: y + 59, width: 11, height: 11), color: tertiary)
                text("Nothing for today", rect: NSRect(x: x + 37, y: y + 56, width: width - 37, height: 17), size: 11, color: secondary)
            } else {
                for (index, event) in events.enumerated() {
                    let rowY = y + 49 + CGFloat(index) * 18
                    (NSColor(cgColor: event.calendar.cgColor) ?? .white).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: rowY + 2, width: 3, height: 13), xRadius: 1.5, yRadius: 1.5).fill()
                    text(event.title ?? "Event", rect: NSRect(x: x + 9, y: rowY, width: width - 107, height: 16), size: 11, weight: .semibold)
                    let time = event.isAllDay ? "All day" : DateFormatter.localizedString(from: event.startDate, dateStyle: .none, timeStyle: .short) + "–" + DateFormatter.localizedString(from: event.endDate, dateStyle: .none, timeStyle: .short)
                    text(time, rect: NSRect(x: x + width - 94, y: rowY + 1, width: 94, height: 15), size: 10, color: secondary, alignment: .right)
                }
            }
        } else {
            text("Calendar is off", rect: NSRect(x: x, y: y + 57, width: width, height: 17), size: 11, color: secondary, alignment: .center)
        }
    }

    private func drawCompact() {
        let rect = shapeRect, gapLeft = bounds.midX - notchSize.width / 2, gapRight = bounds.midX + notchSize.width / 2
        let iconY = (notchSize.height - 12) / 2
        if let activity, let level = activity.progress, activity.kind == .volume || activity.kind == .brightness {
            let name = activity.kind == .volume ? LevelSliderView.volumeSymbol(level: level, muted: model.volumeControl.isMuted) : (level < 0.34 ? "sun.min.fill" : "sun.max.fill")
            symbol(name, rect: NSRect(x: gapLeft - 43, y: (notchSize.height - 14) / 2, width: 14, height: 14), color: .white)
            let bar = NSRect(x: gapRight + 10, y: notchSize.height / 2 - 3, width: 52, height: 6)
            NSColor.white.withAlphaComponent(0.2).setFill(); NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).addClip()
            NSColor.white.withAlphaComponent(0.95).setFill(); NSRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(hudLevel), height: bar.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if let item = activity?.trayItem {
            let thumb = NSRect(x: gapLeft - 40, y: (notchSize.height - 22) / 2, width: 22, height: 22)
            if let image = TrayThumbnailCache.shared.image(item) { drawArtwork(image, in: thumb, radius: 6) }
            else { symbol("camera.viewfinder", rect: thumb.insetBy(dx: 3, dy: 3), color: .white) }
            text("Saved", rect: NSRect(x: gapRight + 14, y: (notchSize.height - 16) / 2, width: 42, height: 16), size: 11, weight: .medium)
        } else if activity == nil, model.musicEnabled, model.nowPlaying.isAvailable {
            let artworkRect = NSRect(x: gapLeft - 40, y: (notchSize.height - 22) / 2, width: 22, height: 22)
            if let art = model.artwork { drawArtwork(art, in: artworkRect, radius: 6) }
            else { symbol("music.note", rect: artworkRect.insetBy(dx: 4, dy: 4), color: .white) }
            NSColor.white.setFill()
            for (index, height) in barHeights.enumerated() {
                let bar = NSRect(x: gapRight + 22 + CGFloat(index) * 4.5, y: (notchSize.height - height) / 2, width: 2.5, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
            }
        } else {
            let formatter = DateFormatter(); formatter.dateFormat = "h:mm"
            text(formatter.string(from: Date()), rect: NSRect(x: rect.minX + 12, y: iconY - 1, width: gapLeft - rect.minX - 16, height: 16), size: 12, weight: .semibold, digits: true)
            let color: NSColor = model.isCharging ? .systemGreen : .white
            symbol(model.isCharging ? "battery.100.bolt" : "battery.100", rect: NSRect(x: gapRight + 6, y: iconY, width: 15, height: 12), color: color)
            text(model.batteryPercent.map { "\($0)%" } ?? "—", rect: NSRect(x: gapRight + 25, y: iconY, width: 34, height: 15), size: 11, weight: .medium, color: color, digits: true)
        }
    }

    private var secondary: NSColor { .white.withAlphaComponent(0.55) }
    private func updateControlsSurface() {
        guard let brightnessSlider, let volumeSlider, let traySurface else { return }
        let trayFrame = NSRect(x: (bounds.width - (expandedSize.width - 68)) / 2, y: notchSize.height + 4, width: expandedSize.width - 68, height: 90)
        if traySurface.frame != trayFrame { traySurface.frame = trayFrame }
        traySurface.isHidden = selectedTab != .tray || contentAlpha <= 0.001
        traySurface.alphaValue = contentAlpha
        if !traySurface.isHidden { traySurface.refresh() }
        if selectedTab != .tray || !expanded { onTrayFocus?(nil) }
        let width = min(472, expandedSize.width - 68)
        let sliderWidth = (width - 12) / 2
        let left = NSRect(x: bounds.midX - width / 2, y: notchSize.height + 8, width: sliderWidth, height: 76)
        let right = left.offsetBy(dx: sliderWidth + 12, dy: 0)
        if brightnessSlider.frame != left { brightnessSlider.frame = left }
        if volumeSlider.frame != right { volumeSlider.frame = right }
        for slider in [brightnessSlider, volumeSlider] {
            slider.isHidden = selectedTab != .controls || !model.controlsEnabled || contentAlpha <= 0.001
            slider.alphaValue = contentAlpha
            slider.needsDisplay = true
        }
    }
    private func animateHUDFill() {
        hudTimer?.invalidate(); hudTimer = nil
        guard let activity, activity.kind == .volume || activity.kind == .brightness, let target = activity.progress else { hudLevel = 0; return }
        let initial = hudLevel, started = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(started) / 0.12)
            self.hudLevel = initial + (max(0, min(1, target)) - initial) * (1 - pow(1 - t, 3))
            self.needsDisplay = true
            if t == 1 { timer.invalidate(); self.hudTimer = nil }
        }
        hudTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func drawArtwork(_ image: NSImage, in rect: NSRect, radius: CGFloat) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let destination = NSRect(x: rect.midX - image.size.width * scale / 2, y: rect.midY - image.size.height * scale / 2, width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    private var tertiary: NSColor { .white.withAlphaComponent(0.30) }
    private func symbol(_ name: String, rect: NSRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)) else { return }
        let tinted = NSImage(size: rect.size, flipped: true) { bounds in
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            color.setFill(); bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private func progress(_ value: Double, rect: NSRect) {
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        if value > 0 {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * min(1, max(0, value)), height: rect.height), xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        }
    }
    private func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white, alignment: NSTextAlignment = .left, digits: Bool = false) {
        let clean = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let style = NSMutableParagraphStyle(); style.alignment = alignment; style.lineBreakMode = .byTruncatingTail
        let original = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let width = (clean as NSString).size(withAttributes: [.font: original]).width
        let pointSize = size * max(0.85, min(1, rect.width / max(1, width)))
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: weight) : NSFont.systemFont(ofSize: pointSize, weight: weight)
        (clean as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}
