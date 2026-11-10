import Foundation
import Testing
import UIKit
@testable import HermesHQNative

// The chat screen's render-path budget: cache trims, streaming versions, the first screen, lazy VoiceOver labels.

@Suite struct ChatCacheTrimTests {
    @Test func trimKeepsTheMostRecentlyUsedHalf() {
        let cache = ChatCache<Int, String>(limit: 10)
        for i in 0..<10 { cache.set(i, "v\(i)") }
        #expect(cache.value(0) == "v0")            // touched: now among the most recent
        cache.set(10, "v10")                      // over the limit: keeps 5
        #expect(cache.count == 5)
        #expect(cache.value(0) == "v0")
        #expect(cache.value(10) == "v10")
        #expect(cache.value(1) == nil && cache.value(5) == nil)
        cache.remove(10)
        #expect(cache.value(10) == nil && cache.count == 4)
        cache.trim(to: 0)
        #expect(cache.count == 0)
        cache.set(1, "a")
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func concurrentUseDoesNotCrash() {
        let cache = ChatCache<Int, NSString>(limit: 200)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<2_000 {
                cache.set(worker * 10_000 + i, "\(i)" as NSString)
                _ = cache.value(worker * 10_000 + i / 2)
                if i % 500 == 0 { cache.trim(to: 50) }
            }
        }
        #expect(cache.count <= 200)
    }
}

@MainActor
@Suite(.serialized) struct ChatRenderPerfTests {   // one shared draw pool: a trim mid-test would evict another's pieces
    let style = ChatStyle.make(category: .large)
    let now = Date(timeIntervalSince1970: 1_790_100_000)

    private func bubble(_ text: String, id: String, scope: String, streaming: Bool) -> ChatRow {
        var m = ChatMessage(id: id, role: .assistant, parts: [.text(text)], timestamp: now, rowId: nil)
        m.isStreaming = streaming
        let rows = ChatRowBuilder.build(.init(messages: [m], isRunning: streaming, botName: "Ivy", expanded: [], now: now, scope: scope))
        return rows.first { $0.isBubble }!
    }

    private func pieces(_ layout: RowLayout) -> [(NSAttributedString, CGFloat?)] {
        guard case .bubble(let b) = layout.content else { return [] }
        return b.blocks.flatMap { block in block.pieces.map { ($0.text, block.layoutWidth) } }
    }

    // MARK: Streaming versions (finding 8)

    @Test func streamingVersionsLiveInOneSlot() {
        let scope = "slot|\(UUID().uuidString)"
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        var last: RowLayout?
        var lastRow: ChatRow?
        var earlier: [(NSAttributedString, CGFloat?)] = []
        for n in 1...50 {
            let row = bubble(String(words.prefix(n * 60)), id: "s1", scope: scope, streaming: true)
            if let last { earlier += pieces(last) }
            let made = TextLayout.layout(row, width: 402, style: style, keep: true)
            // The version just measured hits until the apply on main asks for it.
            #expect(TextLayout.cached(row, width: 402, style: style) != nil)
            #expect(TextLayout.layout(row, width: 402, style: style, keep: true).key == made.key)
            // Not in the shared caches.
            #expect(TextLayout.layouts.value(made.key!) == nil)
            last = made
            lastRow = row
        }
        let newest = pieces(last!)
        #expect(newest.map(\.0.string).joined().hasSuffix(String(words.prefix(50 * 60)).suffix(20)))
        #expect(newest.allSatisfy { TextKitPool.pooled($0.0, width: $0.1) != nil }, "the newest version stays pooled for drawing")
        #expect(earlier.allSatisfy { TextKitPool.pooled($0.0, width: $0.1) == nil }, "replaced versions leave the draw pool")
        #expect(TextLayout.streamSlots.count <= StreamSlots.limit)
        // The slot hands back only the newest version.
        let older = bubble(String(words.prefix(60)), id: "s1", scope: scope, streaming: true)
        #expect(TextLayout.cached(older, width: 402, style: style) == nil)
        // Settled: cached as usual, and the slot is gone.
        let settled = bubble(String(words.prefix(50 * 60)), id: "s1", scope: scope, streaming: false)
        let done = TextLayout.layout(settled, width: 402, style: style, keep: true)
        #expect(TextLayout.layouts.value(done.key!) != nil)
        #expect(TextLayout.cached(lastRow!, width: 402, style: style) == nil)
        #expect(!pieces(last!).contains { TextKitPool.pooled($0.0, width: $0.1) != nil })
    }

    @Test func abandonedStreamsCannotPileUp() {
        let scope = "slots|\(UUID().uuidString)"
        for i in 0..<(StreamSlots.limit + 10) {
            _ = TextLayout.layout(bubble("Partial reply \(i)", id: "m\(i)", scope: scope, streaming: true), width: 402, style: style, keep: true)
        }
        #expect(TextLayout.streamSlots.count <= StreamSlots.limit)
    }

    // MARK: Background trim (finding 7)

    @Test func backgroundTrimKeepsThreeHundredPoolEntries() {
        for i in 0..<400 {
            TextKitPool.offer(TextKitLayout(NSAttributedString(string: "pool \(i)"), width: 100), width: 100)
        }
        ChatCaches.trimForBackground()
        #expect(TextKitPool.cache.count <= 300)
        #expect(TextKitPool.cache.count >= 200)
    }

    // MARK: First screen (findings 7 and 25)

    private func session(_ texts: [String]) -> SpyChatSession {
        let spy = SpyChatSession()
        spy.messages = texts.enumerated().map { i, text in
            ChatMessage(id: "stored-row-\(i + 1)-assistant", role: .assistant, parts: [.text(text)], timestamp: now, rowId: i + 1)
        }
        return spy
    }

