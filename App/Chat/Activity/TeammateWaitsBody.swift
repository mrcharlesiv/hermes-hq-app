import UIKit

// Waiting on teammates card on the chat's activity shelf (Hermes 0.23.3+, `bot_delivery.list`).
// Lists unsettled `message_agent` deliveries sent by this bot, lets the user jump to the teammate's chat,
// and lets the user dismiss failed rows. Read-only: never resends automatically.

final class TeammateWaitsBody: UIView, ShelfMeasuredBody {
    private var revision = ShelfRevision()
    var layoutRevision: Int { revision.value }
    var onOpen: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?

    private let stack = UIStackView()
    private let list = UIStackView()
    private let notice = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2, lines: 0)
    private var rows: [String: TeammateWaitRow] = [:]
    private var lastRows: [BotDeliveryRow] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        list.axis = .vertical
        list.spacing = 6
        stack.addArrangedSubview(list)
        notice.text = BotDeliveryRow.neverResentNotice
        notice.isHidden = true
        notice.accessibilityIdentifier = "chat.teammates.notice"
        stack.addArrangedSubview(notice)
        accessibilityIdentifier = "chat.teammates.list"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ deliveries: [BotDeliveryRow], displayName: (String) -> String, now: Double) {
        lastRows = deliveries
        var h = Hasher()
        for d in deliveries {
            h.combine(d.deliveryId); h.combine(d.target); h.combine(d.state.rawValue)
            h.combine(d.statusLine); h.combine(d.preview); h.combine(d.isUnknownOutcome)
        }
        revision.note(h.finalize())

        let ids = Set(deliveries.map(\.deliveryId))
        for (id, view) in rows where !ids.contains(id) {
            view.removeFromSuperview()
            rows[id] = nil
        }
        var arranged: [UIView] = []
        for delivery in deliveries {
            let row = rows[delivery.deliveryId] ?? {
                let r = TeammateWaitRow()
                r.onOpen = { [weak self] target in self?.onOpen?(target) }
                r.onDismiss = { [weak self] id in self?.onDismiss?(id) }
                rows[delivery.deliveryId] = r
                return r
            }()
            row.update(delivery, displayName: displayName(delivery.target), now: now)
            arranged.append(row)
        }
        if list.arrangedSubviews != arranged {
            for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
            for view in arranged { list.addArrangedSubview(view) }
        }
        notice.isHidden = !deliveries.contains(where: \.isUnknownOutcome)
    }

    func tick(now: Double) {
        for delivery in lastRows {
            rows[delivery.deliveryId]?.updateAge(since: delivery.since, now: now)
        }
    }
}

private final class TeammateWaitRow: UIView {
    var onOpen: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?

    private let title = ShelfText.label(ShelfText.footnoteBold, color: ChatPalette.label)
    private let age = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2)
    private let status = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2, lines: 2)
    private let preview = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2, lines: 2)
    private let openButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private var target = ""
    private var deliveryId = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ChatPalette.fill3.withAlphaComponent(0.55)
        layer.cornerRadius = HQShape.radius(12, .card)
        layer.cornerCurve = .continuous

        age.setContentHuggingPriority(.required, for: .horizontal)
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [title, age])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8

        let buttonFont = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = HQFont.preferred(.footnote)
            return out
        }

        var openCfg = UIButton.Configuration.bordered()
        openCfg.title = "Open"
        openCfg.titleTextAttributesTransformer = buttonFont
        openCfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        openButton.configuration = openCfg
        openButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.target.isEmpty else { return }
            Haptics.play(.selection)
            self.onOpen?(self.target)
        }, for: .touchUpInside)

        var dismissCfg = UIButton.Configuration.plain()
        dismissCfg.title = "Dismiss"
        dismissCfg.titleTextAttributesTransformer = buttonFont
        dismissCfg.baseForegroundColor = ChatPalette.label2
        dismissCfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
        dismissButton.configuration = dismissCfg
        dismissButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.deliveryId.isEmpty else { return }
            Haptics.play(.selection)
            self.onDismiss?(self.deliveryId)
        }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [openButton, dismissButton, UIView()])
        buttons.axis = .horizontal
        buttons.spacing = 6
        buttons.alignment = .center

        let col = UIStackView(arrangedSubviews: [header, status, preview, buttons])
        col.axis = .vertical
        col.spacing = 3
        col.setCustomSpacing(6, after: preview)
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ row: BotDeliveryRow, displayName: String, now: Double) {
        target = row.target
        deliveryId = row.deliveryId
        title.text = displayName.isEmpty ? "@\(row.targetHandle)" : displayName
        updateAge(since: row.since, now: now)
        status.text = row.statusLine
        switch row.state {
        case .waitingOnYou: status.textColor = ChatPalette.orange
        case .failed: status.textColor = ChatPalette.red
        case .queued, .claimed, .working: status.textColor = ChatPalette.label2
        }
        let trimmedPreview = row.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        preview.text = trimmedPreview
        preview.isHidden = trimmedPreview.isEmpty
        dismissButton.isHidden = row.state != .failed
        openButton.accessibilityLabel = "Open \(title.text ?? row.target)"
        openButton.accessibilityIdentifier = "chat.teammates.open.\(row.deliveryId)"
        dismissButton.accessibilityLabel = "Dismiss \(title.text ?? row.target)"
        dismissButton.accessibilityIdentifier = "chat.teammates.dismiss.\(row.deliveryId)"
    }

    func updateAge(since: Double, now: Double) {
        age.text = BotDeliveryRow.compactAge(since: since, now: now)
    }
}
