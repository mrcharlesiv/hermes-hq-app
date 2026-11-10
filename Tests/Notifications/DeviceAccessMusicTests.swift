// [device-access] Music: DeviceAccess+Music's pure parts (query matching, the now/control answer shape), and what
// MusicAccess says against the Simulator's empty library (no Music app data there).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessMusicTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ op: String, _ args: [String: JSONValue] = [:]) -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: op, args: args)
    }

    @Test func matchingIsCaseInsensitiveAgainstAnyGivenName() {
        #expect(DeviceAccess.musicMatches(["Thriller", "Michael Jackson"], query: "thriller"))
        #expect(DeviceAccess.musicMatches(["Thriller", "Michael Jackson"], query: "jackson"))
        #expect(!DeviceAccess.musicMatches(["Thriller", "Michael Jackson"], query: "beatles"))
        #expect(!DeviceAccess.musicMatches([nil, "Michael Jackson"], query: ""))
        #expect(!DeviceAccess.musicMatches([nil, nil], query: "anything"))
    }

    /// Audit 09-6: only the four actions; "stop", a typo or none at all is turned down rather than played.
    @Test func controlTakesOnlyItsFourActions() {
        #expect(DeviceAccess.musicAction(request("music.control", ["action": "play"])) == .play)
        #expect(DeviceAccess.musicAction(request("music.control", ["action": "Pause"])) == .pause)
        #expect(DeviceAccess.musicAction(request("music.control", ["action": "next"])) == .next)
        #expect(DeviceAccess.musicAction(request("music.control", ["action": "previous"])) == .previous)
        #expect(DeviceAccess.musicAction(request("music.control", ["action": "stop"])) == nil)
        #expect(DeviceAccess.musicAction(request("music.control", ["action": "plya"])) == nil)
        #expect(DeviceAccess.musicAction(request("music.control")) == nil)
    }

    @Test func nowPlayingAnswerCarriesOnlyWhatsThere() throws {
        let playing = DeviceAccess.musicAnswer(state: "playing", title: "Thriller", artist: "Michael Jackson", album: "Thriller",
                                                durationSeconds: 357, positionSeconds: 12)
        #expect(playing.result["state"]?.string == "playing")
        let item = try #require(playing.result["item"]?.object)
        #expect(item["title"]?.string == "Thriller" && item["artist"]?.string == "Michael Jackson")
        #expect(item["duration_s"]?.double == 357 && item["position_s"]?.double == 12)

        let stopped = DeviceAccess.musicAnswer(state: "stopped", title: nil, artist: nil, album: nil, durationSeconds: nil, positionSeconds: nil)
        #expect(stopped.result["state"]?.string == "stopped" && stopped.result["item"] == nil)
    }

    /// The Simulator has no Music library: nothing is playing, and a play query never matches.
    @Test func theSimulatorsEmptyLibraryAnswersNothingPlayingAndNoMatch() async throws {
        guard MusicAccess.permission == .allowed else { return }
        let now = await MusicAccess.answer(request("music.now"), scopes: ["nowPlaying"])
        #expect(now.status == .done)
        #expect(now.result["state"]?.string == "stopped")

        let play = await MusicAccess.answer(request("music.control", ["action": "play", "query": "a song that doesn’t exist anywhere 12345"]), scopes: ["control"])
        #expect(play.status == .failed)
    }
}
