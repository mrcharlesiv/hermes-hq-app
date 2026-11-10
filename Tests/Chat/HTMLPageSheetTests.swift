import Foundation
import UIKit
import Testing
@testable import HermesHQNative

// Owner, 2026-10-31: a bot's ::preview page opens live, and its buttons message the bot (the desktop's talk-back).
@Suite("HTML page sheet") @MainActor
struct HTMLPageSheetTests {
    /// The page in a window on the app's screen: it loads only once it appears (it takes the app's look first), and a
    /// window with no scene never appears.
    private func open(_ html: String, sent: @escaping (String) -> Void) throws -> (page: HTMLPageSheet, window: UIWindow) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page-\(UUID().uuidString).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        let source = HTMLPageSheet.Source(path: "/tmp/page.html", context: MediaContext(accountId: "t", profile: "default"),
                                          send: sent, botName: "Otto")
        let page = HTMLPageSheet(file: url, source: source)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = page
        window.isHidden = false
        return (page, window)
    }

    @Test func aPageSendReachesTheBotHidden() async throws {
        var prompts: [String] = []
        let html = """
        <html><body><button id=b data-hermes-send="Show only Facebook">F</button>
        <script>window.addEventListener('load',function(){setTimeout(function(){document.getElementById('b').click();
        setTimeout(function(){window.hermes.send('x'.repeat(600)).then(function(r){document.title=r.error||'ok'})},1300)},100)})</script></body></html>
        """
        let shown = try open(html) { prompts.append($0) }
        defer { shown.window.isHidden = true }
        for _ in 0..<60 where prompts.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(prompts == ["Show only Facebook"])
        try await Task.sleep(for: .seconds(2))
        #expect(prompts.count == 1, "a 600-character prompt is refused, not cut")
        _ = shown.page
    }

    @Test func pagesAreHTMLByName() {
        #expect(HTMLPageSheet.opens(name: "chart.html") && HTMLPageSheet.opens(name: "A.HTM"))
        #expect(!HTMLPageSheet.opens(name: "notes.md"))
    }

    @Test func aLonePageInASettledReplyIsAPageCard() {
        let style = ChatStyleCache.shared.style(for: .large)
        let blocks = MarkdownRenderer.render("Here.\n\n::preview{file=\"/a/chart.html\"}\n\nDone.", style: style, linkChips: true).blocks
        let cards = blocks.compactMap { if case .pageCard(let r) = $0 { return r } else { return nil } }
        #expect(cards.count == 1 && cards.first?.attachment.gatewayPath == "/a/chart.html")
        // While it streams (no chips) it is the file's row; another file is never a page card.
        let streaming = MarkdownRenderer.render("::preview{file=\"/a/chart.html\"}", style: style).blocks
        #expect(!streaming.contains { if case .pageCard = $0 { return true } else { return false } })
        let pdf = MarkdownRenderer.render("MEDIA:/a/report.pdf", style: style, linkChips: true).blocks
        #expect(!pdf.contains { if case .pageCard = $0 { return true } else { return false } })
    }
}
