// Who held control, remembered (docs/spec/3x-screen.md §5.8, §3.3). Hermes honours a viewer id only on the /api/ws
// connection that minted it and names a lease's holder by hash, so the phone keeps: this run's holds (to take the
// lease again with a new id after a reconnect) and one saved hold per bot (to offer "You were in control" after a
// relaunch). Also the kind of Screen a gateway gave (for the menu label) and the rotate hint's once-only flag.
// UserDefaults holds ids only, never content; a viewer id can do nothing but release its own hold.

import Foundation

nonisolated struct SavedHold: Codable, Equatable, Sendable {
    var id: String
    var hash: String
    var at: TimeInterval
}

@MainActor final class ScreenHolds {
    enum Leave: Equatable {
        /// Holding with the stream open: its close 1000 hands back.
        case closeHandsBack
        /// Release this id with force (holding with the stream down, or a hold saved by an earlier run).
        case release(id: String)
        case nothing
    }

    static let maxAge: TimeInterval = 24 * 60 * 60
    static let rotateHintKey = "hq.screen.rotateHintSeen"

    private let defaults: UserDefaults
    private let now: () -> Date
    /// This run's newest hold per `accountId|profile`. Empty after a relaunch, so nothing is reclaimed silently.
    private(set) var session: [String: ScreenViewer] = [:]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    static func key(_ account: String, _ profile: String) -> String { "\(account)|\(profile)" }
    static func heldKey(_ account: String, _ profile: String) -> String { "hq.screen.held.\(account).\(profile)" }
    static func kindKey(_ account: String) -> String { "hq.screen.kind.\(account)" }

    // MARK: Rules (the web's shouldReclaim / heldBefore / leaveBotScreen)

    /// After a re-observe minted a new id: the lease is a person's, not the new id's, and names an id this app held.
    static func shouldReclaim(prior: ScreenViewer?, minted: ScreenViewer, lease: ScreenLease?, own: ScreenViewer?) -> Bool {
        guard let lease, lease.holder == .human, let hash = lease.viewerHash, hash != minted.hash else { return false }
        return hash == prior?.hash || hash == own?.hash
    }

    /// The lease still names a hold saved by an earlier run and this attach does not hold it.
    static func heldBefore(saved: SavedHold?, lease: ScreenLease?, viewer: ScreenViewer?) -> SavedHold? {
        guard let saved, lease?.holder == .human, lease?.viewerHash == saved.hash else { return nil }
        return viewer?.hash == saved.hash ? nil : saved
    }

    static func leave(holding: Bool, streamOpen: Bool, viewer: ScreenViewer?, saved: SavedHold?) -> Leave {
        if holding, streamOpen { return .closeHandsBack }
        if holding, let viewer { return .release(id: viewer.id) }
        if let saved { return .release(id: saved.id) }
        return .nothing
    }

    // MARK: This run

    func own(_ account: String, _ profile: String) -> ScreenViewer? { session[Self.key(account, profile)] }
    func clearOwn(_ account: String, _ profile: String) { session[Self.key(account, profile)] = nil }

    /// Call whenever the lease or the viewer changes.
    func note(lease: ScreenLease?, viewer: ScreenViewer?, account: String, profile: String) {
        guard let lease else { return }
        if ScreenWire.holds(lease, viewer), let viewer {
            session[Self.key(account, profile)] = viewer
            if saved(account, profile)?.hash != viewer.hash { save(viewer, account, profile) }
        } else if lease.holder == .agent || (lease.viewerHash != nil && lease.viewerHash != saved(account, profile)?.hash) {
            // Known to be someone else's (or the bot's): the saved hold is over.
            forget(account, profile)
            if lease.holder == .agent { session[Self.key(account, profile)] = nil }
        }
    }

    // MARK: Saved

    func saved(_ account: String, _ profile: String) -> SavedHold? {
        let key = Self.heldKey(account, profile)
        guard let text = defaults.string(forKey: key) else {
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }       // not a string: ignore and clear
            return nil
        }
        guard let hold = try? JSONDecoder().decode(SavedHold.self, from: Data(text.utf8)), !hold.id.isEmpty, hold.hash == ScreenWire.viewerHash(hold.id) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        var age = now().timeIntervalSince1970 - hold.at
        #if DEBUG
        age += defaults.double(forKey: "HQScreenHoldAge")       // stress plan R9: a launch argument ages the hold
        #endif
        guard age >= 0, age < Self.maxAge else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return hold
    }

    func save(_ viewer: ScreenViewer, _ account: String, _ profile: String) {
        let hold = SavedHold(id: viewer.id, hash: viewer.hash, at: now().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(hold) { defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.heldKey(account, profile)) }
    }

    func forget(_ account: String, _ profile: String) { defaults.removeObject(forKey: Self.heldKey(account, profile)) }

    // MARK: The gateway's kind and the hint

    func rememberedKind(_ account: String) -> ScreenKind? {
        guard let kind = defaults.string(forKey: Self.kindKey(account)).flatMap(ScreenKind.init), kind != .unknown else { return nil }
        return kind
    }

    func rememberKind(_ kind: ScreenKind, _ account: String) {
        guard kind != .unknown, rememberedKind(account) != kind else { return }
        defaults.set(kind.rawValue, forKey: Self.kindKey(account))
    }

    var rotateHintSeen: Bool {
        get { defaults.bool(forKey: Self.rotateHintKey) }
        set { defaults.set(newValue, forKey: Self.rotateHintKey) }
    }
}
