// [live] The Lock Screen progress rules (HermesKit/Live/LiveActivityRules.swift) and the center that hands them to
// ActivityKit (App/Live/LiveActivityCenter.swift), with a recording driver in ActivityKit's place.

import CryptoKit
import Foundation
import Testing
@testable import HermesHQNative

nonisolated private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

nonisolated private func bot(_ id: String, working: Bool, name: String? = nil) -> LiveBot {
    LiveBot(id: id, name: name ?? id.capitalized, isWorking: working, link: "hermes://session/s-\(id)")
}

nonisolated private func turn(_ id: String) -> LiveActivitySubject { LiveActivitySubject(kind: .turn, id: id) }
nonisolated private func job(_ key: String) -> LiveActivitySubject { LiveActivitySubject(kind: .job, id: key) }

nonisolated private func started(_ commands: [LiveActivityCommand]) -> [LiveActivitySubject] {
    commands.compactMap { if case .start(let start) = $0 { return start.subject } else { return nil } }
}

@Suite struct LiveActivityTurnRulesTests {
    /// Owner, 2026-11-01: a message sent and the phone locked at once showed no card (the rule was 20 s); iOS lets the
    /// app start one only while it is in front, so a turn that has only just begun gets its card too.
    @Test func aTurnJustBegunStartsItsCardWhenTheAppIsLeft() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("otto", working: true)], now: t0, appActive: true)
        #expect(started(planner.leaving([bot("otto", working: true)], now: t0.addingTimeInterval(1))) == [turn("otto")])
        var shortened = LiveActivityPlanner()
        shortened.turnThreshold = 3   // a UI test's -HQDebugLiveThreshold still holds
        _ = shortened.bots([bot("otto", working: true)], now: t0, appActive: true)
        #expect(shortened.leaving([bot("otto", working: true)], now: t0.addingTimeInterval(2)).isEmpty)
    }

    @Test func aQuickReplysDoneGoesAfterAMinuteALongerOnesAfterFifteen() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("a", working: true), bot("b", working: true)], now: t0, appActive: true)
        _ = planner.leaving([bot("a", working: true), bot("b", working: true)], now: t0.addingTimeInterval(2))
        let quick = t0.addingTimeInterval(40)
        #expect(planner.bots([bot("a", working: false), bot("b", working: true)], now: quick, appActive: false)
                == [.end(turn("a"), LiveActivityContent(phase: .done, startedAt: t0, endedAt: quick), .after(quick.addingTimeInterval(60)))])
        let longer = t0.addingTimeInterval(60)
        #expect(planner.bots([bot("b", working: false)], now: longer, appActive: false)
                == [.end(turn("b"), LiveActivityContent(phase: .done, startedAt: t0, endedAt: longer), .after(longer.addingTimeInterval(15 * 60)))])
        #expect(LiveActivityTiming.linger(ran: -5) == 15 * 60, "a clock that moved back lingers the usual time")
    }

    @Test("A voice conversation's own chat gets no reply card: the conversation's card already shows its turn")
    func aTalkChatsTurnGetsNoSecondCard() {
        var planner = LiveActivityPlanner()
        var talking = bot("otto", working: true)
        talking.session = "s-otto"
        var other = bot("ada", working: true)
        other.session = "s-ada"
        _ = planner.bots([talking, other], now: t0, appActive: true)
        #expect(started(planner.leaving([talking, other], now: t0.addingTimeInterval(2), talking: "s-otto")) == [turn("ada")])
        #expect(planner.live[turn("otto")] == nil)
    }

    @Test func aLongTurnStartsWorkingWithItsOwnStartTimeAndLink() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("otto", working: true, name: "Otto"), bot("idle", working: false)], now: t0, appActive: true)
        let commands = planner.leaving([bot("otto", working: true, name: "Otto"), bot("idle", working: false)], now: t0.addingTimeInterval(25))
        #expect(commands == [.start(LiveActivityStart(subject: turn("otto"), botName: "Otto", detail: nil, link: "hermes://session/s-otto",
                                                      content: LiveActivityContent(phase: .working, startedAt: t0)))])
        // Leaving again (Control Center, then Home) starts no second one.
        #expect(planner.leaving([bot("otto", working: true)], now: t0.addingTimeInterval(40)).isEmpty)
    }

    @Test func theTurnsClockStartsWhenTheAppFirstSawItRunning() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("a", working: true)], now: t0, appActive: true)
        _ = planner.bots([bot("a", working: true)], now: t0.addingTimeInterval(10), appActive: true)   // still the same turn
        #expect(planner.workingSince["a"] == t0)
        _ = planner.bots([bot("a", working: false)], now: t0.addingTimeInterval(11), appActive: true)
        _ = planner.bots([bot("a", working: true)], now: t0.addingTimeInterval(30), appActive: true)   // a new turn
        #expect(planner.workingSince["a"] == t0.addingTimeInterval(30))
        #expect(planner.leaving([bot("a", working: true)], now: t0.addingTimeInterval(45))
                == [.start(LiveActivityStart(subject: turn("a"), botName: "A", detail: nil, link: "hermes://session/s-a",
                                             content: LiveActivityContent(phase: .working, startedAt: t0.addingTimeInterval(30))))],
                "the new turn's own start")
    }

    @Test func aTurnThatEndsAwayEndsDoneAndLingersOnTheLockScreen() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("a", working: true)], now: t0, appActive: true)
        _ = planner.leaving([bot("a", working: true)], now: t0.addingTimeInterval(30))
        let end = t0.addingTimeInterval(90)
        let commands = planner.bots([bot("a", working: false)], now: end, appActive: false)
        #expect(commands == [.end(turn("a"), LiveActivityContent(phase: .done, startedAt: t0, endedAt: end),
                                  .after(end.addingTimeInterval(LiveActivityPlanner.doneLinger)))])
        #expect(planner.live.isEmpty)
    }

    @Test func aTurnThatEndsWhileTheAppIsInFrontGoesAtOnce() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("a", working: true)], now: t0, appActive: true)
        _ = planner.leaving([bot("a", working: true)], now: t0.addingTimeInterval(30))
        let end = t0.addingTimeInterval(60)
        #expect(planner.bots([bot("a", working: false)], now: end, appActive: true)
                == [.end(turn("a"), LiveActivityContent(phase: .done, startedAt: t0, endedAt: end), .immediate)])
    }

    @Test func aBotThatLeftTheRosterEndsItsTurn() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("a", working: true)], now: t0, appActive: true)
        _ = planner.leaving([bot("a", working: true)], now: t0.addingTimeInterval(30))
        let commands = planner.bots([], now: t0.addingTimeInterval(40), appActive: false)
        #expect(commands.count == 1)
        #expect(planner.workingSince.isEmpty)
    }

    @Test func atMostFourAtOnceTheLongestRunningFirst() {
        var planner = LiveActivityPlanner()
        let ids = ["a", "b", "c", "d", "e", "f"]
        for (index, id) in ids.reversed().enumerated() {   // f first: the longest-running
            _ = planner.bots(ids.reversed().prefix(index + 1).map { bot($0, working: true) }, now: t0.addingTimeInterval(Double(index)), appActive: true)
        }
        let commands = planner.leaving(ids.map { bot($0, working: true) }, now: t0.addingTimeInterval(100))
        #expect(started(commands) == ["f", "e", "d", "c"].map(turn))
    }

    @Test func offOrUnavailableStartsNothing() {
        var off = LiveActivityPlanner(enabled: false)
        _ = off.bots([bot("a", working: true)], now: t0, appActive: true)
        #expect(off.leaving([bot("a", working: true)], now: t0.addingTimeInterval(60)).isEmpty)
        var unavailable = LiveActivityPlanner(available: false)
        _ = unavailable.bots([bot("a", working: true)], now: t0, appActive: true)
        #expect(unavailable.leaving([bot("a", working: true)], now: t0.addingTimeInterval(60)).isEmpty)
        #expect(unavailable.jobStarted(key: "k", title: "T", botName: "B", link: nil, now: t0).isEmpty)
    }

    @Test func turningTheSwitchOffTakesEverythingAwayAtOnce() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("a", working: true)], now: t0, appActive: true)
        _ = planner.leaving([bot("a", working: true)], now: t0.addingTimeInterval(30))
        _ = planner.jobStarted(key: "ops|j1", title: "Backup", botName: "Ops", link: nil, now: t0)
        #expect(planner.setEnabled(false) == [.end(turn("a"), nil, .immediate), .end(job("ops|j1"), nil, .immediate)])
        #expect(planner.live.isEmpty)
        #expect(planner.jobStarted(key: "ops|j2", title: "B", botName: "Ops", link: nil, now: t0).isEmpty)
        #expect(planner.setEnabled(true).isEmpty)
    }

    @Test func aRefusedStartIsNotFollowed() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("a", working: true)], now: t0, appActive: true)
        _ = planner.leaving([bot("a", working: true)], now: t0.addingTimeInterval(30))
        planner.startFailed(turn("a"))
        #expect(planner.bots([bot("a", working: false)], now: t0.addingTimeInterval(40), appActive: false).isEmpty)
    }
}

