// Pieces the More pages share (docs/spec/3x-morepages.md §0.4): the hosting controller a SwiftUI page is pushed in
// (small title on the bar row, the app's themed grouped page), the page states (skeleton, error with Try Again / Copy
// Details, empty), the bot picker for per-bot pages, and the offline footer.

import SwiftUI
import UIKit

/// Item 9: the one top inset every pushed More page starts at, under its bar — the gap the More root itself uses
/// above its first card (`MoreMetrics.sectionGap / 2`). Pages stopped setting their own value (0, a near-zero header
/// view, or nothing at all, which left the system's own ~40 pt) once this was the shared default.
enum MorePageMetrics {
    static let topGap: CGFloat = MoreMetrics.sectionGap / 2
}

/// `MorePageController`'s rootView: `HQScaledRoot` (shared well beyond More) plus the one top inset every pushed
/// More page uses, applied here so individual pages don't each pick their own (item 9).
struct MorePageRoot<Content: View>: View {
    var content: HQScaledRoot<Content>

    var body: some View {
        content.contentMargins(.top, MorePageMetrics.topGap, for: .scrollContent)
    }
}

/// A SwiftUI More page on More's navigation stack. `onAppear` / `onDisappear` let a model start and stop its polling.
final class MorePageController<Content: View>: UIHostingController<MorePageRoot<Content>>, KeyRefreshing {
    var onAppear: (() -> Void)?
    var onDisappear: (() -> Void)?
    /// Kept alive with the page (a model, a `PageBarCapsule`, a `NavEditBar`).
    var retained: [AnyObject] = []
    /// ⌘R while this page tops a sheet (`KeyRefreshing`): what its pull does.
    var keyRefresh: (() -> Void)?

    init(title: String, identifier: String? = nil, _ content: Content) {
        super.init(rootView: MorePageRoot(content: HQScaledRoot(content)))
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
        if let identifier { view.accessibilityIdentifier = identifier }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage   // [glass] clear while shown in a glass sheet (Prompts)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onAppear?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

/// Skeleton rows while a page's first read is on its way. Still there after `RosterStateCopy.slowAfter`, it says the
/// gateway is slow above the rows, with Try Again when the page can read again, as the Bots list does (UX study #206).
struct MoreSkeleton: View {
    var rows = 6
    var tile = false
    var label = "Loading…"
    var retry: (() -> Void)? = nil
    @State private var slow = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            if slow {
                PageSlowNote(retry: retry.map { retry in {
                    slow = false
                    attempt += 1
                    retry()
                } })
            }
            VStack(spacing: 0) {
                ForEach(0..<(slow ? min(rows, RosterStateCopy.slowSkeletonRows) : rows), id: \.self) { _ in PageSkeletonRow(tile: tile) }
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityIdentifier("more.page.loading")
            Spacer(minLength: 0)
        }
        .task(id: attempt) {
            try? await Task.sleep(for: .seconds(RosterStateCopy.slowAfter))
            guard !Task.isCancelled else { return }
            slow = true
            HQAnnounce.say(RosterStateCopy.slowPage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.hqGroupedPage)
    }
}

/// A first read that failed with nothing to show: the reason in words, Try Again and Copy Details (`PageStates.error`).
struct MoreErrorState: View {
    var title: String
    var reason: String
    /// The page's name for the not-available line; read from a "Couldn't Load <Page>" title when not given.
    var page: String? = nil
    var retry: () -> Void
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?

    var body: some View {
        if reason == MoreWire.olderHermes {
            // [mac] Stress test 2026-10-28 #10: a page this Hermes doesn't have isn't a failure. Its own line under the
            // title (not the title again), and no Try Again or Copy Details, which can't change anything.
            MoreEmptyState(symbol: "exclamationmark.triangle", title: MoreWire.notAvailableTitle,
                           text: MoreWire.notAvailableBody(page ?? MoreWire.pageName(fromFailureTitle: title)))
        } else {
            failure
        }
    }

    private var failure: some View {
        ContentUnavailableView {
            UnavailableTitle(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason).hqMacFont(MacType.emptyBodyFont)   // [mac] Stress test 2026-10-28 #52
        } actions: {
            Button("Try Again", action: retry)
                .hqEmptyActionButtonStyle()   // [mac] Stress test 2026-10-28 #55 (round 6): the plain push button on the Mac
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("more.page.retry")
            Button(copied ? "Copied" : "Copy Details") {
                UIPasteboard.general.string = "\(title)\n\(PageStates.scrubbed(reason))"
                PagesHaptics.success()
                HQAnnounce.say("Copied")
                // "Copied" for two seconds, then the button's own name again.
                copied = true
                copiedTask?.cancel()
                copiedTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { copied = false }
                }
            }
            .hqMacPushOnly()   // [mac] Stress test 2026-10-28 #55 (round 6): a push button beside Try Again, not a link
        }
        .hqMacEmptyPlacement()   // [mac] Stress test 2026-10-28 #9
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hqGroupedPage)
        .accessibilityIdentifier("more.page.error")
    }
}

