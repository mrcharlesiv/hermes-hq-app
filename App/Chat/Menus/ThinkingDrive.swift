// [thinking-drive] The thinking bar's drive. Owner 2026-11-01: "I want for the model selector to have a haptic feedback
// that accelerates. It gets more aggressive as you slide it towards the highest effort. And then I want there to be
// like an animation in the slider, like as it fills … like you're going into hyperspace. So like visually as you're
// sliding it, you feel it getting more aggressive. And then you also, the visual matches it. Feel free to have a lot of
// fun with this".
//
// Each drive is a look and a feel together, picked in Settings › Sounds & Haptics › Thinking Bar:
// - Lightspeed: stars stream through the lit bar into the knob: dots near Off, streaks higher, lines at the top, and each
//   beat runs back down the bar. Behind the card the page goes to black and a sky of stars (LightspeedSky) pours out of
//   the knob, then out from behind the card's top edge. LightspeedScript runs the moments: the breath before the top
//   level, the hit, the cruise while it's held and the drop when it's let go. Felt as a hum rising in strength and pitch
//   under ticks that come faster, quiet in the breath, then the jump's double hit, a swelling hum, and a thud at the end.
// - Afterburner: the knob is an engine and the bar its exhaust. The plume heats from the theme's colour through
//   magenta and orange to white at the nozzle, heat streams back through it, shock diamonds stand behind the nozzle,
//   sparks streak off the knob, and every beat flares the knob and sends a tongue of flame back down the plume. Behind
//   the card the page darkens to a furnace glow that breathes with the beat, and embers rise past the card. Felt as a
//   heartbeat that becomes a drumroll over a low rumble; the top level is overdrive.
// - Calm: the lights as they were, a tick at each level.
// The beat is the bar's: each one is a knock and a light at the same moment. Under Reduce Motion, in Low Power Mode
// and in the Desktop Look the bar draws calmly; the haptics still rev.

import UIKit

enum ThinkingDrive: String, CaseIterable, Identifiable {
    case lightspeed, afterburner, calm

    var id: String { rawValue }

    /// `UserDefaults` key; on this device.
    nonisolated static let key = "hqn.thinkingDrive"

    static var chosen: ThinkingDrive {
        get { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .lightspeed }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .lightspeed: "Lightspeed"
        case .afterburner: "Afterburner"
        case .calm: "Calm"
        }
    }

    /// How it feels (nil: a tick at each level, as before).
    var feel: Haptics.Rev.Profile? {
        switch self {
        case .lightspeed:
            // A hum that climbs from a murmur to a buzz, ticks from 2.5 to 28 a second, crisp.
            Haptics.Rev.Profile(hum: 0.12...0.75, humSharpness: 0.05...0.7, rate: 2.5...28,
                                pulse: 0.25...0.85, pulseSharpness: 0.4...0.95)
        case .afterburner:
            // A low rumble under a heartbeat that becomes a drumroll: heavier knocks, duller, 1.6 to 22 a second.
            Haptics.Rev.Profile(hum: 0.15...0.55, humSharpness: 0...0.3, rate: 1.6...22,
                                pulse: 0.45...1, pulseSharpness: 0.15...0.6)
        case .calm: nil
        }
    }

    @MainActor func makeFill() -> ThinkingFill? {
        switch self {
        case .lightspeed: LightspeedFill()
        case .afterburner: AfterburnerFill()
        case .calm: nil
        }
    }
}

/// One frame of the bar, for its fill and the backdrop behind the card.
struct ThinkingFrame {
    /// Where the knob is, 0 (Off) … 1 (the top level).
    var drive: CGFloat
    /// How hard it runs now, 0 … 1: the knob's place while a finger holds it, winding down after it lets go.
    var heat: CGFloat
    /// How present it is, 0 … 1: up as the finger lands, fading after it lifts.
    var engaged: CGFloat
    var time: CGFloat
    var dt: CGFloat
    /// The bar's start on its centre line, and the knob's centre (the bar's space).
    var start: CGPoint
    var knob: CGPoint
    var lineWidth: CGFloat
    var tint: UIColor
    /// Lightspeed's moment (nil for the other drives).
    var lightspeed: LightspeedState?
}

enum ThinkingBeat { case beat, top }

