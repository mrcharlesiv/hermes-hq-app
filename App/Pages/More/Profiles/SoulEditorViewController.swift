// A profile's SOUL.md, shown to users as "Instructions" (docs/spec/3x-morepages.md §10): read-only at first with Edit on the bar; Edit puts Cancel and
// Save there (`NavEditBar`) and brings the keyboard. Save reads the file again first (it may have changed on the
// gateway), then writes it. A refused Save shows a notice above the text with Try Again; nothing typed is lost. What
// is typed is also kept in Caches on every pause, and offered back when the editor opens after the app went away.
// The text is a prompt file: no autocorrect, no smart punctuation. It never goes to the log.

import UIKit

final class SoulEditorViewController: UIViewController, UITextViewDelegate, EscapeCancelling {
    private let context: MorePages.Context
    private let api: ProfilesAPI
    private let profile: String
    private let botName: String
    private let drafts: SoulDraftStore
    private let readOnly: Bool

    private let textView = SoulTextView()
    private let placeholder = UILabel()
    private let notice = SoulNoticeView()
    private lazy var editBar = NavEditBar(host: self, onCancel: { [weak self] in self?.cancel() }, onSave: { [weak self] in self?.save() })
    private lazy var editItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Edit", primaryAction: UIAction { [weak self] _ in
            PagesHaptics.selection()
            self?.beginEditing()
        })
        item.accessibilityIdentifier = "soul.edit"
        return item
    }()

    /// The gateway's text this page shows at rest and an edit is compared with.
    private var baseText = ""
    /// What a Save checks the gateway's file against (a restored draft keeps the base it was typed over).
    private var baseHash = SoulDraft.hash("")
    private var baseExists = false
    /// The gateway's newer file a Save found and you didn't replace (Cancel): Discard goes back to it, not the old text.
    private var theirs: SoulDocument?
    private var loaded = false
    private var saving = false
    private var dirty = false
    private var failure: String?
    private var online: Bool
    private var loadTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var linkTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(context: MorePages.Context, profile: String, botName: String, drafts: SoulDraftStore = .standard) {
        self.context = context
        self.profile = profile
        self.botName = botName
        self.drafts = drafts
        api = ProfilesAPI(client: context.client)
        online = context.isOnline
        readOnly = ProfilesAccess.readOnly(context)
        super.init(nibName: nil, bundle: nil)
        title = "Instructions"
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        view.accessibilityIdentifier = "soul.page"

        textView.backgroundColor = .clear
        textView.textColor = HQPalette.label
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: HQFont.mono(ofSize: 15, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.isEditable = false
        textView.isSelectable = true
        // A prompt file: the keyboard never rewrites what was typed.
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.delegate = self
        textView.accessibilityIdentifier = "soul.text"
        textView.accessibilityLabel = "Instructions"
        textView.isHidden = true

        placeholder.text = SoulRules.placeholder
        // A hint, not the file's text: the body face, not the editor's code face (it read as the file's contents).
        placeholder.font = HQFont.preferred(.body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = HQPalette.label3
        placeholder.numberOfLines = 0
        placeholder.isHidden = true
        placeholder.accessibilityIdentifier = "soul.placeholder"

        notice.isHidden = true
        notice.onRetry = { [weak self] in self?.save() }

        let stack = UIStackView(arrangedSubviews: [notice, textView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(placeholder)
        // Keyboard down: the text runs to the bottom of the page (under the tab bar, inset by the system).
        // Keyboard up: it ends at the keyboard, so the last line and the caret stay in sight.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 21),
            placeholder.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -21),
        ])

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepDraftNow() }
        })
        load()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        editBar.hostDidAppear()
        linkTimer?.invalidate()
        linkTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.linkTick() }
        }
        linkTick()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        editBar.hostWillDisappear()
        // Leaving with an edit open (another tab, a gateway switch): what was typed is kept for the next visit.
        keepDraftNow()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        linkTimer?.invalidate()
        linkTimer = nil
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func linkTick() {
        let now = context.isOnline
        guard now != online else { return }
        online = now
        refresh()
        if now, !loaded, loadTask == nil { load() }
    }

    // MARK: Reading

    private func load() {
        loadTask?.cancel()
        var loading = UIContentUnavailableConfiguration.loading().hqScaled()
        loading.text = "Loading Instructions…"
        contentUnavailableConfiguration = loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await self.api.soul(self.profile)
                guard !Task.isCancelled else { return }
                self.loadTask = nil
                self.show(document)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.loadTask = nil
                let gone = (error as? HTTPError)?.status == 404
                self.contentUnavailableConfiguration = PageStates.error(
                    title: "Couldn’t Load Instructions",
                    reason: gone ? "This bot isn’t on your gateway any more." : PagesREST.reason(error)) { [weak self] in self?.load() }
            }
        }
    }

    private func show(_ document: SoulDocument) {
        contentUnavailableConfiguration = nil
        baseText = document.content
        baseHash = SoulDraft.hash(document.content)
        baseExists = document.exists
        loaded = true
        textView.text = document.content
        textView.isHidden = false
        theirs = nil
        dirty = false
        refresh()
        offerDraft()
    }

    /// A draft kept from an edit the app left: offered back when it says something the gateway's file does not.
    private func offerDraft() {
        let account = context.account.id
        guard let draft = drafts.read(account: account, profile: profile) else { return }
        guard !readOnly else { return }      // kept for a session that can write
        guard SoulRules.draftOffer(draft, server: baseText) == .offer else {
            drafts.remove(account: account, profile: profile)
            return
        }
        let alert = UIAlertController(title: "Restore Unsaved Changes?",
                                      message: "You were editing \(botName)’s Instructions and your changes were not saved.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.drafts.remove(account: account, profile: self.profile)
        })
        let restore = UIAlertAction(title: "Restore", style: .default) { [weak self] _ in
            guard let self, self.loaded, !self.editBar.isEditing else { return }
            // The Save that follows checks the gateway's file against what the draft was typed over.
            self.baseHash = draft.baseHash
            self.beginEditing()
            self.textView.text = draft.text
            self.moveCaretToEnd()
            self.textChanged(keepDraft: false)
        }
        alert.addAction(restore)
        alert.preferredAction = restore
        FailureAlert.topmost(self)?.present(alert, animated: true)
    }

    // MARK: Editing

    private var canEdit: Bool { loaded && !readOnly }

    private func beginEditing() {
        guard canEdit, !editBar.isEditing else { return }
        failure = nil
        editBar.begin()
        textView.isEditable = true
        textView.becomeFirstResponder()
        moveCaretToEnd()
        refresh()
    }

    /// The caret starts after the last line, in sight above the keyboard.
    private func moveCaretToEnd() {
        let end = NSRange(location: textView.textStorage.length, length: 0)
        textView.selectedRange = end
        textView.scrollRangeToVisible(end)
    }

    private func endEditing() {
        draftTask?.cancel()
        draftTask = nil
        textView.resignFirstResponder()
        textView.isEditable = false
        failure = nil
        saving = false
        dirty = false
        editBar.end()
        refresh()
    }

    func textViewDidChange(_ textView: UITextView) { textChanged(keepDraft: true) }

    private func textChanged(keepDraft: Bool) {
        dirty = textView.textStorage.length != (baseText as NSString).length || textView.text != baseText
        refresh()
        guard keepDraft, editBar.isEditing else { return }
        // Written on every pause in typing (1 s).
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.keepDraftNow()
        }
    }

    /// The draft file follows the editor: written while there are unsaved changes, removed when there are none.
    private func keepDraftNow() {
        guard editBar.isEditing, loaded else { return }
        draftTask?.cancel()
        draftTask = nil
        let account = context.account.id, profile = profile, drafts = drafts
        guard dirty else {
            drafts.remove(account: account, profile: profile)
            return
        }
        let draft = SoulDraft(text: textView.text ?? "", baseHash: baseHash)
        // Off the main thread: a large file must not hold a keystroke.
        Task.detached(priority: .utility) { drafts.write(draft, account: account, profile: profile) }
    }

    // MARK: Cancel

    private func cancel() {
        guard editBar.isEditing, !saving else { return }
        PagesHaptics.selection()
        guard dirty else { endEditing(); return }
        guard presentedViewController == nil else { return }
        // An alert, as the app's other editors ask (ConnectorPageController): on iOS 26 an action sheet from a bar
        // button is a popover without its cancel button, and Keep Editing must be there to tap.
        let alert = UIAlertController(title: SoulRules.discardTitle, message: SoulRules.discardMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SoulRules.discardConfirm, style: .destructive) { [weak self] _ in self?.discard() })
        alert.addAction(UIAlertAction(title: SoulRules.discardCancel, style: .cancel))
        present(alert, animated: true)
    }

    private func discard() {
        guard editBar.isEditing, !saving else { return }
        PagesHaptics.selection()
        if let theirs { adopt(theirs); return }
        textView.text = baseText
        baseHash = SoulDraft.hash(baseText)
        drafts.remove(account: context.account.id, profile: profile)
        endEditing()
    }

    /// Hardware Escape while editing runs Cancel (with the Discard question when there are changes), never a plain Back.
    func escapeCancel() -> Bool {
        guard editBar.isEditing else { return false }
        cancel()
        return true
    }

    // MARK: Save

    private func save() {
        guard editBar.isEditing, !saving, dirty || failure != nil else { return }
        let sent = textView.text ?? ""
        saving = true
        failure = nil
        refresh()
        Task { [weak self] in
            guard let self else { return }
            do {
                // Read first: someone else may have changed the file since this edit began.
                let now = try await self.api.soul(self.profile)
                if now.exists, now.content == sent {
                    self.saved(sent)        // an earlier Save landed although its answer was lost
                    return
                }
                if SoulRules.changedOnGateway(baseHash: self.baseHash, baseExists: self.baseExists, now: now) {
                    self.saving = false
                    self.refresh()
                    self.askReplace(now)
                    return
                }
                try await self.api.saveSoul(self.profile, content: sent)
                self.saved(sent)
            } catch {
                self.saving = false
                self.failure = SoulRules.saveReason(error)
                PagesHaptics.error()
                self.refresh()
                UIAccessibility.post(notification: .layoutChanged, argument: self.notice)
            }
        }
    }

    private func saved(_ sent: String) {
        saving = false
        baseText = sent
        baseHash = SoulDraft.hash(sent)
        baseExists = true
        theirs = nil
        drafts.remove(account: context.account.id, profile: profile)
        PagesHaptics.success()
        PagesHUD.show("Instructions Saved", symbol: "checkmark", from: self)
        if textView.text == sent {
            endEditing()
        } else {
            textChanged(keepDraft: true)    // something was typed while the Save was out: the edit goes on
        }
    }

    /// Replace It saves yours over theirs; Use Their Version drops your edit and shows the gateway's file; Cancel keeps
    /// editing (a later Discard goes back to their version).
    private func askReplace(_ now: SoulDocument) {
        theirs = now
        let alert = UIAlertController(title: "Instructions Changed on Your Gateway",
                                      message: "Someone else changed this file since you opened it.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Replace It", style: .destructive) { [weak self] _ in
            guard let self else { return }
            PagesHaptics.selection()
            self.baseHash = SoulDraft.hash(now.content)
            self.baseExists = now.exists
            self.save()
        })
        alert.addAction(UIAlertAction(title: "Use Their Version", style: .default) { [weak self] _ in
            PagesHaptics.selection()
            self?.adopt(now)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        FailureAlert.topmost(self)?.present(alert, animated: true)
    }

    /// The gateway's file becomes the page's text and base; your edit (and its kept draft) is dropped.
    private func adopt(_ document: SoulDocument) {
        drafts.remove(account: context.account.id, profile: profile)
        endEditing()
        show(document)
    }

    // MARK: Drawing the state

    private func refresh() {
        if editBar.isEditing {
            editBar.update(dirty: dirty || failure != nil, saving: saving)
        } else {
            let wanted = canEdit ? [editItem] : nil
            if navigationItem.rightBarButtonItems ?? [] != wanted ?? [] { navigationItem.rightBarButtonItems = wanted }
            editItem.isEnabled = online
        }
        placeholder.isHidden = !loaded || textView.textStorage.length > 0
        if let failure, editBar.isEditing {
            notice.showFailure(title: "Couldn’t Save Instructions", reason: failure)
        } else if loaded, !readOnly, !online, !editBar.isEditing {
            notice.showInfo(MorePages.offlineFooter)
        } else {
            notice.isHidden = true
        }
    }
}

