// What the Sessions search says: the field's placeholder (UX study 2026-10-19 #36: it named no scope), and the words
// when nothing matched (#28: a gateway search that failed read "No Results", so an older chat looked gone). Pure, so
// the choices are unit-tested without UIKit.

import Foundation

nonisolated enum SessionsSearchWords {
    static let searching = "Searching…"
    static let failedTitle = "Couldn’t Search Your Gateway"

    /// "Search Chats", or "Search Ivy’s Chats" while a chip picks one bot.
    static func placeholder(botName: String?) -> String {
        guard let name = botName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return "Search Chats" }
        return "Search \(name)’s Chats"
    }

    /// The empty list's words while a query is typed. `failed`: a profile's gateway search failed, so only the loaded
    /// chats were searched. A search that answered with no hits keeps "No Results".
    static func empty(query: String, searching inFlight: Bool, failed: Bool) -> (text: String, secondary: String?) {
        if inFlight { return (searching, nil) }
        if failed { return (failedTitle, "Showing loaded chats only, and none match “\(query)”.") }
        return ("No Results for “\(query)”", nil)
    }
}
