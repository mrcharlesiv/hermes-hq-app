// Regression tests for the activity stream's review round: hidden goal continuations in the queue, bounded tool
// arguments, store observers across a re-mint, screen visibility, live work by session, the hidden turn's anchor, the
// transcript cache's version, In Header's waiting capsule, the delegate card's live overlay, the action row with a
// fallback notice, the step sheet's server answers, the display-flag cache, spinners and the padded label.

import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Activity · review round", .serialized)
struct ActivityReviewTests {
    func session(_ client: FakeGatewayClient = FakeGatewayClient(), stored: String = "s1") -> LiveChatSession {
        LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: stored, title: "Hermes",
                        head: nil, cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
    }

    func toolCalls(_ m: ChatMessage?) -> [ToolCall] {
        (m?.parts ?? []).compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
    }

    // MARK: Hidden goal continuation in the queue (§6.4)

    @Test func aQueuedGoalContinuationShowsItsDisplayWordsAndNeverFillsTheField() {
        let s = session()
        s.turn.busy = true
        s.enqueueHidden("[Continue working toward the standing goal: Ship 2.4 …internal prompt…]", display: "/goal resume")
        s.enqueueHidden("[Continue working toward the standing goal …]", display: nil)
        let items = s.queuedMessages
        #expect(items.count == 2)
        #expect(ChatQueueCard.rowText(items[0]) == ("/goal resume", true))
        #expect(ChatQueueCard.rowText(items[1]) == ("Continue toward goal", true))
        // Remove from Queue: the internal prompt never comes back for the composer.
        #expect(s.removeQueued(items[0].id) == nil)
        #expect(s.queuedMessages.count == 1)
        // An ordinary queued send still hands its words back.
        let plain = QueuedMessage(id: "q9", text: "hello\nthere")
        #expect(ChatQueueCard.rowText(plain) == ("hello there", false))
    }

    // MARK: Bounded tool arguments (§11.1)

    static let bigFile = String(repeating: "let value = 42 // padding the file\n", count: 300)        // ~10 KB

    @Test func aTenKilobyteWriteFileKeepsItsPathAndStaysValidJSON() throws {
        let args: [String: JSONValue] = ["content": .string(Self.bigFile), "path": "/app/src/app.py"]
        let raw = ChatJSON.stringify(.object(args))
        #expect(raw.utf8.count > 10_000)
        let bounded = try #require(ToolArgs.boundedText(args, raw: raw))
        #expect(bounded.utf8.count <= ToolArgs.maxBytes)
        let parsed = try #require(ChatJSON.parse(string: bounded)?.object)
        #expect(parsed["path"] == "/app/src/app.py")
        #expect(parsed["content"]?.string?.hasSuffix("…") == true)
        let call = ToolCall(id: "w1", name: "write_file", title: "write_file", argsText: bounded, summary: nil, state: .running, durationSeconds: nil)
        #expect(ToolLines.line(call) == ToolLine(emoji: "✍️", text: "Writing app.py"))
    }

    @Test func aSixKilobyteDelegationKeepsItsGoals() throws {
        let context = String(repeating: "Background the child needs. ", count: 110)          // ~3 KB each
        let args: [String: JSONValue] = ["tasks": [["goal": "Read the changelog", "context": .string(context)],
                                                   ["goal": "Check open issues", "context": .string(context)]]]
        let raw = ChatJSON.stringify(.object(args))
        #expect(raw.utf8.count > 6_000)
        let bounded = try #require(ToolArgs.boundedText(args, raw: raw))
        #expect(bounded.utf8.count <= ToolArgs.maxBytes)
        #expect(ToolCards.delegateGoals(.object(ToolArgs.parse(bounded))) == ["Read the changelog", "Check open issues"])
        let call = ToolCall(id: "d1", name: "delegate_task", title: "delegate_task", argsText: bounded, summary: nil, state: .running, durationSeconds: nil)
        #expect(ToolLines.line(call).text == "Delegating 2 tasks")
    }

