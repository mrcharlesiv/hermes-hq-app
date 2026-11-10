import Foundation
import Testing
@testable import HermesHQNative

/// [offline] The offline screen's words by reason, the gateway card, the retry ladder and its countdown
/// (docs/spec/3x-offline.md §3.5, §3.6).
@Suite struct OfflineCopyTests {
    @Test func everyReasonHasItsWords() {
        let rows: [(String, String, String)] = [
            ("tailscale-off", "Turn On Tailscale", "Turn on Tailscale to reach the computer running Hermes. Hermes HQ reconnects as soon as it’s on."),
            ("timeout", "Hermes Isn’t Answering", "The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying."),
            ("tls", "Can’t Verify Hermes", "iPhone doesn’t trust the HTTPS certificate of the computer running Hermes. Hermes HQ keeps trying; if this continues, sign in with a trusted address."),
            ("gateway-outdated", "Update Hermes", "The computer running Hermes has a version of Hermes that’s too old for Hermes HQ. Update Hermes there; Hermes HQ keeps trying."),
            ("rate-limited", "Hermes Is Busy", "It is limiting sign-ins right now. Hermes HQ will try again shortly."),
            ("host-rejected", "Hermes Isn’t Accepting This Address", "Hermes no longer accepts connections at the saved address. On the computer running Hermes, check HERMES_DASHBOARD_PUBLIC_URL in ~/.hermes/.env; Hermes HQ keeps trying."),
            ("not-hermes", "Can’t Reach Hermes", "The saved address answered, but not as Hermes. Hermes HQ keeps trying; check the computer running Hermes, or sign in with its current address."),
            ("keychain-locked", "Unlock Your iPhone", "Your saved sign-in is protected until iPhone is unlocked. Hermes HQ reconnects as soon as it is."),
            ("keychain-unavailable", "Can’t Open Your Saved Sign-In", "iPhone couldn’t open it just now. Hermes HQ keeps trying. Your local drafts are being kept."),
            ("keychain-unreadable", "Can’t Read Your Saved Sign-In", "Sign in again to continue. Drafts on this iPhone are kept aside, not moved to the account you sign in with."),
        ]
        for (reason, title, recovery) in rows {
            for hasAddress in [true, false] {
                let screen = OfflineCopy.screen(reason: reason, hasAddress: hasAddress)
                #expect(screen.title == title, "\(reason)")
                #expect(screen.recovery == recovery, "\(reason)")
            }
        }
    }

    /// §3.5: a saved address whose session check is gone (404) is an older Hermes when its public status still
    /// answers with a version, and not Hermes otherwise (the sign-in form's rule).
    @Test func aMissingSessionCheckIsAnOlderHermesOrNotHermes() {
        #expect(GatewayAuth.missingSessionCheck(status: 200, body: Data(#"{"version":"0.9.0","release_date":"2026.1.5"}"#.utf8)) == .gatewayOutdated)
        #expect(GatewayAuth.missingSessionCheck(status: 200, body: Data("<!doctype html><title>Welcome</title>".utf8)) == .notHermes)
        #expect(GatewayAuth.missingSessionCheck(status: 200, body: Data(#"{"ok":true}"#.utf8)) == .notHermes)
        #expect(GatewayAuth.missingSessionCheck(status: 404, body: Data(#"{"version":"0.9.0"}"#.utf8)) == .notHermes)
        #expect(GatewayAuth.missingSessionCheck(status: nil, body: nil) == .notHermes)
        #expect(OfflineCopy.screen(reason: GatewayFailure.gatewayOutdated.code, hasAddress: true).title == "Update Hermes")
        #expect(OfflineCopy.screen(reason: GatewayFailure.notHermes.code, hasAddress: true).recovery.contains("not as Hermes."))
    }

