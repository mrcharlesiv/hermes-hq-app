// [presence] What a bot is doing outside its chat: its browser and its screen (spec 3x-presence §3.2). Carried on `Bot`
// (`Bot.presence`), built by `PresenceCenter` from gateway events and the browser plugin's list, drawn by the Bots rows.

import Foundation

/// What a bot is doing outside its chat (carried on `Bot`; nil there when empty, so an idle roster hashes as before).
nonisolated struct BotPresence: Hashable, Sendable {
    /// "Browsing example.com", "Using its browser", "Needs you in its browser", "You’re using its browser",
    /// "Handing you its browser…" (`BrowserCard.statusLine`); nil when its browser is not news.
    var browserLine: String?
    /// A screen tool started in the last 90 s and its reply has not finished.
    var usingComputer = false

    var isEmpty: Bool { browserLine == nil && !usingComputer }
}
