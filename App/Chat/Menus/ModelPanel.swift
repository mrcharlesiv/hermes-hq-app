// [model-panel] The composer's model panel. The owner asked on 2026-10-31 for "some type of very epic kind of like pop-up
// or bubble that like shows all the available options for the model in terms of like it's available, the context
// window, effort … even when they drag the … effort selector, like it has this animation behind it". On the first
// build they added: "rebuild it to be our own … the slider even … unique to Hermes HQ in a way that is congruent to our
// design language. In fact, the entire thing needs to be that way".
//
// The panel is about one thing: how this chat thinks. Its model, thinking, Fast and skipping approvals are this chat's
// alone in Hermes; only the approval mode is the bot's. The bot's own models (default, fallbacks, auxiliary) live in its
// Bot Info, and app-wide things (saved prompts) stay in the ⋯, so nothing here overlaps them (owner 2026-11-01 on the
// cut that held the whole ⋯: "looks like we're just … cramming everything into one thing"). A glass card grows out of
// the composer's model bubble and takes the keyboard's place; the bar keeps its two rows. Four blocks, top down:
// - Who: the model's name (with its tag) over its maker, ending in up-and-down chevrons. The name is the Switch Model
//   button: a menu of every model, favourites first, then recents, then the whole catalog by provider, and Search All
//   Models (the Models sheet) at the end. (Owner 2026-10-31: "a menu that opens all and shows the favorites first".)
//   Favorites ends in a row that stars or unstars the chat's model, so starring needs no trip to the sheet.
//   The chat's bot sits at the top corner (owner 2026-11-01: "that space is unused"). It acts out how hard it is set to
//   think (at Off it rests and looks at you; at any other level it thinks, faster the harder), cheers on a switch, and
//   a tap opens its Bot Info.
// - Its facts side by side on one solid strip, each a value over what it is ("1M" over Context window, "18%" over
//   Context used, Included over Price, "62% left" over Plan), in equal columns (owner 2026-10-31: "visually balanced").
//   Price and Plan end in a small chevron and open Model Prices and Usage & Limits.
// - Thinking on one slim row (owner 2026-11-01: "something that took up a lot less room"): the level and what it means
//   over a bar lit up to its knob, lights running up the lit part while it moves.
// - Fast, Approval Mode and YOLO as rows of one solid card, like a Settings group (owner 2026-10-31: "your approval
//   settings on it and fast mode"). Fast is a switch; on a model with no fast mode the row dims and says so.
//   Everything in the panel is this chat's except Approval Mode, the bot's rule (Manual, Smart or Off), so that row
//   says so under its name ("Every chat with Hermes"); YOLO, right under it, is this chat's exception (/yolo) and says
//   "No prompts in this chat" (owner 2026-11-01, "Do the weak points": one control reached two ways). Names and the
//   menu's words are Hermes' own (approvals.mode, the desktop app's Approval mode menu, /yolo; owner 2026-11-01: "Idk
//   if these are the same terms that Hermes uses"). Each shield turns orange while nothing asks first.
// Nothing ends in "…". It closes with a tap outside, a swipe down or Escape, folding back into the bubble.

import UIKit

/// What the panel reads and does; `ChatMenus` supplies it.
struct ModelPanelActions {
    var state: () -> ModelPanelState?
    var pick: (ModelChoice) async -> Void
    var setEffort: (String) async -> Void
    var setFast: (Bool) async -> Void
    /// The bot's approval mode ("manual" · "smart" · "off"), and this chat's skip (`/yolo`).
    var setApprovalMode: (String) async -> Void
    var setYolo: (Bool) async -> Void
    /// Reads the approval mode when the chat's info left it out (an older Hermes).
    var loadApprovals: () async -> Void
    var openAll: () -> Void
    /// [menu-stars] Stars or unstars the chat's model (Switch Model's Favorites); nil hides the row.
    var toggleFavorite: (() -> Void)? = nil
    /// The whole catalog by provider, read when the menu opens (nil when it can't be had).
    var allModels: () async -> [ModelPanelGroup]?
    /// Asks for the catalog again after it failed to load; the result shows the next time the menu opens.
    var reloadModels: () async -> Void = {}
    /// `handingOff`: another pop-up (All Models) opens straight after, and takes over bringing the keys back.
    var closed: (_ handingOff: Bool) -> Void
    /// The plan's and the price's pages (Usage & Limits, Model Prices), opened from their facts.
    var openUsage: () -> Void = {}
    var openPrices: () -> Void = {}
    /// [context-window] The chat's bot's Context Window, opened from the Context fact; nil where it can't be changed.
    var openContextWindow: (() -> Void)? = nil
    /// The bot's name and its Bot Info (its default, fallback and auxiliary models), opened by a tap on its face; nil
    /// where there is no Bot Info to open.
    var bot: (name: String, open: () -> Void)? = nil
}

final class ModelPanelView: UIView {
    private let actions: ModelPanelActions
    private weak var chip: ModelChip?
    private var state: ModelPanelState
    /// The lowest the card may reach (in this view): the composer's top, less a gap.
    private let floorY: CGFloat

    private let dim = UIView()
    private let blur = UIVisualEffectView(effect: nil)
    private let card = BackedGlassCard(effect: UIGlassEffect(style: .regular))
    private let scroll = PanelScrollView()
    /// Holds the list; its mask fades the bottom edge while more is below (a row never just stops at the card's edge).
    private let clip = UIView()
    private let fade = CAGradientLayer()
    private let content = UIView()

