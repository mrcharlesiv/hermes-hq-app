// Durable chat-tail cache (spec 03 §7.2, native M1 sizing §7.2.1).
//
// Key: (account id, profile, stored session id). Location:
//   Application Support/transcripts/<accountKey>/<profile>/<storedId>.hqt   (accountKey = SHA-256 prefix of the account id)
// Entry: newest 40 messages, tool details reduced to short heads; ≤256 KiB encoded, else 40 without tool details, then
// the web's ladder 8 → 3 → 1 → a `partial` display copy (used only for the offline cold-launch restore). 64 entries /
// 16 MiB on disk, LRU by last read or write, the chat on screen is never evicted. ≤8 decoded entries kept in memory. `load` is synchronous (it runs inside the push) and reads one small
// file at most; `save` updates memory at once and writes 100 ms later, coalesced per chat, atomically, off the main thread.

import CryptoKit
import Foundation
import Synchronization

nonisolated final class TranscriptCache: Sendable {
    nonisolated struct Key: Hashable, Sendable {
        var account: String
        var profile: String
        var storedId: String
    }

    nonisolated struct Limits: Sendable {
        var messagesPerEntry = 40
        var entryBytes = 256 * 1024
        var maxEntries = 64
        var totalBytes = 16 * 1024 * 1024
        var memoryEntries = 8
        var writeDelay: Duration = .milliseconds(100)
    }

    static let shared = TranscriptCache()

    let root: URL
    let limits: Limits

    nonisolated private struct IndexEntry: Codable, Sendable { var bytes: Int; var used: Double; var saved: Double }
    nonisolated private struct State: Sendable {
        var memory: [Key: TranscriptEntry] = [:]
        var memoryOrder: [Key] = []              // most recent last
        var index: [String: IndexEntry] = [:]     // by relative path
        var indexLoaded = false
        var pending: [Key: (entry: TranscriptEntry, generation: Int)] = [:]
        var generation = 0
        var visible: Set<Key> = []
        var purgeGeneration = 0
        /// [load-cache] Chats deleted this run (`account` + "\n" + stored id): a later save of one is dropped, so the
        /// chat deleted from its own screen doesn't write its tail back as it closes.
        var deleted: Set<String> = []
        /// [13-7] Accounts purged this run (signed out, or the gateway removed): a chat still open as the screen
        /// changes saves its tail as it closes, and that save is dropped until the account is signed in again.
        var purged: Set<String> = []
    }

    private let state = Mutex(State())
    private let io = DispatchQueue(label: "hq.transcript-cache", qos: .utility)

    init(root: URL? = nil, limits: Limits = Limits()) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = base.appending(path: "transcripts", directoryHint: .isDirectory)
        }
        self.limits = limits
    }

    // MARK: Keys and paths

    static func accountKey(_ accountId: String) -> String {
        let digest = SHA256.hash(data: Data(accountId.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeComponent(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "default" : trimmed
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded == "." || encoded == ".." ? "%2E" + encoded : encoded
    }

    static func key(account: String, profile: String, storedId: String) -> Key {
        let p = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        return Key(account: account, profile: p.isEmpty ? "default" : p, storedId: storedId)
    }

    private func relativePath(_ key: Key) -> String {
        "\(Self.accountKey(key.account))/\(Self.safeComponent(key.profile))/\(Self.safeComponent(key.storedId)).hqt"
    }

    private func fileURL(_ relative: String) -> URL { root.appending(path: relative, directoryHint: .notDirectory) }
    private var indexURL: URL { root.appending(path: "index.json", directoryHint: .notDirectory) }

    // MARK: Reads (main thread, synchronous, fast)

    /// The cached tail for a chat, nil when there is none (partial offline copies are not returned here).
    func load(account: String, profile: String, storedId: String) -> [ChatMessage]? {
        loadEntry(account: account, profile: profile, storedId: storedId)?.messages
    }

    func loadEntry(account: String, profile: String, storedId: String, allowPartial: Bool = false) -> TranscriptEntry? {
        let key = Self.key(account: account, profile: profile, storedId: storedId)
        let rel = relativePath(key)
        let now = Date().timeIntervalSince1970
        if let hit = state.withLock({ s -> TranscriptEntry? in
            if let pending = s.pending[key] { touchMemory(&s, key, pending.entry); s.index[rel]?.used = now; return pending.entry }
            guard let entry = s.memory[key] else { return nil }
            touchMemory(&s, key, entry)
            s.index[rel]?.used = now
            return entry
        }) {
            return (hit.partial && !allowPartial) ? nil : hit
        }
        let url = fileURL(rel)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let entry = try? TranscriptEntry.decode(data) else {
            // Corrupt or truncated: drop it so every later open doesn't pay (or trip over) it again.
            // [diagnostics] §7: the chat opens without its saved copy; say so once (sizes only, never content).
            ScreenFault.report(screen: "chat", message: "saved chat could not be read (\(data.count) bytes)", path: ["TranscriptCache"])
            state.withLock { s in s.index[rel] = nil }
            io.async { [self] in
                // Re-check on the writer queue: a save may have replaced the file meanwhile.
                guard let again = try? Data(contentsOf: url), (try? TranscriptEntry.decode(again)) == nil else { return }
                try? FileManager.default.removeItem(at: url)
                saveIndexIfNeeded(force: true)
            }
            return nil
        }
        state.withLock { s in
            touchMemory(&s, key, entry)
            if s.index[rel] != nil { s.index[rel]?.used = now }
        }
        return (entry.partial && !allowPartial) ? nil : entry
    }

    /// When the chat's tail was saved (staleness, spec 03 §4.1: `savedAt + 1 s < last_active`).
    func savedAt(account: String, profile: String, storedId: String) -> Date? {
        loadEntry(account: account, profile: profile, storedId: storedId, allowPartial: true)?.savedAt
    }

    /// [perf] `savedAt` without the decode: the warmer asks this of ~30 chats per check, and through `loadEntry` each
    /// miss read and decoded a whole tail on main and pushed it into the 8-entry memory LRU, evicting the tails the owner
    /// actually opens. This reads the pending or in-memory copy, else the file's 13-byte header, and touches no LRU.
    func savedAtPeek(account: String, profile: String, storedId: String) -> Date? {
        let key = Self.key(account: account, profile: profile, storedId: storedId)
        if let hit = state.withLock({ s in s.pending[key]?.entry.savedAt ?? s.memory[key]?.savedAt }) { return hit }
        guard let handle = try? FileHandle(forReadingFrom: fileURL(relativePath(key))) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 13), head.count == 13 else { return nil }
        return TranscriptEntry.peekSavedAt(head)
    }

    private func touchMemory(_ s: inout State, _ key: Key, _ entry: TranscriptEntry) {
        s.memory[key] = entry
        s.memoryOrder.removeAll { $0 == key }
        s.memoryOrder.append(key)
        while s.memoryOrder.count > limits.memoryEntries {
            let old = s.memoryOrder.removeFirst()
            if !s.visible.contains(old) { s.memory[old] = nil } else { s.memoryOrder.append(old); break }
        }
    }

    // MARK: Writes

    /// Saves the newest messages of a chat. Pending/streaming messages are skipped (backend truth only); tool details are
    /// reduced to their cache copy (`ToolDetail.slimmedForCache`, the inline diff only for the newest turn).
    func save(_ messages: [ChatMessage], meta: [String: MessageMeta], account: String, profile: String, storedId: String,
              savedAt: Date = Date()) {
        let key = Self.key(account: account, profile: profile, storedId: storedId)
        let settled = messages.filter { !$0.isPending && !$0.isStreaming }
        let tail = Array(settled.suffix(limits.messagesPerEntry)).map { m -> ChatMessage in var c = m; c.revision = 0; return c }
        let newestAssistant = tail.last { $0.role == .assistant }?.id
        var tailMeta: [String: MessageMeta] = [:]
        for m in tail {
            guard var mm = meta[m.id] else { continue }
            if !mm.tools.isEmpty {
                let keepDiff = m.id == newestAssistant
                mm.tools = mm.tools.mapValues { $0.isCacheCopy ? $0 : $0.slimmedForCache(keepDiff: keepDiff) }
            }
            tailMeta[m.id] = mm
        }
        let entry = TranscriptEntry(messages: tail, meta: tailMeta, savedAt: savedAt)
        guard let generation = state.withLock({ s -> Int? in
            guard !s.deleted.contains(Self.deletedKey(account, storedId)), !s.purged.contains(account) else { return nil }
            s.generation += 1
            s.pending[key] = (entry, s.generation)
            touchMemory(&s, key, entry)
            return s.generation
        }) else { return }
        let delay = limits.writeDelay
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        io.asyncAfter(deadline: .now() + seconds) { [self] in
            write(key, generation: generation)
        }
    }

    /// Writes everything pending now and waits (app backgrounding, tests).
    func flush() {
        io.sync {
            let keys = state.withLock { Array($0.pending.keys) }
            for key in keys { write(key, generation: nil) }
            saveIndexIfNeeded(force: true)
        }
    }

    /// The chat on screen is never evicted (pass nil when it closes).
    func setVisible(_ key: Key?, visible: Bool = true) {
        guard let key else { return }
        state.withLock { s in if visible { s.visible.insert(key) } else { s.visible.remove(key) } }
    }

    private func write(_ key: Key, generation: Int?) {
        guard let job = state.withLock({ s -> (TranscriptEntry, Int)? in
            guard let p = s.pending[key], generation == nil || p.generation == generation else { return nil }
            s.pending[key] = nil
            return (p.entry, s.purgeGeneration)
        }) else { return }
        let (entry, purgeGeneration) = job
        loadIndexIfNeeded()
        let rel = relativePath(key)
        let url = fileURL(rel)
        guard let data = admit(entry) else {
            AppLog.trace("store", "transcript cache: a newer tail wasn't admitted, kept the older one marked stale")
            markStale(url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            excludeRootFromBackup()
            guard state.withLock({ $0.purgeGeneration == purgeGeneration }) else { return }
            try data.write(to: url, options: [.atomic])
            let now = Date().timeIntervalSince1970
            state.withLock { s in s.index[rel] = IndexEntry(bytes: data.count, used: now, saved: entry.savedAt.timeIntervalSince1970) }
        } catch {
            AppLog.swallowed("store", "write transcript cache tail", error)
            return
        }
        evictIfNeeded()
        saveIndexIfNeeded(force: true)
    }

    /// The size ladder (R:src/transcript-persistence.ts:221-262): 40 → 40 without tool details → 8 → 3 → 1 → partial
    /// copy; nil = can't admit. The native-only second rung keeps a tool-heavy chat's whole first screen.
    func admit(_ entry: TranscriptEntry) -> Data? {
        let full = entry.encoded()
        if full.count <= limits.entryBytes { return full }
        let stripped = Self.withoutToolDetails(entry)
        if stripped != entry {
            let data = stripped.encoded()
            if data.count <= limits.entryBytes { return data }
        }
        for count in [8, 3, 1] where count < entry.messages.count {
            var smaller = entry
            smaller.messages = Array(entry.messages.suffix(count))
            smaller.meta = entry.meta.filter { id, _ in smaller.messages.contains { $0.id == id } }
            let data = smaller.encoded()
            if data.count <= limits.entryBytes { return data }
        }
        var cap = 8000
        while cap >= 250 {
            let data = Self.partialCopy(entry, textCap: cap).encoded()
            if data.count <= limits.entryBytes { return data }
            cap /= 2
        }
        return nil
    }

    /// Same messages; step-sheet details dropped and tool args cut to 512 bytes (the rows still draw).
    static func withoutToolDetails(_ entry: TranscriptEntry) -> TranscriptEntry {
        var out = entry
        out.messages = entry.messages.map { m in
            guard m.parts.contains(where: TranscriptMerge.isTool) else { return m }
            var c = m
            c.parts = m.parts.map { part in
                // [drafts] A draft call keeps its words: its card is drawn from them (cut, it would draw as a plain step).
                guard case .tool(var call) = part, call.name != DraftCards.tool else { return part }
                call.argsText = call.argsText.map { ChatText.clip($0, max: 512) }
                return .tool(call)
            }
            return c
        }
        out.meta = entry.meta.compactMapValues { mm in
            var c = mm
            c.tools = [:]
            return c.isDefault ? nil : c
        }
        return out
    }

    static let partialNote = "\n\n… _Shortened offline copy. Reconnect to load the rest._"

    /// Bounded display copy of the newest ≤3 messages (texts ≤ cap chars, tools without args/results, ≤24 parts).
    static func partialCopy(_ entry: TranscriptEntry, textCap: Int) -> TranscriptEntry {
        func cut(_ t: String) -> String { t.count <= textCap ? t : String(t.prefix(textCap)) + partialNote }
        let messages = entry.messages.suffix(3).map { m -> ChatMessage in
            var c = m
            c.parts = m.parts.prefix(24).map { part in
                switch part {
                case .text(let t): return .text(cut(t))
                case .reasoning(let t): return .reasoning(cut(t))
                case .tool(var call):
                    call.argsText = nil
                    call.summary = "Output left out of the offline copy."
                    return .tool(call)
                }
            }
            return c
        }
        var meta: [String: MessageMeta] = [:]
        for m in messages { if var mm = entry.meta[m.id] { mm.tools = [:]; if !mm.isDefault { meta[m.id] = mm } } }
        return TranscriptEntry(messages: Array(messages), meta: meta, savedAt: entry.savedAt, partial: true)
    }

    /// A newer tail that can't be admitted never deletes the older one: keep it, marked stale.
    private func markStale(_ url: URL) {
        guard var data = try? Data(contentsOf: url), data.count > 12 else { return }
        data[data.startIndex + 12] |= 2
        try? data.write(to: url, options: [.atomic])
    }

    private func evictIfNeeded() {
        let victims: [String] = state.withLock { s in
            let visible = Set(s.visible.map { relativePath($0) })
            var total = s.index.values.reduce(0) { $0 + $1.bytes }
            var count = s.index.count
            var out: [String] = []
            for (rel, e) in s.index.sorted(by: { $0.value.used < $1.value.used }) {
                guard count > limits.maxEntries || total > limits.totalBytes else { break }
                if visible.contains(rel) { continue }
                out.append(rel); total -= e.bytes; count -= 1
            }
            for rel in out { s.index[rel] = nil }
            s.memory = s.memory.filter { key, _ in !out.contains(relativePath(key)) }
            s.memoryOrder.removeAll { out.contains(relativePath($0)) }
            return out
        }
        for rel in victims { try? FileManager.default.removeItem(at: fileURL(rel)) }
    }

    // MARK: Index

    private func loadIndexIfNeeded() {
        guard !state.withLock({ $0.indexLoaded }) else { return }
        var loaded: [String: IndexEntry] = [:]
        if let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode([String: IndexEntry].self, from: data) {
            loaded = decoded
        } else if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            // Rebuild from the files on disk (first run after an index loss).
            for case let url as URL in walker where url.pathExtension == "hqt" {
                guard let rel = Self.relativePath(of: url, under: root) else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let t = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                loaded[rel] = IndexEntry(bytes: values?.fileSize ?? 0, used: t, saved: t)
            }
            AppLog.trace("store", "transcript cache: index missing, rebuilt \(loaded.count) entries from disk")
        }
        state.withLock { s in
            for (rel, e) in loaded where s.index[rel] == nil { s.index[rel] = e }
            s.indexLoaded = true
        }
    }

    /// [13-16] A file's path under the cache's folder, with the links resolved on both sides: the walk may name it
    /// /private/var/… while the folder is /var/… (iOS), and a plain text cut then left entries that pointed nowhere,
    /// which eviction could never delete.
    nonisolated static func relativePath(of url: URL, under root: URL) -> String? {
        let base = root.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    private func saveIndexIfNeeded(force: Bool) {
        let snapshot = state.withLock { $0.index }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            AppLog.swallowed("store", "save transcript cache index", error)
        }
    }

    private func excludeRootFromBackup() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Invalidation (spec 03 §7.2)

    /// Failed resume / session not found: drop that scope's entry.
    func remove(account: String, profile: String, storedId: String) {
        let key = Self.key(account: account, profile: profile, storedId: storedId)
        let rel = relativePath(key)
        state.withLock { s in
            s.pending[key] = nil; s.memory[key] = nil; s.memoryOrder.removeAll { $0 == key }; s.index[rel] = nil
        }
        io.async { [self] in try? FileManager.default.removeItem(at: fileURL(rel)); saveIndexIfNeeded(force: true) }
    }

    private static func deletedKey(_ account: String, _ storedId: String) -> String { account + "\n" + storedId }

    /// Session deleted: drop every profile's entry for that stored id (this account), and refuse later saves of it.
    func removeEverywhere(account: String, storedId: String) {
        let accountDir = root.appending(path: Self.accountKey(account), directoryHint: .isDirectory)
        let file = Self.safeComponent(storedId) + ".hqt"
        let matches: @Sendable (String) -> Bool = { rel in rel.hasPrefix(Self.accountKey(account) + "/") && rel.hasSuffix("/" + file) }
        state.withLock { s in
            s.deleted.insert(Self.deletedKey(account, storedId))
            for key in s.memory.keys where key.account == account && key.storedId == storedId { s.memory[key] = nil }
            for key in s.pending.keys where key.account == account && key.storedId == storedId { s.pending[key] = nil }
            s.memoryOrder.removeAll { $0.account == account && $0.storedId == storedId }
            for rel in s.index.keys where matches(rel) { s.index[rel] = nil }
        }
        io.async { [self] in
            // A write already under way when the lock was taken finished before this (one serial queue): its file and
            // its index line go too.
            state.withLock { s in for rel in s.index.keys where matches(rel) { s.index[rel] = nil } }
            let profiles = (try? FileManager.default.contentsOfDirectory(at: accountDir, includingPropertiesForKeys: nil)) ?? []
            for dir in profiles { try? FileManager.default.removeItem(at: dir.appending(path: file)) }
            saveIndexIfNeeded(force: true)
        }
    }

    /// [load-cache] Bot deleted: drop its folder of tails. No tombstone: a new bot may take the name.
    func removeProfile(account: String, profile: String) {
        let p = Self.key(account: account, profile: profile, storedId: "").profile
        let dir = root.appending(path: Self.accountKey(account), directoryHint: .isDirectory)
            .appending(path: Self.safeComponent(p), directoryHint: .isDirectory)
        let prefix = "\(Self.accountKey(account))/\(Self.safeComponent(p))/"
        state.withLock { s in
            s.pending = s.pending.filter { !($0.key.account == account && $0.key.profile == p) }
            s.memory = s.memory.filter { !($0.key.account == account && $0.key.profile == p) }
            s.memoryOrder.removeAll { $0.account == account && $0.profile == p }
            s.index = s.index.filter { !$0.key.hasPrefix(prefix) }
        }
        io.async { [self] in
            state.withLock { s in s.index = s.index.filter { !$0.key.hasPrefix(prefix) } }
            try? FileManager.default.removeItem(at: dir)
            saveIndexIfNeeded(force: true)
        }
    }

    /// Profile renamed: re-key its entries.
    func renameProfile(account: String, from old: String, to new: String) {
        let accountDir = root.appending(path: Self.accountKey(account), directoryHint: .isDirectory)
        let oldDir = accountDir.appending(path: Self.safeComponent(old), directoryHint: .isDirectory)
        let newDir = accountDir.appending(path: Self.safeComponent(new), directoryHint: .isDirectory)
        state.withLock { s in
            for key in Array(s.memory.keys) where key.account == account && key.profile == old {
                let entry = s.memory.removeValue(forKey: key)
                s.memory[Key(account: account, profile: new, storedId: key.storedId)] = entry
            }
            s.memoryOrder = s.memoryOrder.map { $0.account == account && $0.profile == old ? Key(account: account, profile: new, storedId: $0.storedId) : $0 }
            let oldPrefix = "\(Self.accountKey(account))/\(Self.safeComponent(old))/"
            for rel in Array(s.index.keys) where rel.hasPrefix(oldPrefix) {
                let e = s.index.removeValue(forKey: rel)
                s.index["\(Self.accountKey(account))/\(Self.safeComponent(new))/" + rel.dropFirst(oldPrefix.count)] = e
            }
        }
        io.async { [self] in
            if !FileManager.default.fileExists(atPath: newDir.path) { try? FileManager.default.moveItem(at: oldDir, to: newDir) }
            saveIndexIfNeeded(force: true)
        }
    }

    /// Sign-out / gateway removed: delete that account's tails (pending writes are dropped first).
    func purge(account: String) {
        let prefix = Self.accountKey(account) + "/"
        state.withLock { s in
            s.purgeGeneration += 1
            s.purged.insert(account)
            s.pending = s.pending.filter { $0.key.account != account }
            s.memory = s.memory.filter { $0.key.account != account }
            s.memoryOrder.removeAll { $0.account == account }
            s.index = s.index.filter { !$0.key.hasPrefix(prefix) }
        }
        io.sync { [self] in
            try? FileManager.default.removeItem(at: root.appending(path: Self.accountKey(account), directoryHint: .isDirectory))
            saveIndexIfNeeded(force: true)
        }
    }

    /// [13-7] Signed in to the account (again): its chats save their tails once more.
    func reopen(account: String) {
        state.withLock { _ = $0.purged.remove(account) }
    }

    /// Clear everything (connection re-home).
    func purgeAll() {
        state.withLock { s in
            s.purgeGeneration += 1
            s.pending = [:]; s.memory = [:]; s.memoryOrder = []; s.index = [:]
        }
        io.sync { [self] in try? FileManager.default.removeItem(at: root) }
    }

    /// Drop decoded entries (memory pressure). Disk is untouched. Answers how many were dropped.
    @discardableResult
    func trimMemory() -> Int {
        state.withLock { s in
            let before = s.memory.count
            s.memory = s.memory.filter { s.visible.contains($0.key) || s.pending[$0.key] != nil }
            s.memoryOrder.removeAll { s.memory[$0] == nil }
            return before - s.memory.count
        }
    }

    /// [diagnostics] Going to the background: keep the `count` most recently used decoded entries, or as many of them
    /// as fit in `bytes` of decoded size, whichever is smaller. The chat on show and anything waiting to be written
    /// are outside both. A decoded entry is taken as three times its file (parsed objects run two to four times
    /// their JSON). Disk is untouched. Answers how many were dropped.
    @discardableResult
    func trimMemory(keeping count: Int, bytes limit: Int) -> Int {
        state.withLock { s in
            var kept = 0, size = 0, dropped = 0
            for key in s.memoryOrder.reversed() {
                if s.visible.contains(key) || s.pending[key] != nil { continue }
                let estimate = (s.index[relativePath(key)]?.bytes ?? 0) * 3
                if kept < count, size + estimate <= limit {
                    kept += 1
                    size += estimate
                } else if s.memory.removeValue(forKey: key) != nil {
                    dropped += 1
                }
            }
            s.memoryOrder.removeAll { s.memory[$0] == nil }
            return dropped
        }
    }

    /// Decoded entries held in memory now (tests and the DEBUG probe).
    var memoryCount: Int { state.withLock { $0.memory.count } }

    /// Total bytes on disk according to the index (tests / diagnostics).
    var diskBytes: Int { flush(); return state.withLock { $0.index.values.reduce(0) { $0 + $1.bytes } } }
    var entryCount: Int { flush(); return state.withLock { $0.index.count } }
}