@Suite struct LiveActivityJobRulesTests {
    @Test func runNowStartsRunningAtOnce() {
        var planner = LiveActivityPlanner()
        let commands = planner.jobStarted(key: "deploys|j-watch", title: "Deploy watch", botName: "Deploys",
                                          link: "hermes://job/deploys%7Cj-watch", now: t0)
        #expect(commands == [.start(LiveActivityStart(subject: job("deploys|j-watch"), botName: "Deploys", detail: "Deploy watch",
                                                      link: "hermes://job/deploys%7Cj-watch",
                                                      content: LiveActivityContent(phase: .running, startedAt: t0)))])
        #expect(planner.jobStarted(key: "deploys|j-watch", title: "x", botName: "y", link: nil, now: t0).isEmpty, "one per job")
        #expect(planner.followedJobs == ["deploys|j-watch"])
    }

    @Test func runNowsAnswerWaitsForTheReadUnlessItNeverRanOrFailed() {
        var planner = LiveActivityPlanner()
        _ = planner.jobStarted(key: "a|1", title: "A", botName: "A", link: nil, now: t0)
        _ = planner.jobStarted(key: "b|2", title: "B", botName: "B", link: nil, now: t0)
        _ = planner.jobStarted(key: "c|3", title: "C", botName: "C", link: nil, now: t0)
        #expect(planner.jobAnswered(key: "a|1", .answered, now: t0, appActive: true).isEmpty, "a Bot Chat job's bot may still work")
        #expect(planner.jobAnswered(key: "b|2", .notStarted, now: t0, appActive: true) == [.end(job("b|2"), nil, .immediate)])
        let end = t0.addingTimeInterval(5)
        #expect(planner.jobAnswered(key: "c|3", .failed, now: end, appActive: false)
                == [.end(job("c|3"), LiveActivityContent(phase: .failed, startedAt: t0, endedAt: end),
                         .after(end.addingTimeInterval(LiveActivityPlanner.doneLinger)))])
        #expect(planner.jobAnswered(key: "zzz", .failed, now: t0, appActive: true).isEmpty, "a job nobody follows")
        #expect(planner.followedJobs == ["a|1"])
    }

    @Test func aJobsReadEndsDoneFailedOrGoneAndKeepsRunningOnes() {
        var planner = LiveActivityPlanner()
        for key in ["run|1", "ok|2", "bad|3", "gone|4"] { _ = planner.jobStarted(key: key, title: key, botName: "B", link: nil, now: t0) }
        let now = t0.addingTimeInterval(70)
        let commands = planner.jobs(["run|1": .running, "ok|2": .done, "bad|3": .failed], now: now, appActive: true)
        #expect(Set(commands.map { "\($0)" }) == Set([
            LiveActivityCommand.end(job("ok|2"), LiveActivityContent(phase: .done, startedAt: t0, endedAt: now), .immediate),
            .end(job("bad|3"), LiveActivityContent(phase: .failed, startedAt: t0, endedAt: now), .immediate),
            .end(job("gone|4"), nil, .immediate),
        ].map { "\($0)" }))
        #expect(planner.followedJobs == ["run|1"])
    }

    @Test func jobsAndTurnsShareTheCap() {
        var planner = LiveActivityPlanner()
        for index in 0..<4 { _ = planner.jobStarted(key: "p|\(index)", title: "J", botName: "B", link: nil, now: t0) }
        #expect(planner.jobStarted(key: "p|9", title: "J", botName: "B", link: nil, now: t0).isEmpty)
        _ = planner.bots([bot("a", working: true)], now: t0, appActive: true)
        #expect(planner.leaving([bot("a", working: true)], now: t0.addingTimeInterval(60)).isEmpty)
    }

    @Test func aJobsStateFollowsTheJobsPageRunningWords() {
        var running = CronJob(id: "j")
        running.state = "running"
        #expect(LiveActivityCenter.state(of: running, inFlight: false) == .running)
        var idle = CronJob(id: "j")
        idle.state = "scheduled"
        #expect(LiveActivityCenter.state(of: idle, inFlight: true) == .running, "a Run Now still out")
        #expect(LiveActivityCenter.state(of: idle, inFlight: false) == .done)
        var working = idle
        working.botWorking = "claimed"
        #expect(LiveActivityCenter.state(of: working, inFlight: false) == .running, "the bot is still on the output")
        var failed = idle
        failed.lastStatus = "error"
        #expect(LiveActivityCenter.state(of: failed, inFlight: false) == .failed)
    }
}

