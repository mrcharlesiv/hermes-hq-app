// A bot's newest computer_use or browser screenshot, updated live (docs/spec/3x-screen.md §5.2, §5.14): what the
// Screen shows when the gateway has no live screen. The pure rules are the web's `bot-activity-model.ts`, ported one
// for one; `ScreenshotFeed` is the model of one open fallback view.

import Foundation

nonisolated struct ScreenShot: Sendable, Equatable {
    var id: String
    /// A gateway path or a `data:image/…` URL.
    var src: String
    var caption: String
    /// Unix seconds; nil when the row carried no time.
    var at: Double?
}

nonisolated enum ScreenHostKind: Sendable, Equatable { case mac, windows }

nonisolated struct RecentScreenSession: Sendable, Equatable {
    var id: String
    var active: Double
    var cwd: String?
}

nonisolated enum ScreenshotRules {
    private static let actions: [String: String] = [
        "capture": "Looked at the screen", "screenshot": "Looked at the screen",
        "click": "Clicked", "left_click": "Clicked", "double_click": "Double-clicked", "right_click": "Right-clicked",
        "middle_click": "Clicked", "type": "Typed", "key": "Pressed keys", "hotkey": "Pressed keys",
        "press_key": "Pressed keys", "scroll": "Scrolled", "drag": "Dragged", "move": "Moved the pointer",
        "mouse_move": "Moved the pointer", "zoom": "Zoomed in", "wait": "Waited",
    ]
    private static let browser: [String: String] = [
        "browser_vision": "Looked at the page", "browser_screenshot": "Looked at the page",
        "browser_click": "Clicked in the browser", "browser_type": "Typed in the browser",
        "browser_scroll": "Scrolled the page", "browser_snapshot": "Read the page", "browser_back": "Went back",
    ]

    /// Tool arguments arrive as an object, or as the JSON text of one.
    static func arguments(_ args: JSONValue?) -> [String: JSONValue] {
        switch args {
        case .object(let record)?: return record
        case .string(let text)?: return (try? JSONValue.parse(Data(text.utf8)))?.object ?? [:]
        default: return [:]
        }
    }

    /// What the bot did, in plain words ("Clicked in Safari", "Opened example.com").
    static func shotCaption(tool: String, args: JSONValue?) -> String {
        let record = arguments(args)
        if tool.hasPrefix("computer_use") {
            let action = (record["action"]?.string ?? "").lowercased()
            let did = actions[action] ?? "Used the computer"
            if let app = record["app"]?.string, !app.isEmpty { return "\(did) in \(app)" }
            return did
        }
        if tool == "browser_navigate" {
            // The web's `new URL(url).host`: the host as written, with its port when it names one.
            if let url = record["url"]?.string, let parts = URLComponents(string: url), parts.scheme?.isEmpty == false,
               let host = parts.host, !host.isEmpty {
                return "Opened \(host.lowercased())\(parts.port.map { ":\($0)" } ?? "")"
            }
            return "Opened a page"
        }
        return browser[tool] ?? "Used the browser"
    }

    /// The arguments of each tool call in the rows, by call id (assistant rows' `tool_calls[].function.arguments`).
    static func callArgs(_ rows: [JSONValue]) -> [String: JSONValue] {
        var found: [String: JSONValue] = [:]
        for row in rows {
            for call in row["tool_calls"]?.array ?? [] {
                guard let id = call["id"]?.string, !id.isEmpty, let args = call["function"]?["arguments"] else { continue }
                found[id] = args
            }
        }
        return found
    }

    /// The newest stored screenshot in a page of stored rows, nil when there is none. The gateway pages rows in
    /// chronological order (an `order=latest` page is the newest rows, oldest of them first), so the newest is the
    /// last one that qualifies.
    static func latestShot(rows: [JSONValue]) -> ScreenShot? {
        let args = callArgs(rows)
        for index in rows.indices.reversed() {
            let row = rows[index]
            guard row["role"]?.string == "tool" else { continue }
            let tool = row["tool_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? row["name"]?.string ?? ""
            guard ToolScreenshots.isScreenshotTool(tool) else { continue }
            let src = ToolScreenshots.storedScreenshot(row["content"])
            guard !src.isEmpty else { continue }
            let at: Double? = { if case .number(let n)? = row["timestamp"] { return n } else { return nil } }()
            let callId = row["tool_call_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            let id = callId ?? "\(tool)-\(at.map(stamp) ?? String(index))"
            let own: JSONValue? = row["args"].flatMap { $0.isNull ? nil : $0 }
            return ScreenShot(id: id, src: src, caption: shotCaption(tool: tool, args: own ?? callId.flatMap { args[$0] }), at: at)
        }
        return nil
    }

    /// The screenshot of a live `tool.complete` payload, nil when it carries none.
    static func liveShot(payload: JSONValue, now: Double) -> ScreenShot? {
        guard let tool = payload["name"]?.string, ToolScreenshots.isScreenshotTool(tool) else { return nil }
        let src = ToolScreenshots.liveSource(result: payload["result"], resultText: payload["result_text"]?.string,
                                             summary: payload["summary"]?.string)
        guard !src.isEmpty else { return nil }
        let id = payload["tool_id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "\(tool)-\(stamp(now))"
        return ScreenShot(id: id, src: src, caption: shotCaption(tool: tool, args: payload["args"]), at: now)
    }

    private static func stamp(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 9e15 ? String(Int64(value)) : String(value)
    }

    /// "just now", "12 s ago", "3 min ago", "2 h ago", else a short date. "" without a time.
    static func shotAge(at: Double?, now: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let at else { return "" }
        let seconds = Int(max(0, min(now - at, 4e9)).rounded())
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = timeZone
        format.setLocalizedDateFormatFromTemplate("MMMd")
        return format.string(from: Date(timeIntervalSince1970: at))
    }

    /// The gateway computer's kind, guessed from file paths (a screenshot's, a session's folder). nil: no telling.
    static func hostKind(_ paths: [String?]) -> ScreenHostKind? {
        for case let path? in paths where !path.isEmpty {
            if ToolScreenshots.isRemote(path) { continue }
            let chars = Array(path.prefix(3))
            if chars.count == 3, chars[0].isASCII, chars[0].isLetter, chars[1] == ":", chars[2] == "\\" || chars[2] == "/" { return .windows }
            if path.contains("\\") { return .windows }
            for root in ["/Users/", "/Volumes/", "/private/", "/Applications/", "/opt/homebrew/"] where path.hasPrefix(root) { return .mac }
        }
        return nil
    }

    /// Heading and sub-line of the latest screenshots view (§5.14).
    /// `managed`: a Hermes Cloud agent, whose Hermes Nous updates (the person can't).
    static func heading(_ reason: ScreenSession.Fallback, name: String, host: ScreenHostKind?, blocker: String?,
                        managed: Bool = false) -> (title: String, detail: String) {
        if managed, case .unavailable = reason {
            return ("Screen isn’t on this Hermes Cloud release yet",
                    "Nous updates Hermes on its agents. Meanwhile, \(name)’s latest screenshot shows here.")
        }
        switch reason {
        case .unsupported:
            return (host == .windows ? "Live screen sharing isn’t available on \(HostWord.phrase)"
                                     : "Screen sharing isn’t set up on \(HostWord.phrase)",
                    "Instead, \(name)’s latest screenshot shows here and updates while the bot works.")
        case .blocked:
            var lead = ""
            if let blocker, !blocker.isEmpty {
                lead = (blocker.hasSuffix(".") ? String(blocker.dropLast()) : blocker) + ". "
            }
            return ("Screen sharing needs attention", "\(lead)Meanwhile, \(name)’s latest screenshot shows here.")
        case .unavailable:
            return ("Screen needs a newer Hermes",
                    "Update Hermes on \(HostWord.updateTarget) to watch live. Meanwhile, \(name)’s latest screenshot shows here.")
        }
    }

    /// The sessions of `GET /api/profiles/sessions`, newest activity first.
    static func sessions(_ data: Data) throws -> [RecentScreenSession] {
        let json = try JSONValue.parse(data)
        return (json["sessions"]?.array ?? []).compactMap { row -> RecentScreenSession? in
            guard let id = row["id"]?.string, !id.isEmpty else { return nil }
            let active: Double = { if case .number(let n)? = row["last_active"] { return n } else { return 0 } }()
            return RecentScreenSession(id: id, active: active, cwd: row["cwd"]?.string)
        }.sorted { $0.active > $1.active }
    }

    static func rows(_ data: Data) throws -> [JSONValue] { try JSONValue.parse(data)["messages"]?.array ?? [] }
}

/// One poll of a bot's stored screenshots. Messages are fetched only when its latest session moved; a failed read is
/// retried on the next poll (never a false "no screenshots"), and two failures in a row say "unreachable".
@MainActor final class ScreenshotPoller {
    enum Empty: Equatable { case none, unreachable }

    var sessions: () async throws -> [RecentScreenSession]
    var messages: (String, Int) async throws -> [JSONValue]
    var shot: (ScreenShot) -> Void = { _ in }
    var empty: (Empty) -> Void = { _ in }
    var seenSessions: ([RecentScreenSession]) -> Void = { _ in }

    private var seen: String?
    private var found = false
    private var failures = 0

    init(sessions: @escaping () async throws -> [RecentScreenSession], messages: @escaping (String, Int) async throws -> [JSONValue]) {
        self.sessions = sessions
        self.messages = messages
    }

    func poll() async {
        do {
            let recent = try await sessions()
            seenSessions(recent)
            guard let latest = recent.first else {
                seen = nil
                failures = 0
                empty(.none)
                return
            }
            let mark = "\(latest.id):\(latest.active)"
            if mark == seen { return }
            let rows = try await messages(latest.id, found ? 8 : 40)
            seen = mark
            failures = 0
            if let next = ScreenshotRules.latestShot(rows: rows) {
                found = true
                shot(next)
            } else {
                empty(.none)
            }
        } catch {
            failures += 1
            if failures >= 2 { empty(.unreachable) }
        }
    }
}

/// The model of one open latest-screenshots view.
@MainActor final class ScreenshotFeed {
    /// `unloadable`: the screenshot is known but its picture could not be fetched (a dropped connection, a timeout, a
    /// 5xx). Not `expired`: only "the file is not there" (404/410) says the gateway let it go (review finding 5).
    enum State: Equatable { case searching, none, unreachable, loading, expired, shown, unloadable }

    /// Tried again on each of the next polls this many times, then on every tenth poll (about every 30 s).
    static let quickLoadTries = 5

    static let pollEvery: TimeInterval = 3

    let profile: String
    let name: String
    private(set) var shot: ScreenShot?
    private(set) var state: State = .searching
    private(set) var working = ""
    /// Goes up each time the picture should be fetched again; the view loads when it differs from what it tried.
    private(set) var loadAttempt = 0
    private var loadFailures = 0
    private var ticksSinceFailure = 0
    private(set) var sessionHost: ScreenHostKind?
    private(set) var recentSessions: Set<String> = []
    /// Anything above changed.
    var onChange: (() -> Void)?
    /// A new picture is to be shown (not the first one): the view announces it.
    var onNewShot: (() -> Void)?
    /// Whether a live event belongs to this bot (the app knows which chats it has live); stored ids the last poll
    /// listed always count.
    var isMine: (GatewayEvent) -> Bool = { _ in false }
    var now: () -> Double = { Date().timeIntervalSince1970 }
    var slow: () -> Bool = { ScreenPower.slow }

    private let client: any GatewayClient
    private let poller: ScreenshotPoller
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var visible = false
    private var busy = false

    init(client: any GatewayClient, profile: String, name: String) {
        self.client = client
        self.profile = profile
        self.name = name
        poller = ScreenshotPoller(
            sessions: {
                let query = [("limit", "3"), ("offset", "0"), ("min_messages", "1"), ("archived", "exclude"),
                             ("order", "recent"), ("profile", profile)].map { URLQueryItem(name: $0.0, value: $0.1) }
                return try ScreenshotRules.sessions(try await client.rest("GET", "/api/profiles/sessions", query: query, body: nil))
            },
            messages: { id, limit in
                let query = [("limit", String(limit)), ("order", "latest"), ("profile", profile)].map { URLQueryItem(name: $0.0, value: $0.1) }
                let path = "/api/sessions/\(HistoryRequest.encodePathSegment(id))/messages"
                return try ScreenshotRules.rows(try await client.rest("GET", path, query: query, body: nil))
            })
        poller.shot = { [weak self] in self?.offer($0) }
        poller.empty = { [weak self] next in
            guard let self, state == .searching || state == .unreachable else { return }
            set(next == .none ? .none : .unreachable)
        }
        poller.seenSessions = { [weak self] sessions in
            guard let self else { return }
            recentSessions = Set(sessions.map(\.id))
            if sessionHost == nil, let kind = ScreenshotRules.hostKind(sessions.map(\.cwd)) {
                sessionHost = kind
                onChange?()
            }
        }
    }

    isolated deinit {
        pollTask?.cancel()
        eventTask?.cancel()
    }

    /// The gateway computer's kind: the shown screenshot's path decides, else a session's folder.
    var hostKind: ScreenHostKind? { ScreenshotRules.hostKind([shot?.src]) ?? sessionHost }

    /// "<caption> · <age>", or "<working>…" in place of the caption while a tool runs.
    func caption(now: Double? = nil) -> String {
        let lead = working.isEmpty ? (shot?.caption ?? "") : "\(working)…"
        guard let shot else { return lead }
        return [lead, ScreenshotRules.shotAge(at: shot.at, now: now ?? self.now())].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The line the picture frame holds when there is no picture.
    var emptyLine: String {
        switch state {
        case .searching: "Looking for screenshots…"
        case .none: "No screenshots yet. When \(name) uses its computer or browser, the newest one appears here."
        case .unreachable: "Can’t reach the gateway to look for screenshots. Trying again…"
        case .loading: "Loading the screenshot…"
        case .unloadable: "Can’t load the screenshot. Trying again…"
        case .expired: ToolScreenshots.expiredNote
        case .shown: ""
        }
    }

    /// On screen and the app active: the poll and the live events run only then.
    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        pollTask?.cancel()
        pollTask = nil
        if eventTask == nil { listen() }
        guard on else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await tick()
                let wait = Self.pollEvery * (slow() ? 2 : 1)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() {
        visible = false
        pollTask?.cancel()
        pollTask = nil
        eventTask?.cancel()
        eventTask = nil
    }

    /// One poll (one at a time; skipped while hidden).
    func tick() async {
        guard visible, !busy else { return }
        busy = true
        await poller.poll()
        busy = false
        retryDue()
    }

    /// After each poll: a picture that could not be fetched is asked for again (the view loads on `loadAttempt`).
    func retryDue() {
        guard state == .unloadable else { return }
        ticksSinceFailure += 1
        if loadFailures <= Self.quickLoadTries || ticksSinceFailure % 10 == 0 {
            loadAttempt += 1
            onChange?()
        }
    }

    /// The view loaded (or could not load) the picture of `id`.
    func loaded(_ id: String, ok: Bool) {
        guard shot?.id == id else { return }
        loadFailures = 0
        set(ok ? .shown : .expired)
    }

    /// The picture of `id` could not be fetched, and nothing says its file is gone: it is tried again.
    func loadFailed(_ id: String) {
        guard shot?.id == id else { return }
        loadFailures += 1
        ticksSinceFailure = 0
        set(.unloadable)
    }

    /// Only the gateway saying the file is not there makes a capture expired.
    nonisolated static func isGone(_ error: Error) -> Bool {
        guard let http = error as? HTTPError else { return false }
        return http.status == 404 || http.status == 410
    }

    func handle(_ event: GatewayEvent) {
        guard event.type == "tool.complete" || event.type == "tool.start" else { return }
        guard isMine(event) || (event.payload["stored_session_id"]?.string).map(recentSessions.contains) == true else { return }
        if event.type == "tool.complete" {
            if let next = ScreenshotRules.liveShot(payload: event.payload, now: now()) { offer(next) }
            if !working.isEmpty {
                working = ""
                onChange?()
            }
        } else if let tool = event.payload["name"]?.string, ToolScreenshots.isScreenshotTool(tool) {
            working = ScreenshotRules.shotCaption(tool: tool, args: event.payload["args"])
            onChange?()
        }
    }

    private func listen() {
        let events = client.events(matching: ["tool.start", "tool.complete"])
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    /// A newer capture replaces the shown one; the same capture arriving by REST after its live event does not.
    private func offer(_ next: ScreenShot) {
        if let shot, shot.id == next.id || (next.at ?? 0) < (shot.at ?? 0) { return }
        let first = shot == nil
        shot = next
        // The previous picture stays up while the next one loads.
        loadFailures = 0
        if ToolScreenshots.isInline(next.src) { state = .shown } else if state != .shown { state = .loading }
        if !first { onNewShot?() }
        onChange?()
    }

    private func set(_ next: State) {
        guard state != next else { return }
        state = next
        onChange?()
    }
}
