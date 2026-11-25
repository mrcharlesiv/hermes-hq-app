// [preview-tab] Collaborative In-App Browser tests (App/Browser/PreviewTab.swift, PreviewActEngine.swift):
// target parsing (including loopback policy), address bar normalization, windowed read answers, and live WKWebView
// `preview.act` execution (elements, click, type, delta, pin/unpin).

import Foundation
import Testing
import WebKit
@testable import HermesHQNative

@MainActor
struct PreviewTabTests {
    @Test func targets() {
        #expect(PreviewTarget("www.cnn.com") == .page(URL(string: "https://www.cnn.com")!))
        #expect(PreviewTarget("https://example.com/a?b=1") == .page(URL(string: "https://example.com/a?b=1")!))
        #expect(PreviewTarget(" `https://example.com` ") == .page(URL(string: "https://example.com")!))
        #expect(PreviewTarget("/Users/bot/report.html") == .file("/Users/bot/report.html"))
        #expect(PreviewTarget("~/notes.md") == .file("~/notes.md"))
        #expect(PreviewTarget("file:///tmp/a.html") == .file("/tmp/a.html"))
        // The bot's own computer: not reachable from the phone.
        #expect(PreviewTarget("localhost:3000") == .unreachable("localhost:3000"))
        #expect(PreviewTarget("http://127.0.0.1:8080/x") == .unreachable("http://127.0.0.1:8080/x"))
        #expect(PreviewTarget("http://app.localhost:5173") == .unreachable("http://app.localhost:5173"))
        #expect(PreviewTarget("ftp://example.com") == .unreachable("ftp://example.com"))
        // On a local Mac gateway, loopback targets are reachable.
        #expect(PreviewTarget("localhost:3000", allowLoopback: true) == .page(URL(string: "http://localhost:3000")!))
        #expect(PreviewTarget("http://127.0.0.1:8080/x", allowLoopback: true) == .page(URL(string: "http://127.0.0.1:8080/x")!))
    }

    @Test func addressBarNormalization() {
        #expect(PreviewActEngine.normalizeAddress("example.com", allowLoopback: false) == URL(string: "https://example.com"))
        #expect(PreviewActEngine.normalizeAddress("https://example.com/path", allowLoopback: false) == URL(string: "https://example.com/path"))
        #expect(PreviewActEngine.normalizeAddress("localhost:5173", allowLoopback: true) == URL(string: "http://localhost:5173"))
        #expect(PreviewActEngine.normalizeAddress("localhost:5173", allowLoopback: false) == nil)
        #expect(PreviewActEngine.normalizeAddress("javascript:alert(1)", allowLoopback: true) == nil)
        #expect(PreviewActEngine.normalizeAddress("data:text/html,hi", allowLoopback: true) == nil)
        #expect(PreviewActEngine.normalizeAddress("swift webview guide", allowLoopback: false)?.host == "www.google.com")
        #expect(PreviewActEngine.normalizeAddress("   ", allowLoopback: true) == nil)
    }

    @Test func readAnswerIsDesktopsShapeAndWindowed() throws {
        let page = PreviewTabController.Page(url: "https://example.com/", title: "Example", text: "abcdefghij")
        let whole = try decode(PreviewTabCenter.answer(page, start: nil, count: nil))
        #expect(whole["kind"] as? String == "url")
        #expect(whole["url"] as? String == "https://example.com/")
        #expect(whole["title"] as? String == "Example")
        #expect(whole["text"] as? String == "abcdefghij")
        #expect(whole["start"] as? Int == 0 && whole["end"] as? Int == 10 && whole["total_chars"] as? Int == 10)

        let part = try decode(PreviewTabCenter.answer(page, start: 3, count: 4))
        #expect(part["text"] as? String == "defg" && part["start"] as? Int == 3 && part["end"] as? Int == 7)
        // Past the end: empty, at the end.
        let past = try decode(PreviewTabCenter.answer(page, start: 50, count: 4))
        #expect(past["text"] as? String == "" && past["start"] as? Int == 10)
        // Never more than the cap in one read.
        let long = PreviewTabController.Page(url: "u", title: "t", text: String(repeating: "x", count: 30_000))
        let capped = try decode(PreviewTabCenter.answer(long, start: 0, count: 100_000))
        #expect((capped["text"] as? String)?.count == PreviewTabCenter.maxChars)
    }

