// [addon-whats-new] Tester 2026-11-05: "Plugin updates — it'd be nice to see what it's updating/installing." The update
// sheet asked "Update the Add-on?" without saying which add-on, from which version to which, or what the new one does.
// The add-ons' own history says it: release commits in mrcharlesiv/hermes-hq-plugins name the plugin and version
// ("hermes-hq-push 0.9.39: Task ideas", "Proactivity 0.4.0-beta.2: …", or joint releases separated by "&"). This reads
// those subjects into one line per version newer than the one Hermes has, merges them with curated built-in release
// notes so offline/rate-limited or non-standard commits never leave an HQ plugin update unexplained, and formats clear
// fallback copy when no per-version lines apply. Pure (the fetch is in AddOnUpdate), so it is unit-tested.

import Foundation

nonisolated enum AddOnChanges {
    struct Change: Equatable, Sendable {
        var version: String
        /// What the version does, in its commit's words, first letter capitalised, up to the first ";".
        var line: String
    }

    /// Any first-party Hermes HQ plugin published in `mrcharlesiv/hermes-hq-plugins` (including future `hermes-hq-*`
    /// plugins).
    static func isHQPlugin(_ plugin: String) -> Bool {
        plugin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("hermes-hq-")
    }

    /// Friendly display name shown in update sheets and reminders.
    static func displayTitle(for plugin: String) -> String {
        switch plugin {
        case PushPolicy.pluginName: "Hermes HQ Add-on"
        case "hermes-hq-browser": "Browser Add-on"
        case ProactivityBeta.pluginName: ProactivityBeta.pageLabel
        default: DisplayName.title(plugin)
        }
    }

    /// Commit subject prefixes used in `mrcharlesiv/hermes-hq-plugins` for each plugin.
    static func commitAliases(for plugin: String) -> [String] {
        switch plugin {
        case ProactivityBeta.pluginName: [plugin, "Proactivity"]
        default: [plugin]
        }
    }

    /// Minimum known target version for built-in HQ plugins when live GitHub notes are unavailable.
    static func defaultTargetVersion(for plugin: String) -> String? {
        switch plugin {
        case PushPolicy.pluginName: PushPolicy.wantedVersion
        case "hermes-hq-browser": BrowserAddOn.wantedVersion
        case ProactivityBeta.pluginName: builtInNotes[plugin]?.first?.version
        default: nil
        }
    }

    /// GitHub's commit list for one add-on's folder, newest first (no sign-in: 60 reads an hour per address is plenty
    /// for a sheet opened by hand).
    static func url(plugin: String, repo: String = "mrcharlesiv/hermes-hq-plugins") -> URL? {
        URL(string: "https://api.github.com/repos/\(repo)/commits?path=\(plugin)&per_page=60")
    }

    // MARK: - Version parsing & semver comparison (including pre-releases like 0.4.0-beta.2)

    private struct ParsedVersion: Equatable {
        var core: [Int]
        var preRelease: [String]
    }

    private static func parseVersion(_ raw: String) -> ParsedVersion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        let coreText: String
        let preRelease: [String]
        if let dash = text.firstIndex(of: "-") {
            coreText = String(text[..<dash])
            let pre = String(text[text.index(after: dash)...])
            guard !pre.isEmpty else { return nil }
            preRelease = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if preRelease.contains(where: \.isEmpty) { return nil }
        } else {
            coreText = text
            preRelease = []
        }
        let pieces = coreText.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !pieces.isEmpty, !pieces.contains(nil) else { return nil }
        return ParsedVersion(core: pieces.compactMap { $0 }, preRelease: preRelease)
    }

    /// True for standard (`0.9.91`, `3.13.1`) and pre-release (`0.4.0-beta.2`) version strings.
    static func isValidVersion(_ raw: String) -> Bool { parseVersion(raw) != nil }

    /// True when `raw` looks like a Git commit SHA (7–40 hex characters, no dot) rather than a version number.
    static func isCommitSHA(_ raw: String?) -> Bool {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 7, text.count <= 40, !text.contains(".") else { return false }
        return text.allSatisfy(\.isHexDigit)
    }

    /// Semver comparison supporting pre-release tags (`0.4.0` > `0.4.0-beta.2` > `0.4.0-beta.1` > `0.3.0-beta.3`).
    /// Returns `< 0` if `lhs < rhs`, `0` if equal, `> 0` if `lhs > rhs`, or `nil` if either isn't a valid version.
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
        guard let a = parseVersion(lhs), let b = parseVersion(rhs) else { return nil }
        let count = max(a.core.count, b.core.count)
        for index in 0..<count {
            let av = index < a.core.count ? a.core[index] : 0
            let bv = index < b.core.count ? b.core[index] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        if a.preRelease.isEmpty && b.preRelease.isEmpty { return 0 }
        if a.preRelease.isEmpty { return 1 }   // stable > pre-release of same core
        if b.preRelease.isEmpty { return -1 }
        let preCount = max(a.preRelease.count, b.preRelease.count)
        for index in 0..<preCount {
            if index >= a.preRelease.count { return -1 }
            if index >= b.preRelease.count { return 1 }
            let ap = a.preRelease[index], bp = b.preRelease[index]
            if ap == bp { continue }
            if let ai = Int(ap), let bi = Int(bp) { return ai < bi ? -1 : 1 }
            if Int(ap) != nil { return -1 }   // numeric identifier has lower precedence than non-numeric
            if Int(bp) != nil { return 1 }
            return ap.localizedStandardCompare(bp) == .orderedAscending ? -1 : 1
        }
        return 0
    }

    /// Semver `version >= minimum` (supports pre-release tags like `0.4.0-beta.2`).
    static func versionAtLeast(_ version: String, _ minimum: String) -> Bool {
        (compareVersions(version, minimum) ?? -1) >= 0
    }

    // MARK: - Parsing release commits

    /// The versions newer than `after` (the newest `limit`: three keep the sheet's steps in view), newest first, one line each.
    /// A version with several commits takes its first (oldest) one, which names the release; follow-ups fix tests or
    /// words. `data`: GitHub's JSON array of commits.
    static func parse(_ data: Data, plugin: String, after: String?, limit: Int = 3) -> [Change] {
        guard let commits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let subjects = commits.compactMap { ($0["commit"] as? [String: Any])?["message"] as? String }
            .map { $0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }
        return changes(subjects: subjects, plugin: plugin, after: after, limit: limit)
    }

    /// The same over commit subjects, newest first.
    static func changes(subjects: [String], plugin: String, after: String?, limit: Int = 3) -> [Change] {
        var order: [String] = []
        var lines: [String: String] = [:]
        for subject in subjects {
            guard let colon = subject.firstIndex(of: ":") else { continue }
            let header = String(subject[..<colon])
            guard let version = extractVersion(from: header, plugin: plugin) else { continue }
            if let after, versionAtLeast(after, version) { continue }   // Hermes has it already
            let words = tidy(String(subject[subject.index(after: colon)...]))
            guard !words.isEmpty else { continue }
            if lines[version] == nil { order.append(version) }
            lines[version] = words   // older commits come later: the release's own words win
        }
        let newestFirst = order.sorted(by: Self.isNewer)
        return newestFirst.prefix(limit).map { Change(version: $0, line: lines[$0] ?? "") }
    }

    /// Strict weak ordering, newest version first: compares semver components including pre-release tags
    /// (missing trailing numeric parts count as 0) and breaks equivalent ties (e.g. "1.0" vs "1.0.0")
    /// deterministically by raw string order.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        if let cmp = compareVersions(lhs, rhs), cmp != 0 { return cmp > 0 }
        return lhs > rhs
    }

    /// Extracts `<version>` for `plugin` from a commit header before `:`.
    /// Supports single headers (`hermes-hq-push 0.9.91`), aliases (`Proactivity 0.4.0-beta.2`),
    /// and compound headers (`hermes-hq-push 0.9.89 & hermes-hq-browser 3.13.1`).
    private static func extractVersion(from header: String, plugin: String) -> String? {
        let aliases = commitAliases(for: plugin)
        let parts = header.split(whereSeparator: { $0 == "&" || $0 == "+" })
        for rawPart in parts {
            let segment = rawPart.trimmingCharacters(in: .whitespaces)
            for alias in aliases {
                let prefix = alias + " "
                guard segment.count > prefix.count,
                      segment.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else { continue }
                var candidate = String(segment.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix("v") || candidate.hasPrefix("V") { candidate.removeFirst() }
                guard candidate.first?.isNumber == true, isValidVersion(candidate) else { continue }
                return candidate
            }
        }
        return nil
    }

    /// Merges live GitHub release lines with curated built-in notes so future releases appear automatically while
    /// offline, rate-limited, or unusually formatted commits still explain what changed.
    static func merge(live: [Change], plugin: String, after: String?, limit: Int = 25) -> [Change] {
        var byVersion: [String: String] = [:]
        // Live commits first (captures every future version published after this build).
        for change in live where isValidVersion(change.version) {
            if let after, versionAtLeast(after, change.version) { continue }
            if !change.line.isEmpty { byVersion[change.version] = change.line }
        }
        // Curated built-in notes fill any offline/rate-limited gaps and replace internal/unparsed release notes.
        for change in builtInChanges(plugin: plugin, after: after, limit: limit) {
            byVersion[change.version] = change.line
        }
        let sorted = byVersion.keys.sorted(by: Self.isNewer)
        return sorted.prefix(limit).map { Change(version: $0, line: byVersion[$0] ?? "") }
    }

    /// Curated built-in release notes newer than `after`, newest first.
    static func builtInChanges(plugin: String, after: String?, limit: Int = 25) -> [Change] {
        guard let all = builtInNotes[plugin] else { return [] }
        let filtered = all.filter { change in
            guard let after, isValidVersion(after) else { return true }
            return !versionAtLeast(after, change.version)
        }
        return Array(filtered.prefix(limit))
    }

    /// The newest version the list names (the one an update gets), or nil.
    static func newest(_ changes: [Change]) -> String? { changes.first?.version }

    /// Best human-readable target version for an update card: prefers a real version from `changes` over a raw Git SHA
    /// or older minimum target, and falls back to `fallbackTo` or the plugin's known required version.
    static func bestTargetVersion(liveNewest: String?, fallbackTo: String?, plugin: String) -> String? {
        let trimmedFallback = fallbackTo?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let knownDefault = defaultTargetVersion(for: plugin)
        let baseline: String?
        if let trimmedFallback, !isCommitSHA(trimmedFallback) {
            baseline = trimmedFallback
        } else {
            baseline = knownDefault ?? trimmedFallback
        }
        guard let live = liveNewest?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return baseline }
        guard let baseline, !isCommitSHA(baseline) else { return live }
        if let cmp = compareVersions(live, baseline) { return cmp >= 0 ? live : baseline }
        return live
    }

    /// Guaranteed plain-English explanation when an update card has no per-version lines (e.g. a brand-new unlisted
    /// build, a reinstall on bots that didn't have it yet, or an offline check past known versions).
    static func fallbackSummary(plugin: String, from: String?, to: String?, setUp: Bool, botsNote: String? = nil, description: String? = nil) -> String {
        let title = displayTitle(for: plugin)
        if setUp {
            switch plugin {
            case PushPolicy.pluginName:
                return "Installs the Hermes HQ Add-on for lock-screen alerts, question and draft cards, shared tasks, goals, and live activity updates."
            case "hermes-hq-browser":
                return "Installs the Browser Add-on so you can watch a bot’s browser live and take over when it needs you."
            case ProactivityBeta.pluginName:
                return "Installs Proactivity (Beta) for open-loop tracking, quiet background checks, and daily briefs (starts off until enabled)."
            default:
                if let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                    return desc
                }
                return "Installs \(title) on Hermes."
            }
        }
        if let from, let to, !from.isEmpty, from == to {
            if let botsNote, !botsNote.isEmpty {
                return "Brings the remaining bots onto version \(to) so every bot has the same features and fixes."
            }
            return "Reinstalls version \(to) with the latest build fixes for \(title)."
        }
        switch plugin {
        case PushPolicy.pluginName:
            return "Upgrades the Hermes HQ Add-on with the latest fixes and features for notifications, interactive cards, tasks, and goals."
        case "hermes-hq-browser":
            return "Upgrades the Browser Add-on with the latest live browser watching, takeover, and Hermes compatibility fixes."
        case ProactivityBeta.pluginName:
            return "Upgrades Proactivity (Beta) with the latest improvements to open-loop tracking, suggestions, and chat hand-offs."
        default:
            if let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                return "Updates \(title) to the newest available version. \(desc)"
            }
            return "Updates \(title) with the latest fixes and improvements."
        }
    }

    // MARK: - Cleaning commit lines

    /// A bracketed aside with a code name in it: a snake_case word, a dotted name or anything in backticks.
    private static let codeAside = try! NSRegularExpression(
        pattern: #"\s*\([^()]*(?:\b[A-Za-z0-9]+_\w+|\b[a-z]\w+\.[a-z]\w+\b|`[^`]*`)[^()]*\)"#)

    /// A bracketed internal attribution or issue tag: `(owner 2026-11-23)`, `(issue #11)`, `(hermes-hq-app#413)`.
    private static let metaAside = try! NSRegularExpression(
        pattern: #"\s*\((?:owner\b[^()]*|issue\s+#\d+[^()]*|[a-z0-9-]+#\d+[^()]*)\)"#,
        options: [.caseInsensitive])

    /// "after an update the app reads …; the add-on says …" → "After an update the app reads …".
    static func tidy(_ text: String) -> String {
        var words = text.trimmingCharacters(in: .whitespaces)
        if let semicolon = words.firstIndex(of: ";") { words = String(words[..<semicolon]).trimmingCharacters(in: .whitespaces) }
        // Cut inside brackets ("turned off entirely (tools hidden; …"): the aside goes, not left open.
        if words.filter({ $0 == "(" }).count > words.filter({ $0 == ")" }).count, let open = words.lastIndex(of: "(") {
            words = String(words[..<open]).trimmingCharacters(in: .whitespaces)
        }
        // Mac polish #145: an aside naming code ("(browser_exec only)", a tool's or a module's name) means nothing to
        // the person updating: it goes, the sentence around it stays.
        words = codeAside.stringByReplacingMatches(in: words, range: NSRange(words.startIndex..., in: words), withTemplate: "")
        words = metaAside.stringByReplacingMatches(in: words, range: NSRange(words.startIndex..., in: words), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)   // an aside that opened the line left its space behind
        if words.count > 120 { words = String(words.prefix(119)).trimmingCharacters(in: .whitespaces) + "…" }
        guard let first = words.first else { return "" }
        return first.uppercased() + words.dropFirst()
    }

    // MARK: - Curated built-in release notes (newest first per HQ plugin)

    private static let builtInNotes: [String: [Change]] = [
        PushPolicy.pluginName: [
            Change(version: "0.9.91", line: "Shows context before clarify question cards and replies in chat when asked to explain"),
            Change(version: "0.9.90", line: "Lets other add-ons send suggestions directly to Tasks › Ideas"),
            Change(version: "0.9.89", line: "Fixes vault login autofill on Hermes 0.23.4 and alerts when a bot asks for your browser"),
            Change(version: "0.9.88", line: "Adds Tasks › Ideas source toggles and multi-bot sweeps"),
            Change(version: "0.9.87", line: "Bots show flights, hotels, and products as interactive cards instead of plain tables"),
            Change(version: "0.9.86", line: "Adds travel cards, Cc and Bcc on email drafts, product links on orders, and connector ask-before-running rules"),
            Change(version: "0.9.85", line: "Goal tasks carry attached files, links, and notes through when accepted"),
            Change(version: "0.9.82", line: "Bots ask once before buying and tasks note when awaited items arrive"),
            Change(version: "0.9.81", line: "1Password logins only fill on the exact site requested"),
            Change(version: "0.9.80", line: "Restores pull request status badges on Hermes 0.23.3+"),
            Change(version: "0.9.79", line: "Matches pull request badges to the right public PR after notes-only merges"),
            Change(version: "0.9.76", line: "Shows public pull request numbers for merged work"),
            Change(version: "0.9.75", line: "Tracks every pull request and branch per chat"),
            Change(version: "0.9.74", line: "Suggests titles for new tasks without renaming existing ones, and adds Goals"),
            Change(version: "0.9.73", line: "Keeps empty branches from showing as open pull request work"),
            Change(version: "0.9.71", line: "Speeds up pull request status checks for coding projects"),
            Change(version: "0.9.70", line: "Marks merged and closed branches immediately and links projects to repositories"),
            Change(version: "0.9.68", line: "Shows each chat’s branch status (open, merged locally, or merged publicly)"),
            Change(version: "0.9.67", line: "Tracks what became of pull requests opened from a chat"),
            Change(version: "0.9.65", line: "Silences alerts for the chat you already have open on screen"),
            Change(version: "0.9.64", line: "Shows images a bot made before asking about them, plus ask-to-act cards"),
            Change(version: "0.9.62", line: "Delivers login and one-time code requests from sign-in frames inside a page"),
            Change(version: "0.9.61", line: "Adds the Soft look for dashboard tiles"),
            Change(version: "0.9.60", line: "Adds shopping product and order cards with payment approval safeguards"),
            Change(version: "0.9.59", line: "Lets bots check for emailed/texted codes first and request a single 1Password login on approval"),
            Change(version: "0.9.58", line: "Applies plugin updates only when packages, findings, and capabilities match what you approved"),
            Change(version: "0.9.57", line: "Shows approval and question cards when a bot handles a scheduled job report"),
            Change(version: "0.9.54", line: "Opens the parent chat when tapping a helper agent’s approval alert"),
            Change(version: "0.9.53", line: "Adds task priority, tags, reminders, start dates, repeat schedules, and files"),
            Change(version: "0.9.52", line: "Lets you approve and install plugin updates that add Python packages from the app"),
            Change(version: "0.9.50", line: "Improves dashboard tile layout so status boards fit cleanly at every size"),
            Change(version: "0.9.47", line: "Adds draft message cards so you can review, edit, or send before a bot messages anyone"),
            Change(version: "0.9.45", line: "Fixes daily Task Ideas runs saving suggestions on newer Hermes gateways"),
            Change(version: "0.9.44", line: "Matches login and code prompts to the exact site tab the bot asked for"),
            Change(version: "0.9.42", line: "Keeps scheduled job images when a bot summarizes them in its chat"),
            Change(version: "0.9.40", line: "Refreshes the task list after updates and reports the add-on’s version"),
            Change(version: "0.9.39", line: "Adds Task Ideas suggestions"),
            Change(version: "0.9.38", line: "Adds a dedicated Task Page for every task"),
            Change(version: "0.9.37", line: "Adds per-task chats, watches, and pre-due checks"),
            Change(version: "0.9.36", line: "Adds custom task sections and lets you turn Tasks off completely"),
            Change(version: "0.9.32", line: "Adds shared Tasks between you and your bots"),
        ],
        "hermes-hq-browser": [
            Change(version: "3.13.1", line: "Alerts when a bot asks for your browser and improves manual checkout fallback"),
            Change(version: "3.13.0", line: "Adds opt-in on-demand Chrome so browsers start only when needed"),
            Change(version: "3.12.0", line: "Sends every pointer drag sample in order for smoother dragging"),
            Change(version: "3.11.0", line: "Reports whether Hermes is hosted for Browser Use Cloud setup"),
            Change(version: "3.10.0", line: "Adds Use for All Bots for Browser Use Cloud"),
            Change(version: "3.9.0", line: "Adds Browser Use Cloud support so bots can browse in the cloud"),
            Change(version: "3.8.1", line: "Shows the active site the bot is viewing in the chat’s browsing chip"),
            Change(version: "3.8.0", line: "Adds compatibility with Hermes 0.22.6 and newer while supporting older gateways"),
            Change(version: "3.7.0", line: "Forwards browser alerts, prompts, and sign-in account choosers to your device"),
        ],
        ProactivityBeta.pluginName: [
            Change(version: "0.4.0-beta.2", line: "Cleans up chat hand-off messages so dates are only stated once"),
            Change(version: "0.4.0-beta.1", line: "Posts proactive findings and morning briefs directly in the bot’s chat"),
            Change(version: "0.3.0-beta.3", line: "Automatically removes a suggestion when its open item is closed"),
            Change(version: "0.3.0-beta.2", line: "Polishes the Proactivity page layout and spacing"),
            Change(version: "0.3.0-beta.1", line: "Adds Tasks › Ideas integration and stability fixes for background checks"),
            Change(version: "0.2.0-beta.2", line: "Filters scheduled job sessions out of chat scans for cleaner tracking"),
            Change(version: "0.2.0-beta.1", line: "Adds the /proactivity command and read-only recent chat scanning"),
            Change(version: "0.1.0-beta.1", line: "Introduces opt-in Proactivity (Beta) with open-loop tracking, daily briefs, and its own page"),
        ],
    ]
}

private extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
