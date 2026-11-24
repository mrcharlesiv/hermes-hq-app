#if targetEnvironment(macCatalyst)
import UIKit

/// [bot-chat-sessions] Owner 2026-11-18 ("I need some way to show sessions owned by a bot ON the bot chat for the Mac
/// app … listed horizontally below the top bar OR in the right side bar? Or maybe both"; he picked both): the
/// inspector's Chats tab. Beside any chat with a bot it lists every chat of that bot's: its own chat and New Chat
/// first, then the rest in groups (Working, Pinned, Today, Yesterday, Earlier), newest first, each with a line of what
/// was last said and when. A green dot is a chat at work, a blue one a reply not read yet; the chat beside the panel
/// is lit. A click opens that chat in the other's place, the panel staying as it is. The strip under the chat's bar
/// (`SessionStrip`) holds only what is live, and its "All N" opens this tab.
/// [bot-tabs-ux] Owner 2026-11-18 ("needs some SERIOUS UI help. It feels so stressful to look at … technically
/// correct, it just doesn't look thoughtfully designed"): the list was every row at one weight, two lines each, ruled
/// off, its dots hanging in the margin. Now it reads as the Mac's sidebar does: no rules, one column for the glyph or
/// dot and one for the words, a rounded fill for the row under the pointer and the chat on show, and one quiet line
/// (title, time) for a chat that needs nothing. Only a chat at work or with a reply not read takes a second line, so
/// the eye lands on what wants it. Groups: Active (at work or unread), Pinned, Today, Earlier.
final class BotChatsPanel: UIViewController, UITableViewDataSource, UITableViewDelegate {
    fileprivate enum Kind: Equatable { case header, botChat, newChat, chat }

    fileprivate struct Row: Equatable {
        var kind: Kind
        var id: String
        var title: String
        var detail: String = ""
        var time: String = ""
        var tip: String = ""
        var working = false
        var unread = false
        var current = false
    }

    private weak var screen: ChatViewController?
    private weak var app: AppModel?
    private let table = UITableView(frame: .zero, style: .plain)
    private var rows: [Row] = []
    private var watches: [NSObjectProtocol] = []
    /// [spring-drop] Files dragged in from the Finder: a chat's row held under them opens it in the other's place; let
    /// go there, they go into its tray (the lit row's: into the chat beside the panel).
    private lazy var fileDrop: SessionFileDrop = {
        let drop = SessionFileDrop(list: table)
        drop.target = { [weak self] point in self?.fileDropTarget(at: point) }
        return drop
    }()
    private lazy var fileDropInteraction = SessionFileDropInteraction(drop: fileDrop)

    private func fileDropTarget(at point: CGPoint) -> SessionFileDrop.Target? {
        guard let path = table.indexPathForRow(at: point), path.row < rows.count, let cell = table.cellForRow(at: path),
              let screen, let app else { return nil }
        let row = rows[path.row]
        guard row.kind == .botChat || row.kind == .chat else { return nil }
        let entry = SessionStripEntry(id: row.id, title: row.title, isBotChat: row.kind == .botChat, working: row.working,
                                      unread: row.unread, current: row.current)
        return SessionFileDrop.Target(key: row.kind == .botChat ? "bot" : row.id, view: cell, rect: cell.bounds.insetBy(dx: 6, dy: 1),
                                      cornerRadius: 8, chat: SessionStrip.dropChat(entry, screen: screen),
                                      open: { [weak screen, weak app] in
                                          guard let screen, let app, !entry.current else { return }
                                          SessionStrip.open(entry, from: screen, app: app)
                                      })
    }

