// A gateway's display side for ScreenSession tests: the lease rules of Hermes (ids minted per /api/ws connection,
// holder named by hash, epochs, 5300 refusals, force release), scripted failures, and display sockets the test ends
// by hand. The stand-in gateway (scripts/fixtures/screen-gateway.py) is the same model over real sockets.

import Foundation
import Synchronization
@testable import HermesHQNative

nonisolated final class FakeDisplay: Sendable {
    struct State: Sendable {
        var supported = true
        var installed = true
        var running = true
        var display = "This Mac"
        var geometry = "64x48"
        var blocker: String?
        var installCommand: String?
        var holder = "agent"
        var hash: String?
        var epoch = 1
        var connection = 1
        var minted: [String: Int] = [:]
        var tickets: [String: String] = [:]
        var counter = 0
        var fail: [String: RPCError] = [:]
        var hang: Set<String> = []
        var delay: [String: Duration] = [:]
        var dialFails = false
        var pictures = true
        var sockets: [FakeScreenSocket] = []
        var socketViewers: [String] = []
        /// Runs once inside the next call of that method, before it answers (to change the world mid-flight).
        var before: [String: @Sendable (inout State) -> Void] = [:]
    }

    let client = FakeGatewayClient()
    let state = Mutex(State())

    init() {
        client.onCall { [weak self] method, params in
            guard let self else { return .object([:]) }
            return try await self.answer(method, params)
        }
    }

    func set(_ change: @Sendable (inout State) -> Void) { state.withLock { change(&$0) } }
    var sockets: [FakeScreenSocket] { state.withLock { $0.sockets } }
    var lease: (holder: String, hash: String?, epoch: Int) { state.withLock { ($0.holder, $0.hash, $0.epoch) } }
    func calls(_ method: String) -> [FakeGatewayClient.Call] { client.calls(method) }
    var methods: [String] { client.calls.map(\.method) }

    /// Another person takes control: the lease changes, the holder's socket is evicted with 4000, the event goes out.
    func otherTakes() {
        let (evicted, payload) = state.withLock { s -> (FakeScreenSocket?, JSONValue) in
            let previous = s.hash
            s.holder = "human"
            s.hash = ScreenWire.viewerHash("someone-else-\(s.epoch)")
            s.epoch += 1
            var socket: FakeScreenSocket?
            if let previous, let index = s.socketViewers.lastIndex(where: { ScreenWire.viewerHash($0) == previous }) { socket = s.sockets[index] }
            return (socket, ["profile_key": .string(Self.homeKey), "lease": Self.leaseJSON(s)])
        }
        evicted?.end(code: 4000, reason: "control-taken")
        client.emit(GatewayEvent(type: "display.lease", sessionId: "", seq: nil, payload: payload))
    }

    /// The bot takes control back by itself.
    func agentTakes() {
        let payload = state.withLock { s -> JSONValue in
            s.holder = "agent"
            s.hash = nil
            s.epoch += 1
            return ["profile_key": .string(Self.homeKey), "lease": Self.leaseJSON(s)]
        }
        client.emit(GatewayEvent(type: "display.lease", sessionId: "", seq: nil, payload: payload))
    }

    func emitStatus() {
        let payload = state.withLock { Self.statusJSON($0) }
        client.emit(GatewayEvent(type: "display.status", sessionId: "", seq: nil, payload: payload))
    }

    /// The app's /api/ws drops and comes back as a new connection.
    func reconnectGateway() {
        client.setConnection(.reconnecting(attempt: 1))
        state.withLock { $0.connection += 1 }
        client.setConnection(.ready)
    }

    // MARK: The display socket

    func dial(_ path: String, _ ticket: String) throws -> any ScreenSocketing {
        let made = try state.withLock { s -> (FakeScreenSocket, Bool, (Int, Int)) in
            guard !s.dialFails, path == ScreenWire.displayPath, let viewer = s.tickets.removeValue(forKey: ticket) else {
                throw URLError(.cannotConnectToHost)
            }
            let socket = FakeScreenSocket()
            s.sockets.append(socket)
            s.socketViewers.append(viewer)
            return (socket, s.pictures, ScreenWire.size(s.geometry) ?? (64, 48))
        }
        if made.1 { Self.picture(made.0, made.2.0, made.2.1) }
        return made.0
    }

    /// The handshake and one whole picture.
    static func picture(_ socket: FakeScreenSocket, _ width: Int, _ height: Int) {
        socket.push(RFBBuild.preamble(width: width, height: height))
        socket.push(RFBBuild.update([RFBBuild.raw(0, 0, width, height, b: 40, g: 80, r: 120)]))
    }

    // MARK: The calls

    /// As Hermes sends it: the profile's home path (hermes_home_key), never its name.
    static let homeKey = "/fixture/home"

    private static func leaseJSON(_ s: State) -> JSONValue {
        ["holder": .string(s.holder), "viewer_id": .null, "viewer_hash": s.hash.map(JSONValue.string) ?? .null,
         "since": 1_791_700_000, "epoch": .number(Double(s.epoch)), "reason": ""]
    }

    private static func statusJSON(_ s: State) -> JSONValue {
        ["profile": "default", "profile_key": .string(homeKey), "supported": .bool(s.supported), "installed": .bool(s.installed), "missing": .array([]),
         "running": .bool(s.running), "display": .string(s.display), "geometry": .string(s.geometry),
         "install_command": s.installCommand.map(JSONValue.string) ?? .null, "blocker": s.blocker.map(JSONValue.string) ?? .null,
         "placement": "gateway", "lease": leaseJSON(s)]
    }

    private func answer(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let (hang, delay) = state.withLock { ($0.hang.contains(method), $0.delay[method]) }
        if hang { try await Task.sleep(for: .seconds(600)) }
        if let delay { try await Task.sleep(for: delay) }
        return try state.withLock { s -> JSONValue in
            if let hook = s.before.removeValue(forKey: method) { hook(&s) }
            if let error = s.fail[method] { throw error }
            let viewer = params["viewer_id"]?.string
            switch method {
            case "display.status":
                return Self.statusJSON(s)
            case "display.start":
                s.running = true
                return Self.statusJSON(s)
            case "display.observe":
                guard s.running else { throw RPCError(code: 5300, message: "this profile's Bot Desktop is not running; call display.start first", data: nil) }
                var id = viewer
                if id == nil || s.minted[id ?? ""] != s.connection {
                    s.counter += 1
                    id = "viewer-\(s.counter)-\(UUID().uuidString.prefix(8))"       // opaque and never reused, as Hermes mints them
                    s.minted[id ?? ""] = s.connection
                }
                s.counter += 1
                let ticket = "ticket-\(s.counter)"
                s.tickets[ticket] = id
                guard case .object(var out) = Self.statusJSON(s) else { return .null }
                out["ticket"] = .string(ticket)
                out["path"] = .string(ScreenWire.displayPath)
                out["viewer_id"] = .string(id ?? "")
                return .object(out)
            case "display.lease.acquire":
                guard let viewer else { throw RPCError(code: 5300, message: "viewer_id required", data: nil) }
                guard s.minted[viewer] == s.connection else {
                    throw RPCError(code: 5300, message: "viewer_id was not minted for this connection; call display.observe first", data: ["code": "viewer_mismatch"])
                }
                s.holder = "human"
                s.hash = ScreenWire.viewerHash(viewer)
                s.epoch += 1
                return ["lease": Self.leaseJSON(s)]
            case "display.lease.release":
                let force = params["force"]?.bool == true
                if let viewer {
                    if force {
                        // Released only while that id still holds: someone who took control meanwhile keeps it.
                        if s.holder == "human", s.hash == ScreenWire.viewerHash(viewer) {
                            s.holder = "agent"
                            s.hash = nil
                            s.epoch += 1
                        }
                    } else {
                        guard s.minted[viewer] == s.connection, s.holder == "human", s.hash == ScreenWire.viewerHash(viewer) else {
                            throw RPCError(code: 5300, message: "another viewer holds control", data: ["code": "viewer_mismatch"])
                        }
                        s.holder = "agent"
                        s.hash = nil
                        s.epoch += 1
                    }
                } else if force {
                    s.holder = "agent"
                    s.hash = nil
                    s.epoch += 1
                } else if s.holder == "human" {
                    throw RPCError(code: 5300, message: "a person holds control", data: ["code": "viewer_mismatch"])
                }
                return ["lease": Self.leaseJSON(s)]
            default:
                throw RPCError(code: -32601, message: "Method not found", data: nil)
            }
        }
    }
}

