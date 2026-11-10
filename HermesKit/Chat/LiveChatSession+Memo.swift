// Voice memos in the live chat (spec 1x-voice §4.2–§4.5, contract `ChatVoiceMemos`): the optimistic bubble in the frame
// the recorder closes, the staging pipeline (`MemoUploader`), the rewrite to the final text, then the existing
// `prompt.submit` path with every branch it has (4009 retry window, 4001/4007 resume-once, refusal, unconfirmed).
// The silence watchdog is armed only when `prompt.submit` goes out: a long upload must not end the turn. The send
// captures the session strongly, so a chat left mid-send still finishes into its own chat. Stop while a memo stages
// cancels the staging at once and hands the memo back as the chat's draft (nothing reached the gateway). A memo still
// queued when the chat is left stays in its queue like typed words: the chat drains it off screen, or the queue stash
// keeps it for the next open (QueueStash.swift). Only a chat that keeps no queue (tests, previews) hands it back.

import Foundation

/// A memo send in flight (by its optimistic bubble's id).
struct MemoSendContext {
    let memo: MemoFile
    /// Typed beside the memo: the next bubble in the same turn; back into the empty field on a refusal.
    let typed: String
    /// The Stop epoch the send began in (a send of an earlier epoch never holds the watchdog back).
    let epoch: Int
    /// The account the send belongs to: the memo stores are written only while it is still the one signed in.
    let accountId: String
    /// The staging task (Stop cancels it while it stages).
    var task: Task<Void, Never>?
    /// The chat's stored id when staging began: what an earlier attempt's staging is kept under (and forgotten by).
    var storedId: String?
    /// The gateway's copy, once staged.
    var gatewayPath: String?
    /// `prompt.submit` went out (the watchdog may arm).
    var submitted = false
}

/// A memo notice for the chat it belongs to. `MemoController` keeps it by scope; the screen showing that scope puts it
/// on its notice card (now, or when the chat opens next).
nonisolated enum MemoSessionNotice {
    static let post = Notification.Name("hq.memo.session.notice")
    static let scopeKey = "scope"
    static let detailKey = "detail"
    static let kindKey = "kind"
    static let botKey = "bot"

    enum Kind: String, Sendable {
        /// The memo went without its transcript (detail: the gateway's reason).
        case noTranscript = "transcript"
        /// The memo couldn't go out and waits as the chat's draft (bot: the chat's bot).
        case savedAsDraft = "draft"
    }

    struct Info: Sendable {
        var kind: Kind
        var scope: String
        var detail: String?
        var bot: String?

        init?(_ note: Notification) {
            guard let scope = note.userInfo?[MemoSessionNotice.scopeKey] as? String else { return nil }
            self.scope = scope
            kind = (note.userInfo?[MemoSessionNotice.kindKey] as? String).flatMap(Kind.init(rawValue:)) ?? .noTranscript
            detail = note.userInfo?[MemoSessionNotice.detailKey] as? String
            bot = note.userInfo?[MemoSessionNotice.botKey] as? String
        }
    }
}

extension LiveChatSession: ChatVoiceMemos {
    var memoScope: String { layoutScope }

    var memoDraft: MemoFile? { memoStoresAreMine ? MemoAccountStores.shared.drafts?.draft(for: memoScope) : nil }

    func setMemoDraft(_ memo: MemoFile?) {
        guard memoStoresAreMine else { return }
        MemoAccountStores.shared.drafts?.set(memo, for: memoScope)
    }

    /// The memo stores signed in are this chat's account's (an account switch mid-send must not write into another's).
    var memoStoresAreMine: Bool { MemoAccountStores.shared.accountId == account.id }

    /// [live words] A memo send's size for the log: its length, its words' (never the words), what's typed beside it.
    /// The send's own text is the bubble's placeholder there (its file path), the same length every time.
    static func memoLogWords(_ context: MemoSendContext) -> String {
        let words = context.memo.words.map { "words \($0.count) chars from this device" } ?? "no words (the gateway transcribes)"
        return "memo \(Int(context.memo.seconds.rounded()))s, \(words), typed \(context.typed.count) chars"
    }

    /// A memo (and the words typed beside it). While a reply runs it waits in the local queue as a memo item and drains
    /// with `queued:true`; it never steers or redirects (V13).
    func sendMemo(_ memo: MemoFile, text: String) {
        flushDeltas()
        let waitInLine = turn.busy || (!queuedMessages.isEmpty && !isQueueParked)
        unparkQueue()   // verify round 3: a fresh message resumes a parked queue (as `send`)
        if waitInLine {
            queuedMessages.append(QueuedMessage(id: nextQueuedId(), text: text, memo: memo))
            changes.markState()
            scheduleFlush()
            if !turn.busy { drainQueueHead() }
            return
        }
        beginMemoSend(memo, typed: text, queued: false)
    }

