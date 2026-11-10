// [sessions-m9] The row's Row Detail figures, metadata, status words and its pending line (docs/spec/3x-sessions.md
// §9; acceptance E1-E7), against scripts/fixtures/sessions-gateway.py. What the row draws is read through its one
// VoiceOver label ("<Title>. <status>. <Owner>: <detail>. <figures and time>. Unread. Pinned."); the colours and the
// layout are in the screenshots.

import XCTest

extension SessionsTests {
    /// E1: with the default Row Detail the row reads as it did: title, owner and preview, the time; no figures.
    @MainActor func test50_DefaultRowIsUnchanged() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        let words = labelOf(garden)
        XCTAssertTrue(words.hasPrefix("Garden plan. Hermes: Tomatoes along the south fence, basil between them, and beans on the trellis.. "), words)
        XCTAssertFalse(words.contains("tokens") || words.contains("$"), "no figures by default (\(words))")
        XCTAssertEqual(words.components(separatedBy: ". ").count, 3, "title, owner and preview, the time (\(words))")
        let release = labelOf(row(app, "s-release"))
        XCTAssertTrue(release.hasSuffix("Pinned"), release)
        XCTAssertTrue(labelOf(row(app, "s-budget")).hasSuffix("Unread"), labelOf(row(app, "s-budget")))
        XCTAssertGreaterThanOrEqual(garden.frame.height, 72, "the row keeps its 72 pt minimum")
        XCTAssertFalse(app.buttons["session-menu-s-garden"].exists, "no ⋯: the long press and the swipes hold the menu")
        shot(app, "E1-default-rows")
    }

    /// E2, E3: Tokens and Cost on: "1.2k · $0.02 · time" on Garden plan; a sub-cent chat shows tokens and no cost; a
    /// chat without tokens shows the time alone. Preview off: the metadata line.
    @MainActor func test51_TokensCostAndMetadata() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "detail", "detail.tokens", "detail.cost")
        closeFilter(app)
        XCTAssertTrue(waitUntil(5) { self.labelOf(garden).contains("1.2k tokens. $0.02. ") }, "tokens, cost, then the time (\(labelOf(garden)))")
        let budget = labelOf(row(app, "s-budget"))
        XCTAssertTrue(budget.contains("999 tokens. ") && !budget.contains("$"), "below a cent the row says nothing of cost (\(budget))")
        let recipes = labelOf(row(app, "s-recipes"))
        XCTAssertFalse(recipes.contains("tokens") || recipes.contains("$"), "no tokens: the time alone (\(recipes))")
        XCTAssertTrue(labelOf(row(app, "s-trip")).contains("15.4k tokens. $0.34. "), labelOf(row(app, "s-trip")))
        XCTAssertTrue(labelOf(row(app, "s-release")).contains("1.5M tokens. $12.50. "), labelOf(row(app, "s-release")))
        shot(app, "E2-tokens-cost")

        // Time off: the figures alone.
        openFilter(app)
        tapFilter(app, "detail", "detail.time")
        closeFilter(app)
        XCTAssertTrue(waitUntil(5) { self.labelOf(garden).hasSuffix("1.2k tokens. $0.02") }, labelOf(garden))
        shot(app, "E2-figures-without-time")

        // E3: Preview off.
        openFilter(app)
        tapFilter(app, "detail", "detail.preview")
        closeFilter(app)
        XCTAssertTrue(waitUntil(5) { self.labelOf(garden).contains("Hermes: main · hermes-4 · 2 messages. ") }, labelOf(garden))
        XCTAssertTrue(labelOf(row(app, "s-release")).contains("Deploys: hermes-4 · 3 messages · 1 tool call"), labelOf(row(app, "s-release")))
        shot(app, "E3-metadata")

        // Nothing of the three: title, owner and metadata only.
        openFilter(app)
        tapFilter(app, "detail", "detail.tokens", "detail.cost")
        closeFilter(app)
        XCTAssertTrue(waitUntil(5) { self.labelOf(garden) == "Garden plan. Hermes: main · hermes-4 · 2 messages" }, labelOf(garden))
        openFilter(app)
        XCTAssertTrue(filterWords(app, "detail").contains("None"), filterWords(app, "detail"))
        shot(app, "E3-row-detail-none")
    }

    /// E4: unread: the badge and the word; a chat waiting on the user: "Needs your input", ahead of everything else.
    @MainActor func test52_UnreadAndNeedsInput() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertTrue(labelOf(row(app, "s-budget")).hasSuffix("Unread"))
        XCTAssertFalse(labelOf(row(app, "s-garden")).contains("Unread"))
        shot(app, "E4-unread")
        // An approval waits in Garden plan.
        openChat(app, "s-garden")
        fixture("/__fixture/emit", ["request": ["method": "approval", "params": ["command": "rm -rf build", "description": "Remove the build folder"]],
                                    "session_id": "s-garden"])
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'rm -rf build'")).firstMatch
            .waitForExistence(timeout: 10), "the approval shows in the chat")
        shot(app, "E4-approval-in-chat")
        backToList(app)
        let garden = row(app, "s-garden")
        XCTAssertTrue(waitUntil(8) { self.labelOf(garden).contains("Needs your input") }, "the row says so (\(labelOf(garden)))")
        XCTAssertTrue(labelOf(garden).hasPrefix("Garden plan. Needs your input. "), "status words come second (\(labelOf(garden)))")
        shot(app, "E4-needs-input")
        openFilter(app)
        tapFilter(app, "status", "status.needs-input")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-garden"] }, "Status › Needs Input lists it (\(order(app)))")
        closeFilter(app)
        shot(app, "E4-needs-input-filter")
    }

    /// E5: text left in a chat's composer shows on its row as "Draft:"; Status › Draft lists it; clearing the text
    /// removes the line.
    @MainActor func test53_DraftLine() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        openChat(app, "s-garden")
        type(app, "call the plumber", send: false)
        backToList(app)
        XCTAssertTrue(waitUntil(6) { self.labelOf(garden).contains("Hermes: Draft: call the plumber") }, labelOf(garden))
        shot(app, "E5-draft")
        openFilter(app)
        tapFilter(app, "status", "status.draft")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-garden"] }, "Status › Draft lists it (\(order(app)))")
        closeFilter(app)
        XCTAssertEqual(strip(app).label, "Showing Draft. Clear Filters")
        shot(app, "E5-status-draft")
        strip(app).tap()
        XCTAssertTrue(waitUntil(6) { self.order(app).count == 5 })
        // Clearing the text removes the line.
        openChat(app, "s-garden")
        let field = app.textViews["composer.text"]
        XCTAssertEqual(field.value as? String, "call the plumber", "the draft is back in the composer")
        // Wherever the tap puts the caret, the words go one key at a time until none is left.
        field.tap()
        var seen: [String] = []
        func typed() -> String {                  // what is left of the words ("" once only the placeholder shows)
            let now = field.value as? String ?? ""
            return "call the plumber".hasPrefix(now) || "call the plumber".hasSuffix(now) ? now : ""
        }
        for _ in 0..<40 {
            let now = typed()
            seen.append(now)
            guard !now.isEmpty else { break }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            if seen.count > 2, seen[seen.count - 1] == seen[seen.count - 2] {          // the caret is at the start: to the end
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        XCTAssertEqual(typed(), "", "the field is empty (\(seen); now \(field.value as? String ?? "nil"))")
        shot(app, "E5-draft-cleared-in-chat")
        backToList(app)
        XCTAssertTrue(waitUntil(6) { !self.labelOf(garden).contains("Draft:") }, "no text, no line (\(labelOf(garden)))")
        XCTAssertTrue(labelOf(garden).contains("Hermes: Tomatoes"), "the preview is back (\(labelOf(garden)))")
    }

    /// E6: a send whose answer never came: the row says "Not Delivered:" ahead of a draft; a relaunch keeps it; the
    /// chat shows the bubble marked again; Delete removes the bubble and the line.
    @MainActor func test54_NotDeliveredLine() throws {
        fixture("/__fixture/fail", ["rpc": "prompt.submit", "drop": true])
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        openChat(app, "s-garden")
        type(app, "Order the cedar boards", send: true)
        let table = app.tables["chat.table"]
        let mark = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Delivery Unconfirmed'")).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 45), "the send is marked once the app is back on the gateway")
        shot(app, "E6-unconfirmed-in-chat")
        type(app, "and nails", send: false)                                // a draft as well
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(garden).contains("Hermes: Not Delivered: Order the cedar boards") },
                      "Not Delivered wins over the draft (\(labelOf(garden)))")
        XCTAssertFalse(labelOf(garden).contains("Draft:"))
        shot(app, "E6-not-delivered")
        Thread.sleep(forTimeInterval: 1.0)                                  // the 0.3 s write
        app.terminate()

        let again = launch(keepView: true)                                  // (a plain launch clears what the tests left)
        let row2 = row(again, "s-garden")
        XCTAssertTrue(row2.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(8) { self.labelOf(row2).contains("Hermes: Not Delivered: Order the cedar boards") },
                      "the relaunch keeps it (\(labelOf(row2)))")
        shot(again, "E6-not-delivered-relaunch")
        openChat(again, "s-garden")
        let table2 = again.tables["chat.table"]
        let bubble = table2.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'You said: Order the cedar boards'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the chat shows the message again")
        XCTAssertTrue(table2.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Delivery Unconfirmed'")).firstMatch
            .waitForExistence(timeout: 6), "with its mark")
        shot(again, "E6-bubble-restored")
        if again.keyboards.count > 0 { again.navigationBars.firstMatch.tap() }
        bubble.press(forDuration: 0.9)
        let delete = again.buttons["message.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the hold menu offers Delete")
        XCTAssertTrue(again.buttons["message.retry"].exists, "and Send Again")
        shot(again, "E6-hold-menu")
        delete.tap()
        XCTAssertTrue(waitUntil(6) { !bubble.exists }, "the bubble goes")
        backToList(again)
        XCTAssertTrue(waitUntil(8) { !self.labelOf(row2).contains("Not Delivered") }, "and the row's line with it (\(labelOf(row2)))")
        XCTAssertTrue(labelOf(row2).contains("Hermes: Draft: and nails"), "the draft is what is left (\(labelOf(row2)))")
        shot(again, "E6-after-delete")
    }

    /// E7: at the largest accessibility size the rows wrap and nothing is cut: the rows with figures and a pending
    /// line, the rail, the strip and the empty state (the screenshots are the check; the row must still say it all).
    @MainActor func test55_LargestTextSize() throws {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let release = row(app, "s-release")
        XCTAssertTrue(release.waitForExistence(timeout: 15))
        shot(app, "E7-ax5-default")
        openFilter(app)
        shot(app, "E7-ax5-menu")
        tapFilter(app, "detail", "detail.tokens", "detail.cost")
        closeFilter(app)
        XCTAssertTrue(waitUntil(5) { self.labelOf(release).contains("1.5M tokens. $12.50. ") }, labelOf(release))
        XCTAssertGreaterThan(release.frame.height, 120, "the row grows with the text (\(release.frame.height))")
        shot(app, "E7-ax5-figures")
        XCTAssertFalse(filterItem(app, "sort").exists || filterItem(app, "detail.time").exists, "the menu is closed")
        XCTAssertLessThanOrEqual(release.frame.maxX, app.frame.width, "the row stays on screen (\(release.frame))")
        // [sessions-layout] A pill: the 44 pt touch height at least, taller with the text.
        XCTAssertTrue(chip(app, "default").exists && chip(app, "default").frame.height >= 43.5, "\(chip(app, "default").frame)")
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        closeFilter(app)
        let token = strip(app)
        XCTAssertTrue(token.waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(token.frame.maxX, app.frame.width, "the strip stays on screen")
        XCTAssertGreaterThanOrEqual(token.frame.minX, 0)
        shot(app, "E7-ax5-strip")
        openFilter(app)
        tapFilter(app, "status", "status.needs-input")
        closeFilter(app)
        // The chips are wider at this size: the last one starts off the screen's edge, so the rail is scrolled to it.
        let rail = app.scrollViews["sessions.chips"]
        if chip(app, "deploys").frame.maxX > app.frame.width { rail.swipeLeft() }
        XCTAssertLessThanOrEqual(chip(app, "deploys").frame.maxX, app.frame.width, "the rail scrolls to its last chip")
        chip(app, "deploys").tap()
        XCTAssertTrue(waitUntil(4) { self.chip(app, "deploys").isSelected }, "Deploys is picked")
        XCTAssertTrue(app.staticTexts["No Matching Chats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sessions.empty.clear"].isHittable)
        shot(app, "E7-ax5-no-match")
    }
}
