// What the Bots tab shows, top to bottom (spec 02 §7): pinned tiles (≤ 6) → the Pinned section (pins beyond the
// tiles) → user sections in roster order → unassigned rows → Hidden (collapsed). Pure, so it is unit-tested.

import Foundation

nonisolated enum BotListSectionID: Hashable, Sendable {
    case tiles
    case pinned
    case user(String)
    case unassigned
    case hidden
    case results
    /// [groups] The Group Chats block, and a user section's sub-block inside it (docs/spec/3x-groups.md §7.1, §7.11).
    case groups
    case groupSection(String)
    /// [bots-groupby] Group By › None: every bot and group chat in one list, no header, nothing filed by a drop.
    case everything
}

/// [bots-groupby] One row of a block that holds bots and group chats together (tester 2026-11-05: "Group chats and
/// individual bot chats cannot be assigned to the same section").
nonisolated enum BotListRow: Hashable, Sendable {
    case bot(String)
    case room(String)
}

nonisolated struct BotListSection: Hashable, Sendable {
    var id: BotListSectionID
    /// Header title; nil for the tiles and the unassigned rows (no header).
    var title: String?
    var bots: [Bot]
    /// [groups] The rooms of a Group Chats block. [bots-groupby] Also a user section's, Unassigned's and Group By ›
    /// None's: filed with the bots, drawn among them (`rows`).
    var rooms: [GroupRowModel] = []

    /// [bots-groupby] The block's bots and rooms in drawing order: the two lists merged by activity (a bot's last
    /// activity, a room's last message), each kind keeping its own order. The bots come already ordered (newest first,
    /// or the owner's order under Sort By › Manual), so with Manual a moved bot stays where it was put and each room
    /// still sits among the bots by its time (audit 05-4, 05-5: Manual used to send every group chat below the bots).
    func rows() -> [BotListRow] {
        if rooms.isEmpty { return bots.map { .bot($0.id) } }
        var out: [BotListRow] = []
        var b = bots[...], r = rooms[...]
        while let bot = b.first, let room = r.first {
            let botTime = bot.lastActive?.timeIntervalSince1970 ?? 0
            if botTime >= room.lastAt / 1000 { out.append(.bot(bot.id)); b = b.dropFirst() }
            else { out.append(.room(room.id)); r = r.dropFirst() }
        }
        return out + b.map { .bot($0.id) } + r.map { .room($0.id) }
    }
}

