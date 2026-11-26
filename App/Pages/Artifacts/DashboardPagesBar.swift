// [dashboard] The Dashboard's pages as a row of names under its header (owner 2026-11-03: "pages within the dashboards
// page"): tap one to show it, hold one to Rename, Move or Delete it, ＋ for a new page. It scrolls sideways when the
// names outgrow the width. [header-menus] A ⋯ after the ＋ opens the shown page's hold menu (owner 2026-11-03, menu review
// "Actions you can only reach by long-press").
//
// [tiles-chips-same] Owner 2026-11-15: "The chips on the top of the Tile page aren't set up the same way the chips are on
// other pages." The names were UIKit buttons in the tile list's first cell: they scrolled away with the tiles, sat 20 pt
// in (the rails sit 16), right under the bar (the rails keep `DesktopRows.underBar`), and had no edge fade or 44 pt
// touch. They are now Tasks' band (`TaskViewsHeader`): a fixed row under the bar that the list starts beneath, drawn
// with the same `SessionPill`s in the same scrolling rail (a wrapping row on the Mac), ＋ drawn as Tasks' New List.

import SwiftUI
import UIKit

@MainActor @Observable
final class DashboardPagesModel {
    /// Empty: no row (one page, the Artifacts shelf, or a search).
    var pages: [DashboardPage] = []
    var current: String = DashboardPage.mainId
    /// How many tiles each page holds (for VoiceOver).
    var counts: [String: Int] = [:]
    /// The page whose name a held tile is over (nil: none).
    var highlighted: String?
    /// [Mac UI check 2026-11-13] A sheet is up over the page (UIKit has dimmed its tint), as Tasks'.
    var dimmed = false
    /// Each name's frame in the band, for a tile dropped on it.
    @ObservationIgnored var frames: [String: CGRect] = [:]
}

/// What the names offer (the page's hold menu and the ⋯).
struct DashboardPageActions {
    var select: (String) -> Void
    var add: () -> Void
    var rename: (DashboardPage) -> Void
    var move: (DashboardPage, Int) -> Void
    var delete: (DashboardPage) -> Void
    /// [tiles-v2] Optional SF Symbol icon, drag-to-reorder, and page-level batch update controls.
    var setSymbol: (DashboardPage, String?) -> Void = { _, _ in }
    var reorder: (String, String) -> Void = { _, _ in }
    var updateAll: () -> Void = {}
    var pauseAll: (Bool) -> Void = { _ in }
}

struct DashboardPagesBand: View {
    var model: DashboardPagesModel
    var actions: DashboardPageActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let space = "dashboard.pages.band"

