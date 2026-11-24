// [sessions-m9] Session Info (docs/spec/3x-sessions.md §10; acceptance F1-F8), against
// scripts/fixtures/sessions-gateway.py. A row with a note reads "value, note"; one without reads its value.

import XCTest

extension SessionsTests {
    @MainActor private func toggleProjectCoding(_ app: XCUIApplication, captureMenu: Bool = false) {
        app.buttons["sessions.projectPage.more"].tap()
        let item = app.buttons["Coding Project"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        if captureMenu { shot(app, "project-card-coding-menu") }
        item.tap()
    }
    /// [coding-pr-review] ⋯ › Project Settings… › Icon Guide (the header's ⓘ until 2026-11-21).
    @MainActor func openIconGuide(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openProjectSettings(app, file: file, line: line)
        let row = projectSetting(app, "sessions.projectSettings.iconGuide")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Project Settings' last row is Icon Guide", file: file, line: line)
        row.tap()
        XCTAssertTrue(app.navigationBars["Icon Guide"].waitForExistence(timeout: 5), "the guide opens", file: file, line: line)
    }

    /// Back from the guide to Project Settings, then the sheet closed.
    @MainActor func closeIconGuide(_ app: XCUIApplication) {
        app.navigationBars["Icon Guide"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(5) { !app.navigationBars["Icon Guide"].exists }, "back on Project Settings")
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { !app.descendants(matching: .any)["sessions.projectSettings"].exists }, "the settings page closes")
    }

