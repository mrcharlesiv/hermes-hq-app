// [transcript] hermes:// deep links beyond `session` and `connect` (docs/spec/3x-transcript.md §7.1, row L981).
// The bounds are the old shell's (`ios/App/App/HermesPlatform.swift` HermesLinks.open and its policy): at most
// 32,768 bytes; kind `^[a-z0-9][a-z0-9-]{0,63}$`; name at most 1,024; at most 32 params; key at most 64; value at
// most 16,384; no control characters. `NotificationRules.link` keeps parsing `session` and `connect`.

import Foundation

nonisolated enum DeepLink: Equatable, Sendable {
    case session(String)
    case connect(String)
    /// Every other valid link: `hermes://<kind>/<name>?<params>`.
    case other(kind: String, name: String, params: [Param])

    struct Param: Equatable, Sendable {
        var key: String
        var value: String
    }

    static let maxBytes = 32_768
    static let maxName = 1_024
    static let maxParams = 32
    static let maxKey = 64
    static let maxValue = 16_384
    private static let kindRE = TRx(#"^[a-z0-9][a-z0-9-]{0,63}$"#)

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// nil for a link that is not ours or fails a bound (ignored silently; a malformed link is not user intent).
    static func parse(_ url: URL, scheme: String) -> DeepLink? {
        guard let given = url.scheme?.lowercased(), given == scheme.lowercased() || given == "hermes" else { return nil }
        let whole = url.absoluteString
        guard whole.utf8.count <= maxBytes else { return nil }
        // The kind is case-sensitive as written ("Bad_Kind" is refused), so it is read from the text, not `url.host`.
        guard let schemeEnd = whole.range(of: "://") else { return nil }
        let rest = whole[schemeEnd.upperBound...]
        let kind = String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard kindRE.test(kind) else { return nil }
        if kind == "session" || kind == "connect" {
            switch NotificationRules.link(url, scheme: scheme) {
            case .session(let id)?: return .session(id)
            case .connect(let address)?: return .connect(address)
            case nil: return nil
            }
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.fragment == nil,
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        let name = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard name.count <= maxName, !hasControl(name) else { return nil }
        let items = components.queryItems ?? []
        guard items.count <= maxParams else { return nil }
        var params: [Param] = []
        for item in items {
            let value = item.value ?? ""
            guard !item.name.isEmpty, item.name.count <= maxKey, value.count <= maxValue, !hasControl(item.name),
                  !hasControl(value) else { return nil }
            params.append(Param(key: item.name, value: value))
        }
        return .other(kind: kind, name: name, params: params)
    }

    /// "/blueprint weekly team=core" (params in the order given; a value with a space is quoted).
    static func blueprintCommand(name: String, params: [Param]) -> String? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains(where: \.isWhitespace) else { return nil }
        var out = "/blueprint \(clean)"
        for param in params {
            let value = param.value.contains(where: \.isWhitespace) || param.value.isEmpty
                ? "\"" + param.value.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : param.value
            out += " \(param.key)=\(value)"
        }
        return out
    }

    /// "That isn’t available on iPhone yet."
    static func unavailable(device: String) -> String { "That isn’t available on \(device) yet." }
}

/// Links that arrive before the app can act on them (signed out, the bot list not loaded): the last four are kept and
/// replayed once.
nonisolated struct DeepLinkQueue: Sendable {
    static let limit = 4
    private(set) var pending: [URL] = []

    mutating func hold(_ url: URL) {
        pending.append(url)
        if pending.count > Self.limit { pending.removeFirst(pending.count - Self.limit) }
    }

    mutating func drain() -> [URL] {
        defer { pending = [] }
        return pending
    }
}