/// What a drive draws in the bar, above its lit part and under its dots and knob.
@MainActor protocol ThinkingFill: AnyObject {
    var layer: CALayer { get }
    func render(_ f: ThinkingFrame)
    func beat(_ kind: ThinkingBeat, _ f: ThinkingFrame)
    func litColor(_ f: ThinkingFrame) -> UIColor
    func knobColor(_ f: ThinkingFrame) -> UIColor
}

enum DriveInk {
    /// `a` to `b` by `t` (0 … 1).
    static func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        let t = min(1, max(0, t))
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }

    /// Lightspeed's white-blue.
    static let hyper = UIColor(red: 0.80, green: 0.93, blue: 1, alpha: 1)

    /// Afterburner's flame at `t`: the theme's colour, magenta, orange, white-hot.
    static func flame(_ tint: UIColor, _ t: CGFloat) -> UIColor {
        let magenta = UIColor(red: 0.98, green: 0.25, blue: 0.72, alpha: 1)
        let orange = UIColor(red: 1, green: 0.56, blue: 0.16, alpha: 1)
        let white = UIColor(red: 1, green: 0.96, blue: 0.86, alpha: 1)
        switch t {
        case ..<0.45: return mix(tint, magenta, t / 0.45)
        case ..<0.78: return mix(magenta, orange, (t - 0.45) / 0.33)
        default: return mix(orange, white, (t - 0.78) / 0.22)
        }
    }

    /// A spark's streak: a hot head on the left (it flies left), its tail fading to the right.
    static let streak: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 4)).image { ctx in
        let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.55).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.25, 1]) else { return }
        ctx.cgContext.addPath(UIBezierPath(roundedRect: CGRect(x: 0, y: 0.5, width: 18, height: 3), cornerRadius: 1.5).cgPath)
        ctx.cgContext.clip()
        ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 18, y: 0), options: [])
    }.cgImage

    /// A small ember: a hard bright core in a soft edge.
    static let ember: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
        let colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1]) else { return }
        ctx.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 4, y: 4), startRadius: 0,
                                         endCenter: CGPoint(x: 4, y: 4), endRadius: 4, options: [])
    }.cgImage

    /// A soft round light, for sparks.
    static let spark: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { ctx in
        let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        ctx.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 6, y: 6), startRadius: 0,
                                         endCenter: CGPoint(x: 6, y: 6), endRadius: 6, options: [])
    }.cgImage
}

/// The lit part's capsule, from the bar's start to the knob.
private func litCapsule(_ f: ThinkingFrame) -> CGPath {
    let r = f.lineWidth / 2
    let rect = CGRect(x: f.start.x - r, y: f.start.y - r, width: max(f.lineWidth, f.knob.x - f.start.x + f.lineWidth), height: f.lineWidth)
    return UIBezierPath(roundedRect: rect, cornerRadius: r).cgPath
}

/// A ring that grows out of the knob and fades: the top level reached.
@MainActor private func shockwave(in layer: CALayer, at center: CGPoint, color: UIColor, radius: CGFloat) {
    let ring = CAShapeLayer()
    ring.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)).cgPath
    ring.position = center
    ring.fillColor = nil
    ring.strokeColor = color.cgColor
    ring.lineWidth = 3
    layer.addSublayer(ring)
    let grow = CABasicAnimation(keyPath: "transform.scale")   // motion-ok: only on a beat, which ThinkingBar.emitBeat sends only while drawsDrive (never under Reduce Motion)
    grow.fromValue = 1
    grow.toValue = 7
    let fade = CABasicAnimation(keyPath: "opacity")   // motion-ok: as above
    fade.fromValue = 0.95
    fade.toValue = 0
    let thin = CABasicAnimation(keyPath: "lineWidth")   // motion-ok: as above
    thin.fromValue = 4
    thin.toValue = 0.5
    let group = CAAnimationGroup()
    group.animations = [grow, fade, thin]
    group.duration = 0.6
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ring.opacity = 0
    CATransaction.begin()
    CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
    ring.add(group, forKey: "wave")
    CATransaction.commit()
}