    private let nameLabel = FitLabel()
    private let tagPill = PillLabel()
    private let makerLabel = FitLabel()
    private let offlineLabel = FitLabel()
    private let factStrip = FactStrip()
    private let face: PanelFace
    private let thinking = ThinkingBar()
    /// [thinking-drive] Behind the card: the drive's starfield or glow.
    private var backdrop: ThinkingBackdrop?
    /// The name and maker are the Switch Model button; its chevrons (or a spinner, mid-switch) end the name.
    private let switchButton = TitleSwitch()
    private let switchChevrons = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))
    private let switchSpinner = UIActivityIndicatorView(style: .medium)
    private let fastTile = PanelRow(symbol: "bolt.fill", name: "Fast", end: .toggle)
    private let approvalsTile = PanelRow(symbol: "checkmark.shield.fill", name: "Approval Mode", end: .menu)
    private let skipTile = PanelRow(symbol: "shield.slash.fill", name: "YOLO", end: .toggle)
    private lazy var settings = PanelGroup(rows: [fastTile, approvalsTile, skipTile])
    /// Each block, for the staggered entrance.
    private var blocks: [[UIView]] = []

    private var closing = false
    private var busy = false

    // [ui-sizing 2026-11-09] 16 pt in from the edge and 12 between blocks (were 20 and 16): the bulkiest card in the chat.
    private static let pad: CGFloat = 16
    private static let blockGap: CGFloat = 12
    static let radius: CGFloat = 34

    // MARK: Presenting

    /// Opens the panel in `host` under `bar` (the composer stays sharp on top, its bubble marked), out of `chip`, no
    /// lower than `floor` (host coordinates). `face`: the chat's bot, whose face sits at the top corner.
    @discardableResult
    static func present(in host: UIView, under bar: UIView, from chip: ModelChip, floor: CGFloat,
                        face: (raw: JSONValue?, profile: String), actions: ModelPanelActions) -> ModelPanelView? {
        guard let state = actions.state() else { return nil }
        let panel = ModelPanelView(actions: actions, chip: chip, state: state, floor: floor, face: face)
        panel.frame = host.bounds
        panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if bar.superview === host { host.insertSubview(panel, belowSubview: bar) } else { host.addSubview(panel) }
        chip.isSelected = true
        panel.holdSwipeBack(true)
        panel.open()
        return panel
    }

    /// The page's back swipes, held while the panel is open (owner 2026-10-31: a drag right on the thinking ring pulled
    /// the whole page off to go back; the bar drags sideways too). Each comes back as it was (a page that holds them itself keeps them held).
    private var heldSwipes: [(recognizer: UIGestureRecognizer, wasEnabled: Bool)] = []

    private func holdSwipeBack(_ hold: Bool) {
        guard hold else {
            for held in heldSwipes { held.recognizer.isEnabled = held.wasEnabled }
            heldSwipes = []
            return
        }
        guard heldSwipes.isEmpty else { return }
        var responder: UIResponder? = superview
        while let next = responder {
            if let navigation = next as? UINavigationController {
                for recognizer in [navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer].compactMap({ $0 }) {
                    heldSwipes.append((recognizer, recognizer.isEnabled))
                    recognizer.isEnabled = false
                }
            }
            responder = next.next
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil { holdSwipeBack(false) }
    }

    private init(actions: ModelPanelActions, chip: ModelChip, state: ModelPanelState, floor: CGFloat,
                 face: (raw: JSONValue?, profile: String)) {
        self.actions = actions
        self.chip = chip
        self.state = state
        self.floorY = floor
        self.face = PanelFace(raw: face.raw, profile: face.profile)
        super.init(frame: .zero)
        accessibilityViewIsModal = true

        // [Mac UI check 2026-11-13] L10: on the Mac the chat stays readable behind the card: a light dim and no blur
        // (the blur smeared your blue bubbles at the column's edge, and the dim and blur together read as a grey slab).
        let mac = DeviceWord.isMac
        dim.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(mac ? 0.3 : 0.45)
                : UIColor.black.withAlphaComponent(mac ? 0.1 : 0.22)
        }
        dim.alpha = 0
        addSubview(blur)
        addSubview(dim)
        if thinking.drive != .calm, !Theme.isDesktop {
            let backdrop = ThinkingBackdrop(drive: thinking.drive)
            addSubview(backdrop)
            self.backdrop = backdrop
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
        dim.addGestureRecognizer(tap)

        card.cornerConfiguration = .capsule(maximumRadius: Self.radius)
        card.clipsToBounds = true
        card.accessibilityIdentifier = "model.panel"
        addSubview(card)
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        card.contentView.addSubview(clip)
        clip.addSubview(scroll)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        scroll.delegate = self
        scroll.addSubview(content)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        card.addGestureRecognizer(pan)

        // A tap back into the field brings the keys up over the card: the panel gives way.
        NotificationCenter.default.addObserver(self, selector: #selector(keysRising), name: UIResponder.keyboardWillShowNotification, object: nil)
        build()
        apply(state, animated: false)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self]) { (view: ModelPanelView, _) in
            view.restyle()
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Building

    private func build() {
        // The name, tag and maker read as the one Switch Model button.
        for label in [nameLabel, makerLabel] as [UIView] { label.isAccessibilityElement = false }
        tagPill.isAccessibilityElement = false
        switchButton.isAccessibilityElement = true
        switchButton.accessibilityTraits = [.button, .header]
        switchButton.accessibilityHint = "Switches this chat's model"
        switchButton.accessibilityIdentifier = "model.panel.switch"
        switchButton.showsMenuAsPrimaryAction = true
        switchButton.preferredMenuElementOrder = .fixed
        switchButton.pressed = { [weak self] down in
            guard let self else { return }
            HQMotion.animate(down ? 0.08 : 0.25) {
                for view in [self.nameLabel, self.tagPill, self.makerLabel, self.switchChevrons] as [UIView] { view.alpha = down ? 0.5 : 1 }
            }
        }
        switchChevrons.contentMode = .center
        switchSpinner.hidesWhenStopped = true
        offlineLabel.text = "Offline · changes wait for the gateway"
        thinking.addTarget(self, action: #selector(effortChosen), for: .primaryActionTriggered)
        thinking.addTarget(self, action: #selector(levelMoved), for: .valueChanged)
        thinking.onDrive = { [weak self] frame, beat in self?.driveMoved(frame, beat) }
        if let bot = actions.bot {
            face.opens(botNamed: bot.name)
            face.addTarget(self, action: #selector(faceTapped), for: .touchUpInside)
        }
        fastTile.addTarget(self, action: #selector(fastTapped), for: .touchUpInside)
        fastTile.accessibilityIdentifier = "model.panel.fast"
        approvalsTile.accessibilityIdentifier = "model.panel.approvals"
        approvalsTile.note = Self.approvalsReach(bot: actions.bot?.name)
        approvalsTile.menu = approvalsMenu()
        skipTile.note = "No prompts in this chat"
        skipTile.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        skipTile.accessibilityIdentifier = "model.panel.skip"
        switchButton.menu = switchMenu()
        var opens: [String: (name: String, open: () -> Void)] = [
            "Price": ("Model Prices", { [weak self] in self?.handOff(to: self?.actions.openPrices ?? {}) }),
            "Plan": ("Usage & Limits", { [weak self] in self?.handOff(to: self?.actions.openUsage ?? {}) })]
        // [context-window] The one place a chat shows its window (owner 2026-11-01 had to ask where to set it).
        if let open = actions.openContextWindow {
            opens[ModelPanelState.Fact.contextTitle] = ("Context Window", { [weak self] in self?.handOff(to: open) })
        }
        factStrip.opens = opens
        for view in [nameLabel, tagPill, makerLabel, switchChevrons, switchSpinner, switchButton, offlineLabel, face, factStrip, thinking, settings] as [UIView] {
            content.addSubview(view)
        }
        restyle()
    }

    private func restyle() {
        // Words on the glass itself take the primary ink (label 2 measured 3.2:1 over the blurred chat).
        nameLabel.font = Self.font(.title2, .bold)
        nameLabel.textColor = ChatPalette.label
        makerLabel.font = Self.font(.subheadline, .medium)
        makerLabel.textColor = ChatPalette.label
        switchChevrons.tintColor = ChatPalette.label2
        switchChevrons.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Self.font(.subheadline, .semibold))
        switchSpinner.color = ChatPalette.label
        offlineLabel.font = Self.font(.footnote, .semibold)
        offlineLabel.textColor = ChatPalette.orange
    }

    /// The text style's size in the given weight (Dynamic Type follows; the traits in force, so a test can set them).
    /// The style's size already carries UI Scale: `face` only sets the weight (`system` scaled it twice: Mac polish #71).
    static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
        let base = HQFont.preferred(style, compatibleWith: UITraitCollection.current)
        return HQFont.face(ofSize: base.pointSize, weight: weight)
    }

    /// The accessibility text sizes, where side-by-side pieces go one (or two) to a line.
    static var accessibilityType: Bool { UITraitCollection.current.preferredContentSizeCategory.isAccessibilityCategory }

    /// The model's name in bold; with `tagInline`, its tag after it in lighter words (when the pill won't fit beside).
    private func nameText(tagInline: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(string: state.name, attributes: [.font: Self.font(.title2, .bold), .foregroundColor: ChatPalette.label])
        if tagInline, let tag = state.tag {
            text.append(NSAttributedString(string: " " + tag, attributes: [.font: Self.font(.title2, .regular), .foregroundColor: ChatPalette.label2]))
        }
        return text
    }

    private func apply(_ next: ModelPanelState, animated: Bool) {
        let modelChanged = next.name != state.name || next.provider != state.provider
        state = next
        let changes = { [self] in
            nameLabel.attributedText = nameText(tagInline: false)
            tagPill.text = next.tag
            makerLabel.text = next.provider
            switchButton.accessibilityLabel = [next.name, next.tag, next.provider].compactMap { $0 }.joined(separator: ", ")
            factStrip.facts = next.facts
            factStrip.isHidden = next.facts.isEmpty
        }
        if animated && modelChanged {
            UIView.transition(with: content, duration: HQMotion.fade, options: [.transitionCrossDissolve, .allowUserInteraction], animations: changes)   // motion-ok: a cross-fade
        } else {
            changes()
        }
        offlineLabel.isHidden = !next.offline
        thinking.stops = next.efforts
        thinking.setStop(next.efforts.firstIndex(of: next.effort) ?? 0, animated: animated)
        thinking.isEnabled = !next.offline
        levelMoved()
        showFast(supported: next.fastSupported, on: next.fastOn)
        fastTile.isEnabled = next.fastSupported && !next.offline
        showApprovals(mode: next.approvalMode, yolo: next.yolo)
        approvalsTile.isEnabled = !next.offline
        skipTile.isEnabled = !next.offline
        switchButton.isEnabled = !next.offline
        switchChevrons.alpha = next.offline ? 0.45 : 1
        // Usage & Limits and Model Prices read the gateway: offline their facts open nothing.
        factStrip.isEnabled = !next.offline
        blocks = [[nameLabel, tagPill, makerLabel, switchChevrons, offlineLabel, face], [factStrip], [thinking], [settings]]
        setNeedsLayout()
    }

    // MARK: Fast and Approvals

    private func showFast(supported: Bool, on: Bool) {
        fastTile.lit = supported && on
        fastTile.showsToggle = supported
        fastTile.value = supported ? (on ? "On" : "Off") : "Not on this model"
    }

    /// The bot's mode on the Approvals row and this chat's skip on its switch; each shield goes orange while nothing
    /// asks first (the bot's rule at Off, or this chat skipping).
    private func showApprovals(mode: String, yolo: Bool) {
        approvalsTile.value = ModelPanelModel.approvalValue(mode: mode)
        approvalsTile.setSymbol(mode == "off" ? "exclamationmark.shield.fill" : "checkmark.shield.fill", warning: mode == "off")
        skipTile.lit = yolo
        skipTile.value = yolo ? "On" : "Off"   // spoken, as Fast's; the switch shows it
        skipTile.setSymbol("shield.slash.fill", warning: yolo)
    }

    /// How far the Approvals row reaches, under its name: the bot's rule, for all its chats.
    static func approvalsReach(bot: String?) -> String {
        guard let bot, !bot.trimmingCharacters(in: .whitespaces).isEmpty else { return "Every chat with this bot" }
        return "Every chat with \(bot)"
    }

    /// Read each time it opens, so it shows what the gateway last said, under the row's reach as its heading.
    private func approvalsMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.approvalItems() ?? []) }])
    }

    private func approvalItems() -> [UIMenuElement] {
        let now = actions.state() ?? state
        let modes = ModelPanelModel.approvalModes.map { entry in
            let action = UIAction(title: entry.name, subtitle: entry.line, state: now.approvalMode == entry.mode ? .on : .off) { [weak self] _ in
                self?.chooseApprovals(entry.mode)
            }
            action.accessibilityIdentifier = "model.panel.approvals.\(entry.mode)"
            return action
        }
        return [UIMenu(title: approvalsTile.note ?? "", options: .displayInline, children: modes)]
    }

    @objc private func skipTapped() {
        guard skipTile.isEnabled else { return }
        chooseYolo(!state.yolo)
    }

    private func chooseApprovals(_ mode: String) {
        guard mode != state.approvalMode else { return }
        Haptics.play(.selection)
        state.approvalMode = mode
        showApprovals(mode: mode, yolo: state.yolo)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.setApprovalMode(mode)
            if !closing { refresh() }
        }
    }

    private func chooseYolo(_ on: Bool) {
        Haptics.play(.selection)
        state.yolo = on
        showApprovals(mode: state.approvalMode, yolo: on)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.setYolo(on)
            if !closing { refresh() }
        }
    }

    // MARK: Switch Model

    /// Read each time it opens: the favourites and recents at once, the catalog once it has loaded (the menu shows
    /// its own loading row meanwhile). Fixed order, so Favorites stays at the top though the menu opens upward.
    private func switchMenu() -> UIMenu {
        let quick = UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.quickSections() ?? []) }
        let all = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor [weak self] in completion(await self?.catalogItems() ?? []) }
        }
        let search = UIAction(title: "Search All Models", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.allTapped() }
        search.accessibilityIdentifier = "model.panel.search"
        // [model-scope] Owner 2026-11-03: the menu's title says what a pick changes (this chat), and where the bot's
        // own default is; not at the accessibility text sizes, where it pushed the picks out of the menu.
        return UIMenu(title: ModelPanelModel.switchMenuTitle(bot: actions.bot?.name, largeText: Self.accessibilityType),
                      children: [quick, UIMenu(title: "All Models", options: .displayInline, children: [all]),
                                 UIMenu(options: .displayInline, children: [search])])
    }

    private func quickSections() -> [UIMenuElement] {
        let now = actions.state() ?? state
        var out: [UIMenuElement] = []
        let starred = now.favorites.map { menuAction($0, maker: true) } + [starAction(now)].compactMap { $0 }
        if !starred.isEmpty {
            out.append(UIMenu(title: "Favorites", options: .displayInline, children: starred))
        }
        if !now.recents.isEmpty {
            out.append(UIMenu(title: "Recent", options: .displayInline, children: now.recents.map { menuAction($0, maker: true) }))
        }
        return out
    }

    /// One submenu per provider ("12 models"); a catalog of one provider lists its models in place.
    private func catalogItems() async -> [UIMenuElement] {
        guard let groups = await actions.allModels(), !groups.isEmpty else {
            // One more go, as the ⋯'s Model menu offered (docs/spec/3x-composer.md §12.2 point 5); the list shows the
            // next time the menu opens.
            let failed = UIAction(title: ModelLoad.menuFailure, attributes: .disabled) { _ in }
            failed.accessibilityIdentifier = "model.loadFailed"
            let again = UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                guard let self else { return }
                Task { await self.actions.reloadModels() }
            }
            again.accessibilityIdentifier = "model.tryAgain"
            return [failed, again]
        }
        if groups.count == 1 { return groups[0].rows.map { menuAction($0, maker: false) } }
        return groups.map { group in
            UIMenu(title: group.title, subtitle: group.rows.count == 1 ? "1 model" : "\(group.rows.count) models",
                   children: group.rows.map { menuAction($0, maker: false) })
        }
    }

    /// [menu-stars] Favorites' last row: Add (or Remove) the chat's model. The next open lists it (or not).
    private func starAction(_ now: ModelPanelState) -> UIAction? {
        guard let toggle = actions.toggleFavorite, !now.name.isEmpty else { return nil }
        let row = ModelPanelModel.starRow(name: now.name, favorite: now.favorites.contains { $0.current }, noFavorites: now.favorites.isEmpty)
        let action = UIAction(title: row.title, subtitle: row.subtitle, image: UIImage(systemName: row.image)) { _ in
            Haptics.play(.selection)
            toggle()
        }
        action.accessibilityIdentifier = "model.panel.star"
        return action
    }

    private func menuAction(_ row: ModelPanelState.Row, maker: Bool) -> UIAction {
        let action = UIAction(title: [row.name, row.tag].compactMap { $0 }.joined(separator: " "),
                              subtitle: maker ? ModelNames.shortProviderName(row.provider) : nil,
                              state: row.current ? .on : .off) { [weak self] _ in self?.switchTo(row) }
        action.accessibilityIdentifier = "model.panel.pick.\(row.model.provider)::\(row.model.id)"
        return action
    }

    // MARK: Layout

    /// The card's resting frame, sized to its content and kept between the safe top and `floorY`.
    private func restingFrame() -> CGRect {
        let width = min(bounds.width - 24, 440)
        let top = safeAreaInsets.top + 12
        let room = max(120, floorY - top)
        let height = layoutContent(width: width)
        let shown = min(height, room)
        // Centred in the chat on the Mac too, as on the iPhone (owner 2026-11-08: "I want it centered"; it had moved over
        // the Mac's bubble at the box's trailing end).
        return CGRect(x: ((bounds.width - width) / 2).rounded(), y: floorY - shown, width: width, height: shown)
    }

    /// Lays the content out for a card `width` wide; returns its height.
    @discardableResult
    private func layoutContent(width: CGFloat) -> CGFloat {
        let pad = Self.pad
        let inner = width - 2 * pad
        var y: CGFloat = pad + 2

        // The model, across the card. Any name fits: the name takes up to three lines before it shrinks, and the maker
        // two (a provider's name can be a sentence), three at the accessibility sizes. The tag rides beside the name in
        // its pill while they share a line; when the name needs more room the tag follows it in words.
        let most = Self.accessibilityType ? 3 : 2
        // The bot's face at the top corner; the name and maker take the width beside it, and the name ends in the
        // Switch Model chevrons.
        let faceSide = PanelFace.side
        let textW = max(0, inner - faceSide - 12)
        let chevronW = ceil(switchChevrons.intrinsicContentSize.width) + 2   // the symbol at its text size
        let nameRoom = max(0, textW - chevronW - 6)
        let tagSize = state.tag == nil ? .zero : tagPill.sizeThatFits(CGSize(width: nameRoom / 2, height: 22))
        let besidePill = max(0, nameRoom - tagSize.width - 8)
        var pillShown = false
        if state.tag != nil, besidePill > 0 {   // no room at all beside the pill: the tag goes inline
            nameLabel.attributedText = nameText(tagInline: false)
            nameLabel.maxLines = 1
            pillShown = nameLabel.fit(width: besidePill).scale >= TextFit.oneLineFloor
        }
        tagPill.isHidden = !pillShown
        let nameW: CGFloat
        if pillShown {
            nameW = min(nameLabel.fittedWidth(width: besidePill), besidePill)
        } else {
            nameLabel.attributedText = nameText(tagInline: state.tag != nil)
            nameLabel.maxLines = Self.accessibilityType ? 4 : 3   // the chevrons take a little of its width
            nameW = min(nameRoom, ceil(nameLabel.fittedWidth(width: nameRoom)))
        }
        let nameH = nameLabel.fittedHeight(width: nameW)
        // A maker that only reads small in its lines (a sign-in's whole sentence) gives its first clause, as on the
        // tiles; the full name stays in the name's spoken label.
        makerLabel.maxLines = most
        if makerLabel.text != state.provider { makerLabel.text = state.provider }
        if !makerLabel.fit(width: textW).comfortable { makerLabel.text = ModelNames.shortProviderName(state.provider) }
        let makerH = makerLabel.fittedHeight(width: textW)
        nameLabel.frame = CGRect(x: pad, y: y, width: max(0, nameW), height: nameH)
        tagPill.frame = CGRect(x: nameLabel.frame.maxX + 8, y: (y + (nameH - tagSize.height) / 2).rounded(),
                               width: tagSize.width, height: tagSize.height)
        makerLabel.frame = CGRect(x: pad, y: y + nameH + 3, width: textW, height: makerH)   // [ui-sizing] 3 pt under the name (was 1)
        // The chevrons on the name's first line, after the name (or its tag).
        let lineH = ceil(Self.font(.title2, .bold).lineHeight)
        let chevronX = (pillShown ? tagPill.frame.maxX : nameLabel.frame.maxX) + 6
        switchChevrons.frame = CGRect(x: chevronX, y: y, width: chevronW, height: min(nameH, lineH))
        switchSpinner.center = CGPoint(x: switchChevrons.frame.midX, y: switchChevrons.frame.midY)
        // The button takes the name and maker and the room beside them, up to the face.
        switchButton.frame = CGRect(x: pad - 8, y: y - 6, width: textW + 14, height: max(44, nameH + 3 + makerH + 12))
        face.frame = CGRect(x: pad + inner - faceSide, y: y - 2, width: faceSide, height: faceSide)
        y += max(nameH + 3 + makerH, faceSide - 2) + Self.blockGap
        if !offlineLabel.isHidden {
            offlineLabel.maxLines = 2
            let h = offlineLabel.fittedHeight(width: inner)
            offlineLabel.frame = CGRect(x: pad, y: y - 4, width: inner, height: h)
            y += h + 8
        }

        // The facts.
        if !factStrip.isHidden {
            let h = factStrip.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
            factStrip.frame = CGRect(x: pad, y: y, width: inner, height: h)
            y += h + Self.blockGap
        }

        // Thinking.
        let thinkingH = thinking.preferredHeight(width: inner)
        thinking.frame = CGRect(x: pad, y: y, width: inner, height: thinkingH)
        y += thinkingH + Self.blockGap

        // Fast and Approvals on one card, a row each.
        let settingsH = settings.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        settings.frame = CGRect(x: pad, y: y, width: inner, height: settingsH)
        y += settingsH + pad
        content.frame = CGRect(x: 0, y: 0, width: width, height: y)
        return y
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dim.frame = bounds
        blur.frame = bounds
        backdrop?.frame = bounds
        guard !closing, card.transform == .identity, opened else { return }
        let rest = restingFrame()
        card.frame = rest
        scroll.frame = card.bounds
        scroll.contentSize = content.bounds.size
        clip.frame = card.bounds
        updateFade()
    }

    /// The bottom 36 pt fade out while the list runs on below the card.
    private func updateFade() {
        let more = scroll.contentSize.height - scroll.contentOffset.y - scroll.bounds.height > 1
        guard more, clip.bounds.height > 0 else { clip.layer.mask = nil; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        let edge = Float(max(0, 1 - 36 / clip.bounds.height))
        fade.locations = [0, NSNumber(value: edge), 1]
        clip.layer.mask = fade
        CATransaction.commit()
    }

    // MARK: Opening and closing

    private var opened = false

    private func chipFrame() -> CGRect? {
        // No bubble to grow out of (the Desktop Look's bar, or the one-row bar): the card rises in place.
        guard let chip, chip.window != nil, !chip.isHidden, chip.alpha > 0.01 else { return nil }
        return chip.convert(chip.bounds, to: self)
    }

    private func open() {
        layoutIfNeeded()
        let rest = restingFrame()
        opened = true
        scroll.frame = CGRect(origin: .zero, size: rest.size)
        scroll.contentSize = content.bounds.size
        clip.frame = CGRect(origin: .zero, size: rest.size)
        let start = chipFrame() ?? rest.insetBy(dx: rest.width * 0.3, dy: rest.height * 0.45)
        Haptics.play(.soft)
        guard !HQMotion.reduced else {
            card.frame = rest
            scroll.frame = card.bounds
            updateFade()
            card.alpha = 0
            HQMotion.animate(HQMotion.fade) { [self] in
                card.alpha = 1
                dim.alpha = 1
            }
            UIAccessibility.post(notification: .screenChanged, argument: switchButton)
            loadApprovalsIfUnknown()
            return
        }
        // The card starts as the bubble; the content waits a beat, then rises in block by block, and the bar fills up
        // to the bot's level.
        card.frame = start
        scroll.frame = CGRect(origin: CGPoint(x: (start.width - rest.width) / 2, y: start.height - rest.height), size: rest.size)
        // Each piece comes back to its own strength (the tiles stay dimmed while offline, Fast where the model has none).
        let strength = Dictionary(blocks.flatMap { $0 }.map { (ObjectIdentifier($0), $0.alpha) }, uniquingKeysWith: { a, _ in a })
        for (i, block) in blocks.enumerated() {
            for view in block {
                view.alpha = 0
                view.transform = CGAffineTransform(translationX: 0, y: 14 + CGFloat(i) * 4)
            }
        }
        clip.frame = CGRect(origin: .zero, size: rest.size)
        HQMotion.spring(duration: 0.62, damping: 0.8, changes: { [self] in
            card.frame = rest
            scroll.frame = CGRect(origin: .zero, size: rest.size)
        }, completion: { [weak self] _ in self?.updateFade() })
        HQMotion.animate(0.3) { [self] in
            dim.alpha = 1
            if !DeviceWord.isMac { blur.effect = UIBlurEffect(style: .systemUltraThinMaterial) }   // [Mac UI check 2026-11-13] L10
        }
        for (i, block) in blocks.enumerated() {
            HQMotion.spring(duration: 0.55, damping: 0.86, delay: 0.08 + Double(i) * 0.045) {
                for view in block {
                    view.alpha = strength[ObjectIdentifier(view)] ?? 1
                    view.transform = .identity
                }
            }
        }
        thinking.fillUp(after: 0.22)
        UIAccessibility.post(notification: .screenChanged, argument: switchButton)
        loadApprovalsIfUnknown()
    }

    /// An older Hermes leaves the approval mode out of the chat's info: read it, and the tile fills in.
    private func loadApprovalsIfUnknown() {
        guard state.approvalMode.isEmpty, !state.offline else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.loadApprovals()
            if !closing, actions.state()?.approvalMode.isEmpty == false { refresh() }
        }
    }

    func close(then: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        chip?.isSelected = false
        holdSwipeBack(false)
        let finish = { [self] in
            removeFromSuperview()
            actions.closed(then != nil)
            then?()
        }
        guard !HQMotion.reduced, let end = chipFrame() else {
            HQMotion.animate(HQMotion.fade, changes: { [self] in
                card.alpha = 0
                dim.alpha = 0
                blur.effect = nil
                backdrop?.alpha = 0
            }, completion: { _ in finish() })
            return
        }
        let size = card.bounds.size
        HQMotion.animate(0.14) { [self] in
            for view in blocks.flatMap({ $0 }) { view.alpha = 0 }
        }
        HQMotion.spring(duration: 0.46, damping: 0.9, changes: { [self] in
            card.transform = .identity
            card.frame = end
            scroll.frame = CGRect(origin: CGPoint(x: (end.width - size.width) / 2, y: end.height - size.height), size: size)
            dim.alpha = 0
            blur.effect = nil
            backdrop?.alpha = 0
        }, completion: { _ in finish() })
    }

    @objc private func tappedOutside() { close() }
    @objc private func keysRising() { close() }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let y = pan.translation(in: self).y
        switch pan.state {
        case .changed:
            // Down follows the finger; up gives a little and stops.
            let shift = y > 0 ? y : -sqrt(-y) * 2
            card.transform = CGAffineTransform(translationX: 0, y: shift)
            dim.alpha = max(0.3, 1 - max(0, y) / 400)
        case .ended, .cancelled:
            if y > 90 || pan.velocity(in: self).y > 900 {
                card.transform = .identity
                close()
            } else {
                HQMotion.spring(duration: 0.45, damping: 0.8) { [self] in
                    card.transform = .identity
                    dim.alpha = 1
                }
            }
        default: break
        }
    }

    // MARK: Actions

    private func refresh() {
        guard let next = actions.state() else { return }
        let switched = next.name != state.name || next.provider != state.provider
        apply(next, animated: true)
        layoutIfNeeded()
        HQMotion.spring(duration: 0.45, damping: 0.85, changes: { [self] in
            let rest = restingFrame()
            card.frame = rest
            clip.frame = card.bounds
            scroll.frame = card.bounds
            scroll.contentSize = content.bounds.size
        }, completion: { [weak self] _ in self?.updateFade() })
        if switched {
            face.cheer()
            thinking.flash()
        }
    }

    /// The face acts out the level under the knob as it moves.
    @objc private func levelMoved() {
        face.show(level: thinking.level ?? "none", fraction: thinking.levelFraction)
    }

    @objc private func effortChosen() {
        guard let level = thinking.level, level != state.effort else { return }
        state.effort = level
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.setEffort(level)
            if !closing { refresh() }
        }
    }

    @objc private func fastTapped() {
        guard state.fastSupported, !busy else { return }
        Haptics.play(.selection)
        let on = !state.fastOn
        state.fastOn = on
        showFast(supported: true, on: on)
        busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.setFast(on)
            busy = false
            if !closing { refresh() }
        }
    }

    @objc private func allTapped() {
        Haptics.play(.selection)
        let open = actions.openAll
        close(then: open)
    }

    // MARK: The drive

    /// [thinking-drive] The backdrop follows the bar's drive: its frames, and its beats.
    private func driveMoved(_ frame: ThinkingFrame, _ beat: ThinkingBeat?) {
        guard let backdrop, !closing else { return }
        if let beat { return backdrop.beat(beat, frame) }
        backdrop.render(frame, knob: thinking.convert(frame.knob, to: backdrop),
                        card: card.convert(card.bounds, to: backdrop), cardRadius: Self.radius)
    }

    // MARK: Handing over

    /// The bot's own models (its default, fallbacks, auxiliary) are in its Bot Info: the face hands over to it.
    @objc private func faceTapped() {
        guard let bot = actions.bot else { return }
        handOff(to: bot.open)
    }

    /// The panel closes into the bubble, then the page it opens comes up (and brings the keys back when it closes).
    private func handOff(to open: @escaping () -> Void) {
        Haptics.play(.selection)
        close(then: open)
    }

    /// Mid-switch a spinner stands where the name's chevrons were.
    private func switchWorking(_ on: Bool) {
        on ? switchSpinner.startAnimating() : switchSpinner.stopAnimating()
        switchChevrons.isHidden = on
    }

    private func switchTo(_ row: ModelPanelState.Row) {
        guard !row.current, !busy else { return }
        Haptics.play(.selection)
        busy = true
        switchWorking(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.pick(row.model)
            busy = false
            switchWorking(false)
            if !closing { refresh() }
        }
    }
}