nonisolated enum BotList {
    static let maxTiles = 6
    static let pinnedSectionName = "Pinned"

    /// Pinned first, then most recent activity first; ties keep the roster's order (`HB/roster-pane-derivation.ts`).
    static func sorted(_ bots: [Bot]) -> [Bot] {
        bots.enumerated().sorted { a, b in
            if a.element.pinned != b.element.pinned { return a.element.pinned }
            let ta = a.element.lastActive?.timeIntervalSince1970 ?? 0, tb = b.element.lastActive?.timeIntervalSince1970 ?? 0
            return ta != tb ? ta > tb : a.offset < b.offset
        }.map(\.element)
    }

    /// The sections in display order. Empty sections are left out; Hidden is always last.
    static func compose(_ bots: [Bot]) -> [BotListSection] {
        let visible = sorted(bots.filter { !$0.hidden })
        let pins = visible.filter(\.pinned)
        // Tiles: the user's dragged order first (pinOrder), never-placed pins after them in sort order.
        let placed = pins.filter { $0.pinOrder != nil }.enumerated()
            .sorted { ($0.element.pinOrder!, $0.offset) < ($1.element.pinOrder!, $1.offset) }.map(\.element)
        let tiles = Array((placed + pins.filter { $0.pinOrder == nil }).prefix(maxTiles))
        let tileIDs = Set(tiles.map(\.id))
        var sections: [BotListSection] = []
        if !tiles.isEmpty { sections.append(BotListSection(id: .tiles, title: nil, bots: tiles)) }
        // Pins beyond the tiles, in the Pinned section (shown only when it has rows).
        let overflow = pins.filter { !tileIDs.contains($0.id) }
        if !overflow.isEmpty { sections.append(BotListSection(id: .pinned, title: pinnedSectionName, bots: overflow)) }
        // User sections in the order their first member appears in the roster; a non-pinned bot left in "Pinned"
        // has no home this device knows, so it is unassigned.
        let rest = visible.filter { !$0.pinned }
        var order: [String] = []
        for bot in bots where !bot.hidden && !bot.pinned {
            if let name = sectionName(bot), !order.contains(name) { order.append(name) }
        }
        for name in order {
            sections.append(BotListSection(id: .user(name), title: name, bots: rest.filter { sectionName($0) == name }))
        }
        let unassigned = rest.filter { sectionName($0) == nil }
        if !unassigned.isEmpty { sections.append(BotListSection(id: .unassigned, title: nil, bots: unassigned)) }
        let hidden = sorted(bots.filter(\.hidden))
        if !hidden.isEmpty { sections.append(BotListSection(id: .hidden, title: "Hidden", bots: hidden)) }
        return sections
    }

    private static func sectionName(_ bot: Bot) -> String? {
        guard let name = bot.sectionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.caseInsensitiveCompare(pinnedSectionName) != .orderedSame else { return nil }
        return name
    }

    /// Search: display name, profile, role and preview (`HB/data.ts:1464-1491`), hidden bots included.
    static func search(_ bots: [Bot], query: String) -> [Bot] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return sorted(bots).filter { bot in
            let haystack = [bot.name, bot.id, bot.role ?? "", bot.preview ?? ""].joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    enum Tone: Sendable { case secondary, tint, attention }

    /// [presence] What a row's second line is about, first match first (R:src/ui-kit/bot-status.ts:41-55 and
    /// R:src/ui-bots/bot-row.tsx:213-217; spec 3x-presence §4.2): waiting for the person, its browser, its computer, a
    /// running turn, nothing.
    /// [botslist] Ahead of those (R:src/ui-bots/row-status.ts:19-29): a standing problem in orange while the chat is
    /// not opening, then "Waking up…" once an open has taken over a second.
    enum RowStatus: Sendable { case attention, waking, needsInput, browser, computer, working, idle }

    static func rowStatus(_ bot: Bot) -> RowStatus {
        if bot.attention != nil, !bot.waking { return .attention }
        if bot.waking { return .waking }
        if bot.needsInput != nil { return .needsInput }                                        // [questions] approval, reply
        // A pending draft keeps its line, and so does a send that may not have arrived ([botslist] L189).
        if bot.presence?.browserLine != nil, bot.previewPrefix != "Draft:", bot.previewPrefix != RosterPreview.notDeliveredPrefix { return .browser }
        if bot.presence?.usingComputer == true { return .computer }
        return bot.isWorking ? .working : .idle
    }

    /// A row's second line (spec 02 §6.5): waiting for an answer, what its browser is doing, "Using its computer",
    /// "Working…" while its chat runs (or the step it is on, "Reading package.json…"), else the preview, the role, or
    /// "No messages yet".
    static func secondLine(_ bot: Bot) -> (text: String, tone: Tone) {
        switch rowStatus(bot) {
        case .attention: return (bot.attention ?? "", .attention)
        case .waking: return ("Waking up…", .secondary)
        case .needsInput: return (bot.needsInput?.statusText ?? "", .attention)
        case .browser: return (bot.presence?.browserLine ?? "", .tint)
        case .computer: return ("Using its computer", .tint)
        case .working: return (bot.step.map(LiveSteps.line) ?? "Working…", .tint)   // [toolnow]
        case .idle: break
        }
        if let preview = bot.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            return (preview, .secondary)
        }
        if let role = bot.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty { return (role, .secondary) }
        return ("No messages yet", .secondary)
    }

    /// [botslist] Bot Info's status line under the role (`S/ui-bots/info-sheet.tsx:142-155`, parity §3 L213): the live
    /// status in the row's own words, else how long ago the bot was last active; nil for a bot never active.
    static func infoStatus(_ bot: Bot, now: Date = Date(), calendar: Calendar = .current) -> (text: String, tone: Tone)? {
        let status = rowStatus(bot)
        if status != .idle { return secondLine(bot) }
        guard let last = bot.lastActive, last.timeIntervalSince1970 > 0 else { return nil }
        let seconds = max(0, now.timeIntervalSince(last))
        if seconds < 60 { return ("Active now", .secondary) }
        if seconds < 3600 { return ("Active \(Int(seconds / 60)) min ago", .secondary) }
        if seconds < 86_400 { return ("Active \(Int(seconds / 3600)) hr ago", .secondary) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? Int(seconds / 86_400)
        return (days <= 1 ? "Active yesterday" : "Active \(days) days ago", .secondary)
    }

    /// [presence] The avatar's corner badge (R:src/ui-kit/bot-avatar.tsx:14-20): the display for "Using its computer",
    /// the dots for a running turn or browser use.
    enum RowBadge: Sendable { case working, computer }

    /// The working arc (V:store/session-dot-state.ts:75 `showsRunningArc`): a running turn, but not one waiting on the
    /// person, whose orange cue is the louder one.
    static func showsArc(_ bot: Bot) -> Bool { bot.isWorking && bot.needsInput == nil }

    /// The unread circle (row, tile, time colour, VoiceOver, tab badge): not while the face shows the working dots. A
    /// running turn moves the chat's `last_active`, so a bot marked itself unread the moment it started on your message
    /// and drew a solid circle beside its typing dots (owner, 2026-10-30). The mark stays; it shows once the turn ends.
    static func showsUnread(_ bot: Bot) -> Bool { bot.unread && rowBadge(bot) == nil }

    static func rowBadge(_ bot: Bot) -> RowBadge? {
        switch rowStatus(bot) {
        case .computer: return .computer
        case .browser, .working: return .working
        case .needsInput, .idle, .attention, .waking: return bot.isWorking ? .working : nil   // as before this stream
        }
    }

    /// VoiceOver: "<name>. <line>. <time>. Unread. Pinned. Muted. Hidden" (present parts only, `row-status.ts:51-53`).
    /// `mute`: the live mute, so a timed one is read with its end ("Muted until 6:30 PM", as Bot Info shows it).
    static func accessibilityLabel(_ bot: Bot, time: String, muted: Bool = false, mute: BotMute? = nil) -> String {
        var second = secondLine(bot).text
        // [botslist] The preview's lead is spoken too: "Not Delivered: …", "Draft: …", "From Ivy: …" (it is on the row).
        if rowStatus(bot) == .idle, let prefix = bot.previewPrefix, !prefix.isEmpty,
           let preview = bot.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            second = "\(prefix) \(second)"
        }
        var parts = [bot.name, second]
        if !time.isEmpty { parts.append(time) }
        if showsUnread(bot) { parts.append("Unread") }
        if bot.pinned { parts.append("Pinned") }
        if muted { parts.append(mutedWords(mute)) }
        if bot.hidden { parts.append("Hidden") }
        return spoken(parts)
    }

    /// "Muted", or for a timed mute "Muted until 6:30 PM" / "Muted until Tue, Oct 6" (`BotMutes.value`).
    static func mutedWords(_ mute: BotMute?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let mute, !mute.always, mute.live(now) else { return "Muted" }
        let value = BotMutes.value(mute, now: now, locale: locale, timeZone: timeZone)   // "Until 6:30 PM"
        return "Muted " + value.prefix(1).lowercased() + value.dropFirst()
    }

    /// The parts as one spoken line, a full stop between them, except after a part that already ends its own
    /// sentence ("Handing you its browser…", a preview ending "?"): "…. Sep 29" is read as two stops.
    static func spoken(_ parts: [String]) -> String {
        var line = ""
        for part in parts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !part.isEmpty {
            if line.isEmpty { line = part; continue }
            let closed = line.last.map { ".…!?。！？".contains($0) } ?? false
            line += (closed ? " " : ". ") + part
        }
        return line
    }

    /// Bots counted on the Bots tab's badge: unread (and not working) and not hidden (`S/bot-unread-runtime.ts:147-161`).
    static func unreadCount(_ bots: [Bot]) -> Int { bots.filter { showsUnread($0) && !$0.hidden }.count }
}
