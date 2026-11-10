// [reliability] B16: one Nous renewal at a time across the app and the Share extension. Each process already renews
// once per pair inside itself; two processes renewing the SAME pair at the same moment both send its refresh token,
// and the second send is a replay, which Portal can answer by ending the session (docs/owner-todo/share.md).
//
// Before it sends a refresh token, a process takes a lease: a small file in the App Group, created with O_EXCL so only
// one process can make it. A process that finds a fresh lease waits for the other's rotated pair to reach the Keychain
// and uses it instead of sending. No file lock is held (a lock held in a shared container while the app is suspended
// gets the app ended by iOS): the lease is a file that says when it was taken, and one older than `ttl` is ignored.
//
// DECISION: `ttl` 20 s (the renewal's own timeout is 15 s); a waiting process waits for the other at most 16 s, then
// takes over. Without an App Group (the native identity, which has no Share extension) there is no one to wait for:
// `acquire` answers a lease that does nothing.

import Foundation
import CryptoKit

nonisolated enum NousRenewalLease {
    static let ttl: TimeInterval = 20
    static let longestWait: TimeInterval = 16
    static let poll: UInt64 = 250_000_000

    /// The App Group folder the lease lives in; nil without an App Group.
    static var directory: URL? { ShareIdentity.folder() }

    nonisolated struct Lease: Sendable {
        let url: URL?
        let token: String

        /// Gives the lease up (only while the file is still this lease, never another process's newer one).
        func release() {
            guard let url, let held = try? String(contentsOf: url, encoding: .utf8), held.hasPrefix(token) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func url(account: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(account.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("nous-renewal-\(digest).lease")
    }

    /// Takes the lease for `account`; nil while another process holds a fresh one.
    static func acquire(account: String, in directory: URL? = directory, now: Date = Date()) -> Lease? {
        let token = UUID().uuidString
        guard let directory else { return Lease(url: nil, token: token) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(account: account, in: directory)
        for _ in 0..<2 {
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if fd >= 0 {
                let line = "\(token) \(now.timeIntervalSince1970)\n"
                _ = line.withCString { write(fd, $0, strlen($0)) }
                close(fd)
                return Lease(url: url, token: token)
            }
            guard errno == EEXIST else { return Lease(url: nil, token: token) }   // can't make the file: don't block a renewal on it
            guard let taken = takenAt(url), now.timeIntervalSince1970 - taken > ttl else { return nil }
            try? FileManager.default.removeItem(at: url)                          // stale: its process went away mid-renewal
        }
        return nil
    }

    /// When the lease at `url` was taken (from its contents; the file's date when they can't be read).
    static func takenAt(_ url: URL) -> TimeInterval? {
        if let text = try? String(contentsOf: url, encoding: .utf8), let at = text.split(separator: " ").last.flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            return at
        }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    /// The lease for `account`, taken now or after waiting for another process's renewal. `adopted` is asked every
    /// `poll` while waiting: true when the Keychain now holds the other process's rotated pair, which ends the wait
    /// with no lease (nothing to send). After `longestWait` the lease is taken anyway (or a do-nothing one is given).
    static func acquireOrWait(account: String, in directory: URL? = directory, longestWait: TimeInterval = longestWait,
                              adopted: () async -> Bool) async -> (lease: Lease?, adopted: Bool) {
        if let lease = acquire(account: account, in: directory) { return (lease, false) }
        let end = Date().addingTimeInterval(longestWait)
        while Date() < end {
            try? await Task.sleep(nanoseconds: poll)
            if await adopted() { return (nil, true) }
            if let lease = acquire(account: account, in: directory) {
                // The other process finished (or gave up) between two looks: its pair may have landed just now.
                if await adopted() { lease.release(); return (nil, true) }
                return (lease, false)
            }
        }
        return (Lease(url: nil, token: UUID().uuidString), false)
    }
}
