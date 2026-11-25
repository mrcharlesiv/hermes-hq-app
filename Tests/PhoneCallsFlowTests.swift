// Phone Calls (Beta) round 2, against samplehostStub (never the network, key "KEYTEST"): the recording switch, the dial
// block, the event log, repeated questions, Tell the assistant, voicemail, the result message, alerts and history.
// XCTest like PhoneCallsTests, because samplehostStub's script is shared by the whole class.
import XCTest
@testable import HermesHQNative

extension PhoneCallsTests {
    /// list-call-events rows as samplehost writes them (`occurred_at` with a space and microseconds, UTC).
    static func events(answered: Bool, ring: Double = 4, talk: Double = 12, machine: Bool = false,
                       hangupCause: String = "normal_clearing", start: String = "2026-11-21 12:36:40") -> [[String: Any]] {
        func row(_ name: String, _ at: Double, _ inner: [String: Any] = [:]) -> [String: Any] {
            let base = PhoneCallEvent.date(start + ".000000")!.addingTimeInterval(at)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
            return ["record_type": "call_event", "type": "webhook", "name": name, "call_leg_id": "leg-1",
                    "occurred_at": f.string(from: base),
                    "payload": ["event_type": name, "payload": inner.merging(["call_leg_id": "leg-1"]) { a, _ in a }]]
        }
        var rows = [row("call.initiated", 0)]
        if answered {
            rows.append(row("call.answered", ring))
            rows.append(row("call.machine.premium.detection.ended", ring + 1, ["result": machine ? "machine" : "human"]))
            rows.append(row("call.hangup", ring + talk, ["hangup_cause": hangupCause, "hangup_source": "callee"]))
        } else {
            rows.append(row("call.hangup", ring, ["hangup_cause": hangupCause, "hangup_source": "callee"]))
        }
        return rows.reversed()   // the log's order isn't promised
    }

