// Keeping the open chat in step with the gateway: first page + inflight graft (03 §4.5), older pages (03 §5.1–5.2;
// M1 keeps prepending pages instead of the web's history-page mode §5.3), the probe-first refresh (03 §7.6), change
// broadcasts (03 §7.7), reconnect catch-up with replay (04 §7), and the 45 s silence watchdog (04 §4.8).

import Foundation

extension LiveChatSession {
    static let fullPageRows = 120
    /// The most rows a refresh or an open reads back to reach a turn's prompt (the gateway's page cap is 500, 03 §2.1).
    static let reachCap = 500

    /// A row that starts a fold group: a user prompt or a system row (anything else continues the turn above it).
    nonisolated static func isTurnStart(_ row: JSONValue) -> Bool {
        let role = row["role"]?.string
        return role == "user" || role == "system"
    }

    /// The rows of a partial turn at the top of a page: everything before its first user/system row.
    nonisolated static func leadingPartial(_ rows: [JSONValue]) -> [JSONValue] {
        Array(rows.prefix { !isTurnStart($0) })
    }

    // MARK: Pages

    func applyFirstPage(_ page: HistoryPage, _ folded: HydratedPage) {
        heldPaint = nil
        noteStoredRows(page.rows)
        let ids = page.rows.compactMap(HistoryPage.rowId)
        AppLog.trace("history", "first page \(logIds): \(page.rows.count) rows (\(ids.first.map(String.init) ?? "-")…\(ids.last.map(String.init) ?? "-")), page id \(AppLog.tag(page.sessionId)), next offset \(page.nextOffset), more=\(page.possiblyTruncated), folded \(folded.messages.count) messages over \(messages.count) shown")
        if let id = page.sessionId, !id.isEmpty { pageSessionId = id }
        nextOffset = page.nextOffset
        hasOlder = page.possiblyTruncated
        oldestRowId = page.rows.lazy.compactMap(HistoryPage.rowId).first
        loadedRowIds = Set(page.rows.compactMap(HistoryPage.rowId))
        headRows = page.possiblyTruncated ? LiveChatSession.leadingPartial(page.rows) : []
        newestSignature = page.rows.last.map(HistoryAPI.signature)
        noteCatchUp("first page \(page.rows.count) rows")
        replaceTranscript(with: folded, replaceAll: true)
        restoreLostSends()                              // [sessions-m9] a send that may never have arrived keeps its bubble (3x-sessions §9.4)
        restoreSideResults()                            // /btw and /bg results that landed this launch
        AppLog.trace("history", "first page applied \(logIds): \(messages.count) rows shown, hasOlder=\(hasOlder)")
        lastSyncAt = Date()
        lastSyncIds = messages.map(\.id)
        changes.markState()
        saveCache()
    }

    /// Fresh rows over what is shown, keeping row identity (03 §4.5 wholesale replace / §7.5 graft).
    ///
    /// While a turn runs, the live bubble is the turn's single owner (04 §7.4: keep the structured live bubble): the
    /// page is cut after the turn's user row, so the stored partial (assistant/tool rows persisted mid-turn) never shows
    /// next to it; the turn-end read then matches the sealed bubble to the stored reply.
    @discardableResult
    func replaceTranscript(with folded: HydratedPage, replaceAll: Bool) -> Bool {
        let span = MainTrail.begin("chat.merge")          // [diagnostics] build 292
        defer { MainTrail.end(span) }
        flushDeltas()
        var fresh = LiveChatSession.sentTitles.applied(to: folded.messages)    // [presence] a titled request keeps its title
        var freshMeta = folded.meta
        var previous = messages
        var carried: (message: ChatMessage, meta: MessageMeta?, next: String?)?
        // While our send waits for the chat's owner nothing on the page is our turn's: the holder's reply stays whole.
        if (turn.busy || turn.streamId != nil) && !turnNotOnGateway {
            if let sid = turn.streamId, let index = indexById[sid] {
                let next = messages[(index + 1)...].first?.id
                carried = (messages[index], metaById[sid], next)
                previous.remove(at: index)
                let canonicalLive = canonicalId(sid)
                fresh.removeAll { $0.id == canonicalLive }
            }
            let cutAt = liveTurnUserIndex(in: fresh, previous: previous)
            AppLog.trace("merge", "merge \(logIds) during a turn: page cut \(cutAt.map { "after its prompt at \($0), \(fresh.count - $0 - 1) stored row(s) of the running turn hidden" } ?? "nowhere (prompt not found or predates the turn)"), live row \(AppLog.tag(turn.streamId)) \(carried != nil ? "carried" : "absent")")
            noteCatchUp("cut \(cutAt.map { "\(fresh.count - $0 - 1)" } ?? "none")\(carried != nil ? " carried" : "")")   // [doubled-reply]
            if let cut = cutAt, cut + 1 < fresh.count {
                for m in fresh[(cut + 1)...] { freshMeta[m.id] = nil }
                fresh.removeSubrange((cut + 1)...)
            }
        }
        let graft = TranscriptMerge.graft(fresh: fresh, freshMeta: freshMeta, onto: previous, previousMeta: metaById,
                                          aliases: aliases, replaceAll: replaceAll)
        AppLog.trace("merge", "merge \(logIds): page \(folded.messages.count) → \(fresh.count) after cut, over \(previous.count) shown → \(graft.messages.count)\(carried != nil ? " + live row \(AppLog.tag(carried?.message.id)) carried" : ""), aliases \(aliases.count) → \(graft.aliases.count); \(graft.notes.joined(separator: "; "))")
        aliases = graft.aliases
        turnMarksFollowAliases()   // [transcript] §6.6: a live reply's mark follows it to its stored id
        var result = graft.messages
        var meta = graft.meta
        if let carried {
            // Back where it was: before the row that followed it, else at the newest end.
            let at = carried.next.flatMap { next in result.firstIndex { $0.id == next } } ?? result.count
            result.insert(carried.message, at: at)
            if let mm = carried.meta { meta[carried.message.id] = mm }
        }
        // Live tool details survive (the page has none for a running turn).
        let resultIds = Set(result.map(\.id))
        for (id, mm) in metaById where meta[id] == nil && resultIds.contains(id) { meta[id] = mm }
        messages = TranscriptMerge.diff(old: messages, new: result, into: &changes)
        metaById = meta
        applyKnownMediaSizes()                                                                                 // [attachments]
        rebuildIndex()
        if let sid = turn.streamId, indexById[sid] == nil { turn.streamId = nil; turn.openPart = nil }
        if let sid = turn.streamId, let index = indexById[sid], let open = turn.openPart, open.index >= messages[index].parts.count {
            turn.openPart = nil
        }
        scheduleFlush()
        return graft.keptOlder
    }

    /// The running turn's user row in a fresh page: our own prompt by identity (stored id, row id, then text among rows
    /// newer than everything shown before it); for a turn we didn't send, the snapshot's inflight prompt, else the newest
    /// user row newer than everything shown. nil (cut nothing) when that row is from before the turn started.
    func liveTurnUserIndex(in fresh: [ChatMessage], previous: [ChatMessage]) -> Int? {
        func newestStoredRow(_ slice: ArraySlice<ChatMessage>) -> Int {
            // A live bubble's row id came from `persisted_turn` or the submit ack: a stored row like any other.
            slice.reduce(0) { best, m in max(best, m.rowId ?? 0) }
        }
        // A user row stored before the running turn began belongs to a finished turn: cutting after it hid that turn's
        // reply until the running one ended (10 s for clock skew; a row with no time is not judged).
        func predates(_ m: ChatMessage, _ start: Date?) -> Bool {
            guard let start, let at = m.timestamp, at.timeIntervalSince1970 > 0 else { return false }
            return at < start.addingTimeInterval(-10)
        }
        if let anchorId = turn.userAnchorId, let anchorIndex = previous.firstIndex(where: { $0.id == anchorId }) {
            let anchor = previous[anchorIndex]
            let canonical = canonicalId(anchorId)
            if let i = fresh.lastIndex(where: { $0.id == canonical }) { return i }
            if let row = anchor.rowId, let i = fresh.lastIndex(where: { $0.role == .user && $0.rowId == row }) { return i }
            let known = newestStoredRow(previous[..<anchorIndex])
            let newer = fresh.indices.filter { fresh[$0].role == .user && (fresh[$0].rowId ?? 0) > known }
            let text = Hydration.userDisplayKey(anchor.plainText) /* [attachments] */
            if let i = newer.first(where: { Hydration.userDisplayKey(fresh[$0].plainText) == text }) { return i }
            // The only newer prompt is ours only once the gateway took ours and it isn't from before we sent.
            guard newer.count == 1, !anchor.isPending,
                  !predates(fresh[newer[0]], anchor.timestamp ?? turn.armedAt ?? turn.turnStartedAt) else { return nil }
            return newer[0]
        }
        let known = newestStoredRow(previous[...])
        let newer = fresh.indices.filter { fresh[$0].role == .user && (fresh[$0].rowId ?? 0) > known }
        if let key = turn.inflightUserKey,
           let i = newer.last(where: { Hydration.userDisplayKey(fresh[$0].plainText) == key }) { return i }
        guard let last = newer.last, !predates(fresh[last], turn.turnStartedAt) else { return nil }
        return last
    }

