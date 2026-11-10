// [jobs] Job templates, "Start from" (docs/spec/3x-jobs.md §6.6): the gateway's blueprint catalog
// (`GET /api/cron/blueprints`) decoded leniently, the form's first values (`initialBlueprintValues`, vendor
// app/cron/blueprints.tsx:22-31; example defaults start empty, src/stress-c.tsx:16-21), the words for a choice
// (`templateOptionLabel`, src/audit-c-format.ts:350-363), a field's hint (`templateFieldHelp`, :367-371) and a field
// error without its code (`cleanBlueprintFieldError`, blueprints.tsx:35-37).

import Foundation

nonisolated struct BlueprintField: Hashable, Sendable, Codable, Identifiable {
    var name: String
    var type: String
    var label: String
    var defaultValue: String?
    var options: [String]
    var optional: Bool
    var strict: Bool
    var help: String

    var id: String { name }

    init(name: String, type: String = "text", label: String = "", defaultValue: String? = nil, options: [String] = [],
         optional: Bool = false, strict: Bool = true, help: String = "") {
        self.name = name; self.type = type; self.label = label; self.defaultValue = defaultValue; self.options = options
        self.optional = optional; self.strict = strict; self.help = help
    }

    init?(json: JSONValue) {
        guard case .object = json, let name = json["name"]?.pgString?.pgTrim, !name.isEmpty else { return nil }
        self.name = name
        type = json["type"]?.string?.pgTrim.lowercased() ?? "text"
        label = json["label"]?.pgString?.pgTrim ?? ""
        defaultValue = json["default"]?.pgString
        options = (json["options"]?.array ?? []).compactMap(\.pgString)
        optional = json["optional"]?.bool ?? false
        strict = json["strict"]?.bool ?? true
        help = json["help"]?.pgString ?? ""
    }

    /// The row's label: the field's own, else its name in words.
    var title: String { label.isEmpty ? JobWords.titleCase(name) : label }
}

nonisolated struct Blueprint: Hashable, Sendable, Codable, Identifiable {
    var key: String
    var title: String
    var description: String
    var category: String
    var fields: [BlueprintField]

    var id: String { key }

    init(key: String, title: String, description: String = "", category: String = "", fields: [BlueprintField] = []) {
        self.key = key; self.title = title; self.description = description; self.category = category; self.fields = fields
    }

    /// Lenient: a missing `fields` is an empty list, a wrong-typed entry is dropped, never fatal.
    init?(json: JSONValue) {
        guard case .object = json, let key = json["key"]?.pgString?.pgTrim, !key.isEmpty else { return nil }
        self.key = key
        let named = json["title"]?.pgString?.pgTrim ?? ""
        title = named.isEmpty ? JobWords.titleCase(key) : named
        description = json["description"]?.pgString?.pgTrim ?? ""
        category = json["category"]?.pgString ?? ""
        var seen = Set<String>()
        fields = (json["fields"]?.array ?? []).compactMap(BlueprintField.init(json:)).filter { seen.insert($0.name).inserted }
    }

    static func list(_ json: JSONValue) -> [Blueprint] {
        var seen = Set<String>()
        return (json["blueprints"]?.array ?? json.array ?? []).compactMap(Blueprint.init(json:)).filter { seen.insert($0.key).inserted }
    }
}

