// More › Files and Review (docs/spec/3x-morepages.md §11 acceptance, §21 stress lines for these pages), against the
// stand-in's invented tree (scripts/fixtures/morepages/workspace.py). Run:
//   HQN_MOREPAGES_GATEWAYS="main" HQN_MOREPAGES_PORTS="10053" HQN_MOREPAGES_ONLY="WorkspaceUITests" scripts/e2e-morepages.sh <udid>

import XCTest

final class WorkspaceUITests: MorePagesCase {
    private let site = "/home/hermes/projects/site"
    private let notes = "/home/hermes/projects/notes"

    // MARK: Helpers

    @MainActor private func entry(_ name: String) -> XCUIElement { app.cells["workspace.entry.\(name)"] }

    @MainActor private func rootPath() -> String { app.staticTexts["workspace.root.path"].label }

    @MainActor private func waitForRoot(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let label = app.staticTexts["workspace.root.path"]
        XCTAssertTrue(label.waitForExistence(timeout: 15), "the root row", file: file, line: line)
        XCTAssertTrue(waitUntil(15) { label.label == path }, "the root reads \(path), not \(label.label)", file: file, line: line)
    }

    /// Scrolls up or down until the element can be tapped clear of the bars.
    @MainActor private func bring(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "\(element)", file: file, line: line)
        let floor = app.windows.firstMatch.frame.height - 130
        for _ in 0..<12 where !element.isHittable || element.frame.midY > floor || element.frame.minY < 110 {
            if element.frame.minY < 110 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    @MainActor private func openRootMenu(_ item: String) {
        let menu = app.buttons["workspace.root.menu"]
        bring(menu)
        menu.tap()
        let choice = app.buttons[item]
        XCTAssertTrue(choice.waitForExistence(timeout: 8), "the menu offers \(item)")
        choice.tap()
    }

    /// Choose Folder… → (the root's parent) → `folder` → Use This Folder.
    @MainActor private func choose(_ folder: String) {
        openRootMenu("Choose Folder…")
        XCTAssertTrue(app.tables["workspace.chooser"].waitForExistence(timeout: 10), "the folder chooser")
        let row = entry(folder)
        bring(row)
        row.tap()
        XCTAssertTrue(app.navigationBars[folder].waitForExistence(timeout: 10), "the chooser shows \(folder)")
        app.buttons["workspace.use-folder"].tap()
    }

    private func workspaceRequests() throws -> [[String: Any]] {
        try restLog().filter { (($0["path"] as? String) ?? "").hasPrefix("/api/fs/") || (($0["path"] as? String) ?? "").hasPrefix("/api/git/") }
    }

    /// Acceptance 3: nothing on either page writes.
    private func assertOnlyReads(file: StaticString = #filePath, line: UInt = #line) throws {
        let requests = try workspaceRequests()
        XCTAssertFalse(requests.isEmpty, "the pages read something", file: file, line: line)
        let writes = requests.filter { ($0["method"] as? String) != "GET" }
        XCTAssertTrue(writes.isEmpty, "only GETs, but saw \(writes)", file: file, line: line)
        let allowed: Set<String> = ["/api/fs/default-cwd", "/api/fs/list", "/api/fs/read-text", "/api/fs/git-root", "/api/fs/download",
                                    "/api/fs/read-data-url", "/api/git/review/list", "/api/git/review/diff"]
        let other = Set(requests.compactMap { $0["path"] as? String }).subtracting(allowed)
        XCTAssertTrue(other.isEmpty, "only the read routes, but saw \(other)", file: file, line: line)
        XCTAssertTrue(((try state()["writes"] as? [Any]) ?? []).isEmpty, "the stand-in recorded no write", file: file, line: line)
    }

    /// A relaunch that keeps the run's text size (the shared `relaunch` starts at the default size).
    @MainActor private func again(_ arguments: [String] = []) {
        var all = arguments
        if let size = ProcessInfo.processInfo.environment["HQN_TEXT_SIZE"], !size.isEmpty {
            all += ["-UIPreferredContentSizeCategoryName", size]
        }
        relaunch(all)
    }

    // MARK: Acceptance

    @MainActor func testU10_FilesAndReview() throws {
        launchSignedIn(["-HQFilesForgetFolders", "YES"])
        openMore("files")
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 10))
        waitForRoot(site)
        XCTAssertEqual(app.staticTexts["workspace.root.name"].label, "site")
        XCTAssertEqual(app.staticTexts["workspace.root.source"].label, "The default folder on the computer running Hermes")
        // The root's entries, folders first.
        for name in ["assets", "src", "README.md", "package.json", "build.log"] {
            XCTAssertTrue(entry(name).waitForExistence(timeout: 10), "Files lists \(name)")
        }
        XCTAssertLessThan(entry("src").frame.minY, entry("README.md").frame.minY, "folders come first")
        if app.cells["workspace.bot"].exists { XCTAssertTrue(app.buttons["more.bot-picker"].exists) }
        shot("files-root")

