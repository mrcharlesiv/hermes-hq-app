// Tiered UI for model and provider fallbacks in the chat timeline:
// - Actionable failures (auth, billing/quota, missing model) render as a compact amber status card matching
//   `PhoneChatCardControl`, opening a native sheet with the model route, copyable fix command, model picker and
//   Provider Settings shortcuts, and collapsible technical details.
// - Transient fallbacks (rate limit, busy, timeout) render as a compact 1-line frosted pill that opens the same sheet.
// - Primary recovery ("Primary model restored") renders as a quiet 1-line pill with a green dot.

import SwiftUI
import UIKit

// MARK: - Presentation model

nonisolated struct ModelFallbackRow: Equatable, Hashable, Sendable {
    enum Presentation: Equatable, Hashable, Sendable {
        case card
        case pill
        case restored
    }

    struct Detail: Equatable, Hashable, Sendable {
        var primaryName: String
        var primaryID: String
        var primaryProvider: String?
        var fallbackName: String
        var fallbackID: String
        var fallbackProvider: String?
        var category: ModelFallback.Category
        var kicker: String
        var routeStatus: String
        var explanation: String
        var primaryCommand: String?
        var primaryEnvVar: String? = nil
        var secondaryHint: String?
        var rawText: String
        var isActionable: Bool

        /// Validates that a parsed CLI fix command is a safe, single-command invocation suitable for running directly in
        /// the in-app Terminal (no newlines, control characters, or shell chaining/redirection metacharacters).
        static func safeTerminalCommand(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
            let forbidden = CharacterSet(charactersIn: ";|&`$><(){}\\\n\r\0")
            guard trimmed.rangeOfCharacter(from: forbidden) == nil else { return nil }
            guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
            return trimmed
        }

        /// Non-nil when `primaryCommand` can be launched directly in a fresh Terminal tab.
        var runnableCommand: String? { Self.safeTerminalCommand(primaryCommand) }
    }

    var presentation: Presentation
    var title: String
    var subtitle: String?
    var spoken: String
    var detail: Detail?

    /// Parses a gateway fallback or recovery notice into a structured timeline row; nil for unrelated notices.
    static func parse(_ text: String,
                      displayName: (String) -> String = { ModelNames.displayModelName($0) },
                      providerName: (String) -> String = { ModelNames.providerDisplayName($0) }) -> ModelFallbackRow? {
        if let fallback = ModelFallback.parse(text) {
            return make(from: fallback, displayName: displayName, providerName: providerName)
        }
        if let restored = ModelFallback.restoredModel(text) {
            let title: String
            if restored.isEmpty {
                title = "Back to your usual model"
            } else {
                let name = readableName(restored, providerShape: false, placeholder: "", or: "",
                                        displayName: displayName, providerName: providerName)
                title = "Back to \(name)"
            }
            return ModelFallbackRow(presentation: .restored, title: title, subtitle: nil, spoken: title, detail: nil)
        }
        return nil
    }

    private static func make(from fallback: ModelFallback,
                             displayName: (String) -> String,
                             providerName: (String) -> String) -> ModelFallbackRow {
        let primary = readableName(fallback.primary, providerShape: fallback.isProviderShape,
                                   placeholder: "primary", or: "Your usual model",
                                   displayName: displayName, providerName: providerName)
        let active = readableName(fallback.fallback, providerShape: fallback.isProviderShape,
                                  placeholder: "fallback", or: "another model",
                                  displayName: displayName, providerName: providerName)
        let category = fallback.category
        let commands = fallback.extractedCommands
        let lowerReason = (fallback.reason ?? "").lowercased()
        let isClaudeProvider = {
            let p = (fallback.primaryProvider ?? "").lowercased()
            return p.hasPrefix("claude-subscription") || p == "claude-code"
        }()
        let isInvalidClaudeBearer = category == .auth && isClaudeProvider && lowerReason.contains("invalid bearer token")
        let primaryCommand = commands.first ?? (isInvalidClaudeBearer ? "claude auth login" : nil)
        let primaryEnvVar = fallback.mentionedEnvVars.first ?? (isInvalidClaudeBearer ? "CLAUDE_CODE_OAUTH_TOKEN" : nil)
        let secondaryHint: String? = if isInvalidClaudeBearer {
            "If `CLAUDE_CODE_OAUTH_TOKEN` is set to a bad or expired value (such as a one-time login code), remove it so Hermes uses your `claude auth login` session."
        } else {
            buildSecondaryHint(commands: commands, envVars: fallback.mentionedEnvVars, reason: fallback.reason)
        }

        let kickerBase: String = switch category {
        case .auth: "Sign-in required"
        case .billing: "Billing or quota limit"
        case .notFound: "Model unavailable"
        case .rateLimit: "Rate limited"
        case .busy: "Provider busy"
        case .timeout: "Timed out"
        case .other: "Model fallback"
        }
        let kicker = fallback.httpStatus.map { "\(kickerBase) · \($0)" } ?? kickerBase

        let routeStatus: String = if let seconds = fallback.retryAfterSeconds, seconds > 0 {
            "Retry in ~\(seconds)s"
        } else {
            "Active for turn"
        }

        let explanation = buildExplanation(primary: primary, active: active, fallback: fallback, category: category)
        let detail = Detail(
            primaryName: primary,
            primaryID: fallback.primary,
            primaryProvider: fallback.primaryProvider,
            fallbackName: active,
            fallbackID: fallback.fallback,
            fallbackProvider: fallback.fallbackProvider,
            category: category,
            kicker: kicker,
            routeStatus: routeStatus,
            explanation: explanation,
            primaryCommand: primaryCommand,
            primaryEnvVar: primaryEnvVar,
            secondaryHint: secondaryHint,
            rawText: fallback.rawText.isEmpty ? "\(fallback.primary) → \(fallback.fallback)" : fallback.rawText,
            isActionable: fallback.isActionable
        )

        if fallback.isActionable {
            let title = "Switched to \(active)"
            let subtitle: String = switch category {
            case .auth: "\(primary) needs sign-in · Tap to fix"
            case .billing: "\(primary) hit a billing limit · Tap for details"
            case .notFound: "\(primary) isn’t available · Tap to fix"
            default: "\(primary) couldn’t respond · Tap to fix"
            }
            return ModelFallbackRow(
                presentation: .card,
                title: title,
                subtitle: subtitle,
                spoken: "\(title). \(subtitle)",
                detail: detail
            )
        }

        let shortCause: String = switch category {
        case .rateLimit: "rate limited"
        case .busy: "busy"
        case .timeout: "timed out"
        default: "unavailable"
        }
        let pillTitle = "\(primary) \(shortCause) · Using \(active)"
        return ModelFallbackRow(
            presentation: .pill,
            title: pillTitle,
            subtitle: nil,
            spoken: "\(pillTitle). Opens details",
            detail: detail
        )
    }

    private static func buildExplanation(primary: String, active: String,
                                         fallback: ModelFallback, category: ModelFallback.Category) -> String {
        let lower = (fallback.reason ?? "").lowercased()
        switch category {
        case .auth:
            if lower.contains("invalid bearer token") && ((fallback.primaryProvider ?? "").lowercased().hasPrefix("claude-subscription") || (fallback.primaryProvider ?? "").lowercased() == "claude-code") {
                return "Claude Code’s saved token was rejected by Anthropic, so \(active) answered this message instead."
            }
            if lower.contains("claude code") && lower.contains("login") {
                return "Claude Code doesn’t have an active login in Hermes’s environment, so \(active) answered this message instead."
            }
            return "\(primary) couldn’t authenticate with its provider, so \(active) answered this message instead."
        case .billing:
            return "\(primary) hit a billing or quota limit, so \(active) answered this message instead."
        case .notFound:
            return "\(primary) wasn’t found on its configured provider, so \(active) answered this message instead."
        case .rateLimit:
            if let seconds = fallback.retryAfterSeconds, seconds > 0 {
                return "\(primary) hit a rate limit, so \(active) answered for now. Hermes can retry \(primary) in about \(seconds) seconds."
            }
            return "\(primary) hit a rate limit, so \(active) answered this message for now."
        case .busy:
            if let seconds = fallback.retryAfterSeconds, seconds > 0 {
                return "\(primary) is temporarily busy, so \(active) answered for now. Hermes can retry \(primary) in about \(seconds) seconds."
            }
            return "\(primary) is temporarily overloaded, so \(active) answered this message for now."
        case .timeout:
            return "\(primary) didn’t respond in time, so \(active) answered this message instead."
        case .other:
            return "\(primary) couldn’t respond, so \(active) answered this message instead."
        }
    }

    private static func buildSecondaryHint(commands: [String], envVars: [String], reason: String?) -> String? {
        let extraCommands = Array(commands.dropFirst())
        if let second = extraCommands.first, let env = envVars.first {
            return "Or instead, run `\(second)` and set `\(env)` in Hermes’s environment."
        }
        if let env = envVars.first {
            if env == "CLAUDE_CODE_OAUTH_TOKEN" {
                return "Alternative (don’t do both): paste a long-lived `sk-ant-…` token from `claude setup-token` into `CLAUDE_CODE_OAUTH_TOKEN`. Leave it unset if you use `claude auth login`."
            }
            if let reason, reason.contains("setup-to") {
                return "Or instead, set `\(env)` (from `claude setup-token`) in Hermes’s environment."
            }
            return "Or instead, set `\(env)` in Hermes’s environment."
        }
        if let second = extraCommands.first {
            return "Or run `\(second)` on \(HostWord.phrase)."
        }
        return nil
    }

    private static func readableName(_ id: String, providerShape: Bool, placeholder: String, or words: String,
                                     displayName: (String) -> String, providerName: (String) -> String) -> String {
        var bare = id
        if bare.hasSuffix("]"), let open = bare.lastIndex(of: "[") { bare = String(bare[..<open]) }
        if !placeholder.isEmpty, bare.lowercased() == placeholder { return words }
        let shown: String
        if let slash = bare.lastIndex(of: "/") {
            bare = String(bare[bare.index(after: slash)...])
            shown = displayName(bare)
        } else {
            shown = providerShape ? providerName(bare) : displayName(bare)
        }
        let trimmed = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? bare : trimmed
    }
}