@Suite struct LiveActivityWordsTests {
    @Test func theWordsTheLockScreenShows() {
        #expect(LiveActivityContent(phase: .working, startedAt: t0).words == "Working…")
        #expect(LiveActivityContent(phase: .running, startedAt: t0).words == "Running")
        #expect(LiveActivityContent(phase: .done, startedAt: t0).words == "Done")
        #expect(LiveActivityContent(phase: .failed, startedAt: t0).words == "Failed")
        #expect(LiveActivityContent.took(44.6) == "45 s")
        #expect(LiveActivityContent.took(185) == "3 min")
        #expect(LiveActivityContent.took(3600) == "1 h")
        #expect(LiveActivityContent.took(3900) == "1 h 5 min")
        #expect(LiveActivityContent.took(-3) == "0 s")
    }

    @Test func aRunningOneGoesStaleAfterHalfAnHourAFinishedOneNever() {
        let running = LiveActivityContent(phase: .working, startedAt: t0)
        #expect(LiveActivityPlanner.staleDate(running, now: t0.addingTimeInterval(10)) == t0.addingTimeInterval(10 + 30 * 60))
        var done = running
        done.phase = .done
        #expect(LiveActivityPlanner.staleDate(done, now: t0) == nil)
    }

    @Test func theSettingsFooterNamesTheIslandOnlyOnAnIPhoneAndSaysTalkIsUnaffected() {
        #expect(LiveActivityWords.footer(island: true)
                == "A bot’s reply that’s still going when you leave the app, or a job you run from Jobs, shows on the Lock Screen and in the Dynamic Island with how long it has run, until it’s done. A reply also names the step its bot is on. Your voice chat’s own Lock Screen controls aren’t affected.")
        #expect(!LiveActivityWords.footer(island: false).contains("Dynamic Island"))
        #expect(!LiveActivityWords.footer(island: true).contains("Dispatch"))
        #expect(LiveActivityWords.footer(island: true).contains("voice chat"), "says plainly that Talk's own controls stay as they are")
    }

    @Test func linksUseTheAppsOwnSchemeAndOpenThroughItsLinkHandling() throws {
        let scheme = AppIdentity.current.urlScheme
        #expect(LiveActivityCenter.sessionLink("abc123") == "\(scheme)://session/abc123")
        let link = try #require(LiveActivityCenter.jobLink("deploys|j-watch"))
        #expect(link == "\(scheme)://job/deploys%7Cj-watch")
        let url = try #require(URL(string: link))
        #expect(DeepLink.parse(url, scheme: scheme) == .other(kind: "job", name: "deploys|j-watch", params: []))
        let session = try #require(URL(string: LiveActivityCenter.sessionLink("abc123")))
        #expect(NotificationRules.link(session, scheme: scheme) == .session("abc123"))
    }
}

