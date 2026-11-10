// Roster wire types: profiles.list rows, their session references and the bot meta in ui_meta['hermes-bots'].
// Spec 02 §2.1 (shape), §3 step 5 (text hygiene), §5.1 (meta fields). Decoding is lenient: unknown keys are ignored,
// every documented key is optional, and fields that arrive as numbers/bools where text is expected become text.

import Foundation

// MARK: - Text helpers

nonisolated enum RosterText {
    /// JS `String(value)` for the scalar kinds the roster can carry where text is expected; "" for anything else
    /// (`S/ui-kit/bot-identity.ts` textOf).
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: return s
        case .number(let n)?: return numberText(n)
        case .bool(let b)?: return b ? "true" : "false"
        default: return ""
        }
    }

    /// Trimmed text, nil when blank.
    static func trimmed(_ value: JSONValue?) -> String? { nonBlank(text(value)) }

    static func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// JS number → string for the values YAML hands back ("2025", "1.5").
    static func numberText(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 9.007e15 { return String(Int64(n)) }
        return String(n)
    }

    /// A strict JSON number (JS `typeof x === 'number'`), finite.
    static func number(_ value: JSONValue?) -> Double? {
        if case .number(let n)? = value, n.isFinite { return n }
        return nil
    }

    /// A strict JSON number as a count: truncated toward zero, nil when it does not fit an `Int` (a malformed or huge
    /// `message_count` must never trap at decode).
    static func count(_ value: JSONValue?) -> Int? {
        guard let n = number(value) else { return nil }
        return Int(exactly: n.rounded(.towardZero))
    }

    /// JS truthiness for the flags meta carries (`if (meta.pinned)`).
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let s)?: return !s.isEmpty
        case .array?, .object?: return true
        default: return false
        }
    }

    /// Spec 02 §3 step 5 (`S/roster-cache.ts:35-72`): text fields that arrive as numbers/bools become strings,
    /// objects/arrays are dropped; a non-object `ui_meta` is dropped.
    static func cleanRow(_ row: JSONValue) -> JSONValue {
        guard var object = row.object else { return row }
        clean(&object, fields: ["name", "title", "display_name", "description", "connectionLabel"])
        if let ui = object["ui_meta"] {
            if var uiObject = ui.object {
                if let own = uiObject["hermes-bots"] {
                    if var meta = own.object {
                        clean(&meta, fields: ["title", "description", "color", "shape", "image"])
                        uiObject["hermes-bots"] = .object(meta)
                    } else if !own.isNull {
                        uiObject["hermes-bots"] = nil
                    }
                }
                object["ui_meta"] = .object(uiObject)
            } else {
                object["ui_meta"] = nil
            }
        }
        return .object(object)
    }

    private static func clean(_ record: inout [String: JSONValue], fields: [String]) {
        for field in fields {
            guard let value = record[field] else { continue }
            switch value {
            case .null, .string: continue
            case .number, .bool: record[field] = .string(text(value))
            case .array, .object: record[field] = nil
            }
        }
    }
}

// MARK: - Session references on a roster row

