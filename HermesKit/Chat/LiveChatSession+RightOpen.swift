// [right-open] Opening a chat shows its saved copy and keeps it: what the gateway holds since joins under it at a whole
// turn, and nothing already on screen is replaced by a piece of itself.
//
// Owner 2026-11-11, with a screen recording of Hermes's chat: "A chat MUST load the correct messages IMMEDIATELY when
// opened. This is unacceptable." The phone's log of that open: the saved copy (40 messages) was cut to its last reply,
// a turn longer than the first page; the first page (24 rows from inside that turn, no prompt among them) replaced it
// with a piece of the same turn ("page 1 → 1 after cut, over 1 shown → 1; replace all"); and each older read then
// folded that piece again ("1 top messages replaced"), a full redraw each time. The chat showed one thing, went
// blank, and settled on another.
//
// The rules now:
// - The whole saved copy is painted, at once (`paintFromCache`).
// - The first page is joined at a turn start whose earlier rows the saved copy holds (`OpenJoint.index`): the saved
//   messages before it stay, the page's whole turns follow. When the page has no such start, older rows are read
//   until one is found (the saved copy stays on screen meanwhile).
// - Nothing new and no turn start in the page (the chat ends in a turn longer than the page, all of it saved): the
//   saved copy is the transcript; paging goes on from the page (`keepSavedCopy`, `savedTurnCut`).
// - The reads made before the tap (`ChatWarmer`) join the saved copy the same way instead of replacing it with their
//   24 rows (`OpenJoint.savedCopy`).

import Foundation

nonisolated enum OpenJoint {
    /// The index in `rows` (a newest page, oldest first) of the turn start the transcript can begin its fresh part at:
    /// the page's first turn start, when the saved copy holds every row before it (`savedThrough`: the newest row the
    /// saved copy covers; rows are only ever added, so a copy that reaches the row before the start holds the turns
    /// before it whole). With nothing saved, any turn start will do. nil: the page holds no such start.
    static func index(in rows: [JSONValue], savedThrough: Int?) -> Int? {
        guard let i = rows.firstIndex(where: LiveChatSession.isTurnStart) else { return nil }
        guard let savedThrough else { return i }
        guard let before = HistoryPage.rowId(rows[max(0, i - 1)]) else { return nil }
        return before <= savedThrough ? i : nil
    }

    /// `page` from its row `i` on, counted as a page that has more above it.
    static func cut(_ page: HistoryPage, at i: Int) -> HistoryPage {
        guard i > 0, i < page.rows.count else { return page }
        var out = page
        out.rows.removeFirst(i)
        var p = page.pagination ?? HistoryPagination(limit: nil, offset: page.requestedOffset, order: "latest", returned: page.rows.count)
        p.nextOffset = page.nextOffset - i
        p.returned = out.rows.count
        p.limit = out.rows.count
        p.hasMore = true
        out.pagination = p
        return out
    }

    /// The newest backend row `messages` cover.
    static func savedThrough(_ messages: [ChatMessage], meta: [String: MessageMeta]) -> Int? {
        messages.lazy.compactMap { newestRow($0, meta[$0.id]) }.max()
    }

    static func newestRow(_ m: ChatMessage, _ meta: MessageMeta?) -> Int? {
        [m.rowId, meta?.firstRowId, meta?.lastRowId].compactMap { $0 }.max()
    }

    enum Saved {
        /// Save these (the saved copy with the page's whole turns joined on, or the page itself).
        case save([ChatMessage], [String: MessageMeta])
        /// The page can't be joined as it is: older rows are needed first.
        case needsOlderRows
    }

    /// The copy to save after a read made ahead of the open: the saved messages before the joint, then the page's
    /// whole turns. `final`: no more rows will be read, so a page that can't be joined is saved from its first turn
    /// start when it has one, and otherwise the saved copy is left alone (nil).
    static func savedCopy(_ entry: TranscriptEntry?, with page: HistoryPage, folded: HydratedPage, final: Bool,
                          accountId: String? = nil) -> Saved? {
        let saved = (entry?.partial ?? true) ? [] : (entry?.messages ?? []).filter { !$0.isLocal }
        let meta = entry?.meta ?? [:]
        let through = savedThrough(saved, meta: meta)
        let whole = !page.possiblyTruncated || !page.isLatestTail
        if whole { return .save(folded.messages, folded.meta) }
        if let through, let newest = page.rows.lazy.compactMap(HistoryPage.rowId).max(), newest <= through {
            return .save(saved, meta)                    // nothing new: the copy is saved again as read now
        }
        func joined(at i: Int, keeping: Bool) -> Saved {
            let rows = Array(page.rows[i...])
            let fresh = i == 0 ? folded : InlineMediaStore.$accountId.withValue(accountId) { Hydration.fold(rows) }
            guard keeping, let first = rows.lazy.compactMap(HistoryPage.rowId).min() else { return .save(fresh.messages, fresh.meta) }
            let older = Array(saved.prefix(while: { (newestRow($0, meta[$0.id]) ?? Int.max) < first }))
            let held = Set(fresh.messages.map(\.id))
            var out = fresh.meta
            for m in older where !held.contains(m.id) { if let mm = meta[m.id] { out[m.id] = mm } }
            return .save(older.filter { !held.contains($0.id) } + fresh.messages, out)
        }
        // With nothing saved, a page that starts a turn is saved as read; from inside one, the rows above are read
        // first (cut at a late turn start, the copy would hold little to show).
        if let i = index(in: page.rows, savedThrough: through), through != nil || i == 0 { return joined(at: i, keeping: through != nil) }
        guard final else { return .needsOlderRows }
        if let i = page.rows.firstIndex(where: LiveChatSession.isTurnStart) { return joined(at: i, keeping: false) }
        return saved.isEmpty ? .save(folded.messages, folded.meta) : nil
    }
}

