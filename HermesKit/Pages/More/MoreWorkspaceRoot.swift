// More › Files and Review (docs/spec/3x-morepages.md §11): which folder the pages show, and the words around it.
// Pure rules, ported from the web: `S/phone-files-root.tsx` (the chosen folder, kept per gateway and profile until
// "Use Chat’s Folder"), `S/fe-pages-r4.ts` (`gatewayHome`, `gatewayPath`, `folderErrorText`), `S/fe-pages-r5.ts`
// (`truncatedNotice`).
//
// Precedence: 1) the folder chosen here for this gateway and bot; else 2) the working folder of the chat last on
// screen, when that chat is this bot's; else 3) the gateway's own answer to `GET /api/fs/default-cwd`.

import Foundation

nonisolated enum MoreWorkspaceRoot {
    enum Source: String, Sendable, Equatable { case chosen, chat, gateway }

    struct Root: Equatable, Sendable {
        var path: String
        var source: Source
    }

    // MARK: Precedence

    /// The root to show, nil when none of the three is a folder path (the page then says why).
    static func resolve(chosen: String?, chatFolder: String?, gatewayDefault: String?) -> Root? {
        if let path = folder(chosen) { return Root(path: path, source: .chosen) }
        if let path = folder(chatFolder) { return Root(path: path, source: .chat) }
        if let path = folder(gatewayDefault) { return Root(path: path, source: .gateway) }
        return nil
    }

    /// A usable folder path: absolute, trimmed, without a trailing slash ("/" stays "/"). nil for anything else
    /// (`readFilesRoot`: `path.startsWith('/')`).
    static func folder(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else { return nil }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Whether the gateway must be asked for its default folder (nothing chosen and no chat folder).
    static func needsGatewayDefault(chosen: String?, chatFolder: String?) -> Bool {
        folder(chosen) == nil && folder(chatFolder) == nil
    }

    // MARK: The chosen folder (UserDefaults `pages.filesRoot.<account>.<profile>`)

    static func key(account: String, profile: String) -> String {
        "pages.filesRoot.\(account).\(profile.isEmpty ? "default" : profile)"
    }

    static func chosen(account: String, profile: String, defaults: UserDefaults = .standard) -> String? {
        folder(defaults.string(forKey: key(account: account, profile: profile)))
    }

    /// nil (or a path that is not absolute) forgets the choice: "Use Chat’s Folder".
    static func setChosen(_ path: String?, account: String, profile: String, defaults: UserDefaults = .standard) {
        if let path = folder(path) {
            defaults.set(path, forKey: key(account: account, profile: profile))
        } else {
            defaults.removeObject(forKey: key(account: account, profile: profile))
        }
    }

    /// Sign Out: every bot's chosen folder for the account.
    static func forget(account: String, defaults: UserDefaults = .standard) {
        let prefix = "pages.filesRoot.\(account)."
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(prefix) { defaults.removeObject(forKey: name) }
    }

    // MARK: Paths in words

    /// The gateway user's home: the default profile lives in "<home>/.hermes". nil when unknown (a custom
    /// HERMES_HOME), and then no path is shortened (`gatewayHome`).
    static func gatewayHome(defaultProfilePath: String?) -> String? {
        let path = (defaultProfilePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), let range = path.range(of: "/.hermes") else { return nil }
        let after = path[range.upperBound...]
        guard after.isEmpty || after.hasPrefix("/") else { return nil }
        let home = String(path[..<range.lowerBound])
        return home.isEmpty ? nil : home
    }

    /// The default profile's folder out of a `GET /api/profiles` answer (`{"profiles":[{"name","path","is_default"}]}`).
    static func gatewayHome(profiles json: JSONValue) -> String? {
        let rows = json["profiles"]?.array ?? json.array ?? []
        let row = rows.first { $0["is_default"]?.bool == true } ?? rows.first { $0["name"]?.string == "default" }
        return gatewayHome(defaultProfilePath: row?["path"]?.string)
    }

    /// "~/Projects/app" for a folder in the gateway user's own home; any other folder keeps its whole path (`gatewayPath`).
    static func display(_ path: String, home: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        guard let home, !home.isEmpty, value.hasPrefix("/") else { return value }
        if value == home { return "~" }
        return value.hasPrefix(home + "/") ? "~" + value.dropFirst(home.count) : value
    }

    /// The folder's own name ("site"); "/" for the top.
    static func name(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.last.map(String.init) ?? "/"
    }

    /// The folder holding `path`; "/" has none.
    static func parent(_ path: String) -> String? {
        guard let path = folder(path), path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// Where the root comes from, under its path (`PhoneFilesHeader`'s source line).
    static func sourceLine(_ source: Source, chatTitle: String?) -> String {
        switch source {
        case .chosen: return "Folder you chose"
        case .chat:
            let title = chatTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "The folder of your last chat" : "The folder of “\(title)”"
        case .gateway: return "The default folder on \(HostWord.phrase)"   // [mac] Stress test 2026-10-28 #60: one name for the host
        }
    }

    // MARK: Failure words

    struct Words: Equatable, Sendable {
        var title: String
        var body: String
    }

    /// What Files says when its folder cannot be read: the reason in words, never "(ENOENT)" (`folderErrorText`; the
    /// titles in the app's Title Case).
    static func folderErrorText(_ code: String, chatFolder: Bool) -> Words {
        let folder = chatFolder ? "This chat’s folder" : "This folder"
        let reason = code.trimmingCharacters(in: .whitespacesAndNewlines)
        func starts(_ word: String) -> Bool {
            guard reason.hasPrefix(word) else { return false }
            // The web's `\b`: the code ends there ("ENOENT: no such file" counts, "ENOENTX" does not).
            guard let next = reason.dropFirst(word.count).unicodeScalars.first else { return true }
            return !(CharacterSet.alphanumerics.contains(next) || next == "_")
        }
        if starts("ENOENT") { return Words(title: "Folder Not Found", body: "\(folder) no longer exists on \(HostWord.phrase).") }
        if starts("EACCES") || starts("EPERM") {
            return Words(title: "Can’t Open This Folder",
                         body: "\(HostWord.sentence) doesn’t allow Hermes HQ to read \(chatFolder ? "this chat’s folder" : "this folder").")
        }
        if starts("ENOTDIR") { return Words(title: "Not a Folder", body: "\(folder) is a file on \(HostWord.phrase), not a folder.") }
        return Words(title: "Couldn’t Read This Folder", body: reason.isEmpty ? "\(HostWord.sentence) did not say why." : reason)
    }

    static let previewKB = 512

    /// "2.5 MB" / "640 KB" (`fileSize`: one decimal, a trailing ".0" dropped).
    static func fileSize(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            let text = String(format: "%.1f", Double(bytes) / 1_048_576)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + " MB"
        }
        return "\(Int((Double(bytes) / 1024).rounded())) KB"
    }

    /// "Showing the first 512 KB of 2.5 MB." (`truncatedNotice`).
    static func truncatedNotice(byteSize: Int?) -> String {
        if let byteSize, byteSize > previewKB * 1024 { return "Showing the first \(previewKB) KB of \(fileSize(byteSize))." }
        return "Showing the first \(previewKB) KB."
    }

    // MARK: Review

    static let noChanges = Words(title: "No Changes", body: "Nothing has changed in this folder since its last saved version.")
    static let notGit = Words(title: "Not a Git Folder", body: "Changes shows what changed in a project that uses Git.")

    /// A refused review list that means "this folder is not a repository" (git's own words in the 400's detail).
    static func isNotGit(reason: String) -> Bool {
        let text = reason.lowercased()
        return text.contains("not a git repository") || text.contains("not a git repo")
    }

    /// "+12 −3" (a real minus sign, as the chat's Changes page). Item 18: a zero side is left out ("New file · +5",
    /// not "New file · +5 −0" — a new file can't have removed lines), both sides kept only when both are above zero.
    static func counts(added: Int, removed: Int) -> String {
        let add = max(0, added), remove = max(0, removed)
        if add > 0, remove > 0 { return "+\(add) −\(remove)" }
        if remove > 0 { return "−\(remove)" }
        return "+\(add)"
    }

    /// The letter a change shows ("M", "A", "D", "R", "C", "U", "?"): one upper-case character, "M" when unknown.
    static func statusLetter(_ status: String) -> String {
        let letter = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["M", "A", "D", "R", "C", "U", "?"].contains(letter) ? letter : "M"
    }

    /// The symbol a change shows in place of git's letter (UX study #116: "M" and "?" mean nothing to most people).
    static func statusSymbol(_ status: String) -> String {
        switch statusLetter(status) {
        case "A", "?": return "plus.square.fill"
        case "D": return "minus.square.fill"
        case "R": return "arrow.right.square.fill"
        case "C": return "plus.square.on.square.fill"
        case "U": return "exclamationmark.triangle.fill"
        default: return "pencil.circle.fill"
        }
    }

    // MARK: Opening a file

    enum Opening: Equatable, Sendable { case text, download }

    /// A file with a text extension (or none: Makefile, LICENSE) is read as text first; anything else is downloaded
    /// for Quick Look.
    static func opening(name: String) -> Opening {
        let base = (name as NSString).lastPathComponent
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return .text }
        let ext = base[base.index(after: dot)...].lowercased()
        if ext.isEmpty { return .text }
        return ArtifactFiles.textExtensions.contains(ext) || ["html", "htm", "csv", "tsv", "env", "gitignore", "lock"].contains(ext) ? .text : .download
    }

    /// Duplicate paths in a listing never reach a table twice (first one wins, order kept).
    static func deduped(_ entries: [WorkspaceEntry]) -> [WorkspaceEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.path).inserted }
    }

    static func deduped(_ changes: [WorkspaceChange]) -> [WorkspaceChange] {
        var seen = Set<String>()
        return changes.filter { seen.insert("\($0.staged)|\($0.path)").inserted }
    }
}