        // Into a folder and back.
        bring(entry("src"))
        entry("src").tap()
        XCTAssertTrue(app.navigationBars["src"].waitForExistence(timeout: 10))
        XCTAssertTrue(entry("components").waitForExistence(timeout: 10))
        XCTAssertTrue(entry("app.js").exists)
        shot("files-folder")
        entry("components").tap()
        XCTAssertTrue(entry("nav.js").waitForExistence(timeout: 10))
        back()
        XCTAssertTrue(entry("app.js").waitForExistence(timeout: 10))
        back()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 10))

        // A Markdown file reads formatted (Preview | Source), as in the chat's Files.
        bring(entry("README.md"))
        entry("README.md").tap()
        let note = app.textViews["artifact.text.body"]
        XCTAssertTrue(note.waitForExistence(timeout: 15), "the note page")
        XCTAssertTrue(waitUntil(10) { ((note.value as? String) ?? "").contains("The marketing site") }, "the file's text shows")
        XCTAssertFalse(((note.value as? String) ?? "").contains("# Site"), "the heading is drawn, not its #")
        XCTAssertTrue(app.segmentedControls["artifact.text.mode"].exists)
        shot("files-markdown")
        back()

        // A text file.
        bring(entry("package.json"))
        entry("package.json").tap()
        let text = app.textViews["workspace.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 15), "the text page")
        XCTAssertTrue(waitUntil(10) { ((text.value as? String) ?? "").contains("\"version\": \"2.4.0\"") }, "the file's text shows")
        XCTAssertFalse(app.staticTexts["workspace.truncated"].exists, "a small file has no notice")
        XCTAssertTrue(app.buttons["workspace.share"].isEnabled)
        shot("files-text")
        back()

        // The 3 MB file shows only its start, and says so.
        bring(entry("build.log"))
        entry("build.log").tap()
        let notice = app.staticTexts["workspace.truncated"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "the truncation notice")
        XCTAssertEqual(notice.label, "Showing the first 512 KB of 3 MB.")
        XCTAssertTrue(waitUntil(15) { ((app.textViews["workspace.text"].value as? String) ?? "").contains("build step ok") })
        shot("files-truncated")
        back()

        // Choose Folder… → Use This Folder: the header changes.
        openRootMenu("Choose Folder…")
        XCTAssertTrue(app.tables["workspace.chooser"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["projects"].waitForExistence(timeout: 10), "the chooser starts at the root's parent")
        XCTAssertTrue(entry("notes").waitForExistence(timeout: 10))
        XCTAssertTrue(entry("site").exists)
        XCTAssertTrue(app.cells["workspace.parent"].exists, "the enclosing folder can be reached")
        XCTAssertTrue(app.buttons["workspace.use-folder"].exists)
        shot("files-chooser")
        entry("notes").tap()
        XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No folders here"].waitForExistence(timeout: 10), "a chooser lists folders only")
        app.buttons["workspace.use-folder"].tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 10))
        waitForRoot(notes)
        XCTAssertEqual(app.staticTexts["workspace.root.source"].label, "Folder you chose")
        XCTAssertTrue(entry("ideas.md").waitForExistence(timeout: 10))
        XCTAssertFalse(entry("README.md").exists)
        shot("files-chosen")

        // ... and survives a relaunch.
        again()
        openMore("files")
        waitForRoot(notes)
        XCTAssertTrue(entry("ideas.md").waitForExistence(timeout: 10))

        // Review of a folder that is not a repository.
        back()
        openMore("review")
        XCTAssertTrue(app.navigationBars["Changes"].waitForExistence(timeout: 10))
        waitForRoot(notes)
        XCTAssertTrue(app.staticTexts["Not a Git Folder"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Changes shows what changed in a project that uses Git."].exists)
        XCTAssertTrue(app.cells["workspace.state"].buttons["Choose Folder…"].exists)
        shot("review-not-git")
        back()

        // Use Chat's Folder returns to the folder Files follows by itself.
        openMore("files")
        waitForRoot(notes)
        openRootMenu("Use Chat’s Folder")
        waitForRoot(site)
        XCTAssertTrue(entry("README.md").waitForExistence(timeout: 10))
        app.buttons["workspace.root.menu"].tap()
        XCTAssertTrue(app.buttons["Choose Folder…"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Use Chat’s Folder"].exists, "offered only while a folder is chosen")
        app.buttons["Choose Folder…"].tap()
        XCTAssertTrue(app.tables["workspace.chooser"].waitForExistence(timeout: 10))
        back()
        back()

        // Review lists the two changed files; a diff opens.
        openMore("review")
        waitForRoot(site)
        let changed = app.cells["workspace.change.src/app.js"]
        XCTAssertTrue(changed.waitForExistence(timeout: 15))
        XCTAssertTrue(app.cells["workspace.change.src/pricing.html"].exists)
        XCTAssertEqual(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.change.'")).count, 2)
        XCTAssertTrue(app.staticTexts["Changed · +3 −1"].exists)
        // Item 18: a new file can't have removed lines, so the zero side drops.
        XCTAssertTrue(app.staticTexts["New file · +5"].exists)
        XCTAssertTrue(app.staticTexts["2 changed files"].exists)
        shot("review-list")
        changed.tap()
        let diff = app.textViews["workspace.diff"]
        XCTAssertTrue(diff.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { ((diff.value as? String) ?? "").contains("+footer(document.body)") }, "the diff shows its added lines")
        XCTAssertTrue(((diff.value as? String) ?? "").contains("-console.log('ready')"))
        shot("review-diff")
        back()

        try assertOnlyReads()
        let diffs = try rest("GET", "/api/git/review/diff")
        XCTAssertEqual(diffs.last?["query"] as? [String: String], ["path": site, "file": "src/app.js", "scope": "uncommitted", "staged": "false"])
        let lists = try rest("GET", "/api/git/review/list")
        XCTAssertEqual(lists.last?["query"] as? [String: String], ["path": site, "scope": "uncommitted"])
    }

    @MainActor func testFiles_FailuresAreSaidInWords() throws {
        launchSignedIn(["-HQFilesForgetFolders", "YES"])
        openMore("files")
        waitForRoot(site)

        // A folder the gateway may not read.
        bring(entry("private"))
        entry("private").tap()
        XCTAssertTrue(app.staticTexts["Can’t Open This Folder"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["The computer running Hermes doesn’t allow Hermes HQ to read this folder."].exists)
        XCTAssertTrue(app.cells["workspace.state"].buttons["Try Again"].exists)
        shot("files-folder-error")
        back()

        // An empty folder.
        bring(entry("empty"))
        entry("empty").tap()
        XCTAssertTrue(app.staticTexts["Empty Folder"].waitForExistence(timeout: 15))
        back()

        // A text file past the gateway's limit, and a download past the phone's: both are refused in words.
        bring(entry("huge.sql"))
        entry("huge.sql").tap()
        XCTAssertTrue(app.alerts["Couldn’t Open This File"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.alerts.staticTexts["This file is too large to open on this iPhone."].exists)
        shot("files-too-large")
        app.alerts.buttons["OK"].tap()

        bring(entry("assets"))
        entry("assets").tap()
        XCTAssertTrue(entry("reel.mov").waitForExistence(timeout: 10))
        entry("reel.mov").tap()
        XCTAssertTrue(app.alerts["Couldn’t Open This File"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.alerts.staticTexts["This file is too large to open on this iPhone."].exists)
        app.alerts.buttons["OK"].tap()

        // A file that is not text opens in Quick Look.
        entry("logo.bin").tap()
        XCTAssertTrue(waitUntil(30) { self.app.otherElements["artifact.quicklook"].exists || self.app.navigationBars["logo.bin"].exists },
                      "a binary opens in Quick Look")
        shot("files-quicklook")
        let done = app.buttons["Done"], close = app.buttons["Close"]
        _ = waitUntil(5) { done.exists || close.exists }
        if done.exists { done.tap() } else if close.exists { close.tap() }
        else { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.073)).tap() }
        XCTAssertTrue(entry("styles.css").waitForExistence(timeout: 10))
        back()

        // The chosen folder is deleted on the gateway: the header stays, the words say so, Choose Folder… is offered.
        choose("notes")
        waitForRoot(notes)
        XCTAssertTrue(entry("ideas.md").waitForExistence(timeout: 10))
        try account.control("/__fixture/workspace", ["gone": [notes]])
        back()
        openMore("files")
        waitForRoot(notes)
        XCTAssertTrue(app.staticTexts["Folder Not Found"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["This folder no longer exists on the computer running Hermes."].exists)
        XCTAssertTrue(app.cells["workspace.state"].buttons["Try Again"].exists)
        XCTAssertTrue(app.cells["workspace.state"].buttons["Choose Folder…"].exists)
        shot("files-folder-gone")
        try account.control("/__fixture/workspace", ["gone": [String]()])
        app.cells["workspace.state"].buttons["Try Again"].tap()
        XCTAssertTrue(entry("ideas.md").waitForExistence(timeout: 15))
        openRootMenu("Use Chat’s Folder")
        waitForRoot(site)
        try assertOnlyReads()
    }

    @MainActor func testFiles_SlowThenFailingFirstReadThenTryAgain() throws {
        launchSignedIn(["-HQFilesForgetFolders", "YES"])
        try delay("GET", "/api/fs/default-cwd", seconds: 4)
        try fail("GET", "/api/fs/list", status: 500, detail: "The disk is busy")
        openMore("files")
        // The page is up at once with its loading row while the gateway is slow.
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["workspace.loading"].waitForExistence(timeout: 3), "the loading row shows while the first read is slow")
        XCTAssertTrue(app.staticTexts["Couldn’t Read This Folder"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["The disk is busy"].exists)
        shot("files-error")
        app.cells["workspace.state"].buttons["Try Again"].tap()
        XCTAssertTrue(entry("README.md").waitForExistence(timeout: 15), "Try Again reads the folder")

        // Review: the list fails, then works.
        back()
        try fail("GET", "/api/git/review/list", status: 500, detail: "git is busy")
        openMore("review")
        XCTAssertTrue(app.staticTexts["Couldn’t Load Changes"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["git is busy"].exists)
        app.cells["workspace.state"].buttons["Try Again"].tap()
        XCTAssertTrue(app.cells["workspace.change.src/app.js"].waitForExistence(timeout: 15))

        // A diff that fails says so on its page.
        try fail("GET", "/api/git/review/diff", status: 500, detail: "no diff today")
        app.cells["workspace.change.src/app.js"].tap()
        XCTAssertTrue(app.staticTexts["Couldn't Open"].waitForExistence(timeout: 15) || app.staticTexts["Couldn’t Open"].exists)
        back()
        try assertOnlyReads()
    }

    @MainActor func testFiles_LargeFolderAndManyChanges() throws {
        try account.control("/__fixture/workspace", ["entries": 3000, "changes": 500])
        launchSignedIn(["-HQFilesForgetFolders", "YES"])
        openMore("files")
        waitForRoot(site)
        bring(entry("many"))
        let started = Date()
        entry("many").tap()
        XCTAssertTrue(entry("file-0000.txt").waitForExistence(timeout: 20))
        measured("Files: 3,000 entries listed \(String(format: "%.2f", Date().timeIntervalSince(started))) s after the tap")
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(app.tables["more.files"].exists)
        // Rapid taps on rows: one page opens, nothing doubles.
        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45))
        middle.tap(); middle.tap(); middle.tap()
        XCTAssertTrue(app.textViews["workspace.text"].waitForExistence(timeout: 15))
        back()
        if !app.tables["more.files"].waitForExistence(timeout: 5) { back() }
        back()

        openMore("review")
        waitForRoot(site)
        XCTAssertTrue(app.cells["workspace.change.src/app.js"].waitForExistence(timeout: 20))
        for _ in 0..<5 { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(app.tables["more.review"].exists)
        try assertOnlyReads()
    }

    @MainActor func testFiles_RelaunchOnEachPage() throws {
        launchSignedIn(["-HQFilesForgetFolders", "YES"])
        openMore("files")
        waitForRoot(site)
        entry("src").tap()
        XCTAssertTrue(entry("app.js").waitForExistence(timeout: 10))
        again()
        // Either the page is back or More's root shows; never a page with no tab bar and no way back.
        XCTAssertTrue(waitUntil(20) { self.app.tabBars.buttons["More"].exists || self.app.navigationBars.buttons.firstMatch.exists })
        openMore("review")
        XCTAssertTrue(app.cells["workspace.change.src/app.js"].waitForExistence(timeout: 15))
        again()
        XCTAssertTrue(waitUntil(20) { self.app.tabBars.buttons["More"].exists || self.app.navigationBars.buttons.firstMatch.exists })
        openMore("files")
        waitForRoot(site)
        XCTAssertTrue(entry("README.md").waitForExistence(timeout: 10))
        try assertOnlyReads()
    }

    @MainActor func testFiles_PerBotAndTheLastChatsFolder() throws {
        launchSignedIn(["-HQFilesForgetFolders", "YES"])
        openMore("files")
        waitForRoot(site)
        // More than one bot: the picker is there; a folder chosen for one bot is not the other's.
        XCTAssertTrue(app.cells["workspace.bot"].waitForExistence(timeout: 10))
        choose("notes")
        waitForRoot(notes)
        bring(app.cells["workspace.bot"])
        app.cells["workspace.bot"].tap()
        let inbox = app.buttons["Inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 8), "the bot menu")
        shot("files-bot-menu")
        inbox.tap()
        waitForRoot(site)
        XCTAssertEqual(app.staticTexts["workspace.root.source"].label, "The default folder on the computer running Hermes")
        XCTAssertEqual((try rest("GET", "/api/fs/default-cwd").last?["query"] as? [String: String])?["profile"], "inbox")
        XCTAssertEqual((try rest("GET", "/api/fs/list").last?["query"] as? [String: String]), ["path": site, "profile": "inbox"])
        // Back to the first bot: its chosen folder is still its own.
        app.cells["workspace.bot"].tap()
        XCTAssertTrue(app.buttons["Hermes"].waitForExistence(timeout: 8))
        app.buttons["Hermes"].tap()
        waitForRoot(notes)
        openRootMenu("Use Chat’s Folder")
        waitForRoot(site)

        // The chat last on screen: its bot's Files follows its folder, and names the chat.
        back()
        tab("Sessions")
        let chat = app.staticTexts["The 2.4 report"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15), "the Sessions list")
        chat.tap()
        XCTAssertTrue(waitUntil(15) { !self.app.tabBars.buttons["More"].isHittable }, "the chat is open")
        back()
        openMore("files")
        waitForRoot(site)          // the default bot's Files is not moved by another bot's chat
        app.cells["workspace.bot"].tap()
        XCTAssertTrue(app.buttons["Deploys"].waitForExistence(timeout: 8))
        app.buttons["Deploys"].tap()
        waitForRoot("/home/hermes/app")
        XCTAssertEqual(app.staticTexts["workspace.root.source"].label, "The folder of “The 2.4 report”")
        XCTAssertTrue(entry("CHANGELOG.md").waitForExistence(timeout: 10))
        shot("files-chat-folder")
        back()
        openMore("review")
        waitForRoot("/home/hermes/app")
        XCTAssertTrue(app.staticTexts["No Changes"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Nothing has changed in this folder since its last saved version."].exists)
        shot("review-no-changes")
        try assertOnlyReads()
    }
}
