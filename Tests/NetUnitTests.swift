import Foundation
import Testing
@testable import HermesHQNative

// MARK: - Addresses (spec 01 §2.2, §2.5)

@Suite struct GatewayAddressTests {
    @Test func typedTextGetsTheRightScheme() {
        #expect(GatewayAddress.normalizeTyped("  studio.tail1234.ts.net ") == "http://studio.tail1234.ts.net")
        #expect(GatewayAddress.normalizeTyped("mac-mini.local:9119") == "http://mac-mini.local:9119")
        #expect(GatewayAddress.normalizeTyped("192.168.1.20:9119") == "http://192.168.1.20:9119")
        #expect(GatewayAddress.normalizeTyped("100.101.102.103") == "http://100.101.102.103")
        #expect(GatewayAddress.normalizeTyped("hermes.example.com") == "https://hermes.example.com")
        #expect(GatewayAddress.normalizeTyped("8.8.8.8") == "https://8.8.8.8")
        #expect(GatewayAddress.normalizeTyped("HTTPS://Studio.Example.com/") == "https://Studio.Example.com/")
        #expect(GatewayAddress.normalizeTyped("[::1]:9119") == "http://[::1]:9119")
        #expect(GatewayAddress.normalizeTyped("myhost") == "http://myhost")
        #expect(GatewayAddress.normalizeTyped("") == "")
    }

    @Test func validationStoresLowercaseSchemeAndHostWithoutTrailingSlash() throws {
        #expect(try GatewayAddress.validated("HTTPS://Studio.Example.com/").absoluteString == "https://studio.example.com")
        #expect(try GatewayAddress.validated("https://studio.example.com:8443/hermes/").absoluteString == "https://studio.example.com:8443/hermes")
        #expect(try GatewayAddress.validated("http://127.0.0.1:9711").absoluteString == "http://127.0.0.1:9711")
        #expect(try GatewayAddress.validated("http://studio.tail1234.ts.net").absoluteString == "http://studio.tail1234.ts.net")
    }

    @Test func validationRefusesBadAddresses() {
        #expect(throws: GatewayFailure.invalidURL) { try GatewayAddress.validated("https://user:pw@host.example.com") }
        #expect(throws: GatewayFailure.invalidURL) { try GatewayAddress.validated("https://host.example.com/?a=1") }
        #expect(throws: GatewayFailure.invalidURL) { try GatewayAddress.validated("https://host.example.com/#frag") }
        #expect(throws: GatewayFailure.invalidURL) { try GatewayAddress.validated("ftp://host.example.com") }
        #expect(throws: GatewayFailure.invalidURL) { try GatewayAddress.validated("not a url") }
        #expect(throws: GatewayFailure.insecureURL) { try GatewayAddress.validated("http://hermes.example.com") }
        #expect(throws: GatewayFailure.insecureURL) { try GatewayAddress.validated("http://8.8.8.8:9119") }
    }

    @Test func cleartextOnlyOnNetworksTheUserControls() {
        for host in ["127.0.0.1", "10.0.0.2", "172.16.5.4", "172.31.255.1", "192.168.0.9", "169.254.1.1", "100.64.0.1",
                     "100.127.255.255", "localhost", "studio", "mac.local", "box.tail1234.ts.net", "::1", "[fe80::1]", "fd7a:115c:a1e0::1"] {
            #expect(GatewayAddress.cleartextAllowed(host: host), "\(host)")
        }
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "example.com", "1.2.3", "2001:db8::1", ""] {
            #expect(!GatewayAddress.cleartextAllowed(host: host), "\(host)")
        }
    }

    @Test func tailnetOnlyGatewaysNeedTailscaleUp() {
        let tailnet = URL(string: "http://100.101.1.2:9119")!
        let named = URL(string: "http://studio.tail1.ts.net")!
        let lan = URL(string: "http://192.168.1.4:9119")!
        let https = URL(string: "https://studio.tail1.ts.net")!
        #expect(GatewayAddress.tailnetOnly(tailnet) && GatewayAddress.tailnetOnly(named))
        #expect(!GatewayAddress.tailnetOnly(lan) && !GatewayAddress.tailnetOnly(https))
        let cellular = [GatewayAddress.Interface(name: "pdp_ip0", address: "100.70.1.2")]
        let tunnel = [GatewayAddress.Interface(name: "utun4", address: "100.101.9.9")]
        #expect(!GatewayAddress.reachable(tailnet, interfaces: { cellular }))
        #expect(GatewayAddress.reachable(tailnet, interfaces: { tunnel }))
        #expect(GatewayAddress.reachable(lan, interfaces: { cellular }))
    }

    @Test func endpointsStayUnderTheGatewayAndItsPrefix() throws {
        let base = URL(string: "https://studio.example.com/hermes")!
        #expect(try GatewayAddress.endpoint(base: base, path: "/api/sessions").absoluteString == "https://studio.example.com/hermes/api/sessions")
        let query = try GatewayAddress.endpoint(base: base, path: "/api/sessions/x/messages",
                                                query: [URLQueryItem(name: "profile", value: "ivy+1"), URLQueryItem(name: "limit", value: "50")])
        #expect(query.absoluteString == "https://studio.example.com/hermes/api/sessions/x/messages?profile=ivy%2B1&limit=50")
        #expect(throws: GatewayFailure.invalidDestination) { try GatewayAddress.endpoint(base: base, path: "api/x") }
        #expect(throws: GatewayFailure.invalidDestination) { try GatewayAddress.endpoint(base: base, path: "//evil.example/api") }
        #expect(throws: GatewayFailure.invalidDestination) { try GatewayAddress.endpoint(base: base, path: "/api/../../etc") }
        #expect(throws: GatewayFailure.invalidDestination) { try GatewayAddress.endpoint(base: base, path: "/api\\x") }
        #expect(throws: GatewayFailure.invalidDestination) { try GatewayAddress.endpoint(base: base, path: "/api/x\r\nHost: y") }
    }

    @Test func socketURLCarriesProfileThenTicket() throws {
        let https = try GatewayAddress.socketURL(base: URL(string: "https://h.example.com:8443")!, profile: "default", ticket: "a+b/c")
        #expect(https.absoluteString == "wss://h.example.com:8443/api/ws?profile=default&ticket=a%2Bb/c")
        let http = try GatewayAddress.socketURL(base: URL(string: "http://127.0.0.1:9711")!, profile: "ivy", ticket: "t")
        #expect(http.absoluteString == "ws://127.0.0.1:9711/api/ws?profile=ivy&ticket=t")
    }

    @Test func accountKeysIgnoreCaseAndTrailingSlash() {
        #expect(GatewayAddress.accountKey(url: "HTTPS://Studio.Example.com/", username: "fleet") == "https://studio.example.com\nfleet")
        #expect(GatewayAddress.accountKey(url: "http://127.0.0.1:9711", username: "nous:u1") == "http://127.0.0.1:9711\nnous:u1")
    }

    @Test func controlPathsAndCeilings() {
        #expect(GatewayAddress.isControlPath("/api/auth/ws-ticket"))
        #expect(GatewayAddress.isControlPath("/auth/native/refresh?x=1"))
        #expect(!GatewayAddress.isControlPath("/api/sessions"))
        #expect(GatewayAddress.responseLimit(path: "/api/auth/me") == 1 << 20)
        #expect(GatewayAddress.responseLimit(path: "/api/sessions/x/messages") == 32 << 20)
    }
}

