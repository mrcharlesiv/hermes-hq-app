// The Robot, Dots, Orb, Pixel and Emoji heads, ported line for line from the web app's `src/ui-heads/robot.ts`,
// `parts.ts` and `render.ts`. Each builds the same SVG markup the web builds (numbers printed as JavaScript prints
// them), so the port can be checked against the web's own output; SVGMini draws it. Pure value code.

import Foundation

nonisolated enum ThemeHeadSVG {
    typealias Point = (Double, Double)
    static let tau = Double.pi * 2

    // MARK: JavaScript number semantics

    /// `Math.round`: halves go up, toward +∞.
    static func round(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
    /// A number as a template literal prints it (shortest round-trip, integers without ".0", -0 as "0").
    static func js(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e21 { return String(Int64(v)) }
        return "\(v)"
    }
    /// robot.ts / parts.ts `n`: a whole number.
    static func n(_ v: Double) -> String { js(round(v)) }
    /// render.ts `n`: one decimal place.
    static func n1(_ v: Double) -> Double { round(v * 10) / 10 }

    // MARK: Tones (`robot.ts:11-37`)

    struct Tone: Sendable { var panel: String; var accent: String; var light: String; var deep: String }
    static let ink = "#0A0A0A"
    static let tones: [String: Tone] = [
        "ink": Tone(panel: "#F7F5F0", accent: "#2EC4B6", light: "#A8F0E8", deep: "#148F86"),
        "mint": Tone(panel: "#BDEEDF", accent: "#1FCFA5", light: "#B4F8E4", deep: "#0C8F70"),
        "teal": Tone(panel: "#AEE6EE", accent: "#22BCD8", light: "#B8F2FB", deep: "#0E8098"),
        "sky": Tone(panel: "#BCD9FF", accent: "#4A93FF", light: "#CBE0FF", deep: "#1F5FC4"),
        "lilac": Tone(panel: "#D7CCFF", accent: "#9479FF", light: "#DDD3FF", deep: "#5B3FD0"),
        "pink": Tone(panel: "#FFC7E1", accent: "#FF66AD", light: "#FFD3E8", deep: "#C7327A"),
        "coral": Tone(panel: "#FFC4B6", accent: "#FF7057", light: "#FFD5CB", deep: "#C5432D"),
        "peach": Tone(panel: "#FFDAB6", accent: "#FFA043", light: "#FFE3C4", deep: "#C96C14"),
        "butter": Tone(panel: "#FBE69C", accent: "#FFCE2E", light: "#FFF1B5", deep: "#C29100"),
        "lime": Tone(panel: "#D6F1A6", accent: "#96DB3C", light: "#E0F8B6", deep: "#5E9E12"),
        "paper": Tone(panel: "#E7E1D3", accent: "#EFE9DB", light: "#FFFFFF", deep: "#8F8672"),
        "red": Tone(panel: "#F9B8B7", accent: "#EF3B36", light: "#FAC6C5", deep: "#A72926"),
        "grass": Tone(panel: "#B3E8C6", accent: "#2DBE60", light: "#C2ECD1", deep: "#208543"),
        "forest": Tone(panel: "#B0CEBF", accent: "#23784E", light: "#BFD8CC", deep: "#195437"),
        "cobalt": Tone(panel: "#B4C4FF", accent: "#2E5BFF", light: "#C2CFFF", deep: "#2040B3"),
        "denim": Tone(panel: "#B8C4E0", accent: "#3A5BA8", light: "#C6CFE6", deep: "#294076"),
        "grape": Tone(panel: "#D0B8F9", accent: "#7C3AED", light: "#D9C6FA", deep: "#5729A6"),
        "plum": Tone(panel: "#D5BAD9", accent: "#8A3F96", light: "#DDC7E1", deep: "#612C69"),
        "magenta": Tone(panel: "#F4AFD5", accent: "#E0218A", light: "#F6BFDD", deep: "#9D1761"),
        "rose": Tone(panel: "#FFE2EB", accent: "#FFAFC8", light: "#FFE8EF", deep: "#B37B8C"),
        "wine": Tone(panel: "#E3B4C2", accent: "#B03055", light: "#E8C3CE", deep: "#7B223C"),
        "caramel": Tone(panel: "#ECD5C2", accent: "#C98A55", light: "#EFDDCE", deep: "#8D613C"),
        "cocoa": Tone(panel: "#D5C2B7", accent: "#8A5638", light: "#DDCEC5", deep: "#613C27"),
        "slate": Tone(panel: "#CACED4", accent: "#6B7688", light: "#D4D7DC", deep: "#4B535F"),
    ]
    static func tone(_ color: String) -> Tone { tones[color] ?? tones["mint"]! }

    // MARK: The icon's parts (`parts.ts:8-19`)

    static let frame = "M350 0h324c101 0 151 0 205 17 60 22 106 68 128 128 17 54 17 104 17 205v324c0 101 0 151-17 205-22 60-68 106-128 128-54 17-104 17-205 17h-324c-101 0-151 0-205-17-60-22-106-68-128-128-17-54-17-104-17-205v-324c0-101 0-151 17-205 22-60 68-106 128-128 54-17 104-17 205-17z"
    static let panel = "M322 54h380c77 0 116 0 157 13 46 17 81 52 98 98 13 41 13 80 13 157v380c0 77 0 116-13 157-17 46-52 81-98 98-41 13-80 13-157 13h-380c-77 0-116 0-157-13-46-17-81-52-98-98-13-41-13-80-13-157v-380c0-77 0-116 13-157 17-46 52-81 98-98 41-13 80-13 157-13z"
    static let dome = "M600 199c99 3 198 34 252 123 28 46 41 103 44 156 4 55-2 110-32 158-14 23-34 45-58 61-49 33-147 51-206 60-34 5-67 8-100 10-32 2-64 6-95 5-69-1-95-5-153-44-21-14-41-29-56-48-34-42-47-95-49-148-1-28 0-56 6-84 14-65 40-105 90-148 18-16 35-27 57-38 74-37 217-65 300-63z"
    static let visor = "M725 364c13-1 22-2 33-1 10 0 21 3 31 7 45 16 69 50 80 95 3 14 6 30 8 45 4 34-1 64-21 92-19 28-48 44-79 55-17 5-41 10-62 15-20 5-41 11-61 15-42 8-83 14-125 18-21 3-46 6-63 6-58 3-109-18-135-72-4-10-7-22-10-31-3-15-6-31-8-46-5-45 7-86 43-116 17-15 36-22 58-27 17-4 42-8 62-11 42-8 83-15 125-22 21-4 41-7 62-11 21-4 45-9 62-11z"
    static let shoulders = "M205 1034l7-34c7-26 13-51 24-75 15-32 35-60 64-82 26-19 60-33 92-40 61-14 160-13 223-6 19 2 36 4 53 9 78 22 129 76 154 152 5 14 7 28 10 42l8 34z"
    static let neck = "M410 728c26-20 163-25 186-6 11 9 4 28 6 40 2 9 3 17 6 24 3 7 13 16 10 20-4 7-43-1-63 0-19 1-37 4-55 7-18 3-37 8-55 13-18 6-45 25-53 20-10-6 3-67 6-78 3-14 0-31 12-40z"
    static let shoulderLights = "M240 968c20-48 36-86 79-118 13-10 27-18 41-26-53 20-87 41-108 96-6 16-9 31-12 48zM352 858c64-25 136-50 205-54 23-1 47 1 71 2-24-4-47-8-71-8-24-1-48 3-72 8-49 11-89 28-133 52zM503 968c9-34 15-72 43-98 12-11 30-18 46-24 17-6 35-10 53-11 17-1 36 1 52 7 16 5 31 17 44 29 13 11 25 26 35 41 9 15 14 33 21 50-5-18-8-37-16-53-9-16-21-32-34-45-13-13-29-26-46-32-36-14-77-9-112 5-17 6-36 15-49 27-12 13-21 32-27 50-6 17-7 36-10 54z"
    static let neckLightA = "M522 772c9 1 17 1 26 0 41-1 35-9 49 32 1-4 2-9 2-13 0-29-16-30-39-27-13 2-25 4-38 8z"
    static let neckLightB = "M414 772c-9 14-13 30-11 46 10-14 15-29 11-46z"
    static let tuft = "M262 302l26-13 16-7 23-12 9-3 28-4-4-13 28 11 18 1-5-14 31 21 18 6 8 3-4-12 30 22 22 9 10 9 14 4 67 34 25 15-4 1-16-4-34 8 8-16-8-2-56 20 14-35-8-3-55 32 17-46-6-2-43 34 13-43-6-2-56 42 14-51-6-1-34 35 10-38-6-1-38 32 10-30-6 1-33 20 9-14-36 7z"
    static let domeLights = "M278 293c-7 4-15 7-22 11-36 20-66 55-82 93-6 15-9 32-12 48 6-15 12-31 19-45 22-43 61-76 97-107zM268 330c-9 7-18 14-26 22-22 27-32 61-38 94 13-30 26-61 45-89 6-9 13-18 19-27zM296 346c-32 26-50 57-62 96 20-33 41-64 62-96zM455 241c48-2 92-7 141 0 15 3 31 6 46 9-72-27-113-27-187-9zM566 252c39 10 77 18 115 33 9 4 18 8 27 12 9 4 18 9 26 14 18 9 34 21 50 33-15-14-29-27-46-39-9-5-18-10-27-15-52-28-87-33-145-38zM738 240c20 10 41 18 58 32 52 42 69 116 79 178 0-38-2-64-14-101-12-33-29-65-59-85-19-13-42-18-64-24zM860 634c-9 9-18 19-27 27-16 14-36 25-53 37 40-12 61-25 80-64z"

    // MARK: Outline helpers (`parts.ts:21-63`)

    static func around(_ count: Int, _ at: (Double) -> Point) -> [Point] {
        (0..<count).map { at(Double($0) / Double(count) * tau - Double.pi / 2) }
    }

    static func cloud() -> [Point] {
        let puffs: [(Double, Double, Double)] = [(-0.58, -0.02, 0.44), (-0.14, -0.36, 0.5), (0.4, -0.26, 0.44), (0.72, 0.08, 0.36)]
        let origin: Point = (0, 0.12)
        return around(72) { t in
            let d: Point = (cos(t), sin(t))
            var reach = 1 / (pow(d.0 / 0.98, 2) + pow(d.1 / 0.4, 2)).squareRoot()
            for (cx, cy, r) in puffs {
                let x = cx - origin.0, y = cy - origin.1, b = d.0 * x + d.1 * y, q = b * b - (x * x + y * y - r * r)
                if q >= 0 { reach = max(reach, b + q.squareRoot()) }
            }
            return (origin.0 + d.0 * reach, origin.1 + d.1 * reach)
        }
    }

    static func superellipse(_ w: Double, _ h: Double, _ power: Double, _ count: Int = 40) -> [Point] {
        around(count) { t in
            let c = cos(t), s = sin(t)
            return (sign(c) * pow(abs(c), power) * w, sign(s) * pow(abs(s), power) * h)
        }
    }

    /// `Math.sign`.
    private static func sign(_ v: Double) -> Double { v > 0 ? 1 : v < 0 ? -1 : v }

    static func wobble(_ points: [Point], seed: Int, amount: Double) -> [Point] {
        let a = Double(seed % 997) / 997 * tau, b = Double(seed % 613) / 613 * tau
        return points.map { p in
            let t = atan2(p.1, p.0), k = 1 + amount * (sin(3 * t + a) * 0.6 + sin(5 * t + b) * 0.4)
            return (p.0 * k, p.1 * k)
        }
    }

    /// A closed Catmull-Rom spline through the points, as a path and as a dense outline to cut highlights from.
    static func spline(_ p: [Point]) -> (d: String, dense: [Point]) {
        let count = p.count
        var dense: [Point] = []
        var d = "M\(n(p[0].0)) \(n(p[0].1))"
        for i in 0..<count {
            let p0 = p[(i - 1 + count) % count], p1 = p[i], p2 = p[(i + 1) % count], p3 = p[(i + 2) % count]
            let c1: Point = (p1.0 + (p2.0 - p0.0) / 6, p1.1 + (p2.1 - p0.1) / 6)
            let c2: Point = (p2.0 - (p3.0 - p1.0) / 6, p2.1 - (p3.1 - p1.1) / 6)
            d += "C\(n(c1.0)) \(n(c1.1)) \(n(c2.0)) \(n(c2.1)) \(n(p2.0)) \(n(p2.1))"
            for step in 0..<6 {
                let t = Double(step) / 6, u = 1 - t
                dense.append((pow(u, 3) * p1.0 + 3 * u * u * t * c1.0 + 3 * u * t * t * c2.0 + pow(t, 3) * p2.0,
                              pow(u, 3) * p1.1 + 3 * u * u * t * c1.1 + 3 * u * t * t * c2.1 + pow(t, 3) * p2.1))
            }
        }
        return (d + "Z", dense)
    }

    // MARK: Faces (`parts.ts:65-111`)

    struct Paint { var ink: String; var accent: String; var light: String; var deep: String; var paper: String }
    static let heart = "M0 .8C-.6 .4-1 0-1-.35C-1-.75-.55-.95-.25-.8C-.1-.72 0-.6 0-.5C0-.6 .1-.72 .25-.8C.55-.95 1-.75 1-.35C1 0 .6 .4 0 .8Z"
    static let spark = "M0-1Q.14-.14 1 0Q.14 .14 0 1Q-.14 .14-1 0Q-.14-.14 0-1Z"
    static let left: Point = (-115, 31), right: Point = (162, -18)

    static func iconEyes(_ c: Paint) -> String {
        "<g transform=\"translate(-595 -534)\"><path d=\"M553 556a73 111-7 1 1-145 18 73 111-7 1 1 145-18z\" fill=\"\(c.accent)\"/><path d=\"M454 458a73 111-7 0 1 97 90 260 260 0 0 1-97-90z\" fill=\"\(c.light)\"/><path d=\"M554 584a73 111-7 1 1-142-70 73 111-7 0 0 142 70z\" fill=\"\(c.deep)\"/><ellipse cx=\"446\" cy=\"516\" rx=\"25\" ry=\"31\" fill=\"#FFF\"/><ellipse cx=\"480\" cy=\"554\" rx=\"10\" ry=\"11\" fill=\"#FFF\"/><ellipse cx=\"533\" cy=\"614\" rx=\"10\" ry=\"11\" fill=\"#FFF\"/><path d=\"M817 509a60 110-7 1 1-120 14 60 110-7 1 1 120-14z\" fill=\"\(c.accent)\"/><path d=\"M730 412a60 110-7 0 1 85 86 240 240 0 0 1-85-86z\" fill=\"\(c.light)\"/><path d=\"M818 543a60 110-7 1 1-117-86 60 110-7 0 0 117 86z\" fill=\"\(c.deep)\"/><ellipse cx=\"730\" cy=\"466\" rx=\"22\" ry=\"29\" fill=\"#FFF\"/><ellipse cx=\"763\" cy=\"504\" rx=\"9\" ry=\"10\" fill=\"#FFF\"/><ellipse cx=\"801\" cy=\"568\" rx=\"10\" ry=\"11\" fill=\"#FFF\"/></g>"
    }

    static func faceMarkup(_ face: String, _ c: Paint, _ id: String) -> String {
        var serial = 0
        /// A glossy gem cut to any outline: a deep underside, a light cap, and three specks, as the icon's eyes.
        func gem(_ at: Point, _ k: Double, _ shape: String, _ w: Double, _ h: Double, _ paint: Paint? = nil,
                 _ specks: Bool = true, _ lid: Double? = nil) -> String {
            let paint = paint ?? c
            let clip = "\(id)e\(serial)"
            serial += 1
            let cut = lid.map { "<clipPath id=\"\(clip)l\"><path d=\"M-200 \(js(-28 - $0 * 200))L200 \(js(-28 + $0 * 200))V300H-200Z\"/></clipPath>" } ?? ""
            var out = "<g transform=\"translate(\(js(at.0)) \(js(at.1))) rotate(-7) scale(\(js(k)))\">\(cut)<g\(lid == nil ? "" : " clip-path=\"url(#\(clip)l)\"")><clipPath id=\"\(clip)\">\(shape)</clipPath><g clip-path=\"url(#\(clip))\"><rect x=\"\(js(-w - 20))\" y=\"\(js(-h - 20))\" width=\"\(js(2 * w + 40))\" height=\"\(js(2 * h + 40))\" fill=\"\(paint.deep)\"/><g transform=\"translate(\(n(w * 0.14)) \(n(-h * 0.16)))\" fill=\"\(paint.accent)\">\(shape)</g><path d=\"M\(js(-w * 0.4)) \(js(-h - 20))H\(js(w + 20))V\(js(h * 0.3))A\(js(w * 3.2)) \(js(w * 3.2)) 0 0 1 \(js(-w * 0.4)) \(js(-h - 20))Z\" fill=\"\(paint.light)\"/></g>"
            if specks {
                out += "<ellipse cx=\"\(n(-w * 0.42))\" cy=\"\(n(-h * 0.42))\" rx=\"\(n(min(w, h) * 0.32))\" ry=\"\(n(min(w, h) * 0.4))\" fill=\"#FFF\"/><circle cx=\"\(n(w * 0.02))\" cy=\"\(n(-h * 0.08))\" r=\"\(n(max(7, w * 0.13)))\" fill=\"#FFF\"/><circle cx=\"\(n(w * 0.5))\" cy=\"\(n(h * 0.45))\" r=\"\(n(max(7, w * 0.13)))\" fill=\"#FFF\"/>"
            }
            out += "</g>"
            if let lid { out += "<path d=\"M-92 \(n(-28 - lid * 92))L92 \(n(-28 + lid * 92))\" stroke=\"\(paint.light)\" stroke-width=\"13\" stroke-linecap=\"round\"/>" }
            return out + "</g>"
        }
        func oval(_ rx: Double, _ ry: Double) -> String { "<ellipse rx=\"\(js(rx))\" ry=\"\(js(ry))\"/>" }
        func both(_ draw: (Point, Double) -> String) -> String { draw(left, 1) + draw(right, 0.86) }
        /// A lit line: the gem's three tones as a stroke.
        func glow(_ at: Point, _ k: Double, _ d: String, _ w: Double = 36) -> String {
            "<g transform=\"translate(\(js(at.0)) \(js(at.1))) rotate(-7) scale(\(js(k)))\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"\(d)\" stroke=\"\(c.deep)\" stroke-width=\"\(js(w))\"/><path d=\"\(d)\" transform=\"translate(3 -6)\" stroke=\"\(c.accent)\" stroke-width=\"\(js(w - 10))\"/><path d=\"\(d)\" transform=\"translate(5 -11)\" stroke=\"\(c.light)\" stroke-width=\"\(n(w * 0.22))\" stroke-dasharray=\"\(js(w * 1.6)) 999\"/></g>"
        }
        var pinkish = c
        pinkish.accent = "#FF5C93"; pinkish.light = "#FFC2D6"; pinkish.deep = "#C92C62"
        switch face {
        case "visor": return iconEyes(c)
        case "pill": return both { gem($0, $1, oval(50, 104), 50, 104) }
        case "dots": return both { gem($0, $1, oval(62, 62), 62, 62) }
        case "surprised": return both { gem($0, $1, oval(86, 100), 86, 100) }
        case "happy": return both { glow($0, $1, "M-70 38Q0 -96 70 38", 48) }
        case "content": return both { glow($0, $1, "M-70 -30Q0 92 70 -30", 48) }
        case "sleepy":
            return both { glow($0, $1, "M-66 10H66", 44) }
                + "<path d=\"M196 -150h42l-42 46h42\" fill=\"none\" stroke=\"\(c.light)\" stroke-width=\"11\" stroke-linecap=\"round\" stroke-linejoin=\"round\" transform=\"rotate(-7)\"/>"
        case "wink": return gem(left, 1, oval(62, 100), 62, 100) + glow(right, 0.86, "M-70 38Q0 -96 70 38", 48)
        case "bars": return both { gem($0, $1, "<rect x=\"-36\" y=\"-100\" width=\"72\" height=\"200\" rx=\"34\"/>", 36, 100) }
        case "side": return both { at, k in gem((at.0 + 34, at.1 - 6), k, oval(58, 98), 58, 98) }
        case "angry": return gem(left, 1, oval(70, 96), 70, 96, c, true, 0.3) + gem(right, 0.86, oval(70, 96), 70, 96, c, true, -0.3)
        case "worried": return gem(left, 1, oval(70, 96), 70, 96, c, true, -0.26) + gem(right, 0.86, oval(70, 96), 70, 96, c, true, 0.26)
        case "heart": return both { gem($0, $1, "<path transform=\"scale(88 98)\" d=\"\(heart)\"/>", 88, 92, pinkish) }
        case "sparkle":
            return both { at, k in
                gem(at, k, "<path transform=\"scale(84 112)\" d=\"\(spark)\"/>", 84, 112, c, false)
                    + "<circle cx=\"\(js(at.0 - 16 * k))\" cy=\"\(js(at.1 - 22 * k))\" r=\"\(js(12 * k))\" fill=\"#FFF\"/>"
            }
        case "dizzy": return both { glow($0, $1, "M-56 -56L56 56M56 -56L-56 56", 42) }
        default:
            return glow((22, 8), 1, "M-200 0H200", 62)
                + "<path d=\"M-150 -6h120\" transform=\"rotate(-7)\" stroke=\"#FFF\" stroke-width=\"12\" stroke-linecap=\"round\"/>"
        }
    }

    static func mouthMarkup(_ mouth: String, _ c: Paint) -> String {
        func lit(_ d: String) -> String {
            "<g transform=\"translate(26 112) rotate(-7)\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"\(d)\" stroke=\"\(c.deep)\" stroke-width=\"19\"/><path d=\"\(d)\" transform=\"translate(1 -3)\" stroke=\"\(c.light)\" stroke-width=\"11\"/></g>"
        }
        switch mouth {
        case "smile": return lit("M-34 -8Q0 24 34 -8")
        case "open": return "<g transform=\"translate(26 116) rotate(-7)\"><ellipse rx=\"20\" ry=\"24\" fill=\"\(c.deep)\"/><ellipse cx=\"2\" cy=\"-4\" rx=\"14\" ry=\"17\" fill=\"\(c.light)\"/></g>"
        case "cat": return lit("M-40 -8Q-20 22 0 -6Q20 22 40 -8")
        case "grille": return lit("M-36 -12V14M-12 -12V14M12 -12V14M36 -12V14")
        default: return ""
        }
    }

    // MARK: Robot (`robot.ts`)

    private static func turned(_ a: Double, _ b: Double) -> Double {
        abs(((a - b).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
    private static func degrees(_ t: Double) -> Double { t * 180 / Double.pi }

    /// A round head with two pointed ears.
    private static func eared() -> [Point] {
        around(96) { t in
            let a = degrees(t), ear = max(0, 1 - min(turned(a, -134), turned(a, -46)) / 21)
            return (cos(t) * (1 + 0.46 * ear) * 1.06, sin(t) * (0.86 + 0.6 * ear) + 0.1)
        }
    }
    private static func corners(_ list: [Point], _ cut: Double) -> [Point] {
        list.enumerated().flatMap { i, p -> [Point] in
            let a = list[(i + list.count - 1) % list.count], b = list[(i + 1) % list.count]
            return [(p.0 + (a.0 - p.0) * cut, p.1 + (a.1 - p.1) * cut), (p.0 + (b.0 - p.0) * cut, p.1 + (b.1 - p.1) * cut)]
        }
    }

    struct Model: Sendable {
        var points: @Sendable () -> [Point]
        var size: Double
        var at: Point
        var eyes: (Double, Double)
        var up: Point? = nil
        var tilt: Double? = nil
        var soft = false
    }

    static let models: [String: Model] = [
        "blob": Model(points: {
            around(40) { t in
                let r = 1 + 0.04 * sin(2 * t + 1.3) + 0.025 * sin(3 * t + 0.4)
                return (r * cos(t) * 1.12, r * sin(t) * 0.92)
            }
        }, size: 0.86, at: (522, 486), eyes: (0.14, 0.78), soft: true),
        "puff": Model(points: { superellipse(1.1, 0.86, 0.42, 48) }, size: 0.86, at: (522, 506), eyes: (0.1, 0.8)),
        "pebble": Model(points: { superellipse(1.2, 0.72, 0.6, 48) }, size: 0.86, at: (522, 548), eyes: (0.04, 0.78)),
        "shield": Model(points: { superellipse(1, 0.88, 0.4, 48).map { ($0.0 * (1 - 0.17 * $0.1), $0.1) } },
                        size: 0.88, at: (522, 500), eyes: (0.02, 0.78)),
        "diamond": Model(points: { corners(around(6) { t in (cos(t + Double.pi / 2) * 1.08, sin(t + Double.pi / 2) * 0.98) }, 0.22) },
                         size: 0.9, at: (522, 478), eyes: (0.06, 0.78)),
        "cat": Model(points: eared, size: 0.8, at: (522, 526), eyes: (0.22, 0.78), up: (0, -1)),
        "ghost": Model(points: {
            (0..<9).map { i -> Point in
                let t = Double.pi + Double(i) / 8 * Double.pi
                return (cos(t) * 0.9, sin(t) * 0.88 - 0.12)
            } + [(0.92, 0.35), (0.92, 0.86), (0.61, 0.66), (0.3, 0.9), (0, 0.7), (-0.3, 0.9), (-0.61, 0.66), (-0.92, 0.86), (-0.92, 0.35)]
        }, size: 0.86, at: (522, 510), eyes: (-0.1, 0.78), tilt: -3),
        "cloud": Model(points: cloud, size: 0.94, at: (506, 524), eyes: (0.2, 0.7), tilt: 0, soft: true),
        "heart": Model(points: {
            around(48) { t in
                let u = t + Double.pi / 2
                return (pow(sin(u), 3) * 1.08, -(13 * cos(u) - 5 * cos(2 * u) - 2 * cos(3 * u) - cos(4 * u)) / 16 + 0.1)
            }
        }, size: 0.9, at: (522, 474), eyes: (-0.22, 0.7), tilt: 0),
        "star": Model(points: {
            around(10) { t in
                let r = Int(round((t + Double.pi / 2) / tau * 10)) % 2 != 0 ? 0.66 : 1.1
                return (cos(t) * r, sin(t) * r + 0.06)
            }
        }, size: 0.86, at: (522, 548), eyes: (0.14, 0.78), tilt: 0),
        "drop": Model(points: {
            [(0, -1.04), (0.3, -0.62), (0.7, -0.1), (0.86, 0.36), (0.64, 0.8), (0, 0.98), (-0.64, 0.8), (-0.86, 0.36), (-0.7, -0.1), (-0.3, -0.62)]
        }, size: 0.8, at: (522, 540), eyes: (0.36, 0.8), tilt: 0),
    ]

    struct Geometry: Sendable {
        var d: String
        var inset: String
        var lights: String
        var antenna: Point
        var antenna2: Point
        var ear: Point
        var tuft: String
        var at: Point
        var k: Double
    }
    static let domeGeometry = Geometry(d: dome, inset: dome, lights: domeLights, antenna: (0, 0), antenna2: (742, 262), ear: (0, 0),
                                       tuft: "", at: (595, 534), k: 1)
    private static let geometryCache = GeometryCache()
    private final class GeometryCache: @unchecked Sendable {
        let lock = NSLock()
        var map: [String: Geometry] = [:]
    }

    static func geometry(_ shape: String, seed: Int) -> Geometry {
        guard let model = models[shape] else { return domeGeometry }
        let key = "\(shape):\(model.soft ? seed : 0)"
        geometryCache.lock.lock()
        if let hit = geometryCache.map[key] { geometryCache.lock.unlock(); return hit }
        geometryCache.lock.unlock()
        let r = 370 * model.size, (cx, cy) = model.at, tilt = (model.tilt ?? -5) * Double.pi / 180
        func turn(_ p: Point) -> Point { (p.0 * cos(tilt) - p.1 * sin(tilt), p.0 * sin(tilt) + p.1 * cos(tilt)) }
        var flat = model.points()
        if model.soft { flat = wobble(flat, seed: seed, amount: 0.02) }
        // The visor takes the head's width where the eyes sit.
        let outline = spline(flat).dense
        let across = outline.filter { abs($0.1 - model.eyes.0) < 0.1 }.map(\.0)
        let left = across.min() ?? 0, right = across.max() ?? 0
        let tall = (outline.map(\.1).max() ?? 0) - (outline.map(\.1).min() ?? 0)
        let k = min((right - left) * r * model.eyes.1 / 564, tall * r * 0.6 / 344)
        let eye = turn((right - (right - left) * 0.035 - 564 * k / r / 2, model.eyes.0))
        let unit = flat.map(turn)
        let (d, dense) = spline(unit.map { (cx + $0.0 * r, cy + $0.1 * r) })
        func pull(_ p: Point, _ by: Double) -> Point {
            let dx = p.0 - cx, dy = p.1 - cy
            var len = (dx * dx + dy * dy).squareRoot()
            if len == 0 { len = 1 }
            return (p.0 - dx / len * by, p.1 - dy / len * by)
        }
        func bearing(_ p: Point) -> Double { degrees(atan2(p.1 - cy, p.0 - cx)) }
        /// A tapered white cut just inside the edge, between two bearings (0 = right, -90 = top).
        func crescent(_ from: Double, _ to: Double, _ gap: Double, _ thick: Double) -> String {
            struct Spot { var i: Int; var p: Point; var a: Double }
            var span: [Spot] = []
            for (i, p) in dense.enumerated() {
                let turned: Double = (bearing(p) - from).truncatingRemainder(dividingBy: 360) + 360
                let a = turned.truncatingRemainder(dividingBy: 360)
                if a <= to - from { span.append(Spot(i: i, p: p, a: a)) }
            }
            span.sort { $0.a != $1.a ? $0.a < $1.a : $0.i < $1.i }
            if span.count < 3 { return "" }
            let outer: [Point] = span.map { pull($0.p, gap) }
            var inner: [Point] = []
            for (i, o) in span.enumerated() {
                let swell: Double = pow(max(0, sin(Double.pi * Double(i) / Double(span.count - 1))), 0.6)
                inner.append(pull(o.p, gap + thick * swell))
            }
            let all: [Point] = outer + inner.reversed()
            return "M" + all.map { (p: Point) -> String in "\(n(p.0)) \(n(p.1))" }.joined(separator: "L") + "Z"
        }
        let lights = crescent(-182, -132, 26, 26) + crescent(-172, -140, 66, 16) + crescent(-100, -66, 30, 15)
            + crescent(-54, -8, 26, 28) + crescent(18, 54, 22, 14) + crescent(70, 112, 40, 9)
        func furthest(_ dx: Double, _ dy: Double) -> Point {
            dense.dropFirst().reduce(dense[0]) { best, p in
                (p.0 - cx) * dx + (p.1 - cy) * dy > (best.0 - cx) * dx + (best.1 - cy) * dy ? p : best
            }
        }
        let up = model.up ?? (-0.42, -0.9)
        let top = pull(furthest(up.0, up.1), 26)
        let negated = -up.0
        let top2 = pull(furthest(negated == 0 ? 0.42 : negated, up.1), 26), side = furthest(-1, 0.25)
        let brow = furthest(-0.34, -0.94)
        let result = Geometry(
            d: d, inset: spline(unit.map { (cx + $0.0 * (r - 24), cy + $0.1 * (r - 24)) }).d, lights: lights,
            antenna: (top.0 - 362, top.1 - 268), antenna2: top2, ear: (side.0 + 44 - 207, side.1 - 598),
            tuft: "translate(\(n(brow.0 + 6)) \(n(brow.1 + 60))) scale(\(js(round(model.size * 100) / 100))) translate(-392 -262)",
            at: (cx + eye.0 * r, cy + eye.1 * r), k: k)
        geometryCache.lock.lock()
        geometryCache.map[key] = result
        geometryCache.lock.unlock()
        return result
    }

    /// The glass the eyes sit behind, around 0,0 at the icon's size. `line` keeps the keyline's weight.
    static func visorMarkup(_ kind: String, _ tone: Tone, _ line: Double, _ id: String) -> String {
        let key = "fill=\"\(ink)\" stroke=\"#FFF\" stroke-width=\"\(js(line))\""
        if kind == "goggles" {
            func lens(_ at: Point, _ rx: Double, _ ry: Double) -> String {
                "<g transform=\"translate(\(js(at.0)) \(js(at.1))) rotate(-7)\"><ellipse rx=\"\(js(rx + 22))\" ry=\"\(js(ry + 22))\" \(key)/><ellipse rx=\"\(js(rx))\" ry=\"\(js(ry))\" fill=\"\(tone.deep)\" opacity=\".36\"/><ellipse rx=\"\(js(rx))\" ry=\"\(js(ry))\" fill=\"none\" stroke=\"#FFF\" stroke-width=\"\(n(line * 0.7))\" opacity=\".55\"/><path d=\"M\(js(-rx * 0.8)) \(js(-ry * 0.2))A\(js(rx)) \(js(ry)) 0 0 1 \(js(-rx * 0.1)) \(js(-ry * 0.92))\" fill=\"none\" stroke=\"#FFF\" stroke-width=\"\(js(line * 1.4))\" stroke-linecap=\"round\" opacity=\".5\"/></g>"
            }
            return "<path d=\"M\(js(left.0)) \(js(left.1))L\(js(right.0)) \(js(right.1))\" stroke=\"#FFF\" stroke-width=\"\(js(46 + line * 2))\"/><path d=\"M\(js(left.0)) \(js(left.1))L\(js(right.0)) \(js(right.1))\" stroke=\"\(ink)\" stroke-width=\"46\"/>"
                + lens(left, 104, 132) + lens(right, 90, 116)
        }
        if kind == "screen" {
            return "<g transform=\"rotate(-7)\"><rect x=\"-272\" y=\"-164\" width=\"544\" height=\"328\" rx=\"78\" \(key)/><rect x=\"-246\" y=\"-138\" width=\"492\" height=\"276\" rx=\"54\" fill=\"\(tone.deep)\" opacity=\".4\"/><path d=\"M-246 -30L-96 -138H24L-246 60Z\" fill=\"#FFF\" opacity=\".1\"/></g>"
        }
        if kind == "none" { return "" }
        return "<g transform=\"translate(-595 -534)\"><clipPath id=\"\(id)g\"><path d=\"\(visor)\"/></clipPath><path d=\"\(visor)\" fill=\"\(ink)\"/><path d=\"M300 560L640 330H760L300 650Z\" fill=\"#FFF\" opacity=\".08\" clip-path=\"url(#\(id)g)\"/><path d=\"\(visor)\" fill=\"none\" stroke=\"#FFF\" stroke-width=\"\(js(line))\"/></g>"
    }

    static let chromeTop = "#FFFFFF", chromeMid = "#C9D0DA", chromeLow = "#7C8592"

    /// Just the robot (no tile), for the tile to be put behind. A finished bot smiles; one that can't be reached sleeps.
    static func robotMarkup(_ head: HeadRecord, _ tone: Tone, state: HeadState?, id: String) -> String {
        let geo = geometry(head.shape, seed: head.seed), isDome = models[head.shape] == nil
        let paint = Paint(ink: ink, accent: tone.accent, light: tone.light, deep: tone.deep, paper: tone.panel)
        func moved(_ by: Point, _ inner: String) -> String {
            by.0 != 0 || by.1 != 0 ? "<g transform=\"translate(\(n(by.0)) \(n(by.1)))\">\(inner)</g>" : inner
        }
        // The shell: ink like the icon, painted in the bot's colour (all of it, or just the head), or chrome.
        let painted = head.shell != "ink", chrome = head.shell == "chrome"
        let skin = chrome ? "url(#\(id)m)" : tone.accent, under = chrome ? chromeLow : tone.deep
        let coat = painted && head.shell != "duo" ? skin : ink
        var defs = "<clipPath id=\"\(id)n\"><rect y=\"700\" width=\"1024\" height=\"92\"/></clipPath>"
        if chrome {
            defs += "<linearGradient id=\"\(id)m\" x1=\".2\" y1=\"0\" x2=\".7\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(chromeTop)\"/><stop offset=\".5\" stop-color=\"\(chromeMid)\"/><stop offset=\"1\" stop-color=\"\(chromeLow)\"/></linearGradient>"
        }
        if painted { defs += "<clipPath id=\"\(id)s\"><path d=\"\(geo.d)\"/></clipPath>" }
        let edge = "stroke=\"\(ink)\" stroke-width=\"14\" stroke-linejoin=\"round\""
        let skull = painted
            ? "<path d=\"\(geo.d)\" fill=\"\(under)\" \(edge)/><g clip-path=\"url(#\(id)s)\"><path d=\"\(geo.d)\" fill=\"\(skin)\" transform=\"translate(-22 -28)\"/></g><path d=\"\(geo.d)\" fill=\"none\" \(edge)/>"
            : "<path d=\"\(geo.d)\" fill=\"\(ink)\"/>"
        func torso(_ clip: String) -> String {
            "<path d=\"\(clip.isEmpty ? shoulders + neck : neck)\" fill=\"\(coat)\"\(coat == ink ? "" : " \(edge)")\(clip)/>"
        }

        // On top: the icon's bulb, two of them, a bolt, or a halo.
        let stem = "M284 160q56 26 78 108", bolt = "M286 56L384 150L338 164L392 276L282 172L330 158Z"
        let kinds: [String: (String, String)] = [
            "bulb": (
                "<path d=\"\(stem)\" fill=\"none\" stroke=\"\(tone.panel)\" stroke-width=\"56\" stroke-linecap=\"round\"/><circle cx=\"270\" cy=\"147\" r=\"62\" fill=\"\(tone.panel)\"/>",
                "<path d=\"\(stem)\" fill=\"none\" stroke=\"\(ink)\" stroke-width=\"40\" stroke-linecap=\"round\"/><path d=\"M322 181q30 19 46 63\" fill=\"none\" stroke=\"#FFF\" stroke-width=\"9\" stroke-linecap=\"round\"/><circle cx=\"270\" cy=\"147\" r=\"54\" fill=\"\(ink)\"/><g class=\"dh-bulb\"><circle cx=\"270\" cy=\"147\" r=\"42\" fill=\"\(tone.accent)\"/><path d=\"M306 168a42 42 0 0 1-72 0a60 60 0 0 0 72 0z\" fill=\"\(tone.deep)\"/><circle cx=\"254\" cy=\"130\" r=\"11\" fill=\"#FFF\"/></g>"
            ),
            "bolt": (
                "<path d=\"\(bolt)\" fill=\"\(tone.panel)\" stroke=\"\(tone.panel)\" stroke-width=\"44\" stroke-linejoin=\"round\"/>",
                "<path d=\"\(bolt)\" fill=\"\(ink)\" stroke=\"\(ink)\" stroke-width=\"28\" stroke-linejoin=\"round\"/><g class=\"dh-bulb\"><path d=\"\(bolt)\" fill=\"\(tone.accent)\"/><path d=\"M286 56L384 150L338 164L310 110Z\" fill=\"\(tone.light)\"/></g>"
            ),
            "ring": (
                "<ellipse cx=\"400\" cy=\"168\" rx=\"150\" ry=\"44\" transform=\"rotate(-9 400 168)\" fill=\"none\" stroke=\"\(tone.panel)\" stroke-width=\"58\"/>",
                "<g transform=\"rotate(-9 400 168)\" fill=\"none\"><ellipse cx=\"400\" cy=\"168\" rx=\"150\" ry=\"44\" stroke=\"\(ink)\" stroke-width=\"42\"/><g class=\"dh-bulb\"><ellipse cx=\"400\" cy=\"168\" rx=\"150\" ry=\"44\" stroke=\"\(tone.accent)\" stroke-width=\"22\"/><path d=\"M262 150a150 44 0 0 1 150-26\" stroke=\"\(tone.light)\" stroke-width=\"9\" stroke-linecap=\"round\"/></g></g>"
            ),
        ]
        let kind = kinds[head.antenna == "twin" ? "bulb" : head.antenna]
        func second(_ inner: String) -> String {
            head.antenna == "twin"
                ? "<g transform=\"translate(\(n(geo.antenna2.0 + 362 * 0.8)) \(n(geo.antenna2.1 - 268 * 0.8))) scale(-.8 .8)\">\(inner)</g>" : ""
        }
        // A halo floats over the crown, so it is drawn over the head; the rest grow from behind it.
        let floats = head.antenna == "ring"
        let antennaHalo = kind.map { moved(geo.antenna, $0.0) + second($0.0) } ?? ""
        let antenna = kind.map { moved(geo.antenna, $0.1) + second($0.1) } ?? ""

        // At the near ear: the icon's headset, a bolt, or a fin.
        let ears: [String: String] = [
            "headset": "<path d=\"M246 594a58 95-4 1 1-116 8 58 95-4 1 1 116-8zm27 6a66 109 2 1 1-132-4 66 109 2 1 1 132 4z\" fill=\"\(tone.panel)\" stroke=\"\(tone.panel)\" stroke-width=\"16\" stroke-linejoin=\"round\"/><path d=\"M273 600a66 109 2 1 1-132-4 66 109 2 1 1 132 4z\" fill=\"\(ink)\"/><path d=\"M246 594a58 95-4 1 1-116 8 58 95-4 1 1 116-8z\" fill=\"\(ink)\"/><path d=\"M148 539a51 88-4 1 1 61 142 51 88-4 0 0-61-142z\" fill=\"#FFF\"/>",
            "bolts": "<g transform=\"rotate(-6 190 600)\"><rect x=\"118\" y=\"548\" width=\"112\" height=\"104\" rx=\"26\" fill=\"\(tone.panel)\" stroke=\"\(tone.panel)\" stroke-width=\"16\"/><rect x=\"118\" y=\"548\" width=\"112\" height=\"104\" rx=\"26\" fill=\"\(ink)\"/><rect x=\"96\" y=\"574\" width=\"46\" height=\"52\" rx=\"14\" fill=\"\(ink)\" stroke=\"\(tone.panel)\" stroke-width=\"8\"/><path d=\"M158 566v68M186 566v68\" stroke=\"#FFF\" stroke-width=\"9\" stroke-linecap=\"round\"/><circle cx=\"119\" cy=\"600\" r=\"9\" fill=\"\(tone.accent)\"/></g>",
            "fins": "<path d=\"M236 520L74 452Q116 596 226 676Z\" fill=\"\(tone.panel)\" stroke=\"\(tone.panel)\" stroke-width=\"30\" stroke-linejoin=\"round\"/><path d=\"M236 520L74 452Q116 596 226 676Z\" fill=\"\(ink)\" stroke=\"\(ink)\" stroke-width=\"12\" stroke-linejoin=\"round\"/><path d=\"M214 532L112 490Q140 572 206 636Z\" fill=\"\(tone.accent)\"/><path d=\"M196 528L118 494Q128 528 150 560Z\" fill=\"\(tone.light)\"/>",
        ]
        let ear = ears[head.ears].map { moved(geo.ear, $0) } ?? ""
        let soft = painted ? " opacity=\".85\"" : ""
        let lights = isDome
            ? "<path d=\"\(tuft)\(geo.lights)\" fill=\"#FFF\"\(soft)/>"
            : "<clipPath id=\"\(id)h\"><path d=\"\(geo.inset)\"/></clipPath><path d=\"\(geo.lights)\" fill=\"#FFF\"\(soft)/><g clip-path=\"url(#\(id)h)\"\(soft)><path d=\"\(tuft)\" transform=\"\(geo.tuft)\" fill=\"#FFF\"/></g>"
        let blush = head.blush
            ? "<g fill=\"#FF7FA8\" transform=\"rotate(-7)\"><ellipse cx=\"-222\" cy=\"104\" rx=\"30\" ry=\"17\"/><ellipse cx=\"258\" cy=\"104\" rx=\"24\" ry=\"15\"/></g>" : ""
        let eyes = state == .done ? "happy" : state == .offline ? "sleepy" : head.face
        let opener = isDome ? "<g>" : "<clipPath id=\"\(id)v\"><path d=\"\(geo.d)\"/></clipPath><g clip-path=\"url(#\(id)v)\">"
        let face = opener + "<g transform=\"translate(\(n(geo.at.0)) \(n(geo.at.1))) scale(\(js(round(geo.k * 100) / 100)))\">"
            + visorMarkup(eyes == "scanner" && head.visor == "goggles" ? "band" : head.visor, tone, round(8 / geo.k * 1.15), id)
            + "<g class=\"dh-face\">\(faceMarkup(eyes, paint, id))</g>\(mouthMarkup(head.mouth, paint))\(blush)</g></g>"
        return defs + torso("") + "<path d=\"\(shoulderLights)\" fill=\"#FFF\"\(painted && head.shell != "duo" ? " opacity=\".8\"" : "")/>"
            + "<g class=\"dh-body\">\(floats ? "" : antennaHalo)<path d=\"\(geo.d)\" fill=\"\(tone.panel)\" stroke=\"\(tone.panel)\" stroke-width=\"\(painted ? 30 : 16)\" stroke-linejoin=\"round\"/>\(floats ? "" : antenna)"
            + torso(" clip-path=\"url(#\(id)n)\"") + skull
            + "<path d=\"\(neckLightA)\" fill=\"\(coat == ink ? tone.panel : "#FFF")\"/><path d=\"\(neckLightB)\" fill=\"#FFF\"/>\(lights)\(ear)\(face)\(floats ? antennaHalo + antenna : "")</g>"
    }

    // MARK: Tiles (`render.ts:29-37`)

    struct Made { var frame: String; var panel: String; var defs = ""; var body: String }
    struct Ground { var frame: String; var panel: String; var mark: String; var dark: Bool; var defs: String }

    static func ground(_ head: HeadRecord, _ tone: Tone, _ id: String) -> Ground {
        if head.tile == "light" { return Ground(frame: ink, panel: "#F7F5F0", mark: ink, dark: false, defs: "") }
        if head.tile == "color" { return Ground(frame: ink, panel: tone.panel, mark: ink, dark: false, defs: "") }
        return Ground(frame: "#000", panel: "url(#\(id)k)", mark: "#FFFFFF", dark: true,
                      defs: "<radialGradient id=\"\(id)k\" cx=\".5\" cy=\".12\" r=\"1\"><stop offset=\"0\" stop-color=\"#2B2B33\"/><stop offset=\".6\" stop-color=\"#121216\"/><stop offset=\"1\" stop-color=\"#08080A\"/></radialGradient>")
    }

    // MARK: Dots (`render.ts:39-135`)

    static let lampEyes: [String: (String, String)] = [
        "visor": (".........|.1111111.|.1111111.|.........|.........", ".....|11111|....."),
        "pill": (".........|..11.11..|..11.11..|..11.11..|.........", ".....|.1.1.|.1.1."),
        "dots": (".........|.........|..1...1..|.........|.........", ".....|.1.1.|....."),
        "surprised": (".........|.111.111.|.111.111.|.111.111.|.........", "11.11|11.11|....."),
        "happy": (".........|..1...1..|.1.1.1.1.|.........|.........", ".1.1.|1.1.1|....."),
        "content": (".........|.........|.1.1.1.1.|..1...1..|.........", ".....|1.1.1|.1.1."),
        "wink": (".........|..11.....|..11.111.|..11.....|.........", ".....|.1...|.1.11"),
        "sleepy": (".........|.........|.........|.111.111.|.........", ".....|.....|11.11"),
        "bars": (".........|.........|.111.111.|.111.111.|.........", ".....|11.11|....."),
        "side": (".........|.111.111.|...1...1.|...1...1.|.........", "11.11|.1..1|....."),
        "angry": (".........|.1.....1.|.11...11.|.111.111.|.........", "1...1|11.11|....."),
        "worried": (".........|...1.1...|..11.11..|.111.111.|.........", ".1.1.|11.11|....."),
        "heart": (".........|.4.4.4.4.|.444.444.|..4...4..|.........", "4.4.4|44444|.4.4."),
        "sparkle": (".........|..1...1..|.111.111.|..1...1..|.........", ".1.1.|11111|.1.1."),
        "dizzy": (".........|.1.1.1.1.|..1...1..|.1.1.1.1.|.........", "1.1.1|.1.1.|1.1.1"),
        "scanner": (".........|.........|.2212222.|.........|.........", ".....|22122|....."),
    ]
    static let lampMouths: [String: (String, String)] = [
        "none": (".........|.........", ".....|....."),
        "smile": ("..2...2..|...222...", "2...2|.222."),
        "open": ("...222...|...222...", ".222.|.222."),
        "cat": (".2.2.2.2.|..2.2.2..", "2.2.2|.2.2."),
        "grille": ("...222...|.........", ".222.|....."),
    ]

    private struct Lamp { var v = 0.0; var hot = false; var hole = false; var pink = false }

    static func dots(_ head: HeadRecord, _ tone: Tone, _ id: String, compact: Bool, state: HeadState?) -> Made {
        let small = compact, grid = small ? 5 : 9, pitch = small ? 158.0 : 86.0, mid = Double(grid - 1) / 2, step = small ? 2.0 : 1.0
        let g = ground(head, tone, id)
        var random = SeededRandom(seed: UInt32(truncatingIfNeeded: head.seed))
        let phase = random.next() * tau, twist = random.next()
        let plain = head.color == "ink" || head.color == "paper"
        let accent = plain ? g.mark : g.dark ? tone.accent : tone.deep
        var lamp = Array(repeating: Array(repeating: Lamp(), count: grid), count: grid)
        func each(_ set: (Double, Double, Double, Double) -> (Double, Bool)) {
            for row in 0..<grid {
                for col in 0..<grid {
                    let x = (Double(col) - mid) * step, y = (Double(row) - mid) * step
                    let (v, hot) = set(x, y, (x * x + y * y).squareRoot(), atan2(y, x))
                    lamp[row][col].v = max(0, min(1, v)); lamp[row][col].hot = hot
                }
            }
        }
        let face = head.eyes && (head.pattern == "ring" || head.pattern == "bloom")
        switch head.pattern {
        case "grid":
            let ox = (random.next() - 0.5) * 5, oy = (random.next() - 0.5) * 5, reach = 1.5 + twist * 1.6
            each { x, y, _, _ in
                let dx = x - ox, dy = y - oy
                let v = 0.5 + 0.5 * cos((dx * dx + dy * dy).squareRoot() / reach * Double.pi + phase)
                return (0.12 + 0.88 * v, v > 0.86)
            }
        case "bloom":
            let band = 1 + (twist * 3).rounded(.down)
            each { x, y, d, _ in
                (d > 4.4 || (face && abs(x) < 2.5 && abs(y) < 1.5) ? 0 : pow(1 - d / 4.8, 0.7), !face && round(d) == band)
            }
        case "ring":
            each { _, _, d, a in
                let sweep = ((a - phase).truncatingRemainder(dividingBy: tau) + tau).truncatingRemainder(dividingBy: tau) / tau
                let on = exp(-pow((d - (small ? 4 : 3.4)) / (small ? 1.1 : 0.62), 2))
                return (on * (0.22 + 0.78 * sweep), on > 0.5 && sweep > 0.86)
            }
        case "spark":
            // A four-pointed star: the lamps shrink along its arms.
            let sharp = 0.72 + twist * 0.14
            each { x, y, d, _ in
                let v = 1 - (pow(abs(x), sharp) + pow(abs(y), sharp)) / pow(4.4, sharp)
                return (v <= 0 ? 0 : 0.2 + 0.8 * pow(v, 0.8), d < 1.2)
            }
        case "wave":
            each { x, y, _, _ in
                let tall = 0.4 + 3.6 * abs(sin(x * (0.6 + twist * 0.5) + phase)) * (1 - abs(x) * 0.1)
                return (abs(y) <= tall ? 1 - abs(y) * 0.13 : 0, x == 0)
            }
        default:
            // A face: the head's eyes over its mouth, with pink cheeks when it blushes.
            func part(_ table: [String: (String, String)], _ key: String) -> [String] {
                let entry = table[key] ?? table.values.first!
                return (small ? entry.1 : entry.0).split(separator: "|").map(String.init)
            }
            var rows = small ? part(lampEyes, head.face) + part(lampMouths, head.mouth)
                : ["........."] + part(lampEyes, head.face) + part(lampMouths, head.mouth) + ["........."]
            if head.blush {
                for col in small ? [0, 4] : [1, 7] {
                    let row = small ? 2 : 5
                    var chars = Array(rows[row])
                    if chars[col] == "." { chars[col] = "3"; rows[row] = String(chars) }
                }
            }
            for row in 0..<grid {
                let chars = Array(rows[row])
                for col in 0..<grid {
                    let mark = chars[col]
                    lamp[row][col].v = mark == "." ? 0 : mark == "2" ? 0.62 : mark == "3" ? 0.5 : 1
                    lamp[row][col].hot = mark == "1" || mark == "4"
                    lamp[row][col].pink = mark > "2"
                }
            }
        }
        let eyeRows = small ? [2] : [3, 4]
        if face { for col in small ? [1, 3] : [3, 5] { for row in eyeRows { lamp[row][col].hole = true } } }
        let moving = state == .thinking || state == .speaking
        var dim = "", lit = "", hot = "", cheek = "", love = ""
        for row in 0..<grid {
            for col in 0..<grid {
                let cell = lamp[row][col]
                let x = 512 + (Double(col) - mid) * pitch, y = 512 + (Double(row) - mid) * pitch
                if cell.hole {
                    if row == eyeRows[0] {
                        hot += "<rect x=\"\(js(x - pitch * 0.32))\" y=\"\(js(y - pitch * 0.32))\" width=\"\(js(n1(pitch * 0.64)))\" height=\"\(js(n1(pitch * Double(eyeRows.count - 1) + pitch * 0.64)))\" rx=\"\(js(n1(pitch * 0.32)))\"/>"
                    }
                    continue
                }
                if cell.v < 0.06 { dim += "<circle cx=\"\(js(x))\" cy=\"\(js(y))\" r=\"\(js(n1(pitch * 0.08)))\"/>"; continue }
                // A thinking matrix ripples outward and a speaking one rises by column: each lamp knows its place.
                let place: String
                if !moving { place = "" } else if state == .thinking {
                    let dc = Double(col) - mid, dr = Double(row) - mid
                    place = " style=\"--i:\(js(round((dc * dc + dr * dr).squareRoot() * step)))\""
                } else { place = " style=\"--i:\(col)\"" }
                let dot = "<circle cx=\"\(js(x))\" cy=\"\(js(y))\" r=\"\(js(n1(pitch * (0.15 + 0.26 * cell.v))))\"\(place)/>"
                if cell.pink { if cell.hot { love += dot } else { cheek += dot } } else if cell.hot { hot += dot } else { lit += dot }
            }
        }
        let glow = g.dark && !plain ? "<g fill=\"\(accent)\" filter=\"url(#\(id)g)\" opacity=\".75\">\(hot)</g>" : ""
        var body = "<g fill=\"\(g.mark)\" opacity=\"\(g.dark ? "0.16" : "0.13")\">\(dim)</g><g class=\"dh-lamps\" fill=\"\(g.mark)\">\(lit)</g>\(glow)<g class=\"dh-lamps\(face || head.pattern == "face" ? " dh-face" : "")\" fill=\"\(accent)\">\(hot)</g>"
        if !cheek.isEmpty { body += "<g class=\"dh-lamps\" fill=\"#FF7FA8\">\(cheek)</g>" }
        if !love.isEmpty { body += "<g class=\"dh-lamps dh-face\" fill=\"#FF4D8D\">\(love)</g>" }
        return Made(frame: g.frame, panel: g.panel,
                    defs: g.defs + "<filter id=\"\(id)g\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feGaussianBlur stdDeviation=\"20\"/></filter>",
                    body: body)
    }

    // MARK: Orb (`render.ts:137-166`)

    static let neighbour: [String: [String]] = [
        "ink": ["#2EC4B6", "#4A93FF", "#9479FF"], "mint": ["#1FCFA5", "#4A93FF", "#D7F36B"], "teal": ["#22BCD8", "#9479FF", "#6BF3C8"],
        "sky": ["#4A93FF", "#9479FF", "#22D8C8"], "lilac": ["#9479FF", "#FF66AD", "#4A93FF"], "pink": ["#FF66AD", "#FFA043", "#9479FF"],
        "coral": ["#FF7057", "#FFCE2E", "#FF66AD"], "peach": ["#FFA043", "#FF66AD", "#FFCE2E"], "butter": ["#FFCE2E", "#FF8A3D", "#FFF3A8"],
        "lime": ["#96DB3C", "#22BCD8", "#F2F06B"], "paper": ["#D9D2C2", "#FFFFFF", "#A39A86"],
    ]

    static func orb(_ head: HeadRecord, _ tone: Tone, _ id: String) -> Made {
        // A Shapes head's own colour, carried over to an orb, glows in its own shades.
        let g = ground(head, tone, id)
        var random = SeededRandom(seed: UInt32(truncatingIfNeeded: head.seed))
        let hues = neighbour[head.color] ?? [tone.accent, tone.light, tone.deep]
        var blobs = ""
        // Two broad drifts of the neighbouring colours, placed opposite each other so they never turn to mud.
        let turn = random.next() * tau
        for i in 0..<4 {
            let angle = turn + Double(i) * tau / 4 + (random.next() - 0.5) * 0.8, reach = 150 + random.next() * 130
            let cx = js(n1(512 + cos(angle) * reach)), cy = js(n1(512 + sin(angle) * reach))
            let rx = js(n1(190 + random.next() * 90)), ry = js(n1(140 + random.next() * 70))
            blobs += "<ellipse cx=\"\(cx)\" cy=\"\(cy)\" rx=\"\(rx)\" ry=\"\(ry)\" transform=\"rotate(\(js(n1(random.next() * 180))) 512 512)\" fill=\"\(hues[1 + i % 2])\" opacity=\".9\"/>"
        }
        let defs = g.defs + "<clipPath id=\"\(id)c\"><circle cx=\"512\" cy=\"512\" r=\"340\"/></clipPath>"
            + "<filter id=\"\(id)b\" x=\"-60%\" y=\"-60%\" width=\"220%\" height=\"220%\"><feGaussianBlur stdDeviation=\"78\"/></filter><filter id=\"\(id)f\" x=\"-60%\" y=\"-60%\" width=\"220%\" height=\"220%\"><feGaussianBlur stdDeviation=\"16\"/></filter><filter id=\"\(id)w\" x=\"-60%\" y=\"-60%\" width=\"220%\" height=\"220%\"><feGaussianBlur stdDeviation=\"46\"/></filter>"
            + "<radialGradient id=\"\(id)e\" cx=\".4\" cy=\".34\" r=\".72\"><stop offset=\".62\" stop-color=\"#000\" stop-opacity=\"0\"/><stop offset=\"1\" stop-color=\"#000\" stop-opacity=\".5\"/></radialGradient>"
            + "<radialGradient id=\"\(id)r\" cx=\".36\" cy=\".3\" r=\".78\"><stop offset=\".8\" stop-color=\"#FFF\" stop-opacity=\"0\"/><stop offset=\".95\" stop-color=\"#FFF\" stop-opacity=\".5\"/><stop offset=\"1\" stop-color=\"#FFF\" stop-opacity=\".1\"/></radialGradient>"
        func eye(_ fill: String, _ dy: Double, _ opacity: Double) -> String {
            "<g fill=\"\(fill)\" opacity=\"\(js(opacity))\" transform=\"translate(0 \(js(dy)))\"><rect x=\"412\" y=\"462\" width=\"54\" height=\"140\" rx=\"27\"/><rect x=\"558\" y=\"462\" width=\"54\" height=\"140\" rx=\"27\"/></g>"
        }
        var body = g.dark
            ? "<circle cx=\"512\" cy=\"512\" r=\"350\" fill=\"\(hues[0])\" filter=\"url(#\(id)w)\" opacity=\".6\"/>"
            : "<ellipse cx=\"512\" cy=\"892\" rx=\"250\" ry=\"30\" fill=\"\(ink)\" filter=\"url(#\(id)f)\" opacity=\".22\"/>"
        body += "<g clip-path=\"url(#\(id)c)\"><rect width=\"1024\" height=\"1024\" fill=\"\(hues[0])\"/><g filter=\"url(#\(id)b)\"><g class=\"dh-drift\">\(blobs)</g></g><circle cx=\"512\" cy=\"512\" r=\"340\" fill=\"url(#\(id)e)\"/><circle cx=\"512\" cy=\"512\" r=\"340\" fill=\"url(#\(id)r)\"/>"
            + "<ellipse cx=\"408\" cy=\"330\" rx=\"150\" ry=\"74\" transform=\"rotate(-30 408 330)\" fill=\"#FFF\" filter=\"url(#\(id)f)\" opacity=\".85\"/></g>"
            + "<ellipse cx=\"372\" cy=\"322\" rx=\"46\" ry=\"26\" transform=\"rotate(-30 372 322)\" fill=\"#FFF\" opacity=\".95\"/>"
        if head.eyes { body += eye(ink, 10, 0.22) + "<g class=\"dh-face\">\(eye("#FFF", 0, 1))</g>" }
        return Made(frame: g.frame, panel: g.panel, defs: defs, body: body)
    }

    // MARK: Pixel (`render.ts:168-227`)

    static let bodies: [[Int]] = [
        [2, 3, 4, 4, 4, 4, 4, 3], // round
        [3, 4, 4, 4, 4, 4, 4, 4], // ghost
        [3, 4, 4, 4, 4, 4, 3], // block
        [3, 4, 5, 5, 5, 5, 4], // wide
        [2, 3, 3, 3, 3, 3, 3, 3, 2], // tall
    ]

    static func pixel(_ head: HeadRecord, _ tone: Tone, _ id: String, plain: Bool = false) -> Made {
        let g = ground(head, tone, id)
        var random = SeededRandom(seed: UInt32(truncatingIfNeeded: head.seed))
        func pick(_ count: Int) -> Int { Int((random.next() * Double(count)).rounded(.down)) }
        let size = 17, cell = 48.0, origin = 512 - Double(size) * cell / 2, mid = 8
        var on = Array(repeating: Array(repeating: false, count: size), count: size)
        func put(_ row: Int, _ col: Int) {
            if row >= 0, row < size, col >= 0, col <= mid { on[row][mid - col] = true; on[row][mid + col] = true }
        }
        let body = bodies[pick(bodies.count)], top = 5, bottom = top + body.count - 1
        for (i, reach) in body.enumerated() { for col in 0...reach { put(top + i, col) } }
        let wide = body[1]
        switch pick(5) { // on top
        case 0: put(top - 1, 0); put(top - 2, 0); put(top - 3, 0); put(top - 3, 1) // one antenna with a bulb
        case 1: put(top - 1, 2); put(top - 2, 3); put(top - 3, 3) // two antennae
        case 2: put(top - 1, wide); put(top - 1, wide - 1); put(top - 2, wide) // pointed ears
        case 3: put(top - 1, wide - 1); put(top - 1, wide - 2); put(top - 2, wide - 1); put(top - 2, wide - 2) // round ears
        default: break
        }
        let arm = top + 4, reach = body[4]
        switch pick(4) { // arms
        case 0: put(arm, reach + 1); put(arm, reach + 2)
        case 1: put(arm, reach + 1); put(arm - 1, reach + 2); put(arm - 2, reach + 2)
        case 2: put(arm, reach + 1); put(arm + 1, reach + 2)
        default: break
        }
        let feet = body[body.count - 1]
        switch pick(4) { // underneath
        case 0: put(bottom + 1, 1); put(bottom + 2, 1); put(bottom + 2, 2)
        case 1: for col in stride(from: 0, through: feet, by: 2) { put(bottom + 1, col) }
        case 2: put(bottom + 1, 0); put(bottom + 1, 2); put(bottom + 1, feet); put(bottom + 2, feet)
        default: put(bottom + 1, 2); put(bottom + 1, 1)
        }
        let inkColor = g.dark ? "#000" : ink, fill = tone.accent, eyeRow = top + 2, eyeCol = 2
        let drawnTall = random.next() < 0.6, drawnMouth = pick(3), belly = random.next() < 0.5
        // Plain: the tall eyes most creatures have and no mouth (still picked, so the belly stays the same).
        let tallEyes = drawnTall || plain, mouth = plain ? 2 : drawnMouth
        var outline = "", cells = "", light = "", shade = "", tummy = ""
        func box(_ col: Int, _ row: Int, _ w: Double = 1, _ h: Double = 1) -> String {
            "M\(js(origin + Double(col) * cell)) \(js(origin + Double(row) * cell))h\(js(cell * w))v\(js(cell * h))h\(js(-cell * w))z"
        }
        func at(_ row: Int, _ col: Int) -> Bool { row >= 0 && row < size && col >= 0 && col < size && on[row][col] }
        for row in -1...size {
            for col in -1...size {
                if at(row, col) {
                    cells += box(col, row)
                    let thick = (at(row, col - 1) && at(row, col + 1)) || (at(row - 1, col) && at(row + 1, col) && (at(row, col - 1) || at(row, col + 1)))
                    if !thick { continue }
                    if (!at(row - 1, col) && at(row + 1, col)) || (!at(row, col - 1) && col < mid && at(row - 1, col)) { light += box(col, row) }
                    else if (!at(row + 1, col) && at(row - 1, col)) || (!at(row, col + 1) && col > mid) { shade += box(col, row) }
                    else if belly && row > eyeRow + 2 && row < bottom && abs(col - mid) <= 1 { tummy += box(col, row) }
                } else if [-1, 0, 1].contains(where: { dy in [-1, 0, 1].contains(where: { dx in at(row + dy, col + dx) }) }) {
                    outline += box(col, row)
                }
            }
        }
        func eye(_ col: Int) -> String {
            "<path d=\"\(box(col, eyeRow, 1, tallEyes ? 2 : 1))\" fill=\"\(inkColor)\"/><rect x=\"\(js(origin + Double(col) * cell + 8))\" y=\"\(js(origin + Double(eyeRow) * cell + 8))\" width=\"17\" height=\"17\" fill=\"#FFF\"/>"
        }
        let smile = mouth == 0 ? box(mid - 1, eyeRow + 3, 3, 1) : mouth == 1 ? box(mid, eyeRow + 3) : ""
        let cheeks = random.next() < 0.4 && !plain ? "<path d=\"\(box(mid - 4, eyeRow + 2))\(box(mid + 4, eyeRow + 2))\" fill=\"#FF7FA8\" opacity=\".85\"/>" : ""
        // Centre the creature on the tile whatever parts it has.
        let rows = on.enumerated().compactMap { $0.element.contains(true) ? $0.offset : nil }
        let lift = Double(size - 1 - rows[0] - rows[rows.count - 1]) * cell / 2
        return Made(frame: g.frame, panel: g.panel, defs: g.defs,
                    body: "<g shape-rendering=\"crispEdges\" transform=\"translate(0 \(js(n1(lift))))\">\(g.dark ? "" : "<path d=\"\(outline)\" fill=\"\(inkColor)\"/>")<path d=\"\(cells)\" fill=\"\(fill)\"/><path d=\"\(light)\" fill=\"\(tone.light)\" opacity=\".62\"/><path d=\"\(shade)\" fill=\"\(tone.deep)\"/><path d=\"\(tummy)\" fill=\"\(tone.light)\" opacity=\".7\"/>"
                        + "\(cheeks)<g class=\"dh-face\">\(eye(mid - eyeCol))\(eye(mid + eyeCol))</g><path d=\"\(smile)\" fill=\"\(inkColor)\"/></g>")
    }

    // MARK: Emoji (`render.ts:229-240`)

    static func escapeText(_ text: String) -> String {
        var out = ""
        for ch in text.unicodeScalars {
            switch ch {
            case "&", "<", ">", "\"", "'": out += "&#\(ch.value);"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func glyph(_ head: HeadRecord, _ tone: Tone, _ id: String) -> Made {
        let g = ground(head, tone, id), text = HeadRecord.cleanGlyph(.string(head.glyph)), emoji = HeadRecord.isEmoji(text)
        let top = head.tile == "color" ? tone.light : "#FFFFFF", bottom = head.tile == "color" ? tone.accent : "#E9E4D8"
        let defs = g.defs + "<linearGradient id=\"\(id)t\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(top)\"/><stop offset=\"1\" stop-color=\"\(bottom)\"/></linearGradient><filter id=\"\(id)s\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\"><feGaussianBlur stdDeviation=\"18\"/></filter>"
        var body = (g.dark ? "" : "<rect width=\"1024\" height=\"1024\" fill=\"url(#\(id)t)\"/>")
            + "<ellipse cx=\"512\" cy=\"838\" rx=\"220\" ry=\"26\" fill=\"#000\" filter=\"url(#\(id)s)\" opacity=\"\(g.dark ? "0.6" : "0.2")\"/>"
        if emoji {
            body += "<text x=\"512\" y=\"500\" text-anchor=\"middle\" dominant-baseline=\"central\" font-size=\"520\">\(escapeText(text))</text>"
        } else {
            let fill = g.dark ? (head.color == "ink" ? "#FFF" : tone.accent) : ink
            body += "<text x=\"512\" y=\"524\" text-anchor=\"middle\" dominant-baseline=\"central\" font-family=\"ui-rounded,-apple-system,system-ui,sans-serif\" font-weight=\"800\" font-size=\"\(text.count > 1 ? 400 : 560)\" letter-spacing=\"-12\" fill=\"\(fill)\">\(escapeText(text))</text>"
        }
        return Made(frame: g.frame, panel: g.panel, defs: defs, body: body)
    }

    // MARK: headSvg (`render.ts:250-264`)

    /// The themes this file draws (Shapes is HeadGeometry's; Character was removed by the owner).
    static let drawnThemes: Set<String> = ["robot", "dots", "orb", "pixel", "glyph"]

    /// The whole picture as an SVG document, in the icon's 1024 space. `id` prefixes every def so two heads can
    /// share a document; it stands in for the web's running serial.
    /// `plain` (the app's own drawing, `Head.plain`): eyes only, always the normal ones, so a finished robot doesn't
    /// smile, an offline one doesn't sleep, and a pixel creature has tall eyes and no mouth or cheeks. Off, the web's.
    static func svg(_ head: HeadRecord, state: HeadState? = nil, compact: Bool = false, id: String = "dh1", robotID: String = "rb1",
                    plain: Bool = false) -> String {
        let head = plain ? head.plain : head
        let tone = tone(head.color)
        let made: Made
        switch head.theme {
        case "dots": made = dots(head, tone, id, compact: compact, state: state)
        case "orb": made = orb(head, tone, id)
        case "pixel": made = pixel(head, tone, id, plain: plain)
        case "glyph": made = glyph(head, tone, id)
        default: made = Made(frame: ink, panel: tone.panel, body: robotMarkup(head, tone, state: plain ? nil : state, id: robotID))
        }
        let body = head.theme == "dots" || head.theme == "orb" || head.theme == "pixel" || head.theme == "glyph"
            ? "<g class=\"dh-body\">\(made.body)</g>" : made.body
        let stated = state.map { $0 != .idle ? " data-state=\"\($0.rawValue)\"" : "" } ?? ""
        let theme = drawnThemes.contains(head.theme) ? head.theme : "robot"
        return "<svg class=\"dh dh-icon\" data-theme=\"\(theme)\"\(stated) xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" aria-hidden=\"true\"><defs><clipPath id=\"\(id)p\"><path d=\"\(panel)\"/></clipPath>\(made.defs)</defs>"
            + "<path d=\"\(frame)\" fill=\"\(made.frame)\"/><path d=\"\(panel)\" fill=\"\(made.panel)\"/><g clip-path=\"url(#\(id)p)\">\(body)</g></svg>"
    }
}