// MARK: [live] The push-side rule (NotificationService.swift's best-effort Done, Shared/LiveActivityPush.swift)

@Suite struct LiveActivityPushTests {
    @Test func aFinishedTurnsPushNamesItsSubjectByProfile() {
        #expect(LiveActivityPush.turnFinished(["kind": "turnDone", "profile": "ivy", "session": "s-1"])
                == LiveActivitySubject(kind: .turn, id: "ivy"))
    }

    @Test func anythingElseNamesNothing() {
        #expect(LiveActivityPush.turnFinished(["kind": "approval", "profile": "ivy"]) == nil, "not a finished turn")
        #expect(LiveActivityPush.turnFinished(["kind": "turnDone"]) == nil, "no profile to match")
        #expect(LiveActivityPush.turnFinished(["kind": "turnDone", "profile": ""]) == nil, "an empty profile matches nothing")
        #expect(LiveActivityPush.turnFinished([:]) == nil)
    }
}

// MARK: The center, with a recorder in ActivityKit's place

@MainActor private final class RecordingDriver: LiveActivityDriver {
    var isOffered = true
    var isAllowed = true
    var refuse = false
    var log: [String] = []
    var leftoversEnded = 0

    func start(_ start: LiveActivityStart) -> Bool {
        log.append("start \(start.subject.kind.rawValue):\(start.subject.id) \(start.content.phase.rawValue) \(start.botName)")
        return !refuse
    }
    func update(_ subject: LiveActivitySubject, _ content: LiveActivityContent) { log.append("update \(subject.id) \(content.phase.rawValue)") }
    func end(_ subject: LiveActivitySubject, _ content: LiveActivityContent?, _ dismissal: LiveActivityDismissal) {
        log.append("end \(subject.kind.rawValue):\(subject.id) \(content?.phase.rawValue ?? "removed") \(dismissal == .immediate ? "now" : "later")")
    }
    func endLeftovers() { leftoversEnded += 1 }
    func clearFinished() { log.append("clear finished") }
    var onPushToken: (@MainActor (LiveActivitySubject, String, String) -> Void)?
}

@MainActor private final class RecordingRelay: LiveStepsRelay {
    var handedOver: [LiveStepsHandOver] = []
    var withdrawn: [String] = []
    func handOverSteps(_ start: LiveStepsHandOver) async { handedOver.append(start) }
    func withdrawSteps(_ activity: String) async { withdrawn.append(activity) }
}

