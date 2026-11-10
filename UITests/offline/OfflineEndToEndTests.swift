// [offline] The launch screen, the offline screen and reconnect behaviour end to end (docs/spec/3x-offline.md §8)
// against the offline stand-in (scripts/e2e-offline.sh starts scripts/fixtures/offline-gateway.py twice and passes
// TEST_RUNNER_HQN_UI_CREDENTIALS, _B, TEST_RUNNER_HQN_UI_OFFLINE=1 and TEST_RUNNER_HQN_OFFLINE_CONTROL; without them
// every test here skips). The stand-in's gateway port can refuse, hang or answer errors; its control port always
// answers, so every control goes there. "Leaving" the app is a trip to the Home Screen and then the end of the
// process, as iOS ends a backgrounded app. All values are invented. Tests named testS… are the repeatable items of
// the spec's stress plan (§9), sized to run in a builder's pass.

import CryptoKit
import XCTest

final class OfflineEndToEndTests: XCTestCase {
    var account: FixtureAccount!
    var other: FixtureAccount!
    /// The stand-ins' control ports (as `FixtureAccount`s, for `control(_:_:)`).
    var ctl: FixtureAccount!
    var ctlB: FixtureAccount?
    var app: XCUIApplication!
    /// The simulator was dark when this test session began (the dark pass of scripts/e2e-offline.sh). XCTest gives the
    /// apps it launches the appearance the simulator had when the session started: switching mid-session, with
    /// `XCUIDevice.shared.appearance` or with `xcrun simctl ui`, changed the setting but not those apps (seen in the
    /// tests' own screen recordings and pixels, 2026-10-12). So the dark screenshots are a pass of their own, and
    /// following the system live is checked without XCTest by scripts/offline-appearance-check.sh.
    var darkSession = false