// MARK: - Precomputed layout

nonisolated struct ModelFallbackLayout {
    var frame: CGRect
    var isCard: Bool
}

nonisolated enum ModelFallbackCardLayout {
    static let inset: CGFloat = 14
    static let icon: CGFloat = 38
    static let gap: CGFloat = 12
    static let chevronWidth: CGFloat = 18

    static func titleFont(_ style: ChatStyle) -> UIFont { PhoneChatCardLayout.titleFont(style) }
    static func detailFont(_ style: ChatStyle) -> UIFont { PhoneChatCardLayout.detailFont(style) }
    static func pillFont(_ style: ChatStyle) -> UIFont {
        HQFont.scaled(13.5, weight: .medium, like: .footnote, category: style.category)
    }

    static func cardWordsWidth(width: CGFloat) -> CGFloat {
        max(1, width - 2 * inset - icon - gap - chevronWidth - gap)
    }

    static func cardWordHeights(_ row: ModelFallbackRow, width: CGFloat, style: ChatStyle) -> (CGFloat, CGFloat) {
        let w = cardWordsWidth(width: width)
        func measure(_ text: String, _ font: UIFont, _ lines: Int) -> CGFloat {
            let size = CGSize(width: w, height: .greatestFiniteMagnitude)
            let bounds = (text as NSString).boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                         attributes: [.font: font], context: nil)
            return min(ceil(bounds.height), ceil(font.lineHeight) * CGFloat(lines))
        }
        let titleH = measure(row.title, titleFont(style), 2)
        let subH = row.subtitle.map { measure($0, detailFont(style), 2) } ?? 0
        return (titleH, subH)
    }

    static func layout(_ row: ModelFallbackRow, width: CGFloat, gap: CGFloat, style: ChatStyle) -> RowLayout {
        switch row.presentation {
        case .card:
            let cardWidth = max(0, width - 2 * ChatMetrics.sideInset)
            let (titleH, subH) = cardWordHeights(row, width: cardWidth, style: style)
            let textH = titleH + (subH > 0 ? 3 + subH : 0)
            let height = 2 * inset + max(icon, textH)
            let frame = CGRect(x: ChatMetrics.sideInset, y: gap, width: cardWidth, height: ceil(height))
            return RowLayout(height: ceil(gap + height), content: .modelFallback(ModelFallbackLayout(frame: frame, isCard: true)))
        case .pill, .restored:
            let interactive = row.presentation == .pill
            let font = pillFont(style)
            let padH: CGFloat = 14
            let padV: CGFloat = 7
            let dotSize: CGFloat = 8
            let dotGap: CGFloat = 8
            let chevExtra: CGFloat = interactive ? (6 + 8) : 0
            let maxPillW = max(120, width - 2 * ChatMetrics.sideInset)
            let maxTextW = max(40, maxPillW - 2 * padH - dotSize - dotGap - chevExtra)
            let bounds = (row.title as NSString).boundingRect(
                with: CGSize(width: maxTextW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            let textW = min(ceil(bounds.width), maxTextW)
            let textH = min(ceil(bounds.height), ceil(font.lineHeight) * 2)
            let pillW = min(maxPillW, ceil(2 * padH + dotSize + dotGap + textW + chevExtra))
            let pillH = max(32, ceil(textH + 2 * padV))
            let rowH = max(interactive ? 44 : 36, pillH + 6)
            let x = ((width - pillW) / 2).rounded()
            let y = gap + ((rowH - pillH) / 2).rounded()
            let frame = CGRect(x: x, y: y, width: pillW, height: pillH)
            return RowLayout(height: ceil(gap + rowH), content: .modelFallback(ModelFallbackLayout(frame: frame, isCard: false)))
        }
    }
}

// MARK: - Table cell

final class ModelFallbackCell: ChatBaseCell, UIContextMenuInteractionDelegate {
    static let reuse = "ModelFallbackCell"

    private let cardControl = ModelFallbackCardControl()
    private let pillControl = ModelFallbackPillControl()
    private var currentRow: ModelFallbackRow?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(cardControl)
        contentView.addSubview(pillControl)
        cardControl.addInteraction(UIContextMenuInteraction(delegate: self))
        pillControl.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .modelFallback(let model) = row.kind,
              case .modelFallback(let box) = layout.content else { return }
        currentRow = model
        let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        if box.isCard {
            cardControl.isHidden = false
            pillControl.isHidden = true
            cardControl.frame = box.frame
            cardControl.configure(model, style: style)
            cardControl.onTap = { [weak self] in
                guard let detail = model.detail else { return }
                self?.delegate?.chatCellOpenModelFallback(detail)
            }
        } else {
            cardControl.isHidden = true
            pillControl.isHidden = false
            pillControl.frame = box.frame
            pillControl.configure(model, style: style)
            pillControl.onTap = model.detail.map { detail in
                { [weak self] in self?.delegate?.chatCellOpenModelFallback(detail) }
            }
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let detail = currentRow?.detail else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []
            if let runnable = detail.runnableCommand, TerminalHooks.canOpen {
                actions.append(UIAction(title: "Run in Terminal", image: UIImage(systemName: "apple.terminal")) { [weak self] _ in
                    self?.delegate?.chatCellRunFallbackCommand(runnable)
                })
            }
            if let command = detail.primaryCommand {
                actions.append(UIAction(title: "Copy Fix Command", image: UIImage(systemName: "terminal")) { _ in
                    UIPasteboard.general.string = command
                    Haptics.play(.success)
                })
            }
            actions.append(UIAction(title: "Choose a Model", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.delegate?.chatCellChooseModel()
            })
            actions.append(UIAction(title: "Copy Details", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = detail.rawText
                Haptics.play(.success)
            })
            return UIMenu(children: actions)
        }
    }
}

