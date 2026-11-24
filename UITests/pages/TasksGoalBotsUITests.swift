// [goals steps 3-5] Bots on a goal (docs/goals.md "Step 3/4/5 in the app"; boards 3, 4 and 5; hermes-hq-push 0.9.66):
// Edit Goal's team rows, New Goal's Plan With a bot (the goal's chat, the hidden ask, the plan's card), tasks offered by
// a bot that isn't on the goal, the weekly check-in on Today and its push, the lead's looks-done, the stall question
// (with no bot, on 0.9.66 and on 0.9.65), the number read by a bot, where it stands and the Goal Page, and the add-on's
// word on all of it (0.9.65 draws exactly steps 1 and 2; no goals is exactly today's Tasks).
//
// Written from what scripts/pages-fixture-gateway.py seeds in goal-bots mode (tasks-mode {"goal_bots": true},
// seed_goal_bots): "1,000 public testers" led by Hermes with Research helping, its number read by Hermes from
// TestFlight, where it stands, a Goal Page, and a waiting check-in (three tasks); "Grow our own tomatoes" led by Hermes
// with a plan waiting in its chat; two tasks offered by Finance (not on the goal) for the testers goal; "Family trip to
// the coast" led by Hermes, which says it looks done; and "Learn three songs on guitar", stalled 16 days, no bot.
// Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_GoalEditTeam,…); HQN_TASKS_LOOK=dark for the dark screens.

import XCTest

extension PagesTests {
    private static let goalRoute = "/api/plugins/hermes-hq-push/goals"
    private static let offerRoute = "/api/plugins/hermes-hq-push/tasks/offers/"

    // MARK: Edit Goal's team (board 5's left phone)

