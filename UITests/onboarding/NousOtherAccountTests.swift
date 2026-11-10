// [nous-different-account] Use Another Nous Account under Sign in with Nous (tester 2026-11-02: "I signed
// into the wrong nous account in app and I can't seem to clear cookies to sign into the right one"). The demo sign-in
// screen (fake driver, no gateway): an address with "nous" offers Nous only, and "notowner" is turned away.
// TEST_RUNNER_HQN_SHOTS=<dir> keeps the screenshots.

import XCTest

final class NousOtherAccountTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor override func tearDown() async throws { a11yQuit() }

    @MainActor func testN1_linkSitsUnderSignInWithNousAndTheRefusalPointsAtIt() {
        for dark in [false, true] {
            let app = a11yLaunch(["-HQDemoSignIn", "-HQDemoAddress", "notowner-nous.example"], dark: dark)
            let nous = app.buttons["sign-in-nous"]
            XCTAssertTrue(nous.waitForExistence(timeout: 30), "Sign in with Nous shows for a Nous-only address")
            let link = app.buttons["sign-in-nous-other"]
            XCTAssertTrue(link.exists, "Use Another Nous Account is there")
            XCTAssertEqual(link.label, "Use Another Nous Account")
            XCTAssertGreaterThanOrEqual(link.frame.minY, nous.frame.maxY - 1, "the link is under the button")
            XCTAssertGreaterThanOrEqual(link.frame.height, 36)
            a11yShot(app, "nous-other-account-\(dark ? "dark" : "light")")

            nous.tap()
            let refusal = app.descendants(matching: .any)["sign-in-error"]
            XCTAssertTrue(refusal.waitForExistence(timeout: 10), "the fake gateway turns the account away")
            XCTAssertTrue(refusal.label.contains("Use Another Nous Account"), "the words name the link: \(refusal.label)")
            XCTAssertTrue(link.isHittable, "the link stays reachable under the refusal")
            a11yShot(app, "nous-other-account-refused-\(dark ? "dark" : "light")")
            a11yQuit(app)
        }
    }
}
