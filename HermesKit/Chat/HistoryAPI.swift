// REST history reads (spec 03 §2): the core `/api/sessions/{id}/messages` route, the optional performance-plugin
// route (§2.3), page decoding with every pagination shape the fixtures and Hermes send (§12 F2), and the
// `atTurn` cut (§4.4). Decoding + folding run off the main actor.

import Foundation
import Synchronization

nonisolated struct HistoryPagination: Sendable, Equatable {
    var limit: Int?
    var offset: Int
    var order: String?
    var returned: Int
    var hasMore: Bool?
    var nextOffset: Int?
    var total: Int?
}

nonisolated struct HistoryPage: Sendable {
    var sessionId: String?                  // resolved stored id (may differ from the requested one)
    var profile: String?
    var rows: [JSONValue]
    var pagination: HistoryPagination?      // nil = legacy complete transcript (F-e)
    /// The request this answers.
    var requestedLimit: Int?
    var requestedOffset: Int
    var order: String

    /// Echoed `latest` (a page that ignored `order` is not a tail, §2.1).
    var isLatestTail: Bool { pagination == nil || pagination?.order == nil || pagination?.order == "latest" }

    /// More older rows may exist (§5.1: explicit has_more/next_offset win; else returned ≥ half the limit).
    /// Hermes counts `returned` after it drops hidden rows from the page (internal notes, hidden turns), so a page of
    /// 121 stored rows can come back as 114: read as the start, Northwind's chat showed only its last two days
    /// (owner, 2026-10-23). A page at least half full may have more; the read before it says so by coming back empty.
    var possiblyTruncated: Bool {
        guard let p = pagination else { return false }
        if let more = p.hasMore { return more }
        if let total = p.total { return p.offset + p.returned < total }
        guard let limit = p.limit ?? requestedLimit else { return false }
        return p.returned > 0 && p.returned * 2 >= limit
    }

    /// Backend rows from the newest end through this page's oldest row.
    var nextOffset: Int {
        if let n = pagination?.nextOffset { return n }
        return (pagination?.offset ?? requestedOffset) + rows.count
    }

    static func rowId(_ row: JSONValue) -> Int? { row["row_id"]?.positiveInt ?? row["id"]?.positiveInt }
    /// The gateway's time of the newest of `rows` (server seconds), nil when none carries one.
    static func newestTimestamp(_ rows: [JSONValue]) -> Double? {
        rows.lazy.compactMap { $0["timestamp"]?.double }.filter { $0.isFinite && $0 > 0 }.max()
    }
}

