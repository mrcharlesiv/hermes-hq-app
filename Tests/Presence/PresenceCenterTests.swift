// [presence] Unit tests for the presence centre (docs/spec/3x-presence.md §3.3, §13) and the main bot request (§10):
// gateway events in, the Bots rows' presence map and the notice's decision out. No window is given, so no notice view
// is made here; the notice itself is covered by the UI tests.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor private final class Board {
    var owners: [String: String] = ["r-ivy": "ivy", "r-main": "default", "r-side": "ivy"]
    var bots: [Bot] = [Board.bot("default", "Hermes"), Board.bot("ivy", "Ivy")]
    var off: Set<String> = []
    var visible: String?
    var published: [[String: BotPresence]] = []
    var browserOpened: [String] = []
    var screenOpened: [String] = []
    var inBackground = false
    /// What Watch was handed to run when it could not open (the notice comes back).
    var gaveUp: [() -> Void] = []

    static func bot(_ id: String, _ name: String) -> Bot {
        Bot(id: id, name: name, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: false, pinned: false,
            pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
    }

    func center(browser: BrowserService? = nil) -> PresenceCenter {
        PresenceCenter(browser: browser, context: PresenceCenter.Context(
            owner: { [unowned self] in self.owners[$0] },
            bots: { [unowned self] in self.bots },
            noticeOn: { [unowned self] in !self.off.contains($0) },
            visibleChatProfile: { [unowned self] in self.visible },
            face: { _ in nil },
            window: { nil },
            openBrowser: { [unowned self] scope, gaveUp in self.browserOpened.append(scope.profile); self.gaveUp.append(gaveUp) },
            openScreen: { [unowned self] bot, gaveUp in self.screenOpened.append(bot.id); self.gaveUp.append(gaveUp) },
            publish: { [unowned self] in self.published.append($0) },
            inBackground: { [unowned self] in self.inBackground }))
    }
}

private func toolStart(_ name: String, session: String, replayed: Bool = false) -> GatewayEvent {
    var event = GatewayEvent(type: "tool.start", sessionId: session, seq: nil, payload: ["name": .string(name)])
    event.replayed = replayed
    return event
}

private func replyDone(_ session: String) -> GatewayEvent {
    GatewayEvent(type: "message.complete", sessionId: session, seq: nil, payload: .null)
}

@MainActor @Suite(.serialized) struct PresenceCenterTests {
    @Test func aScreenToolMarksTheChatsOwnerAndTheReplyFinishingClearsIt() async {
        let board = Board()
        let center = board.center()
        center.handle(toolStart("browser_navigate", session: "r-ivy"))
        #expect(board.published == [["ivy": BotPresence(usingComputer: true)]])
        #expect(center.debugOutcomes == [.browser])
        #expect(center.debugExpiryArmed)

        // Another tool, another event type, an unknown chat: nothing more.
        center.handle(toolStart("terminal", session: "r-ivy"))
        center.handle(GatewayEvent(type: "message.delta", sessionId: "r-ivy", seq: nil, payload: .null))
        center.handle(toolStart("computer_use", session: "r-nobody"))
        #expect(center.debugOutcomes == [.browser, .none("no owner")])

        // The reply finished (in any of the bot's chats: the owner is the bot).
        center.handle(replyDone("r-side"))
        #expect(await BotsTest.waitUntil { board.published.last == [:] })
        #expect(!center.debugExpiryArmed)
        // A reply finishing for a bot that was not active publishes nothing.
        let count = board.published.count
        center.handle(replyDone("r-main"))
        try? await Task.sleep(for: PresenceCenter.publishGap + .milliseconds(100))
        #expect(board.published.count == count)
        center.shutdown()
    }

