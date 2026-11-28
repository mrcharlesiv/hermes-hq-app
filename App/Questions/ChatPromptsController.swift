import UIKit

// One chat screen's server requests (spec 1x §4): the approval card's rows and actions, the question dock in the
// composer's place, the password sheets and their chip. Owned by ChatViewController (`promptsUI`, hooks marked
// [questions] there); reads and answers through the chat's `ChatPrompting`. The sheets themselves live in the
// account's `PromptSheetStore` (they outlive this screen while their request is open).

@MainActor final class ChatPromptsController: QuestionDockDelegate, PromptSheetDelegate {
    private weak var chat: ChatViewController?
    let prompting: ChatPrompting
    private(set) var prompts = ChatPrompts()

    // Approval expiry (§4.2): the profile's timeout, when it was read, and which cards have expired.
    private var timeout: (value: TimeInterval, readAt: Date)?
    private var timeoutReading = false
    private var expired: Set<String> = []
    private var ticker: Timer?

    // The dock.
    private var dock: QuestionDockView?
    private let resumeDock = QuestionResumeView()
    /// [question-dictate] Dictation into the card's answer fields (#438).
    let dictation: QuestionDictation
    /// [questions] The settled card whose unanswered questions the dock is answering now (a live question takes the
    /// dock back from it).
    private var late: SettledClarifyCard?

    // Sheets and the chip (§4.5): the store keeps them by request id while open (the typed text survives a tuck and
    // leaving the chat).
    let sheets: PromptSheetStore
    private let ownsSheets: Bool
    /// The prompt this screen presented, and its frame (weak: UIKit holds it while it is up or going).
    private var presented: String?
    private weak var presentedNav: UINavigationController?
    /// The value prompts this screen last listed.
    private var shownValues: Set<String> = []
    /// Sheet answers this screen has on the wire (a second tap can't send again).
    private var answering: Set<String> = []
    /// Re-checks, while a prompt waits behind another sheet over the chat, whether it can come up now (Q14).
    private var slotTimer: Timer?
    private let chip = PromptChipView()
    private var chipShown = false
    private var installed = false
    /// DEBUG `-HQDebugTuckPrompts YES`: sheets start tucked (chip screenshots).
    var startTucked = false

    /// Which screen's controller listens to a chat's prompts (a chat reopened before its old screen went keeps the
    /// new screen's listener when the old one uninstalls).
    private static var listeners: [ObjectIdentifier: WeakController] = [:]
    private struct WeakController { weak var controller: ChatPromptsController? }

    init(chat: ChatViewController, prompting: ChatPrompting, sheets: PromptSheetStore? = nil) {
        self.chat = chat
        self.prompting = prompting
        self.sheets = sheets ?? PromptSheetStore()
        ownsSheets = sheets == nil
        dictation = QuestionDictation(screen: chat)
        #if DEBUG
        startTucked = UserDefaults.standard.bool(forKey: "HQDebugTuckPrompts")
        #endif
    }

    isolated deinit { uninstall() }

    /// Called once the chat's view exists.
    func install() {
        guard let chat else { return }
        installed = true
        chip.alpha = 0
        chip.isHidden = true
        chip.onTap = { [weak self] in self?.chipTapped() }
        chat.installPromptChip(chip)
        Self.listeners[ObjectIdentifier(prompting)] = WeakController(controller: self)
        prompting.onPromptsChange = { [weak self] in self?.refresh() }
        refresh()
    }

    /// The screen went: timers stop, a sheet it still shows is tucked (its text kept while the request is open), and
    /// it stops listening. Idempotent.
    func uninstall() {
        dictation.cancel(why: "the chat screen went")   // [question-dictate]
        ticker?.invalidate()
        ticker = nil
        slotTimer?.invalidate()
        slotTimer = nil
        if let id = presented {
            sheets.setTucked(id, true)
            if let nav = presentedNav { PromptSheetStore.dismiss(nav) }
        }
        presented = nil
        presentedNav = nil
        if ownsSheets { sheets.removeAll() }
        guard installed else { return }
        installed = false
        let key = ObjectIdentifier(prompting)
        if Self.listeners[key].map({ $0.controller == nil || $0.controller === self }) ?? true {
            Self.listeners[key] = nil
            prompting.onPromptsChange = nil
        }
    }

