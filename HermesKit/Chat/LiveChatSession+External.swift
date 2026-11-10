// [external-turn] Working… while another Hermes process runs a turn in this chat (ExternalTurn.swift,
// docs/spec/03-chat-history.md §4.8): the chat reads its stored rows every few seconds meanwhile, so each step and the
// reply show as the gateway writes them, and the header says Working… until the ledger (or the rows) say it ended.

import Foundation

extension LiveChatSession {
    /// Another process runs a turn here now (the header's Working…, the rows' live step line, the Bots/Sessions rows).
    var externalWorking: Bool { externalWork != nil }

    /// Checks run while no turn of ours does, and while our send waits behind theirs (`SESSION_OWNER_BUSY`).
    private var externalChecksAllowed: Bool { !turn.busy || turn.waitingForOwner != nil }

    /// Something suggests another process may run a turn here (the open settled, a read brought rows, our send was
    /// refused for the gateway's turn): ask, and keep reading while it runs. One loop at a time.
    func checkExternalWork(_ why: String) {
        guard observing, openSettled, externalWorkTask == nil, externalChecksAllowed, readSessionId != nil else { return }
        externalGeneration += 1
        let generation = externalGeneration
        externalWorkTask = Task { [weak self] in
            await self?.externalWorkLoop(why, generation: generation)
        }
    }

    /// The screen went away or our own turn started: the loop ends and Working… with it.
    /// [owner-wait] The pause before the next try while another run owns the chat: `ownerRetryInterval` for the first
    /// three, then half again longer each time up to 4× (2 s → 8 s). Every 2 s for the whole wait made 15 tries in 36 s
    /// (log study 2026-10-28, Inbox 7:51 AM); `waitForOwner` still ends it as soon as the other run is seen to end.
    func ownerPause(_ tries: Int) -> Duration {
        ownerRetryInterval * min(pow(1.5, Double(max(0, tries - 3))), 4)
    }

    /// Sleeps `pause`, or less: the external-turn watch saw the other run end (the chat is free now), or Stop was pressed
    /// (`epoch` moved on), so the waiting message comes back at once instead of up to 8 s later.
    func waitForOwner(_ pause: Duration, epoch: Int? = nil) async {
        let ends = externalEnds
        let until = ContinuousClock.now + pause
        while externalEnds == ends, !Task.isCancelled, epoch.map({ $0 == stopEpoch }) ?? true {
            let left = ContinuousClock.now.duration(to: until)
            guard left > .zero else { return }
            try? await Task.sleep(for: min(left, .milliseconds(250)))
        }
    }

    func endExternalWork(_ why: String) {
        externalGeneration += 1
        externalWorkTask?.cancel()
        externalWorkTask = nil
        setExternalWork(nil, why: why, readAfter: false)
    }

    private func externalWorkLoop(_ why: String, generation: Int) async {
        var round = 0
        defer { if generation == externalGeneration { externalWorkTask = nil } }
        while generation == externalGeneration, !Task.isCancelled, observing, externalChecksAllowed {
            if round > 0 {
                // What the other process wrote since: each step as it lands (probe-first, so an unchanged chat costs
                // one 1-row read).
                startRefresh(force: false)
                await refreshTask?.value
                guard generation == externalGeneration, !Task.isCancelled, observing, externalChecksAllowed else { return }
            }
            round += 1
            let verdict = await externalVerdict()
            guard generation == externalGeneration, !Task.isCancelled, observing else { return }
            setExternalWork(verdict, why: round == 1 ? why : "read \(round)", readAfter: true)
            if verdict == nil { return }
            try? await Task.sleep(for: ExternalTurn.pollInterval)
        }
        // Our own turn started (or the screen left) with the loop still on: that turn's state takes over.
        if generation == externalGeneration, externalWork != nil {
            setExternalWork(nil, why: turn.busy ? "a turn of ours started" : "screen off", readAfter: false)
        }
    }

    /// The ledger's word when the add-on has it; otherwise the stored rows'.
    private func externalVerdict() async -> ExternalTurn.Source? {
        switch await askLedger() {
        case .working(let working): return working ? .ledger : nil
        case .missing, .failed: break
        }
        return ExternalTurn.historyUnfinished(messages, newestStoredAt: newestStoredAt, now: Date()) ? .history : nil
    }

    private func askLedger() async -> ExternalTurn.LedgerAnswer {
        let key = account.id
        if let since = ExternalTurn.ledgerMissingSince[key], Date().timeIntervalSince(since) < ExternalTurn.missingRecheck {
            return .missing
        }
        let ids = Set([readSessionId, storedSessionId, resolvedStoredId, pageSessionId].compactMap { $0 })
        guard !ids.isEmpty else { return .failed }
        let profileName = profile.isEmpty ? "default" : profile
        let client = self.client
        do {
            let json = try await PagesREST.json(client, "GET", ExternalTurn.ledgerPath,
                                                query: [URLQueryItem(name: "profile", value: profileName)], timeout: 10)
            ExternalTurn.ledgerMissingSince[key] = nil
            return .working(ExternalTurn.ledgerNames(json, ids: ids, profile: profileName))
        } catch {
            if PagesREST.status(error) == 404 {
                if ExternalTurn.ledgerMissingSince[key] == nil {
                    AppLog.trace("turn", "external turn \(logIds): add-on has no sessions/working (older than 0.9.6), the stored rows decide")
                }
                ExternalTurn.ledgerMissingSince[key] = Date()
                return .missing
            }
            AppLog.trace("turn", "external turn \(logIds): ledger read failed (\(PagesREST.status(error).map(String.init) ?? "no status")), the stored rows decide")
            return .failed
        }
    }

    /// `readAfter`: when the other process's turn ends, one forced read brings the reply it ended with.
    func setExternalWork(_ source: ExternalTurn.Source?, why: String, readAfter: Bool) {
        guard source != externalWork else { return }
        let was = externalWork
        externalWork = source
        if source == nil, was != nil { externalEnds += 1 }
        AppLog.note("turn", "external turn \(logIds): \(source.map { "running (\($0.rawValue))" } ?? "ended") after \(why)")
        changes.markState()
        scheduleFlush()
        if (was == nil) != (source == nil) { onExternalWorkChange?(source != nil) }
        if source == nil, was != nil, readAfter, observing { startRefresh(force: true) }
    }
}
