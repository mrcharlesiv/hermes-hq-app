// [groups] What a room adds to the chat screen (docs/spec/3x-groups.md §7.13): the reply chip, the paused capsule and
// the @ suggestions above the composer, the composer's Stop square while a round runs, the ⋯ menu, a bubble's hold
// menu, the empty room, and the alerts. `ChatViewController` owns one when its session is a `ChatRoomSurface`; every
// hook there is marked [groups].

import UIKit

/// What the room screen asks the app for (AppModel+Groups fills it).
@MainActor struct GroupRoomActions {
    var isOnline: () -> Bool = { true }
    var avatar: () -> (image: String?, faces: [GroupRowModel.Face]) = { (nil, []) }
    var info: () -> Void = {}
    var addBots: () -> Void = {}
    /// [hosted] Hermes runs this room and keeps the bots it was made with: no Add Bots.
    var fixedMembers: () -> Bool = { false }
    var activity: () -> Void = {}
    var delete: () -> Void = {}
}

@MainActor final class GroupRoomChrome: NSObject {
    private weak var chat: ChatViewController?
    private let room: any ChatRoomSurface
    private let dock = UIStackView()
    private let replyChip = RoomReplyChip()
    private let pausedCapsule = RoomPausedCapsule()
    private let mentions = RoomMentionList()
    private var emptyView: RoomEmptyView?
    private var stopping = false
    var actions = GroupRoomActions() { didSet { refreshEmpty() } }

    init(chat: ChatViewController, room: any ChatRoomSurface) {
        self.chat = chat
        self.room = room
        super.init()
    }

    // MARK: Install

