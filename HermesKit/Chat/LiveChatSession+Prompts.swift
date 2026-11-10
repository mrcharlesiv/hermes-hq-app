// The live chat's server requests (spec 1x §3.6): `ChatPrompting` through the account's `ServerRequestCenter`, filtered
// to this chat's runtime id. The hooks in LiveChatSession.swift are marked [questions]: `promptLink` (stored),
// `bindRuntime` → `promptRuntimeBound()`, `computeStatus` → `promptStatusText`, start/stopObserving → `promptsObserving`.

import Foundation

extension LiveChatSession: ChatPrompting {
    /// Ties this chat to the account's centre (AppModel.wire). Idempotent.
    func attachPrompts(_ center: ServerRequestCenter) {
        guard promptLink == nil else { return }
        let link = PromptChatLink(center: center)
        // Only while the stopped turn is still unwinding (Stop sent, its terminal frame not seen yet): `interrupted`
        // stays set until this phone's next send, and a later turn another client, cron or a chained goal started in
        // this session must still get its cards (§2.3 "already Stopped").
        link.interruptedProbe = { [weak self] in
            guard let self else { return false }
            return self.turn.interrupted && self.turn.stopTerminalPending
        }
        link.onChange = { [weak self] in self?.promptsChangedForChat() }
        link.onTimedOut = { [weak self] in self?.appendApprovalTimedOutNotice() }
        // A login saved after the bot stopped waiting for it: the bot reads its vault only while a turn runs, so the
        // chat says so (a running reply takes it as a steer, an idle chat starts a turn).
        link.onLoginSavedLate = { [weak self] site in self?.send(LateLogin.message(site: site)) }
        promptLink = link
        if let rid = runtimeSessionId { promptRuntimeBound(rid) }
        link.isObserving = observing
    }

    /// Called from `bindRuntime` (rule 8 lives in the centre).
    func promptRuntimeBound(_ runtime: String) {
        guard let link = promptLink, !link.covers(runtime) else { return }
        link.bind(runtime: runtime, profile: profile, profileParam: profileParam, storedId: storedSessionId ?? resolvedStoredId)
        if observing { link.center?.replayApprovals(runtime) }
    }

    /// Header words while a request waits (§3.6), after the link states and before "Working…".
    var promptStatusText: String? { promptLink?.prompts.needsInput?.statusText }

    /// `replay` false: a reconnect is about to confirm the runtime and replays the approvals itself (`approvalsConfirmed`).
    func promptsObserving(_ on: Bool, replay: Bool = true) {
        promptLink?.isObserving = on
        if on { if replay { promptsCameOnScreen() } else { probeOpenPrompts() } }
    }

    /// A reconnect's `session.activate` answered for this runtime (or its `session.resume` bound the one the link already
    /// had, which `promptRuntimeBound` skips): the chat on screen reads the approval queue now.
    func approvalsConfirmed(_ runtime: String) {
        guard observing else { return }
        promptLink?.center?.replayApprovals(runtime)
    }

    private func promptsChangedForChat() {
        changes.markState()
        scheduleFlush()
        promptLink?.screenOnChange?()
    }

    /// `request.cancel {reason: timeout}` for one of this chat's approvals: a local notice, never cached (§4.2).
    func appendApprovalTimedOutNotice() {
        localCounter += 1
        let id = "local-notice-approval-\(localCounter)"
        let text = "Approval timed out — the command was not run. Ask Hermes to try again."
        appendMessage(ChatMessage(id: id, role: .system, parts: [.text(text)], timestamp: Date(), rowId: nil))
        var meta = MessageMeta()
        meta.systemNotice = true
        meta.serverRowSpan = 0
        metaById[id] = meta
        scheduleFlush()
    }

    // MARK: ChatPrompting

    var prompts: ChatPrompts { promptLink?.prompts ?? ChatPrompts() }

    var onPromptsChange: (() -> Void)? {
        get { promptLink?.screenOnChange }
        set { promptLink?.screenOnChange = newValue }
    }

    func answerApproval(_ id: String, _ choice: ApprovalChoice) async throws {
        try await promptLink?.center?.answerApproval(id, choice)
    }

    func dismissExpiredApproval(_ id: String) { promptLink?.center?.dismissExpiredApproval(id) }

    func approvalTimeout(fresh: Bool) async -> TimeInterval {
        await promptLink?.center?.approvalTimeout(profile: profileParam, fresh: fresh) ?? ApprovalExpiry.defaultTimeout
    }

    func clarifyDraft(_ requestId: String) -> ClarifyDraft? { promptLink?.center?.draft(requestId) }

    func saveClarifyDraft(_ requestId: String, _ draft: ClarifyDraft) { promptLink?.center?.saveDraft(requestId, draft) }

    func sendClarify(_ requestId: String, answers: [(qid: String, answer: String?)]) async throws {
        try await promptLink?.center?.sendClarify(requestId, answers: answers)
    }

    func skipClarify(_ requestId: String) async throws { try await promptLink?.center?.skipClarify(requestId) }

    func answerValue(_ requestId: String, _ value: String) async throws {
        try await promptLink?.center?.answerValue(requestId, value)
    }

    func reconnectNow() { (client as? LiveGatewayClient)?.reconnectNow() }

    /// The chat came on screen (or back to the foreground with it open): probe what is still open, replay approvals.
    func promptsCameOnScreen() {
        guard let center = promptLink?.center, let rid = runtimeSessionId else { return }
        probeOpenPrompts()
        center.replayApprovals(rid)
    }

    /// Probes what is still open (without the approvals replay).
    private func probeOpenPrompts() {
        guard let center = promptLink?.center, let rid = runtimeSessionId else { return }
        let prompts = center.prompts(for: [rid])
        if prompts.clarify != nil || !prompts.values.isEmpty || prompts.approvals.contains(where: { $0.id.hasPrefix("srq-") }) {
            center.probeSoon(rid)
        }
    }
}
