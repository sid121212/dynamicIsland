import AppKit

enum IslandMetrics {
    static let idleSize = NSSize(width: 200, height: 32)
}

enum IslandTab { case nook, tray }

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
    var onGeometryChange: (() -> Void)?
    private(set) var expanded = false
    var pinned = false
    var timerEnd: Date?
    var activity: IslandActivity? { didSet { needsDisplay = true } }
    private(set) var notchSize = IslandMetrics.idleSize
    private(set) var expandedSize = NotchGeometry.expandedSize(notch: IslandMetrics.idleSize)
    private var selectedTab: IslandTab = .nook
    private var size = IslandMetrics.idleSize
    private var topRadius: CGFloat = 6
    private var bottomRadius: CGFloat = 14
    private var contentAlpha: CGFloat = 0
    private var shapeExpansion: CGFloat = 0
    private var transitionTimer: Timer?
    private var transitionDestination: NSSize?
    private var tabTimer: Timer?
    private var hoveredPoint = NSPoint(x: -1, y: -1)
    private var lastTrackGesture = Date.distantPast
    private var compactClockTimer: Timer?

    init(frame: NSRect, model: SystemMonitor) {
        self.model = model
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Nook island")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var shapeRect: NSRect { NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height) }
    var shapePath: NSBezierPath { NotchGeometry.path(in: shapeRect, top: topRadius, bottom: bottomRadius) }
    var isCompact: Bool { activity != nil || (model.musicEnabled && model.nowPlaying.isAvailable) || timerEnd != nil }

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
        transition(animated: true)
        needsDisplay = true
    }
    func containsShapePoint(_ point: NSPoint) -> Bool { shapePath.contains(point) }
    override func hitTest(_ point: NSPoint) -> NSView? { containsShapePoint(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { handleClick(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        hoveredPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    func transition(animated: Bool) {
        let compact = isCompact && !expanded
        let target = expanded ? expandedSize : NSSize(width: notchSize.width + (compact ? 128 : 0), height: notchSize.height)
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
    private var turnOnRect: NSRect { NSRect(x: bounds.midX - 40, y: notchSize.height + 62, width: 80, height: 24) }

    func handleClick(at point: NSPoint) {
        guard containsShapePoint(point) else { return }
        if !expanded { pinned = true; setExpanded(true); return }
        if nookRect.contains(point) { select(.nook); return }
        if trayRect.contains(point) { select(.tray); return }
        if gearRect.contains(point) { onSettings?(); return }
        if selectedTab == .tray {
            if !model.clipboardEnabled, turnOnRect.contains(point) { model.clipboardEnabled = true; return }
            for index in 0..<min(3, model.clipboardItems.count) {
                if clipboardRow(index).contains(point) { model.copyClipboardItem(at: index); return }
            }
            return
        }
        let mediaX = dashboardOrigin + 34
        let controlsY = notchSize.height + 65
        if model.musicEnabled && model.nowPlaying.isAvailable {
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
        tabTimer?.invalidate()
        let start = Date()
        tabTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.contentAlpha = min(1, Date().timeIntervalSince(start) / 0.15)
            self.needsDisplay = true
            if self.contentAlpha >= 1 { timer.invalidate(); self.tabTimer = nil }
        }
    }

    func renderPreview(state: String, directory: URL) throws {
        transitionTimer?.invalidate(); transitionTimer = nil
        selectedTab = state == "tray" ? .tray : .nook
        if state == "compact" {
            activity = IslandActivity(kind: .notification, title: "Preview", subtitle: "", progress: nil, expiresAt: .distantFuture)
        } else if state == "hud" {
            activity = IslandActivity(kind: .volume, title: "Volume", subtitle: "", progress: 0.65, expiresAt: .distantFuture)
        } else { activity = nil }
        expanded = state == "expanded" || state == "tray" || state == "media"
        transition(animated: false)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = bounds.size
        cacheDisplay(in: bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("\(state)@2x.png"))
        }
        let composite = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        composite.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composite)
        NSColor(calibratedRed: 0.23, green: 0.36, blue: 0.40, alpha: 1).setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        let foreground = NSImage(size: bounds.size); foreground.addRepresentation(bitmap)
        foreground.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        if let png = composite.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("\(state)-wallpaper@2x.png"))
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), abs(event.scrollingDeltaX) > 6,
           Date().timeIntervalSince(lastTrackGesture) > 0.5 {
            lastTrackGesture = Date()
            if selectedTab == .nook, model.nowPlaying.isAvailable { model.mediaCommand(event.scrollingDeltaX > 0 ? "previous" : "next") }
            else { select(selectedTab == .nook ? .tray : .nook) }
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
            if selectedTab == .nook { drawDashboard() } else { drawTray() }
            context.endTransparencyLayer()
        } else if !expanded && transitionTimer == nil && isCompact { drawCompact() }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHeader() {
        for (rect, title, symbolName, tab) in [(nookRect, "Nook", "house.fill", IslandTab.nook), (trayRect, "Tray", "tray.fill", IslandTab.tray)] {
            if selectedTab == tab || rect.contains(hoveredPoint) {
                NSColor.white.withAlphaComponent(selectedTab == tab ? 0.14 : 0.08).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            }
            let color = NSColor.white.withAlphaComponent(selectedTab == tab ? 1 : 0.55)
            symbol(symbolName, rect: NSRect(x: rect.minX + 8, y: rect.minY + 6, width: 11, height: 11), color: color)
            text(title, rect: NSRect(x: rect.minX + 23, y: rect.minY + 5, width: rect.width - 27, height: 15), size: 11, weight: .semibold, color: color)
        }
        symbol("gearshape.fill", rect: gearRect.insetBy(dx: 6, dy: 6), color: secondary)
    }

    private func drawDashboard() {
        let x = dashboardOrigin + 34, y = notchSize.height + 8
        let mediaWidth: CGFloat = 188
        let available = model.musicEnabled && model.nowPlaying.isAvailable
        let artRect = NSRect(x: x, y: y, width: 44, height: 44)
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: artRect, xRadius: 9, yRadius: 9).fill()
        if available, let art = model.artwork {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: artRect, xRadius: 9, yRadius: 9).addClip()
            art.draw(in: artRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else { symbol("music.note", rect: artRect.insetBy(dx: 13, dy: 13), color: tertiary) }
        text(available ? model.nowPlaying.title : "Not Playing", rect: NSRect(x: x + 52, y: y + 3, width: 132, height: 18), size: 13, weight: .semibold)
        text(available ? model.nowPlaying.artist : "Open Music or Spotify", rect: NSRect(x: x + 52, y: y + 24, width: 132, height: 16), size: 11, color: secondary)
        if available, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: model.nowPlaying.source == "Spotify" ? "com.spotify.client" : "com.apple.Music") {
            NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: x + 32, y: y + 32, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if available && model.nowPlaying.duration > 0 {
            progress(model.nowPlaying.position / model.nowPlaying.duration, rect: NSRect(x: x + 12, y: y + 53, width: 152, height: 3))
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
        if model.calendarEnabled {
            let events = model.todayEvents.prefix(2)
            if events.isEmpty {
                symbol("calendar", rect: NSRect(x: x + 20, y: y + 59, width: 11, height: 11), color: tertiary)
                text("Nothing for today", rect: NSRect(x: x + 37, y: y + 56, width: width - 37, height: 17), size: 11, color: secondary)
            } else {
                for (index, event) in events.enumerated() {
                    let rowY = y + 49 + CGFloat(index) * 18
                    (NSColor(cgColor: event.calendar.cgColor) ?? .white).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: rowY + 2, width: 3, height: 13), xRadius: 1.5, yRadius: 1.5).fill()
                    text(event.title ?? "Event", rect: NSRect(x: x + 9, y: rowY, width: width - 53, height: 16), size: 11, weight: .semibold)
                    let time = event.isAllDay ? "All day" : DateFormatter.localizedString(from: event.startDate, dateStyle: .none, timeStyle: .short)
                    text(time, rect: NSRect(x: x + width - 46, y: rowY + 1, width: 46, height: 15), size: 10, color: secondary, alignment: .right)
                }
            }
        } else {
            text("Calendar is off", rect: NSRect(x: x, y: y + 57, width: width, height: 17), size: 11, color: secondary, alignment: .center)
        }
        if model.weatherEnabled, let weather = model.weather {
            symbol(weather.systemSymbol, rect: NSRect(x: x, y: y + 27, width: 10, height: 10), color: secondary)
            text("\(weather.temperature)°", rect: NSRect(x: x + 11, y: y + 25, width: 23, height: 15), size: 10, weight: .medium, color: secondary)
        }
    }

    private func clipboardRow(_ index: Int) -> NSRect {
        NSRect(x: dashboardOrigin + 34, y: notchSize.height + 8 + CGFloat(index) * 27, width: expandedSize.width - 68, height: 23)
    }
    private func drawTray() {
        if !model.clipboardEnabled {
            text("Clipboard History is off", rect: NSRect(x: dashboardOrigin + 34, y: notchSize.height + 8, width: expandedSize.width - 68, height: 18), size: 13, weight: .semibold, alignment: .center)
            text("Turn it on in Settings", rect: NSRect(x: dashboardOrigin + 34, y: notchSize.height + 31, width: expandedSize.width - 68, height: 16), size: 11, color: secondary, alignment: .center)
            NSColor.white.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: turnOnRect, xRadius: 12, yRadius: 12).fill()
            text("Turn On", rect: turnOnRect.offsetBy(dx: 0, dy: 5), size: 11, weight: .semibold, alignment: .center)
        } else if model.clipboardItems.isEmpty {
            text("Copy text to begin", rect: NSRect(x: dashboardOrigin + 34, y: notchSize.height + 38, width: expandedSize.width - 68, height: 18), size: 13, weight: .semibold, alignment: .center)
        } else {
            for (index, value) in model.clipboardItems.prefix(3).enumerated() {
                let rect = clipboardRow(index)
                NSColor.white.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 11.5, yRadius: 11.5).fill()
                symbol("doc.on.clipboard", rect: NSRect(x: rect.minX + 9, y: rect.minY + 6, width: 11, height: 11), color: secondary)
                text(value, rect: NSRect(x: rect.minX + 29, y: rect.minY + 4, width: rect.width - 41, height: 16), size: 11)
            }
        }
    }
    private func drawCompact() {
        let rect = shapeRect, gapLeft = bounds.midX - notchSize.width / 2, gapRight = bounds.midX + notchSize.width / 2
        let iconY = (notchSize.height - 12) / 2
        if let activity, let level = activity.progress, activity.kind == .volume || activity.kind == .brightness {
            symbol(activity.kind == .volume ? "speaker.wave.2.fill" : "sun.max.fill", rect: NSRect(x: rect.minX + 22, y: iconY, width: 14, height: 12), color: .white)
            progress(level, rect: NSRect(x: gapRight + 10, y: notchSize.height / 2 - 2, width: 44, height: 4))
        } else {
            let formatter = DateFormatter(); formatter.dateFormat = "h:mm"
            text(formatter.string(from: Date()), rect: NSRect(x: rect.minX + 12, y: iconY - 1, width: gapLeft - rect.minX - 16, height: 16), size: 12, weight: .semibold, digits: true)
            let color: NSColor = model.isCharging ? .systemGreen : .white
            symbol(model.isCharging ? "battery.100.bolt" : "battery.100", rect: NSRect(x: gapRight + 6, y: iconY, width: 15, height: 12), color: color)
            text(model.batteryPercent.map { "\($0)%" } ?? "—", rect: NSRect(x: gapRight + 25, y: iconY, width: 34, height: 15), size: 11, weight: .medium, color: color, digits: true)
        }
    }

    private var secondary: NSColor { .white.withAlphaComponent(0.55) }
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