    func beginMemoSend(_ memo: MemoFile, typed: String, queued: Bool) {
        beginSend(MemoText.optimistic(localPath: memo.path, typed: typed), queued: queued,
                  memo: MemoSendContext(memo: memo, typed: typed, epoch: stopEpoch, accountId: account.id))
    }

    /// A memo of this Stop epoch is staging: the watchdog waits for its `prompt.submit` (spec §4.2 step 0).
    var memoStaging: Bool { memoSends.values.contains { !$0.submitted && $0.epoch == stopEpoch } }

    /// Steps (a)–(f), the rewrite, then (g). Runs with `self` held strongly until `prompt.submit` answers. A send Stop
    /// withdrew meanwhile (its context gone) ends quietly.
    func runMemoSend(localId: String, queued: Bool, holdForStop: Bool, epoch: Int) async {
        guard memoSends[localId] != nil else { return }
        // A brand-new chat learns its stored id first: an earlier attempt's staging is kept under it (and forgotten by
        // it on the ack), and the chat's scope (drafts, notices) is the full one from here on.
        let storedId = await ensureStoredId()
        guard let context = memoSends[localId] else { return }
        memoSends[localId]?.storedId = storedId
        let uploader = MemoUploader(client: client)
        let staged: StagedMemo
        do {
            staged = try await uploader.stage(context.memo, profile: profileParam, storedId: storedId) { params in
                try await self.memoAttach(params)
            }
        } catch {
            AppLog.note("send", "memo send \(AppLog.tag(localId)): staging failed: \(LiveChatSession.logError(error))")
            guard memoSends[localId] != nil else { return }
            if stopEpoch != epoch { withdrawStoppedSend(localId: localId, text: context.typed); return }
            let reason = (error as? MemoSendError)?.reason ?? MemoUploader.words(error, doing: "send the voice memo")
            refuseSend(localId: localId, text: context.typed, reason: reason, queued: queued)
            return
        }
        guard memoSends[localId] != nil else { return }
        // Stop pressed while it staged: it never goes out; the memo comes back as the chat's draft.
        if stopEpoch != epoch { withdrawStoppedSend(localId: localId, text: context.typed); return }
        // The bubble shows the transcript at once (`rewriteOptimistic`), and keeps playing the same file and waveform.
        let prompt = MemoText.prompt(reference: staged.reference, typed: context.typed)
        updateMessage(localId) { m in m.parts = [.text(prompt)] }
        if let gatewayPath = staged.gatewayPath, memoStoresAreMine {
            MemoAccountStores.shared.cache?.alias(gatewayPath, to: URL(fileURLWithPath: context.memo.path))
            MemoAccountStores.shared.shapes?.link(context.memo.path, to: gatewayPath)
        }
        memoSends[localId]?.gatewayPath = staged.gatewayPath
        memoSends[localId]?.submitted = true
        if let failure = staged.transcriptFailure, memoStoresAreMine {
            NotificationCenter.default.post(name: MemoSessionNotice.post, object: self,
                                            userInfo: [MemoSessionNotice.scopeKey: memoScope, MemoSessionNotice.detailKey: failure,
                                                       MemoSessionNotice.botKey: botName,
                                                       MemoSessionNotice.kindKey: MemoSessionNotice.Kind.noTranscript.rawValue])
        }
        scheduleFlush()
        armWatchdog()
        await submit(prompt, localId: localId, queued: queued, holdForStop: holdForStop, epoch: epoch)
    }

    /// (c) `file.attach {session_id, profile, name, path}`; a stale runtime id (4001) resumes once and attaches again
    /// with the same uploaded path (no second upload).
    func memoAttach(_ base: [String: JSONValue]) async throws -> JSONValue {
        if runtimeSessionId == nil { try await resumeNow() }
        var resumed = false
        var waitedForReturn = 0
        while true {
            try Task.checkCancellation()
            guard let rid = runtimeSessionId else { throw MemoSendError(reason: "Couldn’t reach this chat.") }
            var params = base
            params["session_id"] = .string(rid)
            do {
                return try await client.call("file.attach", .object(params), timeout: .seconds(30))
            } catch let error as RPCError where error.code == 4001 && !resumed {
                resumed = true
                runtimeSessionId = nil
                try await resumeNow()
            } catch let error as RPCError where (error.isConnectionLost || error.isNotConnected) && waitedForReturn < 2 {
                // [phone-logs] Build 908: a memo sent just before leaving the app uploaded slowly, and the background
                // close (25 s after leaving) came while its file.attach was out: "Couldn’t Send", and the owner sent it
                // again 11 minutes later. A link closed for the background waits for the return and attaches again
                // (the same uploaded path, no second upload); any other lost link is refused as before.
                guard await linkClosedForBackground() else { throw error }
                waitedForReturn += 1
                AppLog.note("send", "memo attach \(logIds): the link closed for the background; attaching again when it is back")
                guard try await linkBack() else { throw error }
                if runtimeSessionId == nil { try await resumeNow() }
            } catch let error as RPCError where error.code == 4064 {
                onRosterStale?()
                throw error
            }
        }
    }

