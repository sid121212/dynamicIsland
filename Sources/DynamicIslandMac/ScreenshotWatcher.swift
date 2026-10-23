import AppKit
import Observation
import Darwin

@MainActor @Observable final class ScreenshotWatcher {
    private(set) var enabled = false
    var isWatching: Bool { source != nil }
    private(set) var folder: URL
    var onSaved: ((TrayItem) -> Void)?
    private let store: TrayStore
    private let configuredFolder: URL?
    private var startupTask: Task<Void, Never>?
    private var query: NSMetadataQuery?
    private var source: DispatchSourceFileSystemObject?
    private var observers: [NSObjectProtocol] = []
    private var pending: [URL: DispatchWorkItem] = [:]
    private var seen = Set<URL>()
    private var began = Date()
    private var generation = 0
    init(store: TrayStore, folder: URL? = nil) {
        self.store = store; configuredFolder = folder
        self.folder = folder ?? Self.screenshotFolder()
    }
    static func screenshotFolder() -> URL {
        let value = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") ?? "~/Desktop"
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
    nonisolated static func accepts(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()) && (name.hasPrefix("screenshot") || name.hasPrefix("screen shot"))
    }
    func start() {
        guard !enabled else { return }; enabled = true; generation += 1; began = Date()
        folder = configuredFolder ?? Self.screenshotFolder()
        let token = generation
        let directory = folder
        DiagnosticsModel.shared.update(.screenshots, .degraded, "Checking screenshot folder access: \(directory.path)", event: true)
        startupTask = Task { [weak self] in
            do {
                // Folder enumeration can wait for TCC or a slow/cloud-backed directory.
                // Never perform it during AppDelegate construction or on the UI thread.
                let baseline = try await Task.detached(priority: .utility) {
                    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                }.value
                guard let self, self.enabled, self.generation == token, !Task.isCancelled else { return }
                self.startupTask = nil
                self.beginWatching(baseline)
            } catch {
                guard let self, self.enabled, self.generation == token, !Task.isCancelled else { return }
                self.startupTask = nil
                DiagnosticsModel.shared.update(.screenshots, .failed, "Screenshot folder access: \(error.localizedDescription)", event: true)
            }
        }
    }
    private func beginWatching(_ baseline: [URL]) {
        do {
            seen = Set(baseline)
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { throw TrayError.message("Cannot watch screenshot folder: \(String(cString: strerror(errno)))") }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            self.source = source
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
            source.setCancelHandler { close(fd) }; source.resume()
            let query = NSMetadataQuery(); self.query = query
            query.searchScopes = [folder.path]
            query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", began.addingTimeInterval(-1) as NSDate)
            query.notificationBatchingInterval = 0.1
            for name in [Notification.Name.NSMetadataQueryDidUpdate, Notification.Name.NSMetadataQueryDidFinishGathering] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated { self?.metadataChanged(notification) }
                })
            }
            let metadataStarted = query.start()
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshFolder() } })
            DiagnosticsModel.shared.update(.screenshots, .ok, "\(folder.path) · folder watcher active · metadata \(metadataStarted ? "active" : "unavailable; fallback active")", event: true)
        } catch { DiagnosticsModel.shared.update(.screenshots, .failed, "Screenshot folder access: \(error.localizedDescription)", event: true) }
    }
    func stop() {
        enabled = false; generation += 1
        startupTask?.cancel(); startupTask = nil
        query?.stop(); query = nil; source?.cancel(); source = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        pending.values.forEach { $0.cancel() }; pending = [:]; seen = []
        store.cancel(group: "screenshots")
        DiagnosticsModel.shared.update(.screenshots, .degraded, "Screenshot watcher disabled; query, descriptor and pending work stopped")
    }
    func restart() { stop(); start() }
    func refreshFolder() { if enabled, configuredFolder == nil, folder != Self.screenshotFolder() { restart() } }
    private func scan() {
        guard enabled else { return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for url in urls where !seen.contains(url) && Self.accepts(url) { enqueue(url) }
        } catch { DiagnosticsModel.shared.update(.screenshots, .failed, "Screenshot folder no longer readable: \(error.localizedDescription)", event: true) }
    }
    private func metadataChanged(_ notification: Notification) {
        guard enabled, let query else { return }
        query.disableUpdates(); defer { query.enableUpdates() }
        let values = notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? query.results.compactMap { $0 as? NSMetadataItem }
        for item in values {
            guard let path = item.value(forAttribute: "kMDItemPath") as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().standardizedFileURL == folder, !seen.contains(url) else { continue }
            enqueue(url)
        }
    }
    private func enqueue(_ url: URL) {
        guard enabled, !seen.contains(url), pending[url] == nil else { return }
        seen.insert(url); stabilize(url, previous: nil, attempt: 0, token: generation)
    }
    private func stabilize(_ url: URL, previous: Int?, attempt: Int, token: Int) {
        guard enabled, token == generation else { return }
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let size, size > 0, size == previous {
            pending.removeValue(forKey: url)
            store.importItem(.file(url, .screenshot), source: "com.apple.screencaptureui", group: "screenshots") { [weak self] item in
                guard let self, self.enabled, self.generation == token else { return }
                if let item {
                    DiagnosticsModel.shared.update(.screenshots, .ok, "\(self.folder.path) · imported \(item.displayName)", event: true)
                    self.onSaved?(item)
                } else { DiagnosticsModel.shared.update(.screenshots, .failed, "Screenshot import failed — \(self.store.error ?? "unknown error")", event: true) }
            }
            return
        }
        guard attempt < 15 else { pending.removeValue(forKey: url); return }
        let work = DispatchWorkItem { [weak self] in self?.stabilize(url, previous: size, attempt: attempt + 1, token: token) }
        pending[url] = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
