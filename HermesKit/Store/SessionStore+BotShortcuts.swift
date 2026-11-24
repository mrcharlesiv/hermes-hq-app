// A shortcut is a place to open an ordinary chat, not a change to the chat. Only the bot list reads these rows.
import Foundation

nonisolated struct BotChatShortcut: Codable, Hashable, Sendable {
    let profile: String
    let id: String

    var json: JSONValue { ["profile": .string(profile), "id": .string(id)] }

    static func decode(_ value: JSONValue?) -> [Self]? {
        value?.array?.compactMap {
            guard let profile = RosterText.trimmed($0["profile"]), let id = RosterText.trimmed($0["id"]) else { return nil }
            return Self(profile: profile, id: id)
        }
    }

    /// A concurrent edit to another shortcut doesn't resurrect one removed on either device.
    static func merged(local: [Self], remote: [Self], base: [Self], policy: GatewaySyncMerge) -> [Self] {
        var seen = Set<Self>()
        switch policy {
        case .replace: return remote.filter { seen.insert($0).inserted }
        case .firstContact: return (remote + local).filter { seen.insert($0).inserted }
        case .rebase:
            if local == base { return remote.filter { seen.insert($0).inserted } }
            let removed = Set(base).subtracting(local).union(Set(base).subtracting(remote))
            return (local + remote).filter { !removed.contains($0) && seen.insert($0).inserted }
        }
    }
}

extension SessionStore {
    var hasBotShortcuts: Bool { !device.botChatShortcuts.isEmpty }

    /// Devices can choose different segments before the sidebar identifies them as the same conversation.
    private func shortcutKeys(id: String, profile: String) -> [BotChatShortcut] {
        guard hasBotShortcuts else { return [] }
        let listed = listedShortcutRows()
        return device.botChatShortcuts.filter { key in
            key.profile == profile && (key.id == id || (listed[key] ?? offPageShortcuts[key])?.liveId(where: { $0 == id }) != nil)
        }
    }

    func hasBotShortcut(_ session: SessionSummary) -> Bool {
        !shortcutKeys(id: session.id, profile: session.profile).isEmpty
    }

    /// Invalidate an older detail response too. Archive keeps the selection for Unarchive; Delete or Remove forgets it.
    @discardableResult func forgetBotShortcutRow(id: String, profile: String, deleting: Bool) -> Bool {
        let keys = Set(shortcutKeys(id: id, profile: profile))
        guard !keys.isEmpty else { return false }
        for key in keys { offPageShortcuts[key] = nil; shortcutCheckedAt[key] = deleting ? nil : .now }
        if deleting { device.botChatShortcuts.removeAll(where: keys.contains); persistState() }
        return true
    }

    private func eligibleShortcut(_ row: SidebarSessionRow) -> Bool {
        row.archived != true && !SessionRules.isBotChat(row) && !SessionRules.isBackgroundRun(row)
            && !Self.isScheduledRun(row) && !Self.recentsExcluded.contains(row.source ?? "")
            && row.title?.hasPrefix("Task: ") != true
            && !leaving.contains(Self.writeKey(id: row.id, profile: row.profile))
    }

    func canAddBotShortcut(_ session: SessionSummary) -> Bool {
        guard !session.archived, !session.outside else { return false }
        return eligibleShortcut(storedRow(session) ?? SidebarSessionRow(id: session.id, profile: session.profile,
            title: session.title, preview: session.preview, source: session.source))
    }

    func setBotShortcut(_ session: SessionSummary, _ shown: Bool) {
        if shown {
            guard !hasBotShortcut(session), canAddBotShortcut(session) else { return }
            let id = storedRow(session).map(Self.durableId) ?? session.id
            device.botChatShortcuts.insert(BotChatShortcut(profile: session.profile, id: id), at: 0)
            persistState()
        } else if !forgetBotShortcutRow(id: session.id, profile: session.profile, deleting: true) { return }
        onChange?()
        refreshOffPageShortcuts()
    }

    /// Match the current segment by lineage. A known hidden/archived row must win over an older off-page answer.
    private func listedShortcutRows() -> [BotChatShortcut: SidebarSessionRow] {
        var found: [BotChatShortcut: SidebarSessionRow] = [:]
        for row in archivedRows + recents.reversed() {
            for id in [row.id] + [row.lineageRootId].compactMap({ $0 }) + (row.lineageIds ?? []) {
                found[BotChatShortcut(profile: row.profile, id: id)] = row
            }
        }
        return found
    }

    /// No global/project pin, sorting, search, unread count or chat strip sees the exception.
    var botShortcutRows: [SessionSummary] {
        guard !device.botChatShortcuts.isEmpty else { return [] }
        let listed = listedShortcutRows()
        var shown = Set<BotChatShortcut>()
        return device.botChatShortcuts.compactMap { key in
            guard let row = listed[key] ?? offPageShortcuts[key], eligibleShortcut(row),
                  shown.insert(BotChatShortcut(profile: row.profile, id: row.id)).inserted else { return nil }
            return shortcutSummary(row)
        }
    }

    /// The sidebar is paged. Read *only* selected ids that aged out, sequentially, at most once a minute per id.
    /// The detail route also accepts prefixes: only the exact chat or its proven lineage is a shortcut target.
    func refreshOffPageShortcuts() {
        guard hasBotShortcuts, !stopped, loadState == .ready else { return }
        let selected = device.botChatShortcuts, listed = listedShortcutRows(), now = ContinuousClock.now
        // A newer sidebar read also invalidates an older, in-flight detail response for this chat.
        for key in selected where listed[key] != nil { offPageShortcuts[key] = nil; shortcutCheckedAt[key] = nil }
        guard shortcutRead == nil else { return }
        let missing = selected.filter { listed[$0] == nil && (shortcutCheckedAt[$0].map { now - $0 >= .seconds(60) } ?? true) }
        guard !missing.isEmpty else { return }
        shortcutRead = Task { [weak self] in
            guard let self else { return }
            for key in missing where !Task.isCancelled && self.device.botChatShortcuts.contains(key) {
                let began = ContinuousClock.now
                self.shortcutCheckedAt[key] = began
                let row: SidebarSessionRow?
                do {
                    let data = try await self.client.rest("GET", Self.path(key.id), query: [URLQueryItem(name: "profile", value: key.profile)], body: nil)
                    let json = try JSONValue.parse(data)
                    var detail = SidebarSessionRow(json: json)
                    if json["profile"]?.string == nil && json["profile_name"]?.string == nil { detail?.profile = key.profile }
                    row = detail.flatMap { $0.profile == key.profile && $0.liveId(where: { $0 == key.id }) != nil ? $0 : nil }
                } catch let error as HTTPError where [403, 404, 410].contains(error.status) {
                    row = nil
                } catch { continue } // A transport failure doesn't erase a confirmed shortcut.
                guard !Task.isCancelled, !self.stopped, self.device.botChatShortcuts.contains(key), self.shortcutCheckedAt[key] == began else { continue }
                if self.offPageShortcuts[key] != row { self.offPageShortcuts[key] = row; self.onChange?() }
            }
            guard !Task.isCancelled else { return }
            self.shortcutRead = nil
            if !Set(self.device.botChatShortcuts).isSubset(of: selected) { self.refreshOffPageShortcuts() }
        }
    }
}
