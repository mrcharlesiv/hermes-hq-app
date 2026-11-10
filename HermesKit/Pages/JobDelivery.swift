// [jobs] Where a job delivers (docs/spec/3x-jobs.md §6.8): the gateway's targets (`GET /api/cron/delivery-targets`),
// the comma-joined value (`parseCronDeliveryTargets` / `toggleCronDeliveryTarget`, vendor app/cron/cron-job-model.ts:
// 82-103) and the rows the editor shows (`DeliverCheckboxes`, index.tsx:1016-1063, with the phone's wording and its
// leave-out rule, build/stress-c-gates.ts:47-48).

import Foundation

nonisolated struct DeliveryTarget: Hashable, Sendable, Codable, Identifiable {
    var id: String
    var name: String
    /// A platform without a cron home channel is listed but cannot be chosen.
    var homeTargetSet: Bool
    var homeEnvVar: String?

    init(id: String, name: String, homeTargetSet: Bool = true, homeEnvVar: String? = nil) {
        self.id = id; self.name = name; self.homeTargetSet = homeTargetSet; self.homeEnvVar = homeEnvVar
    }

    /// Lenient: an entry without an id is dropped, a missing name falls back to the id, `home_target_set` may be a
    /// bool, a number or a string; absent means set (the web's `home_target_set !== false`).
    init?(json: JSONValue) {
        guard let id = json["id"]?.pgString?.pgTrim, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.pgString?.pgTrim ?? ""
        switch json["home_target_set"] {
        case .bool(let set)?: homeTargetSet = set
        case .number(let n)?: homeTargetSet = n != 0
        case .string(let s)?: homeTargetSet = !["false", "0", "no", ""].contains(s.lowercased())
        default: homeTargetSet = true
        }
        homeEnvVar = json["home_env_var"]?.string
    }

    /// `{"targets":[…]}` (or a bare list), duplicates by id dropped.
    static func list(_ json: JSONValue) -> [DeliveryTarget] {
        var seen = Set<String>()
        return (json["targets"]?.array ?? json.array ?? []).compactMap(DeliveryTarget.init(json:)).filter { seen.insert($0.id).inserted }
    }
}

/// One row of "Deliver to".
nonisolated struct DeliveryRow: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    /// "Set a home channel first" under a platform that cannot be chosen.
    var note: String?
    var selectable: Bool
    var checked: Bool
}

