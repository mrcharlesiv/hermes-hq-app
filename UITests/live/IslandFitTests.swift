// [island-fit] The Dynamic Island's small views, photographed in every shape they take: a reply's, a job's and Talk's
// timers at each length (0:05, 16:10, 1:02:05, 12:00:00), over, and beside another app's activity ("twin",
// TestSupport/IslandTwin: each then gets the small round view). The app puts them there itself (`-HQDebugIsland`, App/Debug/IslandDebugHook.swift): no gateway, no sign-in.
// Run: scripts/island-shots.sh [SIM_UDID] — shots land in .build/island (HQN_SHOTS); look at each one's top strip.
// HQN_ISLAND_SPECS="turn:970;turn:970,talk:30" runs only those.

import XCTest

final class IslandFitTests: XCTestCase {
    static let specs = [
        "turn:5", "turn:970", "turn:3725", "turn:43200", "job:970", "job:3725", "done:970", "done:45296", "failed:970",
        "talk:5", "talk:970", "talk:3725", "talkended:970",
        "twin,turn:970", "turn:970,twin", "twin,talk:970", "turn:970,talk:30",
    ]

    @MainActor func testIslandShapes() {
        let env = ProcessInfo.processInfo.environment
        let asked = env["HQN_ISLAND_SPECS"].map { $0.split(separator: ";").map(String.init) } ?? []
        for spec in asked.isEmpty ? Self.specs : asked {
            // "twin": another app's activity shares the island (TestSupport/IslandTwin starts one of its own at
            // launch): first in the list, it was there before ours; last, it came after. Otherwise it has none.
            let twin = XCUIApplication(bundleIdentifier: "com.example.islandtwin")
            let parts = spec.split(separator: ",")
            twin.launchArguments = parts.first == "twin" ? [] : ["-HQTwinEnd", "YES"]
            twin.launch()
            Thread.sleep(forTimeInterval: parts.first == "twin" ? 5 : 2)
            let app = XCUIApplication()
            app.launchArguments += ["-HQDebugIsland", spec]
            app.launch()
            Thread.sleep(forTimeInterval: 6)       // the hook starts them 2 s after the app is in front
            if parts.count > 1, parts.last == "twin" {
                twin.launchArguments = []
                twin.launch()
                Thread.sleep(forTimeInterval: 5)
            }
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 8)       // a new one blooms wide first
            let name = "island-" + spec.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: ",", with: "+")
            save(name)
            // Held, the island opens to its expanded view; Notification Center lists the card as the Lock Screen does.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.027)).press(forDuration: 1.2)
            Thread.sleep(forTimeInterval: 1.5)
            save(name + "-open")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
            Thread.sleep(forTimeInterval: 1)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.005))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
            let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Always Allow"])).firstMatch
            if allow.waitForExistence(timeout: 2) { allow.tap() }
            Thread.sleep(forTimeInterval: 1.5)
            save(name + "-lock")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            Thread.sleep(forTimeInterval: 1)
            app.terminate()
        }
    }

    @MainActor private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
