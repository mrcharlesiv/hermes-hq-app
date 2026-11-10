// Red desert: flat-topped rock under a very big sky. Design space x 0...1000, y 0...2168.

import CoreGraphics
import Foundation

private typealias P = PosterP

nonisolated extension Poster {
    static func mesa(_ c: PosterCanvas, dark: Bool) {
        var rng = SplitMix64(seed: 0x3E5A_0001)
        let lift = max(0, 2168 - c.bottomY) * 0.86

        // The sky: a long dissolve from deep cerulean through pale aqua into the hot air over the rock. At night, cool slate, so the warm rock stands off it.
        let skyStops: [(Double, PosterInk)] = dark
            ? [(0, hx(0x070A12)), (0.3, hx(0x0C101E)), (0.55, hx(0x141A2C)), (0.75, hx(0x1E2638)), (0.88, hx(0x2C3244)), (1, hx(0x4A3C48))]
            : [(0, hx(0x1F6390)), (0.2, hx(0x3D86AC)), (0.4, hx(0x79ADBB)), (0.58, hx(0xB9CFBF)), (0.74, hx(0xEEDAB2)), (0.88, hx(0xF9BE86)), (1, hx(0xF49A62))]
        c.pull(PosterRamp(skyStops, step: 1), amp: dark ? 0.03 : 0.042, key: 1, rows: (0, c.row(1480))) { x, y in
            Float((y - 180) / 1230)
        }
        if dark {
            PosterSky.stars2(c, until: 1160, bright: [(142, 232, 2.2), (402, 118, 1.6), (668, 300, 2.4), (246, 640, 1.7), (864, 170, 1.6)],
                             dots: hx(0xC4CCD8), big: hx(0xF0EEE4), count: 520, seed: 71)
        }

        // High flat clouds, few and long, stepping down toward the rock.
        do {
            var r = SplitMix64(seed: 0x57E5)
            let groups: [(Double, Double, Double, Double, Double)] = [
                (-150, 300, 640, 22, 8), (40, 410, 684, 12, 5), (-60, 170, 726, 8, 3),
                (560, 1140, 508, 15, 6), (720, 1100, 548, 9, 4)
            ]
            var bodies: [[P]] = []
            for g in groups { bodies.append(PosterCut.spindle(x0: g.0, x1: g.1, y: g.2, up: g.3, down: g.4, skew: 0.56, rng: &r)) }
            let body = PosterPlate(c) { g in for b in bodies { fillPoly(g, b) } }
            c.flat(dark ? hx(0x141826) : hx(0x8FB6C0), plate: body, opacity: dark ? 0.9 : 0.8)
            let lit = PosterPlate(c) { g in
                for b in bodies {
                    g.saveGState()
                    g.beginPath()
                    poly(g, b)
                    g.clip()
                    fillPoly(g, b.map { P($0.x - 8, $0.y - 5) })
                    g.restoreGState()
                }
            }
            c.flat(dark ? hx(0x1E2436) : hx(0xFFF3DC), plate: lit, opacity: dark ? 0.8 : 0.95)
        }

        // One big thunderhead behind the mesa, its sunny side to the left.
        let cloudRamp = PosterRamp(dark
            ? [(0, hx(0x0C0F1A)), (0.2, hx(0x121626)), (0.42, hx(0x1A2032)), (0.66, hx(0x262E42)), (0.86, hx(0x343C52)), (1, hx(0x4A5268))]
            : [(0, hx(0x5A79A6)), (0.2, hx(0x7E8EB4)), (0.4, hx(0xB4A0B6)), (0.58, hx(0xE9B8A4)), (0.76, hx(0xFBDCB6)), (1, hx(0xFFF7E6))], step: 0.5)
        let sunL = dark ? PosterLight(-0.62, -0.62, 0.48) : PosterLight(-0.8, -0.32, 0.5)
        let lx = sunL.x, ly = sunL.y
        let gi = 1 / (lx * lx + ly * ly).squareRoot()
        let shade: (Double, Double, Float, Float, Float, PosterBillow) -> Float = { x, y, ndl, form, _, b in
            let size = Float(b.ry / b.mry)
            let dxn = Float((x - b.x) / b.rx), dyn = Float((y - b.y) / b.ry)
            let away = -(dxn * lx + dyn * ly)
            let merge = 1 - sstep(0.0, 0.92, away)
            if dark {
                let fx = Float((x - b.mx) / b.mrx), fy = Float((y - b.my) / b.mry)
                let graze = (fx * lx + fy * ly) * gi
                let hold = 1 - 0.75 * sstep(0.2, 0.8, graze)
                let a = (0.05 + 0.2 * sstep(0.06, 0.4, size)) * hold
                let f = 0.66 * graze + 0.34 * form + a * (ndl - 0.55) * merge
                return 0.08 + sstep(-0.34, 0.66, f) * 0.32 + sstep(0.5, 0.94, f) * 0.3
            }
            let hold = 1 - 0.8 * sstep(0.42, 0.92, form)
            let a = (0.12 + 0.46 * sstep(0.06, 0.4, size)) * hold
            let f = form + a * (ndl - 0.55) * merge
            return 0.1 + sstep(-0.26, 0.92, f) * 0.9
        }
        var tower: [PosterBillow] = []
        let masses: [(x: Double, y: Double, rx: Double, ry: Double, inner: Int)] = [
            (760, 640, 120, 104, 8), (880, 700, 150, 130, 8), (664, 770, 110, 96, 8), (820, 852, 214, 150, 12),
            (600, 904, 104, 74, 8), (980, 880, 150, 150, 9), (720, 972, 240, 86, 12), (440, 980, 124, 44, 7), (940, 1010, 180, 80, 8)
        ]
        for m in masses { crownHeap(&tower, x: m.x, y: m.y, rx: m.rx, ry: m.ry, inner: m.inner, rng: &rng) }
        c.billows(tower, ramp: cloudRamp, amp: 0.03, key: 14, light: sunL, base: { x in 1062 + 5 * sin(x / 70) + 3 * sin(x / 23) }, shade: shade)
        // A smaller one to the left, far off, closing the V of the sky.
        var leftHeap: [PosterBillow] = []
        for m: (x: Double, y: Double, rx: Double, ry: Double, inner: Int) in [(70, 1020, 110, 62, 7), (-10, 1060, 120, 56, 6), (170, 1086, 92, 28, 5)] {
            crownHeap(&leftHeap, x: m.x, y: m.y, rx: m.rx, ry: m.ry, inner: m.inner, rng: &rng)
        }
        c.billows(leftHeap, ramp: cloudRamp, amp: 0.03, key: 15, light: sunL, base: { x in 1112 + 4 * sin(x / 60) + 2 * sin(x / 19) }, shade: shade)

        // Far mesas: two steps of air.
        func farMesa(_ pts: [P], ramp: PosterRamp, key: Int, from: Double, span: Double) {
            let line = cut(pts, amp: 0.02, minLen: 12, rng: &rng)
            let p = PosterPlate(c) { g in fillPoly(g, line + [P(line.last!.x, 1500), P(line.first!.x, 1500)]) }
            c.pull(ramp, plate: p, amp: 0.05, key: key) { _, y in Float((y - from) / span) }
        }
        farMesa([P(-30, 1262), P(40, 1256), P(62, 1188), P(170, 1182), P(196, 1250), P(272, 1262), P(300, 1214), P(392, 1208), P(420, 1270), P(560, 1276), P(1030, 1276)],
                ramp: PosterRamp(dark ? [(0, hx(0x3C1E30)), (1, hx(0x5C2E34))] : [(0, hx(0xDFA79C)), (1, hx(0xF7C49A))], step: 0.8), key: 6, from: 1180, span: 120)
        farMesa([P(-30, 1304), P(90, 1298), P(112, 1268), P(208, 1262), P(240, 1312), P(1030, 1322)],
                ramp: PosterRamp(dark ? [(0, hx(0x301730)), (1, hx(0x482434))] : [(0, hx(0xC88A88)), (1, hx(0xEDAE88))], step: 0.8), key: 7, from: 1260, span: 80)

        // The floor behind everything.
        let floorRamp = PosterRamp(dark
            ? [(0, hx(0x4C1E34)), (0.2, hx(0x3A1730)), (0.5, hx(0x281028)), (0.8, hx(0x1A0B1E)), (1, hx(0x0F0614))]
            : [(0, hx(0xF3B487)), (0.14, hx(0xE9925F)), (0.34, hx(0xD6703F)), (0.56, hx(0xB9502F)), (0.8, hx(0x8F3A30)), (1, hx(0x6E2A30))], step: 0.6)
        let floorBack = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: 1318, tilt: 0.01, waves: [(5, 90, 1.2), (2.5, 31, 0.4)], floorY: 2200)) }
        c.pull(floorRamp, plate: floorBack, amp: 0.05, key: 2) { _, y in Float((y - 1310) / 860) }

        // The rock, the same way a massif is cut: a big prow turns one wall to the sun and one away, buttresses fall from a flat top,
        // and every one of them is a lit face and a shadow face. Edges run to a vanishing point on the horizon, so it stands in space.
        let inkSet = dark
            ? PosterAlpInks(rockDeep: hx(0x16091F), rockShadow: hx(0x231030), rockMid: hx(0x441E38), rockLit: hx(0x642E3C),
                            snowDeep: hx(0x160926), snowShadow: hx(0x2A1336), snowMid: hx(0x56223E), snowLit: hx(0x8A3C42), snowTop: hx(0xA0483E), rim: hx(0xD08060))
            : PosterAlpInks(rockDeep: hx(0x331542), rockShadow: hx(0x4E1F50), rockMid: hx(0x8E363E), rockLit: hx(0xC6562F),
                            snowDeep: hx(0x3A1748), snowShadow: hx(0x5E2650), snowMid: hx(0xAE3F30), snowLit: hx(0xF19654), snowTop: hx(0xE6622C), rim: hx(0xFFDDAE))
        func aired(_ i: PosterAlpInks, _ air: PosterInk, _ t: Double) -> PosterAlpInks {
            PosterAlpInks(rockDeep: i.rockDeep.mixed(with: air, t), rockShadow: i.rockShadow.mixed(with: air, t), rockMid: i.rockMid.mixed(with: air, t), rockLit: i.rockLit.mixed(with: air, t),
                          snowDeep: i.snowDeep.mixed(with: air, t), snowShadow: i.snowShadow.mixed(with: air, t), snowMid: i.snowMid.mixed(with: air, t), snowLit: i.snowLit.mixed(with: air, t), snowTop: i.snowTop.mixed(with: air, t), rim: i.rim)
        }
        func arete(_ pts: [P], h: Double, k: Double = 1.2, fade: Double = 0.5, rampIn: Double = 0.1) -> PosterRidge {
            PosterAlp.ridge(pts, h: h, k: k, amp: 0.05, len: 18, fade: fade, rampIn: rampIn, rng: &rng)
        }
        func formation(skyline: [P], top: Double, foot: Double, wall: Double, levels: [[PosterRidge]], ribs: [PosterRidge], inks: PosterAlpInks, air: PosterInk, airOp: Float, seed: UInt32, key: Int) -> PosterPlate {
            var style = PosterAlpStyle(light: PosterLight(-0.8, -0.32, 0.5), inks: inks, rockLine: 0.42, rockWidth: 70)
            style.thrLit = 0.54
            style.thrMid = 0.3
            let line = cut(skyline, amp: 0.016, minLen: 12, rng: &rng)
            let mask = PosterAlp.paint(c, skyline: line, bottom: foot + 34, top: top, foot: foot, slope: 0.36, levels: levels, rockRidges: [(ribs, 1)], style: style,
                                       warmLine: { x in wall + 6 * sin(x / 37) }, tint: nil, seed: seed, key: key)
            // Dust settles round the foot and takes the rock away grain by grain.
            let from = wall + (foot - wall) * 0.25
            c.stipple(air, plate: mask, rows: (c.row(from), c.row(foot + 36)), key: key + 40, opacity: 1, grainMix: 0.46) { x, y in
                let w = 10 * sin(x / 83 + Double(key)) + 5 * sin(x / 29)
                return airOp * Float(dsstep(from + w, foot + 10, y))
            }
            return mask
        }

        let dust = dark ? hx(0x3C1A2E) : hx(0xF3B487)

        // A far butte and its needle on the left.
        do {
            let inks = aired(inkSet, dark ? hx(0x3C1E32) : hx(0xF0A67E), 0.42)
            let prow = arete([P(116, 1092), P(120, 1160), P(114, 1250), P(128, 1400)], h: 170, k: 0.98, fade: 0.8, rampIn: 0.02)
            let second = [arete([P(66, 1110), P(60, 1180), P(44, 1290)], h: 26), arete([P(158, 1104), P(164, 1190), P(176, 1280)], h: 30), arete([P(214, 1120), P(222, 1180), P(238, 1300)], h: 22)]
            let ribs = [arete([P(30, 1250), P(10, 1330), P(-10, 1400)], h: 26), arete([P(164, 1270), P(186, 1330), P(214, 1410)], h: 28)]
            _ = formation(skyline: [P(-60, 1380), P(-16, 1300), P(10, 1240), P(16, 1176), P(24, 1128), P(38, 1112), P(116, 1092), P(200, 1102), P(232, 1112), P(238, 1132), P(244, 1190), P(262, 1262), P(304, 1340), P(350, 1400)],
                          top: 1092, foot: 1400, wall: 1240, levels: [[prow], second, ribs], ribs: ribs, inks: inks, air: dust, airOp: 0.92, seed: 81, key: 41)
            // The needle stands clear of it.
            let needleInks = aired(inkSet, dark ? hx(0x3C1E32) : hx(0xF0A67E), 0.3)
            let spine = arete([P(292, 1062), P(296, 1140), P(290, 1250), P(304, 1400)], h: 40, k: 0.98, fade: 0.9, rampIn: 0.02)
            _ = formation(skyline: [P(250, 1400), P(268, 1320), P(278, 1250), P(280, 1180), P(278, 1110), P(284, 1072), P(292, 1062), P(304, 1068), P(310, 1104), P(312, 1170), P(322, 1254), P(338, 1330), P(362, 1400)],
                          top: 1062, foot: 1400, wall: 1270, levels: [[spine]], ribs: [], inks: needleInks, air: dust, airOp: 0.9, seed: 83, key: 43)
        }

        // The hero: a prow at x 566, a sunny wall running back to the left, a long shadowed wall running back to the right and off the sheet.
        let prowX = 566.0
        @Sendable func wallY(_ y0: Double, _ x: Double) -> Double {
            let d = x - prowX
            return d < 0 ? y0 + (-d) * (1300 - y0) / 1820 : y0 + d * (1300 - y0) / 3300
        }
        let heroTop = 904.0, heroWall = 1226.0, heroFoot = 1470.0
        var heroLine: [P] = [P(0, 1486), P(90, 1460), P(176, 1420), P(240, 1370), P(286, 1312), P(316, 1252), P(332, 1204), P(338, 1130), P(344, 1056), P(350, 1000), P(354, 968), P(364, 950), P(376, wallY(heroTop, 376))]
        for x: Double in [440, 500, 540] { heroLine.append(P(x, wallY(heroTop, x) + (x == 500 ? 3 : 0))) }
        heroLine.append(P(prowX, heroTop))
        for x: Double in [640, 720, 792] { heroLine.append(P(x, wallY(heroTop, x))) }
        // The rim runs on back, settling a little lower, with no bite in it.
        for (x, drop): (Double, Double) in [(846, 3), (902, 5), (968, 11), (1060, 15)] { heroLine.append(P(x, wallY(heroTop, x) + drop)) }
        let prow = arete([P(prowX, heroTop), P(prowX + 5, 1010), P(prowX - 4, 1120), P(prowX + 8, heroWall), P(prowX + 28, 1340), P(prowX + 54, 1500)], h: 500, k: 0.98, fade: 0.86, rampIn: 0.01)
        func butt(_ x: Double, _ len: Double, _ h: Double, drift: Double = 0) -> PosterRidge {
            let t = wallY(heroTop, x)
            return arete([P(x, t), P(x + rng.next(-4, 4), t + len * 0.36), P(x + drift * 0.5 + rng.next(-5, 5), t + len * 0.72), P(x + drift, t + len)], h: h, k: 1.25, fade: 0.55, rampIn: 0.04)
        }
        var second: [PosterRidge] = [
            // On the sunny wall: only a few, to crack it.
            butt(384, 260, 16), butt(404, 110, 18), butt(486, 300, 22), butt(534, 150, 26),
            // On the shadow wall: noses that catch the sun, at uneven spacing, long and short.
            butt(612, 300, 44, drift: 8), butt(640, 120, 30), butt(668, 250, 52, drift: 10), butt(722, 150, 26), butt(826, 330, 82, drift: 14), butt(850, 110, 28),
            butt(884, 220, 40, drift: 12), butt(936, 120, 24), butt(1014, 320, 72, drift: 20)
        ]
        // Ribs of the talus: flaring, far apart.
        let ribs: [PosterRidge] = [
            arete([P(344, 1226), P(304, 1320), P(240, 1400), P(176, 1490)], h: 34, fade: 0.6),
            arete([P(404, 1236), P(376, 1320), P(330, 1400), P(286, 1500)], h: 76, fade: 0.6),
            arete([P(530, 1236), P(536, 1320), P(530, 1400), P(530, 1500)], h: 40, fade: 0.6),
            arete([P(700, 1272), P(722, 1340), P(748, 1410), P(780, 1500)], h: 30, fade: 0.5),
            arete([P(846, 1262), P(872, 1330), P(910, 1410), P(960, 1500)], h: 24, fade: 0.5),
            arete([P(968, 1270), P(996, 1340), P(1040, 1420)], h: 26, fade: 0.5)
        ]
        second += ribs
        var third: [PosterRidge] = []
        for r in second { third += spurs(of: r, count: 2, length: 20...64, hFrac: 0.42, k: 1.5, from: 0.1, to: 0.86, spread: 22...46, cutLen: 14, rng: &rng) }
        let heroMask = formation(skyline: heroLine, top: heroTop, foot: heroFoot, wall: heroWall, levels: [[prow], second, third], ribs: ribs, inks: inkSet, air: dust, airOp: 0.86, seed: 93, key: 44)

        // Bedding: thin cut ledges, darker across the walls, a pale bench or two, heavier across the talus. They follow the walls back in perspective.
        func bedding(_ list: [(y0: Double, n: Int, len: ClosedRange<Double>, th: ClosedRange<Double>)], _ ink: PosterInk, _ op: Double, x0: Double = 300, x1: Double = 1050, seed: UInt64) {
            var r = SplitMix64(seed: seed)
            let p = PosterPlate(c) { g in
                g.beginPath()
                for l in list {
                    for _ in 0..<l.n {
                        let x = r.next(x0, x1), len = r.next(l.len.lowerBound, l.len.upperBound)
                        let mid = wallY(l.y0, x), end = wallY(l.y0, x + len * 0.5), start = wallY(l.y0, x - len * 0.5)
                        let tilt = (end - start) / len
                        lens(g, x, mid + r.next(-1.5, 1.5), len, r.next(l.th.lowerBound, l.th.upperBound), tilt: tilt)
                    }
                }
                g.fillPath()
            }
            p.intersect(heroMask)
            c.flat(ink, plate: p, opacity: op)
        }
        // The cap: one dark course right under the rim, broken up by a band of cracks.
        do {
            let cap = PosterPlate(c) { g in
                var top: [P] = [], bot: [P] = []
                var x = 330.0
                while x < 1070 {
                    let t = wallY(heroTop, x)
                    top.append(P(x, t - 6))
                    bot.append(P(x, t + 15 + 3.2 * sin(x / 19) + 2 * sin(x / 7.3)))
                    x += 5
                }
                fillPoly(g, top + bot.reversed())
            }
            cap.intersect(heroMask)
            c.flat(dark ? hx(0x0E0614) : hx(0x4A1B48), plate: cap, opacity: dark ? 0.5 : 0.42)
        }
        bedding([(986, 14, 24...74, 1.4...3), (1040, 18, 20...84, 1.2...2.8), (1104, 15, 24...90, 1.2...2.8), (1170, 18, 20...76, 1.4...3)], dark ? hx(0x12081C) : hx(0x5A2048), dark ? 0.42 : 0.34, x0: 356, seed: 11)
        bedding([(1250, 16, 24...70, 2...4.5), (1282, 14, 24...76, 2.5...5), (1316, 14, 28...84, 2.5...5.5), (1356, 10, 28...90, 2.5...5.5)], dark ? hx(0x12081C) : hx(0x7A2C3A), 0.2, x0: 100, seed: 12)
        bedding([(1212, 8, 20...64, 1.6...3), (1266, 8, 20...64, 2...3.2), (1302, 8, 20...70, 2...3.2)], dark ? hx(0x7E4040) : hx(0xFFD7A2), 0.2, x0: 100, x1: prowX - 30, seed: 13)
        bedding([(1212, 8, 30...100, 1.4...3), (1266, 6, 30...110, 1.6...3.4)], dark ? hx(0x2E1626) : hx(0x8C4052), 0.2, x0: prowX + 20, seed: 14)

        // The near floor runs in over the rock's foot.
        let horizonFloor = 1466.0
        let floorFront = PosterPlate(c) { g in fillPoly(g, PosterCut.wavyBand(y: horizonFloor, tilt: 0.012, waves: [(7, 130, 0.6), (3, 41, 2.0)], floorY: 2200)) }
        @Sendable func floorTone(_ x: Double, _ y: Double) -> Double { (y - 1420) / 750 + 0.1 }
        c.pull(floorRamp, plate: floorFront, amp: 0.05, key: 3) { x, y in Float(floorTone(x, y)) }

        // Long swells of ground: a trough and a lit shoulder, far apart and very low.
        struct Swell { var x0: Double, x1: Double, y0: Double, y1: Double, a: Double, l: Double, p: Double, belly: Double }
        let swells: [Swell] = [
            Swell(x0: -120, x1: 560, y0: 1560, y1: 1536, a: 3, l: 90, p: 1.0, belly: 34),
            Swell(x0: 380, x1: 1160, y0: 1640, y1: 1606, a: 4, l: 110, p: 2.5, belly: 44),
            Swell(x0: -140, x1: 640, y0: 1760, y1: 1716, a: 5, l: 130, p: 3.6, belly: 60),
            Swell(x0: 300, x1: 1180, y0: 1880, y1: 1840, a: 6, l: 150, p: 4.4, belly: 74),
            Swell(x0: -160, x1: 700, y0: 2030, y1: 1970, a: 7, l: 180, p: 0.6, belly: 90)
        ]
        func swellPts(_ s: Swell, thick: Double) -> [P] {
            var top: [P] = [], under: [P] = []
            var u = 0.0
            while u <= 1.0001 {
                let x = s.x0 + (s.x1 - s.x0) * u
                let cy = s.y0 + (s.y1 - s.y0) * u + s.a * sin(x / s.l + s.p) + s.a * 0.4 * sin(x / (s.l * 0.37) + s.p * 2.3)
                top.append(P(x, cy))
                under.append(P(x, cy + thick * pow(sin(.pi * pow(u, 0.8)), 1.5)))
                u += 0.012
            }
            return top + under.reversed()
        }
        for s in swells {
            let trough = PosterPlate(c) { g in fillPoly(g, swellPts(s, thick: s.belly)) }
            c.pull(floorRamp, plate: trough, amp: 0.05, key: 26) { x, y in Float(floorTone(x, y) + 0.07) }
            let shoulder = PosterPlate(c) { g in fillPoly(g, swellPts(s, thick: s.belly * 0.32)) }
            c.pull(floorRamp, plate: shoulder, amp: 0.05, key: 27) { x, y in Float(floorTone(x, y) - 0.06) }
        }

        // The hero's shadow lies on the floor to its right.
        let cast = PosterPlate(c) { g in
            fillPoly(g, [P(600, horizonFloor - 2), P(1040, horizonFloor - 10), P(1040, 1596), P(960, 1578), P(880, 1566), P(780, 1524), P(690, 1512), P(640, 1484)])
        }
        c.flat(dark ? hx(0x0C0512) : hx(0x4E2054), plate: cast, opacity: dark ? 0.6 : 0.46)

        // A dry wash winds out of the rock's foot toward the viewer: pale sand, one dark bank, one lit one.
        do {
            let spine: [(x: Double, y: Double, w: Double)] = [
                (520, horizonFloor + 8, 3), (604, 1500, 7), (660, 1538, 12), (590, 1590, 18), (470, 1640, 24), (452, 1704, 34), (590, 1774, 48), (700, 1852, 66), (610, 1950, 88), (392, 2040, 118), (250, 2150, 160), (200, 2260, 200)
            ]
            var l: [P] = [], r: [P] = []
            let steps = 14
            for i in 0..<(spine.count - 1) {
                let a = spine[max(0, i - 1)], b = spine[i], d = spine[i + 1], e = spine[min(spine.count - 1, i + 2)]
                for s in 0..<steps {
                    let t = Double(s) / Double(steps), t2 = t * t, t3 = t2 * t
                    let x = 0.5 * (2 * b.x + (d.x - a.x) * t + (2 * a.x - 5 * b.x + 4 * d.x - e.x) * t2 + (3 * b.x - a.x - 3 * d.x + e.x) * t3)
                    let y = 0.5 * (2 * b.y + (d.y - a.y) * t + (2 * a.y - 5 * b.y + 4 * d.y - e.y) * t2 + (3 * b.y - a.y - 3 * d.y + e.y) * t3)
                    let w = b.w + (d.w - b.w) * t
                    let wob = 1 + 0.16 * sin(y / 23) + 0.1 * sin(y / 9.1 + x / 40)
                    l.append(P(x - w * wob, y + 2 * sin(x / 17)))
                    r.append(P(x + w * wob * 0.92, y - 2 * sin(x / 13)))
                }
            }
            let bank = PosterPlate(c) { g in fillPoly(g, l.map { P($0.x - 5, $0.y + 3) } + r.reversed().map { P($0.x + 9, $0.y + 5) }) }
            c.flat(dark ? hx(0x0D0612) : hx(0x5C2046), plate: bank, opacity: dark ? 0.8 : 0.72)
            let bed = PosterPlate(c) { g in fillPoly(g, l + r.reversed()) }
            let sand = PosterRamp(dark ? [(0, hx(0x5E2E3A)), (0.5, hx(0x412134)), (1, hx(0x261428))] : [(0, hx(0xF6CFA0)), (0.5, hx(0xE29C6E)), (1, hx(0xBC6C4E))], step: 0.7)
            c.pull(sand, plate: bed, amp: 0.06, key: 29) { _, y in Float((y - 1470) / 640) }
            // Ripple marks in the sand.
            var rr = SplitMix64(seed: 0xAA)
            let ripple = PosterPlate(c) { g in
                g.beginPath()
                var y = 1500.0
                while y < 2200 {
                    let d = (y - 1470) / 700
                    var x = -30 + rr.next(0, 40)
                    while x < 1040 {
                        lens(g, x, y + rr.next(-3, 3), rr.next(22, 90) * (0.4 + 1.6 * d), rr.next(0.8, 1.6) * (0.5 + 2.8 * d), tilt: rr.next(-0.04, 0.04))
                        x += rr.next(30, 90) * (0.5 + 1.5 * d)
                    }
                    y += rr.next(5, 10) * (0.6 + 2.6 * d)
                }
            }
            ripple.intersect(bed)
            c.flat(dark ? hx(0x170C20) : hx(0xC97F62), plate: ripple, opacity: dark ? 0.5 : 0.55)
        }

        // Scrub: clumps, not dice. Mostly small, a few big, and only the near ones have a lit top.
        do {
            let n = GradientNoise(seed: 311)
            var body: [(Double, Double, Double)] = []
            var r = SplitMix64(seed: 312)
            var y = horizonFloor + 8
            while y < 2190 {
                let d = (y - horizonFloor) / 700
                var x = -20 + r.next(0, 20)
                while x < 1030 {
                    let keep = n.fbm(x / 170, y / (24 + 120 * d), octaves: 2)
                    if keep + r.next(-0.12, 0.12) > 0.27 {
                        let dice = r.next()
                        let size = dice < 0.7 ? r.next(1.2, 2.4) : (dice < 0.95 ? r.next(2.4, 3.8) : r.next(3.8, 5.4))
                        body.append((x, y + r.next(-2, 2), size * (0.5 + 3.8 * d)))
                    }
                    x += r.next(10, 30) * (0.45 + 3.0 * d)
                }
                y += r.next(3.5, 7) * (0.5 + 3.6 * d)
            }
            func lump(_ g: CGContext, _ t: (Double, Double, Double), _ r: inout SplitMix64, rx: Double, ry: Double, dx: Double = 0, dy: Double = 0) {
                let (x, y, s) = t
                let n = 11
                var pts: [P] = []
                for i in 0...n {
                    let a = .pi + Double(i) / Double(n) * .pi
                    let k = r.next(0.72, 1.12)
                    pts.append(P(x + dx * s + cos(a) * s * rx * k, y + dy * s + sin(a) * s * ry * k))
                }
                pts.append(P(x + dx * s + s * rx * 0.5, y + dy * s + s * 0.16))
                pts.append(P(x + dx * s - s * rx * 0.5, y + dy * s + s * 0.16))
                fillPoly(g, pts)
            }
            let shadowsP = PosterPlate(c) { g in
                g.beginPath()
                for t in body { lens(g, t.0 + t.2 * 1.5, t.1 + t.2 * 0.12, t.2 * 4.2, t.2 * 0.3) }
                g.fillPath()
            }
            c.flat(dark ? hx(0x0B0410) : hx(0x5A2046), plate: shadowsP, opacity: dark ? 0.6 : 0.4)
            var rr = SplitMix64(seed: 313)
            let bodyP = PosterPlate(c) { g in for t in body { lump(g, t, &rr, rx: 1.7, ry: 1.0) } }
            c.flat(dark ? hx(0x160C22) : hx(0x4C3A34), plate: bodyP)
            let midP = PosterPlate(c) { g in for t in body where t.2 > 3.2 { lump(g, t, &rr, rx: 1.24, ry: 0.74, dx: -0.36, dy: -0.24) } }
            c.flat(dark ? hx(0x241A2C) : hx(0x75603F), plate: midP, offset: (c.reg, 0))
            let litP = PosterPlate(c) { g in for t in body where t.2 > 6.4 { lump(g, t, &rr, rx: 0.7, ry: 0.42, dx: -0.6, dy: -0.46) } }
            c.flat(dark ? hx(0x30243A) : hx(0xAD9A5E), plate: litP, offset: (c.reg, 0))
        }

        // Small outcrops in the middle ground on the right, echoing the big one: a sunny face, a shadow face, a few courses.
        do {
            func outcrop(_ x: Double, _ y: Double, _ w: Double, _ h: Double, seed: UInt64) {
                var r = SplitMix64(seed: seed)
                let j = { (v: Double, r: inout SplitMix64) in v * r.next(0.9, 1.1) }
                let prowT = P(x - w * j(0.1, &r), y - h)
                let leftT = P(x - w * 0.44, y - h * 0.9), rightT = P(x + w * 0.42, y - h * 0.86)
                let leftB = P(x - w * 0.5, y - h * j(0.44, &r)), rightB = P(x + w * 0.5, y - h * j(0.4, &r))
                let foot0 = P(x - w * 0.82, y + 2), foot1 = P(x + w * 0.84, y + 2)
                let prowB = P(prowT.x + w * 0.06, y - h * 0.34), prowF = P(prowT.x + w * 0.14, y + 2)
                c.paint { g in
                    let shadowI = dark ? hx(0x1C0E26) : hx(0x4E1F50), wallI = dark ? hx(0x743436) : hx(0xE2662E), talusI = dark ? hx(0x5C2C36) : hx(0xEF9352), lineI = dark ? hx(0x0E0614) : hx(0x7A2C3A), rimI = dark ? hx(0xB8705A) : hx(0xFFD6A4)
                    // Its shadow on the floor first.
                    g.setFillColor(cg(dark ? hx(0x0B0410) : hx(0x4E2054)))
                    g.beginPath()
                    lens(g, x + w * 1.05, y + 4, w * 1.9, 5, tilt: 0.01)
                    g.fillPath()
                    fill(g, shadowI, [foot0, leftB, leftT, prowT, rightT, rightB, foot1])
                    fill(g, talusI, [foot0, leftB, prowB, prowF])
                    fill(g, wallI, [leftB, leftT, prowT, prowB])
                    fill(g, rimI, [leftT, prowT, P(prowT.x, prowT.y + 2.2), P(leftT.x, leftT.y + 2.6)])
                    // Courses.
                    g.setFillColor(cg(lineI))
                    g.beginPath()
                    for i in 1...3 {
                        let t = Double(i) * 0.22
                        let ya = y - h * (1 - t) + h * 0.04, yb = y - h * (1 - t) + (i == 3 ? -1 : 2)
                        lens(g, (leftB.x + prowB.x) * 0.5, (ya + yb) * 0.5, w * r.next(0.34, 0.52), 1.8, tilt: -0.12)
                    }
                    g.fillPath()
                }
            }
            outcrop(838, 1650, 150, 96, seed: 1)
            outcrop(948, 1672, 110, 62, seed: 2)
            outcrop(748, 1664, 74, 42, seed: 3)
            outcrop(120, 1600, 86, 44, seed: 4)
        }

        // The foreground, lifted if the frame crops the bottom: a rock shelf and agaves.
        var r3 = SplitMix64(seed: 509)
        let shelf = [P(-40, 1884), P(70, 1892), P(150, 1916), P(238, 1934), P(330, 1982), P(450, 2030), P(610, 2056), P(760, 2034), P(880, 1982), P(960, 1950), P(1040, 1940)].map { P($0.x, $0.y - lift) }
        let inkFg = dark ? hx(0x07030C) : hx(0x2C1136), inkLit = dark ? hx(0x1E1022) : hx(0x70304A), rimFg = dark ? hx(0x402230) : hx(0xEE9458)
        PosterForeground.ledge(c, line: shelf, foot: 2168, deep: inkFg, ledge: inkLit, rim: rimFg, ledges: 80, reach: 150, rng: &r3)
        c.paint { g in
            for (x, y, s): (Double, Double, Double) in [(828, 1972, 74), (912, 1946, 50), (752, 2010, 40)] {
                PosterDraw.agave(g, x: x, y: y - lift, size: s, dark: inkFg, lit: dark ? hx(0x1A1426) : hx(0x4F6650), rng: &r3)
            }
        }

        c.finish(seed: 0xE5A, tooth: 0.05, mottle: 0.018, pinholes: dark ? 0.06 : 0.16, paper: hx(0xFFF3DC))
    }
}
