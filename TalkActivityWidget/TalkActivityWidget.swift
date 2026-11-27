// [talk-background] Draws the voice conversation's Live Activity (docs/spec/3x-talk-background.md §3): the Lock Screen
// banner and the Dynamic Island. The state comes from the app (TalkActivityKit/TalkActivityAttributes.swift).

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// [live] One extension draws both: Talk's own Live Activity (below) and a long reply's or a job run's
// (ReplyActivityWidget.swift, docs/spec/3x-presence.md §17, docs/spec/3x-jobs.md §12). Reusing this target — already
// embedded, already registered — means neither needs an App ID of its own.
@main
struct HermesHQActivitiesBundle: WidgetBundle {
    var body: some Widget {
        TalkActivityWidget()
        ReplyActivityWidget()
        // [tile-widgets] Home Screen widgets, in the same extension (no new App ID): a Tile, and Tasks.
        TileWidget()
        TasksWidget()   // [tasks-widget]
    }
}

struct TalkActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TalkActivityAttributes.self) { context in
            // On Liquid Glass with white words (LockScreenGlass.swift): left to the system, the words came out black on
            // the black card the Lock Screen drew (owner, build 404: "the live widget on the lock screen is just black");
            // then a dark card of its own (owner, 2026-10-31: "needs to be Liquid Glass not black").
            TalkBannerView(context: context)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(TalkPhaseStyle.link(context))
        } dynamicIsland: { context in
            let state = TalkPhaseStyle.shown(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    HStack(spacing: 6) {
                        TalkPhaseIcon(state: state, accent: context.attributes.accent)
                            .font(.headline)
                        Text(context.attributes.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, 4)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TalkClock(startedAt: context.attributes.startedAt, state: state)
                        .font(.headline)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, 4)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(state.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        TalkButtons(state: state)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
            } compactLeading: {
                TalkPhaseIcon(state: state, accent: context.attributes.accent)
                    .font(.system(size: 15, weight: .semibold))
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } compactTrailing: {
                // Adapts cleanly when another Live Activity competes for island width: 14 pt condensed -> 13 pt
                // compressed -> ultra-short stopped duration ("1h") before ever scaling down.
                TalkCompactTrailing(startedAt: context.attributes.startedAt, state: state)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } minimal: {
                TalkPhaseIcon(state: state, accent: context.attributes.accent)
                    .font(.system(size: 15, weight: .semibold))
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
            .widgetURL(TalkPhaseStyle.link(context))
            .keylineTint(TalkPhaseStyle.tint(state, accent: context.attributes.accent))
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct TalkBannerView: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<TalkActivityAttributes>

    var body: some View {
        switch activityFamily {
        case .small:
            TalkSmallBannerView(context: context)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .activityBackgroundTint(.clear)
                .environment(\.colorScheme, .dark)
        default:
            TalkLockScreenView(context: context)
                .lockScreenGlass()
        }
    }
}

private struct TalkSmallBannerView: View {
    let context: ActivityViewContext<TalkActivityAttributes>

    var body: some View {
        let state = TalkPhaseStyle.shown(context)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TalkPhaseIcon(state: state, accent: context.attributes.accent)
                    .font(.subheadline.weight(.semibold))
                Text(context.attributes.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                TalkClock(startedAt: context.attributes.startedAt, state: state)
                    .font(.subheadline.weight(.semibold))
                    .fontWidth(.condensed)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }
            Text(state.title)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// Symbol and colour per phase: green while it listens (a call in progress), the accent while it speaks, grey while
/// it waits, red when muted.
enum TalkPhaseStyle {
    static let ended = "ended"

    /// The chat's link: the state's once the chat has a stored id (a conversation begun in a brand-new chat), else the
    /// one it began with.
    static func link(_ context: ActivityViewContext<TalkActivityAttributes>) -> URL? {
        (context.state.link ?? context.attributes.link).flatMap(URL.init(string:))
    }

    /// What to draw. A running card the app stopped sending (it was killed and can't end it: TalkActivity's
    /// `staleAfter`) is drawn as over, not "Listening" with its clock running for hours.
    static func shown(_ context: ActivityViewContext<TalkActivityAttributes>) -> TalkActivityAttributes.ContentState {
        guard context.isStale, context.state.phase != ended else { return context.state }
        return TalkActivityAttributes.ContentState(phase: ended, title: "Ended", muted: false, link: context.state.link)
    }

    static func symbol(_ state: TalkActivityAttributes.ContentState) -> String {
        if state.muted { return "mic.slash.fill" }
        switch state.phase {
        case "speaking": return "speaker.wave.2.fill"
        case "thinking", "transcribing": return "ellipsis"
        case "reconnecting", "starting": return "arrow.triangle.2.circlepath"
        case ended: return "phone.down.fill"
        default: return "waveform"
        }
    }

    static func tint(_ state: TalkActivityAttributes.ContentState, accent: [Double]?) -> Color {
        if state.muted { return .red }
        switch state.phase {
        case "speaking": return LiveLook.accent(accent)
        case "thinking", "transcribing", "reconnecting", "starting", ended: return .secondary
        default: return .green
        }
    }
}

struct TalkPhaseIcon: View {
    let state: TalkActivityAttributes.ContentState
    let accent: [Double]?

    var body: some View {
        Image(systemName: TalkPhaseStyle.symbol(state))
            .foregroundStyle(TalkPhaseStyle.tint(state, accent: accent))
            .symbolEffect(.variableColor.iterative, isActive: state.phase == "listening" && !state.muted)
            .accessibilityHidden(true)
    }
}

/// [island-fit] Talk's compact trailing Dynamic Island clock: steps from 14 pt condensed to 13 pt compressed (and
/// ultra-short stopped durations like "1h") when competing Live Activities squeeze the island.
struct TalkCompactTrailing: View {
    let startedAt: Date
    let state: TalkActivityAttributes.ContentState

    var body: some View {
        if state.phase != TalkPhaseStyle.ended {
            CompactLiveTimer(startedAt: startedAt, reach: LiveTimerSpan.talkReach)
        } else if let endedAt = state.endedAt, endedAt > startedAt {
            let seconds = endedAt.timeIntervalSince(startedAt)
            ViewThatFits(in: .horizontal) {
                Text(LiveTimerSpan.clock(seconds))
                    .font(.system(size: 14, weight: .semibold))
                    .fontWidth(.condensed)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(LiveTimerSpan.clock(seconds))
                    .font(.system(size: 13, weight: .semibold))
                    .fontWidth(.compressed)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(LiveActivityContent.tookTiny(seconds))
                    .font(.system(size: 13, weight: .semibold))
                    .fontWidth(.compressed)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(LiveLook.squeeze)
            }
        }
    }
}

/// The conversation's running time, kept by the system (no update per second). Stopped at the end once it is over
/// (it read 0:00 before); hidden on a card drawn as over without one (gone stale).
struct TalkClock: View {
    let startedAt: Date
    let state: TalkActivityAttributes.ContentState
    var alignment: TextAlignment = .trailing

    var body: some View {
        if state.phase != TalkPhaseStyle.ended {
            // As wide as its digits (LiveTimer, ReplyActivityWidget.swift): a timer left to itself takes all the room
            // it is offered — wider than the Lock Screen once, and the whole top of the screen in the island.
            LiveTimer(startedAt: startedAt, alignment: alignment == .leading ? .leading : .trailing, reach: LiveTimerSpan.talkReach)
        } else if let endedAt = state.endedAt, endedAt > startedAt {
            // Stopped, so plain digits: a paused timer too takes all the room it is offered.
            Text(LiveTimerSpan.clock(endedAt.timeIntervalSince(startedAt)))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(LiveLook.squeeze)
        }
    }
}

struct TalkButtons: View {
    let state: TalkActivityAttributes.ContentState

    var body: some View {
        if state.phase != TalkPhaseStyle.ended {
            HStack(spacing: 8) {
                Button(intent: TalkMuteIntent()) {
                    Image(systemName: state.muted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 22, height: 22)
                }
                .tint(state.muted ? .red : .gray)
                .accessibilityLabel(state.muted ? "Unmute" : "Mute")
                Button(intent: TalkEndIntent()) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .tint(.red)
                .accessibilityLabel("End Conversation")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
        }
    }
}

struct TalkLockScreenView: View {
    let context: ActivityViewContext<TalkActivityAttributes>

    var body: some View {
        let state = TalkPhaseStyle.shown(context)
        let ended = state.phase == TalkPhaseStyle.ended
        HStack(alignment: ended ? .top : .center, spacing: 12) {
            TalkPhaseIcon(state: state, accent: context.attributes.accent)
                .font(.title2)
                .frame(width: 34, height: 34)
            if ended {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(context.attributes.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if state.endedAt != nil {
                            TalkClock(startedAt: context.attributes.startedAt, state: state, alignment: .trailing)
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.85))
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(2)
                        }
                    }
                    Text(state.title)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        Text(state.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .allowsTightening(true)
                            .truncationMode(.tail)
                        Text("·")
                        // Leading, or the digits sit at the far end of the timer's (widest-value) box, away from the dot.
                        TalkClock(startedAt: context.attributes.startedAt, state: state, alignment: .leading)
                            .fontWidth(.condensed)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 4)
                TalkButtons(state: state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        // The card is dark in both modes: every system colour (the waiting grey, the buttons) reads for dark.
        .environment(\.colorScheme, .dark)
    }
}
