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
    }
}

struct TalkActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TalkActivityAttributes.self) { context in
            // On Liquid Glass with white words (LockScreenGlass.swift): left to the system, the words came out black on
            // the black card the Lock Screen drew (owner, build 404: "the live widget on the lock screen is just black");
            // then a dark card of its own (owner, 2026-10-31: "needs to be Liquid Glass not black").
            TalkLockScreenView(context: context)
                .lockScreenGlass()
                .activitySystemActionForegroundColor(.white)
                .widgetURL(TalkPhaseStyle.link(context))
        } dynamicIsland: { context in
            let state = TalkPhaseStyle.shown(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.name).font(.headline).lineLimit(1)
                    } icon: {
                        TalkPhaseIcon(state: state, accent: context.attributes.accent)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TalkClock(startedAt: context.attributes.startedAt, state: state)
                        .font(.headline)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Text(state.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        TalkButtons(state: state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                TalkPhaseIcon(state: state, accent: context.attributes.accent)
            } compactTrailing: {
                // Room for "0:00:00", as the reply card's island: 44 pt cut a talk past an hour to "1:00:…".
                TalkClock(startedAt: context.attributes.startedAt, state: state)
                    .frame(width: 64, alignment: .trailing)
            } minimal: {
                TalkPhaseIcon(state: state, accent: context.attributes.accent)
            }
            .widgetURL(TalkPhaseStyle.link(context))
            .keylineTint(TalkPhaseStyle.tint(state, accent: context.attributes.accent))
        }
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

/// The conversation's running time, kept by the system (no update per second). Stopped at the end once it is over
/// (it read 0:00 before); hidden on a card drawn as over without one (gone stale).
struct TalkClock: View {
    let startedAt: Date
    let state: TalkActivityAttributes.ContentState
    var alignment: TextAlignment = .trailing

    var body: some View {
        if state.phase != TalkPhaseStyle.ended {
            // A bounded range: a timer's text is as wide as its longest value, and one running to distantFuture was
            // wider than the Lock Screen.
            Text(timerInterval: startedAt...startedAt.addingTimeInterval(24 * 3600), countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(alignment)
        } else if let endedAt = state.endedAt, endedAt > startedAt {
            Text(timerInterval: startedAt...endedAt, pauseTime: endedAt, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(alignment)
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
        HStack(spacing: 12) {
            TalkPhaseIcon(state: state, accent: context.attributes.accent)
                .font(.title2)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 6) {
                    Text(state.title).lineLimit(1)
                    if state.phase != TalkPhaseStyle.ended || state.endedAt != nil {
                        Text("·")
                        // Leading, or the digits sit at the far end of the timer's (widest-value) box, away from the dot.
                        TalkClock(startedAt: context.attributes.startedAt, state: state, alignment: .leading)
                            .frame(maxWidth: 64, alignment: .leading)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 8)
            TalkButtons(state: state)
        }
        .padding(16)
        // The card is dark in both modes: every system colour (the waiting grey, the buttons) reads for dark.
        .environment(\.colorScheme, .dark)
    }
}
