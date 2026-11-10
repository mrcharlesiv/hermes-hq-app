import Foundation
import Testing
@testable import HermesHQNative

/// [offline] The launch screen's machine (docs/spec/3x-offline.md §3.1, §3.2): the web app's `launch-screen.test.ts`
/// cases with a hand-driven clock.
@MainActor @Suite struct LaunchGateTests {
    typealias Clock = ReadFlightTests.FakeClock

    final class Probe {
        var blocker: LaunchBlocker? = .cover
        var views: [LaunchGate.View] = []
        var last: LaunchGate.View { views.last ?? LaunchGate.View() }
    }

    private func make(_ probe: Probe, clock: Clock) -> LaunchGate {
        LaunchGate(clock: clock, blocker: { probe.blocker }, render: { probe.views.append($0) })
    }

    @Test func quickLaunchShowsOnlyTheIconThenLeavesOnceConnectedWithContent() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        #expect(probe.last == LaunchGate.View(phase: .shown, spinner: false, status: "", actions: false))
        gate.mount()
        await clock.advance(0.3)
        probe.blocker = nil
        gate.check()
        #expect(gate.phase == .shown)          // the stability guard first
        await clock.advance(0.1)
        #expect(gate.phase == .leaving)
        #expect(!probe.views.contains { $0.spinner }, "no indicator on a quick launch")
        await clock.advance(0.12)
        #expect(gate.phase == .gone)
    }

    @Test func staysWhileTheFirstListLoads() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        gate.mount()
        probe.blocker = .loading
        gate.check()
        await clock.advance(2)
        #expect(gate.phase == .shown)
        probe.blocker = nil
        gate.check()
        await clock.advance(0.1)
        #expect(gate.phase == .leaving)
    }

    @Test func aFirstListGetsFiveSecondsThenTheAppShowsLoading() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        gate.mount()
        await clock.advance(3)             // connecting took 3 s
        probe.blocker = .loading           // the gateway opened
        gate.check()
        await clock.advance(4.9)
        #expect(gate.phase == .shown)
        await clock.advance(0.3)           // 5 s after the gateway opened, plus the guard
        #expect(gate.phase != .shown)
    }

    @Test func theContentAllowanceIsNotStartedWhileNotConnected() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        gate.mount()
        gate.check()
        await clock.advance(11)
        #expect(gate.phase == .shown, "not connected: the launch screen (or the offline screen) keeps the page")
    }

    @Test func onePlaceholderHandingOverToTheNextDoesNotEndTheLaunchEarly() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        gate.mount()
        probe.blocker = nil
        gate.check()
        await clock.advance(0.05)
        probe.blocker = .loading           // another loading state took over inside the guard
        gate.check()
        await clock.advance(0.2)
        #expect(gate.phase == .shown)
        probe.blocker = nil
        gate.check()
        await clock.advance(0.1)
        #expect(gate.phase == .leaving)
    }

    @Test func indicatorThenCaptionThenTheUsualCause() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        await clock.advance(0.89)
        #expect(!probe.last.spinner)
        await clock.advance(0.02)
        #expect(probe.last.spinner && probe.last.status.isEmpty)
        await clock.advance(3.1)
        #expect(probe.last.status == "Connecting to Hermes…")
        #expect(!probe.last.actions)
        await clock.advance(8)
        #expect(probe.last.status == "Still connecting. Check that the computer running Hermes is on and awake.")
        #expect(probe.last.actions)
        _ = gate
    }

    /// Tailscale is named only for a gateway reached through it (UX study #122).
    @Test func theUsualCauseNamesTailscaleOnlyForATailnetGateway() async {
        let clock = Clock(), probe = Probe()
        let gate = LaunchGate(clock: clock, blocker: { probe.blocker }, throughTailscale: { true }, render: { probe.views.append($0) })
        await clock.advance(12)
        #expect(probe.last.status == "Still connecting. Check that the computer running Hermes is on and awake, and that Tailscale is on here.")
        _ = gate
        #expect(GatewayAddress.throughTailscale(URL(string: "https://studio.tail1234.ts.net")!))
        #expect(GatewayAddress.throughTailscale(URL(string: "http://100.101.102.103:9119")!))
        #expect(GatewayAddress.throughTailscale(URL(string: "http://[fd7a:115c:a1e0::1]:9119")!))
        #expect(!GatewayAddress.throughTailscale(URL(string: "https://hermes.example.com")!))
        #expect(!GatewayAddress.throughTailscale(URL(string: "http://mac-mini.local:9119")!))
    }

    @Test func theCaptionSaysLoadingOnceTheGatewayIsOpen() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        gate.mount()
        probe.blocker = .loading
        await clock.advance(4)
        #expect(probe.last.status == "Loading…")
        // Still loading at 12 s is not "check Tailscale": the gateway is open.
        await clock.advance(8.5)
        #expect(!probe.last.actions)
        _ = gate
    }

    @Test func aConnectingCaptionTurnsToLoadingWhenTheGatewayOpens() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        gate.mount()
        await clock.advance(4)
        #expect(probe.last.status == "Connecting to Hermes…")
        probe.blocker = .loading
        gate.check()
        #expect(probe.last.status == "Loading…")
    }

    @Test func givesWayToSignInAndCoversAgainOnceSigningInBoots() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        gate.hide()
        #expect(gate.phase == .leaving)
        await clock.advance(0.12)
        #expect(gate.phase == .gone)
        gate.booting()
        #expect(gate.phase == .shown)
        #expect(probe.last == LaunchGate.View())
        #expect(!gate.isMounted)
    }

    @Test func keepsTheIconWithTheReasonWhenStartupFailsAndRecoversIfTheAppMountsAnyway() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        await clock.advance(1)
        gate.fail("Hermes HQ couldn’t start. Tap Try Again.")
        #expect(probe.last.status == "Hermes HQ couldn’t start. Tap Try Again.")
        #expect(probe.last.actions && !probe.last.spinner)
        #expect(gate.hasFailed)
        await clock.advance(30)
        #expect(probe.last.status.hasPrefix("Hermes HQ couldn’t start"), "the timers no longer overwrite the reason")
        probe.blocker = nil
        gate.mount()
        #expect(!gate.hasFailed)
        #expect(probe.views.contains { $0.status.isEmpty && !$0.actions })
        await clock.advance(0.1)
        #expect(gate.phase == .leaving)
    }

    @Test func tryAgainStartsTheTimersOver() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        await clock.advance(12)
        #expect(probe.last.actions)
        gate.retry()
        #expect(probe.last == LaunchGate.View(phase: .shown, spinner: true, status: "Connecting to Hermes…", actions: false))
        await clock.advance(11.9)
        #expect(!probe.last.actions)
        await clock.advance(0.2)
        #expect(probe.last.actions)
    }

    @Test func nothingChangesOnceGone() async {
        let clock = Clock(), probe = Probe()
        let gate = make(probe, clock: clock)
        gate.mount()
        probe.blocker = nil
        gate.check()
        await clock.advance(1)
        #expect(gate.phase == .gone)
        let count = probe.views.count
        gate.check(); gate.retry(); gate.fail("x"); gate.mount()
        await clock.advance(20)
        #expect(probe.views.count == count)
        #expect(clock.pending == 0, "no timer outlives the launch")
    }
}

