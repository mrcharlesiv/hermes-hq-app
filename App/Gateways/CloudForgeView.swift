// The new agent's own dot-matrix face (MatrixHead, the same LEDs as its bot's head), built LED by LED while Nous sets it
// up: loose LEDs circle the face and land row by row from the bottom, warming as Nous gets further (a create took 17
// minutes on 2026-10-30, so landing slows over minutes and never finishes early); once the agent answers every LED lights
// from the bottom up and the eyes open; signed in, it hops, blinks, and a burst goes off. Reduce Motion or Low Power: LEDs fade in
// where they belong, nothing moves.

import SwiftUI

struct CloudForge: View {
    enum Stage: Equatable {
        /// Asking Nous to make it: the first LEDs gather.
        case gathering(since: Date)
        /// Nous builds and starts it: LEDs keep landing and warm up.
        case building(since: Date)
        /// It answers: every LED lights, bottom to top, and the eyes open while HQ signs in.
        case waking(since: Date)
        /// Signed in: a hop, a blink, a burst.
        case done(at: Date)
    }

    /// The agent's name: its face is the one a bot of that name gets (`Head.defaultHead`).
    var seed: String
    var stage: Stage
    /// The face's side; the picture is 1.6 times it, for the loose LEDs and the burst.
    var side: CGFloat
    @Environment(\.colorScheme) private var scheme
    @State private var store = ForgeStore()

    static let room: CGFloat = 1.6

    var body: some View {
        let still = HQMotion.decorativeStill
        TimelineView(.animation(minimumInterval: still ? 1 : 1.0 / 30)) { context in
            Canvas { ctx, size in
                store.prepare(seed: seed, dark: scheme == .dark)
                store.draw(&ctx, size: size, side: side, stage: stage, now: context.date, still: still)
            }
        }
        .frame(width: side * Self.room, height: side * Self.room)
        .accessibilityHidden(true)
    }
}

/// The face's LEDs with where each starts, when it lands and its colours, kept across frames.
@MainActor private final class ForgeStore {
    struct LED {
        var col: Int
        var row: Int
        var kind: MatrixDot.Kind
        /// When in the build it lands (0 first … 1 last): bottom rows first, a little shuffled.
        var rank: Double
        /// Where it circles before it lands (radians, share of the face's side, radians a second).
        var angle: Double
        var reach: Double
        var spin: Double
        /// Off … its own lit colour, in `ForgeStore.levels` steps, then a flare.
        var colours: [Color]
        var landed: Date?
    }

    static let levels = 8
    private var key = ""
    private var leds: [LED] = []
    private var glow = Color.clear
    private var spark = Color.clear
    private var hole: Color?
    private var facing = 1

