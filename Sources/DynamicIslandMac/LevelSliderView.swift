import AppKit
import QuartzCore

final class LevelSliderView: NSView {
    private let control: any LevelControl
    private let brightness: Bool
    private let deviceName: () -> String
    private let mute: (() -> Void)?
    private var dragging = false
    private var lastWrite = Date.distantPast
    private var previousDragLevel: Double = 0
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(control: any LevelControl, brightness: Bool, name: @escaping () -> String, mute: (() -> Void)? = nil) {
        self.control = control; self.brightness = brightness; deviceName = name; self.mute = mute
        super.init(frame: .zero); wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel(brightness ? "Brightness" : "Volume")
        toolTip = brightness ? "Drag or scroll to change brightness" : "Drag or scroll to change volume; click the speaker to mute"
    }
    required init?(coder: NSCoder) { fatalError() }
    static func fraction(x: CGFloat, width: CGFloat) -> Double { guard width > 0 else { return 0 }; return max(0, min(1, Double(x / width))) }
    static func volumeSymbol(level: Double, muted: Bool) -> String {
        if muted || level == 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        return level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.setAlpha(control.isSupported ? 1 : 0.4)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: 52)
        let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
        NSColor.white.withAlphaComponent(0.12).setFill(); path.fill()
        context.saveGState(); path.addClip()
        NSColor.white.withAlphaComponent(control.isMuted ? 0.3 : 0.92).setFill()
        NSRect(x: 0, y: 0, width: rect.width * CGFloat(control.isSupported ? control.level : 0), height: 52).fill()
        context.restoreGState()
        context.saveGState()
        let symbol = brightness ? "sun.max.fill" : Self.volumeSymbol(level: control.level, muted: control.isMuted)
        drawSymbol(symbol, rect: NSRect(x: 18, y: 18, width: 16, height: 16))
        let value = "\(Int((control.level * 100).rounded()))%" as NSString
        let style = NSMutableParagraphStyle(); style.alignment = .right
        let label = NSImage(size: NSSize(width: 48, height: 18), flipped: true) { bounds in
            value.draw(in: bounds, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style]); return true
        }
        label.draw(in: NSRect(x: rect.width - 62, y: 18, width: 48, height: 18), from: .zero, operation: .difference, fraction: 1, respectFlipped: true, hints: nil)
        context.restoreGState(); context.endTransparencyLayer()
        let caption = control.isSupported ? deviceName() : "Not available on this \(brightness ? "display" : "output")"
        let captionStyle = NSMutableParagraphStyle(); captionStyle.alignment = .center; captionStyle.lineBreakMode = .byTruncatingTail
        (caption as NSString).draw(in: NSRect(x: 0, y: 60, width: bounds.width, height: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.4), .paragraphStyle: captionStyle])
        context.restoreGState()
        setAccessibilityValue(Int(control.level * 100)); setAccessibilityEnabled(control.isSupported)
    }
    private func drawSymbol(_ name: String, rect: NSRect) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold)) else { return }
        let tinted = NSImage(size: rect.size, flipped: true) { bounds in
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSColor.white.setFill(); bounds.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: rect, from: .zero, operation: .difference, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func mouseDown(with event: NSEvent) {
        guard control.isSupported else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.y <= 52 else { return }
        if point.x <= 38, let mute { mute(); needsDisplay = true; return }
        dragging = true; previousDragLevel = control.level; animatePress(true)
        apply(point.x, force: true)
    }
    override func mouseDragged(with event: NSEvent) { if dragging { apply(convert(event.locationInWindow, from: nil).x) } }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        apply(convert(event.locationInWindow, from: nil).x, force: true)
        dragging = false; animatePress(false)
    }
    private func apply(_ x: CGFloat, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastWrite) >= 1.0 / 30 else { return }
        lastWrite = Date()
        let value = Self.fraction(x: x, width: bounds.width)
        control.set(value)
        let previousBucket = Int(previousDragLevel * 4), bucket = Int(value * 4)
        if bucket != previousBucket || (value == 0 && previousDragLevel > 0) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        previousDragLevel = value; needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        guard control.isSupported, event.scrollingDeltaY != 0 else { return }
        control.set(max(0, min(1, control.level + (event.scrollingDeltaY > 0 ? 0.02 : -0.02))))
        needsDisplay = true
    }
    private func animatePress(_ pressed: Bool) {
        guard let layer else { return }
        let target: CGFloat = pressed ? 1.02 : 1
        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.mass = 1; animation.stiffness = pow(2 * .pi / 0.25, 2); animation.damping = 2 * 0.8 * sqrt(animation.stiffness)
        animation.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        animation.toValue = target; animation.duration = animation.settlingDuration
        layer.setValue(target, forKeyPath: "transform.scale"); layer.add(animation, forKey: "press")
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard control.isSupported else { return false }; control.set(min(1, control.level + 0.02)); needsDisplay = true; return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard control.isSupported else { return false }; control.set(max(0, control.level - 0.02)); needsDisplay = true; return true
    }
}