/// [offline] The reconnect notice (§5.1): `connection-startup.test.ts` 407–436 and `reconnectBanner`'s rules.
@MainActor @Suite struct ReconnectBannerTests {
    typealias Clock = ReadFlightTests.FakeClock

    final class Probe {
        var shown: [String] = []
        var clears = 0
        var offline = false
    }

    private func make(_ probe: Probe, clock: Clock) -> ReconnectBanner {
        ReconnectBanner(clock: clock, offline: { probe.offline }, show: { probe.shown.append($0) }, clear: { probe.clears += 1 })
    }

    @Test func aBlipShowsNothing() async {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        banner.socketError(attempt: 0)
        await clock.advance(3.9)
        banner.open()
        await clock.advance(10)
        #expect(probe.shown.isEmpty)
        #expect(probe.clears == 0, "nothing was on show to clear")
    }

    @Test func anOutageShowsAfterTheHoldAndNamesNoCauseUntilAnAttemptFails() async {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        banner.socketError(attempt: 0)
        await clock.advance(4)
        #expect(probe.shown == ["Reconnecting to the computer running Hermes…"])
        banner.socketError(attempt: 1)
        banner.failure(reason: "timeout")
        #expect(probe.shown.last == "The computer running Hermes is slow to answer — still trying…")
        banner.failure(reason: "rate-limited")
        #expect(probe.shown.last == "The computer running Hermes is busy — still trying…")
        banner.failure(reason: "unreachable")
        #expect(probe.shown.last == "Can’t reach the computer running Hermes. Check your network or VPN connection. Reconnecting…")
        banner.failure(reason: "tailscale-off")
        #expect(probe.shown.last == "Turn on Tailscale to reach the computer running Hermes. Reconnecting…")
        banner.failure(reason: "host-rejected")
        #expect(probe.shown.last == "Can’t connect to the computer running Hermes right now. Reconnecting…")
        banner.open()
        #expect(probe.clears == 1)
        #expect(banner.shown.isEmpty)
    }

