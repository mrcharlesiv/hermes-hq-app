// Stream "questions" unit checks 1, 3, 6, 7, 8 (docs/spec/1x-questions.md §7.1): answer frames, the open_requests
// interception, the dock's staging (ported from W:src/phone-question-dock.test.ts), approval expiry
// (W:src/approval-expiry.test.ts) and the settled clarify parse.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Questions: frames and interception")
struct QuestionsFrameTests {
    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func responseFramesHaveNoMethodAndKeepTheStringId() throws {
        let ok = try object(RPCFrame.response(id: "srq-0c51a9e2b8f4", result: ["choice": "once"]))
        #expect(ok["jsonrpc"] as? String == "2.0")
        #expect(ok["id"] as? String == "srq-0c51a9e2b8f4")
        #expect((ok["result"] as? [String: Any])?["choice"] as? String == "once")
        #expect(ok["method"] == nil && ok["error"] == nil)
        #expect(RPCFrame.response(id: "srq-1", result: [:]) == #"{"id":"srq-1","jsonrpc":"2.0","result":{}}"#)
        #expect(RPCFrame.response(id: "srq-1", result: ["value": ""]) == #"{"id":"srq-1","jsonrpc":"2.0","result":{"value":""}}"#)

        let declined = try object(RPCFrame.errorResponse(id: "srq-77aa01bb22cc", code: 4404, message: "This window is not showing the session."))
        #expect(declined["id"] as? String == "srq-77aa01bb22cc")
        #expect(declined["method"] == nil && declined["result"] == nil)
        let error = try #require(declined["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == 4404)
        #expect(error["message"] as? String == "This window is not showing the session.")
        #expect(RPCFrame.errorResponse(id: "srq-2", code: -32601, message: "no handler for server request: setup_choose")
                == #"{"error":{"code":-32601,"message":"no handler for server request: setup_choose"},"id":"srq-2","jsonrpc":"2.0"}"#)
    }

    @Test func serverRequestExamplesParse() {
        let examples = [
            #"{"jsonrpc":"2.0","id":"srq-0c51a9e2b8f4","method":"approval","params":{"session_id":"5cc537d1","command":"git push --force origin main","pattern_key":"git force push (rewrites remote history)","pattern_keys":["git force push (rewrites remote history)"],"description":"git force push (rewrites remote history)","allow_permanent":true,"allow_session":true,"request_id":"9b1d6f0e2c4a4e83a1d2c3b4e5f60718","choices":["once","session","always","deny"]}}"#,
            #"{"jsonrpc":"2.0","id":"srq-77aa01bb22cc","method":"clarify","params":{"session_id":"5cc537d1","questions":[{"qid":"q0","question":"Which branch should I deploy?","choices":["main (Recommended)","staging"],"multi_select":false},{"qid":"q1","question":"Anything to skip?","choices":["Tests","Lint","Docs"],"multi_select":true},{"qid":"q2","question":"What should the release be called?","choices":null,"multi_select":false}]}}"#,
            #"{"jsonrpc":"2.0","id":"srq-1e2f3a4b5c6d","method":"vault.save_login","params":{"session_id":"5cc537d1","origin":"https://shop.example.com","site":"Example Shop"}}"#,
        ]
        let methods = ["approval", "clarify", "vault.save_login"]
        for (text, method) in zip(examples, methods) {
            guard case .serverRequest(let id, let parsedMethod, let params) = RPCFrame.parse(text) else {
                Issue.record("not a server request: \(text)"); continue
            }
            #expect(id.hasPrefix("srq-"))
            #expect(parsedMethod == method)
            #expect(params["session_id"]?.string == "5cc537d1")
        }
        guard case .serverRequest(_, _, let clarify) = RPCFrame.parse(examples[1]) else { return }
        let questions = ClarifyText.normalize(clarify["questions"])
        #expect(questions.count == 3)
        #expect(questions[2].choices == nil && questions[1].multiSelect)
    }