    func install(jumpButton: UIView) {
        guard let chat else { return }
        dock.axis = .vertical
        dock.alignment = .center
        dock.spacing = 8
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.accessibilityIdentifier = "room.dock"
        chat.view.insertSubview(dock, belowSubview: jumpButton)
        for view in [replyChip, pausedCapsule, mentions] as [UIView] {
            view.isHidden = true
            dock.addArrangedSubview(view)
        }
        replyChip.widthAnchor.constraint(equalTo: dock.widthAnchor).isActive = true
        mentions.widthAnchor.constraint(equalTo: dock.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            dock.leadingAnchor.constraint(equalTo: chat.view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            dock.trailingAnchor.constraint(equalTo: chat.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            dock.bottomAnchor.constraint(equalTo: chat.composer.topAnchor, constant: -8),
            jumpButton.bottomAnchor.constraint(lessThanOrEqualTo: dock.topAnchor, constant: -8),
        ])
        replyChip.onClose = { [weak self] in self?.room.replyTarget = nil }
        pausedCapsule.onResume = { [weak self] in
            Haptics.play(.light)
            self?.room.resumeAll()
        }
        pausedCapsule.onShow = { [weak self] in self?.showPaused() }
        mentions.onPick = { [weak self] tag in self?.insertMention(tag, replacingQuery: true) }
        // The @ list takes the message field's list keys, as a bot chat's @ and / drawer does (a room has no drawer:
        // `ChatViewController.installDrawer`): ↑ / ↓ mark a row, Tab picks it (or the first), Return picks a marked
        // one, Escape closes the list and keeps the words (Mac polish #16: only a click picked a name).
        if let field = chat.composer.textView as? ComposerTextView {
            field.drawerOpen = { [weak self] in self?.mentionsOpen ?? false }
            field.onDrawerKey = { [weak self] key in self?.mentions.key(key) }
            field.onHardwareReturnPick = { [weak self] in self?.mentionsOpen == true && self?.mentions.pickMarked() == true }
            field.onDrawerEscape = { [weak self] in self?.closeMentions() }
        }
        chat.composer.offersSteerQueue = false
        chat.composer.onTextChange = { [weak self] text in self?.updateMentions(text) }
        room.onChromeChange = { [weak self] in self?.refresh(animated: true) }
        chat.moreMenu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreItems() ?? []) }])
        refresh(animated: false)
    }

    /// The top of what the dock shows (the transcript ends above it); nil when it shows nothing.
    var dockTop: CGFloat? {
        guard !dock.isHidden, dock.arrangedSubviews.contains(where: { !$0.isHidden }), dock.frame.height > 1 else { return nil }
        return dock.frame.minY - 4
    }

    // MARK: State

    /// The session's state changed (the chat applied it): the capsules and the question dock's turn.
    func stateChanged() {
        guard let chat else { return }
        let hide = chat.hasPromptDock
        if dock.isHidden != hide { dock.isHidden = hide }
        refreshEmpty()
    }

    private func refresh(animated: Bool) {
        guard let chat else { return }
        var changed = false
        func show(_ view: UIView, _ on: Bool) { if view.isHidden == on { view.isHidden = !on; changed = true } }
        if let target = room.replyTarget {
            let line = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let flat = line.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if replyChip.set(header: room.replyHeader(target), text: flat.isEmpty ? "Thread reply" : flat) { changed = true }
            show(replyChip, true)
        } else {
            show(replyChip, false)
        }
        let paused = room.paused
        if !paused.isEmpty, pausedCapsule.set(GroupRowWords.paused(paused), count: paused.count) { changed = true }
        show(pausedCapsule, !paused.isEmpty)
        let running = room.roomRunning
        if !running { stopping = false }
        if chat.composer.isRunning != running { chat.composer.isRunning = running }   // the composer's Stop square
        // A second failure of the same send says why (the "Couldn’t Deliver" alert).
        let retrying = room.retrying
        let undelivered = room.undelivered
        for id in pendingRetries where !retrying.contains(id) {
            pendingRetries.remove(id)
            if let reason = undelivered[id] { couldNotDeliver(id, reason: reason) }
        }
        dock.isHidden = chat.hasPromptDock
        if changed { chat.roomChromeChanged(animated: animated) } else { refreshEmpty() }
    }

    // MARK: Empty room

    func setEmpty(_ empty: Bool) {
        guard let chat else { return }
        if empty {
            let view = emptyView ?? {
                // Framed by the chat (`layoutEmpty`): the room between the top bar and the composer, keys up or down.
                let made = RoomEmptyView()
                chat.view.insertSubview(made, aboveSubview: chat.tableView)
                emptyView = made
                return made
            }()
            if view.isHidden { chat.view.setNeedsLayout() }
            view.isHidden = false
            refreshEmpty()
        } else {
            emptyView?.isHidden = true
        }
    }

    /// Tester 2026-11-05: centred on the whole screen, the empty room sat under a new group chat's composer once the
    /// keys came up and the words ran to two lines. It keeps to the transcript's room, as the bot chat's intro does.
    func layoutEmpty(in room: CGRect) {
        guard let emptyView, !emptyView.isHidden, emptyView.frame != room else { return }
        emptyView.frame = room
    }

    private func refreshEmpty() {
        guard let emptyView, !emptyView.isHidden else { return }
        let avatar = actions.avatar()
        emptyView.set(name: room.roomName, members: GroupRowWords.membersOrNone(room.memberNames), image: avatar.image, faces: avatar.faces)
    }

    // MARK: Send

    /// true: the room refused the send, and the words are back in the field.
    func refuses(_ text: String) -> Bool {
        guard let chat, let refusal = room.refusal(for: text) else { return false }
        if chat.composer.text.isEmpty { chat.composer.text = text }
        explain(refusal)
        return true
    }

    /// A voice memo into a room with no one to send to: it waits as the room's draft (and the words typed beside it in
    /// the field), and the alert says why. A memo is never a slash command.
    func refusesMemo(_ memo: MemoFile, typed: String) -> Bool {
        guard let chat, case .noMembers? = room.refusal(for: "memo") else { return false }
        (room as? ChatVoiceMemos)?.setMemoDraft(memo)
        if chat.composer.text.isEmpty { chat.composer.text = typed }
        explain(.noMembers(room: room.roomName))
        return true
    }

    private func explain(_ refusal: RoomSendRefusal) {
        guard let chat else { return }
        switch refusal {
        case .slashCommand:
            chat.showNotice(GroupRoomSession.slashNotice)
        case .noMembers(let name):
            let alert = UIAlertController(title: "Can’t Send",
                                          message: "\(name) has no members to send to — add a bot, or reopen the group chat if members are still loading.",
                                          preferredStyle: .alert)
            if actions.isOnline(), !actions.fixedMembers() {
                alert.addAction(UIAlertAction(title: "Add Bots…", style: .default) { [weak self] _ in self?.actions.addBots() })
            }
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            chat.present(alert, animated: true)
        }
    }

    // MARK: Stop, Resume, Try Again

    /// The composer's Stop square and ⋯ › Stop All.
    func stop() {
        guard !stopping else { return }
        stopping = true
        Haptics.play(.rigid)   // as a bot chat's Stop
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await self.room.stopRoom()
            self.stopping = false
            guard !confirmed, let chat = self.chat else { return }
            let alert = UIAlertController(title: "Couldn’t Confirm Stop",
                                          message: "The group chat is paused, but \(HostWord.phrase) couldn’t confirm that the current reply stopped.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            chat.present(alert, animated: true)
        }
    }

    private func showPaused() {
        guard let chat else { return }
        let alert = UIAlertController(title: "Paused Bots", message: room.paused.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        chat.present(alert, animated: true)
    }

    /// Sends of this screen being tried again: a second failure shows the alert.
    private var pendingRetries: Set<String> = []

    func retry(_ messageId: String) {
        guard room.undelivered[messageId] != nil, !room.retrying.contains(messageId) else { return }
        pendingRetries.insert(messageId)
        room.retry(messageId)
    }

    private func couldNotDeliver(_ messageId: String, reason: String) {
        guard let chat, chat.presentedViewController == nil, chat.view.window != nil else { return }
        let words = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = UIAlertController(title: "Couldn’t Deliver", message: words.isEmpty ? "None of the bots in this group chat took the message." : words,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in self?.retry(messageId) })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        chat.present(alert, animated: true)
    }

    // MARK: Mentions

    /// The @ list is on show (the question dock hides the whole dock).
    private var mentionsOpen: Bool { !mentions.isHidden && !dock.isHidden }
    /// The words Escape closed the list on: it stays closed until they change, as the drawer does.
    private var mentionsClosedFor: String?

    private func closeMentions() {
        guard let chat, mentionsOpen else { return }
        mentionsClosedFor = chat.composer.text
        updateMentions(chat.composer.text)
    }

    private func updateMentions(_ text: String) {
        guard let chat else { return }
        var rows: [RoomMentionList.Row] = []
        if text != mentionsClosedFor { mentionsClosedFor = nil }
        if mentionsClosedFor == nil, let query = GroupMentions.typingQuery(caretText(text)) {
            let all = [RoomMentionList.Row(tag: "everyone", name: "@everyone", detail: "Every bot in this group chat", sender: nil)]
                + room.mentionChoices.map { RoomMentionList.Row(tag: $0.tag, name: $0.name, detail: "@\($0.tag)", sender: $0.sender) }
            rows = query.isEmpty ? all : all.filter { $0.tag.lowercased().hasPrefix(query) || $0.name.lowercased().contains(query) }
        }
        let shows = !rows.isEmpty
        let changed = mentions.set(rows) || mentions.isHidden == shows
        mentions.isHidden = !shows
        if changed { chat.roomChromeChanged(animated: false) }
    }

    /// The text up to the caret (a suggestion follows what is being typed there).
    private func caretText(_ text: String) -> String {
        guard let view = chat?.composer.textView, view.isFirstResponder else { return text }
        let source = text as NSString
        let caret = min(view.selectedRange.location, source.length)
        return source.substring(to: caret)
    }

    /// Puts `@tag ` at the caret (in place of the `@word` being typed when it came from the list).
    func insertMention(_ tag: String, replacingQuery: Bool) {
        guard let chat else { return }
        let view = chat.composer.textView
        let source = chat.composer.text as NSString
        var caret = view.isFirstResponder ? min(view.selectedRange.location, source.length) : source.length
        var head = source.substring(to: caret)
        let tail = source.substring(from: caret)
        if replacingQuery, let at = head.lastIndex(of: "@") { head = String(head[..<at]) }
        else if let last = head.last, !last.isWhitespace { head += " " }
        let insert = "@\(tag) "
        caret = (head as NSString).length + (insert as NSString).length
        chat.composer.text = head + insert + (tail.hasPrefix(" ") ? String(tail.dropFirst()) : tail)
        view.becomeFirstResponder()
        view.selectedRange = NSRange(location: caret, length: 0)
        updateMentions(chat.composer.text)
    }

    // MARK: ⋯

    private func moreItems() -> [UIMenuElement] {
        func item(_ title: String, _ symbol: String, id: String, destructive: Bool = false, disabled: Bool = false, _ run: @escaping () -> Void) -> UIAction {
            var attributes: UIMenuElement.Attributes = destructive ? .destructive : []
            if disabled { attributes.insert(.disabled) }
            let action = UIAction(title: title, image: UIImage(systemName: symbol), attributes: attributes) { _ in run() }
            action.accessibilityIdentifier = "room.more.\(id)"
            return action
        }
        let online = actions.isOnline()
        var top: [UIMenuElement] = [
            item("Find in Chat", "magnifyingglass", id: "find") { [weak self] in self?.chat?.showFind() },
            item("Group Info", "info.circle", id: "info") { [weak self] in self?.actions.info() },
        ]
        if online, !actions.fixedMembers() { top.append(item("Add Bots…", "person.badge.plus", id: "add") { [weak self] in self?.actions.addBots() }) }
        // Prompts need no model list: the saved prompts go into this room's field as in a bot's chat.
        if let menus = chat?.menus {
            top.append(item("Prompts", "text.book.closed", id: "prompts") { [weak menus] in
                Haptics.play(.selection)
                menus?.presentPrompts()
            })
        }
        top.append(item("Activity", "clock.arrow.circlepath", id: "activity") { [weak self] in self?.actions.activity() })
        var run: [UIMenuElement] = []
        if room.roomRunning { run.append(item("Stop All", "stop.circle", id: "stop") { [weak self] in self?.stop() }) }
        if !room.paused.isEmpty { run.append(item("Resume All", "play.circle", id: "resume") { [weak self] in self?.room.resumeAll() }) }
        var out: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, children: top)]
        if !run.isEmpty { out.append(UIMenu(title: "", options: .displayInline, children: run)) }
        if online {
            out.append(UIMenu(title: "", options: .displayInline, children: [
                item("Delete Group Chat", "trash", id: "delete", destructive: true) { [weak self] in self?.actions.delete() },
            ]))
        }
        return out
    }

    // MARK: Hold menu

    private func reply(to entry: GroupMessage) {
        room.replyTarget = entry
        chat?.focusComposer()
    }

    /// Swipe to Reply on a member's bubble: the same thread reply as the hold menu's Reply.
    @discardableResult
    func reply(rowId: String) -> Bool {
        guard let chat else { return false }
        let messageId = chat.roomRow(id: rowId)?.messageId ?? String(rowId.prefix { $0 != "|" })
        guard let entry = room.entry(for: messageId) else { return false }
        reply(to: entry)
        return true
    }

    func messageMenu(rowId: String, source: UIView) -> UIMenu? {
        guard let chat else { return nil }
        let messageId = chat.roomRow(id: rowId)?.messageId ?? String(rowId.prefix { $0 != "|" })
        guard let entry = room.entry(for: messageId) else { return nil }
        let text = entry.text
        func item(_ title: String, _ symbol: String, id: String, destructive: Bool = false, _ run: @escaping () -> Void) -> UIAction {
            let action = UIAction(title: title, image: UIImage(systemName: symbol), attributes: destructive ? .destructive : []) { _ in run() }
            action.accessibilityIdentifier = "message.\(id)"
            return action
        }
        var children: [UIMenuElement] = [
            item("Copy", "doc.on.doc", id: "copy") { [weak chat] in
                UIPasteboard.general.string = text
                #if DEBUG
                DebugHooks.recordText(text, as: "copy.txt")
                #endif
                Haptics.play(.success)
                MenusHUD.show("Copied", in: chat?.view)
            },
            item("Reply", "arrowshape.turn.up.left", id: "reply") { [weak self] in self?.reply(to: entry) },
        ]
        // [Mac UI check 2026-11-13] Share… and Select Text, as a bot chat's bubble menu offers them (C3).
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let menus = chat.menus {
            children.append(item("Share…", "square.and.arrow.up", id: "share") { [weak menus, weak source] in
                menus?.shareMessage(text, from: source)
            })
            children.append(item("Select Text", "text.cursor", id: "select") { [weak chat] in
                guard let chat, let top = MenusSheet.top(chat) else { return }
                top.present(SelectTextViewController.make(text: ChatTranscript.readableText(text)), animated: true)
            })
        }
        if let tag = room.mentionTag(for: messageId) {
            children.append(item("Mention", "at", id: "mention") { [weak self] in self?.insertMention(tag, replacingQuery: false) })
        }
        if room.undelivered[messageId] != nil {
            children.append(UIMenu(title: "", options: .displayInline, children: [
                item("Send Again", "arrow.clockwise", id: "resend") { [weak self] in self?.retry(messageId) },
                item("Delete", "trash", id: "delete", destructive: true) { [weak self] in
                    Haptics.play(.warning)   // as a bot chat's Delete of an unsent message
                    self?.room.deleteUndelivered(messageId)
                },
            ]))
        }
        let who = entry.from.kind == .user ? "You" : String(room.replyHeader(entry).split(separator: "·").last ?? "").trimmingCharacters(in: .whitespaces)
        let when = ChatTranscript.when(Date(timeIntervalSince1970: entry.at / 1000))
        return UIMenu(title: [who, when].filter { !$0.isEmpty }.joined(separator: " · "), children: children)
    }
}