/// A session wired to a `FakeDisplay`, with what it told its view.
@MainActor final class SessionRig {
    let display = FakeDisplay()
    let clock = FakeUptime()
    let defaults: UserDefaults
    let holds: ScreenHolds
    let service: ScreenService
    private(set) var session: ScreenSession
    private(set) var notices: [ScreenSession.Notice] = []
    private(set) var frames = 0
    private(set) var phases: [ScreenSession.Phase] = []

    init(timing: ScreenSession.Timing? = nil, defaults: UserDefaults? = nil) {
        let name = "screen-session-\(UUID().uuidString)"
        let store = defaults ?? UserDefaults(suiteName: name)!
        if defaults == nil { store.removePersistentDomain(forName: name) }
        self.defaults = store
        holds = ScreenHolds(defaults: store)
        let display = self.display
        display.client.onRest { _, _ in Data(SessionRig.healthy.utf8) }
        service = ScreenService(client: display.client, holds: holds) { path, ticket in try display.dial(path, ticket) }
        var fast = ScreenSession.Timing()
        fast.statusWait = .milliseconds(300)
        fast.pauseDelay = .milliseconds(150)
        fast.retryDelay = .milliseconds(40)
        fast.healthEvery = .milliseconds(250)
        service.timing = timing ?? fast
        let clock = self.clock
        service.now = { clock.now }
        session = service.session(profile: "default", name: "Hermes")
        wire()
    }

