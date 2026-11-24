import CryptoKit
import XCTest

/// [coding-pr-review] Owner 2026-11-21 (option B of artifacts/coding-pr-review/mock1.html): a project's page draws no
/// pin in its Pinned pile, its header loses the ⓘ (the icon guide moved to Project Settings) and zero PR counts, the PR
/// mark opens a PR card, and a coding row carries the pull request's verdict.
extension SessionsTests {
    // MARK: Helpers

    /// The Projects side, then the App project's page.
    @MainActor func openAppProjectPage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        if !project.waitForExistence(timeout: 3) {     // on the Chats side (a project's page shows its pills already)
            let toProjects = app.buttons["sessions.pills.projects"]
            XCTAssertTrue(toProjects.waitForExistence(timeout: 15), "the Projects side", file: file, line: line)
            tapSide(app, toProjects)
        }
        XCTAssertTrue(project.waitForExistence(timeout: 10), "App's pill", file: file, line: line)
        onScreen(app, project).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 10), "App's page", file: file, line: line)
    }

    /// Whether the page shown is a coding project's: its settings have the coding-only When the Pull Request Merges.
    /// (A zero PR count is not drawn since 2026-11-21, so no count says it before the marks load.)
    @MainActor func pageIsCoding(_ app: XCUIApplication) -> Bool {
        openProjectSettings(app)
        let coding = app.switches["sessions.projectSettings.autoDoneMerged"].waitForExistence(timeout: 2)
        closeProjectSettings(app)
        return coding
    }

    /// The page shown made a coding project, or not (the ⋯'s Coding Project, only when it differs).
    @MainActor func setPageCoding(_ app: XCUIApplication, _ on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard pageIsCoding(app) != on else { return }
        app.buttons["sessions.projectPage.more"].tap()
        let item = app.buttons["Coding Project"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the ⋯'s Coding Project", file: file, line: line)
        item.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// The App project's page as a coding project, its `marker` count drawn.
    @MainActor func ensureAppCoding(_ app: XCUIApplication, waitFor marker: String = "sessions.projectPage.pr.open") {
        openAppProjectPage(app)
        setPageCoding(app, true)
        XCTAssertTrue(app.buttons[marker].waitForExistence(timeout: 20), "App is a coding project (\(marker))")
    }

    /// A tap on a row's PR mark: the mark ends the row's first line at its trailing edge (the touch is 44 pt; no time
    /// or dot follows it on a read coding row on a project page).
    @MainActor func tapPRMark(_ app: XCUIApplication, _ id: String) {
        let cell = row(app, id)
        XCTAssertTrue(cell.waitForExistence(timeout: 8))
        let frame = cell.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 26, dy: frame.minY + 20)).tap()
    }

    /// The fixture's runtime id for a stored chat (sessions-gateway.py `runtime`).
    func runtimeId(_ stored: String) -> String {
        SHA256.hash(data: Data(stored.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// The words the app submitted, by chat runtime id.
    func submitted() -> [(session: String, text: String)] {
        rpc("prompt.submit").map { ($0["session_id"] as? String ?? "", $0["text"] as? String ?? "") }
    }

    /// Which listed rows draw a pin glyph (the app's pin-glyphs.txt text-out).
    @MainActor func pinGlyphRows() -> Set<String> {
        let text = textOut("pin-glyphs.txt") ?? ""
        return Set(text.split(separator: "\n").map(String.init).filter { $0 != "none" })
    }

    // MARK: Step 1: no pin in a project page's Pinned pile

    /// App's page: Ship the 2.4 release notes (pinned everywhere) is in the page's Pinned pile, which draws no pin (its
    /// heading says it), and VoiceOver still says Pinned. An archived pinned chat opened in Done keeps its pin.
    @MainActor func test40r_PinnedPileDrawsNoPin() throws {
        guard Self.textOutFolder != nil else { throw XCTSkip("reads the app's text out (HQN_SHOTS_DIR)") }
        setRow("s-old", ["pinned": true])     // archived and pinned: listed in Done
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openAppProjectPage(app)
        XCTAssertTrue(header(app, "Pinned").waitForExistence(timeout: 8), "App's Pinned pile")
        let release = row(app, "s-release")
        XCTAssertTrue(release.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(6) { self.labelOf(release).contains("Pinned") }, "VoiceOver still says Pinned (\(labelOf(release)))")
        XCTAssertTrue(waitUntil(6) { !self.pinGlyphRows().contains("s-release") }, "no pin in the Pinned pile (\(pinGlyphRows()))")
        shot(app, "CR1-pinned-pile-no-pin")

        // Done (closed at first): the archived pinned chat keeps its pin, nothing else there says it is pinned.
        let done = header(app, "Done")
        for _ in 0..<4 where !done.exists || !done.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(done.waitForExistence(timeout: 6), "Done")
        if !row(app, "s-old").exists { done.tap() }
        let old = row(app, "s-old")
        XCTAssertTrue(old.waitForExistence(timeout: 6), "the archived chat in Done")
        XCTAssertTrue(waitUntil(6) { self.pinGlyphRows().contains("s-old") }, "Done's pinned chat keeps its pin (\(pinGlyphRows()))")
        XCTAssertTrue(labelOf(old).contains("Pinned"), labelOf(old))
        XCTAssertFalse(pinGlyphRows().contains("s-release"), "still none in Pinned")
        shot(app, "CR1-done-keeps-pin")
    }

    // MARK: Step 2: the header (no ⓘ, zero PR counts hidden); the guide in Project Settings

    /// Website (not coding): no ⓘ; Project Settings ends with Icon Guide, which opens the activity guide alone. App as a
    /// coding project: only the states with a chat are drawn, and its guide lists every state.
    @MainActor func test40s_HeaderGuideInSettings() throws {
        fixture("/__fixture/mode", ["prStatus": [
            "default/s-garden": ["state": "open", "repo": "example/app", "branch": "garden", "number": 24],
            "deploys/s-release": ["state": "merged", "repo": "example/app", "branch": "release", "number": 23]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openWebsitePage(app)
        XCTAssertFalse(app.buttons["sessions.projectPage.info"].exists, "no ⓘ in the header")
        setPageCoding(app, false)      // an earlier test may have left it one
        XCTAssertFalse(app.buttons["sessions.projectPage.pr.none"].exists, "not a coding project: no count line")
        openIconGuide(app)
        XCTAssertFalse(app.descendants(matching: .any)["project.legend.open"].firstMatch.exists, "not coding: no code marks")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Needs You'")).firstMatch.exists, "the activity marks")
        shot(app, "CR2-guide-not-coding")
        closeIconGuide(app)

        openAppProjectPage(app)
        setPageCoding(app, true)
        let open = app.buttons["sessions.projectPage.pr.open"], merged = app.buttons["sessions.projectPage.pr.merged"]
        XCTAssertTrue(waitUntil(20) { open.exists && merged.exists && merged.label.contains("1 loaded chat") }, "\(open.label) / \(merged.label)")
        for state in ["none", "draft", "closed"] {
            XCTAssertFalse(app.buttons["sessions.projectPage.pr.\(state)"].exists, "\(state) at zero is absent")
        }
        XCTAssertFalse(app.buttons["sessions.projectPage.info"].exists)
        let more = app.buttons["sessions.projectPage.more"]
        XCTAssertGreaterThan(more.frame.midX, open.frame.maxX, "the ⋯ ends the header")
        shot(app, "CR2-header-coding")
        openProjectSettings(app)
        let guideRow = projectSetting(app, "sessions.projectSettings.iconGuide")
        XCTAssertTrue(guideRow.waitForExistence(timeout: 5))
        shot(app, "CR2-settings-icon-guide-row")
        guideRow.tap()
        XCTAssertTrue(app.navigationBars["Icon Guide"].waitForExistence(timeout: 5))
        for state in ["none", "draft", "open", "merged", "closed", "unknown"] {
            XCTAssertTrue(app.descendants(matching: .any)["project.legend.\(state)"].firstMatch.exists, state)
        }
        shot(app, "CR2-guide-coding")
        closeIconGuide(app)
        // Picking Merged rings it with its word; the open count stays.
        let plain = merged.frame.width
        merged.tap()
        XCTAssertTrue(waitUntil(10) { merged.isSelected && merged.frame.width > plain + 30 }, "picked ring holds the word")
        shot(app, "CR2-header-picked")
        merged.tap()
        XCTAssertTrue(waitUntil(10) { !merged.isSelected })
        app.buttons["sessions.projectPage.more"].tap()
        let item = app.buttons["Coding Project"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    // MARK: Step 3: the PR card

    /// App as a coding project: Garden plan's mark opens the card (not the chat) with its state, name, place, link and
    /// Ask to Merge, and its other branch; Ask to Merge shows the words, Cancel sends nothing, Send posts exactly those
    /// words to Garden plan and opens it.
    @MainActor func test40t_PRCardFromTheMark() throws {
        let link = "https://github.com/example/app/pull/24"
        fixture("/__fixture/mode", ["prompts": "hold", "prStatus": [
            "default/s-garden": ["state": "open", "repo": "example/app", "branch": "fix/garden", "number": 24, "url": link, "items": [
                ["state": "open", "repo": "example/app", "branch": "fix/garden", "number": 24, "url": link, "source": "github"],
                ["state": "draft", "repo": "example/app", "branch": "feature/beds", "source": "git"]]],
            "deploys/s-release": ["state": "merged", "repo": "example/app", "number": 23]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        ensureAppCoding(app)
        let garden = row(app, "s-garden")
        XCTAssertTrue(waitUntil(20) { self.labelOf(garden).contains("Open #24") }, labelOf(garden))
        shot(app, "CR3-page")
        tapPRMark(app, "s-garden")
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 8), "the PR card")
        XCTAssertFalse(app.tables["chat.table"].exists, "the chat did not open")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["prcard.state"].firstMatch.label.contains("Open #24"), any["prcard.state"].firstMatch.label)
        XCTAssertEqual(any["prcard.name"].firstMatch.label, "Garden plan")
        XCTAssertEqual(any["prcard.place"].firstMatch.label, "example/app · fix/garden")
        XCTAssertTrue(app.buttons["prcard.openOnGitHub"].exists, "Open on GitHub")
        let ask = app.buttons["prcard.askToMerge"]
        XCTAssertTrue(ask.exists && ask.label.hasPrefix("Ask ") && ask.label.hasSuffix(" to Merge…"), ask.label)
        XCTAssertFalse(any["prcard.checks"].firstMatch.exists || any["prcard.changes"].firstMatch.exists, "no Checks or Changes without their data")
        shot(app, "CR3-card")

        // Also in This Chat: the branch's own card.
        let other = app.buttons["prcard.other.0"]
        XCTAssertTrue(other.exists && other.label.contains("Draft · feature/beds"), other.label)
        other.tap()
        XCTAssertTrue(app.navigationBars["Branch"].waitForExistence(timeout: 5), "the branch's card")
        XCTAssertTrue(waitUntil(4) { any["prcard.state"].firstMatch.label.contains("Draft") })
        XCTAssertFalse(app.buttons["prcard.openOnGitHub"].exists, "a branch has no link")
        shot(app, "CR3-card-branch")
        app.navigationBars["Branch"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 5))

        // Ask to Merge: the exact words; Cancel sends nothing.
        ask.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "a confirmation")
        XCTAssertTrue(confirm.staticTexts["Merge pull request #24."].exists, "the exact words")
        shot(app, "CR3-confirm")
        confirm.buttons["Cancel"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(submitted().isEmpty, "Cancel sent nothing (\(submitted()))")
        XCTAssertTrue(app.navigationBars["Pull Request"].exists, "still on the card")

        // Send: posted to Garden plan, which opens.
        ask.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["Send"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 12), "the chat opens")
        XCTAssertTrue(waitUntil(12) { !self.submitted().isEmpty }, "the words were sent")
        let sent = submitted()
        XCTAssertEqual(sent.count, 1, "\(sent)")
        XCTAssertEqual(sent.first?.text, "Merge pull request #24.")
        XCTAssertEqual(sent.first?.session, runtimeId("s-garden"), "to Garden plan")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "CR3-sent")
    }

    // MARK: Step 4: the verdict on rows

    /// One App row per case of the verdict, through the fixture's `prStatus` (the contract's new keys): each row's
    /// spoken label says its verdict, and the merged and no-code rows gain nothing. The card names the PR's title and
    /// `branch → base`.
    @MainActor func test40u_VerdictOnRows() throws {
        let now = Date().timeIntervalSince1970
        let rows: [(id: String, title: String)] = [("s-cr-fail", "Tighten sidebar spacing"), ("s-cr-run", "Add keyboard shortcuts"),
                                                   ("s-cr-size", "Rename the settings keys"), ("s-cr-check", "Bump the build number"),
                                                   ("s-cr-plain", "Read the crash logs")]
        for (place, row) in rows.enumerated() {
            setRow(row.id, ["profile": "default", "title": row.title, "cwd": "/home/hermes/app",
                            "last_active": now - Double(300 + place * 60), "unread": false])
        }
        let size = ["files": 4, "additions": 128, "deletions": 12]
        let passed: [String: Any] = ["state": "passed", "passed": 5, "failed": 0, "running": 0]
        fixture("/__fixture/mode", ["prStatus": [
            "default/s-garden": ["state": "open", "repo": "example/app", "branch": "fix/reconnect-crash", "number": 24,
                                 "url": "https://github.com/example/app/pull/24", "size": size, "checks": passed,
                                 "title": "Fix reconnect crash", "base": "main"],
            "default/s-cr-fail": ["state": "open", "repo": "example/app", "number": 25, "size": size,
                                  "checks": ["state": "failed", "passed": 3, "failed": 2, "running": 0]],
            "default/s-cr-run": ["state": "draft", "repo": "example/app", "number": 26, "size": size,
                                 "checks": ["state": "running", "passed": 2, "failed": 0, "running": 3]],
            "default/s-cr-size": ["state": "draft", "repo": "example/app", "branch": "chore/settings-keys",
                                  "size": ["files": 9, "additions": 212, "deletions": 40]],
            "default/s-cr-check": ["state": "open", "repo": "example/app", "number": 27, "checks": passed],
            // Never sent for a merged pull request; the app draws nothing even so.
            "deploys/s-release": ["state": "merged", "repo": "example/app", "number": 23, "size": size, "checks": passed]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        ensureAppCoding(app)
        let expected: [(String, String)] = [("s-garden", "Checks passed, 128 lines added, 12 removed"), ("s-cr-fail", "2 checks failing"),
                                            ("s-cr-run", "Checks running"), ("s-cr-size", "212 lines added, 40 removed"),
                                            ("s-cr-check", "Checks passed")]
        for (id, words) in expected {
            let cell = row(app, id)
            XCTAssertTrue(waitUntil(20) { self.labelOf(cell).contains(words) }, "\(id): \(labelOf(cell))")
        }
        XCTAssertFalse(labelOf(row(app, "s-cr-check")).contains("lines added"), "no size, no size words")
        for id in ["s-release", "s-cr-plain"] {
            let label = labelOf(row(app, id))
            XCTAssertFalse(label.contains("Checks") || label.contains("lines added") || label.contains("checks"), "\(id) gains nothing: \(label)")
        }
        XCTAssertTrue(labelOf(row(app, "s-release")).contains("Merged #23"))
        shot(app, "CR4-rows")

        // The card: the pull request's title, and where it merges.
        tapPRMark(app, "s-garden")
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 8), "the PR card")
        let any = app.descendants(matching: .any)
        XCTAssertEqual(any["prcard.name"].firstMatch.label, "Fix reconnect crash")
        XCTAssertEqual(any["prcard.place"].firstMatch.label, "example/app · fix/reconnect-crash \u{2192} main")
        shot(app, "CR4-card")
    }

    // MARK: Step 5: the card's Checks and Changes

    /// Garden plan's card asks for that one chat with `detail: true` and `fresh: true`, then shows Checks (failing,
    /// with its runs) and Changes (a file with a patch whose diff opens, a cut patch, a binary file, and the files the
    /// list leaves out); Ask to Fix Checks shows its exact words.
    @MainActor func test40v_CardChecksAndChanges() throws {
        let link = "https://github.com/example/app/pull/24"
        let size = ["files": 5, "additions": 128, "deletions": 12]
        let counts: [String: Any] = ["state": "failed", "passed": 3, "failed": 2, "running": 0]
        var withRuns = counts
        withRuns["runs"] = [["name": "lint", "state": "failed"], ["name": "ui-tests", "state": "failed"],
                            ["name": "unit-tests", "state": "passed"], ["name": "build", "state": "passed"], ["name": "docs", "state": "passed"]]
        fixture("/__fixture/mode", ["prStatus": [
            "default/s-garden": ["state": "open", "repo": "example/app", "branch": "fix/reconnect-crash", "number": 24, "url": link,
                                 "size": size, "checks": counts, "title": "Fix reconnect crash", "base": "main",
                                 "items": [["state": "open", "repo": "example/app", "branch": "fix/reconnect-crash", "number": 24,
                                            "url": link, "source": "github", "size": size, "checks": withRuns,
                                            "title": "Fix reconnect crash", "base": "main",
                                            "files": [["path": "App/Net/Reconnect.swift", "additions": 96, "deletions": 8,
                                                       "patch": "@@ -10,3 +10,4 @@\n context\n-old line\n+new line\n+one more"],
                                                      ["path": "CHANGELOG.md", "additions": 30, "deletions": 4, "patch_cut": true],
                                                      ["path": "Assets/logo.png", "additions": 0, "deletions": 0, "binary": true]]]]]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        ensureAppCoding(app)
        XCTAssertTrue(waitUntil(20) { self.labelOf(self.row(app, "s-garden")).contains("2 checks failing") }, labelOf(row(app, "s-garden")))
        tapPRMark(app, "s-garden")
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 8), "the PR card")
        let any = app.descendants(matching: .any)
        let checks = any["prcard.checks"].firstMatch
        XCTAssertTrue(checks.waitForExistence(timeout: 15), "Checks")
        XCTAssertEqual(checks.label, "2 of 5 checks failing")
        // The card's own ask: this one chat, fresh, with detail.
        let asks = writes("POST", "/api/plugins/hermes-hq-push/sessions/pr-status").filter { $0["detail"] as? Bool == true }
        XCTAssertEqual(asks.count, 1, "one detail ask (\(asks))")
        XCTAssertEqual((asks.first?["sessions"] as? [[String: Any]])?.count, 1, "for one chat")
        XCTAssertEqual((asks.first?["sessions"] as? [[String: Any]])?.first?["id"] as? String, "s-garden")
        XCTAssertEqual(asks.first?["fresh"] as? Bool, true)
        XCTAssertTrue(any["prcard.changes"].firstMatch.waitForExistence(timeout: 5), "Changes")
        XCTAssertEqual(any["prcard.changes"].firstMatch.label, "Changes · 5 files · +128 \u{2212}12")
        XCTAssertTrue(any["prcard.file.0"].firstMatch.label.hasPrefix("App/Net/Reconnect.swift"), any["prcard.file.0"].firstMatch.label)
        XCTAssertTrue(any["prcard.file.1"].firstMatch.label.contains("Too large to show here"), any["prcard.file.1"].firstMatch.label)
        XCTAssertTrue(any["prcard.file.2"].firstMatch.label.contains("Binary file"), any["prcard.file.2"].firstMatch.label)
        app.swipeUp(velocity: .slow)        // the large detent
        shot(app, "CR5-card")
        // The card's list draws its lower rows only once they come on screen.
        let more = any["prcard.moreFiles"].firstMatch
        for _ in 0..<3 where !more.exists { app.swipeUp(velocity: .slow) }
        XCTAssertEqual(more.label, "and 2 more files")
        XCTAssertTrue(app.buttons["prcard.askToFixChecks"].exists, "Ask to Fix Checks")

        // A file's diff, in the steps sheet's panel.
        app.buttons["prcard.file.0"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Reconnect.swift"].waitForExistence(timeout: 5), "the file's page")
        XCTAssertTrue(any["step.diff"].firstMatch.waitForExistence(timeout: 5), "the diff panel")
        shot(app, "CR5-diff")
        app.navigationBars["Reconnect.swift"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 5))
        // A cut patch opens nothing.
        XCTAssertFalse(app.buttons["prcard.file.1"].exists, "a cut patch is not a button")

        // The runs.
        app.buttons["prcard.checks"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Checks"].waitForExistence(timeout: 5), "the runs")
        XCTAssertEqual(any["prcard.run.0"].firstMatch.label, "lint, Failed")
        XCTAssertEqual(any["prcard.run.4"].firstMatch.label, "docs, Passed")
        shot(app, "CR5-runs")
        app.navigationBars["Checks"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 5))

        // Ask to Fix Checks: its exact words; Cancel sends nothing.
        let fix = app.buttons["prcard.askToFixChecks"]
        for _ in 0..<3 where !fix.isHittable { app.swipeUp(velocity: .slow) }
        fix.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.staticTexts["The checks on pull request #24 are failing. Fix them."].exists, "the exact words")
        confirm.buttons["Cancel"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(submitted().isEmpty, "Cancel sent nothing")
    }

    // MARK: Step 6: Trustworthy coding view (unified settings, health banner, PR card actions & warnings)

    @MainActor func test40w_CodingTrustAndHealth() throws {
        let now = Date().timeIntervalSince1970
        setRow("s-shortcuts", ["profile": "default", "title": "Add keyboard shortcuts", "cwd": "/home/hermes/app",
                               "last_active": now - 120, "unread": false])
        let link = "https://github.com/example/app/pull/24"
        let runLink = "https://github.com/example/app/actions/runs/91"
        let size = ["files": 4, "additions": 128, "deletions": 12]
        let counts: [String: Any] = ["state": "failed", "passed": 3, "failed": 2, "running": 0]
        var withRuns = counts
        withRuns["runs"] = [
            ["name": "lint", "state": "failed", "url": runLink, "summary": "2 unused variables in Reconnect.swift"],
            ["name": "ui-tests", "state": "failed", "summary": "Timeout waiting for PR card"],
            ["name": "unit-tests", "state": "passed"]
        ]
        fixture("/__fixture/mode", ["prManage": true, "prStatus": [
            "default/s-garden": ["state": "open", "repo": "example/app", "branch": "fix/reconnect-crash", "number": 24, "url": link,
                                 "size": size, "checks": counts, "title": "Fix reconnect crash", "base": "main",
                                 "items": [["state": "open", "repo": "example/app", "branch": "fix/reconnect-crash", "number": 24,
                                            "url": link, "source": "github", "size": size, "checks": withRuns,
                                            "title": "Fix reconnect crash", "base": "main",
                                            "files": [["path": "App/Net/Reconnect.swift", "additions": 96, "deletions": 8,
                                                       "patch": "@@ -10,3 +10,4 @@\n context\n-old line\n+new line\n+one more"]]]]],
            "deploys/s-release": ["state": "merged", "repo": "example/app", "number": 23,
                                  "url": "https://github.com/example/app/pull/23",
                                  "size": ["files": 1, "additions": 14, "deletions": 3],
                                  "items": [["state": "merged", "repo": "example/app", "number": 23,
                                             "url": "https://github.com/example/app/pull/23", "source": "github",
                                             "size": ["files": 1, "additions": 14, "deletions": 3],
                                             "files": [["path": "App/Sessions/ProjectPage.swift", "additions": 14, "deletions": 3,
                                                        "patch": "@@ -1,2 +1,3 @@\n context\n+added"]]]]],
            "default/s-shortcuts": ["state": "unknown"]
        ]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        ensureAppCoding(app)

        // Healthy project (PRs already matching): zero health banner; `?` sits cleanly in the PR filter bar.
        // Count matches the exact 2 displayed unknown rows (s-shortcuts in Active + s-old in Done; never phantom outside rows).
        let unknown = app.buttons["sessions.projectPage.pr.unknown"]
        XCTAssertTrue(unknown.waitForExistence(timeout: 15), "? filter pill for unmatched chat")
        XCTAssertTrue(waitUntil(10) { unknown.label.contains("2 loaded chats") }, unknown.label)
        XCTAssertFalse(app.descendants(matching: .any)["sessions.projectPage.codingHealth"].firstMatch.exists,
                       "no health banner when PRs are already matching")
        shot(app, "CR6-header-unknown-pill")
        // Tapping `?` rings it ("2 Unknown") and filters the project list to the exact 2 unmatched chats.
        unknown.tap()
        XCTAssertTrue(waitUntil(10) { unknown.isSelected && self.row(app, "s-shortcuts").exists && self.row(app, "s-old").exists && !self.row(app, "s-garden").exists })
        shot(app, "CR6-unknown-filter-active")
        unknown.tap()
        XCTAssertTrue(waitUntil(10) { !unknown.isSelected && self.row(app, "s-garden").exists })

        // Unified Project Settings now includes Coding Project + Repository row.
        openProjectSettings(app)
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.coding").waitForExistence(timeout: 5))
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.repository").waitForExistence(timeout: 5))
        shot(app, "CR6-project-settings-coding")
        closeProjectSettings(app)

        // PR card: Refresh toolbar button, Open Chat, Mark as Closed, failing-checks merge warning, and check run summaries.
        tapPRMark(app, "s-garden")
        XCTAssertTrue(app.navigationBars["Pull Request"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["prcard.refresh"].waitForExistence(timeout: 5), "Refresh button")
        let checks = app.descendants(matching: .any)["prcard.checks"].firstMatch
        XCTAssertTrue(checks.waitForExistence(timeout: 15))
        app.swipeUp(velocity: .slow)
        let openChatBtn = app.buttons["prcard.openChat"]
        for _ in 0..<3 where !openChatBtn.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(openChatBtn.exists, "Open Chat in PR card")
        XCTAssertTrue(app.buttons["prcard.markClosed"].exists, "Mark as Closed in PR card")
        shot(app, "CR6-card-actions")

        // Asking to merge while checks fail surfaces an explicit warning title!
        let merge = app.buttons["prcard.askToMerge"]
        merge.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Checks Are Failing — Merge Anyway?"].exists, "failing-check merge warning")
        XCTAssertTrue(alert.staticTexts["Merge pull request #24."].exists, "exact merge words preserved")
        shot(app, "CR6-merge-warning")
        alert.buttons["Cancel"].tap()

        // Checks page shows failure summaries and external link affordance.
        for _ in 0..<3 where !checks.isHittable { app.swipeDown(velocity: .slow) }
        checks.tap()
        XCTAssertTrue(app.navigationBars["Checks"].waitForExistence(timeout: 5))
        shot(app, "CR6-checks-summary")
        app.navigationBars["Checks"].buttons.element(boundBy: 0).tap()
        app.buttons["sheet.close"].firstMatch.tap()

        // Unmatched `?` card explains why instead of showing an empty "Status Unknown" dead end.
        XCTAssertTrue(row(app, "s-shortcuts").waitForExistence(timeout: 8))
        tapPRMark(app, "s-shortcuts")
        XCTAssertTrue(app.navigationBars["Branch"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["prcard.unknownNotice"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prcard.retry"].exists)
        XCTAssertTrue(app.buttons["prcard.linkRepository"].exists)
        shot(app, "CR6-unknown-card")
    }
}
