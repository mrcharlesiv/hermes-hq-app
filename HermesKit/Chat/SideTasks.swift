// /btw and /bg (docs/spec/3x-composer.md §8.4): a side question answered from a snapshot of the chat (`prompt.btw`), and
// a prompt run in a separate session (`prompt.background`). Both answer at once with a task id and run beside the turn;
// the result comes later as `btw.complete` / `background.complete` on the runtime that asked. The start line is a slash
// row that goes when the result lands; the result is a local row drawn as one line that opens on it (a /btw answer opens
// by itself). A chat left while a task is out keeps listening off screen, like a chat sending its queue, and the results
// are kept for the launch, so opening the chat again shows them (the gateway stores neither, as on the desktop).

import Foundation

nonisolated enum SideTaskKind: String, Sendable {
    case btw
    case background = "bg"

    var method: String { self == .btw ? "prompt.btw" : "prompt.background" }

    init?(event: String) {
        switch event {
        case "btw.complete": self = .btw
        case "background.complete": self = .background
        default: return nil
        }
    }

    /// The command typed with nothing after it.
    var usage: String {
        switch self {
        case .btw: return "Type a question after /btw. It's answered from this chat so far, without interrupting it."
        case .background: return "Type a task after /bg. It runs in a separate session, and the result shows here when it's done."
        }
    }

    /// The slash row while the task runs.
    var started: String {
        switch self {
        case .btw: return "Asking on the side… the answer will show here."
        case .background: return "Started in the background. Keep chatting; the result will show here when it's done."
        }
    }

    /// The start row when Hermes restarted before the task finished.
    static let lost = "Hermes restarted before this finished."

    /// The start row once the chat stopped waiting (`SideTasks.listenLimit`); a result that still comes while the chat
    /// is open replaces it.
    var overdue: String {
        switch self {
        case .btw: return "Stopped waiting for the answer after an hour. Ask again if you still need it."
        case .background: return "Stopped waiting after an hour. Ask Hermes for the result."
        }
    }

    func couldNotStart(_ reason: String) -> String {
        switch self {
        case .btw: return "Couldn’t ask: \(reason)"
        case .background: return "Couldn’t start the background task: \(reason)"
        }
    }
}