// MARK: - Views

/// A capsule of the system glass that sizes to its content.
private func roomGlass(radius: CGFloat?, tint: UIColor? = nil, interactive: Bool = false) -> UIVisualEffectView {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    if let tint { effect.tintColor = tint }
    let view = UIVisualEffectView(effect: effect)
    view.cornerConfiguration = radius.map { .corners(radius: .fixed($0)) } ?? .capsule()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

private func roomLabel(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular, color: UIColor, lines: Int = 1) -> UILabel {
    let label = UILabel()
    let base = HQFont.preferred(style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
    // The style's size already carries UI Scale; `face` only sets the weight (`system` scaled it twice: Mac polish #71).
    label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: HQFont.face(ofSize: base.pointSize, weight: weight))
    label.adjustsFontForContentSizeCategory = true
    label.textColor = color
    label.numberOfLines = lines
    label.maximumContentSizeCategory = .accessibilityLarge
    return label
}

/// A capsule button's title font: the app's text size, held at the dock's largest so a capsule stays a capsule.
/// (A font asked for without a size follows the app's setting, not the button's own cap.)
private func roomButtonFont(_ style: UIFont.TextStyle, bold: Bool = false) -> UIFont {
    let size = UIApplication.shared.preferredContentSizeCategory
    let held = size > .accessibilityLarge ? UIContentSizeCategory.accessibilityLarge : size
    let font = HQFont.preferred(style, compatibleWith: UITraitCollection(preferredContentSizeCategory: held))
    return bold ? font.bold() : font
}

/// `Replying in thread · Ivy` over one line of the message, with a close button (D4).
final class RoomReplyChip: UIView {
    var onClose: (() -> Void)?
    private let glass = roomGlass(radius: 18)
    private let header = roomLabel(.footnote, weight: .semibold, color: ChatPalette.tintText)
    private let line = roomLabel(.footnote, color: ChatPalette.label2)
    private let close = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        let texts = UIStackView(arrangedSubviews: [header, line])
        texts.axis = .vertical
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.isAccessibilityElement = true
        texts.accessibilityIdentifier = "room.reply"
        glass.contentView.addSubview(texts)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        close.tintColor = ChatPalette.label2
        close.accessibilityLabel = "Cancel thread reply"
        close.accessibilityIdentifier = "room.reply.cancel"
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        glass.contentView.addSubview(close)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            texts.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            texts.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 9),
            texts.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -9),
            texts.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            close.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
            glass.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        texts.accessibilityLabel = ""
        self.texts = texts
    }

    private weak var texts: UIStackView?

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// true when the words changed.
    func set(header: String, text: String) -> Bool {
        guard self.header.text != header || line.text != text else { return false }
        self.header.text = header
        line.text = text
        texts?.accessibilityLabel = "\(header). \(text)"
        return true
    }
}

