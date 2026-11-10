// Pure rules for the recorder (W:ios/App/App/HermesVoice.swift:225-256, HermesPlatform.swift:784-786; spec §3.3).

import Foundation

nonisolated enum MemoPolicy {
    enum Finish: String, Sendable, Equatable { case await, draft, discard }

    /// What happens to a take the recorder stopped on its own. Never a send: only the person's release or Send sends
    /// (C1). The length limit waits for the release rule; a call, Siri, leaving the app or a lost headset keeps the
    /// take as a draft once it is a second long.
    static func finish(reason: MemoStopReason, elapsed: Double) -> Finish {
        switch reason {
        case .limit: return .await
        case .cancel: return .discard
        default: return elapsed >= 1 ? .draft : .discard
        }
    }

    /// The one retry after a busy input starts the microphone only for the same take, not stopped, with the app in
    /// front and no trip to the background during the 150 ms pause (Codex N12).
    static func mayRetry(sameTake: Bool, stopped: Bool, active: Bool, backgrounded: Bool) -> Bool {
        sameTake && !stopped && active && !backgrounded
    }

    /// AVAudioRecorder's average power (dBFS) as a 0…1 level.
    static func level(power: Float) -> Double { Double(max(0, min(1, (power + 50) / 50))) }

    /// `count` bars from the per-100 ms levels: each bar is its stretch's loudest moment (three decimals), so a short
    /// memo still fills the bubble and a long one keeps its peaks.
    static func peaks(_ samples: [Double], count: Int = 48) -> [Double] {
        guard !samples.isEmpty, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
        return (0..<count).map { bar in
            let start = bar * samples.count / count
            let end = max(start + 1, (bar + 1) * samples.count / count)
            let slice = samples[min(start, samples.count - 1)..<min(end, samples.count)]
            return ((slice.max() ?? 0) * 1000).rounded() / 1000
        }
    }

    /// The attachment limit until a Settings value exists (W:ios/App/App/PickedFiles.swift:30): 32 MiB.
    static let defaultLimitBytes = 32 * 1024 * 1024

    /// AAC mono 24 kHz at 48 kbps is 6 kB a second: ten minutes, or less when the attachment limit is smaller.
    static func limitSeconds(limitBytes: Int = defaultLimitBytes) -> Double {
        min(600, (Double(limitBytes) * 0.95 / 6000).rounded(.down))
    }

    /// Below this a memo can't be recorded at all (`too-small`).
    static let minimumLimit: Double = 10

    /// "0:04", "1:30": whole seconds rounded down (`formatAudioLength`, W:src/voice-memo.ts:40-43). For a clock that
    /// runs: the live timer, the time left while a memo plays.
    static func length(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// A finished memo's length, rounded to the nearest second as Telegram shows it: a 2.0 s hold (1.9 s recorded once
    /// the microphone confirmed) reads "0:02". The bubble at rest, the chip, the queue card, notices, review.
    static func total(_ seconds: Double) -> String { length(seconds.isFinite ? seconds.rounded() : 0) }

    /// Two decimals (a MemoFile's `seconds`).
    static func twoDecimals(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