/// The notice pinned above the text: a refused Save ("Couldn’t Save Instructions", the reason, Try Again), or why Edit is off.
final class SoulNoticeView: UIView {
    var onRetry: (() -> Void)?
    private let card = UIView()
    private let titleLabel = UILabel()
    private let reasonLabel = UILabel()
    private let retry = UIButton(configuration: .tinted())

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = HQPalette.card   // a card on the grouped page, as a list row is
        card.layer.cornerRadius = HQShape.radius(16, .card)
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        titleLabel.font = HQFont.preferred(.headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = HQPalette.red
        titleLabel.numberOfLines = 0
        reasonLabel.font = HQFont.preferred(.subheadline)
        reasonLabel.adjustsFontForContentSizeCategory = true
        reasonLabel.textColor = HQPalette.label
        reasonLabel.numberOfLines = 4
        var config = UIButton.Configuration.hqMacPush(or: .tinted(), capsule: true)   // [mac] Stress test 2026-10-28 #55 (round 6)
        config.title = "Try Again"
        if !DeviceWord.isMac { config.buttonSize = .small }
        retry.configuration = config
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)
        retry.accessibilityIdentifier = "soul.save-failure.retry"
        retry.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [titleLabel, reasonLabel, retry])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: reasonLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        accessibilityContainerType = .semanticGroup
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func showFailure(title: String, reason: String) {
        titleLabel.text = title
        titleLabel.isHidden = false
        reasonLabel.text = reason
        reasonLabel.textColor = HQPalette.label
        retry.isHidden = false
        accessibilityIdentifier = "soul.save-failure"
        isHidden = false
    }

    func showInfo(_ text: String) {
        titleLabel.isHidden = true
        reasonLabel.text = text
        reasonLabel.textColor = HQPalette.label2
        retry.isHidden = true
        accessibilityIdentifier = "soul.offline"
        isHidden = false
    }
}

/// The editor's text view. At rest (not editable) UIKit offers a text view to VoiceOver one paragraph at a time, and
/// building that list compares the whole text once per paragraph: a 400 KB SOUL.md stalls the main thread for a
/// minute. A long file is offered as one element instead, as it already is while it is being edited.
final class SoulTextView: UITextView {
    /// Past this many UTF-16 units the file is read as one element.
    static let paragraphLimit = 40_000

    private var whole: Bool { !isEditable && textStorage.length > Self.paragraphLimit }

    override var isAccessibilityElement: Bool {
        get { whole ? true : super.isAccessibilityElement }
        set { super.isAccessibilityElement = newValue }
    }
    override var accessibilityElements: [Any]? {
        get { whole ? nil : super.accessibilityElements }
        set { super.accessibilityElements = newValue }
    }
    override func accessibilityElementCount() -> Int { whole ? 0 : super.accessibilityElementCount() }
}
