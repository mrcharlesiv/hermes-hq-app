// Settings-stream end-to-end checks (docs/spec/1x-settings.md §13, S1–S34) against the settings fixture: the real app,
// real gestures, and the fixture's `/__settings/state` as the wire evidence. Run with scripts/e2e-settings.sh.

import XCTest

final class SettingsEndToEndTests: XCTestCase {
    var a: SettingsFixture!

    override func setUpWithError() throws {
        continueAfterFailure = false
        a = try SettingsFixture.load("HQN_SETTINGS_A")
        try a.control("/__settings/reset", [:])
    }

    // MARK: - S1 / S2 Pin and Unpin

    @MainActor func testS1S2_PinAndUnpinSam() throws {
        let app = launchSignedIn()
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        pressMenu(app, row, "Pin")
        XCTAssertTrue(app.cells["bot-tile-ivy"].waitForExistence(timeout: 3), "Ivy becomes a tile at once")
        XCTAssertTrue(waitUntil(timeout: 8) { self.a.writes("profiles.configure").count == 1 })
        let pin = a.writes("profiles.configure")[0]
        XCTAssertTrue(same(pin["name"], "ivy"))
        let sent = (pin["ui_meta"] as? [String: Any])?["hermes-bots"]
        XCTAssertTrue(same(sent, ["sectionId": "hermes-hq-pinned", "sectionName": "Pinned", "created": 1790000000001, "pinned": true,
                                  "pinnedFrom": ["id": "sec-work", "name": "Work"]]), "the §5.2 example: \(String(describing: sent))")
        XCTAssertTrue(same((a.profile("ivy")["revisions"] as? [String: Any])?["hermes-bots"], 2), "revision + 1")
        shot(app, "bots-pinned")

        pressMenu(app, app.cells["bot-tile-ivy"], "Unpin")
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 3), "back to a row")
        XCTAssertTrue(waitUntil(timeout: 8) { self.a.writes("profiles.configure").count == 2 })
        let unpin = (a.writes("profiles.configure")[1]["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]
        XCTAssertTrue(same(unpin?["pinned"], false) && same(unpin?["sectionId"], "sec-work") && same(unpin?["sectionName"], "Work")
                      && same(unpin?["pinnedFrom"], false), "\(String(describing: unpin))")
        XCTAssertTrue(app.cells["section-header-Work"].exists, "under Work again")
    }

    // MARK: - S3 refused write

    @MainActor func testS3_RefusedPinRollsBackWithTryAgain() throws {
        try a.control("/__settings/fail", ["method": "profiles.configure", "mode": "applied-false", "count": 1])
        let app = launchSignedIn()
        pressMenu(app, app.cells["bot-row-ivy"], "Pin")
        let alert = app.alerts["Couldn’t Pin Ivy"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "the failure alert")
        XCTAssertTrue(alert.staticTexts["Your gateway didn’t save the change."].exists)
        XCTAssertTrue(alert.buttons["Show Details"].exists && alert.buttons["Try Again"].exists && alert.buttons["OK"].exists)
        XCTAssertTrue(app.cells["bot-row-ivy"].exists, "the tile went back to a row")
        shot(app, "alert-couldnt-pin")
        alert.buttons["Try Again"].tap()
        XCTAssertTrue(app.cells["bot-tile-ivy"].waitForExistence(timeout: 8), "Try Again pins")
    }

    // MARK: - S7 Hide, Undo pill, Show in Bots

    @MainActor func testS7_HideUndoAndShowFromHidden() throws {
        let app = launchSignedIn()
        pressMenu(app, app.cells["bot-row-research"], "More")
        tapMenu(app, "Hide from Bots")
        // The pill shows with the change itself (4 s): Undo at once.
        let pill = app.otherElements["undo-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 8), "the Undo pill")
        app.buttons["undo-pill.undo"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { same(self.a.botsMeta("research")["hidden"], false) }, "Undo shows it again")
        XCTAssertTrue(app.cells["bot-row-research"].waitForExistence(timeout: 5))
        // Hidden again, it joins Deploys under Hidden ("Hidden · 2") and leaves its section.
        pressMenu(app, app.cells["bot-row-research"], "More")
        tapMenu(app, "Hide from Bots")
        let hiddenTwo = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Hidden, 2 bots")).firstMatch
        XCTAssertTrue(appears(hiddenTwo, app, "hidden-two", timeout: 5), "research moves to Hidden · 2")
        XCTAssertFalse(app.cells["bot-row-research"].exists, "and leaves its section")
        shot(app, "undo-pill-hidden")
        XCTAssertTrue(waitUntil(timeout: 8) { same(self.a.botsMeta("research")["hidden"], true) }, "the hide is saved")
        // A hidden bot's own menu has Show in Bots on its first level.
        let hidden = app.cells["section-header-hidden"]
        XCTAssertTrue(appears(hidden, app, "hidden-header"), "the Hidden header")
        hidden.tap()
        let research = app.cells["bot-row-research"]
        XCTAssertTrue(appears(research, app, "hidden-expanded"), "Hidden expands")
        research.press(forDuration: 1.0)
        shot(app, "menu-hidden-bot")
        tapMenu(app, "Show in Bots")
        XCTAssertTrue(waitUntil(timeout: 8) { same(self.a.botsMeta("research")["hidden"], false) })
        XCTAssertTrue(waitUntil(timeout: 5) {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Hidden, 1 bot")).firstMatch.exists
        }, "back to Hidden · 1")
    }

    // MARK: - S8 / S9 New Section, drag a bot onto it; S12 move a pinned bot

    @MainActor func testS8S9S12_NewSectionDragAndMovePinned() throws {
        let app = launchSignedIn(drag: true)
        openMenu(app, app.buttons["bots.compose"], showing: "New Section…")
        tapMenu(app, "New Section…")
        let field = app.textFields["section.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Clients")
        confirmAlert(app, "Create")
        let header = app.cells["section-header-Clients"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "an empty Clients section")
        XCTAssertTrue(app.staticTexts[hint].exists, "with its hint")
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "no write for an empty section")
        shot(app, "bots-empty-section")

        let ivy = app.cells["bot-row-ivy"]
        ivy.press(forDuration: 0.55, thenDragTo: header, withVelocity: .slow, thenHoldForDuration: 0.8)
        let filed = waitUntil(timeout: 10) { (self.a.botsMeta("ivy")["sectionName"] as? String) == "Clients" }
        if !filed { dump(app, "after-drag") }
        XCTAssertTrue(filed, "the drop files Ivy in Clients")
        let sent = (a.writes("profiles.configure").last?["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]
        XCTAssertTrue((sent?["sectionId"] as? String)?.hasPrefix("sec-") == true && same(sent?["sectionName"], "Clients"))

        // S12: the pinned Hermes moves "home" to Clients: only pinnedFrom changes; it stays a tile. Relaunched without
        // drag (saved sign-in): a tile is draggable now, and XCUITest waits a minute per step on a held tile's pending lift.
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        XCTAssertTrue(app.cells["bot-tile-default"].waitForExistence(timeout: 20), "signed in still")
        let before = a.writes("profiles.configure").count
        pressMenu(app, app.cells["bot-tile-default"], "More")
        tapMenu(app, "Move to Section")
        tapMenu(app, "Clients")
        XCTAssertTrue(waitUntil(timeout: 8) { self.a.writes("profiles.configure").count == before + 1 })
        let moved = (a.writes("profiles.configure").last?["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]
        XCTAssertTrue(same((moved?["pinnedFrom"] as? [String: Any])?["name"], "Clients") && same(moved?["sectionId"], "hermes-hq-pinned"))
        XCTAssertTrue(app.cells["bot-tile-default"].exists, "still a tile")
    }

    // MARK: - S10 / S11 Rename and delete a section

    @MainActor func testS10S11_RenameThenDeleteWorkWithUndo() throws {
        let app = launchSignedIn()
        XCTAssertTrue(app.cells["section-header-Work"].waitForExistence(timeout: 10))
        // [botsminimal] The menu is a hold on the section's name.
        pressMenu(app, app.cells["section-header-Work"], "Rename…")
        let field = app.textFields["section.rename"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.clearAndType("Office")
        confirmAlert(app, "Save")
        XCTAssertTrue(appears(app.cells["section-header-Office"], app, "renamed-header"), "the header says Office")
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("profiles.configure").count == 2 }, "one write per member")
        for write in a.writes("profiles.configure") {
            XCTAssertTrue(same(((write["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any])?["sectionName"], "Office"))
        }

        pressMenu(app, app.cells["section-header-Office"], "Delete Section")
        let confirm = app.sheets["Delete “Office”?"]      // [botslist] anchored on the section's name (parity §3 L152)
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.staticTexts["Its 2 bots move to Unassigned."].exists)
        confirm.buttons["Delete Section"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("profiles.configure").count == 4 }, "two writes clearing")
        XCTAssertTrue(same(a.botsMeta("ivy")["sectionId"], NSNull()))
        let pill = app.otherElements["undo-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        app.buttons["undo-pill.undo"].tap()
        XCTAssertTrue(app.cells["section-header-Office"].waitForExistence(timeout: 5), "the record is back")
        XCTAssertTrue(waitUntil(timeout: 10) { same(self.a.botsMeta("ivy")["sectionId"], "sec-work") && same(self.a.botsMeta("research")["sectionId"], "sec-work") })
    }

    // MARK: - S13 / S14 Edit Bot

    @MainActor func testS13S14_EditBotSavesTitleAndDescription() throws {
        let app = launchSignedIn()
        openBotInfo(app, "ivy")
        shot(app, "bot-info")
        app.buttons["bot-info.edit"].tap()
        let title = app.textFields["edit-bot.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["edit-bot.save"].isEnabled, "Save waits for a change")
        shot(app, "edit-bot")
        title.tap()
        title.typeText("Ivy the Scout")
        let description = app.textViews["edit-bot.description"].exists ? app.textViews["edit-bot.description"] : app.textFields["edit-bot.description"]
        description.tap()
        description.clearAndType("Finds flights")
        // S14 first: a refused save keeps the page.
        try a.control("/__settings/fail", ["method": "profiles.configure", "mode": "error", "count": 1])
        app.buttons["edit-bot.save"].tap()
        let alert = app.alerts["Couldn’t Save Changes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        alert.buttons["OK"].tap()
        XCTAssertTrue(title.exists, "the page stays with what was typed")
        app.buttons["edit-bot.save"].tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 8), "back on Bot Info")
        XCTAssertTrue(waitUntil(timeout: 5) { app.staticTexts["Ivy the Scout"].exists }, "the name redraws at once")
        let write = a.writes("profiles.configure").last ?? [:]
        XCTAssertTrue(same(write["description"], "Finds flights"), "description sent: \(String(describing: write["description"]))")
        XCTAssertTrue(same(((write["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any])?["title"], "Ivy the Scout"))
        XCTAssertEqual(Set(write.keys), ["name", "ui_meta", "description"])
    }

    /// Taps a choice in one of Edit Head's sideways strips, scrolling the strip until the choice is on screen.
    @MainActor func tapInStrip(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), identifier)
        let width = app.windows.firstMatch.frame.width
        // `isHittable` throws for a choice scrolled fully off screen, so the frame decides.
        for _ in 0..<8 where button.frame.minX < 8 || button.frame.maxX > width - 8 {
            let y = button.frame.midY
            let leftward = button.frame.minX > width / 2
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: leftward ? width - 40 : 40, dy: y))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: leftward ? -220 : 220, dy: 0)))
        }
        button.tap()
    }

    // MARK: - S36 Edits made from a bot's own chat redraw its header at once (verify round 2)

    @MainActor func testS36_EditFromChatTitleRedrawsTheOpenChat() throws {
        let app = launchSignedIn()
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the chat opens")
        let header = app.descendants(matching: .any)["chat.title"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(header.label.hasPrefix("Ivy"), header.label)
        let headBefore = header.value as? String
        header.tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 5), "Bot Info opens from the title")
        app.buttons["bot-info.edit"].tap()
        let field = app.textFields["edit-bot.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Ivy Scout")
        app.buttons["edit-bot.save"].tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 8), "back on Bot Info")
        app.buttons["bot-info.edit"].tap()
        app.buttons["edit-bot.edit-head"].tap()
        tapInStrip(app, "edit-head.shape-hex")
        XCTAssertFalse(app.buttons["edit-head.eyes-hearts"].exists, "no Eyes strip: every face has the normal eyes")
        app.buttons["edit-head.save"].tap()
        XCTAssertTrue(app.staticTexts["Head saved. It’s on every device on this gateway."].waitForExistence(timeout: 8))
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["bot-info.close"].tap()
        // The chat underneath already shows the new name, head and "Message <name>", without a reopen.
        XCTAssertTrue(waitUntil(timeout: 5) { header.label == "Ivy Scout" }, "the header's name: \(header.label)")
        XCTAssertTrue(waitUntil(timeout: 5) { (header.value as? String)?.hasPrefix("hex/") == true },
                      "the header's head: \(String(describing: header.value)) (was \(String(describing: headBefore)))")
        // [a11y] The field shows "Message <name>" whole or, when that is wider than the field at full size, "Message"
        // alone (ComposerView.shownPlaceholder); "Message Ivy Scout" is a point too wide on this iPhone beside the mic.
        let shownPlaceholders = { app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Message'")).allElementsBoundByIndex.map(\.label) }
        XCTAssertTrue(waitUntil(timeout: 5) { !app.staticTexts["Message Ivy"].exists
                          && (app.staticTexts["Message Ivy Scout"].exists || app.staticTexts["Message"].exists) },
                      "the field's placeholder follows the name: \(shownPlaceholders())")
        shot(app, "chat-after-edits")
    }

    // MARK: - S15 Edit Head; S16 conflict; S17 Reset

    @MainActor func testS15S16S17_EditHeadSaveConflictAndReset() throws {
        let app = launchSignedIn()
        openBotInfo(app, "ivy")
        app.buttons["bot-info.edit"].tap()
        app.buttons["edit-bot.edit-head"].tap()
        XCTAssertTrue(app.buttons["edit-head.shape-hex"].waitForExistence(timeout: 5))
        shot(app, "edit-head")
        tapInStrip(app, "edit-head.shape-hex")
        app.buttons["edit-head.save"].tap()
        XCTAssertTrue(app.staticTexts["Head saved. It’s on every device on this gateway."].waitForExistence(timeout: 8))
        let save = a.writes("profiles.configure").last ?? [:]
        // Ivy has no head of its own: the editor starts from its dot-matrix head (cobalt, Wide, its record's oval eyes, drawn
        // as slits), and a dot-matrix head saves its outline in `form` with no glasses, antenna or ears.
        let expectedHead: [String: Any] = ["v": 6, "theme": "matrix", "color": "cobalt", "seed": 1562156509, "shape": "dome", "face": "visor",
                                           "visor": "band", "shell": "ink", "antenna": "none", "ears": "none", "mouth": "none", "blush": false,
                                           "hair": "bob", "pattern": "face", "tile": "none", "eyes": true, "glyph": "✨", "form": "hex",
                                           "look": "ovals", "specs": "none", "hat": "none", "headset": false]
        XCTAssertTrue(same((save["ui_meta"] as? [String: Any])?["dispatch-head"], expectedHead), "\(save)")
        XCTAssertTrue(same(save["ui_meta_expected_revisions"], ["dispatch-head": 0]))
        XCTAssertTrue(waitUntil(timeout: 8) { same(self.a.profile("ivy")["avatar_png"], [288, 288]) }, "the 288 × 288 desktop copy")
        shot(app, "edit-bot-head-saved")
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["bot-info.close"].tap()

        // S16: Research's head changes on another device while its editor is open.
        openBotInfo(app, "research")
        app.buttons["bot-info.edit"].tap()
        app.buttons["edit-bot.edit-head"].tap()
        XCTAssertTrue(app.buttons["edit-head.shape-star"].waitForExistence(timeout: 5))
        try a.control("/__settings/desktop-edit", ["profile": "research", "key": "dispatch-head",
                                                   "value": ["v": 6, "theme": "shape", "color": "red", "seed": 3, "form": "drop"]])
        tapInStrip(app, "edit-head.shape-star")
        app.buttons["edit-head.save"].tap()
        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This bot’s head was changed on another device'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "the conflict notice")
        shot(app, "edit-head-conflict")
        app.buttons["edit-head.save"].tap()
        XCTAssertTrue(app.staticTexts["Head saved. It’s on every device on this gateway."].waitForExistence(timeout: 8), "saving again replaces theirs")
        XCTAssertTrue(same((a.writes("profiles.configure").last?["ui_meta_expected_revisions"] as? [String: Any])?["dispatch-head"], 2))
        XCTAssertTrue(waitUntil(timeout: 8) { same(self.a.profile("research")["avatar_png"], [288, 288]) })

        // S17: Reset Head: CAS with null, then the mirror is cleared (it is ours).
        app.buttons["edit-bot.edit-head"].tap()
        let reset = app.buttons["edit-head.reset"]
        for _ in 0..<6 where !(reset.exists && reset.isHittable) { app.swipeUp() }
        reset.tap()
        XCTAssertTrue(app.staticTexts["Head reset. Every device on this gateway shows its default head."].waitForExistence(timeout: 8),
                      "a reset says so (not \"Head saved\")")
        XCTAssertTrue(same(((a.writes("profiles.configure").last?["ui_meta"]) as? [String: Any])?["dispatch-head"], NSNull()))
        XCTAssertTrue(waitUntil(timeout: 8) { same(self.a.profile("research")["has_avatar"], false) }, "set_asset clear:true")
        XCTAssertTrue(same(a.writes("profiles.set_asset").last?["clear"], true))
    }

    // MARK: - S18 Edit Head: Shuffle, Undo, idea, My Style, discard guard

    @MainActor func testS18_EditHeadExtrasAndDiscardGuard() throws {
        let app = launchSignedIn(["-hqn.head.style", "none"])      // no My Style saved (a string, not a head record)
        openBotInfo(app, "ivy")
        app.buttons["bot-info.edit"].tap()
        app.buttons["edit-bot.edit-head"].tap()
        let stage = app.descendants(matching: .any)["edit-head.stage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["edit-head.undo"].isEnabled, "nothing to undo yet")
        app.buttons["edit-head.shuffle"].tap()
        XCTAssertTrue(app.buttons["edit-head.undo"].isEnabled, "Shuffle can be undone")
        XCTAssertTrue(app.buttons["edit-head.save"].isEnabled)
        app.buttons["edit-head.undo"].tap()
        XCTAssertFalse(app.buttons["edit-head.save"].isEnabled, "Undo restores the head it opened with")
        app.buttons["edit-head.idea-2"].tap()
        XCTAssertTrue(app.buttons["edit-head.save"].isEnabled, "an idea is a change")
        for _ in 0..<6 where !(app.buttons["edit-head.color-cobalt"].exists && app.buttons["edit-head.color-cobalt"].isHittable) { app.swipeUp() }
        app.buttons["edit-head.color-cobalt"].tap()
        for _ in 0..<6 where !(app.buttons["edit-head.set-style"].exists && app.buttons["edit-head.set-style"].isHittable) { app.swipeUp() }
        XCTAssertFalse(app.buttons["edit-head.use-style"].isEnabled, "no style yet")
        app.buttons["edit-head.set-style"].tap()
        XCTAssertTrue(app.buttons["edit-head.use-style"].isEnabled)
        shot(app, "edit-head-scrolled")
        // Use My Style takes the style's look and keeps this bot's colour and seed (§7.4). Shuffle (on the sticky stage)
        // first, so the draft's colour and seed differ from the style's.
        let styled = headFields(stage)
        XCTAssertEqual(styled["color"], "cobalt", "the style was set from the cobalt draft: \(styled)")
        app.buttons["edit-head.shuffle"].tap()
        let shuffled = headFields(stage)
        XCTAssertNotEqual(shuffled["seed"], styled["seed"], "Shuffle rolled a new head")
        app.buttons["edit-head.use-style"].tap()
        let used = headFields(stage)
        XCTAssertEqual(used["color"], shuffled["color"], "the bot's colour stays")
        XCTAssertEqual(used["seed"], shuffled["seed"], "the bot's seed stays")
        for part in ["form", "look", "specs", "mouth"] { XCTAssertEqual(used[part], styled[part], "the style's \(part)") }
        // The sheet holds while there are changes: a pull down asks first.
        let top = app.navigationBars["Edit Head"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(appears(discard, app, "discard-sheet", timeout: 4), "the discard sheet")
        shot(app, "edit-head-discard")
        // iOS 26 shows an action sheet's cancel action as a tap outside it.
        if app.buttons["Keep Editing"].exists { app.buttons["Keep Editing"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { !app.buttons["Discard Changes"].exists }, "Keep Editing stays")
        app.navigationBars["Edit Head"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["edit-bot.edit-head"].waitForExistence(timeout: 3), "back on Edit Bot")
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "nothing saved")
    }

    // MARK: - S38 Edit Head themes: the theme grid, a Robot's own parts, Describe it, and saving a Robot head

    @MainActor func testS38_EditHeadThemesRobotDescribeAndSave() throws {
        let app = launchSignedIn()
        openBotInfo(app, "ivy")
        app.buttons["bot-info.edit"].tap()
        app.buttons["edit-bot.edit-head"].tap()
        let stage = app.descendants(matching: .any)["edit-head.stage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        for theme in ["robot", "dots", "orb", "pixel", "glyph", "shape"] {
            XCTAssertTrue(app.buttons["edit-head.theme-\(theme)"].exists, "theme \(theme) is offered")
        }
        XCTAssertFalse(app.buttons["edit-head.theme-persona"].exists, "Character is not offered")
        shot(app, "edit-head-themes")
        app.buttons["edit-head.theme-robot"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { self.headFields(stage)["theme"] == "robot" }, "\(headFields(stage))")
        XCTAssertTrue(app.buttons["edit-head.save"].isEnabled, "a theme is a change")
        XCTAssertTrue(app.buttons["edit-head.head-cat"].waitForExistence(timeout: 5), "the robot's Head strip")
        shot(app, "edit-head-robot")
        XCTAssertFalse(app.buttons["edit-head.eyes-happy"].exists, "no Eyes strip on a robot either")
        tapInStrip(app, "edit-head.visor-screen")
        tapInStrip(app, "edit-head.shell-chrome")
        var fields = headFields(stage)
        XCTAssertEqual(fields["visor"], "screen"); XCTAssertEqual(fields["shell"], "chrome")
        let antenna = app.segmentedControls["edit-head.antenna"]
        for _ in 0..<6 where !(antenna.exists && antenna.isHittable) { app.swipeUp() }
        antenna.buttons["Halo"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { self.headFields(stage)["antenna"] == "ring" })
        shot(app, "edit-head-robot-extras")

        // Describe it lays what it understood over the draft and says what it heard.
        let field = app.textFields["edit-head.describe"]
        // [main-e2e] Hittable isn't enough: the field scrolls under the pinned stage (the head, Shuffle and Undo) and a
        // tap there lands on the stage. Down until it is below Shuffle.
        let shuffle = app.buttons["edit-head.shuffle"]
        for _ in 0..<8 where !(field.exists && field.isHittable && field.frame.minY >= shuffle.frame.maxY) { app.swipeDown() }
        field.tap()
        var lost: [String] = []
        for (index, ch) in "sleepy purple cat with goggles".enumerated() {
            // The simulator hides and re-shows the keyboard now and then while XCUITest types; wait it out.
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            if !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
                lost.append("\(index)")
                shot(app, "describe-lost-focus-\(index)")
                field.tap()
            }
            field.typeText(String(ch))
        }
        print("DESCRIBE-FOCUS-LOST at \(lost)")
        XCTAssertTrue(lost.isEmpty, "Describe it lost keyboard focus before characters \(lost)")
        let understood = app.staticTexts["edit-head.understood"]
        XCTAssertTrue(understood.waitForExistence(timeout: 3))
        XCTAssertTrue(understood.label.hasPrefix("Got it: "), understood.label)
        for word in ["purple", "cat", "sleepy", "goggles"] { XCTAssertTrue(understood.label.contains(word), understood.label) }
        fields = headFields(stage)
        XCTAssertEqual(fields["theme"], "robot", "no theme word: the theme stays")
        XCTAssertEqual(fields["shape"], "cat"); XCTAssertEqual(fields["face"], "sleepy")
        XCTAssertEqual(fields["color"], "lilac"); XCTAssertEqual(fields["visor"], "goggles")
        app.keyboards.buttons["Done"].firstMatch.tap()
        shot(app, "edit-head-described")

        app.buttons["edit-head.save"].tap()
        XCTAssertTrue(app.staticTexts["Head saved. It’s on every device on this gateway."].waitForExistence(timeout: 8))
        let head = ((a.writes("profiles.configure").last ?? [:])["ui_meta"] as? [String: Any])?["dispatch-head"] as? [String: Any] ?? [:]
        XCTAssertEqual(head["theme"] as? String, "robot", "\(head)")
        XCTAssertEqual(head["shape"] as? String, "cat")
        XCTAssertEqual(head["face"] as? String, "sleepy")
        XCTAssertEqual(head["shell"] as? String, "chrome")
        XCTAssertEqual(head["antenna"] as? String, "ring")
        XCTAssertEqual(head["hat"] as? String, "none")
        XCTAssertTrue(waitUntil(timeout: 8) { same(self.a.profile("ivy")["avatar_png"], [288, 288]) }, "the 288 × 288 desktop copy")
        shot(app, "edit-bot-robot-saved")
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 5))
        shot(app, "bots-robot-head")

        // The saved Robot opens as a Robot, and the other themes draw too.
        openBotInfo(app, "ivy")
        app.buttons["bot-info.edit"].tap()
        app.buttons["edit-bot.edit-head"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.headFields(stage)["theme"] == "robot" }, "\(headFields(stage))")
        for theme in ["dots", "orb", "pixel", "glyph"] {
            app.buttons["edit-head.theme-\(theme)"].tap()
            XCTAssertTrue(waitUntil(timeout: 3) { self.headFields(stage)["theme"] == theme })
            shot(app, "edit-head-\(theme)")
        }
    }

    /// Verify round 3: words typed in Edit Bot, then Edit Head opened and left untouched: a pull down still asks (the
    /// page under it has changes), Keep Editing keeps the words, and nothing is written.
    @MainActor func testS37_UntouchedEditHeadOverDirtyEditBotStillAsks() throws {
        let app = launchSignedIn()
        openBotInfo(app, "ivy")
        app.buttons["bot-info.edit"].tap()
        let title = app.textFields["edit-bot.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Unsaved Title")
        // The form scrolls Title clear of the keyboard when it takes focus (it sits lower since the Picture section
        // grew its Head | Upload tabs): Edit Head is tapped where it comes to rest, not where it was mid-scroll.
        let editHead = app.buttons["edit-bot.edit-head"]
        var at = editHead.frame, since = Date()
        XCTAssertTrue(waitUntil(timeout: 8) {
            let now = editHead.frame
            if now != at { at = now; since = Date() }
            return editHead.isHittable && Date().timeIntervalSince(since) >= 0.6
        }, "Edit Head comes to rest in reach: \(at)")
        editHead.tap()
        XCTAssertTrue(app.buttons["edit-head.save"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["edit-head.save"].isEnabled, "Edit Head itself has no changes")
        let top = app.navigationBars["Edit Head"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(appears(discard, app, "edit-head-over-dirty-edit-bot", timeout: 4), "the pull down asks first")
        if app.buttons["Keep Editing"].exists { app.buttons["Keep Editing"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { !discard.exists }, "Keep Editing stays")
        app.navigationBars["Edit Head"].buttons["Cancel"].tap()        // no changes of its own: straight back
        XCTAssertTrue(waitUntil(timeout: 3) { (title.value as? String) == "Unsaved Title" }, "back on Edit Bot, the words kept")
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "nothing saved")
    }

    // MARK: - S19 / S20 / S21 New Bot

    @MainActor func testS19S21_NewBotIntroducesItselfAndTakenNames() throws {
        let app = launchSignedIn()
        openMenu(app, app.buttons["bots.compose"], showing: "New Bot")
        tapMenu(app, "New Bot")
        let name = app.textFields["new-bot.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["new-bot.create"].isEnabled, "empty: Create waits")
        name.typeText("Ivy")
        XCTAssertTrue(app.staticTexts["new-bot.taken"].waitForExistence(timeout: 3), "S21: taken")
        XCTAssertEqual(app.staticTexts["new-bot.taken"].label, "A bot named “ivy” already exists.")
        XCTAssertFalse(app.buttons["new-bot.create"].isEnabled)
        shot(app, "new-bot-taken")
        name.clearAndType("Inbox Triage")
        let description = app.textViews["new-bot.description"].exists ? app.textViews["new-bot.description"] : app.textFields["new-bot.description"]
        description.tap()
        description.typeText("Sorts my email")
        shot(app, "new-bot")
        app.buttons["new-bot.create"].tap()
        let table = app.tables["chat.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 15), "the new bot's chat opens")
        let reply = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Hi! I'm Inbox Triage.")).firstMatch
        let streamed = reply.waitForExistence(timeout: 15)
        if !streamed { dump(app, "new-bot-chat"); print("STATE", a.state()["prompts"] ?? "", a.profile("inbox-triage")) }
        XCTAssertTrue(streamed, "the intro reply streams")
        let create = a.writes("profiles.create").last ?? [:]
        XCTAssertEqual(Set(create.keys), ["name", "description", "clone_from", "no_skills", "share_auth", "soul", "soulText"])
        XCTAssertTrue(same(create["name"], "inbox-triage") && same(create["description"], "Sorts my email") && same(create["clone_from"], "default")
                      && same(create["no_skills"], false) && same(create["share_auth"], true))
        XCTAssertTrue(same(create["soulText"], "# Inbox Triage\n\n**Mission:** Sorts my email\n\nYou are Inbox Triage, a persistent named agent (profile `inbox-triage`) on this machine.\nYou keep your own memory, skills, and conversation history across sessions."))
        let meta = (a.writes("profiles.configure").first { same($0["name"], "inbox-triage") }?["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]
        XCTAssertTrue(same(meta?["shape"], "blobatar") && same(meta?["imageKind"], "shape"))
        let creates = a.writes("session.create")
        XCTAssertTrue(same(creates.last?["profile"], "inbox-triage") && same(creates.last?["title"], "Bot Chat"))
        let prompts = (a.state()["prompts"] as? [[String: Any]]) ?? []
        XCTAssertEqual(prompts.filter { same($0["text"], "Hey, tell me about yourself!") }.count, 1, "the intro is sent once")
        shot(app, "new-bot-chat")
    }

    @MainActor func testS20_NewBotWithoutAModelSkipsTheIntro() throws {
        try a.control("/__settings/runtime", ["ok": false, "error": "No provider"])
        let app = launchSignedIn()
        openMenu(app, app.buttons["bots.compose"], showing: "New Bot")
        tapMenu(app, "New Bot")
        let name = app.textFields["new-bot.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Notes 2")
        app.buttons["new-bot.create"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens")
        let notice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "No model provider is ready for it yet")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 6), "the no-model notice")
        shot(app, "new-bot-no-model")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(((a.state()["prompts"] as? [[String: Any]]) ?? []).count, 0, "no intro")
    }

    // MARK: - S22 / S23 Capabilities

    @MainActor func testS22S23_SkillsAndConnectors() throws {
        try a.control("/__settings/install-outcome", ["identifier": "official/research/duckduckgo", "exit": 1,
                                                      "lines": ["Not installed: the security scan found 2 high-risk pattern(s) in 'official/research/duckduckgo' (listed above)."]])
        let app = launchSignedIn()
        openSettings(app)
        // The gateway settings sit above Bots & Tools: scroll down to Capabilities, then Skills ([cap-pages]).
        scrollTo(app.buttons["settings.capabilities"], app, max: 12)
        app.buttons["settings.capabilities"].tap()
        XCTAssertTrue(app.buttons["capabilities.row.skills"].waitForExistence(timeout: 8), "Capabilities' four rows")
        app.buttons["capabilities.row.skills"].tap()
        let arxiv = app.switches["skill-switch-arxiv"]
        XCTAssertTrue(appears(arxiv, app, "skills", timeout: 10), "the skills list")
        shot(app, "capabilities-skills")
        flip(arxiv)
        XCTAssertTrue(waitUntil(timeout: 8) { self.a.writes("PUT /api/skills/toggle").count == 1 })
        XCTAssertTrue(same(a.writes("PUT /api/skills/toggle")[0]["enabled"], false) && same(a.writes("PUT /api/skills/toggle")[0]["name"], "arxiv"))
        let get = app.buttons["skill-get-blender-mcp"]
        scrollTo(get, app)
        get.tap()
        // [capabilities] Get asks first.
        XCTAssertTrue(app.alerts.buttons["Install"].waitForExistence(timeout: 5), "Get asks first")
        app.alerts.buttons["Install"].tap()
        XCTAssertTrue(app.switches["skill-switch-blender-mcp"].waitForExistence(timeout: 15), "the installed skill moves to Installed")
        let duck = app.buttons["skill-get-duckduckgo"]
        for _ in 0..<6 where !duck.isHittable { app.swipeUp() }
        duck.tap()
        XCTAssertTrue(app.alerts.buttons["Install"].waitForExistence(timeout: 5), "Get asks first")
        app.alerts.buttons["Install"].tap()
        let blocked = app.alerts["Couldn’t Install duckduckgo"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 15), "the scan-block alert")
        XCTAssertTrue(blocked.staticTexts["The security scan flagged 2 items to review. Read the scan before deciding whether to trust the author."].exists)
        shot(app, "capabilities-install-blocked")
        blocked.buttons["OK"].tap()
        // A skill's page.
        app.swipeDown(); app.swipeDown()
        app.buttons["skill-row-web-search"].firstMatch.exists ? app.buttons["skill-row-web-search"].firstMatch.tap() : app.staticTexts["Web Search"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Web Search"].waitForExistence(timeout: 5))   // the page is titled as people say it (DisplayName)
        XCTAssertTrue(app.switches["Turned On"].waitForExistence(timeout: 5))
        shot(app, "capabilities-skill-page")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Connectors: Back to Capabilities, then its row.
        app.navigationBars.buttons["Capabilities"].firstMatch.tap()
        XCTAssertTrue(app.buttons["capabilities.row.connectors"].waitForExistence(timeout: 5))
        app.buttons["capabilities.row.connectors"].tap()
        let files = app.switches["mcp-switch-files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        // [connectors-ux] a plugin's server has no switch here at all (its plugin switches it); its row opens its page
        XCTAssertFalse(app.switches["mcp-switch-browser"].exists, "a plugin's server can't be switched here")
        shot(app, "capabilities-connectors")
        flip(files)
        XCTAssertTrue(waitUntil(timeout: 8) { self.a.writes("reload.mcp").count == 1 })
        XCTAssertTrue(same(a.writes("PUT /api/mcp/servers/files/enabled").last?["enabled"], true))
        XCTAssertEqual(Set(a.writes("reload.mcp")[0].keys), ["confirm"], "reload.mcp sends only confirm")
    }

    // MARK: - S30 Appearance and Completion Sound; S34 Kanban row absent

    @MainActor func testS34_SettingsCardAboutAndNoKanban() throws {
        let app = launchSignedIn()
        openSettings(app)
        let card = app.buttons["settings.gateway-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 8) { card.label.contains("Connected") && card.label.contains("6\u{00A0}Bots") && card.label.contains("Hermes\u{00A0}0.21.5") },
                      "the card's status line: \(card.label)")
        shot(app, "settings")
        // [desktoplook] the Theme row above moved this switch below the fold: scroll to it.
        for _ in 0..<3 where !app.switches["settings.completion-sound"].exists { app.swipeUp() }
        XCTAssertTrue(app.switches["settings.completion-sound"].exists, "the cue is wired")
        // [kanban-tab-one] No Kanban Tab row on the root (owner 2026-11-03: one home per page); it is on Appearance ›
        // Tabs (S41), though this fixture's base gateway answers the Kanban API.
        let kanban = app.buttons["settings.kanban"]
        XCTAssertFalse(kanban.exists, "no Kanban Tab row on the Settings root")
        // About and the licences.
        let about = app.buttons["settings.about"]
        for _ in 0..<6 where !(about.exists && about.isHittable) {
            app.swipeUp()
            XCTAssertFalse(kanban.exists, "no Kanban Tab row on the Settings root")
        }
        about.tap()
        XCTAssertTrue(app.staticTexts["Version"].waitForExistence(timeout: 3))
        shot(app, "about")
        app.buttons["Open-Source Licenses"].tap()
        XCTAssertTrue(app.staticTexts["swift-markdown"].waitForExistence(timeout: 3))
        shot(app, "licenses")
    }

    /// S30: the cue plays when a reply finishes and stays silent with the switch off; Appearance survives a relaunch.
    @MainActor func testS30_CompletionSoundAndAppearanceAfterRelaunch() throws {
        guard ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] != "1" else { throw XCTSkip("light runs only (it sets Dark itself)") }
        let app = launchSignedIn(["-HQDebugCueCount", "YES"])
        let probe = app.descendants(matching: .any)["debug.cue-count"]
        func cue() -> (played: Int, heard: Int) {
            let value = (probe.exists ? probe.value as? String : nil) ?? ""
            let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return numbers.count == 2 ? (numbers[0], numbers[1]) : (0, 0)
        }
        // The switch starts on (an earlier run may have left it off).
        openSettings(app)
        let start = app.switches["settings.completion-sound"]
        // [desktoplook] the Theme row above moved this switch below the fold: scroll to it.
        for _ in 0..<3 where !start.exists { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 5), "the cue is wired")
        if start.value as? String == "0" { flip(start) }
        closeSettings(app)
        // A reply with the switch on: one cue.
        talk(app, to: "ivy", "Hello there")
        XCTAssertTrue(waitUntil(timeout: 15) { cue().heard >= 1 }, "the reply finished: \(cue())")
        XCTAssertEqual(cue().played, cue().heard, "it played the cue")
        let played = cue().played
        // Off: the next reply is silent.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openSettings(app)
        let sound = app.switches["settings.completion-sound"]
        for _ in 0..<3 where !sound.exists { app.swipeUp() }   // [desktoplook] below the fold
        XCTAssertTrue(sound.waitForExistence(timeout: 5))
        XCTAssertEqual(sound.value as? String, "1")
        flip(sound)
        XCTAssertEqual(sound.value as? String, "0", "the switch flips")
        closeSettings(app)
        let heard = cue().heard
        talk(app, to: "ivy", "Once more")
        XCTAssertTrue(waitUntil(timeout: 15) { cue().heard > heard }, "the second reply finished: \(cue())")
        XCTAssertEqual(cue().played, played, "no cue with the switch off")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openSettings(app)
        for _ in 0..<3 where !app.switches["settings.completion-sound"].exists { app.swipeUp() }   // [desktoplook] below the fold
        flip(app.switches["settings.completion-sound"])        // back on
        // Dark, then a relaunch (the saved sign-in, no reset): the first frame is dark.
        for _ in 0..<6 where !(app.buttons["settings.appearance"].exists && app.buttons["settings.appearance"].isHittable) { app.swipeDown() }
        app.buttons["settings.appearance"].tap()
        tapMenu(app, "Dark")
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "settings-after-dark")
        closeSettings(app)          // Settings is on More: the relaunch reopens the tab last shown
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"]
        app.launch()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 20), "signed in still")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertLessThan(pageLuminance(app), 0.35, "Dark is applied after the relaunch")
        shot(app, "relaunch-dark")
        openSettings(app)
        app.buttons["settings.appearance"].tap()
        tapMenu(app, "System")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(pageLuminance(app), 0.55, "System (light on this simulator) again")
    }

    // MARK: - S31 largest text size

    @MainActor func testS31_SettingsAtTheLargestTextSize() throws {
        let app = launchSignedIn(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openSettings(app)
        XCTAssertTrue(app.buttons["settings.gateway-card"].waitForExistence(timeout: 5))
        shot(app, "settings-ax5")
        app.swipeUp()
        shot(app, "settings-ax5-lower")
        let capabilities = app.buttons["settings.capabilities"]
        scrollTo(capabilities, app, max: 24)
        capabilities.tap()
        // [cap-pages] Four rows, no tabs to fold into a pull-down.
        let skills = app.buttons["capabilities.row.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 8), "Capabilities' rows at accessibility sizes")
        shot(app, "capabilities-ax5")
        skills.tap()
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 8), "Skills is its own page")
        XCTAssertFalse(app.buttons["capabilities.tab"].exists, "no tab control")
    }

    // MARK: - S32 read-only

    @MainActor func testS32_ReadOnlyRefusesEveryWrite() throws {
        let app = launchSignedIn(["-HQDebugReadOnly", "YES"])
        pressMenu(app, app.cells["bot-row-ivy"], "Pin")
        let alert = app.alerts["Couldn’t Pin Ivy"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Changes are turned off for this gateway in this build."].exists)
        alert.buttons["OK"].tap()
        // [tester batch 3] Bot Info › Default Model says why before any chooser opens.
        openBotInfo(app, "ivy")
        app.botInfoTab("Brain")   // [page-tabs]
        let model = app.buttons["bot-info.default-model"]
        XCTAssertTrue(appears(model, app, "read-only-model-row", timeout: 8), "Brain › Default Model")
        model.tap()
        let refused = app.alerts["Couldn’t Change Ivy’s Model"]
        XCTAssertTrue(appears(refused, app, "read-only-model-alert"), "refused, with the reason")
        XCTAssertTrue(refused.staticTexts["Changes are turned off for this gateway in this build."].exists)
        refused.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["model-option.claude-haiku-5"].exists, "no chooser opened")
        XCTAssertEqual(((a.state()["writes"] as? [Any]) ?? []).count, 0, "nothing sent")
    }

    // MARK: - S24 / S25 / S27 two gateways (config B)

    @MainActor func testS24S25S27_TwoGatewaysSwitchNewsRenameRemove() throws {
        guard ProcessInfo.processInfo.environment["HQN_SETTINGS_CONFIG"] != "C" else { throw XCTSkip("config B only") }
        let b = try SettingsFixture.load("HQN_SETTINGS_B")
        try b.control("/__settings/reset", [:])
        let app = launchSignedIn()
        // S24: Add Gateway… from Settings › Gateway.
        openSettings(app)
        app.buttons["settings.gateway-card"].tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 5))
        shot(app, "gateway-one")
        app.buttons["gateway.add"].tap()
        signIn(app, b)
        let listed = waitUntil(timeout: 15) { app.descendants(matching: .any)["gateway-row-\(b.hostPort)"].exists }
        if !listed { dump(app, "gateway-two") }
        XCTAssertTrue(listed, "two gateways listed")
        shot(app, "gateway-two")
        app.navigationBars["Gateways"].buttons.element(boundBy: 0).tap()       // back to Settings
        closeSettings(app)
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 10))
        let beta = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Beta Ivy'")).firstMatch
        XCTAssertTrue(beta.waitForExistence(timeout: 10), "the Beta gateway's bots")
        shot(app, "bots-switcher-title")

        // S25: news on the gateway not in use shows as a dot and "1 New".
        try a.control("/__settings/bump", ["profile": "ivy"])
        openTitleMenu(app)
        XCTAssertTrue(appears(app.buttons["gateway-menu-\(a.hostPort)"].firstMatch, app, "title-menu"), "the title menu lists the gateways")
        // The check the menu started lands while it is open: its row updates in place.
        let news = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1 New' OR value CONTAINS '1 New'")).firstMatch
        XCTAssertTrue(appears(news, app, "title-menu-news", timeout: 8), "\"1 New\" on the other gateway")
        shot(app, "title-menu-news")
        app.buttons["gateway-menu-\(a.hostPort)"].firstMatch.tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A fresh answer is waiting."].waitForExistence(timeout: 20), "Ivy's news shows after the switch")

        // S26 (as far as this build allows: a pushed chat hides the tab bar, so a switch is made from a list): the
        // Sessions title switches too, and the tab stays on its list with the other gateway's sessions painted.
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Trip ideas"].waitForExistence(timeout: 10), "this gateway's sessions")
        let sessionsSwitcher = app.buttons["gateway-switcher"].firstMatch
        XCTAssertTrue(sessionsSwitcher.waitForExistence(timeout: 5), "the Sessions title switches too")
        shot(app, "sessions-switcher-title")
        sessionsSwitcher.tap()
        XCTAssertTrue(app.buttons["gateway-menu-\(b.hostPort)"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["gateway-menu-\(b.hostPort)"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (app.buttons["gateway-switcher"].firstMatch.label).contains(b.port) }, "now on Beta")
        XCTAssertTrue(app.collectionViews["sessions.list"].exists, "still on the Sessions list")
        sessionsSwitcher.tap()
        XCTAssertTrue(app.buttons["gateway-menu-\(a.hostPort)"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["gateway-menu-\(a.hostPort)"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (app.buttons["gateway-switcher"].firstMatch.label).contains(a.port) })
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 10))

        // S27: rename the other one, then remove it.
        openSettings(app)
        app.buttons["settings.gateway-card"].tap()
        let other = app.descendants(matching: .any)["gateway-row-\(b.hostPort)"]
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.swipeLeft()
        app.buttons["Rename"].tap()
        let field = app.textFields["gateway.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Studio")
        confirmAlert(app, "Save")
        let studio = app.descendants(matching: .any)["gateway-row-Studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 5), "renamed")
        studio.swipeLeft()
        app.buttons["Remove"].tap()
        let confirm = app.alerts["Remove Studio?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", b.username + " is signed out of this gateway")).firstMatch.exists)
        confirm.buttons["Remove Gateway"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !studio.exists }, "removed")
        shot(app, "gateway-after-remove")
    }

    // MARK: - S28 / S29 password + Sign in with Nous (config C)

    /// Verify round 1 (pages × gateways): More leads with the gateway card; a switch made from More › Gateway lands
    /// back on that page; with two gateways every tab's title is the same size at the same y; after a switch the tab
    /// is remembered again (a relaunch reopens it).
    @MainActor func testS35_TabsAndMoreAcrossASwitch() throws {
        guard ProcessInfo.processInfo.environment["HQN_SETTINGS_CONFIG"] != "C" else { throw XCTSkip("config B only") }
        let b = try SettingsFixture.load("HQN_SETTINGS_B")
        try b.control("/__settings/reset", [:])
        var app = launchSignedIn()
        // A tab tap the late "Save Password?" card took is tried again.
        func select(_ name: String) {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "the \(name) tab")
            for _ in 0..<3 where !tab.isSelected {
                tab.tap()
                _ = waitUntil(timeout: 2) { tab.isSelected }
            }
            XCTAssertTrue(tab.isSelected, "the \(name) tab is selected")
        }
        dismissSavePassword(app, wait: 3)
        select("More")
        let card = app.cells["more-row-gateway"]
        XCTAssertTrue(appears(card, app, "more-card"), "More leads with the gateway card")
        shot(app, "more-gateway-card")
        card.tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 5), "the card opens the Gateway page")
        app.buttons["gateway.add"].tap()
        signIn(app, b)
        let rowA = app.descendants(matching: .any)["gateway-row-\(a.hostPort)"]
        XCTAssertTrue(appears(rowA, app, "more-two-gateways", timeout: 15), "two gateways listed")
        dismissSavePassword(app, wait: 2)
        // Back to A from here: the switch lands on this page, on More's stack.
        rowA.tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            let row = app.descendants(matching: .any)["gateway-row-\(self.a.hostPort)"]
            return row.exists && row.isSelected
        }, "switched to A")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.navigationBars["Gateways"].exists, "still on the Gateways page after the switch")
        XCTAssertTrue(app.tabBars.buttons["More"].isSelected, "on the More tab")
        shot(app, "more-after-switch")

        // One header on every tab: the titles share a size and a y.
        func title(_ name: String) -> CGRect {
            select(name)
            let text = app.navigationBars.staticTexts[name].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5), "\(name) title")
            Thread.sleep(forTimeInterval: 0.5)
            return text.frame
        }
        let bots = title("Bots"), sessions = title("Sessions"), jobs = title("Jobs")
        for (name, frame) in [("Sessions", sessions), ("Jobs", jobs)] {
            XCTAssertEqual(frame.minY, bots.minY, accuracy: 1, "\(name)'s title sits where Bots' does")
            XCTAssertEqual(frame.height, bots.height, accuracy: 1, "\(name)'s title is the size of Bots'")
        }
        shot(app, "jobs-two-gateways")

        // Jobs stays picked across a relaunch (the switch's tabs remember again).
        Thread.sleep(forTimeInterval: 0.5)
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = appearanceArguments + ["-HQDebugNoDrag", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Jobs"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 5) { app.tabBars.buttons["Jobs"].isSelected }, "the relaunch reopens Jobs")
    }

    @MainActor func testS28S29_NousGatewayRenewsWhileParkedAndSignedOutRow() throws {
        guard ProcessInfo.processInfo.environment["HQN_SETTINGS_CONFIG"] == "C" else { throw XCTSkip("config C only (scripts/e2e-settings.sh <udid> C)") }
        let nous = try SettingsFixture.load("HQN_SETTINGS_B")
        let app = launchSignedIn()
        openSettings(app)
        app.buttons["settings.gateway-card"].tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 5))
        app.buttons["gateway.add"].tap()
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(nous.url)
        let nousButton = app.buttons["sign-in-nous"]
        XCTAssertTrue(nousButton.waitForExistence(timeout: 10), "the gateway offers Sign in with Nous")
        nousButton.tap()
        // The system's consent ("… Wants to Use "127.0.0.1" to Sign In"), then the stand-in Portal's page.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.buttons["Continue"]
        if consent.waitForExistence(timeout: 8) { consent.tap() }
        var owner: XCUIElement?
        for root in [app, XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
            let link = root.links["Continue as owner"].firstMatch
            if link.waitForExistence(timeout: 8) { owner = link; break }
        }
        guard let owner else { dump(app, "nous-portal"); XCTFail("the Portal page's Continue as owner"); return }
        owner.tap()
        let nousRow = app.descendants(matching: .any)["gateway-row-\(nous.hostPort)"]
        XCTAssertTrue(appears(nousRow, app, "nous-added", timeout: 20), "the Nous gateway is added and in use")
        XCTAssertTrue(nousRow.label.contains("Nous account") || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Nous account'")).firstMatch.exists,
                      "its row says Nous account")
        shot(app, "gateway-nous")
        let refreshesBefore = (try nous.control("/__fixture/nous")["counts"] as? [String: Any])?["refresh"] as? Int ?? 0

        // Back to the password gateway; the Nous one is parked with its token about to lapse (30 s).
        app.descendants(matching: .any)["gateway-row-\(a.hostPort)"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { app.staticTexts["Switching…"].exists == false })
        app.navigationBars["Gateways"].buttons.element(boundBy: 0).tap()
        closeSettings(app)
        Thread.sleep(forTimeInterval: 36)
        openTitleMenu(app)
        XCTAssertTrue(waitUntil(timeout: 15) {
            let counts = (try? nous.control("/__fixture/nous"))?["counts"] as? [String: Any]
            return (counts?["refresh"] as? Int ?? 0) == refreshesBefore + 1
        }, "the news check renewed the parked Nous token once")
        let counts = (try nous.control("/__fixture/nous")["counts"] as? [String: Any]) ?? [:]
        XCTAssertEqual(counts["refreshReplayed"] as? Int ?? 0, 0, "no refresh token was replayed")
        app.buttons["gateway-menu-\(nous.hostPort)"].firstMatch.tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 15), "switching back needs no sign-in")
        XCTAssertFalse(app.textFields["sign-in-address"].exists)

        // S29: Portal revokes the parked account; the next check signs it out here.
        openTitleMenu(app)
        app.buttons["gateway-menu-\(a.hostPort)"].firstMatch.tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 15))
        try nous.control("/__fixture/nous/revoke", [:])
        Thread.sleep(forTimeInterval: 31)
        openTitleMenu(app)
        let signedOut = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Signed Out'")).firstMatch
        XCTAssertTrue(appears(signedOut, app, "nous-signed-out", timeout: 15), "the Nous row says Signed Out")
        shot(app, "title-menu-signed-out")
        app.buttons["gateway-menu-\(nous.hostPort)"].firstMatch.tap()
        let cancel = app.buttons["add-gateway.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "the prefilled sign-in")
        XCTAssertEqual(app.textFields["sign-in-address"].value as? String, nous.url)
        cancel.tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 5), "Cancel stays on the password gateway")
    }

    // MARK: - Helpers

    let hint = "Hold a bot or group chat and drag it here, or choose Move to Section in its menu."

    /// A clean phone signed in to the fixture. Drag and drop is off unless a test drags: with it on, XCUITest's synthesized
    /// long press leaves UIKit's drag lift pending and every later step waits 60 s for the app to idle.
    /// [filters-only] `row`: the bot whose row says the list is in (a roster cut to one bot has no Ivy).
    @MainActor func launchSignedIn(_ arguments: [String] = [], fixture: SettingsFixture? = nil, drag: Bool = false,
                                   row: String = "ivy") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES"] + appearanceArguments + arguments + (drag ? [] : ["-HQDebugNoDrag", "YES"])
        app.launch()
        signIn(app, fixture ?? a)
        let ivy = app.cells["bot-row-\(row)"]
        if !ivy.waitForExistence(timeout: 20) {
            // A late "Save Password?" sheet can sit over the list; clear it once and look again before failing.
            dismissSavePassword(app, wait: 2)
            XCTAssertTrue(appears(ivy, app, "launch-\(name)", timeout: 10), "the Bots list shows")
        }
        dismissSavePassword(app, wait: 2)
        return app
    }

    var appearanceArguments: [String] {
        let environment = ProcessInfo.processInfo.environment
        return (environment["HQN_SHOTS_DARK"] == "1" ? ["-hqn.appearance", "dark"] : [])
            + (environment["HQN_UI_DESKTOPLOOK"] == "1" ? ["-HQDebugDesktopLook", "YES"] : [])
    }

    @MainActor func signIn(_ app: XCUIApplication, _ fixture: SettingsFixture) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), "the sign-in form shows")
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(fixture.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText(fixture.username)
        // At accessibility sizes the field sits under the keyboard: bring it up first. A tap during the keyboard's settle
        // can miss the field, so type again only when it is still empty (a secure field clears itself when typed into
        // again, so never "fix" a filled one).
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            for _ in 0..<5 where !password.isHittable { app.swipeUp() }
            password.tap()
            password.typeText(fixture.password)
            let typed = (password.value as? String) ?? ""
            if !typed.isEmpty, typed != password.placeholderValue { break }
        }
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        button.tap()
        dismissSavePassword(app, wait: 3)
    }

    /// Opens a bot's chat and sends `text`.
    @MainActor func talk(_ app: XCUIApplication, to bot: String, _ text: String) {
        let row = app.cells["bot-row-\(bot)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the chat opens")
        field.tap()
        field.typeText(text)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
    }

    /// The edit-head stage's DEBUG fields ("color=…;seed=…;form=…").
    @MainActor func headFields(_ stage: XCUIElement) -> [String: String] {
        let value = (stage.value as? String) ?? ""
        guard let open = value.firstIndex(of: "["), let close = value.lastIndex(of: "]") else { return [:] }
        var fields: [String: String] = [:]
        for pair in value[value.index(after: open)..<close].split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields
    }

    /// The screen's median brightness (0 black … 1 white), from a 12 × 24 downsample of a screenshot.
    @MainActor func pageLuminance(_ app: XCUIApplication) -> Double {
        guard let image = app.screenshot().image.cgImage else { return -1 }
        let width = 12, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return -1 }
        var values: [Double] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            values.append((0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255)
        }
        values.sort()
        return values[values.count / 2]
    }

    /// iOS offers to save the typed password, sometimes seconds after the sign-in: decline it so it never takes a tap.
    @MainActor func dismissSavePassword(_ app: XCUIApplication, wait: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists {
                candidate.tap()
                return
            }
            if wait > 0 { Thread.sleep(forTimeInterval: 0.25) }
        } while Date() < deadline
    }

    /// Long-presses until the menu shows `item`, then taps it (a press during the list's first reload can be lost).
    @MainActor func pressMenu(_ app: XCUIApplication, _ element: XCUIElement, _ item: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0..<3 {
            dismissSavePassword(app)
            element.press(forDuration: 1.0)
            if app.buttons[item].firstMatch.waitForExistence(timeout: 3) { break }
        }
        tapMenu(app, item, file: file, line: line)
    }

    /// Taps a context-menu (or pull-down) item by its title.
    @MainActor func tapMenu(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = app.buttons[title].firstMatch
        if item.waitForExistence(timeout: 4) { item.tap(); return }
        let any = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        if !any.waitForExistence(timeout: 2) { dump(app, "menu-\(title)") }
        XCTAssertTrue(any.exists, "menu item \(title)", file: file, line: line)
        any.tap()
    }

    /// A SwiftUI Toggle's row is a switch holding the real switch: tap that one.
    @MainActor func flip(_ element: XCUIElement) {
        let inner = element.switches.firstMatch
        (inner.exists ? inner : element).tap()
    }

    @MainActor func openTitleMenu(_ app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        let candidates = [app.buttons["gateway-switcher"].firstMatch, bar.buttons["Bots"], bar.staticTexts["Bots"]]
        for element in candidates where element.waitForExistence(timeout: 2) {
            element.tap()
            return
        }
        dump(app, "title")
        XCTFail("no title to tap")
    }

    /// More › Settings (as on the web, the Bots bar has no Settings button). A second tap on More pops a page left open.
    /// By its id: Desktop Look docks its own bar in place of the system one, and its More carries the same id.
    @MainActor func openSettings(_ app: XCUIApplication) {
        let more = app.tabButton(id: "tab-more", label: "More")
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let row = app.cells["more-row-settings"]
        for _ in 0..<4 {
            dismissSavePassword(app)
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
        }
        for _ in 0..<3 {
            row.tap()
            if app.buttons["settings.gateway-card"].waitForExistence(timeout: 3) { return }
        }
    }

    /// Leaves Settings for the Bots list (Settings stays on More's stack; the next `openSettings` pops it).
    @MainActor func closeSettings(_ app: XCUIApplication) {
        let close = app.buttons["settings.close"]
        if close.exists { close.tap(); return }
        let bots = app.tabBars.buttons["Bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 5))
        bots.tap()
        _ = waitUntil(timeout: 3) { bots.isSelected }
    }

    @MainActor func openBotInfo(_ app: XCUIApplication, _ id: String) {
        let row = app.cells["bot-row-\(id)"].exists ? app.cells["bot-row-\(id)"] : app.cells["bot-tile-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        pressMenu(app, row, "Bot Info")
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 5), "Bot Info opens")
    }

    /// Taps a menu button until its menu shows `item` (a first tap right after launch can land before the bar is live).
    @MainActor func openMenu(_ app: XCUIApplication, _ button: XCUIElement, showing item: String) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            button.tap()
            if app.buttons[item].firstMatch.waitForExistence(timeout: 2) { return }
        }
    }

    /// Taps an alert's button; once more if the alert is still up a second later (a tap during the keyboard's settle).
    @MainActor func confirmAlert(_ app: XCUIApplication, _ title: String) {
        let button = app.alerts.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.4)
        button.tap()
        if button.waitForExistence(timeout: 1.0), button.isHittable { button.tap() }
    }

    /// Waits for an element; on failure saves the tree and a screenshot as debug-<name>.
    @MainActor @discardableResult
    func appears(_ element: XCUIElement, _ app: XCUIApplication, _ name: String, timeout: TimeInterval = 5) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        dump(app, name)
        return false
    }

    /// The element tree, for a failure's diagnosis (.build/shots/debug-<name>.txt).
    @MainActor func dump(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty else { return }
        try? app.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("debug-\(name).txt"), atomically: true, encoding: .utf8)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("debug-\(name).png"))
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    /// A screenshot into .build/shots (light or dark by the run) and the test's attachments.
    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let mode = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(mode)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIElement {
    /// Clears a field's text and types new text.
    func clearAndType(_ text: String) {
        tap()
        let current = (value as? String) ?? ""
        if !current.isEmpty, current != placeholderValue {
            // Select All, then type over it (deletes from wherever the caret landed can miss text after it).
            press(forDuration: 1.1)
            let selectAll = XCUIApplication().menuItems["Select All"].exists ? XCUIApplication().menuItems["Select All"]
                : XCUIApplication().buttons["Select All"]
            if selectAll.waitForExistence(timeout: 2) {
                selectAll.tap()
                typeText(XCUIKeyboardKey.delete.rawValue)
            } else {
                typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            }
        } else if !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        typeText(text)
    }
}
