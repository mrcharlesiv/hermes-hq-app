// [pr-card-detail] Owner 2026-11-21 (option B of artifacts/coding-pr-review/mock1.html, the PR card's Checks and
// Changes): what the card's two review sections show, from a `detail: true` answer for that one chat (the lead's
// entry of `items`, or the item the card is on). Each section only with its data; nothing, not an empty section, else.
//
//   Checks    one row: "5 checks passed" / "2 of 5 checks failing" / "3 of 5 checks running"; with runs, a chevron
//             that pushes the runs (name, state mark)
//   Changes   "Changes · 4 files · +128 −12", one row per file (name, folder, "+96 −8"; a patch pushes its diff),
//             "Binary file", "Too large to show here", then "and N more files"
//   Actions   Ask <bot> to Fix Checks… while checks fail

import Foundation

nonisolated extension PullRequestCard {
    /// The Checks section's one row.
    struct ChecksRow: Hashable, Sendable {
        var words: String
        var state: SessionPRChecks.State
        /// nil: no runs to push (not asked, or none sent).
        var runs: [SessionPRChecks.Run]?
    }

    /// One changed file's row.
    struct FileRow: Hashable, Sendable {
        enum Body: Hashable, Sendable {
            case patch(String)
            case binary
            case tooLarge
            case none
        }
        var path: String
        /// The last path component, drawn in monospace.
        var name: String
        /// The folder, as a quiet second line; nil at the repository's top.
        var folder: String?
        /// "+96 −8"; nil for a binary file (its counts are zeros).
        var counts: String?
        var body: Body

        /// What the row says under its name instead of a diff ("Binary file", "Too large to show here").
        var note: String? {
            switch body {
            case .binary: return "Binary file"
            case .tooLarge: return "Too large to show here"
            case .patch, .none: return nil
            }
        }
    }

    /// The Checks row, from the shown item's checks.
    var checksRow: ChecksRow? {
        guard [.draft, .open].contains(shown.state), let checks = shown.checks else { return nil }
        let total = checks.total
        let words: String
        switch checks.state {
        case .passed: words = total == 1 ? "1 check passed" : "\(total) checks passed"
        case .failed: words = "\(max(1, checks.failed)) of \(total) \(total == 1 ? "check" : "checks") failing"
        case .running: words = "\(max(1, checks.running)) of \(total) \(total == 1 ? "check" : "checks") running"
        }
        let runs = checks.runs.flatMap { $0.isEmpty ? nil : $0 }
        return ChecksRow(words: words, state: checks.state, runs: runs)
    }

    /// The Changes section's label: "Changes · 4 files · +128 −12" (from `size`), or "Changes" without one.
    var changesLabel: String? {
        guard !fileRows.isEmpty else { return nil }
        guard let size = shown.size else { return "Changes" }
        return "Changes · \(size.files == 1 ? "1 file" : "\(size.files) files") · \(PRVerdict.sizeWords(size))"
    }

    /// One row per file the answer lists (at most 50), in git's order. Shown for draft, open, and merged PRs when sent.
    var fileRows: [FileRow] {
        guard [.draft, .open, .merged].contains(shown.state), let files = shown.files else { return [] }
        return files.map { file in
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: true)
            let name = parts.last.map(String.init) ?? file.path
            let folder = parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
            let body: FileRow.Body = file.binary ? .binary : file.patch.map { .patch($0) } ?? (file.patchCut ? .tooLarge : .none)
            let counts = file.binary ? nil : "+\(file.additions) \u{2212}\(file.deletions)"
            return FileRow(path: file.path, name: name, folder: folder, counts: counts, body: body)
        }
    }

    /// How many changed files the list leaves out ("and N more files"); 0: none.
    var moreFiles: Int {
        let rows = fileRows.count
        guard rows > 0, let size = shown.size else { return 0 }
        return max(0, size.files - rows)
    }

    /// "and 3 more files", "and 1 more file".
    var moreFilesWords: String? {
        let more = moreFiles
        guard more > 0 else { return nil }
        return more == 1 ? "and 1 more file" : "and \(more) more files"
    }

    /// The words Ask to Fix Checks sends, while the checks of a numbered pull request fail. nil: no such action.
    var fixChecksWords: String? {
        guard [.draft, .open].contains(shown.state), !isLeadManual, shown.checks?.state == .failed,
              let number = shown.number else { return nil }
        return "The checks on pull request #\(number) are failing. Fix them."
    }

    /// "Ask Otto to Fix Checks…"
    var fixChecksTitle: String { "Ask \(botName) to Fix Checks…" }

    /// The card's status with a fresh answer: the new status, unless the chat's code is gone from it (the card keeps
    /// what it showed).
    static func refreshed(_ old: SessionPRStatus, with new: SessionPRStatus?) -> SessionPRStatus {
        guard let new, new.state != .none, new.state != .unknown else { return old }
        return new
    }
}
