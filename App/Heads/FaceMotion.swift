// [moods] How every face moves while its bot is at something (owner, 2026-10-28, of Grok Bot's faces: "I want similar
// to that. Don't copy them obviously."): the body turns, tips, tilts, hops and squashes as if it were round, and the
// eyes look about, blink and narrow. Each mood has a few routines a few seconds long, played in a
// shuffled order so a face never reads as a loop; each starts and ends on the mood's own pose, so any one can follow
// any other. Only the body and the eyes move (owner, 2026-10-28: "i don't want mouths. just the body and eyes moving"),
// and the eyes stay the head's own normal ones ("only one kind of eyes - the normal ones. The other options make them
// look cheap"): no stars, arcs or crosses, just where they look and how open they are.
//
// Pure values worked out here. HeadView plays them on each kind of head by sampling them into keyframes: the body the
// same on all of them, a dot-matrix head's eyes a LED at a time (MatrixAct), a Shapes head's gliding, a Dots head's a
// lamp at a time.

import CoreGraphics
import Foundation

/// Where the body is: moved (shares of the head's side, + right and down), tilted (`roll`, degrees, + clockwise),
/// turned (`turn`, degrees about the upright, + toward the viewer's right), tipped (`tip`, degrees, + face down) and
/// squashed (+ wider and shorter, − taller and thinner).
nonisolated struct FaceBody: Hashable, Sendable {
    var x = 0.0, y = 0.0, roll = 0.0, turn = 0.0, tip = 0.0, squash = 0.0

    static let rest = FaceBody()

    func mixed(_ other: FaceBody, _ k: Double) -> FaceBody {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return FaceBody(x: mix(x, other.x), y: mix(y, other.y), roll: mix(roll, other.roll), turn: mix(turn, other.turn),
                        tip: mix(tip, other.tip), squash: mix(squash, other.squash))
    }

    /// Shortest signed angular difference from `a` to `b`, in (−180°, 180°], so settling from 360° back to 0° moves 0°.
    static func shortestAngleDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    /// Smooth blend between poses using shortest angular arcs (never unwinds a full 360° spin backwards).
    func mixedShortest(_ other: FaceBody, _ k: Double) -> FaceBody {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return FaceBody(x: mix(x, other.x), y: mix(y, other.y),
                        roll: roll + Self.shortestAngleDelta(from: roll, to: other.roll) * k,
                        turn: turn + Self.shortestAngleDelta(from: turn, to: other.turn) * k,
                        tip: tip + Self.shortestAngleDelta(from: tip, to: other.tip) * k,
                        squash: mix(squash, other.squash))
    }

    /// C² quintic S-curve (0→1 with zero velocity and zero acceleration at both ends) for silk-smooth transitions.
    static func quintic(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        return u * u * u * (10 + u * (-15 + 6 * u))
    }
}

/// Where the eyes look (−1…1 each way, + right and down), how far shut they are (0 open … 1 shut), how wide/perked
/// they open (0 normal … 1 wide, still normal slits), and subtle inquisitive asymmetry (−1…1: + right eye slightly
/// wider than left).
nonisolated struct FaceEyes: Hashable, Sendable {
    var x = 0.0, y = 0.0, lids = 0.0, wide = 0.0, tilt = 0.0

    static let rest = FaceEyes()
    /// How far a look all the way across (1) or down turns the eyes round a round body, degrees: the same as the body
    /// turning or tipping that far, so a look and a turn add up to where the face is looking.
    static let across = 34.0, down = 26.0

    func mixed(_ other: FaceEyes, _ k: Double) -> FaceEyes {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return FaceEyes(x: mix(x, other.x), y: mix(y, other.y), lids: mix(lids, other.lids),
                        wide: mix(wide, other.wide), tilt: mix(tilt, other.tilt))
    }
}

