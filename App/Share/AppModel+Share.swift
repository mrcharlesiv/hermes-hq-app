// [share] The app's half of the Share extension (docs/spec/3x-share.md §4.4, §7.5, §7.11): it keeps the App Group's
// roster and faces current for the sheet, clears them when nobody (or somebody else) is signed in, and opens the chat a
// share just went to when Hermes HQ next comes to the front.
//
// Every hook is a no-op in a build without the App Group (the native identity: `ShareStore()` is nil).

import Foundation

/// The chat a share just went to, taken once (spec §7.11). Apart from `AppModel` so a test can drive it with a
/// temporary folder and a fake opener.
@MainActor
enum ShareInbox {
    /// This build's App Group folder, looked up once (nil in the native identity).
    static let store: ShareStore? = ShareStore()

    /// `account`: the signed-in account's key (`StoredAccount.key`), asked only when a note is there; nil keeps the
    /// note for later (a cold launch can become active before the account is restored). The note is removed whatever
    /// it holds once somebody is signed in: too old, another account's or unreadable, it opens nothing.
    static func openIfAny(store: ShareStore?, account: () -> String?, open: (ShareSent) -> Void) {
        guard let store, store.hasSentNote, let key = account() else { return }
        guard let sent = store.takeSent(account: key) else { return }
        open(sent)
    }

    // MARK: Giving way (the note is taken either way: a share's chat is offered once, never later)

    /// When the person last asked for a chat themselves: a tapped alert, the peek, a hermes:// link.
    private(set) static var askedAt: Date?

    static func personAsked(now: Date = Date()) { askedAt = now }

    /// How long a chat the person asked for wins over a share's: as long as a tapped alert may still be waiting for the
    /// lists on a cold launch (`openNotifiedChat` waits up to 10 s), so the two can never land one after the other.
    static let givesWay: TimeInterval = 10
    /// How often the share's own open looks again while the tabs or the lists are not there yet (40 × 0.25 s).
    static let attempts = 40

    enum Step: Equatable { case open, wait, drop }

    /// What to do with the chat a share went to, `attempt` looks after its note was taken at `taken`.
    /// - `asked`: when the person last asked for a chat themselves. Theirs is the one to show, so the share's is dropped
    ///   when they asked around the time the app came forward (they tapped an alert or a link to get here) or since.
    /// - `ready`: the tabs are on screen and the lists know the chat (or have loaded and do not).
    /// - `sheetUp`: something is presented over the tabs (a New Bot form, a Settings editor, the share sheet of a
    ///   file). Opening a chat would throw it away without asking, unsaved input included: the share's chat is dropped.
    static func step(taken: Date, asked: Date?, ready: Bool, sheetUp: Bool, attempt: Int) -> Step {
        if let asked, asked >= taken.addingTimeInterval(-givesWay) { return .drop }
        guard ready else { return attempt < attempts ? .wait : .drop }
        return sheetUp ? .drop : .open
    }
}

extension AppModel {
    /// [settings] Largest Attachment changed in Settings: the Share sheet's roster carries the limit, so it is
    /// written again (the writer rewrites when `limitBytes` differs).
    private func watchAttachmentLimit() {
        if let old = AttachmentLimitWatch.token { NotificationCenter.default.removeObserver(old) }
        AttachmentLimitWatch.token = NotificationCenter.default.addObserver(forName: AttachmentLimit.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shareRosterChanged() }
        }
    }

    /// The Bots list changed: the sheet's roster follows within about a second.
    func shareRosterChanged() {
        // Bots painted from the disk cache count; an empty list counts once the gateway has answered.
        guard let account, botsLoaded || !bots.isEmpty else { return }
        // [share] With several gateways saved, the sheet's "Send to" names this one (UX study 2026-10-21 #271).
        let gateway = signIn.store.accounts.count > 1 ? settingsHub.currentTitle : nil
        ShareRosterWriter.shared.schedule(bots: bots, account: account.id, gateway: gateway)
        // [ask-bot] The Ask Bot shortcut's bots and Bot Chats, in both identities (it runs in the app, not the extension).
        if let stored = AccountVault.app.peek(), stored.hasSession, stored.gatewayAccount?.id == account.id {
            AskRoster.save(AskRoster.make(bots: bots, stored: stored, limit: Int(AttachmentStaging.maxItemBytes)))
        }
    }

    /// Sign Out, a gateway switch, a launch with nobody signed in: the sheet offers nobody until a roster is written
    /// for whoever signs in next. The remembered bot and an unopened last-sent note go too.
    func shareLeaving() {
        ShareRosterWriter.shared.clear()
        AskRoster.clear()                       // [ask-bot]
    }

    /// Signed in (launch restore, a fresh sign-in, a switch): a roster left by another account goes, this account's is
    /// written as soon as its bots are known, and a share made while the app was away opens its chat.
    func shareActivated(_ account: GatewayAccount) {
        guard ShareRosterWriter.shared.enabled else { return }
        if let key = signIn.store.stored(account)?.key { ShareRosterWriter.shared.clear(unlessFor: key) }
        watchAttachmentLimit()   // [settings]
        shareRosterChanged()
        openSharedChatIfAny()
    }

    /// Hermes HQ came to the front (or finished signing in): within 5 minutes of a share, that bot's chat opens, as a
    /// tapped alert would open it. Costs one file-exists check when there is no note.
    ///
    /// It gives way twice (`ShareInbox.step`): to a chat the person asked for themselves (the alert or link that
    /// brought the app forward), and to a sheet that is up, which opening a chat would throw away.
    func openSharedChatIfAny() {
        guard account != nil else { return }
        ShareInbox.openIfAny(store: ShareInbox.store, account: { AccountVault.app.peek()?.key }) { [weak self] sent in
            let taken = Date()
            // One turn later: a tapped alert or link delivered in the same turn as "became active" is heard first.
            DispatchQueue.main.async { self?.openSharedChat(sent, taken: taken) }
        }
    }

    private func openSharedChat(_ sent: ShareSent, taken: Date, attempt: Int = 0) {
        let root = MainTabController.current
        let known = botsLoaded || bots.contains { $0.canonicalSessionId == sent.session } || sessions.contains { $0.id == sent.session }
        switch ShareInbox.step(taken: taken, asked: ShareInbox.askedAt, ready: root?.view.window != nil && known,
                               sheetUp: root?.presentedViewController != nil, attempt: attempt) {
        case .wait:
            // A cold launch: the tabs are being put on screen, or the lists have not painted yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.openSharedChat(sent, taken: taken, attempt: attempt + 1)
            }
        case .drop:
            AppLog.note("share", "shared chat not opened")
        case .open:
            AppLog.note("share", "open shared chat")
            openNotifiedChat(stored: sent.session, profile: sent.profile)
        }
    }
}

/// [settings] The one observer of Largest Attachment for the Share roster (the newest signed-in model owns it).
@MainActor private enum AttachmentLimitWatch {
    static var token: NSObjectProtocol?
}