/// A side task's result row: a local system message whose text is "side:<kind>\n<title>\n<result>" (as a slash row's is
/// "slash:/<name>\n<output>"); never cached, never in the shared transcript.
nonisolated enum SideTaskRow {
    static let idPrefix = "local-side-"
    static let noAnswer = "No answer came back."

    static func id(_ kind: SideTaskKind, taskId: String) -> String { "\(idPrefix)\(kind.rawValue)-\(taskId)" }

    static func isSideRow(_ message: ChatMessage) -> Bool {
        message.role == .system && message.id.hasPrefix(idPrefix)
    }

    /// A /btw answer is what was asked for: it opens as it lands. A background task's report stays one line, as a
    /// finished subagent's does.
    static func opensByItself(_ message: ChatMessage) -> Bool {
        isSideRow(message) && message.id.hasPrefix("\(idPrefix)\(SideTaskKind.btw.rawValue)-")
    }

    static func text(kind: SideTaskKind, title: String, result: String) -> String {
        "side:\(kind.rawValue)\n\(title)\n\(result)"
    }

    static func parse(_ text: String) -> (kind: SideTaskKind, title: String, result: String)? {
        guard text.hasPrefix("side:") else { return nil }
        let lines = text.dropFirst("side:".count).split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count == 3, let kind = SideTaskKind(rawValue: String(lines[0])) else { return nil }
        return (kind, String(lines[1]), String(lines[2]))
    }

    /// "By the way: what's the port?", "Background task finished: run the tests"; a failure says so. `asked` is cut to
    /// one line.
    static func title(kind: SideTaskKind, asked: String?, failed: Bool) -> String {
        let words = ChatText.trimmed(asked ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let line = words.utf8.count > 400 ? ChatText.clip(words, max: 400) + "…" : words
        let lead: String
        switch kind {
        case .btw: lead = failed ? "Couldn’t answer" : "By the way"
        case .background: lead = failed ? "Background task failed" : "Background task finished"
        }
        return line.isEmpty ? lead : "\(lead): \(line)"
    }

    /// The row for a finished task. The gateway sends a failure as "error: <reason>".
    static func message(kind: SideTaskKind, taskId: String, asked: String?, text: String, at: Date) -> ChatMessage {
        var result = ChatText.trimmed(text)
        let failed = result.hasPrefix("error: ")
        if failed { result = ChatText.trimmed(String(result.dropFirst("error: ".count))) }
        if result.isEmpty { result = noAnswer }
        let body = self.text(kind: kind, title: title(kind: kind, asked: asked, failed: failed), result: result)
        return ChatMessage(id: id(kind, taskId: taskId), role: .system, parts: [.text(body)], timestamp: at, rowId: nil)
    }
}

/// A task that is out: what was asked, and its start row.
nonisolated struct SideTask: Sendable {
    var kind: SideTaskKind
    var asked: String
    /// The start row and the command it shows ("/bg" or "/background", as typed).
    var startRowId: String?
    var command: String?
    var startedAt: Date
}

/// Results that landed this launch, by chat (`account|profile|stored id`): a chat opened again shows them where they
/// landed. Memory only: after a relaunch they are gone, as on the desktop.
@MainActor final class SideResultStash {
    static let shared = SideResultStash()
    /// A chat keeps its newest this many.
    static let perChat = 50
    private var rows: [String: [ChatMessage]] = [:]

    func add(_ message: ChatMessage, scope: String) {
        var list = rows[scope] ?? []
        guard !list.contains(where: { $0.id == message.id }) else { return }
        list.append(message)
        if list.count > Self.perChat { list.removeFirst(list.count - Self.perChat) }
        rows[scope] = list
    }

    func rows(scope: String) -> [ChatMessage] { rows[scope] ?? [] }

    /// Sign-out: the account's results go with its other caches.
    func purge(accountId: String) {
        rows = rows.filter { !$0.key.hasPrefix(accountId + "|") }
    }
}

nonisolated enum SideTasks {
    /// How long a chat left with a task out keeps listening for its result.
    static let listenLimit: TimeInterval = 3600
}

extension LiveChatSession {
    /// A `btw.complete` / `background.complete` frame. Every chat hears every frame: this one takes its own tasks, and a
    /// task asked on its runtime by an earlier screen of the same chat. Not the turn's, so never parked or held.
    func sideTaskFinished(_ event: GatewayEvent) {
        guard let kind = SideTaskKind(event: event.type), let taskId = event.payload["task_id"]?.nonEmptyString,
              !menus.sideDone.contains(taskId) else { return }
        // One the chat stopped waiting for (over the limit) is still its own: its start row goes when it lands late.
        let pending = menus.sideTasks.removeValue(forKey: taskId) ?? menus.sideOverdue.removeValue(forKey: taskId)
        guard pending != nil || (!event.sessionId.isEmpty && event.sessionId == runtimeSessionId) else { return }
        menus.sideDone.insert(taskId)
        let id = SideTaskRow.id(kind, taskId: taskId)
        guard indexById[id] == nil else { AppLog.trace("chat", "side task \(AppLog.tag(taskId)) result again (replay), already shown"); return }   // a replay of one already shown
        AppLog.trace("chat", "side task \(kind.rawValue) \(AppLog.tag(taskId)) result in \(logIds): \(pending == nil ? "asked by an earlier screen" : "ours"), \(observing ? "on screen" : "off screen"), still out \(menus.sideTasks.count)")
        if let start = pending?.startRowId { removeSlashRow(start) }
        let asked = pending?.asked ?? event.payload["question"]?.nonEmptyString
        let message = SideTaskRow.message(kind: kind, taskId: taskId, asked: asked,
                                          text: LiveChatSession.coerceText(event.payload["text"]), at: Date())
        flushDeltas()
        appendMessage(message)
        if storedSessionId != nil { SideResultStash.shared.add(message, scope: layoutScope) }
        scheduleFlush()
    }

    /// Whether a task asked in this chat is still out. One asked over `SideTasks.listenLimit` ago stops being waited
    /// for: its start row says so (as `sideTasksLost`'s does), and it is kept aside so a late result still replaces it.
    func sideTasksOut(now: Date = Date()) -> Bool {
        let late = menus.sideTasks.filter { now.timeIntervalSince($0.value.startedAt) >= SideTasks.listenLimit }
        if !late.isEmpty {
            AppLog.trace("chat", "side tasks \(logIds): \(late.count) past the listen limit, no longer waited for")
            for (id, task) in late {
                menus.sideTasks[id] = nil
                menus.sideOverdue[id] = task
                if let row = task.startRowId { updateSlashRow(row, command: task.command, output: task.kind.overdue) }
            }
            scheduleFlush()
        }
        return !menus.sideTasks.isEmpty
    }

    /// Left with a task out: the off-screen listening ends by itself once the newest task's limit has passed.
    func armSideTaskLimit() {
        menus.sideLimit?.cancel()
        guard let newest = menus.sideTasks.values.map(\.startedAt).max() else { return }
        let wait = max(0, SideTasks.listenLimit - Date().timeIntervalSince(newest)) + 1
        menus.sideLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.endAwayDrainIfDone()
        }
    }

    /// Hermes restarted (a new replay epoch): the tasks that were out died with it. Their start rows say so and nothing
    /// waits for them.
    func sideTasksLost() {
        guard !menus.sideTasks.isEmpty else { return }
        AppLog.note("chat", "side tasks \(logIds): \(menus.sideTasks.count) lost with a gateway restart")
        for task in menus.sideTasks.values {
            if let row = task.startRowId { updateSlashRow(row, command: task.command, output: SideTaskKind.lost) }
        }
        menus.sideTasks = [:]
        menus.sideOverdue = [:]
        scheduleFlush()
    }

    /// The first page landed: results that came in while this chat was closed come back where they landed.
    func restoreSideResults() {
        guard storedSessionId != nil else { return }
        var restored = false
        for m in SideResultStash.shared.rows(scope: layoutScope) where indexById[m.id] == nil {
            let at = m.timestamp ?? Date()
            let index = messages.firstIndex { ($0.timestamp ?? .distantPast) > at } ?? messages.count
            insertMessage(m, at: index)
            restored = true
        }
        if restored {
            AppLog.trace("chat", "side results restored in \(logIds)")
            changes.markState()
            scheduleFlush()
        }
    }
}
