// [chats-under] Each bot's own chats, listed under its row on the Bots page (owner 2026-11-08: "the feel of the bot
// page we have with the simplicity of the sessions page"). Filter › Chats Under Bots picks what shows for every bot:
// Off (the default, so the page stays as it was), Active (working, waiting for an answer, or unread: tester
// 2026-11-08, "I create a lot of sessions so favorites won't scale well"), Pinned Only, or Pinned + Recent with 1, 2, 3
// or 5 recent chats; a bot's hold menu can set its own, and has View Sessions. "N more" opens Sessions with the bot's
// chip picked.

import SwiftUI
import UIKit

/// What a bot lists under its row.
nonisolated enum BotChatsMode: String, CaseIterable, Sendable {
    case off, active, pinned, recent

    var title: String {
        switch self {
        case .off: "Off"
        case .active: "Active"
        case .pinned: "Pinned Only"
        case .recent: "Pinned + Recent"
        }
    }

    /// The menu's second line.
    var detail: String? {
        switch self {
        case .active: "Working, waiting for you, or unread"
        case .pinned: "Chats you pin"
        default: nil
        }
    }
}

/// A mode and, for Pinned + Recent, how many recent chats.
nonisolated struct BotChatsChoice: Hashable, Sendable {
    var mode: BotChatsMode
    var count: Int

    static let counts = [1, 2, 3, 5]
    static let standard = BotChatsChoice(mode: .recent, count: 2)
    /// Until it's chosen: off, so nobody's page changes on its own.
    static let initial = BotChatsChoice(mode: .off, count: 2)

    /// The Filter menu's subtitle: "Off", "Pinned only", "Pinned + 2 recent".
    var summary: String {
        switch mode {
        case .off: "Off"
        case .active: "Active chats"
        case .pinned: "Pinned only"
        case .recent: "Pinned + \(count) recent"
        }
    }

    /// Stored as "off", "pinned" or "recent:2".
    var stored: String { mode == .recent ? "recent:\(count)" : mode.rawValue }

    init(mode: BotChatsMode, count: Int) {
        self.mode = mode
        self.count = Self.counts.contains(count) ? count : Self.standard.count
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard let mode = parts.first.flatMap(BotChatsMode.init(rawValue:)) else { return nil }
        self.init(mode: mode, count: parts.count > 1 ? Int(parts[1]) ?? Self.standard.count : Self.standard.count)
    }
}

/// The choices, kept on this device: one for every bot, and any bot's own.
@MainActor enum BotChatsPrefs {
    static let key = "hq.bots.chatsUnder"
    static let botsKey = "hq.bots.chatsUnder.bots"
    /// [mac] Posted when a choice changes: the Mac's sidebar, which lists the bots there, draws their chats again.
    static let changed = Notification.Name("BotChatsPrefs.changed")

