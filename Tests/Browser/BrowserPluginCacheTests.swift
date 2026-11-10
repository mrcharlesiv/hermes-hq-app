// The browser plugin's cached /health answer (the viewer opens on it, a transport failure keeps it) and the activity
// socket's silence watchdog. Sockets that open go to a WebSocket server on 127.0.0.1 in this process.

import Foundation
import Network
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

nonisolated private let cacheReadyHealth: JSONValue = ["installed": true, "protocol": 3, "features": ["control": true, "watch": true]]

/// Dials that fail with `error` each time (counted).
nonisolated private final class FailingSockets: GatewayPluginSockets, @unchecked Sendable {
    private let dialled = Mutex(0)
    private let error: any Error & Sendable
    init(_ error: any Error & Sendable) { self.error = error }
    var count: Int { dialled.withLock { $0 } }
    func pluginSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
        dialled.withLock { $0 += 1 }
        throw error
    }
}

/// A WebSocket server on 127.0.0.1 that accepts every socket and says nothing, or pings every `pingEvery`.
nonisolated private final class QuietServer: GatewayPluginSockets, @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hqn.tests.quiet-server")
    private let connections = Mutex<[NWConnection]>([])
    private let dialled = Mutex(0)
    private let port = Mutex<UInt16>(0)
    private let pingEvery: DispatchTimeInterval?

    init(pingEvery: DispatchTimeInterval? = nil) throws {
        let parameters = NWParameters.tcp
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.pingEvery = pingEvery
    }

    var dials: Int { dialled.withLock { $0 } }
    var accepted: Int { connections.withLock { $0.count } }

    func start() async throws {
        let once = Mutex(false)
        let found: UInt16 = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                let first = once.withLock { done -> Bool in
                    guard !done else { return false }
                    switch state { case .ready, .failed, .cancelled: done = true; return true; default: return false }
                }
                guard first else { return }
                switch state {
                case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                default: continuation.resume(throwing: CancellationError())
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        port.withLock { $0 = found }
    }

    func stop() {
        listener.cancel()
        for connection in connections.withLock({ $0 }) { connection.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        connections.withLock { $0.append(connection) }
        connection.start(queue: queue)
        receive(connection)
        if let pingEvery { ping(connection, every: pingEvery) }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, error in
            if error == nil { self?.receive(connection) }
        }
    }

    private func ping(_ connection: NWConnection, every: DispatchTimeInterval) {
        queue.asyncAfter(deadline: .now() + every) { [weak self] in
            guard let self else { return }
            switch connection.state {
            case .cancelled, .failed: return
            case .ready:
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
                connection.send(content: Data(#"{"type":"ping"}"#.utf8), contentContext: context, isComplete: true, completion: .idempotent)
            default: break
            }
            self.ping(connection, every: every)
        }
    }

    func pluginSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
        dialled.withLock { $0 += 1 }
        let port = port.withLock { $0 }
        return URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)\(path)")!)
    }
}

@MainActor @Suite(.serialized) struct BrowserPluginCacheTests {
    private func service(sockets: any GatewayPluginSockets) -> (BrowserService, BotsFakeGatewayClient) {
        let client = BotsFakeGatewayClient()
        client.onREST { _, path, _, _ in
            guard path.hasSuffix("/health") else { throw HTTPError(status: 404, body: nil) }
            return try cacheReadyHealth.encoded()
        }
        return (BrowserService(rest: client, sockets: sockets), client)
    }

    private func healthCalls(_ client: BotsFakeGatewayClient) -> Int { client.restCalls.filter { $0.path.hasSuffix("/health") }.count }

    // MARK: The cached answer

    @Test func theCachedPluginIsAReadyAnswerUntilForgottenOrShutDown() async throws {
        let (service, client) = service(sockets: CountingSockets())
        #expect(service.cachedPlugin == nil)
        _ = try await service.plugin()
        #expect(service.cachedPlugin?.base == BrowserWire.plugin)
        service.forgetPlugin()
        #expect(service.cachedPlugin == nil)

        client.onREST { _, _, _, _ in try (["installed": true, "protocol": 1] as JSONValue).encoded() }
        _ = try await service.plugin()
        #expect(service.cachedPlugin == nil, "an update answer is never kept")

        client.onREST { _, _, _, _ in try cacheReadyHealth.encoded() }
        _ = try await service.plugin()
        #expect(service.cachedPlugin != nil)
        service.shutdown()
        #expect(service.cachedPlugin == nil)
    }

    private func viewer(_ service: BrowserService) -> BrowserViewerController {
        let viewer = BrowserViewerController(service: service, scope: BrowserScope(profile: "wren", title: "Wren"))
        viewer.loadViewIfNeeded()
        return viewer
    }

    @Test func aViewerOpensReadyOnTheCachedPluginBeforeItsRecheckAnswers() async throws {
        let (service, client) = service(sockets: CountingSockets(hang: true))
        _ = try await service.plugin()
        let gate = Flag(true)
        client.onREST { _, _, _, _ in
            while gate.on { try await Task.sleep(for: .milliseconds(10)) }
            return try cacheReadyHealth.encoded()
        }
        let viewer = viewer(service)
        #expect(viewer.debugSetup == "ready", "no checking page on a warm cache")
        #expect(await BotsTest.waitUntil { healthCalls(client) == 2 }, "it still rechecks in the background")
        gate.on = false
        try? await Task.sleep(for: .milliseconds(100))
        #expect(viewer.debugSetup == "ready")
        service.shutdown()
    }

