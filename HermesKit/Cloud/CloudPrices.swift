// What a Hermes Cloud agent costs, the region nearest the phone, and Portal's cost estimate for an agent that exists.
//
// Nous Portal lists its sizes and prices only on its signed-in New Agent page, and its MCP server estimates only agents
// that already exist (`agents` cost_estimate needs agent_id), so the New Agent form's per-size table is the app's own:
// Nous's prices as its signed-in New Agent page showed them on 2026-11-04: Standard 2 GB $0.60/day, Pro 4 GB $1.08/day,
// Max 8 GB (100 GB disk) $2.50/day; stopped, $0.13/day for the 25 GB disk and $0.50/day for Max's 100 GB. Nous bills once a day in arrears, compute to the second plus storage, and a
// deploy needs $2 of credit (portal.nousresearch.com/cloud). A size the table doesn't know shows no price.

import Foundation

nonisolated struct CloudSize: Sendable, Equatable {
    var memory: String
    var cpus: Int
    /// Chats it runs at once (Portal's "concurrent sessions").
    var chats: Int
    /// USD per day while it runs.
    var perDay: Double
    /// USD per day while stopped: its disk only.
    var stoppedPerDay: Double = CloudPrices.stoppedPerDay
}

nonisolated enum CloudPrices {
    static let sizes: [String: CloudSize] = [
        // CPUs as Portal's own agent rows give them (2026-11-04: standard 2, pro 4); the write-ups said 4 and 8.
        "standard": CloudSize(memory: "2 GB", cpus: 2, chats: 10, perDay: 0.60),
        "pro": CloudSize(memory: "4 GB", cpus: 4, chats: 20, perDay: 1.08),
        "max": CloudSize(memory: "8 GB", cpus: 4, chats: 20, perDay: 2.50, stoppedPerDay: 0.50),
    ]
    /// USD per day while stopped, for the 25 GB disk Standard and Pro come with (a size that doesn't say).
    static let stoppedPerDay = 0.13
    /// Credit a deploy needs.
    static let minimumCredit = 2.0

    static func size(_ key: String?) -> CloudSize? { key.flatMap { sizes[$0.lowercased()] } }
    static var lowestPerDay: Double? { sizes.values.map(\.perDay).min() }

    /// "$0.56", "$2", "$17": cents only under $10, and only when there are any.
    static func dollars(_ amount: Double) -> String {
        if amount >= 10 { return "$\(Int(amount.rounded()))" }
        let cents = (amount * 100).rounded()
        return cents.truncatingRemainder(dividingBy: 100) == 0 ? "$\(Int(cents / 100))" : String(format: "$%.2f", cents / 100)
    }

    /// Running every day of a 30-day month.
    static func month(_ perDay: Double) -> Double { perDay * 30 }
}

/// Bot Screen on Hermes Cloud. Nous builds the desktop into the image of agents with 8 GB of memory or more and leaves it
/// out of smaller ones, where it can't be added (the Hermes desktop app's own words, hermes-agent 757705867a; on
/// 2026-11-04 it said so for the owner's 2 GB agent). The 8 GB size is Max, on Portal's New Agent page for any account,
/// paid by the day like Standard and Pro (no plan needed). Portal has no Screen switch: `set_feature` offers only `relay`.
nonisolated enum CloudScreen {
    static let minimumMB = 8192

    /// Whether an agent of this memory has Screen; nil when the memory isn't known.
    static func included(memoryMB: Int?) -> Bool? { memoryMB.map { $0 >= minimumMB } }

    /// The size among `choices` that comes with Screen (Max), drawn as its own wide card under the others.
    static func size(in choices: [String]) -> String? { choices.first { sizes.contains($0.lowercased()) } }
    static let sizes: Set<String> = ["max"]
}

/// The create schema's Fly regions, and which is nearest the phone (by its time zone: no location asked).
nonisolated enum CloudRegions {
    private static let southAmerica = ["America/Sao_Paulo", "America/Argentina", "America/Buenos_Aires", "America/Montevideo",
                                       "America/Santiago", "America/Lima", "America/Bogota", "America/Caracas", "America/La_Paz",
                                       "America/Asuncion", "America/Guayaquil", "America/Fortaleza", "America/Recife",
                                       "America/Bahia", "America/Belem", "America/Manaus", "America/Cuiaba", "America/Campo_Grande"]

    /// Nearest first, for this time zone; the first of those `choices` offers wins.
    static func preferred(_ zone: TimeZone) -> [String] {
        let id = zone.identifier
        let hours = Double(zone.secondsFromGMT(for: Date())) / 3600 - (zone.isDaylightSavingTime(for: Date()) ? 1 : 0)
        if southAmerica.contains(where: { id.hasPrefix($0) }) { return ["gru", "iad"] }
        if id.hasPrefix("America/") || id.hasPrefix("US/") || id.hasPrefix("Canada/") || id == "Pacific/Honolulu" {
            return hours <= -7 ? ["sjc", "iad"] : ["iad", "sjc"]
        }
        if id.hasPrefix("Australia/") || id.hasPrefix("Pacific/") { return ["syd", "nrt"] }
        if id.hasPrefix("Asia/") || id.hasPrefix("Indian/") {
            return hours >= 5 ? ["nrt", "sin", "syd", "lhr"] : ["lhr", "fra", "ams"]
        }
        if id.hasPrefix("Europe/") || id.hasPrefix("Africa/") || id.hasPrefix("Atlantic/") { return ["lhr", "ams", "fra", "cdg", "iad"] }
        return ["iad"]
    }

    static func closest(among choices: [String], zone: TimeZone = .current) -> String? {
        preferred(zone).first { choices.contains($0) }
    }
}

/// `agents` cost_estimate for one agent: what it has cost so far and what a month would cost. Portal's own numbers
/// (a dated Fly pricing snapshot, not a bill). The answer's shape isn't documented, so its keys are matched loosely.
nonisolated struct CloudSpend: Sendable, Equatable {
    var toDate: Double?
    var monthly: Double?

    static func read(_ value: JSONValue) -> CloudSpend? {
        var numbers: [(key: String, amount: Double)] = []
        collect(value, path: "", depth: 0, into: &numbers)
        func first(_ words: [String], not: [String] = []) -> Double? {
            numbers.first { entry in words.contains { entry.key.contains($0) } && !not.contains { entry.key.contains($0) } }?.amount
        }
        let monthly = first(["projectedmonth", "permonth", "monthly", "month"])
        let toDate = first(["todate", "sofar", "accrued", "incurred", "spent", "elapsed"], not: ["month", "hour", "day", "rate"])
        guard monthly != nil || toDate != nil else { return nil }
        return CloudSpend(toDate: toDate, monthly: monthly)
    }

    /// Every number (or "$1.23" string) under the answer, keyed by its path with the punctuation dropped.
    private static func collect(_ value: JSONValue, path: String, depth: Int, into out: inout [(key: String, amount: Double)]) {
        guard depth < 4 else { return }
        if let object = value.object {
            for key in object.keys.sorted() {
                let next = path + key.lowercased().filter { $0.isLetter || $0.isNumber }
                if let item = object[key] { collect(item, path: next, depth: depth + 1, into: &out) }
            }
        } else if let number = value.double {
            out.append((path, number))
        } else if let text = value.string, text.hasPrefix("$"), let number = Double(text.dropFirst().replacingOccurrences(of: ",", with: "")) {
            out.append((path, number))
        }
    }
}