    @Test func liveAndStoredCallsCarryBoundedArguments() throws {
        // Live: tool.start with a 10 KB write_file.
        let s = session()
        s.dispatch(GatewayEvent(type: "tool.start", sessionId: "r1", seq: nil,
                                payload: ["tool_id": "w1", "name": "write_file", "args": ["path": "/app/notes.md", "content": .string(Self.bigFile)]]))
        let live = try #require(toolCalls(s.messages.last).first)
        #expect(ChatJSON.parse(string: live.argsText ?? "") != nil, "valid JSON")
        #expect(ToolLines.line(live).text == "Writing notes.md")
        // Stored: the same call read from history.
        let arguments = ChatJSON.stringify(.object(["path": "/app/notes.md", "content": .string(Self.bigFile)]))
        let rows: [JSONValue] = [
            ["id": 1, "role": "user", "content": "write it", "timestamp": 1_791_600_000.0],
            ["id": 2, "role": "assistant", "content": "", "timestamp": 1_791_600_001.0,
             "tool_calls": [["id": "w1", "type": "function", "function": ["name": "write_file", "arguments": .string(arguments)]]]],
            ["id": 3, "role": "tool", "tool_call_id": "w1", "tool_name": "write_file", "content": "{\"success\": true}", "timestamp": 1_791_600_002.0],
        ]
        let page = Hydration.fold(rows, pageSeq: 1)
        let stored = try #require(page.messages.flatMap { toolCalls($0) }.first { $0.name == "write_file" })
        #expect((stored.argsText?.utf8.count ?? 0) <= ToolArgs.maxBytes)
        #expect(ToolLines.line(stored).text == "Writing notes.md")
    }

    // [perf] The live tool path serializes a big call once, with long strings clipped first: same text as before.

    @Test func theInputPrefixMatchesTheFullJSONsFirstFourKilobytes() {
        let items: [JSONValue] = (0..<40).map { .string("item \($0)") }
        let args: [String: JSONValue] = ["content": .string(String(repeating: "é and a quote \" ", count: 20_000)),
                                         "path": .string("/very/long/" + String(repeating: "dir/", count: 300) + "file.txt"),
                                         "list": .array(items)]
        let input = ToolArgs.inputText(args)
        #expect(input.prefix == ChatText.clip(ChatJSON.stringify(.object(args)), max: 4096))
        #expect(!input.isFull)
        let small: [String: JSONValue] = ["path": "/a.txt", "content": "hi", "n": 3]
        let full = ChatJSON.stringify(.object(small))
        #expect(ToolArgs.inputText(small).prefix == full)
        #expect(ToolArgs.inputText(small).isFull)
        #expect(ToolArgs.boundedText(small, input: ToolArgs.inputText(small)) == full)
    }

    @Test func boundedTextIsUnchangedByThePrefixPath() throws {
        let context = String(repeating: "Background the child needs. ", count: 110)
        let fixtures: [[String: JSONValue]] = [
            ["content": .string(Self.bigFile), "path": "/app/src/app.py"],
            ["tasks": [["goal": "Read the changelog", "context": .string(context)], ["goal": "Check open issues", "context": .string(context)]]],
            ["content": .string(String(repeating: "x", count: 500_000)), "path": "/big.bin"],
        ]
        for args in fixtures {
            let old = ToolArgs.boundedText(args, raw: ChatJSON.stringify(.object(args)))
            #expect(ToolArgs.boundedText(args, input: ToolArgs.inputText(args)) == old)
        }
    }

    @Test func aHalfMegabyteLiveWriteKeepsItsInputPrefixAndPath() throws {
        let s = session()
        let content = String(repeating: "0123456789abcdef", count: 32_000)                  // 512 KB
        let args: [String: JSONValue] = ["path": "/app/huge.txt", "content": .string(content)]
        s.dispatch(GatewayEvent(type: "tool.start", sessionId: "r1", seq: nil,
                                payload: ["tool_id": "w9", "name": "write_file", "args": .object(args)]))
        let expected = ChatText.clip(ChatJSON.stringify(.object(args)), max: 4096)
        let sid = try #require(s.messages.last?.id)
        #expect(s.metaById[sid]?.tools["w9"]?.input == expected)
        s.dispatch(GatewayEvent(type: "tool.complete", sessionId: "r1", seq: nil,
                                payload: ["tool_id": "w9", "name": "write_file", "args": .object(args), "result": ["success": true]]))
        #expect(s.metaById[sid]?.tools["w9"]?.input == expected)
        let call = try #require(toolCalls(s.messages.last).first)
        #expect(ChatJSON.parse(string: call.argsText ?? "")?.object?["path"] == "/app/huge.txt")
        #expect((call.argsText?.utf8.count ?? 0) <= ToolArgs.maxBytes)
    }

