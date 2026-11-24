import UIKit

// [threads] A thread as rows of the chat it hangs in (docs/spec/3x-threads.md §5).
//
// Open, it is one row: a header ("Thread ›"), then the thread's last question and what the bot answered, drawn by the
// chat's own bubble cells (so text, code, tails and times look as they do anywhere), beside a thin line in the bot's
// colour. Folded, it is one centred line like the chat's other grouped lines ("Flight on Friday · 4 messages ›").
// Either way a tap opens the thread's own chat.

/// One thread under a message of the chat, as the row builder is given it.
nonisolated struct ThreadRowInput: Sendable {
    var thread: ChatThread
    /// Open (its messages in place) or folded (`ThreadRules.isOpen`).
    var open: Bool
}

/// The line's colour: the bot's own (`Bot.chatsTint`).
nonisolated enum ThreadTint: Hashable, Sendable {
    case accent(red: Double, green: Double, blue: Double)
    /// An ink or paper face is drawn in the page's own ink.
    case label, label2
}

/// An open thread's row.
nonisolated struct ThreadRow {
    /// The thread's key (`ChatThread.id`).
    var key: String
    /// "Thread", or its own short title.
    var name: String
    /// "6 messages" when it holds more than it shows; a problem's words.
    var tail: String?
    var problem: Bool
    /// What it shows, oldest first: bubbles, and the waiting row while its reply has nothing to show yet.
    var inner: [ChatRow]
    var tint: ThreadTint
}

nonisolated struct ThreadLayout: @unchecked Sendable {
    struct Inner {
        var row: ChatRow
        var layout: RowLayout
        var frame: CGRect
    }
    /// The header's line (glyph, name, tail, chevron), the vertical line, the inner rows; all in row coordinates.
    var header: CGRect
    var line: CGRect
    var inner: [Inner]
}

