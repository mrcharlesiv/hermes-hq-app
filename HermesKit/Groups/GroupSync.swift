// [groups] The mirror's pull and publish (docs/spec/3x-groups.md §5.3): a port of `flushGroupChatServerSync`
// (`HB/group-chat.ts:1282-1390`). One publish in flight; compare-and-swap on gateways that have it; a retry ladder.

import Foundation

@MainActor final class GroupSync {
    /// Weak: a publish still in flight when the account leaves must not reach for a store that is gone.
    private weak var store: GroupStore?
    private weak var bots: BotStore?
    private let client: any GatewayClient
    /// The mirror key's revision as last read from the gateway.
    private(set) var remoteRevision = 0
    private var pendingChanged: Set<String> = []
    private var pendingDeleted: Set<String> = []
    private var debounce: Task<Void, Never>?
    private var flushing = false
    /// Room keys scheduled after the publish in flight took its picture of the rooms: that write does not carry
    /// them, so they stay pending when it lands (a reply that arrives mid-publish must still reach the mirror).
    private var lateKeys: Set<String> = []
    private var failures = 0
    /// The mirror's revision when the last ladder gave up: a pull that shows the same one does not start another.
    private var gaveUpRevision: Int?
    private var closed = false
    private var lastPulled: JSONValue?
    private var pulledOnce = false
    /// Test hooks: the debounce and the back-off's unit.
    var debounceNanoseconds: UInt64 = 350_000_000
    var backoffUnit: Double = 1
    var readTimeout: Duration = .seconds(20)
    static let maxTries = 8
    /// Publishes made (tests and the stress checks read it).
    private(set) var publishes = 0

    init(store: GroupStore, bots: BotStore?, client: any GatewayClient) {
        self.store = store
        self.bots = bots
        self.client = client
    }

    func shutdown() {
        closed = true
        debounce?.cancel()
        debounce = nil
    }

    var hasPending: Bool { !pendingChanged.isEmpty || !pendingDeleted.isEmpty }

    /// A fresh roster is in `BotStore`: merge its mirror into the device's rooms, then send what waits.
    func pulled() {
        guard !closed, let store, let bots, let row = bots.profiles.first(where: { $0.name == "default" }) ?? bots.profiles.first(where: \.isDefault) else { return }
        remoteRevision = row.uiMetaRevision(GroupSnapshot.metaKey)
        let raw = row.uiMeta[GroupSnapshot.metaKey]
        let first = !pulledOnce
        pulledOnce = true
        if raw != lastPulled || first {
            lastPulled = raw
            let mirror = GroupSnapshot.parse(raw)
            store.adoptTombstones(mirror.deleted)
            store.adopt(GroupSnapshot.apply(mirror, to: store.rooms, tombstones: store.tombstones, protect: pendingChanged))
            // A Delete Group Chat cut off by the app closing: the tombstone is on the device, the room is still in
            // the mirror. The first pull after a launch owes that write (later ones have it in `pendingDeleted`).
            if first {
                for (key, revision) in store.tombstones where mirror.deleted[key] == nil && !pendingChanged.contains(key) {
                    guard let room = mirror.rooms[key], key.hasPrefix("id:") || revision >= room.revision else { continue }
                    pendingDeleted.insert(key)
                }
            }
        }
        guard hasPending, debounce == nil, !flushing, bots.phase >= .slim else { return }
        // What waits goes out after a pull (it was offline, or a write is owed). A ladder that gave up is not started
        // again by every refresh: only a new change does that, or a mirror that moved since (§5.3).
        if failures >= Self.maxTries {
            guard remoteRevision != gaveUpRevision else { return }
            failures = 0
        }
        gaveUpRevision = nil
        arm(after: debounceNanoseconds)
    }

    /// 350 ms after the last change that touches the mirror.
    func schedule(changed: String? = nil, deleted: String? = nil) {
        if let changed { pendingChanged.insert(changed); pendingDeleted.remove(changed) }
        if let deleted { pendingDeleted.insert(deleted); pendingChanged.remove(deleted) }
        if flushing { if let changed { lateKeys.insert(changed) }; if let deleted { lateKeys.insert(deleted) } }
        guard !closed, hasPending else { return }
        if changed != nil || deleted != nil { failures = 0; gaveUpRevision = nil }   // a new change starts a new ladder
        guard failures < Self.maxTries else { return }
        arm(after: debounceNanoseconds)
    }

