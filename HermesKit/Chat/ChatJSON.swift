// JSON helpers for the chat data layer: a fast parser (Foundation's JSONSerialization, then a cheap walk into
// JSONValue), compact stringify, and the small "loose value" accessors the hydration fold needs (spec 03 §2.2:
// Hermes adds fields freely and older backends send JSON columns as strings).

import Foundation

nonisolated enum ChatJSON {
    /// Parses raw JSON bytes. Much faster than `JSONValue.parse` for big pages (no try-each-type decoding).
    static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value(from: object)
    }

    /// Parses a JSON string; nil when it is not JSON.
    static func parse(string: String) -> JSONValue? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? parse(data)
    }

    static func value(from object: Any) -> JSONValue {
        switch object {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let a as [Any]: return .array(a.map(value(from:)))
        case let d as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d { out[k] = value(from: v) }
            return .object(out)
        case is NSNull: return .null
        default: return .null
        }
    }

    static func foundationObject(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            guard n.isFinite else { return NSNull() }   // JSONSerialization raises on NaN/inf
            if n.rounded() == n, abs(n) < 9.007e15 { return Int64(n) }
            return n
        case .string(let s): return s
        case .array(let a): return a.map(foundationObject)
        case .object(let o): return o.mapValues(foundationObject)
        }
    }

    /// Compact JSON text (sorted keys so equal values stringify equally). Strings stay strings.
    static func stringify(_ value: JSONValue) -> String {
        if case .string(let s) = value {
            // A bare top-level string: quote it like JSON.stringify would.
            if let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
               let text = String(data: data, encoding: .utf8) {
                return String(text.dropFirst().dropLast())
            }
            return "\"\(s)\""
        }
        if case .null = value { return "null" }
        let object = foundationObject(value)
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    static func stringifyPretty(_ value: JSONValue) -> String {
        let object = foundationObject(value)
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return stringify(value) }
        return text
    }
}

nonisolated extension JSONValue {
    /// An object, or a JSON string holding an object (display_metadata, codex items…), else nil.
    var looseObject: [String: JSONValue]? {
        switch self {
        case .object(let o): return o
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("{"), case .object(let o)? = ChatJSON.parse(string: t) else { return nil }
            return o
        default: return nil
        }
    }

    /// Non-empty trimmed string, or nil.
    var nonEmptyString: String? {
        guard case .string(let s) = self, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// JS truthiness for the hydration fold (`a || b`).
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// Positive safe integer (row ids).
    var positiveInt: Int? {
        guard case .number(let n) = self, n.rounded() == n, n > 0, n < 9.007e15 else { return nil }
        return Int(n)
    }
}

nonisolated extension Optional where Wrapped == JSONValue {
    var isTruthy: Bool { self?.isTruthy ?? false }
}

nonisolated enum ChatText {
    /// `text.replace(/\s+/g, ' ').trim()`
    static func flat(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for ch in text {
            if ch.isWhitespace { pendingSpace = !out.isEmpty; continue }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(ch)
        }
        return out
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// First `max` characters with "…" when cut (compactPreview).
    static func compactPreview(_ text: String, max: Int = 72) -> String {
        let line = flat(text)
        guard line.count > max else { return line }
        return String(line.prefix(max - 1)) + "…"
    }

    /// Cut to at most `max` UTF-8 bytes, never splitting a Unicode scalar. O(1) for text under the cap (the UTF-8 count of
    /// a native string is stored), so a 1 MB tool output costs a slice, not a grapheme walk (it runs on the main thread
    /// for live `tool.complete` frames).
    static func clip(_ text: String, max: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > max else { return text }
        guard max > 0 else { return "" }
        let end = utf8.index(utf8.startIndex, offsetBy: max)
        // String subscripting rounds a mid-scalar index down to the scalar boundary, so the result is valid UTF-8.
        return String(text[..<end])
    }

    /// First non-whitespace byte of `text` without copying it (cheap "could this be JSON?" checks on huge outputs).
    static func firstNonSpaceByte(_ text: String) -> UInt8? {
        for byte in text.utf8 where !(byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09) { return byte }
        return nil
    }

    /// FNV-1a over UTF-8 (probe signatures, spec 03 §7.6).
    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in text.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return hash
    }
}
