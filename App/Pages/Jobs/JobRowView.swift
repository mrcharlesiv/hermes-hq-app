// A job row (docs/spec/1x-pages.md §3.4): the human title (Callout, 2 lines; 4 at accessibility sizes), then one
// Footnote line — red "Last run failed · " when the last run failed, "Running · " while a run is out, orange
// "Overdue · " when a run is late, "Paused · " for a paused job — and the schedule in words.
// [jobs-edge] Owner 2026-11-10 (design pick 1): when it runs next stands at the trailing edge of the title's line, where
// a bot row has its time (`JobWords.rowEdge`), orange with how late an overdue run is and tinted with how long a running
// one has been out. Every row is two lines; the failed row no longer wraps to a third for its next run. At the
// accessibility sizes the edge follows the schedule on the second line instead, so the title keeps the row's width.
// 20 pt in, 12 pt top and bottom (D-P10). [jobsminimal] No ⋯ or divider (owner, 2026-10-27, as Bots and Sessions): a
// long press holds the row's menu (Run Now, Pause/Resume, Edit, Delete Job), a swipe reaches Pause/Resume, Run and
// Delete. Paused rows are not dimmed (55 % opacity fell below 4.5:1).
// [jobfaces] The owning bot's face leads the row, small (22 pt, centred on the title's first line), so whose job it is
// reads at a glance; the words keep their sizes (owner, 2026-11-01).

import SwiftUI

struct JobRowModel: Hashable {
    var key: String
    var title: String
    var subtitle: String
    var failed: Bool
    var running: Bool
    var paused: Bool
    var overdue = false
    /// [jobs-edge] When it runs next (or how late, or how long it has run), at the row's trailing edge.
    var edge: JobWords.RowEdge?
    /// [jobfaces] The bot that owns the job, and its head as the bot list has it (nil before the bots load).
    var owner = ""
    var head: JSONValue?

    var lead: JobWords.RowLead { JobWords.rowLead(running: running, failed: failed, overdue: overdue, paused: paused) }
}

struct JobRowView: View {
    var row: JobRowModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var textFaceSize: CGFloat = 22
    /// [ui-sizing] × UI Scale too: a ScaledMetric follows only the text size, and at 150 % the text grew around it.
    private var faceSize: CGFloat { HQFont.scaled(textFaceSize) }
    private var large: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            face
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.title)
                        .font(Font.hq(.callout))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(large ? 4 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !large, let edge = row.edge {
                        Text(edge.text)
                            .font(Font.hq(.footnote))
                            .monospacedDigit()
                            .foregroundStyle(edgeColor(edge))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                subtitle
                    .font(Font.hq(.footnote))
                    .lineLimit(large ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Theme.isDesktop ? 12 : 9)   // [compact] iOS look: 3 pt less a side (owner 2026-10-17)
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .frame(minHeight: Theme.isDesktop ? 56 : 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(accessibilitySubtitle)")
        .accessibilityAddTraits(.isButton)
    }

    /// The owner's face, its middle on the middle of the title's first line (capped at 32 pt at the largest sizes).
    @ViewBuilder private var face: some View {
        if !row.owner.isEmpty {
            let size = min(32, faceSize).rounded()
            HeadImage(raw: row.head, profile: row.owner, size: size)
                .frame(width: size, height: size)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.callout).capHeight / 2 }
                .accessibilityHidden(true)
        }
    }

    private var subtitle: Text {
        let leadWords = row.lead.rawValue
        let lead: Text
        switch row.lead {
        case .running: lead = Text(leadWords).foregroundStyle(Color.hqTintText)
        case .failed: lead = Text(leadWords).foregroundStyle(Color.hqRed)
        case .overdue: lead = Text(leadWords).foregroundStyle(Color.hqOrange)
        case .paused: lead = Text(leadWords).foregroundStyle(Color.hqLabel2).fontWeight(.semibold)
        case .none: lead = Text("")
        }
        let words = Text("\(lead)\(Text(row.subtitle).foregroundStyle(Color.hqLabel2))")
        guard large, let edge = row.edge else { return words }
        return Text("\(words)\(Text("\u{00A0}· ").foregroundStyle(Color.hqLabel2))\(Text(edge.text).foregroundStyle(edgeColor(edge)))")
    }

    private func edgeColor(_ edge: JobWords.RowEdge) -> Color {
        switch edge.tone {
        case .plain: Color.hqLabel2
        case .late: Color.hqOrange
        case .running: Color.hqTintText
        }
    }

    private var accessibilitySubtitle: String {
        row.lead.rawValue + row.subtitle + (row.edge.map { ", " + $0.spoken } ?? "")
    }
}

/// A 44 pt ⋯ that shows a UIKit menu (built when tapped, so it reflects the job's current state).
struct UIMenuButton: UIViewRepresentable {
    var menu: () -> UIMenu
    var label: String

