// Ask Bot (Shortcuts): the bot's answer to one prompt, read from the share socket's events. Tester, 2026-11-08:
// "a 'send message to bot' shortcut, similar to 'Ask' in the official app ... a daily automation shortcut to export data
// from an app and send it to my bot". Nothing here answers the gateway; it only listens.

import Foundation

/// How the wait for a reply ended.
nonisolated enum ShareReply: Equatable, Sendable {
    /// The turn's final text (empty when the bot answered with tools only).
    case text(String)
    /// The bot asked the person something (an approval, a question): answered in the app.
    case asking
    /// No answer within the wait: the bot is still on it, and its reply will be in the chat.
    case stillWorking
    /// The turn ended in an error (the gateway's words, or empty).
    case failed(String)
}

nonisolated final class ShareReplyWatch: @unchecked Sendable {
    private let runtime: String
    private let lock = NSLock()
    /// Every turn end seen for this chat since listening began, in order.
    private var ends: [ShareReply] = []
    /// Text of the message being written (when a turn end carries none).
    private var streamed = ""
    private var interruption: ShareReply?
    private var waiter: (skip: Int, continuation: CheckedContinuation<ShareReply, Never>)?

    /// `runtime`: the chat's runtime id, as `session.resume` answered it.
    init(runtime: String) { self.runtime = runtime }

    /// The socket's listener.
    func take(_ event: ShareSocketEvent) {
        lock.lock()
        switch event {
        case .event(let type, let session, let payload):
            let mine = session == runtime || (session.isEmpty && type == "error")
            guard mine else { break }
            switch type {
            case "message.start": streamed = ""
            case "message.delta": streamed += Self.text(payload.object["text"])
            case "message.complete":
                let said = Self.text(payload.object["text"])
                let text = (said.isEmpty ? streamed : said).trimmingCharacters(in: .whitespacesAndNewlines)
                ends.append(payload.object["status"] as? String == "error" ? .failed(text) : .text(text))
                streamed = ""
            case "error":
                let message = (payload.object["message"] as? String) ?? ""
                ends.append(.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
            default: break
            }
        case .request(_, let session):
            if session == runtime || session.isEmpty { interruption = interruption ?? .asking }
        case .closed:
            interruption = interruption ?? .stillWorking
        }
        let ready = settled()
        lock.unlock()
        if let ready { ready.continuation.resume(returning: ready.reply) }
    }

    /// The reply: the turn end after the first `skip` (1 when the prompt was queued behind a running turn), the bot
    /// asking, or `.stillWorking` after `timeout` seconds or a closed socket.
    func wait(skip: Int, timeout: Double) async -> ShareReply {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShareReply, Never>) in
            lock.lock()
            waiter = (skip, continuation)
            let ready = settled()
            lock.unlock()
            if let ready { return ready.continuation.resume(returning: ready.reply) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire() }
        }
    }

    /// Called with the lock held: the waiter and its answer, once there is one (the waiter is then gone).
    private func settled() -> (continuation: CheckedContinuation<ShareReply, Never>, reply: ShareReply)? {
        guard let waiter else { return nil }
        let reply: ShareReply
        if ends.count > waiter.skip { reply = ends[waiter.skip] }
        else if let interruption { reply = interruption }
        else { return nil }
        self.waiter = nil
        return (waiter.continuation, reply)
    }

    private func expire() {
        lock.lock(); let pending = waiter; waiter = nil; lock.unlock()
        pending?.continuation.resume(returning: .stillWorking)
    }

    /// A text field as the app reads it (`LiveChatSession.coerceText`): a string, or parts with `text`.
    static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let parts = value as? [Any] {
            return parts.map { part in
                if let string = part as? String { return string }
                let object = part as? [String: Any]
                return (object?["text"] as? String) ?? (object?["output_text"] as? String) ?? ""
            }.joined()
        }
        if let object = value as? [String: Any] { return (object["text"] as? String) ?? (object["output_text"] as? String) ?? "" }
        return ""
    }
}
