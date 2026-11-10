// The Bots and Sessions titles switch gateways (spec 1x-settings §4.6; owner: "A + unread dots"): with two or more
// saved gateways the title gets the system's title menu (gateways with "In Use" / "Signed Out" / "N New", then Add
// Gateway… and Manage Gateways…) and the subtitle names the gateway in use, after a news dot when another gateway has
// news. One saved gateway: the plain title, as before. The menu hangs on the subtitle under the inline large title — no
// custom title view, no extra height. No `titleMenuProvider` and no compact `subtitleView`: with either, iOS draws a
// centred title on scroll with its own menu chevron beside the subtitle's (owner, build 284: "MORE ⌄ / Mac Studio ⌄"
// moved to the centre, "two down arrows… confusing"); without them the title scrolls away as it does with one gateway.

import UIKit

@MainActor final class GatewayTitleSwitcher {
    weak var host: UIViewController?
    let services: any AppServices
    let settings: any SettingsServices
    let baseTitle: String
    /// Called when the switcher turns off (one gateway left): the host shows its own subtitle again.
    var onDeactivate: (() -> Void)?
    private(set) var isActive = false
    private var token: UUID?

    init(host: UIViewController, services: any AppServices, settings: any SettingsServices, baseTitle: String) {
        self.host = host
        self.services = services
        self.settings = settings
        self.baseTitle = baseTitle
        token = settings.gateways.observe { [weak self] in self?.refresh() }
        refresh()
    }

    isolated deinit {
        if let token { settings.gateways.stopObserving(token) }
    }

    var gateways: any GatewayAccounts { settings.gateways }

    func refresh() {
        guard let item = host?.navigationItem else { return }
        let active = gateways.accounts.count > 1
        if active {
            isActive = true
            apply()
        } else if isActive {
            isActive = false
            item.titleMenuProvider = nil
            item.subtitleView = nil
            item.largeSubtitleView = nil
            item.attributedSubtitle = nil
            item.subtitle = nil
            subtitleButtons = []
            onDeactivate?()
        }
    }

    /// The subtitle as a button that opens the gateway menu: iOS 26 shows no title menu with an inline large title
    /// (spec §4.6 UNKNOWN 1, checked on the simulator), so the fallback the spec names carries the chevron.
    private var subtitleButtons: [UIButton] = []
    private var lastShown: [String] = []
    /// The gateway a running switch is going to (its landing is announced).
    private var announcedSwitch: String?

    /// The link problem's words, as the Bots list words them.
    private var linkWords: String? { OutageClock.shared.words(services.connection) }   // [offline] one reading for every header