/// `Ivy is paused` / `2 bots paused` and Resume.
final class RoomPausedCapsule: UIView {
    var onResume: (() -> Void)?
    var onShow: (() -> Void)?
    private let glass = roomGlass(radius: nil)
    private let words = UIButton(type: .system)
    private let resume = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        var wordsConfig = UIButton.Configuration.plain()
        // Small Subheadline (about 11 pt at the default size), growing with the words as far as the capsule lets them.
        wordsConfig.image = UIImage(systemName: "pause.fill")
        wordsConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .small)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        wordsConfig.imagePadding = 6
        wordsConfig.baseForegroundColor = ChatPalette.label
        wordsConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 6)
        words.configuration = wordsConfig
        words.accessibilityIdentifier = "room.paused"
        words.maximumContentSizeCategory = .accessibilityLarge
        words.addAction(UIAction { [weak self] _ in self?.onShow?() }, for: .touchUpInside)
        var resumeConfig = UIButton.Configuration.plain()
        resumeConfig.baseForegroundColor = ChatPalette.tintText
        resumeConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 16)
        resumeConfig.titleLineBreakMode = .byTruncatingTail   // one word: never broken across lines
        resume.configuration = resumeConfig
        resume.accessibilityIdentifier = "room.resume"
        resume.maximumContentSizeCategory = .accessibilityLarge
        resume.addAction(UIAction { [weak self] _ in self?.onResume?() }, for: .touchUpInside)
        // Resume keeps its width; a long line of words wraps beside it instead.
        resume.setContentCompressionResistancePriority(.required, for: .horizontal)
        resume.setContentHuggingPriority(.required, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (capsule: RoomPausedCapsule, _: UITraitCollection) in capsule.setFonts() }
        let row = UIStackView(arrangedSubviews: [words, resume])
        row.axis = .horizontal
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor), row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor), row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var shown = ""

    /// true when the words changed.
    func set(_ text: String, count: Int) -> Bool {
        guard text != shown else { return false }
        shown = text
        setFonts()
        words.accessibilityLabel = "\(text). Show bots"
        return true
    }

    private func setFonts() {
        words.configuration?.attributedTitle = AttributedString(shown, attributes: AttributeContainer([.font: roomButtonFont(.subheadline)]))
        resume.configuration?.attributedTitle = AttributedString("Resume", attributes: AttributeContainer([.font: roomButtonFont(.subheadline, bold: true)]))
    }
}