    @Test func interceptionYieldsReplayedRequestsThenTheAuthoritativeSet() {
        let result: JSONValue = ["session_id": "5cc537d1", "open_requests": [
            ["id": "srq-a", "method": "clarify", "params": ["session_id": "5cc537d1", "questions": [], "answers": ["q0": "main"]]],
            ["id": "srq-b", "method": "approval", "params": ["session_id": "5cc537d1", "command": "ls"]],
        ], "pending_approval": ["request_id": "abc", "command": "ls"]]
        let events = OpenRequestsIntercept.events(method: "session.activate", params: ["session_id": "5cc537d1"], result: result, epoch: 3)
        #expect(events.map(\.type) == [LocalEvent.serverRequest, LocalEvent.serverRequest, LocalEvent.openRequests])
        #expect(events[0].payload["id"]?.string == "srq-a")
        #expect(events[0].payload["replayed"]?.bool == true)
        #expect(events[0].payload["epoch"]?.int == 3)
        #expect(events[0].payload["params"]?["answers"]?["q0"]?.string == "main")
        #expect(events[2].payload["ids"] == ["srq-a", "srq-b"])
        #expect(events[2].payload["pending_approval"]?["request_id"]?.string == "abc")
        #expect(events[2].payload["method"]?.string == "session.activate")

        // A missing key means none open: an empty authoritative set.
        let none = OpenRequestsIntercept.events(method: "session.resume", params: ["session_id": "stored"],
                                                result: ["session_id": "rt1"], epoch: 1)
        #expect(none.count == 1)
        #expect(none[0].sessionId == "rt1")
        #expect(none[0].payload["ids"] == [])
        #expect(none[0].payload["pending_approval"]?.isNull == true)
        // Other methods: nothing.
        #expect(OpenRequestsIntercept.events(method: "prompt.submit", params: [:], result: ["session_id": "x"], epoch: 1).isEmpty)
        // events.since names the session in its params.
        let since = OpenRequestsIntercept.events(method: "session.events.since", params: ["session_id": "rt9"],
                                                 result: ["events": [], "open_requests": []], epoch: 1)
        #expect(since.last?.sessionId == "rt9")
    }

    @Test func aSessionAuthoritysSnapshotReplaysItsSharedQuestions() {
        let result: JSONValue = ["session_id": "s1", "execution_generation": 4, "open_requests": [], "prompts": [
            ["kind": "approval", "prompt_id": "a-1", "execution_generation": 4, "choices": ["once", "deny"], "command": "ls"],
            ["kind": "clarify", "prompt_id": "c-1", "execution_generation": 4, "question": "Which?", "choices": ["A", "B"]],
        ]]
        let events = OpenRequestsIntercept.events(method: "session.activate", params: ["session_id": "s1"], result: result, epoch: 2)
        #expect(events.map(\.type) == ["clarify.request", LocalEvent.openRequests])
        #expect(events[0].sessionId == "s1")
        #expect(events[0].payload["prompt_id"]?.string == "c-1")
        #expect(events[1].payload["prompt_ids"] == ["c-1"])
        // A plain sidecar's snapshot has no `prompts`: no `prompt_ids`, so shared questions are left alone.
        let plain = OpenRequestsIntercept.events(method: "session.activate", params: ["session_id": "s1"],
                                                 result: ["session_id": "s1", "open_requests": []], epoch: 2)
        #expect(plain.last?.payload["prompt_ids"] == nil)
    }
}

@Suite("Questions: the dock's staging")
struct ClarifyStagingTests {
    let one = ClarifyQuestion(qid: "q1", question: "Which city?", choices: ["Lisbon (Recommended)", "Porto"], multiSelect: false)
    let many = ClarifyQuestion(qid: "q2", question: "Include?", choices: ["Flights", "Hotels", "Day trips"], multiSelect: true)
    let free = ClarifyQuestion(qid: "q3", question: "Anything else?", choices: nil, multiSelect: false)
    let empty = ClarifyStage()

    @Test func answersEachQuestionAsTheWebCardDoes() {
        #expect(ClarifyStaging.stagedAnswer(one, empty) == nil)
        #expect(ClarifyStaging.stagedAnswer(one, ClarifyStaging.toggle(one, empty, "Lisbon (Recommended)")) == "Lisbon")
        #expect(ClarifyStaging.stagedAnswer(many, ClarifyStage(choices: ["Flights", "Hotels"])) == #"["Flights","Hotels"]"#)
        #expect(ClarifyStaging.stagedAnswer(free, ClarifyStage(draft: "  Two adults  ")) == "Two adults")
        #expect(ClarifyStaging.stagedAnswer(many, ClarifyStage(choices: ["Flights"], draft: "Trains", other: true)) == #"["Flights","Trains"]"#)
        #expect(ClarifyStaging.stagedAnswer(one, ClarifyStage(draft: "stale")) == nil)
    }

