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
            LiveBannerView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .widgetURL(context.attributes.link.flatMap(URL.init(string:)))
        } dynamicIsland: { context in
            let attributes = context.attributes, state = context.state
            let card = LiveCard(attributes, state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: LiveLook.symbol(attributes.subject.kind, state.phase))
                            .font(.headline)
                            .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
                        Text(attributes.botName)
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
                    LiveElapsed(state: state, stale: context.isStale, short: true)
                        .font(.headline)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, 4)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveExpandedBottomView(attributes: attributes, state: state, card: card)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
            } compactLeading: {
                Image(systemName: LiveLook.symbol(attributes.subject.kind, state.phase))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } compactTrailing: {
                // Adapts cleanly when another Live Activity competes for island width: full 14 pt condensed when room
                // allows, 13 pt compressed when squeezed, and ultra-short finished labels ("12h") before ever scaling.
                LiveCompactTrailing(state: state, stale: context.isStale)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } minimal: {
                Image(systemName: LiveLook.symbol(attributes.subject.kind, state.phase))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
            .widgetURL(attributes.link.flatMap(URL.init(string:)))
            .keylineTint(LiveLook.tint(state.phase, accent: attributes.accent))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Switches between the Lock Screen / Notification Center banner (`.medium`) and the compact Apple Watch Smart Stack
/// / CarPlay card (`.small`).
private struct LiveBannerView: View {
    @Environment(\.activityFamily) private var activityFamily
    let attributes: HQLiveAttributes
    let state: LiveActivityContent
    let stale: Bool

    var body: some View {
        switch activityFamily {
        case .small:
            LiveSmallBannerView(attributes: attributes, state: state, stale: stale)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .activityBackgroundTint(.clear)
                .environment(\.colorScheme, .dark)
        default:
            LiveLockScreenView(attributes: attributes, state: state, stale: stale)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lockScreenGlass()
        }
    }
}

/// Compact 2-line banner for Apple Watch Smart Stack and CarPlay (`.small` activity family).
private struct LiveSmallBannerView: View {
    let attributes: HQLiveAttributes
    let state: LiveActivityContent
    let stale: Bool

    var body: some View {
        let card = LiveCard(attributes, state, stale: stale)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: LiveLook.symbol(attributes.subject.kind, state.phase))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
                Text(attributes.botName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                LiveElapsed(state: state, stale: stale, short: true)
                    .font(.subheadline.weight(.semibold))
                    .fontWidth(.condensed)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }
            Text(card.line)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .combine)
    }
}

/// Full-width bottom area of the expanded Dynamic Island: side-chat title (if any), step count, running step / job
/// status (up to 2 lines so nothing is clipped), and the most recent finished step.
private struct LiveExpandedBottomView: View {
    let attributes: HQLiveAttributes
    let state: LiveActivityContent
    let card: LiveCard

    private var sideChatTitle: String? {
        guard attributes.subject.kind == .turn, let detail = attributes.detail, !detail.isEmpty else { return nil }
        return detail
    }

