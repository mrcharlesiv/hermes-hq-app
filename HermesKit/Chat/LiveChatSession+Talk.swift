// Live voice in the chat (docs/spec/3x-talk.md §2.3, contract `ChatVoiceTurns`). A spoken turn is an ordinary send:
// the same optimistic bubble, the same 4009 retry window, the same resume-once, the same refusal card. The only
// difference on the wire is `interrupted: true` after a barge-in (§3.6).

import Foundation

extension LiveChatSession: ChatVoiceTurns {
    /// A chat that is gone from the gateway cannot hold a conversation. The groups stream adds its rooms here (T25).
    var allowsTalk: Bool { !chatGone }

    var voiceClient: any GatewayClient { client }

    var canReopen: Bool { menus.isBotChat || storedSessionId != nil || resolvedStoredId != nil }

    func sendSpoken(_ text: String, interrupted: Bool) {
        guard !ChatText.trimmed(text).isEmpty else { return }
        flushDeltas()
        // Spoken over a running reply: the reply stops and these words are the next turn, never a queued message
        // (the desktop's voice conversation does the same).
        let stopped = interruptForVoice()
        if (!queuedMessages.isEmpty && !isQueueParked) || !(interrupted || stopped) {
            // Typed messages are waiting their turn: the usual send keeps the order.
            send(text)
            return
        }
        unparkQueue()
        beginSend(text, queued: false, interrupted: true)
    }

    /// Stops the running reply for a spoken message. True when one was running.
    private func interruptForVoice() -> Bool {
        guard turn.busy else { return false }
        stop()
        return true
    }

    var newestReply: SpokenReply? {
        guard let last = messages.last, last.role == .assistant else { return nil }
        return LiveChatSession.spoken(last)
    }

    func spokenReplies(since: Date) -> [SpokenReply] {
        messages.suffix(Self.recentReplyWindow).compactMap { message -> SpokenReply? in
            guard message.role == .assistant, message.sender == nil, !message.interrupted, message.error == nil, !message.isStreaming,
                  let at = message.timestamp, at >= since else { return nil }
            let reply = LiveChatSession.spoken(message)
            guard !ChatText.trimmed(reply.text).isEmpty, !Self.isInterruptedSentinel(reply.text) else { return nil }
            return reply
        }
    }

    /// How far back from the newest message `spokenReplies` looks.
    static let recentReplyWindow = 24

    /// What Hermes stores for a turn stopped while it waited on the model ("Operation interrupted: waiting for model
    /// response (4.7s elapsed)."); the live stream strips it (04 §5.3), a history read does not.
    nonisolated static func isInterruptedSentinel(_ text: String) -> Bool {
        ChatText.trimmed(text).hasPrefix("Operation interrupted:")
    }

    func spokenText(messageId: String) -> SpokenReply? {
        messages.last { $0.id == messageId && $0.role == .assistant }.map(LiveChatSession.spoken)
    }

    /// The words of one assistant message: its text parts in order (never reasoning, never tools).
    nonisolated static func spoken(_ message: ChatMessage) -> SpokenReply {
        let text = message.parts.compactMap { part -> String? in
            if case .text(let words) = part, !words.isEmpty { return words }
            return nil
        }.joined(separator: "\n\n")
        return SpokenReply(messageId: message.id, text: text, pending: message.isStreaming)
    }

    /// [voice record] The conversation's words, for the chat and the bot. Queued, never typed into a running reply:
    /// its note asks for no answer, and steered into the reply to a real request it would have silenced that reply.
    func sendVoiceRecord(_ text: String) {
        guard !chatGone, !ChatText.trimmed(text).isEmpty else {
            rollbackUnboundVoiceRecordFolds()
            return
        }
        flushDeltas()
        if let idx = pendingVoiceRecordFolds.lastIndex(where: { $0.recordText == nil }) {
            pendingVoiceRecordFolds[idx].recordText = text
        }
        // An ordinary message, not a hidden one: a hidden row (`display_kind: "hidden"`) reaches the bot but is never
        // drawn, and the chat's line is made from this message (build 1073 sent it hidden: the bot had the words and
        // the chat showed nothing).
        unparkQueue()
        queuedMessages.append(QueuedMessage(id: nextQueuedId(), text: text))
        changes.markState()
        scheduleFlush()
        if !turn.busy { drainQueueHead() }
    }