nonisolated struct HistoryRequest: Sendable, Hashable {
    var storedSessionId: String
    var profile: String?
    var limit: Int?
    var offset: Int = 0
    var order: String = "latest"
    var inlineImages: Bool? = nil

    /// Path + query for the core route. `profile` first, as the web client sends it (04 §1.4).
    func core() -> (path: String, query: [URLQueryItem]) {
        var q: [URLQueryItem] = []
        if let profile { q.append(URLQueryItem(name: "profile", value: profile)) }
        if let limit { q.append(URLQueryItem(name: "limit", value: String(limit))) }
        if offset > 0 { q.append(URLQueryItem(name: "offset", value: String(offset))) }
        q.append(URLQueryItem(name: "order", value: order))
        q.append(URLQueryItem(name: "include_compacted", value: "true"))
        if let inlineImages { q.append(URLQueryItem(name: "inline_images", value: inlineImages ? "true" : "false")) }
        return ("/api/sessions/\(HistoryRequest.encodePathSegment(storedSessionId))/messages", q)
    }

    /// The performance plugin rewrite (§2.3), without cursors (M1 pages by offset).
    func plugin(_ features: PerformanceFeatures) -> (path: String, query: [URLQueryItem]) {
        var (path, query) = core()
        if features.historyPath {
            path = "/api/plugins/\(features.routeName)/sessions/\(HistoryRequest.encodePathSegment(storedSessionId))/messages"
        }
        if features.historyDisplay {
            query.append(URLQueryItem(name: "projection", value: "display.v1"))
            query.append(URLQueryItem(name: "max_bytes", value: "65536"))
        }
        if features.historyPath && features.historyToolRefs { query.append(URLQueryItem(name: "tool_refs", value: "content.v1")) }
        return (path, query)
    }

    static func encodePathSegment(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// `gateway.ready.performance` advertisement (§2.3). Only flags equal to 1 count.
nonisolated struct PerformanceFeatures: Sendable, Equatable {
    var historyDisplay = false
    var historyPath = false
    var historyToolRefs = false
    /// VOICE: `media_waveform == 1` with a history path: memo waveforms from the plugin (spec 1x-voice §6.3).
    var mediaWaveform = false
    var routeName = "hermes-hq-performance"

    var isActive: Bool { historyDisplay || historyPath }

    init() {}

    init?(ready payload: JSONValue?) {
        guard let perf = payload?["performance"]?.object, perf["version"]?.int == 1 else { return nil }
        func on(_ key: String) -> Bool { perf[key]?.double == 1 }
        if let path = perf["history_path"]?.string,
           path.range(of: #"^(hermes-hq|dispatch)-performance\.v1$"#, options: .regularExpression) != nil {
            historyPath = true
            routeName = String(path.dropLast(3))
        }
        historyDisplay = on("history_display")
        historyToolRefs = on("history_tool_refs")
        mediaWaveform = historyPath && on("media_waveform")   // VOICE
        if !isActive { return nil }
    }
}

/// Accounts whose performance-plugin history route was refused (400/404/422) while the core route answered (§2.3): the
/// plugin route stays off for that account until the gateway restarts (a new `replay_epoch`), shared by every open chat.
nonisolated final class PluginRouteGate: Sendable {
    static let shared = PluginRouteGate()
    private let disabled = Mutex<[String: String]>([:])    // account id → replay epoch when it was turned off

    init() {}

    func isDisabled(account: String, epoch: String) -> Bool { disabled.withLock { $0[account] == epoch } }
    func disable(account: String, epoch: String) { disabled.withLock { $0[account] = epoch } }
    func reset() { disabled.withLock { $0 = [:] } }
}

nonisolated enum HistoryAPI {
    /// Decodes a REST page (core, plugin, fixture or legacy shapes).
    static func decodePage(_ data: Data, request: HistoryRequest) throws -> HistoryPage {
        let json = try ChatJSON.parse(data)
        guard let root = json.object else { throw HTTPError(status: 200, body: "history page is not an object") }
        let rows = root["messages"]?.array ?? []
        var pagination: HistoryPagination?
        if let p = root["pagination"]?.object {
            pagination = HistoryPagination(limit: p["limit"]?.int, offset: p["offset"]?.int ?? request.offset,
                                           order: p["order"]?.string, returned: p["returned"]?.int ?? rows.count,
                                           hasMore: p["has_more"]?.bool, nextOffset: p["next_offset"]?.int,
                                           total: p["total"]?.int)
        } else if request.limit != nil, root["has_more"] != nil || root["total"] != nil {
            // Legacy fixtures (F-e): `{messages,total,has_more}` = the complete transcript.
            pagination = nil
        }
        let page = HistoryPage(sessionId: root["session_id"]?.string, profile: root["profile"]?.string, rows: rows,
                           pagination: pagination, requestedLimit: request.limit, requestedOffset: request.offset,
                           order: request.order)
        AppLog.trace("history", "page \(AppLog.tag(request.storedSessionId)) (answer \(AppLog.tag(page.sessionId))): asked limit \(request.limit.map(String.init) ?? "-") offset \(request.offset); \(rows.count) rows, pagination \(pagination.map { "limit \($0.limit.map(String.init) ?? "-") offset \($0.offset) returned \($0.returned) has_more \($0.hasMore.map { "\($0)" } ?? "-") next \($0.nextOffset.map(String.init) ?? "-") total \($0.total.map(String.init) ?? "-") order \($0.order ?? "-")" } ?? "none (complete)") → more=\(page.possiblyTruncated), next offset \(page.nextOffset)")
        return page
    }

    /// `atTurn` cut (R:src/open-page.ts:43-56): a full first page drops leading assistant/tool rows up to the first
    /// user/system row when that keeps ≥ half the page, so a turn isn't split across pages. Returns rows dropped.
    static func cutAtTurn(_ page: inout HistoryPage) -> Int {
        guard let limit = page.requestedLimit, limit < 120, page.isLatestTail, let p = page.pagination,
              p.returned >= (p.limit ?? limit), p.returned >= limit else { return 0 }
        guard let first = page.rows.firstIndex(where: { row in
            let role = row["role"]?.string
            return role == "user" || role == "system"
        }), first > 0 else { return 0 }
        let kept = page.rows.count - first
        guard kept * 2 >= page.rows.count else { return 0 }
        AppLog.trace("history", "page cut at turn: \(first) leading reply rows dropped, \(kept) kept (a turn isn't split)")
        page.rows.removeFirst(first)
        var pagination = p
        pagination.returned = kept
        pagination.limit = kept
        pagination.nextOffset = p.offset + kept
        pagination.hasMore = true
        page.pagination = pagination
        return first
    }

    /// Signature of a row for the refresh probe (§7.6): `rowId:jsonLength:FNV-1a`.
    static func signature(_ row: JSONValue) -> String {
        let json = ChatJSON.stringify(row)
        return "\(HistoryPage.rowId(row) ?? 0):\(json.utf8.count):\(ChatText.fnv1a(json))"
    }

    /// Folds a page off the main thread.
    @concurrent
    static func fetchAndFold(client: any GatewayClient, request: HistoryRequest, features: PerformanceFeatures?,
                             cut: Bool) async throws -> (HistoryPage, HydratedPage, usedPlugin: Bool) {
        let (page, usedPlugin) = try await fetch(client: client, request: request, features: features)
        var mutable = page
        if cut { _ = cutAtTurn(&mutable) }
        // [attachments] decoded inline images go to this account's media folder (docs/spec/1x-attachments.md §8.1)
        let folded = InlineMediaStore.$accountId.withValue(client.account.id) { Hydration.fold(mutable.rows) }
        return (mutable, folded, usedPlugin)
    }

    /// One history read. Through the plugin when advertised and not turned off for the account; a 400/404/422 from it
    /// falls back to the core route, and a core answer then turns the plugin route off for the account (§2.3).
    /// A response too large for the transport (§6.6, native M1): the same read with `limit` halved down to 1, then that
    /// 1-row read once more with `inline_images=false`.
    @concurrent
    static func fetch(client: any GatewayClient, request: HistoryRequest, features: PerformanceFeatures?,
                      gate: PluginRouteGate = .shared) async throws -> (HistoryPage, usedPlugin: Bool) {
        var attempt = request
        while true {
            do {
                return try await fetchOnce(client: client, request: attempt, features: features, gate: gate)
            } catch where isResponseTooLarge(error) {
                AppLog.note("history", "page \(AppLog.tag(request.storedSessionId)) too large at limit \(attempt.limit.map(String.init) ?? "-") inline images \(attempt.inlineImages != false); retrying smaller")
                if let limit = attempt.limit, limit > 1 {
                    attempt.limit = max(1, limit / 2)
                } else if attempt.limit == nil {
                    attempt.limit = 60
                } else if attempt.inlineImages != false {
                    attempt.inlineImages = false
                } else {
                    throw error
                }
            }
        }
    }

    private static func fetchOnce(client: any GatewayClient, request: HistoryRequest, features: PerformanceFeatures?,
                                  gate: PluginRouteGate) async throws -> (HistoryPage, usedPlugin: Bool) {
        let account = client.account.id
        let epoch = client.latestReady?["replay_epoch"]?.string ?? ""
        var pluginRefused = false
        if let features, features.isActive, !gate.isDisabled(account: account, epoch: epoch) {
            let (path, query) = request.plugin(features)
            do {
                let data = try await client.rest("GET", path, query: query, body: nil)
                return (try decodePage(data, request: request), true)
            } catch let error as HTTPError where [400, 404, 422].contains(error.status) {
                AppLog.note("history", "plugin history route refused \(error.status) for \(AppLog.tag(request.storedSessionId)); core route instead")
                pluginRefused = true          // fall through to the core route
            }
        }
        let (path, query) = request.core()
        let data = try await client.rest("GET", path, query: query, body: nil)
        let page = try decodePage(data, request: request)
        if pluginRefused {
            AppLog.note("history", "plugin history route turned off for this account until the gateway restarts (core route answered)")
            gate.disable(account: account, epoch: epoch)
        }
        return (page, false)
    }

    /// The transport refused a body over its cap (Net's `GatewayFailure.responseTooLarge`, stable code
    /// `response-too-large`, spec 01 §18). Matched by its description so this module doesn't depend on Net's error type
    /// (a typed error in the shared contracts is listed as a wanted contract change).
    static func isResponseTooLarge(_ error: any Error) -> Bool {
        if error is HTTPError || error is RPCError || error is CancellationError || error is URLError { return false }
        let text = String(describing: error)
        return text == "response-too-large" || text == "responseTooLarge"
    }
}
