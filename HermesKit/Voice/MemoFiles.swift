// Where memos live on the phone (spec 1x-voice §3.3 step 3, §3.6, §6.2, §6.3):
//   Application Support/memos/<account key>/<uuid>/voice-memo.m4a   your recordings (drafts, sends in flight)
//   Application Support/memos/<account key>/drafts.json             drafts per chat, newest first: {"<scope>": [MemoDraft]}
//   Application Support/memos/<account key>/shapes.json             waveforms by path, newest 64
//   Library/Caches/memos/<account key>/<sha256(path)>.<ext>         played gateway memos (LRU, 64 files / 128 MB)
// The account key is SHA-256(account id), hex, first 16 characters. Sign-out purges both folders. memos/ and
// memos/<account key>/ are excluded from backup (set on every sign-in); recordings no draft refers to (a crash or a
// kill mid-send) are swept once a day old.

import CryptoKit
import Foundation
import Synchronization

nonisolated enum MemoPaths {
    /// Tests point these elsewhere.
    nonisolated(unsafe) static var supportBase: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    nonisolated(unsafe) static var cachesBase: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())

    static func accountKey(_ accountId: String) -> String {
        SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static var memosRoot: URL { supportBase.appending(path: "memos", directoryHint: .isDirectory) }
    static func memos(_ key: String) -> URL { memosRoot.appending(path: key, directoryHint: .isDirectory) }
    static func caches(_ key: String) -> URL {
        cachesBase.appending(path: "memos", directoryHint: .isDirectory).appending(path: key, directoryHint: .isDirectory)
    }

    /// A new recording's final place: memos/<key>/<uuid>/voice-memo.<ext>.
    static func newRecording(_ key: String, ext: String) -> URL {
        memos(key).appending(path: UUID().uuidString, directoryHint: .isDirectory).appending(path: "voice-memo.\(ext)")
    }

    /// A path this phone owns (under memos/): a local file, never a gateway path.
    static func isLocal(_ path: String) -> Bool {
        path.hasPrefix(memosRoot.path + "/") || path.hasPrefix(memosRoot.resolvingSymlinksInPath().path + "/")
    }

    /// A recording's path in this install. iOS can move the app's container on an update, so a path saved by an
    /// earlier launch is rebuilt under today's memos folder (everything after its last "/memos/").
    static func rebase(_ path: String) -> String {
        guard !FileManager.default.fileExists(atPath: path), let range = path.range(of: "/memos/", options: .backwards) else { return path }
        let moved = memosRoot.appending(path: String(path[range.upperBound...])).path
        return FileManager.default.fileExists(atPath: moved) ? moved : path
    }

    /// Creates `folder` if needed and excludes it (and so everything in it) from backup, every time.
    static func excludeFromBackup(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Deletes the recording folders under memos/<key>/ that no draft refers to and that nothing touched for `age`
    /// seconds: what a crash or a kill mid-send left behind. Run off the main thread.
    static func sweep(key: String, keeping: Set<String>, olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let folders = try? fm.contentsOfDirectory(at: memos(key), includingPropertiesForKeys: keys) else { return }
        let kept = Set(keeping.flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] })
        let cutoff = Date().addingTimeInterval(-age)
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            if files.contains(where: { kept.contains($0.path) || kept.contains($0.resolvingSymlinksInPath().path) }) { continue }
            let touched = (files + [folder]).compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            if (touched.max() ?? .distantPast) < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    /// Creates the folder (0700-ish, excluded from backup).
    static func ensure(_ folder: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Deletes a recording and its UUID folder (when that folder is under memos/).
    static func remove(_ path: String) {
        guard isLocal(path) else { return }
        let file = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if folder.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == memosRoot.standardizedFileURL,
           (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Sign-out: this account's recordings, drafts, shapes and played memos.
    static func purge(accountId: String) {
        let key = accountKey(accountId)
        try? FileManager.default.removeItem(at: memos(key))
        try? FileManager.default.removeItem(at: caches(key))
    }

    static func purgeAll() {
        try? FileManager.default.removeItem(at: memosRoot)
        try? FileManager.default.removeItem(at: cachesBase.appending(path: "memos", directoryHint: .isDirectory))
    }
}

/// Small JSON files written off the main thread (one serial queue, latest write wins).
nonisolated enum MemoDisk {
    private static let queue = DispatchQueue(label: "hq.memo.disk", qos: .utility)

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            MemoPaths.ensure(url.deletingLastPathComponent())
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Waits for queued writes (tests, sign-out).
    static func flush() { queue.sync {} }
}

// MARK: - Drafts

/// A memo waiting in its chat's composer, with any words that were typed beside it (a queued memo handed back when its
/// chat was left: they go back into the field with it).
nonisolated struct MemoDraft: Codable, Hashable, Sendable {
    var memo: MemoFile
    var text: String?
}

/// Memo drafts per chat (spec §3.6), keyed by the chat's layout scope, newest first; the chip shows the first. A memo
/// handed back (a take left behind, a refused or withdrawn send, a queued memo removed or left behind) goes in front and
/// never deletes another: a recording only leaves the phone when it is sent or its chip's Remove is tapped. Survives
/// relaunch (paths rebased if iOS moved the app's container).
@MainActor final class MemoDraftStore {
    static let didChange = Notification.Name("hq.memo.drafts.changed")
    /// userInfo key: the scope that changed.
    static let scopeKey = "scope"

    private let file: URL
    private var drafts: [String: [MemoDraft]]

    init(accountKey: String) {
        file = MemoPaths.memos(accountKey).appending(path: "drafts.json")
        var loaded = MemoDisk.read([String: [MemoDraft]].self, from: file)
            ?? MemoDisk.read([String: MemoFile].self, from: file)?.mapValues { [MemoDraft(memo: $0)] }
            ?? [:]
        var changed = false
        for (scope, list) in loaded {
            // A draft whose recording is gone (cleared by iOS, a crash mid-save) is no draft.
            let kept = list.compactMap { draft -> MemoDraft? in
                var draft = draft
                draft.memo.path = MemoPaths.rebase(draft.memo.path)
                return FileManager.default.fileExists(atPath: draft.memo.path) ? draft : nil
            }
            if kept != list { changed = true; loaded[scope] = kept.isEmpty ? nil : kept }
        }
        drafts = loaded
        if changed { save() }
    }

    /// The scope's draft (its newest). A bot chat opened before its id was known kept its drafts under
    /// "<account>|<profile>|": they are found (and moved) once the chat knows its id.
    func draft(for scope: String) -> MemoFile? { entries(scope).first?.memo }

    /// Words kept with the scope's draft (nil when none).
    func text(for scope: String) -> String? { entries(scope).first?.text.flatMap { $0.isEmpty ? nil : $0 } }

    /// Every recording a draft refers to (the sweep keeps them).
    var paths: Set<String> { Set(drafts.values.flatMap { $0.map(\.memo.path) }) }

    /// `memo`: in front of the scope's drafts (moved there if it is already one). nil: Remove — the newest draft goes
    /// and its recording is deleted.
    func set(_ memo: MemoFile?, for scope: String) {
        var list = entries(scope)
        if let memo {
            if list.first?.memo == memo { return }
            let text = list.first(where: { $0.memo.path == memo.path })?.text
            list.removeAll { $0.memo.path == memo.path }
            list.insert(MemoDraft(memo: memo, text: text), at: 0)
        } else {
            guard !list.isEmpty else { return }
            let removed = list.removeFirst()
            MemoPaths.remove(removed.memo.path)
        }
        store(list, scope)
    }

    /// Memos handed back with their words (oldest first): in front of the scope's drafts, in that order. Nothing is
    /// deleted.
    func restore(_ items: [MemoDraft], for scope: String) {
        guard !items.isEmpty else { return }
        let paths = Set(items.map(\.memo.path))
        store(items + entries(scope).filter { !paths.contains($0.memo.path) }, scope)
    }

    /// Takes the scope's newest draft out of the store to send it: its file stays (touched, so the sweep sees it as
    /// fresh while it is in flight).
    @discardableResult
    func take(_ scope: String) -> MemoFile? {
        var list = entries(scope)
        guard !list.isEmpty else { return nil }
        let memo = list.removeFirst().memo
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: memo.path)
        store(list, scope)
        return memo
    }

    /// The words kept with the scope's newest draft went back into the field: they're no longer kept.
    func clearText(for scope: String) {
        var list = entries(scope)
        guard let first = list.first, first.text != nil else { return }
        list[0].text = nil
        drafts[scope] = list
        save()
    }

    /// The scope's drafts, moving a bare scope's ("<account>|<profile>|") to a full one that asks.
    private func entries(_ scope: String) -> [MemoDraft] {
        if let hit = drafts[scope], !hit.isEmpty { return hit }
        guard let bar = scope.lastIndex(of: "|"), scope.index(after: bar) < scope.endIndex else { return [] }
        let bare = String(scope[...bar])
        guard let early = drafts[bare], !early.isEmpty else { return [] }
        drafts[bare] = nil
        drafts[scope] = early
        save()
        return early
    }

    private func store(_ list: [MemoDraft], _ scope: String) {
        drafts[scope] = list.isEmpty ? nil : list
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.scopeKey: scope])
    }

    var all: [String: MemoFile] { drafts.compactMapValues { $0.first?.memo } }

    /// How many memo drafts an account keeps on this phone, read from its file without loading the store (Sign Out and
    /// Remove say how many recordings they delete). A draft whose recording is gone doesn't count.
    nonisolated static func savedCount(accountId: String) -> Int {
        let file = MemoPaths.memos(MemoPaths.accountKey(accountId)).appending(path: "drafts.json")
        let lists = MemoDisk.read([String: [MemoDraft]].self, from: file)
            ?? MemoDisk.read([String: MemoFile].self, from: file)?.mapValues { [MemoDraft(memo: $0)] }
            ?? [:]
        return lists.values.joined().filter { FileManager.default.fileExists(atPath: MemoPaths.rebase($0.memo.path)) }.count
    }

    private func save() { MemoDisk.write(drafts, to: file) }
}

