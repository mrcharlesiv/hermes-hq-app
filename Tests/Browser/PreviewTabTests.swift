// [preview-tab] A bot's Browser tab (App/Browser/PreviewTab.swift): what `preview.open` names, as this device can show
// it, and the read answer in Hermes Desktop's shape, windowed as Desktop windows it.

import Foundation
import Testing
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

    private func decode(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