    @MainActor func testTasks_GoalEditTeam() throws {
        try goalMode(["goal_bots": true])
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenGoal", "Run a 10K", "-HQPagesGoalSheet", "team"])
        let name = Self.lookName
        // [goals step 6] One Bots row (the team sheet) in place of Led By and Helpers.
        let bots = app.buttons["goal.edit.bots"].firstMatch
        XCTAssertTrue(bots.waitForExistence(timeout: 20), "Edit Goal shows its bots")
        XCTAssertEqual(bots.label, "Bots, Just Me")
        XCTAssertFalse(app.buttons["goal.edit.lead"].exists || app.buttons["goal.edit.helpers"].exists, "no Led By or Helpers rows")
        XCTAssertFalse(app.buttons["goal.edit.review"].exists, "no check-in without a lead")
        XCTAssertTrue(app.buttons["goal.edit.adds"].exists && app.switches["goal.edit.known"].exists)
        shot("goals3-1-team-empty" + name)

        // Research leads (the first ticked). The check-in comes with it (Mondays 8 AM), and it is saved at once.
        var cues = goalCues()
        bots.tap()
        let research = app.buttons["goal.team.row.research"].firstMatch
        XCTAssertTrue(research.waitForExistence(timeout: 5), "the bots to pick")
        research.tap()
        XCTAssertTrue(waitUntil(8) { research.label == "Research, on this goal, leads" }, research.label)
        XCTAssertGreaterThan(goalCues(), cues, "picking a lead is felt")
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains { $0.body?["lead"] as? String == "research" } }, "PATCH lead")

        // Finance helps (the second ticked; never the lead).
        let finance = app.buttons["goal.team.row.finance"].firstMatch
        finance.tap()
        XCTAssertTrue(waitUntil(8) { finance.label == "Finance, on this goal" }, finance.label)
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains { ($0.body?["helpers"] as? [String]) == ["finance"] } }, "PATCH helpers")
        app.buttons["goal.team.done"].tap()
        XCTAssertTrue(waitUntil(8) { bots.label == "Bots, Led by Research, with Finance" }, bots.label)
        let review = app.buttons["goal.edit.review"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 8), "the check-in row with a lead")
        XCTAssertTrue(waitUntil(8) { review.label == "Check-in, Mondays 8 AM" }, "the add-on's first slot: \(review.label)")

        // The check-in's slot: Fridays 5 PM.
        review.tap()
        let fridays = app.buttons["Fridays"].firstMatch
        XCTAssertTrue(fridays.waitForExistence(timeout: 5), "the days")
        fridays.tap()
        let five = app.buttons["5 PM"].firstMatch
        XCTAssertTrue(five.waitForExistence(timeout: 5), "the times")
        five.tap()
        XCTAssertTrue(waitUntil(8) { review.label == "Check-in, Fridays 5 PM" }, review.label)
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains {
            ($0.body?["review"] as? [String: Any])?["day"] as? Int == 4 && ($0.body?["review"] as? [String: Any])?["time"] as? String == "17:00" } }, "PATCH review")

        // New Tasks: Add Without Asking; Tell My Other Bots off.
        app.buttons["goal.edit.adds"].firstMatch.tap()
        app.buttons["Add Without Asking"].firstMatch.tap()
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains { $0.body?["adds"] as? String == "auto" } }, "PATCH adds")
        cues = goalCues()
        let known = app.switches["goal.edit.known"].firstMatch
        if !known.isHittable { app.swipeUp(velocity: .slow) }
        // A Form switch toggles from its knob, not the middle of its label.
        known.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains { $0.body?["known_to_all"] as? Bool == false } }, "PATCH known_to_all false")
        XCTAssertGreaterThan(goalCues(), cues, "the switch is felt")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("goals3-2-team-set" + name)

        // Done: the page says who, and the goal's card carries the faces (a face: the bot is on the goal).
        app.buttons["goal.edit-done"].firstMatch.exists ? app.buttons["goal.edit-done"].firstMatch.tap() : app.swipeDown(velocity: .fast)
        let who = app.descendants(matching: .any)["goal.who"].firstMatch
        XCTAssertTrue(who.waitForExistence(timeout: 10), "the who row")
        XCTAssertTrue(who.label.hasPrefix("Led by Research, with Finance"), who.label)
        XCTAssertTrue(who.label.contains("check-in Fridays 5 PM"), who.label)
        shot("goals3-3-page-who" + name)
        app.buttons["sheet.close"].firstMatch.tap()
        let card = app.buttons["goal-card-Run a 10K"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the goal's card")
        XCTAssertTrue(waitUntil(8) { card.label.contains("Led by Research, with Finance") }, card.label)

        // [goals step 6] Unticking the lead hands it on (Finance leads); unticking Finance leaves no lead.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Run a 10K", "-HQPagesGoalSheet", "team"])
        let again = app.buttons["goal.edit.bots"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        again.tap()
        let lead = app.buttons["goal.team.row.research"].firstMatch
        XCTAssertTrue(lead.waitForExistence(timeout: 8))
        lead.tap()
        let next = app.buttons["goal.team.row.finance"].firstMatch
        XCTAssertTrue(waitUntil(8) { next.label == "Finance, on this goal, leads" }, next.label)
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains { $0.body?["lead"] as? String == "finance" } }, "PATCH lead finance")
        next.tap()
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains { $0.body?.keys.contains("lead") == true && $0.body?["lead"] is NSNull } }, "PATCH lead null")
        app.buttons["goal.team.done"].tap()
        XCTAssertTrue(waitUntil(8) { again.label == "Bots, Just Me" }, again.label)
        XCTAssertTrue(waitUntil(5) { !self.app.buttons["goal.edit.review"].exists }, "no lead, no check-in")
    }

    // MARK: New Goal's Plan With a bot (board 3)

    @MainActor func testTasks_GoalPlanWithBot() throws {
        try goalMode(["goal_bots": true])
        app = launchSignedIn(Self.look + ["-HQPagesForgetGoalPlanWith", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesNewGoal", "YES"])
        let name = Self.lookName
        let field = app.descendants(matching: .any)["goals.new.title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "New Goal")
        // [goals step 6] Plan With is now New Goal's Who's helping? row, and it starts on the root bot leading (it was off
        // by default, and a first goal saved with no one planning it).
        let hermes = app.buttons["goals.new.who.default"].firstMatch
        XCTAssertTrue(hermes.waitForExistence(timeout: 5), "Who's helping?, with the add-on's bots")
        XCTAssertEqual(hermes.label, "Hermes, on this goal, leads", "on the root bot without touching it")
        // [goals set-up] item 4: the lead's line says the questions come first.
        XCTAssertEqual(app.staticTexts["goals.new.who.note"].firstMatch.label, "Hermes asks up to three questions, then offers a plan.")
        XCTAssertFalse(app.buttons["goals.new.plan"].exists, "no Plan With button any more")
        field.typeText("Learn to bake bread")
        shot("goals3-4-new-plan-with" + name)
        app.buttons["goals.new.add"].firstMatch.tap()

        // [goals set-up] item 5: the goal is made with its lead in the one POST (it was POST, then PATCH lead), and its
        // chat opens with the lead asked for a plan.
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.method == "POST" && $0.path == Self.goalRoute && $0.body?["lead"] as? String == "default" } },
                      "POST /goals with the lead in it")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(goalPatches().contains { $0.body?["lead"] != nil }, "no PATCH for the lead")
        XCTAssertTrue(app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.waitForExistence(timeout: 15), "the chat takes the screen")
        XCTAssertTrue(waitUntil(15) { self.promptTexts().contains { $0.hasPrefix("I just made this goal and want you to lead it.") } },
                      "the hidden ask: \(promptTexts())")
        XCTAssertTrue(waitUntil(15) { self.promptTexts().contains { $0.contains("Goal: “Learn to bake bread”") } }, "with the goal's details")
        XCTAssertTrue(app.staticTexts["Learn to bake bread"].firstMatch.waitForExistence(timeout: 5) || app.cells.staticTexts["Learn to bake bread"].exists,
                      "your bubble keeps your words")

        // The scripted lead answers with a plan: a card under its reply, Use This Plan / Change It / Keep the Goal, No Plan.
        let card = app.cells["chat.goal-offer"].firstMatch.exists ? app.cells["chat.goal-offer"].firstMatch : app.descendants(matching: .any)["chat.goal-offer"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the plan's card")
        let use = app.buttons["chat.goal-offer.Use This Plan"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.goal-offer.Change It"].exists && app.buttons["chat.goal-offer.quiet"].exists)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let before = card.frame.height
        shot("goals3-5-plan-card" + name)
        use.tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.method == "POST" && $0.path.hasPrefix(Self.offerRoute) && $0.body?["action"] as? String == "accept" } })
        XCTAssertTrue(waitUntil(10) { self.app.buttons["chat.goal-offer.undo"].exists }, "answered: one line with Undo")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(card.frame.height, before, accuracy: 1, "the chat card keeps one height in every state")
        shot("goals3-6-plan-accepted" + name)

        // The goal over the chat: its milestones are there now.
        app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["goal.milestone.Pick the first step"].firstMatch.waitForExistence(timeout: 10), "the plan's milestones")
        XCTAssertTrue(app.descendants(matching: .any)["goal.who"].firstMatch.label.hasPrefix("Led by Hermes"))

        // After a relaunch the chat is read from the gateway: your bubble still shows only what you typed.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Learn to bake bread",
                                          "-HQPagesGoalSheet", "chat"])
        XCTAssertTrue(app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.waitForExistence(timeout: 20), "the goal's chat again")
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Here is a first plan")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "the chat read again")
        let hidden = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "I just made this goal")).firstMatch
        XCTAssertFalse(hidden.exists, "the app's ask stays hidden after a relaunch")
        let mine = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Learn to bake bread")).firstMatch
        XCTAssertTrue(mine.exists || app.cells.staticTexts["Learn to bake bread"].firstMatch.exists, "your bubble after a relaunch")
        shot("goals3-6b-plan-after-relaunch" + name)

        // Board 3 itself: the seeded plan for the tomatoes, its card on the goal's page.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Grow our own tomatoes"])
        let pageCard = app.descendants(matching: .any)["goal.offer-card.plan"].firstMatch
        XCTAssertTrue(pageCard.waitForExistence(timeout: 20), "the waiting plan on the goal's page")
        XCTAssertTrue(app.buttons["goal.offer-card.Use This Plan"].exists && app.buttons["goal.offer-card.quiet"].exists)
        XCTAssertTrue(app.buttons["goal.offer-card.more"].exists, "5 milestones, 3 shown: 2 more ›")
        shot("goals3-7-plan-on-page" + name)
        app.buttons["goal.offer-card.quiet"].firstMatch.tap()   // Keep the Goal, No Plan
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.path == Self.offerRoute + "of_plan" && $0.body?["plan"] as? Bool == false } })
        XCTAssertTrue(waitUntil(10) { !pageCard.exists || pageCard.label.contains("Kept the goal, no plan") || self.app.staticTexts["Kept the goal, no plan"].exists })
    }

    // MARK: Tasks from a bot not on the goal (board 5's right phone)

    @MainActor func testTasks_GoalTasksOfferFromAnotherBot() throws {
        try goalMode(["goal_bots": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers"])
        let name = Self.lookName
        let card = app.descendants(matching: .any)["goal.offer-card.tasks"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Finance's tasks on the goal's page")
        XCTAssertTrue(app.staticTexts["Reply to the podcast host with two January dates"].exists, "its tasks")
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hermes leads this goal and sees them at'")).firstMatch
        XCTAssertTrue(note.exists, "who leads it")
        XCTAssertTrue(app.buttons["goal.offer-card.Add to Goal"].exists && app.buttons["goal.offer-card.Just Tasks"].exists
                      && app.buttons["goal.offer-card.No"].exists)
        shot("goals3-8-tasks-from-finance" + name)

        // Just Tasks: added, no goal; Undo takes them back.
        app.buttons["goal.offer-card.Just Tasks"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.path == Self.offerRoute + "of_other" && $0.body?["action"] as? String == "accept"
            && $0.body?["in_goal"] as? Bool == false } }, "accept, in_goal false")
        XCTAssertTrue(app.staticTexts["Added 2 tasks, no goal"].waitForExistence(timeout: 10))
        let undo = app.buttons["goal.offer-card.undo"].firstMatch
        XCTAssertTrue(undo.exists)
        shot("goals3-9-just-tasks" + name)
        undo.tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.path == Self.offerRoute + "of_other" && $0.body?["action"] as? String == "undo" } })
        XCTAssertTrue(waitUntil(10) { self.app.staticTexts["Undone"].exists || !card.exists }, "taken back")
    }

    // MARK: The check-in (board 4's left phone) and its push

    @MainActor func testTasks_GoalCheckin() throws {
        try goalMode(["goal_bots": true])
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        let card = app.descendants(matching: .any)["goal.offer-card.checkin"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the check-in leads Today")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '340 testers, up 37 this week.'")).firstMatch.exists, "its two sentences")
        let add = app.buttons["goal.offer-card.Add These 3"].firstMatch
        XCTAssertTrue(add.exists && app.buttons["goal.offer-card.Change"].exists && app.buttons["goal.offer-card.Not Now"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["goal.offer-card.plan"].exists, "one goal card at a time")
        openGoalShelf()
        let heading = goalShelfHeading()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertLessThan(card.frame.maxY, heading.frame.minY + 1, "above the Goals shelf (board 4)")
        // The testers card carries Hermes's face with the orange dot: something waits for you.
        let testers = shelfCard("1,000 public testers")
        XCTAssertTrue(testers.label.contains("Led by Hermes, with Research. Waiting for your answer."), testers.label)
        shot("goals3-10-checkin-today" + name)

        // Change: the goal's chat takes the cursor.
        app.buttons["goal.offer-card.Change"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.waitForExistence(timeout: 15), "the goal's chat")
        app.buttons["sheet.close"].firstMatch.exists ? app.buttons["sheet.close"].firstMatch.tap() : app.swipeDown(velocity: .fast)
        XCTAssertTrue(card.waitForExistence(timeout: 10))

        // Add These 3: the tasks go under the goal.
        let cues = goalCues()
        add.tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.path == Self.offerRoute + "of_checkin" && $0.body?["action"] as? String == "accept" } })
        XCTAssertGreaterThan(goalCues(), cues, "the answer is felt")
        // Answered, the card leaves Today; what it did shows once as a notice, with Undo (owner 2026-11-23).
        let notice = app.descendants(matching: .any)["pages.notice"].firstMatch
        XCTAssertTrue(waitUntil(10) { notice.exists && notice.label.contains("Added 3 tasks") }, "the notice: \(notice.label)")
        XCTAssertTrue(waitUntil(8) { !card.exists }, "the answered card leaves Today")
        let undo = app.buttons["chat.notice.action"].firstMatch
        XCTAssertTrue(undo.exists && undo.label == "Undo", "Undo on the notice")
        shot("goals3-11-checkin-added" + name)
        undo.tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.path == Self.offerRoute + "of_checkin" && $0.body?["action"] as? String == "undo" } },
                      "Undo on the notice takes the tasks back")

        // The check-in's push ("goal:<id>") opens that goal.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesGoalPush", "1,000 public testers"])
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the goal's page")
        XCTAssertEqual(title.label, "1,000 public testers")
    }

    // MARK: Looks done

    @MainActor func testTasks_GoalLooksDone() throws {
        try goalMode(["goal_bots": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Family trip to the coast"])
        let name = Self.lookName
        let card = app.descendants(matching: .any)["goal.looks-done"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the lead says the goal looks done")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hermes thinks this goal is achieved'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["goal.looks-done.done"].firstMatch.label == "Mark Achieved" && app.buttons["goal.looks-done.keep"].exists)
        shot("goals3-12-looks-done" + name)
        // Not Yet: the card goes, and the lead can't ask again until something moves.
        app.buttons["goal.looks-done.keep"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { self.goalPatches().contains { $0.body?["offer_answer"] as? String == "keep" } }, "offer_answer keep")
        XCTAssertTrue(waitUntil(8) { !card.exists }, "the card goes")
        XCTAssertThrowsError(try account.control("/__fixture/goal-update", ["bot": "default", "goal": "g_trip", "looks_done": "goal"]),
                             "a second looks-done with nothing ticked is refused (403)")
        XCTAssertTrue(app.descendants(matching: .any)["goal.title"].firstMatch.label == "Family trip to the coast")

        // Mark Done on a milestone: the lead says Launch week looks done; the box ticks.
        try account.control("/__fixture/goal-update", ["bot": "default", "goal": "g_testers", "looks_done": "Launch week", "why": "All four posts are up."])
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers"])
        let launch = app.descendants(matching: .any)["goal.looks-done"].firstMatch
        XCTAssertTrue(launch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Hermes thinks Launch week looks done: All four posts are up. Mark it done?"].exists)
        let done = app.buttons["goal.looks-done.done"].firstMatch
        XCTAssertEqual(done.label, "Mark Done")
        shot("goals3-13-looks-done-milestone" + name)
        done.tap()
        XCTAssertTrue(waitUntil(10) { self.goalPatches().contains { $0.body?["offer_answer"] as? String == "done" } }, "offer_answer done")
        XCTAssertTrue(waitUntil(8) { !launch.exists })
        let box = app.descendants(matching: .any)["goal.milestone.Launch week"].firstMatch
        XCTAssertTrue(waitUntil(10) { (box.value as? String)?.lowercased().contains("done") == true || box.label.contains("done") }, "ticked: \(box.label) \(box.value ?? "")")
    }

    // MARK: The stall question (board 4's right phone)

    @MainActor func testTasks_GoalStall() throws {
        try goalMode(["goal_bots": true])
        // A Keep Going from an earlier run stays on this device two weeks: start without one.
        app = launchSignedIn(Self.look + ["-HQPagesForgetGoalKeeps", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        openGoalShelf()
        let shelf = shelfCard("Learn three songs on guitar")
        XCTAssertTrue(waitUntil(15) { shelf.exists || self.app.buttons["goals.shelf.all"].exists })
        app.buttons["tasks.view.goals"].firstMatch.tap()
        let cell = app.cells["goal-cell-Learn three songs on guitar"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        scrollTo(cell)
        let button = app.buttons["goal-card-Learn three songs on guitar"].firstMatch
        XCTAssertTrue(cell.descendants(matching: .any)["goal.card.stall"].firstMatch.exists || button.label.contains("Nothing has moved in 16 days"),
                      "the card's orange line: \(button.label)")
        cell.tap()
        let stall = app.descendants(matching: .any)["goal.stall"].firstMatch
        XCTAssertTrue(stall.waitForExistence(timeout: 10), "the question, with no bot")
        XCTAssertEqual(app.staticTexts["goal.stall.line"].firstMatch.label, "Nothing has moved in 16 days")
        XCTAssertTrue(app.staticTexts["goal.stall.question"].firstMatch.label.hasPrefix("The next task, “Finish lesson 2”, has been open since"))
        XCTAssertTrue(app.buttons["goal.stall.smaller"].exists && app.buttons["goal.stall.pause"].exists && app.buttons["goal.stall.let-go"].exists)
        shot("goals3-14-stall" + name)
        app.buttons["goal.stall.keep"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { self.goalPatches().contains { $0.body?["keep"] as? Bool == true } }, "Keep Going on the gateway (0.9.66)")
        XCTAssertTrue(waitUntil(8) { !stall.exists }, "asked again in two weeks")

        // 0.9.65: the same question; Keep Going is kept on this device, after a relaunch too.
        try account.control("/__fixture/reset", [:])
        try goalMode(["goals": true, "stall": true])
        app.terminate()
        // The 0.9.66 Keep Going above is on this device too: forget it, to ask again on 0.9.65.
        app = launchSignedIn(Self.look + ["-HQPagesForgetGoalKeeps", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenGoal", "Learn three songs on guitar"])
        let old = app.descendants(matching: .any)["goal.stall"].firstMatch
        XCTAssertTrue(old.waitForExistence(timeout: 20), "the same question on 0.9.65")
        XCTAssertFalse(app.descendants(matching: .any)["goal.who"].exists, "no bot on 0.9.65")
        app.buttons["goal.stall.keep"].firstMatch.tap()
        XCTAssertTrue(waitUntil(8) { !old.exists })
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(goalPatches().contains { $0.body?["keep"] != nil }, "0.9.65 keeps no kept_at: nothing is sent")
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Learn three songs on guitar"])
        XCTAssertTrue(app.descendants(matching: .any)["goal.title"].firstMatch.waitForExistence(timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.descendants(matching: .any)["goal.stall"].exists, "kept on this device")
    }

    // MARK: The number read by a bot

    @MainActor func testTasks_GoalNumberFromBot() throws {
        try goalMode(["goal_bots": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers"])
        let name = Self.lookName
        let source = app.descendants(matching: .any)["goal.number.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 20), "where the number comes from")
        XCTAssertTrue(source.label.contains("TestFlight · "), source.label)
        XCTAssertTrue(source.label.contains("8:02"), "when Hermes last looked: \(source.label)")
        shot("goals3-15-number-from-bot" + name)

        // Edit Goal › Number From: Research reads it from the forum.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers", "-HQPagesGoalSheet", "team"])
        let from = app.buttons["goal.edit.source"].firstMatch
        XCTAssertTrue(from.waitForExistence(timeout: 20))
        XCTAssertEqual(from.label, "Number From, TestFlight · Hermes")
        from.tap()
        let research = app.buttons["Research…"].firstMatch
        XCTAssertTrue(research.waitForExistence(timeout: 5), "the goal's bots")
        XCTAssertFalse(app.buttons["Finance…"].exists, "only bots on the goal read its number")
        research.tap()
        let alert = app.alerts["Where Does Research Read It?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let what = alert.textFields.firstMatch
        what.tap()
        what.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "the forum")
        alert.buttons["Set"].tap()
        XCTAssertTrue(waitUntil(10) { self.goalPatches().contains {
            let source = (($0.body?["measure"] as? [String: Any])?["source"] as? [String: Any])
            return source?["bot"] as? String == "research" && source?["what"] as? String == "the forum" } }, "PATCH measure.source")
        XCTAssertTrue(waitUntil(8) { from.label == "Number From, the forum · Research" }, from.label)
        // You again: the row says Update.
        from.tap()
        app.buttons["You"].firstMatch.tap()
        XCTAssertTrue(waitUntil(8) { from.label == "Number From, You" }, from.label)
    }

    // MARK: Where it stands and the Goal Page (step 5)

    @MainActor func testTasks_GoalPage() throws {
        try goalMode(["goal_bots": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers"])
        let name = Self.lookName
        let stands = app.descendants(matching: .any)["goal.stands"].firstMatch
        XCTAssertTrue(stands.waitForExistence(timeout: 20), "where it stands, in the lead's words")
        XCTAssertTrue(app.staticTexts["goal.stands.text"].firstMatch.label.hasPrefix("Most new testers came from the forum post."))
        let who = app.descendants(matching: .any)["goal.who"].firstMatch
        XCTAssertTrue(who.label.hasPrefix("Led by Hermes, with Research"), who.label)
        XCTAssertFalse(app.descendants(matching: .any)["goal.stall"].exists, "a goal that moves isn't asked")
        // The lead's words sit under the cards and the goal's rows: scrolled up into view for the picture.
        let open = app.buttons["goal.stands.page"].firstMatch
        let bottom = app.windows.firstMatch.frame.maxY * 0.78
        for _ in 0..<4 where !open.exists || open.frame.maxY > bottom {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTAssertTrue(open.exists && open.frame.maxY <= bottom, "where it stands, in view: \(open.frame)")
        shot("goals3-16-stands" + name)
        XCTAssertTrue(open.label == "Goal Page", open.label)
        open.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15), "the add-on's page")
        XCTAssertTrue(web.staticTexts["Led by Hermes"].waitForExistence(timeout: 10), "drawn with your bots' names")
        XCTAssertTrue(web.staticTexts["The forum post brought 61 testers in two days."].exists, "what the lead wrote on it")
        XCTAssertTrue(waitUntil(5) { self.requests().contains { $0.method == "GET" && $0.path == Self.goalRoute + "/g_testers/page"
            && ($0.query["names"] ?? "").contains("Hermes") } }, "GET /goals/{id}/page?names=")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("goals3-17-goal-page" + name)

        // Ask for an Update: a hidden turn in the goal's chat.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers", "-HQPagesGoalSheet", "ask"])
        XCTAssertTrue(waitUntil(20) { self.promptTexts().contains { $0.hasPrefix("Please look at where “1,000 public testers” stands now") } },
                      "the lead is asked: \(promptTexts())")
    }

    // MARK: The add-on's word

    @MainActor func testTasks_GoalBotsNeedTheAddOn() throws {
        // 0.9.65: goals, and nothing of steps 3 to 5.
        try goalMode(["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        XCTAssertTrue(goalShelfHeading().waitForExistence(timeout: 20))
        openGoalShelf()
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'goal.offer-card.'")).firstMatch.exists, "no goal card")
        let testers = shelfCard("1,000 public testers")
        XCTAssertTrue(testers.waitForExistence(timeout: 5))
        XCTAssertFalse(testers.label.contains("Led by"), "no faces: \(testers.label)")
        shot("goals3-18-older-addon-today" + name)
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers", "-HQPagesGoalSheet", "edit"])
        XCTAssertTrue(app.descendants(matching: .any)["goal.edit.sheet"].firstMatch.waitForExistence(timeout: 20) || app.textFields["goal.edit.name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["goal.edit.lead"].exists, "no Led By")
        XCTAssertFalse(app.buttons["goal.edit.bots"].exists, "no Bots row")
        XCTAssertFalse(app.buttons["goal.edit.source"].exists, "no Number From")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.descendants(matching: .any)["goal.title"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["goal.who"].exists, "no who row")
        XCTAssertFalse(app.descendants(matching: .any)["goal.stands"].exists, "no stands")
        XCTAssertFalse(app.descendants(matching: .any)["goal.tucked-bar"].exists, "no goal's chat")
        XCTAssertFalse(app.descendants(matching: .any)["goal.number.source"].exists)
        XCTAssertFalse(requests().contains { $0.method == "GET" && $0.path.hasSuffix("/page") && $0.path.hasPrefix(Self.goalRoute) }, "no Goal Page asked for")

        // New Goal has no Plan With, and no Who's helping? row.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesNewGoal", "YES"])
        XCTAssertTrue(app.buttons["goals.new.add"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["goals.new.plan"].exists, "no Plan With on 0.9.65")
        XCTAssertFalse(app.descendants(matching: .any)["goals.new.who"].exists, "no Who's helping? on 0.9.65")
        app.terminate()

        // No goals at all: exactly today's Tasks (no shelf, no goal card).
        try account.control("/__fixture/reset", [:])
        try goalMode(["goal_bots": true, "goals": "empty"])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Today"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(goalShelfHeading().exists, "no shelf")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'goal.offer-card.'")).firstMatch.exists)
        shot("goals3-19-no-goals" + name)
    }
}

// MARK: - Helpers

extension PagesTests {
    /// The goals' PATCHes, newest last.
    /// The fixture in a goals mode. The run's first launch signs in, and signing in taps "Not Now" on the password
    /// prompt, which is also the check-in's own answer: so that launch happens before the goals (as `launchWithLists`).
    @MainActor func goalMode(_ mode: [String: Any]) throws {
        if !Self.freshThisRun { launchSignedIn(Self.look).terminate() }
        try account.control("/__fixture/tasks-mode", mode)
    }

    @MainActor func goalPatches() -> [Request] {
        requests().filter { $0.method == "PATCH" && $0.path.hasPrefix("/api/plugins/hermes-hq-push/goals/") }
    }

    /// What was sent to the bots (prompt.submit's text), oldest first.
    @MainActor func promptTexts() -> [String] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return ((state["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == "prompt.submit" }
            .compactMap { ($0["params"] as? [String: Any])?["text"] as? String }
    }

    /// The DEBUG probe's count of cues that would have played (`-HQDebugHapticsProbe YES`).
    @MainActor func goalCues() -> Int {
        let probe = app.descendants(matching: .any)["debug.haptics"]
        guard probe.waitForExistence(timeout: 5), let value = probe.value as? String,
              let count = value.split(separator: " ").first?.split(separator: "=").last.flatMap({ Int($0) }) else { return -1 }
        return count
    }
}