    static func ask(_ id: String, _ question: String, at: String) -> [String: Any] {
        ["role": "assistant", "text": "", "created_at": at,
         "tool_calls": [["id": id, "type": "function", "function": ["name": "ask_owner", "arguments": #"{"question":"\#(question)"}"#]]]]
    }

    var addMessages: [samplehostStub.Seen] { samplehostStub.seen.filter { $0.path.hasSuffix("/actions/ai_assistant_add_messages") } }

    // MARK: Item 4: recording

    @MainActor func testRecordingRoundTripPostsTheWholeTelephonyOnlyWhenItDiffers() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let wrote = try await api().matchRecording(assistantID: "assistant-1", on: true)
        XCTAssertTrue(wrote)
        let posts = samplehostStub.seen.filter { $0.method == "POST" && $0.path == "/v2/ai/assistants/assistant-1" }
        XCTAssertEqual(posts.count, 1)
        let sent = try XCTUnwrap(posts.first?.json)
        XCTAssertEqual(Set(sent.keys), ["telephony_settings"])
        let telephony = try XCTUnwrap(sent["telephony_settings"] as? [String: Any])
        XCTAssertEqual(telephony["default_texml_app_id"] as? String, "texml-1", "the whole object goes back")
        XCTAssertEqual(telephony["noise_suppression"] as? String, "krisp")
        let recording = try XCTUnwrap(telephony["recording_settings"] as? [String: Any])
        XCTAssertEqual(recording["enabled"] as? Bool, true)
        XCTAssertEqual(recording["channels"] as? String, "dual", "only enabled changes")
        // Now it matches: a read, no write.
        let again = try await api().matchRecording(assistantID: "assistant-1", on: true)
        XCTAssertFalse(again)
        XCTAssertEqual(samplehostStub.seen.filter { $0.method == "POST" && $0.path == "/v2/ai/assistants/assistant-1" }.count, 1)
        XCTAssertEqual(samplehostStub.seen.filter { $0.method == "GET" && $0.path == "/v2/ai/assistants/assistant-1" }.count, 2)
        // Absent recording_settings reads as samplehost's default: on.
        XCTAssertEqual(samplehostAssistantDetail(json: ["id": "a", "telephony_settings": [:]]).recordingOn, true)
        XCTAssertNil(samplehostAssistantDetail(json: ["id": "a"]).recordingOn)
    }

    @MainActor func testAFailedRecordingUpdateBlocksTheDial() async throws {
        let script = Script()
        script.updateFails = true
        samplehostStub.reset(script.route)
        var setup = PhoneSetup(apiKey: Self.key, fromNumber: "+15550100001", connectionID: "conn-1", assistantID: "assistant-1")
        setup.recordCalls = true
        let calls = try controller(setup: setup)
        do {
            try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
            XCTFail("dialed although recording couldn't be set")
        } catch {
            XCTAssertTrue(phoneMessage(error).hasPrefix("The call wasn't placed"), phoneMessage(error))
        }
        XCTAssertFalse(samplehostStub.seen.contains { $0.path == "/v2/calls" }, "no dial")
        XCTAssertTrue(calls.calls.isEmpty)
    }

    @MainActor func testTheDialRecordsAndSaysSoWhenTheSwitchIsOn() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        var setup = PhoneSetup(apiKey: Self.key, fromNumber: "+15550100001", connectionID: "conn-1", assistantID: "assistant-1")
        setup.recordCalls = true
        setup.ownerName = " Alex "
        let calls = try controller(setup: setup)
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Move the appointment", voicemail: .leaveMessage, name: "Dental Office")
        let order = samplehostStub.seen.map { "\($0.method) \($0.path)" }
        let update = try XCTUnwrap(order.firstIndex(of: "POST /v2/ai/assistants/assistant-1"))
        let dial = try XCTUnwrap(order.firstIndex(of: "POST /v2/calls"))
        XCTAssertLessThan(update, dial, "recording matches before the dial")
        let assistant = try XCTUnwrap(samplehostStub.seen[dial].json["assistant"] as? [String: Any])
        let greeting = assistant["greeting"] as? String ?? ""
        XCTAssertTrue(greeting.contains("calling for Alex"), greeting)
        XCTAssertTrue(greeting.contains("this call is being recorded"), greeting)
        let instructions = assistant["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("call is being recorded"))
        XCTAssertTrue(instructions.contains("leave one short friendly message, then hang up"))
        XCTAssertTrue(instructions.contains("placing an outbound phone call for Alex."))
        XCTAssertTrue(instructions.contains("You are calling Dental Office."))
        let call = try XCTUnwrap(calls.calls.first)
        XCTAssertTrue(call.recorded)
        XCTAssertEqual(call.voicemailChoice, .leaveMessage)
        XCTAssertEqual(call.legID, "leg-1")
        XCTAssertEqual(call.statusText, "Ringing…")
        _ = await calls.endAll()
    }

    @MainActor func testConversationIDTransitionsToLiveImmediatelyBeforeMessagesArrive() async throws {
        let script = Script()
        script.messages = []
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Check in")
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.conversationID, "conv-1")
        XCTAssertEqual(calls.calls.first?.state, .live, "live immediately once samplehost creates the conversation")
        _ = await calls.endAll()
    }

    @MainActor func testFastHangupEventEndsCallWithoutWaitingForRingTimeout() async throws {
        let script = Script()
        script.alive = false
        script.messages = []
        script.events = Self.events(answered: false, ring: 2, hangupCause: "user_busy")
        samplehostStub.reset { seen in seen.path == "/v2/ai/conversations" ? (200, ["data": []]) : script.route(seen) }
        var clock = Date(timeIntervalSince1970: 9_000)
        let calls = try controller()
        calls.now = { clock }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        clock = clock.addingTimeInterval(3)   // well under the 55-second ring timeout
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.state, .ended)
        XCTAssertEqual(calls.calls.first?.outcome, .busy)
        XCTAssertEqual(calls.calls.first?.statusText, "Busy")
    }

    @MainActor func testConversationStartFailedHangsUpOrphanedLegAndReportsFailure() async throws {
        let script = Script()
        script.messages = []
        script.events = [
            ["record_type": "call_event", "type": "webhook", "name": "call.initiated", "call_leg_id": "leg-1",
             "occurred_at": "2026-11-21 12:36:40.000000", "payload": ["event_type": "call.initiated", "payload": [:]]],
            ["record_type": "call_event", "type": "webhook", "name": "call.answered", "call_leg_id": "leg-1",
             "occurred_at": "2026-11-21 12:36:43.000000", "payload": ["event_type": "call.answered", "payload": [:]]],
            ["record_type": "call_event", "type": "webhook", "name": "call.conversation.start_failed", "call_leg_id": "leg-1",
             "occurred_at": "2026-11-21 12:36:44.000000",
             "payload": ["event_type": "call.conversation.start_failed", "payload": ["error": "model quota exceeded"]]],
        ]
        samplehostStub.reset { seen in seen.path == "/v2/ai/conversations" ? (200, ["data": []]) : script.route(seen) }
        var clock = Date(timeIntervalSince1970: 15_000)
        let calls = try controller()
        calls.now = { clock }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.refresh(Self.callID)
        XCTAssertTrue(samplehostStub.seen.contains { $0.path.hasSuffix("/actions/hangup") }, "orphaned call leg is hung up")
        XCTAssertEqual(calls.calls.first?.state, .ended)
        clock = clock.addingTimeInterval(65)
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.outcome, .couldNotConnect("model quota exceeded"))
    }

