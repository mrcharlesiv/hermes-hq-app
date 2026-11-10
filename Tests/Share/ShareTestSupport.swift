// [share] Helpers for the Share extension's unit and fixture tests (docs/spec/3x-share.md §11).

import Foundation
import Testing
@testable import HermesHQNative

/// A Keychain item in memory: what `SystemShareKeychain` is to the extension, with counters and hooks for the
/// compare-and-swap tests.
nonisolated final class MemoryShareKeychain: ShareKeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var readFailure: ShareFailure?
    private var updateFailures = 0
    private var beforeUpdate: (@Sendable (MemoryShareKeychain) -> Void)?
    private(set) var reads = 0
    private(set) var updates = 0

    init(_ data: Data? = nil) { self.data = data }
    convenience init(json: [String: Any]) { self.init(try? JSONSerialization.data(withJSONObject: json)) }

    var value: Data? { lock.withLock { data } }
    var object: [String: Any] { value.flatMap(ShareAccounts.object) ?? [:] }
    var counts: (reads: Int, updates: Int) { lock.withLock { (reads, updates) } }

    func set(_ data: Data?) { lock.withLock { self.data = data } }
    func set(json: [String: Any]) { set(try? JSONSerialization.data(withJSONObject: json)) }
    func failReads(_ failure: ShareFailure?) { lock.withLock { readFailure = failure } }
    func failUpdates(_ times: Int) { lock.withLock { updateFailures = times } }
    /// Runs once, just before the next `update` compares nothing (the store is dumb): the test changes the item as
    /// the app would between the share's read and its write.
    func onNextUpdate(_ work: @escaping @Sendable (MemoryShareKeychain) -> Void) { lock.withLock { beforeUpdate = work } }

    func read() throws -> Data? {
        try lock.withLock {
            reads += 1
            if let readFailure { throw readFailure }
            return data
        }
    }

    func update(_ data: Data) throws {
        let hook = lock.withLock { () -> (@Sendable (MemoryShareKeychain) -> Void)? in
            let hook = beforeUpdate; beforeUpdate = nil; return hook
        }
        hook?(self)
        try lock.withLock {
            if updateFailures > 0 { updateFailures -= 1; throw ShareFailure.keychain(-25300) }
            guard self.data != nil else { throw ShareFailure.keychain(-25300) }       // SecItemUpdate never adds an item
            updates += 1
            self.data = data
        }
    }
}

nonisolated enum ShareSamples {
    static let url = "http://127.0.0.1:9911"
    static let username = "share-fixture"
    static var key: String { ShareRules.accountKey(url: url, username: username) }

    static func cookie(_ name: String, _ value: String, domain: String = "127.0.0.1") -> [String: Any] {
        ["name": name, "value": value, "domain": domain, "path": "/", "secure": false, "httpOnly": true]
    }

    static func cookies(_ access: String = "a1", _ refresh: String = "r1") -> [[String: Any]] {
        [cookie("hermes_session_at", access), cookie("hermes_session_rt", refresh)]
    }

    /// The app's Keychain JSON: the list shape with one current password account (and whatever else a test adds).
    static func item(url: String = ShareSamples.url, username: String = ShareSamples.username, cookies: [[String: Any]]? = ShareSamples.cookies(),
                     nous: [String: Any]? = nil, others: [[String: Any]] = [], extra: [String: Any] = [:]) -> [String: Any] {
        var account: [String: Any] = ["url": url, "username": username, "provider": nous == nil ? "fake" : "nous", "label": "Test"]
        if let cookies { account["cookies"] = cookies }
        if let nous { account["nous"] = nous }
        var object: [String: Any] = ["current": ShareRules.accountKey(url: url, username: username), "accounts": [account] + others]
        for (name, value) in extra { object[name] = value }
        return object
    }

    static func nous(access: String = "nat_1", refresh: String = "nrt_1", expiresAt: Double = Date().timeIntervalSince1970 + 3600,
                     user: String = "user_owner_fixture", obtainedAt: Double? = Date().timeIntervalSince1970) -> [String: Any] {
        var entry: [String: Any] = ["accessToken": access, "refreshToken": refresh, "expiresAt": expiresAt, "userId": user]
        if let obtainedAt { entry["obtainedAt"] = obtainedAt }
        return entry
    }

    static func bot(_ profile: String = "ivy", name: String = "Ivy", session: String = "20260929_120000_aabbcc02",
                    lastActive: Double? = nil, avatar: String? = nil) -> ShareBot {
        ShareBot(key: ShareRules.key(profile: profile), name: name, profile: profile, session: session, avatar: avatar, lastActive: lastActive)
    }

    static func roster(url: String = ShareSamples.url, username: String = ShareSamples.username, bots: [ShareBot]? = nil,
                       limit: Int = ShareRules.defaultLimitBytes) -> ShareRoster {
        ShareRoster(account: ShareRules.accountKey(url: url, username: username), url: url, username: username, limitBytes: limit,
                    bots: bots ?? [bot("default", name: "Hermes", session: "20260929_120000_aabbcc01"), bot()], savedAt: 1)
    }
}

nonisolated enum ShareTemp {
    /// A new empty folder under the test's temporary directory.
    static func folder(_ label: String = "share") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hq-share-tests-\(label)-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func file(_ name: String, bytes: Int, in folder: URL, fill: UInt8 = 0x41) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: fill, count: bytes))
        return url
    }

    @discardableResult
    static func file(_ name: String, text: String, in folder: URL) -> URL {
        let url = folder.appendingPathComponent(name)
        try? Data(text.utf8).write(to: url)
        return url
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("UITests/Fixtures/attachments", isDirectory: true)
}
