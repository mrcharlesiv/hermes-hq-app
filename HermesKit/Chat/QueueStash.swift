// Messages queued behind a running reply, kept per chat beyond its screen (verify round 3). A chat left while its queue
// still waits keeps draining it off screen (`LiveChatSession.drainingAway`, the web's background queue drain), and what
// is left (a parked queue, or everything when the app is killed) comes back when the chat opens next, as the web keeps
// `hermes.desktop.composerQueue.v1`. One live chat owns a scope's queue at a time; its changes are written through.
// On disk: one small JSON file per account, `{"v":1,"chats":{scope:{profile,items}}}`, written 0.3 s after the last
// change, off the main thread. Queued voice memos are written too (their recordings stay in memos/<key>/, kept from the
// daily sweep while a queue holds them, and found again after the container moves); the park is never written. [m9/composer] A queue read back from disk in a fresh process starts PAUSED, with Resume on its card
// (docs/spec/3x-composer.md §16.2 DECISION): nothing is sent after a relaunch that the person did not just ask for.

import Foundation

@MainActor final class QueueStash {
    static let shared = QueueStash()

    nonisolated struct StoredQueue: Codable, Hashable, Sendable {
        var profile: String
        var items: [QueuedMessage]
    }

    private struct Entry {
        var profile: String
        var items: [QueuedMessage]
        var parked: Bool
        /// The live chat that holds this queue now (its changes are written through); nil = waiting for an open.
        var owner: ObjectIdentifier?
    }

    /// By account id, then chat scope (`account|profile|stored id`).
    private var accounts: [String: [String: Entry]] = [:]
    private let base: URL?
    private let writer = DispatchQueue(label: "hq.queues.write", qos: .utility)
    private var writeGeneration: [String: Int] = [:]

    /// Tests pass their own folder.
    init(base: URL? = nil) {
        self.base = base
    }

    // MARK: Ownership

    /// The queue a chat finds when it opens (and takes over): nil when nothing waits or another live chat owns it.
    func claim(accountId: String, scope: String, owner: AnyObject) -> (items: [QueuedMessage], parked: Bool)? {
        loadIfNeeded(accountId)
        let id = ObjectIdentifier(owner)
        guard var entry = accounts[accountId]?[scope] else {
            accounts[accountId, default: [:]][scope] = Entry(profile: "", items: [], parked: false, owner: id)
            return nil
        }
        if let current = entry.owner, current != id {
            AppLog.trace("send", "queue stash \(AppLog.tag(scope)): \(entry.items.count) waiting, owned by another live chat; not claimed")
            return nil
        }
        entry.owner = id
        accounts[accountId]?[scope] = entry
        if !entry.items.isEmpty { AppLog.trace("send", "queue stash \(AppLog.tag(scope)): claimed \(entry.items.count) waiting messages, parked=\(entry.parked)") }
        return entry.items.isEmpty ? nil : (entry.items, entry.parked)
    }

    /// Whether `owner` holds the scope's queue (its changes are the ones kept).
    func owns(accountId: String, scope: String, owner: AnyObject) -> Bool {
        accounts[accountId]?[scope]?.owner == ObjectIdentifier(owner)
    }

    /// The owner's queue changed: kept (and written) as it is now.
    func update(accountId: String, scope: String, profile: String, owner: AnyObject, items: [QueuedMessage], parked: Bool) {
        loadIfNeeded(accountId)
        let id = ObjectIdentifier(owner)
        if let current = accounts[accountId]?[scope]?.owner, current != id {
            AppLog.trace("send", "queue stash \(AppLog.tag(scope)): update from a chat that doesn't own it ignored (\(items.count) items)")
            return
        }
        accounts[accountId, default: [:]][scope] = Entry(profile: profile, items: items, parked: parked && !items.isEmpty, owner: id)
        save(accountId)
    }

    /// The owner let go (its screen left without anything to drain, its drain ended, or it went away): what it left
    /// waits for the next open.
    func release(accountId: String, scope: String, owner: AnyObject) {
        guard var entry = accounts[accountId]?[scope], entry.owner == ObjectIdentifier(owner) else { return }
        entry.owner = nil
        if !entry.items.isEmpty { AppLog.trace("send", "queue stash \(AppLog.tag(scope)): released with \(entry.items.count) waiting for the next open (parked=\(entry.parked))") }
        if entry.items.isEmpty { accounts[accountId]?[scope] = nil } else { accounts[accountId]?[scope] = entry }
    }

    /// What waits for a chat (tests, diagnostics).
    func items(accountId: String, scope: String) -> [QueuedMessage] {
        loadIfNeeded(accountId)
        return accounts[accountId]?[scope]?.items ?? []
    }

