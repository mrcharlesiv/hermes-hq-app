// [threads] A bot chat's threads (docs/spec/3x-threads.md): the model a chat screen draws, and the pure rules for
// where a thread hangs in the chat, whether it shows open or folded, and what an open one shows.
//
// A thread is a session of its own in the bot's profile (`parent_session_id` = the bot chat), so it runs beside the
// bot chat's reply instead of joining it. The bot chat draws it in place: open (its last question and the answer) while
// it is the newest thing there, one folded line afterwards.

import Foundation

/// [threads] Durable link between a thread session and the Bot Chat it started from, kept in device state and synced
/// via `GatewaySync` so threads never need `parent_session_id` alongside `messages` on `session.create` (which causes
/// Hermes's `_seed_branch_row` to title the thread `"Bot Chat #N"` and strip `display_kind: "hidden"` from its seed).
nonisolated struct BotThreadLink: Codable, Hashable, Sendable {
    var storedId: String
    var profile: String
    var parentId: String
    var startedAt: Double
    var anchorRow: Int?

    static let maxKept = 200

    var json: JSONValue {
        var obj: [String: JSONValue] = [
            "storedId": .string(storedId),
            "profile": .string(profile),
            "parentId": .string(parentId),
            "startedAt": .number(startedAt),
        ]
        if let anchorRow { obj["anchorRow"] = .number(Double(anchorRow)) }
        return .object(obj)
    }

    static func decode(_ value: JSONValue?) -> [Self]? {
        value?.array?.compactMap { item in
            guard let storedId = RosterText.trimmed(item["storedId"]),
                  let profile = RosterText.trimmed(item["profile"]),
                  let parentId = RosterText.trimmed(item["parentId"]),
                  let startedAt = RosterText.number(item["startedAt"]) else { return nil }
            return Self(storedId: storedId, profile: profile, parentId: parentId, startedAt: startedAt,
                        anchorRow: RosterText.count(item["anchorRow"]))
        }
    }

    private struct Key: Hashable { var profile: String; var storedId: String }
    private var key: Key { Key(profile: profile, storedId: storedId) }

    /// Merges synced thread links across devices without dropping newly started local threads or resurrecting deletions.
    static func merged(local: [Self], remote: [Self], base: [Self], policy: GatewaySyncMerge) -> [Self] {
        func dedupe(_ items: [Self]) -> [Self] {
            var seen = Set<Key>()
            var out: [Self] = []
            for item in items.sorted(by: { $0.startedAt > $1.startedAt }) {
                if seen.insert(item.key).inserted { out.append(item) }
            }
            return Array(out.prefix(maxKept))
        }
        switch policy {
        case .replace:
            return dedupe(remote)
        case .firstContact:
            return dedupe(remote + local)
        case .rebase:
            if local == base { return dedupe(remote) }
            let baseKeys = Set(base.map(\.key))
            let localKeys = Set(local.map(\.key))
            let remoteKeys = Set(remote.map(\.key))
            let removed = baseKeys.subtracting(localKeys).union(baseKeys.subtracting(remoteKeys))
            return dedupe((local + remote).filter { !removed.contains($0.key) })
        }
    }
}

/// One thread, as the chat it hangs in draws it.
nonisolated struct ChatThread: Identifiable, Sendable {
    /// Its key in the chat's list: the stored session id once the gateway made it, a local key until then.
    var id: String
    var storedId: String?
    /// Its own short title; nil until it has one ("Thread" meanwhile).
    var title: String?
    var startedAt: Date
    /// The message of the main chat it hangs under: its id there when this device started the thread, and its stored
    /// row (the seed's closing note carries it to every other device). Without either, its start time places it.
    var anchorMessageId: String?
    var anchorRow: Int?
    /// What is said in it, oldest first (never its hidden seed).
    var messages: [ChatMessage]
    /// A reply is running in it.
    var running: Bool
    /// It could not start or send ("The gateway didn’t start a new chat."); the line says so.
    var problem: String?
    /// The cache scope of its rows' layouts (`ChatRow.scope`).
    var scope: String

    /// The messages that count as said: yours and the bot's.
    var spoken: [ChatMessage] { messages.filter { $0.role != .system } }
}

/// [threads] §9: what the chat screen hands `ThreadStore` when a send cannot go into the main chat now.
nonisolated struct BusyThreadPayload: Sendable {
    /// Prompt text sent on the wire.
    var text: String
    /// What the bubble shows when it differs from `text` (skills, titled requests, hidden notes).
    var display: String? = nil
    /// Photos and files attached to the send.
    var attachments: [DraftAttachment] = []
    /// Voice memo attached to the send (nil for typed/photo/file sends).
    var memo: MemoFile? = nil
    /// Local bubble id to leave out of the thread's seed (nil when routed proactively before adding a main bubble).
    var localId: String? = nil
    /// Why the main chat couldn't take the send (nil for 4009 busy or proactive continuation).
    var reason: OwnerWait? = nil
    /// True when routed directly before attempting `prompt.submit` in the main chat.
    var proactive: Bool = false
}

