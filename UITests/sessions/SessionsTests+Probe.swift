// [sessions-m9] The reconnect probe (docs/spec/3x-sessions.md §11; acceptance G1-G4), against
// scripts/fixtures/sessions-gateway.py: `/__fixture/drop` closes the socket, the app reconnects, and
// `/__fixture/stats` says which sidebar reads it then made (limit 1 = the probe; 20 = the top page, §11.5; 50 or 300 =
// a full read). The app's own counters are written to probe.txt (`probes=2 skipped=1 full=3 top=1`).

import XCTest

extension SessionsTests {
    /// Full reads the fixture has answered, at either depth.
    func fullReads() -> Int { let reads = sidebarReads(); return reads.full + reads.deep }

    /// The app's own counters, from probe.txt.
    func probeStats() -> [String: Int] {
        var out: [String: Int] = [:]
        for part in (readTextOut("probe.txt") ?? "").split(separator: " ") {
            let pair = part.split(separator: "=")
            if pair.count == 2, let value = Int(pair[1]) { out[String(pair[0])] = value }
        }
        return out
    }

    /// Closes the socket and waits for the app to be back and to have asked again (a probe or a full read).
    @MainActor func dropAndWait(file: StaticString = #filePath, line: UInt = #line) {
        let before = sidebarReads()
        fixture("/__fixture/drop")
        XCTAssertTrue(waitUntil(30) { let now = self.sidebarReads(); return now.probe + now.full + now.deep + now.top > before.probe + before.full + before.deep + before.top },
                      "the app reconnects and asks again", file: file, line: line)
        Thread.sleep(forTimeInterval: 2.5)                              // a full read after a probe has had its time
    }

    /// G1: nothing changed: one probe, no full read, and the app counts a skip.
    @MainActor func test70_ReconnectWithNothingChangedSkipsTheRead() throws {
        removeTextOut("probe.txt")
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3.0)                              // the launch's reads are done
        let before = sidebarReads(), fullBefore = fullReads(), statsBefore = probeStats()
        let orderBefore = order(app)
        dropAndWait()
        XCTAssertEqual(sidebarReads().probe - before.probe, 1, "one probe")
        XCTAssertEqual(fullReads() - fullBefore, 0, "no full read")
        XCTAssertEqual(order(app), orderBefore, "the list does not move")
        XCTAssertTrue(waitUntil(5) { (self.probeStats()["skipped"] ?? 0) - (statsBefore["skipped"] ?? 0) == 1 }, "skipped=1 (\(readTextOut("probe.txt") ?? "no file"))")
        XCTAssertEqual((probeStats()["probes"] ?? 0) - (statsBefore["probes"] ?? 0), 1)
        XCTAssertEqual((probeStats()["full"] ?? 0) - (statsBefore["full"] ?? 0), 0)
        shot(app, "G1-after-reconnect")
    }

    /// G2: the newest chat's title changed while the socket was away: the probe, then the top page (§11.5; the list is
    /// on screen but its full read is fresh), no full read, and the new title.
    @MainActor func test71_ReconnectWithAChangeReadsTheTopPage() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3.0)
        let before = sidebarReads(), fullBefore = fullReads()
        setRow("s-garden", ["title": "Garden plan for spring"])       // no event: only the reconnect can find it
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(labelOf(row(app, "s-garden")).hasPrefix("Garden plan for spring"), "nothing told the app yet")
        dropAndWait()
        XCTAssertEqual(sidebarReads().probe - before.probe, 1, "one probe")
        XCTAssertEqual(sidebarReads().top - before.top, 1, "then the top page")
        XCTAssertEqual(fullReads() - fullBefore, 0, "and no full read")
        XCTAssertTrue(waitUntil(6) { self.labelOf(self.row(app, "s-garden")).hasPrefix("Garden plan for spring. ") },
                      "the row shows the new title (\(labelOf(row(app, "s-garden"))))")
        shot(app, "G2-new-title")
    }

    /// G3: opening a chat marks it read; that write alone does not cost the next reconnect its skip.
    @MainActor func test72_MarkReadKeepsTheLastRead() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(labelOf(row(app, "s-budget")).hasSuffix("Unread"))
        openChat(app, "s-budget")
        XCTAssertTrue(waitUntil(8) { self.unreadWrites().contains { $0.path == "/api/sessions/s-budget" && !$0.unread } }, "opening it marks it read")
        backToList(app)
        XCTAssertTrue(waitUntil(6) { !self.labelOf(self.row(app, "s-budget")).contains("Unread") })
        Thread.sleep(forTimeInterval: 4.0)                              // whatever the write's own event asked for is done
        let before = sidebarReads(), fullBefore = fullReads()
        dropAndWait()
        XCTAssertEqual(sidebarReads().probe - before.probe, 1, "a probe")
        XCTAssertEqual(fullReads() - fullBefore, 0, "and no full read")
        shot(app, "G3-after-mark-read")
    }

    /// G4: a pin from this phone forgets the last read: the reconnect reads in full, with no probe first. (The
    /// sidebar is slowed so the read the pin's own event asks for cannot land before the socket drops.)
    @MainActor func test73_APinForgetsTheLastRead() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3.0)
        fixture("/__fixture/mode", ["sidebarDelay": 4])
        let before = sidebarReads(), fullBefore = fullReads()
        openMenu(app, garden, until: "Pin")
        app.buttons["Pin"].firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { self.writes("PATCH", "/api/sessions/s-garden").contains { $0["pinned"] as? Bool == true } }, "the pin is written")
        fixture("/__fixture/drop")
        Thread.sleep(forTimeInterval: 12.0)                             // the reconnect, and the slowed reads
        XCTAssertEqual(sidebarReads().probe - before.probe, 0, "no probe")
        XCTAssertGreaterThanOrEqual(fullReads() - fullBefore, 1, "a full read")
        fixture("/__fixture/mode", ["sidebarDelay": 0])
        XCTAssertTrue(waitUntil(8) { self.labelOf(garden).hasSuffix("Pinned") }, labelOf(garden))
        shot(app, "G4-after-pin")
    }
}
