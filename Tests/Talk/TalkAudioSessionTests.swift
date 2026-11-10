// Audio session coordination with a conversation in it (docs/spec/3x-talk.md §10.1, row L1010), the route control
// (§6.5, row L539) and the Bot Info row's room for four tiles (§2.5, row L214). Every owner is a stand-in here: no
// test touches the real audio session.

import AVKit
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Audio session coordination", .serialized)
@MainActor
struct TalkAudioSessionTests {
    typealias Owner = AudioSessionCoordinator.Owner

    @MainActor final class Seen {
        var playbackPreempted = 0, speechPreempted = 0
        var recordingPreempted: [Owner] = []
        var borrowed: [Owner] = []
        var conversationsEnded = 0
    }

    /// The coordinator with every owner a stand-in and the callbacks counted; `restore` puts the app's own wiring back
    /// (the other suites and the app in the test host rely on it).
    private func make() -> (AudioSessionCoordinator, Seen, restore: () -> Void) {
        let coordinator = AudioSessionCoordinator.shared
        let playback = coordinator.onPlaybackPreempted, speech = coordinator.onSpeechPreempted
        let recording = coordinator.onRecordingPreempted, borrowed = coordinator.onConversationBorrowed
        let ending = coordinator.endConversation, simulated = coordinator.simulatedOwners
        coordinator.reset()
        coordinator.simulatedOwners = [.memoRecording, .memoPlayback, .conversation, .dictation, .speech, .diagnostics]
        let seen = Seen()
        coordinator.onPlaybackPreempted = { seen.playbackPreempted += 1 }
        coordinator.onSpeechPreempted = { seen.speechPreempted += 1 }
        coordinator.onRecordingPreempted = { seen.recordingPreempted.append($0) }
        coordinator.onConversationBorrowed = { seen.borrowed.append($0) }
        coordinator.endConversation = { [weak coordinator] in
            seen.conversationsEnded += 1
            coordinator?.release(.conversation)
        }
        VoiceEvents.clear()
        return (coordinator, seen, {
            coordinator.reset()
            coordinator.onPlaybackPreempted = playback
            coordinator.onSpeechPreempted = speech
            coordinator.onRecordingPreempted = recording
            coordinator.onConversationBorrowed = borrowed
            coordinator.endConversation = ending
            coordinator.simulatedOwners = simulated
        })
    }

    private func events() -> [String] { VoiceEvents.all.map(\.text) }

    @Test("A player that takes the session from a recording ends the recording (Read Aloud tapped during a memo or a dictation)")
    func playingPreemptsRecording() async throws {
        let (coordinator, seen, restore) = make()
        defer { restore() }
        for recording in [Owner.dictation, .memoRecording, .diagnostics] {
            for player in [Owner.speech, .memoPlayback] {
                try await coordinator.acquire(recording)
                try await coordinator.acquire(player)
                #expect(coordinator.owner == player)
                #expect(seen.recordingPreempted.last == recording, "\(recording.rawValue) is told \(player.rawValue) took the session")
                coordinator.release(recording)                 // the loser's late release changes nothing
                #expect(coordinator.owner == player)
                coordinator.release(player)
                #expect(coordinator.owner == nil)
            }
        }
        #expect(seen.recordingPreempted.count == 6)
        // The same owner asking again is not a loss.
        try await coordinator.acquire(.dictation)
        try await coordinator.acquire(.dictation)
        #expect(seen.recordingPreempted.count == 6)
        coordinator.release(.dictation)
    }

    @Test("A start that was ended gives back only its own hold: a newer start of the same kind keeps the session")
    func anAbandonedStartGivesBackOnlyItsOwnHold() async throws {
        let (coordinator, _, restore) = make()
        defer { restore() }
        let first = try await coordinator.acquire(.dictation)
        coordinator.releaseAbandoned(.dictation, grant: first)
        #expect(coordinator.owner == nil)
        // Released by Stop meanwhile, and a new dictation took the session: the old start's give-back changes nothing.
        let old = try await coordinator.acquire(.dictation)
        coordinator.release(.dictation)
        let newer = try await coordinator.acquire(.dictation)
        #expect(newer != old)
        coordinator.releaseAbandoned(.dictation, grant: old)
        #expect(coordinator.owner == .dictation)
        // Nor does another owner's.
        coordinator.releaseAbandoned(.conversation, grant: newer)
        #expect(coordinator.owner == .dictation)
        coordinator.release(.dictation)
        #expect(coordinator.owner == nil)
    }