    func makeUIView(context: Context) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis")
        config.baseForegroundColor = HQPalette.label2
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        Self.sizeGlyph(button)
        button.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (button: UIButton, _) in Self.sizeGlyph(button) }
        return button
    }

    /// 20 pt at the default text size, growing with the text up to 28: the same ⋯ as every other row's
    /// (`RowMoreButton`, the Bots and Sessions rows), where a fixed 20 stayed small beside Extra Large words.
    private static func sizeGlyph(_ button: UIButton) {
        let size = HQFont.symbolSize(20, cap: 28, category: button.traitCollection.preferredContentSizeCategory)
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.accessibilityLabel = label
        let build = menu
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in completion(build().children) }])
    }
}

/// A section header: Subheadline semibold label-2 with a count; Needs Attention leads with a red triangle, Running
/// with a small spinner; Completed (folded) has a trailing Hide when open.
struct JobSectionHeaderView: View {
    var section: JobWords.Section
    var count: Int
    var open: Bool
    var toggle: (() -> Void)?
    /// [soft-cards] The section stands on a soft card: the name starts where the rows' pictures do, and as far under
    /// the card's top as the last row's words stand over its foot.
    var onCard = false

    var body: some View {
        HStack(spacing: 6) {
            switch section {
            case .needsAttention:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hqRed).font(Font.hq(.subheadline))
            case .running:
                ProgressView().controlSize(.mini)
            default:
                EmptyView()
            }
            JobsHeaderWords(title: section.rawValue, count: count)
            Spacer(minLength: 8)
            if section == .completed, open, let toggle {
                // A 44 pt target inside the header's own padding (UX study #169), so the header keeps its height.
                Button(action: toggle) {
                    Text("Hide").padding(.top, 18).padding(.bottom, 6).contentShape(Rectangle())
                }
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqTint)
                    .padding(.top, -18).padding(.bottom, -6)
            }
        }
        .padding(.horizontal, onCard ? 20 + BackdropCards.side : 20)
        .padding(.top, onCard ? 12 + BackdropCards.grown(9) : 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Show N Completed ⌄" (tint), the folded Completed section's only row.
struct ShowCompletedRowView: View {
    var count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text("Show \(count) Completed").font(Font.hq(.callout))
            Image(systemName: "chevron.down").font(Font.hq(.footnote).weight(.semibold))
            Spacer()
        }
        .foregroundStyle(Color.hqTint)
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Show \(count) Completed")
        .accessibilityAddTraits(.isButton)
    }
}

/// The scope menu as a bar button beside the search magnifier ("All Bots ⌄"), only with two bots or more. Kept out of
/// the title's row so every page's large title sits where Bots' does (owner 2026-10-10: the header sat too low; a
/// subtitle row shrinks and lifts the title, a third header style).
@MainActor
final class ScopeBarItem {
    let item: UIBarButtonItem
    private var signature: String?
    /// [desktoplook] In the look the item has no capsule, so its words alone read as the page's title (UX study #123):
    /// there it is drawn as the desktop's quiet control, the words and a chevron in the secondary colour.
    private let lookButton = UIButton(configuration: .plain())
    private var themeWatch: NSObjectProtocol?
    /// A page pushed from More (Artifacts with Kanban in tab 3): the scope as a glyph, so the bar's trailing group is
    /// narrow enough for the small title to centre beside Back, as on the other pushed More pages (UX study #88).
    var compact = false

