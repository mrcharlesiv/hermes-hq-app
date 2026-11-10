// The live chat's side of the activity stream (docs/spec/1x-activity.md §3.4): its binding in the ActivityStore, the
// measured reasoning time (§9.2), the In Header live step (§10.4), the fallback-model notice (§8.3) and hidden goal
// continuations (§6.4). `LiveChatSession` holds one `ActivityLink`; the hooks it calls are marked `[activity]`.

import Foundation

/// Everything the activity stream keeps per live chat (one stored property of `LiveChatSession`).
final class ActivityLink {
    /// Set by the app model when it builds the chat.
    weak var store: ActivityStore?
    fileprivate var observation: ActivityObservation?
    fileprivate var boundRid: String?
    fileprivate var onChange: (() -> Void)?
    fileprivate var mirroredInterrupted = false
    fileprivate var visible = false
    /// The child whose detail the screen has open (its tail is read; kept across a rebind).
    fileprivate var openSubagent: String?
    /// Reasoning part start / end times by message id and part index (§9.2). Memory only.
    fileprivate var starts: [String: [Int: Date]] = [:]
    fileprivate var ends: [String: [Int: Date]] = [:]
    fileprivate var tracked: Set<String> = []
    fileprivate var displayFlags = DisplayFlags()
    /// Seconds-since-1970 of notices already added (one row per fallback).
    fileprivate var noticeKeys: Set<String> = []
    /// The newest message when a hidden goal continuation went out: nothing up to it belongs to that turn (it has no
    /// prompt row of its own), so the previous reply never counts as working again (§10.5).
    fileprivate(set) var hiddenTurnAnchor: String?
    /// Replies whose hidden steps were brought back (Show Steps), kept while the app runs (§10.5) — not with the screen.
    var revealedSteps: Set<String> = []
    /// Tests: the clock the reasoning timer reads.
    var clock: () -> Date = { Date() }

    init() {}
}

extension LiveChatSession: ChatActivityProviding {
    var activity: ChatActivity {
        guard let store = activityLink.store else { return ChatActivity() }
        if let rid = activityLink.boundRid { return store.activity(rid) }
        // Not bound yet (the open's resume is out): an earlier open's state, so the shelf is drawn from the first frame.
        return store.activity(storedIds: [resolvedStoredId, storedSessionId].compactMap { $0 }, profile: profile)
    }

    var onActivityChange: (() -> Void)? {
        get { activityLink.onChange }
        set { activityLink.onChange = newValue }
    }

    var activityStore: ActivityStore? { activityLink.store }
    var activityRuntimeId: String? { activityLink.boundRid }
    var providerWait: String? { turn.providerWait }
    var displayFlags: DisplayFlags { activityLink.displayFlags }

    func reasoningSeconds(messageId: String) -> [Int: Double] {
        guard let starts = activityLink.starts[messageId], let ends = activityLink.ends[messageId] else { return [:] }
        var out: [Int: Double] = [:]
        for (index, start) in starts {
            if let end = ends[index] { out[index] = max(0, end.timeIntervalSince(start)).rounded(.down) }
        }
        return out
    }

    func setActivityVisible(_ visible: Bool, openSubagent: String?) {
        let appearing = visible && !activityLink.visible
        activityLink.visible = visible
        activityLink.openSubagent = visible ? openSubagent : nil
        if visible {
            activityLink.store?.setVisible(runtimeId: activityLink.boundRid, openSubagent: openSubagent)
            if appearing { refreshDisplayFlags() }
        } else if let store = activityLink.store, store.visibleRuntimeId == activityLink.boundRid {
            // Only this chat's own claim: a chat that already took the screen (a push over this one, a route that
            // added it before this one left) keeps its polls.
            store.setVisible(runtimeId: nil, openSubagent: nil)
        }
    }

    var hiddenTurnAnchor: String? { activityLink.hiddenTurnAnchor }

    var revealedSteps: Set<String> {
        get { activityLink.revealedSteps }
        set { activityLink.revealedSteps = newValue }
    }