// MARK: - Waveform shapes

nonisolated struct MemoShape: Codable, Hashable, Sendable {
    var peaks: [Double]
    var seconds: Double
    var at: Double
}

/// Waveforms by path, newest 64 (W:src/ui-voice/memo-peaks.ts:4-37). Your own memos are stored at save by their local
/// path and linked to the gateway path when the send's text is rewritten.
@MainActor final class MemoShapeStore {
    static let didChange = Notification.Name("hq.memo.shapes.changed")
    static let pathKey = "path"
    static let limit = 64

    private let file: URL
    private var shapes: [String: MemoShape]
    /// Paths whose computation failed this launch: never asked again.
    private(set) var failed = Set<String>()

    init(accountKey: String) {
        file = MemoPaths.memos(accountKey).appending(path: "shapes.json")
        shapes = MemoDisk.read([String: MemoShape].self, from: file) ?? [:]
    }

    func shape(for path: String) -> MemoShape? { shapes[path] }

    func remember(_ path: String, peaks: [Double], seconds: Double) {
        guard peaks.count == 48, seconds.isFinite, seconds > 0 else { return }
        shapes[path] = MemoShape(peaks: peaks, seconds: seconds, at: Date().timeIntervalSince1970)
        trim()
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.pathKey: path])
    }

    /// The gateway's copy has the same shape as the recording it came from.
    func link(_ local: String, to gateway: String) {
        guard let shape = shapes[local], local != gateway else { return }
        remember(gateway, peaks: shape.peaks, seconds: shape.seconds)
    }

    func markFailed(_ path: String) { failed.insert(path) }
    func unmarkFailed(_ path: String) { failed.remove(path) }

    var count: Int { shapes.count }

    private func trim() {
        guard shapes.count > Self.limit else { return }
        let keep = shapes.sorted { $0.value.at > $1.value.at }.prefix(Self.limit)
        shapes = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func save() { MemoDisk.write(shapes, to: file) }
}

