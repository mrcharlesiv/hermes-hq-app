// The account's Bot Screen service (docs/spec/3x-screen.md §3.1, §5.1, §5.4): what is known about each bot's screen
// (for the row menu's label), the `display.status` / `display.lease` event pump, the open Screens (so sign-out can
// leave them), and the Mac health reader. One per signed-in account, like BrowserService.

import Foundation

@MainActor final class ScreenService {
    private struct Known {
        var status: ScreenStatus?
        var lease: ScreenLease?
        var viewer: ScreenViewer?
        var unavailable = false
    }

    private final class Open {
        weak var session: ScreenSession?
        init(_ session: ScreenSession) { self.session = session }
    }

    let client: any GatewayClient
    let holds: ScreenHolds
    let health: MacScreenHealthReader
    var timing = ScreenSession.Timing()
    /// The clock the eviction and failure windows read (tests move it by hand).
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private let dial: @Sendable (String, String) async throws -> any ScreenSocketing
    private var known: [String: Known] = [:] {
        didSet { NotificationCenter.default.post(name: Self.knownChanged, object: self) }
    }
    /// What is known about a bot's screen changed: Bot Info's Screen row, open under a Screen, reads it again.
    static let knownChanged = Notification.Name("ScreenService.knownChanged")
    /// Hermes names a screen in its events by `profile_key`, the profile's home PATH on the gateway (hermes_home_key),
    /// and a `display.lease` event carries nothing else. The menu asks by the bot's NAME, so every status that says
    /// both teaches this map which name a path belongs to.
    private var profileForKey: [String: String] = [:]
    private var open: [Open] = []
    private var pump: Task<Void, Never>?
    private var states: Task<Void, Never>?
    private var stopped = false

    var accountId: String { client.account.id }
    /// Whether the gateway still has a step's screenshot (one checker per account, §5.3).
    private(set) lazy var expiry = ScreenshotExpiry(client: client, profile: nil)

    init(client: any GatewayClient, holds: ScreenHolds = ScreenHolds(),
         dial: @escaping @Sendable (String, String) async throws -> any ScreenSocketing) {
        self.client = client
        self.holds = holds
        self.dial = dial
        health = MacScreenHealthReader(rest: client)
        let events = client.events(matching: ["display.status", "display.lease"]), connection = client.connectionStates()
        pump = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        states = Task { [weak self] in
            var last: ConnectionState?
            for await state in connection {
                defer { last = state }
                guard state == .ready, let earlier = last, earlier != .ready else { continue }
                self?.sessions.forEach { $0.gatewayReconnected() }
            }
        }
    }

    /// The live client's own display socket.
    convenience init?(client: any GatewayClient) {
        guard let sockets = client as? any GatewayDisplaySockets else { return nil }
        self.init(client: client) { path, ticket in try await sockets.displaySocket(path: path, ticket: ticket) }
    }

    private var sessions: [ScreenSession] {
        open.removeAll { $0.session == nil }
        return open.compactMap(\.session)
    }

    /// Whether a Screen is open right now (the viewer's own check; one at a time).
    var hasOpenSession: Bool { !sessions.isEmpty }

    // MARK: What the menu reads

    func tone(for profile: String) -> ScreenTone {
        guard let entry = known[profile] else { return .unknown }
        var status = entry.status
        if let lease = entry.lease { status?.lease = lease }
        return ScreenWire.tone(unavailable: entry.unavailable, status: status, viewer: entry.viewer)
    }

    /// The kind of Screen a bot has, by what is known, else by what its gateway gave last (§5.4).
    func kind(for profile: String) -> ScreenKind {
        let result = ScreenWire.kind(tone: tone(for: profile), remembered: holds.rememberedKind(accountId))
        if let remember = result.remember { holds.rememberKind(remember, accountId) }
        return result.kind
    }

    func status(for profile: String) -> ScreenStatus? { known[profile]?.status }

    // MARK: Sessions

    func session(profile: String, name: String) -> ScreenSession {
        let session = ScreenSession(profile: profile, name: name, environment: ScreenSession.Environment(
            client: client, dial: dial, holds: holds, health: health, accountId: accountId, timing: timing, now: now,
            cachedStatus: { [weak self] profile in
                guard let entry = self?.known[profile], !entry.unavailable, var status = entry.status else { return nil }
                if let lease = entry.lease { status.lease = lease }
                return status
            }))
        session.report = { [weak self] session in self?.note(session) }
        open.append(Open(session))
        return session
    }

    private func note(_ session: ScreenSession) {
        guard !stopped else { return }
        var entry = known[session.profile] ?? Known()
        if session.unavailable {
            entry = Known(unavailable: true)
        } else if let status = session.status {
            entry.status = status
            entry.lease = session.lease
            entry.viewer = session.viewer
            entry.unavailable = false
        }
        known[session.profile] = entry
        if let key = session.status?.profileKey, !key.isEmpty { profileForKey[key] = session.profile }    // the surest pairing
        if session.unavailable || session.status != nil { _ = kind(for: session.profile) }        // remembered for the gateway
    }

