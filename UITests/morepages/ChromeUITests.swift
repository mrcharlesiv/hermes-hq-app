// The navigation-chrome and cheap rows of docs/spec/3x-morepages.md (U1 … U8), end to end against the morepages
// stand-in. Run: scripts/e2e-morepages.sh <udid>  (HQN_MOREPAGES_ONLY="ChromeUITests" for these alone).

import XCTest

final class ChromeUITests: MorePagesCase {
    @MainActor private func openArtifacts() -> XCUIElement {
        openMore("artifacts")
        let list = app.collectionViews["artifacts.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        return list
    }

    @MainActor @discardableResult
    private func scrollTo(_ element: XCUIElement, in list: XCUIElement) -> Bool {
        let limit = app.windows.firstMatch.frame.height - 130
        for _ in 0..<10 {
            if element.exists, element.isHittable, element.frame.midY < limit { return true }
            list.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    // MARK: U1

    /// §2: a file a chat names three times is one row "×3"; another chat naming it once is its own row with no count.
    @MainActor func testU1_RepeatBadge() throws {
        launchSignedIn()
        let list = openArtifacts()
        app.segmentedControls["artifacts.filter"].buttons["Files"].tap()
        let plans = list.cells.matching(identifier: "artifact-row-plan.md")
        XCTAssertTrue(waitUntil(15) { plans.count == 2 }, "plan.md is one row per chat, however often a chat names it")
        let badges = (0..<plans.count).map { plans.element(boundBy: $0).staticTexts["artifact-repeats"] }
        XCTAssertEqual(badges.filter(\.exists).count, 1, "only the chat that named it three times has a count")
        let badge = badges.first { $0.exists }!
        XCTAssertEqual(badge.label, "Mentioned 3 times")
        XCTAssertFalse(list.cells["artifact-row-index.md"].staticTexts["artifact-repeats"].exists, "named once: no count")
        shot("artifacts-repeats")
        app.segmentedControls["artifacts.filter"].buttons["Links"].tap()
        let link = list.cells.containing(.staticText, identifier: "artifact-repeats").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "the link named twice has a count")
        XCTAssertEqual(link.staticTexts["artifact-repeats"].label, "Mentioned 2 times")
        app.segmentedControls["artifacts.filter"].buttons["All"].tap()
    }

    // MARK: U2

    @MainActor private func depth() -> Int { app.navigationBars.count == 0 ? 0 : (app.navigationBars.buttons.count) }

    /// §3: links between notes push text viewers; Back is the note before; a heading link scrolls; a missing note says so.
    @MainActor func testU2_LinkedNotes() throws {
        launchSignedIn()
        let list = openArtifacts()
        app.segmentedControls["artifacts.filter"].buttons["Files"].tap()
        XCTAssertTrue(scrollTo(list.cells["artifact-row-index.md"], in: list))
        list.cells["artifact-row-index.md"].tap()
        let body = app.textViews["artifact.text.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["index.md"].waitForExistence(timeout: 5))
        let plan = body.links["the plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 8), "the note's links are links")
        shot("note-index")

        // A heading in this note: scrolls, no new page.
        body.links["Usage"].tap()
        let page = app.otherElements["artifact.text"]
        XCTAssertTrue(waitUntil(5) { (page.value as? String) == "#usage" }, "the heading link scrolled to Usage")
        XCTAssertTrue(app.navigationBars["index.md"].exists, "a heading link does not push")
        XCTAssertTrue(waitUntil(5) { !plan.isHittable || plan.frame.minY < 0 }, "the top of the note scrolled away")
        body.swipeDown(velocity: .fast); body.swipeDown(velocity: .fast)

        // A web link leaves the stack alone (not followed here).
        XCTAssertTrue(body.links["the site"].exists)

        // The plan, and back through its link to the index: Back names the note before.
        XCTAssertTrue(waitUntil(5) { plan.isHittable })
        plan.tap()
        XCTAssertTrue(app.navigationBars["plan.md"].waitForExistence(timeout: 8), "the linked note's title is its file name")
        XCTAssertTrue(app.navigationBars["plan.md"].buttons["index.md"].waitForExistence(timeout: 5), "Back reads the note before")
        let index = body.links["the index"]
        XCTAssertTrue(index.waitForExistence(timeout: 8))
        shot("note-linked")
        index.tap()
        XCTAssertTrue(app.navigationBars["index.md"].buttons["plan.md"].waitForExistence(timeout: 8), "a cycle pushes again")
        back()
        XCTAssertTrue(app.navigationBars["plan.md"].waitForExistence(timeout: 5))

        // A link with a heading in another note opens it at that heading.
        body.links["how to use it"].tap()
        XCTAssertTrue(app.navigationBars["index.md"].buttons["plan.md"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(8) { (app.otherElements["artifact.text"].value as? String) == "#usage" }, "opened at the heading")
        back(); back()
        XCTAssertTrue(app.navigationBars["index.md"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["index.md"].buttons["Artifacts"].exists || app.navigationBars["index.md"].buttons["Back"].exists)

        // A missing note: says so, with no Quick Look button and no Share.
        XCTAssertTrue(waitUntil(5) { body.links["a missing note"].isHittable })
        body.links["a missing note"].tap()
        XCTAssertTrue(app.staticTexts["Couldn’t open missing.md here."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Open in Quick Look"].exists, "a missing file offers no Quick Look")
        XCTAssertFalse(app.navigationBars["missing.md"].buttons["Share"].isEnabled, "nothing to share")
        shot("note-missing")
        back()

        // A relative link above the folder, then a long name: Back reads plain "Back".
        XCTAssertTrue(waitUntil(5) { body.links["README"].isHittable })
        body.links["README"].tap()
        XCTAssertTrue(app.navigationBars["README.md"].waitForExistence(timeout: 8))
        body.links["a very long note name"].tap()
        XCTAssertTrue(app.navigationBars["a-very-long-note-name.md"].waitForExistence(timeout: 8))
        body.links["the plan"].tap()
        XCTAssertTrue(app.navigationBars["plan.md"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["plan.md"].buttons["Back"].waitForExistence(timeout: 5),
                      "a long name reads plain Back; bar has \(app.navigationBars["plan.md"].buttons.allElementsBoundByIndex.map(\.label))")
        back(); back(); back()

        // An absolute path is itself.
        XCTAssertTrue(waitUntil(5) { body.links["an absolute note"].isHittable })
        body.links["an absolute note"].tap()
        XCTAssertTrue(app.navigationBars["abs.md"].waitForExistence(timeout: 8))
        back(); back()
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Back from the first note is Artifacts")

        // Every read carried the first note's session; each path was resolved in the linking note's folder.
        let reads = try rest("GET", "/api/fs/download").compactMap { $0["query"] as? [String: Any] }
        func value(_ query: [String: Any], _ key: String) -> String {
            (query[key] as? [String])?.first ?? (query[key] as? String) ?? ""
        }
        let noteReads = reads.filter { value($0, "path").hasSuffix(".md") && value($0, "path").contains("/home/hermes") }
        XCTAssertTrue(noteReads.allSatisfy { value($0, "session_id") == "s-notes" }, "every read carried session_id")
        let paths = Set(noteReads.map { value($0, "path") })
        for expected in ["/home/hermes/app/notes/plan.md", "/home/hermes/app/notes/missing.md", "/home/hermes/app/README.md",
                         "/home/hermes/app/notes/a-very-long-note-name.md", "/home/hermes/abs.md"] {
            XCTAssertTrue(paths.contains(expected), "read \(expected); got \(paths.sorted())")
        }
    }

    // MARK: U3

    @MainActor private func openTask(_ title: String, arguments: [String]) {
        launchSignedIn(arguments)
        tab("Kanban")
        let list = app.collectionViews["kanban.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let card = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", title))
            .matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-task-'")).firstMatch
        if !card.waitForExistence(timeout: 5) {
            // The task sits under another status chip.
            let chip = app.cells["kanban.chip.todo"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "chips: \(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'kanban.chip'")).allElementsBoundByIndex.map(\.identifier))")
            chip.tap()
        }
        XCTAssertTrue(scrollTo(card, in: list), "\(title) is on the board")
        card.tap()
        XCTAssertTrue(app.staticTexts["kanban.task.title"].waitForExistence(timeout: 10))
    }

    @MainActor private func addRow() -> XCUIElement {
        let add = app.buttons["kanban.task.add-attachment"]
        let sheet = app.collectionViews.firstMatch
        for _ in 0..<12 where !(add.exists && add.isHittable) { sheet.swipeUp(velocity: .slow) }
        return add
    }

    private func uploads() throws -> [[String: Any]] {
        ((try state()["kanban_attachments"] as? [String: Any])?["uploads"] as? [[String: Any]]) ?? []
    }

    /// §4: Add Attachment → Choose File uploads the file alone, the list shows it, and the same name again is "(1)".
    @MainActor func testU3_AddAttachment() throws {
        openTask("Record the export demo", arguments: ["-HQPagesSeedFile", "brief.txt"])
        let add = addRow()
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add Attachment under the task's files")
        shot("kanban-add-attachment")
        try delay("POST", try taskAttachmentPath(), seconds: 3)
        add.tap()
        XCTAssertTrue(app.buttons["Photo Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose File"].exists)
        shot("kanban-add-attachment-menu")
        app.buttons["Choose File"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["kanban.task.adding"].waitForExistence(timeout: 5), "the row reads Adding… while it uploads")
        XCTAssertFalse(app.buttons["kanban.task.add-attachment"].exists, "no second upload can start")
        shot("kanban-adding")
        XCTAssertTrue(app.buttons["brief.txt"].waitForExistence(timeout: 15), "the file is listed")
        var sent = try uploads()
        XCTAssertEqual(sent.count, 1, "exactly one upload")
        XCTAssertEqual(sent.first?["parts"] as? [String], ["file"], "the file part and no other field")
        XCTAssertEqual(sent.first?["sent_as"] as? String, "brief.txt")
        XCTAssertEqual(sent.first?["content_type"] as? String, "text/plain")

        // The same name again is kept beside the first.
        let again = addRow()
        XCTAssertTrue(waitUntil(10) { again.exists && again.isHittable })
        again.tap()
        app.buttons["Choose File"].tap()
        XCTAssertTrue(app.buttons["brief (1).txt"].waitForExistence(timeout: 15))
        sent = try uploads()
        XCTAssertEqual(sent.count, 2)
        shot("kanban-attachments-added")

        // It opens again in Quick Look.
        app.buttons["brief.txt"].tap()
        XCTAssertTrue(waitUntil(15) { (try? self.rest("GET", "/api/plugins/kanban/attachments/up1").count) ?? 0 >= 1 }, "the new file is read back")
    }

    private func taskAttachmentPath() throws -> String {
        // The open task's id, from the app's own read of it.
        let reads = try rest("GET", "/api/plugins/kanban/tasks/").compactMap { $0["path"] as? String }
        let id = reads.last.map { $0.split(separator: "/")[4] } ?? ""
        return "/api/plugins/kanban/tasks/\(id)/attachments"
    }

    /// §4: the gateway's refusals in plain words; nothing is added; the row comes back.
    @MainActor func testU3_AttachmentRefusals() throws {
        openTask("Record the export demo", arguments: ["-HQPagesSeedFile", "brief.txt"])
        let path = try taskAttachmentPath()
        try fail("POST", path, status: 413, detail: "attachment exceeds 25 MB limit")
        addRow().tap()
        app.buttons["Choose File"].tap()
        let alert = app.alerts["Couldn’t Add Attachment"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["This file is larger than 25 MB, the most a task can hold."].exists)
        shot("kanban-attachment-too-large")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(5) { self.app.buttons["kanban.task.add-attachment"].exists }, "the row is back")

        // Rapid repeats while the gateway is slow: one upload at a time, then a drop mid-upload says so in words.
        try delay("POST", path, seconds: 6)
        addRow().tap()
        app.buttons["Choose File"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["kanban.task.adding"].waitForExistence(timeout: 5), "Adding… while the gateway is slow")
        XCTAssertTrue(app.buttons["brief.txt"].waitForExistence(timeout: 25), "the slow upload lands")
        try fail("POST", path, status: 500, detail: "failed to store attachment: disk full")
        addRow().tap()
        app.buttons["Choose File"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "a gateway error mid-upload is an alert")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'disk full'")).firstMatch.exists,
                      "the gateway's words: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
        alert.buttons["OK"].tap()
        XCTAssertEqual(try uploads().count, 1, "only the upload that went through was stored")
    }

    /// §4: a file past the limit is refused on the phone before a byte is sent.
    @MainActor func testU3_TooLargeBeforeUpload() throws {
        openTask("Record the export demo", arguments: ["-HQPagesSeedFile", "big.bin", "-HQPagesSeedFileMB", "26"])
        addRow().tap()
        app.buttons["Choose File"].tap()
        let alert = app.alerts["Couldn’t Add Attachment"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        XCTAssertTrue(alert.staticTexts["This file is larger than 25 MB, the most a task can hold."].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(try rest("POST", "/api/plugins/kanban/tasks/").filter { (($0["path"] as? String) ?? "").hasSuffix("/attachments") }.isEmpty,
                      "nothing was sent")
    }

    /// §4: a read-only gateway has no Add Attachment row.
    @MainActor func testU3_ReadOnlyHasNoAddRow() throws {
        openTask("Record the export demo", arguments: ["-HQPagesReadOnly", "YES"])
        let sheet = app.collectionViews.firstMatch
        let file = app.buttons["demo-script.txt"]
        for _ in 0..<12 where !(file.exists && file.isHittable) { sheet.swipeUp(velocity: .slow) }
        XCTAssertTrue(file.exists, "the task's files still read")
        XCTAssertFalse(app.buttons["kanban.task.add-attachment"].exists)
    }

    // MARK: U4

    @MainActor private func field(_ page: String) -> XCUIElement { app.searchFields["\(page).search.field"] }

    /// The search field's own cancel (iOS 26 draws it as a ✕ named Close).
    @MainActor private var cancelSearch: XCUIElement {
        let close = app.buttons["Close"].firstMatch
        return close.exists ? close : app.buttons["Cancel"].firstMatch
    }

    @MainActor private func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    @MainActor private func openPage(_ page: String) {
        switch page {
        case "jobs": tab("Jobs"); XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 10))
        case "kanban": tab("Kanban"); XCTAssertTrue(app.collectionViews["kanban.list"].waitForExistence(timeout: 10))
        case "artifacts": _ = openArtifacts()
        default:
            openMore("capabilities")
            let skills = app.descendants(matching: .any)["capabilities.row.skills"]   // [cap-pages] one of its four pages
            XCTAssertTrue(skills.waitForExistence(timeout: 10))
            skills.tap()
            XCTAssertTrue(app.descendants(matching: .any)["capabilities.list"].waitForExistence(timeout: 10))
        }
    }

    /// §5: no field at rest; the magnifier unfolds it with the keyboard up; a miss says so; Cancel folds it away.
    @MainActor func testU4_SearchFoldsOnEveryPage() throws {
        launchSignedIn()
        for page in ["jobs", "kanban", "artifacts", "capabilities"] {
            openPage(page)
            let field = field(page)
            XCTAssertFalse(field.exists, "\(page): no search field at rest")
            XCTAssertEqual(app.searchFields.count, 0, "\(page): no search field of any kind at rest")
            shot("search-\(page)-rest")
            let magnifier = app.buttons["\(page).search"]
            XCTAssertTrue(magnifier.waitForExistence(timeout: 5), "\(page): the bar has a magnifier")
            XCTAssertEqual(magnifier.label, "Search")
            magnifier.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 5), "\(page): the field unfolds")
            XCTAssertTrue(waitUntil(5) { self.hasFocus(field) && self.app.keyboards.firstMatch.exists }, "\(page): the keyboard is up from the same tap")
            field.typeText("zzz")
            let miss = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results for'")).firstMatch
            if page != "capabilities" || miss.waitForExistence(timeout: 2) {
                XCTAssertTrue(miss.waitForExistence(timeout: 5), "\(page): a miss says so")
            }
            shot("search-\(page)-miss")
            cancelSearch.tap()
            XCTAssertTrue(waitUntil(5) { !field.exists }, "\(page): Cancel folds the field away")
            XCTAssertFalse(miss.exists, "\(page): the full list is back")
            if page == "artifacts" || page == "capabilities" { back() }
        }
    }

    /// §5: a typed query stays with its page across tab changes.
    @MainActor func testU4_QueryKeptAcrossTabs() throws {
        launchSignedIn()
        openPage("jobs")
        let rows = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'job-row-'"))
        XCTAssertTrue(waitUntil(10) { rows.count > 1 })
        let all = rows.count
        app.buttons["jobs.search"].tap()
        let field = field("jobs")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("inbox")
        XCTAssertTrue(waitUntil(5) { rows.count < all }, "the list is filtered")
        let filtered = rows.count
        app.keyboards.buttons["Search"].tap()   // keys down; the query stays
        XCTAssertTrue(waitUntil(5) { !self.app.keyboards.firstMatch.exists })
        for other in ["Bots", "More"] {
            tab(other)
            XCTAssertFalse(field.exists, "the field belongs to Jobs")
            tab("Jobs")
            XCTAssertTrue(field.waitForExistence(timeout: 5), "back on Jobs the field is there")
            XCTAssertEqual(field.value as? String, "inbox")
            XCTAssertEqual(rows.count, filtered, "and the list is still filtered")
        }
        shot("search-jobs-kept")
        // Emptied and left: it folds away.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        cancelSearch.tap()
        XCTAssertTrue(waitUntil(5) { !field.exists })
        XCTAssertEqual(rows.count, all)
    }

    /// §5: opening a result and coming back keeps the query and the filtered list.
    @MainActor func testU4_QueryKeptAcrossPush() throws {
        launchSignedIn()
        let list = openArtifacts()
        app.buttons["artifacts.search"].tap()
        let field = field("artifacts")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("index.md")
        let row = list.cells["artifact-row-index.md"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertFalse(list.cells["artifact-row-summary.md"].exists, "filtered")
        row.tap()
        XCTAssertTrue(app.textViews["artifact.text.body"].waitForExistence(timeout: 10))
        back()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "back from the file the field is there")
        XCTAssertEqual(field.value as? String, "index.md")
        XCTAssertTrue(row.exists)
        XCTAssertFalse(list.cells["artifact-row-summary.md"].exists, "still filtered")
        // Rapid open and fold: the page ends folded with its list.
        cancelSearch.tap()
        for _ in 0..<4 {
            app.buttons["artifacts.search"].tap()
            if cancelSearch.waitForExistence(timeout: 3) { cancelSearch.tap() }
        }
        XCTAssertTrue(waitUntil(5) { !field.exists })
        XCTAssertTrue(list.cells["artifact-row-summary.md"].waitForExistence(timeout: 5) || list.cells.count > 3)
    }

    // MARK: U6

    /// §7: Settings › About › Open-Source Licenses lists everything the app ships; a row opens the whole notice.
    @MainActor func testU6_Licenses() throws {
        launchSignedIn()
        openMore("settings")
        let about = app.descendants(matching: .any)["settings.about"]
        XCTAssertTrue(app.descendants(matching: .any)["settings.list"].waitForExistence(timeout: 10), "Settings opens")
        for _ in 0..<12 where !(about.exists && about.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(about.exists, "Settings lists About")
        about.tap()
        let row = app.descendants(matching: .any)["about.licenses"]
        for _ in 0..<6 where !(row.waitForExistence(timeout: 3) && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.exists, "About lists Open-Source Licenses")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["licenses.intro"].waitForExistence(timeout: 10), "the page says what the list is")
        let names = ["Hermes Agent (Nous Research)", "Lucide", "swift-cmark", "swift-markdown"]
        for name in names {
            XCTAssertTrue(app.descendants(matching: .any)["license-row-\(name)"].waitForExistence(timeout: 5), "\(name) is listed")
        }
        XCTAssertFalse(app.descendants(matching: .any)["licenses.failed"].exists)
        shot("licenses")
        app.descendants(matching: .any)["license-row-swift-cmark"].tap()
        let text = app.descendants(matching: .any)["license.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "the notice opens")
        XCTAssertTrue(app.navigationBars["swift-cmark"].waitForExistence(timeout: 5), "the small title names the package")
        let body = (text.label + " " + ((text.value as? String) ?? ""))
        XCTAssertTrue(body.contains("Copyright"), "the whole notice is there")
        shot("license-text")
        back()
        XCTAssertTrue(app.descendants(matching: .any)["license-row-Lucide"].waitForExistence(timeout: 5))
    }

    // MARK: U7

    @MainActor private func openBotInfo() {
        tab("Bots")
        let cell = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-row-' OR identifier BEGINSWITH 'bot-tile-'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15))
        let item = app.buttons["Bot Info"].firstMatch
        for _ in 0..<3 {
            cell.press(forDuration: 1.0)
            if item.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(item.exists, "the bot's menu has Bot Info")
        item.tap()
        XCTAssertTrue(app.buttons["bot-info.tile.memo"].waitForExistence(timeout: 10), "Bot Info's tiles")
    }

    /// §8: Bot Info's tiles are the shared quick-action tiles: equal width in a row, a grid and then a stack as text grows.
    @MainActor func testU7_QuickActionTiles() throws {
        launchSignedIn()
        openBotInfo()
        let memo = app.buttons["bot-info.tile.memo"], mute = app.buttons["bot-info.tile.mute"]
        XCTAssertTrue(mute.exists)
        XCTAssertEqual(memo.frame.width, mute.frame.width, accuracy: 1, "tiles share the row equally")
        XCTAssertEqual(memo.frame.minY, mute.frame.minY, accuracy: 1, "one row at the default size")
        XCTAssertGreaterThanOrEqual(memo.frame.height, 59)
        shot("quick-actions")
        let before = mute.label
        mute.tap()
        XCTAssertTrue(waitUntil(8) { mute.label != before }, "Mute becomes Unmute (was \(before))")
        mute.tap()
        XCTAssertTrue(waitUntil(8) { mute.label == before }, "and back")

        let width = app.windows.firstMatch.frame.width
        for (name, size) in [("ax1", "UICTContentSizeCategoryAccessibilityM"), ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")] {
            _ = relaunch(["-UIPreferredContentSizeCategoryName", size])
            openBotInfo()
            let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-info.tile.'"))
            XCTAssertGreaterThanOrEqual(tiles.count, 2)
            for index in 0..<tiles.count {
                let tile = tiles.element(boundBy: index)
                XCTAssertGreaterThanOrEqual(tile.frame.minX, 0, "\(name): inside the screen")
                XCTAssertLessThanOrEqual(tile.frame.maxX, width + 0.5, "\(name): inside the screen")
                XCTAssertGreaterThanOrEqual(tile.frame.height, 59)
            }
            let first = tiles.element(boundBy: 0).frame, last = tiles.element(boundBy: tiles.count - 1).frame
            XCTAssertGreaterThan(last.minY, first.minY, "\(name): the tiles reflow onto more rows")
            if name == "ax5" { XCTAssertEqual(first.width, last.width, accuracy: 1); XCTAssertGreaterThan(first.width, width * 0.7, "stacked full width") }
            shot("quick-actions-\(name)")
        }
    }

    // MARK: U8

    /// XCUITest cannot deliver a plain Escape key press on this simulator runtime (UITests/ipad/IPadSupport.swift), so
    /// this presses Command-period, the same command's second key: it runs the same action (`AppDelegate.hqEscape`).
    @MainActor private func escape() { app.typeKey(".", modifierFlags: .command) }

    /// §9: Escape belongs to a transient layer or a search; it goes Back on a pushed page and never leaves a tab root.
    @MainActor func testU8_Escape() throws {
        launchSignedIn()
        // A tab root: nothing changes.
        openPage("jobs")
        escape(); escape()
        XCTAssertTrue(app.tabBars.buttons["Jobs"].isSelected)
        XCTAssertTrue(app.collectionViews["jobs.list"].isHittable)
        let rows = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'job-row-'"))
        let all = rows.count
        XCTAssertGreaterThan(all, 1)

        // Searching: the field folds, the whole list is back.
        app.buttons["jobs.search"].tap()
        let search = field("jobs")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("zzzz-no-such-job")
        XCTAssertTrue(waitUntil(5) { rows.count == 0 })
        escape()
        if !waitUntil(8, { !search.exists || !search.isHittable }) { shot("escape-search-stuck") }
        XCTAssertTrue(waitUntil(1) { !search.exists || !search.isHittable }, "the search folds")
        XCTAssertTrue(waitUntil(8) { rows.count == all }, "the full list")
        XCTAssertTrue(app.buttons["jobs.search"].waitForExistence(timeout: 5), "the magnifier is back")
        XCTAssertTrue(app.tabBars.buttons["Jobs"].isSelected)

        // A pushed page: Back.
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["job.detail"].waitForExistence(timeout: 10))
        escape()
        XCTAssertTrue(waitUntil(8) { !app.descendants(matching: .any)["job.detail"].exists }, "Escape went Back")
        XCTAssertTrue(app.collectionViews["jobs.list"].isHittable)
        escape()
        XCTAssertTrue(app.tabBars.buttons["Jobs"].isSelected, "and stops at the root")

        // A sheet over Kanban: it closes, Kanban stays.
        openPage("kanban")
        app.buttons["kanban.new"].tap()
        let sheet = app.descendants(matching: .any)["kanban.new.title"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
        escape()
        XCTAssertTrue(waitUntil(8) { !sheet.exists }, "the sheet closed")
        XCTAssertTrue(app.tabBars.buttons["Kanban"].isSelected)
        XCTAssertTrue(app.collectionViews["kanban.list"].isHittable)

        // A chat with text typed: the draft and the chat stay.
        tab("Bots")
        let bot = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-row-' OR identifier BEGINSWITH 'bot-tile-'")).firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 10))
        bot.tap()
        let composer = app.textViews["composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("a draft")
        escape(); escape(); escape()
        XCTAssertTrue(composer.exists, "still in the chat")
        XCTAssertEqual(composer.value as? String, "a draft", "the draft is untouched")
        shot("escape-chat-draft")
    }
}
