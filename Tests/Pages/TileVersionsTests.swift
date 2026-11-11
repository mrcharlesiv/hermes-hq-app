// [tile-versions] A tile's versions (owner 2026-11-11): what counts as a new one, where they're kept on the bot's
// computer, and rolling back.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// The bot's computer, as the three routes the versions use see it.
private nonisolated final class FakeDisk: Sendable {
    let files = Mutex<[String: String]>([:])
    let folders = Mutex<Set<String>>([])

    func client() -> PagesFakeClient {
        PagesFakeClient { [self] request in
            switch (request.method, request.path) {
            case ("GET", "/api/fs/read-text"):
                let path = request.query["path"] ?? ""
                guard let text = files.withLock({ $0[path] }) else { throw httpError(404, "File not found") }
                return ["path": .string(path), "text": .string(text), "binary": false, "truncated": false]
            case ("POST", "/api/fs/write-text"):
                let path = request.body?["path"]?.string ?? ""
                let parent = (path as NSString).deletingLastPathComponent
                guard parent == "/home/otto/dashboards" || folders.withLock({ $0.contains(parent) }) else {
                    throw httpError(400, "Parent directory does not exist")
                }
                files.withLock { $0[path] = request.body?["content"]?.string ?? "" }
                return ["ok": true, "path": .string(path)]
            case ("POST", "/api/files/mkdir"):
                _ = folders.withLock { $0.insert(request.body?["path"]?.string ?? "") }
                return ["ok": true]
            default:
                throw httpError(404, "Not Found")
            }
        }
    }
}

@MainActor
struct TileVersionsTests {
    private let tile = "/home/otto/dashboards/revenue.html"

    private func page(_ look: String, data: String = "{\"total\": 1200, \"updated\": \"2026-11-11T09:00:00Z\"}") -> String {
        """
        <!doctype html><html><head><title>Revenue</title><meta name="hq-tile-job" content="job-1"></head>
        <body><div class="\(look)"></div>
        <script type="application/json" id="data">\(data)</script>
        <script>draw()</script></body></html>
        """
    }

    @Test func versionsLiveBesideTheTile() {
        #expect(TileVersionFiles.folder(for: "/home/otto/dashboards/revenue.html") == "/home/otto/dashboards/revenue.versions")
        #expect(TileVersionFiles.folder(for: "~/dashboards/revenue-week.html") == "~/dashboards/revenue-week.versions")
        #expect(TileVersionFiles.indexPath(for: "~/dashboards/a.b.html") == "~/dashboards/a.b.versions/versions.json")
        #expect(TileVersionFiles.fileName(3) == "v3.html")
    }

    @Test func aRefreshIsNotANewLook() {
        let before = page("line")
        let refreshed = page("line", data: "{\"total\": 1350,\n  \"updated\": \"2026-11-11T10:00:00Z\"}")
        #expect(TileVersionFiles.designHash(before) == TileVersionFiles.designHash(refreshed))
        #expect(TileVersionFiles.designHash(before) != TileVersionFiles.designHash(page("bars")))
        // White space alone (a script that writes the page again) isn't an edit.
        #expect(TileVersionFiles.designHash(before) == TileVersionFiles.designHash(before.replacingOccurrences(of: "\n", with: "\n\n  ")))
    }

    @Test func eachLookIsNumberedOnce() {
        var list = TileVersionList.empty
        var added: TileVersion?
        (list, added) = TileVersionFiles.noting(page("line"), in: list, kind: .made, what: "Revenue this week", at: 100)
        #expect(added?.number == 1)
        #expect(added?.kind == .made)
        #expect(added?.words == "Revenue this week")
        #expect(list.current == 1)

        // The job refreshed it: still Version 1.
        (list, added) = TileVersionFiles.noting(page("line", data: "{\"total\": 9}"), in: list, kind: .outside, what: nil, at: 200)
        #expect(added == nil)
        #expect(list.versions.count == 1)

        (list, added) = TileVersionFiles.noting(page("bars"), in: list, kind: .changed, what: "  Make it a bar chart ", at: 300)
        #expect(added?.number == 2)
        #expect(added?.what == "Make it a bar chart")
        #expect(list.current == 2)
        #expect(list.newestFirst.map(\.number) == [2, 1])
    }

    @Test func aTileFromBeforeVersionsStartsAtOne() {
        let (list, added) = TileVersionFiles.noting(page("line"), in: .empty, kind: .outside, what: nil)
        #expect(added?.number == 1)
        #expect(added?.kind == .first)
        #expect(list.current == 1)
    }

