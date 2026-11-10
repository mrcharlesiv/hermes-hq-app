// [share] The real ShareSender, its real URLSession and its real socket, against this stream's stand-in gateway
// (docs/spec/3x-share.md §11.2): §7.3 checks 1, 2, 4, 5, 6; §7.4 checks 3-5; §7.7 check 2; §7.8 checks 3-4;
// §7.9 checks 2-5.
//
// Enabled only when `build/fixtures/share-it.json` (or the file `TEST_RUNNER_HQN_SHARE_IT` names) exists, names
// 127.0.0.1 on a port in 9910-9919 and that port answers: so it can only be scripts/fixtures/share-gateway.py started
// by this stream. Otherwise every test here is skipped. One password sign-in per test at most.
//
//   python3 scripts/fixtures/share-gateway.py --port 9911 --redirect-port 9913 --credentials build/fixtures/share-it.json \
//       --files build/fixtures/share-it-files --log build/fixtures/share-it.jsonl

import Foundation
import Testing
@testable import HermesHQNative

nonisolated enum ShareFixture {
    static var file: String { ProcessInfo.processInfo.environment["HQN_SHARE_IT"] ?? "share-it.json" }
    static var credentials: Fixtures.Credentials? { Fixtures.credentials(file) }

    /// The fixture's port, and only when its address is this Mac's loopback in this stream's range.
    static var port: UInt16? {
        guard let url = credentials.flatMap({ URL(string: $0.url) }), url.scheme == "http", url.host() == "127.0.0.1",
              let port = url.port, (9910...9919).contains(port) else { return nil }
        return UInt16(port)
    }

    /// Probed once: the suite's condition is asked again for every test, in parallel with the tests themselves.
    static let available: Bool = port.map(Fixtures.portOpen) ?? false

    @discardableResult
    static func post(_ path: String, _ json: [String: Any]? = nil) async throws -> JSONValue {
        guard let port else { throw TimedOut(what: "the share fixture") }
        return try await Fixtures.control(port, "/__fixture/" + path, json: json)
    }

    static func state() async throws -> ShareFixtureState {
        guard let port else { throw TimedOut(what: "the share fixture") }
        return ShareFixtureState(try await Fixtures.control(port, "/__fixture/state", method: "GET"))
    }

    static func nousCounts() async throws -> [String: Int] {
        guard let port else { throw TimedOut(what: "the share fixture") }
        return (try await Fixtures.control(port, "/__fixture/nous", method: "GET")["counts"]?.object ?? [:]).compactMapValues(\.int)
    }

    /// A bearer pair from the fixture (no Portal, no password).
    static func nousPair(ttl: Int) async throws -> [String: Any] {
        let issued = try await post("nous/issue", ["ttl": ttl])
        guard let access = issued["access_token"]?.string, let refresh = issued["refresh_token"]?.string,
              let expires = issued["expires_at"]?.double, let user = issued["user_id"]?.string else { throw TimedOut(what: "a Nous pair") }
        return ShareSamples.nous(access: access, refresh: refresh, expiresAt: expires, user: user)
    }
}

/// What the fixture recorded (`GET /__fixture/state`).
nonisolated struct ShareFixtureState: Sendable {
    let raw: JSONValue
    init(_ raw: JSONValue) { self.raw = raw }

    var ledger: [JSONValue] { raw["shareLedger"]?.array ?? [] }
    /// "GET /api/auth/me", "UPGRADE /api/ws", "session.resume", in the order the gateway took them.
    var labels: [String] {
        ledger.compactMap { entry in
            switch entry["kind"]?.string {
            case "http": return (entry["method"]?.string ?? "") + " " + (entry["path"]?.string ?? "")
            case "upgrade": return "UPGRADE " + (entry["path"]?.string ?? "")
            case "rpc": return entry["rpc"]?.string
            case "reply": return "REPLY"
            default: return nil
            }
        }
    }
    func entries(_ label: String) -> [JSONValue] { zip(labels, ledger).filter { $0.0 == label }.map(\.1) }
    func entry(_ label: String) -> JSONValue? { entries(label).first }
    func keys(_ label: String) -> [String]? { entry(label)?["keys"]?.array?.compactMap(\.string) }
    var prompts: [JSONValue] { raw["prompts"]?.array ?? [] }
    var texts: [String] { prompts.compactMap { $0["text"]?.string } }
    var uploads: [JSONValue] { raw["uploads"]?.array ?? [] }
    var deletes: [JSONValue] { raw["deletes"]?.array ?? [] }
    var held: [String] { raw["held"]?.array?.compactMap(\.string) ?? [] }
    var redirected: Int { raw["redirected"]?.array?.count ?? 0 }
    var serverRequests: Int { raw["serverRequests"]?.int ?? -1 }
    var serverRequestReplies: Int { raw["serverRequestReplies"]?.int ?? -1 }
    /// RPC or HTTP entries the gateway refused as malformed (4000).
    var invalid: [JSONValue] { ledger.filter { $0["error"]?.int == 4000 } }
}

