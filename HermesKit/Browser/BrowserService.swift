// Watch Browser's connection to the gateway's browser plugin (hermes-hq-browser, or dispatch-browser under its old
// name): plugin discovery, the activity list (one socket per account, shared by the chat card, Bots and the viewer),
// the bot's own-Chrome status and the per-bot browser choice (plugin 3.6+). Ported from the web app's
// src/browser-watch/activity-channel.ts and activity-runtime.ts.

import Foundation
import Synchronization
import UIKit

/// A client that can open a gateway plugin's websocket (a fresh ticket each). `LiveGatewayClient` adopts it.
nonisolated protocol GatewayPluginSockets: AnyObject, Sendable {
    func pluginSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask
}

/// One plugin websocket: a receive loop off the main thread that parses each text message with `parse` and hands the
/// results on in order; the close (with its code) ends the stream.
nonisolated final class BrowserSocket<Message: Sendable>: Sendable {
    enum Event: Sendable {
        case message(Message)
        case closed(code: Int)
    }

    let events: AsyncStream<Event>
    private let task: URLSessionWebSocketTask
    private let loop: Task<Void, Never>

    init(task: URLSessionWebSocketTask, parse: @escaping @Sendable (Data) -> Message?) {
        self.task = task
        let (stream, sink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        events = stream
        task.resume()
        loop = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                do {
                    let data: Data
                    switch try await task.receive() {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    if let message = parse(data) { sink.yield(.message(message)) }
                } catch {
                    sink.yield(.closed(code: task.closeCode.rawValue))
                    break
                }
            }
            sink.finish()
        }
    }

    func send(_ data: Data) {
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func close(_ code: Int = 1000) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        loop.cancel()
    }

    /// Sends a last message, then closes once it has gone out, or after `limit` seconds. Audit 14-7: a close in the
    /// same instant as a send may drop what was queued (a Give Back lost leaves the bot waiting out its 2-minute hold).
    /// The socket keeps itself until then (its deinit would close it at once).
    func close(after data: Data, limit: Double = 2) {
        let once = BrowserCloseOnce()
        let finish: @Sendable () -> Void = { [self] in
            guard once.first() else { return }
            close()
        }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in finish() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) { finish() }
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
        loop.cancel()
    }
}

/// `BrowserSocket.close(after:)`'s one close, whichever comes first: the send's completion or the clock.
nonisolated final class BrowserCloseOnce: Sendable {
    private let done = Mutex(false)
    func first() -> Bool { done.withLock { done in defer { done = true }; return !done } }
}

/// The browser plugin of one gateway account.
@MainActor final class BrowserService {
    struct Plugin: Sendable {
        var base: String
        var health: JSONValue
        var legacy: Bool
        var setup: BrowserSetup { BrowserHealth.setup(health) }
    }

    let rest: any GatewayClient
    let sockets: any GatewayPluginSockets
    /// The plugin name that answered last (a Mac still on the old name isn't asked the new one, a 404, every time).
    private var base = BrowserWire.plugin
    private var ready: (plugin: Plugin, at: Date)?
    static let healthReuse: TimeInterval = 5 * 60
    private(set) lazy var activity = BrowserActivityChannel(service: self)

    init(rest: any GatewayClient, sockets: any GatewayPluginSockets) {
        self.rest = rest
        self.sockets = sockets
    }

    /// Signed out or switched gateway: an open viewer stops dialling.
    private(set) var isShutDown = false

    /// Open viewers' sessions (weak): a sign-out gives a held browser back and ends them.
    private let watchers = NSHashTable<BrowserWatchSession>.weakObjects()

    func register(_ session: BrowserWatchSession) { watchers.add(session) }

    func shutdown() {
        isShutDown = true
        for session in watchers.allObjects { session.shutDown() }
        watchers.removeAllObjects()
        activity.shutdown()
        ready = nil
    }

    /// [presence] The gateway link is back (spec 3x-presence §11): sockets waiting out a back-off dial now.
    func linkRestored() {
        guard !isShutDown else { return }
        for session in watchers.allObjects { session.linkRestored() }
        activity.linkRestored()
    }

    #if DEBUG
    var debugWatcherCount: Int { watchers.allObjects.count }
    #endif

    /// The plugin on this gateway: hermes-hq-browser, else dispatch-browser. A ready answer is reused for 5 minutes.
    /// Throws `HTTPError` 404 when neither name answers (a setup step), anything else for a connection problem.
    func plugin(fresh: Bool = false, timeout: TimeInterval = 8) async throws -> Plugin {
        if !fresh, let ready, Date().timeIntervalSince(ready.at) < Self.healthReuse { return ready.plugin }
        let first = base
        for candidate in [first, first == BrowserWire.plugin ? BrowserWire.legacyPlugin : BrowserWire.plugin] {
            do {
                let health = try await json("GET", candidate + "/health", timeout: timeout)
                base = candidate
                let found = Plugin(base: candidate, health: health, legacy: candidate == BrowserWire.legacyPlugin)
                ready = found.setup == .ready ? (found, Date()) : nil
                return found
            } catch let error as HTTPError where error.status == 404 {
                if candidate == first { continue }
                // Neither name answers: a ready answer still cached is stale, so the next open reads /health again.
                ready = nil
                throw error
            }
        }
        ready = nil
        throw HTTPError(status: 404, body: nil)
    }

