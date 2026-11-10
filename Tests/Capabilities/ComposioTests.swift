// Connect Apps unit tests (docs/spec/3x-capabilities.md §10, §12): the Composio client against a URLProtocol stub (no
// network), the key's only destination, error words, the single-use link rule, the gateway record and the catalog words.

import Foundation
import Testing
@testable import HermesHQNative

/// Records every request and answers from a script. Serialized: the stub's state is process-wide.
nonisolated final class ComposioStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [URLRequest] = []
    /// Each request's JSON body, in the order seen (`.null` when none): URLSession hands a stub the body as a stream.
    nonisolated(unsafe) static var bodies: [JSONValue] = []
    nonisolated(unsafe) static var answer: @Sendable (URLRequest) -> (Int, String) = { _ in (200, "{}") }
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        Self.bodies.append(Self.read(request))
        let (status, body) = Self.answer(request)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset(_ answer: @escaping @Sendable (URLRequest) -> (Int, String)) {
        lock.lock(); seen = []; bodies = []; self.answer = answer; lock.unlock()
    }

    private static func read(_ request: URLRequest) -> JSONValue {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return data.isEmpty ? .null : ((try? JSONValue.parse(data)) ?? .null)
    }
}

@Suite(.serialized) @MainActor struct ComposioTests {
    nonisolated static let session = #"{"session_id":"trs_1","mcp":{"type":"http","url":"https://backend.composio.dev/tool_router/v3/trs_1/mcp"},"config":{"user_id":"dispatch-aabbcc"}}"#

    func client(_ keys: ComposioKeychain) -> ComposioClient {
        ComposioClient(keys: keys, session: ComposioClient.makeSession(protocols: [ComposioStub.self]), base: ComposioClient.productionBase)
    }

    func keychain() -> ComposioKeychain { ComposioKeychain(service: "tests.composio.\(UUID().uuidString)") }

