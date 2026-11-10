import Foundation
import Testing
@testable import HermesHQNative

/// Row-building, preview cleaning, list time, sort, tiles and sections (spec 02 §6–7).
@Suite struct RosterRulesTests {
    private func profile(_ json: JSONValue) -> RosterProfile { RosterProfile(json: json)! }

    // MARK: Names and roles (§6.1, §6.2)

    @Test func names() {
        #expect(RosterRules.titleCase("research-buddy") == "Research Buddy")
        #expect(RosterRules.titleCase("ivy_2nd__bot") == "Ivy 2nd Bot")
        let primary = profile(BotsTest.row("default"))
        #expect(RosterRules.displayName(primary, meta: BotMeta()) == "Hermes")
        let renamed = profile(BotsTest.row("default", display: "Atlas"))
        #expect(RosterRules.displayName(renamed, meta: BotMeta()) == "Atlas")
        let titled = profile(BotsTest.row("research-buddy", display: "Scout", meta: ["title": "  Scout Prime "]))
        #expect(RosterRules.displayName(titled, meta: BotMeta(json: titled.uiMeta["hermes-bots"])) == "Scout Prime")
        #expect(RosterRules.displayName(profile(BotsTest.row("research-buddy")), meta: BotMeta()) == "Research Buddy")
        let roled = profile(BotsTest.row("ivy", meta: ["description": "Meta role"], description: "Row role"))
        #expect(RosterRules.roleLine(roled, meta: BotMeta(json: roled.uiMeta["hermes-bots"]), name: "Ivy") == "Meta role")
        #expect(RosterRules.roleLine(profile(BotsTest.row("ivy", description: "Row role")), meta: BotMeta(), name: "Ivy") == "Row role")
        #expect(RosterRules.handle(forProfile: "default") == "hermes")
    }

    // MARK: Preview text (§6.4)

