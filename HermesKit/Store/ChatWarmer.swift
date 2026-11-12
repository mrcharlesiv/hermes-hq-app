// Before the tap (spec 03 §4.1, "stale refresh pass"): when the Bots roster changes, the newest bots' chat tails are
// read and saved to the transcript cache, so opening one paints from disk in the push's first frame instead of waiting
// for the network. At most twice a minute, ≥ 2 s after the roster settles, newest activity first, at most 4 chats per
// pass, one at a time, never while the app is in the background. A tail is read when it was never saved or was saved
// more than 1 s before the chat's last activity.
//
// Right after sign-in nothing is saved yet, so the first pass comes sooner (0.5 s) and reads more chats (8): the bots
// the owner is about to tap are the newest ones. And a finger resting on a row reads that chat at once
// (`prefetch`, spec 03 §4.1 finger-down warm): the open that follows takes the read over (`HistoryFlights`).

import Foundation

final class ChatWarmer {
    static let rowsPerTail = 24
    static let chatsPerPass = 4
    static let chatsFirstPass = 8
    static let firstSettle: Duration = .milliseconds(500)

    private let client: any GatewayClient
    private let account: GatewayAccount
    private let cache: TranscriptCache
    private let settle: Duration
    private let minimumGap: Duration
    /// Profiles whose chat is on screen: that chat keeps its own cache.
    var isOpen: (String) -> Bool = { _ in false }
    /// Leaving cancels a planned pass (and cuts a reading one short); coming back plans it again, since an unchanged
    /// roster no longer notifies on the return's read.
    var appActive = true {
        didSet {
            if !appActive { scheduled?.cancel(); scheduled = nil; return }
            guard !oldValue else { return }
            if passTask != nil { passAgain = true }
            else if scheduled == nil, !staleTargets(latest).isEmpty { schedule() }
        }
    }
    /// [offline] §6.10: the chat the next launch would reopen, and the Sessions list's rows (the first 15 are read ahead).
    var lastChat: () -> WarmOrder.LastChat? = { nil }
    var sessionRows: () -> [SessionSummary] = { [] }
    /// [offline] How long the first pass waits for the roster to name the bots' own chats (see `pass()`).
    var rosterWait: Duration = .seconds(4)

    private var latest: [Bot] = []
    /// The settle wait before a pass. A roster change restarts it; it never cancels a pass that is already reading.
    private var scheduled: Task<Void, Never>?
    /// The pass that is reading. Kept apart from `scheduled`: on a slow link the full roster lands while the first pass
    /// still reads, and cancelling that pass then pushed every first open ~30 s out (verification round 2).
    private var passTask: Task<Void, Never>?
    /// The roster changed while a pass ran: one more pass (at the normal gap) once it ends.
    private var passAgain = false
    private var lastPass: ContinuousClock.Instant?
    /// [perf] Chats this warmer read (a new bot's empty chat too), with their activity then: skipped until it moves, so
    /// they never look stale forever and plan a pass every `minimumGap`. [13-15] A saved tail's time is the phone's clock
    /// and the activity the gateway's: a gateway clock running ahead made every chat it had just read look stale again,
    /// read on every pass.
    private var readAt: [WarmOrder.Target: Date?] = [:]

    init(client: any GatewayClient, account: GatewayAccount, cache: TranscriptCache = .shared,
         settle: Duration = .seconds(2), minimumGap: Duration = .seconds(30)) {
        self.client = client
        self.account = account
        self.cache = cache
        self.settle = settle
        self.minimumGap = minimumGap
    }

    func stop() {
        scheduled?.cancel()
        scheduled = nil
        passTask?.cancel()
        passTask = nil
        passAgain = false
        readAt = [:]
    }

    /// The roster changed: plan a pass once it settles (and no sooner than `minimumGap` after the last one). A pass that
    /// is reading carries on with the new roster (it picks each next chat from the latest one).
    func rosterChanged(_ bots: [Bot]) {
        latest = bots
        guard appActive else { return }
        if passTask != nil { passAgain = true; return }
        schedule()
    }

    private func schedule() {
        scheduled?.cancel()
        var wait = lastPass == nil ? min(settle, Self.firstSettle) : settle
        if let lastPass {
            let since = ContinuousClock.now - lastPass
            if since < minimumGap { wait = max(wait, minimumGap - since) }
        }
        scheduled = Task { [weak self, wait] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            self.startPass()
        }
    }

    private func startPass() {
        guard passTask == nil, appActive else { return }
        passTask = Task { [weak self] in
            await self?.pass()
            guard let self, !Task.isCancelled else { return }
            self.passTask = nil
            if self.passAgain {
                self.passAgain = false
                if self.appActive { self.schedule() }
            }
        }
    }

