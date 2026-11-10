// [diagnostics] Intervals Instruments can show (docs/spec/3x-diagnostics.md §10; the web shell's AppDelegate.swift
// signposters): Launch, Session (the saved sign-in's restore), Socket (ticket, handshake). The subsystem is the
// running app's own bundle id, so a trace filtered by the app shows them under either identity. An interval is
// begun and ended by name: a second begin of a name still open replaces it (the first never ends, as a dial that was
// abandoned should read), and an end with nothing open does nothing. No message carries text from a chat.

import Foundation
import MetricKit
import os
import Synchronization

nonisolated enum Signposts {
    static let subsystem = Bundle.main.bundleIdentifier ?? "ai.hermes.hqnative"

    enum Category: String, CaseIterable, Sendable {
        case launch = "Launch", session = "Session", socket = "Socket"
    }

    static let stability = Logger(subsystem: subsystem, category: "Stability")
    private static let posters: [Category: OSSignposter] =
        Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0, OSSignposter(subsystem: subsystem, category: $0.rawValue)) })
    /// MetricKit's own log: the launch interval mirrored here is attributed to the app in the daily summary.
    private static let metricKit = MXMetricManager.makeLogHandle(category: "Launch")
    private static let open = Mutex<[String: OSSignpostIntervalState]>([:])
    private static let counts = Mutex<[String: Int]>([:])

    /// Begins `name` ("Launch", "Restore", "Ticket", "Handshake"). `detail` is a short fixed word, never content.
    static func begin(_ category: Category, _ name: StaticString, detail: String = "") {
        guard let poster = posters[category] else { return }
        let state = poster.beginInterval(name, id: poster.makeSignpostID(), "\(detail, privacy: .public)")
        open.withLock { $0[key(category, name)] = state }
        if category == .launch { mxSignpost(.begin, log: metricKit, name: name) }
        count("begin", category, name)
    }

    /// Ends `name` with its outcome ("ok", "timeout", "tabs"…). Returns whether an interval was open.
    @discardableResult
    static func end(_ category: Category, _ name: StaticString, outcome: String = "") -> Bool {
        guard let poster = posters[category], let state = open.withLock({ $0.removeValue(forKey: key(category, name)) }) else { return false }
        poster.endInterval(name, state, "\(outcome, privacy: .public)")
        if category == .launch { mxSignpost(.end, log: metricKit, name: name) }
        count("end", category, name)
        return true
    }

    static func event(_ category: Category, _ name: StaticString) {
        posters[category]?.emitEvent(name)
        count("event", category, name)
    }

    /// How many of each were posted this run ("begin Socket.Ticket": 3): what a test and the DEBUG probe read, since
    /// nothing in the process can read a signpost back.
    static func posted() -> [String: Int] { counts.withLock { $0 } }
    static func isOpen(_ category: Category, _ name: StaticString) -> Bool { open.withLock { $0[key(category, name)] != nil } }

    private static func key(_ category: Category, _ name: StaticString) -> String { "\(category.rawValue).\(name)" }
    private static func count(_ what: String, _ category: Category, _ name: StaticString) {
        counts.withLock { $0["\(what) \(key(category, name))", default: 0] += 1 }
    }
}