// MARK: - Playback cache

/// Played gateway memos as local files (spec §6.2): LRU by last use, 64 files or 128 MB. A gateway path resolves to
/// the local recording it came from (an alias, then the moved file), else to a cached download.
nonisolated final class MemoPlaybackCache: Sendable {
    let folder: URL
    let maxFiles: Int
    let maxBytes: Int
    private let aliases = Mutex<[String: URL]>([:])
    private let flights = Mutex<[String: Task<URL, any Error>]>([:])

    init(accountKey: String, maxFiles: Int = 64, maxBytes: Int = 128 << 20) {
        folder = MemoPaths.caches(accountKey)
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
    }

    /// The cache file for a gateway path.
    func cacheURL(for path: String) -> URL {
        let ext = (path as NSString).pathExtension.lowercased()
        return folder.appending(path: MemoPaths.hex(path) + (ext.isEmpty ? "" : "." + ext))
    }

    /// A local file for `path` without the network: the file itself (local), an alias, or a cache hit (touched).
    func local(for path: String) -> URL? {
        let fm = FileManager.default
        if MemoPaths.isLocal(path) || path.hasPrefix(NSTemporaryDirectory()) {
            return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let alias = aliases.withLock({ $0[path] }), fm.fileExists(atPath: alias.path) { return alias }
        let cached = cacheURL(for: path)
        guard fm.fileExists(atPath: cached.path) else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
        return cached
    }

    /// While a send is in flight, the gateway path plays the local recording.
    func alias(_ gatewayPath: String, to local: URL) { aliases.withLock { $0[gatewayPath] = local } }

    /// The gateway accepted the memo (V9): the recording moves into the cache under its gateway path, so your own memo
    /// never downloads again.
    func adopt(_ local: URL, as gatewayPath: String) {
        let target = cacheURL(for: gatewayPath)
        let fm = FileManager.default
        MemoPaths.ensure(folder)
        try? fm.removeItem(at: target)
        if (try? fm.moveItem(at: local, to: target)) != nil {
            MemoPaths.remove(local.path)   // its empty UUID folder
            aliases.withLock { $0[gatewayPath] = nil }
            evict()
        }
    }

    /// Downloads `path` (`GET /api/fs/download?path=&profile=`), one flight per path, written off the main thread.
    func fetch(_ path: String, profile: String?, client: any GatewayClient) async throws -> URL {
        if let hit = local(for: path) { return hit }
        let task: Task<URL, any Error> = flights.withLock { flights in
            if let running = flights[path] { return running }
            let made = Task<URL, any Error>.detached(priority: .userInitiated) { [self] in
                defer { _ = self.flights.withLock { $0.removeValue(forKey: path) } }
                var query = [URLQueryItem(name: "path", value: path)]
                if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
                let data = try await client.rest("GET", "/api/fs/download", query: query, body: nil)
                guard !data.isEmpty else { throw HTTPError(status: 204, body: "empty") }
                MemoPaths.ensure(self.folder)
                let target = self.cacheURL(for: path)
                try data.write(to: target, options: .atomic)
                self.evict()
                return target
            }
            flights[path] = made
            return made
        }
        return try await task.value
    }

    /// Keeps the newest `maxFiles` / `maxBytes` by last use.
    func evict() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries = items.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }
        entries.sort { $0.1 > $1.1 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.2
            if index >= maxFiles || bytes > maxBytes { try? fm.removeItem(at: entry.0) }
        }
    }

    func purge() {
        aliases.withLock { $0 = [:] }
        try? FileManager.default.removeItem(at: folder)
    }

    var fileCount: Int { (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0 }
}