    init(screen: ChatViewController, app: AppModel) {
        self.screen = screen
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        watches.forEach { NotificationCenter.default.removeObserver($0) }
        app?.setChatList(self, shown: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.register(BotChatCell.self, forCellReuseIdentifier: "chat")
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.sectionHeaderTopPadding = 0
        table.contentInset = UIEdgeInsets(top: 2, left: 0, bottom: 12, right: 0)
        table.accessibilityIdentifier = "mac.inspector.chats"
        MacHover.drawsOwnHover(table)   // BotChatCell paints its own inset rounded hover pill
        table.addInteraction(UIDropInteraction(delegate: fileDropInteraction))   // [spring-drop]
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let center = NotificationCenter.default
        for name in [SessionStrip.listChanged, Theme.didChange] {
            let force = name == Theme.didChange
            watches.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload(force: force) }
            })
        }
        reload(force: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload(force: false)
    }

    /// While the list is on show the chats are read at the on-screen pace (`AppModel.setChatList`).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        app?.setChatList(self, shown: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        app?.setChatList(self, shown: false)
    }

    /// Another chat is beside the panel now (one of its rows opened, or a chat of another bot's): its bot's chats, that
    /// one lit.
    func follow(_ next: ChatViewController) {
        screen = next
        if isViewLoaded { reload(force: false) }
    }

    private func reload(force: Bool) {
        guard let app, let screen else { return }
        let next = Self.rows(app: app, model: screen.session)
        guard force || next != rows else { return }
        rows = next
        table.reloadData()
    }

    private static func rows(app: AppModel, model: any ChatSessionModel) -> [Row] {
        let live = model as? LiveChatSession
        let profile = model.profile.isEmpty ? "default" : model.profile
        let bot = app.botStore?.bot(named: profile)
        let onBotChat = live?.isBotChat == true
        let currentId = onBotChat ? nil : live?.storedSessionId
        var out: [Row] = []
        if let bot {
            out.append(Row(kind: .botChat, id: bot.canonicalSessionId ?? "", title: "Bot Chat", tip: "Your ongoing chat with \(bot.name)",
                           working: bot.isWorking, unread: bot.unread && !onBotChat, current: onBotChat))
        }
        out.append(Row(kind: .newChat, id: "", title: "New Chat"))
        let chats = SessionStripRules.chats(bot: bot, sessions: app.sessionsOutsideKeptProjects(keeping: currentId), profile: profile)
        for group in SessionStripRules.groups(chats) {
            out.append(Row(kind: .header, id: group.title, title: group.title))
            for chat in group.chats {
                let working = chat.isRunning || chat.status == .working
                let current = chat.id == currentId
                let unread = chat.unread && !current
                let said = (chat.preview ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                // A second line only where something wants the eye: the step at work, the reply not read yet.
                let detail = working ? (chat.step ?? "Working…") : unread ? said : ""
                let title = SessionRowView.title(chat)
                out.append(Row(kind: .chat, id: chat.id, title: title, detail: detail, time: working ? "" : ListTime.string(chat.lastActive),
                               tip: said.isEmpty ? title : title + "\n" + said, working: working, unread: unread, current: current))
            }
        }
        return out
    }

    // MARK: The table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath)
        let row = rows[indexPath.row]
        (cell as? BotChatCell)?.show(row)
        switch row.kind {
        case .header: cell.accessibilityIdentifier = "mac.inspector.chats.group.\(row.title.lowercased())"
        case .botChat: cell.accessibilityIdentifier = "mac.inspector.chats.bot"
        case .newChat: cell.accessibilityIdentifier = "mac.inspector.chats.new"
        case .chat: cell.accessibilityIdentifier = "mac.inspector.chats.chat.\(rows[..<indexPath.row].filter { $0.kind == .chat }.count)"
        }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { BotChatCell.height(rows[indexPath.row]) }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool { rows[indexPath.row].kind != .header }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let app, let screen else { return }
        let row = rows[indexPath.row]
        switch row.kind {
        case .header: break
        case .newChat:
            guard let navigation = screen.navigationController,
                  app.openNewChat(like: screen.session, draft: "", replacing: screen) else { return }
            AppLog.note("chat", "chats tab: New Chat")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                (navigation.topViewController as? ChatViewController)?.focusComposer()
            }
        case .botChat, .chat:
            guard !row.current else { return }
            SessionStrip.open(SessionStripEntry(id: row.id, title: row.title, isBotChat: row.kind == .botChat, working: row.working,
                                                unread: row.unread, current: false), from: screen, app: app)
        }
    }
}

/// One row of the Chats tab. A glyph or dot in the first column, the words in the second: a title with its time at the
/// end, and for a chat at work or not read a grey line under it. The row under the pointer and the chat on show take a
/// rounded fill, as the sidebar's rows do. A group's name is a row too (small, grey, with air above it).
private final class BotChatCell: UITableViewCell {
    static let lineGap: CGFloat = 2
    /// The fill's inset from the panel's edges, the words' inset inside it, and the glyph column's width.
    private static let fillInset: CGFloat = 8
    private static let pad: CGFloat = 8
    private static let column: CGFloat = 16
    private static var headerFont: UIFont { HQFont.preferred(.caption1).pagesWeight(.semibold) }