/// [threads] §9: calm routing strip shown over the composer while sends go straight into a thread.
nonisolated struct ThreadBusyBanner: Equatable, Sendable {
    var title: String
    var note: String
    /// Active busy thread key if continuing an existing one; nil if the next send starts a new thread.
    var threadKey: String? = nil
}

nonisolated enum ThreadRules {
    /// §9: said over the message box when words sent to a busy chat went on in a thread.
    static let busyNotice = "This chat is busy, so your message went into a thread."
    /// §9: how long an idle auto-thread remains sticky for follow-up busy sends before a new busy stretch starts fresh.
    static let busyThreadTTL: TimeInterval = 15 * 60
    /// §9: brief grace window on a first `4090` refusal from a known external holder before handing off to a thread.
    static let busyOwnerGrace: Duration = .milliseconds(1500)

    /// Where the composer's thread button hangs a new thread: under the newest finished message (yours or the bot's),
    /// skipping any reply still streaming so it sits under your request while the first reply streams, yet never gets
    /// trapped above an already-finished assistant message (which would fold the thread immediately).
    static func composerAnchor(in messages: [ChatMessage], running: Bool) -> ChatMessage? {
        messages.last { $0.role != .system && !$0.isStreaming }
            ?? messages.last { $0.role != .system }
    }

    /// §9: where a thread that took a busy chat's words hangs: under the newest finished message in that chat (yours or
    /// the bot's), so it stands open at the foot with its answer in view. `localId` is the bubble of the words it took,
    /// which leaves the chat. (By time alone it would hang under your last message, above the bot's answer to it, and
    /// fold the moment it finished.)
    static func busyAnchor(in messages: [ChatMessage], leavingOut localId: String?) -> ChatMessage? {
        messages.last { $0.id != localId && $0.role != .system && !$0.isStreaming }
            ?? messages.last { $0.id != localId && $0.role != .system }
    }

    /// §9: the thread that took a busy chat's words takes the next ones too, for as long as it is reachable and well,
    /// the main chat hasn't accepted a send or gone idle since, and the thread hasn't gone stale.
    static func takesNextBusySend(heldAt: Int?, accepted: Int, live: Bool, problem: Bool) -> Bool {
        takesNextBusySend(heldAt: heldAt, accepted: accepted, reachable: live, problem: problem,
                          mainIdleSinceHold: false, lastActivity: .distantPast, now: .distantPast, ttl: busyThreadTTL)
    }

    static func takesNextBusySend(heldAt: Int?, accepted: Int, reachable: Bool, problem: Bool,
                                  mainIdleSinceHold: Bool, lastActivity: Date, now: Date,
                                  ttl: TimeInterval = busyThreadTTL) -> Bool {
        guard heldAt == accepted, reachable, !problem, !mainIdleSinceHold else { return false }
        return now.timeIntervalSince(lastActivity) <= ttl
    }

    /// §9: quiet notice when the main chat becomes free again and the composer hands back from an auto-thread.
    static func backInMainNotice(botName: String) -> String {
        let who = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(who.isEmpty ? "The bot" : who) is back in the main chat."
    }

    /// §9: true when a transcript refresh brought in a newer finished assistant reply than was shown before
    /// (proves an external job or turn finished writing its answer in the main chat).
    static func hasNewFinishedReply(before: [ChatMessage], after: [ChatMessage]) -> Bool {
        func latestFinished(_ list: [ChatMessage]) -> ChatMessage? {
            list.last {
                $0.role == .assistant && !$0.isStreaming && $0.error == nil
                    && !ChatTranscript.blocks($0).isEmpty
            }
        }
        guard let now = latestFinished(after) else { return false }
        guard let prev = latestFinished(before) else { return true }
        if let nowRow = now.rowId, let prevRow = prev.rowId { return nowRow > prevRow }
        return now.id != prev.id && after.count > before.count
    }

    /// §9: words for the calm proactive-routing banner over the composer.
    static func proactiveBanner(botName: String, activeTitle: String?, threadKey: String?, reason: OwnerWait?) -> ThreadBusyBanner {
        let title = activeTitle.flatMap { $0.isEmpty || $0 == defaultTitle ? nil : $0 }
        let busyNote: String = {
            switch reason {
            case .backgroundTask: return "Busy with a background task"
            case .messagingTurn(let app?): return "Busy with a \(app) message"
            case .messagingTurn(nil): return "Busy with a messaging turn"
            case .otherWindow: return "Busy in another window"
            case .runningReply, nil: return "Busy in the main chat"
            }
        }()
        if let title {
            return ThreadBusyBanner(title: "Replying in Thread",
                                    note: "Continuing “\(title)”",
                                    threadKey: threadKey)
        }
        return ThreadBusyBanner(title: "Sending to Thread",
                                note: busyNote,
                                threadKey: threadKey)
    }

    /// Threads that belong to an empty chat (no non-system messages to hang under yet): shown at the foot so an
    /// auto-thread started before the main chat has any messages never disappears.
    static func unanchored(_ threads: [ChatThread], in messages: [ChatMessage]) -> [ChatThread] {
        guard !messages.contains(where: { $0.role != .system }) else { return [] }
        return threads.filter { $0.anchorMessageId == nil && $0.anchorRow == nil }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// The index in `messages` (the main chat's, oldest first) of the message `thread` hangs under; nil when that
    /// message is older than what is loaded (or the chat is empty).
    static func anchorIndex(of thread: ChatThread, in messages: [ChatMessage]) -> Int? {
        if let id = thread.anchorMessageId, let found = messages.lastIndex(where: { $0.id == id }) { return found }
        if let row = thread.anchorRow {
            if let exact = messages.lastIndex(where: { $0.rowId == row }) { return exact }
            // A reply folded from several stored rows carries its first row: the newest message at or before the anchor.
            var best: Int?
            var sawStored = false
            for (index, message) in messages.enumerated() {
                guard let own = message.rowId else { continue }
                sawStored = true
                if own <= row { best = index }
            }
            if best != nil || sawStored { return best }
        }
        // By time: under your newest message from before the thread began (the request the bot was busy with, or the
        // one it had just answered).
        var best: Int?
        for (index, message) in messages.enumerated() where message.role == .user {
            guard let at = message.timestamp else { continue }
            if at <= thread.startedAt { best = index } else { break }
        }
        return best
    }

    /// Open (its messages in place) or folded (one line). Open while it is the newest thing in the chat: nothing the
    /// bot has finished saying in the main chat comes after it. A thread still answering, or one that could not start,
    /// stays open wherever it is.
    static func isOpen(_ thread: ChatThread, anchor: Int, in messages: [ChatMessage]) -> Bool {
        if thread.running || thread.problem != nil { return true }
        guard anchor + 1 < messages.count else { return true }
        for message in messages[(anchor + 1)...] where message.role == .assistant && message.sender == nil {
            if !message.isStreaming && !ChatTranscript.blocks(message).isEmpty { return false }
        }
        return true
    }

    /// What an open thread shows in the main chat: your last message in it and what the bot said after it. `earlier`
    /// counts the spoken messages before those.
    static func shown(_ thread: ChatThread) -> (messages: [ChatMessage], earlier: Int) {
        let spoken = thread.spoken
        guard let lastYours = spoken.lastIndex(where: { $0.role == .user }) else { return (spoken, 0) }
        return (Array(spoken[lastYours...]), lastYours)
    }

    private static let inheritedBotChatPattern = try! NSRegularExpression(pattern: #"^bot chat(?:\s+#\d+)?$"#, options: [.caseInsensitive])

    /// True when `title` is `"Bot Chat"` or a branch-numbered copy (`"Bot Chat #2"`, `"Bot Chat #3"`, …) inherited
    /// from the parent Bot Chat rather than a real name for the thread.
    static func isInheritedBotChatTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return inheritedBotChatPattern.firstMatch(in: trimmed, range: range) != nil
    }

    /// "Thread", or its own short title once it has one.
    static func name(_ thread: ChatThread) -> String {
        guard let title = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title != defaultTitle, !isInheritedBotChatTitle(title)
        else { return defaultTitle }
        // Hermes's first title is the opening words, cut: the app's own short title replaces it a moment later.
        let first = thread.spoken.first(where: { $0.role == .user }).map(ChatTranscript.messageText) ?? ""
        return ShortTitle.isPlaceholder(title, firstMessage: first) ? defaultTitle : title
    }

    static let defaultTitle = "Thread"

    /// "1 message", "4 messages".
    static func countWords(_ count: Int) -> String { count == 1 ? "1 message" : "\(count) messages" }

    /// The folded line's words after the name: "4 messages", or the problem.
    static func foldedTail(_ thread: ChatThread) -> String? {
        let count = thread.spoken.count
        return count > 0 ? countWords(count) : nil
    }

    /// The open block's header: "Thread", "Flight on Friday", and "· 6 messages" when it holds more than it shows.
    static func header(_ thread: ChatThread) -> (name: String, tail: String?) {
        let shown = self.shown(thread)
        return (name(thread), shown.earlier > 0 ? countWords(thread.spoken.count) : nil)
    }

    /// The threads of one chat by the index of the message each hangs under, oldest thread first under one message.
    static func byAnchor(_ threads: [ChatThread], in messages: [ChatMessage]) -> [Int: [ChatThread]] {
        var out: [Int: [ChatThread]] = [:]
        for thread in threads.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let index = anchorIndex(of: thread, in: messages) else { continue }
            out[index, default: []].append(thread)
        }
        return out
    }
}

