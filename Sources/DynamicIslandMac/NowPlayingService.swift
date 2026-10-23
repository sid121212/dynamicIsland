import AppKit
import Observation

struct NowPlayingState {
    var title = "Nothing playing"
    var artist = "Play audio in any app"
    var album = ""
    var duration: Double = 0
    var position: Double = 0
    var isPlaying = false
    var source = ""
    var bundleID = ""
    var artwork: NSImage?
    var appIcon: NSImage?
    var timestamp = Date()
    var rate: Double = 0
    var isAvailable: Bool { !title.isEmpty && title != "Nothing playing" }
    var elapsed: Double {
        let value = position + (isPlaying ? max(0, Date().timeIntervalSince(timestamp)) * rate : 0)
        return max(0, duration > 0 ? min(duration, value) : value)
    }
}

@MainActor @Observable final class NowPlayingService {
    private(set) var state = NowPlayingState()
    private(set) var running = false
    var onChange: (() -> Void)?
    private var enabled = false
    private var generation = 0
    private var stream: Process?
    private var test: Process?
    private var commands: [Process] = []
    private var timeout: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var retryDelay: Double = 1
    private var stdout = Data()
    private var payload: [String: Any] = [:]
    private var observers: [NSObjectProtocol] = []
    private var progressTimer: Timer?
    private var visible = false
    private var fallbackBusy = false

    private var resources: [String]? {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MediaRemoteAdapterTestClient"),
              FileManager.default.fileExists(atPath: framework.path),
              FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        return [script.path, framework.path, helper.path]
    }

