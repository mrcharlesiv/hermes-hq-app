// The chat's sheets: Info (the title and ⋯ › Info, spec 06 §4.1), the step sheet (spec 03 §8.8, spec 06 §3.3), the
// error card's Details (spec 06 §5.6.1, M1: Copy only), and the transcript as text for ⋯ › Share Transcript. All are
// system sheets (glass on iOS 26) with a sheet-bar ✕ (spec 06 §8.4, §8.8).

import UIKit

// MARK: - Shared sheet frame

/// A navigation controller in a system sheet: medium and large detents and a ✕ in the bar (spec 06 §8.8: one radius and
/// inset for every sheet, so the system's defaults). Every sheet matches the Account sheet (verification round 2 found
/// them apart): the ✕ leading, where the system puts a cancellation action (the web's sheet bar has its dismiss first
/// too), no grabber, and an opaque grouped page, so the chat's bubbles never show through the values.
enum ChatSheet {
    static func wrap(_ root: UIViewController, title: String, detents: [UISheetPresentationController.Detent] = [.medium(), .large()])
        -> UINavigationController {
        root.title = title
        let dismiss = UIAction { [weak root] _ in root?.dismiss(animated: true) }
        // [mac] Stress test 2026-10-28 #32, #55: a Mac sheet closes with the word Done, not the phone's ✕.
        let close = UIBarButtonItem.hqClose(action: dismiss)
        close.accessibilityIdentifier = "sheet.close"
        root.navigationItem.hqPlaceClose(close)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac
        root.navigationItem.largeTitleDisplayMode = .never
        let navigation = UINavigationController(rootViewController: root)
        SheetStyle.apply(navigation, from: nil, detents: detents)   // UX study #161: a form sheet in two panes
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = detents
            sheet.hqPreferLargeAtAccessibilitySizes()   // [a11y] R4: opens large at accessibility text sizes
            sheet.prefersGrabberVisible = false
            // [glass] On Liquid Glass below full height (iOS look), rows on solid cards; opaque in the Desktop Look.
            sheet.hqGlassPage()
        }
        return navigation
    }
}

/// Labelled monospace blocks on the elevated cell colour, radius 14, Footnote size (spec 06 §3.3); each copies on a
/// long press. Used by the step sheet and the error details.
final class ChatBlocksViewController: UIViewController {
    struct Block {
        var label: String
        var text: String
        var mono = true
    }

    private let blocks: [Block]
    private let heading: String?
    private let footer: [UIAction]
    /// [error-words] A sentence under the heading, and the actions under that, above the blocks (Error Details: what
    /// happened and what to do come first, the raw text last). `primary`: the title of the action drawn filled.
    private let note: String?
    private let actionsFirst: Bool
    private let primary: String?
    private let stack = UIStackView()

