// Pinned artifacts (tester, 2026-10-31: "pin/favorite certain artifacts in a chat and the artifacts tab"; a bot
// keeps a meal-and-workout dashboard up to date). A pin is a file, image or link on one bot's computer, not one chat's
// mention of it: a page the bot rewrites from chat to chat stays one pin, and it opens as the file is now. Pins sit at
// the top of Artifacts and on the Pinned page, and outlive the recent-chats window the Artifacts index reads.
//
// Kept on this device per account (Application Support/pages/pins/<account hash>.json), across sign-outs: a pin is a
// choice the owner made, not a cache of the gateway. [sync] The pins and the Tiles pages also live on the gateway
// (`GatewaySync`, document "pins"), so the iPhone and the Mac show the same tiles; the page shown is each device's own.

import CryptoKit
import Foundation

nonisolated struct ArtifactPin: Codable, Sendable, Hashable, Identifiable {
    /// `"<profile>\u{1F}<value>"` (profile "default" when unset).
    var id: String
    var kind: ArtifactRecord.Kind
    /// The path or URL, as the bot wrote it.
    var value: String
    var label: String
    var profile: String
    /// The newest chat seen naming it (Show in Chat; a relative path resolves against that chat's folder).
    var sessionId: String
    var sessionTitle: String
    /// Seconds since 1970.
    var pinnedAt: Double
    /// [dashboard] Its tile in Grid (nil, as every pin made before Grid: Small).
    var size: PinTileSize?
    /// [dashboard] The Dashboard page it is on (owner 2026-11-03, "pages within the dashboard"); nil, as every pin made
    /// before pages: Main.
    var page: String?
    /// [tiles] The name the owner gave it (Rename…); nil: `name` picks one.
    var title: String?
    /// [tiles] A page's own `<title>`, tidied (`TileNames.cleanTitle`), read when its picture is drawn.
    var pageTitle: String?
    /// [tiles] The job its page says keeps it up to date (`<meta name="hq-tile-job">`).
    var jobId: String?
    /// [tile-versions] The version of its page that shows now, as last read from the bot's computer (`TileVersions`);
    /// nil until the app has kept one.
    var version: Int?

    var tileSize: PinTileSize { size ?? .small }

    /// [tiles] Its name in plain words (owner 2026-11-03: not "revenue.html"): the owner's, the page's title, else the
    /// file name in words. A link keeps its label.
    var name: String {
        if let title, !title.isEmpty { return title }
        return automaticName
    }

    /// Its name without the owner's: the page's title, else the file name in words (a link: its label).
    var automaticName: String {
        if let pageTitle, !pageTitle.isEmpty { return pageTitle }
        return kind == .link ? label : TileNames.pretty(label)
    }

    /// Its name is its file's in words: no name of the owner's or the page's own.
    var namedByFile: Bool { (title ?? "").isEmpty && (pageTitle ?? "").isEmpty && kind != .link }

    nonisolated static func key(profile: String?, value: String) -> String {
        let p = (profile ?? "").trimmingCharacters(in: .whitespaces)
        return (p.isEmpty ? "default" : p) + "\u{1F}" + value
    }

    init(kind: ArtifactRecord.Kind, value: String, label: String, profile: String?, sessionId: String, sessionTitle: String,
         pinnedAt: Double = Date().timeIntervalSince1970) {
        let owner = (profile ?? "").isEmpty ? "default" : profile!
        id = Self.key(profile: owner, value: value)
        self.kind = kind
        self.value = value
        self.label = label.isEmpty ? ArtifactCollector.label(value, kind: kind) : label
        self.profile = owner
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.pinnedAt = pinnedAt
    }

    init(_ record: ArtifactRecord) {
        self.init(kind: record.kind, value: record.value, label: record.label, profile: record.profile,
                  sessionId: record.sessionId, sessionTitle: record.sessionTitle)
    }

    /// The pin as an Artifacts record, so it opens, previews and shares as any artifact does. Its id is the pin's own
    /// ("pin:" first), apart from the chat-by-chat records in the list.
    var record: ArtifactRecord {
        ArtifactRecord(id: "pin:" + id, kind: kind, value: value, href: ArtifactCollector.href(value), label: label,
                       sessionId: sessionId, profile: profile, sessionTitle: sessionTitle, timestamp: pinnedAt * 1000)
    }

    /// An HTML page (pictured, and opened live).
    var isPage: Bool { kind == .file && ["html", "htm"].contains(ArtifactFiles.fileExtension(value)) }

    /// A path on the bot's computer the app can read straight (absolute, `~/`, or `file://`).
    var gatewayPath: String? {
        guard kind != .link, !value.hasPrefix("http://"), !value.hasPrefix("https://"), !value.hasPrefix("data:") else { return nil }
        if value.hasPrefix("file://") { return URL(string: value)?.path(percentEncoded: false) }
        return value
    }
}