/// A bright capsule over the lit part that fades: the moment of the jump.
@MainActor private func flashBar(_ layer: CAShapeLayer, _ f: ThinkingFrame, color: UIColor, strength: CGFloat = 0.95, seconds: CFTimeInterval = 0.45) {
    layer.path = litCapsule(f)
    layer.fillColor = color.cgColor
    let fade = CABasicAnimation(keyPath: "opacity")   // motion-ok: only on a beat, guarded by drawsDrive in ThinkingBar.emitBeat
    fade.fromValue = strength
    fade.toValue = 0
    fade.duration = seconds
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.opacity = 0
    layer.add(fade, forKey: "flash")
}

// MARK: - Lightspeed

/// Stars streaming through the lit part into the knob: dots near Off, streaks as it climbs, lines at the top.
final class LightspeedFill: ThinkingFill {
    let layer = CALayer()
    private let streaks = CALayer()
    private let mask = CAShapeLayer()
    /// Far, middle and near stars: thinner and dimmer to brighter and thicker.
    private let depths = (0..<3).map { _ in CAShapeLayer() }
    private let flash = CAShapeLayer()
    /// Each beat, running back from the knob.
    private let pulses = CAShapeLayer()
    private var pulseTrail: [CGFloat] = []
    private struct Star { var x: CGFloat; var lane: CGFloat; var pace: CGFloat; var depth: Int }
    private var stars: [Star]

    init() {
        stars = (0..<44).map { i in Star(x: .random(in: 0...420), lane: .random(in: -0.34...0.34), pace: .random(in: 0.55...1.45), depth: i % 3) }
        layer.actions = ["opacity": NSNull()]
        streaks.mask = mask
        layer.addSublayer(streaks)
        for (i, depth) in depths.enumerated() {
            depth.fillColor = nil
            depth.lineCap = .round
            depth.lineWidth = [1.2, 1.8, 2.6][i]
            depth.strokeColor = UIColor.white.withAlphaComponent([0.3, 0.5, 0.8][i]).cgColor
            depth.actions = ["path": NSNull()]
            streaks.addSublayer(depth)
        }
        pulses.fillColor = nil
        pulses.lineCap = .round
        pulses.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        pulses.actions = ["path": NSNull(), "lineWidth": NSNull()]
        streaks.addSublayer(pulses)
        mask.actions = ["path": NSNull()]
        flash.opacity = 0
        layer.addSublayer(flash)
    }

    func render(_ f: ThinkingFrame) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.opacity = Float(f.engaged)
        guard f.engaged > 0.01 else { return }
        mask.path = litCapsule(f)
        let h = f.heat
        // The breath: the streaks go slow and short just before the hit.
        let breath = f.lightspeed?.charge ?? 0
        let speed = (50 + 1250 * pow(h, 1.5)) * (1 - 0.75 * breath)
        let length = (1 + 150 * pow(h, 2.2)) * (1 - 0.8 * breath)
        let span = max(1, f.knob.x - f.start.x + f.lineWidth)
        let left = f.start.x - f.lineWidth / 2
        let paths = depths.map { _ in CGMutablePath() }
        for i in stars.indices {
            stars[i].x += speed * stars[i].pace * f.dt
            let long = length * stars[i].pace
            if stars[i].x - long > span {
                // Back to the start, keeping the spacing.
                stars[i].x -= span + long + .random(in: 0...50)
                stars[i].lane = .random(in: -0.34...0.34)
            }
            let y = f.start.y + stars[i].lane * f.lineWidth
            paths[stars[i].depth].move(to: CGPoint(x: left + stars[i].x - long, y: y))
            paths[stars[i].depth].addLine(to: CGPoint(x: left + stars[i].x, y: y))
        }
        for (i, depth) in depths.enumerated() { depth.path = paths[i] }
        pulseTrail = pulseTrail.map { $0 + 900 * f.dt }.filter { $0 < span + 20 }
        let beats = CGMutablePath()
        for back in pulseTrail {
            beats.move(to: CGPoint(x: f.knob.x - back - 10, y: f.start.y))
            beats.addLine(to: CGPoint(x: f.knob.x - back, y: f.start.y))
        }
        pulses.path = beats
        pulses.lineWidth = f.lineWidth * 0.2
    }

    func beat(_ kind: ThinkingBeat, _ f: ThinkingFrame) {
        switch kind {
        case .beat: pulseTrail.append(f.lineWidth * 0.5)
        case .top: flashBar(flash, f, color: DriveInk.hyper, strength: 0.7, seconds: 0.2)
        }
    }

    /// Stays the theme's colour to the top, so the level reads against the night.
    func litColor(_ f: ThinkingFrame) -> UIColor { DriveInk.mix(f.tint, DriveInk.hyper, pow(f.heat, 1.6) * f.engaged * 0.45) }
    func knobColor(_ f: ThinkingFrame) -> UIColor {
        let s = f.lightspeed
        return DriveInk.mix(f.tint, DriveInk.hyper, pow(f.heat, 2) * f.engaged * (0.6 + 0.2 * max(s?.charge ?? 0, s?.warp ?? 0)))
    }
}