private final class ModelFallbackCardControl: UIButton {
    private let badge = UIImageView()
    private let titleLabelView = UILabel()
    private let subtitleLabelView = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private var row: ModelFallbackRow?
    private var style: ChatStyle?
    var onTap: (() -> Void)?

    init() {
        super.init(frame: .zero)
        for view in [badge, titleLabelView, subtitleLabelView, chevron] {
            view.isAccessibilityElement = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        titleLabelView.numberOfLines = 2
        titleLabelView.lineBreakMode = .byTruncatingTail
        subtitleLabelView.numberOfLines = 2
        subtitleLabelView.lineBreakMode = .byTruncatingTail
        badge.contentMode = .center
        chevron.contentMode = .center
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "chat.model-fallback.card"
        addAction(UIAction { [weak self] _ in
            Haptics.play(.light)
            self?.onTap?()
        }, for: .primaryActionTriggered)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(self)
        #endif
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (view: ModelFallbackCardControl, _) in
            view.applyChrome()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.72 : 1 } }

    private func applyChrome() {
        backgroundColor = ChatPalette.promptCard
        layer.cornerRadius = HQShape.radius(18, .card)
        layer.cornerCurve = .continuous
        let accentEdge = PhoneCardColors.attention.resolvedColor(with: traitCollection).withAlphaComponent(0.32)
        let baseEdge = ChatPalette.promptEdge.resolvedColor(with: traitCollection)
        let edge = baseEdge.cgColor.alpha > 0.35 ? baseEdge : accentEdge
        layer.borderColor = edge.cgColor
        layer.borderWidth = max(HQShape.pixel(traitCollection.displayScale), 1)
        badge.backgroundColor = PhoneCardColors.attention
        badge.tintColor = PhoneCardColors.ink(on: PhoneCardColors.attention, minimum: 3)
    }