    /// The bot an event is about, by name. A pairing learned from an open Screen wins; then the status's own `profile`
    /// ("custom" is Hermes' word for a home it cannot name); then a home under `…/profiles/<name>`; then a key that is
    /// not a path at all (an older gateway). nil: nobody here can say whose screen it is, and the event is dropped.
    func profileName(for payload: JSONValue) -> String? {
        let key = payload["profile_key"]?.string ?? ""
        if let learned = profileForKey[key] { return learned }
        if let name = payload["profile"]?.string, !name.isEmpty, name != "custom" {
            if !key.isEmpty { profileForKey[key] = name }
            return name
        }
        guard !key.isEmpty else { return nil }
        guard key.contains("/") || key.contains("\\") else { return key }
        let parts = key.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if parts.count >= 2, parts[parts.count - 2] == "profiles" {
            let name = String(parts[parts.count - 1])
            profileForKey[key] = name
            return name
        }
        return nil
    }

    private func handle(_ event: GatewayEvent) {
        guard !stopped else { return }
        let name = profileName(for: event.payload)
        if let key = name {
            var entry = known[key] ?? Known()
            if event.type == "display.status", let status = ScreenStatus.parse(event.payload) {
                entry.status = status
                if let lease = status.lease, !lease.isOlder(than: entry.lease) { entry.lease = lease }
                entry.unavailable = false
                known[key] = entry
            } else if event.type == "display.lease", let lease = ScreenLease.parse(event.payload["lease"]), !lease.isOlder(than: entry.lease) {
                entry.lease = lease
                known[key] = entry
            }
            // A hold this phone saved is over once the gateway says the bot (or someone else) has control: a Screen
            // that was closed while in control leaves its hold saved until this word arrives.
            if let lease = known[key]?.lease, !sessions.contains(where: { $0.profile == key && !$0.left }) {
                holds.note(lease: lease, viewer: nil, account: accountId, profile: key)
            }
        }
        sessions.forEach { $0.handle(event, about: name) }
    }

    // MARK: Check setup (§5.13)

    private enum Read: Sendable {
        case health(Result<JSONValue?, Error>)
        case status(Result<JSONValue, Error>)
    }

    /// The plugin's health and the bot's status, read together, as the one line "Check setup" shows. Throws when the
    /// gateway cannot be reached (a missing plugin route is not a failure).
    func checkSetup(profile: String) async throws -> String {
        let client = self.client, health = self.health
        let (plugin, status) = await withChildTasks(of: Read.self) { children -> (Result<JSONValue?, Error>?, Result<JSONValue, Error>?) in
            children.addTask { .health(await Result { try await health.read() }) }
            children.addTask {
                .status(await Result { try await client.call("display.status", ScreenWire.profileParams(profile), timeout: ScreenWire.statusTimeout) })
            }
            var plugin: Result<JSONValue?, Error>?, status: Result<JSONValue, Error>?
            while let read = await children.next() {
                switch read {
                case .health(let result): plugin = result
                case .status(let result): status = result
                }
            }
            return (plugin, status)
        }
        guard let plugin, let status else { throw CancellationError() }
        let healthValue = try plugin.get()
        var parsed: ScreenStatus?
        switch status {
        case .success(let value): parsed = ScreenStatus.parse(value)
        case .failure(let error): if !ScreenWire.isUnavailable(error) { throw error }
        }
        return MacScreenReadiness.message(health: healthValue, status: parsed)
    }

    // MARK: Leaving

    /// Sign-out and gateway switch call this first, while the client can still ask: every open Screen leaves, and one
    /// that holds control waits for the gateway's word that the bot has it back (in all at most `limit`). A hold
    /// whose hand-back was not confirmed stays saved for the next launch. Returns at once when no Screen is open.
    func handBackBeforeLeaving(limit: Duration = .seconds(2)) async {
        let leaving = sessions.filter { !$0.left }
        guard !leaving.isEmpty else { return }
        let work = Task { @MainActor in
            for session in leaving { await session.leaveConfirming() }       // one Screen is open at a time
        }
        let clock = Task {
            try? await Task.sleep(for: limit)
            work.cancel()
        }
        await work.value
        clock.cancel()
    }

    /// Sign-out and account switch: every open Screen leaves by the rules of §5.8, and nothing more is read.
    func shutdown() {
        guard !stopped else { return }
        stopped = true
        sessions.forEach { $0.leave() }
        open = []
        pump?.cancel()
        states?.cancel()
    }
}

nonisolated extension Result where Failure == Error {
    /// `Result { try await … }`.
    init(_ work: @Sendable () async throws -> Success) async {
        do { self = .success(try await work()) } catch { self = .failure(error) }
    }
}