/// [dashboard] One page of the Dashboard, as a Home Screen page (owner 2026-11-03: "pages … of these little dashboards
/// or widgets"). Main is always there and first; the others are the owner's, named and ordered.
nonisolated struct DashboardPage: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String

    static let mainId = "main"
    static let main = DashboardPage(id: mainId, name: "Main")
}

/// [dashboard] A pin's tile in Grid (tester feedback, 2026-11-01: "stack these in a grid layout it will actually feel like
/// a dashboard"): the sizes of a Home Screen widget, in grid cells. Extra Large (owner 2026-11-02, "more like widgets"):
/// the grid's whole width, three rows down, for a dashboard seen whole.
nonisolated enum PinTileSize: String, Codable, Sendable, CaseIterable {
    case small, medium, large, extraLarge

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// Columns across and rows down (Extra Large's width is cut to the grid's, `PinGridPacking`).
    var span: (columns: Int, rows: Int) {
        switch self {
        case .small: (1, 1)
        case .medium: (2, 1)
        case .large: (2, 2)
        case .extraLarge: (Self.wholeWidth, 3)
        }
    }

    static let wholeWidth = 99

    /// The size a tile dragged by its corner to this many cells takes (Edit Tiles): three rows or more Extra Large, two
    /// Large, one row two cells across Medium, else Small.
    static func fitting(columns: Int, rows: Int) -> PinTileSize {
        if rows >= 3 { return .extraLarge }
        if rows == 2 { return .large }
        return columns >= 2 ? .medium : .small
    }
}

/// [dashboard] Where Grid's tiles go: in order, each in the first place from the top where its span fits (a Small after
/// a Medium fills the gap a Large left beside it), as Home Screen widgets pack. A span wider than the grid is cut to it.
nonisolated enum PinGridPacking {
    struct Cell: Equatable {
        var column: Int, row: Int, columns: Int, rows: Int
    }

    static func place(_ spans: [(columns: Int, rows: Int)], columns: Int) -> (cells: [Cell], rows: Int) {
        let width = max(1, columns)
        var taken: [[Bool]] = []
        var cells: [Cell] = []
        func free(_ column: Int, _ row: Int, _ across: Int, _ down: Int) -> Bool {
            for r in row..<(row + down) where r < taken.count {
                for c in column..<(column + across) where taken[r][c] { return false }
            }
            return true
        }
        for span in spans {
            let across = min(max(1, span.columns), width), down = max(1, span.rows)
            var row = 0
            search: while true {
                for column in 0...(width - across) where free(column, row, across, down) {
                    while taken.count < row + down { taken.append(Array(repeating: false, count: width)) }
                    for r in row..<(row + down) { for c in column..<(column + across) { taken[r][c] = true } }
                    cells.append(Cell(column: column, row: row, columns: across, rows: down))
                    break search
                }
                row += 1
            }
        }
        return (cells, taken.count)
    }
}

/// [dashboard] How pins show: picture tiles in a grid, cards with their names and chats, or rows.
nonisolated enum PinsView: String, Sendable, CaseIterable {
    case grid, cards, list
}

@MainActor
final class ArtifactPins {
    /// Posted on the main actor after any change; `object` is the store.
    static let didChange = Notification.Name("hq.artifactPins.didChange")
    /// The most pins kept: the shelf is a glance, not a second list. [dashboard] 120 with Dashboard pages (60 was one page's worth).
    static let limit = 120

    private static var stores: [String: ArtifactPins] = [:]

    /// Posted when pins switch between Grid, Cards and List, or Grid's names come or go.
    static let viewChanged = Notification.Name("hq.artifactPins.viewChanged")
    private static let viewKey = "hq.artifactPins.view"
    private static let namesKey = "hq.artifactPins.gridNames"