    static let storageSentence = "Hermes HQ couldn’t switch this iPhone’s saved app data to this account. Your drafts are kept. "
        + "If iPhone storage is almost full, free up some space, then try again."
    /// Every sentence the reconnect notice may say (`ReconnectNotice`); anything else on the banner is a bug.
    static let bannerSentences: Set<String> = [
        "Network unavailable. Check your network or VPN connection.",
        "Reconnecting to the computer running Hermes…",
        "Turn on Tailscale to reach the computer running Hermes. Reconnecting…",
        "The computer running Hermes is slow to answer — still trying…",
        "The computer running Hermes is busy — still trying…",
        "Can’t reach the computer running Hermes. Check your network or VPN connection. Reconnecting…",
        "Can’t connect to the computer running Hermes right now. Reconnecting…",
        // The header says Offline (never connected in this run, or two minutes of trying).
        "The computer running Hermes is out of reach. Hermes HQ keeps trying.",
        "Turn on Tailscale to reach the computer running Hermes. Hermes HQ keeps trying.",
        "The computer running Hermes is slow to answer. Hermes HQ keeps trying.",
        "The computer running Hermes is busy. Hermes HQ keeps trying.",
        "Can’t reach the computer running Hermes. Check your network or VPN connection. Hermes HQ keeps trying.",
        "Can’t connect to the computer running Hermes right now. Hermes HQ keeps trying.",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["HQN_UI_OFFLINE"] == "1", let control = env["HQN_OFFLINE_CONTROL"], !control.isEmpty else {
            throw XCTSkip("Run with scripts/e2e-offline.sh (the offline stand-in).")
        }
        account = try FixtureAccount.load()
        darkSession = env["HQN_UI_START_DARK"] == "1"
        ctl = FixtureAccount(url: control, username: "", password: "")
        if let path = env["HQN_UI_CREDENTIALS_B"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let url = object["url"] as? String, let username = object["username"] as? String, let password = object["password"] as? String {
            other = FixtureAccount(url: url, username: username, password: password)
            if let control = object["control"] as? String { ctlB = FixtureAccount(url: control, username: "", password: "") }
        }
        try ctl.control("/__fixture/reset", [:])
        try? ctlB?.control("/__fixture/reset", [:])
    }

    override func tearDownWithError() throws {
        _ = try? ctl?.control("/__fixture/reset", ["seed": false])
    }

    // MARK: O1. A first sign-in goes through the launch screen to the app

    @MainActor func testO01_SignInGoesThroughLaunchToTheApp() throws {
        freshApp()
        XCTAssertFalse(el("offline").exists, "no offline screen")
        XCTAssertFalse(el("launch").exists, "the launch screen has left")
        XCTAssertFalse(bannerShowing(), "no reconnect notice on a good connection")
        XCTAssertFalse(app.staticTexts["Reconnecting…"].exists || app.staticTexts["Offline"].exists, "the header is quiet")
        XCTAssertGreaterThanOrEqual(count("tickets"), 1, "one socket ticket was asked for")
        shot("offline-app-light")
    }

    // MARK: O2. Saved rows at once while the gateway is down; the notice after 4 s; quiet again once it is back

    @MainActor func testO02_CachedLaunchShowsSavedRowsWhileTheGatewayIsDown() throws {
        freshApp()
        leave()
        setMode("status", ["status": 503])
        relaunch()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botShown("default") }, "the saved list is on show at once")
        XCTAssertFalse(el("offline").exists, "saved content: never the offline screen")
        // The notice waits out a blip (4 s), then says why in a sentence.
        XCTAssertTrue(waitUntil(timeout: 20) { self.bannerShowing() }, "the reconnect notice shows")
        let words = bannerText()
        XCTAssertTrue(Self.bannerSentences.contains(words), "a known sentence: \(words)")
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.staticTexts["Offline"].exists || self.app.staticTexts["Reconnecting…"].exists },
                      "the header says the link is down")
        XCTAssertFalse(el("offline").exists, "still the app")
        shot("offline-banner-light")
        setMode("up")
        XCTAssertTrue(waitUntil(timeout: 60) { !self.bannerShowing() }, "the notice clears once connected")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.app.staticTexts["Offline"].exists && !self.app.staticTexts["Reconnecting…"].exists },
                      "the header is quiet again")
    }

    // MARK: O3. Nothing saved and the gateway down: the offline screen, the countdown from the real ladder, and back

    @MainActor func testO03_UncachedLaunchShowsTheOfflineScreenAndRecovers() throws {
        freshApp()
        leave()
        try ctl.control("/__fixture/reset", ["seed": false])
        setMode("status", ["status": 503])
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15), "the offline screen")
        XCTAssertEqual(el("offline.title").label, "Can’t Reach Hermes")
        XCTAssertEqual(el("offline.recovery").label, "The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying.")
        let card = el("offline.card").label
        let host = URL(string: account.url).map { "\($0.host ?? ""):\($0.port ?? 0)" } ?? ""
        XCTAssertTrue(card.contains(host), "the card names the gateway (\(host)): \(card)")
        XCTAssertTrue(card.contains(account.username), "and the account: \(card)")
        XCTAssertFalse(card.contains("http"), "host and port, not a URL: \(card)")
        XCTAssertTrue(app.buttons["offline.try-again"].exists && app.buttons["offline.different-gateway"].exists)
        XCTAssertFalse(app.buttons["offline.sign-in-again"].exists, "Sign In Again is only for an unreadable sign-in")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no tabs under it")
        shot("offline-screen-light")
        // The countdown: "Trying Again in N s", N from the due date, never 0, never above the ladder's top (30).
        var seen: [Int] = [], sawConnecting = false
        let end = Date().addingTimeInterval(24)
        while Date() < end {
            let words = statusWords()
            if let n = countdown(words) {
                XCTAssertTrue((1...30).contains(n), "the countdown stays in range: \(words)")
                seen.append(n)
            } else if words == "Connecting…" {
                sawConnecting = true
            } else {
                XCTAssertTrue(words.isEmpty, "only a countdown or Connecting…: \(words)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(seen.isEmpty, "a countdown was on show")
        _ = sawConnecting          // "Connecting…" lasts under a second; whether a slow run catches it proves nothing
        // That attempts ran is read from the stand-in's ledger, not from how often this test managed to look: the
        // dials follow the ladder (3, 6, 12 s), bursts of requests, each one wait apart.
        // A dial is the session check or the ticket request; any other request the app makes meanwhile (its
        // diagnostic log upload) is not one and does not count as a rung.
        let bursts = dialAttempts()
        let others = Set(((ledger()["rest"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String }).subtracting(["/api/auth/me", "/api/auth/ws-ticket"])
        if !others.isEmpty { note("requests beside the dials while offline: \(others.sorted())") }
        XCTAssertGreaterThanOrEqual(bursts.count, 3, "launch attempt and at least two retries: \(bursts)")
        let gaps = zip(bursts.dropFirst(), bursts).map { $0 - $1 }
        // From one dial's start to the next is the dial itself (how long the gateway took to fail it, seconds on a
        // loaded Mac) and then the wait. So the rule is a floor that is never undercut, and a ceiling with room for
        // the dial: never sooner than the rung, never as late as the rung above.
        XCTAssertGreaterThanOrEqual(gaps[0], 2.7, "first retry no sooner than 3 s after the first failure: \(gaps)")
        XCTAssertLessThan(gaps[0], 6, "and on the 3 s rung: \(gaps)")
        XCTAssertGreaterThanOrEqual(gaps[1], 5.7, "second retry no sooner than 6 s later: \(gaps)")
        XCTAssertLessThan(gaps[1], 12, "and on the 6 s rung: \(gaps)")
        if gaps.count > 2 {
            XCTAssertGreaterThanOrEqual(gaps[2], 11.7, "third retry no sooner than 12 s later: \(gaps)")
            XCTAssertLessThan(gaps[2], 24, "and on the 12 s rung: \(gaps)")
        }
        // Killed and reopened (stress 27): the offline screen again, the ladder starting over at 3 s.
        app.terminate()
        let earlier = restBursts().count
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15), "the offline screen again")
        XCTAssertTrue(waitUntil(timeout: 8) { self.countdown(self.statusWords()) != nil }, "a countdown")
        // The ladder starts over: this launch's first retry comes 3 s after its first failure (the last run had
        // reached 12 s). Read from the stand-in's ledger; the countdown on screen may already be the next one's by
        // the time a slow test run looks at it.
        XCTAssertTrue(waitUntil(timeout: 20) { self.restBursts().count >= earlier + 2 }, "this launch dialled and retried: \(restBursts())")
        let fresh = Array(restBursts().dropFirst(earlier))
        if fresh.count >= 2 { XCTAssertEqual(fresh[1] - fresh[0], 3, accuracy: 1.6, "the ladder starts over at 3 s: \(fresh)") }
        // The gateway returns: the next automatic retry opens the app, no tap needed.
        setMode("up")
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 40), "the app, by itself")
        XCTAssertTrue(waitUntil(timeout: 15) { self.botShown("default") }, "with its list")
        XCTAssertFalse(el("offline").exists)
    }

    // MARK: O4. The words follow the reason

    @MainActor func testO04_TheScreenIsWordedByReason() throws {
        freshApp()
        leave()
        let cases: [(name: String, mode: [String: Any], args: [String], title: String, recovery: String)] = [
            ("rate-limited", ["mode": "status", "status": 429, "retry_after": 300], [], "Hermes Is Busy", "It is limiting sign-ins right now."),
            // Hermes turns an address it does not expect away with 400 "Invalid Host header" (spec 01 §8.3).
            ("host-rejected", ["mode": "status", "status": 400, "body": "Invalid Host header"], [], "Hermes Isn’t Accepting This Address", "HERMES_DASHBOARD_PUBLIC_URL"),
            ("not-hermes", ["mode": "not-hermes"], [], "Can’t Reach Hermes", "not as Hermes"),
            ("gateway-outdated", ["mode": "outdated"], [], "Update Hermes", "too old for Hermes HQ"),
            ("timeout", ["mode": "blackhole"], [], "Hermes Isn’t Answering", "may be asleep or on another network"),
            ("tls", ["mode": "status", "status": 503], ["-HQDebugOfflineReason", "tls"], "Can’t Verify Hermes", "HTTPS certificate"),
            ("tailscale-off", ["mode": "status", "status": 503], ["-HQDebugOfflineReason", "tailscale-off"], "Turn On Tailscale", "Turn on Tailscale to reach the computer running Hermes."),
        ]
        for one in cases {
            app?.terminate()
            try ctl.control("/__fixture/mode", one.mode)
            relaunch(["-HQDebugResetCaches", "YES"] + one.args)
            XCTAssertTrue(el("offline.title").waitForExistence(timeout: 25), "\(one.name): the offline screen")
            XCTAssertEqual(el("offline.title").label, one.title, one.name)
            XCTAssertTrue(el("offline.recovery").label.contains(one.recovery), "\(one.name): \(el("offline.recovery").label)")
            let all = el("offline.title").label + " " + el("offline.recovery").label + " " + el("offline.card").label + " " + statusWords()
            for raw in ["429", "400", "503", "Invalid Host", "rate-limited", "host-rejected", "not-hermes", "gateway-outdated", "timeout", "Dispatch", "Error Domain"] {
                XCTAssertFalse(all.contains(raw), "\(one.name): no raw code on the screen (\(raw)): \(all)")
            }
            if one.name == "rate-limited" {
                // Retry-After: 300 is honoured up to 120 s and the countdown says so (stress 12).
                XCTAssertTrue(waitUntil(timeout: 6) { (self.countdown(self.statusWords()) ?? 0) > 30 }, "a long wait is shown: \(statusWords())")
                XCTAssertLessThanOrEqual(countdown(statusWords()) ?? 999, 120, "capped at 120 s")
                // (review) Try Again inside the wait the gateway asked for sends nothing; the countdown goes on.
                Thread.sleep(forTimeInterval: 2)
                let before = restTotal()
                XCTAssertTrue(waitUntil(timeout: 10) { self.app.buttons["offline.try-again"].isEnabled })
                app.buttons["offline.try-again"].tap()
                Thread.sleep(forTimeInterval: 4)
                XCTAssertEqual(restTotal(), before, "Try Again does not dial inside the gateway's Retry-After")
                XCTAssertTrue(waitUntil(timeout: 6) { (self.countdown(self.statusWords()) ?? 0) > 30 }, "the countdown goes on: \(statusWords())")
            }
            shot("offline-reason-\(one.name)")
        }
    }

    // MARK: O5. Try Again, and coming back to the app, each dial at once

    @MainActor func testO05_TryAgainAndReturningRetryAtOnce() throws {
        freshApp()
        leave()
        try ctl.control("/__fixture/reset", ["seed": false])
        setMode("status", ["status": 503])
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15), "the offline screen")
        // Let the ladder reach a long wait (3 + 6 s), so a dial inside it can only be the tap's.
        XCTAssertTrue(waitUntil(timeout: 25) { (self.countdown(self.statusWords()) ?? 0) >= 9 }, "a 12 s wait is counting: \(statusWords())")
        // No automatic dial is due for 9 s: a request in the next 4 s can only be the tap's.
        var before = restTotal()
        app.buttons["offline.try-again"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { self.restTotal() > before }, "Try Again dials at once")
        XCTAssertTrue(el("offline.title").exists, "still the offline screen while the gateway is down")
        XCTAssertTrue(waitUntil(timeout: 6) { self.countdown(self.statusWords()) != nil }, "and a countdown again: \(statusWords())")
        XCTAssertTrue(app.buttons["offline.try-again"].isEnabled, "the buttons are back")
        // (review) A Try Again that fails keeps the ladder's place: the wait that follows is the 12 s the ladder was
        // on, never the next rung (24 s), however often it is tapped.
        // Which rung that is comes from the ledger, not from a guess at how fast this test ran: the dials the app
        // made by itself so far (all dials less the taps) say where the ladder stands (3, 6, 12, 24, 30 s), and the
        // wait on show after a failed Try Again is at most that, never the rung above.
        let ladder = [3, 6, 12, 24, 30]
        let inForce = { (taps: Int) -> Int in ladder[max(0, min(self.dialAttempts().count - taps - 1, ladder.count - 1))] }
        XCTAssertTrue(waitUntil(timeout: 6) { self.countdown(self.statusWords()) != nil }, "a countdown")
        var shown = countdown(statusWords()) ?? 99
        var rung = inForce(1)
        XCTAssertLessThanOrEqual(shown, rung, "the wait after a failed Try Again is still the rung the ladder was on (\(rung) s): \(shown) s")
        note("after a failed Try Again: \(shown) s on show, the ladder on its \(rung) s rung")
        tapBetweenAttempts("offline.try-again")
        XCTAssertTrue(waitUntil(timeout: 8) { self.statusWords() != "Connecting…" && self.countdown(self.statusWords()) != nil }, "a countdown again")
        shown = countdown(statusWords()) ?? 99
        rung = inForce(2)
        XCTAssertLessThanOrEqual(shown, rung, "and after a second one (\(rung) s): \(shown) s")
        // Away and back mid-countdown (stress 22): a dial at once, the countdown recomputed, nothing stuck.
        XCTAssertTrue(waitUntil(timeout: 45) { (self.countdown(self.statusWords()) ?? 0) >= 9 }, "a long wait again: \(statusWords())")
        before = restTotal()
        goHome()
        Thread.sleep(forTimeInterval: 3)
        let away = restTotal()
        app.activate()
        XCTAssertTrue(waitUntil(timeout: 5) { self.restTotal() > away }, "returning dials at once")
        XCTAssertLessThanOrEqual(away - before, 2, "no dial storm in the background: \(away - before) requests in 3 s away")
        XCTAssertTrue(waitUntil(timeout: 8) { self.countdown(self.statusWords()) != nil }, "a countdown after the return: \(statusWords())")
        // The gateway is back: Try Again opens the app (stress 7 records the time).
        setMode("up")
        XCTAssertTrue(waitUntil(timeout: 20) { self.app.buttons["offline.try-again"].exists && self.app.buttons["offline.try-again"].isEnabled || self.app.tabBars.buttons["Bots"].exists })
        let tapped = Date()
        if app.buttons["offline.try-again"].exists { app.buttons["offline.try-again"].tap() }
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 20), "the app")
        XCTAssertTrue(waitUntil(timeout: 15) { self.botShown("default") }, "with its list")
        note("offline to app after Try Again: \(String(format: "%.2f", Date().timeIntervalSince(tapped))) s (includes XCTest polling)")
    }

    // MARK: O6. Change Address or Sign In: the prefilled sheet, Cancel, and a sign-in elsewhere

    @MainActor func testO06_DifferentGatewaySheet() throws {
        try XCTSkipIf(other == nil, "needs the second stand-in")
        freshApp()
        leave()
        setMode("status", ["status": 503])
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(app.buttons["offline.different-gateway"].waitForExistence(timeout: 15), "the offline screen")
        app.buttons["offline.different-gateway"].tap()
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8), "the sign-in form in a sheet")
        XCTAssertEqual(address.value as? String, account.url, "the saved address is filled in")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.app.textFields["sign-in-username"].value as? String) == self.account.username },
                      "and the saved username")
        XCTAssertTrue(app.buttons["offline.sign-in.cancel"].exists, "Cancel")
        shot("offline-different-gateway-sheet")
        app.buttons["offline.sign-in.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 6) { !self.app.textFields["sign-in-address"].exists }, "the sheet closes")
        XCTAssertTrue(el("offline.title").exists, "back on the offline screen")
        XCTAssertTrue(waitUntil(timeout: 20) { self.countdown(self.statusWords()) != nil || self.statusWords() == "Connecting…" },
                      "which never stopped retrying: \(statusWords())")
        // Again, and this time the other gateway.
        app.buttons["offline.different-gateway"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        typeSignIn(other)
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30), "signed in to the other gateway")
        dismissAlerts()
        XCTAssertTrue(waitUntil(timeout: 20) { self.anyLabel(containing: "B Hermes") }, "its bots are on show")
        XCTAssertFalse(el("offline").exists)
        shot("offline-other-gateway-app")
    }

    // MARK: O7. A saved sign-in the Keychain cannot hand over

    @MainActor func testO07_KeychainReasons() throws {
        freshApp()
        leave()
        // Locked: the words, no sign-in buttons that would throw the saved sign-in away, Try Again reads it again.
        relaunch(["-HQDebugRestoreFailure", "keychain-locked", "-HQDebugRestoreFailureCount", "2"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15), "the offline screen")
        XCTAssertEqual(el("offline.title").label, "Unlock Your iPhone")
        XCTAssertFalse(app.buttons["offline.sign-in-again"].exists)
        XCTAssertTrue(el("offline.card").label.contains(":"), "the card still names the gateway: \(el("offline.card").label)")
        shot("offline-reason-keychain-locked")
        // The sign-in reads again on the second retry: by Try Again here, or by the automatic retry if this run was
        // slow enough for it to get there first (that Try Again dials at once is O05's check).
        let again = app.buttons["offline.try-again"]
        if again.exists, again.isEnabled { again.tap() }
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30), "readable again: the app")
        leave()
        // Unavailable: its own words.
        relaunch(["-HQDebugRestoreFailure", "keychain-unavailable", "-HQDebugRestoreFailureCount", "1"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15))
        XCTAssertEqual(el("offline.title").label, "Can’t Open Your Saved Sign-In")
        shot("offline-reason-keychain-unavailable")
        // It keeps trying by itself.
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30), "the automatic retry opens the app")
        leave()
        // Unreadable: Sign In Again, asked first, then the form with what is known filled in.
        relaunch(["-HQDebugRestoreFailure", "keychain-unreadable"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15))
        XCTAssertEqual(el("offline.title").label, "Can’t Read Your Saved Sign-In")
        XCTAssertTrue(app.buttons["offline.sign-in-again"].exists, "Sign In Again")
        shot("offline-reason-keychain-unreadable")
        tapBetweenAttempts("offline.sign-in-again")
        let alert = app.alerts["Sign In Again?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "asked first")
        shot("offline-sign-in-again-confirm")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(el("offline.title").exists, "Cancel stays")
        tapBetweenAttempts("offline.sign-in-again")
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Sign In Again"].tap()
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8), "the sign-in form")
        XCTAssertEqual(address.value as? String, account.url, "the last gateway's address is filled in")
    }

    // MARK: O8. The launch screen's own states: the long wait, the storage sentence

    @MainActor func testO08_LaunchScreenStates() throws {
        freshApp()
        leave()
        // Held on the launch screen (DEBUG): the icon alone, then the spinner, the caption at 4 s, the cause and the
        // buttons at 12 s.
        relaunch(["-HQDebugResetCaches", "YES", "-HQDebugLaunchHold", "40"])
        XCTAssertTrue(el("launch.icon").waitForExistence(timeout: 5), "the launch screen with the icon")
        XCTAssertFalse(app.buttons["launch.try-again"].exists, "no buttons yet")
        shot("launch-icon-light")
        XCTAssertTrue(waitUntil(timeout: 8) { self.el("launch.caption").exists && self.el("launch.caption").label == "Connecting to Hermes…" },
                      "the caption after 4 s")
        shot("launch-caption-light")
        XCTAssertTrue(waitUntil(timeout: 14) { self.el("launch.caption").label == "Still connecting. Check that the computer running Hermes is on and awake." },
                      "the usual cause at 12 s: \(el("launch.caption").label)")
        XCTAssertTrue(app.buttons["launch.try-again"].exists && app.buttons["launch.different-gateway"].exists, "and the two buttons")
        shot("launch-stalled-light")
        app.buttons["launch.try-again"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !self.app.buttons["launch.try-again"].exists }, "Try Again starts over: the buttons leave")
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 25), "and the start that was held goes through to the app")
        // The storage sentence: startup stops with the reason, Try Again and nothing lost.
        app.terminate()
        relaunch(["-HQDebugStorageFailure", "YES"])
        XCTAssertTrue(waitUntil(timeout: 10) { self.el("launch.caption").exists && self.el("launch.caption").label == Self.storageSentence },
                      "the storage sentence: \(el("launch.caption").label)")
        XCTAssertTrue(app.buttons["launch.try-again"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the app is not shown over storage it cannot use")
        shot("launch-storage-light")
        // Without the failure the same phone starts.
        app.terminate()
        relaunch()
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 20), "the app")
    }

    // MARK: O9. The Bots list: can't load, stale, slow

    @MainActor func testO09_BotsListFailedAndStaleStates() throws {
        freshApp()
        leave()
        // Nothing saved and the roster read failing with a raw dump: "Couldn’t Load Bots" in words, Try Again.
        try ctl.control("/__fixture/fail", ["rpc": "profiles.list", "code": -32000, "count": 500, "message": "Traceback (most recent call last) 0x7ff0 RPCError -32000"])
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30), "the app shows (the gateway is connected)")
        XCTAssertTrue(waitUntil(timeout: 20) { self.app.staticTexts["Couldn’t Load Bots"].exists }, "Couldn’t Load Bots")
        // Stress round 1: the gateway answered, with an error of its own; the app says that in its own sentence.
        XCTAssertTrue(app.staticTexts["Your gateway couldn’t load your bots."].exists, "the reason in words, never the dump")
        XCTAssertFalse(anyLabel(containing: "Traceback") || anyLabel(containing: "-32000") || anyLabel(containing: "RPCError"), "no raw code")
        XCTAssertTrue(app.buttons["Try Again"].exists)
        shot("bots-cant-load-light")
        try ctl.control("/__fixture/reset", ["seed": false])
        app.buttons["Try Again"].tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.botShown("default") }, "Try Again loads the list")
        XCTAssertFalse(app.staticTexts["Couldn’t Load Bots"].exists)
        // A saved list and a failing refresh: the stale card over the last good list.
        leave()
        try ctl.control("/__fixture/fail", ["rpc": "profiles.list", "code": -32000, "count": 500])
        relaunch()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botShown("default") }, "the saved list")
        XCTAssertTrue(el("bots.notice.text").waitForExistence(timeout: 30), "the stale card")
        let words = el("bots.notice.text").label
        XCTAssertTrue(words.hasPrefix("Can’t refresh bots. Showing the list from "), words)
        XCTAssertTrue(botShown("default"), "the last good list stays under it")
        shot("bots-stale-light")
        try ctl.control("/__fixture/reset", ["seed": false])
        el("bots.notice.retry").tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !self.el("bots.notice.text").exists }, "a good read removes the card")
        XCTAssertTrue(botShown("default"))
    }

    @MainActor func testO10_BotsListSlowCard() throws {
        freshApp()
        leave()
        try ctl.control("/__fixture/delay", ["rpc": ["profiles.list": 40]])
        relaunch(["-HQDebugResetCaches", "YES"])
        // Connected, the first list still out: the launch screen gives it 5 s, then the app shows with its skeleton.
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 25), "the app with its own loading state")
        XCTAssertFalse(botShown("default"), "no rows yet")
        XCTAssertFalse(el("bots.notice.text").exists, "no slow card before 15 s")
        // The card and its words in one look (a slow run must not read the label after the list has arrived).
        var words: String?
        XCTAssertTrue(waitUntil(timeout: 25) { words = self.labelNow("bots.notice.text"); return words != nil }, "the slow card after 15 s of skeleton")
        XCTAssertEqual(words, "Still loading your bots… Your gateway is taking longer than usual.")
        shot("bots-slow-light")
        XCTAssertTrue(waitUntil(timeout: 50) { self.botShown("default") }, "the list arrives")
        XCTAssertFalse(el("bots.notice.text").exists, "and the card leaves")
    }

    // MARK: O11. The reconnect notice: nothing for a blip, a sentence for an outage, gone on ready

    @MainActor func testO11_ReconnectNotice() throws {
        freshApp()
        Thread.sleep(forTimeInterval: 3)
        // A dropped socket that is straight back: no notice at any point (the app's own record of what it put up).
        let before = notices().count
        try ctl.control("/__fixture/drop", [:])
        Thread.sleep(forTimeInterval: 8)
        XCTAssertEqual(notices().count, before, "a blip shows no notice")
        XCTAssertFalse(bannerShowing(), "nothing on screen")
        // An outage: the notice after the 4 s hold, a known sentence, under the status bar. The test looks rarely
        // here: every look makes the app describe its whole screen on the main thread, which on a loaded Mac takes
        // seconds and would hold back the very timer being measured.
        let down = Date().timeIntervalSince1970
        setMode("status", ["status": 503])
        Thread.sleep(forTimeInterval: 8)
        if bannerShowing() { shot("banner-reconnecting-light") }
        XCTAssertTrue(app.staticTexts["Reconnecting…"].exists || app.staticTexts["Offline"].exists, "the header says the link is down")
        XCTAssertTrue(app.collectionViews["bots.list"].isHittable, "the app stays usable under it")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(waitUntil(timeout: 30, every: 4) { self.notices().count > before }, "the notice shows")
        let first = try XCTUnwrap(notices().log.first { $0.start >= down - 0.5 }, "the outage's first sentence is on record")
        XCTAssertGreaterThanOrEqual(first.start - down, 3.5, "not before the 4 s hold")
        XCTAssertLessThanOrEqual(first.start - down, 20, "and not long after it: \(first.start - down) s")
        XCTAssertTrue(Self.bannerSentences.contains(first.sentence), "a known sentence: \(first.sentence)")
        XCTAssertGreaterThan(first.frame.minY, 40, "clear of the status bar and the island: \(first.frame)")
        XCTAssertLessThan(first.frame.maxY, 220, "at the top: \(first.frame)")
        XCTAssertGreaterThanOrEqual(first.frame.height, 44, "a comfortable capsule: \(first.frame)")
        // (review) The notice is a moment, the header is the lasting sign: each sentence leaves by itself after 6 s
        // (one with something new to say, the cause, may follow), while the gateway is still down and the header
        // still says so.
        XCTAssertTrue(waitUntil(timeout: 48, every: 6) {
            let log = self.notices().log.filter { $0.start >= down - 0.5 }
            return !log.isEmpty && log.allSatisfy { $0.stayed != nil }
        }, "the notice leaves by itself during the outage")
        XCTAssertFalse(bannerShowing(), "nothing on screen")
        XCTAssertTrue(app.staticTexts["Reconnecting…"].exists || app.staticTexts["Offline"].exists, "the header still says the link is down")
        shot("banner-gone-header-stays-light")
        Thread.sleep(forTimeInterval: 10)
        let outage = notices().log.filter { $0.start >= down - 0.5 }
        note("the reconnect notice in one outage: " + outage.map { "\(String(format: "%.1f", $0.start - down)) s for \(String(format: "%.1f", $0.stayed ?? -1)) s “\($0.sentence)”" }.joined(separator: "; "))
        XCTAssertFalse(bannerShowing(), "it does not come back with nothing new to say")
        XCTAssertLessThanOrEqual(outage.count, 3, "a sentence, perhaps its cause, perhaps “keeps trying”; never a stream: \(outage.map(\.sentence))")
        XCTAssertEqual(Set(outage.map(\.sentence)).count, outage.count, "no sentence twice in one outage")
        for one in outage {
            let stayed = try XCTUnwrap(one.stayed, "every sentence has left")
            XCTAssertLessThanOrEqual(stayed, 7.5, "no sentence stays longer than about 6 s: \(stayed) s “\(one.sentence)”")
        }
        XCTAssertGreaterThanOrEqual(outage.last?.stayed ?? 0, 5, "the last sentence had its 6 s: \(outage.last?.stayed ?? 0)")
        XCTAssertTrue(app.staticTexts["Reconnecting…"].exists || app.staticTexts["Offline"].exists, "the header still says so")
        setMode("up")
        XCTAssertTrue(waitUntil(timeout: 60) { !self.app.staticTexts["Reconnecting…"].exists && !self.app.staticTexts["Offline"].exists }, "the header is quiet once connected")
        XCTAssertFalse(bannerShowing(), "no notice")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert for an outage")
    }

    // MARK: O21. The notice takes no touches: the bar's buttons work through it, a swipe up puts it away

    @MainActor func testO21_TheNoticeTakesNoTouches() throws {
        // The notice kept up for 60 s here (it leaves after 6 s otherwise), so every tap below lands under it.
        freshApp(["-HQDebugNoticeStay", "240"])   // long enough for three taps on a loaded Mac (a run took over 60 s)
        Thread.sleep(forTimeInterval: 3)
        setMode("status", ["status": 503])
        XCTAssertTrue(waitUntil(timeout: 30) { self.bannerShowing() }, "the notice shows")
        let notice = el("connection.banner").frame
        let centre = CGVector(dx: 0.5, dy: 0.5)
        // The Bots bar's + (a menu) under the notice.
        let compose = app.buttons["bots.compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 5), "the Bots bar's +")
        XCTAssertTrue(notice.intersects(compose.frame), "the notice lies over the +: \(notice) \(compose.frame)")
        compose.coordinate(withNormalizedOffset: centre).tap()
        XCTAssertTrue(app.buttons["New Bot"].waitForExistence(timeout: 5), "the + menu opens through the notice")
        shot("banner-over-bar-compose-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.buttons["New Bot"].exists }, "the menu closes")
        // Back in an open chat under the notice.
        openBot("deploys")
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back")
        XCTAssertTrue(bannerShowing(), "the notice is over the chat too")
        XCTAssertTrue(el("connection.banner").frame.intersects(back.frame), "and over Back: \(el("connection.banner").frame) \(back.frame)")
        shot("banner-over-chat-bar")
        back.coordinate(withNormalizedOffset: centre).tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.app.tables["chat.table"].exists && self.botShown("default") }, "Back works through the notice")
        // Search under the notice.
        let search = app.buttons["bots.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the search button")
        XCTAssertTrue(bannerShowing(), "the notice is still up")
        XCTAssertTrue(el("connection.banner").frame.intersects(search.frame), "over the search button")
        search.coordinate(withNormalizedOffset: centre).tap()
        XCTAssertTrue(el("bots.search.field").waitForExistence(timeout: 5), "Search opens through the notice")
        XCTAssertTrue(bannerShowing(), "the notice was up throughout")
        // A swipe up on the capsule puts it away for this outage; the header keeps saying the link is down.
        let capsule = el("connection.banner")
        let from = capsule.coordinate(withNormalizedOffset: centre)
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -70)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.bannerShowing() }, "a swipe up puts the notice away")
        Thread.sleep(forTimeInterval: 6)
        XCTAssertFalse(bannerShowing(), "for the rest of this outage")
        setMode("up")
        XCTAssertTrue(waitUntil(timeout: 60) { !self.app.staticTexts["Reconnecting…"].exists && !self.app.staticTexts["Offline"].exists }, "connected again")
    }

    // MARK: O12. The gateway ends the session: told first, drafts kept, sign in again when ready

    @MainActor func testO12_SignInAgainNotice() throws {
        freshApp()
        openBot("deploys")
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("half a thought")
        try ctl.control("/__fixture/revoke", [:])
        let alert = app.alerts["Sign In Again"]
        XCTAssertTrue(alert.waitForExistence(timeout: 40), "told that the session ended")
        // Audit 06-14: the alert names the gateway that ended the session.
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", " ended this iPhone’s session. Sign in again to reconnect; your drafts are kept.")).firstMatch.exists)
        shot("alert-sign-in-again-light")
        alert.buttons["Not Now"].tap()
        XCTAssertTrue(app.tables["chat.table"].exists, "put off: the chat stays")
        XCTAssertFalse(app.textFields["sign-in-address"].exists, "no sign-in form yet")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Signed Out"].waitForExistence(timeout: 8), "the header says Signed Out")
        XCTAssertFalse(bannerShowing(), "no reconnect notice for a session that ended")
        shot("header-signed-out-light")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(app.alerts.count, 0, "it does not nag while the app stays open")
        // Said again when the app is opened again.
        goHome()
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "said again on return")
        XCTAssertEqual(app.alerts.count, 1, "once")
        alert.buttons["Sign In Again"].tap()
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the sign-in form")
        XCTAssertEqual(address.value as? String, account.url, "the address is filled in")
        shot("sign-in-after-session-ended")
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10), "the password fields show for the address")
        XCTAssertEqual(app.textFields["sign-in-username"].value as? String, account.username, "and the username")
        password.tap()
        password.typeText(account.password)
        app.buttons["sign-in-password-button"].tap()
        dismissSavePassword()
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30), "signed in again")
        dismissAlerts()
        openBot("deploys")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.app.textViews["composer.text"].value as? String) == "half a thought" },
                      "the draft is still there: \(String(describing: app.textViews["composer.text"].value))")
    }

    // MARK: O13. A message too large to receive: said once, the app stays usable

    @MainActor func testO13_MessageTooLargeNotice() throws {
        freshApp()
        Thread.sleep(forTimeInterval: 3)
        try ctl.control("/__fixture/oversize", [:])
        let alert = app.alerts["Message too large"]
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "told once")
        let words = "Your gateway sent a message larger than 64 MB, which Hermes HQ on iPhone can’t receive. It was skipped; open this chat on the computer running Hermes to see it."
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label == %@", words)).firstMatch.exists, "the sentence")
        shot("alert-too-large-light")
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 6), "once, not again")
        // Back on a working link: lists load and a chat opens.
        XCTAssertTrue(waitUntil(timeout: 40) { !self.app.staticTexts["Reconnecting…"].exists && !self.bannerShowing() }, "connected again")
        openBot("research")
        XCTAssertTrue(app.textViews["composer.text"].exists, "the app is usable")
    }

    // MARK: O14. A moment inside the app is not a return; a real return refreshes once

    @MainActor func testO14_TabSwitchesAreNotReturns() throws {
        freshApp()
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.cells["session-row-s-001"].waitForExistence(timeout: 15), "the sessions list")
        Thread.sleep(forTimeInterval: 6)
        let reads = { self.count("probes") + self.count("full") }
        let before = reads()
        let ticketsBefore = count("tickets")
        for _ in 0..<4 {
            app.tabBars.buttons["Bots"].tap()
            Thread.sleep(forTimeInterval: 0.5)
            app.tabBars.buttons["Sessions"].tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(reads(), before, "tab switches read nothing again")
        // A real return. DECISION (report): with the socket up and change events flowing, the Sessions list has missed
        // nothing while away and reads nothing on a return; what it owes is one look when a change arrived while the
        // app was away. So a chat changes during the trip, and the return makes exactly one read.
        let activations = el("debug.activations")
        let returnsBefore = (activations.value as? String) ?? ""
        goHome()
        Thread.sleep(forTimeInterval: 1)
        try ctl.control("/__fixture/touch", ["session_id": "s-003"])
        try ctl.control("/__fixture/broadcast", ["type": "sessions.changed"])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(reads(), before, "nothing is read while the app is away")
        app.activate()
        XCTAssertTrue(app.cells["session-row-s-001"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 15) { reads() - before >= 1 }, "the return looks at the sessions list")
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(reads() - before, 1, "one look at the sessions list on a return, and only one")
        XCTAssertTrue(returnsBefore.contains("returns=1") && ((activations.value as? String) ?? "").contains("returns=2"),
                      "the trip was one return: \(returnsBefore) → \(activations.value ?? "")")
        XCTAssertEqual(count("tickets"), ticketsBefore, "the socket stayed up over a short trip away")
        XCTAssertFalse(bannerShowing(), "no notice")
    }

    // MARK: O22. A moment in Notification Center or Control Center is not a return (§6.8)

    @MainActor func testO22_TheShadeAndControlCenterAreNotReturns() throws {
        freshApp()
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.cells["session-row-s-001"].waitForExistence(timeout: 15), "the sessions list")
        Thread.sleep(forTimeInterval: 6)
        let activations = el("debug.activations")
        XCTAssertTrue(activations.waitForExistence(timeout: 5), "the activation counter (DEBUG)")
        let moments = { () -> Int in
            let value = (activations.value as? String) ?? ""
            return Int(value.components(separatedBy: "moments=").last ?? "") ?? -1
        }
        let returns = { () -> Int in
            let value = (activations.value as? String) ?? ""
            return Int(value.components(separatedBy: "returns=").last?.components(separatedBy: " ").first ?? "") ?? -1
        }
        XCTAssertEqual(returns(), 1, "the launch is the one return so far: \(activations.value ?? "")")
        let reads = { self.count("probes") + self.count("full") }
        let before = reads(), ticketsBefore = count("tickets"), rosterBefore = rpcCount("profiles.list"), momentsBefore = moments()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Control Center: pulled down from the top right corner, closed with a tap on its empty part (a tap can never
        // send the app Home, as a swipe up from the bottom edge does once Control Center has already closed).
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.0))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        Thread.sleep(forTimeInterval: 2.5)
        shot("moment-control-center")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(waitUntil(timeout: 12) { moments() > momentsBefore || returns() > 1 }, "the app was inactive for a moment and is active again: \(activations.value ?? "")")
        note("after Control Center: \(activations.value ?? "")")
        XCTAssertTrue(app.cells["session-row-s-001"].waitForExistence(timeout: 10), "back in the app")
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(returns(), 1, "Control Center was not a return: \(activations.value ?? "")")
        XCTAssertEqual(moments(), momentsBefore + 1, "it was one moment: \(activations.value ?? "")")
        XCTAssertEqual(reads() - before, 0, "no list was read again")
        XCTAssertEqual(rosterReadsOffThePoll(after: rosterBefore), 0, "the roster neither (its own 30 s poll aside): \(rpcCount("profiles.list") - rosterBefore) read")
        XCTAssertEqual(count("tickets"), ticketsBefore, "no socket was dialled")
        XCTAssertFalse(bannerShowing(), "no notice")
        // Notification Center: pulled down from the top edge, pushed back up. What the system does with the app under
        // it is the system's choice: seen on this simulator both ways, the app merely inactive, and the app sent to the
        // background once the sheet covers the screen. DECISION (spec §6.8): the first is a moment and reads nothing;
        // the second is a real background, so a return, and is held to a return's budget (one look, no new socket).
        let afterControlCenter = moments()
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.0))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8)))
        Thread.sleep(forTimeInterval: 2.5)
        shot("moment-notification-center")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(waitUntil(timeout: 12) { moments() > afterControlCenter || returns() > 1 }, "active again after Notification Center: \(activations.value ?? "")")
        XCTAssertTrue(app.cells["session-row-s-001"].waitForExistence(timeout: 10), "back in the app")
        Thread.sleep(forTimeInterval: 6)
        note("after Notification Center: \(activations.value ?? "") (\(returns() > 1 ? "the system sent the app to the background: a return" : "a moment, not a return"))")
        if returns() == 1 {
            XCTAssertEqual(reads() - before, 0, "a moment reads no list")
            XCTAssertEqual(rosterReadsOffThePoll(after: rosterBefore), 0, "nor the roster (its own poll aside)")
        } else {
            XCTAssertEqual(returns(), 2, "one return, not several: \(activations.value ?? "")")
            XCTAssertLessThanOrEqual(reads() - before, 1, "a return looks at the list once at most")
            XCTAssertLessThanOrEqual(rosterReadsOffThePoll(after: rosterBefore), 1, "and at the roster once at most (its own poll aside)")
        }
        XCTAssertEqual(count("tickets"), ticketsBefore, "no socket was dialled")
        XCTAssertFalse(bannerShowing(), "no notice")
    }

    // MARK: O15. A reply cut off by a gateway restart is completed from the saved chat

    @MainActor func testO15_TailRecheckCompletesACutReply() throws {
        freshApp()
        app.tabBars.buttons["Sessions"].tap()
        let row = app.cells["session-row-s-001"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
        Thread.sleep(forTimeInterval: 2)
        // 600 characters, the gateway restarting after 200 of them; the whole reply is saved 3 s later.
        try ctl.control("/__fixture/turn", ["session_id": "s-001", "chars": 600, "drop_at": 200, "save_after": 3])
        let readsBefore = messageReads("s-001")
        let field = app.textViews["composer.text"]
        field.tap()
        field.typeText("Tell me more")
        tapSend()
        let whole = waitUntil(timeout: 60) { self.longestChatText() >= 590 }
        if !whole {
            shot("chat-cut-reply-not-whole")
            let calls = ((ledger()["rpc"] as? [[String: Any]]) ?? []).suffix(12).compactMap { $0["method"] as? String }
            note("cut reply not whole; the last calls were: \(calls.joined(separator: ", "))")
        }
        XCTAssertTrue(whole, "the whole reply is on show: \(longestChatText()) characters")
        XCTAssertFalse(app.alerts.firstMatch.exists, "quietly")
        // What the rules allow for a reply saved 3 s after the cut (spec §6.3, §6.5): the reconnect's own tail read, the
        // recheck at 2 s (not saved yet) and at 5 s (saved: it covers), the one resume read that puts the saved reply on
        // show, and at most one one-row look for the `sessions.changed` that the save sends. Four reads of the tail
        // and one probe at most; a recheck that lands after the save needs one fewer.
        let details = { Array(self.messageReadDetails("s-001").dropFirst(readsBefore)).filter { !Self.isRowPreview($0) } }
        let tails = { details().filter { !$0.hasSuffix("limit 1") }.count }
        let probes = { details().filter { $0.hasSuffix("limit 1") }.count }
        note("tail reads after the cut reply, each with its limit: \(details().joined(separator: ", "))")
        XCTAssertGreaterThanOrEqual(tails(), 1, "the saved chat was read")
        XCTAssertLessThanOrEqual(tails(), 4, "a few looks, not a loop: \(details())")
        XCTAssertLessThanOrEqual(probes(), 1, "one one-row look at most: \(details())")
        note("tail reads after the cut reply: \(tails()) and \(probes()) one-row look")
        shot("chat-after-cut-reply")
        // And it stays whole: no shorter text replaces it later, and the reading has stopped.
        Thread.sleep(forTimeInterval: 4)
        let settled = details().count
        Thread.sleep(forTimeInterval: 8)
        XCTAssertGreaterThanOrEqual(longestChatText(), 590)
        XCTAssertEqual(details().count, settled, "no more reads once it is whole: \(details())")
        XCTAssertLessThanOrEqual(tails(), 4, "four reads of the tail at most: \(details())")
        XCTAssertLessThanOrEqual(probes(), 1, "one one-row look at most: \(details())")
    }

    // MARK: O16. Work that ended while the socket was away is checked once on the reconnect

    @MainActor func testO16_StaleWorkIsCheckedOnce() throws {
        // The background-process claim is seeded for the test (its real source is the composer stream's row L461). The
        // process runs on the gateway before the app starts, so the check at the first ready keeps the claim.
        try ctl.control("/__fixture/work", ["session_id": "s-002", "processes": ["proc-1"]])
        // A gateway without `subagent.list` (an older Hermes): the open chat's own list poll, which would also notice
        // the missing child within a few seconds, is out of the picture, so what clears the claim here is the stale
        // work check and nothing else.
        try ctl.control("/__fixture/fail", ["rpc": "subagent.list", "code": -32601, "count": 500, "message": "Method not found"])
        freshApp(["-HQDebugProcessClaim", "s-002:proc-1"])
        app.tabBars.buttons["Sessions"].tap()
        let row = app.cells["session-row-s-002"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        try ctl.control("/__fixture/work", ["session_id": "s-002", "subagents": ["sub-1"]])
        Thread.sleep(forTimeInterval: 3)
        shot("chat-work-running")
        // The work ends with no event (the socket "missed" it), then the socket drops and comes back.
        try ctl.control("/__fixture/work/end", ["subagents": ["sub-1"], "processes": ["proc-1"]])
        let before = rpcCount("delegation.status"), agentsBefore = rpcCount("agents.list")
        let opensBefore = socketOpens().count
        try ctl.control("/__fixture/drop", [:])
        XCTAssertTrue(waitUntil(timeout: 30) { self.rpcCount("delegation.status") > before },
                      "the reconnect asks what is still running (sockets opened since: \(socketOpens().count - opensBefore), "
                      + "agents.list \(rpcCount("agents.list") - agentsBefore), capsule on show: \(anyLabel(containing: "subagent")))")
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(rpcCount("delegation.status") - before, 1, "once")
        XCTAssertEqual(rpcCount("agents.list") - agentsBefore, 1, "the claimed process is asked about once")
        note("stale work check after a reconnect: delegation.status \(rpcCount("delegation.status") - before), agents.list \(rpcCount("agents.list") - agentsBefore)")
        XCTAssertFalse(bannerShowing())
        XCTAssertTrue(waitUntil(timeout: 10) { !self.anyLabel(containing: "1 helper") }, "the claim the gateway no longer has is gone from the chat")
        shot("chat-work-cleared")
    }

    // MARK: O19. Caches on the first frame: chat tails read ahead in order, Skills warmed once, Jobs from its saved list

    @MainActor func testO19_CachesOnTheFirstFrame() throws {
        freshApp()
        // Chat tails are read ahead a moment after the list has rows: the pinned bot's chat first, bots before Sessions rows.
        XCTAssertTrue(waitUntil(timeout: 20) { self.tailReads().count >= 5 }, "chat tails are read ahead: \(tailReads())")
        Thread.sleep(forTimeInterval: 4)
        let tails = tailReads()
        note("chat tails read ahead, in order: \(tails.joined(separator: " "))")
        XCTAssertEqual(tails.first, Self.botChat("default"), "the pinned bot's chat is read first")
        let firstSessionRow = tails.firstIndex { $0.hasPrefix("s-") } ?? tails.count
        XCTAssertEqual(Set(tails.prefix(firstSessionRow)), Set(["default", "research", "deploys", "finance", "garden"].map(Self.botChat)),
                       "every bot's chat before any Sessions row")
        XCTAssertEqual(Set(tails).count, tails.count, "each chat once")
        XCTAssertLessThanOrEqual(tails.count, 8, "a first pass of at most eight chats")
        // The Skills list is read ahead once, without being opened.
        XCTAssertTrue(waitUntil(timeout: 15) { self.restCount("/api/skills") >= 1 }, "the skills list is read ahead")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(restCount("/api/skills"), 1, "once")
        // With the gateway now slow to answer for skills, the page still opens with its rows (the read-ahead copy).
        try ctl.control("/__fixture/delay", ["rest": ["/api/skills": 25]])
        app.tabBars.buttons["More"].tap()
        let settings = app.cells["more-row-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["settings.gateway-card"].waitForExistence(timeout: 10), "Settings")
        // The Capabilities row sits below the gateway's settings, and the list builds its rows as they come into view.
        let skills = app.buttons["settings.capabilities"]
        let limit = app.windows.firstMatch.frame.height - 150
        for _ in 0..<14 where !(skills.exists && skills.isHittable && skills.frame.maxY < limit) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(skills.exists && skills.isHittable, "the Capabilities row")
        skills.tap()
        XCTAssertTrue(el("capabilities.row.skills").waitForExistence(timeout: 5), "Capabilities' rows")   // [cap-pages]
        el("capabilities.row.skills").tap()
        XCTAssertTrue(el("skill-switch-garden-notes").waitForExistence(timeout: 4), "the skills are there on arrival, from the read-ahead copy")
        shot("skills-from-warm-up")
        try ctl.control("/__fixture/delay", ["rest": ["/api/skills": 0]])

        // Jobs: its rows come from the saved list on the next launch, with the gateway down.
        app.tabBars.buttons["Jobs"].tap()
        let job = el("job-row-default|job-1")
        XCTAssertTrue(job.waitForExistence(timeout: 15), "the Jobs list")
        Thread.sleep(forTimeInterval: 1)
        leave()
        setMode("status", ["status": 503])
        relaunch()
        XCTAssertTrue(waitUntil(timeout: 8) { self.app.tabBars.buttons["Jobs"].exists }, "the app, not the offline screen")
        app.tabBars.buttons["Jobs"].tap()
        XCTAssertTrue(job.waitForExistence(timeout: 3), "the saved Jobs rows are on show while the gateway is down")
        XCTAssertFalse(el("offline").exists)
        shot("jobs-from-cache-gateway-down")
        setMode("up")
    }

    // MARK: O20. A storage failure cancels a gateway switch and says why (§3.4 check 3)

    @MainActor func testO20_AStorageFailureCancelsAGatewaySwitch() throws {
        try XCTSkipIf(other == nil, "needs the second stand-in")
        freshApp()
        leave()
        // A second saved gateway, signed in from the offline screen's sheet (as O06 does).
        setMode("status", ["status": 503])
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(app.buttons["offline.different-gateway"].waitForExistence(timeout: 15), "the offline screen")
        app.buttons["offline.different-gateway"].tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 8))
        typeSignIn(other)
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30), "signed in to the other gateway")
        dismissAlerts()
        XCTAssertTrue(waitUntil(timeout: 20) { self.anyLabel(containing: "B Hermes") }, "its bots are on show")
        setMode("up")
        leave()
        // The phone's storage refuses the first gateway's folders when switching back.
        relaunch(["-HQDebugStorageFailure", "switch"])
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30), "the app starts: the launch check passes")
        dismissAlerts()
        XCTAssertTrue(waitUntil(timeout: 20) { self.anyLabel(containing: "B Hermes") }, "on the other gateway")
        let first = String(account.url.split(separator: "/").last ?? "")
        let switcher = app.buttons["gateway-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 8), "the title is the gateway switcher with two gateways saved")
        switcher.tap()
        let item = app.buttons["gateway-menu-\(first)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8), "the menu lists the first gateway (\(first))")
        item.tap()
        let alert = app.alerts["Couldn’t Switch to \(first)"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "the switch is refused with an alert")
        let sentence = alert.staticTexts.matching(NSPredicate(format: "label == %@", Self.storageSentence)).firstMatch
        XCTAssertTrue(sentence.exists, "the storage sentence, whole")
        XCTAssertTrue(alert.buttons["Try Again"].exists && alert.buttons["OK"].exists)
        shot("alert-storage-switch-light")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.anyLabel(containing: "B Hermes") }, "still on the other gateway")
        XCTAssertFalse(el("offline").exists || el("launch").exists, "the screen on show is not replaced")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.bannerShowing() }, "and its connection is untouched")
    }

    // MARK: O17. The offline screen at the largest text size

    @MainActor func testO17_OfflineScreenAtTheLargestTextSize() throws {
        freshApp()
        leave()
        setMode("status", ["status": 503])
        relaunch(["-HQDebugResetCaches", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15), "the offline screen")
        shot("offline-screen-ax5-top")
        let retry = app.buttons["offline.try-again"]
        for _ in 0..<6 where !retry.isHittable { app.swipeUp() }
        XCTAssertTrue(retry.isHittable, "Try Again can be reached by scrolling")
        let other = app.buttons["offline.different-gateway"]
        for _ in 0..<6 where !other.isHittable { app.swipeUp() }
        XCTAssertTrue(other.isHittable, "and the other button")
        shot("offline-screen-ax5-buttons")
        XCTAssertGreaterThanOrEqual(el("offline.card").frame.height, 60, "the card grows with its text")
    }

    // MARK: O24. The launch screen at the largest text size: the whole sentence and both buttons can be reached

    @MainActor func testO24_LaunchScreenAtTheLargestTextSize() throws {
        let big = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        freshApp()
        leave()
        relaunch(["-HQDebugResetCaches", "YES", "-HQDebugLaunchHold", "40"] + big)
        XCTAssertTrue(waitUntil(timeout: 25) { self.app.buttons["launch.try-again"].exists }, "stalled, with its buttons")
        XCTAssertEqual(el("launch.caption").label, "Still connecting. Check that the computer running Hermes is on and awake.")
        // At rest the icon is where the system launch screen drew it: the middle of the window.
        // (Once there are words the icon is decoration to VoiceOver, so the caption is measured: its top is 118 pt
        // under the icon's centre.)
        let window = app.frame, rest = el("launch.caption").frame.minY
        XCTAssertEqual(rest, window.midY + 118, accuracy: 1, "at rest the caption is 118 pt under the centre, the icon at the centre")
        shot("launch-stalled-ax5-top")
        // One swipe from the middle of the screen (the icon, not the words) scrolls it.
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 4) { self.el("launch.caption").frame.minY < rest - 40 },
                      "the screen scrolls from a touch anywhere: \(el("launch.caption").frame.minY) from \(rest)")
        let retry = app.buttons["launch.try-again"], other = app.buttons["launch.different-gateway"]
        for _ in 0..<6 where !other.isHittable { app.swipeUp() }
        XCTAssertTrue(other.isHittable, "Change Address or Sign In can be reached")
        XCTAssertLessThanOrEqual(other.frame.maxY, window.maxY, "whole, above the bottom edge")
        shot("launch-stalled-ax5-buttons")
        for _ in 0..<6 where !retry.isHittable { app.swipeDown() }
        XCTAssertTrue(retry.isHittable, "Try Again can be reached")
        XCTAssertGreaterThanOrEqual(retry.frame.minY, 0)
        // The storage sentence: read whole from top to bottom, Try Again under it.
        app.terminate(); _ = app.wait(for: .notRunning, timeout: 20)
        relaunch(["-HQDebugStorageFailure", "YES"] + big)
        XCTAssertTrue(waitUntil(timeout: 20) { self.el("launch.caption").exists && self.el("launch.caption").label == Self.storageSentence }, "the storage sentence")
        shot("launch-storage-ax5-top")
        let caption = el("launch.caption")
        XCTAssertGreaterThan(caption.frame.maxY, window.maxY, "it is longer than the screen at this size")
        let again = app.buttons["launch.try-again"]
        XCTAssertTrue(again.exists)
        for _ in 0..<12 where !again.isHittable { app.swipeUp() }
        XCTAssertTrue(again.isHittable, "Try Again under the sentence can be reached")
        XCTAssertLessThanOrEqual(caption.frame.maxY, again.frame.minY, "the sentence ends above the button: nothing is cut")
        XCTAssertLessThanOrEqual(again.frame.maxY, window.maxY)
        shot("launch-storage-ax5-end")
        // And at the default size nothing scrolls: the icon stays put.
        app.terminate(); _ = app.wait(for: .notRunning, timeout: 20)
        relaunch(["-HQDebugResetCaches", "YES", "-HQDebugLaunchHold", "40"])
        XCTAssertTrue(waitUntil(timeout: 25) { self.app.buttons["launch.try-again"].exists }, "stalled at the default size")
        XCTAssertEqual(el("launch.caption").frame.minY, app.frame.midY + 118, accuracy: 1, "the caption 118 pt under the centre")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(el("launch.caption").frame.minY, app.frame.midY + 118, accuracy: 1, "nothing to scroll: nothing moves")
        XCTAssertTrue(app.buttons["launch.try-again"].isHittable && app.buttons["launch.different-gateway"].isHittable)
    }

    // MARK: O25. A session that ends under another alert left up for half a minute is still said

    @MainActor func testO25_SignInAgainWaitsOutAnotherAlert() throws {
        freshApp()
        Thread.sleep(forTimeInterval: 3)
        try ctl.control("/__fixture/oversize", [:])
        let large = app.alerts["Message too large"]
        XCTAssertTrue(large.waitForExistence(timeout: 90), "the too-large notice")
        try ctl.control("/__fixture/revoke", [:])
        // Longer than the 14 s after which the held notice used to be dropped.
        Thread.sleep(forTimeInterval: 30)
        XCTAssertEqual(app.alerts.count, 1, "one alert at a time")
        XCTAssertFalse(app.textFields["sign-in-address"].exists, "the app is not replaced under the alert")
        large.buttons["OK"].tap()
        let signIn = app.alerts["Sign In Again"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 20), "the held notice shows once the other alert is answered")
        XCTAssertEqual(app.alerts.count, 1, "once")
        shot("alert-sign-in-again-after-held")
        signIn.buttons["Not Now"].tap()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(app.alerts.count, 0, "answered: it does not come back while the app stays open")
        // Said again on a return, also when that return finds the app unable to show it at once.
        goHome()
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "said again on return")
    }

    // MARK: O26. A gateway that never answers: the way to another gateway stays open while a dial runs

    @MainActor func testO26_DifferentGatewayStaysOpenDuringADial() throws {
        freshApp()
        leave()
        try ctl.control("/__fixture/reset", ["seed": false])
        setMode("blackhole")
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 60), "the offline screen")
        let retry = app.buttons["offline.try-again"], other = app.buttons["offline.different-gateway"]
        var disabledRetry = 0, disabledOther = 0, samples = 0
        let end = Date().addingTimeInterval(45)
        while Date() < end {
            samples += 1
            if !retry.isEnabled { disabledRetry += 1 }
            if !other.isEnabled { disabledOther += 1 }
            Thread.sleep(forTimeInterval: 0.25)
        }
        note("black hole 45 s: Try Again off in \(disabledRetry) of \(samples) looks, the other button off in \(disabledOther)")
        XCTAssertGreaterThan(disabledRetry, 0, "a dial into a silent host was running at some look (Try Again is off then)")
        XCTAssertEqual(disabledOther, 0, "Change Address or Sign In is never off")
        // Tapped while a dial runs: the sheet opens.
        XCTAssertTrue(waitUntil(timeout: 40) { !retry.isEnabled }, "a dial is running")
        shot("offline-dialling-other-button-on")
        other.tap()
        XCTAssertTrue(app.buttons["offline.sign-in.cancel"].waitForExistence(timeout: 10), "the sheet opens during a dial")
    }

    // MARK: O27. The reconnect notice at the largest text size: whole, and still a notice

    @MainActor func testO27_ReconnectNoticeAtTheLargestTextSize() throws {
        freshApp(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-HQDebugNoticeStay", "40"])
        Thread.sleep(forTimeInterval: 3)
        let before = notices().count
        setMode("status", ["status": 503])
        XCTAssertTrue(waitUntil(timeout: 45, every: 3) { self.notices().count > before }, "the notice shows")
        let shown = try XCTUnwrap(notices().log.last)
        XCTAssertTrue(Self.bannerSentences.contains(shown.sentence), "a known sentence: \(shown.sentence)")
        // At this size it was 259 pt tall and cut after four lines. Its type now stops at the first accessibility
        // size: the longest sentence is a few lines.
        XCTAssertLessThan(shown.frame.height, 180, "a notice, not a wall: \(shown.frame)")
        XCTAssertGreaterThanOrEqual(shown.frame.height, 44, "\(shown.frame)")
        XCTAssertEqual(bannerText(), shown.sentence, "the whole sentence is what is on show")
        shot("banner-ax5")
        note("the notice at the largest text size: \(Int(shown.frame.width)) x \(Int(shown.frame.height)) pt, \"\(shown.sentence)\"")
    }

    // MARK: O28. A reply that finishes while the app is away is on show on return, without leaving the chat

    @MainActor func testO28_AReplyFinishedWhileAwayShowsOnReturn() throws {
        freshApp()
        openBot("default")
        let chat = Self.botChat("default")
        // (think, away): the reply ends with the socket still held (its frames reach a backgrounded app), then with the
        // socket let go after the 25 s grace (the reconnect's catch-up brings it).
        for (round, (think, away)) in [(4.0, 12.0), (30.0, 45.0)].enumerated() {
            try ctl.control("/__fixture/turn", ["session_id": chat, "chars": 300 + round * 100, "think": think])
            let field = app.textViews["composer.text"]
            field.tap()
            field.typeText("Round \(round + 1), take your time")
            tapSend()
            Thread.sleep(forTimeInterval: 1)
            goHome()
            Thread.sleep(forTimeInterval: away)
            app.activate()
            let whole = waitUntil(timeout: 15) { self.longestChatText() >= 290 + round * 100 }
            if !whole {
                shot("away-reply-missing-\(round + 1)")
                let calls = ((ledger()["rpc"] as? [[String: Any]]) ?? []).suffix(14).compactMap { $0["method"] as? String }
                note("round \(round + 1): reply not on show after return; last calls: \(calls.joined(separator: ", "))")
            }
            XCTAssertTrue(whole, "round \(round + 1): the reply is on show on return: \(longestChatText()) characters")
        }
    }

    // MARK: O29. Build 292: a long chat catches up on return as soon as the link is ready

    /// Sent, then the phone left before the turn's first frame; the turn ran while the socket was let go and the
    /// gateway restarted meanwhile (no replay). On return the reply must show right after the link is ready, with no
    /// reopen (owner's phone, Oct 13–15). The chat is long (markdown, code blocks, tables, tool rows), so the catch-up's
    /// main-thread work shows in the app's `main.hang` records (scripts/catchup-trace.sh profiles the return and copies
    /// them out). The seconds from the return to the reply on show are noted.
    @MainActor func testO29_ALongChatCatchesUpOnReturn() throws {
        let chat = Self.botChat("default")
        try ctl.control("/__fixture/rich", ["session_id": chat, "turns": 60])
        freshApp()
        mark("start")
        openBot("default")
        XCTAssertTrue(waitUntil(timeout: 15) { self.anyLabel(containing: "Tell me if you want the next step") }, "the long chat shows")
        try ctl.control("/__fixture/turn", ["session_id": chat, "chars": 900, "wait": 30])
        let field = app.textViews["composer.text"]
        field.tap()
        field.typeText("One more step, take your time")
        tapSend()
        Thread.sleep(forTimeInterval: 1)
        mark("away")
        goHome()
        Thread.sleep(forTimeInterval: 45)          // the 25 s grace lets the socket go; the turn runs at 30 s, unheard
        try ctl.control("/__fixture/restart", [:]) // no replay: the catch-up has only the saved rows
        mark("return")
        let back = Date()
        app.activate()
        let shown = waitUntil(timeout: 50) { self.longestChatText() >= 890 }
        let seconds = Date().timeIntervalSince(back)
        if !shown { shot("long-chat-catch-up-missing") }
        note(String(format: "long chat: the reply that finished while away showed %.1f s after the return", seconds))
        XCTAssertTrue(shown, "the reply is on show after the return: \(longestChatText()) characters")
        XCTAssertLessThan(seconds, 8, "right after the link is ready, not after the 45 s watchdog or a reopen")
        Thread.sleep(forTimeInterval: 3)
        mark("done")
    }

    /// A marker in the shots folder that scripts/catchup-trace.sh waits for.
    private func mark(_ what: String) {
        guard let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("catchup-\(what).marker")
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: url)
    }

    // MARK: O18. Dark appearance of every new screen (screenshots to look at)

    @MainActor func testO18_DarkScreens() throws {
        try XCTSkipUnless(darkSession, "Runs in the dark pass of scripts/e2e-offline.sh (the simulator dark before the session starts).")
        freshApp()
        XCTAssertLessThan(pageBrightness() ?? 255, 70, "the app is dark in this pass: \(pageBrightness() ?? -1)")
        leave()
        relaunch(["-HQDebugResetCaches", "YES", "-HQDebugLaunchHold", "16"])
        XCTAssertTrue(el("launch.icon").waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { (self.pageBrightness() ?? 255) < 70 }, "the launch screen is dark with the system: \(pageBrightness() ?? -1)")
        shot("launch-icon-dark")
        XCTAssertTrue(waitUntil(timeout: 8) { self.el("launch.caption").exists && !self.app.buttons["launch.try-again"].exists }, "the caption")
        shot("launch-caption-dark")
        XCTAssertTrue(waitUntil(timeout: 16) { self.app.buttons["launch.try-again"].exists }, "the stalled state")
        shot("launch-stalled-dark")
        app.terminate()
        setMode("status", ["status": 503])
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(pageBrightness() ?? 255, 70, "the offline screen is dark with the system")
        shot("offline-screen-dark")
        app.buttons["offline.different-gateway"].tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(pageBrightness() ?? 255, 90, "the sign-in form is dark with the system: \(pageBrightness() ?? -1)")
        shot("offline-different-gateway-sheet-dark")
        app.buttons["offline.sign-in.cancel"].tap()
        // Back up: the app, then an outage for the banner and the stale card.
        setMode("up")
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 45), "the app")
        dismissAlerts()
        XCTAssertTrue(waitUntil(timeout: 15) { self.botShown("default") })
        Thread.sleep(forTimeInterval: 3)
        // The notice stays 6 s: that it showed is read from the app's record; the picture is taken when a look
        // catches it (a slow run may not, and says so).
        let noticesBefore = notices().count
        setMode("status", ["status": 503])
        Thread.sleep(forTimeInterval: 5)
        var pictured = false
        XCTAssertTrue(waitUntil(timeout: 40, every: 0.5) {
            if !pictured, self.bannerShowing() { self.shot("banner-reconnecting-dark"); pictured = true }
            return pictured || self.notices().count > noticesBefore
        }, "the notice")
        if !pictured { note("dark pass: the notice showed (on record) but no look caught it for the picture") }
        setMode("up")
        XCTAssertTrue(waitUntil(timeout: 60) { !self.bannerShowing() })
        // The Bots list's three states and the storage sentence.
        leave()
        try ctl.control("/__fixture/fail", ["rpc": "profiles.list", "code": -32000, "count": 500])
        relaunch()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botShown("default") }, "the saved list")
        XCTAssertTrue(el("bots.notice.text").waitForExistence(timeout: 30), "the stale card")
        shot("bots-stale-dark")
        leave()
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(waitUntil(timeout: 50) { self.app.staticTexts["Couldn’t Load Bots"].exists }, "Couldn’t Load Bots")
        XCTAssertTrue(waitUntil(timeout: 8) { !self.el("launch").exists }, "the launch screen has left")
        Thread.sleep(forTimeInterval: 0.6)
        shot("bots-cant-load-dark")
        leave()
        try ctl.control("/__fixture/reset", ["seed": false])
        try ctl.control("/__fixture/delay", ["rpc": ["profiles.list": 60]])   // up for 45 s: a slow run still sees it
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 25), "the app with its own loading state")
        XCTAssertTrue(waitUntil(timeout: 50, every: 1) { self.labelNow("bots.notice.text") != nil }, "the slow card")
        shot("bots-slow-dark")
        XCTAssertTrue(waitUntil(timeout: 70, every: 1) { self.botShown("default") }, "the list arrives")
        try ctl.control("/__fixture/reset", ["seed": false])
        leave()
        relaunch(["-HQDebugStorageFailure", "YES"])
        XCTAssertTrue(waitUntil(timeout: 10) { self.el("launch.caption").exists && self.el("launch.caption").label == Self.storageSentence },
                      "the storage sentence")
        shot("launch-storage-dark")
        leave()
        relaunch()
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 45), "the app again")
        dismissAlerts()
        XCTAssertTrue(waitUntil(timeout: 20) { self.botShown("default") && !self.bannerShowing() })
        Thread.sleep(forTimeInterval: 3)
        try ctl.control("/__fixture/oversize", [:])
        if app.alerts["Message too large"].waitForExistence(timeout: 60) {
            shot("alert-too-large-dark")
            app.alerts["Message too large"].buttons["OK"].tap()
        } else {
            XCTFail("the Message too large alert did not show")
        }
        XCTAssertTrue(waitUntil(timeout: 40) { !self.app.staticTexts["Reconnecting…"].exists && !self.bannerShowing() })
        try ctl.control("/__fixture/revoke", [:])
        XCTAssertTrue(app.alerts["Sign In Again"].waitForExistence(timeout: 40))
        shot("alert-sign-in-again-dark")
        app.alerts["Sign In Again"].buttons["Not Now"].tap()
        XCTAssertTrue(app.staticTexts["Signed Out"].waitForExistence(timeout: 8))
        shot("header-signed-out-dark")
    }

    // MARK: S1. Big lists (stress 1): 60 bots and 500 chats

    @MainActor func testS01_BigLists() throws {
        try ctl.control("/__fixture/reset", ["bots": 60, "sessions": 500])
        freshApp()
        XCTAssertTrue(waitUntil(timeout: 20) { self.botShown("default") })
        leave()
        // Cached: rows on the first frames.
        let started = Date()
        relaunch()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botShown("default") }, "the saved list")
        note("cached launch to rows with 60 bots: \(String(format: "%.2f", Date().timeIntervalSince(started))) s (includes XCTest launch)")
        XCTAssertFalse(el("offline").exists)
        // Uncached: launch screen, then the app with rows; never a skeleton left behind.
        leave()
        relaunch(["-HQDebugResetCaches", "YES"])
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 20) { self.botShown("default") }, "the list")
        app.collectionViews["bots.list"].swipeUp()
        app.collectionViews["bots.list"].swipeUp()
        XCTAssertFalse(el("bots.notice.text").exists, "no card on a healthy list")
        shot("bots-big-list")
    }

    // MARK: S2. A reconnect storm (stress 2): no notice, no read storm

    @MainActor func testS02_ReconnectStorm() throws {
        freshApp()
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.cells["session-row-s-001"].waitForExistence(timeout: 15))
        app.cells["session-row-s-001"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4)
        let probes = count("probes"), full = count("full"), reads = messageReads("s-001"), activates = rpcCount("session.activate")
        let started = Date()
        // DECISION (report): a socket that keeps dying within 5 s of opening keeps its back-off (spec 01 §13.2), so in
        // a storm the app can be without a socket for longer than the 4 s hold and the notice is then due. What must
        // hold is the rule itself: the notice never shows unless no socket has opened for (about) 4 s.
        var firstShown: Double?
        for _ in 0..<25 {
            try ctl.control("/__fixture/drop", [:])
            if firstShown == nil, bannerShowing() { firstShown = Date().timeIntervalSince1970 }
            Thread.sleep(forTimeInterval: 0.4)
        }
        if let firstShown {
            let lastOpen = socketOpens().filter { $0 <= firstShown }.max() ?? started.timeIntervalSince1970
            let without = firstShown - lastOpen
            note("storm: the notice showed \(String(format: "%.1f", without)) s after the last socket opened")
            XCTAssertGreaterThanOrEqual(without, 3.0, "the notice showed only \(without) s after a socket opened")
        } else {
            note("storm: no notice during 25 drops")
        }
        XCTAssertTrue(waitUntil(timeout: 40) { !self.bannerShowing() && !self.app.staticTexts["Reconnecting…"].exists }, "connected and quiet after the storm")
        let seconds = Date().timeIntervalSince(started)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert")
        let allowed = Int(seconds / 3) + 2
        XCTAssertLessThanOrEqual(count("probes") - probes, allowed, "at most one sessions probe per 3 s over \(Int(seconds)) s")
        XCTAssertLessThanOrEqual(count("full") - full, 2, "the full sessions read is not repeated per reconnect")
        // This chat has seen no event yet, so it holds no replay cursor and a reconnect catches up with one read of the
        // saved chat (spec 04 §7.4). The rule to hold is §6.5's: one history read per socket that opened, never two. A
        // read is followed by its one-row look 1.2 s on (builds 278/292, cbaa2fb and e1ca54b): at most one per socket.
        let opened = socketOpens().filter { $0 >= started.timeIntervalSince1970 }.count
        let details = Array(messageReadDetails("s-001").dropFirst(reads))
        let historyReads = details.filter { !$0.hasSuffix("limit 1") }.count, probeReads = details.count - historyReads
        note("storm: \(count("probes") - probes) probes, \(count("full") - full) full reads, \(historyReads) chat reads and \(probeReads) one-row looks, \(rpcCount("session.activate") - activates) session.activate, \(opened) sockets opened in \(Int(seconds)) s")
        note("storm: the open chat's reads, each with its limit: \(details.joined(separator: ", "))")
        XCTAssertLessThanOrEqual(historyReads, opened, "at most one read of the open chat per socket that opened: \(details), \(opened) sockets")
        XCTAssertLessThanOrEqual(probeReads, opened, "at most one one-row look per socket that opened: \(details), \(opened) sockets")
        XCTAssertLessThanOrEqual(rpcCount("session.activate") - activates, opened, "one session.activate per socket at most")
        XCTAssertTrue(app.tables["chat.table"].exists, "the chat is still on show")
    }

    // MARK: S3. A storm with a chat that holds a replay cursor: the replay covers every reconnect, no history read (§6.5)

    @MainActor func testS03_StormWithAReplayCursorReadsNoHistory() throws {
        freshApp()
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.cells["session-row-s-003"].waitForExistence(timeout: 15))
        app.cells["session-row-s-003"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        // A turn seen live gives the chat its cursor (the last seq it saw).
        let field = app.textViews["composer.text"]
        field.tap()
        field.typeText("Count for me")
        tapSend()
        XCTAssertTrue(waitUntil(timeout: 40) { self.longestChatText() >= 200 }, "the reply arrived live: \(longestChatText())")
        Thread.sleep(forTimeInterval: 8)             // the turn's own settling reads are done
        // A first reply on a fresh install brings the app's notifications offer ("Know When a Bot Replies?", the
        // notifications stream's). It is not this test's subject: answer it, so "no alert" below means no alert from
        // the storm (stress round 1: the offer was left up and failed that line).
        let offer = app.alerts["Know When a Bot Replies?"]
        if offer.waitForExistence(timeout: 6) { offer.buttons["Not Now"].tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { !offer.exists }, "the offer is answered")
        let reads = messageReads("s-003"), activates = rpcCount("session.activate"), since = rpcCount("session.events.since")
        let started = Date()
        for _ in 0..<10 {
            try ctl.control("/__fixture/drop", [:])
            Thread.sleep(forTimeInterval: 1.2)
        }
        XCTAssertTrue(waitUntil(timeout: 60) { !self.bannerShowing() && !self.app.staticTexts["Reconnecting…"].exists }, "connected and quiet after the storm")
        Thread.sleep(forTimeInterval: 4)
        let opened = socketOpens().filter { $0 >= started.timeIntervalSince1970 }.count
        // §6.5 check 2: no history read, and at most one one-row look per reconnect (with no read made, a reply that
        // finished while the link was paused is looked for at once: build 292, e1ca54b).
        let details = Array(messageReadDetails("s-003").dropFirst(reads)).filter { !Self.isRowPreview($0) }
        let historyReads = details.filter { !$0.hasSuffix("limit 1") }.count, probeReads = details.count - historyReads
        note("storm with a replay cursor: \(historyReads) history reads and \(probeReads) one-row looks of the open chat, "
             + "\(rpcCount("session.activate") - activates) session.activate, \(rpcCount("session.events.since") - since) session.events.since, "
             + "\(opened) sockets opened; reads: \(details.joined(separator: ", "))")
        XCTAssertGreaterThanOrEqual(opened, 2, "the storm reconnected: \(opened)")
        XCTAssertEqual(historyReads, 0, "the replay covers each reconnect: the open chat's history is not read at all: \(details)")
        XCTAssertLessThanOrEqual(probeReads, opened, "at most one one-row look per socket that opened: \(details), \(opened) sockets")
        XCTAssertLessThanOrEqual(rpcCount("session.activate") - activates, opened, "one session.activate per socket at most")
        XCTAssertGreaterThanOrEqual(longestChatText(), 200, "the reply is still whole")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert")
    }

    // MARK: O23. A visible poll waits three times as long while the phone saves power (§6.9)

    @MainActor func testO23_AVisiblePollStretchesWhileSavingPower() throws {
        // A gateway without change events: the Jobs list on screen is read again every 30 s. In Low Power Mode every
        // 90 s. Read from the stand-in's ledger.
        try ctl.control("/__fixture/options", ["change_events": false])
        let jobsReads = { self.restCount("/api/cron/jobs") }
        func gaps(saving: Bool, watch: TimeInterval) -> [Double] {
            freshApp(["-HQDebugPowerSaving", saving ? "YES" : "NO"])
            app.tabBars.buttons["Jobs"].tap()
            XCTAssertTrue(el("job-row-default|job-1").waitForExistence(timeout: 15), "the Jobs list")
            let first = jobsReads()
            let began = Date()
            var times: [Double] = []
            var seen = first
            while Date().timeIntervalSince(began) < watch {
                let now = jobsReads()
                if now > seen { times.append(Date().timeIntervalSince(began)); seen = now }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
            app.terminate()
            return times
        }
        let normal = gaps(saving: false, watch: 75)
        note("Jobs poll without change events: read again at \(normal.map { String(format: "%.0f s", $0) }) (normal power)")
        XCTAssertGreaterThanOrEqual(normal.count, 2, "every 30 s: two reads in 75 s: \(normal)")
        XCTAssertLessThanOrEqual(normal.count, 3, "and no more: \(normal)")
        try ctl.control("/__fixture/reset", [:])
        try ctl.control("/__fixture/options", ["change_events": false])
        let saving = gaps(saving: true, watch: 105)
        note("Jobs poll without change events: read again at \(saving.map { String(format: "%.0f s", $0) }) (saving power)")
        XCTAssertEqual(saving.count, 1, "every 90 s while saving power: one read in 105 s: \(saving)")
        if let only = saving.first { XCTAssertGreaterThanOrEqual(only, 75, "not before about 90 s: \(saving)") }
    }

    // MARK: S11. Flapping (stress 11): down 2 s, up 2 s

    @MainActor func testS11_Flapping() throws {
        freshApp()
        Thread.sleep(forTimeInterval: 3)
        let began = Date().timeIntervalSince1970
        let before = notices().count
        for _ in 0..<10 {
            self.setMode("status", ["status": 503])
            Thread.sleep(forTimeInterval: 2)
            self.setMode("up")
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertEqual(app.alerts.count, 0, "no alerts from flapping")
        XCTAssertTrue(waitUntil(timeout: 60) { !self.bannerShowing() && !self.app.staticTexts["Reconnecting…"].exists }, "quiet at the end")
        // Each outage is 2 s on the gateway; the app's own back-off can stretch one past the 4 s hold, so the notice
        // may show. It must never flicker. Read from the app's own record of what it put up (a slow test run cannot
        // miss a flicker there): the same sentence is never back within 3 s of leaving, and the notice never shows
        // sooner than about 4 s after a socket last opened.
        let record = notices()
        let log = record.log.filter { $0.start >= began }
        let shows = record.count - before
        let opens = socketOpens()
        var shortestGap = Double.infinity
        for (earlier, later) in zip(log, log.dropFirst()) where earlier.sentence == later.sentence {
            if let end = earlier.end { shortestGap = min(shortestGap, later.start - end) }
        }
        for one in log {
            let lastOpen = opens.filter { $0 <= one.start }.max() ?? began
            // A sentence that follows another at once (the cause after "Reconnecting…") is the same showing going on.
            let follows = log.contains { ($0.end ?? -1) > 0 && abs(($0.end ?? 0) - one.start) < 0.5 }
            if !follows { XCTAssertGreaterThanOrEqual(one.start - lastOpen, 3.0, "“\(one.sentence)” showed only \(one.start - lastOpen) s after a socket opened") }
            XCTAssertTrue(Self.bannerSentences.contains(one.sentence), "a known sentence: \(one.sentence)")
        }
        XCTAssertLessThanOrEqual(shows, 20, "at most two sentences per outage: shown \(shows) times over 10 outages")
        XCTAssertGreaterThanOrEqual(shortestGap, 3.0, "the same sentence was back \(shortestGap) s after leaving")
        note("flapping: the notice put up \(shows) sentences over 10 two-second outages; shortest time before the same sentence came back \(shortestGap == .infinity ? "none" : String(format: "%.1f s", shortestGap))")
        XCTAssertTrue(app.collectionViews["bots.list"].isHittable)
    }

    // MARK: S29. Relaunches against a down gateway with saved content (stress 29)

    @MainActor func testS29_RelaunchesWithSavedContentNeverShowOffline() throws {
        freshApp()
        leave()
        try ctl.control("/__fixture/reset", ["seed": false])
        setMode("status", ["status": 503])
        // Each launch is a new process, so its ladder starts over: a dial at once, then 3, 6, 12, 24 s apart (at 0, 3,
        // 9, 21, 45 s). How many fit depends on how long the launch stayed up, which on a loaded Mac is anything from
        // 3 to 20 s, so each round is held to what the ladder allows for its own length (a dial is the session check
        // or the request for a socket ticket; list reads let through as outage probes, spec §6.1, and the diagnostic log upload on leaving
        // are not dials). Never more: no storm from opening the app again and again.
        var allowedInAll = 0, lines: [String] = []
        for round in 1...5 {
            let began = Date().timeIntervalSince1970
            relaunch()
            XCTAssertTrue(waitUntil(timeout: 8) { self.botShown("default") }, "round \(round): saved rows")
            XCTAssertFalse(el("offline").exists, "round \(round): never the offline screen")
            Thread.sleep(forTimeInterval: 1.5)
            goHome()
            app.terminate()
            let ended = Date().timeIntervalSince1970
            let mine = dialAttempts().filter { $0 >= began && $0 <= ended + 0.5 }
            let first = mine.first ?? began
            let up = ended - first
            let allowed = [0.0, 3, 9, 21, 45, 75].filter { $0 <= up + 0.5 }.count
            allowedInAll += allowed
            lines.append("round \(round): up \(String(format: "%.1f", up)) s, dials at \(mine.map { String(format: "%.1f", $0 - first) }) (allowed \(allowed))")
            XCTAssertLessThanOrEqual(mine.count, allowed, "round \(round): dials follow the ladder, no burst: \(lines.last ?? "")")
        }
        let dials = dialAttempts().count
        XCTAssertGreaterThanOrEqual(dials, 5, "every launch dialled: \(lines)")
        XCTAssertLessThanOrEqual(dials, allowedInAll, "dials follow the ladder per launch, no burst: \(dials) of \(allowedInAll)")
        note("5 relaunches against a down gateway: \(dials) dials (the ladder allowed \(allowedInAll)), \(restBursts().count) bursts of requests of any kind; " + lines.joined(separator: "; "))
        // And the sixth launch, the gateway back: straight to the app, connected.
        setMode("up")
        relaunch()
        XCTAssertTrue(waitUntil(timeout: 15) { self.botShown("default") }, "saved rows again")
        XCTAssertTrue(waitUntil(timeout: 60) { !self.app.staticTexts["Reconnecting…"].exists && !self.app.staticTexts["Offline"].exists }, "connected once the gateway answers")
        XCTAssertFalse(el("offline").exists, "never the offline screen")
    }

    // MARK: Helpers

    @MainActor private func launch(reset: Bool, _ arguments: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-HQDebugResetAccounts", "YES"] : []) + ["-HQDebugExposeStatus", "YES"] + arguments
        if reset {
            app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username,
                                     "HQN_SIGNIN_PASSWORD": account.password]
        }
        // The app that ran before is all the way gone first. `launch()` ends a running copy by itself, but on a loaded
        // Mac that SIGTERM was seen to land on the copy just started (every such "crash" in the system log is an exit
        // by SIGTERM, never a crash signal, and no crash report exists), which XCTest then reports as
        // "Critical process crashed in (null)".
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 20)
        }
        Thread.sleep(forTimeInterval: 1.5)
        app.launch()
        self.app = app
    }

    /// A clean first run signed in to stand-in A, with its list on show.
    @MainActor private func freshApp(_ arguments: [String] = []) {
        launch(reset: true, arguments)
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 40), "signed in")
        dismissAlerts()
        XCTAssertTrue(waitUntil(timeout: 20) { self.botShown("default") }, "the roster is on show")
    }

    @MainActor private func relaunch(_ arguments: [String] = []) { launch(reset: false, arguments) }

    /// A launch-time offer (notifications setup) may come; close it.
    @MainActor private func dismissAlerts() {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2), alert.buttons["Not Now"].exists, !app.alerts["Sign In Again"].exists {
            alert.buttons["Not Now"].tap()
        }
    }

    @MainActor private func dismissSavePassword() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let passwords = XCUIApplication(bundleIdentifier: "com.apple.Passwords")
        let candidates = [springboard.buttons["Not Now"], passwords.buttons["Not Now"]]
        _ = waitUntil(timeout: 5) { candidates.contains { $0.exists } || self.app.tabBars.buttons["Bots"].exists }
        candidates.first { $0.exists }?.tap()
    }

    @MainActor private func goHome() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5))
    }

    /// To the Home Screen (caches are written), then the end of the process.
    @MainActor private func leave() {
        goHome()
        Thread.sleep(forTimeInterval: 0.6)
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 20)
    }

    @MainActor private func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func botShown(_ id: String) -> Bool {
        app.cells["bot-row-\(id)"].exists || app.cells["bot-tile-\(id)"].exists
    }

    @MainActor private func openBot(_ id: String) {
        if !app.collectionViews["bots.list"].isHittable, app.tabBars.buttons["Bots"].exists { app.tabBars.buttons["Bots"].tap() }
        XCTAssertTrue(waitUntil(timeout: 15) { self.botShown(id) }, "the \(id) bot is listed")
        (app.cells["bot-row-\(id)"].exists ? app.cells["bot-row-\(id)"] : app.cells["bot-tile-\(id)"]).tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor private func anyLabel(containing text: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }

    @MainActor private func bannerShowing() -> Bool { el("connection.banner").exists || el("connection.banner.text").exists }

    /// The sentence on the notice, "" when it is not up. Read from one snapshot: the notice may leave between a look
    /// and a read, and a plain `.label` on an element that has just gone fails the test for no fault of the app.
    @MainActor private func bannerText() -> String {
        (try? el("connection.banner").snapshot())?.label ?? ""
    }

    /// An element's label from one snapshot, nil when it is not there.
    @MainActor private func labelNow(_ id: String) -> String? { (try? el(id).snapshot())?.label }

    /// One sentence the reconnect notice put up, from the app's own record (`OfflineDebug`, "debug.notice").
    struct Notice {
        var start: Double
        /// Seconds it stayed, nil while it is still up.
        var stayed: Double?
        var frame: CGRect
        var sentence: String
        var end: Double? { stayed.map { start + $0 } }
    }

    /// Every sentence the notice has put up since the app started (the last 16), oldest first, and how many in all.
    /// A record, not a look: what a slow test run fails to catch on screen is still in it.
    @MainActor private func notices() -> (count: Int, log: [Notice]) {
        guard let value = (try? el("debug.notice").snapshot())?.value as? String else { return (0, []) }
        var lines = value.components(separatedBy: "\n")
        let count = Int(lines.removeFirst().replacingOccurrences(of: "n=", with: "")) ?? 0
        let log = lines.compactMap { line -> Notice? in
            let parts = line.components(separatedBy: ";")
            guard parts.count >= 4, let start = Double(parts[0]), let stayed = Double(parts[1]) else { return nil }
            let box = parts[2].components(separatedBy: ",").compactMap { Double($0) }
            let frame = box.count == 4 ? CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) : .zero
            return Notice(start: start, stayed: stayed < 0 ? nil : stayed, frame: frame, sentence: parts[3...].joined(separator: ";"))
        }
        return (count, log)
    }

    /// The offline screen's visible status line (`-HQDebugExposeStatus YES` puts it in the element's value).
    @MainActor private func statusWords() -> String {
        let status = el("offline.status")
        return status.exists ? ((status.value as? String) ?? "") : ""
    }

    /// Taps an offline-screen button while a wait of three seconds or more is counting. During an attempt
    /// ("Connecting…", at least 0.6 s) the buttons are disabled by design, and a tap then does nothing.
    @MainActor private func tapBetweenAttempts(_ id: String) {
        XCTAssertTrue(waitUntil(timeout: 45) { (self.countdown(self.statusWords()) ?? 0) >= 3 && self.app.buttons[id].isEnabled },
                      "\(id): a wait is counting (\(statusWords()))")
        app.buttons[id].tap()
    }

    /// N of "Trying Again in N s".
    private func countdown(_ words: String) -> Int? {
        guard words.hasPrefix("Trying Again in "), words.hasSuffix("\u{00A0}s") else { return nil }
        return Int(words.dropFirst("Trying Again in ".count).dropLast(2))
    }

    /// Types an address, username and password into the sign-in form on show and submits.
    @MainActor private func typeSignIn(_ who: FixtureAccount) {
        let address = app.textFields["sign-in-address"]
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        address.typeText(who.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 12), "the password fields show for the address")
        username.tap()
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        username.typeText(who.username)
        let password = app.secureTextFields["sign-in-password"]
        for _ in 0..<4 where !password.isHittable { app.swipeUp() }
        password.tap()
        password.typeText(who.password)
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        button.tap()
        dismissSavePassword()
    }

    /// The longest text on show in the chat (a reply's characters).
    /// The simulator hides the software keyboard while XCUITest types and brings it back about a second later; a tap
    /// on Send in that window ends outside the button as the row moves (as `MenusTests.waitForKeysUp` found). Wait for
    /// the row to be back over the keys and still, then tap.
    @MainActor private func tapSend() {
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send")
        var last = CGRect.null
        var steady = 0
        _ = waitUntil(timeout: 5) {
            let frame = send.frame
            let up = frame.maxY < self.app.frame.height * 0.7
            steady = up && frame == last ? steady + 1 : 0
            last = frame
            return steady >= 2
        }
        send.tap()
    }

    @MainActor private func longestChatText() -> Int {
        let table = app.tables["chat.table"]
        guard table.exists else { return 0 }
        let texts = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "invented reply"))
        var longest = 0
        for index in 0..<min(texts.count, 12) { longest = max(longest, texts.element(boundBy: index).label.count) }
        return longest
    }

    // MARK: The stand-in's ledger

    private func setMode(_ mode: String, _ extra: [String: Any] = [:]) {
        var body = extra
        body["mode"] = mode
        _ = try? ctl.control("/__fixture/mode", body)
    }

    private func ledger() -> [String: Any] { (try? ctl.control("/__fixture/state")) ?? [:] }

    private func count(_ key: String) -> Int { (ledger()[key] as? Int) ?? 0 }

    private func rpcCount(_ method: String) -> Int {
        ((ledger()["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == method }.count
    }

    private func messageReads(_ session: String) -> Int {
        ((ledger()["rest"] as? [[String: Any]]) ?? []).filter { ($0["path"] as? String) == "/api/sessions/\(session)/messages" }.count
    }

    /// [main-e2e] A Sessions row's newest words (SessionLatestRules.tail = 8) and a Bots row's (BotSaidRules.tail = 30)
    /// read the same route with their own short tails: not the open chat's reads.
    private static func isRowPreview(_ detail: String) -> Bool { detail.hasSuffix(" limit 8") || detail.hasSuffix(" limit 30") }

    /// Each read of a chat's saved messages: seconds since the first one, and its `limit`.
    private func messageReadDetails(_ session: String) -> [String] {
        let rows = ((ledger()["rest"] as? [[String: Any]]) ?? []).filter { ($0["path"] as? String) == "/api/sessions/\(session)/messages" }
        let first = (rows.first?["start"] as? Double) ?? 0
        return rows.map { row in
            let query = (row["query"] as? [String: Any]) ?? [:]
            let limit = (query["limit"] as? [Any])?.first ?? query["limit"] ?? "?"
            return "+\(String(format: "%.1f", ((row["start"] as? Double) ?? 0) - first)) s limit \(limit)"
        }
    }

    private func restTotal() -> Int { ((ledger()["rest"] as? [[String: Any]]) ?? []).count }

    /// When each socket was accepted by the stand-in (it says ready at once).
    private func socketOpens() -> [Double] { (ledger()["dials"] as? [Double]) ?? ((ledger()["dials"] as? [NSNumber]) ?? []).map(\.doubleValue) }

    private func restCount(_ path: String) -> Int {
        ((ledger()["rest"] as? [[String: Any]]) ?? []).filter { ($0["path"] as? String) == path }.count
    }

    /// The chats whose saved messages were read, in the order the reads began.
    private func tailReads() -> [String] {
        ((ledger()["rest"] as? [[String: Any]]) ?? [])
            .compactMap { row -> (Double, String)? in
                // [main-e2e] Only the warmer's reads (ChatWarmer.rowsPerTail = 24 rows): the Bots and Sessions rows read
                // their newest words from the same route with their own short tails (BotSaidRules, SessionLatestRules).
                guard let path = row["path"] as? String, path.hasPrefix("/api/sessions/"), path.hasSuffix("/messages"),
                      (row["query"] as? [String: Any])?["limit"] as? String == "24",
                      let start = row["start"] as? Double else { return nil }
                return (start, String(path.dropFirst("/api/sessions/".count).dropLast("/messages".count)))
            }
            .sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The stand-in's id for a bot's own chat (scripts/fixtures/offline-gateway.py `bot_chat_id`).
    private static func botChat(_ profile: String) -> String {
        let digest = SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined()
        return "20261011_090000_bc\(digest.prefix(6))"
    }

    /// When the app started a dial against a gateway that answers with an error: the request for a socket ticket
    /// (since connect-fast also a restore's session check; `/api/auth/me` is still counted, as an older build's
    /// first dials began with it). The gateways these tests fail answer 5xx/429, so a dial is one request.
    private func dialAttempts() -> [Double] {
        ((ledger()["rest"] as? [[String: Any]]) ?? []).filter { ["/api/auth/me", "/api/auth/ws-ticket"].contains(($0["path"] as? String) ?? "") }
            .compactMap { $0["start"] as? Double }.sorted()
    }

    /// Roster reads that were not the list's own poll: a `profiles.list` sooner than 25 s after the one before it
    /// (the poll runs every 30 s or slower, on its own clock, whatever the app's activations do).
    private func rosterReadsOffThePoll(after mark: Int) -> Int {
        let times = ((ledger()["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == "profiles.list" }
            .compactMap { $0["start"] as? Double }
        guard times.count > mark, mark > 0 else { return max(0, times.count - mark) }
        return (mark..<times.count).filter { times[$0] - times[$0 - 1] < 25 }.count
    }

    /// When each burst of gateway requests began (requests less than 1.5 s apart are one connection attempt).
    private func restBursts() -> [Double] {
        let starts = ((ledger()["rest"] as? [[String: Any]]) ?? []).compactMap { $0["start"] as? Double }.sorted()
        var bursts: [Double] = []
        var last = -Double.infinity
        for start in starts {
            if start - last > 1.5 { bursts.append(start) }
            last = start
        }
        return bursts
    }

    private func note(_ text: String) {
        print("[offline-e2e] \(text)")
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("e2e-offline-notes.txt")
            let line = "\(name): \(text)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// How bright the page is where nothing is drawn (the left edge, a third of the way down): 0 black … 255 white.
    /// The dark screenshots are checked with it, so a simulator that did not really switch cannot pass for dark.
    @MainActor private func pageBrightness() -> Int? {
        guard let image = XCUIScreen.main.screenshot().image.cgImage, let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let x = 10, y = image.height / 3
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        guard offset + 2 < CFDataGetLength(data) else { return nil }
        return (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
    }

    @MainActor private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("e2e-\(name).png"))
        }
    }

    @MainActor private func waitUntil(timeout: TimeInterval, every pause: TimeInterval = 0.15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pause))
        }
        return condition()
    }
}