    @Test("A conversation takes the session from everything else, and says so in the events")
    func conversationPreempts() async throws {
        let (coordinator, seen, restore) = make()
        defer { restore() }
        try await coordinator.acquire(.memoPlayback)
        try await coordinator.acquire(.conversation)
        #expect(coordinator.owner == .conversation && seen.playbackPreempted == 1)
        coordinator.release(.conversation)
        #expect(coordinator.owner == nil)

        try await coordinator.acquire(.speech)
        try await coordinator.acquire(.conversation)
        #expect(coordinator.owner == .conversation && seen.speechPreempted == 1)
        coordinator.release(.conversation)

        for recording in [Owner.memoRecording, .dictation, .diagnostics] {
            try await coordinator.acquire(recording)
            try await coordinator.acquire(.conversation)
            #expect(coordinator.owner == .conversation)
            #expect(seen.recordingPreempted.last == recording, "\(recording.rawValue) is told it lost the microphone")
            coordinator.release(recording)                     // the loser's late release changes nothing
            #expect(coordinator.owner == .conversation)
            coordinator.release(.conversation)
        }
        #expect(seen.recordingPreempted == [.memoRecording, .dictation, .diagnostics])
        #expect(seen.conversationsEnded == 0, "nobody ended a conversation")
        let log = events()
        #expect(log.contains("audio session: conversation acquired") && log.contains("audio session: conversation released"))
        #expect(log.contains("audio session: memoPlayback acquired"))
    }

    @Test("Playing inside a conversation borrows its session: the owner stays, the conversation is told, and giving back changes nothing")
    func borrowing() async throws {
        let (coordinator, seen, restore) = make()
        defer { restore() }
        try await coordinator.acquire(.conversation)
        for player in [Owner.memoPlayback, .speech] {
            try await coordinator.acquire(player)
            #expect(coordinator.owner == .conversation, "the conversation keeps the session")
            #expect(coordinator.borrower == player)
            #expect(coordinator.holds(player) && coordinator.holds(.conversation))
            coordinator.release(player)
            #expect(coordinator.owner == .conversation && coordinator.borrower == nil)
            #expect(!coordinator.holds(player))
        }
        #expect(seen.borrowed == [.memoPlayback, .speech])
        #expect(seen.playbackPreempted == 0 && seen.speechPreempted == 0 && seen.conversationsEnded == 0)
        let log = events()
        #expect(log.contains("audio session: speech plays inside the conversation"))
        #expect(log.contains("audio session: speech done inside the conversation"))
        #expect(!log.contains("audio session: speech acquired"), "the category was never changed for the borrower")
        // The conversation ends while something borrows: both are gone.
        try await coordinator.acquire(.speech)
        coordinator.release(.conversation)
        #expect(coordinator.owner == nil && coordinator.borrower == nil)
    }

    @Test("One microphone: a memo, a dictation or a diagnostics take ends the conversation before it records")
    func oneMicrophone() async throws {
        let (coordinator, seen, restore) = make()
        defer { restore() }
        for (index, recording) in [Owner.memoRecording, .dictation, .diagnostics].enumerated() {
            try await coordinator.acquire(.conversation)
            try await coordinator.acquire(recording)
            #expect(seen.conversationsEnded == index + 1, "\(recording.rawValue) ends the conversation first")
            #expect(coordinator.owner == recording && coordinator.borrower == nil)
            coordinator.release(recording)
            #expect(coordinator.owner == nil)
        }
        #expect(events().contains("audio session: dictation ends the conversation"))
        #expect(seen.recordingPreempted.isEmpty, "the conversation was ended, not pre-empted as a recording")
    }

    @Test("The loudspeaker: the receiver goes to the speaker unless the earpiece was chosen; anything plugged in is left alone")
    func loudspeakerOverride() {
        typealias C = AudioSessionCoordinator
        #expect(C.speakerOverride(outputs: ["Receiver"], loudspeaker: true) == .speaker)
        #expect(C.speakerOverride(outputs: ["Speaker"], loudspeaker: true) == nil)
        #expect(C.speakerOverride(outputs: ["Speaker"], loudspeaker: false) == .clear)
        #expect(C.speakerOverride(outputs: ["Receiver"], loudspeaker: false) == nil)
        for external in ["Headphones", "BluetoothHFP", "BluetoothA2DPOutput", "CarAudio", "AirPlay"] {
            #expect(C.speakerOverride(outputs: [external], loudspeaker: true) == nil, "\(external) wins")
            #expect(C.speakerOverride(outputs: [external], loudspeaker: false) == nil)
        }
        #expect(C.speakerOverride(outputs: [], loudspeaker: true) == nil)
    }