    @Test func twoBotsAreKeptApart() async {
        let board = Board()
        let center = board.center()
        center.handle(toolStart("computer_use", session: "r-main"))
        center.handle(toolStart("browser_click", session: "r-ivy"))
        #expect(await BotsTest.waitUntil {
            board.published.last == ["default": BotPresence(usingComputer: true), "ivy": BotPresence(usingComputer: true)]
        })
        center.handle(replyDone("r-main"))
        #expect(await BotsTest.waitUntil { board.published.last == ["ivy": BotPresence(usingComputer: true)] })
        center.shutdown()
    }

    /// The notice's decision, in the spec's order, read from what the centre recorded.
    @Test func theNoticeFollowsTheSwitchTheVisibleChatAndTheCooldown() async {
        let board = Board()
        let center = board.center()
        // Replayed after a reconnect: the row yes (after the coalescing gap, never at once), the notice never.
        center.handle(toolStart("browser_navigate", session: "r-ivy", replayed: true))
        #expect(center.debugOutcomes.last == .none("replayed"))
        #expect(board.published.isEmpty, "a replayed start is not published at once")
        #expect(await BotsTest.waitUntil { board.published.last == ["ivy": BotPresence(usingComputer: true)] })

        // Its switch is off.
        board.off = ["ivy"]
        center.handle(toolStart("browser_navigate", session: "r-ivy"))
        #expect(center.debugOutcomes.last == .none("off for this bot"))
        board.off = []

        // Its chat is on screen (any chat of the bot): the chat's own card says it.
        board.visible = "ivy"
        center.handle(toolStart("browser_navigate", session: "r-side"))
        #expect(center.debugOutcomes.last == .none("its chat is on screen"))

        // Another bot's chat on screen: the notice shows, once per 30 s.
        board.visible = "default"
        center.handle(toolStart("browser_navigate", session: "r-ivy"))
        #expect(center.debugOutcomes.last == .browser)
        center.handle(toolStart("browser_click", session: "r-ivy"))
        #expect(center.debugOutcomes.last == .none("cooldown"))
        // The other bot has its own cooldown; its own chat is on screen, so move away first.
        board.visible = nil
        center.handle(toolStart("browser_navigate", session: "r-main"))
        #expect(center.debugOutcomes.last == .browser)
        center.shutdown()
    }

    /// A reconnect replays a finished turn's screen tool and its end in one burst: the row never says "Using its
    /// computer" for it, not even for the coalescing gap.
    @Test func aReplayedTurnThatAlreadyEndedNeverShowsOnTheRow() async {
        let board = Board()
        let center = board.center()
        center.handle(toolStart("browser_navigate", session: "r-ivy", replayed: true))
        center.handle(toolStart("computer_use", session: "r-ivy", replayed: true))
        var done = replyDone("r-ivy")
        done.replayed = true
        center.handle(done)
        #expect(board.published.isEmpty)
        try? await Task.sleep(for: PresenceCenter.publishGap + .milliseconds(200))
        #expect(!board.published.contains { $0.values.contains { $0.usingComputer } }, "no publish says Using its computer")
        #expect(center.publishes <= 1)
        #expect(!center.debugExpiryArmed)

        // A replayed start with no end after it (the turn is still running) does show, one gap later.
        center.handle(toolStart("browser_navigate", session: "r-ivy", replayed: true))
        #expect(await BotsTest.waitUntil { board.published.last == ["ivy": BotPresence(usingComputer: true)] })
        // And a live start after a replayed end publishes at once again.
        var over = replyDone("r-ivy")
        over.replayed = true
        center.handle(over)
        #expect(await BotsTest.waitUntil { board.published.last == [:] })
        try? await Task.sleep(for: PresenceCenter.publishGap + .milliseconds(50))
        center.handle(toolStart("computer_use", session: "r-main"))
        #expect(board.published.last == ["default": BotPresence(usingComputer: true)])
        center.shutdown()
    }

    /// The app runs on for a moment after it leaves the screen: a tool start then sets the row but raises no notice
    /// (it would be found, stale, on the return) and spends no cooldown.
    @Test func noNoticeWhileTheAppIsInTheBackground() async {
        let board = Board()
        let center = board.center()
        board.inBackground = true
        center.handle(toolStart("browser_navigate", session: "r-ivy"))
        #expect(center.debugOutcomes == [.none("in the background")])
        #expect(board.published.last == ["ivy": BotPresence(usingComputer: true)], "the row still follows")
        board.inBackground = false
        center.handle(toolStart("browser_click", session: "r-ivy"))
        #expect(center.debugOutcomes.last == .browser, "the background start spent no cooldown")
        center.shutdown()
    }

    /// Watch could not open (an alert stayed on top for the whole wait): the notice is asked for again, unless there is
    /// nothing left to offer.
    @Test func aWatchThatCouldNotOpenIsOfferedAgain() {
        let board = Board()
        let center = board.center()
        let alert = PresenceNotice.Alert(profile: "ivy", name: "Ivy", kind: .browser, face: nil)
        center.debugWatch(alert)
        #expect(board.browserOpened == ["ivy"] && board.gaveUp.count == 1)
        board.gaveUp[0]()
        #expect(center.watchesOfferedAgain == 1)

        // A screen notice goes to the screen stream's opener, for the bot as the roster has it now.
        center.debugWatch(PresenceNotice.Alert(profile: "default", name: "Old Name", kind: .screen, face: nil))
        #expect(board.screenOpened == ["default"] && board.gaveUp.count == 2)
        // A bot that left the roster since: nothing opens.
        center.debugWatch(PresenceNotice.Alert(profile: "gone", name: "Gone", kind: .screen, face: nil))
        #expect(board.screenOpened == ["default"])

        // After sign-out a late give-up does nothing.
        center.shutdown()
        board.gaveUp[1]()
        center.debugWatch(alert)
        #expect(board.browserOpened == ["ivy"])
    }

    /// The screen half needs the screen stream's viewer (DECISION D6): without it nothing is offered and no cooldown is
    /// spent; with it the notice is the screen one.
    @Test func aScreenNoticeNeedsAScreenViewer() {
        let saved = (BotComputerHooks.openScreen, BotComputerHooks.screenIsOpen)
        defer { (BotComputerHooks.openScreen, BotComputerHooks.screenIsOpen) = saved }
        let board = Board()
        let center = board.center()

        BotComputerHooks.openScreen = nil
        BotComputerHooks.screenIsOpen = nil
        center.handle(toolStart("computer_use", session: "r-ivy"))
        #expect(center.debugOutcomes.last == .none("no screen viewer"))

        BotComputerHooks.openScreen = { _, _ in }
        center.handle(toolStart("computer_use", session: "r-ivy"))
        #expect(center.debugOutcomes.last == .screen)                 // the miss above spent no cooldown

        // A screen viewer already showing (any bot's): no notice for anyone.
        BotComputerHooks.screenIsOpen = { true }
        center.handle(toolStart("browser_navigate", session: "r-main"))
        #expect(center.debugOutcomes.last == .none("screen viewer open"))
        center.shutdown()
    }

    /// S1: five hundred tool starts in a burst cost a couple of roster rebuilds, not five hundred.
    @Test func aBurstOfToolStartsPublishesAFewTimes() async {
        // [ship, m9] This test is about a build with no Screen viewer. The hooks are the app's own now (the test host
        // sets them when it has a signed-in account), so they are pinned for the burst and put back before the wait.
        let saved = (BotComputerHooks.openScreen, BotComputerHooks.screenIsOpen)
        BotComputerHooks.openScreen = nil
        BotComputerHooks.screenIsOpen = nil
        let board = Board()
        let center = board.center()
        func start(_ i: Int) { center.handle(toolStart(i % 2 == 0 ? "browser_click" : "computer_use", session: i % 3 == 0 ? "r-main" : "r-ivy")) }
        for i in 0..<20 { start(i) }
        // One notice each; the rest fell to the cooldown (or, for the screen tools, to there being no screen viewer).
        #expect(center.debugOutcomes.count == 20 && center.debugOutcomes.filter { $0 == .browser }.count == 2)
        for i in 20..<500 { start(i) }
        (BotComputerHooks.openScreen, BotComputerHooks.screenIsOpen) = saved
        #expect(center.publishes <= 2)
        try? await Task.sleep(for: PresenceCenter.publishGap + .milliseconds(200))
        #expect(center.publishes == 2)
        #expect(board.published.last == ["default": BotPresence(usingComputer: true), "ivy": BotPresence(usingComputer: true)])
        #expect(center.debugOutcomes.count == 64)                     // the record is bounded
        #expect(!center.debugOutcomes.contains(.browser) && !center.debugOutcomes.contains(.screen))
        center.shutdown()
    }

    @Test func shuttingDownClearsTheRowsAndIgnoresWhatComesAfter() async {
        let board = Board()
        let center = board.center()
        center.handle(toolStart("browser_navigate", session: "r-ivy"))
        center.shutdown()
        #expect(board.published.last == [:])
        #expect(!center.debugExpiryArmed)
        let count = board.published.count
        center.handle(toolStart("browser_navigate", session: "r-main"))
        center.setBotsListShown(true)
        center.botsChanged()
        try? await Task.sleep(for: PresenceCenter.publishGap + .milliseconds(100))
        #expect(board.published.count == count && center.debugOutcomes == [.browser])
        #expect(!center.debugSubscribed)
        center.shutdown()                                            // twice is fine
        #expect(board.published.count == count)
    }

    /// The Bots rows' "Browsing …" line: read from the plugin's list only while the Bots list is on screen.
    @Test func theBrowserLineComesFromThePluginsListWhileTheBotsListShows() async {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in throw HTTPError(status: 404, body: nil) }
        let service = BrowserService(rest: client, sockets: NoPluginSockets())
        let board = Board()
        let center = board.center(browser: service)
        let row = BrowserRow(id: "0123456789abcdef01234567", profile: "ivy", sessionId: "s1", sessionIds: ["s1"],
                             url: "https://www.example.test/a", busy: 1, agentAt: Date().timeIntervalSince1970, active: true)

        // Not on screen: the list is not read.
        service.activity.debugPublish([row])
        #expect(board.published.isEmpty && !center.debugSubscribed && service.activity.debugListeners == 0)

        center.setBotsListShown(true)
        #expect(center.debugSubscribed && service.activity.debugListeners == 1)
        #expect(await BotsTest.waitUntil { board.published.last?["ivy"]?.browserLine == BrowserCard.statusLine(row) })
        #expect(board.published.last?["ivy"]?.browserLine?.hasPrefix("Browsing") == true)
        #expect(board.published.last?["default"] == nil)
        center.setBotsListShown(true)                                 // twice: still one listener
        #expect(service.activity.debugListeners == 1)

        // With a screen tool too: both on the one entry.
        center.handle(toolStart("browser_navigate", session: "r-ivy"))
        #expect(await BotsTest.waitUntil { board.published.last?["ivy"]?.usingComputer == true })
        #expect(board.published.last?["ivy"]?.browserLine != nil)

        // The browser went quiet: its line goes.
        var idle = row
        idle.active = false
        idle.busy = 0
        idle.agentAt = Date().timeIntervalSince1970 - 600
        service.activity.debugPublish([idle])
        #expect(await BotsTest.waitUntil { board.published.last?["ivy"]?.browserLine == BrowserCard.statusLine(idle) })

        // A bot that left the roster takes its line with it.
        service.activity.debugPublish([row])
        #expect(await BotsTest.waitUntil { board.published.last?["ivy"]?.browserLine != nil })
        board.bots = [Board.bot("default", "Hermes")]
        center.botsChanged()
        #expect(await BotsTest.waitUntil { board.published.last?["ivy"]?.browserLine == nil })

        center.setBotsListShown(false)
        #expect(!center.debugSubscribed && service.activity.debugListeners == 0)
        center.shutdown()
        service.shutdown()
    }

    /// UX study #135: on Sessions and More the centre holds the plugin's list open itself, one listener, gone with the tab.
    @Test func sessionsAndMoreHoldThePluginsListOpenForAsks() {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in throw HTTPError(status: 404, body: nil) }
        let service = BrowserService(rest: client, sockets: NoPluginSockets())
        let board = Board()                                           // held: the centre keeps it unowned
        let center = board.center(browser: service)
        #expect(!center.debugAsksHeard && service.activity.debugListeners == 0)
        center.setAsksHeard(true)
        center.setAsksHeard(true)                                     // twice: still one listener
        #expect(center.debugAsksHeard && service.activity.debugListeners == 1)
        center.setBotsListShown(true)                                 // the Bots list shares the socket
        #expect(service.activity.debugListeners == 2)
        center.setAsksHeard(false)
        #expect(!center.debugAsksHeard && service.activity.debugListeners == 1)
        center.setAsksHeard(true)
        center.shutdown()
        #expect(!center.debugAsksHeard && service.activity.debugListeners == 0)
        center.setAsksHeard(true)                                     // after shutdown: nothing
        #expect(service.activity.debugListeners == 0)
        service.shutdown()
        withExtendedLifetime(board) {}
    }
}

