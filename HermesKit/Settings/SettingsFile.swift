// Settings › Export Settings… / Import Settings… / Reset to Defaults… (`src/settings-config-file.ts`,
// `src/mcp-entry-mask.ts`). `GET /api/config` returns every ${VAR} reference expanded, so an exported file would carry
// connector bearer tokens and provider keys in plain text: the export writes a placeholder at each credential, and an
// import never writes a placeholder (or a secret the file lacks) over the value already on the gateway.

import Foundation

nonisolated enum SettingsFile {
    /// What an exported file holds in place of a key or token.
    static let placeholder = "«left out of this export»"

    // MARK: Which values are credentials

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `api_key_env`, `password_store`: the name of where a secret lives, not the secret.
    private static func namesAPlace(_ key: String) -> Bool { matches(key, #"_env(?:_?(?:var|name))?$|_store$|_backend$"#) }

    /// Outside connectors: authorization, api key, token, secret, password, bearer, cookie.
    static func secretKey(_ key: String) -> Bool {
        matches(key, #"authorization|api[_-]?key|token|secret|password|bearer|cookie"#) && !namesAPlace(key)
    }

    /// A connector's entry: any key-like name.
    static func connectorSecretKey(_ key: String) -> Bool {
        matches(key, #"key|token|secret|passw(?:or)?d|authorization|cookie|credential|bearer"#) && !namesAPlace(key)
    }

    private static func isReference(_ text: String) -> Bool { matches(text, #"\$\{[A-Za-z_][A-Za-z0-9_]*\}"#) }

    private static let valueShapes = #"\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[abprs]-[A-Za-z0-9-]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#
    private static let secretParams = #"^(?:auth|sig|signature|code|session(?:[-_]?id)?|hmac|hash|access|customer[-_]?id|user[-_]?id)$"#

    /// A whole value replaced, unless it is empty or a ${VAR} reference.
    private static func whole(_ text: String) -> String { text.isEmpty || isReference(text) ? text : placeholder }

    /// Free text: provider key shapes and JWTs; URLs' user info and credential parameters.
    private static func scrub(_ text: String, connector: Bool) -> String {
        var out = text.replacingOccurrences(of: valueShapes, with: placeholder, options: .regularExpression)
        out = maskURLs(out)
        if connector {
            // A random-looking run (a bare token argument): 16+ letters and digits mixed, or a UUID.
            out = replace(out, #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9]{16,}"#) { run in
                run.contains("-") || (run.rangeOfCharacter(from: .decimalDigits) != nil && run.rangeOfCharacter(from: .letters) != nil)
                    ? placeholder : run
            }
        }
        return out
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: transform(String(out[range])))
        }
        return out
    }

    private static func maskURLs(_ text: String) -> String {
        replace(text, #"\b[a-z][a-z0-9+.-]*://[^\s"'<>]+"#) { url in
            guard var parts = URLComponents(string: url) else { return url }
            var changed = false
            if parts.user != nil || parts.password != nil {
                if let user = parts.user, !isReference(user) { parts.user = placeholder; changed = true }
                if let password = parts.password, !isReference(password) { parts.password = placeholder; changed = true }
            }
            if let items = parts.queryItems {
                parts.queryItems = items.map { item in
                    guard let value = item.value, !value.isEmpty, !isReference(value),
                          connectorSecretKey(item.name) || matches(item.name, secretParams) else { return item }
                    changed = true
                    return URLQueryItem(name: item.name, value: placeholder)
                }
            }
            return changed ? (parts.string?.removingPercentEncoding ?? url) : url
        }
    }

    // MARK: Export

    /// The config with every credential replaced by the placeholder (numbers, switches, empty values and ${VAR}
    /// references stay as they are).
    static func redact(_ config: JSONValue) -> JSONValue {
        guard case .object(let object) = config else { return redactValue(config, key: nil, connector: false) }
        return .object(object.reduce(into: [:]) { out, entry in
            if entry.key == "mcp_servers", case .object(let servers) = entry.value {
                out[entry.key] = .object(servers.mapValues { redactValue($0, key: nil, connector: true) })
            } else {
                out[entry.key] = redactValue(entry.value, key: entry.key, connector: false)
            }
        })
    }

    private static func redactValue(_ value: JSONValue, key: String?, connector: Bool, inSecretMap: Bool = false, flagBefore: Bool = false) -> JSONValue {
        let isSecret = key.map { connector ? connectorSecretKey($0) : secretKey($0) } ?? false
        switch value {
        case .string(let text):
            if isSecret || inSecretMap || flagBefore { return .string(whole(text)) }
            if connector, let header = maskHeader(text) { return .string(header) }
            if connector, let assigned = maskAssignment(text) { return .string(assigned) }
            return .string(scrub(text, connector: connector))
        case .array(let items):
            var out: [JSONValue] = []
            var maskNext = false
            for item in items {
                out.append(redactValue(item, key: key, connector: connector, inSecretMap: inSecretMap, flagBefore: maskNext))
                // A flag that takes a credential as its next argument ("--api-key", "--token", "--header").
                maskNext = connector && (item.string.map { matches($0, #"^--?[\w-]*(?:key|token|secret|passw(?:or)?d|auth|cookie|credential)[\w-]*$"#) } ?? false)
            }
            return .array(out)
        case .object(let object):
            let secretMap = connector && ["headers", "env", "environment"].contains(key ?? "")
            return .object(object.reduce(into: [:]) { out, entry in
                if secretMap, matches(entry.key, #"^(?:content-type|accept(?:-[a-z]+)?)$"#) {
                    out[entry.key] = entry.value
                } else if secretMap, case .string(let text) = entry.value {
                    out[entry.key] = .string(whole(text))
                } else {
                    out[entry.key] = redactValue(entry.value, key: entry.key, connector: connector)
                }
            })
        default:
            return value
        }
    }

    /// "Authorization: Bearer abc" → "Authorization: «…»".
    private static func maskHeader(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*([A-Za-z0-9_-]+)\s*:\s*(\S.*)$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let name = Range(match.range(at: 1), in: text), let rest = Range(match.range(at: 2), in: text),
              !matches(text, #"^\s*[a-z][a-z0-9+.-]*://"#), connectorSecretKey(String(text[name])) else { return nil }
        return isReference(String(text[rest])) ? text : "\(text[name]): \(placeholder)"
    }

    /// "API_TOKEN=abc" / "--token=abc" → the name kept, the value left out.
    private static func maskAssignment(_ text: String) -> String? {
        guard let equals = text.firstIndex(of: "=") else { return nil }
        let name = String(text[..<equals]), value = String(text[text.index(after: equals)...])
        guard name.range(of: #"^-{0,2}[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil, connectorSecretKey(name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))), !value.isEmpty, !isReference(value) else { return nil }
        return "\(name)=\(placeholder)"
    }

    /// "Hermes settings 2026-10-11.json": which profile, and when.
    static func exportFileName(profile: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let cleaned = profile.replacingOccurrences(of: #"[\\/:*?"<>|\x{00}-\x{1f}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Hermes" : cleaned) settings \(day).json"
    }

    /// The pretty-printed file.
    static func fileData(_ config: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(redact(config))
    }

    // MARK: Import

    /// A left-out value: this placeholder, or the gateway's own redaction.
    static func isPlaceholder(_ value: JSONValue) -> Bool {
        guard let text = value.string else { return false }
        return text == placeholder || text.lowercased().hasPrefix("«redacted") || text.trimmingCharacters(in: .whitespaces).range(of: #"^\*{3,}$"#, options: .regularExpression) != nil
    }

    /// The file as the gateway should see it: each placeholder takes the value already saved there (or is dropped), and
    /// an object inside a list keeps the secrets the file left out, since a list is written whole.
    static func keepSecrets(_ next: JSONValue, current: JSONValue?) -> JSONValue? {
        keep(next, current, inList: false)
    }

    private static func keep(_ next: JSONValue, _ current: JSONValue?, inList: Bool) -> JSONValue? {
        switch next {
        case .string(let text) where isPlaceholder(next) || text.contains(placeholder):
            // The saved value stays (a string with left-out parts can't be stitched back safely: keep the whole saved one).
            if case .string? = current { return current }
            return nil
        case .array(let items):
            let currentItems = current?.array ?? []
            let names = currentItems.map { $0["name"]?.string }
            let pairByName = !currentItems.isEmpty && names.allSatisfy { $0 != nil } && Set(names.compactMap { $0 }).count == names.count
            return .array(items.enumerated().compactMap { index, item in
                var counterpart: JSONValue?
                if pairByName, let name = item["name"]?.string {
                    counterpart = currentItems.first { $0["name"]?.string == name }
                } else if index < currentItems.count {
                    counterpart = currentItems[index]
                }
                return keep(item, counterpart, inList: true)
            })
        case .object(let object):
            let base = current?.object ?? [:]
            var out: [String: JSONValue] = [:]
            for (key, value) in object {
                if let kept = keep(value, base[key], inList: inList) { out[key] = kept }
            }
            if inList {
                // A list is written whole: a credential the file left out entirely comes back from the saved item.
                for (key, value) in base where out[key] == nil && redact(.object([key: value]))[key] != value {
                    out[key] = value
                }
            }
            return .object(out)
        default:
            return next
        }
    }

    /// Only what the file changes is written (`PUT /api/config` deep-merges).
    static func importPatch(file: JSONValue, current: JSONValue) -> JSONValue {
        let next = keepSecrets(file, current: current) ?? .object([:])
        return ConfigPath.diff(current, next)
    }
}
