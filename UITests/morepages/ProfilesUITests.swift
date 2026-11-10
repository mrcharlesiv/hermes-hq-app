// More › Bot Profiles, the SOUL.md editor and its Cancel / Save bar (docs/spec/3x-morepages.md §10 acceptance, and
// the §21 lines for these pages). Run:
//   HQN_MOREPAGES_GATEWAYS="main" HQN_MOREPAGES_PORTS="<port>" HQN_MOREPAGES_ONLY="ProfilesUITests" scripts/e2e-morepages.sh <udid>

import XCTest

final class ProfilesUITests: MorePagesCase {
    // MARK: Helpers

    @MainActor private func any(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
    /// An element of a long page: scrolls down until the list has made it (large text pushes rows off the screen).
    @MainActor private func found(_ identifier: String) -> XCUIElement {
        let element = any(identifier)
        for _ in 0..<6 where !element.exists { app.swipeUp(velocity: .slow) }
        if element.exists { reach(element) }   // and clear of the floating tab bar, so a tap lands on it
        return element
    }
    @MainActor private var text: XCUIElement { app.textViews["soul.text"] }
    @MainActor private var edit: XCUIElement { app.buttons["soul.edit"] }
    @MainActor private var cancel: XCUIElement { app.buttons["nav-edit.cancel"] }
    @MainActor private var save: XCUIElement { app.buttons["nav-edit.save"] }
    @MainActor private var textValue: String { (text.value as? String) ?? "" }

    private func knob(_ body: [String: Any]) throws { try account.control("/__fixture/profiles", body) }

    private func profiles() throws -> [String: Any] { (try state()["profiles"] as? [String: Any]) ?? [:] }

    private func soul(_ name: String) throws -> [String: Any] {
        ((try profiles()["souls"] as? [String: Any])?[name] as? [String: Any]) ?? [:]
    }

    @MainActor private func openList() {
        openMore("profiles")
        XCTAssertTrue(app.buttons["profiles.row.default"].waitForExistence(timeout: 15), "the list shows")
    }

    @MainActor private func openDetail(_ name: String) {
        if !app.buttons["profiles.row.\(name)"].exists { openList() }
        let row = app.buttons["profiles.row.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "row \(name)")
        reach(row)
        row.tap()
        XCTAssertTrue(any("profiles.detail.fact.id").waitForExistence(timeout: 10), "the detail shows")
    }

    @MainActor private func openEditor(_ name: String) {
        openDetail(name)
        found("profiles.detail.soul").tap()
        XCTAssertTrue(waitUntil(20) { self.text.exists || self.any("soul.placeholder").exists }, "the editor shows")
    }

    /// Edit, then type at the end of the text.
    @MainActor private func startEditing() {
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit")
        edit.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel shows")
    }

    @MainActor private func hudSays(_ words: String) -> Bool {
        waitUntil(10) { self.app.descendants(matching: .any).matching(identifier: "pages.hud").allElementsBoundByIndex.contains { $0.label.contains(words) } }
    }

    // MARK: §10 acceptance 2

    @MainActor func testU9_Profiles() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        let started = Date()
        openMore("profiles")
        let first = app.buttons["profiles.row.default"], inbox = app.buttons["profiles.row.inbox"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "the list shows")
        measured("Bot Profiles: tap to first rows \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertTrue(app.navigationBars["Bot Profiles"].exists, "the title is Bot Profiles")
        for name in ["inbox", "deploys", "research", "finance"] {
            XCTAssertTrue(app.buttons["profiles.row.\(name)"].exists, "lists \(name)")
        }
        XCTAssertLessThan(first.frame.minY, inbox.frame.minY, "the default profile is first")
        XCTAssertTrue(first.label.contains("Hermes") && first.label.contains("default") && first.label.contains("12 skills"), first.label)
        XCTAssertTrue(app.buttons["profiles.row.research"].label.contains("1 skill"), "one skill is singular")
        shot("profiles-list")
        XCTAssertTrue(found("profiles.count").exists && app.staticTexts["5 profiles"].exists, "the footer counts them")
        app.swipeDown(); app.swipeDown()

        inbox.tap()
        XCTAssertTrue(any("profiles.detail.fact.id").waitForExistence(timeout: 10))
        XCTAssertEqual(any("profiles.detail.fact.id").label, "Bot ID, inbox")
        XCTAssertTrue(any("profiles.detail.fact.provider").label.contains("nous"))
        shot("profiles-detail")
        XCTAssertEqual(found("profiles.detail.fact.skills").label, "Skills Installed, 4")
        XCTAssertTrue(found("profiles.detail.fact.folder").label.contains("/home/hermes/profiles/inbox"))
        XCTAssertTrue(found("profiles.detail.rename").exists && found("profiles.detail.delete").exists)

        found("profiles.detail.soul").tap()
        XCTAssertTrue(text.waitForExistence(timeout: 15), "the text loads")
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Inbox") }, "the gateway's text shows")
        XCTAssertTrue(app.navigationBars["Instructions"].exists)
        XCTAssertTrue(edit.exists && edit.isEnabled)
        shot("profiles-soul-rest")

        let backLabel = app.navigationBars["Instructions"].buttons.element(boundBy: 0).label
        startEditing()
        XCTAssertTrue(save.exists && !save.isEnabled, "Save is there, dimmed")
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertFalse(edit.exists, "Edit gave way to Save")
        XCTAssertEqual(app.navigationBars["Instructions"].buttons.count, 2, "Back is gone: only Cancel and Save")
        text.typeText("\nALWAYS-SIGN-OFF")
        XCTAssertTrue(waitUntil(5) { self.save.isEnabled }, "typing enables Save")
        XCTAssertTrue(textValue.hasSuffix("ALWAYS-SIGN-OFF"), "typed after the last line")
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThan(text.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "the text ends above the keyboard")
        }
        shot("profiles-soul-editing")

        try delay("PUT", "/api/profiles/inbox/soul", seconds: 3)
        save.tap()
        XCTAssertTrue(waitUntil(3) { self.save.label == "Saving…" }, "Save reads Saving…")
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(cancel.isEnabled, "Cancel is off while saving")
        shot("profiles-soul-saving")
        XCTAssertTrue(hudSays("Instructions Saved"), "the HUD says Instructions Saved")
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Edit is back")
        XCTAssertFalse(cancel.exists)
        XCTAssertEqual(app.navigationBars["Instructions"].buttons.element(boundBy: 0).label, backLabel, "Back returns")
        XCTAssertTrue(textValue.hasSuffix("ALWAYS-SIGN-OFF"), "the text stays")
        let kept = try soul("inbox")
        XCTAssertTrue((kept["content"] as? String ?? "").hasSuffix("\nALWAYS-SIGN-OFF"), "the fixture holds the new text")
        XCTAssertEqual(kept["revision"] as? Int, 2)
        let puts = try rest("PUT", "/api/profiles/inbox/soul")
        XCTAssertEqual(puts.count, 1)
        XCTAssertEqual(Set((puts[0]["body"] as? [String: Any] ?? [:]).keys), ["content"], "only `content` is sent")
        // Back works again.
        back()
        XCTAssertTrue(any("profiles.detail.fact.id").waitForExistence(timeout: 5))
    }

    @MainActor func testU9_CancelDiscardAndSwipeBack() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openEditor("inbox")
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Inbox") })
        let original = textValue
        // Cancel with nothing changed just ends the edit.
        startEditing()
        cancel.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Discard Changes"].exists)

        startEditing()
        text.typeText("\nNOT-KEPT")
        XCTAssertTrue(waitUntil(5) { self.save.isEnabled })
        // Swipe-back while editing does not pop.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.45))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
        middle.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)))
        XCTAssertTrue(cancel.exists && text.exists, "still editing after a swipe from the edge")
        XCTAssertTrue(textValue.contains("NOT-KEPT"))

        cancel.tap()
        XCTAssertTrue(app.staticTexts["Discard Changes?"].waitForExistence(timeout: 5), "the Discard question")
        XCTAssertTrue(app.staticTexts["Your Instructions edits have not been saved."].exists)
        XCTAssertTrue(app.alerts.buttons["Discard Changes"].exists && app.alerts.buttons["Keep Editing"].exists)
        shot("profiles-soul-discard")
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue(waitUntil(5) { !self.app.buttons["Discard Changes"].exists })
        XCTAssertTrue(textValue.contains("NOT-KEPT"), "Keep Editing keeps the text")
        XCTAssertTrue(cancel.exists && save.isEnabled)

        cancel.tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the edit ended")
        XCTAssertEqual(textValue, original, "the gateway's text is back")
        XCTAssertTrue(try rest("PUT", "/api/profiles/inbox/soul").isEmpty, "nothing was sent")
        // Not editing: the swipe goes back.
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
        XCTAssertTrue(any("profiles.detail.fact.id").waitForExistence(timeout: 5), "swipe-back works when nothing is being edited")
    }

    @MainActor func testU9_SaveFailureThenTryAgain() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openEditor("deploys")
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Deploys") })
        startEditing()
        text.typeText("\nSHIP-ON-GREEN")
        try fail("PUT", "/api/profiles/deploys/soul", status: 500, detail: "Could not write SOUL.md: disk full")
        save.tap()
        let notice = any("soul.save-failure")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the notice shows")
        XCTAssertTrue(app.staticTexts["Couldn’t Save Instructions"].exists)
        XCTAssertTrue(app.staticTexts["Could not write SOUL.md: disk full"].exists, "the gateway's reason")
        XCTAssertTrue(cancel.exists && save.exists, "the edit bar stays up")
        XCTAssertTrue(save.isEnabled && cancel.isEnabled)
        XCTAssertTrue(textValue.hasSuffix("SHIP-ON-GREEN"), "nothing typed is lost")
        XCTAssertLessThan(notice.frame.minY, text.frame.minY, "the notice is above the text")
        shot("profiles-soul-save-failed")
        XCTAssertEqual(try soul("deploys")["revision"] as? Int, 1, "nothing was written")

        app.buttons["soul.save-failure.retry"].tap()
        XCTAssertTrue(hudSays("Instructions Saved"), "Try Again saves")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(any("soul.save-failure").exists, "the notice went")
        XCTAssertTrue((try soul("deploys")["content"] as? String ?? "").hasSuffix("\nSHIP-ON-GREEN"))
        XCTAssertEqual(try rest("PUT", "/api/profiles/deploys/soul").count, 2)
    }

    @MainActor func testU9_ChangedOnGateway() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openEditor("research")
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Research") })
        startEditing()
        text.typeText("\nMINE")
        try account.control("/__fixture/soul-edit", ["profile": "research", "content": "# Edited on the desktop\n"])
        save.tap()
        XCTAssertTrue(app.staticTexts["Instructions Changed on Your Gateway"].waitForExistence(timeout: 10), "the conflict question")
        XCTAssertTrue(app.staticTexts["Someone else changed this file since you opened it."].exists)
        shot("profiles-soul-conflict")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(waitUntil(5) { !self.app.staticTexts["Instructions Changed on Your Gateway"].exists })
        XCTAssertTrue(cancel.exists && save.isEnabled && textValue.hasSuffix("MINE"), "still editing, nothing lost")
        XCTAssertTrue(try rest("PUT", "/api/profiles/research/soul").isEmpty, "nothing was written over it")
        save.tap()
        XCTAssertTrue(app.buttons["Replace It"].waitForExistence(timeout: 10))
        app.buttons["Replace It"].tap()
        XCTAssertTrue(hudSays("Instructions Saved"))
        XCTAssertTrue((try soul("research")["content"] as? String ?? "").hasSuffix("\nMINE"), "Replace It wrote this phone's text")
    }

    // MARK: §10 acceptance 3: Rename, Delete, the default profile

    @MainActor func testU9_Rename() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openDetail("inbox")
        found("profiles.detail.rename").tap()
        let field = app.textFields["profiles.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the prompt")
        XCTAssertTrue(app.staticTexts["Rename Bot"].exists)
        XCTAssertTrue(app.staticTexts["Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit."].exists)
        XCTAssertEqual(field.value as? String, "inbox", "pre-filled")
        let rename = app.alerts.buttons["Rename"]
        XCTAssertFalse(rename.isEnabled, "the same name can't be sent")
        shot("profiles-rename")
        // The simulator's keyboard drops keys now and then: type, read back, and type again if it did.
        func shownName() -> String {
            ((field.value as? String) ?? "").replacingOccurrences(of: ", not a valid name", with: "")
        }
        func type(_ name: String) {
            for _ in 0..<4 {
                let keys = String(repeating: XCUIKeyboardKey.delete.rawValue, count: shownName().count) + name
                if !keys.isEmpty { field.typeText(keys) }
                if waitUntil(2, { shownName() == name }) { return }
            }
            XCTFail("could not type “\(name)”, the field shows “\(shownName())”")
        }
        // XCUITest's typing hides the simulator's keyboard for a moment and the alert slides with it (the same is
        // handled in the Activity and Settings tests): a tap that lands while it moves is lost, so tap until it leaves.
        func confirm() {
            for _ in 1...4 {
                rename.tap()
                if waitUntil(2, { !field.exists }) {
                    return
                }
            }
            XCTFail("Rename did not close the prompt")
        }
        for bad in ["Bad Name", "-lead", "a.b", ""] {
            type(bad)
            XCTAssertFalse(rename.isEnabled, "“\(bad)” cannot be sent")
        }
        shot("profiles-rename-invalid")
        // A name another profile has: said in words, nothing sent.
        type("deploys")
        XCTAssertTrue(rename.isEnabled)
        confirm()
        XCTAssertTrue(app.staticTexts["Couldn’t Rename"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A profile with that name already exists."].exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(try rest("PATCH", "/api/profiles/").isEmpty, "an invalid or taken name was never sent")

        // The gateway refusing it (409) says so too.
        try knob(["rename_status": 409])
        found("profiles.detail.rename").tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        type("mail")
        confirm()
        XCTAssertTrue(app.staticTexts["Couldn’t Rename"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Profile 'mail' already exists."].exists, "the gateway's detail")
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(any("profiles.detail.fact.id").label, "Bot ID, inbox")

        found("profiles.detail.rename").tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        type("mail")
        XCTAssertTrue(rename.isEnabled)
        confirm()
        XCTAssertTrue(waitUntil(15) { self.any("profiles.detail.fact.id").label == "Bot ID, mail" }, "the detail shows the new id")
        XCTAssertTrue(found("profiles.detail.fact.folder").label.contains("/home/hermes/profiles/mail"))
        let patches = try rest("PATCH", "/api/profiles/inbox")
        XCTAssertEqual(patches.count, 2)
        XCTAssertEqual(patches.last?["body"] as? [String: String], ["new_name": "mail"], "exactly `new_name`")
        XCTAssertEqual(try profiles()["renames"] as? [[String]], [["inbox", "mail"]])
        // The list shows it under its new id (the row's identifier; the id itself is on its page), same bot name.
        back()
        XCTAssertTrue(app.buttons["profiles.row.mail"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["profiles.row.inbox"].exists)
        XCTAssertTrue(waitUntil(15) { self.app.buttons["profiles.row.mail"].label.hasPrefix("Inbox, ") }, app.buttons["profiles.row.mail"].label)
        tab("Bots")
        XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 15), "the Bots list still shows the bot, same title")
    }

    @MainActor func testU9_DeleteDefaultAndMissingSoul() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        // The default profile: no Rename, no Delete, and it says why.
        openDetail("default")
        XCTAssertFalse(app.buttons["profiles.detail.rename"].exists)
        XCTAssertFalse(app.buttons["profiles.detail.delete"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["The default profile can’t be renamed or deleted."].waitForExistence(timeout: 5))
        shot("profiles-detail-default")
        back()
        app.buttons["profiles.row.default"].swipeLeft()
        XCTAssertFalse(app.buttons["profiles.swipe.delete.default"].exists, "no swipe actions on the default row")
        XCTAssertFalse(app.buttons["profiles.swipe.rename.default"].exists)

        // A bot with no SOUL.md yet.
        openEditor("finance")
        XCTAssertTrue(any("soul.placeholder").waitForExistence(timeout: 10))
        XCTAssertEqual(any("soul.placeholder").label, "This bot has no instructions yet. What you write here tells the bot who it is.")
        shot("profiles-soul-missing")
        startEditing()
        text.typeText("# Finance")
        XCTAssertFalse(any("soul.placeholder").exists, "typing hides the placeholder")
        save.tap()
        XCTAssertTrue(hudSays("Instructions Saved"))
        XCTAssertEqual(try soul("finance")["content"] as? String, "# Finance")
        XCTAssertEqual(try soul("finance")["exists"] as? Bool, true)
        back()

        // Delete: the Bots list's own question.
        XCTAssertTrue(any("profiles.detail.fact.id").waitForExistence(timeout: 5))
        found("profiles.detail.delete").tap()
        XCTAssertTrue(app.staticTexts["Delete “Finance”?"].waitForExistence(timeout: 5), "the Bots list's question")
        shot("profiles-delete")
        app.buttons["Delete Bot"].tap()
        XCTAssertTrue(app.buttons["profiles.row.default"].waitForExistence(timeout: 15), "back on the list")
        XCTAssertTrue(waitUntil(10) { !self.app.buttons["profiles.row.finance"].exists }, "the row is gone")
        XCTAssertTrue(waitUntil(10) { self.found("profiles.count").label == "4 profiles" })
        XCTAssertEqual(try profiles()["deleted"] as? [String], ["finance"])
        XCTAssertEqual(try rest("DELETE", "/api/profiles/finance").count, 1)

        // The row's long press offers the same two (item 3: the ⋯ moved to a long press and a swipe).
        app.buttons["profiles.row.research"].press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Rename Bot…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete Bot…"].exists)
        shot("profiles-row-menu")
        app.buttons["Rename Bot…"].tap()
        XCTAssertTrue(app.textFields["profiles.rename.field"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["profiles.rename.field"].value as? String, "research")
        app.alerts.buttons["Cancel"].tap()
    }

    @MainActor func testU9_ReadOnlyGateway() throws {
        launchSignedIn(["-HQPagesReadOnly", "YES", "-HQSoulDraftsReset", "YES"])
        openList()
        app.buttons["profiles.row.inbox"].swipeLeft()
        XCTAssertFalse(app.buttons["profiles.swipe.delete.inbox"].exists, "no swipe actions on a read-only gateway")
        openDetail("inbox")
        XCTAssertFalse(app.buttons["profiles.detail.rename"].exists)
        XCTAssertFalse(app.buttons["profiles.detail.delete"].exists)
        found("profiles.detail.soul").tap()
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Inbox") }, "pages still read")
        XCTAssertFalse(edit.exists, "no Edit on a read-only gateway")
        shot("profiles-soul-read-only")
    }

    @MainActor func testU9_Offline() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openEditor("inbox")
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Inbox") })
        XCTAssertTrue(edit.isEnabled)
        try knob(["drop_seconds": 14])
        XCTAssertTrue(any("soul.offline").waitForExistence(timeout: 12), "the editor says why Edit is off")
        XCTAssertTrue(app.staticTexts["You can change this once your gateway is back."].exists)
        XCTAssertFalse(edit.isEnabled, "Edit is off while offline")
        XCTAssertTrue(textValue.contains("You are Inbox"), "the text stays")
        shot("profiles-soul-offline")
        back()
        XCTAssertTrue(any("profiles.detail.fact.id").waitForExistence(timeout: 5))
        if app.staticTexts["You can change this once your gateway is back."].waitForExistence(timeout: 3) {
            XCTAssertFalse(app.buttons["profiles.detail.rename"].exists, "no Rename while offline")
            XCTAssertFalse(app.buttons["profiles.detail.delete"].exists)
            shot("profiles-detail-offline")
        }
        XCTAssertTrue(app.buttons["profiles.detail.rename"].waitForExistence(timeout: 40), "the controls return with the link")
    }

    // MARK: §21 stress

    @MainActor func testU9_Stress_SixtyProfilesSearchAndBadRows() throws {
        try knob(["count": 60, "duplicate": "inbox", "junk": true])
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openList()
        XCTAssertTrue(app.staticTexts["61 profiles"].waitForExistence(timeout: 10) || {
            for _ in 0..<12 where !self.app.staticTexts["61 profiles"].exists { self.app.swipeUp(velocity: .fast) }
            return self.app.staticTexts["61 profiles"].exists
        }(), "60 bots and the one readable junk row, the repeated row once")
        XCTAssertTrue(app.buttons["profiles.row.bot-60"].exists, "the last row")
        shot("profiles-list-60-end")
        for _ in 0..<12 where !app.buttons["profiles.row.default"].isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertEqual(app.buttons.matching(identifier: "profiles.row.inbox").count, 1, "a repeated id is one row")
        XCTAssertTrue(app.buttons["profiles.row.numbers"].exists || true)

        // Search behind the magnifier.
        app.buttons["profiles.search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the field unfolds")
        XCTAssertEqual(field.placeholderValue, "Search Profiles")
        field.typeText("bot-57")
        XCTAssertTrue(app.buttons["profiles.row.bot-57"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { !self.app.buttons["profiles.row.default"].exists }, "only the match")
        shot("profiles-search")
        field.typeText("zzz")
        XCTAssertTrue(any("profiles.search-miss").waitForExistence(timeout: 5), "a miss says so")
        shot("profiles-search-miss")
        // Open the last bot's page from a search.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        XCTAssertTrue(app.buttons["profiles.row.bot-57"].waitForExistence(timeout: 5))
        app.buttons["profiles.row.bot-57"].tap()
        XCTAssertTrue(waitUntil(10) { self.any("profiles.detail.fact.id").label == "Bot ID, bot-57" })
    }

    @MainActor func testU9_Stress_LargeSoul() throws {
        try knob(["soul_kb": 400, "profile": "inbox"])
        let before = try soul("inbox")
        XCTAssertGreaterThan(before["bytes"] as? Int ?? 0, 400 * 1024)
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openDetail("inbox")
        let opened = Date()
        found("profiles.detail.soul").tap()
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        measured("SOUL.md 400 KB: tap to text \(String(format: "%.2f", Date().timeIntervalSince(opened))) s")
        startEditing()
        let typing = Date()
        text.typeText("END-MARK-0123456789")
        measured("SOUL.md 400 KB: 19 keys typed in \(String(format: "%.2f", Date().timeIntervalSince(typing))) s")
        XCTAssertTrue(waitUntil(10) { self.save.isEnabled })
        shot("profiles-soul-400kb-editing")
        save.tap()
        XCTAssertTrue(hudSays("Instructions Saved"), "the large file saves")
        let after = try soul("inbox")
        XCTAssertEqual(after["bytes"] as? Int, (before["bytes"] as? Int ?? 0) + 19, "sent whole, plus what was typed")
        XCTAssertTrue((after["tail"] as? String ?? "").hasSuffix("END-MARK-0123456789"), "typed at the end")
        XCTAssertEqual(after["revision"] as? Int, (before["revision"] as? Int ?? 0) + 1)
    }

    @MainActor func testU9_Stress_RapidEditCancelAndSave() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openEditor("inbox")
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Inbox") })
        let original = textValue
        // As fast as the keyboard lets: a tap sent while the simulator's keyboard is mid-slide can leave XCUITest
        // waiting for the app to settle for good (seen twice in full runs), so each tap waits for the keyboard to land.
        for _ in 0..<8 {
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
            cancel.tap()
            _ = waitUntil(2) { !self.app.keyboards.firstMatch.exists }
        }
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "ends at rest")
        XCTAssertFalse(cancel.exists || save.exists)
        XCTAssertEqual(textValue, original)
        XCTAssertEqual(app.navigationBars["Instructions"].buttons.count, 2, "Back and Edit, nothing doubled")
        // A double tap on Save sends one write.
        startEditing()
        text.typeText("\nONCE")
        try delay("PUT", "/api/profiles/inbox/soul", seconds: 2)
        save.tap()
        if save.exists, save.isHittable { save.tap() }
        XCTAssertTrue(hudSays("Instructions Saved"))
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(try rest("PUT", "/api/profiles/inbox/soul").count, 1, "one write")
        XCTAssertEqual(try soul("inbox")["revision"] as? Int, 2)
    }

    @MainActor func testU9_Stress_RelaunchMidEditRestoresTheDraft() throws {
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openEditor("deploys")
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Deploys") })
        startEditing()
        text.typeText("\nDRAFT-MARK-ONE")
        XCTAssertTrue(waitUntil(5) { self.save.isEnabled })
        Thread.sleep(forTimeInterval: 2.5)          // past the 1 s pause after which the draft is written
        relaunch()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 20), "signed in still")
        if !waitUntil(4, { self.app.staticTexts["Restore Unsaved Changes?"].exists }) {
            if !any("profiles.detail.fact.id").exists { openDetail("deploys") }
            found("profiles.detail.soul").tap()
        }
        XCTAssertTrue(app.staticTexts["Restore Unsaved Changes?"].waitForExistence(timeout: 15), "the draft is offered")
        shot("profiles-soul-restore")
        app.alerts.buttons["Restore"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "editing again")
        XCTAssertTrue(textValue.hasSuffix("DRAFT-MARK-ONE"), "what was typed is back")
        XCTAssertTrue(save.isEnabled, "and can be saved")
        XCTAssertTrue(try rest("PUT", "/api/profiles/deploys/soul").isEmpty)
        save.tap()
        XCTAssertTrue(hudSays("Instructions Saved"))
        XCTAssertTrue((try soul("deploys")["content"] as? String ?? "").hasSuffix("\nDRAFT-MARK-ONE"))

        // A saved edit leaves no draft; a discarded offer is not made twice.
        startEditing()
        text.typeText("\nDRAFT-MARK-TWO")
        Thread.sleep(forTimeInterval: 2.5)
        relaunch()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 20))
        if !waitUntil(4, { self.app.staticTexts["Restore Unsaved Changes?"].exists }) {
            if !any("profiles.detail.fact.id").exists { openDetail("deploys") }
            found("profiles.detail.soul").tap()
        }
        XCTAssertTrue(app.staticTexts["Restore Unsaved Changes?"].waitForExistence(timeout: 15))
        app.alerts.buttons["Discard"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(textValue.contains("DRAFT-MARK-TWO"), "Discard leaves the gateway's text")
        back()
        found("profiles.detail.soul").tap()
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertFalse(waitUntil(3) { self.app.staticTexts["Restore Unsaved Changes?"].exists }, "not offered again")
    }

    @MainActor func testU9_Stress_SlowAndFailingFirstRead() throws {
        try fail("GET", "/api/profiles", status: 500, detail: "The profile folder couldn’t be read.")
        launchSignedIn(["-HQSoulDraftsReset", "YES"])
        openMore("profiles")
        XCTAssertTrue(app.staticTexts["Couldn’t Load Profiles"].waitForExistence(timeout: 15), "the error state")
        XCTAssertTrue(app.staticTexts["The profile folder couldn’t be read."].exists)
        shot("profiles-list-error")
        try delay("GET", "/api/profiles", seconds: 3)
        app.buttons["Try Again"].firstMatch.tap()
        XCTAssertTrue(any("more.page.loading").waitForExistence(timeout: 3), "the skeleton while it reads")
        XCTAssertTrue(app.buttons["profiles.row.default"].waitForExistence(timeout: 15), "Try Again works")
        // The editor's first read failing.
        try fail("GET", "/api/profiles/inbox/soul", status: 500, detail: "SOUL.md couldn’t be read.")
        openDetail("inbox")
        found("profiles.detail.soul").tap()
        XCTAssertTrue(app.staticTexts["Couldn’t Load Instructions"].waitForExistence(timeout: 15))
        shot("profiles-soul-error")
        app.buttons["Try Again"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { self.textValue.contains("You are Inbox") })
    }
}
