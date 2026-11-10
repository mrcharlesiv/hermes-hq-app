// [sync] What the owner sets follows them from device to device (owner 2026-11-03: "a lot of things are not carrying
// over from the mobile app to the desktop app … when I pin tiles, they're not saving"). Pins, Tiles pages, removed
// artifacts, the Sessions and Bots orders and the settings were kept in files and UserDefaults on each device, so the
// Mac never saw what the iPhone did.
//
// Each synced thing is one document on the gateway: `ui_meta["hermes-hq-sync.<name>"]` on the default bot's profile,
// beside the group chats' mirror (GroupSync), so every gateway has it with no add-on and every device signed in to that
// gateway reads the same one, whatever address it was signed in with. The envelope is
//
//     {"v": 1, "at": <ms, rises with every write>, "by": "<device>", "data": <the document>}
//
// - Pull: every roster that arrives carries `ui_meta`. A document whose `at` is past the one this device last took is
//   adopted, unless this device has a change of its own waiting (then the write below settles it).
// - Push: 600 ms after a change, read the roster, take in what another device wrote since (`.rebase`: the document
//   merges as it knows how), write with compare-and-swap where the gateway has it, and try again on a conflict.
// - A device that never synced a document and has one of its own merges the two (`.firstContact`: pins are joined,
//   not replaced) and writes the result.
// - Offline: the change waits (kept across launches) and goes after the next roster.
// - Each write is capped at 64 KB by the gateway; a document past `maxBytes` stays on the device (and says so in the log).

import CryptoKit
import Foundation

/// How a document coming from the gateway meets this device's copy.
nonisolated enum GatewaySyncMerge: Sendable {
    /// Nothing is waiting here: the gateway's copy replaces this one.
    case replace
    /// This device never synced it and holds its own: keep both where the document can.
    case firstContact
    /// A change made here is about to be written over a newer copy from another device: keep this device's change,
    /// take in the rest where the document can.
    case rebase
}

/// A store whose user choices are kept on the gateway for every device.
@MainActor protocol GatewaySynced: AnyObject {
    /// The `ui_meta` key's tail ("pins" → `hermes-hq-sync.pins`).
    var syncName: String { get }
    /// Its synced part now. Called often: compared with the last one sent or taken, so only a real change writes.
    func syncValue() -> JSONValue
    /// The gateway's copy. `base`: the copy both devices last agreed on (nil before the first sync), for a document
    /// that merges change by change. Must not call the sync's `changed` back (it is ignored while adopting anyway).
    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?)
    /// This store found nothing of its own on disk (a sign-out or Remove Gateway deleted it, or it never saved): what
    /// this device remembers syncing is then about a copy that is gone, so it meets the gateway's as a new device does.
    var syncStartedEmpty: Bool { get }
}

extension GatewaySynced {
    var syncStartedEmpty: Bool { false }
}

@MainActor final class GatewaySync {
    static let keyPrefix = "hermes-hq-sync."
    /// Under the gateway's 64 KB cap per write, with room for the envelope.
    static let maxBytes = 60_000
    static let maxTries = 6

    private let client: any GatewayClient
    private let accountId: String
    private let defaults: UserDefaults
    /// The default bot's row in the newest roster.
    private let defaultRow: () -> RosterProfile?
    private let readOnly: () -> Bool
    private let deviceName: String
    private var documents: [String: GatewaySynced] = [:]
    /// What each document was when last written or adopted (only a value that differs is a change; a rebase's base).
    /// Kept on disk, so a change made before the app quit is still a change after the next launch.
    private var known: [String: JSONValue] = [:] {
        didSet { saveKnown() }
    }
    private let knownURL: URL?
    private var lastRaw: [String: JSONValue?] = [:]
    private var adopting: Set<String> = []
    private var debounce: Task<Void, Never>?
    private var flushing = false
    private var failures = 0
    /// [main-e2e] The gateway answered that it can't take the write: nothing is tried again (not even on going to the
    /// background) until the next change.
    private var cantWrite = false
    /// What each document was when the gateway couldn't take it, or the tries gave up on it: the same value again is no
    /// change (a pill tap on Sessions saves its device state, whose synced part is unchanged; each tap read and wrote).
    private var heldBack: [String: JSONValue] = [:]
    private var closed = false
    /// Test hooks.
    var debounceNanoseconds: UInt64 = 600_000_000
    var backoffUnit: Double = 1
    var readTimeout: Duration = .seconds(20)
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    private(set) var writes = 0

