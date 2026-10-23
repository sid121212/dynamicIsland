import AppKit
import Quartz
import UniformTypeIdentifiers

final class TrayThumbnailCache {
    static let shared = TrayThumbnailCache()
    private let images = NSCache<NSURL, NSImage>()
    init() { images.totalCostLimit = 12 * 1024 * 1024; images.countLimit = 100 }
    func image(_ item: TrayItem) -> NSImage? {
        guard let url = item.thumbnailURL else { return nil }
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: url as NSURL, cost: 192 * 192 * 4); return image
    }
}

enum TrayFilter: String, CaseIterable {
    case all = "All", images = "Images", text = "Text", files = "Files"
    func includes(_ item: TrayItem) -> Bool {
        switch self {
        case .all: return true
        case .images: return item.kind == .image || item.kind == .screenshot || item.thumbnailURL != nil
        case .text: return item.kind == .text
        case .files: return item.kind == .file
        }
    }
}

final class TrayView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let model: SystemMonitor
    private let store: TrayStore
    private let scroll = NSScrollView()
    private let document = NSView()
    private var filter: TrayFilter = .all
    private var cards: [UUID: TrayCard] = [:]
    private var displayed: [TrayItem] = []
    private var renderedLoadedState = false
    private var selected: TrayItem?
    var onSettings: (() -> Void)?
    var onRequestFocus: ((NSView) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: SystemMonitor, store: TrayStore? = nil) {
        self.model = model; self.store = store ?? model.trayStore
        super.init(frame: .zero)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        scroll.documentView = document; addSubview(scroll)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 20, width: bounds.width, height: 66)
        document.setFrameSize(NSSize(width: max(bounds.width, CGFloat(displayed.count) * 104 - 8), height: 66))
        scroll.layer?.mask?.frame = scroll.bounds
    }
    func refresh() {
        // Manual AppKit frames must be ready before assigning the clipping mask.
        layout()
        let animateNew = renderedLoadedState
        if store.loaded { renderedLoadedState = true }
        let next = store.items.filter { filter.includes($0) }
        if next != displayed {
            let oldIDs = Set(displayed.map(\.id)); displayed = next
            let previousCards = cards
            document.subviews.forEach { $0.removeFromSuperview() }; cards = [:]
            document.frame = NSRect(x: 0, y: 0, width: max(bounds.width, CGFloat(next.count) * 104 - 8), height: 66)
            for (i, item) in next.enumerated() {
                let card = previousCards[item.id]?.item == item ? previousCards[item.id]! : TrayCard(item: item, owner: self)
                card.frame = NSRect(x: CGFloat(i) * 104, y: 0, width: 96, height: 66)
                document.addSubview(card); cards[item.id] = card
                if !oldIDs.contains(item.id), animateNew {
                    let animation = CASpringAnimation(keyPath: "transform.translation.x")
                    animation.fromValue = -24; animation.toValue = 0; animation.mass = 1
                    animation.stiffness = pow(2 * .pi / 0.35, 2); animation.damping = 2 * 0.85 * sqrt(animation.stiffness)
                    animation.duration = animation.settlingDuration; card.layer?.add(animation, forKey: "arrival")
                }
            }
            if let selected, !next.contains(where: { $0.id == selected.id }) {
                self.selected = nil
                if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }
            }
        }
        scroll.isHidden = next.isEmpty
        // A transparent fade at the trailing edge preserves the standard black body.
        let mask = CAGradientLayer(); mask.frame = scroll.bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5); mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]; mask.locations = [0, 0.94, 1]
        scroll.wantsLayer = true; scroll.layer?.mask = mask
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if displayed.isEmpty {
            if let error = store.error {
                label("Tray unavailable", rect: NSRect(x: 0, y: 29, width: bounds.width, height: 17), size: 13, weight: .semibold)
                label(error, rect: NSRect(x: 10, y: 49, width: bounds.width - 20, height: 28), size: 10, alpha: 0.55)
            } else {
                drawSymbol("tray", rect: NSRect(x: bounds.midX - 11, y: 22, width: 22, height: 22), alpha: 0.3)
                label("Nothing here yet", rect: NSRect(x: 0, y: 46, width: bounds.width, height: 17), size: 13, weight: .semibold)
                label(model.clipboard.denied ? "Allow clipboard access in Tray Settings" : (model.clipboardEnabled || model.screenshotsEnabled ? "Copy something · camera enables saved screenshots" : "Capture paused · enable clipboard or camera above"), rect: NSRect(x: 0, y: 66, width: bounds.width, height: 15), size: 11, alpha: 0.55)
            }
        }
        var x: CGFloat = 0
        for value in TrayFilter.allCases {
            let width: CGFloat = value == .images ? 49 : 39
            if filter == value { NSColor.white.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: 16), xRadius: 8, yRadius: 8).fill() }
            label(value.rawValue, rect: NSRect(x: x, y: 1, width: width, height: 14), size: 10, weight: .medium, alpha: filter == value ? 1 : 0.55)
            x += width + 3
        }
        let captureX = bounds.width - 224
        drawSymbol(model.clipboardEnabled ? "doc.on.clipboard.fill" : "doc.on.clipboard", rect: NSRect(x: captureX, y: 1, width: 14, height: 14), alpha: model.clipboardEnabled ? 0.9 : 0.3)
        drawSymbol("camera", rect: NSRect(x: captureX + 28, y: 1, width: 15, height: 14), alpha: model.screenshotsEnabled ? 0.9 : 0.3)
        label("\(store.items.count)", rect: NSRect(x: bounds.width - 104, y: 1, width: 24, height: 14), size: 10, alpha: 0.55)
        label("Clear", rect: NSRect(x: bounds.width - 76, y: 1, width: 32, height: 14), size: 10, alpha: 0.55)
        drawSymbol("ellipsis.circle", rect: NSRect(x: bounds.width - 22, y: 1, width: 14, height: 14), alpha: 0.55)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 18 {
            let captureX = bounds.width - 224
            if NSRect(x: captureX - 4, y: 0, width: 24, height: 18).contains(point) { model.clipboardEnabled.toggle(); refresh(); return }
            if NSRect(x: captureX + 24, y: 0, width: 24, height: 18).contains(point) {
                if !model.screenshotsEnabled { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
                model.screenshotsEnabled.toggle(); refresh(); return
            }
            if NSRect(x: bounds.width - 28, y: 0, width: 28, height: 18).contains(point) { onSettings?(); return }
            if NSRect(x: bounds.width - 80, y: 0, width: 40, height: 18).contains(point) { store.clear(); return }
            var x: CGFloat = 0
            for value in TrayFilter.allCases {
                let width: CGFloat = value == .images ? 49 : 39
                if NSRect(x: x, y: 0, width: width, height: 18).contains(point) { filter = value; displayed = []; refresh(); return }
                x += width + 3
            }
        } else if model.clipboard.denied { onSettings?() }
        focus()
    }
    func highlight(_ id: UUID) {
        filter = .all; refresh()
        if let item = displayed.first(where: { $0.id == id }), let card = cards[id] { select(item); card.scrollToVisible(card.bounds); card.flash() }
    }
    private func focus() { onRequestFocus?(self) }
    func select(_ item: TrayItem) { selected = item; focus() }
    func copy(_ item: TrayItem, card: TrayCard) {
        select(item)
        model.clipboard.copy(item) { [weak card] success in if success { card?.flash() } }
    }
    func pin(_ item: TrayItem) { store.togglePin(item) }
    func delete(_ item: TrayItem) { store.delete(item) }
    func preview(_ item: TrayItem) {
        selected = item; focus()
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        QLPreviewPanel.shared()?.updateController(); QLPreviewPanel.shared()?.makeKeyAndOrderFront(self)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, let selected { preview(selected) }
        else if event.keyCode == 53 { QLPreviewPanel.shared()?.orderOut(nil) }
        else { super.keyDown(with: event) }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { selected?.fileURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self; panel.reloadData() }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil; restoreAccessory() }
    func windowWillClose(_ notification: Notification) { restoreAccessory() }
    private func restoreAccessory() {
        DispatchQueue.main.async { if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) } }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selected == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { selected?.fileURL as NSURL? }
    func save(_ item: TrayItem) {
        guard let source = item.fileURL else { return }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.displayName
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.begin { response in
            defer { self.restoreAccessory() }
            guard response == .OK, let target = panel.url else { return }
            Task {
                let message = await Task.detached(priority: .utility) { () -> String? in
                    let temporary = target.deletingLastPathComponent().appendingPathComponent(".dynamic-island-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    do {
                        try FileManager.default.copyItem(at: source, to: temporary)
                        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
                        else { try FileManager.default.moveItem(at: temporary, to: target) }
                        return nil
                    } catch { return error.localizedDescription }
                }.value
                if let message { let alert = NSAlert(); alert.messageText = "Could not save Tray item"; alert.informativeText = message; alert.runModal() }
            }
        }
    }
}

