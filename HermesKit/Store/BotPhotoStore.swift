// [photoheads] Which bots wear a photo (docs/spec/3x-photoheads.md §4.2–4.4). The gateway's roster only says whether a
// profile has an avatar (`has_avatar`), never which one, so this store fetches each avatar (`profiles.get_asset`),
// decides what it is (`BotPicture`), and keeps the verdict, plus a small copy of a real photo, per gateway account.
//
// The avatar on the gateway is the truth (DECISION D3): a picture is fetched again when a row's `ui_meta` revisions
// move, when Bot Info opens, on pull to refresh, and never for this phone's own writes (`adopt`, `noteMetaWrite`).
// Fetches are silent: one at a time, 250 ms apart, only while the socket is up and the app is on screen. A failure
// changes nothing on screen (a bot always has a head) and is tried again after 30 s, 2 min and 10 min.

import CryptoKit
import Foundation

/// Timing knobs (§4.2, §4.3, §8.3). Tests shrink them.
nonisolated struct BotPhotoTiming: Sendable {
    var fetchTimeout: Duration = .seconds(30)
    /// The gap between two fetches.
    var spacing: Duration = .milliseconds(250)
    /// How long after a row's revisions moved the picture is fetched (the other device's upload is not awaited there).
    var revisionDelay: Duration = .seconds(2)
    /// When that answer is the picture already held: look once more this much later.
    var followUpDelay: Duration = .seconds(10)
    var retryLadder: [Duration] = [.seconds(30), .seconds(120), .seconds(600)]
    /// Bot Info and pull to refresh skip a bot checked this recently.
    var refreshGuard: Duration = .seconds(60)
    /// A head's desktop copy that failed to upload over a photo is sent again after these waits (§8.3).
    var mirrorRetries: [Duration] = [.seconds(2), .seconds(8)]
    /// The wait for a picture upload (`profiles.set_asset`) to answer (§8.1).
    var uploadTimeout: Duration = .seconds(30)

    /// What the app runs with. DEBUG: `-HQDebugUploadTimeout <seconds>` shortens the wait for a picture upload, so a UI
    /// test of "no gateway on Save" does not sit through the real 30 s (App/Debug/DebugHooks.swift).
    static let standard: BotPhotoTiming = {
        var timing = BotPhotoTiming()
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "HQDebugUploadTimeout")
        if seconds > 0 { timing.uploadTimeout = .milliseconds(Int(seconds * 1000)) }
        #endif
        return timing
    }()
}

/// One bot's verdict as stored in `index.json` (§4.4).
nonisolated struct BotPhotoEntry: Codable, Sendable, Equatable {
    var verdict: BotPicture.Verdict
    var fingerprint: String
    /// `ui_meta_revisions["hermes-bots"]` and `["dispatch-head"]` when the picture was read.
    var bots: Int
    var head: Int
    /// When it was read (seconds since 1970).
    var at: Double
    var w: Int
    var h: Int
}

nonisolated struct BotPhotoIndexFile: Codable, Sendable {
    var version = 1
    var entries: [String: BotPhotoEntry] = [:]
    /// The Bots list's order when it was last drawn (the first of these are decoded before the first frame).
    var order: [String] = []
    /// Whether this gateway stores bot pictures, as its last roster answer said (nil: a file written before this was kept).
    var assets: Bool?
}

/// One serial background queue for the picture files, so a write, a removal and a read of one file never cross.
nonisolated final class BotPhotoDisk: @unchecked Sendable {
    static let shared = BotPhotoDisk()
    private let queue = DispatchQueue(label: "hermeshq.bot-photos", qos: .utility)

    func write(_ data: Data, to url: URL) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            } catch {
                // Full or unavailable storage: the picture is fetched again next launch.
                AppLog.swallowed("store", "write bot photo \(url.lastPathComponent)", error)
            }
        }
    }

    func remove(_ url: URL) {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    func read(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: try? Data(contentsOf: url)) }
        }
    }

    /// Keeps the `keep` most recently used picture folders besides `current` (the roster cache keeps 3 accounts too).
    func prune(_ directory: URL, current: URL, keep: Int) {
        queue.async {
            let fm = FileManager.default
            guard let found = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let others = found.filter { BotPhotoStore.isFolder($0.lastPathComponent) && $0.lastPathComponent != current.lastPathComponent }
            guard others.count > keep else { return }
            let dated = others.map { url -> (URL, Date) in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: url) }
        }
    }

    func flush() { queue.sync {} }
}

