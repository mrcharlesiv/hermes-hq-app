// [genstack] Owner, 2026-10-31: "Now the images aren't showing where I can swipe through them like we had." Once the
// bridged calls paired with their pictures, the app bot's twenty icons drew as twenty cards in a column. Pictures made
// one after another in a reply are one photo stack you swipe through (session 20260101_090000_aa0002, rows 11336-11357).

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Pictures made one after another")
@MainActor
struct GeneratedStackTests {
    private static func call(_ id: String) -> JSONValue {
        let inner = ChatJSON.stringify(["calls": [["name": "image_generate",
                                                   "arguments": ["aspect_ratio": "square", "prompt": .string(id)]]]])
        return ["id": .string(id), "type": "function", "function": ["name": "tool_call", "arguments": .string(inner)]]
    }

    private static func picture(_ id: String, row: Int) -> JSONValue {
        ["role": "tool", "tool_name": "image_generate", "tool_call_id": .string(id), "row_id": .number(Double(row)),
         "content": .string("{\"success\": true, \"image\": \"https://v3b.fal.media/files/\(id).png\", \"modality\": \"text\"}"),
         "timestamp": 1793475096]
    }

    /// Two batches of calls (as stored: each assistant row holds its calls, the pictures follow), then `tail`.
    private func rows(_ first: [String], _ second: [String], between: String = "", tail: [JSONValue] = []) -> [ChatRow] {
        var stored: [JSONValue] = [["role": "user", "content": "Do 20.", "row_id": 1, "timestamp": 1793474859]]
        var row = 2
        stored.append(["role": "assistant", "content": "One brief for each.", "row_id": .number(Double(row)), "timestamp": 1793474895,
                       "tool_calls": .array(first.map(Self.call))])
        for id in first { row += 1; stored.append(Self.picture(id, row: row)) }
        if !second.isEmpty {
            row += 1
            stored.append(["role": "assistant", "content": .string(between), "row_id": .number(Double(row)), "timestamp": 1793475000,
                           "tool_calls": .array(second.map(Self.call))])
            for id in second { row += 1; stored.append(Self.picture(id, row: row)) }
        }
        stored += tail
        let page = Hydration.fold(stored, pageSeq: 1)
        var generated: [String: [String: GeneratedImageInfo]] = [:]
        for (id, meta) in page.meta { for (tid, d) in meta.tools { if let g = d.generatedImage { generated[id, default: [:]][tid] = g } } }
        var input = ChatRowBuilder.Input(messages: page.messages, isRunning: false, botName: "Hermes", expanded: [])
        input.media = ChatMediaSnapshot(attachments: [:], generated: generated, context: MediaContext(accountId: "a", profile: "app"))
        return ChatRowBuilder.build(input)
    }

    private func stacks(_ rows: [ChatRow]) -> [[MediaItem]] {
        rows.compactMap { r in
            if case .bubble(let b) = r.kind, b.media.contains(where: { $0.generated != nil }) { return b.media } else { return nil }
        }
    }

    @Test func twentyPicturesAreOneStack() throws {
        let first = (1...10).map { "p\($0)" }, second = (11...20).map { "p\($0)" }
        let built = rows(first, second)
        let found = stacks(built)
        #expect(found.count == 1)
        let stack = try #require(found.first)
        #expect(stack.count == 20)
        #expect(stack.first?.attachment.source == .remote(URL(string: "https://v3b.fal.media/files/p1.png")!))
        #expect(stack.last?.attachment.source == .remote(URL(string: "https://v3b.fal.media/files/p20.png")!))
        #expect(stack.allSatisfy { $0.attachment.pixelWidth == 1000 && $0.attachment.pixelHeight == 1000 }, "square, as asked")
        #expect(built.contains { $0.id.hasSuffix("|gp1") }, "the stack keeps the first card's place")
    }

    @Test func wordsBetweenStartANewStack() {
        let found = stacks(rows(["a1", "a2"], ["b1", "b2", "b3"], between: "Ten done, ten to go."))
        #expect(found.map(\.count) == [2, 3])
    }

    @Test func oneAloneStaysTheCard() throws {
        let found = stacks(rows(["solo"], []))
        #expect(found.map(\.count) == [1])
        #expect(found.first?.first?.attachment.pixelWidth == nil, "a single card sizes from its aspect, unchanged")
    }

    @Test func wordsAfterThePicturesAreTheirOwnBubble() throws {
        let built = rows(["a1", "a2"], [], tail: [["role": "assistant", "content": "**Pick** your favourites.", "row_id": 50,
                                                   "timestamp": 1793475600]])
        #expect(stacks(built).first?.count == 2)
        let words = built.compactMap { r -> BubbleRow? in
            if case .bubble(let b) = r.kind, b.text.contains("Pick") { return b } else { return nil }
        }
        #expect(words.count == 1)
        #expect(words.first?.media.isEmpty == true && words.first?.markdown == true)
    }

    @Test func aRenderingCardWaitsBesideTheStack() throws {
        let done = ToolCall(id: "d1", name: "image_generate", title: "", argsText: "{\"aspect_ratio\":\"square\"}", summary: nil,
                            state: .done, durationSeconds: nil)
        var done2 = done; done2.id = "d2"
        var live = done; live.id = "live"; live.state = .running
        var m = ChatMessage(id: "local-a", role: .assistant, parts: [.tool(done), .tool(done2), .tool(live)], timestamp: Date(), rowId: nil)
        m.isStreaming = true
        let info = GeneratedImageInfo(source: "https://v3b.fal.media/x.png", pixelWidth: nil, pixelHeight: nil, aspect: .square, success: true)
        var input = ChatRowBuilder.Input(messages: [m], isRunning: true, botName: "Hermes", expanded: [])
        input.media = ChatMediaSnapshot(attachments: [:], generated: ["local-a": ["d1": info, "d2": info]],
                                        context: MediaContext(accountId: "a", profile: "app"))
        let found = stacks(ChatRowBuilder.build(input))
        #expect(found.map(\.count) == [2, 1])
        #expect(found.last?.first?.rendering == true)
    }
}