    // MARK: Rows

    /// What the row builder draws (the approval card and the question note).
    var rowsInput: PromptRowsInput? {
        var out = PromptRowsInput()
        let asker = (prompting as? ChatRoomSurface)?.promptAsker   // [groups] a room names the member who asks
        if let first = prompts.approvals.first {
            let total = max(prompts.approvalStackTotal, prompts.approvals.count)
            out.approval = ApprovalCardRow(
                id: first.id, stackExpired: prompts.approvals.allSatisfy { expired.contains($0.id) },
                command: first.command, description: first.description, showsDescription: first.showsDescription,
                position: max(1, total - prompts.approvals.count + 1), total: total, allowSession: first.allowSession,
                allowAlways: first.allowAlways, expired: expired.contains(first.id), answering: first.answering,
                leaving: first.leaving, clockKey: first.clockKey, firstSeen: first.firstSeen, asker: asker, botName: chat?.botName,
                kind: first.kind, path: first.path, access: first.access, host: first.host, label: first.label, risk: first.risk)
        }
        if let clarify = prompts.clarify {
            out.clarifyNote = .asked(count: clarify.questions.count,
                                     first: clarify.questions.first?.question ?? "",
                                     asker: asker,
                                     questions: clarify.questions.map(\.question))
            out.clarifyDockExpanded = dock?.prompt.id == clarify.id && dock?.draft.minimized == false
        } else if prompts.clarifyUndelivered {
            out.clarifyNote = .undelivered
        } else if let sent = prompts.sentClarify {
            out.clarifyNote = .sent(sent.rows)
        }
        return out.approval == nil && out.clarifyNote == nil ? nil : out
    }

    // MARK: Changes

    func refresh() {
        let previous = prompts
        prompts = prompting.prompts
        expired = expired.filter { id in prompts.approvals.contains { $0.id == id } }
        updateTicker()
        if !prompts.approvals.isEmpty && timeout == nil { readTimeout(fresh: false) }
        if let first = prompts.approvals.first, !first.leaving {
            if lastDisplayedApprovalId != first.id {
                lastDisplayedApprovalId = first.id
                prompting.approvalDisplayed(first.id)
            }
        } else {
            lastDisplayedApprovalId = nil
        }
        updateDock(animated: previous.clarify?.id != prompts.clarify?.id)
        updateSheets()
        dropStaleConfirm()
        // An answered card that faded out now goes: the rows above glide into its place.
        let closing = previous.approvals.first?.leaving == true && prompts.approvals.first?.id != previous.approvals.first?.id
        chat?.promptsDidChange(closingGap: closing)
    }

    // MARK: Approval card

