// [tile-versions] Versions of a tile (owner 2026-11-11: "when you make one it's v1, if you edit it it's now v2, etc… and
// you can roll back to prior versions if you want to and can see what prior versions looked like").
//
// A tile is one page on its bot's computer that the bot edits in place, so an edit used to leave nothing of the page
// before it. Now each look of the page is kept as a copy beside it:
//
//     ~/dashboards/revenue.html                    the tile
//     ~/dashboards/revenue.versions/v1.html …      each version, as the page was
//     ~/dashboards/revenue.versions/versions.json  which there are, what was asked for each, and which one shows now
//
// On the bot's computer, not on this device: the iPhone and the Mac see the same versions, and a copy is a page like
// any other, so it's pictured and opened by what pictures and opens the tile.
//
// A version is a look, not a refresh: the job that keeps a tile up to date rewrites its data many times a day, and
// that makes no versions. Two pages are the same version when they're alike but for their data
// (`TileVersionFiles.design`: the page less its `<script type="application/json">` blocks, where the tile skill keeps
// the data). A new one is kept when the app sees the look differ from the version that shows: after New Tile (1), after
// each Change…, before a change or a roll back (an edit asked in a chat, outside Tiles), and when Versions opens.
//
// Rolling back writes that version's page back over the tile; nothing is dropped, so going forward again is the same
// tap. The version that shows is `current`, not always the highest.

import CryptoKit
import Foundation

nonisolated struct TileVersion: Codable, Sendable, Hashable, Identifiable {
    nonisolated enum Kind: String, Codable, Sendable {
        /// New Tile made it.
        case made
        /// Change… in Tiles.
        case changed
        /// The page looked different from the version that showed: edited in a chat or by hand.
        case outside
        /// The tile as the app first saw it (made before versions were kept).
        case first
    }

    var number: Int
    /// Seconds since 1970, when the app kept it.
    var at: Double
    var kind: Kind
    /// What was asked for (New Tile's or Change…'s words).
    var what: String?
    /// Its copy's name in the versions folder ("v3.html").
    var file: String
    /// `TileVersionFiles.designHash` of its page.
    var design: String

    var id: Int { number }

    /// "Version 3".
    var title: String { "Version \(number)" }

    /// The row's second line: what was asked, or how it came to be.
    var words: String {
        let asked = (what ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .made: return asked.isEmpty ? "The tile as it was made" : asked
        case .changed: return asked.isEmpty ? "Changed in Tiles" : asked
        case .outside: return "Changed in a chat"
        case .first: return "The tile when versions began"
        }
    }
}

nonisolated struct TileVersionList: Codable, Sendable, Equatable {
    /// The version that shows now.
    var current: Int
    var versions: [TileVersion]

    static let empty = TileVersionList(current: 0, versions: [])

    var shown: TileVersion? { versions.first { $0.number == current } }
    var next: Int { (versions.map(\.number).max() ?? 0) + 1 }
    /// Newest first, as Versions lists them.
    var newestFirst: [TileVersion] { versions.sorted { $0.number > $1.number } }
}

