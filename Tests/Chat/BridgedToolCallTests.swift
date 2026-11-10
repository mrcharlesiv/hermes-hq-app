// [bridge] Owner, 2026-10-31: "My Hermes HQ bot has a response. But when I click it, the response is shown for a brief
// moment, and then it goes away." The app bot made twenty icons through Hermes's deferred-tool bridge: each call was a
// `tool_call` holding one `image_generate`, while the result rows were stored under `image_generate`. The newest page
// held only results, so they drew as picture cards; a second later the older page paired them with their call, named
// "tool_call", and the cards went (session 20260101_090000_aa0002, rows 11335-11360).

import Foundation
import Testing
@testable import HermesHQNative

@Suite("A call made through the deferred-tool bridge")
@MainActor
struct BridgedToolCallTests {
    private static func bridged(_ id: String, prompt: String) -> JSONValue {
        let inner = ChatJSON.stringify(["calls": [["name": "image_generate",
                                                   "arguments": ["aspect_ratio": "square", "prompt": .string(prompt)]]]])
        return ["id": .string(id), "type": "function", "function": ["name": "tool_call", "arguments": .string(inner)]]
    }

    private static func picture(_ id: String, row: Int, url: String) -> JSONValue {
        ["role": "tool", "tool_name": "image_generate", "tool_call_id": .string(id), "row_id": .number(Double(row)),
         "content": .string("{\n  \"success\": true,\n  \"image\": \"\(url)\",\n  \"modality\": \"text\",\n  \"upscaled\": false\n}"),
         "timestamp": 1793475096]
    }

    /// The turn as stored: the prompt, the call row (words + two bridged calls), the two pictures, an empty step.
    private var turn: [JSONValue] {
        [
            ["role": "user", "content": "Have it abandon the feather entirely. Do 20.", "row_id": 11335, "timestamp": 1793474859],
            ["role": "assistant", "content": "I'll give Grok one brief.", "row_id": 11336, "timestamp": 1793474895,
             "tool_calls": [Self.bridged("toolu_A", prompt: "caduceus"), Self.bridged("call_B", prompt: "helmet")]],
            Self.picture("toolu_A", row: 11337, url: "https://v3b.fal.media/files/b/0ab0a021/a.png"),
            Self.picture("call_B", row: 11338, url: "https://v3b.fal.media/files/b/0ab0a021/b.png"),
            ["role": "assistant", "content": "", "row_id": 11339, "timestamp": 1793475523,
             "tool_calls": [["id": "call_C", "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]]],
        ]
    }

    private func pictures(_ page: HydratedPage) -> [String: GeneratedImageInfo] {
        var found: [String: GeneratedImageInfo] = [:]
        for meta in page.meta.values { for (id, d) in meta.tools { if let g = d.generatedImage { found[id] = g } } }
        return found
    }

    private func toolNames(_ page: HydratedPage) -> [String: String] {
        var names: [String: String] = [:]
        for m in page.messages { for case .tool(let c) in m.parts { names[c.id] = c.name } }
        return names
    }

    @Test func picturesStayWhenTheirCallArrives() throws {
        let newestOnly = Hydration.fold(Array(turn.suffix(3)), pageSeq: 1)
        #expect(Set(pictures(newestOnly).keys) == ["toolu_A", "call_B"], "results alone: the cards draw")
        let whole = Hydration.fold(turn, pageSeq: 1)
        #expect(Set(pictures(whole).keys) == ["toolu_A", "call_B"], "joined with their call: the cards stay")
        #expect(pictures(whole)["toolu_A"]?.source == "https://v3b.fal.media/files/b/0ab0a021/a.png")
        let names = toolNames(whole)
        #expect(names["toolu_A"] == "image_generate" && names["call_B"] == "image_generate")
        #expect(names["call_C"] == "terminal")
    }

    @Test func theStepReadsTheInnerCallsArguments() throws {
        let whole = Hydration.fold(turn, pageSeq: 1)
        let call = try #require(whole.messages.flatMap(\.parts).compactMap { p -> ToolCall? in
            if case .tool(let c) = p, c.id == "toolu_A" { return c } else { return nil }
        }.first)
        #expect(call.argsText?.contains("caduceus") == true)
        #expect(call.argsText?.contains("\"calls\"") == false, "the bridge's wrapper isn't what the step shows")
    }

    @Test func aBridgeHoldingSeveralCallsStaysOneStep() {
        let both = ChatJSON.stringify(["calls": [["name": "image_generate", "arguments": ["prompt": "a"]],
                                                 ["name": "image_generate", "arguments": ["prompt": "b"]]]])
        let rows: [JSONValue] = [
            ["role": "user", "content": "go", "row_id": 1, "timestamp": 1793474859],
            ["role": "assistant", "content": "On it.", "row_id": 2, "timestamp": 1793474860,
             "tool_calls": [["id": "multi", "type": "function", "function": ["name": "tool_call", "arguments": .string(both)]]]],
        ]
        #expect(toolNames(Hydration.fold(rows, pageSeq: 1))["multi"] == "tool_call")
    }

    @Test func theLiveStepIsThePictureToo() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 5000] : [:] }
        s.send("go")
        let calls: JSONValue = ["calls": [["name": "image_generate", "arguments": ["aspect_ratio": "square", "prompt": "caduceus"]]]]
        await h.emit([h.event("message.start", seq: 1),
                      h.event("tool.start", ["tool_id": "c1", "name": "tool_call", "args": calls], seq: 2)])
        s.flushChanges()
        var live = try #require(h.assistant)
        #expect(s.metaById[live.id]?.tools["c1"]?.generatedImage != nil, "the running card")
        await h.emit([h.event("tool.complete", ["tool_id": "c1", "name": "tool_call",
                                                "result": ["success": true, "image": "https://v3b.fal.media/x.png"]], seq: 3)])
        s.flushChanges()
        live = try #require(h.assistant)
        let call = live.parts.compactMap { p -> ToolCall? in if case .tool(let c) = p { return c } else { return nil } }.first
        #expect(call?.name == "image_generate")
        #expect(s.metaById[live.id]?.tools["c1"]?.generatedImage?.source == "https://v3b.fal.media/x.png")
    }
}