#if DEBUG
extension ModelPanelView {
    /// Tests: a panel for `state` laid out in a host `hostWidth` wide, without opening it. Returns the panel and its
    /// content (every piece in place, the facts, tiles and ring laid out inside).
    /// `adjust` fills in the ⋯'s words and menu; `floor` is where the card's bottom rests (the room is it less 12).
    static func debugLaidOut(_ state: ModelPanelState, hostWidth: CGFloat, floor: CGFloat = 4000,
                             adjust: (inout ModelPanelActions) -> Void = { _ in }) -> (panel: ModelPanelView, content: UIView) {
        var actions = ModelPanelActions(state: { state }, pick: { _ in }, setEffort: { _ in }, setFast: { _ in },
                                        setApprovalMode: { _ in }, setYolo: { _ in }, loadApprovals: {}, openAll: {},
                                        allModels: { nil }, closed: { _ in })
        adjust(&actions)
        let panel = ModelPanelView(actions: actions, chip: ModelChip(), state: state, floor: floor, face: (nil, "default"))
        panel.frame = CGRect(x: 0, y: 0, width: hostWidth, height: 4000)
        panel.layoutContent(width: min(hostWidth - 24, 440))
        for view in panel.content.subviews { view.layoutIfNeeded() }
        return (panel, panel.content)
    }