    @MainActor func testMigrateSessionReKeysCallsFromRuntimeToStoredID() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "runtime-1", to: "+12125550142", purpose: "Ask")
        calls.migrateSession(from: ["runtime-1"], to: "stored-42")
        XCTAssertEqual(calls.calls.first?.sessionID, "stored-42")
        _ = await calls.endAll()
    }

    // MARK: Item 3: the event log

    @MainActor func testCallEventsReadTheWebhookLogByLeg() async throws {
        let script = Script()
        script.events = Self.events(answered: true, ring: 4, talk: 30)
        samplehostStub.reset(script.route)
        let events = try await api().callEvents(legID: "leg-1")
        let seen = try XCTUnwrap(samplehostStub.seen.first)
        XCTAssertEqual(seen.path, "/v2/call_events")
        XCTAssertEqual(seen.query["filter[leg_id]"], "leg-1")
        XCTAssertEqual(seen.query["filter[type]"], "webhook")
        XCTAssertEqual(seen.query["page[size]"], "50")
        XCTAssertEqual(Set(events.map(\.name)), ["call.initiated", "call.answered", "call.machine.premium.detection.ended", "call.hangup"])
        XCTAssertEqual(events.first { $0.name == "call.hangup" }?.hangupCause, "normal_clearing")
        XCTAssertEqual(events.first { $0.name == "call.hangup" }?.hangupSource, "callee")
        XCTAssertEqual(events.first { $0.name.contains("detection") }?.result, "human")
        let verdict = PhoneVerdict.derive(events: events, status: nil, theirLines: [], ended: true, localEnd: nil, gaveUp: false)
        XCTAssertEqual(verdict.ringSeconds ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(verdict.duration, 30)
        XCTAssertEqual(verdict.outcome, .finished)
    }

    @MainActor func testOutcomeWaitsForTheLaggingLogThenSettles() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        var clock = Date(timeIntervalSince1970: 5_000)
        let calls = try controller()
        calls.now = { clock }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.statusText, "On the call")
        script.alive = false
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.statusText, "Ended", "the log hasn't caught up")
        XCTAssertFalse(calls.calls.first?.settled ?? true)
        clock = clock.addingTimeInterval(10)
        script.events = Self.events(answered: true, ring: 5, talk: 92)
        script.duration = 92
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.statusText, "Finished · 1m 32s")
        XCTAssertEqual(calls.calls.first?.ringSeconds ?? -1, 5, accuracy: 0.001)
    }

    @MainActor func testBusyAndNoAnswerFromTheLog() async throws {
        for (cause, title) in [("user_busy", "Busy"), ("timeout", "No answer"), ("call_rejected", "Declined"),
                               ("unallocated_number", "Couldn't connect: that number doesn't exist")] {
            let script = Script()
            script.alive = false
            script.messages = []
            script.events = Self.events(answered: false, ring: 3, hangupCause: cause)
            samplehostStub.reset { seen in seen.path == "/v2/ai/conversations" ? (200, ["data": []]) : script.route(seen) }
            var clock = Date(timeIntervalSince1970: 9_000)
            let calls = try controller("https://a.example.com|\(cause)")
            calls.now = { clock }
            try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
            clock = clock.addingTimeInterval(TimeInterval(PhoneLimits.ringSeconds + 11))
            await calls.refresh(Self.callID)
            XCTAssertEqual(calls.calls.first?.statusText, title, cause)
        }
    }

    // MARK: Item 12: voicemail in 1 second

    @MainActor func testVoicemailInOneSecondGetsTheStraightToVoicemailNote() async throws {
        let script = Script()
        script.messages = [
            ["role": "assistant", "text": "<emotion value=\"calm\"/>Hi, this is an AI assistant calling with a quick request.", "created_at": "2026-01-01T00:00:01.000Z"],
            ["role": "user", "text": "Your call has been forwarded to an automatic voice message system. Please record your message at the tone.", "created_at": "2026-01-01T00:00:02.000Z"],
        ]
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.statusText, "Voicemail answered")
        script.alive = false
        script.duration = 23
        script.events = Self.events(answered: true, ring: 1, talk: 23, machine: true)
        await calls.refresh(Self.callID)
        let call = try XCTUnwrap(calls.calls.first)
        XCTAssertEqual(call.outcome, .voicemail)
        XCTAssertEqual(call.statusText, "Went to voicemail · 23s")
        XCTAssertEqual(call.straightToVoicemailNote,
                       "Voicemail picked up in 1 second, so the phone probably never rang. That is the other phone or its carrier (Do Not Disturb or a Focus, Silence Unknown Callers, a spam filter), not your samplehost setup.")
        XCTAssertEqual(call.lines.first?.text, "Hi, this is an AI assistant calling with a quick request.", "no emotion tag")
    }

    // MARK: Item 5: a question asked twice

    @MainActor func testAQuestionAskedTwiceShowsOnceAndOneAnswerSettlesBoth() async throws {
        let script = Script()
        script.messages = [
            ["role": "assistant", "text": "Hello.", "created_at": "2026-01-01T00:00:01.000Z"],
            Self.ask("call_a", "Is Tuesday at 3 OK?", at: "2026-01-01T00:00:02.000Z"),
            ["role": "tool", "text": #"{"http_status":422,"error":"unreachable"}"#, "created_at": "2026-01-01T00:00:02.500Z"],
            Self.ask("call_b", "is tuesday at 3 ok? ", at: "2026-01-01T00:00:03.000Z"),
            ["role": "system", "text": "[long silence]", "created_at": "2026-01-01T00:00:04.000Z"],
        ]
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.refresh(Self.callID)
        let question = try XCTUnwrap(calls.calls.first?.question)
        XCTAssertEqual(question.id, "call_b", "the newest one is offered")
        XCTAssertEqual(question.ids, ["call_b", "call_a"], "with the other open copy")
        XCTAssertEqual(calls.calls.first?.asked.count, 1, "listed once")
        XCTAssertEqual(calls.calls.first?.shownLines.map(\.text), ["Hello."], "no receipt, no [long silence]")
        await calls.answer(Self.callID, question: question, with: "Yes")
        XCTAssertEqual(addMessages.count, 1, "one request")
        let messages = try XCTUnwrap(addMessages.first?.json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["tool", "tool", "system"])
        XCTAssertEqual(Set(messages.compactMap { $0["tool_call_id"] as? String }), ["call_a", "call_b"])
        XCTAssertNil(calls.calls.first?.question)
        XCTAssertEqual(calls.calls.first?.asked.first?.answer, "Yes")
        // The conversation reads our two tool messages back: one "You" line.
        script.messages.append(["role": "tool", "text": PhoneAskOwner.toolAnswer("Yes", toolCallID: "call_b"), "created_at": "2026-01-01T00:00:05.000Z"])
        script.messages.append(["role": "tool", "text": PhoneAskOwner.toolAnswer("Yes", toolCallID: "call_a"), "created_at": "2026-01-01T00:00:05.001Z"])
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.shownLines.map(\.text), ["Hello.", "Yes"])
        XCTAssertEqual(calls.calls.first?.shownLines.last?.speaker, .you)
        XCTAssertNil(calls.calls.first?.question)
        _ = await calls.endAll()
    }

    @MainActor func testALateRepeatIsAnsweredQuietlyNotShownAgain() async throws {
        let script = Script()
        script.messages = [Self.ask("call_a", "Which day?", at: "2026-01-01T00:00:02.000Z")]
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.refresh(Self.callID)
        await calls.answer(Self.callID, question: try XCTUnwrap(calls.calls.first?.question), with: "Friday")
        script.messages.append(Self.ask("call_c", "Which day?", at: "2026-01-01T00:00:09.000Z"))
        await calls.refresh(Self.callID)
        XCTAssertNil(calls.calls.first?.question, "not asked of the owner again")
        XCTAssertEqual(addMessages.count, 2)
        let quiet = try XCTUnwrap(addMessages.last?.json)
        XCTAssertEqual(quiet["trigger_response"] as? Bool, false)
        let messages = try XCTUnwrap(quiet["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["tool"])
        XCTAssertEqual(messages.first?["content"] as? String, "The owner answered (ref call_c): Friday")
        await calls.refresh(Self.callID)
        XCTAssertEqual(addMessages.count, 2, "once")
        _ = await calls.endAll()
    }

    // MARK: Item 6: Tell the assistant

    @MainActor func testTellTheAssistantSendsASystemMessageAndShowsAYouLineAtOnce() async throws {
        let script = Script()
        script.messages = [["role": "assistant", "text": "Hello.", "created_at": "2026-01-01T00:00:01.000Z"]]
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.refresh(Self.callID)
        let sent = await calls.tell(Self.callID, "  Ask for the earliest slot. ")
        XCTAssertTrue(sent)
        let body = try XCTUnwrap(addMessages.first?.json)
        XCTAssertEqual(body["trigger_response"] as? Bool, true)
        XCTAssertFalse((body["command_id"] as? String ?? "").isEmpty)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Message from the owner, sent during the call: Ask for the earliest slot.")
        XCTAssertEqual(calls.calls.first?.shownLines.last, PhoneTranscript.Line(id: "pending|0", speaker: .you, text: "Ask for the earliest slot."),
                       "shown before the conversation returns it")
        // The conversation returns it: still one line.
        script.messages.append(["role": "system", "text": "Message from the owner, sent during the call: Ask for the earliest slot.", "created_at": "2026-01-01T00:00:03.000Z"])
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.shownLines.filter { $0.speaker == .you }.map(\.text), ["Ask for the earliest slot."])
        // A failure says why and takes the line back.
        samplehostStub.reset { seen in
            seen.path.hasSuffix("ai_assistant_add_messages") ? (422, ["errors": [["code": "1", "title": "Assistant not running"]]]) : script.route(seen)
        }
        let failed = await calls.tell(Self.callID, "Never mind")
        XCTAssertFalse(failed)
        XCTAssertEqual(calls.calls.first?.issue, "samplehost: Assistant not running")
        XCTAssertFalse(calls.calls.first?.shownLines.contains { $0.text == "Never mind" } ?? true)
        _ = await calls.endAll()
    }

    // MARK: Item 9: the result message, once

    @MainActor func testTheResultGoesToItsChatExactlyOnceAlsoAfterARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "phone-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = PhoneHistoryStore(directory: folder)
        let script = Script()
        samplehostStub.reset(script.route)
        var clock = Date(timeIntervalSince1970: 20_000)
        let calls = try controller(history: history)
        calls.now = { clock }
        var sent: [PhoneResultMessage] = []
        calls.chatSender = { _ in { sent.append($0) } }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Book a table for two")
        await calls.refresh(Self.callID)
        let question = try XCTUnwrap(calls.calls.first?.question)
        await calls.answer(Self.callID, question: question, with: "Morning")
        script.alive = false
        script.duration = 92
        script.events = Self.events(answered: true, ring: 4, talk: 92)
        await calls.refresh(Self.callID)
        XCTAssertTrue(calls.calls.first?.settled ?? false)
        XCTAssertTrue(sent.isEmpty, "waits for the transcript to go quiet")
        clock = clock.addingTimeInterval(7)
        await calls.refresh(Self.callID)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.display, "Call to +1 212 555 0142: finished, 1m 32s")
        let text = try XCTUnwrap(sent.first?.text)
        XCTAssertTrue(text.hasPrefix(PhoneResultMessage.header))
        XCTAssertTrue(text.contains("Goal: Book a table for two"))
        XCTAssertTrue(text.contains("Which simulated time works? → Morning"))
        XCTAssertTrue(text.contains("Them: The simulated recipient has a question."))
        await calls.refresh(Self.callID)
        XCTAssertEqual(sent.count, 1)
        // A relaunch reads the history: the call is there, already sent.
        let again = PhoneCallController(accountID: calls.accountID, store: store, history: history)
        again.autoPoll = false
        again.chatSender = { _ in { sent.append($0) } }
        again.makeAPI = calls.makeAPI
        XCTAssertEqual(again.calls.first?.result, .sent)
        await again.refresh(Self.callID)
        again.deliverPending(matching: { _ in true }) { sent.append($0) }
        XCTAssertEqual(sent.count, 1, "never twice")
    }

    @MainActor func testAResultWaitsForItsChatAndTheSwitchTurnsItOff() async throws {
        let script = Script()
        script.alive = false
        script.duration = 30
        script.events = Self.events(answered: true, ring: 4, talk: 30)
        samplehostStub.reset(script.route)
        let calls = try controller()
        calls.resultQuiet = 0
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.result, .pending, "the chat isn't open")
        var sent: [PhoneResultMessage] = []
        calls.deliverPending(matching: { $0.sessionID == "other" }) { sent.append($0) }
        XCTAssertTrue(sent.isEmpty, "another chat doesn't take it")
        calls.deliverPending(matching: { $0.sessionID == "s1" }) { sent.append($0) }
        calls.deliverPending(matching: { $0.sessionID == "s1" }) { sent.append($0) }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(calls.calls.first?.result, .sent)

        var off = PhoneSetup(apiKey: Self.key, fromNumber: "+15550100001", connectionID: "conn-1", assistantID: "assistant-1")
        off.sendResults = false
        let quiet = try controller("https://a.example.com|off", setup: off)
        quiet.resultQuiet = 0
        var never: [PhoneResultMessage] = []
        quiet.chatSender = { _ in { never.append($0) } }
        try await quiet.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await quiet.refresh(Self.callID)
        XCTAssertEqual(quiet.calls.first?.result, .off)
        XCTAssertTrue(never.isEmpty)
    }

    @MainActor func testSummaryArrivingAfterDeliveryUpdatesHistoryWithoutSendingTwice() async throws {
        let script = Script()
        script.summary = nil
        script.summaryPending = true
        script.alive = false
        script.duration = 30
        script.events = Self.events(answered: true, talk: 30)
        samplehostStub.reset(script.route)
        var clock = Date(timeIntervalSince1970: 20_000)
        let calls = try controller()
        calls.now = { clock }
        var sent: [PhoneResultMessage] = []
        calls.chatSender = { _ in { sent.append($0) } }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Book a table")
        await calls.refresh(Self.callID)
        clock = clock.addingTimeInterval(7)
        await calls.refresh(Self.callID)
        XCTAssertTrue(sent.isEmpty, "waits briefly while samplehost reports a pending insight")
        clock = clock.addingTimeInterval(1)
        await calls.refresh(Self.callID)
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(try XCTUnwrap(sent.first?.text).contains("Summary:"))
        script.summary = "Corner Bistro booked the table under Alex."
        clock = clock.addingTimeInterval(4)
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.summary, script.summary)
        XCTAssertTrue(calls.calls.first?.done == true)
        XCTAssertEqual(sent.count, 1)
    }

    @MainActor func testEmptyInsightDeliversToChatQuicklyWithoutWaitingForPendingLimit() async throws {
        let script = Script()
        script.summary = nil
        script.summaryPending = false
        script.alive = false
        script.duration = 25
        script.events = Self.events(answered: true, talk: 25)
        samplehostStub.reset(script.route)
        var clock = Date(timeIntervalSince1970: 20_000)
        let calls = try controller()
        calls.now = { clock }
        var sent: [PhoneResultMessage] = []
        calls.chatSender = { _ in { sent.append($0) } }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Check in")
        await calls.refresh(Self.callID)
        XCTAssertTrue(sent.isEmpty)
        clock = clock.addingTimeInterval(2.1)
        await calls.refresh(Self.callID)
        XCTAssertEqual(sent.count, 1, "empty insights deliver in ~2s instead of stalling for pending summary wait")
    }

    @MainActor func testAnsweredCallSettlesQuicklyFromCallDurationWhenEventLogLags() async throws {
        let script = Script()
        script.summary = nil
        script.summaryPending = false
        script.events = []   // samplehost event log is lagging behind
        samplehostStub.reset(script.route)
        var clock = Date(timeIntervalSince1970: 25_000)
        let calls = try controller()
        calls.now = { clock }
        var sent: [PhoneResultMessage] = []
        calls.chatSender = { _ in { sent.append($0) } }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Check in")
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.state, .live)
        script.alive = false
        script.duration = 42
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.state, .ended)
        XCTAssertEqual(calls.calls.first?.duration, 42, "call_duration is captured immediately from the first ended status read")
        XCTAssertFalse(calls.calls.first?.settled ?? true)
        clock = clock.addingTimeInterval(5)
        await calls.refresh(Self.callID)
        XCTAssertTrue(calls.calls.first?.settled ?? false, "answered calls settle after answeredEventsGiveUp without waiting 60s")
        XCTAssertEqual(calls.calls.first?.outcome, .finished)
        XCTAssertEqual(sent.count, 1, "transcript was already quiet since overAt, so chat populates immediately on settle")
    }

    @MainActor func testSummaryPollingStopsWhenItNeverArrives() async throws {
        let script = Script()
        script.summary = nil
        script.summaryPending = true
        script.alive = false
        script.events = Self.events(answered: true)
        samplehostStub.reset(script.route)
        var clock = Date(timeIntervalSince1970: 20_000)
        let calls = try controller()
        calls.now = { clock }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Book a table")
        await calls.refresh(Self.callID)
        clock = clock.addingTimeInterval(29)
        await calls.refresh(Self.callID)
        XCTAssertFalse(calls.calls.first?.done ?? true)
        let attempts = samplehostStub.seen.filter { $0.path.hasSuffix("/conversations-insights") }.count
        XCTAssertGreaterThan(attempts, 1)
        clock = clock.addingTimeInterval(1)
        await calls.refresh(Self.callID)
        XCTAssertEqual(samplehostStub.seen.filter { $0.path.hasSuffix("/conversations-insights") }.count, attempts)
        let call = try XCTUnwrap(calls.calls.first)
        XCTAssertTrue(call.done)
        XCTAssertEqual(PhoneCallPresentation.whatHappened(call), "The call finished.")
    }

    // MARK: Item 7: alerts

    @MainActor func testANewQuestionAlertsOnlyWhenItsSheetIsNotOnScreen() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller()
        var alerts: [PhoneAlert] = []
        calls.alert = { alerts.append($0) }
        calls.appActive = { true }
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        calls.sheetAppeared("s1")
        await calls.refresh(Self.callID)
        XCTAssertTrue(alerts.isEmpty, "the owner sees it on the sheet")
        calls.sheetDisappeared("s1")
        script.messages.append(Self.ask("call_ask_2", "Window or aisle?", at: "2026-01-01T00:00:09.000Z"))
        await calls.refresh(Self.callID)
        XCTAssertEqual(alerts, [.question(account: calls.accountID, session: "s1", profile: nil, call: Self.callID, text: "Window or aisle?")])
        await calls.refresh(Self.callID)
        XCTAssertEqual(alerts.count, 1, "once per question")
        let content = PhoneAlerts.content(alerts[0])
        XCTAssertEqual(content.body, "The assistant on your call asks: Window or aisle?")
        XCTAssertEqual(content.userInfo[PhoneAlerts.alertKey] as? String, Self.callID)
        XCTAssertEqual(PhoneAlerts.content(.stillGoing(account: "a", session: "s1", profile: nil, call: "c")).body,
                       "Your call is still going. Open Hermes HQ to follow it and answer questions.")
        _ = await calls.endAll()
    }

    // MARK: Item 8: history

    @MainActor func testHistoryKeepsCallsAcrossARelaunchAndNeverTheKey() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "phone-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = PhoneHistoryStore(directory: folder)
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller(history: history)
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.refresh(Self.callID)
        let file = history.file(for: calls.accountID)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains(Self.key), "never the key")
        XCTAssertTrue(saved.contains("Hello from the simulated agent."))
        XCTAssertFalse(file.lastPathComponent.contains("example"), "named by a hash")
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let relaunched = PhoneCallController(accountID: calls.accountID, store: store, history: history)
        relaunched.autoPoll = false
        XCTAssertEqual(relaunched.calls.map(\.id), [Self.callID])
        XCTAssertEqual(relaunched.calls.first?.lines, calls.calls.first?.lines)
        XCTAssertTrue(relaunched.calls.first?.active ?? false, "an unfinished call is checked again on load")
        relaunched.forgetHistory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        _ = await calls.endAll()
    }

    @MainActor func testClearHistoryKeepsACallStillOn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "phone-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = PhoneHistoryStore(directory: folder)
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller(history: history)
        try await calls.place(sessionID: "s1", to: "+12125550142", purpose: "Ask")
        await calls.hangup(Self.callID)
        calls.clearHistory()
        XCTAssertTrue(calls.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.file(for: calls.accountID).path))
    }
}
