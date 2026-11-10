// [thinking-drive] The thinking bar's drive (App/Chat/Menus/ThinkingDrive.swift): how it feels as it climbs, and the
// choice in Settings. No network, no haptic engine.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Menus · thinking drive")
struct ThinkingDriveTests {
    private let steps = stride(from: 0.0, through: 1.0, by: 0.125).map { $0 }

    /// Owner 2026-11-01: "a haptic feedback that accelerates. It gets more aggressive as you slide it towards the
    /// highest effort". Every step up beats faster, knocks harder and hums louder, and the top is a different animal.
    @Test(arguments: [ThinkingDrive.lightspeed, .afterburner])
    func itAcceleratesAndHitsHarderAsItClimbs(_ drive: ThinkingDrive) throws {
        let feel = try #require(drive.feel)
        let rates = steps.map(feel.beatsPerSecond)
        #expect(zip(rates, rates.dropFirst()).allSatisfy { $0 < $1 }, "faster at every step")
        #expect(rates.last! / rates.first! >= 8, "the top beats many times faster than Off")
        // The same share faster per step: it feels like acceleration, not a dial.
        let shares = zip(rates, rates.dropFirst()).map { $1 / $0 }
        #expect(shares.allSatisfy { abs($0 - shares[0]) < 1e-9 })
        for range in [feel.hum, feel.pulse, feel.pulseSharpness] {
            let strengths = steps.map { Haptics.Rev.Profile.along(range, $0) }
            #expect(zip(strengths, strengths.dropFirst()).allSatisfy { $0 < $1 })
            #expect(strengths.last! <= 1)
        }
    }

    @Test func afterburnerKnocksHarderButDullerThanLightspeed() throws {
        let light = try #require(ThinkingDrive.lightspeed.feel), fire = try #require(ThinkingDrive.afterburner.feel)
        #expect(fire.pulse.upperBound > light.pulse.upperBound)
        #expect(fire.pulseSharpness.upperBound < light.pulseSharpness.upperBound)
        #expect(fire.beatsPerSecond(0) < light.beatsPerSecond(0), "a slower heartbeat at the bottom")
    }

    @MainActor @Test func calmIsTheOldTickWithNoFill() {
        #expect(ThinkingDrive.calm.feel == nil)
        #expect(ThinkingDrive.calm.makeFill() == nil)
        #expect(ThinkingDrive.lightspeed.makeFill() is LightspeedFill)
        #expect(ThinkingDrive.afterburner.makeFill() is AfterburnerFill)
    }

    @Test func lightspeedIsTheDefaultAndTheChoiceIsKept() {
        let before = UserDefaults.standard.object(forKey: ThinkingDrive.key)
        defer { if let before { UserDefaults.standard.set(before, forKey: ThinkingDrive.key) } else { UserDefaults.standard.removeObject(forKey: ThinkingDrive.key) } }
        UserDefaults.standard.removeObject(forKey: ThinkingDrive.key)
        #expect(ThinkingDrive.chosen == .lightspeed)
        ThinkingDrive.chosen = .afterburner
        #expect(ThinkingDrive.chosen == .afterburner)
        UserDefaults.standard.set("warp9", forKey: ThinkingDrive.key)
        #expect(ThinkingDrive.chosen == .lightspeed, "an unknown value reads as the default")
        #expect(ThinkingDrive.allCases.map(\.title) == ["Lightspeed", "Afterburner", "Calm"])
    }

    // MARK: Lightspeed's timeline

    private let pen: CGFloat = 0.8, flip: CGFloat = 0.9, dt: CGFloat = 1.0 / 120

    private func run(_ script: inout LightspeedScript, seconds: CGFloat, position: (CGFloat) -> CGFloat, dragging: Bool = true) -> (hits: Int, flashes: Int) {
        var hits = 0, flashes = 0, clock: CGFloat = 0, last: CGFloat = 0
        while clock < seconds {
            let p = position(clock)
            let e = script.step(dt: dt, position: p, heat: p, engaged: 1, dragging: dragging, pen: pen, flip: flip)
            if e.hit { hits += 1 }
            if script.state.flash > last, script.state.flash > 0.9 { flashes += 1 }
            last = script.state.flash
            clock += dt
        }
        return (hits, flashes)
    }