    /// Tests: the pieces stacked down the panel, in order (each a frame in the content's space).
    var debugPieces: [(name: String, view: UIView)] {
        let pieces: [(String, UIView)] = [("name", nameLabel), ("tag", tagPill), ("maker", makerLabel), ("chevrons", switchChevrons),
                                          ("offline", offlineLabel), ("face", face), ("facts", factStrip), ("thinking", thinking),
                                          ("settings", settings)]
        return pieces.filter { !$0.1.isHidden }
    }

    /// Screenshots: the bar as if a finger held it at `position` (0…1).
    func debugHoldDial(at position: CGFloat) { thinking.debugHold(at: position) }
    func debugSweepDial() { thinking.debugSweep() }
    func debugWarpDial() { thinking.debugWarp() }
    func debugAllModels() { allTapped() }
    /// Screenshots: Switch Model's menu open, as a tap opens it (the interaction's own presenter; DEBUG only).
    func debugOpenMenu() { Self.openMenu(of: switchButton) }
    private static func openMenu(of button: UIButton) {
        let sel = NSSelectorFromString("_presentMenuAtLocation:")
        guard let interaction = button.contextMenuInteraction, let method = class_getInstanceMethod(type(of: interaction), sel) else { return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        unsafeBitCast(method_getImplementation(method), to: Present.self)(interaction, sel, CGPoint(x: button.bounds.midX, y: button.bounds.midY))
    }
    /// Tests: the Approvals menu's rows as they'd open ("[For This Bot]", "Manual ✓", …; "✓" marks the checked rows).
    func debugApprovalTitles() -> [String] {
        func titles(_ elements: [UIMenuElement]) -> [String] {
            elements.flatMap { element -> [String] in
                if let menu = element as? UIMenu { return (menu.title.isEmpty ? [] : ["[\(menu.title)]"]) + titles(menu.children) }
                return [element.title + ((element as? UIAction)?.state == .on ? " ✓" : "")]
            }
        }
        return titles(approvalItems())
    }
    /// Tests: what the settings rows say.
    var debugTiles: (fast: String?, fastLit: Bool, fastEnabled: Bool, approvals: String?, warning: Bool, reach: String?,
                     skip: Bool, skipWarning: Bool, skipNote: String?) {
        (fastTile.value, fastTile.lit, fastTile.isEnabled, approvalsTile.value, approvalsTile.warning, approvalsTile.note,
         skipTile.lit, skipTile.warning, skipTile.note)
    }
    /// Screenshots: the Approval Mode menu open, as a tap opens it.
    func debugOpenApprovals() { Self.openMenu(of: approvalsTile) }
    /// Screenshots: a fact tapped ([context-window] the Context fact opens Context Window).
    func debugOpenFact(_ title: String) { factStrip.debugOpen(title) }
    /// Tests: a tap on YOLO.
    func debugTapSkip() { skipTapped() }
    /// Tests: what VoiceOver reads for the Approval Mode and YOLO rows.
    var debugApprovalLabels: (approvals: String?, skip: String?, skipValue: String?, skipTraits: UIAccessibilityTraits) {
        (approvalsTile.accessibilityLabel, skipTile.accessibilityLabel, skipTile.accessibilityValue, skipTile.accessibilityTraits)
    }
    /// Tests: the facts strip's columns, and which open a page.
    var debugFacts: [(title: String, opens: Bool)] { factStrip.debugColumns }
    /// Tests: whether the face opens Bot Info, and what VoiceOver says of it.
    /// Tests: which controls VoiceOver reads as dimmed.
    var debugDimmed: [String] {
        [("name", switchButton as UIView), ("thinking", thinking), ("fast", fastTile), ("approvals", approvalsTile), ("skip", skipTile)]
            .filter { $0.1.accessibilityTraits.contains(.notEnabled) }.map(\.0)
    }
    var debugFace: (opens: Bool, label: String?) { (face.isUserInteractionEnabled && face.isAccessibilityElement, face.accessibilityLabel) }
    /// Tests: the card as it would rest: its height, and its content's.
    var debugResting: (card: CGFloat, content: CGFloat) {
        let card = restingFrame().height
        return (card, content.bounds.height)
    }
    /// Tests: the Switch Model menu's rows as they'd open, the catalog's included.
    func debugMenuTitles() async -> [String] {
        func titles(_ elements: [UIMenuElement]) -> [String] {
            elements.flatMap { element -> [String] in
                if let menu = element as? UIMenu { return (menu.title.isEmpty ? [] : ["[\(menu.title)]"]) + titles(menu.children) }
                return [element.title]
            }
        }
        return titles(quickSections()) + ["[All Models]"] + titles(await catalogItems())
    }
}
#endif

extension ModelPanelView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }
}

extension ModelPanelView: UIGestureRecognizerDelegate {
    /// The swipe down starts only from the top of the list (or anywhere when nothing scrolls), never while the thinking
    /// bar moves (an up-or-down drag on its words still closes the card).
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, pan.view === card else { return true }
        if thinking.keepsTouch { return false }
        let velocity = pan.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        return scroll.contentOffset.y <= 0 && velocity.y > 0
    }
}

/// The panel's list scrolls from a capsule too (a scroll view keeps a touch that lands on a control by default); the
/// thinking bar keeps a touch it has taken.
private final class PanelScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if let bar = view as? ThinkingBar { return !bar.keepsTouch }
        return true
    }
}

// MARK: - Thinking

/// The chat's bot at the panel's top corner, beside the model's name. It acts out how hard it is set to think: at Off it
/// rests and looks at you; at any other level it thinks, its animations running at 1× at the least level up to 2.2× at
/// the most. A new model makes it cheer once. A tap opens the bot's Bot Info, where its own default, fallback and
/// auxiliary models live (owner 2026-11-01: the panel and Bot Info "need to work together … we're not overlapping
/// things"); the panel holds this chat's.
final class PanelFace: UIControl {
    static let side: CGFloat = 48   // [ui-sizing] was 60, a quarter of the card's width on a 375 pt phone

    private let face: HeadView
    /// Holds the face; its layer's speed is how fast the face thinks.
    private let holder = UIView()
    private var level = "none"
    private var fraction: CGFloat = 0
    private var cheering = 0

    init(raw: JSONValue?, profile: String) {
        face = HeadView(side: Self.side)
        super.init(frame: .zero)
        holder.isUserInteractionEnabled = false
        face.isUserInteractionEnabled = false
        face.configure(raw: raw, profile: profile)
        holder.addSubview(face)
        addSubview(holder)
        accessibilityIdentifier = "model.panel.face"
        // Off until there is a Bot Info to open; the face still acts the level out.
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A tap opens `bot`'s Bot Info; VoiceOver reads it as a button that says where it goes.
    func opens(botNamed bot: String) {
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = bot
        accessibilityHint = "Opens Bot Info: its default model, fallback models and auxiliary models"
        largeContentTitle = bot
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        holder.bounds = bounds
        holder.center = CGPoint(x: bounds.midX, y: bounds.midY)
        face.frame = holder.bounds
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            HQMotion.spring(duration: 0.3, damping: 0.9) { [self] in
                if HQMotion.reduced { alpha = isHighlighted ? 0.6 : 1 } else { holder.transform = isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity }
            }
        }
    }

    /// `level` ("none" for Off) and where it sits among the thinking levels (0 the least … 1 the most).
    func show(level: String, fraction: CGFloat) {
        self.level = level
        self.fraction = fraction
        refresh()
    }

    private func refresh() {
        guard cheering == 0 else { return }
        if level == "none" { pose(nil, tempo: 1) } else { pose(.thinking, tempo: Float(1 + 1.2 * fraction)) }
    }

    private func pose(_ mood: BotMood?, tempo: Float) {
        if face.posedMood != mood {
            // A new act starts on the clock everyone shares: back to it first, then the tempo.
            setTempo(1, reset: true)
            face.posedMood = mood
        }
        setTempo(mood == nil || HQMotion.decorativeStill ? 1 : tempo, reset: false)
    }

    /// Runs the face's animations at `speed` without a jump: the holder's clock carries on from where it is.
    private func setTempo(_ speed: Float, reset: Bool) {
        let layer = holder.layer
        if reset {
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            return
        }
        guard layer.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = layer.convertTime(now, from: nil)
        layer.beginTime = now
        layer.timeOffset = local
        layer.speed = speed
    }

    /// A new model: the face cheers once, then goes back to thinking at its level.
    func cheer() {
        cheering += 1
        let token = cheering
        setTempo(1, reset: true)
        face.posedMood = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, cheering == token else { return }
            cheering = 0
            refresh()
        }
    }
}

/// How hard the bot thinks, on one slim row (owner 2026-11-01: "made the effort selector something that took up a lot
/// less room"; it was the bot's face inside a 270° ring, about 250 pt tall). "Thinking" with the level and what it means
/// across the top ("High · Thinks hard"), and under them the ring's parts laid straight: a 22 pt bar lit in the tint up
/// to a tint knob ringed in white, a dot at each level, and lights with soft tails running up the lit part into the knob
/// while it moves, more and faster as it climbs. A finger on the bar puts the knob under it and drags it; on the words
/// a sideways drag slides it. A tick at each level crossed; let go and it settles on the nearest. VoiceOver swipes up
/// and down. `.valueChanged` fires on each level crossed, `.primaryActionTriggered` once it settles.
final class ThinkingBar: UIControl {
    /// The accessibility sizes, as of the words' fonts (layout passes can read the view's own traits instead).
    private var largeText = false
    var stops: [String] = [] {
        didSet {
            guard stops != oldValue else { return }
            stop = min(stop, max(0, stops.count - 1))
            relabel(animated: false)
            setNeedsLayout()
        }
    }
    private(set) var stop = 0
    /// The level the knob is on ("none" for Off), nil with no levels.
    var level: String? { stops.indices.contains(stop) ? stops[stop] : nil }

    private let titleLabel = FitLabel()
    private let valueLabel = FitLabel()
    private let track = CAShapeLayer()
    private let lit = CAShapeLayer()
    private let litStops = CAShapeLayer()
    private let darkStops = CAShapeLayer()
    private let knob = UIView()
    private let comets = CometView()