    /// A second Screen on the same service (after Close, or another bot).
    func reopen(profile: String = "default") {
        session = service.session(profile: profile, name: "Hermes")
        notices = []
        phases = []
        wire()
    }

    private func wire() {
        session.onNotice = { [weak self] in self?.notices.append($0) }
        session.onFrame = { [weak self] _, _, _ in self?.frames += 1 }
        session.onChange = { [weak self] in
            guard let self else { return }
            if self.phases.last != self.session.phase { self.phases.append(self.session.phase) }
        }
    }

    /// A Mac whose helper is set up: viewing and control ready.
    nonisolated static let healthy = #"{"installed":true,"ok":true,"platform":"darwin","drift":[],"enabled":true,"control":true,"helper":{"ok":true,"tcc":{"screen":true,"events":true}}}"#

    var socket: FakeScreenSocket? { display.sockets.last }
    var account: String { display.client.account.id }

    func live(_ seconds: Double = 5) async -> Bool { await screenWait(seconds) { self.session.phase == .live } }

    /// Opens and waits for the picture.
    func openLive() async -> Bool {
        session.open()
        return await live()
    }

    func takeOver() async -> Bool {
        guard await screenWait(5, { self.session.canTake }) else { return false }
        session.takeOver()
        return await screenWait { self.session.holding && self.session.busy == nil }
    }

    /// Pointer and key messages a socket received, as readable tuples.
    static func inputs(_ socket: FakeScreenSocket?) -> [String] {
        (socket?.inputs ?? []).map { data in
            let b = [UInt8](data)
            switch b.first {
            case 5 where b.count == 6: return "pointer \(b[1]) \(Int(b[2]) << 8 | Int(b[3])),\(Int(b[4]) << 8 | Int(b[5]))"
            case 4 where b.count == 8: return "key \(String(UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7]), radix: 16)) \(b[1] == 1 ? "down" : "up")"
            case 6: return "cut \(b.count - 8)"
            default: return "other"
            }
        }
    }
}
