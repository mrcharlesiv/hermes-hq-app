// The desktop's motion on a running turn (owner: "make sure the animations in our app match the code in the desktop
// app"): the running tool's `breathe` spinner and shimmering title, the streaming code card's glow. A held turn — a
// thought, a tool still running, half a code block — keeps moving while nothing new arrives; shots in both looks.

import XCTest

extension ActivityEndToEndTests {
    nonisolated(unsafe) static let heldTurnPlan: [String: Any] = {
        let events: [[String: Any]] = [
            ["type": "reasoning.delta", "payload": ["text": "Checking the gateway first."]],
            ["after": 1, "type": "tool.start", "payload": ["tool_id": "call_t1", "name": "terminal", "args": ["command": "tail -n 40 gateway.log"]]],
            ["after": 0.5, "type": "message.delta", "payload": ["text": "Run this to check it:\n\n```sh\nhermes gateway status --verbose\n"]],
            ["after": 30, "type": "tool.complete", "payload": ["tool_id": "call_t1", "name": "terminal", "args": ["command": "tail -n 40 gateway.log"], "result": ["output": "ok"], "duration_s": 30]],
            ["type": "message.delta", "payload": ["text": "```\n"]],
        ]
        return ["holdAfter": 0.5, "events": events]
    }()

    @MainActor private func heldTurn(_ name: String) throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/plan", ["plans": [Self.heldTurnPlan]])
        let app = launchAndSend(account, "Is the gateway up?")
        XCTAssertTrue(labelled(app, containing: "hermes gateway status").waitForExistence(timeout: 10), "the code card streams in")
        Thread.sleep(forTimeInterval: 1)
        let table = app.tables["chat.table"]
        let first = table.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.45)
        XCTAssertNotEqual(first, table.screenshot().pngRepresentation, "the running turn moves while nothing new arrives")
        shot("desktop-motion-\(name)")
    }

    /// Dark: `HQN_E2E_APPEARANCE=dark HQN_E2E_ONLY=test40_DesktopMotionOnARunningTurn scripts/e2e-activity.sh`.
    @MainActor func test40_DesktopMotionOnARunningTurn() throws { try heldTurn("turn") }

    /// Before anything arrives: the desktop's dither square, the shimmering words and its "0s" timer (no three dots).
    @MainActor func test42_WaitingRowIsTheDesktopsDitherSquare() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        // test40's held turn (a 30 s step) can still be running on the shared fixture: end it, or this send only queues.
        _ = try account.control("/__fixture/finish", ["profile": "default"])
        try account.control("/__fixture/plan", ["plans": [["holdAfter": 0.5, "events": [
            ["after": 20, "type": "message.delta", "payload": ["text": "Here."]]]]]])
        let app = launchAndSend(account, "Are you there?")
        XCTAssertTrue(waitUntil(timeout: 8) { app.tables["chat.table"].staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+s'")).count > 0 }
                      || app.tables["chat.table"].cells.matching(NSPredicate(format: "label BEGINSWITH 'Waiting'")).count > 0, "the waiting row shows")
        Thread.sleep(forTimeInterval: 2.5)
        shot("waiting-dither")
    }
}
