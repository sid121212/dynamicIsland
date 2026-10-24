import AppKit
import EventKit

MainActor.assumeIsolated {

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

check(UpdatePolicy.requiresMovingToApplications("/Volumes/Dynamic Island/Dynamic Island.app"), "DMG runs must be blocked")
check(UpdatePolicy.requiresMovingToApplications("/private/var/folders/test/AppTranslocation/id/d/Dynamic Island.app"), "Translocated runs must be blocked")
check(!UpdatePolicy.requiresMovingToApplications("/Applications/Dynamic Island.app"), "Applications must be allowed")
check(!UpdatePolicy.requiresMovingToApplications("/Users/test/Applications/Dynamic Island.app"), "User Applications must be allowed")
check(!UpdatePolicy.requiresMovingToApplications("/VolumesBackup/Dynamic Island.app"), "Path lookalikes must not trigger the DMG guard")
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
let hoverPoint = NSPoint(x: view.bounds.midX, y: notch.height + 6)
check(view.triggersHover(at: hoverPoint), "Hover must reach below the hardware camera into accessible pointer space")
check(view.hitTest(hoverPoint) == nil, "Hover-only margin must not intercept clicks outside the idle shape")
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
check(view.shapeRect.width == notch.width + 144, "HUD wings must add exactly 72 points per side")
check(view.shapeRect.height == notch.height, "Compact must retain notch height")
check(view.shapeRect.minY == 0, "Compact must remain top attached")
view.activity = nil
view.transition(animated: true)
run(0.75)
check(view.shapeRect.size == notch, "HUD dismissal returns to hardware notch")
// Stream records can split across pipe reads, carry diffs, pause, and become empty.
let media = NowPlayingService()
let record = #"{"type":"data","diff":false,"payload":{"title":"Protocol check","playing":true,"durationMicros":120000000,"elapsedTimeMicros":10000000,"playbackRate":1}}"# + "\n"
let bytes = Data(record.utf8)
media.receive(bytes.prefix(17))
check(!media.state.isAvailable, "Partial JSON must not publish metadata")
media.receive(bytes.dropFirst(17))
check(media.state.title == "Protocol check" && media.state.duration == 120, "Full records use microsecond units")
media.receive(Data((#"{"type":"data","diff":true,"payload":{"playing":false,"elapsedTimeMicros":20000000,"artist":null}}"# + "\n").utf8))
check(media.state.isAvailable && !media.state.isPlaying, "Paused metadata must remain available")
check(media.state.elapsed == 20, "Paused position must not advance locally")
media.receive(Data((#"{"type":"data","diff":false,"payload":{}}"# + "\n").utf8))
check(!media.state.isAvailable, "An empty full payload clears stale metadata")
media.stop()
check(CalendarAccess.notDetermined.actionTitle == "Allow Calendar Access", "Unrequested Calendar must offer access, not an empty events message")
check(CalendarAccess.denied.actionTitle == "Open Settings", "Denied Calendar must offer Settings")
check(CalendarAccess.restricted.actionTitle == "Open Settings", "Restricted Calendar must not claim to be empty")
let eventStore = EKEventStore()
let allDay = EKEvent(eventStore: eventStore); allDay.isAllDay = true; allDay.startDate = Date().addingTimeInterval(3600)
let timed = EKEvent(eventStore: eventStore); timed.isAllDay = false; timed.startDate = Date()
check(CalendarService.precedes(allDay, timed), "All-day events sort before earlier timed events")
let forecast = Data(#"{"current":{"temperature_2m":28.6,"weather_code":2,"is_day":0},"daily":{"temperature_2m_max":[31.2],"temperature_2m_min":[22.1]}}"#.utf8)
let weather = try! WeatherState.decode(forecast, city: "Test City", latitude: 0, longitude: 0, fahrenheit: false, selection: "Test City")
check(weather.temperature == 29 && weather.high == 31 && weather.low == 22, "Forecast reads and rounds current and daily temperatures")
check(weather.systemSymbol == "cloud.moon.fill", "Cloudy night must use a moon symbol")
check(WeatherState.symbol(code: 0, isDay: true) == "sun.max.fill", "Clear daytime uses sun")
check(WeatherState.symbol(code: 95, isDay: false) == "cloud.bolt.rain.fill", "Thunderstorms must not render as clear weather")
check((try? WeatherState.decode(Data("{}".utf8), city: "", latitude: 0, longitude: 0, fahrenheit: false, selection: "")) == nil, "Malformed forecasts cannot publish a weather chip")
check(view.weatherChipRect.minX > view.bounds.midX + notch.width / 2, "Weather chip must sit to the right of the hardware camera")
check(view.weatherChipRect.maxY <= notch.height, "Weather chip stays in header, not the Calendar body")
check(view.controlsRect.minX > view.bounds.midX + notch.width / 2, "Controls tab must not sit behind the camera")
check(LevelSliderView.fraction(x: -30, width: 230) == 0 && LevelSliderView.fraction(x: 300, width: 230) == 1, "Slider drags outside its bounds clamp to endpoints")
check(LevelSliderView.volumeSymbol(level: 0.8, muted: true) == "speaker.slash.fill", "Muted output must use the mute symbol even at a nonzero stored volume")
check(MediaKey.decode(subtype: 8, data: (2 << 16) | (0xA << 8))?.code == 2, "Brightness key-down decodes from systemDefined data1")
check(MediaKey.decode(subtype: 8, data: (0 << 16) | (0xB << 8))?.down == false, "Media key release decodes separately")
check(MediaKey.decode(subtype: 8, data: (21 << 16) | (0xA << 8)) == nil, "Unsupported keyboard illumination must pass through")
check(MediaKey.decode(subtype: 7, data: (0xA << 8)) == nil, "Other systemDefined subtypes must pass through")
var keyPolicy = MediaKeyPolicy()
check(!keyPolicy.consume(MediaKey(code: 0, down: true), fine: false, apply: { _, _ in false }), "Failed device writes must not swallow native keys")
check(!keyPolicy.consume(MediaKey(code: 0, down: false), fine: false, apply: { _, _ in preconditionFailure("Key-up must not write") }), "Failed key-downs must not swallow their releases")
var muteWrites = 0
check(keyPolicy.consume(MediaKey(code: 7, down: true), fine: false, apply: { _, step in muteWrites += 1; return step == 1.0 / 16 }), "Successful media changes can suppress the native event")
check(keyPolicy.consume(MediaKey(code: 7, down: true), fine: false, apply: { _, _ in muteWrites += 1; return true }) && muteWrites == 1, "Mute repeats must not oscillate the device")
check(keyPolicy.consume(MediaKey(code: 7, down: false), fine: false, apply: { _, _ in preconditionFailure("Release must not write") }), "Consumed key-downs must consume their paired release")
check(keyPolicy.consume(MediaKey(code: 1, down: true), fine: true, apply: { _, step in step == 1.0 / 64 }), "Shift-Option keys must apply fine increments")
if CommandLine.arguments.contains("--render-controls") {
    final class PreviewLevel: LevelControl {
        var level: Double; var isMuted = false; var isSupported = true
        init(_ level: Double) { self.level = level }
        func set(_ value: Double) { level = value }
    }
    final class PreviewCanvas: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
    }
    let canvas = PreviewCanvas(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    let brightness = LevelSliderView(control: PreviewLevel(0.42), brightness: true, name: { "Built-in display" })
    brightness.frame = NSRect(x: 14, y: 10, width: 230, height: 76)
    let volume = LevelSliderView(control: PreviewLevel(1), brightness: false, name: { "MacBook Speakers" })
    volume.frame = NSRect(x: 256, y: 10, width: 230, height: 76)
    canvas.addSubview(brightness); canvas.addSubview(volume)
    host.contentView = canvas; host.setContentSize(canvas.frame.size)
    let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    let output = URL(fileURLWithPath: CommandLine.arguments.last!)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
}
print("Passed: geometry, concave ears, hit testing, fixed hosting, animation ordering, compact/HUD regression checks")
print("Passed: split media records, microsecond units, diffs, paused position, empty payload")
print("Passed: Calendar access actions/all-day ordering; weather parsing, night symbols, malformed data, header geometry")
print("Passed: Controls geometry/clamping, media-key decoding, failure passthrough, paired releases, mute repeats, fine increments")
var trayChecksFinished = false
Task { @MainActor in
    do { try await runTrayChecks() }
    catch { preconditionFailure("Tray checks failed: \(error)") }
    trayChecksFinished = true
}
let trayDeadline = Date().addingTimeInterval(25)
while !trayChecksFinished && Date() < trayDeadline { run(0.02) }
check(trayChecksFinished, "Tray checks must complete without a blocked main thread")

}
