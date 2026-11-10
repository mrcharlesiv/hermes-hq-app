// [photoheads] The faces pushed alerts show (docs/spec/3x-photoheads.md §4.6). The notification extension cannot reach
// the roster, so the app keeps each bot's face where the extension reads it (Shared/PushFaces.swift: by gateway account
// and profile): the bot's photo when it wears one, its head otherwise. iOS draws a sender's picture in its own round
// shape, so the photo is handed over square.
//
// A face is saved under the key that names it (`BotFaces.faceKey`), so a bot whose face has not changed is never drawn
// or written again in one run. A photo is never saved as a head: one that is not in memory is read and decoded off the
// main actor, one bot at a time, and saved when it is ready. Nothing is decoded on the main actor here, whatever the
// size of the roster.

import UIKit

@MainActor final class PushFaceSaver {
    static let shared = PushFaceSaver()
    /// A sender's picture at 3× (DECISION D18).
    static let side: CGFloat = 120

    private struct Wanted: Equatable {
        let profile: String
        /// The face's key when it was asked for ("photo:<fingerprint>").
        let key: String
        let account: String
    }

    private let hub: NotificationHub
    private let faces: BotFaces
    /// The account whose faces may be saved now (the signed-in gateway's push owner).
    private let currentAccount: () -> String?
    private var waiting: [Wanted] = []
    private var working: Wanted?
    private var task: Task<Void, Never>?

    init(hub: NotificationHub = .shared, faces: BotFaces = .shared, currentAccount: @escaping () -> String? = { PushRegistrar.shared.owner }) {
        self.hub = hub
        self.faces = faces
        self.currentAccount = currentAccount
    }

    /// Whether every face asked for has been dealt with (tests).
    var isIdle: Bool { task == nil && waiting.isEmpty }

    /// The roster as it is now. Heads and photos already in memory are saved here; the other photos one by one, later.
    func save(_ bots: [Bot], account: String) {
        var later: [Wanted] = []
        for bot in bots {
            let key = faces.faceKey(profile: bot.id, raw: bot.head)
            let signature = Self.signature(key)
            guard hub.needsFace(profile: bot.id, signature: signature, account: account) else { continue }
            if !faces.showsPhoto(bot.id) {
                hub.saveFace(profile: bot.id, signature: signature, account: account) {
                    faces.headImage(profile: bot.id, raw: bot.head, side: Self.side, scale: 1, dark: false)
                }
            } else if let photo = faces.cachedPhoto(bot.id) {
                hub.saveFace(profile: bot.id, signature: signature, account: account) {
                    BotFaces.tile(photo, side: Self.side, scale: 1, shape: .square)
                }
            } else {
                let wanted = Wanted(profile: bot.id, key: key, account: account)
                if wanted != working { later.append(wanted) }
            }
        }
        // The newest roster replaces what was waiting: a bot that left, or whose face changed again, is not saved late.
        waiting = later
        if task == nil, !waiting.isEmpty {
            task = Task { [weak self] in await self?.run() }
        }
    }

    private func run() async {
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            working = next
            let copy = await faces.photoCopy(for: next.profile)
            working = nil
            // Still the same picture, for the account still signed in.
            if let copy, "photo:" + copy.fingerprint == next.key, currentAccount() == next.account {
                hub.saveFace(profile: next.profile, signature: Self.signature(next.key), account: next.account) {
                    BotFaces.tile(copy.image, side: Self.side, scale: 1, shape: .square)
                }
            }
            await Task.yield()
        }
        task = nil
    }

    /// What `NotificationHub.saveFace` remembers a saved face by (this run only).
    static func signature(_ key: String) -> Int {
        var hasher = Hasher()
        hasher.combine(key)
        return hasher.finalize()
    }
}
