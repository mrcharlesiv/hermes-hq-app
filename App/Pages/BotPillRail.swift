// [bot-pills] Owner 2026-11-05: the bot pills at the top of Sessions, the same on Tasks. One rail draws both: All,
// then each bot as a slim pill with its small face (`SessionPill`). On Tasks it is a fixed band under the bar, as
// Sessions' header is, and takes the place of the bar's "All Bots ⌄"; a Me pill after All shows your own tasks. The
// Mac keeps the pop-up (Sessions' bots are a pop-up there too, owner 2026-11-02 #20). Tiles was tried and dropped
// (owner: its own pages sort it better).

import SwiftUI
import UIKit

/// The pills in one row that scrolls sideways: All, then `extra` (Sessions' New and Working), then the bots. A tap on
/// the lit bot goes back to All. The picked pill is scrolled to the middle.
/// `identifier`: the pills are "<identifier>.all" and "<identifier>.<bot>", the rail "<identifier>s".
struct BotPillRail<Extra: View>: View {
    var bots: [SessionChipBot]
    var picked: String?
    var allPicked: Bool
    var identifier: String
    var onPick: (String?) -> Void
    var onPickAll: () -> Void
    @ViewBuilder var extra: () -> Extra
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allId: String { "\(identifier).all" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    SessionPill(caption: "All", name: "All Bots", picked: allPicked, identifier: allId) {
                        onPickAll()
                    } face: {
                        EmptyView()
                    }
                    .id(allId)
                    extra()
                    ForEach(bots) { bot in
                        // [photoheads] Reading `version` redraws the pill when a photo arrives or goes.
                        let _ = BotFaces.shared.version
                        SessionPill(caption: bot.name, name: bot.name, picked: picked == bot.id,
                                    identifier: "\(identifier).\(bot.id)", hasFace: true) {
                            // The lit pill goes back to every bot.
                            onPick(picked == bot.id ? nil : bot.id)
                        } face: {
                            HeadImage(head: bot.head, profile: bot.id, size: SessionPill<EmptyView>.faceSize,
                                      working: bot.isWorking, phase: HeadView.phase(for: bot.id))
                        }
                        .id(bot.id)
                    }
                }
                .padding(.horizontal, Theme.isDesktop ? DesktopRows.gutter : 16)
                // The pills' 44 pt touch frames hold 5 pt above and below them already.
                // [top-bar-gap] Owner 2026-11-09: in the Desktop Look the bar is a frosted band with an edge, and the
                // pills sat 8 pt under it ("the top bar is so close to the contents"). They get the room the Mac's
                // rail already has (`DesktopRows.underBar`).
                .padding(.top, DesktopRows.underBar)
                .padding(.bottom, Theme.isDesktop ? 2 : 4)
                .hqPickGlassRow()
            }
            .scrollIndicators(.hidden)
            .hqScrollEdgeFade(width: 20)
            .onAppear { proxy.scrollTo(picked ?? allId, anchor: .center) }
            .onChange(of: picked) { _, picked in
                if reduceMotion {
                    proxy.scrollTo(picked ?? allId, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(picked ?? allId, anchor: .center) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bots")
        .accessibilityIdentifier("\(identifier)s")
    }
}

@MainActor @Observable
final class BotPillsModel {
    /// The pills, in order (Hermes first); empty: no rail.
    var bots: [SessionChipBot] = []
    /// The picked bot (or `PagesScope.me`); nil: All.
    var picked: String?
    /// A Me pill after All (Tasks): your own tasks, the ones no bot helps with.
    var me = false
}

private struct BotPillsBand: View {
    var model: BotPillsModel
    var identifier: String
    var onPick: (String?) -> Void

    var body: some View {
        Group {
            if !model.bots.isEmpty {
                BotPillRail(bots: model.bots, picked: model.picked, allPicked: model.picked == nil, identifier: identifier,
                            onPick: onPick, onPickAll: { onPick(nil) }) {
                    if model.me { mePill }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.isDesktop ? Color.hqPage : Color.clear)
    }

    /// Me, then a rule before the bots (as Sessions' New and Working have). The lit pill goes back to All.
    @ViewBuilder private var mePill: some View {
        let picked = model.picked == PagesScope.me
        SessionPill(caption: "Me", name: "Your Own Tasks", picked: picked, identifier: "\(identifier).me",
                    hasFace: true, lead: 12) {
            onPick(picked ? nil : PagesScope.me)
        } face: {
            Image(systemName: "person.fill")
                .font(Theme.isDesktop ? Font.hq(.caption) : Font.hq(.footnote))
                .foregroundStyle(picked ? Color.hqOnTint : Color.hqLabel2)
        }
        .id(PagesScope.me)
        Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }
}

/// [bot-pills] The rail as a page's fixed band under its bar (Tasks), as Sessions' header: it never scrolls
/// with the list, the list starts under it (the page's safe area grows by its height), and in the iOS look it is clear
/// over the list's soft edge; the Desktop Look keeps a band in the page colour.
@MainActor
final class BotPillHeader {
    private let model = BotPillsModel()
    private let identifier: String
    private let onPick: (String?) -> Void
    private weak var controller: UIViewController?
    private var host: UIHostingController<BotPillsBand>?
    private var height: NSLayoutConstraint?
    private var laidOut = false

    /// iPhone and iPad. The Mac keeps the bar's "All Bots ⌄" pop-up, as its Sessions does.
    static var available: Bool { !DeviceWord.isMac }

    /// The rail shows (two bots or more, not on the Mac): the bar keeps no bot menu of its own then.
    var shows: Bool { !model.bots.isEmpty }

    /// `identifier`: "tasks.chip" names the pills "tasks.chip.all", "tasks.chip.<bot>" and the rail "tasks.chips".
    /// `me`: a Me pill after All (`PagesScope.me`).
    init(identifier: String, me: Bool = false, onPick: @escaping (String?) -> Void) {
        self.identifier = identifier
        self.onPick = onPick
        model.me = me
    }

    /// Under the bar of `controller`; `list` is the page's list (in its soft-edge host when it has one).
    func install(in controller: UIViewController, list: UIScrollView, backdrop: PageBackdrop?) {
        guard Self.available, host == nil else { return }
        self.controller = controller
        let host = UIHostingController(rootView: BotPillsBand(model: model, identifier: identifier) { [weak self] in
            self?.pick($0)
        })
        host.safeAreaRegions = []                // it sits above the safe area it makes room in
        host.view.backgroundColor = Theme.isDesktop ? HQPalette.page : .clear
        backdrop?.clear(host.view)               // [backdrop] the picture's band is behind it then
        host.view.translatesAutoresizingMaskIntoConstraints = false
        controller.addChild(host)
        controller.view.addSubview(host.view)
        // [top-edge] The pills are part of the top edge, as Sessions' chips: the hard band (Theme › Themes › Top Edge)
        // reaches under them.
        if let edgeHost = list.superview as? UIScrollView {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = edgeHost
            edge.edge = .top
            host.view.addInteraction(edge)
        }
        let height = host.view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            height,
        ])
        host.didMove(toParent: controller)
        host.view.clipsToBounds = true
        self.host = host
        self.height = height
    }

    /// The roster and the pick; the band is measured again only when what it draws changed.
    func update(bots: [Bot], picked: String) {
        guard host != nil else { return }
        let pills = SessionChipBot.chips(from: PagesNames.scopeChoices(bots))
        let lit = picked == PagesScope.all ? nil : picked
        var changed = false
        if model.bots != pills { model.bots = pills; changed = true }
        if model.picked != lit { model.picked = lit; changed = true }
        if changed { controller?.view.setNeedsLayout() }
    }

    private func pick(_ bot: String?) {
        PagesHaptics.selection()
        onPick(bot)
    }

    /// From the page's `viewDidLayoutSubviews`: the band's height, and the list's room under it.
    func layout() {
        guard let host, let height, let controller, controller.view.bounds.width > 0 else { return }
        let view = controller.view!
        let fitted = model.bots.isEmpty ? 0 : host.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        // To the pixel, not the point: a band a fraction taller than its content left a line of the list above it.
        let scale = max(view.window?.screen.scale ?? controller.traitCollection.displayScale, 1)
        let target = fitted.isFinite ? max(0, (fitted * scale).rounded(.up) / scale) : 0
        let band = Theme.isDesktop ? HQPalette.page : UIColor.clear
        if host.view.backgroundColor != band { host.view.backgroundColor = band }
        guard abs(controller.additionalSafeAreaInsets.top - target) > 0.5 else { return }
        let animated = view.window != nil && !HQMotion.reduced && laidOut
        laidOut = true
        let change = {
            height.constant = target
            controller.additionalSafeAreaInsets.top = target
        }
        if animated {
            UIView.animate(withDuration: 0.2) {   // motion-ok: `animated` above is false under Reduce Motion
                change()
                view.layoutIfNeeded()
            }
        } else {
            change()
        }
    }
}