    @Test func singleSelectKeepsOneAnswerAndMultiToggles() {
        let picked = ClarifyStaging.toggle(one, empty, "Porto")
        #expect(ClarifyStaging.toggle(one, picked, "Lisbon (Recommended)").choices == ["Lisbon (Recommended)"])
        let other = ClarifyStaging.openOther(one, picked)
        #expect(other == ClarifyStage(choices: [], draft: "", other: true))
        var typed = other; typed.draft = "Faro"
        #expect(ClarifyStaging.toggle(one, typed, "Porto") == ClarifyStage(choices: ["Porto"], draft: "Faro", other: false))
        let both = ClarifyStaging.toggle(many, ClarifyStaging.toggle(many, empty, "Flights"), "Hotels")
        #expect(both.choices == ["Flights", "Hotels"])
        #expect(ClarifyStaging.toggle(many, both, "Flights").choices == ["Hotels"])
        #expect(ClarifyStaging.openOther(many, both) == ClarifyStage(choices: ["Flights", "Hotels"], draft: "", other: true))
    }

    @Test func replayShowsLockedAnswersAsPicked() {
        #expect(ClarifyStaging.replay(one, nil) == nil)
        #expect(ClarifyStaging.replay(one, .some(nil)) == nil)
        #expect(ClarifyStaging.replay(one, "Lisbon") == ClarifyStage(choices: ["Lisbon (Recommended)"], draft: "", other: false))
        #expect(ClarifyStaging.replay(many, #"["Hotels","Trains"]"#) == ClarifyStage(choices: ["Hotels"], draft: "Trains", other: true))
        #expect(ClarifyStaging.replay(free, "Two adults") == ClarifyStage(choices: [], draft: "Two adults", other: false))
    }

    @Test func notesWhatWasSentOrSkipped() {
        let stages = ["q1": ClarifyStaging.toggle(one, empty, "Porto"), "q2": ClarifyStage(choices: ["Flights", "Hotels"])]
        #expect(ClarifyStaging.sentRows([one, many, free], stages) == [
            SentClarifyRow(question: "Which city?", answer: "Porto"),
            SentClarifyRow(question: "Include?", answer: "Flights, Hotels"),
            SentClarifyRow(question: "Anything else?", answer: nil),
        ])
        #expect(ClarifyStaging.sentRows([one], stages, skipped: true) == [SentClarifyRow(question: "Which city?", answer: "")])
    }

    @Test func initialDraftReplaysLocksAndLocalPicksWin() {
        let prompt = ClarifyPrompt(id: "srq-x", questions: [one, many], lockedAnswers: ["q1": "Lisbon", "q2": String?.none])
        let fresh = ClarifyStaging.initialDraft(prompt, saved: nil)
        #expect(fresh.stages["q1"]?.choices == ["Lisbon (Recommended)"])
        #expect(fresh.stages["q2"] == nil)
        let saved = ClarifyDraft(page: 5, stages: ["q1": ClarifyStage(choices: ["Porto"])])
        let kept = ClarifyStaging.initialDraft(prompt, saved: saved)
        #expect(kept.stages["q1"]?.choices == ["Porto"])
        #expect(kept.page == 1)    // clamped to the last page
    }

    @Test func normalisationDropsUnusableQuestionsAndChoices() {
        let raw: JSONValue = [
            ["qid": " q0 ", "question": " Pick ", "choices": ["  ", "A", 3, .string(String(repeating: "x", count: 8001))], "multi_select": true],
            ["qid": "", "question": "No id"],
            ["qid": "q2", "question": "   "],
            ["qid": "q3", "question": "Open", "choices": ["  "], "multi_select": true],
        ]
        let out = ClarifyText.normalize(raw)
        #expect(out == [ClarifyQuestion(qid: "q0", question: "Pick", choices: ["A"], multiSelect: true),
                        ClarifyQuestion(qid: "q3", question: "Open", choices: nil, multiSelect: false)])
        #expect(ClarifyText.bareChoice("main (Recommended)") == "main")
        #expect(ClarifyText.bareChoice("main") == "main")
    }
}

