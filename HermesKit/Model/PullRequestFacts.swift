// [pr-review-facts] Owner 2026-11-21 (option B of artifacts/coding-pr-review/mock1.html): what a pull request's
// review looks like, as the add-on sends it on `sessions/pr-status` (the wire contract given whole to the app and the
// add-on; its rules are in docs/spec/3x-sessions.md [pr-review-facts]): its size, its checks, its title and the branch
// it merges into, and, for the one chat whose PR card is open (`detail: true`), its files and its check runs.
//
// Every key is optional and an absent key means "not known", never zero: the app draws nothing for it. A wrong type, a
// negative number or an unknown checks state drops that one key, never the answer (`PRFacts`).

import Foundation

/// How big the change is: `{"files": int, "additions": int, "deletions": int}`, each >= 0.
nonisolated struct SessionPRSize: Hashable, Sendable, Codable {
    var files: Int
    var additions: Int
    var deletions: Int

    var diffText: String { "+\(additions) \u{2212}\(deletions)" }
}

/// Numbered unified-diff lines for the interactive PR diff viewer (tap any line to send a targeted comment to the bot).
nonisolated enum PullRequestDiffLines {
    enum Kind: Hashable, Sendable { case hunk, context, added, removed }

    struct Line: Identifiable, Hashable, Sendable {
        var id: Int
        var number: Int?
        var kind: Kind
        var text: String
    }

    /// Parses a unified diff patch into displayable lines with accurate target-file (or removed-line) line numbers.
    static func parse(_ raw: String) -> [Line] {
        let stripped = StepRules.stripHeaders(StepRules.stripChrome(raw))
        var out: [Line] = []
        var nextID = 0
        var oldLine = 1
        var newLine = 1
        var inHunk = false
        let hunkRegex = try? NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)

        for rawLine in stripped {
            let s = String(rawLine)
            if s.hasPrefix("@@") {
                if let hunkRegex,
                   let match = hunkRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let r1 = Range(match.range(at: 1), in: s), let r2 = Range(match.range(at: 2), in: s),
                   let o = Int(s[r1]), let n = Int(s[r2]) {
                    oldLine = o
                    newLine = n
                    inHunk = true
                    out.append(Line(id: nextID, number: nil, kind: .hunk, text: s))
                    nextID += 1
                }
                continue
            }
            if s.hasPrefix("\\") { continue }
            if !inHunk {
                // Fallback when a patch has no @@ header.
                let kind: Kind = s.hasPrefix("+") && !s.hasPrefix("+++") ? .added : s.hasPrefix("-") && !s.hasPrefix("---") ? .removed : .context
                out.append(Line(id: nextID, number: nextID + 1, kind: kind, text: s))
                nextID += 1
                continue
            }
            if s.hasPrefix("+") && !s.hasPrefix("+++") {
                out.append(Line(id: nextID, number: newLine, kind: .added, text: s))
                newLine += 1
                nextID += 1
            } else if s.hasPrefix("-") && !s.hasPrefix("---") {
                out.append(Line(id: nextID, number: oldLine, kind: .removed, text: s))
                oldLine += 1
                nextID += 1
            } else {
                out.append(Line(id: nextID, number: newLine, kind: .context, text: s))
                oldLine += 1
                newLine += 1
                nextID += 1
            }
        }
        return out
    }

    /// Formats a targeted line comment to send directly to the chat's bot.
    static func commentMessage(path: String, lineNumber: Int, codeLine: String, note: String) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = codeLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCode.isEmpty {
            return "In `\(path)` line \(lineNumber):\n\n\(trimmedNote)"
        }
        return "In `\(path)` line \(lineNumber) (`\(trimmedCode)`):\n\n\(trimmedNote)"
    }
}

/// The head commit's check runs: how many passed, failed and are still running, and (with `detail: true`) each run.
nonisolated struct SessionPRChecks: Hashable, Sendable {
    enum State: String, Hashable, Sendable, Codable { case passed, failed, running }
    struct Run: Hashable, Sendable {
        var name: String
        var state: State
        /// Optional GitHub link for this check run (when sent by the add-on).
        var url: URL? = nil
        /// Optional short failure/output summary for this check run.
        var summary: String? = nil
    }
    var state: State
    var passed: Int
    var failed: Int
    var running: Int
    /// nil: not asked for (no `detail: true`) or not sent. Failed first, then running, then passed (the add-on's order).
    var runs: [Run]? = nil

    var total: Int { passed + failed + running }
}

/// One changed file (`detail: true` only). `patch`: its unified diff from the first `@@` line on.
nonisolated struct SessionPRFile: Hashable, Sendable {
    var path: String
    var additions: Int
    var deletions: Int
    var binary = false
    var patch: String? = nil
    /// Left out for size: "Too large to show here".
    var patchCut = false
}