    /// The ready answer still within its 5 minutes, without asking (nil when there is none): a viewer opens on it at once.
    var cachedPlugin: Plugin? {
        guard let ready, Date().timeIntervalSince(ready.at) < Self.healthReuse else { return nil }
        return ready.plugin
    }

    func forgetPlugin() { ready = nil }

    static func isMissing(_ error: Error) -> Bool { (error as? HTTPError)?.status == 404 }

    func json(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil,
              timeout: TimeInterval = 8) async throws -> JSONValue {
        let data: Data
        if timeout > 120, let transfers = rest as? GatewayTransfers {
            // A profile copy can take minutes on a big profile: the transfer lane allows up to 600 s.
            data = try await transfers.transfer(method, path, query: query, body: try body?.encoded(),
                                                contentType: "application/json", timeout: timeout)
        } else if let live = rest as? LiveGatewayClient {
            data = try await live.rest(method, path, query: query, body: try body?.encoded(), timeout: timeout)
        } else {
            data = try await rest.rest(method, path, query: query, body: try body?.encoded())
        }
        return try JSONValue.parse(data)
    }

    /// The bot's own Chrome (`/bots`): nil from an older plugin (no route).
    func ownBrowser(profile: String) async throws -> OwnBrowser? {
        let found = try await plugin()
        do {
            return OwnBrowser.parse(try await json("GET", found.base + "/bots"), profile: profile)
        } catch where Self.isMissing(error) {
            return nil
        }
    }

    // MARK: The per-bot choice (plugin 3.6+, docs/browser-choice-decision.md)

    /// nil when the plugin doesn't offer it (the phone hides the choice).
    func choice(profile: String) async throws -> BrowserChoice? {
        let found = try await plugin()
        guard found.setup == .ready, BrowserHealth.offersChoice(found.health) else { return nil }
        return BrowserChoice.parse(try await json("GET", found.base + "/choice", query: [URLQueryItem(name: "profile", value: profile)]))
    }

    func chromeProfiles() async throws -> ChromeProfiles {
        let found = try await plugin()
        return ChromeProfiles.parse(try await json("GET", found.base + "/chrome-profiles"))
    }

    /// A profile copy takes a while on a big profile (the plugin copies outside the bot's lock): up to ten minutes.
    func setChoice(profile: String, change: BrowserChoice.Change) async throws -> BrowserChoice {
        let found = try await plugin()
        var body: [String: JSONValue] = ["profile": .string(profile)]
        switch change {
        case .own: body["mode"] = "own"
        case .copy(let source): body["mode"] = "copy"; body["source"] = .string(source)
        case .refresh: body["refresh"] = true
        case .window(let normal): body["window"] = normal ? "normal" : "hidden"
        case .takeOver: body["take_over"] = true
        }
        let answer = try await json("POST", found.base + "/choice", body: .object(body), timeout: 600)
        guard let choice = BrowserChoice.parse(answer) else { throw GatewayFailure.notHermes }
        return choice
    }
}

/// A bot's browser choice as the plugin reports it.
nonisolated struct BrowserChoice: Sendable, Equatable {
    var profile: String
    var copy: ChromeProfile?
    var copiedAt: Date?
    var normalWindow: Bool
    var changeable: Bool
    /// Why the plugin doesn't run this bot's browser (3.6.2+): `real_profile`, `released`, `external`, `fixed`,
    /// `remote`, `camofox`, `off`, `no_browser`, `starting`. nil when it does, or from an older plugin.
    var blocked: String? = nil
    /// The plugin can safely take this bot's browser over (`POST /choice {take_over: true}`, 3.6.2+).
    var canTakeOver = false

    enum Change: Sendable, Equatable {
        case own
        case copy(String)
        case refresh
        case window(normal: Bool)
        /// Hand a browser the plugin doesn't run to it (only when `canTakeOver`).
        case takeOver
    }

    static func parse(_ value: JSONValue) -> BrowserChoice? {
        guard value["schema"]?.string == "hermes-hq-browser.choice.v1", let profile = value["profile"]?.string else { return nil }
        let source = value["mode"]?.string == "copy" ? value["source"].flatMap(ChromeProfile.parse) : nil
        return BrowserChoice(profile: profile, copy: source,
                             copiedAt: value["copied_at"]?.double.map { Date(timeIntervalSince1970: $0) },
                             normalWindow: value["window"]?.string == "normal", changeable: value["changeable"]?.bool ?? false,
                             blocked: value["blocked"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) },
                             canTakeOver: value["can_take_over"]?.bool ?? false)
    }
}

