// The app's side of per-bot Mute (port of the web app's src/ui-bots/bot-mute.ts, build 240): the live list for the
// signed-in gateway, saved where the notification extension reads it (Shared/BotMutes.swift), the rows' bell, the timed
// mutes ending on their own, and the one-time tip after the first mute. Local alerts and the reply peek ask `allows`.

import Foundation
import Observation

@MainActor @Observable
final class BotMuteCenter {
    static let shared = BotMuteCenter()
    /// The first mute's tip ("Muted on This iPhone") has shown (the web app's `dispatch.tip.bot-mute-scope`).
    static let tipSeenKey = "hermes.tip.bot-mute-scope"

    struct Storage {
        var load: () -> Data?
        var save: (Data?) -> Void
        static let keychain = Storage(load: { BotMuteKeychain.read() }, save: { BotMuteKeychain.write($0) })
    }

    private(set) var mutes: [String: BotMute]
    /// The signed-in gateway's account, as pushes name it (PushPolicy.owner).
    @ObservationIgnored var account: () -> String? = { PushRegistrar.shared.owner }
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listeners: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var expiry: Timer?

    init(storage: Storage = .keychain, defaults: UserDefaults = .standard) {
        self.storage = storage
        self.defaults = defaults
        mutes = BotMutes.pruned(BotMutes.decode(storage.load()))
        scheduleExpiry()
    }

    private func key(_ profile: String) -> String? {
        guard let account = account(), !account.isEmpty, !profile.isEmpty else { return nil }
        return BotMutes.key(account: account, profile: profile)
    }

    /// The bot's live mute on this gateway.
    func mute(of profile: String) -> BotMute? {
        guard let key = key(profile) else { return nil }
        return BotMutes.mute(mutes, key, now: now())
    }

    func isMuted(_ profile: String) -> Bool { mute(of: profile) != nil }

    /// Sets (or with nil clears) one bot's mute. Returns whether this was the first mute ever and its tip hasn't shown.
    @discardableResult
    func set(_ profile: String, _ mute: BotMute?) -> Bool {
        guard let key = key(profile) else { return false }
        var next = BotMutes.pruned(mutes, now: now())
        if let mute, mute.live(now()) { next[key] = mute } else { next[key] = nil }
        apply(next)
        return mute != nil && !defaults.bool(forKey: Self.tipSeenKey)
    }

    /// A swipe's or menu's Mute: Always; again: off. Returns whether the tip should show.
    @discardableResult
    func toggle(_ profile: String) -> Bool { set(profile, isMuted(profile) ? nil : .forever) }

    /// A deleted bot's mute goes with it (a new bot of that name starts unmuted).
    func clear(_ profile: String) { set(profile, nil) }

    func markTipSeen() { defaults.set(true, forKey: Self.tipSeenKey) }

    #if DEBUG
    /// UI tests start with no mutes and the tip unseen.
    func resetForTests() {
        defaults.removeObject(forKey: Self.tipSeenKey)
        apply([:])
        storage.save(nil)
    }
    #endif

    /// Whether a local alert (or the peek) of `kind` for `profile` may show.
    func allows(kind: String, profile: String) -> Bool {
        guard let account = account() else { return true }
        return BotMutes.allows(kind: kind, account: account, profile: profile, mutes: mutes, now: now())
    }

    // MARK: Listeners (the Bots list redraws its bells)

    @discardableResult func observe(_ change: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        listeners[token] = change
        return token
    }

    func stopObserving(_ token: UUID) { listeners[token] = nil }

    // MARK: Store

    private func apply(_ next: [String: BotMute]) {
        guard next != mutes else { return }
        mutes = next
        storage.save(next.isEmpty ? nil : BotMutes.encode(next))
        scheduleExpiry()
        for listener in listeners.values { listener() }
    }

    /// A timed mute ends on its own: its bell goes then, without a reload.
    private func scheduleExpiry() {
        expiry?.invalidate()
        expiry = nil
        guard let next = BotMutes.nextExpiry(mutes, now: now()) else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(BotMutes.pruned(self.mutes, now: self.now()))
                self.scheduleExpiry()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }
}