// MARK: - JSON-RPC framing (spec 01 §11)

@Suite struct RPCFrameTests {
    @Test func eventFrames() {
        let frame = RPCFrame.parse(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"5cc537d1","payload":{"text":"Hel"},"seq":42}}"#)
        guard case .event(let event) = frame else { Issue.record("not an event: \(frame)"); return }
        #expect(event.type == "message.delta")
        #expect(event.sessionId == "5cc537d1")
        #expect(event.seq == 42)
        #expect(event.payload["text"]?.string == "Hel")
    }

    @Test func gatewayReadyHasNoSessionAndNoSeq() {
        let frame = RPCFrame.parse(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":true,"change_events":true,"replay_epoch":"build47","desktop_contract":8}}}"#)
        guard case .event(let event) = frame else { Issue.record("not an event"); return }
        #expect(event.type == "gateway.ready" && event.sessionId == "" && event.seq == nil)
        #expect(event.payload["heartbeat"]?.bool == true)
        #expect(event.payload["replay_epoch"]?.string == "build47")
        #expect(event.payload["desktop_contract"]?.int == 8)
    }

    @Test func eventWithNullSessionAndNoPayload() {
        guard case .event(let event) = RPCFrame.parse(#"{"method":"event","params":{"type":"sessions.changed","session_id":null}}"#) else {
            Issue.record("not an event"); return
        }
        #expect(event.sessionId == "" && event.payload.isNull)
    }

    @Test func responses() {
        guard case .result(let id, let value) = RPCFrame.parse(#"{"jsonrpc":"2.0","id":17,"result":{"sessions":[{"id":"a"}],"ok":true}}"#) else {
            Issue.record("not a result"); return
        }
        #expect(id == 17)
        #expect(value["sessions"]?[0]?["id"]?.string == "a")
        #expect(value["ok"]?.bool == true)
        guard case .failure(let failedId, let error) = RPCFrame.parse(#"{"jsonrpc":"2.0","id":3,"error":{"code":4001,"message":"session not found","data":{"x":1}}}"#) else {
            Issue.record("not a failure"); return
        }
        #expect(failedId == 3 && error.code == 4001 && error.message == "session not found" && error.data?["x"]?.int == 1)
        guard case .failure(_, let blank) = RPCFrame.parse(#"{"id":4,"error":{"code":-32603}}"#) else { Issue.record("no failure"); return }
        #expect(blank.message == "Hermes RPC failed")
        guard case .result(_, let null) = RPCFrame.parse(#"{"id":5,"result":null}"#) else { Issue.record("no result"); return }
        #expect(null.isNull)
    }

    @Test func heartbeatAnswersAndServerRequests() {
        guard case .stringAnswer(let id) = RPCFrame.parse(#"{"jsonrpc":"2.0","result":{"ok":true},"id":"heartbeat-3"}"#) else {
            Issue.record("not a string answer"); return
        }
        #expect(id == "heartbeat-3")
        guard case .serverRequest(let rid, let method, let params) = RPCFrame.parse(#"{"jsonrpc":"2.0","id":"srq-1a2b3c4d5e6f","method":"clarify","params":{"session_id":"abc"}}"#) else {
            Issue.record("not a server request"); return
        }
        #expect(rid == "srq-1a2b3c4d5e6f" && method == "clarify" && params["session_id"]?.string == "abc")
    }

    @Test func junkIsIgnored() {
        for text in ["", "   ", "not json", "[1,2]", "42", #"{"jsonrpc":"2.0"}"#, #"{"method":"event","params":{"session_id":"x"}}"#,
                     #"{"method":"notify","params":{}}"#] {
            guard case .ignored = RPCFrame.parse(text) else { Issue.record("not ignored: \(text)"); continue }
        }
        guard case .orphanError(let error) = RPCFrame.parse(#"{"jsonrpc":"2.0","error":{"code":-32700,"message":"parse error"},"id":null}"#) else {
            Issue.record("not an orphan error"); return
        }
        #expect(error.code == -32700)
    }

    @Test func booleansAndNumbersStayDistinct() {
        guard case .result(_, let value) = RPCFrame.parse(#"{"id":1,"result":{"t":true,"f":false,"one":1,"zero":0,"pi":3.5}}"#) else {
            Issue.record("no result"); return
        }
        #expect(value["t"] == .bool(true) && value["f"] == .bool(false))
        #expect(value["one"] == .number(1) && value["zero"] == .number(0) && value["pi"] == .number(3.5))
    }

    @Test func requestsAreObjectsWithIntegerIds() throws {
        let text = RPCFrame.request(id: 7, method: "session.list", params: ["limit": 1])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect((object["id"] as? NSNumber)?.intValue == 7)
        #expect(object["method"] as? String == "session.list")
        #expect((object["params"] as? [String: Any])?["limit"] as? Int == 1)
        #expect(!text.contains("7.0"))
        let bare = RPCFrame.request(id: 8, method: "gateway.ping", params: .null)
        #expect(bare.contains(#""params":{}"#))
        let heartbeat = RPCFrame.request(id: "heartbeat-1", method: "gateway.ping")
        #expect(heartbeat.contains(#""id":"heartbeat-1""#))
    }

    @Test func replayElementsParse() {
        let element: JSONValue = ["type": "message.delta", "session_id": "s1", "payload": ["text": "lo"], "seq": 42]
        let event = RPCFrame.event(from: element)
        #expect(event?.type == "message.delta" && event?.seq == 42 && event?.sessionId == "s1")
    }
}

// MARK: - Back-off, ticket ladder, path changes

@Suite struct ConnectionPolicyTests {
    @Test func backoffStaysWithinFullJitterBounds() {
        let backoff = ReconnectBackoff.afterReady
        #expect(backoff.ceiling(attempt: 0) == 0.3)
        #expect(backoff.ceiling(attempt: 1) == 0.6)
        #expect(backoff.ceiling(attempt: 5) == 9.6)
        #expect(backoff.ceiling(attempt: 6) == 15)
        #expect(backoff.ceiling(attempt: 1000) == 15)
        #expect(backoff.delay(attempt: 3, random: 0) == 0)
        #expect(abs(backoff.delay(attempt: 3, random: 0.5) - 1.2) < 1e-9)
        for attempt in 0..<40 {
            for _ in 0..<50 {
                let delay = backoff.delay(attempt: attempt)
                #expect(delay >= 0 && delay <= min(15, 0.3 * pow(2, Double(attempt))))
            }
        }
        #expect(ReconnectBackoff.beforeReady.ceiling(attempt: 0) == 2)
        #expect(ReconnectBackoff.beforeReady.ceiling(attempt: 3) == 15)
    }

    @Test func ticketTimeoutLadder() {
        #expect(ticketTimeout(afterTimeouts: 0) == .seconds(8))
        #expect(ticketTimeout(afterTimeouts: 1) == .seconds(15))
        #expect(ticketTimeout(afterTimeouts: 2) == .seconds(20))
        #expect(ticketTimeout(afterTimeouts: 9) == .seconds(20))
    }

    @Test func pathChanges() {
        let wifi = PathChange.signature(satisfied: true, interfaces: ["wifi"])
        let wifiVPN = PathChange.signature(satisfied: true, interfaces: ["other", "wifi", "other"])
        let cellVPN = PathChange.signature(satisfied: true, interfaces: ["cellular", "other"])
        let cell = PathChange.signature(satisfied: true, interfaces: ["cellular"])
        let down = PathChange.signature(satisfied: false, interfaces: [])
        #expect(wifiVPN == "up:other,wifi")
        #expect(PathChange.between(nil, wifi) == .none)
        #expect(PathChange.between(wifi, wifi) == .none)
        #expect(PathChange.between(wifi, down) == .lost)
        #expect(PathChange.between(down, down + "x") == .none)
        #expect(PathChange.between(down, wifi) == .restored)
        #expect(PathChange.between(wifi, cell) == .replaced)
        #expect(PathChange.between(wifiVPN, cellVPN) == .verify)
    }
}

// MARK: - Accounts and tokens (spec 01 §2.1, §7)

@Suite struct AccountRulesTests {
    func tokens(_ access: String, _ refresh: String, expires: Double = 2_000_000_000, user: String = "u1", obtained: Double? = 1_999_999_000) -> NousTokens {
        NousTokens(accessToken: access, refreshToken: refresh, expiresAt: expires, userId: user, obtainedAt: obtained)
    }

    @Test func renewalFollowsD6() {
        // Lifetime 3600 s: renew in the last 60 s (like the web client).
        let long = tokens("a", "r", expires: 3600, obtained: 0)
        #expect(!long.needsRenewal(now: 3539))
        #expect(long.needsRenewal(now: 3540))
        // Lifetime 30 s: renew after half of it, not on every request.
        let short = tokens("a", "r", expires: 30, obtained: 0)
        #expect(!short.needsRenewal(now: 14.9))
        #expect(short.needsRenewal(now: 15))
        // Lifetime 120 s: the two rules meet.
        #expect(!tokens("a", "r", expires: 120, obtained: 0).needsRenewal(now: 59))
        #expect(tokens("a", "r", expires: 120, obtained: 0).needsRenewal(now: 60))
        // No expiry, or a clock ahead of Portal's: no proactive renewal.
        #expect(!tokens("a", "r", expires: 0, obtained: 100).needsRenewal(now: 10_000))
        #expect(!tokens("a", "r", expires: 50, obtained: 100).needsRenewal(now: 10_000))
        // A pair this app did not mint: the web rule.
        #expect(tokens("a", "r", expires: 1000, obtained: nil).needsRenewal(now: 941))
        #expect(!tokens("a", "r", expires: 1000, obtained: nil).needsRenewal(now: 939))
    }

    @Test func renewsAlongsideFromHalfItsLifetime() {
        // [renew-alongside] Lifetime 900 s: renewed alongside from 450 s; the request waits only in the last 60 s.
        let long = tokens("a", "r", expires: 900, obtained: 0)
        #expect(!long.renewsAlongside(now: 449))
        #expect(long.renewsAlongside(now: 450) && !long.needsRenewal(now: 450))
        #expect(long.needsRenewal(now: 840))
        // Lifetime 30 s: half is also D6's point, so there is no window alongside (the request waits, as before).
        let short = tokens("a", "r", expires: 30, obtained: 0)
        #expect(!short.renewsAlongside(now: 14.9) && short.renewsAlongside(now: 15) && short.needsRenewal(now: 15))
        // No expiry, a clock ahead of Portal's, or a pair this app did not mint: never alongside.
        #expect(!tokens("a", "r", expires: 0, obtained: 100).renewsAlongside(now: 10_000))
        #expect(!tokens("a", "r", expires: 50, obtained: 100).renewsAlongside(now: 10_000))
        #expect(!tokens("a", "r", expires: 1000, obtained: nil).renewsAlongside(now: 900))
    }

    @Test func savedAccountsListRules() throws {
        var list = SavedAccounts()
        let a = StoredAccount(url: "https://a.example.com", username: "fleet", cookies: [SavedCookie(name: "s", value: "1", domain: "a.example.com")])
        let b = StoredAccount(url: "https://b.example.com", username: "nous:u1", nous: tokens("at", "rt"))
        list.save(a)
        list.save(b)
        #expect(list.current == b.key && list.accounts.map(\.key) == [b.key, a.key])
        let selected = list.select(a.key)
        #expect(selected && list.current == a.key && list.accounts.first?.key == a.key)
        var renamed = a; renamed.label = "Home"
        list.save(renamed)
        var again = a; again.cookies = []
        list.save(again)
        #expect(list.active?.label == "Home") // a save without a label keeps the old one
        // Compare-and-swap: only the exact pair a renewal started from is replaced.
        let wrongPair = list.renewNous(b.key, sent: tokens("other", "x"), renewed: tokens("at2", "rt2"))
        #expect(!wrongPair)
        let rightPair = list.renewNous(b.key, sent: tokens("at", "rt", obtained: nil), renewed: tokens("at2", "rt2"))
        #expect(rightPair)
        #expect(list.account(b.key)?.nous?.accessToken == "at2")
        // Removing the current account makes the next most recent current.
        let removedA = list.remove(a.key)
        #expect(removedA != nil && list.current == b.key)
        let removedB = list.remove(b.key)
        #expect(removedB != nil && list.current == nil)
    }

    @Test func storedJSONMatchesTheSpecShapeAndNeverAPassword() throws {
        let json = #"{"current":"https://studio.example.com\nnous:user_abc","accounts":[{"url":"https://studio.example.com","username":"nous:user_abc","label":"Studio","password":"leaked","nous":{"accessToken":"eyJ","refreshToken":"nrt_","expiresAt":1791234567,"userId":"user_abc"}},{"url":"https://studio.example.com","username":"fleet","provider":"basic","cookies":[{"name":"__Host-hermes_session_at","value":"v","domain":"studio.example.com","path":"/","expires":1791200000,"secure":true,"httpOnly":true,"sameSite":"lax"}]}]}"#
        let list = try #require(SavedAccounts.decode(Data(json.utf8)))
        #expect(list.active?.username == "nous:user_abc")
        #expect(list.active?.nous?.obtainedAt == nil)
        #expect(list.accounts[1].cookies?.first?.cookie?.isHTTPOnly == true)
        let written = String(decoding: try list.encoded(), as: UTF8.self)
        #expect(!written.contains("password") && !written.contains("leaked"))
        let nous = try #require(list.active?.gatewayAccount)
        #expect(nous.kind == .nous && nous.username == nil && nous.label == "Studio")
        let password = try #require(list.accounts[1].gatewayAccount)
        #expect(password.kind == .password && password.username == "fleet" && password.label == "studio.example.com")
        #expect(password.id == "https://studio.example.com|fleet")
    }

    @Test func cookieSameness() {
        let one = [SavedCookie(name: "at", value: "1", domain: "h"), SavedCookie(name: "rt", value: "2", domain: "h")]
        let reordered = [SavedCookie(name: "rt", value: "2", domain: "h", path: "/x"), SavedCookie(name: "at", value: "1", domain: "h")]
        let renewed = [SavedCookie(name: "at", value: "3", domain: "h"), SavedCookie(name: "rt", value: "2", domain: "h")]
        #expect(SavedCookie.same(one, reordered))
        #expect(!SavedCookie.same(one, renewed))
    }
}

// MARK: - Nous protocol pieces (spec 01 §6)

@Suite struct NousProtocolTests {
    @Test func pkceAndState() {
        let (verifier, challenge) = NousPKCE.pair()
        #expect(verifier.count == 86)
        #expect(!verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
        #expect(challenge == NousPKCE.challenge(for: verifier))
        #expect(challenge.count == 43)
        // RFC 7636 appendix B.
        #expect(NousPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(NousPKCE.state().count == 43)
        #expect(NousPKCE.sameState("abc", "abc"))
        #expect(!NousPKCE.sameState("abd", "abc"))
        #expect(!NousPKCE.sameState(nil, "abc") && !NousPKCE.sameState("", "") && !NousPKCE.sameState("ab", "abc"))
    }

    @Test func authorizeURL() throws {
        let url = try #require(NousGatewayProtocol.authorizeURL(gateway: URL(string: "https://g.example.com")!, challenge: "c+d",
                                                                 redirect: "http://127.0.0.1:53124/callback", state: "s"))
        #expect(url.absoluteString == "https://g.example.com/auth/native/authorize?provider=nous&code_challenge=c%2Bd&code_challenge_method=S256&redirect_uri=http://127.0.0.1:53124/callback&state=s")
    }

    @Test func offersNous() {
        #expect(NousGatewayProtocol.offersNous(status: ["auth_providers": ["basic", "nous"], "auth_flows": ["cookie", "native_pkce"]]))
        #expect(!NousGatewayProtocol.offersNous(status: ["auth_providers": ["basic", "nous"], "auth_flows": ["cookie"]]))
        #expect(!NousGatewayProtocol.offersNous(status: ["auth_providers": ["basic"], "auth_flows": ["native_pkce"]]))
    }

    /// [own-login] A gateway whose browser login is its own (self-hosted OIDC), not Nous (tester Papy 2026-11-12).
    @Test func ownLoginProvider() throws {
        let status: JSONValue = ["auth_providers": ["self-hosted"], "auth_flows": ["cookie", "native_pkce"]]
        #expect(!NousGatewayProtocol.offersNous(status: status) && NousGatewayProtocol.offersBrowserSignIn(status: status))
        #expect(!NousGatewayProtocol.offersBrowserSignIn(status: ["auth_providers": ["self-hosted"], "auth_flows": ["cookie"]]))
        let listed: JSONValue = ["providers": [["name": "basic", "display_name": "Password", "supports_password": true],
                                               ["name": "self-hosted", "display_name": "Self-Hosted OIDC", "supports_password": false]]]
        let own = try #require(NousGatewayProtocol.ownLogin(providers: listed))
        #expect(own == BrowserLogin(provider: "self-hosted", displayName: "Self-Hosted OIDC"))
        #expect(own.buttonTitle == "Sign in with Single Sign-On")
        #expect(BrowserLogin(provider: "okta", displayName: "Okta").buttonTitle == "Sign in with Okta")
        #expect(BrowserLogin(provider: "x", displayName: "").buttonTitle == "Sign in with Single Sign-On")
        // Nous and password providers are never "its own login"; nor is an empty list.
        #expect(NousGatewayProtocol.ownLogin(providers: ["providers": [["name": "nous", "display_name": "Nous"], ["name": "basic", "supports_password": true]]]) == nil)
        #expect(NousGatewayProtocol.ownLogin(providers: ["providers": []]) == nil)

        let url = try #require(NousGatewayProtocol.authorizeURL(gateway: URL(string: "https://g.example.com")!, provider: "self-hosted",
                                                                 challenge: "c", redirect: "http://127.0.0.1:53124/callback", state: "s"))
        #expect(url.absoluteString.contains("/auth/native/authorize?provider=self-hosted&code_challenge=c&"))

        // The pair is taken only from the provider the account signed in with, and remembers it for renewals.
        let body = Data(#"{"access_token":"a","refresh_token":"r","expires_at":1791234567,"provider":"self-hosted","user_id":"sub-1"}"#.utf8)
        #expect(NousGatewayProtocol.answer(status: 200, body: body) == .unavailable(502))
        guard case .tokens(let tokens) = NousGatewayProtocol.answer(status: 200, body: body, provider: "self-hosted", now: 5) else {
            Issue.record("no tokens"); return
        }
        #expect(tokens.provider == "self-hosted" && tokens.providerName == "self-hosted" && tokens.userId == "sub-1")
        let nousBody = Data(#"{"access_token":"a","refresh_token":"r","provider":"nous","user_id":"u"}"#.utf8)
        #expect(NousGatewayProtocol.answer(status: 200, body: nousBody, provider: "self-hosted") == .unavailable(502))
        guard case .tokens(let nous) = NousGatewayProtocol.answer(status: 200, body: nousBody) else { Issue.record("no tokens"); return }
        #expect(nous.provider == nil && nous.providerName == "nous")

        // No refresh token (a login without offline_access): taken for its own login only, never renewed ahead of time.
        let bare = Data(#"{"access_token":"a","refresh_token":"","expires_at":100,"provider":"self-hosted","user_id":"sub-1"}"#.utf8)
        guard case .tokens(let short) = NousGatewayProtocol.answer(status: 200, body: bare, provider: "self-hosted", now: 10) else {
            Issue.record("no tokens"); return
        }
        #expect(!short.canRenew && !short.needsRenewal(now: 99) && !short.renewsAlongside(now: 99))
        #expect(NousGatewayProtocol.answer(status: 200, body: Data(#"{"access_token":"a","refresh_token":"","provider":"nous","user_id":"u"}"#.utf8)) == .unavailable(502))
        #expect(ShareNous(["accessToken": "a", "refreshToken": "", "userId": "u"] as [String: Any]) == nil)
        #expect(ShareNous(["accessToken": "a", "refreshToken": "", "userId": "u", "provider": "self-hosted", "expiresAt": 100, "obtainedAt": 10] as [String: Any])?.needsRenewal(now: 99) == false)

        // Saved and read back with its provider; a pair saved by an older build (no provider) is Nous.
        let stored = StoredAccount(url: "https://g.example.com", username: StoredAccount.nousUsername(userId: tokens.userId), nous: tokens)
        let read = try #require(SavedAccounts.decode(try SavedAccounts(current: stored.key, accounts: [stored]).encoded())?.active)
        #expect(read.nous?.provider == "self-hosted" && read.isNous)
        let account = try #require(read.gatewayAccount)
        #expect(account.kind == .nous && account.usesOwnLogin && GatewayNaming.accountName(account) == "Single sign-on")
        let old = try #require(SavedAccounts.decode(Data(#"{"current":"https://g.example.com\nnous:u","accounts":[{"url":"https://g.example.com","username":"nous:u","nous":{"accessToken":"a","refreshToken":"r","expiresAt":1,"userId":"u"}}]}"#.utf8))?.active)
        #expect(old.nous?.provider == nil && old.gatewayAccount?.usesOwnLogin == false)
        #expect(GatewayNaming.accountName(try #require(old.gatewayAccount)) == "Nous account")

        // The Share extension renews the same pair by the same rule.
        let shared = try #require(ShareNous(["accessToken": "a", "refreshToken": "r", "userId": "sub-1", "provider": "self-hosted"] as [String: Any]))
        #expect(shared.providerName == "self-hosted" && shared.json["provider"] as? String == "self-hosted")
        #expect(ShareNous.renewed(status: 200, body: body, userId: "sub-1") == nil)
        #expect(ShareNous.renewed(status: 200, body: body, userId: "sub-1", provider: shared.provider, now: 9)?.provider == "self-hosted")

        // The form: the browser way in is this login; the words never name Nous.
        let options = SignInOptions(reachable: true, offersNous: false, offersPassword: false, ownLoginTitle: own.buttonTitle)
        #expect(SignInWays(options) == .nous)
        #expect(ProbeResult(known: true, nous: false, password: true, ownLogin: own).ways == .both)
        #expect(!SignInCopy.subtitle(.nous, ownLogin: true).contains("Nous") && !SignInCopy.footnote(.nous, ownLogin: true).contains("Nous"))
        #expect(SignInCopy.message(for: SignInError("nous-failed"), ownLogin: true) == "The sign-in didn’t finish. Try again.")
        #expect(SignInCopy.message(for: SignInError("nous-failed"), ownLogin: false) == "Nous sign-in didn’t finish. Try again.")
    }

    /// [own-vpn] A WireGuard (or any own VPN's) private address or name takes plain http://, as Tailscale's does.
    @Test func ownVPNAddresses() throws {
        for host in ["10.8.0.1", "172.16.5.2", "192.168.42.10", "fd00:1234::1", "hermes.lan", "hermes.home.arpa", "box.wg.internal", "HERMES.LAN."] {
            #expect(GatewayAddress.cleartextAllowed(host: host), "\(host)")
            #expect(SignInAddress.isLocalHost(host), "\(host)")
        }
        for host in ["hermes.example.com", "evil-lan.com", "internal.example.org", "hermes.lan.example.com"] {
            #expect(!GatewayAddress.cleartextAllowed(host: host), "\(host)")
            #expect(!SignInAddress.isLocalHost(host), "\(host)")
        }
        #expect(GatewayAddress.normalizeTyped("hermes.lan:9119") == "http://hermes.lan:9119")
        #expect(try GatewayAddress.validated("http://hermes.home.arpa:9119").absoluteString == "http://hermes.home.arpa:9119")
        // A WireGuard address is not "tailnet-only": nothing waits for Tailscale.
        #expect(GatewayAddress.reachable(URL(string: "http://10.8.0.1:9119")!, interfaces: { [] }))
    }

    @Test func tokenAnswers() {
        let good = Data(#"{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_at":1791234567,"provider":"nous","user_id":"user_abc"}"#.utf8)
        guard case .tokens(let tokens) = NousGatewayProtocol.answer(status: 200, body: good, now: 1791234500) else { Issue.record("no tokens"); return }
        #expect(tokens.userId == "user_abc" && tokens.expiresAt == 1791234567 && tokens.obtainedAt == 1791234500)
        let numeric = Data(#"{"access_token":"a","refresh_token":"r","provider":"nous","user_id":42}"#.utf8)
        guard case .tokens(let n) = NousGatewayProtocol.answer(status: 200, body: numeric) else { Issue.record("no tokens"); return }
        #expect(n.userId == "42" && n.expiresAt == 0)
        #expect(NousGatewayProtocol.answer(status: 200, body: Data(#"{"access_token":"a","refresh_token":"r","provider":"basic","user_id":"u"}"#.utf8)) == .unavailable(502))
        #expect(NousGatewayProtocol.answer(status: 400, body: Data(#"{"detail":"Invalid or expired authorization code."}"#.utf8)) == .refused("session_expired"))
        #expect(NousGatewayProtocol.answer(status: 403, body: Data(#"{"error":"not_authorized"}"#.utf8)) == .refused("not_authorized"))
        #expect(NousGatewayProtocol.answer(status: 403, body: Data()) == .refused("not_authorized"))
        #expect(NousGatewayProtocol.answer(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8)) == .unavailable(429))
    }

    @Test func loopbackCallbackParsing() {
        let settled = LoopbackRelay.callback(fromRequestHead: "GET /callback?code=abc&state=xyz&iss=https%3A%2F%2Fp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(settled == LoopbackRelay.Callback(code: "abc", error: nil, iss: "https://p", state: "xyz"))
        #expect(LoopbackRelay.callback(fromRequestHead: "GET /callback?error=access_denied HTTP/1.1\r\n\r\n")?.error == "access_denied")
        #expect(LoopbackRelay.callback(fromRequestHead: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(LoopbackRelay.callback(fromRequestHead: "GET /callback HTTP/1.1\r\n\r\n") == nil)
        #expect(LoopbackRelay.callback(fromRequestHead: "GET /callbackx?code=1 HTTP/1.1\r\n\r\n") == nil)
        #expect(LoopbackRelay.callback(fromRequestHead: "garbage") == nil)
    }
}

// MARK: - [nous-different-account] The Nous sheet's saved login

/// Tester 2026-11-02: signed in to the wrong Nous account and couldn't get out, because every sheet borrowed
/// Safari's saved login. Each case starts from `.shared` and puts the person's real mode back after.
@Suite(.serialized) @MainActor struct NousSheetLoginTests {
    private func fresh(_ body: () -> Void) {
        let saved = NousSheetLogin.mode
        NousSheetLogin.mode = .shared
        body()
        NousSheetLogin.mode = saved
    }

    @Test func aGatewaySignOutMakesOnlyTheNextSheetPrivate() {
        fresh {
            #expect(!NousSheetLogin.isPrivate)
            NousSheetLogin.signedOut()
            #expect(NousSheetLogin.mode == .once && NousSheetLogin.isPrivate)
            NousSheetLogin.finished()
            #expect(NousSheetLogin.mode == .shared && !NousSheetLogin.isPrivate)
        }
    }

    @Test func anotherAccountKeepsEverySheetPrivateOnceItFinishes() {
        fresh {
            NousSheetLogin.chooseAccount()
            #expect(NousSheetLogin.mode == .choose && NousSheetLogin.isPrivate)
            NousSheetLogin.finished()
            #expect(NousSheetLogin.mode == .always)
            // Safari still holds the other account: a later sign-out or sign-in doesn't go back to it.
            NousSheetLogin.signedOut()
            NousSheetLogin.finished()
            NousSheetLogin.chooseAccount()
            #expect(NousSheetLogin.mode == .always && NousSheetLogin.isPrivate)
        }
    }

    @Test func choosingWinsOverASignOut() {
        fresh {
            NousSheetLogin.signedOut()
            NousSheetLogin.chooseAccount()
            #expect(NousSheetLogin.mode == .choose)
            NousSheetLogin.signedOut()   // a sign-out after choosing keeps the choice
            #expect(NousSheetLogin.mode == .choose)
        }
    }

    @Test func aSharedSignInChangesNothing() {
        fresh {
            NousSheetLogin.finished()
            #expect(NousSheetLogin.mode == .shared)
        }
    }

    @Test func theNotOwnerWordsPointAtTheLink() {
        #expect(GatewayFailure.notOwner.message.contains(SignInCopy.otherNousAccount))
        #expect(SignInCopy.messages["not-owner"]?.contains(SignInCopy.otherNousAccount) == true)
    }
}

// MARK: - Failures, compatibility, probe mapping

@Suite struct FailureTests {
    @Test func httpStatusesMapToPlainFailures() {
        #expect(GatewayFailure.from(HTTPError(status: 401, body: nil)) == .sessionEnded)
        #expect(GatewayFailure.from(HTTPError(status: 403, body: #"{"error":"not_authorized"}"#)) == .notOwner)
        #expect(GatewayFailure.from(HTTPError(status: 400, body: "Invalid Host header")) == .hostRejected)
        #expect(GatewayFailure.from(HTTPError(status: 429, body: nil)) == .rateLimited)
        #expect(GatewayFailure.from(HTTPError(status: 503, body: nil)) == .unavailable)
        #expect(GatewayFailure.from(URLError(.timedOut)) == .timeout)
        #expect(GatewayFailure.from(URLError(.cannotConnectToHost)) == .unreachable)
        #expect(GatewayFailure.from(URLError(.serverCertificateUntrusted)) == .tls)
        #expect(GatewayFailure.from(RPCError.timedOut("prompt.submit", after: .seconds(30))) == .timeout)
        #expect(RPCError.timedOut("session.list", after: .seconds(30)).message == "request timed out after 30s: session.list")
    }

    /// Audit 10-2, 10-3: a failure alert never shows protocol wording, a transport line or a bare status number.
    @Test func failureWordsArePlain() {
        let invalid = RPCError(code: 4000, message: "invalid params for prompt.submit: unexpected key", data: nil)
        #expect(!invalid.plainReason.contains("prompt.submit") && invalid.plainReason.hasPrefix("Your gateway didn’t accept"))
        #expect(RPCError(code: 4000, message: "Invalid_params", data: nil).plainReason == invalid.plainReason)
        #expect(RPCError(code: -32601, message: "method not found: x.y", data: nil).plainReason == invalid.plainReason)
        #expect(RPCError.timedOut("projects.create", after: .seconds(30)).plainReason == GatewayFailure.timeout.message)
        #expect(!RPCError.connectionLost("projects.create").plainReason.contains("projects.create"))
        #expect(RPCError(code: 5000, message: " That name is taken. ", data: nil).plainReason == "That name is taken.")
        #expect(RPCError(code: -32603, message: "Internal error", data: nil).plainReason == GatewayFailure.gatewayError(nil).message)
        #expect(HTTPError(status: 503, body: nil).plainWords == GatewayFailure.unavailable.message)
        #expect(HTTPError(status: 500, body: nil).plainWords == "Your gateway ran into a problem (error 500). Try again.")
        #expect(CapabilitiesStore.detail(HTTPError(status: 500, body: nil)) == HTTPError(status: 500, body: nil).plainWords)
    }

    @Test func rejectionsAndCopy() {
        #expect(GatewayFailure.authRejected.isRejection && GatewayFailure.sessionEnded.isRejection)
        #expect(!GatewayFailure.unreachable.isRejection && !GatewayFailure.notOwner.isRejection)
        #expect(GatewayFailure.nousCancelled.message.isEmpty)
        #expect(GatewayFailure.forCode("tailscale-off") == .tailscaleOff)
        #expect(ConnectionState.offline(reason: "paused").userMessage == nil)
        #expect(ConnectionState.signedOut(reason: "session-ended").userMessage == GatewayFailure.sessionEnded.message)
        #expect(ConnectionState.ready.userMessage == nil)
    }

    @Test func compatibilityUsesReleaseDateOnly() {
        // [onboarding] `.outdated` now carries what the Update screen shows (Tests/Onboarding/GatewayCompatibilityTests.swift).
        #expect(GatewayCompatibility(status: ["version": "9.9.9", "release_date": "2026.9.20"])
                == .outdated(OutdatedGateway(version: "9.9.9", releaseDate: "2026.9.20", canUpdate: true)))
        #expect(GatewayCompatibility(status: ["release_date": "2026.9.21"]) == .compatible)
        #expect(GatewayCompatibility(status: ["release_date": "2026.10.01"]) == .compatible)
        #expect(GatewayCompatibility(status: ["version": "1.0.0"]) == .unknown)
        #expect(GatewayCompatibility(status: ["release_date": "soon"]) == .unknown)
    }

    @Test func probeWays() {
        #expect(ProbeResult.unknown.ways == .both)
        #expect(ProbeResult(known: true, nous: true, password: false).ways == .nous)
        #expect(ProbeResult(known: true, nous: false, password: true).ways == .password)
        #expect(ProbeResult(known: true, nous: true, password: true).ways == .both)
        #expect(ProbeResult(known: true, nous: false, password: false).ways == .both)
        #expect(GatewayAddress.looksProbeable("studio.tail1.ts.net") && !GatewayAddress.looksProbeable("studio"))
    }
}

// MARK: - Pools [stale-pool]

@Suite struct TransportFlushTests {
    /// Dropping the idle connections keeps the account's cookie jar (the password session); after invalidation it is
    /// a no-op and requests still refuse.
    @Test func flushKeepsTheJarAndIsSafeAfterInvalidation() async throws {
        let transport = HTTPTransport()
        let url = URL(string: "http://127.0.0.1:9/api/x")!
        transport.installCookies([SavedCookie(name: "hermes_session_rt", value: "keep-me", domain: "127.0.0.1")])
        let before = transport.cookies(for: url)
        #expect(before.map(\.value) == ["keep-me"])
        transport.flushConnections()
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.cookies(for: url).map(\.value) == ["keep-me"])
        transport.invalidate()
        transport.flushConnections()
        await #expect(throws: GatewayFailure.connectionChanged) {
            _ = try await transport.data(for: URLRequest(url: url), pool: .bulk, ceiling: 1024)
        }
    }
}
