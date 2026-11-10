// [m9/composer] What the composer stream adds to a chat with a queue (docs/spec/3x-composer.md §1, §16). The chat
// screen checks for it the way it checks `ChatQueueing`; the live session adopts it.

import Foundation

/// ⌘Return while a reply runs: the next send waits in the queue instead of going into the reply.
protocol ChatSendQueueing: AnyObject {
    var queuesNextSend: Bool { get set }
}

protocol ChatQueueResuming: AnyObject {
    /// "Resume" on a paused queue: it drains again, now when the chat is idle, after the reply when one is running.
    func resumeQueue()
    /// A hardware Return in the empty field while idle: the head row goes out now. Nothing while the queue is paused
    /// (that needs Resume), a reply runs or nothing waits. Returns whether a message went out.
    @discardableResult func sendNextQueued() -> Bool
}

extension LiveChatSession: ChatSendQueueing {}

extension LiveChatSession: ChatQueueResuming {
    func resumeQueue() {
        guard isQueueParked, !queuedMessages.isEmpty else { return }
        unparkQueue()
        changes.markState()
        scheduleFlush()
        // Idle: the head goes now. A reply running: the turn's end drains it, as any unparked queue.
        if !turn.busy { drainQueueHead() }
    }

    @discardableResult
    func sendNextQueued() -> Bool {
        guard EmptyReturn.decide(running: turn.busy, waiting: queuedMessages.count, paused: isQueueParked, canAct: true) == .sendNext,
              isLive else { return false }
        drainQueueHead()
        scheduleFlush()
        return true
    }
}

// MARK: L463 · Send Now steers a queued message into the running reply (spec §15.3, §15.4)

