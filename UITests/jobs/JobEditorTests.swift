// [jobs] End-to-end tests of the Jobs editor (docs/spec/3x-jobs.md §8) against the jobs stand-in gateway
// (scripts/fixtures/jobs-gateway.py). Run with scripts/e2e-jobs.sh <udid> [port].

import XCTest

class JobEditorCase: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!
    nonisolated(unsafe) static var freshThisRun = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        try account.control("/__fixture/reset", [:])
    }

    struct Request { var method: String; var path: String; var query: [String: String]; var body: [String: Any]?; var at: Double }

    func requests() -> [Request] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return ((state["requests"] as? [[String: Any]]) ?? []).map { row in
            var query: [String: String] = [:]
            for (key, value) in (row["query"] as? [String: Any]) ?? [:] { query[key] = "\(value)" }
            return Request(method: row["method"] as? String ?? "", path: row["path"] as? String ?? "", query: query,
                           body: row["body"] as? [String: Any], at: row["at"] as? Double ?? 0)
        }
    }

    @MainActor @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return condition()
    }

    @MainActor func launchSignedIn(_ arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQPagesHUDSeconds", "6"] + arguments
        app.launchEnvironment = environment
        if !Self.freshThisRun {
            Self.freshThisRun = true
            app.launchArguments += ["-HQDebugResetAccounts", "YES"]
        }
        app.launch()
        // A Desktop Look skin may letter the tabs in capitals: match them whatever the case.
        let bots = app.tabBars.buttons.matching(NSPredicate(format: "label ==[c] %@", "Bots")).firstMatch
        let form = app.textFields["sign-in-address"]
        _ = waitUntil(15) { bots.exists || form.exists }
        if !bots.exists && form.exists {
            let pages = PagesTests()
            pages.account = account
            pages.signIn(app)
        }
        XCTAssertTrue(bots.waitForExistence(timeout: 15), "signed in")
        return app
    }

    @MainActor func tab(_ name: String) {
        let button = app.tabBars.buttons.matching(NSPredicate(format: "label ==[c] %@", name)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the \(name) tab")
        button.tap()
        if !waitUntil(2, { button.isSelected }) { button.tap() }
        XCTAssertTrue(waitUntil(3, { button.isSelected }), "the \(name) tab is selected")
    }

    @MainActor func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let suffix = ProcessInfo.processInfo.environment["HQN_JOBS_SHOT_SUFFIX"] ?? ""
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("e2e-jobs-\(name)\(suffix).png"))
        }
    }

    @MainActor func dump(_ name: String) {
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? app.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("dump-\(name).txt"), atomically: true, encoding: .utf8)
        }
    }

    @MainActor func jobRow(_ key: String) -> XCUIElement { app.cells["job-row-\(key)"] }

    // MARK: The editor

    @MainActor func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @MainActor var saveButton: XCUIElement { app.buttons["job.editor.save"] }
    @MainActor var hud: XCUIElement { app.descendants(matching: .any)["pages.hud"] }

    @MainActor func openJobs() {
        tab("Jobs")
        XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(15) { self.app.buttons["jobs.new"].exists }, "the + button")
    }

    @MainActor func openNew() {
        if !app.collectionViews["jobs.list"].exists || !app.buttons["jobs.new"].isHittable { openJobs() }
        XCTAssertTrue(waitUntil(10) { !self.hud.exists || !self.app.navigationBars["New Job"].exists })
        app.buttons["jobs.new"].tap()
        XCTAssertTrue(app.navigationBars["New Job"].waitForExistence(timeout: 5), "New Job opens")
        XCTAssertTrue(el("job.editor.top").waitForExistence(timeout: 5), "the form shows")
    }

    /// Brings a job's row on screen (the list only keeps the rows near the screen).
    @MainActor @discardableResult func showRow(_ key: String) -> XCUIElement {
        let row = jobRow(key)
        let list = app.collectionViews["jobs.list"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { list.swipeDown() }
        for _ in 0..<10 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable, "the row \(key)")
        return row
    }

    /// The discard question's "Keep Editing" (a popover question has no cancel button: a tap outside is it).
    @MainActor func keepEditing() {
        let keep = app.buttons["Keep Editing"].firstMatch
        if keep.exists { keep.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap() }
        XCTAssertTrue(waitUntil(3) { !self.app.buttons["Discard Changes"].exists }, "the question goes")
    }

    @MainActor func clock(_ element: XCUIElement) -> String {
        ((element.value as? String) ?? "").replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Scrolls the form until the element can be tapped.
    @MainActor @discardableResult func reveal(_ element: XCUIElement, tries: Int = 18) -> XCUIElement {
        let form = app.otherElements["job.editor"].firstMatch
        if !element.exists { toTop() }
        for _ in 0..<tries {
            // One snapshot of the keyboard: a drag can dismiss it between an exists check and a frame read.
            let keyboardTop = (try? app.keyboards.firstMatch.snapshot())?.frame.minY
            if element.exists && element.frame.minY < 130 {
                // Under the bar: bring it down.
                form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                    .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
                continue
            }
            let floor = keyboardTop.map { $0 - 8 } ?? app.frame.height - 60
            if element.exists && element.isHittable && element.frame.maxY < floor { return element }
            // Drag inside what the keyboard leaves showing.
            let from = keyboardTop != nil ? 0.40 : 0.70, to = keyboardTop != nil ? 0.16 : 0.38
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        return element
    }

    @MainActor func toTop() {
        let form = app.otherElements["job.editor"].firstMatch
        for _ in 0..<5 where !(el("job.editor.top").exists && el("job.editor.top").isHittable) {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        }
    }

    @MainActor func type(_ id: String, _ text: String, replacing: Bool = false) {
        let field = reveal(el(id))
        XCTAssertTrue(field.waitForExistence(timeout: 5), id)
        guard replacing else {
            field.tap()
            field.typeText(text)
            return
        }
        // A second go when the field reads something else: on a loaded Mac the keyboard's page switches for
        // "*", "/" and digits get lost ("*/10 * * * *" came out "*/10 * *"); a real drop in the app drops again.
        for _ in 0..<2 {
            // A tap at the field's right end puts the caret after the last character.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            XCTAssertTrue(waitUntil(3) { self.app.keyboards.firstMatch.exists }, "the keyboard")
            // Delete as many characters as the field reads, even when that equals its hint: an empty field reads its
            // hint, but so does a name that is the one Hermes would give (the Name hint), and extra deletes do nothing.
            if let current = field.value as? String, !current.isEmpty {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            field.typeText(text)
            if field.value as? String == text { return }
        }
    }

    static let frequencyIds = ["Daily": "daily", "Weekdays": "weekdays", "Weekly": "weekly", "Monthly": "monthly", "Hourly": "hourly",
                               "Every 15 minutes": "every-15-minutes", "Custom": "custom"]
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// A button in a sideways strip: the form scrolled to the strip, then the strip to the button.
    @MainActor @discardableResult func stripButton(_ strip: String, _ button: XCUIElement) -> XCUIElement {
        let row = reveal(el(strip))
        for _ in 0..<12 where !onScreen(button) { drag(row, left: true) }
        for _ in 0..<16 where !onScreen(button) { drag(row, left: false) }
        XCTAssertTrue(onScreen(button), "\(strip) shows the button")
        return button
    }

    /// A drag across the part of a strip that is on the screen. The strip's own frame spans all its picks since they
    /// stand in one glass container (2026-10-31), so `swipeLeft()` at its middle began far past the screen's edge.
    @MainActor func drag(_ row: XCUIElement, left: Bool) {
        let window = app.windows.firstMatch
        let shown = row.frame.intersection(window.frame)
        guard !shown.isNull, shown.width > 120 else { return left ? row.swipeLeft() : row.swipeRight() }
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let near = origin.withOffset(CGVector(dx: shown.minX + 40, dy: shown.midY))
        let far = origin.withOffset(CGVector(dx: shown.maxX - 40, dy: shown.midY))
        (left ? far : near).press(forDuration: 0.05, thenDragTo: left ? near : far)
    }

    /// Whether a strip's button can be tapped: its middle on the screen first. The strips run edge to edge with their
    /// picks in one glass container (2026-10-31), and asking `isHittable` of a pick past the screen's edge threw
    /// "Activation point invalid" instead of answering no.
    @MainActor func onScreen(_ button: XCUIElement) -> Bool {
        guard button.exists else { return false }
        let frame = button.frame, screen = app.windows.firstMatch.frame
        guard !frame.isEmpty, screen.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        return button.isHittable
    }

    /// The Schedule's frequency chips, Weekly's day buttons (that day alone) and the Start From cards (redesign 2026-10-31).
    @MainActor func choose(_ id: String, _ choice: String) {
        switch id {
        case "job.editor.frequency":
            let chip = el("job.editor.frequency.\(Self.frequencyIds[choice] ?? choice)")
            stripButton(id, chip).tap()
            XCTAssertTrue(waitUntil(3) { chip.isSelected }, "\(choice) is chosen")
        case "job.editor.day":
            guard let day = Self.dayNames.firstIndex(of: choice) else { return XCTFail("no day \(choice)") }
            let target = reveal(el("job.editor.weekday.\(day)"))
            if !target.isSelected { target.tap() }
            for other in 0..<7 where other != day && el("job.editor.weekday.\(other)").isSelected { el("job.editor.weekday.\(other)").tap() }
            XCTAssertTrue(waitUntil(3) { target.isSelected }, "\(choice) is on")
        default:
            let card = el(id).buttons.matching(NSPredicate(format: "label == %@", choice == "Custom" ? "Write Your Own" : choice)).firstMatch
            stripButton(id, card).tap()
            XCTAssertTrue(waitUntil(3) { card.isSelected }, "\(choice) is chosen")
        }
    }

    /// A menu picker row: opens it and taps the choice. The frequency, day and Start From are buttons in a row now.
    @MainActor func pick(_ id: String, _ choice: String) {
        if ["job.editor.frequency", "job.editor.day", "job.editor.start"].contains(id) { return choose(id, choice) }
        let row = reveal(app.buttons[id])
        XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        row.tap()
        let item = app.buttons.matching(NSPredicate(format: "label == %@", choice)).firstMatch
        if !item.waitForExistence(timeout: 2) {
            // A long menu: scroll it.
            for _ in 0..<5 where !item.exists { app.swipeUp() }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 3), "\(id) offers \(choice)")
        item.tap()
        XCTAssertTrue(waitUntil(3) { row.label.hasSuffix(choice) }, "\(id) reads \(choice) (\(row.label))")
    }

    @MainActor func setTime(_ id: String, hour: String, minute: String, period: String) {
        let picker = reveal(app.datePickers[id])
        XCTAssertTrue(picker.waitForExistence(timeout: 5), id)
        picker.buttons.firstMatch.tap()
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.firstMatch.waitForExistence(timeout: 5), "the time wheel opens")
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: hour)
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: minute)
        if wheels.count > 2 { wheels.element(boundBy: 2).adjust(toPickerWheelValue: period) }
        // Close it with a tap on the sheet's title: a tap outside the wheel also lands on what is under it (iOS 27),
        // and the screen's middle can be a frequency chip.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.115)).tap()
        XCTAssertTrue(waitUntil(3) { !wheels.firstMatch.exists }, "the wheel closes")
    }

    @MainActor func summary() -> String { el("job.editor.summary").exists ? el("job.editor.summary").label : "" }

    /// Taps Create / Save and waits for the HUD.
    @MainActor func saveExpecting(_ words: String) {
        XCTAssertTrue(waitUntil(5) { self.saveButton.exists && self.saveButton.isEnabled }, "the button is live")
        saveButton.tap()
        XCTAssertTrue(waitUntil(15) { self.hud.exists && self.hud.label == words }, "\(words) shows (\(hud.exists ? hud.label : "no HUD"), \(failure()))")
        XCTAssertTrue(waitUntil(5) { !self.app.otherElements["job.editor"].exists }, "the sheet closes")
    }

    @MainActor func failure() -> String { el("job.editor.failure").exists ? el("job.editor.failure").label : "" }

    func writes(_ method: String, _ prefix: String) -> [Request] {
        requests().filter { $0.method == method && $0.path.hasPrefix(prefix) && !$0.path.hasSuffix("/trigger") && !$0.path.hasSuffix("/pause") && !$0.path.hasSuffix("/resume") }
    }

    func bodyKeys(_ request: Request?) -> [String] { (request?.body ?? [:]).keys.sorted() }

    func updates(_ request: Request?) -> [String: Any] { (request?.body?["updates"] as? [String: Any]) ?? [:] }

    /// A row's menu: a long press (improve-24 #15 took the ⋯ button off Jobs rows, 2026-10-28).
    @MainActor func openRowMenu(_ row: XCUIElement) { row.press(forDuration: 1.0) }

    /// "Edit Job…" from a row's menu.
    @MainActor func editFromMenu(_ key: String, title: String) {
        let row = showRow(key)
        openRowMenu(row)
        let edit = app.buttons["Edit Job…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "Edit Job… is in the menu")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5), "Edit Job opens")
    }

    @MainActor func closeSheet(discard: Bool = true) {
        app.buttons["sheet.close"].firstMatch.tap()
        let question = app.buttons["Discard Changes"].firstMatch
        if question.waitForExistence(timeout: 1.5), discard { question.tap() }
        if discard { XCTAssertTrue(waitUntil(5) { !self.app.otherElements["job.editor"].exists }, "the sheet closes") }
    }

    /// No answer the app could not read (the fixture never sends a 4000 "malformed" frame; a write the gateway refused
    /// as malformed would be a 422 here).
    func assertNoMalformed(file: StaticString = #filePath, line: UInt = #line) {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        let rpc = (state["rpc"] as? [[String: Any]]) ?? []
        XCTAssertFalse(rpc.contains { "\($0)".contains("4000") }, "a malformed frame was answered", file: file, line: line)
    }
}