    func configure(_ row: ModelFallbackRow, style: ChatStyle) {
        self.row = row
        self.style = style
        applyChrome()
        titleLabelView.font = ModelFallbackCardLayout.titleFont(style)
        titleLabelView.textColor = ChatPalette.label
        titleLabelView.text = row.title
        subtitleLabelView.font = ModelFallbackCardLayout.detailFont(style)
        subtitleLabelView.textColor = ChatPalette.label2
        subtitleLabelView.text = row.subtitle
        subtitleLabelView.isHidden = row.subtitle == nil
        badge.layer.cornerRadius = ModelFallbackCardLayout.icon / 2
        badge.image = UIImage(systemName: "exclamationmark.triangle.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        chevron.tintColor = ChatPalette.label2
        accessibilityLabel = row.spoken
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row, let style else { return }
        let inset = ModelFallbackCardLayout.inset
        let iconSize = ModelFallbackCardLayout.icon
        let gap = ModelFallbackCardLayout.gap
        let middle = bounds.height / 2
        let x = inset + iconSize + gap
        let wordsW = ModelFallbackCardLayout.cardWordsWidth(width: bounds.width)
        let (titleH, subH) = ModelFallbackCardLayout.cardWordHeights(row, width: bounds.width, style: style)
        let totalH = titleH + (subH > 0 ? 3 + subH : 0)
        let y = middle - totalH / 2
        badge.frame = CGRect(x: inset, y: middle - iconSize / 2, width: iconSize, height: iconSize)
        titleLabelView.frame = CGRect(x: x, y: y, width: wordsW, height: titleH)
        subtitleLabelView.frame = CGRect(x: x, y: y + titleH + 3, width: wordsW, height: subH)
        chevron.frame = CGRect(x: bounds.width - inset - ModelFallbackCardLayout.chevronWidth, y: middle - 10,
                               width: ModelFallbackCardLayout.chevronWidth, height: 20)
    }
}

private final class ModelFallbackPillControl: UIButton {
    private let dot = UIView()
    private let labelView = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
    private var interactive = false
    var onTap: (() -> Void)?