/// How a move goes, as CSS's `cubic-bezier`: its middle points may run past 1, for a move that overshoots and settles.
nonisolated struct FaceEase: Hashable, Sendable {
    var x1: Double, y1: Double, x2: Double, y2: Double

    static let linear = FaceEase(x1: 0, y1: 0, x2: 1, y2: 1)
    /// Soft at both ends: most moves.
    static let glide = FaceEase(x1: 0.42, y1: 0, x2: 0.22, y2: 1)
    /// Quick off, running about 15 % past and settling back: a head swinging round, a landing.
    static let spring = FaceEase(x1: 0.3, y1: 1.6, x2: 0.45, y2: 1.1)
    /// Livelier overshoot for playful hops and joyful settles.
    static let bouncy = FaceEase(x1: 0.26, y1: 1.75, x2: 0.42, y2: 1.08)
    /// Crisp off, soft landing: quick eye saccades and alert snaps.
    static let snappy = FaceEase(x1: 0.18, y1: 0, x2: 0.12, y2: 1)
    /// Faster and faster: a fall, a push.
    static let drop = FaceEase(x1: 0.55, y1: 0, x2: 0.9, y2: 0.55)
    /// Fast off, slowing to the top: a jump.
    static let rise = FaceEase(x1: 0.1, y1: 0.55, x2: 0.35, y2: 1)

    /// How far along the move is at `t` (0…1 of its time).
    func callAsFunction(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        func curve(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        func slope(_ s: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * x1 + 6 * u * s * (x2 - x1) + 3 * s * s * (1 - x2)
        }
        var s = t
        for _ in 0..<8 {
            let d = slope(s)
            guard abs(d) > 1e-6 else { break }
            s = min(max(s - (curve(s, x1, x2) - t) / d, 0), 1)
        }
        if abs(curve(s, x1, x2) - t) > 1e-4 {
            var low = 0.0, high = 1.0
            for _ in 0..<40 {
                s = (low + high) / 2
                if curve(s, x1, x2) < t { low = s } else { high = s }
            }
        }
        return curve(s, y1, y2)
    }
}

/// A value at a moment of a routine, reached from the one before by `ease`.
nonisolated struct FaceKey<Value: Hashable & Sendable>: Hashable, Sendable {
    var at: Double
    var value: Value
    var ease: FaceEase
}

/// One routine: how the body and the eyes go, each on its own timeline.
nonisolated struct FaceClip: Sendable {
    var length: Double
    var body: [FaceKey<FaceBody>]
    var eyes: [FaceKey<FaceEyes>]
    /// Beats in it a light may flash on (a nod's dip, a hop's landing).
    var marks: [Double] = []

    func body(at t: Double) -> FaceBody { Self.value(body, at: t) { $0.mixed($1, $2) } }
    func eyes(at t: Double) -> FaceEyes { Self.value(eyes, at: t) { $0.mixed($1, $2) } }

    var first: (body: FaceBody, eyes: FaceEyes) { (body[0].value, eyes[0].value) }
    var last: (body: FaceBody, eyes: FaceEyes) { (body[body.count - 1].value, eyes[eyes.count - 1].value) }

    /// Times to sample it at, evenly about `rate` a second, both ends included (the same for every loop it's in, so a
    /// face drawn for it is drawn for any order).
    func times(rate: Double) -> [Double] {
        let steps = max(1, Int((length * rate).rounded(.up)))
        return (0...steps).map { length * Double($0) / Double(steps) }
    }

    private static func value<V>(_ keys: [FaceKey<V>], at t: Double, mix: (V, V, Double) -> V) -> V {
        var previous = keys[0]
        for key in keys.dropFirst() {
            if t < key.at {
                let span = key.at - previous.at
                return mix(previous.value, key.value, span > 0 ? key.ease((t - previous.at) / span) : 1)
            }
            previous = key
        }
        return previous.value
    }
}

/// Writes a routine as moves from where the face is: hold, then go somewhere over a while.
nonisolated struct FaceScript {
    private(set) var body: [FaceKey<FaceBody>]
    private(set) var eyes: [FaceKey<FaceEyes>]
    private(set) var marks: [Double] = []

    init(_ body: FaceBody = .rest, _ eyes: FaceEyes = .rest) {
        self.body = [FaceKey(at: 0, value: body, ease: .linear)]
        self.eyes = [FaceKey(at: 0, value: eyes, ease: .linear)]
    }

    /// Where the body is after the last move.
    var now: FaceBody { body[body.count - 1].value }
    /// How the eyes are after the last look.
    var looking: FaceEyes { eyes[eyes.count - 1].value }

    /// At `at`, the body moves over `over` seconds to where `change` takes it.
    mutating func move(_ at: Double, _ over: Double, _ ease: FaceEase = .glide, _ change: (inout FaceBody) -> Void) {
        var to = now
        change(&to)
        Self.add(&body, at, over, ease, to)
    }

    mutating func move(_ at: Double, _ over: Double, _ ease: FaceEase = .glide, to: FaceBody) {
        Self.add(&body, at, over, ease, to)
    }

    /// At `at`, the eyes go over `over` seconds to where `change` takes them.
    mutating func look(_ at: Double, _ over: Double = 0.16, _ ease: FaceEase = .glide, _ change: (inout FaceEyes) -> Void) {
        var to = looking
        change(&to)
        Self.add(&eyes, at, over, ease, to)
    }

    mutating func look(_ at: Double, _ over: Double = 0.16, _ ease: FaceEase = .glide, to: FaceEyes) {
        Self.add(&eyes, at, over, ease, to)
    }

    /// The lids drop smoothly, pause briefly shut, and lift again softly (0.28 s).
    mutating func blink(_ at: Double) {
        let open = looking
        look(at, 0.09, .glide) { $0.lids = 1; $0.wide = 0 }
        look(at + 0.12, 0.16, .glide, to: open)
    }

    /// Two quick natural blinks (0.58 s).
    mutating func doubleBlink(_ at: Double) {
        blink(at)
        blink(at + 0.3)
    }

    mutating func mark(_ at: Double) { marks.append(at) }

    /// The routine, `length` seconds long: the last pose held to the end.
    func clip(_ length: Double) -> FaceClip {
        var body = body, eyes = eyes
        if let last = body.last, last.at < length { body.append(FaceKey(at: length, value: last.value, ease: .linear)) }
        if let last = eyes.last, last.at < length { eyes.append(FaceKey(at: length, value: last.value, ease: .linear)) }
        return FaceClip(length: length, body: body, eyes: eyes, marks: marks)
    }

    private static func add<V>(_ keys: inout [FaceKey<V>], _ at: Double, _ over: Double, _ ease: FaceEase, _ value: V) {
        let last = keys[keys.count - 1]
        assert(at >= last.at - 1e-9, "a move starts before the last one ends")
        if at > last.at + 1e-9 { keys.append(FaceKey(at: at, value: last.value, ease: .linear)) }
        keys.append(FaceKey(at: max(at, last.at) + over, value: value, ease: ease))
    }
}

// MARK: - The routines

/// Each mood's routines, our own (not Grok Bot's): the body in degrees and shares of the head, the eyes −1…1.
nonisolated enum FaceRoutines {
    /// Browsing: where the pointer stops (fractions of the head), each stop a second, the eyes and head turning to it.
    static let stops: [CGPoint] = [CGPoint(x: 0.3, y: 0.68), CGPoint(x: 0.72, y: 0.4), CGPoint(x: 0.6, y: 0.74), CGPoint(x: 0.34, y: 0.36)]
    static let stopLength = 1.0
    /// Writing: how long a line takes to type, and the pause before the next two (a routine is two lines and a pause).
    static let lineLength = 1.4
    static let typingPause = 0.4

    /// `mood`'s routines for a face turned to `facing` (−1 left, +1 right): one for a once-only mood (two for done, one
    /// with a cartwheel), a few for the others.
    static func clips(_ mood: BotMood, facing: Int) -> [FaceClip] {
        let f = facing < 0 ? -1.0 : 1.0
        switch mood {
        case .thinking: return thinking(f)
        case .reading: return reading()
        case .searching: return searching(f)
        case .running: return running(f)
        case .writing: return writing(f)
        case .browsing: return browsing()
        case .messaging: return messaging(f)
        case .making: return making(f)
        case .replying: return replying(f)
        case .asking: return asking(f)
        case .done: return done(f)
        case .failed: return failed(f)
        }
    }

    /// The eyes kept still under Reduce Motion: the mood's own look (up for done, down and half shut for failed).
    static func still(_ mood: BotMood, facing: Int) -> FaceEyes {
        switch mood {
        case .done: FaceEyes(y: -0.6)
        case .failed: FaceEyes(y: 0.5, lids: 0.45)
        default: clips(mood, facing: facing)[0].first.eyes
        }
    }

    /// A hop on the spot from `at` (0.62 s): down, up `height`, a squash as it lands, back where it was. When it lands.
    @discardableResult
    private static func hop(_ script: inout FaceScript, _ at: Double, height: Double, roll: Double = 0) -> Double {
        let from = script.now
        script.move(at, 0.1) { $0.squash = from.squash + 0.08; $0.y = from.y + 0.012 }
        script.move(at + 0.1, 0.16, .rise) {
            $0.y = from.y - height; $0.squash = from.squash - 0.07; $0.roll = from.roll + roll
        }
        script.move(at + 0.26, 0.14, .drop) {
            $0.y = from.y + 0.008; $0.squash = from.squash + 0.075; $0.roll = from.roll
        }
        script.move(at + 0.4, 0.22, .spring, to: from)
        return at + 0.4
    }

    /// A nod from `at` (0.5 s): the face dips and comes back up. Marks the dip.
    private static func nod(_ script: inout FaceScript, _ at: Double, depth: Double = 11) {
        let from = script.now
        script.move(at, 0.15, .snappy) { $0.tip = from.tip + depth; $0.y = from.y + 0.016; $0.squash = from.squash + 0.03 }
        script.move(at + 0.15, 0.35, .spring, to: from)
        script.mark(at + 0.15)
    }

    private static func thinking(_ f: Double) -> [FaceClip] {
        // Chin up, turned thoughtfully to one side, eyes up there: turning something over.
        let body = FaceBody(roll: 5 * f, turn: 14 * f, tip: -8), eyes = FaceEyes(x: 0.65 * f, y: -0.85)
        var over = FaceScript(body, eyes)       // slowly drifts round to the other side, and back
        over.look(0.85, 0.22, .snappy) { $0.x = -0.75 * f; $0.y = -0.95; $0.tilt = -0.25 * f }
        over.move(0.95, 1.25) { $0.turn = -18 * f; $0.roll = -6 * f; $0.tip = -10; $0.x = -0.015 * f }
        over.blink(2.55)
        over.look(3.25, 0.25, .snappy, to: eyes)
        over.move(3.35, 1.3, to: body)

        var hmm = FaceScript(body, eyes)        // leans in, squints in concentration, then lightbulb perk-up!
        hmm.move(0.45, 0.48) { $0.tip = 6; $0.squash = 0.055; $0.y = 0.018; $0.turn = 6 * f; $0.roll = -2 * f }
        hmm.look(0.45, 0.26) { $0.lids = 0.55; $0.y = 0.18; $0.x = 0.25 * f; $0.tilt = 0.45 * f }
        hmm.move(1.75, 0.24, .rise) { $0.tip = -13; $0.squash = -0.08; $0.y = -0.048; $0.turn = 0; $0.roll = 3 * f }
        hmm.look(1.72, 0.12, .snappy) { $0.lids = 0; $0.wide = 0.85; $0.y = -0.45; $0.x = 0; $0.tilt = 0 }
        hmm.mark(1.95)
        hmm.move(2.05, 0.55, .bouncy, to: body)
        hmm.look(2.55, 0.22, to: eyes)
        hmm.doubleBlink(3.35)

        var about = FaceScript(body, eyes)      // eyes darting up connecting ideas
        about.look(0.4, 0.12, .snappy) { $0.x = -0.65 * f; $0.y = -1; $0.wide = 0.2 }
        about.move(0.45, 0.52, .spring) { $0.turn = -10 * f; $0.roll = -3 * f; $0.tip = -11 }
        about.look(1.3, 0.12, .snappy) { $0.x = 1 * f; $0.y = -0.55; $0.wide = 0.3 }
        about.move(1.35, 0.52, .spring) { $0.turn = 22 * f; $0.roll = 7 * f; $0.tip = -6 }
        about.blink(2.15)
        about.look(2.65, 0.2, to: eyes)
        about.move(2.7, 0.9, to: body)

        var weigh = FaceScript(body, eyes)      // weighs option A vs option B
        weigh.look(0.35, 0.16, .snappy) { $0.x = -0.8 * f; $0.y = -0.35; $0.tilt = -0.35 * f }
        weigh.move(0.4, 0.65, .spring) { $0.roll = -10 * f; $0.turn = -15 * f; $0.tip = -3; $0.y = 0.01 }
        weigh.look(1.5, 0.16, .snappy) { $0.x = 0.85 * f; $0.y = -0.45; $0.tilt = 0.35 * f }
        weigh.move(1.55, 0.65, .spring) { $0.roll = 10 * f; $0.turn = 18 * f; $0.tip = -5; $0.y = -0.01 }
        weigh.blink(2.5)
        weigh.look(2.95, 0.22, to: eyes)
        weigh.move(3.0, 0.85, to: body)
        return [over.clip(5.2), hmm.clip(4.4), about.clip(4.0), weigh.clip(4.2)]
    }

    private static func reading() -> [FaceClip] {
        // Head down to the page, focused narrowed eyes at the start of a line.
        let body = FaceBody(turn: -8, tip: 10, squash: 0.025), eyes = FaceEyes(x: -0.85, y: 0.32, lids: 0.32)
        var lines = FaceScript(body, eyes)      // three lines down the page, saccadic rhythm & crisp carriage returns
        for line in 0..<3 {
            let t = Double(line) * 1.15
            let rowY = 0.32 + 0.23 * Double(line)
            lines.look(t + 0.04, 0.4, .glide) { $0.x = 0.05; $0.y = rowY }
            lines.look(t + 0.48, 0.4, .glide) { $0.x = 0.88; $0.y = rowY }
            lines.move(t + 0.04, 0.84) { $0.turn = 8; $0.tip = 10 + 2.5 * Double(line); $0.roll = 2 }
            lines.mark(t + 0.92)
            lines.look(t + 0.92, 0.12, .snappy) { $0.x = -0.85; $0.y = line < 2 ? 0.32 + 0.23 * Double(line + 1) : 0.32 }
            lines.move(t + 0.92, 0.18, .snappy) { $0.turn = -8; $0.tip = line < 2 ? 10 + 2.5 * Double(line + 1) : 10; $0.roll = 0 }
        }

        var close = FaceScript(body, eyes)      // leans in to a dense bit, reads, slow understanding nod
        close.move(0.18, 0.46) { $0.tip = 16; $0.y = 0.025; $0.squash = -0.025; $0.roll = -3 }
        close.look(0.18, 0.24) { $0.lids = 0.52; $0.y = 0.5 }
        close.look(0.75, 0.92, .linear) { $0.x = 0.88 }
        close.move(0.75, 0.92) { $0.turn = 9; $0.roll = 2 }
        close.look(1.72, 0.12, .snappy) { $0.x = -0.85; $0.y = 0.65 }
        close.move(1.72, 0.26) { $0.turn = -8; $0.roll = 0 }
        nod(&close, 2.05, depth: 8)
        close.blink(2.6)
        close.move(2.95, 0.6, to: body)
        close.look(2.95, 0.25, to: eyes)

        var skim = FaceScript(body, eyes)       // fast vertical skim, catches an interesting detail
        skim.move(0.2, 0.55) { $0.turn = 0; $0.tip = 6; $0.y = -0.008 }
        skim.look(0.2, 0.16, .snappy) { $0.x = -0.2; $0.y = 0.1; $0.lids = 0.15 }
        skim.look(0.65, 0.65, .glide) { $0.x = 0.25; $0.y = 0.82 }
        skim.move(0.75, 0.65) { $0.tip = 15; $0.y = 0.02 }
        skim.look(1.45, 0.12, .snappy) { $0.lids = 0; $0.wide = 0.55; $0.x = 0.4; $0.y = 0.6 }
        skim.move(1.45, 0.28, .spring) { $0.roll = 6; $0.squash = -0.04; $0.tip = 11 }
        skim.mark(1.55)
        skim.blink(2.1)
        skim.move(2.55, 0.65, to: body)
        skim.look(2.55, 0.22, to: eyes)
        return [lines.clip(3.6), close.clip(3.8), skim.clip(3.4)]
    }

    private static func searching(_ f: Double) -> [FaceClip] {
        let body = FaceBody(tip: -3), eyes = FaceEyes(y: -0.2)
        var sides = FaceScript(body, eyes)      // crisp eyes-first look each way
        sides.look(0.18, 0.09, .snappy) { $0.x = -1; $0.wide = 0.25 }
        sides.move(0.22, 0.34, .spring) { $0.turn = -28; $0.x = -0.036; $0.roll = -6 }
        sides.look(1.05, 0.09, .snappy) { $0.x = 1; $0.wide = 0.25 }
        sides.move(1.09, 0.42, .spring) { $0.turn = 28; $0.x = 0.036; $0.roll = 6 }
        sides.blink(1.85)
        sides.look(2.25, 0.12, .snappy, to: eyes)
        sides.move(2.3, 0.48, to: body)

        var peer = FaceScript(body, eyes)       // leans in and scans along closely
        peer.move(0.25, 0.42) { $0.tip = 13; $0.y = 0.028; $0.squash = 0.045 }
        peer.look(0.25, 0.18) { $0.y = 0.48; $0.lids = 0.35 }
        peer.look(1.05, 0.12, .snappy) { $0.x = -0.9 * f }
        peer.move(1.1, 0.36, .spring) { $0.turn = -16 * f; $0.roll = -3 * f }
        peer.look(1.85, 0.12, .snappy) { $0.x = 0.9 * f }
        peer.move(1.9, 0.38, .spring) { $0.turn = 16 * f; $0.roll = 3 * f }
        peer.look(2.75, 0.18, to: eyes)
        peer.move(2.8, 0.52, to: body)

        var up = FaceScript(body, eyes)         // scans along the top
        up.look(0.2, 0.12, .snappy) { $0.x = 0.8 * f; $0.y = -1; $0.wide = 0.3 }
        up.move(0.24, 0.45, .spring) { $0.turn = 18 * f; $0.tip = -16; $0.roll = 4 * f }
        up.look(1.1, 0.18, .glide) { $0.x = -0.8 * f; $0.y = -0.95 }
        up.move(1.15, 0.62) { $0.turn = -18 * f; $0.tip = -14; $0.roll = -4 * f }
        up.look(2.15, 0.15, to: eyes)
        up.move(2.2, 0.5, to: body)

        var doubleTake = FaceScript(body, eyes) // looks left, starts right, snaps BACK left ("wait—what was that?!")
        doubleTake.look(0.18, 0.1, .snappy) { $0.x = -0.9 * f }
        doubleTake.move(0.22, 0.34, .spring) { $0.turn = -20 * f; $0.roll = -4 * f }
        doubleTake.look(0.85, 0.12, .snappy) { $0.x = 0.6 * f }
        doubleTake.move(0.88, 0.28) { $0.turn = 10 * f; $0.roll = 2 * f }
        doubleTake.look(1.24, 0.08, .snappy) { $0.x = -1 * f; $0.y = -0.05; $0.wide = 0.75; $0.tilt = -0.4 * f }
        doubleTake.move(1.26, 0.3, .bouncy) { $0.turn = -26 * f; $0.roll = -8 * f; $0.y = -0.022; $0.squash = -0.04; $0.tip = 4 }
        doubleTake.mark(1.42)
        doubleTake.blink(2.2)
        doubleTake.look(2.7, 0.16, to: eyes)
        doubleTake.move(2.75, 0.55, to: body)
        return [sides.clip(3.1), peer.clip(3.6), up.clip(3.0), doubleTake.clip(3.6)]
    }

    private static func running(_ f: Double) -> [FaceClip] {
        // Head down into the work, focused narrowed eyes, unmistakable kinetic rhythm even at 40 pt.
        let body = FaceBody(tip: 6), eyes = FaceEyes(y: 0.42, lids: 0.28)
        var busy = FaceScript(body, eyes)       // working away to an energetic alternating groove
        for beat in 0..<4 {
            let t = 0.04 + Double(beat) * 0.56
            let side = beat % 2 == 0 ? f : -f
            busy.move(t, 0.24, .drop) { $0.y = 0.038; $0.squash = 0.07; $0.roll = 4.5 * side; $0.tip = 10 }
            busy.move(t + 0.24, 0.30, .spring, to: body)
            busy.mark(t + 0.24)
            if beat == 0 || beat == 2 {
                busy.look(t + 0.04, 0.14, .snappy) { $0.x = 0.45 * side }
            }
        }
        busy.look(1.75, 0.16, to: eyes)
        busy.blink(1.96)

        var check = FaceScript(body, eyes)      // snaps up to check output, satisfied mini-nod, back to work
        check.look(0.32, 0.1, .snappy) { $0.x = 0.95 * f; $0.y = -0.2; $0.lids = 0; $0.wide = 0.5 }
        check.move(0.35, 0.38, .spring) { $0.turn = 22 * f; $0.roll = 5 * f; $0.tip = -2; $0.y = -0.015 }
        check.blink(1.0)
        nod(&check, 1.25, depth: 7)
        check.look(1.78, 0.12, .snappy, to: eyes)
        check.move(1.8, 0.32, to: body)
        for (i, t) in [2.14, 2.62].enumerated() {
            let side = i == 0 ? f : -f
            check.move(t, 0.22, .drop) { $0.y = 0.036; $0.squash = 0.068; $0.roll = 4 * side; $0.tip = 10 }
            check.move(t + 0.22, 0.26, .spring, to: body)
            check.mark(t + 0.22)
        }

        var rev = FaceScript(body, eyes)        // leans in intensely watching rapid logs, then quick perk breath
        rev.move(0.2, 0.38) { $0.tip = 12; $0.squash = 0.05; $0.y = 0.022 }
        rev.look(0.2, 0.18) { $0.lids = 0.45; $0.y = 0.55; $0.x = -0.65 * f }
        rev.look(0.7, 0.22, .snappy) { $0.x = 0.7 * f; $0.y = 0.35 }
        rev.move(0.72, 0.34) { $0.turn = 10 * f; $0.roll = 3 * f }
        rev.look(1.18, 0.22, .snappy) { $0.x = -0.55 * f; $0.y = 0.65 }
        rev.move(1.2, 0.34) { $0.turn = -10 * f; $0.roll = -3 * f }
        rev.move(1.75, 0.26, .rise) { $0.tip = -1; $0.squash = -0.055; $0.y = -0.028; $0.turn = 0; $0.roll = 0 }
        rev.look(1.75, 0.14, .snappy) { $0.lids = 0; $0.wide = 0.45; $0.x = 0; $0.y = 0.1 }
        rev.mark(1.9)
        rev.move(2.15, 0.52, .spring, to: body)
        rev.look(2.2, 0.22, to: eyes)
        return [busy.clip(2.4), check.clip(3.2), rev.clip(2.8)]
    }

    private static func writing(_ f: Double) -> [FaceClip] {
        // Eyes on the start of a line, the head with them: two lines typed with kinetic cadence, then a beat in the pause.
        let body = FaceBody(roll: -3, turn: -8, tip: 8), eyes = FaceEyes(x: -0.85, y: 0.32, lids: 0.28)
        func typed(tilt: Double) -> FaceScript {
            var script = FaceScript(body, eyes)
            for line in 0..<2 {
                let t = Double(line) * lineLength
                let rowY = line == 0 ? 0.32 : 0.65
                script.look(t + 0.05, lineLength - 0.16, .linear) { $0.x = 0.88; $0.y = rowY }
                // Mid-line keystroke micro-dip for lively typing rhythm.
                script.move(t + 0.05, (lineLength - 0.16) * 0.5) { $0.turn = 0; $0.roll = tilt * 0.3; $0.y = 0.014; $0.squash = 0.025 }
                script.move(t + 0.05 + (lineLength - 0.16) * 0.5, (lineLength - 0.16) * 0.5) {
                    $0.turn = 9; $0.roll = tilt; $0.y = 0; $0.squash = 0; $0.tip = 8 + Double(line) * 3
                }
                guard line == 0 else { continue }
                // Crisp carriage return to the start of line 2.
                script.move(t + lineLength - 0.11, 0.11, .snappy) { $0.turn = -8; $0.roll = -tilt * 0.7; $0.tip = 11 }
                script.look(t + lineLength - 0.09, 0.09, .snappy) { $0.x = -0.85; $0.y = 0.65 }
            }
            return script
        }
        let end = 2 * lineLength
        let length = end + typingPause

        var plain = typed(tilt: 3)
        plain.look(end, 0.16, .snappy, to: eyes)
        plain.move(end, 0.32, .spring, to: body)

        var pleased = typed(tilt: 6 * f)        // head on one side, widens & nods pleased at the end
        pleased.look(end - 0.08, 0.1, .snappy) { $0.lids = 0; $0.wide = 0.45 }
        pleased.move(end - 0.06, 0.1, .snappy) { $0.tip = 15; $0.y = 0.018; $0.squash = 0.035 }
        pleased.mark(end + 0.04)
        pleased.look(end + 0.06, 0.18, to: eyes)
        pleased.move(end + 0.04, 0.28, .spring, to: body)

        var revise = FaceScript(body, eyes)     // starts line 1, brief squint-tilt rethink, brisk finish + line 2
        revise.look(0.05, 0.42, .linear) { $0.x = 0.05; $0.y = 0.32 }
        revise.move(0.05, 0.42) { $0.turn = 0; $0.roll = -7 * f }
        revise.look(0.5, 0.14) { $0.lids = 0.52; $0.tilt = 0.35 * f }
        revise.look(0.78, 0.5, .snappy) { $0.x = 0.88; $0.lids = 0.28; $0.tilt = 0 }
        revise.move(0.78, 0.5, .snappy) { $0.turn = 9; $0.roll = 4 * f }
        revise.move(lineLength - 0.11, 0.11, .snappy) { $0.turn = -8; $0.roll = -3; $0.tip = 11 }
        revise.look(lineLength - 0.09, 0.09, .snappy) { $0.x = -0.85; $0.y = 0.65 }
        revise.look(lineLength + 0.05, lineLength - 0.16, .linear) { $0.x = 0.88; $0.y = 0.65 }
        revise.move(lineLength + 0.05, lineLength - 0.16) { $0.turn = 9; $0.roll = 3; $0.tip = 11 }
        revise.look(end, 0.16, to: eyes)
        revise.move(end, 0.32, .spring, to: body)
        return [plain.clip(length), pleased.clip(length), revise.clip(length)]
    }

    private static func browsing() -> [FaceClip] {
        // The eyes on the pointer, the head turning after them.
        func at(_ stop: CGPoint, turn: Double, rollScale: Double = 4.5) -> (FaceBody, FaceEyes) {
            let x = (stop.x - 0.5) * 2.6, y = (stop.y - 0.5) * 2.6
            return (FaceBody(roll: x * rollScale, turn: x * turn, tip: y * 13), FaceEyes(x: x, y: y))
        }
        let last = stops[stops.count - 1]
        let home = at(last, turn: 18)
        var clicks = FaceScript(home.0, home.1)     // crisp tactile click-peck at each stop
        var follows = FaceScript(home.0, home.1)    // expressive sweeping head following the eyes
        var inspect = FaceScript(home.0, home.1)    // curious tilt + focused squint before clicking
        for (index, stop) in stops.enumerated() {
            let t = Double(index) * stopLength
            let (body, eyes) = at(stop, turn: 18)
            clicks.look(t, 0.24, .snappy, to: eyes)
            clicks.move(t + 0.02, 0.32, .spring, to: body)
            clicks.move(t + 0.35, 0.07, .drop) { $0.squash = 0.065; $0.tip = body.tip + 7; $0.y = 0.02 }
            clicks.mark(t + 0.36)
            clicks.move(t + 0.42, 0.28, .bouncy, to: body)

            let (swung, looked) = at(stop, turn: index == stops.count - 1 ? 18 : 26)
            follows.look(t, 0.2, .snappy, to: looked)
            follows.move(t + 0.06, 0.46, .spring, to: swung)
            if index == 1 { follows.blink(t + 0.6) }

            let (tilted, gazed) = at(stop, turn: 18, rollScale: index == stops.count - 1 ? 4.5 : 8.5)
            inspect.look(t, 0.22, .snappy) {
                $0 = gazed
                if index == 1 || index == 2 { $0.lids = 0.32; $0.tilt = 0.35 * (gazed.x >= 0 ? 1 : -1) }
            }
            inspect.move(t + 0.04, 0.34, .spring, to: tilted)
            if index < stops.count - 1 {
                inspect.look(t + 0.42, 0.1, .snappy) { $0.lids = 0; $0.wide = 0.4; $0.tilt = 0 }
                inspect.move(t + 0.42, 0.07, .drop) { $0.squash = 0.055; $0.y = 0.015 }
                inspect.mark(t + 0.43)
                inspect.move(t + 0.49, 0.28, .spring, to: tilted)
            }
        }
        let length = Double(stops.count) * stopLength
        return [clicks.clip(length), follows.clip(length), inspect.clip(length)]
    }

    private static func messaging(_ f: Double) -> [FaceClip] {
        // Turned eagerly to the side it's sending to.
        let body = FaceBody(x: 0.025 * f, roll: 4 * f, turn: 24 * f), eyes = FaceEyes(x: f)
        var send = FaceScript(body, eyes)       // juicy Pixar anticipation wind-up and energetic fling, twice
        for t in [0.3, 1.55] {
            send.move(t, 0.22, .glide) { $0.x = -0.02 * f; $0.turn = 10 * f; $0.squash = -0.06; $0.tip = -7; $0.roll = -3 * f }
            send.look(t, 0.16) { $0.wide = 0.35 }
            send.move(t + 0.22, 0.13, .drop) { $0.x = 0.068 * f; $0.turn = 32 * f; $0.squash = 0.065; $0.tip = 8; $0.roll = 7 * f }
            send.look(t + 0.22, 0.12) { $0.wide = 0; $0.lids = 0.2 }
            send.mark(t + 0.35)
            send.move(t + 0.35, 0.5, .bouncy, to: body)
            send.look(t + 0.38, 0.18, to: eyes)
            if t < 1.0 { send.blink(1.08) }
        }

        var back = FaceScript(body, eyes)       // warm glance back at you, friendly blink, and away again
        back.look(0.62, 0.14, .snappy) { $0.x = 0; $0.wide = 0.4 }
        back.move(0.66, 0.46, .spring) { $0.turn = 0; $0.x = 0; $0.roll = -3 * f; $0.tip = -2 }
        back.doubleBlink(1.25)
        back.look(1.98, 0.14, .snappy, to: eyes)
        back.move(2.02, 0.52, .spring, to: body)

        var listen = FaceScript(body, eyes)     // leans attentively as if receiving a reply, nods twice, sends back
        listen.move(0.2, 0.4, .spring) { $0.turn = 28 * f; $0.roll = 9 * f; $0.tip = -4 }
        listen.look(0.2, 0.18) { $0.wide = 0.35; $0.tilt = 0.25 * f }
        nod(&listen, 0.7, depth: 8)
        nod(&listen, 1.32, depth: 7)
        listen.move(1.95, 0.16, .drop) { $0.x = 0.06 * f; $0.squash = 0.055; $0.tip = 6 }
        listen.mark(2.1)
        listen.move(2.12, 0.52, .spring, to: body)
        listen.look(2.12, 0.2, to: eyes)
        return [send.clip(2.8), back.clip(3.0), listen.clip(3.0)]
    }

    private static func making(_ f: Double) -> [FaceClip] {
        // Chin up, eyes up at what it's creating.
        let body = FaceBody(tip: -5), eyes = FaceEyes(y: -0.55)
        var wiggle = FaceScript(body, eyes)     // joyful rhythmic side-to-side dance
        wiggle.move(0.22, 0.28, .spring) { $0.roll = -13 * f; $0.y = 0.02; $0.squash = 0.045; $0.turn = -8 * f }
        wiggle.look(0.22, 0.12, .snappy) { $0.x = -0.6 * f; $0.wide = 0.4 }
        wiggle.move(0.55, 0.34, .spring) { $0.roll = 13 * f; $0.y = -0.022; $0.squash = -0.045; $0.turn = 8 * f }
        wiggle.look(0.58, 0.12, .snappy) { $0.x = 0.6 * f; $0.wide = 0.45 }
        wiggle.move(0.95, 0.32, .spring) { $0.roll = -10 * f; $0.y = 0.015; $0.squash = 0.035; $0.turn = -6 * f }
        wiggle.look(0.98, 0.12, .snappy) { $0.x = -0.4 * f }
        wiggle.move(1.32, 0.48, .bouncy, to: body)
        wiggle.look(1.36, 0.18, to: eyes)

        var bounce = FaceScript(body, eyes)     // two lively hops with playful mid-air tilts
        bounce.look(0.25, 0.14) { $0.wide = 0.6; $0.y = -0.7 }
        hop(&bounce, 0.18, height: 0.095, roll: 7 * f)
        bounce.look(0.85, 0.16, to: eyes)
        bounce.look(1.22, 0.14) { $0.wide = 0.65; $0.y = -0.7 }
        hop(&bounce, 1.15, height: 0.095, roll: -7 * f)
        bounce.look(1.85, 0.18, to: eyes)

        var admire = FaceScript(body, eyes)     // steps back and admires from both angles, then bright proud perk
        admire.move(0.24, 0.5, .spring) { $0.turn = 24 * f; $0.roll = 7 * f; $0.x = 0.02 * f }
        admire.look(0.24, 0.15, .snappy) { $0.x = 0.75 * f; $0.lids = 0.22; $0.tilt = 0.3 * f }
        admire.move(1.12, 0.6, .spring) { $0.turn = -24 * f; $0.roll = -7 * f; $0.x = -0.02 * f }
        admire.look(1.15, 0.15, .snappy) { $0.x = -0.75 * f; $0.lids = 0.22; $0.tilt = -0.3 * f }
        admire.move(1.98, 0.24, .rise) { $0.turn = 0; $0.roll = 0; $0.x = 0; $0.tip = -11; $0.squash = -0.065; $0.y = -0.028 }
        admire.look(1.96, 0.14, .snappy) { $0.x = 0; $0.lids = 0; $0.wide = 0.7; $0.tilt = 0 }
        admire.move(2.28, 0.48, .spring, to: body)
        admire.look(2.35, 0.2, to: eyes)

        var flourish = FaceScript(body, eyes)   // smooth conducting figure-8 sway
        flourish.move(0.2, 0.55) { $0.turn = 16 * f; $0.tip = -12; $0.roll = 8 * f; $0.y = -0.02 }
        flourish.look(0.2, 0.2) { $0.x = 0.6 * f; $0.y = -0.85; $0.wide = 0.35 }
        flourish.move(0.85, 0.6) { $0.turn = -16 * f; $0.tip = 2; $0.roll = -8 * f; $0.y = 0.015 }
        flourish.look(0.85, 0.2) { $0.x = -0.6 * f; $0.y = -0.25 }
        flourish.move(1.55, 0.5) { $0.turn = 10 * f; $0.tip = -10; $0.roll = 5 * f; $0.y = -0.015 }
        flourish.look(1.55, 0.2) { $0.x = 0.4 * f; $0.y = -0.75 }
        flourish.move(2.15, 0.5, .spring, to: body)
        flourish.look(2.15, 0.2, to: eyes)
        return [wiggle.clip(2.3), bounce.clip(2.4), admire.clip(3.0), flourish.clip(2.8)]
    }

    private static func replying(_ f: Double) -> [FaceClip] {
        // Facing you warmly as it talks.
        var along = FaceScript()                // expressive conversational nods of varied depth
        nod(&along, 0.15, depth: 12)
        nod(&along, 0.72, depth: 8)
        nod(&along, 1.3, depth: 11)
        along.blink(1.98)

        var sway = FaceScript()                 // warm conversational sway, nods, expressive glance aside
        sway.move(0.12, 0.72) { $0.turn = 14 * f; $0.roll = 6 * f; $0.tip = -2 }
        sway.look(0.18, 0.24) { $0.x = 0.45 * f; $0.wide = 0.2 }
        nod(&sway, 1.02, depth: 10)
        sway.look(1.56, 0.14, .snappy) { $0.x = 0.8 * f }
        sway.move(1.88, 0.78, .spring, to: .rest)
        sway.look(1.94, 0.26, to: .rest)
        sway.blink(2.5)

        var bright = FaceScript()               // perks up brightly on an exciting point, then warm emphasis nod
        bright.look(0.22, 0.12, .snappy) { $0.y = -0.55; $0.wide = 0.75 }
        bright.move(0.24, 0.32, .bouncy) { $0.squash = -0.075; $0.tip = -9; $0.y = -0.036 }
        bright.move(0.86, 0.34, to: .rest)
        bright.look(0.9, 0.18, to: .rest)
        nod(&bright, 1.32, depth: 12)
        bright.blink(1.92)

        var explain = FaceScript()              // gestures gently left then right, maintaining warm eye contact
        explain.move(0.18, 0.55, .spring) { $0.turn = -14 * f; $0.roll = -5 * f; $0.tip = 4 }
        explain.look(0.2, 0.18) { $0.x = -0.35 * f; $0.wide = 0.2 }
        explain.mark(0.55)
        explain.move(1.05, 0.6, .spring) { $0.turn = 14 * f; $0.roll = 5 * f; $0.tip = 3 }
        explain.look(1.08, 0.18) { $0.x = 0.35 * f; $0.wide = 0.25 }
        explain.mark(1.45)
        explain.move(1.86, 0.5, .spring, to: .rest)
        explain.look(1.9, 0.22, to: .rest)
        nod(&explain, 2.38, depth: 8)
        return [along.clip(2.4), sway.clip(3.0), bright.clip(2.3), explain.clip(3.0)]
    }

    private static func asking(_ f: Double) -> [FaceClip] {
        // Head cocked endearingly to one side, wide expectant look at you.
        let body = FaceBody(roll: -11 * f, tip: -4), eyes = FaceEyes(y: -0.15, wide: 0.25, tilt: 0.25 * f)
        var hops = FaceScript(body, eyes)       // two springy hops: well?
        hops.blink(0.28)
        hops.look(0.82, 0.14) { $0.wide = 0.75; $0.y = -0.25 }
        hops.mark(hop(&hops, 0.75, height: 0.085))
        hops.look(1.48, 0.14) { $0.wide = 0.8; $0.y = -0.28 }
        hops.mark(hop(&hops, 1.42, height: 0.085))
        hops.look(2.05, 0.16, to: eyes)
        hops.blink(2.22)

        var tilt = FaceScript(body, eyes)       // playful curiosity tilt all the way to the other side and back
        tilt.move(0.55, 0.52, .bouncy) { $0.roll = 12 * f; $0.turn = 10 * f; $0.tip = -6 }
        tilt.look(0.55, 0.18, .snappy) { $0.x = 0.38 * f; $0.wide = 0.6; $0.tilt = -0.45 * f }
        tilt.blink(1.45)
        tilt.move(2.05, 0.55, .bouncy, to: body)
        tilt.look(2.05, 0.2, to: eyes)

        var curious = FaceScript(body, eyes)    // leans closer expectantly with wide eyes and a gentle double-blink
        curious.move(0.35, 0.5, .spring) { $0.roll = -15 * f; $0.tip = -9; $0.squash = -0.06; $0.y = -0.028 }
        curious.look(0.35, 0.18) { $0.wide = 0.85; $0.y = -0.22; $0.tilt = 0.45 * f }
        curious.doubleBlink(1.15)
        curious.move(2.05, 0.52, .spring, to: body)
        curious.look(2.05, 0.22, to: eyes)
        return [hops.clip(2.6), tilt.clip(3.2), curious.clip(2.8)]
    }

    private static func done(_ f: Double) -> [FaceClip] {
        // Celebratory jump (plain, cartwheel, or full 3D pirouette spin), eyes bright and up; juicy landing at 0.66 s,
        // leans back pleased and blinks twice warmly at you.
        enum Trick { case plain, cartwheel, pirouette }
        func jump(_ trick: Trick) -> FaceClip {
            let spinRoll = trick == .cartwheel ? 360 * f : 0
            let spinTurn = trick == .pirouette ? 360 * f : 0
            var script = FaceScript()
            script.look(0.04, 0.14, .snappy) { $0.y = -0.65; $0.wide = 0.85 }
            script.move(0, 0.16, .glide) { $0.squash = 0.11; $0.y = 0.02 }
            script.move(0.16, 0.26, .rise) {
                $0.y = -0.19; $0.squash = -0.095; $0.tip = -10; $0.roll = spinRoll * 0.55; $0.turn = spinTurn * 0.55
            }
            script.move(0.42, 0.24, .drop) {
                $0.y = 0; $0.squash = 0.11; $0.tip = 2; $0.roll = spinRoll; $0.turn = spinTurn
            }
            script.mark(0.66)
            script.move(0.66, 0.3, .spring) { $0.squash = 0; $0.tip = 0 }
            script.move(1.0, 0.34) { $0.tip = -9; $0.roll = spinRoll + 7 * f }
            // Settles cleanly back to rest well before `length` so the C³ spring reaches zero velocity.
            script.move(1.58, 0.42, .glide) { $0.tip = 0; $0.roll = spinRoll; $0.turn = spinTurn }
            script.look(0.78, 0.2, .glide) { $0.y = 0; $0.wide = 0.3 }
            script.doubleBlink(1.10)
            script.look(1.70, 0.22, .glide, to: .rest)
            return script.clip(BotMood.done.length)
        }
        return [jump(.plain), jump(.cartwheel), jump(.pirouette)]
    }

    private static func failed(_ f: Double) -> [FaceClip] {
        // Routine 0: sharp flinch and "no!" head-shake with eyes screwed shut, then a defeated droop that settles cleanly.
        var shake = FaceScript()
        shake.look(0, 0.1, .drop) { $0.lids = 0.95 }
        shake.move(0.02, 0.15, .snappy) { $0.x = -0.036 * f; $0.turn = -22 * f; $0.roll = -6 * f }
        shake.move(0.17, 0.19, .snappy) { $0.x = 0.036 * f; $0.turn = 20 * f; $0.roll = 6 * f }
        shake.move(0.36, 0.17, .snappy) { $0.x = -0.018 * f; $0.turn = -10 * f; $0.roll = -3 * f }
        shake.move(0.53, 0.16) { $0.x = 0; $0.turn = 0; $0.roll = 0 }
        shake.move(0.7, 0.36) { $0.tip = 17; $0.y = 0.045; $0.squash = 0.065 }
        shake.look(0.72, 0.26) { $0.y = 0.65; $0.lids = 0.52 }
        shake.move(1.18, 0.36, .glide, to: .rest)
        shake.look(1.22, 0.26, .glide, to: .rest)

        // Routine 1: startled recoil hop-back, quick shudder, then weary tilted slump that settles cleanly.
        var recoil = FaceScript()
        recoil.look(0, 0.09, .drop) { $0.lids = 0.95 }
        recoil.move(0.02, 0.14, .rise) { $0.y = -0.04; $0.tip = -10; $0.squash = -0.05; $0.x = -0.024 * f; $0.turn = -14 * f }
        recoil.move(0.16, 0.16, .snappy) { $0.y = 0; $0.tip = 0; $0.squash = 0.03; $0.x = 0.028 * f; $0.turn = 16 * f; $0.roll = 4 * f }
        recoil.move(0.32, 0.16, .snappy) { $0.x = -0.016 * f; $0.turn = -9 * f; $0.roll = -2 * f; $0.squash = 0 }
        recoil.move(0.48, 0.16) { $0.x = 0; $0.turn = 0; $0.roll = 0 }
        recoil.move(0.68, 0.36) { $0.tip = 16; $0.roll = 9 * f; $0.y = 0.042; $0.squash = 0.06 }
        recoil.look(0.7, 0.26) { $0.y = 0.6; $0.lids = 0.5; $0.tilt = -0.3 * f }
        recoil.move(1.18, 0.36, .glide, to: .rest)
        recoil.look(1.22, 0.26, .glide, to: .rest)
        return [shake.clip(BotMood.failed.length), recoil.clip(BotMood.failed.length)]
    }
}

// MARK: - A face's loop

/// The routines one face plays for a mood, in its own shuffled order: twice through, never the same one twice running
/// (so a long step doesn't read as a loop), or the one routine of a once-only mood. Faces of the same bot given the same
/// seed play the same order (its row and its chat's header move together).
nonisolated struct FaceLoop: Sendable {
    let clips: [FaceClip]
    /// When each routine starts.
    let starts: [Double]
    let period: Double

    init(_ mood: BotMood, facing: Int, seed: Int) {
        let all = FaceRoutines.clips(mood, facing: facing)
        var dice = MatrixActMasks.Dice(seed)
        var order: [Int]
        if mood.once || all.count == 1 {
            order = [dice.int(0..<all.count)]
        } else {
            func shuffled() -> [Int] {
                var picks = Array(all.indices)
                for i in picks.indices.reversed() { picks.swapAt(i, dice.int(0..<(i + 1))) }
                return picks
            }
            let first = shuffled()
            var second = shuffled()
            for _ in 0..<12 where second.first == first.last || second.last == first.first { second = shuffled() }
            order = first + second
        }
        clips = order.map { all[$0] }
        var clock = 0.0
        var starts: [Double] = []
        for clip in clips {
            starts.append(clock)
            clock += clip.length
        }
        self.starts = starts
        period = clock
    }

    /// Every beat a light may flash on, in loop time.
    var marks: [Double] { zip(clips, starts).flatMap { clip, start in clip.marks.map { $0 + start } } }

    /// The pose `t` seconds in (wrapping round).
    func pose(at t: Double) -> (body: FaceBody, eyes: FaceEyes) {
        var t = t.truncatingRemainder(dividingBy: period)
        if t < 0 { t += period }
        let index = starts.lastIndex { $0 <= t } ?? 0
        return (clips[index].body(at: t - starts[index]), clips[index].eyes(at: t - starts[index]))
    }

    /// The loop sampled about `rate` times a second, each routine on its own even steps: the moments, the poses.
    func samples(rate: Double = 30) -> [(at: Double, body: FaceBody, eyes: FaceEyes)] {
        var out: [(at: Double, body: FaceBody, eyes: FaceEyes)] = []
        for (clip, start) in zip(clips, starts) {
            for t in clip.times(rate: rate) where out.isEmpty || start + t > out[out.count - 1].at + 1e-9 {
                out.append((start + t, clip.body(at: t), clip.eyes(at: t)))
            }
        }
        if !out.isEmpty {
            out[0].at = 0
            out[out.count - 1].at = period
        }
        return out
    }

    /// Linearly interpolated pose at `t` in `samples` (`period` long), wrapping when `!once` and clamping when `once`.
    static func interpolated(in samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], at t: Double, period: Double,
                             once: Bool) -> (body: FaceBody, eyes: FaceEyes) {
        guard !samples.isEmpty else { return (.rest, .rest) }
        guard samples.count > 1, period > 0 else { return (samples[0].body, samples[0].eyes) }
        var u = once ? min(max(t, 0), period) : t.truncatingRemainder(dividingBy: period)
        if u < 0 { u += period }
        if u <= samples[0].at { return (samples[0].body, samples[0].eyes) }
        let last = samples.count - 1
        if u >= samples[last].at { return (samples[last].body, samples[last].eyes) }
        var low = 0, high = last
        while low + 1 < high {
            let mid = (low + high) >> 1
            if samples[mid].at <= u { low = mid } else { high = mid }
        }
        let a = samples[low], b = samples[high], span = b.at - a.at
        let k = span > 1e-12 ? (u - a.at) / span : 0
        return (a.body.mixed(b.body, k), a.eyes.mixed(b.eyes, k))
    }

    /// Uniformly spaced `(at, turn, tip)` poses at `rate` Hz over `period`, so temporal smoothing across the loop seam
    /// never sees a half-width final interval.
    static func uniformPoses(from samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], period: Double, rate: Double = 30,
                             once: Bool) -> [(at: Double, turn: Double, tip: Double)] {
        guard samples.count > 1, period > 0 else {
            return samples.map { ($0.at, $0.body.turn, $0.body.tip) }
        }
        let steps = max(1, Int((period * rate).rounded()))
        var out: [(at: Double, turn: Double, tip: Double)] = []
        out.reserveCapacity(steps + 1)
        for k in 0...steps {
            let at = k == steps ? period : period * Double(k) / Double(steps)
            if !once && k == steps {
                out.append((period, out[0].turn, out[0].tip))
            } else {
                let pose = interpolated(in: samples, at: at, period: period, once: once)
                out.append((at, pose.body.turn, pose.body.tip))
            }
        }
        return out
    }

    /// The loop as a soft body plays it (a Shapes head's), `rate` times a second (owner, 2026-10-28: "They are not smooth
    /// enough. Do better.", then of Grok Bot's: "smooth animation. The eyes feel alive. The body/face moves in a way that
    /// is fluid. Never jittery."). The body follows the routine on a spring that never runs past and back (one that does
    /// reads as a shiver), so no move starts or stops dead. The eyes lead it: where they look is kept in the world, a look
    /// plus the body's own turn and tip (FaceEyes.across, .down), and they get there quickly, so as the head turns after
    /// them they come back to its middle, still on the same spot. It breathes, slowly, under it all. Blinks and narrowing
    /// keep their own timing. A loop's runs on from its end into its start; one played `once` starts where the routine does.
    func softSamples(once: Bool, rate: Double = 60) -> [(at: Double, body: FaceBody, eyes: FaceEyes)] {
        let raw = samples(rate: rate)
        guard raw.count > 1 else { return raw }
        // x, y, roll, turn, tip, squash; where the eyes look across and up, in the world; eye wide & tilt.
        // A whole turn is no jump (a turn is a turn).
        var targets = raw.map {
            [$0.body.x, $0.body.y, $0.body.roll, $0.body.turn, $0.body.tip, $0.body.squash,
             $0.eyes.x, $0.eyes.y, $0.eyes.wide, $0.eyes.tilt]
        }
        for i in 1..<targets.count {
            for c in 2...4 {
                while targets[i][c] - targets[i - 1][c] > 180 { targets[i][c] -= 360 }
                while targets[i][c] - targets[i - 1][c] < -180 { targets[i][c] += 360 }
            }
        }
        for i in targets.indices {
            targets[i][6] += targets[i][3] / FaceEyes.across
            targets[i][7] += targets[i][4] / FaceEyes.down
        }
        let targetWrap = (0..<10).map { targets[targets.count - 1][$0] - targets[0][$0] }
        // Two-stage cascaded critically damped spring (C³ smooth: position, velocity, AND acceleration are all continuous,
        // so motion flows like liquid butter with zero hard starts, hard stops, or overshoot ringing).
        let omega = [4.4, 4.4, 2.8, 2.8, 2.8, 4.4, 6.2, 6.2, 5.2, 4.6].map { 2 * Double.pi * $0 }
        let omega2 = [6.8, 6.8, 4.8, 4.8, 4.8, 6.8, 9.5, 9.5, 8.0, 7.2].map { 2 * Double.pi * $0 }
        func filter(_ input: [[Double]], freq: [Double]) -> [[Double]] {
            let wrap = (0..<10).map { input[input.count - 1][$0] - input[0][$0] }
            var at = input[0], speed = [Double](repeating: 0, count: 10)
            var res: [[Double]] = []
            res.reserveCapacity(raw.count)
            func step(_ i: Int) {
                let dt = raw[i + 1].at - raw[i].at
                guard dt > 0 else { return }
                let t0 = input[i], t1 = input[i + 1]
                for c in 0..<10 {
                    let w = freq[c], e = exp(-w * dt)
                    let m = 0.5 * (t0[c] + t1[c])
                    let dx = at[c] - m
                    let c2 = speed[c] + w * dx
                    at[c] = m + (dx + c2 * dt) * e
                    speed[c] = (speed[c] - w * c2 * dt) * e
                }
            }
            if !once {
                // Critically damped spring at ≥2.8 Hz decays below 1e-21 over 3.2 s: warming up the final 3.2 s of the
                // loop (or a full pass for shorter loops) converges the periodic state to full Double precision while
                // staying 3.5× faster on the main thread than running multiple full passes.
                let warmup = min(period, 3.2)
                let warmStart = raw.firstIndex { $0.at >= period - warmup } ?? 0
                at = input[warmStart]
                for i in warmStart..<(raw.count - 1) { step(i) }
                for c in [2, 3, 4, 6, 7] { at[c] -= wrap[c] }
                if period < 3.2 {
                    for i in 0..<(raw.count - 1) { step(i) }
                    for c in [2, 3, 4, 6, 7] { at[c] -= wrap[c] }
                }
            }
            for i in 0..<(raw.count - 1) {
                res.append(at)
                step(i)
            }
            if !once, let first = res.first {
                // Guarantee bit-exact loop closure (modulo full 360° wraps on angle channels).
                var closed = first
                for c in [2, 3, 4, 6, 7] { closed[c] += wrap[c] }
                res.append(closed)
            } else {
                res.append(at)
            }
            return res
        }
        let stage1 = filter(targets, freq: omega)
        var out = filter(stage1, freq: omega2)
        // A once-only routine settles cleanly to its exact resting end pose with zero velocity and zero acceleration, so
        // it never slams to a halt at `period` or jerks on handoff back to rest.
        if once, let finalTarget = targets.last {
            let settleWindow = min(0.32, period * 0.25)
            let settleStart = period - settleWindow
            for i in raw.indices where raw[i].at > settleStart {
                let w = FaceBody.quintic((raw[i].at - settleStart) / max(settleWindow, 1e-6))
                for c in 0..<10 { out[i][c] += (finalTarget[c] - out[i][c]) * w }
            }
            out[out.count - 1] = finalTarget
        }
        // A gentle organic breath about every 3.4 s (a whole number a loop, so it joins up): subtle lift, stretch, and
        // harmonic float so held moments stay alive.
        let breaths = once ? 0 : max(1, (period / 3.4).rounded())
        let lastIndex = raw.count - 1
        let baseSway = once ? 0 : sin(0.65)
        var result: [(at: Double, body: FaceBody, eyes: FaceEyes)] = []
        result.reserveCapacity(raw.count)
        for (i, (sample, c)) in zip(raw, out).enumerated() {
            let seam = !once && (i == 0 || i == lastIndex)
            let phase = 2 * Double.pi * breaths * sample.at / period
            let breath = seam ? 0 : sin(phase)
            let sway = once ? 0 : (seam ? baseSway : sin(phase + 0.65))
            result.append((sample.at,
                           FaceBody(x: c[0], y: c[1] - 0.004 * breath, roll: c[2] + 0.8 * sway, turn: c[3], tip: c[4] - 0.5 * breath,
                                    squash: c[5] - 0.015 * breath),
                           FaceEyes(x: c[6] - c[3] / FaceEyes.across, y: c[7] - c[4] / FaceEyes.down, lids: sample.eyes.lids,
                                    wide: c[8], tilt: c[9])))
        }
        if !once, let first = result.first {
            // Bit-exact periodic closure across all channels (preserving any full-turn angle wrap).
            var endBody = first.body
            endBody.roll += targetWrap[2]; endBody.turn += targetWrap[3]; endBody.tip += targetWrap[4]
            result[lastIndex] = (period, endBody, first.eyes)
        }
        return result
    }
}

