// [proactivity-beta] Wire contract and REST client for the optional hermes-hq-proactive Beta plugin
// (mrcharlesiv/hermes-hq-plugins/hermes-hq-proactive). Off by default on the gateway; toggling it on or off
// calls PATCH /api/plugins/hermes-hq-proactive/settings for the chosen bot profile.

import Foundation

nonisolated enum ProactivityBeta {
    static let pluginName = "hermes-hq-proactive"
    static let pluginSource = "mrcharlesiv/hermes-hq-plugins/hermes-hq-proactive"
    static let pageLabel = "Proactivity (Beta)"
    static let route = "/api/plugins/hermes-hq-proactive"

    enum AutonomyMode: String, CaseIterable, Identifiable, Sendable {
        case observe, prep, full
        var id: String { rawValue }

        var title: String {
            switch self {
            case .observe: "Observe & Brief"
            case .prep: "Prep & Offer"
            case .full: "Prep + Urgent"
            }
        }

        var detail: String {
            switch self {
            case .observe: "Quiet open-loop tracking and a daily brief only (Tier 0)."
            case .prep: "Read-only checks, drafts, and structured offers within your daily budget (Tier 0–1)."
            case .full: "Prep & offers plus budgeted urgent alerts outside quiet hours (Tier 0–2)."
            }
        }
    }

    struct Status: Equatable, Sendable {
        var version: String
        var beta: Bool
        var enabled: Bool
        var autonomyMode: AutonomyMode
        var quietHoursActive: Bool
        var quietStart: String
        var quietEnd: String
        var offersUsed24h: Int
        var offersLimit24h: Int
        var interruptsUsed24h: Int
        var interruptsLimit24h: Int
        var pendingOffers: Int
        var openLoops: Int
        var snoozedLoops: Int
        var activeWatches: Int
        var inTurnEnabled: Bool
        var loopRadarEnabled: Bool
        var idleSweepEnabled: Bool
        var dailyBriefEnabled: Bool
        var patternDetectionEnabled: Bool
        var allowLlmInSweep: Bool

        static func parse(_ data: Data) throws -> Status {
            let root = try JSONValue.parse(data)
            return decode(root)
        }

        static func decode(_ root: JSONValue) -> Status {
            let budgets = root["budgets"]
            let counts = root["counts"]
            let settings = root["settings"]
            let rawMode = RosterText.trimmed(root["autonomy_mode"]) ?? RosterText.trimmed(settings?["autonomy_mode"]) ?? "prep"
            return Status(
                version: RosterText.trimmed(root["version"]) ?? "0.1.0-beta.1",
                beta: root["beta"]?.bool ?? true,
                enabled: root["enabled"]?.bool ?? settings?["enabled"]?.bool ?? false,
                autonomyMode: AutonomyMode(rawValue: rawMode.lowercased()) ?? .prep,
                quietHoursActive: root["quiet_hours_active"]?.bool ?? false,
                quietStart: RosterText.trimmed(settings?["quiet_start"]) ?? "22:00",
                quietEnd: RosterText.trimmed(settings?["quiet_end"]) ?? "08:00",
                offersUsed24h: budgets?["offers_used_24h"]?.int ?? 0,
                offersLimit24h: budgets?["offers_limit_24h"]?.int ?? 6,
                interruptsUsed24h: budgets?["interrupts_used_24h"]?.int ?? 0,
                interruptsLimit24h: budgets?["interrupts_limit_24h"]?.int ?? 2,
                pendingOffers: counts?["pending_offers"]?.int ?? 0,
                openLoops: counts?["open_loops"]?.int ?? 0,
                snoozedLoops: counts?["snoozed_loops"]?.int ?? 0,
                activeWatches: counts?["active_watches"]?.int ?? 0,
                inTurnEnabled: settings?["in_turn_enabled"]?.bool ?? true,
                loopRadarEnabled: settings?["loop_radar_enabled"]?.bool ?? true,
                idleSweepEnabled: settings?["idle_sweep_enabled"]?.bool ?? true,
                dailyBriefEnabled: settings?["daily_brief_enabled"]?.bool ?? true,
                patternDetectionEnabled: settings?["pattern_detection_enabled"]?.bool ?? true,
                allowLlmInSweep: settings?["allow_llm_in_sweep"]?.bool ?? true
            )
        }
    }

    struct SweepOutcome: Equatable, Sendable {
        var quiet: Bool
        var signalsDetected: Int
        var createdOffers: Int
        var tokensUsed: Int

        static func parse(_ data: Data) throws -> SweepOutcome {
            let root = try JSONValue.parse(data)
            return SweepOutcome(
                quiet: root["quiet"]?.bool ?? false,
                signalsDetected: root["signals_detected"]?.int ?? 0,
                createdOffers: root["created_offers"]?.int ?? 0,
                tokensUsed: root["tokens_used"]?.int ?? 0
            )
        }
    }

    /// Fallback page metadata when opening the plugin web page directly before a rescan lists it.
    static let fallbackPage = PluginDashboardPage(
        name: pluginName,
        label: pageLabel,
        description: "Opt-in Beta proactivity engine (off by default): open-loop radar, prepared drafts, daily brief, and adaptive calibration.",
        icon: "Sparkles",
        tabPath: "/proactive",
        entry: "dist/index.js",
        css: "dist/style.css",
        hasAPI: true,
        source: "plugin",
        version: "0.1.0-beta.1"
    )
}

