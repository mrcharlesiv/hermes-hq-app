// Screen-side regression tests for integration verification round 2: code highlighting, the Copy row under the latest
// reply, the stopped row's Retry, the step sheet's full output, the session subtitle, and the chat sheets' bar.

import Foundation
import Testing
import ObjectiveC
import UIKit
@testable import HermesHQNative

@MainActor
struct VerificationRoundTwoScreenTests {
    let style = ChatStyle.make(category: .large)

    private func input(_ messages: [ChatMessage], running: Bool = false) -> ChatRowBuilder.Input {
        ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Ivy", expanded: [], scope: "test|ivy|s1")
    }

    private func color(_ text: NSAttributedString, at word: String, dark: Bool = false) -> UIColor? {
        let range = (text.string as NSString).range(of: word)
        guard range.location != NSNotFound,
              let c = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor else { return nil }
        return c.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
    }

    private func hex(_ c: UIColor?) -> String {
        guard let c else { return "nil" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    private func codeText(_ r: RenderedMarkdown) -> NSAttributedString? {
        for block in r.blocks { if case .code(_, _, let text, _) = block { return text } }
        return nil
    }

    // MARK: Syntax highlighting (spec 06 §2.6)

    @Test func settledCodeIsHighlightedWithTheGitHubColours() throws {
        let md = "Here:\n\n```python\n# add two\ndef add(a, b):\n    return a + \"x\" + str(42)\n```"
        let plain = try #require(codeText(MarkdownRenderer.render(md, style: style)))
        #expect(hex(color(plain, at: "def")) == "1F2328")                       // streaming: plain foreground
        let lit = try #require(codeText(MarkdownRenderer.render(md, style: style, highlight: true)))
        #expect(hex(color(lit, at: "def")) == "CF222E")                         // keyword
        #expect(hex(color(lit, at: "add(")) == "8250DF")                        // the defined function
        #expect(hex(color(lit, at: "\"x\"")) == "0A3069")                       // string
        #expect(hex(color(lit, at: "# add two")) == "57606A")                   // comment (remapped)
        #expect(hex(color(lit, at: "42")) == "0550AE")                          // number
        #expect(hex(color(lit, at: "def", dark: true)) == "CF6C65")             // dark-dimmed, filtered
        // Same fonts, so the same geometry as the plain card.
        #expect(lit.string == plain.string)
        #expect(lit.attribute(.font, at: 0, effectiveRange: nil) as? UIFont == plain.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    }

    @Test func highlighterCoversTheLabelledLanguages() throws {
        let cases: [(String, String, String, String)] = [
            ("js", "const x = await fetch(url) // go", "const", "CF222E"),
            ("ts", "interface Foo { a: string }", "Foo", "953800"),
            ("swift", "func load() { let n = 3 }", "load", "8250DF"),
            ("go", "package main\nfunc main() {}", "package", "CF222E"),
            ("rust", "fn main() { println!(\"hi\"); }", "println!", "8250DF"),
            ("json", "{\"name\": \"Ivy\", \"n\": 2, \"ok\": true}", "\"name\"", "116329"),
            ("yaml", "name: Ivy\ncount: 3 # three", "name", "116329"),
            ("bash", "git log --oneline | head -3", "git", "8250DF"),
            ("sql", "SELECT id FROM users WHERE n > 2", "SELECT", "CF222E"),
            ("html", "<div class=\"a\">Hi</div>", "div", "116329"),
            ("css", ".card { color: red; }", "color", "0550AE"),
            ("diff", "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new", "+new", "116329"),
        ]
        for (lang, code, word, want) in cases {
            let tokens = try #require(SyntaxHighlighter.tokens(code, language: lang), "\(lang)")
            let text = NSMutableAttributedString(string: code, attributes: [.foregroundColor: UIColor.black])
            SyntaxHighlighter.apply(tokens, to: text)
            #expect(hex(color(text, at: word)) == want, "\(lang): \(word)")
        }
        #expect(SyntaxHighlighter.tokens("plain words", language: "text") == nil)
        #expect(SyntaxHighlighter.tokens("A=1", language: "env") == nil)
        #expect(SyntaxHighlighter.tokens(String(repeating: "x\n", count: 3_001), language: "python") == nil)
    }

    @Test func aStreamingReplyStaysPlainUntilItSettles() {
        var m = ChatMessage(id: "stored-row-9-assistant", role: .assistant, parts: [.text("```swift\nlet a = 1\n```")],
                            timestamp: Date(), rowId: 9)
        m.isStreaming = true
        let streaming = ChatRowBuilder.build(input([m], running: true)).first { $0.isBubble }!
        m.isStreaming = false
        let settled = ChatRowBuilder.build(input([m])).first { $0.isBubble }!
        #expect(streaming.variant != settled.variant)            // a new layout (with colours) once settled
        guard case .bubble(let b) = TextLayout.make(settled, width: 402, style: style).content,
              let code = b.blocks.compactMap({ block -> NSAttributedString? in
                  if case .code(_, _, let t, _) = block.block { return t } else { return nil } }).first
        else { Issue.record("expected a code block"); return }
        #expect(hex(color(code, at: "let")) == "CF222E")
    }

    // MARK: Copy under the latest reply (spec 06 §2.5)

    @Test func noCopyRowUnderTheLatestReply() {
        // [updates] The row is gone (owner, 2026-10-27): Copy is in the reply's hold menu.
        let user = ChatMessage(id: "u1", role: .user, parts: [.text("hi")], timestamp: Date(), rowId: 1)
        let reply = ChatMessage(id: "a1", role: .assistant, parts: [.text("Hello **there**")], timestamp: Date(), rowId: 2)
        #expect(!ChatRowBuilder.build(input([user, reply])).contains { if case .actions = $0.kind { true } else { false } })
    }

    // MARK: Stopped before the reply › Retry (spec 06 §5.6.3)

    @Test func stoppedEarlyRowCarriesARetryCapsuleWithA44PointTarget() {
        let user = ChatMessage(id: "u1", role: .user, parts: [.text("long job")], timestamp: Date(), rowId: 1)
        var marker = ChatMessage(id: "local-stopped-1", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
        marker.interrupted = true
        let rows = ChatRowBuilder.build(input([user, marker]))
        guard let row = rows.first(where: { if case .stoppedEarly = $0.kind { true } else { false } }) else {
            Issue.record("expected the stopped row"); return
        }
        guard case .line(let l) = TextLayout.make(row, width: 402, style: style).content,
              let capsule = l.retryFrame, let tap = l.retryTap else { Issue.record("expected a Retry capsule"); return }
        #expect(capsule.minX > l.frame.minX + l.text.size.width)                // after the words, on the same line
        #expect(abs(capsule.midY - l.frame.midY) < 1)
        #expect(tap.height >= 44 && tap.width >= capsule.width)
    }

    // MARK: Step sheet (spec 06 §3.3)

    @Test func stepSheetShowsTheWholeOutputErrorOutputAndExitCode() {
        let call = ToolCall(id: "t1", name: "terminal", title: "Ran git log", argsText: "{\"command\":\"git log --oneline\"}",
                            summary: "a41f2c9 Export chats", state: .done, durationSeconds: nil)
        var detail = ToolDetail()
        detail.command = "git log --oneline"
        detail.stdout = "a41f2c9 Export chats\nb22e1d0 Fix sync\nc11d0e9 Tidy\nd00c9f8 Start"
        detail.stderr = "warning: shallow"
        detail.exitCode = 0
        let blocks = ChatStepSheet.blocks(call: call, detail: detail)
        #expect(blocks.map(\.label) == ["Command", "Output", "Error output", "Exit code"])
        #expect(blocks[1].text.split(separator: "\n").count == 4)
        let edit = ToolCall(id: "t2", name: "patch", title: "Edited notes.md", argsText: "{\"path\":\"notes.md\"}",
                            summary: "{", state: .done, durationSeconds: nil)
        var editDetail = ToolDetail()
        editDetail.detail = "{\n  \"success\": true\n}"
        editDetail.inlineDiff = "--- a/notes.md\n+++ b/notes.md\n+one line"
        let editBlocks = ChatStepSheet.blocks(call: edit, detail: editDetail)
        #expect(editBlocks.contains { $0.label == "Changes" && $0.text.contains("+one line") })
        #expect(editBlocks.first { $0.label == "Output" }?.text != "{")
    }

    // MARK: Title subtitle (spec 06 §4.1)

    @Test func aSessionNamesItsBotUnderTheTitle() {
        let title = ChatTitleView()
        title.title = "Push the release tag"
        let plain = title.intrinsicContentSize
        title.subtitle = "A long bot name for the session"
        #expect(title.intrinsicContentSize.width >= plain.width)
        #expect(title.intrinsicContentSize.height == 44)
        #expect(title.accessibilityLabel == "Push the release tag, A long bot name for the session")
    }

    // MARK: Sheets match the Account sheet (spec 06 §8.7–8.8)

    @Test func chatSheetsPutTheCloseButtonLeadingOnTheSheetPage() {
        let call = ToolCall(id: "t1", name: "terminal", title: "Ran ls", argsText: nil, summary: "ok", state: .done, durationSeconds: nil)
        let sheet = ChatStepSheet.make(title: "Ran ls", call: call) as! UINavigationController
        let root = sheet.viewControllers[0]
        root.loadViewIfNeeded()
        #expect(root.navigationItem.leftBarButtonItem != nil)
        #expect(root.navigationItem.rightBarButtonItem == nil)
        #expect(sheet.sheetPresentationController?.prefersGrabberVisible == false)
        // [desktoplook] The page is the sheet page: clear on half-height glass (spec 06 §8 rule 0, SheetGlassTests), and
        // off the glass the themed grouped colour, which IS iOS's grouped colour in the standard look
        // (GroupedPageTests.theStandardGroupedPageIsExactlyTheSystems): compared as drawn, in light and dark.
        #expect(root.view.backgroundColor == HQPalette.sheetPage)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let drawn = ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) { root.view.backgroundColor?.resolvedColor(with: traits) }
            #expect(drawn == UIColor.systemGroupedBackground.resolvedColor(with: traits))
        }
    }
}

/// Sign in with Nous loads AuthenticationServices only when its sheet opens (it cost ~1.3 s of every launch linked).
@MainActor
struct WebAuthRuntimeTests {
    @Test func theSheetIsMadeAndStartsThroughTheRuntime() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:9/authorize?state=x"))
        let handler: @convention(block) @Sendable (NSURL?, NSError?) -> Void = { _, _ in }
        let session = try #require(WebAuthRuntime.makeSession(url: url, customScheme: "hermeshq-native", handler: handler))
        #expect(NSStringFromClass(type(of: session)).contains("ASWebAuthenticationSession"))
        // The iOS 27.2 SDK's session does not start without a window on screen to present from (27.0's did).
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let provider = WebAuthAnchorProvider(anchor: window)
        let proto = try #require(objc_getProtocol("ASWebAuthenticationPresentationContextProviding"))
        #expect(class_conformsToProtocol(WebAuthAnchorProvider.self, proto))
        session.setValue(provider, forKey: "presentationContextProvider")
        session.setValue(false, forKey: "prefersEphemeralWebBrowserSession")
        #expect((session.value(forKey: "presentationContextProvider") as AnyObject?) === provider)
        #expect(session.value(forKey: "prefersEphemeralWebBrowserSession") as? Bool == false)
        #expect(WebAuthRuntime.start(session))           // the system consent alert comes up…
        try await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.environment["HQN_SHEET_HOLD_MS"].flatMap(Int.init) ?? 300))
        WebAuthRuntime.cancel(session)                    // …and goes, as the loopback relay closes it
        // The browser wrapper drives the same calls.
        let browser = WebAuthBrowser(anchor: window)
        let opened = browser.open(url, userCancelled: {})
        #expect(opened)
        try await Task.sleep(for: .milliseconds(300))
        browser.close()
    }
}
