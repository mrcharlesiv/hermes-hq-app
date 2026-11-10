// [device-access] Drafts' own rules for Device Access (docs/device-access.md), kept pure Foundation so they're
// unit-testable without UIKit: a `drafts.create` request's plan, the waiting list's 24-hour expiry and 20-draft cap,
// and the notification's words. App/DeviceAccess/DraftsStore.swift keeps the list on disk and opens one.

import Foundation

nonisolated extension DeviceAccess {
    /// One draft waiting on this phone (App/DeviceAccess/DraftsStore.swift keeps these, keyed by the request's id).
    struct Draft: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var kind: String   // "email" or "text"
        var to: [String]
        var cc: [String]
        var subject: String?
        var body: String
        var bot: String
        var createdAt: Date
    }

    static let draftTTL: TimeInterval = 24 * 3600
    static let draftCap = 20

    /// A `drafts.create` request's plan, or nil for a bad one (`kind` not email/text, nothing to send to, or no words).
    static func draftPlan(_ request: Request) -> (kind: String, to: [String], cc: [String], subject: String?, body: String)? {
        guard let kind = request.string("kind", max: 10), ["email", "text"].contains(kind) else { return nil }
        let to = request.strings("to", max: 20)
        guard !to.isEmpty else { return nil }
        guard let body = request.string("body", max: 10_000) else { return nil }
        let subject = kind == "email" ? request.string("subject", max: 200) : nil
        return (kind, to, request.strings("cc", max: 20), subject, body)
    }

    /// The waiting list after adding one (or just trimming): newest first, nothing over `draftTTL` old, at most
    /// `draftCap` kept.
    static func liveDrafts(_ drafts: [Draft], adding draft: Draft? = nil, now: Date = .now) -> [Draft] {
        var kept = drafts.filter { now.timeIntervalSince($0.createdAt) < draftTTL }
        if let draft { kept.removeAll { $0.id == draft.id }; kept.append(draft) }
        kept.sort { $0.createdAt > $1.createdAt }
        if kept.count > draftCap { kept.removeLast(kept.count - draftCap) }
        return kept
    }

    /// "Hermes wrote an email" / "Ann’s Bot wrote a text message".
    static func draftNotificationTitle(kind: String, bot: String) -> String {
        "\(bot.isEmpty ? "Hermes" : bot) wrote \(kind == "text" ? "a text message" : "an email")"
    }

    /// "To Ann: can you look at the budget tonight…".
    static func draftNotificationBody(to: [String], body: String) -> String {
        let who = to.first ?? "someone"
        let label = to.count > 1 ? "\(who) & \(to.count - 1) more" : who
        return "To \(label): \(draftSnippet(body))"
    }

    static func draftSnippet(_ text: String, words: Int = 8) -> String {
        let parts = text.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard parts.count > words else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.prefix(words).joined(separator: " ") + "…"
    }
}
