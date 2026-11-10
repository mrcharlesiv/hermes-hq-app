// News on the gateways that aren't in use (spec 1x-settings §4.7): the bots a parked gateway's Bots list last saw (its
// roster cache and unread state on disk), and how many of them answered since. Ported from `S/gateway-switcher.ts`
// (parkedChats, unreadCount). Pure; `GatewaySwitcherModel` reads the files and the chats.

import Foundation

/// One bot's chat on a gateway that isn't in use, as this phone last saw it there.
nonisolated struct ParkedChat: Sendable, Hashable {
    /// The activity owner: the profile name (native baselines are keyed by profile).
    var owner: String
    /// The id to read (`resolved_id || id`).
    var id: String
    var ids: [String]
    /// The routing profile (`nil` for `default`).
    var profile: String?
    var baseline: Double?
    var marked: Bool
}

/// What `GET /api/sessions/<id>` answered for one parked chat.
nonisolated struct ParkedChatLive: Sendable, Hashable {
    var id: String
    var lastActive: Double?
    var messageCount: Int?

    init(id: String, lastActive: Double?, messageCount: Int?) {
        self.id = id; self.lastActive = lastActive; self.messageCount = messageCount
    }

    /// `id` is the id the read asked for, never the answer's own (`GET /api/sessions/{id}` resolves prefixes and
    /// lineage, so the row it returns can carry another id; the web keys rows by the requested id too).
    init?(json: JSONValue, id: String) {
        guard json.object != nil else { return nil }
        self.id = id
        lastActive = RosterText.number(json["last_active"])
        messageCount = RosterText.count(json["message_count"])
    }
}

nonisolated enum GatewayNews {
    static let maxChats = 40

    /// `parkedChats`: the last full roster's bots with a chat, without hidden bots or empty chats, each with this phone's
    /// baseline and marker for it. At most 40.
    static func parkedChats(roster: [JSONValue], state: BotDeviceState?) -> [ParkedChat] {
        let baselines = state?.unread.baselines ?? [:]
        let markers = state?.unread.markers ?? [:]
        var chats: [ParkedChat] = []
        for raw in roster {
            guard let row = raw.object, let name = RosterText.trimmed(row["name"]) else { continue }
            let meta = row["ui_meta"]?["hermes-bots"]?.object ?? state?.meta[name]?.object
            if meta?["hidden"] == .bool(true) { continue }
            let canonical = row["canonical_session"]?.object
            if case .number(let count)? = canonical?["message_count"], count == 0 { continue }
            guard let session = RosterSessionRef(json: row["canonical_session"]) else { continue }
            let id = session.resolvedId ?? session.id
            guard !id.isEmpty else { continue }
            let bucket = markers[name] ?? []
            chats.append(ParkedChat(owner: name, id: id, ids: session.ids, profile: name == "default" ? nil : name,
                                    baseline: baselines[name], marked: session.ids.contains { bucket.contains($0) }))
            if chats.count >= maxChats { break }
        }
        return chats
    }

    /// `unreadCount`: chats still marked unread, or answered since this phone last saw them (no baseline: not news).
    static func unreadCount(_ chats: [ParkedChat], live: [ParkedChatLive]) -> Int {
        let now = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return chats.filter { chat in
            if chat.marked { return true }
            guard let answer = now[chat.id], let last = answer.lastActive, let baseline = chat.baseline else { return false }
            return last > baseline && answer.messageCount != 0
        }.count
    }

    /// A stored session id the REST route accepts (spec 01 §7.4).
    static let sessionIdPattern = JSRegex(#"^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$"#)

    /// "1 New" … "9 New", "9+ New" above nine.
    static func newsLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 9 ? "9+ New" : "\(count) New"
    }

    /// [botslist] What VoiceOver says for the gateway switcher under a page's title (`S/gateway-title.tsx:39-43`, parity
    /// §2 L128): the page, the gateway in use, and news elsewhere, as one line — "Bots, on Studio, 2 new on other
    /// gateways". While a switch runs: "Bots, switching to Beta". With the link down: "Bots, on Studio, offline".
    /// `page` is nil where the page's own title is already read just before the switcher (the system's large title is
    /// its own element on iOS), so the name is never read twice.
    static func switcherLabel(page: String?, gateway: String, switchingTo: String?, link: String?, otherNews: Int) -> String {
        var parts: [String] = []
        if let page, !page.isEmpty { parts.append(page) }
        if let switchingTo, !switchingTo.isEmpty {
            parts.append("switching to \(switchingTo)")
            return sentence(parts)
        }
        if !gateway.isEmpty { parts.append("on \(gateway)") }
        if let link = link?.trimmingCharacters(in: CharacterSet(charactersIn: "… .")), !link.isEmpty { parts.append(link.lowercased()) }
        if otherNews > 9 { parts.append("more than 9 new on other gateways") }
        else if otherNews > 0 { parts.append("\(otherNews) new on other gateways") }
        return sentence(parts)
    }

    private static func sentence(_ parts: [String]) -> String {
        let line = parts.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
