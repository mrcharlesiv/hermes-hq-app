// The one-minute request a shortcut leaves for the app (docs/spec/3x-intents.md §7.1; a port of build 240's
// `VoiceNoteRequestStore`, W:ios/App/App/VoiceNoteIntent.swift:50-83). Same UserDefaults key and JSON as the web app,
// so a request written by either is read by the other across an update. Durable on purpose: the shortcut may run
// before the app's scene exists; the expiry stops a request that waited behind sign-in or a restart from recording
// much later.

import Foundation

nonisolated struct VoiceNoteRequest: Codable, Equatable, Sendable {
    let id: String
    /// `url + "\n" + username` of the account the shortcut's bot belongs to.
    let account: String
    /// `"ios-direct::" + profile`.
    let key: String
    /// The bot's name when the shortcut ran (for the words on screen only; never matched on).
    let name: String
    /// Milliseconds since 1970.
    let expiresAt: Double
}

nonisolated final class VoiceNoteRequestStore {
    static let storageKey = "dispatch.voice.request"
    /// How long a request lives (ms).
    static let lifetime: Double = 60_000

    private let defaults: UserDefaults
    private let now: () -> Double

    init(defaults: UserDefaults = .standard, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.defaults = defaults
        self.now = now
    }

    /// The waiting request. One that expired, or whose expiry is further away than a request can be (edited storage,
    /// DECISION I16), is cleared and reads as none.
    var pending: VoiceNoteRequest? {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            // Anything else under the key (a string, a number) is not ours: gone.
            if defaults.object(forKey: Self.storageKey) != nil { clear() }
            return nil
        }
        guard let request = try? JSONDecoder().decode(VoiceNoteRequest.self, from: data),
              !request.id.isEmpty, request.expiresAt.isFinite else { clear(); return nil }
        let time = now()
        guard request.expiresAt > time, request.expiresAt <= time + Self.lifetime else { clear(); return nil }
        return request
    }

    /// A new request; it replaces any earlier one.
    @discardableResult func enqueue(account: String, key: String, name: String) -> VoiceNoteRequest {
        let request = VoiceNoteRequest(id: UUID().uuidString, account: account, key: key, name: name,
                                       expiresAt: now() + Self.lifetime)
        defaults.set(try? JSONEncoder().encode(request), forKey: Self.storageKey)
        return request
    }

    /// Clears the request only if it is still this one: a newer request survives an old acknowledgement.
    func acknowledge(_ id: String) {
        if pending?.id == id { clear() }
    }

    func clear() { defaults.removeObject(forKey: Self.storageKey) }
}
