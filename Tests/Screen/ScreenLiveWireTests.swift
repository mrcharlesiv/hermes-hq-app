// The real stream and RFB client against the stand-in gateway over loopback (scripts/fixtures/screen-gateway.py).
// Enabled only when the run passes `TEST_RUNNER_HQN_SCREEN_FIXTURE=<base url>|<credentials json path>`; the fixture
// must be one this stream started on its own port:
//   python3 scripts/fixtures/screen-gateway.py --port 9941 --credentials build/fixtures/screen-9941.json \
//     --frames build/fixtures/screen-frames &
//   TEST_RUNNER_HQN_SCREEN_FIXTURE="http://127.0.0.1:9941|$PWD/build/fixtures/screen-9941.json" …
// Nothing here is a real desktop: every frame, lease and input is the fixture's.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated enum ScreenFixture {
    static var config: (base: URL, username: String, password: String)? {
        guard let raw = ProcessInfo.processInfo.environment["HQN_SCREEN_FIXTURE"], let bar = raw.firstIndex(of: "|"),
              let base = URL(string: String(raw[..<bar])),
              let data = FileManager.default.contents(atPath: String(raw[raw.index(after: bar)...])),
              let creds = try? JSONValue.parse(data), let user = creds["username"]?.string, let pass = creds["password"]?.string,
              ["127.0.0.1", "localhost"].contains(base.host() ?? "") else { return nil }
        return (base, user, pass)
    }
    static var available: Bool { config != nil }

    private static func request(_ path: String, _ body: [String: Any]?) async throws -> JSONValue {
        guard let base = config?.base else { return .null }
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 10)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: request)
        return (try? JSONValue.parseFast(data)) ?? .null
    }

    @discardableResult static func control(_ body: [String: Any]) async throws -> JSONValue { try await request("/__fixture/screen", body) }
    static func reset() async throws { _ = try await request("/__fixture/screen/reset", [:]) }
    static func ledger() async throws -> JSONValue { try await request("/__fixture/screen", nil) }
    static func expected() async throws -> JSONValue { try await request("/__fixture/screen/expect", nil) }
}

extension LoopbackGatewayClient: GatewayDisplaySockets {
    func displaySocket(path: String, ticket: String) async throws -> any ScreenSocketing {
        guard let url = ScreenWire.displaySocketURL(base: base, path: path, ticket: ticket) else { throw GatewayFailure.invalidURL }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return ScreenSocket(session.webSocketTask(with: URLRequest(url: url, timeoutInterval: 15)))
    }
}

@Suite("Screen stream against the stand-in gateway (live socket)", .serialized, .enabled(if: ScreenFixture.available))
@MainActor
struct ScreenLiveWireTests {
    private func connect() async throws -> LoopbackGatewayClient {
        let config = try #require(ScreenFixture.config)
        let client = LoopbackGatewayClient(base: config.base)
        try await client.signIn(username: config.username, password: config.password)
        try await client.connect()
        return client
    }

    /// observe + dial + stream. Returns the stream, what it reported, and the viewer.
    private func attach(_ client: LoopbackGatewayClient, viewer: String? = nil, stuckAfter: TimeInterval = 8,
                        firstPictureWait: TimeInterval = 20) async throws -> (ScreenStream, StreamProbe, ScreenObserved) {
        let answer = try await client.call("display.observe", ScreenWire.observeParams(profile: "default", viewerId: viewer), timeout: ScreenWire.observeTimeout)
        let observed = try #require(ScreenObserved.parse(answer))
        let socket = try await client.displaySocket(path: observed.path, ticket: observed.ticket)
        let probe = StreamProbe()
        let stream = ScreenStream(socket: socket, stuckAfter: stuckAfter, firstPictureWait: firstPictureWait,
                                  onReady: { w, h in probe.ready.append((w, h)) },
                                  onFrame: { image, w, h, serial in probe.lastImage = image; probe.frames.append((w, h, serial, 0)) },
                                  onEnd: { probe.ends.append($0) })
        stream.start()
        return (stream, probe, observed)
    }