/// A thread read from the gateway without opening it (another device's, or one from an earlier run).
nonisolated enum ThreadFetch {
    nonisolated struct Result: Sendable {
        var messages: [ChatMessage]
        var anchorRow: Int?
    }

    /// From its stored rows: the hidden seed gives the anchor and is left out of the messages. Also heals legacy
    /// threads whose gateway stripped `display_kind: "hidden"` via `_seed_branch_row` by detecting the closing-note
    /// boundary row and trimming the leaked seed prefix.
    static func read(rows: [JSONValue]) -> Result {
        var anchor: Int?
        var sawHidden = false
        var visible: [JSONValue] = []
        for row in rows {
            if row["display_kind"]?.string == "hidden" {
                sawHidden = true
                if let text = row["content"]?.string, let found = ThreadSeed.anchorRow(in: text) { anchor = found }
                continue
            }
            visible.append(row)
        }
        if !sawHidden, let seedEnd = visible.lastIndex(where: { row in
            row["role"]?.string == "assistant" && (row["content"]?.string.map(ThreadSeed.isClosingNote) == true)
        }) {
            if let text = visible[seedEnd]["content"]?.string, let found = ThreadSeed.anchorRow(in: text) {
                anchor = found
            }
            visible = Array(visible.dropFirst(seedEnd + 1))
        }
        return Result(messages: Hydration.fold(visible).messages, anchorRow: anchor)
    }

    static func load(client: any GatewayClient, storedId: String, profile: String?) async throws -> Result {
        read(rows: try await ChatTranscript.fetchAllRows(client: client, storedSessionId: storedId, profile: profile))
    }
}

