// Status & Maintenance's and Usage's wire (docs/spec/3x-morepages.md §15; the web's Command Center): the gateway's
// status, recent logs, usage and update check, decoded leniently (`AG/hermes_cli/web_routers/status.py`,
// `analytics.py`, `actions.py`; shapes `V/types/hermes.ts`), plus the pure words and number formats the pages show. A
// missing field reads "—"; a bad row is skipped.

import Foundation

/// [status-page] The pages' names, said the same wherever they are opened: More's rows, Settings › Gateway's row, More
/// search, a tab, the Mac's sidebar (owner 2026-11-03: one home per page, one name for it). The code keeps the old
/// name in its ids and types (`command-center`, `CommandCenter…`): saved tabs, row availability and tests use them.
nonisolated enum CommandCenterNames {
    static let page = "Status & Maintenance"
    /// Its Usage tab, now a page of its own beside it.
    static let usage = "Usage"
}

// MARK: - Status

/// `GET /api/status`: the keys Status & Maintenance's status sections show.
nonisolated struct GatewayStatusReport: Sendable, Equatable {
    struct Platform: Sendable, Equatable, Identifiable {
        var id: String
        var state: String
        var error: String?

        var name: String { GatewayStatusReport.platformName(id) }
        var words: String { GatewayStatusReport.stateWords(state) }
        var isUp: Bool { ["connected", "running", "ready", "ok"].contains(state.lowercased()) }
        var isDown: Bool { ["error", "fatal", "failed", "crashed"].contains(state.lowercased()) || error != nil }
    }

    var version: String?
    var releaseDate: String?
    var gatewayRunning: Bool?
    var gatewayState: String?
    var activeSessions: Int?
    var platforms: [Platform]
    /// `can_update_hermes`: false where updates are managed outside Hermes (a container). Absent on older gateways.
    var canUpdate: Bool

    init(json: JSONValue) {
        version = json["version"]?.pgString.flatMap { $0.isEmpty ? nil : $0 }
        releaseDate = json["release_date"]?.pgString
        gatewayRunning = json["gateway_running"]?.bool
        gatewayState = json["gateway_state"]?.string
        activeSessions = json["active_sessions"]?.int
        canUpdate = json["can_update_hermes"]?.bool ?? true
        var seen = Set<String>()
        platforms = (json["gateway_platforms"]?.object ?? [:]).compactMap { id, value -> Platform? in
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            // An older gateway wrote the state as a bare string.
            let state = value["state"]?.pgString ?? value.string ?? "unknown"
            let error = value["error_message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return Platform(id: id, state: state, error: error)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Hermes 0.21.5", as Settings › About names the gateway's Hermes.
    var versionWords: String { version.map { "Hermes \($0)" } ?? "—" }
    var gatewayWords: String { gatewayRunning.map { $0 ? "Running" : "Stopped" } ?? "—" }
    var sessionsWords: String { activeSessions.map(String.init) ?? "—" }

    static func platformName(_ id: String) -> String {
        let known = ["whatsapp": "WhatsApp", "imessage": "iMessage", "sms": "SMS", "api_server": "API Server", "homeassistant": "Home Assistant",
                     "dingtalk": "DingTalk", "wecom": "WeCom", "bluebubbles": "BlueBubbles", "qqbot": "QQ Bot"]
        if let name = known[id.lowercased()] { return name }
        return id.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func stateWords(_ state: String) -> String {
        switch state.lowercased() {
        case "connected", "running", "ready", "ok": return "Connected"
        case "connecting", "starting", "retrying", "reconnecting": return "Connecting…"
        case "disconnected", "stopped", "disabled": return "Disconnected"
        case "error", "fatal", "failed", "crashed": return "Error"
        case "", "unknown": return "—"
        default: return state.prefix(1).uppercased() + state.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
    }
}

// MARK: - Update check

/// `GET /api/hermes/update/check`.
nonisolated struct HermesUpdateCheck: Sendable, Equatable {
    /// Commits behind: 0 up to date, -1 behind by an unknown count, nil when the check could not run.
    var behind: Int?
    var updateAvailable: Bool
    /// Only an in-place (git) install can be updated from here; otherwise `message` says what to do.
    var canApply: Bool
    var message: String?
    var currentVersion: String?
    var command: String?
    // [update-flow] Additive keys (older gateways leave them out): how Hermes was installed ("git", "docker", "apt",
    // "nix", "desktop-app", "managed-runtime" …), the release it would move to, its commits, and whether this build is
    // held on or moving back to a release.
    var installMethod: String?
    var channel: String?
    var sourceVersion: String?
    var held: String?
    var rollbackTo: String?
    var commits: [HermesUpdateCommit] = []

    init(json: JSONValue) {
        behind = json["behind"]?.int
        updateAvailable = json["update_available"]?.bool ?? ((behind ?? 0) != 0)
        canApply = json["can_apply"]?.bool ?? false
        message = json["message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        currentVersion = json["current_version"]?.pgString.flatMap { $0.isEmpty ? nil : $0 }
        command = json["update_command"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        installMethod = json["install_method"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        channel = json["channel"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        sourceVersion = json["source_version"]?.pgString.flatMap { $0.isEmpty ? nil : $0 }
        held = (json["held"]?.string ?? json["held"]?.bool.map { $0 ? "held" : "" }).flatMap { $0.isEmpty ? nil : $0 }
        rollbackTo = json["rollback_to"]?.pgString.flatMap { $0.isEmpty ? nil : $0 }
        commits = (json["commits"]?.array ?? []).compactMap(HermesUpdateCommit.init(json:))
    }

    /// The row's value: "Up to Date", "3 Updates Available", "Update Available", "Couldn’t Check".
    var words: String {
        guard let behind else { return updateAvailable ? "Update Available" : "Couldn’t Check" }
        if behind == 0, !updateAvailable { return "Up to Date" }
        if behind > 0 { return behind == 1 ? "1 Update Available" : "\(behind) Updates Available" }
        return "Update Available"
    }

    var canUpdateNow: Bool { canApply && updateAvailable }

    /// The gateway answered but its check didn't run (no `behind`, nothing available): the row reads "Couldn’t Check"
    /// and offers Check Again, the same as when no answer came at all.
    var couldNotCheck: Bool { behind == nil && !updateAvailable }
}

// MARK: - Logs

nonisolated enum LogLevelFilter: String, CaseIterable, Sendable, Identifiable {
    case all, errors, warnings
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "All"; case .errors: "Errors"; case .warnings: "Warnings" }
    }
    /// `level=` on `GET /api/logs` (a minimum: WARNING also lists errors); left out for All.
    var query: String? {
        switch self { case .all: nil; case .errors: "ERROR"; case .warnings: "WARNING" }
    }
}

nonisolated enum LogLines {
    enum Level: Sendable { case error, warning }

    /// `{"file","lines":[…]}`: each line without its line ending; anything that is not text is skipped.
    static func parse(_ json: JSONValue) -> [String] {
        (json["lines"]?.array ?? []).compactMap { value in
            guard let text = value.string else { return nil }
            var line = Substring(text)
            while let last = line.last, last.isNewline { line = line.dropLast() }
            return String(line)
        }
    }

    /// The level stamped on a line ("2026-10-13 09:15:02,123 ERROR gateway.run: …"), read from its first 60 characters.
    static func level(of line: String) -> Level? {
        let head = line.prefix(60)
        for word in head.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).prefix(4) {
            switch word {
            case "ERROR", "CRITICAL", "[ERROR]", "[CRITICAL]": return .error
            case "WARNING", "WARN", "[WARNING]", "[WARN]": return .warning
            default: continue
            }
        }
        return nil
    }
}

// MARK: - Usage

/// `GET /api/analytics/usage?days=N`.
nonisolated struct UsageReport: Sendable, Equatable {
    struct Day: Sendable, Equatable, Identifiable {
        var id: String          // "2026-10-13"
        var date: Date
        var input: Int
        var output: Int
        var sessions: Int
        var tokens: Int { input + output }
    }
    struct Model: Sendable, Equatable, Identifiable {
        var id: String
        var tokens: Int
        var sessions: Int?
        var cost: Double?
    }
    struct Skill: Sendable, Equatable, Identifiable {
        var id: String
        var count: Int
    }

    var periodDays: Int
    var tokens: Int?
    var sessions: Int?
    var cost: Double?
    var daily: [Day]
    var models: [Model]
    var skills: [Skill]

    init(json: JSONValue, asked: Int) {
        periodDays = json["period_days"]?.int ?? asked
        let totals = json["totals"]
        let input = totals?["total_input"]?.int, output = totals?["total_output"]?.int
        tokens = input == nil && output == nil ? nil : (input ?? 0) + (output ?? 0)
        sessions = totals?["total_sessions"]?.int
        cost = totals?["total_estimated_cost"]?.double.flatMap { $0.isFinite ? $0 : nil }

        var days = Set<String>()
        daily = (json["daily"]?.array ?? []).compactMap { row -> Day? in
            guard let day = row["day"]?.string, let date = Self.date(day), days.insert(day).inserted else { return nil }
            return Day(id: day, date: date, input: max(0, row["input_tokens"]?.int ?? 0), output: max(0, row["output_tokens"]?.int ?? 0),
                       sessions: max(0, row["sessions"]?.int ?? 0))
        }
        .sorted { $0.date < $1.date }

        var names = Set<String>()
        models = (json["by_model"]?.array ?? []).compactMap { row -> Model? in
            guard let name = row["model"]?.string, !name.isEmpty, names.insert(name).inserted else { return nil }
            return Model(id: name, tokens: max(0, (row["input_tokens"]?.int ?? 0) + (row["output_tokens"]?.int ?? 0)),
                         sessions: row["sessions"]?.int, cost: row["estimated_cost"]?.double)
        }

        var skillNames = Set<String>()
        skills = (json["skills"]?["top_skills"]?.array ?? []).compactMap { row -> Skill? in
            guard let name = row["skill"]?.string, !name.isEmpty, skillNames.insert(name).inserted else { return nil }
            let count = row["total_count"]?.int ?? ((row["view_count"]?.int ?? 0) + (row["manage_count"]?.int ?? 0))
            return Skill(id: name, count: max(0, count))
        }
    }

    /// Nobody used this gateway in the period: "No Usage Yet".
    var isEmpty: Bool { daily.allSatisfy { $0.tokens == 0 && $0.sessions == 0 } && models.isEmpty && (sessions ?? 0) == 0 && (tokens ?? 0) == 0 }

    /// VoiceOver's summary of the chart: "Daily tokens, 30 days. Most on October 3: 1.2M."
    func chartSummary(calendar: Calendar = .current) -> String {
        let head = "Daily tokens, \(daily.count) \(daily.count == 1 ? "day" : "days")"
        guard let peak = daily.max(by: { $0.tokens < $1.tokens }), peak.tokens > 0 else { return head }
        let format = Date.FormatStyle(date: .long, time: .omitted, calendar: calendar).month(.wide).day().year(.omitted)
        return "\(head). Most on \(peak.date.formatted(format)): \(UsageFormat.compact(peak.tokens))."
    }

    static func date(_ day: String) -> Date? {
        let parts = day.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

nonisolated enum UsageFormat {
    /// 950 → "950", 12,340 → "12.3K", 1,234,567 → "1.2M", 2,500,000,000 → "2.5B".
    static func compact(_ value: Int) -> String {
        let n = Double(abs(value)), sign = value < 0 ? "-" : ""
        func scaled(_ divisor: Double, _ unit: String) -> String {
            let v = n / divisor
            let text = v >= 99.95 ? String(format: "%.0f", v) : String(format: "%.1f", v)
            return sign + (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if n < 1000 { return sign + String(Int(n)) }
        if n < 999_950 { return scaled(1000, "K") }
        if n < 999_950_000 { return scaled(1_000_000, "M") }
        return scaled(1_000_000_000, "B")
    }

    static func compact(_ value: Int?) -> String { value.map { compact($0) } ?? "—" }

    /// 12.3456 → "$12.35", 0.004 → "<$0.01", 0 → "$0.00", nil → "—".
    static func cost(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value > 0, value < 0.01 { return "<$0.01" }
        if value >= 1000 { return "$" + compact(Int(value.rounded())) }
        return String(format: "$%.2f", value)
    }

    static func sessions(_ count: Int?) -> String {
        guard let count else { return "—" }
        return count == 1 ? "1 session" : "\(count.formatted(.number.grouping(.automatic))) sessions"
    }

    static func actions(_ count: Int) -> String { count == 1 ? "1 action" : "\(count) actions" }
}

// MARK: - API

nonisolated struct CommandCenterAPI: Sendable {
    let client: any GatewayClient
    var actions: GatewayActionsAPI { GatewayActionsAPI(client: client) }

    func status() async throws -> GatewayStatusReport {
        let report = GatewayStatusReport(json: try await PagesREST.json(client, "GET", "/api/status", timeout: 20))
        AppLog.trace("pages", "status & maintenance: status \(report.versionWords), gateway \(report.gatewayWords), \(report.platforms.count) platforms, \(report.platforms.filter(\.isDown).count) down")
        return report
    }

    /// `GET /api/logs?file=agent&lines=200[&level=ERROR|WARNING]`.
    static func logsQuery(level: LogLevelFilter, lines: Int = 200) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "file", value: "agent"), URLQueryItem(name: "lines", value: String(lines))]
        if let level = level.query { query.append(URLQueryItem(name: "level", value: level)) }
        return query
    }

    @concurrent
    func logs(level: LogLevelFilter, lines: Int = 200) async throws -> [String] {
        let out = LogLines.parse(try await PagesREST.json(client, "GET", "/api/logs", query: Self.logsQuery(level: level, lines: lines), timeout: 30))
        AppLog.trace("pages", "status & maintenance: logs (\(level.rawValue)): \(out.count) lines")
        return out
    }

    @concurrent
    func usage(days: Int) async throws -> UsageReport {
        let answer = try await PagesREST.json(client, "GET", "/api/analytics/usage", query: [URLQueryItem(name: "days", value: String(days))],
                                              timeout: 30)
        guard answer.object != nil else { throw PagesREST.unreadable(answer) }
        let report = UsageReport(json: answer, asked: days)
        AppLog.trace("pages", "usage page (\(days)d): \(report.daily.count) days, \(report.models.count) models, empty \(report.isEmpty)")
        return report
    }

    func updateCheck(force: Bool = false) async throws -> HermesUpdateCheck {
        let check = HermesUpdateCheck(json: try await PagesREST.json(client, "GET", "/api/hermes/update/check",
                                                         query: force ? [URLQueryItem(name: "force", value: "true")] : [], timeout: 45))
        AppLog.trace("config", "hermes update check (force \(force)): \(check.words), can apply \(check.canApply)")
        return check
    }
}

// MARK: - Maintenance

/// Status & Maintenance's Maintenance section (`V/app/command-center/maintenance.tsx`). Each POST answers an action record whose
/// output is read from the action status. Kept: the three that only read or add a file on the gateway computer.
nonisolated enum MaintenanceAction: String, CaseIterable, Sendable, Identifiable {
    case doctor, securityAudit, backup
    var id: String { rawValue }

    var title: String {
        switch self { case .doctor: "Run Doctor"; case .securityAudit: "Security Audit"; case .backup: "Create Backup" }
    }
    var detail: String {
        switch self {
        case .doctor: "Health-check the install, config, and providers"
        case .securityAudit: "Scan config and skills for risky settings"
        case .backup: "Zip config, memories, skills, and sessions on \(HostWord.phrase)"
        }
    }
    var outputTitle: String {
        switch self { case .doctor: "Doctor"; case .securityAudit: "Security Audit"; case .backup: "Backup" }
    }
    var path: String {
        switch self { case .doctor: "/api/ops/doctor"; case .securityAudit: "/api/ops/security-audit"; case .backup: "/api/ops/backup" }
    }
    /// The action's name when the answer names none (`_ACTION_LOG_FILES`).
    var actionName: String {
        switch self { case .doctor: "doctor"; case .securityAudit: "security-audit"; case .backup: "backup" }
    }
    /// The doctor and the backup take a JSON body (`{}`: every default); the audit takes none.
    var body: JSONValue? {
        switch self { case .doctor, .backup: .object([:]); case .securityAudit: nil }
    }

    func start(_ api: GatewayActionsAPI) async throws -> String {
        try await api.start(path, query: [], fallback: actionName, body: body)
    }
}

/// What a row or an output page says for an action's phase.
nonisolated struct ActionWords: Sendable, Equatable {
    var text: String
    var isError = false
    var isBusy = false

    @MainActor static func update(_ phase: GatewayActionRun.Phase) -> ActionWords? {
        switch phase {
        case .idle: return nil
        case .running: return ActionWords(text: "Updating…", isBusy: true)
        case .stalled: return ActionWords(text: "Still updating. This page updates when your gateway is back.", isBusy: true)
        case .untracked: return ActionWords(text: "Update started. This Hermes doesn’t report an update’s progress, so it can’t be followed here.")
        case .finished(true, _): return ActionWords(text: "Hermes Updated")
        case .finished(false, _): return ActionWords(text: "The update didn’t finish.", isError: true)
        case .failed(let reason): return ActionWords(text: reason, isError: true)
        }
    }

    @MainActor static func maintenance(_ phase: GatewayActionRun.Phase) -> ActionWords? {
        switch phase {
        case .idle: return nil
        case .running: return ActionWords(text: "Running…", isBusy: true)
        case .stalled: return ActionWords(text: "Still running. This page updates when your gateway answers.", isBusy: true)
        case .untracked: return ActionWords(text: "Started. This Hermes doesn’t report its progress, so it can’t be followed here.")
        case .finished(true, _): return ActionWords(text: "Finished")
        case .finished(false, _): return ActionWords(text: "Finished with Problems", isError: true)
        case .failed(let reason): return ActionWords(text: reason, isError: true)
        }
    }

    /// The last `count` lines that say something (a failure's "last lines").
    static func tail(_ lines: [String], _ count: Int = 4) -> [String] {
        Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("===") }.suffix(count))
    }
}
