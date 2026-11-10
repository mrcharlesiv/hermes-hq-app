// A snowed-in village in a valley: a church, houses of different builds, a stream under a stone bridge. Design space x 0...1000, y 0...2168.

import CoreGraphics
import Foundation

private typealias P = PosterP

nonisolated private struct VillageInks: Sendable {
    var walls: [(lit: PosterInk, shade: PosterInk)]
    var beam: PosterInk, stone: PosterInk, stoneDark: PosterInk, eave: PosterInk
    var roofLit: PosterInk, roofShade: PosterInk, roofDeep: PosterInk
    var pane: PosterInk, paneDim: PosterInk, frame: PosterInk, shutter: PosterInk
    var chimney: PosterInk, drift: PosterInk, shadow: PosterInk
    var spireLit: PosterInk, spireShade: PosterInk
}

nonisolated private struct VillageHouse: Sendable {
    var x: Double, y: Double, s: Double
    var left: Bool, tone: Int, kind: Int
    var gw: Double = 46, sw: Double = 62, h: Double = 34, rh: Double = 30
    var chim: Double = 0.7
}

/// One house in painter's order. Its gable is on the left and lit when `left`, otherwise on the right and in shade with the long wall lit.
nonisolated private func villageHouse(_ g: CGContext, _ b: VillageHouse, _ k: VillageInks, dark: Bool, tops: inout [(x: Double, y: Double, s: Double)]) {
    var r = SplitMix64(seed: UInt64(b.x * 7 + 3) &* 31 &+ UInt64(b.y * 13))
    let m = b.left ? 1.0 : -1.0
    let s = b.s, gw = b.gw, sw = b.sw, h = b.h, rh = b.rh
    func p(_ u: Double, _ v: Double) -> P { P(b.x + m * u * s, b.y - v * s) }
    func side(_ u: Double, _ v: Double) -> P { p(u, v + u * (0.1 - 0.04 * v / h)) }
    func gable(_ u: Double, _ v: Double) -> P { p(u, v - u * (0.14 - 0.04 * v / h)) }
    let wall = k.walls[b.tone % k.walls.count]
    let gableInk = b.left ? wall.lit : wall.shade, sideInk = b.left ? wall.shade : wall.lit
    let apex = p(-gw / 2, h + rh + gw * 0.06), ridgeFar = p(-gw / 2 + sw, h + rh + gw * 0.06 + sw * 0.06)

    // Its shadow on the snow goes right, whichever way it faces.
    let reach = (sw + gw) * s, edge = b.x + (b.left ? sw : gw) * s
    Poster.fill(g, k.shadow, [P(edge - reach * 0.5, b.y - 1 * s), P(edge, b.y - 2.5 * s), P(edge + reach * 0.5, b.y - 1 * s), P(edge + reach * 1.05, b.y + 3.5 * s), P(edge + reach * 0.3, b.y + 7 * s), P(edge - reach * 0.5, b.y + 6 * s)])

    Poster.fill(g, sideInk, [side(0, 0), side(sw, 0), side(sw, h), side(0, h)])
    Poster.fill(g, gableInk, [gable(0, 0), gable(0, h), apex, gable(-gw, h), gable(-gw, 0)])

    // The build.
    switch b.kind {
    case 2:
        // A stone ground floor.
        Poster.fill(g, k.stone, [side(0, 0), side(sw, 0), side(sw, h * 0.34), side(0, h * 0.34)])
        Poster.fill(g, k.stone, [gable(0, 0), gable(0, h * 0.34), gable(-gw, h * 0.34), gable(-gw, 0)])
        g.setFillColor(Poster.cg(k.stoneDark))
        g.beginPath()
        for _ in 0..<Int(10 + 8 * s) {
            let u = r.next(0.04, 0.96), v = r.next(0.03, 0.31)
            let c = r.next() < 0.6 ? side(u * sw, v * h) : gable(-u * gw, v * h)
            Poster.lens(g, c.x, c.y, r.next(3.4, 7) * s, r.next(0.8, 1.3) * s)
        }
        g.fillPath()
    case 3:
        // Boards.
        g.setFillColor(Poster.cg(k.beam))
        g.beginPath()
        var u = 3.5
        while u < sw {
            let a = side(u, 0), d = side(u, h)
            g.move(to: CGPoint(x: a.x, y: a.y)); g.addLine(to: CGPoint(x: a.x + 0.8 * s, y: a.y)); g.addLine(to: CGPoint(x: d.x + 0.8 * s, y: d.y)); g.addLine(to: CGPoint(x: d.x, y: d.y)); g.closePath()
            u += r.next(3.6, 5.4)
        }
        u = 3.5
        while u < gw {
            let v = h + rh * (1 - abs(u - gw / 2) / (gw / 2))
            let a = gable(-u, 0), d = gable(-u, v * 0.98)
            g.move(to: CGPoint(x: a.x, y: a.y)); g.addLine(to: CGPoint(x: a.x + 0.8 * s, y: a.y)); g.addLine(to: CGPoint(x: d.x + 0.8 * s, y: d.y)); g.addLine(to: CGPoint(x: d.x, y: d.y)); g.closePath()
            u += r.next(3.6, 5.4)
        }
        g.fillPath()
    default:
        break
    }

    // Windows, not on a grid: a plain row with gaps, a shutter here, a door there.
    func window(_ place: (Double, Double) -> P, _ u: Double, _ v: Double, _ w: Double, _ hh: Double, lit: Bool) {
        Poster.fill(g, lit ? k.pane : k.paneDim, [place(u, v), place(u + w, v), place(u + w, v + hh), place(u, v + hh)])
    }
    let lit = dark ? 0.62 : 0.1
    let n = max(2, Int(sw / 15))
    let door = Int(r.next(0, Double(n)))
    for i in 0..<n {
        if i != door && r.next() < 0.14 { continue }
        let u = (Double(i) + 0.5) * sw / Double(n) - 3.6 + r.next(-1, 1)
        if i == door && !b.left {
            Poster.fill(g, k.beam, [side(u - 0.6, 0), side(u + 7.6, 0), side(u + 7.6, h * 0.62), side(u - 0.6, h * 0.62)])
            if dark { Poster.fill(g, k.pane, [side(u + 1.2, h * 0.5), side(u + 5.8, h * 0.5), side(u + 5.8, h * 0.58), side(u + 1.2, h * 0.58)]) }
            continue
        }
        window(side, u, h * 0.4 + r.next(-0.8, 0.8), 7.2, 10.5, lit: r.next() < lit)
    }
    // The gable: one or two below, a small one up in the point.
    if gw > 30 {
        if b.left && r.next() < 0.4 {
            Poster.fill(g, k.beam, [gable(-gw * 0.5 - 4, 0), gable(-gw * 0.5 + 4, 0), gable(-gw * 0.5 + 4, h * 0.62), gable(-gw * 0.5 - 4, h * 0.62)])
            if dark { Poster.fill(g, k.pane, [gable(-gw * 0.5 - 2.4, h * 0.5), gable(-gw * 0.5 + 2.4, h * 0.5), gable(-gw * 0.5 + 2.4, h * 0.58), gable(-gw * 0.5 - 2.4, h * 0.58)]) }
        } else {
            window(gable, -gw * 0.34 - 3.5, h * 0.36, 7, 10.5, lit: r.next() < lit)
            window(gable, -gw * 0.72 - 3.5, h * 0.36, 7, 10.5, lit: r.next() < lit)
        }
        window(gable, -gw * 0.5 - 3, h + rh * 0.12, 6, 8, lit: r.next() < lit * 0.8)
    }
    // The shadow the eaves throw.
    Poster.fill(g, k.eave, [side(-1, h + 1), side(sw + 1, h + 1), side(sw + 1, h - 5.5), side(0, h - 5.5)])
    Poster.fill(g, k.eave, [gable(0, h), apex, gable(-gw, h), gable(-gw + 1, h - 4), P(apex.x, apex.y + 8.5 * s), gable(-1, h - 4)])

    // Snow on the roof: the slope we can see, thick at the eave, sagging and dripping over it.
    let over = 6.0
    let e0 = side(-over, h - 2.6), e1 = side(sw + over, h - 2.6)
    let plane = b.left ? k.roofShade : k.roofLit
    var eave: [P] = []
    let drips = max(6, Int(sw * s / 8))
    for i in 0...drips {
        let u = Double(i) / Double(drips)
        let drop = (i % 2 == 0 ? r.next(0.2, 1.5) : r.next(1.2, 3.8)) * s
        eave.append(P(e0.x + (e1.x - e0.x) * u, e0.y + (e1.y - e0.y) * u + drop))
    }
    let ridgeA = P(apex.x, apex.y - 3.4 * s), ridgeB = P(ridgeFar.x, ridgeFar.y - 3.4 * s)
    Poster.fill(g, plane, [ridgeA, ridgeB] + eave.reversed())
    // Soft shapes in the snow: the deeper ink low down on a shaded plane, a sliver of shade on a lit one, a lit crest along the ridge.
    let low = b.left ? k.roofDeep : k.roofShade
    var lowEdge: [P] = []
    for i in 0...10 {
        let u = Double(i) / 10
        let t = (b.left ? 0.62 : 0.8) + 0.1 * sin(u * 7 + b.x)
        let a = P(ridgeA.x + (ridgeB.x - ridgeA.x) * u, ridgeA.y + (ridgeB.y - ridgeA.y) * u)
        let d = P(e0.x + (e1.x - e0.x) * u, e0.y + (e1.y - e0.y) * u)
        lowEdge.append(P(a.x + (d.x - a.x) * t, a.y + (d.y - a.y) * t))
    }
    Poster.fill(g, low, lowEdge + eave.reversed())
    if b.left {
        var crest: [P] = []
        for i in 0...10 {
            let u = Double(i) / 10
            let t = 0.2 + 0.08 * sin(u * 9 + b.y)
            let a = P(ridgeA.x + (ridgeB.x - ridgeA.x) * u, ridgeA.y + (ridgeB.y - ridgeA.y) * u)
            let d = P(e0.x + (e1.x - e0.x) * u, e0.y + (e1.y - e0.y) * u)
            crest.append(P(a.x + (d.x - a.x) * t, a.y + (d.y - a.y) * t))
        }
        Poster.fill(g, k.roofLit, [ridgeA, ridgeB] + crest.reversed())
    }
    // Rake snow on the gable's two edges, lumpy.
    func rake(_ a: P, _ d: P, up: Double) {
        var top: [P] = [], bot: [P] = []
        for i in 0...8 {
            let u = Double(i) / 8
            let x = a.x + (d.x - a.x) * u, y = a.y + (d.y - a.y) * u
            top.append(P(x, y - up * s * r.next(0.8, 1.3)))
            bot.append(P(x, y + r.next(0.4, 1.6) * s))
        }
        Poster.fill(g, b.left ? k.roofLit : k.roofShade, top + bot.reversed())
    }
    rake(P(ridgeA.x, ridgeA.y + 1 * s), gable(-gw - 4.4, h - 3.2), up: 2.8)
    rake(P(ridgeA.x, ridgeA.y + 1 * s), e0, up: 2.4)

    // Chimney.
    if b.chim > 0 {
        let c0 = P(ridgeA.x + (ridgeB.x - ridgeA.x) * b.chim, ridgeA.y + (ridgeB.y - ridgeA.y) * b.chim + 7 * s)
        let w = 4.4 * s, t = 16 * s
        Poster.fill(g, k.chimney, [P(c0.x - w, c0.y + 6 * s), P(c0.x - w, c0.y - t), P(c0.x + w, c0.y - t), P(c0.x + w, c0.y + 6 * s)])
        Poster.fill(g, k.roofLit, [P(c0.x - w - 1.4 * s, c0.y - t - 0.4 * s), P(c0.x - w * 0.5, c0.y - t - 2.8 * s), P(c0.x + w * 0.6, c0.y - t - 2.4 * s), P(c0.x + w + 1.4 * s, c0.y - t - 0.2 * s), P(c0.x + w + 0.8 * s, c0.y - t + 2 * s), P(c0.x - w - 0.8 * s, c0.y - t + 2.2 * s)])
        Poster.fill(g, k.roofLit, [P(c0.x - w - 2.6 * s, c0.y + 6 * s), P(c0.x - w, c0.y + 1 * s), P(c0.x + w, c0.y + 0 * s), P(c0.x + w + 2.6 * s, c0.y + 5 * s)])
        tops.append((c0.x, c0.y - t - 3 * s, s))
    }

    // Snow banked up against the foot: a low, lumpy mound that dies away at both ends.
    let f0 = gable(-gw - 16, -1), f1 = side(sw + 16, -1)
    var upper: [P] = [], lower: [P] = []
    let bumps = 14
    for i in 0...bumps {
        let u = Double(i) / Double(bumps)
        let x = f0.x + (f1.x - f0.x) * u
        let line: Double
        if m * (x - b.x) < 0 { line = b.y - abs(x - b.x) * 0.14 } else { line = b.y - abs(x - b.x) * 0.1 }
        let env = pow(sin(.pi * u), 0.6)
        upper.append(P(x, line - r.next(3, 8.5) * s * env + 3 * s * (1 - env)))
        lower.append(P(x, line + (3 + 4 * env) * s))
    }
    Poster.fill(g, k.drift, upper + lower.reversed())
}

