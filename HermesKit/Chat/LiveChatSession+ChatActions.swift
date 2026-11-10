// The rest of the chat's actions (parity 240 §5, §8): Pin, Mark as Read/Unread, Archive and Delete
// (`PATCH`/`DELETE /api/sessions/<id>`, V:api/sessions.ts:374-411, 700-720), Branch in New Chat (`session.branch_stored`,
// `session.branch`, V:use-session-actions/index.ts:2524-2749), Export JSON (`getAllSessionMessages`, S:phone-chat-menu.tsx
// :236-245), and the rewinds — Regenerate, Edit and Rewind to Here — which are `prompt.submit` truncating before a stored
// user row (V:use-prompt-actions/rewind.ts:135-393). Files and Changes read the chat's folder over REST
// (ChatWorkspace.swift).

import Foundation

/// A rewind's send in flight: what it adds to `prompt.submit`, the transcript to put back if it is refused, and who
/// hears that it was.
struct RewindSend {
    var params: [String: JSONValue]
    var snapshot: [ChatMessage]
    var snapshotMeta: [String: MessageMeta]
    var onFailed: (String) -> Void
}

/// A new chat made by Branch: its stored id (the one to open) and the runtime id the gateway already bound.
nonisolated struct ChatBranchResult: Hashable, Sendable {
    var storedId: String
    var runtimeId: String?
}

/// What the chat screen's menus ask of a chat beyond Rename and Share.
protocol ChatSessionMoreActions: AnyObject {
    /// The chat's stored id once known (Pin, Archive, Delete and the lists address it).
    var actionsStoredId: String? { get }
    /// The chat's folder as the gateway last reported it (Files, Changes).
    var workingDirectory: String? { get }
    func setPinned(_ pinned: Bool) async throws
    func setUnread(_ unread: Bool) async throws
    func setArchived(_ archived: Bool) async throws
    func deleteChat() async throws
    func exportJSON() async throws -> (data: Data, fileName: String)
    /// A new chat from the whole chat (nil) or from the start through a message.
    func branch(fromMessage messageId: String?) async throws -> ChatBranchResult
    /// Sends the latest reply's prompt again in place of the reply. False when there is nothing to regenerate.
    @discardableResult func regenerate(onFailed: @escaping (String) -> Void) -> Bool
    /// Your message, sent again as `text` with everything from it on removed (Edit). False when it can't be addressed.
    @discardableResult func edit(_ messageId: String, to text: String, onFailed: @escaping (String) -> Void) -> Bool
    /// Everything after your message removed; it runs again from there (Rewind to Here).
    @discardableResult func rewind(to messageId: String, onFailed: @escaping (String) -> Void) -> Bool
    /// Your unconfirmed send, sent once more as a new message (its old bubble goes). Delete drops it from the screen.
    func sendAgain(_ messageId: String)
    func deleteUndelivered(_ messageId: String)
    /// Whether this message can be edited / rewound to: your stored text message (not a voice memo, nothing attached).
    func canRewind(_ messageId: String) -> Bool
    /// The REST reads behind Files and Changes, scoped to this chat's profile.
    var workspace: ChatWorkspace { get }
}

extension LiveChatSession: ChatSessionMoreActions {
    var actionsStoredId: String? { readSessionId }
    var workingDirectory: String? { menus.cwd }
    var workspace: ChatWorkspace { ChatWorkspace(client: client, profile: profileParam) }

    // MARK: Pin, unread, archive (PATCH /api/sessions/<id>)

    /// `PATCH /api/sessions/<stored id>` with `profile` in the query and the body (as Rename's REST path).
    func patchSession(_ fields: [String: JSONValue]) async throws {
        guard let stored = readSessionId else { throw MenusError.loading }
        do {
            try await SessionWrite.patch(client, id: stored, profile: profileParam, fields)
            AppLog.trace("chat", "chat \(AppLog.tag(stored)) changed: \(fields.map { "\($0.key)=\($0.value.bool.map { "\($0)" } ?? "…")" }.sorted().joined(separator: " "))")
        } catch {
            AppLog.note("chat", "chat \(AppLog.tag(stored)) change \(fields.keys.sorted().joined(separator: ",")) failed: \(LiveChatSession.logError(error))")
            throw error
        }
    }

    func setPinned(_ pinned: Bool) async throws { try await patchSession(["pinned": .bool(pinned)]) }
    func setUnread(_ unread: Bool) async throws { try await patchSession(["unread": .bool(unread)]) }
    func setArchived(_ archived: Bool) async throws { try await patchSession(["archived": .bool(archived)]) }

