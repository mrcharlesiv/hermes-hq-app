// Shared pieces of the Jobs, Kanban and Artifacts pages (docs/spec/1x-pages.md §2): the header treatment the Bots
// and Sessions tabs use, the HUD and Undo pill (native glass capsules above the tab bar, never a tab-bar accessory),
// the notice under the bar, page states (skeleton, error with Try Again / Copy Details, empty, search miss), haptics.

import SwiftUI
import UIKit

// MARK: - Header

enum PageChrome {
    /// The Bots/Sessions title treatment (build 2, owner 2026-10-10: the large title on the bar row, inline, so the list
    /// starts high) and their bar (clear at rest, the page colour once rows scroll under it). One helper for all pages.
    static func applyListHeader(to controller: UIViewController, title: String) {
        controller.title = title
        controller.navigationItem.largeTitleDisplayMode = .inline
        ListBarAppearance.apply(to: controller.navigationItem)
    }

    /// The page's search behind the bar's magnifier (D-P11: the field "takes up so much space").
    static func installSearch(on controller: UIViewController, placeholder: String, updater: UISearchResultsUpdating)
        -> UISearchController {
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = updater
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = placeholder
        controller.navigationItem.searchController = search
        controller.navigationItem.preferredSearchBarPlacement = .integratedButton
        controller.navigationItem.searchBarPlacementAllowsToolbarIntegration = false
        controller.navigationItem.hidesSearchBarWhenScrolling = false
        return search
    }

    /// A navigation stack for a page tab, set up like the Bots and Sessions tabs'.
    static func navigation(_ root: UIViewController) -> UINavigationController {
        let navigation = PaneNavigationController(rootViewController: root)   // [m9/ipad] routes opens to the right pane
        navigation.navigationBar.prefersLargeTitles = true
        navigation.delegate = PushedPageTitles.shared
        return navigation
    }
}

/// Pages pushed onto a tab's stack (Artifacts or Settings from More, a job, a skill…) get the standard small centred
/// title. Only a tab's root keeps the large title, inline on the bar row: beside a Back button UIKit drops a large
/// title onto its own row, which put every pushed page low on the screen (owner 2026-10-10, "header too far from the top").
final class PushedPageTitles: NSObject, UINavigationControllerDelegate {
    static let shared = PushedPageTitles()

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController,
                              animated: Bool) {
        AppLog.note("screen", "show \(String(describing: type(of: viewController))) (depth \(navigationController.viewControllers.count))")
        FrameMeter.shared.navigation(navigationController, to: viewController, animated: animated, chat: viewController is ChatViewController)   // [diagnostics]
        // [desktoplook] The docked tab bar leaves under a page that hides the bottom bar (a chat), as the system bar does.
        if DesktopTabBar.wanted != nil { MainTabController.current?.desktopTabBar.navigationWillShow(viewController, in: navigationController, animated: animated) }
        HeldSwipeTabBar.willShow(viewController, in: navigationController)   // the tab bar waits for the finger to let go
        PoppedPageRelease.watch(navigationController, animated: animated)   // [perf] build 300
        #if targetEnvironment(macCatalyst)
        MacBackTitle.name(under: viewController, in: navigationController)   // [mac] stress test #104
        #endif
        #if targetEnvironment(macCatalyst)
        MacPlaceTitle.leadInSettingsPane(viewController, in: navigationController)   // [mac-ui-issues]
        MacPlaceTitle.leadPage(viewController, in: navigationController)   // [Mac UI check 2026-11-13] V17
        #endif
        guard viewController !== navigationController.viewControllers.first else {
            #if targetEnvironment(macCatalyst)
            MacPlaceTitle.leadIfMarked(viewController)
            #endif
            return
        }
        viewController.navigationItem.largeTitleDisplayMode = .never
    }

    /// [restore] A push or a pop landed (a held chat push included): the screen the next cold launch reopens.
    /// [perf] Build 300: after an animated push or pop it is noted a moment later, not in the turn that ends the
    /// transition (its preferences write landed in the pop's last frames). Going to the background notes it at once
    /// anyway (AppDelegate).
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController,
                              animated: Bool) {
        if animated { noteLaunchScreenSoon() } else { MainTabController.current?.noteLaunchScreen() }
        ListTrail.page(viewController)   // [diagnostics] Mac 479: a loop crash names a SwiftUI list by address only
        // [desktoplook] The docked tab bar matches the stack that landed (a slide that went astray can't leave it drawn).
        if DesktopTabBar.wanted != nil { MainTabController.current?.desktopTabBar.navigationDidShow(in: navigationController) }
        PointerEffects.install(in: viewController)   // [m9/ipad] rows and round buttons answer a trackpad's pointer
        #if targetEnvironment(macCatalyst)
        MacWindow.pageBar(viewController)            // [mac] rows don't show through the page's title
        #endif
    }

    private var launchNotePending = false

    private func noteLaunchScreenSoon() {
        guard !launchNotePending else { return }
        launchNotePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PoppedPageRelease.delay) { [weak self] in
            self?.launchNotePending = false
            MainTabController.current?.noteLaunchScreen()
        }
    }
}

