// [goals] Goals step 2 (docs/goals.md "Step 2"): Today's Goals shelf (its cards and their Next, a tap opens the goal,
// the fold kept after a relaunch, All N ›, only on Today and only with All Bots or Me), the goal's mark on a task's row
// in the list's dot's place (Today, "Next in", Upcoming, Inbox, a list, Bots, a search; not on the goal's own page; the
// list's dot again for an achieved goal; none at all on an add-on that keeps no goals), a search that finds goals and a
// task by its goal's and its milestone's names, and step 1's loose ends: Update as a small sheet, a card dragged to a
// new place (kept after a relaunch), Delete Goal…, Let It Go and Make Active Again, a milestone's menu, the number's
// menu, the empty Goals view, the largest text size and the iPad.
//
// Written from what scripts/pages-fixture-gateway.py seeds in goals mode (seed_task_goals): active "1,000 public
// testers" (a number, next "Post the build notes to the forum"), "Run a 10K" (milestones, next "Easy 3 mile run") and
// "Family trip to the coast" (tasks only, next "Book the aquarium tickets"); paused "Learn conversational Spanish"
// ("Book a trial lesson"); achieved "Read 12 books this year". With lists on too, "Sign up for the race" is in Home and
// the achieved goal's "Return the library books" is in Home, due in two days; the paused goal has a bot's own task
// ("List three Spanish podcasts for beginners", under Bots).
// Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_GoalsShelf,…); HQN_TASKS_LOOK=dark for the dark screens.

import XCTest

extension PagesTests {
    // MARK: The shelf