/// The @ suggestions: `@everyone`, then each member (face, name, `@tag`).
final class RoomMentionList: UIView {
    struct Row: Equatable {
        var tag: String
        var name: String
        var detail: String
        var sender: ChatSender?
    }

    var onPick: ((String) -> Void)?
    private let glass = roomGlass(radius: 20)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var rows: [Row] = []
    private var height: NSLayoutConstraint!
    /// The row ↑ / ↓ marked (Tab and Return pick it); typing starts over, as in the drawer.
    private(set) var marked: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "room.mentions"
        addSubview(glass)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(scroll)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            height,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// true when the rows changed.
    func set(_ next: [Row]) -> Bool {
        guard next != rows else { return false }
        rows = next
        marked = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in next {
            let control = RoomMentionRow(row)
            control.addAction(UIAction { [weak self] _ in self?.onPick?(row.tag) }, for: .touchUpInside)
            stack.addArrangedSubview(control)
        }
        stack.layoutIfNeeded()
        let rowHeight = max(48, stack.arrangedSubviews.first?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height ?? 48)
        height.constant = min(CGFloat(next.count), 4.5) * rowHeight
        return true
    }

    /// The message field's list keys (Mac polish #16), as the drawer's: ↓ marks the first row, then the next; ↑ the one
    /// before, or none from the first; Tab picks the marked row, or the first.
    func key(_ key: ComposerTextView.DrawerKey) {
        guard !rows.isEmpty else { return }
        switch key {
        case .down: mark(marked.map { min($0 + 1, rows.count - 1) } ?? 0)
        case .up:
            guard let marked else { return }
            mark(marked == 0 ? nil : marked - 1)
        case .tab: onPick?(rows[min(marked ?? 0, rows.count - 1)].tag)
        }
    }

