import Foundation
import Testing
@testable import HermesHQNative

@Suite("History hydration (spec 03 §6, §8)")
struct HydrationTests {
    private func page(_ name: String) throws -> HydratedPage {
        let rows = try ChatFixtures.json(name)["messages"]?.array ?? []
        return Hydration.fold(rows, pageSeq: 1)
    }

    private func tools(_ m: ChatMessage) -> [ToolCall] {
        m.parts.compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
    }

    @Test func performancePageAlternatesWithStableIds() throws {
        let folded = try page("perf-page-latest-24.json")
        #expect(folded.messages.count == 24)
        #expect(folded.messages.first?.id == "stored-row-1109-user")
        #expect(folded.messages.last?.id == "stored-row-1201-assistant")
        #expect(folded.messages.last?.rowId == 1201)
        for (i, m) in folded.messages.enumerated() {
            #expect(m.role == (i % 2 == 0 ? .user : .assistant))
            #expect(m.plainText.hasPrefix("Synthetic history row"))
            #expect(m.timestamp != nil)
        }
        // Same rows folded again (another page object) produce identical ids: overlapping pages match.
        let again = try page("perf-page-latest-24.json")
        #expect(again.messages.map(\.id) == folded.messages.map(\.id))
    }

    @Test func toolTurnFoldsIntoOneAssistantMessage() throws {
        let folded = try page("perf-page-after-turn.json")
        let last = try #require(folded.messages.last)
        #expect(last.id == "stored-row-1209-assistant")
        #expect(last.role == .assistant)
        let user = folded.messages[folded.messages.count - 2]
        #expect(user.id == "stored-row-1202-user")
        #expect(user.plainText == "Run three steps")
        let calls = tools(last)
        #expect(calls.map(\.id) == ["performance-tool-0", "performance-tool-1", "performance-tool-2"])
        #expect(calls.allSatisfy { $0.state == .done && $0.name == "terminal" })
        #expect(calls.first?.title == "Ran 1 command")          // settled run: counts, no command (§8.3)
        #expect(calls.first?.summary == "synthetic output")
        #expect(calls.first?.argsText?.contains("printf synthetic-step-0") == true)
        guard case .text(let reply)? = last.parts.last else { Issue.record("last part is not text"); return }
        #expect(reply == "Let me run three steps. All done.")
        let meta = try #require(folded.meta[last.id])
        #expect(meta.serverRowSpan == 7)                       // 3 tool-call rows + 3 tool rows + the reply row
        #expect(meta.firstRowId == 1203)
        let detail = try #require(meta.tools["performance-tool-0"])
        #expect(detail.command == "printf synthetic-step-0")
        #expect(detail.exitCode == 0)
        #expect((detail.stdout ?? "").hasPrefix("synthetic output\n"))
    }