nonisolated struct ChromeProfile: Sendable, Equatable, Identifiable {
    var dir: String
    var name: String
    var account: String?
    var id: String { dir }

    static func parse(_ value: JSONValue) -> ChromeProfile? {
        guard let dir = value["dir"]?.string, !dir.isEmpty else { return nil }
        return ChromeProfile(dir: dir, name: value["name"]?.string ?? dir, account: value["account"]?.string)
    }
}

nonisolated struct ChromeProfiles: Sendable, Equatable {
    var supported: Bool
    var browser: String?
    var profiles: [ChromeProfile]
    var reason: String?
    /// `no_access`: the program on the computer that needs Full Disk Access (the plugin's Python), shown so it can be added.
    var program: String?

    static func parse(_ value: JSONValue) -> ChromeProfiles {
        ChromeProfiles(supported: value["supported"]?.bool == true, browser: value["browser"]?.string,
                       profiles: (value["profiles"]?.array ?? []).compactMap(ChromeProfile.parse), reason: value["reason"]?.string,
                       program: value["python"]?.string.map { String($0.prefix(300)) })
    }
}

/// One foreground activity connection shared by its consumers (the chat card, Bots rows, the viewer). It carries the
/// browser list only, never page images. When its last consumer leaves, the socket closes 3 s later unless one comes
/// back; the last list stays (marked disconnected) for 3 minutes, so a chat's card keeps its place across an app switch.
@MainActor final class BrowserActivityChannel {
    private(set) var rows: [BrowserRow] = []
    private(set) var connected = false
    static let linger: Duration = .seconds(3)
    static let retain: TimeInterval = 3 * 60
    /// The plugin pings after 20 s with no list change, timed from its last ping: a socket quiet for this long is
    /// half-open (a network change in the foreground) and is dialled again. Tests shorten it.
    static var silence: Duration = .seconds(45)
    static var watchEvery: Duration = .seconds(5)
    /// A main-link restore replaces a socket quiet for this long at once, without waiting for the watchdog.
    static var quietOnRestore: Duration = .seconds(25)

    /// [presence] Told whenever the listeners are (rows or the link changed) without being a listener itself: it
    /// never opens the socket (`PresenceCenter`'s ask notice, DECISION D40 in docs/spec/3x-presence.md).
    var onRowsChanged: (() -> Void)?

    private weak var service: BrowserService?
    private var listeners: [UUID: () -> Void] = [:]
    private var generation = 0
    private var socket: BrowserSocket<JSONValue>?
    private var work: Task<Void, Never>?
    private var lingering: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastInbound = ContinuousClock.now
    private var attempt = 0
    private var retainedAt: Date?
    private var foreground = UIApplication.shared.applicationState != .background
    private var observers: [NSObjectProtocol] = []
    private var isShutDown = false

    init(service: BrowserService) {
        self.service = service
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(false) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(true) }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Starts listening (the socket opens with the first listener); the token's `cancel()` stops.
    func subscribe(_ listener: @escaping () -> Void) -> BrowserSubscription {
        let id = UUID()
        listeners[id] = listener
        if listeners.count == 1 {
            if let lingering {
                lingering.cancel(); self.lingering = nil
                // [presence] A back-off that ran out while nobody listened left no socket and nothing scheduled: dial
                // (a no-op while the socket, or a dial, is still there).
                if socket == nil, work == nil { retry?.cancel(); retry = nil; begin() }
            } else { begin() }
        }
        return BrowserSubscription { [weak self] in self?.unsubscribe(id) }
    }

