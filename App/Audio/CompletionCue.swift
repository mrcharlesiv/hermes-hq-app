// Settings › Sounds › Completion Sound (spec 1x-settings §3.7): a soft two-note cue when a bot's reply finishes, the
// web's default variant 1 "Two-note comfort" (`V/lib/completion-sound.ts:221-230,383-418`): three sine voices with
// exponential envelopes → master 0.48 → low-pass 3,800 Hz (Q 0.32) → dry 0.88 + a small room's reverb 0.34. Rendered
// once into a buffer; `.ambient` audio (the silent switch silences it, other audio keeps playing).

import AVFAudio
import UIKit

@MainActor enum CompletionCue {
    static let key = "hqn.completionSoundOn"

    /// On by default (`dispatch.completionSoundOn`).
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static let variantKey = "hqn.completionSoundVariant"

    /// Settings › Sounds › Sound (the web's `$completionSoundVariantId`, default 1 "Two-Note Comfort").
    static var variant: Int {
        get { (UserDefaults.standard.object(forKey: variantKey) as? Int).flatMap { id in
            CompletionSoundVariant.presets.contains { $0.id == id } ? id : nil } ?? 1 }
        set {
            UserDefaults.standard.set(newValue, forKey: variantKey)
            cueData = nil
            cueVariant = nil
        }
    }

    /// The picker's audition: plays the chosen cue now, whether or not the switch is on (`previewCompletionSound`).
    static func preview(_ id: Int) {
        if AudioSessionCoordinator.shared.owner != nil { return }
        Task.detached(priority: .userInitiated) {
            let data = id == 1 ? CompletionCueSynth.wavData() : CompletionSoundVariant.wavData(id)
            await MainActor.run {
                if let data { AudioWork.later { CueAudio.play(data, fresh: true) } }
            }
        }
    }

    /// Plays at most one cue per session key every 2 s.
    static var dedupeWindow: TimeInterval = 2
    private static var lastPlayed: [String: Date] = [:]
    private static var rendering = false
    /// How many cues played this run (DEBUG checks read it).
    private(set) static var playedCount = 0
    /// How many replies finished this run, cue or not (DEBUG checks read it).
    private(set) static var heardCount = 0

    /// The chat module calls this for every live `message.complete` while the app is active.
    static func turnEnded(sessionKey: String) {
        #if DEBUG
        heardCount += 1
        defer { CueTestProbe.update() }
        #endif
        guard isOn, UIApplication.shared.applicationState == .active else { return }
        let now = Date()
        if let last = lastPlayed[sessionKey], now.timeIntervalSince(last) < dedupeWindow { return }
        lastPlayed[sessionKey] = now
        if lastPlayed.count > 64 { lastPlayed = lastPlayed.filter { now.timeIntervalSince($0.value) < dedupeWindow } }
        play()
    }

    static func play() {
        // Integration: never while voice holds the session (a memo recording or playing): the cue would play under its
        // `.playAndRecord` / `.playback` category, into the take or over the memo.
        if AudioSessionCoordinator.shared.owner != nil { return }
        playedCount += 1
        let id = variant
        if let cueData, cueVariant == id {
            AudioWork.later { CueAudio.play(cueData) }
            return
        }
        guard !rendering else { return }
        rendering = true
        Task.detached(priority: .userInitiated) {
            // Variant 1 keeps its original renderer (the shipped sound, sample for sample).
            let data = id == 1 ? CompletionCueSynth.wavData() : CompletionSoundVariant.wavData(id)
            await MainActor.run {
                rendering = false
                cueData = data
                cueVariant = id
                if let data { AudioWork.later { CueAudio.play(data, fresh: true) } }
            }
        }
    }

    /// The rendered cue (WAV bytes), made once per chosen variant.
    private static var cueData: Data?
    private static var cueVariant: Int?
}

/// The cue's player. Integration: `AVAudioSession` calls and `AVAudioPlayer.play()` (which activates the session) block on
/// the media server — XCTest flagged them on the main thread when a reply finished — so they run on the voice stream's
/// serial audio queue (`AudioWork`), in order with the memo recorder's own session calls.
nonisolated enum CueAudio {
    /// Touched only on `AudioWork.queue`.
    nonisolated(unsafe) private static var player: AVAudioPlayer?

    static func play(_ data: Data, fresh: Bool = false) {
        dispatchPrecondition(condition: .onQueue(AudioWork.queue))
        let session = AVAudioSession.sharedInstance()
        // Only called while nothing holds the session (`CompletionCue.play` checks the voice coordinator on the main
        // actor; its own session calls run on this same queue, in order). Voice releases the session without putting
        // its category back, so after any memo the category is still `.playAndRecord` or `.playback`: the cue would
        // then ignore the silent switch and stop other apps' audio (verify round 1). Always `.ambient` + mix.
        if session.category != .ambient || !session.categoryOptions.contains(.mixWithOthers) {
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }
        if player == nil || fresh || player?.data != data {
            player?.stop()
            player = try? AVAudioPlayer(data: data)
            player?.volume = 1
            player?.prepareToPlay()
        }
        player?.currentTime = 0
        player?.play()
    }
}