nonisolated enum SteerRule {
    /// `^\/[^\s/]*(?:\s|$)`: a slash command.
    static func isSlashCommand(_ text: String) -> Bool {
        text.range(of: #"^\/[^\s/]*(?:\s|$)"#, options: .regularExpression) != nil
    }

    /// Steerable: visible text, nothing attached, not a memo, not a slash command.
    static func steerable(_ m: QueuedMessage) -> Bool {
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !m.hidden && !t.isEmpty && m.attachments.isEmpty && m.memo == nil && !isSlashCommand(t)
    }

    static let failedNotice = "Couldn’t add this to the running reply. It’ll send after this reply."
}

extension LiveChatSession {
    var isReplyRunning: Bool { turn.busy }

    func canSteer(_ id: String) -> Bool {
        guard turn.busy, !redirectUnsupported, !steeringIds.contains(id),
              let item = queuedMessages.first(where: { $0.id == id }) else { return false }
        return SteerRule.steerable(item)
    }

    /// The row leaves the queue and the queue un-pauses on `redirected`/`queued`; a refusal keeps the row and says so.
    func steerQueued(_ id: String) async -> Bool {
        guard turn.busy, steeringIds.isEmpty, let item = queuedMessages.first(where: { $0.id == id }), SteerRule.steerable(item) else {
            if !turn.busy { sendQueuedNow(id) }
            return false
        }
        steeringIds.insert(id)
        changes.markState()   // the row's "Sending…" caption
        defer {
            steeringIds.remove(id)
            changes.markState()
            scheduleFlush()
        }
        let steer = beginSteer(shown: item.display ?? item.text)
        switch await finishSteer(steer, text: item.text) {
        case .redirected, .nextTurn:
            if let index = queuedMessages.firstIndex(where: { $0.id == id }) { queuedMessages.remove(at: index) }
            if queuedMessages.isEmpty { unparkQueue() }
            changes.markState()
            scheduleFlush()
            return true
        case .failed:
            onNotice?(SteerRule.failedNotice)
            return false
        }
    }
}

// MARK: Typing while a reply runs adds to it (desktop parity, owner 2026-10-28)

/// The desktop app sends plain text typed while a reply runs straight into that reply (`session.redirect`, its
/// "stop-and-correct": the bubble lands under what the bot already said and the bot carries on with it in mind). Photos
/// and files, slash commands, a skill or titled request, an open approval / password / question, a Stop still
/// unwinding, and a send still waiting on another process all keep to the queue, as on the desktop
/// (`V/app/chat/composer/hooks/use-composer-submit.ts:280-307`). A steer the gateway turns down joins the queue, so
/// nothing typed is lost.
nonisolated enum ReplySteerOutcome: Equatable, Sendable {
    /// Part of the running reply now.
    case redirected
    /// The gateway holds it for the next turn (the turn was still being built, or compressing).
    case nextTurn
    /// Not taken: `rejected` (the reply ended first), 4010 / -32601, a transport failure.
    case failed
}

/// What `beginSteer` set up: the pending bubble, and the live reply it sealed (put back if the steer isn't taken).
struct SteerHandle {
    let localId: String
    let sealedStreamId: String?
    let sealedWasStreaming: Bool
    let turnStartedAt: Date?
}

extension LiveChatSession {
    /// A message typed now goes into the running reply instead of waiting behind it.
    func steersTyped(_ text: String, display: String?, attachments: [DraftAttachment]) -> Bool {
        let trimmed = ChatText.trimmed(text)
        return turn.busy && !turn.interrupted && !turn.stopTerminalPending && !turn.submitHeld
            && turn.waitingForOwner == nil && turn.preparingSendId == nil
            && !redirectUnsupported && display == nil && attachments.isEmpty
            && !trimmed.isEmpty && !SteerRule.isSlashCommand(trimmed) && prompts.isEmpty
    }

    /// The typed message's bubble shows at once under the running reply; the steer goes out after any still in flight
    /// (typing order). Turned down → it joins the queue: idle by then → it sends now; still busy → the notice.
    func steerTyped(_ text: String) {
        let steer = beginSteer(shown: text)
        let previous = typedSteerChain
        let epoch = stopEpoch
        typedSteerChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard await self.finishSteer(steer, text: text) == .failed else { return }
            // Stop came while the steer was out: Stop halts the queue, so the words wait in it, paused, and nothing
            // queued before them goes out either (spec 3x-composer §19.6: "back as a paused queue row").
            if self.stopEpoch != epoch {
                AppLog.note("send", "steer \(AppLog.tag(steer.localId)) on \(self.logIds) not taken after Stop; kept in the paused queue")
                self.queuedMessages.append(QueuedMessage(id: self.nextQueuedId(), text: text, attachments: [], display: nil))
                self.parkQueue()
                self.changes.markState()
                self.scheduleFlush()
                return
            }
            AppLog.note("send", "steer \(AppLog.tag(steer.localId)) on \(self.logIds) not taken; queued (\(self.turn.busy ? "after this reply" : "sends now"))")
            self.queuedMessages.append(QueuedMessage(id: self.nextQueuedId(), text: text, attachments: [], display: nil))
            self.unparkQueue()
            self.changes.markState()
            self.scheduleFlush()
            if self.turn.busy { self.onNotice?(SteerRule.failedNotice) } else { self.drainQueueHead() }
        }
    }

    /// Seals the live reply where it stands and adds the pending bubble under it, so whatever the bot says after the
    /// correction lands below it (the desktop's `appendMidTurnUserMessage`). A tool still running in the sealed bubble
    /// finishes there (`toolOwner` finds it by id).
    func beginSteer(shown: String) -> SteerHandle {
        flushDeltas()
        let sealed = turn.streamId.flatMap { indexById[$0] != nil ? $0 : nil }
        let wasStreaming = sealed.flatMap { indexById[$0] }.map { messages[$0].isStreaming } ?? false
        if let sealed { updateMessage(sealed) { $0.isStreaming = false } }
        turn.streamId = nil
        turn.openPart = nil
        localCounter += 1
        let localId = "local-user-\(localCounter)-\(UInt32.random(in: 0...UInt32.max))"
        var bubble = ChatMessage(id: localId, role: .user, parts: [.text(shown)], timestamp: Date(), rowId: nil)
        bubble.isPending = true
        appendMessage(bubble)
        turn.correctionIds.insert(localId)
        AppLog.trace("send", "steer \(AppLog.tag(localId)) on \(logIds): bubble under \(sealed.map { "sealed live row \(AppLog.tag($0))" } ?? "the reply (no live row)")")
        changes.markState()
        scheduleFlush()
        return SteerHandle(localId: localId, sealedStreamId: sealed, sealedWasStreaming: wasStreaming, turnStartedAt: turn.turnStartedAt)
    }

    /// `session.redirect {session_id, text[, profile]}` (resumes a stale runtime and retries once).
    func finishSteer(_ steer: SteerHandle, text: String) async -> ReplySteerOutcome {
        var failure: RPCError?
        var attempt = 0
        while attempt < 2 {
            attempt += 1
            if runtimeSessionId == nil { try? await resumeNow() }
            guard let rid = runtimeSessionId else { break }
            var params: [String: JSONValue] = ["session_id": .string(rid), "text": .string(text)]
            if let profileParam { params["profile"] = .string(profileParam) }
            do {
                let result = try await client.call("session.redirect", .object(params), timeout: .seconds(20))
                let status = result["status"]?.string ?? ""
                AppLog.trace("send", "steer \(AppLog.tag(steer.localId)) on \(logIds): \(status.isEmpty ? "no status" : status)")
                if status == "redirected" {
                    updateMessage(steer.localId) { $0.isPending = false }
                    changes.markState()
                    scheduleFlush()
                    return .redirected
                }
                if status == "queued" {
                    // The next turn's prompt, not part of this reply: the reply goes on in its own bubble, this one
                    // moves to the newest end (the desktop's `moveOptimisticMessageToEnd`).
                    turn.correctionIds.remove(steer.localId)
                    unsealSteer(steer)
                    if let index = indexById[steer.localId] {
                        var bubble = messages[index]
                        bubble.isPending = false
                        removeMessage(steer.localId)
                        appendMessage(bubble)
                    }
                    changes.markState()
                    scheduleFlush()
                    return .nextTurn
                }
                failure = nil
                break
            } catch let error as RPCError {
                failure = error
                if error.code == 4001 { runtimeSessionId = nil; continue }
                break
            } catch {
                break
            }
        }
        if let failure, failure.code == 4010 || failure.code == -32601 { redirectUnsupported = true }
        turn.correctionIds.remove(steer.localId)
        removeMessage(steer.localId)
        unsealSteer(steer)
        changes.markState()
        scheduleFlush()
        return .failed
    }

    /// The steer wasn't part of this reply after all: the reply carries on in the bubble it was sealed out of, unless the
    /// turn ended or the bot already went on in a new one.
    private func unsealSteer(_ steer: SteerHandle) {
        guard let sid = steer.sealedStreamId, indexById[sid] != nil, turn.busy, turn.streamId == nil,
              turn.turnStartedAt == steer.turnStartedAt else { return }
        turn.streamId = sid
        turn.openPart = nil
        if steer.sealedWasStreaming { updateMessage(sid) { $0.isStreaming = true } }
    }

    /// Where the running turn's rows end: the next prompt after its anchor that isn't one of its own steers.
    func turnScopeEnd(after anchor: Int) -> Int {
        guard anchor + 1 < messages.count else { return messages.count }
        return messages[(anchor + 1)...].firstIndex { $0.role == .user && !turn.correctionIds.contains($0.id) } ?? messages.count
    }
}