    @Test("Each new conversation starts on the loudspeaker; the choice is said in the events")
    func loudspeakerPerConversation() async throws {
        let (coordinator, _, restore) = make()
        defer { restore(); coordinator.setLoudspeaker(true) }
        try await coordinator.acquire(.conversation)
        coordinator.setLoudspeaker(false)
        #expect(!coordinator.loudspeaker)
        #expect(events().contains("audio session: loudspeaker off"))
        try await coordinator.acquire(.conversation)
        #expect(!coordinator.loudspeaker, "the same conversation keeps the choice")
        coordinator.release(.conversation)
        try await coordinator.acquire(.conversation)
        #expect(coordinator.loudspeaker, "a new one is back on the loudspeaker")
    }

    @Test("Releasing what does not hold the session, or releasing twice, changes nothing; a reset forgets everything")
    func releases() async throws {
        let (coordinator, _, restore) = make()
        defer { restore() }
        try await coordinator.acquire(.dictation)
        coordinator.release(.speech)
        coordinator.release(.conversation)
        #expect(coordinator.owner == .dictation)
        coordinator.release(.dictation)
        coordinator.release(.dictation)
        #expect(coordinator.owner == nil)
        try await coordinator.acquire(.conversation)
        try await coordinator.acquire(.speech)
        coordinator.reset()                                    // iOS reset its audio services
        #expect(coordinator.owner == nil && coordinator.borrower == nil)
        #expect(Owner.conversation.records && !Owner.conversation.plays)
        #expect(Owner.speech.plays && !Owner.speech.records && Owner.diagnostics.records && Owner.dictation.records)
    }
}

@Suite("Talk route control")
@MainActor
struct TalkRouteControlTests {
    @Test("The control under the route's name is the system's route picker, with a 44 pt touch area")
    func picker() {
        let button = TalkRouteButton()
        button.frame = CGRect(x: 100, y: 100, width: 62, height: 16)        // as small as its caption
        button.layoutIfNeeded()
        let pickers = button.subviews.compactMap { $0 as? AVRoutePickerView }
        #expect(pickers.count == 1, "one AVRoutePickerView")
        let picker = pickers[0]
        #expect(picker.frame.width >= 62 && picker.frame.width >= 44 && picker.frame.height >= 44, "\(picker.frame)")
        #expect(!picker.prioritizesVideoDevices)
        // Touches 14 pt above and below the caption still land on the picker.
        #expect(button.point(inside: CGPoint(x: 31, y: -13), with: nil))
        #expect(button.point(inside: CGPoint(x: 31, y: 29), with: nil))
        #expect(!button.point(inside: CGPoint(x: 31, y: -15), with: nil))
        let hit = button.hitTest(CGPoint(x: 31, y: -10), with: nil)
        #expect(hit != nil && (hit === picker || hit?.isDescendant(of: picker) == true), "the touch goes to the system control")
        #expect(button.isAccessibilityElement && button.accessibilityTraits.contains(.button))
        #expect(button.accessibilityIdentifier == "talk.dock.route")
        #expect(button.routeName == TalkDockState.routeName(.none, portName: nil, device: TalkRouteButton.device))
    }
}

@Suite("Bot Info tiles")
struct BotInfoTileRowTests {
    @Test("The row keeps its three-tile width and makes room for a fourth (Screen)")
    func room() {
        #expect(BotInfoTiles.rowWidth(tiles: 1) == 260)
        #expect(BotInfoTiles.rowWidth(tiles: 2) == 260)
        #expect(BotInfoTiles.rowWidth(tiles: 3) == 260, "Talk, Memo, Mute: as before")
        #expect(BotInfoTiles.rowWidth(tiles: 4) == 350, "Talk, Memo, Screen, Mute: 80 pt each")
        #expect(BotInfoTiles.rowWidth(tiles: 4) <= 393 - 32, "fits the sheet of a 393 pt wide iPhone")
        #expect(BotInfoTiles.rowWidth(tiles: 0) == 260)
    }
}