#if DEBUG
/// UI tests (`-HQDebugCueCount YES`): a one-point element on the key window whose value is "played=N heard=M", so a test
/// can tell a reply that played the cue from one the switch silenced.
@MainActor enum CueTestProbe {
    private static weak var label: UILabel?

    static func update() {
        guard UserDefaults.standard.bool(forKey: "HQDebugCueCount") else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let probe = label ?? {
            let made = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            made.isAccessibilityElement = true
            made.accessibilityIdentifier = "debug.cue-count"
            made.accessibilityLabel = "cue"
            window?.addSubview(made)
            label = made
            return made
        }()
        if probe.window == nil { window?.addSubview(probe) }
        probe.accessibilityValue = "played=\(CompletionCue.playedCount) heard=\(CompletionCue.heardCount)"
    }
}
#endif

/// The cue's samples (pure math, any thread).
nonisolated enum CompletionCueSynth {
    static let sampleRate = 44_100.0
    static let length = 1.0

    struct Voice { var freq: Double; var start: Double; var dur: Double; var peak: Double; var attack: Double }

    static let voices = [
        Voice(freq: 329.63, start: 0.01, dur: 0.22, peak: 0.05, attack: 0.03),
        Voice(freq: 261.63, start: 0.09, dur: 0.52, peak: 0.07, attack: 0.08),
        Voice(freq: 130.81, start: 0.09, dur: 0.46, peak: 0.02, attack: 0.10),
    ]

    /// WebAudio's `exponentialRampToValueAtTime` from `v0` at `t0` to `v1` at `t1`.
    static func ramp(_ v0: Double, _ v1: Double, _ t0: Double, _ t1: Double, _ t: Double) -> Double {
        v0 * pow(v1 / v0, (t - t0) / (t1 - t0))
    }

    static func envelope(_ voice: Voice, at t: Double) -> Double {
        let start = voice.start, peakAt = start + voice.attack, end = start + voice.dur
        guard t >= start, t <= end + 0.02 else { return 0 }
        if t <= peakAt { return ramp(0.0001, max(voice.peak, 0.0002), start, peakAt, t) }
        if t <= end { return ramp(max(voice.peak, 0.0002), 0.0001, peakAt, end, t) }
        return 0.0001
    }

    /// The dry voices through master gain and the low-pass filter.
    static func dry() -> [Float] {
        let count = Int(sampleRate * length)
        var out = [Double](repeating: 0, count: count)
        for voice in voices {
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let gain = envelope(voice, at: t)
                if gain > 0 { out[i] += sin(2 * .pi * voice.freq * (t - voice.start)) * gain }
            }
        }
        return master(out)
    }

    /// Master 0.48, then an RBJ low-pass biquad (3,800 Hz, Q 0.32).
    static func master(_ samples: [Double]) -> [Float] {
        let w0 = 2 * Double.pi * 3800 / sampleRate, alpha = sin(w0) / (2 * 0.32), cw = cos(w0)
        let b0 = (1 - cw) / 2, b1 = 1 - cw, b2 = (1 - cw) / 2, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        return samples.map { sample in
            let x = sample * 0.48
            let y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return Float(y)
        }
    }

    /// Dry 0.88 plus a small room (a short Schroeder reverb standing in for the web's noise impulse: 4 combs, 2 all-passes).
    static func mixed() -> [Float] { mixed(dry: dry()) }

    static func mixed(dry: [Float]) -> [Float] {
        let combs = [1116, 1188, 1277, 1356].map { Int(Double($0) * sampleRate / 44_100) }
        var wet = [Float](repeating: 0, count: dry.count)
        for delay in combs {
            var buffer = [Float](repeating: 0, count: delay)
            var index = 0
            for i in 0..<dry.count {
                let out = buffer[index]
                buffer[index] = dry[i] + out * 0.72
                index = (index + 1) % delay
                wet[i] += out / Float(combs.count)
            }
        }
        for delay in [556, 441] {
            var buffer = [Float](repeating: 0, count: delay)
            var index = 0
            for i in 0..<wet.count {
                let held = buffer[index]
                let out = -wet[i] + held
                buffer[index] = wet[i] + held * 0.5
                index = (index + 1) % delay
                wet[i] = out
            }
        }
        return zip(dry, wet).map { $0 * 0.88 + $1 * 0.34 }
    }

    /// 16-bit mono PCM WAV.
    static func wavData() -> Data? { wavData(samples: mixed()) }

    static func wavData(samples: [Float]) -> Data? {
        let peak = samples.map(abs).max() ?? 0
        // The web's level is quiet by design; leave it, only guard against clipping.
        let scale: Float = peak > 0.98 ? 0.98 / peak : 1
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample * scale)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func append<T>(_ value: T) { var v = value; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16).littleEndian); append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(sampleRate).littleEndian); append(UInt32(sampleRate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count).littleEndian)
        data.append(pcm)
        return data
    }
}