/// One signed-in account: the Keychain item the app saved, in memory, and the roster the app would have written.
nonisolated struct ShareFixtureAccount: Sendable {
    let keychain: MemoryShareKeychain
    let roster: ShareRoster
    var ivy: ShareBot { roster.bots[1] }

    func sender(_ store: (any ShareKeychainStore)? = nil, progress: @escaping @Sendable (ShareStep) -> Void = { _ in }) -> ShareSender {
        // The gateway is loopback: no interface is asked for (and none is offered).
        ShareSender(keychain: store ?? keychain, interfaces: { [] }, progress: progress)
    }

    func text(_ message: String, shared: [String] = [], files: [ShareAttachment] = []) -> ShareRequest {
        ShareRequest(bot: ivy, message: message, shared: shared, attachments: files)
    }

    /// The item with every cookie's value changed (what another renewal, or a stale copy, looks like).
    func item(cookieValues change: (String) -> String) -> [String: Any] {
        var object = keychain.object
        guard var accounts = object["accounts"] as? [[String: Any]] else { return object }
        for index in accounts.indices {
            guard let cookies = accounts[index]["cookies"] as? [[String: Any]] else { continue }
            accounts[index]["cookies"] = cookies.map { cookie in
                var cookie = cookie
                cookie["value"] = change(cookie["value"] as? String ?? "")
                return cookie
            }
        }
        object["accounts"] = accounts
        return object
    }
}

