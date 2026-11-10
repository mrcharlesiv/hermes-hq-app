// Level maths, end of speech and the barge-in trigger (docs/spec/3x-talk.md §4.1, §4.3). Pure value types fed with
// (level, time) pairs, so every window is unit-tested without audio. The barge-in trigger is ported from
// `vendor/hermes/apps/desktop/src/lib/voice-barge-in.ts`.

import Foundation

nonisolated enum TalkLevel {
    /// The web meter's scale: `min(1, rms × 128 / 42)` of float samples in −1…1 (about −32 dBFS reads 0.075).
    static func level(rms: Double) -> Double { rms.isFinite ? min(1, max(0, rms * 128 / 42)) : 0 }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return (sum / Double(samples.count)).squareRoot()
    }

    static func rms(_ samples: UnsafeBufferPointer<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768
            sum += value * value
        }
        return (sum / Double(samples.count)).squareRoot()
    }

    static func level(_ samples: [Float]) -> Double { samples.withUnsafeBufferPointer { level(rms: rms($0)) } }
}

/// Decides when one take ends: quiet after speech, nothing said at all, or the longest take.
nonisolated struct TakeEndpoint: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        /// The person spoke and then stayed quiet for the silence window.
        case endOfSpeech
        /// Nothing was said for the idle window: the take is dropped and a new one starts.
        case idle
        /// The longest take: it is sent as it is.
        case cap
    }
    var silenceMs: Double
    var idleMs: Double
    var capMs: Double
    private(set) var heardSpeech = false
    private(set) var elapsedMs = 0.0
    private(set) var quietMs = 0.0

    init(silenceMs: Double = Double(TalkConfig.silenceDefaultMs), clock: TalkClock = TalkClock()) {
        self.silenceMs = silenceMs
        idleMs = clock.idleTakeMs
        capMs = clock.longestTakeMs
    }

    /// `ms` is how much audio this level covers.
    mutating func feed(level: Double, ms: Double) -> Verdict? {
        elapsedMs += ms
        if level >= TalkClock.speechLevel {
            heardSpeech = true
            quietMs = 0
        } else {
            quietMs += ms
        }
        if elapsedMs >= capMs { return heardSpeech ? .cap : .idle }
        if heardSpeech, quietMs >= silenceMs { return .endOfSpeech }
        if !heardSpeech, elapsedMs >= idleMs { return .idle }
        return nil
    }
}

/// Hears the person start talking while the bot works or speaks, then finds the end of what they said.
nonisolated struct BargeMonitor: Sendable {
    enum Event: Equatable, Sendable {
        /// Speech began: silence the bot now.
        case speech
        /// The utterance ended (quiet for the silence window, or the 30 s cap).
        case utteranceEnded
    }
    static let calibrationMs = 400.0
    static let sustainedMs = 300.0
    static let majority = 0.8
    static let minTrigger = 0.075
    static let floorMultiplier = 3.5
    static let playbackMinTrigger = 0.14
    static let ceiling = 0.37
    static let defaultMultiplier = 3.0
    static let graceMs = 500.0
    static let gapForGraceMs = 1_000.0
    static let floorSamples = 200
    static let utteranceMaxMs = 30_000.0

    let floorScale: Double
    let playbackMin: Double
    var silenceMs: Double
    private var floor: [Double] = []
    private var quietFloor = 0.0
    private var calibratedSince: Double?
    private var floorLocked = false
    private var recent: [(above: Bool, at: Double)] = []
    private var wasPlaying = false
    private var playbackSeen = false
    private var lastPlayingAt = 0.0
    private var graceUntil = 0.0
    private(set) var tripped = false
    private var trippedAt = 0.0
    private var quietSince: Double?

    init(multiplier: Double? = nil, silenceMs: Double = Double(TalkConfig.silenceDefaultMs)) {
        let scale = multiplier.map { $0.isFinite && $0 > 0 ? $0 / BargeMonitor.defaultMultiplier : 1 } ?? 1
        floorScale = BargeMonitor.floorMultiplier * scale
        playbackMin = BargeMonitor.playbackMinTrigger * scale
        self.silenceMs = silenceMs
    }

    /// The level that counts as the person speaking right now.
    func trigger(playing: Bool) -> Double {
        var trigger = max(BargeMonitor.minTrigger, quietFloor * floorScale)
        if playing { trigger = min(max(trigger, playbackMin), BargeMonitor.ceiling) }
        return trigger
    }

    private mutating func pushFloor(_ level: Double) {
        floor.append(level)
        if floor.count > BargeMonitor.floorSamples { floor.removeFirst() }
        quietFloor = floor.sorted()[floor.count >> 1]
    }

    /// `now` in milliseconds on any steady clock; `playing` is whether the bot's audio is leaving the speaker.
    mutating func feed(level: Double, now: Double, playing: Bool) -> Event? {
        if tripped {
            if level >= BargeMonitor.minTrigger { quietSince = nil } else if quietSince == nil { quietSince = now }
            if let quietSince, now - quietSince >= silenceMs { return .utteranceEnded }
            if now - trippedAt >= BargeMonitor.utteranceMaxMs { return .utteranceEnded }
            return nil
        }
        if !floorLocked {
            if !playing {
                if calibratedSince == nil { calibratedSince = now }
                pushFloor(level)
            }
            if playing || (calibratedSince.map { now - $0 >= BargeMonitor.calibrationMs } ?? false) { floorLocked = true }
        }
        if playing, !wasPlaying {
            if !playbackSeen || now - lastPlayingAt >= BargeMonitor.gapForGraceMs { graceUntil = now + BargeMonitor.graceMs }
            playbackSeen = true
        }
        wasPlaying = playing
        if playing { lastPlayingAt = now }
        let trigger = trigger(playing: playing)
        if floorLocked, !playing, level < trigger { pushFloor(level) }
        let above = floorLocked && level >= trigger && now >= graceUntil
        recent.append((above, now))
        while let first = recent.first, now - first.at > BargeMonitor.sustainedMs { recent.removeFirst() }
        let aboveCount = recent.reduce(0) { $0 + ($1.above ? 1 : 0) }
        let span = recent.first.map { now - $0.at } ?? 0
        if above, span >= BargeMonitor.sustainedMs * BargeMonitor.majority, Double(aboveCount) >= Double(recent.count) * BargeMonitor.majority {
            tripped = true
            trippedAt = now
            quietSince = nil
            return .speech
        }
        return nil
    }
}

/// The newest second of microphone audio, kept so a barge-in utterance starts from its first syllable.
nonisolated struct PreRoll: Sendable {
    private var frames: [Int16] = []
    let capacity: Int
    init(sampleRate: Int = 16_000, seconds: Double = 1) { capacity = max(1, Int(Double(sampleRate) * seconds)) }
    mutating func append(_ samples: UnsafeBufferPointer<Int16>) {
        frames.append(contentsOf: samples)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
    }
    mutating func append(_ samples: [Int16]) { samples.withUnsafeBufferPointer { append($0) } }
    mutating func take() -> [Int16] {
        defer { frames.removeAll(keepingCapacity: true) }
        return frames
    }
    var count: Int { frames.count }
}

/// A 16 kHz mono 16-bit WAV, the format a take is sent in (§3.2).
nonisolated enum TalkWave {
    static let sampleRate = 16_000

    static func header(dataBytes: Int, sampleRate: Int = TalkWave.sampleRate) -> Data {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(dataBytes))
        return data
    }

    static func file(_ samples: [Int16], sampleRate: Int = TalkWave.sampleRate) -> Data {
        var data = header(dataBytes: samples.count * 2, sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }
        return data
    }
}