extension LiveChatSession {
    /// Reads made to find a turn start when the first page has none the saved copy reaches.
    static let jointReads = 4
    /// The same with nothing saved to show meanwhile (the screen waits on these).
    static let coldJointReads = 2

    /// The open's first page, put on screen so that it holds whole turns and joins the saved copy. Returns the page as
    /// applied.
    @discardableResult
    func landFirstPage(_ first: HistoryPage, _ firstFolded: HydratedPage) async -> HistoryPage {
        let shown = messages.filter { !$0.isLocal }
        let through = OpenJoint.savedThrough(shown, meta: metaById)
        // The whole chat, or a page that is no tail: as read.
        guard first.possiblyTruncated, first.isLatestTail, !first.rows.isEmpty, let stored = readSessionId else {
            applyFirstPage(first, firstFolded, keepCached: true)
            return first
        }
        var page = first
        var readMore = false
        var joint = OpenJoint.index(in: page.rows, savedThrough: through)
        if joint == nil, let through, let newest = page.rows.lazy.compactMap(HistoryPage.rowId).max(), newest <= through,
           !page.rows.contains(where: LiveChatSession.isTurnStart) {
            keepSavedCopy(over: page)
            return page
        }
        // With nothing saved the page is shown as read when it starts a turn; from inside one, the turn's start is
        // read first (a piece of a reply was drawn, then drawn again whole).
        if through == nil, joint != 0 { joint = nil }
        if joint == nil {
            let started = ContinuousClock.now
            let reads = through == nil ? LiveChatSession.coldJointReads : LiveChatSession.jointReads
            var read = 0
            while joint == nil, read < reads, page.possiblyTruncated, !Task.isCancelled {
                read += 1
                let (extended, grew) = await LiveChatSession.readBack(page, client: client, stored: stored, profile: profileParam,
                                                                      features: perfFeatures, reads: 1, until: { _ in false })
                guard grew else { break }
                readMore = true
                page = extended
                joint = OpenJoint.index(in: page.rows, savedThrough: through)
                // The chat moved on by more than was read and the saved copy is out of reach: it gives way to the
                // gateway's whole turns.
                if joint == nil, let through, let oldest = page.rows.lazy.compactMap(HistoryPage.rowId).min(), oldest > through,
                   page.rows.contains(where: LiveChatSession.isTurnStart) { break }
            }
            AppLog.trace("history", "first page \(logIds): no turn start the saved copy reaches in \(first.rows.count) rows; read back to \(page.rows.count) in \(read) reads, \(AppLog.ms(since: started)) ms, joint \(joint.map(String.init) ?? "none")")
        }
        if let i = joint {
            let cut = OpenJoint.cut(page, at: i)
            let folded = i == 0 && !readMore ? firstFolded : await LiveChatSession.foldOffMain(cut.rows, accountId: account.id)
            let from = cut.rows.lazy.compactMap(HistoryPage.rowId).min() ?? Int.max
            let older = through == nil ? [] : Array(messages.prefix(while: { !$0.isLocal && (newestRow($0) ?? Int.max) < from }))
            applyFirstPage(cut, folded, savedOlder: older)
            return cut
        }
        if !page.possiblyTruncated {
            // Read back to the chat's start: all of it, as read.
            applyFirstPage(page, await LiveChatSession.foldOffMain(page.rows, accountId: account.id), keepCached: true)
            return page
        }
        if let i = page.rows.firstIndex(where: LiveChatSession.isTurnStart) {
            let cut = OpenJoint.cut(page, at: i)
            applyFirstPage(cut, await LiveChatSession.foldOffMain(cut.rows, accountId: account.id), savedOlder: [])
            return cut
        }
        // A turn longer than the reach: its newest rows, as before.
        let folded = readMore ? await LiveChatSession.foldOffMain(page.rows, accountId: account.id) : firstFolded
        applyFirstPage(page, folded, keepCached: true)
        return page
    }