    @Test func anythingElseGetsTheDefaultPair() {
        for reason in ["unreachable", "unavailable", "gateway-error", "something-new", ""] {
            let known = OfflineCopy.screen(reason: reason, hasAddress: true)
            #expect(known.title == "Can’t Reach Hermes")
            #expect(known.recovery == "The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying.")
            let unknown = OfflineCopy.screen(reason: reason, hasAddress: false)
            #expect(unknown.title == "Can’t Reach Hermes")
            #expect(unknown.recovery == "Tap Try Again to recover your saved connection before changing sign-in. Your local drafts are being kept.")
        }
        #expect(OfflineCopy.screen(reason: nil, hasAddress: true).title == "Can’t Reach Hermes")
    }

    /// Audit 06-10: no network on the phone is said as that, not as the computer being asleep, and the status line
    /// says what it waits for (nothing dials, so there is no countdown).
    @MainActor @Test func noNetworkOnThePhoneSaysSo() {
        for hasAddress in [true, false] {
            let screen = OfflineCopy.screen(reason: GatewayFailure.offline.code, hasAddress: hasAddress)
            #expect(screen.title == "You’re Offline")
            #expect(screen.recovery == "iPhone isn’t connected to the internet. Hermes HQ reconnects as soon as it is.")
        }
        let model = OfflineScreenModel()
        model.reason = GatewayFailure.offline.code
        model.url = URL(string: "http://127.0.0.1:9980")
        #expect(model.statusText() == "Waiting for a connection…" && model.spokenStatus == "Waiting for a connection…")
        model.setStatus(due: nil, connecting: true)
        #expect(model.statusText() == "Connecting…")
        model.reason = "unreachable"
        model.setStatus(due: nil, connecting: false)
        #expect(model.statusText() == "")
    }

