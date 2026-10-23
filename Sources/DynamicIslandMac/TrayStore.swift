import AppKit
import CryptoKit
import ImageIO
import Observation
import UniformTypeIdentifiers

nonisolated enum TrayKind: String, Codable, Sendable { case text, image, screenshot, file }
nonisolated struct TrayItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var kind: TrayKind
    var createdAt: Date
    var pinned: Bool
    var sourceBundleID: String?
    var text: String?
    var fileURL: URL?
    var thumbnailURL: URL?
    var contentHash: String
    var displayName: String
    var byteCount: Int64
}
nonisolated enum TrayInput: Sendable {
    case text(String)
    case image(Data, TrayKind)
    case file(URL, TrayKind)
}
nonisolated struct TraySnapshot: Sendable { let revision: Int; let items: [TrayItem] }
nonisolated enum TrayError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

// Actor isolation keeps file IO, SHA-256 and ImageIO decoding off the UI thread.
actor TrayDisk {
    let root: URL
    private var items: [TrayItem] = []
    private var loaded = false
    private var revision = 0
    private let maximumItems: Int
    private let maximumBytes: Int64
    private let maximumImageBytes: Int64 = 25 * 1024 * 1024
    init(root: URL, maximumItems: Int = 100, maximumBytes: Int64 = 500 * 1024 * 1024) {
        self.root = root; self.maximumItems = maximumItems; self.maximumBytes = maximumBytes
    }
    private var payloads: URL { root.appendingPathComponent("items", isDirectory: true) }
    private var thumbnails: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    private var index: URL { root.appendingPathComponent("index.json") }
    private func inside(_ url: URL, directory: URL) -> Bool {
        url.isFileURL && url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath()
    }
    func load(retention: TimeInterval, now: Date = Date()) throws -> TraySnapshot {
        try Task.checkCancellation()
        if !loaded {
            try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            if FileManager.default.fileExists(atPath: index.path) {
                // A corrupt index is preserved and reported, never silently overwritten.
                let data = try Data(contentsOf: index)
                let decoded = try JSONDecoder().decode([TrayItem].self, from: data)
                items = decoded.filter { item in
                    guard let url = item.fileURL, inside(url, directory: payloads) else { return false }
                    return FileManager.default.fileExists(atPath: url.path) && (item.thumbnailURL.map { inside($0, directory: thumbnails) } ?? true)
                }
            }
            loaded = true
            let referenced = Set((items.compactMap(\.fileURL) + items.compactMap(\.thumbnailURL)).map { $0.resolvingSymlinksInPath().standardizedFileURL })
            for directory in [payloads, thumbnails] {
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !referenced.contains(url.resolvingSymlinksInPath().standardizedFileURL) {
                    if UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil { try? FileManager.default.removeItem(at: url) }
                }
            }
        }
        let next = pruned(items, retention: retention, now: now)
        if next != items { try commit(next) }
        return TraySnapshot(revision: revision, items: items)
    }
    private func pruned(_ values: [TrayItem], retention: TimeInterval, now: Date) -> [TrayItem] {
        var next = values.filter { $0.pinned || retention <= 0 || now.timeIntervalSince($0.createdAt) < retention }
        while next.filter({ !$0.pinned }).count > maximumItems {
            guard let oldest = next.lastIndex(where: { !$0.pinned }) else { break }; next.remove(at: oldest)
        }
        while next.reduce(Int64(0), { $0 + $1.byteCount }) > maximumBytes {
            guard let oldest = next.lastIndex(where: { !$0.pinned }) else { break }; next.remove(at: oldest)
        }
        return next
    }
    private func commit(_ next: [TrayItem]) throws {
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(next).write(to: index, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        let surviving = Set(next.compactMap(\.fileURL) + next.compactMap(\.thumbnailURL))
        let removed = items.filter { previous in !next.contains(where: { $0.id == previous.id }) }
        // Only delete paths owned by this store, after the replacement index is durable.
        for item in removed {
            for url in [item.fileURL, item.thumbnailURL].compactMap({ $0 }) where !surviving.contains(url) {
                if inside(url, directory: payloads) || inside(url, directory: thumbnails) { try? FileManager.default.removeItem(at: url) }
            }
        }
        items = next; revision += 1
    }
    private func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { try Task.checkCancellation(); hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func insert(_ input: TrayInput, source: String?, retention: TimeInterval, now: Date = Date()) throws -> (TraySnapshot, TrayItem) {
        _ = try load(retention: retention, now: now)
        let id = UUID()
        var kind: TrayKind, data: Data?, original: URL?, text: String?, name: String, ext: String
        switch input {
        case .text(let value):
            guard !value.isEmpty, value.utf8.count <= 25 * 1024 * 1024 else { throw TrayError.message("Text is empty or exceeds 25 MB") }
            kind = .text; text = value; data = Data(value.utf8); name = "Clipboard text.txt"; ext = "txt"
        case .image(let value, let imageKind):
            guard imageKind == .image || imageKind == .screenshot, value.count <= maximumImageBytes else { throw TrayError.message("Image exceeds 25 MB") }
            kind = imageKind
            guard let source = CGImageSourceCreateWithData(value as CFData, nil), let type = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0 else { throw TrayError.message("Image cannot be decoded") }
            let sourceType = UTType(type as String)
            // TIFF payloads are normalized once off the main thread.
            if sourceType?.conforms(to: .tiff) == true {
                let output = NSMutableData()
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw TrayError.message("TIFF conversion failed") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination), output.length <= maximumImageBytes else { throw TrayError.message("Converted image exceeds 25 MB") }
                data = output as Data; ext = "png"
            } else { data = value; ext = sourceType?.preferredFilenameExtension ?? "png" }
            name = imageKind == .screenshot ? "Screenshot.\(ext)" : "Clipboard image.\(ext)"
        case .file(let url, let fileKind):
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else { throw TrayError.message("Only regular files under 500 MB can be kept") }
            kind = fileKind; original = url; name = url.lastPathComponent
            let suffix = url.pathExtension.lowercased()
            ext = suffix.count <= 12 && suffix.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) ? suffix : "bin"
            if kind == .image || kind == .screenshot, size > maximumImageBytes { throw TrayError.message("Image exceeds 25 MB") }
        }
        let digest = try original.map { try hash($0) } ?? SHA256.hash(data: data!).map { String(format: "%02x", $0) }.joined()
        if let position = items.firstIndex(where: { $0.contentHash == digest }) {
            var next = items; var existing = next.remove(at: position)
            existing.createdAt = now; existing.sourceBundleID = source ?? existing.sourceBundleID
            if kind == .screenshot { existing.kind = .screenshot; existing.displayName = name }
            next.insert(existing, at: 0); try commit(next)
            return (TraySnapshot(revision: revision, items: items), existing)
        }
        let target = payloads.appendingPathComponent(id.uuidString).appendingPathExtension(ext.isEmpty ? "bin" : ext)
        let thumbnail = thumbnails.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
        do {
            if let original { try FileManager.default.copyItem(at: original, to: target) }
            else { try data!.write(to: target, options: .atomic) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try Task.checkCancellation()
            let payloadBytes = Int64((try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            if kind == .image || kind == .screenshot, payloadBytes > maximumImageBytes { throw TrayError.message("Image exceeds 25 MB") }
            var bytes = payloadBytes + 2048
            if let text { bytes += Int64(try JSONEncoder().encode(text).count) }
            let pinnedBytes = items.filter(\.pinned).reduce(Int64(0)) { $0 + $1.byteCount }
            guard pinnedBytes + bytes <= maximumBytes else { throw TrayError.message("Tray storage full — remove or unpin items") }
            var thumb: URL?
            if kind != .text,
               let source = CGImageSourceCreateWithURL(target as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 192, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
               let destination = CGImageDestinationCreateWithURL(thumbnail as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if CGImageDestinationFinalize(destination) { thumb = thumbnail; try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: thumbnail.path) }
            }
            if thumb != nil { bytes += Int64((try? thumbnail.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let item = TrayItem(id: id, kind: kind, createdAt: now, pinned: false, sourceBundleID: source, text: text, fileURL: target, thumbnailURL: thumb, contentHash: digest, displayName: name, byteCount: bytes)
            let next = pruned([item] + items, retention: retention, now: now)
            guard next.contains(where: { $0.id == id }) else { throw TrayError.message("Tray storage limit reached") }
            try commit(next)
            return (TraySnapshot(revision: revision, items: items), item)
        } catch {
            try? FileManager.default.removeItem(at: target); try? FileManager.default.removeItem(at: thumbnail); throw error
        }
    }
    func mutate(id: UUID? = nil, pin: Bool? = nil, clearPinned: Bool = false, retention: TimeInterval = 86400) throws -> TraySnapshot {
        guard loaded else { throw TrayError.message("Tray not loaded") }
        var next = items
        if let id {
            if let pin, let i = next.firstIndex(where: { $0.id == id }) { next[i].pinned = pin }
            else { next.removeAll { $0.id == id } }
        } else { next.removeAll { clearPinned || !$0.pinned } }
        try commit(pruned(next, retention: retention, now: Date())); return TraySnapshot(revision: revision, items: items)
    }
}

@MainActor @Observable final class TrayStore {
    private(set) var items: [TrayItem] = []
    private(set) var error: String?
    private(set) var loaded = false
    var onChange: (() -> Void)?
    private let disk: TrayDisk
    private var revision = -1
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var groups: [UUID: String] = [:]
    private var timer: Timer?
    private let defaults: UserDefaults
    var retention: TimeInterval { defaults.object(forKey: "trayRetention") as? Double ?? 86400 }
    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let directory = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dynamic Island/Tray", isDirectory: true)
        disk = TrayDisk(root: directory)
    }
    func start() {
        ensureLoaded()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.ensureLoaded() } }
        timer.tolerance = 30; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil; tasks.values.forEach { $0.cancel() }; tasks = [:]; groups = [:] }
    func cancel(group: String) { for id in groups.keys.filter({ groups[$0] == group }) { tasks.removeValue(forKey: id)?.cancel(); groups.removeValue(forKey: id) } }
    func ensureLoaded() {
        let retention = retention
        perform { [disk] in let snapshot = try await disk.load(retention: retention); return (snapshot, nil) }
    }
    func importItem(_ input: TrayInput, source: String?, group: String = "clipboard", completion: ((TrayItem?) -> Void)? = nil) {
        let retention = retention
        perform(group: group, completion: completion) { [disk] in let (snapshot, item) = try await disk.insert(input, source: source, retention: retention); return (snapshot, item) }
    }
    func delete(_ item: TrayItem) { mutate(id: item.id) }
    func togglePin(_ item: TrayItem) { mutate(id: item.id, pin: !item.pinned) }
    func clear(includingPinned: Bool = false) { mutate(clearPinned: includingPinned) }
    private func mutate(id: UUID? = nil, pin: Bool? = nil, clearPinned: Bool = false) {
        let retention = retention
        perform { [disk] in let snapshot = try await disk.mutate(id: id, pin: pin, clearPinned: clearPinned, retention: retention); return (snapshot, nil) }
    }
    private func perform(group: String? = nil, completion: ((TrayItem?) -> Void)? = nil, operation: @escaping @Sendable () async throws -> (TraySnapshot, TrayItem?)) {
        let id = UUID()
        groups[id] = group
        tasks[id] = Task { [weak self] in
            do {
                let (snapshot, item) = try await operation()
                guard let self, !Task.isCancelled else { return }
                if snapshot.revision >= self.revision { self.revision = snapshot.revision; self.items = snapshot.items; self.loaded = true; self.error = nil; self.onChange?() }
                self.tasks.removeValue(forKey: id); self.groups.removeValue(forKey: id); completion?(item)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.tasks.removeValue(forKey: id); self.groups.removeValue(forKey: id); self.error = error.localizedDescription
                DiagnosticsModel.shared.update(.clipboard, .failed, "Tray storage: \(error.localizedDescription)", event: true)
                self.onChange?(); completion?(nil)
            }
        }
    }
}