    private func updateTicker() {
        let needed = !prompts.approvals.isEmpty
        if needed, ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !needed {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func readTimeout(fresh: Bool) {
        guard !timeoutReading else { return }
        timeoutReading = true
        let asked = Date()
        Task { [weak self] in
            guard let self else { return }
            let value = await self.prompting.approvalTimeout(fresh: fresh)
            self.timeoutReading = false
            self.timeout = (value, asked)
            self.tick()
        }
    }

    /// Once a second: a card whose count ran out on a timeout read before it was due reads it again; only then is it
    /// Expired (its row is rebuilt then, because its height changes).
    private func tick() {
        guard let timeout else { return }
        var changed = false
        for approval in prompts.approvals {
            let (label, stale) = ApprovalExpiry.countdown(seenAt: approval.firstSeen, timeout: timeout.value, readAt: timeout.readAt)
            if stale { readTimeout(fresh: true) }
            if label == ApprovalExpiry.expired, !expired.contains(approval.id) {
                expired.insert(approval.id)
                NotificationHub.shared.withdrawLocal(requests: [approval.id])   // UX study #257: no live Approve left on it
                changed = true
            }
        }
        if changed { chat?.promptsDidChange() }
    }

    func expiryLabel(firstSeen: Date) -> String {
        guard let timeout else { return "" }
        return ApprovalExpiry.countdown(seenAt: firstSeen, timeout: timeout.value, readAt: timeout.readAt).label
    }

    func cardTapped(_ id: String, _ button: ApprovalButton) {
        switch button {
        case .run: answer(id, .once)
        case .reject:
            if let approval = prompts.approvals.first(where: { $0.id == id }), approval.isSandbox {
                confirmSandboxDeny(approval)
            } else {
                answer(id, .deny)
            }
        case .session: answer(id, .session)
        case .always: confirmAlways(id)
        case .dismiss: prompting.dismissExpiredApproval(id)
        case .more: break
        }
    }

    /// [v0.23.4] Sandbox folder/website denials accept an optional reason string sent back to the sandbox.
    private func confirmSandboxDeny(_ approval: ApprovalPrompt) {
        guard let chat else { answer(approval.id, .deny); return }
        let target = approval.kind == .access ? (approval.path ?? "this folder") : (approval.label ?? approval.host ?? "this website")
        let title = approval.kind == .access ? "Deny Folder Access?" : "Deny Website Access?"
        let alert = UIAlertController(title: title, message: "You can optionally tell \(chat.botName) why \(target) was denied.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Reason (optional)"
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Deny", style: .destructive) { [weak self, weak alert] _ in
            let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = raw.map { String($0.prefix(500)) }
            self?.answer(approval.id, .deny, reason: reason)
        })
        alwaysConfirm = (approval.id, alert)
        chat.present(alert, animated: true)
    }

    private func confirmAlways(_ id: String) {
        guard let chat, let approval = prompts.approvals.first(where: { $0.id == id }) else { return }
        let title: String
        var message: String
        switch approval.kind {
        case .access:
            title = "Always Allow Folder Access?"
            let accessPhrase: String = switch approval.access {
            case .readWrite: "read and write access"
            case .read: "read-only access"
            case nil: "access"
            }
            message = "\(chat.botName) will always have \(accessPhrase) to this folder in its sandbox."
            if let path = approval.path, !path.isEmpty { message += "\n\n\(path)" }
        case .network:
            title = "Always Allow Website Access?"
            let site = approval.label ?? approval.host ?? "this website"
            message = "\(chat.botName) will always be allowed to reach \(site) from its sandbox."
            if let host = approval.host, !host.isEmpty, host != site { message += "\n\n\(host)" }
        case .command:
            title = "Always Allow This Command?"
            let command = approval.command.trimmingCharacters(in: .whitespacesAndNewlines)
            message = "\(chat.botName) won’t ask again before running commands that match “\(approval.description)” — in this chat or any other, from now on."
            if !command.isEmpty { message += "\n\n\(command)" }
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Always Allow", style: .destructive) { [weak self] _ in self?.answer(id, .always) })
        alwaysConfirm = (id, alert)
        chat.present(alert, animated: true)
    }

    /// Verify round 3: the Always allow confirm, while it is up. It goes as soon as its approval is answered elsewhere
    /// (or expires): a tap on it then would allow nothing while feeling like a permanent rule was written.
    private var alwaysConfirm: (id: String, alert: UIAlertController)?
    private var lastDisplayedApprovalId: String?

    /// The "Skip All Questions?" confirm, while it is up: it goes as soon as its questions are answered or withdrawn
    /// elsewhere (its buttons would do nothing, and a password sheet for this chat waits behind it).
    private var skipConfirm: (id: String, alert: UIAlertController)?

    private func dropStaleConfirm() {
        if let confirm = alwaysConfirm {
            let showing = confirm.alert.presentingViewController != nil && !confirm.alert.isBeingDismissed
            if !(showing && isOpen(confirm.id)) {
                alwaysConfirm = nil
                if showing { confirm.alert.dismiss(animated: true) }
            }
        }
        if let confirm = skipConfirm {
            let showing = confirm.alert.presentingViewController != nil && !confirm.alert.isBeingDismissed
            let open = prompts.clarify?.id == confirm.id
            if !(showing && open) {
                skipConfirm = nil
                if showing { confirm.alert.dismiss(animated: true) }
            }
        }
    }

    /// Whether an approval still waits for this phone's answer (not answered elsewhere, not already being answered).
    private func isOpen(_ id: String) -> Bool {
        prompts.approvals.contains { $0.id == id && $0.answering == nil && !$0.leaving }
    }

    private func answer(_ id: String, _ choice: ApprovalChoice, reason: String? = nil) {
        // Answered elsewhere meanwhile: nothing is sent, so nothing confirms it (no success tap, no allowlist rule).
        guard isOpen(id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prompting.answerApproval(id, choice, reason: reason)
                // Allowing plays success; Reject is silent (MEM:taptic-feedback-gaps).
                if choice != .deny { Haptics.play(.success) }
            } catch {
                self.failed(error, fallback: ServerRequestCenter.approvalFailed)
            }
        }
    }

    /// A failed answer (§4.7): the toast, with Reconnect when Hermes is offline, and the error haptic the web's error
    /// toasts play (MEM:taptic-feedback-gaps: replacing a toast must not lose it).
    private func failed(_ error: Error, fallback: String) {
        let answerError = error as? PromptAnswerError
        Haptics.play(.error)
        let action: (title: String, handler: () -> Void)? = answerError?.offline == true
            ? ("Reconnect", { [weak self] in self?.prompting.reconnectNow() }) : nil
        chat?.showNotice(answerError?.message ?? fallback, action: action)
    }

    func showAll(_ id: String) {
        guard let chat, let approval = prompts.approvals.first(where: { $0.id == id }) else { return }
        if approval.showsDescription {
            let blocks = ChatBlocksViewController(heading: nil, blocks: [.init(label: "Command details", text: approval.description)])
            chat.present(ChatSheet.wrap(blocks, title: "Command"), animated: true)
        } else {
            chat.present(PromptCommandBlock.wholeCommandSheet(approval.command), animated: true)
        }
    }

    // MARK: Dock (§4.3)

    private func updateDock(animated: Bool) {
        guard let chat else { return }
        if prompts.clarify != nil { late = nil }
        if late != nil, dock?.later == true { return }
        if let clarify = prompts.clarify {
            if let dock, dock.prompt.id == clarify.id {
                dock.sending = clarify.sending ? (dock.sending == .none ? .send : dock.sending) : .none
                // A reconnect's replay may bring locks the gateway already holds: they fill the questions the user
                // hasn't touched (§4.3).
                if dock.mergeReplayed(clarify.lockedAnswers) { prompting.saveClarifyDraft(clarify.id, dock.draft) }
                return
            }
            let draft = ClarifyStaging.initialDraft(clarify, saved: prompting.clarifyDraft(clarify.id))
            let view = QuestionDockView(prompt: clarify, draft: draft)
            adopt(view)
            prompting.saveClarifyDraft(clarify.id, draft)
            dock = view
            showQuestionDock(view, animated: animated)
        } else if let gone = dock {
            dock = nil
            // The bot stopped waiting (its clarify timeout, a Stop, a reconnect's prune) while answers were being typed:
            // they stay in the dock, now as Answer Now's, and Send puts them in the chat (a tester lost a whole
            // interview's answers to the 90 s default).
            if keepAnswering(gone) { return }
            chat.setDock(nil, for: .question, animated: true)
        }
    }

    /// Every new dock: this controller answers it, and [question-dictate] its answer fields can be dictated into.
    private func adopt(_ view: QuestionDockView) {
        view.delegate = self
        view.dictation = dictation
    }

    // MARK: [question-dictate] Dictation into the card (#438)

    /// A question card (or its minimized bar) stands in the composer's place: Dictate with Hermes types into the card.
    var coversComposer: Bool { dock != nil }
    /// A take types into the card now (Read Replies Aloud waits behind it).
    var cardDictating: Bool { dictation.isActive }
    /// Dictate with Hermes (⇧⌘D on the Mac) can start for the card: one is up, not on its way, and no dictation runs.
    var canDictateIntoCard: Bool { (dock.map { $0.sending == .none } ?? false) && dictation.canBegin }

    /// Dictate with Hermes, or a failure card's Try Again, while the card covers the composer: into the field that last
    /// dictated, else the shown page's ("Something else…" opened for it). A minimized card opens first.
    func dictateIntoCard() {
        guard let dock, dock.sending == .none, !dictation.isActive else { return }
        if dock.draft.minimized {
            dock.setMinimized(false)
            showQuestionDock(dock, animated: true)
            chat?.promptsDidChange()
        }
        dictation.retry { [weak dock] in dock?.fieldForDictation() }
    }

    /// A live dock that went unsent with something typed or picked comes back as a later dock holding the same draft.
    /// Its card is the settled one for the same questions (looked up again at Send, when it has arrived).
    private func keepAnswering(_ gone: QuestionDockView) -> Bool {
        guard let chat, !gone.later, gone.sending == .none, Self.hasAnswers(gone.draft) else { return false }
        let questions = gone.prompt.questions
        let rows = questions.map { ClarifyQA(question: $0.question, answer: "", unanswered: true, choices: $0.choices) }
        let key = ClarifyLate.key(questions.map(\.question))
        let multi = Set(questions.filter(\.multiSelect).map { ClarifyLate.flat($0.question) })
        late = SettledClarifyCard(rows: rows, key: key, messageId: "", multi: multi, answerable: true, answeredLater: false)
        let typing = gone.isEditingText
        let view = QuestionDockView(prompt: ClarifyPrompt(id: "late|\(key)", questions: questions), draft: gone.draft, later: true)
        adopt(view)
        dock = view
        AppLog.trace("questions", "clarify \(AppLog.tag(gone.prompt.id)) ended unsent with answers typed: kept as Answer Now")
        // Mid-typing, the keyboard stays up on the same question.
        showQuestionDock(view, animated: false)
        if typing, !gone.draft.minimized { view.focusShownField() }
        return true
    }

    static func hasAnswers(_ draft: ClarifyDraft) -> Bool {
        draft.stages.values.contains { !$0.choices.isEmpty || !$0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Swap only the presentation. Keep the same dock (fields, scroll and picks) and save its minimized state by
    /// request id, so a reconnect or leaving and reopening this chat does not cover the transcript again.
    private func showQuestionDock(_ dock: QuestionDockView, animated: Bool) {
        if dock.draft.minimized {
            resumeDock.show(dock)
            resumeDock.onTap = { [weak self, weak dock] in
                guard let self, let dock, self.dock === dock, dock.draft.minimized else { return }
                dock.setMinimized(false)
                Haptics.play(.selection)
                self.showQuestionDock(dock, animated: true)
                self.chat?.promptsDidChange()
                UIAccessibility.post(notification: .layoutChanged, argument: dock)
            }
        }
        chat?.setDock(dock.draft.minimized ? resumeDock : dock, for: .question, animated: animated)
        #if targetEnvironment(macCatalyst)
        // A rapid reopen can reinsert the same view before it leaves the window; didMoveToWindow need not run.
        if !dock.draft.minimized { dock.takeKeys() }
        #endif
    }

    func dockMinimize(_ dock: QuestionDockView) {
        guard self.dock === dock, dock.sending == .none, !dock.draft.minimized else { return }
        dock.setMinimized(true)
        Haptics.play(.selection)
        showQuestionDock(dock, animated: true)
        chat?.promptsDidChange()
        resumeDock.announce()
    }

    func dockExplain(_ dock: QuestionDockView) {
        guard self.dock === dock, dock.sending == .none, !dock.later else { return }
        Haptics.play(.selection)
        dock.stageExplainFirst()
        dockSend(dock)
    }

    func dockSend(_ dock: QuestionDockView) {
        guard dock.sending == .none else { return }
        if dock.later { return sendLater(dock) }
        dock.sending = .send
        let id = dock.prompt.id
        prompting.saveClarifyDraft(id, dock.draft)
        let answers = dock.answers
        dock.endEditing(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prompting.sendClarify(id, answers: answers)
            } catch {
                dock.sending = .none
                self.failed(error, fallback: ServerRequestCenter.clarifyFailed)
            }
        }
    }

    func dockSkip(_ dock: QuestionDockView) {
        guard dock.sending == .none else { return }
        if dock.later { return closeLater() }
        // Skip cancels every question, so answers already given would be lost: it asks first.
        guard dock.prompt.questions.count > 1, dock.answeredCount > 0, let chat else { return skip(dock) }
        let alert = UIAlertController(title: "Skip All Questions?",
                                      message: "The answers you’ve given so far won’t be sent.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Skip All", style: .destructive) { [weak self, weak dock] _ in
            guard let self, let dock, dock.window != nil else { return }
            self.skip(dock)
        })
        skipConfirm = (dock.prompt.id, alert)
        chat.present(alert, animated: true)
    }

    private func skip(_ dock: QuestionDockView) {
        guard dock.sending == .none else { return }
        dock.sending = .skip
        dock.endEditing(true)
        let id = dock.prompt.id
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prompting.skipClarify(id)
            } catch {
                dock.sending = .none
                self.failed(error, fallback: ServerRequestCenter.clarifyFailed)
            }
        }
    }

    func dockDraftChanged(_ dock: QuestionDockView) {
        guard !dock.later else { return }   // its picks live in the dock until Send or Cancel
        prompting.saveClarifyDraft(dock.prompt.id, dock.draft)
    }

    // MARK: Answer Now ([questions])

    /// Answer Now on a settled card: its unanswered questions come back in the dock, with the choices they offered.
    /// The bot's clarify call is long over, so Send puts the answers in the chat as a message of yours naming the card
    /// (`ClarifyLate.message`); the card then shows them. A live question owns the dock and wins.
    func answerLater(_ card: SettledClarifyCard) {
        guard let chat, prompts.clarify == nil else { return }
        if let dock, dock.later, late?.key == card.key {
            if dock.draft.minimized {
                dock.setMinimized(false)
                showQuestionDock(dock, animated: true)
            }
            return
        }
        let open = card.rows.filter { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !open.isEmpty else { return }
        let questions = open.enumerated().map { i, row in
            let choices = (row.choices ?? []).filter { $0.count <= ClarifyText.maxChoiceChars }
            return ClarifyQuestion(qid: "q\(i)", question: row.question, choices: choices.isEmpty ? nil : choices,
                                   multiSelect: !choices.isEmpty && card.multi.contains(ClarifyLate.flat(row.question)))
        }
        Haptics.play(.selection)
        AppLog.trace("questions", "answer later \(card.key) (\(questions.count) question(s))")
        late = card
        let view = QuestionDockView(prompt: ClarifyPrompt(id: "late|\(card.key)", questions: questions), draft: ClarifyDraft(), later: true)
        adopt(view)
        dock = view
        chat.setDock(view, for: .question, animated: true)
    }

    private func sendLater(_ dock: QuestionDockView) {
        guard let card = late, let chat else { return closeLater() }
        let rows = ClarifyStaging.sentRows(dock.prompt.questions, dock.draft.stages)
        let answers = rows.compactMap { row in row.answer.map { (question: row.question, answer: $0) } }
            .filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !answers.isEmpty else { return }
        dock.endEditing(true)
        closeLater()
        // A dock kept from a live question has no card yet: its settled card, by the same questions. One whose
        // questions all got answers was answered on the live request (another device): nothing more to send.
        var messageId = card.messageId
        if messageId.isEmpty, let found = chat.settledClarify(key: card.key) {
            messageId = found.messageId
            if !found.hasBlank {
                AppLog.trace("questions", "kept answers for \(card.key) not sent: the question was answered on its request")
                return
            }
        }
        chat.sendLateAnswer(ClarifyLate.message(key: card.key, answers: answers), messageId: messageId)
    }

    private func closeLater() {
        late = nil
        guard dock?.later == true else { return }
        dock?.endEditing(true)
        dock = nil
        chat?.setDock(nil, for: .question, animated: true)
        updateDock(animated: true)
    }

    var dockView: QuestionDockView? { dock }

    // MARK: Sheets and the chip (§4.5)

    private func updateSheets() {
        let open = Set(prompts.values.map(\.id))
        // Answered or withdrawn while this screen showed it: it goes without a chip, and the next untucked one comes up
        // once it is gone. A sheet whose answer is on its way stays up (§2.3).
        if let id = presented, !open.contains(id) {
            presented = nil
            if let nav = presentedNav {
                PromptSheetStore.dismiss(nav) { [weak self] in self?.presentNextIfPossible() }
            }
            presentedNav = nil
        }
        // This chat's requests that went: their sheets are cleared and released (the account's centre reports the same
        // through `onRemoved`; a screen-owned store has only this).
        let gone = shownValues.subtracting(open)
        if !gone.isEmpty { sheets.drop(gone) }
        shownValues = open
        for value in prompts.values {
            let (sheet, created) = sheets.sheet(for: value, botName: chat?.botName)
            sheet.delegate = self
            if created && startTucked { sheets.setTucked(value.id, true) }
            sheet.setSending(value.sending || answering.contains(value.id))
        }
        presentNextIfPossible()
        updateChip()
    }

    /// The oldest untucked prompt, when this chat is on screen and nothing else is presented over it (Q14). Behind
    /// another sheet (Info, a step, Show All, an alert) it waits and comes up as soon as that one goes.
    private func presentNextIfPossible(preferring preferred: String? = nil) {
        let next = preferred.flatMap { id in prompts.values.first { $0.id == id } } ?? prompts.values.first { !sheets.isTucked($0.id) }
        guard presented == nil, let chat, chat.view.window != nil, chat.navigationController?.topViewController === chat,
              let next, let nav = sheets.navigation(next.id) else {
            updateChip()
            return
        }
        // Something else is up (or our own frame is still finishing a tuck): try again when it has gone.
        guard chat.presentedViewController == nil, nav.presentingViewController == nil else {
            waitForSlot()
            updateChip()
            return
        }
        slotTimer?.invalidate()
        slotTimer = nil
        presented = next.id
        presentedNav = nav
        sheets.setTucked(next.id, false)
        chat.view.endEditing(true)
        chat.present(nav, animated: true)
        updateChip()
    }

    private func waitForSlot() {
        guard slotTimer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.slotTick() } }
        RunLoop.main.add(timer, forMode: .common)
        slotTimer = timer
    }

    private func slotTick() {
        guard presented == nil, let chat, chat.view.window != nil, prompts.values.contains(where: { !sheets.isTucked($0.id) }) else {
            // Nothing waits, or the chat left the screen (its next appearance tries again).
            slotTimer?.invalidate()
            slotTimer = nil
            return
        }
        guard chat.presentedViewController == nil else { return }
        slotTimer?.invalidate()
        slotTimer = nil
        presentNextIfPossible()
    }

    /// The chat came on screen, or a sheet over it went: maybe a waiting prompt can show now.
    func chatAppeared() { presentNextIfPossible() }

    /// The prompt the chip stands for: the oldest tucked one, or (no sheet of ours up) one that couldn't be shown.
    private var chipPromptId: String?

    private func updateChip() {
        let candidates = prompts.values.filter { $0.id != presented }
        let waiting = candidates.first { sheets.isTucked($0.id) } ?? (presented == nil ? candidates.first : nil)
        let show = presented == nil && waiting != nil
        chipPromptId = show ? waiting?.id : nil
        if let waiting { chip.set(PromptSheetCopy.make(waiting).chip) }
        guard show != chipShown else { return }
        chipShown = show
        if show { chip.isHidden = false }
        let animate = chat?.view.window != nil && !HQMotion.reduced
        let change = {
            self.chip.alpha = show ? 1 : 0
            self.chat?.promptChipChanged()
        }
        let done: (Bool) -> Void = { _ in
            if !self.chipShown { self.chip.isHidden = true }
            self.chat?.promptChipChanged()
        }
        if animate { UIView.animate(withDuration: HQMotion.fade, animations: change, completion: done) } else { change(); done(true) }   // motion-ok: `animate` is false under Reduce Motion
    }

    private func chipTapped() {
        guard let id = chipPromptId else { return }
        sheets.setTucked(id, false)
        presentNextIfPossible(preferring: id)
    }

    /// Primary or the red decline. The sheet stays up, its text kept, until the answer is sent; the request's removal
    /// then dismisses it (and the store clears the text). A failure re-enables it (§2.3, §4.7).
    func promptSheet(_ sheet: PromptSheetController, answer value: String) {
        let id = sheet.prompt.id
        guard !answering.contains(id) else { return }
        answering.insert(id)
        sheet.setSending(true)
        Task { [weak self] in
            guard let self else { return }
            defer { self.answering.remove(id) }
            do {
                try await self.prompting.answerValue(id, value)
            } catch {
                self.sheets.existing(id)?.setSending(false)
                self.failed(error, fallback: ServerRequestCenter.valueFailed(sheet.prompt.kind))
            }
        }
    }

    func promptSheetTucked(_ sheet: PromptSheetController) {
        let id = sheet.prompt.id
        guard sheets.existing(id) === sheet else { return }
        sheets.setTucked(id, true)
        if presented == id {
            presented = nil
            presentedNav = nil
        }
        updateChip()
    }

    #if DEBUG
    var debugChipText: String? { chipShown ? chip.text : nil }
    var debugPresented: String? { presented }
    #endif
}
