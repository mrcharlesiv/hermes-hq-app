// Bots list composition (spec 02 §6, §7): roster rows + merged meta + device-local state → `Bot` rows in display
// order (pinned tiles, the Pinned section, user sections, unassigned rows, hidden rows) and per-row details. Pure.

import Foundation

/// A user section as this device knows it (`hermes.plugin.hermes-bots.bot-sections-v1`): display order is the
/// array order. Membership lives on each bot's meta (`sectionId`).
nonisolated struct RosterSectionRecord: Codable, Sendable, Hashable {
    var id: String
    var name: String
}

/// The Bots list, top to bottom (§7.5). `flat` is the same rows in one array (what `BotStore.bots` holds).
nonisolated struct RosterLayout: Sendable, Hashable {
    nonisolated struct Section: Sendable, Hashable, Identifiable {
        var id: String
        var name: String
        var bots: [Bot]
        var isPinned: Bool { id == RosterRules.pinnedSectionId }
    }

    /// Up to six pinned bots, in the device's tile order (`Bot.pinOrder` 0…5).
    var tiles: [Bot] = []
    /// The Pinned section (first, only when it holds pins that are not tiles), then user sections in order. Only
    /// sections with rows are listed.
    var sections: [Section] = []
    /// Rows with no (known) section, drawn last with no header.
    var unassigned: [Bot] = []
    /// Hidden bots, for the collapsed "Hidden · N" group at the bottom.
    var hidden: [Bot] = []

    var flat: [Bot] { tiles + sections.flatMap(\.bots) + unassigned + hidden }
    /// [manualorder] The rows below the tiles, top to bottom (what Sort By › Manual orders).
    var rows: [Bot] { sections.flatMap(\.bots) + unassigned + hidden }
    /// [manualorder] The same rows by block (Pinned and each section, the unassigned rows, Hidden), as bot ids.
    var rowBlocks: [[String]] { (sections.map(\.bots) + [unassigned, hidden]).map { $0.map(\.id) } }
    var isEmpty: Bool { tiles.isEmpty && sections.isEmpty && unassigned.isEmpty && hidden.isEmpty }
}

/// What a row knows beyond the shared `Bot` fields.
nonisolated struct BotRowDetail: Sendable, Hashable {
    var profile: String
    var handle: String
    /// The cleaned preview split for drawing: prefix ("From Inbox:") in the label colour, then the text.
    var preview: RosterPreview.Parts
    /// The row's time, seconds since the epoch (0: none). Format with `ListTime.string(seconds:)` at draw time.
    var time: Double
    /// The Bot Chat's registry id and the id that opens (lineage tip); nil when the roster names no Bot Chat.
    var registryId: String?
    var openId: String?
    var canonicalIds: [String]
    /// The chat's stored count (includes tool rows; never show it as an unread count).
    var messageCount: Int?
    /// The section the bot goes back to when unpinned (menus and Bot Info show this one).
    var homeSectionId: String?
    var isTile: Bool
    var model: String?
    var hasAvatar: Bool
}