    private func closeTo(_ a: String, _ b: String, _ tolerance: Int) -> Bool {
        guard a.count == b.count, a.count == 30 else { return false }
        func bytes(_ text: String) -> [Int] { stride(from: 0, to: 30, by: 2).map { Int(text.dropFirst($0).prefix(2), radix: 16) ?? -999 } }
        return zip(bytes(a), bytes(b)).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test func everyEncodingShowsTheFixturesOwnPicture() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        for (mode, encoding, lossless) in [("mac", "tight-jpeg", false), ("linux", "mixed", true), ("linux", "tight-basic", true),
                                           ("linux", "raw", true), ("linux", "copyrect", true)] {
            try await ScreenFixture.reset()
            try await ScreenFixture.control(["mode": mode, "stream": ["encoding": encoding, "fps": 30]])
            let (stream, probe, observed) = try await attach(client)
            #expect(await screenWait(10) { probe.frames.count >= 8 }, "\(encoding): frames \(probe.frames.count), ends \(probe.ends)")
            #expect(probe.ready.first.map { $0 == (1280, 800) } == true && observed.status.running)
            stream.stop(handBack: false)
            try await Task.sleep(for: .milliseconds(400))
            let expected = try await ScreenFixture.expected()
            let want = expected["probe"]?.string ?? "", got = stream.pacing.probe
            if lossless { #expect(got == want, "\(encoding)") } else { #expect(closeTo(got, want, 40), "\(encoding): \(got) vs \(want)") }
            let ledger = try await ScreenFixture.ledger()
            #expect(ledger["max_outstanding_requests"]?.int == 1, "\(encoding)")
            #expect(ledger["unknown_params"]?.array?.isEmpty == true && ledger["forbidden_calls"]?.int == 0)
            #expect((ledger["set_encodings"]?.array ?? []).compactMap(\.int) == [7, 1, 0, -25, -254, -224, -223, -308])
            let kinds = Set((ledger["client_messages"]?.object ?? [:]).keys)
            let watchOnly = kinds.isSubset(of: ["0", "2", "3"])
            #expect(watchOnly, "watching sends no input: \(kinds)")
            #expect(stream.pacing.mainThreadDecodes == 0 && stream.pacing.failedJPEGs == 0)
            #expect(probe.ends.isEmpty)
        }
    }

    @Test func anySplitOfTheByteStreamGivesTheSamePicture() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        var seen: Set<String> = []
        for chunk in [1, 7, 65_536] {
            try await ScreenFixture.reset()
            try await ScreenFixture.control(["mode": "linux", "stream": ["chunk": chunk, "fps": 30, "size": [640, 480]]])
            let (stream, probe, _) = try await attach(client)
            #expect(await screenWait(40) { probe.frames.count >= 3 }, "chunk \(chunk): \(probe.frames.count) frames, ends \(probe.ends)")
            stream.stop(handBack: false)
            try await Task.sleep(for: .milliseconds(300))
            let want = try await ScreenFixture.expected()["probe"]?.string ?? ""
            #expect(stream.pacing.probe == want, "chunk \(chunk)")
            seen.insert(stream.pacing.probe)
        }
        #expect(seen.count == 1)
    }