    /// A waiting pinned chat, a finished reply, and a request without a reply have distinct coding subtitles.
    @MainActor func testCodingSessionSubtitles() throws {
        func reply(_ text: String) -> [[String: String]] { [["role": "assistant", "content": text]] }
        setRow("s-garden", ["title": "Fix reconnect crash", "messages": reply("12 regression tests passed.")])
        setRow("s-release", ["title": "Redesign the project header", "messages": reply("Updated the compact layout.")])
        setRow("s-recipes", ["profile": "default", "title": "Tighten sidebar spacing", "messages": reply("Reduced the gap between rows."), "last_active": nowSeconds - 200])
        setRow("s-shortcuts", ["title": "Add keyboard shortcuts", "messages": [["role": "user", "content": "Add a shortcut to open search."]], "last_active": nowSeconds - 300])
        setRow("s-old", ["title": "Retire the old build script", "messages": reply("Removed the unused build step.")])
        fixture("/__fixture/mode", ["live": ["s-release": "waiting"], "prStatus": [
            "default/s-garden": ["state": "open", "repo": "example/app", "number": 24],
            "deploys/s-release": ["state": "draft", "repo": "example/app", "number": 25],
            "default/s-recipes": ["state": "merged", "repo": "example/app", "number": 23],
            "default/s-shortcuts": ["state": "none", "repo": "example/app"],
            "deploys/s-old": ["state": "merged", "repo": "example/app", "number": 19]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-release")
        let question = "Which header layout should we use?"
        fixture("/__fixture/emit", ["request": ["method": "clarify", "params": ["questions": [["qid": "layout", "question": question, "choices": ["Compact", "Expanded"]]]]], "session_id": "s-release"])
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", question)).firstMatch.waitForExistence(timeout: 10))
        backToList(app)
        tapSide(app, app.buttons["sessions.pills.projects"])
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 10))
        let coding = app.buttons["sessions.projectPage.pr.merged"]
        setPageCoding(app, false)      // [coding-pr-review] a zero count is not drawn: the settings say it
        let sent = row(app, "s-shortcuts")
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertFalse(labelOf(sent).contains("No reply yet"))
        toggleProjectCoding(app)
        XCTAssertTrue(coding.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(15) { self.labelOf(sent).contains("No reply yet") }, labelOf(sent))
        let result = row(app, "s-garden")
        XCTAssertTrue(waitUntil(20) {
            let label = self.labelOf(result)
            return label.contains("12 regression tests passed") && label.contains("Open #24")
        }, labelOf(result))
        let waiting = row(app, "s-release")
        XCTAssertTrue(waitUntil(30) {
            let label = self.labelOf(waiting).lowercased()
            return label.contains("choose a header layout")
        }, labelOf(waiting))
        shot(app, "coding-session-subtitles")
        toggleProjectCoding(app)
        XCTAssertTrue(waitUntil(10) { !coding.exists && !self.labelOf(sent).contains("No reply yet") })
    }

    /// A working coding row streams its tool call like every other row; the finished turn ends on its summary
    /// (owner, 2026-11-20).
    @MainActor func testCodingSessionStreamsStepsThenSummary() throws { try streamsStepsThenSummary(faces: true) }

    /// Bot Faces off: no face to animate, so the spinner on the status line alone says the bot works.
    @MainActor func testCodingSessionStreamsStepsThenSummaryWithoutFaces() throws { try streamsStepsThenSummary(faces: false) }

    @MainActor private func streamsStepsThenSummary(faces: Bool) throws {
        let tag = faces ? "" : "-nofaces"
        fixture("/__fixture/mode", ["prompts": "hold", "prStatus": [
            "default/s-garden": ["state": "open", "repo": "example/app", "number": 24],
            "default/s-shortcuts": ["state": "none", "repo": "example/app"]
        ]])
        setRow("s-shortcuts", ["title": "Add keyboard shortcuts", "messages": [["role": "user", "content": "Add a shortcut to open search."]]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-shortcuts").waitForExistence(timeout: 15))
        if !faces { openFilter(app); tapFilter(app, "show", "faces"); closeFilter(app) }
        // The project page first: a running chat reorders the chips.
        tapSide(app, app.buttons["sessions.pills.projects"])
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 10))
        let coding = app.buttons["sessions.projectPage.pr.open"]
        setPageCoding(app, true)       // [coding-pr-review] a zero count is not drawn: the settings say it
        XCTAssertTrue(coding.waitForExistence(timeout: 10))
        openChat(app, "s-shortcuts")
        type(app, "Add Cmd-K for search", send: true)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the turn runs")
        backToList(app)
        XCTAssertTrue(coding.waitForExistence(timeout: 10), "still on the coding project page")
        let working = row(app, "s-shortcuts")
        fixture("/__fixture/emit", ["type": "tool.start", "session_id": "s-shortcuts",
                                    "payload": ["name": "terminal", "tool_id": "cs1", "args": ["command": "cd ~/app && npm test"]]])
        XCTAssertTrue(waitUntil(8) { self.labelOf(working).contains("Running npm test") }, labelOf(working))
        Thread.sleep(forTimeInterval: 0.4)
        shot(app, "coding-session-live-step" + tag)
        let summary = "Added Cmd-K to open search and covered it with a UI test."
        fixture("/__fixture/emit", ["type": "message.complete", "session_id": "s-shortcuts", "payload": ["text": summary + " Details below."]])
        XCTAssertTrue(waitUntil(10) {
            let label = self.labelOf(working)
            return label.contains("Added Cmd-K to open search") && !label.contains("npm") && !label.contains("Details below")
        }, labelOf(working))
        Thread.sleep(forTimeInterval: 0.4)
        shot(app, "coding-session-summary" + tag)
    }

    /// Project summary filters intersect the page's piles, and the coding switch clears the selection.
    @MainActor func testProjectPRCountFilter() throws {
        fixture("/__fixture/mode", ["prStatus": [
            "default/s-garden": ["state": "none", "repo": "example/app", "branch": "garden"],
            "deploys/s-release": ["state": "merged", "repo": "example/app", "branch": "release", "number": 42],
            "deploys/s-old": ["state": "merged", "repo": "example/app", "branch": "old", "number": 41]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        tapSide(app, app.buttons["sessions.pills.projects"])
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["sessions.projectPage.coding"].exists)
        setPageCoding(app, false)      // [coding-pr-review] a zero count is not drawn: the settings say it
        shot(app, "project-card-coding-off")
        let note = app.staticTexts["Counts include only available PR statuses."]
        // [coding-pr-review] Owner 2026-11-21 (option B): no ⓘ in the header; the ⋯ is its last control, its glyph
        // whole on the card.
        XCTAssertFalse(app.buttons["sessions.projectPage.info"].exists, "the ⓘ left the header")
        let more = app.buttons["sessions.projectPage.more"]
        XCTAssertTrue(more.exists)
        XCTAssertLessThanOrEqual(more.frame.midX + 12, app.cells["sessions.projectPage"].frame.maxX, "the ⋯'s glyph is inside the card")
        XCTAssertGreaterThan(more.frame.midX, app.cells["sessions.projectPage"].frame.maxX - 50, "the ⋯ stands at the card's end")
        // The guide is Project Settings' last row.
        openIconGuide(app)
        XCTAssertFalse(note.exists)
        closeIconGuide(app)
        toggleProjectCoding(app, captureMenu: true)
        let merged = app.buttons["sessions.projectPage.pr.merged"]
        XCTAssertTrue(merged.waitForExistence(timeout: 10))
        shot(app, "project-card-coding-on")
        XCTAssertTrue(waitUntil(20) { merged.label.contains("2 loaded") }, merged.label)
        // A state at zero is not drawn: no draft, open or closed chat here.
        let none = app.buttons["sessions.projectPage.pr.none"]
        XCTAssertTrue(waitUntil(10) { none.exists && none.label.contains("1 loaded chat") }, none.label)
        for state in ["draft", "open", "closed"] {
            XCTAssertFalse(app.buttons["sessions.projectPage.pr.\(state)"].exists, "\(state) at zero is absent")
        }
        XCTAssertLessThan(none.frame.midX, merged.frame.midX, "the order is unchanged")
        shot(app, "project-card-coding-on-loaded")
        XCTAssertFalse(note.exists)
        openIconGuide(app)
        for state in ["none", "draft", "open", "merged", "closed", "unknown"] {
            XCTAssertTrue(app.descendants(matching: .any)["project.legend.\(state)"].firstMatch.exists, state)
        }
        XCTAssertTrue(note.exists)
        shot(app, "project-icon-guide")
        closeIconGuide(app)
        let plainWidth = merged.frame.width
        merged.tap()
        XCTAssertTrue(waitUntil(10) { merged.isSelected && self.row(app, "s-release").exists && self.row(app, "s-old").exists && !self.row(app, "s-garden").exists })
        // Owner 2026-11-19: the picked state names itself inside its ring ("2 Merged").
        XCTAssertTrue(waitUntil(5) { merged.frame.width > plainWidth + 30 }, "picked ring holds the word: \(plainWidth) → \(merged.frame.width)")
        shot(app, "project-pr-summary-selected")
        merged.tap()
        XCTAssertTrue(waitUntil(10) { !merged.isSelected && self.row(app, "s-garden").exists })
        XCTAssertTrue(waitUntil(5) { abs(merged.frame.width - plainWidth) < 1 }, "unpicked drops the word")
        merged.tap()
        XCTAssertTrue(waitUntil(10) { merged.isSelected })
        toggleProjectCoding(app)
        XCTAssertTrue(waitUntil(10) { !merged.exists && self.row(app, "s-garden").exists })
        toggleProjectCoding(app)
        XCTAssertTrue(merged.waitForExistence(timeout: 10))
        XCTAssertFalse(merged.isSelected)
    }
    /// [pr-manage] A coding project's chat is marked closed and reopened from its row menu, and the project is linked
    /// to a repository from its ⋯ (a folder that isn't one says so).
    @MainActor func testProjectPRMarksAndRepository() throws {
        fixture("/__fixture/mode", ["prManage": true, "prStatus": [
            "default/s-garden": ["state": "draft", "repo": "example/app", "branch": "garden"],
            "deploys/s-release": ["state": "merged", "repo": "example/app", "branch": "release", "number": 42]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        tapSide(app, app.buttons["sessions.pills.projects"])
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 10))
        setPageCoding(app, true)       // [coding-pr-review] a zero count is not drawn: the settings say it
        XCTAssertTrue(waitUntil(20) { self.labelOf(self.row(app, "s-garden")).contains("Draft") }, labelOf(row(app, "s-garden")))

        // Mark as Closed, then Reopen. A merged chat offers neither.
        openMenu(app, row(app, "s-garden"), until: "Mark as Closed")
        shot(app, "project-row-menu-close")
        app.buttons["Mark as Closed"].firstMatch.tap()
        XCTAssertTrue(waitUntil(15) { self.labelOf(self.row(app, "s-garden")).contains("Closed") }, labelOf(row(app, "s-garden")))
        shot(app, "project-row-closed")
        openMenu(app, row(app, "s-garden"), until: "Reopen")
        XCTAssertFalse(app.buttons["Mark as Closed"].exists)
        app.buttons["Reopen"].firstMatch.tap()
        XCTAssertTrue(waitUntil(15) { self.labelOf(self.row(app, "s-garden")).contains("Draft") }, labelOf(row(app, "s-garden")))
        openMenu(app, row(app, "s-release"), until: "Rename…")
        XCTAssertFalse(app.buttons["Mark as Closed"].exists || app.buttons["Reopen"].exists, "a merged chat takes no mark")
        for _ in 0..<3 where app.buttons["Rename…"].firstMatch.exists {     // tap beside the menu to close it
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertTrue(waitUntil(4) { !app.buttons["Rename…"].firstMatch.exists }, "the row menu closes")

        // ⋯ › Repository…
        let repository = app.buttons["Repository…"].firstMatch
        for _ in 0..<3 where !repository.exists {
            app.buttons["sessions.projectPage.more"].tap()
            _ = repository.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(repository.exists, "the ⋯ offers Repository…")
        shot(app, "project-menu-repository")
        repository.tap()
        XCTAssertTrue(app.navigationBars["Repository"].waitForExistence(timeout: 5))
        let folder = app.textFields["project.repository.folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        // Turning Coding Project on now awaits pr-repos and auto-links the project's own folder without racing.
        let initialUnlink = app.buttons["project.repository.unlink"]
        if waitUntil(5, { if !initialUnlink.exists { app.swipeUp() }; return initialUnlink.exists }) {
            initialUnlink.tap()
            XCTAssertTrue(waitUntil(8) { !initialUnlink.exists }, "unlinks auto-linked repo to test manual linking")
            app.swipeDown()
        }
        shot(app, "project-repository-empty")
        XCTAssertFalse(app.buttons["project.repository.unlink"].exists)
        // [repo-pickers] The project's repositories, the others Hermes knows and the GitHub names already seen are one
        // tap each; the folder's own GitHub repository is the default.
        let own = app.buttons["project.repository.folder.app"], server = app.buttons["project.repository.folder.app-server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        XCTAssertTrue(own.isSelected && !server.isSelected)
        XCTAssertTrue(app.buttons["project.repository.others"].exists, "the other projects' repositories are folded")
        XCTAssertTrue(app.buttons["project.repository.public.own"].isSelected)
        server.tap()
        XCTAssertTrue(waitUntil(4) { server.isSelected && !own.isSelected })
        XCTAssertTrue((folder.value as? String ?? "").hasSuffix("/app-server"), "\(folder.value ?? "")")
        let named = app.buttons["project.repository.public.example/app"]
        if !named.exists { app.swipeUp() }
        XCTAssertTrue(named.waitForExistence(timeout: 5), "a GitHub name a chat's branch was read against")
        named.tap()
        XCTAssertTrue(waitUntil(4) { named.isSelected })
        XCTAssertEqual(app.textFields["project.repository.public"].value as? String, "example/app")
        shot(app, "project-repository-picked")
        app.buttons["project.repository.public.own"].tap()
        if !own.isHittable { app.swipeDown() }
        own.tap()
        XCTAssertTrue(waitUntil(4) { own.isSelected })
        folder.tap()
        folder.typeText("/nope\n")      // Return puts the keyboard away: it covers Link once the choices are listed
        app.buttons["project.repository.link"].tap()
        let problem = app.staticTexts["project.repository.error"]
        XCTAssertTrue(problem.waitForExistence(timeout: 8))
        XCTAssertTrue(problem.label.contains("isn’t a git repository"), problem.label)
        shot(app, "project-repository-error")
        own.tap()                       // [repo-pickers] one tap puts the project's own repository back
        XCTAssertTrue(waitUntil(4) { own.isSelected })
        app.buttons["project.repository.link"].tap()
        // The choices make the page longer: Linked, Update Link and Unlink are below them.
        let unlink = app.buttons["project.repository.unlink"]
        XCTAssertTrue(waitUntil(10) { if !unlink.exists { app.swipeUp() }; return unlink.exists })
        XCTAssertEqual(app.buttons["project.repository.link"].label, "Update Link")
        XCTAssertFalse(problem.exists)
        XCTAssertTrue(app.descendants(matching: .any)["project.repository.main"].firstMatch.exists)
        shot(app, "project-repository-linked")
        app.buttons["project.repository.unlink"].tap()
        XCTAssertTrue(waitUntil(8) { !app.buttons["project.repository.unlink"].exists })
        app.buttons["sheet.close"].firstMatch.tap()
    }
    /// The general list keeps its timestamps; PR details appear only after opting a project in.
    @MainActor func testPRTrackingEndToEnd() throws {
        fixture("/__fixture/mode", ["prStatus": [
            "default/s-garden": ["state": "none", "repo": "example/garden", "branch": "feature/garden"],
            "research/s-trip": ["state": "unknown", "repo": "example/travel", "branch": "feature/travel"],
            "deploys/s-release": ["state": "draft", "repo": "example/app", "branch": "feature/release", "number": 42,
                                  "url": "https://github.com/example/app/pull/42"]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        for id in ["s-garden", "s-trip", "s-release", "s-budget"] {
            let chat = row(app, id)
            XCTAssertTrue(chat.waitForExistence(timeout: 10), id)
            let label = labelOf(chat)
            for prWords in ["Pull request", "PR status", "No PR yet", "Merged #42"] {
                XCTAssertFalse(label.contains(prWords), label)
            }
            XCTAssertNotNil(label.range(of: #"\b([0-9]{1,2}:[0-9]{2} (AM|PM)|Yesterday|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b"#, options: .regularExpression), "normal timestamp: \(label)")
        }
        shot(app, "pr-tracking-general-list")
        tapSide(app, app.buttons["sessions.pills.projects"])
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 10))
        setPageCoding(app, true)       // [coding-pr-review] a zero count is not drawn: the settings say it
        XCTAssertTrue(waitUntil(20) { self.labelOf(self.row(app, "s-release")).contains("Draft #42") }, labelOf(row(app, "s-release")))
        XCTAssertTrue(waitUntil(10) { self.labelOf(self.row(app, "s-garden")).contains("No PR yet") }, labelOf(row(app, "s-garden")))
        openChat(app, "s-release")
        openSessionInfo(app)
        let pr = app.cells["info.pull-request"]
        for _ in 0..<5 where !pr.isHittable { app.tables["info.list"].swipeUp() }
        XCTAssertTrue(pr.waitForExistence(timeout: 8), "Chat Info offers Pull Request")
        XCTAssertTrue(pr.label.contains("Draft #42"), pr.label)
        shot(app, "pr-tracking-info")
        pr.tap()
        // [coding-pr-review] The row opens the PR card (it was an alert): the same card as the row's mark.
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 5), "the PR card")
        let card = app.descendants(matching: .any)
        XCTAssertTrue(card["prcard.state"].firstMatch.label.contains("Draft #42"), card["prcard.state"].firstMatch.label)
        XCTAssertTrue(card["prcard.place"].firstMatch.label.contains("example/app"), card["prcard.place"].firstMatch.label)
        XCTAssertTrue(card["prcard.place"].firstMatch.label.contains("feature/release"), card["prcard.place"].firstMatch.label)
        XCTAssertTrue(app.buttons["prcard.openOnGitHub"].exists)
        XCTAssertTrue(app.buttons["prcard.askToMerge"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert")
        shot(app, "pr-tracking-details")
    }
    /// [pr-multi] Owner 2026-11-20: "How does it work with 2 PRs … 2 at the same time and only one merging". One chat
    /// with two pull requests still open and one merged: one mark with a 2 beside it, counted under Open and Merged,
    /// and Session Info lists each one.
    @MainActor func testPRSeveralInOneChat() throws {
        let link = { (n: Int) in "https://github.com/example/app/pull/\(n)" }
        fixture("/__fixture/mode", ["prStatus": [
            "deploys/s-release": ["state": "open", "repo": "example/app", "number": 44, "url": link(44), "items": [
                ["state": "open", "repo": "example/app", "number": 44, "url": link(44), "source": "github"],
                ["state": "draft", "branch": "feature/release-notes", "source": "git"],
                ["state": "merged", "repo": "example/app", "number": 40, "url": link(40), "source": "github"]]],
            "deploys/s-old": ["state": "merged", "repo": "example/app", "number": 41, "url": link(41), "items": [
                ["state": "merged", "repo": "example/app", "number": 41, "url": link(41), "source": "github"]]]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        tapSide(app, app.buttons["sessions.pills.projects"])
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 10))
        setPageCoding(app, true)       // [coding-pr-review] a zero count is not drawn: the settings say it
        let release = row(app, "s-release")
        XCTAssertTrue(waitUntil(20) { self.labelOf(release).contains("Open #44, 1 more not merged") }, labelOf(release))
        // [pr-pill] The green "#44" pill and "+2" on the right are drawn, not read (the row's words say it): the shot below.
        XCTAssertFalse(labelOf(row(app, "s-old")).contains("not merged"), labelOf(row(app, "s-old")))
        let open = app.buttons["sessions.projectPage.pr.open"], merged = app.buttons["sessions.projectPage.pr.merged"]
        XCTAssertTrue(waitUntil(20) { open.label.contains("1 loaded chat") && merged.label.contains("2 loaded") },
                      "\(open.label) / \(merged.label)")      // chats, under each state they have
        shot(app, "pr-several-in-one-chat")
        merged.tap()
        XCTAssertTrue(waitUntil(10) { merged.isSelected && self.row(app, "s-release").exists && self.row(app, "s-old").exists })
        merged.tap()
        XCTAssertTrue(waitUntil(10) { !merged.isSelected })
        openChat(app, "s-release")
        openSessionInfo(app)
        let first = app.cells["info.pull-request"], second = app.cells["info.pull-request.1"], third = app.cells["info.pull-request.2"]
        for _ in 0..<5 where !third.isHittable { app.tables["info.list"].swipeUp() }
        XCTAssertTrue(third.waitForExistence(timeout: 8), "Session Info lists each one")
        XCTAssertTrue(first.label.contains("Open #44"), first.label)
        XCTAssertTrue(second.label.contains("Branch") && second.label.contains("Draft · feature/release-notes"), second.label)
        XCTAssertTrue(third.label.contains("Merged #40"), third.label)
        XCTAssertFalse(app.cells["info.pull-request.3"].exists)
        shot(app, "pr-several-info")
        third.tap()
        // [coding-pr-review] The PR card, on that pull request.
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 5), "the PR card")
        let card = app.descendants(matching: .any)
        XCTAssertTrue(card["prcard.state"].firstMatch.label.contains("Merged #40"), card["prcard.state"].firstMatch.label)
        XCTAssertTrue(app.buttons["prcard.openOnGitHub"].exists)
        XCTAssertFalse(app.buttons["prcard.askToMerge"].exists, "merged: nothing to merge")
        XCTAssertTrue(app.buttons["prcard.other.0"].exists && app.buttons["prcard.other.1"].exists, "Also in This Chat")
    }
    /// The gateway as the sheet names it: host and port.
    var gatewayHost: String {
        guard let url = URL(string: account.url), let host = url.host else { return account.url }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    @MainActor func closeSheet(_ app: XCUIApplication) {
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { !app.tables["info.list"].exists }, "the sheet closes")
    }

    /// F1, F2, F7: the sheet's title and head, the model with its provider, the usage rows, then Messages, Folder with
    /// its branch, the bot's name, the gateway and the id. One `session.usage` ask, with only its two keys.
    @MainActor func test60_SessionInfoRows() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(app.navigationBars["Chat Info"].exists, "the title is Chat Info")
        XCTAssertEqual(app.staticTexts["info.title"].label, "Trip to Lisbon", "the chat's title under the head")
        let model = infoRow(app, "Model")
        XCTAssertTrue(model.lowercased().contains("hermes") && model.lowercased().contains("nous"), "the model with its provider under it (\(model))")
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Context") == "24%, 48.2K of 200K · 151.8K left" }, "Context (\(infoRow(app, "Context")))")
        XCTAssertEqual(infoRow(app, "Tokens"), "15.4K, 14.2K in · 1.2K out")
        XCTAssertEqual(infoRow(app, "Speed"), "64 tokens/s, 1.6 s a call · 9 calls")
        XCTAssertEqual(infoRow(app, "Cost"), "$0.34, Estimated")
        XCTAssertEqual(infoRow(app, "Messages"), "2")
        XCTAssertEqual(infoRow(app, "Folder"), "/home/hermes/reading, main", "the folder with its branch under it")
        XCTAssertEqual(infoRow(app, "Bot"), "Research", "the bot's name, not its id")
        XCTAssertEqual(infoRow(app, "Gateway"), "\(gatewayHost), Connected")
        XCTAssertEqual(infoRow(app, "Chat ID"), "s-trip")
        XCTAssertFalse(hasInfoRow(app, "Source"), "an app chat has no Source row")
        XCTAssertFalse(hasInfoRow(app, "Answered By"))
        // The rows in the web's order.
        let order = app.tables["info.list"].cells.allElementsBoundByIndex.map(\.identifier).filter { $0.hasPrefix("info.row.") }
        let expected = ["model", "context", "tokens", "speed", "cost", "messages", "folder", "bot", "gateway", "chat-id"].map { "info.row." + $0 }
        XCTAssertEqual(order.filter { expected.contains($0) }, expected, "the web's order (\(order))")
        shot(app, "F1-session-info")
        app.tables["info.list"].swipeUp()
        XCTAssertTrue(app.cells["info.copy-all"].waitForExistence(timeout: 4), "Copy Session Info closes the list")
        shot(app, "F2-session-info-end")
        // F7: one ask, two keys.
        let asks = rpc("session.usage")
        XCTAssertEqual(asks.count, 1, "one session.usage ask")
        XCTAssertTrue(Set(asks.first?.keys.map { $0 } ?? []).isSubset(of: ["session_id", "profile"]), "only session_id and profile (\(asks))")
        closeSheet(app)
        backToList(app)

        // Garden plan: an actual cost has no note.
        openChat(app, "s-garden")
        openSessionInfo(app)
        XCTAssertEqual(app.staticTexts["info.title"].label, "Garden plan")
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "1.2K, 1K in · 230 out" }, infoRow(app, "Tokens"))
        XCTAssertEqual(infoRow(app, "Cost"), "$0.02", "an actual cost carries no note")
        XCTAssertEqual(infoRow(app, "Context"), "2%, 3.1K of 200K · 196.9K left")
        XCTAssertEqual(infoRow(app, "Calls"), "2", "no timings: the calls alone")
        XCTAssertEqual(infoRow(app, "Bot"), "Hermes")
        XCTAssertEqual(infoRow(app, "Folder"), "/home/hermes/app, main")
        shot(app, "F1-session-info-actual-cost")
    }

    /// F3, F4: a usage tick changes Tokens while the sheet is open; a fallback line adds "Answered By" and relabels
    /// the model "Chat Model"; "Primary model restored:" takes both back.
    @MainActor func test61_SessionInfoFollowsTheChat() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "15.4K, 14.2K in · 1.2K out" }, infoRow(app, "Tokens"))
        fixture("/__fixture/emit", ["type": "session.usage", "session_id": "s-trip", "payload": ["usage": [
            "input": 20000, "output": 2000, "total": 22000, "context_used": 60000, "context_max": 200000, "context_percent": 30,
            "context_estimated": true, "cost_usd": 0.5]]])
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "22K, 20K in · 2K out" }, "Tokens follows without reopening (\(infoRow(app, "Tokens")))")
        XCTAssertEqual(infoRow(app, "Context"), "~30%, 60K of 200K · 140K left", "an estimated context carries the ~")
        XCTAssertEqual(infoRow(app, "Cost"), "$0.50", "the live cost wins, with no Estimated note")
        shot(app, "F3-usage-tick")

        fixture("/__fixture/emit", ["type": "status.update", "session_id": "s-trip", "payload": [
            "kind": "fallback", "text": "Model fallback: hermes-4 via nous unavailable (rate limited); using hermes-3 via nous."]])
        XCTAssertTrue(waitUntil(6) { self.hasInfoRow(app, "Answered By") }, "Answered by appears")
        let answered = infoRow(app, "Answered By")
        XCTAssertTrue(answered.lowercased().contains("hermes") && answered.contains("is unavailable on the gateway (rate limited)"), answered)
        XCTAssertTrue(hasInfoRow(app, "Chat Model"), "the model row is relabelled")
        XCTAssertFalse(hasInfoRow(app, "Model"))
        let cells = app.tables["info.list"].cells.allElementsBoundByIndex.map(\.identifier).filter { $0.hasPrefix("info.row.") }
        XCTAssertEqual(Array(cells.prefix(2)), ["info.row.answered-by", "info.row.chat-model"], "Answered by comes first (\(cells))")
        shot(app, "F4-answered-by")
        fixture("/__fixture/emit", ["type": "status.update", "session_id": "s-trip", "payload": [
            "kind": "status", "text": "Primary model restored: hermes-4 via nous."]])
        XCTAssertTrue(waitUntil(6) { !self.hasInfoRow(app, "Answered By") }, "restored: Answered by goes")
        XCTAssertTrue(hasInfoRow(app, "Model") && !hasInfoRow(app, "Chat Model"))
        shot(app, "F4-restored")
    }

    /// F5: a chat that came from Telegram says so, and a chat with a reasoning effort names it. (A chat handed over from Telegram: it is listed with the app's
    /// chats and its `handoff_platform` names where it came from. Telegram's own threads are not in this list.)
    @MainActor func test62_SessionInfoSource() throws {
        setRow("s-tg", ["profile": "default", "title": "Dinner plans", "source": "desktop", "handoff_platform": "telegram", "last_active": nowSeconds - 300,
                        "reasoning_effort": "xhigh", "fast": true,
                        "messages": [["role": "user", "content": "Where shall we eat?"], ["role": "assistant", "content": "The place by the canal has a table at eight."]]])
        let app = launch()
        XCTAssertTrue(row(app, "s-tg").waitForExistence(timeout: 15), "the Telegram chat is listed")
        shot(app, "F5-telegram-row")
        openChat(app, "s-tg")
        openSessionInfo(app)
        XCTAssertEqual(infoRow(app, "Source"), "Telegram")
        XCTAssertEqual(infoRow(app, "Reasoning"), "Extra High · Fast", "the chat's reasoning effort, as the app names it")
        shot(app, "F5-reasoning")
        XCTAssertEqual(infoRow(app, "Chat ID"), "s-tg")
        app.tables["info.list"].swipeUp()                                // the Source row is below the fold
        XCTAssertTrue(app.cells["info.row.source"].isHittable, "the Source row scrolls in")
        shot(app, "F5-source-telegram")
    }

    /// F6: Copy Session Info copies every row with the raw ids and says "Copied"; a row's hold menu copies that row;
    /// a tap on Chat ID copies the id.
    @MainActor func test63_SessionInfoCopy() throws {
        removeTextOut("info-copy.txt")
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "15.4K, 14.2K in · 1.2K out" })
        let list = app.tables["info.list"]
        list.swipeUp()
        let copyAll = app.cells["info.copy-all"]
        XCTAssertTrue(copyAll.waitForExistence(timeout: 4))
        copyAll.tap()
        XCTAssertTrue(app.descendants(matching: .any)["menus.hud"].waitForExistence(timeout: 4), "the HUD")
        XCTAssertEqual(app.descendants(matching: .any)["menus.hud"].label, "Copied")
        shot(app, "F6-copied")
        let copied = try XCTUnwrap(textOut("info-copy.txt"), "what went to the pasteboard")
        let lines = copied.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Model: hermes-4 (nous)"), "the raw model and provider ids (\(lines))")
        XCTAssertTrue(lines.contains("Context: 24% (48.2K of 200K · 151.8K left)"), copied)
        XCTAssertTrue(lines.contains("Speed: 64 tokens/s (1.6 s a call · 9 calls)"), copied)
        XCTAssertTrue(lines.contains("Tokens: 15.4K (14.2K in · 1.2K out)"), copied)
        XCTAssertTrue(lines.contains("Cost: $0.34 (Estimated)"), copied)
        XCTAssertTrue(lines.contains("Bot: Research (research)"), "the bot's name with its id (\(copied))")
        XCTAssertTrue(lines.contains("Chat ID: s-trip"), copied)
        XCTAssertTrue(lines.contains("Gateway: \(gatewayHost) (Connected)"), copied)

        // A tap on Chat ID copies the id.
        removeTextOut("info-copy.txt")
        app.cells["info.row.chat-id"].tap()
        XCTAssertEqual(textOut("info-copy.txt"), "s-trip")
        // A row's hold menu › Copy copies that row.
        removeTextOut("info-copy.txt")
        list.swipeDown()
        let tokens = app.cells["info.row.tokens"]
        XCTAssertTrue(tokens.waitForExistence(timeout: 4))
        tokens.press(forDuration: 1.0)
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the row's hold menu")
        shot(app, "F6-row-hold-menu")
        copy.tap()
        XCTAssertEqual(textOut("info-copy.txt"), "Tokens: 15.4K (14.2K in · 1.2K out)")
    }

