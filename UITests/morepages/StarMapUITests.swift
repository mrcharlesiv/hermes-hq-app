// More › Star Map, end to end against the morepages stand-in (docs/spec/3x-morepages.md §17 acceptance 2 and 3, and
// the Star Map lines of the stress plan §21). The graph comes from scripts/fixtures/morepages/learning.py:
// POST /__fixture/graph {"nodes": N, "edges": E, "memory": M, "delay": s, "fail": {"status", "count"}}.
//
//   HQN_MOREPAGES_GATEWAYS="main" HQN_MOREPAGES_PORTS="<port>" HQN_MOREPAGES_ONLY="StarMapUITests" scripts/e2e-morepages.sh <udid>
//
// `-HQStarMapDebug YES` adds the element `starmap.debug` (JSON: the zoom, the counts, where a few stars are);
// `-HQStarMapProbe YES` runs the scripted 5 s pan and zoom and leaves its frame times in `starmap.probe`.

import XCTest

final class StarMapUITests: MorePagesCase {
    // MARK: Helpers

    /// The Map on show whatever an earlier test left chosen (a launch argument reads over the saved choice), and the
    /// debug element.
    static let onMap = ["-HQStarMapDebug", "YES", "-pages.more.starmap.view", "map"]

    private func graph(_ knobs: [String: Any]) throws { try account.control("/__fixture/graph", knobs) }

    @MainActor private var canvas: XCUIElement { app.descendants(matching: .any)["starmap.canvas"] }
    @MainActor private var subtitle: String { app.staticTexts["starmap.subtitle"].label }

    /// The canvas's spoken zoom ("100 percent") as a factor.
    @MainActor private var zoom: Double {
        let value = (canvas.value as? String) ?? ""
        return (Double(value.split(separator: " ").first ?? "") ?? 0) / 100
    }

    @MainActor private func debug() -> [String: Any] {
        let value = app.descendants(matching: .any)["starmap.debug"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? [:]
    }

    /// More › Star Map, with the Map on show and its stars flown in.
    @MainActor private func openMap(_ arguments: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        launchSignedIn(Self.onMap + arguments)
        openMore("star-map")
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "the map is on show", file: file, line: line)
        XCTAssertTrue(waitUntil(10) { self.debug()["flown"] as? Bool == true }, "the stars flew in", file: file, line: line)
    }

    @MainActor private func mode(_ name: String) {
        let button = app.segmentedControls["starmap.mode"].buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the \(name) segment")
        button.tap()
    }

    @MainActor private func filter(_ name: String) {
        app.buttons["starmap.filter"].tap()
        let choice = app.buttons[name]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the filter menu offers \(name)")
        choice.tap()
    }

    /// Taps the canvas at a point in its own coordinates.
    @MainActor private func tapCanvas(x: Double, y: Double) {
        canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
    }

