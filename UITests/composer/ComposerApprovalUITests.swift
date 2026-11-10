// [m9/composer] L422: the jump capsule "Approval needed" lands Run / Reject above the composer. Against the questions
// stand-in: HQN_COMPOSER_FIXTURE=questions scripts/e2e-composer.sh <udid> (it sets HQN_UI_QUESTIONS=1).

import XCTest

final class ComposerApprovalUITests: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["HQN_UI_QUESTIONS"] == "1" else { throw XCTSkip("Run with HQN_COMPOSER_FIXTURE=questions scripts/e2e-composer.sh") }
        account = try FixtureAccount.load()
        try account.control("/__fixture/reset", [:])
    }

    private func wait(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.25) }
        return cond()
    }

    @MainActor private func send(_ text: String) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        app.buttons["composer.send"].tap()
        if field.exists, let v = field.value as? String, v == text { app.buttons["composer.send"].tap() }
    }

    @MainActor func test1_JumpToApprovalLandsRunAndRejectAboveTheComposer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES"]
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username, "HQN_SIGNIN_PASSWORD": account.password]
        app.launch()
        self.app = app
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 20))
        app.cells["bot-row-default"].tap()
        let table = app.tables["chat.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        for i in 0..<5 {
            send("tell me about item number \(i)")
            XCTAssertTrue(wait(20) { !app.buttons["composer.stop"].exists }, "reply \(i) done")
        }
        send("please approve this")
        XCTAssertTrue(app.buttons["approval.run"].waitForExistence(timeout: 20), "the approval card shows")
        XCTAssertTrue(wait(5) { app.buttons["approval.run"].isHittable })
        XCTAssertFalse(app.buttons["jump.approval"].exists, "Run is in sight: no capsule")
        // Scroll away (to older messages) until the card is out of sight.
        for _ in 0..<6 { table.swipeDown(velocity: .fast) }
        let capsule = app.buttons["jump.approval"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 5), "the capsule shows when the approval is out of sight")
        XCTAssertEqual(capsule.label, "Approval needed")
        if let shots = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("composer-approval-capsule.png"))
        }
        capsule.tap()
        XCTAssertTrue(wait(5) { app.buttons["approval.run"].exists && app.buttons["approval.run"].isHittable }, "Run is on screen after the tap")
        let run = app.buttons["approval.run"], reject = app.buttons["approval.reject"]
        let field = app.textViews["composer.text"]
        XCTAssertLessThan(max(run.frame.maxY, reject.frame.maxY), field.frame.minY, "the buttons sit above the composer")
        XCTAssertTrue(wait(3) { !capsule.exists }, "the capsule is gone")
        if let shots = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("composer-approval-landed.png"))
        }
        run.tap()
        XCTAssertTrue(wait(10) { !app.buttons["approval.run"].exists }, "answering clears the card")
        XCTAssertFalse(app.buttons["jump.approval"].exists)
    }
}