nonisolated enum JobBlueprints {
    static let deliverField = "deliver"

    /// How a field is asked.
    enum Control: Equatable, Sendable { case time, choice, deliver, text }

    static func control(_ field: BlueprintField) -> Control {
        if field.name == deliverField { return .deliver }
        switch field.type {
        case "time": return .time
        // A choice field the catalog gave no choices is asked as text (never an empty menu).
        case "enum", "weekdays": return field.options.isEmpty ? .text : .choice
        default: return .text
        }
    }

    private static let exampleDefault = RX(#"^(?:an?|two or three|one or two|some)\s.*(?:\sor\s|,)"#, .caseInsensitive)

    /// A text default that describes what to type ("a product URL or exact flight/hotel/listing description").
    static func isExampleDefault(_ field: BlueprintField) -> Bool {
        field.type == "text" && exampleDefault.test((field.defaultValue ?? "").pgTrim)
    }

    /// The form's first values: each field's default, except the deliver slot's '' or 'origin' (the phone is not a
    /// chat a job can come from) → 'local', and an example default → ''.
    static func initialValues(_ blueprint: Blueprint) -> [String: String] {
        var out: [String: String] = [:]
        for field in blueprint.fields {
            let seeded = field.defaultValue ?? ""
            if field.name == deliverField && (seeded.isEmpty || seeded == "origin") { out[field.name] = "local" }
            else if isExampleDefault(field) { out[field.name] = "" }
            else { out[field.name] = seeded }
        }
        return out
    }

    private static let weekdayWords = ["everyday": "Every day", "weekdays": "Weekdays", "weekends": "Weekends"]

    /// A choice in words: "everyday" → "Every day", "sunday" → "Sunday", a start hour "7" → "7 AM", minutes between
    /// checks "30" → "Every 30 minutes"; anything else keeps its words with a capital.
    static func optionLabel(_ field: BlueprintField, _ option: String) -> String {
        let value = option.pgTrim
        if let words = weekdayWords[value] { return words }
        if let day = JobWords.days.first(where: { $0.lowercased() == value.lowercased() }) { return day }
        if let n = JobWords.int(value) {
            if field.name.hasSuffix("_hour") && n <= 23 { return "\(n % 12 == 0 ? 12 : n % 12) \(n < 12 ? "AM" : "PM")" }
            if RX.c(#"^interval_(?:min|minutes)$"#).test(field.name) { return n == 60 ? "Every hour" : "Every \(n) minutes" }
            if RX.c(#"^interval_(?:h|hours)$"#).test(field.name) { return n == 1 ? "Every hour" : (n == 24 ? "Once a day" : "Every \(n) hours") }
            return value
        }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    private static func capitalised(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// The hint under a field: a time follows the gateway computer's clock; "(24h)" is dropped; nothing for text
    /// fields (their hint is the placeholder) or the deliver slot (its rows explain themselves).
    static func fieldHelp(_ field: BlueprintField) -> String? {
        if field.name == deliverField { return nil }
        if field.type == "time" { return JobSchedule.clockNote }
        if control(field) == .text { return nil }
        let text = RX.c(#"\s*\(24h\)"#, .caseInsensitive).replace(field.help, with: "").pgTrim
        return text.isEmpty ? nil : capitalised(text)
    }

    /// A text field's placeholder: its help, else its label.
    static func placeholder(_ field: BlueprintField) -> String {
        let help = field.help.pgTrim
        return help.isEmpty ? field.title : capitalised(help)
    }

    /// "422: missing required value: time (What time?)" → "missing required value: time (What time?)".
    static func cleanFieldError(_ message: String) -> String {
        RX.c(#"^\d+:\s*"#).replace(message, with: "", all: false)
    }

    /// The field a gateway refusal names ("missing required value: time (", "interval_h='9' not allowed", "invalid time").
    static func fieldNamed(in error: String, of blueprint: Blueprint) -> String? {
        let names = blueprint.fields.map(\.name)
        if let hit = RX.c(#"missing required value:\s*([\w-]+)"#).exec(error)?[1], names.contains(hit) { return hit }
        if let hit = RX.c(#"^([\w-]+)="#).exec(error)?[1], names.contains(hit) { return hit }
        if RX.c(#"invalid time|a time is required"#, .caseInsensitive).test(error) { return blueprint.fields.first { $0.type == "time" }?.name }
        if RX.c(#"unknown recurrence"#, .caseInsensitive).test(error), names.contains("recurrence") { return "recurrence" }
        if RX.c(#"unknown day"#, .caseInsensitive).test(error), names.contains("day") { return "day" }
        return nil
    }

    /// "08:15" ↔ hour and minute. nil for anything that is not a 24 h time.
    static func time(_ value: String) -> (hour: Int, minute: Int)? {
        guard let match = RX.c(#"^(\d{1,2}):(\d{2})"#).exec(value.pgTrim), let hour = Int(match[1] ?? ""), let minute = Int(match[2] ?? ""),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    static func timeValue(hour: Int, minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    /// A non-optional field is still blank (Create waits).
    static func isIncomplete(_ blueprint: Blueprint, _ values: [String: String]) -> Bool {
        blueprint.fields.contains { !$0.optional && (values[$0.name] ?? "").pgTrim.isEmpty }
    }

    /// Title and description contain the words (the Blueprints section follows the Jobs search).
    static func matches(_ blueprint: Blueprint, _ words: String) -> Bool {
        words.isEmpty || blueprint.title.lowercased().contains(words) || blueprint.description.lowercased().contains(words)
    }
}
