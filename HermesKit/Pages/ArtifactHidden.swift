// Removed artifacts (owner 2026-11-02: "You have a TON of artifacts saved from email footers and other BS. Remove
// them."). Remove on an artifact hides that file, picture or link from Artifacts, Bot Info › Artifacts and Pinned (a
// pinned one is unpinned), in every chat that names it: keyed as a pin is, the bot and the value. Nothing on the bot's
// computer changes.
//
// Kept on this device per account (Application Support/pages/hidden/<account hash>.json), across sign-outs, as pins are.
// [sync] The newest `syncedLimit` also live on the gateway (`GatewaySync`, document "hidden"): removed on the iPhone is
// removed on the Mac. Nothing is ever put back, so the two copies are joined, never replaced.

import CryptoKit
import Foundation

@MainActor
final class ArtifactHidden {
    /// Posted on the main actor after any change; `object` is the store.
    static let didChange = Notification.Name("hq.artifactHidden.didChange")
    /// The most kept; the oldest go first past it.
    static let limit = 5000

    private static var stores: [String: ArtifactHidden] = [:]

    /// The removed artifacts of the account with this id (one store per account, made on first use).
    static func of(accountId: String) -> ArtifactHidden {
        if let store = stores[accountId] { return store }
        let store = ArtifactHidden(fileURL: fileURL(accountId: accountId))
        stores[accountId] = store
        return store
    }

    #if DEBUG
    /// `-HQDebugResetPins YES` (UI tests): nothing removed on any account.
    static func debugReset() {
        try? FileManager.default.removeItem(at: PagesCache.root.appending(path: "hidden", directoryHint: .isDirectory))
        stores = [:]
    }
    #endif

    nonisolated static func fileURL(accountId: String, root: URL = PagesCache.root) -> URL {
        let hash = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return root.appending(path: "hidden", directoryHint: .isDirectory).appending(path: "\(hash).json")
    }

    let fileURL: URL?
    /// `ArtifactPin.key`s, oldest first.
    private var order: [String]
    private(set) var keys: Set<String>

    init(fileURL: URL?) {
        self.fileURL = fileURL
        order = fileURL.flatMap { PagesCache.read([String].self, $0) } ?? []
        keys = Set(order)
    }

    var isEmpty: Bool { keys.isEmpty }

    func isHidden(profile: String?, value: String) -> Bool { keys.contains(ArtifactPin.key(profile: profile, value: value)) }
    func isHidden(_ record: ArtifactRecord) -> Bool { isHidden(profile: record.profile, value: record.value) }
    func isHidden(_ pin: ArtifactPin) -> Bool { keys.contains(pin.id) }

    /// Hides it everywhere; a pin of it goes too.
    func hide(profile: String?, value: String, pins: ArtifactPins? = nil) {
        let key = ArtifactPin.key(profile: profile, value: value)
        pins?.unpin(id: key)
        guard keys.insert(key).inserted else { return }
        order.append(key)
        if order.count > Self.limit {
            for gone in order.prefix(order.count - Self.limit) { keys.remove(gone) }
            order.removeFirst(order.count - Self.limit)
        }
        saved()
    }

    private func saved() {
        if let fileURL { PagesCache.write(order, to: fileURL) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        syncChanged?()
    }

    /// [sync] Told after every change.
    var syncChanged: (() -> Void)?

    func hide(_ record: ArtifactRecord, pins: ArtifactPins? = nil) { hide(profile: record.profile, value: record.value, pins: pins) }

    func visible(_ records: [ArtifactRecord]) -> [ArtifactRecord] { keys.isEmpty ? records : records.filter { !isHidden($0) } }
    func visible(_ pins: [ArtifactPin]) -> [ArtifactPin] { keys.isEmpty ? pins : pins.filter { !isHidden($0) } }
}

// [sync] What was removed, as every device signed in to the gateway sees it.
extension ArtifactHidden: GatewaySynced {
    /// The newest kept on the gateway (its write is capped at 64 KB).
    static let syncedLimit = 400

    var syncName: String { "hidden" }

    func syncValue() -> JSONValue { .array(order.suffix(Self.syncedLimit).map { .string($0) }) }

    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
        let remote = (value.array ?? []).compactMap(\.string).filter { !keys.contains($0) }
        guard !remote.isEmpty else { return }
        order = remote + order
        keys.formUnion(remote)
        if order.count > Self.limit {
            for gone in order.prefix(order.count - Self.limit) { keys.remove(gone) }
            order.removeFirst(order.count - Self.limit)
        }
        saved()
    }
}