    init() {
        item = UIBarButtonItem(title: "All Bots", menu: nil)
        item.accessibilityIdentifier = "pages.scope"
        lookButton.showsMenuAsPrimaryAction = true
        lookButton.accessibilityIdentifier = "pages.scope"
        themeWatch = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLook() }
        }
    }

    isolated deinit {
        if let themeWatch { NotificationCenter.default.removeObserver(themeWatch) }
    }

    /// The look's control (a custom view) or the plain bar button (none).
    private func applyLook() {
        // [mac] Stress test 2026-10-28: the Mac draws the words-and-chevron button in both looks ("All Bots" had its
        // chevron only in the Desktop Look).
        guard Theme.isDesktop || DeviceWord.isMac else {
            if item.customView != nil { item.customView = nil }
            #if targetEnvironment(macCatalyst)
            // [mac] The bar button's own title carries no UI Scale: "All Bots" came out smaller than the page under it.
            for state in [UIControl.State.normal, .highlighted] {
                item.setTitleTextAttributes([.font: HQFont.system(ofSize: 15, weight: .medium)], for: state)
            }
            #endif
            return
        }
        var config = UIButton.Configuration.plain()
        // [mac] Stress test 2026-10-28 round 6: in the iOS look the bar's + and magnifier are the label colour, and
        // "All Bots" beside them was grey. On the Mac in the iOS look it takes their colour; the Desktop Look keeps
        // its quiet secondary control.
        // [mac] Stress test 2026-10-28 round 7: in the Desktop Look the Mac draws the bar's + and magnifier in its own
        // toolbar grey (white at about 54 % in dark: (148,149,150) on the bar), not the look's label 2, so "All Bots"
        // (176,181,187) was brighter than the glyphs beside it. On the Mac it takes their grey.
        // [mac] Stress test 2026-10-28 round 9: measured again, the + and magnifier beside it peak at (176,181,187), the
        // look's label 2, and the round 7 grey drew "All Bots" at 148, darker than they are. The Desktop Look's words
        // are label 2 on the Mac too, and the chevron (which came out brighter, 214) takes the same ink.
        let ink: UIColor = !DeviceWord.isMac || Theme.isDesktop ? HQPalette.label2 : HQPalette.label
        if compact {
            config.image = item.image
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline)
        } else {
            config.attributedTitle = AttributedString(item.title ?? "", attributes: AttributeContainer([
                .font: HQFont.preferred(.subheadline), .foregroundColor: ink,
            ]))
            config.image = UIImage(systemName: "chevron.down")
            #if targetEnvironment(macCatalyst)
            // [mac] Stress test 2026-10-28 round 9: drawn in the words' ink. As a template the Mac drew it near white
            // (214) whatever the button's foreground and image colours said.
            config.image = config.image?.withTintColor(ink, renderingMode: .alwaysOriginal)
            #endif
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)
            config.imagePlacement = .trailing
            config.imagePadding = 4
        }
        config.baseForegroundColor = ink
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        lookButton.configuration = config
        lookButton.menu = item.menu
        lookButton.accessibilityLabel = item.accessibilityLabel
        lookButton.sizeToFit()
        if item.customView !== lookButton { item.customView = lookButton }
    }

    /// Puts the item left of the search magnifier (or takes it away). `extra` (New Job +) goes at the trailing edge, as
    /// Kanban's New Task does.
    /// [morepages] `search`: the page's own magnifier (`PageBarCapsule.searchItem`).
    /// [tasks] `menuExtra`: the page's other commands, under the bots in this one menu, so the bar keeps three buttons
    /// with Search in the middle as Sessions' [Filter] [Search] [New] (owner 2026-11-04: Tasks' magnifier sat second
    /// of four). With one bot there is no filter, so they keep a ⋯ of their own, left of Search.
    /// [bot-pills] `pills`: the bots are a pill rail under the bar (`BotPillHeader`), so the bar has no bot menu, as
    /// with one bot.
    func update(scope: PagesScope, bots: [Bot], on navigationItem: UINavigationItem, extra: [UIBarButtonItem] = [],
                search own: UIBarButtonItem? = nil, menuExtra: UIDeferredMenuElement? = nil, alone: UIBarButtonItem? = nil,
                pills: Bool = false, me: Bool = false) {
        let search = own ?? navigationItem.searchBarPlacementBarButtonItem
        guard !pills, let title = ScopeMenu.title(scope: scope, bots: bots, me: me) else {
            let items = extra + [search] + [alone].compactMap { $0 }
            if navigationItem.rightBarButtonItems ?? [] != items { navigationItem.rightBarButtonItems = items }
            return
        }
        // Rebuilt only when what it shows changes: a menu open under the finger is never replaced by a reload.
        let current = scope.effective(bots: bots)
        let signature = ([current] + PagesNames.scopeChoices(bots).map { "\($0.id)\u{1F}\($0.name)" }).joined(separator: "\u{1E}")
        if signature != self.signature {
            self.signature = signature
            if compact {
                // A filter glyph, filled while one bot is chosen; VoiceOver hears the scope.
                item.title = nil
                item.image = UIImage(systemName: current == PagesScope.all ? "line.3.horizontal.decrease"
                                                                          : "line.3.horizontal.decrease.circle.fill")
            } else {
                item.title = title
                item.image = nil
            }
            let menu = ScopeMenu.make(scope: scope, bots: bots, me: me) { _ in }
            item.menu = menuExtra.map { UIMenu(children: [UIMenu(options: [.displayInline, .singleSelection], children: menu.children),
                                                          UIMenu(options: .displayInline, children: [$0])]) } ?? menu
            item.accessibilityLabel = "Showing \(title). Change"
            applyLook()
        }
        if navigationItem.rightBarButtonItems?.contains(item) != true || navigationItem.rightBarButtonItems?.contains(search) != true {
            // [mac] Stress test 2026-10-28 #66: with the magnifier at the trailing edge (`DesktopBars.searchToEdge`),
            // Jobs' + sat between it and "All Bots", so All Bots stood one item further in on Jobs than on Artifacts.
            // On the Mac All Bots comes straight after the magnifier on both, and the page's own items after it.
            // [mac-audit G] Owner 2026-11-02 (Mac audit #19): one order on every list's bar, read left to right as
            // Bots and Sessions read: filter (All Bots), then New (+), then Search at the edge.
            navigationItem.rightBarButtonItems = DeviceWord.isMac ? [search] + extra + [item] : extra + [search, item]
        }
    }
}