/// The contract's tolerant reading of each new key.
nonisolated enum PRFacts {
    static let titleLimit = 200
    static let runLimit = 30
    static let runNameLimit = 120
    static let fileLimit = 50
    static let patchLimit = 20_000

    /// A count: a whole JSON number, 0 or more. A string, a fraction or a negative number is not one.
    static func count(_ value: JSONValue?) -> Int? {
        guard case .number(let n)? = value, n.isFinite, n >= 0, n < 9.0e15, n.rounded(.towardZero) == n else { return nil }
        return Int(n)
    }

    static func size(_ value: JSONValue?) -> SessionPRSize? {
        guard let files = count(value?["files"]), let additions = count(value?["additions"]),
              let deletions = count(value?["deletions"]) else { return nil }
        return SessionPRSize(files: files, additions: additions, deletions: deletions)
    }

    /// `runs`: read `checks.runs` too (a `detail: true` answer). A run that doesn't read is left out, not the list.
    /// No runs at all (passed + failed + running = 0) is not a checks answer: the contract says at least one.
    static func checks(_ value: JSONValue?, runs: Bool) -> SessionPRChecks? {
        guard let state = value?["state"]?.string.flatMap(SessionPRChecks.State.init(rawValue:)),
              let passed = count(value?["passed"]), let failed = count(value?["failed"]),
              let running = count(value?["running"]), passed + failed + running > 0 else { return nil }
        var checks = SessionPRChecks(state: state, passed: passed, failed: failed, running: running)
        if runs, let list = value?["runs"]?.array {
            checks.runs = list.prefix(runLimit).compactMap { run in
                guard let name = run["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                      let state = run["state"]?.string.flatMap(SessionPRChecks.State.init(rawValue:)) else { return nil }
                let url = run["url"]?.string.flatMap(Self.validCheckURL)
                let summary = run["summary"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty.map { String($0.prefix(titleLimit)) }
                return SessionPRChecks.Run(name: String(name.prefix(runNameLimit)), state: state, url: url, summary: summary)
            }
        }
        return checks
    }

    /// Valid HTTPS GitHub link for a check run (never arbitrary schemes or hosts).
    static func validCheckURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "github.com", parts.user == nil, parts.password == nil,
              parts.port == nil, !parts.path.isEmpty else { return nil }
        return parts.url
    }

    /// The pull request's title on GitHub, trimmed, at most 200 characters; empty is none.
    static func title(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(titleLimit))
    }

    /// The branch it merges into; empty is none.
    static func base(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains(where: \.isNewline) else { return nil }
        return text
    }

    /// At most 50 files; a file that doesn't read (no path, a count that isn't one) is left out, not the list.
    static func files(_ value: JSONValue?) -> [SessionPRFile]? {
        guard let rows = value?.array else { return nil }
        return rows.prefix(fileLimit).compactMap { row in
            guard let path = row["path"]?.string, !path.trimmingCharacters(in: .whitespaces).isEmpty,
                  let additions = count(row["additions"]), let deletions = count(row["deletions"]) else { return nil }
            let binary = row["binary"]?.bool == true
            let patch = binary ? nil : row["patch"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(patchLimit)) }
            return SessionPRFile(path: path, additions: additions, deletions: deletions, binary: binary, patch: patch,
                                 patchCut: !binary && patch == nil && row["patch_cut"]?.bool == true)
        }
    }
}

/// [pr-verdict] What a coding row says at its subtitle's trailing end about the lead pull request, draft or open only
/// (owner 2026-11-21, option B): its checks, then its size. nil: nothing (the row is exactly as before).
nonisolated enum PRVerdict: Hashable, Sendable {
    /// Checks passed: a check mark, then the size when known.
    case passed(SessionPRSize?)
    /// Checks failing: a cross and "2 checks failing", in the theme's red.
    case failing(Int)
    /// Checks still running: the Working quarter ring and "checks running".
    case running
    /// No checks known: the size alone.
    case size(SessionPRSize)

    static func of(_ status: SessionPRStatus?) -> PRVerdict? {
        guard let status, [.draft, .open].contains(status.state), !status.manual else { return nil }
        if let checks = status.checks {
            switch checks.state {
            case .failed: return .failing(max(1, checks.failed))
            case .running: return .running
            case .passed: return .passed(status.size)
            }
        }
        return status.size.map { .size($0) }
    }

    /// "+128 −12" (U+2212 for the minus).
    static func sizeWords(_ size: SessionPRSize) -> String { "+\(size.additions) \u{2212}\(size.deletions)" }

    /// The words drawn after the glyph; nil: the glyph alone.
    var words: String? {
        switch self {
        case .passed(let size): return size.map(Self.sizeWords)
        case .failing(let count): return count == 1 ? "1 check failing" : "\(count) checks failing"
        case .running: return "checks running"
        case .size(let size): return Self.sizeWords(size)
        }
    }

    /// What VoiceOver says: "Checks passed, 128 lines added, 12 removed" / "2 checks failing" / "Checks running".
    var spoken: String {
        switch self {
        case .passed(let size): return (["Checks passed"] + (size.map { [Self.spokenSize($0)] } ?? [])).joined(separator: ", ")
        case .failing(let count): return count == 1 ? "1 check failing" : "\(count) checks failing"
        case .running: return "Checks running"
        case .size(let size): return Self.spokenSize(size)
        }
    }

    static func spokenSize(_ size: SessionPRSize) -> String {
        "\(size.additions) \(size.additions == 1 ? "line" : "lines") added, \(size.deletions) removed"
    }
}
