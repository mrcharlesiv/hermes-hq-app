// [live-grouped] Draws the grouped Live Activity combining active bot replies, side chats, and jobs into a single
// Lock Screen card and Dynamic Island pill. Adapts automatically:
// - 1 item: renders the rich single-item view (bot name, step count, live timer, full 2-line step, earlier steps)
//   so a single active bot never shows a sparse table or duplicate app header.
// - 2+ items: renders a balanced multi-row card (`[icon] Hermes HQ` left, `3 active` right-aligned over the status
//   column, hairline divider, and natural left-flowing `[Title]  [Subtitle]  [Spacer]  [Status]` rows). Each row is
//   an individual SwiftUI `Link` opening its exact chat or job directly.

import ActivityKit
import SwiftUI
import WidgetKit

struct GroupedActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HQGroupedLiveAttributes.self) { context in
            let url = (context.state.soleItem?.link ?? context.attributes.link).flatMap(URL.init(string:))
            GroupedBannerView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .widgetURL(url)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            let single = state.soleItem.map { item -> (HQLiveAttributes, LiveActivityContent, LiveCard) in
                let attrs = GroupedLook.singleAttributes(item, accent: attributes.accent)
                let content = item.singleContent
                return (attrs, content, LiveCard(attrs, content, stale: context.isStale))
            }
            let url = (state.soleItem?.link ?? attributes.link).flatMap(URL.init(string:))
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    if let (attrs, content, _) = single {
                        HStack(spacing: 6) {
                            Image(systemName: LiveLook.symbol(attrs.subject.kind, content.phase))
                                .font(.headline)
                                .foregroundStyle(LiveLook.tint(content.phase, accent: attrs.accent))
                            Text(attrs.botName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.leading, 4)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                    } else {
                        Image(systemName: GroupedLook.symbol(state))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                            .padding(.leading, 6)
                            .dynamicTypeSize(...DynamicTypeSize.large)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let (_, content, _) = single {
                        LiveElapsed(state: content, stale: context.isStale, short: true)
                            .font(.headline)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.trailing, 4)
                            .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    } else {
                        Text(context.isStale && !state.isOver ? "Check app" : state.summary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(context.isStale && !state.isOver ? Color.secondary : GroupedLook.tint(state, accent: attributes.accent))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.trailing, 6)
                            .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let (attrs, content, card) = single {
                        LiveExpandedBottomView(attributes: attrs, state: content, card: card)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 2)
                            .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    } else {
                        GroupedExpandedBottomView(state: state, accent: attributes.accent)
                            .padding(.horizontal, 4)
                            .padding(.top, 2)
                            .padding(.bottom, 2)
                            .dynamicTypeSize(...DynamicTypeSize.large)
                    }
                }
            } compactLeading: {
                if let (attrs, content, _) = single {
                    Image(systemName: LiveLook.symbol(attrs.subject.kind, content.phase))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LiveLook.tint(content.phase, accent: attrs.accent))
                        .dynamicTypeSize(...DynamicTypeSize.large)
                } else {
                    Image(systemName: GroupedLook.symbol(state))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
            } compactTrailing: {
                if let (_, content, _) = single {
                    LiveCompactTrailing(state: content, stale: context.isStale)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                } else {
                    GroupedCompactTrailing(state: state, stale: context.isStale, accent: attributes.accent)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
            } minimal: {
                if let (attrs, content, _) = single {
                    Image(systemName: LiveLook.symbol(attrs.subject.kind, content.phase))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LiveLook.tint(content.phase, accent: attrs.accent))
                        .dynamicTypeSize(...DynamicTypeSize.large)
                } else {
                    Image(systemName: GroupedLook.symbol(state))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
            }
            .widgetURL(url)
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
            Group {
                if let sole = state.soleItem {
                    LiveSmallBannerView(attributes: GroupedLook.singleAttributes(sole, accent: attributes.accent),
                                        state: sole.singleContent, stale: stale)
                } else {
                    GroupedSmallBannerView(attributes: attributes, state: state, stale: stale)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .activityBackgroundTint(.clear)
            .environment(\.colorScheme, .dark)
        default:
            Group {
                if let sole = state.soleItem {
                    LiveLockScreenView(attributes: GroupedLook.singleAttributes(sole, accent: attributes.accent),
                                       state: sole.singleContent, stale: stale)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                } else {
                    GroupedLockScreenView(attributes: attributes, state: state, stale: stale)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lockScreenGlass()
        }
    }
}

/// Compact 2-line banner for Apple Watch Smart Stack and CarPlay (`.small` activity family) when 2+ items exist.
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

/// Lock Screen grouped card for 2+ items: balanced left/right header with subtle hairline divider over up to 5
/// individually tappable rows.
struct GroupedLockScreenView: View {
    let attributes: HQGroupedLiveAttributes
    let state: LiveGroupedContent
    let stale: Bool

    var body: some View {
        let shown = state.visible(limit: LiveGroupedContent.lockScreenLimit, reserveOverflowRow: true)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: GroupedLook.symbol(state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroupedLook.tint(state, accent: attributes.accent))
                Text(attributes.appName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(stale && !state.isOver ? "Check app" : state.summary)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(stale && !state.isOver ? .white.opacity(0.65) : GroupedLook.tint(state, accent: attributes.accent))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(height: 0.5)
            }

            VStack(alignment: .leading, spacing: 5.5) {
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

/// Expanded Dynamic Island bottom region for 2+ items: up to 4 tappable rows (or 3 rows + "+N more" when overflowing).
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

/// One compact single-line row (`[Title]  [Subtitle]  [Spacer]  [Status]`), wrapped in a `Link` when it carries a deep
/// link. Subtitles flow naturally right beside the title with no artificial width cap or dead middle gap:
/// - For main bot chats (`subtitleIsStep`), the bot name stays whole while the live step uses all remaining width.
/// - For side chats & jobs, the short bot tag stays whole beside the title while very long titles truncate neatly.
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(item.subtitleIsStep ? 1 : 0)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(item.subtitleIsStep ? 0 : 1)
                }
            }
            Spacer(minLength: 8)
            Text(item.statusWord)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroupedLook.statusColor(item.phase, accent: accent))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// [island-fit] Compact trailing Dynamic Island view for 2+ grouped items: shows "3 active" when solo, steps down to
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
    static func singleAttributes(_ item: LiveGroupedItem, accent: [Double]?) -> HQLiveAttributes {
        HQLiveAttributes(subject: item.subject, botName: item.botName ?? item.title, detail: item.detail,
                         link: item.link, accent: accent)
    }

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