    init(heading: String?, blocks: [Block], footer: [UIAction] = [], note: String? = nil, actionsFirst: Bool = false, primary: String? = nil) {
        self.heading = heading
        self.blocks = blocks
        self.footer = footer
        self.note = note
        self.actionsFirst = actionsFirst
        self.primary = primary
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The grouped page the Account sheet's list draws; the blocks sit on the elevated cell colour above it.
        view.backgroundColor = HQPalette.sheetPage
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
        ])
        // [glass-design] In the iOS look the blocks take the grouped cards' edges (the view's margins: Chat Info's,
        // Models' rows), so every sheet's cards line up; the Desktop Look keeps its 16 pt.
        if GlassSheetKit.designed {
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor).isActive = true
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor).isActive = true
        } else {
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16).isActive = true
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16).isActive = true
        }
        if let heading, !heading.isEmpty {
            let title = UILabel()
            title.font = HQFont.preferred(.headline)
            title.adjustsFontForContentSizeCategory = true
            title.textColor = ChatPalette.label
            title.numberOfLines = 0
            title.text = heading
            title.accessibilityTraits = .header
            title.accessibilityIdentifier = "sheet.heading"
            stack.addArrangedSubview(title)
            stack.setCustomSpacing(note == nil ? 16 : 4, after: title)
        }
        if let note, !note.isEmpty {
            let words = UILabel()
            words.font = HQFont.preferred(.subheadline)
            words.adjustsFontForContentSizeCategory = true
            words.textColor = ChatPalette.label2
            words.numberOfLines = 0
            words.text = note
            words.accessibilityIdentifier = "sheet.note"
            stack.addArrangedSubview(words)
            stack.setCustomSpacing(14, after: words)
        }
        if actionsFirst, let row = actionRow() {
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(18, after: row)
        }
        for block in blocks {
            let label = UILabel()
            label.font = HQFont.preferred(.footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = ChatPalette.label2
            label.text = block.label
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(6, after: label)
            let card = ChatCopyBlock(text: block.text, mono: block.mono)
            stack.addArrangedSubview(card)
            stack.setCustomSpacing(18, after: card)
        }
        if !actionsFirst, let row = actionRow() { stack.addArrangedSubview(row) }
    }

    private func actionRow() -> UIView? {
        guard !footer.isEmpty else { return nil }
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        for action in footer {
            // [glass-design] A solid capsule like the cards, not glass on the glass (GlassSheetKit).
            var config = UIButton.Configuration.hqSheetAction()
            if action.title == primary {
                config = .filled()
                config.cornerStyle = .capsule
                config.baseBackgroundColor = ChatPalette.tint
                config.baseForegroundColor = .white
            }
            config.title = action.title
            config.image = action.image
            config.imagePadding = 6
            if !GlassSheetKit.designed { config.buttonSize = .medium }
            let button = UIButton(configuration: config, primaryAction: action)
            button.accessibilityIdentifier = "sheet.\(action.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(UIView())
        return row
    }

    /// [error-words] The height the content needs at `width` (the sheet's own detent reads it).
    func fittedHeight(width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let margins = view.layoutMargins.left + view.layoutMargins.right
        let inner = max(120, width - (GlassSheetKit.designed ? max(margins, 32) : 32))
        let size = stack.systemLayoutSizeFitting(CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(size.height) + 8 + 24
    }
}

/// One labelled block's body: selectable monospace text on the elevated cell colour, radius 14.
final class ChatCopyBlock: UIView {
    init(text: String, mono: Bool) {
        super.init(frame: .zero)
        backgroundColor = HQPalette.sheetCard   // [glass] frosted on a glass sheet, solid off it
        layer.cornerRadius = HQShape.radius(14, .card)
        layer.cornerCurve = .continuous
        hqGlassEdge()   // [glass-design] its thin edge on the glass
        let body = UITextView()
        body.isEditable = false
        body.isScrollEnabled = false
        body.backgroundColor = .clear
        body.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        body.textContainer.lineFragmentPadding = 0
        let footnote = HQFont.preferred(.footnote)
        body.font = mono ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
            : footnote
        body.adjustsFontForContentSizeCategory = true
        body.textColor = ChatPalette.label
        body.text = text
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Step sheet

enum ChatStepSheet {
    /// The step sheet (spec 03 §8.8, spec 06 §3.3, M1 subset): Command (terminal) or Input, Output, Error output, Exit
    /// code, the file change, Duration. `detail` is the call's full detail (the row's `summary` is only its first line:
    /// verification round 2 found a 4-line `git log` cut to one line and a file edit's output shown as "{").
    static func make(title: String, call: ToolCall, detail: ToolDetail? = nil) -> UIViewController {
        ChatSheet.wrap(ChatBlocksViewController(heading: title, blocks: blocks(call: call, detail: detail)), title: "Step")
    }

    static func blocks(call: ToolCall, detail: ToolDetail?) -> [ChatBlocksViewController.Block] {
        var blocks: [ChatBlocksViewController.Block] = []
        func add(_ name: String, _ value: String?, mono: Bool = true) {
            guard var value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // An empty JSON record or list (a step cached before verification round 3) says nothing.
            let bare = value.filter { !$0.isWhitespace }
            if bare == "{}" || bare == "[]" { return }
            // The web pages big payloads 20,000 characters at a time (spec 03 §8.8); M1 shows the first page.
            if value.utf16.count > 20_000 { value = String(value.prefix(20_000)) + "\n…" }
            blocks.append(.init(label: name, text: value, mono: mono))
        }
        let args = ChatRunSummary.args(call)
        if call.name == "terminal" || call.name == "execute_code" {
            add("Command", detail?.command ?? ChatRunSummary.firstString(args, ["command", "code"]))
        } else {
            add("Input", detail?.input ?? call.argsText)
        }
        if let detail {
            if call.state == .failed { add("Error", detail.errorText) }
            add("Output", detail.stdout ?? detail.detail)
            add("Error output", detail.stderr)
            if let code = detail.exitCode { add("Exit code", String(code)) }
            add("Changes", detail.inlineDiff)
            // Nothing but a summary (a cached copy with no output kept): still say what the step returned.
            if blocks.count <= 1, detail.errorText == nil { add(call.state == .failed ? "Error" : "Output", call.summary) }
        } else {
            add(call.state == .failed ? "Error" : "Output", call.summary)
        }
        if let d = call.durationSeconds { blocks.append(.init(label: "Duration", text: String(format: "%.1f s", d), mono: false)) }
        if blocks.isEmpty { blocks.append(.init(label: "Details", text: "No details for this step.", mono: false)) }
        return blocks
    }
}

// MARK: - Error details

enum ChatErrorDetailsSheet {
    /// "Error Details" (spec 06 §5.6.1, M1): the raw error text and Copy.
    /// [error-words] Owner 2026-11-10 (design pick 7): what happened in plain words first (`ErrorPlainWords`), then
    /// Try Again (where the caller can retry) beside Copy, then the raw text under "Technical details"; and the sheet
    /// is as tall as that, not half the screen with its lower half empty.
    static func make(details: String, retry: (() -> Void)? = nil) -> UIViewController {
        var copy: UIAction!
        copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { action in
            UIPasteboard.general.string = details
            Haptics.play(.success)
            if let button = action.sender as? UIButton {
                var config = button.configuration
                config?.title = "Copied"
                config?.image = UIImage(systemName: "checkmark")
                button.configuration = config
            }
        }
        let words = ErrorPlainWords.explain(details)
        var actions: [UIAction] = [copy]
        var navigation: UINavigationController?
        if let retry {
            actions.insert(UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { _ in
                navigation?.dismiss(animated: true) { retry() }
            }, at: 0)
        }
        let body = ChatBlocksViewController(heading: words.title, blocks: [.init(label: "Technical details", text: details)], footer: actions,
                                            note: words.text, actionsFirst: true, primary: retry == nil ? nil : "Try Again")
        let fitted = UISheetPresentationController.Detent.custom(identifier: .init("error.fitted")) { [weak body] context in
            guard let body else { return nil }
            let width = body.viewIfLoaded?.bounds.width ?? 0
            // The bar above the content, and the room under it for the home indicator.
            let wanted = body.fittedHeight(width: width > 0 ? width : 390) + 64 + 20
            return min(context.maximumDetentValue, max(220, wanted))
        }
        let wrapped = ChatSheet.wrap(body, title: "Error Details", detents: [fitted, .large()])
        navigation = wrapped
        return wrapped
    }
}

// MARK: - Info

/// Info for the open chat (the title tap and ⋯ › Info). [sessions-m9] "Session Info" (docs/spec/3x-sessions.md §10):
/// the web's twelve rows from `SessionInfoRows`, live while the sheet is open, and Copy Session Info.
enum ChatInfoSheet {
    /// `store`: the Sessions store, for the chat's stored row (messages, folder, cost, source). `profileName`: the
    /// bot's name for a profile id.
    static func make(model: any ChatSessionModel, account: GatewayAccount?, modelName: String?, store: SessionStore? = nil,
                     profileName: ((String) -> String)? = nil) -> UIViewController {
        ChatSheet.wrap(makeContent(model: model, account: account, modelName: modelName, store: store, profileName: profileName),
                       title: "Chat Info")
    }

    /// [mac-layout] The rows alone, for the Mac's inspector (no sheet, no Done).
    static func makeContent(model: any ChatSessionModel, account: GatewayAccount?, modelName: String?, store: SessionStore? = nil,
                            profileName: ((String) -> String)? = nil) -> UIViewController {
        let source = SessionInfoSheetSource(model: model, account: account, modelName: modelName, store: store, profileName: profileName)
        let title = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatInfoList(name: title.isEmpty ? "This chat" : title, head: model.head, profile: model.profile, source: source,
                            panel: DeviceWord.isMac)
    }
}

private final class ChatInfoList: UITableViewController {
    private let name: String
    private let head: JSONValue?
    private let profile: String
    private let source: SessionInfoSheetSource
    /// [inspector] Owner 2026-11-09 (the Mac's right panel: "ugly … the way it's showing all this information is just
    /// bad"): in the panel the rows are an inspector's, as Xcode's and Finder's Get Info draw them. No card: the label
    /// in a narrow column on the left, the value beside it, a hairline between rows, at the panel's own margins, which
    /// Steps, Files and Helpers share (`InspectorLook`). The Chat Info sheet keeps its card.
    private let panel: Bool
    private var rows: [SessionInfoRow]
    private var ticker: Timer?
    /// The chat's running background commands (`process.list`), asked every 3 s while the sheet shows; the section is
    /// left out while there are none.
    private var commands: [BackgroundProcess] = []
    private var commandsTask: Task<Void, Never>?
    private var commandSection: Int? { commands.isEmpty ? nil : 1 }
    private var copySection: Int { commands.isEmpty ? 1 : 2 }

    init(name: String, head: JSONValue?, profile: String, source: SessionInfoSheetSource, panel: Bool = false) {
        self.name = name
        self.head = head
        self.profile = profile
        self.source = source
        self.panel = panel
        self.rows = source.rows()
        super.init(style: panel ? .plain : .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = HQPalette.sheetPage
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "copy-all")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "command")
        tableView.register(ChatInfoNoteCell.self, forCellReuseIdentifier: ChatInfoNoteCell.reuse)
        tableView.register(ChatInfoFormCell.self, forCellReuseIdentifier: ChatInfoFormCell.reuse)
        tableView.accessibilityIdentifier = "info.list"
        if panel { InspectorLook.dress(tableView) }
        // [mac] Stress test 2026-10-28 #72: a short header row (the face and the name side by side) instead of the
        // phone's contact card, and Copy Chat Info as a button under the rows instead of a full-width row.
        if DeviceWord.isMac {
            tableView.tableHeaderView = macHeader()
            tableView.tableFooterView = macFooter()
        } else {
            tableView.tableHeaderView = phoneHeader()
        }
        // MENUS (spec 1x §14.3 check 33): the header follows a text size change.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (list: ChatInfoList, _) in
            list.view.setNeedsLayout()
        }
        // The stored row (when the lists do not hold it) and one `session.usage` ask; the rows follow what comes back.
        source.opened { [weak self] in self?.refresh() }
    }

    private func macHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 60))
        let face = HeadView(side: 36)
        face.configure(raw: head, profile: profile)
        let title = UILabel()
        title.text = name
        title.font = HQFont.preferred(.headline)
        title.textColor = HQPalette.label
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.accessibilityIdentifier = "info.title"
        for view in [face, title] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: panel ? InspectorLook.margin : 20),
            face.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            face.widthAnchor.constraint(equalToConstant: 36),
            face.heightAnchor.constraint(equalToConstant: 36),
            title.leadingAnchor.constraint(equalTo: face.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -20),
            title.centerYAnchor.constraint(equalTo: face.centerYAnchor),
        ])
        return header
    }

    private func macFooter() -> UIView {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 56))
        var config = UIButton.Configuration.hqPush()
        config.title = "Copy Chat Info"
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.copyAll() })
        button.accessibilityIdentifier = "info.copy-all"
        button.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(button)
        NSLayoutConstraint.activate([
            panel ? button.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: InspectorLook.margin)
                : button.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            button.topAnchor.constraint(equalTo: footer.topAnchor, constant: panel ? 14 : 4),
        ])
        return footer
    }

    /// [chatinfo-tidy] Owner 2026-11-10 (design pick 8): the face and the name on one line (a 40 pt face, the name in
    /// Headline beside it), so the rows start at the top of the sheet. The chat's title pill, right above the sheet,
    /// already shows the same face and name at full size.
    static let phoneFace: CGFloat = 40

    private func phoneHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 64))
        let face = HeadView(side: Self.phoneFace)
        face.configure(raw: head, profile: profile)
        face.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel()
        title.text = name
        title.font = HQFont.preferred(.headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 3
        title.lineBreakMode = .byTruncatingTail
        title.accessibilityIdentifier = "info.title"
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(face)
        header.addSubview(title)
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor, constant: 4),
            face.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            face.widthAnchor.constraint(equalToConstant: Self.phoneFace),
            face.heightAnchor.constraint(equalToConstant: Self.phoneFace),
            title.leadingAnchor.constraint(equalTo: face.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: header.layoutMarginsGuide.trailingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        headerTitle = title
        return header
    }

    /// The rows follow the chat while the sheet is open: usage ticks during a turn, a fallback, the gateway's link.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refresh()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        if commandsTask == nil, let live = source.live, live.offersRunningCommands {
            commandsTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let list = await live.runningCommands() else {
                        try? await Task.sleep(for: .seconds(3))
                        continue
                    }
                    self?.show(commands: list)
                    if !live.offersRunningCommands { return }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ticker?.invalidate()
        ticker = nil
        commandsTask?.cancel()
        commandsTask = nil
    }

    private func show(commands next: [BackgroundProcess]) {
        guard next != commands, !holdMenuOpen, !tableView.isEditing else { return }
        if isViewLoaded, tableView.visibleCells.contains(where: \.isHighlighted) { return }
        commands = next
        tableView.reloadData()
    }

    /// Stops one command (`process.kill`); the turn and the other commands keep running.
    private func stop(_ command: BackgroundProcess) {
        guard let live = source.live else { return }
        commands.removeAll { $0.id == command.id }
        tableView.reloadData()
        Task { [weak self] in
            do {
                try await live.stopCommand(command.id)
                Haptics.play(.success)
            } catch {
                FailureAlert.present(title: "Couldn’t Stop the Command", reason: MenusError.text(error), from: self)
            }
            if let list = await live.runningCommands() {
                self?.commands = []          // the list the gateway gives now, whatever the sheet thought
                self?.show(commands: list)
            }
        }
    }

    /// A row's hold menu (Copy) is up: the table is left alone until it closes, so the menu and the highlight stay.
    private var holdMenuOpen = false

    /// The rows are read again and, when they changed, drawn again: but never under a finger. While a row is pressed
    /// (its highlight shows, the hold menu is about to open or is open) the table waits; the next tick, or the menu
    /// closing, catches up. The whole table is reloaded rather than single cells: the table also keeps cells for rows
    /// off screen (VoiceOver reads them), and only a reload refreshes those (seen: the Gateway row below the fold kept
    /// saying "Connected" while the chat said "Reconnecting…").
    private func refresh() {
        guard !holdMenuOpen else { return }
        if isViewLoaded, tableView.visibleCells.contains(where: \.isHighlighted) { return }
        // [mac] #72: nor while part of a value is selected (a reload would drop the selection before ⌘C).
        if isViewLoaded, tableView.visibleCells.contains(where: { ($0 as? ChatInfoFormCell)?.selecting == true }) { return }
        let next = source.rows()
        guard next != rows else { return }
        rows = next
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, willDisplayContextMenu configuration: UIContextMenuConfiguration,
                            animator: (any UIContextMenuInteractionAnimating)?) {
        holdMenuOpen = true
    }

    override func tableView(_ tableView: UITableView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                            animator: (any UIContextMenuInteractionAnimating)?) {
        let closed = { [weak self] in
            guard let self else { return }
            self.holdMenuOpen = false
            self.refresh()
        }
        if let animator { animator.addCompletion(closed) } else { closed() }
    }

    private weak var headerTitle: UILabel?

    /// The header grows with the name (it wraps at the accessibility sizes instead of clipping).
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !panel { DesktopTableOutliner.attach(to: tableView) }   // Stress test 2026-10-28 #56: the look's outlined box, not iOS's card
        guard let header = tableView.tableHeaderView, let title = headerTitle else { return }
        let width = tableView.bounds.width
        // Three lines (six at the accessibility sizes, where a short name already takes three), then an ellipsis.
        let lines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 6 : 3
        if title.numberOfLines != lines { title.numberOfLines = lines }
        // [chatinfo-tidy] The name beside the face: the header is as tall as the taller of the two, 12 pt above and below.
        let beside = max(0, width - header.layoutMargins.left - header.layoutMargins.right - 8 - Self.phoneFace - 12)
        let titleHeight = title.sizeThatFits(CGSize(width: beside, height: .greatestFiniteMagnitude)).height
        let height = ceil(max(Self.phoneFace, titleHeight) + 24)
        guard abs(header.frame.height - height) > 0.5 || abs(header.frame.width - width) > 0.5 else { return }
        header.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = header
    }

    /// [mac] The last section (Copy Chat Info) is the footer's button instead.
    override func numberOfSections(in tableView: UITableView) -> Int { (commands.isEmpty ? 2 : 3) - (DeviceWord.isMac ? 1 : 0) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return rows.count }
        return section == commandSection ? commands.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == commandSection ? "Running Commands" : nil
    }

    /// Desktop Look: the header is the look's label (capitals, tracked, small), as every other header in the look.
    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard section == commandSection, Theme.isDesktop, let header = view as? UITableViewHeaderFooterView else { return }
        var content = UIListContentConfiguration.header().hqScaled()
        content.attributedText = NSAttributedString(string: "Running Commands".uppercased(), attributes: DesktopLayout.labelAttributes())
        header.contentConfiguration = content
        header.accessibilityLabel = "Running Commands"
    }

    private func commandCell(_ command: BackgroundProcess, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "command", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell().hqScaled()
        content.text = command.title
        content.textProperties.font = HQFont.mono(15, like: .body)
        content.textProperties.numberOfLines = 2
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        let tail = command.tailLines
        content.secondaryText = tail.isEmpty ? command.detail : command.detail + "\n" + tail
        content.secondaryTextProperties.font = HQFont.mono(12, like: .footnote)
        content.secondaryTextProperties.color = ChatPalette.label2
        content.secondaryTextProperties.numberOfLines = 3
        content.textToSecondaryTextVerticalPadding = 4
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = "info.command.\(indexPath.row)"
        cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Stop") { [weak self] _ in
            self?.stop(command)
            return true
        }]
        return cell
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == commandSection, indexPath.row < commands.count else { return nil }
        let command = commands[indexPath.row]
        let stop = UIContextualAction(style: .destructive, title: "Stop") { [weak self] _, _, done in
            self?.stop(command)
            done(true)
        }
        stop.image = UIImage(systemName: "stop.circle")
        return UISwipeActionsConfiguration(actions: [stop])
    }

    // [glass] Rows keep a solid card while the sheet sits on glass.
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if panel { cell.backgroundColor = .clear } else { cell.hqSolidOnGlass() }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == commandSection, indexPath.row < commands.count {
            return commandCell(commands[indexPath.row], at: indexPath)
        }
        guard indexPath.section == 0 else {
            // Copy Session Info: every row as `Label: value (note)`, with the raw ids.
            let cell = tableView.dequeueReusableCell(withIdentifier: "copy-all", for: indexPath)
            var content = UIListContentConfiguration.cell().hqScaled()
            content.text = "Copy Chat Info"
            content.textProperties.font = HQFont.preferred(.body)
            content.textProperties.color = HQPalette.tintText
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = "info.copy-all"
            return cell
        }
        let row = rows[indexPath.row]
        if DeviceWord.isMac, let cell = tableView.dequeueReusableCell(withIdentifier: ChatInfoFormCell.reuse, for: indexPath) as? ChatInfoFormCell {
            cell.configure(row, labels: rows.map(\.label), panel: panel)
            return cell
        }
        let cell = row.note != nil
            ? tableView.dequeueReusableCell(withIdentifier: ChatInfoNoteCell.reuse, for: indexPath)
            : tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        fill(cell, with: row)
        return cell
    }

    /// Draws a row into its cell (a new cell, or the one on screen when only its value changed).
    private func fill(_ cell: UITableViewCell, with row: SessionInfoRow) {
        if let note = row.note, let cell = cell as? ChatInfoNoteCell {
            // MENUS (spec 1x §4.3): the value with its note smaller under it; both wrap, and at the accessibility
            // sizes they stack under the label like the other rows (verification: AX3 clipped a fixed-size accessory).
            cell.configure(label: row.label, value: row.value, note: note, mono: row.mono, bar: row.bar)
            cell.accessibilityIdentifier = row.identifier
            return
        }
        var content = UIListContentConfiguration.valueCell().hqScaled()
        content.text = row.label
        content.secondaryText = row.value
        content.prefersSideBySideTextAndSecondaryText = !row.mono
        // The note rows' fonts and colours (ChatInfoNoteCell), so Desktop Look draws every row the same size: the
        // system's own value cell kept 17 pt there while the note rows took the look's smaller body.
        content.textProperties.font = HQFont.preferred(.body)
        content.textProperties.color = ChatPalette.label
        content.secondaryTextProperties.font = HQFont.preferred(.body)
        content.secondaryTextProperties.color = ChatPalette.label2
        if row.mono {
            content = UIListContentConfiguration.subtitleCell().hqScaled()
            content.text = row.label
            content.textProperties.font = HQFont.preferred(.body)
            content.textProperties.color = ChatPalette.label
            content.secondaryText = row.value
            content.secondaryTextProperties.font = HQFont.mono(13, like: .footnote)
            content.secondaryTextProperties.color = ChatPalette.label2
            if row.label == "Folder" {
                content.secondaryTextProperties.numberOfLines = 2
                content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            }
        }
        cell.contentConfiguration = content
        cell.selectionStyle = row.copiesValue ? .default : .none
        cell.accessibilityHint = row.copiesValue ? "Copies it" : nil
        cell.accessibilityIdentifier = row.identifier
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == commandSection { return }
        guard indexPath.section == 0 else { copyAll(); return }
        let row = rows[indexPath.row]
        guard row.copiesValue else { return }
        UIPasteboard.general.string = row.value
#if DEBUG
        DebugHooks.recordText(row.value, as: "info-copy.txt")
#endif
        Haptics.play(.success)
    }

    /// Copy Chat Info: every row as `Label: value (note)`, with the raw ids.
    private func copyAll() {
        let text = SessionInfoRows.copyText(rows)
        UIPasteboard.general.string = text
#if DEBUG
        DebugHooks.recordText(text, as: "info-copy.txt")
#endif
        Haptics.play(.success)
        MenusHUD.show("Copied", in: view.window)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        if indexPath.section == commandSection, indexPath.row < commands.count {
            // A command's menu: Copy Command, and Stop (the swipe's action, for a mouse or a hold).
            let command = commands[indexPath.row]
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                let copy = UIAction(title: "Copy Command", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = command.command
                    Haptics.play(.success)
                    MenusHUD.show("Copied", in: self?.view.window)
                }
                let stop = UIAction(title: "Stop Command", image: UIImage(systemName: "stop.circle"), attributes: .destructive) { _ in
                    self?.stop(command)
                }
                stop.accessibilityIdentifier = "info.command.stop"
                return UIMenu(children: [copy, stop])
            }
        }
        guard indexPath.section == 0 else { return nil }
        // Copy: the row as Copy Session Info writes it (raw ids), else `Label: value (note)`.
        let text = rows[indexPath.row].copyText
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
#if DEBUG
                DebugHooks.recordText(text, as: "info-copy.txt")