    private func refreshDisplayFlags() {
        guard let store = activityLink.store else { return }
        let cached = store.display.flags(profile: profile)
        if cached != activityLink.displayFlags {
            activityLink.displayFlags = cached
            activityLink.onChange?()
        }
        store.display.refresh(profile: profile) { [weak self] flags in
            guard let self, flags != self.activityLink.displayFlags else { return }
            self.activityLink.displayFlags = flags
            self.activityLink.onChange?()
        }
    }

    // MARK: Binding

    /// `bindRuntime` (a resume or an activate that minted a new runtime id).
    func activityBound(_ result: JSONValue) {
        guard let rid = result["session_id"]?.nonEmptyString else { return }
        activityBound(result, runtimeId: rid)
    }

    /// The chat is bound on this socket as `rid` (also after a reconnect's activate kept the same id).
    func activityBound(_ result: JSONValue, runtimeId rid: String) {
        guard let store = activityLink.store else { return }
        store.bind(runtimeId: rid, profile: profile, storedId: resolvedStoredId ?? storedSessionId)
        store.applyResume(result, runtimeId: rid)
        if activityLink.boundRid != rid {
            activityLink.boundRid = rid
            activityLink.observation = store.observe(rid) { [weak self] in self?.activityLink.onChange?() }
            if activityLink.visible { store.setVisible(runtimeId: rid, openSubagent: activityLink.openSubagent) }
            activityLink.onChange?()
        }
        if turn.interrupted { store.setInterrupted(runtimeId: rid, true) }
    }

    /// Stop: the children and task lists go at once, and late frames of the stopped turn are dropped.
    func activityStopPressed() {
        activityLink.mirroredInterrupted = true
        guard let rid = activityLink.boundRid ?? runtimeSessionId else { return }
        activityLink.store?.stopped(runtimeId: rid)
    }

    /// Once per delivered frame: mirror the end of a Stop to the store, and time the reasoning parts.
    func activityFrame() {
        if activityLink.mirroredInterrupted != turn.interrupted {
            activityLink.mirroredInterrupted = turn.interrupted
            if let rid = activityLink.boundRid { activityLink.store?.setInterrupted(runtimeId: rid, turn.interrupted) }
        }
        noteReasoningTimes()
    }

    // MARK: Reasoning timing (§9.2)

    /// A reasoning part starts when it is first drawn and ends when a later part opens or the reply stops streaming.
    func noteReasoningTimes() {
        let link = activityLink
        if let sid = turn.streamId { link.tracked.insert(sid) }
        guard !link.tracked.isEmpty else { return }
        let now = link.clock()
        for id in link.tracked {
            guard let index = indexById[id] else { link.tracked.remove(id); continue }
            let m = messages[index]
            let lastVisible = m.parts.lastIndex { part in
                switch part {
                case .text(let t), .reasoning(let t): return !ChatText.trimmed(t).isEmpty
                case .tool: return true
                }
            } ?? -1
            for (i, part) in m.parts.enumerated() {
                guard case .reasoning(let text) = part, !ChatText.trimmed(text).isEmpty else { continue }
                if link.starts[id]?[i] == nil { link.starts[id, default: [:]][i] = now }
                let open = m.isStreaming && i >= lastVisible
                if !open, link.ends[id]?[i] == nil { link.ends[id, default: [:]][i] = now }
            }
            if !m.isStreaming { link.tracked.remove(id) }
        }
    }

    // MARK: In Header (§10.4)

    /// The newest reply's last tool call or text part: a tool call is the live step.
    var liveStep: ToolLine? {
        guard turn.busy else { return nil }
        var anchor = turnAnchorIndex()
        // A hidden continuation has no prompt row: the turn starts after the message that was newest when it went out.
        if let id = activityLink.hiddenTurnAnchor, let index = indexById[id] { anchor = max(anchor, index) }
        guard let reply = messages[(anchor + 1)...].last(where: { $0.role == .assistant }) else { return nil }
        for part in reply.parts.reversed() {
            switch part {
            case .tool(let call): return ToolLines.line(call)
            case .text(let t) where !ChatText.trimmed(t).isEmpty: return nil
            default: continue
            }
        }
        return nil
    }

    var statusIsWorking: Bool {
        switch connection {
        case .offline, .reconnecting, .signedOut: return false
        case .connecting where everReady: return false
        default: return turn.busy
        }
    }

