import XCTest

/// [tap-out] With the keyboard up, a tap on the transcript gives a tick and closes the keyboard; a tap on the
/// message box itself leaves it up (the owner, 2026-11-11).
final class KeyboardTapOutTests: XCTestCase {
    @MainActor func testTapOutsideTicksThenClosesKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDemoChat", "20", "-HQDemoAutoOpen", "-HQDebugHapticsProbe", "YES"]
        app.launch()
        let box = app.textViews["composer.text"]
        XCTAssertTrue(box.waitForExistence(timeout: 15), "the chat opens")
        box.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard comes up")
        Thread.sleep(forTimeInterval: 1)

        // A tap in the box keeps the keyboard up and plays nothing.
        let before = count(app)
        box.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "a tap in the box keeps the keyboard")
        XCTAssertEqual(count(app), before, "no tick for a tap in the box")

        // A tap on the transcript: one tick, keyboard gone.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the keyboard closes")
        XCTAssertGreaterThan(count(app), before, "the tap out ticks")
    }

    @MainActor private func count(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["debug.haptics"]
        guard probe.waitForExistence(timeout: 5), let value = probe.value as? String,
              let n = value.split(separator: " ").first?.split(separator: "=").last.flatMap({ Int($0) }) else { return -1 }
        return n
    }
}
