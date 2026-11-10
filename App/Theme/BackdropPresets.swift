// [backdrop] The pictures Theme › App Background and Chat Background can preload: no image assets, every pixel
// drawn here instead (the first ten here; Photographic, Illustrated, Painted and Doodles in Packages/WallpaperArt/). Each preset has a Light and a Dark version that follows the system appearance;
// `glow` alone also follows the person's own tint.
//
// - Geometry is relative to the picture's short side (`unit`), so a small list-row tile and a full phone screen are
//   the same picture at different scales.
// - Soft colour fields come from Core Graphics' own linear and radial gradients, drawn straight at full size: that's
//   hardware work, not a Swift loop, so it costs almost nothing regardless of resolution. The one field that truly
//   needs per-pixel colour (`contours`' tinted ground) is drawn on a small canvas and scaled up — Core Graphics'
//   upscale is itself smooth, so a blurry source never needs a separate blur pass.
// - A very light seeded grain is stippled over the finished picture, last, at full resolution, so broad gradients
//   don't band on an 8-bit screen.
// - Pure Core Graphics / Core Image / Foundation: no UIKit or SwiftUI, so this draws identically in the app (always
//   off the main thread) and in a standalone `swiftc` command-line tool.
// - Deterministic: a seeded generator stands in for `random()`, seeded from the preset and the appearance, so the
//   same inputs always draw the same picture.

import CoreGraphics
import CoreImage
import Foundation
import WallpaperArt

