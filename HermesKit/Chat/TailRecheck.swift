// [offline] The tail recheck (docs/spec/3x-offline.md §6.3), a port of the web app's `src/connection-tail-recheck.ts`.
// A reply cut off by a reconnect whose missed events are gone (the replay buffer exceeded, the gateway restarted) stays
// cut off: the resume finds the turn no longer running and shows the journaled partial reply, which the gateway had not
// saved yet. Such a resume starts a series: the chat's newest rows are read again after 2, 5, 10, 20, 30, 60, 120 s
// while the chat is on screen and the app in front; once the saved rows hold the same prompt followed by a reply at
// least as long as the one shown, the chat reads its tail again and the saved reply replaces the partial.

import Foundation

nonisolated enum TailRecheck {
    static let ladder: [TimeInterval] = [2, 5, 10, 20, 30, 60, 120]

    /// What the chat shows of its last turn: the prompt, and how much of the reply after it.
    struct Shown: Equatable, Sendable {
        var prompt: String
        var reply: Int
    }

    static func shown(_ messages: [ChatMessage]) -> Shown {
        let at = messages.lastIndex { $0.role == .user }
        let after = at.map { messages[($0 + 1)...] } ?? messages[...]
        let reply = after.filter { $0.role == .assistant }.reduce(0) { $0 + normal($1.plainText).count }
        return Shown(prompt: at.map { messages[$0].plainText } ?? "", reply: reply)
    }

    static func rowText(_ row: JSONValue) -> String {
        if let text = row["content"]?.string { return text }
        if case .array(let parts)? = row["content"] { return parts.map { $0["text"]?.string ?? "" }.joined() }
        return ""
    }

    private static func normal(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What the gateway's newest rows hold of the turn on show.
    enum Saved: Equatable, Sendable {
        /// The turn's prompt is not there, or nothing is saved after it yet.
        case nothing
        /// A reply is saved after the prompt, shorter than the one shown.
        case shorter
        /// A reply at least as long as the one shown.
        case covers
    }

    /// The same prompt, read leniently (review): the gateway may save a prompt with more around it than the phone
    /// shows (an attachment note, injected context) or the phone may show a note the gateway does not keep, so one
    /// containing the other counts once white space is evened out. Two different prompts never match.
    static func samePrompt(saved: String, shown: String) -> Bool {
        let saved = normal(saved), shown = normal(shown)
        if saved == shown { return true }
        guard !saved.isEmpty, !shown.isEmpty else { return false }
        return saved.contains(shown) || shown.contains(saved)
    }

    /// Lengths are compared with white space evened out on both sides, and the saved reply may be up to 2% shorter
    /// (trailing white space trimmed on saving, text the saved row keeps in a part that is not text).
    static func savedReply(_ rows: [JSONValue], _ shown: Shown) -> Saved {
        guard let at = rows.lastIndex(where: { $0["role"]?.string == "user" }),
              samePrompt(saved: rowText(rows[at]), shown: shown.prompt) else { return .nothing }
        let replies = rows[(at + 1)...].filter { $0["role"]?.string == "assistant" }
        guard !replies.isEmpty else { return .nothing }
        let saved = replies.reduce(0) { $0 + normal(rowText($1)).count }
        return Double(saved) >= (Double(shown.reply) * 0.98).rounded(.down) ? .covers : .shorter
    }

    /// Whether the gateway's newest rows hold that turn's reply, at least as long as the one shown. The prompt must be
    /// there before it: an older turn's reply must never pass for this one's.
    static func savedReplyCovers(_ rows: [JSONValue], _ shown: Shown) -> Bool { savedReply(rows, shown) == .covers }
}

/// One chat's series. A resume of its own (a reconnect, an open) starts the ladder over; only the recheck's own resume,
/// made once the saved reply covers the partial, ends it.
@MainActor final class TailRecheckSeries {
    private let clock: any FlightClock
    /// Still worth checking: the chat is the one on screen and the app is in front.
    private let owed: @MainActor () -> Bool
    /// The chat's newest saved rows (a failed read throws).
    private let read: @MainActor () async throws -> [JSONValue]
    /// Read the tail again so the saved reply replaces the partial.
    private let resume: @MainActor () -> Void

    private var attempt = 0
    private var timer: (any FlightTimer)?
    private var shown: TailRecheck.Shown?
    private var resumed = false
    private var generation = 0
    /// Reads in a row that found a saved reply for this turn shorter than the one shown.
    private var shorterReads = 0
    /// (review) The turn this series gave up on: the gateway has saved a reply for it, the turn is not running, and
    /// two reads in a row found it no longer. Nothing longer will come, so resumes that settle on the same turn with no
    /// more text than this start no new series (a chat that can never match must not cost seven reads per reconnect).
    private var concluded: TailRecheck.Shown?
    /// Reads made (tests and the performance log).
    private(set) var reads = 0
    /// [diagnostics] The chat's tags for log lines.
    var logName = ""

    init(clock: (any FlightClock)? = nil, owed: @escaping @MainActor () -> Bool,
         read: @escaping @MainActor () async throws -> [JSONValue], resume: @escaping @MainActor () -> Void) {
        self.clock = clock ?? LiveFlightClock.shared
        self.owed = owed
        self.read = read
        self.resume = resume
    }

    var isActive: Bool { shown != nil }

    /// [perf] The series just started over: its first read (the ladder's 2 s step) is the one pending.
    var firstStepPending: Bool { timer != nil && attempt == 1 }

    func cancel() {
        timer?.cancel(); timer = nil
        shown = nil
        resumed = false
        attempt = 0
        shorterReads = 0
        generation += 1
    }

    /// A resume of the chat finished. `partial`: it settled (not running) on a reply the gateway has not saved;
    /// `running`: the turn is live again (its events carry the rest).
    func settled(partial: Bool, running: Bool, shown now: TailRecheck.Shown) {
        if running {
            if shown != nil { AppLog.trace("chat", "tail recheck \(logName): turn running again, series ends") }
            concluded = nil; return cancel()
        }
        if let concluded, partial {
            if concluded.prompt == now.prompt, now.reply <= concluded.reply {
                AppLog.trace("chat", "tail recheck \(logName): same turn already given up on (\(now.reply) chars ≤ \(concluded.reply)), no new series")
                return
            }
            self.concluded = nil
        }
        guard partial else {
            // The partial is folded once; later resumes no longer carry it though it is still what the chat shows. Only
            // the recheck's own resume ends the series here.
            if resumed {
                AppLog.trace("chat", "tail recheck \(logName): saved reply read in, series ends")
                cancel()
            }
            return
        }
        timer?.cancel(); timer = nil
        if let held = shown, held.prompt == now.prompt {
            shown = TailRecheck.Shown(prompt: now.prompt, reply: max(held.reply, now.reply))
        } else {
            shown = now
        }
        if !resumed { attempt = 0 }
        resumed = false
        guard attempt < TailRecheck.ladder.count else { return cancel() }
        AppLog.trace("chat", "tail recheck \(logName): settled on an unsaved reply (\(shown?.reply ?? 0) chars shown), step \(attempt + 1) of \(TailRecheck.ladder.count) in \(Int(TailRecheck.ladder[attempt])) s")
        generation += 1
        schedule(generation)
    }

    private func schedule(_ token: Int) {
        let wait = TailRecheck.ladder[attempt]
        attempt += 1
        timer = clock.schedule(after: wait) { [weak self] in self?.check(token) }
    }

    private func check(_ token: Int) {
        timer = nil
        guard token == generation, let shown else { return }
        guard owed() else { return cancel() }
        reads += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            let rows: [JSONValue]?
            do { rows = try await self.read() } catch {   // [diagnostics]
                AppLog.swallowed("chat", "tail recheck \(self.logName) read \(self.reads)", error)
                rows = nil
            }
            guard token == self.generation, self.shown == shown else { return }
            guard self.owed() else {
                AppLog.trace("chat", "tail recheck \(self.logName): chat left or app in back, series ends")
                return self.cancel()
            }
            let saved = rows.map { TailRecheck.savedReply($0, shown) }
            self.shorterReads = saved == .shorter ? self.shorterReads + 1 : 0
            AppLog.trace("chat", "tail recheck \(self.logName) read \(self.reads) (step \(self.attempt)): \(rows?.count ?? -1) rows, saved reply \(saved.map { "\($0)" } ?? "read failed") vs \(shown.reply) chars shown")
            if saved == .covers {
                AppLog.trace("chat", "tail recheck \(self.logName): saved reply covers the partial, forced tail read")
                self.resumed = true
                self.resume()
            } else if self.shorterReads >= 2 {
                // Saved, not running, and no longer on a second look: what is shown stays, the reading stops.
                AppLog.trace("chat", "tail recheck \(self.logName): saved reply shorter twice, gives up; the shown reply stays")
                self.cancel()
                self.concluded = shown
            } else if self.attempt < TailRecheck.ladder.count {
                self.schedule(token)
            } else {
                AppLog.trace("chat", "tail recheck \(self.logName): ladder done without a saved reply that covers it")
                self.cancel()
            }
        }
    }
}