    /// 0…1 along the bar: under the finger while dragging, else easing to `target`.
    private var position: CGFloat = 0
    private var target: CGFloat = 0
    private var velocity: CGFloat = 0
    private var dragging = false
    /// How lively the lights are (0 still … 1.6), up while dragging and with each level crossed, then fading.
    private var energy: CGFloat = 0
    private var phase: CGFloat = 0
    private var link: CADisplayLink?
    #if DEBUG
    private var sweep: (from: CGFloat, elapsed: Double, legs: [(to: CGFloat, seconds: Double)])?
    private var debugFrozen = false
    private var debugKeepsLevel = false
    #endif

    // [thinking-drive] The drive (ThinkingDrive.swift): what the fill draws, how it feels, and its beat.
    let drive = ThinkingDrive.chosen
    /// Nil in the Desktop Look and for Calm (the comets draw instead).
    private let fill: ThinkingFill?
    private let rev: Haptics.Rev?
    /// Lightspeed's timeline: it runs under the calm cases too (the haptics follow it); only the drawing stops.
    private var script: LightspeedScript?
    /// Each frame while the drive runs, and each beat: the panel's backdrop follows it.
    var onDrive: ((ThinkingFrame, ThinkingBeat?) -> Void)?
    private var engaged: CGFloat = 0
    private var heat: CGFloat = 0
    private var motion: CGFloat = 0
    private var lastPosition: CGFloat = 0
    private var beatClock: Double = 0
    private var time: CGFloat = 0
    /// The panel opening: the bar fills with the drive running gently.
    private var filling = false
    /// The fill draws (not under Reduce Motion or while the phone saves power).
    private var drawsDrive: Bool { fill != nil && !HQMotion.decorativeStill }

    /// The bar 22 pt thick (owner 2026-10-31: "I also want the effort selector bar to be wider"), the knob 34 and the
    /// level dots 6, as on the ring before it.
    private static let lineWidth: CGFloat = 22
    private static let knobSide: CGFloat = 34
    private static let dotSide: CGFloat = 6

