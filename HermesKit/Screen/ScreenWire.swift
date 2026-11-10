// Bot Screen's wire (docs/spec/3x-screen.md §2): the display status and lease as Hermes sends them, the exact params of
// the five `display.*` calls (Hermes answers an unknown param with error 4000), the viewer hash, the tone and kind
// rules, and the display socket's URL. Pure values; nothing here talks to the network.

import CryptoKit
import Foundation

nonisolated enum ScreenHolder: String, Sendable { case agent, human }

/// Who controls the screen. A human holder is named by `viewerHash`, never by id.
nonisolated struct ScreenLease: Equatable, Sendable {
    var holder: ScreenHolder = .agent
    var viewerHash: String?
    var epoch = 0

    /// nil unless it is an object with a known holder (a wrong shape is "no lease known", never a crash).
    static func parse(_ value: JSONValue?) -> ScreenLease? {
        guard let value, value.object != nil, let holder = value["holder"]?.string.flatMap(ScreenHolder.init) else { return nil }
        return ScreenLease(holder: holder, viewerHash: value["viewer_hash"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                           epoch: max(0, value["epoch"]?.int ?? 0))
    }

    /// `V/screen-state.ts` isOlderLease: a lease with a lower epoch than the one held is ignored.
    func isOlder(than other: ScreenLease?) -> Bool { other.map { epoch < $0.epoch } ?? false }
}

nonisolated struct ScreenStatus: Equatable, Sendable {
    var profileKey: String?
    var supported = false
    var installed = false
    var running = false
    var missing: [String] = []
    var display: String?
    var geometry: String?
    var installCommand: String?
    var blocker: String?
    var placement: String?
    var lease: ScreenLease?

    /// nil unless the answer is an object. Every field is optional on read.
    static func parse(_ value: JSONValue?) -> ScreenStatus? {
        guard let value, value.object != nil else { return nil }
        func text(_ key: String) -> String? { value[key]?.string.map(ScreenWire.plain).flatMap { $0.isEmpty ? nil : $0 } }
        return ScreenStatus(profileKey: value["profile_key"]?.string, supported: value["supported"]?.bool == true,
                            installed: value["installed"]?.bool == true, running: value["running"]?.bool == true,
                            missing: (value["missing"]?.array ?? []).compactMap(\.string), display: value["display"]?.string,
                            geometry: value["geometry"]?.string, installCommand: value["install_command"]?.string,
                            blocker: text("blocker"), placement: value["placement"]?.string, lease: ScreenLease.parse(value["lease"]))
    }

    /// The Mac's own console, shared by every bot on it.
    var isMac: Bool { display == "This Mac" }
    /// `!running && blocker`: the gateway could share a screen but something stops it.
    var isBlocked: Bool { !running && blocker != nil }
}

/// A viewer id minted by `display.observe` and the hash the lease names it by.
nonisolated struct ScreenViewer: Equatable, Sendable {
    let id: String
    let hash: String

    init(id: String) {
        self.id = id
        hash = ScreenWire.viewerHash(id)
    }
}

nonisolated struct ScreenObserved: Equatable, Sendable {
    var status: ScreenStatus
    var ticket: String
    var path: String
    var viewer: ScreenViewer

    static func parse(_ value: JSONValue) -> ScreenObserved? {
        guard let status = ScreenStatus.parse(value), let ticket = value["ticket"]?.string, !ticket.isEmpty,
              let path = value["path"]?.string, let id = value["viewer_id"]?.string, !id.isEmpty else { return nil }
        return ScreenObserved(status: status, ticket: ticket, path: path, viewer: ScreenViewer(id: id))
    }
}

/// What a bot's screen is doing (`V/screen-portal.tsx` portalTone).
nonisolated enum ScreenTone: Equatable, Sendable { case unknown, unavailable, unsupported, missing, off, live, human, other }

/// What the Screen entry opens (`S/bot-screen-phone.tsx` screenMenuLabel).
nonisolated enum ScreenKind: String, Equatable, Sendable {
    case unknown, live, screenshots

    var menuTitle: String {
        switch self {
        case .screenshots: "Latest Screenshots"
        case .live: "Watch Screen"
        case .unknown: "View Screen"
        }
    }

    var symbol: String { self == .screenshots ? "photo.on.rectangle" : "display" }
}

nonisolated enum ScreenWire {
    static let displayPath = "/api/display/ws"
    static let maxMessage = 4 * 1024 * 1024
    static let statusTimeout: Duration = .seconds(20)
    static let startTimeout: Duration = .seconds(30)
    static let observeTimeout: Duration = .seconds(15)
    static let leaseTimeout: Duration = .seconds(10)

    enum Close {
        static let controlTaken = 4000
        static let notRunning = 4001
        static let ticket = 4401
        static let notAllowed = 4403
        static let protocolError = 1003
    }

    // MARK: Params (exactly these keys)

    static func profileParams(_ profile: String) -> JSONValue { ["profile": .string(profile)] }

    static func observeParams(profile: String, viewerId: String?) -> JSONValue {
        var params: [String: JSONValue] = ["profile": .string(profile)]
        if let viewerId, !viewerId.isEmpty { params["viewer_id"] = .string(viewerId) }
        return .object(params)
    }

    static func acquireParams(profile: String, viewerId: String) -> JSONValue {
        ["profile": .string(profile), "viewer_id": .string(viewerId)]
    }

    /// By id · by id with force (a hold this phone lost track of) · bare with force (another viewer's hold).
    static func releaseParams(profile: String, viewerId: String?, force: Bool) -> JSONValue {
        var params: [String: JSONValue] = ["profile": .string(profile)]
        if let viewerId, !viewerId.isEmpty { params["viewer_id"] = .string(viewerId) }
        if force { params["force"] = true }
        return .object(params)
    }

    // MARK: Rules

    /// Older Hermes has no `display.*`: error -32601, or a message saying so.
    static func isUnavailable(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        if rpc.code == -32601 { return true }
        let text = rpc.message.lowercased()
        return text.contains("method not found") || text.contains("unknown method")
    }

    /// First 12 hex characters of SHA-256 of the viewer id (`HA/tools/bot_desktop/lease.py` public_view).
    static func viewerHash(_ id: String) -> String {
        String(SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    static func holds(_ lease: ScreenLease?, _ viewer: ScreenViewer?) -> Bool {
        guard let lease, let viewer, lease.holder == .human else { return false }
        return lease.viewerHash == viewer.hash
    }

    static func tone(unavailable: Bool, status: ScreenStatus?, viewer: ScreenViewer?) -> ScreenTone {
        if unavailable { return .unavailable }
        guard let status else { return .unknown }
        if !status.supported { return .unsupported }
        if !status.installed { return .missing }
        if !status.running { return .off }
        if status.lease?.holder == .human { return holds(status.lease, viewer) ? .human : .other }
        return .live
    }

    /// The kind a tone means, and what to remember for the gateway (nil: remember nothing).
    static func kind(tone: ScreenTone, remembered: ScreenKind?) -> (kind: ScreenKind, remember: ScreenKind?) {
        switch tone {
        case .unsupported, .unavailable: (.screenshots, .screenshots)
        case .unknown: (remembered ?? .unknown, nil)
        default: (.live, .live)
        }
    }

    /// "This Mac · 1920×1080" (`S/bot-screen-phone.tsx` screenLabel): an X display number (":7") says nothing to a
    /// person and is left out; "WxH" reads "W×H".
    static func screenLabel(_ status: ScreenStatus?) -> String {
        guard let status else { return "" }
        var geometry = status.geometry ?? ""
        let sides = geometry.split(separator: "x", omittingEmptySubsequences: false)
        if sides.count == 2, sides.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) { geometry = "\(sides[0])×\(sides[1])" }
        var display = (status.display ?? "").trimmingCharacters(in: .whitespaces)
        if display.hasPrefix(":"), display.dropFirst().allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }), display.count > 1 { display = "" }
        return [display, geometry].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A geometry "1920x1080" as numbers (nil when it is anything else).
    static func size(_ geometry: String?) -> (width: Int, height: Int)? {
        guard let parts = geometry?.split(separator: "x"), parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// `ws(s)://<gateway><prefix>/api/display/ws?display_ticket=<ticket>`: the ticket is the only credential that
    /// route takes. nil (never dialled) when `path` is anything but `/api/display/ws`.
    static func displaySocketURL(base: URL, path: String, ticket: String) -> URL? {
        guard path == displayPath, !ticket.isEmpty, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
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
        parts.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        return parts.url
    }

    // MARK: Text the gateway wrote (D27)

    private static let oldHelper = try! NSRegularExpression(pattern: "dispatch[ \\u00A0]screen", options: [.caseInsensitive])
    private static let oldPlugin = try! NSRegularExpression(pattern: "dispatch-screen", options: [.caseInsensitive])
    private static let oldName = try! NSRegularExpression(pattern: "dispatch", options: [.caseInsensitive])

    /// Gateway-written text before it is shown or spoken: a Mac that still runs the pre-rename plugin words its
    /// messages with the old product name, which never appears on screen.
    static func plain(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in [(oldHelper, "Hermes HQ Screen"), (oldPlugin, "hermes-hq-screen"), (oldName, "Hermes HQ")] {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A failed call in words a person can read.
    static func message(_ error: Error) -> String {
        if let rpc = error as? RPCError {
            if rpc.isTimeout { return "The gateway took too long to answer." }
            if rpc.isConnectionLost || rpc.isNotConnected { return "The connection to the gateway was lost." }
            let text = plain(rpc.message)
            return text.isEmpty ? "The gateway refused the request." : text
        }
        if let failure = error as? GatewayFailure, let text = failure.errorDescription { return text }
        if error is CancellationError { return "The request was cancelled." }
        return plain(error.localizedDescription)
    }

    /// `<text without its trailing period>.` (one period, not two).
    static func sentence(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") { out.removeLast() }
        return out + "."
    }
}
