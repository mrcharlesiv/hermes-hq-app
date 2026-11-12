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