    // MARK: Delete (V:use-session-actions/index.ts:2901-3100)

    /// A running reply is stopped and the runtime closed first; then `DELETE /api/sessions/<id>?profile=<owner>` (the
    /// profile must be in the URL). The cached transcript goes too.
    func deleteChat() async throws {
        guard let stored = readSessionId else { throw MenusError.loading }
        if let rid = runtimeSessionId {
            var params: [String: JSONValue] = ["session_id": .string(rid)]
            if let profileParam { params["profile"] = .string(profileParam) }
            if turn.busy {
                do {
                    _ = try await client.call("session.interrupt", .object(params), timeout: .seconds(15))
                } catch let error as RPCError where error.code == 4001 || error.code == 4007 {
                    // The runtime is already gone: nothing left to stop.
                }
            }
            _ = try? await client.call("session.close", .object(params), timeout: .seconds(15))
        }
        do { try await SessionWrite.delete(client, id: stored, profile: profileParam) } catch {
            AppLog.note("chat", "delete chat \(AppLog.tag(stored)) failed: \(LiveChatSession.logError(error))")
            throw error
        }
        AppLog.trace("chat", "chat \(AppLog.tag(stored)) deleted (was busy=\(turn.busy)); cache dropped")
        cache.remove(account: account.id, profile: profile, storedId: stored)
        if let original = storedSessionId, original != stored { cache.remove(account: account.id, profile: profile, storedId: original) }
    }

    // MARK: Export JSON

    func exportJSON() async throws -> (data: Data, fileName: String) {
        guard let stored = readSessionId else { throw MenusError.loading }
        let rows = try await ChatTranscript.fetchAllRows(client: client, storedSessionId: stored, profile: profileParam)
        let data = try ChatExport.payload(sessionId: stored, title: title, messages: rows)
        return (data, ChatExport.fileName(sessionId: stored, title: title))
    }

    // MARK: Branch

    func branch(fromMessage messageId: String?) async throws -> ChatBranchResult {
        let result: JSONValue
        if let messageId {
            // From a message: `session.branch {session_id, count}` on the live runtime, never while a reply runs.
            guard !turn.busy else { throw MenusError("Stop the current reply before branching from it.") }
            guard let target = messages.first(where: { $0.id == messageId }) else { throw MenusError("This message isn't in the chat anymore.") }
            guard !target.isLocal || target.rowId != nil else { throw MenusError("This message isn't saved on your gateway yet.") }
            let whole: [ChatMessage]
            if !hasOlder && openPhase == .open {
                whole = messages
            } else {
                guard let stored = readSessionId else { throw MenusError.loading }
                whole = try await ChatTranscript.fetchAll(client: client, storedSessionId: stored, profile: profileParam)
            }
            let id = whole.contains(where: { $0.id == messageId }) ? messageId
                : target.rowId.flatMap { row in whole.last(where: { $0.rowId == row })?.id }
            guard let id, let count = RewindParams.branchCount(upTo: id, in: whole) else {
                throw MenusError("This message isn't saved on your gateway yet.")
            }
            result = try await sessionCall("session.branch", timeout: .seconds(60), runtime: .resumeFirst) { _ in
                ["count": .number(Double(count))]
            }
        } else {
            // The whole chat: `session.branch_stored` from the stored id; an older gateway without it gets
            // `session.create` with every message (V:use-session-actions/index.ts:2613-2630).
            guard let stored = readSessionId else { throw MenusError.loading }
            var params: [String: JSONValue] = ["cols": 96, "source": "desktop", "parent_session_id": .string(stored)]
            if let cwd = menus.cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
            if let profileParam { params["profile"] = .string(profileParam) }
            do {
                result = try await client.call("session.branch_stored", .object(params), timeout: .seconds(60))
            } catch let error as RPCError where error.code == -32601 || error.message.localizedCaseInsensitiveContains("method not found")
                || error.message.localizedCaseInsensitiveContains("unknown method") {
                let rows = try await ChatTranscript.fetchAll(client: client, storedSessionId: stored, profile: profileParam)
                let plain = rows.filter { $0.role == .user || $0.role == .assistant }.compactMap { m -> JSONValue? in
                    let text = ChatTranscript.blocks(m)
                    return text.isEmpty ? nil : .object(["role": .string(m.role == .user ? "user" : "assistant"), "content": .string(text)])
                }
                guard !plain.isEmpty else { throw MenusError("Nothing to branch — send a message first.") }
                params["messages"] = .array(plain)
                result = try await client.call("session.create", .object(params), timeout: .seconds(60))
            }
        }
        let runtime = result["session_id"]?.nonEmptyString
        guard let stored = result["stored_session_id"]?.nonEmptyString ?? runtime else {
            AppLog.note("chat", "branch of \(logIds): answer had no session id")
            throw MenusError("Hermes answered the branch in a shape this app doesn't read.")
        }
        AppLog.trace("chat", "branch of \(logIds) \(messageId == nil ? "(whole chat)" : "from \(AppLog.tag(messageId))"): new chat \(AppLog.tag(stored)) rt \(AppLog.tag(runtime))")
        return ChatBranchResult(storedId: stored, runtimeId: runtime)
    }