    static var all: BotChatsChoice {
        get { UserDefaults.standard.string(forKey: key).flatMap(BotChatsChoice.init(stored:)) ?? .initial }
        set {
            UserDefaults.standard.set(newValue.stored, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Any bot lists chats: all bots' choice, or one bot's own.
    static var inUse: Bool {
        all.mode != .off || (UserDefaults.standard.dictionary(forKey: botsKey)?.values.contains { ($0 as? String) != BotChatsMode.off.rawValue } ?? false)
    }

    /// A bot's own choice; nil follows `all`.
    static func own(_ bot: String) -> BotChatsChoice? {
        (UserDefaults.standard.dictionary(forKey: botsKey)?[bot] as? String).flatMap(BotChatsChoice.init(stored:))
    }

    static func setOwn(_ choice: BotChatsChoice?, for bot: String) {
        var stored = UserDefaults.standard.dictionary(forKey: botsKey) as? [String: String] ?? [:]
        stored[bot] = choice?.stored
        UserDefaults.standard.set(stored, forKey: botsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func choice(for bot: String) -> BotChatsChoice { own(bot) ?? all }
}

/// Which chats a bot lists, and how many it leaves for Sessions.
nonisolated enum BotChatsUnder {
    /// Pinned (or active) chats shown at most, so one bot doesn't take the page.
    static let maxPinned = 5

    /// Working, waiting for an answer, or unread.
    static func isActive(_ session: SessionSummary) -> Bool {
        session.isRunning || session.unread || session.status == .needsInput || session.status == .working
    }

    /// `sessions` is the Sessions list's recents (pinned first, then newest first): the bot's pinned chats (up to
    /// `maxPinned`), then for Pinned + Recent its newest others, `count` of them. `more`: its chats not shown.
    static func pick(_ sessions: [SessionSummary], bot: String, choice: BotChatsChoice) -> (shown: [SessionSummary], more: Int) {
        guard choice.mode != .off else { return ([], 0) }
        let own = sessions.filter { $0.profile == bot && !$0.archived }
        if choice.mode == .active {
            // Waiting for you first, then working, then unread; newest first within each.
            let active = own.filter(isActive).sorted {
                let a = rank($0), b = rank($1)
                return a != b ? a < b : ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast)
            }
            let shown = Array(active.prefix(maxPinned))
            return (shown, own.count - shown.count)
        }
        let pinned = own.filter(\.pinned).prefix(maxPinned)
        var shown = Array(pinned)
        if choice.mode == .recent {
            let recent = own.filter { !$0.pinned }
                .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            shown += recent.prefix(choice.count)
        }
        return (shown, own.count - shown.count)
    }

    private static func rank(_ session: SessionSummary) -> Int {
        session.status == .needsInput ? 0 : session.isRunning || session.status == .working ? 1 : 2
    }
}

/// Where the line and the titles sit, under the bot row's face (both looks).
enum BotChatsMetrics {
    static var leading: CGFloat { Theme.isDesktop ? DesktopRows.gutter : BotRowMetrics.leading }
    static var lineX: CGFloat {
        Theme.isDesktop ? DesktopRows.gutter + DesktopRows.face / 2 : BotRowMetrics.leading + BotRowMetrics.face / 2
    }
    static var textX: CGFloat { lineX + 19 }
    static var rowHeight: CGFloat { Theme.isDesktop ? 34 : Density.ios(34, 28) }
    /// Under the last row, before the next bot.
    static let tail: CGFloat = 6
}

/// How the line down a bot's chats looks (owner 2026-11-08: "all of those options for the line down … so that the person
/// could pick"): a short branch out to each chat (the default, picked first), a dot on the line at each chat, the line
/// alone, the line with a thin rule between chats, or nothing. Settings › Appearance › Chats Under Bots (owner: "Shouldn't
/// the style choice be in the theme areas of Settings?"), kept on this device.
nonisolated enum BotChatsStyle: String, CaseIterable, Sendable {
    case branch, dots, line, dividers, none

    static let key = "hq.bots.chatsUnder.style"
    /// Posted when the style changes: the Bots list redraws its chats.
    static let changed = Notification.Name("BotChatsStyle.changed")
    static var saved: BotChatsStyle {
        get { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .branch }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    var title: String {
        switch self {
        case .branch: "Branches"
        case .dots: "Dots"
        case .line: "Line"
        case .dividers: "Dividers"
        case .none: "No Line"
        }
    }

    /// The menu's picture for it.
    var symbol: String {
        switch self {
        case .branch: "arrow.turn.down.right"
        case .dots: "circle.dotted"
        case .line: "line.3.horizontal"
        case .dividers: "rectangle.split.1x2"
        case .none: "minus"
        }
    }

    /// The line ends at the last row's mark (a branch or a dot) instead of short of its foot.
    var marksRows: Bool { self == .branch || self == .dots }
}

/// The thin line down the bot's chats, in the bot's own colour (owner 2026-11-08: "the same color as the bot"), drawn in
/// the chosen style. It runs through a row and stops at the last one. `lineX` and `style` come from the row, so a change
/// of look or style redraws it with the text (read here, the line stayed where the old look put it). [mac] The Mac's
/// sidebar draws it under its bot rows too (`MacSidebarChat`).
struct BotChatsLine: View {
    var last: Bool
    var tint: Color
    var lineX: CGFloat
    var style: BotChatsStyle
    /// "N more" gets a branch, not a dot.
    var more = false
    static let width: CGFloat = 1
    static let branch: CGFloat = 11
    var body: some View {
        if style != .none {
            GeometryReader { proxy in
                let content = proxy.size.height - (last ? BotChatsMetrics.tail : 0)
                let middle = content / 2
                let end = !last ? proxy.size.height : style.marksRows ? middle + Self.width / 2 : content - 8
                ZStack(alignment: .topLeading) {
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: Self.width, height: max(0, end))
                        .offset(x: lineX - Self.width / 2)
                    if style == .branch || (style == .dots && more) {
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: Self.branch, height: Self.width)
                            .offset(x: lineX - Self.width / 2, y: middle - Self.width / 2)
                    } else if style == .dots {
                        Circle().fill(tint).frame(width: 6, height: 6).offset(x: lineX - 3, y: middle - 3)
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// One of the bot's chats, as the Sessions page draws it: its title, a dot when unread, its time.
struct BotChatRowView: View {
    var session: SessionSummary
    var last: Bool
    /// The bot's own colour (its line in the tint style).
    var tint: Color = .hqStroke
    var style: BotChatsStyle = .saved
    @ScaledMetric(relativeTo: .callout) private var height: CGFloat = BotChatsMetrics.rowHeight

    var body: some View {
        let time = ListTime.string(session.lastActive)
        HStack(spacing: 8) {
            if session.pinned {
                Image(systemName: "pin.fill").font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
            }
            Text(session.title)
                .font(Font.hq(Density.compact && !Theme.isDesktop ? .subheadline : .callout).weight(session.unread ? .semibold : .regular))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if session.isRunning {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else if session.unread || session.status == .needsInput {
                // Orange when it waits for an answer, as the Sessions page marks it.
                Circle().fill(session.status == .needsInput ? Color.hqOrange : Color.hqTint)
                    .frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(time)
                .font(Font.hq(.footnote))
                .monospacedDigit()
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, BotChatsMetrics.textX)
        .padding(.trailing, BotChatsMetrics.leading)
        .frame(minHeight: height)
        .overlay(alignment: .bottom) {
            if style == .dividers, !last {
                Rectangle().fill(Color.hqStroke).frame(height: 0.5)
                    .padding(.leading, BotChatsMetrics.textX).accessibilityHidden(true)
            }
        }
        .padding(.bottom, last ? BotChatsMetrics.tail : 0)
        .background(alignment: .leading) { BotChatsLine(last: last, tint: tint, lineX: BotChatsMetrics.lineX, style: style) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BotChatRowView.label(session, time: time))
        .accessibilityAddTraits(.isButton)
    }

    static func label(_ session: SessionSummary, time: String) -> String {
        var words = [session.title]
        if session.pinned { words.append("Pinned") }
        if session.status == .needsInput { words.append("Waiting for you") }
        if session.isRunning { words.append("Working") } else if session.unread { words.append("Unread") }
        if !time.isEmpty { words.append(time) }
        return words.joined(separator: ", ")
    }
}

/// "N more ›": the rest of the bot's chats, in Sessions with its chip picked.
struct BotChatsMoreView: View {
    var count: Int
    var botName: String
    var tint: Color = .hqStroke
    var style: BotChatsStyle = .saved
    // [ui-sizing] The chat rows' height (Compact's too) as its own: a fixed 32 stood taller than Compact's 28 pt rows.
    @ScaledMetric(relativeTo: .subheadline) private var textHeight: CGFloat = 32
    private var height: CGFloat { textHeight / 32 * BotChatsMetrics.rowHeight }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count) more").font(Font.hq(.subheadline).weight(.medium))
            Image(systemName: "chevron.right").font(Font.hq(.caption).weight(.semibold))
        }
        .foregroundStyle(Color.hqTintText)
        .padding(.leading, BotChatsMetrics.textX)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .padding(.bottom, BotChatsMetrics.tail)
        .background(alignment: .leading) { BotChatsLine(last: true, tint: tint, lineX: BotChatsMetrics.lineX, style: style, more: true) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) more chats with \(botName)")
        .accessibilityHint("Opens Sessions with \(botName) picked")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Menus

extension BotChatsChoice {
    /// The choices as menu nodes: the three modes, then the recent count as a row of numbers. `follow`: a bot's own
    /// menu leads with "Same as All Bots" (checked when the bot has no choice of its own).
    @MainActor static func menuNodes(current: BotChatsChoice, own: Bool?, all: BotChatsChoice,
                                     pick: @escaping (BotChatsChoice?) -> Void) -> [BotMenuNode] {
        var modes: [BotMenuNode] = []
        if let own {
            var same = BotMenuNode.action("Same as All Bots", nil, checked: !own) { pick(nil) }
            same.subtitle = all.summary
            modes.append(same)
        }
        let checks = own ?? true
        for mode in BotChatsMode.allCases {
            var node = BotMenuNode.action(mode.title, nil, checked: checks && current.mode == mode) {
                pick(BotChatsChoice(mode: mode, count: current.count))
            }
            node.subtitle = mode.detail
            node.identifier = "chats-under.\(mode.rawValue)"
            modes.append(node)
        }
        let numbers = counts.map { count in
            var node = BotMenuNode.action("\(count)", "\(count).circle", checked: current.mode == .recent && current.count == count) {
                pick(BotChatsChoice(mode: .recent, count: count))
            }
            node.identifier = "chats-under.count.\(count)"
            return node
        }
        return [
            BotMenuNode(title: "", kind: .inline(modes)),
            BotMenuNode(title: own == nil ? "Recent Chats per Bot" : "Recent Chats", kind: .palette(numbers)),
        ]
    }
}

extension Bot {
    /// [chats-under] The bot's own colour: its head's accent.
    var chatsTint: Color {
        let color = Head.resolve(head, profile: id).color
        // Ink and paper faces are drawn black or white (as the page asks), not in their accent.
        if color == .ink { return .hqLabel }
        if color == .paper { return .hqLabel2 }
        let rgb = HeadTones.accent(color)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - Settings › Appearance › Chats Under Bots

/// [chats-under] The style's page: a preview of a bot's chats drawn in it, then the five styles.
enum BotChatsStyleSettings {
    static let title = "Chats Under Bots"
    static func make() -> UIViewController {
        let page = SettingsPageController(title: title, BotChatsStyleSettingsView())
        page.view.accessibilityIdentifier = "settings.chats-under"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

struct BotChatsStyleSettingsView: View {
    @AppStorage(BotChatsStyle.key) private var raw = BotChatsStyle.branch.rawValue
    private var style: BotChatsStyle { BotChatsStyle(rawValue: raw) ?? .branch }

    #if targetEnvironment(macCatalyst)
    // [mac] The Mac's bots are in the sidebar, whose right click has the choice (the Bots list's Filter never shows there).
    static let note = "How the line beside each bot's chats looks in the sidebar. To show chats under your bots, Control-click a bot or the sidebar's empty space, then choose Chats Under Bots."
    #else
    static let note = "How the line beside each bot's chats looks on the Bots page. To show chats under your bots, open Bots, tap Filter, then Chats Under Bots."
    #endif

    private static func sample(_ id: String, _ title: String, hoursAgo: Double, unread: Bool = false) -> SessionSummary {
        SessionSummary(id: id, profile: "preview", title: title, preview: nil, lastActive: Date().addingTimeInterval(-hoursAgo * 3600),
                       source: "desktop", unread: unread, isRunning: false)
    }

    var body: some View {
        List { Group {
            Section {
                VStack(spacing: 0) {
                    BotChatRowView(session: Self.sample("p1", "Draft the weekly newsletter", hoursAgo: 1, unread: true), last: false,
                                   tint: .hqTint, style: style)
                    BotChatRowView(session: Self.sample("p2", "Plan next week", hoursAgo: 26), last: false, tint: .hqTint, style: style)
                    BotChatsMoreView(count: 3, botName: "your bot", tint: .hqTint, style: style)
                }
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            } header: { HQSectionLabel { Text("Preview") } }
            Section {
                ForEach(BotChatsStyle.allCases, id: \.self) { option in
                    Button {
                        guard option != style else { return }
                        Haptics.play(.selection)
                        BotChatsStyle.saved = option
                        raw = option.rawValue
                        AppLog.trace("settings", "chats under bots style \(option.rawValue)")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: option.symbol).frame(width: 24).foregroundStyle(Color.hqTintText)
                            Text(option.title).foregroundStyle(Color.hqLabel)
                            Spacer(minLength: 8)
                            if option.rawValue == raw { Image(systemName: "checkmark").foregroundStyle(Color.hqTintText).fontWeight(.semibold) }
                        }
                    }
                    .accessibilityAddTraits(option.rawValue == raw ? .isSelected : [])
                    .accessibilityIdentifier("chats-under.style.\(option.rawValue)")
                }
            } header: { HQSectionLabel { Text("Style") } } footer: { HQSectionFooter { Text(Self.note) } }
            .id(raw)   // the rows redraw with their tick when the pick changes (a List kept the old one)
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
    }
}

/// [chats-under] Settings › Appearance's row for the page, with the style it's set to.
struct BotChatsStyleRow: View {
    var open: () -> Void
    @AppStorage(BotChatsStyle.key) private var raw = BotChatsStyle.branch.rawValue
    var body: some View {
        if DeviceWord.isMac {
            // [mac] Owner 2026-11-09 (Settings "too iOS-like"): one choice is a pop-up in its row, not a page of its
            // own; the sidebar beside it shows the line as it changes.
            HStack(spacing: 12) {
                SettingsRowLabel(title: BotChatsStyleSettings.title, systemImage: "arrow.turn.down.right")
                Spacer(minLength: 16)
                MacPopUp(label: BotChatsStyleSettings.title, selection: Binding(get: { BotChatsStyle(rawValue: raw) ?? .branch }, set: { option in
                    BotChatsStyle.saved = option
                    raw = option.rawValue
                    AppLog.trace("settings", "chats under bots style \(option.rawValue)")
                }), options: BotChatsStyle.allCases) { $0.title }
                    .accessibilityIdentifier("settings.chats-under-row")
                    .hqMacSettingsControl()
            }
            .help("The line beside each bot's chats in the sidebar")
        } else {
        NavRow(title: BotChatsStyleSettings.title, systemImage: "arrow.turn.down.right",
               value: (BotChatsStyle(rawValue: raw) ?? .branch).title, action: open)
            .accessibilityIdentifier("settings.chats-under-row")
        }
    }
}