/// The chat last on screen, as Files and Review need it: whose it is, its stored id, its folder when the chat said
/// one, its title. Kept per account in UserDefaults (`pages.filesChat.<account>`).
nonisolated struct MoreChatFolderRecord: Codable, Equatable, Sendable {
    var profile: String
    var sessionId: String?
    var cwd: String?
    var title: String?

    static func key(_ account: String) -> String { "pages.filesChat.\(account)" }

    static func read(account: String, defaults: UserDefaults = .standard) -> MoreChatFolderRecord? {
        guard let data = defaults.data(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(MoreChatFolderRecord.self, from: data)
    }

    func write(account: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        if defaults.data(forKey: Self.key(account)) != data { defaults.set(data, forKey: Self.key(account)) }
    }

    static func forget(account: String, defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key(account)) }

    /// The folder for `profile`'s Files: this chat's own, else the folder its row on the Sessions list carries; nil
    /// when the chat is another bot's or has no folder.
    func folder(for profile: String, sessions: [SessionSummary]) -> String? {
        let mine = self.profile.isEmpty ? "default" : self.profile
        guard mine == (profile.isEmpty ? "default" : profile) else { return nil }
        if let own = MoreWorkspaceRoot.folder(cwd) { return own }
        guard let sessionId, let row = sessions.first(where: { $0.id == sessionId }) else { return nil }
        return MoreWorkspaceRoot.folder(row.cwd)
    }
}