/// [threads] §9: compact context note carried on the next main-chat prompt after an auto-thread settled while the main
/// chat was busy, so the main chat never has amnesia about decisions made in the side thread. Stripped from the visible
/// bubble everywhere (`SentTitles`), just like `PhoneChatNote`.
nonisolated enum ThreadContextNote {
    static let marker = "[Side thread context — handled while this chat was busy; use only as background for the message below]"
    static let maxCharacters = 2_400
    static let perLineCharacters = 400

    /// Summarises settled side-thread turns into a compact note; nil when there are no spoken messages.
    static func format(threads: [(title: String?, messages: [ChatMessage])], maxCharacters: Int = Self.maxCharacters) -> String? {
        var lines: [String] = []
        var budget = maxCharacters - marker.count - 4
        guard budget > 80 else { return nil }
        for thread in threads {
            let spoken = thread.messages.filter { $0.role != .system && $0.error == nil && !$0.isStreaming }
            guard !spoken.isEmpty else { continue }
            var headerAdded = false
            let heading = thread.title.flatMap { $0.isEmpty || $0 == ThreadRules.defaultTitle ? nil : $0 }
            for message in spoken.suffix(6) {
                let raw = ChatText.trimmed(ChatTranscript.blocks(message))
                guard !raw.isEmpty else { continue }
                let role = message.role == .user ? "User" : "Assistant"
                let clipped = ThreadSeed.clipped(raw.replacingOccurrences(of: "\n", with: " "), to: perLineCharacters)
                let line = "- \(role): \(clipped)"
                var cost = line.count + 1
                var prefixLine: String?
                if !headerAdded, let heading {
                    let h = "Thread “\(heading)”:"
                    prefixLine = h
                    cost += h.count + 1
                }
                guard cost <= budget else { break }
                if let prefixLine { lines.append(prefixLine); headerAdded = true }
                lines.append(line)
                budget -= cost
            }
        }
        guard !lines.isEmpty else { return nil }
        return marker + "\n" + lines.joined(separator: "\n")
    }

    static func appended(to prompt: String, note: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !note.isEmpty else { return prompt }
        return trimmed + "\n\n" + note
    }

    static func hasNote(_ stored: String) -> Bool {
        stored.contains("\n\n" + marker)
    }

    /// Removes the trailing side-thread context block from a stored prompt, returning the user's own words.
    static func stripped(_ stored: String) -> String? {
        guard let range = stored.range(of: "\n\n" + marker) else { return nil }
        let own = String(stored[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? nil : own
    }
}