    /// How pins show on the Pinned page and Artifacts' shelf. One choice for every account; Grid unless set (owner
    /// 2026-11-02: pins "more like widgets"; Cards was the first default).
    /// List: rows like Today's (tester, 2026-10-31: with many pages, big cards are slow to scroll past).
    /// [dashboard] Grid: picture tiles, as a dashboard of the pages the bots keep up to date (2026-11-01).
    static var view: PinsView {
        get { UserDefaults.standard.string(forKey: viewKey).flatMap(PinsView.init(rawValue:)) ?? .grid }
        set {
            guard newValue != view else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: viewKey)
            NotificationCenter.default.post(name: viewChanged, object: nil)
        }
    }

    static var showsList: Bool { view == .list }

    /// [dashboard] Grid's tiles have their names under them unless turned off (the tiles alone, a dashboard of charts).
    static var showsNames: Bool {
        get { UserDefaults.standard.object(forKey: namesKey) as? Bool ?? true }
        set {
            guard newValue != showsNames else { return }
            UserDefaults.standard.set(newValue, forKey: namesKey)
            NotificationCenter.default.post(name: viewChanged, object: nil)
        }
    }

    /// The pins of the account with this id (one store per account, made on first use).
    static func of(accountId: String) -> ArtifactPins {
        if let store = stores[accountId] { return store }
        let store = ArtifactPins(fileURL: fileURL(accountId: accountId))
        stores[accountId] = store
        return store
    }

    #if DEBUG
    /// `-HQDebugResetPins YES` (UI tests): no pins on any account, and Cards (Grid with names).
    static func debugReset() {
        try? FileManager.default.removeItem(at: PagesCache.root.appending(path: "pins", directoryHint: .isDirectory))
        UserDefaults.standard.set(PinsView.cards.rawValue, forKey: viewKey)   // the UI tests start from Cards
        UserDefaults.standard.removeObject(forKey: namesKey)
        stores = [:]
    }
    #endif

    nonisolated static func fileURL(accountId: String, root: URL = PagesCache.root) -> URL {
        let hash = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return root.appending(path: "pins", directoryHint: .isDirectory).appending(path: "\(hash).json")
    }

    let fileURL: URL?
    /// Newest pin first, unless reordered.
    private(set) var pins: [ArtifactPin] { didSet { clashCache = nil } }

    /// Mac polish #45: a pin's name as every list shows it: `ArtifactPin.name`, except that pins named by their files
    /// that read the same ("index.md" and "index.html", both "Index") keep their extensions.
    func name(_ pin: ArtifactPin) -> String {
        clashes.contains(pin.id) ? TileNames.pretty(pin.label, keepsExtension: true) : pin.name
    }

    /// The pin to draw: a copy named as `name(_:)` says (the kept pin is unchanged).
    func shown(_ pin: ArtifactPin) -> ArtifactPin {
        guard clashes.contains(pin.id) else { return pin }
        var copy = pin
        copy.title = name(pin)
        return copy
    }

    private var clashCache: Set<String>?
    private var clashes: Set<String> {
        if let clashCache { return clashCache }
        let found = TileNames.clashing(pins.map { ($0.id, $0.name, $0.namedByFile) })
        clashCache = found
        return found
    }

    /// [dashboard] The Dashboard's pages (Main first) and the one shown, beside the pins (`<hash>.pages.json`).
    private nonisolated struct PagesFile: Codable, Sendable {
        var pages: [DashboardPage]
        var current: String
    }

    private(set) var pages: [DashboardPage]
    /// The page the Dashboard shows, and where a new pin goes.
    var currentPage: String {
        didSet {
            guard currentPage != oldValue else { return }
            if !pages.contains(where: { $0.id == currentPage }) { currentPage = DashboardPage.mainId }
            changed()
        }
    }

    private var pagesURL: URL? { fileURL.map { $0.deletingPathExtension().appendingPathExtension("pages.json") } }

    init(fileURL: URL?) {
        self.fileURL = fileURL
        pins = fileURL.flatMap { PagesCache.read([ArtifactPin].self, $0) } ?? []
        let kept = fileURL.flatMap { PagesCache.read(PagesFile.self, $0.deletingPathExtension().appendingPathExtension("pages.json")) }
        var pages = kept?.pages.filter { $0.id != DashboardPage.mainId } ?? []
        pages.insert(kept?.pages.first { $0.id == DashboardPage.mainId } ?? .main, at: 0)
        self.pages = pages
        currentPage = kept.map(\.current).flatMap { id in pages.contains { $0.id == id } ? id : nil } ?? DashboardPage.mainId
    }

    /// [dashboard] The page a pin is on (Main when it names none, or a page since deleted).
    func pageId(of pin: ArtifactPin) -> String {
        guard let page = pin.page, pages.contains(where: { $0.id == page }) else { return DashboardPage.mainId }
        return page
    }

    func pins(onPage page: String) -> [ArtifactPin] { pins.filter { pageId(of: $0) == page } }

    /// [dashboard] A new page after the others; it becomes the one shown.
    @discardableResult
    func addPage(named name: String) -> DashboardPage {
        let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = DashboardPage(id: UUID().uuidString, name: words.isEmpty ? "Page \(pages.count + 1)" : words)
        pages.append(page)
        currentPage = page.id
        changed()
        return page
    }

    func renamePage(_ id: String, to name: String) {
        let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let index = pages.firstIndex(where: { $0.id == id }), pages[index].name != words else { return }
        pages[index].name = words
        changed()
    }

    /// [dashboard] A page deleted: its tiles go to Main, nothing unpinned. Main can't be deleted.
    func deletePage(_ id: String) {
        guard id != DashboardPage.mainId, let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: index)
        for i in pins.indices where pins[i].page == id { pins[i].page = nil }
        if currentPage == id { currentPage = pages[max(0, index - 1)].id }
        changed()
    }

    /// [dashboard] A page moved one place left (-1) or right (+1); Main stays first.
    func movePage(_ id: String, by step: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let target = index + step
        guard target >= 1, target < pages.count else { return }
        pages.swapAt(index, target)
        changed()
    }

    /// [dashboard] A tile moved to another page (the end of that page's tiles).
    func setPage(_ page: String, id: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }), pageId(of: pins[index]) != page,
              pages.contains(where: { $0.id == page }) else { return }
        var pin = pins.remove(at: index)
        pin.page = page == DashboardPage.mainId ? nil : page
        let last = pins.lastIndex { pageId(of: $0) == page }
        pins.insert(pin, at: last.map { $0 + 1 } ?? pins.count)
        changed()
    }

    func isPinned(profile: String?, value: String) -> Bool {
        let key = ArtifactPin.key(profile: profile, value: value)
        return pins.contains { $0.id == key }
    }

    func isPinned(_ record: ArtifactRecord) -> Bool { isPinned(profile: record.profile, value: record.value) }

    /// Every pin is taken: a new one is refused (it once pushed the last one out unsaid, maybe a tile on another page).
    var isFull: Bool { pins.count >= Self.limit }

    /// Pins it first; false when it's refused (full). Already pinned counts as pinned.
    @discardableResult
    func pin(_ pin: ArtifactPin) -> Bool {
        guard !pins.contains(where: { $0.id == pin.id }) else { return true }
        guard !isFull else { return false }
        var pin = pin
        // [dashboard] Onto the page last looked at.
        if pin.page == nil, currentPage != DashboardPage.mainId { pin.page = currentPage }
        pins.insert(pin, at: 0)
        changed()
        return true
    }

    /// An unpin undone: the pin as it was (its size, name and page) where it was.
    func restore(_ pin: ArtifactPin, at index: Int) {
        guard !pins.contains(where: { $0.id == pin.id }), !isFull else { return }
        pins.insert(pin, at: min(max(0, index), pins.count))
        changed()
    }

    func unpin(id: String) {
        let before = pins.count
        pins.removeAll { $0.id == id }
        if pins.count != before { changed() }
    }

    func unpin(profile: String?, value: String) { unpin(id: ArtifactPin.key(profile: profile, value: value)) }

    /// Pins `record` if it isn't, else unpins it; true when it is pinned now.
    @discardableResult
    func toggle(_ record: ArtifactRecord) -> Bool {
        if isPinned(record) { unpin(profile: record.profile, value: record.value); return false }
        return pin(ArtifactPin(record))
    }

    func move(from source: Int, to destination: Int) {
        guard pins.indices.contains(source), source != destination else { return }
        let moved = pins.remove(at: source)
        pins.insert(moved, at: min(max(0, destination), pins.count))
        changed()
    }

    /// [dashboard] A tile dragged onto another's place: it takes that place, the others moving up or down one (the pins
    /// on screen can be one bot's or a search's, so this goes by id, not by the position on screen).
    func move(id: String, to target: String) {
        guard let source = pins.firstIndex(where: { $0.id == id }), let destination = pins.firstIndex(where: { $0.id == target }) else { return }
        move(from: source, to: destination)
    }

    /// [dashboard] A pin's tile in Grid.
    func setSize(_ size: PinTileSize, id: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }), pins[index].tileSize != size else { return }
        pins[index].size = size
        changed()
    }

    /// [tiles] Rename…: the owner's name for it; empty goes back to the automatic one.
    func rename(id: String, to name: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        let words = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let title: String? = words.isEmpty ? nil : words
        guard pins[index].title != title else { return }
        pins[index].title = title
        changed()
    }

    /// [tiles] What its page's head said when it was last read (its title, its job).
    func notePage(id: String, head: TileNames.Head) {
        guard let index = pins.firstIndex(where: { $0.id == id }),
              pins[index].pageTitle != head.title || pins[index].jobId != head.jobId else { return }
        pins[index].pageTitle = head.title
        pins[index].jobId = head.jobId
        changed()
    }

    /// [tile-versions] The version that shows now (after one was kept, or a roll back).
    func noteVersion(id: String, _ number: Int) {
        guard number > 0, let index = pins.firstIndex(where: { $0.id == id }), pins[index].version != number else { return }
        pins[index].version = number
        changed()
    }

    /// A newer chat named a pinned file: the pin follows it (Show in Chat goes to where the file was last made).
    func follow(_ records: [ArtifactRecord]) {
        var newest: [String: ArtifactRecord] = [:]
        for record in records {
            let key = ArtifactPin.key(profile: record.profile, value: record.value)
            if let kept = newest[key], kept.timestamp >= record.timestamp { continue }
            newest[key] = record
        }
        var moved = false
        for index in pins.indices {
            guard let record = newest[pins[index].id], record.sessionId != pins[index].sessionId
                    || record.sessionTitle != pins[index].sessionTitle else { continue }
            pins[index].sessionId = record.sessionId
            pins[index].sessionTitle = record.sessionTitle
            moved = true
        }
        if moved { changed() }
    }

    /// [sync] Told after every change (the gateway copy follows).
    var syncChanged: (() -> Void)?

    private func changed() {
        if let fileURL { PagesCache.write(pins, to: fileURL) }
        if let pagesURL { PagesCache.write(PagesFile(pages: pages, current: currentPage), to: pagesURL) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        syncChanged?()
    }
}

