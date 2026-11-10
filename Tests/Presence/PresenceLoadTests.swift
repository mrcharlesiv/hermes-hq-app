// [presence] The unit side of the stress plan (docs/spec/3x-presence.md §14): load and bad data through the presence
// centre and the plugin's list, with no simulator screen. The UI side is UITests/presence/PresenceStressTests.swift.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor private final class Roster {
    var bots: [Bot]
    var owners: [String: String] = [:]
    var published: [[String: BotPresence]] = []

    init(_ count: Int) {
        bots = (0..<count).map { i in
            Bot(id: i == 0 ? "default" : String(format: "bot-%02d", i), name: i == 0 ? "Hermes" : "Bot \(i)", role: nil, preview: nil,
                lastActive: nil, isWorking: false, unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: false,
                canonicalSessionId: nil, head: nil)
        }
        for bot in bots { owners["r-\(bot.id)"] = bot.id }
    }

    func center(browser: BrowserService? = nil) -> PresenceCenter {
        PresenceCenter(browser: browser, context: PresenceCenter.Context(
            owner: { [unowned self] in self.owners[$0] },
            bots: { [unowned self] in self.bots },
            noticeOn: { _ in true },
            visibleChatProfile: { nil },
            face: { _ in nil },
            window: { nil },
            openBrowser: { _, _ in },
            openScreen: { _, _ in },
            publish: { [unowned self] in self.published.append($0) }))
    }
}

private func start(_ payload: JSONValue, session: String) -> GatewayEvent {
    GatewayEvent(type: "tool.start", sessionId: session, seq: nil, payload: payload)
}

private func hexId(_ n: Int) -> String { String(format: "%024x", n) }

@MainActor @Suite(.serialized) struct PresenceLoadTests {
    /// S1: 52 bots, the plugin's list changing for every one of them 300 times in a row (the fixture's 20 a second for
    /// 15 s, sent here as fast as the main thread takes them): the roster is rebuilt a handful of times, and the last
    /// frame's lines are the ones left standing.
    @Test func aFloodOfListFramesCostsAFewRosterRebuilds() async {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in throw HTTPError(status: 404, body: nil) }
        let service = BrowserService(rest: client, sockets: NoPluginSockets())
        let roster = Roster(52)
        let center = roster.center(browser: service)
        center.setBotsListShown(true)
        let began = ContinuousClock.now
        var last: [BrowserRow] = []
        for frame in 0..<300 {
            last = roster.bots.enumerated().map { i, bot in
                BrowserRow(id: hexId(i + 1), profile: bot.id, url: "https://site-\(frame % 7).example.test/p\(frame)", busy: 1,
                           agentAt: Date().timeIntervalSince1970, active: true)
            }
            service.activity.debugPublish(last)
            if frame % 25 == 24 { try? await Task.sleep(for: .milliseconds(20)) }      // let the main thread breathe, as a socket would
        }
        let took = ContinuousClock.now - began
        try? await Task.sleep(for: PresenceCenter.publishGap + .milliseconds(200))
        // At most one publish per publishGap, plus the first and the trailing one.
        let allowed = Int(took / PresenceCenter.publishGap) + 3
        #expect(center.publishes <= allowed, "\(center.publishes) publishes in \(took) (allowed \(allowed))")
        #expect(center.publishes < 30)
        #expect(roster.published.last?.count == 52)
        #expect(roster.published.last?["bot-07"]?.browserLine == "Browsing site-\(299 % 7).example.test")
        #expect(roster.published.last?["default"]?.browserLine == "Browsing site-\(299 % 7).example.test")
        #expect(service.activity.debugListeners == 1)