/// `canonical_session` / `last_session` / `worker_session` on a `profiles.list` row, or a `session.list` title-lookup
/// row (spec 02 §2.1, §2.5). Times are unix seconds.
nonisolated struct RosterSessionRef: Sendable, Hashable, Codable {
    var id: String                   // registry row (durable identity); may be "" on a malformed row
    var resolvedId: String?          // compression-lineage tip: the id to open
    var title: String?
    var rootTitle: String?
    var preview: String?
    var source: String?
    var startedAt: Double?
    var lastActive: Double?          // only a JSON number counts (unread tracker rule)
    var messageCount: Int?           // only a JSON number counts; includes tool rows
    var liveMessageCount: Int?

    init(id: String, resolvedId: String? = nil, title: String? = nil, rootTitle: String? = nil, preview: String? = nil,
         source: String? = nil, startedAt: Double? = nil, lastActive: Double? = nil, messageCount: Int? = nil,
         liveMessageCount: Int? = nil) {
        self.id = id; self.resolvedId = resolvedId; self.title = title; self.rootTitle = rootTitle
        self.preview = preview; self.source = source; self.startedAt = startedAt; self.lastActive = lastActive
        self.messageCount = messageCount; self.liveMessageCount = liveMessageCount
    }

    init?(json: JSONValue?) {
        guard let o = json?.object else { return nil }
        id = RosterText.text(o["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedId = RosterText.trimmed(o["resolved_id"])
        title = o["title"].flatMap { $0.isNull ? nil : RosterText.text($0) }
        rootTitle = RosterText.trimmed(o["root_title"])
        preview = o["preview"].flatMap { $0.isNull ? nil : RosterText.text($0) }
        source = RosterText.trimmed(o["source"])
        startedAt = RosterText.number(o["started_at"])
        lastActive = RosterText.number(o["last_active"])
        messageCount = RosterText.count(o["message_count"])
        liveMessageCount = RosterText.count(o["live_message_count"])
    }

    /// The id that opens: the lineage tip, else the registry id (`HB/row-helpers.ts:68-70`, `S/list-helpers.ts:62-69`).
    var openId: String { resolvedId ?? id }

    /// Both ids the chat goes by, deduped, blank ones dropped (`S/bot-unread-activity.ts:17`).
    var ids: [String] {
        var out: [String] = []
        for value in [id, resolvedId ?? ""] where !value.isEmpty && !out.contains(value) { out.append(value) }
        return out
    }

    /// `root_title || title === "Bot Chat"` (`HB/canonical-chat.ts:155-163`).
    var isBotChat: Bool {
        if let root = rootTitle { return root == RosterRules.botChatTitle }
        return title?.trimmingCharacters(in: .whitespacesAndNewlines) == RosterRules.botChatTitle
    }
}

// MARK: - Bot meta (ui_meta['hermes-bots'])

/// Where a pin moved a bot from (`pinnedFrom`, HQ only; `S/ui-bots/pinned-section-model.ts:7-22`).
nonisolated enum PinHome: Sendable, Hashable {
    case unrecorded                  // missing, false, or not a usable object: not in Pinned because of a pin
    case noSection                   // null: came from no section
    case section(id: String, name: String?)

    init(_ value: JSONValue?) {
        guard let value else { self = .unrecorded; return }
        if value.isNull { self = .noSection; return }
        guard let o = value.object, let id = o["id"]?.string, !id.isEmpty else { self = .unrecorded; return }
        self = .section(id: id, name: o["name"]?.string)
    }
}

/// The fields of `ui_meta['hermes-bots']` the Bots list reads (spec 02 §5.1). Built from the merged local snapshot.
nonisolated struct BotMeta: Sendable, Hashable {
    var title: String?
    var description: String?
    var pinned: Bool = false
    var hidden: Bool = false
    var sectionId: String?
    var sectionName: String?
    var pinnedFrom: PinHome = .unrecorded
    var created: Double?

    init() {}

    init(json: JSONValue?) {
        guard let o = json?.object else { return }
        title = RosterText.trimmed(o["title"])
        description = RosterText.trimmed(o["description"])
        pinned = RosterText.truthy(o["pinned"])
        hidden = RosterText.truthy(o["hidden"])
        sectionId = RosterText.truthy(o["sectionId"]) ? RosterText.nonBlank(RosterText.text(o["sectionId"])) : nil
        sectionName = RosterText.trimmed(o["sectionName"])
        pinnedFrom = PinHome(o["pinnedFrom"])
        created = RosterText.number(o["created"])
    }

    /// Display rule for a meta that a web device has not reconciled yet (`pinnedSectionPatch`, spec 02 §7.4): a bot
    /// filed in Pinned by hand (no recorded home) reads as pinned.
    var effectivePinned: Bool {
        pinned || (sectionId == RosterRules.pinnedSectionId && pinnedFrom == .unrecorded)
    }

    /// The user section the bot belongs to when it is not shown as pinned: an unpinned bot still in Pinned goes back
    /// to the home its pin recorded (nil = no section).
    var homeSectionId: String? {
        guard sectionId == RosterRules.pinnedSectionId else { return sectionId }
        if case .section(let id, _) = pinnedFrom { return id }
        return nil
    }
}

// MARK: - profiles.list row

/// One `profiles.list` row (spec 02 §2.1). `raw` is the text-cleaned row as received, kept for the disk cache and
/// the slim merge.
nonisolated struct RosterProfile: Sendable, Hashable {
    var name: String
    var isDefault: Bool
    var displayName: String?
    var description: String?
    var title: String?
    var model: String?
    var provider: String?
    var lastSession: RosterSessionRef?
    var workerSession: RosterSessionRef?
    var canonicalSession: RosterSessionRef?
    var uiMeta: [String: JSONValue]
    var hasAvatar: Bool
    var raw: JSONValue

    init?(json: JSONValue) {
        let row = RosterText.cleanRow(json)
        guard let o = row.object, let name = RosterText.trimmed(o["name"]) else { return nil }
        self.name = name
        isDefault = o["is_default"]?.bool ?? (name == "default")
        displayName = RosterText.trimmed(o["display_name"])
        description = RosterText.trimmed(o["description"])
        title = RosterText.trimmed(o["title"])
        model = RosterText.trimmed(o["model"])
        provider = RosterText.trimmed(o["provider"])
        lastSession = RosterSessionRef(json: o["last_session"])
        workerSession = RosterSessionRef(json: o["worker_session"])
        canonicalSession = RosterSessionRef(json: o["canonical_session"])
        uiMeta = o["ui_meta"]?.object ?? [:]
        hasAvatar = o["has_avatar"]?.bool ?? false
        raw = row
    }

    /// The server's own `ui_meta['hermes-bots']` object on this row, if any.
    var serverMeta: [String: JSONValue]? { uiMeta["hermes-bots"]?.object }
    /// The raw head record (spec 02 §10; drawn by the heads module).
    var head: JSONValue? { uiMeta["dispatch-head"].flatMap { $0.isNull ? nil : $0 } }
    /// The chat's ids (registry id and lineage tip).
    var canonicalIds: [String] { canonicalSession?.ids ?? [] }
    /// @handle: the primary profile is `hermes`, never `default` (`HB/data.ts:1011-1017`).
    var handle: String { RosterRules.handle(forProfile: name) }
}

/// A decoded `profiles.list` answer.
nonisolated struct RosterSnapshot: Sendable, Hashable {
    var profiles: [RosterProfile]
    var botModeProtocol: Bool?
    var installId: String?

    nonisolated enum DecodeError: Error, CustomStringConvertible {
        case notARoster
        var description: String { "The gateway's bot list was not readable." }
    }

    init(profiles: [RosterProfile], botModeProtocol: Bool? = nil, installId: String? = nil) {
        self.profiles = profiles; self.botModeProtocol = botModeProtocol; self.installId = installId
    }

    /// Decode a `profiles.list` result. Rows without a name are dropped; a duplicate name keeps its first row.
    static func decode(_ result: JSONValue) throws -> RosterSnapshot {
        guard let rows = result["profiles"]?.array else { throw DecodeError.notARoster }
        var seen = Set<String>()
        var profiles: [RosterProfile] = []
        for row in rows {
            guard let profile = RosterProfile(json: row), seen.insert(profile.name).inserted else { continue }
            profiles.append(profile)
        }
        return RosterSnapshot(profiles: profiles, botModeProtocol: result["bot_mode_protocol"]?.bool,
                              installId: result["install_id"]?.string)
    }

    /// The slim answer's rows, keeping each bot's last known session fields until the full answer lands
    /// (`S/roster-cache.ts:106-123`): a field the slim row lacks is copied from the previous row of that name.
    static func mergeSlim(_ slim: [JSONValue], over previous: [JSONValue]) -> [JSONValue] {
        var known: [String: [String: JSONValue]] = [:]
        for row in previous {
            if let o = row.object, let name = RosterText.trimmed(o["name"]), known[name] == nil { known[name] = o }
        }
        let fields = ["last_session", "worker_session", "canonical_session"]
        return slim.map { row in
            guard var o = row.object, let name = RosterText.trimmed(o["name"]), let before = known[name] else { return row }
            for field in fields where o[field] == nil { if let value = before[field] { o[field] = value } }
            return .object(o)
        }
    }
}

// MARK: - Local meta snapshot (spec 02 §5.2)

nonisolated enum BotMetaMerge {
    /// `HB/profile-ops.ts:233-300` without the write fence (native M1 never writes meta): for each row with a server
    /// `hermes-bots` object, `merged = {...local, ...server}`, local `image` kept, `chat` dropped, and a local `group`
    /// scalar dropped when the server has `groups` but no `group`. Rows without server meta keep the local meta.
    static func merge(local: [String: JSONValue], roster: [RosterProfile]) -> [String: JSONValue] {
        var next = local
        for profile in roster {
            guard let server = profile.serverMeta else { continue }
            let mine = next[profile.name]?.object ?? [:]
            var merged = mine.merging(server) { _, theirs in theirs }
            if let image = mine["image"], !image.isNull, RosterText.truthy(image) { merged["image"] = image }
            merged["chat"] = nil
            if server["groups"]?.array != nil, mine["group"] != nil, server["group"] == nil { merged["group"] = nil }
            next[profile.name] = .object(merged)
        }
        return next
    }
}
