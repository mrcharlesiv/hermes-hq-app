import XCTest

/// [updates] A row of an opened update card opens on a tap and folds on a second (owner, 2026-10-29: "I can't click
/// on the 'from Otto' messages. When I do. Nothing happens." The row's link recognizer cancelled every tap).
final class UpdateMemberTapTests: XCTestCase {
    @MainActor func testTapOpensAndFoldsAMember() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDemoChat", "1", "-HQDemoAutoOpen", "-HQDemoBotExchange", "-HQDemoOpenGroups"]
        app.launch()
        let members = app.descendants(matching: .any).matching(identifier: "chat.update.member")
        XCTAssertTrue(members.firstMatch.waitForExistence(timeout: 15))
        let member = try XCTUnwrap((0..<members.count).lazy.map { members.element(boundBy: $0) }.first { $0.isHittable })
        let label = member.label
        let same = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertEqual(same.value as? String, "Collapsed")
        let closed = same.frame.height
        same.tap()
        XCTAssertTrue(waitFor(same, "Expanded"))
        XCTAssertGreaterThan(same.frame.height, closed)
        same.tap()
        XCTAssertTrue(waitFor(same, "Collapsed"))
    }

    private func waitFor(_ element: XCUIElement, _ value: String) -> Bool {
        let done = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        return XCTWaiter().wait(for: [done], timeout: 5) == .completed
    }
}
