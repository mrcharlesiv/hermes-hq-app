// [shortcut-new-chat] The projects the Shortcuts app's New Chat action offers (owner 2026-11-20: "an iOS shortcut that
// opens a session with whatever bot you want in whatever project you want"). The Sessions store's projects, every
// bot's, one per folder, as the New Chat sheet lists them (`SessionProjects.newChatEntries`); stored in the app's own
// defaults so the system's pickers can read them off the main thread with no app model. Names and folders only.
//
// Also the `<scheme>://new-chat?bot=<profile>&project=<folder or name>` link the action opens through, which a
// shortcut's Open URL step (or any other app) can use as is.

import Foundation

/// One project as the pickers know it.
nonisolated struct ProjectShortcutRecord: Codable, Equatable, Sendable {
    /// The project's key: its folder on the gateway's computer (`SessionProjects.key`).
    let key: String
    let name: String
    /// `url + "\n" + username` (`VoiceBotCatalog.account`): a project of another sign-in is nobody's.
    let account: String
}

nonisolated enum ProjectShortcutCatalog {
    static let storeKey = "hq.intents.projects"
    static let maxProjects = 512

    static func projects(_ defaults: UserDefaults = .standard) -> [ProjectShortcutRecord] {
        guard let data = defaults.data(forKey: storeKey), data.count <= 1024 * 1024,
              let records = try? JSONDecoder().decode([ProjectShortcutRecord].self, from: data) else { return [] }
        return Array(records.prefix(maxProjects))
    }

    /// The records for the New Chat sheet's entries, signed in as `account` (Home and folder-less projects left out:
    /// a chat with no project already starts in the bot's own folder).
    static func records(_ entries: [SessionProjectEntry], account: String) -> [ProjectShortcutRecord] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let name = VoiceBotCatalog.clean(entry.label)
            guard entry.key != SessionProjects.homeKey, entry.key.hasPrefix("/") || entry.key.hasPrefix("~"),
                  !name.isEmpty, seen.insert(entry.key).inserted else { return nil }
            return ProjectShortcutRecord(key: entry.key, name: name, account: account)
        }
    }

    /// Writes only when the bytes differ. Returns whether it wrote.
    @discardableResult static func store(_ records: [ProjectShortcutRecord], _ defaults: UserDefaults = .standard) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(records.prefix(maxProjects))) else { return false }
        if defaults.data(forKey: storeKey) == data { return false }
        defaults.set(data, forKey: storeKey)
        return true
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: storeKey) }

    /// The stored project `wanted` names: its folder (a trailing "/" or not), else its name (any case).
    static func resolve(_ wanted: String, in records: [ProjectShortcutRecord]) -> ProjectShortcutRecord? {
        let text = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var folder = text                     // as `SessionProjects.folderKey` (main-actor isolated): no trailing "/"
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        if let hit = records.first(where: { $0.key == folder }) { return hit }
        return records.first { $0.name.caseInsensitiveCompare(text) == .orderedSame }
    }
}

/// `<scheme>://new-chat?bot=<profile>&project=<folder or name>&message=<words>&send=0|1`: a new chat with that bot, in
/// that project (no project: the bot's own folder, as a plain New Chat). `message`: its first message, sent at once
/// (`send=0`: left in the message box to send yourself).
nonisolated struct NewChatLink: Equatable, Sendable {
    static let kind = "new-chat"
    var bot: String
    var project: String?
    var message: String? = nil
    var send = true

    /// nil for any other link, or one without a bot.
    static func parse(_ link: DeepLink?) -> NewChatLink? {
        guard case .other(let kind, _, let params)? = link, kind == Self.kind else { return nil }
        let value: (String) -> String? = { key in
            params.last { $0.key == key }?.value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard let bot = value("bot") else { return nil }
        // The words as written (a leading space is theirs); only a message of blanks is none.
        let message = params.last { $0.key == "message" }?.value
        let send = value("send").map { !["0", "false", "no"].contains($0.lowercased()) } ?? true
        return NewChatLink(bot: bot, project: value("project"),
                           message: message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? message : nil, send: send)
    }

    /// External URLs (`<scheme>://new-chat`) from other apps or web pages must never auto-send a prompt:
    /// force `send = false` so the composer draft is prefilled for the user to review and tap Send.
    var forExternalURL: NewChatLink {
        var copy = self
        copy.send = false
        return copy
    }

    /// External URL sanitization: disables auto-send and resolves `project` strictly against already-saved projects
    /// (dropping unknown arbitrary filesystem paths so an external link cannot silently trigger `projects.create`).
    func sanitizedForExternalURL(knownProjects: [ProjectShortcutRecord]) -> NewChatLink {
        var copy = forExternalURL
        if let wanted = project {
            copy.project = ProjectShortcutCatalog.resolve(wanted, in: knownProjects)?.key
        }
        return copy
    }

    func url(scheme: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = Self.kind
        let items = [URLQueryItem(name: "bot", value: bot)] + (project.map { [URLQueryItem(name: "project", value: $0)] } ?? [])
            + (message.map { [URLQueryItem(name: "message", value: $0)] + (send ? [] : [URLQueryItem(name: "send", value: "0")]) } ?? [])
        // A value's own "&", "=", "+" and "#" are escaped too (URLComponents leaves them, splitting a message).
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        parts.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return parts.url
    }
}