    @Test func textCutShortIsReadByTheTolerantScan() {
        func call(_ name: String, _ text: String) -> ToolCall {
            ToolCall(id: "c", name: name, title: name, argsText: text, summary: nil, state: .done, durationSeconds: nil)
        }
        #expect(ToolLines.line(call("write_file", #"{"path":"/a/b/app.py","content":"print(1)\nprint(2"#)).text == "Writing app.py")
        #expect(ToolLines.line(call("terminal", #"{"command":"npm run build && npm te"#)).code == "npm run build && npm te")
        let goals = ToolCards.delegateGoals(.object(ToolArgs.parse(#"{"tasks":[{"goal":"A","context":"long"},{"goal":"B","cont"#)))
        #expect(goals == ["A", "B"])
        // The web's case stays: a key cut before its value gives nothing.
        #expect(ToolLines.line("terminal", args: .string(#"{"comm"#)) == ToolLine(emoji: "💻", text: "Running"))
    }

    // MARK: Store: observers across a re-mint, visibility, live work by session

    @Test func aRemintedChatHearsEachChangeOnce() {
        let client = FakeGatewayClient()
        let store = ActivityStore(client: client, frameMode: .manual)
        var calls = 0
        store.bind(runtimeId: "rid00001", profile: "default", storedId: "s1")
        var first: ActivityObservation? = store.observe("rid00001") { calls += 1 }
        store.bind(runtimeId: "rid00002", profile: "default", storedId: "s1")
        let second = store.observe("rid00002") { calls += 1 }
        first = nil
        _ = first
        store.flush()
        calls = 0
        store.handle(GatewayEvent(type: "subagent.start", sessionId: "rid00002", seq: nil,
                                  payload: ["goal": "g", "task_count": 1, "task_index": 0, "subagent_id": "a", "status": "running"]))
        store.flush()
        #expect(calls == 1)
        _ = second
    }

    @Test func leavingAChatNeverClearsTheChatThatTookTheScreen() {
        let client = FakeGatewayClient()
        let store = ActivityStore(client: client, frameMode: .manual)
        let a = session(client, stored: "sa"), b = session(client, stored: "sb")
        a.activityLink.store = store
        b.activityLink.store = store
        a.activityBound(["session_id": "aaaa0001"], runtimeId: "aaaa0001")
        b.activityBound(["session_id": "bbbb0002"], runtimeId: "bbbb0002")
        a.setActivityVisible(true, openSubagent: nil)
        b.setActivityVisible(true, openSubagent: nil)        // B was pushed over A
        a.setActivityVisible(false, openSubagent: nil)       // A leaves afterwards
        #expect(store.visibleRuntimeId == "bbbb0002")
        b.setActivityVisible(false, openSubagent: nil)
        #expect(store.visibleRuntimeId == nil)
    }

    @Test func liveWorkIsKeptPerSession() {
        let client = FakeGatewayClient()
        let store = ActivityStore(client: client, frameMode: .manual)
        var changes: [String] = []
        store.onLiveWorkChange = { changes.append($0) }
        store.bind(runtimeId: "aaaa0001", profile: "default", storedId: "s1")
        store.bind(runtimeId: "bbbb0002", profile: "default", storedId: "s2")
        store.handle(GatewayEvent(type: "subagent.start", sessionId: "aaaa0001", seq: nil,
                                  payload: ["goal": "g", "task_count": 1, "task_index": 0, "subagent_id": "a", "status": "running"]))
        #expect(store.hasLiveWork(storedId: "s1") && !store.hasLiveWork(storedId: "s2"))
        changes = []
        // A second chat of the same bot gets a child: the bot already works, its session row still changes.
        store.handle(GatewayEvent(type: "subagent.start", sessionId: "bbbb0002", seq: nil,
                                  payload: ["goal": "h", "task_count": 1, "task_index": 0, "subagent_id": "b", "status": "running"]))
        #expect(store.liveWorkStoredIds == ["s1", "s2"])
        #expect(changes == ["default"])
    }

    // MARK: A hidden continuation's turn (§10.5)

    @Test func thePreviousReplyIsNotWorkingWhileAHiddenContinuationStarts() {
        let messages = [ChatMessage(id: "u", role: .user, parts: [.text("go")], timestamp: Date(), rowId: 1),
                        ChatMessage(id: "a", role: .assistant, parts: [.tool(ToolCall(id: "t", name: "terminal", title: "t", argsText: nil,
                                                                                         summary: nil, state: .done, durationSeconds: nil)),
                                                                          .text("Done.")], timestamp: Date(), rowId: 2)]
        #expect(StepRules.isWorking(messages[1], at: 1, in: messages, running: true))
        #expect(!StepRules.isWorking(messages[1], at: 1, in: messages, running: true, turnAnchor: "a"))
        let s = session()
        s.messages = messages
        s.rebuildIndex()
        s.submitHidden("continue", queued: false)
        #expect(s.hiddenTurnAnchor == "a")
    }

    // MARK: Transcript cache version (§3.4)

    @Test func cardsRoundTripAndOldFilesStillRead() throws {
        var delegate = ToolCall(id: "d1", name: "delegate_task", title: "Delegated", argsText: #"{"goal":"A"}"#, summary: nil, state: .done, durationSeconds: 9.5)
        delegate.card = .delegate(goals: ["A"], results: [DelegateResult(status: "completed", summary: "Found 14", model: "m", durationSeconds: 4.2)],
                                  dispatchedGoals: nil)
        var image = ToolCall(id: "i1", name: "image_generate", title: "Image", argsText: nil, summary: nil, state: .done, durationSeconds: nil)
        image.card = .image(path: "/x.png", aspect: "square", pixelWidth: 512, pixelHeight: 512)
        let m = ChatMessage(id: "a", role: .assistant, parts: [.tool(delegate), .tool(image), .text("ok")], timestamp: Date(timeIntervalSince1970: 100), rowId: 2)
        let entry = TranscriptEntry(messages: [m], meta: [:], savedAt: Date(timeIntervalSince1970: 200))
        let data = entry.encoded()
        #expect(Array(data.prefix(4)) == Array("HQT5".utf8))
        let back = try TranscriptEntry.decode(data)
        #expect(toolCalls(back.messages.first).map(\.card) == [delegate.card, image.card])
        // A file an earlier build wrote (integration: HQT3 merges the attachments and activity formats; older files
        // are a miss, read fresh): never misread.
        let plain = TranscriptEntry(messages: [ChatMessage(id: "b", role: .assistant, parts: [.text("hi")], timestamp: nil, rowId: 3)],
                                    meta: [:], savedAt: Date(timeIntervalSince1970: 300))
        for magic in ["HQT1", "HQT2"] {
            var old = plain.encoded()
            old.replaceSubrange(0..<4, with: Array(magic.utf8))
            #expect(throws: (any Error).self) { try TranscriptEntry.decode(old) }
        }
    }

    // MARK: Rows: In Header's waiting capsule, the delegate overlay, the action row

    func rowsInput(_ messages: [ChatMessage], running: Bool, _ configure: (inout ActivityRowsInput) -> Void = { _ in }) -> ChatRowBuilder.Input {
        var a = ActivityRowsInput()
        configure(&a)
        return ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Hermes", expanded: [], scope: "t", activity: a)
    }

    func hasWaiting(_ rows: [ChatRow]) -> Bool { rows.contains { if case .waiting = $0.kind { return true } else { return false } } }

    @Test func inHeaderDrawsNoWaitingCapsuleOnceTheReplyStarted() {
        let user = ChatMessage(id: "u", role: .user, parts: [.text("Run the tests")], timestamp: Date(), rowId: 1)
        var reply = ChatMessage(id: "a", role: .assistant, parts: [.tool(ToolCall(id: "t", name: "terminal", title: "t", argsText: #"{"command":"npm test"}"#,
                                                                                  summary: nil, state: .running, durationSeconds: nil))],
                                timestamp: Date(), rowId: nil)
        reply.isStreaming = true
        #expect(!hasWaiting(ChatRowBuilder.build(rowsInput([user, reply], running: true) { $0.style = .header })), "the status line says npm test")
        #expect(hasWaiting(ChatRowBuilder.build(rowsInput([user], running: true) { $0.style = .header })), "before any reply part")
        #expect(!hasWaiting(ChatRowBuilder.build(rowsInput([user, reply], running: true) { $0.toolProgressOff = true })))
        // [toolnow] Since 2026-10-27 the thinking row stays under a running step in Rows too, naming it.
        #expect(hasWaiting(ChatRowBuilder.build(rowsInput([user, reply], running: true))), "Rows keeps the thinking row")
    }

    @Test func anEarlierTurnsCardKeepsItsOwnResult() {
        func delegate(_ id: String, running: Bool) -> ToolCall {
            var c = ToolCall(id: id, name: "delegate_task", title: "d", argsText: #"{"goal":"Index"}"#, summary: nil,
                             state: running ? .running : .done, durationSeconds: nil)
            if !running { c.card = .delegate(goals: ["Index"], results: [DelegateResult(status: "completed", summary: "Indexed")], dispatchedGoals: nil) }
            return c
        }
        let messages = [ChatMessage(id: "u1", role: .user, parts: [.text("one")], timestamp: Date(), rowId: 1),
                        ChatMessage(id: "a1", role: .assistant, parts: [.tool(delegate("d1", running: false)), .text("ok")], timestamp: Date(), rowId: 2),
                        ChatMessage(id: "u2", role: .user, parts: [.text("two")], timestamp: Date(), rowId: 3),
                        ChatMessage(id: "a2", role: .assistant, parts: [.tool(delegate("d2", running: true))], timestamp: Date(), rowId: nil, isStreaming: true)]
        let child = SubagentProgress(id: "sa_9", goal: "Survey", status: .running, taskCount: 1, taskIndex: 0, startedAt: 1, updatedAt: 1,
                                     stream: [SubagentStreamEntry(at: 1, isError: false, kind: .tool, text: "Read File(\"x\")")])
        let rows = ChatRowBuilder.build(rowsInput(messages, running: true) { $0.subagents = [child] })
        func card(_ id: String) -> [ToolCards.DelegateRow] {
            for row in rows { if case .activity(.delegate(let d)) = row.kind, d.toolId == id { return d.rows } }
            return []
        }
        #expect(card("d1").first?.status == .completed, "the old card keeps its result")
        #expect(card("d1").first?.activity == ["Indexed"])
        #expect(card("d2").first?.status == .running)
        #expect(card("d2").first?.activity.last == "Read File(\"x\")", "the live card takes the child")
    }

    @Test func aFallbackNoticeSitsUnderTheReply() {
        let messages = [ChatMessage(id: "u", role: .user, parts: [.text("Which option")], timestamp: Date(), rowId: 1),
                        ChatMessage(id: "a", role: .assistant, parts: [.text("Option B is simpler.")], timestamp: Date(), rowId: 2),
                        ChatMessage(id: "\(ProviderWait.noticeIdPrefix)1791600000", role: .system,
                                    parts: [.text("⚠ Model fallback: switched to fixture-2")], timestamp: Date(), rowId: nil)]
        let rows = ChatRowBuilder.build(rowsInput(messages, running: false))
        let ids = rows.map(\.id).filter { !$0.hasSuffix("|day") }
        // [updates] No Copy row under the reply any more (owner, 2026-10-27).
        #expect(ids == ["u|b0", "a|b0", "\(ProviderWait.noticeIdPrefix)1791600000|notice"])
        let region = ChatRowBuilder.build(rowsInput(messages, running: false), range: 2..<3).map(\.id)
        #expect(region == ["\(ProviderWait.noticeIdPrefix)1791600000|notice"])
    }

    @Test func aFailedImageCollapsesToItsLinkRow() {
        var c = ToolCall(id: "i1", name: "image_generate", title: "i", argsText: #"{"aspect_ratio":"square"}"#, summary: nil, state: .done, durationSeconds: nil)
        c.card = .image(path: "/fixture/x.png", aspect: "square", pixelWidth: 1024, pixelHeight: 1024)
        let messages = [ChatMessage(id: "u", role: .user, parts: [.text("draw")], timestamp: Date(), rowId: 1),
                        ChatMessage(id: "a", role: .assistant, parts: [.tool(c), .text("Here.")], timestamp: Date(), rowId: 2)]
        let style = ChatStyleCache.shared.style(for: .large)
        func height(_ failed: Bool) -> (CGFloat, CGFloat)? {
            let rows = ChatRowBuilder.build(rowsInput(messages, running: false) { if failed { $0.failedImages = ["/fixture/x.png"] } })
            guard let row = rows.first(where: { $0.id == "a|imi1" }) else { return nil }
            return (TextLayout.layout(row, width: 393, style: style).height, max(0, row.gapAbove))
        }
        #expect((height(false)?.0 ?? 0) > 200)
        let failed = height(true)
        #expect(failed.map { $0.0 == ceil($0.1 + 44) } == true, "a 44 pt link row: \(String(describing: failed))")
    }

    // MARK: Step sheet: the plugin's answers (§12 item 5, 6)

    @Test func theStepSheetReadsThePluginsAnswers() async throws {
        func failure(_ status: Int, _ body: String) -> StepOutputSource.Failure { StepOutputSource.failure(HTTPError(status: status, body: body)) }
        #expect(failure(404, #"{"detail":"Not Found"}"#) == .unavailable)
        #expect(failure(404, #"{"detail":"Tool content not found"}"#) == .gone)
        #expect(failure(503, #"{"detail":"Compatible Hermes HQ performance adapter is unavailable"}"#) == .unavailable)
        #expect(failure(413, #"{"detail":{"code":"tool_content_too_large"}}"#) == .tooLarge)
        #expect(failure(422, #"{"detail":{"code":"tool_preview_unavailable","message":"This output contains binary control data."}}"#)
                == .refused("This output contains binary control data."))
        let client = FakeGatewayClient()
        client.onRest { _, _ in Data(#"{"schema":"tool.content.v1","content":{"files":["a","b"],"ok":true}}"#.utf8) }
        let source = StepOutputSource(client: client, routeName: "hermes-hq-performance",
                                      ref: ["session_id": "s1", "row_id": 7, "profile": "default"])
        let text = try await source.full()
        #expect(ChatJSON.parse(string: text)?["files"] == ["a", "b"], "a decoded object is copied as JSON")
    }

    // MARK: Display flags cache (§2.3)

    @Test func displayFlagsAreReadOncePerMinuteAndAgainAfterAppReturn() async {
        let client = FakeGatewayClient()
        client.onRest { path, _ in Data(#"{"display":{"show_reasoning":false}}"#.utf8) }
        let cache = DisplayConfigCache(client: client)
        var got: DisplayFlags?
        cache.refresh(profile: "default") { got = $0 }
        #expect(await waitUntil { got != nil })
        #expect(got?.showReasoning == false)
        cache.refresh(profile: "default") { _ in }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(client.restLog.filter { $0.path == "/api/config" }.count == 1, "fresh for a minute")
        cache.markStale()
        cache.refresh(profile: "default") { _ in }
        #expect(await waitUntil { client.restLog.filter { $0.path == "/api/config" }.count == 2 })
    }

    // MARK: Spinners and the padded label

    @Test func aSpinnerInAHiddenPieceIsNotShowing() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let piece = UIView(frame: window.bounds)
        let spinner = GlyphSpinner()
        piece.addSubview(spinner)
        window.addSubview(piece)
        window.isHidden = false
        #expect(spinner.isShowing)
        piece.isHidden = true
        #expect(!spinner.isShowing)
        piece.isHidden = false
        piece.alpha = 0
        #expect(!spinner.isShowing)
        piece.alpha = 1
        spinner.isHidden = true
        #expect(!spinner.isShowing)
        window.isHidden = true
    }

    @Test func aPaddedLabelBreaksLinesInsideItsPadding() {
        let label = PaddedLabel()
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.numberOfLines = 0
        label.padding = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        label.text = String(repeating: "npm run build ", count: 12)
        let size = label.sizeThatFits(CGSize(width: 200, height: 1000))
        #expect(size.width <= 200)
        let plain = UILabel()
        plain.font = label.font
        plain.numberOfLines = 0
        plain.text = label.text
        let inner = plain.sizeThatFits(CGSize(width: 184, height: 1000))
        #expect(abs(size.height - (inner.height + 8)) < 1, "the text wraps at the width inside the padding")
    }
}
