// Disk persistence for the Bots and Sessions stores (spec 02 §11): small JSON files per gateway account, read
// synchronously at launch (instant first draw) and written atomically off the main thread.

import CryptoKit
import Foundation

nonisolated enum RosterDisk {
    /// File kinds. Each is `<kind>-<account key>.json`; no kind may be another kind plus "-…" (the cache pruning
    /// matches `<kind>-<key>.json` exactly, but distinct names keep a mistake there from eating another file).
    static let rosterKind = "roster"
    static let botStateKind = "botstate"
    static let sessionsKind = "sessions"
    static let sessionStateKind = "sessionstate"

    /// The account key's length: 12 bytes of SHA-256 as hex.
    static let accountKeyLength = 24

    /// A file-name-safe key for an account (its id holds the base URL and user name).
    static func accountKey(_ account: GatewayAccount) -> String { accountKey(id: account.id) }

    /// The same key from the account's id alone.
    static func accountKey(id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.prefix(accountKeyLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    static func url(_ directory: URL, _ kind: String, _ account: GatewayAccount) -> URL {
        directory.appendingPathComponent("\(kind)-\(accountKey(account)).json")
    }

    /// Whether a file name is exactly `<kind>-<account key>.json` (so `sessions-` never matches `sessionstate-…` or a
    /// `sessions-state-…` file from an older build).
    static func isFile(_ name: String, ofKind kind: String) -> Bool {
        let prefix = kind + "-", suffix = ".json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let key = name.dropFirst(prefix.count).dropLast(suffix.count)
        return key.count == accountKeyLength && key.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Synchronous read; nil when missing or unreadable (a damaged cache just paints later).
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }       // usually just missing: no earlier cache
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLog.swallowed("store", "decode cached \(url.lastPathComponent)", error)
            return nil
        }
    }

    /// Atomic background write; `keepNewest` then keeps only the newest `count` files of that kind (other accounts'
    /// copies of the same cache).
    static func write<T: Encodable & Sendable>(_ value: T, to url: URL, keepNewest: (kind: String, count: Int)? = nil, urgent: Bool = false) {
        RosterDiskWriter.shared.write(value, to: url, keepNewest: keepNewest, urgent: urgent)
    }
}

/// One serial background queue for every store write; `flush()` waits for pending writes (tests, sign-out).
nonisolated final class RosterDiskWriter: @unchecked Sendable {
    static let shared = RosterDiskWriter()
    private let queue = DispatchQueue(label: "hermeshq.roster-disk", qos: .utility)

    /// `urgent` [groups]: the write (and what is queued before it) runs at the caller's pace instead of utility's, for
    /// something the app must not lose if it is closed a moment later (your send in a room). Still never on the caller.
    func write<T: Encodable & Sendable>(_ value: T, to url: URL, keepNewest: (kind: String, count: Int)?, urgent: Bool = false) {
        queue.async(qos: urgent ? .userInitiated : .unspecified, flags: urgent ? [.enforceQoS] : []) {
            do {
                let data = try JSONEncoder().encode(value)
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                if let keepNewest { Self.prune(directory, kind: keepNewest.kind, keep: keepNewest.count) }
            } catch {
                // Full or unavailable storage: the list just paints later next launch.
                AppLog.swallowed("store", "write cache \(url.lastPathComponent)", error)
            }
        }
    }

    func remove(_ url: URL) {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    func flush() { queue.sync {} }

    /// Keep the `keep` most recently written `<kind>-<account key>.json` files (the web keeps 3 roster caches). Files of
    /// any other kind, device state included, are never touched.
    private static func prune(_ directory: URL, kind: String, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = names.filter { RosterDisk.isFile($0.lastPathComponent, ofKind: kind) }
        guard files.count > keep else { return }
        let dated = files.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: url) }
    }
}