@MainActor
final class BotPhotoStore {
    nonisolated static let folderPrefix = "botphotos-"
    nonisolated static let indexName = "index.json"

    let account: GatewayAccount
    /// `<cacheDirectory>/botphotos-<account key>/`.
    let folder: URL
    let timing: BotPhotoTiming

    /// What each fetched avatar turned out to be. A bot the roster says has no avatar has no entry (its verdict is `none`).
    private(set) var entries: [String: BotPhotoEntry] = [:]
    /// The Bots list's order, as last told.
    private(set) var order: [String] = []
    /// Whether any roster row carried a `has_avatar` key. False on a gateway older than the asset store: nothing is
    /// ever fetched there (§4.3, §5.6). Kept in `index.json`, so a gateway this phone has seen before is known from
    /// the first frame of the next launch, before its roster answers.
    private(set) var supportsAssets = false
    /// A bot's face changed (verdict or picture). Main actor.
    var onChange: ((_ profile: String) -> Void)?
    /// `supportsAssets` changed (the first roster answer of a gateway never seen before, or an older gateway). Main actor.
    var onSupportChange: (() -> Void)?

    private struct Pair: Equatable { var bots = 0; var head = 0 }
    private enum Reason { case first, revision, followUp, refresh }
    private struct Pending {
        var due: ContinuousClock.Instant
        var reason: Reason
        /// How many times this fetch has failed (the next wait on the ladder).
        var attempt = 0
    }

    private let client: any GatewayClient
    private let disk: BotPhotoDisk
    private let indexURL: URL
    /// What the newest roster said per bot.
    private var rows: [String: (has: Bool, pair: Pair)] = [:]
    private var rank: [String: Int] = [:]
    private var pending: [String: Pending] = [:]
    /// Bots whose fetch failed through the whole ladder: tried again on reconnect or when asked for.
    private var exhausted: Set<String> = []
    /// Bumped whenever this phone learns a bot's picture another way: a fetch answer older than that is dropped.
    private var tokens: [String: Int] = [:]
    /// When this phone last wrote a bot's picture or meta: a roster read sent before that says nothing new about it.
    private var writtenAt: [String: Date] = [:]
    private var checkedAt: [String: ContinuousClock.Instant] = [:]
    /// How often a bot's kept file could not be drawn this run (`discardUnreadable`).
    private var discards: [String: Int] = [:]
    /// Bots whose photo a head save replaced on this phone and whose desktop copy has not been stored yet (§8.3).
    private(set) var awaitingMirror: Set<String> = []
    private var focus: String?
    private var fetching: String?
    private var lastFetchEnded: ContinuousClock.Instant?
    private var connected = false
    private var active = true
    private var started = false
    private var statesTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var napTask: Task<Void, Never>?
    /// Fetches sent, for tests and the stress run.
    private(set) var fetchCount = 0

    init(client: any GatewayClient, account: GatewayAccount, cacheDirectory: URL, timing: BotPhotoTiming = .standard,
         disk: BotPhotoDisk = .shared) {
        self.client = client
        self.account = account
        self.timing = timing
        self.disk = disk
        folder = Self.folder(cacheDirectory, account)
        indexURL = folder.appendingPathComponent(Self.indexName)
        // A missing or damaged index means "no verdicts": every picture is fetched again, nothing crashes.
        if let file = RosterDisk.read(BotPhotoIndexFile.self, from: indexURL) {
            order = file.order
            supportsAssets = file.assets ?? false
            // A photo whose file is gone has nothing to draw: forget the verdict so it is fetched again.
            entries = file.entries.filter { name, entry in
                entry.verdict != .photo || FileManager.default.fileExists(atPath: Self.fileURL(folder, name).path)
            }
        }
        rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        disk.prune(cacheDirectory, current: folder, keep: 3)
    }

    // MARK: - Where things are kept

    nonisolated static func folder(_ cacheDirectory: URL, _ account: GatewayAccount) -> URL {
        cacheDirectory.appendingPathComponent(folderPrefix + RosterDisk.accountKey(account), isDirectory: true)
    }