@Suite("Questions: approval expiry")
struct ApprovalExpiryTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func countsDownToTheTimeoutAsAnUpperBound() {
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 60, now: t0 + 18) == "Expires within 0:42")
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 60, now: t0 + 59.5) == "Expires within 0:01")
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 60, now: t0 + 60) == "Expired")
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 300, now: t0 + 10) == "Expires within 5 min")
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 300, now: t0 + 215) == "Expires within 1:25")
        // Spec §7.1 check 7 boundaries.
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 91, now: t0) == "Expires within 2 min")
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 90, now: t0) == "Expires within 1:30")
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 0, now: t0) == "Expired")
        // A timeout past 99 minutes counts hours (the card's space is "Expires within 99 min").
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 99 * 60, now: t0) == "Expires within 99 min")
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 120 * 60, now: t0) == "Expires within 2 h")
        #expect(ApprovalExpiry.label(seenAt: t0, timeout: 120 * 60, now: t0 + 1800) == "Expires within 90 min")
    }

    @Test func aStaleReadWaitsAtZeroInsteadOfExpiring() {
        // The timeout was read before it was due: 0:00 until a fresh read agrees.
        let stale = ApprovalExpiry.countdown(seenAt: t0, timeout: 60, readAt: t0 + 1, now: t0 + 61)
        #expect(stale.label == "Expires within 0:00" && stale.stale)
        let fresh = ApprovalExpiry.countdown(seenAt: t0, timeout: 60, readAt: t0 + 61, now: t0 + 61)
        #expect(fresh.label == "Expired" && !fresh.stale)
        #expect(ApprovalExpiry.countdown(seenAt: t0, timeout: nil, readAt: nil).label == "")
    }

    @Test func timeoutComesFromTheConfigWithTheDefault() {
        #expect(ApprovalExpiry.timeout(fromConfig: ["approvals": ["timeout": 120]]) == 120)
        #expect(ApprovalExpiry.timeout(fromConfig: ["approvals": ["timeout": "45"]]) == 45)
        #expect(ApprovalExpiry.timeout(fromConfig: ["approvals": ["timeout": 0]]) == 300)
        #expect(ApprovalExpiry.timeout(fromConfig: ["model": "x"]) == 300)
        #expect(ApprovalExpiry.timeout(fromConfig: nil) == 300)
    }
}

@Suite("Questions: the settled card")
struct ClarifySettledTests {
    let result: JSONValue = ["responses": [
        ["question": "Which branch?", "choices_offered": ["main", "staging"], "status": "answered", "user_response": "main"],
        ["question": "Skip?", "choices_offered": ["Tests", "Lint"], "status": "answered", "user_response": ["Lint", "docs too"]],
        ["question": "Name?", "choices_offered": .null, "status": "unanswered", "user_response": .null],
        ["question": "Other?", "choices_offered": .null, "status": "skipped", "user_response": .null],
    ], "outcome": "submitted"]

    @Test func parsesALiveObjectAndAHistoryString() throws {
        let rows = try #require(ClarifySettled.parse(result))
        #expect(rows == [ClarifyQA(question: "Which branch?", answer: "main", unanswered: false),
                         ClarifyQA(question: "Skip?", answer: "Lint, docs too", unanswered: false),
                         ClarifyQA(question: "Name?", answer: "", unanswered: true),
                         ClarifyQA(question: "Other?", answer: "", unanswered: false)])
        let text = String(decoding: try result.encoded(), as: UTF8.self)
        #expect(ClarifySettled.parse(.string(text)) == rows)
        #expect(ClarifySettled.parse(["stdout": "x"]) == nil)
        #expect(ClarifySettled.parse(.string("not json")) == nil)
    }

    @Test func theSummaryCarriesTheRowsThroughHydration() throws {
        let summary = try #require(ClarifySettled.summary(name: "clarify", result: result, fallback: "x"))
        #expect(ClarifySettled.rows(fromSummary: summary)?.count == 4)
        #expect(ClarifySettled.summary(name: "terminal", result: result, fallback: "x") == "x")
        #expect(ClarifySettled.rows(fromSummary: "plain") == nil)
        // History: an assistant tool call row + its tool row fold into a clarify call whose summary has the rows.
        let rows: [JSONValue] = [
            ["role": "user", "content": "ask", "row_id": 1, "timestamp": 1_790_852_400],
            ["role": "assistant", "content": "", "row_id": 2, "timestamp": 1_790_852_401,
             "tool_calls": [["id": "clarify-1", "type": "function", "function": ["name": "clarify", "arguments": "{}"]]]],
            ["role": "tool", "content": .string(String(decoding: try result.encoded(), as: UTF8.self)), "row_id": 3,
             "tool_call_id": "clarify-1", "timestamp": 1_790_852_402],
        ]
        let page = Hydration.fold(rows)
        let call = page.messages.flatMap(\.parts).compactMap { part -> ToolCall? in
            if case .tool(let c) = part { return c } else { return nil }
        }.first
        #expect(call?.name == "clarify")
        #expect(ClarifySettled.rows(fromSummary: call?.summary)?.first?.answer == "main")
    }
}
