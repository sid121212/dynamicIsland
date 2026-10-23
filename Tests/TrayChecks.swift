import AppKit

@MainActor func runTrayChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicIslandTrayChecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let disk = TrayDisk(root: root.appendingPathComponent("storage"), maximumItems: 2)
    let (_, first) = try await disk.insert(.text("first"), source: "test", retention: 0, now: now.addingTimeInterval(-7200))
    let (_, duplicate) = try await disk.insert(.text("first"), source: "test", retention: 0, now: now.addingTimeInterval(-7200))
    precondition(first.id == duplicate.id, "Deduplication must preserve the item identity")
    _ = try await disk.mutate(id: first.id, pin: true, retention: 0)
    let (_, expired) = try await disk.insert(.text("expired"), source: nil, retention: 0, now: now.addingTimeInterval(-7200))
    let fresh = try await disk.load(retention: 3600, now: now)
    precondition(fresh.items.map(\.id) == [first.id], "Retention must preserve pins and remove expired unpinned items")
    precondition(!FileManager.default.fileExists(atPath: expired.fileURL!.path), "Expired payloads must be removed")
    _ = try await disk.insert(.text("second"), source: nil, retention: 0)
    _ = try await disk.insert(.text("third"), source: nil, retention: 0)
    let (limited, _) = try await disk.insert(.text("fourth"), source: nil, retention: 0)
    precondition(limited.items.filter { !$0.pinned }.count == 2 && limited.items.contains { $0.id == first.id }, "Item cap must evict oldest unpinned entries only")
    let reload = TrayDisk(root: root.appendingPathComponent("storage"))
    let restored = try await reload.load(retention: 0)
    precondition(restored.items == limited.items, "Index must round-trip IDs, ordering, pin state and payload URLs")
    let constrained = TrayDisk(root: root.appendingPathComponent("bounded"), maximumBytes: 5000)
    let (_, pinned) = try await constrained.insert(.text(String(repeating: "a", count: 1100)), source: nil, retention: 0)
    _ = try await constrained.mutate(id: pinned.id, pin: true, retention: 0)
    do {
        _ = try await constrained.insert(.text("another item"), source: nil, retention: 0)
        preconditionFailure("Pinned storage must not silently exceed the byte limit")
    } catch {}
    let afterFailure = try await constrained.load(retention: 0)
    precondition(afterFailure.items.map(\.id) == [pinned.id], "Failed inserts must preserve committed history")
    let corruptRoot = root.appendingPathComponent("corrupt")
    try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: corruptRoot.appendingPathComponent("index.json"))
    do { _ = try await TrayDisk(root: corruptRoot).load(retention: 0); preconditionFailure("Corrupt index must fail visibly") } catch {}
    let preservedIndex = try Data(contentsOf: corruptRoot.appendingPathComponent("index.json"))
    precondition(preservedIndex == corrupt, "Corrupt index must never be overwritten")

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    for x in 0..<64 { for y in 0..<48 {
        let pixel = bitmap.bitmapData!.advanced(by: y * bitmap.bytesPerRow + x * 4)
        pixel[0] = 20; pixel[1] = 120; pixel[2] = 240; pixel[3] = 255
    } }
    let png = bitmap.representation(using: .png, properties: [:])!
    let encodingDisk = TrayDisk(root: root.appendingPathComponent("encodings"))
    let tiff = bitmap.representation(using: .tiff, properties: [:])!
    let (_, converted) = try await encodingDisk.insert(.image(tiff, .image), source: nil, retention: 0)
    precondition(converted.fileURL?.pathExtension == "png", "TIFF clipboard content must be normalized to PNG")
    do { _ = try await encodingDisk.insert(.image(Data(repeating: 0, count: 25 * 1024 * 1024 + 1), .image), source: nil, retention: 0); preconditionFailure("Images over 25 MB must be rejected") } catch {}
    do { _ = try await encodingDisk.insert(.image(Data("not an image".utf8), .image), source: nil, retention: 0); preconditionFailure("Malformed image data must be rejected") } catch {}
    let finderImage = root.appendingPathComponent("Finder image.png")
    try png.write(to: finderImage)
    let (_, finderCard) = try await TrayDisk(root: root.appendingPathComponent("finder-images")).insert(.file(finderImage, .file), source: nil, retention: 0)
    precondition(finderCard.kind == .file && finderCard.thumbnailURL != nil && TrayFilter.images.includes(finderCard), "Images copied from Finder must keep file actions and show a preview in Images")
    let store = TrayStore(root: root.appendingPathComponent("monitor-store"))
    let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, source: { "test.notes" })
    monitor.start(); defer { monitor.stop(); store.stop() }
    pasteboard.clearContents(); precondition(pasteboard.setString("visible", forType: .string), "Private test pasteboard unavailable")
    try await waitForTray { store.items.count == 1 }
    pasteboard.clearContents(); pasteboard.setString("secret", forType: .string)
    pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")); monitor.poll()
    try await Task.sleep(for: .milliseconds(100))
    precondition(store.items.count == 1, "Concealed clipboard data must never be stored")
    precondition(ClipboardMonitor.shouldIgnore(types: [], source: "COM.1PASSWORD.1PASSWORD", exclusions: Set(ClipboardMonitor.defaultExclusions.map { $0.lowercased() })), "Password-manager app exclusions must be case-insensitive")
    for marker in ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
        precondition(ClipboardMonitor.shouldIgnore(types: [marker], source: nil, exclusions: []), "Transient/generated clipboard values must be ignored")
    }
    let beforeOwnWrite = store.items[0].createdAt
    monitor.copy(store.items[0]) { precondition($0, "Restoring text to the test pasteboard must succeed") }
    monitor.poll(); try await Task.sleep(for: .milliseconds(100))
    precondition(store.items[0].createdAt == beforeOwnWrite, "Own writes must not re-add or reorder history")
    pasteboard.clearContents(); pasteboard.setData(png, forType: .png); monitor.poll()
    try await waitForTray { store.items.contains { $0.kind == .image } }
    let image = store.items.first { $0.kind == .image }!
    precondition(image.thumbnailURL != nil && FileManager.default.fileExists(atPath: image.thumbnailURL!.path), "Images must receive a stored thumbnail")
    let copySuccess: Bool = await withCheckedContinuation { continuation in monitor.copy(image) { continuation.resume(returning: $0) } }
    precondition(copySuccess && pasteboard.data(forType: .png) != nil, "Image restore must publish PNG data")
    monitor.poll()
    let original = root.appendingPathComponent("original.txt"); try Data("a file".utf8).write(to: original)
    pasteboard.clearContents(); pasteboard.writeObjects([original as NSURL]); monitor.poll()
    try await waitForTray { store.items.contains { $0.kind == .file } }
    let file = store.items.first { $0.kind == .file }!
    precondition(file.fileURL != original && FileManager.default.fileExists(atPath: original.path), "File imports must use a copy and preserve the original")
    store.delete(file); try await waitForTray { !store.items.contains { $0.id == file.id } }
    precondition(FileManager.default.fileExists(atPath: original.path), "Deleting history must not delete the source file")

    let shots = root.appendingPathComponent("shots"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    let watcher = ScreenshotWatcher(store: store, folder: shots)
    var saved: TrayItem?
    watcher.onSaved = { saved = $0 }; watcher.start()
    try await waitForTray { watcher.isWatching }
    let screenshot = shots.appendingPathComponent("Screenshot fixture.png")
    let began = Date(); try png.write(to: screenshot)
    try await waitForTray { saved != nil }
    precondition(Date().timeIntervalSince(began) < 1, "Stable screenshot files should import in under one second")
    precondition(saved!.kind == .screenshot && FileManager.default.fileExists(atPath: screenshot.path), "Screenshot activity must use the screenshot kind and preserve its original")
    precondition(TrayFilter.images.includes(saved!) && !TrayFilter.files.includes(saved!), "Screenshot cards must appear in the Images filter")
    watcher.stop()
    monitor.stop()
    let stoppedCount = store.items.count
    try png.write(to: shots.appendingPathComponent("Screenshot after-stop.png"))
    pasteboard.clearContents(); pasteboard.setString("after stop", forType: .string); monitor.poll()
    try await Task.sleep(for: .milliseconds(500))
    precondition(store.items.count == stoppedCount, "Disabled capture modules must not ingest changes")
    let persisted = try await TrayDisk(root: root.appendingPathComponent("monitor-store")).load(retention: 86400)
    precondition(persisted.items == store.items, "Captured Tray content must survive a fresh store instance")
    for item in persisted.items {
        precondition(FileManager.default.fileExists(atPath: item.fileURL!.path), "Reload cleanup must retain referenced payloads")
        if let thumbnail = item.thumbnailURL {
            precondition(FileManager.default.fileExists(atPath: thumbnail.path), "Reload cleanup must retain referenced thumbnails")
            precondition(NSImage(contentsOf: thumbnail) != nil, "Stored thumbnails must decode for the UI")
        }
    }
    // Exercise the actual scroll container, not only standalone card drawing.
    let previewModel = SystemMonitor(preview: true)
    // Use the isolated test store without touching the user's Tray.
    let tray = TrayView(model: previewModel, store: store)
    tray.frame = NSRect(x: 0, y: 0, width: 472, height: 90)
    let trayWindow = NSWindow(contentRect: tray.bounds, styleMask: .borderless, backing: .buffered, defer: false)
    trayWindow.contentView = tray
    tray.refresh()
    // refresh must work immediately, without relying on a later AppKit layout pass.
    let scroller = tray.subviews.compactMap { $0 as? NSScrollView }.first!
    precondition(scroller.frame.height == 66 && scroller.frame.width == 472, "Tray card viewport must be laid out after frame changes")
    precondition(scroller.documentView!.subviews.count == store.items.count, "Captured items must reach the actual scroll container")
    precondition(!scroller.isHidden && scroller.contentView.documentVisibleRect.height > 0, "Tray cards must have a visible viewport")
    if let index = CommandLine.arguments.firstIndex(of: "--render-tray"), index + 1 < CommandLine.arguments.count {
        final class BlackCanvas: NSView {
            override var isFlipped: Bool { true }
            override func draw(_ rect: NSRect) { NSColor.black.setFill(); bounds.fill() }
        }
        let canvas = BlackCanvas(frame: tray.bounds)
        trayWindow.contentView = canvas; canvas.addSubview(tray)
        let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    print("Passed: Tray dedupe, persistence, pin/retention/count/byte limits, corruption preservation, clipboard types/exclusions/own writes, image/file copies, screenshot watcher timing and capture shutdown")
}

@MainActor private func waitForTray(line: Int = #line, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(4)
    while !condition() {
        guard Date() < deadline else { throw TrayError.message("Tray check timed out at line \(line) · \(DiagnosticsModel.shared.entries[.clipboard]?.summary ?? "") · \(DiagnosticsModel.shared.entries[.screenshots]?.summary ?? "")") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