    /// Releases the oldest stored rows beyond `keep` messages (03 §5.4; M1 does it when the screen goes away). The tail
    /// offset is rewound by the released backend rows so paging fetches them again; rows without a row id stay.
    func releaseOlderHistory(keepingNewest keep: Int) {
        guard keep > 0, messages.count > keep else { return }
        let limit = messages.count - keep
        var cut = 0
        var rows = 0
        func releasable(_ m: ChatMessage) -> Bool { !m.isLocal && (m.rowId ?? metaById[m.id]?.firstRowId) != nil }
        while cut < limit, releasable(messages[cut]) {
            rows += metaById[messages[cut].id]?.serverRowSpan ?? 1
            cut += 1
        }
        // The new top starts a turn (a user prompt), so paging back never splits the turn below it.
        while cut > 0, cut < messages.count, messages[cut].role != .user, releasable(messages[cut]) {
            rows += metaById[messages[cut].id]?.serverRowSpan ?? 1
            cut += 1
        }
        guard cut > 0, cut < messages.count, messages[cut].role == .user else { return }
        // Rows the screen never draws (hidden rows, a background run's prompt, rows that fold to nothing) count too: the
        // stored rows read below the new top, by their ids. Counted short, the next older page started too far back and
        // the rows just above the kept top never came back. (More is safe: the older read joins on the oldest row.)
        if let top = metaById[messages[cut].id]?.firstRowId ?? messages[cut].rowId {
            let floor = oldestRowId ?? Int.min
            rows = max(rows, loadedRowIds.lazy.filter { $0 >= floor && $0 < top }.count)
        }
        AppLog.trace("history", "release \(logIds): \(cut) oldest messages (\(rows) rows) let go, \(messages.count - cut) kept, offset \(nextOffset) → \(max(1, nextOffset - rows))")
        headRows = []
        for m in messages[..<cut] {
            metaById[m.id] = nil
            changes.remove(m.id)
        }
        messages.removeFirst(cut)
        rebuildIndex()
        nextOffset = max(1, nextOffset - rows)
        if let first = messages.first { oldestRowId = metaById[first.id]?.firstRowId ?? first.rowId ?? oldestRowId }
        hasOlder = true
        changes.markState()
    }

    /// Pages older history in (no-op when nothing older or already loading, and until the open settles).
    func loadOlder() {
        // [transcript] §4.2: after a page that failed, paging waits for "Try again" (no request loop while failed).
        guard hasOlder, !isLoadingOlder, openSettled, olderTask == nil, !olderFailed else { return }
        AppLog.trace("history", "older page asked \(logIds) (scrolled to top), offset \(nextOffset)")
        olderTask = Task { [weak self] in await self?.loadOlderPage(fill: false) }
    }

    /// [transcript] "Try again" on the earlier-messages notice (and once by itself when the link comes back).
    func retryOlder() {
        guard olderFailed else { return }
        AppLog.trace("history", "older page try again \(logIds), offset \(nextOffset)")
        olderFailed = false
        changes.markState(); scheduleFlush()
        // The failed read may have been the one that completes the first 120 rows: read the same page again.
        guard hasOlder, !isLoadingOlder, olderTask == nil else { return }
        let fill = nextOffset < LiveChatSession.fullPageRows
        olderTask = Task { [weak self] in await self?.loadOlderPage(fill: fill) }
    }

