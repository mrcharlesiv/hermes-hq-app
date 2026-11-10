// What Sign Out and Remove Gateway say before they run: the gateway by its given name, where the app goes next when
// other gateways are saved, and what this phone deletes for the account (`AppModel.finishSignOut`,
// `SettingsHub.purge`): its drafts, the messages that hadn't gone out yet (queued, or marked Not Delivered) and its
// voice memo recordings, counted when there are any. Bots and chats stay on the gateway.

import UIKit

@MainActor enum SignOutWords {
    /// What waits on this phone for an account and goes with it.
    static func pending(accountId: String) -> (unsent: Int, recordings: Int) {
        let unsent = QueueStash.shared.count(accountId: accountId) + LostSends.shared.count(accountId: accountId)
        let memos = MemoAccountStores.shared
        let recordings = memos.accountId == accountId ? (memos.drafts?.paths.count ?? 0) : MemoDraftStore.savedCount(accountId: accountId)
        return (unsent, recordings)
    }

    /// The Sign Out confirmation for the gateway in use. `next`: the gateway the app moves to (the most recently used
    /// other one), nil when it is the only one saved.
    static func signOut(accountId: String?, name: String, next: String?) -> (title: String, message: String) {
        let pending = accountId.map(pending(accountId:)) ?? (unsent: 0, recordings: 0)
        return signOut(name: name, next: next, unsent: pending.unsent, recordings: pending.recordings)
    }

    nonisolated static func signOut(name: String, next: String?, unsent: Int, recordings: Int) -> (title: String, message: String) {
        let lost = lost(unsent: unsent, recordings: recordings)
        let sentences: [String?] = [
            next.map { "\(name) leaves this list and Hermes HQ switches to \($0)." },
            lost.prefix(1).uppercased() + String(lost.dropFirst()) + " on this \(DeviceWord.name) are deleted.",
            "Your bots and chats stay on \(name). You can sign in again any time.",
        ]
        return ("Sign out of \(name)?", sentences.compactMap { $0 }.joined(separator: " "))
    }

    /// The Remove Gateway confirmation for a gateway that isn't in use.
    static func remove(_ row: GatewayAccountRow) -> String {
        let pending = pending(accountId: row.id)
        return remove(accountName: row.accountName, unsent: pending.unsent, recordings: pending.recordings)
    }

    nonisolated static func remove(accountName: String, unsent: Int, recordings: Int) -> String {
        "\(accountName) is signed out of this gateway on this \(DeviceWord.name), and "
            + lost(unsent: unsent, recordings: recordings) + " here are deleted. You can add it again."
    }

    /// "its drafts", or "its drafts, 2 unsent messages and 1 voice recording".
    nonisolated static func lost(unsent: Int, recordings: Int) -> String {
        var parts = ["its drafts"]
        if unsent > 0 { parts.append(unsent == 1 ? "1 unsent message" : "\(unsent) unsent messages") }
        if recordings > 0 { parts.append(recordings == 1 ? "1 voice recording" : "\(recordings) voice recordings") }
        guard parts.count > 1 else { return parts[0] }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}