    @Test func aResizeMidStreamIsFollowed() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "mac", "stream": ["fps": 30]])
        let (stream, probe, _) = try await attach(client)
        #expect(await screenWait(10) { probe.frames.count >= 3 })
        for size in [[1920, 1080], [1280, 800], [1920, 1080]] {
            try await ScreenFixture.control(["stream": ["size": size]])
            #expect(await screenWait(10) { probe.frames.last.map { $0.width == size[0] && $0.height == size[1] } == true }, "\(size)")
            let before = probe.frames.count
            #expect(await screenWait(10) { probe.frames.count >= before + 3 })
        }
        #expect(probe.lastImage?.width == 1920 && probe.ends.isEmpty)
        #expect(try await ScreenFixture.ledger()["max_outstanding_requests"]?.int == 1)
        stream.stop(handBack: false)
    }

    @Test func inputIsAcceptedOnlyWhileHoldingAndClosingWith1000HandsBack() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "mac"])
        let (stream, probe, observed) = try await attach(client)
        #expect(await screenWait(10) { probe.frames.count >= 2 })
        stream.send(RFBMessage.pointer(mask: 0, x: 10, y: 10))                  // watching: the gateway drops it
        try await Task.sleep(for: .milliseconds(300))
        var ledger = try await ScreenFixture.ledger()
        #expect(ledger["inputs"]?.array?.isEmpty == true && ledger["dropped_inputs"]?.int == 1)
        let taken = try await client.call("display.lease.acquire", ScreenWire.acquireParams(profile: "default", viewerId: observed.viewer.id), timeout: ScreenWire.leaseTimeout)
        #expect(ScreenWire.holds(ScreenLease.parse(taken["lease"]), observed.viewer))
        stream.send(RFBMessage.pointer(mask: 0, x: 640, y: 400))
        stream.send(RFBMessage.pointer(mask: 1, x: 640, y: 400))
        stream.send(RFBMessage.pointer(mask: 0, x: 640, y: 400))
        for (keysym, down) in [(0xFFE3, true), (0x63, true), (0x63, false), (0xFFE3, false)] as [(UInt32, Bool)] { stream.send(RFBMessage.key(keysym, down: down)) }
        stream.send(RFBMessage.cutText(Array("Hello".utf8)))
        try await Task.sleep(for: .milliseconds(500))
        ledger = try await ScreenFixture.ledger()
        let inputs = ledger["inputs"]?.array ?? []
        #expect(inputs.count == 8)
        #expect(inputs.prefix(3).map { $0["mask"]?.int } == [0, 1, 0] && inputs[1]["x"]?.int == 640 && inputs[1]["y"]?.int == 400)
        #expect(inputs[3..<7].map { $0["keysym"]?.int } == [0xFFE3, 0x63, 0x63, 0xFFE3] && inputs[3..<7].map { $0["down"]?.bool } == [true, true, false, false])
        #expect(inputs[7]["kind"]?.string == "cut" && inputs[7]["text"]?.string == "Hello" && inputs[7]["length"]?.int == 5)
        let kinds = Set((ledger["client_messages"]?.object ?? [:]).keys)
        #expect(kinds == ["0", "2", "3", "4", "5", "6"])
        // Leaving while holding: a 1000 close frame, which hands the lease back.
        stream.stop(handBack: true, flush: [RFBMessage.pointer(mask: 0, x: 640, y: 400)])
        try await Task.sleep(for: .milliseconds(800))
        ledger = try await ScreenFixture.ledger()
        #expect(ledger["sockets"]?.array?.last?["close_code"]?.int == 1000)
        #expect(ledger["lease"]?["holder"]?.string == "agent" && ledger["open_sockets"]?.int == 0)
    }

    @Test func aPauseSendsNoCloseFrameAndKeepsTheLease() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "mac"])
        let (stream, probe, observed) = try await attach(client)
        #expect(await screenWait(10) { probe.frames.count >= 2 })
        _ = try await client.call("display.lease.acquire", ScreenWire.acquireParams(profile: "default", viewerId: observed.viewer.id), timeout: ScreenWire.leaseTimeout)
        stream.stop(handBack: false)
        try await Task.sleep(for: .milliseconds(800))
        var ledger = try await ScreenFixture.ledger()
        let last = try #require(ledger["sockets"]?.array?.last)
        // URLSession's plain cancel() sends a close frame with no status (the gateway reads 1005), exactly what the web
        // app's `socket.close()` gave: anything but 1000/1001 is a dropped link to the gateway, so the lease is kept.
        let code = last["close_code"]?.int
        #expect(last["closed_at"]?.double != nil && (code == nil || code == 1005), "never 1000 or 1001: \(String(describing: code))")
        #expect(ledger["lease"]?["holder"]?.string == "human" && ledger["lease"]?["viewer_hash"]?.string == observed.viewer.hash)
        // The same connection attaches again with its id and is still the holder; then gives it back by id.
        let (again, second, minted) = try await attach(client, viewer: observed.viewer.id)
        #expect(await screenWait(10) { second.frames.count >= 2 })
        #expect(minted.viewer.id == observed.viewer.id && ScreenWire.holds(minted.status.lease, minted.viewer))
        let released = try await client.call("display.lease.release", ScreenWire.releaseParams(profile: "default", viewerId: minted.viewer.id, force: false), timeout: ScreenWire.leaseTimeout)
        #expect(ScreenLease.parse(released["lease"])?.holder == .agent)
        again.stop(handBack: false)
        ledger = try await ScreenFixture.ledger()
        #expect(ledger["unknown_params"]?.array?.isEmpty == true)
    }

    @Test func gatewayCloseCodesArriveAsTheyWereSent() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        for code in [4000, 4001, 4401, 1003] {
            try await ScreenFixture.reset()
            try await ScreenFixture.control(["mode": "mac", "stream": ["fps": 30]])
            let (kept1, probe, _) = try await attach(client)
            defer { kept1.stop(handBack: false) }
            #expect(await screenWait(10) { probe.frames.count >= 2 })
            try await ScreenFixture.control(["stream": ["close_code": code]])
            #expect(await screenWait(10) { !probe.ends.isEmpty }, "\(code)")
            if case .closed(let got, _)? = probe.ends.first { #expect(got == code) } else { Issue.record("\(code): \(probe.ends)") }
        }
        // A cut link has no code.
        try await ScreenFixture.reset()
        let (kept2, probe, _) = try await attach(client)
        defer { kept2.stop(handBack: false) }
        #expect(await screenWait(10) { probe.frames.count >= 2 })
        try await ScreenFixture.control(["stream": ["drop": true]])
        #expect(await screenWait(10) { probe.ends == [.closed(code: nil, reason: nil)] }, "\(probe.ends)")
        // A used or rejected ticket is refused with 4401 before any frame.
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["tickets": ["reject": true]])
        let (kept3, refused, _) = try await attach(client)
        defer { kept3.stop(handBack: false) }
        #expect(await screenWait(10) { !refused.ends.isEmpty })
        if case .closed(let got, _)? = refused.ends.first { #expect(got == 4401) } else { Issue.record("\(refused.ends)") }
    }

    @Test func badDataEndsInATypedErrorOrIsSurvived() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        let fatal: [(String, ScreenStream.End)] = [
            ("bad-version", .failed("bad-version")), ("security-none-missing", .failed("no-security")), ("security-failed", .failed("security-failed")),
            ("zero-size", .failed("bad-size")), ("huge-size", .failed("bad-size")), ("rect-outside", .failed("rect-outside")),
            ("unknown-encoding", .failed("unknown-encoding")), ("unknown-message", .failed("unknown-message")), ("zlib-garbage", .failed("zlib")),
            ("zlib-truncated", .failed("zlib")), ("jpeg-garbage-3", .failed("bad-jpegs")), ("palette-zero", .failed("bad-filter")),
            ("copyrect-outside", .failed("rect-outside")), ("cut-text-huge", .failed("too-long")), ("text-frame", .failed("text-frame")),
        ]
        for (name, expected) in fatal {
            try await ScreenFixture.reset()
            try await ScreenFixture.control(["mode": "linux", "stream": ["garbage": name, "fps": 30, "size": [640, 480]]])
            let (kept4, probe, _) = try await attach(client)
            defer { kept4.stop(handBack: false) }
            #expect(await screenWait(10) { !probe.ends.isEmpty }, "\(name)")
            #expect(probe.ends == [expected], "\(name): \(probe.ends)")
        }
        for name in ["jpeg-garbage", "trailing-bytes", "never-ending-update", "colour-map-huge"] {
            try await ScreenFixture.reset()
            try await ScreenFixture.control(["mode": "linux", "stream": ["garbage": name, "fps": 30, "size": [640, 480]]])
            let (stream, probe, _) = try await attach(client)
            #expect(await screenWait(20) { probe.frames.count >= 8 }, "\(name) keeps streaming: \(probe.frames.count) frames, ends \(probe.ends)")
            #expect(probe.ends.isEmpty, "\(name)")
            if name == "jpeg-garbage" { #expect(stream.pacing.failedJPEGs == 1) }
            stream.stop(handBack: false)
        }
        // The largest length Tight can declare is waited for, and the stuck rule ends it (2 s here instead of 8).
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "linux", "stream": ["garbage": "tight-length-overflow", "fps": 30, "size": [640, 480]]])
        let (kept5, probe, _) = try await attach(client, stuckAfter: 2)
        defer { kept5.stop(handBack: false) }
        #expect(await screenWait(10) { probe.ends == [.stuck] }, "\(probe.ends)")
    }

    @Test func aStalledUpdateIsStuckAndASlowOneIsNot() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "mac", "stream": ["stall_after": 3, "fps": 30]])
        let (kept6, stalled, _) = try await attach(client, stuckAfter: 2)
        defer { kept6.stop(handBack: false) }
        #expect(await screenWait(10) { stalled.ends == [.stuck] }, "\(stalled.ends)")
        // 256 kbit/s with 150 ms of delay: slow, but bytes keep coming, so nothing ends.
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "mac", "stream": ["throttle_kbps": 256, "delay_ms": 150, "size": [640, 480]]])
        let (stream, slow, _) = try await attach(client, stuckAfter: 2)
        #expect(await screenWait(30) { slow.frames.count >= 2 }, "\(slow.frames.count) frames, ends \(slow.ends)")
        #expect(slow.ends.isEmpty)
        stream.stop(handBack: false)
    }

    /// Review finding 3: the Mac helper sends a picture only once it has one. A handshake followed by silence is not a
    /// stuck stream until the first-picture wait is over, and then it ends as "no picture", not as stuck.
    @Test func aFirstPictureMayComeLateAndOneThatNeverComesEndsAsNoPicture() async throws {
        let client = try await connect()
        defer { client.shutdown() }
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "mac", "stream": ["first_frame_delay_ms": 4000]])
        let (late, probe, _) = try await attach(client, stuckAfter: 2, firstPictureWait: 15)
        #expect(await screenWait(5) { probe.ready.count == 1 }, "the handshake finishes at once")
        try await Task.sleep(for: .milliseconds(2600))
        #expect(probe.ends.isEmpty && probe.frames.isEmpty, "past the 2 s stuck limit with no picture: still waiting")
        #expect(await screenWait(15) { probe.frames.count >= 1 }, "\(probe.frames.count) frames, ends \(probe.ends)")
        #expect(probe.ends.isEmpty)
        late.stop(handBack: false)

        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "mac", "stream": ["first_frame_delay_ms": -1]])
        let (never, silent, _) = try await attach(client, stuckAfter: 2, firstPictureWait: 3)
        defer { never.stop(handBack: false) }
        #expect(await screenWait(15) { silent.ends == [.noPicture] }, "\(silent.ends)")
        #expect(silent.frames.isEmpty)
        try await Task.sleep(for: .milliseconds(500))
        let ledger = try await ScreenFixture.ledger()
        let code = ledger["sockets"]?.array?.last?["close_code"]?.int
        #expect(code != 1000 && code != 1001, "ended without a hand-back close: \(String(describing: code))")
    }

    /// Review finding 2: sign-out and gateway switch end the client (and every socket on its session) right after
    /// the Screen leaves. The hand-back must already be the gateway's truth by then.
    @Test func handingBackBeforeTheClientDiesReachesTheGateway() async throws {
        let client = try await connect()
        try await ScreenFixture.reset()
        try await ScreenFixture.control(["mode": "linux"])
        let name = "screen-live-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let holds = ScreenHolds(defaults: defaults)
        // The display socket lives on a session this test kills at once, as HTTPTransport.invalidate() does.
        let sockets = URLSession(configuration: .ephemeral)
        let base = try #require(ScreenFixture.config?.base)
        let service = ScreenService(client: client, holds: holds) { path, ticket in
            guard let url = ScreenWire.displaySocketURL(base: base, path: path, ticket: ticket) else { throw GatewayFailure.invalidURL }
            return ScreenSocket(sockets.webSocketTask(with: URLRequest(url: url, timeoutInterval: 15)))
        }
        let session = service.session(profile: "default", name: "Hermes")
        session.open()
        #expect(await screenWait(15) { session.phase == .live })
        session.takeOver()
        #expect(await screenWait(10) { session.holding && session.busy == nil })
        #expect(holds.saved(client.account.id, "default") != nil)
        var ledger = try await ScreenFixture.ledger()
        #expect(ledger["lease"]?["holder"]?.string == "human")

        await service.handBackBeforeLeaving()
        service.shutdown()
        sockets.invalidateAndCancel()               // everything on the transport is cancelled in the same breath
        client.shutdown()

        ledger = try await ScreenFixture.ledger()   // no waiting: it is already true
        #expect(ledger["lease"]?["holder"]?.string == "agent", "the bot has control again: \(String(describing: ledger["lease"]))")
        #expect(holds.saved(client.account.id, "default") == nil && holds.own(client.account.id, "default") == nil)
    }
}
