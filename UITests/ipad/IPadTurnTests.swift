// [ipad-polish] Turns the simulator's iPad sideways or upright and leaves it that way, for screenshot tours of the
// two-pane layout in landscape (simctl has no rotate command, and iPadOS refuses an app's own request while its
// windows are resizable). Nothing is launched or checked:
//   xcodebuild … test -only-testing:HermesHQNativeUITests/IPadTurnTests/testTurnLandscape
//   xcodebuild … test -only-testing:HermesHQNativeUITests/IPadTurnTests/testTurnPortrait

import XCTest

final class IPadTurnTests: XCTestCase {
    @MainActor func testTurnLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor func testTurnPortrait() {
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
    }

    /// Drags the running app's window corner inward (iPadOS windowed apps), so the window is smaller than the screen and
    /// carries the system's window controls, then photographs it: `TEST_RUNNER_HQN_SHOTS_DIR/window-small.png`.
    /// `TEST_RUNNER_HQN_WINDOW_TO` = "0.75,0.8" is where the corner goes (a share of the screen).
    @MainActor func testShrinkWindow() throws {
        let app = XCUIApplication()
        guard app.state == .runningForeground else { throw XCTSkip("Launch the app first (simctl launch).") }
        let environment = ProcessInfo.processInfo.environment
        let to = (environment["HQN_WINDOW_TO"] ?? "0.75,0.8").split(separator: ",").compactMap { Double($0) }
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let corner = board.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995))
        let target = board.coordinate(withNormalizedOffset: CGVector(dx: to.first ?? 0.75, dy: to.last ?? 0.8))
        corner.press(forDuration: 0.4, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 2)
        if let folder = environment["HQN_SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder + "/window-small.png"))
        }
        print("IPAD-NOTE window after the drag: \(app.windows.firstMatch.frame)")
    }
}
