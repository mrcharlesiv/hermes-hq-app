// Bot unread dots (spec 02 §6.6–6.7): device-local activity baselines and unread markers, persisted per gateway
// account. Ported from `S/bot-unread-activity.ts` (createBotActivityTracker) and the marker half of
// `S/bot-unread-runtime.ts`. No gateway writes. Pure value type; the store persists it.

import Foundation

nonisolated struct BotUnreadState: Codable, Sendable, Hashable {
    /// Activity owner (profile name) → the newest canonical `last_active` this device has seen.
    var baselines: [String: Double] = [:]
    /// Profile → unread canonical ids (`hermes.desktop.unreadFinishedSessions`), ≤200 per profile.
    var markers: [String: [String]] = [:]

    static let maxBaselines = 2000
    static let maxMarkersPerProfile = 200

    init() {}

    // MARK: Reads

    /// A marker names one of the bot's chat ids.
    func isMarked(_ profile: RosterProfile) -> Bool {
        guard let bucket = markers[profile.name], !bucket.isEmpty else { return false }
        return profile.canonicalIds.contains { bucket.contains($0) }
    }

    /// The row's dot: marked, and the chat is not empty (`message_count === 0` reads "untouched", §6.6).
    func isUnread(_ profile: RosterProfile) -> Bool {
        isMarked(profile) && profile.canonicalSession?.messageCount != 0
    }

    // MARK: Transitions

    /// One full roster (`reconcile`): a bot whose chat is on screen is acknowledged; one with a baseline that its
    /// canonical `last_active` passed (and a non-empty chat) is marked; first sight only records the baseline.
    mutating func reconcile(_ roster: [RosterProfile], isVisible: (RosterProfile) -> Bool) {
        var next = baselines
        for profile in roster {
            guard let canonical = profile.canonicalSession, !profile.canonicalIds.isEmpty,
                  let stamp = canonical.lastActive, stamp >= 0 else { continue }
            let before = baselines[profile.name]
            if isVisible(profile) {
                acknowledgeMarkers(profile)
            } else if let before, stamp > before, canonical.messageCount != 0 {
                mark(profile)
            }
            next[profile.name] = max(before ?? 0, stamp)
        }
        if next.count > Self.maxBaselines {
            let current = Set(roster.map(\.name))
            for key in next.keys where !current.contains(key) && next.count > Self.maxBaselines { next[key] = nil }
        }
        baselines = next
    }

    /// Mark as Read / an open that applied fresh history: drop both ids' markers and advance the baseline.
    mutating func acknowledge(_ profile: RosterProfile) {
        remember(profile)
        acknowledgeMarkers(profile)
    }

    /// The user left the bot's chat having seen it through `seenThrough` (server seconds): later rosters do not mark the
    /// bot for activity up to then. `tolerance` covers the gap between a message's own time and the chat's
    /// `last_active` (stamped when the turn is stored). Without this, a roster read after leaving would see the user's
    /// own exchange (newer than the last roster read while the chat was on screen) as unseen activity.
    mutating func left(_ profile: String, seenThrough: Double, tolerance: Double = 2) {
        guard seenThrough.isFinite, seenThrough > 0 else { return }
        baselines[profile] = max(baselines[profile] ?? 0, seenThrough + tolerance)
    }

    /// A marker whose activity the user saw after all (the chat's own read reached the canonical `last_active`, within
    /// `tolerance`) is dropped; newer activity keeps it.
    mutating func acknowledgeIfSeen(_ profile: RosterProfile, seenThrough: Double, tolerance: Double = 2) {
        guard isMarked(profile), let stamp = profile.canonicalSession?.lastActive, stamp <= seenThrough + tolerance else { return }
        acknowledgeMarkers(profile)
    }

    /// Mark as Unread / newer activity: one durable marker on the registry id (`id || resolved_id`).
    mutating func mark(_ profile: RosterProfile) {
        guard let canonical = profile.canonicalSession else { return }
        let id = canonical.id.isEmpty ? (canonical.resolvedId ?? "") : canonical.id
        guard !id.isEmpty else { return }
        var bucket = markers[profile.name] ?? []
        if !bucket.contains(id) { bucket.append(id) }
        if bucket.count > Self.maxMarkersPerProfile { bucket.removeFirst(bucket.count - Self.maxMarkersPerProfile) }
        markers[profile.name] = bucket
    }

    private mutating func remember(_ profile: RosterProfile) {
        guard let stamp = profile.canonicalSession?.lastActive, stamp >= 0, stamp > (baselines[profile.name] ?? -1) else { return }
        baselines[profile.name] = stamp
    }

    private mutating func acknowledgeMarkers(_ profile: RosterProfile) {
        guard var bucket = markers[profile.name] else { return }
        let ids = Set(profile.canonicalIds)
        bucket.removeAll { ids.contains($0) }
        markers[profile.name] = bucket.isEmpty ? nil : bucket
    }
}