    @Test func withoutACacheTheViewerChecksFirst() async {
        let (service, _) = service(sockets: CountingSockets(hang: true))
        let viewer = viewer(service)
        #expect(viewer.debugSetup == "checking")
        #expect(await BotsTest.waitUntil { viewer.debugSetup == "ready" })
        service.shutdown()
    }

    @Test func aRecheckThatFindsNoPluginOrAnOldOneShowsItsPage() async throws {
        let (service, client) = service(sockets: CountingSockets(hang: true))
        _ = try await service.plugin()
        client.onREST { _, _, _, _ in throw HTTPError(status: 404, body: nil) }
        let missing = viewer(service)
        #expect(missing.debugSetup == "ready")
        #expect(await BotsTest.waitUntil { missing.debugSetup == "missing" })
        #expect(service.cachedPlugin == nil, "a plugin found missing is not served from the cache")
        let reopened = viewer(service)
        #expect(reopened.debugSetup != "ready", "the next open reads /health instead of opening ready")
        #expect(await BotsTest.waitUntil { reopened.debugSetup == "missing" })

        client.onREST { _, _, _, _ in try cacheReadyHealth.encoded() }
        _ = try await service.plugin(fresh: true)
        client.onREST { _, _, _, _ in try (["installed": true, "protocol": 1] as JSONValue).encoded() }
        let old = viewer(service)
        #expect(old.debugSetup == "ready")
        #expect(await BotsTest.waitUntil { old.debugSetup == "update" })
        service.shutdown()
    }

    @Test func aRecheckThatTimesOutLeavesTheViewerReady() async throws {
        let (service, client) = service(sockets: CountingSockets(hang: true))
        _ = try await service.plugin()
        client.onREST { _, _, _, _ in throw URLError(.timedOut) }
        let viewer = viewer(service)
        #expect(await BotsTest.waitUntil { healthCalls(client) >= 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(viewer.debugSetup == "ready")
        service.shutdown()
    }

    // MARK: The activity socket

    @Test func aTransportFailureKeepsTheCachedPlugin() async {
        let sockets = FailingSockets(URLError(.notConnectedToInternet))
        let (service, client) = service(sockets: sockets)
        let subscription = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil(.seconds(5)) { sockets.count >= 2 })
        #expect(healthCalls(client) == 1, "the retry after a network failure skips /health")
        subscription.cancel()
        service.shutdown()
    }

    @Test func aPluginErrorDropsTheCachedPlugin() async {
        let sockets = FailingSockets(HTTPError(status: 503, body: nil))
        let (service, client) = service(sockets: sockets)
        let subscription = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil(.seconds(5)) { sockets.count >= 2 })
        #expect(healthCalls(client) == 2, "a 503 from the plugin asks /health again")
        subscription.cancel()
        service.shutdown()
    }

    @Test func aSilentSocketIsDialledAgain() async throws {
        let server = try QuietServer()
        try await server.start()
        defer { server.stop() }
        let (silence, every) = (BrowserActivityChannel.silence, BrowserActivityChannel.watchEvery)
        BrowserActivityChannel.silence = .milliseconds(400)
        BrowserActivityChannel.watchEvery = .milliseconds(100)
        defer { BrowserActivityChannel.silence = silence; BrowserActivityChannel.watchEvery = every }
        let (service, _) = service(sockets: server)
        let subscription = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil { service.activity.debugOpen })
        #expect(await BotsTest.waitUntil { !service.activity.debugOpen && service.activity.debugRetrying })
        #expect(await BotsTest.waitUntil(.seconds(5)) { server.dials >= 2 })
        subscription.cancel()
        service.shutdown()
    }

    @Test func aSocketThatPingsIsKept() async throws {
        let server = try QuietServer(pingEvery: .milliseconds(100))
        try await server.start()
        defer { server.stop() }
        let (silence, every) = (BrowserActivityChannel.silence, BrowserActivityChannel.watchEvery)
        BrowserActivityChannel.silence = .milliseconds(400)
        BrowserActivityChannel.watchEvery = .milliseconds(100)
        defer { BrowserActivityChannel.silence = silence; BrowserActivityChannel.watchEvery = every }
        let (service, _) = service(sockets: server)
        let subscription = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil { service.activity.debugOpen })
        try? await Task.sleep(for: .milliseconds(1_000))
        #expect(service.activity.debugOpen && server.dials == 1)
        subscription.cancel()
        service.shutdown()
    }

    @Test func aLinkRestoreReplacesAQuietSocketOnly() async throws {
        let quiet = BrowserActivityChannel.quietOnRestore
        BrowserActivityChannel.quietOnRestore = .milliseconds(300)
        defer { BrowserActivityChannel.quietOnRestore = quiet }

        let pinging = try QuietServer(pingEvery: .milliseconds(100))
        try await pinging.start()
        defer { pinging.stop() }
        let (live, _) = service(sockets: pinging)
        let kept = live.activity.subscribe {}
        #expect(await BotsTest.waitUntil { live.activity.debugOpen })
        try? await Task.sleep(for: .milliseconds(500))
        live.activity.linkRestored()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(live.activity.debugOpen && pinging.dials == 1, "a socket that just spoke is left alone")
        kept.cancel()
        live.shutdown()

        let silent = try QuietServer()
        try await silent.start()
        defer { silent.stop() }
        let (service, _) = service(sockets: silent)
        let subscription = service.activity.subscribe {}
        #expect(await BotsTest.waitUntil { service.activity.debugOpen })
        try? await Task.sleep(for: .milliseconds(500))
        service.activity.linkRestored()
        #expect(await BotsTest.waitUntil { !service.activity.debugOpen })
        #expect(await BotsTest.waitUntil(.seconds(5)) { silent.dials >= 2 })
        subscription.cancel()
        service.shutdown()
    }
}