    override init(frame: CGRect) {
        fill = Theme.isDesktop ? nil : drive.makeFill()
        rev = drive.feel.map { Haptics.Rev(profile: $0) }
        script = drive == .lightspeed ? LightspeedScript() : nil
        super.init(frame: frame)
        for shape in [track, lit] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            shape.actions = ["strokeEnd": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
            layer.addSublayer(shape)
        }
        if let fill { layer.addSublayer(fill.layer) }
        for dots in [darkStops, litStops] {
            dots.actions = ["path": NSNull()]
            layer.addSublayer(dots)
        }
        comets.isUserInteractionEnabled = false
        addSubview(comets)
        knob.isUserInteractionEnabled = false
        knob.layer.borderWidth = 3
        knob.layer.shadowOffset = .zero
        addSubview(knob)
        titleLabel.text = "Thinking"
        valueLabel.maxLines = 2
        addSubview(titleLabel)
        addSubview(valueLabel)
        isAccessibilityElement = true
        accessibilityLabel = "Thinking"
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "model.panel.thinking"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self]) { (bar: ThinkingBar, _) in
            bar.restyle()
            bar.setNeedsLayout()
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Its traits are set as its levels change (adjustable, or words alone); "dimmed" follows `isEnabled` (offline).
    override var accessibilityTraits: UIAccessibilityTraits {
        get { isEnabled ? super.accessibilityTraits : super.accessibilityTraits.union(.notEnabled) }
        set { super.accessibilityTraits = newValue }
    }

    /// Offline the bar and its knob dim (nothing to set).
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            let strength: Float = isEnabled ? 1 : 0.4
            for part in [track, lit, litStops, darkStops] { part.opacity = strength }
            knob.alpha = CGFloat(strength)
            comets.alpha = CGFloat(strength)
            valueLabel.alpha = isEnabled ? 1 : 0.6
        }
    }

    private func restyle() {
        let t = traitCollection
        track.strokeColor = ChatPalette.label.resolvedColor(with: t).withAlphaComponent(0.13).cgColor
        lit.strokeColor = ChatPalette.tint.resolvedColor(with: t).cgColor
        litStops.fillColor = ChatPalette.onTint.resolvedColor(with: t).withAlphaComponent(0.9).cgColor
        darkStops.fillColor = ChatPalette.label.resolvedColor(with: t).withAlphaComponent(0.32).cgColor
        knob.backgroundColor = ChatPalette.tint
        knob.layer.borderColor = ChatPalette.onTint.resolvedColor(with: t).cgColor
        knob.layer.shadowColor = ChatPalette.tint.resolvedColor(with: t).cgColor
        comets.ink = ChatPalette.onTint.resolvedColor(with: t)
        titleLabel.font = ModelPanelView.font(.subheadline, .semibold)
        titleLabel.textColor = ChatPalette.label
        relabel(animated: false, force: true)
    }

    // MARK: Geometry

    private struct Metrics {
        var title: CGRect = .zero
        var value: CGRect = .zero
        /// The bar's centre line, and where the knob's centre runs from and to.
        var barY: CGFloat = 0
        var from: CGFloat = 0
        var to: CGFloat = 0
        var height: CGFloat = 0
    }

    private var shape = Metrics()

    private func metrics(width: CGFloat) -> Metrics {
        var m = Metrics()
        // The level and its line sit beside "Thinking" while they fit on one line there; else they go under it, two
        // lines before they shrink.
        let titleW = min(width, ceil(titleLabel.fittedWidth(width: width)))
        let room = max(0, width - titleW - 12)
        valueLabel.maxLines = 1
        let beside = !largeText && valueLabel.fit(width: room).scale >= TextFit.oneLineFloor
        let titleH = titleLabel.fittedHeight(width: titleW)
        if beside {
            valueLabel.textAlignment = .right
            let valueH = valueLabel.fittedHeight(width: room)
            let rowH = max(titleH, valueH)
            m.title = CGRect(x: 0, y: ((rowH - titleH) / 2).rounded(), width: titleW, height: titleH)
            m.value = CGRect(x: width - room, y: ((rowH - valueH) / 2).rounded(), width: room, height: valueH)
        } else {
            valueLabel.maxLines = largeText ? 6 : 2
            valueLabel.textAlignment = .left
            m.title = CGRect(x: 0, y: 0, width: width, height: titleH)
            m.value = CGRect(x: 0, y: titleH + 2, width: width, height: valueLabel.fittedHeight(width: width))
        }
        let words = max(m.title.maxY, m.value.maxY)
        guard stops.count > 1 else {
            m.height = words
            return m
        }
        m.barY = ceil(words + 8 + Self.knobSide / 2)
        m.from = Self.knobSide / 2
        m.to = width - Self.knobSide / 2
        m.height = m.barY + Self.knobSide / 2
        return m
    }

    func preferredHeight(width: CGFloat) -> CGFloat { ceil(metrics(width: width).height) }

    private func x(at position: CGFloat) -> CGFloat { shape.from + (shape.to - shape.from) * position }

    private func stopPosition(_ index: Int) -> CGFloat {
        stops.count > 1 ? CGFloat(index) / CGFloat(stops.count - 1) : 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape = metrics(width: bounds.width)
        titleLabel.frame = shape.title
        valueLabel.frame = shape.value
        let empty = stops.count < 2
        for part in [track, lit, litStops, darkStops] { part.isHidden = empty }
        knob.isHidden = empty
        comets.isHidden = empty
        accessibilityTraits = empty ? .staticText : .adjustable
        comets.frame = bounds
        fill?.layer.frame = bounds
        guard !empty else { return }
        let line = UIBezierPath()
        line.move(to: CGPoint(x: shape.from, y: shape.barY))
        line.addLine(to: CGPoint(x: shape.to, y: shape.barY))
        for part in [track, lit, litStops, darkStops] { part.frame = bounds }
        track.path = line.cgPath
        lit.path = line.cgPath
        knob.bounds = CGRect(x: 0, y: 0, width: Self.knobSide, height: Self.knobSide)
        knob.layer.cornerRadius = Self.knobSide / 2
        comets.origin = CGPoint(x: shape.from, y: shape.barY)
        comets.lineWidth = Self.lineWidth
        draw()
    }

    /// Puts the lit part, the stops and the knob at `position`, and the lights' state on the comets.
    private func draw() {
        guard stops.count > 1, shape.to > shape.from else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lit.strokeEnd = position
        let on = UIBezierPath(), off = UIBezierPath()
        for i in stops.indices {
            let p = stopPosition(i)
            let c = CGPoint(x: x(at: p), y: shape.barY)
            let dot = UIBezierPath(ovalIn: CGRect(x: c.x - Self.dotSide / 2, y: c.y - Self.dotSide / 2, width: Self.dotSide, height: Self.dotSide))
            if p <= position + 0.001 { on.append(dot) } else { off.append(dot) }
        }
        litStops.path = on.cgPath
        darkStops.path = off.cgPath
        let glow = min(1, energy)
        knob.center = CGPoint(x: x(at: position), y: shape.barY)
        knob.transform = dragging ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
        knob.layer.shadowOpacity = Float(0.35 + 0.45 * glow)
        knob.layer.shadowRadius = 5 + 7 * glow
        CATransaction.commit()
        comets.lit = x(at: position) - shape.from
        comets.energy = drawsDrive || HQMotion.reduced ? 0 : energy   // the clock runs under Reduce Motion only for the beat
        comets.phase = phase
        comets.level = levelFraction
        comets.setNeedsDisplay()
    }

    /// Where the level sits among the thinking levels (0 the least … 1 the most; Off is 0).
    var levelFraction: CGFloat {
        let thinking = stops.filter { $0 != "none" }
        guard let level, let index = thinking.firstIndex(of: level) else { return 0 }
        return thinking.count > 1 ? CGFloat(index) / CGFloat(thinking.count - 1) : 1
    }

    // MARK: The level

    func setStop(_ index: Int, animated: Bool) {
        let next = max(0, min(index, stops.count - 1))
        let changed = next != stop
        stop = next
        target = stopPosition(stop)
        relabel(animated: animated && changed)
        guard animated, !HQMotion.reduced, window != nil else {
            position = target
            velocity = 0
            setNeedsLayout()
            return
        }
        startLink()
    }

    /// "High · Thinks hard": the level's name in semibold, what it means after it.
    private func relabel(animated: Bool, force: Bool = false) {
        largeText = ModelPanelView.accessibilityType
        let name = level.map { ModelNames.effortLabel($0) }
        let line = level.map { stops.count == 1 ? ModelPanelModel.effortLine($0) + " · its only level" : ModelPanelModel.effortLine($0) }
            ?? "This model answers without a thinking step"
        accessibilityValue = [name, line].compactMap { $0 }.joined(separator: ", ")
        let text = NSMutableAttributedString()
        if let name {
            text.append(NSAttributedString(string: name + " · ", attributes: [.font: ModelPanelView.font(.subheadline, .semibold), .foregroundColor: ChatPalette.label]))
        }
        text.append(NSAttributedString(string: line, attributes: [.font: ModelPanelView.font(.subheadline, .regular), .foregroundColor: ChatPalette.label]))
        guard force || valueLabel.attributedText?.string != text.string else { return }
        // Only the words cross-fade.
        guard animated, !HQMotion.reduced else {
            valueLabel.attributedText = text
            setNeedsLayout()
            return
        }
        UIView.transition(with: valueLabel, duration: 0.16, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {   // motion-ok: a cross-fade, guarded above
            self.valueLabel.attributedText = text
        }
        setNeedsLayout()
    }

    // MARK: Touch

    /// On the bar the knob comes under the finger and follows it; on the words a sideways drag slides it.
    private enum Grip { case bar, slide }
    private var grip = Grip.bar
    private var lastTouch: CGPoint = .zero
    /// How far the finger has gone since it landed: a slide waits until it has gone more sideways than up or down.
    private var travel: CGSize = .zero
    private var sliding = false
    /// The level when the finger landed: a drag the list or the page takes back puts it back.
    private var startStop = 0

    /// The bar keeps a touch it has taken from the list and the card's swipe down: on the bar always, on the words
    /// once the finger goes more sideways than up or down (an upward drag there still scrolls the list).
    var keepsTouch: Bool { isTracking && (grip == .bar || sliding || abs(travel.width) >= abs(travel.height)) }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, stops.count > 1 else { return false }
        let p = touch.location(in: self)
        startStop = stop
        lastTouch = p
        travel = .zero
        velocity = 0
        engage()
        if p.y >= shape.barY - Self.knobSide / 2 - 6 {
            grip = .bar
            setPosition(fraction(at: p.x))
        } else {
            grip = .slide
            sliding = false
        }
        startLink()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let p = touch.location(in: self)
        let dx = p.x - lastTouch.x
        travel.width += dx
        travel.height += p.y - lastTouch.y
        lastTouch = p
        switch grip {
        case .bar:
            setPosition(fraction(at: p.x))
        case .slide:
            if !sliding {
                guard abs(travel.width) > 6, abs(travel.width) > abs(travel.height) else { return true }
                sliding = true
            }
            setPosition(min(1, max(0, position + dx / max(1, shape.to - shape.from))))
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        settle()
        sendActions(for: .primaryActionTriggered)
    }

    /// The list or the page took the touch: the level goes back to where it was.
    override func cancelTracking(with event: UIEvent?) {
        if stop != startStop {
            stop = startStop
            relabel(animated: true)
            sendActions(for: .valueChanged)
        }
        settle()
    }

    /// A finger on the bar: the drive starts, its first beat at once.
    private func engage() {
        dragging = true
        filling = false
        lastPosition = position
        beatClock = 1
        rev?.begin()
    }

    private func settle() {
        dragging = false
        if script?.dropsOnLift == true { rev?.dropOut() }
        rev?.end()
        target = stopPosition(stop)
        if HQMotion.reduced || link == nil {
            position = target
            draw()
        }
    }

    private func fraction(at x: CGFloat) -> CGFloat {
        min(1, max(0, (x - shape.from) / max(1, shape.to - shape.from)))
    }

    /// The knob at `next` (0…1): a tick, the words and the face as it crosses a level.
    private func setPosition(_ next: CGFloat) {
        position = next
        let nearest = Int((next * CGFloat(stops.count - 1)).rounded())
        if nearest != stop {
            stop = nearest
            if let rev {
                // [thinking-drive] Harder knocks higher up; the top level lands the jump (Lightspeed's script lands
                // its own, in the frame it draws the hit).
                if dragging, stop == stops.count - 1 {
                    if script == nil {
                        rev.jump()
                        emitBeat(.top)
                    }
                } else {
                    rev.click(drive: Double(stopPosition(stop)))
                }
            } else {
                Haptics.play(.selection)
            }
            relabel(animated: true)
            energy = min(1.6, energy + 0.45)
            sendActions(for: .valueChanged)
        }
        if HQMotion.reduced { draw() }
    }

    override func accessibilityIncrement() { step(1) }
    override func accessibilityDecrement() { step(-1) }

    private func step(_ by: Int) {
        let next = max(0, min(stops.count - 1, stop + by))
        guard next != stop else { return }
        setStop(next, animated: true)
        sendActions(for: .valueChanged)
        sendActions(for: .primaryActionTriggered)
    }

    #if DEBUG
    func debugHold(at position: CGFloat) {
        layoutIfNeeded()
        engage()
        setPosition(position)
        energy = 1.2
        startLink()
    }

    /// Recordings: a finger runs the knob from where it is up to the top, down to the bottom, then back, and lets go.
    func debugSweep() {
        debugSweep(legs: [(1, 2.2), (1, 0.6), (0, 2.6), (0, 0.5), (position, 1.6)])
    }

    /// Recordings of the drive: down to Off, a slow climb to the top, a hold there, then back down to High.
    func debugWarp() {
        let high = stops.firstIndex(of: "high").map(stopPosition) ?? 0.6
        if UserDefaults.standard.bool(forKey: "HQDebugWarpDown") {
            debugSweep(legs: [(0, 0.7), (0, 0.4), (1, 3.6), (1, 1.6), (high, 1.4), (high, 0.3)])
        } else {
            // Lets go at the top: the drop.
            debugKeepsLevel = true     // the sample catalog would put the knob back on High
            debugSweep(legs: [(0, 0.7), (0, 0.4), (1, 3.6), (1, 4.5)])
        }
    }

    /// -HQDebugWarpFreeze <stage:value>: runs the sweep at a fixed 1/120 s a frame and holds on that moment, for exact
    /// screenshots. climb:<heat>, breath:<charge>, hit:<seconds>, cruise:<seconds>, pass:<share>, drop:<seconds>.
    private func debugFrozenNow() -> Bool {
        guard let wanted = UserDefaults.standard.string(forKey: "HQDebugWarpFreeze"), let script else { return false }
        let parts = wanted.split(separator: ":")
        guard parts.count == 2, let value = Double(parts[1]) else { return false }
        let v = CGFloat(value), s = script.state
        switch parts[0] {
        case "climb": return script.stage == .climb && heat >= v && sweep != nil
        case "breath": return s.charge >= v
        case "hit": return script.stage == .hit && (script.secondsSinceHit ?? 0) >= v
        case "cruise": return script.stage == .cruise && (script.secondsSinceHit ?? 0) >= LightspeedScript.hitLength + v
        case "pass": return (s.pass ?? -1) >= v
        case "drop": return (script.secondsSinceDrop ?? -1) >= v
        default: return false
        }
    }

    private func debugSweep(legs: [(to: CGFloat, seconds: Double)]) {
        layoutIfNeeded()
        sweep = (from: position, elapsed: 0, legs: legs)
        engage()
        energy = 1
        startLink()
    }

    /// The sweep's next frame, from the clock; it lets go at the end.
    private func debugSweepStep(_ dt: Double) {
        guard var sweep else { return }
        let legs = sweep.legs
        sweep.elapsed += dt
        self.sweep = sweep
        guard sweep.elapsed < legs.reduce(0, { $0 + $1.seconds }) else {
            self.sweep = nil
            settle()
            if !debugKeepsLevel { sendActions(for: .primaryActionTriggered) }
            return
        }
        var start = sweep.from, left = sweep.elapsed, p = sweep.from
        for leg in legs {
            if left <= leg.seconds {
                let t = CGFloat(left / leg.seconds)
                p = start + (leg.to - start) * (t * t * (3 - 2 * t))
                break
            }
            left -= leg.seconds
            start = leg.to
        }
        setPosition(p)
    }
    #endif

    // MARK: Opening

    /// As the panel opens, the bar fills from empty up to the level, the lights running with it.
    func fillUp(after delay: TimeInterval) {
        guard !HQMotion.reduced, stops.count > 1, target > 0 else { return }
        position = 0
        velocity = 0
        setNeedsLayout()
        let goal = target
        target = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, window != nil, !dragging else { return }
            target = goal
            energy = 1
            filling = true
            startLink()
        }
    }

    /// A new model: the lights run once, with the face's cheer.
    func flash() {
        energy = max(energy, 1)
        startLink()
    }

    // MARK: The clock

    private func startLink() {
        // Under Reduce Motion the clock still runs while a finger holds the bar, for the drive's beat (felt, not seen).
        guard !HQMotion.reduced || (dragging && rev != nil), link == nil, window != nil else { return }
        let link = CADisplayLink(target: BarLinkProxy(self), selector: #selector(BarLinkProxy.tick(_:)))   // motion-ok: guarded by HQMotion.reduced above
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        var dt = CGFloat(min(1.0 / 30, max(0, link.targetTimestamp - link.timestamp)))
        #if DEBUG
        if UserDefaults.standard.string(forKey: "HQDebugWarpFreeze") != nil {
            if debugFrozen { return }
            dt = 1.0 / 120
        }
        #endif
        phase += dt
        #if DEBUG
        debugSweepStep(Double(dt))
        #endif
        runDrive(dt)
        if dragging {
            energy = max(energy, 1)
        } else if HQMotion.reduced {
            position = target
            velocity = 0
            energy = 0
        } else {
            // A critically damped spring along the bar (no overshoot past a level).
            let omega: CGFloat = 15
            velocity += (omega * omega * (target - position) - 2 * omega * velocity) * dt
            position += velocity * dt
            if abs(target - position) < 0.0006, abs(velocity) < 0.01 {
                position = target
                velocity = 0
            }
            energy = max(0, energy - dt * 1.2)
        }
        draw()
        renderDrive(dt)
        #if DEBUG
        if debugFrozenNow() { debugFrozen = true }
        #endif
        if !dragging, position == target, energy <= 0, engaged < 0.005 {
            link.invalidate()
            self.link = nil
            comets.setNeedsDisplay()
            if filling { filling = false }
            engaged = 0
            heat = 0
            renderDrive(0)
        }
    }

    // MARK: The drive

    /// The drive's state for this frame, and its beat: a knock and a light together, faster as the knob climbs.
    private func runDrive(_ dt: CGFloat) {
        time += dt
        if filling, position >= target - 0.002 { filling = false }
        let want: CGFloat = dragging ? 1 : filling ? 0.6 : 0
        engaged += (want - engaged) * min(1, dt * (want > engaged ? 10 : 1.8))
        let hot: CGFloat = dragging || filling ? position : 0
        heat += (hot - heat) * min(1, dt * (hot > heat ? 9 : 1.6))
        let speed = abs(position - lastPosition) / max(dt, 0.001)
        lastPosition = position
        motion += (min(1, speed / 1.2) - motion) * min(1, dt * 8)
        if script != nil, stops.count > 1 {
            // The last level but one, and the point where the knob's level turns to the top one.
            let count = CGFloat(stops.count - 1)
            let events = script?.step(dt: dt, position: position, heat: heat, engaged: engaged, dragging: dragging,
                                      pen: (count - 1) / count, flip: (count - 0.5) / count)
            if events?.hit == true {
                rev?.jump()
                emitBeat(.top)
            }
            if events?.thump == true { rev?.thump() }
        }
        guard dragging, let feel = drive.feel else { return }
        rev?.set(drive: Double(position), motion: Double(motion), hum: script?.hum)
        beatClock += Double(dt) * feel.beatsPerSecond(Double(position))
        if beatClock >= 1 {
            beatClock -= beatClock.rounded(.down)
            if script?.knocksOn ?? true {
                rev?.pulse(drive: Double(position), scale: script?.knockScale ?? 1, sharpen: script?.knockSharpen ?? 0)
                emitBeat(.beat)
            }
        }
    }

    private func driveFrame(_ dt: CGFloat) -> ThinkingFrame {
        ThinkingFrame(drive: position, heat: heat, engaged: engaged, time: time, dt: dt,
                      start: CGPoint(x: shape.from, y: shape.barY), knob: knob.center, lineWidth: Self.lineWidth,
                      tint: ChatPalette.tint.resolvedColor(with: traitCollection), lightspeed: script?.state)
    }

    private func renderDrive(_ dt: CGFloat) {
        guard stops.count > 1 else {
            // A model with no levels picked while the sky is up: it goes with the bar.
            var last = driveFrame(dt)
            last.engaged = 0
            last.lightspeed?.presence = 0
            onDrive?(last, nil)
            return
        }
        let f = driveFrame(dt)
        if let fill {
            // Drawn calmly (Reduce Motion, Low Power Mode): the bar keeps the theme's colour.
            let drawn = drawsDrive
            if drawn { fill.render(f) } else if fill.layer.opacity > 0 { fill.layer.opacity = 0 }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            lit.strokeColor = (drawn ? fill.litColor(f) : f.tint).cgColor
            knob.backgroundColor = drawn ? fill.knobColor(f) : f.tint
            knob.layer.shadowColor = (drawn ? fill.knobColor(f) : f.tint).cgColor
            if drawn { knob.layer.shadowRadius = 5 + 7 * min(1, energy) + 14 * f.heat * f.engaged }
            CATransaction.commit()
        }
        // Drawn calmly, the page behind the card stays as it is too.
        var page = f
        if !drawsDrive {
            page.engaged = 0
            page.lightspeed?.presence = 0
        }
        onDrive?(page, nil)
    }

    private func emitBeat(_ kind: ThinkingBeat) {
        guard drawsDrive else { return }
        let f = driveFrame(0)
        fill?.beat(kind, f)
        onDrive?(f, kind)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            link?.invalidate()
            link = nil
            rev?.end()
        }
    }
}