@MainActor private func fixtureBot(_ id: String, working: Bool) -> Bot {
    Bot(id: id, name: id == "default" ? "Hermes" : id.uppercased(), role: nil, preview: nil, lastActive: nil, isWorking: working,
        unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "s-\(id)", head: nil)
}

@MainActor @Suite(.serialized) struct LiveActivityCenterTests {
    private func center(_ driver: RecordingDriver, enabled: Bool = true) -> (LiveActivityCenter, () -> Void) {
        let center = LiveActivityCenter(driver: driver, enabled: enabled)
        var clock = t0
        center.now = { clock }
        center.appActive = { false }
        return (center, { clock = clock.addingTimeInterval(30) })
    }

    @Test func aLongTurnStartsWhenTheAppIsLeftAndEndsDoneWhenTheBotStops() {
        let driver = RecordingDriver()
        let (center, tick) = center(driver)
        center.botsChanged([fixtureBot("otto", working: true)])
        tick()
        center.appLeaving()
        center.botsChanged([fixtureBot("otto", working: false)])
        #expect(driver.log == ["start turn:otto working OTTO", "end turn:otto done later"])
    }

    @Test func iOSRefusingTheStartLeavesNothingToEnd() {
        let driver = RecordingDriver()
        driver.refuse = true
        let (center, tick) = center(driver)
        center.botsChanged([fixtureBot("otto", working: true)])
        tick()
        center.appLeaving()
        center.botsChanged([fixtureBot("otto", working: false)])
        #expect(driver.log == ["start turn:otto working OTTO"])
        #expect(center.planner.live.isEmpty)
    }

    @Test func liveActivitiesTurnedOffForTheAppInSettingsStartNothing() {
        let driver = RecordingDriver()
        driver.isAllowed = false
        let (center, tick) = center(driver)
        center.botsChanged([fixtureBot("otto", working: true)])
        tick()
        center.appLeaving()
        #expect(driver.log.isEmpty)
    }

    @Test func aBuildWithoutTheExtensionOffersNothing() {
        let driver = RecordingDriver()
        driver.isOffered = false
        let (center, tick) = center(driver)
        #expect(!center.isOffered)
        center.botsChanged([fixtureBot("otto", working: true)])
        tick()
        center.appLeaving()
        #expect(driver.log.isEmpty)
        #expect(!NoLiveActivities().isOffered)
    }

    @Test func runNowFollowsTheJobUntilAJobsReadSaysItIsOver() {
        let driver = RecordingDriver()
        let (center, _) = center(driver)
        var job = CronJob(id: "j-watch")
        job.profile = "deploys"
        center.jobRunStarted(job, title: "Deploy watch", botName: "Deploys", store: nil)
        center.jobRunAnswered(job.key, .started)
        #expect(driver.log == ["start job:deploys|j-watch running Deploys"])
        center.jobsStates([job.key: .running])
        center.jobsStates([job.key: .done])
        #expect(driver.log.last == "end job:deploys|j-watch done later")
    }

    @Test func aRunThatNeverBeganGoesAtOnce() {
        let driver = RecordingDriver()
        let (center, _) = center(driver)
        let job = CronJob(id: "j1")
        center.jobRunStarted(job, title: "A", botName: "Hermes", store: nil)
        center.jobRunAnswered(job.key, .alreadyRunning("busy"))
        #expect(driver.log == ["start job:default|j1 running Hermes", "end job:default|j1 removed now"])
    }

    @Test func theSwitchAndSignOutTakeEverythingAway() {
        let driver = RecordingDriver()
        let (center, _) = center(driver)
        center.jobRunStarted(CronJob(id: "j1"), title: "A", botName: "Hermes", store: nil)
        center.accountLeft()
        #expect(driver.log.last == "end job:default|j1 removed now")
        center.jobRunStarted(CronJob(id: "j2"), title: "B", botName: "Hermes", store: nil)
        center.setOn(false)
        #expect(driver.log.last == "end job:default|j2 removed now")
        center.jobRunStarted(CronJob(id: "j3"), title: "C", botName: "Hermes", store: nil)
        #expect(driver.log.last == "end job:default|j2 removed now", "off: nothing starts")
        center.setOn(true)
        #expect(LiveActivityCenter.isOn)
    }

    @Test func theFirstReturnEndsWhatAnEarlierRunLeft() {
        let driver = RecordingDriver()
        let (center, _) = center(driver)
        center.appBecameActive()
        center.appBecameActive()
        #expect(driver.leftoversEnded == 1)
    }