nonisolated enum JobDelivery {
    static let fallback = "local"
    /// `local`: every run is kept in the job's Run History anyway, so the words say it goes nowhere else
    /// (2026-10-31, was "Saved in Run History"; the owner: the page and the editor should match).
    static let localLabel = "Run History Only"
    static let needsHomeChannel = "Set a home channel first"
    /// The words the job page and the editor share (D-J8).
    static let labels = ["local": localLabel]

    /// The chosen targets, in order, without repeats; nothing chosen means local.
    static func parse(_ value: String) -> [String] {
        var seen = Set<String>()
        let targets = value.split(separator: ",").map { String($0).pgTrim }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return targets.isEmpty ? [fallback] : targets
    }

    /// Checks or unchecks one target. The last checked one cannot be unchecked.
    static func toggle(_ value: String, _ target: String, checked: Bool) -> String {
        let targets = parse(value)
        if checked { return (targets.contains(target) ? targets : targets + [target]).joined(separator: ",") }
        if !targets.contains(target) || targets.count == 1 { return targets.joined(separator: ",") }
        return targets.filter { $0 != target }.joined(separator: ",")
    }

    /// The editor's tap on a row: Run History Only (`local`) is a choice of its own (every run is kept in Run History
    /// anyway, so "local" beside a place means nothing more); any other row is checked or unchecked beside the other
    /// places, and unchecking the last one leaves Run History Only.
    static func pick(_ value: String, _ target: String) -> String {
        if target == fallback { return fallback }
        var places = parse(value).filter { $0 != fallback }
        if let index = places.firstIndex(of: target) { places.remove(at: index) } else { places.append(target) }
        return places.isEmpty ? fallback : places.joined(separator: ",")
    }

    /// The editor's rows in its groups: places (Run History Only, the platforms, routes kept from the job), the bots'
    /// chats, and the platforms that cannot be chosen until they have a home channel (named in a line, not as rows).
    static func groups(_ rows: [DeliveryRow]) -> (places: [DeliveryRow], bots: [DeliveryRow], needsHome: [String]) {
        var places: [DeliveryRow] = [], bots: [DeliveryRow] = [], needsHome: [String] = []
        for row in rows {
            if !row.selectable && !row.checked { needsHome.append(row.title) }
            else if row.id.hasPrefix("bot-chat:") { bots.append(row) }
            else { places.append(row) }
        }
        return (places, bots, needsHome)
    }

    /// Run History Only is checked only when nothing else is (a job saved as "local,telegram" sends to Telegram, and
    /// keeps every run in Run History as any job does). What is shown only: the value is sent as it was until changed.
    static func historyOnlyBeside(_ rows: [DeliveryRow]) -> [DeliveryRow] {
        guard rows.contains(where: { $0.checked && $0.id != fallback }) else { return rows }
        return rows.map { row in
            var row = row
            if row.id == fallback { row.checked = false }
            return row
        }
    }

    /// "Discord needs a home channel first." / "Discord and Slack need…": nil when every platform has one.
    static func needsHomeNote(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "\(list) \(names.count == 1 ? "needs" : "need") a home channel first: send /sethome in the chat that should get results."
    }

    /// Two values that deliver to the same places (order and repeats aside).
    static func same(_ a: String, _ b: String) -> Bool { parse(a) == parse(b) }

    /// The name of one listed target.
    static func title(_ target: DeliveryTarget, botNames: [String: String]) -> String {
        if target.id == "local" { return localLabel }
        if target.id.hasPrefix("bot-chat:") {
            let profile = String(target.id.dropFirst("bot-chat:".count))
            if let name = botNames[profile], !name.isEmpty { return "Bot Chat (\(name))" }
            let given = target.name.isEmpty ? "Bot Chat (\(profile))" : target.name
            return JobWords.readableTargetName(given)
        }
        if let known = JobWords.platformNames[target.id] { return known }
        return target.name.isEmpty ? JobWords.titleCase(target.id) : target.name
    }

    /// The rows: the gateway's targets in its order (local first), minus a platform without a home channel when one of
    /// its chats, or the chat the job came from on it, is already chosen; then every chosen value the gateway no longer
    /// lists, kept so an edit never drops a saved route.
    static func rows(targets: [DeliveryTarget], value: String, origin: CronOrigin? = nil, chatNames: [String: String] = [:],
                     botNames: [String: String] = [:]) -> [DeliveryRow] {
        let selected = parse(value)
        var listed = targets
        if !listed.contains(where: { $0.id == "local" }) { listed.insert(DeliveryTarget(id: "local", name: "Local"), at: 0) }
        else if let index = listed.firstIndex(where: { $0.id == "local" }), index != 0 { listed.insert(listed.remove(at: index), at: 0) }
        let originPlatform = JobWords.known(origin?.platform)
        let shown = listed.filter { target in
            target.homeTargetSet || selected.contains(target.id)
                || !selected.contains { other in other.hasPrefix(target.id + ":") || (other == "origin" && originPlatform == target.id) }
        }
        var rows = shown.map { target -> DeliveryRow in
            let checked = selected.contains(target.id)
            let needsHome = target.id != "local" && !target.homeTargetSet
            // A platform already saved on the job stays uncheckable even without a home channel (the web's row is live).
            return DeliveryRow(id: target.id, title: title(target, botNames: botNames), note: needsHome ? needsHomeChannel : nil,
                               selectable: !needsHome || checked, checked: checked)
        }
        let known = Set(listed.map(\.id))
        var names = chatNames
        for (profile, name) in botNames { names["bot-chat:\(profile)"] = name }
        for target in selected where !known.contains(target) {
            let title = JobWords.humanDeliverTarget(target, origin: origin, labels: labels, full: false, names: names)
            rows.append(DeliveryRow(id: target, title: title.isEmpty ? target : title, note: nil, selectable: true, checked: true))
        }
        return rows
    }
}