@MainActor struct MainBotRequestTests {
    @Test func theMainBotIsTheDefaultProfile() throws {
        #expect(throws: MainBotRequest.Failure(MainBotRequest.noMainBot)) { try MainBotRequest.mainBot([]) }
        #expect(throws: MainBotRequest.Failure(MainBotRequest.noMainBot)) { try MainBotRequest.mainBot([Board.bot("ivy", "Ivy")]) }
        #expect(try MainBotRequest.mainBot([Board.bot("ivy", "Ivy"), Board.bot("default", "Hermes")]).id == "default")
    }

    @Test func theWordsAreTheWebApps() {
        #expect(MainBotRequest.browserTitle == "Install the Hermes HQ browser add-on on this Hermes.")
        #expect(MainBotRequest.noMainBot == "Couldn’t find the main bot on the computer running Hermes. Open Bots and try again.")
        #expect(MainBotRequest.couldNotOpen == "Couldn’t open the bot’s chat. Try again.")
        #expect(MainBotRequest.notInTime == "The bot’s chat didn’t open in time. Try again.")
        #expect(MainBotRequest.couldNotSend == "Couldn’t send the request to the bot. Try again.")
        #expect(MainBotRequest.Failure(MainBotRequest.notInTime).localizedDescription == MainBotRequest.notInTime)
        for words in [MainBotRequest.browserTitle, MainBotRequest.noMainBot, MainBotRequest.couldNotOpen, MainBotRequest.notInTime,
                      MainBotRequest.couldNotSend, PresenceNotice.message(name: "Ivy", kind: .browser), PresenceNotice.message(name: "Ivy", kind: .screen)] {
            #expect(!words.localizedCaseInsensitiveContains("dispatch"))
        }
    }

