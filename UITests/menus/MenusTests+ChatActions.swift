// End-to-end checks of the rest of the chat menus (parity 240 §5, §8) against the menus fixture
// (scripts/fixtures/menus-gateway.py records every write): the ⋯ rows, Find in chat, Pin / Mark as Unread / Export Chat,
// Files and Changes, Archive, Delete Chat, Branch, and the hold menu's and action row's Regenerate, Edit, Rewind to Here,
// Branch (Send Again / Delete: unit tests). Run with scripts/e2e-menus.sh (HQN_MENUS_ONLY="test20_…" for one).

import XCTest

extension MenusTests {
    // MARK: ⋯ rows

    @objc @MainActor func test20_ChatMenuRows() throws {
        let (account, app) = try start()
        openBotChat(app)
        openMore(app)
        for id in ["share", "find", "info", "pin", "unread"] {
            XCTAssertTrue(app.buttons["chat.more.\(id)"].exists, "⋯ › \(id) in the bot's chat")
        }
        XCTAssertEqual(app.buttons["chat.more.pin"].label, "Pin")
        XCTAssertEqual(app.buttons["chat.more.unread"].label, "Mark as Unread")
        for id in ["rename", "archive", "delete"] {
            XCTAssertFalse(app.buttons["chat.more.\(id)"].exists, "a bot's own chat has no \(id)")
        }
        shot(app, "chat-more-menu-bot")
        menuItem(app, "More").tap()
        for id in ["files", "changes", "branch", "export"] {
            XCTAssertTrue(app.buttons["chat.more.\(id)"].waitForExistence(timeout: 3), "More › \(id)")
        }
        shot(app, "chat-more-submenu")
        dismissMenu(app)
        goBack(app)
        openTrip(app)
        openMore(app)
        for id in ["rename", "pin", "unread", "archive", "delete"] {
            XCTAssertTrue(app.buttons["chat.more.\(id)"].exists, "⋯ › \(id) in a session")
        }
        XCTAssertEqual(app.buttons["chat.more.delete"].label, "Delete Chat")
        shot(app, "chat-more-menu-session")
        dismissMenu(app)
        // Offline: the writes wait ("Offline"); Share, Find and Info don't.
        try account.control("/__menus/mode", ["offline": true])
        XCTAssertTrue(waitUntil(timeout: 20) { (app.textViews["composer.text"].placeholderValue ?? "") == "Offline"
            || app.staticTexts["Offline"].exists || app.staticTexts["Reconnecting…"].exists }, "the chat is offline")
        openMore(app)
        XCTAssertFalse(app.buttons["chat.more.pin"].isEnabled, "Pin waits offline")
        XCTAssertFalse(app.buttons["chat.more.delete"].isEnabled, "Delete waits offline")
        XCTAssertTrue(app.buttons["chat.more.find"].isEnabled, "Find works offline")
        shot(app, "chat-more-menu-offline")
        dismissMenu(app)
        try account.control("/__menus/mode", ["offline": false])
        try assertActionsWire(account)
    }

    // MARK: Find in chat

