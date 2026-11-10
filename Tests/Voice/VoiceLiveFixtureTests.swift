// A-L1…A-L3 (docs/spec/1x-voice.md §9): the memo pipeline and playback against the running voice stand-in gateway
// (scripts/fixtures/voice-gateway.py on 127.0.0.1:9728). Enabled only when the run passes
//   TEST_RUNNER_HQ_VOICE_FIXTURE="http://127.0.0.1:9728|$PWD/build/fixtures/voice.json" scripts/build.sh test <udid>
// One password sign-in per test (never in a loop); all data is the fixture's invented state.

import AVFAudio
import Foundation
import Testing
@testable import HermesHQNative

nonisolated enum VoiceFixture {
    static var config: (base: URL, username: String, password: String)? {
        guard let raw = ProcessInfo.processInfo.environment["HQ_VOICE_FIXTURE"], let bar = raw.firstIndex(of: "|"),
              let base = URL(string: String(raw[..<bar])),
              let data = FileManager.default.contents(atPath: String(raw[raw.index(after: bar)...])),
              let creds = try? ChatJSON.parse(data), let user = creds["username"]?.string, let pass = creds["password"]?.string,
              ["127.0.0.1", "localhost", "::1"].contains(base.host() ?? "") else { return nil }
        return (base, user, pass)
    }
    static var available: Bool { config != nil }
    static var port: UInt16 { UInt16(config?.base.port ?? 9728) }
}

@Suite("Voice fixture (live)", .serialized, .enabled(if: VoiceFixture.available))
@MainActor
struct VoiceLiveFixtureTests {
    let ivy = "20260929_120000_aabbcc02"

    private func signIn() async throws -> (LiveGatewayClient, SignInService) {
        let config = try #require(VoiceFixture.config)
        let vault = Fixtures.testVault("voice")
        vault.removeAll()
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: config.base.absoluteString, username: config.username,
                                                           password: config.password)
        let client = service.client(for: account)
        try await waitFor(client, .ready)
        VoiceTestStores.activate(account.id)
        return (client, service)
    }

    @discardableResult
    private func control(_ path: String, _ json: [String: Any]? = nil, method: String = "POST") async throws -> JSONValue {
        try await Fixtures.control(VoiceFixture.port, path, method: method, json: json)
    }

    private func session(_ client: LiveGatewayClient) async -> LiveChatSession {
        let s = LiveChatSession(client: client, account: client.account, profile: "ivy", storedSessionId: ivy, title: "Ivy",
                                head: nil, cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        s.start()
        _ = await waitUntil(timeout: .seconds(10)) { s.openSettled }
        return s
    }

    @Test func aMemoGoesEndToEndExactlyOnce() async throws {
        try await control("/__fixture/voice", ["reset": true])
        let (client, _) = try await signIn()
        defer { client.shutdown(); Fixtures.testVault("voice").removeAll() }
        let memo = try VoiceTestStores.recording(client.account.id, seconds: 3)
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(15)) { !s.isRunning && s.messages.contains { $0.plainText.contains("Synthetic transcript") } })
        try await Task.sleep(for: .milliseconds(400))
        let state = try await control("/__fixture/voice-state", method: "GET")
        #expect(state["filesReads"]?.int == 1)
        #expect(state["uploads"]?.array?.count == 1)
        #expect(state["attaches"]?.array?.count == 1)
        #expect(state["deletes"]?.array?.count == 1)
        #expect(state["transcribes"]?.array?.count == 1)
        let prompts = state["prompts"]?.array ?? []
        #expect(prompts.count == 1)
        let stored = try #require(state["attaches"]?[0]?["stored"]?.string)
        #expect(stored.hasSuffix(".hermes/profiles/ivy/attachments/voice-memo.wav") || stored.contains("/profiles/ivy/attachments/voice-memo-"))
        let expected = MemoText.reference(path: stored, said: .text("Synthetic transcript of a 3 s voice memo."))
        #expect(prompts.first?["text"]?.string == expected)
        // The history read back parses as a memo with that transcript.
        let page = try JSONValue.parse(try await client.get("/api/sessions/\(ivy)/messages", [URLQueryItem(name: "profile", value: "ivy")]))
        let last = page["messages"]?.array?.last { $0["role"]?.string == "user" }
        let parsed = try #require(VoiceMemo.parse(last?["content"]?.string ?? ""))
        #expect(parsed.path == stored)
        #expect(parsed.transcript == .text("Synthetic transcript of a 3 s voice memo."))
    }

    @Test func aSeededMemoDownloadsPlaysAndComputes() async throws {
        try await control("/__fixture/voice", ["reset": true])
        let seeded = try await control("/__fixture/memo-history", ["profile": "ivy", "memos": [["seconds": 4, "transcript": "Seeded."],
                                                                                              ["seconds": 2, "missing": true]], "reply": ""])
        let paths = seeded["paths"]?.array?.compactMap(\.string) ?? []
        #expect(paths.count == 2)
        let (client, _) = try await signIn()
        defer { client.shutdown(); Fixtures.testVault("voice").removeAll() }
        let cache = try #require(MemoAccountStores.shared.cache)
        let url = try await cache.fetch(paths[0], profile: "ivy", client: client)
        let player = try AVAudioPlayer(contentsOf: url)
        #expect(abs(player.duration - 4) < 0.05)
        let (peaks, seconds) = try MemoWaveform.compute(url)
        #expect(peaks.count == 48 && abs(seconds - 4) < 0.05)
        // Fetched once: a second ask is a cache hit.
        #expect(cache.local(for: paths[0]) == url)
        // The missing memo answers 404, which the bubble shows as "Couldn’t load audio".
        await #expect(throws: HTTPError.self) { _ = try await cache.fetch(paths[1], profile: "ivy", client: client) }
        do { _ = try await cache.fetch(paths[1], profile: "ivy", client: client) } catch let error as HTTPError { #expect(error.status == 404) }
    }

    @Test func sttOffStoresTheOffWording() async throws {
        try await control("/__fixture/voice", ["reset": true])
        try await control("/__fixture/voice", ["stt": ["default": false]])
        let (client, _) = try await signIn()
        defer { client.shutdown(); Fixtures.testVault("voice").removeAll() }
        let memo = try VoiceTestStores.recording(client.account.id)
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(15)) { !s.isRunning })
        let state = try await control("/__fixture/voice-state", method: "GET")
        #expect(state["transcribes"]?.array?.count == 0)
        #expect(state["prompts"]?[0]?["text"]?.string?.hasSuffix("Voice memo transcript: (unavailable: speech-to-text is off on the gateway)") == true)
    }
}