    @Test func aReopenedChatWarmsItsFirstScreenForDrawing() async throws {
        let tag = UUID().uuidString
        let spy = session((0..<20).map { "Reply \($0) \(tag): " + String(repeating: "some words that wrap ", count: 12) })
        _ = ChatViewController(session: spy)                 // measures (and pools) the first screen
        TextKitPool.cache.removeAll()                         // a trim: the layouts stay, the draw pool doesn't
        let chat = ChatViewController(session: spy)          // cache hits: nothing offered by measuring
        let wanted = chat.debugLayouts.flatMap(pieces)
        #expect(!wanted.isEmpty)
        var ready = false
        for _ in 0..<100 where !ready {
            try await Task.sleep(for: .milliseconds(20))
            ready = wanted.allSatisfy { TextKitPool.pooled($0.0, width: $0.1) != nil }
        }
        #expect(ready, "the first screen's text is laid out for drawing off the main thread")
    }

    @Test func aColdChatOfCodeDumpsMeasuresOnlyTheScreen() {
        let tag = UUID().uuidString
        let code = (0..<500).map { "let value\($0) = compute(\($0)) // \(tag)" }.joined(separator: "\n")
        let spy = session((0..<20).map { "Dump \($0)\n\n```swift\n\(code)\n```" })
        let chat = ChatViewController(session: spy)
        let heights = chat.debugLayouts.map(\.height)
        let height = TextLayout.screenHeight
        #expect(!heights.isEmpty)
        #expect(heights.reduce(0, +) >= height || heights.count == chat.debugCounts.built, "the screen is covered")
        #expect(heights.dropLast().reduce(0, +) < height, "nothing uncached past the screen once over budget")
        #expect(heights.count < 12)
        // Small rows never reach the budget: the old rule (1.5 screens and at least 12 rows).
        let small = session((0..<40).map { "Reply \($0) \(tag)" })
        let again = ChatViewController(session: small)
        var expected = 0
        var total: CGFloat = 0
        let all = again.debugCounts.built
        let warm = again.debugLayouts.map(\.height)
        while expected < min(all, warm.count) && (total < height * 1.5 || expected < 12) {
            total += warm[expected]
            expected += 1
        }
        #expect(warm.count == expected)
        #expect(warm.count >= min(12, all))
    }

    // MARK: VoiceOver label (finding 6)

    @Test func theSpokenLabelIsBuiltOnlyWhenAsked() throws {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: nil)
        let first = bubble("Some **bold** words and `code`.", id: "v1", scope: "a11y|\(UUID().uuidString)", streaming: false)
        let layout = TextLayout.layout(first, width: 402, style: style)
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: layout.height)
        let before = ChatBubbleCell.spokenBuilds
        cell.configure(first, layout: layout)
        #expect(ChatBubbleCell.spokenBuilds == before, "configure doesn't build the label")
        let bubble = try #require(cell.contentView.subviews.first)
        let label = bubble.accessibilityLabel
        #expect(label == "Ivy said: Some bold words and code.")
        #expect(ChatBubbleCell.spokenBuilds == before + 1)
        _ = bubble.accessibilityLabel
        #expect(ChatBubbleCell.spokenBuilds == before + 1, "memoized")
        // A reused cell speaks its new row.
        let second = self.bubble("Another reply", id: "v2", scope: "a11y|\(UUID().uuidString)", streaming: false)
        let layout2 = TextLayout.layout(second, width: 402, style: style)
        cell.configure(second, layout: layout2)
        #expect(bubble.accessibilityLabel == "Ivy said: Another reply")
    }

    // MARK: Applying a measured snapshot (finding 1)

    /// The live bubble's text as the table holds it.
    private func liveText(_ chat: ChatViewController) -> String {
        chat.debugLayouts.map { pieces($0).map(\.0.string).joined() }.first { $0.contains("Streaming") } ?? ""
    }

    private func mainHop() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    @Test func aMeasureThatLandsLateStillMovesTheReplyForward() async throws {
        let tag = UUID().uuidString
        let spy = SpyChatSession()
        var reply = ChatMessage(id: "s", role: .assistant, parts: [.text("Streaming \(tag)")], timestamp: now, rowId: nil)
        reply.isStreaming = true
        spy.messages.append(reply)
        spy.isRunning = true
        let chat = ChatViewController(session: spy)
        chat.loadViewIfNeeded()
        func stream(_ end: String) async {
            spy.messages[spy.messages.count - 1].parts = [.text("Streaming \(tag) " + String(repeating: "more words arrive ", count: 120) + end)]
            spy.onChange?(.updated(ids: ["s"]))
            await mainHop()                                    // the flush, and its apply
        }
        let first = chat.debugHoldLayoutQueue()
        await stream("END-ONE")                                // too long to measure here: off to the layout queue
        await stream("END-TWO")                                // a newer delta while that measure waits
        let second = chat.debugHoldLayoutQueue()               // the follow-up measure waits too
        first()
        var text = ""
        for _ in 0..<100 where !text.contains("END-ONE") {
            try await Task.sleep(for: .milliseconds(20))
            text = liveText(chat)
        }
        #expect(text.contains("END-ONE"), "what was measured goes on screen, though the reply has moved on")
        second()
        for _ in 0..<100 where !text.contains("END-TWO") {
            try await Task.sleep(for: .milliseconds(20))
            text = liveText(chat)
        }
        #expect(text.contains("END-TWO"), "then the follow-up catches up with the newest")
    }
}