    @Test func aFailureBeforeTheHoldIsHeldToo() async {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        banner.socketError(attempt: 1)
        banner.failure(reason: "timeout")
        #expect(probe.shown.isEmpty)
        await clock.advance(4)
        #expect(probe.shown == ["The computer running Hermes is slow to answer — still trying…"])
    }

    @Test func aLostNetworkShowsAtOnceAndClearsAtOnce() async {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        banner.network(reachable: false)
        #expect(probe.shown == ["Network unavailable. Check your network or VPN connection."])
        banner.network(reachable: true)
        #expect(probe.clears == 1)
        await clock.advance(10)
        #expect(probe.shown.count == 1, "the cancelled hold shows nothing later")
    }

    @Test func aBackgroundPauseSaysNothing() async {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        banner.socketError(attempt: 0)
        banner.failure(reason: "paused")
        await clock.advance(10)
        #expect(probe.shown.isEmpty)
        banner.foreground()
        banner.socketError(attempt: 1)
        await clock.advance(4)
        #expect(probe.shown == ["Can’t reach the computer running Hermes. Check your network or VPN connection. Reconnecting…"])
    }

    @Test func onceTheHeaderReadsOfflineItSaysHermesHQKeepsTrying() async {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        banner.socketError(attempt: 0)
        await clock.advance(10)
        #expect(probe.shown == ["Reconnecting to the computer running Hermes…"])
        probe.offline = true
        banner.refresh()
        #expect(probe.shown.last == "The computer running Hermes is out of reach. Hermes HQ keeps trying.")
        banner.socketError(attempt: 1)
        banner.failure(reason: "timeout")
        #expect(probe.shown.last == "The computer running Hermes is slow to answer. Hermes HQ keeps trying.")
        #expect(!probe.shown.contains { $0.contains("Reconnecting…") && $0.contains("keeps trying") })
    }

    @Test func refreshShowsNothingByItself() {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        probe.offline = true
        banner.refresh()
        #expect(probe.shown.isEmpty)
    }

    @Test func theSameSentenceIsShownOnce() async {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        banner.socketError(attempt: 0)
        await clock.advance(4)
        banner.socketError(attempt: 0)
        banner.refresh()
        banner.socketError(attempt: 0)
        #expect(probe.shown.count == 1)
    }

    @Test func signedOutStopsItForGood() async {
        let clock = Clock(), probe = Probe()
        let banner = make(probe, clock: clock)
        banner.socketError(attempt: 0)
        await clock.advance(4)
        banner.stop()
        #expect(probe.clears == 1 && banner.isStopped)
        banner.socketError(attempt: 1)
        banner.failure(reason: "timeout")
        banner.network(reachable: false)
        await clock.advance(10)
        #expect(probe.shown.count == 1, "nothing after sign-out: Sign in again replaces it")
    }

    @Test func everySentenceIsPlainAndNamesNoHost() {
        for reason in [nil, "", "unreachable", "timeout", "rate-limited", "tailscale-off", "tls", "host-rejected", "weird-code"] as [String?] {
            for failed in [false, true] {
                for offline in [false, true] {
                    let text = ReconnectNotice.text(networkDown: false, reason: reason, failed: failed, offline: offline)
                    #expect(!text.isEmpty)
                    #expect(!text.contains("Dispatch") && !text.contains("http") && !text.contains("weird-code"))
                }
            }
        }
        #expect(ReconnectNotice.symbol(for: ReconnectNotice.networkDown) == "wifi.exclamationmark")
        #expect(ReconnectNotice.symbol(for: ReconnectNotice.reconnecting) == "arrow.triangle.2.circlepath")
    }
}