/// The pictures that come with the app (Theme › App Background and Chat Background), drawn in code.
nonisolated enum BackdropPreset: String, CaseIterable, Sendable {
    case aurora, sunset, ocean, meadow, blossom, dunes, nebula, paper, contours, glow
    // Owner 2026-11-05, on four new styles side by side: "I love them all". Each has its own folder in Packages/WallpaperArt/.
    case photoLake, photoOcean, photoClouds, photoDunes, photoCanyon, photoForest, photoAurora, photoAlpenglow
    case posterLake, posterOcean, posterClouds, posterMesa, northernLights, snowyVillage, cityDusk, rollingHills
    case paintLake, paintOcean, paintClouds, paintHills, paintForest, paintDesert, paintPeaks, paintHarbor
    // Doodles, each its own set of drawings: four on the masculine side, two on the feminine side, two neutral (owner
    // 2026-11-03: "Forest. mountains. controllers &headphones. Sports balls/equipment.").
    case doodleForest, doodlePeaks, doodleGaming, doodleSports, doodleRose, doodleLilac, doodleTravel, doodleCafe

    /// A stored id, including pictures since replaced (builds 722 and 723; each moves to the nearest in look).
    init?(stored: String) {
        switch stored {
        case "doodleMint": self = .doodleForest
        case "doodleSky", "doodleTeal": self = .doodleTravel
        case "doodleSand", "doodleLemon": self = .doodleCafe
        case "doodlePeach": self = .doodleRose
        case "clouds", "seaOfClouds": self = .photoClouds
        case "retroSun", "waveTiles", "oceanSunset": self = .photoOcean
        case "terrazzo": self = .rollingHills
        case "cityLights": self = .cityDusk
        case "snowfall": self = .snowyVillage
        case "alpine", "alpenglow": self = .photoAlpenglow
        case "mistyRidges", "mistyForest": self = .photoForest
        case "pinePeaks": self = .posterLake
        case "mountainLake": self = .photoLake
        case "canyon": self = .photoCanyon
        case "lonePeak": self = .posterClouds
        case "starlitPeaks": self = .paintPeaks
        case "desert": self = .photoDunes
        default: self.init(rawValue: stored)
        }
    }

    /// The name on its tile and in the Theme row.
    var label: String {
        switch self {
        case .aurora: "Aurora"
        case .sunset: "Sunset"
        case .ocean: "Ocean"
        case .meadow: "Meadow"
        case .blossom: "Blossom"
        case .dunes: "Dunes"
        case .nebula: "Nebula"
        case .paper: "Paper"
        case .contours: "Contours"
        case .glow: "Theme Glow"
        case .doodleForest: "Forest"
        case .doodlePeaks: "Peaks"
        case .doodleGaming: "Gaming"
        case .doodleSports: "Sports"
        case .doodleRose: "Rose"
        case .doodleLilac: "Lilac"
        case .doodleTravel: "Travel"
        case .doodleCafe: "Café"
        case .photoLake: "Alpine Lake"
        case .photoOcean: "Golden Sea"
        case .photoClouds: "Cloud Deck"
        case .photoDunes: "Sand Ridges"   // not "Dune Sea", a twin of Dunes
        case .photoCanyon: "Red Canyon"
        case .photoForest: "Fog Valley"
        case .photoAurora: "Polar Light"
        case .photoAlpenglow: "Alpenglow"
        case .posterLake: "Emerald Lake"
        case .posterOcean: "Cumulus Coast"
        case .posterClouds: "Summit at Dusk"
        case .posterMesa: "Mesa"
        case .northernLights: "Northern Lights"
        case .snowyVillage: "Snowy Village"
        case .cityDusk: "City at Dusk"
        case .rollingHills: "Rolling Hills"
        case .paintLake: "Still Water"
        case .paintOcean: "Evening Sea"
        case .paintClouds: "Billows"   // not "Cloud Sea", a twin of Cloud Deck
        case .paintHills: "Green Valley"
        case .paintForest: "Birch Wood"
        case .paintDesert: "Painted Desert"
        case .paintPeaks: "Golden Peaks"
        case .paintHarbor: "Harbor"
        }
    }

    /// The section of the Pictures page its tile sits in.
    enum Group: CaseIterable, Sendable {
        /// The first ten, under Classic with None and Your Photo (titled by style, as the groups after it; "Pictures"
        /// said nothing the page didn't).
        case classic
        /// Real terrain, clouds and water, lit like a photograph.
        case photographic
        /// Designed like a printed travel poster: flat inks, bold shapes.
        case illustrated
        /// Loaded brush strokes over a lit study.
        case painted
        /// Packed hand-drawn sets, each with its own drawings and colours.
        case doodles

        var title: String {
            switch self {
            case .classic: "Classic"
            case .photographic: "Photographic"
            case .illustrated: "Illustrated"
            case .painted: "Painted"
            case .doodles: "Doodles"
            }
        }

        var presets: [BackdropPreset] { BackdropPreset.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .aurora, .sunset, .ocean, .meadow, .blossom, .dunes, .nebula, .paper, .contours, .glow: .classic
        case .photoLake, .photoOcean, .photoClouds, .photoDunes, .photoCanyon, .photoForest, .photoAurora, .photoAlpenglow: .photographic
        case .posterLake, .posterOcean, .posterClouds, .posterMesa, .northernLights, .snowyVillage, .cityDusk, .rollingHills: .illustrated
        case .paintLake, .paintOcean, .paintClouds, .paintHills, .paintForest, .paintDesert, .paintPeaks, .paintHarbor: .painted
        case .doodleForest, .doodlePeaks, .doodleGaming, .doodleSports, .doodleRose, .doodleLilac, .doodleTravel, .doodleCafe: .doodles
        }
    }

    /// Slow enough to draw that the finished picture is kept on disk (`BackdropPictureCache`). Doodles draw in about a tenth of a second.
    var keptOnDisk: Bool { group == .photographic || group == .illustrated || group == .painted }

    /// An sRGB colour, 0–1 per channel.
    nonisolated struct Ink: Sendable, Hashable {
        var r: Double
        var g: Double
        var b: Double
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }

    /// Draws the picture `width`×`height` pixels for Light or Dark. All geometry is relative to the picture's short
    /// side, so a small tile is the full picture made small. `accent`: the theme's tint, used by `.glow` only.
    /// Returns nil only if Core Graphics fails.
    func render(width: Int, height: Int, dark: Bool, accent: Ink) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        // The four styles finish their own pictures, grain and all. Their scene names are these ids.
        switch group {
        case .classic: break
        case .photographic: return WallpaperArt.render(.photographic, scene: rawValue, width: width, height: height, dark: dark)
        case .illustrated: return WallpaperArt.render(.illustrated, scene: rawValue, width: width, height: height, dark: dark)
        case .painted: return WallpaperArt.render(.painted, scene: rawValue, width: width, height: height, dark: dark)
        case .doodles: return WallpaperArt.render(.doodles, scene: rawValue, width: width, height: height, dark: dark)
        }
        guard let ctx = BackdropCanvas.context(width: width, height: height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let unit = Double(min(width, height))
        let seed = BackdropCanvas.seed(self, dark: dark)
        switch self {
        case .aurora: BackdropArt.aurora(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .sunset: BackdropArt.sunset(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .ocean: BackdropArt.ocean(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .meadow: BackdropArt.meadow(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .blossom: BackdropArt.blossom(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .dunes: BackdropArt.dunes(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .nebula: BackdropArt.nebula(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .paper: BackdropArt.paper(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .contours: BackdropArt.contours(ctx, rect: rect, unit: unit, dark: dark, seed: seed)
        case .glow: BackdropArt.glow(ctx, rect: rect, unit: unit, dark: dark, seed: seed, accent: accent)
        default: return nil
        }
        // A fixed byte-delta reads as fine, near-invisible grain at phone resolution, but as a coarse speckle on a
        // small picker swatch (fewer, bigger pixels for the same delta): scale it down with the short side.
        let grainAmount = max(1, Int32((5.0 * unit / 1290).rounded()))
        BackdropCanvas.grain(ctx, width: width, height: height, seed: seed, amount: grainAmount)
        return ctx.makeImage()
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

// MARK: Canvas, seed and grain

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

    /// FNV-1a over the preset's name, folded with the appearance: stable across runs and processes (unlike Swift's
    /// own randomised `String.hashValue`), so the same preset and appearance always draw the same picture.
    static func seed(_ preset: BackdropPreset, dark: Bool) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in preset.rawValue.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return dark ? h ^ 0x9E3779B97F4A7C15 : h
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
nonisolated struct Noise2D {
    private struct Term { let dx, dy, phase, amp: Double }
    private let terms: [Term]
    private let norm: Double

    init(seed: UInt64, octaves: Int = 4) {
        var rng = SplitMix64(seed: seed)
        var terms: [Term] = []
        var amp = 0.55, freq = 1.0, norm = 0.0
        for _ in 0..<octaves {
            let angle = rng.next(0, 2 * .pi), phase = rng.next(0, 2 * .pi)
            terms.append(Term(dx: cos(angle) * freq, dy: sin(angle) * freq, phase: phase, amp: amp))
            norm += amp
            amp *= 0.55
            freq *= 1.9
        }
        self.terms = terms
        self.norm = max(norm, 0.0001)
    }

    /// Roughly -1…1 at any `(x, y)` (the units are the caller's own; a step of about 1 is "one feature").
    func value(_ x: Double, _ y: Double) -> Double {
        var sum = 0.0
        for term in terms { sum += term.amp * sin(x * term.dx + y * term.dy + term.phase) }
        return sum / norm
    }
}

// MARK: Shared drawing helpers

nonisolated enum BackdropArt {
    typealias Ink = BackdropPreset.Ink

    /// Fills `rect` top-to-bottom with a multi-stop gradient (Core Graphics' own renderer: fast at any resolution).
    static func verticalWash(_ ctx: CGContext, rect: CGRect, stops: [(Double, Ink)]) {
        let colors = stops.map { $0.1.cg } as CFArray
        guard let gradient = CGGradient(colorsSpace: BackdropCanvas.space, colors: colors, locations: stops.map { CGFloat($0.0) })
        else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    /// A soft round wash of `color`, fading to clear by `radius`: a radial gradient is inherently soft, so this
    /// needs no blur pass. `blend`: `.screen` lifts a colour like light on a dark ground; `.normal` tints a page.
    static func blobGradient(_ color: Ink, alpha: Double) -> CGGradient? {
        CGGradient(colorsSpace: BackdropCanvas.space, colors: [color.cg(alpha: alpha), color.cg(alpha: 0)] as CFArray, locations: [0, 1])
    }

    static func blob(_ ctx: CGContext, center: CGPoint, radius: Double, color: Ink, alpha: Double, blend: CGBlendMode = .normal) {
        guard radius > 0, let gradient = blobGradient(color, alpha: alpha) else { return }
        blob(ctx, center: center, radius: radius, gradient: gradient, blend: blend)
    }

    /// Same, with a gradient the caller already built: a ribbon's 17 blobs share one colour, so building the
    /// gradient once outside the loop (not once per blob) is worth it.
    static func blob(_ ctx: CGContext, center: CGPoint, radius: Double, gradient: CGGradient, blend: CGBlendMode) {
        guard radius > 0 else { return }
        ctx.saveGState()
        ctx.setBlendMode(blend)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// A soft wavy ribbon: a string of overlapping blobs that tapers at both ends (the `sin` on `radius`), the wiggle
    /// from a seeded sine (not `Noise2D`: a single clean wave reads as a ribbon, several stacked ones read as static).
    static func ribbon(_ ctx: CGContext, rect: CGRect, baseX: Double, waviness: Double, width: Double, color: Ink, alpha: Double,
                       blend: CGBlendMode, rng: inout SplitMix64) {
        guard let gradient = blobGradient(color, alpha: alpha) else { return }
        let steps = 16
        let phase = rng.next(0, 2 * .pi)
        let freq = rng.next(1.3, 2.3)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let y = rect.minY + t * rect.height
            let x = baseX + sin(t * freq * .pi + phase) * waviness
            let taper = 0.55 + 0.45 * sin(t * .pi)
            blob(ctx, center: CGPoint(x: x, y: y), radius: width * taper, gradient: gradient, blend: blend)
        }
    }
}

// MARK: Presets

private nonisolated extension BackdropArt {
    /// Ribbons/curtains of teal, green and violet light: a night sky in Dark, a vivid teal-to-violet sky in Light.
    /// Both are a real wallpaper at full strength — the app's own Dim veil is what fades it, not this code.
    static func aurora(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        verticalWash(ctx, rect: rect, stops: dark
            ? [(0, Ink(hex: 0x03060F)), (0.55, Ink(hex: 0x070C1C)), (1, Ink(hex: 0x010308))]
            : [(0, Ink(hex: 0x5FE3C0)), (0.45, Ink(hex: 0x6FC3EC)), (1, Ink(hex: 0xBBA0EE))])
        let hues: [Ink] = dark
            ? [Ink(hex: 0x19C99A), Ink(hex: 0x3D8FFF), Ink(hex: 0x8C6CFF), Ink(hex: 0x22DFC4)]
            : [Ink(hex: 0x12A37E), Ink(hex: 0x1E6FE0), Ink(hex: 0x6C3FD1), Ink(hex: 0x12B89E)]
        let blend: CGBlendMode = dark ? .screen : .normal
        let alpha = dark ? 0.42 : 0.58
        for i in 0..<4 {
            let baseX = rect.minX + unit * (0.08 + 0.28 * Double(i)) + rng.next(-0.04, 0.04) * unit
            ribbon(ctx, rect: rect.insetBy(dx: 0, dy: -unit * 0.15), baseX: baseX, waviness: unit * (0.12 + 0.04 * Double(i % 2)),
                   width: unit * 0.17, color: hues[i], alpha: alpha, blend: blend, rng: &rng)
        }
    }

    /// Vivid coral/rose/violet fields, with a warm glow where the sun would sit.
    static func sunset(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        if dark {
            verticalWash(ctx, rect: rect, stops: [(0, Ink(hex: 0x3B1B4A)), (0.4, Ink(hex: 0x6B2350)), (0.7, Ink(hex: 0x3A1740)),
                                                   (1, Ink(hex: 0x160B22))])
            blob(ctx, center: CGPoint(x: rect.midX, y: rect.minY + unit * 0.3), radius: unit * 1.1, color: Ink(hex: 0xFF8A5C), alpha: 0.45,
                 blend: .screen)
            blob(ctx, center: CGPoint(x: rect.midX + unit * 0.18, y: rect.minY + unit * 0.52), radius: unit * 0.95, color: Ink(hex: 0xD988FF),
                 alpha: 0.35, blend: .screen)
        } else {
            verticalWash(ctx, rect: rect, stops: [(0, Ink(hex: 0xFFB37A)), (0.5, Ink(hex: 0xFF7FA6)), (1, Ink(hex: 0x8C5FD9))])
            blob(ctx, center: CGPoint(x: rect.midX, y: rect.minY + unit * 0.26), radius: unit * 1.05, color: Ink(hex: 0xFFE29A), alpha: 0.55)
            blob(ctx, center: CGPoint(x: rect.midX - unit * 0.16, y: rect.minY + unit * 0.56), radius: unit * 0.9, color: Ink(hex: 0xFF5C93),
                 alpha: 0.38)
        }
    }

    /// Vivid blue/teal, with soft-shaded wave bands rising through the lower two-thirds of the frame (each band is
    /// its own small gradient, not a flat fill, so it reads as a curved, lit wave rather than a hard step).
    static func ocean(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        verticalWash(ctx, rect: rect, stops: dark
            ? [(0, Ink(hex: 0x042430)), (0.5, Ink(hex: 0x0B5068)), (1, Ink(hex: 0x010B12))]
            : [(0, Ink(hex: 0x3FD0DE)), (0.5, Ink(hex: 0x1C98C4)), (1, Ink(hex: 0x0B5A86))])
        let bandCount = 6
        let shallow = dark ? Ink(hex: 0x1D7E96) : Ink(hex: 0x9FEFEF)
        let deep = dark ? Ink(hex: 0x02222E) : Ink(hex: 0x0B4A72)
        for i in 0..<bandCount {
            let t = Double(i) / Double(bandCount - 1)
            let bandTop = rect.minY + rect.height * (0.38 + 0.11 * t)
            let amp = unit * (0.02 + 0.016 * t)
            let freq = 1.3 + 0.45 * Double(i)
            let phase = rng.next(0, 2 * .pi)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            var x = rect.minX
            while x <= rect.maxX {
                let y = bandTop + sin((x - rect.minX) / unit * freq * 2 * .pi + phase) * amp
                path.addLine(to: CGPoint(x: x, y: y))
                x += unit * 0.02
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            let bandColor = shallow.mixed(with: deep, t)
            let crest = bandColor.mixed(with: shallow, 0.6)
            guard let gradient = CGGradient(colorsSpace: BackdropCanvas.space,
                                             colors: [crest.cg(alpha: dark ? 0.55 : 0.5), bandColor.cg(alpha: dark ? 0.4 : 0.38)] as CFArray,
                                             locations: [0, 1])
            else { continue }
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: bandTop - amp), end: CGPoint(x: rect.midX, y: bandTop + unit * 0.18),
                                   options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    /// Vivid grass green to saffron yellow, with pools of richer meadow light.
    static func meadow(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        if dark {
            verticalWash(ctx, rect: rect, stops: [(0, Ink(hex: 0x163A22)), (0.6, Ink(hex: 0x0F2817)), (1, Ink(hex: 0x040A05))])
            blob(ctx, center: CGPoint(x: rect.minX + unit * 0.3, y: rect.minY + unit * 0.35), radius: unit * 1.05, color: Ink(hex: 0xFFC65C),
                 alpha: 0.4, blend: .screen)
            blob(ctx, center: CGPoint(x: rect.maxX - unit * 0.2, y: rect.maxY - unit * 0.4), radius: unit * 0.95, color: Ink(hex: 0x4FB868),
                 alpha: 0.44, blend: .screen)
        } else {
            verticalWash(ctx, rect: rect, stops: [(0, Ink(hex: 0x8FD36A)), (1, Ink(hex: 0xF4C94A))])
            blob(ctx, center: CGPoint(x: rect.minX + unit * 0.26, y: rect.minY + unit * 0.3), radius: unit * 1.0, color: Ink(hex: 0x4FAE4A),
                 alpha: 0.42)
            blob(ctx, center: CGPoint(x: rect.maxX - unit * 0.22, y: rect.maxY - unit * 0.3), radius: unit * 1.0, color: Ink(hex: 0xFFB703),
                 alpha: 0.44)
        }
    }

    /// Vivid pink, peach and gold, with a couple of richer bokeh-like blooms.
    static func blossom(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        if dark {
            verticalWash(ctx, rect: rect, stops: [(0, Ink(hex: 0x3D1830)), (0.55, Ink(hex: 0x2A1226)), (1, Ink(hex: 0x100810))])
            blob(ctx, center: CGPoint(x: rect.midX + unit * 0.12, y: rect.minY + unit * 0.3), radius: unit * 1.05, color: Ink(hex: 0xFF6FA0),
                 alpha: 0.42, blend: .screen)
            blob(ctx, center: CGPoint(x: rect.minX + unit * 0.2, y: rect.maxY - unit * 0.42), radius: unit * 0.95, color: Ink(hex: 0xB3449A),
                 alpha: 0.36, blend: .screen)
        } else {
            verticalWash(ctx, rect: rect, stops: [(0, Ink(hex: 0xFF9EC4)), (0.5, Ink(hex: 0xFFBB8A)), (1, Ink(hex: 0xFFE6B0))])
            blob(ctx, center: CGPoint(x: rect.maxX - unit * 0.18, y: rect.minY + unit * 0.3), radius: unit * 1.0, color: Ink(hex: 0xFFA94D),
                 alpha: 0.4)
            blob(ctx, center: CGPoint(x: rect.minX + unit * 0.2, y: rect.maxY - unit * 0.32), radius: unit * 1.0, color: Ink(hex: 0xF6568F),
                 alpha: 0.36)
        }
    }

    /// Layered sand hills, each ridge shaded from a lit crest to its own deeper tone (a gradient fill, not a flat
    /// one) with a thin warm rim of light traced along the ridge line itself, the way a low sun catches a dune's
    /// edge: sand in Light, dusk dunes in Dark.
    static func dunes(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        verticalWash(ctx, rect: rect, stops: dark
            ? [(0, Ink(hex: 0x2B1740)), (0.5, Ink(hex: 0x3B2354)), (1, Ink(hex: 0x160E22))]
            : [(0, Ink(hex: 0xFFE2AE)), (0.5, Ink(hex: 0xFBC983)), (1, Ink(hex: 0xE2A355))])
        let layerCount = 5
        // Dark's near (closest, bottom-most) layer stays a visible dusk violet, not near-black: two neighbouring
        // layers mixed toward black both read as "black", losing the ridge line between them.
        let farColor = dark ? Ink(hex: 0x55356F) : Ink(hex: 0xF6D79B)
        let nearColor = dark ? Ink(hex: 0x1F1428) : Ink(hex: 0xBD7836)
        let highlight = dark ? Ink(hex: 0x8C6FB0) : Ink(hex: 0xFFF2CF)
        for i in 0..<layerCount {
            let t = Double(i) / Double(layerCount - 1)
            let baseY = rect.minY + rect.height * (0.34 + 0.2 * t)
            let amp = unit * (0.055 + 0.045 * t)
            let freq = rng.next(1.0, 1.7)
            let phase = rng.next(0, 2 * .pi)
            let phase2 = rng.next(0, 2 * .pi)
            func ridgeY(_ x: Double) -> Double {
                let u = (x - rect.minX) / unit
                return baseY - amp * (0.5 + 0.5 * sin(u * freq + phase)) - amp * 0.3 * sin(u * freq * 2.3 + phase2)
            }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            var x = rect.minX
            while x <= rect.maxX { path.addLine(to: CGPoint(x: x, y: ridgeY(x))); x += unit * 0.015 }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            let layerColor = farColor.mixed(with: nearColor, t)
            let crest = layerColor.mixed(with: highlight, dark ? 0.3 : 0.45)
            // The gradient runs all the way to the bottom of the frame, not just past the ridge crest: the
            // frontmost layer's fill IS the foreground sand/dusk floor, so it needs its own gentle shading
            // (crest → base tone → a touch deeper at the very bottom) or that whole floor reads as one flat block.
            let shadow = layerColor.mixed(with: dark ? Ink(hex: 0x05030A) : Ink(hex: 0x6B3F18), 0.4)
            if let gradient = CGGradient(colorsSpace: BackdropCanvas.space, colors: [crest.cg, layerColor.cg, shadow.cg] as CFArray,
                                         locations: [0, 0.22, 1]) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: baseY - amp * 1.4), end: CGPoint(x: rect.midX, y: rect.maxY),
                                       options: [])
                ctx.restoreGState()
            }
            let rim = CGMutablePath()
            x = rect.minX
            rim.move(to: CGPoint(x: x, y: ridgeY(x)))
            while x <= rect.maxX { rim.addLine(to: CGPoint(x: x, y: ridgeY(x))); x += unit * 0.015 }
            ctx.setStrokeColor(crest.cg(alpha: dark ? 0.5 : 0.55))
            ctx.setLineWidth(max(1, unit * 0.002))
            ctx.addPath(rim)
            ctx.strokePath()
        }
    }

    /// Deep space with bigger, stronger, varied purple/blue/magenta glows and sparse tiny stars in Dark; a vivid
    /// periwinkle-to-orchid haze with faint specks in Light. Each glow is a soft outer halo plus a tighter, brighter
    /// core — a single huge soft blob dilutes to almost nothing once the app's own veil goes over it; a bright core
    /// still reads as a clear pool of light.
    static func nebula(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let a = CGPoint(x: rect.minX + unit * 0.32, y: rect.minY + unit * 0.4)
        let b = CGPoint(x: rect.maxX - unit * 0.22, y: rect.maxY - unit * 0.45)
        let c = CGPoint(x: rect.maxX - unit * 0.3, y: rect.minY + unit * 0.2)
        if dark {
            verticalWash(ctx, rect: rect, stops: [(0, Ink(hex: 0x0A0B1C)), (0.5, Ink(hex: 0x15123A)), (1, Ink(hex: 0x030308))])
            blob(ctx, center: a, radius: unit * 1.15, color: Ink(hex: 0x7A4DFF), alpha: 0.38, blend: .screen)
            blob(ctx, center: a, radius: unit * 0.46, color: Ink(hex: 0x9D7CFF), alpha: 0.68, blend: .screen)
            blob(ctx, center: b, radius: unit * 1.0, color: Ink(hex: 0x3A7DFF), alpha: 0.3, blend: .screen)
            blob(ctx, center: b, radius: unit * 0.4, color: Ink(hex: 0x6CA0FF), alpha: 0.6, blend: .screen)
            blob(ctx, center: c, radius: unit * 0.85, color: Ink(hex: 0xC94DFF), alpha: 0.24, blend: .screen)
            blob(ctx, center: c, radius: unit * 0.35, color: Ink(hex: 0xDD7CFF), alpha: 0.5, blend: .screen)
        } else {
            verticalWash(ctx, rect: rect, stops: [(0, Ink(hex: 0x8FA0F2)), (0.5, Ink(hex: 0xA98CE8)), (1, Ink(hex: 0xD48CE0))])
            blob(ctx, center: a, radius: unit * 1.2, color: Ink(hex: 0x8F5FE0), alpha: 0.4)
            blob(ctx, center: a, radius: unit * 0.5, color: Ink(hex: 0x7038D0), alpha: 0.4)
            blob(ctx, center: b, radius: unit * 1.0, color: Ink(hex: 0x4F7FEF), alpha: 0.3)
            blob(ctx, center: b, radius: unit * 0.45, color: Ink(hex: 0x2F5FE0), alpha: 0.3)
        }
        let count = dark ? 220 : 60
        let starColor = dark ? Ink(hex: 0xFFFFFF) : Ink(hex: 0x6E5AA3)
        for _ in 0..<count {
            let x = rect.minX + rng.next() * rect.width
            let y = rect.minY + rng.next() * rect.height
            let r = unit * (dark ? 0.0012 : 0.001) * (0.5 + rng.next())
            let a = dark ? rng.next(0.3, 0.85) : rng.next(0.06, 0.16)
            ctx.setFillColor(starColor.cg(alpha: a))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// A dot grid on warm, saturated paper in Light, on a richer slate in Dark. The quietest of the ten by design,
    /// but the dots and the paper tone are both pushed up so the texture still reads under the app's own veil.
    static func paper(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        let top = dark ? Ink(hex: 0x232838) : Ink(hex: 0xF3DFB8)
        let bottom = dark ? Ink(hex: 0x161A24) : Ink(hex: 0xE7C98C)
        verticalWash(ctx, rect: rect, stops: [(0, top), (1, bottom)])
        let dot = dark ? Ink(hex: 0xFFFFFF) : Ink(hex: 0x6B5B3F)
        let alpha = dark ? 0.14 : 0.18
        let spacing = unit * 0.055
        let radius = unit * 0.004
        ctx.setFillColor(dot.cg(alpha: alpha))
        var y = rect.minY + spacing * 0.5
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + spacing * 0.5 + (row.isMultiple(of: 2) ? 0 : spacing / 2)
            while x < rect.maxX {
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
                x += spacing
            }
            y += spacing * 0.86
            row += 1
        }
    }

    /// Topographic contour lines on a saturated sage/blue-grey (Light) or navy-teal (Dark) ground: the ground is a
    /// smooth noise field drawn small and scaled up, the lines are marching squares over the same field at full
    /// resolution, boosted enough to read clearly under the app's own veil.
    static func contours(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64) {
        let noise = Noise2D(seed: seed)
        let low = dark ? Ink(hex: 0x152A42) : Ink(hex: 0xBFE0C0)
        let high = dark ? Ink(hex: 0x1E4A5C) : Ink(hex: 0xA9D6E8)
        let smallShort = 72
        let smallWidth = max(1, Int((rect.width / unit * Double(smallShort)).rounded()))
        let smallHeight = max(1, Int((rect.height / unit * Double(smallShort)).rounded()))
        if let smallCtx = BackdropCanvas.context(width: smallWidth, height: smallHeight), let data = smallCtx.data {
            let bytesPerRow = smallCtx.bytesPerRow
            let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * smallHeight)
            for iy in 0..<smallHeight {
                let ny = Double(iy) / Double(smallShort)
                let row = iy * bytesPerRow
                for ix in 0..<smallWidth {
                    let nx = Double(ix) / Double(smallShort)
                    let v = (noise.value(nx * 1.3, ny * 1.3) + 1) / 2
                    let c = low.mixed(with: high, v)
                    let i = row + ix * 4
                    pixels[i] = UInt8((c.r * 255).rounded())
                    pixels[i + 1] = UInt8((c.g * 255).rounded())
                    pixels[i + 2] = UInt8((c.b * 255).rounded())
                    pixels[i + 3] = 255
                }
            }
            if let small = smallCtx.makeImage() { BackdropCanvas.drawUpright(small, in: rect, ctx: ctx) }
        } else {
            verticalWash(ctx, rect: rect, stops: [(0, low), (1, high)])
        }
        let cell = unit / 20
        let cols = max(1, Int((rect.width / cell).rounded(.up)))
        let rows = max(1, Int((rect.height / cell).rounded(.up)))
        var grid = [[Double]](repeating: [Double](repeating: 0, count: cols + 1), count: rows + 1)
        for j in 0...rows {
            let ny = Double(j) * cell / unit
            for i in 0...cols {
                let nx = Double(i) * cell / unit
                grid[j][i] = noise.value(nx * 1.3, ny * 1.3)
            }
        }
        let lineColor = dark ? Ink(hex: 0x9FC4E8) : Ink(hex: 0x3E5C3A)
        ctx.setStrokeColor(lineColor.cg(alpha: dark ? 0.45 : 0.42))
        ctx.setLineWidth(max(1, unit * 0.002))
        ctx.setLineCap(.round)
        for level in [-0.6, -0.3, 0, 0.3, 0.6] {
            let path = CGMutablePath()
            for j in 0..<rows {
                for i in 0..<cols { marchCell(path, grid: grid, i: i, j: j, level: level, rect: rect, cell: cell) }
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// One marching-squares cell: adds 0, 1 or 2 line segments where `level` crosses the cell's four edges.
    static func marchCell(_ path: CGMutablePath, grid: [[Double]], i: Int, j: Int, level: Double, rect: CGRect, cell: Double) {
        let tl = grid[j][i], tr = grid[j][i + 1], bl = grid[j + 1][i], br = grid[j + 1][i + 1]
        let x0 = rect.minX + Double(i) * cell, y0 = rect.minY + Double(j) * cell
        let x1 = x0 + cell, y1 = y0 + cell
        func lerp(_ a: Double, _ b: Double, _ va: Double, _ vb: Double) -> Double {
            let d = vb - va
            guard abs(d) > 1e-9 else { return (a + b) / 2 }
            return a + (b - a) * (level - va) / d
        }
        var code = 0
        if tl > level { code |= 1 }
        if tr > level { code |= 2 }
        if br > level { code |= 4 }
        if bl > level { code |= 8 }
        guard code != 0, code != 15 else { return }
        let top = CGPoint(x: lerp(x0, x1, tl, tr), y: y0)
        let right = CGPoint(x: x1, y: lerp(y0, y1, tr, br))
        let bottom = CGPoint(x: lerp(x0, x1, bl, br), y: y1)
        let left = CGPoint(x: x0, y: lerp(y0, y1, tl, bl))
        func seg(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
        switch code {
        case 1, 14: seg(left, top)
        case 2, 13: seg(top, right)
        case 3, 12: seg(left, right)
        case 4, 11: seg(right, bottom)
        case 6, 9: seg(top, bottom)
        case 7, 8: seg(left, bottom)
        case 5: seg(left, top); seg(right, bottom) // saddle: one consistent diagonal, decorative, not exact
        case 10: seg(top, right); seg(left, bottom)
        default: break
        }
    }

    /// Big, strong blobs of the theme's own tint, plus a hue-shifted partner colour, over a neutral ground. Each is
    /// a big soft halo plus a tighter, brighter core: the halo gives it scale, the core gives it a clearly-visible
    /// pool of light that still reads once the app's own veil goes over it.
    static func glow(_ ctx: CGContext, rect: CGRect, unit: Double, dark: Bool, seed: UInt64, accent: Ink) {
        let top = dark ? Ink(hex: 0x1C1D22) : Ink(hex: 0xF2F1EC)
        let bottom = dark ? Ink(hex: 0x0E0E12) : Ink(hex: 0xE7E4DA)
        verticalWash(ctx, rect: rect, stops: [(0, top), (1, bottom)])
        let partner = accent.hueShifted(by: 48)
        let a = CGPoint(x: rect.minX + unit * 0.28, y: rect.minY + unit * 0.4)
        let b = CGPoint(x: rect.maxX - unit * 0.22, y: rect.maxY - unit * 0.48)
        if dark {
            blob(ctx, center: a, radius: unit * 1.35, color: accent, alpha: 0.46, blend: .screen)
            blob(ctx, center: a, radius: unit * 0.55, color: accent, alpha: 0.85, blend: .screen)
            blob(ctx, center: b, radius: unit * 1.15, color: partner, alpha: 0.36, blend: .screen)
            blob(ctx, center: b, radius: unit * 0.48, color: partner, alpha: 0.7, blend: .screen)
        } else {
            blob(ctx, center: a, radius: unit * 1.3, color: accent, alpha: 0.26)
            blob(ctx, center: a, radius: unit * 0.55, color: accent, alpha: 0.55)
            blob(ctx, center: b, radius: unit * 1.1, color: partner, alpha: 0.2)
            blob(ctx, center: b, radius: unit * 0.48, color: partner, alpha: 0.46)
        }
    }
}
