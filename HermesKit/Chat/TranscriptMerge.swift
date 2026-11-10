// Pure transcript algorithms (spec 03 §4.2, §7.5; spec 04 §4.5): the provisional open window, the final-text merge,
// the refreshed-tail graft with stable row identity, and the precise change diff the chat screen consumes.

import Foundation

/// Accumulates what changed between two emitted states (spec: precise `ChatChange` values, one flush per frame).
nonisolated struct ChangeSet: Sendable {
    private(set) var reset = false
    private(set) var updated: [String] = []
    private var updatedSet: Set<String> = []
    private(set) var appended: [String] = []
    private var appendedSet: Set<String> = []
    private(set) var removed: [String] = []
    private var removedSet: Set<String> = []
    private(set) var prepended = 0
    private(set) var state = false

    var isEmpty: Bool { !reset && updated.isEmpty && appended.isEmpty && removed.isEmpty && prepended == 0 && !state }

    mutating func markReset() { reset = true }
    mutating func markState() { state = true }
    mutating func prepend(_ count: Int) { if count > 0 { prepended += count } }

    mutating func update(_ id: String) {
        guard !appendedSet.contains(id), !updatedSet.contains(id) else { return }
        updatedSet.insert(id); updated.append(id)
    }

    mutating func append(_ id: String) {
        guard !appendedSet.contains(id) else { return }
        if removedSet.contains(id), let r = removed.firstIndex(of: id) { removed.remove(at: r); removedSet.remove(id); update(id); return }
        appendedSet.insert(id); appended.append(id)
    }

    mutating func remove(_ id: String) {
        if appendedSet.contains(id) {
            appendedSet.remove(id); appended.removeAll { $0 == id }
            return
        }
        if updatedSet.contains(id) { updatedSet.remove(id); updated.removeAll { $0 == id } }
        if removedSet.insert(id).inserted { removed.append(id) }
    }

    /// The calls to make, in order. Several structural kinds in one frame collapse to `.reset`.
    func emissions() -> [ChatChange] {
        if reset { return state ? [.reset, .state] : [.reset] }
        let structural = [!removed.isEmpty, prepended > 0, !appended.isEmpty].filter { $0 }.count
        if structural > 1 { return state ? [.reset, .state] : [.reset] }
        var out: [ChatChange] = []
        if !removed.isEmpty { out.append(.removed(ids: removed)) }
        if prepended > 0 { out.append(.prependedOlder(count: prepended)) }
        if !appended.isEmpty { out.append(.appended(ids: appended)) }
        if !updated.isEmpty { out.append(.updated(ids: updated)) }
        if state { out.append(.state) }
        return out
    }
}