#endif
            }])
        }
    }
}

/// MENUS (spec 1x §4.3): Info's Model row — "Model" leading, the model's name with its provider under it trailing
/// (Body label-2 over Footnote label-3), 12 pt above and below. At the accessibility sizes the value stacks under the
/// label, left-aligned, and every line wraps (nothing is a fixed-size accessory).
private final class ChatInfoNoteCell: UITableViewCell {
    static let reuse = "info.note"
    private let label = UILabel()
    private let value = UILabel()
    private let note = UILabel()
    private let values = UIStackView()
    private let row = UIStackView()
    /// A thin bar under the row (Context, Cache): a rounded track, the share filled in the tint.
    private let bar = ChatInfoBar()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        // [glass-design] The note in label 2 (`HQPalette.cardNote`): label 3 read 2.1:1 on the card.
        for (l, style, color) in [(label, UIFont.TextStyle.body, ChatPalette.label), (value, .body, ChatPalette.label2),
                                  (note, .footnote, HQPalette.cardNote)] {
            l.font = HQFont.preferred(style)
            l.adjustsFontForContentSizeCategory = true
            l.textColor = color
            l.numberOfLines = 0
        }
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        values.addArrangedSubview(value)
        values.addArrangedSubview(note)
        values.axis = .vertical
        values.spacing = 1
        row.addArrangedSubview(label)
        row.addArrangedSubview(values)
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(bar)
        stack.axis = .vertical
        stack.spacing = 8
        bar.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
        isAccessibilityElement = true
        applySize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: ChatInfoNoteCell, _) in cell.applySize() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [sessions-m9] `mono`: a path (Folder): its own line under the label, monospaced, two lines with the middle cut.
    func configure(label text: String, value valueText: String, note noteText: String, mono: Bool = false, bar share: Double? = nil) {
        bar.isHidden = share == nil
        bar.share = share ?? 0
        label.text = text
        value.text = valueText
        note.text = noteText
        accessibilityLabel = text
        accessibilityValue = "\(valueText), \(noteText)"
        self.mono = mono
        value.font = mono ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
            : HQFont.preferred(.body)
        value.numberOfLines = mono ? 2 : 0
        value.lineBreakMode = mono ? .byTruncatingMiddle : .byWordWrapping
        applySize()
    }

    private var mono = false

    private func applySize() {
        let stacked = mono || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        row.axis = stacked ? .vertical : .horizontal
        row.alignment = stacked ? .leading : .center
        row.spacing = stacked ? 4 : 16
        values.alignment = stacked ? .leading : .trailing
        value.textAlignment = stacked ? .natural : .right
        note.textAlignment = stacked ? .natural : .right
    }
}