    @MainActor private func closeSheet() {
        let title = app.staticTexts["starmap.node.title"]
        // A tap on the dimmed page above a medium sheet closes it; a drag from its grabber is the fallback.
        for attempt in 0..<4 where title.exists {
            if attempt % 2 == 0 {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            } else {
                let from = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -24))
                from.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            }
            _ = waitUntil(3) { !title.exists }
        }
        XCTAssertFalse(title.exists, "the node sheet closed")
    }

    /// The skills the List's section headers add up to ("Coding · 11" …), read while scrolling to the Memory section.
    @MainActor private func listedSkills() -> (skills: Int, categories: Int) {
        var counts: [String: Int] = [:]
        let headers = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'starmap.section.'"))
        for _ in 0..<30 {
            for index in 0..<headers.count {
                let header = headers.element(boundBy: index)
                guard header.exists, header.identifier != "starmap.section.memory-cards" else { continue }
                if let number = header.label.split(separator: " ").last.flatMap({ Int($0) }) { counts[header.identifier] = number }
            }
            if app.staticTexts["starmap.section.memory-cards"].exists { break }
            app.swipeUp(velocity: .slow)
        }
        return (counts.values.reduce(0, +), counts.count)
    }

    // MARK: Acceptance (§17.2)

    @MainActor func testU16_StarMap() throws {
        openMap()
        XCTAssertTrue(app.navigationBars["Star Map"].exists, "the small title on the bar row")
        XCTAssertEqual(subtitle, "60 skills across 12 categories")
        let first = debug()
        XCTAssertEqual(first["stars"] as? Int, 100, "60 skills and 40 memories are stars; the three bad rows are skipped")
        XCTAssertEqual(first["clusters"] as? Int, 13)
        XCTAssertGreaterThan(first["edges"] as? Int ?? 0, 100)
        XCTAssertEqual(try rest("GET", "/api/learning/graph").last?["query"] as? [String: String] ?? [:], [:], "the default bot sends no profile")
        shot("starmap-map")

        // Pinch: the scale changes, both ways, and stops at its limits.
        let start = zoom
        XCTAssertGreaterThan(start, 0.3)
        XCTAssertLessThanOrEqual(start, 1.0)
        canvas.pinch(withScale: 2.2, velocity: 1.5)
        XCTAssertTrue(waitUntil(5) { self.zoom > start * 1.3 }, "pinching out zooms in: \(start) → \(zoom)")
        for _ in 0..<4 where zoom < 2 { canvas.pinch(withScale: 2, velocity: 1.5) }
        XCTAssertGreaterThan(zoom, 1.6)
        XCTAssertLessThanOrEqual(zoom, 4.0)
        let zoomed = zoom
        canvas.pinch(withScale: 0.4, velocity: -1.5)
        XCTAssertTrue(waitUntil(5) { self.zoom < zoomed * 0.8 }, "pinching in zooms out: \(zoomed) → \(zoom)")
        for _ in 0..<8 where zoom > 0.51 { canvas.pinch(withScale: 0.3, velocity: -2) }
        XCTAssertGreaterThanOrEqual(zoom, 0.3, "never smaller than its floor")

        // A double tap away from any cluster frames the whole map again; a pan moves it.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).doubleTap()
        _ = waitUntil(3) { abs(self.zoom - start) < 0.02 }
        canvas.swipeLeft(velocity: .slow)
        XCTAssertTrue(app.staticTexts["starmap.subtitle"].exists, "a pan on the map does not swipe the page away")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).doubleTap()
        XCTAssertTrue(waitUntil(5) { !(self.debug()["points"] as? [[String: Any]] ?? []).isEmpty }, "stars are back in view")

        // A double tap on a cluster frames it: above 1.6× its stars are named.
        let target = try XCTUnwrap((debug()["points"] as? [[String: Any]] ?? []).first { ($0["id"] as? String) == "retired-notes" }, "Coding's top star")
        canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: try XCTUnwrap(target["x"] as? Double), dy: try XCTUnwrap(target["y"] as? Double))).doubleTap()
        XCTAssertTrue(waitUntil(5) { self.zoom > 1.6 }, "the cluster is framed with star names on: \(zoom)")
        XCTAssertFalse(app.staticTexts["starmap.node.title"].exists, "a double tap is not a tap on a star")
        shot("starmap-zoomed")
        // A second double tap on the framed cluster shows the whole map again.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(waitUntil(5) { abs(self.zoom - start) < 0.02 && (self.debug()["points"] as? [[String: Any]] ?? []).count > 3 }, "the whole map again: \(zoom)")

        // Tap a star: its sheet, with the facts from the graph and the text from /api/learning/node.
        let points = debug()["points"] as? [[String: Any]] ?? []
        let star = try XCTUnwrap(points.first { ($0["id"] as? String).map { !$0.hasPrefix("memory:") && $0 != "retired-notes" } ?? false }, "a skill star on screen: \(points)")
        let id = try XCTUnwrap(star["id"] as? String)
        tapCanvas(x: try XCTUnwrap(star["x"] as? Double), y: try XCTUnwrap(star["y"] as? Double))
        let title = app.staticTexts["starmap.node.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "tapping a star opens its sheet")
        XCTAssertEqual(title.label, id, "the nearest star wins")
        let text = app.staticTexts["starmap.node.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "the node's text arrived")
        XCTAssertTrue(text.label.contains("name: \(id)"), text.label)
        XCTAssertTrue(app.staticTexts["Skill"].exists && app.staticTexts["Category"].exists, "the facts")
        let asked = try rest("GET", "/api/learning/node").last?["query"] as? [String: String]
        XCTAssertEqual(asked, ["id": id], "exactly the id is sent for the default bot")
        shot("starmap-node")
        closeSheet()

        // List: the same count as the subtitle.
        mode("List")
        XCTAssertTrue(app.collectionViews["starmap.list"].waitForExistence(timeout: 10) || app.tables["starmap.list"].exists, "the list")
        XCTAssertEqual(subtitle, "60 skills across 12 categories")
        shot("starmap-list")
        let listed = listedSkills()
        XCTAssertEqual(listed.skills, 60, "the List's sections add up to the subtitle's count")
        XCTAssertEqual(listed.categories, 12)
        XCTAssertTrue(app.staticTexts["starmap.section.memory-cards"].exists, "then the Memory section")
        app.swipeUp(velocity: .slow)
        shot("starmap-list-memory")
    }

    @MainActor func testU16_FiltersAndTheFilterMenu() throws {
        openMap()
        app.buttons["starmap.filter"].tap()
        XCTAssertTrue(app.buttons["Used"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["All"].exists && app.buttons["Learned"].exists && app.buttons["Refresh"].exists)
        shot("starmap-filter-menu")
        app.buttons["Used"].tap()
        XCTAssertTrue(waitUntil(8) { self.subtitle != "60 skills across 12 categories" }, "Used narrows the map")
        let used = subtitle
        let usedStars = debug()["stars"] as? Int ?? 0
        XCTAssertTrue(usedStars > 0 && usedStars < 60, "only used skills are stars (memories are never used): \(usedStars)")
        XCTAssertTrue(used.hasPrefix("\(usedStars) skills"), "\(used) vs \(usedStars) stars")
        filter("Learned")
        XCTAssertTrue(waitUntil(8) { self.subtitle != used }, "Learned is another set")
        let learned = debug()["stars"] as? Int ?? 0
        XCTAssertTrue(learned > 0 && learned < 60, "\(learned)")
        mode("List")
        XCTAssertEqual(listedSkills().skills, learned, "the List follows the filter")
        XCTAssertFalse(app.staticTexts["starmap.section.memory-cards"].exists, "memories are not Learned")
        filter("All")
        XCTAssertTrue(waitUntil(8) { self.subtitle == "60 skills across 12 categories" })
        // Refresh reads the graph again.
        let reads = try rest("GET", "/api/learning/graph").count
        filter("Refresh")
        XCTAssertTrue(waitUntil(8) { ((try? self.rest("GET", "/api/learning/graph").count) ?? 0) > reads }, "Refresh asked again")
    }

    @MainActor func testU16_EmptyGraph() throws {
        try graph(["nodes": 0])
        launchSignedIn()
        openMore("star-map")
        XCTAssertTrue(app.staticTexts["Nothing learned yet"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["As Hermes builds skills and memories for your work, they appear here."].exists)
        XCTAssertFalse(app.segmentedControls["starmap.mode"].exists, "no Map | List over an empty graph")
        XCTAssertFalse(app.buttons["starmap.filter"].isEnabled, "nothing to filter")
        shot("starmap-empty")
    }

    @MainActor func testU16_MissingNode() throws {
        openMap()
        mode("List")
        let row = app.buttons["starmap.row.retired-notes"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the most used skill of the largest category is the first row")
        XCTAssertTrue(row.label.contains("Used 240 times") && row.label.contains("Pinned"), row.label)
        row.tap()
        XCTAssertTrue(app.staticTexts["starmap.node.title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["This is no longer in the map."].waitForExistence(timeout: 10), "a 404 node says so")
        XCTAssertTrue(app.staticTexts["Stale"].exists && app.staticTexts["Hermes"].exists, "the facts from the graph still show")
        shot("starmap-node-missing")
        closeSheet()

        // A node whose read fails says so, and Try Again reads it.
        let other = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'starmap.row.' AND identifier != 'starmap.row.retired-notes'")).firstMatch
        try fail("GET", "/api/learning/node", status: 500, detail: "boom")
        other.tap()
        XCTAssertTrue(app.staticTexts["Couldn’t load this."].waitForExistence(timeout: 10))
        shot("starmap-node-failed")
        app.buttons["starmap.node.retry"].tap()
        XCTAssertTrue(app.staticTexts["starmap.node.text"].waitForExistence(timeout: 10), "Try Again read the node")
        closeSheet()
    }

    @MainActor func testU16_BotPickerChangesTheMap() throws {
        openMap()
        let picker = app.buttons["more.bot-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "a picker when there is more than one bot")
        picker.tap()
        let inbox = app.buttons["Inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        shot("starmap-bot-menu")
        inbox.tap()
        XCTAssertTrue(waitUntil(15) { self.app.staticTexts["starmap.subtitle"].exists && self.subtitle == "24 skills across 5 categories" },
                      "Inbox has its own, smaller map: \(subtitle)")
        XCTAssertEqual(debug()["clusters"] as? Int, 6, "5 categories and Memory")
        XCTAssertEqual(try rest("GET", "/api/learning/graph").last?["query"] as? [String: String], ["profile": "inbox"])
        shot("starmap-map-inbox")
        // A node of a named bot is read in that bot's scope.
        let points = debug()["points"] as? [[String: Any]] ?? []
        let star = try XCTUnwrap(points.first, "a star on screen")
        tapCanvas(x: try XCTUnwrap(star["x"] as? Double), y: try XCTUnwrap(star["y"] as? Double))
        XCTAssertTrue(app.staticTexts["starmap.node.text"].waitForExistence(timeout: 10))
        XCTAssertEqual((try rest("GET", "/api/learning/node").last?["query"] as? [String: String])?["profile"], "inbox")
        closeSheet()
        // The bot is remembered; put it back for the tests that follow.
        relaunch(Self.onMap)
        openMore("star-map")
        XCTAssertTrue(waitUntil(20) { self.app.staticTexts["starmap.subtitle"].exists && self.subtitle == "24 skills across 5 categories" },
                      "the chosen bot is remembered")
        app.buttons["more.bot-picker"].tap()
        app.buttons["Hermes"].tap()
        XCTAssertTrue(waitUntil(15) { self.subtitle == "60 skills across 12 categories" })
    }

    @MainActor func testU16_VoiceOverOpensOnListAndTheMapHasOneElementPerCluster() throws {
        launchSignedIn(["-HQA11yVoiceOver", "YES", "-HQA11yReduceMotion", "YES", "-HQStarMapDebug", "YES"])
        openMore("star-map")
        XCTAssertTrue(app.buttons["starmap.row.retired-notes"].waitForExistence(timeout: 20), "with VoiceOver on the page opens on List")
        XCTAssertFalse(canvas.exists)
        mode("Map")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertEqual(debug()["flown"] as? Bool, true, "Reduce Motion: no fly-in")
        let coding = app.descendants(matching: .any)["starmap.cluster.coding"]
        XCTAssertTrue(coding.waitForExistence(timeout: 5), "one element per cluster")
        XCTAssertTrue(coding.label.hasPrefix("Coding, ") && coding.label.hasSuffix(" skills"), coding.label)
        XCTAssertEqual(app.descendants(matching: .any)["starmap.cluster.memory"].label, "Memory, 40 memories")
        let clusters = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'starmap.cluster.'")).count
        XCTAssertEqual(clusters, 13, "13 clusters, not 100 stars")
        XCTAssertEqual(canvas.label, "Star Map")
        XCTAssertTrue((canvas.value as? String ?? "").hasSuffix(" percent"), "the zoom is spoken")
    }

    // MARK: Stress (§21)

    /// A slow first read that then fails: the skeleton, then "Couldn’t Load Star Map", and Try Again works.
    @MainActor func testStress_SlowFirstReadThenFailure() throws {
        try graph(["delay": 6, "fail": ["status": 500, "count": 1]])
        launchSignedIn(Self.onMap)
        openMore("star-map")
        XCTAssertTrue(app.descendants(matching: .any)["more.page.loading"].waitForExistence(timeout: 5), "the skeleton shows while the read is on its way")
        shot("starmap-loading")
        XCTAssertTrue(app.staticTexts["Couldn’t Load Star Map"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Failed to build learning graph"].exists, "the gateway's own reason")
        XCTAssertTrue(app.buttons["Copy Details"].exists)
        shot("starmap-error")
        try graph(["delay": 0])
        app.buttons["Try Again"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "Try Again loads the map")
        XCTAssertEqual(subtitle, "60 skills across 12 categories")
        back()
        XCTAssertTrue(app.cells["more-row-star-map"].waitForExistence(timeout: 5), "a failed read that is not a 404 keeps the row in More")
    }

    /// Relaunch: the Map | List choice is remembered.
    @MainActor func testStress_RelaunchKeepsMapOrList() throws {
        launchSignedIn(["-HQStarMapDebug", "YES"])
        openMore("star-map")
        mode("List")
        XCTAssertTrue(app.buttons["starmap.row.retired-notes"].waitForExistence(timeout: 10))
        relaunch(["-HQStarMapDebug", "YES"])
        if !app.buttons["starmap.row.retired-notes"].waitForExistence(timeout: 6) { openMore("star-map") }
        XCTAssertTrue(app.buttons["starmap.row.retired-notes"].waitForExistence(timeout: 20), "List is remembered")
        XCTAssertTrue(app.segmentedControls["starmap.mode"].buttons["List"].isSelected)
        XCTAssertTrue(app.tabBars.buttons["More"].isHittable, "the tab bar shows")
        mode("Map")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        relaunch(["-HQStarMapDebug", "YES"])
        if !canvas.waitForExistence(timeout: 6) { openMore("star-map") }
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "Map is remembered")
        XCTAssertTrue(app.segmentedControls["starmap.mode"].buttons["Map"].isSelected)
    }

    /// Map | List and the filters switched quickly, many times: the page ends where the last choice put it.
    @MainActor func testStress_RapidSwitching() throws {
        try graph(["nodes": 2000])
        openMap()
        XCTAssertEqual(subtitle, "2000 skills across 12 categories")
        let map = app.segmentedControls["starmap.mode"].buttons["Map"], list = app.segmentedControls["starmap.mode"].buttons["List"]
        for _ in 0..<15 { list.tap(); map.tap() }
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        for name in ["Used", "Learned", "All", "Used", "All", "Learned", "Used", "All"] { filter(name) }
        XCTAssertTrue(waitUntil(10) { self.subtitle == "2000 skills across 12 categories" }, "the last filter wins: \(subtitle)")
        XCTAssertEqual(debug()["stars"] as? Int, 2040)
        list.tap()
        for name in ["Used", "All"] { filter(name) }
        XCTAssertTrue(app.collectionViews["starmap.list"].waitForExistence(timeout: 10))
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        map.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        // Pinch and pan in quick turns over 2,000 stars.
        for _ in 0..<3 {
            canvas.pinch(withScale: 2.5, velocity: 3)
            canvas.swipeUp(velocity: .fast)
            canvas.swipeRight(velocity: .fast)
            canvas.pinch(withScale: 0.4, velocity: -3)
        }
        XCTAssertGreaterThan(zoom, 0.05)
        XCTAssertTrue(app.staticTexts["starmap.subtitle"].exists, "still on the page")
        shot("starmap-map-after-rapid")
        back()
        XCTAssertTrue(app.cells["more-row-star-map"].waitForExistence(timeout: 5), "Back leads to More")
    }

    /// The 20,000-character memory card: folded at 4 lines, unfolds and folds again.
    @MainActor func testStress_LongMemoryCard() throws {
        try graph(["nodes": 3])
        openMap()
        mode("List")
        let more = app.buttons["starmap.memory.more.3"]
        for _ in 0..<12 where !more.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the long card offers Show More")
        reach(more)
        XCTAssertEqual(more.label, "Show More")
        shot("starmap-memory-folded")
        more.tap()
        XCTAssertTrue(waitUntil(8) { !more.exists || !more.isHittable || more.label == "Show Less" }, "the card unfolded: Show Less is now under its 20,000 characters")
        shot("starmap-memory-open")
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.staticTexts["starmap.subtitle"].exists && app.tabBars.buttons["More"].exists, "the list scrolls on and the app is alive")
        // Folding it again from the Map and back: a card opens folded.
        mode("Map")
        mode("List")
        XCTAssertTrue(app.staticTexts["starmap.subtitle"].waitForExistence(timeout: 5))
    }

    /// The probe at 2,000 nodes (§17.3) and at 5,000 nodes with 10,000 links (§21): the frame times are recorded in
    /// the test's [measure] lines and in build/shots/morepages-starmap-probe.txt. The 25 ms target is reported, not
    /// asserted: a shared Mac's simulator is not a phone.
    @MainActor func testStress_Probe2000() throws { try probe(nodes: 2000, edges: 3000) }
    @MainActor func testStress_Probe5000() throws { try probe(nodes: 5000, edges: 10_000) }

    @MainActor private func probe(nodes: Int, edges: Int) throws {
        try graph(["nodes": nodes, "edges": edges])
        launchSignedIn(["-HQStarMapProbe", "YES", "-pages.more.starmap.view", "map"])
        let tapped = Date()
        openMore("star-map")
        XCTAssertTrue(canvas.waitForExistence(timeout: 30), "the map of \(nodes) is on show")
        measured("star map \(nodes): map on show \(Int(Date().timeIntervalSince(tapped) * 1000)) ms after the tap on the More tab")
        XCTAssertEqual(subtitle, "\(nodes) skills across 12 categories")
        let result = app.descendants(matching: .any)["starmap.probe"]
        XCTAssertTrue(result.waitForExistence(timeout: 40), "the probe finished")
        let text = result.value as? String ?? ""
        XCTAssertTrue(text.contains("nodes=\(nodes + 40)"), text)
        measured("star map probe \(nodes): \(text)")
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("morepages-starmap-probe.txt")
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(Self.dark ? "dark" : "light") \(text)\n"
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (old + line).write(to: url, atomically: true, encoding: .utf8)
        }
        shot("starmap-map-\(nodes)")
        // Still usable after the script: a pinch zooms, the List has the same count.
        let before = zoom
        canvas.pinch(withScale: 3, velocity: 2)
        XCTAssertTrue(waitUntil(5) { self.zoom > before }, "the map still answers a pinch")
        shot("starmap-zoomed-\(nodes)")
        mode("List")
        XCTAssertTrue(app.collectionViews["starmap.list"].waitForExistence(timeout: 15))
        XCTAssertEqual(subtitle, "\(nodes) skills across 12 categories")
    }
}