    /// F8: with the gateway gone the Gateway row's note says so while the sheet is open, and "Connected" when it is back.
    @MainActor func test64_SessionInfoGatewayNote() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Gateway") == "\(self.gatewayHost), Connected" }, infoRow(app, "Gateway"))
        fixture("/__fixture/mode", ["down": 900])                       // away until the test brings it back (no race with a clock)
        let away = ["Offline", "Reconnecting…", "Connecting…"].map { "\(gatewayHost), \($0)" }
        let wentAway = waitUntil(30) { away.contains(self.infoRow(app, "Gateway")) }
        if !wentAway { shot(app, "F8-FAILED-note-did-not-follow") }
        XCTAssertTrue(wentAway, "the note follows the link (\(infoRow(app, "Gateway")))")
        let said = infoRow(app, "Gateway")
        shot(app, "F8-gateway-away")
        XCTAssertEqual(infoRow(app, "Tokens"), "15.4K, 14.2K in · 1.2K out", "the live rows keep their last values")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert of its own")
        XCTAssertTrue(away.contains(infoRow(app, "Gateway")), "still away while the gateway is (\(infoRow(app, "Gateway")))")
        fixture("/__fixture/mode", ["down": 0])
        XCTAssertTrue(waitUntil(90) { self.infoRow(app, "Gateway") == "\(self.gatewayHost), Connected" },
                      "Connected again once the gateway is back (was \(said), now \(infoRow(app, "Gateway")))")
        shot(app, "F8-gateway-back")
    }

    /// Tester 2026-10-27: the usage card with every figure Hermes sends (their mockup's numbers): Context with
    /// what is left and a bar, Tokens counting the cache reads, Cache with a bar, Speed, Cost with the model's price.
    /// iOS look, then Desktop Look.
    @MainActor func test66_SessionInfoUsageCard() throws {
        for (look, extra) in [("ios", [String]()), ("desktop", ["-HQDebugDesktopLook", "YES"])] {
            let app = launch(extra: extra)
            XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
            openChat(app, "s-trip")
            openSessionInfo(app)
            XCTAssertTrue(waitUntil(6) { self.hasInfoRow(app, "Speed") })
            fixture("/__fixture/emit", ["type": "session.usage", "session_id": "s-trip", "payload": ["usage": [
                "input": 342000, "prompt": 17100000, "output": 84800, "total": 17184800, "reasoning": 12400, "calls": 96,
                "compressions": 2, "context_used": 264000, "context_max": 1000000, "context_percent": 26,
                "context_estimated": false, "cache_hit_pct": 98, "avg_tps": 82.4, "avg_latency_s": 1.24, "cost_usd": 0.037]]])
            XCTAssertTrue(waitUntil(6) { self.hasInfoRow(app, "Cache") }, "Cache appears with the tick")
            XCTAssertEqual(infoRow(app, "Context"), "26%, 264K of 1M · 736K left · compressed 2×")
            XCTAssertEqual(infoRow(app, "Tokens"), "17.2M, 17.1M in · 84.8K out · 12.4K reasoning")
            XCTAssertEqual(infoRow(app, "Cache"), "98%, ~16.8M from cache · 342K new")
            XCTAssertEqual(infoRow(app, "Speed"), "82 tokens/s, 1.2 s a call · 96 calls")
            XCTAssertTrue(infoRow(app, "Cost").hasPrefix("$0.04"), infoRow(app, "Cost"))
            let order = app.tables["info.list"].cells.allElementsBoundByIndex.map(\.identifier).filter { $0.hasPrefix("info.row.") }
            let expected = ["context", "tokens", "cache", "speed", "cost"].map { "info.row." + $0 }
            XCTAssertEqual(order.filter { expected.contains($0) }, expected, "the card's order (\(order))")
            shot(app, "F-usage-card-\(look)")
            app.tables["info.list"].swipeUp()
            XCTAssertTrue(app.cells["info.row.cost"].waitForExistence(timeout: 4))
            shot(app, "F-usage-card-\(look)-2")
            closeSheet(app)
            app.terminate()
        }
    }

    /// §10.4: a new chat with nothing sent shows what it has; a chat on an older gateway opens without its usage rows.
    @MainActor func test65_SessionInfoStates() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        tapChip(app, "research")
        app.buttons["sessions.compose"].tap()
        let start = app.buttons["new-chat-start"]   // the New Chat sheet, Research lit
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the new chat")
        Thread.sleep(forTimeInterval: 1.0)
        openSessionInfo(app)
        XCTAssertEqual(app.staticTexts["info.title"].label, "New Chat", "the name the chat's own header gives it")
        XCTAssertTrue(hasInfoRow(app, "Model") && hasInfoRow(app, "Gateway") && hasInfoRow(app, "Chat ID"))
        XCTAssertEqual(infoRow(app, "Bot"), "Research")
        XCTAssertFalse(hasInfoRow(app, "Messages"), "nothing sent: no Messages row")
        XCTAssertFalse(hasInfoRow(app, "Cost"))
        shot(app, "F-new-chat-info")
        closeSheet(app)
        backToList(app)
        clearPick(app)

        // The largest text size: value and note stack under the label.
        app.terminate()
        let large = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(row(large, "s-release").waitForExistence(timeout: 15))
        chip(large, "research").tap()
        openChat(large, "s-trip")
        openSessionInfo(large)
        XCTAssertTrue(waitUntil(6) { self.hasInfoRow(large, "Context") })
        shot(large, "F-ax5-session-info")
        large.tables["info.list"].swipeUp()
        shot(large, "F-ax5-session-info-2")
    }
}