nonisolated enum TileVersionFiles {
    /// The most kept for one tile: the oldest after the first give way (their copies stay on the bot's computer).
    static let limit = 60

    /// The folder beside the tile that holds its versions: "~/dashboards/revenue.html" → "~/dashboards/revenue.versions".
    static func folder(for tile: String) -> String {
        let ns = tile as NSString
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        let directory = ns.deletingLastPathComponent
        let name = (stem.isEmpty ? "tile" : stem) + ".versions"
        if directory.isEmpty { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func indexPath(for tile: String) -> String { folder(for: tile) + "/versions.json" }
    static func fileName(_ number: Int) -> String { "v\(number).html" }
    static func path(of version: TileVersion, tile: String) -> String { folder(for: tile) + "/" + version.file }

    /// The page less its data: the JSON blocks the tile skill keeps the data in are taken out and runs of white space
    /// made one, so a refresh (new numbers, a new "updated" time) leaves it the same and an edit doesn't.
    static func design(_ html: String) -> String {
        var text = html
        if let regex = try? NSRegularExpression(pattern: #"<script\b[^>]*type\s*=\s*["']?application/json["']?[^>]*>.*?</script\s*>"#,
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<script type=\"application/json\"></script>")
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func designHash(_ html: String) -> String {
        SHA256.hash(data: Data(design(html).utf8)).map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    /// The list after the app saw the tile's page as `html`: unchanged when the version that shows has that look, else
    /// with a new version (the first when there were none). `added`: the version to write a copy for.
    static func noting(_ html: String, in list: TileVersionList, kind: TileVersion.Kind, what: String?,
                       at: Double = Date().timeIntervalSince1970) -> (list: TileVersionList, added: TileVersion?) {
        let design = designHash(html)
        if let shown = list.shown, shown.design == design { return (list, nil) }
        var list = list
        // The first one kept of a tile the app didn't make just now is the tile as found, whatever was asked since.
        let first = list.versions.isEmpty
        let number = list.next
        let asked = (what ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let version = TileVersion(number: number, at: at, kind: first && kind == .outside ? .first : kind,
                                  what: asked.isEmpty ? nil : String(asked.prefix(600)), file: fileName(number), design: design)
        list.versions.append(version)
        list.current = number
        if list.versions.count > limit {
            // The first stays (where the tile began); the oldest after it go.
            let sorted = list.versions.sorted { $0.number < $1.number }
            list.versions = [sorted[0]] + sorted.suffix(limit - 1)
        }
        return (list, version)
    }
}

nonisolated enum TileVersionError: Error, Sendable {
    /// The page couldn't be read whole (too large for a text read, or not text).
    case unreadable
    /// The version's copy is gone from the bot's computer.
    case missing
    /// The gateway refused (`words`: its reason).
    case refused(String)

    var words: String {
        switch self {
        case .unreadable: "This tile’s page couldn’t be read, or is too large to keep versions of."
        case .missing: "That version’s copy is gone from the bot’s computer."
        case .refused(let reason): reason
        }
    }

    static func words(_ error: Error) -> String {
        (error as? TileVersionError)?.words ?? PagesREST.reason(error)
    }
}

/// The reads and writes on the bot's computer (`/api/fs/download`, `/api/fs/write-text`, `/api/files/mkdir`).
nonisolated struct TileVersionStore: Sendable {
    let client: any GatewayClient
    /// The tile's bot.
    let profile: String
    /// The tile's page, as its pin has it.
    let tile: String

    private var query: [URLQueryItem] {
        profile.isEmpty ? [] : [URLQueryItem(name: "profile", value: profile)]
    }

    /// The most of a page kept as a version (the gateway takes a text write up to 8 MB).
    static let largest = 6 * 1024 * 1024

    /// A file's text, whole: the download route, not `/api/fs/read-text`, which stops at 512 KB (a tile with its data
    /// inline can be 1 MB). nil when there is no such file.
    private func readText(_ path: String) async throws -> String? {
        do {
            let data = try await PagesREST.send(client, "GET", "/api/fs/download", query: [URLQueryItem(name: "path", value: path)] + query,
                                                timeout: 60)
            guard data.count <= Self.largest, let text = String(data: data, encoding: .utf8) else { throw TileVersionError.unreadable }
            return text
        } catch let error as HTTPError where error.status == 404 {
            return nil
        }
    }

    private func writeText(_ path: String, _ content: String) async throws {
        let body: JSONValue = .object(["path": .string(path), "content": .string(content)])
        let data = try await PagesREST.send(client, "POST", "/api/fs/write-text", query: query, json: body, timeout: 30)
        // A 200 that isn't Hermes's own answer (a proxy's page) wrote nothing.
        guard let answer = try? JSONValue.parse(data), answer["ok"]?.bool != false, answer["error"] == nil else {
            throw TileVersionError.refused("The gateway didn’t keep the file.")
        }
    }

    private func makeFolder() async throws {
        let body: JSONValue = .object(["path": .string(TileVersionFiles.folder(for: tile))])
        _ = try await PagesREST.send(client, "POST", "/api/files/mkdir", query: query, json: body, timeout: 30)
    }

    /// The tile's versions as kept (empty when none are yet).
    func list() async throws -> TileVersionList {
        guard let text = try await readText(TileVersionFiles.indexPath(for: tile)), let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode(TileVersionList.self, from: data) else { return .empty }
        return list
    }

    private func keep(_ list: TileVersionList) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await writeText(TileVersionFiles.indexPath(for: tile), String(decoding: try encoder.encode(list), as: UTF8.self))
    }

    /// The tile's page read now and kept as a new version when its look isn't the one that shows. The list after.
    @discardableResult
    func note(kind: TileVersion.Kind, what: String?) async throws -> TileVersionList {
        guard let html = try await readText(tile), !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TileVersionError.unreadable
        }
        let list = try await list()
        let (noted, added) = TileVersionFiles.noting(html, in: list, kind: kind, what: what)
        guard let added else { return list }
        if list.versions.isEmpty { try await makeFolder() }
        try await writeText(TileVersionFiles.path(of: added, tile: tile), html)
        try await keep(noted)
        return noted
    }

    /// Version `number`'s page written back over the tile. What shows now is kept first when it isn't a version yet,
    /// so a roll back never drops a look. The list after.
    func rollBack(to number: Int) async throws -> TileVersionList {
        var list = try await note(kind: .outside, what: nil)
        guard let version = list.versions.first(where: { $0.number == number }) else { throw TileVersionError.missing }
        guard let html = try await readText(TileVersionFiles.path(of: version, tile: tile)) else { throw TileVersionError.missing }
        try await writeText(tile, html)
        list.current = number
        try await keep(list)
        return list
    }
}