    static func height(_ row: BotChatsPanel.Row) -> CGFloat {
        if row.kind == .header { return (headerFont.lineHeight + 26).rounded(.up) }
        let lines = InspectorLook.textFont.lineHeight + (row.detail.isEmpty ? 0 : lineGap + InspectorLook.detailFont.lineHeight)
        return (lines + 14).rounded(.up) + 2   // 1 pt of air above and below the fill
    }

    private let fill = UIView()
    private let dot = UIView()
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let detailLabel = UILabel()
    private let headerLabel = UILabel()
    private let lines = UIStackView()
    private var lit = false
    private var hovers = true
    private var pointerOver = false
    private let tip = UIToolTipInteraction()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        fill.layer.cornerRadius = 6
        fill.layer.cornerCurve = .continuous
        fill.isUserInteractionEnabled = false
        dot.layer.cornerRadius = 3.5
        glyph.contentMode = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timeLabel.font = InspectorLook.detailFont
        timeLabel.textColor = HQPalette.label3
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.font = InspectorLook.detailFont
        detailLabel.textColor = HQPalette.label2
        detailLabel.lineBreakMode = .byTruncatingTail
        headerLabel.font = Self.headerFont
        headerLabel.textColor = HQPalette.label3
        let first = UIStackView(arrangedSubviews: [titleLabel, timeLabel])
        first.axis = .horizontal
        first.spacing = 8
        first.alignment = .firstBaseline
        lines.axis = .vertical
        lines.spacing = Self.lineGap
        lines.addArrangedSubview(first)
        lines.addArrangedSubview(detailLabel)
        for sub in [fill, dot, glyph, lines, headerLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(sub)
        }
        let columnMiddle = Self.fillInset + Self.pad + Self.column / 2
        let words = Self.fillInset + Self.pad + Self.column + 8
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.fillInset),
            fill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.fillInset),
            fill.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            fill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
            lines.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: words),
            lines.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -(Self.fillInset + Self.pad + 2)),
            lines.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: columnMiddle),
            dot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            glyph.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: columnMiddle),
            glyph.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            // A group's name starts where the glyph column does and sits low in its row, near the rows it names.
            headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.fillInset + Self.pad),
            headerLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
        ])
        addInteraction(tip)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ row: BotChatsPanel.Row) {
        let header = row.kind == .header
        headerLabel.font = Self.headerFont
        headerLabel.isHidden = !header
        headerLabel.text = row.title
        lines.isHidden = header
        hovers = !header
        lit = row.current
        updateFill()
        // The chat on show and a reply not read are the two things said in a heavier face.
        titleLabel.font = row.current || row.unread ? InspectorLook.textFont.pagesWeight(.semibold) : InspectorLook.textFont
        titleLabel.textColor = HQPalette.label
        titleLabel.text = row.title
        timeLabel.font = InspectorLook.detailFont
        timeLabel.text = row.time
        timeLabel.isHidden = row.time.isEmpty
        detailLabel.font = InspectorLook.detailFont
        detailLabel.text = row.detail
        detailLabel.isHidden = row.detail.isEmpty
        let dotted = !header && (row.working || row.unread)
        dot.isHidden = !dotted
        dot.backgroundColor = row.working ? SessionStrip.workingColor : SessionStrip.unreadColor
        glyph.isHidden = header || dotted || row.kind == .chat
        glyph.tintColor = HQPalette.label2
        switch row.kind {
        case .botChat: glyph.image = SessionStrip.robot(side: 15)
        case .newChat: glyph.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        default: glyph.image = nil
        }
        tip.defaultToolTip = header || row.tip.isEmpty ? nil : row.tip
        isAccessibilityElement = true
        accessibilityLabel = header ? row.title
            : [row.title, row.working ? "Working" : nil, row.unread ? "New reply" : nil, row.detail.isEmpty ? nil : row.detail,
               row.time.isEmpty ? nil : row.time].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = header ? .header : row.current ? [.button, .selected] : .button
    }

    private func updateFill() {
        fill.backgroundColor = lit ? HQPalette.cellPressed : (hovers && pointerOver) ? HQPalette.cellPressed.withAlphaComponent(0.5) : .clear
    }

    /// The row under the pointer lights a little, as the sidebar's rows do.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        pointerOver = hover.state == .began || hover.state == .changed
        updateFill()
    }
}
#endif