    /// "Switching to X…", "Offline · X", "X"; a news dot first when another gateway has news.
    var subtitleText: String {
        let rows = gateways.accounts
        if let switching = gateways.switchingTo, let row = rows.first(where: { $0.id == switching }) {
            return "Switching to \(row.title)…"
        }
        let title = rows.first(where: \.isCurrent)?.title ?? ""
        return [linkWords, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func apply() {
        guard isActive, let item = host?.navigationItem else { return }
        let text = subtitleText
        let news = gateways.otherNews > 0 && gateways.switchingTo == nil
        var title = AttributedString()
        if news {
            var dot = AttributedString("● ")
            dot.foregroundColor = HQPalette.tint
            dot.font = HQFont.system(ofSize: 9, weight: .bold) // a11y-font-ok: a decorative dot, hidden from VoiceOver
            dot.baselineOffset = 1.5
            title += dot
        }
        var words = AttributedString(text)
        words.foregroundColor = HQPalette.label2
        words.font = HQFont.preferred(.footnote)
        title += words
        // [botslist] One spoken line (parity §2 L128). The page's name is left out: the large title beside this button is
        // its own VoiceOver element on iOS (a header reading "Bots"), so "Bots" would be read twice.
        let switching = gateways.switchingTo.flatMap { id in gateways.accounts.first { $0.id == id }?.title }
        let spoken = GatewayNews.switcherLabel(page: nil, gateway: rowsCurrentTitle, switchingTo: switching, link: linkWords,
                                               otherNews: gateways.otherNews)
        // The inline large title draws `largeSubtitleView` (the only one: see the header).
        if subtitleButtons.isEmpty { subtitleButtons = [makeSubtitleButton()] }
        for button in subtitleButtons {
            var config = button.configuration ?? .plain()
            config.attributedTitle = title
            button.configuration = config
            button.accessibilityLabel = spoken
            button.accessibilityHint = "Shows your gateways."
            // While a switch runs the menu is not offered (`gateway-title.tsx:73-75`).
            button.isUserInteractionEnabled = switching == nil
            button.accessibilityTraits = switching == nil ? [.button] : [.button, .notEnabled]
            button.sizeToFit()
        }
        // The switch landed: say where we are now (once, from the page on screen).
        if let was = announcedSwitch, switching == nil {
            announcedSwitch = nil
            if was == rowsCurrentTitle, host?.viewIfLoaded?.window != nil { HQAnnounce.say("Now on \(was)") }
        } else if let switching {
            announcedSwitch = switching
        }
        if item.largeSubtitleView !== subtitleButtons[0] { item.largeSubtitleView = subtitleButtons[0] }
        item.titleMenuProvider = nil
        item.subtitleView = nil
        host?.navigationController?.navigationBar.setNeedsLayout()
        // What the menu shows per row (news, signed out, name): an open menu follows changes.
        let shown = gateways.accounts.map { "\($0.id)|\($0.title)|\($0.news)|\($0.hasSession)|\($0.isCurrent)" }
        if shown != lastShown { lastShown = shown; updateOpenMenus() }
    }

    private func makeSubtitleButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)
            .applying(UIImage.SymbolConfiguration(weight: .semibold)))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = HQPalette.label2
        // [mac-audit] Owner 2026-11-02: one line, cut at the end; a long computer name ("alex’s Mac Studio") wrapped
        // onto two clipped lines under the title.
        config.titleLineBreakMode = .byTruncatingTail
        let button = TallTouchButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(title: "Gateways", children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self.map { $0.menu([]).children } ?? [])
        }])
        button.accessibilityIdentifier = "gateway-switcher"
        button.contentHorizontalAlignment = .leading
        return button
    }

    private var rowsCurrentTitle: String { gateways.accounts.first(where: \.isCurrent)?.title ?? "" }

    // MARK: The menu (`S/gateway-title.tsx:23-36`)

    func menu(_ suggested: [UIMenuElement]) -> UIMenu {
        Haptics.play(.selection)
        gateways.checkSoon()
        return menuContent()
    }

    /// Counts that land while the menu is open update it in place (`S/gateway-title.tsx:61` patches subtitles live).
    private func updateOpenMenus() {
        for button in subtitleButtons {
            button.contextMenuInteraction?.updateVisibleMenu { [weak self] current in
                guard let self else { return current }
                return current.replacingChildren(self.menuContent().children)
            }
        }
    }

    /// One item per saved gateway, the one in use checked; picking another switches to it (the title menu's first group;
    /// [filters-only] no longer in the Bots bar's Filter, owner 2026-11-03).
    func gatewayItems() -> [UIAction] {
        let rows = gateways.accounts
        return rows.map { row -> UIAction in
            let status: String? = row.isCurrent ? "In Use" : !row.hasSession ? "Signed Out"
                : row.unreachable ? SettingsHub.cantReach : GatewayNews.newsLabel(row.news)
            // [mac-audit] Owner 2026-11-02: two gateways with one name (both on this Mac, both "alex’s Mac Studio")
            // also show their address, or only the check mark told them apart.
            let twin = rows.contains { $0.id != row.id && $0.title == row.title }
            let address = twin ? GatewayNaming.host(row.account.baseURL, port: true) : ""
            let subtitle = [address, status ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            // [botslist] While a switch runs no other gateway can be picked (`gateway-title.tsx:73-75`).
            // Hosted by Nous: a cloud beside its name.
            let action = UIAction(title: row.title, subtitle: subtitle.isEmpty ? nil : subtitle,
                                  image: CloudGatewayFlow.isCloud(row.account.baseURL) ? UIImage(systemName: "cloud") : nil,
                                  attributes: gateways.switchingTo == nil ? [] : .disabled,
                                  state: row.isCurrent ? .on : .off) { [weak self] _ in
                self?.switchTo(row)
            }
            action.accessibilityIdentifier = "gateway-menu-\(row.title)"
            return action
        }
    }

    private func menuContent() -> UIMenu {
        let gatewayItems = gatewayItems()
        let add = UIAction(title: "Add Gateway…", image: UIImage(systemName: "plus")) { [weak self] _ in
            guard let self else { return }
            GatewaySwitchGuard.confirm(switchingTo: nil, from: self.host) { [weak self] in
                guard let self else { return }
                AddGatewayFlow.present(from: self.host, services: self.services)
            }
        }
        let cloud = UIAction(title: CloudCopy.menuTitle, image: UIImage(systemName: "cloud")) { [weak self] _ in
            guard let self else { return }
            GatewaySwitchGuard.confirm(switchingTo: nil, from: self.host) { [weak self] in
                guard let self else { return }
                CloudGatewayFlow.present(from: self.host, services: self.services)
            }
        }
        cloud.accessibilityIdentifier = "gateway-menu-cloud"
        // In use and hosted by Nous: its own agent page, one tap from the title.
        var manageCloud: UIAction?
        if let current = gateways.accounts.first(where: \.isCurrent), CloudGatewayFlow.isCloud(current.account.baseURL) {
            // The agent's own page on Hermes Cloud (Start, Stop, Restart, Update, its size): Manage Gateways… below
            // already opens the Gateways page, so the two items no longer lead to the same place.
            let url = current.account.baseURL
            let action = UIAction(title: CloudCopy.manageAgent, image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                guard let self, let host = self.host else { return }
                CloudGatewayFlow.present(from: host, services: self.services, agent: url)
            }
            action.accessibilityIdentifier = "gateway-menu-cloud-manage"
            manageCloud = action
        }
        let manage = UIAction(title: "Manage Gateways…", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            guard let self, let host = self.host else { return }
            SettingsScreens.presentGateways(from: host, services: self.services)
        }
        return UIMenu(title: "Gateways", children: [
            UIMenu(options: .displayInline, children: gatewayItems),
            UIMenu(options: .displayInline, children: [manageCloud, add, cloud, manage].compactMap { $0 }),
        ])
    }

    private func switchTo(_ row: GatewayAccountRow) {
        guard !row.isCurrent else { return }
        GatewaySwitchGuard.confirm(switchingTo: row.title, from: host) { [weak self] in self?.switchNow(row) }
    }

    private func switchNow(_ row: GatewayAccountRow) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.gateways.switchTo(row.id)
            } catch GatewaySwitchError.needsSignIn(let account) {
                AddGatewayFlow.present(from: self.host, services: self.services, prefill: account)
            } catch let error as AccountStorageError {      // [offline] §3.4: the storage sentence, in the same alert
                FailureAlert.present(title: "Couldn’t Switch to \(row.title)", reason: StartupProblems.storage,
                                     detail: "\(error)", from: self.host, whole: true) { [weak self] in self?.switchTo(row) }
            } catch {
                FailureAlert.present(title: "Couldn’t Switch to \(row.title)",
                                     reason: GatewaySwitchError.reason(switchingTo: row.title),
                                     detail: "\(error)", from: self.host) { [weak self] in self?.switchTo(row) }
            }
        }
    }
}