nonisolated extension Poster {
    static func snowyVillage(_ c: PosterCanvas, dark: Bool) {
        var rng = SplitMix64(seed: 0x51_11A6)
        let lift = max(0, 2168 - c.bottomY) * 0.86

        // The sky: crisp morning, or a deep clear blue night.
        let skyStops: [(Double, PosterInk)] = dark
            ? [(0, hx(0x040818)), (0.4, hx(0x081030)), (0.72, hx(0x0E1A44)), (1, hx(0x1C2A58))]
            : [(0, hx(0x4F90BE)), (0.3, hx(0x84B6D2)), (0.55, hx(0xBFD6DF)), (0.76, hx(0xEFE2D6)), (1, hx(0xFAD2B6))]
        c.pull(PosterRamp(skyStops, step: 1), amp: dark ? 0.03 : 0.042, key: 1, rows: (0, c.row(1240))) { _, y in Float((y - 150) / 900) }
        if dark {
            PosterSky.stars2(c, until: 860, bright: [(150, 200, 2.2), (404, 112, 1.7), (800, 228, 2.3), (240, 430, 1.8), (900, 460, 1.6)],
                             dots: hx(0xB8C6E0), big: hx(0xF0EEE2), count: 480, seed: 73)
        }
        // A few flat clouds low in the sky.
        do {
            var r = SplitMix64(seed: 0x57E7)
            let groups: [(Double, Double, Double, Double, Double)] = [
                (640, 1140, 408, 13, 5), (760, 1100, 450, 8, 3)
            ]
            var bodies: [[P]] = []
            for g in groups { bodies.append(PosterCut.spindle(x0: g.0, x1: g.1, y: g.2, up: g.3, down: g.4, skew: 0.56, rng: &r)) }
            let body = PosterPlate(c) { g in for b in bodies { fillPoly(g, b) } }
            c.flat(dark ? hx(0x121C42) : hx(0xA4C4D4), plate: body, opacity: 0.86)
            let lit = PosterPlate(c) { g in
                for b in bodies {
                    g.saveGState()
                    g.beginPath()
                    poly(g, b)
                    g.clip()
                    fillPoly(g, b.map { P($0.x - 8, $0.y - 4) })
                    g.restoreGState()
                }
            }
            c.flat(dark ? hx(0x202C56) : hx(0xFFF6E8), plate: lit, opacity: 0.92)
        }

        // A far range and the massif above the valley: no moon, only the morning on its upper snow, or starlight.
        let farRange = PosterPlate(c) { g in
            var r = SplitMix64(seed: 302)
            var pts = cut([P(-30, 930), P(60, 860), P(140, 894), P(214, 806), P(280, 850), P(350, 800), P(800, 800), P(880, 770), P(950, 800), P(1030, 760)], amp: 0.08, minLen: 16, rng: &r)
            pts.append(P(1030, 1240)); pts.append(P(-30, 1240))
            fillPoly(g, pts)
        }
        c.pull(PosterRamp(dark ? [(0, hx(0x141E44)), (1, hx(0x18244A))] : [(0, hx(0xA6C0D2)), (1, hx(0xE4DCD8))], step: 0.8), plate: farRange, amp: 0.05, key: 6) { _, y in Float((y - 780) / 340) }

        func arete(_ pts: [P], h: Double, k: Double = 0.98, amp: Double = 0.07, len: Double = 24, fade: Double = 0.78, rampIn: Double = 0.03) -> PosterRidge {
            PosterAlp.ridge(pts, h: h, k: k, amp: amp, len: len, fade: fade, rampIn: rampIn, rng: &rng)
        }
        let foot = 1200.0
        let skyline = cut([P(-60, 1060), P(50, 990), P(136, 952), P(190, 972), P(270, 884), P(330, 900), P(404, 806), P(452, 760), P(500, 680), P(536, 692), P(586, 628), P(628, 572), P(656, 592), P(690, 650), P(734, 712), P(786, 772), P(826, 756), P(876, 706), P(922, 762), P(990, 852), P(1060, 912)], amp: 0.06, minLen: 13, rng: &rng)
        let m1 = arete([P(628, 572), P(586, 690), P(516, 800), P(440, 930), P(350, 1060), P(250, 1200)], h: 230)
        let m2 = arete([P(628, 572), P(650, 700), P(632, 840), P(668, 980), P(650, 1200)], h: 230)
        let m3 = arete([P(876, 706), P(848, 820), P(868, 950), P(840, 1200)], h: 150)
        let m4 = arete([P(404, 806), P(340, 900), P(250, 1000), P(120, 1200)], h: 130)
        let second = [
            arete([P(516, 800), P(560, 900), P(548, 1040), P(560, 1190)], h: 90, k: 1.25, rampIn: 0.22),
            arete([P(632, 840), P(590, 930), P(610, 1060), P(590, 1190)], h: 80, k: 1.25, rampIn: 0.22),
            arete([P(668, 980), P(730, 1060), P(760, 1190)], h: 70, k: 1.25, rampIn: 0.22),
            arete([P(350, 1060), P(376, 1130), P(380, 1190)], h: 44, k: 1.25, rampIn: 0.22),
            arete([P(250, 1000), P(262, 1090), P(250, 1190)], h: 44, k: 1.25, rampIn: 0.22),
            arete([P(868, 950), P(930, 1040), P(980, 1190)], h: 60, k: 1.25, rampIn: 0.22),
            arete([P(500, 680), P(470, 760), P(420, 830)], h: 44, k: 1.2, fade: 0.3, rampIn: 0.22),
            arete([P(270, 884), P(262, 950), P(214, 1030)], h: 40, k: 1.2, fade: 0.3, rampIn: 0.22)
        ]
        var third: [PosterRidge] = []
        for r in [m1, m2, m3, m4] { third += spurs(of: r, count: 5, length: 34...110, hFrac: 0.28, k: 1.5, from: 0.06, to: 0.84, spread: 30...56, rng: &rng) }
        third.removeAll { $0.pts.last!.x > $0.pts[0].x + 6 && $0.pts[0].y < 800 && $0.pts[0].x > 600 }
        for r in second { third += spurs(of: r, count: 2, length: 24...70, hFrac: 0.42, k: 1.5, from: 0.1, to: 0.8, spread: 30...56, rng: &rng) }
        let massifInks = dark
            ? PosterAlpInks(rockDeep: hx(0x060A20), rockShadow: hx(0x0C1230), rockMid: hx(0x161E44), rockLit: hx(0x20294E),
                            snowDeep: hx(0x101A40), snowShadow: hx(0x18244E), snowMid: hx(0x28386A), snowLit: hx(0x445890), snowTop: hx(0x54689C), rim: hx(0x8092C0))
            : PosterAlpInks(rockDeep: hx(0x2A3A68), rockShadow: hx(0x40568A), rockMid: hx(0x7E7CA2), rockLit: hx(0xB298A4),
                            snowDeep: hx(0x5F7CAE), snowShadow: hx(0x86A0C8), snowMid: hx(0xC4CCE0), snowLit: hx(0xFFF4E4), snowTop: hx(0xFFD6BA), rim: hx(0xFFFAEE))
        PosterAlp.paint(c, skyline: skyline, bottom: foot + 40, top: 572, foot: foot, slope: 0.5, levels: [[m1, m2, m3, m4], second, third], rockRidges: [([m1, m2, m3, m4], 1), (second, 0.7)],
                        style: PosterAlpStyle(light: PosterLight(-0.74, -0.34, 0.6), inks: massifInks, rockLine: 0.46, rockWidth: 130),
                        warmLine: { x in 760 - 0.34 * (x - 600) }, tint: dark ? hx(0x2A3C70) : hx(0xFFF0DC), seed: 0x3456, key: 2)
        // The air at its foot, in steps.
        do {
            let air = dark ? hx(0x162046) : hx(0xD8E0E6)
            // The facets dissolve into the cold air grain by grain, well above the first band of it.
            let mountain = PosterPlate(c) { g in fillPoly(g, skyline + [P(1060, 1240), P(-60, 1240)]) }
            c.stipple(air, plate: mountain, rows: (c.row(860), c.row(1160)), key: 37, grainMix: 0.3) { _, y in
                let u = Float(dsstep(860, 1120, y))
                return u * u * 0.94
            }
            for (y, tilt, op, wa, wl, wp) in [(1016.0, 0.03, 0.35, 12.0, 190.0, 1.1), (1064.0, -0.03, 0.6, 10.0, 150.0, 3.0), (1108.0, 0.02, 0.85, 8.0, 120.0, 0.4), (1146.0, -0.01, 1.0, 6.0, 100.0, 2.0)] {
                let p = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: y, tilt: tilt, waves: [(wa, wl, wp), (wa * 0.4, wl * 0.33, wp * 2)], floorY: foot + 60)) }
                c.flat(air, plate: p, opacity: op)
            }
        }

        // The forest comes down both sides, opening a V onto the village: two torn planes, dusted on the side facing the light.
        func forest(seed: UInt64, line: @escaping (Double) -> Double, floorY: Double, height: ClosedRange<Double>, ink: PosterInk, snow: PosterInk) {
            var r = SplitMix64(seed: seed), r2 = SplitMix64(seed: seed)
            let body = PosterPlate(c) { g in PosterCut.treeline(g, line: line, floorY: floorY, height: height, rng: &r) }
            let inner = PosterPlate(c) { g in
                g.saveGState()
                g.translateBy(x: 1.7, y: 2.6)
                PosterCut.treeline(g, line: line, floorY: floorY, height: height, rng: &r2)
                g.restoreGState()
            }
            c.flat(ink, plate: body)
            body.subtract(inner)
            c.flat(snow, plate: body, opacity: 0.84)
        }
        forest(seed: 54, line: { x in 1212 - (x < 420 ? 112 * pow((420 - x) / 470, 1.7) : 250 * pow((x - 420) / 620, 2.2)) + 8 * sin(x / 140) }, floorY: 1300, height: 34...72, ink: dark ? hx(0x0A1230) : hx(0x48708A), snow: dark ? hx(0x2A3A6A) : hx(0xEEEEEE))
        forest(seed: 55, line: { x in 1244 - (x < 420 ? 90 * pow((420 - x) / 470, 2) : 214 * pow((x - 420) / 620, 2.4)) + 10 * sin(x / 190 + 1) }, floorY: 1320, height: 36...86, ink: dark ? hx(0x070C24) : hx(0x2C5270), snow: dark ? hx(0x26346A) : hx(0xFFF6EA))

        // The valley floor: snow all the way down, stepping in terraces.
        let snowRamp = PosterRamp(dark
            ? [(0, hx(0x263660)), (0.22, hx(0x1E2C54)), (0.5, hx(0x162244)), (0.78, hx(0x0F1834)), (1, hx(0x091026))]
            : [(0, hx(0xFFF8EC)), (0.26, hx(0xFBEDE4)), (0.5, hx(0xE8E2EA)), (0.78, hx(0xCCD4E8)), (1, hx(0xABBBDC))], step: 0.6)
        @Sendable func snowTone(_ y: Double) -> Double { (y - 1220) / 950 }
        let valley = PosterPlate(c) { g in
            var pts: [P] = []
            var x = -30.0
            while x <= 1030 {
                pts.append(P(x, 1238 - (x < 420 ? 80 * pow((420 - x) / 470, 2.1) : 190 * pow((x - 420) / 620, 2.5)) + 9 * sin(x / 170 + 0.7) + 3 * sin(x / 31)))
                x += 8
            }
            pts.append(P(1030, 2220)); pts.append(P(-30, 2220))
            fillPoly(g, pts)
        }
        c.pull(snowRamp, plate: valley, amp: 0.05, key: 3) { _, y in Float(snowTone(y)) }
        struct Bank { var x0: Double, x1: Double, y0: Double, y1: Double, a: Double, l: Double, p: Double, belly: Double }
        let banks: [Bank] = [
            Bank(x0: -120, x1: 640, y0: 1302, y1: 1284, a: 3, l: 70, p: 0.8, belly: 26),
            Bank(x0: 500, x1: 1130, y0: 1262, y1: 1238, a: 3, l: 66, p: 2.1, belly: 24),
            Bank(x0: -140, x1: 600, y0: 1408, y1: 1380, a: 4, l: 84, p: 3.1, belly: 40),
            Bank(x0: 560, x1: 1140, y0: 1372, y1: 1346, a: 4, l: 90, p: 1.4, belly: 44),
            Bank(x0: -160, x1: 570, y0: 1536, y1: 1500, a: 5, l: 110, p: 2.2, belly: 60),
            Bank(x0: 610, x1: 1160, y0: 1488, y1: 1462, a: 5, l: 110, p: 4.4, belly: 66)
        ]
        for b in banks {
            let t = PosterPlate(c) { g in fillPoly(g, swell(x0: b.x0, x1: b.x1, y0: b.y0, y1: b.y1, a: b.a, l: b.l, p: b.p, thick: b.belly)) }
            c.pull(snowRamp, plate: t, amp: 0.05, key: 26) { _, y in Float(snowTone(y) + 0.18) }
            let lip = PosterPlate(c) { g in fillPoly(g, swell(x0: b.x0, x1: b.x1, y0: b.y0, y1: b.y1, a: b.a, l: b.l, p: b.p, thick: b.belly * 0.2)) }
            c.pull(snowRamp, plate: lip, amp: 0.05, key: 27) { _, y in Float(snowTone(y) - 0.2) }
        }

        // The village: hand placed, far to near, none of them twins.
        let inks: VillageInks = dark
            ? VillageInks(walls: [(hx(0x26283E), hx(0x10122A)), (hx(0x2C2236), hx(0x141026)), (hx(0x1E2844), hx(0x0E142C))],
                          beam: hx(0x0A0A1A), stone: hx(0x1A1E36), stoneDark: hx(0x0A0C1E), eave: hx(0x06081A),
                          roofLit: hx(0x4A5E92), roofShade: hx(0x2C3C6C), roofDeep: hx(0x1C2850),
                          pane: hx(0xFFC468), paneDim: hx(0x0A0E22), frame: hx(0x0C0E20), shutter: hx(0x141830),
                          chimney: hx(0x12142A), drift: hx(0x2A3A68), shadow: hx(0x0A1026),
                          spireLit: hx(0x24344E), spireShade: hx(0x0E1830))
            : VillageInks(walls: [(hx(0xCBAE86), hx(0x93806C)), (hx(0xAE7560), hx(0x774E4A)), (hx(0xA2ACB2), hx(0x6C7A8A))],
                          beam: hx(0x56382E), stone: hx(0xA69A98), stoneDark: hx(0x6E6A74), eave: hx(0x4A4664),
                          roofLit: hx(0xFFF9EE), roofShade: hx(0xCDD6EA), roofDeep: hx(0xA8B8D8),
                          pane: hx(0xFBD27C), paneDim: hx(0x3E5670), frame: hx(0x4A4664), shutter: hx(0x4A6E78),
                          chimney: hx(0x8A4C3E), drift: hx(0xFFF8EE), shadow: hx(0xAEBBD8),
                          spireLit: hx(0x7CA89E), spireShade: hx(0x38606E))
        func h(_ x: Double, _ y: Double, _ s: Double, _ left: Bool, _ tone: Int, _ kind: Int, gw: Double = 46, sw: Double = 62, wall: Double = 34, roof: Double = 30, chim: Double = 0.7) -> VillageHouse {
            VillageHouse(x: x, y: y, s: s, left: left, tone: tone, kind: kind, gw: gw, sw: sw, h: wall, rh: roof, chim: chim)
        }
        let back: [VillageHouse] = [
            h(52, 1292, 0.6, true, 0, 0), h(118, 1282, 0.58, false, 2, 0, chim: 0), h(182, 1290, 0.62, true, 1, 3), h(244, 1274, 0.58, false, 0, 0, chim: 0),
            h(556, 1286, 0.62, true, 2, 0), h(616, 1272, 0.58, false, 1, 3, chim: 0), h(672, 1280, 0.64, true, 0, 2), h(762, 1292, 0.6, false, 2, 0, chim: 0)
        ]
        let middle: [VillageHouse] = [
            h(40, 1404, 0.96, true, 1, 2, sw: 56), h(136, 1388, 0.88, false, 0, 0, gw: 40, sw: 52), h(214, 1420, 1.02, true, 2, 3, gw: 42, sw: 50),
            h(560, 1398, 0.92, false, 1, 0, gw: 44, sw: 54, chim: 0.4), h(632, 1412, 1.0, true, 0, 2, gw: 44, sw: 60), h(724, 1386, 0.86, false, 2, 3, chim: 0)
        ]
        let front: [VillageHouse] = [
            h(92, 1522, 1.3, true, 0, 2, gw: 48, sw: 56), h(250, 1552, 1.46, false, 1, 0, gw: 50, sw: 58), h(386, 1500, 1.18, true, 2, 3, gw: 46, sw: 48, chim: 0.3),
            h(520, 1528, 1.22, false, 0, 0, gw: 42, sw: 52, chim: 0.5)
        ]

        // Lamplight lies on the snow in front of the lit houses, in grain.
        if dark {
            for b in back + middle + front {
                let cx = b.x + (b.left ? b.sw * 0.3 : -b.sw * 0.3) * b.s, cy = b.y + 7 * b.s
                let rx = 62 * b.s, ry = 13 * b.s
                c.stipple(hx(0x7A5A4A), rows: (c.row(cy - ry), c.row(cy + ry)), key: 41, opacity: 0.7, grainMix: 0.2) { x, y in
                    let dx = (x - cx) / rx, dy = (y - cy) / ry
                    let d = dx * dx + dy * dy
                    return d > 1 ? 0 : Float((1 - d) * (1 - d)) * 0.62
                }
            }
        }

        var tops: [(x: Double, y: Double, s: Double)] = []
        c.paint { g in for b in back { villageHouse(g, b, inks, dark: dark, tops: &tops) } }

        // Small dark trees between the rows, so that no line of roofs runs on.
        let treeBody: PosterInk = dark ? hx(0x060A20) : hx(0x24475E), treeLit: PosterInk = dark ? hx(0x3C4E86) : hx(0xFFF8EC), treeShade: PosterInk = dark ? hx(0x1C2850) : hx(0xB6C4DE)
        c.spruces([(84, 1312, 60), (516, 1300, 58), (820, 1312, 70), (866, 1306, 92), (922, 1292, 60)], seed: 81, body: treeBody, lit: treeLit, shade: treeShade, shadow: inks.shadow, shadowOpacity: 0.6)

        // The church: the tall thing in the middle of it all.
        do {
            let lit = dark ? hx(0x2C2E48) : hx(0xFBF0DC), shade = dark ? hx(0x12142C) : hx(0xB6AAB2), side = dark ? hx(0x1C1E38) : hx(0xD8CCCA)
            c.paint { g in
                g.translateBy(x: -130, y: 0)
                // Nave, running back to the right.
                let bl = P(476, 1398), br = P(612, 1378), tl = P(476, 1320), tr = P(612, 1310)
                g.setFillColor(cg(inks.shadow))
                g.beginPath()
                lens(g, 650, 1392, 200, 8)
                g.fillPath()
                fill(g, side, [bl, br, tr, tl])
                fill(g, inks.eave, [tl, tr, P(612, 1316), P(476, 1328)])
                for i in 0..<4 {
                    let x = 492 + Double(i) * 30.0, y0 = 1378 - Double(i) * 3.2, y1 = 1336 - Double(i) * 2
                    fill(g, inks.frame, [P(x - 1, y0 + 1), P(x + 13, y0 + 1), P(x + 13, y1 + 6), P(x + 6, y1 - 2), P(x - 1, y1 + 6)])
                    fill(g, dark ? inks.pane : hx(0x4C627C), [P(x, y0), P(x + 12, y0), P(x + 12, y1 + 6), P(x + 6, y1), P(x, y1 + 6)])
                    fill(g, inks.frame, [P(x + 5.6, y0), P(x + 6.4, y0), P(x + 6.4, y1), P(x + 5.6, y1)])
                }
                // Its roof.
                var eave: [P] = []
                for i in 0...16 {
                    let u = Double(i) / 16
                    eave.append(P(470 + u * 156, 1322 - u * 10 + (i % 2 == 0 ? 1 : 3.4)))
                }
                fill(g, inks.roofLit, [P(478, 1262), P(616, 1264)] + eave.reversed())
                fill(g, inks.roofShade, [P(470, 1322), P(500, 1296), P(556, 1302), P(596, 1284), P(626, 1284), P(626, 1312)])
                // Its far end: a thin edge of snow, then the plain wall of the end.
                fill(g, shade, [P(612, 1378), P(622, 1374), P(622, 1312), P(612, 1312)])
                // The tower.
                fill(g, lit, [P(418, 1392), P(450, 1402), P(450, 1176), P(418, 1170)])
                fill(g, shade, [P(450, 1402), P(482, 1394), P(482, 1170), P(450, 1176)])
                // Bands, belfry, clock.
                fill(g, inks.eave, [P(418, 1170), P(450, 1176), P(482, 1170), P(482, 1178), P(450, 1184), P(418, 1178)])
                for y in [1250.0, 1320.0] {
                    fill(g, shade, [P(418, y), P(450, y + 6), P(450, y + 10), P(418, y + 4)])
                    fill(g, inks.eave, [P(450, y + 6), P(482, y), P(482, y + 4), P(450, y + 10)])
                }
                func arch(_ x0: Double, _ y0: Double, _ w: Double, _ hh: Double, _ dy: Double, _ ink: PosterInk) {
                    fill(g, ink, [P(x0, y0), P(x0 + w, y0 + dy), P(x0 + w, y0 + dy - hh + w * 0.4), P(x0 + w / 2, y0 + dy * 0.5 - hh), P(x0, y0 - hh + w * 0.4)])
                }
                arch(424, 1240, 8.5, 42, 1.6, inks.eave)
                arch(436, 1242, 8.5, 42, 1.6, inks.eave)
                arch(456, 1244, 8.5, 42, -1.6, dark ? inks.pane : inks.eave)
                arch(468, 1242, 8.5, 42, -1.6, dark ? inks.pane : inks.eave)
                // A door.
                arch(430, 1394, 14, 34, 3.4, inks.beam)
                // The spire, with a flared foot and the snow caught on it.
                fill(g, inks.spireLit, [P(450, 1020), P(450, 1182), P(412, 1174), P(424, 1148)])
                fill(g, inks.spireShade, [P(450, 1020), P(476, 1148), P(488, 1174), P(450, 1182)])
                fill(g, inks.roofLit, [P(412, 1174), P(424, 1146), P(434, 1132), P(438, 1148), P(444, 1140), P(450, 1158), P(450, 1182)])
                fill(g, inks.roofShade, [P(450, 1158), P(458, 1150), P(466, 1160), P(476, 1148), P(488, 1174), P(450, 1182)])
                fill(g, inks.roofLit, [P(442, 1092), P(447, 1062), P(450, 1050), P(450, 1098), P(446, 1104)])
                fill(g, inks.roofLit, [P(432, 1124), P(438, 1104), P(444, 1112), P(442, 1126)])
                // A plain finial.
                fill(g, inks.beam, [P(449.2, 994), P(450.8, 994), P(450.8, 1024), P(449.2, 1024)])
                g.setFillColor(cg(dark ? hx(0xC8A868) : hx(0xD8A850)))
                g.fillEllipse(in: CGRect(x: 446.6, y: 1006, width: 6.8, height: 6.8))
                // Snow at its foot.
                fill(g, inks.drift, [P(404, 1398), P(420, 1386), P(440, 1396), P(456, 1398), P(482, 1388), P(520, 1394), P(560, 1384), P(610, 1376), P(650, 1370), P(660, 1384), P(560, 1408), P(440, 1414)])
                g.translateBy(x: 130, y: 0)
            }
        }

        c.paint { g in for b in middle { villageHouse(g, b, inks, dark: dark, tops: &tops) } }
        c.spruces([(300, 1424, 52), (470, 1420, 62), (798, 1420, 86), (846, 1430, 60)], seed: 82, body: treeBody, lit: treeLit, shade: treeShade, shadow: inks.shadow, shadowOpacity: 0.6)
        c.paint { g in for b in front { villageHouse(g, b, inks, dark: dark, tops: &tops) } }
        var plumes: [(x: Double, y: Double, s: Double)] = []
        for (i, t) in tops.enumerated() where t.s > 0.9 && i % 3 == 0 { plumes.append(t) }
        c.smoke(plumes, ink: dark ? hx(0x2C3A68) : hx(0xFFFFFF), opacity: dark ? 0.3 : 0.34, seed: 91)

        // The road across, the stone bridge, and the stream coming down toward us.
        let bridgeX = 520.0, roadY = 1640.0
        let road: [P] = [P(-40, 1664), P(120, 1650), P(280, 1638), P(bridgeX, roadY), P(720, 1648), P(880, 1640), P(1040, 1618)]
        do {
            let top = PosterPlate(c) { g in
                var a: [P] = [], b: [P] = []
                var x = -40.0
                while x <= 1040 {
                    let y = curveY(road, x)
                    a.append(P(x, y - 8)); b.append(P(x, y + 10))
                    x += 8
                }
                fillPoly(g, a + b.reversed())
            }
            let rut = PosterPlate(c) { g in
                g.beginPath()
                var x = -40.0
                var r = SplitMix64(seed: 613)
                while x < 1040 {
                    let len = r.next(30, 120)
                    lens(g, x + len / 2, curveY(road, x + len / 2) + r.next(-3, 4), len, r.next(1, 2))
                    x += len + r.next(10, 60)
                }
                g.fillPath()
            }
            c.flat(dark ? hx(0x161E40) : hx(0xD8D4E2), plate: top)
            c.flat(dark ? hx(0x0C1230) : hx(0xB0B4CC), plate: rut, opacity: 0.8)

            let stream = ribbon([(x: bridgeX + 30, y: 1596, w: 3), (x: bridgeX + 14, y: 1618, w: 10), (x: bridgeX, y: roadY, w: 15), (x: bridgeX + 18, y: 1704, w: 22), (x: bridgeX + 62, y: 1772, w: 28), (x: bridgeX + 158, y: 1846, w: 36), (x: bridgeX + 204, y: 1944, w: 52), (x: bridgeX + 300, y: 2040, w: 76), (x: bridgeX + 352, y: 2160, w: 112), (x: bridgeX + 440, y: 2290, w: 160)])
            let bankP = PosterPlate(c) { g in fillPoly(g, stream.left.map { P($0.x - 6, $0.y + 1) } + stream.right.reversed().map { P($0.x + 8, $0.y + 3) }) }
            c.flat(dark ? hx(0x0C1430) : hx(0x9DAED0), plate: bankP)
            let water = PosterPlate(c) { g in fillPoly(g, stream.left + stream.right.reversed()) }
            c.pull(PosterRamp(dark ? [(0, hx(0x0C1A34)), (0.5, hx(0x081228)), (1, hx(0x040A1A))] : [(0, hx(0x5E88A8)), (0.5, hx(0x3D6A8A)), (1, hx(0x204A6A))], step: 0.6), plate: water, amp: 0.05, key: 29) { _, y in Float((y - 1520) / 600) }
            // Lit and dark marks on the water, wider as they near; a little ice along the edges.
            var r = SplitMix64(seed: 0xB7)
            let ripples = PosterPlate(c) { g in
                g.beginPath()
                var y = 1650.0
                while y < 2190 {
                    let d = (y - 1640) / 520
                    var x = 40.0 + r.next(0, 30)
                    while x < 1120 {
                        if r.next() < 0.55 { lens(g, x, y + r.next(-3, 3), r.next(10, 60) * (0.5 + 1.8 * d), r.next(0.7, 1.5) * (0.6 + 2.0 * d), tilt: r.next(-0.03, 0.03)) }
                        x += r.next(20, 80) * (0.6 + 1.6 * d)
                    }
                    y += r.next(9, 22) * (0.6 + 2 * d)
                }
                g.fillPath()
            }
            ripples.intersect(water)
            c.flat(dark ? hx(0x223458) : hx(0xBCD8E4), plate: ripples, opacity: dark ? 0.6 : 0.8)
            if dark {
                // The bridge's lamp and the houses, a little amber in the water under it.
                let amber = PosterPlate(c) { g in
                    g.beginPath()
                    var q = SplitMix64(seed: 0xB8)
                    var y = 1668.0
                    while y < 1820 {
                        lens(g, bridgeX - 18 + q.next(-10, 16) + (y - 1668) * 0.2, y, q.next(6, 22), q.next(0.8, 1.4))
                        y += q.next(5, 12)
                    }
                    g.fillPath()
                }
                amber.intersect(water)
                c.flat(hx(0xE0A052), plate: amber, opacity: 0.6)
            }

            // Where it comes from is behind a drift.
            let head = PosterPlate(c) { g in fillPoly(g, swell(x0: bridgeX - 90, x1: bridgeX + 260, y0: 1612, y1: 1588, a: 2.5, l: 60, p: 1.1, thick: 30)) }
            c.pull(snowRamp, plate: head, amp: 0.05, key: 3) { _, y in Float(snowTone(y) - 0.06) }
            // Stone bridge: one arch, a hump, snow along the top.
            let span = 68.0
            let stone = dark ? hx(0x20243E) : hx(0xB6AAA8), stoneShade = dark ? hx(0x10142C) : hx(0x7E7C8C), mortar = dark ? hx(0x0A0E22) : hx(0x8A8490)
            c.paint { g in
                let hump: (Double) -> Double = { x in roadY - 16 - 12 * max(0, 1 - pow((x - bridgeX) / span, 2)) }
                var top: [P] = []
                var x = bridgeX - span
                while x <= bridgeX + span {
                    top.append(P(x, hump(x)))
                    x += 6
                }
                let foot = roadY + 22.0
                fill(g, stone, top + [P(bridgeX + span + 6, foot), P(bridgeX - span - 6, foot)])
                // The arch.
                var arc: [P] = []
                for i in 0...16 {
                    let a = .pi * Double(i) / 16
                    arc.append(P(bridgeX - cos(a) * 34, foot - sin(a) * 30))
                }
                fill(g, dark ? hx(0x04081A) : hx(0x2F4C66), arc)
                // The inside of the arch, in shade.
                var inner: [P] = []
                for i in 0...16 {
                    let a = .pi * Double(i) / 16
                    inner.append(P(bridgeX - cos(a) * 34, foot - sin(a) * 30))
                }
                var ring: [P] = []
                for i in 0...16 {
                    let a = .pi * Double(16 - i) / 16
                    ring.append(P(bridgeX - cos(a) * 41, foot - sin(a) * 37))
                }
                fill(g, stoneShade, inner + ring)
                // Voussoirs and courses.
                g.setFillColor(cg(mortar))
                g.beginPath()
                for i in 1..<9 {
                    let a = .pi * Double(i) / 9
                    let x0 = bridgeX - cos(a) * 34, y0 = foot - sin(a) * 30, x1 = bridgeX - cos(a) * 41, y1 = foot - sin(a) * 37
                    g.move(to: CGPoint(x: x0 - 0.5, y: y0)); g.addLine(to: CGPoint(x: x1 - 0.5, y: y1)); g.addLine(to: CGPoint(x: x1 + 0.5, y: y1)); g.addLine(to: CGPoint(x: x0 + 0.5, y: y0)); g.closePath()
                }
                var q = SplitMix64(seed: 0xB9)
                for _ in 0..<22 {
                    let px = bridgeX + q.next(-span, span)
                    if abs(px - bridgeX) < 46 && q.next() < 0.8 { continue }
                    lens(g, px, q.next(hump(px) + 8, foot - 2), q.next(6, 16), q.next(1, 1.6))
                }
                g.fillPath()
                // The load of snow along the parapet, sagging over the sides.
                var upper: [P] = [], lower: [P] = []
                x = bridgeX - span - 12
                while x <= bridgeX + span + 12 {
                    let base = x < bridgeX - span || x > bridgeX + span ? hump(max(bridgeX - span, min(bridgeX + span, x))) + 4 : hump(x)
                    upper.append(P(x, base - 7 - q.next(0, 2.6)))
                    lower.append(P(x, base + 2 + q.next(0, 4)))
                    x += 7
                }
                fill(g, inks.roofLit, upper + lower.reversed())
            }
            // Snow heaped at the bridge's ends, the same snow as the ground.
            let mounds = PosterPlate(c) { g in
                let foot = roadY + 26
                fillPoly(g, swell(x0: bridgeX - span - 90, x1: bridgeX - 34, y0: foot, y1: foot + 6, a: 2, l: 19, p: 1, thick: 0).map { $0 } + [P(bridgeX - 40, foot + 12), P(bridgeX - span - 30, foot + 16)])
                var l: [P] = [P(bridgeX - span - 96, foot + 16)], rr: [P] = [P(bridgeX + span + 96, foot + 16)]
                for i in 0...10 {
                    let u = Double(i) / 10
                    l.append(P(bridgeX - span - 96 + u * 112, foot + 16 - 36 * sin(u * .pi / 2) * (0.9 + 0.1 * sin(u * 13))))
                    rr.append(P(bridgeX + span + 96 - u * 112, foot + 16 - 36 * sin(u * .pi / 2) * (0.9 + 0.1 * sin(u * 11))))
                }
                l.append(P(bridgeX - 36, foot + 16))
                rr.append(P(bridgeX + 36, foot + 16))
                fillPoly(g, l)
                fillPoly(g, rr)
            }
            c.pull(snowRamp, plate: mounds, amp: 0.05, key: 3) { _, y in Float(snowTone(y) - 0.08) }
            // Boulders in the stream, wearing snow.
            c.paint { g in
                var q = SplitMix64(seed: 0xBA)
                let rock: PosterInk = dark ? hx(0x070A1C) : hx(0x3A4258), rockLit: PosterInk = dark ? hx(0x14183A) : hx(0x6E7288)
                for (x, y, w): (Double, Double, Double) in [(bridgeX - 6, 1716, 12), (bridgeX + 190, 1846, 17), (bridgeX + 156, 1950, 22), (bridgeX + 352, 2050, 28)] {
                    var body: [P] = [], cap: [P] = [], under: [P] = []
                    let n = 9
                    for i in 0...n {
                        let u = Double(i) / Double(n)
                        let a = .pi + u * .pi
                        let k = q.next(0.8, 1.14)
                        let px = x + cos(a) * w * k, py = y + sin(a) * w * 0.62 * k
                        body.append(P(px, py))
                        cap.append(P(x - w * 0.08 + cos(a) * w * 1.02 * k, y - w * 0.04 + sin(a) * w * 0.66 * k))
                        under.append(P(x - w * 0.08 + cos(a) * w * (0.86 + 0.1 * sin(u * 9)), y - w * 0.3 + sin(a) * w * 0.24))
                    }
                    fill(g, rock, body + [P(x + w * 0.92, y + w * 0.14), P(x - w * 0.92, y + w * 0.14)])
                    fill(g, rockLit, body.map { P($0.x - w * 0.14, $0.y + w * 0.08) } + [P(x, y + w * 0.1), P(x - w * 0.8, y + w * 0.14)])
                    fill(g, inks.roofLit, cap + under.reversed())
                }
            }
        }

        // A few bare trees among the houses, their twigs against the snow.
        do {
            var r = SplitMix64(seed: 909)
            var woods: [[P]] = []
            for (x, y, tall, lean): (Double, Double, Double, Double) in [(348, 1520, 90, 0.12), (704, 1456, 96, 0.1)] {
                woods += PosterDraw.juniper(&r, x: x, base: y, height: tall, lean: lean).wood
            }
            let wood = PosterPlate(c) { g in for t in woods { fillPoly(g, t) } }
            c.flat(dark ? hx(0x070A1E) : hx(0x4A4656), plate: wood)
        }

        // Fence posts wandering along the road, with hats of snow.
        c.paint { g in
            var r = SplitMix64(seed: 717)
            var x = 40.0
            while x < 372 {
                let y = curveY(road, x) + 28 + 3 * sin(x / 90)
                let tall = r.next(19, 26)
                fill(g, dark ? hx(0x070A1C) : hx(0x4C3E46), [P(x - 2, y + 2), P(x - 1.6, y - tall), P(x + 1.6, y - tall), P(x + 2, y + 2)])
                fill(g, inks.roofLit, [P(x - 3, y - tall - 0.4), P(x - 1, y - tall - 3.2), P(x + 1.6, y - tall - 2.6), P(x + 3, y - tall - 0.2), P(x + 1.8, y - tall + 2), P(x - 2, y - tall + 2)])
                x += r.next(28, 78)
            }
        }

        // Long drifts in front. The stream cut has already been made; these stay to either side of it.
        struct Drift { var x0: Double, x1: Double, y0: Double, y1: Double, a: Double, l: Double, p: Double, belly: Double }
        for d in [Drift(x0: 700, x1: 1160, y0: 1790, y1: 1700, a: 5, l: 110, p: 0.7, belly: 58),
                  Drift(x0: -120, x1: 560, y0: 1760, y1: 1716, a: 5, l: 100, p: 2.4, belly: 66),
                  Drift(x0: 800, x1: 1190, y0: 1950, y1: 1860, a: 6, l: 120, p: 3.3, belly: 80),
                  Drift(x0: -160, x1: 620, y0: 1890, y1: 1862, a: 6, l: 120, p: 1.2, belly: 70),
                  Drift(x0: -200, x1: 716, y0: 2070, y1: 2010, a: 7, l: 150, p: 0.4, belly: 96)] {
            let t = PosterPlate(c) { g in fillPoly(g, swell(x0: d.x0, x1: d.x1, y0: d.y0, y1: d.y1, a: d.a, l: d.l, p: d.p, thick: d.belly)) }
            c.pull(snowRamp, plate: t, amp: 0.06, key: 28) { _, y in Float(snowTone(y) + 0.16) }
            let lip = PosterPlate(c) { g in fillPoly(g, swell(x0: d.x0, x1: d.x1, y0: d.y0, y1: d.y1, a: d.a, l: d.l, p: d.p, thick: d.belly * 0.18)) }
            c.pull(snowRamp, plate: lip, amp: 0.05, key: 30) { _, y in Float(snowTone(y) - 0.16) }
        }

        // The frame: the near spruces, heavy on the left.
        let nearBody: PosterInk = dark ? hx(0x030616) : hx(0x123048), nearLit: PosterInk = dark ? hx(0x34467A) : hx(0xFFFAF0), nearShade: PosterInk = dark ? hx(0x141E40) : hx(0x93A8CC)
        c.spruces([(830, 2084 - lift * 0.3, 430), (76, 2124 - lift * 0.3, 240)], seed: 83, body: dark ? hx(0x050A20) : hx(0x1E4058), lit: dark ? hx(0x2C3C6E) : hx(0xF6F0EC), shade: dark ? hx(0x121A3A) : hx(0xA4B4D2), shadow: inks.shadow, shadowOpacity: 0.7)
        do {
            var r = SplitMix64(seed: 84)
            let big = PosterDraw.snowSpruce(&r, x: 992, top: 1130, base: 2220, halfW: 196, tiers: 22, load: 1.1)
            for s in [big] {
                let bodyP = PosterPlate(c) { g in fillPoly(g, s.body) }
                c.flat(nearBody, plate: bodyP)
                let shadeP = PosterPlate(c) { g in for p in s.shade { fillPoly(g, p) } }
                c.flat(nearShade, plate: shadeP)
                let litP = PosterPlate(c) { g in for p in s.lit { fillPoly(g, p) } }
                c.flat(nearLit, plate: litP, offset: (c.reg, 0))
            }
        }

        // A last bank in shade across the foot of the sheet.
        do {
            var r = SplitMix64(seed: 504)
            let line: [P] = [P(-40, 2098), P(140, 2110), P(330, 2118), P(520, 2106), P(700, 2072), P(860, 2022), P(1040, 1968)].map { P($0.x, $0.y - lift) }
            let edge = cut(line, amp: 0.025, minLen: 16, rng: &r)
            let p = PosterPlate(c) { g in fillPoly(g, edge + [P(1040, 2300), P(-40, 2300)]) }
            let lip = PosterPlate(c) { g in fillPoly(g, edge + edge.reversed().map { P($0.x + 4, $0.y + 3.4 + 2.6 * sin($0.x / 47)) }) }
            c.pull(PosterRamp(dark ? [(0, hx(0x121C3E)), (0.5, hx(0x0B1230)), (1, hx(0x060A1E))] : [(0, hx(0x8498C8)), (0.5, hx(0x6A80B4)), (1, hx(0x4A5F98))], step: 0.6), plate: p, amp: 0.06, key: 31) { _, y in
                Float((y - 2040 + lift) / 130)
            }
            c.flat(dark ? hx(0x2A3A68) : hx(0xEDE8F2), plate: lip, opacity: dark ? 0.6 : 0.86)
        }

        c.finish(seed: 0x5A1, tooth: 0.05, mottle: 0.018, pinholes: dark ? 0.06 : 0.16, paper: hx(0xFFF6EA))
    }
}