    private func arm(after nanoseconds: UInt64) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.debounce = nil
            await self.flush()
        }
    }

    /// Runs the pending publish now (tests; the app goes to the background).
    func flushNow() async {
        debounce?.cancel()
        debounce = nil
        await flush()
    }

    private func flush() async {
        guard !closed, !flushing, hasPending else { return }
        flushing = true
        lateKeys = []
        let changed = pendingChanged, deleted = pendingDeleted
        let started = ContinuousClock.now
        var done = false
        var offline = false
        do {
            done = try await publish(changed: changed, deleted: deleted)
        } catch let error as RPCError where error.isNotConnected || error.isConnectionLost {
            offline = true
        } catch {
            done = false
        }
        flushing = false
        let late = lateKeys
        lateKeys = []
        guard !closed else { return }
        if done {
            AppLog.trace("groups", "mirror publish: \(changed.count) changed, \(deleted.count) deleted, in \(AppLog.ms(since: started)) ms")
            // Only what this write carried is settled: a key scheduled after its picture was taken goes out next.
            pendingChanged.subtract(changed.subtracting(late))
            pendingDeleted.subtract(deleted.subtracting(late))
            failures = 0
            gaveUpRevision = nil
            if hasPending { arm(after: debounceNanoseconds) }
        } else if offline {
            AppLog.trace("groups", "mirror publish: offline, kept for the next pull")
            // Nothing is sent offline: the pending publish goes out after the next successful pull.
        } else {
            failures += 1
            guard failures < Self.maxTries else {              // kept on the device; the next change tries again
                AppLog.note("groups", "mirror publish: gave up after \(failures) tries at revision \(remoteRevision)")
                gaveUpRevision = remoteRevision
                return
            }
            AppLog.trace("groups", "mirror publish: attempt \(failures) failed, retrying")
            let wait = min(30, backoffUnit * pow(2, Double(min(failures - 1, 5))))
            arm(after: UInt64(wait * 1_000_000_000))
        }
    }

    /// Read, merge, write with compare-and-swap, read back. false = conflict or a refused write (try again).
    private func publish(changed: Set<String>, deleted: Set<String>) async throws -> Bool {
        guard let store else { return true }
        let read = try await client.call("profiles.list", ["include_sessions": false], timeout: readTimeout)
        guard !closed, let row = (read["profiles"]?.array ?? []).first(where: { $0["name"]?.string == "default" }) else { return false }
        let supportsSwap = row["ui_meta_revisions"]?.object != nil
        let revision = max(0, row["ui_meta_revisions"]?[GroupSnapshot.metaKey]?.int ?? 0)
        remoteRevision = revision
        let remoteRaw = row["ui_meta"]?[GroupSnapshot.metaKey]
        let remote = GroupSnapshot.parse(remoteRaw)
        store.adoptTombstones(remote.deleted)
        // What another device wrote since the last pull comes in first, so the write below never drops it.
        store.adopt(GroupSnapshot.apply(remote, to: store.rooms, tombstones: store.tombstones, protect: changed))
        // The picture of the rooms is taken here (no suspension until the write is sent): a change scheduled while
        // the read above was in flight is in it; one scheduled from here on is not, and is kept for the next write.
        lateKeys = []
        let local = GroupSnapshot.local(rooms: store.rooms, tombstones: store.tombstones)
        let writeRevision = revision + 1
        let removed = Dictionary(store.rooms.filter { !$0.removed.isEmpty }.map { ($0.key, Set($0.removed)) }) { $1 }
        let merged = GroupSnapshot.merge(remote: remote, local: local, changed: changed, deleted: deleted, removed: removed,
                                         writeRevision: writeRevision)
        let now = Date().timeIntervalSince1970 * 1000
        let made = GroupSnapshot.envelope(merged, now: now)
        // Never an envelope with no rooms, unless this write deletes the last one.
        if made.kept.rooms.isEmpty && deleted.isEmpty && !remote.rooms.isEmpty { return true }
        if made.kept.rooms == remote.rooms && made.kept.deleted == remote.deleted && remote.version >= 3 { return true }
        var params: [String: JSONValue] = ["name": "default", "ui_meta": .object([GroupSnapshot.metaKey: made.json])]
        if supportsSwap { params["ui_meta_expected_revisions"] = .object([GroupSnapshot.metaKey: .number(Double(revision))]) }
        let answer = try await client.call("profiles.configure", .object(params), timeout: readTimeout)
        publishes += 1
        guard !closed else { return true }
        guard answer["applied"]?["ui_meta"]?.bool == true else { return false }
        if supportsSwap, answer["applied"]?["ui_meta_revisions"]?[GroupSnapshot.metaKey]?.int != writeRevision { return false }
        remoteRevision = supportsSwap ? writeRevision : revision
        lastPulled = nil
        store.stamp(revision: writeRevision, for: changed)
        store.adoptTombstones(made.kept.deleted)
        return true
    }
}
