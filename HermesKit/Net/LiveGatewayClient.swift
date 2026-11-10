// The GatewayClient the app uses for a signed-in account: authenticated REST, JSON-RPC over /api/ws, multicast
// events and connection states, app lifecycle and network hints. One per account; `shutdown()` ends it for good.

import Foundation
import Network
import UIKit

nonisolated final class LiveGatewayClient: GatewayClient, GatewayTransfers, GatewayPluginSockets, GatewayDisplaySockets, GatewayTerminalSockets, Sendable {   // VOICE: GatewayTransfers; [browser] GatewayPluginSockets; [screen] GatewayDisplaySockets; [terminal] GatewayTerminalSockets
    let account: GatewayAccount

    private let auth: GatewayAuth
    private let connection: GatewayConnection
    private let transport: HTTPTransport
    private let eventHub = Broadcast<GatewayEvent>()
    private let stateHub = StateHub(.connecting)
    private let ready = Locked<JSONValue?>(nil)
    private let failure = Locked<GatewayFailure?>(nil)
    private let closed = Locked(false)
    private let commands: AsyncStream<GatewayConnection.Command>.Continuation
    private let background: BackgroundTaskHolder
    private let pathWatcher: PathWatcher?
    // [offline] The outage gate every GET passes (docs/spec/3x-offline.md §6.1) and when the next dial before the first
    // ready is due (§3.6). HermesKit/Net/LiveGatewayClient+Offline.swift reads them.
    let outage = OutageGate()
    /// [load-cache] `GET /api/config` shared by the readers that only read it.
    let configReads = SharedConfigReads()
    let retryDue = Locked<Date?>(nil)
    let retryHub = Broadcast<Date?>()

    /// - Parameters:
    ///   - verified: true right after a typed sign-in; false for a launch restore (the first ticket the dial mints is
    ///     the session check, as on the desktop: no separate `/api/auth/me`).
    ///   - socketProfile: the `profile` query on `/api/ws` (ignored by the server; sent for parity).
    ///   - timing: the connection's intervals (tests shorten them).
    init(stored: StoredAccount, transport: HTTPTransport, vault: AccountVault = .app, verified: Bool,
         socketProfile: String = "default", watchNetwork: Bool = true, timing: GatewayConnection.Timing = .standard) {
        let base = URL(string: stored.url) ?? URL(string: "https://invalid.invalid")!
        self.account = stored.gatewayAccount ?? GatewayAccount(id: stored.url + "|" + stored.username, baseURL: base,
                                                               kind: stored.isNous ? .nous : .password, username: nil, label: stored.url)
        self.transport = transport
        let auth = GatewayAuth(stored: stored, base: base, transport: transport, vault: vault, verified: verified)
        self.auth = auth
        let background = BackgroundTaskHolder()
        self.background = background
        var outlets = GatewayConnection.Outlets(events: eventHub, states: stateHub, ready: ready, failure: failure,
                                                endBackgroundTask: { Task { @MainActor in background.end() } })
        outlets.offline = OfflineOutlets(gate: outage, retryDue: retryDue, retryHub: retryHub)   // [offline]
        let connection = GatewayConnection(base: base, socketProfile: socketProfile, auth: auth, transport: transport,
                                           outlets: outlets, timing: timing)
        self.connection = connection
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayConnection.Command.self, bufferingPolicy: .unbounded)
        self.commands = continuation
        self.pathWatcher = watchNetwork ? PathWatcher { change in continuation.yield(.path(change)) } : nil

        let events = eventHub, states = stateHub, retries = retryHub
        // Weak: the auth must not keep its connection (and that its auth) alive after the client is gone.
        let onRejected: @Sendable (GatewayFailure) -> Void = { [weak connection] failure in
            Task { await connection?.authRejected(failure) }
        }
        Task {
            await auth.setRejectionHandler(onRejected)
            await connection.start()
            // Lifecycle and network commands, strictly in the order they were given.
            for await command in stream { await connection.handle(command) }
            events.finish()
            states.finish()
            retries.finish()
        }
        pathWatcher?.start()
    }

    deinit {
        // Dropped without shutdown(): end it all the same, so no socket keeps reconnecting for nobody.
        if !closed.value {
            pathWatcher?.stop()
            commands.yield(.shutdown)
            let auth = self.auth, transport = self.transport
            Task {
                await auth.settleRenewal()
                await auth.close()
                transport.invalidate()
            }
        }
        commands.finish()
    }

    // MARK: GatewayClient

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        try await rest(method, path, query: query, body: body, timeout: 30)
    }

    func configData(_ query: [URLQueryItem], maxAge: TimeInterval) async throws -> Data {
        try await configReads.data(query, maxAge: maxAge) { [self] in try await rest("GET", "/api/config", query: query, body: nil) }
    }

    /// `rest` with an explicit timeout (seconds, clamped to 1…120).
    func rest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data?, timeout: TimeInterval) async throws -> Data {
        try await send(method, path, query: query, body: body, contentType: "application/json", timeout: min(max(timeout, 1), 120))
    }

    // VOICE (spec 1x-voice §2.2, R5): multipart uploads and transcription need their own body type and up to 600 s.
    /// `GatewayTransfers`: `rest` with a body type and a timeout clamped to 1…600 s.
    func transfer(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, contentType: String,
                  timeout: TimeInterval) async throws -> Data {
        try await send(method, path, query: query, body: body, contentType: contentType, timeout: min(max(timeout, 1), 600))
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, contentType: String,
                      timeout: TimeInterval) async throws -> Data {
        if closed.value { throw GatewayFailure.connectionChanged }
        let url = try GatewayAddress.endpoint(base: account.baseURL, path: path, query: query)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // [offline] §6.1: reads are held while the gateway is known down (one probe per window); writes never are.
        let read = method == "GET" || method == "HEAD"
        // [load-cache] A write may change the config: what SharedConfigReads kept goes before it is sent and once it
        // is answered (a read that started meanwhile isn't kept either).
        if !read { configReads.invalidate() }
        defer { if !read { configReads.invalidate() } }
        if read, !outage.admit() {
            AppLog.trace("net", "read \(AppLog.path(url)) held: gateway known down (\(outage.heldFailure.code))")
            throw outage.heldFailure
        }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await auth.send(request)
            if read { outage.note(status: response.statusCode) }
        } catch {
            if read, !Task.isCancelled { outage.note(failure: GatewayFailure.from(error)) }
            throw error
        }
        if closed.value { throw GatewayFailure.connectionChanged }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError(status: response.statusCode, body: String(decoding: data.prefix(64 << 10), as: UTF8.self))
        }
        return data
    }

    /// Throws `RPCError` only (the contract), or `CancellationError` when the caller's task is cancelled:
    /// - the gateway's own error answer (its code and message);
    /// - `isTimeout`: sent, no answer within `timeout`;
    /// - `isConnectionLost`: sent, then the socket closed first (the gateway may have done it: delivery unconfirmed);
    /// - `isNotConnected`: never sent (no socket while it waited: paused, offline, Tailscale off, signed out, shut
    ///   down…). Safe to send again; `message` is plain words, `notSentBecause` the `GatewayFailure`.
    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        // [load-cache] As a REST write: the config readers' kept answer goes before and after.
        let writesConfig = SharedConfigReads.writes(rpc: method)
        if writesConfig { configReads.invalidate() }
        defer { if writesConfig { configReads.invalidate() } }
        if closed.value {
            AppLog.trace("net", "call \(method) not sent: client already shut down")
            throw RPCError.notSent(.connectionChanged)
        }
        do {
            return try await connection.call(method, params, timeout: timeout)
        } catch let failure as GatewayFailure {
            // The call never reached the gateway (no socket while it waited): mapped to `RPCError.notSent`, safe to
            // send again. Already a `GatewayFailure` by the time it gets here, so this is the layer that decides it.
            AppLog.trace("net", "call \(method) not sent: \(failure.code)")
            throw RPCError.notSent(failure)
        }
    }

    /// Waits while `session`'s missed events are replayed after a reconnect (returns at once when nothing is held).
    /// Chat awaits this before re-reading that session's history so the read never races the replay (spec 01 §13.3).
    func replayDone(session: String) async {
        await connection.replayDone(session: session)
    }

    func replayedCursor(session: String) async -> Int? {
        await connection.replayedCursor(session: session)
    }

    func events() -> AsyncStream<GatewayEvent> { eventHub.subscribe() }

    /// [perf] Filtered before the event is queued: a main-actor consumer of a few types isn't woken by every delta.
    func events(matching types: Set<String>) -> AsyncStream<GatewayEvent> { eventHub.subscribe(where: { types.contains($0.type) }) }

    func connectionStates() -> AsyncStream<ConnectionState> { stateHub.subscribe() }

    var latestReady: JSONValue? { ready.value }

    func appDidBecomeActive() {
        guard !closed.value else { return }
        commands.yield(.becameActive)
    }

    /// Begins the UIKit background task at once (when called on the main thread, as from a scene or app delegate), then
    /// gives the socket 25 s before it closes with 1001.
    func appDidEnterBackground() {
        guard !closed.value else { return }
        let holder = background, commands = self.commands
        let begin: @MainActor () -> Void = {
            let granted = holder.begin { commands.yield(.backgroundExpired) }
            commands.yield(.enteredBackground(granted: granted))
        }
        if Thread.isMainThread { MainActor.assumeIsolated(begin) } else { Task { @MainActor in begin() } }
    }

    /// [talk-background] Let go with the app away: a fresh background task covers the grace the socket now gets.
    func holdThroughBackground(_ on: Bool) {
        guard !closed.value else { return }
        let holder = background, commands = self.commands
        let apply: @MainActor () -> Void = {
            guard !on else { commands.yield(.holdOpen); return }
            let away = UIApplication.shared.applicationState == .background
            commands.yield(.releaseHold(granted: away && holder.begin { commands.yield(.backgroundExpired) }))
        }
        if Thread.isMainThread { MainActor.assumeIsolated(apply) } else { Task { @MainActor in apply() } }
    }

    /// A Nous renewal in flight (one started alongside a request) finishes before the transport goes: a switch to
    /// another gateway otherwise cancels it and can lose the rotated pair (`GatewayAuth.settleRenewal`).
    func shutdown() {
        guard endClient() else { return }
        let auth = self.auth, transport = self.transport
        Task {
            await auth.settleRenewal()
            transport.invalidate()
        }
    }

    // MARK: Extras for the app

    // [browser] A gateway plugin's websocket (hermes-hq-browser's activity list and watch stream): a fresh single-use
    // ticket per socket, as the web app's native shell minted one for every sibling socket. Not the /api/ws lane.
    func pluginSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
        if closed.value { throw GatewayFailure.connectionChanged }
        guard GatewayAddress.reachable(account.baseURL) else { throw GatewayFailure.tailscaleOff }
        let ticket = try await auth.mintTicket(timeout: .seconds(10))
        if closed.value { throw GatewayFailure.connectionChanged }
        guard let url = BrowserWire.socketURL(base: account.baseURL, path: path, query: query, ticket: ticket) else {
            throw GatewayFailure.invalidURL
        }
        let task = try transport.webSocketTask(with: URLRequest(url: url, timeoutInterval: 15))
        task.maximumMessageSize = BrowserWire.maxMessage + 4096
        SocketStats.shared.track(task)           // [diagnostics]
        AppLog.trace("browser", "plugin socket opened: \(path)")
        return task
    }

    // [talk] The gateway's own speech socket (`/api/audio/speak-stream`, docs/spec/3x-talk.md §3.3): a fresh single-use
    // ticket per socket, as for a plugin socket. `VoiceWire.socketURL` only builds addresses under `/api/audio/`.
    func voiceSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
        if closed.value { throw GatewayFailure.connectionChanged }
        guard GatewayAddress.reachable(account.baseURL) else { throw GatewayFailure.tailscaleOff }
        let ticket = try await auth.mintTicket(timeout: .seconds(10))
        if closed.value { throw GatewayFailure.connectionChanged }
        guard let url = VoiceWire.socketURL(base: account.baseURL, path: path, query: query, ticket: ticket) else {
            throw GatewayFailure.invalidURL
        }
        let task = try transport.webSocketTask(with: URLRequest(url: url, timeoutInterval: 15))
        task.maximumMessageSize = VoiceWire.maxMessage
        SocketStats.shared.track(task)           // [diagnostics]
        AppLog.trace("voice", "voice socket opened: \(path)")
        return task
    }

    // [screen] A bot's display socket (Bot Screen's RFB stream). The single-use display ticket from `display.observe`
    // is the only credential that route takes, so no auth ticket is minted; a path other than /api/display/ws is
    // refused without dialling.
    func displaySocket(path: String, ticket: String) async throws -> any ScreenSocketing {
        if closed.value { throw GatewayFailure.connectionChanged }
        guard GatewayAddress.reachable(account.baseURL) else { throw GatewayFailure.tailscaleOff }
        guard let url = ScreenWire.displaySocketURL(base: account.baseURL, path: path, ticket: ticket) else {
            throw GatewayFailure.invalidURL
        }
        let task = try transport.webSocketTask(with: URLRequest(url: url, timeoutInterval: 15))
        SocketStats.shared.track(task)           // [diagnostics]
        return ScreenSocket(task)
    }

    // [terminal] The Terminal page's shell socket (hermes-hq-push 0.9.25's /terminal): a fresh single-use ticket per
    // socket, as for a plugin socket. `TerminalWire.socketURL` builds only that one address.
    func terminalSocket(query: [URLQueryItem]) async throws -> any TerminalSocketing {
        if closed.value { throw GatewayFailure.connectionChanged }
        guard GatewayAddress.reachable(account.baseURL) else { throw GatewayFailure.tailscaleOff }
        let ticket = try await auth.mintTicket(timeout: .seconds(10))
        if closed.value { throw GatewayFailure.connectionChanged }
        guard let url = TerminalWire.socketURL(base: account.baseURL, query: query, ticket: ticket) else {
            throw GatewayFailure.invalidURL
        }
        let task = try transport.webSocketTask(with: URLRequest(url: url, timeoutInterval: 15))
        SocketStats.shared.track(task)           // [diagnostics]
        AppLog.trace("terminal", "terminal socket opened")
        return TerminalSocket(task)
    }

    /// After `shutdown()` / `endClient()`: every call fails with `connectionChanged`.
    var isShutDown: Bool { closed.value }

    /// The current state (the stream's latest value).
    var state: ConnectionState { stateHub.value }

    /// Why the last connection attempt failed (for "Can't reach your gateway" copy), nil once ready.
    var lastFailure: GatewayFailure? { failure.value }

    /// "Try again" from the UI: dial now, ladder reset.
    func reconnectNow() {
        guard !closed.value else { return }
        commands.yield(.reconnectNow)
    }

    /// Post-sign-in compatibility (spec 01 §4.3): authenticated `GET /api/status`, at most 4 s. Typed sign-ins only.
    func compatibility() async -> GatewayCompatibility {
        guard let data = try? await rest("GET", "/api/status", body: nil, timeout: 4),
              let status = try? JSONValue.parseFast(data) else { return .unknown }
        return GatewayCompatibility(status: status)
    }

    /// Ends the client without releasing its transport (a sign-out still sends `/auth/logout` with its cookies).
    @discardableResult func endClient() -> Bool {
        let first = closed.mutate { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return false }
        pathWatcher?.stop()
        commands.yield(.shutdown)
        commands.finish()
        let auth = self.auth
        Task { await auth.close() }
        return true
    }

    /// The transport (sign-out's logout uses the jar after the client ended).
    var httpTransport: HTTPTransport { transport }

    // MARK: Server requests [questions] (spec 1x §3.1; `ServerRequestAnswering` in HermesKit/Contracts+questions.swift)

    @discardableResult func respond(serverRequest id: String, result: JSONValue) async throws -> Int {
        if closed.value { throw RPCError.notSent(.connectionChanged) }
        return try await connection.sendAnswer(RPCFrame.response(id: id, result: result))
    }

    @discardableResult func fail(serverRequest id: String, code: Int, message: String) async throws -> Int {
        if closed.value { throw RPCError.notSent(.connectionChanged) }
        return try await connection.sendAnswer(RPCFrame.errorResponse(id: id, code: code, message: message))
    }

    var declinesNotShown: Bool { connection.declinesNotShown.value }

    #if DEBUG
    var debugConnection: GatewayConnection { connection }
    var debugAuth: GatewayAuth { auth }
    #endif
}

