// desktoplook: colour maths for the theming layer (spec 3x-desktoplook §3.2, §5.5). Pure and nonisolated: the
// resolver runs it once per theme change, never per draw.

import Foundation

/// An sRGB colour; channels and alpha 0…1.
nonisolated struct RGBA: Sendable, Hashable {
    var r: Double, g: Double, b: Double, a: Double

    /// Channels 0…255 (the generated seed table), alpha 0…1.
    init(_ r255: Double, _ g255: Double, _ b255: Double, _ a: Double = 1) {
        r = r255 / 255; g = g255 / 255; b = b255 / 255; self.a = a
    }
    init(unit r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF), alpha)
    }

    static let white = RGBA(hex: 0xFFFFFF)
    static let black = RGBA(hex: 0x000000)

    func alpha(_ value: Double) -> RGBA { RGBA(unit: r, g, b, value) }
    /// `color-mix(in srgb, self p%, transparent)`.
    func faded(_ percent: Double) -> RGBA { RGBA(unit: r, g, b, a * percent / 100) }

    /// CSS `color-mix(in srgb, self percent%, other)`: premultiplied interpolation.
    func mix(_ percent: Double, _ other: RGBA) -> RGBA {
        let p = percent / 100, q = 1 - p
        let alpha = a * p + other.a * q
        guard alpha > 0 else { return RGBA(unit: 0, 0, 0, 0) }
        return RGBA(unit: (r * a * p + other.r * other.a * q) / alpha, (g * a * p + other.g * other.a * q) / alpha,
                    (b * a * p + other.b * other.a * q) / alpha, alpha)
    }

    /// CSS `color-mix(in oklab, self percent%, other)` (Björn Ottosson's matrices, as desktop-look.ts:83-85).
    func mixOklab(_ percent: Double, _ other: RGBA) -> RGBA {
        let p = percent / 100, q = 1 - p
        let alpha = a * p + other.a * q
        guard alpha > 0 else { return RGBA(unit: 0, 0, 0, 0) }
        let x = oklab, y = other.oklab
        func lerp(_ u: Double, _ v: Double) -> Double { (u * a * p + v * other.a * q) / alpha }
        return RGBA.fromOklab(lerp(x.0, y.0), lerp(x.1, y.1), lerp(x.2, y.2), alpha)
    }

    /// Source-over on an opaque colour.
    func over(_ under: RGBA) -> RGBA {
        RGBA(unit: r * a + under.r * (1 - a), g * a + under.g * (1 - a), b * a + under.b * (1 - a), 1)
    }

    private static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func toGamma(_ v: Double) -> Double {
        let c = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        return min(1, max(0, c))
    }

    var oklab: (Double, Double, Double) {
        let lr = RGBA.toLinear(r), lg = RGBA.toLinear(g), lb = RGBA.toLinear(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func fromOklab(_ L: Double, _ A: Double, _ B: Double, _ alpha: Double) -> RGBA {
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.291485548 * B, 3)
        return RGBA(unit: toGamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                    toGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                    toGamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s), alpha)
    }

    /// WCAG relative luminance (the web's own constant, 0.03928, desktop-look.ts:91).
    var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(with other: RGBA) -> Double {
        let x = luminance, y = other.luminance
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // CIELAB (D50, as CSS lab()/lch()), for the tint floor (`lch(from … max(l, 57) c h)`) and the on-tint ink.
    private var labD50: (Double, Double, Double) {
        let lr = RGBA.toLinear(r), lg = RGBA.toLinear(g), lb = RGBA.toLinear(b)
        // linear sRGB -> XYZ D50 (Bradford-adapted matrix, CSS Color 4)
        let x = 0.4360747 * lr + 0.3850649 * lg + 0.1430804 * lb
        let y = 0.2225045 * lr + 0.7168786 * lg + 0.0606169 * lb
        let z = 0.0139322 * lr + 0.0971045 * lg + 0.7141733 * lb
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x / 0.96422), fy = f(y), fz = f(z / 0.82521)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIELAB lightness 0…100.
    var labL: Double { labD50.0 }

    /// The same hue and chroma with CIELAB L raised to at least `floor` (clipped into sRGB).
    func raisingL(to floor: Double) -> RGBA {
        let lab = labD50
        guard lab.0 < floor else { return self }
        func inv(_ t: Double) -> Double { t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) / (24389.0 / 27) }
        func at(_ lightness: Double) -> RGBA {
            let fy = (lightness + 16) / 116, fx = lab.1 / 500 + fy, fz = fy - lab.2 / 200
            let x = inv(fx) * 0.96422, y = inv(fy), z = inv(fz) * 0.82521
            let lr = 3.1338561 * x - 1.6168667 * y - 0.4906146 * z
            let lg = -0.9787684 * x + 1.9161415 * y + 0.0334540 * z
            let lb = 0.0719453 * x - 0.2289914 * y + 1.4052427 * z
            return RGBA(unit: RGBA.toGamma(lr), RGBA.toGamma(lg), RGBA.toGamma(lb), a)
        }
        // Clipping a saturated colour into sRGB loses lightness, so aim a little higher until the floor holds.
        var result = at(floor)
        var target = floor
        while result.labL < floor - 0.25, target < 100 {
            target += 1
            result = at(target)
        }
        return result
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

nonisolated enum ThemeMath {
    /// Port of `legibleMix` (desktop-look.ts:96-105): how much of `source` is kept (100 = untouched) when it is mixed
    /// toward `text` in 10 % steps until it reads at 4.5:1 on `page`.
    static func legibleKeep(source: RGBA, text: RGBA, page: RGBA) -> Int {
        let ground = page.over(.white)
        for keep in stride(from: 100, through: 0, by: -10) {
            let colour = source.mixOklab(Double(keep), text)
            if colour.over(ground).contrast(with: ground) >= 4.5 { return keep }
        }
        return 0
    }

    static func legible(source: RGBA, text: RGBA, page: RGBA) -> RGBA {
        let keep = legibleKeep(source: source, text: text, page: page)
        return keep == 100 ? source : source.mixOklab(Double(keep), text)
    }

    /// Finer than the web's 10 % steps, for values the web never had to fix (the iOS look's tint text on other skins):
    /// mixes toward `text` until `ratio` holds, and falls back to `text` itself.
    static func readable(_ source: RGBA, text: RGBA, on page: RGBA, ratio: Double = 4.5) -> RGBA {
        let ground = page.over(.white)
        for keep in stride(from: 100, through: 0, by: -5) {
            let colour = source.mixOklab(Double(keep), text)
            if colour.over(ground).contrast(with: ground) >= ratio { return colour }
        }
        return text
    }
}