    init(client: any GatewayClient, accountId: String, deviceName: String, defaults: UserDefaults = .standard,
         knownDirectory: URL? = GatewaySync.defaultDirectory,
         defaultRow: @escaping () -> RosterProfile?, readOnly: @escaping () -> Bool = { false }) {
        self.client = client
        self.accountId = accountId
        self.deviceName = deviceName
        self.defaults = defaults
        self.defaultRow = defaultRow
        self.readOnly = readOnly
        knownURL = knownDirectory.map { dir in
            Self.knownURL(accountId: accountId, directory: dir)
        }
        if let knownURL, let data = try? Data(contentsOf: knownURL), let saved = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            known = saved
        }
    }

    nonisolated private static func knownURL(accountId: String, directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return directory.appending(path: "sync-\(hash).json")
    }

    /// [13-1] Sign Out / Remove Gateway deleted these documents' local copies (the Sessions and Bots orders, colours,
    /// favourites): this device forgets it ever synced them for the account. Kept, the next sign-in's empty store looked
    /// like a change made here (its value differed from the one last known, the gateway's copy was no newer than the one
    /// last taken) and was written over every device's. Forgotten, it meets the gateway's copy as a new device does
    /// (`.firstContact`), and an empty store takes it.
    static func forget(accountId: String, documents names: [String], defaults: UserDefaults = .standard,
                       knownDirectory: URL? = GatewaySync.defaultDirectory) {
        for name in names { defaults.removeObject(forKey: stateKey(name, accountId: accountId)) }
        guard let knownDirectory else { return }
        let url = knownURL(accountId: accountId, directory: knownDirectory)
        guard let data = try? Data(contentsOf: url),
              var saved = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return }
        for name in names { saved[name] = nil }
        if saved.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveKnown() {
        guard let knownURL, let data = try? JSONEncoder().encode(known) else { return }
        try? FileManager.default.createDirectory(at: knownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: knownURL, options: .atomic)
    }

    func shutdown() {
        closed = true
        debounce?.cancel()
        debounce = nil
    }

    // MARK: Documents

    /// Adds a document. Its value now is what it is "known" as; a change made before (offline, then the app quit) is
    /// remembered as waiting and goes out after the next roster.
    func register(_ document: GatewaySynced) {
        let name = document.syncName
        documents[name] = document
        if document.syncStartedEmpty, known[name] != nil || defaults.object(forKey: stateKey(name)) != nil {
            // [13-1] Its local copy is gone (signed out and back in on a build that kept this bookkeeping): what this
            // device knew is about that copy. It starts as a new device does, so the gateway's copy comes in instead of
            // the empty one going out.
            known[name] = nil
            defaults.removeObject(forKey: stateKey(name))
            AppLog.note("sync", "\(name): nothing kept on this device; taking the gateway's copy")
        }
        let value = document.syncValue()
        if known[name] == nil {
            known[name] = value
        } else if known[name] != value, !state(name).pending {
            // Changed while no sync was listening (before this build, or a write cut off): it still goes.
            var state = state(name)
            state.pending = true
            save(state, name)
        }
        if defaultRow() != nil { pulled() }
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "sync", directoryHint: .isDirectory)
    }

    /// The document says it may have changed. Nothing is written unless its value differs from the last one known.
    func changed(_ name: String) {
        guard !closed, !adopting.contains(name), let document = documents[name] else { return }
        let value = document.syncValue()
        guard value != known[name], value != heldBack[name] else { return }
        var state = state(name)
        state.pending = true
        save(state, name)
        failures = 0
        cantWrite = false
        arm(after: debounceNanoseconds)
    }

    var hasPending: Bool { documents.keys.contains { state($0).pending } }

    // MARK: Pull

    /// A fresh roster is in: adopt what another device wrote, then send what waits here.
    func pulled() {
        guard !closed, let row = defaultRow() else { return }
        for (name, document) in documents {
            let raw = row.uiMeta[Self.keyPrefix + name]
            if let seen = lastRaw[name], seen == raw { continue }
            lastRaw[name] = raw
            var state = state(name)
            guard let envelope = Envelope(raw) else {
                // None on the gateway yet (or it was cleared): this device's copy goes up.
                if !state.pending { state.pending = true; save(state, name) }
                continue
            }
            guard envelope.at > state.base else { continue }
            if state.pending { continue }                        // the write settles it (rebase)
            adopt(document, envelope, merge: state.base == 0 ? .firstContact : .replace)
            state.base = envelope.at
            // A first contact that kept something of this device's owes a write.
            state.pending = document.syncValue() != envelope.data
            save(state, name)
        }
        guard hasPending, debounce == nil, !flushing, !cantWrite, failures < Self.maxTries else { return }
        arm(after: debounceNanoseconds)
    }

    private func adopt(_ document: GatewaySynced, _ envelope: Envelope, merge: GatewaySyncMerge) {
        let name = document.syncName
        adopting.insert(name)
        let base = state(name).base == 0 ? nil : known[name]
        document.adoptSynced(envelope.data, merge: merge, base: base)
        adopting.remove(name)
        // The gateway's copy is what the two agree on now (a rebase's own change is still to be written).
        known[name] = merge == .replace ? document.syncValue() : envelope.data
        AppLog.trace("sync", "\(name): took the copy from \(envelope.by.isEmpty ? "another device" : envelope.by) (\(merge))")
    }

    // MARK: Push

    private func arm(after nanoseconds: UInt64) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.debounce = nil
            await self.flush()
        }
    }

    /// Sends what waits now (tests; the app going to the background).
    func flushNow() async {
        debounce?.cancel()
        debounce = nil
        await flush()
    }

    private func flush() async {
        guard !closed, !flushing, hasPending, !cantWrite, !readOnly() else { return }
        flushing = true
        var offline = false
        var ok = true
        do {
            ok = try await publish()
        } catch let error as RPCError where error.isNotConnected || error.isConnectionLost {
            offline = true
        } catch is CantKeep {
            // A gateway that answers the write without taking `ui_meta` (it doesn't keep it): as one that refuses it.
            flushing = false
            cantWrite = true
            holdBack()
            AppLog.note("sync", "the gateway answered without keeping the synced documents; the next change tries again")
            return
        } catch let error as RPCError where error.code == -32601 || error.code == 4000 {
            // [main-e2e] A gateway that can't take the write (an older Hermes without `profiles.configure`, or without
            // `ui_meta` on it): every try read the roster again, six over ~30 s on each launch. The next change tries again.
            flushing = false
            cantWrite = true
            holdBack()
            AppLog.note("sync", "the gateway can't keep synced documents (\(error)); the next change tries again")
            return
        } catch {
            ok = false
        }
        flushing = false
        guard !closed else { return }
        if ok {
            failures = 0
            if hasPending { arm(after: debounceNanoseconds) }   // changed while the write was out
        } else if !offline {
            failures += 1
            guard failures < Self.maxTries else {
                holdBack()
                AppLog.note("sync", "gave up after \(failures) tries; the next change tries again")
                return
            }
            let wait = min(30, backoffUnit * pow(2, Double(failures - 1)))
            arm(after: UInt64(wait * 1_000_000_000))
        }
    }

    /// The waiting documents as they are now: not tried again until one changes.
    private func holdBack() {
        for (name, document) in documents where state(name).pending { heldBack[name] = document.syncValue() }
    }

    private struct CantKeep: Error {}

    /// Read, merge, write the waiting documents in one compare-and-swap write (as many as fit). false = a conflict or a refusal.
    private func publish() async throws -> Bool {
        let names = documents.keys.filter { state($0).pending }.sorted()
        guard !names.isEmpty else { return true }
        let read = try await client.call("profiles.list", ["include_sessions": false], timeout: readTimeout)
        guard !closed, let row = (read["profiles"]?.array ?? []).first(where: { $0["name"]?.string == "default" })
                ?? (read["profiles"]?.array ?? []).first(where: { $0["is_default"]?.bool == true }) else { return false }
        let profileName = row["name"]?.string ?? "default"
        let supportsSwap = row["ui_meta_revisions"]?.object != nil
        var meta: [String: JSONValue] = [:]
        var expected: [String: JSONValue] = [:]
        var written: [String: (at: Double, value: JSONValue)] = [:]
        var total = 0
        for name in names {
            guard let document = documents[name] else { continue }
            let key = Self.keyPrefix + name
            var state = state(name)
            let remote = Envelope(row["ui_meta"]?[key])
            if let remote, remote.at > state.base {
                // Another device wrote since this one last took it: its copy comes in under this device's change.
                adopt(document, remote, merge: state.base == 0 ? .firstContact : .rebase)
                state.base = remote.at
                save(state, name)
            }
            let value = document.syncValue()
            if let remote, remote.data == value {                // already there
                state.pending = false
                state.base = remote.at
                save(state, name)
                known[name] = value
                continue
            }
            let at = max(now(), (remote?.at ?? 0) + 1, state.base + 1)
            let envelope = Envelope(at: at, by: deviceName, data: value)
            let json = envelope.json
            let size = (try? json.encoded().count) ?? 0
            guard size <= Self.maxBytes else {
                AppLog.note("sync", "\(name): \(size) bytes is past the gateway's limit; kept on this device")
                state.pending = false
                save(state, name)
                known[name] = value
                continue
            }
            // The gateway's cap is on the whole write: what doesn't fit goes in the next one.
            guard total + size <= Self.maxBytes else { continue }
            total += size
            meta[key] = json
            expected[key] = .number(Double(row["ui_meta_revisions"]?[key]?.int ?? 0))
            written[name] = (at, value)
        }
        guard !meta.isEmpty else { return true }
        var params: [String: JSONValue] = ["name": .string(profileName), "ui_meta": .object(meta)]
        if supportsSwap { params["ui_meta_expected_revisions"] = .object(expected) }
        let answer = try await client.call("profiles.configure", .object(params), timeout: readTimeout)
        writes += 1
        guard !closed else { return true }
        // Hermes says whether it took `ui_meta`; an answer that doesn't say never keeps it.
        guard let applied = answer["applied"]?["ui_meta"]?.bool else { throw CantKeep() }
        guard applied else {
            AppLog.trace("sync", "write refused (\(answer["applied"]?["ui_meta_conflicts"] == nil ? "not applied" : "conflict")); reading again")
            return false
        }
        for (name, write) in written {
            var state = state(name)
            state.base = write.at
            // A change made while the write was out is still waiting.
            state.pending = documents[name].map { $0.syncValue() != write.value } ?? false
            save(state, name)
            known[name] = write.value
            heldBack[name] = nil
            lastRaw[name] = nil
        }
        AppLog.trace("sync", "wrote \(written.keys.sorted().joined(separator: ", "))")
        return true
    }

    // MARK: Per-document state on this device

    private struct State: Codable { var base: Double = 0; var pending = false }

    private func stateKey(_ name: String) -> String { Self.stateKey(name, accountId: accountId) }

    nonisolated private static func stateKey(_ name: String, accountId: String) -> String { "hq.gatewaySync.\(name)|\(accountId)" }

    private func state(_ name: String) -> State {
        defaults.data(forKey: stateKey(name)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    private func save(_ state: State, _ name: String) {
        defaults.set(try? JSONEncoder().encode(state), forKey: stateKey(name))
    }

    #if DEBUG
    /// Tests: this device forgets it ever synced.
    func forgetState() { for name in documents.keys { defaults.removeObject(forKey: stateKey(name)) } }
    #endif
}

/// The document's wrapper on the gateway.
nonisolated struct GatewaySyncEnvelope: Sendable, Equatable {
    var at: Double
    var by: String
    var data: JSONValue

    init(at: Double, by: String, data: JSONValue) {
        self.at = at
        self.by = by
        self.data = data
    }

    init?(_ raw: JSONValue?) {
        guard let raw, raw["v"]?.int == 1, let at = raw["at"]?.double, let data = raw["data"], !data.isNull else { return nil }
        self.at = at
        by = raw["by"]?.string ?? ""
        self.data = data
    }

    var json: JSONValue { ["v": 1, "at": .number(at), "by": .string(by), "data": data] }
}

private typealias Envelope = GatewaySyncEnvelope
