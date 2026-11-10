// What the Sessions list says while it has nothing to show because nothing has been read yet: Loading, or "Couldn’t
// Load Chats" with Try Again (UX study 2026-10-19 #27: a first launch said "No Sessions Yet" while the read was still
// out, and again after it failed, so the chats looked gone). Pure, so the choice is unit-tested without UIKit.

import Foundation

nonisolated enum SessionsLoadWords {
    static let loading = "Loading…"
    static let chatsTitle = "Couldn’t Load Chats"
    static let archivedTitle = "Couldn’t Load Archived Chats"
    static let busyReason = "Your gateway is busy, so your chats couldn’t load in time."
    static let defaultReason = "Your gateway couldn’t load your chats."

    /// The reason under the title, in words for a person (the Bots list's rules, `RosterStateCopy`): busy, waiting for
    /// the gateway, the gateway's own sentence, else the default. An HTTP status or an error dump is never shown.
    static func reason(for error: any Error) -> String {
        if RosterRules.isGatewayBusy(error) { return busyReason }
        if RosterRules.isGatewayNotConnected(error) { return RosterStateCopy.waitingReason }
        if let rpc = error as? RPCError {
            if rpc.isNotConnected || rpc.isConnectionLost { return RosterStateCopy.waitingReason }
            return RosterStateCopy.plain(rpc.message).flatMap { RosterStateCopy.sentence($0) } ?? defaultReason
        }
        return RosterStateCopy.words(for: error) ?? defaultReason
    }
}

/// What an empty Sessions list (or Show › Archived) shows in place of rows.
nonisolated enum SessionsEmptyState: Equatable, Sendable {
    /// Nothing has been read yet: the list is not known to be empty.
    case loading
    /// The read failed with nothing on hand: the reason, with Try Again.
    case failed(title: String, reason: String)
    /// The list was read and is empty (or is only filtered or searched empty): its usual words.
    case usual

    /// `holdsRows`: the store has chats on hand (read or cached, hidden ones included). Those mean the list was read
    /// once, so a later failure or a read in flight keeps the usual words. `retrying`: Try Again was tapped and its
    /// read has not answered yet.
    static func choose(_ state: SessionsLoadState, holdsRows: Bool, archived: Bool, retrying: Bool) -> SessionsEmptyState {
        guard !holdsRows else { return .usual }
        if retrying { return .loading }
        switch state {
        case .idle, .loading:
            return .loading
        case .failed(let message, _):
            return .failed(title: archived ? SessionsLoadWords.archivedTitle : SessionsLoadWords.chatsTitle, reason: message)
        case .ready:
            return .usual
        }
    }
}
