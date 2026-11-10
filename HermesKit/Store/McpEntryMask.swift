// Port of the web's ref:src/mcp-entry-mask.ts (docs/spec/3x-capabilities.md §6, §7). Connector › Advanced shows the
// selected server's entry read-only with every credential replaced; its log goes through the same masker. Each rule
// keeps the web's name and carries the TypeScript pattern above its Swift twin; Tests/Capabilities/McpEntryMaskTests
// ports the web's vectors one to one.

import Foundation

nonisolated struct McpEntryMask: Sendable {
    static let MASK = "••••••"
    /// The web's default masker: `${VAR}` references are masked too.
    static let phone = McpEntryMask()

    var mask = McpEntryMask.MASK
    /// Leave `${VAR}` references as written (the settings export keeps them; the phone's view hides them).
    var keepRefs = false
    var freeRuns = true

    // /(?:key|token|secret|passw(?:or)?d|authorization|cookie|credential|bearer)/i
    static let SECRET_KEY = JSRegex(#"(?:key|token|secret|passw(?:or)?d|authorization|cookie|credential|bearer)"#, "i")
    // /^(?:auth|sig|signature|code|session(?:[-_]?id)?|hmac|hash|access|customer[-_]?id|user[-_]?id)$/i
    static let SECRET_PARAM = JSRegex(#"^(?:auth|sig|signature|code|session(?:[-_]?id)?|hmac|hash|access|customer[-_]?id|user[-_]?id)$"#, "i")
    static let SECRET_MAPS: Set<String> = ["headers", "env", "environment"]
    // /^(?:content-type|accept(?:-[a-z]+)?)$/i
    static let SAFE_HEADER = JSRegex(#"^(?:content-type|accept(?:-[a-z]+)?)$"#, "i")
    // /\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[abprs]-[A-Za-z0-9-]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b/g
    static let SECRET_VALUE = JSRegex(#"\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[abprs]-[A-Za-z0-9-]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#)
    // /^--?[\w-]*(?:key|token|secret|passw(?:or)?d|auth|cookie|credential)[\w-]*$/i
    static let SECRET_FLAG = JSRegex(#"^--?[\w-]*(?:key|token|secret|passw(?:or)?d|auth|cookie|credential)[\w-]*$"#, "i")
    // /^(?:--header|-H)$/
    static let HEADER_FLAG = JSRegex(#"^(?:--header|-H)$"#)
    // /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9]{16,}/gi
    static let TOKEN_RUN = JSRegex(#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9]{16,}"#, "i")
    // /\b[a-z][a-z0-9+.-]*:\/\/[^\s"'<>]+/gi
    static let URL_IN_TEXT = JSRegex(#"\b[a-z][a-z0-9+.-]*://[^\s"'<>]+"#, "i")
    // /\$\{[A-Za-z_][A-Za-z0-9_]*\}/
    static let ENV_REF = JSRegex(#"\$\{[A-Za-z_][A-Za-z0-9_]*\}"#)
    // /^[a-z][a-z0-9+.-]*:\/\//i
    static let IS_URL = JSRegex(#"^[a-z][a-z0-9+.-]*://"#, "i")
    // /^\s*([A-Za-z0-9_-]+)\s*:\s*(\S.*)$/
    static let HEADER_LINE = JSRegex(#"^\s*([A-Za-z0-9_-]+)\s*:\s*(\S.*)$"#)
    // /^([a-z][a-z0-9+.-]*:\/\/)([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/i
    static let URL_PARTS = JSRegex(#"^([a-z][a-z0-9+.-]*://)([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$"#, "i")
    // /\b([\w-]*(?:api[-_]?key|token|secret|passw(?:or)?d|authorization|cookie|credential)["']?\s*[:=]\s*)(?:(?:Bearer|Basic|Token)\s+)?("[^"]*"|'[^']*'|[^\s,;"']+)/gi
    static let NAMED = JSRegex(#"\b([\w-]*(?:api[-_]?key|token|secret|passw(?:or)?d|authorization|cookie|credential)["']?\s*[:=]\s*)(?:(?:Bearer|Basic|Token)\s+)?("[^"]*"|'[^']*'|[^\s,;"']+)"#, "i")
    // /\b(Bearer|Basic)\s+(?!••|«)[^\s,;"']+/gi
    static let BEARER = JSRegex(#"\b(Bearer|Basic)\s+(?!••|«)[^\s,;"']+"#, "i")
    // /^(--header=)(.+)$/
    static let FLAGGED = JSRegex(#"^(--header=)(.+)$"#)
    // /^([^=\s]*(?:key|token|secret|passw(?:or)?d|auth|cookie|credential)[^=\s]*=)(.+)$/i
    static let ASSIGNED = JSRegex(#"^([^=\s]*(?:key|token|secret|passw(?:or)?d|auth|cookie|credential)[^=\s]*=)(.+)$"#, "i")
    // /^(?:none|oauth|bearer|basic|header)$/i
    static let AUTH_METHOD = JSRegex(#"^(?:none|oauth|bearer|basic|header)$"#, "i")
    static let HAS_DIGIT = JSRegex(#"\d"#)
    static let HAS_LETTER = JSRegex(#"[A-Za-z]"#)

    private var template: String { NSRegularExpression.escapedTemplate(for: mask) }

    private func ref(_ value: String) -> Bool { keepRefs && Self.ENV_REF.test(value) }
    private func whole(_ value: String) -> String { !value.isEmpty && !ref(value) ? mask : value }

    private func matches(_ regex: JSRegex, _ value: String) -> [NSTextCheckingResult] {
        regex.regex.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length))
    }

    private func runs(_ value: String) -> String {
        let ns = value as NSString
        var out = "", last = 0
        for match in matches(Self.TOKEN_RUN, value) {
            let run = ns.substring(with: match.range)
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += run.contains("-") || (Self.HAS_DIGIT.test(run) && Self.HAS_LETTER.test(run)) ? mask : run
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }

    private func outsideRefs(_ value: String, _ apply: (String) -> String) -> String {
        guard keepRefs else { return apply(value) }
        let ns = value as NSString
        var out = "", last = 0
        for match in matches(Self.ENV_REF, value) {
            out += apply(ns.substring(with: NSRange(location: last, length: match.range.location - last))) + ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        return out + apply(ns.substring(from: last))
    }

    /// "Authorization: Bearer abc" → "Authorization: ••••••" for a secret header's name, and for any header when
    /// `always` (the argument after --header). nil when `value` is not a header.
    private func header(_ value: String, always: Bool = false) -> String? {
        guard let match = Self.HEADER_LINE.exec(value), !Self.IS_URL.test(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let name = match.groups[1], rest = match.groups[2]
        if !always && !Self.SECRET_KEY.test(name) { return nil }
        return ref(rest) || Self.SAFE_HEADER.test(name) ? value : "\(name): \(mask)"
    }

    private func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }

    private func url(_ value: String) -> String {
        guard let parts = Self.URL_PARTS.exec(value) else { return runs(value) }
        let scheme = parts.groups[1], authority = parts.groups[2], path = parts.groups[3]
        let query = parts.groups.count > 4 ? parts.groups[4] : "", hash = parts.groups.count > 5 ? parts.groups[5] : ""
        // A username alone is often the token itself (https://TOKEN@host).
        var host = authority
        if let at = authority.range(of: "@", options: .backwards) {
            let user = authority[..<at.lowerBound].split(separator: ":", omittingEmptySubsequences: false).map { whole(String($0)) }.joined(separator: ":")
            host = user + "@" + authority[at.upperBound...]
        }
        // Hosted "secret URL" servers carry the token in the path (…/s/<token>/mcp).
        let route = path.split(separator: "/", omittingEmptySubsequences: false).map { ref(String($0)) ? String($0) : runs(String($0)) }.joined(separator: "/")
        var search = ""
        if !query.isEmpty {
            search = "?" + query.dropFirst().split(separator: "&", omittingEmptySubsequences: false).map { piece -> String in
                let pair = String(piece)
                guard let eq = pair.firstIndex(of: "=") else { return pair }
                let rawName = String(pair[..<eq])
                let name = decode(rawName), param = decode(String(pair[pair.index(after: eq)...]))
                let secret = !param.isEmpty && !ref(param) && (Self.SECRET_KEY.test(name) || Self.SECRET_PARAM.test(name) || runs(param) != param)
                return secret ? "\(rawName)=\(mask)" : pair
            }.joined(separator: "&")
        }
        return scheme + host + route + search + hash
    }

    /// Free text (an argument, a server log line): "Name: value" and "name=value" secrets, Bearer credentials, known
    /// key shapes, URLs' credentials and random-looking runs.
    func text(_ value: String) -> String {
        let template = self.template
        func plain(_ part: String) -> String {
            outsideRefs(part) { piece in
                var out = Self.NAMED.replaceAll(piece, "$1" + template)
                out = Self.BEARER.replaceAll(out, "$1 " + template)
                out = Self.SECRET_VALUE.replaceAll(out, template)
                return freeRuns ? runs(out) : out
            }
        }
        let ns = value as NSString
        var out = "", last = 0
        for match in matches(Self.URL_IN_TEXT, value) {
            out += plain(ns.substring(with: NSRange(location: last, length: match.range.location - last))) + url(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        return out + plain(ns.substring(from: last))
    }

    private func string(_ value: String, key: String) -> String {
        if value.isEmpty { return value }
        if Self.SECRET_KEY.test(key) { return whole(value) }
        if let named = header(value) { return named }
        if Self.IS_URL.test(value) { return url(value) }
        // "--header=X-Api-Key: abc", "--api-key=abc", "TOKEN=abc"
        if let flagged = Self.FLAGGED.exec(value) { return flagged.groups[1] + (header(flagged.groups[2], always: true) ?? whole(flagged.groups[2])) }
        if let assigned = Self.ASSIGNED.exec(value) { return assigned.groups[1] + whole(assigned.groups[2]) }
        return text(value)
    }

    func entry(_ value: JSONValue) -> JSONValue { entry(value, key: "", inSecretMap: false) }

    private func entry(_ value: JSONValue, key: String, inSecretMap: Bool) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(inSecretMap ? whole(s) : string(s, key: key))
        case .array(let items):
            return .array(items.enumerated().map { index, item in
                let flag = index > 0 ? (items[index - 1].string ?? "") : ""
                if let s = item.string, !flag.isEmpty {
                    if Self.HEADER_FLAG.test(flag) { return .string(header(s, always: true) ?? whole(s)) }
                    if Self.SECRET_FLAG.test(flag) { return .string(whole(s)) }
                }
                return entry(item, key: key, inSecretMap: inSecretMap)
            })
        case .object(let map):
            let headers = key.lowercased() == "headers"
            var out: [String: JSONValue] = [:]
            for (name, child) in map {
                // "auth": "oauth" names a method, and Content-Type / Accept a format; neither is a credential.
                if (name == "auth" && child.string.map(Self.AUTH_METHOD.test) == true) || (headers && Self.SAFE_HEADER.test(name)) {
                    out[name] = child
                } else {
                    let isContainer = child.object != nil || child.array != nil
                    out[name] = entry(child, key: name,
                                      inSecretMap: inSecretMap || Self.SECRET_MAPS.contains(name.lowercased()) || (Self.SECRET_KEY.test(name) && isContainer))
                }
            }
            return .object(out)
        default:
            return value
        }
    }

    /// `JSON.stringify({[name]: maskMcpEntry(entry)}, null, 2)` with sorted keys (DECISION 6-a).
    func configurationText(name: String, entry raw: JSONValue) -> String {
        let masked = JSONValue.object([name: entry(raw)])
        guard let data = try? masked.encoded(), let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else { return "" }
        return text
    }
}
