// Crash hunt for build 3 (SIGABRT on a cooperative thread while the Artifacts page was reading): the Artifacts pass
// (per-profile listing group + the index's session-read group) run many times over, with answers that land at random
// moments, fail, or are cancelled mid-flight by refreshes, scope changes and sign-out resets.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor
struct ArtifactsStressTests {
    private static let profiles = ["default", "inbox", "deploys", "research", "finance"]

    nonisolated private static func session(_ profile: String, _ n: Int, bump: Int) -> JSONValue {
        .object(["id": .string("s-\(profile)-\(n) 😀"), "profile": .string(profile), "title": .string("T \(n) 👩‍👩‍👧‍👦\r\n"),
                 "message_count": .number(Double(2 + bump)), "last_active": .number(Double(1_000_000 + n * 7 + bump)),
                 "started_at": .number(1_000_000), "cwd": .string("/home/hermes/wörk")])
    }

    nonisolated private static func messages(_ n: Int) -> JSONValue {
        let text = "Saved /home/hermes/öut/résumé 😀.pdf\r\n![x](/home/hermes/img/😀.png) https://example.com/a/\(n).png MEDIA:`/home/hermes/m/😀 f.png`"
        return .object(["messages": .array([
            .object(["role": "assistant", "content": .string(text), "timestamp": .number(Double(2_000_000 + n))]),
            .object(["role": "tool", "tool_name": "write_file", "content": .string(#"{"path": "/home/hermes/w/😀.md", "files_created": [3, null]}"#)]),
        ]), "pagination": .object(["limit": 100])])
    }

    /// The build-3 crash in the simulator: More › Artifacts › Try Again with the gateway down (every listing fails at
    /// once) aborted with "libc++abi: Pure virtual function called!".
    @Test(.timeLimit(.minutes(2))) func everyListingFailingAtOnceDoesNotAbort() async throws {
        let client = PagesFakeClient { _ in throw URLError(.cannotConnectToHost) }
        let store = ArtifactsStore(client: client, account: client.account, directory: nil)
        store.profilesProvider = { Self.profiles }
        store.pageShown()
        for _ in 0..<300 {
            store.refresh(explicit: true)
            for _ in 0..<200 where store.refreshing { await Task.yield() }
        }
        for _ in 0..<500 where store.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.loadError != nil)
    }

    /// The per-profile listing alone (the group that aborted under -O in the simulator), many times over.
    @Test(.timeLimit(.minutes(2))) func perProfileListingManyTimes() async throws {
        let client = PagesFakeClient { request in
            let roll = Int.random(in: 0..<4)
            if roll == 0 { await Task.yield() }
            if roll == 1 { throw URLError(.cannotConnectToHost) }
            return .object(["sessions": .array([Self.session(request.query["profile"] ?? "default", roll, bump: 0)])])
        }
        let store = ArtifactsStore(client: client, account: client.account, directory: nil)
        store.profilesProvider = { Self.profiles }
        var listed = 0
        for _ in 0..<3000 {
            if let listing = try? await store.listSessions(scope: "all") { listed += listing.sessions.count }
        }
        #expect(listed > 0)
    }

    @Test(.timeLimit(.minutes(5))) func passesSurviveRandomTimingFailuresAndCancellation() async throws {
        let bump = Atomic<Int>(0)
        let client = PagesFakeClient { request in
            // Land at random moments on the cooperative pool (some at once, some after a short wait).
            let roll = Int.random(in: 0..<10)
            if roll < 3 { try await Task.sleep(nanoseconds: UInt64.random(in: 0...2_000_000)) } else if roll < 6 { await Task.yield() }
            if request.path == ArtifactsStore.sessionsPath {
                if roll == 9 { throw httpError(503, "busy") }
                let profile = request.query["profile"] ?? "default"
                let b = bump.load(ordering: .relaxed)
                return .object(["sessions": .array((0..<12).map { Self.session(profile, $0, bump: b) })])
            }
            if roll == 8 { throw httpError(500, "nope") }
            if roll == 7 { throw URLError(.timedOut) }
            return Self.messages(roll)
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "artifacts-stress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArtifactsStore(client: client, account: client.account, directory: dir)
        store.profilesProvider = { Self.profiles }
        store.index.progressInterval = 0
        store.index.saveInterval = 0
        var changes = 0
        store.onChange = { changes += 1 }
        store.pageShown()
        for round in 0..<1500 {
            bump.add(1, ordering: .relaxed)            // every session changed: every pass reads them all again
            switch round % 9 {
            case 0: store.setScope(Self.profiles[round % Self.profiles.count])
            case 1: store.setScope("all")
            case 4: store.reset()
            default: break
            }
            store.refresh(explicit: true)
            try await Task.sleep(nanoseconds: UInt64.random(in: 0...(round % 4 == 0 ? 25_000_000 : 3_000_000)))
        }
        // Let the last pass finish.
        for _ in 0..<500 where store.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.refreshing)
        #expect(changes > 0)
    }
}
