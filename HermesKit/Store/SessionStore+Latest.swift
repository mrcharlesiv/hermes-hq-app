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
    /// The row's `message_count` when read: `last_active` is Hermes's ~1-minute heartbeat, so a reply stored after
    /// the last heartbeat moves `message_count` without moving `recency`. Optional for older caches.
    var count: Int? = nil
    /// Render once on ingest, not on each rebuild of a potentially large list. Optional for old caches.
    var codingResult: String? = nil

    // Persist the source, not yesterday's display wording. Reopening an existing chat picks up copy changes.
    private enum CodingKeys: String, CodingKey { case at, text, role, count }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at); try c.encode(text, forKey: .text)
        try c.encodeIfPresent(role, forKey: .role); try c.encodeIfPresent(count, forKey: .count)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(at: try c.decode(Double.self, forKey: .at), text: try c.decode(String.self, forKey: .text),
                  role: try c.decodeIfPresent(String.self, forKey: .role),
                  count: try c.decodeIfPresent(Int.self, forKey: .count))
    }

    init(at: Double, text: String, role: String? = nil, count: Int? = nil) {
        self.at = at; self.text = text; self.role = role; self.count = count
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
    /// Coalescing delay before flushing a partial batch so fast answers don't wait on a slow sibling read.
    static let flushDelay: Duration = .milliseconds(120)

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
            if let kind = row["display_kind"]?.string, kind == "scheduled_wake" || kind == "loop_wakeup" { continue }
            // The words the chat shows: a compaction carrier's `content` is Hermes's whole summary.
            var raw = words(row["display_content"]?.string != nil ? row["display_content"] : row["content"])
            if role == "user", TimelineNotes.isTaskSnapshot(raw) || TimelineNotes.isScheduledWake(raw) { continue }
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
              !TimelineNotes.isTaskSnapshot(text), !TimelineNotes.isScheduledWake(text) else { return nil }
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
            let stale = latestStale.contains(key)
            let sameCount = cached?.count == nil || row.messageCount == nil || cached?.count == row.messageCount
            let current = !stale && cached?.at == row.recency && sameCount && cached?.role != nil
                && !TimelineNotes.isTaskSnapshot(cached?.text ?? "") && !TimelineNotes.isScheduledWake(cached?.text ?? "")
            if current || latestReads.contains(key) || latestQueue.contains(where: { $0.id == row.id && $0.profile == row.profile }) { continue }
            latestStale.remove(key)
            latestQueue.append(row)
            queued += 1
        }
        if queued > 0 { AppLog.trace("sessions", "latest preview: \(queued) rows queued of \(candidates.count) candidates") }
        pumpLatest()
    }

    /// A chat stopped running a turn (detected via live status or working ledger): re-read its tail now so the row
    /// doesn't revert from "Working…" to a pre-reply preview while waiting for the sidebar pass.
    func rereadLatest(for storedIds: Set<String>) {
        guard !stopped, timing.readsLatest, !storedIds.isEmpty else { return }
        var marked = false
        for row in recents + messaging + archivedRows where !SessionRules.isBotChat(row) {
            guard row.liveId(where: storedIds.contains) != nil else { continue }
            if row.id == seenSessionId { continue }
            latestStale.insert(Self.writeKey(id: row.id, profile: row.profile))
            marked = true
        }
        if marked { refreshLatest() }
    }

    /// A chat just seen or answered on this device: its row says so before the next read.
    func noteLatest(profile: String, sessionId: String, text: String, role: String? = nil) {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty, !Hydration.isSilentWords(line), !TimelineNotes.isTaskSnapshot(line), !TimelineNotes.isScheduledWake(line),
              let row = rowsById[sessionId], row.profile == profile else { return }
        let key = Self.writeKey(id: sessionId, profile: profile)
        let clipped = line.count > 200 ? String(line.prefix(200)) : line
        let update = SessionLatestMessage(at: row.recency, text: clipped, role: role, count: row.messageCount)
        guard device.latest[key] != update else { return }
        // The row's recency and count are the ones before this message: the next read that moves either confirms with the gateway.
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
        let message = SessionLatestMessage(at: row.recency, text: String(line.prefix(200)), role: "assistant", count: row.messageCount)
        guard device.latest[key] != message else { return }
        device.latest[key] = message
        confirmedReplyRecency[key] = row.recency
        persistState()
        rebuild()
    }

    @concurrent
    private static func fetchLatest(client: any GatewayClient, row: SidebarSessionRow) async -> SessionLatestMessage? {
        let query = [URLQueryItem(name: "profile", value: row.profile),
                     URLQueryItem(name: "limit", value: String(SessionLatestRules.tail)),
                     URLQueryItem(name: "order", value: "latest"),
                     URLQueryItem(name: "inline_images", value: "false")]
        let path = "/api/sessions/\(HistoryRequest.encodePathSegment(row.id))/messages"
        guard let data = try? await client.get(path, query), let root = try? JSONValue.parseFast(data),
              let found = SessionLatestRules.latestMessage(root["messages"]?.array ?? []) else { return nil }
        return SessionLatestMessage(at: row.recency, text: found.text, role: found.role, count: row.messageCount)
    }

    private func pumpLatest() {
        while latestReads.count < SessionLatestRules.parallel, !latestQueue.isEmpty {
            let row = latestQueue.removeFirst()
            let key = Self.writeKey(id: row.id, profile: row.profile)
            latestReads.insert(key)
            let client = self.client
            let previous = device.latest[key]
            Task { [weak self] in
                let message = await Self.fetchLatest(client: client, row: row)
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
        let rowMoved = current != nil && (current?.recency != row.recency || current?.messageCount != row.messageCount)
        let markedStale = latestStale.contains(key)
        let eligible = current != nil && !rowMoved && device.latest[key] == previous
        if eligible, let message, device.latest[key] != message {
            device.latest[key] = message
            confirmedReplyRecency[key] = nil
            latestDirty += 1
        } else if eligible && message == nil {
            AppLog.trace("sessions", "latest preview \(AppLog.tag(row.id)): no user/assistant tail, gateway preview stands")
        }
        // Re-queue after applying the result above so any newly pumped read captures the updated `previous`.
        if rowMoved || markedStale { refreshLatest() }
        // Batch quick simultaneous answers, but never hold finished rows hostage behind a slow sibling read.
        guard latestDirty > 0 else { return }
        flushLatest(immediate: latestDirty >= 6 || (latestQueue.isEmpty && latestReads.isEmpty))
    }

    private func flushLatest(immediate: Bool) {
        if immediate {
            latestFlushTask?.cancel()
            latestFlushTask = nil
            guard latestDirty > 0, !stopped else { return }
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
            return
        }
        guard latestFlushTask == nil else { return }
        latestFlushTask = Task { [weak self] in
            try? await Task.sleep(for: SessionLatestRules.flushDelay)
            guard let self, !Task.isCancelled else { return }
            self.latestFlushTask = nil
            self.flushLatest(immediate: true)
        }
    }
}