/// The footnote-size gateway subtitle is about 20 pt tall: its touch area reaches 44 pt while it draws, and lays out,
/// at its own size. The extra height goes above the text, over the large title (which takes no taps), because the bar
/// ends a few points under the subtitle and a touch below it would land on the list. The bar's own views around the
/// subtitle are exactly its size, so `TallTouchNavigationBar` hands it the touches above it.
final class TallTouchButton: UIButton {
    nonisolated static let minimumTouchHeight: CGFloat = 44
    /// The buttons on screen, for the bar to find.
    fileprivate static let live = NSHashTable<TallTouchButton>.weakObjects()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { Self.live.remove(self) } else { Self.live.add(self) }
    }

    /// `bounds` grown upward to at least `minimumTouchHeight`, bottom edge kept; the width stays the text's.
    nonisolated static func touchRect(_ bounds: CGRect) -> CGRect {
        let height = max(bounds.height, minimumTouchHeight)
        return CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return super.point(inside: point, with: event) }
        return Self.touchRect(bounds).contains(point)
    }
}

/// The tabs' navigation bar: a touch on the large title just above a `TallTouchButton` goes to the button (its own
/// `point(inside:)` can't reach past the bar's wrappers, which are exactly its size). Touches on the bar's buttons are
/// left as they are.
final class TallTouchNavigationBar: UINavigationBar {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let hit, sequence(first: hit, next: \.superview).contains(where: Self.takesTouches) { return hit }
        for button in TallTouchButton.live.allObjects where button.isDescendant(of: self) && Self.isShowing(button, in: self) {
            let local = convert(point, to: button)
            if button.point(inside: local, with: event) { return button }
        }
        return hit
    }

    /// A control with something to do: the bar's buttons. The large title is a control too, with no actions (no title
    /// menu here), so a touch on it can go to the subtitle.
    private static func takesTouches(_ view: UIView) -> Bool {
        guard let control = view as? UIControl else { return false }
        return control.allControlEvents.rawValue != 0 || !control.allTargets.isEmpty || !control.interactions.isEmpty
    }

    /// Visible and taking touches all the way up to the bar (the large title hides its subtitle on scroll).
    private static func isShowing(_ button: UIView, in bar: UIView) -> Bool {
        guard button.isUserInteractionEnabled else { return false }
        for view in sequence(first: button, next: \.superview) {
            if view === bar { return true }
            if view.isHidden || view.alpha < 0.01 { return false }
        }
        return false
    }
}