// MARK: - Afterburner

/// The knob an engine, the bar its exhaust: a plume that runs hot toward the knob, heat streaming back through it, shock
/// diamonds standing behind the nozzle, sparks streaking off the knob, and a tongue of flame back down the plume on
/// every beat.
final class AfterburnerFill: ThinkingFill {
    let layer = CALayer()
    private let plume = CALayer()
    private let mask = CAShapeLayer()
    private let heatLayer = CAGradientLayer()
    /// Heat streaming back from the knob: far from it dimmer, near it brighter.
    private let flow = (0..<2).map { _ in CAShapeLayer() }
    private let tongues = CAShapeLayer()
    private let diamonds = CAShapeLayer()
    private let sparks = CAEmitterLayer()
    private let flash = CAShapeLayer()
    private struct Wisp { var back: CGFloat; var lane: CGFloat; var pace: CGFloat; var phase: CGFloat }
    private var wisps: [Wisp]
    /// Each beat's tongue: its distance back from the knob (points).
    private var tongueTrail: [CGFloat] = []
    private var flare: CGFloat = 0
    private var burst: CGFloat = 0

    init() {
        wisps = (0..<28).map { _ in Wisp(back: .random(in: 0...420), lane: .random(in: -0.3...0.3),
                                         pace: .random(in: 0.6...1.4), phase: .random(in: 0...(2 * .pi))) }
        layer.actions = ["opacity": NSNull()]
        plume.mask = mask
        layer.addSublayer(plume)
        heatLayer.startPoint = CGPoint(x: 0, y: 0.5)
        heatLayer.endPoint = CGPoint(x: 1, y: 0.5)
        heatLayer.actions = ["colors": NSNull(), "locations": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
        plume.addSublayer(heatLayer)
        for (i, wisp) in flow.enumerated() {
            wisp.fillColor = nil
            wisp.lineCap = .round
            wisp.lineWidth = [1.4, 2.2][i]
            wisp.actions = ["path": NSNull(), "opacity": NSNull(), "strokeColor": NSNull()]
            plume.addSublayer(wisp)
        }
        tongues.fillColor = nil
        tongues.lineCap = .round
        tongues.actions = ["path": NSNull(), "opacity": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        plume.addSublayer(tongues)
        // Lens-shaped Mach diamonds, white-hot with an orange halo.
        diamonds.fillColor = UIColor(red: 1, green: 0.97, blue: 0.86, alpha: 1).cgColor
        diamonds.shadowColor = UIColor(red: 1, green: 0.55, blue: 0.12, alpha: 1).cgColor
        diamonds.shadowOffset = .zero
        diamonds.shadowRadius = 3
        diamonds.shadowOpacity = 1
        diamonds.actions = ["path": NSNull(), "opacity": NSNull(), "shadowPath": NSNull()]
        plume.addSublayer(diamonds)
        mask.actions = ["path": NSNull()]
        // Two kinds of spark: fast streaks thrown back off the engine, and embers that arc and fall. Both start
        // yellow-white and cool to red as they die.
        let streak = CAEmitterCell()
        streak.name = "streak"
        streak.contents = DriveInk.streak
        streak.birthRate = 1
        streak.lifetime = 0.32
        streak.lifetimeRange = 0.14
        streak.velocity = 380
        streak.velocityRange = 160
        streak.emissionLongitude = .pi
        streak.emissionRange = .pi / 9
        streak.scale = 0.5
        streak.scaleRange = 0.2
        streak.alphaSpeed = -2.4
        streak.color = UIColor(red: 1, green: 0.93, blue: 0.7, alpha: 1).cgColor
        streak.greenSpeed = -1.6
        streak.blueSpeed = -2.2
        let ember = CAEmitterCell()
        ember.name = "ember"
        ember.contents = DriveInk.ember
        ember.birthRate = 0.6
        ember.lifetime = 0.8
        ember.lifetimeRange = 0.35
        ember.velocity = 170
        ember.velocityRange = 110
        ember.emissionLongitude = .pi * 1.12          // back and a little up
        ember.emissionRange = .pi / 3
        ember.yAcceleration = 420                     // they fall
        ember.scale = 0.5
        ember.scaleRange = 0.25
        ember.scaleSpeed = -0.35
        ember.alphaSpeed = -1.1
        ember.color = UIColor(red: 1, green: 0.85, blue: 0.5, alpha: 1).cgColor
        ember.greenSpeed = -0.9
        ember.blueSpeed = -1.2
        sparks.emitterCells = [streak, ember]
        sparks.emitterShape = .point
        sparks.renderMode = .additive
        sparks.birthRate = 0
        sparks.actions = ["emitterPosition": NSNull(), "birthRate": NSNull(), "velocity": NSNull()]
        layer.addSublayer(sparks)
        flash.opacity = 0
        layer.addSublayer(flash)
    }

    func render(_ f: ThinkingFrame) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.opacity = Float(f.engaged)
        flare = max(0, flare - f.dt * 6)
        burst = max(0, burst - f.dt * 4)
        guard f.engaged > 0.01 else { sparks.birthRate = 0; return }
        let h = f.heat
        mask.path = litCapsule(f)
        let r = f.lineWidth / 2
        let span = max(f.lineWidth, f.knob.x - f.start.x + f.lineWidth)
        let left = f.start.x - r

        // The plume: cool at the far end, through the flame to white at the nozzle; the hot part reaches further
        // back as it climbs, and every beat pushes it out a little.
        heatLayer.frame = CGRect(x: left, y: f.start.y - r, width: span, height: f.lineWidth)
        let push = min(1, h + flare * 0.12)
        heatLayer.colors = [DriveInk.mix(f.tint, DriveInk.flame(f.tint, 0.4), h).withAlphaComponent(0.85).cgColor,
                            DriveInk.flame(f.tint, push * 0.62).cgColor,
                            DriveInk.flame(f.tint, push * 0.86).cgColor,
                            DriveInk.flame(f.tint, push).cgColor]
        let hot = 0.12 + 0.5 * pow(h, 1.2) + 0.08 * flare
        heatLayer.locations = [0, NSNumber(value: Double(max(0.05, 1 - hot * 1.6))), NSNumber(value: Double(1 - hot * 0.55)), 1]
        heatLayer.opacity = Float(min(1, 0.3 + h * 1.3))

        // Heat streaming back out of the nozzle, wavering, faster and longer as it climbs.
        let speed = 70 + 820 * pow(h, 1.3)
        let length = 4 + 46 * pow(h, 1.5)
        let paths = flow.map { _ in CGMutablePath() }
        for i in wisps.indices {
            wisps[i].back += speed * wisps[i].pace * f.dt
            if wisps[i].back - length > span {
                wisps[i].back = .random(in: 0...20)
                wisps[i].lane = .random(in: -0.3...0.3)
            }
            let w = wisps[i]
            let head = f.knob.x - w.back
            let tail = head - length * w.pace
            let wave = sin(f.time * 11 + w.phase + head * 0.06) * f.lineWidth * 0.1 * (0.4 + h)
            let y = f.start.y + w.lane * f.lineWidth + wave
            let near = w.back < span * 0.45 ? 1 : 0
            paths[near].move(to: CGPoint(x: tail, y: y - wave * 0.6))
            paths[near].addQuadCurve(to: CGPoint(x: head, y: y), control: CGPoint(x: (head + tail) / 2, y: y + wave))
        }
        let wispInk = DriveInk.mix(UIColor(red: 1, green: 0.86, blue: 0.55, alpha: 1), .white, h * 0.4).cgColor
        for (i, wisp) in flow.enumerated() {
            wisp.path = paths[i]
            wisp.strokeColor = wispInk
            wisp.opacity = Float((0.2 + 0.34 * h) * [0.55, 1][i])
        }

        // Each beat's tongue of flame, running back down the plume, stretching and fading.
        let tongueSpeed = 320 + 900 * h
        tongueTrail = tongueTrail.map { $0 + tongueSpeed * f.dt }.filter { $0 < span + 40 }
        let tonguePath = CGMutablePath()
        for back in tongueTrail {
            let head = f.knob.x - back
            tonguePath.move(to: CGPoint(x: head - 10 - 50 * min(1, back / 140), y: f.start.y))
            tonguePath.addLine(to: CGPoint(x: head, y: f.start.y))
        }
        tongues.path = tonguePath
        tongues.lineWidth = f.lineWidth * 0.42
        tongues.strokeColor = DriveInk.flame(f.tint, min(1, h + 0.2)).cgColor
        tongues.opacity = Float(0.35 + 0.45 * h)

        // Mach diamonds behind the nozzle: one at Medium, a row of six at the top, spreading as it climbs.
        let count = h < 0.3 ? 0 : 1 + Int((h - 0.3) / 0.7 * 5.99)
        let gap = 15 + 13 * h
        let lens = CGMutablePath()
        for k in 0..<count {
            let x = f.knob.x - f.lineWidth * 1.05 - CGFloat(k) * gap
            guard x - 8 > f.start.x else { break }
            let flicker = 0.88 + 0.12 * sin(f.time * 53 + CGFloat(k) * 2.1)
            let fall = 1 - CGFloat(k) * 0.12
            let w = 6.5 * fall * flicker, ht = f.lineWidth * 0.3 * fall * flicker
            lens.move(to: CGPoint(x: x - w, y: f.start.y))
            lens.addQuadCurve(to: CGPoint(x: x + w, y: f.start.y), control: CGPoint(x: x, y: f.start.y - 2 * ht))
            lens.addQuadCurve(to: CGPoint(x: x - w, y: f.start.y), control: CGPoint(x: x, y: f.start.y + 2 * ht))
        }
        diamonds.path = lens
        diamonds.shadowPath = lens
        diamonds.opacity = Float(min(1, 0.4 + 0.7 * (h - 0.3)))

        // Sparks off the engine, from High up; a shower at the top.
        let sparkHeat = max(0, (h - 0.35) / 0.65)
        sparks.emitterPosition = CGPoint(x: f.knob.x - f.lineWidth * 0.3, y: f.knob.y)
        sparks.birthRate = Float(f.engaged * (pow(sparkHeat, 1.3) * 110 + flare * 18 * sparkHeat + burst * 260))
        sparks.velocity = Float(0.6 + 0.9 * h + 0.6 * burst)
    }

    func beat(_ kind: ThinkingBeat, _ f: ThinkingFrame) {
        flare = 1
        switch kind {
        case .beat:
            tongueTrail.append(f.lineWidth * 0.5)
        case .top:
            burst = 1
            flashBar(flash, f, color: DriveInk.flame(f.tint, 1))
            shockwave(in: layer, at: f.knob, color: DriveInk.flame(f.tint, 0.8), radius: f.lineWidth * 0.8)
        }
    }

    func litColor(_ f: ThinkingFrame) -> UIColor { DriveInk.mix(f.tint, DriveInk.flame(f.tint, f.heat * 0.7), f.engaged) }
    func knobColor(_ f: ThinkingFrame) -> UIColor {
        DriveInk.mix(f.tint, DriveInk.flame(f.tint, min(1, f.heat * 1.05 + flare * 0.25)), f.engaged)
    }
}

// MARK: - Behind the card

/// Behind the card, over the dimmed page: Lightspeed's starfield pouring out of the knob, or Afterburner's furnace
/// glow breathing with each beat and embers rising past the card. Touches pass through to the dim (a tap there closes
/// the panel).
final class ThinkingBackdrop: UIView {
    private let drive: ThinkingDrive
    /// Lightspeed's sky, made when it first draws. Without Metal the older lines draw instead.
    private var sky: LightspeedSky?
    private let veil = CALayer()
    private let depths = (0..<4).map { _ in CAShapeLayer() }
    private let glow = CAGradientLayer()
    private let embers = CAEmitterLayer()
    private let flash = CALayer()
    private struct Star { var x: CGFloat; var y: CGFloat; var z: CGFloat }
    private var stars: [Star] = []
    private var boost: CGFloat = 0
    private var flare: CGFloat = 0