final class TrayCard: NSView, NSDraggingSource {
    let item: TrayItem
    private weak var owner: TrayView?
    private var hovered = false
    private var down = NSPoint.zero
    private var dragging = false
    private var actionClick = false
    private var flashed = false
    private var flashTimer: Timer?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(item: TrayItem, owner: TrayView) {
        self.item = item; self.owner = owner; super.init(frame: .zero); wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(item.kind == .text ? "Clipboard text" : item.displayName)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func flash() { flashed = true; needsDisplay = true; flashTimer?.invalidate(); flashTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.flashed = false; self?.needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.white.withAlphaComponent(0.07).setFill(); path.fill()
        if let image = TrayThumbnailCache.shared.image(item) {
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            image.draw(in: NSRect(x: bounds.midX - image.size.width * scale / 2, y: bounds.midY - image.size.height * scale / 2, width: image.size.width * scale, height: image.size.height * scale), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: NSRect(x: 5, y: 45, width: 22, height: 17), xRadius: 8, yRadius: 8).fill()
            drawSymbol(item.kind == .screenshot ? "camera.viewfinder" : "photo", rect: NSRect(x: 9, y: 48, width: 14, height: 11))
        } else if item.kind == .text {
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
            ((item.text ?? "") as NSString).draw(in: NSRect(x: 8, y: item.pinned ? 18 : 7, width: 80, height: item.pinned ? 26 : 38), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: style])
            if let id = item.sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 8, y: 49, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        } else {
            if let url = item.fileURL { NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 34, y: 11, width: 28, height: 28), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle; style.alignment = .center
            (item.displayName as NSString).draw(in: NSRect(x: 5, y: 46, width: 86, height: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.white, .paragraphStyle: style])
        }
        if item.pinned { drawSymbol("pin.fill", rect: NSRect(x: 5, y: 4, width: 9, height: 9)) }
        if hovered {
            for (i, name) in ["doc.on.doc", "pin", "trash"].enumerated() {
                let rect = NSRect(x: 34 + CGFloat(i) * 20, y: 3, width: 18, height: 18)
                NSColor.black.withAlphaComponent(0.4).setFill(); NSBezierPath(ovalIn: rect).fill()
                NSColor.white.withAlphaComponent(0.14).setFill(); NSBezierPath(ovalIn: rect).fill()
                drawSymbol(name, rect: rect.insetBy(dx: 4, dy: 4))
            }
        }
        if flashed { NSColor.black.withAlphaComponent(0.55).setFill(); path.fill(); drawSymbol("checkmark", rect: NSRect(x: 38, y: 23, width: 20, height: 20)) }
    }
    override func mouseDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil); dragging = false; actionClick = false
        owner?.select(item)
        if hovered, down.y <= 22, down.x >= 34 {
            actionClick = true
            switch Int((down.x - 34) / 20) { case 0: owner?.copy(item, card: self); case 1: owner?.pin(item); default: owner?.delete(item) }
        } else if event.clickCount == 2 { actionClick = true; owner?.preview(item) }
    }
    override func mouseUp(with event: NSEvent) { if !dragging && !actionClick { owner?.copy(item, card: self) } }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !dragging, !actionClick, hypot(point.x - down.x, point.y - down.y) > 4, let url = item.fileURL else { return }
        dragging = true
        let drag = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = TrayThumbnailCache.shared.image(item) ?? NSWorkspace.shared.icon(forFile: url.path)
        drag.setDraggingFrame(bounds, contents: image); beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copyItem)), (item.pinned ? "Unpin" : "Pin", #selector(pinItem)), ("Quick Look", #selector(previewItem)), ("Save to Desktop…", #selector(saveItem)), ("Reveal in Finder", #selector(revealItem)), ("Delete", #selector(deleteItem))] {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); entry.target = self
        }
        return menu
    }
    @objc private func copyItem() { owner?.copy(item, card: self) }
    @objc private func pinItem() { owner?.pin(item) }
    @objc private func deleteItem() { owner?.delete(item) }
    @objc private func previewItem() { owner?.preview(item) }
    @objc private func saveItem() { owner?.save(item) }
    @objc private func revealItem() { if let url = item.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
}

private func label(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1) {
    let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: style])
}
private func drawSymbol(_ name: String, rect: NSRect, alpha: CGFloat = 1) {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: rect.height, weight: .medium)) else { return }
    let tinted = NSImage(size: rect.size, flipped: true) { bounds in
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.white.setFill(); bounds.fill(using: .sourceAtop); return true
    }
    tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
}