    /// Owner, 2026-11-01: back in the app, a new message to Hermes, the phone locked, and the card "just said done": the
    /// reply before's. The bots' first read after the return came before iOS called the app active, so that turn's
    /// Done was left to linger. Every return now takes away whatever is over, after the end the read asked for.
    @Test func everyReturnClearsTheCardsThatAreOverAfterAnEndTheReturnsFirstReadAskedFor() {
        let driver = RecordingDriver()
        let (center, tick) = center(driver)
        center.botsChanged([fixtureBot("default", working: true)])
        tick()
        center.appLeaving()
        center.botsChanged([fixtureBot("default", working: false)])    // the return's first read, not yet active
        center.appBecameActive()
        center.appBecameActive()
        #expect(driver.log == ["start turn:default working Hermes", "end turn:default done later", "clear finished", "clear finished"])
    }
}

// MARK: [live-steps] The card names the step its bot is on

nonisolated private func stepping(_ id: String, _ step: String?) -> LiveBot {
    LiveBot(id: id, name: id.capitalized, isWorking: true, link: "hermes://session/s-\(id)", step: step, session: "s-\(id)")
}

@Suite struct LiveStepsRulesTests {
    @Test func aTrailNamesTheRunningStepTheTwoBeforeItAndHowMany() {
        var trail = LiveStepTrail()
        trail.follow("reading package.json")
        trail.follow("running npm test")
        trail.follow("running npm test")                 // the same step heard again counts once
        trail.follow(nil)                                // its reply writes
        trail.follow("searching the web for flaky tests")
        #expect(trail == LiveStepTrail(step: "searching the web for flaky tests", recent: ["running npm test", "reading package.json"], steps: 3))
        trail.follow("opening github.com")
        #expect(trail.recent == ["searching the web for flaky tests", "running npm test"], "at most two earlier ones")
        #expect(trail.steps == 4)
        #expect(trail.settled() == LiveStepTrail(step: nil, recent: ["opening github.com", "searching the web for flaky tests"], steps: 4))
    }

