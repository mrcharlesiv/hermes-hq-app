// [first-run] The first run's fourteen small cues (App/Resources/FirstRun/first-run-<cue>.m4a, rendered from the mock's
// own synthesis), played at the mock's `cue('…')` points. Played the way CompletionCue plays (App/Audio/CompletionCue
// .swift): `.ambient` audio that mixes with what else is playing and that the silent switch silences, every session and
// player call on the voice stream's audio queue (`AudioWork`), never on the main thread. Nothing while voice holds the
// session. Each cue's player is made once, on first use.

import AVFAudio
import Foundation

@MainActor enum ArrivalSound {
    nonisolated enum Cue: String, CaseIterable, Sendable {
        case tap, gather, here, send, back, settle, scan, ignite, wake, boop, fly, pop, sent, pingon
    }

    /// How many cues were asked for this run (DEBUG checks read it).
    private(set) static var played: [Cue] = []

    static func play(_ cue: Cue) {
        if AudioSessionCoordinator.shared.owner != nil { return }
        played.append(cue)
        if played.count > 64 { played.removeFirst(played.count - 64) }
        AudioWork.later { ArrivalSoundPlayers.play(cue) }
    }

    /// Makes the players ahead of the first cue (off the main thread), so the first one is on time.
    static func prepare() {
        AudioWork.later { ArrivalSoundPlayers.prepare() }
    }
}

/// The players, touched only on `AudioWork.queue`.
nonisolated enum ArrivalSoundPlayers {
    nonisolated(unsafe) private static var players: [ArrivalSound.Cue: AVAudioPlayer] = [:]

    static func prepare() {
        dispatchPrecondition(condition: .onQueue(AudioWork.queue))
        for cue in ArrivalSound.Cue.allCases where players[cue] == nil { _ = player(cue) }
    }

    private static func player(_ cue: ArrivalSound.Cue) -> AVAudioPlayer? {
        if let made = players[cue] { return made }
        guard let url = Bundle.main.url(forResource: "first-run-" + cue.rawValue, withExtension: "m4a"),
              let made = try? AVAudioPlayer(contentsOf: url) else { return nil }
        made.prepareToPlay()
        players[cue] = made
        return made
    }

    static func play(_ cue: ArrivalSound.Cue) {
        dispatchPrecondition(condition: .onQueue(AudioWork.queue))
        let session = AVAudioSession.sharedInstance()
        // As CueAudio: always `.ambient` + mix (voice may have left another category behind).
        if session.category != .ambient || !session.categoryOptions.contains(.mixWithOthers) {
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }
        guard let player = player(cue) else { return }
        player.currentTime = 0
        player.play()
    }
}
