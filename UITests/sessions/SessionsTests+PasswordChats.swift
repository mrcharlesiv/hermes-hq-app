// A chat the old password sign-in made (Hermes stamps it `basic:<username>`, next-20-20 B8): Hermes refuses every
// other sign-in's edit with a bare `permission_denied`, and the failure alert says whose chat it is and what to do
// (SessionActionText.refusedPasswordChat), in both looks. The fixture refuses such rows as Hermes does.

import XCTest

extension SessionsTests {
    /// Archive and Delete on a `basic:fleet` chat: each "Couldn’t …" alert names the old password sign-in and the way
    /// out; the row stays. Another chat's refusal keeps the general words.
    @MainActor func test98_PasswordChatRefusalSaysWhy() throws {
        try passwordChatRound(launch(), "standard")
    }

    @MainActor func test99_PasswordChatRefusalSaysWhyInDesktopLook() throws {
        try passwordChatRound(launch(extra: ["-HQDebugDesktopLook", "YES"]), "desktop")
    }

    @MainActor private func passwordChatRound(_ first: XCUIApplication, _ look: String) throws {
        first.terminate()
        setRow("s-recipes", ["user_id": "basic:fleet"])
        setRow("s-trip", ["user_id": "nous:someone-else"])
        fixture("/__fixture/fail", ["method": "PATCH", "path": "/api/sessions/s-trip", "status": 403, "detail": "permission_denied", "count": 1])
        let app = launch(extra: look == "desktop" ? ["-HQDebugDesktopLook", "YES"] : [])
        let recipes = row(app, "s-recipes")
        XCTAssertTrue(recipes.waitForExistence(timeout: 15))

        swipe(recipes, left: true)
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 3))
        app.buttons["Archive"].tap()
        let archive = app.alerts["Couldn’t Archive Chat"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "Hermes's refusal comes back as an alert")
        let words = archive.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(words.contains { $0.hasPrefix("Only the old password sign-in can change this chat") && $0.contains("Settings › Notifications") },
                      "it says whose chat it is and what to do (\(words))")
        shot(app, "B8-archive-refused-\(look)")
        XCTAssertTrue(writes("PATCH", "/api/sessions/s-recipes").contains { $0["archived"] as? Bool == true }, "the archive was sent")
        XCTAssertFalse(words.contains { $0.hasSuffix("…") }, "shown whole")
        archive.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(5) { !archive.exists })
        XCTAssertTrue(row(app, "s-recipes").waitForExistence(timeout: 8), "the row comes back")

        swipe(row(app, "s-recipes"), left: true)
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Delete Chat"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        let delete = app.alerts["Couldn’t Delete Chat"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        XCTAssertTrue(delete.staticTexts.allElementsBoundByIndex.map(\.label).contains { $0.hasPrefix("Only the old password sign-in can change this chat") })
        shot(app, "B8-delete-refused-\(look)")
        delete.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(5) { !delete.exists })
        XCTAssertTrue(row(app, "s-recipes").waitForExistence(timeout: 8), "nothing was deleted")
        XCTAssertFalse(writes("DELETE", "/api/sessions/s-recipes", any: true).isEmpty, "the delete was sent")

        // Another sign-in's chat: the general words (update the add-on), not the password ones.
        let trip = row(app, "s-trip")
        XCTAssertTrue(trip.waitForExistence(timeout: 8))
        swipe(trip, left: true)
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 3))
        app.buttons["Archive"].tap()
        let other = app.alerts["Couldn’t Archive Chat"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        let otherWords = other.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(otherWords.contains { $0.hasPrefix("Hermes says this chat belongs to another sign-in") }, "\(otherWords)")
        XCTAssertFalse(otherWords.contains { $0.contains("old password") })
        other.buttons["OK"].tap()
    }
}