    @Test func actEngineInventoriesTypesAndClicksInWebView() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let html = """
        <!doctype html><html><head><title>Demo</title></head><body>
          <input id="email" type="email" placeholder="Email address" style="display:block;width:240px;height:32px;margin:16px;" />
          <button id="go" style="display:block;width:120px;height:36px;margin:16px;"
            onclick="document.getElementById('status').textContent='Signed in: ' + document.getElementById('email').value">Sign In</button>
          <div id="status">Idle</div>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://example.com/")!)
        try await waitForLoad(web)

        // 1. elements
        let invRaw = try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "elements"]],
            in: nil, contentWorld: .defaultClient) as? String)
        let inv = try decode(invRaw)
        #expect(inv["success"] as? Bool == true)
        let elements = try #require(inv["elements"] as? [[String: Any]])
        let emailRef = try #require(elements.first { ($0["role"] as? String) == "input:email" }?["ref"] as? String)
        let buttonRef = try #require(elements.first { ($0["role"] as? String) == "button" }?["ref"] as? String)
        #expect(emailRef.hasPrefix("inp-"))
        #expect(buttonRef.hasPrefix("btn-"))

        // 2. type into input
        let typeRaw = try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "type", "ref": emailRef, "text": "me@example.com"]],
            in: nil, contentWorld: .defaultClient) as? String)
        let typed = try decode(typeRaw)
        #expect(typed["success"] as? Bool == true)

        // 3. click button and verify DOM updated
        let clickRaw = try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "click", "ref": buttonRef]],
            in: nil, contentWorld: .defaultClient) as? String)
        let clicked = try decode(clickRaw)
        #expect(clicked["success"] as? Bool == true)

        let status = try await web.evaluateJavaScript("document.getElementById('status').textContent") as? String
        #expect(status == "Signed in: me@example.com")

        // 4. pin and unpin annotation
        let pinRaw = try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "pin", "ref": buttonRef, "text": "Primary CTA"]],
            in: nil, contentWorld: .defaultClient) as? String)
        #expect(try decode(pinRaw)["success"] as? Bool == true)

        let unpinRaw = try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "unpin"]],
            in: nil, contentWorld: .defaultClient) as? String)
        #expect(try decode(unpinRaw)["success"] as? Bool == true)
    }

    @Test func vaultOriginAndStrictMatching() {
        #expect(PreviewVaultOrigin.origin(of: "https://Example.com:443/login?next=/") == "https://example.com")
        #expect(PreviewVaultOrigin.origin(of: "http://localhost:3000/app") == "http://localhost:3000")
        #expect(PreviewVaultOrigin.origin(of: "http://example.com:80/x") == "http://example.com")
        #expect(PreviewVaultOrigin.origin(of: "file:///tmp/a.html") == nil)
        #expect(PreviewVaultOrigin.origin(of: "about:blank") == nil)

        let items = [
            PreviewVaultLogin(id: "1", label: "Acme (1P)", identifier: "me@example.com",
                              origin: "https://dashboard.example.com", backend: "1password"),
            PreviewVaultLogin(id: "2", label: "Parent domain", identifier: "other@example.com",
                              origin: "https://example.com", backend: "1password"),
            PreviewVaultLogin(id: "3", label: "Alt origin", identifier: "alt@example.com",
                              origin: "https://login.example.com",
                              allowedOrigins: ["https://dashboard.example.com"], backend: "vault"),
            PreviewVaultLogin(id: "4", kind: "payment", label: "Card",
                              origin: "https://dashboard.example.com", backend: "vault"),
        ]
        let matched = PreviewVaultLogin.matching(items, origin: "https://dashboard.example.com")
        #expect(matched.map(\.id) == ["1", "3"])
        #expect(matched.first?.backendDisplayName == "1Password")
    }

    @Test func vaultBindingsPinDocumentAndInvalidateOnNavigation() async {
        final class StubDoc: PreviewVaultDocument {
            var documentGeneration = 1
            var isLiveForVault = true
            var shouldThrow = false
            func evaluateVaultExpression(_ expression: String) async throws -> Any? {
                if shouldThrow { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret=top-secret"]) }
                return ["filled": 2]
            }
        }

        let bindings = PreviewVaultBindings()
        let doc = StubDoc()
        let target = bindings.openUserBinding(document: doc)
        #expect(target != nil)

        // Unknown target declines (nil -> 4404 so another window can answer).
        let declined = await bindings.handleAct(sessionId: "", params: .object([
            "action": .string("vault"),
            "vault": .object(["operation": .string("evaluate"), "target": .string("unknown"), "expression": .string("1")]),
        ]), activeDocument: doc)
        #expect(declined == nil)

        // User binding refuses a non-empty session id (declines).
        let wrongScope = await bindings.handleAct(sessionId: "sess-1", params: .object([
            "action": .string("vault"),
            "vault": .object(["operation": .string("evaluate"), "target": .string(target!), "expression": .string("1")]),
        ]), activeDocument: doc)
        #expect(wrongScope == nil)

        // Valid session-less evaluate succeeds.
        let ok = await bindings.handleAct(sessionId: "", params: .object([
            "action": .string("vault"),
            "vault": .object(["operation": .string("evaluate"), "target": .string(target!), "expression": .string("1")]),
        ]), activeDocument: doc)
        #expect(ok?.contains(#""success":true"#) == true)

        // Errors never echo secret text.
        doc.shouldThrow = true
        let failed = await bindings.handleAct(sessionId: "", params: .object([
            "action": .string("vault"),
            "vault": .object(["operation": .string("evaluate"), "target": .string(target!), "expression": .string("secret")]),
        ]), activeDocument: doc)
        #expect(failed?.contains("top-secret") == false)
        #expect(failed?.contains(PreviewVaultBindings.pageFailedError) == true)

        // Navigation increments documentGeneration and invalidates the binding.
        doc.shouldThrow = false
        doc.documentGeneration += 1
        let stale = await bindings.handleAct(sessionId: "", params: .object([
            "action": .string("vault"),
            "vault": .object(["operation": .string("evaluate"), "target": .string(target!), "expression": .string("1")]),
        ]), activeDocument: doc)
        #expect(stale?.contains(PreviewVaultBindings.changedError) == true)

        // Close releases binding.
        let closed = await bindings.handleAct(sessionId: "", params: .object([
            "action": .string("vault"),
            "vault": .object(["operation": .string("close"), "target": .string(target!)]),
        ]), activeDocument: doc)
        #expect(closed?.contains(#""success":true"#) == true)
    }

    @Test func vaultBindingsAgentScopeAndLiveWebViewUndefinedEval() async throws {
        // 1. Live WKWebView evaluation: undefined, primitives, objects, and Promises must never throw WKError 5.
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        web.loadHTMLString("<!doctype html><html><body><input id='u' value='' /></body></html>",
                           baseURL: URL(string: "https://example.com/")!)
        try await waitForLoad(web)

        let undef = try await PreviewTabController.BrowserTab.evaluateVaultExpression("(() => { document.getElementById('u').value = 'alice'; })()", in: web)
        #expect(undef == nil)
        let readBack = try await PreviewTabController.BrowserTab.evaluateVaultExpression("document.getElementById('u').value", in: web) as? String
        #expect(readBack == "alice")
        let asyncVal = try await PreviewTabController.BrowserTab.evaluateVaultExpression("Promise.resolve({ ok: true, count: 2 })", in: web) as? [String: Any]
        #expect(asyncVal?["ok"] as? Bool == true && asyncVal?["count"] as? Int == 2)

        // 2. Agent binding: open → evaluate → active tab switch invalidates → expiry prunes.
        final class StubDoc: PreviewVaultDocument {
            var documentGeneration = 1
            var isLiveForVault = true
            func evaluateVaultExpression(_ expression: String) async throws -> Any? { "ok" }
        }
        var clock = Date(timeIntervalSince1970: 1_000)
        let bindings = PreviewVaultBindings()
        bindings.now = { clock }
        let tabA = StubDoc()
        let tabB = StubDoc()

        let openRaw = try #require(await bindings.handleAct(sessionId: "sess-a", params: .object([
            "action": .string("vault"), "vault": .object(["operation": .string("open")]),
        ]), activeDocument: tabA))
        let opened = try decode(openRaw)
        #expect(opened["success"] as? Bool == true)
        let target = try #require(opened["target"] as? String)

        // Switching the active tab away from tabA invalidates the agent binding.
        let switched = await bindings.handleAct(sessionId: "sess-a", params: .object([
            "action": .string("vault"),
            "vault": .object(["operation": .string("evaluate"), "target": .string(target), "expression": .string("1")]),
        ]), activeDocument: tabB)
        #expect(switched?.contains(PreviewVaultBindings.changedError) == true)

        // Advancing past TTL declines cleanly.
        clock = clock.addingTimeInterval(PreviewVaultBindings.agentTTL + 5)
        let expired = await bindings.handleAct(sessionId: "sess-a", params: .object([
            "action": .string("vault"),
            "vault": .object(["operation": .string("evaluate"), "target": .string(target), "expression": .string("1")]),
        ]), activeDocument: tabA)
        #expect(expired == nil)
    }

    @Test func actEngineDeltaPressGuardAndNullScrollAmount() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let html = """
        <!doctype html><html><head><title>Delta Demo</title></head><body style="height:2000px;">
          <button id="a" style="display:block;width:120px;height:36px;margin:16px;">First</button>
          <button id="b" style="display:block;width:120px;height:36px;margin:16px;">Second</button>
          <button id="c" style="display:block;width:120px;height:36px;margin:16px;">Third</button>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://example.com/")!)
        try await waitForLoad(web)

