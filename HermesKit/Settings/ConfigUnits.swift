// [mac] Stress test 2026-10-28 #95, #101: how a config number reads on the Mac's Settings form. "100000" read as a code
// and Approval Timeout "60" said nothing about seconds; Compression Threshold showed 0.5 for half. Display only: what
// is written to Hermes is the same value as before (a percent field's 50 writes 0.5, as the page's own 0.5 did).
// Pure functions, so the words and the round trip are unit tested without a screen.

import Foundation

nonisolated enum ConfigUnits {
    enum Unit: Equatable, Sendable {
        /// A count of something: "60 seconds", "1 second".
        case count(String, String)
        /// A share kept as 0…1, shown and typed as a percent.
        case percent
    }

    static let units: [String: Unit] = [
        "model_context_length": .count("token", "tokens"),
        "approvals.timeout": .count("second", "seconds"),
        "terminal.timeout": .count("second", "seconds"),
        "auxiliary.compression.timeout": .count("second", "seconds"),
        "delegation.child_timeout_seconds": .count("second", "seconds"),
        "file_read_max_chars": .count("character", "characters"),
        "memory.memory_char_limit": .count("character", "characters"),
        "memory.user_char_limit": .count("character", "characters"),
        "tool_output.max_bytes": .count("byte", "bytes"),
        "tool_output.max_lines": .count("line", "lines"),
        "tool_output.max_line_length": .count("character", "characters"),
        "checkpoints.max_snapshots": .count("snapshot", "snapshots"),
        "agent.max_turns": .count("step", "steps"),
        "agent.api_max_retries": .count("retry", "retries"),
        "delegation.max_iterations": .count("turn", "turns"),
        "delegation.max_concurrent_children": .count("subagent", "subagents"),
        "compression.protect_last_n": .count("message", "messages"),
        "compression.threshold": .percent,
        "compression.target_ratio": .percent,
    ]

    /// The one word for a value that isn't set (#101: "Not Set", "None" and others meant the same).
    static let none = "None"

    /// [mac] Stress test 2026-10-28 round 6: what a blank text field means where blank isn't "none" (a field's
    /// placeholder said "None" beside help that says "Leave blank to use the main model").
    static func blank(key: String) -> String {
        switch key {
        case "delegation.model": "Main Model"
        case "delegation.provider": "Main Model’s Provider"
        default: none
        }
    }

    /// A number with the locale's grouping ("100,000"), at most three decimals.
    static func grouped(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 3
        return formatter.string(from: NSNumber(value: value)) ?? ConfigText.text(.number(value))
    }

    /// The number as a form's field shows it: grouped, a percent key as its percent ("50" for 0.5).
    static func fieldText(key: String, value: JSONValue?, locale: Locale = .current) -> String {
        guard let number = value?.double else { return ConfigText.text(value) }
        if units[key] == .percent { return grouped(number * 100, locale: locale) }
        return grouped(number, locale: locale)
    }

    /// What a typed field writes: the number, a percent key's back as its share (nil while it isn't a number).
    /// Grouping separators and a trailing "%" are allowed; an empty field is 0, as the page's editor treats it.
    static func value(key: String, text: String, locale: Locale = .current) -> JSONValue? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) }
        let number: Double
        if trimmed.isEmpty {
            number = 0
        } else {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            if let parsed = formatter.number(from: trimmed)?.doubleValue, parsed.isFinite {
                number = parsed
            } else if case .number(let plain)? = ConfigRenderer.numberValue(trimmed) {
                number = plain
            } else {
                return nil
            }
        }
        return .number(units[key] == .percent ? number / 100 : number)
    }

    /// The word after a field ("seconds", "%"), nil when the key has none.
    static func unitWord(key: String, value: Double?) -> String? {
        switch units[key] {
        case .count(let one, let many)?: value == 1 ? one : many
        case .percent?: "%"
        case nil: nil
        }
    }

    /// A number with its unit: "100,000 tokens", "60 seconds", "50%".
    static func display(key: String, value: Double, locale: Locale = .current) -> String {
        switch units[key] {
        case .percent?: return grouped(value * 100, locale: locale) + "%"
        case .count?: return grouped(value, locale: locale) + " " + (unitWord(key: key, value: value) ?? "")
        case nil: return grouped(value, locale: locale)
        }
    }

    /// The Mac's summary of a field: `ConfigRenderer.summary`, with numbers grouped and in their units and every empty
    /// value read as `none`.
    static func summary(_ field: ConfigFieldModel, locale: Locale = .current) -> String {
        let plain = ConfigRenderer.summary(field)
        if plain == "Not Set" { return none }
        guard field.control == .number, let number = field.value?.double, plain != "Automatic",
              VoiceSettingsCatalog.units[field.key] == nil else { return plain }
        return display(key: field.key, value: number, locale: locale)
    }

    /// A label without the unit it carried in brackets ("Compression Model Timeout (s)"): the unit is beside the value.
    static func label(_ label: String, key: String) -> String {
        guard units[key] != nil, label.hasSuffix(" (s)") else { return label }
        return String(label.dropLast(4))
    }

    /// Help text that reads as a sentence: a full stop at the end when it has none (#101).
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?…:”\"".contains(last) else { return trimmed }
        // [mac] Stress test 2026-10-28 #101: "(Sonnet, Opus, Haiku)" closes a sentence too; "(… here.)" already ends.
        if last == ")", let before = trimmed.dropLast().last, ".!?".contains(before) { return trimmed }
        return trimmed + "."
    }
}