struct MoreEmptyState<Actions: View>: View {
    var symbol: String
    var title: String
    var text: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            UnavailableTitle(title, systemImage: symbol)
        } description: {
            Text(text).hqMacFont(MacType.emptyBodyFont)   // [mac] Stress test 2026-10-28 #52
        } actions: {
            actions()
        }
        .hqMacEmptyPlacement()   // [mac] Stress test 2026-10-28 #9
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hqGroupedPage)
        .accessibilityIdentifier("more.page.empty")
    }
}

/// [mac] Stress test 2026-10-28 #9: a per-bot page's empty or error state under its Bot picker, on the Mac. Drawn as a
/// row in the page's List it stood near the top, and in the Desktop Look inside an outlined box. Here the picker is the
/// card the List would draw (readable width, the page's inset under the bar) and the state fills the rest of the page,
/// centred with the one lift every state has, with no card round it, in both looks.
struct MoreStateUnderPicker<State: View>: View {
    var bots: [Bot]
    @Binding var selection: String
    var title = "Bot"
    @ViewBuilder var state: () -> State

    var body: some View {
        VStack(spacing: 0) {
            MoreBotPicker(title: title, bots: bots, selection: $selection, card: true)
                .frame(maxWidth: DeviceWord.isMac ? MacForm.readableWidth : .infinity)
                .padding(.horizontal, MacInset.side)
                .padding(.top, MacInset.top)
            state()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hqGroupedPage)
    }
}

/// A ContentUnavailableView title that wraps: the plain `Label(title, systemImage:)` keeps one line and cuts the
/// words off at accessibility sizes ("No Skills I…", UX study #99).
struct UnavailableTitle: View {
    let title: String
    let systemImage: String
    /// [mac] Stress test 2026-10-28 round 8: the symbol drawn over the title in the label itself. Prompts' state, a
    /// row in a short sheet's List, showed no symbol (the system's state leaves its icon out when it judges the room
    /// short), unlike every other state.
    var stacked = false

    init(_ title: String, systemImage: String, stacked: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.stacked = stacked
    }

    var body: some View {
        if stacked {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .hqMacFont(MacType.emptySymbolFont)
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityHidden(true)
                Text(title).lineLimit(nil).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .hqMacFont(MacType.emptyTitleFont)
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label {
            Text(title).lineLimit(nil).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .hqMacFont(MacType.emptyTitleFont)   // [mac] Stress test 2026-10-28 #52: one empty-state title and symbol
        } icon: {
            Image(systemName: systemImage).hqMacFont(MacType.emptySymbolFont)
        }
    }
}

extension MoreEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, text: String) {
        self.init(symbol: symbol, title: title, text: text) { EmptyView() }
    }
}

/// The bot a per-bot page reads (Files, Review, Messaging, Star Map, Capabilities, Connectors, Import Into): a menu row
/// with the bot's head and name. Pages show it only when the gateway has more than one bot.
/// `card`: drawn outside a List (a menu Picker there shows only its value), as a grouped card of its own.
struct MoreBotPicker: View {
    var title = "Bot"
    var bots: [Bot]
    @Binding var selection: String
    var card = false
    /// [mac] Stress test 2026-10-28 #55: the row a List draws, in a UIKit table's own cell (Files, Changes): the label,
    /// then the menu at the trailing edge, with no card of its own (the table's cell is the card).
    var row = false
    var identifier = "more.bot-picker"

    /// [mac] Stress test 2026-10-28 round 6: one Bot row on every page. It was 51 pt as a card (Messaging, Star Map), 65
    /// as a List or table row (Files, Changes, Connectors, Capabilities), and in the iOS look a capsule against a 20 pt
    /// card. On the Mac every kind is the form's one row height (`MacForm.rowHeight`) with the list's own row insets;
    /// the card has the list's card corners.
    static var macHeight: CGFloat { MacForm.rowHeight }
    static let macCardRadius: CGFloat = 20

    var body: some View {
        if DeviceWord.isMac {
            macBody
        } else {
            phoneBody
        }
    }