#if targetEnvironment(macCatalyst)
/// [mac] Stress test 2026-10-28 #104: the Back button names the page it goes back to on the Mac, in both looks (a bare
/// chevron in the Desktop Look, a glass circle in the iOS look). The page under the one shown keeps a title of its own
/// for Back (a list's count stays: it set one); the Desktop Look's stand-in reads the same title (`DesktopBack`).
@MainActor enum MacBackTitle {
    static func name(under page: UIViewController, in navigation: UINavigationController) {
        let stack = navigation.viewControllers
        guard let index = stack.firstIndex(of: page), index > 0 else { return }
        let item = stack[index - 1].navigationItem
        // A page that asked for a bare chevron (`.minimal`, a sheet's flow) keeps it.
        guard item.backButtonTitle == nil, item.backButtonDisplayMode == .default else { return }
        let title = stack[index - 1].title ?? item.title
        if let title, !title.isEmpty { item.backButtonTitle = title }
    }
}
#endif

/// [perf] Build 300, "Smooth back to Bots": a popped page (a chat, mostly) is let go of a moment after the pop, not in
/// the turn that ends it. UIKit drops its last hold on the page there, and taking down a chat's views (its table, its
/// cells, the composer) cost the pop's last frames ~5 ms on a simulator. Held here, it is released once no transition
/// is running (`delay` after the pop, later if another push or pop has started by then). The page has already left:
/// its `viewDidDisappear` / `didMove(toParent: nil)` ran on time (a chat detaches from its session there), only its
/// memory waits.
@MainActor
enum PoppedPageRelease {
    static let delay: TimeInterval = 0.35
    private(set) static var held: [UIViewController] = []
    private static var running = 0
    private static var scheduled = false

    /// Called as a navigation controller is about to show a page: a pop's outgoing page is held from its end.
    static func watch(_ navigationController: UINavigationController, animated: Bool) {
        guard animated, let coordinator = navigationController.transitionCoordinator else { return }
        running += 1
        let from = coordinator.viewController(forKey: .from)
        coordinator.animate(alongsideTransition: nil) { context in
            running -= 1
            // A pop that went through (an edge swipe can be called off): the outgoing page is no longer on the stack.
            if !context.isCancelled, let from, from.navigationController == nil,
               !navigationController.viewControllers.contains(where: { $0 === from }) {
                hold(from)
            }
        }
    }

    static func hold(_ page: UIViewController) {
        held.append(page)
        schedule()
    }

    private static func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            scheduled = false
            // Another push or pop under way: after it, so its frames don't pay for this one.
            guard running == 0 else { schedule(); return }
            held.removeAll()
        }
    }
}

// MARK: - Haptics

@MainActor
enum PagesHaptics {
    static func selection() { Haptics.play(.selection) }
    static func success() { Haptics.play(.success) }
    static func error() { Haptics.play(.error) }
}

// MARK: - HUD, Undo pill, notice

/// A short result out of sight ("Run Started", "Copied"): a glass capsule centred above the tab bar, 1.5 s.
final class PagesHUD: UIView {
    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let stack = UIStackView()
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    private let detailLabel = UILabel()

