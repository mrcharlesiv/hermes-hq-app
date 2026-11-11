// [transcript] The files a turn changed, and the diffs its edit tools returned (docs/spec/3x-transcript.md §5.2 and
// §5.4, rows L346 and L348). Ported from the desktop's `changed-files.ts` (deriveChangedFiles, countDiffLineStats)
// and `S/tool-diffs.ts` (a bounded store: 200 diffs or 1,048,576 characters, the newest always kept).

import Foundation

nonisolated struct ChangedFile: Hashable, Sendable {
    /// The path exactly as the tool reported it (absolute or relative to the chat's folder).
    var path: String
    /// Basename, for the row.
    var name: String
    var added: Int
    var removed: Int
    /// How many landed edits the counts add up. A step's preview shows one edit's +/−, the card the file's whole turn,
    /// so a file edited twice says "2 edits" there (screenshot review of the n20 revisit, 2026-10-31: "+1 −3" on the
    /// step over "+3 −4" on the card read as a mismatch).
    var edits = 1
}

nonisolated enum ChangedFiles {
    /// The web's `isFileEditTool`.
    static let editTools: Set<String> = ["edit_file", "patch", "write_file"]

    static func isEditTool(_ name: String) -> Bool { editTools.contains(name) }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")

    /// The diff as Hermes sends it, made plain: its `inline_diff` is the CLI's coloured print (every line wrapped in
    /// ANSI colour codes, so none of them starts with "+" or "-"), led by a "┊ review diff" line (localised) and with
    /// "a/x → b/x" in place of the "---"/"+++" headers (agent/display.py `_render_inline_unified_diff`). The codes and
    /// the "┊" line go; an arrow header becomes a "+++ " line so `path` can still read it. A plain diff is unchanged.
    static func plain(_ diff: String) -> String {
        let stripped = diff.contains("\u{1B}")
            ? ansi.stringByReplacingMatches(in: diff, range: NSRange(diff.startIndex..., in: diff), withTemplate: "")
            : diff
        guard stripped.contains("┊") || stripped.contains("→") else { return stripped }
        var out: [String] = []
        stripped.enumerateLines { line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("┊") { return }
            if let first = t.first, !"+-@ ".contains(first), let arrow = t.range(of: " → "),
               !t[arrow.upperBound...].contains(" ") {
                out.append("+++ " + t[arrow.upperBound...])
                return
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Lines added and removed in a unified diff: lines starting "+" (not "+++") and "-" (not "---").
    static func lineStats(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        plain(diff).enumerateLines { line, _ in
            if line.hasPrefix("+") { if !line.hasPrefix("+++") { added += 1 } }
            else if line.hasPrefix("-") { if !line.hasPrefix("---") { removed += 1 } }
        }
        return (added, removed)
    }

    static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// The file an edit call names: its `path` / `file_path` / `file` argument, else the diff's "+++ b/<path>" header.
    static func path(args: [String: JSONValue], diff: String) -> String? {
        for key in ["path", "file_path", "file", "filepath", "target_file"] {
            if let value = args[key]?.string?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        var found: String?
        plain(diff).enumerateLines { line, stop in
            guard line.hasPrefix("+++ ") else { return }
            var name = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("b/") { name = String(name.dropFirst(2)) }
            if let tab = name.firstIndex(of: "\t") { name = String(name[..<tab]) }
            if !name.isEmpty, name != "/dev/null" { found = name; stop = true }
        }
        return found
    }

    /// One row per file the turn edited, in first-touched order, the +/− of every edit to that file summed. Only
    /// landed edits with a diff count (a running call has none; a failed one changed nothing).
    static func derive(calls: [(call: ToolCall, args: [String: JSONValue], diff: String?)]) -> [ChangedFile] {
        var order: [String] = []
        var byPath: [String: ChangedFile] = [:]
        for entry in calls {
            guard isEditTool(entry.call.name), entry.call.state == .done, let diff = entry.diff,
                  !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let path = path(args: entry.args, diff: diff) else { continue }
            let stats = lineStats(diff)
            if var existing = byPath[path] {
                existing.added += stats.added
                existing.removed += stats.removed
                existing.edits += 1
                byPath[path] = existing
            } else {
                order.append(path)
                byPath[path] = ChangedFile(path: path, name: basename(path), added: stats.added, removed: stats.removed)
            }
        }
        return order.compactMap { byPath[$0] }
    }

    /// "1 file changed" / "3 files changed".
    static func title(_ count: Int) -> String { count == 1 ? "1 file changed" : "\(count) files changed" }

    /// A card row's file in the Changes list: the exact path, then a suffix match on the repo-relative path.
    static func match(_ file: String, in listed: [String]) -> String? {
        if let exact = listed.first(where: { $0 == file }) { return exact }
        let clean = file.hasPrefix("./") ? String(file.dropFirst(2)) : file
        return listed.first { clean.hasSuffix("/" + $0) || $0.hasSuffix("/" + clean) || $0 == clean }
    }

    /// An edit tool's path, in a place `FileLinks`/the gateway's REST routes can open: a relative one ("src/app.js")
    /// joined to the chat's working folder; one already absolute, home-relative or a Windows path left as it is (and
    /// one with no known folder: a chat the app never learned a `cwd` for).
    static func resolve(_ path: String, in folder: String?) -> String {
        let clean = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        guard !clean.hasPrefix("/"), !clean.hasPrefix("~"), !clean.contains(":\\"), let folder, !folder.isEmpty else { return clean }
        return folder.hasSuffix("/") ? folder + clean : folder + "/" + clean
    }

    // MARK: The inline preview

    struct PreviewLine: Hashable, Sendable {
        enum Kind: Hashable, Sendable { case added, removed, context }
        var kind: Kind
        /// With its leading "+", "−" or space, so colour is never the only signal.
        var text: String
    }

    /// The first `limit` changed lines of a diff, each hunk's changes led by one line of context; and whether more
    /// follow. File headers, hunk headers and "\ No newline" marks are not lines.
    static func preview(_ diff: String, limit: Int = 8) -> (lines: [PreviewLine], more: Bool) {
        var out: [PreviewLine] = []
        var more = false
        var pendingContext: String?
        var lastWasChange = false
        let normalised = plain(diff.replacingOccurrences(of: "\r\n", with: "\n"))
        for raw in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("@@") || line.hasPrefix("\\") || line.hasPrefix("Binary files") {
                pendingContext = nil; lastWasChange = false
                continue
            }
            let isAdd = line.hasPrefix("+"), isDel = line.hasPrefix("-")
            guard isAdd || isDel else {
                pendingContext = line
                lastWasChange = false
                continue
            }
            if out.count >= limit { more = true; break }
            if !lastWasChange, let context = pendingContext, out.count < limit - 1 {
                out.append(PreviewLine(kind: .context, text: " " + context.dropFirst(context.hasPrefix(" ") ? 1 : 0)))
            }
            pendingContext = nil
            lastWasChange = true
            out.append(PreviewLine(kind: isAdd ? .added : .removed, text: (isAdd ? "+" : "−") + line.dropFirst()))
        }
        return (out, more)
    }
}

/// The diffs edit tools returned, by tool call id: 200 diffs or 1,048,576 characters, the newest always kept, cleared
/// on memory pressure (`S/tool-diffs.ts`). A row whose diff was evicted shows its header and "Show all changes".
nonisolated final class ToolDiffStore: @unchecked Sendable {
    static let shared = ToolDiffStore()
    static let maxDiffs = 200
    static let maxCharacters = 1_048_576

    private let lock = NSLock()
    private var diffs: [String: String] = [:]
    /// Oldest first.
    private var order: [String] = []
    private var characters = 0

    func set(_ diff: String, for id: String) {
        guard !id.isEmpty, !diff.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = diffs[id] {
            if old == diff {
                if order.last != id { order.removeAll { $0 == id }; order.append(id) }
                return
            }
            characters -= old.utf16.count
            order.removeAll { $0 == id }
        }
        diffs[id] = diff
        order.append(id)
        characters += diff.utf16.count
        while order.count > 1 && (order.count > Self.maxDiffs || characters > Self.maxCharacters) {
            let gone = order.removeFirst()
            if let text = diffs.removeValue(forKey: gone) { characters -= text.utf16.count }
        }
    }

    func diff(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return diffs[id]
    }

    func remove(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            guard let text = diffs.removeValue(forKey: id) else { continue }
            characters -= text.utf16.count
            order.removeAll { $0 == id }
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        diffs = [:]; order = []; characters = 0
    }

    var counts: (diffs: Int, characters: Int) {
        lock.lock(); defer { lock.unlock() }
        return (order.count, characters)
    }
}
