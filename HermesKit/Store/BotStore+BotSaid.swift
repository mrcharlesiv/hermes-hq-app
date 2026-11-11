// [botsaid] A Bots row's preview is the newest thing the bot itself said in its Bot Chat (owner, 2026-10-27): never
// your own message, a scheduled run's report, another bot's delivery, a [SILENT] reply or a machine note. The roster's
// preview (`_latest_message_preview`) is the chat's newest line of any kind, so each bot whose chat moved has the tail
// of its Bot Chat read (`/api/sessions/{id}/messages`, a few at a time) and the newest of its own replies kept on the
// device until the chat moves again. The rows draw it in place of the roster's preview (`withBotSaid`).
//
// "Moved" is read off the roster's whole word on the chat (`BotSaidRules.mark`), not its `last_active` alone: that time
// is Hermes's activity heartbeat (`sessions.last_activity_at`, written at most about once a minute while a turn runs),
// so the reply that ends a turn is stored after it and never moves it. A row read while its bot was still working kept
// the words from before the reply until the chat was next used (owner 2026-11-10: "the preview text … does not match
// the last message in the chat from the bot"; on his gateway that day every Bot Chat's newest reply was 0.4 to 37 s
// newer than its `last_active`).

import Foundation

nonisolated struct BotSaidEntry: Codable, Sendable, Hashable {
    /// The Bot Chat read (its open id).
    var session: String
    /// The chat's `last_active` when read: a chat whose activity moved since is read again.
    var at: Double
    /// The bot's newest words; nil when the tail held none of its own.
    var text: String?
    /// What the roster said of the chat when it was read (`BotSaidRules.mark`); nil for words this device saw arrive
    /// (and for an entry kept by an older build): the next roster reads the chat.
    var mark: String? = nil
    /// The time of the newest stored row in the tail read (gateway seconds): the chat's real last activity, which the
    /// roster's `last_active` trails by up to a minute. nil until a read has measured it.
    var newest: Double? = nil
}