    var voiceFoldedMessageIds: Set<String> {
        pendingVoiceRecordFolds.reduce(into: liveVoiceHiddenIds) { $0.formUnion($1.ids) }
    }
    var voiceFoldedRowIds: Set<Int> {
        pendingVoiceRecordFolds.reduce(into: liveVoiceHiddenRowIds) { $0.formUnion($1.rowIds) }
    }

    var isAnsweringVoiceRecord: Bool { answeringVoiceRecord }

    func setLiveVoiceActive(_ active: Bool) {
        liveVoiceGeneration += 1
        liveVoiceActive = active
        if !active { liveVoiceTurnActive = false }
    }

    func noteLiveVoiceHeard(messageId: String) {
        liveVoiceHeardIds.insert(messageId)
        if let idx = indexById[messageId] {
            if let row = messages[idx].rowId { liveVoiceHeardRowIds.insert(row) }
            if let row = messages[idx].reactionRow { liveVoiceHeardRowIds.insert(row) }
        }
    }

    func revokeLiveVoiceHeard(messageId: String) {
        liveVoiceHeardIds.remove(messageId)
        if let idx = indexById[messageId] {
            if let row = messages[idx].rowId { liveVoiceHeardRowIds.remove(row) }
            if let row = messages[idx].reactionRow { liveVoiceHeardRowIds.remove(row) }
        }
    }

    /// True only while the currently running turn belongs to an active live-voice delegation.
    var isLiveVoiceTurn: Bool { liveVoiceActive && liveVoiceTurnActive }

    /// Releases the currently running live-voice turn's prompt and replies immediately (called on typed steer into a
    /// live-voice turn, or when a live-voice turn ends in an error).
    func unhideRunningLiveVoiceTurn() {
        let anchor = turnAnchorIndex()
        guard anchor >= 0, anchor < messages.count else { return }
        let scopeEnd = turnScopeEnd(after: anchor)
        var released: [String] = []
        for i in anchor..<min(scopeEnd, messages.count) {
            let m = messages[i]
            var changed = false
            if liveVoiceHiddenIds.remove(m.id) != nil { changed = true }
            liveVoiceUserIds.remove(m.id)
            liveVoiceSteerIds.remove(m.id)
            liveVoiceQueuedTurnIds.remove(m.id)
            if let row = m.rowId, liveVoiceHiddenRowIds.remove(row) != nil { changed = true }
            if let row = m.reactionRow, liveVoiceHiddenRowIds.remove(row) != nil { changed = true }
            if changed { released.append(m.id) }
        }
        guard !released.isEmpty else { return }
        for id in released { changes.update(id) }
        changes.markState()
        scheduleFlush()
    }

    /// Drops the temporary fold hold once `VoiceChatRecord` is acknowledged (from here `[folded: ...]` on the message
    /// itself drives folding across reloads and devices).
    func confirmVoiceRecordFold(for recordText: String) {
        if let idx = pendingVoiceRecordFolds.firstIndex(where: { $0.recordText == recordText })
            ?? pendingVoiceRecordFolds.firstIndex(where: { $0.recordText == nil }) {
            pendingVoiceRecordFolds.remove(at: idx)
        }
    }

    /// Restores turns held for a `VoiceChatRecord` that was refused, stopped, removed from queue, or unconfirmed.
    func rollbackVoiceRecordFold(for recordText: String) {
        guard let idx = pendingVoiceRecordFolds.firstIndex(where: { $0.recordText == recordText })
            ?? pendingVoiceRecordFolds.firstIndex(where: { $0.recordText == nil }) else { return }
        let entry = pendingVoiceRecordFolds.remove(at: idx)
        for id in entry.ids { changes.update(id) }
        if !entry.ids.isEmpty {
            changes.markState()
            scheduleFlush()
        }
    }

    private func rollbackUnboundVoiceRecordFolds() {
        var released: Set<String> = []
        pendingVoiceRecordFolds.removeAll { entry in
            guard entry.recordText == nil else { return false }
            released.formUnion(entry.ids)
            return true
        }
        guard !released.isEmpty else { return }
        for id in released { changes.update(id) }
        changes.markState()
        scheduleFlush()
    }

