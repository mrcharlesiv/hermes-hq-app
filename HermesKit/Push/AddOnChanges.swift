// [addon-whats-new] Tester 2026-11-05: "Plugin updates — it'd be nice to see what it's updating/installing." The update
// sheet asked "Update the Add-on?" without saying which add-on, from which version to which, or what the new one does.
// The add-ons' own history says it: every release commit in mrcharlesiv/hermes-hq-plugins starts
// "<plugin> <version>: <what it does>" ("hermes-hq-push 0.9.39: Task ideas"). This reads those subjects into one line per
// version newer than the one Hermes has. Pure (the fetch is in AddOnUpdate), so it is unit-tested.

import Foundation

nonisolated enum AddOnChanges {
    struct Change: Equatable, Sendable {
        var version: String
        /// What the version does, in its commit's words, first letter capitalised, up to the first ";".
        var line: String
    }

    /// GitHub's commit list for one add-on's folder, newest first (no sign-in: 60 reads an hour per address is plenty
    /// for a sheet opened by hand).
    static func url(plugin: String, repo: String = "mrcharlesiv/hermes-hq-plugins") -> URL? {
        URL(string: "https://api.github.com/repos/\(repo)/commits?path=\(plugin)&per_page=60")
    }

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
        let prefix = plugin + " "
        var order: [String] = []
        var lines: [String: String] = [:]
        for subject in subjects where subject.hasPrefix(prefix) {
            let rest = subject.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let version = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
            guard version.first?.isNumber == true, PushPolicy.versionAtLeast(version, "0") else { continue }
            if let after, PushPolicy.versionAtLeast(after, version) { continue }   // Hermes has it already
            let words = tidy(String(rest[rest.index(after: colon)...]))
            guard !words.isEmpty else { continue }
            if lines[version] == nil { order.append(version) }
            lines[version] = words   // older commits come later: the release's own words win
        }
        let newestFirst = order.sorted { PushPolicy.versionAtLeast($0, $1) && $0 != $1 }
        return newestFirst.prefix(limit).map { Change(version: $0, line: lines[$0] ?? "") }
    }

    /// The newest version the list names (the one an update gets), or nil.
    static func newest(_ changes: [Change]) -> String? { changes.first?.version }

    /// A bracketed aside with a code name in it: a snake_case word, a dotted name or anything in backticks.
    private static let codeAside = try! NSRegularExpression(
        pattern: #"\s*\([^()]*(?:\b[A-Za-z0-9]+_\w+|\b[a-z]\w+\.[a-z]\w+\b|`[^`]*`)[^()]*\)"#)

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
            .trimmingCharacters(in: .whitespaces)   // an aside that opened the line left its space behind
        if words.count > 120 { words = String(words.prefix(119)).trimmingCharacters(in: .whitespaces) + "…" }
        guard let first = words.first else { return "" }
        return first.uppercased() + words.dropFirst()
    }
}