    @objc @MainActor func test21_FindInChat() throws {
        let (account, app) = try start()
        openTrip(app)
        XCTAssertTrue(message(app, containing: "Sintra").waitForExistence(timeout: 8))
        openMore(app)
        app.buttons["chat.more.find"].tap()
        let field = app.searchFields["chat.find.field"].exists ? app.searchFields["chat.find.field"] : app.textFields["chat.find.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the find bar")
        XCTAssertTrue(waitUntil(timeout: 3) { field.hasFocus() }, "its field takes the keyboard")
        field.typeText("and")
        let count = app.staticTexts["chat.find.count"]
        XCTAssertTrue(waitUntil(timeout: 3) { count.label == "3 of 3" }, "three matches, the newest current: \(count.label)")
        shot(app, "find-bar")
        app.buttons["chat.find.previous"].tap()
        XCTAssertTrue(waitUntil(timeout: 2) { count.label == "2 of 3" })
        app.buttons["chat.find.previous"].tap()
        app.buttons["chat.find.previous"].tap()
        XCTAssertTrue(waitUntil(timeout: 2) { count.label == "3 of 3" }, "wraps around")
        app.buttons["chat.find.next"].tap()
        XCTAssertTrue(waitUntil(timeout: 2) { count.label == "1 of 3" })
        shot(app, "find-stepped")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "LISBON")
        XCTAssertTrue(waitUntil(timeout: 3) { count.label == "1 of 1" }, "case-insensitive: \(count.label)")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "zzz")
        XCTAssertTrue(waitUntil(timeout: 3) { count.label == "No Results" })
        app.buttons["chat.find.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !app.otherElements["chat.find"].exists && !field.exists }, "Done closes the bar")
        try assertActionsWire(account)
    }

    // MARK: Pin, Mark as Unread, Export Chat

    @objc @MainActor func test22_PinUnreadExport() throws {
        clearTextOut()
        let (account, app) = try start()
        openTrip(app)
        openMore(app)
        app.buttons["chat.more.pin"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowFlag(account, "pinned") == true }, "PATCH {pinned: true}")
        let pin = patches(account).last { (($0["body"] as? [String: Any])?["pinned"]) != nil }
        XCTAssertEqual((pin?["body"] as? [String: Any])?["profile"] as? String, "default")
        XCTAssertTrue((pin?["query"] as? String ?? "").contains("profile=default"))
        openMore(app)
        XCTAssertEqual(app.buttons["chat.more.pin"].label, "Unpin")
        app.buttons["chat.more.unread"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowFlag(account, "unread") == true }, "PATCH {unread: true}")
        openMore(app)
        XCTAssertEqual(app.buttons["chat.more.unread"].label, "Mark as Read")
        shot(app, "chat-more-pinned-unread")
        app.buttons["chat.more.unread"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowFlag(account, "unread") == false }, "PATCH {unread: false}")
        // Export Chat: every stored row, in the web's file shape, through the share sheet.
        openMore(app)
        menuItem(app, "More").tap()
        app.buttons["chat.more.export"].tap()
        let exported = textOut("export.json") ?? ""
        XCTAssertTrue(exported.contains("\"session_id\": \"\(Self.trip)\""), "the export names the chat")
        XCTAssertTrue(exported.contains("\"message_count\": 6"), "every row")
        XCTAssertTrue(exported.contains("Sintra for the palaces"))
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 8) || app.buttons["Close"].waitForExistence(timeout: 2),
                      "the share sheet")
        shot(app, "export-share-sheet")
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown() }
        XCTAssertTrue(calls(account, "session.title").isEmpty)
        try assertActionsWire(account)
    }

    // MARK: Files and Changes

    @objc @MainActor func test23_FilesAndChanges() throws {
        let (account, app) = try start()
        openTrip(app)
        openMore(app)
        menuItem(app, "More").tap()
        app.buttons["chat.more.files"].tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["workspace.entry.notes"].waitForExistence(timeout: 8), "the chat's folder")
        XCTAssertTrue(app.cells["workspace.entry.README.md"].exists)
        let cells = app.tables["workspace.files"].cells
        XCTAssertEqual(cells.element(boundBy: 0).identifier, "workspace.entry.notes", "folders first")
        shot(app, "files-page")
        app.cells["workspace.entry.notes"].tap()
        XCTAssertTrue(app.cells["workspace.entry.packing.md"].waitForExistence(timeout: 8), "a folder opens its own list")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // A Markdown file reads formatted (Preview | Source); other text monospaced.
        app.cells["workspace.entry.README.md"].tap()
        let note = app.textViews["artifact.text.body"]
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 5) { (note.value as? String ?? "").contains("A long weekend in Lisbon") })
        XCTAssertFalse((note.value as? String ?? "").contains("# Trip"), "the heading is drawn, not its #")
        shot(app, "files-markdown")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.cells["workspace.entry.itinerary.txt"].tap()
        let text = app.textViews["workspace.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 5) { (text.value as? String ?? "").contains("Day 2: Sintra") })
        shot(app, "files-text")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["sheet.close"].tap()
        openMore(app)
        menuItem(app, "More").tap()
        app.buttons["chat.more.changes"].tap()
        XCTAssertTrue(app.navigationBars["Changes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["workspace.change.itinerary.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.cells["workspace.change.notes/packing.md"].exists)
        XCTAssertFalse(app.cells["workspace.change.node_modules/left-pad/index.js"].exists, "dependency folders are left out")
        shot(app, "changes-page")
        app.cells["workspace.change.itinerary.txt"].tap()
        let diff = app.textViews["workspace.diff"]
        XCTAssertTrue(diff.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 5) { (diff.value as? String ?? "").contains("+Day 3: Cascais") })
        shot(app, "changes-diff")
        let rest = (try state(account))["rest"] as? [[String: Any]] ?? []
        for path in ["/api/fs/list", "/api/fs/read-text", "/api/git/review/list", "/api/git/review/diff"] {
            let reads = rest.filter { $0["path"] as? String == path }
            XCTAssertFalse(reads.isEmpty, "\(path) was read")
            XCTAssertTrue(reads.allSatisfy { ($0["query"] as? String ?? "").contains("profile=default") }, "\(path) names its profile")
        }
        XCTAssertTrue(rest.contains { $0["path"] as? String == "/api/git/review/list" && ($0["query"] as? String ?? "").contains("path=/fixture") }
                      || rest.contains { $0["path"] as? String == "/api/git/review/list" && ($0["query"] as? String ?? "").contains("path=%2Ffixture") },
                      "Changes reads the chat's folder")
    }

    /// A path in backticks in a reply opens in Files (owner, 2026-10-29): the note formatted, its folder under Back.
    @objc @MainActor func test23b_FilePathInAReplyOpensInFiles() throws {
        let (account, app) = try start()
        openTrip(app)
        let name = "day-trips-from-lisbon-sintra-and-cascais-2026-10-28.md"
        let reply = message(app, containing: name)
        XCTAssertTrue(reply.waitForExistence(timeout: 8), "the reply naming the file")
        shot(app, "file-path-reply")
        // The path ends the reply, wrapping over its last lines: its last line's start, above the bubble's bottom edge.
        // Desktop Look sets the time on a row of its own under the reply (the line is then 37 pt above the bottom).
        for lift in [18.0, 37.0] where !app.navigationBars[name].exists {
            reply.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: reply.frame.height - lift)).tap()
            _ = app.navigationBars[name].waitForExistence(timeout: 4)
        }
        let body = app.textViews["artifact.text.body"]
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 4), "the file opens")
        XCTAssertTrue(waitUntil(timeout: 8) { (body.value as? String ?? "").contains("Pena Palace") })
        XCTAssertFalse((body.value as? String ?? "").contains("**"), "Markdown reads formatted")
        // The system's control in the iOS look, the desktop's outlined strip in the Desktop Look: buttons in the toolbar.
        XCTAssertTrue(app.toolbars.buttons["Preview"].exists, "Preview | Source")
        shot(app, "file-path-note")
        app.toolbars.buttons["Source"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (body.value as? String ?? "").contains("**Sintra**") })
        shot(app, "file-path-source")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["workspace.entry.packing.md"].waitForExistence(timeout: 8), "Back shows the file's folder")
        XCTAssertTrue(app.navigationBars["Files"].exists)
        shot(app, "file-path-folder")
        app.buttons["sheet.close"].tap()
        let rest = (try state(account))["rest"] as? [[String: Any]] ?? []
        XCTAssertTrue(rest.contains { $0["path"] as? String == "/api/fs/read-text" && ($0["query"] as? String ?? "").contains("day-trips-from-lisbon") })
    }

    /// A path written out in a reply, not in backticks, opens in Files too (owner, 2026-10-30: Otto's "Files:" list
    /// "aren't clickable").
    @objc @MainActor func test23c_BarePathInAReplyOpensInFiles() throws {
        let (account, app) = try start()
        openTrip(app)
        let reply = message(app, containing: "Baixa or Chiado")
        XCTAssertTrue(reply.waitForExistence(timeout: 8), "the reply listing the file")
        shot(app, "bare-path-reply")
        // The path is the reply's last line, past the bullet: tap it above the bubble's bottom edge (Desktop Look sets
        // the time on a row of its own, 37 pt up).
        for lift in [18.0, 37.0] where !app.navigationBars["packing.md"].exists {
            reply.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 100, dy: reply.frame.height - lift)).tap()
            _ = app.navigationBars["packing.md"].waitForExistence(timeout: 4)
        }
        XCTAssertTrue(app.navigationBars["packing.md"].waitForExistence(timeout: 4), "the file opens")
        let body = app.textViews["artifact.text.body"]
        XCTAssertTrue(waitUntil(timeout: 8) { (body.value as? String ?? "").contains("walking shoes") })
        shot(app, "bare-path-note")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["workspace.entry.packing.md"].waitForExistence(timeout: 8), "Back shows the file's folder")
        app.buttons["sheet.close"].tap()
        let rest = (try state(account))["rest"] as? [[String: Any]] ?? []
        XCTAssertTrue(rest.contains { $0["path"] as? String == "/api/fs/read-text" && ($0["query"] as? String ?? "").contains("packing.md") })
    }

    // MARK: Archive and Delete

    @objc @MainActor func test24_ArchiveAndDelete() throws {
        let (account, app) = try start()
        openTrip(app)
        openMore(app)
        app.buttons["chat.more.archive"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowFlag(account, "archived") == true }, "PATCH {archived: true}")
        XCTAssertTrue(waitUntil(timeout: 8) { !app.tables["chat.table"].exists }, "back on the list")
        XCTAssertTrue(app.descendants(matching: .any)["undo-pill"].waitForExistence(timeout: 3), "\"Archived · Undo\" shows on the list")
        XCTAssertTrue(waitUntil(timeout: 8) { !app.cells["session-row-\(Self.trip)"].exists }, "the row leaves the Sessions list")
        shot(app, "archived-back-on-list")
        // Delete: a fresh start (the archived chat is gone from the list).
        try account.control("/__menus/reset", [:])
        let relaunched = launch(account, reset: true)
        openTrip(relaunched)
        openMore(relaunched)
        relaunched.buttons["chat.more.delete"].tap()
        let confirm = relaunched.sheets.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirm sheet")
        XCTAssertTrue(confirm.staticTexts["Delete “Trip planning”?"].exists)
        shot(relaunched, "delete-confirm")
        confirm.buttons["Delete Chat"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.deletes(account).count == 1 }, "DELETE /api/sessions/<id>")
        let delete = deletes(account).first
        XCTAssertEqual(delete?["path"] as? String, "/api/sessions/\(Self.trip)")
        XCTAssertTrue((delete?["query"] as? String ?? "").contains("profile=default"), "the profile is in the URL")
        XCTAssertTrue(calls(account, "session.close").contains { $0["profile"] as? String == "default" }, "the runtime closes first")
        XCTAssertTrue(waitUntil(timeout: 8) { !relaunched.tables["chat.table"].exists && !relaunched.cells["session-row-\(Self.trip)"].exists },
                      "back on the list, the row gone")
        try assertActionsWire(account)
    }

    // MARK: Branch

    @objc @MainActor func test25_Branch() throws {
        let (account, app) = try start()
        openTrip(app)
        openMore(app)
        menuItem(app, "More").tap()
        app.buttons["chat.more.branch"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.calls(account, "session.branch_stored").isEmpty }, "session.branch_stored")
        let stored = calls(account, "session.branch_stored").first
        XCTAssertEqual(stored?["parent_session_id"] as? String, Self.trip)
        XCTAssertEqual(stored?["source"] as? String, "desktop")
        XCTAssertEqual(stored?["cwd"] as? String, "/fixture")
        XCTAssertTrue(barTitle(app, "Branch of Trip planning").waitForExistence(timeout: 8), "the new chat opens in place")
        XCTAssertTrue(message(app, containing: "Sintra").waitForExistence(timeout: 10), "with the whole chat")
        shot(app, "branch-opened")
        goBack(app)
        XCTAssertTrue(app.cells["session-row-\(Self.trip)"].waitForExistence(timeout: 5), "Back returns to the list")
        // From a reply: `session.branch` with the count of messages through it.
        try account.control("/__fixture/plan", ["plans": [["replyText": "A reply to branch from."]]])
        app.buttons["tab-bots"].firstMatch.tap()
        openBotChat(app)
        send(app, "Hello there")
        let reply = message(app, containing: "A reply to branch from")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        Thread.sleep(forTimeInterval: 2)
        reply.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.branch"].waitForExistence(timeout: 5))
        app.buttons["message.branch"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.calls(account, "session.branch").isEmpty }, "session.branch")
        XCTAssertEqual(calls(account, "session.branch").first?["count"] as? Int, 3, "intro, prompt and reply")
        XCTAssertTrue(barTitle(app, "Branch of").waitForExistence(timeout: 8))
        try assertActionsWire(account)
    }

    // MARK: Regenerate, the action row, Edit, Rewind to Here

    @objc @MainActor func test26_MessageActions() throws {
        keepAppAlerts()
        let (account, app) = try start()
        try account.control("/__fixture/plan", ["plans": [["replyText": "First answer."], ["replyText": "Second answer."],
                                                         ["replyText": "Answer to the edit."], ["replyText": "Answer after the rewind."]]])
        openBotChat(app)
        send(app, "Hello there")
        let first = message(app, containing: "First answer")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        Thread.sleep(forTimeInterval: 2)
        let userRow = botRows(account).last { $0["role"] as? String == "user" }?["row_id"] as? Int
        // The hold menu: the newest reply offers Regenerate and Branch.
        first.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.regenerate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["message.branch"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hermes · '")).firstMatch.exists, "sender · time")
        shot(app, "hold-menu-reply-actions")
        app.buttons["message.regenerate"].tap()
        XCTAssertTrue(message(app, containing: "Second answer").waitForExistence(timeout: 10), "the reply runs again")
        let regenerate = calls(account, "prompt.submit").last
        XCTAssertEqual(regenerate?["text"] as? String, "Hello there")
        XCTAssertEqual(regenerate?["truncate_before_row_id"] as? Int, userRow)
        XCTAssertEqual(regenerate?["confirm_truncate"] as? Bool, true)
        XCTAssertTrue(waitUntil(timeout: 10) { !first.exists }, "the old reply is gone")
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        XCTAssertEqual(botRows(account).filter { $0["role"] as? String == "user" }.count, 1, "one prompt on the gateway")
        Thread.sleep(forTimeInterval: 2.5)   // the turn-end read replaces the rewritten rows
        // The action row under the latest reply: Copy · Regenerate · More.
        XCTAssertTrue(app.buttons["chat.copy-reply"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.regenerate-reply"].exists)
        app.buttons["chat.reply-more"].tap()
        XCTAssertTrue(app.buttons["reply-more.share"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["reply-more.select"].exists)
        XCTAssertTrue(app.buttons["reply-more.branch"].exists)
        shot(app, "reply-action-row-more")
        dismissMenu(app)
        // Edit: the message goes into the field with a banner; the send replaces it.
        let mine = message(app, containing: "You said: Hello there")
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["message.rewind"].exists)
        shot(app, "hold-menu-mine-actions")
        app.buttons["message.edit"].tap()
        XCTAssertTrue(app.otherElements["composer.editing"].waitForExistence(timeout: 5), "the Editing banner")
        let field = app.textViews["composer.text"]
        XCTAssertEqual(field.value as? String, "Hello there")
        shot(app, "editing-message")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "again")
        waitForKeysUp(app)
        app.buttons["composer.send"].tap()
        XCTAssertTrue(message(app, containing: "Answer to the edit").waitForExistence(timeout: 10))
        let edit = calls(account, "prompt.submit").last
        XCTAssertEqual(edit?["text"] as? String, "Hello again")
        XCTAssertNotNil(edit?["truncate_before_row_id"] as? Int)
        XCTAssertFalse(app.otherElements["composer.editing"].exists, "the banner went with the send")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.message(app, containing: "You said: Hello there").exists }, "the old prompt is gone")
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        Thread.sleep(forTimeInterval: 2.5)
        // Rewind to Here: a confirm, then the prompt runs again from there.
        let edited = message(app, containing: "You said: Hello again")
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        edited.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.rewind"].waitForExistence(timeout: 5))
        app.buttons["message.rewind"].tap()
        let alert = app.alerts["Rewind to Here?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        shot(app, "rewind-confirm")
        alert.buttons["Rewind and Rerun"].tap()
        XCTAssertTrue(message(app, containing: "Answer after the rewind").waitForExistence(timeout: 10))
        let rewind = calls(account, "prompt.submit").last
        XCTAssertEqual(rewind?["text"] as? String, "Hello again")
        XCTAssertEqual(rewind?["confirm_truncate"] as? Bool, true)
        XCTAssertFalse(app.alerts["Couldn’t Rewind"].exists)
        XCTAssertFalse(app.alerts["Couldn’t Edit Message"].exists)
        XCTAssertEqual(botRows(account).filter { $0["role"] as? String == "user" }.count, 1, "still one prompt on the gateway")
        try assertActionsWire(account)
    }

    /// Swipe to Reply: a reply dragged left puts "Replying to Hermes" over the composer; the send goes out under a
    /// quote of it. The hold menu's Reply does the same, and the banner's ✕ drops the quote.
    @objc @MainActor func test27_SwipeToReply() throws {
        keepAppAlerts()
        let (account, app) = try start()
        try account.control("/__fixture/plan", ["plans": [["replyText": "Option A is faster.\n\nOption B is cheaper."],
                                                         ["replyText": "Going with A."]]])
        openBotChat(app)
        send(app, "Which option?")
        let reply = message(app, containing: "Option A is faster")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        Thread.sleep(forTimeInterval: 2)
        // The hold menu offers Reply; ✕ on its banner drops it.
        reply.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.reply"].waitForExistence(timeout: 5))
        app.buttons["message.reply"].tap()
        let banner = app.otherElements["composer.replying"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "the Replying banner")
        app.buttons["composer.replying.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !banner.exists }, "✕ drops the reply")
        // A drag to the left on the reply.
        let start = reply.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -150, dy: 0)))
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "the swipe begins a reply")
        XCTAssertTrue(app.staticTexts["Replying to Hermes"].exists)
        shot(app, "swipe-to-reply")
        let field = app.textViews["composer.text"]
        field.typeText("A please")
        waitForKeysUp(app)
        app.buttons["composer.send"].tap()
        XCTAssertTrue(message(app, containing: "Going with A").waitForExistence(timeout: 10))
        XCTAssertEqual(calls(account, "prompt.submit").last?["text"] as? String,
                       "> Option A is faster.\n> Option B is cheaper.\n\nA please")
        XCTAssertFalse(banner.exists, "the banner went with the send")
        shot(app, "swipe-to-reply-sent")
        try assertActionsWire(account)
    }

    // (Send Again / Delete on an unconfirmed send: the fixture can't leave a send unconfirmed — after a dropped link the
    // app's reconnect proves delivery from the resumed turn — so they are covered by ChatActionsTests' session tests.)

    // MARK: Helpers

    /// Branch, Delete's close and the row writes name their profile; nothing was refused as invalid params.
    @MainActor func assertActionsWire(_ account: FixtureAccount) throws {
        try assertWireClean(account)
        for method in ["session.branch", "session.branch_stored", "session.close"] {
            for params in calls(account, method) {
                XCTAssertEqual(params["profile"] as? String, "default", "\(method) names its profile: \(params)")
            }
        }
        for patch in patches(account) {
            XCTAssertEqual((patch["body"] as? [String: Any])?["profile"] as? String, "default", "PATCH names its profile")
        }
    }

    /// The simulator hides the software keyboard while XCUITest types (its key events come from a hardware keyboard)
    /// and brings it back about a second later, with the text view first responder throughout. A tap on Send in that
    /// window lands on the row at its keys-down place and the returning keyboard carries the button out from under the
    /// finger (touchUpOutside): wait until the row is back over the keys and still before tapping.
    @MainActor func waitForKeysUp(_ app: XCUIApplication) {
        let send = app.buttons["composer.send"]
        var last = CGRect.null
        var steady = 0
        _ = waitUntil(timeout: 5) {
            let frame = send.frame
            let up = frame.maxY < app.frame.height * 0.7
            steady = up && frame == last ? steady + 1 : 0
            last = frame
            return steady >= 2
        }
    }

    @MainActor func rowFlag(_ account: FixtureAccount, _ key: String) -> Bool? {
        (((try? state(account))?["rows"] as? [String: Any])?[Self.trip] as? [String: Any])?[key] as? Bool
    }

    @MainActor func deletes(_ account: FixtureAccount) -> [[String: Any]] {
        ((try? state(account))?["rest"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == "DELETE" }
    }

    @MainActor func botRows(_ account: FixtureAccount) -> [[String: Any]] {
        (try? state(account))?["botMessages"] as? [[String: Any]] ?? []
    }
}

extension XCUIElement {
    /// Whether the element holds the keyboard focus.
    func hasFocus() -> Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