    /// Groups active-call hidden messages into atomic turns so a turn either folds whole (prompt + all its replies) or
    /// stays completely visible.
    private struct ActiveVoiceTurn {
        var userIndices: [Int]
        var assistantIndices: [Int]
        var foldable: Bool
    }

    private func partitionActiveVoiceTurns(heardReplyIds: Set<String>, allowingFold: Bool) -> (turns: [ActiveVoiceTurn], orphanIds: [String]) {
        var heardIds = heardReplyIds.union(liveVoiceHeardIds)
        var heardRows = liveVoiceHeardRowIds
        for m in messages where heardIds.contains(m.id) {
            if let r = m.rowId { heardRows.insert(r) }
            if let r = m.reactionRow { heardRows.insert(r) }
        }
        func inActiveCall(_ m: ChatMessage) -> Bool {
            liveVoiceHiddenIds.contains(m.id)
                || (m.rowId.map { liveVoiceHiddenRowIds.contains($0) } == true)
                || (m.reactionRow.map { liveVoiceHiddenRowIds.contains($0) } == true)
        }
        func wasHeard(_ m: ChatMessage) -> Bool {
            heardIds.contains(m.id)
                || (m.rowId.map { heardRows.contains($0) } == true)
                || (m.reactionRow.map { heardRows.contains($0) } == true)
        }
        var covered: Set<Int> = []
        var turns: [ActiveVoiceTurn] = []
        var i = 0
        while i < messages.count {
            let m = messages[i]
            if m.role == .user, m.sender == nil, m.job == nil, !VoiceChatRecord.isRecord(m.plainText), inActiveCall(m) {
                var uList = [i]
                var aList: [Int] = []
                var scan = i + 1
                while scan < messages.count {
                    let next = messages[scan]
                    if next.role == .system || next.sender != nil || next.job != nil || VoiceChatRecord.isRecord(next.plainText) {
                        scan += 1
                        continue
                    }
                    if next.role == .user {
                        if (turn.correctionIds.contains(next.id) || liveVoiceSteerIds.contains(next.id)), inActiveCall(next) {
                            uList.append(scan)
                            scan += 1
                            continue
                        }
                        break
                    }
                    if next.role == .assistant {
                        aList.append(scan)
                    }
                    scan += 1
                }
                for idx in uList { covered.insert(idx) }
                for idx in aList { covered.insert(idx) }

                let runningAnchorMatch = turn.busy && turn.userAnchorId.map { anchor in
                    uList.contains { u in
                        messages[u].id == anchor
                            || (messages[u].rowId != nil && indexById[anchor].flatMap { messages[$0].rowId } == messages[u].rowId)
                    }
                } == true
                let hasPendingOrQueuedUser = uList.contains { u in
                    messages[u].isPending || liveVoiceQueuedTurnIds.contains(messages[u].id)
                }
                let usersClean = uList.allSatisfy { u in
                    let msg = messages[u]
                    return msg.error == nil && msg.reactions.isEmpty && msg.phoneResultText == nil
                        && VoiceMemo.parse(msg.plainText) == nil
                }
                let repliesFoldable = !aList.isEmpty && aList.allSatisfy { a in
                    let reply = messages[a]
                    guard !reply.isStreaming, reply.error == nil, reply.reactions.isEmpty else { return false }
                    let text = ChatText.trimmed(ReasoningTags.strip(reply.plainText))
                    if text.isEmpty || Hydration.isSilentWords(text) { return true }
                    if reply.interrupted { return false }
                    return wasHeard(reply)
                }
                let foldable = allowingFold && !runningAnchorMatch && !hasPendingOrQueuedUser && usersClean && repliesFoldable
                turns.append(ActiveVoiceTurn(userIndices: uList, assistantIndices: aList, foldable: foldable))
                i = scan
            } else {
                i += 1
            }
        }
        var orphanIds: [String] = []
        for idx in messages.indices where !covered.contains(idx) && inActiveCall(messages[idx]) {
            orphanIds.append(messages[idx].id)
        }
        return (turns, orphanIds)
    }