    /// Before the main bot's chat is shown, what is over the tabs closes; a sheet with unsaved edits is never thrown
    /// away and an alert is never answered for the person.
    @Test func whatIsOpenClosesUnlessItHoldsUnsavedEdits() throws {
        #expect(MainBotRequest.leaveProblem(lockedSheet: false, alertOnTop: false) == nil)
        #expect(MainBotRequest.leaveProblem(lockedSheet: true, alertOnTop: false) == MainBotRequest.editingFirst)
        #expect(MainBotRequest.leaveProblem(lockedSheet: true, alertOnTop: true) == MainBotRequest.editingFirst)
        #expect(MainBotRequest.leaveProblem(lockedSheet: false, alertOnTop: true) == MainBotRequest.couldNotOpen)
        #expect(MainBotRequest.editingFirst == "Save or discard what you’re editing, then try again.")
        #expect(MainBotRequest.presented(over: nil).isEmpty)
        try MainBotRequest.checkCanLeave(nil)
        try MainBotRequest.checkCanLeave(UIViewController())
    }

    /// Asked twice (S7): the same request already waiting in the chat's queue is not queued again.
    @Test func askingTwiceQueuesOnce() {
        #expect(MainBotRequest.step(queued: [], text: "install it") == .send)
        #expect(MainBotRequest.step(queued: ["something else"], text: "install it") == .send)
        #expect(MainBotRequest.step(queued: ["something else", "install it"], text: "install it") == .alreadyQueued)
    }