/// Keeps the display link from holding its bar.
private final class BarLinkProxy: NSObject {
    weak var bar: ThinkingBar?
    init(_ bar: ThinkingBar) { self.bar = bar }
    @objc func tick(_ link: CADisplayLink) {
        guard let bar else { link.invalidate(); return }
        bar.tick(link)
    }
}

/// The lights that run up the bar's lit part while it moves: each a bright head with a tail, rising from the bar's
/// start and pouring into the knob. One at the least thinking, up to three at the most, faster as the level climbs.
final class CometView: UIView {
    /// The bar's start, on its centre line.
    var origin: CGPoint = .zero
    var lineWidth: CGFloat = 22
    /// The lit part's length (points).
    var lit: CGFloat = 0
    var energy: CGFloat = 0
    var phase: CGFloat = 0
    var level: CGFloat = 0
    var ink: UIColor = .white

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        let strength = min(1, energy)
        guard strength > 0.01, lit > 16, let ctx = UIGraphicsGetCurrentContext() else { return }
        let count = 1 + min(2, Int(level * 2.5))
        let speed = 230 + 340 * level
        let tail = min(lit * 0.55, 105)
        let travel = lit + tail
        // Square-cut slices, so the tail is one smooth fade (round caps overlapped into beads).
        ctx.setLineCap(.butt)
        for i in 0..<count {
            let along = ((phase * speed / travel) + CGFloat(i) / CGFloat(count)).truncatingRemainder(dividingBy: 1) * travel
            // In at the start, out into the knob: the head fades over its first stretch, the tail drains at the end.
            let rise = min(1, along / 32)
            let segments = 40
            for k in 0..<segments {
                let a0 = along - tail + tail * CGFloat(k) / CGFloat(segments)
                let a1 = along - tail + tail * CGFloat(k + 1) / CGFloat(segments)
                let from = max(0, a0), to = min(lit, a1)
                guard to > from else { continue }
                let f = CGFloat(k + 1) / CGFloat(segments)
                ctx.setStrokeColor(ink.withAlphaComponent(strength * rise * pow(f, 1.8) * 0.95).cgColor)
                ctx.setLineWidth(lineWidth * (0.22 + 0.4 * f))
                ctx.move(to: CGPoint(x: origin.x + from, y: origin.y))
                ctx.addLine(to: CGPoint(x: origin.x + to, y: origin.y))
                ctx.strokePath()
            }
            guard along <= lit else { continue }
            let head = CGPoint(x: origin.x + along, y: origin.y)
            let r = lineWidth * 0.3
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 8, color: ink.withAlphaComponent(0.9 * strength * rise).cgColor)
            ctx.setFillColor(ink.withAlphaComponent(strength * rise).cgColor)
            ctx.fillEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
        }
    }
}

// MARK: - Pieces

/// A small capsule of text beside the model's name ("Thinking", "Fast"), on a frosted card.
final class PillLabel: UIView {
    var text: String? { didSet { label.text = text; setNeedsLayout() } }
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HQPalette.glassPane   // [glass-design] frosted: the panel is glass in every look
        hqGlassEdge(always: true)   // [glass-design] its thin edge on the panel's glass
        label.textAlignment = .center
        addSubview(label)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (pill: PillLabel, _) in pill.restyle() }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func restyle() {
        label.font = ModelPanelView.font(.caption1, .bold)
        label.textColor = ChatPalette.label2
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: size.height))
        return CGSize(width: ceil(text.width) + 16, height: ceil(label.font.lineHeight) + 6)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        label.frame = bounds
    }
}

/// The model's facts on one solid strip, in equal columns: each value in bold over what it is. One card rather than a
/// tile each, as it is read, not tapped (the Switch To tiles are the ones to tap); it shares their corners. When a value
/// won't sit comfortably in a column that narrow (a long price, or the accessibility text sizes) the columns go two to
/// a line, then one; a short last line shares the full width, so the strip stays even.
final class FactStrip: UIView {
    var facts: [ModelPanelState.Fact] = [] {
        didSet {
            guard facts != oldValue else { return }
            if columns.count != facts.count {
                columns.forEach { $0.removeFromSuperview() }
                columns = facts.map { _ in FactColumn() }
                for column in columns {
                    column.addTarget(self, action: #selector(columnTapped(_:)), for: .touchUpInside)
                    addSubview(column)
                }
            }
            for (column, fact) in zip(columns, facts) { column.fact = fact }
            reopen()
            setNeedsLayout()
        }
    }
    /// [model-panel] Where a column leads, by its fact's title ("Price" → Model Prices, "Plan" → Usage & Limits), and
    /// what a tap there opens; offline (`isEnabled` false) nothing opens.
    var opens: [String: (name: String, open: () -> Void)] = [:] { didSet { reopen() } }
    var isEnabled = true { didSet { if isEnabled != oldValue { reopen() } } }
    private var columns: [FactColumn] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HQPalette.glassPane   // [glass-design] frosted: the panel is glass in every look
        layer.cornerRadius = HQShape.radius(14, .card)
        layer.cornerCurve = .continuous
        hqGlassEdge(always: true)   // [glass-design] its thin edge on the panel's glass
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func reopen() {
        for column in columns {
            column.leadsTo = column.fact.flatMap { opens[$0.title]?.name }
            column.isEnabled = isEnabled
        }
    }

    @objc private func columnTapped(_ column: FactColumn) {
        guard isEnabled, let title = column.fact?.title, let target = opens[title] else { return }
        target.open()
    }

    /// The columns' frames in `width`, line by line.
    private func plan(width: CGFloat) -> [CGRect] {
        let count = columns.count
        guard count > 0, width > 0 else { return [] }
        var tries = [Int]()
        for across in [ModelPanelView.accessibilityType ? min(2, count) : count, (count + 1) / 2, 1] where across >= 1 && !tries.contains(across) {
            tries.append(across)
        }
        func widths(_ across: Int) -> [[CGFloat]] {
            stride(from: 0, to: count, by: across).map { first in
                let n = min(across, count - first)
                return (0..<n).map { _ in width / CGFloat(n) }
            }
        }
        let across = tries.first { across in
            var index = 0
            return widths(across).allSatisfy { line in line.allSatisfy { w in defer { index += 1 }; return columns[index].comfortable(width: w) } }
        } ?? 1
        var frames: [CGRect] = []
        var y: CGFloat = 0, index = 0
        for line in widths(across) {
            let height = line.enumerated().map { columns[index + $0.offset].fittedHeight(width: $0.element) }.max() ?? 0
            var x: CGFloat = 0
            for (i, w) in line.enumerated() {
                let left = x.rounded(), right = i == line.count - 1 ? width : (x + w).rounded()
                frames.append(CGRect(x: left, y: y, width: right - left, height: height))
                x += w
            }
            index += line.count
            y += height
        }
        return frames
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: plan(width: size.width).map(\.maxY).max() ?? 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (column, frame) in zip(columns, plan(width: bounds.width)) { column.frame = frame }
    }

    #if DEBUG
    /// Screenshots: a tap on the column with `title`.
    func debugOpen(_ title: String) {
        if let column = columns.first(where: { $0.fact?.title == title }) { columnTapped(column) }
    }
    /// Tests: each column's caption as drawn, and whether it opens something.
    var debugColumns: [(title: String, opens: Bool)] { columns.map { ($0.fact?.title ?? "", $0.leadsTo != nil && $0.isEnabled) } }
    #endif
}

/// One fact: its value over its caption, centred. The value keeps to one line; the caption may take two. A column that
/// opens a page (Price, the plan) ends its caption in a small chevron and is a button.
final class FactColumn: UIControl {
    var fact: ModelPanelState.Fact? { didSet { relabel() } }
    /// The page a tap opens ("Model Prices"), nil for a plain fact.
    var leadsTo: String? { didSet { if leadsTo != oldValue { relabel() } } }
    private let valueLabel = FitLabel()
    private let captionLabel = FitLabel()
    private static let inset = UIEdgeInsets(top: 10, left: 6, bottom: 11, right: 6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        valueLabel.textAlignment = .center
        captionLabel.textAlignment = .center
        captionLabel.maxLines = 2
        for label in [valueLabel, captionLabel] {
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self]) { (column: FactColumn, _) in column.relabel() }
        relabel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isEnabled: Bool { didSet { if isEnabled != oldValue { relabel() } } }
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, leadsTo != nil else { return }
            HQMotion.animate(0.12) { self.alpha = self.isHighlighted ? 0.5 : 1 }
        }
    }

    private var opens: Bool { leadsTo != nil && isEnabled }

    private func relabel() {
        valueLabel.font = ModelPanelView.font(.subheadline, .semibold)
        valueLabel.textColor = ChatPalette.label
        let captionFont = ModelPanelView.font(.footnote, .regular)
        valueLabel.text = fact?.value
        let caption = NSMutableAttributedString(string: fact?.caption ?? "", attributes: [.font: captionFont, .foregroundColor: ChatPalette.label2])
        if opens, let chevron = UIImage(systemName: "chevron.forward", withConfiguration: UIImage.SymbolConfiguration(font: HQFont.system(ofSize: captionFont.pointSize * 0.8, weight: .semibold))) {
            caption.append(NSAttributedString(string: "\u{2009}"))
            caption.append(NSAttributedString(attachment: NSTextAttachment(image: chevron.withTintColor(ChatPalette.label2, renderingMode: .alwaysOriginal))))
        }
        captionLabel.attributedText = caption
        isUserInteractionEnabled = opens
        accessibilityLabel = fact?.title
        accessibilityValue = fact.map { $0.spoken ?? $0.value }
        accessibilityTraits = opens ? .button : .staticText
        accessibilityHint = opens ? leadsTo.map { "Opens \($0)" } : nil
        accessibilityIdentifier = fact.map { "model.panel.fact." + $0.title.lowercased().replacingOccurrences(of: " ", with: "-") }
        setNeedsLayout()
    }

    /// Whether the words read at their size in a column `width` wide.
    func comfortable(width: CGFloat) -> Bool {
        let room = width - Self.inset.left - Self.inset.right
        return valueLabel.fit(width: room).comfortable && captionLabel.fit(width: room).comfortable
    }

    /// At least 44 pt, the column's words centred in it.
    func fittedHeight(width: CGFloat) -> CGFloat {
        let room = width - Self.inset.left - Self.inset.right
        return max(44, Self.inset.top + valueLabel.fittedHeight(width: room) + 1 + captionLabel.fittedHeight(width: room) + Self.inset.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.inset
        let width = max(0, bounds.width - inset.left - inset.right)
        let valueH = valueLabel.fittedHeight(width: width)
        let captionH = captionLabel.fittedHeight(width: width)
        let top = ((bounds.height - valueH - 1 - captionH) / 2).rounded()
        valueLabel.frame = CGRect(x: inset.left, y: top, width: width, height: valueH)
        captionLabel.frame = CGRect(x: inset.left, y: top + valueH + 1, width: width, height: captionH)
    }
}

/// [model-panel] The model's name and maker as one button (owner 2026-11-01, on a panel that "looks like we're just
/// fucking cramming everything into one thing": Switch Model sat four blocks under the name it changes). A tap opens
/// Switch Model, every model with the favourites first. The name ends in the pop-up chevrons, which a spinner replaces
/// while a switch is under way. It draws nothing itself: the panel's labels sit under it and dim with its press.
final class TitleSwitch: UIButton {
    var pressed: (Bool) -> Void = { _ in }
    override var isHighlighted: Bool { didSet { if isHighlighted != oldValue { pressed(isHighlighted) } } }
    /// Its traits are set once ([.button, .header]); "dimmed" follows `isEnabled` (offline).
    override var accessibilityTraits: UIAccessibilityTraits {
        get { isEnabled ? super.accessibilityTraits : super.accessibilityTraits.union(.notEnabled) }
        set { super.accessibilityTraits = newValue }
    }
}