    func releaseUnheardLiveVoice(heardReplyIds: Set<String>) {
        liveVoiceGeneration += 1
        liveVoiceActive = false
        liveVoiceTurnActive = false
        liveVoiceActiveQueuedSteerId = nil
        guard !liveVoiceHiddenIds.isEmpty || !liveVoiceHiddenRowIds.isEmpty else {
            liveVoiceQueuedTurnIds = []
            return
        }
        let (turns, orphanIds) = partitionActiveVoiceTurns(heardReplyIds: heardReplyIds, allowingFold: true)
        var releasedIds = orphanIds
        for t in turns where !t.foldable {
            for idx in t.userIndices + t.assistantIndices {
                let m = messages[idx]
                liveVoiceUserIds.remove(m.id)
                liveVoiceSteerIds.remove(m.id)
                liveVoiceQueuedTurnIds.remove(m.id)
                liveVoiceHiddenIds.remove(m.id)
                if let r = m.rowId { liveVoiceHiddenRowIds.remove(r) }
                if let r = m.reactionRow { liveVoiceHiddenRowIds.remove(r) }
                releasedIds.append(m.id)
            }
        }
        for id in orphanIds {
            liveVoiceHiddenIds.remove(id)
            if let idx = indexById[id] {
                if let r = messages[idx].rowId { liveVoiceHiddenRowIds.remove(r) }
                if let r = messages[idx].reactionRow { liveVoiceHiddenRowIds.remove(r) }
            }
        }
        liveVoiceQueuedTurnIds = []
        guard !releasedIds.isEmpty else { return }
        for id in releasedIds { changes.update(id) }
        changes.markState()
        scheduleFlush()
    }

    func finishLiveVoice(heardReplyIds: Set<String>, sendingRecord: Bool) -> [String] {
        liveVoiceGeneration += 1
        liveVoiceActive = false
        liveVoiceTurnActive = false
        liveVoiceActiveQueuedSteerId = nil
        let hadHidden = !liveVoiceHiddenIds.isEmpty || !liveVoiceHiddenRowIds.isEmpty
        guard hadHidden else {
            liveVoiceUserIds = []
            liveVoiceSteerIds = []
            liveVoiceQueuedTurnIds = []
            liveVoiceHeardIds = []
            liveVoiceHeardRowIds = []
            return []
        }
        let (turns, orphanIds) = partitionActiveVoiceTurns(heardReplyIds: heardReplyIds, allowingFold: sendingRecord)
        var foldedTags: [String] = []
        var pendingIds: Set<String> = []
        var pendingRowIds: Set<Int> = []
        var releasedIds = orphanIds
        for t in turns {
            if t.foldable,
               let tag = VoiceChatRecord.turnFoldTag(users: t.userIndices.map { messages[$0] },
                                                     assistants: t.assistantIndices.map { messages[$0] }) {
                foldedTags.append(tag)
                for idx in t.userIndices + t.assistantIndices {
                    let m = messages[idx]
                    pendingIds.insert(m.id)
                    if let r = m.rowId { pendingRowIds.insert(r) }
                    if let r = m.reactionRow { pendingRowIds.insert(r) }
                }
            } else {
                for idx in t.userIndices + t.assistantIndices {
                    releasedIds.append(messages[idx].id)
                }
            }
        }
        liveVoiceUserIds = []
        liveVoiceSteerIds = []
        liveVoiceQueuedTurnIds = []
        liveVoiceHiddenIds = []
        liveVoiceHiddenRowIds = []
        liveVoiceHeardIds = []
        liveVoiceHeardRowIds = []
        if sendingRecord && (!pendingIds.isEmpty || !pendingRowIds.isEmpty) {
            pendingVoiceRecordFolds.append(PendingVoiceRecordFold(recordText: nil, ids: pendingIds, rowIds: pendingRowIds))
        }
        if !releasedIds.isEmpty {
            for id in releasedIds { changes.update(id) }
            changes.markState()
            scheduleFlush()
        }
        return foldedTags
    }

    // [gpt-live] (docs/spec/3x-gpt-live.md §4)