nonisolated enum BotSaidRules {
    /// Reads in the air at once.
    static let parallel = 3
    /// Rows asked for: enough to step past tool turns, a morning of scheduled runs and the owner's own messages.
    static let tail = 30
    /// What a row is handed when the bot's chat holds none of its words: read as "the bot has spoken, nothing to show"
    /// (`RosterPreview.botPreview` draws the role line, never "No messages yet").
    static let nothingShown = "[SILENT]"

    /// Everything the roster says of a chat that moves when a message is stored: its activity time, its counts and its
    /// newest line. A chat whose mark differs from the one it was read at is read again.
    static func mark(_ chat: RosterSessionRef) -> String {
        "\(chat.lastActive ?? 0)|\(chat.messageCount ?? -1)|\(chat.liveMessageCount ?? -1)|\(chat.preview ?? "")"
    }

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
            if let newest = entry.newest, newest > (canonical.lastActive ?? 0) { canonical.lastActive = newest }
            row.canonicalSession = canonical
            return row
        }
    }

    /// [botsaid] The roster's rows with each Bot Chat's activity moved up to its newest stored row, where a read has
    /// measured one. The roster's own `last_active` is the heartbeat from before the reply: the row's time, its unread
    /// dot and the saved copy of its chat (`ChatWarmer`) all go by this one instead.
    func withChatActivity(_ rows: [RosterProfile]) -> [RosterProfile] {
        guard let said = device.botSaid, !said.isEmpty else { return rows }
        return rows.map { row in
            guard let entry = said[row.name], let newest = entry.newest, var canonical = row.canonicalSession,
                  canonical.openId == entry.session || canonical.ids.contains(entry.session),
                  newest > (canonical.lastActive ?? 0) else { return row }
            var row = row
            canonical.lastActive = newest
            row.canonicalSession = canonical
            return row
        }
    }

    /// The roster's word on each Bot Chat as the gateway gave it (before `withChatActivity`).
    func noteRosterMarks(_ rows: [RosterProfile]) {
        botSaidMarks = Dictionary(rows.compactMap { row in row.canonicalSession.map { (row.name, BotSaidRules.mark($0)) } },
                                  uniquingKeysWith: { first, _ in first })
    }

    /// A tail read found the chat's newest stored row at `newest`. The first time a chat is measured only moves its
    /// baseline (the dot it has or hasn't is the one the heartbeat gave it); after that, activity past the baseline is
    /// unread like any other (a reply stored after the turn's last heartbeat used to get no dot once you had looked).
    private func chatActivityRead(_ name: String, session: String, newest: Double, first: Bool) {
        guard let i = profiles.firstIndex(where: { $0.name == name }), var canonical = profiles[i].canonicalSession,
              canonical.openId == session || canonical.ids.contains(session), newest > (canonical.lastActive ?? 0) else { return }
        canonical.lastActive = newest
        profiles[i].canonicalSession = canonical
        if first {
            device.unread.baselines[name] = max(device.unread.baselines[name] ?? 0, newest)
        } else {
            reconcileUnread([profiles[i]])
        }
    }

    /// Read the tail of each Bot Chat that moved since it was last read (after every full roster).
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
            let at = canonical.lastActive ?? 0, mark = botSaidMarks[profile.name] ?? BotSaidRules.mark(canonical)
            if let entry = said[profile.name], entry.session == canonical.openId, entry.mark == mark { continue }
            // A read already out or waiting for this very state covers it; one for an older state is followed by another.
            if botSaidOut[profile.name]?.mark == mark || botSaidQueue.contains(where: { $0.profile == profile.name && $0.mark == mark }) { continue }
            botSaidQueue.removeAll { $0.profile == profile.name }
            botSaidQueue.append((profile.name, canonical.openId, at, mark))
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
        var entry = BotSaidEntry(session: sessionId, at: at, text: line.count > 200 ? String(line.prefix(200)) : line)
        if let old = device.botSaid?[name], old.session == sessionId { entry.newest = old.newest }
        botSaidSeenAt[name] = .now
        guard device.botSaid?[name] != entry else { return false }
        device.botSaid = (device.botSaid ?? [:]).merging([name: entry]) { $1 }
        persistState()
        return true
    }

    private func pumpBotSaid() {
        // One read per bot at a time: a chat that moved again while its read is out waits for that answer.
        while botSaidOut.count < BotSaidRules.parallel,
              let next = botSaidQueue.firstIndex(where: { botSaidOut[$0.profile] == nil }) {
            let item = botSaidQueue.remove(at: next)
            botSaidOut[item.profile] = (item.mark, .now)
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

    private func botSaidRead(_ item: (profile: String, session: String, at: Double, mark: String), rows: [JSONValue]?) {
        let asked = botSaidOut.removeValue(forKey: item.profile)?.asked
        defer { pumpBotSaid() }
        guard !stopped else { return }
        guard let rows else {
            AppLog.trace("bots", "bot said \(item.profile): read failed, the next roster tries again")
            return
        }
        // Words this device saw arrive after the read was asked for are newer than what it read: they stay, and the next
        // roster reads the chat (a read that crossed a reply put the reply before it back on the row).
        if let seen = device.botSaid?[item.profile], seen.mark == nil, seen.session == item.session,
           let asked, let seenAt = botSaidSeenAt[item.profile], seenAt > asked {
            AppLog.trace("bots", "bot said \(item.profile): read crossed a reply seen here, the reply stays")
            return
        }
        var entry = BotSaidEntry(session: item.session, at: item.at, text: BotSaidRules.latest(rows), mark: item.mark)
        // Nothing of the bot's in the tail (a run of scheduled reports): the words already known for this chat stay.
        let old = device.botSaid?[item.profile].flatMap { $0.session == item.session ? $0 : nil }
        if entry.text == nil, let old { entry.text = old.text }
        entry.newest = [HistoryPage.newestTimestamp(rows), old?.newest].compactMap { $0 }.max()
        if let newest = entry.newest {
            chatActivityRead(item.profile, session: item.session, newest: newest, first: device.botSaid?[item.profile]?.newest == nil)
        }
        if device.botSaid?[item.profile] != entry {
            device.botSaid = (device.botSaid ?? [:]).merging([item.profile: entry]) { $1 }
            botSaidDirty += 1
        }
        // One rebuild and one write per few answers, not one per answer.
        guard botSaidDirty > 0, botSaidDirty >= 6 || (botSaidQueue.isEmpty && botSaidOut.isEmpty) else { return }
        AppLog.trace("bots", "bot said: \(botSaidDirty) rows updated")
        botSaidDirty = 0
        persistState()
        rebuild()
    }
}