    /// [phone-logs] The chat's link went offline because the app left the screen ("paused"), not because the gateway
    /// went away. The lost call's error can come a moment before the state does: up to 1 s is allowed for it.
    func linkClosedForBackground() async -> Bool {
        for _ in 0..<10 {
            if connection == .offline(reason: GatewayFailure.paused.code) { return true }
            if connection != .ready { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return connection == .offline(reason: GatewayFailure.paused.code)
    }

    /// [phone-logs] Waits for the link to be ready again: for as long as the app is away (the task is frozen with it),
    /// then at most 30 s of trying once it is back. False when it did not come back.
    func linkBack() async throws -> Bool {
        var trying = 0
        while connection != .ready {
            try await Task.sleep(for: .milliseconds(250))
            if connection != .offline(reason: GatewayFailure.paused.code) { trying += 1 }
            if trying > 120 { return false }
        }
        return true
    }

    // MARK: Stop and leave (VOICE hooks in LiveChatSession.swift)

    /// VOICE hook at the top of `stop()`: memos still staging stop at once (their task is cancelled: nothing more is
    /// uploaded, attached or transcribed) and come back as this chat's draft, their bubble gone (spec §4.3 "Stop before
    /// (g)"). When the running turn was such a memo's own, it never reached the gateway: the turn settles here, with no
    /// interrupt and no Stopped marker, and `true` tells `stop()` it is done.
    func memoStopWhileStaging() -> Bool {
        let staging = memoSends.filter { !$0.value.submitted }
        guard !staging.isEmpty else { return false }
        let ownTurn = turn.userAnchorId.map { staging[$0] != nil } ?? false
        stopEpoch += 1
        for (localId, context) in staging.sorted(by: { $0.key < $1.key }) {
            context.task?.cancel()
            withdrawStoppedSend(localId: localId, text: context.typed)
        }
        guard ownTurn, turn.streamId == nil else { return false }
        parkQueue()
        settleFlags()
        changes.markState()
        scheduleFlush()
        return true
    }

    /// VOICE hook in `stopObserving()` for a chat that keeps no queue beyond its screen (`keepsQueue` off: tests,
    /// previews): it is left with memos still queued behind a reply, and nothing drains them, so each memo comes back as
    /// this chat's draft (oldest first, with the words typed beside it), and the chat says so when it opens next. Its
    /// recording is never lost. The app's chats keep their memos queued (`stopObserving`).
    func memoQueueLeaving() {
        let memos = queuedMessages.compactMap { item in item.memo.map { MemoDraft(memo: $0, text: item.text) } }
        guard !memos.isEmpty else { return }
        AppLog.trace("send", "chat left \(logIds): \(memos.count) queued memos go back to drafts (stores mine=\(memoStoresAreMine))")
        queuedMessages.removeAll { $0.memo != nil }
        changes.markState()
        guard memoStoresAreMine, let drafts = MemoAccountStores.shared.drafts else {
            for draft in memos { MemoPaths.remove(draft.memo.path) }
            return
        }
        drafts.restore(memos, for: memoScope)
        NotificationCenter.default.post(name: MemoSessionNotice.post, object: self,
                                        userInfo: [MemoSessionNotice.scopeKey: memoScope, MemoSessionNotice.botKey: botName,
                                                   MemoSessionNotice.kindKey: MemoSessionNotice.Kind.savedAsDraft.rawValue])
    }

    enum MemoSendOutcome { case acknowledged, unconfirmed, refused, withdrawn }

    /// Called by the send path's endings for every local id: nil for a text send. For a memo it returns the typed words
    /// (what goes back into the field), and puts the memo where it belongs: the playback cache under its gateway path
    /// (accepted, or unconfirmed: never resent), or back in the composer as this chat's draft chip (refused, withdrawn).
    /// When another account signed in meanwhile, nothing is written into its stores: the recording is deleted.
    func memoSendFinished(_ localId: String, _ outcome: MemoSendOutcome) -> String? {
        guard let context = memoSends.removeValue(forKey: localId) else { return nil }
        AppLog.trace("send", "memo send \(AppLog.tag(localId)) ended: \(outcome)")
        guard MemoAccountStores.shared.accountId == context.accountId else {
            MemoPaths.remove(context.memo.path)
            return context.typed
        }
        switch outcome {
        case .acknowledged, .unconfirmed:
            if outcome == .acknowledged {
                MemoUploader.forgetStage(memoPath: context.memo.path, storedId: context.storedId)
            }
            if let gatewayPath = context.gatewayPath {
                MemoAccountStores.shared.cache?.adopt(URL(fileURLWithPath: context.memo.path), as: gatewayPath)
            }
        case .refused, .withdrawn:
            setMemoDraft(context.memo)
        }
        return context.typed
    }

    /// Remove on a queued memo: the memo returns as the draft chip (its words go back to the field as for text).
    func memoQueueItemRemoved(_ item: QueuedMessage) {
        if let memo = item.memo { setMemoDraft(memo) }
    }
}