    func sendDelegated(_ text: String, voiceContext: String) {
        guard !ChatText.trimmed(text).isEmpty else { return }
        flushDeltas()
        // A request made while the reply runs goes into it, as typed words do (`session.redirect`): stopping it threw
        // away the work under way (owner, 2026-10-28 20:46: "Operation interrupted" on searches the voice had asked for
        // three seconds before).
        // [voice record] Not into the turn answering a voice chat's record: its note asks for no reply, so the request
        // would go unanswered. That turn is stopped instead (the record is stored already).
        if steersTyped(text, display: nil, attachments: []), !answeringVoiceRecord {
            steerDelegated(text, voiceContext: voiceContext)
            return
        }
        let stopped = interruptForVoice()
        unparkQueue()
        beginSend(text, queued: false, interrupted: stopped, voiceContext: voiceContext)
    }

    /// The running turn is the answer to a voice chat's record.
    private var answeringVoiceRecord: Bool {
        guard turn.busy, let id = turn.userAnchorId, let index = indexById[id], messages.indices.contains(index) else { return false }
        let words = messages[index].parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
        return VoiceChatRecord.isRecord(words)
    }

    /// The request's bubble shows at once under the running reply. Not taken (the reply ended first, a gateway without
    /// redirect): it goes out as its own request, stopping the reply if one still runs, never into the queue.
    private func steerDelegated(_ text: String, voiceContext: String) {
        let generation = liveVoiceGeneration
        // Only hide a voice steer when steering into an already-folded live-voice turn (never into a visible typed turn).
        let foldSteer = liveVoiceActive && liveVoiceTurnActive
        let steer = beginSteer(shown: text, voiceDelegated: true)
        if foldSteer {
            liveVoiceUserIds.insert(steer.localId)
            liveVoiceHiddenIds.insert(steer.localId)
        }
        let previous = typedSteerChain
        typedSteerChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let outcome = await self.finishSteer(steer, text: text)
            switch outcome {
            case .redirected:
                if foldSteer, self.liveVoiceHiddenIds.contains(steer.localId) {
                    self.liveVoiceSteerIds.insert(steer.localId)
                }
                return
            case .nextTurn:
                if self.liveVoiceActive && self.liveVoiceGeneration == generation {
                    // The gateway queued this steer for the next turn: keep its prompt folded and mark it so `onStart`
                    // pairs the upcoming foreign-started turn with it.
                    self.liveVoiceUserIds.insert(steer.localId)
                    self.liveVoiceHiddenIds.insert(steer.localId)
                    self.liveVoiceQueuedTurnIds.insert(steer.localId)
                } else if self.liveVoiceHiddenIds.remove(steer.localId) != nil {
                    self.liveVoiceUserIds.remove(steer.localId)
                    self.changes.update(steer.localId)
                    self.changes.markState()
                    self.scheduleFlush()
                }
                return
            case .failed:
                self.liveVoiceUserIds.remove(steer.localId)
                self.liveVoiceHiddenIds.remove(steer.localId)
                self.liveVoiceQueuedTurnIds.remove(steer.localId)
                AppLog.note("send", "voice steer \(AppLog.tag(steer.localId)) on \(self.logIds) not taken; sent as its own request")
                let stopped = self.interruptForVoice()
                self.unparkQueue()
                // If the live call ended while the steer was in flight, `beginSend` checks `liveVoiceActive` and leaves
                // the fallback send visible rather than leaking a hidden bubble post-call.
                self.beginSend(text, queued: false, interrupted: stopped, voiceContext: voiceContext)
            }
        }
    }

    var onDelegationRefused: (() -> Void)? {
        get { onVoiceLiveRefused }
        set { onVoiceLiveRefused = newValue }
    }

    var runningToolTitle: String? {
        guard let last = messages.last, last.role == .assistant, last.isStreaming else { return nil }
        for part in last.parts.reversed() {
            if case .tool(let call) = part, call.state == .running { return call.title.isEmpty ? call.name : call.title }
        }
        return nil
    }

    var spokenHistory: [(assistant: Bool, text: String)] { LiveChatSession.spokenTurns(messages) }

    nonisolated static func spokenTurns(_ messages: [ChatMessage]) -> [(assistant: Bool, text: String)] {
        let folded = VoiceChatRecord.foldedIndices(in: messages)
        return messages.enumerated().compactMap { index, message -> (assistant: Bool, text: String)? in
            if folded.contains(index) {
                guard message.role == .assistant, VoiceChatRecord.textHasDeliverable(message.plainText) else { return nil }
                let words = SpeechText.sanitizeForSpeech(LiveChatSession.spoken(message).text)
                return words.isEmpty ? nil : (true, words)
            }
            switch message.role {
            case .user:
                let words = message.parts.compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined(separator: "\n")
                // [voice record] An earlier voice chat's words, without the note that is for the bot alone.
                if let record = VoiceChatRecord.parse(words) { return (false, "(Said in an earlier voice chat) " + record.words) }
                return words.isEmpty ? nil : (false, words)
            case .assistant:
                let words = SpeechText.sanitizeForSpeech(LiveChatSession.spoken(message).text)
                return words.isEmpty ? nil : (true, words)
            case .system:
                return nil
            }
        }
    }

    /// How long a conversation's start waits for the chat to finish opening, and for the read further back.
    static let seedOpenWait: Duration = .seconds(3)
    static let seedReadWait: Duration = .seconds(2)
    /// Backend rows the read further back asks for (tool rows count, so this is a few dozen turns).
    static let seedReadRows = 120

    /// The seed of a live voice session. Two things left the voice knowing next to nothing of the chat (owner,
    /// 2026-11-16): Talk from a bot's menu started before the chat had loaded (an empty seed), and a loaded chat holds
    /// one page of 24 backend rows, often three or four turns. So the open is waited for, and when the chat goes
    /// further back than what is loaded and the seed has room, one read fetches more. The transcript is not touched.
    func spokenSeed() async -> [(assistant: Bool, text: String)] {
        let deadline = ContinuousClock.now + Self.seedOpenWait
        while ContinuousClock.now < deadline, !(openSettled || openFinished), !chatGone {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let loaded = spokenHistory
        let budget = LiveVoiceWire.wideSeed
        let filled = loaded.count >= budget.messages
            || loaded.reduce(0) { $0 + min($1.text.count, budget.perTurn) } >= budget.chars
        guard !filled, hasOlder || loaded.isEmpty, let stored = readSessionId else { return loaded }
        var request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: Self.seedReadRows)
        request.inlineImages = false
        let client = self.client, features = perfFeatures
        let read = Task { try? await HistoryAPI.fetchAndFold(client: client, request: request, features: features, cut: true) }
        let limit = Task { try? await Task.sleep(for: Self.seedReadWait); read.cancel() }
        let page = await read.value
        limit.cancel()
        guard let page else {
            AppLog.note("talk", "voice seed \(logIds): the read further back didn't answer; \(loaded.count) loaded turns used")
            return loaded
        }
        let further = LiveChatSession.spokenTurns(page.1.messages)
        // A reply still streaming or a message just sent is only in what is loaded.
        return further.count > loaded.count ? further : loaded
    }

    var openQuestion: VoiceQuestion? {
        guard let clarify = prompts.clarify, !clarify.sending else { return nil }
        let open = clarify.questions.filter { clarify.lockedAnswers[$0.qid] == nil }
        guard !open.isEmpty else { return nil }
        return VoiceQuestion(id: clarify.id, spoken: VoiceQuestionText.spoken(open))
    }

    func answerQuestion(_ id: String, spoken: String) {
        guard let clarify = prompts.clarify, clarify.id == id else { return }
        let answers = clarify.questions.map { question -> (qid: String, answer: String?) in
            if let locked = clarify.lockedAnswers[question.qid] { return (question.qid, locked) }
            return (question.qid, VoiceQuestionText.answer(spoken, to: question))
        }
        Task { [weak self] in
            do {
                try await self?.sendClarify(id, answers: answers)
            } catch {
                AppLog.note("talk", "spoken answer to a question not sent: \(AppLog.scrub(String(describing: error)))")
            }
        }
    }

    /// `voiceHold` changed (called from its `didSet`): a chat left on screen-less hold lets go once the conversation ends.
    func voiceHoldChanged() {
        if !voiceHold { endAwayDrainIfDone() }
    }
}
