// Owner 2026-11-23: the Hermes HQ Discord card at the top of More (closes for good), and the Discord pill that stays
// beside Website and GitHub at More's foot (App/Pages/More/CommunityInvite.swift, `MoreLinksFooter`).

import XCTest

final class DiscordInviteUITests: MorePagesCase {
    @MainActor func testDiscordCardClosesAndTheFooterLinkStays() throws {
        launchSignedIn(["-HQDebugDiscordCard", "YES"])
        let card = revealMore("discord-invite")
        XCTAssertTrue(card.exists, "the Discord card heads More")
        let gateway = app.cells["more-row-gateway"]
        if gateway.exists { XCTAssertLessThan(card.frame.minY, gateway.frame.minY, "above the gateway card") }
        XCTAssertTrue(app.buttons["more.discord.join"].exists, "it has a Join button")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "bottom of More")).firstMatch.exists
                      || card.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "bottom of More")).firstMatch.exists,
                      "it says where the link stays")
        shot("discord-card")

        app.buttons["more.discord.close"].tap()
        XCTAssertTrue(waitUntil(5) { !app.cells["more-row-discord-invite"].exists }, "Close takes the card away")

        let link = app.buttons["more.link.discord"]
        for _ in 0..<12 where !link.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(link.exists && link.isHittable, "the Discord pill is at More's foot")
        XCTAssertTrue(app.buttons["more.link.website"].exists && app.buttons["more.link.github"].exists, "beside Website and GitHub")
        XCTAssertEqual(abs(link.frame.midY - app.buttons["more.link.github"].frame.midY) < 2, true, "on the same line")
        shot("discord-footer")

        // Closed is closed: a relaunch doesn't bring it back.
        relaunch()
        let bots = app.tabBars.buttons["Bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 15))
        tab("More")
        XCTAssertTrue(app.cells["more-row-gateway"].waitForExistence(timeout: 10) || app.cells["more-row-settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.cells["more-row-discord-invite"].exists, "the card stays closed after a relaunch")
    }
}
