// [botsaid] What a Bots row previews is decided by the chat's own rows, not by a second set of rules. The row used to
// take the newest assistant message that wasn't a job's report or a delivery; the chat meanwhile learned to fold a
// reply written to another bot into its "With Otto · 4 messages" line (`UpdateGroups`), and the row never did
// (owner, 2026-11-12: a bot's answer to another bot's request sat on the Bots page while its chat showed it folded:
// "this bug we cannot squash"). The tail read for the row is now built the way the chat
// builds it (`Hydration.fold`, the delivery resolvers, `ChatRowBuilder`'s rows), and the preview is the newest reply
// the chat's own rule leaves a bubble (`UpdateGroups.Rows.interim`). Whatever the chat folds, hides or draws as a
// note can't be a preview, now or after the next folding rule.

import Foundation

nonisolated extension BotSaidRules {
    struct Shown: Equatable, Sendable {
        /// The newest reply the chat draws as the bot's bubble, on one line; nil when the messages hold none.
        var text: String?
        /// Something other than the bot's own turns came before that reply in these messages, so what it answers was
        /// read with it. False for a reply whose turn began before the first of them (a long turn in a short tail):
        /// whether it was written to another bot can't be told yet.
        var settled: Bool
    }

    /// The bot's newest words to you among `raw` (oldest first), as its chat draws them.
    static func shown(_ raw: [ChatMessage], own: DeliveryMessages.Seat, seats: [DeliveryMessages.Seat]) -> Shown {
        let (messages, rows) = chatRows(raw, own: own, seats: seats)
        for at in messages.indices.reversed() where messages[at].role == .assistant {
            for (r, row) in rows.at(at).enumerated().reversed() {
                guard UpdateGroups.isBotsReply(row), case .bubble(let bubble) = row.kind, isOwnWords(bubble.text),
                      !rows.interim(UpdateGroups.Member(message: at, row: r)) else { continue }
                let line = bubble.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return Shown(text: line.count > 200 ? String(line.prefix(200)) : line,
                             settled: messages[..<at].contains { $0.role != .assistant })
            }
        }
        return Shown(text: nil, settled: false)
    }

    /// The same for a tail of stored rows, in any order.
    static func shown(rows: [JSONValue], own: DeliveryMessages.Seat, seats: [DeliveryMessages.Seat]) -> Shown {
        let ordered = rows.enumerated().sorted { a, b in
            let ia = HistoryPage.rowId(a.element), ib = HistoryPage.rowId(b.element)
            if let ia, let ib, ia != ib { return ia < ib }
            return a.offset < b.offset
        }.map(\.element)
        return shown(Hydration.fold(ordered).messages, own: own, seats: seats)
    }

    /// The messages as the bot's chat draws them, and the chat's own word on each of their rows.
    private static func chatRows(_ raw: [ChatMessage], own: DeliveryMessages.Seat,
                                 seats: [DeliveryMessages.Seat]) -> (messages: [ChatMessage], rows: UpdateGroups.Rows) {
        var messages = DeliveryMessages.resolve(raw, roster: seats).messages
        messages = BotDMs.resolve(messages, roster: seats).messages
        messages = CronDeliveries.resolve(messages, roster: seats, own: own).messages
        messages = TurnErrors.withoutDuplicateTurnErrors(TimelineNotes.resolve(messages))
        var input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: own.name, expanded: [], scope: "botsaid")
        input.bots = seats
        input.ownFace = ChatSender(key: own.profile, name: input.speakerName, head: own.head, profile: own.profile, colorHex: nil)
        input.activity.style = .bottom   // whatever Tool Call Style is set: the row doesn't change with it
        // The chat's own word on each reply: one inside a talk with another bot, or written to one, folds (`interim`).
        return (messages, UpdateGroups.Rows(input))
    }

    // MARK: [botunread] Is anything new in the chat for you?

    /// A stored tail (any order) holds something for you newer than `since` (gateway seconds): a reply the chat draws
    /// as the bot's bubble, your own message from another device, a job's report, a helper's result, a question or an
    /// error. Another bot's message, this bot's messages to it, a reply the chat folds into their talk and the work
    /// lines around them are not: a chat that only moved because two bots talked earns no unread dot (a tester,
    /// 2026-11-14). True whenever it can't be told (no times on the rows, or every row read is newer than `since`
    /// and there may be more behind them): a dot too many beats a missed reply.
    static func newsForYou(rows: [JSONValue], since: Double, own: DeliveryMessages.Seat, seats: [DeliveryMessages.Seat],
                           whole: Bool = false) -> Bool {
        let ordered = rows.enumerated().sorted { a, b in
            let ia = HistoryPage.rowId(a.element), ib = HistoryPage.rowId(b.element)
            if let ia, let ib, ia != ib { return ia < ib }
            return a.offset < b.offset
        }.map(\.element)
        let timed = ordered.compactMap { row -> (id: Int?, at: Double)? in
            guard let at = row["timestamp"]?.double, at.isFinite, at > 0 else { return nil }
            return (HistoryPage.rowId(row), at)
        }
        guard !timed.isEmpty else { return !ordered.isEmpty }
        guard timed.contains(where: { $0.at > since }) else { return false }
        // Every row is new: older new ones may sit behind this tail, unless it is the whole chat.
        if !whole, !timed.contains(where: { $0.at <= since }) { return true }
        // A message is as new as the newest stored row folded into it (its own time is its first row's).
        let page = Hydration.fold(ordered)
        var fresh = Set<String>()
        for message in page.messages {
            let meta = page.meta[message.id]
            guard let first = meta?.firstRowId ?? message.rowId else { continue }
            let last = max(first, meta?.lastRowId ?? message.rowId ?? first)
            if timed.contains(where: { row in row.id.map { first...last ~= $0 } ?? false && row.at > since }) { fresh.insert(message.id) }
        }
        let (messages, drawn) = chatRows(page.messages, own: own, seats: seats)
        var carried = false     // a message with no stored row of its own (a resolver's) is as new as the one before it
        for at in messages.indices {
            let message = messages[at]
            if message.rowId != nil || page.meta[message.id]?.firstRowId != nil { carried = fresh.contains(message.id) }
            guard carried else { continue }
            for (r, row) in drawn.at(at).enumerated() where isForYou(row, UpdateGroups.Member(message: at, row: r), in: drawn) {
                return true
            }
        }
        return false
    }

    /// One drawn row is something you'd open the chat for.
    private static func isForYou(_ row: ChatRow, _ member: UpdateGroups.Member, in rows: UpdateGroups.Rows) -> Bool {
        switch row.kind {
        case .bubble(let bubble):
            // The bot's reply, unless the chat folds it into a talk with another bot; yours and anyone else's count.
            if UpdateGroups.isBotsReply(row) { return !rows.interim(member) && !bubble.text.isEmpty }
            return true
        case .backgroundResult:
            return !UpdateGroups.isBotTalk(row)          // "From Otto" / "To Otto" are the bots' own business
        case .error, .prompt, .slashOutput:
            return true
        case .toolRun, .thought, .day, .notice, .updateMember, .caption, .stoppedEarly, .waiting, .sendState, .actions,
             .activity, .reactions:
            return false
        }
    }
}