    var body: some View {
        Group {
            if !model.pages.isEmpty { rail }
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: DesktopPillBand.color))   // as Tasks' band
        .coordinateSpace(.named(Self.space))
    }

    private static func identifier(_ page: DashboardPage) -> String {
        "dashboard.page.\(page.id == DashboardPage.mainId ? "main" : page.name)"
    }

    @ViewBuilder private var pills: some View {
        ForEach(model.pages) { page in
            let picked = model.current == page.id
            // Under a sheet the picked pill's tinted glass greys: drawn plain with a ring then, as Tasks' pills.
            let quiet = picked && model.dimmed && !Theme.isDesktop
            let count = model.counts[page.id] ?? 0
            let hasIcon = page.symbol.map { !$0.isEmpty } ?? false
            let pill = SessionPill(caption: page.name, name: page.name, picked: picked && !quiet,
                                   identifier: Self.identifier(page), hasFace: hasIcon) {
                actions.select(page.id)
            } face: {
                if let symbol = page.symbol, !symbol.isEmpty {
                    Image(systemName: UIImage(systemName: symbol) != nil ? symbol : "rectangle.3.group")
                        .font(Font.hq(Theme.isDesktop ? .caption : .footnote).weight(.semibold))
                        .foregroundStyle(picked && !quiet ? Color.hqTintText : Color.hqLabel2)
                }
            }
            .overlay {
                if quiet {
                    Capsule().strokeBorder(Color.hqLabel2, lineWidth: 1.5)
                        .frame(height: SessionPill<EmptyView>.height)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(quiet ? .isSelected : [])
            .accessibilityValue(count == 1 ? "1 tile" : "\(count) tiles")
            // A held tile over the name lifts it.
            .scaleEffect(model.highlighted == page.id ? 1.12 : 1)
            .animation(HQMotion.reduced ? nil : .easeOut(duration: 0.15), value: model.highlighted)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { model.frames[page.id] = $0 }
            .contextMenu { menu(for: page) }
            .id(page.id)
            if page.id != DashboardPage.mainId {
                pill
                    .draggable("hq-page:" + page.id)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, raw.hasPrefix("hq-page:") else { return false }
                        let source = String(raw.dropFirst("hq-page:".count))
                        guard source != page.id else { return false }
                        actions.reorder(source, page.id)
                        return true
                    }
            } else {
                pill
            }
        }
        // ＋, as Tasks' New List.
        SessionPill(caption: "", name: "New Page", picked: false, identifier: "dashboard.page.add", hasFace: true, lead: 10) {
            actions.add()
        } face: {
            Self.mark("plus")
        }
        // [header-menus] The shown page's hold menu, a tap away: drawn as the ＋, titled with the page's name.
        if let page = model.pages.first(where: { $0.id == model.current }) {
            Menu {
                Section(page.name) { menu(for: page) }
                Section("Tiles on This Page") {
                    Button { actions.updateAll() } label: { Label("Update All Now", systemImage: "arrow.clockwise") }
                    Button { actions.pauseAll(true) } label: { Label("Pause All Updates", systemImage: "pause.circle") }
                    Button { actions.pauseAll(false) } label: { Label("Resume All Updates", systemImage: "play.circle") }
                }
            } label: {
                MorePill()
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.plain)
            // The 44 pt touch outside the Menu: inside its label, the glass grew to the whole touch frame (a ⋯ 10 pt
            // taller than the ＋ beside it).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Actions for \(page.name)")
            .accessibilityIdentifier("dashboard.page.menu")
        }
    }

    /// ＋'s and ⋯'s mark, in the secondary label colour (Tasks' New List).
    static func mark(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(Font.hq(Theme.isDesktop ? .caption : .footnote).weight(.semibold))
            .foregroundStyle(Color.hqLabel2)
            .padding(.trailing, -8)
    }

    /// Rename, Choose Icon, Move Left/Right, Delete (Main can be renamed and given an icon, not moved or deleted).
    @ViewBuilder private func menu(for page: DashboardPage) -> some View {
        Button { actions.rename(page) } label: { Label("Rename…", systemImage: "pencil") }
            .accessibilityIdentifier("dashboard.page.rename")
        Menu {
            Button { actions.setSymbol(page, nil) } label: {
                Label("No Icon", systemImage: page.symbol == nil ? "checkmark" : "nosign")
            }
            ForEach(DashboardPage.symbolChoices, id: \.symbol) { choice in
                Button { actions.setSymbol(page, choice.symbol) } label: {
                    Label(choice.label, systemImage: choice.symbol)
                }
            }
        } label: {
            Label("Icon", systemImage: page.symbol ?? "sparkles")
        }
        .accessibilityIdentifier("dashboard.page.icon")
        if page.id != DashboardPage.mainId, let index = model.pages.firstIndex(of: page) {
            if index > 1 || index < model.pages.count - 1 {
                Section {
                    if index > 1 {
                        Button { actions.move(page, -1) } label: { Label("Move Left", systemImage: "arrow.left") }
                    }
                    if index < model.pages.count - 1 {
                        Button { actions.move(page, 1) } label: { Label("Move Right", systemImage: "arrow.right") }
                    }
                }
            }
            Section {
                Button(role: .destructive) { actions.delete(page) } label: { Label("Delete Page", systemImage: "trash") }
                    .accessibilityIdentifier("dashboard.page.delete")
            }
        }
    }

    @ViewBuilder private var rail: some View {
        if DeviceWord.isMac {
            // As Tasks' views on the Mac: every name in sight, wrapping to a second line in a narrow pane.
            PagesFlowLayout(spacing: 8, lineSpacing: 0) { pills }
                .padding(.horizontal, Theme.isDesktop ? DesktopRows.gutter : 16)
                .padding(.top, DesktopRows.underBar)
                .padding(.bottom, Theme.isDesktop ? 2 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hqPickGlassRow()
                .hqFlatPicks()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Pages")
                .accessibilityIdentifier("dashboard.pages")
        } else {
            scrollingRail
        }
    }

    private var scrollingRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) { pills }
                    .padding(.horizontal, Theme.isDesktop ? DesktopRows.gutter : 16)
                    .padding(.top, DesktopRows.underBar)
                    .padding(.bottom, Theme.isDesktop ? 2 : 4)
                    .hqPickGlassRow()
            }
            // [rail-scroller] Owner 2026-11-18 (Mac screenshot): `.hidden` still shows the scroller with a mouse
            // attached, a grey bar over the pills. `.never` hides it there too; a trackpad swipe still scrolls.
            .scrollIndicators(.never)
            .hqScrollEdgeFade(width: 20, preservesGlass: true)
            // Only as far as it takes to show the picked name whole (no anchor), as Tasks' rail.
            .onAppear { proxy.scrollTo(model.current) }
            .onChange(of: model.current) { _, current in
                if reduceMotion {
                    proxy.scrollTo(current)
                } else {
                    withAnimation(.easeInOut(duration: HQMotion.pane)) { proxy.scrollTo(current) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages")
        .accessibilityIdentifier("dashboard.pages")
    }
}

/// The ⋯ as a pill drawn as the ＋ (`SessionPill` with a mark and no caption) for a `Menu`'s label.
private struct MorePill: View {
    var body: some View {
        let height = SessionPill<EmptyView>.height
        HStack(spacing: 6) {
            DashboardPagesBand.mark("ellipsis")
            Text("").font(Font.hq(Theme.isDesktop ? .footnote : .subheadline).weight(.medium))
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(minHeight: height)
        .background {
            if Theme.isDesktop {
                RoundedRectangle(cornerRadius: DesktopRows.radius, style: .continuous).fill(Color.hqFill3)
            }
        }
        .hqPickGlass(false, in: Capsule(), prominent: true)
    }
}

/// The names as the page's fixed band under its bar, as Tasks' views (`TaskViewsHeader`): the list starts under it.
@MainActor
final class DashboardPagesHeader: NSObject, UIDropInteractionDelegate {
    let model = DashboardPagesModel()
    private let actions: DashboardPageActions
    private weak var controller: UIViewController?
    private var host: UIHostingController<DashboardPagesBand>?
    private var height: NSLayoutConstraint?
    private var laidOut = false
    /// [dashboard] A tile held over a name goes onto that page: whether the drag is a tile, and the drop.
    var acceptsDrop: (UIDropSession) -> Bool = { _ in false }
    var onDrop: (UIDropSession, String) -> Void = { _, _ in }

    var shows: Bool { !model.pages.isEmpty }

    init(actions: DashboardPageActions) {
        self.actions = actions
    }

    /// Under the bar of `controller`; `list` is the page's list (in its soft-edge host when it has one).
    func install(in controller: UIViewController, list: UIScrollView, backdrop: PageBackdrop?) {
        guard host == nil else { return }
        self.controller = controller
        let host = UIHostingController(rootView: DashboardPagesBand(model: model, actions: actions))
        host.safeAreaRegions = []                // it sits above the safe area it makes room in
        host.view.backgroundColor = DesktopPillBand.color
        backdrop?.clear(host.view)               // [backdrop] the picture's band is behind it then
        host.view.translatesAutoresizingMaskIntoConstraints = false
        controller.addChild(host)
        controller.view.addSubview(host.view)
        // [top-edge] The names are part of the top edge, as Sessions' and Tasks' pills: the hard band reaches under them.
        if let edgeHost = list.superview as? UIScrollView {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = edgeHost
            edge.edge = .top
            host.view.addInteraction(edge)
        }
        host.view.addInteraction(UIDropInteraction(delegate: self))
        let height = host.view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            height,
        ])
        host.didMove(toParent: controller)
        host.view.clipsToBounds = true
        let probe = TintDimProbe()
        probe.isUserInteractionEnabled = false
        probe.changed = { [weak self] dimmed in
            guard let self, self.model.dimmed != dimmed else { return }
            self.model.dimmed = dimmed
        }
        controller.view.addSubview(probe)
        self.host = host
        self.height = height
    }

    /// The names and the shown one (none: no row); the band is measured again only when what it draws changed.
    func update(pages: [DashboardPage], current: String, counts: [String: Int]) {
        guard host != nil else { return }
        var changed = false
        if model.pages != pages { model.pages = pages; changed = true }
        if model.current != current { model.current = current; changed = true }
        if model.counts != counts { model.counts = counts }
        if pages.isEmpty { model.frames = [:] }
        if changed { controller?.view.setNeedsLayout() }
    }

    /// The name a dragged tile is over, lit up (nil: none).
    func highlight(_ id: String?) {
        guard id != model.highlighted else { return }
        // A tick as a page's name lights under a held tile (once per name, not per move of the finger).
        if id != nil { Haptics.play(.selection) }
        model.highlighted = id
    }

    /// The page (not the shown one) whose name is under the drop.
    private func page(under session: UIDropSession) -> String? {
        guard let view = host?.view, shows else { return nil }
        let point = session.location(in: view)
        return model.frames.first { id, frame in id != model.current && frame.insetBy(dx: -4, dy: -8).contains(point) }?.key
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        shows && acceptsDrop(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        let id = page(under: session)
        highlight(id)
        return UIDropProposal(operation: id == nil ? .forbidden : .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { highlight(nil) }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { highlight(nil) }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let id = page(under: session)
        highlight(nil)
        if let id { onDrop(session, id) }
    }

    /// From the page's `viewDidLayoutSubviews`: the band's height, and the list's room under it.
    func layout() {
        guard let host, let height, let controller, controller.view.bounds.width > 0 else { return }
        let view = controller.view!
        let fitted = model.pages.isEmpty ? 0 : host.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        // To the pixel, not the point: a band a fraction taller than its content left a line of the list above it.
        let scale = max(view.window?.screen.scale ?? controller.traitCollection.displayScale, 1)
        let target = fitted.isFinite ? max(0, (fitted * scale).rounded(.up) / scale) : 0
        let band = DesktopPillBand.color
        if host.view.backgroundColor != band { host.view.backgroundColor = band }
        guard abs(controller.additionalSafeAreaInsets.top - target) > 0.5 else { return }
        let animated = view.window != nil && !HQMotion.reduced && laidOut
        laidOut = true
        let change = {
            height.constant = target
            controller.additionalSafeAreaInsets.top = target
        }
        if animated {
            UIView.animate(withDuration: HQMotion.fade) {   // motion-ok: `animated` above is false under Reduce Motion
                change()
                view.layoutIfNeeded()
            }
        } else {
            change()
        }
    }
}