    private init(text: String, detail: String?, symbol: String?) {
        super.init(frame: .zero)
        accessibilityIdentifier = "pages.hud"
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        if let symbol {
            let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)))
            image.tintColor = HQPalette.label
            image.contentMode = .center
            image.setContentHuggingPriority(.required, for: .horizontal)
            image.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(image)
        }
        label.text = text
        label.font = HQFont.preferred(.subheadline).pagesWeight(.semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HQPalette.label
        label.numberOfLines = 2
        if let detail {
            // A hint under the result (the archive pill: "Archived tasks are on the desktop board.").
            detailLabel.text = detail
            detailLabel.font = HQFont.preferred(.footnote)
            detailLabel.adjustsFontForContentSizeCategory = true
            detailLabel.textColor = HQPalette.label2
            detailLabel.numberOfLines = 0
            let words = UIStackView(arrangedSubviews: [label, detailLabel])
            words.axis = .vertical
            words.spacing = 1
            words.alignment = .leading
            stack.addArrangedSubview(words)
        } else {
            stack.addArrangedSubview(label)
        }
        // UX study #152: a notice with an action (Undo, Cancel) is the Undo pill (`UndoPill`), not this HUD.
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -18),
        ])
        isAccessibilityElement = true
        accessibilityLabel = detail.map { "\(text). \($0)" } ?? text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static weak var current: PagesHUD?

    /// Shows a HUD over `controller`'s tab bar controller (or its window).
    @discardableResult
    static func show(_ text: String, detail: String? = nil, symbol: String? = nil, from controller: UIViewController,
                     duration: TimeInterval? = nil) -> PagesHUD? {
        // A tab bar controller passed itself (an action's result host, `JobActions.resultHost`) hosts it directly.
        let tabs = (controller as? UITabBarController) ?? controller.tabBarController
        guard let host = tabs?.view ?? controller.view.window ?? controller.view else { return nil }
        current?.dismiss(animated: false)
        let hud = PagesHUD(text: text, detail: detail, symbol: symbol)
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.alpha = 0
        host.addSubview(hud)
        // [jobs] The bar the HUD sits over must share the host's view tree. With Desktop Look on, the system tab bar is
        // hidden (it is not under `host` then: a constraint to it stopped the app) and the docked bar stands in for it.
        let docked = host.subviews.last { $0 is DesktopTabBar && !$0.isHidden }
        let tabBar = docked ?? tabs.flatMap { tabs -> UIView? in
            let bar = tabs.tabBar
            return !tabs.isTabBarHidden && !bar.isHidden && bar.isDescendant(of: host) ? bar : nil
        }
        let bottom = tabBar.map { hud.bottomAnchor.constraint(equalTo: $0.topAnchor, constant: -12) }
            ?? hud.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: host.centerXAnchor), bottom,
            hud.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
        ])
        if detail != nil { hud.glass.cornerConfiguration = .uniformCorners(radius: .fixed(22)) }   // two lines: a rounded card
        current = hud
        UIView.animate(withDuration: 0.2) { hud.alpha = 1 }   // motion-ok: opacity only
        HQAnnounce.say(detail.map { "\(text). \($0)" } ?? text)
        var shown = duration ?? 1.5
        #if DEBUG
        // UI tests (`-HQPagesHUDSeconds 6`): a HUD outlasts the runner's wait for the app to settle after a tap.
        let longer = UserDefaults.standard.double(forKey: "HQPagesHUDSeconds")
        if longer > 0 { shown = max(shown, longer) }
        #endif
        let work = DispatchWorkItem { [weak hud] in hud?.dismiss() }
        hud.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + shown, execute: work)
        return hud
    }

    func dismiss(animated: Bool = true) {
        hideWork?.cancel()
        guard animated else { removeFromSuperview(); return }
        UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })   // motion-ok: opacity only
    }
}

/// A one-line notice under the bar ("Couldn't refresh. Showing what was saved."), 3 s, native glass.
@MainActor
final class PageNoticeHost {
    private let toast = ChatNoticeToast()
    private weak var view: UIView?

    init(in view: UIView) {
        self.view = view
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.accessibilityIdentifier = "pages.notice"
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }

    func show(_ text: String, seconds: TimeInterval = 3) {
        view?.bringSubviewToFront(toast)
        // Verify round 2: the can't-reach words are three lines; two cut them off mid-sentence. The whole reason shows,
        // and a long one stays long enough to read.
        toast.show(text, duration: text.count > 80 ? max(seconds, 5) : seconds, spinner: false, lines: 0)
    }

    /// [task-ideas] With a move ("Added … · Show"): tappable, held while touched, as the chat's notices with an action.
    func show(_ text: String, seconds: TimeInterval = 5, action: (title: String, handler: () -> Void)) {
        view?.bringSubviewToFront(toast)
        toast.show(text, duration: max(seconds, 5), spinner: false, action: action, lines: 0)
    }
}

// MARK: - States