/// [mac] Stress test 2026-10-28 #72: Info's rows as a Mac info panel, a two-column form. The label in a fixed column,
/// trailing-aligned and secondary; the value, its note and its bar in one column beside it, every value starting at
/// the same x (the phone's rows put most values at the right edge and Folder and Chat ID under their labels). The value
/// is selectable text: drag across part of it and ⌘C, as in a Mac Get Info window.
private final class ChatInfoFormCell: UITableViewCell {
    static let reuse = "info.form"
    private let label = UILabel()
    private let value = UITextView()
    private let note = UILabel()
    private let bar = ChatInfoBar()
    private let column = UIStackView()
    private lazy var labelWidth = label.widthAnchor.constraint(equalToConstant: HQFont.scaled(112))
    /// Every label in the list, so a narrow column fits the widest one and every value still starts at the same x.
    private var labels: [String] = []
    /// The widest of `labels` and the font size it was measured at (a layout pass runs often; the words seldom change).
    private var widest: (labels: [String], size: CGFloat, width: CGFloat)?
    /// [mac-ui-issues] Owner 2026-11-09 (the inspector "awkwardly sized and laid out"): in the inspector's column the
    /// label sat right-aligned beside its value and the two shared a width neither had (a folder's path broke after
    /// "/home/hermes/"). A narrow cell now stacks them, as Xcode's and Finder's inspectors do: the label small above,
    /// the value under it at the row's whole width. The Chat Info sheet (wide) keeps the two columns.
    private var beside: [NSLayoutConstraint] = []
    private var above: [NSLayoutConstraint] = []
    private var stacked = false
    /// [inspector] In the Mac's right panel: always two columns, the labels in a narrow column on the left at the
    /// panel's smaller text, the values beside them (`ChatInfoList.panel`).
    private var panel = false
    /// Part of the value is selected: Info's live refresh waits, so a reload doesn't take the selection away.
    var selecting: Bool { value.isFirstResponder && value.selectedRange.length > 0 }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        label.font = HQFont.preferred(.body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ChatPalette.label2
        label.textAlignment = .right
        label.numberOfLines = 0
        value.isEditable = false
        value.isSelectable = true
        value.isScrollEnabled = false
        value.backgroundColor = .clear
        value.textContainerInset = .zero
        value.textContainer.lineFragmentPadding = 0
        value.textColor = ChatPalette.label
        value.adjustsFontForContentSizeCategory = true
        note.font = HQFont.preferred(.footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = ChatPalette.label3
        note.numberOfLines = 0
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 2
        for view in [value, note, bar] as [UIView] { column.addArrangedSubview(view) }
        column.setCustomSpacing(6, after: note)
        for view in [label, column] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        let margins = contentView.layoutMarginsGuide
        beside = [
            labelWidth,
            label.firstBaselineAnchor.constraint(equalTo: value.firstBaselineAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -9),
            column.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
        ]
        above = [
            label.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ]
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),
        ] + beside)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mac polish #60: in the inspector's narrow column (340 pt) the 112 pt label column left the value about as much,
    /// so "127.0.0.1:10500" broke mid-number and Fixture Model took two lines. A narrow cell gives its labels what the
    /// widest of them needs in the label's own font (the iOS look's larger body too: "Answered By", "Reasoning"), from
    /// 76 up to the sheet's 112; the sheet keeps the wide column. Set before the cell is measured and as it lays out.
    private func fitLabelColumn(to width: CGFloat) {
        if panel {
            if stacked {
                stacked = false
                NSLayoutConstraint.deactivate(above)
                NSLayoutConstraint.activate(beside)
            }
            label.font = InspectorLook.labelFont
            label.textAlignment = .natural
            let column = min(max(widestLabel(), 64), max(64, (width * 0.4).rounded()))
            if labelWidth.constant != column { labelWidth.constant = column }
            return
        }
        let wide = HQFont.scaled(112)
        let narrow = width > 0 && width < HQFont.scaled(440)
        if narrow != stacked {
            stacked = narrow
            NSLayoutConstraint.deactivate(narrow ? beside : above)
            NSLayoutConstraint.activate(narrow ? above : beside)
            label.font = HQFont.preferred(narrow ? .footnote : .body)
            label.textAlignment = narrow ? .natural : .right
        }
        guard !narrow else { return }
        if labelWidth.constant != wide { labelWidth.constant = wide }
    }

    private func widestLabel() -> CGFloat {
        let font = label.font ?? HQFont.preferred(.body)
        if let widest, widest.labels == labels, widest.size == font.pointSize { return widest.width }
        let width = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max().map { ($0 + 1).rounded(.up) } ?? 0
        widest = (labels, font.pointSize, width)
        return width
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                          verticalFittingPriority: UILayoutPriority) -> CGSize {
        fitLabelColumn(to: targetSize.width)
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority,
                                             verticalFittingPriority: verticalFittingPriority)
    }

    override func layoutSubviews() {
        fitLabelColumn(to: bounds.width)
        super.layoutSubviews()
    }

    func configure(_ row: SessionInfoRow, labels: [String], panel: Bool = false) {
        if self.labels != labels || self.panel != panel {
            self.labels = labels
            self.panel = panel
            widest = nil
            setNeedsLayout()
        }
        if panel {
            contentView.preservesSuperviewLayoutMargins = false
            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: InspectorLook.margin, bottom: 0, trailing: InspectorLook.margin)
        }
        label.text = row.label
        value.text = row.value
        value.font = row.mono ? UIFontMetrics(forTextStyle: .body).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
            : HQFont.preferred(.body)
        // [mac] Stress test 2026-10-28: Folder and Chat ID read a size smaller than the values round them; on the Mac the
        // monospaced face is the body's size.
        if row.mono, DeviceWord.isMac { value.font = HQFont.monoFace(ofSize: HQFont.preferred(.body).pointSize, weight: .regular) }
        if panel {
            value.font = row.mono ? HQFont.monoFace(ofSize: InspectorLook.textFont.pointSize - 1, weight: .regular) : InspectorLook.textFont
            note.font = InspectorLook.detailFont
        }
        value.textColor = ChatPalette.label
        // A long folder keeps its two ends (the start of the path and the folder's own name). Mac polish #60: so does a
        // value with nowhere to wrap (a gateway's address, a chat's ID), on one line, never broken mid-number; a path
        // still wraps at its slashes.
        let oneWord = !row.value.contains(where: { $0.isWhitespace || $0 == "/" })
        value.textContainer.maximumNumberOfLines = oneWord ? 1 : row.mono ? 2 : 0
        value.textContainer.lineBreakMode = row.mono || oneWord ? .byTruncatingMiddle : .byWordWrapping
        note.text = row.note
        // [mac] Stress test 2026-10-28 round 7: in the iOS look the tertiary grey left "Fixture" and "Connected" too faint
        // under their values; the secondary label colour, as the labels beside them.
        note.textColor = Theme.isDesktop ? ChatPalette.label3 : ChatPalette.label2
        note.isHidden = row.note == nil
        bar.isHidden = row.bar == nil
        bar.share = row.bar ?? 0
        accessibilityLabel = row.label
        accessibilityValue = row.note.map { "\(row.value), \($0)" } ?? row.value
        accessibilityIdentifier = row.identifier
    }
}

