// [tasks] Owner 2026-11-04: "we also need a way to organize tasks on the page. Like, can we create sections? And an
// easy way to move the tasks amongst the sections." Filter › Group By › My Sections, New Section, Move To from a held
// row, a drag onto another section, Select for several at once, and a section's own menu (Rename, Move, Delete) and
// fold. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_MySections); every look:
// TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.

import XCTest

extension PagesTests {
    @MainActor func testTasks_MySections() throws {
        let look = ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"]
        let name = look.map { "-" + $0 } ?? ""
        let arguments: [String] = switch look {
        case "dark": ["-hqn.appearance", "dark"]
        case "desktop": ["-hqn.appearance", "light", "-hqn.theme.desktopLook", "<true/>"]
        case "desktop-dark": ["-hqn.appearance", "dark", "-hqn.theme.desktopLook", "<true/>"]
        default: ["-hqn.appearance", "light"]
        }
        app = launchSignedIn(arguments + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let filter = app.buttons["tasks.more"].firstMatch   // [bot-pills] the page's commands; the bots are pills under the bar
        XCTAssertTrue(filter.waitForExistence(timeout: 20))
        XCTAssertTrue(app.cells["task-row-Call the dentist"].firstMatch.waitForExistence(timeout: 15))

        // Group By › My Sections: saved on the gateway, so the Mac shows the same.
        filter.tap()
        submenu("Group By").tap()
        shot("tasks-sections-group-by" + name)
        app.buttons["My Sections"].firstMatch.tap()
        let putSettings = { (key: String, value: String) in
            self.requests().contains { $0.method == "PUT" && $0.path.hasSuffix("/tasks/settings") && ($0.body?[key] as? String) == value }
        }
        XCTAssertTrue(waitUntil(10) { putSettings("group", "sections") }, "Group By reaches the gateway")
        let newSection = app.cells["tasks.new-section"].firstMatch
        for _ in 0..<8 where !(newSection.exists && newSection.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(newSection.exists, "New Section under the list")
        shot("tasks-sections-start" + name)

        // Two sections: one from the row, one from the Filter menu.
        newSection.tap()
        addSectionNamed("Home")
        let sectionsPut = { self.requests().filter { $0.method == "PUT" && $0.path.hasSuffix("/tasks/sections") } }
        XCTAssertTrue(waitUntil(10) { sectionsPut().count == 1 }, "the section is saved")
        let home = app.descendants(matching: .any)["tasks.user-section.Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        for _ in 0..<8 where !filter.isHittable { app.swipeDown(velocity: .fast) }
        filter.tap()
        app.buttons["New Section…"].firstMatch.tap()
        addSectionNamed("Errands")
        XCTAssertTrue(waitUntil(10) { sectionsPut().count == 2 })
        XCTAssertTrue(app.descendants(matching: .any)["tasks.user-section.Errands"].firstMatch.waitForExistence(timeout: 10))

        // Hold a row › Move To › Errands.
        let patched = { (id: String) in
            self.requests().filter { $0.method == "PATCH" && $0.path.hasSuffix("/tasks/\(id)") && $0.body?.keys.contains("section") == true }
        }
        let cleaning = app.cells["task-row-Pick up dry cleaning"].firstMatch
        for _ in 0..<8 where !(cleaning.exists && cleaning.isHittable) { app.swipeUp(velocity: .slow) }
        cleaning.press(forDuration: 0.8)
        submenu("Move To").tap()
        shot("tasks-sections-move-to" + name)
        app.buttons["Errands"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { !patched("t_cleaning").isEmpty }, "Move To files it")
        let errands = app.descendants(matching: .any)["tasks.user-section.Errands"].firstMatch
        XCTAssertTrue(waitUntil(5) { cleaning.frame.minY > errands.frame.minY }, "it sits under Errands")

        // Drag a task onto Home (empty: the drop row).
        let porch = app.cells["task-row-Pick a spot for Friday’s team lunch"].firstMatch
        let homeDrop = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tasks.section-empty.")).firstMatch
        for _ in 0..<8 where !(homeDrop.exists && homeDrop.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(porch.isHittable, "the last task sits just above Home")
        porch.press(forDuration: 1.0, thenDragTo: homeDrop, withVelocity: .slow, thenHoldForDuration: 0.6)
        shot("tasks-sections-dragged" + name)
        XCTAssertTrue(waitUntil(10) { !patched("t_lunch").isEmpty }, "a drag files it too")
        XCTAssertTrue(waitUntil(5) { porch.frame.minY > home.frame.minY && porch.frame.minY < errands.frame.minY }, "it sits under Home")
        shot("tasks-sections-filed" + name)

        // Select two, Move To › Home.
        for _ in 0..<8 where !filter.isHittable { app.swipeDown(velocity: .fast) }
        filter.tap()
        app.buttons["Select Tasks"].firstMatch.tap()
        let dentist = app.cells["task-row-Call the dentist"].firstMatch
        let gift = app.cells["task-row-Mom’s birthday gift"].firstMatch
        XCTAssertTrue(dentist.waitForExistence(timeout: 5))
        dentist.tap()
        for _ in 0..<6 where !(gift.exists && gift.isHittable) { app.swipeUp(velocity: .slow) }
        gift.tap()
        shot("tasks-sections-select" + name)
        XCTAssertTrue(waitUntil(5) { dentist.isSelected && gift.isSelected }, "two picked")
        app.buttons["tasks.select.move"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 5))
        shot("tasks-sections-select-move" + name)
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { !patched("t_dentist").isEmpty && !patched("t_gift").isEmpty }, "both moved")
        XCTAssertTrue(waitUntil(5) { !app.buttons["tasks.select.done"].exists }, "Select ends after the move")

        // Home's menu: Rename.
        for _ in 0..<8 where !(home.exists && home.isHittable) { app.swipeDown(velocity: .slow) }
        let homeMenu = app.buttons["tasks.section-menu.Home"].firstMatch
        XCTAssertTrue(homeMenu.waitForExistence(timeout: 5))
        homeMenu.tap()
        XCTAssertTrue(app.buttons["Delete Section…"].firstMatch.waitForExistence(timeout: 5))
        shot("tasks-sections-header-menu" + name)
        app.buttons["Rename…"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        sleep(1)
        field.typeText("House")   // the old name is selected: typing replaces it
        shot("tasks-sections-rename" + name)
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(waitUntil(10) { sectionsPut().count == 3 }, "the rename is saved")
        let house = app.descendants(matching: .any)["tasks.user-section.House"].firstMatch
        XCTAssertTrue(house.waitForExistence(timeout: 10))
        // Clear of the floating tab bar: a tap on a header under it lands on a tab (Bots) instead.
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<4 where tabBar.exists && house.frame.maxY > tabBar.frame.minY - 12 { app.swipeUp(velocity: .slow) }

        // Fold it: its tasks hide.
        house.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)).tap()
        XCTAssertTrue(waitUntil(5) { !porch.exists }, "folded")
        shot("tasks-sections-folded" + name)
        house.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)).tap()
        XCTAssertTrue(porch.waitForExistence(timeout: 5), "open again")

        // Sort By.
        for _ in 0..<8 where !filter.isHittable { app.swipeDown(velocity: .fast) }
        filter.tap()
        submenu("Sort By").tap()
        shot("tasks-sections-sort" + name)
        app.buttons["Due Date"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { putSettings("sort", "due") }, "Sort By reaches the gateway")
    }

    @MainActor private func addSectionNamed(_ name: String) {
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "asks for a name")
        field.typeText(name)
        app.alerts.buttons["Add"].tap()
    }

    /// A menu's submenu row, whose label carries its current choice ("Group By, Smart").
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
