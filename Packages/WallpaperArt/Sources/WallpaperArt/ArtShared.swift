// What the painters share with the first ten pictures (copied from App/Theme/BackdropPresets.swift, so this package stands alone).

import CoreGraphics
import Foundation

nonisolated enum BackdropPreset {
    /// An sRGB colour, 0–1 per channel.
    nonisolated struct Ink: Sendable, Hashable {
        var r: Double
        var g: Double
        var b: Double
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }
}

nonisolated extension BackdropPreset.Ink {
    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    func cg(alpha: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }

    /// Linear interpolation toward `other`, `t` 0…1.
    func mixed(with other: Self, _ t: Double) -> Self {
        let t = min(1, max(0, t))
        return Self(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// The same colour, hue-rotated by `degrees` in HSB space (`glow`'s partner tone beside the person's accent).
    func hueShifted(by degrees: Double) -> Self {
        let maxV = max(r, g, b), minV = min(r, g, b), delta = maxV - minV
        var hue = 0.0
        if delta > 0.0001 {
            if maxV == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        let sat = maxV <= 0 ? 0 : delta / maxV
        var newHue = (hue + degrees).truncatingRemainder(dividingBy: 360)
        if newHue < 0 { newHue += 360 }
        return Self.fromHSB(h: newHue, s: sat, v: maxV)
    }

    private static func fromHSB(h: Double, s: Double, v: Double) -> Self {
        guard s > 0.0001 else { return Self(r: v, g: v, b: v) }
        let c = v * s, hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hp) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = v - c
        return Self(r: r1 + m, g: g1 + m, b: b1 + m)
    }
}

nonisolated enum BackdropCanvas {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An opaque 8-bit sRGB context, `(0, 0)` at the top-left and y growing downward (ordinary screen sense), so
    /// every preset below can be written without thinking about Core Graphics' own bottom-up convention.
    static func context(width: Int, height: Int) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        return ctx
    }

    /// Draws `image` (itself made by another flipped `context(width:height:)`) into `rect`, right way up. Plain
    /// `ctx.draw(image, in:)` would flip it a second time — CGImage drawing always orients to the context's own
    /// notion of "up", so two flipped contexts in a row cancel out only by chance (`contours`' ground tint).
    static func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// A little seeded noise, stippled onto the finished picture's own bytes so big smooth gradients don't band on
    /// an 8-bit screen. Monochrome (one delta per pixel, not per channel) so it reads as grain, not colour speckle.
    /// Cheap: an xorshift128+ step and three byte adds per pixel, no allocation, no Core Graphics calls.
    static func grain(_ ctx: CGContext, width: Int, height: Int, seed: UInt64, amount: Int32 = 5) {
        guard let data = ctx.data else { return }
        let bytesPerRow = ctx.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        var s0 = seed | 1
        var s1 = (seed &* 0x2545F4914F6CDD1D) | 1
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                s1 ^= s1 << 23
                s1 ^= s1 >> 17
                s1 ^= s0
                s1 ^= s0 >> 26
                let t = s0; s0 = s1; s1 = t
                let delta = Int32((s0 >> 58) & 0xF) - 8 // -8...7
                let d = (delta * amount) / 8
                guard d != 0 else { continue }
                let i = row + x * 4
                for c in 0..<3 {
                    let v = Int32(pixels[i + c]) + d
                    pixels[i + c] = UInt8(min(255, max(0, v)))
                }
            }
        }
    }
}

/// A tiny seeded generator standing in for `random()`: xorshift128+, deterministic from its seed, never the system
/// RNG (spec: the same inputs must always draw the same picture).
nonisolated struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// 0…1.
    mutating func next() -> Double { Double(nextUInt64() >> 11) * (1.0 / 9007199254740992.0) }

    /// `lower`…`upper`.
    mutating func next(_ lower: Double, _ upper: Double) -> Double { lower + next() * (upper - lower) }
}

/// A smooth, deterministic stand-in for Perlin/value noise: a handful of sine waves at seeded angles, frequencies
/// and phases, summed and normalised to roughly -1…1. Used wherever a preset wants an organic wobble (a ribbon's
/// curve, a dune ridge, `contours`' field) without a real noise-texture implementation.
