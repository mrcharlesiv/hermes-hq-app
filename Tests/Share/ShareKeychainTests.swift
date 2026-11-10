// [share] docs/spec/3x-share.md §5.2, §7.4 checks 1, 2, 7, §7.9 check 1: the app's Keychain JSON as the extension
// reads and edits it, pinned to the app's own types.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShareKeychainTests {
    private func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    // MARK: Reading

    @Test func currentAccountOfTheListShape() throws {
        let other: [String: Any] = ["url": "https://b.example", "username": "bee", "cookies": ShareSamples.cookies("b1", "b2")]
        let account = try #require(ShareAccounts.current(in: data(ShareSamples.item(others: [other]))))
        #expect(account.key == ShareSamples.key && account.url == ShareSamples.url && account.username == ShareSamples.username)
        #expect(ShareAccounts.sameCookies(account.cookies, ShareSamples.cookies()))
        #expect(account.nous == nil)
        // `current` names the other one.
        var item = ShareSamples.item(others: [other])
        item["current"] = ShareRules.accountKey(url: "https://b.example", username: "bee")
        #expect(ShareAccounts.current(in: data(item))?.username == "bee")
        // Nobody current, a current that is not saved, the wrong types: nobody.
        item["current"] = nil
        #expect(ShareAccounts.current(in: data(item)) == nil)
        item["current"] = "http://gone\nme"
        #expect(ShareAccounts.current(in: data(item)) == nil)
        #expect(ShareAccounts.current(in: data(["current": ShareSamples.key, "accounts": "nope"])) == nil)
        #expect(ShareAccounts.current(in: Data("[]".utf8)) == nil)
        #expect(ShareAccounts.current(in: Data()) == nil)
    }

    @Test func theAppsOwnJSONIsRead() throws {
        // What `AccountVault` stores is `SavedAccounts`, encoded by JSONEncoder.
        let saved = SavedAccount.sample
        let list = SavedAccounts(current: saved.key, accounts: [saved, StoredAccount(url: "https://b.example", username: "bee")])
        let account = try #require(ShareAccounts.current(in: JSONEncoder().encode(list)))
        #expect(account.key == saved.key)
        #expect(account.cookies.count == 2)
        #expect(account.cookies.compactMap(ShareAccounts.decode).map(\.name).sorted() == ["hermes_session_at", "hermes_session_rt"])
    }

    @Test func build89ItemNeedsTheApp() throws {
        let legacy: [String: Any] = ["url": ShareSamples.url, "username": ShareSamples.username, "password": "never read",
                                     "cookies": ShareSamples.cookies()]
        #expect(ShareAccounts.isLegacyPasswordItem(data(legacy)))
        #expect(ShareAccounts.current(in: data(legacy))?.key == ShareSamples.key)
        #expect(!ShareAccounts.isLegacyPasswordItem(data(ShareSamples.item())))
        #expect(throws: ShareFailure.needsApp) { try ShareSender.account(keychain: MemoryShareKeychain(json: legacy), roster: ShareSamples.roster()) }
        // It is never written.
        #expect(ShareAccounts.replacingCookies(in: data(legacy), account: ShareSamples.key, expected: ShareSamples.cookies(),
                                               renewed: ShareSamples.cookies("a2", "r2")) == nil)
    }

    @Test func nousEntry() throws {
        let user = "nous:user_owner_fixture"
        let item = ShareSamples.item(username: user, cookies: nil, nous: ShareSamples.nous(expiresAt: 2000, obtainedAt: 1000))
        let account = try #require(ShareAccounts.current(in: data(item)))
        #expect(account.cookies.isEmpty)
        #expect(account.nous == ShareNous(accessToken: "nat_1", refreshToken: "nrt_1", expiresAt: 2000, userId: "user_owner_fixture", obtainedAt: 1000))
        // A pair missing a field is no pair.
        for missing in ["accessToken", "refreshToken", "userId"] {
            var entry = ShareSamples.nous(); entry[missing] = nil
            #expect(ShareNous(entry) == nil, "\(missing)")
            entry[missing] = ""
            #expect(ShareNous(entry) == nil, "\(missing) empty")
        }
        #expect(ShareNous(nil) == nil && ShareNous("text") == nil)
        // The app's own encoding of a Nous account.
        let tokens = NousTokens(accessToken: "nat_9", refreshToken: "nrt_9", expiresAt: 5000, userId: "u9", obtainedAt: 4000)
        let stored = StoredAccount(url: ShareSamples.url, username: StoredAccount.nousUsername(userId: "u9"), provider: "nous", nous: tokens)
        let read = try #require(ShareAccounts.current(in: JSONEncoder().encode(SavedAccounts(current: stored.key, accounts: [stored]))))
        #expect(read.nous == ShareNous(accessToken: "nat_9", refreshToken: "nrt_9", expiresAt: 5000, userId: "u9", obtainedAt: 4000))
        // And back: the app decodes what the extension writes.
        let spent = try #require(read.nous)
        let written = try #require(ShareAccounts.replacingNous(in: JSONEncoder().encode(SavedAccounts(current: stored.key, accounts: [stored])),
                                                               account: stored.key, expected: spent,
                                                               renewed: ShareNous(accessToken: "nat_10", refreshToken: "nrt_10", expiresAt: 9000, userId: "u9", obtainedAt: 8000)))
        let decoded = try JSONDecoder().decode(SavedAccounts.self, from: written)
        #expect(decoded.active?.nous == NousTokens(accessToken: "nat_10", refreshToken: "nrt_10", expiresAt: 9000, userId: "u9", obtainedAt: 8000))
        #expect(decoded.active?.provider == "nous")
    }

    // MARK: Opening checks (§7.8, in order)

    @Test func openingChecksInOrder() throws {
        let roster = ShareSamples.roster()
        #expect(throws: ShareFailure.signedOut) { try ShareSender.account(keychain: MemoryShareKeychain(), roster: roster) }
        #expect(throws: ShareFailure.signedOut) { try ShareSender.account(keychain: MemoryShareKeychain(Data("{}".utf8)), roster: roster) }
        #expect(throws: ShareFailure.signedOut) { try ShareSender.account(keychain: MemoryShareKeychain(Data("junk".utf8)), roster: roster) }
        let locked = MemoryShareKeychain(json: ShareSamples.item()); locked.failReads(.locked)
        #expect(throws: ShareFailure.locked) { try ShareSender.account(keychain: locked, roster: roster) }
        let broken = MemoryShareKeychain(json: ShareSamples.item()); broken.failReads(.keychain(-25291))
        #expect(throws: ShareFailure.keychain(-25291)) { try ShareSender.account(keychain: broken, roster: roster) }
        // Saved without a session (the app keeps the address for its sign-in form): signed out.
        #expect(throws: ShareFailure.signedOut) {
            try ShareSender.account(keychain: MemoryShareKeychain(json: ShareSamples.item(cookies: nil)), roster: roster)
        }
        #expect(throws: ShareFailure.signedOut) {
            try ShareSender.account(keychain: MemoryShareKeychain(json: ShareSamples.item(cookies: [])), roster: roster)
        }
        // Signed out wins over a missing roster; a missing roster over another account's.
        #expect(throws: ShareFailure.signedOut) { try ShareSender.account(keychain: MemoryShareKeychain(), roster: nil) }
        #expect(throws: ShareFailure.noRoster) { try ShareSender.account(keychain: MemoryShareKeychain(json: ShareSamples.item()), roster: nil) }
        #expect(throws: ShareFailure.otherAccount) {
            try ShareSender.account(keychain: MemoryShareKeychain(json: ShareSamples.item()), roster: ShareSamples.roster(url: "http://127.0.0.1:9914"))
        }
        #expect(throws: ShareFailure.otherAccount) {
            try ShareSender.account(keychain: MemoryShareKeychain(json: ShareSamples.item()), roster: ShareSamples.roster(username: "someone-else"))
        }
        #expect(try ShareSender.account(keychain: MemoryShareKeychain(json: ShareSamples.item()), roster: roster).key == ShareSamples.key)
        // A Nous account with a pair and no cookies is signed in (the regression of 2026-10-08).
        let nous = ShareSamples.item(username: "nous:u1", cookies: nil, nous: ShareSamples.nous())
        #expect(try ShareSender.account(keychain: MemoryShareKeychain(json: nous), roster: ShareSamples.roster(username: "nous:u1")).nous != nil)
        // The address's case and a trailing slash do not make it another account.
        let shouted = ShareSamples.item(url: "HTTP://127.0.0.1:9911/")
        #expect(try ShareSender.account(keychain: MemoryShareKeychain(json: shouted), roster: roster).key == ShareSamples.key)
    }

    // MARK: Compare-and-swap

    @Test func replacingCookiesWritesOnlyWhenNothingMoved() throws {
        let other: [String: Any] = ["url": "https://b.example", "username": "bee", "cookies": ShareSamples.cookies("b1", "b2"),
                                    "provider": "hermes", "label": "Bee", "invented": ["kept": true]]
        var item = ShareSamples.item(others: [other], extra: ["futureField": 7])
        var accounts = item["accounts"] as! [[String: Any]]
        accounts[0]["surprise"] = "kept too"
        item["accounts"] = accounts
        let before = data(item)
        let old = ShareSamples.cookies(), new = ShareSamples.cookies("a2", "r2")

        let written = try #require(ShareAccounts.replacingCookies(in: before, account: ShareSamples.key, expected: old, renewed: new))
        let after = try #require(ShareAccounts.object(written))
        let list = try #require(after["accounts"] as? [[String: Any]])
        #expect(ShareAccounts.sameCookies(list[0]["cookies"] as! [[String: Any]], new))
        // Everything else survives byte-for-value: the second account, provider, label, unknown keys.
        #expect(after["current"] as? String == ShareSamples.key)
        #expect(after["futureField"] as? Int == 7)
        #expect(list[0]["provider"] as? String == "fake" && list[0]["label"] as? String == "Test" && list[0]["surprise"] as? String == "kept too")
        #expect(NSDictionary(dictionary: list[1]).isEqual(to: other))
        var expected = item
        var changed = accounts; changed[0]["cookies"] = new
        expected["accounts"] = changed
        #expect(NSDictionary(dictionary: after).isEqual(to: expected))

        // Nothing is written when…
        #expect(ShareAccounts.replacingCookies(in: before, account: ShareSamples.key, expected: old, renewed: []) == nil)          // nothing renewed
        #expect(ShareAccounts.replacingCookies(in: before, account: ShareSamples.key, expected: old, renewed: old) == nil)         // the same cookies
        #expect(ShareAccounts.replacingCookies(in: before, account: ShareSamples.key, expected: new, renewed: ShareSamples.cookies("a3", "r3")) == nil)   // the app renewed meanwhile
        #expect(ShareAccounts.replacingCookies(in: before, account: "http://gone\nme", expected: old, renewed: new) == nil)       // not saved any more
        var switched = item; switched["current"] = ShareRules.accountKey(url: "https://b.example", username: "bee")
        #expect(ShareAccounts.replacingCookies(in: data(switched), account: ShareSamples.key, expected: old, renewed: new) == nil) // no longer current
        var signedOut = item; var bare = accounts; bare[0]["cookies"] = nil; signedOut["accounts"] = bare
        #expect(ShareAccounts.replacingCookies(in: data(signedOut), account: ShareSamples.key, expected: old, renewed: new) == nil) // signed out meanwhile
        #expect(ShareAccounts.replacingCookies(in: Data("junk".utf8), account: ShareSamples.key, expected: old, renewed: new) == nil)
    }

    @Test func replacingNousWritesOnlyWhileTheSpentPairIsThere() throws {
        let user = "nous:user_owner_fixture"
        let key = ShareRules.accountKey(url: ShareSamples.url, username: user)
        var entry = ShareSamples.nous(expiresAt: 2000, obtainedAt: 1000)
        entry["laterBuildField"] = "kept"
        let other: [String: Any] = ["url": "https://b.example", "username": "bee", "cookies": ShareSamples.cookies("b1", "b2")]
        let item = ShareSamples.item(username: user, cookies: nil, nous: entry, others: [other], extra: ["futureField": 7])
        let spent = try #require(ShareNous(entry))
        let rotated = ShareNous(accessToken: "nat_2", refreshToken: "nrt_2", expiresAt: 4000, userId: "user_owner_fixture", obtainedAt: 3000)

        let written = try #require(ShareAccounts.replacingNous(in: data(item), account: key, expected: spent, renewed: rotated))
        let after = try #require(ShareAccounts.object(written))
        let list = try #require(after["accounts"] as? [[String: Any]])
        let stored = try #require(list[0]["nous"] as? [String: Any])
        #expect(ShareNous(stored) == rotated)
        #expect(stored["laterBuildField"] as? String == "kept")
        #expect(after["futureField"] as? Int == 7 && after["current"] as? String == key)
        #expect(list[0]["provider"] as? String == "nous" && list[0]["label"] as? String == "Test")
        #expect(NSDictionary(dictionary: list[1]).isEqual(to: other))

        // The app rotated meanwhile (another pair is there): nothing is written.
        #expect(ShareAccounts.replacingNous(in: written, account: key, expected: spent, renewed: rotated) == nil)
        #expect(ShareAccounts.replacingNous(in: data(item), account: "http://gone\nme", expected: spent, renewed: rotated) == nil)
        #expect(ShareAccounts.replacingNous(in: data(ShareSamples.item()), account: ShareSamples.key, expected: spent, renewed: rotated) == nil)
        // `obtainedAt` is bookkeeping: a pair differing only there is the same pair.
        var restamped = spent; restamped.obtainedAt = 77
        #expect(ShareAccounts.replacingNous(in: data(item), account: key, expected: restamped, renewed: rotated) != nil)
        // A rotated pair without an issue time removes the old one's.
        var bare = rotated; bare.obtainedAt = nil
        let cleared = try #require(ShareAccounts.replacingNous(in: data(item), account: key, expected: spent, renewed: bare))
        let entryAfter = try #require(((ShareAccounts.object(cleared)?["accounts"] as? [[String: Any]])?[0])?["nous"] as? [String: Any])
        #expect(entryAfter["obtainedAt"] == nil)
    }

    // MARK: Parity with the app

    @Test func cookieJSONIsTheAppsSavedCookie() throws {
        let expires = Date(timeIntervalSince1970: 1_900_000_000)
        let cookies: [HTTPCookie] = [
            try #require(HTTPCookie(properties: [.name: "hermes_session_at", .value: "abc.def", .domain: "127.0.0.1", .path: "/",
                                                 .expires: expires, HTTPCookiePropertyKey("HttpOnly"): "TRUE", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax])),
            try #require(HTTPCookie(properties: [.name: "hermes_session_rt", .value: "x=y", .domain: "hq.example", .path: "/api/auth",
                                                 .secure: "TRUE", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict])),
            try #require(HTTPCookie(properties: [.name: "plain", .value: "", .domain: "hq.example", .path: "/"])),
        ]
        for cookie in cookies {
            let ours = ShareAccounts.encode(cookie)
            let theirs = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedCookie(cookie))) as? [String: Any])
            #expect(NSDictionary(dictionary: ours).isEqual(to: theirs), "\(cookie.name)")
            // The app decodes what the extension writes…
            let saved = try JSONDecoder().decode(SavedCookie.self, from: JSONSerialization.data(withJSONObject: ours))
            #expect(saved == SavedCookie(cookie))
            // …and both rebuild the same cookie.
            let mine = try #require(ShareAccounts.decode(theirs)), appsOwn = try #require(saved.cookie)
            #expect(mine.name == appsOwn.name && mine.value == appsOwn.value && mine.domain == appsOwn.domain && mine.path == appsOwn.path)
            #expect(mine.isSecure == appsOwn.isSecure && mine.isHTTPOnly == appsOwn.isHTTPOnly)
            #expect(mine.expiresDate == appsOwn.expiresDate && mine.sameSitePolicy == appsOwn.sameSitePolicy)
        }
        #expect(ShareAccounts.decode(["name": "a"]) == nil)
        // "The same session" means the same thing in both.
        let a = ShareSamples.cookies("1", "2"), b = ShareSamples.cookies("1", "3")
        func saved(_ list: [[String: Any]]) throws -> [SavedCookie] { try JSONDecoder().decode([SavedCookie].self, from: JSONSerialization.data(withJSONObject: list)) }
        #expect(ShareAccounts.sameCookies(a, a) == SavedCookie.same(try saved(a), try saved(a)))
        #expect(ShareAccounts.sameCookies(a, b) == SavedCookie.same(try saved(a), try saved(b)))
        #expect(ShareAccounts.sameCookies(a, a.reversed()) && !ShareAccounts.sameCookies(a, b) && !ShareAccounts.sameCookies(a, []))
    }

    @Test func needsRenewalIsTheAppsRule() {
        let table: [(expiresAt: Double, obtainedAt: Double?, now: Double)] = [
            (2000, 1000, 1000), (2000, 1000, 1939), (2000, 1000, 1940), (2000, 1000, 1941), (2000, 1000, 2500),
            (1030, 1000, 1014), (1030, 1000, 1015), (1030, 1000, 1016), (1001, 1000, 1000.4), (1001, 1000, 1000.5),
            (0, 1000, 5000), (900, 1000, 5000), (1000, 1000, 5000),
            (2000, nil, 1939), (2000, nil, 1940), (2000, nil, 1941), (0, nil, 10), (2000, nil, 3000),
            (1_800_003_600, 1_800_000_000, 1_800_003_539), (1_800_003_600, 1_800_000_000, 1_800_003_540),
        ]
        for row in table {
            let mine = ShareNous(accessToken: "a", refreshToken: "r", expiresAt: row.expiresAt, userId: "u", obtainedAt: row.obtainedAt)
            let apps = NousTokens(accessToken: "a", refreshToken: "r", expiresAt: row.expiresAt, userId: "u", obtainedAt: row.obtainedAt)
            #expect(mine.needsRenewal(now: row.now) == apps.needsRenewal(now: row.now), "\(row)")
        }
        let a = ShareNous(accessToken: "a", refreshToken: "r", expiresAt: 1, userId: "u", obtainedAt: 1)
        #expect(a.samePair(ShareNous(accessToken: "a", refreshToken: "r", expiresAt: 9, userId: "u", obtainedAt: nil)))
        #expect(!a.samePair(ShareNous(accessToken: "a", refreshToken: "r2", expiresAt: 1, userId: "u", obtainedAt: 1)))
        #expect(!a.samePair(ShareNous(accessToken: "a", refreshToken: "r", expiresAt: 1, userId: "u2", obtainedAt: 1)))
    }

    @Test func refreshAnswerIsTakenOnlyForTheSameNousAccount() throws {
        func body(_ object: [String: Any]) -> Data { data(object) }
        let good: [String: Any] = ["provider": "nous", "access_token": "nat_2", "refresh_token": "nrt_2", "expires_at": 5000, "user_id": "u1"]
        let pair = try #require(ShareNous.renewed(status: 200, body: body(good), userId: "u1", now: 4000))
        #expect(pair == ShareNous(accessToken: "nat_2", refreshToken: "nrt_2", expiresAt: 5000, userId: "u1", obtainedAt: 4000))
        #expect(ShareNous.renewed(status: 200, body: body(good), userId: "someone-else") == nil)
        #expect(ShareNous.renewed(status: 401, body: body(good), userId: "u1") == nil)
        for (name, value) in [("provider", "hermes" as Any), ("access_token", ""), ("refresh_token", ""), ("user_id", "u2")] {
            var bad = good; bad[name] = value
            #expect(ShareNous.renewed(status: 200, body: body(bad), userId: "u1") == nil, "\(name)")
            bad[name] = nil
            #expect(ShareNous.renewed(status: 200, body: body(bad), userId: "u1") == nil, "\(name) missing")
        }
        #expect(ShareNous.renewed(status: 200, body: Data("<html>".utf8), userId: "u1") == nil)
        // No expiry from the gateway: 0, and then never renewed ahead of time.
        var open = good; open["expires_at"] = nil
        let openPair = try #require(ShareNous.renewed(status: 200, body: body(open), userId: "u1", now: 4000))
        #expect(openPair.expiresAt == 0 && !openPair.needsRenewal(now: 9_000_000))
    }

    // MARK: The source itself

    @Test func theExtensionNeverAddsOrDeletesAKeychainItem() throws {
        // §7.4 check 7: SecItemAdd would create a second sign-in, SecItemDelete would sign the app out.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var read = 0
        for folder in ["ShareKit", "ShareExtension"] {
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }.joined(separator: "\n")
                read += 1
                #expect(!code.contains("SecItemAdd"), "\(file.lastPathComponent)")
                #expect(!code.contains("SecItemDelete"), "\(file.lastPathComponent)")
                #expect(!code.contains("UIApplication.shared"), "\(file.lastPathComponent)")       // not available to an extension
                #expect(!code.contains("openURL") && !code.contains("extensionContext?.open"), "\(file.lastPathComponent)")   // never opens the app
                if folder == "ShareKit" {
                    #expect(!code.contains("import UIKit") && !code.contains("import SwiftUI"), "\(file.lastPathComponent)")
                }
            }
        }
        #expect(read >= 16)
    }
}

private enum SavedAccount {
    static var sample: StoredAccount {
        StoredAccount(url: ShareSamples.url, username: ShareSamples.username,
                      cookies: [SavedCookie(name: "hermes_session_at", value: "a1", domain: "127.0.0.1"),
                                SavedCookie(name: "hermes_session_rt", value: "r1", domain: "127.0.0.1")],
                      provider: "hermes", label: "Fixture")
    }
}