    // MARK: Rewinds (Regenerate, Edit, Rewind to Here)

    func canRewind(_ messageId: String) -> Bool {
        guard let index = indexById[messageId] else { return false }
        let m = messages[index]
        guard m.role == .user, !m.isPending, m.error == nil, let row = m.rowId, row > 0 else { return false }
        let text = ChatTranscript.messageText(m)
        if VoiceMemo.parse(text) != nil { return false }
        if let meta = metaById[m.id], !meta.attachments.isEmpty || !meta.attachmentRefs.isEmpty { return false }
        return !ChatText.trimmed(text).isEmpty
    }

    /// The prompt of the newest reply: the user turn at or before it (`planReload`, V:rewind.ts:481-517).
    func regenerate(onFailed: @escaping (String) -> Void) -> Bool {
        guard !turn.busy, let reply = messages.lastIndex(where: { $0.role == .assistant }),
              let prompt = messages[..<reply].lastIndex(where: { $0.role == .user }) else { return false }
        let id = messages[prompt].id
        guard canRewind(id) else { return false }
        return rewindSubmit(at: prompt, text: ChatTranscript.messageText(messages[prompt]), onFailed: onFailed)
    }

    func edit(_ messageId: String, to text: String, onFailed: @escaping (String) -> Void) -> Bool {
        guard canRewind(messageId), let index = indexById[messageId] else { return false }
        let typed = ChatText.trimmed(text)
        guard !typed.isEmpty else { return false }
        // Unchanged: nothing to send (`planEdit`).
        if typed == ChatText.trimmed(ChatTranscript.messageText(messages[index])) { return true }
        return rewindSubmit(at: index, text: typed, onFailed: onFailed)
    }

    func rewind(to messageId: String, onFailed: @escaping (String) -> Void) -> Bool {
        guard canRewind(messageId), let index = indexById[messageId] else { return false }
        return rewindSubmit(at: index, text: ChatTranscript.messageText(messages[index]), onFailed: onFailed)
    }

    /// Removes the user turn at `index` and everything after it, then sends `text` truncating before that turn's row.
    /// A running reply is stopped first (`interruptFirst`); the send waits out the stop as any send does.
    private func rewindSubmit(at index: Int, text: String, onFailed: @escaping (String) -> Void) -> Bool {
        guard let row = messages[index].rowId else { return false }
        flushDeltas()
        if turn.busy { stop() }
        let snapshot = messages
        let snapshotMeta = metaById
        let loaded = messages.compactMap { $0.rowId } + Array(loadedRowIds).sorted()
        let params = RewindParams.make(beforeRowId: row, loadedRowIds: loaded)
        let kept = Array(messages[..<index])
        messages = TranscriptMerge.diff(old: messages, new: kept, into: &changes)
        let keptIds = Set(kept.map(\.id))
        metaById = metaById.filter { keptIds.contains($0.key) }
        rebuildIndex()
        if let sid = turn.streamId, indexById[sid] == nil { turn.streamId = nil; turn.openPart = nil }
        let before = messages.last?.id
        AppLog.trace("send", "rewind in \(logIds): before row \(row), \(snapshot.count - index) messages taken off (kept \(index))")
        beginSend(text, queued: false)
        guard let sent = messages.last, sent.id != before, sent.role == .user else {
            AppLog.note("send", "rewind in \(logIds): the send didn't start; transcript stays cut until the next read")
            return false
        }
        menus.rewinds[sent.id] = RewindSend(params: params, snapshot: snapshot, snapshotMeta: snapshotMeta, onFailed: onFailed)
        return true
    }

    /// `prompt.submit`'s extra keys for a rewind's send (nil for an ordinary send).
    func rewindParams(for localId: String) -> [String: JSONValue]? { menus.rewinds[localId]?.params }