    init() {
        super.init(frame: .zero)
        for view in [dot, labelView, chevron] {
            view.isAccessibilityElement = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        dot.layer.cornerRadius = 4
        labelView.numberOfLines = 2
        labelView.lineBreakMode = .byTruncatingTail
        chevron.contentMode = .center
        isAccessibilityElement = true
        addAction(UIAction { [weak self] _ in
            guard let self, self.interactive else { return }
            Haptics.play(.light)
            self.onTap?()
        }, for: .primaryActionTriggered)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(self)
        #endif
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (view: ModelFallbackPillControl, _) in
            view.applyChrome()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool { didSet { alpha = (interactive && isHighlighted) ? 0.72 : 1 } }

    private func applyChrome() {
        backgroundColor = ChatPalette.promptCard.resolvedColor(with: traitCollection)
            .withAlphaComponent(interactive ? 0.92 : 0.76)
        layer.cornerRadius = Theme.isDesktop ? min(HQShape.desktopRadius(.capsule), bounds.height / 2) : bounds.height / 2
        layer.cornerCurve = .continuous
        let edge = ChatPalette.promptEdge.resolvedColor(with: traitCollection)
        let fallbackEdge = ChatPalette.separator.resolvedColor(with: traitCollection).withAlphaComponent(0.35)
        layer.borderColor = (edge.cgColor.alpha > 0 ? edge : fallbackEdge).cgColor
        layer.borderWidth = max(HQShape.pixel(traitCollection.displayScale), 1)
    }

    func configure(_ row: ModelFallbackRow, style: ChatStyle) {
        interactive = row.presentation == .pill
        isUserInteractionEnabled = interactive
        dot.backgroundColor = interactive ? PhoneCardColors.attention : ChatPalette.green
        labelView.font = ModelFallbackCardLayout.pillFont(style)
        labelView.textColor = interactive ? ChatPalette.label : ChatPalette.label2
        labelView.text = row.title
        chevron.tintColor = ChatPalette.label2
        chevron.isHidden = !interactive
        accessibilityTraits = interactive ? .button : .staticText
        accessibilityLabel = row.spoken
        accessibilityIdentifier = interactive ? "chat.model-fallback.pill" : "chat.model-fallback.restored"
        applyChrome()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.isDesktop ? min(HQShape.desktopRadius(.capsule), bounds.height / 2) : bounds.height / 2
        let padH: CGFloat = 14
        let dotSize: CGFloat = 8
        let dotGap: CGFloat = 8
        let chevW: CGFloat = interactive ? 8 : 0
        let chevGap: CGFloat = interactive ? 6 : 0
        let midY = bounds.height / 2
        dot.frame = CGRect(x: padH, y: midY - dotSize / 2, width: dotSize, height: dotSize)
        let textX = padH + dotSize + dotGap
        let textW = max(1, bounds.width - textX - padH - chevW - chevGap)
        labelView.frame = CGRect(x: textX, y: 0, width: textW, height: bounds.height)
        if interactive {
            chevron.frame = CGRect(x: bounds.width - padH - chevW, y: midY - 7, width: chevW, height: 14)
        }
    }
}

// MARK: - Detail sheet

enum ModelFallbackSheet {
    static func make(detail: ModelFallbackRow.Detail,
                     onRunInTerminal: ((String?) -> Void)? = nil,
                     onSetEnvVar: ((String) -> Void)? = nil,
                     onChooseModel: @escaping () -> Void,
                     onOpenProviders: (() -> Void)?) -> UIViewController {
        var dismissAndThen: ((@escaping () -> Void) -> Void)?
        let view = ModelFallbackSheetView(
            detail: detail,
            onRunInTerminal: onRunInTerminal.map { run in
                { command in
                    dismissAndThen? { run(command) }
                }
            },
            onSetEnvVar: onSetEnvVar.map { openEnv in
                { key in
                    dismissAndThen? { openEnv(key) }
                }
            },
            onChooseModel: {
                dismissAndThen? { onChooseModel() }
            },
            onOpenProviders: onOpenProviders.map { open in
                {
                    dismissAndThen? { open() }
                }
            }
        )
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        let sheet = ChatSheet.wrap(host, title: "Model Fallback", detents: [.medium(), .large()])
        if detail.isActionable {
            sheet.sheetPresentationController?.selectedDetentIdentifier = .large
        }
        dismissAndThen = { [weak sheet] next in
            if let sheet, sheet.presentingViewController != nil {
                sheet.dismiss(animated: true, completion: next)
            } else {
                next()
            }
        }
        return sheet
    }
}

private struct ModelFallbackSheetView: View {
    let detail: ModelFallbackRow.Detail
    let onRunInTerminal: ((String?) -> Void)?
    let onSetEnvVar: ((String) -> Void)?
    let onChooseModel: () -> Void
    let onOpenProviders: (() -> Void)?

    @State private var copiedCommand = false
    @State private var copiedDetails = false
    @State private var showTechnical = false

    private var accentColor: Color { Color(uiColor: PhoneCardColors.attention) }
    private var cardSurface: Color { Color(uiColor: HQPalette.sheetCard) }
    private var codeSurface: Color { Color(uiColor: ChatPalette.codeFill) }

    private var showsFixCard: Bool {
        detail.primaryCommand != nil || (detail.primaryEnvVar != nil && onSetEnvVar != nil)
    }

    private var hasPrimaryFixAction: Bool {
        (detail.primaryCommand != nil && onRunInTerminal != nil) || (detail.primaryEnvVar != nil && onSetEnvVar != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                routeCard
                Text(detail.explanation)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fallback.sheet.explanation")

                if showsFixCard {
                    fixCard
                }

                actionButtons
                technicalSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: HQPalette.sheetPage).ignoresSafeArea())
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.18))
                    .overlay(Circle().strokeBorder(accentColor.opacity(0.42), lineWidth: 1))
                Image(systemName: "exclamationmark.triangle.fill")
                    .hqSymbolFont(16, weight: .semibold, cap: 22)
                    .foregroundStyle(accentColor)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Switched to \(detail.fallbackName)")
                    .font(Font.hq(.headline))
                    .foregroundStyle(Color.hqLabel)
                Text(detail.kicker)
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(accentColor)
            }
            Spacer(minLength: 0)
        }
    }

    private var routeCard: some View {
        HStack(spacing: 8) {
            Text(detail.primaryName)
                .font(Font.hq(.footnote).weight(.semibold))
                .strikethrough(true, color: Color.hqLabel2)
                .foregroundStyle(Color.hqLabel2)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.hqFill3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .lineLimit(1)

            Image(systemName: "arrow.right")
                .font(Font.hq(.caption).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .accessibilityHidden(true)

            Text(detail.fallbackName)
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.4), lineWidth: 1)
                )
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(detail.routeStatus)
                .font(Font.hq(.caption).weight(.medium))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous)
                .strokeBorder(Color.hqStroke.opacity(0.55), lineWidth: 0.75)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(detail.primaryName) switched to \(detail.fallbackName). \(detail.routeStatus)")
    }

    private var fixCard: some View {
        let hintText: String? = detail.secondaryHint ?? (detail.primaryCommand == nil ? detail.primaryEnvVar.map { "Set `\($0)` in Hermes’s environment." } : nil)
        let envIsPrimary = detail.primaryCommand == nil || onRunInTerminal == nil
        return VStack(alignment: .leading, spacing: 10) {
            Text("Fix on \(HostWord.phrase)")
                .font(Font.hq(.caption).weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Color.hqLabel2)

            if let command = detail.primaryCommand {
                HStack(spacing: 10) {
                    Text(command)
                        .font(Font.hqSystem(.footnote, design: .monospaced))
                        .foregroundStyle(Color.hqLabel)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = command
                        Haptics.play(.success)
                        copiedCommand = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedCommand = false }
                    } label: {
                        Text(copiedCommand ? "Copied" : "Copy")
                            .font(Font.hq(.caption).weight(.semibold))
                            .foregroundStyle(Color.hqLabel)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.hqFill3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fallback.sheet.copy-command")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(codeSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                if let onRunInTerminal {
                    let runnable = detail.runnableCommand
                    Button {
                        if let runnable {
                            Haptics.play(.light)
                            onRunInTerminal(runnable)
                        } else {
                            UIPasteboard.general.string = command
                            Haptics.play(.success)
                            onRunInTerminal(nil)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "apple.terminal")
                                .font(Font.hq(.subheadline).weight(.semibold))
                            Text(runnable != nil ? "Run in Terminal" : "Copy & Open Terminal")
                                .font(Font.hq(.subheadline).weight(.semibold))
                        }
                        .foregroundStyle(Color.hqOnTint)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(Color.hqTint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fallback.sheet.run-terminal")
                }
            }

            if let hintText {
                if detail.primaryCommand != nil && onRunInTerminal != nil {
                    Divider()
                        .padding(.vertical, 2)
                }
                Text((try? AttributedString(markdown: hintText)) ?? AttributedString(hintText))
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let envVar = detail.primaryEnvVar, let onSetEnvVar {
                let isInvalidToken = detail.rawText.lowercased().contains("invalid bearer token")
                let buttonTitle = isInvalidToken ? "Check \(envVar)" : "Set \(envVar)"
                Button {
                    Haptics.play(.light)
                    onSetEnvVar(envVar)
                } label: {
                    if envIsPrimary {
                        HStack(spacing: 7) {
                            Image(systemName: "key.fill")
                                .font(Font.hq(.subheadline).weight(.semibold))
                            Text(buttonTitle)
                                .font(Font.hq(.subheadline).weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .foregroundStyle(Color.hqOnTint)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 12)
                        .background(Color.hqTint, in: Capsule())
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "key.fill")
                                .font(Font.hq(.footnote).weight(.semibold))
                                .foregroundStyle(Color.hqTintText)
                            Text(buttonTitle)
                                .font(Font.hq(.footnote).weight(.semibold))
                                .foregroundStyle(Color.hqTintText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(Font.hq(.caption2).weight(.semibold))
                                .foregroundStyle(Color.hqLabel3)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 38)
                        .background(codeSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fallback.sheet.set-env")
            }
        }
        .padding(14)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous)
                .strokeBorder(Color.hqStroke.opacity(0.55), lineWidth: 0.75)
        )
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(action: onChooseModel) {
                Text("Choose a Model")
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(hasPrimaryFixAction ? Color.hqLabel : Color.hqOnTint)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: hasPrimaryFixAction ? 42 : 44)
                    .background(hasPrimaryFixAction ? cardSurface : Color.hqTint, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(hasPrimaryFixAction ? Color.hqStroke.opacity(0.6) : Color.clear, lineWidth: 0.75)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fallback.sheet.choose-model")

            HStack(spacing: 10) {
                if let onOpenProviders {
                    Button(action: onOpenProviders) {
                        Text("Provider Settings")
                            .font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(Color.hqLabel)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 42)
                            .background(cardSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.hqStroke.opacity(0.6), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fallback.sheet.providers")
                }

                Button {
                    UIPasteboard.general.string = technicalDump
                    Haptics.play(.success)
                    copiedDetails = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedDetails = false }
                } label: {
                    Text(copiedDetails ? "Copied" : "Copy Details")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 42)
                        .background(cardSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.hqStroke.opacity(0.6), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fallback.sheet.copy-details")
            }
        }
    }

    private var technicalSection: some View {
        DisclosureGroup(isExpanded: $showTechnical) {
            Text(technicalDump)
                .font(Font.hqSystem(.caption, design: .monospaced))
                .foregroundStyle(Color.hqLabel2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(codeSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(.top, 8)
        } label: {
            Text("Technical details")
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
        }
        .tint(Color.hqLabel2)
        .accessibilityIdentifier("fallback.sheet.technical")
    }

    private var technicalDump: String {
        var lines: [String] = []
        if let p = detail.primaryProvider {
            lines.append("Primary: \(detail.primaryID) (\(p))")
        } else {
            lines.append("Primary: \(detail.primaryID)")
        }
        if let f = detail.fallbackProvider {
            lines.append("Fallback: \(detail.fallbackID) (\(f))")
        } else {
            lines.append("Fallback: \(detail.fallbackID)")
        }
        lines.append(detail.rawText)
        return lines.joined(separator: "\n")
    }
}