    private func unsubscribe(_ id: UUID) {
        guard listeners.removeValue(forKey: id) != nil, listeners.isEmpty else { return }
        lingering?.cancel()
        lingering = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled, let self, self.listeners.isEmpty else { return }
            self.lingering = nil
            self.close()
        }
    }

    private func begin() {
        guard !isShutDown, foreground, socket == nil, work == nil else { return }
        if let retainedAt, Date().timeIntervalSince(retainedAt) > Self.retain { rows = [] }
        retainedAt = nil
        connect()
    }

    private func setForeground(_ on: Bool) {
        foreground = on
        if on { if !listeners.isEmpty { begin() } } else { close() }
    }

    func shutdown() {
        isShutDown = true
        lingering?.cancel()
        close()
        listeners = [:]
        rows = []
    }

    /// Ends the socket; the list stays, marked disconnected.
    private func close() {
        generation += 1
        retry?.cancel(); retry = nil
        watchdog?.cancel(); watchdog = nil
        work?.cancel(); work = nil
        socket?.close(); socket = nil
        if !rows.isEmpty { retainedAt = Date() }
        attempt = 0
        if connected { connected = false; publish() }
    }

    private func publish() {
        for listener in listeners.values { listener() }
        onRowsChanged?()
    }

    private func connect() {
        generation += 1
        let mine = generation
        work = Task { [weak self] in
            guard let self else { return }
            do {
                guard let service = self.service else { return }
                let plugin = try await service.plugin(timeout: 4)
                guard mine == self.generation else { return }
                // A gateway without the plugin stays quiet until the next subscribe.
                guard plugin.setup == .ready else { self.work = nil; return }
                let task = try await service.sockets.pluginSocket(path: plugin.base + "/activity", query: [])
                guard mine == self.generation else { task.cancel(with: .normalClosure, reason: nil); return }
                let socket = BrowserSocket<JSONValue>(task: task) { data in
                    data.count <= 256_000 ? try? JSONValue.parse(data) : nil
                }
                self.socket = socket
                self.lastInbound = .now
                self.startWatchdog(mine)
                AppLog.note("browser", "activity socket open")
                for await event in socket.events {
                    guard mine == self.generation else { return }
                    switch event {
                    case .message(let value):
                        self.lastInbound = .now   // a ping counts: it says the socket is alive
                        if let rows = BrowserRow.parseList(value) {
                            self.attempt = 0
                            self.rows = rows
                            self.connected = true
                            self.publish()
                        }
                    case .closed:
                        break
                    }
                }
                guard mine == self.generation else { return }
                self.lost()
            } catch {
                guard mine == self.generation else { return }
                if BrowserService.isMissing(error) { self.work = nil; return }
                // Only an answer from the plugin itself says the cached one is wrong. A transport failure (the network
                // not ready on return from the background, a ticket timeout) keeps it, so the retry skips /health.
                if let http = error as? HTTPError, http.status == 405 || http.status >= 500 { self.service?.forgetPlugin() }
                AppLog.swallowed("browser", "open the activity socket", error)
                self.lost()
            }
        }
    }

    /// A socket that says nothing is half-open: closing it ends the loop, which then reconnects as for any drop.
    private func startWatchdog(_ mine: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchEvery)
                guard let self, mine == self.generation, !Task.isCancelled, let socket = self.socket else { return }
                if ContinuousClock.now - self.lastInbound > Self.silence {
                    AppLog.note("browser", "activity socket silent: redialing")
                    socket.close()
                    return
                }
            }
        }
    }

    /// The socket dropped: the last list stays while it reconnects (a status blip must not tear down a takeover).
    private func lost() {
        watchdog?.cancel(); watchdog = nil
        socket?.close(); socket = nil
        work = nil
        if connected { connected = false; publish() }
        let wait = min(10, pow(2, Double(attempt)))
        attempt += 1
        let mine = generation
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, mine == self.generation, !self.listeners.isEmpty, self.foreground else { return }
            self.retry = nil
            self.connect()
        }
    }

    /// [presence] The gateway link is back (spec 3x-presence §11, DECISION D14): a list socket waiting out its back-off
    /// dials now; one that went quiet because the plugin was missing looks once more (so the Bots rows' lines appear
    /// after the main bot installs the plugin and restarts Hermes). A live socket, or a dial in flight, is left alone.
    func linkRestored() {
        guard !isShutDown, foreground, !listeners.isEmpty else { return }
        // A socket that has been quiet across a network change is likely half-open: replace it now (its loop ends and
        // reconnects).
        if let socket, ContinuousClock.now - lastInbound > Self.quietOnRestore {
            AppLog.note("browser", "activity link restored: quiet socket replaced")
            socket.close()
            return
        }
        guard socket == nil, work == nil else { return }
        if retry != nil {
            retry?.cancel(); retry = nil
            attempt = 0
            AppLog.note("browser", "activity link restored: dialing now")
            connect()
        } else {
            service?.forgetPlugin()
            begin()
        }
    }

    #if DEBUG
    /// [presence] Tests: its back-off step, whether it waits to retry, whether a dial or a socket is there.
    var debugAttempt: Int { attempt }
    var debugRetrying: Bool { retry != nil }
    var debugDialing: Bool { work != nil }
    var debugOpen: Bool { socket != nil }
    var debugListeners: Int { listeners.count }
    /// Tests: a list as if the socket had sent it.
    func debugPublish(_ rows: [BrowserRow], connected: Bool = true) {
        self.rows = rows
        self.connected = connected
        publish()
    }
    #endif
}

/// Cancels a listener (also on deinit).
final class BrowserSubscription {
    private var cancelAction: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
    func cancel() { cancelAction?(); cancelAction = nil }
    isolated deinit { cancelAction?() }
}