nonisolated enum ProactivityBetaAPI {
    static func profileQuery(_ profile: String) -> [URLQueryItem] {
        DashboardPagesAPI.profileQuery(profile)
    }

    static func status(_ client: any GatewayClient, profile: String) async throws -> ProactivityBeta.Status {
        let data = try await client.rest("GET", "\(ProactivityBeta.route)/status", query: profileQuery(profile), body: nil)
        return try ProactivityBeta.Status.parse(data)
    }

    static func patchSettings(_ client: any GatewayClient, profile: String, fields: [String: JSONValue]) async throws -> ProactivityBeta.Status {
        let encoded = try JSONValue.object(fields).encoded()
        let data = try await client.rest("PATCH", "\(ProactivityBeta.route)/settings", query: profileQuery(profile), body: encoded)
        let root = try JSONValue.parse(data)
        if let statusObj = root["status"], case .object = statusObj {
            return ProactivityBeta.Status.decode(statusObj)
        }
        return try await status(client, profile: profile)
    }

    static func runSweep(_ client: any GatewayClient, profile: String, forceBrief: Bool) async throws -> ProactivityBeta.SweepOutcome {
        let encoded = try JSONValue.object(["force_brief": .bool(forceBrief)]).encoded()
        let data = try await client.rest("POST", "\(ProactivityBeta.route)/sweep", query: profileQuery(profile), body: encoded)
        return try ProactivityBeta.SweepOutcome.parse(data)
    }

    /// True when the gateway answered 404 on `/status` (plugin not installed, disabled, or routes not mounted yet).
    /// Hermes's runtime gate answers `404 {"detail":"Plugin not found"}` and FastAPI's fallback answers
    /// `404 {"detail":"Not Found"}`; `/status` itself never returns a domain 404.
    static func isRouteMissing(_ error: Error) -> Bool {
        guard let http = error as? HTTPError else { return false }
        return http.status == 404
    }

    static func errorWords(_ error: Error, fallback: String = "Couldn’t reach Hermes.") -> String {
        if let http = error as? HTTPError {
            if let body = http.body, let data = body.data(using: .utf8), let parsed = try? JSONValue.parse(data),
               let detail = RosterText.trimmed(parsed["detail"]) ?? RosterText.trimmed(parsed["error"]) ?? RosterText.trimmed(parsed["message"]),
               !detail.isEmpty {
                return detail
            }
            return "Hermes answered HTTP \(http.status)."
        }
        return (error as? LocalizedError)?.errorDescription ?? fallback
    }
}
