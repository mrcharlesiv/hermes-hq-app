// ⋯ › Prompts, Usage & Limits and Model Prices (TestFlight feedback 2026-10-24) against the menus fixture, whose
// catalog carries prices, subscription windows, a pool and a rate-limited login (scripts/fixtures/menus-gateway.py
// `catalog_providers`). Run with scripts/e2e-menus.sh (HQN_MENUS_ONLY=test30_PromptsUsagePrices). test31 and test32
// are tester batch 3's pay-as-you-go balances (HQN_MENUS_ONLY=test31_PayAsYouGoBalances,test32_BalanceUnderAPlansBars).

import XCTest

extension MenusTests {
    @MainActor func test30_PromptsUsagePrices() throws {
        let (account, app) = try start()
        openBotChat(app)

        // The three rows under Model; the second open's subtitles come from the warmed catalog.
        openMore(app)
        XCTAssertTrue(app.buttons["chat.more.prompts"].waitForExistence(timeout: 3), "Prompts")
        XCTAssertTrue(app.buttons["chat.more.usage"].exists, "Usage & Limits")
        XCTAssertTrue(app.buttons["chat.more.prices"].exists, "Model Prices")
        dismissMenu(app)
        XCTAssertTrue(waitUntil(timeout: 5) { self.calls(account, "model.options").count == 1 }, "the warm-up read")
        Thread.sleep(forTimeInterval: 0.5)
        openMore(app)
        XCTAssertEqual(menuItem(app, "Usage & Limits").label, "Usage & Limits, Opus weekly · 6% left")
        XCTAssertEqual(menuItem(app, "Model Prices").label, "Model Prices, $3.00 in · $15.00 out")
        shot(app, "extras-more-menu")

        // Prompts: empty, then a new one, then a tap puts it in the message box.
        app.buttons["chat.more.prompts"].tap()
        XCTAssertTrue(app.otherElements["prompts.empty"].waitForExistence(timeout: 5)
                      || labelled(app, "No Prompts Yet").waitForExistence(timeout: 2), "the empty library")
        shot(app, "extras-prompts-empty")
        XCTAssertFalse(app.buttons["prompts.edit"].exists, "nothing to edit yet")
        app.buttons["prompts.add"].tap()
        let title = app.textFields["prompt.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Weekly update")
        let text = app.textViews["prompt.text"]
        text.tap()
        text.typeText("Draft my weekly status update from this chat, in three short bullets.")
        shot(app, "extras-prompt-editor")
        app.buttons["prompt.save"].tap()
        let row = app.buttons["prompts.row.Weekly update"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the saved prompt is listed")
        shot(app, "extras-prompts-list")
        XCTAssertTrue(app.buttons["prompts.edit"].exists, "Edit once there is a prompt")
        row.tap()
        let field = app.textViews["composer.text"]
        XCTAssertTrue(waitUntil(timeout: 5) { (field.value as? String)?.hasPrefix("Draft my weekly status update") == true },
                      "the prompt is in the message box")
        shot(app, "extras-prompt-inserted")
        field.typeText(" Hello there")
        app.buttons["composer.send"].tap()
        let mine = message(app, containing: "Hello there")
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)

        // Your own message's hold menu saves it as a prompt.
        mine.press(forDuration: 0.9)
        let save = app.buttons["message.savePrompt"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save as Prompt on your message")
        shot(app, "extras-hold-save-prompt")
        save.tap()
        openMore(app)
        XCTAssertEqual(menuItem(app, "Prompts").label, "Prompts, 2 saved")

        // Usage & Limits: bars per window, a pool's logins, a rate limit, this chat, credits, the /usage report.
        app.buttons["chat.more.usage"].tap()
        XCTAssertTrue(app.otherElements["usage.gauge.anthropic.2"].waitForExistence(timeout: 10)
                      || labelled(app, "Opus weekly").waitForExistence(timeout: 2), "Anthropic's windows")
        // Owner 2026-10-30: the chat's tightest allowance leads (Anthropic's Opus weekly, 6% left), with its pace.
        let lead = app.descendants(matching: .any)["usage.headline"]
        XCTAssertTrue(lead.waitForExistence(timeout: 5), "the At a Glance card")
        XCTAssertTrue(lead.label.contains("Opus weekly"), lead.label)
        XCTAssertTrue(app.buttons["usage.remind.anthropic.2"].exists, "a bell on the low allowance")
        shot(app, "extras-usage")
        app.swipeUp()
        // The At a Glance card pushed the pool's used-up login below the first screen (a List draws only what shows).
        let usedUp = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Used up'")).firstMatch
        XCTAssertTrue(labelled(app, "Rate limited").exists || usedUp.waitForExistence(timeout: 3), "the used-up login's note")
        shot(app, "extras-usage-middle")
        // [tester batch 3] OpenRouter pays as it goes: its balance is its own chats' to read, this one is on Anthropic.
        // [owner 2026-10-30] With no balance here it is folded under Balance not reported, at the foot of the page.
        let router = app.descendants(matching: .any)["usage.balance.openrouter"]
        let quiet = app.buttons["usage.balances.quiet"]
        for _ in 0..<4 where !(quiet.exists && quiet.isHittable) { app.swipeUp() }
        XCTAssertFalse(router.exists, "folded")
        quiet.tap()
        for _ in 0..<2 where !router.exists { app.swipeUp() }
        XCTAssertTrue(waitUntil(timeout: 5) { router.exists }, "OpenRouter under the fold")
        XCTAssertTrue(router.label.contains("Shows in a chat that uses it"), router.label)
        XCTAssertTrue(labelled(app, "Nous credits: $4.20 left").waitForExistence(timeout: 5), "credits from session.usage")
        shot(app, "extras-usage-bottom")
        let asked = calls(account, "slash.exec").filter { ($0["command"] as? String) == "usage" }.count
        let report = app.buttons["usage.report"]
        for _ in 0..<3 where !report.isHittable { app.swipeUp() }   // the page is longer since the redesign
        report.tap()
        XCTAssertTrue(app.navigationBars["Usage Report"].waitForExistence(timeout: 10), "the /usage report")
        shot(app, "extras-usage-report")
        XCTAssertEqual(calls(account, "slash.exec").filter { ($0["command"] as? String) == "usage" }.count, asked + 1, "the report asked /usage")
        app.navigationBars["Usage Report"].buttons.firstMatch.tap()
        let close = app.buttons["sheet.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3), "back on Usage & Limits")
        close.tap()
        Thread.sleep(forTimeInterval: 0.8)

        // Model Prices: the chat's provider first, its model checked; a subscription says Included; search narrows.
        openMore(app)
        app.buttons["chat.more.prices"].tap()
        XCTAssertTrue(app.otherElements["prices.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10)
                      || labelled(app, "$3.00 in · $15.00 out · $0.30 cached").waitForExistence(timeout: 2), "Anthropic's prices")
        shot(app, "extras-prices")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("gpt")
        Thread.sleep(forTimeInterval: 0.8)
        shot(app, "extras-prices-search")
        try assertWireClean(account)
    }

    /// [tester batch 3] Usage & Limits gives each pay-as-you-go login a balance where Hermes reports one, and says when
    /// it can't: the chat is on OpenRouter (its /usage says "Credits balance: $12.34"), signed in to Nous (billing.state,
    /// the main bot's chat, and its /usage say $7.50 to spend; billing.state's account balance, $3.40, is not shown) and
    /// a DeepSeek key (no balance anywhere, folded under Balance not reported). Checking while /usage is
    /// slow; Couldn't check with the reason when it fails, Check Again; Offline for what a read would fill when the
    /// connection goes (by itself, the page follows the connection), the figures read before it staying, and read again
    /// when it comes back. With HQN_MENUS_AX3=1 the rows below the first screen are scrolled to.
    @MainActor func test31_PayAsYouGoBalances() throws {
        let ax3 = ProcessInfo.processInfo.environment["HQN_UI_AX3"] == "1"
        let (account, app) = try start()
        try account.control("/__menus/mode", ["balances": true, "slowExec": 4])
        try account.control("/__menus/model", ["profile": "default", "model": "moonshotai/kimi-k2-thinking", "provider": "openrouter"])
        openBotChat(app)
        openMore(app)
        let usage = app.buttons["chat.more.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 3))
        usage.tap()
        let router = app.descendants(matching: .any)["usage.balance.openrouter"]
        let nous = app.descendants(matching: .any)["usage.balance.nous"]
        let deepseek = app.descendants(matching: .any)["usage.balance.deepseek"]
        // /usage takes 4 s: OpenRouter is still being checked while billing.state has already given Nous's.
        XCTAssertTrue(waitUntil(timeout: 10) { router.exists && router.label.contains("Checking…") }, "checking: \(router.label)")
        XCTAssertTrue(router.label.hasPrefix("OpenRouter · This Chat"), router.label)
        XCTAssertTrue(waitUntil(timeout: 4) { nous.label.contains("$7.50") }, "Nous from billing.state: \(nous.label)")
        XCTAssertFalse(nous.label.contains("$3.40"), "the credits it can spend, not the account balance: \(nous.label)")
        let quiet = app.buttons["usage.balances.quiet"]
        XCTAssertFalse(deepseek.exists, "a key has none: folded away")
        shot(app, "usage-balances-checking")
        XCTAssertTrue(waitUntil(timeout: 10) { router.label.contains("$12.34") }, "OpenRouter's balance: \(router.label)")
        XCTAssertTrue(nous.label.contains("$7.50") && !deepseek.exists)
        XCTAssertTrue(labelled(app, "Pay As You Go").exists || app.staticTexts["PAY AS YOU GO"].exists, "the section")
        shot(app, "usage-balances")
        let footer = app.descendants(matching: .any)["usage.balances.footer"]
        reveal(app, footer)
        XCTAssertTrue(footer.exists, "the footer says whose figures these are")
        // The fold opens to the logins with no balance.
        reveal(app, quiet)
        XCTAssertTrue(quiet.label.contains("Balance not reported"), quiet.label)
        quiet.tap()
        for _ in 0..<2 where !deepseek.waitForExistence(timeout: 1) { app.swipeUp() }
        shot(app, "usage-balances-folded-open")
        XCTAssertTrue(deepseek.exists, "DeepSeek under the fold")
        // On the wire: /usage from this chat (its session), billing.state with no more than `profile`.
        let report = try XCTUnwrap(calls(account, "slash.exec").last { ($0["command"] as? String) == "usage" })
        XCTAssertNotNil(report["session_id"], "/usage asks this chat")
        let billing = calls(account, "billing.state")
        XCTAssertEqual(billing.count, 1, "billing.state once")
        XCTAssertTrue(billing.allSatisfy { Set($0.keys).isSubset(of: ["profile"]) }, "billing.state takes only profile: \(billing)")
        let close = app.buttons["sheet.close"].firstMatch
        close.tap()
        Thread.sleep(forTimeInterval: 0.8)

        // /usage fails: OpenRouter says it couldn't check and why; Nous still has billing.state's; Check Again recovers.
        try account.control("/__menus/mode", ["usageFail": true, "slowExec": 0])
        openMore(app)
        usage.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { router.exists && router.label.contains("Couldn’t check") }, "failed: \(router.label)")
        XCTAssertTrue(router.label.contains("usage report failed (fixture)"), "the reason: \(router.label)")
        XCTAssertTrue(waitUntil(timeout: 4) { nous.label.contains("$7.50") }, "Nous from billing.state: \(nous.label)")
        let retry = app.buttons["usage.balances.retry"]
        shot(app, "usage-balances-failed")
        reveal(app, retry)
        XCTAssertTrue(retry.exists, "Check Again")
        try account.control("/__menus/mode", ["usageFail": false])
        retry.tap()
        // At AX3 OpenRouter's row has scrolled away: Check Again going is the sign its check came back.
        XCTAssertTrue(waitUntil(timeout: 10) { !retry.exists }, "nothing left to check again")
        if !ax3 { XCTAssertTrue(router.label.contains("$12.34"), "checked again: \(router.label)") }

        // The connection goes with a check failed: Nous's figure stays, OpenRouter's unknown one says Offline.
        close.tap()
        Thread.sleep(forTimeInterval: 0.8)
        try account.control("/__menus/mode", ["usageFail": true])
        openMore(app)
        usage.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { router.exists && router.label.contains("Couldn’t check") }, "failed again: \(router.label)")
        try account.control("/__menus/mode", ["offline": true])
        // The page follows the connection: no tap, the row a read would fill says Offline once the app knows.
        XCTAssertTrue(waitUntil(timeout: 20) { router.label.contains("Offline") }, "offline: \(router.label)")
        XCTAssertTrue(nous.label.contains("$7.50"), "the figure read before stays: \(nous.label)")
        XCTAssertFalse(deepseek.exists, "still folded")
        shot(app, "usage-balances-offline")
        // Back online, the Offline row is read again by itself.
        try account.control("/__menus/mode", ["offline": false, "usageFail": false])
        XCTAssertTrue(waitUntil(timeout: 30) { router.label.contains("$12.34") }, "read again once back online: \(router.label)")
        close.tap()
        // At AX3 the field has no room for "Message Hermes" and says "Message" (ComposerView.shownPlaceholder).
        XCTAssertTrue(waitUntil(timeout: 30) { (app.textViews["composer.text"].placeholderValue ?? "").hasPrefix("Message")
            || app.staticTexts["Message Hermes"].exists || app.staticTexts["Message"].exists }, "back online")
        try assertWireClean(account)
    }

    /// [tester batch 3] A pay-as-you-go login that shows as a plan keeps its balance: the chat's OpenRouter key has a
    /// spending limit (an "API key quota" window), so OpenRouter is a block with a bar, and the Credits balance /usage
    /// gives sits under that bar. No Pay As You Go section is left (Anthropic and Codex are plans too).
    @MainActor func test32_BalanceUnderAPlansBars() throws {
        let (account, app) = try start()
        try account.control("/__menus/mode", ["routerQuota": true])
        try account.control("/__menus/model", ["profile": "default", "model": "moonshotai/kimi-k2-thinking", "provider": "openrouter"])
        openBotChat(app)
        openMore(app)
        let usage = app.buttons["chat.more.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 3))
        usage.tap()
        let router = app.descendants(matching: .any)["usage.balance.openrouter"]
        XCTAssertTrue(waitUntil(timeout: 10) { router.exists && router.label.contains("$12.34") }, "the balance: \(router.label)")
        XCTAssertTrue(router.label.hasPrefix("Credits balance"), router.label)
        let quota = labelled(app, "API key quota")
        XCTAssertTrue(quota.exists, "the key's window")
        XCTAssertGreaterThan(router.frame.minY, quota.frame.minY, "under the bar")
        XCTAssertTrue(labelled(app, "OpenRouter · This Chat").exists || app.staticTexts["OPENROUTER · THIS CHAT"].exists, "its block")
        XCTAssertFalse(app.descendants(matching: .any)["usage.balances.footer"].exists, "no Pay As You Go section")
        shot(app, "usage-balance-under-bars")
        XCTAssertEqual(calls(account, "slash.exec").filter { ($0["command"] as? String) == "usage" }.count, 1, "/usage once")
        app.buttons["sheet.close"].firstMatch.tap()
        try assertWireClean(account)
    }

    /// At the largest text sizes a row can be a scroll away: swipe the page up until it can be tapped, slowly (a flick
    /// can carry a short row past the window and out of the tree), and back down if it went past.
    @MainActor func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeDown(velocity: .slow) }
    }
}