enum PageStates {
    /// Load failed with nothing cached: the reason in words, Try Again and Copy Details.
    static func error(title: String, reason: String, retry: @escaping () -> Void) -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.empty().hqScaled()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = title
        config.secondaryText = reason
        var button = UIButton.Configuration.hqMacPush(or: .filled(), capsule: true)   // [mac] Stress test 2026-10-28 #55 (round 6)
        button.title = "Try Again"
        config.button = button
        config.buttonProperties.primaryAction = UIAction { _ in retry() }
        var copy = UIButton.Configuration.hqMacPush(or: .plain())   // [mac] Stress test 2026-10-28 #55 (round 6): a push button, not a link
        copy.title = "Copy Details"
        config.secondaryButton = copy
        config.secondaryButtonProperties.primaryAction = UIAction { _ in
            UIPasteboard.general.string = "\(title)\n\(scrubbed(reason))"
            PagesHaptics.success()
        }
        return config
    }

    /// Details never carry a token or cookie.
    static func scrubbed(_ text: String) -> String {
        // Key=value forms only ("token=…", "Authorization: Bearer …", "session_id=…"); words like "Session not found" stay.
        let pairs = RX.c(#"(?i)\b(token|ticket|cookie|authorization|session_id|sessionid)\s*[=:]\s*(?:bearer\s+)?[^\s&;]+"#).replace(text, with: "$1=…")
        return RX.c(#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#).replace(pairs, with: "Bearer …")
    }

    /// `titleFont`: nil keeps the preset's own title style; pass one to match a lighter empty state elsewhere
    /// (item 10: the Commands sheet's title read larger and heavier than Capabilities' "No Skills Installed").
    static func empty(symbol: String, title: String, text: String, titleFont: UIFont? = nil) -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.empty().hqScaled()
        config.image = UIImage(systemName: symbol)
        config.text = title
        config.secondaryText = text
        if let titleFont { config.textProperties.font = titleFont }
        return config
    }

    static func searchMiss(_ words: String, text: String = "Check the spelling, or try another word.") -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.search().hqScaled()
        config.text = "No Results for “\(words)”"
        config.secondaryText = text
        return config
    }
}

/// UX study #206: a UIKit list's first read gets `RosterStateCopy.slowAfter` (15 s), then it says the gateway is slow
/// (MoreSkeleton's line). `update` on every reload: while loading it arms once; otherwise it resets.
@MainActor
final class SlowLoadClock {
    private var timer: Timer?
    private(set) var slow = false
    /// The 15 s have passed: the list redraws with the slow line.
    var onSlow: (() -> Void)?

    func update(loading: Bool) {
        guard loading else { restart(); return }
        guard timer == nil, !slow else { return }
        let timer = Timer(timeInterval: RosterStateCopy.slowAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.slow = true
                HQAnnounce.say(RosterStateCopy.slowPage)
                self.onSlow?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Try Again (or the read ended): the line goes and the 15 s start over.
    func restart() {
        timer?.invalidate()
        timer = nil
        slow = false
    }

    isolated deinit { timer?.invalidate() }
}

/// UX study #206: the slow line over a shortened skeleton, with Try Again (MoreSkeleton's, and the Jobs list's).
struct PageSlowNote: View {
    var retry: (() -> Void)?
    var identifier = "more.page.slow"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RosterStateCopy.slowPage)
                .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button(RosterStateCopy.tryAgain, action: retry)
                    .font(Font.hq(.subheadline))
                    .accessibilityIdentifier(identifier + ".retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hqPictureBacking()   // [backdrop-cards]
        .padding(.horizontal, Backdrop.app.cards && Backdrop.app.shows ? BackdropCards.side : 20)   // [backdrop-cards] as wide as a card
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Skeleton rows shaped like the page's rows (title bar + shorter subtitle bar; a leading tile on Artifacts).
struct PageSkeletonRow: View {
    var tile: Bool = false
    @State private var dim = false

    /// [settings] The decorative pulse: off under Reduce Motion and while the phone saves power.
    private func pulse() {
        if HQMotion.decorativeStill {
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { dim = false }
        } else if !dim {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { dim = true }   // motion-ok: decorativeStill above
        }
    }
    var body: some View {
        HStack(spacing: 14) {
            if tile { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hqFill3).frame(width: 36, height: 36) }
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.hqFill3).frame(width: geo.size.width * 0.55, height: 15)
                    RoundedRectangle(cornerRadius: 6).fill(Color.hqFill3).frame(width: geo.size.width * 0.8, height: 12)
                }
                .frame(maxHeight: .infinity)
            }
        }
        // [ui-sizing 2026-11-09] 52 pt, as the Tasks and Jobs rows it stands in for (and Artifacts' with its tile): at
        // 68 the page jumped as the rows came in.
        .frame(height: tile ? 36 : 33)
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .opacity(dim ? 0.45 : 1)
        .onAppear { pulse() }
        // [settings] Saving power stops the pulse; it starts again when saving ends (3x-settings §3).
        .onReceive(NotificationCenter.default.publisher(for: PowerState.changed)) { _ in pulse() }
        .accessibilityHidden(true)
    }
}

