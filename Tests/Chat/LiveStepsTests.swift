import Foundation
import Testing
@testable import HermesHQNative

/// [toolnow] The Bots and Sessions rows name the running step instead of "Working…" (owner, 2026-10-30).
@Suite struct LiveStepsTests {
    static func event(_ type: String, _ payload: [String: JSONValue] = [:], runtime: String = "r1") -> GatewayEvent {
        GatewayEvent(type: type, sessionId: runtime, seq: nil, payload: .object(payload))
    }

    static func start(_ name: String, _ args: [String: JSONValue], runtime: String = "r1") -> GatewayEvent {
        event("tool.start", ["name": .string(name), "tool_id": .string("t-\(name)"), "args": .object(args)], runtime: runtime)
    }

    @Test func namesTheNewestStepUntilTheReplyWrites() {
        var steps = LiveSteps()
        let changed1 = steps.handle(Self.event("message.start"))
        #expect(!changed1)
        #expect(steps.byRuntime["r1"] == nil)                                   // no step yet: "Working…"
        let changed2 = steps.handle(Self.start("read_file", ["path": .string("/Users/x/app/package.json")]))
        #expect(changed2)
        #expect(steps.byRuntime["r1"] == "reading package.json")
        // A finished step stays named through the thinking after it (the thinking row's rule).
        let changed3 = steps.handle(Self.event("tool.complete", ["name": .string("read_file"), "tool_id": .string("t-read_file")]))
        #expect(!changed3)
        let changed4 = steps.handle(Self.event("reasoning.delta", ["text": .string("Let me check")]))
        #expect(!changed4)
        #expect(steps.byRuntime["r1"] == "reading package.json")
        let changed5 = steps.handle(Self.start("terminal", ["command": .string("cd /Users/x/app && npm test")]))
        #expect(changed5)
        #expect(steps.byRuntime["r1"] == "running npm test")
        // A silent step leaves the one before it.
        let changed6 = steps.handle(Self.start("todo", ["todos": .array([])]))
        #expect(!changed6)
        #expect(steps.byRuntime["r1"] == "running npm test")
        // Blank deltas don't count as writing; words do.
        let changed7 = steps.handle(Self.event("message.delta", ["text": .string("\n ")]))
        #expect(!changed7)
        let changed8 = steps.handle(Self.event("message.delta", ["text": .string("All tests pass.")]))
        #expect(changed8)
        #expect(steps.byRuntime["r1"] == nil)
        let changed9 = steps.handle(Self.event("message.delta", ["text": .string(" More.")]))
        #expect(!changed9)   // nothing to clear: no change
    }

    @Test func theTurnsEndClearsIt() {
        for end in [Self.event("message.complete", ["text": .string("Done")]), Self.event("error", ["message": .string("x")]),
                    Self.event("session.interrupt"), Self.event("session.info", ["running": .bool(false)])] {
            var steps = LiveSteps()
            _ = steps.handle(Self.start("web_search", ["query": .string("swift actors")]))
            #expect(steps.byRuntime["r1"] == "searching the web for swift actors")
            let changed10 = steps.handle(end)
            #expect(changed10)
            #expect(steps.byRuntime["r1"] == nil)
        }
        var steps = LiveSteps()
        _ = steps.handle(Self.start("web_search", ["query": .string("swift actors")]))
        let changed11 = steps.handle(Self.event("session.info", ["running": .bool(true)]))
        #expect(!changed11)
        let changed12 = steps.clear("r1")
        #expect(changed12)
        #expect(steps.byRuntime.isEmpty)
    }

    @Test func eachChatKeepsItsOwn() {
        var steps = LiveSteps()
        _ = steps.handle(Self.start("read_file", ["path": .string("/a/notes.md")], runtime: "r1"))
        _ = steps.handle(Self.start("browser_navigate", ["url": .string("https://www.apple.com/iphone/")], runtime: "r2"))
        #expect(steps.byRuntime == ["r1": "reading notes.md", "r2": "opening apple.com"])
        _ = steps.handle(Self.event("message.complete", runtime: "r2"))
        #expect(steps.byRuntime == ["r1": "reading notes.md"])
        let changed13 = steps.handle(Self.start("read_file", ["path": .string("/a/notes.md")], runtime: ""))
        #expect(!changed13)   // broadcasts: nobody's
    }

    @Test func argumentsAsTheChatReadsThem() {
        var steps = LiveSteps()
        _ = steps.handle(Self.event("tool.start", ["name": .string("terminal"), "args_text": .string(#"{"command": "git status"}"#)]))
        #expect(steps.byRuntime["r1"] == "running git status")
        _ = steps.handle(Self.event("tool.start", ["name": .string("read_file"), "arguments": .object(["path": .string("/x/a.swift")])]))
        #expect(steps.byRuntime["r1"] == "reading a.swift")
        // A message to another bot names it as the roster does.
        let roster = [DeliveryMessages.Seat(profile: "otto", name: "Otto", head: nil)]
        _ = steps.handle(Self.start("message_agent", ["target": .string("@otto"), "message": .string("hi")]), roster: roster)
        #expect(steps.byRuntime["r1"] == "messaging Otto")
    }

    @Test func rowLine() {
        #expect(LiveSteps.line("reading package.json") == "Reading package.json…")
        #expect(LiveSteps.line("running npm test") == "Running npm test…")
    }

    @Test func rowsSayTheStep() {
        var bot = Bot(id: "otto", name: "Otto", role: nil, preview: "Earlier", lastActive: nil, isWorking: true, unread: false,
                      pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "c", head: nil)
        #expect(BotList.secondLine(bot).text == "Working…")
        bot.step = "reading package.json"
        #expect(BotList.secondLine(bot).text == "Reading package.json…")
        #expect(BotList.secondLine(bot).tone == .tint)
        #expect(BotList.accessibilityLabel(bot, time: "2:34 PM").contains("Reading package.json"))
        bot.isWorking = false                                                   // a stale step never shows on an idle row
        #expect(BotList.secondLine(bot).text == "Earlier")

        var session = SessionSummary(id: "s", profile: "otto", title: "Pricing", preview: "Earlier", lastActive: nil,
                                     source: nil, unread: false, isRunning: true)
        session.status = .working
        #expect(SessionRowWords.detailText(session, detail: []) == "Working…")
        session.step = "running npm test"
        #expect(SessionRowWords.detailText(session, detail: []) == "Running npm test…")
        #expect(SessionRowWords.accessibilityLabel(title: "Pricing", session: session, ownerName: "Otto", detail: [], time: "")
            .contains("Running npm test"))
    }
}
