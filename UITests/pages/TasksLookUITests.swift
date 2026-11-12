// [tasks] Owner 2026-11-04, after the first live "Ask Hermes to Help": "the way that some of the work was presented …
// needs to be improved. And there's some buttons that I felt like should have had a tactic feedback, and they did not."
// A bot's work reads as lines (its one-paragraph shortlist split per place, a file named by its name), what it got ready
// sits under its line, a long step folds, the activity says words ("Started", not "working"), and every button that
// does something plays a cue. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_WorkReadsWellAndEveryTapIsFelt).

import XCTest

extension PagesTests {
    @MainActor func testTasks_WorkReadsWellAndEveryTapIsFelt() throws {
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks",
                              "-HQPagesOpenTask", "Pick a spot for Friday’s team lunch"])
        XCTAssertTrue(app.otherElements["task.sheet"].waitForExistence(timeout: 20) || app.descendants(matching: .any)["task.sheet"].exists,
                      "the lunch task opens")
        let note = app.buttons["task.made.note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "what Hermes made is listed")

        // What Hermes got ready is on the task in full (a brief short of room puts the steps first; nothing folds away).
        XCTAssertFalse(app.buttons["task.made.more"].exists, "nothing Hermes made hides behind a tap")
        // The note's row previews its first place, not the paragraph's first 60 characters.
        XCTAssertTrue(note.label.contains("Elm & Oak"), note.label)
        shot("tasks-look-ready-top" + Self.lookName)

        // A 200-character step folds to two lines; a tap shows it whole, and is felt.
        let longStep = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Shortlist 3 lunch spots")).firstMatch
        XCTAssertTrue(longStep.waitForExistence(timeout: 5), "the long step is listed")
        // The task's card is shorter now (chips, no tiles): the step can stand under the chat's bar, in sight but covered.
        for _ in 0..<3 where !longStep.isHittable { app.swipeUp(velocity: .slow) }
        let folded = longStep.frame.height
        var cues = hapticCount()
        longStep.tap()
        XCTAssertTrue(waitUntil(3) { longStep.frame.height > folded + 10 }, "the step opens: \(folded) → \(longStep.frame.height)")
        XCTAssertGreaterThan(hapticCount(), cues, "opening the step is felt")
        shot("tasks-look-step-open" + Self.lookName)

        // The note reads as lines: a place per line, its file by name, numbers that call.
        cues = hapticCount()
        note.tap()
        let text = app.textViews["task.note.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8), "the note opens")
        XCTAssertGreaterThan(hapticCount(), cues, "opening the note is felt")
        let words = (text.value as? String) ?? ""
        XCTAssertTrue(words.contains("Copper Kettle"), words)
        XCTAssertFalse(words.contains("groups. Bayside"), "one place per line: \(words)")
        XCTAssertTrue(words.contains("team-lunch-shortlist.md"), words)
        XCTAssertFalse(words.contains("/home/hermes/documents/"), "the file reads as its name: \(words)")
        shot("tasks-look-note" + Self.lookName)
        app.swipeDown(velocity: .fast)

        // The history says words (⋯ › History; it had been Activity on the page).
        cues = hapticCount()
        openHistory()
        let started = app.textViews.matching(NSPredicate(format: "value == %@", "Started")).firstMatch
        XCTAssertTrue(started.waitForExistence(timeout: 5), "\"working\" reads Started")
        XCTAssertGreaterThan(hapticCount(), cues, "opening History is felt")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Got it ready")).firstMatch.exists, "\"ready\" reads Got it ready")
        XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value == %@", "working")).firstMatch.exists)
        shot("tasks-look-activity" + Self.lookName)
        app.buttons["sheet.close"].firstMatch.tap()

        // Adding a step is felt.
        let plus = app.buttons["task.steps.add"].firstMatch
        for _ in 0..<4 where !(plus.exists && plus.isHittable) { app.swipeDown(velocity: .slow) }
        plus.tap()
        let field = app.textFields["task.add-step"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "+ opens the field")
        field.tap()
        cues = hapticCount()
        field.typeText("Book it\n")
        XCTAssertTrue(waitUntil(5) { self.hapticCount() > cues }, "adding a step is felt")

        // Copy Title is felt.
        cues = hapticCount()
        // The task's page is its chat: the chat's ⋯ holds the task's rows first (a task with no bots: the page's own ⋯).
        let more = app.buttons["task.more"].firstMatch
        (more.exists ? more : app.buttons["chat.more"].firstMatch).tap()
        app.buttons["Details"].firstMatch.tap()
        app.buttons["Copy Title"].firstMatch.tap()
        XCTAssertTrue(waitUntil(3) { self.hapticCount() > cues }, "Copy Title is felt")

        // A task of yours: its notes read formatted, with Edit; the file Hermes names reads by its name.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks",
                              "-HQPagesOpenTask", "Go through the open job applications"])
        let notes = app.textViews["task.notes.text"].firstMatch
        for _ in 0..<4 where !notes.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(notes.waitForExistence(timeout: 15), "the notes read formatted")
        shot("tasks-look-notes" + Self.lookName)
        let noteWords = (notes.value as? String) ?? ""
        XCTAssertFalse(noteWords.contains("contradictions; Sales"), "the checks read as a list: \(noteWords)")
        openHistory()
        let sheetFile = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "review-sheet.md")).firstMatch
        XCTAssertTrue(sheetFile.waitForExistence(timeout: 5), "the history names the file")
        XCTAssertFalse((sheetFile.value as? String ?? "").contains("/home/hermes/"), "by its name")
        shot("tasks-look-notes-activity" + Self.lookName)
        app.buttons["sheet.close"].firstMatch.tap()

        // Long notes fold to three lines with More at the heading's end (owner 2026-11-12: "The notes section takes up
        // WAY too much space"); More shows them whole, Less folds them again.
        let notesMore = app.buttons["task.notes.more"].firstMatch
        XCTAssertTrue(notesMore.waitForExistence(timeout: 5), "five lines of notes fold")
        let foldedHeight = notes.frame.height
        notesMore.tap()
        XCTAssertTrue(waitUntil(5) { notes.frame.height > foldedHeight + 20 }, "More shows the notes whole")
        shot("tasks-look-notes-open" + Self.lookName)
        notesMore.tap()
        XCTAssertTrue(waitUntil(5) { notes.frame.height < foldedHeight + 5 }, "Less folds them again")
        // [tasks-first] A tap on the notes writes (no Edit button, no ⋯ › Details › Edit Notes).
        cues = hapticCount()
        notes.tap()
        XCTAssertTrue(app.textViews["task.notes"].firstMatch.waitForExistence(timeout: 3) || app.textFields["task.notes"].firstMatch.exists,
                      "a tap on the notes opens the field")
        XCTAssertGreaterThan(hapticCount(), cues, "starting to write is felt")
        // Done over the keys ends writing.
        let editDone = app.buttons["task.edit-done"].firstMatch
        XCTAssertTrue(editDone.waitForExistence(timeout: 5), "Done over the keys")
        editDone.tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "the notes read formatted again")
        XCTAssertFalse(app.textViews["composer.text"].exists, "a task of your own has no message box")

        // Giving it to a bot is felt the moment it's chosen: the who row's menu.
        let who = app.descendants(matching: .any)["task.who"].firstMatch
        for _ in 0..<3 where !who.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(who.waitForExistence(timeout: 5), "the who row")
        who.tap()
        let hermes = app.buttons["Hermes"].firstMatch
        XCTAssertTrue(hermes.waitForExistence(timeout: 5), "the menu offers Hermes")
        cues = hapticCount()
        hermes.tap()
        XCTAssertTrue(waitUntil(3) { self.hapticCount() > cues }, "Assign is felt")
    }

    /// Every look (check-every-look): TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark; light when unset.
    /// ⋯ › History, on the task's page (its chat's ⋯) or a task standing alone (its own ⋯).
    @MainActor func openHistory() {
        let more = app.buttons["task.more"].firstMatch
        (more.exists ? more : app.buttons["chat.more"].firstMatch).tap()
        let history = app.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5), "⋯ › History")
        history.tap()
    }

    static var lookName: String {
        ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"].map { "-" + $0 } ?? ""
    }

    static var look: [String] {
        switch ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"] {
        case "dark": return ["-hqn.appearance", "dark"]
        case "desktop": return ["-hqn.appearance", "light", "-hqn.theme.desktopLook", "<true/>"]
        case "desktop-dark": return ["-hqn.appearance", "dark", "-hqn.theme.desktopLook", "<true/>"]
        default: return ["-hqn.appearance", "light"]
        }
    }

    /// The DEBUG probe's count of cues that would have played (`-HQDebugHapticsProbe YES`).
    @MainActor private func hapticCount() -> Int {
        let probe = app.descendants(matching: .any)["debug.haptics"]
        guard probe.waitForExistence(timeout: 5), let value = probe.value as? String,
              let count = value.split(separator: " ").first?.split(separator: "=").last.flatMap({ Int($0) }) else { return -1 }
        return count
    }
}