    @MainActor func testTasks_GoalsShelf() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        let arguments = Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"]
        app = launchSignedIn(arguments)
        let name = Self.lookName
        let heading = goalShelfHeading()
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "Today leads with the Goals shelf")
        openGoalShelf()
        XCTAssertTrue(app.buttons["tasks.view.today"].firstMatch.isSelected, "the page still opens on Today")
        let testers = shelfCard("1,000 public testers"), tenK = shelfCard("Run a 10K"), trip = shelfCard("Family trip to the coast")
        XCTAssertTrue(testers.waitForExistence(timeout: 10) && tenK.exists && trip.exists, "a card for each active goal")
        XCTAssertFalse(shelfCard("Learn conversational Spanish").exists, "a paused goal has no card")
        XCTAssertFalse(shelfCard("Read 12 books this year").exists, "an achieved goal has no card")
        XCTAssertLessThan(testers.frame.minX, tenK.frame.minX, "your order")
        XCTAssertLessThan(tenK.frame.minX, trip.frame.minX, "your order")
        XCTAssertEqual(testers.frame.minY, tenK.frame.minY, accuracy: 1, "one row")
        // Next is real: the first open task under the goal, in your order.
        XCTAssertTrue(testers.label.contains("next: Post the build notes to the forum"), testers.label)
        XCTAssertTrue(tenK.label.contains("next: Easy 3 mile run"), tenK.label)
        XCTAssertTrue(trip.label.contains("next: Book the aquarium tickets"), trip.label)
        XCTAssertEqual(testers.value as? String, "34 percent", "read as the Goals view's card is")
        // The shelf stands over Today's groups.
        let todayGroup = app.descendants(matching: .any)["tasks.section.Today"].firstMatch
        XCTAssertTrue(todayGroup.waitForExistence(timeout: 5))
        XCTAssertLessThan(testers.frame.maxY, todayGroup.frame.minY, "the shelf leads Today")
        let all = app.buttons["goals.shelf.all"].firstMatch
        XCTAssertTrue(all.exists && all.value as? String == "3", "All 3 ›: \(all.value ?? "")")
        XCTAssertEqual(heading.value as? String, "3, shown")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("goals2-1-shelf" + name)
        // It scrolls sideways: the last card comes into view.
        app.descendants(matching: .any)["goals.shelf.cards"].firstMatch.swipeLeft()
        XCTAssertTrue(waitUntil(4) { trip.isHittable && trip.frame.maxX <= self.app.windows.firstMatch.frame.maxX + 1 }, "the row scrolls")
        shot("goals2-2-shelf-scrolled" + name)

        // A tap opens the goal.
        trip.tap()
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the goal's page")
        XCTAssertEqual(title.label, "Family trip to the coast")
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 8))

        // A tap on "Goals" folds it to that one line, which then says how many; it stays folded after a relaunch.
        let openTop = heading.frame.minY
        heading.tap()
        XCTAssertTrue(waitUntil(5) { heading.value as? String == "3, hidden" }, "folded: \(heading.value ?? "")")
        XCTAssertTrue(waitUntil(5) { !testers.exists }, "the cards go")
        XCTAssertTrue(heading.label.contains("Goals"))
        XCTAssertTrue(app.staticTexts["3"].exists || heading.frame.width > 0, "Goals 3")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(heading.frame.minY, openTop, accuracy: 1, "the heading stays where it was as the cards fold away")
        let todayFolded = app.descendants(matching: .any)["tasks.section.Today"].firstMatch
        XCTAssertLessThan(todayFolded.frame.minY - heading.frame.maxY, 40, "Today follows close under the folded line")
        shot("goals2-3-shelf-folded" + name)
        app.terminate()
        app = launchSignedIn(arguments)
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(5) { self.goalShelfHeading().value as? String == "3, hidden" }, "kept on this device")
        XCTAssertFalse(shelfCard("1,000 public testers").exists, "still folded after a relaunch")
        XCTAssertEqual(goalShelfHeading().frame.minY, openTop, accuracy: 1, "folded from the start, in the same place")
        goalShelfHeading().tap()
        XCTAssertTrue(shelfCard("1,000 public testers").waitForExistence(timeout: 5), "open again")
        XCTAssertEqual(goalShelfHeading().value as? String, "3, shown")

        // Only on Today: not on Upcoming, Inbox or a list.
        app.buttons["tasks.view.upcoming"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { !self.goalShelfHeading().exists }, "no shelf on Upcoming")
        tapView("inbox")
        XCTAssertTrue(waitUntil(5) { !self.goalShelfHeading().exists }, "no shelf on Inbox")
        app.buttons["tasks.view.today"].firstMatch.tap()
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 5))

        // The bots filter: it stays with All Bots and Me, and hides with one bot picked.
        let filter = app.buttons["pages.scope"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        app.buttons["Me"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { self.app.cells["task-row-Pick up dry cleaning"].exists }, "Me")
        XCTAssertTrue(goalShelfHeading().exists, "the shelf stays with Me")
        filter.tap()
        app.buttons["Research"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { !self.goalShelfHeading().exists }, "hidden with one bot picked")
        filter.tap()
        app.buttons["All Bots"].firstMatch.tap()
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 5), "back with All Bots")

        // All 3 › opens the Goals view.
        app.buttons["goals.shelf.all"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { self.app.buttons["tasks.view.goals"].firstMatch.isSelected }, "the Goals view")
        XCTAssertTrue(app.cells["goal-cell-1,000 public testers"].firstMatch.waitForExistence(timeout: 5))
    }

    /// The shelf's cards stack at the accessibility text sizes, two at most, then "All 3 ›".
    @MainActor func testTasks_GoalsShelfLargestText() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + Self.largestText + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 20))
        openGoalShelf()
        let testers = shelfCard("1,000 public testers"), tenK = shelfCard("Run a 10K")
        XCTAssertTrue(testers.waitForExistence(timeout: 10) && tenK.exists)
        XCTAssertFalse(shelfCard("Family trip to the coast").exists, "two at most")
        XCTAssertGreaterThanOrEqual(tenK.frame.minY, testers.frame.maxY - 1, "one under another")
        let all = app.buttons["goals.shelf.all"].firstMatch
        XCTAssertTrue(all.exists)
        XCTAssertGreaterThanOrEqual(all.frame.minY, tenK.frame.maxY - 1, "then All 3 ›")
        assertWhole([testers, tenK, all], in: "the stacked shelf")
        shot("goals2-4-shelf-largest" + Self.lookName)
    }

    // MARK: The goal's mark

    @MainActor func testTasks_GoalMarks() throws {
        try account.control("/__fixture/tasks-mode", ["lists": true, "goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 20))
        openGoalShelf()
        // Today: a goal's task carries the mark (said "for <goal>"); a task in a list keeps the list's dot ("in Home").
        let notes = app.cells["task-row-Post the build notes to the forum"].firstMatch
        XCTAssertTrue(scrollTo(notes), "a goal's task due today")
        XCTAssertTrue(rowLabel(notes).contains("for 1,000 public testers"), rowLabel(notes))
        XCTAssertTrue(markDrawn(in: notes), "the mark is drawn on the row")
        let run = app.cells["task-row-Easy 3 mile run"].firstMatch
        XCTAssertTrue(scrollTo(run) && rowLabel(run).contains("for Run a 10K"), rowLabel(run))
        let cleaning = app.cells["task-row-Pick up dry cleaning"].firstMatch
        XCTAssertTrue(scrollTo(cleaning))
        XCTAssertTrue(rowLabel(cleaning).contains("in Home") && !rowLabel(cleaning).contains(" for "), rowLabel(cleaning))
        XCTAssertFalse(markDrawn(in: cleaning), "no mark on a task with no goal")
        shot("goals2-5-marks-today" + name)
        // "Next in Home": the mark there too (the list's own dot is not drawn under its name).
        let signup = app.cells["task-row-Sign up for the race"].firstMatch
        XCTAssertTrue(scrollTo(signup), "the goal's task under Next in Home")
        XCTAssertTrue(rowLabel(signup).contains("for Run a 10K"), rowLabel(signup))
        XCTAssertTrue(markDrawn(in: signup))
        shot("goals2-6-marks-next-in" + name)

        // Upcoming: an achieved goal's task shows its list's dot again.
        app.buttons["tasks.view.upcoming"].firstMatch.tap()
        let library = app.cells["task-row-Return the library books"].firstMatch
        XCTAssertTrue(scrollTo(library), "the achieved goal's task, due in two days")
        XCTAssertTrue(rowLabel(library).contains("in Home"), rowLabel(library))
        XCTAssertFalse(rowLabel(library).contains("for Read 12 books"), "an achieved goal leaves no mark: \(rowLabel(library))")
        XCTAssertFalse(markDrawn(in: library))
        let shoes = app.cells["task-row-Buy real running shoes"].firstMatch
        XCTAssertTrue(scrollTo(shoes) && rowLabel(shoes).contains("for Run a 10K"), rowLabel(shoes))
        shot("goals2-7-marks-upcoming" + name)

        // Inbox: a paused goal's task keeps its mark.
        tapView("inbox")
        let lesson = app.cells["task-row-Book a trial lesson"].firstMatch
        XCTAssertTrue(scrollTo(lesson))
        XCTAssertTrue(rowLabel(lesson).contains("for Learn conversational Spanish"), rowLabel(lesson))
        XCTAssertTrue(markDrawn(in: lesson))

        // Inside the list: the mark, and no list dot.
        let home = app.buttons["tasks.view.list.Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        let rail = app.descendants(matching: .any)["tasks.views"].firstMatch
        let edge = app.windows.firstMatch.frame.maxX
        for _ in 0..<3 where home.frame.maxX > edge { rail.swipeLeft() }
        home.tap()
        let signupInList = app.cells["task-row-Sign up for the race"].firstMatch
        XCTAssertTrue(scrollTo(signupInList))
        XCTAssertTrue(rowLabel(signupInList).contains("for Run a 10K"), rowLabel(signupInList))
        XCTAssertTrue(markDrawn(in: signupInList))
        let libraryInList = app.cells["task-row-Return the library books"].firstMatch
        XCTAssertTrue(scrollTo(libraryInList) && !markDrawn(in: libraryInList), "an achieved goal's task, plain in its list")
        shot("goals2-8-marks-list" + name)

        // Bots: a bot's own task in a goal carries the mark there too (the fixture seeds one in the paused goal).
        let bots = app.buttons["tasks.view.bots"].firstMatch
        XCTAssertTrue(bots.waitForExistence(timeout: 5))
        for _ in 0..<3 where bots.frame.maxX > edge { rail.swipeLeft() }
        tapView("bots")
        let podcasts = app.cells["task-row-List three Spanish podcasts for beginners"].firstMatch
        XCTAssertTrue(scrollTo(podcasts), "the bot's task under Bots")
        XCTAssertTrue(rowLabel(podcasts).contains("for Learn conversational Spanish"), rowLabel(podcasts))
        XCTAssertTrue(markDrawn(in: podcasts))
        let invoices = app.cells["task-row-Summarize October invoices"].firstMatch
        XCTAssertTrue(scrollTo(invoices))
        XCTAssertFalse(rowLabel(invoices).contains(" for ") || markDrawn(in: invoices), "a bot's task in no goal: \(rowLabel(invoices))")
        shot("goals2-9-marks-bots" + name)

        // The goal's own page: no mark on its rows.
        let goalsPill = app.buttons["tasks.view.goals"].firstMatch
        for _ in 0..<3 where goalsPill.frame.minX < 0 { rail.swipeRight() }
        goalsPill.tap()
        let testersCard = app.cells["goal-cell-1,000 public testers"].firstMatch
        XCTAssertTrue(testersCard.waitForExistence(timeout: 8))
        testersCard.tap()
        let pageRow = app.descendants(matching: .any)["goal.task.Post the build notes to the forum"].firstMatch
        XCTAssertTrue(pageRow.waitForExistence(timeout: 10))
        XCTAssertFalse(pageRow.label.contains("for 1,000 public testers"), "no mark on the goal's own page: \(pageRow.label)")
        XCTAssertFalse(markDrawn(in: pageRow))
    }

    /// An add-on that keeps no goals (the stand-in gateway's plain mode): no shelf, no heading, no mark.
    @MainActor func testTasks_GoalMarksNeedGoals() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let cleaning = app.cells["task-row-Pick up dry cleaning"].firstMatch
        XCTAssertTrue(cleaning.waitForExistence(timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(goalShelfHeading().exists, "no shelf and no heading")
        // [goals-addon] The Goals pill stays, to offer the update (TasksGoalsUITests' testTasks_GoalsNeedTheAddOn).
        XCTAssertTrue(app.buttons["tasks.view.goals"].exists, "the Goals pill offers the update")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "tasks.goal-mark").count, 0, "no mark on any row")
        for row in app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-row-")).allElementsBoundByIndex.prefix(12) {
            XCTAssertFalse(rowLabel(row).contains(", for "), "no goal said on \(row.identifier): \(rowLabel(row))")
        }
        shot("goals2-10-plain-no-shelf" + Self.lookName)
    }

    // MARK: Search

    @MainActor func testTasks_GoalsSearch() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 20))
        // "launch": the goal whose why says it, then the tasks under its "Launch week" milestone.
        search("launch")
        let goals = app.descendants(matching: .any)["tasks.section.Goals"].firstMatch
        XCTAssertTrue(goals.waitForExistence(timeout: 8), "a Goals group first")
        let testers = app.cells["goal-cell-1,000 public testers"].firstMatch
        XCTAssertTrue(testers.waitForExistence(timeout: 5), "found by its why")
        let toDo = app.descendants(matching: .any)["tasks.section.To Do"].firstMatch
        XCTAssertTrue(toDo.waitForExistence(timeout: 5))
        XCTAssertLessThan(goals.frame.minY, toDo.frame.minY, "Goals, then To Do")
        XCTAssertTrue(app.cells["task-row-Reply to the three beta reviews"].firstMatch.exists, "a task found by its milestone's name")
        XCTAssertTrue(app.cells["task-row-Record the 60 second demo"].firstMatch.exists)
        XCTAssertFalse(goalShelfHeading().exists, "the shelf stays out of a search")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("goals2-11-search-launch" + name)

        // By a goal's name: the goal and every task under it.
        search("10k")
        XCTAssertTrue(app.cells["goal-cell-Run a 10K"].firstMatch.waitForExistence(timeout: 5), "the goal by its name")
        for task in ["Easy 3 mile run", "Buy real running shoes", "Sign up for the race"] {
            XCTAssertTrue(app.cells["task-row-\(task)"].firstMatch.waitForExistence(timeout: 5), "\(task), by its goal's name")
        }
        XCTAssertFalse(app.cells["goal-cell-1,000 public testers"].exists)
        shot("goals2-12-search-goal-name" + name)

        // Any status: a paused goal is found by its why.
        search("neighbours")
        XCTAssertTrue(app.cells["goal-cell-Learn conversational Spanish"].firstMatch.waitForExistence(timeout: 5), "a paused goal")
        // A found card opens its goal.
        app.cells["goal-cell-Learn conversational Spanish"].firstMatch.tap()
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Learn conversational Spanish")
    }

    // MARK: Loose ends from step 1

    /// Update is a small sheet over the keyboard, as tall as its content.
    @MainActor func testTasks_GoalUpdateSheet() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers"])
        let update = app.buttons["goal.update"].firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 20))
        update.tap()
        let field = app.textFields["goal.update.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the keys come up with it")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let sheet = app.descendants(matching: .any)["goal.update.sheet"].firstMatch
        XCTAssertTrue(sheet.exists)
        let screen = app.windows.firstMatch.frame
        // The sheet's view runs on under the keys; what shows is from its top to the keyboard's.
        let shown = keyboard.frame.minY - sheet.frame.minY
        XCTAssertGreaterThan(shown, 60, "it rides over the keyboard: \(sheet.frame) \(keyboard.frame)")
        XCTAssertLessThan(shown, 220, "as tall as its content, not a half page: \(sheet.frame) \(keyboard.frame)")
        XCTAssertGreaterThan(sheet.frame.minY, screen.height / 3, "the goal stays in view above it")
        XCTAssertLessThan(field.frame.maxY, keyboard.frame.minY, "the field is above the keys")
        XCTAssertTrue(app.staticTexts["goal.update.was"].firstMatch.exists, "what it was")
        XCTAssertTrue(app.descendants(matching: .any)["goal.title"].firstMatch.exists, "the goal stays behind it")
        shot("goals2-13-update-sheet" + Self.lookName)
        field.gmTypeOver("420")
        app.buttons["goal.update.save"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_testers") && ($0.body?["measure_now"] as? Double) == 420 }
        }, "Update saves the number")
        XCTAssertTrue(waitUntil(5) { !field.exists }, "and closes")
        XCTAssertTrue(waitUntil(8) { self.app.descendants(matching: .any)["goal.title"].firstMatch.value as? String == "42 percent" })
    }

    /// A card dragged to a new place among the active goals; the order survives a relaunch.
    @MainActor func testTasks_GoalsReorder() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        let arguments = Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesTasksView", "goals"]
        app = launchSignedIn(arguments)
        let testers = app.cells["goal-cell-1,000 public testers"].firstMatch, trip = app.cells["goal-cell-Family trip to the coast"].firstMatch
        XCTAssertTrue(testers.waitForExistence(timeout: 20) && trip.exists)
        XCTAssertLessThan(testers.frame.minY, trip.frame.minY)
        let from = trip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let to = testers.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        from.press(forDuration: 0.9, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_trip") && $0.body?["position"] != nil }
        }, "the new place is saved")
        XCTAssertTrue(waitUntil(5) { trip.frame.minY < testers.frame.minY }, "the trip leads now")
        shot("goals2-14-reordered" + Self.lookName)
        app.terminate()
        app = launchSignedIn(arguments)
        let tripAgain = app.cells["goal-cell-Family trip to the coast"].firstMatch, testersAgain = app.cells["goal-cell-1,000 public testers"].firstMatch
        XCTAssertTrue(tripAgain.waitForExistence(timeout: 20) && testersAgain.exists)
        XCTAssertLessThan(tripAgain.frame.minY, testersAgain.frame.minY, "the order survives a relaunch")
        // And the shelf follows it.
        app.buttons["tasks.view.today"].firstMatch.tap()
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 5))
        openGoalShelf()
        XCTAssertLessThan(shelfCard("Family trip to the coast").frame.minX, shelfCard("1,000 public testers").frame.minX, "the shelf in your order")
    }

    /// Delete Goal… asks first; its tasks stay in Tasks, with no goal row.
    @MainActor func testTasks_GoalDelete() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesTasksView", "goals"])
        let card = app.cells["goal-cell-Run a 10K"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.press(forDuration: 0.9)
        let delete = app.buttons["Delete Goal…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["Delete Goal"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "it asks first")
        XCTAssertTrue(app.staticTexts["Its tasks stay on your list, with no goal."].exists)
        shot("goals2-15-delete-asks" + Self.lookName)
        confirm.tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.method == "DELETE" && $0.path.hasSuffix("/goals/g_10k") } }, "deleted")
        XCTAssertTrue(waitUntil(5) { !card.exists }, "the card goes")
        // Its tasks are still in Tasks, with no goal.
        app.buttons["tasks.view.today"].firstMatch.tap()
        let run = app.cells["task-row-Easy 3 mile run"].firstMatch
        XCTAssertTrue(scrollTo(run), "its task is still in Tasks")
        XCTAssertFalse(rowLabel(run).contains(" for "), "and carries no mark: \(rowLabel(run))")
        run.tap()
        let page = app.descendants(matching: .any)["task.title"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10) || app.descendants(matching: .any)["task.who"].firstMatch.waitForExistence(timeout: 5), "its page")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(app.descendants(matching: .any)["task.goal"].firstMatch.exists, "no goal row")
        shot("goals2-16-deleted-task-page" + Self.lookName)
    }

    /// Let It Go keeps the goal under Let Go; Make Active Again brings it back.
    @MainActor func testTasks_GoalLetGoAndBack() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesTasksView", "goals"])
        let card = app.cells["goal-cell-Family trip to the coast"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.press(forDuration: 0.9)
        let letGo = app.buttons["Let It Go"].firstMatch
        XCTAssertTrue(letGo.waitForExistence(timeout: 5))
        letGo.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_trip") && $0.body?["status"] as? String == "let_go" }
        })
        let fold = app.buttons["goals.fold.letGo"].firstMatch
        for _ in 0..<4 where !fold.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(fold.waitForExistence(timeout: 5), "under Let Go, folded")
        XCTAssertFalse(card.exists, "folded away")
        fold.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "kept under Let Go")
        let cardWords = app.descendants(matching: .any)["goal-card-Family trip to the coast"].firstMatch
        XCTAssertTrue(cardWords.label.contains("Let go"), cardWords.label)
        shot("goals2-17-let-go" + Self.lookName)
        // Its tasks lose the mark; the pill counts two active goals.
        XCTAssertTrue((app.buttons["tasks.view.goals"].firstMatch.label + " " + (app.buttons["tasks.view.goals"].firstMatch.value as? String ?? "")).contains("2"))
        card.press(forDuration: 0.9)
        let again = app.buttons["Make Active Again"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_trip") && $0.body?["status"] as? String == "active" }
        })
        for _ in 0..<4 where !app.cells["goal-cell-1,000 public testers"].isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(waitUntil(5) { card.exists && !fold.exists }, "active again, and Let Go is gone with nothing in it")
        XCTAssertTrue(waitUntil(5) { !cardWords.label.contains("Let go") }, cardWords.label)
    }

    /// A milestone's menu: Rename…, Set Date…, Move Up, Delete Milestone… (its tasks stay in the goal).
    @MainActor func testTasks_GoalMilestoneMenu() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Run a 10K"])
        let fiveMiles = app.descendants(matching: .any)["goal.milestone.Run 5 miles"].firstMatch
        XCTAssertTrue(fiveMiles.waitForExistence(timeout: 20))
        let patches = { self.requests().filter { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_10k") && $0.body?["milestones"] != nil } }
        func milestones(_ request: Request?) -> [[String: Any]] { request?.body?["milestones"] as? [[String: Any]] ?? [] }

        // Rename…
        fiveMiles.press(forDuration: 0.9)
        let rename = app.buttons["Rename…"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.buttons["Clear text"].firstMatch.exists ? field.buttons["Clear text"].firstMatch.tap() : field.gmTypeOver("")
        field.typeText("Run 6 miles")
        app.alerts.buttons["Rename"].firstMatch.exists ? app.alerts.buttons["Rename"].firstMatch.tap() : app.alerts.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(waitUntil(10) { milestones(patches().last).contains { $0["title"] as? String == "Run 6 miles" } }, "renamed")
        let sixMiles = app.descendants(matching: .any)["goal.milestone.Run 6 miles"].firstMatch
        XCTAssertTrue(sixMiles.waitForExistence(timeout: 8))

        // Set Date…: the milestone's own date sheet.
        sixMiles.press(forDuration: 0.9)
        let setDate = app.buttons["Set Date…"].firstMatch
        XCTAssertTrue(setDate.waitForExistence(timeout: 5))
        setDate.tap()
        XCTAssertTrue(app.navigationBars["Milestone Date"].waitForExistence(timeout: 5), "the milestone's date sheet")
        let before = patches().count
        app.buttons["task.due.set"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { patches().count > before }, "the date is saved")
        XCTAssertTrue(milestones(patches().last).contains { $0["title"] as? String == "Run 6 miles" && $0["due"] is String })

        // Move Up: it goes before "Run a 5K".
        XCTAssertTrue(sixMiles.waitForExistence(timeout: 5))
        sixMiles.press(forDuration: 0.9)
        let up = app.buttons["Move Up"].firstMatch
        XCTAssertTrue(up.waitForExistence(timeout: 5))
        up.tap()
        XCTAssertTrue(waitUntil(10) {
            let titles = milestones(patches().last).compactMap { $0["title"] as? String }
            return titles.firstIndex(of: "Run 6 miles") ?? 9 < titles.firstIndex(of: "Run a 5K") ?? 0
        }, "moved up")
        let fiveK = app.descendants(matching: .any)["goal.milestone.Run a 5K"].firstMatch
        XCTAssertTrue(waitUntil(5) { sixMiles.frame.minY < fiveK.frame.minY }, "drawn above it")
        shot("goals2-18-milestone-moved" + Self.lookName)

        // Delete Milestone…: asks, and its tasks stay in the goal under No Milestone.
        fiveK.press(forDuration: 0.9)
        let delete = app.buttons["Delete Milestone…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.alerts.buttons["Delete Milestone"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "it asks first")
        confirm.tap()
        XCTAssertTrue(waitUntil(10) { !milestones(patches().last).contains { $0["title"] as? String == "Run a 5K" } }, "removed")
        XCTAssertTrue(waitUntil(8) { !fiveK.exists })
        let loose = app.descendants(matching: .any)["goal.loose"].firstMatch
        XCTAssertTrue(loose.waitForExistence(timeout: 8), "No Milestone holds its tasks now")
        let run = app.descendants(matching: .any)["goal.task.Easy 3 mile run"].firstMatch
        for _ in 0..<3 where !run.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(run.waitForExistence(timeout: 5), "its task is still in the goal")
        XCTAssertGreaterThan(run.frame.minY, loose.frame.minY, "under No Milestone")
        shot("goals2-19-milestone-deleted" + Self.lookName)
    }

    /// The number's menu: Edit Number… (unit, from, to) and Remove Number (asks first).
    @MainActor func testTasks_GoalNumberMenu() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers"])
        let number = app.buttons["goal.number"].firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 20))
        XCTAssertTrue(number.label.contains("340 of 1,000 testers"), number.label)
        number.tap()
        let edit = app.buttons["Edit Number…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the number's menu")
        XCTAssertTrue(app.buttons["Remove Number"].firstMatch.exists && app.buttons["Update…"].firstMatch.exists)
        edit.tap()
        let target = app.textFields["goal.number.target"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.gmTypeOver("2000")
        app.buttons["goal.number.save"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_testers")
                && (($0.body?["measure"] as? [String: Any])?["target"] as? Double) == 2000 }
        }, "the new target is saved: \(requests().filter { $0.method == "PATCH" }.map { "\($0.path) \($0.body ?? [:])" })")
        XCTAssertTrue(waitUntil(8) { number.label.contains("340 of 2,000 testers") }, number.label)
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(waitUntil(5) { title.value as? String == "17 percent" }, "the ring follows: \(title.value ?? "")")
        shot("goals2-20-number-edited" + Self.lookName)

        number.tap()
        app.buttons["Remove Number"].firstMatch.tap()
        let confirm = app.alerts.buttons["Remove Number"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "it asks first")
        confirm.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_testers") && $0.body?.keys.contains("measure") == true
                && $0.body?["measure"] is NSNull }
        }, "the number is removed")
        XCTAssertTrue(waitUntil(8) { !number.exists }, "no number row")
        XCTAssertTrue(waitUntil(5) { title.value as? String == "40 percent" }, "the ring follows the milestones: \(title.value ?? "")")
        XCTAssertTrue(app.descendants(matching: .any)["goal.number.add"].firstMatch.waitForExistence(timeout: 5),
                      "+ Number waits among the quiet words")
    }

    /// No goals at all: what a goal is, in two lines, with New Goal; no shelf on Today.
    @MainActor func testTasks_GoalsEmpty() throws {
        try account.control("/__fixture/tasks-mode", ["goals": "empty"])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let pill = app.buttons["tasks.view.goals"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "the add-on keeps goals: the pill is there")
        XCTAssertTrue(app.cells["task-row-Pick up dry cleaning"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(goalShelfHeading().exists, "no active goal: no shelf, no heading")
        pill.tap()
        let words = app.staticTexts["goals.empty"].firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 5), "what a goal is")
        XCTAssertTrue(words.label.hasPrefix("A goal is something you want to finish"), words.label)
        let new = app.buttons["goals.empty.new"].firstMatch
        XCTAssertTrue(new.exists, "with New Goal")
        assertWhole([words, new], in: "the empty Goals view")
        shot("goals2-21-empty" + Self.lookName)
        new.tap()
        XCTAssertTrue(app.descendants(matching: .any)["goals.new.title"].firstMatch.waitForExistence(timeout: 8), "New Goal opens")
    }

    /// The Goals view and a goal's page at the largest accessibility text size: nothing cut to nothing, nothing
    /// overlapping. Also run on the iPad (`testTasks_GoalsOnIPad` names the iPad's shots).
    @MainActor func testTasks_GoalsLargestText() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + Self.largestText + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesTasksView", "goals"])
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        let testers = app.cells["goal-cell-1,000 public testers"].firstMatch
        XCTAssertTrue(testers.waitForExistence(timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let cards = ["1,000 public testers", "Run a 10K", "Family trip to the coast"].map { app.cells["goal-cell-\($0)"].firstMatch }.filter(\.exists)
        assertWhole(cards.filter(\.isHittable), in: "the Goals view")
        shot("goals2-22-view-largest" + device + Self.lookName)
        for _ in 0..<3 { app.swipeUp(velocity: .slow) }
        let shownCards = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "goal-cell-")).allElementsBoundByIndex.filter(\.isHittable)
        assertWhole(shownCards, in: "the Goals view, scrolled")
        shot("goals2-23-view-largest-bottom" + device + Self.lookName)
        for _ in 0..<4 where !testers.isHittable { app.swipeDown(velocity: .slow) }
        testers.tap()
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let rows = ["goal.title", "goal.number", "goal.date", "goal.why", "goal.bar"].map { app.descendants(matching: .any)[$0].firstMatch }
            .filter { $0.exists && $0.isHittable }
        XCTAssertGreaterThanOrEqual(rows.count, 2, "the page's rows are on screen")
        assertWhole(rows, in: "the goal's page")
        // The date's words are whole, under each other, not "By W…  48 da…".
        let date = app.descendants(matching: .any)["goal.date"].firstMatch
        if date.exists { XCTAssertGreaterThan(date.frame.height, 80, "the date and what is left stand one under the other: \(date.frame)") }
        shot("goals2-24-page-largest" + device + Self.lookName)
        for _ in 0..<2 { app.swipeUp(velocity: .slow) }
        let lower = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "goal.milestone.", "goal.task."))
            .allElementsBoundByIndex.filter { $0.exists && $0.isHittable && !$0.identifier.hasPrefix("goal.milestone.box.") }
        assertWhole(lower, in: "the goal's milestones")
        // Not squeezed to a letter a line: a milestone's name and date fit in a few lines at the largest size.
        let screen = app.windows.firstMatch.frame
        for row in lower where row.identifier.hasPrefix("goal.milestone.") {
            XCTAssertLessThan(row.frame.height, screen.height * 0.4, "\(row.identifier) runs to \(row.frame.height) pt")
            XCTAssertGreaterThan(row.frame.width, screen.width * 0.6, "\(row.identifier) keeps the row's width")
        }
        shot("goals2-25-page-largest-milestones" + device + Self.lookName)
    }

    /// The iPad: the shelf, the Goals view and a goal's page fit its window (run on the "HQ goals iPad" simulator).
    @MainActor func testTasks_GoalsOnIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Runs on the iPad simulator.") }
        try account.control("/__fixture/tasks-mode", ["lists": true, "goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 20))
        openGoalShelf()
        let cards = ["1,000 public testers", "Run a 10K", "Family trip to the coast"].map(shelfCard)
        XCTAssertTrue(cards[0].waitForExistence(timeout: 10))
        // A card scrolled past the pane's edge has no hit point, and `isHittable` fails the test on it rather than
        // saying false: judge by the frame. The cards in view are whole and apart; the first one is wholly in view.
        let inView = cards.filter { card in
            let frame = card.frame
            return card.exists && !frame.isInfinite && !frame.isNull && frame.intersection(window).width > 24
        }
        XCTAssertGreaterThanOrEqual(inView.count, 2, "two cards side by side in the iPad's pane: \(cards.map { "\($0.exists) \($0.frame)" }) in \(window)")
        assertWhole(inView, in: "the iPad's shelf")
        XCTAssertTrue(window.contains(cards[0].frame), "the first card is whole: \(cards[0].frame) in \(window)")
        let notes = app.cells["task-row-Post the build notes to the forum"].firstMatch
        XCTAssertTrue(scrollTo(notes) && markDrawn(in: notes), "the mark on the iPad's rows")
        for _ in 0..<3 { app.swipeDown(velocity: .slow) }
        shot("goals2-26-ipad-shelf" + Self.lookName)
        app.buttons["tasks.view.goals"].firstMatch.tap()
        let testers = app.cells["goal-cell-1,000 public testers"].firstMatch
        XCTAssertTrue(testers.waitForExistence(timeout: 8))
        let viewCards = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "goal-cell-")).allElementsBoundByIndex.filter(\.isHittable)
        assertWhole(viewCards, in: "the iPad's Goals view")
        shot("goals2-27-ipad-goals" + Self.lookName)
        testers.tap()
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let rows = ["goal.title", "goal.number", "goal.date", "goal.why", "goal.bar", "goal.milestone.Launch week"]
            .map { app.descendants(matching: .any)[$0].firstMatch }.filter { $0.exists && $0.isHittable }
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        assertWhole(rows, in: "the iPad's goal page")
        shot("goals2-28-ipad-page" + Self.lookName)
        app.buttons["goal.update"].firstMatch.tap()
        XCTAssertTrue(app.textFields["goal.update.field"].firstMatch.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let sheet = app.descendants(matching: .any)["goal.update.sheet"].firstMatch
        let keys = app.keyboards.firstMatch
        let shown = keys.exists && keys.frame.minY < sheet.frame.maxY ? keys.frame.minY - sheet.frame.minY : sheet.frame.height
        XCTAssertLessThan(shown, 240, "Update stays small on the iPad: \(sheet.frame), keys \(keys.exists ? keys.frame : .zero)")
        shot("goals2-29-ipad-update" + Self.lookName)
    }
}