    func prepare(seed: String, dark: Bool) {
        let next = seed.lowercased() + (dark ? "/dark" : "/light")
        guard next != key else { return }
        let sameFace = key.split(separator: "/").first == next.split(separator: "/").first
        key = next
        let design = MatrixDesign(Head.defaultMatrixHead(profile: seed.isEmpty ? "hermes-cloud" : seed))
        let palette = MatrixPalette.make(design, dark: dark)
        facing = design.facing
        glow = Color(cgColor: palette.lit.cgColor())
        spark = Color(cgColor: palette.hot.cgColor())
        hole = palette.hole.map { Color(cgColor: $0.cgColor()) }
        // FNV-1a of the name: the same scatter every launch (Swift's hashValue changes per run).
        var random = SeededRandom(seed: max(seed.lowercased().utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }, 1))
        let old = leds
        var made: [LED] = MatrixHead.dots(design).enumerated().map { index, dot in
            // The head at rest (MatrixHeadRenderer.draw's colours): grey at the back, the bot's colour where light falls.
            let lit = palette.lit.mixed(palette.hot, dot.hot * 0.8)
            let grey = palette.shade.mixed(palette.unlit, MatrixHead.smooth(0, 0.5, dot.light))
            let full = grey.mixed(lit, MatrixHead.smooth(0.1, 1, dot.light))
            let off = palette.unlit.mixed(palette.shade, 0.5)
            var colours = (0...Self.levels).map { Color(cgColor: off.mixed(full, Double($0) / Double(Self.levels)).cgColor()) }
            colours.append(Color(cgColor: full.mixed(palette.hot, 0.7).cgColor()))
            return LED(col: dot.col, row: dot.row, kind: dot.kind, rank: Double(MatrixHead.grid - 1 - dot.row) + random.next() * 3,
                       angle: random.next() * 2 * .pi, reach: 0.5 + 0.3 * random.next(),
                       spin: (0.08 + 0.1 * random.next()) * (random.next() < 0.5 ? -1 : 1), colours: colours,
                       landed: sameFace && index < old.count ? old[index].landed : nil)
        }
        let order = made.indices.sorted { made[$0].rank < made[$1].rank }
        for (place, index) in order.enumerated() { made[index].rank = Double(place) / Double(max(made.count, 1)) }
        leds = made
    }

    /// How much of the face has landed by `now`: asymptotic in each stage, so it keeps moving however long Nous takes.
    private func built(_ stage: CloudForge.Stage, now: Date) -> Double {
        switch stage {
        case .gathering(let since): 0.38 * (1 - exp(-max(0, now.timeIntervalSince(since)) / 50))
        case .building(let since): 0.4 + 0.52 * (1 - exp(-max(0, now.timeIntervalSince(since)) / 240))
        case .waking, .done: 1
        }
    }

    /// How warm a landed LED is (0 off … 1 its own colour).
    private func warmth(_ stage: CloudForge.Stage, led: LED, now: Date) -> Double {
        switch stage {
        case .gathering: return 0.2
        case .building(let since): return 0.28 + 0.4 * (1 - exp(-max(0, now.timeIntervalSince(since)) / 300))
        case .waking(let since):
            // Lights run up the face from the bottom row.
            let at = 0.2 + Double(MatrixHead.grid - 1 - led.row) / Double(MatrixHead.grid) * 0.9
            return 0.68 + 0.32 * min(1, max(0, (now.timeIntervalSince(since) - at) / 0.3))
        case .done: return 1
        }
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, side: CGFloat, stage: CloudForge.Stage, now: Date, still: Bool) {
        let t = now.timeIntervalSinceReferenceDate
        let pitch = side / CGFloat(MatrixHead.grid)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let origin = CGPoint(x: centre.x - side / 2, y: centre.y - side / 2)
        let progress = built(stage, now: now)
        var doneAt: Date?
        if case .done(let at) = stage { doneAt = at }
        let since = doneAt.map { now.timeIntervalSince($0) } ?? -1

        // The light the face gives off, growing as it builds; breathing while Nous works.
        let breathe = still || doneAt != nil ? 1 : 0.85 + 0.15 * sin(t * 2)
        let glowAlpha = (scheme ? 0.3 : 0.16) * (0.25 + 0.75 * progress) * breathe
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - side * 0.8, y: centre.y - side * 0.8, width: side * 1.6, height: side * 1.6)),
                 with: .radialGradient(Gradient(colors: [glow.opacity(glowAlpha), glow.opacity(glowAlpha * 0.4), glow.opacity(0)]),
                                       center: centre, startRadius: 0, endRadius: side * 0.8))

        // Signed in: a little hop.
        if since >= 0, since < 0.5, !still {
            let hop = 1 + 0.07 * sin(.pi * since / 0.5)
            ctx.translateBy(x: centre.x, y: centre.y)
            ctx.scaleBy(x: hop, y: hop)
            ctx.translateBy(x: -centre.x, y: -centre.y)
        }

        // A light sweeps across the face now and then while it builds; once, brightly, when it's done.
        let sweep: Double? = {
            if still { return nil }
            if since >= 0 { return since < 1.2 ? since / 1.2 * 1.6 - 0.3 : nil }
            if case .waking = stage { return nil }
            return (t.truncatingRemainder(dividingBy: 3.4)) / 3.4 * 1.6 - 0.3
        }()
        // Eyes: shut while it's built; open once it answers (it wakes up); one blink when it's done.
        var awake = since >= 0
        if case .waking(let woke) = stage { awake = now.timeIntervalSince(woke) > 1.1 }
        let eyesOpen = awake && !(since > 0.9 && since < 1.05)
        let flight = 0.9

        for index in leds.indices {
            var led = leds[index]
            if led.landed == nil, progress >= led.rank {
                led.landed = now
                leds[index].landed = led.landed
            }
            let home = CGPoint(x: origin.x + (CGFloat(led.col) + 0.5) * pitch, y: origin.y + (CGFloat(led.row) + 0.5) * pitch)
            let radius = pitch * 0.4
            guard let landed = led.landed else {
                if still {
                    // Where it will go, faint.
                    ctx.fill(Path(ellipseIn: CGRect(x: home.x - radius * 0.6, y: home.y - radius * 0.6, width: radius * 1.2, height: radius * 1.2)),
                             with: .color(led.colours[0].opacity(0.35)))
                } else {
                    let loose = loosePoint(led, centre: centre, side: side, t: t)
                    ctx.fill(Path(ellipseIn: CGRect(x: loose.x - radius * 0.55, y: loose.y - radius * 0.55, width: radius * 1.1, height: radius * 1.1)),
                             with: .color(led.colours[1].opacity(0.55)))
                }
                continue
            }
            let age = now.timeIntervalSince(landed)
            var point = home
            var opacity = 1.0
            if still {
                opacity = min(1, age / 0.4)
            } else if age < flight {
                let f = age / flight
                // Ease out with a small overshoot, so each LED settles into its place.
                let c = 1.4
                let eased = 1 + (c + 1) * pow(f - 1, 3) + c * pow(f - 1, 2)
                let from = loosePoint(led, centre: centre, side: side, t: t)
                point = CGPoint(x: from.x + (home.x - from.x) * eased, y: from.y + (home.y - from.y) * eased)
            }
            var level = warmth(stage, led: led, now: now)
            // A flash as it lands.
            if !still, age >= flight, age < flight + 0.35 { level = max(level, 1 - (age - flight) / 0.35 * (1 - level)) }
            var flare = false
            if let sweep {
                let along = Double(led.col + led.row) / Double(2 * MatrixHead.grid - 2)
                let bump = exp(-pow((along - sweep) / 0.07, 2))
                if bump > 0.6 { flare = true } else { level = min(1, level + bump * 0.5) }
            }
            if led.kind == .hole || led.kind == .white || led.kind == .pupil, eyesOpen {
                // An eye: a dark LED (a gap on a dark page).
                if let hole { ctx.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(hole)) }
                continue
            }
            let colour = flare ? led.colours[ForgeStore.levels + 1] : led.colours[Int((level * Double(ForgeStore.levels)).rounded())]
            ctx.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(colour.opacity(opacity)))
        }

        // The burst: two rings of sparks fly out from the face and fade, the outer one faster and farther.
        if since >= 0, since < 1.5, !still {
            for i in 0..<44 {
                let outer = i < 26
                let count = outer ? 26.0 : 18.0
                let slot = Double(outer ? i : i - 26)
                let life = outer ? 1.1 : 1.45
                let f = min(1, since / life)
                guard f < 1 else { continue }
                let eased = 1 - pow(1 - f, 3)
                let angle = slot / count * 2 * .pi + (outer ? 0 : .pi / count) + Double(i % 3) * 0.09
                let reach = side * (0.42 + (outer ? 0.55 + 0.12 * Double(i % 4) / 3 : 0.3 + 0.1 * Double(i % 3) / 2) * eased)
                // A little fall as they slow.
                let p = CGPoint(x: centre.x + cos(angle) * reach, y: centre.y + sin(angle) * reach + side * 0.08 * f * f)
                let r = pitch * (outer ? 0.42 : 0.3) * (1 - f * 0.55)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color((i.isMultiple(of: 3) ? glow : spark).opacity(1 - f * f)))
            }
        }
    }

    private var scheme: Bool { key.hasSuffix("/dark") }

    /// Where a loose LED is at `t`: circling the face, drifting in and out a little.
    private func loosePoint(_ led: LED, centre: CGPoint, side: CGFloat, t: Double) -> CGPoint {
        let angle = led.angle + led.spin * t
        let reach = side * led.reach * (1 + 0.05 * sin(t * 0.9 + led.angle * 3))
        return CGPoint(x: centre.x + cos(angle) * reach, y: centre.y + sin(angle) * reach * 0.92)
    }
}
