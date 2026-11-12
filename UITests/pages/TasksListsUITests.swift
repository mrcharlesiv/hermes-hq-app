// [tasks-first] Your lists (owner 2026-11-04: "can we create sections? And an easy way to move the tasks amongst the
// sections"; 2026-11-12: they are the views row's own pills, by the plainer name). + at the row's end makes one, Move To
// from a held row files a task (New List… makes one on the way), Select moves several at once, a list is in your own
// order or sorted, and a hold on its pill renames or deletes it (its tasks are kept). Run with scripts/e2e-pages.sh
// (HQN_PAGES_ONLY=testTasks_Lists); every look: TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.

import XCTest

extension PagesTests {
    @MainActor func testTasks_Lists() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        let filter = app.buttons["pages.scope"].firstMatch   // Filter: the bots, then the page's commands
        XCTAssertTrue(filter.waitForExistence(timeout: 20))
        let cleaning = app.cells["task-row-Pick up dry cleaning"].firstMatch
        XCTAssertTrue(cleaning.waitForExistence(timeout: 15))
        let rail = app.descendants(matching: .any)["tasks.views"].firstMatch
        let today = app.buttons["tasks.view.today"].firstMatch
        let sectionsPut = { self.requests().filter { $0.method == "PUT" && $0.path.hasSuffix("/tasks/sections") } }
        let patched = { (id: String, key: String) in
            self.requests().filter { $0.method == "PATCH" && $0.path.hasSuffix("/tasks/\(id)") && $0.body?.keys.contains(key) == true }
        }
        func reach(_ pill: XCUIElement) {
            let width = app.windows.firstMatch.frame.maxX
            for _ in 0..<4 where !pill.exists || pill.frame.maxX > width - 8 { rail.swipeLeft() }
            for _ in 0..<4 where pill.frame.minX < 8 { rail.swipeRight() }
        }

        // + at the row's end: a new list, shown at once, saved on the gateway.
        let plus = app.buttons["tasks.view.new-list"].firstMatch
        reach(plus)
        plus.tap()
        nameList("Home", action: "Add")
        XCTAssertTrue(waitUntil(10) { sectionsPut().count == 1 }, "the list is saved")
        let home = app.buttons["tasks.view.list.Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10), "the new list is a pill")
        XCTAssertTrue(waitUntil(5) { home.isSelected }, "and is on show")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.view-empty"].firstMatch.waitForExistence(timeout: 5), "an empty list says so")
        shot("tasks-lists-new" + name)

        // Hold a row › Move To › New List…: the list is made, the task filed, and the list shown.
        reach(today)
        today.tap()
        XCTAssertTrue(cleaning.waitForExistence(timeout: 5))
        cleaning.press(forDuration: 0.8)
        submenu("Move To").tap()
        shot("tasks-lists-move-to" + name)
        app.buttons["New List…"].firstMatch.tap()
        nameList("Errands", action: "Add")
        XCTAssertTrue(waitUntil(10) { sectionsPut().count == 2 })
        XCTAssertTrue(waitUntil(10) { !patched("t_cleaning", "section").isEmpty }, "Move To files it")
        let errands = app.buttons["tasks.view.list.Errands"].firstMatch
        XCTAssertTrue(waitUntil(10) { errands.exists && errands.isSelected }, "the new list is on show")
        XCTAssertTrue(cleaning.waitForExistence(timeout: 5), "with the task in it")

        // A task in a list still shows in your day.
        reach(today)
        today.tap()
        XCTAssertTrue(cleaning.waitForExistence(timeout: 5), "a filed task is still due today")

        // Select two, Move To › Home.
        filter.tap()
        app.buttons["Select Tasks"].firstMatch.tap()
        let dentist = app.cells["task-row-Call the dentist"].firstMatch
        let passport = app.cells["task-row-Renew passport"].firstMatch
        XCTAssertTrue(dentist.waitForExistence(timeout: 5))
        dentist.tap()
        passport.tap()
        XCTAssertTrue(waitUntil(5) { dentist.isSelected && passport.isSelected }, "two picked")
        shot("tasks-lists-select" + name)
        app.buttons["tasks.select.move"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { !patched("t_dentist", "section").isEmpty && !patched("t_passport", "section").isEmpty }, "both moved")
        XCTAssertTrue(waitUntil(5) { !app.buttons["tasks.select.done"].exists }, "Select ends after the move")

        // The list: its two tasks, the count on its pill, and Sort By in Filter.
        reach(home)
        home.tap()
        XCTAssertTrue(dentist.waitForExistence(timeout: 5) && passport.exists, "both are in Home")
        XCTAssertTrue(waitUntil(5) { home.label.contains("2") }, "the lit pill counts its tasks: \(home.label)")
        shot("tasks-lists-list" + name)
        filter.tap()
        submenu("Sort By").tap()
        shot("tasks-lists-sort" + name)
        app.buttons["Due Date"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PUT" && $0.path.hasSuffix("/tasks/settings") && ($0.body?["sort"] as? String) == "due" }
        }, "Sort By reaches the gateway")

