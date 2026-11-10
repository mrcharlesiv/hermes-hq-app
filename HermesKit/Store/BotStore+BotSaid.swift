// [botsaid] A Bots row's preview is the newest thing the bot itself said in its Bot Chat (owner, 2026-10-27): never
// your own message, a scheduled run's report, another bot's delivery, a [SILENT] reply or a machine note. The roster's
// preview (`_latest_message_preview`) is the chat's newest line of any kind, so each bot whose chat moved has the tail
// of its Bot Chat read (`/api/sessions/{id}/messages`, a few at a time) and the newest of its own replies kept on the
// device until the chat moves again. The rows draw it in place of the roster's preview (`withBotSaid`).

import Foundation

nonisolated struct BotSaidEntry: Codable, Sendable, Hashable {
    /// The Bot Chat read (its open id).
    var session: String
    /// The chat's `last_active` when read: a chat whose activity moved since is read again.
    var at: Double
    /// The bot's newest words; nil when the tail held none of its own.
    var text: String?
}

nonisolated enum BotSaidRules {
    /// Reads in the air at once.
    static let parallel = 3
    /// Rows asked for: enough to step past tool turns, a morning of scheduled runs and the owner's own messages.
    static let tail = 30
    /// What a row is handed when the bot's chat holds none of its words: read as "the bot has spoken, nothing to show"
    /// (`RosterPreview.botPreview` draws the role line, never "No messages yet").
    static let nothingShown = "[SILENT]"

    /// The newest assistant message that is the bot's own words, else nil.
    static func latest(_ rows: [JSONValue]) -> String? {
        let ordered = rows.enumerated().sorted { a, b in
            let ia = HistoryPage.rowId(a.element), ib = HistoryPage.rowId(b.element)
            if let ia, let ib, ia != ib { return ia > ib }
            return a.offset > b.offset
        }.map(\.element)
        for row in ordered where row["role"]?.string == "assistant" {
            let text = SessionLatestRules.words(row["content"])
            guard isOwnWords(text) else { continue }
            let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return line.count > 200 ? String(line.prefix(200)) : line
        }
        return nil
    }

    /// An assistant message's text is something the bot said to you: not a cron run's report, a delivery from another
    /// bot, a process or system note, nor a bare [SILENT].
    static func isOwnWords(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !RosterPreview.isSilentOnly(trimmed) else { return false }
        if CronDeliveries.mayBeCron(trimmed) || CronDeliveries.processNote(trimmed) != nil { return false }
        if RosterPreview.isDelivery(trimmed) || RosterPreview.isMachineNote(trimmed) { return false }
        return !RosterPreview.cleanPreviewText(trimmed).isEmpty
    }
}

extension BotStore {
    /// The rows the list draws: each Bot Chat's preview is the bot's own newest words when they have been read.
    func withBotSaid(_ rows: [RosterProfile]) -> [RosterProfile] {
        guard let said = device.botSaid, !said.isEmpty else { return rows }
        return rows.map { row in
            guard let entry = said[row.name], var canonical = row.canonicalSession,
                  canonical.openId == entry.session || canonical.ids.contains(entry.session) else { return row }
            var row = row
            canonical.preview = entry.text ?? BotSaidRules.nothingShown
            row.canonicalSession = canonical
            return row
        }
    }

    /// Read the tail of each Bot Chat whose activity moved since it was last read (after every full roster).
    func refreshBotSaid() {
        guard !stopped, timing.readsBotSaid else { return }
        var said = device.botSaid ?? [:]
        let known = Set(profiles.map(\.name))
        if said.keys.contains(where: { !known.contains($0) }) {
            said = said.filter { known.contains($0.key) }
            device.botSaid = said
        }
        var queued = 0
        for profile in profiles {
            guard let canonical = profile.canonicalSession, !canonical.id.isEmpty, RosterRules.holdsMessages(canonical) else { continue }
            let at = canonical.lastActive ?? 0
            if let entry = said[profile.name], entry.session == canonical.openId, entry.at == at { continue }
            if botSaidReads.contains(profile.name) || botSaidQueue.contains(where: { $0.profile == profile.name }) { continue }
            botSaidQueue.append((profile.name, canonical.openId, at))
            queued += 1
        }
        if queued > 0 { AppLog.trace("bots", "bot said: \(queued) chats queued") }
        pumpBotSaid()
    }

    /// The bot just said `text` in its Bot Chat, seen by this device: its row shows it before the next read. True when
    /// the kept words changed (the caller rebuilds).
    @discardableResult
    func noteBotSaid(profile name: String, sessionId: String, text: String, at: Double) -> Bool {
        guard BotSaidRules.isOwnWords(text) else { return false }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let entry = BotSaidEntry(session: sessionId, at: at, text: line.count > 200 ? String(line.prefix(200)) : line)
        guard device.botSaid?[name] != entry else { return false }
        device.botSaid = (device.botSaid ?? [:]).merging([name: entry]) { $1 }
        persistState()
        return true
    }

    private func pumpBotSaid() {
        while botSaidReads.count < BotSaidRules.parallel, !botSaidQueue.isEmpty {
            let item = botSaidQueue.removeFirst()
            botSaidReads.insert(item.profile)
            let client = self.client
            Task { [weak self] in
                let query = [URLQueryItem(name: "profile", value: item.profile),
                             URLQueryItem(name: "limit", value: String(BotSaidRules.tail)),
                             URLQueryItem(name: "order", value: "latest")]
                let path = "/api/sessions/\(HistoryRequest.encodePathSegment(item.session))/messages"
                let rows: [JSONValue]? = await {
                    guard let data = try? await client.get(path, query), let root = try? JSONValue.parse(data) else { return nil }
                    return root["messages"]?.array ?? []
                }()
                self?.botSaidRead(item, rows: rows)
            }
        }
    }

    private func botSaidRead(_ item: (profile: String, session: String, at: Double), rows: [JSONValue]?) {
        botSaidReads.remove(item.profile)
        defer { pumpBotSaid() }
        guard !stopped else { return }
        guard let rows else {
            AppLog.trace("bots", "bot said \(item.profile): read failed, the next roster tries again")
            return
        }
        var entry = BotSaidEntry(session: item.session, at: item.at, text: BotSaidRules.latest(rows))
        // Nothing of the bot's in the tail (a run of scheduled reports): the words already known for this chat stay.
        if entry.text == nil, let old = device.botSaid?[item.profile], old.session == item.session { entry.text = old.text }
        if device.botSaid?[item.profile] != entry {
            device.botSaid = (device.botSaid ?? [:]).merging([item.profile: entry]) { $1 }
            botSaidDirty += 1
        }
        // One rebuild and one write per few answers, not one per answer.
        guard botSaidDirty > 0, botSaidDirty >= 6 || (botSaidQueue.isEmpty && botSaidReads.isEmpty) else { return }
        AppLog.trace("bots", "bot said: \(botSaidDirty) rows updated")
        botSaidDirty = 0
        persistState()
        rebuild()
    }
}