    @ViewBuilder private var macBody: some View {
        let _ = Theme.touch()
        // [mac] Stress test 2026-10-28 round 8: one Bot row on every More page. The card (Messaging, Star Map) and the
        // table row (Files, Changes) drew the borderless menu picker, the List row (Connectors, Import Sessions) the
        // bordered pop-up in the form's control column, mid-row; Files' label took the table cell's smaller font. Now
        // every kind is the label in body text and the bordered pop-up (`MacPopUp`) at the trailing edge, the same
        // inset from the row's edge.
        let line = HStack(spacing: 12) {
            label
            Spacer(minLength: 8)
            MacPopUp(label: title, selection: $selection, options: bots.map(\.id)) { id in
                bots.first(where: { $0.id == id })?.name ?? id
            }
            .accessibilityIdentifier(identifier)
        }
        .font(Font.hq(.body))
        .frame(minHeight: Self.macHeight)
        .accessibilityElement(children: .contain)
        if card {
            let radius = Theme.isDesktop ? DesktopRows.radius : Self.macCardRadius
            line
                .padding(.horizontal, Self.macSide)
                .background(Theme.isDesktop ? Color.hqPage : Color(uiColor: HQPalette.card),
                            in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.isDesktop ? Color.hqStroke : Color.clear, lineWidth: 1))
        } else if row {
            // The cell's hosting margins are 0: the row's own sides.
            line.padding(.horizontal, Self.macSide)
        } else {
            // In a List: the same sides, and no room over and under (the List's own made this row 74 pt against the
            // card's 44 on Messaging and Star Map).
            line.listRowInsets(EdgeInsets(top: 0, leading: Self.macSide, bottom: 0, trailing: Self.macSide))
        }
    }

    /// [mac] Stress test 2026-10-28 round 8: the card's and the table row's sides, a List row's own inset.
    static let macSide: CGFloat = 20

    @ViewBuilder private var phoneBody: some View {
        if row {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                picker.labelsHidden()
            }
            .accessibilityElement(children: .contain)
        } else if card {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                picker.labelsHidden()
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 52)
            // A List row's own card (hqGroupedCard is the page's grey in light, so the card vanished: UX study #94);
            // in the Desktop Look the flat outlined box its lists draw.
            .background(Theme.isDesktop ? Color.hqPage : Color(uiColor: HQPalette.card),
                        in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(Theme.isDesktop ? Color.hqStroke : Color.clear, lineWidth: 1))
            .accessibilityElement(children: .contain)
        } else {
            picker
        }
    }

    /// [mac] Stress test 2026-10-28 #55: on the Mac the card is the box the Desktop Look's lists draw (4 pt corners, as
    /// the picker rows on Capabilities, Messaging and Connectors), not a blue-outlined capsule. The iOS look and the
    /// iPhone keep the one-row card's capsule.
    private var cardRadius: CGFloat { DeviceWord.isMac && Theme.isDesktop ? DesktopRows.radius : 26 }

    private var picker: some View {
        Picker(selection: $selection) {
            ForEach(bots) { bot in
                Text(bot.name).tag(bot.id)
            }
        } label: {
            label
        }
        .hqMenuPicker()
        .accessibilityIdentifier(identifier)
    }

    private var label: some View {
        HStack(spacing: 12) {
            if let bot = bots.first(where: { $0.id == selection }) {
                HeadImage(raw: bot.head, profile: bot.id, size: 28)
            }
            Text(title).foregroundStyle(Color.hqLabel)
        }
    }
}

/// A per-bot page's remembered bot (`pages.more.bot.<page>.<account>`), read as the default bot when it left the roster.
@MainActor
enum MoreBotChoice {
    static func key(_ page: String, _ account: GatewayAccount) -> String { "pages.more.bot.\(page).\(account.id)" }

    static func read(_ page: String, context: MorePages.Context) -> String {
        let saved = UserDefaults.standard.string(forKey: key(page, context.account))
        if let saved, context.bots.contains(where: { $0.id == saved }) { return saved }
        return context.botChoices.first?.id ?? "default"
    }

    static func save(_ profile: String, page: String, context: MorePages.Context) {
        UserDefaults.standard.set(profile, forKey: key(page, context.account))
    }
}

/// A status dot and its word ("● Connected").
struct MoreStatusLine: View {
    var text: String
    var color: Color
    /// UX study #12: Bot Info's dot (a Caption 2 circle.fill, growing with the text but never past 14 pt; the Desktop
    /// Look's fixed Caption 2), so the dots match across pages.
    @ScaledMetric(relativeTo: .caption2) private var dotPoint: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(Theme.isDesktop ? Font.hq(.caption2) : Font.system(size: min(dotPoint, 14)))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
        }
    }
}

/// A page in a sheet that ⌘R refreshes (Usage & Limits, Model Prices): the shortcut otherwise stays off while a sheet is up.
@MainActor
protocol KeyRefreshing: AnyObject {
    var keyRefresh: (() -> Void)? { get }
}