/// `inflight.corrections` (+ `correction_offsets`, only when every steer has one) of a resume snapshot
/// (`H/tui_gateway/session_auto_continue.py` `_inflight_snapshot`). Nil when the turn has none.
nonisolated struct InflightCorrections: Sendable {
    let texts: [String]
    let offsets: [Int]?

    init?(_ inflight: [String: JSONValue]) {
        let texts = (inflight["corrections"]?.array ?? []).compactMap { $0.string }.filter { !ChatText.trimmed($0).isEmpty }
        guard !texts.isEmpty else { return nil }
        self.texts = texts
        let offsets = (inflight["correction_offsets"]?.array ?? []).compactMap { $0.int }
        self.offsets = offsets.count == texts.count && offsets.allSatisfy({ $0 >= 0 }) ? offsets : nil
    }

    /// Hermes joins steers that reached the model together into one stored prompt.
    static let joinMarker = "[Additional user correction]"

    /// The row shows this steer: its words, or a joined row holding them.
    func covers(_ row: String, _ text: String) -> Bool {
        let r = ChatText.flat(row), t = ChatText.flat(text)
        return r == t || (row.contains(Self.joinMarker) && r.contains(t))
    }

    func isCorrection(_ row: String) -> Bool { texts.contains { covers(row, $0) } }
}
