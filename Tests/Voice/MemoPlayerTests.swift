// MemoPlayer builds and primes its player off the main thread; a stop or another memo while that runs must win.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Memo player", .serialized)
@MainActor
struct MemoPlayerTests {
    private func wave(_ seconds: Double = 2) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("memo-player-\(UUID().uuidString).wav")
        try? MemoRecorder.fixtureWave(seconds: seconds, levels: [0.3, 0.6, 0.9]).write(to: url)
        return url
    }

    @Test func playLoadsThenPlays() async {
        let player = MemoPlayer()
        defer { player.stop() }
        let url = wave()
        player.play(url.path) { url }
        #expect(player.state(of: url.path) == .loading)
        #expect(await waitUntil(timeout: .seconds(5)) { player.state(of: url.path) == .playing })
        #expect(player.duration > 1.5)
    }

    @Test func aStopWhileThePlayerIsBuiltNeverStartsIt() async {
        let player = MemoPlayer()
        defer { player.stop() }
        let url = wave()
        player.play(url.path) { url }
        player.stop()
        await AudioWork.drain()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!player.isCurrent(url.path))
        #expect(player.state(of: url.path) == .idle)
        #expect(player.duration == 0)
    }

    @Test func anotherMemoWhileTheFirstIsBuiltKeepsTheNewerOne() async {
        let player = MemoPlayer()
        defer { player.stop() }
        let first = wave(), second = wave(3)
        player.play(first.path) { first }
        player.play(second.path) { second }
        #expect(await waitUntil(timeout: .seconds(5)) { player.state(of: second.path) == .playing })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(player.isCurrent(second.path))
        #expect(player.state(of: first.path) == .idle)
        #expect(player.duration > 2.5)
    }

    @Test func anUnreadableFileIsALoadFailure() async {
        let player = MemoPlayer()
        defer { player.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("memo-player-bad-\(UUID().uuidString).m4a")
        try? Data("not audio".utf8).write(to: url)
        player.play(url.path) { url }
        #expect(await waitUntil(timeout: .seconds(5)) { MemoLoadFailures.contains(url.path) })
        #expect(!player.isCurrent(url.path))
        MemoLoadFailures.remove(url.path)
    }
}
