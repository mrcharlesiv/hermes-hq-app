// More › Spawn Tree, end to end against the stand-in gateway (docs/spec/3x-morepages.md §16 acceptance, §21):
// scripts/fixtures/morepages/delegation.py answers `delegation.status`; `POST /__fixture/delegation` changes the tree.

import XCTest

final class SpawnTreeUITests: MorePagesCase {
    private func mode(_ mode: String, delay: Double = 0) throws { _ = try account.control("/__fixture/delegation", ["mode": mode, "delay": delay]) }

    @MainActor private func words(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    @MainActor private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)["spawn-tree.row.\(id)"].firstMatch }

    @MainActor private func openSpawnTree() {
        launchSignedIn()
        // At a large text size More's list makes this row only once it scrolls into view.
        tab("More")
        let cell = app.cells["more-row-spawn-tree"]
        for _ in 0..<6 where !cell.waitForExistence(timeout: 3) { app.swipeUp(velocity: .slow) }
        openMore("spawn-tree")
        XCTAssertTrue(app.navigationBars["Spawn Tree"].waitForExistence(timeout: 10), "the page's small title")
    }

    @MainActor func testU15_SpawnTree() throws {
        openSpawnTree()
        // The tree, grouped by bot then chat, with indents.
        XCTAssertTrue(words("14 subagents · 10 active").waitForExistence(timeout: 15), "the header counts")
        XCTAssertTrue(words("Ship the 2.4 release notes").exists, "the owning chat's title, from the app's sessions")
        let root = row("sa-r1"), child = row("sa-r2"), grandchild = row("sa-r3")
        XCTAssertTrue(root.waitForExistence(timeout: 5) && child.exists && grandchild.exists)
        // The model by its name, not its slug ("claude-opus-5" reads "Opus 5").
        XCTAssertTrue(child.label.contains("Opus 5, 7 tools") || words("Opus 5 · 7 tools · running").exists, "the row text: \(child.label)")
        // A row's element is its whole cell, so the level is read from its label (the indent itself is looked at in the screenshot).
        XCTAssertFalse(root.label.contains("level"), root.label)
        XCTAssertTrue(child.label.hasSuffix("level 2"), child.label)
        XCTAssertTrue(grandchild.label.hasSuffix("level 3"), grandchild.label)
        shot("spawn-tree")
        app.swipeUp()
        XCTAssertTrue(words("Research").waitForExistence(timeout: 5) || words("RESEARCH").exists, "the second bot's group")
        shot("spawn-tree-second-bot")
        app.swipeDown()

        // The gateway saw only {"profile": …}, one call per bot each round.
        let calls = try rpc("delegation.status")
        XCTAssertFalse(calls.isEmpty)
        for call in calls {
            let keys = Set((call["params"] as? [String: Any] ?? [:]).keys)
            XCTAssertTrue(keys.isSubset(of: ["profile"]), "only profile is sent: \(keys)")
        }
        let profiles = Set(calls.compactMap { ($0["params"] as? [String: Any])?["profile"] as? String })
        XCTAssertEqual(profiles, ["inbox", "deploys", "research", "finance"], "one call per named bot (the default bot sends no key)")

        // Tapping a row opens its chat; Back returns to the tree.
        child.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens over More")
        XCTAssertTrue(words("Ship the 2.4 release notes").waitForExistence(timeout: 10))
        shot("spawn-tree-chat")
        back()
        XCTAssertTrue(app.navigationBars["Spawn Tree"].waitForExistence(timeout: 10))

        // The knob removes every child: the empty state within 4 s (the page reads every 3 s).
        XCTAssertTrue(row("sa-r1").waitForExistence(timeout: 10))
        try mode("empty")
        XCTAssertTrue(words("No Subagents Running").waitForExistence(timeout: 4), "the empty state within 4 s")
        XCTAssertTrue(words("When a bot hands work to helpers, they show up here while they run.").exists)
        shot("spawn-tree-empty")
        try mode("seed")
        XCTAssertTrue(row("sa-r1").waitForExistence(timeout: 6), "the tree comes back by itself")
    }

    @MainActor func testPausedNotice() throws {
        try mode("paused")
        openSpawnTree()
        XCTAssertTrue(words("New subagents are paused on this gateway.").waitForExistence(timeout: 15))
        XCTAssertTrue(words("14 subagents").exists)
        shot("spawn-tree-paused")
    }

    @MainActor func testFourHundredSubagentsSixDeep() throws {
        try mode("big")
        let start = Date()
        openSpawnTree()
        XCTAssertTrue(words("400 subagents").waitForExistence(timeout: 20), "400 rows; the two repeated ids are dropped")
        measured("400 subagents: \(String(format: "%.2f", Date().timeIntervalSince(start))) s from launch to the header")
        // Oldest first: helper 295 leads its chat, and its chain runs six deep.
        let first = row("sa-b294"), deep = row("sa-b299")
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the oldest helper leads its chat")
        shot("spawn-tree-400")
        // Rows are made as they scroll into view: the sixth level is a little further down.
        for _ in 0..<3 where !deep.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(deep.exists, "the sixth level")
        XCTAssertTrue(deep.label.hasSuffix("level 6"), deep.label)
        shot("spawn-tree-400-deep")
        for _ in 0..<8 { app.swipeUp(velocity: .fast) }
        shot("spawn-tree-400-scrolled")
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.navigationBars["Spawn Tree"].exists, "still here after fast scrolling and three refreshes")
    }

    @MainActor func testOddRecordsAndOneProcessForEveryBot() throws {
        try mode("odd")
        openSpawnTree()
        XCTAssertTrue(words("An orphan whose parent already finished").waitForExistence(timeout: 15), "an orphan is a root")
        XCTAssertTrue(words("One half of a cycle").exists && words("The other half of a cycle").exists, "a cycle is broken, both rows show")
        XCTAssertTrue(words("Its own parent").exists)
        XCTAssertTrue(words("6 subagents").exists, "records without an id are skipped")
        shot("spawn-tree-odd")
        // A gateway that answers the whole list for every bot: each subagent shows once, under the bot that owns its chat.
        try mode("global")
        XCTAssertTrue(words("14 subagents · 10 active").waitForExistence(timeout: 8))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "spawn-tree.row.sa-r1").count, 1)
    }

    @MainActor func testDelayedFirstReadThenFailureThenTryAgain() throws {
        try mode("error", delay: 3)
        openSpawnTree()
        XCTAssertTrue(app.descendants(matching: .any)["more.page.loading"].waitForExistence(timeout: 3), "the skeleton while the read is slow")
        XCTAssertTrue(words("Couldn’t Load Spawn Tree").waitForExistence(timeout: 30))
        XCTAssertTrue(words("The delegation registry is not available.").exists, "the gateway's reason")
        shot("spawn-tree-error")
        try mode("seed")
        app.buttons["Try Again"].tap()
        XCTAssertTrue(row("sa-r1").waitForExistence(timeout: 15), "Try Again reads the tree")
        // A later failure keeps the tree on screen.
        try mode("error")
        XCTAssertTrue(words("Couldn’t refresh. Showing the last list.").waitForExistence(timeout: 8))
        XCTAssertTrue(row("sa-r1").exists)
        try mode("seed")
    }

    @MainActor func testRelaunchOnThePage() throws {
        openSpawnTree()
        XCTAssertTrue(row("sa-r1").waitForExistence(timeout: 15))
        relaunch()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 20), "the tab bar shows after a relaunch")
        if app.navigationBars["Spawn Tree"].waitForExistence(timeout: 5) {
            XCTAssertTrue(row("sa-r1").waitForExistence(timeout: 15), "a restored page reads again")
            back()
            XCTAssertTrue(app.cells["more-row-spawn-tree"].waitForExistence(timeout: 10), "Back leads to More")
        }
        openMore("spawn-tree")
        XCTAssertTrue(row("sa-r1").waitForExistence(timeout: 15))
    }

    /// Last by name: the row is hidden on this simulator until the next launch's probe finds the method again.
    @MainActor func testZOlderHermesHidesTheRow() throws {
        launchSignedIn()
        XCTAssertTrue(revealMore("spawn-tree", timeout: 15).exists)   // [morepages] the merged More list scrolls
        try mode("missing")
        app.cells["more-row-spawn-tree"].tap()
        XCTAssertTrue(words("Not Available on This Hermes").waitForExistence(timeout: 15), "the older-Hermes state")
        shot("spawn-tree-older-hermes")
        back()
        XCTAssertTrue(waitUntil(10) { !self.app.cells["more-row-spawn-tree"].exists }, "the row is hidden next time")
        try mode("seed")
        relaunch()
        XCTAssertTrue(revealMore("spawn-tree", timeout: 20).exists, "it comes back when the gateway answers again")
    }

    /// The tree at any text size (the pass at a large size uses it).
    @MainActor func testLooksAtAnyTextSize() throws {
        openSpawnTree()
        XCTAssertTrue(words("14 subagents · 10 active").waitForExistence(timeout: 15))
        shot("spawn-tree-size")
        app.swipeUp()
        shot("spawn-tree-size-2")
        try mode("empty")
        XCTAssertTrue(words("No Subagents Running").waitForExistence(timeout: 6))
        shot("spawn-tree-size-empty")
    }
}