    @Test func theNoticesWordsAndHowLongItStays() {
        #expect(PresenceNotice.message(name: "Ivy", kind: .browser) == "Ivy is using its browser")
        #expect(PresenceNotice.message(name: "Hermes", kind: .screen) == "Hermes is using its screen")
        // D40: an ask says what the chat's card says.
        #expect(PresenceNotice.message(name: "Ivy", kind: .browserAsk) == "Ivy needs you in its browser")
        #expect(PresenceNotice.message(name: "Ivy", kind: .browserAsk)
                == BrowserCard.words(BrowserRow(id: "b", profile: "ivy", ask: "Enter the code"), name: "Ivy"))
        // As drawn, the name is set apart so a right-to-left name does not reorder the sentence; the letters are the same.
        let drawn = PresenceNotice.drawn(name: "هيرميس", kind: .browser)
        #expect(drawn == "\u{2068}هيرميس\u{2069} is using its browser")
        let letters = String(String.UnicodeScalarView(drawn.unicodeScalars.filter { $0.value != 0x2068 && $0.value != 0x2069 }))
        #expect(letters == PresenceNotice.message(name: "هيرميس", kind: .browser))
        #expect(PresenceNotice.shownFor(voiceOver: false, hold: false) == 8)
        #expect(PresenceNotice.shownFor(voiceOver: true, hold: false) == 16)
    }
}

/// The capsule's own rules that need no screen: who holds it and when its leave timer runs (spec §8.3).
@MainActor @Suite(.serialized) struct PresenceNoticeTests {
    private func alert(_ profile: String, _ name: String) -> PresenceNotice.Alert {
        PresenceNotice.Alert(profile: profile, name: name, kind: .browser, face: nil)
    }

    @Test func aHeldCapsuleStaysHeldWhenAnotherBotTakesIt() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let notice = PresenceNotice.shared
        notice.dismiss(up: true)
        var watched: [String] = []
        notice.show(alert("ivy", "Ivy"), in: window) { watched.append($0.profile) }
        #expect(notice.isShowing && notice.timerArmed && notice.showingProfile == "ivy")