    @Test func theCardStartsWithTheStepsTheTurnAlreadyTook() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([stepping("otto", "reading package.json")], now: t0, appActive: true)
        _ = planner.bots([stepping("otto", "running npm test")], now: t0.addingTimeInterval(10), appActive: true)
        let commands = planner.leaving([stepping("otto", "running npm test")], now: t0.addingTimeInterval(25))
        guard case .start(let start)? = commands.first else { Issue.record("no start"); return }
        #expect(start.content.step == "running npm test")
        #expect(start.content.recent == ["reading package.json"])
        #expect(start.content.steps == 2)
    }

    @Test func aNewStepUpdatesTheCardOnShowAndNothingElseDoes() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([stepping("otto", "reading package.json")], now: t0, appActive: true)
        _ = planner.leaving([stepping("otto", "reading package.json")], now: t0.addingTimeInterval(25))
        #expect(planner.bots([stepping("otto", "reading package.json")], now: t0.addingTimeInterval(26), appActive: false).isEmpty,
                "a roster change with the same step sends nothing")
        let commands = planner.bots([stepping("otto", "running npm test")], now: t0.addingTimeInterval(27), appActive: false)
        var expected = LiveActivityContent(phase: .working, startedAt: t0)
        expected.trail = LiveStepTrail(step: "running npm test", recent: ["reading package.json"], steps: 2)
        #expect(commands == [.update(turn("otto"), expected)])
        #expect(planner.live[turn("otto")]?.content == expected)
    }

    @Test func aBotWithoutStepsStillSaysWorkingAsBefore() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("otto", working: true)], now: t0, appActive: true)
        _ = planner.leaving([bot("otto", working: true)], now: t0.addingTimeInterval(25))
        #expect(planner.bots([bot("otto", working: true)], now: t0.addingTimeInterval(30), appActive: false).isEmpty)
        #expect(planner.live[turn("otto")]?.content == LiveActivityContent(phase: .working, startedAt: t0))
    }

    @Test func aFinishedTurnsCardCountsItsLastStepAsDone() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([stepping("otto", "reading package.json")], now: t0, appActive: true)
        _ = planner.leaving([stepping("otto", "reading package.json")], now: t0.addingTimeInterval(25))
        _ = planner.bots([stepping("otto", "running npm test")], now: t0.addingTimeInterval(30), appActive: false)
        let end = t0.addingTimeInterval(60)
        let commands = planner.bots([bot("otto", working: false)], now: end, appActive: false)
        var expected = LiveActivityContent(phase: .done, startedAt: t0, endedAt: end)
        expected.trail = LiveStepTrail(step: nil, recent: ["running npm test", "reading package.json"], steps: 2)
        #expect(commands == [.end(turn("otto"), expected, .after(end.addingTimeInterval(LiveActivityPlanner.doneLinger)))])
        #expect(planner.trails.isEmpty, "the next turn starts its own trail")
    }

    @Test func anOlderBuildsCardStillDecodesAndANoStepCardEncodesAsBefore() throws {
        let old = #"{"phase":"working","startedAt":800000000}"#
        let content = try JSONDecoder().decode(LiveActivityContent.self, from: Data(old.utf8))
        #expect(content == LiveActivityContent(phase: .working, startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any]
        #expect(Set(encoded?.keys.map { $0 } ?? []) == ["phase", "startedAt"])
    }

    @Test func aPushedCardDecodesTheWayTheAddOnSendsIt() throws {
        // hermes-hq-push 0.9.22's content-state: Apple-reference-date seconds, the trail sealed.
        let pushed = #"{"phase":"working","startedAt":800000000.5,"seal":{"v":1,"kid":"0011223344556677","box":"AAAA"}}"#
        let content = try JSONDecoder().decode(LiveActivityContent.self, from: Data(pushed.utf8))
        #expect(content.startedAt == Date(timeIntervalSinceReferenceDate: 800_000_000.5))
        #expect(content.seal == LiveSeal(v: 1, kid: "0011223344556677", box: "AAAA"))
        #expect(content.trail.isEmpty)
    }

    @Test func aSealedTrailOpensWithThePhonesKeyAndNothingElse() throws {
        let key = PushSeal.makeKey()
        let inner = #"{"step":"running npm test","recent":["reading package.json"],"steps":2}"#
        let box = try AES.GCM.seal(Data(inner.utf8), using: SymmetricKey(data: key), authenticating: PushSeal.aad).combined!
        var content = LiveActivityContent(phase: .working, startedAt: t0)
        content.seal = LiveSeal(v: 1, kid: PushSeal.kid(key), box: box.base64EncodedString())
        #expect(LiveStepsSeal.trail(content, keys: { [key] }) == LiveStepTrail(step: "running npm test", recent: ["reading package.json"], steps: 2))
        #expect(LiveStepsSeal.trail(content, keys: { [PushSeal.makeKey()] }).isEmpty, "another key opens nothing")
    }

    /// A box the add-on sealed (hermes-hq-push 0.9.22's `seal_box`, key bytes 0…31, nonce bytes 0…11): the widget opens it.
    @Test func aBoxTheAddOnSealedOpens() throws {
        let key = Data(0..<32)
        let pushed = #"""
        {"phase": "working", "startedAt": 800000000.5, "seal": {"v": 1, "kid": "630dcd2966c43366",
         "box": "AAECAwQFBgcICQoLPCClb6CV4CGvM+Ll34AWCqO491nQDzoPTEXJp28MY9dvZIzG9ONg/RXAFoPvp1hZjTIB6j/4yalQ+QhENMGGmpVMtVjp5lul5QWaokJo3Tac5kWJWb4e"}}
        """#
        let content = try JSONDecoder().decode(LiveActivityContent.self, from: Data(pushed.utf8))
        #expect(PushSeal.kid(key) == "630dcd2966c43366")
        #expect(LiveStepsSeal.trail(content, keys: { [key] }) == LiveStepTrail(step: "running npm test", recent: ["reading package.json"], steps: 7))
    }

    @Test func pushedWordsAreCutToOneShortLine() {
        let long = String(repeating: "a", count: 90)
        let trail = LiveStepsSeal.trail(["step": "running\nnpm test", "recent": [long, "  ", "three", "four"], "steps": 4])
        #expect(trail.step == "running npm test")
        #expect(trail.recent.count == 2)
        #expect(trail.recent[0].count == LiveStepTrail.wordsLimit)
        #expect(trail.recent[1] == "three", "a blank one is dropped")
    }

    @Test func theCardsLines() {
        #expect(LiveStepTrail.running("running npm test") == "Running npm test…")
        #expect(LiveStepTrail.finished("reading package.json") == "Reading package.json")
        #expect(LiveStepTrail.count(1) == "1 step")
        #expect(LiveStepTrail.count(7) == "7 steps")
    }
}

@MainActor @Suite(.serialized) struct LiveStepsCenterTests {
    @MainActor private func steppingBot(_ step: String?, working: Bool = true) -> Bot {
        var bot = fixtureBot("otto", working: working)
        bot.step = step
        return bot
    }

    @Test func aTurnsPushTokenGoesToTheAddOnWithItsStartAndStepsAndIsWithdrawnAtTheEnd() async {
        let driver = RecordingDriver()
        let relay = RecordingRelay()
        let center = LiveActivityCenter(driver: driver, enabled: true, steps: relay)
        var clock = t0
        center.now = { clock }
        center.appActive = { false }
        center.botsChanged([steppingBot("reading package.json")])
        clock = t0.addingTimeInterval(30)
        center.appLeaving()
        driver.onPushToken?(turn("otto"), "activity-1", "abcd")
        await Task.yield(); await Task.yield()
        #expect(relay.handedOver == [LiveStepsHandOver(activity: "activity-1", token: "abcd", profile: "otto", session: "s-otto", startedAt: t0,
                                                      trail: LiveStepTrail(step: "reading package.json", recent: [], steps: 1))])
        center.botsChanged([steppingBot("running npm test")])
        #expect(driver.log.last == "update otto working")
        center.botsChanged([steppingBot(nil, working: false)])
        await Task.yield(); await Task.yield()
        #expect(relay.withdrawn == ["activity-1"])
    }

    @Test func aJobsCardHandsNothingOver() async {
        let driver = RecordingDriver()
        let relay = RecordingRelay()
        let center = LiveActivityCenter(driver: driver, enabled: true, steps: relay)
        driver.onPushToken?(job("deploys|j1"), "activity-2", "abcd")
        await Task.yield()
        #expect(relay.handedOver.isEmpty)
    }
}

// MARK: [live-chats] A bot's other chats get a card each (a tester, 2026-11-05)

nonisolated private func sideChat(_ profile: String, _ session: String, title: String?, step: String? = nil) -> LiveBot {
    LiveBot(id: LiveBot.sideId(profile: profile, session: session), name: profile.uppercased(), isWorking: true,
            link: "hermes://session/\(session)", step: step, session: session, profile: profile, chat: title)
}

@Suite struct LiveSideChatRulesTests {
    @Test func aSideChatsTurnGetsItsOwnCardBesideItsBotChats() {
        var planner = LiveActivityPlanner()
        let chats = [bot("otto", working: true, name: "Otto"), sideChat("otto", "s-day", title: "Day check")]
        _ = planner.bots(chats, now: t0, appActive: true)
        let commands = planner.leaving(chats, now: t0.addingTimeInterval(5))
        #expect(started(commands) == [turn("otto"), turn("otto/s-day")])
        guard case .start(let side)? = commands.last else { Issue.record("no side start"); return }
        #expect(side.botName == "OTTO")
        #expect(side.detail == "Day check")
        #expect(side.link == "hermes://session/s-day")
    }

    @Test func aSideChatsCardEndsDoneWhenItsTurnEndsAndLeavesTheBotChatsAlone() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([bot("otto", working: true), sideChat("otto", "s-day", title: nil)], now: t0, appActive: true)
        _ = planner.leaving([bot("otto", working: true), sideChat("otto", "s-day", title: nil)], now: t0.addingTimeInterval(5))
        let end = t0.addingTimeInterval(120)
        let commands = planner.bots([bot("otto", working: true)], now: end, appActive: false)
        #expect(commands == [.end(turn("otto/s-day"), LiveActivityContent(phase: .done, startedAt: t0, endedAt: end),
                                  .after(end.addingTimeInterval(LiveActivityPlanner.doneLinger)))])
        #expect(planner.live[turn("otto")] != nil)
    }

    @Test func aSideChatsStepsGoToItsOwnCard() {
        var planner = LiveActivityPlanner()
        _ = planner.bots([sideChat("otto", "s-day", title: "Day check", step: "reading daycheck.py")], now: t0, appActive: true)
        _ = planner.leaving([sideChat("otto", "s-day", title: "Day check", step: "reading daycheck.py")], now: t0.addingTimeInterval(5))
        let commands = planner.bots([sideChat("otto", "s-day", title: "Day check", step: "running sed")], now: t0.addingTimeInterval(9), appActive: false)
        var expected = LiveActivityContent(phase: .working, startedAt: t0)
        expected.trail = LiveStepTrail(step: "running sed", recent: ["reading daycheck.py"], steps: 2)
        #expect(commands == [.update(turn("otto/s-day"), expected)])
    }
}

@MainActor @Suite(.serialized) struct LiveSideChatCenterTests {
    @Test func aSideChatsPushTokenGoesToTheAddOnUnderItsBotAndItsOwnChat() async {
        let driver = RecordingDriver()
        let relay = RecordingRelay()
        let center = LiveActivityCenter(driver: driver, enabled: true, steps: relay)
        var clock = t0
        center.now = { clock }
        center.appActive = { false }
        center.botsChanged([fixtureBot("otto", working: false)])
        center.sideChatsChanged([sideChat("otto", "s-day", title: "Day check")])
        clock = t0.addingTimeInterval(30)
        center.appLeaving()
        #expect(driver.log == ["start turn:otto/s-day working OTTO"])
        driver.onPushToken?(turn("otto/s-day"), "activity-3", "abcd")
        await Task.yield(); await Task.yield()
        #expect(relay.handedOver.map(\.profile) == ["otto"])
        #expect(relay.handedOver.map(\.session) == ["s-day"])
        center.sideChatsChanged([])
        #expect(driver.log.last == "end turn:otto/s-day done later")
        await Task.yield(); await Task.yield()
        #expect(relay.withdrawn == ["activity-3"])
    }
}
