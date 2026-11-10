// More › Import Sessions (docs/spec/3x-morepages.md §14): Claude Code and Codex conversations found on the gateway
// computer, previewed and brought into Hermes. JSON-RPC (`AG/tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py`):
//   session.foreign.list     {profile?, source?: "claude"|"codex", offset?, limit?}
//                            → {sessions:[{id, source, label, title, cwd, mtime, turn_count, excerpt}], next_offset, host, unreadable}
//   session.foreign.preview  {profile?, id} → {messages:[{role, content}], total, truncated, already_imported: id|null, cwd}
//   session.foreign.import   {profile?, id} → {session_id, already_imported}
// Hermes answers error 4000 for any other key, so the builders below send exactly these. 60 s each
// (`V/app/session-import/api.ts:46`). `id` is an opaque handle, never a path. Words: `V/i18n/en.ts` sessionImport,
// `S/import-scan-help.ts`, `S/audit-c-format.ts` (`friendlyHostName`, `importPreviewText`).

import Foundation
import Observation

nonisolated struct ForeignSession: Identifiable, Hashable, Sendable {
    var id: String
    /// "claude", "codex" (anything else is kept as sent).
    var source: String
    /// "Claude Code" / "Codex".
    var label: String
    var title: String
    var cwd: String?
    var modified: Date?
    var turnCount: Int
    var excerpt: String

    /// A row, or nil when it has no usable id (a bad row is skipped, never a crash).
    init?(_ json: JSONValue) {
        guard json.object != nil, let id = json["id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        self.id = id
        source = json["source"]?.string ?? ""
        let label = json["label"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = label.isEmpty ? ForeignSessions.sourceName(source) : label
        title = json["title"]?.string ?? ""
        cwd = json["cwd"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        modified = json["mtime"]?.pgSeconds.map { Date(timeIntervalSince1970: $0) }
        turnCount = max(0, json["turn_count"]?.int ?? 0)
        excerpt = json["excerpt"]?.string ?? ""
    }

    init(id: String, source: String, label: String, title: String, cwd: String?, modified: Date?, turnCount: Int, excerpt: String) {
        self.id = id; self.source = source; self.label = label; self.title = title; self.cwd = cwd
        self.modified = modified; self.turnCount = turnCount; self.excerpt = excerpt
    }
}

nonisolated struct ForeignPage: Equatable, Sendable {
    var sessions: [ForeignSession]
    var nextOffset: Int?
    var host: String?
    var unreadable: Int

    init(_ json: JSONValue) {
        sessions = (json["sessions"]?.array ?? []).compactMap(ForeignSession.init)
        // A "next" that does not move forward would page for ever: only a positive offset counts.
        nextOffset = json["next_offset"]?.int.flatMap { $0 > 0 ? $0 : nil }
        host = json["host"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        unreadable = max(0, json["unreadable"]?.int ?? 0)
    }
}

nonisolated struct ForeignTurn: Hashable, Sendable {
    var role: String
    var content: String
    var isUser: Bool { role == "user" }
}

nonisolated struct ForeignPreview: Equatable, Sendable {
    var messages: [ForeignTurn]
    var total: Int
    var truncated: Bool
    /// The Hermes session this conversation already became, when it was imported before.
    var alreadyImported: String?
    var cwd: String?

    init(_ json: JSONValue) throws {
        guard json.object != nil else { throw PagesMessageError("The gateway’s answer could not be read.") }
        messages = (json["messages"]?.array ?? []).compactMap { turn in
            guard let content = turn["content"]?.string, !content.isEmpty else { return nil }
            return ForeignTurn(role: turn["role"]?.string ?? "assistant", content: content)
        }
        total = max(json["total"]?.int ?? messages.count, 0)
        truncated = json["truncated"]?.bool ?? false
        alreadyImported = json["already_imported"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        cwd = json["cwd"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }
}

nonisolated struct ForeignImportResult: Equatable, Sendable {
    var sessionId: String
    var alreadyImported: Bool

    init(_ json: JSONValue) throws {
        guard let id = json["session_id"]?.string, !id.isEmpty else {
            throw PagesMessageError("The gateway did not say which chat it made.")
        }
        sessionId = id
        alreadyImported = json["already_imported"]?.bool ?? false
    }
}

/// The three calls. Answers are decoded off the main thread.
nonisolated struct ForeignSessionsAPI: Sendable {
    let client: any GatewayClient
    static let timeout: Duration = .seconds(60)
    static let pageSize = 50

    /// `{profile?, source?, offset?, limit?}`: `source` only for Claude Code or Codex, `offset` only past the first page.
    static func listParams(profile: String?, source: String?, offset: Int, limit: Int = pageSize) -> JSONValue {
        var keys: [String: JSONValue] = ["limit": .number(Double(limit))]
        if let source, source == "claude" || source == "codex" { keys["source"] = .string(source) }
        if offset > 0 { keys["offset"] = .number(Double(offset)) }
        return MoreWire.profileParams(profile, keys)
    }

    /// `{profile?, id}`.
    static func idParams(profile: String?, id: String) -> JSONValue {
        MoreWire.profileParams(profile, ["id": .string(id)])
    }

    @concurrent
    func list(profile: String?, source: String?, offset: Int, limit: Int = pageSize) async throws -> ForeignPage {
        let json = try await client.call("session.foreign.list", Self.listParams(profile: profile, source: source, offset: offset, limit: limit),
                                         timeout: Self.timeout)
        guard json.object != nil else { throw PagesMessageError("The gateway’s answer could not be read.") }
        return ForeignPage(json)
    }

    @concurrent
    func preview(profile: String?, id: String) async throws -> ForeignPreview {
        try ForeignPreview(try await client.call("session.foreign.preview", Self.idParams(profile: profile, id: id), timeout: Self.timeout))
    }

    @concurrent
    func importSession(profile: String?, id: String) async throws -> ForeignImportResult {
        try ForeignImportResult(try await client.call("session.foreign.import", Self.idParams(profile: profile, id: id), timeout: Self.timeout))
    }
}

/// Pure rules and words.
nonisolated enum ForeignSessions {
    static let subtitle = "Bring a conversation into Hermes and pick up where you left off."
    static let scanning = "Finding Conversations…"
    static let emptyTitle = "No Conversations Found"
    static let emptyText = "Claude Code and Codex sessions on \(HostWord.phrase) will appear here."   // UX study #24
    static let scanErrorTitle = "Couldn’t Find Sessions"
    static let scanHelpText = "Check your connection to Hermes, then try again. An older Hermes may need an update."
    static let noMatchesTitle = "No Matching Conversations"
    static let noMatchesText = "Try another title or folder, or load more sessions."
    static let skipped = "Some logs were empty, unreadable, or too large to preview."
    static let loadMore = "Load More Sessions"
    static let searchPrompt = "Search Loaded Sessions"
    static let previewLimit = "Preview shortened for readability. The complete conversation is imported."
    static let copyNotice = "Copies conversation text. Source files stay unchanged. Tool output and reasoning are not carried over."
    static let alreadyHere = "This conversation is already in Hermes. Open your existing copy to continue."
    static let previewErrorTitle = "Preview Unavailable"
    static let previewErrorText = "The source may have moved or changed. Refresh the list and try again."
    static let importErrorTitle = "Couldn’t Import This Conversation"
    static let emptyPreview = "This conversation has no messages to preview."

    static func sourceName(_ source: String) -> String {
        switch source {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return source.isEmpty ? "Another App" : source.capitalized
        }
    }

    /// A page added to the rows already loaded: a row seen before keeps its place and takes the newer copy; nothing
    /// is listed twice (pages overlap when a log appears between two reads).
    static func merge(_ loaded: [ForeignSession], _ page: [ForeignSession]) -> [ForeignSession] {
        var out = loaded
        var place: [String: Int] = [:]
        for (index, row) in out.enumerated() where place[row.id] == nil { place[row.id] = index }
        // The loaded rows themselves are never trusted to be unique either.
        if place.count != out.count {
            var seen = Set<String>()
            out = out.filter { seen.insert($0.id).inserted }
            place = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.id, $0) })
        }
        for row in page {
            if let index = place[row.id] { out[index] = row } else { place[row.id] = out.count; out.append(row) }
        }
        return out
    }

    /// One line of words: line breaks and runs of spaces become single spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The row's first line: its title, else the app it came from.
    static func title(_ session: ForeignSession) -> String {
        let title = oneLine(session.title)
        if !title.isEmpty { return title }
        return session.label.isEmpty ? "Untitled Conversation" : "\(session.label) Conversation"
    }

    static func messages(_ count: Int) -> String { count == 1 ? "1 message" : "\(count) messages" }

    /// "site · 12 messages · 2 hours ago": the folder's name (when there is one), the turn count, how long ago.
    static func detail(_ session: ForeignSession, now: Date = Date(), locale: Locale = .current) -> String {
        var parts: [String] = []
        if let cwd = session.cwd, let name = cwd.split(separator: "/").last { parts.append(String(name)) }
        parts.append(messages(session.turnCount))
        if let modified = session.modified { parts.append(relative(modified, now: now, locale: locale)) }
        return parts.joined(separator: " · ")
    }

    static func relative(_ date: Date, now: Date, locale: Locale = .current) -> String {
        // Under a minute ago, or a gateway clock ahead of the phone's: never "in 3 minutes".
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The row's last lines: the excerpt on one line; nil when there is none.
    static func excerpt(_ session: ForeignSession) -> String? {
        let text = oneLine(session.excerpt)
        return text.isEmpty ? nil : String(text.prefix(400))
    }

    /// What VoiceOver reads for a row.
    static func spoken(_ session: ForeignSession, now: Date = Date()) -> String {
        [title(session), session.label, detail(session, now: now)].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Search over the loaded rows: title, folder and excerpt, any case (`V/app/session-import/index.tsx:67-69`).
    static func filter(_ rows: [ForeignSession], query: String) -> [ForeignSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { "\($0.title) \($0.cwd ?? "") \($0.excerpt)".lowercased().contains(needle) }
    }

    /// "Studio’s Mac mini" for "Studios-Mac-mini.local" (`friendlyHostName`); an address is left as it is.
    static func friendlyHost(_ host: String?) -> String {
        var name = (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [".local", ".lan", ".home", ".localdomain"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)); break
        }
        if name.isEmpty || name.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return name }
        var short = name
        if name.contains("."), !name.contains(where: \.isWhitespace) { short = String(name.split(separator: ".").first ?? Substring(name)) }
        short = short.replacingOccurrences(of: #"^(.+?)s-(Mac-mini|Mac-Studio|Mac-Pro|MacBook|iMac|Mac)\b"#, with: "$1’s-$2",
                                           options: [.regularExpression, .caseInsensitive])
        return short.split(separator: "-", omittingEmptySubsequences: true).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func readingFrom(_ host: String?) -> String {
        let name = friendlyHost(host)
        return "Reading from \(name.isEmpty ? HostWord.phrase : name)"
    }

    /// Why the list could not be read, from the error itself (`importScanHelp`): only a timeout is the slow scan; a
    /// sign-in, a gateway without the method, or no connection each need something else.
    static func scanHelp(_ error: Error) -> String {
        // A gateway without the method (-32601): the spec's "older Hermes" words; its More row goes next time.
        if MoreWire.isMissingRoute(error) { return MoreWire.olderHermes }
        if let http = error as? HTTPError, http.status == 401 || http.status == 403 { return scanHelp(message: "\(http.status)") }
        if PagesREST.isSlowAnswer(error) { return scanHelp(message: "timed out") }
        if let failure = error as? GatewayFailure { return scanHelp(message: failure.message) }
        if (error as NSError).domain == NSURLErrorDomain { return scanHelp(message: "could not connect") }
        return scanHelp(message: PagesREST.reason(error))
    }

    static func scanHelp(message raw: String) -> String {
        let message = raw
        func has(_ pattern: String) -> Bool { message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if has(#"\b(?:401|403)\b|authentication expired|rejected|sign in again"#) {
            return "Your sign-in to Hermes has expired or was rejected. Sign in again, then try again."
        }
        if has(#"\b404\b"#) { return "This Hermes doesn’t offer importing sessions yet. Update Hermes on \(HostWord.updateTarget) to use it." }
        if has(#"timed? ?out|timeout|took too long|\b(?:408|504)\b"#) {
            return "Reading the Claude Code and Codex logs on \(HostWord.phrase) took too long. Try again in a moment."
        }
        if has(#"offline|could not connect|couldn’t connect|can’t reach|connection was lost|not connected|network|failed to fetch|load failed"#) {
            return "Hermes HQ can’t reach \(HostWord.phrase). Check the connection, then try again."
        }
        let detail = oneLine(message)
        return !detail.isEmpty && detail.count <= 160 ? "\(scanHelpText) (\(detail))" : scanHelpText
    }

    /// A preview turn's text: runs of "[ran tool: x]" lines become one "Used x (2×) and y" line (`importPreviewText`).
    static func previewText(_ text: String) -> String {
        var out: [String] = []
        var run: [(name: String, count: Int)] = []
        func flush() {
            guard !run.isEmpty else { return }
            let names = run.map { $0.count > 1 ? "\($0.name) (\($0.count)×)" : $0.name }
            out.append("Used " + ListFormatter.localizedString(byJoining: names))
            run = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[ran tool: "), trimmed.hasSuffix("]"), !trimmed.dropFirst(11).dropLast().contains("]") {
                let name = trimmed.dropFirst(11).dropLast().trimmingCharacters(in: .whitespaces)
                if let index = run.firstIndex(where: { $0.name == name }) { run[index].count += 1 } else { run.append((name, 1)) }
            } else if trimmed.isEmpty && !run.isEmpty {
                continue    // blank lines between tool lines belong to the run
            } else {
                flush()
                out.append(String(line))
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// Who said a turn: "You", or the app the conversation came from.
    static func speaker(_ turn: ForeignTurn, label: String) -> String { turn.isUser ? "You" : (label.isEmpty ? "Assistant" : label) }
}

/// The list's state: which source and bot, the rows loaded so far, paging, and the first read's outcome.
@MainActor @Observable
final class ForeignSessionsStore {
    enum Source: String, CaseIterable, Identifiable, Sendable {
        case all, claude, codex
        var id: String { rawValue }
        var title: String { self == .all ? "All" : ForeignSessions.sourceName(rawValue) }
        /// What goes on the wire: nothing for All.
        var wire: String? { self == .all ? nil : rawValue }
    }

    enum Phase: Equatable {
        case loading
        case loaded
        /// The first read failed: the help text, and the raw reason for Copy Details.
        case failed(help: String, reason: String)
    }

    private let api: ForeignSessionsAPI
    private(set) var phase: Phase = .loading
    private(set) var rows: [ForeignSession] = []
    private(set) var nextOffset: Int?
    private(set) var host: String?
    private(set) var unreadable = 0
    private(set) var loadingMore = false
    /// A Load More that failed: the rows stay, the row says why and can be tapped again.
    private(set) var moreError: String?
    private(set) var source: Source = .all
    private(set) var profile: String
    var query = ""
    /// The first read's result (nil = it answered): the page hides its More row for a gateway without the method.
    @ObservationIgnored var onFirstRead: ((Error?) -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(client: any GatewayClient, profile: String) {
        api = ForeignSessionsAPI(client: client)
        self.profile = profile
    }

    var visible: [ForeignSession] { ForeignSessions.filter(rows, query: query) }
    var hasMore: Bool { nextOffset != nil }
    var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Reads the first page again (a new source or bot, Try Again, pull to refresh). Rows on screen stay until the
    /// answer when `keeping`.
    func reload(keeping: Bool = false) {
        generation += 1
        let mine = generation
        task?.cancel()
        loadingMore = false
        moreError = nil
        if !keeping || rows.isEmpty { phase = .loading; rows = []; nextOffset = nil; unreadable = 0 }
        let api = self.api, profile = self.profile, source = self.source.wire
        let start = ContinuousClock.now
        task = Task { [weak self] in
            do {
                let page = try await api.list(profile: profile, source: source, offset: 0)
                guard let self, self.generation == mine else { return }
                self.rows = ForeignSessions.merge([], page.sessions)
                self.nextOffset = page.nextOffset
                self.host = page.host ?? self.host
                self.unreadable = page.unreadable
                self.phase = .loaded
                self.onFirstRead?(nil)
                AppLog.trace("pages", "foreign sessions first page (\(source ?? "all")) in \(AppLog.ms(since: start)) ms: \(page.sessions.count) sessions, \(page.unreadable) unreadable, more \(page.nextOffset != nil)")
            } catch {
                guard let self, self.generation == mine, !(error is CancellationError) else { return }
                self.onFirstRead?(error)
                let reason = PagesREST.reason(error)
                AppLog.note("pages", "foreign sessions first page (\(source ?? "all")) failed after \(AppLog.ms(since: start)) ms: \(reason)")
                if keeping, !self.rows.isEmpty { self.phase = .loaded; return }
                self.rows = []
                self.nextOffset = nil
                self.phase = .failed(help: ForeignSessions.scanHelp(error), reason: reason)
            }
        }
    }

    /// Waits for the read in flight (tests, pull to refresh).
    func settle() async { await task?.value }

    /// The next page. A second tap while one is on its way does nothing.
    func loadMore() {
        guard phase == .loaded, !loadingMore, let offset = nextOffset else { return }
        loadingMore = true
        moreError = nil
        let mine = generation
        let api = self.api, profile = self.profile, source = self.source.wire
        task = Task { [weak self] in
            do {
                let page = try await api.list(profile: profile, source: source, offset: offset)
                guard let self, self.generation == mine else { return }
                let before = self.rows.count
                self.rows = ForeignSessions.merge(self.rows, page.sessions)
                // A page that brought nothing new and points nowhere further ends the list (never a loop).
                self.nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                if self.rows.count == before && page.sessions.isEmpty { self.nextOffset = nil }
                self.unreadable += page.unreadable
                self.loadingMore = false
                AppLog.trace("pages", "foreign sessions load more: \(self.rows.count - before) new, \(self.rows.count) total, more \(self.nextOffset != nil)")
            } catch {
                guard let self, self.generation == mine else { return }
                self.loadingMore = false
                if !(error is CancellationError) {
                    self.moreError = PagesREST.reason(error)
                    AppLog.note("pages", "foreign sessions load more failed: \(self.moreError ?? "")")
                }
            }
        }
    }

    func setSource(_ next: Source) {
        guard next != source else { return }
        source = next
        reload()
    }

    func setProfile(_ next: String) {
        guard next != profile else { return }
        profile = next
        reload()
    }

    func preview(_ session: ForeignSession) async throws -> ForeignPreview {
        try await api.preview(profile: profile, id: session.id)
    }

    func importSession(_ session: ForeignSession) async throws -> ForeignImportResult {
        let start = ContinuousClock.now
        do {
            let result = try await api.importSession(profile: profile, id: session.id)
            AppLog.trace("pages", "foreign session \(AppLog.tag(session.id)) import ok in \(AppLog.ms(since: start)) ms, already imported \(result.alreadyImported)")
            return result
        } catch {
            AppLog.note("pages", "foreign session \(AppLog.tag(session.id)) import failed after \(AppLog.ms(since: start)) ms: \(PagesREST.reason(error))")
            throw error
        }
    }
}