    @Test func specWorkedExample() throws {
        // 03 §6.4 rows, verbatim shape.
        let rows: [JSONValue] = [
            ["role": "user", "content": "Run two steps", "row_id": 40, "timestamp": 1790852460],
            ["role": "assistant", "content": "", "row_id": 41, "timestamp": 1790852461,
             "tool_calls": [["id": "performance-tool-0", "type": "function",
                             "function": ["name": "terminal", "arguments": "{\"command\": \"printf synthetic-step-0\", \"timeout\": 5}"]]]],
            ["role": "tool", "content": "{\"stdout\": \"synthetic output\\nsynthetic output\\n\", \"stderr\": \"\", \"exit_code\": 0}",
             "row_id": 42, "timestamp": 1790852461, "tool_call_id": "performance-tool-0"],
            ["role": "assistant", "content": "Synthetic performance reply.", "row_id": 43, "timestamp": 1790852462],
        ]
        let folded = Hydration.fold(rows, pageSeq: 1)
        #expect(folded.messages.map(\.id) == ["stored-row-40-user", "stored-row-43-assistant"])
        let reply = folded.messages[1]
        #expect(reply.rowId == 43)
        #expect(reply.timestamp == Date(timeIntervalSince1970: 1790852461))   // earliest of the row and its parts
        #expect(folded.meta[reply.id]?.serverRowSpan == 3)
        #expect(folded.meta[reply.id]?.durableComplete == true)
        #expect(reply.parts.count == 2)
        if case .text(let t) = reply.parts[1] { #expect(t == "Synthetic performance reply.") } else { Issue.record("expected text") }
    }

    @Test func replayFixtureLiftsImageRefs() throws {
        // 03 §11 F-a.
        let rows: [JSONValue] = [
            ["id": 1, "session_id": "20260101_000000_d15a7c0a", "role": "user", "timestamp": 1767225600.0, "active": 1, "compacted": 0,
             "content": "Do not use any tools. Reply with the single word OK.\n@image:/dispatch-replay-fixture/qa-image.png\n[screenshot]",
             "tool_call_id": nil, "tool_calls": nil, "tool_name": nil, "reasoning": nil, "display_kind": nil, "display_metadata": nil],
            ["id": 2, "session_id": "20260101_000000_d15a7c0a", "role": "assistant", "timestamp": 1767225604.0, "active": 1, "compacted": 0,
             "content": "OK", "finish_reason": "stop", "tool_call_id": nil, "tool_calls": nil, "tool_name": nil, "reasoning": nil,
             "display_kind": nil, "display_metadata": nil],
        ]
        let folded = Hydration.fold(rows, pageSeq: 1)
        #expect(folded.messages.map(\.id) == ["stored-row-1-user", "stored-row-2-assistant"])
        #expect(folded.messages[0].plainText == "Do not use any tools. Reply with the single word OK.")
        #expect(folded.meta["stored-row-1-user"]?.attachmentRefs == ["@image:/dispatch-replay-fixture/qa-image.png"])
        #expect(folded.messages[1].plainText == "OK")
    }

    @Test func plaidPageIsBoundedAndWorded() throws {
        let raw = try ChatFixtures.data("plaid-page-latest-24.json")
        let folded = try page("plaid-page-latest-24.json")
        #expect(!folded.messages.isEmpty)
        #expect(folded.messages.allSatisfy { $0.id.hasPrefix("stored-row-") })
        // Every user row starts a message; assistant turns fold tool rounds.
        let users = folded.messages.filter { $0.role == .user }
        #expect(users.count >= 1)
        for m in folded.messages where m.role == .assistant {
            for call in tools(m) {
                #expect(call.title.count < 120)
                #expect((call.summary ?? "").count <= 160)
                #expect(call.state != .running)
                if call.name == "patch" { #expect(call.title.hasPrefix("Edited ")) }
                if call.name == "terminal" { #expect(call.title.hasPrefix("Ran ")) }
            }
            for detail in (folded.meta[m.id]?.tools ?? [:]).values {
                #expect((detail.stdout ?? "").count <= 8192)
                #expect((detail.detail ?? "").count <= 8192)
            }
        }
        // The folded model is far smaller than the page (tool outputs are not kept whole).
        let modelChars = folded.messages.reduce(0) { sum, m in
            sum + m.parts.reduce(0) { s, p in
                switch p { case .text(let t), .reasoning(let t): return s + t.count; case .tool(let c): return s + c.title.count + (c.summary?.count ?? 0) }
            }
        }
        #expect(modelChars < raw.count)
        // Reasoning rows become reasoning parts.
        let hasReasoning = folded.messages.contains { $0.parts.contains { if case .reasoning = $0 { return true }; return false } }
        let rawHasReasoning = (try ChatFixtures.json("plaid-page-latest-24.json")["messages"]?.array ?? []).contains { $0["reasoning"]?.nonEmptyString != nil }
        #expect(hasReasoning == rawHasReasoning)
    }

    @Test func plaidOlderPageFoldsTurnsWithoutLosingRows() throws {
        let rows = try ChatFixtures.json("plaid-page-older.json")["messages"]?.array ?? []
        let folded = Hydration.fold(rows, pageSeq: 1)
        let span = folded.messages.reduce(0) { $0 + (folded.meta[$1.id]?.serverRowSpan ?? 1) }
        #expect(span == rows.count)       // every backend row is accounted for by exactly one message
        #expect(Set(folded.messages.map(\.id)).count == folded.messages.count)
    }

    @Test func silentToolsDrawOnlyWhenFailed() {
        let rows: [JSONValue] = [
            ["role": "user", "content": "Plan it", "id": 1, "timestamp": 10],
            ["role": "assistant", "content": "", "id": 2, "timestamp": 11,
             "tool_calls": [["id": "t1", "function": ["name": "todo", "arguments": "{\"todos\":[]}"]],
                            ["id": "t2", "function": ["name": "react_to_message", "arguments": "{\"emoji\":\"👍\"}"]],
                            ["id": "t3", "function": ["name": "read_file", "arguments": "{\"path\":\"/x/App.swift\"}"]]]],
            ["role": "tool", "tool_call_id": "t1", "tool_name": "todo", "content": "{\"success\": true}", "id": 3, "timestamp": 12],
            ["role": "tool", "tool_call_id": "t2", "tool_name": "react_to_message", "content": "{\"success\": false, \"error\": \"no message\"}", "id": 4, "timestamp": 12],
            ["role": "tool", "tool_call_id": "t3", "tool_name": "read_file", "content": "{\"content\": \"import UIKit\"}", "id": 5, "timestamp": 12],
            ["role": "assistant", "content": "Done.", "id": 6, "timestamp": 13],
        ]
        let folded = Hydration.fold(rows, pageSeq: 1)
        let reply = folded.messages.last!
        let calls = tools(reply)
        #expect(calls.map(\.id) == ["t2", "t3"])
        #expect(calls[0].state == .failed)
        #expect(calls[0].title == "Used 1 tool, 1 tool call failed")
        #expect(calls[1].title == "Explored App.swift")
        #expect(folded.meta[reply.id]?.serverRowSpan == 5)
    }

    @Test func noticesHiddenRowsAndCleanup() {
        let rows: [JSONValue] = [
            ["role": "user", "content": "[System: hidden scaffolding]", "display_kind": "hidden", "id": 1, "timestamp": 1],
            ["role": "user", "content": "[Background process proc_1 heartbeat #3 still running]", "id": 2, "timestamp": 2],
            ["role": "user", "content": "[System: The active model for this chat has changed to claude-opus-5-5 via provider anthropic. From this point on…]",
             "display_kind": "model_switch", "id": 3, "timestamp": 3],
            ["role": "assistant", "content": "[SILENT]", "id": 4, "timestamp": 4],
            ["role": "user", "content": "Fix it\n--- Attached Context ---\n@file:/repo/a.swift contents…\n", "id": 5, "timestamp": 5],
            ["role": "user", "content": "[IMPORTANT: The user has invoked the \"work\" skill. The full skill content is loaded below.]\nbody…\nThe user has provided the following instruction alongside the skill invocation: fix   the leak\n\n[Runtime note: x]",
             "id": 6, "timestamp": 6],
            ["role": "assistant", "content": "", "display_kind": "failed_turn", "display_content": "Your request was not processed.", "id": 7, "timestamp": 7],
            ["role": "user", "content": [["type": "text", "text": "what is this?"],
                                         ["type": "image_url", "image_url": ["url": .string("data:image/png;base64," + String(repeating: "A", count: 200))]]],
             "id": 8, "timestamp": 8],
        ]
        let folded = Hydration.fold(rows, pageSeq: 1)
        let ids = folded.messages.map(\.id)
        #expect(!ids.contains("stored-row-1-user"))
        #expect(!ids.contains("stored-row-2-user"))
        let model = folded.messages.first { $0.id == "stored-row-3-system" }
        #expect(model?.plainText == "Model changed to Opus 5.5")   // verify round 3: the name, as the toast says it
        #expect(folded.meta["stored-row-3-system"]?.systemNotice == true)
        #expect(folded.messages.first { $0.id == "stored-row-4-system" }?.plainText == Hydration.silentRunText)
        let attached = folded.messages.first { $0.id == "stored-row-5-user" }
        #expect(attached?.plainText == "Fix it")                                   // the ref is lifted out of the text…
        #expect(folded.meta["stored-row-5-user"]?.attachmentRefs == ["@file:/repo/a.swift"])   // …into the attachment refs
        #expect(folded.messages.first { $0.id == "stored-row-6-user" }?.plainText == "/work fix the leak")
        #expect(folded.meta["stored-row-7-system"]?.systemNotice == true)
        let image = folded.messages.first { $0.id == "stored-row-8-user" }
        #expect(image?.plainText == "what is this?")
        #expect(!(image?.plainText.contains("base64") ?? true))
    }

    /// Log study 2026-10-28: the Mac's 1:47 PM sends. The stored row says only "not processed"; its metadata says why.
    @Test func aFailedTurnNoteCarriesItsReason() {
        let notice = "Your request was not processed. Send it again if you still want me to carry it out."
        let surface: JSONValue = ["layer": "provider", "code": "model_entitlement", "retryable": false, "provider": "openai-codex",
                                  "model": "claude-opus-5-5[1m]", "provider_label": "ChatGPT or Codex Subscription"]
        let rows: [JSONValue] = [
            ["role": "user", "content": "look at the spot", "id": 34293, "timestamp": 1],
            ["role": "assistant", "content": .string(notice), "display_kind": "failed_turn", "id": 34294, "timestamp": 2,
             "display_metadata": ["error": "HTTP 400: The 'claude-opus-5-5[1m]' model is not supported when using Codex with a ChatGPT account.",
                                  "error_surface": surface]],
            ["role": "user", "content": "again", "id": 34295, "timestamp": 3],
            ["role": "assistant", "content": .string(notice), "display_kind": "failed_turn", "id": 34296, "timestamp": 4],
        ]
        let folded = Hydration.fold(rows, pageSeq: 1)
        let note = folded.messages.first { $0.id == "stored-row-34294-system" }
        #expect(note?.plainText == "Your request was not processed. ChatGPT or Codex Subscription said: The 'claude-opus-5-5[1m]' model is not supported when using Codex with a ChatGPT account.")
        #expect(folded.messages.first { $0.id == "stored-row-34296-system" }?.plainText == notice)   // no metadata: as stored
        // Beside the live error card it still gives way to the card.
        #expect(TimelineNotes.note(note?.plainText ?? "", errorNearby: true) == .hidden)
        // The partial notice keeps its warning.
        let partial = "This turn did not complete. Some actions may already have run; verify their effects before resending."
        #expect(Hydration.failedTurnWords(partial, metadata: ["error": "Connection reset"]) == partial + " Connection reset")
    }

    @Test func toolTitleWording() {
        typealias Call = ToolPresentation.Call
        func title(_ name: String, _ args: [String: JSONValue], live: Bool, failed: Bool = false) -> String {
            ToolPresentation.title(for: Call(name: name, args: args, pending: live, failed: failed, hasResult: !live), live: live)
        }
        #expect(title("terminal", ["command": "cd ~/x && npm test 2>&1 | tail -20"], live: true) == "Running npm test")
        #expect(title("terminal", ["command": "npm test"], live: false) == "Ran 1 command")
        #expect(title("read_file", ["path": "/Users/a/ios/App.swift"], live: false) == "Explored App.swift")
        #expect(title("patch", ["path": "src/app.py"], live: true) == "Editing app.py")
        #expect(title("web_search", ["query": "swift markdown"], live: false) == "Searched “swift markdown”")
        #expect(title("browser_navigate", ["url": "https://example.com/docs"], live: false) == "Opened example.com/docs")
        #expect(title("browser_click", ["selector": "#a"], live: false) == "Performed 1 browser action")
        #expect(title("mystery", [:], live: false, failed: true) == "Used 1 tool, 1 tool call failed")
        #expect(title("skill_view", ["name": "work"], live: false) == "Loaded skill: work")
        #expect(ToolPresentation.summarizeShellCommand("cd a && make && make install") == "make + 1 command")
        #expect(ToolPresentation.callFailed(isError: false, result: ["success": false]))
        #expect(!ToolPresentation.callFailed(isError: true, result: ["ok": true]))
        #expect(ToolPresentation.callFailed(isError: false, result: ["error": "boom"]))
        #expect(!ToolPresentation.callFailed(isError: false, result: ["stdout": "x", "stderr": "warning", "exit_code": 0]))
    }

    @Test func atTurnCutKeepsTurnsWhole() throws {
        let data = try ChatFixtures.data("plaid-page-latest-24.json")
        var page = try HistoryAPI.decodePage(data, request: HistoryRequest(storedSessionId: "x", profile: "default", limit: 24))
        #expect(page.possiblyTruncated)
        let before = page.rows.count
        let dropped = HistoryAPI.cutAtTurn(&page)
        #expect(dropped == 7)                                    // the page opens mid-turn: 7 assistant/tool rows
        #expect(page.rows.count == before - dropped)
        #expect(page.rows.first?["role"]?.string == "user")
        #expect(page.nextOffset == 17)
        #expect(page.possiblyTruncated)
    }
}

@Suite struct ShortHistoryPageTests {
    private func page(returned: Int, limit: Int = 121) -> HistoryPage {
        HistoryPage(sessionId: "s", profile: nil, rows: [],
                    pagination: HistoryPagination(limit: limit, offset: 0, order: "latest", returned: returned),
                    requestedLimit: limit, requestedOffset: 0, order: "latest")
    }

    /// Hermes counts a page after dropping hidden rows: 121 stored rows came back as 114 for Northwind (2026-10-23).
    @Test func aPageThinnedByHiddenRowsMayHaveMore() {
        #expect(page(returned: 121).possiblyTruncated)
        #expect(page(returned: 114).possiblyTruncated)
        #expect(page(returned: 61).possiblyTruncated)
        #expect(!page(returned: 20).possiblyTruncated, "a short chat is whole")
        #expect(!page(returned: 0).possiblyTruncated)
    }
}

@Suite("History reads (spec 03 §2, §4.2, §7.5)")
struct HistoryReadTests {
    @Test func performancePluginRouteFallsBackOnceToCore() async throws {
        let ready: JSONValue = ["replay_epoch": "x", "performance": ["version": 1, "history_display": 1, "history_cursor": 1,
                                                                    "history_path": "hermes-hq-performance.v1", "history_tool_refs": 1]]
        let features = try #require(PerformanceFeatures(ready: ready))
        #expect(features.routeName == "hermes-hq-performance")
        let request = HistoryRequest(storedSessionId: "20260929_120000_aabbcc01", profile: "default", limit: 24)
        let (path, query) = request.plugin(features)
        #expect(path == "/api/plugins/hermes-hq-performance/sessions/20260929_120000_aabbcc01/messages")
        #expect(query.map(\.name) == ["profile", "limit", "order", "include_compacted", "projection", "max_bytes", "tool_refs"])

        let client = FakeGatewayClient()
        let core = try ChatFixtures.data("perf-page-latest-24.json")
        client.onRest { path, _ in
            if path.hasPrefix("/api/plugins/") { throw HTTPError(status: 404, body: "Not Found") }
            return core
        }
        let (page, usedPlugin) = try await HistoryAPI.fetch(client: client, request: request, features: features)
        #expect(!usedPlugin)
        #expect(page.rows.count == 24)
        #expect(client.restLog.map(\.path) == [path, "/api/sessions/20260929_120000_aabbcc01/messages"])
        #expect(PerformanceFeatures(ready: ["replay_epoch": "x"]) == nil)
        #expect(PerformanceFeatures(ready: ["performance": ["version": 2, "history_display": 1]]) == nil)
    }

    @Test func openWindowPaintsTheNewest24Rows() {
        let messages = (0..<40).map { i in
            ChatMessage(id: "m\(i)", role: i % 2 == 0 ? .user : .assistant, parts: [.text("\(i)")], timestamp: nil, rowId: i + 1)
        }
        var meta: [String: MessageMeta] = [:]
        var big = MessageMeta(); big.serverRowSpan = 7
        meta["m39"] = big
        let window = TranscriptMerge.openWindow(messages, meta: meta)
        #expect(window.last?.id == "m39")
        #expect(window.reduce(0) { $0 + (meta[$1.id]?.serverRowSpan ?? 1) } <= 24)
        #expect(window.first?.role == .user)                       // doesn't start mid-turn
        var huge = MessageMeta(); huge.serverRowSpan = 99
        #expect(TranscriptMerge.openWindow(messages, meta: ["m39": huge]).map(\.id) == ["m39"])
    }

    @Test func finalTextMergeNeverWipesAndReplacesOnlyAfterTheLastTool() {
        let tool = ChatPart.tool(ToolCall(id: "t", name: "terminal", title: "Ran 1 command", argsText: nil, summary: nil, state: .done,
                                          durationSeconds: nil))
        let parts: [ChatPart] = [.text("Let me check. "), tool, .text("Done")]
        #expect(TranscriptMerge.mergeFinalText(parts, "") == parts)
        #expect(TranscriptMerge.mergeFinalText(parts, "Let me check. Done") == parts)
        #expect(TranscriptMerge.mergeFinalText(parts, "Let me check. Done — all green.") ==
                [.text("Let me check. "), tool, .text("Done — all green.")])
        #expect(TranscriptMerge.mergeFinalText([.reasoning("Think"), .text("Hi")], "Think about it: hi") ==
                [.text("Think about it: hi")])
    }

    @Test func changeSetCollapsesMixedStructuralChanges() {
        var c = ChangeSet()
        c.append("a"); c.update("a"); c.update("b")
        #expect(c.emissions().count == 2)
        c.prepend(3)
        #expect(c.emissions().first.map { if case .reset = $0 { return true }; return false } == true)
        var d = ChangeSet()
        d.append("x"); d.remove("x")
        #expect(d.isEmpty)
    }
}

@Suite("Async notices (spec 03 §6.5)")
struct AsyncNoticeTests {
    @Test func backgroundCompletionsBecomeTimelineNotices() {
        let batch = "[ASYNC DELEGATION BATCH COMPLETE — 2 subagents]\n--- ✓ TASK 1/2: Check the build  (status=completed) ---\nBuild is green.\n--- ✗ TASK 2/2: Run tests  (status=failed) ---\nTwo tests failed.\nFull live transcript (complete tool/assistant trace): /tmp/x.json\n"
        let rows: [JSONValue] = [
            ["role": "user", "content": .string(batch), "display_kind": "internal_notification", "id": 9, "timestamp": 1],
            ["role": "user", "content": "[IMPORTANT: Background process proc_7 completed.\nexit 0]", "display_kind": "internal_notification", "id": 10, "timestamp": 2],
        ]
        let folded = Hydration.fold(rows, pageSeq: 1)
        #expect(folded.messages.map(\.id) == ["stored-row-9-system", "stored-row-10-system"])
        #expect(folded.messages[0].plainText == "2 helpers finished")
        #expect(folded.meta["stored-row-9-system"]?.asyncResult == "Build is green.\n\nTwo tests failed.")
        #expect(folded.messages[1].plainText == "Background task finished", "the live note's words")
        #expect(folded.meta["stored-row-10-system"]?.asyncResult == "Background process proc_7 completed.\nexit 0")
        #expect(folded.meta["stored-row-10-system"]?.systemNotice == true)
    }
}
