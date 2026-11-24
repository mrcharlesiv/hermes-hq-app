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
    /// Absent in older caches and for local updates whose sender is not known.
    var role: String? = nil
    /// Render once on ingest, not on each rebuild of a potentially large list. Optional for old caches.
    var codingResult: String? = nil

    // Persist the source, not yesterday's display wording. Reopening an existing chat picks up copy changes.
    private enum CodingKeys: String, CodingKey { case at, text, role }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at); try c.encode(text, forKey: .text); try c.encodeIfPresent(role, forKey: .role)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(at: try c.decode(Double.self, forKey: .at), text: try c.decode(String.self, forKey: .text),
                  role: try c.decodeIfPresent(String.self, forKey: .role))
    }

    init(at: Double, text: String, role: String? = nil) {
        self.at = at; self.text = text; self.role = role
        self.codingResult = CodingSessionSubtitle.result(self)
    }
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
    static func latest(_ rows: [JSONValue]) -> String? { latestMessage(rows)?.text }

    /// The role travels with the cached message so a user's request is never mistaken for a confirmed reply.
    static func latestMessage(_ rows: [JSONValue]) -> (text: String, role: String)? {
        let ordered = rows.enumerated().sorted { a, b in
            let ia = HistoryPage.rowId(a.element), ib = HistoryPage.rowId(b.element)
            if let ia, let ib, ia != ib { return ia > ib }
            return a.offset > b.offset
        }.map(\.element)
        for row in ordered {
            guard let role = row["role"]?.string, role == "user" || role == "assistant" else { continue }
            // The words the chat shows: a compaction carrier's `content` is Hermes's whole summary.
            var raw = words(row["display_content"]?.string != nil ? row["display_content"] : row["content"])
            if role == "user", TimelineNotes.isTaskSnapshot(raw) { continue }
            // [restated] Your request restated after a compaction repeats one already in the chat.
            if role == "user", let restated = TimelineNotes.restatedRequest(raw) { raw = restated.before }
            if role == "user", raw.contains("(Task id "), let asked = TodoWords.askShown(raw) { raw = asked }   // [tasks]
            let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if role == "user", VoiceChatRecord.isRecord(raw) { continue }   // [voice record] its line is not a message to preview
            if text.isEmpty || (role == "assistant" && Hydration.isSilentWords(text)) { continue }
            return (text.count > 200 ? String(text.prefix(200)) : text, role)
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
        guard let text = device.latest[Self.writeKey(id: row.id, profile: row.profile)]?.text,
              !TimelineNotes.isTaskSnapshot(text) else { return nil }
        return text
    }

    /// Read the newest message of each shown chat whose activity moved since it was last read.
    /// When viewing a single project page, prioritize that project's live and archived (Done) chats so older coding
    /// rows and Done rows don't fall outside the global top-60 window and drop to "No recent update".
    func refreshLatest() {
        guard !stopped, timing.readsLatest else { return }
        let livePool = (recents + messaging).filter { ($0.messageCount ?? 1) > 0 && !SessionRules.isBotChat($0) }
            .sorted { $0.recency > $1.recency }
        let archivedPool = archivedRows.filter { ($0.messageCount ?? 1) > 0 && !SessionRules.isBotChat($0) }
            .sorted { $0.recency > $1.recency }
        var candidates: [SidebarSessionRow] = []
        var pickedKeys = Set<String>()
        func add(_ rows: some Sequence<SidebarSessionRow>, cap: Int) {
            var added = 0
            for row in rows where added < cap {
                let key = Self.writeKey(id: row.id, profile: row.profile)
                if pickedKeys.insert(key).inserted {
                    candidates.append(row)
                    added += 1
                }
            }
        }
        if view.projectFilter.count == 1, let projectKey = view.projectFilter.first {
            let projectLive = livePool.filter { projectKeyFor(cwd: $0.cwd, profile: $0.profile) == projectKey }
            let projectArchived = archivedPool.filter { projectKeyFor(cwd: $0.cwd, profile: $0.profile) == projectKey }
            add(projectLive, cap: SessionLatestRules.window)
            add(projectArchived, cap: SessionLatestRules.window)
        }
        add(livePool, cap: SessionLatestRules.window)
        if view.showArchived {
            add(archivedPool, cap: SessionLatestRules.window)
        }
        var queued = 0
        for row in candidates {
            let key = Self.writeKey(id: row.id, profile: row.profile)
            let cached = device.latest[key]
            let current = cached?.at == row.recency && cached?.role != nil && !TimelineNotes.isTaskSnapshot(cached?.text ?? "")
            if current || latestReads.contains(key) || latestQueue.contains(where: { $0.id == row.id && $0.profile == row.profile }) { continue }
            latestQueue.append(row)
            queued += 1
        }
        if queued > 0 { AppLog.trace("sessions", "latest preview: \(queued) rows queued of \(candidates.count) candidates") }
        pumpLatest()
    }

    /// A chat just seen or answered on this device: its row says so before the next read.
    func noteLatest(profile: String, sessionId: String, text: String, role: String? = nil) {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty, line != "[SILENT]", let row = rowsById[sessionId], row.profile == profile else { return }
        let key = Self.writeKey(id: sessionId, profile: profile)
        let update = SessionLatestMessage(at: row.recency, text: line, role: role)
        guard device.latest[key] != update else { return }
        // The row's recency is the one before this message: the next read that moves it reads the gateway's own.
        device.latest[key] = update
        AppLog.trace("sessions", "latest preview \(AppLog.tag(sessionId)): set from this device's own send/reply")
        persistState()
        rebuild()
    }

    /// Record a completed reply only when the event was tied to this exact stored session.
    func noteConfirmedReply(profile: String, sessionId: String, text: String) {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty, !Hydration.isSilentWords(line),
              let row = (recents + cron + messaging + archivedRows).first(where: { $0.id == sessionId && $0.profile == profile }) else { return }
        let key = Self.writeKey(id: sessionId, profile: profile)
        let message = SessionLatestMessage(at: row.recency, text: String(line.prefix(200)), role: "assistant")
        guard device.latest[key] != message else { return }
        device.latest[key] = message
        confirmedReplyRecency[key] = row.recency
        persistState()
        rebuild()
    }

    private func pumpLatest() {
        while latestReads.count < SessionLatestRules.parallel, !latestQueue.isEmpty {
            let row = latestQueue.removeFirst()
            let key = Self.writeKey(id: row.id, profile: row.profile)
            latestReads.insert(key)
            let client = self.client
            let previous = device.latest[key]
            Task { [weak self] in
                let query = [URLQueryItem(name: "profile", value: row.profile),
                             URLQueryItem(name: "limit", value: String(SessionLatestRules.tail)),
                             URLQueryItem(name: "order", value: "latest")]
                let path = "/api/sessions/\(HistoryRequest.encodePathSegment(row.id))/messages"
                let message: SessionLatestMessage? = await {
                    guard let data = try? await client.get(path, query), let root = try? JSONValue.parse(data),
                          let found = SessionLatestRules.latestMessage(root["messages"]?.array ?? []) else { return nil }
                    return SessionLatestMessage(at: row.recency, text: found.text, role: found.role)
                }()
                self?.latestRead(key, row: row, message: message, previous: previous)
            }
        }
    }

    private func latestRead(_ key: String, row: SidebarSessionRow, message: SessionLatestMessage?, previous: SessionLatestMessage?) {
        latestReads.remove(key)
        defer { pumpLatest() }
        guard !stopped else { return }
        // A newer list page or local update wins over a slow history response.
        let current = (recents + cron + messaging + archivedRows).first { $0.id == row.id && $0.profile == row.profile }
        let eligible = current?.recency == row.recency && device.latest[key] == previous
        if current != nil, current?.recency != row.recency { refreshLatest() }
        if eligible, let message, device.latest[key] != message {
            device.latest[key] = message
            confirmedReplyRecency[key] = nil
            latestDirty += 1
        } else if eligible && message == nil {
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
