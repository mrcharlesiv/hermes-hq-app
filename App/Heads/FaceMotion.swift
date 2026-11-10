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
}

/// Where the eyes look (−1…1 each way, + right and down) and how far shut they are (0 open … 1 shut).
nonisolated struct FaceEyes: Hashable, Sendable {
    var x = 0.0, y = 0.0, lids = 0.0

    static let rest = FaceEyes()
    /// How far a look all the way across (1) or down turns the eyes round a round body, degrees: the same as the body
    /// turning or tipping that far, so a look and a turn add up to where the face is looking.
    static let across = 32.0, down = 24.0

    func mixed(_ other: FaceEyes, _ k: Double) -> FaceEyes {
        FaceEyes(x: x + (other.x - x) * k, y: y + (other.y - y) * k, lids: lids + (other.lids - lids) * k)
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

    /// The lids drop quickly, stay shut a moment and lift again more slowly (0.26 s).
    mutating func blink(_ at: Double) {
        let open = looking
        look(at, 0.07, .drop) { $0.lids = 1 }
        look(at + 0.11, 0.15, to: open)
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
    private static func hop(_ script: inout FaceScript, _ at: Double, height: Double) -> Double {
        let from = script.now
        script.move(at, 0.1) { $0.squash = from.squash + 0.06 }
        script.move(at + 0.1, 0.16, .rise) { $0.y = from.y - height; $0.squash = from.squash - 0.05 }
        script.move(at + 0.26, 0.14, .drop) { $0.y = from.y; $0.squash = from.squash + 0.05 }
        script.move(at + 0.4, 0.22, .spring, to: from)
        return at + 0.4
    }

    /// A nod from `at` (0.5 s): the face dips and comes back up. Marks the dip.
    private static func nod(_ script: inout FaceScript, _ at: Double, depth: Double = 9) {
        let from = script.now
        script.move(at, 0.16) { $0.tip = from.tip + depth; $0.y = from.y + 0.008 }
        script.move(at + 0.16, 0.34, .spring, to: from)
        script.mark(at + 0.16)
    }

    private static func thinking(_ f: Double) -> [FaceClip] {
        // Chin up, turned a little to one side, eyes up there: turning something over.
        let body = FaceBody(roll: 3 * f, turn: 10 * f, tip: -6), eyes = FaceEyes(x: 0.6 * f, y: -0.85)
        var over = FaceScript(body, eyes)       // slowly round to the other side, and back
        over.move(1.0, 1.2) { $0.turn = -12 * f; $0.roll = -3 * f; $0.tip = -8 }
        over.look(1.05, 0.3) { $0.x = -0.6 * f }
        over.blink(2.7)
        over.move(3.4, 1.2, to: body)
        over.look(3.5, 0.3, to: eyes)
        var hmm = FaceScript(body, eyes)        // settles, squints at it, then perks up: got it
        hmm.move(0.6, 0.5) { $0.tip = 4; $0.squash = 0.04; $0.turn = 4 * f; $0.roll = 0 }
        hmm.look(0.6, 0.3) { $0.lids = 0.5; $0.y = 0.1; $0.x = 0.2 * f }
        hmm.move(2.0, 0.22, .rise) { $0.tip = -10; $0.squash = -0.06; $0.y = -0.03 }
        hmm.look(2.0, 0.12) { $0.lids = 0; $0.y = -0.5; $0.x = 0 }
        hmm.move(2.22, 0.5, .spring, to: body)
        hmm.look(2.9, 0.25, to: eyes)
        hmm.blink(3.6)
        var about = FaceScript(body, eyes)      // glances about up there
        about.look(0.5, 0.14) { $0.x = -0.5 * f; $0.y = -1 }
        about.move(0.5, 0.5) { $0.turn = -6 * f; $0.roll = 0 }
        about.look(1.3, 0.14) { $0.x = f; $0.y = -0.6 }
        about.move(1.3, 0.5, .spring) { $0.turn = 18 * f; $0.roll = 5 * f }
        about.blink(2.1)
        about.move(2.7, 0.9, to: body)
        about.look(2.7, 0.2, to: eyes)
        return [over.clip(5.2), hmm.clip(4.4), about.clip(4.0)]
    }

    private static func reading() -> [FaceClip] {
        // Head down to the page, eyes narrowed at the start of a line.
        let body = FaceBody(turn: -6, tip: 8, squash: 0.02), eyes = FaceEyes(x: -0.8, y: 0.35, lids: 0.35)
        var lines = FaceScript(body, eyes)      // three lines, the head following each along
        for line in 0..<3 {
            let t = Double(line) * 1.15
            lines.look(t + 0.05, 0.85, .linear) { $0.x = 0.8 }
            lines.move(t + 0.05, 0.85) { $0.turn = 6 }
            lines.look(t + 0.95, 0.14) { $0.x = -0.8; $0.y = line < 2 ? 0.35 + 0.15 * Double(line + 1) : 0.35 }
            lines.move(t + 0.95, 0.18) { $0.turn = -6 }
        }
        var close = FaceScript(body, eyes)      // leans in to a hard bit
        close.move(0.2, 0.5) { $0.tip = 14; $0.y = 0.015; $0.squash = -0.02 }
        close.look(0.2, 0.3) { $0.lids = 0.55 }
        close.look(0.8, 0.9, .linear) { $0.x = 0.8 }
        close.move(0.8, 0.9) { $0.turn = 6 }
        close.look(1.75, 0.14) { $0.x = -0.8 }
        close.move(1.75, 0.3) { $0.turn = -6 }
        close.blink(2.3)
        close.move(2.7, 0.6, to: body)
        close.look(2.7, 0.3, to: eyes)
        return [lines.clip(3.6), close.clip(3.8)]
    }

    private static func searching(_ f: Double) -> [FaceClip] {
        let body = FaceBody(tip: -3), eyes = FaceEyes(y: -0.2)
        var sides = FaceScript(body, eyes)      // a quick look each way, eyes first
        sides.look(0.2, 0.1) { $0.x = -1 }
        sides.move(0.22, 0.32, .spring) { $0.turn = -24; $0.x = -0.025; $0.roll = -4 }
        sides.look(1.0, 0.1) { $0.x = 1 }
        sides.move(1.02, 0.4, .spring) { $0.turn = 24; $0.x = 0.025; $0.roll = 4 }
        sides.blink(1.75)
        sides.move(2.2, 0.4, to: body)
        sides.look(2.2, 0.12, to: eyes)
        var peer = FaceScript(body, eyes)       // leans in and looks along
        peer.move(0.3, 0.4) { $0.tip = 10; $0.y = 0.02; $0.squash = 0.03 }
        peer.look(0.3, 0.2) { $0.y = 0.3 }
        peer.look(1.2, 0.12) { $0.x = -0.8 * f }
        peer.move(1.2, 0.35) { $0.turn = -10 * f }
        peer.look(1.9, 0.12) { $0.x = 0.8 * f }
        peer.move(1.9, 0.35) { $0.turn = 10 * f }
        peer.move(2.7, 0.5, to: body)
        peer.look(2.7, 0.2, to: eyes)
        var up = FaceScript(body, eyes)         // scans along the top
        up.move(0.25, 0.45) { $0.turn = 14 * f; $0.tip = -14 }
        up.look(0.25, 0.14) { $0.x = 0.7 * f; $0.y = -1 }
        up.move(1.1, 0.6) { $0.turn = -14 * f; $0.tip = -12 }
        up.look(1.15, 0.2) { $0.x = -0.7 * f }
        up.move(2.1, 0.5, to: body)
        up.look(2.1, 0.15, to: eyes)
        return [sides.clip(3.0), peer.clip(3.6), up.clip(3.0)]
    }

    private static func running(_ f: Double) -> [FaceClip] {
        // Head down a little, eyes narrowed on the work.
        let body = FaceBody(tip: 5), eyes = FaceEyes(y: 0.25, lids: 0.3)
        var busy = FaceScript(body, eyes)       // working away to a beat, bobbing to it
        for beat in 0..<4 {
            let t = Double(beat) * 0.6
            busy.move(t, 0.3) { $0.y = 0.012; $0.squash = 0.035 }
            busy.move(t + 0.3, 0.3, to: body)
        }
        busy.blink(1.5)
        var check = FaceScript(body, eyes)      // a look at what came out, then back to it
        check.look(0.4, 0.12) { $0.x = f; $0.lids = 0.1 }
        check.move(0.4, 0.4, .spring) { $0.turn = 18 * f; $0.roll = 3 * f; $0.tip = 2 }
        check.blink(1.1)
        check.look(1.5, 0.12, to: eyes)
        check.move(1.5, 0.4, to: body)
        for t in [2.2, 2.7] {
            check.move(t, 0.25) { $0.y = 0.012; $0.squash = 0.035 }
            check.move(t + 0.25, 0.25, to: body)
        }
        return [busy.clip(2.4), check.clip(3.2)]
    }

    private static func writing(_ f: Double) -> [FaceClip] {
        // Eyes on the start of a line, the head with them: two lines typed, then a look at them in the pause.
        let body = FaceBody(roll: -2, turn: -6, tip: 6), eyes = FaceEyes(x: -0.8, y: 0.3, lids: 0.3)
        func typed(tilt: Double) -> FaceScript {
            var script = FaceScript(body, eyes)
            for line in 0..<2 {
                let t = Double(line) * lineLength
                script.look(t + 0.05, lineLength - 0.15, .linear) { $0.x = 0.8 }
                script.move(t + 0.05, lineLength - 0.15) { $0.turn = 6; $0.roll = tilt }
                guard line == 0 else { continue }
                // Back to the start of the next line.
                script.move(t + lineLength - 0.1, 0.1) { $0.turn = -6; $0.roll = -tilt }
                script.look(t + lineLength - 0.08, 0.08) { $0.x = -0.8; $0.y = 0.55 }
            }
            return script
        }
        let end = 2 * lineLength
        var plain = typed(tilt: 2)
        plain.look(end, 0.16, to: eyes)
        plain.move(end, 0.3, to: body)
        var pleased = typed(tilt: 5 * f)        // head on one side, a nod at the end
        pleased.move(end - 0.05, 0.12) { $0.tip = 12 }
        pleased.look(end, 0.16, to: eyes)
        pleased.move(end + 0.07, 0.3, .spring, to: body)
        let length = end + typingPause
        return [plain.clip(length), pleased.clip(length)]
    }

    private static func browsing() -> [FaceClip] {
        // The eyes on the pointer, the head turning after them.
        func at(_ stop: CGPoint, turn: Double) -> (FaceBody, FaceEyes) {
            let x = (stop.x - 0.5) * 2.6, y = (stop.y - 0.5) * 2.6
            return (FaceBody(roll: x * 3, turn: x * turn, tip: y * 10), FaceEyes(x: x, y: y))
        }
        let last = stops[stops.count - 1]
        var clicks = FaceScript(at(last, turn: 16).0, at(last, turn: 16).1)     // a little peck as it clicks
        var follows = FaceScript(at(last, turn: 16).0, at(last, turn: 16).1)    // the head swinging after the eyes
        for (index, stop) in stops.enumerated() {
            let t = Double(index) * stopLength
            let (body, eyes) = at(stop, turn: 16)
            clicks.look(t, 0.3, to: eyes)
            clicks.move(t, 0.35, to: body)
            clicks.move(t + 0.35, 0.06, .drop) { $0.squash = 0.04 }
            clicks.move(t + 0.41, 0.25, .spring, to: body)
            let (swung, looked) = at(stop, turn: index == stops.count - 1 ? 16 : 24)   // home again at the end
            follows.look(t, 0.25, to: looked)
            follows.move(t + 0.05, 0.45, .spring, to: swung)
            if index == 1 { follows.blink(t + 0.6) }
        }
        return [clicks.clip(Double(stops.count) * stopLength), follows.clip(Double(stops.count) * stopLength)]
    }

    private static func messaging(_ f: Double) -> [FaceClip] {
        // Turned to the side it's sending to.
        let body = FaceBody(x: 0.02 * f, roll: 3 * f, turn: 22 * f), eyes = FaceEyes(x: f)
        var send = FaceScript(body, eyes)       // winds up and sends, twice
        for t in [0.4, 1.6] {
            send.move(t, 0.22) { $0.x = -0.005 * f; $0.squash = -0.04; $0.tip = -5 }
            send.move(t + 0.22, 0.14, .drop) { $0.x = 0.05 * f; $0.squash = 0.045; $0.tip = 6 }
            send.move(t + 0.36, 0.5, .spring, to: body)
            send.mark(t + 0.36)
        }
        send.blink(1.2)
        var back = FaceScript(body, eyes)       // a look back at you, and away again
        back.move(0.7, 0.45, .spring) { $0.turn = 0; $0.x = 0; $0.roll = 0 }
        back.look(0.75, 0.15) { $0.x = 0 }
        back.blink(1.5)
        back.look(1.95, 0.15, to: eyes)
        back.move(2.0, 0.5, to: body)
        return [send.clip(2.8), back.clip(3.0)]
    }

    private static func making(_ f: Double) -> [FaceClip] {
        // Chin up, eyes up at what it's making.
        let body = FaceBody(tip: -4), eyes = FaceEyes(y: -0.5)
        var wiggle = FaceScript(body, eyes)     // a happy wiggle
        wiggle.move(0.3, 0.3) { $0.roll = -8 * f; $0.squash = 0.03 }
        wiggle.look(0.3, 0.14) { $0.x = -0.5 * f }
        wiggle.move(0.6, 0.35) { $0.roll = 8 * f; $0.squash = -0.03 }
        wiggle.look(0.65, 0.14) { $0.x = 0.5 * f }
        wiggle.move(0.95, 0.3) { $0.roll = -5 * f; $0.squash = 0.02 }
        wiggle.move(1.25, 0.4, .spring, to: body)
        wiggle.look(1.3, 0.16, to: eyes)
        var bounce = FaceScript(body, eyes)     // bounces on the spot
        for t in [0.2, 1.2] { hop(&bounce, t, height: 0.07) }
        var admire = FaceScript(body, eyes)     // looks at it from both sides
        admire.move(0.3, 0.5, .spring) { $0.turn = 20 * f; $0.roll = 4 * f }
        admire.look(0.3, 0.16) { $0.x = 0.6 * f }
        admire.move(1.2, 0.6, .spring) { $0.turn = -20 * f; $0.roll = -4 * f }
        admire.look(1.25, 0.16) { $0.x = -0.6 * f }
        admire.move(2.1, 0.5, to: body)
        admire.look(2.1, 0.16, to: eyes)
        return [wiggle.clip(2.2), bounce.clip(2.4), admire.clip(2.8)]
    }

    private static func replying(_ f: Double) -> [FaceClip] {
        // Facing you as it talks.
        var along = FaceScript()                // nods along
        for t in [0.15, 0.75, 1.35] { nod(&along, t) }
        along.blink(2.0)
        var sway = FaceScript()                 // sways, nods once, glances aside
        sway.move(0.1, 0.8) { $0.turn = 10 * f; $0.roll = 4 * f }
        sway.look(0.2, 0.3) { $0.x = 0.4 * f }
        nod(&sway, 1.1)
        sway.look(1.6, 0.14) { $0.x = 0.8 * f }
        sway.move(1.9, 0.8, to: .rest)
        sway.look(2.0, 0.3, to: .rest)
        sway.blink(2.5)
        var bright = FaceScript()               // perks up at something, then nods
        bright.look(0.25, 0.12) { $0.y = -0.6 }
        bright.move(0.25, 0.3, .spring) { $0.squash = -0.05; $0.tip = -6 }
        bright.move(0.9, 0.35, to: .rest)
        bright.look(0.95, 0.2, to: .rest)
        nod(&bright, 1.4)
        return [along.clip(2.4), sway.clip(3.0), bright.clip(2.2)]
    }

    private static func asking(_ f: Double) -> [FaceClip] {
        // Head on one side, looking at you.
        let body = FaceBody(roll: -9 * f, tip: -4), eyes = FaceEyes(y: -0.15)
        var hops = FaceScript(body, eyes)       // two little hops: well?
        hops.blink(0.3)
        for t in [0.8, 1.45] { hops.mark(hop(&hops, t, height: 0.06)) }
        hops.blink(2.2)
        var tilt = FaceScript(body, eyes)       // head over to the other side and back
        tilt.move(0.6, 0.5, .spring) { $0.roll = 9 * f }
        tilt.look(0.6, 0.2) { $0.x = 0.3 * f }
        tilt.blink(1.5)
        tilt.move(2.1, 0.5, .spring, to: body)
        tilt.look(2.1, 0.2, to: eyes)
        return [hops.clip(2.6), tilt.clip(3.2)]
    }

    private static func done(_ f: Double) -> [FaceClip] {
        // Jumps for joy (one way with a cartwheel), eyes up; lands, leans back pleased and blinks twice at you.
        func jump(cartwheel: Bool) -> FaceClip {
            let spin = cartwheel ? 360 * f : 0
            var script = FaceScript()
            script.look(0.05, 0.15) { $0.y = -0.6 }
            script.move(0, 0.16) { $0.squash = 0.09 }
            script.move(0.16, 0.26, .rise) { $0.y = -0.16; $0.squash = -0.08; $0.tip = -8; $0.roll = spin * 0.55 }
            script.move(0.42, 0.24, .drop) { $0.y = 0; $0.squash = 0.09; $0.tip = 0; $0.roll = spin }
            script.move(0.66, 0.3, .spring) { $0.squash = 0 }
            script.move(1.0, 0.35) { $0.tip = -8; $0.roll = spin + 6 * f }
            // Back to rest (a whole turn is rest).
            script.move(1.9, 0.4) { $0.tip = 0; $0.roll = spin }
            script.look(0.8, 0.2) { $0.y = 0 }
            script.blink(1.3)
            script.blink(1.6)
            return script.clip(BotMood.done.length)
        }
        return [jump(cartwheel: false), jump(cartwheel: true)]
    }

    private static func failed(_ f: Double) -> [FaceClip] {
        // A shake with its eyes screwed shut (no!), then it droops, eyes down and half shut.
        var script = FaceScript()
        script.look(0, 0.12) { $0.lids = 0.8 }
        script.move(0.02, 0.16) { $0.x = -0.025 * f; $0.turn = -16 * f; $0.roll = -4 * f }
        script.move(0.18, 0.2) { $0.x = 0.025 * f; $0.turn = 14 * f; $0.roll = 4 * f }
        script.move(0.38, 0.18) { $0.x = -0.012 * f; $0.turn = -7 * f; $0.roll = -2 * f }
        script.move(0.56, 0.16) { $0.x = 0; $0.turn = 0; $0.roll = 0 }
        script.move(0.72, 0.4) { $0.tip = 14; $0.y = 0.03; $0.squash = 0.04 }
        script.look(0.75, 0.3) { $0.y = 0.5; $0.lids = 0.45 }
        script.move(1.45, 0.4, to: .rest)
        script.look(1.55, 0.25, to: .rest)
        return [script.clip(BotMood.failed.length)]
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
        // x, y, roll, turn, tip, squash; where the eyes look across and up, in the world. A whole turn is no jump (a turn
        // is a turn).
        var targets = raw.map { [$0.body.x, $0.body.y, $0.body.roll, $0.body.turn, $0.body.tip, $0.body.squash, $0.eyes.x, $0.eyes.y] }
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
        let wrap = (0..<8).map { targets[targets.count - 1][$0] - targets[0][$0] }
        // How quickly each follows: a hop's moves up and down and its squash quickly (they're short), turns more slowly, the
        // eyes quickest of all.
        let omega = [5.0, 5, 3, 3, 3, 5, 7, 7].map { 2 * Double.pi * $0 }
        var at = targets[0], speed = [Double](repeating: 0, count: 8)
        var out: [[Double]] = []
        let passes = once ? 1 : 3
        for pass in 0..<passes {
            if pass > 0 { for c in [2, 3, 4, 6, 7] { at[c] -= wrap[c] } }
            for i in 0..<(raw.count - 1) {
                if pass == passes - 1 { out.append(at) }
                let span = raw[i + 1].at - raw[i].at, steps = max(1, Int((span * 480).rounded(.up))), dt = span / Double(steps)
                for step in 1...steps {
                    let k = Double(step) / Double(steps)
                    for c in 0..<8 {
                        let target = targets[i][c] + (targets[i + 1][c] - targets[i][c]) * k
                        speed[c] += (omega[c] * omega[c] * (target - at[c]) - 2 * omega[c] * speed[c]) * dt
                        at[c] += speed[c] * dt
                    }
                }
            }
        }
        out.append(at)
        // A breath about every 3.4 s (a whole number a loop, so it joins up): a little taller and up, and back.
        let breaths = once ? 0 : max(1, (period / 3.4).rounded())
        return zip(raw, out).map { sample, c in
            let breath = sin(2 * Double.pi * breaths * sample.at / period)
            return (sample.at, FaceBody(x: c[0], y: c[1] - 0.0025 * breath, roll: c[2], turn: c[3], tip: c[4], squash: c[5] - 0.012 * breath),
                    FaceEyes(x: c[6] - c[3] / FaceEyes.across, y: c[7] - c[4] / FaceEyes.down, lids: sample.eyes.lids))
        }
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
        let degree = Double.pi / 180, omega = 2 * Double.pi * 2.2, damping = 0.62
        // How the body moves between each sample and the next: how much it stretches for its speed up or down, how its
        // squash and nod go, across, and its turns (radians).
        let speeds: [(stretch: Double, down: Double, across: Double, swing: Double)] = (0..<(samples.count - 1)).map { i in
            let a = samples[i], b = samples[i + 1], span = max(b.at - a.at, 1e-6)
            let stretch = -0.07 * abs(b.body.y - a.body.y) / span
            let down = ((b.body.squash - a.body.squash) * 1.5 + (b.body.tip - a.body.tip) * degree * 0.6) / span
            let across = (b.body.x - a.body.x) * 5 / span
            let swing = ((b.body.roll - a.body.roll) * 2.5 + (b.body.turn - a.body.turn) * 1.2) * degree / span
            return (stretch, down, across, swing)
        }
        var squash = (at: 0.0, speed: 0.0), lean = (at: 0.0, speed: 0.0)
        var before = once ? (stretch: 0.0, down: 0.0, across: 0.0, swing: 0.0) : speeds[speeds.count - 1]
        var out: [FaceJelly] = []
        for pass in 0..<(once ? 1 : 3) {
            let last = pass == (once ? 0 : 2)
            for (i, speed) in speeds.enumerated() {
                if last { out.append(FaceJelly(squash: squash.at, lean: lean.at)) }
                // A change in speed pushes the soft body the other way (it carries on as the body stops, lags as it goes).
                squash.speed -= speed.down - before.down
                lean.speed -= speed.across - before.across + speed.swing - before.swing
                before = speed
                let span = samples[i + 1].at - samples[i].at, steps = max(1, Int((span * 240).rounded(.up))), dt = span / Double(steps)
                for _ in 0..<steps {
                    squash.speed += (-omega * omega * (squash.at - speed.stretch) - 2 * damping * omega * squash.speed) * dt
                    squash.at += squash.speed * dt
                    lean.speed += (-omega * omega * lean.at - 2 * damping * omega * lean.speed) * dt
                    lean.at += lean.speed * dt
                }
            }
        }
        out.append(FaceJelly(squash: squash.at, lean: lean.at))
        // Eased to a limit, not cut off at it (a cut-off reads as a jolt); a once-only wobble eased out by its end.
        func limit(_ v: Double, _ most: Double) -> Double { most * tanh(v / most) }
        return zip(samples, out).map { sample, jelly in
            let left = once ? min(max((period - sample.at) / 0.4, 0), 1) : 1, fade = left * left * (3 - 2 * left)
            return FaceJelly(squash: limit(jelly.squash, jelly.squash < 0 ? 0.16 : 0.2) * fade, lean: limit(jelly.lean, 0.14) * fade)
        }
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

    static let bins = 96
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
        rings = (0...14).map { k in
            let a = -Double.pi / 2 + Double.pi * Double(k) / 14, scale = pow(max(cos(a), 0), Self.fullness), z = depth * sin(a)
            return edge.map { (x: $0.x * scale, y: $0.y * scale, z: z) }
        }
        rest = []
        rest = reach(turn: 0, tip: 0)
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

    /// `reach` at each of `poses`: worked out on a 3° grid and blended between, so a routine's hundreds of samples
    /// share a few dozen outlines (each is about a millisecond's work).
    func reaches(_ poses: [(turn: Double, tip: Double)]) -> [[Double]] {
        let grid = 3.0
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
        let round = kernel(2), along = kernel(1.5), unique = loop ? n - 1 : n
        let rounded = reaches.map { reach in
            (0..<bins).map { b in
                round.enumerated().reduce(0.0) { sum, tap in
                    let i = (b + tap.offset - round.count / 2 + bins) % bins
                    return sum + tap.element * (reach[i] - rest[i])
                }
            }
        }
        return (0..<n).map { i in
            (0..<bins).map { b in
                rest[b] + along.enumerated().reduce(0.0) { sum, tap in
                    let j = i + tap.offset - along.count / 2
                    return sum + tap.element * rounded[loop ? ((j % unique) + unique) % unique : min(max(j, 0), n - 1)][b]
                }
            }
        }
    }

    /// The edge as points round it (this view's), `reach` out at each bin.
    func edge(_ reach: [Double]) -> [CGPoint] {
        let step = 2 * Double.pi / Double(reach.count)
        return reach.enumerated().map { b, r in
            let a = Double(b) * step
            return CGPoint(x: middle.x + r * cos(a), y: middle.y + r * sin(a))
        }
    }

    /// Where a face drawn at `point` (facing ahead) goes as the body turns and tips: how far it moves; how wide and
    /// high it shows (1 facing ahead, less as it goes round toward the edge); and how far it faces you (1 straight
    /// on, 0 side on, less round the back).
    func seat(_ point: CGPoint, turn: Double, tip: Double) -> (dx: Double, dy: Double, wide: Double, high: Double, facing: Double) {
        let q = (x: point.x - middle.x, y: point.y - middle.y), bins = Double(rest.count)
        var at = atan2(q.y, q.x) / (2 * Double.pi) * bins
        if at < 0 { at += bins }
        let low = Int(at) % rest.count, k = at - Double(Int(at))
        let r = max(rest[low] * (1 - k) + rest[(low + 1) % rest.count] * k, 1e-6)
        let share = min(hypot(q.x, q.y) / r, 0.95)
        let p: Point3 = (q.x, q.y, depth * sqrt(max(0, 1 - pow(share, 2 / Self.fullness))))
        let c = Self.turning(turn, tip), now = shown(Self.turned(p, c)), then = shown(p)
        // Facing ahead, its surface there leans out by its normal: across and down along it, and straight out of it.
        var n: Point3 = (q.x / (r * r), q.y / (r * r), p.z / max(depth * depth, 1e-9))
        let length = max(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 1e-12)
        n = (n.x / length, n.y / length, n.z / length)
        let across = Self.turned((1, 0, -n.x / n.z), c), down = Self.turned((0, 1, -n.y / n.z), c)
        return (now.x - then.x, now.y - then.y, abs(across.x), abs(down.y), Self.turned(n, c).z)
    }
}
