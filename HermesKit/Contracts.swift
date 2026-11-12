// Shared contracts for milestone 1. Every module codes against these types; change them only in integration.
// Protocol facts: docs/spec/*.md. Default actor isolation is MainActor (project setting); network-facing
// types below are explicitly `nonisolated` so they can be used from any context.

import Foundation

// MARK: - JSON

/// Loosely typed JSON for gateway payloads (Hermes adds fields freely; decode strictly only where needed).
nonisolated enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.007e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] } else { return nil } }
    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] } else { return nil }
    }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var double: Double? {
        switch self { case .number(let n): return n; case .string(let s): return Double(s); default: return nil }
    }
    /// nil for NaN, ±inf and values past Int's range ("1e400", "nan" in a string): `Int(Double)` traps on those.
    var int: Int? { double.flatMap { $0.isFinite && abs($0) < 9.2e18 ? Int($0) : nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    var isNull: Bool { if case .null = self { return true } else { return false } }

    /// Decode raw JSON bytes. Throws on invalid JSON.
    static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    nonisolated init(stringLiteral v: String) { self = .string(v) }
    nonisolated init(integerLiteral v: Int) { self = .number(Double(v)) }
    nonisolated init(floatLiteral v: Double) { self = .number(v) }
    nonisolated init(booleanLiteral v: Bool) { self = .bool(v) }
    nonisolated init(nilLiteral: ()) { self = .null }
    nonisolated init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    nonisolated init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

// MARK: - Accounts and connection (owner: Net)

/// One saved gateway sign-in (spec 01 §2.1, §2.4.1). Secrets (cookies, bearer pairs) live in the Keychain, never here.
nonisolated struct GatewayAccount: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable { case password, nous }
    var id: String               // stable key, e.g. "<normalized base URL>|<username>" or "nous:<user id>@<base>"
    var baseURL: URL             // normalized, no trailing slash
    var kind: Kind
    var username: String?        // password accounts only; never shown for Nous ("Nous account")
    var label: String            // human label for the gateway (host name)
    /// [own-login] `.nous` accounts signed in with the gateway's own login provider instead (self-hosted OIDC): its
    /// name on the wire. nil for Nous and for password accounts.
    var provider: String? = nil

    /// Signed in in the browser with the gateway's own login provider, not Nous.
    var usesOwnLogin: Bool { kind == .nous && provider != nil && provider != "nous" }
}

nonisolated enum ConnectionState: Sendable, Equatable {
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case offline(reason: String)
    case signedOut(reason: String)   // session ended (401 after refresh, revoked): show sign-in again
}

/// A gateway event frame: {"method":"event","params":{type, session_id, payload?, seq?}} (spec 01 §11.4).
nonisolated struct GatewayEvent: Sendable {
    var type: String
    var sessionId: String            // runtime id (8 hex) or "" for broadcasts
    var seq: Int?
    var payload: JSONValue           // .null when absent
    /// [presence] Delivered by a reconnect's (or a gap repair's) catch-up, not as it happened: old news (spec 3x-presence §3.4).
    var replayed = false
    /// [authority] The turn this frame belongs to (`execution_generation`, sent by a gateway-hosted Hermes's session authority).
    var generation: Int? = nil
}

nonisolated struct RPCError: Error, Sendable, CustomStringConvertible {
    var code: Int
    var message: String
    var data: JSONValue?
    var description: String { "RPC \(code): \(message)" }
}

nonisolated struct HTTPError: Error, Sendable, CustomStringConvertible {
    var status: Int
    var body: String?
    var description: String { "HTTP \(status)" }
}

/// Everything the rest of the app needs from a signed-in gateway. Implemented by `LiveGatewayClient` (Net) and by
/// test/preview fakes. Implementations reconnect by themselves and keep auth fresh (Nous renewal, single-flight).
nonisolated protocol GatewayClient: AnyObject, Sendable {
    var account: GatewayAccount { get }
    /// Authenticated REST call relative to the base URL ("/api/sessions/x/messages"). Throws `HTTPError` for a non-2xx
    /// answer from the gateway; transport and session failures (unreachable, timeout, a 401 whose renewal failed…)
    /// throw `GatewayFailure` (a `LocalizedError` with plain-words copy).
    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data
    /// JSON-RPC call over /api/ws. Waits for the socket to be ready (bounded by `timeout`). Throws `RPCError` only, or
    /// `CancellationError` when the caller's task is cancelled. Besides the gateway's own error answers, three client
    /// kinds (GatewayFailure.swift): `isTimeout` (sent, no answer in time), `isConnectionLost` (sent, then the socket
    /// closed first: delivery unconfirmed), `isNotConnected` (never sent: safe to send again).
    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue
    /// New subscriber stream for every event frame (multicast). Includes "gateway.ready" after each (re)connect.
    func events() -> AsyncStream<GatewayEvent>
    /// `events()` narrowed to these types, in order. A consumer that wants a few types uses it so it is not woken (on
    /// the main actor) for every message delta.
    func events(matching types: Set<String>) -> AsyncStream<GatewayEvent>
    /// New subscriber stream of connection state changes; yields the current state first.
    func connectionStates() -> AsyncStream<ConnectionState>
    /// Payload of the latest gateway.ready (replay_epoch, performance plugin info…), nil before the first.
    var latestReady: JSONValue? { get }
    /// Returns once `session`'s (runtime id) missed events have been replayed after a reconnect — at once when nothing
    /// is held. A chat awaits this before re-reading that session's history so the read never races the replay
    /// (spec 01 §13.3). Held events are released by the client on its own; this only orders the caller's read.
    func replayDone(session: String) async
    /// After `replayDone`: the `last_seen` cursor the connection's own replay of `session` answered from on this socket
    /// (every frame after it was delivered, possibly none), nil when it did not replay that session in full.
    func replayedCursor(session: String) async -> Int?
    /// App lifecycle hints: foreground → reconnect now if needed; background → let the socket go after a grace.
    func appDidBecomeActive()
    func appDidEnterBackground()
    /// [talk-background] A conversation running with the app away keeps the socket (true) until it ends (false).
    func holdThroughBackground(_ on: Bool)
    /// Close the socket and stop reconnecting (sign-out / account switch).
    func shutdown()
    /// [load-cache] `GET /api/config` (with `query`, e.g. `profile=`) for a reader that only reads it: the live client
    /// shares a read in flight and reuses an answer for `maxAge` seconds (0: only shared), dropping it on any write
    /// (SharedConfigReads). Fakes read every time.
    func configData(_ query: [URLQueryItem], maxAge: TimeInterval) async throws -> Data
}

extension GatewayClient {
    /// [load-cache] Fakes: a plain read.
    nonisolated func configData(_ query: [URLQueryItem], maxAge: TimeInterval) async throws -> Data {
        try await rest("GET", "/api/config", query: query, body: nil)
    }

    nonisolated func configData(_ query: [URLQueryItem]) async throws -> Data {
        try await configData(query, maxAge: SharedConfigReads.defaultMaxAge)
    }

    /// Fakes and clients with no background close: nothing to hold.
    nonisolated func holdThroughBackground(_ on: Bool) {}
    /// Fakes and clients without a replay hold: nothing to wait for.
    nonisolated func replayDone(session: String) async {}
    nonisolated func replayedCursor(session: String) async -> Int? { nil }

    /// Fakes: `events()` filtered after the fact (the live client filters before the event is queued).
    nonisolated func events(matching types: Set<String>) -> AsyncStream<GatewayEvent> {
        let all = events()
        return AsyncStream { continuation in
            let pump = Task {
                for await event in all where types.contains(event.type) { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    nonisolated func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> Data {
        try await rest("GET", path, query: query, body: nil)
    }
    nonisolated func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await call(method, params, timeout: .seconds(30))
    }
}

// MARK: - Bots and sessions (owner: Data/Bots)

/// One row of the Bots list. A bot is a Hermes profile; its chat is the session titled "Bot Chat" (spec 02 §1, §8).
nonisolated struct Bot: Identifiable, Hashable, Sendable {
    var id: String                   // profile name ("default" shows as "Hermes")
    var name: String                 // display name
    var role: String?                // second line when there is no preview
    var preview: String?             // cleaned last-message preview
    var lastActive: Date?
    var isWorking: Bool              // a turn is running on its chat
    var unread: Bool                 // device-local dot (spec 02 §6.6–6.7)
    var pinned: Bool
    var pinOrder: Int?               // order among pinned tiles
    var sectionName: String?
    var hidden: Bool
    var canonicalSessionId: String?  // stored id of its "Bot Chat" if the roster knows it
    var head: JSONValue?             // raw ui_meta["dispatch-head"] record (spec 02 §10); nil → default head
    /// [questions] Its chat waits for an answer: "Waiting for your approval / reply" (spec 1x §3.6).
    var needsInput: NeedsInput? = nil
    /// The preview's lead ("Draft:", "From Inbox:"), drawn apart in the label colour (spec 02 §6.4 item 4); `preview`
    /// starts with it.
    var previewPrefix: String? = nil
    /// [presence] Its browser or its screen in use (spec 3x-presence §4, §5); nil when neither, so an idle roster hashes as before.
    var presence: BotPresence? = nil
    /// [botslist] Its chat's open has taken more than a second: the row says "Waking up…" (parity §3 L184). Display only.
    var waking: Bool = false
    /// [botslist] A standing problem's words, shown in orange as the row's status ("Sign in again for this bot",
    /// parity §3 L185). Display only, never saved.
    var attention: String? = nil
    /// [toolnow] Its Bot Chat's running step in a few words ("reading package.json", LiveSteps): the row's live line
    /// names it instead of "Working…". Display only.
    var step: String? = nil
}

nonisolated struct SessionSummary: Identifiable, Hashable, Sendable {
    var id: String                   // stored session id
    var profile: String
    var title: String
    var preview: String?
    var lastActive: Date?
    var source: String?
    var unread: Bool
    var isRunning: Bool
    /// Sessions row actions: pinned on the gateway (the list's Pinned group), archived (the Archived view's rows).
    var pinned: Bool = false
    var archived: Bool = false
    /// More › Color: one of `SessionColors` (device-local), nil for none.
    var color: Int? = nil
    /// From the messaging slice: a chat that started outside the app (Telegram, Discord, API…).
    var outside: Bool = false
    /// The platform the row's mark names (`ChatSource.origin`): a messaging chat's source, or where a handoff began.
    var origin: String? = nil
    /// Search: the hit's cleaned snippet with its matches marked (`SessionSearch.matchSnippet`), shown for the preview.
    var searchSnippet: String? = nil
    // [sessions-m9] Filter & Sort, Row Detail, the pending line (docs/spec/3x-sessions.md §3.1; types in Contracts+sessions.swift).
    var startedAt: Date? = nil
    /// `input_tokens + output_tokens`.
    var tokens: Int = 0
    /// The actual cost, else the estimate, else 0 (`sessionCostUsd`).
    var cost: Double = 0
    /// "main · hermes-4 · 2 messages · 1 tool call": the second line when Preview is off or there is none.
    var metadata: String = ""
    var status: SessionStatus = .idle
    var pending: SessionPending? = nil
    var cwd: String? = nil
    // [/sessions-m9]
    /// [toolnow] The running turn's step in a few words (LiveSteps): the row says it instead of "Working…".
    var step: String? = nil
    /// The sign-in Hermes stamped on it (`SidebarSessionRow.userId`), for a refused edit's words.
    var owner: String? = nil
}

// MARK: - Chat (owner: Data/Chat)

/// One tool call inside an assistant turn (spec 03 §6, spec 04 §3.2).
nonisolated struct ToolCall: Hashable, Sendable {
    enum State: String, Hashable, Sendable { case running, done, failed }
    var id: String
    var name: String
    var title: String                // human wording ("Read file ios/App.swift", spec 03 §8.3); falls back to name
    var argsText: String?
    var summary: String?             // tool.complete summary / short result
    var state: State
    var durationSeconds: Double?
    /// [activity] A finished card tool's bounded result (delegate rows, generated image; docs/spec/1x-activity.md §11.1).
    var card: ToolCard? = nil
    /// [transcript] The finished call's size in words ("10 KB output") or its one short line of shell output, shown at
    /// the row's trailing edge (docs/spec/3x-transcript.md §5.1). Not kept in the transcript cache.
    var note: String? = nil
}

nonisolated enum ChatPart: Hashable, Sendable {
    case text(String)                // markdown
    case reasoning(String)
    case tool(ToolCall)
}

/// One message: a user row, one whole assistant turn (parts interleaved in order), or a system notice.
nonisolated struct ChatMessage: Identifiable, Hashable, Sendable {
    enum Role: String, Hashable, Sendable { case user, assistant, system }
    var id: String                   // "stored-row-{rowId}-{kind}" for history; "local-…" for optimistic/live rows
    var role: Role
    var parts: [ChatPart]
    var timestamp: Date?
    var rowId: Int?
    var isStreaming: Bool = false    // assistant turn still receiving events
    var isPending: Bool = false      // optimistic user row not yet acknowledged
    var interrupted: Bool = false    // stopped by the user
    var error: String? = nil         // turn failed / delivery unconfirmed
    /// Bumped on every content change; UI layout caches key on (id, revision, width).
    var revision: Int = 0
    /// [groups] Another sender's message (a room member, a delivery from another bot): an incoming bubble with its
    /// name and face (docs/spec/3x-groups.md §7.12). nil = you, or the chat's own bot.
    var sender: ChatSender? = nil
    /// [transcript] A cron delivery's job name, on the byline beside its bot (docs/spec/3x-transcript.md §2.1); and a
    /// turn whose reply was the scheduler's "[SILENT]": the note drawn after its tool rows. Display-time only (set by
    /// the resolver pass the chat screen runs; never stored).
    var job: String? = nil
    var silentNote: Bool = false
    /// A background process's note: what it printed (command, output), opened from its one-line title. Display-time only.
    var report: String? = nil
    /// Tapback reactions on the message (yours and the bot's), from its stored rows or `message.react`'s answer.
    var reactions: [MessageReaction] = []
    /// The stored row a reaction is written to when that differs from `rowId` (a reply folded from several rows reacts on
    /// the row holding its words, as the live turn's `final_assistant_row_id` does).
    var reactionRow: Int? = nil

    /// The row `message.react` addresses; nil for a message not stored yet.
    var reactionTarget: Int? { reactionRow ?? rowId }
}

/// What changed, so UIKit can update precisely instead of reloading everything.
nonisolated enum ChatChange: Sendable {
    case reset                               // messages replaced wholesale (fresh page over cache, history mode)
    case updated(ids: [String])              // these messages' content changed (streaming deltas, tool states)
    case appended(ids: [String])             // new messages at the newest end
    case prependedOlder(count: Int)          // older messages added at the oldest end
    case removed(ids: [String])
    case state                               // isRunning / connection / title / hasOlder changed
}

/// Optional details a chat session offers the chat screen (the live session and the demo fakes adopt it); the screen
/// falls back to the session's profile and title without them.
protocol ChatSessionDetails: AnyObject {
    /// "<account id>|<profile>|<stored session id>": the cache scope of the chat's layouts. Message ids such as
    /// "stored-row-12-assistant" repeat in every profile's state.db, so they never identify a row on their own.
    var layoutScope: String { get }
    /// The bot the chat belongs to: "Message Ivy", "Ivy couldn’t finish this reply", "Ivy said:".
    var botName: String { get }
    /// The model answering ("Waiting for <model>"); nil when unknown.
    var modelName: String? { get }
    /// The gateway's time of the newest stored message shown (the `seenThrough` a bot's unread baseline moves to when
    /// the chat is left, spec 02 §6.7); nil when nothing stored is shown.
    var seenThrough: Date? { get }
}

/// A chat whose sends wait in a local queue while a reply runs (spec 04 §6.2 M1). The chat screen shows the queue as a
/// card above the composer; the live session adopts it.
protocol ChatQueueing: AnyObject {
    /// Oldest first.
    var queuedMessages: [QueuedMessage] { get }
    /// Stop parked the queue: it waits for Send Now or the next send.
    var isQueueParked: Bool { get }
    func sendQueuedNow(_ id: String)
    /// Takes a message out of the queue and returns its text.
    @discardableResult func removeQueued(_ id: String) -> String?
    /// L463: a reply is running (Send Now steers when it can; Stop and Send is offered).
    var isReplyRunning: Bool { get }
    /// Whether Send Now may steer this row into the running reply (text only, no slash command; gateway supports it).
    func canSteer(_ id: String) -> Bool
    /// Puts this row into the running reply with `session.redirect`; false (the row stays queued) when refused.
    func steerQueued(_ id: String) async -> Bool
    /// The row is going out now (Send Now steering it into the reply): its caption reads "Sending…".
    func isQueuedSending(_ id: String) -> Bool
    /// Delete (spec 3x-composer §15.3): the row is thrown away, its photos, files and memo recording with it; nothing
    /// comes back to the field.
    func discardQueued(_ id: String)
    /// Edit (spec 3x-composer §15.5): the row being edited, which doesn't send until Save or Cancel.
    var queueEditingId: String? { get }
    /// Whether Edit is offered for the row (typed words only).
    func canEditQueued(_ id: String) -> Bool
    /// Holds the row for an edit and returns its words; nil when it can't be edited.
    func beginQueuedEdit(_ id: String) -> String?
    /// Save: the row's words become `text` in place (same id, same position) and the hold ends. False when it is gone.
    @discardableResult func saveQueuedEdit(_ id: String, text: String) -> Bool
    /// Cancel (or Save done): the hold ends and the queue goes on.
    func endQueuedEdit()
}

extension ChatQueueing {
    var isReplyRunning: Bool { false }
    func canSteer(_ id: String) -> Bool { false }
    func steerQueued(_ id: String) async -> Bool { false }
    func isQueuedSending(_ id: String) -> Bool { false }
    func discardQueued(_ id: String) { removeQueued(id) }
    var queueEditingId: String? { nil }
    func canEditQueued(_ id: String) -> Bool { false }
    func beginQueuedEdit(_ id: String) -> String? { nil }
    func saveQueuedEdit(_ id: String, text: String) -> Bool { false }
    func endQueuedEdit() {}
}

/// A chat that can deliver its pending changes now instead of at the next display frame: a send's own bubble reaches
/// the screen in the same frame the field clears (spec 06 §5.2). The live session adopts it.
protocol ChatChangeFlushing: AnyObject {
    func flushChanges()
}

/// How far a chat's open has got. With nothing to paint, the screen shows a skeleton while it opens (spec 06 §4.2) and,
/// when it failed, the reason with Retry (spec 03 §4.7; Retry calls `start()` again).
enum ChatOpenPhase: Equatable, Sendable { case opening, open, failed(String) }

protocol ChatOpenStatus: AnyObject {
    var openPhase: ChatOpenPhase { get }
}

/// A tool call's full detail for its step sheet (spec 03 §8.8, spec 06 §3.3): output, error output, exit code, diff.
/// The row only carries a one-line summary.
protocol ChatToolDetails: AnyObject {
    func toolDetail(messageId: String, toolId: String) -> ToolDetail?
}

/// "Delivery Unconfirmed · Check" under your message (spec 04 §2.5): a read-only look for it in the stored chat.
/// `true` = it is there (the mark goes), `false` = not there, `nil` = couldn't tell. Never resends.
protocol ChatDeliveryChecking: AnyObject {
    func checkDelivery(_ messageId: String) async -> Bool?
}

/// The open chat as the chat screen sees it. `messages` is oldest → newest.
/// `init` of the live implementation fills `messages` from the disk cache synchronously so the first frame of the push
/// already shows the chat; `start()` then fetches fresh history and attaches to live events.
protocol ChatSessionModel: AnyObject {
    var title: String { get }
    var profile: String { get }
    var head: JSONValue? { get }
    var messages: [ChatMessage] { get }
    var isRunning: Bool { get }              // a turn is in flight (show Stop instead of Send)
    var hasOlder: Bool { get }
    var isLoadingOlder: Bool { get }
    var connection: ConnectionState { get }
    var statusText: String? { get }          // "Working…", "Reconnecting…", tool in progress, nil when idle
    /// Called on the main actor after every change, already coalesced to at most one call per display frame.
    var onChange: ((ChatChange) -> Void)? { get set }
    func start()                             // begin refresh + live attach (idempotent)
    func stopObserving()                     // screen went away; keep cache
    func loadOlder()                         // page older history in (no-op when !hasOlder or already loading)
    func send(_ text: String)
    func stop()                              // interrupt the running turn
}

// MARK: - Factories the UI uses (owner: integration)

/// The app-wide model the UI talks to. Implemented in App/AppModel.swift (integration); UI modules use fakes until then.
protocol AppServices: AnyObject {
    var account: GatewayAccount? { get }
    /// Display order (spec 02 §7). One listener: `BotsViewController` owns `onBotsChange` and its owner
    /// (`MainTabController`) fans roster changes out to the Sessions list.
    var bots: [Bot] { get }
    /// The Sessions list's recents slice (all bots); cron and messaging-platform rows are not in it.
    var sessions: [SessionSummary] { get }
    var connection: ConnectionState { get }
    var onBotsChange: (() -> Void)? { get set }
    var onSessionsChange: (() -> Void)? { get set }
    /// Called on the main actor whenever `connection` changes (the lists' skeleton, offline state and subtitle).
    var onConnectionChange: (() -> Void)? { get set }
    func refreshBots()
    func refreshSessions()
    /// Builds the chat for a bot synchronously from cache (instant), then starts it.
    func chat(for bot: Bot) -> ChatSessionModel
    func chat(for session: SessionSummary) -> ChatSessionModel
    func markRead(_ bot: Bot)
    func signOut()
    /// The roster has answered at least once since sign-in (or its read failed): until then an empty list is still
    /// loading (skeleton rows), not "No Bots Yet".
    var botsLoaded: Bool { get }
    /// Whether the Sessions tab is the one showing (no chat pushed over it counts separately): its list refreshes on the
    /// on-screen cadence only then (spec 03 §7.7: 10 s on screen, 45 s with a probe first off it).
    func setSessionsListShown(_ shown: Bool)
    /// [m9/ipad] Two panes: the selected list stays on screen beside an open chat, so it keeps its on-screen cadence.
    func setListsBesideChat(_ beside: Bool)
    /// A finger rests on a bot's row: read its chat's newest rows now, so the open that may follow paints at once
    /// (spec 03 §4.1 finger-down warm). Cheap to call repeatedly.
    func prefetchChat(for bot: Bot)
}

extension AppServices {
    var botsLoaded: Bool { true }
    func setSessionsListShown(_ shown: Bool) {}
    func setListsBesideChat(_ beside: Bool) {}
    func prefetchChat(for bot: Bot) {}
}