    /// The rewind was accepted: the kept rows' new ids replace the old ones (the next rewind must not name a dead row,
    /// 4018), and the chat is read whole again once the turn ends (its stored rows were rewritten).
    func rewindAcknowledged(localId: String, result: JSONValue) {
        guard menus.rewinds.removeValue(forKey: localId) != nil else { return }
        let map = RewindParams.survivorMap(result)
        AppLog.trace("send", "rewind \(AppLog.tag(localId)) accepted: \(map.count) kept rows renumbered; whole reload owed")
        if !map.isEmpty {
            for m in messages {
                guard let old = m.rowId, let mapped = map[old] else { continue }
                updateMessage(m.id) { $0.rowId = mapped }
            }
            loadedRowIds = Set(loadedRowIds.compactMap { map[$0] ?? $0 })
        }
        menus.wholeReloadOwed = true
    }

    /// The rewind's send was refused: the transcript as it was before, and the reason to whoever asked.
    /// True when `localId` was a rewind (the ordinary refusal — an error card, the words back — doesn't apply).
    func rewindRefused(localId: String, reason: String) -> Bool {
        guard let rewind = menus.rewinds.removeValue(forKey: localId) else { return false }
        AppLog.note("send", "rewind \(AppLog.tag(localId)) refused: transcript put back (\(rewind.snapshot.count) rows)")
        if turn.userAnchorId == localId { turn.userAnchorId = nil; turn.anchorPromptKey = nil }
        messages = TranscriptMerge.diff(old: messages, new: rewind.snapshot, into: &changes)
        metaById = rewind.snapshotMeta
        rebuildIndex()
        settleFlags()
        changes.markState()
        scheduleFlush()
        rewind.onFailed(reason.isEmpty ? "Hermes didn't accept the change." : reason)
        return true
    }

    /// The rewind's send was overtaken by Stop before it went out: nothing was cut on the gateway, so the messages it
    /// took off come back (`restore`), quietly — Stop was the person's own choice. With a newer send already shown
    /// (`restore` false) the snapshot would drop it: the chat is read whole after that turn instead.
    /// True when `localId` was a rewind (no draft comes back: the transcript shows the message as it was).
    func rewindWithdrawn(localId: String, restore: Bool) -> Bool {
        guard let rewind = menus.rewinds.removeValue(forKey: localId) else { return false }
        guard restore else {
            AppLog.note("send", "rewind \(AppLog.tag(localId)) stopped before sending, a newer send shown: whole reload owed")
            menus.wholeReloadOwed = true
            return true
        }
        AppLog.trace("send", "rewind \(AppLog.tag(localId)) stopped before sending: transcript put back (\(rewind.snapshot.count) rows)")
        messages = TranscriptMerge.diff(old: messages, new: rewind.snapshot, into: &changes)
        metaById = rewind.snapshotMeta
        rebuildIndex()
        if let sid = turn.streamId, indexById[sid] == nil { turn.streamId = nil; turn.openPart = nil }
        return true
    }

    /// A rewind left the stored rows rewritten: the next read replaces the transcript whole (a tail read would graft the
    /// re-inserted rows onto the old ones and show them twice).
    func reloadWholeIfOwed() async -> Bool {
        guard menus.wholeReloadOwed, let stored = readSessionId else { return false }
        menus.wholeReloadOwed = false
        let request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: 24)
        guard let (page, folded, _) = try? await HistoryAPI.fetchAndFold(client: client, request: request, features: perfFeatures, cut: true)
        else {
            AppLog.note("history", "whole reload after a rewind \(logIds) failed; still owed, no tail read this time")
            menus.wholeReloadOwed = true
            return true
        }
        AppLog.trace("history", "whole reload after a rewind \(logIds): \(page.rows.count) rows")
        applyFirstPage(page, folded)
        scheduleFlush()
        return true
    }

    // MARK: Send Again / Delete (an unconfirmed send)

    func sendAgain(_ messageId: String) {
        guard let index = indexById[messageId], messages[index].role == .user, messages[index].error != nil else { return }
        let text = ChatTranscript.messageText(messages[index])
        AppLog.trace("send", "send again \(AppLog.tag(messageId)) in \(logIds): unconfirmed bubble replaced by a new send")
        removeMessage(messageId)
        clearLostSend(messageId)                        // [sessions-m9]
        changes.markState()
        send(text)
        scheduleFlush()
    }

    func deleteUndelivered(_ messageId: String) {
        guard let index = indexById[messageId], messages[index].role == .user, messages[index].error != nil else { return }
        AppLog.trace("send", "unconfirmed send \(AppLog.tag(messageId)) deleted in \(logIds)")
        removeMessage(messageId)
        clearLostSend(messageId)                        // [sessions-m9]
        changes.markState()
        scheduleFlush()
    }
}
