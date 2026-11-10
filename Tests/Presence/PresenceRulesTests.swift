// [presence] Unit tests for the pure rules (docs/spec/3x-presence.md §13, 1–5): screen tools, the 90 s window, the
// notice gate in the web's order, and the Bots row's line, tone and badge.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct PresenceRulesTests {
    private let t0 = ContinuousClock.now

    // MARK: 1. Screen tools

    /// D4: a write the gateway never answered says so in plain words; the client's own line stays in the details.
    @Test func aWriteWithNoAnswerIsSaidInPlainWords() {
        let title = "Couldn’t Change the Alert"
        let timedOut = RPCError.timedOut("profiles.configure", after: .seconds(30))
        let plain = NoticeWriteWords.plain(BotWriteError(title: title, reason: BotWriteOutcome.reason(timedOut), detail: "\(timedOut)"))
        #expect(plain.title == title && plain.reason == "The computer running Hermes didn’t answer in time.")
        #expect(plain.detail?.contains("request timed out after 30s: profiles.configure") == true)
        let lost = RPCError.connectionLost("profiles.configure")
        #expect(NoticeWriteWords.plain(BotWriteError(title: title, reason: BotWriteOutcome.reason(lost))).reason
                == "The connection dropped before the computer running Hermes answered.")
        // Anything the gateway did say is left as it was said.
        let refused = BotWriteError(title: title, reason: BotWriteError.notSavedReason, detail: "{}")
        #expect(NoticeWriteWords.plain(refused) == refused)
        let other = BotWriteError(title: title, reason: "This profile is locked.")
        #expect(NoticeWriteWords.plain(other) == other)
    }

    @Test func screenToolNames() {
        for name in ["computer_use", "computer_use_click", "browser_navigate", "browser_"] {
            #expect(ScreenTools.isScreenTool(name), "\(name)")
        }
        for name in ["terminal", "", "Browser_navigate", "xbrowser_click", "computer", "COMPUTER_USE", " browser_x"] {
            #expect(!ScreenTools.isScreenTool(name), "\(name)")
        }
        #expect(!ScreenTools.isScreenTool(nil))
        #expect(ScreenTools.isBrowserTool("browser_navigate") && ScreenTools.isBrowserTool("browser_"))
        #expect(!ScreenTools.isBrowserTool("computer_use_click") && !ScreenTools.isBrowserTool("Browser_x"))
        #expect(!ScreenTools.isBrowserTool(nil) && !ScreenTools.isBrowserTool(""))
        #expect(ScreenTools.quiet == .seconds(90) && ScreenTools.noticeCooldown == .seconds(30) && ScreenTools.noticeSeconds == 8)
    }

    // MARK: 2. The 90 s window

    @Test func computerActivityWindow() {
        var activity = ComputerActivity()
        #expect(activity.nextExpiry() == nil)
        activity.toolStarted("ivy", at: t0)
        #expect(activity.active(at: t0 + .milliseconds(89_900)) == ["ivy"])
        #expect(activity.nextExpiry() == t0 + .seconds(90))
        // A second start at 60 s moves the end to 150 s.
        activity.toolStarted("ivy", at: t0 + .seconds(60))
        #expect(activity.active(at: t0 + .seconds(120)) == ["ivy"])
        #expect(activity.active(at: t0 + .milliseconds(149_900)) == ["ivy"])
        #expect(activity.active(at: t0 + .seconds(150)).isEmpty)
        // Expired entries are dropped, so nothing is left to wait for.
        #expect(activity.lastAt.isEmpty && activity.nextExpiry() == nil)
    }

    @Test func computerActivityNotActiveAtNinetySeconds() {
        var activity = ComputerActivity()
        activity.toolStarted("ivy", at: t0)
        #expect(activity.active(at: t0 + .seconds(90)).isEmpty)
    }

    @Test func replyFinishedClearsAndSaysSo() {
        var activity = ComputerActivity()
        activity.toolStarted("ivy", at: t0)
        activity.toolStarted("default", at: t0 + .seconds(10))
        #expect(activity.nextExpiry() == t0 + .seconds(90))            // the earliest
        let first = activity.replyFinished("ivy")
        let again = activity.replyFinished("ivy")                      // already cleared: nothing to republish
        let nobody = activity.replyFinished("nobody")
        #expect(first && !again && !nobody)
        #expect(activity.active(at: t0 + .seconds(20)) == ["default"])
        #expect(activity.nextExpiry() == t0 + .seconds(100))
        activity.toolStarted("", at: t0)                               // a nameless launch home is nobody
        #expect(activity.active(at: t0 + .seconds(20)) == ["default"])
        activity.reset()
        #expect(activity.active(at: t0).isEmpty)
    }

    // MARK: 3. The notice gate

    private func input(_ tool: String? = "browser_navigate", profile: String? = "ivy", replayed: Bool = false, on: Bool = true,
                       visible: String? = nil, screenOpen: Bool = false, watching: Bool = false,
                       canWatchScreen: Bool = false) -> NoticeGate.Input {
        NoticeGate.Input(replayed: replayed, toolName: tool, profile: profile, noticeOn: on, visibleChatProfile: visible,
                         screenViewerOpen: screenOpen, watchingThisBrowser: watching, canWatchScreen: canWatchScreen)
    }

    @Test func gateTableInTheWebsOrder() {
        var gate = NoticeGate()
        #expect(gate.decide(input(replayed: true), now: t0) == .none("replayed"))
        #expect(gate.decide(input("terminal"), now: t0) == .none("not a screen tool"))
        #expect(gate.decide(input(nil), now: t0) == .none("not a screen tool"))
        #expect(gate.decide(input(profile: nil), now: t0) == .none("no owner"))
        #expect(gate.decide(input(profile: ""), now: t0) == .none("no owner"))
        #expect(gate.decide(input(on: false), now: t0) == .none("off for this bot"))
        #expect(gate.decide(input(visible: "ivy"), now: t0) == .none("its chat is on screen"))
        #expect(gate.decide(input("computer_use_click"), now: t0) == .none("no screen viewer"))
        #expect(gate.decide(input(screenOpen: true), now: t0) == .none("screen viewer open"))
        #expect(gate.last.isEmpty)                                     // none of the above stamped the cooldown
        #expect(gate.decide(input(), now: t0) == .browser)
        #expect(gate.last["ivy"] == t0)
        #expect(gate.decide(input(), now: t0 + .seconds(5)) == .none("cooldown"))
        #expect(gate.decide(input(), now: t0 + .milliseconds(29_900)) == .none("cooldown"))
        #expect(gate.decide(input(), now: t0 + .seconds(30)) == .browser)
        #expect(gate.decide(input("computer_use_click", canWatchScreen: true), now: t0 + .seconds(61)) == .screen)
    }

    /// A replayed start is skipped before anything else, whatever the rest says (E10).
    @Test func aReplayedStartNeverNotifies() {
        var gate = NoticeGate()
        for tool in ["browser_navigate", "computer_use_click"] {
            #expect(gate.decide(input(tool, replayed: true, canWatchScreen: true), now: t0) == .none("replayed"))
        }
        #expect(gate.last.isEmpty)
    }

    @Test func twoBotsAreIndependent() {
        var gate = NoticeGate()
        #expect(gate.decide(input(profile: "ivy"), now: t0) == .browser)
        #expect(gate.decide(input(profile: "default"), now: t0 + .seconds(1)) == .browser)
        #expect(gate.decide(input(profile: "ivy"), now: t0 + .seconds(2)) == .none("cooldown"))
        #expect(gate.decide(input(profile: "default"), now: t0 + .seconds(31)) == .browser)
    }

    /// As on the web (shouldNudge runs before browserWatchOpen): a notice held back because the person is already
    /// watching still starts the 30 s.
    @Test func alreadyWatchingStillStampsTheCooldown() {
        var gate = NoticeGate()
        #expect(gate.decide(input(watching: true), now: t0) == .none("already watching"))
        #expect(gate.last["ivy"] == t0)
        #expect(gate.decide(input(), now: t0 + .seconds(10)) == .none("cooldown"))
        #expect(gate.decide(input(), now: t0 + .seconds(30)) == .browser)
    }

    @Test func screenViewerOpenAndNoViewerStampNothing() {
        var gate = NoticeGate()
        #expect(gate.decide(input(screenOpen: true), now: t0) == .none("screen viewer open"))
        #expect(gate.decide(input("computer_use", canWatchScreen: false), now: t0) == .none("no screen viewer"))
        #expect(gate.last.isEmpty)
        // So the first notice once the viewer is closed (or exists) is not held back.
        #expect(gate.decide(input(), now: t0 + .seconds(1)) == .browser)
    }

    /// Another bot's chat on screen does not hide this bot's notice; a screen tool in its own chat still notifies (the
    /// chat has no card for the screen).
    @Test func visibleChatOnlyHidesItsOwnBrowserNotice() {
        var gate = NoticeGate()
        #expect(gate.decide(input(profile: "ivy", visible: "default"), now: t0) == .browser)
        #expect(gate.decide(input("computer_use_click", profile: "default", visible: "default", canWatchScreen: true), now: t0) == .screen)
    }

    @Test func resetForgetsTheCooldown() {
        var gate = NoticeGate()
        #expect(gate.decide(input(), now: t0) == .browser)
        gate.reset()
        #expect(gate.decide(input(), now: t0 + .seconds(1)) == .browser)
    }

    // MARK: 4. The row's line, tone and badge

    private func bot(_ id: String = "ivy", working: Bool = false, preview: String? = "Hello", prefix: String? = nil,
                     needs: NeedsInput? = nil, presence: BotPresence? = nil) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: preview, lastActive: nil, isWorking: working, unread: false,
            pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil,
            needsInput: needs, previewPrefix: prefix, presence: presence)
    }

    @Test func rowStatusRanking() {
        let browsing = BotPresence(browserLine: "Browsing example.test", usingComputer: true)
        let computer = BotPresence(browserLine: nil, usingComputer: true)
        #expect(BotList.rowStatus(bot(working: true, needs: .approval, presence: browsing)) == .needsInput)
        #expect(BotList.rowStatus(bot(working: true, presence: browsing)) == .browser)
        #expect(BotList.rowStatus(bot(working: true, presence: computer)) == .computer)
        #expect(BotList.rowStatus(bot(working: true)) == .working)
        #expect(BotList.rowStatus(bot()) == .idle)
        #expect(BotList.rowStatus(bot(presence: BotPresence())) == .idle)
    }

    @Test func secondLineWordsAndTones() {
        let browsing = BotPresence(browserLine: "Browsing example.test", usingComputer: true)
        let waiting = BotList.secondLine(bot(working: true, needs: .approval, presence: browsing))
        #expect(waiting.text == NeedsInput.approval.statusText && waiting.tone == .attention)
        let browser = BotList.secondLine(bot(working: true, presence: browsing))
        #expect(browser.text == "Browsing example.test" && browser.tone == .tint)
        // DECISION D1: "Needs you in its browser" is tint too.
        let asks = BotList.secondLine(bot(presence: BotPresence(browserLine: "Needs you in its browser")))
        #expect(asks.text == "Needs you in its browser" && asks.tone == .tint)
        let computer = BotList.secondLine(bot(presence: BotPresence(usingComputer: true)))
        #expect(computer.text == "Using its computer" && computer.tone == .tint)
        let working = BotList.secondLine(bot(working: true))
        #expect(working.text == "Working…" && working.tone == .tint)
        let idle = BotList.secondLine(bot())
        #expect(idle.text == "Hello" && idle.tone == .secondary)
        #expect(BotList.secondLine(bot(preview: nil)).text == "No messages yet")
    }

    /// A pending draft keeps its line over the browser's; "Using its computer" and "Working…" still rank above it.
    @Test func theDraftException() {
        let browsing = BotPresence(browserLine: "Browsing example.test")
        let draft = bot(preview: "Draft: half a thought", prefix: "Draft:", presence: browsing)
        #expect(BotList.rowStatus(draft) == .idle)
        #expect(BotList.secondLine(draft).text == "Draft: half a thought")
        #expect(BotList.rowBadge(draft) == nil)
        let draftWorking = bot(working: true, preview: "Draft: half a thought", prefix: "Draft:", presence: browsing)
        #expect(BotList.secondLine(draftWorking).text == "Working…")
        let draftComputer = bot(preview: "Draft: x", prefix: "Draft:", presence: BotPresence(browserLine: "Using its browser", usingComputer: true))
        #expect(BotList.secondLine(draftComputer).text == "Using its computer")
        // Another lead ("From Inbox:") is not a draft.
        #expect(BotList.rowStatus(bot(preview: "From Inbox: hi", prefix: "From Inbox:", presence: browsing)) == .browser)
    }

    @Test func rowBadges() {
        #expect(BotList.rowBadge(bot(presence: BotPresence(usingComputer: true))) == .computer)
        #expect(BotList.rowBadge(bot(working: true, presence: BotPresence(usingComputer: true))) == .computer)
        #expect(BotList.rowBadge(bot(presence: BotPresence(browserLine: "Using its browser"))) == .working)
        #expect(BotList.rowBadge(bot(presence: BotPresence(browserLine: "Using its browser", usingComputer: true))) == .working)
        #expect(BotList.rowBadge(bot(working: true)) == .working)
        #expect(BotList.rowBadge(bot()) == nil)
        // Waiting for the person: as before this stream (dots only while a turn runs).
        #expect(BotList.rowBadge(bot(needs: .approval, presence: BotPresence(usingComputer: true))) == nil)
        #expect(BotList.rowBadge(bot(working: true, needs: .approval, presence: BotPresence(usingComputer: true))) == .working)
    }

    @Test func voiceOverLabelCarriesTheLine() {
        let computer = bot(presence: BotPresence(usingComputer: true))
        #expect(BotList.accessibilityLabel(computer, time: "9:41") == "Ivy. Using its computer. 9:41")
        let browsing = bot(presence: BotPresence(browserLine: "Browsing example.test"))
        #expect(BotList.accessibilityLabel(browsing, time: "") == "Ivy. Browsing example.test")
    }

    /// Stress round 1: "Handing you its browser…. Sep 29" (an ellipsis and then a full stop).
    @Test func voiceOverLabelDoesNotStopTwice() {
        let handing = bot(presence: BotPresence(browserLine: "Handing you its browser…"))
        #expect(BotList.accessibilityLabel(handing, time: "Sep 29") == "Ivy. Handing you its browser… Sep 29")
        #expect(BotList.spoken(["Ivy", "Are you there?", "9:41", "Unread"]) == "Ivy. Are you there? 9:41. Unread")
        #expect(BotList.spoken(["Ivy", "Done.", "", "Pinned"]) == "Ivy. Done. Pinned")
        #expect(BotList.spoken(["Ivy", "Working…"]) == "Ivy. Working…")
    }

    /// Stress round 1: an address that is not a web page is not repeated raw in the row.
    @Test func theRowNamesOnlyAWebSite() {
        func line(_ url: String) -> String? {
            BrowserCard.statusLine(BrowserRow(id: "abcdefabcdefabcdefabcdef", profile: "ivy", url: url, active: true))
        }
        #expect(line("https://www.example.test/sign-in") == "Browsing example.test")
        #expect(line("http://localhost:8080/x") == "Browsing localhost:8080")
        for odd in ["javascript:alert(1)", "not a url at all", "about:blank", "about:config", "data:text/html,hi",
                    "file:///etc/hosts", "https://", "", "chrome://newtab/"] {
            #expect(line(odd) == "Using its browser", "\(odd)")
        }
    }

    // MARK: 5. The roster builder

    private func profile(_ json: JSONValue) -> RosterProfile { RosterProfile(json: json)! }

    @Test func rosterBuilderPutsPresenceOnTheRightBot() {
        let rows = [BotsTest.row("default"), BotsTest.row("ivy"), BotsTest.row("tile", meta: ["pinned": true]),
                    BotsTest.row("gone", meta: ["hidden": true])]
        var input = RosterBuilder.Input(profiles: rows.map(profile), pinOrder: ["tile"])
        input.presence = ["ivy": BotPresence(browserLine: "Browsing example.test"),
                          "tile": BotPresence(usingComputer: true),
                          "gone": BotPresence(browserLine: "Using its browser", usingComputer: true),
                          "default": BotPresence(),                      // empty: stays nil on the bot
                          "stranger": BotPresence(usingComputer: true)]   // not in the roster: ignored
        let layout = RosterBuilder.build(input).layout
        let all = layout.flat
        #expect(all.first { $0.id == "ivy" }?.presence == BotPresence(browserLine: "Browsing example.test"))
        #expect(all.first { $0.id == "default" }?.presence == nil)
        #expect(layout.tiles.first { $0.id == "tile" }?.presence?.usingComputer == true)
        #expect(layout.hidden.first { $0.id == "gone" }?.presence?.browserLine == "Using its browser")
        #expect(!all.contains { $0.id == "stranger" })
        // No presence at all: every bot's field is nil, so an idle roster equals the one built before this stream.
        let idle = RosterBuilder.build(.init(profiles: rows.map(profile), pinOrder: ["tile"])).layout
        #expect(idle.flat.allSatisfy { $0.presence == nil })
        #expect(idle != layout)
    }

    // MARK: Bots row: only the bot's own chat's browsing (owner Oct 15: a scheduled job's browsing lit Hermes' tile)

    @Test func botRowSpeaksOnlyForItsOwnChatUnlessThePersonIsNeeded() {
        let own: Set<String> = ["", "20260101_090000_aa0004"]
        let job = BrowserRow(id: "aaaaaaaaaaaaaaaaaaaaaaaa", profile: "default", sessionId: "cron_e210a1b7e4a5_20261015_113006",
                             url: "https://example.test", agentAt: 200, active: true)
        #expect(BrowserCard.botRow([job], profile: "default", ownChats: own) == nil, "a scheduled job browsing stays off the bot")
        #expect(BrowserCard.statusLine(BrowserCard.botRow([job], profile: "default", ownChats: own)) == nil)
        #expect(BrowserCard.botRow([job], profile: "default", ownChats: nil) == job, "roster not known yet: as before")

        var asking = job
        asking.ask = "Sign in, please"
        #expect(BrowserCard.botRow([asking], profile: "default", ownChats: own) == asking, "needing the person always shows")
        var held = job
        held.control = .person
        #expect(BrowserCard.botRow([held], profile: "default", ownChats: own) == held)

        let mine = BrowserRow(id: "bbbbbbbbbbbbbbbbbbbbbbbb", profile: "default", sessionId: "20260101_090000_aa0004",
                              url: "https://mine.test", agentAt: 100, active: true)
        #expect(BrowserCard.botRow([job, mine], profile: "default", ownChats: own) == mine, "an older own-chat use still shows")
        #expect(BrowserCard.botRow([mine], profile: "ivy", ownChats: own) == nil)

        let standing = BrowserRow(id: "cccccccccccccccccccccccc", profile: "default", sessionIds: ["cron_x"], agentAt: 300, active: true)
        #expect(BrowserCard.botRow([standing], profile: "default", ownChats: own) == nil, "no session id: its last chat decides")
        let unnamed = BrowserRow(id: "dddddddddddddddddddddddd", profile: "default", agentAt: 300, active: true)
        #expect(BrowserCard.botRow([unnamed], profile: "default", ownChats: own) == unnamed, "no chat named at all: the bot's")
    }
}