    @Test func rowPreviewMachineNotes() {
        #expect(RosterPreview.rowPreview("[System: The active model for this chat has changed to claude-opus-5-5 via provider anthropic.]")
                == "Model changed to claude-opus-5-5")
        #expect(RosterPreview.rowPreview("[System: The active model for this chat has changed to gpt-5.]", model: { $0.uppercased() })
                == "Model changed to GPT-5")
        #expect(RosterPreview.rowPreview("[System: The active model for this chat has changed to claude-op...") == "Model changed")
        #expect(RosterPreview.rowPreview("[System: The active model for this chat has ch...") == "Model changed")
        #expect(RosterPreview.rowPreview("[System note: Gateway restarted]") == "Gateway restarted")
        #expect(RosterPreview.rowPreview("[SYSTEM] Nightly check done") == "Nightly check done")
        #expect(RosterPreview.rowPreview("work kanban task t_522444de") == "Kanban task")
        #expect(RosterPreview.rowPreview("<external_codex_apps_open_page>{\"a\":1}</external_codex_apps_open_page> Hi there") == "Hi there")
        #expect(RosterPreview.rowPreview("Plain words") == "Plain words")
    }

    /// UX study #210: a bot whose newest message is a silent reply shows its role line (blank without one), never
    /// "Nothing to report" or "No messages yet".
    @Test func silentPreviewShowsTheRoleLine() {
        let withRole = RosterPreview.botPreview(text: "[SILENT]", fromBot: nil, role: "Research assistant")
        #expect(withRole.text == "Research assistant" && withRole.isFallback && withRole.prefix == nil)
        #expect(RosterPreview.botPreview(text: " [ silent ] ", fromBot: nil, role: nil).text == "")
        #expect(RosterPreview.botPreview(text: "", fromBot: nil, role: nil).text == "No messages yet")
    }

    @Test func cleanPreviewText() {
        #expect(RosterPreview.cleanPreviewText("**Done.** I pushed the fix to `main`.") == "Done. I pushed the fix to main.")
        #expect(RosterPreview.cleanPreviewText("See [the notes](https://example.org) and ![chart](x.png)") == "See the notes and chart")
        #expect(RosterPreview.cleanPreviewText("[SILENT]") == "", "UX study #210: no 'Nothing to report' in the lists")
        #expect(RosterPreview.cleanPreviewText("[NO_REPLY]") == "")
        #expect(RosterPreview.cleanPreviewText("NO_REPLY") == "")
        #expect(RosterPreview.cleanPreviewText("Report ready\n## Run Context\njob: x\nwhen: now") == "Report ready")
        #expect(RosterPreview.cleanPreviewText("[System note: internal] Here you go") == "Here you go")
        #expect(RosterPreview.cleanPreviewText("# Title\n- one\n- two") == "Title one two")
        #expect(RosterPreview.cleanPreviewText("| a | b |\n|---|---|\n| 1 | 2 |") == "a · b · 1 · 2")
        #expect(RosterPreview.cleanPreviewText("The **bold start that the gateway cut") == "The bold start that the gateway cut")
        #expect(RosterPreview.cleanPreviewText("```swift\nlet x = 1\n```\nDone") == "Done")
        #expect(RosterPreview.cleanPreviewText("[System: The active model for this chat has changed to m1.]") == "Model changed to m1")
    }

    @Test func deliveryPrefix() {
        #expect(RosterPreview.deliveryHandle("Message from 🤖 inbox (@inbox): Three emails need you") == "inbox")
        #expect(RosterPreview.deliveryHandle("Message from agent 'default': hi") == "hermes")
        #expect(RosterPreview.deliveryHandle("Hello") == nil)
        let parts = RosterPreview.botPreview(text: "Message from 🤖 inbox (@inbox): **Three** emails need you", fromBot: "Inbox", role: nil)
        #expect(parts.prefix == "From Inbox:" && parts.text == "Three emails need you")
        #expect(parts.line == "From Inbox: Three emails need you")
        let bracket = RosterPreview.botPreview(text: "[Message from agent 'ivy'] ping", fromBot: nil, role: nil)
        #expect(bracket.prefix == nil && bracket.text == "ping")
        let empty = RosterPreview.botPreview(text: "[SYSTEM]", fromBot: nil, role: "Research assistant")
        #expect(empty.isFallback && empty.text == "Research assistant")
        #expect(RosterPreview.botPreview(text: "", fromBot: nil, role: nil).text == "No messages yet")
    }

    @Test func deliveryPrefixUsesRosterName() {
        let rows = [BotsTest.row("inbox", display: "Inbox Zero", canonical: BotsTest.session("i1", lastActive: 10)),
                    BotsTest.row("ivy", canonical: BotsTest.session("s1", preview: "Message from 🤖 inbox (@inbox): Sorted", lastActive: 20))]
        let out = RosterBuilder.build(.init(profiles: rows.map(profile)))
        #expect(out.details["ivy"]?.preview.prefix == "From Inbox Zero:")
        #expect(out.layout.flat.first { $0.id == "ivy" }?.preview == "From Inbox Zero: Sorted")
    }

    // MARK: Which session previews, and its time (§6.3)

    @Test func rosterPreviewRules() {
        let chat = profile(BotsTest.row("ivy", canonical: BotsTest.session("c1", resolved: "c2", preview: "From the chat", lastActive: 300),
                                        last: BotsTest.session("l1", preview: "Side chat", lastActive: 400, title: "Side")))
        let source = RosterRules.rosterPreview(chat)
        #expect(source.preview == "From the chat" && source.time == 300 && source.session?.id == "c1")

        // An empty Bot Chat previews nothing, whatever the bot's sessions said (tester, 2026-11-05): a session
        // turn, a cron run, or a side chat with only a title stays on its Sessions row.
        let cron = profile(BotsTest.row("inbox", canonical: BotsTest.session("c1", preview: "", lastActive: 100, count: 0),
                                        last: BotsTest.session("cron_abc", preview: "raw", lastActive: 500,
                                                               title: "morning-inbox-triage · Sep 27 17:00", source: "cron")))
        let cronSource = RosterRules.rosterPreview(cron)
        #expect(cronSource.preview == "" && cronSource.time == 0 && cronSource.session == nil)

        let turn = profile(BotsTest.row("orchestrator", canonical: BotsTest.session("c1", preview: "", lastActive: 100, count: 0),
                                        last: BotsTest.session("l1", preview: "Operation interrupted: waiting for model response",
                                                               lastActive: 600, title: "Refactor")))
        let turnSource = RosterRules.rosterPreview(turn)
        #expect(turnSource.preview == "" && turnSource.time == 0 && RosterRules.rosterTime(turn) == 0)

        let side = profile(BotsTest.row("x", last: BotsTest.session("l1", preview: "", lastActive: 50, title: "Planning")))
        #expect(RosterRules.rosterPreview(side).preview == "" && RosterRules.rosterTime(side) == 0)

        let nothing = profile(BotsTest.row("y", canonical: BotsTest.session("c1", preview: "", lastActive: 99, count: 0)))
        #expect(RosterRules.rosterPreview(nothing).time == 0)
        #expect(RosterPreview.humanJobTitle("ios-build-check") == "iOS build check")
        #expect(RosterPreview.humanJobTitle("Weekly review") == "Weekly review")
    }

    // MARK: List time (§6.3)

    @Test func listTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US")
        let locale = Locale(identifier: "en_US")
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let now = date(2026, 10, 9, 15, 30)                         // a Friday
        func words(_ d: Date?) -> String { BotsTest.plain(ListTime.string(d, now: now, calendar: calendar, locale: locale)) }
        #expect(words(date(2026, 10, 9, 9, 5)) == "9:05 AM")
        #expect(words(date(2026, 10, 9, 15, 31)) == "3:31 PM")      // a little ahead of the clock: today's time
        #expect(words(date(2026, 10, 8, 23, 59)) == "Yesterday")
        #expect(words(date(2026, 10, 5)) == "Mon")
        #expect(words(date(2026, 10, 3)) == "Sat")
        #expect(words(date(2026, 10, 2)) == "Oct 2")
        #expect(words(date(2025, 8, 7)) == "Aug 7, 2025")
        #expect(words(date(2026, 10, 11)) == "Oct 11")             // another day ahead: its date
        #expect(words(nil) == "")
        #expect(ListTime.string(seconds: 0, now: now, calendar: calendar, locale: locale) == "")
    }

    // MARK: Sort, tiles, sections (§7)

    @Test func demoLayout() throws {
        let snapshot = try RosterSnapshot.decode(BotsFixture.json("demo-profiles-list"))
        let sections = RosterBuilder.adoptSections([], profiles: snapshot.profiles, meta: [:])
        #expect(sections == [RosterSectionRecord(id: "sec-work", name: "Work"), RosterSectionRecord(id: "sec-home", name: "Home")])
        let layout = RosterBuilder.build(.init(profiles: snapshot.profiles, sections: sections)).layout
        #expect(layout.tiles.map(\.id) == ["default", "deploys", "research"])
        #expect(layout.tiles.map(\.pinOrder) == [0, 1, 2])
        #expect(layout.sections.map(\.name) == ["Work", "Home"])
        #expect(layout.sections[0].bots.map(\.id) == ["inbox", "writing", "finance"])
        #expect(layout.sections[1].bots.map(\.id) == ["garden", "home", "travel"])
        #expect(layout.unassigned.isEmpty && layout.hidden.isEmpty)
        #expect(layout.flat.count == 9)
        #expect(layout.flat.allSatisfy { $0.canonicalSessionId != nil })
        let deploys = try #require(layout.tiles.first { $0.id == "deploys" })
        #expect(deploys.preview == "One overlap: Example Notes 3.1 added Markdown export on Monday, no JSON. Ours does both.")
        #expect(deploys.head?["color"]?.string == "coral")
    }

    @Test func sortPinnedFirstThenNewestThenCreated() {
        let rows = [
            BotsTest.row("old", canonical: BotsTest.session("a", lastActive: 100)),
            BotsTest.row("new", canonical: BotsTest.session("b", lastActive: 900)),
            BotsTest.row("pin", canonical: BotsTest.session("c", lastActive: 50), meta: ["pinned": true]),
            BotsTest.row("fresh", meta: ["created": 950_000]),                   // nothing said: sorts by creation (ms)
            BotsTest.row("tieA", canonical: BotsTest.session("d", lastActive: 500)),
            BotsTest.row("tieB", canonical: BotsTest.session("e", lastActive: 500)),
        ]
        let layout = RosterBuilder.build(.init(profiles: rows.map(profile))).layout
        #expect(layout.tiles.map(\.id) == ["pin"])
        #expect(layout.unassigned.map(\.id) == ["fresh", "new", "tieA", "tieB", "old"])
    }

    @Test func tilesOverflowIntoPinnedSectionAndRespectDeviceOrder() {
        let rows = (1...8).map { i in
            BotsTest.row("b\(i)", canonical: BotsTest.session("s\(i)", lastActive: Double(i * 10)), meta: ["pinned": true])
        }
        let profiles = rows.map(profile)
        let layout = RosterBuilder.build(.init(profiles: profiles)).layout
        #expect(layout.tiles.map(\.id) == ["b8", "b7", "b6", "b5", "b4", "b3"])
        #expect(layout.sections.map(\.id) == [RosterRules.pinnedSectionId])
        #expect(layout.sections[0].bots.map(\.id) == ["b2", "b1"])
        #expect(layout.sections[0].bots.allSatisfy { $0.sectionName == "Pinned" && $0.pinOrder == nil })
        // Dragged order first; never-placed pins after, in sort order.
        let ordered = RosterBuilder.build(.init(profiles: profiles, pinOrder: ["b1", "b2"])).layout
        #expect(ordered.tiles.map(\.id) == ["b1", "b2", "b8", "b7", "b6", "b5"])
        #expect(ordered.sections[0].bots.map(\.id) == ["b4", "b3"])
    }

    @Test func hiddenBotsGoLast() {
        let rows = [BotsTest.row("a", canonical: BotsTest.session("x", lastActive: 900), meta: ["hidden": true, "pinned": true]),
                    BotsTest.row("b", canonical: BotsTest.session("y", lastActive: 100))]
        let layout = RosterBuilder.build(.init(profiles: rows.map(profile))).layout
        #expect(layout.tiles.isEmpty)
        #expect(layout.unassigned.map(\.id) == ["b"])
        #expect(layout.hidden.map(\.id) == ["a"])
        #expect(layout.flat.map(\.id) == ["b", "a"])
    }

    /// §7.4: draw what the meta says, as the web reconciler would leave it.
    @Test func pinnedSectionReading() {
        let sections = [RosterSectionRecord(id: "sec-work", name: "Work")]
        let rows = [
            // Filed in Pinned by hand on a desktop (no recorded home): a pin.
            BotsTest.row("byhand", canonical: BotsTest.session("a", lastActive: 1), meta: ["sectionId": "hermes-hq-pinned"]),
            // Unpinned elsewhere, still in Pinned with its home recorded: back home.
            BotsTest.row("unpinned", canonical: BotsTest.session("b", lastActive: 2),
                         meta: ["pinned": false, "sectionId": "hermes-hq-pinned", "pinnedFrom": ["id": "sec-work", "name": "Work"]]),
            // Unpinned from no section.
            BotsTest.row("loose", canonical: BotsTest.session("c", lastActive: 3),
                         meta: ["pinned": false, "sectionId": "hermes-hq-pinned", "pinnedFrom": .null]),
            // Pinned on a phone whose write has not landed: still a pin (tile).
            BotsTest.row("pinnedwork", canonical: BotsTest.session("d", lastActive: 4), meta: ["pinned": true, "sectionId": "sec-work"]),
        ]
        let out = RosterBuilder.build(.init(profiles: rows.map(profile), sections: sections))
        #expect(Set(out.layout.tiles.map(\.id)) == ["byhand", "pinnedwork"])
        #expect(out.layout.sections.map(\.name) == ["Work"])
        #expect(out.layout.sections[0].bots.map(\.id) == ["unpinned"])
        #expect(out.layout.unassigned.map(\.id) == ["loose"])
        #expect(out.details["pinnedwork"]?.homeSectionId == "sec-work")
    }

    @Test func sectionAdoption() {
        let local = [RosterSectionRecord(id: "s1", name: "Clients"), RosterSectionRecord(id: "s9", name: "Empty")]
        let rows = [
            BotsTest.row("a", meta: ["sectionId": "s1", "sectionName": "Customers"]),
            BotsTest.row("b", meta: ["sectionId": "s1", "sectionName": "Customers"]),
            BotsTest.row("c", meta: ["sectionId": "s2", "sectionName": "Home"]),
            BotsTest.row("d", meta: ["sectionId": "s3"]),                                   // no name: nothing to adopt
            BotsTest.row("e", meta: ["sectionId": "hermes-hq-pinned", "sectionName": "Pinned"]),
        ].map(profile)
        let adopted = RosterBuilder.adoptSections(local, profiles: rows, meta: [:])
        #expect(adopted == [.init(id: "s1", name: "Customers"), .init(id: "s9", name: "Empty"), .init(id: "s2", name: "Home")])
        // Members disagree (a rename still landing): the local name stays.
        let split = [BotsTest.row("a", meta: ["sectionId": "s1", "sectionName": "One"]),
                     BotsTest.row("b", meta: ["sectionId": "s1", "sectionName": "Two"])].map(profile)
        #expect(RosterBuilder.adoptSections(local, profiles: split, meta: [:])[0].name == "Clients")
        // A member with only an id of a known section is filed there; an unknown one is unassigned.
        let layout = RosterBuilder.build(.init(profiles: [BotsTest.row("x", meta: ["sectionId": "s9"]),
                                                          BotsTest.row("y", meta: ["sectionId": "nope"])].map(profile),
                                               sections: local)).layout
        #expect(layout.sections.map(\.id) == ["s9"])
        #expect(layout.unassigned.map(\.id) == ["y"])
    }

    @Test func secondLineAndSearch() {
        let parts = RosterPreview.Parts(prefix: "From Inbox:", text: "Sorted", isFallback: false)
        #expect(RosterRules.secondLine(isWorking: false, preview: parts).line == "From Inbox: Sorted")
        #expect(RosterRules.secondLine(isWorking: true, preview: parts).text == "Working…")
        #expect(RosterRules.secondLine(isWorking: true, opening: true, preview: parts).text == "Waking up…")
        let bot = Bot(id: "default", name: "Hermes", role: "Your right hand", preview: "Pump quote", lastActive: nil, isWorking: false,
                      unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
        #expect(RosterRules.matches(bot, query: "@hermes"))
        #expect(RosterRules.matches(bot, query: "PUMP"))
        #expect(RosterRules.matches(bot, query: "right"))
        #expect(!RosterRules.matches(bot, query: "garden"))
    }

    @Test func busyErrors() {
        #expect(RosterRules.isGatewayBusy(RPCError(code: -1, message: "request timed out after 120s: profiles.list", data: nil)))
        #expect(RosterRules.isGatewayBusy(HTTPError(status: 503, body: nil)))
        #expect(RosterRules.isGatewayBusy(URLError(.timedOut)))
        #expect(!RosterRules.isGatewayBusy(RPCError(code: 5061, message: "boom", data: nil)))
        #expect(RosterRules.isGatewayNotConnected(RPCError(code: -1, message: "Gateway unavailable", data: nil)))
    }
    /// The row's own meta wins over the device snapshot (M1 makes no local meta writes); snapshot-only keys stay.
    @Test func rowMetaOverSnapshot() {
        let snapshot: [String: JSONValue] = ["ivy": ["pinned": false, "title": "Old", "color": "red"]]
        let row = RosterProfile(json: BotsTest.row("ivy", meta: ["pinned": true, "title": "New"]))!
        let meta = RosterBuilder.meta(for: row, snapshot: snapshot)
        #expect(meta.pinned && meta.title == "New")
        let bare = RosterProfile(json: BotsTest.row("ivy"))!
        #expect(RosterBuilder.meta(for: bare, snapshot: snapshot).title == "Old")
        #expect(RosterBuilder.meta(for: bare, snapshot: [:]).title == nil)
    }

    /// Reusing the preview cache gives the same rows; a changed session or role recomputes.
    @Test func previewCacheMatchesAFreshBuild() throws {
        let snapshot = try RosterSnapshot.decode(BotsFixture.json("demo-profiles-list"))
        let fresh = RosterBuilder.build(.init(profiles: snapshot.profiles))
        let reused = RosterBuilder.build(.init(profiles: snapshot.profiles, working: ["deploys"], previews: fresh.previews))
        #expect(fresh.previews.count == snapshot.profiles.count)
        #expect(reused.details == fresh.details)
        #expect(reused.layout.flat.map(\.preview) == fresh.layout.flat.map(\.preview))
        var changed = snapshot.profiles
        let index = try #require(changed.firstIndex { $0.name == "deploys" })
        changed[index].canonicalSession?.preview = "**New** words"
        var meta = changed[index].uiMeta["hermes-bots"]?.object ?? [:]
        meta["description"] = "A new role"
        changed[index].uiMeta["hermes-bots"] = .object(meta)
        let next = RosterBuilder.build(.init(profiles: changed, previews: reused.previews))
        #expect(next.details["deploys"]?.preview.text == "New words")
        #expect(next.layout.flat.first { $0.id == "deploys" }?.role == "A new role")
        #expect(next.details["research"] == fresh.details["research"])
    }
}