    /// Return with a row marked picks it (true); else Return does what it always does.
    func pickMarked() -> Bool {
        guard let marked, rows.indices.contains(marked) else { return false }
        onPick?(rows[marked].tag)
        return true
    }

    private func mark(_ index: Int?) {
        marked = index
        for (i, view) in stack.arrangedSubviews.enumerated() { (view as? RoomMentionRow)?.marked = i == index }
        if let index, index < stack.arrangedSubviews.count {
            layoutIfNeeded()
            scroll.scrollRectToVisible(stack.arrangedSubviews[index].frame, animated: false)
        }
    }
}

private final class RoomMentionRow: UIControl {
    init(_ row: RoomMentionList.Row) {
        super.init(frame: .zero)
        let face: UIView
        if let sender = row.sender {
            let head = HeadView(side: 28)
            head.configure(raw: sender.head, profile: sender.profile)
            face = head
        } else {
            let icon = UIImageView(image: UIImage(systemName: "person.2.fill"))
            icon.tintColor = ChatPalette.label2
            icon.contentMode = .scaleAspectFit
            face = icon
        }
        face.isUserInteractionEnabled = false
        face.translatesAutoresizingMaskIntoConstraints = false
        let name = roomLabel(.subheadline, weight: .semibold, color: ChatPalette.label)
        name.text = row.name
        let detail = roomLabel(.footnote, color: ChatPalette.label2)
        detail.text = row.detail
        let texts = UIStackView(arrangedSubviews: [name, detail])
        texts.axis = .vertical
        texts.spacing = 1
        texts.isUserInteractionEnabled = false
        texts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(face)
        addSubview(texts)
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            face.centerYAnchor.constraint(equalTo: centerYAnchor),
            face.widthAnchor.constraint(equalToConstant: 28), face.heightAnchor.constraint(equalToConstant: 28),
            texts.leadingAnchor.constraint(equalTo: face.trailingAnchor, constant: 10),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            texts.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            texts.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(row.name), \(row.detail)"
        accessibilityIdentifier = "room.mention.\(row.tag)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Marked from the keys (`RoomMentionList.key`): the drawer's mark.
    var marked = false { didSet { fill() } }
    override var isHighlighted: Bool { didSet { fill() } }

    private func fill() {
        #if targetEnvironment(macCatalyst)
        let mark = MacSelection.accent   // [mac] the window's selection, as the drawer marks its rows
        #else
        let mark = ChatPalette.fill3
        #endif
        backgroundColor = isHighlighted ? ChatPalette.fill3 : marked ? mark : .clear
        accessibilityTraits = marked ? [.button, .selected] : .button
    }
}

/// An empty room: the group avatar, the name, the members, and what a send does.
final class RoomEmptyView: UIView {
    private let avatar = GroupAvatarView(side: 56)
    private let name = UILabel()
    private let members = UILabel()
    private let hint = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "room.empty"
        name.font = HQFont.preferred(.title3)
        name.textColor = ChatPalette.label
        members.font = HQFont.preferred(.subheadline)
        members.textColor = ChatPalette.label2
        hint.font = HQFont.preferred(.footnote)
        hint.textColor = ChatPalette.label2
        hint.text = "Everyone here sees what you send. Type @ to ask one bot."
        for label in [name, members, hint] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        name.accessibilityIdentifier = "room.empty.name"
        members.accessibilityIdentifier = "room.empty.members"
        hint.accessibilityIdentifier = "room.empty.hint"
        avatar.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(avatar)
        [name, members, hint].forEach(stack.addArrangedSubview)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.setCustomSpacing(12, after: avatar)
        stack.setCustomSpacing(10, after: members)
        addSubview(stack)
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 56), avatar.heightAnchor.constraint(equalToConstant: 56)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private let stack = UIStackView()
    private var squeezed: [UIView] = []

