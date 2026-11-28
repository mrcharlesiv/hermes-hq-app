// Waiting on teammates (Hermes 0.23.3+, `bot_delivery.list`, `apps/desktop/src/plugins/hermes-bots/teammate-waits.tsx`):
// read-only strip above a bot's Bot Chat composer listing every `message_agent` delivery from that bot that has not
// settled yet. Never resends automatically; `unknown_outcome` tells the user to open the teammate's chat first.

import Foundation

nonisolated enum BotDeliveryState: String, Sendable, Equatable, Codable {
    case queued
    case claimed
    case working
    case waitingOnYou = "waiting_on_you"
    case failed
}

nonisolated struct BotDeliveryRow: Sendable, Equatable, Identifiable {
    var deliveryId: String
    var target: String
    var targetHandle: String
    var state: BotDeliveryState
    /// Receipt's last write time (epoch seconds).
    var since: Double
    var preview: String
    /// Set for `.waitingOnYou` (e.g. `"clarify"` or `"approval"`).
    var waitingOn: String?
    /// Typed failure code for `.failed` (e.g. `"unknown_outcome"`, `"runtime_offline"`).
    var reason: String?
    var error: String?

    var id: String { deliveryId }
    var isUnknownOutcome: Bool { state == .failed && reason == "unknown_outcome" }
    var needsAttention: Bool { state == .waitingOnYou || state == .failed }
    var isActive: Bool { state == .queued || state == .claimed || state == .working }

    init(deliveryId: String, target: String, targetHandle: String, state: BotDeliveryState, since: Double,
         preview: String, waitingOn: String? = nil, reason: String? = nil, error: String? = nil) {
        self.deliveryId = deliveryId
        self.target = target
        self.targetHandle = targetHandle
        self.state = state
        self.since = since
        self.preview = preview
        self.waitingOn = waitingOn
        self.reason = reason
        self.error = error
    }

    init?(json: JSONValue) {
        guard let deliveryId = json["delivery_id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deliveryId.isEmpty,
              let target = json["target"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty,
              let rawState = json["state"]?.string,
              let state = BotDeliveryState(rawValue: rawState) else { return nil }
        let handle = json["target_handle"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let since = json["since"]?.double ?? 0
        let preview = json["preview"]?.string ?? ""
        self.init(
            deliveryId: deliveryId,
            target: target,
            targetHandle: handle.isEmpty ? target : handle,
            state: state,
            since: since.isFinite ? since : 0,
            preview: preview,
            waitingOn: json["waiting_on"]?.string,
            reason: json["reason"]?.string,
            error: json["error"]?.string
        )
    }

    /// Plain words for a failed row's typed reason (`teammate-waits.tsx::failureReasonText`).
    var failureReasonText: String {
        if let reason, reason != "unknown", let words = Self.reasonWords[reason] {
            return words
        }
        let trimmed = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown error" : trimmed
    }

    var statusLine: String {
        switch state {
        case .queued:
            return "Queued"
        case .claimed:
            return "Picked up"
        case .working:
            return "Working"
        case .waitingOnYou:
            return waitingOn == "clarify"
                ? "Waiting on you — answer question"
                : "Waiting on you — approve or deny"
        case .failed:
            return isUnknownOutcome ? "Outcome unknown" : "Failed: \(failureReasonText)"
        }
    }

    static let neverResentNotice = "Items here are never resent automatically. Outcome unknown means the teammate may already have acted — open its chat before asking again."

    static let reasonWords: [String: String] = [
        "provider_auth_or_access": "Model provider rejected the key",
        "provider_quota_limit": "Provider is out of credits",
        "provider_rate_limit": "Provider rate limit",
        "provider_server_error": "Provider couldn’t be reached",
        "missing_config": "No model configured",
        "model_unavailable": "Model unavailable",
        "context_overflow": "Context limit reached",
        "runtime_offline": "Teammate offline",
        "queued_expired": "Never picked up",
        "delivery_timeout": "Timed out",
        "agent_blocked": "Blocked",
        "cancelled": "Cancelled",
        "unknown_outcome": "Outcome unknown",
    ]

    /// Compact elapsed age ("<1m", "5m", "2h", "3d").
    static func compactAge(since: Double, now: Double) -> String {
        guard since > 0, now >= since else { return "<1m" }
        let seconds = Int(now - since)
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

/// Persisted dismissed failure IDs (keyed with dismiss timestamps so trimming keeps the newest 256).
@MainActor final class TeammateWaitsStore {
    static let shared = TeammateWaitsStore()
    private static let key = "hermes.teammate-waits.dismissed"
    private let defaults: UserDefaults
    private var dismissedAt: [String: Double]
    var dismissed: Set<String> { Set(dismissedAt.keys) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let dict = defaults.dictionary(forKey: Self.key) as? [String: Double] {
            self.dismissedAt = dict
        } else if let legacy = defaults.stringArray(forKey: Self.key) {
            let now = Date().timeIntervalSince1970
            var migrated: [String: Double] = [:]
            for (idx, id) in legacy.enumerated() where !id.isEmpty {
                migrated[id] = now - Double(legacy.count - idx)
            }
            self.dismissedAt = migrated
        } else {
            self.dismissedAt = [:]
        }
    }

    func dismiss(_ deliveryId: String, now: Double = Date().timeIntervalSince1970) {
        guard !deliveryId.isEmpty, dismissedAt[deliveryId] == nil else { return }
        dismissedAt[deliveryId] = now
        if dismissedAt.count > 256 {
            let newest = dismissedAt.sorted { $0.value > $1.value }.prefix(256)
            dismissedAt = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        defaults.set(dismissedAt, forKey: Self.key)
    }

    /// Only failed rows can be dismissed; active or waiting rows always remain visible.
    func visible(_ rows: [BotDeliveryRow]) -> [BotDeliveryRow] {
        rows.filter { $0.state != .failed || dismissedAt[$0.deliveryId] == nil }
    }
}

nonisolated enum TeammateWaitsAPI {
    /// Result of polling `bot_delivery.list` for a sender bot profile.
    enum Outcome: Sendable, Equatable {
        case rows([BotDeliveryRow])
        /// The gateway does not implement `bot_delivery.list` (`-32601`): stop polling this session.
        case unsupported
    }

    static func list(client: any GatewayClient, profile: String?) async throws -> Outcome {
        let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let params: JSONValue = trimmed.isEmpty ? .object([:]) : .object(["profile": .string(trimmed)])
        do {
            let result = try await client.call("bot_delivery.list", params, timeout: .seconds(10))
            let rows = (result["deliveries"]?.array ?? []).compactMap(BotDeliveryRow.init(json:))
            return .rows(rows)
        } catch let error as RPCError where error.code == -32601 {
            return .unsupported
        }
    }
}