nonisolated enum RosterBuilder {
    nonisolated struct Input: Sendable {
        var profiles: [RosterProfile]
        /// Merged local meta snapshot by profile (§5.2); a profile missing here reads its row's own meta.
        var meta: [String: JSONValue]
        var sections: [RosterSectionRecord]
        /// Tile order: profile names, first tile first (`dispatch.bots.pinOrder.v1`).
        var pinOrder: [String]
        var unread: BotUnreadState
        /// Profiles whose own Bot Chat is busy right now (fed by the chat engine; side chats don't count).
        var working: Set<String>
        /// Bot Chats this device created since the last roster named them: profile → stored id.
        var mintedChats: [String: String]
        /// Previews worked out by the last build (a rebuild for an unread or working change reuses them).
        var previews: RosterPreviewCache
        /// [questions] Profiles whose chat waits for an answer (spec 1x §3.6), fed by the server-request centre.
        var needsInput: [String: NeedsInput] = [:]
        /// Verify round 3: the words typed and not sent in a bot's chat, by profile (the row says "Draft: <words>",
        /// spec 02 §6.4 item 4, R:src/ui-lists/row-pending.ts).
        var drafts: [String: String] = [:]
        /// [botslist] The words of a send in the bot's Bot Chat that may never have arrived, by profile: the row says
        /// "Not Delivered: <words>", ahead of a draft (parity §3 L189, R:src/ui-lists/row-pending.ts:15-21).
        var lost: [String: String] = [:]
        /// [botslist] Bots whose chat has been opening for over a second (L184), and each bot's standing problem (L185).
        var waking: Set<String> = []
        var attention: [String: String] = [:]
        /// [presence] What each bot is doing outside its chat (spec 3x-presence §3.3), fed by the presence centre.
        var presence: [String: BotPresence] = [:]
        /// [toolnow] Each working bot's Bot Chat step in a few words, by profile (LiveSteps).
        var steps: [String: String] = [:]
        /// [manualorder] Sort By › Manual: the rows' order (profile names, `BotRowOrder`); nil for Recent Activity.
        var rowOrder: [String]? = nil

        init(profiles: [RosterProfile], meta: [String: JSONValue] = [:], sections: [RosterSectionRecord] = [],
             pinOrder: [String] = [], unread: BotUnreadState = BotUnreadState(), working: Set<String> = [],
             mintedChats: [String: String] = [:], previews: RosterPreviewCache = RosterPreviewCache()) {
            self.profiles = profiles; self.meta = meta; self.sections = sections; self.pinOrder = pinOrder
            self.unread = unread; self.working = working; self.mintedChats = mintedChats; self.previews = previews
        }
    }

    nonisolated struct Output: Sendable {
        var layout: RosterLayout
        var details: [String: BotRowDetail]
        /// Pass back as `Input.previews` on the next build.
        var previews: RosterPreviewCache
    }

    /// The meta a row is drawn with: `{...snapshot, ...server}` when the row carries its own `hermes-bots` object (M1
    /// never writes meta, so the device snapshot can hold nothing fresher than the server; a pin, hide or section
    /// change made elsewhere shows from the cached or slim row without waiting for the full answer), else the
    /// snapshot.
    static func meta(for profile: RosterProfile, snapshot: [String: JSONValue]) -> BotMeta {
        guard let server = profile.serverMeta else { return BotMeta(json: snapshot[profile.name]) }
        guard let local = snapshot[profile.name]?.object, !local.isEmpty else { return BotMeta(json: .object(server)) }
        return BotMeta(json: .object(local.merging(server) { _, theirs in theirs }))
    }

    static func build(_ input: Input, model: (String) -> String = { $0 }) -> Output {
        let profiles = input.profiles
        let metas = profiles.map { meta(for: $0, snapshot: input.meta) }
        let names = zip(profiles, metas).map { RosterRules.displayName($0, meta: $1) }
        // Display names by handle, for "From <Name>:" (`S/ui-bots/identity.ts:24-29`).
        var nameByHandle: [String: String] = [:]
        for (profile, name) in zip(profiles, names) where nameByHandle[profile.handle] == nil { nameByHandle[profile.handle] = name }

        // Sort (§7.2): pinned first, then newest first; ties keep profiles.list order.
        let order = profiles.indices.sorted { a, b in
            let pa = metas[a].effectivePinned, pb = metas[b].effectivePinned
            if pa != pb { return pa }
            let ta = RosterRules.sortTime(profiles[a], meta: metas[a]), tb = RosterRules.sortTime(profiles[b], meta: metas[b])
            if ta != tb { return ta > tb }
            return a < b
        }

        // Tiles (§7.3): the first six visible pins, dragged order first, never-placed pins after in sort order.
        let rank = Dictionary(input.pinOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let pins = order.filter { metas[$0].effectivePinned && !metas[$0].hidden }
        let tileIndices = pins.enumerated()
            .sorted { (rank[profiles[$0.element].name] ?? Int.max, $0.offset) < (rank[profiles[$1.element].name] ?? Int.max, $1.offset) }
            .prefix(RosterRules.maxTiles).map(\.element)
        let tileSet = Set(tileIndices)

        let known = input.sections.filter { $0.id != RosterRules.pinnedSectionId }
        let knownIds = Set(known.map(\.id))

        var details: [String: BotRowDetail] = [:]
        var previews = RosterPreviewCache()
        func row(_ i: Int, sectionName: String?, pinOrder: Int?) -> Bot {
            let profile = profiles[i], meta = metas[i], name = names[i]
            let role = RosterRules.roleLine(profile, meta: meta, name: name)
            var (source, parts) = input.previews.preview(for: profile, role: role, nameByHandle: nameByHandle, model: model,
                                                         into: &previews)
            if let lost = input.lost[profile.name] {
                var pending = RosterPreview.botPreview(text: lost, fromBot: nil, draft: true, role: role, model: model)
                pending.prefix = RosterPreview.notDeliveredPrefix
                parts = pending
            } else if let draft = input.drafts[profile.name] {
                parts = RosterPreview.botPreview(text: draft, fromBot: nil, draft: true, role: role, model: model)
            }
            let canonical = profile.canonicalSession
            let registryId = canonical.flatMap { $0.id.isEmpty ? nil : $0.id }
            let openId = registryId != nil ? canonical?.openId : input.mintedChats[profile.name]
            details[profile.name] = BotRowDetail(
                profile: profile.name, handle: profile.handle, preview: parts, time: source.time,
                registryId: registryId, openId: openId, canonicalIds: profile.canonicalIds,
                messageCount: canonical?.messageCount, homeSectionId: meta.homeSectionId,
                isTile: pinOrder != nil, model: profile.model, hasAvatar: profile.hasAvatar)
            return Bot(id: profile.name, name: name, role: role,
                       preview: parts.isFallback ? nil : parts.line,
                       lastActive: source.time > 0 ? Date(timeIntervalSince1970: source.time) : nil,
                       isWorking: input.working.contains(profile.name),
                       unread: input.unread.isUnread(profile),
                       pinned: meta.effectivePinned, pinOrder: pinOrder, sectionName: sectionName,
                       hidden: meta.hidden, canonicalSessionId: openId, head: profile.head,
                       needsInput: input.needsInput[profile.name], previewPrefix: parts.isFallback ? nil : parts.prefix,
                       presence: input.presence[profile.name].flatMap { $0.isEmpty ? nil : $0 },   // [presence]
                       waking: input.waking.contains(profile.name), attention: input.attention[profile.name],   // [botslist]
                       step: input.steps[profile.name])   // [toolnow]
        }

        var layout = RosterLayout()
        for (index, i) in tileIndices.enumerated() { layout.tiles.append(row(i, sectionName: nil, pinOrder: index)) }

        var pinnedRows: [Bot] = []
        var bySection: [String: [Bot]] = [:]
        for i in order where !tileSet.contains(i) {
            let meta = metas[i]
            if meta.hidden {
                layout.hidden.append(row(i, sectionName: nil, pinOrder: nil))
            } else if meta.effectivePinned {
                pinnedRows.append(row(i, sectionName: RosterRules.pinnedSectionName, pinOrder: nil))
            } else if let id = meta.homeSectionId, knownIds.contains(id), let section = known.first(where: { $0.id == id }) {
                bySection[id, default: []].append(row(i, sectionName: section.name, pinOrder: nil))
            } else {
                layout.unassigned.append(row(i, sectionName: nil, pinOrder: nil))
            }
        }
        // [manualorder] Sort By › Manual: each block in the owner's order, rows it doesn't name folded in by position.
        if let ids = input.rowOrder, !ids.isEmpty {
            pinnedRows = BotRowOrder.ordered(pinnedRows, by: ids)
            bySection = bySection.mapValues { BotRowOrder.ordered($0, by: ids) }
            layout.unassigned = BotRowOrder.ordered(layout.unassigned, by: ids)
            layout.hidden = BotRowOrder.ordered(layout.hidden, by: ids)
        }
        if !pinnedRows.isEmpty {
            layout.sections.append(.init(id: RosterRules.pinnedSectionId, name: RosterRules.pinnedSectionName, bots: pinnedRows))
        }
        for section in known {
            if let rows = bySection[section.id], !rows.isEmpty { layout.sections.append(.init(id: section.id, name: section.name, bots: rows)) }
        }
        return Output(layout: layout, details: details, previews: previews)
    }

    /// Section adoption (`HB/user-sections.ts:159-191`): a section id this device does not know is added with the name
    /// its members carry; a known section takes its members' name when they all agree on one. Order and empty
    /// sections stay this device's own. The Pinned section is implicit and never stored here.
    static func adoptSections(_ local: [RosterSectionRecord], profiles: [RosterProfile], meta snapshot: [String: JSONValue]) -> [RosterSectionRecord] {
        var names: [(id: String, names: [String])] = []
        for profile in profiles {
            let meta = meta(for: profile, snapshot: snapshot)
            guard let id = meta.sectionId, id != RosterRules.pinnedSectionId, let name = meta.sectionName else { continue }
            if let index = names.firstIndex(where: { $0.id == id }) {
                if !names[index].names.contains(name) { names[index].names.append(name) }
            } else {
                names.append((id, [name]))
            }
        }
        let current = local.filter { $0.id != RosterRules.pinnedSectionId }
        let knownIds = Set(current.map(\.id))
        var next = current.map { record -> RosterSectionRecord in
            guard let entry = names.first(where: { $0.id == record.id }), entry.names.count == 1 else { return record }
            return RosterSectionRecord(id: record.id, name: entry.names[0])
        }
        for entry in names where !knownIds.contains(entry.id) { next.append(RosterSectionRecord(id: entry.id, name: entry.names[0])) }
        return next
    }
}

/// The worked-out preview of each row, kept between builds: the preview pipeline (several dozen regular expressions per
/// row) reruns only for a row whose sessions, role or delivery sender changed, not when a rebuild only flips unread or
/// working flags. Start a fresh cache when the model labels change.
nonisolated struct RosterPreviewCache: Sendable {
    nonisolated struct Entry: Sendable {
        // Inputs of the source half.
        var canonical: RosterSessionRef?
        var last: RosterSessionRef?
        var source: RosterRules.PreviewSource
        var text: String
        var handle: String?
        // Inputs and result of the drawn half (nil until worked out).
        var drawn: (role: String?, fromBot: String?, parts: RosterPreview.Parts)?
    }

    private(set) var entries: [String: Entry] = [:]

    init() {}

    var count: Int { entries.count }

    /// The row's preview source and drawn parts, reused from this cache when their inputs are unchanged; the result
    /// is recorded in `next`.
    func preview(for profile: RosterProfile, role: String?, nameByHandle: [String: String], model: (String) -> String,
                 into next: inout RosterPreviewCache) -> (RosterRules.PreviewSource, RosterPreview.Parts) {
        let canonical = profile.canonicalSession, last = profile.lastSession
        var entry: Entry
        if let old = entries[profile.name], old.canonical == canonical, old.last == last {
            entry = old
        } else {
            let source = RosterRules.rosterPreview(profile, model: model)
            entry = Entry(canonical: canonical, last: last, source: source,
                          text: RosterPreview.sourcePreview(profile, shown: source.preview),
                          handle: RosterPreview.deliveryHandle(source.preview), drawn: nil)
        }
        let fromBot = entry.handle.map { nameByHandle[$0] ?? $0 }
        let parts: RosterPreview.Parts
        if let drawn = entry.drawn, drawn.role == role, drawn.fromBot == fromBot {
            parts = drawn.parts
        } else {
            parts = RosterPreview.botPreview(text: entry.text, fromBot: fromBot, role: role, bot: profile.name, model: model)
            entry.drawn = (role, fromBot, parts)
        }
        next.entries[profile.name] = entry
        return (entry.source, parts)
    }
}