        // A finger (or VoiceOver's cursor) on it: no timer.
        notice.hold(true)
        #expect(!notice.timerArmed)
        // The same bot again, then another bot: the capsule is refreshed and handed over, still held.
        notice.show(alert("ivy", "Ivy"), in: window) { watched.append($0.profile) }
        #expect(!notice.timerArmed, "a refresh under a finger does not start the 8 s")
        notice.show(alert("default", "Hermes"), in: window) { watched.append($0.profile) }
        #expect(!notice.timerArmed && notice.showingProfile == "default")
        // Let go: now it runs.
        notice.hold(false)
        #expect(notice.timerArmed)
        // An unbalanced let-go (a focus lost twice) changes nothing.
        notice.hold(false)
        #expect(notice.timerArmed)

        // Tapped: Watch runs for the bot it shows now, once, and the capsule and its timer go.
        let view = notice.view
        view?.onTap?()
        #expect(watched == ["default"])
        #expect(!notice.isShowing && !notice.timerArmed)
        // The capsule that left can still end a gesture: it speaks for nobody.
        view?.onTap?()
        view?.onHold?(.touch, true)
        view?.onDismiss?()
        #expect(watched == ["default"] && !notice.timerArmed)

        // A new capsule starts with no holds, whatever the last one was left with.
        notice.show(alert("ivy", "Ivy"), in: window) { watched.append($0.profile) }
        notice.hold(true)
        notice.dismiss(up: true)
        notice.hold(false)                                           // nothing on screen: nothing to hold
        #expect(!notice.timerArmed)
        notice.show(alert("ivy", "Ivy"), in: window) { watched.append($0.profile) }
        #expect(notice.timerArmed)
        notice.dismiss(up: true)
        #expect(!notice.isShowing)
    }

    // MARK: The finger (stress round 1: a swipe taken as a tap, a notice stuck on screen, a nudge that opened Watch)

    /// A notice on a window of the test's own, and what its Watch was asked for.
    private final class Stage {
        let window: UIWindow
        var watched: [String] = []
        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            PresenceNotice.shared.dismiss(up: true)
        }
        func show(_ profile: String = "ivy", _ name: String = "Ivy") throws -> PresenceNotice.NoticeView {
            PresenceNotice.shared.show(PresenceNotice.Alert(profile: profile, name: name, kind: .browser, face: nil), in: window) {
                self.watched.append($0.profile)
            }
            return try #require(PresenceNotice.shared.view)
        }
    }

    @Test func whatATouchWasIsDecidedByWhereItWent() {
        typealias N = PresenceNotice
        #expect(N.outcome(travel: 0, rise: 0, speed: 0) == .tap)
        #expect(N.outcome(travel: 9, rise: -9, speed: -900) == .tap, "a finger's own jitter is still a tap")
        #expect(N.outcome(travel: 12, rise: -12, speed: -240) == .settle, "a 12 pt nudge up is not a tap")
        #expect(N.outcome(travel: 12, rise: 0, speed: 0) == .settle, "nor a nudge sideways")
        #expect(N.outcome(travel: 12, rise: -12, speed: -600) == .dismiss, "a flick up sends it away")
        #expect(N.outcome(travel: 68, rise: -68, speed: 0) == .dismiss, "up by more than 18 pt sends it away, however slowly")
        #expect(N.outcome(travel: 68, rise: -2, speed: 0) == .settle, "up and back down again: it stays")
        #expect(N.outcome(travel: 60, rise: 60, speed: 900) == .settle, "down only gives a little")
        #expect(N.outcome(travel: 40, rise: 5, speed: -900) == .settle, "a flick up that ended below where it began is not away")
    }

    @Test func aSwipeUpIsNeverATapHoweverItsEventsArrive() throws {
        let stage = try Stage()
        let notice = PresenceNotice.shared
        // The whole swipe arrives as two events (the app was stalled while the finger moved): down, then up 68 pt higher.
        var view = try stage.show()
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 10)
        #expect(!notice.timerArmed && view.isTouched)
        view.touchEnded(at: CGPoint(x: 201, y: 24), time: 10.7, cancelled: false)
        #expect(!notice.isShowing && stage.watched.isEmpty, "sent away, and Watch did not run")

        // The same with its moves delivered.
        view = try stage.show()
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 20)
        for step in 1...10 { view.touchMoved(to: CGPoint(x: 201, y: 92 - CGFloat(step) * 6.8), time: 20 + Double(step) * 0.07) }
        #expect(view.transform.ty < -60, "it follows the finger up")
        view.touchEnded(at: CGPoint(x: 201, y: 24), time: 20.7, cancelled: false)
        #expect(!notice.isShowing && stage.watched.isEmpty)

        // A capsule on its way out takes no more touches and speaks for nobody.
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 30)
        view.touchEnded(at: CGPoint(x: 201, y: 92), time: 30.1, cancelled: false)
        #expect(stage.watched.isEmpty && !view.isTouched)
    }

    @Test func aTapIsATapAndANudgeIsNot() throws {
        let stage = try Stage()
        let notice = PresenceNotice.shared
        // 12 pt up in 50 ms: neither a tap nor a swipe. It stays, and its 8 s start again.
        var view = try stage.show()
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 10)
        view.touchMoved(to: CGPoint(x: 201, y: 86), time: 10.025)
        view.touchEnded(at: CGPoint(x: 201, y: 80), time: 10.05, cancelled: false)
        #expect(stage.watched.isEmpty && notice.isShowing && notice.timerArmed && !view.isTouched)
        // Pulled down and let go: it stays.
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 11)
        view.touchMoved(to: CGPoint(x: 201, y: 152), time: 11.3)
        #expect(abs(view.transform.ty - 12) < 0.5, "down only gives a fifth")
        view.touchEnded(at: CGPoint(x: 201, y: 152), time: 11.4, cancelled: false)
        #expect(stage.watched.isEmpty && notice.isShowing && notice.timerArmed)
        // Up 60 pt and back to where it began, then lifted: it wandered, so it is not a tap.
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 12)
        view.touchMoved(to: CGPoint(x: 201, y: 32), time: 12.2)
        view.touchMoved(to: CGPoint(x: 201, y: 92), time: 12.6)
        view.touchEnded(at: CGPoint(x: 201, y: 92), time: 12.9, cancelled: false)
        #expect(stage.watched.isEmpty && notice.isShowing && notice.timerArmed)
        // A real tap (3 pt of jitter): Watch, once.
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 13)
        view.touchMoved(to: CGPoint(x: 203, y: 90), time: 13.05)
        view.touchEnded(at: CGPoint(x: 203, y: 90), time: 13.1, cancelled: false)
        #expect(stage.watched == ["ivy"] && !notice.isShowing)

        // A finger that rests for a long time and lifts where it landed is still a tap on Watch.
        view = try stage.show("default", "Hermes")
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 20)
        #expect(!notice.timerArmed)
        view.touchEnded(at: CGPoint(x: 201, y: 92), time: 31, cancelled: false)
        #expect(stage.watched == ["ivy", "default"])
    }

    @Test func theLeaveTimerAlwaysComesBackWhenNoFingerIsOnIt() throws {
        let stage = try Stage()
        let notice = PresenceNotice.shared
        let view = try stage.show()
        // A touch the system took away.
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 10)
        view.touchMoved(to: CGPoint(x: 201, y: 60), time: 10.2)
        #expect(!notice.timerArmed)
        view.touchEnded(at: CGPoint(x: 201, y: 60), time: 10.3, cancelled: true)
        #expect(notice.isShowing && notice.timerArmed && stage.watched.isEmpty, "cancelled: it stays and its time runs")
        // Down reported twice, up once (events out of step): one let-go is enough, because a hold is not counted.
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 11)
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 11.01)
        notice.hold(true)
        #expect(!notice.timerArmed)
        view.touchEnded(at: CGPoint(x: 240, y: 92), time: 11.5, cancelled: false)
        #expect(notice.isShowing && notice.timerArmed && !view.isTouched)
        // Up with no down, and up twice: nothing.
        view.touchEnded(at: CGPoint(x: 201, y: 20), time: 12, cancelled: false)
        view.touchEnded(at: CGPoint(x: 201, y: 92), time: 12.1, cancelled: false)
        #expect(notice.isShowing && notice.timerArmed && stage.watched.isEmpty)

        // VoiceOver's cursor and a finger overlap: each lets go for itself.
        notice.hold(true, by: .voiceOver)
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 13)
        view.touchEnded(at: CGPoint(x: 240, y: 92), time: 13.4, cancelled: false)
        #expect(!notice.timerArmed, "VoiceOver still holds it")
        notice.hold(false, by: .voiceOver)
        #expect(notice.timerArmed)
        notice.dismiss(up: true)

        // Sent away under a finger (its viewer opened another way): the late lift changes nothing, and the next
        // capsule starts unheld.
        let old = try stage.show()
        old.touchBegan(at: CGPoint(x: 201, y: 92), time: 20)
        notice.dismiss(about: "ivy")
        old.touchEnded(at: CGPoint(x: 201, y: 92), time: 21, cancelled: false)
        #expect(stage.watched.isEmpty && !notice.isShowing)
        _ = try stage.show()
        #expect(notice.timerArmed)
        notice.dismiss(up: true)
    }

    /// Stress round 1: a touch whose lift never arrived (the app was stopped as the finger came down) held the notice
    /// on screen for good, and the next tap on it did nothing.
    @Test func aFingerThatNeverLiftsCannotKeepItForGood() async throws {
        let stage = try Stage()
        let notice = PresenceNotice.shared
        let usual = notice.restingFingerSeconds
        #expect(usual == 30)
        defer { notice.restingFingerSeconds = usual }
        notice.restingFingerSeconds = 0.6

        // Down, one move, and nothing more, ever.
        var view = try stage.show()
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 10)
        view.touchMoved(to: CGPoint(x: 201, y: 80), time: 10.1)
        #expect(notice.isShowing && !notice.timerArmed)
        #expect(await BotsTest.waitUntil(.seconds(10)) { !notice.isShowing }, "it leaves once the finger has been still that long")
        #expect(stage.watched.isEmpty)

        // A finger that keeps moving keeps it; it leaves only after the finger has been still.
        view = try stage.show()
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 20)
        var moved = Date()
        var kept = 0
        for step in 1...6 {
            try await Task.sleep(for: .milliseconds(200))
            // (On a busy Mac the sleep itself can outlast the limit: only a move made in time proves anything.)
            guard Date().timeIntervalSince(moved) < 0.45 else { break }
            #expect(notice.isShowing, "still held after \(step - 1) moves")
            view.touchMoved(to: CGPoint(x: 201 + CGFloat(step), y: 92), time: 20 + Double(step) * 0.2)
            moved = Date()
            kept += 1
        }
        if kept >= 4 { #expect(notice.isShowing, "0.8 s after it landed, past the limit, a finger that kept moving still holds it") }
        #expect(await BotsTest.waitUntil(.seconds(10)) { !notice.isShowing })

        // A lift in time ends the watch: the notice then has its own 8 s.
        view = try stage.show()
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 30)
        view.touchEnded(at: CGPoint(x: 240, y: 92), time: 30.2, cancelled: false)
        try await Task.sleep(for: .milliseconds(900))
        #expect(notice.isShowing && notice.timerArmed, "the resting-finger watch ended with the lift")

        // With a finger stuck on it, a new finger still counts: the old touch is dropped and the new one is a tap.
        view.touchBegan(at: CGPoint(x: 201, y: 92), time: 40)
        view.touchEnded(at: CGPoint(x: 201, y: 92), time: 40.0, cancelled: true)     // what the tracker does to the old one
        view.touchBegan(at: CGPoint(x: 300, y: 92), time: 41)
        view.touchEnded(at: CGPoint(x: 300, y: 92), time: 41.1, cancelled: false)
        #expect(stage.watched == ["ivy"] && !notice.isShowing)
    }

    @Test func aLongNameIsShortenedSoTheWordsAlwaysShow() throws {
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        #expect(PresenceNotice.fitted(name: "Ivy", kind: .browser, font: font, width: 220) == PresenceNotice.drawn(name: "Ivy", kind: .browser))
        let long = String(repeating: "Averyveryverylongname ", count: 4) + "x"            // 89 letters
        for (size, width) in [(CGFloat(15), CGFloat(220)), (28, 300), (40, 160)] {
            let font = UIFont.systemFont(ofSize: size, weight: .semibold)
            let text = PresenceNotice.fitted(name: long, kind: .screen, font: font, width: width)
            #expect(text.hasSuffix("… is using its screen") || text.hasSuffix("…\u{2069} is using its screen"), "\(text)")
            #expect(text.hasPrefix("\u{2068}A"), "at least the name's first letter stays")
            if size < 40 { #expect(text.hasPrefix("\u{2068}Averyvery"), "as much of the name as fits") }
            let label = UILabel()
            label.numberOfLines = 0
            label.font = font
            label.text = text
            if size < 40 {
                #expect(label.sizeThatFits(CGSize(width: width, height: 10_000)).height <= ceil(font.lineHeight * 2) + 1, "two lines at \(size) pt")
            }
        }
        // On the capsule: the fixed words are there at the largest text the capsule allows, and VoiceOver hears the whole name.
        let stage = try Stage()
        stage.window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let view = try stage.show("ivy", long)
        #expect(view.shownWords.hasSuffix("is using its browser") && view.shownWords.contains("…"), "\(view.shownWords)")
        #expect(view.accessibilityLabel == "\(long) is using its browser")
        PresenceNotice.shared.dismiss(up: true)
    }
}
