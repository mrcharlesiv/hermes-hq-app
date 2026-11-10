// [share] Which bots the share sheet offers, and what it is told about each (docs/spec/3x-share.md §7.5).
// Port of build 240's src/share-roster.ts:38-70 and ios/App/App/DispatchShare.swift:19-43. Pure.
//
// The roster holds names and routing ids only: never a message, a preview, a cookie or a token. Ghost and remote rows
// do not exist in the native roster (one gateway's profiles.list); if a later stream adds remote bots to `Bot`, they
// must be skipped here.

import Foundation
import CryptoKit

nonisolated enum ShareRosterRows {
    struct Draft: Equatable, Sendable {
        var key: String
        var name: String
        var profile: String
        /// The stored id of its Bot Chat, or "" while it has none (the sheet shows it disabled).
        var session: String
        var lastActive: Double?
        /// What its face is drawn from: changes exactly when the picture would.
        var imageKey: String
    }

    /// In the Bots list's own order: hidden bots, invalid profiles and empty names left out; at most 200.
    static func rows(_ bots: [Bot]) -> [Draft] {
        var rows: [Draft] = []
        for bot in bots {
            guard rows.count < ShareRules.maxBots else { break }
            let name = String(bot.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ShareRules.maxNameLength))
            guard !bot.hidden, ShareRules.validProfile(bot.id), !name.isEmpty else { continue }
            let session = bot.canonicalSessionId.flatMap { ShareRules.validSession($0) ? $0 : nil } ?? ""
            let active = bot.lastActive?.timeIntervalSince1970 ?? 0
            rows.append(Draft(key: ShareRules.key(profile: bot.id), name: name, profile: bot.id, session: session,
                              lastActive: active > 0 ? active : nil, imageKey: imageKey(head: bot.head, profile: bot.id)))
        }
        return rows
    }

    /// Stable across launches (`Hasher` is not): "head:" + hex(SHA-256(the head record's sorted-keys JSON)), or of
    /// "default-matrix-4:" + profile for a bot that wears its default head. A dot-matrix record's JSON is hashed after
    /// "matrix-4:": its pictures from before the 20-across LEDs (under "matrix-3:", "matrix-2:" or its plain JSON, and a
    /// default head's under "default:" or "default-matrix:" to "default-matrix-3:" + profile) are drawn again.
    static func imageKey(head: JSONValue?, profile: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let source: Data
        if let head, head != .null, let json = try? encoder.encode(head) {
            source = head["theme"]?.string == "matrix" ? Data("matrix-4:".utf8) + json : json
        } else {
            source = Data(("default-matrix-4:" + profile).utf8)
        }
        return "head:" + hex(SHA256.hash(data: source))
    }

    /// The face's file in `avatars/`: 32 hex characters and `.png`, different for every account, bot and picture.
    static func avatarName(account: String, profile: String, imageKey: String) -> String {
        let digest = SHA256.hash(data: Data((account + "\n" + profile + "\n" + imageKey).utf8))
        return hex(digest.prefix(16)) + ".png"
    }

    static func bots(_ rows: [Draft], account: String) -> [ShareBot] {
        rows.map { row in
            ShareBot(key: row.key, name: row.name, profile: row.profile, session: row.session, color: "",
                     avatar: avatarName(account: account, profile: row.profile, imageKey: row.imageKey), lastActive: row.lastActive)
        }
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
