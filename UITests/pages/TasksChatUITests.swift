// [tasks] A task is a workspace (owner 2026-11-04: "If you can all live inside the task, I think that's the best way to
// do it"; a reply sent from a task had left it for "a brand new session that was preloaded with some text … That's
// chaos"). Owner 2026-11-05: the chat lives on the task page itself. The page is the task's own chat with the task's
// details on top: your bubble shows your words alone, the chat is made hidden (never in Sessions or the desktop app's
// list), and only once you write. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_TaskChat); HQN_TASKS_LOOK
// picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_TaskChat() throws {
        // A task with its own chat: where it stands and what's next in Inbox's words, and under it the chat so far, on
        // the one page (Pinned Task step 1, 2026-11-07: the brief).
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenTask", "Follow up with Ivy on the contract"])
        // The plain task view (owner 2026-11-09): the circle, Inbox's words whole, its answers as taps, when it looks again.
        let state = app.buttons["task.check"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 20), "the task opens")
        let words = app.textViews["task.words"].firstMatch
        XCTAssertTrue(words.exists, "Inbox's words")
        XCTAssertTrue(((words.value as? String) ?? "").contains("No reply from Ivy yet"), "from its Task Page: \(words.value ?? "")")
        XCTAssertTrue(app.descendants(matching: .any)["task.next-check"].firstMatch.exists, "when Inbox looks again")
        XCTAssertTrue(app.buttons["task.choice.0"].firstMatch.exists, "its answers are taps")
        XCTAssertFalse(app.buttons["task.share-draft"].firstMatch.exists, "no move buttons")
        XCTAssertFalse(app.buttons["task.status"].exists, "no status menu on the page")
        XCTAssertTrue(app.tables["chat.table"].exists, "the task's page is its chat")
        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Can you keep an eye out for it?")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "the first question is on the task's page")
        XCTAssertFalse(mine.label.contains("Task id"), "your bubble shows your words alone: \(mine.label)")
        XCTAssertFalse(mine.label.contains("About my task"), mine.label)
        shot("tasks-chat-1-page" + Self.lookName)
        XCTAssertTrue(state.isHittable, "the page opens on the task, its chat under it")
        XCTAssertFalse(app.buttons["task.chat"].exists, "nothing opens over the task")
        // Its steps show at once, with Add a step (owner 2026-11-05: "I don't like that the steps in the task are now
        // behind a click"); nothing folds them away.
        XCTAssertTrue(app.buttons["task.steps.add"].firstMatch.waitForExistence(timeout: 5), "a task with a chat shows its steps, + to add")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Send the nudge")).firstMatch.exists,
                      "its steps are on the page")
        shot("tasks-chat-1b-steps" + Self.lookName)

        // What Inbox watches for, and where the task came from, are in its History (⋯ › History).
        app.buttons["chat.more"].firstMatch.tap()
        app.buttons["History"].firstMatch.tap()
        let watching = app.descendants(matching: .any)["task.history.watch"].firstMatch
        XCTAssertTrue(watching.waitForExistence(timeout: 5), "History opens")
        XCTAssertTrue(watching.label.contains("Watching for a reply from Ivy"), watching.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Added from your chat with Inbox")).firstMatch.exists,
                      "where it came from")
        shot("tasks-chat-1c-history" + Self.lookName)
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 5))

        // A task you share with a bot that has no chat yet: opening it makes none; the first message makes one,
        // hidden, with Hermes, and its reply comes in under the task. [tasks-first] The task's view has one line to
        // write in; the chat's full box comes with the chat.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Mom’s birthday gift"])
        let field = app.textViews["composer.text"].firstMatch
        let message = app.buttons["task.message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "the task opens with its one-line message box")
        XCTAssertFalse(field.exists, "not the chat's full box")
        XCTAssertTrue(app.descendants(matching: .any)["task.sheet"].firstMatch.exists, "with the task on top")
        let made: () -> [String: Any]? = {
            self.taskRPC("session.create").first { ($0["title"] as? String)?.hasPrefix("Task: Mom’s birthday gift") == true }
        }
        XCTAssertNil(made(), "opening the task makes no chat")
        shot("tasks-chat-2-empty" + Self.lookName)
        // A field in the details stays in sight as the keys come up (the chat keeps what is above its bar, which lifted
        // the step field under the top bar).
        let add = app.buttons["task.steps.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the task can take a step")
        add.tap()
        let step = app.textFields["task.add-step"].firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 5), "+ Add a step opens the field")
        let keys = app.keyboards.firstMatch
        XCTAssertTrue(keys.waitForExistence(timeout: 5), "the keys come up for the step")
        // Writing a step: the chat's bar steps aside (step 3), and the field stands under the chat's bar, above the keys.
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        XCTAssertTrue(waitUntil(3) { !message.exists && !field.exists }, "the message box steps aside while you write a step")
        XCTAssertTrue(waitUntil(3) { step.frame.minY >= barBottom - 1 && step.frame.maxY <= keys.frame.minY },
                      "the step field shows between the bar (\(barBottom)) and the keys (\(keys.frame.minY)): \(step.frame)")
        shot("tasks-chat-2b-step" + Self.lookName)
        step.typeText("\n")   // an empty step closes its field, and the message box comes back
        XCTAssertTrue(message.waitForExistence(timeout: 5), "the message box is back")
        message.tap()          // the chat takes the screen with its own box
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the chat's full box comes with the chat")
        sendInComposer("Is there a cleaner open late?")
        XCTAssertTrue(waitUntil(10) { self.taskPrompts().contains { $0.contains("(Task id t_gift)") } }, "asks: \(taskPrompts())")
        let asked = taskPrompts().first { $0.contains("(Task id t_gift)") } ?? ""
        XCTAssertTrue(asked.hasPrefix("Is there a cleaner open late?"), asked)
        XCTAssertEqual(made()?["hidden"] as? Bool, true, "the task's chat is made hidden: \(String(describing: made()))")
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Is there a cleaner open late?")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        XCTAssertFalse(bubble.label.contains("Task id"), bubble.label)
        XCTAssertTrue(app.descendants(matching: .any)["task.sheet"].firstMatch.exists, "the reply comes in on the task's page")
        // The link was saved on the task; a second message goes as typed.
        XCTAssertTrue(waitUntil(10) {
            let rest = ((try? self.account.control("/__fixture/state")) ?? [:])["rest"] as? [[String: Any]] ?? []
            return rest.contains { ($0["method"] as? String) == "PATCH" && ($0["path"] as? String)?.hasSuffix("/t_gift") == true
                && (($0["body"] as? [String: Any])?["chat"] as? [String: Any])?["profile"] as? String == "default" }
        }, "the chat is saved on the task")
        shot("tasks-chat-3-sent" + Self.lookName)
    }

    @MainActor func testTasks_TaskPage() throws {
        // Owner 2026-11-05: every task a bot works on has a page that shows everything about it and where it stands,
        // in one look the add-on draws (hermes-hq-push 0.9.38). Inbox wrote on this one; its chat can ask for more.
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenTask", "Follow up with Ivy on the contract"])
        // The organized task view (owner 2026-11-09): the Task Page opens from ⋯.
        XCTAssertTrue(app.buttons["task.check"].firstMatch.waitForExistence(timeout: 20), "the task opens")
        app.buttons["chat.more"].firstMatch.tap()
        let open = app.buttons["Task Page"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "a task a bot works on offers its Task Page in ⋯")
        shot("tasks-page-1-chip" + Self.lookName)
        open.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10), "the page opens")
        let stands = web.staticTexts["Where it stands"].firstMatch
        XCTAssertTrue(stands.waitForExistence(timeout: 10), "the page says where the task stands")
        XCTAssertTrue(web.staticTexts["No reply from Ivy yet. A friendly nudge is drafted and ready for you to send."].firstMatch.exists)
        XCTAssertTrue(app.navigationBars["Task Page"].exists, "the sheet is called Task Page")
        shot("tasks-page-2-top" + Self.lookName)
        web.swipeUp(velocity: .slow)
        shot("tasks-page-3-more" + Self.lookName)
        // Its chat is made, so the page can ask Inbox to bring it up to date (a hidden turn in the task's chat).
        let ask = web.buttons["Ask for an Update"].firstMatch
        for _ in 0..<4 where !ask.isHittable { web.swipeUp(velocity: .slow) }
        XCTAssertTrue(ask.isHittable, "the page can ask its bot for an update")
        ask.tap()
        XCTAssertTrue(waitUntil(10) { self.taskPrompts().contains { $0.contains("Task Page up to date") } }, "asks: \(taskPrompts())")
        shot("tasks-page-4-asked" + Self.lookName)

        // A task with nothing written on it yet still has a page: what the task itself says.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Renew passport"])
        // Nothing written on it: no "Page ›" on the brief, but ⋯ has it.
        XCTAssertTrue(app.buttons["task.check"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["task.page.open"].exists, "no Page › until the bot writes one")
        app.buttons["chat.more"].firstMatch.tap()
        let fromMenu = app.buttons["Task Page"].firstMatch
        XCTAssertTrue(fromMenu.waitForExistence(timeout: 5), "⋯ › Task Page")
        fromMenu.tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Filling in the form"].firstMatch.waitForExistence(timeout: 10),
                      "a page nobody wrote on says what the task says")
        XCTAssertFalse(app.webViews.firstMatch.buttons["Ask for an Update"].firstMatch.isHittable, "no chat yet: nothing to ask in")
        shot("tasks-page-5-plain" + Self.lookName)

        // Your own task has no page (and, [tasks-first], no bot's conversation: it stands alone).
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Go through the open job applications"])
        XCTAssertTrue(app.buttons["task.check"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["task.page.open"].exists, "your own task has no Task Page")
        app.buttons["task.more"].firstMatch.tap()
        XCTAssertTrue(app.buttons["History"].firstMatch.waitForExistence(timeout: 5), "its own ⋯")
        XCTAssertFalse(app.buttons["Task Page"].exists, "no Task Page in ⋯ either")
    }

    /// Owner 2026-11-05: a reply alert from a task's chat "did not open back up in the task. It opened up in a new
    /// session. And then also the Hermes name on the top is messed up." The chat's link takes the tapped alert's road
    /// (NotificationHub.open → openNotifiedChat): the task opens at the reply, the task above it, its name on top.
    @MainActor func testTasks_ChatAlertOpensTask() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        XCTAssertTrue(app.descendants(matching: .any)["tasks.views"].firstMatch.waitForExistence(timeout: 20), "the list is read")
        tab("Bots")
        openTaskChatLink()
        // Step 3: a reply's alert lands at the reply with the task as its bar (one line: the bot's latest word).
        let watch = app.descendants(matching: .any)["task.bar"].firstMatch
        XCTAssertTrue(watch.waitForExistence(timeout: 15), "the alert opens the task, as its bar")
        XCTAssertTrue(app.tables["chat.table"].exists, "the task's page is its chat")
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "The draft is under")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "with what was said in it")
        XCTAssertTrue(waitUntil(5) { reply.isHittable }, "at the reply the alert was for")
        let title = app.descendants(matching: .any)["chat.title"].firstMatch
        XCTAssertTrue(title.exists, "the chat's bar")
        XCTAssertTrue(title.label.hasPrefix("Follow up with Ivy on the contract"), "the task's name on top: \(title.label)")
        XCTAssertTrue(title.label.contains("Inbox"), "and its bot under it: \(title.label)")
        XCTAssertFalse(title.label.contains("Task:"), "never the chat's own unique name: \(title.label)")
        shot("tasks-chat-alert-1-task" + Self.lookName)

        // Tapped again with the task open: the task stays (its chat reads its tail), nothing opens over it.
        openTaskChatLink()
        XCTAssertFalse(watch.waitForNonExistence(timeout: 3), "the task stays open")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.title").count, 1, "one chat on show")

        // A cold launch onto Bots, signed in afresh (no task list on this device yet: the tap reads it): the same.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQDebugResetAccounts", "YES"])
        openTaskChatLink()
        XCTAssertTrue(app.descendants(matching: .any)["task.bar"].firstMatch.waitForExistence(timeout: 25), "a cold launch opens the task too")
        let coldTitle = app.descendants(matching: .any)["chat.title"].firstMatch
        XCTAssertTrue(coldTitle.label.hasPrefix("Follow up with Ivy on the contract"), coldTitle.label)
        let coldReply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "The draft is under")).firstMatch
        XCTAssertTrue(waitUntil(10) { coldReply.exists && coldReply.isHittable }, "at the reply")
        // The whole task is a tap on its bar.
        app.descendants(matching: .any)["task.bar"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["task.check"].firstMatch.waitForExistence(timeout: 5), "the task is above its chat")
        shot("tasks-chat-alert-3-scrolled-up" + Self.lookName)
        shot("tasks-chat-alert-2-cold" + Self.lookName)
    }

    /// Owner 2026-11-07 (Pinned Task step 2): a task's chat is made by its first message, not its first letter; words
    /// typed and not sent are still there when the task opens again; and ⋯ › Chat has nothing that would cut the chat
    /// from its task.
    @MainActor func testTasks_ChatBelongsToTheTask() throws {
        // [tasks-first] A task you share with a bot (a task of your own has no chat to write in).
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Renew passport"])
        let message = app.buttons["task.message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "the task opens with its one-line message box")
        let made: () -> Bool = {
            self.taskRPC("session.create").contains { ($0["title"] as? String)?.hasPrefix("Task: Renew passport") == true }
        }
        message.tap()
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the chat's box comes with the chat")
        field.typeText("Ask if they press shirts")
        XCTAssertFalse(waitUntil(3) { made() }, "writing makes no chat")
        shot("tasks-step2-1-typed" + Self.lookName)

        // Closed and opened again: the words are still in the bar.
        app.buttons["sheet.close"].firstMatch.tap()
        let row = app.cells["task-row-Renew passport"].firstMatch
        XCTAssertTrue(waitUntil(10) { row.exists && row.isHittable && !app.textViews["composer.text"].firstMatch.exists }, "back on the list")
        row.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 15), "the task opens again")
        message.tap()
        let again = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(5) { ((again.value as? String) ?? "").contains("press shirts") }, "the draft is kept: \(again.value ?? "")")
        XCTAssertFalse(made(), "still no chat")
        shot("tasks-step2-2-draft-kept" + Self.lookName)

        // ⋯ › Chat: what's left, and none of what would cut the chat from its task.
        app.buttons["chat.more"].firstMatch.tap()
        let chat = app.buttons["Chat"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()
        XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: 5), "Chat ▸ opens")
        for gone in ["Delete Chat", "Archive", "Rename…", "Pin", "Branch in New Chat"] {
            XCTAssertFalse(app.buttons[gone].exists, "no \(gone)")
        }
        shot("tasks-step2-3-chat-menu" + Self.lookName)
    }

    /// The task's chat's link, `<scheme>://session/<id>`, opened by the system (as a tapped alert is).
    @MainActor private func openTaskChatLink() {
        let scheme = ProcessInfo.processInfo.environment["HQN_URL_SCHEME"].flatMap { $0.isEmpty ? nil : $0 } ?? "hermeshq-native"
        XCUIDevice.shared.system.open(URL(string: "\(scheme)://session/20261104_090000_tcsam01")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    /// Types into the chat's bar and taps Send, once more if the words are still there (a tap while the button was
    /// still turning from Talk into Send does nothing; TranscriptEndToEndTests.typeAndSend).
    @MainActor private func sendInComposer(_ text: String) {
        let field = app.textViews["composer.text"].firstMatch
        field.tap()
        field.typeText(text)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        if waitUntil(3, { (field.value as? String) != text }) { return }
        if send.exists { send.tap() }
    }

    private func taskRPC(_ method: String) -> [[String: Any]] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return ((state["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == method }
            .compactMap { $0["params"] as? [String: Any] }
    }

    private func taskPrompts() -> [String] { taskRPC("prompt.submit").compactMap { $0["text"] as? String } }
}