        // First call returns full inventory; second call with no changes returns compact delta.
        let first = try decode(try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "elements"]],
            in: nil, contentWorld: .defaultClient) as? String))
        #expect((first["elements"] as? [[String: Any]])?.count == 3)

        let second = try decode(try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "elements"]],
            in: nil, contentWorld: .defaultClient) as? String))
        let delta = try #require(second["delta"] as? [String: Any])
        #expect(delta["same"] as? Int == 3)

        // Printable key on body is refused unless allow_shortcut is true.
        let refused = try decode(try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "press", "selector": "body", "key": "k"]],
            in: nil, contentWorld: .defaultClient) as? String))
        #expect(refused["success"] as? Bool == false)

        let allowed = try decode(try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "press", "selector": "body", "key": "k", "allow_shortcut": true]],
            in: nil, contentWorld: .defaultClient) as? String))
        #expect(allowed["success"] as? Bool == true)

        // Scroll with NSNull amount scrolls by default page height (not 0).
        let scrolled = try decode(try #require(try await web.callAsyncJavaScript(
            PreviewActEngine.actScript, arguments: ["payload": ["action": "scroll", "amount": NSNull()]],
            in: nil, contentWorld: .defaultClient) as? String))
        #expect(scrolled["success"] as? Bool == true)
        let scrollY = try await web.evaluateJavaScript("window.scrollY") as? Double ?? 0
        #expect(scrollY > 0)
    }

    private func waitForLoad(_ web: WKWebView) async throws {
        for _ in 0..<50 {
            if !web.isLoading, let ready = try? await web.evaluateJavaScript("document.readyState") as? String,
               ready == "complete" || ready == "interactive" {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
