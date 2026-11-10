// [share] What the app leaves in the App Group for the sheet, and what the sheet leaves for the app
// (docs/spec/3x-share.md §5.1). Port of build 240's DispatchShareKit.swift: the JSON is the same, so files written by
// build 240 are read after the update.

import Foundation

/// One bot the sheet offers: names and routing ids only, never a message, a preview or a credential.
nonisolated struct ShareBot: Codable, Equatable, Identifiable, Sendable {
    /// The roster key (`ios-direct::ivy`; build 240 also wrote `legacy::ivy`).
    let key: String
    /// What people read ("Ivy").
    let name: String
    /// The gateway profile its chat lives on ("ivy", "default").
    let profile: String
    /// The stored id of its Bot Chat (the lineage tip), or "" while it has none yet (the app creates it on first open).
    let session: String
    /// "#rrggbb", or "" for the system tint.
    let color: String
    /// A small picture in the shared folder's `avatars/`, when the bot has one.
    let avatar: String?
    /// When its chat was last active (Unix seconds).
    let lastActive: Double?

    init(key: String, name: String, profile: String, session: String, color: String = "", avatar: String? = nil, lastActive: Double? = nil) {
        self.key = key; self.name = name; self.profile = profile; self.session = session
        self.color = color; self.avatar = avatar; self.lastActive = lastActive
    }

    var id: String { key }
    var initial: String { name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?" }
    /// A share needs the bot's own Bot Chat: the extension never creates one (spec D17, §7.10).
    var canReceive: Bool { ShareRules.validSession(session) && ShareRules.validProfile(profile) }
}

nonisolated struct ShareRoster: Codable, Equatable, Sendable {
    var version = 1
    /// The account the roster belongs to: `StoredAccount.key` (gateway address and username, never a secret).
    let account: String
    let url: String
    let username: String
    /// The largest attachment the sheet sends (spec D5: 32 MiB from this app; build 240 wrote its own setting here).
    let limitBytes: Int
    let bots: [ShareBot]
    let savedAt: Double
    /// The gateway's name for the "Send to" header, written only while more than one gateway is saved (absent in a
    /// roster an older build wrote: it decodes as nil).
    let gateway: String?

    init(account: String, url: String, username: String, limitBytes: Int, bots: [ShareBot], savedAt: Double, gateway: String? = nil) {
        self.account = account; self.url = url; self.username = username
        self.limitBytes = limitBytes; self.bots = bots; self.savedAt = savedAt; self.gateway = gateway
    }
}

/// What the extension leaves for the app after a send: which chat to open next time Hermes HQ comes to the front.
nonisolated struct ShareSent: Codable, Equatable, Sendable {
    let id: String
    let account: String
    let session: String
    let profile: String
    let botName: String
    let at: Double
}