    /// Whether a name in the cache directory is one account's picture folder.
    nonisolated static func isFolder(_ name: String) -> Bool {
        guard name.hasPrefix(folderPrefix) else { return false }
        let key = name.dropFirst(folderPrefix.count)
        return key.count == RosterDisk.accountKeyLength && key.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// A profile's picture file: named by a hash, so any profile name (spaces, emoji, 200 characters) is a valid file name.
    nonisolated static func fileName(_ profile: String) -> String {
        SHA256.hash(data: Data(profile.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    nonisolated static func fileURL(_ folder: URL, _ profile: String) -> URL { folder.appendingPathComponent(fileName(profile)) }

    /// Forget an account's pictures without a store (a saved gateway being removed).
    nonisolated static func purge(cacheDirectory: URL, account: GatewayAccount, disk: BotPhotoDisk = .shared) {
        disk.remove(folder(cacheDirectory, account))
    }

    // MARK: - Reads

    /// nil = not known yet (the head shows).
    func verdict(for profile: String) -> BotPicture.Verdict? {
        if let entry = entries[profile] { return entry.verdict }
        if let row = rows[profile], !row.has { return BotPicture.Verdict.none }
        return nil
    }

    func hasPhoto(_ profile: String) -> Bool { entries[profile]?.verdict == .photo }

    /// A photo's fingerprint (nil when the head wins).
    func fingerprint(for profile: String) -> String? {
        guard let entry = entries[profile], entry.verdict == .photo else { return nil }
        return entry.fingerprint
    }

    func photoURL(for profile: String) -> URL? { hasPhoto(profile) ? Self.fileURL(folder, profile) : nil }

    /// The kept copy's bytes, read after any write still on its way.
    func photoData(for profile: String) async -> Data? {
        guard let url = photoURL(for: profile) else { return nil }
        return await disk.read(url)
    }

    /// The kept copy could not be drawn (a damaged file): forget it and fetch the picture again. Twice in one run at
    /// most: a phone that cannot keep the file at all (no storage left) would otherwise fetch it for ever. After that
    /// the bot wears its head until the socket reconnects, Bot Info opens or the list is pulled.
    func discardUnreadable(_ profile: String) {
        guard entries[profile]?.verdict == .photo else { return }
        bump(profile)
        entries[profile] = nil
        disk.remove(Self.fileURL(folder, profile))
        saveIndex()
        onChange?(profile)
        guard supportsAssets, rows[profile]?.has == true else { return }
        let times = discards[profile, default: 0] + 1
        discards[profile] = times
        if times <= Self.discardLimit {
            pending[profile] = Pending(due: .now, reason: .first)
            pump()
        } else {
            exhausted.insert(profile)
        }
    }

    nonisolated static let discardLimit = 2

    var pendingCount: Int { pending.count }
    var isIdle: Bool { pending.isEmpty && fetching == nil }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let client = self.client
        statesTask = Task { [weak self] in
            for await state in client.connectionStates() {
                guard let self else { return }
                self.connectionChanged(state == .ready)
            }
        }
    }

    /// Stop every task (sign-out, account switch). The cache stays.
    func stop() {
        started = false
        connected = false
        statesTask?.cancel(); statesTask = nil
        pumpTask?.cancel(); pumpTask = nil
        napTask?.cancel(); napTask = nil
        pending = [:]
        exhausted = []
        // An answer still on its way belongs to the run that just ended.
        if let fetching { tokens[fetching, default: 0] += 1 }
        for name in Array(tokens.keys) where name != fetching { tokens[name, default: 0] += 1 }
    }

    /// Forget this account's pictures (sign-out of the account).
    func removeCachedData() {
        let had = entries.filter { $0.value.verdict == .photo }.map(\.key)
        for name in Set(entries.keys).union(rows.keys) { bump(name) }
        entries = [:]
        rows = [:]
        pending = [:]
        exhausted = []
        awaitingMirror = []
        disk.remove(folder)
        for name in had { onChange?(name) }
    }

    func appDidBecomeActive() {
        active = true
        pump()
    }

    func appDidEnterBackground() {
        active = false
        napTask?.cancel()
    }

    /// The open chat's bot: its picture is fetched first.
    func setFocus(_ profile: String?) {
        guard focus != profile else { return }
        focus = profile
        if let profile, pending[profile] != nil { napTask?.cancel() }
    }

    private func connectionChanged(_ ready: Bool) {
        guard started, ready != connected else { return }
        connected = ready
        guard ready else { return }
        // The ladder starts over on reconnect (§4.2).
        let now = ContinuousClock.now
        for (name, item) in pending where item.attempt > 0 { pending[name] = Pending(due: now, reason: item.reason) }
        for name in exhausted where rows[name]?.has == true && pending[name] == nil { pending[name] = Pending(due: now, reason: .first) }
        exhausted = []
        napTask?.cancel()
        pump()
    }

    // MARK: - Signals

    /// A roster answer (§4.3). `issuedAt` is when its read was sent: a row older than this phone's own write of that
    /// bot's picture or meta says nothing new about it.
    func rowsArrived(_ profiles: [RosterProfile], order newOrder: [String], issuedAt: Date) {
        guard !profiles.isEmpty else { return }
        guard profiles.contains(where: { $0.raw["has_avatar"] != nil }) else {
            // A gateway older than the asset store: do nothing, ever.
            if supportsAssets {
                supportsAssets = false
                saveIndex()
                onSupportChange?()
            }
            return
        }
        var dirty = false
        let learned = !supportsAssets
        if learned {
            supportsAssets = true
            dirty = true
        }
        defer { if learned { onSupportChange?() } }
        if newOrder != order, !newOrder.isEmpty {
            order = newOrder
            rank = Dictionary(newOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            dirty = true
        }
        let now = ContinuousClock.now
        var seen = Set<String>()
        var hurried = false
        for profile in profiles {
            let name = profile.name
            seen.insert(name)
            if let written = writtenAt[name] {
                if written > issuedAt { continue }
                writtenAt[name] = nil
            }
            let pair = Pair(bots: profile.uiMetaRevision(BotStore.botsKey), head: profile.uiMetaRevision(BotStore.headKey))
            let previous = rows[name]?.pair
            rows[name] = (profile.hasAvatar, pair)
            guard profile.hasAvatar else {
                // No avatar: the head, at once, and no call.
                if pending[name] != nil || fetching == name { bump(name) }
                exhausted.remove(name)
                if let old = entries.removeValue(forKey: name) {
                    if old.verdict == .photo { disk.remove(Self.fileURL(folder, name)) }
                    dirty = true
                    if old.verdict == .photo { onChange?(name) }
                }
                continue
            }
            if let waiting = pending[name] {
                // A retry waiting on the ladder, and the row just said the picture moved again: that is news, so the
                // retry comes forward (stress round 1: a changed picture sat behind a 10 minute wait). The same row
                // again changes nothing.
                if waiting.attempt > 0, let previous, previous != pair, waiting.due > now + timing.revisionDelay {
                    pending[name]?.due = now + timing.revisionDelay
                    hurried = true
                }
                continue
            }
            guard fetching != name else { continue }
            if let entry = entries[name] {
                if entry.bots != pair.bots || entry.head != pair.head {
                    pending[name] = Pending(due: now + timing.revisionDelay, reason: .revision)
                }
            } else if !exhausted.contains(name) {
                pending[name] = Pending(due: now, reason: .first)
            }
        }
        // A bot that is gone takes its picture with it.
        for name in Set(entries.keys).union(rows.keys).union(pending.keys) where !seen.contains(name) {
            bump(name)
            rows[name] = nil
            exhausted.remove(name)
            if let old = entries.removeValue(forKey: name) {
                if old.verdict == .photo { disk.remove(Self.fileURL(folder, name)); onChange?(name) }
                dirty = true
            }
        }
        if dirty { saveIndex() }
        if hurried { napTask?.cancel() }
        pump()
    }

    /// Bot Info opened for this bot, or the list was pulled: look again unless it was checked in the last minute.
    /// A bot whose last fetch failed and is waiting on the ladder is tried now instead (once per ask; a further
    /// failure goes on up the ladder): the person asked, so the wait is not theirs to sit through.
    func refresh(_ profile: String) {
        guard supportsAssets, started, rows[profile]?.has == true, fetching != profile else { return }
        if let waiting = pending[profile] {
            guard waiting.attempt > 0, waiting.due > .now else { return }
            pending[profile]?.due = .now
            napTask?.cancel()
            pump()
            return
        }
        if let checked = checkedAt[profile], ContinuousClock.now - checked < timing.refreshGuard { return }
        exhausted.remove(profile)
        pending[profile] = Pending(due: .now, reason: .refresh)
        napTask?.cancel()
        pump()
    }

    /// Pull to refresh: every bot the roster says has an avatar.
    func refreshAll() {
        for (name, row) in rows where row.has { refresh(name) }
    }

    /// This phone just stored `dataURL` as the bot's avatar (a photo, a head's desktop copy), or removed it (nil): the
    /// faces change now and nothing is fetched.
    func adopt(_ profile: String, dataURL: String?) async {
        let token = bump(profile)
        writtenAt[profile] = Date()
        checkedAt[profile] = .now
        exhausted.remove(profile)
        awaitingMirror.remove(profile)
        let pair = rows[profile]?.pair ?? entries[profile].map { Pair(bots: $0.bots, head: $0.head) } ?? Pair()
        guard let dataURL, !dataURL.isEmpty else {
            rows[profile] = (false, pair)
            if let old = entries.removeValue(forKey: profile) {
                if old.verdict == .photo { disk.remove(Self.fileURL(folder, profile)) }
                saveIndex()
                if old.verdict == .photo { onChange?(profile) }
            }
            return
        }
        rows[profile] = (true, pair)
        let classified = await Self.classify(found: true, dataURL: dataURL)
        guard tokens[profile, default: 0] == token else { return }       // a later write of this bot's picture won
        apply(profile, classified, pair: pair)
    }

    /// This phone's own `profiles.configure` moved a `ui_meta` revision: that is not another device's change.
    func noteMetaWrite(_ profile: String, key: String, revision: Int) {
        guard key == BotStore.botsKey || key == BotStore.headKey else { return }
        writtenAt[profile] = Date()
        let isBots = key == BotStore.botsKey
        if var row = rows[profile] {
            if isBots { row.pair.bots = max(row.pair.bots, revision) } else { row.pair.head = max(row.pair.head, revision) }
            rows[profile] = row
        }
        guard var entry = entries[profile] else { return }
        let recorded = isBots ? entry.bots : entry.head
        // Only the very next revision is surely ours alone; a gap means another device wrote in between, and the next
        // roster's difference fetches the picture.
        guard revision == recorded + 1 else { return }
        if isBots { entry.bots = revision } else { entry.head = revision }
        entries[profile] = entry
        saveIndex()
        // A fetch waiting only because of this revision has nothing left to look for.
        if let item = pending[profile], item.reason == .revision, rows[profile].map({ $0.pair.bots == entry.bots && $0.pair.head == entry.head }) ?? true {
            pending[profile] = nil
        }
    }

    /// A head was just saved for this bot from this phone (DECISION D4): a photo it wore is dropped here at once; the
    /// head's desktop copy replaces it on the gateway next. True when a photo was dropped.
    @discardableResult
    func headSaved(_ profile: String) -> Bool {
        bump(profile)
        writtenAt[profile] = Date()
        guard let entry = entries[profile], entry.verdict == .photo else { return false }
        entries[profile] = BotPhotoEntry(verdict: .mirror, fingerprint: "", bots: entry.bots, head: entry.head,
                                         at: Date().timeIntervalSince1970, w: 0, h: 0)
        disk.remove(Self.fileURL(folder, profile))
        awaitingMirror.insert(profile)
        saveIndex()
        onChange?(profile)
        return true
    }

    // MARK: - The queue

    @discardableResult
    private func bump(_ profile: String) -> Int {
        let next = tokens[profile, default: 0] + 1
        tokens[profile] = next
        pending[profile] = nil
        return next
    }

    private func pump() {
        guard pumpTask == nil, started, connected, active, !pending.isEmpty else { return }
        pumpTask = Task(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !Task.isCancelled, started, connected, active {
            let now = ContinuousClock.now
            guard let next = nextFetch(now) else { break }
            var due = next.due
            if let ended = lastFetchEnded, ended + timing.spacing > due { due = ended + timing.spacing }
            if due > now {
                // Sleep until the next one is due; anything that changes the plan cancels the nap.
                let nap = Task<Void, Never> { _ = try? await Task.sleep(until: due, clock: .continuous) }
                napTask = nap
                await nap.value
                if napTask == nap { napTask = nil }
                continue
            }
            await fetch(next.name)
            lastFetchEnded = .now
        }
        // A cancelled run was replaced by `stop` (and maybe a new run): it must not clear its successor.
        if Task.isCancelled { return }
        pumpTask = nil
        pump()       // something queued while the last fetch was finishing
    }

    /// The fetch to make now (the open chat's bot first, then list order), or the one that comes due soonest.
    private func nextFetch(_ now: ContinuousClock.Instant) -> (name: String, due: ContinuousClock.Instant)? {
        guard !pending.isEmpty else { return nil }
        func place(_ name: String) -> (Int, Int, String) { (name == focus ? 0 : 1, rank[name] ?? Int.max, name) }
        let ready = pending.filter { $0.value.due <= now }.keys
        if let name = ready.min(by: { place($0) < place($1) }) { return (name, now) }
        guard let soonest = pending.min(by: { $0.value.due < $1.value.due }) else { return nil }
        return (soonest.key, soonest.value.due)
    }

    private func fetch(_ name: String) async {
        guard let item = pending.removeValue(forKey: name) else { return }
        let token = tokens[name, default: 0]
        let pair = rows[name]?.pair ?? Pair()
        let before = entries[name]
        fetching = name
        fetchCount += 1
        defer { if fetching == name { fetching = nil } }
        let client = self.client, timeout = timing.fetchTimeout
        do {
            let result = try await client.call("profiles.get_asset", ["name": .string(name), "asset": "avatar"], timeout: timeout)
            guard started, tokens[name, default: 0] == token else { return }
            let found = result["found"]?.bool == true
            let classified = await Self.classify(found: found, dataURL: result["data"]?.string)
            guard started, tokens[name, default: 0] == token else { return }
            checkedAt[name] = .now
            exhausted.remove(name)
            if item.reason == .revision, let before, before.verdict == classified.verdict, before.fingerprint == classified.fingerprint {
                // The same picture as before: the other device's upload may still be on its way. Look once more, then
                // take the answer as it is.
                pending[name] = Pending(due: .now + timing.followUpDelay, reason: .followUp)
                return
            }
            apply(name, classified, pair: pair)
        } catch {
            // Silent (§4.2): whatever showed keeps showing; the next try waits on the ladder.
            guard started, tokens[name, default: 0] == token, pending[name] == nil else { return }
            if item.attempt < timing.retryLadder.count {
                pending[name] = Pending(due: .now + timing.retryLadder[item.attempt], reason: item.reason, attempt: item.attempt + 1)
            } else {
                exhausted.insert(name)
            }
        }
    }

    private func apply(_ name: String, _ classified: BotPicture.Classified, pair: Pair) {
        let old = entries[name]
        let entry = BotPhotoEntry(verdict: classified.verdict, fingerprint: classified.fingerprint, bots: pair.bots, head: pair.head,
                                  at: Date().timeIntervalSince1970, w: classified.width, h: classified.height)
        entries[name] = entry
        let url = Self.fileURL(folder, name)
        let same = old?.verdict == entry.verdict && old?.fingerprint == entry.fingerprint
        if classified.verdict == .photo, let png = classified.png {
            if !same { disk.write(png, to: url) }
        } else if old?.verdict == .photo {
            disk.remove(url)
        }
        saveIndex()
        if !same { onChange?(name) }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(BotPhotoIndexFile(entries: entries, order: order, assets: supportsAssets)) else { return }
        disk.write(data, to: indexURL)
    }

    /// Decoding and downsampling happen off the main actor.
    private nonisolated static func classify(found: Bool, dataURL: String?) async -> BotPicture.Classified {
        await Task.detached(priority: .utility) { BotPicture.classify(found: found, dataURL: dataURL) }.value
    }

    isolated deinit {
        statesTask?.cancel()
        pumpTask?.cancel()
        napTask?.cancel()
    }
}