/// Session Info's thin bar (tester 2026-10-27): 4 pt, rounded, the share in the tint over a faint track.
private final class ChatInfoBar: UIView {
    var share: Double = 0 { didSet { setNeedsLayout() } }
    private let fill = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ChatPalette.fill3
        fill.backgroundColor = ChatPalette.tint
        layer.cornerRadius = 2
        layer.masksToBounds = true
        addSubview(fill)
        isAccessibilityElement = false
        heightAnchor.constraint(equalToConstant: 4).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let clamped = share.isFinite ? Swift.max(0, Swift.min(1, share)) : 0
        fill.frame = CGRect(x: 0, y: 0, width: (bounds.width * clamped).rounded(), height: bounds.height)
    }
}

// MARK: - Transcript as text

enum ChatTranscriptText {
    /// The chat as plain text for Messages or Notes (MENUS, spec 1x §4.4: the title, then "You:" / "<Bot>:" on its own
    /// line over each message; system notes and tool steps left out). The loaded messages only: ⋯ › Share reads the
    /// whole chat through `ChatSessionActions.transcriptText()`.
    static func make(_ model: any ChatSessionModel) -> String {
        let bot = ((model as? ChatSessionDetails)?.botName ?? model.title)
        return ChatTranscript.text(title: model.title, botName: bot, messages: model.messages, userLine: userLine)
    }

    /// Your voice memo's transcript line in place of its text.
    static let userLine: @Sendable (String) -> String? = { VoiceMemo.parse($0)?.transcriptLine }
}
