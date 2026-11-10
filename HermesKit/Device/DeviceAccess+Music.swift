// [device-access] Music's pure parts (App/DeviceAccess/MusicAccess.swift does the MediaPlayer work): whether a song,
// album, artist or playlist matches what a bot asked to play, and the shared `music.now`/`music.control` answer
// shape once the player's state and item are read.

import Foundation

nonisolated extension DeviceAccess {
    /// What `music.control` may do.
    enum MusicAction: String, Sendable { case play, pause, next, previous }

    /// The request's `action` (case-insensitive), or nil for a missing or unknown one. Audit 09-6: anything else
    /// ("stop", a typo) used to count as Play, and music started.
    static func musicAction(_ request: Request) -> MusicAction? {
        request.string("action", max: 20).flatMap { MusicAction(rawValue: $0.lowercased()) }
    }

    /// Whether a library item matches a play request: one of its names contains the query (case-insensitive),
    /// trimmed on both sides. Used for a song's title or artist, an album's or playlist's title, and so on.
    static func musicMatches(_ names: [String?], query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return names.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// `music.now`/`music.control`'s answer, once the player's state and now-playing item (if any) are read into
    /// plain values.
    static func musicAnswer(state: String, title: String?, artist: String?, album: String?, durationSeconds: Double?, positionSeconds: Double?) -> Answer {
        var result: [String: JSONValue] = ["state": .string(state)]
        if let title {
            var item: [String: JSONValue] = ["title": .string(title)]
            if let artist { item["artist"] = .string(artist) }
            if let album { item["album"] = .string(album) }
            if let durationSeconds { item["duration_s"] = .number(durationSeconds) }
            if let positionSeconds { item["position_s"] = .number(positionSeconds) }
            result["item"] = .object(item)
        }
        return .done(result)
    }
}
