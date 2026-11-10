// Watch Browser's wire (gateway plugin hermes-hq-browser, protocol 3; port of the web app's src/browser-watch/model.ts).
// Pure values and parsing: no UI, no sockets. Text JSON both ways; a frame is a JPEG data URL inside a `frame` message.
// Nothing here logs: page text, typed text and addresses never reach the diagnostic log.

import Foundation
import CoreGraphics

nonisolated enum BrowserWire {
    static let plugin = "/api/plugins/hermes-hq-browser"
    /// The same plugin under its name before Hermes HQ (dispatch-browser 3.3 and earlier): same protocol, older routes.
    static let legacyPlugin = "/api/plugins/dispatch-browser"
    static let protocolVersion = 3
    static let maxFrameImage = 4 * 1024 * 1024
    static let maxMessage = maxFrameImage + 4096
    /// A frame is acknowledged at most this often once drawn (the plugin sends one per ack): 30 a second. The web app
    /// paced at 50 ms because it decoded on the main thread; here decoding is off it.
    static let frameInterval: Duration = .milliseconds(33)
    /// A bot's own Chrome counts as in use this long after its last browser tool.
    static let activeFor: TimeInterval = 90

    static func isBrowserId(_ id: String) -> Bool {
        id.count == 24 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func watchPath(_ id: String, base: String = plugin) -> String? {
        isBrowserId(id) ? "\(base)/sessions/\(id)/watch" : nil
    }

    /// `ws(s)://<host>/<prefix>/api/plugins/…?profile=<p>&ticket=<t>` for a plugin socket: the gateway's own scheme
    /// (wss iff https), its path prefix kept, the ticket last (the native shell mints one per socket, as for /api/ws).
    static func socketURL(base: URL, path: String, query: [URLQueryItem], ticket: String) -> URL? {
        guard path.hasPrefix(plugin + "/") || path.hasPrefix(legacyPlugin + "/"), !path.contains("?"), !path.contains("#"),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.scheme?.lowercased() {
        case "https": parts.scheme = "wss"
        case "http": parts.scheme = "ws"
        default: return nil
        }
        let prefix = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = prefix + path
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        parts.queryItems = query.filter { $0.name != "ticket" && $0.name != "token" } + [URLQueryItem(name: "ticket", value: ticket)]
        return parts.url
    }

    /// The viewer's identity: one per phone, so a phone that left (or relaunched) finds a browser it still holds.
    static func viewerId(defaults: UserDefaults = .standard) -> String {
        let key = "hq.browser.viewer"
        if let saved = defaults.string(forKey: key), saved.count == 32, saved.allSatisfy(\.isHexDigit) { return saved }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let made = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(made, forKey: key)
        return made
    }
}

// MARK: - Rows (the activity list)

nonisolated enum BrowserControl: String, Sendable, Hashable { case bot, waiting, person }

/// One bot browser as the gateway lists it.
nonisolated struct BrowserRow: Sendable, Hashable, Identifiable {
    var id: String
    var profile: String
    var sessionId: String
    var sessionIds: [String]
    var url: String?
    var busy: Int
    var control: BrowserControl
    var ask: String?
    var agentAt: Double
    var active: Bool

    init(id: String, profile: String, sessionId: String = "", sessionIds: [String] = [], url: String? = nil, busy: Int = 0,
         control: BrowserControl = .bot, ask: String? = nil, agentAt: Double = 0, active: Bool = false) {
        self.id = id; self.profile = profile; self.sessionId = sessionId; self.sessionIds = sessionIds; self.url = url
        self.busy = busy; self.control = control; self.ask = ask; self.agentAt = agentAt; self.active = active
    }

    static func parse(_ value: JSONValue, now: Date = Date()) -> BrowserRow? {
        guard let id = value["id"]?.string, BrowserWire.isBrowserId(id),
              let profile = value["profile"]?.string, !profile.isEmpty else { return nil }
        let ids = (value["session_ids"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty && $0.count <= 512 }.suffix(16)
        let control = value["control"]?.string.flatMap(BrowserControl.init(rawValue:)) ?? .bot
        let busy = value["busy"]?.double.map { $0 > 0 ? Int($0.rounded(.down)) : 0 } ?? 0
        let agentAt = value["agent_at"]?.double.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let ask = value["ask"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        var row = BrowserRow(id: id, profile: String(profile.prefix(128)), sessionId: String((value["session_id"]?.string ?? "").prefix(512)),
                             sessionIds: Array(ids), url: value["url"]?.string.map { String($0.prefix(4096)) }, busy: busy,
                             control: control, ask: ask.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }, agentAt: agentAt)
        row.active = value["active"]?.bool ?? (busy > 0 || (agentAt > 0 && now.timeIntervalSince1970 - agentAt < BrowserWire.activeFor))
        return row
    }

    /// `dispatch-browser.list.v3` (the plugin kept its wire names under the new name).
    static func parseList(_ value: JSONValue) -> [BrowserRow]? {
        guard value["schema"]?.string == "dispatch-browser.list.v3", let list = value["browsers"]?.array else { return nil }
        return list.prefix(64).compactMap { parse($0) }
    }

    /// A bot using it, asking for the person, or the person holding it: news. An idle bot Chrome shows nothing.
    var inUse: Bool { active || ask != nil || control != .bot }
}

/// Which browser a chat or a bot shows.
nonisolated struct BrowserScope: Sendable, Hashable {
    /// The bot (Hermes profile).
    var profile: String
    /// A bot's own chat shows any browser of that bot; another chat only its own (by session id).
    var sessionIds: [String] = []
    /// The bot's display name.
    var title: String
    /// Another chat of the bot (not its own chat): only a browser of this chat's sessions, none while it has no ids yet.
    var chatOnly = false

    /// This bot's browser: its profile's, and when the scope names chats, one of theirs. Newest bot use first.
    func row(in rows: [BrowserRow]) -> BrowserRow? {
        let ids = Set(sessionIds.filter { !$0.isEmpty })
        if chatOnly && ids.isEmpty { return nil }
        return rows.sorted { $0.agentAt > $1.agentAt }.first { row in
            row.profile == profile && (ids.isEmpty || ids.contains(row.sessionId) || row.sessionIds.contains(where: ids.contains))
        }
    }
}

nonisolated enum BrowserCard {
    /// The browser the chat's card shows: one in use, or, while the chat's turn still runs, the one it already shows (a
    /// bot between browser calls is still browsing for this turn; the 90 s window running out must not drop the card).
    static func row(_ row: BrowserRow?, showing: BrowserRow?, turnRunning: Bool) -> BrowserRow? {
        if let row, row.inUse { return row }
        guard turnRunning, let showing, row == nil || row?.id == showing.id else { return nil }
        var kept = row ?? showing
        kept.active = true
        return kept
    }

    /// The card's words (the shelf chip).
    static func words(_ row: BrowserRow, name: String) -> String {
        if row.ask != nil && row.control == .bot { return "\(name) needs you in its browser" }
        switch row.control {
        case .person: return "You’re using \(name)’s browser"
        case .waiting: return "Handing you the browser…"
        case .bot:
            let host = BrowserAddress(row.url).host
            return !host.isEmpty && host != "New Tab" ? "Browsing \(host)" : "Using its browser"
        }
    }

    /// The browser a Bots row speaks for (like the bot's face, R:0b15f4d): one its own Bot Chat uses, or one that needs
    /// the person (asking, handed over, held) whichever chat it is in. A scheduled job or side chat that browses says so
    /// in its own chat, not on the bot. `ownChats` nil (roster not known yet): any of the bot's browsers.
    static func botRow(_ rows: [BrowserRow], profile: String, ownChats: Set<String>?) -> BrowserRow? {
        rows.sorted { $0.agentAt > $1.agentAt }.first { row in
            guard row.profile == profile else { return false }
            if row.ask != nil || row.control != .bot { return true }
            guard let ownChats else { return true }
            let chat = row.sessionId.isEmpty ? (row.sessionIds.last ?? "") : row.sessionId
            return ownChats.contains(chat)
        }
    }

    /// One line for a Bots row (nil when the browser is not news).
    static func statusLine(_ row: BrowserRow?) -> String? {
        guard let row, row.inUse else { return nil }
        if row.ask != nil && row.control == .bot { return "Needs you in its browser" }
        if row.control == .person { return "You’re using its browser" }
        if row.control == .waiting { return "Handing you its browser…" }
        guard let host = webHost(row.url ?? "") else { return "Using its browser" }
        return "Browsing \(host)"
    }

    /// The site a web address names, as the row says it ("example.com"). Nil for anything that is not a web page
    /// with a host (an empty tab, `javascript:…`, a local page, words that are no address): the row then says
    /// "Using its browser" rather than repeating a raw string.
    static func webHost(_ url: String) -> String? {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let named = parts.host, !named.isEmpty else { return nil }
        let host = BrowserAddress(url).host
        return host.isEmpty || host == "New Tab" ? nil : host
    }
}

// MARK: - The watch socket's messages

nonisolated struct BrowserTab: Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var url: String
}

nonisolated struct BrowserControlState: Sendable, Hashable {
    var state: BrowserControl
    var mine: Bool
    var epoch: Int?
}

/// A text field in the page (plugin 3.4.4+).
nonisolated enum BrowserFieldKind: String, Sendable, Hashable, CaseIterable {
    case password, username, code, email, tel, url, number, search, text, multiline
}

nonisolated struct BrowserPageFields: Sendable, Hashable {
    var under: BrowserFieldKind?
    var focus: BrowserFieldKind?
}

/// Something the watched page has open that Chrome draws outside the page, so no frame shows it (plugin 3.7.0+): the
/// page's own alert boxes (the page is stopped until one is answered), or a "Sign in with…" account chooser.
nonisolated struct BrowserPageDialog: Sendable, Hashable {
    nonisolated enum Kind: String, Sendable, Hashable {
        case alert, confirm, prompt, leave, accounts, signin
        case signinError = "signin_error"
    }
    nonisolated struct Account: Sendable, Hashable {
        var name: String
        var email: String
    }
    var id: Int
    var kind: Kind
    var site: String?
    var message: String
    var defaultText: String?
    var title: String?
    var accounts: [Account]
}

nonisolated struct BrowserViewState: Sendable, Hashable {
    var tabs: [BrowserTab]
    var tab: String?
    var follow: Bool
    var control: BrowserControlState
    var ask: String?
    var field: BrowserPageFields?
    var dialog: BrowserPageDialog? = nil

    var currentTab: BrowserTab? { tabs.first { $0.id == tab } }
}

/// A frame as the socket carried it: the page's CSS size it shows and the JPEG bytes (not yet decoded).
nonisolated struct BrowserFrame: Sendable {
    var seq: Int
    var tab: String?
    var epoch: Int?
    var width: Double
    var height: Double
    var jpeg: Data
}

nonisolated enum BrowserServerMessage: Sendable {
    case state(BrowserViewState)
    case frame(BrowserFrame)
    case ended(String)
    case error(String)
    case ping
    case copied(String)

    private static let jpegHead = "data:image/jpeg;base64,/9j/"

    /// Parses one text message (off the main thread: a frame is up to 4 MB of base64). nil for anything malformed.
    static func parse(_ data: Data) -> BrowserServerMessage? {
        guard data.count <= BrowserWire.maxMessage,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        func text(_ key: String, _ max: Int) -> String? { (object[key] as? String).map { String($0.prefix(max)) } }
        switch type {
        case "ping": return .ping
        case "ended": return .ended(text("reason", 32).flatMap { $0.isEmpty ? nil : $0 } ?? "closed")
        case "error": return .error(text("message", 300).flatMap { $0.isEmpty ? nil : $0 } ?? "The browser didn’t take that.")
        case "copied": return .copied(text("text", 65536) ?? "")
        case "state": return parseState(object).map(BrowserServerMessage.state)
        case "frame": return parseFrame(object).map(BrowserServerMessage.frame)
        default: return nil
        }
    }

    static func parseState(_ object: [String: Any]) -> BrowserViewState? {
        guard let tabs = object["tabs"] as? [Any], let control = object["control"] as? [String: Any],
              let state = (control["state"] as? String).flatMap(BrowserControl.init(rawValue:)) else { return nil }
        let parsedTabs: [BrowserTab] = tabs.prefix(64).compactMap { value in
            guard let tab = value as? [String: Any], let id = tab["id"] as? String, !id.isEmpty, id.count <= 256 else { return nil }
            return BrowserTab(id: id, title: String((tab["title"] as? String ?? "").prefix(300)), url: String((tab["url"] as? String ?? "").prefix(4096)))
        }
        let ask = (object["ask"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var field: BrowserPageFields?
        if let f = object["field"] as? [String: Any] {
            field = BrowserPageFields(under: (f["under"] as? String).flatMap(BrowserFieldKind.init(rawValue:)),
                                      focus: (f["focus"] as? String).flatMap(BrowserFieldKind.init(rawValue:)))
        }
        return BrowserViewState(tabs: parsedTabs, tab: object["tab"] as? String, follow: (object["follow"] as? Bool) != false,
                                control: BrowserControlState(state: state, mine: (control["mine"] as? Bool) == true,
                                                             epoch: (control["epoch"] as? NSNumber).flatMap(intValue)),
                                ask: ask.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }, field: field,
                                dialog: (object["dialog"] as? [String: Any]).flatMap(parseDialog))
    }

    static func parseDialog(_ d: [String: Any]) -> BrowserPageDialog? {
        guard let id = (d["id"] as? NSNumber).flatMap(intValue),
              let kind = (d["kind"] as? String).flatMap(BrowserPageDialog.Kind.init(rawValue:)) else { return nil }
        func text(_ key: String, _ limit: Int) -> String? {
            (d[key] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let accounts: [BrowserPageDialog.Account] = ((d["accounts"] as? [Any]) ?? []).prefix(20).compactMap { value in
            guard let a = value as? [String: Any] else { return nil }
            let name = String((a["name"] as? String ?? "").prefix(200)), email = String((a["email"] as? String ?? "").prefix(200))
            return name.isEmpty && email.isEmpty ? nil : BrowserPageDialog.Account(name: name, email: email)
        }
        if kind == .accounts && accounts.isEmpty { return nil }
        return BrowserPageDialog(id: id, kind: kind, site: text("site", 253), message: text("message", 2000) ?? "",
                                 defaultText: kind == .prompt ? (d["default"] as? String).map { String($0.prefix(2000)) } : nil,
                                 title: text("title", 300), accounts: accounts)
    }

    private static func intValue(_ n: NSNumber) -> Int? {
        let d = n.doubleValue
        return d.isFinite && abs(d) < 9e15 ? Int(d) : nil
    }

    static func parseFrame(_ object: [String: Any]) -> BrowserFrame? {
        guard let seqNumber = object["seq"] as? NSNumber, let seq = intValue(seqNumber), seq >= 1,
              let width = (object["width"] as? NSNumber)?.doubleValue, width > 0, width <= 8192,
              let height = (object["height"] as? NSNumber)?.doubleValue, height > 0, height <= 8192,
              let image = object["image"] as? String, image.utf8.count <= BrowserWire.maxFrameImage,
              image.hasPrefix(jpegHead) else { return nil }
        let base64 = image.dropFirst("data:image/jpeg;base64,".count)
        guard let jpeg = Data(base64Encoded: String(base64)), jpeg.count > 4 else { return nil }
        return BrowserFrame(seq: seq, tab: object["tab"] as? String, epoch: (object["epoch"] as? NSNumber).flatMap(intValue),
                            width: width, height: height, jpeg: jpeg)
    }
}

/// What the phone sends.
nonisolated enum BrowserClientMessage: Sendable, Equatable {
    case hello(viewer: String)
    case view(width: Int, height: Int, scale: Double)
    case ack(seq: Int)
    case pong
    case take, give, follow
    case tab(String)
    /// Input while the phone holds the browser (`epoch` added when sent).
    case input(BrowserInput)

    func json(epoch: Int? = nil) -> Data {
        var object: [String: Any]
        switch self {
        case .hello(let viewer): object = ["type": "hello", "viewer": viewer]
        case .view(let w, let h, let s): object = ["type": "view", "width": w, "height": h, "scale": s]
        case .ack(let seq): object = ["type": "ack", "seq": seq]
        case .pong: object = ["type": "pong"]
        case .take: object = ["type": "take"]
        case .give: object = ["type": "give"]
        case .follow: object = ["type": "follow"]
        case .tab(let id): object = ["type": "tab", "id": id]
        case .input(let input):
            object = input.object
            if let epoch { object["epoch"] = epoch }
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

nonisolated enum BrowserInput: Sendable, Equatable {
    case move(x: Double, y: Double)
    case tap(x: Double, y: Double)
    case down(x: Double, y: Double)
    case up(x: Double, y: Double)
    case scroll(x: Double, y: Double, dx: Int, dy: Int)
    case text(String)
    case key(String)
    case go(String)
    case nav(String)        // back, forward, reload
    case copy
    case selectAll
    /// The person's answer to the page's open `BrowserPageDialog`: OK/Cancel, a prompt's text, the account picked.
    case answer(id: Int, accept: Bool, text: String? = nil, account: Int? = nil)

    /// Typing (kept while the socket reconnects, in order); a tap or a scroll at a stale spot is not worth replaying.
    var isTyping: Bool {
        switch self { case .text, .key: return true; default: return false }
    }

    var object: [String: Any] {
        func point(_ type: String, _ x: Double, _ y: Double) -> [String: Any] { ["type": type, "x": round4(x), "y": round4(y)] }
        switch self {
        case .move(let x, let y): return point("move", x, y)
        case .tap(let x, let y): return point("tap", x, y)
        case .down(let x, let y): return point("down", x, y)
        case .up(let x, let y): return point("up", x, y)
        case .scroll(let x, let y, let dx, let dy): return point("scroll", x, y).merging(["dx": dx, "dy": dy]) { $1 }
        case .text(let text): return ["type": "text", "text": text]
        case .key(let key): return ["type": "key", "key": key]
        case .go(let url): return ["type": "go", "url": url]
        case .nav(let action): return ["type": "nav", "action": action]
        case .copy: return ["type": "copy"]
        case .selectAll: return ["type": "select_all"]
        case .answer(let id, let accept, let text, let account):
            var object: [String: Any] = ["type": "answer", "id": id, "accept": accept]
            if let text { object["text"] = text }
            if let account { object["account"] = account }
            return object
        }
    }

    private func round4(_ v: Double) -> Double { (min(1, max(0, v)) * 10_000).rounded() / 10_000 }
}

// MARK: - Helpers

/// The phone's own field for typing into a page field of this kind: a sign-in field gets one iOS offers password
/// AutoFill on (Passwords, 1Password…), a code field gets codes from Messages and Mail; anything else the plain field.
nonisolated enum BrowserKeyboardSlot: String, Sendable, Hashable, CaseIterable { case text, username, password, code }

nonisolated enum BrowserKeyboardKind: Sendable, Hashable { case text, email, tel, url, decimal, search }

nonisolated enum BrowserKeyboard {
    static func slot(for kind: BrowserFieldKind?) -> (slot: BrowserKeyboardSlot, keyboard: BrowserKeyboardKind) {
        switch kind {
        case .password: return (.password, .text)
        case .username: return (.username, .text)
        case .email: return (.username, .email)     // most email fields a person takes over for are sign-ins
        case .code: return (.code, .text)           // codes can have letters
        case .tel: return (.text, .tel)
        case .url: return (.text, .url)
        case .number: return (.text, .decimal)
        case .search: return (.text, .search)
        default: return (.text, .text)
        }
    }

    /// Clipboard text as `text` messages the plugin takes (at most 8 KB a message), at most 50 of them.
    /// Counted in Unicode scalars (Python's code points: the plugin refuses a `text` over 4096 of them), never splitting
    /// a character (an emoji with its modifiers stays in one chunk).
    static func pasteChunks(_ text: String, size: Int = 2000) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var chunks: [String] = []
        var current = "", scalars = 0
        for character in normalized {
            let count = character.unicodeScalars.count
            if scalars + count > size, !current.isEmpty {
                chunks.append(current)
                if chunks.count == 50 { return chunks }
                current = ""
                scalars = 0
            }
            current.append(character)
            scalars += count
        }
        if !current.isEmpty && chunks.count < 50 { chunks.append(current) }
        return chunks
    }
}

/// What a page address shows.
nonisolated struct BrowserAddress: Sendable, Equatable {
    var host: String
    var secure: Bool

    init(_ url: String?) {
        guard let url, !url.isEmpty else { host = ""; secure = false; return }
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased() else {
            host = String(url.prefix(80)); secure = false; return
        }
        switch scheme {
        case "data", "blob": host = "Local page"; secure = false
        case "about": host = url == "about:blank" ? "New Tab" : String(url.prefix(80)); secure = false
        default:
            var h = parts.host ?? ""
            if h.hasPrefix("www.") { h.removeFirst(4) }
            if let port = parts.port { h += ":\(port)" }
            host = h.isEmpty ? String(url.prefix(80)) : h
            secure = scheme == "https"
        }
    }

    /// What a typed address means: a URL as is, a bare host as https, anything else a web search.
    static func url(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil { return String(value.prefix(2048)) }
        if value.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return String("https://\(value)".prefix(2048))
        }
        let query = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return String("https://duckduckgo.com/?q=\(query)".prefix(2048))
    }

    /// An empty tab (nothing to show).
    static func isBlank(_ url: String) -> Bool { url.isEmpty || url == "about:blank" || url.hasPrefix("chrome://newtab") }
}

/// What the gateway's plugin can do: watch and take over (protocol 3), an older plugin that needs replacing, none, or
/// a current one that switched itself off because Hermes changed under it (`drift`: reinstalling it can't help).
nonisolated enum BrowserSetup: String, Sendable { case ready, missing, update, drift }

nonisolated enum BrowserHealth {
    static func setup(_ health: JSONValue) -> BrowserSetup {
        let current = health["protocol"]?.int == BrowserWire.protocolVersion
        if health["installed"]?.bool == true { return current && health["features"]?["control"]?.bool == true ? .ready : .update }
        // Tester report 2026-11-05: 3.7.0 on Hermes 0.22.6+ answers installed false with a drift list (Hermes removed
        // internals it reads). A missing package (`missing`, e.g. websockets) is still something an install fixes.
        if current, !hasMissing(health), !(health["drift"]?.array ?? []).isEmpty { return .drift }
        return health["protocol"]?.double != nil ? .update : .missing
    }

    private static func hasMissing(_ health: JSONValue) -> Bool {
        switch health["missing"] {
        case .none, .null?: return false
        case .string(let words)?: return !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let list)?: return !list.isEmpty
        default: return true
        }
    }

    /// The add-on's own words for what Hermes changed: trimmed, joined and capped (nil when it gave none as text).
    /// Mac polish #145: without the Python error's name it appends in brackets ("browser tools unavailable
    /// (ImportError)"), which says nothing to a person; the add-on's /health still has it.
    static func driftWords(_ health: JSONValue, limit: Int = 240) -> String? {
        let items = (health["drift"]?.array ?? []).compactMap { item -> String? in
            let said = item.string ?? ""
            let words = errorName.stringByReplacingMatches(in: said, range: NSRange(said.startIndex..., in: said), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : words
        }
        var joined = items.joined(separator: "; ")
        while joined.hasSuffix(".") { joined.removeLast() }   // the sentence it goes in adds its own
        if joined.count > limit { joined = String(joined.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" }
        return joined.isEmpty ? nil : joined
    }

    /// A Python error's name in brackets: "(ImportError)", "(ModuleNotFoundError: …)", "(requests.exceptions.Timeout…)".
    private static let errorName = try! NSRegularExpression(pattern: #"\s*\((?:[A-Za-z_][\w.]*)?(?:Error|Exception|Warning)\b[^()]*\)"#)

    /// Plugin 3.6+: a bot's browser can be switched to a copy of the person's Chrome profile and a normal window.
    static func offersChoice(_ health: JSONValue) -> Bool { health["features"]?["choice"]?.bool == true }

    /// Plugin 3.7+: the page's popups and boxes reach the phone (`dialog` in the state, `answer` from the phone).
    static func relaysPopups(_ health: JSONValue) -> Bool { health["features"]?["dialogs"]?.bool == true }

    /// Where the add-on version last offered an update for popups is kept (offered once per version).
    static let popupsOfferKey = "browser.popupsUpdateOffered"

    /// The version to offer an update for: a working add-on that can't send popups, not offered already. Else nil.
    static func popupsUpdate(_ health: JSONValue, offered: String?) -> String? {
        guard setup(health) == .ready, !relaysPopups(health) else { return nil }
        let version = String((health["version"]?.string ?? "older").prefix(40))
        return version == offered ? nil : version
    }
}

/// [browser-update] Owner 2026-11-05: "Can we make it something that they can update in the exact same like user
/// experience as they update our other plugin?" The browser add-on (hermes-hq-browser) is updated by the notification
/// add-on's update sheet (App/Notifications/AddOnUpdate.swift): the same reminder, row, steps and endings, one restart
/// for both. This build wants 3.8.1: 3.8.0 was the first that works on Hermes 0.22.6+ (3.7.0 switches itself off there:
/// `drift`), and 3.8.1 makes the chat's "Browsing …" chip name the page the bot is on (tester 2026-11-07: it
/// said site-a.example, a scheduled job's tab, while Watch Browser showed site-b.example).
nonisolated enum BrowserAddOn {
    static let wantedVersion = "3.8.1"

    /// Why an installed browser add-on needs the update.
    enum Need: String, Codable, Sendable, Equatable {
        /// Older than `wantedVersion` and still working.
        case outdated
        /// Older than `wantedVersion` and switched off because Hermes changed under it (the update turns it back on).
        case off
    }

    /// What the add-on's /health says about updating it. Nil when there is nothing an update can do: current already,
    /// not this add-on's protocol (an older test plugin keeps Watch Browser's own "Update Browser Watching" page, whose
    /// request also cleans up after it), or current and off all the same (a newer Hermes changed something again).
    static func need(_ health: JSONValue) -> Need? {
        guard health["protocol"]?.int == BrowserWire.protocolVersion else { return nil }
        guard !PushPolicy.versionAtLeast(version(health), wantedVersion) else { return nil }
        return BrowserHealth.setup(health) == .drift ? .off : .outdated
    }

    /// The version /health gives ("" when it gives none: older than any version asked for).
    static func version(_ health: JSONValue) -> String {
        String((health["version"]?.string ?? "").trimmingCharacters(in: .whitespaces).prefix(40))
    }

    /// The update is on (the sheet's last step): this version or newer, installed, nothing missing and no drift.
    static func isOn(_ health: JSONValue) -> Bool {
        PushPolicy.versionAtLeast(version(health), wantedVersion) && health["installed"]?.bool == true
            && (health["drift"]?.array ?? []).isEmpty
    }

    /// Hermes restarted onto the new add-on: its /health answers at `wantedVersion` or newer.
    static func restarted(_ health: JSONValue) -> Bool { PushPolicy.versionAtLeast(version(health), wantedVersion) }
}

/// A bot's own Chrome as `/bots` lists it (plugin 3.3+).
nonisolated struct OwnBrowser: Sendable, Equatable {
    var status: String
    var error: String?

    static func parse(_ value: JSONValue, profile: String) -> OwnBrowser? {
        guard value["schema"]?.string == "dispatch-browser.bots.v1", let bots = value["bots"]?.array else { return nil }
        let bot = bots.first { $0["profile"]?.string == profile }
        return OwnBrowser(status: String((bot?["status"]?.string ?? "unknown").prefix(40)),
                          error: bot?["error"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) })
    }
}

/// What the viewer says while a bot has no browser to show.
nonisolated struct BrowserEmptyCopy: Sendable, Equatable {
    var title: String
    var body: String
    var waiting = false
    /// The next step the viewer offers as a button, when there is one the app can take.
    var action: Action?

    enum Action: Sendable, Equatable {
        /// The add-on is switched off for the bot: its Plugins list, where it's turned back on.
        case plugins
        /// [browser-update] An add-on update fixes it: the add-on update sheet (Settings' Update, the same steps).
        case update
    }

    /// `own`: nil = an older plugin; `.none` (outer) = not known yet.
    static func noBrowser(_ own: OwnBrowser??, name: String) -> BrowserEmptyCopy {
        let status: String
        switch own {
        case .none: status = "loading"
        case .some(.none): status = "older"
        case .some(.some(let o)): status = o.status
        }
        let error: String? = { if case .some(.some(let o)) = own { return o.error }; return nil }()
        switch status {
        case "ready", "starting", "external", "unknown", "loading":
            return .init(title: "Opening \(name)’s Browser", body: "It shows here in a moment.", waiting: true)
        case "not_responding":
            return .init(title: "\(name)’s Browser Isn’t Responding", body: "It restarts on its own within a minute.", waiting: true)
        case "no_chrome":
            // UX study #140: the plain next step is where to get it, on that computer (no button: nothing on this device
            // can install it, and nobody has confirmed a bot can).
            return .init(title: "Chrome Isn’t Installed", body: "\(name) needs Google Chrome on \(HostWord.phrase) for a browser you can watch. On that computer, download it from google.com/chrome; once it’s installed, \(name)’s browser starts by itself.")
        case "port_taken", "no_port":
            // [ux] Plain words first; the plugin's own detail (which port) under them.
            let lead = "Another app on \(HostWord.phrase) is using what \(name)’s browser needs. Once it’s free, the browser starts by itself."
            return .init(title: "\(name)’s Browser Can’t Start", body: error.map { "\(lead)\n\n\($0)" } ?? lead)
        case "config_error":
            return .init(title: "\(name)’s Browser Can’t Start", body: "\(name)’s settings file on \(HostWord.phrase) has a mistake in it. Once it’s fixed, the browser starts by itself.")
        case "camofox":
            return .init(title: "Browser Can’t Be Shown", body: "\(name) uses Camofox, a browser Hermes HQ can’t show.")
        case "remote", "fixed":
            return .init(title: "Browser Can’t Be Shown", body: "\(name) is connected to a browser Hermes HQ can’t reach.")
        case "real_profile":
            return .init(title: "No Browser Open", body: "\(name) browses with a copy of your browser profile that Hermes opens for each task. When it opens a page, you’ll see it here.")
        case "released":
            return .init(title: "No Browser of Its Own", body: "\(name)’s browser was set up by hand, so Hermes HQ leaves it alone. When it opens a page Hermes HQ can show, you’ll see it here.")
        case "off":
            return .init(title: "Browser Watching Is Off", body: "The browser add-on is turned off in \(name)’s plugins. Turn it on there to watch \(name)’s browser here.",
                         action: .plugins)
        case "older":
            return .init(title: "No Browser Open", body: "When \(name) opens a web page, you’ll see it here live. Update the browser add-on and every bot keeps a browser of its own, ready to watch any time.")
        default:
            return .init(title: "No Browser Open", body: "When \(name) opens a web page, you’ll see it here live.")
        }
    }
}

extension BrowserEmptyCopy {
    /// [drift] The add-on switched itself off: Hermes changed something it needs. Its own words, then what fixes it.
    /// [browser-update] Older than 3.8.0 (3.7.0 on Hermes 0.22.6+): the update does, with a button that starts it. The
    /// line said "an add-on update for this Hermes is on the way" until 3.8.0 was out. Current and off all the same:
    /// no button, since reinstalling brings back the same version.
    static func addOnOff(_ health: JSONValue) -> BrowserEmptyCopy {
        let lead = "This version of Hermes changed something the browser add\u{2011}on needs"
        let what = BrowserHealth.driftWords(health).map { "\(lead): \($0)." } ?? "\(lead)."
        guard BrowserAddOn.need(health) == .off else {
            return .init(title: "Browser Add\u{2011}on Is Off",
                         body: "\(what) Reinstalling won’t help \u{2014} an add\u{2011}on update for this Hermes is on the way.")
        }
        return .init(title: "Browser Add\u{2011}on Is Off",
                     body: "\(what) Add\u{2011}on \(BrowserAddOn.wantedVersion) fixes this. Update it to watch your bots’ browsers again.",
                     action: .update)
    }

    /// [browser-update] The Off screen's button.
    static let updateButton = "Update the Add\u{2011}on"
}

/// Typing the person entered while the watch socket was away, in order, sent once it is back.
nonisolated struct PendingTyping: Sendable {
    enum Kept: Equatable { case first, kept, full, ignored }
    private(set) var items: [BrowserInput] = []
    let limit: Int

    init(limit: Int = 400) { self.limit = limit }

    var isEmpty: Bool { items.isEmpty }

    mutating func add(_ input: BrowserInput) -> Kept {
        guard input.isTyping else { return .ignored }
        guard items.count < limit else { return .full }
        items.append(input)
        return items.count == 1 ? .first : .kept
    }

    mutating func take() -> [BrowserInput] { defer { items = [] }; return items }
    mutating func clear() { items = [] }
}

nonisolated enum BrowserReconnect {
    /// 1, 2, 4, 8, 10, 10… seconds.
    static func delay(attempt: Int) -> Double { min(10, pow(2, Double(max(0, attempt - 1)))) }
}

/// [presence] When the gateway link is back, plugin sockets waiting out a back-off dial at once (spec 3x-presence §11;
/// the web app's `dispatch:network-restored` resume, R:src/browser-watch/viewer.tsx:270-271).
nonisolated enum BrowserLinkRule {
    /// The gateway link came back: the path returned (the state leaves .offline) or the main socket is ready again
    /// (DECISION D13: after any drop, not only a network path change).
    static func restored(from old: ConnectionState, to new: ConnectionState) -> Bool {
        switch new {
        case .signedOut, .offline: return false
        case .ready: return old != .ready
        case .connecting, .reconnecting:
            if case .offline = old { return true }
            return false
        }
    }

    /// A viewer's socket dials now only while it waits to retry: one that is live, or a dial already asking for its
    /// address (no socket yet and no retry pending), is left alone, so two sockets never race.
    static func watchDialsNow(shown: Bool, stopped: Bool, ended: Bool, hasSocket: Bool, retrying: Bool) -> Bool {
        shown && !stopped && !ended && !hasSocket && retrying
    }
}

/// [presence] Chat ⋯ › Watch Browser (spec 3x-presence §9; R:src/phone-chat-menu.tsx:258): greyed with "Offline" under
/// it while the link is not ready.
nonisolated enum BrowserMenuRule {
    static let title = "Watch Browser"
    static func chatItem(offline: Bool) -> (subtitle: String?, disabled: Bool) {
        offline ? ("Offline", true) : (nil, false)
    }
}

/// The phone's stage in points times its zoom, and its pixel density, bounded (the `view` message).
nonisolated func browserViewSize(width: Double, height: Double, scale: Double) -> (width: Int, height: Int, scale: Double) {
    let ratio = scale.isFinite ? min(3, max(1, scale)) : 1
    func size(_ v: Double) -> Int { v.isFinite ? Int(max(64, min(2048, v.rounded()))) : 64 }
    return (size(width), size(height), ratio)
}