@Suite(.serialized, .enabled(if: ShareFixture.available)) struct ShareFixtureTests {
    private let vault = Fixtures.testVault("share")
    private static let ivyStored = "20260929_120000_aabbcc02", ivyRuntime = "bf611b3e"

    private func roster(url: String, username: String) -> ShareRoster {
        ShareSamples.roster(url: url, username: username)
    }

    /// One password sign-in through the app's own sign-in code; the fixture's records start empty after it.
    private func signedIn() async throws -> ShareFixtureAccount {
        let credentials = try #require(ShareFixture.credentials)
        vault.removeAll()
        defer { vault.removeAll() }
        // The app's own password sign-in and its own save, without the live connection `SignInService` would open
        // beside the share (its socket would land in the ledger whenever the machine is slow).
        let base = try GatewayAddress.validated(GatewayAddress.normalizeTyped(credentials.url))
        let transport = HTTPTransport()
        defer { transport.invalidate() }
        let signed = try await SignInFlows.passwordSignIn(base: base, username: credentials.username, password: credentials.password, transport: transport)
        try await AccountStore(vault: vault).saveOffMain(StoredAccount(url: base.absoluteString, username: credentials.username,
                                                                      cookies: signed.cookies, provider: signed.provider))
        let stored = try #require(vault.peek())
        #expect(stored.cookies?.isEmpty == false)
        // What the app's Keychain item holds: the same JSON, kept in memory for the share.
        let item = try JSONEncoder().encode(SavedAccounts(current: stored.key, accounts: [stored]))
        try await ShareFixture.post("share-reset")
        let roster = roster(url: stored.url, username: stored.username)
        #expect(roster.account == stored.key)
        return ShareFixtureAccount(keychain: MemoryShareKeychain(item), roster: roster)
    }

    /// A Sign in with Nous account: a bearer pair and no cookies.
    private func nousAccount(_ pair: [String: Any]) throws -> ShareFixtureAccount {
        let credentials = try #require(ShareFixture.credentials)
        let item = ShareSamples.item(url: credentials.url, username: "nous-fixture", cookies: nil, nous: pair)
        return ShareFixtureAccount(keychain: MemoryShareKeychain(json: item), roster: roster(url: credentials.url, username: "nous-fixture"))
    }

    private func failure(_ work: () async throws -> ShareResult) async -> ShareFailure? {
        do { _ = try await work(); return nil } catch { return error as? ShareFailure ?? .refused("unexpected: \(error)") }
    }

    private func files(_ names: [String], in folder: URL) -> [ShareAttachment] {
        names.map { name in
            let home = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if name.hasSuffix(".jpg") {
                // As the sheet does: the photo is converted before it is staged (a camera photo, GPS and all, goes in).
                let camera = ShareTestMedia.photo("camera-" + name, in: home), staged = home.appendingPathComponent(name)
                try? ShareMedia.jpeg(at: camera).write(to: staged)
                try? FileManager.default.removeItem(at: camera)
                return ShareAttachment(kind: .image, file: staged, name: name)
            }
            return ShareAttachment(kind: .file, file: ShareTemp.file(name, text: "A note for " + name, in: home), name: name)
        }
    }

    // MARK: §7.3 The extension sends by itself

    @Test func aPhotoAFileAndAMessageArriveInOrderWithExactKeys() async throws {
        let account = try await signedIn()
        let steps = ShareSteps()
        let attachments = files(["photo.jpg", "note.txt"], in: ShareTemp.folder("fixture-order"))
        let result = try await account.sender(progress: { steps.add($0) }).send(account.text("From the fixture test", files: attachments), roster: account.roster)
        #expect(result.session == Self.ivyStored && !result.renewedCookies)
        #expect(steps.all == [.connecting, .uploading(1, 2), .uploading(2, 2), .sending])

        let state = try await ShareFixture.state()
        #expect(state.labels == ["GET /api/auth/me", "GET /api/files", "POST /api/files/upload-stream", "POST /api/files/upload-stream",
                                 "POST /api/auth/ws-ticket", "UPGRADE /api/ws", "client.capabilities", "session.resume",
                                 "image.attach", "file.attach", "DELETE /api/files", "prompt.submit"])
        // §6.3: the key set of every call, exactly.
        #expect(state.keys("GET /api/auth/me") == [])
        #expect(state.keys("GET /api/files") == ["profile"])
        #expect(state.entries("POST /api/files/upload-stream").allSatisfy { $0["keys"]?.array?.compactMap(\.string) == ["profile"] })
        #expect(state.keys("POST /api/auth/ws-ticket") == [])
        #expect(state.keys("UPGRADE /api/ws") == ["ticket"])
        #expect(state.keys("client.capabilities") == ["server_requests"])
        #expect(state.keys("session.resume") == ["omit_messages", "profile", "session_id", "source"])
        #expect(state.keys("image.attach") == ["path", "profile", "session_id"])
        #expect(state.keys("file.attach") == ["name", "path", "profile", "session_id"])
        #expect(state.keys("DELETE /api/files") == ["profile"])
        #expect(state.keys("prompt.submit") == ["profile", "queued", "session_id", "text"])
        #expect(state.invalid.isEmpty)
        #expect(state.ledger.allSatisfy { $0["error"] == nil || $0["error"]?.isNull == true })
        // The stored id opens the chat; everything after names the runtime id it answered with.
        #expect(state.entry("session.resume")?["session"]?.string == Self.ivyStored)
        for call in ["image.attach", "file.attach", "prompt.submit"] {
            #expect(state.entry(call)?["session"]?.string == Self.ivyRuntime, "\(call)")
        }
        // Every request is the signed-in session's, to Ivy's profile, and every status is a success.
        let http = state.ledger.filter { $0["kind"]?.string == "http" }
        #expect(http.count == 6 && http.allSatisfy { $0["auth"]?.string == "cookie" && $0["status"]?.int == 200 })
        #expect(state.ledger.compactMap { $0["profile"]?.string }.allSatisfy { $0 == "ivy" })
        #expect(state.entry("UPGRADE /api/ws")?["status"]?.int == 101)

        // §7.3 check 2: exactly one prompt reached Ivy's chat, queued.
        #expect(state.prompts.count == 1)
        let prompt = try #require(state.prompts.first)
        #expect(prompt["queued"]?.bool == true && prompt["profile"]?.string == "ivy" && prompt["session"]?.string == Self.ivyRuntime)
        #expect(prompt["text"]?.string == "@file:/fixture-home/attachments/note.txt\n\nFrom the fixture test")
        #expect(state.entry("prompt.submit")?["queued"]?.bool == true)

        // What reached the gateway's disk: both uploads under the staging folder, the photo a plain JPEG.
        #expect(state.uploads.count == 2)
        #expect(state.uploads.allSatisfy { ($0["path"]?.string ?? "").hasPrefix("/fixture/uploads/.dispatch-attachments/") && $0["status"]?.int == 200 })
        let photo = try #require(state.uploads.first)
        #expect(photo["jpeg"]?.bool == true && photo["gps"]?.bool == false && photo["camera"]?.bool == false)
        #expect((photo["path"]?.string ?? "").hasSuffix("/photo.jpg"))
        // The file's staged copy went once the gateway kept its own.
        #expect(state.deletes.count == 1)
        #expect(state.deletes.first?["recursive"]?.bool == true && state.deletes.first?["status"]?.int == 200)
        let staged = (state.uploads.last?["path"]?.string ?? "").split(separator: "/").dropLast().joined(separator: "/")
        #expect(state.deletes.first?["path"]?.string == "/" + staged)
    }

    @Test func anApprovalRequestOnTheSharesSocketIsNeverAnswered() async throws {
        let account = try await signedIn()
        try await ShareFixture.post("share-server-request", ["before": "prompt.submit"])
        let result = try await account.sender().send(account.text("Needs an approval"), roster: account.roster)
        #expect(result.session == Self.ivyStored)
        try await Task.sleep(for: .milliseconds(800))
        let state = try await ShareFixture.state()
        #expect(state.serverRequests == 1)                // the gateway did ask
        #expect(state.serverRequestReplies == 0)          // and the share said nothing back
        #expect(!state.labels.contains("REPLY"))
        #expect(state.texts == ["Needs an approval"])
    }

    @Test func aRedirectIsNotFollowed() async throws {
        let account = try await signedIn()
        try await ShareFixture.post("share-fail", ["target": "me", "status": 302])
        let failed = await failure { try await account.sender().send(account.text("Never sent"), roster: account.roster) }
        #expect(failed == .gateway(302))
        #expect(failed?.message == "Your gateway had a problem with this share. Try again in a minute.")
        try await Task.sleep(for: .milliseconds(500))
        let state = try await ShareFixture.state()
        #expect(state.labels == ["GET /api/auth/me"])     // one request, and nothing after the redirect
        #expect(state.redirected == 0)                    // the other port was never asked
        #expect(state.prompts.isEmpty)
    }

    @Test func cancelDuringAnUploadSendsNoPrompt() async throws {
        let account = try await signedIn()
        try await ShareFixture.post("share-hold", ["target": "upload", "seconds": 3])
        let attachments = files(["note.txt"], in: ShareTemp.folder("fixture-cancel"))
        let request = account.text("Cancelled", files: attachments), roster = account.roster
        let sender = account.sender()
        let sending = Task { () -> ShareFailure? in
            do { _ = try await sender.send(request, roster: roster); return nil } catch { return error as? ShareFailure }
        }
        // Wait until the gateway is holding the upload, then Cancel.
        var held = false
        for _ in 0..<100 where !held {
            try await Task.sleep(for: .milliseconds(100))
            held = try await ShareFixture.state().held.contains("upload")
        }
        #expect(held)
        let cancelled = Date()
        sending.cancel()
        #expect(await sending.value == .cancelled)
        #expect(Date().timeIntervalSince(cancelled) < 2)          // Cancel never waits on the gateway
        try await Task.sleep(for: .seconds(4))                    // long enough for the held upload to finish over there
        let state = try await ShareFixture.state()
        #expect(state.prompts.isEmpty)
        #expect(!state.labels.contains("POST /api/auth/ws-ticket") && !state.labels.contains("prompt.submit"))
    }

    /// Cancel while the gateway is slow to open the chat: the share ends as the person's Cancel at once (the socket
    /// records it before the connection is torn down, so the system's own "cancelled" never takes its place), and
    /// nothing more is sent, not even a clean-up.
    @Test func cancelWhileTheChatOpensIsThePersonsCancel() async throws {
        let account = try await signedIn()
        try await ShareFixture.post("share-hold", ["target": "session.resume", "seconds": 3])
        let attachments = files(["note.txt"], in: ShareTemp.folder("fixture-cancel-socket"))
        let request = account.text("Cancelled", files: attachments), roster = account.roster
        let sender = account.sender()
        let sending = Task { () -> ShareFailure? in
            do { _ = try await sender.send(request, roster: roster); return nil } catch { return error as? ShareFailure }
        }
        var held = false
        for _ in 0..<100 where !held {
            try await Task.sleep(for: .milliseconds(100))
            held = try await ShareFixture.state().held.contains("session.resume")
        }
        #expect(held)
        let cancelled = Date()
        sending.cancel()
        #expect(await sending.value == .cancelled)
        #expect(Date().timeIntervalSince(cancelled) < 2)
        try await Task.sleep(for: .seconds(4))
        let state = try await ShareFixture.state()
        #expect(state.prompts.isEmpty && !state.labels.contains("prompt.submit"))
        #expect(state.labels.last == "session.resume", "\(state.labels)")       // nothing after Cancel
        #expect(state.deletes.isEmpty)
    }

    // MARK: §7.3 A share that fails before its prompt leaves nothing on the gateway

    @Test func aShareTheChatRefusesRemovesItsUploadsFromTheGateway() async throws {
        let account = try await signedIn()
        let attachments = files(["photo.jpg", "note.txt"], in: ShareTemp.folder("fixture-cleanup"))
        // The chat is busy: both uploads are on the gateway's disk by the time session.resume is refused.
        try await ShareFixture.post("share-fail", ["target": "session.resume", "code": 4009, "message": "session busy"])
        let failed = await failure { try await account.sender().send(account.text("Never arrives", files: attachments), roster: account.roster) }
        #expect(failed == .refused("This bot is busy. Try again in a moment."))
        var state = try await ShareFixture.state()
        #expect(state.labels == ["GET /api/auth/me", "GET /api/files", "POST /api/files/upload-stream", "POST /api/files/upload-stream",
                                 "POST /api/auth/ws-ticket", "UPGRADE /api/ws", "client.capabilities", "session.resume",
                                 "DELETE /api/files", "DELETE /api/files"])
        // One DELETE per uploaded folder, each of them a folder an upload went to, all answered 200.
        let folders = state.uploads.compactMap { $0["path"]?.string }.map { ($0 as NSString).deletingLastPathComponent }
        #expect(folders.count == 2 && Set(folders).count == 2)
        #expect(state.deletes.compactMap { $0["path"]?.string } == folders)
        #expect(state.deletes.allSatisfy { $0["recursive"]?.bool == true && $0["status"]?.int == 200 })
        #expect(state.entries("DELETE /api/files").allSatisfy { $0["keys"]?.array?.compactMap(\.string) == ["profile"] && $0["status"]?.int == 200 })
        // The gateway's own disk: nothing of this share is left in the staging folder.
        #expect(state.raw["staged"]?.array?.isEmpty == true, "\(String(describing: state.raw["staged"]))")
        #expect(state.prompts.isEmpty && state.invalid.isEmpty)

        // Try Again (the fault is spent): it uploads afresh and goes through. The photo's copy stays for the bot's turn,
        // the file's is released as always: exactly one file is left staged, and it is this share's photo.
        let result = try await account.sender().send(account.text("Second go", files: attachments), roster: account.roster)
        #expect(result.session == Self.ivyStored)
        state = try await ShareFixture.state()
        #expect(state.texts == ["@file:/fixture-home/attachments/note.txt\n\nSecond go"])
        let staged = state.raw["staged"]?.array?.compactMap(\.string) ?? []
        #expect(staged.count == 1 && staged.first?.hasSuffix("/photo.jpg") == true, "\(staged)")
        #expect(state.uploads.count == 4 && state.deletes.count == 3)
        try await Task.sleep(for: .milliseconds(600))
    }

    // MARK: §7.4 Renewed cookies written back

    @Test func aRenewedSessionIsWrittenBackForTheApp() async throws {
        let account = try await signedIn()
        let before = ShareAccounts.current(in: try #require(account.keychain.value))
        try await ShareFixture.post("expire-access")
        let result = try await account.sender().send(account.text("After the access cookie lapsed"), roster: account.roster)
        #expect(result.renewedCookies)
        #expect(account.keychain.counts.updates == 1)
        let item = try #require(account.keychain.value)
        let after = try #require(ShareAccounts.current(in: item))
        #expect(!ShareAccounts.sameCookies(after.cookies, before?.cookies ?? []))
        #expect(after.key == before?.key && after.cookies.count >= 2)
        // The app reads what the share wrote: same account, provider and label, the renewed cookies.
        let decoded = try JSONDecoder().decode(SavedAccounts.self, from: item)
        #expect(decoded.active?.key == before?.key && decoded.active?.provider == "fake")
        #expect(decoded.active?.cookies?.count == after.cookies.count)
        // And the renewed pair is a live session: a second share needs no sign-in and renews nothing.
        let again = try await account.sender().send(account.text("With the renewed session"), roster: account.roster)
        #expect(!again.renewedCookies && account.keychain.counts.updates == 1)
        let state = try await ShareFixture.state()
        #expect(state.texts == ["After the access cookie lapsed", "With the renewed session"])
        #expect(state.entries("GET /api/auth/me").allSatisfy { $0["status"]?.int == 200 })
    }

    @Test func aKeychainTheAppChangedMeanwhileIsNeverOverwritten() async throws {
        let account = try await signedIn()
        // The app renewed the session after the share read the item: its cookies are the newer ones.
        let fromTheApp = account.item { $0 + "-renewed-by-the-app" }
        let keychain = SwappingKeychain(account.keychain, after: 1, with: fromTheApp)
        try await ShareFixture.post("expire-access")
        let result = try await account.sender(keychain).send(account.text("While the app renewed"), roster: account.roster)
        #expect(!result.renewedCookies)
        #expect(account.keychain.counts.updates == 0)
        let kept = try #require(account.keychain.value), wanted = try JSONSerialization.data(withJSONObject: fromTheApp)
        #expect(ShareAccounts.sameCookies(ShareAccounts.current(in: kept)?.cookies ?? [], ShareAccounts.current(in: wanted)?.cookies ?? []))
        #expect(ShareAccounts.current(in: kept)?.cookies.isEmpty == false)
        #expect(try await ShareFixture.state().texts == ["While the app renewed"])
    }

    @Test func staleCookiesAreRetriedOnceWithTheKeychainsCopy() async throws {
        let account = try await signedIn()
        let fresh = account.keychain.object
        // The share reads an item whose cookies the gateway no longer knows; by its second read the app has saved the
        // live ones.
        let stale = MemoryShareKeychain(json: account.item { _ in "stale" })
        let keychain = SwappingKeychain(stale, after: 1, with: fresh)
        let result = try await account.sender(keychain).send(account.text("After one retry"), roster: account.roster)
        #expect(result.session == Self.ivyStored)
        let state = try await ShareFixture.state()
        #expect(state.entries("GET /api/auth/me").compactMap { $0["status"]?.int } == [401, 200])
        #expect(state.texts == ["After one retry"])
        #expect(state.labels.filter { $0 == "prompt.submit" }.count == 1)
    }

    // MARK: §7.7 What the prompt says

    @Test func theSixPromptsReachTheGatewayWordForWord() async throws {
        let account = try await signedIn()
        let folder = ShareTemp.folder("fixture-prompts")
        let rows: [(String, [String], [String], String)] = [
            ("From Safari", ["https://example.com/a"], [], "From Safari\n\nhttps://example.com/a"),
            ("", [], ["one.jpg"], "What do you see in this image?"),
            ("Look", [], ["one.jpg", "two.jpg"], "Look"),
            ("From Files", [], ["note.txt"], "@file:/fixture-home/attachments/note.txt\n\nFrom Files"),
            ("", [], ["a.txt", "b.txt", "one.jpg"], "@file:/fixture-home/attachments/a.txt\n@file:/fixture-home/attachments/b.txt"),
            ("Same", ["Same", "Same"], [], "Same"),
        ]
        for (message, shared, names, prompt) in rows {
            try await ShareFixture.post("share-reset")              // records and the gateway's files; the session stays
            _ = try await account.sender().send(account.text(message, shared: shared, files: files(names, in: folder)), roster: account.roster)
            let state = try await ShareFixture.state()
            #expect(state.texts == [prompt], "\(prompt)")
            #expect(state.invalid.isEmpty && state.prompts.first?["queued"]?.bool == true)
            // Give the fixture's short reply time to finish before the next share's reset.
            try await Task.sleep(for: .milliseconds(600))
        }
    }

    // MARK: §7.8 Failures in plain words

    @Test func gatewayFaultsBecomeTheSheetsSentences() async throws {
        let account = try await signedIn()
        let folder = ShareTemp.folder("fixture-faults")
        let photo = files(["one.jpg"], in: folder), note = files(["note.txt"], in: folder)
        let cases: [([String: Any], [ShareAttachment], ShareFailure, String, Bool)] = [
            (["target": "upload", "status": 429], note, .gateway(429), "Your gateway is busy. Try again in a minute.", true),
            (["target": "files", "status": 500], note, .gateway(500), "Your gateway had a problem with this share. Try again in a minute.", true),
            (["target": "session.resume", "code": 4001, "message": "session not found"], [],
             .refused("Your gateway couldn’t find this bot’s chat. Open it in Hermes HQ, then share again."),
             "Your gateway couldn’t find this bot’s chat. Open it in Hermes HQ, then share again.", false),
            (["target": "session.resume", "code": 4009, "message": "session busy"], [],
             .refused("This bot is busy. Try again in a moment."), "This bot is busy. Try again in a moment.", false),
            (["target": "image.attach", "result": ["attached": false, "message": "That picture is not allowed here."]], photo,
             .refused("That picture is not allowed here."), "That picture is not allowed here.", false),
        ]
        for (fault, attachments, expected, sentence, retryable) in cases {
            try await ShareFixture.post("share-reset")
            try await ShareFixture.post("share-fail", fault)
            let failed = await failure { try await account.sender().send(account.text("Never arrives", files: attachments), roster: account.roster) }
            #expect(failed == expected, "\(fault["target"] ?? "")")
            #expect(failed?.message == sentence && failed?.retryable == retryable && failed?.blocksSheet == false)
            let state = try await ShareFixture.state()
            #expect(state.prompts.isEmpty && !state.labels.contains("prompt.submit"), "\(fault["target"] ?? "")")
        }
        // A share after the faults are spent goes through: nothing was queued for later and nothing was stored.
        try await ShareFixture.post("share-reset")
        _ = try await account.sender().send(account.text("After the faults"), roster: account.roster)
        #expect(try await ShareFixture.state().texts == ["After the faults"])
        try await Task.sleep(for: .milliseconds(600))

        // The gateway ends the session: the one failure that sends the person back to the app.
        try await ShareFixture.post("share-reset")
        try await ShareFixture.post("revoke")
        let ended = await failure { try await account.sender().send(account.text("Never arrives"), roster: account.roster) }
        #expect(ended == .sessionEnded && ended?.blocksSheet == true && ended?.retryable == false)
        #expect(ended?.message == "Your gateway ended this iPhone’s session. Open Hermes HQ to sign in again.")
        let state = try await ShareFixture.state()
        #expect(state.labels == ["GET /api/auth/me"])     // refused once, and the Keychain had nothing newer to try
        #expect(state.prompts.isEmpty)
        #expect(account.keychain.counts.updates == 0)
    }

    @Test func aLostAnswerIsUnconfirmedAndNeverSentAgain() async throws {
        let account = try await signedIn()
        try await ShareFixture.post("share-hold", ["target": "prompt.submit", "drop": true])
        let failed = await failure { try await account.sender().send(account.text("Did it arrive?"), roster: account.roster) }
        #expect(failed == .unconfirmed && failed?.retryable == false && failed?.blocksSheet == false)
        #expect(failed?.message == "Hermes HQ couldn’t confirm the share arrived. Check the chat before sending again.")
        try await Task.sleep(for: .seconds(2))
        let state = try await ShareFixture.state()
        #expect(state.texts == ["Did it arrive?"])        // the gateway has it, once
        #expect(state.labels.filter { $0 == "prompt.submit" }.count == 1)
        #expect(state.labels.filter { $0 == "UPGRADE /api/ws" }.count == 1)       // no second socket, no second try
    }

    // MARK: §7.9 Sign in with Nous

    @Test func aNousAccountSharesWithItsBearerAndNoCookies() async throws {
        try await ShareFixture.post("share-reset")
        let account = try nousAccount(try await ShareFixture.nousPair(ttl: 3600))
        let photo = files(["one.jpg"], in: ShareTemp.folder("fixture-nous"))
        let result = try await account.sender().send(account.text("A photo and a note", files: photo), roster: account.roster)
        #expect(result.session == Self.ivyStored && !result.renewedCookies)
        let state = try await ShareFixture.state()
        #expect(state.texts == ["A photo and a note"])
        let http = state.ledger.filter { $0["kind"]?.string == "http" }
        #expect(http.count == 4 && http.allSatisfy { $0["auth"]?.string == "bearer" && $0["cookie"]?.bool == false && $0["status"]?.int == 200 })
        // The upgrade carries only the ticket.
        #expect(state.entry("UPGRADE /api/ws")?["auth"]?.string == "none" && state.entry("UPGRADE /api/ws")?["cookie"]?.bool == false)
        let counts = try await ShareFixture.nousCounts()
        #expect(counts["refresh"] == 0 && counts["replayed"] == 0 && counts["bearerRejected"] == 0)
        #expect(account.keychain.counts.updates == 0)
    }

    @Test func aLapsedNousPairIsRotatedExactlyOnceAndSaved() async throws {
        try await ShareFixture.post("share-reset")
        let pair = try await ShareFixture.nousPair(ttl: 1)
        let account = try nousAccount(pair)
        try await Task.sleep(for: .seconds(2))
        let started = Date().timeIntervalSince1970
        let result = try await account.sender().send(account.text("After the token lapsed"), roster: account.roster)
        #expect(result.renewedCookies)
        let counts = try await ShareFixture.nousCounts()
        #expect(counts["refresh"] == 1 && counts["replayed"] == 0)
        #expect(account.keychain.counts.updates == 1)
        let item = try #require(account.keychain.value)
        let saved = try #require(ShareAccounts.current(in: item)?.nous)
        #expect(saved.accessToken != pair["accessToken"] as? String && saved.refreshToken != pair["refreshToken"] as? String)
        #expect(saved.accessToken.hasPrefix("nat_") && saved.refreshToken.hasPrefix("nrt_") && saved.userId == "user_owner_fixture")
        #expect((saved.obtainedAt ?? 0) >= started - 1)
        // The app reads the rotated pair.
        let decoded = try JSONDecoder().decode(SavedAccounts.self, from: item)
        #expect(decoded.active?.nous?.refreshToken == saved.refreshToken && decoded.active?.provider == "nous")
        let state = try await ShareFixture.state()
        #expect(state.labels.prefix(2) == ["POST /auth/native/refresh", "GET /api/auth/me"])
        #expect(state.texts == ["After the token lapsed"])
    }

    @Test func aNewerNousPairInTheKeychainIsUsedInsteadOfRenewing() async throws {
        try await ShareFixture.post("share-reset")
        let credentials = try #require(ShareFixture.credentials)
        let spent = try await ShareFixture.nousPair(ttl: 1), newer = try await ShareFixture.nousPair(ttl: 3600)
        let account = try nousAccount(spent)
        // The app rotated the pair after the share read the item.
        let keychain = SwappingKeychain(account.keychain, after: 1,
                                        with: ShareSamples.item(url: credentials.url, username: "nous-fixture", cookies: nil, nous: newer))
        try await Task.sleep(for: .seconds(2))
        let result = try await account.sender(keychain).send(account.text("With the app’s newer token"), roster: account.roster)
        #expect(result.session == Self.ivyStored)
        let counts = try await ShareFixture.nousCounts()
        #expect(counts["refresh"] == 0 && counts["replayed"] == 0 && counts["bearerRejected"] == 0)
        #expect(account.keychain.counts.updates == 0)
        #expect(try await ShareFixture.state().texts == ["With the app’s newer token"])
    }

    @Test func aRevokedNousSessionEndsAfterOneRenewal() async throws {
        try await ShareFixture.post("share-reset")
        let account = try nousAccount(try await ShareFixture.nousPair(ttl: 3600))
        try await ShareFixture.post("nous/revoke")
        let ended = await failure { try await account.sender().send(account.text("Never arrives"), roster: account.roster) }
        #expect(ended == .sessionEnded)
        let counts = try await ShareFixture.nousCounts()
        #expect(counts["refresh"] == 1)                   // one attempt, never a second
        let state = try await ShareFixture.state()
        #expect(state.labels == ["GET /api/auth/me", "POST /auth/native/refresh"])
        #expect(state.prompts.isEmpty && account.keychain.counts.updates == 0)
    }

    // MARK: §12.7 Two processes at once (stress)

    private func authCounts() async throws -> [String: Int] {
        let port = try #require(ShareFixture.port)
        let counts = (try await Fixtures.control(port, "/__fixture/auth", method: "GET").object ?? [:]).compactMapValues(\.int)
        #expect(counts["passwordPosts"] != nil && counts["refreshes"] != nil && counts["rejected"] != nil, "\(counts)")
        return counts
    }

    @Test func twoClientsRenewOneSessionThroughAHundredRounds() async throws {
        // The app and a share (here: two senders, each with its own cookie jar) on one Keychain item, while the access
        // cookie lapses before every round. Every fourth round they go at the same moment.
        let account = try await signedIn()
        let first = try #require(account.keychain.value)
        let key = try #require(ShareAccounts.current(in: first)?.key)
        let before = try await authCounts()
        for round in 0..<100 {
            try await ShareFixture.post("expire-access")
            let shares = [(account.sender(), account.text("A \(round)"), account.roster), (account.sender(), account.text("B \(round)"), account.roster)]
            if round % 4 == 0 {
                let ended = await shareOutcomes(shares.map { (sender: $0.0, request: $0.1, roster: $0.2) })
                #expect(ended == [nil, nil], "round \(round): \(ended)")
            } else {
                for share in (round % 2 == 0 ? shares : shares.reversed()) {
                    let ended = await failure { try await share.0.send(share.1, roster: share.2) }
                    #expect(ended == nil, "round \(round): \(ended.map { "\($0)" } ?? "")")
                }
            }
            // The Keychain still holds this account with a whole session, in the shape the app reads.
            let item = try #require(account.keychain.value)
            let active = try JSONDecoder().decode(SavedAccounts.self, from: item).active
            #expect(active?.key == key && (active?.cookies?.count ?? 0) >= 2, "round \(round)")
        }
        // …and that session is one the gateway accepts: a last share needs nothing renewed.
        let last = try await account.sender().send(account.text("After a hundred rounds"), roster: account.roster)
        #expect(!last.renewedCookies)
        let after = try await authCounts()
        #expect(after["passwordPosts"] == before["passwordPosts"] && after["logins"] == before["logins"])       // never a sign-in
        #expect(after["rejected"] == before["rejected"])                                                      // nobody was signed out
        #expect((after["refreshes"] ?? 0) - (before["refreshes"] ?? 0) >= 100)
        #expect(account.keychain.counts.updates == 100)                                                       // one saved renewal a round, never two
        let state = try await ShareFixture.state()
        #expect(state.texts.count == 201 && Set(state.texts).count == 201)                                    // each share once
        #expect(state.entries("GET /api/auth/me").allSatisfy { $0["status"]?.int == 200 })
    }

    /// The Keychain's Nous entry, dated as if it were about to lapse, so whoever reads it next renews it.
    private func lapsing(_ account: ShareFixtureAccount) throws {
        var object = account.keychain.object
        var accounts = try #require(object["accounts"] as? [[String: Any]])
        var entry = try #require(accounts[0]["nous"] as? [String: Any])
        let now = Date().timeIntervalSince1970
        entry["expiresAt"] = now + 30
        entry["obtainedAt"] = now - 3600
        accounts[0]["nous"] = entry
        object["accounts"] = accounts
        account.keychain.set(json: object)
    }

    /// What the app does when its token lapses: rotates the Keychain's pair and saves the new one. False when the
    /// gateway refuses the pair.
    private func appRenews(_ account: ShareFixtureAccount) async throws -> Bool {
        let port = try #require(ShareFixture.port), credentials = try #require(ShareFixture.credentials)
        let read = try #require(account.keychain.value)
        let held = try #require(ShareAccounts.current(in: read)?.nous)
        let answer = try await Fixtures.control(port, "/auth/native/refresh", json: ["refresh_token": held.refreshToken, "provider": "nous"])
        guard let access = answer["access_token"]?.string, let refresh = answer["refresh_token"]?.string, let expires = answer["expires_at"]?.double else { return false }
        account.keychain.set(json: ShareSamples.item(url: credentials.url, username: "nous-fixture", cookies: nil,
                                                     nous: ShareSamples.nous(access: access, refresh: refresh, expiresAt: expires, user: held.userId)))
        return true
    }

    @Test func theAppAndAShareRotateOneNousPairThroughAHundredRounds() async throws {
        try await ShareFixture.post("share-reset")
        let account = try nousAccount(try await ShareFixture.nousPair(ttl: 900))
        var dice = ShareDice(seed: 11), byTheShare = 0
        for round in 0..<100 {
            try lapsing(account)
            let appFirst = Bool.random(using: &dice)
            if appFirst { #expect(try await appRenews(account), "round \(round): the app was refused") }
            let before = try await ShareFixture.nousCounts()["refresh"] ?? 0
            let ended = await failure { try await account.sender().send(account.text("Round \(round)"), roster: account.roster) }
            #expect(ended == nil, "round \(round), app first \(appFirst): \(ended.map { "\($0)" } ?? "")")
            let renewed = (try await ShareFixture.nousCounts()["refresh"] ?? 0) - before
            #expect(renewed == (appFirst ? 0 : 1), "round \(round), app first \(appFirst)")
            byTheShare += renewed
            // What the share saved is what the app renews with next.
            if !appFirst { #expect(try await appRenews(account), "round \(round): the app could not use the pair the share saved") }
        }
        let counts = try await ShareFixture.nousCounts()
        #expect(counts["replayed"] == 0 && counts["bearerRejected"] == 0)
        #expect(counts["refresh"] == 100 + byTheShare && byTheShare > 20 && byTheShare < 80)
        #expect(try await ShareFixture.state().texts.count == 100)
    }

    @Test func aNousPairSpentByTheAppAtTheSameMomentEndsTheSessionWithoutALoop() async throws {
        // The owner's known remaining risk, made to happen: the app rotates the pair and has not saved the new one
        // when the share renews with the pair it read. Portal ends the session; the share says so and stops.
        var replays = 0
        for round in 0..<10 {
            try await ShareFixture.post("share-reset")
            let account = try nousAccount(try await ShareFixture.nousPair(ttl: 900))
            try lapsing(account)
            let port = try #require(ShareFixture.port)
            let read = try #require(account.keychain.value)
            let held = try #require(ShareAccounts.current(in: read)?.nous)
            // The app's rotation reaches the gateway; its Keychain write has not happened yet.
            let rotated = try await Fixtures.control(port, "/auth/native/refresh", json: ["refresh_token": held.refreshToken, "provider": "nous"])
            #expect(rotated["access_token"]?.string != nil)
            let started = Date()
            let ended = await failure { try await account.sender().send(account.text("Never arrives \(round)"), roster: account.roster) }
            #expect(ended == .sessionEnded, "round \(round): \(ended.map { "\($0)" } ?? "sent")")
            let counts = try await ShareFixture.nousCounts()
            #expect(counts["refresh"] == 2 && counts["replayed"] == 1, "round \(round): \(counts)")       // the app's, the share's one, never more
            replays += counts["replayed"] ?? 0
            let state = try await ShareFixture.state()
            #expect(state.prompts.isEmpty && account.keychain.counts.updates == 0, "round \(round)")
            #expect(state.labels.filter { $0 == "POST /auth/native/refresh" }.count == 2 && !state.labels.contains("UPGRADE /api/ws"), "round \(round): \(state.labels)")
            #expect(Date().timeIntervalSince(started) < 10, "round \(round)")
        }
        #expect(replays == 10)
    }
}