    /// One older page joined on the oldest loaded row (03 §5.2: `limit+1`, `offset = nextOffset-1`, keep rows strictly
    /// before the join). `fill` = the background read that completes the first 120 rows.
    func loadOlderPage(fill: Bool) async {
        // A cancelled load (the screen went away) leaves the bookkeeping to whoever cancelled it.
        defer { if !Task.isCancelled { olderTask = nil } }
        guard let stored = readSessionId, hasOlder, !isLoadingOlder else { return }
        isLoadingOlder = true
        changes.markState(); scheduleFlush()
        defer { if !Task.isCancelled { isLoadingOlder = false; changes.markState(); scheduleFlush() } }
        let rows = fill ? max(1, LiveChatSession.fullPageRows - nextOffset) : LiveChatSession.fullPageRows
        var offset = max(0, nextOffset - 1)
        let olderStart = ContinuousClock.now
        let lids = logIds
        for attempt in 0..<LiveChatSession.olderReads {
            let request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: rows + 1, offset: offset)
            AppLog.trace("history", "older page \(lids) read \(attempt + 1): offset \(offset), limit \(rows + 1), fill=\(fill), join row \(oldestRowId.map(String.init) ?? "-")")
            let fetched: (HistoryPage, usedPlugin: Bool)?
            do { fetched = try await HistoryAPI.fetch(client: client, request: request, features: perfFeatures) } catch {   // [diagnostics]
                AppLog.swallowed("history", "older page \(lids) at offset \(offset)", error)
                fetched = nil
            }
            guard !Task.isCancelled else { return }
            // [transcript] §4.2: the read failed (no answer, or not a 2xx): say so; paging waits for "Try again".
            guard let (page, _) = fetched else {
                AppLog.note("history", "older page \(lids) failed at offset \(offset); \"Try again\" shown")
                olderFailed = true; return
            }
            guard let join = oldestRowId else {
                AppLog.trace("history", "older page \(lids): no oldest row id to join on; hasOlder=false")
                hasOlder = false
                return
            }
            let ids = page.rows.map(HistoryPage.rowId)
            let got = ids.compactMap { $0 }
            AppLog.trace("history", "older page \(lids): \(page.rows.count) rows (\(got.first.map(String.init) ?? "-")…\(got.last.map(String.init) ?? "-")), more=\(page.possiblyTruncated), \(AppLog.ms(since: olderStart)) ms")
            if page.rows.isEmpty { AppLog.trace("history", "older page \(lids): empty, start reached"); hasOlder = false; return }
            if let at = ids.firstIndex(of: join) {
                if at == 0 {
                    // Nothing older in this page: either the start, or our offset is stale. (A too-large page is re-read
                    // with a smaller limit, so compare with what was actually asked.)
                    if !page.possiblyTruncated || page.rows.count < (page.requestedLimit ?? rows + 1) {
                        AppLog.trace("history", "older page \(lids): join row \(join) is the oldest, start reached")
                        hasOlder = false; return
                    }
                    AppLog.trace("history", "older page \(lids): join row \(join) first in a full page, offset stale; reading further back")
                    offset += page.rows.count
                    continue
                }
                AppLog.trace("history", "older page \(lids): joined on row \(join) at \(at), \(at) older rows to add")
                await prependOlder(rows: Array(page.rows[..<at]), page: page)
                return
            }
            if ids.compactMap({ $0 }).allSatisfy({ $0 > join }) {
                // Rows were saved since we paged: the window moved newer; read further back.
                AppLog.trace("history", "older page \(lids): all rows newer than join \(join) (rows saved since), reading further back")
                offset += page.rows.count
                continue
            }
            // No join (rows rewritten): keep only what is strictly older than what is shown.
            let older = page.rows.filter { (HistoryPage.rowId($0) ?? Int.max) < join }
            AppLog.trace("history", "older page \(lids): join row \(join) not in page (rows rewritten/thinned), \(older.count) strictly older kept")
            if older.isEmpty { hasOlder = false; return }
            await prependOlder(rows: older, page: page)
            return
        }
        // Rows saved while the chat stayed open moved the window newer than the offset: the reads above stepped over
        // nothing but rows newer than the join, so the next page starts where they stopped (a long-open chat with a
        // long agent run otherwise drifted past the reach of every later page, and scrolling up loaded nothing).
        nextOffset = max(nextOffset, offset + 1)
        AppLog.note("history", "older page \(lids): no join after \(LiveChatSession.olderReads) reads (window kept moving); next page from offset \(nextOffset)")
    }

    /// Reads an older page makes looking for its join row before it stops for now.
    static let olderReads = 6

    private func prependOlder(rows: [JSONValue], page: HistoryPage) async {
        var kept = rows
        // Same turn rule as the first page: don't split a turn when the cut keeps ≥ half (03 §4.4).
        var dropped = 0
        if kept.count >= 4, let first = kept.firstIndex(where: { ["user", "system"].contains($0["role"]?.string ?? "") }),
           first > 0, (kept.count - first) * 2 >= kept.count, page.possiblyTruncated {
            kept.removeFirst(first)
            dropped = first
        }
        // The partial turn at the top of what is shown is folded again together with these older rows, so a turn that
        // crosses the page boundary reads as one reply (verification round 2: a 70-step turn reloaded as "Ran 11",
        // "Ran 48, used 1 tool" and "Ran 11, used 1 tool", the stray tool being a result whose call was a page away).
        let head = headRows
        let joint = kept + head
        let folded = await LiveChatSession.foldOffMain(joint, accountId: account.id)
        guard !Task.isCancelled else { return }
        let headCount = head.isEmpty ? 0 : shownHeadCount(head)
        let existing = Set(messages[headCount...].map(\.id)).union(aliases.keys)
        // [presence] a titled request among the older rows shows its title, as the newest page's does
        let fresh = LiveChatSession.sentTitles.applied(to: folded.messages.filter { !existing.contains($0.id) })
        guard !fresh.isEmpty else {
            AppLog.trace("history", "older rows \(logIds): \(rows.count) rows folded to \(folded.messages.count), all already shown; hasOlder=false")
            hasOlder = false
            return
        }
        // Offsets: the page covers [offset, offset+count) from the newest end; its oldest kept row sits at
        // offset + count - 1 - dropped.
        let pageOffset = page.pagination?.offset ?? page.requestedOffset
        nextOffset = pageOffset + page.rows.count - dropped
        oldestRowId = kept.lazy.compactMap(HistoryPage.rowId).first ?? oldestRowId
        kept.compactMap(HistoryPage.rowId).forEach { loadedRowIds.insert($0) }
        hasOlder = page.possiblyTruncated || dropped > 0
        headRows = hasOlder ? LiveChatSession.leadingPartial(joint) : []
        let old = messages
        AppLog.trace("history", "older rows \(logIds): \(rows.count) rows (\(dropped) dropped to keep turns whole) + \(head.count) head rows refolded → \(fresh.count) new messages, \(folded.messages.count - fresh.count) already shown, \(headCount) top messages replaced; next offset \(nextOffset), hasOlder=\(hasOlder)")
        for m in old[..<headCount] { metaById[m.id] = nil }
        messages = TranscriptMerge.diff(old: old, new: fresh + old[headCount...], into: &changes)
        let freshIds = Set(fresh.map(\.id))
        for (id, mm) in folded.meta where freshIds.contains(id) { metaById[id] = mm }
        rebuildIndex()
        scheduleFlush()
    }

    /// How many messages at the top of the transcript were folded from `head` (the partial turn's raw rows).
    func shownHeadCount(_ head: [JSONValue]) -> Int {
        let headRowIds = Set(head.compactMap(HistoryPage.rowId))
        var count = 0
        for m in messages {
            guard !m.isLocal, m.role != .user else { break }
            if let row = m.rowId ?? metaById[m.id]?.firstRowId {
                guard headRowIds.contains(row) else { break }
            } else if !headRowIds.isEmpty {
                break
            }
            count += 1
        }
        return count
    }

    /// Joins older rows onto `start` (a page read from the newest end) until `enough` holds for the rows, the chat's
    /// start, or `reachCap` rows. Each read overlaps one row with what is held (the 03 §5.2 join).
    func extendBack(_ start: HistoryPage, stored: String, until enough: ([JSONValue]) -> Bool) async -> (page: HistoryPage, grew: Bool) {
        var page = start
        var grew = false
        var reads = 0
        while page.isLatestTail, page.possiblyTruncated, page.rows.count < LiveChatSession.reachCap, !enough(page.rows),
              reads < 8, !Task.isCancelled {
            reads += 1
            guard let join = page.rows.lazy.compactMap(HistoryPage.rowId).first else { break }
            let covered = page.nextOffset
            let want = min(LiveChatSession.fullPageRows, LiveChatSession.reachCap - page.rows.count)
            let request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: want + 1, offset: max(0, covered - 1))
            let olderPage: HistoryPage?
            do { olderPage = try await HistoryAPI.fetch(client: client, request: request, features: perfFeatures).0 } catch {   // [diagnostics]
                AppLog.swallowed("history", "extend back \(AppLog.tag(stored)) read \(reads) at offset \(max(0, covered - 1))", error)
                olderPage = nil
            }
            guard let older = olderPage, !Task.isCancelled else { break }
            var p = page.pagination ?? HistoryPagination(limit: nil, offset: 0, order: "latest", returned: page.rows.count)
            let ids = older.rows.map(HistoryPage.rowId)
            let added: [JSONValue]
            if let at = ids.firstIndex(of: join) {
                added = Array(older.rows[..<at])
            } else if !older.rows.isEmpty, ids.compactMap({ $0 }).allSatisfy({ $0 > join }) {
                // Rows were saved since the first read: the window moved newer; read further back.
                p.nextOffset = (older.pagination?.offset ?? older.requestedOffset) + older.rows.count
                page.pagination = p
                continue
            } else {
                added = older.rows.filter { (HistoryPage.rowId($0) ?? Int.max) < join }
            }
            AppLog.trace("history", "extend back \(AppLog.tag(stored)) read \(reads): \(older.rows.count) rows, \(added.count) older than join \(join) added, now \(added.count + page.rows.count)")
            page.rows = added + page.rows
            p.returned = page.rows.count
            p.nextOffset = older.nextOffset
            p.hasMore = older.possiblyTruncated && !added.isEmpty
            page.pagination = p
            if added.isEmpty { break }
            grew = true
        }
        return (page, grew)
    }

    /// What a refreshed tail must reach so the newest turn on screen is read whole: the newest prompt shown (by its row,
    /// or its text while it has none), else the newest stored row shown, else any turn start.
    func tailReach() -> ([JSONValue]) -> Bool {
        let meta = metaById
        func storedRow(_ m: ChatMessage) -> Int? { m.isLocal ? nil : (m.rowId ?? meta[m.id]?.firstRowId) }
        func oldest(_ rows: [JSONValue]) -> Int { rows.compactMap(HistoryPage.rowId).min() ?? Int.max }
        if let u = messages.lastIndex(where: { $0.role == .user }) {
            let prompt = messages[u]
            if let row = prompt.rowId { return { oldest($0) <= row } }
            let before = messages[..<u].compactMap(storedRow).max()
            let text = Hydration.userDisplayKey(prompt.plainText) // [attachments]
            return { rows in
                if let before, oldest(rows) <= before { return true }
                guard !text.isEmpty else { return false }
                return rows.contains { row in
                    guard row["role"]?.string == "user" else { return false }
                    let content = Hydration.text(from: row["content"] ?? .null)
                    return Hydration.userDisplayKey(content).contains(text)
                }
            }
        }
        if let newest = messages.compactMap(storedRow).max() { return { oldest($0) <= newest } }
        return { $0.contains(where: LiveChatSession.isTurnStart) }
    }

    /// Folds rows off the main thread; decoded inline images land in `accountId`'s media folder ([attachments]).
    @concurrent
    static func foldOffMain(_ rows: [JSONValue], accountId: String? = nil) async -> HydratedPage {
        InlineMediaStore.$accountId.withValue(accountId) { Hydration.fold(rows) }
    }

    // MARK: Refresh probe (03 §7.6)

    /// Pull-to-refresh / manual refresh: probe-first tail read.
    func refresh() {
        guard openSettled else { return }
        startRefresh(force: false)
    }

    func startRefresh(force: Bool) {
        if refreshTask != nil {
            AppLog.trace("history", "tail read \(logIds) asked while one runs: one more pass after it (force=\(force || refreshAgainForce))")
            // One more pass after this one; a forced request stays forced (a turn-end or watchdog read is never a probe).
            refreshAgain = true
            refreshAgainForce = refreshAgainForce || force
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshTail(force: force)
            guard generation == self.refreshGeneration else { return }
            self.refreshTask = nil
            if self.refreshAgain {
                let again = self.refreshAgainForce
                self.refreshAgain = false
                self.refreshAgainForce = false
                self.startRefresh(force: again)
            }
        }
    }

    /// A 24-row tail read started ahead of time (the reconnect's, beside its `session.activate`).
    typealias TailSeed = Task<(HistoryPage, HydratedPage, usedPlugin: Bool)?, Never>

    /// `readChangedTail`: limit=1 probe → 24 rows → 120 rows when the 24 don't overlap what is held. `isCurrent` lets a
    /// caller that may have been superseded (an older reconnect) drop the result instead of applying it. `seed`: the
    /// 24-row read already made, used in place of the probe and the 24-row read while no turn runs.
    func refreshTail(force: Bool, isCurrent: () -> Bool = { true }, seed: TailSeed? = nil) async {
        guard let stored = readSessionId else { return }
        // MENUS: after a rewind the stored rows were rewritten under new ids: read the newest page whole instead.
        if !turn.busy, await reloadWholeIfOwed() { AppLog.trace("history", "tail read \(logIds): whole reload after a rewind instead"); return }
        let tailStart = ContinuousClock.now
        let lids = logIds
        let features = perfFeatures
        // The reconnect's and the watchdog's reads run beside the one-at-a-time refresh: one that started later and has
        // already been applied holds newer rows, so this one is dropped instead of cutting them away.
        tailReadSerial += 1
        let serial = tailReadSerial
        let shownMatchesSync = lastSyncIds == messages.map(\.id)
        let probeServes = shownMatchesSync || (lastSyncAt.map { Date().timeIntervalSince($0) < 5 } ?? false)
        var seeded: (HistoryPage, HydratedPage, usedPlugin: Bool)?
        if let seed, !turn.busy, turn.streamId == nil { seeded = await seed.value }
        if !force, let signature = newestSignature, probeServes, let (page, _, _) = seeded {
            // The seed's newest row answers what the limit-1 probe would.
            if page.isLatestTail, let row = page.rows.last, HistoryAPI.signature(row) == signature {
                AppLog.trace("history", "tail read \(lids): seed's newest row is the one shown, nothing new")
                lastSyncAt = Date()
                noteStoredRows(page.rows)
                reportSeenAfterLeaving()
                return
            }
            AppLog.trace("history", "tail read \(lids): seed's newest row differs from the one shown, applying it")
        } else if !force, let signature = newestSignature, probeServes {
            let probe = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: 1)
            if let (page, _) = try? await HistoryAPI.fetch(client: client, request: probe, features: features),
               page.isLatestTail, let row = page.rows.last, HistoryAPI.signature(row) == signature {
                AppLog.trace("history", "tail probe \(lids): newest row \(HistoryPage.rowId(row).map(String.init) ?? "-") is the one shown, nothing new, \(AppLog.ms(since: tailStart)) ms")
                lastSyncAt = Date()
                noteStoredRows(page.rows)
                reportSeenAfterLeaving()
                return
            }
            AppLog.trace("history", "tail probe \(lids): newest row changed (or probe failed), reading 24")
        } else {
            AppLog.trace("history", "tail read \(lids): no probe (force=\(force), signature=\(newestSignature != nil), shown matches last sync=\(shownMatchesSync), seed=\(seeded != nil))")
        }
        // The page must reach the newest turn shown (its prompt), so that turn is read whole: a long tool-heavy turn has
        // more rows than one read, and a page that started mid-turn showed the reply twice, the stored copy above your
        // own message (verification round 2).
        let reach = tailReach()
        let small = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: 24)
        let read: (HistoryPage, HydratedPage, usedPlugin: Bool)?
        if let seeded { read = seeded } else {
            read = try? await HistoryAPI.fetchAndFold(client: client, request: small, features: features, cut: false)
        }
        guard var (page, folded, _) = read else { AppLog.note("history", "tail read \(lids): 24-row read failed, \(AppLog.ms(since: tailStart)) ms; nothing changed"); return }
        var readFailed = false
        if page.possiblyTruncated && !reach(page.rows) {
            // The 24 rows don't reach the newest turn: read 120. If that read fails, the 24 rows are still the newest truth.
            AppLog.trace("history", "tail read \(lids): 24 rows don't reach the newest turn shown, reading \(LiveChatSession.fullPageRows)")
            let full = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: LiveChatSession.fullPageRows)
            if let (p2, f2, _) = try? await HistoryAPI.fetchAndFold(client: client, request: full, features: features, cut: false) {
                page = p2; folded = f2
            } else {
                AppLog.note("history", "tail read \(lids): \(LiveChatSession.fullPageRows)-row read failed; using the 24 rows")
                readFailed = true
            }
        }
        var grew = false
        if !readFailed {
            let extended = await extendBack(page, stored: stored, until: reach)
            page = extended.page
            grew = extended.grew
        }
        // Rows before the page's first turn start belong to an older, finished turn that is already shown: dropping them
        // keeps a part of it from replacing the whole of it.
        var trimmed = 0
        if page.possiblyTruncated, reach(page.rows), let start = page.rows.firstIndex(where: LiveChatSession.isTurnStart), start > 0 {
            page.rows.removeFirst(start)
            trimmed = start
        }
        if grew || trimmed > 0 { folded = await LiveChatSession.foldOffMain(page.rows, accountId: account.id) }
        guard isCurrent() else { AppLog.trace("history", "tail read \(lids): superseded by a newer reconnect, dropped"); return }
        guard serial > tailReadApplied else {
            AppLog.trace("history", "tail read \(lids): a read started after it was applied first, dropped (\(serial) ≤ \(tailReadApplied))")
            return
        }
        tailReadApplied = serial
        let tailIds = page.rows.compactMap(HistoryPage.rowId)
        AppLog.trace("history", "tail read \(lids): \(page.rows.count) rows (\(tailIds.first.map(String.init) ?? "-")…\(tailIds.last.map(String.init) ?? "-")), grew=\(grew), \(trimmed) leading rows trimmed, more=\(page.possiblyTruncated), busy=\(turn.busy), seed=\(seeded != nil), \(AppLog.ms(since: tailStart)) ms")
        noteStoredRows(page.rows)
        let pageRowIds = page.rows.compactMap(HistoryPage.rowId)
        pageRowIds.forEach { loadedRowIds.insert($0) }
        // [catch-up] build 292: while a turn runs the page is cut after its prompt (`replaceTranscript`), so its newest
        // row is not what is shown: a later limit-1 probe must not take it as read (the reply stayed hidden until a
        // reopen when the turn then settled without a frame).
        let cutsLiveTurn = (turn.busy || turn.streamId != nil) && !turnNotOnGateway
        newestSignature = cutsLiveTurn ? nil : page.rows.last.map(HistoryAPI.signature) ?? newestSignature
        noteCatchUp("tail \(page.rows.count) rows\(cutsLiveTurn ? " busy" : "")\(seeded != nil ? " seed" : "")")
        let before = messages.count
        let keptOlder = replaceTranscript(with: folded, replaceAll: false)
        settleLostSends()                               // [sessions-m9] a marked send the page now holds did arrive
        AppLog.trace("history", "tail read applied \(lids): \(before) → \(messages.count) rows, \(keptOlder ? "older rows kept" : "page replaced the screen, paging restarts at offset \(page.nextOffset)")")
        if !keptOlder {
            // The page replaced what was shown: paging continues from its oldest row.
            nextOffset = page.nextOffset
            oldestRowId = pageRowIds.first
            loadedRowIds = Set(pageRowIds)
            hasOlder = page.possiblyTruncated || trimmed > 0
            headRows = hasOlder ? LiveChatSession.leadingPartial(page.rows) : []
            changes.markState()
        } else if let newestHead = headRows.compactMap(HistoryPage.rowId).max(), let first = pageRowIds.min(), first <= newestHead {
            // The page re-read rows of the partial turn on top: its raw rows no longer match what is shown.
            headRows = []
        }
        lastSyncAt = Date()
        lastSyncIds = messages.map(\.id)
        saveCache()
        reportSeenAfterLeaving()
        checkExternalWork("new rows")                   // [external-turn] rows written by another process?
    }

    /// Notes the newest stored time a history read returned (`seenThrough`).
    func noteStoredRows(_ rows: [JSONValue]) {
        guard let newest = HistoryPage.newestTimestamp(rows), newest > (newestStoredAt ?? 0) else { return }
        newestStoredAt = newest
    }

    /// The read owed when the chat was left after its turn ended has landed: report how far that turn was seen.
    func reportSeenAfterLeaving() {
        guard seenOwedAfterLeave, !observing else { return }
        seenOwedAfterLeave = false
        if let seen = seenThrough { onSeenAfterLeaving?(seen) }
    }

    // MARK: First page owed (03 §4.7)

    /// Reads the first page again after `delay` (one try in flight; a reconnect asks again at once).
    func retryFirstPageSoon(after delay: Duration) {
        guard firstPageOwed, observing else { return }
        firstPageTask?.cancel()
        firstPageTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, self.firstPageOwed else { return }
            await self.retryFirstPage()
        }
    }

    /// One more try at the open's history read. Lands like the open's own read (wholesale over what is shown, then the
    /// background older page); after the last try fails with nothing shown, the screen shows the failure and Retry.
    func retryFirstPage() async {
        guard firstPageOwed, let stored = readSessionId else { return }
        firstPageTries += 1
        let request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: 24)
        let result: (HistoryPage, HydratedPage, usedPlugin: Bool)?
        do { result = try await HistoryAPI.fetchAndFold(client: client, request: request, features: perfFeatures, cut: true) } catch {   // [diagnostics]
            AppLog.note("history", "first page retry \(firstPageTries) \(logIds) failed: \(LiveChatSession.logError(error))")
            result = nil
        }
        guard firstPageOwed, !Task.isCancelled else { return }
        firstPageTask = nil
        guard let (page, folded, _) = result else {
            if firstPageTries >= firstPageRetryDelays.count {
                AppLog.note("history", "first page \(logIds): gave up after \(firstPageTries) tries, rows shown \(messages.count)\(messages.isEmpty ? ", error screen" : "")")
            }
            if firstPageTries < firstPageRetryDelays.count {
                retryFirstPageSoon(after: firstPageRetryDelays[firstPageTries])
            } else {
                firstPageOwed = false
                if messages.isEmpty { openError = "Couldn't load this chat." }
                changes.markState()
                scheduleFlush()
            }
            return
        }
        firstPageOwed = false
        AppLog.trace("history", "first page retry \(firstPageTries) \(logIds): got \(page.rows.count) rows")
        applyFirstPage(page, folded)
        changes.markState()
        scheduleFlush()
        if hasOlder && nextOffset < 120 && observing && olderTask == nil {
            olderTask = Task { [weak self] in await self?.loadOlderPage(fill: true) }
        }
        onOpenSettled?(true)
        checkExternalWork("first page")                 // [external-turn]
    }

    /// The turn's end read waits 1.2 s so the gateway's last `sessions.changed` produces one read (03 §4.6).
    func scheduleTurnEndRead(force: Bool = false) {
        turnEndTask?.cancel()
        let delay = turnEndReadDelay
        turnEndTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.turnEndTask = nil
            guard !self.turn.busy || force else { AppLog.trace("history", "turn-end read \(self.logIds) skipped: a new turn runs"); return }
            AppLog.trace("history", "turn-end read \(self.logIds) (force=\(force))")
            self.lastTurnEndReadAt = Date()
            self.startRefresh(force: force)
        }
    }

    /// [owner-wait] Our send waits for another process's run (4090): its turn hasn't reached the gateway, so the reply
    /// that run saves is only announced by `sessions.changed`, and a read must not cut it as part of our turn.
    var turnNotOnGateway: Bool { turn.waitingForOwner != nil }

    /// `sessions.changed`: one open-chat pass per 10 s (leading edge when the gap has passed, else one trailing
    /// pass), none while our own turn runs or off screen; a read since the turn ended serves for 12 s (03 §7.7).
    func scheduleChangedPass() {
        // The turn-end read is owed (1.2 s after the turn ended): it is the one read for this tick too (03 §4.6).
        guard observing, openSettled, changedPassTask == nil, turnEndTask == nil else { return }
        if reconnectOwnsTail { return }      // [offline] §6.5: the reconnect's own read is the one for this tick
        let gap = changedPassGap
        let now = Date()
        let gapSeconds = Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18
        let wait = lastChangedPassAt.map { max(0, gapSeconds - now.timeIntervalSince($0)) } ?? 0
        changedPassTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.changedPassTask = nil
            guard self.observing, !self.turn.busy || self.turnNotOnGateway, self.turnEndTask == nil else { return }
            if let read = self.lastTurnEndReadAt, Date().timeIntervalSince(read) < 12 { return }
            AppLog.trace("history", "sessions.changed pass \(self.logIds): tail read")
            self.lastChangedPassAt = Date()
            self.startRefresh(force: false)
        }
    }

    // MARK: Inflight graft (03 §4.5, 04 §7.3–7.4)

    /// Applies a resume/activate snapshot: running state, the in-flight turn after the REST transcript, queued prompt.
    func graftInflight(_ snapshot: JSONValue?) {
        guard let snap = snapshot?.object else { return }
        let running = snap["running"]?.bool ?? false
        noteCatchUp("graft running \(running)")            // [doubled-reply]
        AppLog.trace("turn", "snapshot \(logIds): running=\(running), inflight=\(snap["inflight"]?.object != nil), queued=\(snap["queued"]?["user"]?.nonEmptyString != nil), was busy=\(turn.busy) live=\(turn.turnLive) stopped=\(turn.interrupted)")
        if running && !turn.interrupted {
            if !turn.busy || !turn.turnLive {
                // A turn we didn't see start: its own prompt is set by the inflight graft below, if it has one.
                if !turn.busy { turn.userAnchorId = nil; turn.anchorPromptKey = nil }
                turn.busy = true
                turn.turnLive = true
                turn.turnStartedAt = snap["turn_started_at"]?.double.map { Date(timeIntervalSince1970: $0) } ?? turn.turnStartedAt ?? Date()
                changes.markState()
                armWatchdog()
            }
        } else if !running {
            // A stopped turn that unwound while we were away: nothing more will hold the next send (04 §5.4).
            if turn.stopTerminalPending { stopTerminalReached() }
            releaseSendPastStop("the snapshot says nothing runs")
            if turn.busy && turn.turnLive {
                // The turn ended while we were away; the REST read already holds it.
                AppLog.trace("turn", "snapshot \(logIds): the turn ended while away; live row \(AppLog.tag(turn.streamId)) sealed, settled")
                if let sid = turn.streamId, indexById[sid] != nil {
                    updateMessage(sid) { m in m.isStreaming = false; LiveChatSession.sealTools(&m, summary: "Result unavailable") }
                }
                settleFlags()
                changes.markState()
            }
            if !turn.busy { turn.idleConfirmed = true }
        }
        if let inflight = snap["inflight"]?.object { graftInflightTurn(inflight, running: running) }
        if let queued = snap["queued"]?["user"]?.nonEmptyString,
           !messages.suffix(3).contains(where: { $0.role == .user && Hydration.userDisplayKey($0.plainText) == Hydration.userDisplayKey(queued) }) {
            localCounter += 1
            AppLog.trace("turn", "snapshot \(logIds): gateway's queued prompt not shown, bubble added")
            appendMessage(ChatMessage(id: "local-user-queued-\(localCounter)", role: .user, parts: [.text(queued)], timestamp: Date(), rowId: nil))
        }
        scheduleFlush()
    }

    private func graftInflightTurn(_ inflight: [String: JSONValue], running: Bool) {
        flushDeltas()
        let corrections = InflightCorrections(inflight)
        if let user = inflight["user"]?.nonEmptyString, let note = Self.inflightNote(user, inflight) {
            if running { turn.inflightUserKey = Hydration.userDisplayKey(user) }
            graftInflightNote(note, prompt: user, running: running)
        } else if let user = inflight["user"]?.nonEmptyString {
            if running { turn.inflightUserKey = Hydration.userDisplayKey(user) }
            // A steer is stored as a prompt of its own mid-turn: the turn's prompt is the newest one that isn't a steer.
            let lastUser = corrections.map { c in messages.last { $0.role == .user && !c.isCorrection($0.plainText) } }
                ?? messages.last { $0.role == .user }
            let shown = lastUser.map { Hydration.userDisplayKey($0.plainText) } ?? ""      // [attachments] display key
            if lastUser == nil || shown != Hydration.userDisplayKey(user) {
                localCounter += 1
                let id = "local-user-inflight-\(localCounter)"
                // [attachments] The submitted text leads with the files' `@file:` refs: they show as file rows, not as
                // a raw path, until the stored row arrives (docs/spec/1x-attachments.md §7.1).
                let lifted = AttachmentHydration.liftText(user)
                AppLog.trace("turn", "inflight \(logIds): its prompt isn't the newest shown, prompt bubble \(AppLog.tag(id)) added (running=\(running))")
                appendMessage(ChatMessage(id: id, role: .user, parts: [.text(lifted.text)], timestamp: turn.turnStartedAt ?? Date(), rowId: nil))
                if !lifted.attachments.isEmpty {
                    var meta = metaById[id] ?? MessageMeta()
                    meta.attachments = lifted.attachments
                    meta.attachmentRefs = lifted.refs
                    metaById[id] = meta
                    applyKnownMediaSizes()
                }
                if running { turn.userAnchorId = id; turn.anchorPromptKey = Hydration.userDisplayKey(user) }
            } else if let lastUser {
                if running { turn.userAnchorId = lastUser.id; turn.anchorPromptKey = Hydration.userDisplayKey(user) }   // the gateway says the newest prompt shown is the running turn's
                // The gateway holds this prompt: a send whose ack was lost was delivered after all (04 §2.5).
                if lastUser.isLocal, lastUser.error == LiveChatSession.unconfirmedMark {
                    AppLog.note("send", "send \(AppLog.tag(lastUser.id)) was delivered after all (gateway's inflight prompt); unconfirmed mark cleared")
                    updateMessage(lastUser.id) { m in m.error = nil }
                    clearLostSend(lastUser.id)          // [sessions-m9]
                }
            }
        }
        var assistantText = inflight["assistant"]?.string ?? ""
        var lastUser = turnAnchorIndex()
        if let corrections {
            // The reply after the last steer goes below it; what came before stays where it is.
            (assistantText, lastUser) = graftCorrections(corrections, assistant: assistantText)
            if let sid = turn.streamId, let index = indexById[sid], index <= lastUser { turn.streamId = nil; turn.openPart = nil }
        }
        let turnAssistants = messages[(lastUser + 1)...].filter { $0.role == .assistant }
        var targetId: String?
        if let sid = turn.streamId, let index = indexById[sid], index > lastUser {
            targetId = sid
        } else if let partial = turnAssistants.last {
            // Stored history already holds this turn's partial rows: fold into that message (04 §7.4).
            targetId = partial.id
        }
        if let id = targetId, let index = indexById[id] {
            let m = messages[index]
            let structured = m.parts.contains { if case .text = $0 { return false } else { return true } }
            let shownText = ChatText.flat(m.plainText)
            let extends = ChatText.flat(assistantText).hasPrefix(shownText)
            let applies = !assistantText.isEmpty && extends && (!(structured && turn.streamId == id && m.isLocal) || shownText.isEmpty)
            AppLog.trace("turn", "inflight \(logIds): reply text → \(AppLog.tag(id)) (\(id == turn.streamId ? "live row" : "stored partial")), \(applies ? "text \(shownText.count) → \(assistantText.count) chars" : "text kept (\(assistantText.isEmpty ? "none" : extends ? "structured live row" : "doesn't extend shown"))"), running=\(running)")
            if !assistantText.isEmpty, extends, !(structured && turn.streamId == id && m.isLocal) || shownText.isEmpty {
                updateMessage(id) { msg in msg.parts = TranscriptMerge.mergeFinalText(msg.parts, assistantText) }
            }
            updateMessage(id) { msg in msg.isStreaming = running }
            if running { turn.streamId = id }
        } else if !assistantText.isEmpty {
            localCounter += 1
            noteCatchUp("inflight bubble")                  // [doubled-reply]
            AppLog.trace("turn", "inflight \(logIds): no row for the turn's reply, inflight bubble added (\(assistantText.count) chars, running=\(running))")
            var m = ChatMessage(id: "local-assistant-inflight-\(localCounter)", role: .assistant, parts: [.text(assistantText)],
                                timestamp: turn.turnStartedAt ?? Date(), rowId: nil)
            m.isStreaming = running
            appendMessage(m)
            if running { turn.streamId = m.id }
        }
        if let sid = turn.streamId, let index = indexById[sid] {
            let parts = messages[index].parts
            if case .text? = parts.last { turn.openPart = (parts.count - 1, false) } else { turn.openPart = nil }
            if !assistantText.isEmpty { turn.sawAssistantPayload = true; turn.awaitingResponse = false }
        }
        if let error = inflight["error"]?.nonEmptyString, inflight["status"]?.string == "error" {
            let id = turn.streamId ?? messages[(lastUser + 1)...].last(where: { $0.role == .assistant })?.id
            if let id { updateMessage(id) { m in m.error = error; m.isStreaming = false } }
        }
    }

    /// [helper-note] The running turn's prompt when Hermes started the turn with a note of its own (a helper's or a
    /// background task's result: `display_kind` async_delegation_complete, process_complete, …), as history draws that
    /// note; nil for a prompt drawn as a bubble. An older gateway sends no kind: its "[ASYNC DELEGATION …" text is a
    /// helper's all the same.
    static func inflightNote(_ user: String, _ inflight: [String: JSONValue]) -> (message: ChatMessage, meta: MessageMeta)? {
        var row: [String: JSONValue] = ["role": "user", "content": .string(user), "_synthetic": true]
        if let kind = inflight["display_kind"]?.nonEmptyString {
            row["display_kind"] = .string(kind)
            if let meta = inflight["display_metadata"] { row["display_metadata"] = meta }
        } else if user.hasPrefix("[ASYNC DELEGATION") {
            row["display_kind"] = "internal_notification"
        } else {
            return nil
        }
        let page = Hydration.fold([.object(row)])
        guard page.messages.count == 1, let note = page.messages.first, note.role == .system else { return nil }
        return (note, page.meta[note.id] ?? MessageMeta())
    }

    /// [helper-note] The turn's note anchors its reply, as a prompt bubble would. The stored note shown after the newest
    /// prompt is the one (Hermes saves its row before the turn starts, so the first page holds it); when the page
    /// doesn't hold it yet, the note is drawn as history draws it and the stored row takes its place in a later read
    /// (TranscriptMerge). Owner, 2026-10-30: a chat opened mid-reply drew the whole "[ASYNC DELEGATION COMPLETE — …]"
    /// block, the job's output and all, as a bubble of the owner's, under the one-line note it already showed.
    private func graftInflightNote(_ note: (message: ChatMessage, meta: MessageMeta), prompt: String, running: Bool) {
        let words = note.message.plainText
        let lastPrompt = messages.lastIndex { $0.role == .user } ?? -1
        let shown = messages.indices.last { i in
            guard i > lastPrompt, messages[i].role == .system else { return false }
            if messages[i].plainText == words { return true }
            return note.meta.asyncResult != nil && metaById[messages[i].id]?.asyncResult == note.meta.asyncResult
        }
        let id: String
        if let shown {
            id = messages[shown].id
            AppLog.trace("turn", "inflight \(logIds): its prompt is a note, shown as \(AppLog.tag(id)); no prompt bubble (running=\(running))")
        } else {
            localCounter += 1
            id = "local-note-inflight-\(localCounter)"
            var m = note.message
            m.id = id
            m.timestamp = turn.turnStartedAt ?? Date()
            AppLog.trace("turn", "inflight \(logIds): its prompt is a note not shown yet, note \(AppLog.tag(id)) added (running=\(running))")
            appendMessage(m)
            metaById[id] = note.meta
        }
        if running { turn.userAnchorId = id; turn.anchorPromptKey = Hydration.userDisplayKey(prompt) }
    }

    /// The snapshot's steers, oldest first: each is a user bubble inside the turn. Those shown (ours, or stored rows:
    /// Hermes saves a steer, and the reply before it, as rows of their own mid-turn) become the turn's own; one not shown
    /// yet is added under the reply text that came before it (`correction_offsets`: characters of `assistant` streamed
    /// when it arrived). Returns the reply text after the last steer and the row it follows.
    private func graftCorrections(_ c: InflightCorrections, assistant: String) -> (tail: String, after: Int) {
        let anchor = turnAnchorIndex()
        let scalars = Array(assistant.unicodeScalars)
        func segment(_ from: Int?, _ to: Int?) -> String {
            let lo = min(max(from ?? 0, 0), scalars.count), hi = min(max(to ?? scalars.count, lo), scalars.count)
            var out = String.UnicodeScalarView()
            out.append(contentsOf: scalars[lo..<hi])
            return String(out)
        }
        var after = anchor
        var added = 0
        var missing = false
        for (i, text) in c.texts.enumerated() {
            // One stored row can hold several steers that reached the model together.
            if after > anchor, messages[after].role == .user, c.covers(messages[after].plainText, text) { continue }
            if !missing, after + 1 < messages.count,
               let j = (after + 1..<messages.count).first(where: { messages[$0].role == .user && c.covers(messages[$0].plainText, text) }) {
                turn.correctionIds.insert(messages[j].id)
                after = j
                continue
            }
            missing = true
            let before = segment(i == 0 ? 0 : c.offsets?[i - 1], c.offsets?[i])
            let replyShown = after + 1 < messages.count && messages[(after + 1)...].contains { $0.role == .assistant && $0.hasVisibleContent }
            if c.offsets != nil, !replyShown, !ChatText.trimmed(before).isEmpty {
                localCounter += 1
                appendMessage(ChatMessage(id: "local-assistant-inflight-\(localCounter)", role: .assistant, parts: [.text(before)],
                                          timestamp: turn.turnStartedAt ?? Date(), rowId: nil))
            }
            localCounter += 1
            let id = "local-user-correction-\(localCounter)"
            appendMessage(ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: Date(), rowId: nil))
            turn.correctionIds.insert(id)
            after = messages.count - 1
            added += 1
        }
        AppLog.trace("turn", "inflight \(logIds): \(c.texts.count) steer(s) in the turn, \(added) added, reply after them \(c.offsets == nil ? "unknown (no offsets)" : "\(scalars.count - min(c.offsets?.last ?? 0, scalars.count)) chars")")
        // Without offsets the split is unknown: the deltas that follow fill the reply in below.
        return (c.offsets.map { segment($0.last, nil) } ?? "", after)
    }

    // MARK: Reconnect (04 §7)

    func handleReady(_ payload: JSONValue) {
        let epoch = payload["replay_epoch"]?.string
        if let features = PerformanceFeatures(ready: payload) { perfFeatures = features } else if payload["performance"] == nil { perfFeatures = nil }
        changeEvents = payload["change_events"]?.bool ?? changeEvents
        if let held = heldEpoch, let epoch, held != epoch {   // backend restarted: replay impossible
            AppLog.trace("chat", "ready \(logIds): replay epoch changed (gateway restarted), cursor \(lastSeq.map(String.init) ?? "-") dropped, side tasks lost")
            lastSeq = nil
            sideTasksLost()                                  // and a /btw or /bg that was out died with it
        }
        if let epoch { heldEpoch = epoch }
        everReady = true
        guard openSettled, isLive else { return }   // verify round 3: a chat draining its queue away catches up too
        if firstPageOwed { retryFirstPageSoon(after: .zero) }
        if joinsRunningReconnect() { AppLog.trace("chat", "ready \(logIds): joins the reconnect that just began"); return }      // [offline] §6.5: the reconnect that just began is this one
        resetActivateTimeoutRetries()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.reconnect(reason: "gateway.ready") }
    }

    /// Re-bind the chat on the new socket, then replay from the last seq; fall back to REST + inflight (04 §7.4 M1).
    /// Reconnects are serialised by a generation: a newer one (a flappy link sends `gateway.ready` twice) supersedes this
    /// one, which then neither applies anything nor releases the parked live frames the newer one still holds.
    func reconnect(reason: String) async {
        reconnectGeneration += 1
        let generation = reconnectGeneration
        parking = true
        func current() -> Bool { generation == reconnectGeneration && !Task.isCancelled }
        reconnectBegan()                 // [offline] §6.5
        noteCatchUp("reconnect \(reason)")   // [doubled-reply]
        let reconnectStart = ContinuousClock.now
        AppLog.trace("chat", "reconnect \(logIds) gen \(generation) (\(reason)): cursor \(lastSeq.map(String.init) ?? "-"), busy=\(turn.busy), live=\(turn.turnLive), stream \(AppLog.tag(turn.streamId)), rows=\(messages.count), \(observing ? "on screen" : "off screen")")
        var caughtUp = false
        var snapshot: JSONValue?
        var settledAway = false
        var readTail = false
        var activateTimedOut = false
        var settleAfterParked: JSONValue?
        // [perf] An idle chat with no cursor reads its tail by REST after the activate anyway: that read (plain REST, no
        // socket needed) starts now and runs beside the activate round trip. Applied only on fresh state (`refreshTail`).
        var prefetch: TailSeed?
        let prefetchStored = readSessionId
        if lastSeq == nil, !firstPageOwed, let stored = prefetchStored, !turn.busy, turn.streamId == nil, !menus.wholeReloadOwed {
            let request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: 24)
            let client = client, features = perfFeatures
            prefetch = Task { try? await HistoryAPI.fetchAndFold(client: client, request: request, features: features, cut: false) }
            AppLog.trace("history", "reconnect \(AppLog.tag(stored)): idle with no cursor, 24-row tail read started beside the activate")
        }
        defer {
            prefetch?.cancel()
            if generation == reconnectGeneration {
                AppLog.trace("chat", "reconnect \(logIds) gen \(generation) ended: caught up=\(caughtUp), tail read=\(readTail), settled away=\(settledAway), activate timed out=\(activateTimedOut), parked \(parked.count), cursor \(lastSeq.map(String.init) ?? "-"), rows=\(messages.count), \(AppLog.ms(since: reconnectStart)) ms")
                reconnectEnded(caughtUp: caughtUp, snapshot: snapshot, activateTimedOut: activateTimedOut)   // [offline] §6.3, §6.5
                parking = false
                releaseParked()
                if let snap = settleAfterParked {
                    flushDeltas()
                    if turn.busy && (!turn.awaitingResponse || turn.turnLive) {
                        // The replay stopped short of the turn's end: settled as before, and the tail recheck (§6.3),
                        // told above that the turn still ran, hears it ended.
                        graftInflight(snap)
                        if caughtUp { tailSettled(snap) }
                    } else if !turn.busy { turn.idleConfirmed = true }
                }
                if turn.busy, isLive { armWatchdog() }
                if !turn.busy { scheduleQueueDrain(after: turn.idleConfirmed ? .zero : queueDrainFallback) }
                scheduleFlush()
                // A reply that finished while the link was paused left no frame. With no read of the tail here, read it
                // now, not 1.2 s on (build 292: the screen showed it only after a reopen); forced when the turn was
                // settled here. A read just made (after any settle) gets the usual look 1.2 s on, unless this reconnect
                // just started a tail recheck (§6.3): its 2 s read of the same tail is that look, with more rows.
                if readTail {
                    if ChatReconnectState.existing(self)?.recheck?.firstStepPending != true { probeTailSoon() }
                } else {
                    probeTailSoon(after: .zero, force: settledAway)
                }
            }
        }
        var activated = false
        let linkedBefore = promptLink?.sessionIds ?? []
        if let rid = runtimeSessionId {
            var params: [String: JSONValue] = ["session_id": .string(rid), "cols": 96, "omit_messages": true]
            if let profileParam { params["profile"] = .string(profileParam) }
            if resumeFlight == nil { activating = true; resumeHeld = [] }
            do {
                snapshot = try await client.call("session.activate", .object(params), timeout: .seconds(30))
                guard current() else { releaseActivateHeld(); return }
                noteCatchUp("activate running \(snapshot?["running"]?.bool == true) inflight \(snapshot?["inflight"]?["assistant"]?.string?.count ?? -1)")
                AppLog.trace("chat", "reconnect activate \(logIds): running=\(snapshot?["running"]?.bool == true), \(snapshot?["session_id"]?.nonEmptyString.map { $0 != rid ? "new runtime \(AppLog.tag($0))" : "same runtime" } ?? "same runtime")")
                if let r = snapshot?["session_id"]?.nonEmptyString, r != rid { bindRuntime(snapshot!) }
                else {
                    if let snapshot { activityBound(snapshot, runtimeId: rid) }      // [activity] rebound: re-read
                    activated = true
                }
                releaseActivateHeld()
            } catch let error as RPCError where error.code == 4001 || error.code == 4007 {
                releaseActivateHeld()
                guard current() else { return }
                noteCatchUp("activate \(error.code)")
                AppLog.trace("chat", "reconnect activate \(logIds): \(error.code), runtime gone; cursor dropped, resuming")
                runtimeSessionId = nil
                lastSeq = nil
            } catch let error as RPCError where error.code == 4064 {
                AppLog.note("chat", "reconnect activate \(logIds): 4064 profile gone")
                releaseActivateHeld()
                onRosterStale?()
                return
            } catch let error as RPCError where error.isTimeout {
                // The socket is still up (no new gateway.ready will come): the reconnect's end tries the activate again.
                AppLog.note("chat", "reconnect activate \(logIds): timed out; retried at the reconnect's end")
                releaseActivateHeld()
                guard current() else { return }
                activateTimedOut = true
                return
            } catch {
                AppLog.trace("chat", "reconnect activate \(logIds): \(LiveChatSession.logError(error)); next gateway.ready retries")
                releaseActivateHeld()
                return          // socket not usable yet; the next gateway.ready retries
            }
        }
        if runtimeSessionId == nil {
            do { snapshot = try await resumeNow() } catch {
                AppLog.note("chat", "reconnect \(logIds): resume failed (\(LiveChatSession.logError(error))); not caught up")
                return
            }
        }
        guard current() else { AppLog.trace("chat", "reconnect gen \(generation) superseded by gen \(reconnectGeneration)"); return }
        // [questions] The runtime is confirmed: replay its approvals (a newly bound one already did in `promptRuntimeBound`).
        if let rid = runtimeSessionId, activated || linkedBefore.contains(rid) { approvalsConfirmed(rid) }
        // A Stop that never reached the turn (timeout, dropped link): the turn still runs, so interrupt it now.
        if turn.stopPending, snapshot?["running"]?.bool == true { reinterrupt() }
        // The connection may still be replaying what this session missed (spec 01 §13.3): its held frames reach us
        // first, so the catch-up below never races them.
        if let rid = runtimeSessionId { await client.replayDone(session: rid) }
        guard current() else { return }
        var needRest = lastSeq == nil
        // The connection's own replay (spec 01 §13.3) already handed this session's missed frames over: they sit in
        // `parked` (held while this reconnect runs). When they start right after our cursor they cover the gap, and
        // asking `session.events.since` again would only fetch the same events a second time.
        var coveredByReplay = false
        if !needRest, let rid = runtimeSessionId, let cursor = lastSeq {
            await Task.yield()
            guard current() else { return }
            let replayed = parked.filter { $0.sessionId == rid }.compactMap(\.seq)
            if let first = replayed.min(), first <= cursor + 1 { coveredByReplay = true }
            // The connection asked from at or before our cursor and handed over everything after it, even when that was
            // nothing (an empty replay leaves nothing parked).
            // Only for the socket that just came up: a chat back on screen may have missed frames the connection
            // delivered while it wasn't listening.
            else if reason == "gateway.ready", let from = await client.replayedCursor(session: rid), from <= cursor {
                coveredByReplay = true
            }
            AppLog.trace("chat", "reconnect \(logIds): cursor \(cursor), connection replay parked \(replayed.count) (first \(replayed.min().map(String.init) ?? "-")) → \(coveredByReplay ? "covers the gap" : "doesn't cover, asking events.since")")
            guard current() else { return }
        }
        if !needRest, !coveredByReplay, let rid = runtimeSessionId, let cursor = lastSeq {
            var params: [String: JSONValue] = ["session_id": .string(rid), "last_seen": .number(Double(cursor))]
            if let profileParam { params["profile"] = .string(profileParam) }
            do {
                let result = try await client.call("session.events.since", .object(params), timeout: .seconds(10))
                guard current() else { return }
                if let epoch = result["epoch"]?.string, let held = heldEpoch, epoch != held {
                    AppLog.trace("chat", "reconnect events.since \(logIds): epoch changed, cursor dropped, REST read")
                    heldEpoch = epoch
                    lastSeq = nil
                    needRest = true
                } else {
                    AppLog.trace("chat", "reconnect events.since \(logIds) from \(cursor): \(result["events"]?.array?.count ?? 0) events, latest \(result["latest_seq"]?.int.map(String.init) ?? "-"), truncated=\(result["truncated"]?.bool == true)\(result["truncated"]?.bool == true ? " → cursor moves to latest, REST read is the truth" : "")")
                    noteCatchUp("since \(result["events"]?.array?.count ?? 0)\(result["truncated"]?.bool == true ? " truncated" : "")")
                    for raw in result["events"]?.array ?? [] {
                        guard let type = raw["type"]?.string else { continue }
                        let event = GatewayEvent(type: type, sessionId: raw["session_id"]?.string ?? rid,
                                                 seq: raw["seq"]?.int, payload: raw["payload"] ?? .null)
                        if event.sessionId == rid { dispatch(event) }
                    }
                    if result["truncated"]?.bool == true {
                        // [doubled-reply] The ring lost frames after our cursor, so the read below is the truth up to now.
                        // The cursor moves to the gateway's newest seq instead of being dropped: the connection's own
                        // replay read the same ring, and its copies (parked until this reconnect ends) must stay stale.
                        // With no cursor they were dispatched after the read had settled the turn and drew its tail
                        // again as a second bubble (owner 2026-10-24: a 62-row turn, its tail from the second note on).
                        if let latest = result["latest_seq"]?.int { lastSeq = max(lastSeq ?? 0, latest) }
                        needRest = true
                    }
                }
            } catch {
                guard current() else { return }
                AppLog.trace("chat", "reconnect events.since \(logIds): \(LiveChatSession.logError(error)); REST read instead")
                needRest = true
            }
        }
        // [catch-up] build 292: a send whose turn never showed a frame here (the app left right after sending) and that
        // the gateway no longer runs ended while we were away (04 §7.2 step 3: busy flags are cleared on reconnect).
        settledAway = settleSendEndedAway(snapshot)
        if coveredByReplay { noteCatchUp("replay covered \(parked.count)") }
        if settledAway { noteCatchUp("settled away") }
        if settledAway { AppLog.note("chat", "return: the turn of a send ended while away; settled on ready") }
        let ended = snapshot?["running"]?.bool == false
        if needRest {
            // [perf] An idle chat with nothing settled here and a tail already read: the limit-1 probe answers when
            // nothing changed while away (the usual return), instead of a 24-120 row read and merge. A busy, streaming,
            // stopping or settled-away chat keeps the forced read (build 292).
            let idleUnchanged = !turn.busy && turn.streamId == nil && !settledAway && snapshot?["running"]?.bool != true
                && !turn.stopPending && !turn.stopTerminalPending && newestSignature != nil
            // [catch-up] The turn running now is the snapshot's: the read below cuts after its prompt. When the turn we
            // left running was another (ours ended and a queued or delivered one started while away), its prompt no
            // longer anchors the cut, or the finished turn's stored reply would be cut away with the new turn's rows.
            if snapshot?["running"]?.bool == true, let user = snapshot?["inflight"]?["user"]?.nonEmptyString {
                let key = Hydration.userDisplayKey(user)
                turn.inflightUserKey = key
                // Our own turn still running matches by the prompt it sent too: a skill, titled request or attachment
                // send shows other text in its bubble than `inflight.user` names.
                if let anchor = turn.userAnchorId, let i = indexById[anchor],
                   Hydration.userDisplayKey(messages[i].plainText) != key,
                   (turn.anchorPromptKey ?? Hydration.userDisplayKey(LiveChatSession.sentTitles.prompt(forTitle: messages[i].plainText)
                                                                      ?? messages[i].plainText)) != key {
                    AppLog.trace("turn", "reconnect \(logIds): running turn isn't the one we left (anchor \(AppLog.tag(turn.userAnchorId))); live row \(AppLog.tag(turn.streamId)) sealed, anchor dropped")
                    turn.userAnchorId = nil
                    turn.anchorPromptKey = nil
                    // Its live bubble is sealed (it takes its stored reply in the read), not carried as the new turn's.
                    flushDeltas()
                    if let sid = turn.streamId, indexById[sid] != nil {
                        updateMessage(sid) { m in m.isStreaming = false; LiveChatSession.sealTools(&m, summary: "Result unavailable") }
                    }
                    turn.streamId = nil
                    turn.openPart = nil
                    turn.turnStartedAt = snapshot?["turn_started_at"]?.double.map { Date(timeIntervalSince1970: $0) } ?? turn.turnStartedAt
                }
            }
            // A turn that ended is settled before the read: a busy chat cuts the stored reply off its page (04 §7.4).
            if ended {
                graftInflight(snapshot)
                // [doubled-reply] With no cursor of our own the connection's replay of the turn (parked, or still on its
                // way) can't be told from new frames: the read below holds everything up to the gateway's newest seq.
                if lastSeq == nil, let rid = runtimeSessionId {
                    await adoptLatestSeq(rid)
                    guard current() else { return }
                }
            }
            // An owed first page is read by its own retry (asked for again by `handleReady`).
            if !firstPageOwed {
                // The early read serves only when nothing moved under it: same stored chat, and no turn running or just
                // ended with a reply the page may predate (those read now; the 1.2 s look-again covers the rest).
                let seedFits = readSessionId == prefetchStored && snapshot?["running"]?.bool != true
                    && (snapshot?["inflight"]?["assistant"]?.string ?? "").isEmpty
                AppLog.trace("history", "reconnect \(logIds): REST tail read (force=\(!idleUnchanged), seed \(prefetch == nil ? "none" : seedFits ? "used" : "unfit"), ended=\(ended))")
                await refreshTail(force: !idleUnchanged, isCurrent: current, seed: seedFits ? prefetch : nil)
                guard current() else { return }
                readTail = true
            }
            if !ended { graftInflight(snapshot) }
        } else if let snap = snapshot, ended {
            // [doubled-reply] The connection's replay holds the rest of the turn (parked until this reconnect ends): its
            // frames end the turn in the live bubble they continue. Settled here first, the stream was gone when they
            // came, so they drew the reply again as a bubble of its own (owner 2026-10-29, build 475, Hermes "To Inbox").
            // What they leave unsettled is settled after them.
            if coveredByReplay, !turn.stopTerminalPending,
               parked.contains(where: { $0.sessionId == runtimeSessionId && Self.isTurnFrame($0.type) }) {
                settleAfterParked = snap
                noteCatchUp("settle after replay")
            }
            // Settles a turn that ended while we were away, and frees a send held behind a Stop.
            else if turn.stopTerminalPending || (turn.busy && (!turn.awaitingResponse || turn.turnLive)) { graftInflight(snap) }
            else if !turn.busy { turn.idleConfirmed = true }
        }
        caughtUp = true                  // [offline] read by the defer above
    }

    /// [doubled-reply] The gateway's newest seq for `rid` as this chat's cursor (an empty `session.events.since` from far
    /// past any seq answers only `latest_seq`), so frames up to it that arrive after a history read are stale.
    func adoptLatestSeq(_ rid: String) async {
        var params: [String: JSONValue] = ["session_id": .string(rid), "last_seen": .number(Double(Int32.max))]
        if let profileParam { params["profile"] = .string(profileParam) }
        guard let result = try? await client.call("session.events.since", .object(params), timeout: .seconds(5)),
              let latest = result["latest_seq"]?.int, lastSeq == nil, runtimeSessionId == rid else {
            AppLog.trace("chat", "adopt cursor \(logIds): no latest seq taken (read failed or state moved)")
            return
        }
        if let epoch = result["epoch"]?.string { heldEpoch = epoch }
        AppLog.trace("chat", "adopt cursor \(logIds): \(latest) (frames up to it now stale)")
        lastSeq = latest
        noteCatchUp("cursor \(latest)")
    }

    /// [catch-up] Our own send, acknowledged, with no frame of its turn heard, and the gateway says nothing runs: the
    /// turn came and went while the link was paused. Settled like the silence watchdog would 45 s later (04 §4.8), so the
    /// tail read after the reconnect shows the reply instead of cutting it as part of a running turn. A send under 15 s
    /// old may not have started yet (the pre-start heartbeat rule, 04 §4.6), and one still uploading hasn't been sent.
    func settleSendEndedAway(_ snapshot: JSONValue?) -> Bool {
        guard snapshot?["running"]?.bool == false, turn.busy, turn.awaitingResponse, !turn.turnLive, !turn.sawAssistantPayload,
              turn.streamId == nil, turn.preparingSendId == nil, !turn.stopTerminalPending, !turn.submitHeld, !turn.interrupted,
              !turn.forwarded                                                                                    // [desktop-forward]
        else { return false }
        if let armed = turn.armedAt, Date().timeIntervalSince(armed) < 15 { return false }
        if let anchor = turn.userAnchorId, let index = indexById[anchor], messages[index].isPending { return false }
        // The connection's replay handed the turn's frames over (parked until the reconnect ends): they settle it. Only
        // the turn's own frames count: the connection's `hq.open_requests` (O29: it held the settle) says nothing of it.
        if parked.contains(where: { $0.sessionId == runtimeSessionId && Self.isTurnFrame($0.type) }) { return false }
        AppLog.trace("turn", "settled away \(logIds): our send \(AppLog.tag(turn.userAnchorId)) got no frame and the gateway runs nothing")
        settleFlags()
        turn.idleConfirmed = true
        changes.markState()
        return true
    }

    /// A frame of a turn's own run: its start, text, tools, end or error.
    nonisolated static func isTurnFrame(_ type: String) -> Bool {
        type == "error" || ["message.", "tool.", "reasoning.", "thinking.", "subagent."].contains { type.hasPrefix($0) }
    }

    // MARK: Silence watchdog (04 §4.8)

    func armWatchdog() {
        guard watchdogTask == nil, !memoStaging else { return }   // VOICE: a memo arms it when prompt.submit goes out
        if turn.lastEventAt == nil || !turn.turnLive { turn.lastEventAt = Date() }
        watchdogTask = Task { [weak self] in await self?.watchdogLoop() }
    }

    private func watchdogLoop() async {
        let limit = silenceTimeout
        let limitSeconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        while !Task.isCancelled, turn.busy {
            let last = turn.lastEventAt ?? Date()
            let wait = limitSeconds - Date().timeIntervalSince(last)
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                continue
            }
            // [attachments] Still uploading or attaching: nothing was submitted, so silence is expected (and the
            // runtime looks idle). The watch starts when the prompt goes out (`endPreparing`).
            if turn.preparingSendId != nil { turn.lastEventAt = Date(); continue }
            // [desktop-forward] The gateway runs it (maybe behind the desktop's own reply) and relays only its start and
            // end; meanwhile the rows it stores show through the tail read. A lost relay ends with an empty
            // message.complete, a lost link with the reconnect's settle.
            if turn.forwarded {
                AppLog.trace("turn", "watchdog \(logIds): \(Int(limitSeconds)) s quiet; the send runs in the gateway's queue, keep waiting")
                turn.lastEventAt = Date()
                await refreshTail(force: false)
                continue
            }
            guard let rid = runtimeSessionId else { turn.lastEventAt = Date(); continue }
            AppLog.trace("turn", "watchdog \(logIds): \(Int(limitSeconds)) s silent, asking active_list")
            guard let result = try? await client.call("session.active_list", .object([:]), timeout: activeListTimeout) else {
                AppLog.trace("turn", "watchdog \(logIds): active_list didn't answer, keep waiting")
                turn.lastEventAt = Date()        // no answer: keep waiting
                continue
            }
            guard !Task.isCancelled, turn.busy else { break }
            if turn.preparingSendId != nil { turn.lastEventAt = Date(); continue }                         // [attachments]
            let sessions = result["sessions"]?.array ?? []
            let entry = sessions.first { $0["id"]?.string == rid || $0["session_id"]?.string == rid }
            let status = entry?["status"]?.string ?? ""
            if entry != nil, ["starting", "waiting", "working", "streaming", "running"].contains(status) || entry?["running"]?.bool == true {
                AppLog.trace("turn", "watchdog \(logIds): runtime still \(status.isEmpty ? "running" : status), keep waiting")
                turn.lastEventAt = Date()
                continue
            }
            AppLog.note("turn", "watchdog \(logIds): turn ended without a terminal frame (runtime \(entry == nil ? "not listed" : "status \(status)")); settling, forced tail read")
            // Ended without a terminal frame: settle like running:false, re-read, and say so if there's no reply.
            watchdogTask = nil            // settleFlags() below must not cancel this very task
            flushDeltas()
            if let sid = turn.streamId, let index = indexById[sid] {
                if messages[index].hasVisibleContent {
                    updateMessage(sid) { m in m.isStreaming = false; LiveChatSession.sealTools(&m, summary: "Result unavailable") }
                } else {
                    removeMessage(sid)
                }
            }
            // The settled turn's prompt, before the read: a message sent while the read runs is a turn of its own, and
            // the card is about this one (it went under the new message, judged by it).
            let promptIndex = turnAnchorIndex()
            let promptId = promptIndex >= 0 ? messages[promptIndex].id : nil
            let anchorBefore = turn.userAnchorId
            settleFlags()
            changes.markState()
            await refreshTail(force: true)
            let sentSince = turn.userAnchorId != anchorBefore ? turn.userAnchorId.flatMap { indexById[$0] } : nil
            let found = promptId.flatMap { indexById[$0] }
            // The prompt's row was renamed by the read and a new message came since: nothing safe to judge by.
            let lastUser: Int? = found ?? (sentSince == nil ? turnAnchorIndex() : nil)
            if let lastUser {
                let end = sentSince.map { max($0, lastUser + 1) } ?? messages.count
                if !messages[(lastUser + 1)..<end].contains(where: { $0.role == .assistant && ($0.hasVisibleContent || $0.error != nil) }) {
                    localCounter += 1
                    AppLog.note("turn", "watchdog \(logIds): no reply after the read; \"ended this turn without a reply\" card shown\(sentSince != nil ? " above the message sent since" : "")")
                    var card = ChatMessage(id: "local-error-\(localCounter)", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
                    card.error = "Hermes ended this turn without a reply."
                    insertMessage(card, at: end)
                }
            }
            scheduleFlush()
            scheduleQueueDrain(after: queueDrainFallback)
            return
        }
        if !Task.isCancelled { watchdogTask = nil }
    }
}
