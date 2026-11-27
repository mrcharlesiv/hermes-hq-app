// [live-grouped] Draws the grouped Live Activity combining active bot replies, side chats, and jobs into a single
// Lock Screen card and Dynamic Island pill. Vended from the same WidgetBundle as TalkActivityWidget and
// ReplyActivityWidget (TalkActivityWidget.swift), requiring no new App ID or provisioning profile.
// Each row is an individual SwiftUI `Link` opening its exact chat or job directly.

import ActivityKit
import SwiftUI
import WidgetKit

struct GroupedActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HQGroupedLiveAttributes.self) { context in
            GroupedBannerView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .widgetURL(context.attributes.link.flatMap(URL.init(string:)))
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: GroupedLook.symbol(state))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                        .padding(.leading, 6)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.isStale && !state.isOver ? "Check app" : state.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(context.isStale && !state.isOver ? Color.secondary : GroupedLook.tint(state, accent: attributes.accent))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, 6)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    GroupedExpandedBottomView(state: state, accent: attributes.accent)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                        .padding(.bottom, 2)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
            } compactLeading: {
                Image(systemName: GroupedLook.symbol(state))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } compactTrailing: {
                GroupedCompactTrailing(state: state, stale: context.isStale, accent: attributes.accent)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } minimal: {
                Image(systemName: GroupedLook.symbol(state))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
            .widgetURL(attributes.link.flatMap(URL.init(string:)))
            .keylineTint(GroupedLook.tint(state, accent: attributes.accent))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Switches between the Lock Screen / Notification Center banner (`.medium`) and Apple Watch Smart Stack / CarPlay (`.small`).
private struct GroupedBannerView: View {
    @Environment(\.activityFamily) private var activityFamily
    let attributes: HQGroupedLiveAttributes
    let state: LiveGroupedContent
    let stale: Bool

    var body: some View {
        switch activityFamily {
        case .small:
            GroupedSmallBannerView(attributes: attributes, state: state, stale: stale)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .activityBackgroundTint(.clear)
                .environment(\.colorScheme, .dark)
        default:
            GroupedLockScreenView(attributes: attributes, state: state, stale: stale)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lockScreenGlass()
        }
    }
}

/// Compact 2-line banner for Apple Watch Smart Stack and CarPlay (`.small` activity family).
private struct GroupedSmallBannerView: View {
    let attributes: HQGroupedLiveAttributes
    let state: LiveGroupedContent
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: GroupedLook.symbol(state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                Text(attributes.appName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(stale && !state.isOver ? "Check app" : state.summary)
                    .font(.subheadline.weight(.semibold))
                    .fontWidth(.condensed)
                    .foregroundStyle(stale && !state.isOver ? Color.secondary : GroupedLook.tint(state, accent: attributes.accent))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }
            if let top = state.items.first {
                let extra = state.totalCount - 1
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(top.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(extra > 0 ? "+\(extra) more" : top.statusWord)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(extra > 0 ? Color.secondary : GroupedLook.statusColor(top.phase, accent: attributes.accent))
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .combine)
    }
}

/// Lock Screen grouped card: centered status header over up to 5 compact, individually tappable rows.
struct GroupedLockScreenView: View {
    let attributes: HQGroupedLiveAttributes
    let state: LiveGroupedContent
    let stale: Bool

    var body: some View {
        let shown = state.visible(limit: LiveGroupedContent.lockScreenLimit, reserveOverflowRow: true)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: GroupedLook.symbol(state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                    Text(attributes.appName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(stale && !state.isOver ? "Check app" : state.summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stale && !state.isOver ? .white.opacity(0.65) : .white.opacity(0.92))
                    .lineLimit(1)
            }
            .padding(.bottom, 1)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(shown.rows) { item in
                    GroupedRowView(item: item, accent: attributes.accent)
                }
                if shown.overflow > 0 {
                    Text("+\(shown.overflow) more")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// Expanded Dynamic Island bottom region: up to 4 tappable rows (or 3 rows + "+N more" when overflowing) so nothing clips.
private struct GroupedExpandedBottomView: View {
    let state: LiveGroupedContent
    let accent: [Double]?

    var body: some View {
        let shown = state.visible(limit: LiveGroupedContent.expandedLimit, reserveOverflowRow: true)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(shown.rows) { item in
                GroupedRowView(item: item, accent: accent)
            }
            if shown.overflow > 0 {
                Text("+\(shown.overflow) more")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One compact single-line row (`[Title]  [Bot / Step]  [Status]`), wrapped in a `Link` when it carries a deep link.
private struct GroupedRowView: View {
    let item: LiveGroupedItem
    let accent: [Double]?

    var body: some View {
        if let url = item.link.flatMap(URL.init(string:)) {
            Link(destination: url) { rowBody }
                .buttonStyle(.plain)
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 118, alignment: .trailing)
                    .layoutPriority(1)
            }
            Text(item.statusWord)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroupedLook.statusColor(item.phase, accent: accent))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 54, alignment: .trailing)
                .layoutPriority(2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// [island-fit] Compact trailing Dynamic Island view for grouped mode: shows "3 active" when solo, steps down to
/// "• 3" and "3" when competing Live Activities squeeze the island so it never clips to "3 ac…".
struct GroupedCompactTrailing: View {
    let state: LiveGroupedContent
    var stale = false
    var accent: [Double]? = nil

    var body: some View {
        if stale && !state.isOver {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not heard from lately")
        } else if state.activeCount > 0 {
            ViewThatFits(in: .horizontal) {
                Text(state.compactLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .fontWidth(.condensed)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(state.compactLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .fontWidth(.compressed)
                    .monospacedDigit()
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Circle()
                        .fill(LiveLook.accent(accent))
                        .frame(width: 5, height: 5)
                    Text("\(state.activeCount)")
                        .font(.system(size: 14, weight: .semibold))
                        .fontWidth(.condensed)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text("\(state.activeCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .fontWidth(.compressed)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(LiveLook.squeeze)
            }
            .foregroundStyle(.primary)
        } else {
            ViewThatFits(in: .horizontal) {
                Text(state.compactLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .fontWidth(.condensed)
                    .lineLimit(1)
                Text(state.compactLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .fontWidth(.compressed)
                    .lineLimit(1)
                    .minimumScaleFactor(LiveLook.squeeze)
            }
            .foregroundStyle(state.hasFailed ? .orange : .green)
        }
    }
}

enum GroupedLook {
    static func symbol(_ state: LiveGroupedContent) -> String {
        if state.activeCount > 0 {
            let active = state.items.filter { !$0.isOver }
            if !active.isEmpty && active.allSatisfy({ $0.subject.kind == .job }) {
                return "calendar.badge.clock"
            }
            return "ellipsis.bubble.fill"
        }
        return state.hasFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    static func tint(_ state: LiveGroupedContent, accent: [Double]?) -> Color {
        if state.activeCount > 0 { return LiveLook.accent(accent) }
        return state.hasFailed ? .orange : .green
    }

    static func statusColor(_ phase: LiveActivityContent.Phase, accent: [Double]?) -> Color {
        switch phase {
        case .working, .running: return LiveLook.accent(accent)
        case .done: return .green
        case .failed: return .orange
        }
    }
}
