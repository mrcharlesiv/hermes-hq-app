// [thinking-drive] Lightspeed's timeline: what the sky, the bar and the haptics do at each moment, and nothing about how
// they draw it. Owner 2026-11-05: "I want to make the lightspeed thinking bar much more epic."
//
// Climb: the sky darkens and the stars pick up speed. Breath: on the way to the top level the stars crowd ahead and go
// slow and the knocks go quiet. Hit: at the top level's halfway point, one flash, one front, the double hit. Cruise: held
// there the shaking stops, the hum swells and falls, and now and then a near star passes with a thump. Drop: letting go
// up there is a thud, the tails snap back into their stars and the page opens out from the middle.
//
// The page may flash at most once in 1.5 s, and never from a beat (beats reach 28 a second and don't come through here).

import CoreGraphics

/// One frame of the timeline.
nonisolated struct LightspeedState: Equatable {
    /// 0 … 1: the last stretch before the hit (Breath).
    var charge: CGFloat = 0
    /// 0 … 1: past the hit.
    var warp: CGFloat = 0
    /// 0 … 1: settled into the cruise.
    var cruise: CGFloat = 0
    /// The page's flash, 0 … 1.
    var flash: CGFloat = 0
    /// How fast through the stars, as a share of light: it crowds them ahead and colours them. Overshoots below 0 as it drops out.
    var beta: CGFloat = 0
    /// How long the tails are.
    var stretch: CGFloat = 0.01
    /// How far the stars have come; only ever rises, so a change of speed never makes them jump.
    var travel: CGFloat = 0
    /// How dark the page is, 0 … 1.
    var veil: CGFloat = 0.12
    /// How present the sky is, 0 … 1.
    var presence: CGFloat = 0
    /// How far the sky's centre is knocked down by the hit (points).
    var jolt: CGFloat = 0
    /// The hit's front and the drop's opening, as a share of the way to the far corner; negative while there is none.
    var front: CGFloat = -1
    var iris: CGFloat = -1
    /// 0 … 1: how far the sky's centre has gone from the knob to the middle, above the card.
    var centred: CGFloat = 0
    /// A near star passing, 0 … 1, and its direction.
    var pass: CGFloat?
    var passAngle: CGFloat = 0
}