        // The list empties: every line goes in one publish.
        let before = center.publishes
        service.activity.debugPublish([])
        #expect(await BotsTest.waitUntil { roster.published.last == [:] })
        #expect(center.publishes == before + 1)
        center.shutdown()
        service.shutdown()
    }

    /// S3: ten bots start a browser tool within the same moment: ten rows, ten notices decided (one each, every bot
    /// has its own cooldown), and a couple of rebuilds.
    @Test func tenBotsAtOnce() async {
        let roster = Roster(10)
        let center = roster.center()
        for bot in roster.bots { center.handle(start(["name": "browser_navigate"], session: "r-\(bot.id)")) }
        #expect(center.debugOutcomes == Array(repeating: .browser, count: 10))
        // Again, at once: every one is inside its own cooldown.
        for bot in roster.bots { center.handle(start(["name": "browser_click"], session: "r-\(bot.id)")) }
        #expect(center.debugOutcomes.suffix(10) == Array(repeating: .none("cooldown"), count: 10))
        #expect(await BotsTest.waitUntil { roster.published.last?.count == 10 })
        #expect(roster.published.last?.values.allSatisfy { $0.usingComputer && $0.browserLine == nil } == true)
        #expect(center.publishes <= 2)
        center.shutdown()
    }

    /// S15: tool starts that make no sense change nothing and decide nothing.
    @Test func toolStartsThatMakeNoSense() async {
        let roster = Roster(2)
        let center = roster.center()
        let long = String(repeating: "z", count: 10_000)
        let bad: [JSONValue] = [
            .null,
            [:],
            ["name": .null],
            ["name": 42],
            ["name": true],
            ["name": ["browser_navigate"]],
            ["name": ["name": "browser_navigate"]],
            ["name": ""],
            ["name": .string(long)],
            ["name": " browser_navigate"],
            ["name": "Browser_Navigate"],
            ["name": "browser"],
            ["name": "computeruse"],
            ["tool": "browser_navigate"],
        ]
        for payload in bad { center.handle(start(payload, session: "r-bot-01")) }
        // A real screen tool in a chat nobody owns, with no session at all, and an event type that only looks like it.
        center.handle(start(["name": "browser_navigate"], session: ""))
        center.handle(start(["name": "browser_navigate"], session: "r-nobody"))
        center.handle(GatewayEvent(type: "tool.start ", sessionId: "r-bot-01", seq: nil, payload: ["name": "browser_navigate"]))
        center.handle(GatewayEvent(type: "tool.complete", sessionId: "r-bot-01", seq: nil, payload: ["name": "browser_navigate"]))
        try? await Task.sleep(for: PresenceCenter.publishGap + .milliseconds(100))
        #expect(roster.published.isEmpty, "nothing reached the rows: \(roster.published)")
        #expect(center.debugOutcomes == [.none("no owner"), .none("no owner")])
        #expect(!center.debugExpiryArmed)

        // A very long name that does begin like a screen tool is still just a screen tool.
        center.handle(start(["name": .string("browser_" + long)], session: "r-bot-01"))
        #expect(roster.published.last == ["bot-01": BotPresence(usingComputer: true)])
        #expect(center.debugOutcomes.last == .browser)
        center.shutdown()
    }

    /// S16: list rows that make no sense: a profile that is no bot, two browsers for one bot, an address that is none, a
    /// very long host, an id that is none, a list far too long.
    @Test func listRowsThatMakeNoSense() async throws {
        func parse(_ rows: [[String: Any]]) throws -> [BrowserRow] {
            let data = try JSONSerialization.data(withJSONObject: ["schema": "dispatch-browser.list.v3", "browsers": rows])
            return try #require(BrowserRow.parseList(try JSONValue.parse(data)))
        }
        let now = Date().timeIntervalSince1970
        let longHost = String(repeating: "verylonghostname", count: 300)
        let rows = try parse([
            ["id": hexId(1), "profile": "nobody-here", "active": true, "url": "https://ghost.example.test/"],
            ["id": hexId(2), "profile": "bot-01", "active": true, "url": "https://older.example.test/", "agent_at": now - 50],
            ["id": hexId(3), "profile": "bot-01", "active": true, "url": "https://newer.example.test/", "agent_at": now],
            ["id": hexId(4), "profile": "default", "active": true, "url": "not a url at all"],
            ["id": hexId(5), "profile": "bot-02", "active": true, "url": "https://\(longHost).example.test/"],
            ["id": "NOT-AN-ID", "profile": "bot-03", "active": true, "url": "https://example.test/"],
            ["id": hexId(6), "profile": 7, "active": true],
            ["id": hexId(7), "profile": "bot-04", "active": "yes", "busy": "many", "agent_at": "soon", "url": 12],
            ["id": hexId(8), "profile": "bot-05", "active": true, "control": "robot", "ask": 5, "url": NSNull()],
        ])
        #expect(rows.count == 7)                                       // the bad id and the number profile are dropped

        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in throw HTTPError(status: 404, body: nil) }
        let service = BrowserService(rest: client, sockets: NoPluginSockets())
        let roster = Roster(6)
        let center = roster.center(browser: service)
        center.setBotsListShown(true)
        service.activity.debugPublish(rows)
        #expect(await BotsTest.waitUntil { roster.published.last?["bot-01"] != nil })
        let map = try #require(roster.published.last)
        #expect(map["nobody-here"] == nil, "a profile that is no bot gets no row")
        #expect(map["bot-01"]?.browserLine == "Browsing newer.example.test", "the newest use wins")
        // Stress round 1: an address that names no web site is not repeated raw; the row says the plain thing.
        #expect(map["default"]?.browserLine == "Using its browser", "an address that is none still reads as a line")
        #expect(map["bot-02"]?.browserLine == "Using its browser", "a host no web site can have (4,800 letters) is not shown")
        #expect(map["bot-03"] == nil)
        #expect(map["bot-04"] == nil, "a row that is not in use is not news")
        #expect(map["bot-05"]?.browserLine == "Using its browser", "an unknown control reads as the bot's")
        for line in map.values.compactMap(\.browserLine) { #expect(!line.localizedCaseInsensitiveContains("dispatch")) }

        // A list far too long is cut at 64 rows; things that are not a list are not a list.
        let many = try parse((0..<500).map { ["id": hexId(100 + $0), "profile": "p\($0)", "active": true] })
        #expect(many.count == 64)
        #expect(BrowserRow.parseList(.null) == nil)
        #expect(BrowserRow.parseList(["schema": "dispatch-browser.list.v3"]) == nil)
        #expect(BrowserRow.parseList(["schema": "dispatch-browser.list.v3", "browsers": "none"]) == nil)
        #expect(BrowserRow.parseList(["schema": "dispatch-browser.list.v3", "browsers": [1, "two", .null, [:]]]) == [])
        center.shutdown()
        service.shutdown()
    }

    /// The 90 s window under many bots: the earliest end is the one the timer waits for, and a reply finishing for
    /// one bot leaves the others alone. (S17, the stored flag's odd shapes, is PresenceStoreTests.)
    @Test func manyBotsShareOneTimer() {
        let clock = ContinuousClock()
        let t0 = clock.now
        var activity = ComputerActivity()
        for i in 0..<200 { activity.toolStarted("bot-\(i)", at: t0 + .seconds(i)) }
        #expect(activity.nextExpiry() == t0 + ScreenTools.quiet)
        #expect(activity.active(at: t0 + .seconds(100)).count == 200 - 11)        // 0…10 ended (their 90 s are up)
        #expect(activity.nextExpiry() == t0 + .seconds(11) + ScreenTools.quiet)
        let done = activity.replyFinished("bot-150")
        #expect(done && activity.active(at: t0 + .seconds(100)).count == 200 - 12)
        #expect(activity.active(at: t0 + .seconds(1_000)).isEmpty && activity.nextExpiry() == nil)
    }
}