    /// Audit 06-11: a Nous agent has no computer to be asleep; the words say it may be stopped or starting.
    @MainActor @Test func aNousAgentIsNotAComputer() {
        let agent = URL(string: "https://research-bot-3f2a.agents.nousresearch.com")
        #expect(OfflineCopy.nousHosted(agent) && !OfflineCopy.nousHosted(URL(string: "http://mac-mini.local:9119")) && !OfflineCopy.nousHosted(nil))
        for reason in ["timeout", "unreachable", "unavailable"] {
            let screen = OfflineCopy.screen(reason: reason, hasAddress: true, nous: true)
            #expect(screen.recovery == OfflineCopy.nousRecovery, "\(reason)")
            #expect(!screen.recovery.contains("computer"))
        }
        #expect(OfflineCopy.screen(reason: "timeout", hasAddress: true, nous: true).title == "Hermes Isn’t Answering")
        #expect(OfflineCopy.screen(reason: "tls", hasAddress: true, nous: true) == OfflineCopy.screen(reason: "tls", hasAddress: true),
                "a reason with its own words keeps them")
        #expect(OfflineCopy.screen(reason: "unreachable", hasAddress: false, nous: true).recovery == OfflineCopy.noAddressRecovery)
        #expect(LaunchGate.Status.stalled(throughTailscale: false, nous: true) == "Still connecting. Your Nous agent may be stopped or still starting.")
        #expect(LaunchGate.Status.stalled(throughTailscale: true) == LaunchGate.Status.stalledTailscale)
    }

    /// Audit 06-14: the ended-session notice names its gateway, and "Sign In Again" is spelled one way everywhere.
    @Test func theSessionEndedNoticeNamesItsGateway() {
        #expect(OfflineNotices.signInAgainTitle == "Sign In Again" && OfflineNotices.signInAgainAction == OfflineCopy.signInAgain)
        #expect(OfflineNotices.signInAgainMessage(gateway: "Studio")
                == "Studio ended this iPhone’s session. Sign in again to reconnect; your drafts are kept.")
        #expect(OfflineNotices.signInAgainMessage(gateway: "  ").hasPrefix("Your gateway ended this iPhone’s session."))
        #expect(OfflineNotices.signInAgainMessage(gateway: nil).hasPrefix("Your gateway ended this iPhone’s session."))
        #expect(OfflineCopy.signInAgainTitle == "Sign In Again?")
    }

    /// Every failure the connection can publish has words here: none falls through to a raw code.
    @Test func everyGatewayFailureCodeReadsAsWords() {
        let failures: [GatewayFailure] = [.unreachable, .timeout, .tls, .tailscaleOff, .rateLimited, .hostRejected, .notHermes,
                                          .gatewayOutdated, .responseTooLarge, .gatewayError("boom")]
        for failure in failures {
            let screen = OfflineCopy.screen(reason: failure.code, hasAddress: true)
            #expect(!screen.title.isEmpty && !screen.recovery.isEmpty)
            #expect(!screen.title.contains(failure.code) || failure.code == "timeout", "\(failure.code) shown raw")
            #expect(!screen.recovery.contains("-error"))
        }
    }

    @Test func cardLines() {
        let ip = URL(string: "http://127.0.0.1:9980")!
        #expect(OfflineCopy.card(reason: "unreachable", url: ip, label: nil, accountName: "ivy")
                == .init(name: "The computer running Hermes", detail: "127.0.0.1:9980 · ivy"))
        let mac = URL(string: "https://alexs-Mac-Studio.local:8443")!
        #expect(OfflineCopy.card(reason: "timeout", url: mac, label: nil, accountName: GatewayNaming.nousAccountName)
                == .init(name: "Alex’s Mac Studio", detail: "alexs-mac-studio.local:8443 · Nous account"))
        // A name given on this phone wins; empty parts are left out.
        #expect(OfflineCopy.card(reason: nil, url: mac, label: "  Home  ", accountName: "")
                == .init(name: "Home", detail: "alexs-mac-studio.local:8443"))
        #expect(OfflineCopy.card(reason: nil, url: URL(string: "https://hermes.example.com")!, label: nil, accountName: "ivy")
                == .init(name: "Hermes", detail: "hermes.example.com · ivy"))
        // An IPv6 address keeps its brackets beside the port and shows no percent-encoding.
        let six = OfflineCopy.card(reason: nil, url: URL(string: "http://[fd7a:115c:a1e0::1]:9119")!, label: nil, accountName: "ivy")
        #expect(six == .init(name: "The computer running Hermes", detail: "[fd7a:115c:a1e0::1]:9119 · ivy"))
        #expect(six?.detail.contains("%") == false)
    }

    @Test func cardWithoutAnAddress() {
        #expect(OfflineCopy.card(reason: "timeout", url: nil, label: nil, accountName: nil)
                == .init(name: "The computer running Hermes", detail: "Your saved sign-in could not be read."))
        // A Keychain reason has its own title and words: no card that contradicts them (UX study #126).
        #expect(OfflineCopy.card(reason: "keychain-locked", url: nil, label: nil, accountName: nil) == nil)
        #expect(OfflineCopy.card(reason: "keychain-unavailable", url: nil, label: nil, accountName: nil) == nil)
        #expect(OfflineCopy.card(reason: "keychain-unreadable", url: nil, label: nil, accountName: nil) == nil)
        #expect(OfflineCopy.card(reason: "keychain-unreadable", url: URL(string: "http://10.0.0.2:9119")!, label: nil, accountName: "ivy") != nil)
    }

    @Test func buttonsByState() {
        #expect(OfflineCopy.showsDifferentGateway(hasAddress: true))
        #expect(!OfflineCopy.showsDifferentGateway(hasAddress: false))
        #expect(OfflineCopy.showsSignInAgain(reason: "keychain-unreadable"))
        #expect(!OfflineCopy.showsSignInAgain(reason: "keychain-locked"))
        #expect(!OfflineCopy.showsSignInAgain(reason: nil))
        // A Keychain that still can't open the sign-in after a few reads offers the way out too; a locked phone never.
        #expect(!OfflineCopy.showsSignInAgain(reason: "keychain-unavailable", failedReads: 2))
        #expect(OfflineCopy.showsSignInAgain(reason: "keychain-unavailable", failedReads: 3))
        #expect(!OfflineCopy.showsSignInAgain(reason: "keychain-locked", failedReads: 10))
        #expect(OfflineCopy.tryAgain == "Try Again")
        #expect(OfflineCopy.differentGateway == "Change Address or Sign In")
        #expect(OfflineCopy.switchTo("Mac Studio") == "Switch to Mac Studio")
        #expect(OfflineCopy.signInAgain == "Sign In Again")
    }

    @Test func countdownWords() {
        #expect(OfflineCopy.countdown(2.2) == "Trying Again in 3\u{00A0}s")
        #expect(OfflineCopy.countdown(0.2) == "Trying Again in 1\u{00A0}s")
        #expect(OfflineCopy.countdown(0) == "Trying Again in 1\u{00A0}s")
        #expect(OfflineCopy.countdown(-4) == "Trying Again in 1\u{00A0}s")
        #expect(OfflineCopy.countdown(30) == "Trying Again in 30\u{00A0}s")
        #expect(OfflineCopy.connecting == "Connecting…")
        #expect(OfflineCopy.retryingSpoken == "Trying again automatically")
    }

    /// The forbidden word never reaches a screen (product rule).
    @Test func noForbiddenWord() {
        var all = [OfflineCopy.tryAgain, OfflineCopy.differentGateway, OfflineCopy.signInAgain, OfflineCopy.connecting,
                   OfflineCopy.retryingSpoken, OfflineCopy.unreadableDetail, OfflineCopy.signInAgainTitle,
                   OfflineCopy.signInAgainMessage, OfflineCopy.defaultRecovery, OfflineCopy.noAddressRecovery]
        for reason in ["tailscale-off", "timeout", "tls", "gateway-outdated", "rate-limited", "host-rejected", "not-hermes",
                       "keychain-locked", "keychain-unavailable", "keychain-unreadable", "unreachable"] {
            let screen = OfflineCopy.screen(reason: reason, hasAddress: true)
            all += [screen.title, screen.recovery]
        }
        for text in all { #expect(!text.localizedCaseInsensitiveContains("dispatch"), "\(text)") }
    }
}