/// [offline] One reading of the link for every header and the notice (§5.1, §5.2).
@MainActor @Suite struct HeaderLinkTests {
    @Test func wordsByState() {
        #expect(HeaderLink.words(.ready, reconnectingFor: nil) == nil)
        #expect(HeaderLink.words(.connecting, reconnectingFor: nil) == nil)
        #expect(HeaderLink.words(.reconnecting(attempt: 1), reconnectingFor: 5) == "Reconnecting…")
        #expect(HeaderLink.words(.reconnecting(attempt: 9), reconnectingFor: 119.9) == "Reconnecting…")
        #expect(HeaderLink.words(.reconnecting(attempt: 9), reconnectingFor: 120) == "Offline")
        #expect(HeaderLink.words(.offline(reason: "timeout"), reconnectingFor: nil) == "Offline")
        #expect(HeaderLink.words(.signedOut(reason: "session-ended"), reconnectingFor: 500) == "Signed Out")
        #expect(!HeaderLink.isOffline(.signedOut(reason: "session-ended"), reconnectingFor: 500))
    }

    @Test func theClockCountsOneOutageFromItsFirstReconnecting() {
        var now = Date(timeIntervalSince1970: 1_000)
        let clock = OutageClock(now: { now })
        #expect(clock.note(.reconnecting(attempt: 1)), "the outage begins")
        now += 60
        #expect(!clock.note(.reconnecting(attempt: 2)), "a later attempt is the same outage")
        #expect(clock.words(.reconnecting(attempt: 2)) == "Reconnecting…")
        now += 60
        #expect(clock.words(.reconnecting(attempt: 3)) == "Offline")
        #expect(clock.isOffline(.reconnecting(attempt: 3)))
        #expect(!clock.note(.ready))
        #expect(clock.reconnectingSince == nil)
        #expect(clock.note(.reconnecting(attempt: 1)), "a new outage starts its own two minutes")
        #expect(clock.words(.reconnecting(attempt: 1)) == "Reconnecting…")
        clock.reset()
        #expect(clock.reconnectingSince == nil)
    }
}

/// [offline] One alert at a time, said once, held while something else is on top (§5.2, §5.3).
@Suite struct NoticeSlotTests {
    @Test func showsOnceAndNotAgainWhileUp() {
        var slot = NoticeSlot()
        let first = slot.request(canShow: true)
        let second = slot.request(canShow: true)
        #expect(first && !second)
        #expect(slot.presented == 1 && slot.showing)
        slot.dismissed()
        #expect(!slot.showing && !slot.pending)
        let third = slot.request(canShow: true)
        #expect(third && slot.presented == 2, "a new streak may say it again")
    }

    @Test func heldUntilItCanShow() {
        var slot = NoticeSlot()
        let now = slot.request(canShow: false)
        #expect(!now && slot.pending && slot.presented == 0)
        let stillBusy = slot.resume(canShow: false)
        #expect(!stillBusy && slot.pending)
        let later = slot.resume(canShow: true)
        #expect(later && slot.showing && !slot.pending)
        let again = slot.resume(canShow: true)
        #expect(!again, "nothing held any more")
    }

    @Test func aFailedPresentIsHeldAgain() {
        var slot = NoticeSlot()
        _ = slot.request(canShow: true)
        slot.dismissed(again: true)
        #expect(slot.pending && !slot.showing)
        slot.reset()
        #expect(!slot.pending && !slot.showing)
    }
}