nonisolated enum TranscriptMerge {
    // MARK: Open window (R:src/open-page.ts:205-216)

    /// The newest messages whose summed row span is ≤ `rows`; when that starts mid-turn and starting at the first
    /// non-assistant message still keeps ≥ rows/2, start there; nothing fits → the last message only.
    static func openWindow(_ messages: [ChatMessage], meta: [String: MessageMeta], rows: Int = 24) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        var sum = 0
        var start = messages.count
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let span = meta[messages[i].id]?.serverRowSpan ?? 1
            if sum + span > rows { break }
            sum += span
            start = i
        }
        if start == messages.count { return [messages[messages.count - 1]] }
        if start > 0, messages[start].role == .assistant,
           let firstOther = messages[start...].firstIndex(where: { $0.role != .assistant }) {
            let kept = messages[firstOther...].reduce(0) { $0 + (meta[$1.id]?.serverRowSpan ?? 1) }
            if kept * 2 >= rows { start = firstOther }
        }
        return Array(messages[start...])
    }

    // MARK: Final text merge (V:lib/chat-messages/parts.ts:358-440)

    static func texts(_ parts: some Collection<ChatPart>) -> String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }

    static func isTool(_ p: ChatPart) -> Bool { if case .tool = p { return true } else { return false } }
    static func isText(_ p: ChatPart) -> Bool { if case .text = p { return true } else { return false } }

    /// Merges the authoritative final text into a turn's parts. An empty final never wipes streamed text.
    static func mergeFinalText(_ parts: [ChatPart], _ finalText: String) -> [ChatPart] {
        guard !ChatText.trimmed(finalText).isEmpty else { return parts }
        let reference = ChatText.flat(finalText)
        let streamed = ChatText.flat(texts(parts))
        if !streamed.isEmpty && streamed == reference { return parts }
        if let lastTool = parts.lastIndex(where: isTool) {
            let earlier = Array(parts[...lastTool])
            let earlierText = texts(earlier)
            let suffix = Array(parts[(lastTool + 1)...])
            if !earlierText.isEmpty && finalText == earlierText { return earlier + suffix.filter { !isText($0) } }
            let response = (!earlierText.isEmpty && finalText.hasPrefix(earlierText)) ? String(finalText.dropFirst(earlierText.count)) : finalText
            return earlier + mergeFinalText(suffix, response)
        }
        let kept = parts.filter { part in
            switch part {
            case .text: return false
            case .reasoning(let r):
                let fr = ChatText.flat(r)
                return reference.isEmpty || fr.isEmpty || !reference.hasPrefix(fr)
            case .tool: return true
            }
        }
        return kept + [.text(finalText)]
    }

    // MARK: Refreshed tail graft (V:app/chat/transcript-backfill.ts:276-333, simplified for M1)

    struct Graft {
        var messages: [ChatMessage]
        var meta: [String: MessageMeta]
        var aliases: [String: String]           // canonical id → displayed id
        /// The page met what was shown, so the stored rows older than it were kept (false: the page replaced them).
        var keptOlder: Bool = false
        /// [diagnostics] What the graft decided, for the chat's log line (filled only while Detailed Logging is on).
        var notes: [String] = []
    }

    /// The message holds backend row `row`: its own, the row its words came from, or one of the rows folded into it.
    static func holds(_ m: ChatMessage, _ meta: MessageMeta?, row: Int) -> Bool {
        if m.rowId == row || m.reactionRow == row { return true }
        guard let meta, let first = meta.firstRowId ?? m.rowId, let last = meta.lastRowId else { return false }
        return first <= row && row <= last
    }

    /// Puts a freshly read newest page (canonical ids) onto what is shown (displayed ids), keeping the ids of rows
    /// already on screen — including live rows (`local-…`) that the page now holds as stored rows — so nothing the
    /// reader sees changes identity. Unstored local rows travel with the next row they were shown before.
    static func graft(fresh: [ChatMessage], freshMeta: [String: MessageMeta], onto previous: [ChatMessage],
                      previousMeta: [String: MessageMeta], aliases: [String: String], replaceAll: Bool) -> Graft {
        var aliases = aliases
        var canonicalOfDisplayed: [String: String] = [:]
        for (c, d) in aliases { canonicalOfDisplayed[d] = c }
        func canonical(_ id: String) -> String { canonicalOfDisplayed[id] ?? id }

        // 1. Stored prefix of `previous` that the page doesn't reach.
        let freshIds = Set(fresh.map(\.id))
        var prefix: [ChatMessage] = []
        var keptOlder = false
        /// A shown message's backend row: its own, else the lowest row it folds (a tool-only message has no row of its
        /// own; treating it as "newer than everything" made a refresh drop the whole history, verification round 2).
        func row(_ m: ChatMessage) -> Int? { m.rowId ?? previousMeta[m.id]?.firstRowId }
        let logging = AppLog.detailed
        var notes: [String] = []
        if logging && replaceAll { notes.append("replace all") }
        if !replaceAll, let anchor = fresh.first(where: { $0.rowId != nil }), let anchorRow = anchor.rowId {
            let storedPrevious = previous.filter { !$0.isLocal }
            if let p = previous.firstIndex(where: { canonical($0.id) == anchor.id }) {
                prefix = previous[..<p].filter { !$0.isLocal }
                keptOlder = true
                if logging { notes.append("page meets screen at row \(anchorRow) (shown index \(p)), keeps \(prefix.count) older") }
            } else if storedPrevious.contains(where: { freshIds.contains(canonical($0.id)) }) {
                // Overlapping but not at the anchor: merge by row id, the page wins for the rows it holds.
                prefix = storedPrevious.filter { (row($0) ?? Int.max) < anchorRow && !freshIds.contains(canonical($0.id)) }
                keptOlder = true
                if logging { notes.append("overlap not at anchor row \(anchorRow): merged by row id, keeps \(prefix.count) older") }
            } else if storedPrevious.allSatisfy({ (row($0) ?? Int.min) < anchorRow }) {
                // The page is entirely newer than the screen: keep what is shown and add the page after it.
                prefix = storedPrevious
                keptOlder = true
                if logging { notes.append("page newer than screen (anchor row \(anchorRow)): keeps all \(prefix.count) shown, adds page after") }
            } else if logging {
                notes.append("no shared row and older rows above anchor \(anchorRow): page replaces the \(storedPrevious.count) shown stored rows")
            }
            // else: no shared row and older ids above the anchor = compaction rewrite / another session → replace.
        }

        // 2. Match live rows to the stored rows that now hold them (stable identity).
        let shownCanonical = Set(previous.map { canonical($0.id) })
        /// Not already displayed under another (aliased) row.
        func unowned(_ freshId: String) -> Bool { aliases[freshId] == nil }
        var matchedFresh = Set<String>()
        var freshOfLocal: [String: String] = [:]        // local displayed id → fresh canonical id
        var copies = Set<String>()                      // live bubbles whose stored message shows under another
        var lastFreshIndex = -1
        for (i, local) in previous.enumerated() where local.isLocal && !local.isStreaming && aliasTarget(local.id, aliases) == nil {
            var found: Int?
            var foundByRow = false
            switch local.role {
            case .user:
                found = fresh.indices.first { j in
                    let f = fresh[j]
                    guard j > lastFreshIndex, !matchedFresh.contains(f.id), f.role == .user else { return false }
                    if let row = local.rowId {
                        // Same backend row: claim it even when a stored copy is already on screen (that copy goes).
                        return f.rowId == row && unowned(f.id)
                    }
                    return !shownCanonical.contains(f.id) && ChatText.flat(f.plainText) == ChatText.flat(local.plainText)
                }
            case .assistant:
                guard local.hasVisibleContent || local.error == nil else { continue }
                if let row = local.rowId {
                    // The live bubble's own `final_assistant_row_id` names its stored copy exactly, so it is tried first.
                    // A reply to a delivery, cron or other-device prompt has no prompt bubble of its own: the scan below
                    // would start at the previous turn's prompt and claim that turn's reply, or match nothing and show
                    // the reply twice. It also covers a page that holds the reply but not its prompt.
                    // A turn with tool steps folds into one stored message filed under its first text row; the live
                    // end names the last row, so a message whose folded rows reach it holds it too (log study
                    // 2026-10-28: row 34563 shown, live 34565, the reply drew twice on the device that didn't send).
                    found = fresh.indices.first { j in
                        j > lastFreshIndex && fresh[j].role == .assistant && holds(fresh[j], freshMeta[fresh[j].id], row: row)
                            && !matchedFresh.contains(fresh[j].id) && unowned(fresh[j].id)
                    }
                    foundByRow = found != nil
                }
                let userBefore = previous[..<i].last { $0.role == .user }
                let userFresh: Int? = userBefore.flatMap { u in
                    let target = freshOfLocal[u.id] ?? canonical(u.id)
                    return fresh.firstIndex { $0.id == target }
                }
                if found == nil, let u = userFresh {
                    var j = u + 1
                    while j < fresh.count, fresh[j].role != .user {
                        // The turn's stored reply. A REST read that raced the live turn may already show it under its own
                        // id: the live bubble still claims it and the stored copy is dropped, so the reply shows once.
                        if fresh[j].role == .assistant, !matchedFresh.contains(fresh[j].id), unowned(fresh[j].id) {
                            found = j; break
                        }
                        j += 1
                    }
                }
            case .system:
                // [helper-note] The note drawn for a running turn's prompt (LiveChatSession.graftInflightNote) gives way
                // to its stored row: same words, or the same result behind them.
                guard local.id.hasPrefix("local-note-") else { continue }
                let result = previousMeta[local.id]?.asyncResult
                found = fresh.indices.first { j in
                    let f = fresh[j]
                    guard j > lastFreshIndex, !matchedFresh.contains(f.id), f.role == .system, unowned(f.id),
                          !shownCanonical.contains(f.id) else { return false }
                    return f.plainText == local.plainText || (result != nil && freshMeta[f.id]?.asyncResult == result)
                }
            }
            if let j = found {
                if logging {
                    let how = local.rowId != nil && fresh[j].rowId == local.rowId ? "row \(local.rowId ?? 0)"
                        : foundByRow ? "its folded rows holding row \(local.rowId ?? 0)"
                        : local.role == .user ? "same text" : local.role == .system ? "same note" : "turn's reply after its prompt"
                    let dup = shownCanonical.contains(fresh[j].id) ? ", its stored copy on screen goes" : ""
                    notes.append("live \(local.role) \(AppLog.tag(local.id)) holds stored \(AppLog.tag(fresh[j].id)) by \(how)\(dup)")
                }
                matchedFresh.insert(fresh[j].id)
                freshOfLocal[local.id] = fresh[j].id
                aliases[fresh[j].id] = local.id
                lastFreshIndex = max(lastFreshIndex, j)
            } else if local.role == .assistant, let row = local.rowId,
                      let held = fresh.first(where: { $0.role == .assistant && holds($0, freshMeta[$0.id], row: row) }),
                      matchedFresh.contains(held.id) || !unowned(held.id) {
                // [doubled-reply] The stored message holding this bubble's row already shows under another live bubble
                // (one turn drawn as two, then folded into one stored message): this one is a copy and goes, instead of
                // staying on as unstored until the chat is opened again (owner 2026-10-29, build 475, Hermes "To Inbox").
                copies.insert(local.id)
                if logging { notes.append("live assistant \(AppLog.tag(local.id)) row \(row) is a copy of \(AppLog.tag(aliases[held.id] ?? held.id)), dropped") }
            } else if logging {
                notes.append("live \(local.role) \(AppLog.tag(local.id)) row \(local.rowId.map(String.init) ?? "-") matched nothing")
            }
        }

        // 3. Assemble: prefix + fresh (displayed ids) with unmatched local rows re-inserted before their next anchor.
        var body: [ChatMessage] = []
        var meta: [String: MessageMeta] = [:]
        let previousById = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in prefix {
            body.append(m)
            if let mm = previousMeta[m.id] { meta[m.id] = mm }
        }
        for f in fresh {
            var m = f
            let displayed = aliases[f.id] ?? f.id
            m.id = displayed
            if let old = previousById[displayed] {
                if old.interrupted {
                    // Marks the live turn put on its rows outlive the resync (R:src/fe-convo-r3.ts:262 applyTurnMarks).
                    m.interrupted = true
                }
                // A live reply the stored copy holds no text for (a stopped turn whose partial wasn't persisted): the
                // words the reader already saw stay (verification round 2: they vanished 2 s after Stop).
                if old.isLocal, ChatText.trimmed(texts(m.parts)).isEmpty, !ChatText.trimmed(texts(old.parts)).isEmpty {
                    m.parts = old.parts
                }
            }
            body.append(m)
            if let mm = freshMeta[f.id] { meta[displayed] = mm }
        }
        let placed = Set(body.map(\.id))
        let unmatched = previous.enumerated().filter { _, m in
            m.isLocal && !placed.contains(m.id) && freshOfLocal[m.id] == nil && !freshIds.contains(canonical(m.id)) && !copies.contains(m.id)
        }
        if logging && !unmatched.isEmpty {
            notes.append("\(unmatched.count) unstored local row(s) kept in place: \(unmatched.map { AppLog.tag($0.element.id) }.joined(separator: " "))")
        }
        for (i, local) in unmatched {
            // Next row after it (in what was shown) that is still in the result.
            let anchor = previous[(i + 1)...].first { placed.contains($0.id) }
            if let anchor, let at = body.firstIndex(where: { $0.id == anchor.id }) {
                body.insert(local, at: at)
            } else {
                body.append(local)
            }
            if let mm = previousMeta[local.id] { meta[local.id] = mm }
        }
        // Drop aliases whose displayed row is gone.
        let present = Set(body.map(\.id))
        if logging {
            let gone = aliases.filter { !present.contains($0.value) }.count
            if gone > 0 { notes.append("\(gone) alias(es) dropped, their rows are gone") }
        }
        aliases = aliases.filter { present.contains($0.value) }
        return Graft(messages: body, meta: meta, aliases: aliases, keptOlder: keptOlder, notes: notes)
    }

    private static func aliasTarget(_ displayed: String, _ aliases: [String: String]) -> String? {
        aliases.first { $0.value == displayed }?.key
    }

    // MARK: Diff

    /// Carries `revision` across (same content keeps the old value; changed content bumps it) and reports precisely
    /// what changed between `old` and `new`.
    static func diff(old: [ChatMessage], new: [ChatMessage], into changes: inout ChangeSet) -> [ChatMessage] {
        let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result = new
        var changed: [String] = []
        for i in result.indices {
            guard let o = oldById[result[i].id] else { result[i].revision = 0; continue }
            if o.sameContent(as: result[i]) { result[i] = o }
            else { result[i].revision = o.revision + 1; changed.append(result[i].id) }
        }
        let oldIds = old.map(\.id), newIds = result.map(\.id)
        let newSet = Set(newIds)
        if oldIds == newIds {
            changed.forEach { changes.update($0) }
        } else if newIds.count > oldIds.count, Array(newIds.prefix(oldIds.count)) == oldIds {
            newIds.dropFirst(oldIds.count).forEach { changes.append($0) }
            changed.forEach { changes.update($0) }
        } else if newIds.count > oldIds.count, Array(newIds.suffix(oldIds.count)) == oldIds {
            changes.prepend(newIds.count - oldIds.count)
            changed.forEach { changes.update($0) }
        } else if newIds.count < oldIds.count, oldIds.filter(newSet.contains) == newIds {
            oldIds.filter { !newSet.contains($0) }.forEach { changes.remove($0) }
            changed.forEach { changes.update($0) }
        } else {
            changes.markReset()
        }
        return result
    }
}