@Suite struct RetryLadderTests {
    @Test func steps() {
        #expect(RetryLadder.steps == [3, 6, 12, 24, 30])
        #expect((0..<8).map { RetryLadder.wait(attempt: $0) } == [3, 6, 12, 24, 30, 30, 30, 30])
        #expect(RetryLadder.wait(attempt: -3) == 3)
        #expect(RetryLadder.wait(attempt: 10_000) == 30)
    }

    @Test func retryAfterStretchesAndIsCapped() {
        #expect(RetryLadder.wait(attempt: 0, retryAfter: 20) == 20)
        #expect(RetryLadder.wait(attempt: 3, retryAfter: 20) == 24)        // the ladder's own step is longer
        #expect(RetryLadder.wait(attempt: 0, retryAfter: 300) == 120)
        #expect(RetryLadder.wait(attempt: 4, retryAfter: 119) == 119)
        // Not a positive number of seconds: ignored, the ladder is used.
        #expect(RetryLadder.wait(attempt: 1, retryAfter: -5) == 6)
        #expect(RetryLadder.wait(attempt: 1, retryAfter: 0) == 6)
        #expect(RetryLadder.wait(attempt: 1, retryAfter: .nan) == 6)
        #expect(RetryLadder.wait(attempt: 1, retryAfter: .infinity) == 6)
    }

    @Test func remainingComesFromTheClock() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(abs(RetryLadder.remaining(until: now.addingTimeInterval(2.2), now: now) - 2.2) < 0.001)
        #expect(RetryLadder.remaining(until: now.addingTimeInterval(-9), now: now) == 0)
        // A run loop that slept through most of the wait: the number is right the moment it wakes.
        #expect(OfflineCopy.countdown(RetryLadder.remaining(until: now.addingTimeInterval(24), now: now.addingTimeInterval(23.5)))
                == "Trying Again in 1\u{00A0}s")
    }
}