/// [moods] How a Shapes head's soft body goes on moving after the body does (owner, 2026-10-28: "The blobs need to be
/// much more animated"): it squashes as it takes off and lands, stretches in the air, leans on past the end of each
/// swing and settles, once, softly (a wobble that rings on reads as a shiver: owner, of Grok Bot's, "Never jittery"). `squash` as FaceBody's (+ wider and shorter); `lean` how far its top
/// runs on sideways, as a share of how high it is (+ right).
nonisolated struct FaceJelly: Hashable, Sendable {
    var squash = 0.0, lean = 0.0

    static let rest = FaceJelly()

    /// Its wobble at each of `samples` (a loop `period` long): a damped spring each way. It stretches with how fast the body goes up or
    /// down, so a landing's sudden stop throws it into a squash; it runs on past each squash and nod, and its top lags
    /// each swing and carries on past its end. A loop's wobble runs on from its end into its start; one played `once`
    /// starts still and has settled by its end, where it's held.
    static func follow(_ samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], period: Double, once: Bool) -> [FaceJelly] {
        guard samples.count > 1 else { return samples.map { _ in .rest } }
        // Silky, high-damping plush spring (0.82 damping: settles smoothly in one creamy motion with zero jitter/ringing).
        let degree = Double.pi / 180, omega = 2 * Double.pi * 2.0, damping = 0.82
        let rawSpeeds: [(stretch: Double, down: Double, across: Double, swing: Double)] = (0..<(samples.count - 1)).map { i in
            let a = samples[i], b = samples[i + 1], span = max(b.at - a.at, 1e-6)
            let vy = (b.body.y - a.body.y) / span
            // Smooth C∞ magnitude (no V-shaped kink at hop apex where vy crosses zero).
            let stretch = -0.075 * (sqrt(vy * vy + 0.01) - 0.1)
            let down = ((b.body.squash - a.body.squash) * 1.45 + (b.body.tip - a.body.tip) * degree * 0.55) / span
            let across = (b.body.x - a.body.x) * 4.5 / span
            let swing = ((b.body.roll - a.body.roll) * 2.2 + (b.body.turn - a.body.turn) * 1.05) * degree / span
            return (stretch, down, across, swing)
        }
        // Light 3-tap smoothing on velocities eliminates finite-difference noise before differentiation.
        let n = rawSpeeds.count
        let speeds: [(stretch: Double, down: Double, across: Double, swing: Double)] = (0..<n).map { i in
            let p = rawSpeeds[once ? max(0, i - 1) : (i - 1 + n) % n]
            let c = rawSpeeds[i]
            let q = rawSpeeds[once ? min(n - 1, i + 1) : (i + 1) % n]
            return (0.25 * p.stretch + 0.5 * c.stretch + 0.25 * q.stretch,
                    0.25 * p.down + 0.5 * c.down + 0.25 * q.down,
                    0.25 * p.across + 0.5 * c.across + 0.25 * q.across,
                    0.25 * p.swing + 0.5 * c.swing + 0.25 * q.swing)
        }
        var squash = (at: 0.0, speed: 0.0), lean = (at: 0.0, speed: 0.0)
        var before = once ? (stretch: 0.0, down: 0.0, across: 0.0, swing: 0.0) : speeds[speeds.count - 1]
        func advance(_ i: Int) {
            let speed = speeds[i]
            // A change in speed pushes the soft body the other way (it carries on as the body stops, lags as it goes).
            squash.speed -= speed.down - before.down
            lean.speed -= speed.across - before.across + speed.swing - before.swing
            before = speed
            let span = samples[i + 1].at - samples[i].at, steps = max(1, Int((span * 120).rounded(.up))), dt = span / Double(steps)
            for _ in 0..<steps {
                squash.speed += (-omega * omega * (squash.at - speed.stretch) - 2 * damping * omega * squash.speed) * dt
                squash.at += squash.speed * dt
                lean.speed += (-omega * omega * lean.at - 2 * damping * omega * lean.speed) * dt
                lean.at += lean.speed * dt
            }
        }
        if !once {
            // Decay rate 0.82 * 2π * 2.0 ≈ 10.3 s⁻¹ drops below 1e-18 over 4.2 s, giving exact periodic steady-state.
            let warmup = min(period, 4.2)
            let warmStart = samples.firstIndex { $0.at >= period - warmup } ?? 0
            before = speeds[(warmStart - 1 + speeds.count) % speeds.count]
            for i in warmStart..<speeds.count { advance(i) }
            if period < 4.2 {
                for i in 0..<speeds.count { advance(i) }
            }
        }
        var out: [FaceJelly] = []
        out.reserveCapacity(samples.count)
        for i in 0..<speeds.count {
            out.append(FaceJelly(squash: squash.at, lean: lean.at))
            advance(i)
        }
        out.append(!once ? out[0] : FaceJelly(squash: squash.at, lean: lean.at))
        // Eased to a limit, not cut off at it (a cut-off reads as a jolt); a once-only wobble eased out C²-smoothly by its end.
        func limit(_ v: Double, _ most: Double) -> Double { most * tanh(v / most) }
        var result = zip(samples, out).map { sample, jelly in
            let fade = once ? FaceBody.quintic((period - sample.at) / 0.4) : 1
            return FaceJelly(squash: limit(jelly.squash, jelly.squash < 0 ? 0.16 : 0.2) * fade, lean: limit(jelly.lean, 0.14) * fade)
        }
        if !once, let first = result.first { result[result.count - 1] = first }
        return result
    }

    /// Linearly interpolated wobble at `t` in `wobble` (`samples` timestamps, `period` long).
    static func interpolated(in wobble: [FaceJelly], samples: [(at: Double, body: FaceBody, eyes: FaceEyes)], at t: Double,
                             period: Double, once: Bool) -> FaceJelly {
        guard wobble.count == samples.count, !wobble.isEmpty else { return .rest }
        guard wobble.count > 1, period > 0 else { return wobble[0] }
        var u = once ? min(max(t, 0), period) : t.truncatingRemainder(dividingBy: period)
        if u < 0 { u += period }
        if u <= samples[0].at { return wobble[0] }
        let last = samples.count - 1
        if u >= samples[last].at { return wobble[last] }
        var low = 0, high = last
        while low + 1 < high {
            let mid = (low + high) >> 1
            if samples[mid].at <= u { low = mid } else { high = mid }
        }
        let span = samples[high].at - samples[low].at
        let k = span > 1e-12 ? (u - samples[low].at) / span : 0
        let a = wobble[low], b = wobble[high]
        return FaceJelly(squash: a.squash + (b.squash - a.squash) * k, lean: a.lean + (b.lean - a.lean) * k)
    }

    /// How far `box` (the eyes) can go each way and stay `margin` inside the outline (the closed spline through
    /// `outline`), along lines through its sides and middle; 0 where it's that close already.
    static func room(for box: CGRect, in outline: [CGPoint], margin: Double) -> (left: Double, right: Double, up: Double, down: Double) {
        let edge = HeadGeometry.spline(outline).dense
        guard edge.count > 2 else { return (0, 0, 0, 0) }
        let segments = edge.indices.map { (edge[$0], edge[($0 + 1) % edge.count]) }
        func xs(at y: Double) -> [Double] {
            segments.compactMap { a, b in
                guard a.y != b.y, (a.y - y) * (b.y - y) <= 0 else { return nil }
                return a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
            }
        }
        func ys(at x: Double) -> [Double] {
            segments.compactMap { a, b in
                guard a.x != b.x, (a.x - x) * (b.x - x) <= 0 else { return nil }
                return a.y + (x - a.x) / (b.x - a.x) * (b.y - a.y)
            }
        }
        let rows = [box.minY, box.midY, box.maxY], columns = [box.minX, box.midX, box.maxX]
        let right: Double = rows.map { (xs(at: $0).filter { $0 > box.midX }.min() ?? box.maxX) - box.maxX }.min() ?? 0
        let left: Double = rows.map { box.minX - (xs(at: $0).filter { $0 < box.midX }.max() ?? box.minX) }.min() ?? 0
        let up: Double = columns.map { box.minY - (ys(at: $0).filter { $0 < box.midY }.max() ?? box.minY) }.min() ?? 0
        let down: Double = columns.map { (ys(at: $0).filter { $0 > box.midY }.min() ?? box.maxY) - box.maxY }.min() ?? 0
        return (max(left - margin, 0), max(right - margin, 0), max(up - margin, 0), max(down - margin, 0))
    }
}