// MARK: - The signed-in account's memo stores

/// The stores for the account that is signed in (one at a time). `AppModel` activates it on sign-in and purges it on
/// sign-out; screens read `current`.
@MainActor final class MemoAccountStores {
    static let shared = MemoAccountStores()

    private(set) var accountId: String?
    private(set) var key: String?
    private(set) var drafts: MemoDraftStore?
    private(set) var shapes: MemoShapeStore?
    private(set) var cache: MemoPlaybackCache?
    /// Bumped on every account change: in-flight work for the previous account is dropped.
    private(set) var generation = 0

    func activate(accountId: String) {
        guard accountId != self.accountId else { return }
        generation += 1
        self.accountId = accountId
        let key = MemoPaths.accountKey(accountId)
        self.key = key
        let drafts = MemoDraftStore(accountKey: key)
        self.drafts = drafts
        shapes = MemoShapeStore(accountKey: key)
        cache = MemoPlaybackCache(accountKey: key)
        // Off the main thread: memos/ and memos/<key>/ stay out of backups (drafts.json and shapes.json hold account and
        // chat ids), and recordings a crash or a kill left behind go once a day old (not a draft's, nor a queued memo's).
        let keep = drafts.paths
        sweepTask = Task.detached(priority: .utility) {
            MemoPaths.excludeFromBackup(MemoPaths.memosRoot)
            MemoPaths.excludeFromBackup(MemoPaths.memos(key))
            MemoPaths.sweep(key: key, keeping: keep.union(QueueStash.memoPaths(accountId: accountId)))
        }
    }

    /// The sign-in's backup flags and sweep (tests wait for it).
    private(set) var sweepTask: Task<Void, Never>?

    /// Sign-out or an account switch: forget the stores (and, on sign-out, the files).
    func deactivate(purge: Bool) {
        generation += 1
        if purge, let accountId {
            MemoDisk.flush()
            MemoPaths.purge(accountId: accountId)
        }
        accountId = nil
        key = nil
        drafts = nil
        shapes = nil
        cache = nil
    }
}