nonisolated struct LightspeedScript {
    struct Events: Equatable {
        /// The top level reached: the double hit and the bar's flash.
        var hit = false
        /// A near star crossing the card's edge.
        var thump = false
    }

    enum Stage: String { case climb, breath, hit, cruise, drop }

    /// Seconds from the hit until the cruise.
    static let hitLength: CGFloat = 0.6
    /// The page may flash again only after this long, and only once the knob has been back under the last level.
    static let flashRest: CGFloat = 1.5

    private(set) var state = LightspeedState()
    private var clock: CGFloat = 0
    private var wasDragging = false
    /// Past the hit, with the finger still up there.
    private var inWarp = false
    /// The knob came from under the halfway point, so the next crossing hits at once (a landing waits for the heat).
    private var crossing = false
    private var lastCrossing: CGFloat = -100
    private var lastFlash: CGFloat = -100
    private var hitFlashes = false
    private var belowLastLevel = true
    private var hitAge: CGFloat?
    private var dropAge: CGFloat?
    private var betaSpeed: CGFloat = 0
    private var centredSpeed: CGFloat = 0
    private var travelRate: CGFloat = 0.02
    private var nextPass: CGFloat = 3
    private var seed: UInt32 = 0x2F6E_2B1

    var stage: Stage {
        if dropAge != nil { return .drop }
        if inWarp { return (hitAge ?? 0) >= Self.hitLength ? .cruise : .hit }
        return state.charge > 0 ? .breath : .climb
    }

    /// Seconds in the hit (and on into the cruise), and seconds in the drop.
    var secondsSinceHit: CGFloat? { hitAge }
    var secondsSinceDrop: CGFloat? { dropAge }

    /// Knocks stop at the hit: the shaking ends as it breaks through.
    var knocksOn: Bool { !inWarp }
    /// The knocks in the last stretch: quieter and sharper, with the hum sinking under them.
    var knockScale: Float { Float(1 + (0.45 - 1) * state.charge) }
    var knockSharpen: Float { Float(0.2 * state.charge) }

    /// What the hum goes to, and how much it listens (nil: it follows the knob).
    var hum: (level: Float, weight: Float)? {
        if inWarp {
            let swell = 0.675 + 0.125 * sin(2 * .pi * clock / 1.6)
            let age = hitAge ?? 0
            let up = min(1, max(0, (age - 0.07) / (Self.hitLength - 0.07)))
            return (Float(0.25 + (swell - 0.25) * up), 1)
        }
        return state.charge > 0 ? (0.25, Float(state.charge)) : nil
    }

    /// Letting go now is a drop, not just a fade.
    var dropsOnLift: Bool { state.warp > 0.5 }

    /// One frame. `pen` is the last level but one, `flip` the point where the knob's level turns to the top one, and
    /// `position`, `heat` and `engaged` are the bar's (ThinkingFrame).
    mutating func step(dt: CGFloat, position: CGFloat, heat: CGFloat, engaged: CGFloat, dragging: Bool, pen: CGFloat, flip: CGFloat) -> Events {
        var events = Events()
        clock += dt
        if let age = hitAge { hitAge = age + dt }
        if let age = dropAge { dropAge = age + dt }

        // The finger.
        if dragging, !wasDragging {
            dropAge = nil
            crossing = position < flip
        } else if !dragging, wasDragging {
            if dropsOnLift { dropAge = 0 }
            inWarp = false
        }
        wasDragging = dragging
        if position < flip { crossing = true }
        if position <= pen { belowLastLevel = true }

        // Across the halfway point, and back.
        if dragging, position >= flip, !inWarp {
            if crossing || heat >= min(0.9, position * 0.9) {
                inWarp = true
                crossing = false
                // A knob jittering on the line is one crossing.
                if clock - lastCrossing >= 0.3 { hit(&events) }
                lastCrossing = clock
            }
        } else if position < flip, inWarp {
            inWarp = false
        }

        advanceWarp(dt: dt, dragging: dragging, position: position, pen: pen, flip: flip)
        advanceCentre(dt: dt)
        advanceSky(dt: dt, heat: heat, engaged: engaged, pen: pen)
        advancePass(dt: dt, into: &events)
        return events
    }

    private mutating func hit(_ events: inout Events) {
        events.hit = true
        hitAge = 0
        hitFlashes = belowLastLevel && clock - lastFlash >= Self.flashRest
        if hitFlashes {
            lastFlash = clock
            belowLastLevel = false
        }
        // The crowd lets go.
        state.beta = 0.6
        betaSpeed = 0
        state.stretch = 1
        travelRate = 1.6
    }

    private mutating func advanceWarp(dt: CGFloat, dragging: Bool, position: CGFloat, pen: CGFloat, flip: CGFloat) {
        // During a drop the warp holds, so the centre and the corona stay where they are as the page opens over them.
        if inWarp {
            state.warp = min(1, state.warp + dt / 0.08)
        } else if dropAge == nil {
            state.warp = max(0, state.warp - dt / 0.3)
        } else if (dropAge ?? 0) >= 0.8 {
            state.warp = 0      // over and out of sight: the next touch starts from nothing
        }
        let span = flip - pen
        state.charge = dragging && !inWarp && span > 0 ? min(1, max(0, (position - pen) / span)) : 0
        let age = hitAge ?? 100
        state.cruise = inWarp ? min(1, max(0, (age - Self.hitLength) / 0.2)) : 0
        state.flash = hitFlashes && age < 0.2 ? exp(-age / 0.045) : 0
        state.front = age >= 0.07 && age < 0.35 ? (age - 0.07) / 0.28 : -1
        let omega: CGFloat = 18
        state.jolt = age < 0.5 ? 6 * (1 + omega * age) * exp(-omega * age) : 0
    }

    /// The centre stays on the knob until the hit, falls to the middle, and heads back the moment the knob comes down.
    /// One spring both ways, so turning back partway keeps its speed and never kinks; a drop finishes the fall.
    private mutating func advanceCentre(dt: CGFloat) {
        if let age = dropAge, age >= 0.8 {
            state.centred = 0   // over and out of sight
            centredSpeed = 0
            return
        }
        let falling = inWarp || dropAge != nil
        let omega: CGFloat = falling ? 6.5 : 9
        centredSpeed += (omega * omega * ((falling ? 1 : 0) - state.centred) - 2 * omega * centredSpeed) * dt
        state.centred = min(1, max(0, state.centred + centredSpeed * dt))
    }

    private mutating func advanceSky(dt: CGFloat, heat: CGFloat, engaged: CGFloat, pen: CGFloat) {
        let charge = state.charge
        // How far up the bar, with the last level at the end of the climb.
        let top = max(0.61, pen)
        func climb(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat) -> CGFloat {
            heat < 0.2 ? a : heat < 0.6 ? a + (b - a) * (heat - 0.2) / 0.4 : b + (c - b) * min(1, (heat - 0.6) / (top - 0.6))
        }

        var betaWant = climb(0, 0.3, 0.75)
        betaWant += (0.97 - betaWant) * charge
        if inWarp { betaWant = 0.8 }
        if dropAge != nil { betaWant = 0 }
        // A spring, so a fast swipe rushes through the crowd rather than stopping for it.
        let omega: CGFloat = 18, zeta: CGFloat = 0.7
        betaSpeed += (omega * omega * (betaWant - state.beta) - 2 * zeta * omega * betaSpeed) * dt
        state.beta = min(0.985, max(-0.2, state.beta + betaSpeed * dt))

        if let age = dropAge {
            state.stretch = max(0, min(state.stretch, 1 - age / 0.12))
        } else if inWarp {
            let t = min(1, (hitAge ?? 0) / Self.hitLength)
            state.stretch = 1 + (0.7 - 1) * t * t * (3 - 2 * t)
        } else {
            let want = climb(0.01, 0.2, 0.55) * (1 + (0.2 - 1) * charge)
            state.stretch += (want - state.stretch) * min(1, dt * 12)
        }

        state.veil = max(climb(0.12, 0.5, 0.88) + (1 - climb(0.12, 0.5, 0.88)) * charge, state.warp)

        var rate: CGFloat
        if let age = dropAge {
            rate = travelRate * exp(-age / 0.26)
        } else if inWarp {
            rate = 0.85 + 0.75 * exp(-(hitAge ?? 0) / 0.25)
            travelRate = rate
        } else {
            rate = (0.02 + 0.55 * pow(max(0, heat), 1.7)) * (1 + (0.25 - 1) * charge)
            travelRate += (rate - travelRate) * min(1, dt * 10)
            rate = travelRate
        }
        state.travel += rate * dt

        if let age = dropAge {
            state.presence = age < 0.8 ? 1 : 0
            let t = (age - 0.12) / 0.58
            state.iris = t < 0 ? -1 : 1.2 * t * t * (3 - 2 * min(1, t))
        } else {
            // Quickly, not at once, when a finger lands back in the middle of a drop.
            state.presence = max(engaged, state.presence - dt / 0.15)
            state.iris = state.iris > dt / 0.15 ? state.iris - dt / 0.15 : -1
        }
    }

    private mutating func advancePass(dt: CGFloat, into events: inout Events) {
        if var p = state.pass {
            let before = p
            p += dt / 0.75
            if before < 0.12, p >= 0.12 { events.thump = true }
            state.pass = p < 1 && dropAge == nil ? p : nil
        } else if state.cruise >= 1 {
            nextPass -= dt
            if nextPass <= 0 {
                state.pass = 0
                state.passAngle = -.pi / 2 + (random() - 0.5) * 2.2     // up the page, either side
                nextPass = 2.5 + 1.5 * random()
            }
        }
    }

    /// 0 … 1, the same every run.
    private mutating func random() -> CGFloat {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return CGFloat(seed >> 8) / CGFloat(1 << 24)
    }
}
