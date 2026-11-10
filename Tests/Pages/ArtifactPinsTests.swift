// [pins] Pinned artifacts (tester, 2026-10-31): one pin per file on a bot's computer, kept on disk, following the
// newest chat that names it.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct ArtifactPinsTests {
    private func record(_ value: String, session: String = "s1", profile: String? = nil, title: String = "Meals",
                        at: Double = 1000, kind: ArtifactRecord.Kind = .file) -> ArtifactRecord {
        ArtifactRecord(id: "\(session):\(value)", kind: kind, value: value, href: ArtifactCollector.href(value),
                       label: ArtifactCollector.label(value, kind: kind), sessionId: session, profile: profile,
                       sessionTitle: title, timestamp: at)
    }

    @Test func aPinIsTheFileNotTheChat() {
        let pins = ArtifactPins(fileURL: nil)
        #expect(pins.toggle(record("/home/h/dash.html", session: "a")))
        #expect(pins.isPinned(record("/home/h/dash.html", session: "b")), "the same file named in another chat")
        #expect(pins.isPinned(record("/home/h/dash.html", profile: "default")), "no profile is the default bot")
        #expect(!pins.isPinned(record("/home/h/dash.html", profile: "fitness")), "another bot's computer")
        pins.pin(ArtifactPin(record("/home/h/dash.html", session: "c")))
        #expect(pins.pins.count == 1)
        #expect(!pins.toggle(record("/home/h/dash.html")))
        #expect(pins.pins.isEmpty)
    }

    @Test func newestFirstAndReorderable() {
        let pins = ArtifactPins(fileURL: nil)
        for name in ["a.html", "b.png", "c.md"] { pins.pin(ArtifactPin(record("/x/\(name)"))) }
        #expect(pins.pins.map(\.label) == ["c.md", "b.png", "a.html"])
        pins.move(from: 2, to: 0)
        #expect(pins.pins.map(\.label) == ["a.html", "c.md", "b.png"])
    }

    @Test func followsTheNewestChatNamingIt() {
        let pins = ArtifactPins(fileURL: nil)
        pins.pin(ArtifactPin(record("/x/dash.html", session: "old", title: "Monday")))
        pins.follow([record("/x/dash.html", session: "new", title: "Friday", at: 9000),
                     record("/x/dash.html", session: "mid", title: "Wednesday", at: 5000)])
        #expect(pins.pins.first?.sessionId == "new")
        #expect(pins.pins.first?.sessionTitle == "Friday")
    }

    @Test func kindsAndPaths() {
        let page = ArtifactPin(record("/x/dash.html"))
        #expect(page.isPage)
        #expect(page.gatewayPath == "/x/dash.html")
        #expect(page.record.id == "pin:" + page.id)
        let link = ArtifactPin(record("https://example.com/report", kind: .link))
        #expect(!link.isPage && link.gatewayPath == nil)
        #expect(ArtifactPin(record("file:///x/a%20b.png", kind: .image)).gatewayPath == "/x/a b.png")
    }

    @Test func keptOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pins-\(UUID().uuidString)")
        let url = ArtifactPins.fileURL(accountId: "acct-1", root: root)
        #expect(url != ArtifactPins.fileURL(accountId: "acct-2", root: root))
        let pins = ArtifactPins(fileURL: url)
        pins.pin(ArtifactPin(record("/x/dash.html", profile: "fitness")))
        PagesCache.flush()
        let again = ArtifactPins(fileURL: url)
        #expect(again.pins.map(\.id) == ["fitness\u{1F}/x/dash.html"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func atMostTheLimit() {
        let pins = ArtifactPins(fileURL: nil)
        for i in 0..<ArtifactPins.limit { pins.pin(ArtifactPin(record("/x/\(i).png", kind: .image))) }
        #expect(pins.isFull)
        // Audit 863 (08b-6): one more is refused; it once pushed the last pin out unsaid.
        #expect(!pins.pin(ArtifactPin(record("/x/new.png", kind: .image))))
        #expect(!pins.toggle(record("/x/new.png", kind: .image)))
        #expect(pins.pins.count == ArtifactPins.limit)
        #expect(pins.pins.first?.label == "\(ArtifactPins.limit - 1).png")
        #expect(pins.pins.last?.label == "0.png", "the oldest pin stays")
    }

    @Test func anUnpinUndoneComesBackAsItWas() {
        let pins = ArtifactPins(fileURL: nil)
        for name in ["a.html", "b.html", "c.html"] { pins.pin(ArtifactPin(record("/x/\(name)"))) }
        guard let index = pins.pins.firstIndex(where: { $0.label == "b.html" }) else { Issue.record("no pin"); return }
        pins.rename(id: pins.pins[index].id, to: "Budget")
        let pin = pins.pins[index]
        pins.unpin(id: pin.id)
        #expect(pins.pins.map(\.label) == ["c.html", "a.html"])
        pins.restore(pin, at: index)
        #expect(pins.pins.map(\.label) == ["c.html", "b.html", "a.html"])
        #expect(pins.pins[1].name == "Budget", "its own name came back")
    }

    // [dashboard] Grid (tester feedback, 2026-11-01).

    @Test func movedByIdWithinOneBotsPins() {
        let pins = ArtifactPins(fileURL: nil)
        for name in ["a.html", "b.png", "c.md", "d.html"] { pins.pin(ArtifactPin(record("/x/\(name)"))) }
        // d c b a: c dragged onto a's place, then a onto d's.
        pins.move(id: ArtifactPin(record("/x/c.md")).id, to: ArtifactPin(record("/x/a.html")).id)
        #expect(pins.pins.map(\.label) == ["d.html", "b.png", "a.html", "c.md"])
        pins.move(id: ArtifactPin(record("/x/a.html")).id, to: ArtifactPin(record("/x/d.html")).id)
        #expect(pins.pins.map(\.label) == ["a.html", "d.html", "b.png", "c.md"])
        pins.move(id: "nobody", to: ArtifactPin(record("/x/d.html")).id)
        #expect(pins.pins.count == 4)
    }

    @Test func tileSizesKeptAndOldPinsSmall() throws {
        let pins = ArtifactPins(fileURL: nil)
        pins.pin(ArtifactPin(record("/x/dash.html")))
        #expect(pins.pins[0].tileSize == .small)
        pins.setSize(.large, id: pins.pins[0].id)
        #expect(pins.pins[0].tileSize == .large)
        // A pin written before Grid has no size.
        let old = #"[{"id":"default\u001f/x/a.png","kind":"image","value":"/x/a.png","label":"a.png","profile":"default","sessionId":"s","sessionTitle":"t","pinnedAt":1}]"#
        let decoded = try JSONDecoder().decode([ArtifactPin].self, from: Data(old.utf8))
        #expect(decoded.first?.tileSize == .small)
        let again = try JSONDecoder().decode([ArtifactPin].self, from: JSONEncoder().encode(pins.pins))
        #expect(again.first?.tileSize == .large)
    }

    @Test func gridPacksLikeWidgets() {
        typealias Cell = PinGridPacking.Cell
        // Small Small / Medium / Large on two columns: one under the other.
        var placed = PinGridPacking.place([(1, 1), (1, 1), (2, 1), (2, 2)], columns: 2)
        #expect(placed.cells == [Cell(column: 0, row: 0, columns: 1, rows: 1), Cell(column: 1, row: 0, columns: 1, rows: 1),
                                 Cell(column: 0, row: 1, columns: 2, rows: 1), Cell(column: 0, row: 2, columns: 2, rows: 2)])
        #expect(placed.rows == 4)
        // A Small after a Small and a Medium fills the gap beside the first Small.
        placed = PinGridPacking.place([(1, 1), (2, 1), (1, 1)], columns: 2)
        #expect(placed.cells[1] == Cell(column: 0, row: 1, columns: 2, rows: 1))
        #expect(placed.cells[2] == Cell(column: 1, row: 0, columns: 1, rows: 1))
        #expect(placed.rows == 2)
        // Four columns: a Large, then Smalls beside it, two by two.
        placed = PinGridPacking.place([(2, 2), (1, 1), (1, 1), (1, 1), (1, 1), (1, 1)], columns: 4)
        #expect(placed.cells.map(\.column) == [0, 2, 3, 2, 3, 0])
        #expect(placed.cells.map(\.row) == [0, 0, 0, 1, 1, 2])
        // Wider than the grid: cut to it.
        placed = PinGridPacking.place([(2, 1)], columns: 1)
        #expect(placed.cells == [Cell(column: 0, row: 0, columns: 1, rows: 1)])
        #expect(PinGridPacking.place([], columns: 2).rows == 0)
    }

    /// [dashboard] Edit Tiles: a corner dragged to so many cells picks the size; Extra Large spans the grid's width.
    @Test func cornerDragPicksTheSize() {
        #expect(PinTileSize.fitting(columns: 1, rows: 1) == .small)
        #expect(PinTileSize.fitting(columns: 2, rows: 1) == .medium)
        #expect(PinTileSize.fitting(columns: 1, rows: 2) == .large)
        #expect(PinTileSize.fitting(columns: 2, rows: 2) == .large)
        #expect(PinTileSize.fitting(columns: 2, rows: 4) == .extraLarge)
        let placed = PinGridPacking.place([PinTileSize.small.span, PinTileSize.extraLarge.span], columns: 2)
        #expect(placed.cells[1] == PinGridPacking.Cell(column: 0, row: 1, columns: 2, rows: 3))
        #expect(placed.rows == 4)
    }

    @Test func gridColumnsFollowTheWidth() {
        #expect(ArtifactsViewController.gridMetrics(width: 353, spacing: 12).columns == 2)    // iPhone 16
        #expect(ArtifactsViewController.gridMetrics(width: 280, spacing: 12).columns == 2)    // never one column
        #expect(ArtifactsViewController.gridMetrics(width: 920, spacing: 12).columns == 4)    // Mac column
        let phone = ArtifactsViewController.gridMetrics(width: 353, spacing: 12)
        #expect(phone.cell * 2 + 12 <= 353)
    }

    /// [mac] The cells grow with the app's scale (the Mac's Desktop Look at 100 %: 130 %), so fewer, bigger tiles fit.
    @Test func gridCellsFollowTheAppScale() {
        let plain = ArtifactsViewController.gridMetrics(width: 1400, spacing: 12)
        let mac = ArtifactsViewController.gridMetrics(width: 1400, spacing: 12, scale: 1.3)
        #expect(plain.columns == 6)
        #expect(mac.columns == 5)
        #expect(mac.cell >= 190 * 1.3)
        #expect(ArtifactsViewController.gridMetrics(width: 353, spacing: 12, scale: 0.9).columns == 2)   // never smaller than 100 %
    }

    @Test func zoomedFrameHasItsOwnKey() {
        #expect(PageSnapshots.Shape.frame(width: 250, height: 250).key == "frame250x250")
        #expect(PageSnapshots.Shape.frame(width: 250, height: 250, zoom: 1.3).key == "frame250x250z130")
        #expect(PageSnapshots.Shape.frame(width: 250, height: 250, zoom: 1.3).zoom == 1.3)
    }
}