    func set(name: String, members: String, image: String?, faces: [GroupRowModel.Face]) {
        self.name.text = name
        self.members.text = members
        avatar.configure(image: image, faces: faces)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Short of room (the keys up), it leaves out the faces, then the hint, then the members, as the bot chat's intro
        // does; the name stays. Centred in what's left, a little high, like the intro.
        squeezed.forEach { $0.isHidden = false }
        squeezed = []
        let column = min(320, bounds.width - 64)
        let fitting = { self.stack.systemLayoutSizeFitting(CGSize(width: column, height: UIView.layoutFittingCompressedSize.height),
                                                           withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel) }
        var fit = fitting()
        for view in [avatar, hint, members] as [UIView] where fit.height > bounds.height {
            view.isHidden = true
            squeezed.append(view)
            fit = fitting()
        }
        stack.frame = CGRect(x: ((bounds.width - column) / 2).rounded(), y: max(0, ((bounds.height - fit.height) / 2 - 20).rounded()),
                             width: column, height: fit.height.rounded(.up))
        clipsToBounds = fit.height > bounds.height   // still too tall (huge text): cut off, never drawn under the composer
    }
}

private extension UIFont {
    /// This font's size (already scaled), semibold (Mac polish #71).
    func bold() -> UIFont { HQFont.face(ofSize: pointSize, weight: .semibold) }
}