    /// The status words in In Header while a step runs: "💻 npm test ›" (the words clipped so the › always shows).
    func activityHeaderStatus() -> String? {
        guard ToolCallSettings.style == .header, let step = liveStep else { return nil }
        var words = step.statusWords
        if words.count > 34 { words = String(words.prefix(33)) + "…" }
        return words + " ›"
    }

    // MARK: Fallback notice (§8.3)

    func activityStatusUpdate(_ p: JSONValue) {
        guard let text = ProviderWait.fallbackNotice(kind: p["kind"]?.string, text: p["text"]?.string) else { return }
        let seconds = Int(Date().timeIntervalSince1970)
        let key = "\(seconds)|\(text)"
        guard activityLink.noticeKeys.insert(key).inserted else { return }
        // The web's `fallback-switch-<seconds>` with M1's "local-" mark (a client-side row: merges keep it, the cache
        // drops it, ChatMeta.isLocal); a second notice in the same second gets a suffix.
        var id = "\(ProviderWait.noticeIdPrefix)\(seconds)"
        if indexById[id] != nil { id += "-\(activityLink.noticeKeys.count)" }
        appendMessage(ChatMessage(id: id, role: .system, parts: [.text(ProviderWait.plainNotice(text))], timestamp: Date(), rowId: nil))
        var meta = MessageMeta()
        meta.systemNotice = true
        meta.serverRowSpan = 0
        metaById[id] = meta
    }

    // MARK: Hidden goal continuation (§6.4)

    func sendHidden(_ text: String, display: String?) {
        guard !ChatText.trimmed(text).isEmpty else { return }
        flushDeltas()
        if turn.busy || (!queuedMessages.isEmpty && !isQueueParked) {
            enqueueHidden(text, display: display)
            return
        }
        submitHidden(text, queued: false)
    }

    /// `prompt.submit {…, display_kind: "hidden"}` with no bubble: the reply arrives like a turn another device started.
    func submitHidden(_ text: String, queued: Bool) {
        activityLink.hiddenTurnAnchor = messages.last?.id
        turn.busy = true
        turn.awaitingResponse = true
        turn.sawAssistantPayload = false
        turn.turnLive = false
        turn.interrupted = false
        turn.stopPending = false
        turn.userAnchorId = nil
        turn.anchorPromptKey = nil
        turn.streamId = nil
        turn.openPart = nil
        turn.idleConfirmed = false
        turn.armedAt = Date()
        turn.turnStartedAt = Date()
        armWatchdog()
        changes.markState()
        scheduleFlush()
        // As an ordinary send (04 §5): a Stop pressed while this is still on its way wins. Before it goes out it never
        // does; accepted after the Stop, the turn it started is interrupted once more.
        let epoch = stopEpoch
        Task { [weak self] in
            guard let self else { return }
            if self.runtimeSessionId == nil { _ = try? await self.resumeNow() }
            if self.stopEpoch != epoch {
                AppLog.trace("send", "hidden goal continuation on \(self.logIds) dropped: Stop came before it went out")
                return
            }
            guard let rid = self.runtimeSessionId else { self.hiddenFailed(epoch: epoch); return }
            var params: [String: JSONValue] = ["session_id": .string(rid), "text": .string(text), "display_kind": "hidden"]
            if let profile = self.profileParam { params["profile"] = .string(profile) }
            if queued { params["queued"] = true }
            do {
                let result = try await self.client.call("prompt.submit", .object(params), timeout: self.submitTimeout)
                if self.stopEpoch != epoch, result["status"]?.string != "queued" {
                    AppLog.trace("send", "hidden goal continuation on \(self.logIds) accepted after Stop: interrupting it again")
                    self.interruptAgain()
                }
            } catch let error as RPCError where error.isTimeout || error.isConnectionLost {
                // It may have gone out: Hermes runs it anyway (never resend).
            } catch {
                self.hiddenFailed(epoch: epoch)
            }
        }
    }

    private func hiddenFailed(epoch: Int) {
        // After a Stop the turn on screen may be a newer send's: not this continuation's to settle.
        if !turn.turnLive && !turn.sawAssistantPayload && stopEpoch == epoch { settleFlags() }
        changes.markState()
        scheduleFlush()
        if let rid = activityLink.boundRid { activityLink.store?.setControlError(runtimeId: rid, "Failed to submit goal continuation") }
    }
}