    private var stepCount: String? {
        guard !state.isOver, card.trail.steps > 0 else { return nil }
        return LiveStepTrail.count(card.trail.steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let chat = sideChatTitle {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let stepCount {
                        Spacer(minLength: 6)
                        Text(stepCount)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
            }
            if sideChatTitle == nil, card.earlier.isEmpty, let stepCount {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.line)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(stepCount)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                }
            } else {
                Text(card.line)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let earlier = card.earlier.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    LiveEarlierStep(words: earlier)
                    if sideChatTitle == nil, let stepCount {
                        Spacer(minLength: 6)
                        Text(stepCount)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Lock Screen banner: the bot's name and how long, a side chat's own title on its own line so long names never
/// crush the timer or get chopped off, what it is doing now (a turn's running step, or a job's title), and for a turn
/// the steps before it.
struct LiveLockScreenView: View {
    let attributes: HQLiveAttributes
    let state: LiveActivityContent
    let stale: Bool

    private var sideChatTitle: String? {
        guard attributes.subject.kind == .turn, let detail = attributes.detail, !detail.isEmpty else { return nil }
        return detail
    }

    var body: some View {
        let card = LiveCard(attributes, state, stale: stale)
        // Side chats show their chat title on its own full-width row, so show 1 earlier step there to stay well inside
        // the 160 pt Lock Screen Live Activity ceiling across all Dynamic Type sizes.
        let shownEarlier = sideChatTitle == nil ? card.earlier : Array(card.earlier.prefix(1))
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: LiveLook.symbol(attributes.subject.kind, state.phase))
                .font(.title2)
                .foregroundStyle(LiveLook.tint(state.phase, accent: attributes.accent))
                .frame(width: 30, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(attributes.botName)
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
                    Spacer(minLength: 4)
                    // No fixed width box: LiveTimer sizes intrinsically to its widest digits and scales cleanly with
                    // Dynamic Type; layoutPriority(2) keeps both running timers and finished durations ("12 h 34 min")
                    // whole without ever being crushed by the title.
                    LiveElapsed(state: state, stale: stale)
                        .font(.headline)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                }
                if let chat = sideChatTitle {
                    Text(chat)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                let idle = !state.isOver && attributes.subject.kind == .turn && card.trail.step == nil && card.trail.steps == 0
                Text(card.line)
                    .font(.subheadline.weight(idle ? .regular : .medium))
                    .foregroundStyle(idle ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(shownEarlier.enumerated()), id: \.offset) { _, words in
                    LiveEarlierStep(words: words)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .combine)
    }
}

/// A step that already ran: a small tick and its words, quieter than the running one.
struct LiveEarlierStep: View {
    let words: String

    var body: some View {
        Label {
            Text(LiveStepTrail.finished(words))
                .lineLimit(1)
                .truncationMode(.tail)
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
    /// The Dynamic Island's compact/expanded/small views: a finished one's time in its shortest words ("16m", "1h 5m").
    var short = false

    var body: some View {
        if let ended = state.endedAt {
            let seconds = ended.timeIntervalSince(state.startedAt)
            Text(short ? LiveActivityContent.tookShort(seconds) : LiveActivityContent.took(seconds))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(LiveLook.squeeze)
        } else if stale {
            Image(systemName: "clock.badge.questionmark")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not heard from lately")
        } else {
            LiveTimer(startedAt: state.startedAt, alignment: .trailing)
        }
    }
}

/// [island-fit] Compact trailing view for the Dynamic Island that adapts cleanly when another Live Activity competes
/// for space: prefers full-size 14 pt condensed digits, steps down to 13 pt compressed (still full height and bold)
/// when squeezed, drops trailing minutes on finished durations ("12h" instead of "12h 34m"), and only scales down as a
/// last resort so digits never clip to "…".
struct LiveCompactTrailing: View {
    let state: LiveActivityContent
    var stale = false

    var body: some View {
        if let ended = state.endedAt {
            let seconds = ended.timeIntervalSince(state.startedAt)
            ViewThatFits(in: .horizontal) {
                Text(LiveActivityContent.tookShort(seconds))
                    .font(.system(size: 14, weight: .semibold))
                    .fontWidth(.condensed)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(LiveActivityContent.tookShort(seconds))
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
            .foregroundStyle(.primary)
        } else if stale {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not heard from lately")
        } else {
            CompactLiveTimer(startedAt: state.startedAt, reach: LiveTimerSpan.reach)
                .foregroundStyle(.primary)
        }
    }
}

/// Running timer tuned for Dynamic Island `compactTrailing`: steps from 14 pt condensed to 13 pt compressed when
/// competing activities squeeze the slot, keeping text bold and full-height before falling back to scale-to-fit.
struct CompactLiveTimer: View {
    let startedAt: Date
    var reach: TimeInterval = LiveTimerSpan.reach

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LiveTimer(startedAt: startedAt, alignment: .trailing, reach: reach, squeeze: 1.0)
                .font(.system(size: 14, weight: .semibold))
                .fontWidth(.condensed)
            LiveTimer(startedAt: startedAt, alignment: .trailing, reach: reach, squeeze: 1.0)
                .font(.system(size: 13, weight: .semibold))
                .fontWidth(.compressed)
            LiveTimer(startedAt: startedAt, alignment: .trailing, reach: reach, squeeze: LiveLook.squeeze)
                .font(.system(size: 13, weight: .semibold))
                .fontWidth(.compressed)
        }
    }
}

/// [island-fit] A running timer that is exactly as wide as its digits. Its range ends at the next digit
/// (LiveTimerSpan), and since a live timer still takes every point it is offered — which stretched the Dynamic Island
/// across the clock and the status icons — its size comes from plain hidden digits ("00:00") it is laid over. Offered
/// less than that, both draw smaller, never cut.
struct LiveTimer: View {
    let startedAt: Date
    var alignment: Alignment = .trailing
    var reach: TimeInterval = LiveTimerSpan.reach
    var squeeze: CGFloat = LiveLook.squeeze

    var body: some View {
        let now = Date()
        Text(LiveTimerSpan.widest(startedAt: startedAt, now: now, reach: reach))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(squeeze)
            .hidden()
            .overlay(alignment: alignment) {
                Text(timerInterval: startedAt...LiveTimerSpan.end(startedAt: startedAt, now: now, reach: reach), countsDown: false)
                    .monospacedDigit()
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(squeeze)
            }
    }
}

enum LiveLook {
    /// [island-fit] Fallback floor before text would truncate: condensed compact digits normally fit at 85–100%, and
    /// only extreme durations in a tightly squeezed slot scale further down rather than clipping.
    static let squeeze: CGFloat = 0.55

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