/// The list's count at its end ("9 jobs", "3 of 9 jobs"), as Photos and Files say how many (lower case, as "5 profiles").
struct PageCountView: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Font.hq(.footnote))
            .monospacedDigit()
            .foregroundStyle(Color.hqLabel2)
            .hqPictureBacking(capsule: true)   // [backdrop-cards]
            .frame(maxWidth: .infinity)
            // [ui-sizing 2026-11-09] A quiet line close under the list, not a ~62 pt footer row (owner: no footer rows).
            .padding(.top, 8)
            .padding(.bottom, 16)
            .accessibilityIdentifier("pages.count")
    }
}

/// The scope menu: All Bots, then the bots (default first), single selection.
@MainActor
enum ScopeMenu {
    /// [bot-pills] `me`: Me after All Bots (Tasks: your own tasks), as the iPhone's Me pill.
    static func make(scope: PagesScope, bots: [Bot], me: Bool = false, changed: @escaping (String) -> Void) -> UIMenu {
        let current = scope.effective(bots: bots)
        var items: [UIMenuElement] = [UIAction(title: "All Bots", state: current == PagesScope.all ? .on : .off) { _ in
            PagesHaptics.selection(); scope.set(PagesScope.all); changed(PagesScope.all)
        }]
        if me {
            items.append(UIAction(title: "Me", image: UIImage(systemName: "person"), state: current == PagesScope.me ? .on : .off) { _ in
                PagesHaptics.selection(); scope.set(PagesScope.me); changed(PagesScope.me)
            })
        }
        let bots = PagesNames.scopeChoices(bots).map { bot in
            UIAction(title: bot.name, state: current == bot.id ? .on : .off) { _ in
                PagesHaptics.selection(); scope.set(bot.id); changed(bot.id)
            }
        }
        items.append(UIMenu(options: .displayInline, children: bots))
        return UIMenu(options: .singleSelection, children: items)
    }

    static func title(scope: PagesScope, bots: [Bot], me: Bool = false) -> String? {
        guard bots.count >= 2 else { return nil }
        let current = scope.effective(bots: bots)
        if me && current == PagesScope.me { return "Me" }
        return current == PagesScope.all ? "All Bots" : PagesNames.botName(current, bots: bots)
    }
}

/// A Jobs header's words: "Scheduled 4" (Subheadline semibold, the count regular). One Text, so at the large sizes the
/// count follows the last word instead of standing in a column of its own beside a hyphenated name; the count in
/// label-2, as readable text (UX study #167). [desktoplook2] In the look,
/// "SCHEDULED · 4" at the desktop's label size, as Bots' "WORK · 2" (UX study #196: a font set on the Text beat the
/// label's own, so the look drew large tracked capitals).
struct JobsHeaderWords: View {
    var title: String
    var count: Int

    var body: some View {
        if Theme.isDesktop {
            Text("\(title) · \(count)")
                .monospacedDigit()
                .hqDesktopLabel()
        } else {
            let number = Text("\(count)").font(Font.hq(.subheadline)).monospacedDigit()
            Text("\(Text(title).font(Font.hq(.subheadline).weight(.semibold))) \(number)")
                .foregroundStyle(Color.hqLabel2)
        }
    }
}

// MARK: - [jobs] Blueprints in the Jobs list (docs/spec/3x-jobs.md §6.6)

/// A section header that is only words and a count ("Blueprints 7"), drawn as the job sections' headers.
struct JobsPlainHeaderView: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            JobsHeaderWords(title: title, count: count)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A blueprint: its title, what it does on up to two lines, a chevron. Tapping opens New Job with it chosen.
struct BlueprintRowView: View {
    var blueprint: Blueprint

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(blueprint.title)
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel)
                    .multilineTextAlignment(.leading)
                if !blueprint.description.isEmpty {
                    Text(blueprint.description)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsChevron()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Starts a new job from this blueprint")
    }
}

/// "No Jobs" above the blueprints (a full-page empty state would cover them).
struct JobsEmptyNoteView: View {
    var text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .hqSymbolFont(40, cap: 56)
                .foregroundStyle(Color.hqLabel3)
                .accessibilityHidden(true)
            Text("No Jobs").font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqLabel)
            Text(text).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center)
        }
        .hqPictureBacking()   // [backdrop-cards]
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
    }
}