// MARK: - File transfers ([attachments] docs/spec/1x-attachments.md §13.1)

extension LiveGatewayClient: GatewayFileTransfers {
    func upload(_ path: String, query: [URLQueryItem], contentType: String, bodyFile: URL, timeout: TimeInterval,
                priority: Float, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> Data {
        if closed.value { throw GatewayFailure.connectionChanged }
        return try await GatewayTransfer.upload(auth: auth, transport: transport, base: account.baseURL, path: path, query: query,
                                                contentType: contentType, bodyFile: bodyFile, timeout: timeout, priority: priority,
                                                progress: progress)
    }

    func download(_ path: String, query: [URLQueryItem], to file: URL, ceiling: Int64, priority: Float,
                  progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> HTTPURLResponse {
        if closed.value { throw GatewayFailure.connectionChanged }
        return try await GatewayTransfer.download(auth: auth, transport: transport, base: account.baseURL, path: path, query: query,
                                                  to: file, ceiling: ceiling, priority: priority, progress: progress)
    }
}

// [onboarding] `GatewayCompatibility` lives in HermesKit/Net/GatewayCompatibility.swift.

/// The UIKit background task that keeps a socket alive through the 20 s grace.
@MainActor final class BackgroundTaskHolder {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    /// [mac-update] Every holder with a task, so a quit to install an update can end them all (`endAllForQuit`).
    private static let live = NSHashTable<BackgroundTaskHolder>.weakObjects()
    /// Set once the app is quitting for an update: no new grace begins.
    private(set) static var quitting = false

    nonisolated init() {}

    /// [mac-update] Owner 2026-11-10, after updating from Mac 927: "everything went away and I can't see what's going
    /// on ... I'm just supposed to sit here and stare at a screen". The Mac's quit puts the app in the background
    /// first, which began each socket's 20 s grace; UIKit then held the process (windows already gone) until the
    /// graces ran out: 26 s of nothing before Sparkle could install (the install and reopen took 0.4 s). The update
    /// ends them just before the quit.
    static func endAllForQuit() {
        quitting = true
        let holders = live.allObjects
        for holder in holders { holder.end() }
        if !holders.isEmpty { AppLog.note("mac", "updates: ended \(holders.count) socket grace task(s) before the quit") }
    }

    /// Begins (or keeps) the task; false when the system grants no background time.
    func begin(expired: @escaping @Sendable () -> Void) -> Bool {
        end()
        guard !Self.quitting else { return false }
        Self.live.add(self)
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Hermes HQ socket grace") { [weak self] in
            expired()
            MainActor.assumeIsolated { self?.end() }
        }
        return identifier != .invalid
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// NWPathMonitor, coalesced: a change is reported once the path stayed put for 2 s (spec 01 §13.7).
nonisolated final class PathWatcher: @unchecked Sendable { // State lives on `queue`.
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.hermes.hqnative.path")
    private let report: @Sendable (PathChange) -> Void
    private var settled: String?
    private var latest: String?
    private var pendingWork: DispatchWorkItem?

    init(report: @escaping @Sendable (PathChange) -> Void) { self.report = report }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let names = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map { "\($0.type)" }
            self?.updated(PathChange.signature(satisfied: path.status == .satisfied, interfaces: names))
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }

    /// On `queue`.
    private func updated(_ signature: String) {
        latest = signature
        guard settled != nil else { settled = signature; return }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.latest else { return }
            let change = PathChange.between(self.settled, current)
            self.settled = current
            if change != .none { self.report(change) }
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + PathChange.settleSeconds, execute: work)
    }
}
