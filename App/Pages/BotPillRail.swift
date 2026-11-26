// [bot-pills] Owner 2026-11-05: the bot pills at the top of Sessions: All, then each bot as a slim pill with its small
// face (`SessionPill`). Tasks had the same rail under its bar until 2026-11-12, when its views (Today, Upcoming, Inbox,
// your lists) took that row ([tasks-first], `TaskViewsHeader`) and its bots moved into the bar's Filter. Tiles was
// tried and dropped (owner: its own pages sort it better).

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
    /// [project-pills] VoiceOver's name for the row: "Projects" when its pills are projects.
    var label = "Bots"
    /// [projects-switch] Drawn before All (Sessions' Bots | Projects switch).
    var leading: AnyView? = nil
    /// [projects-switch] No All when it would stand alone beside the switch (one bot, nothing New or Working).
    var showsAll = true
    /// [pill-reorder] Sessions' project rail: its scroll, kept and set by a dragged pill (`ProjectPillRun`).
    var scroll: PillRailScroll? = nil
    var onPick: (String?) -> Void
    var onPickAll: () -> Void
    @ViewBuilder var extra: () -> Extra
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allId: String { "\(identifier).all" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    // [switch-scrolls] Owner 2026-11-17 (a screenshot, the switch ringed): "I want for this to scroll with
                    // everything else in this row". The Bots | Projects switch is the row's first item and scrolls with
                    // the pills (1053 to 1062 held it still at the row's start while they slid under it).
                    if let leading { leading }
                    if showsAll {
                        SessionPill(caption: "All", name: "All Bots", picked: allPicked, identifier: allId) {
                            onPickAll()
                        } face: {
                            EmptyView()
                        }
                        .id(allId)
                    }
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
            .modifier(PillRailScrolls(scroll: scroll))
            // [rail-scroller] Owner 2026-11-18 (Mac screenshot): `.hidden` still shows the scroller with a mouse
            // attached, a grey bar over the pills. `.never` hides it there too; a trackpad swipe still scrolls.
            .scrollIndicators(.never)
            .hqScrollEdgeFade(width: 20, preservesGlass: true)
            .onAppear { show(leading == nil ? picked : nil, proxy) }   // [project-page-return] Sessions: from the switch
            .onChange(of: picked) { _, picked in
                if reduceMotion {
                    show(picked, proxy)
                } else {
                    withAnimation(.easeInOut(duration: HQMotion.pane)) { show(picked, proxy) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("\(identifier)s")
    }

    /// The picked pill in view; nothing picked, the row's start.
    /// [project-page-return] Owner 2026-11-17 ("How easy is it to go back?"): Sessions' rail starts with the Bots |
    /// Projects switch, and centring the picked pill pushed the switch off the screen (a project's page opened from the
    /// Bots side had it 500 pt off). There the row first shows from its start, switch in view (a project's page names its
    /// project, a bot's list its bot), and a pick scrolls only as far as the pill needs (a pill half under the edge comes
    /// whole). Tasks' rail still centres.
    private func show(_ picked: String?, _ proxy: ScrollViewProxy) {
        if let picked { proxy.scrollTo(picked, anchor: leading == nil ? .center : nil) }
        else { proxy.scrollTo(allId, anchor: .center) }
    }
}
