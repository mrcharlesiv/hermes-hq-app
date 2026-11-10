// The Sessions row's second line shows the chat's newest message. The sidebar's `preview` is the head of the FIRST
// user message (Hermes `_sql_preview_raw`, kept for untitled chats' titles), so each chat whose activity moved has its
// newest user/assistant message read from the tail of `/api/sessions/{id}/messages` (a few at a time, newest rows
// first) and kept on the device until its activity moves again. The Bots list reads its bots' own words the same way
// (`BotStore+BotSaid.swift`).

import Foundation

nonisolated struct SessionLatestMessage: Codable, Sendable, Hashable {
    /// The row's `recency` when this was read: a row whose activity moved since is read again.
    var at: Double
    var text: String
}

nonisolated enum SessionLatestRules {
    /// Rows read per pass, newest first (the rest keep the gateway's preview until they rise).
    static let window = 60
    /// Reads in the air at once.
    static let parallel = 3
    /// Messages kept on the device.
    static let keep = 400
    /// Rows asked for: enough to step past tool turns and an exact `[SILENT]` reply.
    static let tail = 8

    /// The newest user/assistant message with words, skipping an exact `[SILENT]` reply; nil when there is none.
    static func latest(_ rows: [JSONValue]) -> String? {
        let ordered = rows.enumerated().sorted { a, b in
            let ia = HistoryPage.rowId(a.element), ib = HistoryPage.rowId(b.element)
            if let ia, let ib, ia != ib { return ia > ib }
            return a.offset > b.offset
        }.map(\.element)
        for row in ordered {
            guard let role = row["role"]?.string, role == "user" || role == "assistant" else { continue }
            // The words the chat shows: a compaction carrier's `content` is Hermes's whole summary.
            var raw = words(row["display_content"]?.string != nil ? row["display_content"] : row["content"])
            // [restated] Your request restated after a compaction repeats one already in the chat.
            if role == "user", let restated = TimelineNotes.restatedRequest(raw) { raw = restated.before }
            if role == "user", raw.contains("(Task id "), let asked = TodoWords.askShown(raw) { raw = asked }   // [tasks]
            let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if text.isEmpty || (role == "assistant" && Hydration.isSilentWords(text)) { continue }
            return text.count > 200 ? String(text.prefix(200)) : text
        }
        return nil
    }

    static func words(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.string { return text }
        return (content.array ?? []).compactMap { $0.string ?? $0["text"]?.string }.joined(separator: " ")
    }
}

extension SessionStore {
    /// The newest message to show for `row`, else nil (the gateway's preview stands).
    func latestText(_ row: SidebarSessionRow) -> String? {
        device.latest[Self.writeKey(id: row.id, profile: row.profile)]?.text
    }

    /// Read the newest message of each shown chat whose activity moved since it was last read.
    func refreshLatest() {
        guard !stopped, timing.readsLatest else { return }
        let rows = (recents + messaging).filter { ($0.messageCount ?? 1) > 0 && !SessionRules.isBotChat($0) }
            .sorted { $0.recency > $1.recency }.prefix(SessionLatestRules.window)
        // Show › Archived lists the archived chats beside the live ones: theirs show the newest message too (read once,
        // an archived chat doesn't move).
        let archived = view.showArchived
            ? archivedRows.filter { ($0.messageCount ?? 1) > 0 && !SessionRules.isBotChat($0) }
                .sorted { $0.recency > $1.recency }.prefix(SessionLatestRules.window)
            : []
        var queued = 0
        for row in Array(rows) + Array(archived) {
            let key = Self.writeKey(id: row.id, profile: row.profile)
            if device.latest[key]?.at == row.recency || latestReads.contains(key) || latestQueue.contains(where: { $0.id == row.id && $0.profile == row.profile }) { continue }
            latestQueue.append(row)
            queued += 1
        }
        if queued > 0 { AppLog.trace("sessions", "latest preview: \(queued) rows queued of \(rows.count + archived.count) candidates") }
        pumpLatest()
    }

    /// A chat just seen or answered on this device: its row says so before the next read.
    func noteLatest(profile: String, sessionId: String, text: String) {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty, line != "[SILENT]", let row = rowsById[sessionId], row.profile == profile else { return }
        let key = Self.writeKey(id: sessionId, profile: profile)
        guard device.latest[key]?.text != line else { return }
        // The row's recency is the one before this message: the next read that moves it reads the gateway's own.
        device.latest[key] = SessionLatestMessage(at: row.recency, text: line)
        AppLog.trace("sessions", "latest preview \(AppLog.tag(sessionId)): set from this device's own send/reply")
        persistState()
        rebuild()
    }

    private func pumpLatest() {
        while latestReads.count < SessionLatestRules.parallel, !latestQueue.isEmpty {
            let row = latestQueue.removeFirst()
            let key = Self.writeKey(id: row.id, profile: row.profile)
            latestReads.insert(key)
            let client = self.client
            Task { [weak self] in
                let query = [URLQueryItem(name: "profile", value: row.profile),
                             URLQueryItem(name: "limit", value: String(SessionLatestRules.tail)),
                             URLQueryItem(name: "order", value: "latest")]
                let path = "/api/sessions/\(HistoryRequest.encodePathSegment(row.id))/messages"
                let text: String? = await {
                    guard let data = try? await client.get(path, query), let root = try? JSONValue.parse(data) else { return nil }
                    return SessionLatestRules.latest(root["messages"]?.array ?? [])
                }()
                self?.latestRead(key, row: row, text: text)
            }
        }
    }

    private func latestRead(_ key: String, row: SidebarSessionRow, text: String?) {
        latestReads.remove(key)
        defer { pumpLatest() }
        guard !stopped else { return }
        if let text, device.latest[key] != SessionLatestMessage(at: row.recency, text: text) {
            device.latest[key] = SessionLatestMessage(at: row.recency, text: text)
            latestDirty += 1
        } else if text == nil {
            AppLog.trace("sessions", "latest preview \(AppLog.tag(row.id)): no user/assistant tail, gateway preview stands")
        }
        // One rebuild and one write per few answers, not one per answer.
        guard latestDirty > 0, latestDirty >= 6 || (latestQueue.isEmpty && latestReads.isEmpty) else { return }
        let dirty = latestDirty
        latestDirty = 0
        if device.latest.count > SessionLatestRules.keep {
            let before = device.latest.count
            let known = Set((recents + cron + messaging + archivedRows).map { Self.writeKey(id: $0.id, profile: $0.profile) })
            device.latest = device.latest.filter { known.contains($0.key) }
            AppLog.trace("sessions", "latest preview cache trimmed \(before) -> \(device.latest.count)")
        }
        AppLog.trace("sessions", "latest preview: \(dirty) rows updated, written")
        persistState()
        rebuild()
    }
}
