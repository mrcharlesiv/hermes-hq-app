// [tasks] Owner 2026-11-04: picking Me / A Bot / Together "felt too complicated to toss the task in there", and a
// Together task with a bot did nothing ("I don't know if the bot's picking it up. I don't know if I'm supposed to message
// the bot"). New Task is the task, Due, and one "Ask a Bot to Help" row; with a bot, Add opens the task and its own
// chat over it, and asks the bot at once. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_NewTaskAsksTheBot); every look:
// TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.

import XCTest

extension PagesTests {
    @MainActor func testTasks_NewTaskAsksTheBot() throws {
        let look = ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"]
        let name = look.map { "-" + $0 } ?? ""
        let arguments: [String] = switch look {
        case "dark": ["-hqn.appearance", "dark"]
        case "desktop": ["-hqn.appearance", "light", "-hqn.theme.desktopLook", "<true/>"]
        case "desktop-dark": ["-hqn.appearance", "dark", "-hqn.theme.desktopLook", "<true/>"]
        default: ["-hqn.appearance", "light"]
        }
        app = launchSignedIn(arguments + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let plus = app.buttons["tasks.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20), "the page has +")
        // The bar has three buttons, Search in the middle (owner 2026-11-04): [Filter] [Search] [+]. [tasks-first] The
        // views are the row under the bar, so the bots are Filter's first rows and the page's commands follow them.
        let filter = app.buttons["pages.scope"].firstMatch, search = app.buttons["tasks.search"].firstMatch
        XCTAssertTrue(filter.exists && search.exists, "Filter and Search")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.chips"].exists, "no bot pills")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.views"].exists, "the views")
        XCTAssertLessThan(filter.frame.midX, search.frame.midX)
        XCTAssertLessThan(search.frame.midX, plus.frame.midX)
        filter.tap()
        XCTAssertTrue(app.buttons["Tasks Settings…"].firstMatch.waitForExistence(timeout: 5), "the page's commands are in Filter")
        XCTAssertTrue(app.buttons["Import from Reminders…"].firstMatch.exists)
        XCTAssertTrue(app.buttons["All Bots"].firstMatch.exists && app.buttons["Me"].firstMatch.exists, "the bots, and Me, lead it")
        shot("tasks-bar-menu" + name)
        app.buttons["Tasks Settings…"].firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: -40, dy: -200)).tap()
        _ = waitUntil(2) { !app.buttons["Tasks Settings…"].firstMatch.exists }
        shot("tasks-bar" + name)
        plus.tap()

        // Plain: the task, Due, and who helps (No One). No Me / A Bot / Together, no prep switch, no steps.
        let title = app.textViews["tasks.new.title"].firstMatch.exists ? app.textViews["tasks.new.title"].firstMatch : app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "New Task opens")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.new.who"].exists, "no Who Does It switch")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.new.prep"].exists, "no gets-it-ready switch")
        let helper = app.descendants(matching: .any)["tasks.new.bot"].firstMatch
        XCTAssertTrue(helper.exists, "Ask a Bot to Help")
        title.typeText("Plan the team offsite")
        shot("tasks-new-plain" + name)

        // Pick a bot: the footer says what Add will do.
        helper.tap()
        let hermes = app.buttons["Hermes"].firstMatch
        XCTAssertTrue(hermes.waitForExistence(timeout: 5), "the bots are listed")
        hermes.tap()
        let note = app.staticTexts["tasks.new.help-note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "says what happens on Add")
        XCTAssertTrue(note.label.contains("chat opens"), note.label)
        shot("tasks-new-bot" + name)

        // Add: a shared task with Hermes, nothing set up to wait for a timer, and Hermes's chat asking it now.
        app.buttons["tasks.new.add"].firstMatch.tap()
        let added = { self.requests().filter { $0.method == "POST" && $0.path.hasSuffix("/tasks") && ($0.body?["title"] as? String) == "Plan the team offsite" } }
        XCTAssertTrue(waitUntil(10) { !added().isEmpty }, "the task is added")
        let body = added().first?.body ?? [:]
        XCTAssertEqual(body["who"] as? String, "together")
        XCTAssertEqual(body["bot"] as? String, "default")
        XCTAssertEqual(body["prep"] as? Bool, false)
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the task's page opens: its own chat")
        XCTAssertTrue(waitUntil(10) { self.askedPrompts().contains { $0.contains("“Plan the team offsite”") } }, "Hermes is asked: \(askedPrompts())")
        let asked = askedPrompts().first { $0.contains("“Plan the team offsite”") } ?? ""
        XCTAssertTrue(asked.hasPrefix("Help me with this: ask me which parts you should take"), asked)
        XCTAssertTrue(asked.contains("(Task id "), "with the task's id, so it can take its parts: \(asked)")
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Help me with “Plan the team offsite”")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "your bubble says it short")
        shot("tasks-new-asked" + name)

        // [tasks] 2026-11-05: the chat lives on the task's page, under the task (nothing opens over it).
        XCTAssertTrue(app.descendants(matching: .any)["task.sheet"].firstMatch.exists, "the task is on the same page")
        XCTAssertFalse(app.navigationBars.buttons["Task"].exists, "no Back to a task underneath")
    }

    private func askedPrompts() -> [String] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return ((state["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == "prompt.submit" }
            .compactMap { ($0["params"] as? [String: Any])?["text"] as? String }
    }
}
