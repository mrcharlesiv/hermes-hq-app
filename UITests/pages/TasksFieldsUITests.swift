// [tasks-first] Step 3 (owner 2026-11-12: "complex enough to handle any task or use case"; mockup 3-task-your-own):
// what a task manager's task has, on an add-on that keeps it (hermes-hq-push 0.9.53): priority (the circle's colour),
// tags, an alert before it's due, a start day, and your own files and links. Each is one row once set; what isn't set
// waits as quiet words under the who row. An older add-on shows none of it.
// Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_Fields); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_Fields() throws {
        // A task with everything set: one row each, and a file of your own under Files.
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Go through the open job applications"])
        let priority = app.descendants(matching: .any)["task.priority"].firstMatch
        XCTAssertTrue(priority.waitForExistence(timeout: 15), "the priority row")
        XCTAssertTrue(priority.label.contains("High priority"), priority.label)
        let tags = app.descendants(matching: .any)["task.tags"].firstMatch
        XCTAssertTrue(tags.exists && tags.label.contains("hiring, q4"), tags.label)
        let due = app.descendants(matching: .any)["task.due"].firstMatch
        XCTAssertTrue(due.label.contains("alert 30 min before"), due.label)
        XCTAssertFalse(app.descendants(matching: .any)["task.priority.add"].exists, "what is set isn't offered again")
        XCTAssertTrue(app.descendants(matching: .any)["task.start.add"].firstMatch.exists, "what isn't set waits as quiet words")
        XCTAssertTrue(app.buttons["task.made.file"].firstMatch.exists, "your own file is under Files")
        XCTAssertTrue(app.descendants(matching: .any)["task.files.add"].firstMatch.exists, "Files ends with the way to add one")
        shot("fields-1-task" + Self.lookName)

        // A task that has started: in Today until it's due; its start day is a row.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesSeedFile", "brief.pdf"])
        let taxes = app.cells["task-row-Gather the tax papers"].firstMatch
        XCTAssertTrue(taxes.waitForExistence(timeout: 15), "a task that has started is in Today")
        let spoken = taxes.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Medium priority")).firstMatch
        XCTAssertTrue(spoken.exists || taxes.label.contains("Medium priority"), "the row says its priority: \(taxes.label)")
        shot("fields-2-today" + Self.lookName)
        app.buttons["tasks.view.inbox"].firstMatch.tap()
        XCTAssertTrue(app.cells["task-row-Fix the porch light"].firstMatch.waitForExistence(timeout: 5), "Inbox lists the porch light")
        XCTAssertFalse(taxes.exists, "a task with a start day is not loose in Inbox")
        shot("fields-3-inbox" + Self.lookName)
        app.buttons["tasks.view.today"].firstMatch.tap()
        XCTAssertTrue(taxes.waitForExistence(timeout: 5), "back on Today")
        taxes.tap()
        let start = app.descendants(matching: .any)["task.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the start day's row")
        XCTAssertTrue(start.label.contains("Started yesterday"), start.label)

        // Priority: the row's menu.
        let row = app.descendants(matching: .any)["task.priority"].firstMatch
        XCTAssertTrue(row.label.contains("Medium priority"), row.label)
        row.tap()
        let high = app.buttons["High"].firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 5), "the priority menu")
        high.tap()
        XCTAssertTrue(waitUntil(10) { self.patched("t_taxes") { ($0["priority"] as? Int) == 1 } }, "the gateway is told")
        XCTAssertTrue(waitUntil(5) { row.label.contains("High priority") }, row.label)

        // Tags: one field, a comma between them.
        app.descendants(matching: .any)["task.tags"].firstMatch.tap()
        let field = app.textFields["task.tags.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the tags field")
        XCTAssertEqual(field.value as? String, "money")
        field.typeText(", #2026")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { self.patched("t_taxes") { ($0["tags"] as? [String]) == ["money", "2026"] } }, "the tags are saved")

        // No start day: the row goes, and "+ Start date" waits under the who row.
        start.tap()
        let none = app.buttons["No Start Date"].firstMatch
        XCTAssertTrue(none.waitForExistence(timeout: 5), "No Start Date in the menu")
        none.tap()
        XCTAssertTrue(app.descendants(matching: .any)["task.start.add"].firstMatch.waitForExistence(timeout: 10), "+ Start date")
        XCTAssertTrue(waitUntil(5) { !start.exists }, "its row is gone")

        // An alert before it's due: in the date's menu.
        let date = app.descendants(matching: .any)["task.due"].firstMatch
        date.tap()
        let alert = app.buttons["Alert"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Alert is in the date's menu")
        alert.tap()
        let hour = app.buttons["1 hour before"].firstMatch
        XCTAssertTrue(hour.waitForExistence(timeout: 5), "the alert choices")
        hour.tap()
        XCTAssertTrue(waitUntil(10) { self.patched("t_taxes") { ($0["alert"] as? Int) == 60 } }, "the alert is saved")
        XCTAssertTrue(waitUntil(5) { date.label.contains("alert 1 hour before") }, date.label)

        // A link of your own, then a file: "+ File" under the who row, then the Files section's last row.
        let add = app.descendants(matching: .any)["task.file.add"].firstMatch
        XCTAssertTrue(add.exists, "+ File while nothing is attached")
        add.tap()
        app.buttons["Link"].firstMatch.tap()
        let link = app.textFields["task.link.field"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "the link's field")
        if let had = link.value as? String, !had.isEmpty, had != "example.com/page" {
            link.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: had.count))
        }
        link.typeText("irs.gov/forms")
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(app.buttons["task.made.link"].firstMatch.waitForExistence(timeout: 10), "the link is under Files")
        XCTAssertTrue(waitUntil(5) {
            self.requests().contains { $0.method == "POST" && $0.path.hasSuffix("/tasks/t_taxes/attach")
                && ($0.body?["url"] as? String) == "https://irs.gov/forms" }
        }, "a bare address gets https://")
        XCTAssertFalse(add.exists, "+ File gives way to the Files section")
        let more = app.descendants(matching: .any)["task.files.add"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Files ends with the add row")
        more.tap()
        app.buttons["File"].firstMatch.tap()
        XCTAssertTrue(app.buttons["task.made.file"].firstMatch.waitForExistence(timeout: 10), "the file is under Files")
        XCTAssertTrue(waitUntil(5) {
            self.requests().contains { $0.method == "POST" && $0.path.hasSuffix("/tasks/t_taxes/attach")
                && ($0.body?["name"] as? String) == "brief.pdf" && !(($0.body?["data"] as? String) ?? "").isEmpty }
        }, "the file's bytes go to the gateway")
        shot("fields-4-edited" + Self.lookName)

        // Taking one off: hold it.
        app.buttons["task.made.link"].firstMatch.press(forDuration: 1.0)
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Remove in its menu")
        remove.tap()
        XCTAssertTrue(waitUntil(10) { !self.app.buttons["task.made.link"].exists }, "the link is gone")
        XCTAssertTrue(waitUntil(5) { self.requests().contains { $0.method == "DELETE" && $0.path.contains("/tasks/t_taxes/made/") } }, "the gateway is told")
    }

    /// An add-on before 0.9.53 keeps none of it: no rows, no quiet words, no priority in Sort By.
    @MainActor func testTasks_FieldsNeedTheAddOn() throws {
        try account.control("/__fixture/tasks-mode", ["older_addon": true])
        defer { _ = try? account.control("/__fixture/tasks-mode", ["older_addon": false]) }
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Pick up dry cleaning"])
        XCTAssertTrue(app.descendants(matching: .any)["task.who"].firstMatch.waitForExistence(timeout: 15), "the task opens")
        XCTAssertTrue(app.descendants(matching: .any)["task.repeat.add"].firstMatch.exists, "what it always had")
        for id in ["task.priority", "task.priority.add", "task.tags", "task.tags.add", "task.start", "task.start.add", "task.file.add", "task.files.add"] {
            XCTAssertFalse(app.descendants(matching: .any)[id].exists, "\(id) needs the newer add-on")
        }
        shot("fields-5-older-addon" + Self.lookName)
    }

    /// A PATCH of the task whose body passes `check`.
    private func patched(_ id: String, _ check: ([String: Any]) -> Bool) -> Bool {
        requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/tasks/\(id)") && $0.body.map(check) == true }
    }
}