    /// Every message waiting in the account's queues (Sign Out and Remove say how many they delete).
    func count(accountId: String) -> Int {
        loadIfNeeded(accountId)
        return accounts[accountId]?.values.reduce(0) { $0 + $1.items.count } ?? 0
    }

    // MARK: Account lifecycle

    /// Sign-out / gateway removal: the account's queues go, on disk too.
    func purge(accountId: String) {
        AppLog.trace("send", "queue stash purged for an account: \(accounts[accountId]?.values.reduce(0) { $0 + $1.items.count } ?? 0) waiting messages dropped")
        accounts[accountId] = nil
        writeGeneration[accountId, default: 0] += 1
        let file = Self.file(accountId: accountId, base: base)
        writer.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Background: the queues reach the disk now, with their photos' upload states as they are (a relaunch then
    /// re-sends nothing that already went up).
    func flush() {
        for accountId in accounts.keys { save(accountId, delay: 0) }
        writer.sync {}
    }

    // MARK: Disk

    private var loaded: Set<String> = []

    private func loadIfNeeded(_ accountId: String) {
        guard loaded.insert(accountId).inserted else { return }
        let stored = Self.load(accountId: accountId, base: base)
        if !stored.isEmpty { AppLog.trace("send", "queue stash loaded: \(stored.count) chats with \(stored.values.reduce(0) { $0 + $1.items.count }) waiting messages (parked)") }
        for (scope, stored) in stored where accounts[accountId]?[scope] == nil {
            accounts[accountId, default: [:]][scope] = Entry(profile: stored.profile, items: stored.items, parked: true, owner: nil)
        }
    }

    nonisolated private struct FileShape: Codable {
        var v: Int
        var chats: [String: StoredQueue]
    }

    nonisolated static func file(accountId: String, base: URL?) -> URL {
        let support = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appending(path: "queues", directoryHint: .isDirectory)
            .appending(path: AttachmentStaging.accountKey(accountId) + ".json")
    }

    /// Everything kept for an account (read at launch by the attachments center, so the queued photos' phone copies are
    /// known before its sweep, and by the first open of a chat).
    nonisolated static func load(accountId: String, base: URL? = nil) -> [String: StoredQueue] {
        guard let data = try? Data(contentsOf: file(accountId: accountId, base: base)),
              let shape = try? JSONDecoder().decode(FileShape.self, from: data), shape.v == 1 else { return [:] }
        var chats = shape.chats
        for (scope, stored) in chats {
            chats[scope]?.items = Self.memosFound(stored.items)
        }
        return chats.filter { !$0.value.items.isEmpty }
    }

    /// VOICE: a queued memo's recording where this install keeps it (`MemoPaths.rebase`); one whose file is gone is
    /// dropped (nothing could send it).
    nonisolated static func memosFound(_ items: [QueuedMessage]) -> [QueuedMessage] {
        var dropped = 0
        let found = items.compactMap { item -> QueuedMessage? in
            guard var memo = item.memo else { return item }
            memo.path = MemoPaths.rebase(memo.path)
            guard FileManager.default.fileExists(atPath: memo.path) else { dropped += 1; return nil }
            var copy = item
            copy.memo = memo
            return copy
        }
        if dropped > 0 { AppLog.note("send", "queue stash: \(dropped) queued memos dropped, their recordings are gone") }
        return found
    }

    /// VOICE: the recordings of the memos an account's stored queues hold (the memo sweep keeps them).
    nonisolated static func memoPaths(accountId: String, base: URL? = nil) -> Set<String> {
        Set(load(accountId: accountId, base: base).values.flatMap { $0.items.compactMap(\.memo?.path) })
    }

    private func save(_ accountId: String, delay: Double = 0.3) {
        writeGeneration[accountId, default: 0] += 1
        let generation = writeGeneration[accountId] ?? 0
        let center = AttachmentCenter.existing(accountId)
        var chats: [String: StoredQueue] = [:]
        for (scope, entry) in accounts[accountId] ?? [:] {
            // Photos with their upload state as it is now; memos as they are (their recordings stay on the phone).
            let items = entry.items.map { item -> QueuedMessage in
                var copy = item
                copy.attachments = item.attachments.map { center?.items[$0.id] ?? $0 }
                return copy
            }
            if !items.isEmpty { chats[scope] = StoredQueue(profile: entry.profile, items: items) }
        }
        let file = Self.file(accountId: accountId, base: base)
        let write = { [weak self] in
            guard let self else { return }
            guard self.writeGeneration[accountId] == generation else { return }
            let data = chats.isEmpty ? nil : try? JSONEncoder().encode(FileShape(v: 1, chats: chats))
            self.writer.async {
                if let data {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    do { try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } catch {   // [diagnostics]
                        AppLog.swallowed("send", "queue stash file write" , error)
                    }
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        if delay <= 0 { write() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { write() } } }
    }
}