    @Test func theFirstStaysWhenTheOldestGiveWay() {
        var list = TileVersionList.empty
        for n in 1...(TileVersionFiles.limit + 5) {
            list = TileVersionFiles.noting(page("look-\(n)"), in: list, kind: .changed, what: nil).list
        }
        #expect(list.versions.count == TileVersionFiles.limit)
        #expect(list.versions.first?.number == 1)
        #expect(list.versions.last?.number == TileVersionFiles.limit + 5)
        #expect(list.current == TileVersionFiles.limit + 5)
    }

    @Test func keptOnTheBotsComputer() async throws {
        let disk = FakeDisk()
        disk.files.withLock { $0[tile] = page("line") }
        let store = TileVersionStore(client: disk.client(), profile: "otto", tile: tile)

        #expect(try await store.list() == .empty)
        var list = try await store.note(kind: .made, what: "Revenue this week")
        #expect(list.current == 1)
        #expect(disk.folders.withLock { $0.contains("/home/otto/dashboards/revenue.versions") })
        #expect(disk.files.withLock { $0["/home/otto/dashboards/revenue.versions/v1.html"] } == page("line"))

        // Looked at again with nothing changed but the data: nothing written.
        disk.files.withLock { $0[tile] = page("line", data: "{\"total\": 1}") }
        list = try await store.note(kind: .outside, what: nil)
        #expect(list.versions.count == 1)
        #expect(disk.files.withLock { $0.count } == 3)   // the tile, v1 and the list

        disk.files.withLock { $0[tile] = page("bars") }
        list = try await store.note(kind: .changed, what: "Make it a bar chart")
        #expect(list.current == 2)
        #expect(try await store.list() == list)
    }

    @Test func rollingBackPutsThePageBackAndKeepsEveryLook() async throws {
        let disk = FakeDisk()
        disk.files.withLock { $0[tile] = page("line") }
        let store = TileVersionStore(client: disk.client(), profile: "otto", tile: tile)
        try await store.note(kind: .made, what: "Revenue this week")
        disk.files.withLock { $0[tile] = page("bars") }
        try await store.note(kind: .changed, what: "Make it a bar chart")
        // Edited in a chat since, never seen by the app: kept as Version 3 before the roll back writes over it.
        disk.files.withLock { $0[tile] = page("pie") }

        var list = try await store.rollBack(to: 1)
        #expect(list.current == 1)
        #expect(list.versions.map(\.number) == [1, 2, 3])
        #expect(list.versions.last?.kind == .outside)
        #expect(disk.files.withLock { $0[tile] } == page("line"))
        #expect(disk.files.withLock { $0["/home/otto/dashboards/revenue.versions/v3.html"] } == page("pie"))

        // Forward again: the same call.
        list = try await store.rollBack(to: 3)
        #expect(list.current == 3)
        #expect(list.versions.count == 3)
        #expect(disk.files.withLock { $0[tile] } == page("pie"))

        // A change after a roll back is the next number, not a branch.
        _ = try await store.rollBack(to: 1)
        disk.files.withLock { $0[tile] = page("table") }
        list = try await store.note(kind: .changed, what: "Make it a table")
        #expect(list.current == 4)
    }

    @Test func aMissingCopyIsSaid() async throws {
        let disk = FakeDisk()
        disk.files.withLock { $0[tile] = page("line") }
        let store = TileVersionStore(client: disk.client(), profile: "otto", tile: tile)
        try await store.note(kind: .made, what: nil)
        disk.files.withLock { $0[tile] = page("bars") }
        try await store.note(kind: .changed, what: nil)
        disk.files.withLock { $0["/home/otto/dashboards/revenue.versions/v1.html"] = nil }
        await #expect(throws: TileVersionError.self) { try await store.rollBack(to: 1) }
        #expect(disk.files.withLock { $0[tile] } == page("bars"))   // the tile is left as it was
    }

    @Test func thePinRemembersWhichVersionShows() {
        let pins = ArtifactPins(fileURL: nil)
        let pin = ArtifactPin(kind: .file, value: tile, label: "revenue.html", profile: "otto", sessionId: "s1", sessionTitle: "Revenue")
        pins.pin(pin)
        #expect(pins.pins.first?.version == nil)
        pins.noteVersion(id: pin.id, 2)
        #expect(pins.pins.first?.version == 2)
        // An older app's pin (no version) still reads.
        let old = #"[{"id":"otto\u001F/a.html","kind":"file","value":"/a.html","label":"a.html","profile":"otto","sessionId":"","sessionTitle":"","pinnedAt":1}]"#
        #expect((try? JSONDecoder().decode([ArtifactPin].self, from: Data(old.utf8)))?.first?.version == nil)
    }
}
