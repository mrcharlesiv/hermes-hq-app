// [threads] A thread runs with no screen of its own: the bot chat it hangs in draws it (docs/spec/3x-threads.md §4).

import Foundation

extension LiveChatSession {
    /// Opens the chat (or keeps it open) and hears the gateway without a screen. It is never the app's focused chat
    /// (`observing` stays false: nothing is marked read or seen for it), and the app model holds it like a chat still
    /// sending its queue, so opening it from anywhere gives this same chat.
    func listenOffScreen() {
        threadHold = true
        // On a screen already: `stopObserving` keeps it listening for as long as the hold stands.
        guard !observing else { return }
        if !drainingAway {
            drainingAway = true
            ticker.revive()
            if eventTask == nil { subscribe() }
            onDrainingAwayChange?(true)
        }
        if !started { beginOpen(failedOpen: false) }
    }

    /// The hold ends: off screen it stops listening once its reply has ended (`endAwayDrainIfDone`).
    func endThreadHold() { threadHold = false }

    /// Whether this chat can host side threads (bot chats and regular sessions; never threads themselves or hidden
    /// task/goal/tile chats).
    var supportsThreads: Bool { !menus.isThread && onBusyThreadSend != nil }

    /// Opts this chat out of hosting threads (called for threads themselves and hidden task/goal/tile chats).
    func disableThreads() {
        onBusyThread = nil
        onBusyThreadSend = nil
        shouldRouteToBusyThread = nil
        consumeThreadContextNote = nil
        restoreThreadContextNote = nil
        onMainReplyLanded = nil
    }

    /// §9: routes a send to the app's thread handler (rich `onBusyThreadSend` first, legacy `onBusyThread` fallback).
    func deliverToBusyThread(_ payload: BusyThreadPayload) -> Bool {
        if let rich = onBusyThreadSend { return rich(payload) }
        guard payload.attachments.isEmpty, payload.display == nil, let legacy = onBusyThread else { return false }
        return legacy(payload.text, payload.localId ?? "")
    }

    /// §9: a send this chat could not take went on in a thread. Its bubble leaves this chat (the thread draws it),
    /// with no "Couldn’t Send" card and nothing handed back. Burst messages typed while it waited drain into the same
    /// thread in order; only non-threadable items (memos, hidden continuations) stay parked.
    func sendWentToThread(_ localId: String, reason: OwnerWait? = nil) {
        AppLog.note("send", "send \(AppLog.tag(localId)) went on in a thread: \(logIds) could not take it now")
        removeMessage(localId)
        if turn.userAnchorId == localId { turn.userAnchorId = nil; turn.anchorPromptKey = nil }
        if turn.preparingSendId == localId { turn.preparingSendId = nil }
        // Drain burst messages queued behind this send during its brief wait straight into the same thread.
        if !isQueueParked, !queuedMessages.isEmpty {
            var remaining: [QueuedMessage] = []
            for item in queuedMessages {
                let canDrain = !item.hidden && item.memo == nil && !VoiceChatRecord.isRecord(item.text)
                if canDrain, deliverToBusyThread(BusyThreadPayload(text: item.text, display: item.display,
                                                                   attachments: item.attachments, localId: nil,
                                                                   reason: reason, proactive: true)) {
                    AppLog.note("send", "burst queued \(AppLog.tag(item.id)) drained into the same busy thread")
                } else {
                    remaining.append(item)
                }
            }
            queuedMessages = remaining
        }
        parkQueue()
        settleFlags()
        changes.markState()
        scheduleFlush()
        onNotice?(ThreadRules.busyNotice)
    }

    /// §9: the thread could not send those words either (the gateway took no new chat, the link went): they come back
    /// to this chat's message box with the reason, as a send refused here does.
    func threadSendCameBack(_ text: String, reason: String) {
        AppLog.note("send", "a thread's send came back to \(logIds): \(AppLog.scrub(String(reason.prefix(100))))")
        sendFailure = SendFailure.make(reason: reason)
        changes.markState()
        scheduleFlush()
        returnWordsToDraft(text)
        onDraftReturned?(text, reason.isEmpty ? "Your message wasn’t sent." : reason)
    }

    /// §9: lightweight probe while an auto-thread is latched on screen and `externalWorking` is false.
    /// Always checks for newly persisted rows (1-row probe-first refresh, which fires `onMainReplyLanded` if a job
    /// finished writing its reply). When `checkServerRunning` is true (latched due to a `4009` server-busy lock rather
    /// than an external CLI `4090` lease), also checks `session.resume(omit_messages: true)` and `session.active_list`,
    /// returning `true` once `hermes serve` confirms this session is idle.
    func probeMainAvailability(checkServerRunning: Bool) async -> Bool {
        guard observing, openSettled, !turn.busy else { return false }
        startRefresh(force: false)
        await refreshTask?.value
        guard checkServerRunning, observing, !turn.busy, let sid = readSessionId else { return false }
        var params: [String: JSONValue] = ["session_id": .string(sid), "omit_messages": true]
        if let profile = profileParam { params["profile"] = .string(profile) }
        guard let resumed = try? await client.call("session.resume", .object(params), timeout: .seconds(10)) else { return false }
        if resumed["running"]?.bool == true { return false }
        if let inflight = resumed["inflight"], !inflight.isNull, inflight["status"]?.string != "error" { return false }
        if let active = try? await client.call("session.active_list", .object([:]), timeout: .seconds(10)) {
            let ids = Set([sid, runtimeSessionId, storedSessionId, resolvedStoredId].compactMap { $0 })
            let busy = (active["sessions"]?.array ?? []).contains { row in
                let matches = [row["id"]?.string, row["session_id"]?.string, row["session_key"]?.string]
                    .compactMap { $0 }.contains { ids.contains($0) }
                guard matches else { return false }
                let status = (row["status"]?.string ?? "").lowercased()
                return status == "running" || status == "waiting" || row["running"]?.bool == true
            }
            if busy { return false }
        }
        return true
    }

    /// Why the chat could not open or send, in words for the thread's line; nil while all is well.
    var threadProblem: String? {
        if case .failed(let reason) = openPhase { return reason }
        return messages.last(where: { $0.role == .user })?.error
    }
}
