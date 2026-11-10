// iPad background crash (TestFlight feedback 2026-10-23: "When backgrounded on iPad, the app crashes almost every
// single time"; a tester's logs 2026-10-24, build 337: 46 of 46 trips home with a chat in the right pane ended the
// app). A real iPad narrows the window for its app-switcher snapshots as the app leaves, which moves the open chat
// from the right pane onto its list and back; the simulator doesn't, so `-HQDebugSnapshotResize` replays it. Opens a
// chat in the right pane, sends the app home a few times (on its list and with a chat open, in both orientations) and
// checks the process the test launched is the one still running, with its chat still answering.

import XCTest

final class IPadBackgroundTests: IPadTestCase {
    @MainActor func testBackgroundingKeepsTheAppRunning() throws {
        guard IPad.isPad else { throw XCTSkip("iPad only") }
        let app = IPad.launch(try IPad.account(.perf), arguments: ["-HQDebugSnapshotResize", "YES"])
        let pid = IPadTestCase.launchedPid
        func roundTrip(_ label: String, chat: Bool) {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended, "\(label): went to the background")
            Thread.sleep(forTimeInterval: 8)
            XCTAssertNotEqual(app.state, .notRunning, "\(label): still running in the background")
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "\(label): came back")
            XCTAssertEqual(app.value(forKey: "processID") as? Int32, pid, "\(label): same process (no crash and relaunch)")
            if chat { XCTAssertTrue(IPad.table(app).waitForExistence(timeout: 5), "\(label): the chat is still on show") }
            XCTAssertTrue(app.descendants(matching: .any)["pane.detail"].waitForExistence(timeout: 5), "\(label): two panes again")
        }
        roundTrip("list", chat: false)
        _ = IPad.openBot(app)
        roundTrip("chat open", chat: true)
        // The tester had been typing: the composer has the keyboard as the app leaves.
        let field = IPad.field(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer shows")
        field.tap()
        field.typeText("a draft")
        roundTrip("chat open, composer focused", chat: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        roundTrip("chat open, landscape", chat: true)
        XCUIDevice.shared.orientation = .portrait
        roundTrip("chat open, portrait again", chat: true)
    }
}