    /// A finger scrubbing across the line ten times a second must not strobe the page.
    @Test func scrubbingNeverFlashesThePageMoreThanOnceInASpell() {
        var script = LightspeedScript()
        let wiggle = run(&script, seconds: 6) { 0.88 + 0.06 * sin(2 * .pi * 10 * $0) }
        #expect(wiggle.flashes == 1, "still above the last level: one flash")
        var wide = LightspeedScript()
        let big = run(&wide, seconds: 6) { 0.7 + 0.3 * sin(2 * .pi * 10 * $0) }
        #expect(big.flashes <= 5, "at most one in 1.5 s, however far it swings")
    }

    @Test func aFastSwipeHitsAtOnceAndOnce() {
        var script = LightspeedScript()
        _ = script.step(dt: dt, position: 0, heat: 0, engaged: 1, dragging: true, pen: pen, flip: flip)
        let e = script.step(dt: dt, position: 1, heat: 0.1, engaged: 1, dragging: true, pen: pen, flip: flip)
        #expect(e.hit)
        #expect(script.state.flash == 1, "the flash peaks in the hit's own frame")
        #expect(run(&script, seconds: 1) { _ in 1 }.hits == 0)
    }

    @Test func landingAtTheTopHitsOnceTheHeatArrives() {
        var script = LightspeedScript()
        let first = script.step(dt: dt, position: 1, heat: 0.1, engaged: 1, dragging: true, pen: pen, flip: flip)
        #expect(!first.hit)
        #expect(run(&script, seconds: 1) { _ in 1 }.hits == 1)
    }

    @Test func slidingDownClearsTheWarpAndKnocksReturn() {
        var script = LightspeedScript()
        _ = run(&script, seconds: 1) { _ in 1 }
        #expect(script.stage == .cruise)
        #expect(!script.knocksOn)
        _ = run(&script, seconds: 0.5) { _ in 0.5 }
        #expect(script.state.warp == 0)
        #expect(script.knocksOn)
    }

    @Test func aLiftFromTheTopDropsAndALowOneJustFades() {
        var script = LightspeedScript()
        _ = run(&script, seconds: 1) { _ in 1 }
        #expect(script.dropsOnLift)
        _ = run(&script, seconds: 0.4, position: { _ in 1 }, dragging: false)
        #expect(script.stage == .drop)
        #expect(script.state.stretch == 0, "the tails have snapped back")
        #expect(script.state.iris > 0)
        _ = run(&script, seconds: 0.5, position: { _ in 1 }, dragging: false)
        #expect(script.state.presence == 0)

        var low = LightspeedScript()
        _ = run(&low, seconds: 1) { _ in 0.5 }
        #expect(!low.dropsOnLift)
        _ = run(&low, seconds: 0.2, position: { _ in 0.5 }, dragging: false)
        #expect(low.stage == .climb)
    }

    @Test func jitterOnTheLineIsOneHit() {
        var script = LightspeedScript()
        #expect(run(&script, seconds: 6) { 0.88 + 0.06 * sin(2 * .pi * 10 * $0) }.hits == 1)
    }

    /// The flash comes back on a two-level bar too, where the knob can only ever sit on the level below.
    @Test func theFlashRearmsSittingOnTheLevelBelow() {
        var script = LightspeedScript(), flashes = 0, last: CGFloat = 0
        for frame in 0..<(120 * 12) {
            let up = (frame / 240) % 2 == 1
            _ = script.step(dt: dt, position: up ? 1 : 0.8, heat: 1, engaged: 1, dragging: true, pen: pen, flip: flip)
            if script.state.flash > last, script.state.flash > 0.9 { flashes += 1 }
            last = script.state.flash
        }
        #expect(flashes == 3)
    }