// MARK: - Helpers

extension PagesTests {
    static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor func goalShelfHeading() -> XCUIElement { app.buttons["goals.shelf.heading"].firstMatch }

    /// Opens a Tasks view (`tasks.view.<key>`) from the Grouped Overview (stepping back to Tasks Overview first if currently drilled into another view).
    @MainActor func tapView(_ key: String) {
        let button = app.buttons["tasks.view.\(key)"].firstMatch
        if !button.exists {
            let back = app.navigationBars.buttons["Tasks"].firstMatch
            if back.exists && back.isHittable { back.tap() }
        }
        _ = button.waitForExistence(timeout: 20)
        for _ in 0..<3 where button.exists && !button.isHittable {
            app.collectionViews["tasks.list"].firstMatch.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        button.tap()
    }

    @MainActor func backToTasksOverview() {
        let smart = app.descendants(matching: .any)["tasks.overview.smart"].firstMatch
        guard !smart.exists else { return }
        let back = app.navigationBars.buttons["Tasks"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
        _ = smart.waitForExistence(timeout: 10)
    }

    @MainActor func shelfCard(_ title: String) -> XCUIElement { app.buttons["goal-shelf-\(title)"].firstMatch }

    /// The fold is kept on the device across runs: open it when an earlier run left it folded.
    @MainActor func openGoalShelf() {
        let heading = goalShelfHeading()
        guard heading.waitForExistence(timeout: 5) else { return }
        if (heading.value as? String)?.hasSuffix("hidden") == true { heading.tap() }
        _ = waitUntil(5) { (heading.value as? String)?.hasSuffix("shown") == true }
    }

    @MainActor func search(_ words: String) {
        let field = app.searchFields.firstMatch
        if !field.exists {
            let button = app.navigationBars.buttons["Search"].firstMatch
            if button.exists { button.tap() } else { app.buttons["Search"].firstMatch.tap() }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the search field")
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != "Search Tasks" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(words)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    /// The row's spoken words (the cell holds one element, the row).
    @MainActor func rowLabel(_ cell: XCUIElement) -> String {
        guard cell.exists else { return "" }
        let inner = cell.descendants(matching: .any).matching(NSPredicate(format: "label != ''")).firstMatch
        return [cell.label, inner.exists ? inner.label : ""].joined(separator: " | ")
    }

    /// The goal's mark drawn in a row (its image, by identifier).
    @MainActor func markDrawn(in element: XCUIElement) -> Bool {
        element.descendants(matching: .any).matching(identifier: "tasks.goal-mark").firstMatch.exists
    }

    /// Scrolls the list until the element is on screen, over the tab bar.
    @MainActor @discardableResult func scrollTo(_ element: XCUIElement) -> Bool {
        let bar = app.tabBars.firstMatch
        for _ in 0..<8 {
            if element.exists && element.isHittable && (!bar.exists || element.frame.maxY <= bar.frame.minY) { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    /// Nothing cut to nothing and nothing overlapping: each element has a real size, and no two overlap.
    @MainActor func assertWhole(_ elements: [XCUIElement], in place: String, file: StaticString = #filePath, line: UInt = #line) {
        let frames = elements.map { ($0.identifier, $0.frame) }
        for (id, frame) in frames {
            XCTAssertGreaterThan(frame.width, 24, "\(place): \(id) has a width (\(frame))", file: file, line: line)
            XCTAssertGreaterThan(frame.height, 16, "\(place): \(id) has a height (\(frame))", file: file, line: line)
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                let overlap = frames[i].1.intersection(frames[j].1)
                XCTAssertTrue(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                              "\(place): \(frames[i].0) and \(frames[j].0) overlap (\(frames[i].1) / \(frames[j].1))", file: file, line: line)
            }
        }
    }
}

private extension XCUIElement {
    /// Deletes what the field holds, then types.
    func gmTypeOver(_ text: String) {
        // At the field's end, so the deletes take what it holds (a right-aligned field's middle is before its words).
        let end = coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        end.tap()
        // A sheet still rising can drop the first tap: tap again until the field holds the keys.
        for _ in 0..<4 where (value(forKey: "hasKeyboardFocus") as? Bool) != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            end.tap()
        }
        if let current = value as? String, !current.isEmpty, current != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        if !text.isEmpty { typeText(text) }
    }
}
