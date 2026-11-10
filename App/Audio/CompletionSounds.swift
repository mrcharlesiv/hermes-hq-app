// Settings › Sounds › Sound: the web's fourteen completion cues (`V/lib/completion-sound.ts` COMPLETION_SOUND_VARIANTS,
// default 1 "Two-note comfort"), rendered natively from the same voice specs: enveloped oscillators (sine, square,
// triangle), plucks that glide, slow blooms, and band-passed noise puffs and whooshes, through the same master gain,
// low-pass and small room as `CompletionCueSynth`. Picking one plays it (the web's preview).

import Foundation

nonisolated enum CompletionSoundVariant {
    enum Wave: Sendable { case sine, square, triangle }

    enum Voice: Sendable {
        case tone(freq: Double, start: Double = 0, dur: Double, gain: Double = 0.5, attack: Double = 0.006, wave: Wave = .sine)
        case pluck(from: Double, to: Double, start: Double = 0, gain: Double, decay: Double, glide: Double = 0.16, attack: Double = 0.004)
        case bloom(freq: Double, start: Double = 0, gain: Double, attack: Double, hold: Double = 0.08, decay: Double,
                   detune: Double = 0, freqTo: Double? = nil, wave: Wave = .sine)
        case air(freq: Double, start: Double = 0, gain: Double, decay: Double, q: Double = 1.2)
        case whoosh(from: Double, to: Double, start: Double = 0, gain: Double, decay: Double, q: Double = 0.8)
        case sweep(from: Double, to: Double, start: Double = 0, gain: Double, decay: Double, attack: Double = 0.003, wave: Wave = .triangle)
    }

    struct Preset: Sendable, Identifiable {
        var id: Int
        var name: String
        var voices: [Voice]
    }

    // Notes (equal temperament), as the web names them.
    private static let A2 = 110.0, A3 = 220.0, A4 = 440.0, A5 = 880.0, B5 = 987.77, C3 = 130.81, C4 = 261.63, E4 = 329.63
    private static let E5 = 659.25, E6 = 1318.51, G4 = 392.0, G5 = 783.99, C5 = 523.25, C6 = 1046.5

    static let presets: [Preset] = [
        Preset(id: 1, name: "Two-Note Comfort", voices: [
            .tone(freq: E4, dur: 0.22, gain: 0.05, attack: 0.03), .tone(freq: C4, start: 0.08, dur: 0.52, gain: 0.07, attack: 0.08),
            .tone(freq: C3, start: 0.08, dur: 0.46, gain: 0.02, attack: 0.1),
        ]),
        Preset(id: 2, name: "Glass Ping", voices: [
            .tone(freq: C6, dur: 0.55, gain: 0.032, attack: 0.002), .tone(freq: E5, start: 0.01, dur: 0.42, gain: 0.018, attack: 0.004),
            .air(freq: 3200, gain: 0.004, decay: 0.1, q: 1.4),
        ]),
        Preset(id: 3, name: "Soft Marimba", voices: [
            .pluck(from: E5, to: G5, gain: 0.03, decay: 0.14, glide: 0.08),
            .bloom(freq: C5, start: 0.04, gain: 0.028, attack: 0.08, hold: 0.04, decay: 0.62),
            .bloom(freq: G4, start: 0.06, gain: 0.014, attack: 0.12, hold: 0.06, decay: 0.55),
        ]),
        Preset(id: 4, name: "Tri-Tone Message", voices: [
            .tone(freq: C6, dur: 0.14, gain: 0.045, attack: 0.004), .tone(freq: A5, start: 0.1, dur: 0.16, gain: 0.04, attack: 0.004),
            .tone(freq: G5, start: 0.2, dur: 0.22, gain: 0.035, attack: 0.006),
        ]),
        Preset(id: 5, name: "Airy Whoosh", voices: [
            .whoosh(from: 4200, to: 900, gain: 0.022, decay: 0.28, q: 0.7), .tone(freq: A5, start: 0.12, dur: 0.35, gain: 0.02, attack: 0.02),
        ]),
        Preset(id: 6, name: "Discovery Cluster", voices: [-14.0, -5, 0, 7, 12].enumerated().map { index, detune in
            Voice.bloom(freq: A3, start: Double(index) * 0.03, gain: 0.012, attack: 0.38, hold: 0.12, decay: 1.05, detune: detune)
        } + [.bloom(freq: E4, start: 0.1, gain: 0.008, attack: 0.45, hold: 0.08, decay: 0.9, detune: 3)]),
        Preset(id: 7, name: "Systems Online", voices: [
            .tone(freq: C5, dur: 0.16, gain: 0.04, attack: 0.006), .tone(freq: G5, start: 0.09, dur: 0.28, gain: 0.042, attack: 0.008),
            .tone(freq: C4, start: 0.09, dur: 0.24, gain: 0.012, attack: 0.01),
        ]),
        Preset(id: 8, name: "Retro Terminal", voices: [
            .tone(freq: B5, dur: 0.12, gain: 0.038, attack: 0.002, wave: .square),
            .tone(freq: E5, start: 0.14, dur: 0.1, gain: 0.028, attack: 0.002, wave: .square),
        ]),
        Preset(id: 9, name: "Modem Chirp", voices: [
            .sweep(from: 320, to: 2200, gain: 0.024, decay: 0.16), .sweep(from: 480, to: 1400, start: 0.1, gain: 0.014, decay: 0.12, wave: .sine),
        ]),
        Preset(id: 10, name: "Wind Chimes", voices: [G5, C6, E5, A5].enumerated().map { index, freq in
            Voice.tone(freq: freq, start: Double(index) * 0.13, dur: 0.72, gain: 0.028 - Double(index) * 0.003, attack: 0.003)
        }),
        Preset(id: 11, name: "Singing Bowl", voices: [
            .bloom(freq: A3, gain: 0.022, attack: 0.58, hold: 0.16, decay: 1.35),
            .bloom(freq: E4, start: 0.08, gain: 0.01, attack: 0.62, hold: 0.12, decay: 1.2, detune: 4),
            .bloom(freq: A4, start: 0.14, gain: 0.006, attack: 0.68, hold: 0.08, decay: 1.05, detune: -3),
        ]),
        Preset(id: 12, name: "Harp Lift", voices: [C5, E5, G5, C6].enumerated().map { index, freq in
            Voice.tone(freq: freq, start: Double(index) * 0.075, dur: 0.38, gain: 0.034 - Double(index) * 0.004, attack: 0.012)
        } + [.bloom(freq: C4, start: 0.2, gain: 0.01, attack: 0.18, hold: 0.06, decay: 0.7)]),
        Preset(id: 13, name: "Sonar Ping", voices: [
            .tone(freq: A2, dur: 0.95, gain: 0.036, attack: 0.008), .tone(freq: A3, start: 0.42, dur: 0.55, gain: 0.014, attack: 0.01),
            .air(freq: 600, gain: 0.005, decay: 0.2, q: 0.5),
        ]),
        Preset(id: 14, name: "Music Box", voices: [E6, C6, G5, E5].enumerated().map { index, freq in
            Voice.pluck(from: freq, to: freq * 0.998, start: Double(index) * 0.09, gain: 0.02 - Double(index) * 0.002, decay: 0.2, glide: 0.06)
        }),
    ]

    static func preset(_ id: Int) -> Preset { presets.first { $0.id == id } ?? presets[0] }

    // MARK: Rendering

    static let sampleRate = CompletionCueSynth.sampleRate

    /// WebAudio's envelope: 0.0001 at `start`, exponential to `peak` at `start + attack`, held to `holdEnd`, exponential
    /// to 0.0001 at `end`; silent after.
    static func envelope(_ t: Double, start: Double, attack: Double, holdEnd: Double, end: Double, peak: Double) -> Double {
        let top = max(peak, 0.0002)
        guard t >= start, t <= end + 0.02 else { return 0 }
        if t <= start + attack { return CompletionCueSynth.ramp(0.0001, top, start, start + attack, t) }
        if t <= holdEnd { return top }
        if t <= end { return CompletionCueSynth.ramp(top, 0.0001, holdEnd, end, t) }
        return 0.0001
    }

    static func wave(_ wave: Wave, _ phase: Double) -> Double {
        let cycle = phase - floor(phase)
        switch wave {
        case .sine: return sin(2 * .pi * cycle)
        case .square: return cycle < 0.5 ? 1 : -1
        case .triangle: return 4 * abs(cycle - 0.5) - 1
        }
    }

    /// The voices summed (before the master chain), long enough for the longest tail.
    static func dry(_ preset: Preset) -> [Double] {
        let length = preset.voices.map(end).max().map { min(2.6, $0 + 0.3) } ?? 1
        let count = Int(sampleRate * length)
        var out = [Double](repeating: 0, count: count)
        var noise = SplitMix(seed: UInt64(preset.id) &* 0x9E37_79B9_7F4A_7C15)
        for voice in preset.voices { add(voice, to: &out, noise: &noise) }
        return out
    }

    private static func end(_ voice: Voice) -> Double {
        switch voice {
        case .tone(_, let start, let dur, _, _, _): start + dur
        case .pluck(_, _, let start, _, let decay, _, _): start + decay
        case .bloom(_, let start, _, let attack, let hold, let decay, _, _, _): start + attack + hold + decay
        case .air(_, let start, _, let decay, _): start + decay
        case .whoosh(_, _, let start, _, let decay, _): start + decay
        case .sweep(_, _, let start, _, let decay, _, _): start + decay
        }
    }

    private static func add(_ voice: Voice, to out: inout [Double], noise: inout SplitMix) {
        switch voice {
        case .tone(let freq, let start, let dur, let gain, let attack, let shape):
            oscillate(&out, start: start, end: start + dur, frequency: { _ in freq }, shape: shape) {
                envelope($0, start: start, attack: attack, holdEnd: start + attack, end: start + dur, peak: gain)
            }
        case .pluck(let from, let to, let start, let gain, let decay, let glide, let attack):
            oscillate(&out, start: start, end: start + decay, frequency: { t in
                t >= start + glide ? to : CompletionCueSynth.ramp(from, to, start, start + glide, max(t, start))
            }, shape: .triangle) {
                envelope($0, start: start, attack: attack, holdEnd: start + attack, end: start + decay, peak: gain)
            }
        case .bloom(let freq, let start, let gain, let attack, let hold, let decay, let detune, let freqTo, let shape):
            let base = freq * pow(2, detune / 1200)
            let target = (freqTo ?? freq) * pow(2, detune / 1200)
            let glideEnd = start + attack + hold * 0.6
            oscillate(&out, start: start, end: start + attack + hold + decay, frequency: { t in
                freqTo == nil || t >= glideEnd ? (freqTo == nil ? base : target) : CompletionCueSynth.ramp(base, target, start, glideEnd, max(t, start))
            }, shape: shape) {
                envelope($0, start: start, attack: attack, holdEnd: start + attack + hold, end: start + attack + hold + decay, peak: gain)
            }
        case .air(let freq, let start, let gain, let decay, let q):
            filteredNoise(&out, start: start, end: start + decay, center: { _ in freq }, q: q, noise: &noise) {
                envelope($0, start: start, attack: 0.018, holdEnd: start + 0.018, end: start + decay, peak: gain)
            }
        case .whoosh(let from, let to, let start, let gain, let decay, let q):
            filteredNoise(&out, start: start, end: start + decay, center: { t in CompletionCueSynth.ramp(from, to, start, start + decay, min(max(t, start), start + decay)) },
                          q: q, noise: &noise) {
                envelope($0, start: start, attack: 0.03, holdEnd: start + 0.03, end: start + decay, peak: gain)
            }
        case .sweep(let from, let to, let start, let gain, let decay, let attack, let shape):
            let sweepEnd = start + decay - 0.02
            oscillate(&out, start: start, end: start + decay, frequency: { t in
                t >= sweepEnd ? to : CompletionCueSynth.ramp(from, to, start, sweepEnd, max(t, start))
            }, shape: shape) {
                envelope($0, start: start, attack: attack, holdEnd: start + attack, end: start + decay, peak: gain)
            }
        }
    }

    private static func oscillate(_ out: inout [Double], start: Double, end: Double, frequency: (Double) -> Double, shape: Wave,
                                  gain: (Double) -> Double) {
        var phase = 0.0
        let first = max(0, Int(start * sampleRate)), last = min(out.count, Int((end + 0.02) * sampleRate))
        guard first < last else { return }
        for i in first..<last {
            let t = Double(i) / sampleRate
            out[i] += wave(shape, phase) * gain(t)
            phase += frequency(t) / sampleRate
        }
    }

    /// White noise through an RBJ band-pass (constant peak gain) whose centre may move.
    private static func filteredNoise(_ out: inout [Double], start: Double, end: Double, center: (Double) -> Double, q: Double,
                                      noise: inout SplitMix, gain: (Double) -> Double) {
        let first = max(0, Int(start * sampleRate)), last = min(out.count, Int((end + 0.02) * sampleRate))
        guard first < last else { return }
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in first..<last {
            let t = Double(i) / sampleRate
            let w0 = 2 * Double.pi * min(center(t), sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * q), cw = cos(w0)
            let b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha
            let x = noise.nextSigned()
            let y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x; y2 = y1; y1 = y
            out[i] += y * gain(t)
        }
    }

    /// The preset through the master chain and room, as 16-bit WAV.
    static func wavData(_ id: Int) -> Data? {
        let preset = preset(id)
        return CompletionCueSynth.wavData(samples: CompletionCueSynth.mixed(dry: CompletionCueSynth.master(dry(preset))))
    }
}

/// A small deterministic noise source (the same cue every time).
nonisolated struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextSigned() -> Double { Double(next() >> 11) / Double(1 << 53) * 2 - 1 }
}