    init(drive: ThinkingDrive) {
        self.drive = drive
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        veil.backgroundColor = UIColor.black.cgColor
        veil.opacity = 0
        layer.addSublayer(veil)
        switch drive {
        case .lightspeed:
            if !HQMotion.decorativeStill { LightspeedSky.prepare() }
            stars = (0..<170).map { _ in Self.newStar(z: .random(in: 0.05...1)) }
            for (i, depth) in depths.enumerated() {
                depth.fillColor = nil
                depth.lineCap = .round
                depth.lineWidth = [0.9, 1.3, 1.8, 2.5][i]
                depth.opacity = [0.35, 0.55, 0.8, 1][i]
                depth.actions = ["path": NSNull(), "strokeColor": NSNull(), "opacity": NSNull()]
                layer.addSublayer(depth)
            }
        case .afterburner:
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.opacity = 0
            glow.actions = ["colors": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
            layer.addSublayer(glow)
            // Embers lifting off the card's edges and drifting up the page, cooling as they go.
            let ember = CAEmitterCell()
            ember.contents = DriveInk.ember
            ember.birthRate = 1
            ember.lifetime = 2.6
            ember.lifetimeRange = 0.9
            ember.velocity = 95
            ember.velocityRange = 55
            ember.emissionLongitude = -.pi / 2
            ember.emissionRange = .pi / 5
            ember.yAcceleration = -40
            ember.xAcceleration = 6
            ember.scale = 0.42
            ember.scaleRange = 0.24
            ember.scaleSpeed = -0.1
            ember.alphaRange = 0.3
            ember.alphaSpeed = -0.38
            ember.color = UIColor(red: 1, green: 0.78, blue: 0.4, alpha: 1).cgColor
            ember.greenSpeed = -0.22
            ember.blueSpeed = -0.2
            embers.emitterCells = [ember]
            embers.emitterShape = .rectangle
            embers.renderMode = .additive
            embers.birthRate = 0
            embers.actions = ["emitterPosition": NSNull(), "emitterSize": NSNull(), "birthRate": NSNull(), "velocity": NSNull()]
            layer.addSublayer(embers)
        case .calm: break
        }
        flash.backgroundColor = drive == .afterburner ? UIColor(red: 1, green: 0.62, blue: 0.25, alpha: 1).cgColor : UIColor.white.cgColor
        flash.opacity = 0
        layer.addSublayer(flash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func newStar(z: CGFloat) -> Star {
        // Not straight ahead: a small hole in the middle, so the knob isn't buried under a dot.
        var x: CGFloat, y: CGFloat
        repeat { x = .random(in: -1...1); y = .random(in: -1...1) } while x * x + y * y < 0.012
        return Star(x: x, y: y, z: z)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        veil.frame = bounds
        flash.frame = bounds
        for depth in depths { depth.frame = bounds }
        sky?.layout(bounds: bounds)
        CATransaction.commit()
    }

    /// `knob` and `card`: the knob's centre and the card's frame in this view's space.
    func render(_ f: ThinkingFrame, knob: CGPoint, card: CGRect, cardRadius: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if drive == .lightspeed, !LightspeedSky.unavailable, let s = f.lightspeed {
            if sky == nil, s.presence >= 0.01 {
                if let made = LightspeedSky() {
                    layer.insertSublayer(made.layer, above: veil)
                    made.layout(bounds: bounds)
                    sky = made
                } else {
                    LightspeedSky.prepare()     // Low Power Mode has ended since the panel opened
                }
            }
            sky?.render(s, knob: knob, card: card, cardRadius: cardRadius, tint: f.tint,
                        dark: traitCollection.userInterfaceStyle == .dark,
                        headroom: window?.windowScene?.screen.currentEDRHeadroom ?? 1)
            return
        }
        boost = max(0, boost - f.dt * 1.4)
        flare = max(0, flare - f.dt * 5)
        let h = f.heat
        // A light page needs more veil to reach the same night.
        let deepen: CGFloat = traitCollection.userInterfaceStyle == .dark ? 1 : 1.22
        switch drive {
        case .lightspeed:
            // Space: the page darkens as you climb, then the stars.
            veil.opacity = Float(f.engaged * (0.1 + 0.62 * pow(h, 1.3)) * deepen)
            guard f.engaged > 0.01 else { for depth in depths { depth.path = nil }; return }
            let reach = max(bounds.width, bounds.height) * 0.22
            let speed = 0.06 + 2.1 * pow(h, 1.7) + 1.6 * boost
            let trail = 0.012 + 0.10 * pow(h, 2) + 0.14 * boost
            let paths = depths.map { _ in CGMutablePath() }
            let room = bounds.insetBy(dx: -40, dy: -40)
            for i in stars.indices {
                stars[i].z -= speed * f.dt
                var star = stars[i]
                let head = CGPoint(x: knob.x + star.x / max(0.02, star.z) * reach, y: knob.y + star.y / max(0.02, star.z) * reach)
                if star.z <= 0.03 || !room.contains(head) {
                    star = Self.newStar(z: .random(in: 0.7...1))
                    stars[i] = star
                    continue
                }
                let tz = star.z + speed * trail
                let tail = CGPoint(x: knob.x + star.x / tz * reach, y: knob.y + star.y / tz * reach)
                let depth = star.z < 0.22 ? 3 : star.z < 0.45 ? 2 : star.z < 0.7 ? 1 : 0
                paths[depth].move(to: tail)
                paths[depth].addLine(to: CGPoint(x: head.x + 0.01, y: head.y))
            }
            let ink = DriveInk.mix(f.tint, DriveInk.hyper, min(1, 0.3 + h)).cgColor
            let presence = Float(f.engaged * min(1, 0.3 + h * 1.4))
            for (i, depth) in depths.enumerated() {
                depth.path = paths[i]
                depth.strokeColor = ink
                depth.opacity = presence * [0.35, 0.55, 0.8, 1][i]
            }
        case .afterburner:
            // A furnace: the page darkens so the glow has something to burn against; the glow stays a saturated
            // orange to red (white-hot is the bar's alone), so the card takes on its colour rather than going grey.
            veil.opacity = Float(f.engaged * (0.08 + 0.55 * pow(h, 1.3)) * deepen)
            guard f.engaged > 0.01 else { glow.opacity = 0; embers.birthRate = 0; return }
            let radius = 120 + 300 * h + 60 * flare
            glow.frame = CGRect(x: knob.x - radius, y: knob.y - radius, width: 2 * radius, height: 2 * radius)
            let core = DriveInk.flame(f.tint, min(0.8, 0.25 + h * 0.6))
            let rim = DriveInk.mix(f.tint, UIColor(red: 0.85, green: 0.16, blue: 0.1, alpha: 1), min(1, h * 1.3))
            glow.colors = [core.withAlphaComponent(0.7).cgColor, rim.withAlphaComponent(0.28).cgColor, rim.withAlphaComponent(0).cgColor]
            glow.locations = [0, 0.42, 1]
            glow.opacity = Float(f.engaged * (0.2 + 0.7 * h) * (0.72 + 0.28 * flare))
            let card = bounds.insetBy(dx: bounds.width * 0.05, dy: 0)
            embers.emitterPosition = CGPoint(x: card.midX, y: knob.y - 40)
            embers.emitterSize = CGSize(width: card.width, height: 160)
            embers.birthRate = Float(f.engaged * (pow(max(0, h - 0.2) / 0.8, 1.6) * 70 + boost * 160))
            embers.velocity = Float(0.7 + 0.8 * h + 1.2 * boost)
        case .calm: break
        }
    }

    func beat(_ kind: ThinkingBeat, _ f: ThinkingFrame) {
        flare = 1
        guard kind == .top else { return }
        // Lightspeed's sky draws its own hit; its lines flash only when the script says the page may.
        if drive == .lightspeed, !LightspeedSky.unavailable || f.lightspeed?.flash == 0 { return }
        boost = 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")   // motion-ok: only on a beat, guarded by drawsDrive in ThinkingBar.emitBeat
        fade.values = [0, drive == .lightspeed ? 0.5 : 0.3, 0]
        fade.keyTimes = [0, 0.18, 1]
        fade.duration = 0.55
        flash.add(fade, forKey: "flash")
    }
}