/// [offline] The offline screen's status line and what VoiceOver hears (§3.5, §3.6).
@MainActor @Suite struct OfflineScreenModelTests {
    @Test func countdownComesFromTheDueDateAndNeverReadsZero() {
        let model = OfflineScreenModel()
        let start = Date(timeIntervalSince1970: 10_000)
        model.setStatus(due: start.addingTimeInterval(6), connecting: false)
        #expect(model.statusText(now: start) == "Trying Again in 6\u{00A0}s")
        #expect(model.statusText(now: start.addingTimeInterval(0.4)) == "Trying Again in 6\u{00A0}s")
        #expect(model.statusText(now: start.addingTimeInterval(5.2)) == "Trying Again in 1\u{00A0}s")
        #expect(model.statusText(now: start.addingTimeInterval(6)) == "Trying Again in 1\u{00A0}s")
        #expect(model.statusText(now: start.addingTimeInterval(60)) == "Trying Again in 1\u{00A0}s", "never 0 or negative")
    }

    @Test func oneAnnouncementPerCountdownAndOnePerAttempt() {
        let model = OfflineScreenModel()
        var heard: [String] = []
        model.announce = { heard.append($0) }
        let due = Date().addingTimeInterval(3)
        model.setStatus(due: due, connecting: false)
        model.setStatus(due: due, connecting: false)
        model.setStatus(due: due.addingTimeInterval(0.2), connecting: false)   // the same countdown, re-read
        #expect(heard == ["Trying again automatically"])
        model.setStatus(due: nil, connecting: true)
        model.setStatus(due: nil, connecting: true)
        #expect(heard == ["Trying again automatically", "Connecting…"])
        #expect(!model.tryAgainEnabled && model.statusText() == "Connecting…")
        model.setStatus(due: Date().addingTimeInterval(6), connecting: false)
        #expect(heard == ["Trying again automatically", "Connecting…", "Trying again automatically"])
        #expect(model.announced == heard)
        #expect(model.tryAgainEnabled)
    }

    @Test func voiceOverNeverHearsTheNumber() {
        let model = OfflineScreenModel()
        model.setStatus(due: Date().addingTimeInterval(24), connecting: false)
        #expect(model.spokenStatus == "Trying again automatically")
        #expect(!model.spokenStatus.contains("24"))
        model.setStatus(due: nil, connecting: false)
        #expect(model.spokenStatus.isEmpty && model.statusText().isEmpty)
    }

    @Test func aProblemSentenceReplacesTheStatus() {
        let model = OfflineScreenModel()
        model.setStatus(due: Date().addingTimeInterval(3), connecting: false)
        model.problem = StartupProblems.storage
        #expect(model.statusText() == StartupProblems.storage)
        #expect(model.spokenStatus == StartupProblems.storage)
    }

    @Test func buttonsFollowWhatIsKnown() {
        let model = OfflineScreenModel()
        model.reason = "timeout"
        #expect(!model.showsDifferentGateway, "no address to start from")
        #expect(model.card == OfflineCopy.Card(name: OfflineCopy.unnamedCard, detail: OfflineCopy.unreadableDetail))
        model.url = URL(string: "http://studio.tail1234.ts.net:9119")
        model.accountName = "ivy"
        #expect(model.showsDifferentGateway && !model.showsSignInAgain)
        #expect(model.card?.detail == "studio.tail1234.ts.net:9119 · ivy")
        #expect(model.screen.title == "Hermes Isn’t Answering")
        model.reason = OfflineCopy.keychainUnreadable
        #expect(model.showsSignInAgain)
        model.focusStatus()
        #expect(model.focusRequests == 1)
    }

    @Test func longAndUnusualGatewayNamesStayReadable() {
        let long = String(repeating: "Office Mac in the back office ", count: 7)      // 210 characters
        let card = OfflineCopy.card(reason: "timeout", url: URL(string: "http://[fd7a:115c:a1e0::1]:9119"), label: long, accountName: "ivy")
        #expect(card?.name == long.trimmingCharacters(in: .whitespaces))
        #expect(card?.detail.contains("%") == false, "never raw percent-encoding: \(card?.detail ?? "")")
        #expect(card?.detail.contains("9119") == true)
        let emoji = OfflineCopy.card(reason: nil, url: URL(string: "https://mac.example"), label: "🏡🖥️", accountName: "Nous account")
        #expect(emoji?.name == "🏡🖥️")
        let rtl = OfflineCopy.card(reason: nil, url: URL(string: "https://mac.example"), label: "بوابة المنزل", accountName: "")
        #expect(rtl?.name == "بوابة المنزل" && rtl?.detail == "mac.example")
    }
}