/// The trailing ⋯ of a row: horizontal `ellipsis` in a 44 pt button (owner decision 4).
struct RowMoreButton<Items: View>: View {
    var label: String
    @ViewBuilder var items: () -> Items
    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
                .hqSymbolFont(20, weight: .semibold, cap: 28)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .foregroundStyle(Color.hqLabel2)
        .accessibilityLabel(label)
    }
}

/// [header-menus] A header's ⋯: its hold menu one tap away (owner 2026-11-03, menu review "Actions you can only reach by
/// long-press": renaming or deleting a section or project was only a hold on its header away). Smaller than a row's ⋯,
/// in label-2, so a list of headers stays quiet; the touch is 44 pt across and `height` down, reaching `above` into the
/// break over the header as the header's own tap does. The plain button style keeps the Mac's pop-up look away.
struct HeaderMoreButton<Items: View>: View {
    var label: String
    var identifier: String
    /// The glyph at the default text size; it grows with the text up to `cap`, so it never crowds the name.
    var glyph: CGFloat = 15
    var cap: CGFloat = 22
    var height: CGFloat = 44
    var above: CGFloat = 0
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
                .hqSymbolFont(glyph, weight: .semibold, cap: cap)
                .foregroundStyle(Color.hqLabel2)
                .frame(width: 44, height: height)
                .contentShape(.interaction, RaisedHitShape(above: above))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

nonisolated extension UIFont {
    func pagesWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// MARK: - The bar's tips

#if targetEnvironment(macCatalyst)
/// [Mac UI check 2026-11-13] An icon-only bar button names itself when the pointer rests on it ("New Job", "Search
/// Sessions"), as the sidebar's buttons do. The window's tip (`MacToolTips`) reads the label off the view under the
/// pointer, and a plain bar item's view doesn't carry its item's label, so the tip found nothing over the bars' "+",
/// magnifiers and ⋯. One tip on each place's bar finds the item under the pointer by its frame and says its label.
@MainActor final class BarItemTips: NSObject, UIToolTipInteractionDelegate {
    static let shared = BarItemTips()

    static func install(on bar: UINavigationBar?) {
        guard let bar, !bar.interactions.contains(where: { ($0 as? UIToolTipInteraction)?.delegate === shared }) else { return }
        let interaction = UIToolTipInteraction()
        interaction.delegate = shared
        bar.addInteraction(interaction)
    }

    func toolTipInteraction(_ interaction: UIToolTipInteraction, configurationAt point: CGPoint) -> UIToolTipConfiguration? {
        guard let bar = interaction.view as? UINavigationBar, let top = bar.topItem else { return nil }
        for item in (top.leftBarButtonItems ?? []) + (top.rightBarButtonItems ?? []) {
            // Words of its own (Edit, Done) or its own view (a pop-up with its title) need no tip.
            guard item.customView == nil, !item.isHidden, item.image != nil, (item.title ?? "").isEmpty,
                  let label = item.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                  let frame = item.frame(in: bar), frame.contains(point) else { continue }
            return UIToolTipConfiguration(toolTip: label, in: frame)
        }
        // Anything else on the bar (a pop-up, a button of the page's own) keeps the window's tip.
        var view = bar.hitTest(point, with: nil)
        while let current = view, current !== bar {
            if let tip = MacToolTips.tip(for: current) { return UIToolTipConfiguration(toolTip: tip, in: current.convert(current.bounds, to: bar)) }
            view = current.superview
        }
        return nil
    }
}
#endif

extension UIViewController {
    /// [Mac UI check 2026-11-13] The tips for this page's bar buttons (`BarItemTips`); nothing off the Mac.
    func installBarItemTips() {
        #if targetEnvironment(macCatalyst)
        BarItemTips.install(on: navigationController?.navigationBar)
        #endif
    }
}