    /// The first page holds nothing the saved copy lacks and no turn start: the chat ends in a turn longer than the
    /// page, and the saved copy shows it whole. The saved messages stay as they are, all of them still unconfirmed;
    /// paging goes on above the page, whose rows are the partial turn on top (`savedTurnCut` keeps the saved reply
    /// when the rows above are read).
    func keepSavedCopy(over page: HistoryPage) {
        heldPaint = nil
        noteStoredRows(page.rows)
        let ids = page.rows.compactMap(HistoryPage.rowId)
        AppLog.trace("history", "first page \(logIds): \(page.rows.count) rows (\(ids.first.map(String.init) ?? "-")…\(ids.last.map(String.init) ?? "-")) hold nothing new and no turn start; the saved copy stays (\(messages.count) shown)")
        if let id = page.sessionId, !id.isEmpty { pageSessionId = id }
        nextOffset = page.nextOffset
        hasOlder = true
        oldestRowId = ids.first
        loadedRowIds = Set(ids)
        headRows = page.rows
        newestSignature = page.rows.last.map(HistoryAPI.signature)
        noteCatchUp("first page \(page.rows.count) rows, saved copy kept")
        cachedOlderIds = Set(messages.filter { !$0.isLocal }.map(\.id))
        restoreLostSends()
        restoreSideResults()
        lastSyncAt = Date()
        lastSyncIds = messages.map(\.id)
        changes.markState()
        scheduleFlush()
        saveCache()                                      // saved again as read now
    }

    /// A read made before the open (the warm pass, a finger resting on the row) joins the saved copy; a page that
    /// can't be joined as it is gets one more read of the rows above it first.
    static func saveReadAhead(_ page: HistoryPage, _ folded: HydratedPage, cache: TranscriptCache, client: any GatewayClient,
                              account: String, profile: String, storedId: String, features: PerformanceFeatures?,
                              stillWanted: () -> Bool = { true }) async {
        let entry = cache.loadEntry(account: account, profile: profile, storedId: storedId)
        var result = OpenJoint.savedCopy(entry, with: page, folded: folded, final: false, accountId: account)
        if case .needsOlderRows? = result {
            let (extended, grew) = await readBack(page, client: client, stored: page.sessionId ?? storedId,
                                                  profile: profile.isEmpty ? nil : profile, features: features, reads: 1,
                                                  until: { _ in false })
            guard !Task.isCancelled else { return }
            let refolded = grew ? await foldOffMain(extended.rows, accountId: account) : folded
            result = OpenJoint.savedCopy(entry, with: extended, folded: refolded, final: true, accountId: account)
        }
        guard stillWanted(), case .save(let messages, let meta)? = result, !messages.isEmpty else { return }
        cache.save(messages, meta: meta, account: account, profile: profile, storedId: storedId)
    }
}