        // Hold the pill: Rename.
        home.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Delete List…"].firstMatch.waitForExistence(timeout: 5))
        shot("tasks-lists-pill-menu" + name)
        app.buttons["Rename…"].firstMatch.tap()
        sleep(1)
        nameList("House", action: "Save")   // the old name is selected: typing replaces it
        XCTAssertTrue(waitUntil(10) { sectionsPut().count == 3 }, "the rename is saved")
        let house = app.buttons["tasks.view.list.House"].firstMatch
        XCTAssertTrue(house.waitForExistence(timeout: 10))

        // Delete the list: its tasks are kept, and the page goes back to Today.
        house.press(forDuration: 0.8)
        app.buttons["Delete List…"].firstMatch.tap()
        XCTAssertTrue(app.alerts.staticTexts["Its 2 tasks are kept, in no list."].waitForExistence(timeout: 5), "it says the tasks are kept")
        shot("tasks-lists-delete" + name)
        app.alerts.buttons["Delete List"].tap()
        XCTAssertTrue(waitUntil(10) { sectionsPut().count == 4 }, "the delete is saved")
        XCTAssertTrue(waitUntil(10) { !house.exists }, "its pill goes")
        XCTAssertTrue(waitUntil(10) { today.exists && today.isSelected }, "back on Today")
        XCTAssertTrue(dentist.waitForExistence(timeout: 5), "its tasks are still on the list")
    }

    @MainActor private func nameList(_ name: String, action: String) {
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "asks for a name")
        field.typeText(name)
        app.alerts.buttons[action].tap()
    }

    /// A menu's submenu row, whose label carries its current choice ("Sort By, My Order").
    @MainActor private func submenu(_ title: String) -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(title) in the menu")
        return row
    }
}

extension PagesTests {
    /// Owner 2026-11-04: Tasks' title was "way too small compared to the other pages". Opened from More it's the same
    /// size as Artifacts opened from More, in every look.
    @MainActor func testTasks_TitleMatchesOtherPages() throws {
        let look = ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"]
        let name = look.map { "-" + $0 } ?? ""
        let arguments: [String] = switch look {
        case "dark": ["-hqn.appearance", "dark"]
        case "desktop": ["-hqn.appearance", "light", "-hqn.theme.desktopLook", "<true/>"]
        case "desktop-dark": ["-hqn.appearance", "dark", "-hqn.theme.desktopLook", "<true/>"]
        default: ["-hqn.appearance", "light"]
        }
        func title(_ page: String, _ words: String) -> CGRect {
            app = launchSignedIn(arguments + ["-HQPagesTab", "4", "-HQPagesMore", page])
            let text = app.navigationBars.staticTexts.matching(NSPredicate(format: "label ==[c] %@", words)).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 20), "\(words) title")
            shot("tasks-title-\(page)" + name)
            let frame = text.frame
            app.terminate()
            return frame
        }
        let tasks = title("tasks", "Tasks"), artifacts = title("artifacts", "Artifacts")
        XCTAssertEqual(tasks.height, artifacts.height, accuracy: 1, "the same title size")
    }
}
