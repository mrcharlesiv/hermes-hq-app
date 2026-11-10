// The repeatable part of Bot Screen's stress plan (docs/spec/3x-screen.md §9) as UI tests against the screen fixture.
// Run with: HQN_SCREEN_STRESS=1 scripts/e2e-screen.sh <udid>   (the script then runs this class instead of the
// end-to-end one; HQN_SCREEN_ONLY narrows it). Bad network and bad data are made inside the fixture only. Numbers are
// written to the result bundle and to the log as "SCREEN-NOTE …" lines.

import XCTest

final class ScreenStressTests: ScreenTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["HQN_UI_SCREEN_STRESS"] == "1" else {
            throw XCTSkip("Run with HQN_SCREEN_STRESS=1 scripts/e2e-screen.sh <udid>.")
        }
    }

    @MainActor override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
    }

    @MainActor private func alive(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after \(what)", file: file, line: line)
    }

    // MARK: §9.1 L6 — open and close many times; nothing is left behind

    @MainActor func testL6_openAndCloseThirtyTimes() throws {
        launch()
        let started = Date()
        for round in 1...30 {
            openScreen()
            waitLive()
            if round % 3 == 0 { takeOver() }
            closeScreen()
        }
        note("30 opens and closes in \(Int(Date().timeIntervalSince(started))) s")
        XCTAssertTrue(waitUntil(timeout: 8) { self.int(self.ledger()["open_sockets"]) == 0 }, "no display socket left")
        let seen = ledger()
        XCTAssertEqual(int(seen["viewers"]), 0, "no viewer left")
        XCTAssertEqual(lease()["holder"] as? String, "agent", "the lease is the bot's")
        XCTAssertEqual(int(seen["max_open_sockets"]), 1, "never two sockets")
        XCTAssertEqual(int(seen["forbidden_calls"]), 0)
        XCTAssertEqual((seen["unknown_params"] as? [Any])?.count, 0)
        XCTAssertEqual(int(seen["dropped_inputs"]), 0)
        alive("30 opens")
    }

    // MARK: §9.1 L7, L2 — resizes mid-stream and the sizes at the limits

    @MainActor func testL7_resizeMidStreamAndSizeLimits() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        for round in 0..<10 {
            let big = round % 2 == 0
            ctl(["stream": ["size": big ? [1920, 1080] : [1280, 800]]])
            let want = big ? "1920x1080" : "1280x800"
            XCTAssertTrue(waitUntil(timeout: 12) { self.field("size", in: self.debugValue()) == want }, "resize \(round): \(debugValue())")
            if big {
                // Far into the bottom right corner of the larger desktop; it must be inside the smaller one afterwards.
                movePointer(dx: 150, dy: 150)
                movePointer(dx: 150, dy: 150)
            } else {
                let at = pointer()
                XCTAssertTrue((0..<1280).contains(at.x) && (0..<800).contains(at.y), "the pointer stays inside the desktop: \(at)")
            }
        }
        XCTAssertEqual(caption(), "You are in control", "resizes do not cost control")
        XCTAssertFalse(el("screen.ended.title").exists)

        // A 4K desktop is allowed; one over 64 MB of pixels is refused without a crash.
        ctl(["stream": ["size": [3840, 2160]]])
        XCTAssertTrue(waitUntil(timeout: 30) { self.field("size", in: self.debugValue()) == "3840x2160" }, debugValue())
        el("screen.stage").pinch(withScale: 3, velocity: 2)
        XCTAssertTrue(waitUntil(timeout: 4) { self.value("zoom") > 1.3 }, "a 4K desktop zooms")
        ctl(["stream": ["size": [8192, 8192]]])
        let ended = el("screen.ended.title")
        XCTAssertTrue(ended.waitForExistence(timeout: 40), "a desktop over the limit ends the stream (\(debugValue()))")
        XCTAssertEqual(ended.label, "Screen Stopped")
        alive("an 8192×8192 desktop")
        ctl(["stream": ["size": [1280, 800]]])
        app.buttons["screen.reconnect"].tap()
        waitLive()
    }

    // MARK: §9.1 L4 — typing under load, in order; handing back stops the rest

    @MainActor func testL4_longPasteInOrderAndHandBackStopsIt() throws {
        ctl(["mode": "linux"])
        launch()
        openScreen()
        waitLive()
        takeOver()
        raiseKeyboard()
        XCTAssertTrue(app.buttons["screen.paste"].waitForExistence(timeout: 5))
        let text = (0..<5_000).map { String(UnicodeScalar(UInt8(97 + $0 % 26))) }.joined()
        UIPasteboard.general.string = text
        var mark = inputs().count
        tapPaste()
        // While it types, the pointer keeps moving.
        movePointer(dx: 40, dy: 40)
        movePointer(dx: -40, dy: -40)
        XCTAssertTrue(waitUntil(timeout: 90) { self.keys(from: mark).count >= 10_000 }, "all 5,000 characters arrive: \(keys(from: mark).count)")
        let typed = keys(from: mark)
        XCTAssertEqual(typed.count, 10_000, "no key twice")
        XCTAssertEqual(String(typed.filter(\.down).compactMap { UnicodeScalar($0.sym).map(Character.init) }), text, "in order")
        var pairs = true
        for index in stride(from: 0, to: typed.count - 1, by: 2) where !(typed[index].down && !typed[index + 1].down && typed[index].sym == typed[index + 1].sym) {
            pairs = false
        }
        XCTAssertTrue(pairs, "every key is pressed, then released")
        XCTAssertTrue(waitUntil(timeout: 5) { self.value("backlog") == 0 })
        let moved = pointers(from: mark)
        note("L4: 5,000 pasted characters = \(typed.count) key events in order; \(moved.count) pointer events alongside")

        // Handing back right after another paste: whatever had gone out, nothing follows once control has ended.
        // (That the rest is dropped within one slice is the unit test typedTextGoesOutInSlicesAndStopsWhenControlEnds.)
        mark = inputs().count
        tapPaste(wait: 1.5)
        app.buttons["screen.give"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botInControl() })
        pause(1)
        let stopped = keys(from: mark).count
        pause(2)
        XCTAssertEqual(keys(from: mark).count, stopped, "nothing more is typed")
        XCTAssertEqual(int(ledger()["dropped_inputs"]), 0, "and nothing was sent without the lease")
        note("L4: hand back after a second paste: \(stopped) of 10,000 key events had gone out")
        UIPasteboard.general.items = []
    }

    // MARK: §9.2 — speed (simulator, loopback, a shared Mac: recorded, with loose ceilings)

    @MainActor func testS_speeds() throws {
        ctl(["stream": ["fps": 30]])
        launch()
        let item = screenMenuItem(bot: "default")
        let tapped = Date()
        item.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.value("frames") >= 1 })
        let first = Date().timeIntervalSince(tapped)
        note("S1 menu tap to first picture: \(String(format: "%.2f", first)) s (budget 1.5 s on an idle Mac; includes XCUITest polling)")
        XCTAssertLessThan(first, 8, "first picture")

        // S5: at 30 fps offered, frames shown over 10 s.
        let before = value("frames")
        pause(10)
        let shown = value("frames") - before
        note("S5 frames shown in 10 s at 30 fps offered: \(Int(shown)); \(debugValue())")
        XCTAssertGreaterThan(shown, 100, "frames keep up")
        XCTAssertEqual(field("mainDecodes", in: debugValue()), "0", "S7: decoding stays off the main thread")
        XCTAssertEqual(int(ledger()["max_outstanding_requests"]), 1, "S6: no backlog")
        let lag = int(ledger()["stream_serial"]) - Int(value("serial"))
        note("S6 serial lag behind the fixture: \(lag)")
        XCTAssertLessThanOrEqual(lag, 3)

        let take = app.buttons["screen.take"]
        XCTAssertTrue(waitUntil(timeout: 20) { take.isEnabled })
        let pressed = Date()
        take.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.caption() == "You are in control" })
        note("S2 Take over to “You are in control”: \(String(format: "%.2f", Date().timeIntervalSince(pressed))) s (budget 0.3 s; includes polling)")

        // S4: finger move to PointerEvent at the fixture.
        let mark = inputs().count
        let sent = Date().timeIntervalSince1970
        movePointer(dy: 40)
        XCTAssertTrue(waitUntil(timeout: 5) { self.inputs().count > mark })
        if let at = (inputs().dropFirst(mark).first?["t"] as? NSNumber)?.doubleValue {
            note("S4 gesture start to first PointerEvent: \(String(format: "%.0f", (at - sent) * 1000)) ms (includes the 50 ms press)")
        }
        let events = pointers(from: mark).count
        XCTAssertLessThan(events, 200, "moves are coalesced per display frame")

        // S10: Close while in control is immediate and hands back.
        let closing = Date()
        closeScreen()
        XCTAssertTrue(waitUntil(timeout: 5) { self.lease()["holder"] as? String == "agent" })
        note("S10 Close while in control: gone and handed back in \(String(format: "%.2f", Date().timeIntervalSince(closing))) s")
    }

    // MARK: §9.3 N3–N7 — tickets, observe failures, slow links

    @MainActor func testN_ticketsObserveFailuresAndSlowLinks() throws {
        launch()
        // N6: a refused ticket is retried once, then said.
        ctl(["tickets": ["reject": true]])
        openScreen()
        let ended = el("screen.ended.title")
        XCTAssertTrue(ended.waitForExistence(timeout: 25), "refused tickets end in the error state")
        XCTAssertEqual(ended.label, "Screen Stopped")
        XCTAssertLessThanOrEqual(calls("display.observe").count, 2, "one re-observe, no loop")
        pause(3)
        XCTAssertLessThanOrEqual(calls("display.observe").count, 2)
        ctl(["tickets": ["reject": false]])
        app.buttons["screen.reconnect"].tap()
        waitLive()
        closeScreen()

        // N7: a failing observe is said with the gateway's words and no socket is dialled.
        try account.control("/__fixture/screen/reset", [:])
        ctl(["fail": ["display.observe": "Bot Desktop viewer could not be prepared"]])
        openScreen()
        XCTAssertTrue(ended.waitForExistence(timeout: 25))
        let words = text("screen.ended") + " " + text("screen.error")
        XCTAssertTrue(words.contains("Bot Desktop viewer could not be prepared"), "the reason is shown: \(words)")
        XCTAssertEqual(sockets().count, 0, "no socket was dialled")
        ctl(["fail": ["display.observe": NSNull()]])
        app.buttons["screen.reconnect"].tap()
        waitLive()
        closeScreen()

        // N2: a slow link that keeps delivering is never called stuck.
        try account.control("/__fixture/screen/reset", [:])
        ctl(["stream": ["throttle_kbps": 256, "delay_ms": 300]])
        openScreen()
        XCTAssertTrue(el("screen.connecting").exists || el("screen.attaching").exists || value("frames") >= 1)
        XCTAssertTrue(waitUntil(timeout: 90) { self.value("frames") >= 1 }, "the first picture arrives, slowly (\(debugValue()))")
        XCTAssertFalse(ended.exists)
        XCTAssertEqual(sockets().count, 1, "no stuck-stream restart while bytes keep coming")
        let closing = Date()
        closeScreen()
        XCTAssertLessThan(Date().timeIntervalSince(closing), 6, "Close is instant on a slow link")

        // N1: one byte per WebSocket frame draws the same picture.
        try account.control("/__fixture/screen/reset", [:])
        ctl(["mode": "linux", "stream": ["chunk": 7, "fps": 3, "encoding": "tight-basic"]])
        openScreen()
        XCTAssertTrue(waitUntil(timeout: 40) { self.value("frames") >= 2 }, debugValue())
        var got = "", want = ""
        XCTAssertTrue(waitUntil(timeout: 15) {
            want = ((try? self.account.control("/__fixture/screen/expect"))?["probe"] as? String) ?? "-"
            got = self.field("probe", in: self.debugValue())
            return got == want
        }, "7-byte frames: \(got) vs \(want)")
        closeScreen()
        alive("the network cases")
    }

    // MARK: §9.3 N5 — the gateway connection drops again and again while in control

    @MainActor func testN5_gatewaySocketDropsWhileInControl() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        for round in 1...6 {
            let old = lease()["viewer_hash"] as? String
            ctl(["drop_ws": true])
            XCTAssertTrue(waitUntil(timeout: 30) {
                let now = self.lease()
                return now["holder"] as? String == "human" && (now["viewer_hash"] as? String) != old && self.caption() == "You are in control"
                    && self.value("frames") >= 1
            }, "round \(round): control kept on the new connection (\(lease()), \(caption()))")
            pause(2)
        }
        let seen = ledger()
        XCTAssertEqual(int(seen["max_open_sockets"]), 1, "never two display sockets")
        let log = (seen["lease_log"] as? [[String: Any]]) ?? []
        XCTAssertFalse(log.dropFirst().contains { $0["holder"] as? String == "agent" }, "the bot never got the lease in between")
        let mark = inputs().count
        movePointer(dy: 30)
        XCTAssertTrue(waitUntil(timeout: 5) { self.inputs().count > mark }, "input still lands after six reconnects")
    }

    // MARK: §9.4 — bad data from the display socket

    @MainActor func testD_badDataNeverCrashes() throws {
        launch()
        let fatal = ["bad-version", "security-none-missing", "security-failed", "zero-size", "huge-size", "rect-outside", "unknown-encoding",
                     "unknown-message", "zlib-garbage", "zlib-truncated", "jpeg-garbage-3", "palette-zero", "copyrect-outside", "cut-text-huge",
                     "text-frame"]
        let ended = el("screen.ended.title")
        var slow: [String] = []
        for name in fatal {
            try account.control("/__fixture/screen/reset", [:])
            // The cases inside Tight Basic rects need a screen that sends them.
            let linux = ["zlib-garbage", "zlib-truncated", "palette-zero", "copyrect-outside"].contains(name)
            ctl(["mode": linux ? "linux" : "mac", "stream": ["garbage": name]])
            openScreen()
            let began = Date()
            XCTAssertTrue(ended.waitForExistence(timeout: 40), "\(name): the viewer says the stream ended (\(debugValue()))")
            if Date().timeIntervalSince(began) > 20 { slow.append(name) }
            XCTAssertEqual(ended.label, "Screen Stopped", name)
            XCTAssertTrue(app.buttons["screen.reconnect"].exists, name)
            alive(name)
            ctl(["stream": ["garbage": NSNull()]])
            app.buttons["screen.reconnect"].tap()
            XCTAssertTrue(waitUntil(timeout: 25) { self.value("frames") >= 1 }, "\(name): Reconnect works once the data is good")
            closeScreen()
        }
        note("bad data: \(fatal.count) fatal cases ended plainly; slow to end: \(slow)")

        // The recoverable ones keep streaming.
        for name in ["jpeg-garbage", "trailing-bytes", "colour-map-huge", "never-ending-update", "tight-length-overflow"] {
            try account.control("/__fixture/screen/reset", [:])
            ctl(["stream": ["garbage": name]])
            openScreen()
            pause(6)
            let streaming = value("frames") >= 1 && !ended.exists
            note("\(name): \(streaming ? "kept streaming" : "ended plainly") (\(debugValue()))")
            XCTAssertTrue(streaming || ended.exists, "\(name): never a blank screen")
            // A stream that stopped moving (the declared length never arrives) is not left hanging: the watchdog
            // starts a new socket, and a second stall says "Screen Stopped".
            let seen = value("frames"), socketsBefore = sockets().count
            pause(3)
            if !ended.exists, value("frames") == seen {
                let waiting = Date()
                XCTAssertTrue(waitUntil(timeout: 45) { ended.exists || self.sockets().count > socketsBefore || self.value("frames") > seen },
                              "\(name): a stalled stream is restarted or ended (\(debugValue()))")
                note("\(name): stalled, then \(ended.exists ? "ended plainly" : "restarted by itself") after \(String(format: "%.0f", Date().timeIntervalSince(waiting) + 9)) s")
            }
            alive(name)
            ctl(["stream": ["garbage": NSNull()]])
            if ended.exists { app.buttons["screen.reconnect"].tap() }
            XCTAssertTrue(waitUntil(timeout: 25) { self.value("frames") >= 1 }, name)
            closeScreen()
        }
    }

    // MARK: §9.5 I4 — Close during every wait

    @MainActor func testI4_closeDuringEveryWait() throws {
        launch()
        // During the status.
        ctl(["status_delay_ms": 4000])
        openScreen()
        pause(0.5)
        closeScreen()
        ctl(["status_delay_ms": 0])
        // During observe, the dial and the first frame.
        for delay in [1500, 600, 200] {
            ctl(["rpc_delay_ms": delay])
            openScreen()
            pause(Double(delay) / 1000 * 0.6 + 0.3)
            closeScreen()
        }
        ctl(["rpc_delay_ms": 0, "stream": ["delay_ms": 1500]])
        openScreen()
        pause(1)
        closeScreen()
        ctl(["stream": ["delay_ms": 0]])
        pause(2)
        XCTAssertEqual(int(ledger()["open_sockets"]), 0, "no socket outlives its Screen")
        XCTAssertEqual(lease()["holder"] as? String, "agent")

        // During the acquire: one that lands after Close is given back.
        openScreen()
        waitLive()
        let take = app.buttons["screen.take"]
        XCTAssertTrue(waitUntil(timeout: 20) { take.isEnabled })
        ctl(["rpc_delay_ms": 2500])
        take.tap()
        pause(0.4)
        closeScreen()
        ctl(["rpc_delay_ms": 0])
        XCTAssertTrue(waitUntil(timeout: 15) { self.lease()["holder"] as? String == "agent" && self.int(self.ledger()["open_sockets"]) == 0 },
                      "an acquire that landed after Close was released (\(lease()))")
        // During the start.
        ctl(["mode": "off", "rpc_delay_ms": 2500])
        openScreen()
        XCTAssertTrue(app.buttons["screen.start"].waitForExistence(timeout: 15))
        app.buttons["screen.start"].tap()
        pause(0.4)
        closeScreen()
        ctl(["rpc_delay_ms": 0])
        pause(3)
        XCTAssertEqual(int(ledger()["open_sockets"]), 0)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no late alert on the Bots list")
        XCTAssertFalse(el("screen.pill.taken").exists || el("screen.hint.gestures").exists, "no late pill either")
        alive("closing during every wait")
    }

    // MARK: §9.5 I9 — the lease changes hands at random while the phone asks for it

    @MainActor func testI9_leaseChurn() throws {
        launch()
        openScreen()
        waitLive()
        let take = app.buttons["screen.take"], give = app.buttons["screen.give"], force = app.buttons["screen.force"]
        let reconnect = app.buttons["screen.reconnect"]
        let until = Date().addingTimeInterval(45)
        var round = 0
        while Date() < until {
            round += 1
            ctl(round % 3 == 0 ? ["agent_takes": true] : ["other_takes": true])
            pause(Double.random(in: 0.6...1.6))
            if reconnect.exists { pause(2); reconnect.tap() }
            else if take.exists, take.isEnabled, take.isHittable { take.tap() }
            else if round % 4 == 0, force.exists, force.isHittable { force.tap() }
            else if round % 5 == 0, give.exists, give.isHittable { give.tap() }
        }
        alive("\(round) rounds of lease churn")
        ctl(["agent_takes": true])
        pause(11)
        if reconnect.exists { reconnect.tap() }
        waitLive()
        // The caption tells the truth about the lease.
        XCTAssertTrue(waitUntil(timeout: 8) {
            let holder = self.lease()["holder"] as? String
            let line = self.caption()
            return holder == "agent" ? self.botInControl() : (line == "You are in control" || line == "Another viewer is in control")
        }, "caption \(caption()) for lease \(lease())")
        XCTAssertTrue(waitUntil(timeout: 8) { take.exists && take.isEnabled }, "no stuck spinner: Take over is offered again")
        takeOver()
        XCTAssertEqual(lease()["holder"] as? String, "human")
        XCTAssertEqual(int(ledger()["max_open_sockets"]), 1)
    }

    // MARK: §9.5 I3 — rotation in every mode

    @MainActor func testI3_rotateEverywhere() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        movePointer(dx: 60, dy: 80)
        let at = pointer()
        let stage = el("screen.stage")
        for (index, orientation) in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait].enumerated() {
            if index == 1 { stage.pinch(withScale: 2, velocity: 2) }
            if index == 2 { app.buttons["screen.keyboard.toggle"].tap() }
            XCUIDevice.shared.orientation = orientation
            pause(1.5)
            alive("rotation \(index)")
            let now = pointer()
            XCTAssertEqual([now.x, now.y], [at.x, at.y], "the pointer does not move when the phone turns")
            XCTAssertGreaterThanOrEqual(value("zoom"), 1)
        }
        XCTAssertEqual(caption(), "You are in control")
        closeScreen()

        ctl(["mode": "unsupported", "shots": ["seed": 2]])
        openScreen()
        XCTAssertTrue(el("screenshots.frame.shown").waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(1.5)
        XCTAssertTrue(el("screenshots.heading").exists, "the latest screenshots survive a turn")
        XCUIDevice.shared.orientation = .portrait
        pause(1)
        closeScreen()
        XCTAssertLessThan(app.cells["bot-row-default"].frame.width, 500, "portrait again after Close")
    }
}