// [sync] The pins and the Tiles pages, as every device signed in to the gateway sees them.
extension ArtifactPins: GatewaySynced {
    var syncName: String { "pins" }

    nonisolated struct SyncedPins: Codable {
        var pins: [ArtifactPin]
        var pages: [DashboardPage]
    }

    func syncValue() -> JSONValue {
        (try? JSONEncoder().encode(SyncedPins(pins: pins, pages: pages))).flatMap { try? JSONValue.parse($0) } ?? .null
    }

    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
        guard let remote = Self.decodeSynced(value) else { return }
        var remotePages = remote.pages.filter { $0.id != DashboardPage.mainId }
        remotePages.insert(remote.pages.first { $0.id == DashboardPage.mainId } ?? .main, at: 0)
        switch merge {
        case .replace:
            pins = remote.pins
            pages = remotePages
        case .firstContact:
            // Both devices had pins before they met: the gateway's first, then this device's that it lacked.
            let ids = Set(remote.pins.map(\.id))
            pins = Array((remote.pins + pins.filter { !ids.contains($0.id) }).prefix(Self.limit))
            let pageIds = Set(remotePages.map(\.id))
            pages = remotePages + pages.filter { !pageIds.contains($0.id) }
        case .rebase:
            // Both changed since they last agreed: the other device's changes, with this one's on top (a pin made here
            // stays, one unpinned here stays gone, a size or page changed here keeps this device's).
            let was = base.flatMap(Self.decodeSynced) ?? SyncedPins(pins: [], pages: [])
            pins = Self.merged(remote.pins, local: pins, base: was.pins)
            pages = Self.merged(remotePages, local: pages, base: was.pages)
            if pins.count > Self.limit { pins.removeLast(pins.count - Self.limit) }
        }
        if !pages.contains(where: { $0.id == DashboardPage.mainId }) { pages.insert(.main, at: 0) }
        if !pages.contains(where: { $0.id == currentPage }) { currentPage = DashboardPage.mainId }
        changed()
    }

    private static func decodeSynced(_ value: JSONValue) -> SyncedPins? {
        guard let data = try? value.encoded() else { return nil }
        return try? JSONDecoder().decode(SyncedPins.self, from: data)
    }

    /// A three-way merge of two lists of items by id: `remote`'s order, less what `local` dropped since `base`, with
    /// what `local` added first and `local`'s version of an item it changed.
    nonisolated static func merged<T: Identifiable & Equatable>(_ remote: [T], local: [T], base: [T]) -> [T] where T.ID == String {
        let baseById = Dictionary(base.map { ($0.id, $0) }) { a, _ in a }
        let localById = Dictionary(local.map { ($0.id, $0) }) { a, _ in a }
        let remoteIds = Set(remote.map(\.id))
        let dropped = Set(base.map(\.id)).subtracting(localById.keys)
        let added = local.filter { baseById[$0.id] == nil && !remoteIds.contains($0.id) }
        var out = added
        for item in remote where !dropped.contains(item.id) {
            if let mine = localById[item.id], let was = baseById[item.id], mine != was { out.append(mine) } else { out.append(item) }
        }
        return out
    }
}
