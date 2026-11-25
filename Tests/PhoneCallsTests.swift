// Phone Calls (Beta) talks to samplehost directly. Every request here is answered by samplehostStub (a URLProtocol), never
// the network. The key is the synthetic "KEYTEST".
import Security
import XCTest
@testable import HermesHQNative

/// Records every request and answers it from `route`.
nonisolated final class samplehostStub: URLProtocol, @unchecked Sendable {
    struct Seen { let method: String; let url: URL; let headers: [String: String]; let body: Data? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [Seen] = []
    nonisolated(unsafe) private static var _route: (Seen) -> (Int, Any) = { _ in (404, [:]) }

    static var seen: [Seen] { lock.withLock { _seen } }
    static func reset(_ route: @escaping (Seen) -> (Int, Any)) { lock.withLock { _seen = []; _route = route } }
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [samplehostStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            body = data
        }
        let seen = Seen(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let route = Self.lock.withLock { Self._seen.append(seen); return Self._route }
        let (status, json) = route(seen)
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

nonisolated extension samplehostStub.Seen {
    var path: String { url.path }
    var json: [String: Any] { body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:] }
    var query: [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}

nonisolated final class PhoneCallsTests: XCTestCase {
    static let key = "KEYTEST"
    static let callID = "v3:sim+call/1"
    let store = PhoneKeyStore(service: "ai.hermes.hqnative.tests.samplehost")

    override func tearDown() { store.removeAll(); super.tearDown() }

    @MainActor func api(_ key: String = PhoneCallsTests.key) -> samplehostAPI {
        samplehostAPI(key: key, base: samplehostEndpoint.production, session: samplehostStub.session)
    }

    /// A controller for account `id` whose setup is saved and whose requests go to the stub.
    /// No polling task and no alerts or chat sends of its own: each test drives `refresh` and captures what it needs.
    @MainActor func controller(_ id: String = "https://a.example.com|a", now: Date = Date(), setup: PhoneSetup? = nil,
                               history: PhoneHistoryStore? = nil) throws -> PhoneCallController {
        try store.save(setup ?? PhoneSetup(apiKey: Self.key, fromNumber: "+15550100001", connectionID: "conn-1",
                                           assistantID: "assistant-1", assistantName: "Otto"), for: id)
        let made = PhoneCallController(accountID: id, store: store, history: history)
        made.makeAPI = { samplehostAPI(key: $0, base: samplehostEndpoint.production, session: samplehostStub.session) }
        made.now = { now }
        made.autoPoll = false
        made.alert = { _ in }
        made.chatSender = { _ in nil }
        return made
    }

    /// A scripted samplehost: one call, its conversation, an ask_owner question, hangup.
    nonisolated final class Script: @unchecked Sendable {
        var alive = true
        var hungUp = false
        /// What list-call-events answers (the real row shape).
        var events: [[String: Any]] = []
        var duration: Int? = nil
        var summary: String? = "The assistant completed the simulated call."
        var summaryPending = false
        /// The assistant's telephony_settings as get-an-assistant answers them; update-an-assistant replaces them.
        var telephony: [String: Any] = ["default_texml_app_id": "texml-1", "noise_suppression": "krisp",
                                        "recording_settings": ["enabled": false, "channels": "dual", "format": "mp3"]]
        var updateFails = false
        var model = "openai/gpt-4o"
        var messages: [[String: Any]] = [
            ["role": "assistant", "text": "Hello from the simulated agent.", "created_at": "2026-01-01T00:00:01.000Z"],
            ["role": "user", "text": "The simulated recipient has a question.", "created_at": "2026-01-01T00:00:02.000Z"],
            ["role": "assistant", "text": "", "created_at": "2026-01-01T00:00:03.000Z",
             "tool_calls": [["id": "call_ask_1", "type": "function",
                             "function": ["name": "ask_owner", "arguments": #"{"question":"Which simulated time works?","choices":["Morning","Afternoon"]}"#]]]],
            ["role": "tool", "text": "Error: request failed", "created_at": "2026-01-01T00:00:03.500Z"],
        ]
        func route(_ seen: samplehostStub.Seen) -> (Int, Any) {
            guard seen.headers["Authorization"] == "Bearer \(PhoneCallsTests.key)" else {
                return (401, ["errors": [["code": "10009", "title": "Authentication failed", "detail": "Could not understand the provided credentials."]]])
            }
            switch (seen.method, seen.path) {
            case ("POST", "/v2/calls"):
                return (200, ["data": ["call_control_id": PhoneCallsTests.callID, "call_leg_id": "leg-1", "call_session_id": "s", "is_alive": false, "record_type": "call"]])
            case ("GET", "/v2/ai/assistants/assistant-1"):
                return (200, ["id": "assistant-1", "name": "Otto", "model": model, "enabled_features": ["telephony"],
                              "greeting": "Hello", "telephony_settings": telephony])
            case ("POST", "/v2/ai/assistants/assistant-1"):
                if updateFails { return (500, ["errors": [["code": "500", "title": "Server error"]]]) }
                if let next = seen.json["telephony_settings"] as? [String: Any] { telephony = next }
                return (200, ["id": "assistant-1", "telephony_settings": telephony])
            case ("GET", "/v2/call_events"):
                return (200, ["data": events, "meta": ["total_pages": 1]])
            case ("GET", "/v2/ai/conversations"):
                return (200, ["data": [["id": "conv-1", "name": "", "created_at": "2026-01-01T00:00:00Z", "metadata": [:]]]])
            case ("GET", "/v2/ai/conversations/conv-1/messages"):
                return (200, ["data": Array(messages.reversed()), "meta": ["total_pages": 1, "total_results": messages.count, "page_number": 1, "page_size": 100]])
            case ("GET", "/v2/ai/conversations/conv-1/conversations-insights"):
                let rows: [[String: Any]]
                if let summary {
                    rows = [["status": "completed", "conversation_insights": [["result": summary]]]]
                } else if summaryPending {
                    rows = [["status": "pending", "conversation_insights": []]]
                } else {
                    rows = []
                }
                return (200, ["data": rows])
            case ("GET", "/v2/calls/\(PhoneCallsTests.callID)"):
                var data: [String: Any] = ["call_control_id": PhoneCallsTests.callID, "is_alive": alive, "record_type": "call"]
                if !alive, let duration { data["call_duration"] = duration }
                return (200, ["data": data])
            case ("POST", "/v2/calls/\(PhoneCallsTests.callID)/actions/ai_assistant_add_messages"):
                return (200, ["data": ["result": "ok"]])
            case ("POST", "/v2/calls/\(PhoneCallsTests.callID)/actions/hangup"):
                if hungUp { return (422, ["errors": [["code": "90018", "title": "Call has already ended", "detail": "This call is no longer active and can't receive commands."]]]) }
                hungUp = true; alive = false
                return (200, ["data": ["result": "ok"]])
            default: return (404, ["errors": [["code": "404", "title": "Not found"]]])
            }
        }
    }

    // MARK: Connect and list

    @MainActor func testConnectVerifiesKeyWithReadOnlyPhoneNumberList() async throws {
        samplehostStub.reset { _ in (200, ["data": [
            ["id": "1", "phone_number": "+15550100001", "status": "active", "connection_id": "conn-1", "connection_name": "Calls"],
            ["id": "2", "phone_number": "+15550100002", "status": "port-pending", "connection_id": "conn-1"],
        ], "meta": ["total_pages": 1]]) }
        let numbers = try await api().phoneNumbers()
        XCTAssertEqual(numbers.map(\.phone_number), ["+15550100001"], "only active numbers can call")
        XCTAssertEqual(numbers.first?.connection_id, "conn-1")
        let seen = try XCTUnwrap(samplehostStub.seen.first)
        XCTAssertEqual(seen.method, "GET")
        XCTAssertEqual(seen.url.host, "api.samplehost.com")
        XCTAssertEqual(seen.path, "/v2/phone_numbers")
        XCTAssertEqual(seen.query["page[size]"], "250")
        XCTAssertEqual(seen.headers["Authorization"], "Bearer KEYTEST")
        XCTAssertNil(seen.body)
    }

    @MainActor func testListsAssistants() async throws {
        samplehostStub.reset { _ in (200, ["data": [["id": "assistant-1", "name": "Otto", "created_at": "2026-01-01T00:00:00Z"]]]) }
        let assistants = try await api().assistants()
        XCTAssertEqual(assistants, [samplehostAssistant(id: "assistant-1", name: "Otto")])
        XCTAssertEqual(samplehostStub.seen.first?.path, "/v2/ai/assistants")
        XCTAssertEqual(samplehostStub.seen.first?.method, "GET")
    }

    @MainActor func testCreatesTheAssistantWithRequiredFieldsAndAnIdempotencyKey() async throws {
        samplehostStub.reset { _ in (200, ["id": "assistant-new", "name": "Hermes HQ Caller", "model": "default"]) }
        let made = try await api().createAssistant(idempotencyKey: "op-1")
        XCTAssertEqual(made, samplehostAssistant(id: "assistant-new", name: "Hermes HQ Caller"))
        let seen = try XCTUnwrap(samplehostStub.seen.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.path, "/v2/ai/assistants")
        XCTAssertEqual(seen.headers["Idempotency-Key"], "op-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: seen.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Hermes HQ Caller")
        XCTAssertFalse((body["instructions"] as? String ?? "").isEmpty)
        XCTAssertEqual(body["enabled_features"] as? [String], ["telephony"])
        XCTAssertEqual(body["greeting"] as? String, "")
        let transcription = try XCTUnwrap(body["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "deepgram/flux")
        let interruption = try XCTUnwrap(body["interruption_settings"] as? [String: Any])
        XCTAssertEqual(interruption["enable"] as? Bool, true)
        let telephony = try XCTUnwrap(body["telephony_settings"] as? [String: Any])
        XCTAssertEqual(telephony["noise_suppression"] as? String, "aicoustics")
        XCTAssertEqual(telephony["greeting_delay_ms"] as? Int, 400)
        XCTAssertEqual(telephony["user_idle_timeout_secs"] as? Int, 180)
        XCTAssertEqual(telephony["user_idle_reply_secs"] as? Int, 5)
        XCTAssertEqual((telephony["recording_settings"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertFalse(String(decoding: seen.body ?? Data(), as: UTF8.self).contains("KEYTEST"))
    }

    @MainActor func testOptimizeAssistantPreservesExistingTelephonyKeys() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        try await api().optimizeAssistant(id: "assistant-1", recording: false)
        let post = try XCTUnwrap(samplehostStub.seen.first { $0.method == "POST" && $0.path == "/v2/ai/assistants/assistant-1" })
        let sent = post.json
        XCTAssertEqual(sent["greeting"] as? String, "")
        XCTAssertEqual(sent["enabled_features"] as? [String], ["telephony"])
        XCTAssertEqual((sent["transcription"] as? [String: Any])?["model"] as? String, "deepgram/flux")
        XCTAssertEqual((sent["interruption_settings"] as? [String: Any])?["enable"] as? Bool, true)
        let telephony = try XCTUnwrap(sent["telephony_settings"] as? [String: Any])
        XCTAssertEqual(telephony["default_texml_app_id"] as? String, "texml-1", "preserves existing keys")
        XCTAssertEqual(telephony["noise_suppression"] as? String, "aicoustics")
        XCTAssertEqual(telephony["greeting_delay_ms"] as? Int, 400)
        XCTAssertEqual(telephony["user_idle_reply_secs"] as? Int, 5)
        XCTAssertEqual((telephony["recording_settings"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((telephony["recording_settings"] as? [String: Any])?["channels"] as? String, "dual")
    }

    @MainActor func testMessagesPaginateAcrossMultiplePages() async throws {
        samplehostStub.reset { seen in
            let page = Int(seen.query["page[number]"] ?? "1") ?? 1
            if page == 1 {
                return (200, ["data": [["role": "user", "text": "Second", "created_at": "2026-01-01T00:00:02Z"]],
                              "meta": ["total_pages": 2, "page_number": 1, "page_size": 100, "total_results": 2]])
            }
            return (200, ["data": [["role": "assistant", "text": "First", "created_at": "2026-01-01T00:00:01Z"]],
                          "meta": ["total_pages": 2, "page_number": 2, "page_size": 100, "total_results": 2]])
        }
        let messages = try await api().messages(conversationID: "conv-1")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(PhoneTranscript.read(messages, answered: []).lines.map(\.text), ["First", "Second"])
        XCTAssertEqual(samplehostStub.seen.count, 2)
    }

    @MainActor func testCallControlAppsListsOnlyActiveApps() async throws {
        samplehostStub.reset { _ in
            (200, ["data": [
                ["id": "cc-1", "application_name": "Main Voice", "active": true],
                ["id": "cc-2", "application_name": "Old Voice", "active": false],
            ]])
        }
        let apps = try await api().callControlApps()
        XCTAssertEqual(apps.map(\.id), ["cc-1"])
        XCTAssertEqual(samplehostStub.seen.first?.path, "/v2/call_control_applications")
    }

    @MainActor func testWrongKeyReadsAsBadKey() async {
        let script = Script()
        samplehostStub.reset(script.route)
        do { _ = try await api("OTHERKEY").phoneNumbers(); XCTFail("accepted") } catch {
            XCTAssertEqual(error as? samplehostError, .badKey)
            XCTAssertTrue(phoneMessage(error).contains("didn't accept this API key"))
        }
    }

    // MARK: Dial

    @MainActor func testDialSendsTheDocumentedFieldsAndTheSafetyStop() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller()
        let id = try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Book a table for two",
                                       name: "Corner Bistro", botName: "Otto")
        XCTAssertEqual(id, Self.callID)
        let autoOptimize = try XCTUnwrap(samplehostStub.seen.first { $0.method == "POST" && $0.path == "/v2/ai/assistants/assistant-1" })
        XCTAssertEqual((autoOptimize.json["telephony_settings"] as? [String: Any])?["noise_suppression"] as? String, "aicoustics",
                       "existing suboptimal assistant is auto-tuned before dialing")
        let dial = try XCTUnwrap(samplehostStub.seen.first { $0.path == "/v2/calls" })
        XCTAssertEqual(dial.method, "POST")
        let body = dial.json
        XCTAssertEqual(Set(body.keys), ["connection_id", "from", "to", "timeout_secs", "time_limit_secs", "command_id",
                                        "answering_machine_detection", "assistant"])
        XCTAssertEqual(body["connection_id"] as? String, "conn-1")
        XCTAssertEqual(body["from"] as? String, "+15550100001")
        XCTAssertEqual(body["to"] as? String, "+15550100002")
        XCTAssertEqual(body["time_limit_secs"] as? Int, 1800, "one 30-minute safety stop, no 60-second cap")
        XCTAssertEqual(body["timeout_secs"] as? Int, 45)
        XCTAssertEqual(body["answering_machine_detection"] as? String, "premium")
        XCTAssertFalse((body["command_id"] as? String ?? "").isEmpty)
        let assistant = try XCTUnwrap(body["assistant"] as? [String: Any])
        XCTAssertEqual(assistant["id"] as? String, "assistant-1")
        let greeting = assistant["greeting"] as? String ?? ""
        XCTAssertTrue(greeting.contains("Hi there, this is Otto."), "warm immediate greeting with bot name: \(greeting)")
        XCTAssertTrue(greeting.contains("book a table for two"), "context right in the pickup greeting: \(greeting)")
        XCTAssertFalse(greeting.localizedCaseInsensitiveContains("the owner"))
        XCTAssertFalse(String(decoding: dial.body ?? Data(), as: UTF8.self).contains("60 seconds"))
        let instructions = assistant["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("Book a table for two"))
        XCTAssertTrue(instructions.contains("You are calling Corner Bistro."))
        XCTAssertTrue(instructions.contains("Current local time:"))
        XCTAssertTrue(instructions.contains("ask_owner"))
        XCTAssertEqual(calls.calls.first?.botName, "Otto")
        let tools = try XCTUnwrap(assistant["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["type"] as? String }, ["webhook", "hangup"])
        let webhook = try XCTUnwrap(tools[0]["webhook"] as? [String: Any])
        XCTAssertEqual(webhook["name"] as? String, "ask_owner")
        XCTAssertEqual(webhook["url"] as? String, "https://ask-owner.invalid/hermes-hq", "the tool sends nothing anywhere")
        let parameters = try XCTUnwrap(webhook["body_parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["question"])
        XCTAssertEqual(calls.calls.map(\.id), [Self.callID])
        XCTAssertEqual(calls.calls.first?.state, .calling)
        _ = await calls.endAll()
    }

    @MainActor func testDialRetryReusesCommandIDAndOneCallAtATime() async throws {
        var fail = true
        let script = Script()
        samplehostStub.reset { seen in
            if seen.path == "/v2/calls", seen.method == "POST", fail { fail = false; return (500, ["errors": [["code": "500", "title": "Server error"]]]) }
            return script.route(seen)
        }
        let calls = try controller()
        do { try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask"); XCTFail("first dial should fail") } catch { }
        try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask")
        let dials = samplehostStub.seen.filter { $0.path == "/v2/calls" && $0.method == "POST" }
        XCTAssertEqual(dials.count, 2)
        XCTAssertEqual(dials[0].json["command_id"] as? String, dials[1].json["command_id"] as? String, "a retry can't place a second call")
        do { try await calls.place(sessionID: "s1", to: "+15550100003", purpose: "Other"); XCTFail("second live call allowed") } catch {
            XCTAssertTrue(phoneMessage(error).contains("Another call"))
        }
        XCTAssertEqual(samplehostStub.seen.filter { $0.path == "/v2/calls" && $0.method == "POST" }.count, 2)
        _ = await calls.endAll()
    }

    @MainActor func testNothingDialsWithoutAReadySetup() async throws {
        samplehostStub.reset { _ in (200, [:]) }
        try store.save(PhoneSetup(apiKey: Self.key), for: "acct")
        let calls = PhoneCallController(accountID: "acct", store: store)
        calls.makeAPI = { samplehostAPI(key: $0, base: samplehostEndpoint.production, session: samplehostStub.session) }
        XCTAssertFalse(calls.ready)
        do { try await calls.place(sessionID: "s", to: "+15550100002", purpose: "x"); XCTFail("dialed") } catch { }
        XCTAssertTrue(samplehostStub.seen.isEmpty)
    }

    // MARK: Transcript, question, answer

    @MainActor func testPollFindsConversationByCallControlIDAndOrdersTranscript() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask")
        await calls.refresh(Self.callID)
        let lookup = try XCTUnwrap(samplehostStub.seen.first { $0.path == "/v2/ai/conversations" })
        XCTAssertEqual(lookup.query["metadata->call_control_id"], "eq." + Self.callID)
        XCTAssertEqual(lookup.query["limit"], "1")
        XCTAssertTrue(lookup.url.absoluteString.contains("eq.v3%3Asim%2Bcall%2F1"), "a + or / in the id is escaped: \(lookup.url)")
        let messages = try XCTUnwrap(samplehostStub.seen.first { $0.path == "/v2/ai/conversations/conv-1/messages" })
        XCTAssertEqual(messages.query["page[size]"], "100")
        XCTAssertTrue(samplehostStub.seen.contains { $0.method == "GET" && $0.path == "/v2/calls/\(Self.callID)" })
        let call = try XCTUnwrap(calls.calls.first)
        XCTAssertEqual(call.state, .live)
        XCTAssertEqual(call.lines.map(\.text), ["Hello from the simulated agent.", "The simulated recipient has a question."])
        XCTAssertEqual(call.lines.map(\.speaker), [.assistant, .them])
        XCTAssertEqual(call.question, PhoneTranscript.Question(id: "call_ask_1", text: "Which simulated time works?", choices: ["Morning", "Afternoon"]))
        // A second refresh reuses the conversation id.
        await calls.refresh(Self.callID)
        XCTAssertEqual(samplehostStub.seen.filter { $0.path == "/v2/ai/conversations" }.count, 1)
        _ = await calls.endAll()
    }

    @MainActor func testQuestionDetectionFromToolCalls() {
        func ask(_ id: String, _ arguments: String?) -> samplehostMessage {
            samplehostMessage(role: "assistant", text: nil, tool_calls: [.init(id: id, type: "function", function: .init(name: "ask_owner", arguments: arguments))])
        }
        var read = PhoneTranscript.read([ask("a", #"{"question":"Yes?","choices":["Yes","No","Yes"," "]}"#)], answered: [])
        XCTAssertEqual(read.question, .init(id: "a", text: "Yes?", choices: ["Yes", "No"]))
        read = PhoneTranscript.read([ask("a", "not json")], answered: [])
        XCTAssertEqual(read.question?.text, "The assistant asked for your input.")
        XCTAssertEqual(read.question?.choices, [])
        XCTAssertNil(PhoneTranscript.read([ask("a", "{}")], answered: ["a"]).question, "answered here")
        let marked = samplehostMessage(role: "tool", text: PhoneAskOwner.toolAnswer("Morning", toolCallID: "a"))
        let fromConversation = PhoneTranscript.read([ask("a", "{}"), marked], answered: [])
        XCTAssertNil(fromConversation.question, "answered on another open of the sheet")
        XCTAssertEqual(fromConversation.answeredInConversation, ["a"])
        let other = samplehostMessage(role: "assistant", tool_calls: [.init(id: "b", function: .init(name: "lookup", arguments: "{}"))])
        XCTAssertNil(PhoneTranscript.read([other], answered: []).question, "other tools aren't questions")
        XCTAssertEqual(PhoneTranscript.read([ask("a", #"{"question":"One"}"#), ask("b", #"{"question":"Two"}"#)], answered: ["b"]).question?.id, nil,
                       "only the newest question is offered")
    }

    @MainActor func testAnswerGoesBackWithAddMessagesOnce() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask")
        await calls.refresh(Self.callID)
        let question = try XCTUnwrap(calls.calls.first?.question)
        await calls.answer(Self.callID, question: question, with: " Morning ")
        let add = samplehostStub.seen.filter { $0.path == "/v2/calls/\(Self.callID)/actions/ai_assistant_add_messages" }
        XCTAssertEqual(add.count, 1)
        let body = try XCTUnwrap(add.first?.json)
        XCTAssertEqual(body["trigger_response"] as? Bool, true)
        XCTAssertFalse((body["command_id"] as? String ?? "").isEmpty)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["tool", "system"])
        XCTAssertEqual(messages[0]["tool_call_id"] as? String, "call_ask_1")
        XCTAssertEqual(messages[0]["content"] as? String, "The owner answered (ref call_ask_1): Morning")
        XCTAssertTrue((messages[1]["content"] as? String ?? "").contains("Morning"))
        XCTAssertNil(calls.calls.first?.question)
        XCTAssertEqual(calls.calls.first?.lastAnswer, "Morning")
        await calls.answer(Self.callID, question: question, with: "Afternoon")
        XCTAssertEqual(samplehostStub.seen.filter { $0.path.hasSuffix("ai_assistant_add_messages") }.count, 1, "one answer per question")
        await calls.refresh(Self.callID)
        XCTAssertNil(calls.calls.first?.question, "the polled tool call stays answered")
        _ = await calls.endAll()
    }

    // MARK: Hangup and the end

    @MainActor func testHangupIsIdempotentAndAlreadyEndedCountsAsEnded() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask")
        await calls.hangup(Self.callID)
        let hangups = samplehostStub.seen.filter { $0.path == "/v2/calls/\(Self.callID)/actions/hangup" }
        XCTAssertEqual(hangups.count, 1)
        XCTAssertEqual(hangups.first?.method, "POST")
        XCTAssertFalse((hangups.first?.json["command_id"] as? String ?? "").isEmpty)
        XCTAssertEqual(calls.calls.first?.state, .ended)
        XCTAssertEqual(calls.calls.first?.statusText, "Ended", "the outcome is still being read from the event log")
        XCTAssertEqual(calls.calls.first?.endNote, "You hung up")
        await calls.hangup(Self.callID)
        await calls.refresh(Self.callID)
        XCTAssertEqual(samplehostStub.seen.filter { $0.path.hasSuffix("/actions/hangup") }.count, 1, "an ended call sends nothing")
        // samplehost's own "already ended" answer is success, not an error.
        let api = api()
        try await api.hangup(callControlID: Self.callID, commandID: "again")
    }

    @MainActor func testCallEndsWhensamplehostSaysItIsNotAlive() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask")
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.state, .live)
        script.alive = false
        script.duration = 12
        script.events = Self.events(answered: true, hangupCause: "normal_clearing")
        calls.resultQuiet = 0
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.state, .ended)
        XCTAssertEqual(calls.calls.first?.outcome, .finished)
        XCTAssertEqual(calls.calls.first?.statusText, "Finished · 12s")
        let before = samplehostStub.seen.count
        await calls.refresh(Self.callID)
        XCTAssertEqual(samplehostStub.seen.count, before, "polling stops once the call ended and its outcome is settled")
    }

    @MainActor func testRingingCallIsNotEndedEarly() async throws {
        let script = Script()
        script.alive = false
        samplehostStub.reset { seen in seen.path == "/v2/ai/conversations" ? (200, ["data": []]) : script.route(seen) }
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask")
        await calls.refresh(Self.callID)
        XCTAssertEqual(calls.calls.first?.state, .calling, "no conversation yet and within ring time")
        _ = await calls.endAll()
    }

    @MainActor func testAppHangsUpAtTheDeadline() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        var clock = Date(timeIntervalSince1970: 1_000)
        let calls = try controller()
        calls.now = { clock }
        try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask")
        XCTAssertEqual(calls.calls.first?.state, .calling)
        clock = clock.addingTimeInterval(91)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(calls.calls.first?.state, .calling, "no 60-second cap: a long call keeps going")
        clock = Date(timeIntervalSince1970: 1_000).addingTimeInterval(45 + 1800 + 1)
        for _ in 0..<40 where calls.calls.first?.state != .ended { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(calls.calls.first?.state, .ended)
        XCTAssertEqual(calls.calls.first?.endNote, "30-minute safety stop")
        XCTAssertEqual(samplehostStub.seen.filter { $0.path.hasSuffix("/actions/hangup") }.count, 1)
    }

    @MainActor func testHangupDeadline() {
        let placed = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(phoneHangupDeadline(placedAt: placed), placed.addingTimeInterval(45 + 1800), "ring time + 30 minutes")
        XCTAssertEqual(PhoneLimits.callSeconds, 1800)
        XCTAssertEqual(PhoneLimits.ringSeconds, 45)
    }

    // MARK: Errors

    @MainActor func testProviderErrorsShowsamplehostDetailNeverTheKey() async {
        let api = api()
        XCTAssertEqual(api.failure(status: 422, Data(#"{"errors":[{"code":"10004","title":"Missing required parameter","detail":"The 'to' parameter is required and cannot be blank."}]}"#.utf8)),
                       .provider("The 'to' parameter is required and cannot be blank."))
        XCTAssertEqual(api.failure(status: 422, Data(#"{"errors":[{"code":"10015","title":"Bad thing"}]}"#.utf8)), .provider("Bad thing"))
        XCTAssertEqual(api.failure(status: 422, Data(#"{"detail":[{"loc":["body"],"msg":"Field required","type":"missing"}]}"#.utf8)), .provider("Field required"))
        XCTAssertEqual(api.failure(status: 401, Data()), .badKey)
        XCTAssertEqual(api.failure(status: 502, Data("<html>gateway</html>".utf8)), .unexpected(502))
        let echoed = api.failure(status: 400, Data(#"{"errors":[{"code":"1","title":"x","detail":"Key KEYTEST is not valid"}]}"#.utf8))
        XCTAssertEqual(echoed, .provider("Key ••• is not valid"))
        XCTAssertFalse(phoneMessage(echoed).contains("KEYTEST"))
        samplehostStub.reset { _ in (422, ["errors": [["code": "10004", "title": "Missing", "detail": "The 'to' parameter is required and cannot be blank."]]]) }
        do { _ = try await api.dial(PhoneDialRequest(to: "", from: "+15550100001", connectionID: "c", assistantID: "a", purpose: "p", commandID: "x")); XCTFail() } catch {
            XCTAssertEqual(phoneMessage(error), "samplehost: The 'to' parameter is required and cannot be blank.")
        }
    }

    // MARK: The key

    @MainActor func testKeyNeverInURLsDescriptionsOrDefaults() async throws {
        let script = Script()
        samplehostStub.reset(script.route)
        let calls = try controller()
        try await calls.place(sessionID: "s1", to: "+15550100002", purpose: "Ask")
        await calls.refresh(Self.callID)
        if let question = calls.calls.first?.question { await calls.answer(Self.callID, question: question, with: "Morning") }
        await calls.hangup(Self.callID)
        XCTAssertGreaterThanOrEqual(samplehostStub.seen.count, 6)
        for seen in samplehostStub.seen {
            XCTAssertFalse(seen.url.absoluteString.contains(Self.key), "key in a URL: \(seen.url)")
            XCTAssertFalse(String(data: seen.body ?? Data(), encoding: .utf8)?.contains(Self.key) ?? false, "key in a body")
            XCTAssertEqual(seen.headers["Authorization"], "Bearer \(Self.key)")
            XCTAssertEqual(seen.url.scheme, "https")
            XCTAssertEqual(seen.url.host, "api.samplehost.com")
        }
        let api = api()
        var dumped = ""
        dump(api, to: &dumped)
        for text in [String(describing: api), String(reflecting: api), dumped, "\(samplehostError.badKey)", String(describing: calls.calls)] {
            XCTAssertFalse(text.contains(Self.key), text)
        }
        let defaults = UserDefaults.standard.dictionaryRepresentation().description
        XCTAssertFalse(defaults.contains(Self.key), "key in UserDefaults")
        _ = await calls.endAll()
    }

    @MainActor func testKeychainItemIsPerAccountDeviceOnlyAndDeletable() throws {
        let a = "https://gateway.example.com|otto", b = "https://gateway.example.com|wren"
        try store.save(PhoneSetup(apiKey: "KEYTEST-A", fromNumber: "+15550100001", connectionID: "c", assistantID: "x"), for: a)
        XCTAssertEqual(store.load(for: a)?.apiKey, "KEYTEST-A")
        XCTAssertNil(store.load(for: b), "another sign-in never sees this key")
        XCTAssertFalse(store.itemAccount(a).contains("otto"), "the item names a hash, not the account")
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                                    kSecAttrAccount as String: store.itemAccount(a), kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        query[kSecAttrSynchronizable as String] = true
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecItemNotFound, "never an iCloud Keychain item")
        try store.save(PhoneSetup(apiKey: "KEYTEST-B"), for: b)
        store.delete(for: a)
        XCTAssertNil(store.load(for: a))
        XCTAssertEqual(store.load(for: b)?.apiKey, "KEYTEST-B")
        XCTAssertFalse(PhoneCallController.shared(for: a) === PhoneCallController.shared(for: b), "each account has its own calls")
        XCTAssertTrue(PhoneCallController.shared(for: a) === PhoneCallController.shared(for: a))
    }

    // MARK: Where requests go

    @MainActor func testOnlysamplehostOverHTTPSAndALoopbackFakeInDebug() async {
        XCTAssertEqual(samplehostEndpoint.production.absoluteString, "https://api.samplehost.com/v2")
        XCTAssertEqual(samplehostEndpoint.base(environment: [:]), samplehostEndpoint.production)
        for bad in ["http://127.0.0.1:9/v2", "https://example.com/v2", "https://127.0.0.1.example.com/v2", "https://u:p@127.0.0.1/v2",
                    "https://127.0.0.1/v2?x=1", "https://localhost:9/v2"] {
            XCTAssertNil(samplehostEndpoint.loopback(bad), bad)
            XCTAssertEqual(samplehostEndpoint.base(environment: ["HQ_SAMPLEHOST_BASE_URL": bad]), samplehostEndpoint.production, bad)
        }
        XCTAssertEqual(samplehostEndpoint.base(environment: ["HQ_SAMPLEHOST_BASE_URL": "https://127.0.0.1:19979/v2"]).absoluteString,
                       "https://127.0.0.1:19979/v2", "DEBUG builds only (compiled out of Release)")
        samplehostStub.reset { _ in (200, ["data": []]) }
        let insecure = samplehostAPI(key: Self.key, base: URL(string: "http://api.samplehost.com/v2")!, session: samplehostStub.session)
        do { _ = try await insecure.phoneNumbers(); XCTFail("sent over HTTP") } catch { XCTAssertEqual(error as? samplehostError, .refusedURL) }
        XCTAssertTrue(samplehostStub.seen.isEmpty)
    }

    @MainActor func testUSNumbersTypedWithoutThePlusAreDialable() {
        let from = "+16155550100"
        for typed in ["2125550142", "212 555 0142", "(212) 555-0142", "212.555.0142", "12125550142", "+12125550142"] {
            XCTAssertEqual(phoneDestination(typed, from: from), "+12125550142", typed)
        }
        XCTAssertEqual(phoneDestination("+44 20 7946 0958", from: from), "+442079460958")
        XCTAssertFalse(phoneIsE164(phoneDestination("2125550142", from: "+442071234567")), "only a +1 caller assumes +1")
        for bad in ["5550123", "0155550142", "1155550142", "212555014"] {
            XCTAssertFalse(phoneIsE164(phoneDestination(bad, from: from)), bad)
        }
    }

    @MainActor func testE164AndRetryKey() {
        XCTAssertTrue(phoneIsE164("+15550100002"))
        for bad in ["15550100002", "+05550100002", "+1555", "+1 555 010 0002", "+1555010000212345", ""] { XCTAssertFalse(phoneIsE164(bad), bad) }
        var retry = PhoneStartRetry()
        let first = PhoneStartIntent(session: "s1", destination: "+15550101", goal: "Ask")
        let id = retry.id(for: first)
        XCTAssertEqual(id, retry.id(for: first))
        XCTAssertNotEqual(id, retry.id(for: PhoneStartIntent(session: "s2", destination: first.destination, goal: first.goal)))
        let next = retry.id(for: first)
        retry.completed()
        XCTAssertNotEqual(next, retry.id(for: first))
    }
}
