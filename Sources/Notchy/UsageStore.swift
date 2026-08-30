import AppKit
import Foundation

/// Owns the provider loop: one Task per provider (independent failure
/// domains), poll-with-jitter, exponential backoff on 429, refresh on wake,
/// reset-expiry trigger, local-file watches (never network), disk cache for
/// instant launch population.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot]

    private let providers: [UsageProvider]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var watchers: [Any] = []   // FSEventStreamRef (opaque pointer) + DispatchSource
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var lastLocalRefresh = Date.distantPast
    private var backoff: [String: Int] = [:]   // consecutive 429s per provider
    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Notchy/snapshots.json")

    init(providers: [UsageProvider]) {
        self.providers = providers
        let cached = Self.loadCache(url: cacheURL)   // [id: ProviderUsage]
        self.snapshots = providers.map { p in
            var s = ProviderSnapshot(info: p.info)
            if let usage = cached[p.info.id] {
                s.usage = usage
                s.state = .stale(since: Date())
            }
            return s
        }
    }

    func start() {
        for p in providers {
            tasks[p.info.id] = Task { await run(provider: p) }
        }
        watchLocalFiles()
        observeWake()
    }

    func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        fileSources.values.forEach { $0.cancel() }
        fileSources.removeAll()
        watchers.removeAll()
    }

    // MARK: - Per-provider loop

    private func run(provider: UsageProvider) async {
        let base: Duration
        switch provider.refresh {
        case .poll(let d): base = d
        }
        // Seed from local sources immediately (no network) so the notch is
        // populated while the first endpoint call is in flight.
        if let local = await provider.localUsage() {
            apply(usage: local, providerID: provider.info.id)
        }
        while !Task.isCancelled {
            await tick(provider: provider)
            let consecutive = backoff[provider.info.id] ?? 0
            // Exponential on 429 (2×, 4×, … capped at 15 min) + poll jitter.
            let delay = base * (1 << min(consecutive, 5)) + .milliseconds(Int.random(in: 0...30_000))
            try? await Task.sleep(for: min(delay, .seconds(900)))
        }
    }

    private func tick(provider: UsageProvider) async {
        do {
            let usage = try await provider.currentUsage()
            backoff[provider.info.id] = nil
            apply(usage: usage, providerID: provider.info.id)
        } catch HTTPError.rateLimited {
            backoff[provider.info.id, default: 0] += 1
            markStale(providerID: provider.info.id)
        } catch {
            // 401 / network / parse: keep last good, mark stale.
            backoff[provider.info.id] = nil
            markStale(providerID: provider.info.id)
            if snapshot(provider.info.id)?.usage == nil,
               let local = await provider.localUsage() {
                apply(usage: local, providerID: provider.info.id)
            }
        }
    }

    // MARK: - Snapshot mutation

    private func snapshot(_ id: String) -> ProviderSnapshot? {
        snapshots.first(where: { $0.info.id == id })
    }

    private func apply(usage: ProviderUsage, providerID: String) {
        update(providerID) { snap in
            snap.usage = usage
            snap.state = .ok
        }
        scheduleResetExpiry(providerID: providerID)
        saveCache()
    }

    private func markStale(providerID: String) {
        update(providerID) { snap in
            if snap.usage != nil {
                snap.state = .stale(since: Date())
            } else {
                snap.state = .noData(reason: "fetch failed")
            }
        }
    }

    private func update(_ providerID: String, _ mutate: (inout ProviderSnapshot) -> Void) {
        if let idx = snapshots.firstIndex(where: { $0.info.id == providerID }) {
            mutate(&snapshots[idx])
        }
    }

    // MARK: - Reset expiry — the only non-timer endpoint triggers are this + wake

    private func scheduleResetExpiry(providerID: String) {
        guard let snap = snapshot(providerID), let usage = snap.usage else { return }
        let deadlines = [usage.session?.resetsAt, usage.weekly?.resetsAt].compactMap { $0 }
        guard let next = deadlines.min(), next > Date() else { return }
        tasks["expiry-\(providerID)"]?.cancel()
        tasks["expiry-\(providerID)"] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 1))
            guard !Task.isCancelled else { return }
            self?.refreshNow(providerID: providerID)
        }
    }

    /// One immediate endpoint refresh for a single provider.
    func refreshNow(providerID: String) {
        guard let p = providers.first(where: { $0.info.id == providerID }) else { return }
        tasks["manual-\(providerID)"]?.cancel()
        tasks["manual-\(providerID)"] = Task { [weak self] in
            await self?.tick(provider: p)
        }
    }

    // MARK: - Wake refresh

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
    }

    func refreshAll() {
        for p in providers { refreshNow(providerID: p.info.id) }
    }

    /// Local-only refresh (file-watch events) — debounced ≥ 5 s; NEVER hits the
    /// network, else active coding sessions would 429-storm the endpoints.
    func refreshAllLocals() {
        guard Date().timeIntervalSince(lastLocalRefresh) > 5 else { return }
        lastLocalRefresh = Date()
        for p in providers {
            let id = p.info.id
            Task { [weak self] in
                guard let local = await p.localUsage() else { return }
                self?.update(id) { snap in
                    // Local sources are passive fallbacks (§1.1: the CLI refreshes
                    // cachedUsageUtilization only on /usage or limit hits) — never
                    // regress a fresh endpoint snapshot (.ok) back to stale cache.
                    guard snap.usage == nil || snap.state != .ok else { return }
                    snap.usage = local
                    if case .noData = snap.state { snap.state = .ok }
                }
                self?.saveCache()
            }
        }
    }

    // MARK: - Local file watching

    private func watchLocalFiles() {
        var dirPaths: [String] = []
        var filePaths: [String] = []
        for p in providers {
            for path in p.watchPaths {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    dirPaths.append(path)
                } else {
                    filePaths.append(path)
                }
            }
        }
        // One FSEvents stream for directory trees (FSEvents takes dir paths only).
        if !dirPaths.isEmpty {
            var context = FSEventStreamContext()
            context.info = Unmanaged.passUnretained(self).toOpaque()
            let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
                let store = Unmanaged<UsageStore>.fromOpaque(clientInfo!).takeUnretainedValue()
                Task { @MainActor in store.refreshAllLocals() }
            }
            if let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context,
                dirPaths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
            ) {
                FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
                FSEventStreamStart(stream)
                watchers.append(stream)
            }
        }
        // One DispatchSource vnode watcher per single file; re-armed on
        // rename/delete since the fd tracks the old inode.
        for path in filePaths {
            armFileWatch(path: path)
        }
    }

    private func armFileWatch(path: String) {
        fileSources[path]?.cancel()   // cancel handler closes the old fd
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            MainActor.assumeIsolated {
                self?.refreshAllLocals()
                // The fd tracks the old inode — re-arm only when the file was
                // replaced, not on plain writes.
                if event.contains(.delete) || event.contains(.rename) {
                    self?.armFileWatch(path: path)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSources[path] = source
    }

    // MARK: - Disk cache

    private static func loadCache(url: URL) -> [String: ProviderUsage] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        struct Cached: Codable {
            var id: String
            var usage: ProviderUsage?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([Cached].self, from: data) else { return [:] }
        return list.reduce(into: [:]) { $0[$1.id] = $1.usage }
    }

    private func saveCache() {
        struct Cached: Codable {
            var id: String
            var usage: ProviderUsage?
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let list = snapshots.map { Cached(id: $0.info.id, usage: $0.usage) }
        if let data = try? encoder.encode(list) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