/// [moods] A Shapes head's body as something solid (owner, 2026-10-28, of the blobs on springs: "I still like how grok
/// bot does it more"): its outline puffed out front and back like a cushion, so as it turns or tips its side comes round
/// and its face slides over its front, where a flat cut-out only tilts and thins. Facing ahead it is its outline. Points
/// as the outline's (a view's); turns and tips in degrees, as FaceBody's (tip + face down, turn + face right).
nonisolated struct FaceSolid: Sendable {
    typealias Point3 = (x: Double, y: Double, z: Double)

    /// What it turns about; how far its front stands out from its edge (and its back behind it).
    let middle: CGPoint, depth: Double
    /// How far its edge is from its middle facing ahead, at each of `bins` angles round it (from +x, clockwise on screen).
    private(set) var rest: [Double]
    /// Its outline at a run of heights from back to front (about its middle), each smaller the nearer the front or back.
    private let rings: [[Point3]]
    /// Its view's size: a point nearer you shows bigger, as the stage's perspective had it.
    private let side: Double

    static let bins = 72
    /// Which way each bin looks from the middle.
    private static let rays = (0..<bins).map { b -> (x: Double, y: Double) in
        let a = 2 * Double.pi * Double(b) / Double(bins)
        return (cos(a), sin(a))
    }
    /// How round its front and back are (1 a lens; less, fuller toward its edge, like a cushion).
    private static let fullness = 0.72

    init(outline: [CGPoint], side: Double) {
        let count = Double(max(outline.count, 1))
        let middle = CGPoint(x: outline.map(\.x).reduce(0, +) / count, y: outline.map(\.y).reduce(0, +) / count)
        let dense = outline.count > 2 ? HeadGeometry.spline(outline).dense : outline
        let edge = stride(from: 0, to: dense.count, by: max(1, dense.count / 72)).map { (x: dense[$0].x - middle.x, y: dense[$0].y - middle.y) }
        let radius = edge.map { hypot($0.x, $0.y) }.reduce(0, +) / Double(max(edge.count, 1))
        let depth = 0.6 * radius
        self.middle = middle
        self.depth = depth
        self.side = max(side, 1)
        // 24 smooth rings (finer than 15) eliminate silhouette stepping/facets as the cushion turns slowly.
        rings = (0...24).map { k in
            let a = -Double.pi / 2 + Double.pi * Double(k) / 24, scale = pow(max(cos(a), 0), Self.fullness), z = depth * sin(a)
            return edge.map { (x: $0.x * scale, y: $0.y * scale, z: z) }
        }
        rest = []
        // Facing straight ahead (turn = 0, tip = 0), every ring `k` projects to a scalar multiple `m_k` of `edge`, so
        // the exact silhouette equals the single ring with maximal `m_k` (49× faster on init, bit-identical).
        let maxM = (0...24).map { k -> Double in
            let a = -Double.pi / 2 + Double.pi * Double(k) / 24
            let sc = pow(max(cos(a), 0), Self.fullness), z = depth * sin(a)
            return sc / max(0.2, 1 - z / (self.side * 2.5))
        }.max() ?? 1
        let bins = Self.bins, step = 2 * Double.pi / Double(bins)
        let flat = edge.map { (x: $0.x * maxM, y: $0.y * maxM, a: atan2($0.y, $0.x)) }
        var restReach = [Double](repeating: 0, count: bins)
        for i in flat.indices {
            let a = flat[i], b = flat[(i + 1) % flat.count]
            var span = b.a - a.a
            if span > Double.pi { span -= 2 * Double.pi } else if span < -Double.pi { span += 2 * Double.pi }
            let from = span >= 0 ? a : b, to = span >= 0 ? b : a
            let first = Int((from.a / step).rounded(.up)), last = Int(((from.a + abs(span)) / step).rounded(.down))
            guard first <= last else { continue }
            let across = from.x * to.y - from.y * to.x, dx = to.x - from.x, dy = to.y - from.y
            for n in first...last {
                let bin = ((n % bins) + bins) % bins, ray = Self.rays[bin], facing = ray.x * dy - ray.y * dx
                guard abs(facing) > 1e-9 else { continue }
                let r = across / facing
                if r > restReach[bin] { restReach[bin] = r }
            }
        }
        for b in 0..<bins where restReach[b] <= 0 {
            restReach[b] = max(restReach[(b + bins - 1) % bins], restReach[(b + 1) % bins])
        }
        rest = restReach
    }

    /// `p` (about the middle) turned and tipped, before perspective.
    private static func turned(_ p: Point3, _ c: (tip: Double, tipS: Double, turn: Double, turnS: Double)) -> Point3 {
        let y = p.y * c.tip + p.z * c.tipS, z = -p.y * c.tipS + p.z * c.tip
        return (p.x * c.turn + z * c.turnS, y, -p.x * c.turnS + z * c.turn)
    }

    private static func turning(_ turn: Double, _ tip: Double) -> (tip: Double, tipS: Double, turn: Double, turnS: Double) {
        let degree = Double.pi / 180
        return (cos(tip * degree), sin(tip * degree), cos(turn * degree), sin(turn * degree))
    }

    /// Where `p` shows, about the middle on screen.
    private func shown(_ p: Point3) -> (x: Double, y: Double) {
        let near = 1 / max(0.2, 1 - p.z / (side * 2.5))
        return (p.x * near, p.y * near)
    }

    /// How far its edge shows from its middle at each of `bins` angles, turned and tipped: the farthest any part of it
    /// reaches that way (its rings and the lines down its side between them).
    func reach(turn: Double, tip: Double) -> [Double] {
        if abs(turn) < 0.01, abs(tip) < 0.01, rest.count == Self.bins { return rest }
        let c = Self.turning(turn, tip), bins = Self.bins, step = 2 * Double.pi / Double(bins)
        let flat = rings.map { ring in ring.map { p -> (x: Double, y: Double, a: Double) in
            let s = shown(Self.turned(p, c))
            return (s.x, s.y, atan2(s.y, s.x))
        } }
        var reach = [Double](repeating: 0, count: bins)
        func mark(_ a: (x: Double, y: Double, a: Double), _ b: (x: Double, y: Double, a: Double)) {
            var span = b.a - a.a
            if span > Double.pi { span -= 2 * Double.pi } else if span < -Double.pi { span += 2 * Double.pi }
            let from = span >= 0 ? a : b, to = span >= 0 ? b : a
            let first = Int((from.a / step).rounded(.up)), last = Int(((from.a + abs(span)) / step).rounded(.down))
            guard first <= last else { return }
            let across = from.x * to.y - from.y * to.x, dx = to.x - from.x, dy = to.y - from.y
            for n in first...last {
                let bin = ((n % bins) + bins) % bins, ray = Self.rays[bin], facing = ray.x * dy - ray.y * dx
                guard abs(facing) > 1e-9 else { continue }
                let r = across / facing
                if r > reach[bin] { reach[bin] = r }
            }
        }
        for (k, ring) in flat.enumerated() {
            for i in ring.indices {
                mark(ring[i], ring[(i + 1) % ring.count])
                if k + 1 < flat.count { mark(ring[i], flat[k + 1][i]) }
            }
        }
        // A ray that met nothing (never, round its middle) takes its neighbours'.
        for b in 0..<bins where reach[b] <= 0 { reach[b] = max(reach[(b + bins - 1) % bins], reach[(b + 1) % bins]) }
        return reach
    }

    /// `reach` at each of `poses`: worked out on a fine 2° grid and blended between so turning is ripple-free.
    func reaches(_ poses: [(turn: Double, tip: Double)]) -> [[Double]] {
        let grid = 2.0
        var known: [Int: [Double]] = [:]
        func at(_ i: Int, _ j: Int) -> [Double] {
            let key = (i + 1000) * 4000 + j + 1000
            if let known = known[key] { return known }
            let reach = reach(turn: Double(i) * grid, tip: Double(j) * grid)
            known[key] = reach
            return reach
        }
        func around(_ degrees: Double) -> Double {
            let d = (degrees + 180).truncatingRemainder(dividingBy: 360)
            return (d < 0 ? d + 360 : d) - 180
        }
        return poses.map { pose in
            let u = around(pose.turn) / grid, v = around(pose.tip) / grid, i = Int(floor(u)), j = Int(floor(v))
            let fu = u - Double(i), fv = v - Double(j)
            let a = at(i, j), b = at(i + 1, j), c = at(i, j + 1), d = at(i + 1, j + 1)
            return (0..<a.count).map { n in (a[n] * (1 - fu) + b[n] * fu) * (1 - fv) + (c[n] * (1 - fu) + d[n] * fu) * fv }
        }
    }

    /// `reaches`, one a sample of a routine (a loop's last the same moment as its first when `loop`), with the facets of
    /// its few rings taken out: how far each differs from the edge at rest, softened round the edge (about 8°) and over
    /// time (about two samples), so the edge never flickers as first one ring and then another stands furthest out.
    func smoothed(_ reaches: [[Double]], loop: Bool) -> [[Double]] {
        let n = reaches.count, bins = Self.bins
        guard n > 1, reaches.allSatisfy({ $0.count == bins }) else { return reaches }
        func kernel(_ sigma: Double) -> [Double] {
            let half = Int((2.5 * sigma).rounded(.up))
            let w = (-half...half).map { exp(-0.5 * pow(Double($0) / sigma, 2)) }
            let total = w.reduce(0, +)
            return w.map { $0 / total }
        }
        let round = kernel(2.0), along = kernel(2.6), unique = loop ? n - 1 : n
        let alongHalf = along.count / 2
        let rounded = reaches.map { reach in
            (0..<bins).map { b in
                round.enumerated().reduce(0.0) { sum, tap in
                    let i = (b + tap.offset - round.count / 2 + bins) % bins
                    return sum + tap.element * (reach[i] - rest[i])
                }
            }
        }
        var out = (0..<n).map { i -> [Double] in
            if loop {
                return (0..<bins).map { b in
                    rest[b] + along.enumerated().reduce(0.0) { sum, tap in
                        let j = i + tap.offset - alongHalf
                        return sum + tap.element * rounded[((j % unique) + unique) % unique][b]
                    }
                }
            }
            // Symmetric truncated radius at once-only endpoints guarantees bit-exact `rest` at t = 0 and t = period.
            let radius = min(alongHalf, i, n - 1 - i)
            if radius == 0 {
                return (0..<bins).map { b in rest[b] + rounded[i][b] }
            }
            let slice = along[(alongHalf - radius)...(alongHalf + radius)]
            let norm = slice.reduce(0, +)
            return (0..<bins).map { b in
                var sum = 0.0
                for offset in -radius...radius {
                    sum += along[alongHalf + offset] * rounded[i + offset][b]
                }
                return rest[b] + sum / norm
            }
        }
        if loop, let first = out.first { out[n - 1] = first }
        return out
    }

    /// The edge as points round it (this view's), `reach` out at each bin.
    func edge(_ reach: [Double]) -> [CGPoint] {
        let step = 2 * Double.pi / Double(reach.count)
        return reach.enumerated().map { b, r in
            let a = Double(b) * step
            return CGPoint(x: middle.x + r * cos(a), y: middle.y + r * sin(a))
        }
    }

    /// Linearly interpolated polar reach at `t` from a uniformly spaced `reaches` array over `0...period`.
    static func interpolatedReach(in reaches: [[Double]], at t: Double, period: Double, once: Bool) -> [Double] {
        guard !reaches.isEmpty else { return [] }
        guard reaches.count > 1, period > 0 else { return reaches[0] }
        var u = once ? min(max(t, 0), period) : t.truncatingRemainder(dividingBy: period)
        if u < 0 { u += period }
        let steps = reaches.count - 1
        let f = u / period * Double(steps)
        let low = min(max(Int(floor(f)), 0), steps - 1)
        let k = f - Double(low)
        let a = reaches[low], b = reaches[low + 1]
        return zip(a, b).map { $0 + ($1 - $0) * k }
    }

    /// Where a face drawn at `point` (facing ahead) goes as the body turns and tips: how far it moves; how wide and
    /// high it shows (1 facing ahead, less as it goes round toward the edge); how far it faces you (1 straight on,
    /// 0 side on, less round the back); and its perspective distance `scale` (> 1 nearer the camera, < 1 farther away).
    func seat(_ point: CGPoint, turn: Double, tip: Double) -> (dx: Double, dy: Double, wide: Double, high: Double, facing: Double, scale: Double) {
        let q = (x: point.x - middle.x, y: point.y - middle.y), bins = Double(rest.count)
        var at = atan2(q.y, q.x) / (2 * Double.pi) * bins
        if at < 0 { at += bins }
        let low = Int(at) % rest.count, k = at - Double(Int(at))
        let r = max(rest[low] * (1 - k) + rest[(low + 1) % rest.count] * k, 1e-6)
        let share = min(hypot(q.x, q.y) / r, 0.95)
        let p: Point3 = (q.x, q.y, depth * sqrt(max(0, 1 - pow(share, 2 / Self.fullness))))
        let c = Self.turning(turn, tip), rot = Self.turned(p, c), now = shown(rot), then = shown(p)
        let restNear = 1 / max(0.2, 1 - p.z / (side * 2.5))
        let nowNear = 1 / max(0.2, 1 - rot.z / (side * 2.5))
        let depthScale = min(max(nowNear / restNear, 0.78), 1.18)
        // Facing ahead, its surface there leans out by its normal: across and down along it, and straight out of it.
        var n: Point3 = (q.x / (r * r), q.y / (r * r), p.z / max(depth * depth, 1e-9))
        let length = max(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 1e-12)
        n = (n.x / length, n.y / length, n.z / length)
        let across = Self.turned((1, 0, -n.x / n.z), c), down = Self.turned((0, 1, -n.y / n.z), c)
        return (now.x - then.x, now.y - then.y, abs(across.x), abs(down.y), Self.turned(n, c).z, depthScale)
    }
}