final class JobEditorTests: JobEditorCase {
    override func tearDownWithError() throws {
        assertNoMalformed()
    }

    /// Every new screen and state, for the light and dark screenshot sets (scripts/e2e-jobs.sh runs it in both).
    @MainActor func testJE00_Screens() throws {
        app = launchSignedIn()
        openJobs()
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 10))
        shot("list")
        let list = app.collectionViews["jobs.list"]
        let blueprint = app.cells["blueprint-row-morning-brief"]
        for _ in 0..<8 where !(blueprint.exists && blueprint.isHittable) { list.swipeUp() }
        XCTAssertTrue(blueprint.exists, "the Blueprints section")
        shot("list-blueprints")
        // Row menu with Edit Job…
        openRowMenu(showRow("research|j-fail"))
        XCTAssertTrue(app.buttons["Edit Job…"].waitForExistence(timeout: 3))
        shot("row-menu")
        app.buttons["Edit Job…"].tap()
        XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shot("edit")
        closeSheet()
        // New Job, top and bottom.
        openNew()
        Thread.sleep(forTimeInterval: 1)
        shot("new")
        reveal(app.buttons["job.editor.model"])
        shot("new-delivery")
        app.buttons["job.editor.model"].tap()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["job.editor.model.anthropic.claude-sonnet-5"].waitForExistence(timeout: 5))
        shot("model-picker")
        app.navigationBars["Model"].buttons.element(boundBy: 0).tap()
        toTop()
        // Each frequency's fields.
        pick("job.editor.frequency", "Weekly")
        reveal(el("job.editor.summary"))
        shot("weekly")
        app.datePickers["job.editor.time"].buttons.firstMatch.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 5))
        shot("time-wheel")
        app.buttons["PopoverDismissRegion"].firstMatch.tap()
        pick("job.editor.frequency", "Monthly")
        pick("job.editor.monthday", "31")
        shot("monthly-31")
        pick("job.editor.frequency", "Hourly")
        shot("hourly")
        pick("job.editor.frequency", "Every 15 minutes")
        shot("every-15")
        pick("job.editor.frequency", "Custom")
        type("job.editor.custom", "banana", replacing: true)
        type("job.editor.prompt", "Say hello")
        shot("custom-keyboard")
        saveButton.tap()
        XCTAssertTrue(waitUntil(10) { self.failure().contains("Invalid schedule") }, "the refusal shows")
        shot("failure")
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        shot("discard")
        app.buttons["Discard Changes"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { !self.app.otherElements["job.editor"].exists })
        // A blueprint's own fields.
        openNew()
        pick("job.editor.start", "Custom reminder")
        Thread.sleep(forTimeInterval: 0.6)
        shot("blueprint")
        reveal(el("job.editor.slot.deliver.local"))
        shot("blueprint-lower")
        closeSheet()
        // The failed-run card and the page's Edit.
        showRow("research|j-fail").tap()
        XCTAssertTrue(app.buttons["job.error.edit"].waitForExistence(timeout: 5))
        shot("detail-failed")
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// R5: + opens New Job; Create waits for a prompt; the defaults post exactly prompt, schedule, deliver.
    @MainActor func testJE01_NewJobDefaults() throws {
        app = launchSignedIn()
        openNew()
        XCTAssertFalse(saveButton.isEnabled, "Create waits for a prompt")
        XCTAssertEqual(app.keyboards.count, 0, "nothing takes focus when the sheet opens")
        XCTAssertTrue(el("job.editor.bot.default").isSelected, "the first bot under All Bots")
        XCTAssertEqual(summary(), "Every day at 9:00 AM")
        type("job.editor.prompt", "Summarize my unread mail")
        XCTAssertTrue(waitUntil(3) { self.saveButton.isEnabled }, "typing a prompt enables Create")
        saveExpecting("Job Created")
        let posts = writes("POST", "/api/cron/jobs")
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.path, "/api/cron/jobs")
        XCTAssertEqual(posts.first?.query["profile"], "default")
        XCTAssertEqual(bodyKeys(posts.first), ["deliver", "prompt", "schedule"], "no name, no model, no provider")
        XCTAssertEqual(posts.first?.body?["prompt"] as? String, "Summarize my unread mail")
        XCTAssertEqual(posts.first?.body?["schedule"] as? String, "0 9 * * *")
        XCTAssertEqual(posts.first?.body?["deliver"] as? String, "local")
        XCTAssertTrue(jobRow("default|jn0001").waitForExistence(timeout: 10), "the new row is in the list")
        XCTAssertTrue(waitUntil(5) { self.jobRow("default|jn0001").isHittable }, "and scrolled into view")
        shot("created")
    }

    /// R5: each of the seven presets posts its expression (Custom starts from the line the form held).
    @MainActor func testJE02_EveryPreset() throws {
        app = launchSignedIn()
        let presets = ["Daily", "Weekdays", "Weekly", "Monthly", "Hourly", "Every 15 minutes", "Custom"]
        for preset in presets {
            openNew()
            type("job.editor.prompt", "Preset \(preset)")
            if preset != "Daily" { pick("job.editor.frequency", preset) }
            saveExpecting("Job Created")
            XCTAssertTrue(waitUntil(10) { !self.hud.exists }, "the HUD goes")
        }
        let sent = writes("POST", "/api/cron/jobs").compactMap { $0.body?["schedule"] as? String }
        XCTAssertEqual(sent, ["0 9 * * *", "0 9 * * 1-5", "0 9 * * 1", "0 9 1 * *", "0 * * * *", "*/15 * * * *", "0 9 * * *"])
    }

    /// R7: the time fields, their summaries and notes, and what they post.
    @MainActor func testJE03_TimeFields() throws {
        app = launchSignedIn()
        openNew()
        // (The prompt is typed last: a long menu needs the room the keyboard takes.)
        // 4: a preset switch keeps the time.
        setTime("job.editor.time", hour: "7", minute: "15", period: "AM")
        XCTAssertEqual(summary(), "Every day at 7:15 AM")
        pick("job.editor.frequency", "Weekly")
        XCTAssertEqual(summary(), "Every Monday at 7:15 AM", "Weekly keeps 7:15")
        // 2: Monthly + 31 says which months skip; 28 does not.
        pick("job.editor.frequency", "Monthly")
        pick("job.editor.monthday", "31")
        XCTAssertTrue(waitUntil(3) { self.el("job.editor.skip-note").exists })
        XCTAssertEqual(el("job.editor.skip-note").label, "Months without day 31 skip this run.")
        XCTAssertEqual(summary(), "Monthly on day 31 at 7:15 AM")
        pick("job.editor.monthday", "28")
        XCTAssertTrue(waitUntil(3) { !self.el("job.editor.skip-note").exists }, "no skip note at 28")
        // 3: Hourly.
        pick("job.editor.frequency", "Hourly")
        pick("job.editor.minute", ":25")
        XCTAssertEqual(summary(), "Every hour at :25")
        pick("job.editor.minute", ":00")
        XCTAssertEqual(summary(), "At the top of every hour")
        XCTAssertFalse(app.datePickers["job.editor.time"].exists, "Hourly has no time wheel")
        // 1: Weekly + Wednesday + 6:30 PM.
        pick("job.editor.frequency", "Weekly")
        pick("job.editor.day", "Wednesday")
        setTime("job.editor.time", hour: "6", minute: "30", period: "PM")
        XCTAssertEqual(summary(), "Every Wednesday at 6:30 PM")
        shot("weekly-wednesday")
        toTop()
        type("job.editor.prompt", "Plan dinner")
        saveExpecting("Job Created")
        XCTAssertEqual(writes("POST", "/api/cron/jobs").last?.body?["schedule"] as? String, "30 18 * * 3")
    }

    /// R7 (5): the phone's time zone never moves the hour that is sent.
    @MainActor func testJE03b_TimeZoneNeverMovesTheHour() throws {
        for zone in ["Asia/Tokyo", "America/Los_Angeles"] {
            app = launchSignedIn(environment: ["TZ": zone])
            openNew()
            type("job.editor.prompt", "Zone \(zone)")
            setTime("job.editor.time", hour: "10", minute: "00", period: "AM")
            XCTAssertEqual(summary(), "Every day at 10:00 AM")
            setTime("job.editor.time", hour: "9", minute: "00", period: "AM")
            saveExpecting("Job Created")
            XCTAssertEqual(writes("POST", "/api/cron/jobs").last?.body?["schedule"] as? String, "0 9 * * *", zone)
            app.terminate()
        }
    }

    /// R10: the Custom schedule field.
    @MainActor func testJE04_CustomSchedule() throws {
        app = launchSignedIn()
        openNew()
        type("job.editor.prompt", "Check the queue")
        setTime("job.editor.time", hour: "7", minute: "15", period: "AM")
        pick("job.editor.frequency", "Custom")
        let field = el("job.editor.custom")
        XCTAssertEqual(field.value as? String, "15 7 * * *", "Custom starts from the current expression")
        type("job.editor.custom", "*/10 * * * *", replacing: true)
        XCTAssertEqual(field.value as? String, "*/10 * * * *")
        shot("custom")
        saveExpecting("Job Created")
        XCTAssertEqual(writes("POST", "/api/cron/jobs").last?.body?["schedule"] as? String, "*/10 * * * *")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })

        openNew()
        type("job.editor.prompt", "Check again")
        pick("job.editor.frequency", "Custom")
        type("job.editor.custom", "every 2h", replacing: true)
        saveExpecting("Job Created")
        XCTAssertEqual(writes("POST", "/api/cron/jobs").last?.body?["schedule"] as? String, "every 2h")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })

        // A refusal: the reason's first line on top, nothing lost, then a plain-hyphen expression goes through.
        openNew()
        type("job.editor.prompt", "Keep me")
        pick("job.editor.frequency", "Custom")
        type("job.editor.custom", "banana", replacing: true)
        saveButton.tap()
        XCTAssertTrue(waitUntil(10) { self.failure().contains("Couldn’t save the job") }, "the failure note shows")
        XCTAssertTrue(failure().contains("Invalid schedule 'banana'. Use:"), failure())
        XCTAssertFalse(failure().contains("Interval"), "only the first line of the usage text")
        XCTAssertTrue(el("job.editor.custom.rejected").exists || reveal(el("job.editor.custom.rejected")).exists, "a red note under the field")
        XCTAssertEqual(reveal(el("job.editor.custom")).value as? String, "banana", "the field keeps its text")
        XCTAssertEqual(reveal(el("job.editor.prompt")).value as? String, "Keep me")
        XCTAssertTrue(saveButton.isEnabled, "Create is live again")
        type("job.editor.custom", "0 9 * * 1-5", replacing: true)
        saveExpecting("Job Created")
        let sent = writes("POST", "/api/cron/jobs").last?.body?["schedule"] as? String
        XCTAssertEqual(sent, "0 9 * * 1-5", "plain hyphen and spaces")
        XCTAssertEqual(sent.map { Array($0.unicodeScalars.map(\.value)) }, Array("0 9 * * 1-5".unicodeScalars.map(\.value)))
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })

        // A schedule that is not a cron line opens on Custom and is not sent again with another change.
        editFromMenu("deploys|j-watch", title: "Release watch")
        XCTAssertTrue(el("job.editor.frequency.custom").isSelected, "Custom is chosen")
        XCTAssertEqual(reveal(el("job.editor.custom")).value as? String, "every 30m")
        toTop()
        type("job.editor.name", "Release watcher", replacing: true)
        saveExpecting("Job Saved")
        let put = writes("PUT", "/api/cron/jobs/j-watch").last
        XCTAssertEqual(updates(put).keys.sorted(), ["name"], "no schedule key")
    }

    /// R8: the delivery rows.
    @MainActor func testJE05_Delivery() throws {
        app = launchSignedIn()
        openNew()
        type("job.editor.prompt", "Deliver me")
        let local = reveal(el("job.editor.deliver.local"))
        XCTAssertTrue(local.isSelected, "Run History Only starts checked")
        XCTAssertEqual(local.label, "Run History Only")
        local.tap()
        XCTAssertTrue(local.isSelected, "a second tap keeps it")
        XCTAssertFalse(el("job.editor.deliver.discord").exists, "Discord has no home channel: no row")
        XCTAssertTrue(reveal(el("job.editor.deliver.needs-home")).label.hasPrefix("Discord needs a home channel first"))
        XCTAssertEqual(reveal(el("job.editor.deliver.bot-chat:research")).label, "Research")
        XCTAssertEqual(el("job.editor.deliver.bot-chat:default").label, "Hermes")
        shot("delivery")
        let telegram = reveal(el("job.editor.deliver.telegram"))
        telegram.tap()
        XCTAssertTrue(waitUntil(3) { telegram.isSelected && !local.isSelected }, "Telegram takes Run History Only's place")
        saveExpecting("Job Created")
        XCTAssertEqual(writes("POST", "/api/cron/jobs").last?.body?["deliver"] as? String, "telegram")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })

        // A saved route the gateway no longer lists is kept, and not sent again with another change.
        editFromMenu("default|j-pinned", title: "Family dinner plan")
        let kept = reveal(el("job.editor.deliver.telegram:-100123:7"))
        XCTAssertTrue(kept.exists && kept.isSelected, "the kept row is checked")
        XCTAssertTrue(kept.label.hasPrefix("Telegram · ") && kept.label.hasSuffix("(topic 7)"), kept.label)
        XCTAssertFalse(el("job.editor.deliver.local").isSelected)
        shot("delivery-kept")
        toTop()
        type("job.editor.name", "Family dinner", replacing: true)
        saveExpecting("Job Saved")
        XCTAssertEqual(updates(writes("PUT", "/api/cron/jobs/j-pinned").last).keys.sorted(), ["name"], "no deliver key, no model key")
    }

    /// R9: the model picker.
    @MainActor func testJE06_ModelPicker() throws {
        app = launchSignedIn()
        openNew()
        type("job.editor.prompt", "Pick a model")
        let row = reveal(app.buttons["job.editor.model"])
        XCTAssertEqual(row.value as? String, "Default (global model)")
        // [model-scope] Owner 2026-11-03: a job's model is its own, and Default is its bot's.
        let scope = app.staticTexts["job.editor.model-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 3) && scope.label.hasPrefix("Applies to this job only. Default uses "), scope.label)
        shot("model-scope")
        row.tap()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 5), "the picker is a pushed page")
        XCTAssertFalse(app.buttons["sheet.close"].exists, "the back button takes the ✕'s place")
        XCTAssertTrue(app.buttons["job.editor.model.default"].isSelected)
        XCTAssertTrue(app.staticTexts["Uses whatever model this bot is set to."].exists)
        let sonnet = app.buttons["job.editor.model.anthropic.claude-sonnet-5"]
        XCTAssertTrue(sonnet.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["job.editor.model.openai.gpt-5"].exists, "a provider that is not signed in is not offered")
        shot("models")
        sonnet.tap()
        XCTAssertTrue(app.navigationBars["New Job"].waitForExistence(timeout: 5), "picking pops back")
        XCTAssertNotEqual(reveal(app.buttons["job.editor.model"]).value as? String, "Default (global model)")
        saveExpecting("Job Created")
        let post = writes("POST", "/api/cron/jobs").last
        XCTAssertEqual(post?.body?["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(post?.body?["provider"] as? String, "anthropic")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })

        // Edit a pinned job → Default clears both keys.
        editFromMenu("default|j-model", title: "Daily standup notes")
        reveal(app.buttons["job.editor.model"]).tap()
        XCTAssertTrue(app.buttons["job.editor.model.anthropic.claude-sonnet-5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["job.editor.model.anthropic.claude-sonnet-5"].isSelected)
        app.buttons["job.editor.model.default"].tap()
        XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5))
        saveExpecting("Job Saved")
        let cleared = updates(writes("PUT", "/api/cron/jobs/j-model").last)
        XCTAssertEqual(cleared.keys.sorted(), ["model", "provider"])
        XCTAssertTrue(cleared["model"] is NSNull && cleared["provider"] is NSNull, "null for both clears the pin")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })

        // A pin the gateway no longer lists is shown, offered under Current, and never sent with another change.
        editFromMenu("default|j-pinned", title: "Family dinner plan")
        let pinned = reveal(app.buttons["job.editor.model"])
        XCTAssertNotEqual(pinned.value as? String, "Default (global model)")
        pinned.tap()
        XCTAssertTrue(app.buttons["job.editor.model.current"].waitForExistence(timeout: 5), "the pinned model under Current")
        XCTAssertTrue(app.buttons["job.editor.model.current"].isSelected)
        shot("models-current")
        app.navigationBars["Model"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled, "opening and closing the picker changes nothing")
        closeSheet()
    }

    /// R9: no provider signed in, then the read failing.
    @MainActor func testJE06b_ModelPickerWithoutModels() throws {
        try account.control("/__fixture/set", ["models": ["providers": [["slug": "openai", "name": "OpenAI", "models": ["gpt-5"], "authenticated": false]]]])
        app = launchSignedIn()
        openNew()
        reveal(app.buttons["job.editor.model"]).tap()
        XCTAssertTrue(app.buttons["job.editor.model.default"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'job.editor.model.'")).count == 1 },
                      "only the default row")
        shot("models-none")
        app.navigationBars["Model"].buttons.element(boundBy: 0).tap()
        closeSheet()
        try account.control("/__fixture/fail", ["method": "GET", "path": "/api/model/options", "status": 500, "count": 2])
        openNew()
        reveal(app.buttons["job.editor.model"]).tap()
        XCTAssertTrue(app.staticTexts["Couldn’t load the models."].waitForExistence(timeout: 8) || app.buttons["job.editor.model.anthropic.claude-sonnet-5"].exists)
        shot("models-failed")
        let retry = app.buttons["job.editor.models.retry"]
        if retry.exists { retry.tap() }
        app.navigationBars["Model"].buttons.element(boundBy: 0).tap()
        closeSheet()
    }

    /// R6: a blueprint from the list, its fields, option labels, example defaults, and what it posts.
    @MainActor func testJE07_BlueprintFromList() throws {
        app = launchSignedIn()
        openJobs()
        let list = app.collectionViews["jobs.list"]
        let row = app.cells["blueprint-row-morning-brief"]
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 10))
        for _ in 0..<10 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.exists, "Blueprints lists the catalog")
        XCTAssertTrue(list.otherElements["jobs.section.Blueprints"].exists || app.cells["blueprint-row-weekly-review"].exists)
        row.tap()
        XCTAssertTrue(app.navigationBars["New Job"].waitForExistence(timeout: 5))
        XCTAssertTrue(el("job.editor.card.morning-brief").isSelected, "Start From is on Morning briefing")
        XCTAssertTrue(el("job.editor.start.description").label.hasPrefix("A short daily briefing"))
        XCTAssertEqual(clock(app.datePickers["job.editor.slot.time"].buttons.firstMatch), "8:00 AM")
        XCTAssertTrue(reveal(el("job.editor.slot.deliver.local")).isSelected, "Where to deliver? is on Run History Only")
        XCTAssertFalse(el("job.editor.slot.deliver.origin").exists, "the phone is not a chat a job comes from")
        XCTAssertFalse(app.buttons["job.editor.model"].exists, "no model row for a blueprint")
        XCTAssertFalse(el("job.editor.prompt").exists)
        shot("blueprint-morning")
        saveExpecting("Job Created")
        let post = writes("POST", "/api/cron/blueprints/instantiate").last
        XCTAssertEqual(post?.query["profile"], "default")
        XCTAssertEqual(post?.body?["blueprint"] as? String, "morning-brief")
        XCTAssertEqual(post?.body?["values"] as? [String: String], ["time": "08:00", "deliver": "local"])
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })

        // Option labels in words; the raw option is what is sent.
        openNew()
        type("job.editor.prompt", "My own prompt")
        pick("job.editor.start", "Habit check-in")
        let recurrence = reveal(app.buttons["job.editor.slot.recurrence"])
        XCTAssertTrue(recurrence.label.hasSuffix("Every day"), recurrence.label)
        recurrence.tap()
        for words in ["Every day", "Weekdays", "Weekends"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", words)).firstMatch.waitForExistence(timeout: 3), words)
        }
        shot("blueprint-options")
        app.buttons.matching(NSPredicate(format: "label == %@", "Weekends")).firstMatch.tap()
        toTop()
        pick("job.editor.start", "Hydration & movement nudge")
        XCTAssertTrue(reveal(app.buttons["job.editor.slot.interval_hours"]).label.hasSuffix("Every hour"))
        XCTAssertTrue(app.buttons["job.editor.slot.start_hour"].label.hasSuffix("9 AM"), app.buttons["job.editor.slot.start_hour"].label)
        XCTAssertTrue(reveal(app.buttons["job.editor.slot.end_hour"]).label.hasSuffix("5 PM"))
        pick("job.editor.slot.interval_hours", "Every 2 hours")
        // An example default starts empty, with the help as its placeholder; Create waits for it.
        toTop()
        pick("job.editor.start", "Price & availability watch")
        let item = reveal(el("job.editor.slot.item"))
        XCTAssertEqual(item.placeholderValue, "URL or precise description — variant, dates, seller")
        XCTAssertTrue(((item.value as? String) ?? "").isEmpty || item.value as? String == item.placeholderValue, "starts empty")
        XCTAssertFalse(saveButton.isEnabled, "Create waits for the required field")
        shot("blueprint-example-default")
        // Back to Custom: what was typed is still there.
        toTop()
        pick("job.editor.start", "Custom")
        XCTAssertEqual(reveal(el("job.editor.prompt")).value as? String, "My own prompt")
        toTop()
        pick("job.editor.start", "Hydration & movement nudge")
        pick("job.editor.slot.interval_hours", "Every 2 hours")
        saveExpecting("Job Created")
        let hydration = writes("POST", "/api/cron/blueprints/instantiate").last?.body?["values"] as? [String: String]
        XCTAssertEqual(hydration, ["interval_hours": "2", "start_hour": "9", "end_hour": "17", "deliver": "local"])
    }

    /// R6: a field error shows in the form; no blueprints means no section, no row, and the shorter empty text.
    @MainActor func testJE08_BlueprintFieldError() throws {
        app = launchSignedIn()
        openNew()
        pick("job.editor.start", "Morning briefing")
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/blueprints/instantiate", "status": 422,
                                                "detail": "422: invalid time '25:00' — use HH:MM (24h)"])
        saveButton.tap()
        XCTAssertTrue(waitUntil(10) { self.failure().contains("invalid time '25:00' — use HH:MM (24h)") }, "the reason shows inline (\(failure()))")
        XCTAssertFalse(failure().contains("422:"), "without its code")
        XCTAssertTrue(app.navigationBars["New Job"].exists, "the sheet stays")
        XCTAssertTrue(el("job.editor.slot.time.error").exists, "the field it names gets the note")
        shot("blueprint-422")
        // An unknown blueprint.
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/blueprints/instantiate", "status": 404,
                                                "detail": "Unknown blueprint: morning-brief"])
        saveButton.tap()
        XCTAssertTrue(waitUntil(10) { self.failure().contains("This blueprint is no longer available.") }, failure())
        closeSheet()

        // The empty page names the blueprints below it.
        try account.control("/__fixture/job", ["delete": "j-paused"])
        let scope = app.buttons["pages.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
        app.buttons["Finance"].firstMatch.tap()
        let note = app.cells["jobs.empty"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), "No Jobs, above the blueprints")
        XCTAssertTrue(note.staticTexts["Jobs run a prompt for Finance on a schedule. Tap + to make one, or start from a blueprint below."].exists
                      || note.label.contains("or start from a blueprint below"), note.label)
        XCTAssertTrue(app.cells["blueprint-row-morning-brief"].exists)
        shot("empty-with-blueprints")
        app.terminate()

        // No blueprints at all.
        try account.control("/__fixture/set", ["blueprints": [Any]()])
        app = launchSignedIn()
        openJobs()
        XCTAssertTrue(waitUntil(10) { self.app.staticTexts["Jobs run a prompt for Finance on a schedule. Tap + to make one."].exists },
                      "the empty text without the blueprint clause")
        XCTAssertFalse(app.cells["blueprint-row-morning-brief"].exists, "no Blueprints section")
        shot("empty-no-blueprints")
        app.buttons["jobs.new"].tap()
        XCTAssertTrue(app.navigationBars["New Job"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(el("job.editor.start").exists, "no Start From cards")
        XCTAssertTrue(el("job.editor.bot.finance").isSelected, "the page's bot is preselected")
        type("job.editor.prompt", "Close the books")
        saveExpecting("Job Created")
        XCTAssertEqual(writes("POST", "/api/cron/jobs").last?.query["profile"], "finance")
        // Back to All Bots for the tests that follow.
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })
        app.buttons["pages.scope"].tap()
        app.buttons["All Bots"].firstMatch.tap()
    }

    /// R2: Edit Job… third in the row menu; it opens the job's values; Save sends only what changed.
    @MainActor func testJE09_EditFromMenu() throws {
        app = launchSignedIn()
        openJobs()
        let row = jobRow("inbox|j-triage")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        openRowMenu(row)
        XCTAssertTrue(app.buttons["Edit Job…"].waitForExistence(timeout: 3))
        let names = ["Run Now", "Pause", "Edit Job…", "Delete Job"]
        let ys = names.map { app.buttons[$0].firstMatch.frame.minY }
        XCTAssertTrue(names.allSatisfy { app.buttons[$0].firstMatch.exists }, "the four entries")
        XCTAssertEqual(ys, ys.sorted(), "in order, Edit Job… third (\(ys))")
        app.buttons["Edit Job…"].tap()
        XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5))
        XCTAssertTrue(el("job.editor.top").exists, "the form opens on its prompt")
        XCTAssertEqual(el("job.editor.name").value as? String, "Morning inbox triage")
        XCTAssertTrue(el("job.editor.frequency.weekdays").isSelected)
        XCTAssertEqual(summary(), "Weekdays at 8:00 AM")
        XCTAssertFalse(el("job.editor.bot").exists, "a job cannot move between bots")
        XCTAssertFalse(el("job.editor.start").exists)
        Thread.sleep(forTimeInterval: 1.5)   // the fresh copy of the job lands
        XCTAssertFalse(saveButton.isEnabled, "nothing changed yet")
        XCTAssertEqual(saveButton.label, "Save")
        type("job.editor.name", "Inbox triage", replacing: true)
        XCTAssertTrue(waitUntil(3) { self.saveButton.isEnabled })
        shot("edit-dirty")
        saveExpecting("Job Saved")
        let puts = writes("PUT", "/api/cron/jobs/j-triage")
        XCTAssertEqual(puts.count, 1)
        XCTAssertEqual(puts.first?.query["profile"], "inbox")
        XCTAssertEqual(updates(puts.first) as? [String: String], ["name": "Inbox triage"], "only the changed key")
        XCTAssertTrue(waitUntil(10) { row.staticTexts["Inbox triage"].exists }, "the row shows the new name")

        // The hold menu is the same menu.
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })
        showRow("research|j-late").press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Edit Job…"].waitForExistence(timeout: 3), "the long-press menu has it too")
        shot("hold-menu")
        app.buttons["Edit Job…"].tap()
        XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5))
        XCTAssertEqual(el("job.editor.name").value as? String, "Weekly reading list")
        closeSheet()
    }

    /// R3: Edit Job beside Run Again on the failed-run card; the page's Edit; the page shows what was saved.
    @MainActor func testJE10_EditFromFailedRun() throws {
        app = launchSignedIn()
        openJobs()
        XCTAssertTrue(jobRow("research|j-fail").waitForExistence(timeout: 10))
        jobRow("research|j-fail").tap()
        let edit = app.buttons["job.error.edit"], run = app.buttons["job.error.run"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5) && run.exists, "both buttons on the card")
        XCTAssertEqual(edit.label, "Edit Job")
        XCTAssertEqual(run.label, "Run Again")
        XCTAssertEqual(edit.frame.midY, run.frame.midY, accuracy: 2, "side by side")
        XCTAssertLessThan(edit.frame.maxX, run.frame.minX + 1, "Edit Job first")
        shot("failed-card")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5))
        XCTAssertEqual(el("job.editor.name").value as? String, "gbrain-daily-update-check-local")
        type("job.editor.prompt", " Then say what changed.")
        saveExpecting("Job Saved")
        let put = writes("PUT", "/api/cron/jobs/j-fail").last
        XCTAssertEqual(updates(put).keys.sorted(), ["prompt"])
        XCTAssertTrue((updates(put)["prompt"] as? String ?? "").contains("Then say what changed."))
        XCTAssertTrue(waitUntil(10) { self.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Then say what changed.' OR value CONTAINS 'Then say what changed.'")).count > 0 },
                      "the page's prompt changed")
        XCTAssertTrue(edit.exists, "the card stays until a run succeeds")
        // Run Again still asks.
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })
        run.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3), "Run Again still asks first")
        app.alerts.firstMatch.buttons["Cancel"].tap()
        // The bar's Edit.
        let barEdit = app.buttons["job.edit"]
        XCTAssertTrue(barEdit.exists && barEdit.isEnabled)
        barEdit.tap()
        XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5))
        // One sheet only, however it was asked for.
        XCTAssertEqual(app.navigationBars.matching(identifier: "Edit Job").count, 1)
        closeSheet()
        XCTAssertEqual(app.staticTexts["job.delivers"].label.isEmpty, false)
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// R5/R9: a script-only job has the note, no prompt, no model; its edit sends neither.
    @MainActor func testJE11_ScriptOnlyJob() throws {
        app = launchSignedIn()
        openJobs()
        editFromMenu("deploys|j-script", title: "Disk space check")
        XCTAssertTrue(el("job.editor.script-note").waitForExistence(timeout: 3))
        XCTAssertEqual(el("job.editor.script-note").label, "This job runs a script on the computer running Hermes. It has no AI prompt.")
        XCTAssertFalse(el("job.editor.prompt").exists, "no prompt field")
        XCTAssertTrue(el("job.editor.frequency.every-15-minutes").isSelected)
        shot("script-only")
        pick("job.editor.frequency", "Hourly")
        reveal(el("job.editor.deliver.local"))
        for _ in 0..<3 { app.otherElements["job.editor"].firstMatch.swipeUp() }
        XCTAssertFalse(app.buttons["job.editor.model"].exists, "no model row")
        saveExpecting("Job Saved")
        XCTAssertEqual(updates(writes("PUT", "/api/cron/jobs/j-script").last) as? [String: String], ["schedule": "0 * * * *"])
    }

    /// §4.6: a failed save keeps the sheet and everything typed; odd answers are plain words.
    @MainActor func testJE12_SaveFailsKeepsForm() throws {
        app = launchSignedIn()
        openNew()
        type("job.editor.name", "Keeper")
        type("job.editor.prompt", "Everything typed stays")
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/jobs", "status": 400, "detail": "The provider refused the request.\nTraceback line"])
        saveButton.tap()
        XCTAssertTrue(waitUntil(10) { self.failure().contains("The provider refused the request.") }, failure())
        XCTAssertTrue(failure().hasPrefix("Couldn’t save the job"), failure())
        XCTAssertFalse(failure().contains("Traceback"), "first line only")
        XCTAssertTrue(el("job.editor.failure").isHittable, "scrolled into view")
        XCTAssertEqual(el("job.editor.name").value as? String, "Keeper")
        XCTAssertEqual(el("job.editor.prompt").value as? String, "Everything typed stays")
        XCTAssertTrue(saveButton.isEnabled)
        shot("save-failed")
        // 500 with HTML.
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/jobs", "status": 500, "raw": "<html><body><h1>Internal Server Error</h1></body></html>"])
        saveButton.tap()
        XCTAssertTrue(waitUntil(10) { self.failure().contains("The gateway did not say why.") }, failure())
        XCTAssertFalse(failure().contains("<"), "no raw HTML")
        // The connection dropped mid-request.
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/jobs", "drop": true])
        saveButton.tap()
        XCTAssertTrue(waitUntil(20) { !self.failure().contains("did not say why") && self.failure().hasPrefix("Couldn’t save the job") && self.saveButton.exists && self.saveButton.isEnabled }, failure())
        XCTAssertFalse(failure().contains("NSURL") || failure().contains("Error Domain"), failure())
        shot("save-dropped")
        XCTAssertEqual(el("job.editor.prompt").value as? String, "Everything typed stays")
        // And then it goes through, once.
        saveExpecting("Job Created")
        XCTAssertEqual(requests().filter { $0.method == "POST" && $0.path == "/api/cron/jobs" }.count, 4, "three refusals and one create, none repeated by itself")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })
        // A job deleted elsewhere while its editor is open.
        editFromMenu("default|j-zone", title: "Weekly health check")
        try account.control("/__fixture/job", ["delete": "j-zone", "broadcast": false])
        type("job.editor.name", "Gone", replacing: true)
        saveButton.tap()
        XCTAssertTrue(waitUntil(10) { self.failure().contains("This job no longer exists.") }, failure())
        shot("save-gone")
        closeSheet()
        XCTAssertTrue(waitUntil(10) { !self.jobRow("default|j-zone").exists }, "the row is gone")
    }

    /// D-J5, D-J4: the discard question; one write for many taps; the sheet holds while saving.
    @MainActor func testJE13_DiscardGuard() throws {
        app = launchSignedIn()
        openNew()
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { !self.app.otherElements["job.editor"].exists }, "a pristine form closes at once")
        XCTAssertFalse(app.buttons["Discard Changes"].exists)
        openNew()
        type("job.editor.prompt", "Do not lose me")
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3), "a changed form asks")
        shot("discard")
        keepEditing()
        XCTAssertEqual(el("job.editor.prompt").value as? String, "Do not lose me")
        // A swipe down asks too.
        app.navigationBars["New Job"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3), "a swipe down asks")
        keepEditing()
        XCTAssertTrue(app.navigationBars["New Job"].exists, "the sheet is still up")
        // A slow write: one POST for three taps, ✕ holds, then the result.
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/jobs", "delay": 8])
        let frame = saveButton.frame   // a fixed point: the button itself gives way to the spinner
        let spot = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        spot.tap(); spot.tap(); spot.tap()
        XCTAssertTrue(waitUntil(2) { !self.saveButton.exists }, "a spinner takes the button's place")
        shot("saving")
        let close = app.buttons["sheet.close"].firstMatch
        XCTAssertFalse(close.isEnabled, "✕ waits for the answer")
        close.tap()
        XCTAssertTrue(app.navigationBars["New Job"].exists, "the sheet does not close mid-write")
        XCTAssertTrue(waitUntil(15) { self.hud.exists && self.hud.label == "Job Created" })
        XCTAssertEqual(requests().filter { $0.method == "POST" && $0.path == "/api/cron/jobs" }.count, 1, "exactly one POST")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })
        // Discard really discards: nothing is sent.
        openNew()
        type("job.editor.prompt", "Throw me away")
        closeSheet(discard: true)
        XCTAssertEqual(requests().filter { $0.method == "POST" && $0.path == "/api/cron/jobs" }.count, 1)
    }

    /// §4.5: a read-only gateway: every entry answers with the notice, the bar buttons are off, nothing is sent.
    @MainActor func testJE14_ReadOnlyGateway() throws {
        app = launchSignedIn(["-HQPagesReadOnly", "YES"])
        openJobs()
        XCTAssertTrue(jobRow("research|j-fail").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["jobs.new"].isEnabled, "+ is off")
        openRowMenu(jobRow("research|j-fail"))
        app.buttons["Edit Job…"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { self.hud.exists && self.hud.label == "Changes are off for this gateway." }, "the notice")
        XCTAssertFalse(app.navigationBars["Edit Job"].exists, "no sheet")
        shot("read-only")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })
        jobRow("research|j-fail").tap()
        XCTAssertTrue(app.buttons["job.error.edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["job.edit"].isEnabled, "Edit is off")
        app.buttons["job.error.edit"].tap()
        XCTAssertTrue(waitUntil(5) { self.hud.exists && self.hud.label == "Changes are off for this gateway." })
        XCTAssertFalse(app.navigationBars["Edit Job"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let list = app.collectionViews["jobs.list"]
        let blueprint = app.cells["blueprint-row-morning-brief"]
        for _ in 0..<10 where !(blueprint.exists && blueprint.isHittable) { list.swipeUp() }
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })
        blueprint.tap()
        XCTAssertTrue(waitUntil(5) { self.hud.exists && self.hud.label == "Changes are off for this gateway." })
        XCTAssertTrue(requests().allSatisfy { !($0.method == "POST" || $0.method == "PUT") || !$0.path.hasPrefix("/api/cron") }, "nothing was sent")
    }

    /// §9: the largest accessibility type: nothing clipped out of reach, the card's buttons stack.
    @MainActor func testJE15_LargestType() throws {
        app = launchSignedIn(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openNew()
        Thread.sleep(forTimeInterval: 1)
        shot("ax5-new")
        XCTAssertTrue(app.buttons["sheet.close"].isHittable && saveButton.exists, "the bar keeps ✕ and Create")
        type("job.editor.prompt", "Large type")
        pick("job.editor.frequency", "Weekly")
        pick("job.editor.day", "Friday")
        reveal(el("job.editor.summary"))
        shot("ax5-weekly")
        let note = reveal(el("job.editor.deliver.needs-home"))
        XCTAssertGreaterThan(note.frame.height, 80, "the home-channel line wraps with room")
        shot("ax5-delivery")
        reveal(app.buttons["job.editor.model"]).tap()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 5))
        shot("ax5-models")
        app.navigationBars["Model"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(5) { self.saveButton.exists && self.saveButton.isEnabled })
        saveExpecting("Job Created")
        XCTAssertEqual(writes("POST", "/api/cron/jobs").last?.body?["schedule"] as? String, "0 9 * * 5")
        XCTAssertTrue(waitUntil(10) { !self.hud.exists })
        showRow("research|j-fail").tap()
        let edit = app.buttons["job.error.edit"], run = app.buttons["job.error.run"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the card's Edit Job")
        for _ in 0..<4 where !(run.exists && run.isHittable) { app.swipeUp() }
        XCTAssertLessThanOrEqual(edit.frame.maxY, run.frame.minY + 1, "the two buttons stack")
        shot("ax5-failed-card")
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// R4: the run history is read once for triggers that land together, never in the background or after leaving.
    @MainActor func testJE17_RunsReadOnce() throws {
        app = launchSignedIn()
        openJobs()
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 10))
        jobRow("inbox|j-triage").tap()
        XCTAssertTrue(app.staticTexts["job.title"].waitForExistence(timeout: 5))
        func runs() -> [Request] { requests().filter { $0.path == "/api/cron/jobs/j-triage/runs" } }
        XCTAssertTrue(waitUntil(10) { runs().count >= 1 }, "the page reads its runs on open")
        Thread.sleep(forTimeInterval: 2.5)
        let opened = runs().count
        XCTAssertEqual(runs().first?.query["limit"], "20")
        // 1: cron.changed and a new last_run_at in the same moment → exactly one more read.
        // (the hook sends cron.changed itself)
        try account.control("/__fixture/job", ["set": ["id": "j-triage", "profile": "inbox", "last_run_at": "2026-10-13T08:00:00+00:00", "last_status": "ok"]])
        XCTAssertTrue(waitUntil(10) { runs().count > opened }, "the change is read")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(runs().count, opened + 1, "one request for the triggers that landed together")
        // A burst while a read is held open → exactly one more, after the first ends.
        try account.control("/__fixture/fail", ["method": "GET", "path": "/api/cron/jobs/j-triage/runs", "delay": 2])
        for _ in 0..<10 { try account.control("/__fixture/broadcast", ["type": "cron.changed"]) }
        Thread.sleep(forTimeInterval: 8)
        let burst = runs()
        XCTAssertLessThanOrEqual(burst.count, opened + 3, "ten events: one shared read and one trailing read (\(burst.count - opened - 1))")
        XCTAssertGreaterThanOrEqual(burst.count, opened + 2)
        if burst.count >= 2 {
            XCTAssertGreaterThanOrEqual(burst[burst.count - 1].at - burst[opened + 1].at, burst.count == opened + 3 ? 1.5 : 0, "the trailing read starts after the held one ends")
        }
        measured("runs requests: on open \(opened), after one change \(opened + 1), after a burst of ten \(burst.count)")
        // 3: leaving the page stops the reads.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let left = runs().count
        for _ in 0..<3 { try account.control("/__fixture/broadcast", ["type": "cron.changed"]) }
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(runs().count, left, "no run reads after the page is left")
    }

    /// R4 (2): nothing is read while the app is in the background; one read on return.
    @MainActor func testJE17b_RunsNotReadInTheBackground() throws {
        app = launchSignedIn()
        openJobs()
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 10))
        jobRow("inbox|j-triage").tap()
        XCTAssertTrue(app.staticTexts["job.title"].waitForExistence(timeout: 5))
        func runs() -> Int { requests().filter { $0.path == "/api/cron/jobs/j-triage/runs" }.count }
        XCTAssertTrue(waitUntil(10) { runs() >= 1 })
        Thread.sleep(forTimeInterval: 2)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        let parked = runs()
        Thread.sleep(forTimeInterval: 70)
        XCTAssertEqual(runs(), parked, "zero run reads in 70 s in the background")
        app.activate()
        XCTAssertTrue(waitUntil(10) { runs() == parked + 1 }, "one read on return (\(runs() - parked))")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(runs(), parked + 1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// D-J12: a change made elsewhere reaches an untouched form, never one being typed in.
    @MainActor func testJE18_ChangeElsewhere() throws {
        app = launchSignedIn()
        openJobs()
        editFromMenu("research|j-late", title: "Weekly reading list")
        Thread.sleep(forTimeInterval: 1.5)
        try account.control("/__fixture/job", ["set": ["id": "j-late", "profile": "research", "name": "Reading list (renamed)"]])
        XCTAssertTrue(waitUntil(15) { (self.el("job.editor.name").value as? String) == "Reading list (renamed)" }, "an untouched form takes the new name")
        XCTAssertFalse(saveButton.isEnabled, "and is still unchanged")
        type("job.editor.prompt", " My typing.")
        try account.control("/__fixture/job", ["set": ["id": "j-late", "profile": "research", "name": "Renamed again"]])
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(el("job.editor.name").value as? String, "Reading list (renamed)", "a form being typed in is left alone")
        saveExpecting("Job Saved")
        XCTAssertEqual(updates(writes("PUT", "/api/cron/jobs/j-late").last).keys.sorted(), ["prompt"], "only the person's own change is sent")
    }

    /// §11.4 (stress): an edit and a delete made while an older list read is still in flight are not undone when that
    /// read lands with the list as it was before the write.
    @MainActor func testJE19_WriteDuringAHeldListRead() throws {
        app = launchSignedIn()
        openJobs()
        XCTAssertTrue(showRow("research|j-late").exists)
        Thread.sleep(forTimeInterval: 2.5)   // the page's own first reads are over
        func listReads() -> [Request] { requests().filter { $0.method == "GET" && $0.path == "/api/cron/jobs" } }
        func released() -> Int { (((try? account.control("/__fixture/state")) ?? [:])["held_until"] as? [Any])?.count ?? 0 }
        /// A list read that answers, when released, with the list as it was when it began; the read after it is slow
        /// too, so an old answer that got through would stay on screen for seconds (long enough to be seen here).
        func hold() throws {
            let before = listReads().count
            try account.control("/__fixture/fail", ["method": "GET", "path": "/api/cron/jobs", "delay": 240, "stale": true, "hold": true])
            try account.control("/__fixture/broadcast", ["type": "cron.changed"])
            XCTAssertTrue(waitUntil(10) { listReads().count > before }, "the held list read began")
            try account.control("/__fixture/fail", ["method": "GET", "path": "/api/cron/jobs", "delay": 6])
        }
        /// Lets the held read answer and watches the row while it and the read after it land.
        func releaseAndWatch(_ cameBack: () -> Bool) throws -> Bool {
            let before = released(), reads = listReads().count
            try account.control("/__fixture/release", [:])
            XCTAssertTrue(waitUntil(5) { released() == before + 1 }, "the held read was still held when the write landed")
            var seen = false
            let until = Date().addingTimeInterval(11)
            while Date() < until {
                if cameBack() { seen = true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            XCTAssertTrue(waitUntil(10) { listReads().count > reads }, "a fresh list read followed the held one")
            return seen
        }

        // An edit during the hold.
        try hold()
        editFromMenu("research|j-late", title: "Weekly reading list")
        Thread.sleep(forTimeInterval: 1.5)
        type("job.editor.name", "Reading list renamed", replacing: true)
        saveExpecting("Job Saved")
        let row = jobRow("research|j-late")
        XCTAssertTrue(waitUntil(3) { row.staticTexts["Reading list renamed"].exists }, "the row has the new name before any list read lands")
        XCTAssertFalse(try releaseAndWatch { row.exists && row.staticTexts["Weekly reading list"].exists },
                       "the old name came back when the older read landed")
        XCTAssertTrue(row.staticTexts["Reading list renamed"].exists, "the new name stays")
        XCTAssertEqual(app.cells.matching(identifier: "job-row-research|j-late").count, 1, "one row")
        shot("held-read-edit")

        // A delete from the row menu during the hold.
        try hold()
        openRowMenu(showRow("research|j-late"))
        XCTAssertTrue(app.buttons["Delete Job"].firstMatch.waitForExistence(timeout: 3), "Delete Job is in the menu")
        app.buttons["Delete Job"].firstMatch.tap()
        // The row menu asks in an action sheet anchored to the row (an alert only on the job's page).
        XCTAssertTrue(app.staticTexts["Delete Job?"].waitForExistence(timeout: 5), "the question")
        let confirm = app.sheets.buttons["Delete Job"].firstMatch.exists ? app.sheets.buttons["Delete Job"].firstMatch
            : app.buttons.matching(NSPredicate(format: "label == %@", "Delete Job")).allElementsBoundByIndex.last { $0.isHittable } ?? app.buttons["Delete Job"].firstMatch
        confirm.tap()
        XCTAssertTrue(waitUntil(8) { !row.exists }, "the row goes")
        XCTAssertFalse(try releaseAndWatch { row.exists }, "the deleted row came back when the older read landed")
        XCTAssertEqual(writes("DELETE", "/api/cron/jobs/j-late").count, 1)
        assertNoMalformed()
    }

    /// §11.4 (stress): the editor, the model picker, a blueprint form and the failed-run card under Desktop Look skins
    /// (their own typeface and colours). Screens for the eye; the checks are that everything still opens and saves.
    @MainActor func testJE20_UnderADesktopLookSkin() throws {
        app = launchSignedIn()   // signed in under the standard look first
        app.terminate()
        for skin in ["catppuccin", "midnight"] {
            app = XCUIApplication()
            app.launchArguments = ["-HQPagesHUDSeconds", "6", "-HQDebugSkin", skin, "-HQDebugDesktopLook", "YES"]
            app.launch()
            // Desktop Look docks its own tab bar (`desktop-tab-bar`), with the tabs' ids.
            let jobs = app.buttons["tab-jobs"]
            XCTAssertTrue(jobs.waitForExistence(timeout: 30), "the look is on and the tabs show")
            jobs.tap()
            XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 10))
            XCTAssertTrue(waitUntil(15) { self.app.buttons["jobs.new"].exists && self.app.buttons["jobs.new"].isHittable }, "the + button")
            shot("skin-\(skin)-list")   // [jobfaces] the owners' faces beside the rows in the look
            openNew()
            shot("skin-\(skin)-new")
            type("job.editor.prompt", "Say hello from \(skin)")
            reveal(app.buttons["job.editor.model"]).tap()
            XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 5), "the model picker opens")
            shot("skin-\(skin)-models")
            app.navigationBars["Model"].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["New Job"].waitForExistence(timeout: 5))
            saveExpecting("Job Created")
            XCTAssertEqual(writes("POST", "/api/cron/jobs").last?.body?["prompt"] as? String, "Say hello from \(skin)")
            XCTAssertTrue(waitUntil(10) { !self.hud.exists })
            showRow("research|j-fail").tap()
            XCTAssertTrue(app.buttons["job.error.edit"].waitForExistence(timeout: 5))
            shot("skin-\(skin)-detail-failed")
            app.buttons["job.error.edit"].tap()
            XCTAssertTrue(app.navigationBars["Edit Job"].waitForExistence(timeout: 5))
            shot("skin-\(skin)-edit")
            closeSheet()
            app.terminate()
        }
        // Leave the simulator on the standard look for whatever runs next.
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetTheme", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 30), "the system tab bar is back")
        app.terminate()
    }

    func measured(_ text: String) { XCTContext.runActivity(named: "[measure] " + text) { _ in } }
}

