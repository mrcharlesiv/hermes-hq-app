// Phone Calls (Beta) round 2: the pure pieces (no requests). Outcomes, the item-12 note, voicemail wording, the
// transcript reader, instructions and greeting, event rows, history, the result message, the call note, the
// proposal link and Check my setup. Numbers are 212 555 01xx stand-ins; the owner is "Alex".
import Foundation
import Testing
@testable import HermesHQNative

struct PhoneOutcomeTests {
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_000_000)
    nonisolated static func event(_ name: String, _ at: Double, result: String? = nil, cause: String? = nil) -> PhoneCallEvent {
        PhoneCallEvent(name: name, occurredAt: t0.addingTimeInterval(at), result: result, hangupCause: cause)
    }
    nonisolated static func answered(ring: Double = 4, talk: Double = 92, machine: Bool = false, cause: String = "normal_clearing") -> [PhoneCallEvent] {
        [event("call.initiated", 0), event("call.answered", ring),
         event("call.machine.premium.detection.ended", ring + 1, result: machine ? "machine" : "human"),
         event("call.hangup", ring + talk, cause: cause)]
    }
    nonisolated static func unanswered(_ cause: String) -> [PhoneCallEvent] { [event("call.initiated", 0), event("call.hangup", 30, cause: cause)] }

    @Test(arguments: [
        ("finished", answered(), [String](), PhoneOutcome.finished, "Finished · 1m 32s"),
        ("machine", answered(ring: 1, talk: 23, machine: true), [], .voicemail, "Went to voicemail · 23s"),
        ("wording", answered(ring: 6, talk: 23), ["Please leave a message after the tone."], .voicemail, "Went to voicemail · 23s"),
        ("no answer", unanswered("no_answer"), [], .noAnswer, "No answer"),
        ("timeout", unanswered("timeout"), [], .noAnswer, "No answer"),
        ("cancel", unanswered("originator_cancel"), [], .noAnswer, "No answer"),
        ("ring ran out", unanswered("normal_clearing"), [], .noAnswer, "No answer"),
        ("busy", unanswered("user_busy"), [], .busy, "Busy"),
        ("declined", unanswered("call_rejected"), [], .declined, "Declined"),
        ("unallocated", unanswered("unallocated_number"), [], .noSuchNumber, "Couldn't connect: that number doesn't exist"),
        ("format", unanswered("invalid_number_format"), [], .noSuchNumber, "Couldn't connect: that number doesn't exist"),
        ("out of order", unanswered("destination_out_of_order"), [], .couldNotConnect("the other phone is out of service"),
         "Couldn't connect: the other phone is out of service"),
        ("odd cause", unanswered("bearer_capability_not_available"), [], .couldNotConnect("bearer capability not available"),
         "Couldn't connect: bearer capability not available"),
    ] as [(String, [PhoneCallEvent], [String], PhoneOutcome, String)])
    func everyOutcomeFromTheLog(name: String, events: [PhoneCallEvent], said: [String], outcome: PhoneOutcome, title: String) {
        let verdict = PhoneVerdict.derive(events: events, status: nil, theirLines: said, ended: true, localEnd: nil, gaveUp: false)
        #expect(verdict.settled, "\(name)")
        #expect(verdict.outcome == outcome, "\(name)")
        #expect(phoneOutcomeTitle(outcome, duration: verdict.duration) == title, "\(name)")
    }

    @Test func notSettledUntilTheLogShowsTheHangup() {
        let early = [Self.event("call.initiated", 0), Self.event("call.answered", 3)]
        let live = PhoneVerdict.derive(events: early, status: nil, theirLines: [], ended: false, localEnd: nil, gaveUp: false)
        #expect(!live.settled && live.outcome == nil)
        #expect(live.answeredAt == Self.t0.addingTimeInterval(3))
        let over = PhoneVerdict.derive(events: early, status: nil, theirLines: [], ended: true, localEnd: .youHungUp, gaveUp: false)
        #expect(!over.settled, "\"Ended\" while the log catches up")
        let late = PhoneVerdict.derive(events: early, status: samplehostCallStatus(call_duration: 40), theirLines: [], ended: true,
                                       localEnd: .youHungUp, gaveUp: true)
        #expect(late.settled && late.outcome == .finished && late.duration == 40, "read long enough: what is known")
        let nothing = PhoneVerdict.derive(events: [], status: nil, theirLines: [], ended: true, localEnd: .youHungUp, gaveUp: true)
        #expect(nothing.outcome == .noAnswer, "you hung up before anyone picked up")
        let unknown = PhoneVerdict.derive(events: [], status: nil, theirLines: [], ended: true, localEnd: nil, gaveUp: true)
        #expect(unknown.outcome == .unknown)
        #expect(phoneOutcomeTitle(.unknown, duration: nil) == "Ended")
    }

    @Test func ringTimeIsAnsweredMinusInitiated() {
        let verdict = PhoneVerdict.derive(events: Self.answered(ring: 2.5).shuffled(), status: nil, theirLines: [], ended: true,
                                          localEnd: nil, gaveUp: false)
        #expect(verdict.ringSeconds == 2.5)
        #expect(verdict.duration == 92, "answered to hangup")
        let fromStatus = PhoneVerdict.derive(events: Self.answered(), status: samplehostCallStatus(call_duration: 95), theirLines: [],
                                             ended: true, localEnd: nil, gaveUp: false)
        #expect(fromStatus.duration == 95, "call_duration wins")
    }

    @Test func straightToVoicemailNote() {
        #expect(phoneStraightToVoicemailNote(voicemail: true, ringSeconds: 0.8)
                == "Voicemail picked up in 1 second, so the phone probably never rang. That is the other phone or its carrier (Do Not Disturb or a Focus, Silence Unknown Callers, a spam filter), not your samplehost setup.")
        #expect(phoneStraightToVoicemailNote(voicemail: true, ringSeconds: 2.4)?.hasPrefix("Voicemail picked up in 2 seconds,") == true)
        #expect(phoneStraightToVoicemailNote(voicemail: true, ringSeconds: 3) == nil, "under 3 seconds only")
        #expect(phoneStraightToVoicemailNote(voicemail: false, ringSeconds: 1) == nil)
        #expect(phoneStraightToVoicemailNote(voicemail: true, ringSeconds: nil) == nil)
    }

    @Test(arguments: ["Please record your message at the tone.", "You have reached the voicemail of 212 555 0142",
                      "Leave a message after the beep", "The person you are calling is not available", "I can’t take your call",
                      "The mailbox is full"])
    func voicemailWording(_ said: String) { #expect(phoneSoundsLikeVoicemail(said)) }

    @Test(arguments: ["Hello, dental office, how can I help?", "Sure, Tuesday works.", "Can you call back later?",
                      "7pm is not available, how about 8?", "Dr. Smith isn't available today, want to leave a message with me?",
                      "Did you check your voicemail earlier?"])
    func notVoicemail(_ said: String) { #expect(!phoneSoundsLikeVoicemail(said)) }

    @Test func amdClassificationsAndMultiTurnHumanProtection() {
        let beepOnly = [Self.event("call.initiated", 0), Self.event("call.answered", 2),
                        Self.event("call.machine.premium.greeting.ended", 4, result: "beep_detected"),
                        Self.event("call.hangup", 8, cause: "normal_clearing")]
        #expect(PhoneVerdict.derive(events: beepOnly, status: nil, theirLines: [], ended: true, localEnd: nil, gaveUp: false).outcome == .voicemail)

        let stdMachine = [Self.event("call.initiated", 0), Self.event("call.answered", 2),
                          Self.event("call.machine.detection.ended", 4, result: "machine_end_beep"),
                          Self.event("call.hangup", 8, cause: "normal_clearing")]
        #expect(PhoneVerdict.derive(events: stdMachine, status: nil, theirLines: [], ended: true, localEnd: nil, gaveUp: false).outcome == .voicemail)

        let humanConversation = [Self.event("call.initiated", 0), Self.event("call.answered", 3),
                                 Self.event("call.machine.premium.detection.ended", 4, result: "human_residence"),
                                 Self.event("call.hangup", 40, cause: "normal_clearing")]
        let multiTurn = ["Hello?", "Yeah, let me check.", "Sorry, please leave a message after the tone is what my other phone says."]
        #expect(PhoneVerdict.derive(events: humanConversation, status: nil, theirLines: multiTurn, ended: true, localEnd: nil, gaveUp: false).outcome == .finished)

        let startFailed = [Self.event("call.initiated", 0), Self.event("call.answered", 2),
                           PhoneCallEvent(name: "call.conversation.start_failed", occurredAt: Self.t0.addingTimeInterval(3), detail: "provider error"),
                           Self.event("call.hangup", 4, cause: "normal_clearing")]
        #expect(PhoneVerdict.derive(events: startFailed, status: nil, theirLines: [], ended: true, localEnd: nil, gaveUp: false).outcome == .couldNotConnect("provider error"))
    }

    @Test func durationsAndStatusWords() {
        #expect(phoneDuration(23) == "23s")
        #expect(phoneDuration(92) == "1m 32s")
        #expect(phoneDuration(3720) == "1h 2m")
        #expect(phoneShown("+12125550142") == "+1 212 555 0142")
        #expect(phoneShown("+442079460958") == "+442079460958")
        var call = PhoneCallRecord(id: "c", sessionID: "s", to: "+12125550142", purpose: "p", placedAt: Self.t0, hangupCommandID: "h")
        #expect(call.statusText == "Ringing…")
        call.state = .live
        #expect(call.statusText == "On the call")
        call.voicemail = true
        #expect(call.statusText == "Voicemail answered")
        call.state = .ended
        #expect(call.statusText == "Ended")
        call.outcome = .voicemail; call.duration = 23
        #expect(call.statusText == "Went to voicemail · 23s")
    }

    @Test func eventRowsDecodeTheRealShape() throws {
        let json = """
        {"data":[{"record_type":"call_event","call_leg_id":"leg-1","call_session_id":"s-1","name":"call.hangup","type":"webhook",
          "occurred_at":"2026-11-21 12:36:49.554602","metadata":{},
          "payload":{"event_type":"call.hangup","payload":{"hangup_cause":"normal_clearing","hangup_source":"callee","sip_hangup_cause":"unspecified"}}},
         {"record_type":"call_event","name":"call.machine.premium.detection.ended","type":"webhook","occurred_at":"2026-11-21T12:36:41Z",
          "payload":{"event_type":"call.machine.premium.detection.ended","payload":{"result":"machine"}}},
         {"payload":{"event_type":"call.answered","payload":{}},"occurred_at":"2026-11-21 12:36:40"}]}
        """
        struct Rows: Decodable { let data: [PhoneCallEvent] }
        let rows = try JSONDecoder().decode(Rows.self, from: Data(json.utf8)).data
        #expect(rows.map(\.name) == ["call.hangup", "call.machine.premium.detection.ended", "call.answered"], "name, else event_type")
        #expect(rows[0].hangupCause == "normal_clearing" && rows[0].hangupSource == "callee")
        #expect(rows[1].result == "machine")
        let base = try #require(PhoneCallEvent.date("2026-11-21 12:36:40"))
        #expect(abs(try #require(rows[0].occurredAt).timeIntervalSince(base) - 9.554602) < 0.0001, "space, microseconds, UTC")
        #expect(rows[1].occurredAt == base.addingTimeInterval(1))
        #expect(PhoneCallEvent.date("2026-11-21 12:36:40.5+02:00") == base.addingTimeInterval(0.5 - 7200))
        #expect(PhoneCallEvent.date("yesterday") == nil)
        // The app's own saved copy reads back the same.
        let again = try JSONDecoder.phone.decode([PhoneCallEvent].self, from: JSONEncoder.phone.encode(rows))
        #expect(again.map(\.name) == rows.map(\.name))
        #expect(again.map(\.result) == rows.map(\.result) && again.map(\.hangupCause) == rows.map(\.hangupCause))
        for (a, b) in zip(again, rows) {   // seconds as a JSON number: exact to well under a millisecond
            #expect(abs((a.occurredAt ?? .distantPast).timeIntervalSince(b.occurredAt ?? .distantFuture)) < 0.001)
        }
    }
}

struct PhoneTranscriptReaderTests {
    static func ask(_ id: String, _ q: String) -> samplehostMessage {
        samplehostMessage(role: "assistant", text: nil, tool_calls: [.init(id: id, type: "function", function: .init(name: "ask_owner", arguments: #"{"question":"\#(q)"}"#))])
    }

    @Test func hidesReceiptsSilenceAndEmotionTagsAndShowsYouLines() {
        let read = PhoneTranscript.read([
            samplehostMessage(role: "assistant", text: #"<emotion value="happy"/> Hi there!"#),
            samplehostMessage(role: "user", text: "Hello? <emotion name=\"calm\">Who is this?</emotion>"),
            samplehostMessage(role: "user", text: "   "),
            Self.ask("a", "Which day?"),
            samplehostMessage(role: "tool", text: #"{"http_status":422,"error":"unreachable"}"#),
            samplehostMessage(role: "tool", text: #"{"data":{"result":"ok"}}"#),
            samplehostMessage(role: "system", text: "[long silence]"),
            samplehostMessage(role: "tool", text: PhoneAskOwner.toolAnswer("Friday", toolCallID: "a")),
            samplehostMessage(role: "system", text: "The owner answered your question \"Which day?\": Friday. Tell the person now, then continue."),
            samplehostMessage(role: "system", text: PhoneAskOwner.ownerMessagePrefix + "Ask for a window seat."),
        ], answered: [])
        #expect(read.lines.map(\.text) == ["Hi there!", "Hello? Who is this?", "Friday", "Ask for a window seat."])
        #expect(read.lines.map(\.speaker) == [.assistant, .them, .you, .you])
        #expect(read.question == nil)
        #expect(read.answers == ["a": "Friday"])
        #expect(read.asked.map(\.text) == ["Which day?"])
    }

    @Test func duplicatesShowOnceWithEveryOpenID() {
        let read = PhoneTranscript.read([Self.ask("a", "Is 3 OK?"), Self.ask("b", "Other?"), Self.ask("c", " is 3 ok? ")], answered: [])
        #expect(read.question?.id == "c")
        #expect(read.question?.ids == ["c", "a"], "the same words, any case")
        let oneAnswered = PhoneTranscript.read([Self.ask("a", "Is 3 OK?"), Self.ask("c", "Is 3 OK?")], answered: ["a"])
        #expect(oneAnswered.question?.ids == ["c"])
        // Our two tool messages for one answer read back as one You line.
        let back = PhoneTranscript.read([Self.ask("a", "Is 3 OK?"), Self.ask("c", "Is 3 OK?"),
                                         samplehostMessage(role: "tool", text: PhoneAskOwner.toolAnswer("Yes", toolCallID: "c")),
                                         samplehostMessage(role: "tool", text: PhoneAskOwner.toolAnswer("Yes", toolCallID: "a"))], answered: [])
        #expect(back.lines.map(\.text) == ["Yes"])
        #expect(back.question == nil)
    }

    @Test func ordersNewestFirstEvenWhenOneRowLacksTimestampAndStripsBreakTags() {
        let newestFirst = [
            samplehostMessage(role: "user", text: "Third <break time=\"200ms\"/> line", created_at: "2026-01-01T00:00:03.000Z"),
            samplehostMessage(role: "assistant", text: "Second <pause/> line", created_at: nil),
            samplehostMessage(role: "assistant", text: "First line", created_at: "2026-01-01T00:00:01.000Z"),
        ]
        let read = PhoneTranscript.read(newestFirst, answered: [])
        #expect(read.lines.map(\.text) == ["First line", "Second line", "Third line"])
    }
}

struct PhoneWordsTests {
    @Test func warmGreetingForSelfThirdPartyAndCustom() {
        #expect(PhoneAskOwner.storedGreeting == "")

        // Self-call with no ownerName set: warm, uses bot name, never says "on behalf of the owner".
        let selfTest = PhoneAskOwner.greeting(botName: "Otto", ownerName: "", callingOwner: true,
                                              purpose: "Just testing the phone call")
        #expect(selfTest.contains("Hey, it's Otto!"))
        #expect(selfTest.contains("quick test call"))
        #expect(!selfTest.localizedCaseInsensitiveContains("the owner"))
        #expect(!selfTest.contains("—"))

        // Self-call with ownerName and clean action purpose.
        let selfNamed = PhoneAskOwner.greeting(botName: "Otto", ownerName: "Alex Mercer", callingOwner: true,
                                               purpose: "Go over today's schedule")
        #expect(selfNamed.contains("Hey Alex, it's Otto!"))
        #expect(selfNamed.contains("go over today's schedule"))

        // Third-party call with ownerName + clean purpose + recording enabled.
        let bistro = PhoneAskOwner.greeting(botName: "Hermes", ownerName: "Alex", calleeName: "Corner Bistro",
                                            callingOwner: false, purpose: "Book a table for two tonight at 7",
                                            recorded: true)
        #expect(bistro.contains("Hi there, this is Hermes calling for Alex."))
        #expect(bistro.contains("this call is being recorded"))
        #expect(bistro.contains("book a table for two tonight at 7"))

        // Third-party call with blank ownerName and third-person pronoun ("they"): never says "the owner" or echoes "they".
        let noOwner = PhoneAskOwner.greeting(botName: "", ownerName: "", calleeName: "Corner Bistro",
                                             callingOwner: false, purpose: "Ask if they have patio seating")
        #expect(noOwner.contains("Hi there, this is Hermes."))
        #expect(!noOwner.localizedCaseInsensitiveContains("the owner"))
        #expect(!noOwner.localizedCaseInsensitiveContains("if they"))

        // Custom agent-supplied greeting passes through cleanly and appends recording notice when recorded.
        let custom = PhoneAskOwner.greeting(botName: "Otto", ownerName: "Alex", callingOwner: true,
                                            purpose: "Weekend trip",
                                            customGreeting: "Hey Alex, it's Otto! Ready to talk through the weekend trip?",
                                            recorded: true)
        #expect(custom.hasPrefix("Hey Alex, it's Otto! Ready to talk through the weekend trip?"))
        #expect(custom.contains("this call is being recorded"))
    }

    @Test func infersCallingOwnerEvenWithoutOwnerName() {
        #expect(PhoneAskOwner.infersCallingOwner(ownerName: "", calleeName: "Me", purpose: "Check in"))
        #expect(PhoneAskOwner.infersCallingOwner(ownerName: "", calleeName: "myself", purpose: "Hi"))
        #expect(PhoneAskOwner.infersCallingOwner(ownerName: "", calleeName: "", purpose: "Call me to test the voice"))
        #expect(PhoneAskOwner.infersCallingOwner(ownerName: "", calleeName: "", purpose: "Check in with me about today"))
        #expect(PhoneAskOwner.infersCallingOwner(ownerName: "Alex Mercer", calleeName: "Alex", purpose: "Schedule"))
        #expect(!PhoneAskOwner.infersCallingOwner(ownerName: "Alex", calleeName: "Corner Bistro", purpose: "Ask them to call me back"))
        #expect(!PhoneAskOwner.infersCallingOwner(ownerName: "", calleeName: "", purpose: "Ask if they can call me back"))
        #expect(!PhoneAskOwner.infersCallingOwner(ownerName: "", calleeName: "", purpose: "Have the dentist call me"))
        #expect(!PhoneAskOwner.infersCallingOwner(ownerName: "", calleeName: "", purpose: "Book a table for two at 7"))
    }

    @Test func instructionsPieces() {
        let fixed = Date(timeIntervalSince1970: 1_763_995_200)
        let spoken = PhoneAskOwner.greeting(botName: "Otto", ownerName: "Alex", calleeName: "Bright Dental",
                                            purpose: "Move the cleaning to next week", recorded: true)
        let text = PhoneAskOwner.instructions(purpose: "Move the cleaning to next week", ownerName: "Alex",
                                              calleeName: "Bright Dental", botName: "Otto", greeting: spoken,
                                              chatContext: "User: Move my cleaning please.", recorded: true,
                                              voicemail: .hangUp, now: fixed)
        for piece in ["You are Otto, an AI voice assistant placing an outbound phone call for Alex.",
                      "You are calling Bright Dental.", "Current local time:",
                      "Opening line already spoken when they picked up:",
                      "Do not repeat that opening line word for word",
                      "Purpose of the call: Move the cleaning to next week",
                      "Recent chat context for background",
                      "User: Move my cleaning please.",
                      "Be warm, relaxed, polite, and socially natural",
                      "Stay on the call until the goal is done", "Do not end the call just because it is taking long",
                      "call the ask_owner tool once", "its result is a receipt, never the answer",
                      "never call ask_owner twice for the same question", "starting with \"The owner answered\"",
                      "\"Message from the owner\"", "call is being recorded",
                      "hang up right away using the hangup tool without saying anything"] {
            #expect(text.contains(piece), "\(piece)")
        }
        #expect(!text.contains("60"), "no time allotment")
        #expect(!text.contains("—"), "no em dashes")
        #expect(!text.contains("call back"), "hang up says nothing, so no call-back rule")

        let callingOwner = PhoneAskOwner.instructions(purpose: "Go over today's schedule", ownerName: "Alex",
                                                      calleeName: "alex", botName: "Otto", recorded: false,
                                                      voicemail: .leaveMessage, now: fixed)
        #expect(callingOwner.contains("You are Otto, Alex's personal AI voice assistant, calling Alex directly on the phone."))
        #expect(callingOwner.contains("Never say you are \"calling on behalf of\" anyone"))
        #expect(!callingOwner.contains("—"), "no em dashes")

        let plain = PhoneAskOwner.instructions(purpose: "p", ownerName: "", recorded: false, voicemail: .leaveMessage, now: fixed)
        #expect(plain.contains("never say \"the owner\" or \"calling on behalf of the owner\" aloud"))
        #expect(!plain.contains("recorded"))
        for piece in ["leave one short friendly message, then hang up", "one plain sentence of your own",
                      "never read notes or typos out as written",
                      "Do not ask anyone to call back unless the purpose asks for a call back",
                      "say it is a quick test call and that no reply is needed"] {
            #expect(plain.contains(piece), "\(piece)")
        }
        #expect(PhoneLimits.stayCopy == "The assistant stays on until the job is done. Safety stop at 30 minutes.")
        #expect(PhoneLocalEnd.safetyStop.note == "30-minute safety stop")
    }
}

struct PhoneHistoryTests {
    static func call(_ n: Int, lines: Int = 1) -> PhoneCallRecord {
        var c = PhoneCallRecord(id: "call-\(n)", sessionID: "s", to: "+12125550142", purpose: "p",
                                placedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + n)), hangupCommandID: "h")
        c.lines = (0..<lines).map { PhoneTranscript.Line(id: "\($0)", speaker: .them, text: "line \($0)") }
        c.events = [PhoneCallEvent(name: "call.hangup", occurredAt: Date(timeIntervalSince1970: 5), hangupCause: "user_busy")]
        c.outcome = .couldNotConnect("a reason"); c.settled = true; c.result = .sent; c.state = .ended
        c.answerCommandIDs = ["q": "transient"]
        return c
    }

    @Test func roundTripCapAndDelete() throws {
        let store = PhoneHistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "phone-pure-\(UUID().uuidString)"))
        defer { store.removeAll() }
        store.save([Self.call(1, lines: 2)], for: "acct-a")
        let back = store.load(for: "acct-a")
        var expected = Self.call(1, lines: 2)
        expected.answerCommandIDs = [:]   // in-flight state isn't saved
        #expect(back == [expected])
        #expect(store.load(for: "acct-b").isEmpty, "per account")
        store.save((1...60).map { Self.call($0, lines: $0 == 60 ? 320 : 1) }, for: "acct-a")
        let capped = store.load(for: "acct-a")
        #expect(capped.count == 50)
        #expect(capped.first?.id == "call-11", "the newest 50")
        #expect(capped.last?.lines.count == 300)
        #expect(capped.last?.lines.first?.text == "line 20", "the end of a long call is kept")
        #expect(store.file(for: "acct-a").lastPathComponent.count == 64 + 5, "sha256 hex + .json")
        store.delete(for: "acct-a")
        #expect(store.load(for: "acct-a").isEmpty)
    }
}

struct PhoneChatTextTests {
    static func ended(_ lines: [PhoneTranscript.Line]) -> PhoneCallRecord {
        var c = PhoneCallRecord(id: "c", sessionID: "s", to: "+12125550142", purpose: "Move my appointment",
                                placedAt: Date(timeIntervalSince1970: 0), hangupCommandID: "h")
        c.state = .ended; c.outcome = .finished; c.duration = 92; c.settled = true
        c.lines = lines
        c.asked = [PhoneQA(question: "Is Tuesday OK?", answer: "Yes"), PhoneQA(question: "Morning?", answer: nil)]
        return c
    }

    @Test func resultMessage() {
        let message = PhoneResultMessage(Self.ended([.init(id: "1", speaker: .assistant, text: "Hello"), .init(id: "2", speaker: .them, text: "Hi"),
                                                     .init(id: "3", speaker: .you, text: "Yes")]))
        #expect(message.display == "Call to +1 212 555 0142: finished, 1m 32s")
        #expect(message.text == """
        Phone call result (sent by Hermes HQ, not typed by the person)
        To: +12125550142
        Goal: Move my appointment
        Outcome: finished, 1m 32s
        Questions the assistant asked and the answers: \nIs Tuesday OK? → Yes
        Morning? → (not answered)
        Transcript:
        Assistant: Hello
        Them: Hi
        You: Yes
        """)
        #expect(PhoneResultMessage.bubble(forStored: message.text) == message.display, "after a relaunch too")
        #expect(PhoneResultMessage.bubble(forStored: "To: +1") == nil)
    }

    @Test func longTranscriptKeepsTheEndAndSaysItWasCut() {
        let lines = (0..<400).map { PhoneTranscript.Line(id: "\($0)", speaker: .them, text: "Line number \($0) of a long call.") }
        let text = PhoneResultMessage(Self.ended(lines)).text
        let transcript = String(text[text.range(of: "Transcript:\n")!.upperBound...])
        #expect(transcript.hasPrefix(PhoneResultMessage.cutMark + "\nThem: Line number"), "starts at a whole line")
        #expect(transcript.hasSuffix("Them: Line number 399 of a long call."))
        #expect(transcript.count <= PhoneResultMessage.transcriptLimit + PhoneResultMessage.cutMark.count + 1)
        #expect(!transcript.contains("Line number 0 of"))
    }

    @Test(arguments: [("Can you call the dentist?", true), ("CALLING them now", true), ("phone my mum", true), ("ring the shop", true),
                      ("dial it", true), ("check my voicemail", true), ("calls today", true), ("recall the plan", false),
                      ("the callback url", false), ("a phoneme", false), ("ringtone", false), ("hello", false)])
    func callNoteTrigger(typed: String, mentions: Bool) {
        #expect(PhoneChatNote.mentionsCalling(typed) == mentions, "\(typed)")
        #expect((PhoneChatNote.note(for: typed, ready: true, scheme: "hermeshq") != nil) == mentions, "\(typed)")
        #expect(PhoneChatNote.note(for: typed, ready: false, scheme: "hermeshq") == nil, "only when Phone Calls is ready")
    }

    @Test func callNoteTextAndStripping() throws {
        let note = PhoneChatNote.text(scheme: "hermeshq")
        #expect(note.hasPrefix("(Hermes HQ: this person can place AI phone calls from the app."))
        #expect(note.contains("cannot see your full chat history or memory"))
        #expect(note.contains("hermeshq://phone-call?to=%2B12125550142&name="))
        #expect(note.contains("&self=1"))
        #expect(note.contains("&greeting="))
        #expect(note.hasSuffix("If you don't have the number, ask for it or look it up first.)"))
        let sent = "Call the dentist and move my appointment" + "\n\n" + note
        #expect(PhoneChatNote.stripped(sent, scheme: "hermeshq") == "Call the dentist and move my appointment")
        #expect(PhoneChatNote.stripped("Call the dentist", scheme: "hermeshq") == nil)
        #expect(PhoneChatNote.note(for: sent, ready: true, scheme: "hermeshq") == nil, "never twice")
        // Legacy notes (v1, v2, and Round 1) also strip cleanly.
        #expect(PhoneChatNote.stripped("Call them\n\n" + PhoneChatNote.legacyRound1Text(scheme: "hermeshq"), scheme: "hermeshq") == "Call them")
        #expect(PhoneChatNote.stripped("Call them\n\n" + PhoneChatNote.legacyText(scheme: "hermeshq", includesName: true), scheme: "hermeshq") == "Call them")
        #expect(PhoneChatNote.stripped("Call them\n\n" + PhoneChatNote.legacyText(scheme: "hermeshq", includesName: false), scheme: "hermeshq") == "Call them")
        // The chat's stored rows: the bubble shows the words as typed, also inside a task's wrapped text.
        let scheme = AppIdentity.current.urlScheme
        let titles = SentTitles()
        #expect(titles.title(forStored: "Call the dentist\n\n" + PhoneChatNote.text(scheme: scheme)) == "Call the dentist")
        let messages = [ChatMessage(id: "u1", role: .user, parts: [.text("Phone the shop\n\n" + PhoneChatNote.text(scheme: scheme))], timestamp: Date(), rowId: nil),
                        ChatMessage(id: "u2", role: .user, parts: [.text("hello")], timestamp: Date(), rowId: nil)]
        #expect(titles.applied(to: messages).map(\.plainText) == ["Phone the shop", "hello"])
        let result = PhoneResultMessage(Self.ended([]))
        #expect(titles.title(forStored: result.text) == result.display)
    }

    @Test func chatContextSummarizesRecentTurnsWithoutLinksOrNotes() {
        let scheme = AppIdentity.current.urlScheme
        let messages = [
            ChatMessage(id: "m1", role: .user, parts: [.text("Let's plan Saturday's hike")], timestamp: nil, rowId: nil),
            ChatMessage(id: "m2", role: .assistant, parts: [.text("Sounds great! Do you want an early start?")], timestamp: nil, rowId: nil),
            ChatMessage(id: "m3", role: .user, parts: [.text("Call me to talk through it\n\n" + PhoneChatNote.text(scheme: scheme))], timestamp: nil, rowId: nil),
            ChatMessage(id: "m4", role: .assistant, parts: [.text("Sure thing!\n[Call +12125550142](hermes://phone-call?to=%2B12125550142&goal=Hike)")], timestamp: nil, rowId: nil),
            ChatMessage(id: "m5", role: .system, parts: [.text("internal system row")], timestamp: nil, rowId: nil),
        ]
        let summary = PhoneChatContext.summarize(messages, botName: "Otto") ?? ""
        #expect(summary.contains("User: Let's plan Saturday's hike"))
        #expect(summary.contains("Otto: Sounds great! Do you want an early start?"))
        #expect(summary.contains("User: Call me to talk through it"))
        #expect(!summary.contains("Hermes HQ: this person can place"))
        #expect(!summary.contains("hermes://phone-call"))
        #expect(!summary.contains("internal system row"))
    }
}

struct PhoneProposalTests {
    static let scheme = "hermeshq"
    static func url(_ s: String) -> URL { URL(string: s)! }

    @Test func parsesAValidProposal() throws {
        let p = try #require(PhoneProposal.parse(Self.url("hermeshq://phone-call?to=%2B12125550142&goal=Move%20my%20cleaning%20to%20Tuesday&utm=x"),
                                                 from: "+12125550100", scheme: Self.scheme))
        #expect(p == PhoneProposal(to: "+12125550142", goal: "Move my cleaning to Tuesday", voicemail: .hangUp), "unknown items ignored")
        let leave = PhoneProposal.parse(Self.url("hermes://phone-call?to=212%20555%200142&goal=Ask&voicemail=leave&self=1&greeting=Hey%20there!"), from: "+12125550100",
                                        scheme: Self.scheme)
        #expect(leave?.to == "+12125550142", "after phoneDestination")
        #expect(leave?.voicemail == .leaveMessage)
        #expect(leave?.callingOwner == true)
        #expect(leave?.greeting == "Hey there!")
    }

    @Test(arguments: ["hermeshq://phone-call?goal=Ask", "hermeshq://phone-call?to=12345&goal=Ask", "hermeshq://phone-call?to=%2B12125550142",
                      "hermeshq://phone-call?to=%2B12125550142&goal=%20%20", "hermeshq://phone-call/extra?to=%2B12125550142&goal=Ask",
                      "hermeshq://user@phone-call?to=%2B12125550142&goal=Ask", "https://phone-call?to=%2B12125550142&goal=Ask",
                      "hermeshq://phone-calls?to=%2B12125550142&goal=Ask", "otherapp://phone-call?to=%2B12125550142&goal=Ask"])
    func refusesInvalid(_ link: String) {
        #expect(PhoneProposal.parse(Self.url(link), from: "+12125550100", scheme: Self.scheme) == nil, "\(link)")
    }

    @Test func voiceOverReadsTheDrawnWords() {
        let reply = "I can call them. [Call +12125550142](hermes://phone-call?to=%2B12125550142&goal=Ask%20for%20a%20table) or [bad](hermes://phone-call?to=1)"
        #expect(PhoneProposal.spoken(reply, scheme: Self.scheme)
                == "I can call them. Call +1 212 555 0142. Ask for a table. Review. or [bad](hermes://phone-call?to=1)", "invalid links stay")
        #expect(PhoneProposal.spoken("No links here.", scheme: Self.scheme) == "No links here.")
        #expect(SpokenMarkdown.plain(PhoneProposal.spoken(reply, scheme: Self.scheme)).hasSuffix("or bad"))
    }

    @Test func goalLengthAndResilientNumbers() {
        let long = String(repeating: "a", count: 2000)
        #expect(PhoneProposal.parse(Self.url("hermeshq://phone-call?to=%2B12125550142&goal=" + long), scheme: Self.scheme)?.goal.count == 2000)
        #expect(PhoneProposal.parse(Self.url("hermeshq://phone-call?to=%2B12125550142&goal=" + long + "a"), scheme: Self.scheme) == nil)
        // Form-decoded `+` (leading space) and 11-digit NANP numbers still parse when `from` is nil (chat rendering).
        #expect(PhoneProposal.parse(Self.url("hermeshq://phone-call?to=%2012125550142&goal=Check%20in"), scheme: Self.scheme)?.to == "+12125550142")
        #expect(PhoneProposal.parse(Self.url("hermeshq://phone-call?to=12125550142&goal=Check%20in"), scheme: Self.scheme)?.to == "+12125550142")
    }

    @Test func outsideTheAppIsAlwaysRefused() {
        #expect(PhoneProposal.refusesOutside(Self.url("hermeshq://phone-call?to=%2B12125550142&goal=Ask"), scheme: Self.scheme))
        #expect(PhoneProposal.refusesOutside(Self.url("HERMES://PHONE-CALL?to=x"), scheme: Self.scheme), "valid or not, any case")
        #expect(!PhoneProposal.refusesOutside(Self.url("hermeshq://new-chat?bot=otto"), scheme: Self.scheme), "other links untouched")
        #expect(!PhoneProposal.refusesOutside(Self.url("https://example.com/phone-call"), scheme: Self.scheme))
        // The app's own scheme, as AppDelegate.open checks it.
        #expect(PhoneProposal.refusesOutside(Self.url(AppIdentity.current.urlScheme + "://phone-call?to=%2B12125550142&goal=Ask")))
    }
}

struct PhoneSetupCheckTests {
    static let setup = PhoneSetup(apiKey: "KEYTEST", fromNumber: "+12125550100", connectionID: "conn-1", assistantID: "assistant-1")
    static let number = try! JSONDecoder().decode(samplehostNumber.self, from: Data(#"{"id":"1","phone_number":"+12125550100","status":"active","connection_id":"conn-1"}"#.utf8))
    static func good() -> PhoneSetupCheck.Reads {
        PhoneSetupCheck.Reads(
            numbers: .success([number]),
            app: .success(samplehostCallControlApp(active: true, application_name: "Calls", outbound: .init(outbound_voice_profile_id: "ovp-1"))),
            profile: .success(samplehostVoiceProfile(enabled: true, whitelisted_destinations: ["US", "CA"])),
            assistant: .success(samplehostAssistantDetail(json: ["id": "assistant-1", "name": "Otto", "model": "openai/gpt-4o",
                                                             "enabled_features": ["telephony"],
                                                             "telephony_settings": ["recording_settings": ["enabled": false]]])),
            balance: .success(samplehostBalance(balance: "12.50", currency: "USD")))
    }
    static func state(_ rows: [PhoneSetupCheck.Row], _ id: String) -> PhoneSetupCheck.State? { rows.first { $0.id == id }?.state }

    @Test func allGood() {
        let rows = PhoneSetupCheck.rows(setup: Self.setup, reads: Self.good())
        #expect(rows.map(\.id) == ["key", "number", "connection", "profile", "country", "assistant", "model", "recording", "balance"])
        #expect(rows.allSatisfy { $0.state == .pass }, "\(rows.filter { $0.state != .pass })")
        #expect(rows.first { $0.id == "balance" }?.sentence == "Your balance is $12.50.")
    }

    @Test func crossesSayWhatToDo() {
        var reads = Self.good()
        reads.app = .success(samplehostCallControlApp(active: false, outbound: .init(outbound_voice_profile_id: "ovp-1")))
        reads.profile = .success(samplehostVoiceProfile(enabled: false, whitelisted_destinations: ["GB"]))
        reads.assistant = .success(samplehostAssistantDetail(json: ["id": "assistant-1", "model": "openai/gpt-live-1", "enabled_features": [],
                                                                "telephony_settings": [:]]))
        reads.balance = .success(samplehostBalance(balance: "0.40", currency: "USD"))
        let rows = PhoneSetupCheck.rows(setup: Self.setup, reads: reads)
        for id in ["connection", "profile", "country", "assistant", "recording", "balance"] {
            #expect(Self.state(rows, id) == .fail, "\(id)")
            #expect(rows.first { $0.id == id }?.fix?.isEmpty == false, "\(id)")
        }
        #expect(Self.state(rows, "model") == .warn, "GPT Live warns")
        #expect(rows.first { $0.id == "recording" }?.sentence == "Recording is on on the assistant but off here.", "absent reads as samplehost's default: on")
        var other = Self.setup
        other.connectionID = "conn-2"
        #expect(Self.state(PhoneSetupCheck.rows(setup: other, reads: Self.good()), "number") == .fail, "not on the chosen connection")
        var noProfile = Self.good()
        noProfile.app = .success(samplehostCallControlApp(active: true, outbound: nil))
        noProfile.profile = nil
        #expect(Self.state(PhoneSetupCheck.rows(setup: Self.setup, reads: noProfile), "profile") == .fail)
    }

    @Test func aFailedReadIsCouldntCheckNotACross() {
        let reads = PhoneSetupCheck.Reads(numbers: .failure(.network), app: .failure(.unexpected(500)), profile: nil,
                                          assistant: .failure(.provider("busy")), balance: .failure(.network))
        let rows = PhoneSetupCheck.rows(setup: Self.setup, reads: reads)
        #expect(!rows.contains { $0.state == .fail }, "\(rows.filter { $0.state == .fail })")
        #expect(rows.filter { $0.state == .unknown }.count == rows.count)
        #expect(rows.allSatisfy { $0.sentence.hasSuffix(PhoneSetupCheck.couldNotCheck) })
        let bad = PhoneSetupCheck.rows(setup: Self.setup, reads: .init(numbers: .failure(.badKey)))
        #expect(Self.state(bad, "key") == .fail, "a refused key is a real answer")
        let missing = PhoneSetupCheck.rows(setup: Self.setup, reads: .init(numbers: .success([Self.number]), app: .failure(.unexpected(404)),
                                                                           assistant: .failure(.unexpected(404))))
        #expect(Self.state(missing, "connection") == .fail && Self.state(missing, "assistant") == .fail, "a 404 is an answer")
    }

    @Test func suboptimalVoiceSettingsWarn() {
        var reads = Self.good()
        reads.assistant = .success(samplehostAssistantDetail(json: [
            "id": "assistant-1", "name": "Otto", "model": "openai/gpt-4o", "enabled_features": ["telephony"],
            "transcription": ["model": "deepgram/nova-2"],
            "interruption_settings": ["enable": false],
            "telephony_settings": ["noise_suppression": "krisp", "user_idle_timeout_secs": 30, "user_idle_reply_secs": 10,
                                   "recording_settings": ["enabled": false]],
        ]))
        let rows = PhoneSetupCheck.rows(setup: Self.setup, reads: reads)
        #expect(Self.state(rows, "voice") == .warn)
    }

    @Test func missingWebhookURLAndTeXMLConnectionsFailClearly() {
        var missingWebhook = Self.good()
        missingWebhook.app = .success(samplehostCallControlApp(
            active: true, application_name: "Voice App", webhook_event_url: "",
            outbound: .init(outbound_voice_profile_id: "ovp-1")
        ))
        let rows = PhoneSetupCheck.rows(setup: Self.setup, reads: missingWebhook)
        #expect(Self.state(rows, "connection") == .fail)
        #expect(rows.first { $0.id == "connection" }?.sentence.contains("webhook URL") == true)

        let texml404 = PhoneSetupCheck.rows(setup: Self.setup, reads: .init(numbers: .success([Self.number]), app: .failure(.unexpected(404))))
        #expect(Self.state(texml404, "connection") == .fail)
        #expect(texml404.first { $0.id == "connection" }?.sentence.contains("TeXML") == true)

        #expect(samplehostHasValidWebhookURL("https://voice-events.invalid/hermes-hq"))
        #expect(!samplehostHasValidWebhookURL(""))
        #expect(!samplehostHasValidWebhookURL("http://voice-events.invalid/hermes-hq"))
        #expect(!samplehostHasValidWebhookURL("localhost"))
    }

    @Test func resolverExcludesTeXMLAndPicksRealVoiceAPIConnection() {
        let texmlNum = samplehostNumber(id: "n1", phone_number: "+12125550100", status: "active",
                                    connection_id: "texml-1", connection_name: "Hermes HQ Caller")
        // Account with zero Call Control apps: TeXML connection is NOT offered or auto-selected.
        #expect(PhoneConnectionResolver.options(numbers: [texmlNum], apps: []).isEmpty)
        #expect(PhoneConnectionResolver.preferredConnection(for: "+12125550100", numbers: [texmlNum], apps: []) == "")
        #expect(PhoneConnectionResolver.isInvalidSavedConnection("texml-1", apps: []))
        #expect(PhoneConnectionResolver.nonCallControlWarning(selectedNumber: texmlNum, connectionID: "", apps: [])?.contains("TeXML") == true)

        // Account where user manually created a Voice API app while number is still on TeXML: offers and picks the Voice API app.
        let voiceApp = samplehostCallControlAppSummary(id: "cc-1", application_name: "Voice API App", active: true,
                                                   webhook_event_url: "https://voice-events.invalid/hermes-hq")
        #expect(PhoneConnectionResolver.options(numbers: [texmlNum], apps: [voiceApp]) == [.init(id: "cc-1", name: "Voice API App")])
        #expect(PhoneConnectionResolver.preferredConnection(for: "+12125550100", numbers: [texmlNum], apps: [voiceApp]) == "cc-1")
        #expect(!PhoneConnectionResolver.isInvalidSavedConnection("cc-1", apps: [voiceApp]))
    }
}

@Suite struct PhoneChatChipTests {
    private func call(_ id: String, _ state: PhoneCallRecord.State) -> PhoneCallRecord {
        var c = PhoneCallRecord(id: id, sessionID: "s", to: "+12125550142", purpose: "p", placedAt: Date(timeIntervalSince1970: 0),
                                hangupCommandID: "h")
        c.state = state
        return c
    }

    @Test func theChipFollowsTheCallAndGoesWhenItEnds() {
        #expect(phoneChipWords([]) == nil)
        #expect(phoneChipWords([call("a", .ended)]) == nil, "an ended call shows nothing")
        #expect(phoneChipWords([call("a", .calling)])?.words == "Calling +1 212 555 0142")
        var named = call("a", .calling); named.name = "Corner Bistro"
        #expect(phoneChipWords([named])?.words == "Calling Corner Bistro")
        #expect(phoneChipWords([call("a", .ended), call("b", .live)], now: Date(timeIntervalSince1970: 92))?.words == "On a call · 1:32")
        #expect(phoneChipWords([call("a", .ending)])?.words == "Ending the call")
        var voicemail = call("a", .live); voicemail.voicemail = true
        #expect(phoneChipWords([voicemail], now: Date(timeIntervalSince1970: 8))?.words == "Voicemail answered · 0:08")
        #expect(phoneChipWords([call("a", .live)])?.asking == false)
    }

    @Test func aQuestionTurnsItIntoAnAsk() {
        var asking = call("a", .live)
        asking.question = PhoneTranscript.Question(id: "q", text: "Tuesday or Friday?", choices: [])
        let chip = phoneChipWords([asking])
        #expect(chip?.words == "Call needs you")
        #expect(chip?.asking == true)
    }
}


struct PhoneCallPresentationTests {
    @Test func timersAndFollowing() {
        let start = Date(timeIntervalSince1970: 500)
        #expect(PhoneCallPresentation.timer(from: start, to: start.addingTimeInterval(-1)) == "0:00")
        #expect(PhoneCallPresentation.timer(from: start, to: start.addingTimeInterval(92.8)) == "1:32")
        #expect(PhoneCallPresentation.timer(from: start, to: start.addingTimeInterval(8.2)) == "0:08")
        #expect(PhoneCallPresentation.followsNewest(distanceFromBottom: -10))
        #expect(PhoneCallPresentation.followsNewest(distanceFromBottom: 32))
        #expect(!PhoneCallPresentation.followsNewest(distanceFromBottom: 33))
    }

    @Test(arguments: [
        (PhoneOutcome.finished, "Finished · 2m 04s", PhoneMark.success, "The call finished."),
        (.voicemail, "Went to voicemail", .voicemail, "Voicemail answered the call."),
        (.noAnswer, "No answer", .missed, "Nobody answered the call."),
        (.busy, "Busy", .missed, "The other line was busy."),
        (.declined, "Declined", .missed, "The other side declined the call."),
        (.noSuchNumber, "Couldn't connect", .failed, "The phone number couldn't be reached because it doesn't exist."),
        (.couldNotConnect("a temporary network problem"), "Couldn't connect", .failed, "The call couldn't connect because of a temporary network problem."),
        (.couldNotConnect("the other phone is out of service"), "Couldn't connect", .failed, "The other phone is out of service."),
        (.unknown, "Ended", .ended, "The call ended before its outcome could be confirmed."),
    ])
    func heroAndReason(_ outcome: PhoneOutcome, _ title: String, _ mark: PhoneMark, _ reason: String) {
        var call = PhoneChatTextTests.ended([])
        call.outcome = outcome
        call.asked = []
        #expect(PhoneCallPresentation.title(outcome, duration: 124) == title)
        #expect(PhoneMark.outcome(outcome) == mark)
        #expect(PhoneCallPresentation.reason(call) == reason)
        #expect(PhoneCallPresentation.whatHappened(call) == reason)
        #expect(PhoneCallPresentation.actions(call) == (outcome == .voicemail ? [.again, .leave] : [.again, .transcript, .share]))
    }

    @Test func factsAndShare() {
        var call = PhoneChatTextTests.ended([.init(id: "a", speaker: .them, text: "KEYTEST was spoken.")])
        call.summary = "Corner Bistro booked your table. KEYTEST"
        call.name = "Corner Bistro"
        call.ringSeconds = 6
        call.result = .pending
        #expect(PhoneCallPresentation.facts(call, sendsResults: true) == [
            .init("Rang for", "6s"), .init("Recording", "Off"), .init("Sent to chat", "Waiting for the chat to open")
        ])
        let share = PhoneCallPresentation.share(call, redacting: "KEYTEST")
        #expect(!share.contains("KEYTEST"))
        #expect(share.contains("Corner Bistro booked your table. •••"))
        #expect(share.contains("Is Tuesday OK? → Yes"))
        #expect(share.contains("Them: ••• was spoken."))
        call.summary = nil
        #expect(PhoneCallPresentation.whatHappened(call) == "The call finished. You answered “Yes”.")
        call.outcome = .voicemail
        call.result = .off
        call.ringSeconds = 1
        #expect(PhoneCallPresentation.pickup(call) == "picked up in 1 second")
        #expect(PhoneCallPresentation.facts(call, sendsResults: false).contains(.init("Message left", "No")))
        call.voicemailChoice = .leaveMessage
        #expect(PhoneCallPresentation.actions(call) == [.again, .transcript, .share])
        #expect(PhoneCallPresentation.facts(call, sendsResults: false).last == .init("Sent to chat", "Off"))
    }

    @Test func cardFromStoredText() throws {
        var call = PhoneChatTextTests.ended([])
        call.summary = "Corner Bistro booked a table at 7:15. They found a quiet table."
        call.duration = 124
        let stored = PhoneResultMessage(call)
        let card = try #require(PhoneResultCard(stored: stored.text))
        #expect(card.title == "Call finished · 2m 04s")
        #expect(card.subtitle == "Corner Bistro booked a table at 7:15.")
        #expect(card.mark == .success)
        #expect(card.localCall(in: []) == nil)
        #expect(card.localCall(in: [call])?.id == call.id)
        #expect(PhoneChatText.shown(stored.text) == stored.display)
        #expect(PhoneResultCard(stored: PhoneResultMessage(call, includeSummary: false).text)?.localCall(in: [call])?.id == call.id)
        #expect(PhoneResultCard(stored: "hello") == nil)
        // Without a samplehost summary, the card still shows callee identity and goal, plus parsed Q&A and transcript.
        var noSummary = PhoneChatTextTests.ended([.init(id: "1", speaker: .assistant, text: "Hello")])
        noSummary.name = "Corner Bistro"
        let parsed = try #require(PhoneResultCard(stored: PhoneResultMessage(noSummary).text))
        #expect(parsed.name == "Corner Bistro")
        #expect(parsed.goal == "Move my appointment")
        #expect(parsed.subtitle == "Corner Bistro · +1 212 555 0142\nMove my appointment")
        #expect(parsed.questions.count == 2)
        #expect(parsed.transcriptLines == ["Assistant: Hello"])
        let message = ChatMessage(id: "result", role: .user, parts: [.text(stored.text)], timestamp: nil, rowId: nil)
        let shown = SentTitles().applied(to: [message])
        #expect(shown.first?.plainText == stored.display)
        #expect(shown.first?.phoneResultText == stored.text)
        let input = ChatRowBuilder.Input(messages: shown, isRunning: false, botName: "Hermes", expanded: [])
        let rows = ChatRowBuilder.build(input)
        #expect(rows.contains { if case .phoneResult(let drawn, _) = $0.kind { return drawn == card }; return false })
    }

    @Test func insightsOnlyUseCompletedPlainStrings() throws {
        func summary(_ json: String) throws -> String? { try samplehostConversationInsight.summary(in: Data(json.utf8)) }
        func status(_ json: String) throws -> samplehostInsightStatus { try samplehostConversationInsight.status(in: Data(json.utf8)) }
        #expect(try summary(#"{"data":[]}"#) == nil)
        #expect(try status(#"{"data":[]}"#) == .empty)
        #expect(try summary(#"{"data":[{"status":"pending","conversation_insights":[{"result":"Early"}]}]}"#) == nil)
        #expect(try status(#"{"data":[{"status":"pending","conversation_insights":[{"result":"Early"}]}]}"#) == .pending)
        #expect(try summary(#"{"data":[{"status":"completed","conversation_insights":[{"result":{"answer":"yes"}},{"result":42}]}]}"#) == nil)
        #expect(try status(#"{"data":[{"status":"completed","conversation_insights":[{"result":{"answer":"yes"}},{"result":42}]}]}"#) == .empty)
        #expect(try summary(#"{"data":[{"status":"completed","conversation_insights":[{"result":false},{"result":"  The call finished.  "}]}]}"#) == "The call finished.")
        #expect(try status(#"{"data":[{"status":"completed","conversation_insights":[{"result":false},{"result":"  The call finished.  "}]}]}"#) == .completed("The call finished."))
    }

    @Test @MainActor func proposalCarriesNameAndRendersAsABlock() throws {
        let url = try #require(URL(string: "hermes://phone-call?to=%2B12125550142&goal=Book%20a%20table&name=Corner%20Bistro"))
        let proposal = try #require(PhoneProposal.parse(url))
        #expect(proposal.name == "Corner Bistro")
        #expect(proposal.spokenReview == "Call Corner Bistro. Book a table. Review.")
        let style = ChatStyle.make(category: .large)
        let markdown = MarkdownRenderer.render("I can call them.\n[Review](\(url))\nLet me know.", style: style, phoneProposals: true)
        #expect(markdown.blocks.contains { if case .phoneProposal(_, let card) = $0 { return card == proposal }; return false })
        let boldMarkdown = MarkdownRenderer.render("I can call them.\n**[Review](\(url))**", style: style, phoneProposals: true)
        #expect(boldMarkdown.blocks.contains { if case .phoneProposal(_, let card) = $0 { return card == proposal }; return false })
        let note = PhoneChatNote.text()
        #expect(note.contains("&name="))
        let old = "Call the bistro.\n\n" + PhoneChatNote.legacyText(includesName: false)
        #expect(PhoneChatText.shown(old) == "Call the bistro.")
    }
}
