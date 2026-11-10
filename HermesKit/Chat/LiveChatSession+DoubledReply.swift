// [doubled-reply] Owner 2026-10-20 (Otto) and 2026-10-23 (Hermes, build 350): after a return mid-turn the reply showed
// twice, then once. Hermes stored it once; no test reproduces it (Tests/Chat/AwayMidTurnTests.swift). This only watches:
// whenever the screen is handed a change, the newest messages are checked for one reply shown twice, and the diagnostic
// log (sent to the owner's computer, ~/.hermes/hq-logs) gets the two rows, the turn's state and the catch-up steps that
// led there, then a second line naming the step that made it whole again. Ids, row ids and lengths only: no text.
// 2026-10-26 one cause found by it: a turn's frames landing after a read that already held its reply (a subagent's
// completion turn, chat opened from the alert) drew a live copy beside the stored row; `onComplete` now keeps the stored
// row (Tests/Chat/ReplyAlreadyShownTests.swift).
// 2026-10-29 another (build 475, Hermes "To Inbox"): back from the alert, the gateway said the turn had ended and the
// chat settled it before the connection's parked replay (the rest of that turn) was dispatched, so the replay drew the
// reply as a second live bubble the tail read kept as unstored. The settle now waits for the parked frames, and the
// merge drops a live bubble whose stored message already shows under another (Tests/Chat/LongTurnAwayTests.swift
// `connectionReplay`, FoldedReplyOtherDeviceTests `aSecondLiveBubbleOfTheSameTurnGoes`).

import Foundation

/// The recent catch-up steps and the doubled pair last logged.
nonisolated struct DoubledReplyWatch {
    static let keepSteps = 8
    static let window = 12
    static let minChars = 12
    var steps: [String] = []
    var logged: String?
}

extension LiveChatSession {
    /// One step of a catch-up (reconnect, read, graft, turn frame), kept for the next doubled-reply line.
    func noteCatchUp(_ step: String) {
        doubledReply.steps.append(step)
        if doubledReply.steps.count > DoubledReplyWatch.keepSteps { doubledReply.steps.removeFirst() }
    }

    /// Checks the newest messages for a reply shown twice (called as the screen is handed a change).
    func watchForDoubledReply() {
        let pair = Self.doubledReply(in: messages.suffix(DoubledReplyWatch.window))
        let key = pair.map { "\($0.0.id)|\($0.1.id)" }
        guard key != doubledReply.logged else { return }
        if let (a, b) = pair {
            AppLog.note("chat", "doubled reply: \(describe(a)) + \(describe(b)); \(turnWords()); after \(stepWords())")
        } else {
            AppLog.note("chat", "doubled reply gone; after \(stepWords())")
        }
        doubledReply.logged = key
    }

    /// Two assistant rows with the same opening words, or the same closing words with no prompt between them (a turn's
    /// tail drawn again as a bubble of its own, owner 2026-10-24), where one is a live (local) row or both name one
    /// stored row: the same reply twice. Two stored rows of their own are a bot that said the same thing twice. Opening
    /// words count only for two rows about as long: a new reply that starts like the last one, still streaming, is not a
    /// copy (log study 2026-10-28, Mac 3:31 PM: 996 chars against 95; the real doubles were 875 against 877).
    nonisolated static func doubledReply(in slice: ArraySlice<ChatMessage>) -> (ChatMessage, ChatMessage)? {
        var seen: [String: ChatMessage] = [:]
        var ends: [String: ChatMessage] = [:]
        for m in slice {
            if m.role == .user { ends = [:] }
            guard m.role == .assistant else { continue }
            let text = m.plainText
            let length = text.count
            let words = ChatText.flat(String(text.prefix(200)))      // runs on every delivery: the two ends only
            guard words.count >= DoubledReplyWatch.minChars else { continue }
            let key = String(words.prefix(80))
            let end = String(ChatText.flat(String(text.suffix(200))).suffix(80))
            func same(_ first: ChatMessage) -> Bool { first.isLocal || m.isLocal || (first.rowId != nil && first.rowId == m.rowId) }
            func aboutAsLong(_ first: ChatMessage) -> Bool {
                let other = first.plainText.count
                return abs(other - length) <= max(20, max(other, length) / 10)
            }
            if let first = seen[key], same(first), aboutAsLong(first) { return (first, m) }
            if let first = ends[end], same(first) { return (first, m) }
            seen[key] = m
            ends[end] = m
        }
        return nil
    }

    private func describe(_ m: ChatMessage) -> String {
        var words = "\(AppLog.tag(m.id)) row \(m.rowId.map(String.init) ?? "-") len \(m.plainText.count)"
        if m.isStreaming { words += " streaming" }
        if let stored = aliases.first(where: { $0.value == m.id })?.key { words += " as \(AppLog.tag(stored))" }
        return words
    }

    private func turnWords() -> String {
        var flags: [String] = []
        if turn.busy { flags.append("busy") }
        if turn.turnLive { flags.append("live") }
        if turn.awaitingResponse { flags.append("awaiting") }
        if let sid = turn.streamId { flags.append("stream \(AppLog.tag(sid))") }
        if let anchor = turn.userAnchorId { flags.append("anchor \(AppLog.tag(anchor))") }
        if turn.inflightUserKey != nil { flags.append("inflight prompt") }
        return "turn " + (flags.isEmpty ? "idle" : flags.joined(separator: " "))
    }

    private func stepWords() -> String {
        doubledReply.steps.isEmpty ? "no catch-up" : doubledReply.steps.joined(separator: " > ")
    }
}