/// [model-panel] One row of the settings card: a symbol in the tint, its name, and at its end either a switch (Fast)
/// or what it's set to with the pop-up chevrons (Approval Mode, a menu). The row is the button: a tap anywhere on it flips
/// the switch or opens the menu. A note under the name says how far the row reaches ("This chat only"). Where the name
/// and the end don't fit on one line (the largest text sizes) the value goes under the name.
final class PanelRow: UIButton {
    enum End { case toggle, menu }
    /// Fast on: the switch on.
    var lit = false { didSet { if lit != oldValue { toggle?.setOn(lit, animated: window != nil && !HQMotion.reduced) } } }
    /// What it's set to ("Smart", "Off", "Not on this model"); spoken as the row's value.
    var value: String? {
        didSet {
            guard value != oldValue else { return }
            valueWords.text = value
            accessibilityValue = value
            setNeedsLayout()
        }
    }
    /// A switch row shows its words in place of the switch ("Not on this model").
    var showsToggle = true { didSet { if showsToggle != oldValue { setNeedsLayout() } } }
    /// Under the name, smaller: how far the row reaches ("Every chat with Hermes", "This chat only"). Read with the name.
    var note: String? {
        didSet {
            guard note != oldValue else { return }
            noteWords.text = note
            accessibilityLabel = [rowName, note].compactMap { $0 }.joined(separator: ", ")
            setNeedsLayout()
        }
    }
    private(set) var warning = false

    private let end: End
    private let rowName: String
    private let icon = UIImageView()
    private let nameWords = FitLabel()
    private let noteWords = FitLabel()
    private let valueWords = FitLabel()
    private let chevrons: UIImageView?
    private let toggle: UISwitch?
    private var symbol: String
    private static let inset = UIEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)
    private static let iconWidth: CGFloat = 26

    init(symbol: String, name: String, end: End) {
        self.symbol = symbol
        self.end = end
        rowName = name
        chevrons = end == .menu ? UIImageView(image: UIImage(systemName: "chevron.up.chevron.down")) : nil
        toggle = end == .toggle ? UISwitch() : nil
        super.init(frame: .zero)
        icon.contentMode = .center
        nameWords.text = name
        nameWords.maxLines = 2
        noteWords.maxLines = 2
        valueWords.maxLines = 2
        chevrons?.contentMode = .center
        toggle?.isUserInteractionEnabled = false
        for view in [icon, nameWords, noteWords, valueWords, chevrons, toggle].compactMap({ $0 }) as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        if end == .menu {
            showsMenuAsPrimaryAction = true
            preferredMenuElementOrder = .fixed
        }
        accessibilityLabel = name
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self]) { (row: PanelRow, _) in
            row.recolor()
            row.setNeedsLayout()
        }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A new symbol; `warning` draws it orange (Approvals while nothing asks first).
    func setSymbol(_ name: String, warning: Bool) {
        guard name != symbol || warning != self.warning else { return }
        symbol = name
        self.warning = warning
        recolor()
    }

    override var isEnabled: Bool { didSet { recolor() } }
    /// A switch row is a toggle to VoiceOver. Read each time, not set once, so "dimmed" follows `isEnabled` (offline,
    /// or Fast on a model without it).
    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            var traits = super.accessibilityTraits
            if end == .toggle { traits.insert(.toggleButton) }
            if !isEnabled { traits.insert(.notEnabled) }
            return traits
        }
        set { super.accessibilityTraits = newValue }
    }
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            HQMotion.animate(isHighlighted ? 0.08 : 0.25) {
                self.backgroundColor = self.isHighlighted ? ChatPalette.label.withAlphaComponent(0.08) : .clear
            }
        }
    }

    private func recolor() {
        icon.image = UIImage(systemName: symbol)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: ModelPanelView.font(.body, .semibold))
        icon.tintColor = warning ? ChatPalette.orange : ChatPalette.tint
        nameWords.font = ModelPanelView.font(.body, .regular)
        nameWords.textColor = ChatPalette.label
        noteWords.font = ModelPanelView.font(.footnote, .regular)
        noteWords.textColor = ChatPalette.label2
        valueWords.font = ModelPanelView.font(.body, .regular)
        valueWords.textColor = ChatPalette.label2
        chevrons?.tintColor = ChatPalette.label2
        chevrons?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: ModelPanelView.font(.footnote, .semibold))
        toggle?.onTintColor = ChatPalette.tint
        alpha = isEnabled ? 1 : 0.45
    }

    private var switchShown: Bool { toggle != nil && showsToggle }
    private var endWidth: CGFloat {
        if switchShown { return toggle?.intrinsicContentSize.width ?? 51 }
        return chevrons.map { ceil($0.image?.size.width ?? 12) + 2 } ?? 0
    }

    private struct Plan { var name: CGRect; var note: CGRect; var value: CGRect; var height: CGFloat }

    private func plan(width: CGFloat) -> Plan {
        let inset = Self.inset
        let x = inset.left + Self.iconWidth + 12
        let endRoom = endWidth > 0 ? endWidth + 8 : 0
        let room = max(0, width - x - inset.right - endRoom)
        let showsValue = !switchShown && !(valueWords.text ?? "").isEmpty
        let hasNote = !(noteWords.text ?? "").isEmpty
        nameWords.maxLines = 1
        valueWords.maxLines = 1
        // With a note the value keeps its own width and the name and note share what's left; without one the name
        // keeps its width and the value takes the rest.
        let nameW: CGFloat, besideRoom: CGFloat
        if hasNote && showsValue {
            besideRoom = min(ceil(valueWords.fittedWidth(width: room)), room / 2)
            nameW = max(0, room - besideRoom - 12)
        } else {
            nameW = min(room, ceil(nameWords.fittedWidth(width: room)))
            besideRoom = max(0, room - nameW - 12)
        }
        let beside = !showsValue || (!ModelPanelView.accessibilityType
            && valueWords.fit(width: besideRoom).scale >= TextFit.oneLineFloor
            && (!hasNote || nameWords.fit(width: nameW).scale >= TextFit.oneLineFloor))
        if beside {
            nameWords.maxLines = 2
            let column = showsValue ? nameW : room
            let nameH = nameWords.fittedHeight(width: column)
            let noteH = hasNote ? noteWords.fittedHeight(width: column) : 0
            let leftH = nameH + (hasNote ? 1 + noteH : 0)
            let valueH = showsValue ? valueWords.fittedHeight(width: besideRoom) : 0
            let height = max(50, ceil(inset.top + max(leftH, valueH, switchShown ? 31 : 0) + inset.bottom))
            let top = ((height - leftH) / 2).rounded()
            let name = CGRect(x: x, y: top, width: column, height: nameH)
            let note = CGRect(x: x, y: top + nameH + 1, width: column, height: noteH)
            let value = CGRect(x: x + room - besideRoom, y: ((height - valueH) / 2).rounded(), width: besideRoom, height: valueH)
            return Plan(name: name, note: note, value: value, height: height)
        }
        nameWords.maxLines = 2
        valueWords.maxLines = 3
        let nameH = nameWords.fittedHeight(width: room)
        let noteH = hasNote ? noteWords.fittedHeight(width: room) : 0
        let noteY = inset.top + nameH + (hasNote ? 1 : 0)
        let valueY = noteY + noteH + 1
        let valueH = valueWords.fittedHeight(width: room)
        let height = max(50, ceil(valueY + valueH + inset.bottom))
        return Plan(name: CGRect(x: x, y: inset.top, width: room, height: nameH),
                    note: CGRect(x: x, y: noteY, width: room, height: noteH),
                    value: CGRect(x: x, y: valueY, width: room, height: valueH), height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: plan(width: size.width).height) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let p = plan(width: bounds.width)
        let inset = Self.inset
        icon.frame = CGRect(x: inset.left, y: 0, width: Self.iconWidth, height: bounds.height)
        nameWords.frame = p.name
        noteWords.frame = p.note
        noteWords.isHidden = p.note.height == 0
        valueWords.frame = p.value
        valueWords.textAlignment = p.value.minX > p.name.minX + 1 ? .right : .left
        valueWords.isHidden = switchShown
        toggle?.isHidden = !switchShown
        if let toggle {
            let size = toggle.intrinsicContentSize
            toggle.frame = CGRect(x: bounds.width - inset.right - size.width, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        if let chevrons {
            chevrons.frame = CGRect(x: bounds.width - inset.right - endWidth, y: 0, width: endWidth, height: bounds.height)
        }
    }
}

/// [model-panel] The settings card: rows on one solid card (radius 14), a hairline between them from the words' start,
/// as a grouped list draws them. Each row's press shades only its own part.
final class PanelGroup: UIView {
    let rows: [PanelRow]
    private var lines: [UIView] = []

    init(rows: [PanelRow]) {
        self.rows = rows
        super.init(frame: .zero)
        backgroundColor = HQPalette.glassPane   // [glass-design] frosted: the panel is glass in every look
        layer.cornerRadius = HQShape.radius(14, .card)
        layer.cornerCurve = .continuous
        hqGlassEdge(always: true)   // [glass-design] its thin edge on the panel's glass
        clipsToBounds = true
        rows.forEach { addSubview($0) }
        lines = rows.dropFirst().map { _ in UIView() }
        lines.forEach { addSubview($0) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (group: PanelGroup, _) in group.recolor() }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func recolor() { lines.forEach { $0.backgroundColor = ChatPalette.label.withAlphaComponent(0.12) } }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: rows.reduce(0) { $0 + $1.sizeThatFits(size).height })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        let hair = 1 / max(1, traitCollection.displayScale)
        for (i, row) in rows.enumerated() {
            let h = row.sizeThatFits(bounds.size).height
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
            if i > 0 { lines[i - 1].frame = CGRect(x: 14 + 26 + 12, y: y - hair / 2, width: bounds.width - 52, height: hair) }
            y += h
        }
    }
}

/// [Mac UI check 2026-11-13] L10, round 3: the model card's glass bent the person's blue bubbles behind its edge into a
/// blue smear (the light iOS look). On the Mac a backing of the page (the pop-ups' veil) sits right under the glass,
/// moving, sizing, fading and rounding with it, so the glass only ever has the backing behind it. The iPhone keeps
/// its clear glass.
final class BackedGlassCard: UIVisualEffectView {
    private let backing = UIView()

    override init(effect: UIVisualEffect?) {
        super.init(effect: effect)
        backing.isUserInteractionEnabled = false
        backing.backgroundColor = ChatPalette.popupVeil
        backing.layer.cornerCurve = .continuous
        backing.isHidden = !DeviceWord.isMac
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        backing.removeFromSuperview()
        superview?.insertSubview(backing, belowSubview: self)
        syncBacking()
    }

    override func removeFromSuperview() {
        backing.removeFromSuperview()
        super.removeFromSuperview()
    }

    override var frame: CGRect { didSet { syncBacking() } }
    override var bounds: CGRect { didSet { syncBacking() } }
    override var center: CGPoint { didSet { backing.center = center } }
    override var transform: CGAffineTransform { didSet { backing.transform = transform } }
    override var alpha: CGFloat { didSet { backing.alpha = alpha } }
    override var isHidden: Bool { didSet { backing.isHidden = isHidden || !DeviceWord.isMac } }

    /// Inside the glass's edge by a point, so no corner of the backing shows past the glass's own rounding.
    private func syncBacking() {
        guard backing.superview != nil else { return }
        backing.bounds = CGRect(origin: .zero, size: CGSize(width: max(0, bounds.width - 2), height: max(0, bounds.height - 2)))
        backing.center = center
        backing.layer.cornerRadius = max(0, min(ModelPanelView.radius, bounds.height / 2) - 1)
    }
}
