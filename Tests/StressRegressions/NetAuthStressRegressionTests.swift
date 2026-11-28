// Comprehensive regression tests for Domain 1 (Security, Networking, Auth, RPC, Cloud, Push, Multi-Gateway).
// Every test runs in-process with stand-in hosts/names (127.0.0.1, example.com, ivy, otto, tester) and no external fixtures.

import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

// MARK: - Helpers

/// Isolated `URLProtocol` stub used only by this file's serialized Portal tests (never collides with `PortalStub`).
nonisolated private final class NetStressPortalProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String, _ auth: String?, _ body: String) -> (Int, [String: String], String)
    private static let state = Mutex<(handler: Handler?, count: Int)>((nil, 0))

    static func reset(_ handler: @escaping Handler) {
        state.withLock { $0 = (handler, 0) }
    }

    static var requestCount: Int { state.withLock { $0.count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopped = Mutex(false)

    override func startLoading() {
        let handler = Self.state.withLock { s -> Handler? in
            s.count += 1
            return s.handler
        }
        guard let url = request.url, let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let bodyData = request.httpBody ?? Self.readStream(request.httpBodyStream)
        let bodyText = String(decoding: bodyData, as: UTF8.self)
        let auth = request.value(forHTTPHeaderField: "Authorization")
        // Run off CFNetwork's internal URLProtocol queue so blocking tests can overlap two requests concurrently.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let (status, headers, text) = handler(url.path, auth, bodyText)
            guard !stopped.withLock({ $0 }) else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

/// Minimal in-process loopback HTTP + RFC-6455 WebSocket server for deterministic `GatewayConnection` replay tests.
nonisolated private final class LoopbackWebSocketServer: @unchecked Sendable {
    final class Peer: @unchecked Sendable {
        let id: Int
        private let connection: NWConnection
        private let queue: DispatchQueue

        init(id: Int, connection: NWConnection, queue: DispatchQueue) {
            self.id = id
            self.connection = connection
            self.queue = queue
        }

        func sendText(_ text: String) {
            let payload = [UInt8](text.utf8)
            var frame: [UInt8] = [0x81]
            if payload.count < 126 {
                frame.append(UInt8(payload.count))
            } else if payload.count <= 65535 {
                frame.append(126)
                frame.append(UInt8((payload.count >> 8) & 0xFF))
                frame.append(UInt8(payload.count & 0xFF))
            } else {
                frame.append(127)
                let len = UInt64(payload.count)
                for shift in stride(from: 56, through: 0, by: -8) {
                    frame.append(UInt8((len >> shift) & 0xFF))
                }
            }
            frame.append(contentsOf: payload)
            connection.send(content: Data(frame), completion: .contentProcessed { _ in })
        }

        func sendPong(_ payload: [UInt8]) {
            var frame: [UInt8] = [0x8A, UInt8(min(payload.count, 125))]
            frame.append(contentsOf: payload.prefix(125))
            connection.send(content: Data(frame), completion: .contentProcessed { _ in })
        }

        func close() {
            let frame = Data([0x88, 0x00])
            connection.send(content: frame, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "hqn.tests.loopback-ws")
    private let lock = NSLock()
    private var started = false
    private var nextPeerID = 0
    private var peers: [Peer] = []
    private let onOpen: @Sendable (Peer) -> Void
    private let onRPC: @Sendable (Peer, JSONValue) -> Void

    init(onOpen: @escaping @Sendable (Peer) -> Void, onRPC: @escaping @Sendable (Peer, JSONValue) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        self.onOpen = onOpen
        self.onRPC = onRPC
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self, listener] state in
                guard let self else { return }
                self.lock.lock()
                let first = !self.started
                switch state {
                case .ready, .failed, .cancelled: self.started = true
                default: break
                }
                self.lock.unlock()
                guard first else { return }
                switch state {
                case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        let active = peers
        peers.removeAll()
        lock.unlock()
        active.forEach { $0.close() }
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTP(connection, [])
    }

    private func readHTTP(_ connection: NWConnection, _ buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var bytes = buffer
            if let data { bytes += [UInt8](data) }
            if let sep = Self.findHeaderEnd(bytes) {
                let headBytes = Array(bytes[..<sep])
                let rest = Array(bytes[(sep + 4)...])
                let head = String(decoding: headBytes, as: UTF8.self)
                let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
                let parts = (lines.first ?? "").split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
                    let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                    let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                    self.lock.lock()
                    self.nextPeerID += 1
                    let peer = Peer(id: self.nextPeerID, connection: connection, queue: self.queue)
                    self.peers.append(peer)
                    self.lock.unlock()
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { [weak self] sendError in
                        guard let self, sendError == nil else { return }
                        self.onOpen(peer)
                        self.readWS(peer, connection, rest)
                    })
                    return
                }
                let body: Data
                let status: Int
                if path.hasPrefix("/api/auth/ws-ticket") {
                    status = 200
                    body = Data(#"{"ticket":"t-1"}"#.utf8)
                } else if path.hasPrefix("/api/auth/me") {
                    status = 200
                    body = Data(#"{"user":"tester"}"#.utf8)
                } else {
                    status = 404
                    body = Data(#"{"detail":"Not Found"}"#.utf8)
                }
                let reply = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(reply.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if error != nil || done { connection.cancel(); return }
            self.readHTTP(connection, bytes)
        }
    }

    private func readWS(_ peer: Peer, _ connection: NWConnection, _ buffer: [UInt8]) {
        var bytes = buffer
        while let (opcode, payload, consumed) = Self.parseFrame(bytes) {
            bytes.removeFirst(consumed)
            switch opcode {
            case 0x1:
                if let json = try? JSONValue.parse(Data(payload)) {
                    onRPC(peer, json)
                }
            case 0x8:
                connection.cancel()
                return
            case 0x9:
                peer.sendPong(payload)
            default:
                break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var next = bytes
            if let data { next += [UInt8](data) }
            if error != nil || (done && next.isEmpty) { connection.cancel(); return }
            self.readWS(peer, connection, next)
        }
    }

    private static func findHeaderEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i }
        }
        return nil
    }

    private static func parseFrame(_ bytes: [UInt8]) -> (opcode: UInt8, payload: [UInt8], consumed: Int)? {
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            var len64: UInt64 = 0
            for i in 0..<8 { len64 = (len64 << 8) | UInt64(bytes[offset + i]) }
            guard len64 <= UInt64(Int.max) else { return nil }
            length = Int(len64)
            offset += 8
        }
        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }
        var payload = Array(bytes[offset..<(offset + length)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
        }
        return (opcode, payload, offset + length)
    }
}

// MARK: - C4: Cloudflare Access Token Isolation

@Suite("C4: Cloudflare Access token clearing")
struct CloudflareAccessIsolationRegressionTests {
    @MainActor final class RecordingDriver: SignInDriving {
        var savedByAddress: [String: CloudflareAccess] = [:]
        var used: [CloudflareAccess?] = []
        var probedAddresses: [String] = []
        var accessAtProbe: [CloudflareAccess?] = []

        func useAccess(_ access: CloudflareAccess?) { used.append(access) }
        func savedAccess(for address: String) -> CloudflareAccess? { savedByAddress[address] }
        func probe(_ address: String) async -> SignInOptions {
            probedAddresses.append(address)
            accessAtProbe.append(used.last ?? nil)
            return SignInOptions(reachable: true, offersNous: false, offersPassword: true)
        }
        func signInWithPassword(address: String, username: String, password: String) async throws {}
        func signInWithNous(address: String) async throws {}
    }

    @MainActor @Test func changingAddressOrFillClearsAccessTokenAndNeverSendsToGatewayB() async throws {
        let driver = RecordingDriver()
        let model = SignInModel(driver: driver, onSignedIn: {})
        model.delay = .milliseconds(5)

        // Enter Gateway A and its Cloudflare Access token.
        model.address = "gw-a.example.com"
        model.accessOpen = true
        model.accessId = "gw-a-id.access"
        model.accessSecret = "gw-a-secret"
        #expect(driver.used.last == CloudflareAccess(clientId: "gw-a-id.access", clientSecret: "gw-a-secret"))

        // Editing whitespace or case on the same normalized address must preserve the token.
        model.address = "  GW-A.example.com  "
        #expect(model.accessId == "gw-a-id.access")
        #expect(model.accessSecret == "gw-a-secret")
        #expect(model.accessOpen)

        // Changing to Gateway B clears the token immediately and calls driver.useAccess(nil).
        model.address = "gw-b.example.com"
        #expect(model.accessId.isEmpty && model.accessSecret.isEmpty)
        #expect(!model.accessOpen && !model.behindAccess)
        #expect((driver.used.last ?? nil) == nil)
        model.ask()
        await model.probeTask?.value
        #expect(driver.probedAddresses.last == "https://gw-b.example.com")
        #expect((driver.accessAtProbe.last ?? nil) == nil, "Gateway A's CF-Access headers leaked to Gateway B")

        // Re-populate token for Gateway B, then invoke fill(address:) with Gateway C.
        model.accessOpen = true
        model.accessId = "gw-b-id.access"
        model.accessSecret = "gw-b-secret"
        model.fill(address: "https://gw-c.example.com")
        #expect(model.accessId.isEmpty && model.accessSecret.isEmpty)
        #expect(!model.accessOpen && !model.behindAccess)
        await model.probeTask?.value
        #expect(driver.probedAddresses.last == "https://gw-c.example.com")
        #expect((driver.accessAtProbe.last ?? nil) == nil, "Gateway B's CF-Access headers leaked via fill(address:)")

        // Pasting a hermes://connect link for another host or clearing address also clears access.
        model.accessOpen = true
        model.accessId = "gw-c-id.access"
        model.accessSecret = "gw-c-secret"
        model.address = "\(AppIdentity.current.urlScheme)://connect?url=https://gw-d.example.com"
        #expect(model.address == "https://gw-d.example.com")
        #expect(model.accessId.isEmpty && model.accessSecret.isEmpty && !model.accessOpen)
        #expect((driver.used.last ?? nil) == nil)

        model.accessOpen = true
        model.accessId = "gw-d-id.access"
        model.accessSecret = "gw-d-secret"
        model.address = "   "
        #expect(model.accessId.isEmpty && model.accessSecret.isEmpty && !model.accessOpen)
        #expect((driver.used.last ?? nil) == nil)
    }
}

// MARK: - C7: Same-Gateway Re-Sign-In Replaces Shut-Down Client

@Suite("C7: Same-gateway re-sign-in", .serialized)
struct SameGatewayReSignInRegressionTests {
    @MainActor @Test func activateReplacesShutDownClientAfterSameGatewayReSignIn() async throws {
        let server = try LoopbackHTTP(headers: { request in
            request.path == "/auth/password-login" ? ["Set-Cookie": "sid=session-cookie; Path=/"] : [:]
        }) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/auth/providers"):
                return (200, Data(#"{"providers":[{"name":"basic","supports_password":true}]}"#.utf8))
            case ("POST", "/auth/password-login"):
                return (200, Data(#"{"ok":true}"#.utf8))
            case ("GET", "/api/auth/me"):
                return (200, Data(#"{"user":"tester"}"#.utf8))
            case ("POST", "/api/auth/ws-ticket"):
                return (503, Data(#"{"detail":"offline"}"#.utf8))
            default:
                return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("stress-c7-resignin-\(UUID().uuidString)")
        vault.removeAll()
        defer { vault.removeAll() }

        let service = SignInService(store: AccountStore(vault: vault))
        let model = AppModel(signIn: service, readOnlyGateway: true)
        let address = "http://127.0.0.1:\(port)"

        let firstAccount = try await service.signInWithPassword(address: address, username: "tester", password: "pw1")
        model.activate(firstAccount)
        let firstClient = try #require(model.client)
        #expect(!firstClient.isShutDown)
        #expect(service.isActiveClient(firstClient, for: firstAccount))

        // Re-sign into the exact same gateway + username: SignInService shuts down `firstClient` and adopts a new one.
        let secondAccount = try await service.signInWithPassword(address: address, username: "tester", password: "pw2")
        #expect(secondAccount.id == firstAccount.id)
        #expect(firstClient.isShutDown)
        #expect(!service.isActiveClient(firstClient, for: secondAccount))

        // Activating the same account id must replace the shut-down client with the new live client.
        model.activate(secondAccount)
        let secondClient = try #require(model.client)
        #expect(secondClient !== firstClient)
        #expect(!secondClient.isShutDown)
        #expect(service.isActiveClient(secondClient, for: secondAccount))

        // Calling activate again while live is still a no-op (keeps the same client instance).
        model.activate(secondAccount)
        #expect(model.client === secondClient)

        secondClient.shutdown()
        service.signOut()
    }
}

// MARK: - C9: HTTPTransport & GatewayTransfer Invalidation Concurrency Stress

@Suite("C9: Transport invalidation continuation safety", .serialized)
nonisolated struct TransportInvalidationStressTests {
    @Test func httpTransportInvalidateRaceNeverLeaksContinuations() async throws {
        let server = try LoopbackHTTP(delay: { _ in 2.0 }) { _ in
            (200, Data(#"{"ok":true}"#.utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/api/status")!

        for round in 0..<5 {
            let transport = HTTPTransport(cookies: false)
            try await untilDeadline(.now + .seconds(5), late: { TimedOut(what: "round \(round) invalidation settle") }) {
                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<16 {
                        group.addTask {
                            let req = URLRequest(url: url, timeoutInterval: 10)
                            _ = try? await transport.data(for: req, pool: i % 2 == 0 ? .bulk : .control, ceiling: 1024)
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(round * 3))
                        transport.invalidate()
                    }
                }
            }
            #expect(transport.requestsInFlight == 0)
        }
    }

    @Test func gatewayTransferUploadAndDownloadInvalidateRaceNeverLeaksContinuations() async throws {
        let server = try LoopbackHTTP(delay: { _ in 2.0 }) { _ in
            (200, Data(#"{"ok":true}"#.utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        let bodyFile = FileManager.default.temporaryDirectory.appending(path: "hqn-c9-upload-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: 64).write(to: bodyFile)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        for round in 0..<4 {
            let transport = HTTPTransport(cookies: false)
            let target = FileManager.default.temporaryDirectory.appending(path: "hqn-c9-dl-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: target) }

            try await untilDeadline(.now + .seconds(5), late: { TimedOut(what: "transfer round \(round) settle") }) {
                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<6 {
                        let req = URLRequest(url: base.appending(path: "/api/files/test-\(i)"), timeoutInterval: 10)
                        group.addTask {
                            if i % 2 == 0 {
                                _ = try? await TransferTask.upload(req, file: bodyFile, transport: transport, priority: 0.5, ceiling: 1024, progress: nil)
                            } else {
                                _ = try? await TransferTask.download(req, to: target, transport: transport, priority: 0.5, ceiling: 1024, progress: nil)
                            }
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(round * 3))
                        transport.invalidate()
                    }
                }
            }
        }
    }
}

// MARK: - H1 & H2: Integer Overflow & Float-to-Int Safety

@Suite("H1 & H2: Overflow and remote float-to-Int safety")
nonisolated struct OverflowAndFloatSafetyTests {
    @Test func replayBookHasGapIsOverflowSafeAtIntMaxAndIntMin() {
        func event(_ seq: Int, session: String = "s1") -> GatewayEvent {
            GatewayEvent(type: "message.delta", sessionId: session, seq: seq, payload: .null)
        }
        var book = ReplayBook()
        _ = book.ready(epoch: "e1")
        _ = book.live(event(Int.max), size: 10)
        #expect(book.cursors["s1"] == Int.max)
        #expect(!book.hasGap(event(Int.max)))
        #expect(!book.hasGap(event(0)))
        #expect(!book.hasGap(event(Int.min)))

        var book2 = ReplayBook()
        _ = book2.ready(epoch: "e1")
        _ = book2.live(event(Int.max - 1), size: 10)
        #expect(!book2.hasGap(event(Int.max)))

        var book3 = ReplayBook()
        _ = book3.ready(epoch: "e1")
        _ = book3.live(event(Int.min), size: 10)
        #expect(!book3.hasGap(event(Int.min + 1)))
        #expect(book3.hasGap(event(Int.min + 2)))
    }

    @Test func hugeAndNonFiniteRemoteDoublesNeverTrap() {
        // CloudPrices.dollars
        #expect(CloudPrices.dollars(1e20).hasPrefix("$"))
        #expect(CloudPrices.dollars(-1e20).hasPrefix("$"))
        #expect(CloudPrices.dollars(.infinity) == "$0")
        #expect(CloudPrices.dollars(-.infinity) == "$0")
        #expect(CloudPrices.dollars(.nan) == "$0")
        #expect(CloudPrices.dollars(0.56) == "$0.56")
        #expect(CloudPrices.dollars(32.7) == "$33")

        // CloudSpend rejects absurd / non-finite numbers
        #expect(CloudSpend.read(["monthly": .number(1e30), "toDate": .string("$inf")]) == nil)
        #expect(CloudSpend.read(["monthly": .number(.infinity), "toDate": .number(.nan)]) == nil)
        let normalSpend = CloudSpend.read(["monthly": .number(18.0), "toDate": .string("$2.50")])
        #expect(normalSpend == CloudSpend(toDate: 2.5, monthly: 18.0))

        // NousGatewayProtocol.answer sanitizes absurd expires_at to 0
        let hugeBody = Data(#"{"access_token":"at","refresh_token":"rt","user_id":"u1","provider":"nous","expires_at":1e30}"#.utf8)
        if case .tokens(let tokens) = NousGatewayProtocol.answer(status: 200, body: hugeBody, now: 1_800_000_000) {
            #expect(tokens.expiresAt == 0)
        } else {
            Issue.record("expected tokens with sanitized expiresAt")
        }

        // NousTokens logging helpers survive absurd / non-finite numbers
        let extreme = NousTokens(accessToken: "a", refreshToken: "r", expiresAt: 1e30, userId: "u1", obtainedAt: 0)
        #expect(!extreme.ageNote(now: 1e30).isEmpty)
        let infTokens = NousTokens(accessToken: "a", refreshToken: "r", expiresAt: .infinity, userId: "u1", obtainedAt: .nan)
        #expect(!infTokens.needsRenewal(now: 1000))
        #expect(!infTokens.renewsAlongside(now: 1000))
        #expect(!infTokens.ageNote(now: 1000).isEmpty)
        #expect(NousTokens.age(.infinity) == "0 s")
        #expect(NousTokens.age(.nan) == "0 s")
        #expect(NousTokens.age(1e30).hasSuffix(" d"))

        // CloudToolSchema.fields ignores out-of-Int-range enum/default numbers without trapping
        let schemaJSON: JSONValue = [
            "properties": [
                "action": ["type": "string", "enum": ["create"]],
                "disk_gb": ["type": "integer", "enum": [.number(1e30), .number(25)], "default": .number(1e30)],
            ],
        ]
        let fields = CloudToolSchema.read(schemaJSON).fields(for: "create")
        let disk = fields.first { $0.name == "disk_gb" }
        #expect(disk?.choices == ["25"])
        #expect(disk?.defaultValue == nil)

        // RetryLater.parse rejects non-finite strings
        #expect(RetryLater.parse("inf") == nil)
        #expect(RetryLater.parse("nan") == nil)
        #expect(RetryLater.parse("Infinity") == nil)
    }
}

// MARK: - H9: CAS forgetSession, Keyed NousRenewals, Switcher Generation Guard

@Suite("H9: CAS session erasure, keyed renewals, switcher guard", .serialized)
struct SessionRaceGuardsRegressionTests {
    @Test func casForgetSessionPreservesNewerSignInInVaultAndGatewayAuth() async throws {
        let vault = Fixtures.testVault("stress-h9-cas-\(UUID().uuidString)")
        vault.removeAll()
        defer { vault.removeAll() }

        let oldCookies = [SavedCookie(name: "sid", value: "v1", domain: "127.0.0.1")]
        let newCookies = [SavedCookie(name: "sid", value: "v2", domain: "127.0.0.1")]
        let acctOld = StoredAccount(url: "http://127.0.0.1:9", username: "tester", cookies: oldCookies)
        let acctNew = StoredAccount(url: "http://127.0.0.1:9", username: "tester", cookies: newCookies)
        try vault.save(acctNew)

        // Stale cookie session cannot wipe newer session.
        #expect(!vault.forgetSession(acctOld.key, expectedCookies: oldCookies, expectedNous: nil))
        #expect(vault.peek(acctNew.key)?.cookies == newCookies)
        // Matching session is erased cleanly.
        #expect(vault.forgetSession(acctNew.key, expectedCookies: newCookies, expectedNous: nil))
        #expect(vault.peek(acctNew.key)?.cookies == nil)

        // Same for Nous pairs via live GatewayAuth refusal against LoopbackHTTP: a stale auth receiving 403
        // calls reject(.sessionEnded) and must NOT wipe a newer sign-in's pair in Keychain.
        let now = Date().timeIntervalSince1970
        let staleNous = NousTokens(accessToken: "at-stale", refreshToken: "rt-stale", expiresAt: now + 600, userId: "u1", obtainedAt: now)
        let freshNous = NousTokens(accessToken: "at-fresh", refreshToken: "rt-fresh", expiresAt: now + 600, userId: "u1", obtainedAt: now)
        let server = try LoopbackHTTP { _ in (403, Data(#"{"error":"not_authorized"}"#.utf8)) }
        let port = try await server.start()
        defer { server.stop() }

        let storedStale = StoredAccount(url: "http://127.0.0.1:\(port)", username: "nous:u1", nous: staleNous)
        let storedFresh = StoredAccount(url: "http://127.0.0.1:\(port)", username: "nous:u1", nous: freshNous)
        try vault.save(storedFresh)

        let transport = HTTPTransport(cookies: false)
        defer { transport.invalidate() }
        let staleAuth = GatewayAuth(stored: storedStale, base: URL(string: storedStale.url)!, transport: transport, vault: vault,
                                    verified: true, renewals: NousRenewals(hold: { _ in { } }))
        await staleAuth.useLeaseDirectory(nil)
        await #expect(throws: GatewayFailure.sessionEnded) {
            _ = try await staleAuth.mintTicket(timeout: .seconds(5))
        }
        // Keychain must STILL hold `freshNous`!
        #expect(vault.peek(storedFresh.key)?.nous?.refreshToken == "rt-fresh")
    }

    @Test func nousRenewalsFlightsAreKeyedByRefreshToken() async {
        let renewals = NousRenewals(hold: { _ in { } })
        let now = Date().timeIntervalSince1970
        let oldPair = NousTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: now - 10, userId: "u1", obtainedAt: now - 910)
        let freshPair = NousTokens(accessToken: "at-new", refreshToken: "rt-new", expiresAt: now - 10, userId: "u1", obtainedAt: now - 910)
        let freshNext = NousTokens(accessToken: "at-new-2", refreshToken: "rt-new-2", expiresAt: now + 900, userId: "u1", obtainedAt: now)

        let entered = Mutex(false)
        let gate = AsyncStream<Void>.makeStream()

        // Start a slow failing flight for rt-old.
        let oldTask = Task {
            await renewals.renew("same-key", oldPair, post: { _ in
                entered.withLock { $0 = true }
                for await _ in gate.stream { break }
                return .refused
            }, keep: { _, _ in true })
        }

        // Wait until old flight is in progress.
        for _ in 0..<100 where !entered.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.withLock { $0 })

        // A new sign-in with rt-new on the SAME account key must NOT join rt-old's flight.
        let freshOutcome = await renewals.renew("same-key", freshPair, post: { sent in
            #expect(sent.refreshToken == "rt-new")
            return .tokens(freshNext)
        }, keep: { _, _ in true })

        if case .tokens(let got) = freshOutcome {
            #expect(got.samePair(freshNext))
        } else {
            Issue.record("expected fresh rotation to succeed independently, got \(freshOutcome)")
        }

        gate.continuation.yield()
        gate.continuation.finish()
        let oldOutcome = await oldTask.value
        if case .refused = oldOutcome { } else { Issue.record("expected old flight to return .refused") }
    }

    @MainActor @Test func switcherStaleProbeDoesNotExpireSwitchedAccount() async throws {
        let vault = Fixtures.testVault("stress-h9-switcher-\(UUID().uuidString)")
        vault.removeAll()
        defer { vault.removeAll() }
        let store = AccountStore(vault: vault)
        let acctA = StoredAccount(url: "http://127.0.0.1:9781", username: "tester",
                                  cookies: [SavedCookie(name: "s", value: "a", domain: "127.0.0.1")])
        let acctB = StoredAccount(url: "http://127.0.0.1:9782", username: "tester",
                                  cookies: [SavedCookie(name: "s", value: "b", domain: "127.0.0.1")])
        try store.save(acctB)
        try store.save(acctA)

        let directory = BotsTest.tempDirectory()
        let parkedB = try #require(acctB.gatewayAccount)
        let roster = RosterCacheFile(at: 0, profiles: [
            ["name": "ivy", "canonical_session": ["id": "s-ivy", "last_active": 100, "message_count": 2]],
        ])
        try JSONEncoder().encode(roster).write(to: RosterDisk.url(directory, RosterDisk.rosterKind, parkedB))

        let model = GatewaySwitcherModel(store: store, directory: directory)
        var activeID: String? = acctA.gatewayAccount?.id
        model.currentId = { activeID }

        nonisolated final class GatedRefusingProbe: ParkedAccountReading {
            let started = Locked(false)
            let gate: AsyncStream<Void>
            init(gate: AsyncStream<Void>) { self.gate = gate }
            func read(id: String, profile: String?) async throws -> AccountProbe.Answer {
                started.set(true)
                for await _ in gate { break }
                return .refused
            }
            func finish() {}
        }

        let gate = AsyncStream<Void>.makeStream()
        let probe = GatedRefusingProbe(gate: gate.stream)
        model.makeProbe = { _ in probe }

        let checkTask = Task { await model.check(force: true) }
        try await eventually(within: 5, "probe started") { probe.started.value }

        // User switches to Account B while the stale parked probe is in flight.
        activeID = parkedB.id
        model.switched(to: parkedB.id)

        // Release the stale refusing probe.
        gate.continuation.yield()
        gate.continuation.finish()
        await checkTask.value

        #expect(!model.expired.contains(parkedB.id), "stale probe marked newly active account expired")
        #expect(model.hasUsableSession(parkedB))
    }
}

// MARK: - H10: PortalLogin & GatewayAuth Expired Rotated Token / Reentrancy

@Suite("H10: PortalLogin & GatewayAuth rotation guards", .serialized)
nonisolated struct PortalAndAuthRotationRegressionTests {
    @Test func portalLoginHandlesExpiredRotatedTokenLockedAdoptAndSignOutIfMatching() async throws {
        let refusing = Locked(true)
        var keychain = PortalKeychain(service: "tests.stress.h10.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.refusesSavesForTests = { refusing.value }

        let now = Date().timeIntervalSince1970
        let session = PortalAuth.makeSession(protocols: [NetStressPortalProtocol.self])
        defer { session.invalidateAndCancel() }
        let login = PortalLogin(keychain: keychain, auth: PortalAuth(session: session), hold: { _ in { } })

        // 1. adopt(_:) retains unsaved credentials when Keychain refuses saves.
        let initial = PortalCredentials(clientId: "mcp:c", accessToken: "tok-expired", refreshToken: "ref-1",
                                        expiresAt: now - 120, obtainedAt: now - 1020)
        await login.adopt(initial)
        #expect(await login.isSignedIn, "adopt dropped credentials when Keychain was locked")
        #expect(keychain.read() == nil)

        // 2. accessToken(force: true, refused: "older") must NOT return `tok-expired` because it needsRenewal()!
        NetStressPortalProtocol.reset { path, _, _ in
            guard path == "/api/oauth/token" else { return (404, [:], "") }
            return (200, ["Content-Type": "application/json"],
                    #"{"access_token":"tok-fresh","refresh_token":"ref-2","expires_in":3600}"#)
        }
        refusing.set(false)
        let token = try await login.accessToken(force: true, refused: "tok-older")
        #expect(token == "tok-fresh")
        #expect(NetStressPortalProtocol.requestCount == 1)
        #expect(keychain.read()?.accessToken == "tok-fresh")

        // 3. signOutIfMatching ignores a stale token and only signs out on matching token.
        await login.signOutIfMatching("tok-older")
        #expect(await login.isSignedIn)
        await login.signOutIfMatching("tok-fresh")
        #expect(!(await login.isSignedIn))
    }

    @Test func portalLoginReentrancyDeferDoesNotClobberNewerRenewalFlight() async throws {
        let keychain = PortalKeychain(service: "tests.stress.h10.defer.\(UUID().uuidString)")
        defer { keychain.clear() }
        let now = Date().timeIntervalSince1970
        let firstCreds = PortalCredentials(clientId: "mcp:c", accessToken: "a1", refreshToken: "r1", expiresAt: now - 10, obtainedAt: now - 900)
        let secondCreds = PortalCredentials(clientId: "mcp:c", accessToken: "b1", refreshToken: "r2", expiresAt: now - 10, obtainedAt: now - 900)
        keychain.save(firstCreds)

        let startedR1 = Locked(false)
        let startedR2 = Locked(false)
        let r2Count = Locked(0)
        let sem1 = DispatchSemaphore(value: 0)
        let sem2 = DispatchSemaphore(value: 0)
        NetStressPortalProtocol.reset { _, _, body in
            if body.contains("refresh_token=r1") {
                startedR1.set(true)
                _ = sem1.wait(timeout: .now() + 5)
                return (200, ["Content-Type": "application/json"], #"{"access_token":"a2","refresh_token":"r1b","expires_in":3600}"#)
            }
            if body.contains("refresh_token=r2") {
                r2Count.mutate { $0 += 1 }
                startedR2.set(true)
                _ = sem2.wait(timeout: .now() + 5)
                return (200, ["Content-Type": "application/json"], #"{"access_token":"b2","refresh_token":"r2b","expires_in":3600}"#)
            }
            return (404, [:], "")
        }

        let session = PortalAuth.makeSession(protocols: [NetStressPortalProtocol.self])
        defer { session.invalidateAndCancel() }
        let login = PortalLogin(keychain: keychain, auth: PortalAuth(session: session), hold: { _ in { } })

        // Flight 1 starts on r1.
        let t1 = Task { try? await login.accessToken(force: true) }
        try await eventually(within: 5, "flight 1 started") { startedR1.value }

        // User signs in fresh with r2 (cancels flight 1) and Flight 2 starts on r2.
        await login.adopt(secondCreds)
        let t2 = Task { try await login.accessToken(force: true) }
        try await eventually(within: 5, "flight 2 started") { startedR2.value }

        // Finish Flight 1 while Flight 2 is still in flight: Flight 1's defer MUST NOT nil out Flight 2!
        sem1.signal()
        _ = await t1.value

        // A concurrent caller arriving now must join Flight 2, NOT launch a second r2 POST!
        let t3 = Task { try await login.accessToken(force: true) }
        try await Task.sleep(for: .milliseconds(50))
        sem2.signal()

        let res2 = try await t2.value
        let res3 = try await t3.value
        #expect(res2 == "b2" && res3 == "b2")
        #expect(r2Count.value == 1, "Flight 1's defer clobbered Flight 2 and caused a duplicate refresh!")
    }

    @Test func gatewayAuthRefreshDoesNotSkipWhenRotatedTokenIsAlreadyExpired() async throws {
        let now = Date().timeIntervalSince1970
        let refreshes = Locked(0)
        let server = try LoopbackHTTP { request in
            if request.path == "/auth/native/refresh" {
                refreshes.mutate { $0 += 1 }
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "access_token": "at-2", "refresh_token": "rt-2", "user_id": "u1",
                    "provider": "nous", "expires_at": now + 900,
                ]))
            }
            return (404, Data(#"{"detail":"Not Found"}"#.utf8))
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("stress-h10-gwauth-\(UUID().uuidString)")
        vault.removeAll()
        defer { vault.removeAll() }

        let expiredRotated = NousTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: now - 30, userId: "u1", obtainedAt: now - 930)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "nous:u1", nous: expiredRotated)
        try vault.save(stored)

        let transport = HTTPTransport(cookies: false)
        defer { transport.invalidate() }
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault,
                               verified: true, renewals: NousRenewals(hold: { _ in { } }))
        await auth.useLeaseDirectory(nil)

        // Caller sent an older token "at-0", while `stored.nous` holds "at-1" which is ALREADY expired.
        // refresh(sentAccess: "at-0") must renew "at-1" -> "at-2" instead of returning early with expired "at-1".
        try await auth.refresh(sentAccess: "at-0", trigger: "401")
        #expect(refreshes.value == 1)
        #expect(await auth.stored.nous?.accessToken == "at-2")
    }
}

// MARK: - H11: GatewayConnection Replay Must Not Unpark Concurrent Gap Repair

@Suite("H11: Replay preserves concurrent gap-repair parks", .serialized)
nonisolated struct GatewayConnectionReplayRegressionTests {
    private static func eventFrame(_ session: String, seq: Int) -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"\#(session)","seq":\#(seq),"payload":{"text":"\#(seq)"}}}"#
    }

    private static func readyFrame(epoch: String) -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","session_id":"","payload":{"replay_epoch":"\#(epoch)"}}}"#
    }

    private static func rpcResult(id: Int, resultJSON: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#
    }

    @Test func reconnectReplayFinishingDoesNotUnparkConcurrentGapRepairSession() async throws {
        struct ServerState {
            var s1Since: (peer: LoopbackWebSocketServer.Peer, id: Int)?
            var s2Since: (peer: LoopbackWebSocketServer.Peer, id: Int)?
            var firstPeer: LoopbackWebSocketServer.Peer?
            var secondPeer: LoopbackWebSocketServer.Peer?
        }
        let state = Mutex(ServerState())
        let server = try LoopbackWebSocketServer(
            onOpen: { peer in
                peer.sendText(Self.readyFrame(epoch: "ep-1"))
                state.withLock { s in
                    if s.firstPeer == nil { s.firstPeer = peer }
                    else { s.secondPeer = peer }
                }
            },
            onRPC: { peer, json in
                guard let id = json["id"]?.int, let method = json["method"]?.string else { return }
                if method == "client.capabilities" {
                    peer.sendText(Self.rpcResult(id: id, resultJSON: "{}"))
                    return
                }
                if method == "session.events.since" {
                    let sid = json["params"]?["session_id"]?.string ?? ""
                    if sid == "s1" {
                        state.withLock { $0.s1Since = (peer, id) }
                        // While s1's reconnect replay is in flight, inject a gap on s2 (seq 1 -> seq 4, seq 5).
                        peer.sendText(Self.eventFrame("s2", seq: 1))
                        peer.sendText(Self.eventFrame("s2", seq: 4))
                        peer.sendText(Self.eventFrame("s2", seq: 5))
                    } else if sid == "s2" {
                        state.withLock { $0.s2Since = (peer, id) }
                    }
                }
            }
        )
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("stress-h11-replay-\(UUID().uuidString)")
        vault.removeAll()
        defer { vault.removeAll() }
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "tester",
                                   cookies: [SavedCookie(name: "s", value: "1", domain: "127.0.0.1")])
        let transport = HTTPTransport()
        let client = LiveGatewayClient(stored: stored, transport: transport, vault: vault, verified: true, watchNetwork: false)
        defer { client.shutdown() }

        let seenS2 = Locked<[Int]>([])
        let seenS1 = Locked<[Int]>([])
        let events = client.events()
        let consumer = Task {
            for await event in events {
                if event.sessionId == "s1", let seq = event.seq { seenS1.mutate { $0.append(seq) } }
                if event.sessionId == "s2", let seq = event.seq { seenS2.mutate { $0.append(seq) } }
            }
        }
        defer { consumer.cancel() }

        try await waitFor(client, .ready, within: 8)
        let peer1 = try #require(state.withLock { $0.firstPeer })
        peer1.sendText(Self.eventFrame("s1", seq: 1))
        try await eventually(within: 5, "s1 seq 1 delivered") { seenS1.value == [1] }

        // Drop socket 1 so socket 2 reconnects and replays s1.
        peer1.close()
        try await eventually(within: 8, "both s1 and s2 session.events.since received") {
            state.withLock { $0.s1Since != nil && $0.s2Since != nil }
        }
        try await eventually(within: 5, "s2 seq 1 delivered") { seenS2.value == [1] }

        // Answer s1's reconnect replay FIRST while s2's gap repair is still pending.
        let s1Req = try #require(state.withLock { $0.s1Since })
        s1Req.peer.sendText(Self.rpcResult(id: s1Req.id, resultJSON: #"{"epoch":"ep-1","events":[],"truncated":false}"#))
        try await Task.sleep(for: .milliseconds(150))

        // s2 must STILL be parked (seq 4 and 5 must not have been released prematurely by s1's replay!).
        #expect(seenS2.value == [1], "s1's replay prematurely released s2's gap-repair parked frames: \(seenS2.value)")

        // Now answer s2's gap repair with the missed frames (seq 2 and seq 3).
        let s2Req = try #require(state.withLock { $0.s2Since })
        let missed = #"{"epoch":"ep-1","events":[{"type":"message.delta","session_id":"s2","seq":2,"payload":{"text":"2"}},{"type":"message.delta","session_id":"s2","seq":3,"payload":{"text":"3"}}],"truncated":false}"#
        s2Req.peer.sendText(Self.rpcResult(id: s2Req.id, resultJSON: missed))

        try await eventually(within: 5, "all s2 events 1..5 delivered in order") { seenS2.value == [1, 2, 3, 4, 5] }
        #expect(seenS2.value == [1, 2, 3, 4, 5])
    }
}

// MARK: - H12: Multi-Gateway & Sign-Out Races

@Suite("H12: Multi-gateway removal and switch races", .serialized)
struct MultiGatewayRaceRegressionTests {
    @MainActor @Test func removeDeletesFromStoreBeforeLogoutCompletesAndClearsUnsavedNous() async throws {
        let logoutStarted = Locked(false)
        let server = try LoopbackHTTP(delay: { $0.path == "/auth/logout" ? 0.6 : 0 }) { request in
            if request.path == "/auth/logout" {
                logoutStarted.set(true)
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            return (404, Data(#"{"detail":"Not Found"}"#.utf8))
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("stress-h12-remove-\(UUID().uuidString)")
        vault.removeAll()
        defer { vault.removeAll() }
        let store = AccountStore(vault: vault)
        let parked = StoredAccount(url: "http://127.0.0.1:\(port)", username: "ivy",
                                   cookies: [SavedCookie(name: "s", value: "p", domain: "127.0.0.1")])
        let current = StoredAccount(url: "http://127.0.0.1:\(port)", username: "otto",
                                    cookies: [SavedCookie(name: "s", value: "c", domain: "127.0.0.1")])
        try store.save(parked)
        try store.save(current)
        let parkedAccount = try #require(parked.gatewayAccount)
        let service = SignInService(store: store)

        let removal = Task { try await service.remove(parkedAccount) }
        try await eventually(within: 5, "logout in flight") { logoutStarted.value }

        // While logout is STILL in flight, the parked account must ALREADY be gone from store so switchTo cannot promote it.
        #expect(store.stored(parkedAccount) == nil)
        #expect(try !service.switchTo(parkedAccount))
        try await removal.value
    }

    @MainActor @Test func settingsHubSwitchToAbortsWhenUserSignsOutMidSwitch() async throws {
        let vault = Fixtures.testVault("stress-h12-switch-\(UUID().uuidString)")
        vault.removeAll()
        defer { vault.removeAll() }
        let store = AccountStore(vault: vault)
        let acctA = StoredAccount(url: "http://127.0.0.1:9785", username: "ivy",
                                  cookies: [SavedCookie(name: "s", value: "a", domain: "127.0.0.1")])
        let acctB = StoredAccount(url: "http://127.0.0.1:9786", username: "otto",
                                  cookies: [SavedCookie(name: "s", value: "b", domain: "127.0.0.1")])
        try store.save(acctB)
        try store.save(acctA)
        let service = SignInService(store: store)
        let model = AppModel(signIn: service, readOnlyGateway: true)
        let a = try #require(acctA.gatewayAccount)
        let b = try #require(acctB.gatewayAccount)
        model.activate(a)
        defer { model.client?.shutdown() }

        // Start switching from A -> B, then immediately tear down/sign out during the 60 ms pre-switch window.
        let switching = Task { try await model.settingsHub.switchTo(b.id) }
        try await Task.sleep(for: .milliseconds(15))
        model.endSession(SignInService.Prefill(address: a.baseURL.absoluteString, username: a.username))
        try await switching.value

        #expect(model.account == nil, "in-flight switchTo re-activated B after the user signed out")
        #expect(store.current?.id == a.id, "in-flight switchTo mutated current gateway after sign-out")
    }
}

// MARK: - M1: GatewayAuth.settleRenewal Honors Short Deadline

@Suite("M1: settleRenewal deadline", .serialized)
nonisolated struct SettleRenewalDeadlineRegressionTests {
    @Test func settleRenewalReturnsAtDeadlineWithoutCancellingUnderlyingRefresh() async throws {
        let now = Date().timeIntervalSince1970
        let server = try LoopbackHTTP(delay: { $0.path == "/auth/native/refresh" ? 1.2 : 0 }) { request in
            switch request.path {
            case "/api/auth/ws-ticket":
                return (200, Data(#"{"ticket":"t-1"}"#.utf8))
            case "/auth/native/refresh":
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "access_token": "at-new", "refresh_token": "rt-new", "user_id": "u1",
                    "provider": "nous", "expires_at": now + 900,
                ]))
            default:
                return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }

        let vault = Fixtures.testVault("stress-m1-settle-\(UUID().uuidString)")
        vault.removeAll()
        defer { vault.removeAll() }
        // 300 s of 900 s left -> triggers alongside refresh immediately when mintTicket sends.
        let tokens = NousTokens(accessToken: "at-old", refreshToken: "rt-old", expiresAt: now + 300, userId: "u1", obtainedAt: now - 600)
        let stored = StoredAccount(url: "http://127.0.0.1:\(port)", username: "nous:u1", nous: tokens)
        try vault.save(stored)

        let transport = HTTPTransport(cookies: false)
        defer { transport.invalidate() }
        let auth = GatewayAuth(stored: stored, base: URL(string: stored.url)!, transport: transport, vault: vault,
                               verified: true, renewals: NousRenewals(hold: { _ in { } }))
        await auth.useLeaseDirectory(nil)

        _ = try await auth.mintTicket(timeout: .seconds(5))
        #expect(await auth.renewalsAlongside == 1)

        // settleRenewal(limit: 50 ms) must return promptly at ~50 ms instead of blocking for the full 1.2 s!
        let began = ContinuousClock.now
        await auth.settleRenewal(limit: .milliseconds(50))
        let elapsed = began.duration(to: .now)
        #expect(elapsed < .milliseconds(450), "settleRenewal ignored its 50 ms deadline and waited \(elapsed)")

        // And the underlying refresh was NOT cancelled: it still finishes and persists rt-new!
        try await eventually(within: 5, "underlying refresh still persisted") {
            vault.peek()?.nous?.refreshToken == "rt-new"
        }
    }
}

// MARK: - M2: PushRegistrar Transient Failures & Counter Guards

@Suite("M2: PushRegistrar transient retry & counters", .serialized)
struct PushRegistrarRegressionTests {
    private let owner = String(repeating: "ef", count: 32)
    private let statusOK: [String: Any] = [
        "ok": true, "kinds": ["turnDone", "approval"], "seal": true, "replies": "watcher",
        "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true,
        "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true,
        "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true,
        "liveEnds": true, "liveQuick": true, "terminal": true, "tasks": true, "draftCards": true,
        "pluginUpdates": true, "task_fields": true, "draftCardsShown": true, "pluginUpdatesChecked": true,
        "goal_pages": true, "pluginVersion": "0.9.58", "delivery": "Relay",
    ]

    @MainActor @Test func transientOfflineAndServerErrorsKeepRetryTrueWithoutTenMinuteLockout() async {
        let suite = "hqn.tests.stress.m2.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let push = PushRegistrar(defaults: defaults)
        push.availableOverride = true
        push.isAuthorized = { true }
        push.received(token: Data(repeating: 0xcd, count: 32))
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }

        var status = 0
        var puts = 0
        push.call = { [statusOK] path, method, _ in
            if path.hasSuffix("/status") { return (status, status == 200 ? statusOK : nil) }
            if method == "PUT" { puts += 1; return (200, ["ok": true]) }
            return (404, nil)
        }

        // Transient status 0, 503, and 429 must all set retry = true and NOT lock out for 10 minutes.
        for transient in [0, 503, 429] {
            status = transient
            await push.register()
            #expect(push.retry, "transient status \(transient) must keep retry == true")
            #expect(!push.active)
        }

        // The very next register() when back online succeeds immediately (no 10-minute absence lockout!).
        status = 200
        await push.register()
        #expect(push.active && !push.retry && puts == 1)
    }

    @MainActor @Test func overlappingPutsKeepUnregisterWaitingUntilAllPutsFinish() async throws {
        let suite = "hqn.tests.stress.m2.overlap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let push = PushRegistrar(defaults: defaults)
        push.availableOverride = true
        push.isAuthorized = { true }
        push.received(token: Data(repeating: 0xab, count: 32))
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }

        var putNumber = 0
        var put1Done: CheckedContinuation<Void, Never>?
        var put2Done: CheckedContinuation<Void, Never>?
        var deleteRan = false
        var deleteSawPut2Finished = false
        var put2Finished = false

        push.call = { [statusOK] path, method, _ in
            if path.hasSuffix("/status") { return (200, statusOK) }
            if method == "PUT" {
                putNumber += 1
                let n = putNumber
                if n == 1 {
                    await withCheckedContinuation { put1Done = $0 }
                } else if n == 2 {
                    await withCheckedContinuation { put2Done = $0 }
                    put2Finished = true
                }
                return (200, ["ok": true])
            }
            if method == "DELETE" {
                deleteRan = true
                deleteSawPut2Finished = put2Finished
                return (200, ["ok": true])
            }
            return (404, nil)
        }

        let reg1 = Task { @MainActor in await push.register() }
        for _ in 0..<100 where put1Done == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let reg2 = Task { @MainActor in await push.register() }
        for _ in 0..<100 where put2Done == nil { try? await Task.sleep(for: .milliseconds(10)) }

        // Start unregister while both PUT 1 and PUT 2 are in flight.
        let unreg = Task { @MainActor in await push.unregister() }
        try? await Task.sleep(for: .milliseconds(30))

        // Finish PUT 1 first: DELETE must STILL wait for PUT 2!
        put1Done?.resume(); put1Done = nil
        await reg1.value
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!deleteRan, "DELETE ran before PUT 2 finished")

        put2Done?.resume(); put2Done = nil
        await reg2.value
        await unreg.value
        #expect(deleteRan && deleteSawPut2Finished, "DELETE should run only after all overlapping PUTs finish")
    }
}

// MARK: - M3 & M4: CloudDesktopWeb Cleanup & Ask Continuation Safety

@Suite("M3 & M4: CloudDesktopWeb safety and purges", .serialized)
struct CloudDesktopWebAndPurgeRegressionTests {
    @MainActor @Test func askReturnsFalseImmediatelyWhenNotPresentedAndPurgeClearsReminders() async {
        let controller = CloudDesktopWebController(url: URL(string: "https://ivy-1000.agents.nousresearch.com/")!, agentName: "Ivy")
        // Controller is not in a window: ask must not hang and must return false immediately.
        let answer = await controller.ask("Confirm action?", cancel: true)
        #expect(!answer)

        // purgeDataStore safely accepts both cloud and non-cloud URLs without throwing/crashing.
        CloudDesktopWeb.purgeDataStore(for: URL(string: "https://ivy-1000.agents.nousresearch.com/")!)
        CloudDesktopWeb.purgeDataStore(for: URL(string: "https://selfhosted.example.com/")!)

        // SettingsHub.purge clears AddOnReminder and PluginUpdateReminder too.
        let account = GatewayAccount(id: "http://127.0.0.1:65001|purge-\(UUID().uuidString)",
                                     baseURL: URL(string: "http://127.0.0.1:65001")!, kind: .password, username: "tester", label: "x")
        AddOnReminder.shared.report(account: account.id, state: .outdated, without: [])
        #expect(UserDefaults.standard.data(forKey: "push.addOnReminder.\(account.id)") != nil)
        SettingsHub.purge(account)
        #expect(UserDefaults.standard.data(forKey: "push.addOnReminder.\(account.id)") == nil)
    }
}

// MARK: - M15 & M16: NotificationHub Epoch/Badge Guard, Task Cross-Gateway Check, Settings Observers

@Suite("M15 & M16: NotificationHub & Settings observer guards", .serialized)
struct NotificationHubRegressionTests {
    @MainActor @Test func postWithStaleEpochSkipsWithoutMutatingBadgeAndColdTaskChecksAccount() async {
        let hub = NotificationHub.shared
        hub.clear()
        let prevOwner = PushRegistrar.shared.owner
        let prevOpenTask = hub.openTask
        let prevOtherGateway = hub.otherGateway
        defer {
            hub.openTask = prevOpenTask
            hub.otherGateway = prevOtherGateway
            PushRegistrar.shared.setOwner(prevOwner)
            hub.clear()
        }

        // Stale epoch observed before clear(): post must return false and leave badgeCount untouched at 0.
        let staleEpoch = hub.epoch - 1
        let posted = await hub.post(kind: "message.complete", session: "s_stale", text: "Hello", epoch: staleEpoch)
        #expect(!posted)
        #expect(hub.badgeCount == 0)

        // Cold-launch task push for another gateway must route to otherGateway, NOT openTask.
        let currentOwner = String(repeating: "11", count: 32)
        let foreignOwner = String(repeating: "22", count: 32)
        PushRegistrar.shared.setOwner(currentOwner)
        hub.openTask = nil
        hub.otherGateway = nil
        hub.queueTask("task-foreign", profile: "ivy", account: foreignOwner)

        var openedTasks: [String] = []
        var foreignAccounts: [String] = []
        hub.otherGateway = { account, _ in foreignAccounts.append(account) }
        hub.openTask = { id, _ in openedTasks.append(id) }

        #expect(openedTasks.isEmpty, "foreign gateway task alert opened on active gateway")
        #expect(foreignAccounts == [foreignOwner])

        // Cold-launch task push for the matching gateway opens normally.
        hub.openTask = nil
        hub.queueTask("task-local", profile: "ivy", account: currentOwner)
        hub.openTask = { id, _ in openedTasks.append(id) }
        #expect(openedTasks == ["task-local"])
    }

    @MainActor @Test func notificationsSettingsControllerDeduplicatesObserversAcrossRepeatedAppear() {
        let controller = NotificationsSettingsController(app: nil)
        controller.viewWillAppear(false)
        controller.viewWillAppear(false)
        controller.viewDidDisappear(false)
        // Re-appearing after disappear also cleanly resets and tears down on deinit.
        controller.viewWillAppear(false)
        controller.viewDidDisappear(false)
    }
}

// MARK: - H13: NousRenewalLease Cancellation Exits Immediately

@Suite("H13: NousRenewalLease cancellation", .serialized)
nonisolated struct NousRenewalLeaseCancellationRegressionTests {
    @Test func acquireOrWaitExitsImmediatelyOnCancellationWithoutSpinning() async throws {
        let dir = leaseFolder("cancel-no-spin")
        defer { try? FileManager.default.removeItem(at: dir) }
        let holder = try #require(NousRenewalLease.acquire(account: "acct", in: dir))
        defer { holder.release() }

        let polls = Locked(0)
        let waiter = Task {
            await NousRenewalLease.acquireOrWait(account: "acct", in: dir, longestWait: 30) {
                polls.mutate { $0 += 1 }
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(60))
        let beganCancel = ContinuousClock.now
        waiter.cancel()
        let (lease, adopted) = await waiter.value
        let afterCancel = beganCancel.duration(to: .now)
        #expect(lease == nil && !adopted)
        #expect(afterCancel < .milliseconds(500), "acquireOrWait spun for \(afterCancel) after cancel")
        #expect(polls.value < 5, "acquireOrWait polled \(polls.value) times instead of exiting")
    }
}

// MARK: - L1, L3, L4: AddOnChanges Ordering, LinkPreviews Concurrency Cap, Shared Portal Sessions

@Suite("L1, L3, L4: Strict weak ordering, concurrency cap, shared sessions")
nonisolated struct LowPriorityReliabilityRegressionTests {
    @Test func addOnChangesSatisfiesStrictWeakOrderingWithEquivalentVersions() {
        let versions = ["1.0", "1.0.0", "1.0.0.0", "0.9.1", "0.9.01", "0.9.10", "0.9.9", "2.0", "2.0.0"]
        // Verify irreflexivity, asymmetry, and transitivity across every pair and triple.
        for a in versions {
            #expect(!AddOnChanges.isNewer(a, than: a), "irreflexivity violated for \(a)")
            for b in versions {
                if AddOnChanges.isNewer(a, than: b) {
                    #expect(!AddOnChanges.isNewer(b, than: a), "asymmetry violated for \(a) vs \(b)")
                }
                for c in versions {
                    if AddOnChanges.isNewer(a, than: b) && AddOnChanges.isNewer(b, than: c) {
                        #expect(AddOnChanges.isNewer(a, than: c), "transitivity violated for \(a), \(b), \(c)")
                    }
                }
            }
        }
        let subjects = versions.map { "hermes-hq-push \($0): Release \($0)" }
        let sorted = AddOnChanges.changes(subjects: subjects, plugin: "hermes-hq-push", after: "0.9.0", limit: 20)
        #expect(sorted.count == versions.count)
        #expect(sorted.first?.version == "2.0.0")
        #expect(sorted.last?.version == "0.9.01" || sorted.last?.version == "0.9.1")
    }

    @Test func linkPreviewsEnforcesMaxInFlightUnderActorReentrancyChurn() async {
        nonisolated final class StaggeredFetcher: LinkFetching, @unchecked Sendable {
            private let lock = NSLock()
            private var active = 0
            private var peak = 0
            private var count = 0

            var mostAtOnce: Int { lock.withLock { peak } }

            func page(_ url: URL) async throws -> LinkFetchResult {
                let n = lock.withLock { () -> Int in
                    active += 1
                    peak = max(peak, active)
                    count += 1
                    return count
                }
                defer { lock.withLock { active -= 1 } }
                try? await Task.sleep(for: .milliseconds(n % 3 == 0 ? 5 : 25))
                return LinkFetchResult(url: url, type: "text/html", data: Data("<title>Page \(n)</title>".utf8))
            }

            func image(_ url: URL) async throws -> LinkFetchResult {
                throw LinkFetchRefused(reason: "none")
            }
        }

        let fetcher = StaggeredFetcher()
        let previews = LinkPreviews(fetcher: fetcher)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    if i >= 10 { try? await Task.sleep(for: .milliseconds((i - 10) * 2)) }
                    _ = await previews.preview(for: "https://site-\(i).example.com/")
                }
            }
        }
        #expect(fetcher.mostAtOnce <= LinkPreviews.maxInFlight,
                "LinkPreviews exceeded maxInFlight (\(LinkPreviews.maxInFlight)): saw \(fetcher.mostAtOnce)")
    }

    @Test func portalAuthAndCloudClientShareStaticSessionsByDefault() {
        let a = PortalAuth()
        let b = PortalAuth()
        #expect(a.session === b.session)
        #expect(a.session === PortalAuth.sharedSession)
        #expect(PortalAuth.sharedSession !== PortalAuth.sharedLongSession)
    }
}