    @Test func theKeyGoesOnlyToComposioAndOnlyAsAHeader() async throws {
        let keys = keychain()
        defer { keys.clear() }
        try keys.save("ak_mock_dispatch")
        ComposioStub.reset { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/toolkits") { return (200, #"{"items":[{"slug":"gmail","name":"Gmail","meta":{"logo":"https://logos.composio.dev/api/gmail","description":"Mail"},"connected_account":{"id":"ca_1","status":"active","created_at":"2026-09-29T20:00:00Z"}}],"next_cursor":"30"}"#) }
            if path.hasSuffix("/link") { return (201, #"{"redirect_url":"https://connect.composio.dev/link/lk_1","connected_account_id":"ca_2"}"#) }
            if path.contains("/connected_accounts/") { return (200, #"{"id":"ca_2","status":"INITIATED"}"#) }
            if path.hasSuffix("/tools") { return (200, request.url?.query?.contains("important=true") == true ? #"{"items":[]}"# : #"{"items":[{"slug":"GMAIL_SEND","name":"Send email","description":"Send."}]}"#) }
            return (200, Self.session)
        }
        let client = client(keys)
        let made = try await client.createSession(userID: "dispatch-aabbcc")
        #expect(made.id == "trs_1" && made.userID == "dispatch-aabbcc" && made.mcpURL.hasSuffix("/trs_1/mcp"))
        _ = try await client.readSession("trs_1")
        let page = try await client.toolkits(session: "trs_1", search: "g mail", slugs: ["gmail", "slack"], cursor: "0", limit: 30, connectedOnly: true)
        #expect(page.next == "30" && page.items.first?.account?.isActive == true && page.items.first?.connected == true)
        let link = try await client.link(session: "trs_1", toolkit: "gmail", callback: "hermeshq-native://composio/callback")
        #expect(link.accountID == "ca_2")
        #expect(try await client.account("ca_2").isActive == false)
        try await client.disconnect("ca_2")
        #expect(try await client.tools(toolkit: "gmail").map(\.slug) == ["GMAIL_SEND"], "an empty important list is asked again without the filter")

        let seen = ComposioStub.seen
        #expect(seen.count == 8)
        for request in seen {
            #expect(request.url?.scheme == "https" && request.url?.host == "backend.composio.dev", "\(request.url?.absoluteString ?? "")")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "ak_mock_dispatch")
            #expect(request.url?.absoluteString.contains("ak_mock_dispatch") == false, "never in a URL")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
        }
        #expect(seen[0].httpMethod == "POST" && seen[0].url?.path == "/api/v3.1/tool_router/session")
        #expect(seen[2].url?.query?.contains("is_connected=true") == true && seen[2].url?.query?.contains("toolkits=gmail,slack") == true)
        #expect(seen[3].url?.path == "/api/v3/tool_router/session/trs_1/link")
        #expect(seen[5].httpMethod == "DELETE" && seen[5].url?.path == "/api/v3/connected_accounts/ca_2")
    }

    @Test func aSessionIdCannotLeaveItsPathSegment() async throws {
        let keys = keychain()
        defer { keys.clear() }
        try keys.save("ak_mock_dispatch")
        ComposioStub.reset { _ in (200, Self.session) }
        _ = try? await client(keys).readSession("../../v3/connected_accounts?x=1#frag")
        // The raw (still encoded) path: every "/" of the id is %2F, so it stays one segment.
        let path = ComposioStub.seen.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
        #expect(path.split(separator: "/").count == 5, "\(path)")
        _ = try? await client(keys).readSession("..")
        #expect(ComposioStub.seen.last?.url?.path == "/api/v3.1/tool_router/session/_")
        #expect(ComposioStub.seen.first?.url?.host == "backend.composio.dev")
        #expect(path.hasPrefix("/api/v3.1/tool_router/session/") && !path.contains("/connected_accounts"), "\(path)")
        #expect(ComposioStub.seen.first?.url?.query == nil && ComposioStub.seen.first?.url?.fragment == nil)
    }

    @Test func withoutAKeyNothingIsSent() async {
        let keys = keychain()
        ComposioStub.reset { _ in (200, Self.session) }
        await #expect(throws: ComposioError.noKey) { try await self.client(keys).createSession(userID: "u") }
        #expect(ComposioStub.seen.isEmpty)
    }

    @Test func settingUpChecksAKeyBeforeItIsSaved() async throws {
        let keys = keychain()
        ComposioStub.reset { request in
            request.value(forHTTPHeaderField: "x-api-key") == "ak_mock_dispatch"
                ? (request.httpMethod == "GET" ? (404, #"{"error":{"message":"Session not found"}}"#) : (201, Self.session))
                : (401, #"{"error":{"message":"Invalid API key ak_wrong_key_123"}}"#)
        }
        let client = client(keys)
        do {
            _ = try await client.check(key: "ak_wrong_key_123", userID: "u", session: nil)
            Issue.record("a wrong key must be refused")
        } catch {
            #expect(error.kind == .badKey && !error.message.contains("ak_wrong_key_123"))
        }
        // A session Composio no longer has is replaced by a new one for the same user.
        let made = try await client.check(key: "ak_mock_dispatch", userID: "dispatch-aabbcc", session: "trs_gone")
        #expect(made.id == "trs_1" && ComposioStub.seen.suffix(2).map(\.httpMethod) == ["GET", "POST"])
        #expect(keys.status().saved == false, "checking saves nothing")
    }

    @Test func errorWordsNeverCarryTheKey() {
        #expect(ComposioClient.error(status: 401, body: .null).kind == .badKey)
        #expect(ComposioClient.error(status: 404, body: ["error": ["message": "Session not found"]]).kind == .notFound)
        #expect(ComposioClient.error(status: 429, body: .null).kind == .rateLimited)
        #expect(ComposioClient.error(status: 503, body: .null) == .problem && ComposioClient.error(status: 302, body: .null) == .problem)
        let leaked = ComposioClient.error(status: 400, body: ["error": ["message": "bad key ak_mock_dispatch in body"]], key: "ak_mock_dispatch")
        #expect(leaked.kind == .rejected && !leaked.message.contains("ak_mock_dispatch"))
    }

    @Test func keyStorage() throws {
        let keys = keychain()
        defer { keys.clear() }
        #expect(!keys.status().saved && keys.read() == nil)
        #expect(throws: ComposioError.self) { try keys.save("short") }
        #expect(throws: ComposioError.self) { try keys.save("has spaces in it") }
        try keys.save("ak_mock_dispatch")
        #expect(keys.status().saved && keys.status().hint == "atch" && keys.read() == "ak_mock_dispatch")
        keys.clear()
        #expect(!keys.status().saved)
        #expect(ComposioKeychain.plausible("ak_mock_dispatch") && !ComposioKeychain.plausible("ak mock") && !ComposioKeychain.plausible(String(repeating: "a", count: 300)))
    }

    @Test func connectLinksMustBeComposiosOwn() {
        let base = ComposioClient.productionBase
        #expect(ComposioClient.connectLink("https://connect.composio.dev/link/lk_1", base: base) != nil)
        #expect(ComposioClient.connectLink("https://composio.dev/x", base: base) != nil)
        #expect(ComposioClient.connectLink("http://connect.composio.dev/link/lk_1", base: base) == nil, "never plain http")
        #expect(ComposioClient.connectLink("https://composio.dev.evil.example/link", base: base) == nil)
        #expect(ComposioClient.connectLink("https://evilcomposio.dev/link", base: base) == nil)
        #expect(ComposioClient.connectLink("https://user:pw@connect.composio.dev/link", base: base) == nil)
        #expect(ComposioClient.connectLink("javascript:alert(1)", base: base) == nil)
        #expect(ComposioClient.connectLink("http://127.0.0.1:10012/link/lk_1", base: base) == nil, "loopback only with the stand-in base")
        #expect(ComposioClient.connectLink("http://127.0.0.1:10012/link/lk_1", base: URL(string: "http://127.0.0.1:10012")!) != nil)
        #expect(ComposioClient.loopback("http://127.0.0.1:10012") != nil && ComposioClient.loopback("http://example.com") == nil
                && ComposioClient.loopback("https://127.0.0.1") == nil)
    }

    @Test func gatewayRecordAndBotEntry() throws {
        #expect(ComposioRecord.read(nil) == nil && ComposioRecord.read(["sessionId": "trs_1"]) == nil)
        let record = ComposioRecord.read(["userId": "dispatch-aabbcc", "sessionId": "trs_1", "allBots": true])
        #expect(record == ComposioRecord(userId: "dispatch-aabbcc", sessionId: "trs_1", allBots: true))
        #expect(ComposioRecord.read(record?.json) == record)
        #expect(JSRegex(#"^dispatch-[0-9a-f]{12}$"#).test(ComposioRecord.newUserID()))
        let entry = ComposioRecord.entry(mcpURL: "https://backend.composio.dev/tool_router/v3/trs_1/mcp")
        #expect(entry["headers"]?["x-api-key"] == "${COMPOSIO_API_KEY}", "the entry holds a reference to the bot's env, never the key")
        #expect(ComposioSession.id(fromMcpURL: "https://backend.composio.dev/tool_router/v3/trs_1/mcp") == "trs_1")
        #expect(ComposioSession.id(fromMcpURL: "https://backend.composio.dev/tool_router/trs_2/mcp?x=1") == "trs_2")
        #expect(ComposioSession.id(fromMcpURL: "https://example.com/mcp") == nil)
    }

    @Test func accountsToolkitsAndWords() {
        let expired = ComposioAccount.read(["id": "ca_1", "status": "expired", "status_reason": "Token expired"])
        #expect(expired?.needsSignIn == true && expired?.wasConnected == true && expired?.isActive == false && expired?.reason == "Token expired")
        #expect(ComposioAccount.read(["id": "ca_1", "status": "INITIATED"])?.wasConnected == false)
        #expect(ComposioAccount.read(["status": "ACTIVE"]) == nil)
        let kit = ComposioToolkit.read(["slug": "hackernews", "name": "Hacker News", "is_no_auth": true, "connected_account": .null])
        #expect(kit?.noAuth == true && kit?.connected == false && kit?.account == nil)
        #expect(ComposioToolkit.read(["name": "No slug"]) == nil)
        #expect(ComposioCatalog.nameList([]) == "" && ComposioCatalog.nameList(["Hermes"]) == "Hermes")
        #expect(ComposioCatalog.nameList(["Hermes", "Inbox"]) == "Hermes and Inbox")
        #expect(ComposioCatalog.nameList(["Hermes", "Inbox", "Ivy"]) == "Hermes, Inbox and Ivy")
        #expect(ComposioCatalog.nameList(["Hermes", "Inbox", "Ivy", "A", "B"]) == "Hermes, Inbox and 3 more")
        #expect(ComposioCatalog.tryIt(slug: "nothing-known", name: "Acme") == ["What can you do with Acme?"])
        #expect(!ComposioCatalog.tryIt(slug: "gmail", name: "Gmail").isEmpty)
        #expect(ComposioCatalog.connectedDate("2026-09-29T20:00:00Z", locale: Locale(identifier: "en_US")).contains("2026"))
        #expect(ComposioCatalog.connectedDate("not a date") == "")
        for words in ComposioCatalog.categories.map(\.title) + ComposioCatalog.popular { #expect(!words.lowercased().contains("dispatch")) }
    }

    @Test func theSignInCallbackIsNotANotificationLink() {
        let scheme = AppIdentity.current.urlScheme
        #expect(NotificationRules.link(URL(string: "\(scheme)://composio/callback?status=success&connected_account_id=ca_1")!, scheme: scheme) == nil)
        #expect(ComposioConnect.callback == "\(scheme)://composio/callback")
        #expect(ComposioLogoStore.url(slug: "gmail", logo: "http://logos.composio.dev/api/gmail")?.scheme != "http" || ComposioClient.base != ComposioClient.productionBase)
        #expect(ComposioLogoStore.url(slug: "gmail", logo: "")?.absoluteString == "https://logos.composio.dev/api/gmail" || ComposioClient.base != ComposioClient.productionBase)
    }
}
