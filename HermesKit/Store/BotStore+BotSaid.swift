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
    /// The rules the words were picked by (`BotSaidRules.rule`); nil for an entry kept by an older build, whose words
    /// may be a reply written to another bot: its chat is read again and its words aren't carried over.
    var rule: Int? = nil
}

nonisolated enum BotSaidRules {
    /// Reads in the air at once.
    static let parallel = 3
    /// Rows asked for: enough to step past tool turns, a morning of scheduled runs and the owner's own messages.
    static let tail = 30
    /// Rows asked for when the newest reply's turn began before that tail (a long turn of tool calls): what it
    /// answers decides whether it was written to you (`Shown.settled`).
    static let deepTail = 160
    /// The rules the kept words were picked by. 2: the chat's own rows (`shown`), so a reply written to another bot
    /// is never the preview.
    static let rule = 2
    /// What a row is handed when the bot's chat holds none of its words: read as "the bot has spoken, nothing to show"
    /// (`RosterPreview.botPreview` draws the role line, never "No messages yet").
    static let nothingShown = "[SILENT]"

    /// Everything the roster says of a chat that moves when a message is stored: its activity time, its counts and its
    /// newest line. A chat whose mark differs from the one it was read at is read again.
    static func mark(_ chat: RosterSessionRef) -> String {
        "\(chat.lastActive ?? 0)|\(chat.messageCount ?? -1)|\(chat.liveMessageCount ?? -1)|\(chat.preview ?? "")"
    }

    /// The bot's newest words to you in a tail of stored rows, else nil (`shown`, BotSaidShown.swift).
    static func latest(_ rows: [JSONValue], own: DeliveryMessages.Seat = .init(profile: "", name: "", head: nil),
                       seats: [DeliveryMessages.Seat] = []) -> String? {
        shown(rows: rows, own: own, seats: seats).text
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
            // [botunread] A bot waiting for its dot with no read out or queued is owed one, moved or not.
            let owed = device.unread.held(profile.name) != nil && botSaidOut[profile.name] == nil
                && !botSaidQueue.contains { $0.profile == profile.name }
            let stale = botSaidStale.contains(profile.name) || owed
            if !stale, let entry = said[profile.name], entry.session == canonical.openId, entry.mark == mark,
               entry.rule == BotSaidRules.rule { continue }
            // A read already out or waiting for this very state covers it; one for an older state is followed by another.
            if botSaidQueue.contains(where: { $0.profile == profile.name && $0.mark == mark }) { continue }
            if !stale, botSaidOut[profile.name]?.mark == mark { continue }
            botSaidStale.remove(profile.name)
            botSaidQueue.removeAll { $0.profile == profile.name }
            botSaidQueue.append((profile.name, canonical.openId, at, mark))
            queued += 1
        }
        if queued > 0 { AppLog.trace("bots", "bot said: \(queued) chats queued") }
        pumpBotSaid()
    }

    /// A reply landed in the bot's chat while this device wasn't showing it: only its words are known here, not what
    /// they answer (it may be written to another bot), so the chat's tail is read now and the row follows that.
    func rereadBotSaid(profile name: String) {
        botSaidStale.insert(name)
        refreshBotSaid()
    }

    /// The bot just said `text` to you in its Bot Chat, seen by this device (`BotSaidRules.shown` picked it from the
    /// chat's own messages): its row shows it before the next read. True when the kept words changed (the caller
    /// rebuilds).
    @discardableResult
    func noteBotSaid(profile name: String, sessionId: String, text: String, at: Double) -> Bool {
        guard BotSaidRules.isOwnWords(text) else { return false }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var entry = BotSaidEntry(session: sessionId, at: at, text: line.count > 200 ? String(line.prefix(200)) : line,
                                 rule: BotSaidRules.rule)
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
            let seats = DeliveryRoster.seats
            let own = seats.first { $0.profile == item.profile } ?? DeliveryMessages.Seat(profile: item.profile, name: item.profile, head: nil)
            // [botunread] What the rows are judged from: the baseline a waiting bot passed, else the one this read may
            // find the chat's newest row past (`chatActivityRead`).
            let since = device.unread.held(item.profile) ?? device.unread.baselines[item.profile]
            Task { [weak self] in
                let path = "/api/sessions/\(HistoryRequest.encodePathSegment(item.session))/messages"
                func tail(_ limit: Int, images: Bool) async -> [JSONValue]? {
                    var query = [URLQueryItem(name: "profile", value: item.profile),
                                 URLQueryItem(name: "limit", value: String(limit)),
                                 URLQueryItem(name: "order", value: "latest")]
                    if !images { query.append(URLQueryItem(name: "inline_images", value: "false")) }
                    guard let data = try? await client.get(path, query), let root = try? JSONValue.parse(data) else { return nil }
                    return root["messages"]?.array ?? []
                }
                var rows = await tail(BotSaidRules.tail, images: true)
                var shown = rows.map { BotSaidRules.shown(rows: $0, own: own, seats: seats) }
                // The newest reply's turn began before these rows (or they hold no reply at all) and the chat goes
                // further back: what the reply answers is read too, once.
                if let short = rows, let first = shown, !first.settled, short.count >= BotSaidRules.tail,
                   let deep = await tail(BotSaidRules.deepTail, images: false), deep.count > short.count {
                    rows = deep
                    shown = BotSaidRules.shown(rows: deep, own: own, seats: seats)
                }
                // [botunread] Every row read is newer than the baseline (a long turn): the rows behind them are read
                // too, once, so a reply to you under a long talk between bots isn't missed.
                var asked = rows.map { $0.count > BotSaidRules.tail ? BotSaidRules.deepTail : BotSaidRules.tail } ?? BotSaidRules.tail
                if let since, let short = rows, asked == BotSaidRules.tail, short.count >= asked,
                   !short.contains(where: { ($0["timestamp"]?.double ?? .infinity) <= since }),
                   let deep = await tail(BotSaidRules.deepTail, images: false), deep.count > short.count {
                    rows = deep
                    shown = BotSaidRules.shown(rows: deep, own: own, seats: seats)
                    asked = BotSaidRules.deepTail
                }
                var whole = (rows?.count ?? 0) < asked
                var news = since.flatMap { since in
                    rows.map { BotSaidRules.newsForYou(rows: $0, since: since, own: own, seats: seats, whole: whole) }
                }
                // "Nothing for you" from a short tail of a longer chat is checked against more of it, once: whether a
                // reply was written to another bot hangs on what this bot asked that bot earlier, which a tail that
                // starts inside a long turn doesn't hold (the reply then read as that bot's own request answered).
                if let since, news == false, let short = rows, asked == BotSaidRules.tail, short.count >= asked,
                   let deep = await tail(BotSaidRules.deepTail, images: false), deep.count > short.count {
                    rows = deep
                    shown = BotSaidRules.shown(rows: deep, own: own, seats: seats)
                    whole = deep.count < BotSaidRules.deepTail
                    news = BotSaidRules.newsForYou(rows: deep, since: since, own: own, seats: seats, whole: whole)
                }
                self?.botSaidRead(item, rows: rows, text: shown?.text,
                                  news: since.map { (since: $0, forYou: news ?? true, whole: whole, own: own, seats: seats) })
            }
        }
    }

    /// [botunread] What a tail read found for the dot: the baseline it judged from and whether anything past it is for you.
    typealias BotNews = (since: Double, forYou: Bool, whole: Bool, own: DeliveryMessages.Seat, seats: [DeliveryMessages.Seat])

    /// [botunread] A waiting bot's chat was read (`rows`; nil: the read failed): it gets its dot when something past its
    /// baseline is for you. A read asked for before the bot began waiting hasn't seen the rows that moved it and
    /// settles nothing (`born`: the wait began inside this read, from its own rows).
    private func settleUnread(_ name: String, rows: [JSONValue]?, news: BotNews?, asked: ContinuousClock.Instant?, born: Bool) {
        guard let since = device.unread.held(name), let profile = profile(named: name) else { return }
        if !born, let held = unreadHeldAt[name], let asked, asked < held { return }
        var forYou = true
        if let rows {
            if let news, news.since == since {
                forYou = news.forYou
            } else {
                let seats = news?.seats ?? DeliveryRoster.seats
                let own = news?.own ?? seats.first { $0.profile == name } ?? DeliveryMessages.Seat(profile: name, name: name, head: nil)
                forYou = BotSaidRules.newsForYou(rows: rows, since: since, own: own, seats: seats, whole: news?.whole ?? false)
            }
        }
        unreadHeldAt[name] = nil
        device.unread.settle(profile, forYou: forYou)
        AppLog.trace("bots", "unread \(name): \(rows == nil ? "read failed, marked" : forYou ? "something for you, marked" : "only bot talk, no dot")")
        botSaidDirty += 1
    }

    private func botSaidRead(_ item: (profile: String, session: String, at: Double, mark: String), rows: [JSONValue]?, text: String?,
                             news: BotNews? = nil) {
        let asked = botSaidOut.removeValue(forKey: item.profile)?.asked
        defer { pumpBotSaid() }
        guard !stopped else { return }
        guard let rows else {
            AppLog.trace("bots", "bot said \(item.profile): read failed, the next roster tries again")
            settleUnread(item.profile, rows: nil, news: nil, asked: asked, born: false)
            if botSaidDirty > 0, botSaidQueue.isEmpty, botSaidOut.isEmpty {
                botSaidDirty = 0
                persistState()
                rebuild()
            }
            return
        }
        // Words this device saw arrive after the read was asked for are newer than what it read: they stay, and the next
        // roster reads the chat (a read that crossed a reply put the reply before it back on the row).
        if let seen = device.botSaid?[item.profile], seen.mark == nil, seen.session == item.session,
           let asked, let seenAt = botSaidSeenAt[item.profile], seenAt > asked {
            AppLog.trace("bots", "bot said \(item.profile): read crossed a reply seen here, the reply stays")
            return
        }
        var entry = BotSaidEntry(session: item.session, at: item.at, text: text, mark: item.mark, rule: BotSaidRules.rule)
        // Nothing of the bot's to you in the tail (a run of scheduled reports, a talk between bots): the words already
        // known for this chat stay, unless an older build picked them (they may be that talk's last reply).
        let old = device.botSaid?[item.profile].flatMap { $0.session == item.session ? $0 : nil }
        if entry.text == nil, let old, old.rule == BotSaidRules.rule { entry.text = old.text }
        entry.newest = [HistoryPage.newestTimestamp(rows), old?.newest].compactMap { $0 }.max()
        let waited = device.unread.held(item.profile) != nil
        if let newest = entry.newest {
            chatActivityRead(item.profile, session: item.session, newest: newest, first: device.botSaid?[item.profile]?.newest == nil)
        }
        settleUnread(item.profile, rows: rows, news: news, asked: asked, born: !waited)   // [botunread]
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