    /// Bots whose saved tail is missing or stale, newest activity first.
    func staleBots(_ bots: [Bot]) -> [Bot] {
        bots.filter { bot in
            guard !bot.hidden, let stored = bot.canonicalSessionId, !stored.isEmpty, !isOpen(bot.id) else { return false }
            guard let saved = cache.savedAtPeek(account: account.id, profile: bot.id, storedId: stored) else { return true }
            guard let active = bot.lastActive else { return false }
            return saved.addingTimeInterval(1) < active
        }
        .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// [offline] §6.10: every chat worth reading ahead whose saved tail is missing or stale, in the web's order: the
    /// chat the next launch reopens, pinned bots, the other bots newest first, 15 Sessions rows, hidden bots.
    func staleTargets(_ bots: [Bot]) -> [WarmOrder.Candidate] {
        WarmOrder.order(lastChat: lastChat(), bots: bots, sessions: sessionRows()).filter { candidate in
            let target = candidate.target
            guard !isOpen(target.profile) else { return false }
            if let seen = readAt[target], seen == candidate.lastActive { return false }
            guard let saved = cache.savedAtPeek(account: account.id, profile: target.profile, storedId: target.storedId) else { return true }
            guard let active = candidate.lastActive else { return false }
            return saved.addingTimeInterval(1) < active
        }
    }

    private func pass() async {
        guard appActive else { return }
        let first = lastPass == nil
        let previous = lastPass
        lastPass = .now
        let client = self.client
        let features = client.latestReady.flatMap { PerformanceFeatures(ready: $0) }
        let limit = first ? Self.chatsFirstPass : Self.chatsPerPass
        // [offline] §6.10 (review round): the roster's first answer may name the bots before it names their chats, and
        // the Sessions rows may be there already. Reading those first would put the least likely chats ahead of the
        // pinned bot's. The first pass gives the bots' chat ids up to `rosterWait` to arrive.
        if first, !latest.isEmpty {
            let deadline = ContinuousClock.now + rosterWait
            while latest.allSatisfy({ ($0.canonicalSessionId ?? "").isEmpty }), ContinuousClock.now < deadline, appActive, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        var tried = Set<WarmOrder.Target>()                      // [offline] §6.10: by chat, not by bot
        var reads = 0
        var aborted = false
        // Each next chat comes from the roster as it is now (a fuller roster may land while this pass reads).
        while tried.count < limit {
            guard appActive, !Task.isCancelled else { aborted = true; break }
            guard let next = staleTargets(latest).first(where: { !tried.contains($0.target) }) else { break }
            let bot = (id: next.target.profile, stored: next.target.storedId), stored = next.target.storedId
            tried.insert(next.target)
            // A finger-down read of this chat is out already (or just landed and was saved).
            if HistoryFlights.shared.has(HistoryFlights.Key(account: account.id, profile: bot.id, storedId: stored)) { continue }
            let request = HistoryRequest(storedSessionId: stored, profile: bot.id, limit: Self.rowsPerTail)
            guard let (page, folded, _) = try? await HistoryAPI.fetchAndFold(client: client, request: request, features: features, cut: true)
            else { continue }
            guard !Task.isCancelled else { aborted = true; break }
            reads += 1
            if folded.messages.isEmpty { readAt[next.target] = next.lastActive; continue }
            guard !isOpen(bot.id) else { continue }
            // [right-open] Joined onto the saved copy (whole turns), never 24 rows in its place.
            await LiveChatSession.saveReadAhead(page, folded, cache: cache, client: client, account: account.id, profile: bot.id,
                                                storedId: stored, features: features, stillWanted: { [weak self] in
                !(self?.isOpen(bot.id) ?? true)
            })
            guard !Task.isCancelled else { aborted = true; break }
            readAt[next.target] = next.lastActive
        }
        // A pass that had nothing to read (the slim roster carries no chats yet) or was cut short before it read
        // anything doesn't count toward the gap, nor ends the "first pass": on a slow link the slim roster's empty pass
        // otherwise pushed the full roster's pass ~30 s out (verification round 2).
        if tried.isEmpty || (aborted && reads == 0) { lastPass = previous }
        // [perf] A full pass that left stale chats unread plans one more (at the normal gap). The roster's poll used to
        // notify every 30-120 s even when nothing changed, and that is what drained the backlog; it now notifies only
        // on a real change. Not after a pass that read nothing: an unreachable gateway isn't asked again and again.
        if !aborted, reads > 0, tried.count >= limit, staleTargets(latest).contains(where: { !tried.contains($0.target) }) {
            passAgain = true
        }
        AppLog.trace("store", "warm pass (\(first ? "first" : "later")): \(tried.count) tried, \(reads) read, aborted=\(aborted), again=\(passAgain)")
    }

    /// A finger rests on this bot's row: read its chat's newest rows now (unless its saved tail is fresh, or a read is
    /// already out). The open that follows takes the read over; if the tap never comes, the rows are saved for later.
    func prefetch(_ bot: Bot) {
        guard appActive, let stored = bot.canonicalSessionId, !stored.isEmpty, !isOpen(bot.id) else { return }
        if let saved = cache.savedAtPeek(account: account.id, profile: bot.id, storedId: stored),
           bot.lastActive.map({ saved.addingTimeInterval(1) >= $0 }) ?? true { return }
        let key = HistoryFlights.Key(account: account.id, profile: bot.id, storedId: stored)
        let client = self.client, cache = self.cache, account = self.account.id
        HistoryFlights.shared.start(key, { HistoryFlights.openRead(client: client, storedId: stored, profile: bot.id) }) {
            [weak self] answer in
            guard !answer.1.messages.isEmpty, !(self?.isOpen(bot.id) ?? true) else { return }
            let features = client.latestReady.flatMap { PerformanceFeatures(ready: $0) }
            Task {
                await LiveChatSession.saveReadAhead(answer.0, answer.1, cache: cache, client: client, account: account, profile: bot.id,
                                                    storedId: stored, features: features, stillWanted: { !(self?.isOpen(bot.id) ?? true) })
            }
        }
    }
}
