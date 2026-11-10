// [live] What a long turn or a job run from Jobs looks like on the Lock Screen and in the Dynamic Island
// (docs/spec/3x-presence.md §17, docs/spec/3x-jobs.md §12). The app starts, updates and ends the activity
// (App/Live/LiveActivityCenter.swift); this only draws `HQLiveAttributes` (LiveKit). A running one's elapsed time is
// a system timer, so it moves on while the app is suspended. Tapping opens the app's own link (the chat, or the job).
// Vended from the same WidgetBundle as Talk's own activity (TalkActivityWidget.swift) — its own card, its own colours,
// unrelated to Talk's Mute/End buttons.
//
// [live-steps] A turn's card names its bot's steps (owner, 2026-10-31: "Right now it just shows working… it needs to show
// the live tool calls"): the running one ("Running npm test…"), the two before it, how many so far. The app's own
// updates carry them plainly; the add-on's pushes carry them sealed, opened here with this phone's push keys
// (Shared/LiveStepsSeal.swift, through the keychain group in HermesHQTalkActivity.entitlements).

import ActivityKit
import SwiftUI
import WidgetKit

struct ReplyActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HQLiveAttributes.self) { context in
            LiveLockScreenView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lockScreenGlass()
                .widgetURL(context.attributes.link.flatMap(URL.init(string:)))
        } dynamicIsland: { context in
            let attributes = context.attributes, state = context.state
            let card = LiveCard(attributes, state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(LiveLook.title(attributes), systemImage: LiveLook.symbol(attributes.subject.kind, state.phase))
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveElapsed(state: state, stale: context.isStale).font(.headline).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.line)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let earlier = card.earlier.first {
                            LiveEarlierStep(words: earlier)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: LiveLook.symbol(attributes.subject.kind, state.phase))
                    .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
            } compactTrailing: {
                // A slot "0:00:00" fits: at 52 pt a turn past an hour drew "1:00:…" (tester, 2026-11-06).
                LiveElapsed(state: state, stale: context.isStale, slot: 64)
            } minimal: {
                Image(systemName: LiveLook.symbol(attributes.subject.kind, state.phase))
                    .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
            }
            .widgetURL(attributes.link.flatMap(URL.init(string:)))
        }
    }
}

/// The Lock Screen banner: the bot's name and how long, what it is doing now (a turn's running step, or a job's title),
/// and for a turn the steps before it.
struct LiveLockScreenView: View {
    let attributes: HQLiveAttributes
    let state: LiveActivityContent
    let stale: Bool

    var body: some View {
        let card = LiveCard(attributes, state, stale: stale)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: LiveLook.symbol(attributes.subject.kind, state.phase))
                .font(.title2)
                .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // The name gives way first: a side chat's long title ("Orchestrator · Update herm…") pushed the
                    // timer off the card's edge (owner's iPad, 2026-11-05). Timer, then the step count, keep their size.
                    Text(LiveLook.title(attributes))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !state.isOver, card.trail.steps > 0 {
                        Text(LiveStepTrail.count(card.trail.steps))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 8)
                    // A running timer asks for unbounded width, so it lost every squeeze to the name; it gets a fixed
                    // slot that "0:00:00" fits (fixedSize on it left the card blank, as did a hidden placeholder).
                    LiveElapsed(state: state, stale: stale, slot: 64)
                        .font(.headline)
                }
                Text(card.line)
                    .font(.subheadline.weight(card.trail.step == nil ? .regular : .medium))
                    .foregroundStyle(card.trail.step == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    .lineLimit(stale && !state.isOver ? 2 : 1)   // one line while it names steps: the card doesn't jump
                ForEach(Array(card.earlier.enumerated()), id: \.offset) { _, words in
                    LiveEarlierStep(words: words)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A step that already ran: a small tick and its words, quieter than the running one.
struct LiveEarlierStep: View {
    let words: String

    var body: some View {
        Label {
            Text(LiveStepTrail.finished(words)).lineLimit(1)
        } icon: {
            Image(systemName: "checkmark").font(.caption2.weight(.semibold))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// What a card says, worked out once per draw: its trail (opened from a pushed seal when there is one), the main line,
/// the earlier steps.
struct LiveCard {
    let trail: LiveStepTrail
    let line: String
    let earlier: [String]

    init(_ attributes: HQLiveAttributes, _ state: LiveActivityContent, stale: Bool) {
        let trail = attributes.subject.kind == .turn ? LiveStepsSeal.trail(state, keys: PushSealKeys.all) : LiveStepTrail()
        self.trail = trail
        var line = LiveLook.line(attributes, state, trail)
        if stale && !state.isOver { line += " · Open to check" }
        self.line = line
        earlier = state.isOver ? trail.settled().recent : trail.recent
    }
}

/// A running one's live timer, a finished one's time taken. A running one gone stale (nothing heard for
/// `LiveActivityTiming.staleAfter`: its turn may well be over, its end lost on the way) stops counting: a clock with a
/// question mark beside "· Open to check" (owner, 2026-11-01: "the timer just keeps ticking up even though the turn has
/// ended").
struct LiveElapsed: View {
    let state: LiveActivityContent
    var stale = false
    /// A fixed width for the running timer, which otherwise takes all the room it's offered.
    var slot: CGFloat? = nil

    var body: some View {
        if let ended = state.endedAt {
            Text(LiveActivityContent.took(ended.timeIntervalSince(state.startedAt)))
                .monospacedDigit()
                .lineLimit(1)
        } else if stale {
            Image(systemName: "clock.badge.questionmark")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not heard from lately")
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .frame(width: slot, alignment: .trailing)
        }
    }
}

enum LiveLook {
    static func symbol(_ kind: LiveActivitySubject.Kind, _ phase: LiveActivityContent.Phase) -> String {
        switch phase {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .working, .running: return kind == .job ? "calendar.badge.clock" : "ellipsis.bubble.fill"
        }
    }

    static func tint(_ phase: LiveActivityContent.Phase, accent: [Double]?) -> Color {
        switch phase {
        case .done: return .green
        case .failed: return .orange
        case .working, .running: return Self.accent(accent)
        }
    }

    /// The app's accent the card was started with (its theme's tint); system blue for a card from before it was sent.
    static func accent(_ components: [Double]?) -> Color {
        guard let components, components.count == 3 else { return .accentColor }
        return Color(red: components[0], green: components[1], blue: components[2])
    }

    /// [live-chats] The card's name: the bot's, and for a side chat's turn its title too ("Otto · Day check").
    static func title(_ attributes: HQLiveAttributes) -> String {
        guard attributes.subject.kind == .turn, let chat = attributes.detail, !chat.isEmpty else { return attributes.botName }
        return attributes.botName + " · " + chat
    }

    /// A job: "Running · Morning brief", "Done · Morning brief", "Failed". A turn: its running step ("Running npm
    /// test…"), "Writing…" between its steps and the end (the app heard its reply start), "Working…" before any step;
    /// over: "Done · 7 steps", "Failed".
    static func line(_ attributes: HQLiveAttributes, _ state: LiveActivityContent, _ trail: LiveStepTrail) -> String {
        if attributes.subject.kind == .job, let detail = attributes.detail, !detail.isEmpty { return state.words + " · " + detail }
        if state.isOver { return trail.steps > 0 ? state.words + " · " + LiveStepTrail.count(trail.steps) : state.words }
        if let step = trail.step { return LiveStepTrail.running(step) }
        return trail.steps > 0 ? "Writing…" : state.words
    }
}
