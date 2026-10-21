import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    precondition(condition(), description)
}

let notch = NSSize(width: 186, height: 32)
let expanded = NotchGeometry.expandedSize(notch: notch)
check(abs(expanded.width - 539.4) < 0.01, "Expanded width must follow hardware notch size")
check(expanded.height == 134, "Expanded body must be notch height plus 102")
check(NotchGeometry.expandedSize(notch: NSSize(width: 120, height: 32)).width == 500, "Width lower bound")
check(NotchGeometry.expandedSize(notch: NSSize(width: 250, height: 38)).width == 560, "Width upper bound")

let model = SystemMonitor(preview: true)
let view = IslandView(frame: NSRect(x: 0, y: 0, width: expanded.width + 40, height: expanded.height + 40), model: model)
view.configure(notch: notch)
let host = NSWindow(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
host.contentView = view
view.onExpansionChange = { _ in view.transition(animated: true) }
let hostSize = host.frame.size

func run(_ duration: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
}

check(view.shapeRect.width == notch.width && view.shapeRect.height == notch.height, "Idle matches hardware notch exactly")
check(view.shapeRect.minY == 0, "Idle is flush with top edge")
view.setExpanded(true)
for _ in 0..<14 {
    run(0.05)
    check(view.shapeRect.minY == 0, "Expansion must never drift below screen top")
    check(host.frame.size == hostSize, "Hosting window must not resize with the shape")
}
check(abs(view.shapeRect.height - expanded.height) < 0.01, "Expansion settles to shallow body")
check(abs(view.shapeRect.width - expanded.width) < 0.01, "Expansion settles to hardware-derived width")
let rect = view.shapeRect
check(!view.containsShapePoint(NSPoint(x: rect.minX + 2, y: 40)), "Transparent side margin must pass clicks through")
check(view.containsShapePoint(NSPoint(x: rect.minX + 22, y: 40)), "Inset vertical wall bounds visible body")
check(view.containsShapePoint(NSPoint(x: rect.minX + 8, y: 1)), "Concave ear flares along top edge")
check(!view.containsShapePoint(NSPoint(x: rect.minX + 8, y: 18)), "Concave ear curves inward below top")
check(view.hitTest(NSPoint(x: 0, y: 100)) == nil, "Shadow padding must not capture menu or app clicks")
check(view.containsShapePoint(NSPoint(x: rect.midX, y: rect.maxY - 1)), "Bottom centre stays filled")

view.setExpanded(false)
run(0.05)
check(abs(view.shapeRect.width - expanded.width) < 0.01, "Collapse must fade content before shrinking")
run(0.75)
check(view.shapeRect.size == notch, "Collapse returns to exact hardware geometry")

view.activity = IslandActivity(kind: .volume, title: "Volume", subtitle: "", progress: 0.5, expiresAt: .distantFuture)
view.transition(animated: true)
run(0.75)
check(view.shapeRect.width == notch.width + 128, "Compact wings must add exactly 64 points per side")
check(view.shapeRect.height == notch.height, "Compact must retain notch height")
check(view.shapeRect.minY == 0, "Compact must remain top attached")
view.activity = nil
view.transition(animated: true)
run(0.75)
check(view.shapeRect.size == notch, "HUD dismissal returns to hardware notch")
print("Passed: geometry, concave ears, hit testing, fixed hosting, animation ordering, compact/HUD regression checks")