nonisolated enum ThreadRows {
    /// Row ids: "<anchor message>|th:<key>" open, "|thf:<key>" folded (two ids: the two are drawn by different cells).
    static let openMark = "|th:"
    static let foldedMark = "|thf:"
    /// Synthetic anchor key for threads started in an empty chat (no non-system messages to hang under yet).
    static let emptyAnchorId = "__thread_empty__"

    /// The thread key in a row id of either form; nil for any other row.
    static func key(inRowId id: String) -> String? {
        for mark in [openMark, foldedMark] {
            if let range = id.range(of: mark) { return String(id[range.upperBound...]) }
        }
        return nil
    }

    static func isThread(_ row: ChatRow) -> Bool {
        if case .thread = row.kind { return true }
        return key(inRowId: row.id) != nil
    }

    /// How far the thread's own rows stand in from the chat's edge, and where its line runs.
    static let indent: CGFloat = 15
    static let lineInset: CGFloat = ChatMetrics.sideInset + 5
    /// 2 pt on the Mac, whose screens are seen from further off (1.5 pt read as a hairline there).
    static let lineWidth: CGFloat = DeviceWord.isMac ? 2 : 1.5

    /// The rows of the threads hung under `message`, oldest thread first.
    static func rows(under message: ChatMessage, input: ChatRowBuilder.Input) -> [ChatRow] {
        guard let hung = input.threads[message.id], !hung.isEmpty else { return [] }
        return hung.map { $0.open ? openRow($0.thread, anchorId: message.id, input: input) : foldedRow($0.thread, anchorId: message.id, input: input) }
    }

    /// Threads started before the main chat has any non-system messages: drawn at the foot so they never vanish.
    static func unanchoredRows(input: ChatRowBuilder.Input) -> [ChatRow] {
        guard let hung = input.threads[emptyAnchorId], !hung.isEmpty else { return [] }
        return hung.map { $0.open ? openRow($0.thread, anchorId: emptyAnchorId, input: input) : foldedRow($0.thread, anchorId: emptyAnchorId, input: input) }
    }

    private static func foldedRow(_ thread: ChatThread, anchorId: String, input: ChatRowBuilder.Input) -> ChatRow {
        let name = ThreadRules.name(thread)
        let tail = ThreadRules.foldedTail(thread)
        var row = BackgroundResultRow(title: name, result: "", process: false, expanded: false)
        // A count of two keeps the caret pointing right (it opens somewhere else), as a grouped line's does.
        row.group = UpdatesGroup(marks: [.glyph(.thread)], tail: tail, count: max(2, thread.spoken.count), opens: true, titles: [name])
        var hasher = Hasher()
        RowHash.add(name, to: &hasher)
        hasher.combine(tail)
        return ChatRow(id: anchorId + foldedMark + thread.id, messageId: anchorId, scope: input.scope, fingerprint: hasher.finalize(),
                       kind: .backgroundResult(row), gapAbove: ChatMetrics.turnGap, variant: 0)
    }

    private static func openRow(_ thread: ChatThread, anchorId: String, input: ChatRowBuilder.Input) -> ChatRow {
        let shown = ThreadRules.shown(thread)
        var inner = ChatRowBuilder.Input(messages: shown.messages, isRunning: thread.running, botName: input.botName, expanded: [])
        inner.now = input.now
        inner.scope = thread.scope
        inner.fewerTimes = input.fewerTimes
        var rows = ChatRowBuilder.build(inner).filter { row in
            switch row.kind {
            case .bubble, .waiting: return true
            default: return false
            }
        }
        // Started a moment ago: its first message is on its way to the gateway.
        if rows.isEmpty, thread.problem == nil {
            let waiting = WaitingRow(label: "\(input.speakerName) is thinking…", since: thread.startedAt)
            rows = [ChatRow(id: "waiting", messageId: "waiting", scope: thread.scope, fingerprint: RowHash.of(waiting.label),
                            kind: .waiting(waiting), gapAbove: ChatMetrics.turnGap, variant: 0)]
        }
        let header = ThreadRules.header(thread)
        let payload = ThreadRow(key: thread.id, name: header.name, tail: thread.problem ?? header.tail, problem: thread.problem != nil,
                                inner: rows, tint: input.threadTint)
        var hasher = Hasher()
        RowHash.add(payload.name, to: &hasher)
        hasher.combine(payload.tail); hasher.combine(payload.problem); hasher.combine(payload.tint)
        for row in rows {
            hasher.combine(row.id); hasher.combine(row.fingerprint); hasher.combine(row.variant); hasher.combine(row.gapAbove)
        }
        return ChatRow(id: anchorId + openMark + thread.id, messageId: anchorId, scope: input.scope, fingerprint: hasher.finalize(),
                       kind: .thread(payload), gapAbove: ChatMetrics.speakerGap, variant: 0)
    }

    // MARK: Layout

    static func layout(_ thread: ThreadRow, row: ChatRow, width: CGFloat, style: ChatStyle, keep: Bool) -> RowLayout {
        let gap = row.gapAbove
        let headerHeight = max(20, ceil(style.notice.lineHeight) + 4)
        let header = CGRect(x: lineInset + 10, y: gap, width: max(0, width - lineInset - 10 - ChatMetrics.sideInset), height: headerHeight)
        var y = header.maxY
        var inner: [ThreadLayout.Inner] = []
        let innerWidth = max(120, width - indent)
        for (index, item) in thread.inner.enumerated() {
            var item = item
            // The first row sits close under the header, whatever follows what.
            if index == 0 { item.gapAbove = 2 }
            let made = TextLayout.layout(item, width: innerWidth, style: style, keep: keep)
            inner.append(ThreadLayout.Inner(row: item, layout: made, frame: CGRect(x: indent, y: y, width: innerWidth, height: made.height)))
            y += made.height
        }
        let line = CGRect(x: lineInset, y: gap + 3, width: lineWidth, height: max(0, y - gap - 3))
        return RowLayout(height: y + 2, content: .thread(ThreadLayout(header: header, line: line, inner: inner)))
    }
}