/// R1 (§6.1): 1 000 jobs in one continuous list (scripts/e2e-jobs.sh runs it against a `--jobs 1000` fixture).
final class JobEditorLongListTests: JobEditorCase {
    func measured(_ text: String) { XCTContext.runActivity(named: "[measure] " + text) { _ in } }

    @MainActor func testJE16_ThousandJobs() throws {
        let state = try account.control("/__fixture/state")
        guard (state["jobs"] as? Int ?? 0) >= 1000 else { throw XCTSkip("Runs against the --jobs 1000 fixture (scripts/e2e-jobs.sh starts it).") }
        app = launchSignedIn()
        let started = Date()
        tab("Jobs")
        let list = app.collectionViews["jobs.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let count = app.staticTexts["pages.count"]
        XCTAssertTrue(waitUntil(20) { list.cells.count > 5 }, "the list paints")
        measured("first rows of 1011 jobs after \(String(format: "%.2f", Date().timeIntervalSince(started))) s (includes the tab switch and the read)")
        shot("long-list")
        // No pager anywhere: one continuous list per section.
        XCTAssertFalse(app.buttons["Next"].exists || app.buttons["Previous"].exists, "no pager")
        // Scroll a long way: rows keep coming, the app stays responsive.
        let scrollStart = Date()
        for _ in 0..<12 { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(list.cells.firstMatch.exists)
        measured("12 fast swipes through the list took \(String(format: "%.2f", Date().timeIntervalSince(scrollStart))) s")
        XCTAssertLessThan(list.cells.count, 60, "only what is near the screen exists (\(list.cells.count) cells)")
        shot("long-list-scrolled")
        // Search filters at typing speed.
        let search = app.navigationBars.buttons["Search"].firstMatch
        if search.exists { search.tap() }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let typed = Date()
        field.typeText("Disk check 701")
        XCTAssertTrue(waitUntil(5) { self.app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'job-row-' AND label CONTAINS 'Disk check 701'")).count >= 1
                                     || self.app.staticTexts["Disk check 701"].exists }, "the one job is found")
        measured("typing 14 characters and finding the row took \(String(format: "%.2f", Date().timeIntervalSince(typed))) s")
        XCTAssertTrue(waitUntil(5) { count.exists && count.label.hasPrefix("1 of ") }, count.exists ? count.label : "no count")
        shot("long-list-search")
        let closeSearch = app.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'Close', 'close'}")).firstMatch
        if closeSearch.exists { closeSearch.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.905, dy: 0.097)).tap() }
        XCTAssertTrue(waitUntil(5) { self.app.buttons["jobs.new"].exists }, "search closes")
        // The editor opens and closes over the long list.
        for _ in 0..<5 {
            XCTAssertTrue(waitUntil(5) { self.app.buttons["jobs.new"].isHittable })
            app.buttons["jobs.new"].tap()
            XCTAssertTrue(app.navigationBars["New Job"].waitForExistence(timeout: 5))
            app.buttons["sheet.close"].firstMatch.tap()
            XCTAssertTrue(waitUntil(5) { !self.app.otherElements["job.editor"].exists })
        }
        // A relaunch paints from the cache before the gateway answers.
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()
        for _ in 0..<3 { try account.control("/__fixture/fail", ["method": "GET", "path": "/api/cron/jobs", "delay": 6]) }
        app = XCUIApplication()
        app.launch()
        let relaunched = Date()
        XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(3) { self.app.collectionViews["jobs.list"].cells.count > 5 }, "rows from the cache")
        XCTAssertLessThan(Date().timeIntervalSince(relaunched), 5.5, "before the list read could answer")
        measured("relaunch painted cached rows \(String(format: "%.2f", Date().timeIntervalSince(relaunched))) s after the list appeared")
        tab("Bots")
    }
}
