// [external-turn] A turn another Hermes process runs in this chat (docs/spec/03-chat-history.md §4.8).
//
// A message from another bot (`message_agent`), a Telegram or Discord message, or a job's hand-off runs in the messaging
// gateway (`hermes gateway run`), not in `hermes serve`, which the app talks to: `session.resume` says `running: false`,
// no turn frames come, and the chat looked idle while the bot worked for minutes (owner, 2026-10-27: "Herald messaged
// Hermes and I can't see that anything is happening"). Two signals say otherwise:
//   - the gateway's durable ledger (`session_admissions` / `worker_executions` in state.db) holds the work until it ends;
//     `hermes serve` refuses a typed send with `SESSION_OWNER_BUSY` from the same read. Hermes's API doesn't expose it:
//     the Hermes HQ add-on (0.9.6+, `GET sessions/working`) reads it for the app. Authoritative when present.
//   - without that add-on, the stored rows: the gateway writes each step as it goes, so a newest turn that ends on a
//     tool step (no words after it), or a stored prompt nobody answered yet, written recently, is still running.

import Foundation

/// The chat screen's view of it (the live session; demo fakes leave it out).
protocol ChatExternalWork: AnyObject {
    var externalWorking: Bool { get }
}

extension LiveChatSession: ChatExternalWork {}

nonisolated enum ExternalTurn {
    /// Where the "still running" came from (logs only).
    enum Source: String, Sendable { case ledger, history }

    /// The add-on's answer for this chat.
    enum LedgerAnswer: Sendable, Equatable {
        case working(Bool)
        /// 404: no add-on, or one older than 0.9.6.
        case missing
        case failed
    }

    static let ledgerPath = "/api/plugins/hermes-hq-push/sessions/working"
    /// A tool step with nothing after it counts as running this long after the newest stored row (a terminal command or
    /// a slow search writes nothing until it returns: 61 s for one search_files on 2026-10-27).
    static let toolWindow: TimeInterval = 600
    /// A stored prompt with no answer counts as running this long (the gateway writes its first step within seconds).
    static let promptWindow: TimeInterval = 120
    /// How often the transcript and the ledger are read while the other process works.
    @MainActor static var pollInterval: Duration = .seconds(3)
    /// A 404 is believed this long before the add-on is asked again (it may be updated meanwhile).
    static let missingRecheck: TimeInterval = 600

    /// Accounts whose add-on lacks the route, with when that was learned (main actor only).
    @MainActor static var ledgerMissingSince: [String: Date] = [:]

    /// The newest stored turn is still being written: its newest message (our own prompts aside) is a stored prompt
    /// with no answer, or the bot's steps with no words after the last one; and the newest stored row is recent.
    static func historyUnfinished(_ messages: [ChatMessage], newestStoredAt: Double?, now: Date) -> Bool {
        guard let newest = newestStoredAt else { return false }
        // Our own bubbles aside (a send waiting behind that turn); our own live reply still counts, so a turn of ours
        // that just ended in words never reads as unfinished.
        guard let last = messages.last(where: { !($0.isLocal && $0.role == .user) }) else { return false }
        let age = now.timeIntervalSince1970 - newest
        switch last.role {
        case .user:
            return age < promptWindow
        case .assistant:
            guard last.error == nil, !last.interrupted else { return false }
            let visible = last.parts.last { part in
                switch part {
                case .text(let t), .reasoning(let t): return !ChatText.trimmed(t).isEmpty
                case .tool: return true
                }
            }
            guard let visible else { return false }
            switch visible {
            case .tool, .reasoning: return age < toolWindow
            case .text: return false
            }
        default:
            // A notice ([SILENT], a model switch, a failed turn) ends what came before it.
            return false
        }
    }

    /// `{"sessions": [{"profile", "id", "status", "kind"}]}` → whether any row names one of `ids` (for `profile`).
    static func ledgerNames(_ json: JSONValue, ids: Set<String>, profile: String) -> Bool {
        let want = profile.isEmpty ? "default" : profile
        for row in json["sessions"]?.array ?? [] {
            guard let id = row["id"]?.string, ids.contains(id) else { continue }
            let p = row["profile"]?.string ?? ""
            if p.isEmpty || p == want { return true }
        }
        return false
    }
}