    func start() {
        guard !enabled else { return }
        enabled = true; generation += 1
        guard resources != nil else { limited("Adapter resources missing"); return }
        DiagnosticsModel.shared.update(.nowPlaying, .degraded, "Adapter startup self-test running")
        let token = generation
        let process = makeProcess(["test"])
        test = process
        // Drain both pipes: neither a full pipe nor an unbounded stderr buffer can stall the helper.
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == token else { return }
                self.timeout?.cancel(); self.timeout = nil
                self.test = nil
                if process.terminationStatus == 0 { self.startStream() }
                else { self.limited("Adapter self-test failed (exit \(process.terminationStatus))") }
            }
        }
        do {
            try process.run()
            let deadline = DispatchWorkItem { [weak self, weak process] in
                guard let self, self.generation == token, process?.isRunning == true else { return }
                process?.terminate()
                self.limited("Adapter self-test timed out")
            }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        } catch { test = nil; limited("Adapter launch failed: \(error.localizedDescription)") }
    }

    func stop() {
        enabled = false; generation += 1; running = false
        timeout?.cancel(); timeout = nil; retry?.cancel(); retry = nil
        for process in [stream, test].compactMap({ $0 }) + commands {
            process.terminationHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        stream = nil; test = nil; commands = []
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers = []; progressTimer?.invalidate(); progressTimer = nil
        stdout = Data(); payload = [:]; state = NowPlayingState()
        DiagnosticsModel.shared.update(.nowPlaying, .degraded, "Now Playing disabled; processes and observers stopped")
        onChange?()
    }

    func setVisible(_ value: Bool) { guard value != visible else { return }; visible = value; configureProgress() }
    private func configureProgress() {
        progressTimer?.invalidate(); progressTimer = nil
        guard enabled, visible, state.isPlaying else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        progressTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = (resources ?? []) + arguments
        process.standardOutput = Pipe(); process.standardError = Pipe()
        return process
    }
    private func startStream() {
        guard enabled, stream == nil else { return }
        generation += 1
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers = []; stdout = Data()
        let token = generation
        let process = makeProcess(["stream", "--no-diff", "--micros", "--debounce=80"])
        stream = process
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == token else { return }
                self.receive(data)
            }
        }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == token else { return }
                self.stream = nil; self.running = false
                self.scheduleRetry("Adapter exited \(process.terminationStatus)")
            }
        }
        do {
            try process.run(); running = true
            DiagnosticsModel.shared.update(.nowPlaying, .degraded, "Self-test passed; stream running, awaiting payload")
        } catch { stream = nil; scheduleRetry("Stream launch failed: \(error.localizedDescription)") }
    }

    private func scheduleRetry(_ reason: String) {
        guard enabled else { return }
        limited("\(reason); retry in \(Int(retryDelay)) s")
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retry = nil; self?.startStream() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(30, retryDelay * 2)
    }

    func receive(_ data: Data) {
        stdout.append(data)
        guard stdout.count < 48 * 1024 * 1024 else {
            stdout.removeAll(); DiagnosticsModel.shared.update(.nowPlaying, .failed, "Adapter record exceeded safety limit"); return
        }
        while let newline = stdout.firstIndex(of: 10) {
            let line = stdout.prefix(upTo: newline); stdout.removeSubrange(...newline)
            guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  envelope["type"] as? String == "data", let values = envelope["payload"] as? [String: Any] else {
                DiagnosticsModel.shared.update(.nowPlaying, .failed, "Invalid adapter JSON record", event: true); continue
            }
            if envelope["diff"] as? Bool == true {
                for (key, value) in values { if value is NSNull { payload.removeValue(forKey: key) } else { payload[key] = value } }
            } else { payload = values }
            retryDelay = 1
            var next = NowPlayingState()
            if let title = payload["title"] as? String, !title.isEmpty {
                next.title = title; next.artist = payload["artist"] as? String ?? ""
                next.album = payload["album"] as? String ?? ""
                next.bundleID = payload["bundleIdentifier"] as? String ?? ""
                next.duration = (payload["durationMicros"] as? Double ?? 0) / 1_000_000
                next.position = (payload["elapsedTimeMicros"] as? Double ?? 0) / 1_000_000
                next.isPlaying = payload["playing"] as? Bool ?? false
                next.rate = payload["playbackRate"] as? Double ?? (next.isPlaying ? 1 : 0)
                if let epoch = payload["timestampEpochMicros"] as? Double { next.timestamp = Date(timeIntervalSince1970: epoch / 1_000_000) }
                if let base64 = payload["artworkData"] as? String, let data = Data(base64Encoded: base64) { next.artwork = NSImage(data: data) }
                let sourceID = payload["parentApplicationBundleIdentifier"] as? String ?? next.bundleID
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceID) {
                    next.appIcon = NSWorkspace.shared.icon(forFile: url.path)
                    next.source = FileManager.default.displayName(atPath: url.path)
                }
            }
            state = next
            DiagnosticsModel.shared.update(.nowPlaying, .ok, next.isAvailable ? "Self-test passed · stream running · \(next.isPlaying ? "playing" : "paused") · \(next.title)" : "Self-test passed · stream running · no active media", event: true)
            configureProgress(); onChange?()
        }
    }

    func togglePlayPause() { command(["send", "2"]) }
    func next() { command(["send", "4"]) }
    func previous() { command(["send", "5"]) }
    func shuffle() { command(["send", "6"]) }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        command(["seek", String(Int64(max(0, min(state.duration, seconds)) * 1_000_000))])
    }
    private func command(_ arguments: [String]) {
        guard enabled, state.isAvailable else { return }
        if !running { fallbackCommand(arguments); return }
        let process = makeProcess(arguments)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.commands.removeAll { $0 === process }
                guard self?.enabled == true, process.terminationStatus != 0 else { return }
                DiagnosticsModel.shared.update(.nowPlaying, .failed, "Adapter command failed (exit \(process.terminationStatus))", event: true)
            }
        }
        do { try process.run(); commands.append(process) }
        catch { DiagnosticsModel.shared.update(.nowPlaying, .failed, "Adapter command launch failed: \(error.localizedDescription)", event: true) }
    }

    private func limited(_ reason: String) {
        DiagnosticsModel.shared.update(.nowPlaying, .degraded, "Limited mode · \(reason)")
        guard enabled, observers.isEmpty else { return }
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFallback() }
            })
        }
        refreshFallback()
    }
    private func refreshFallback() {
        guard enabled, !running, !fallbackBusy else { return }
        let apps = NSWorkspace.shared.runningApplications
        let id = apps.contains { $0.bundleIdentifier == "com.spotify.client" } ? "com.spotify.client" : "com.apple.Music"
        guard apps.contains(where: { $0.bundleIdentifier == id }) else { return }
        fallbackBusy = true
        let token = generation
        let duration = id == "com.spotify.client" ? "((duration of current track) / 1000)" : "duration of current track"
        let script = "tell application id \"\(id)\" to if player state is not stopped then return (name of current track) & \"|||\" & (artist of current track) & \"|||\" & (\(duration)) & \"|||\" & player position & \"|||\" & (player state is playing)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue ?? ""
            let denied = error?[NSAppleScript.errorNumber] as? Int == -1743
            DispatchQueue.main.async {
                guard let self else { return }; self.fallbackBusy = false
                guard self.enabled, !self.running, self.generation == token else { return }
                let fields = result.components(separatedBy: "|||")
                if fields.count == 5 {
                    self.state = NowPlayingState(title: fields[0], artist: fields[1], duration: Double(fields[2]) ?? 0, position: Double(fields[3]) ?? 0, isPlaying: fields[4] == "true", source: id == "com.spotify.client" ? "Spotify" : "Music", bundleID: id, rate: fields[4] == "true" ? 1 : 0)
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { self.state.appIcon = NSWorkspace.shared.icon(forFile: url.path) }
                    DiagnosticsModel.shared.update(.nowPlaying, .degraded, "Limited mode · notification received · \(fields[0])", event: true)
                } else {
                    self.state = NowPlayingState()
                    if denied { DiagnosticsModel.shared.update(.nowPlaying, .failed, "Limited mode · Automation denied", event: true) }
                }
                self.configureProgress(); self.onChange?()
            }
        }
    }
    private func fallbackCommand(_ arguments: [String]) {
        guard ["com.spotify.client", "com.apple.Music"].contains(state.bundleID) else { return }
        let verb: String
        if arguments.first == "seek", let micros = Double(arguments.last ?? "") { verb = "set player position to \(micros / 1_000_000)" }
        else {
            switch arguments.last {
            case "4": verb = "next track"
            case "5": verb = "previous track"
            case "6": verb = state.bundleID == "com.spotify.client" ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled"
            default: verb = "playpause"
            }
        }
        let script = "tell application id \"\(state.bundleID)\" to \(verb)"
        DispatchQueue.global(qos: .userInitiated).async { var error: NSDictionary?; NSAppleScript(source: script)?.executeAndReturnError(&error) }
    }
}