    @Test func aTapLongAfterADropIsJustATap() {
        var script = LightspeedScript()
        _ = run(&script, seconds: 1) { _ in 1 }
        _ = run(&script, seconds: 5, position: { _ in 1 }, dragging: false)
        _ = run(&script, seconds: 0.08) { _ in 0.3 }
        #expect(!script.dropsOnLift)
    }

    @Test func landingBackInADropDoesNotSnap() {
        var script = LightspeedScript()
        _ = run(&script, seconds: 1) { _ in 1 }
        _ = run(&script, seconds: 0.5, position: { _ in 1 }, dragging: false)
        let before = script.state
        _ = script.step(dt: dt, position: 1, heat: 1, engaged: 0.4, dragging: true, pen: pen, flip: flip)
        #expect(before.presence - script.state.presence < 0.1)
        #expect(script.state.iris > 0)
    }

    /// Owner 2026-11-05: "right as it moves into the highest tier ... naturally fall into the center", then "as soon as
    /// you pull it down, I want it to follow the slider", "very fluid".
    @Test func theCentreStaysOnTheKnobUntilTheTopTier() {
        var script = LightspeedScript()
        for frame in 0..<(120 * 3) {
            let position = CGFloat(frame) / (120 * 3) * (flip - 0.01)
            _ = script.step(dt: dt, position: position, heat: position, engaged: 1, dragging: true, pen: pen, flip: flip)
            #expect(script.state.centred == 0)
        }
    }

    @Test func theCentreFallsWithoutAJumpAndComesBackAtOnce() {
        var script = LightspeedScript(), last: CGFloat = 0, biggest: CGFloat = 0, lastStep: CGFloat = 0, kink: CGFloat = 0
        func frame(_ position: CGFloat) {
            _ = script.step(dt: dt, position: position, heat: position, engaged: 1, dragging: true, pen: pen, flip: flip)
            let step = script.state.centred - last
            biggest = max(biggest, abs(step))
            kink = max(kink, abs(step - lastStep))
            last = script.state.centred
            lastStep = step
        }
        for _ in 0..<12 { frame(1) }
        #expect(script.state.centred > 0 && script.state.centred < 0.2, "it starts slowly, a fall and not a snap")
        for _ in 0..<(120 * 2) { frame(1) }
        #expect(script.state.centred > 0.99)
        for _ in 0..<12 { frame(0.8) }
        #expect(script.state.centred < 0.95, "it has set off back within 0.1 s")
        for _ in 0..<(120 * 2) { frame(0.8) }
        #expect(script.state.centred < 0.01)
        // Turned back partway, while it's still falling.
        for _ in 0..<36 { frame(1) }
        for _ in 0..<36 { frame(0.8) }
        #expect(biggest < 0.03, "no frame moves it far")
        #expect(kink < 0.008, "no frame changes its speed much")
    }

    @Test func aDropFinishesTheFallThenClears() {
        var script = LightspeedScript()
        _ = run(&script, seconds: 0.3) { _ in 1 }
        let before = script.state.centred
        _ = run(&script, seconds: 0.4, position: { _ in 1 }, dragging: false)
        #expect(script.state.centred > before)
        _ = run(&script, seconds: 0.5, position: { _ in 1 }, dragging: false)
        #expect(script.state.centred == 0)
    }

    @Test func theStarsNeverRunBackward() {
        var script = LightspeedScript()
        var last = script.state.travel
        for frame in 0..<1200 {
            let lift = frame > 900
            _ = script.step(dt: dt, position: min(1, CGFloat(frame) / 500), heat: min(1, CGFloat(frame) / 500), engaged: 1, dragging: !lift, pen: pen, flip: flip)
            #expect(script.state.travel >= last)
            last = script.state.travel
        }
    }

    @Test func aNearStarThumpsWhileCruising() {
        var script = LightspeedScript(), thumps = 0
        for _ in 0..<(120 * 12) {
            if script.step(dt: dt, position: 1, heat: 1, engaged: 1, dragging: true, pen: pen, flip: flip).thump { thumps += 1 }
        }
        #expect(thumps >= 2)
        #expect(thumps <= 5)
    }
}
