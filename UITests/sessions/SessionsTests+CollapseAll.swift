// [sessions-collapse] Every section on the Sessions page folds, in every view (owner 2026-11-11: "I want to be able to
// collapse all of the categories on the sessions page for every view"). Group By Recent: Pinned, "Projects" (every
// project at once, to one closed "Projects" header) and Recent; kept across launches.

import XCTest

extension SessionsTests {
    /// The open "Projects" caption over the first project (a tap closes every project).
    @MainActor func projectsCaption(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["sessions.projects.caption"].firstMatch
    }

    @MainActor func test99_RecentSectionsAllFold() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-release").waitForExistence(timeout: 15), "the pinned chat")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "collapse-all-1-open")

        // Pinned closes to its name, count and chevron (no See All under it).
        let pinned = header(app, "Pinned")
        XCTAssertTrue(pinned.waitForExistence(timeout: 5))
        pinned.tap()
        XCTAssertTrue(waitUntil(5) { !self.row(app, "s-release").exists }, "Pinned closed")
        XCTAssertTrue((header(app, "Pinned").value as? String)?.hasPrefix("Collapsed") == true, "\(header(app, "Pinned").value ?? "")")
        XCTAssertFalse(app.buttons["sessions.seeAll.pinned"].exists, "no See All on a closed Pinned")

        // "Projects" closes every project to one header.
        let caption = projectsCaption(app)
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "the Projects caption")
        // On the word itself (the element's frame reaches up into the break above it).
        caption.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.75)).tap()
        let projects = header(app, "Projects")
        XCTAssertTrue(waitUntil(5) { projects.exists && (projects.value as? String)?.hasPrefix("Collapsed") == true },
                      "Projects closed (\(headers(app)))")
        XCTAssertFalse(headers(app).contains { $0.hasPrefix("Website") }, "no project rows under a closed Projects")
        XCTAssertTrue(projects.label.contains("project"), "it counts projects: \(projects.label)")

        // Recent closes too.
        let recent = header(app, "Recent")
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        XCTAssertTrue(waitUntil(5) { (self.header(app, "Recent").value as? String)?.hasPrefix("Collapsed") == true }, "Recent closed")
        XCTAssertTrue(waitUntil(5) { self.order(app).isEmpty }, "no rows left (\(order(app)))")
        shot(app, "collapse-all-2-closed")

        // Kept across launches.
        app.terminate()
        let again = launch(keepView: true)
        XCTAssertTrue(header(again, "Recent").waitForExistence(timeout: 15))
        XCTAssertTrue((header(again, "Pinned").value as? String)?.hasPrefix("Collapsed") == true)
        XCTAssertTrue((header(again, "Projects").value as? String)?.hasPrefix("Collapsed") == true)
        XCTAssertTrue((header(again, "Recent").value as? String)?.hasPrefix("Collapsed") == true)

        // Each opens again.
        header(again, "Projects").tap()
        XCTAssertTrue(projectsCaption(again).waitForExistence(timeout: 5), "Projects open again")
        header(again, "Pinned").tap()
        XCTAssertTrue(row(again, "s-release").waitForExistence(timeout: 5), "Pinned open again")
        header(again, "Recent").tap()
        XCTAssertTrue(waitUntil(5) { (self.header(again, "Recent").value as? String)?.hasPrefix("Expanded") == true }, "Recent open again")
    }
}
