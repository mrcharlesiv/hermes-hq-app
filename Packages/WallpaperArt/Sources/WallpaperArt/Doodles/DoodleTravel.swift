// The Travel drawings. Spot colours: 0 is coral, 1 is sand, 2 is ocean; bare paper is sun-bleached white.
// Every building is a made-up one: no landmark, airline, or country is meant by anything here.

import CoreGraphics
import Foundation

nonisolated enum DoodleTravel {
    typealias K = DoodleKit

    static func all() -> [DoodleGlyph] {
        var list = [suitcase(), propPlane(), palmIsland(), camera(), sailboat(), liner(), balloon(), camper(), rowHouses(), passport(), lighthouse(), scooter(),
                    boardingPass(), foldedMap(), compassRose(), windmill(), domeHouse(), marketStall(), aviators(), train(), globe(), backpack(), sunHat(), flipFlops(),
                    beachBall(), umbrellaChair(), surfboard(), iceCream(), coconut(), pineapple(), starfish(), crab(), turtle(), fish(), anchor(), lifebuoy(), postcard(), stamp(),
                    luggageTag(), hotelKey(), neckPillow(), sunscreen(), guideBook(), coins(), cactus(), toucan(), gull(), cloud(), wetTicket(), shellPair(),
                    dashTrail(), tinyPlane(), tinyWave(), tinyShell(), tinyX(), tinyGull(), tinyStar(), tinyDrop()]
        list += DoodleFillers.common().filter { ["dot"].contains($0.name) }
        list += extras() + littles()
        for i in list.indices {
            list[i].fixed = true
            list[i].done()
        }
        return list
    }

    static func suitcase() -> DoodleGlyph {
        var g = DoodleGlyph("suitcase", 0.26, 0.44, tilt: 8)
        g.must = true
        // Handle, then a stitched old case with straps, corners and stickers from nowhere in particular.
        g.line("^46,18 46,4 52,-2 ^80,-2 86,4 ^86,18", 1.45)
        g.line("^54,18 54,8 ^78,8 ^78,18", 0.7)
        g.shape(0, .rrect(0, 16, 132, 92, 7), 1.6)
        g.line(.rrect(5, 21, 122, 82, 4), 0.5)
        // Two leather straps and buckles.
        for x in [28.0, 92.0] {
            g.shape(1, "^\(x),15 ^\(x + 12),15 ^\(x + 12),108 ^\(x),108 z", 1)
            g.shape(-1, .rrect(x - 2, 30, 16, 12, 2), 0.85)
            g.line(.poly([(x + 6, 30), (x + 6, 42)]), 0.55)
        }
        // Corners.
        for (x0, y0, sx, sy) in [(0.0, 16.0, 1.0, 1.0), (132.0, 16.0, -1.0, 1.0), (0.0, 108.0, 1.0, -1.0), (132.0, 108.0, -1.0, -1.0)] {
            g.shape(1, .poly([(x0, y0 + sy * 16), (x0, y0), (x0 + sx * 16, y0)], closed: true), 0.95)
        }
        // Stickers: a sun-and-sea roundel, a pennant, a star tag.
        g.shape(-1, .circle(62, 64, 17), 1.05)
        g.tint(2, "^46,70 56,66 66,70 ^78,66 74,78 62,81 50,78 z")
        g.line("^46,70 56,66 66,70 ^78,66", 0.5)
        g.shape(1, .circle(62, 58, 6.4), 0.7)
        g.shape(-1, "^108,60 ^128,68 ^108,78 z", 0.85)
        g.shape(2, "^108,60 ^114,62.4 ^114,75 ^108,78 z", 0.6)
        g.shape(-1, .rrect(8, 68, 18, 24, 2), 0.85)
        g.shape(2, DoodleFillers.starPath(17, 80, 6.4), 0.6)
        g.detail(0.22) { g in
            g.stitch("^44,24 ^88,24", dash: 2.2, gap: 2, w: 0.45)
            g.stitch("^44,100 ^88,100", dash: 2.2, gap: 2, w: 0.45)
            g.hatch("^44,86 ^88,86 ^88,98 ^44,98 z", angle: 60, gap: 3.2, w: 0.42)
            g.gel("^44,30 ^56,30", 1)
            g.blot(.circle(7, 23, 1.3))
            g.blot(.circle(125, 23, 1.3))
            g.blot(.circle(7, 101, 1.3))
            g.blot(.circle(125, 101, 1.3))
        }
        // Feet.
        g.blot(.rrect(14, 108, 12, 5, 1.5))
        g.blot(.rrect(106, 108, 12, 5, 1.5))
        return g
    }

    static func propPlane() -> DoodleGlyph {
        var g = DoodleGlyph("propPlane", 0.26, 0.46, tilt: 14)
        g.must = true
        // A chubby high-wing bush plane heading right.
        g.shape(1, "^12,8 ^6,4 ^0,8 ^6,42 ^20,44 z", 1.3)
        g.shape(0, "^4,44 22,38 60,32 98,34 124,44 ^132,54 128,64 98,72 56,74 26,66 ^4,52 z", 1.6)
        g.tint(-1, "^6,50 ^130,54 ^129,62 104,70 56,72 26,64 ^4,52 z")
        g.line("^6,50 40,52 ^130,54", 0.65)
        // Tailplane.
        g.shape(1, "^0,48 ^-12,44 ^-12,58 ^18,58 z", 1.1)
        // Cabin windows.
        g.shape(2, "^88,36 ^104,36 ^116,48 ^88,48 z", 1)
        g.line("^96,36 ^96,48", 0.6)
        for x in [40.0, 56.0, 72.0] { g.shape(2, .rrect(x, 37, 10, 11, 3), 0.75) }
        // Engine cowl and propeller.
        g.shape(1, "^122,42 134,46 ^140,54 134,62 ^122,66 z", 1.25)
        g.shape(-1, .ellipse(148, 54, 3.5, 26), 1)
        g.shape(-1, .ellipse(140, 54, 3, 3), 0.8)
        // Wing strut, wing over the top, a wheel and spat.
        g.line("^70,14 ^86,50", 1)
        g.line("^78,14 ^88,50", 0.7)
        g.line("^84,72 ^92,88", 1.15)
        g.line("^48,72 ^40,88", 1.15)
        g.shape(1, .circle(92, 92, 7.6), 1.1)
        g.shape(1, .circle(40, 92, 7.6), 1.1)
        g.shape(0, "^38,4 ^126,6 ^130,16 ^38,16 ^32,10 z", 1.45)
        g.line("^60,5 ^60,16", 0.55)
        g.line("^104,6 ^104,16", 0.55)
        g.detail(0.24) { g in
            g.blot(.circle(92, 92, 1.7))
            g.blot(.circle(40, 92, 1.7))
            g.stitch("^18,62 44,68 ^90,66", dash: 2.2, gap: 2, w: 0.42)
            g.gel("^30,40 ^40,37", 0.9)
            g.line("^112,34 ^120,28 ^124,34", 0.5)
            g.hatch("^74,60 ^122,58 ^100,68 ^76,68 z", angle: 66, gap: 3, w: 0.42)
        }
        // Motion dashes behind.
        g.line("^-30,28 ^-14,30", 0.8)
        g.line("^-32,72 ^-10,70", 0.8)
        return g
    }

    static func palmIsland() -> DoodleGlyph {
        var g = DoodleGlyph("palmIsland", 0.24, 0.46, tilt: 5)
        g.must = true
        // Water, a low sand bar, a leaning palm with heavy fronds, coconuts, a tiny crab.
        g.shape(1, "^4,98 20,90 56,84 96,88 ^122,98 104,106 56,110 20,106 z", 1.45)
        g.shape(1, DoodlePath.taper([(58, 90), (64, 64), (76, 38), (84, 22)], 11, 6), 1.3)
        g.detail(0.2) { g in
            for t in stride(from: 0.1, through: 0.9, by: 0.14) {
                let x = 58 + t * 26, y = 90 - t * 68
                g.line(.poly([(x - 4 + t * 2, y - 1), (x + 5 - t * 2, y + 1)]), 0.42)
            }
        }
        // Fronds, each with a notched edge.
        func frond(_ g: inout DoodleGlyph, _ a: (Double, Double), _ m: (Double, Double), _ b: (Double, Double), sep: Int) {
            let dx = b.0 - a.0, dy = b.1 - a.1
            let l = hypot(dx, dy)
            let nx = -dy / l, ny = dx / l
            var nodes: [DoodlePath.Node] = [.init(x: a.0, y: a.1, corner: true)]
            nodes.append(.init(x: m.0 + nx * -9, y: m.1 + ny * -9, corner: false))
            nodes.append(.init(x: b.0, y: b.1, corner: true))
            var cut = SplitMix64(seed: UInt64(abs(b.0 * 7 + b.1 * 13)) + 90)
            var t = 0.86
            while t > 0.1 {
                let s: (Double, Double) = ((1 - t) * (1 - t) * a.0 + 2 * t * (1 - t) * m.0 + t * t * b.0, (1 - t) * (1 - t) * a.1 + 2 * t * (1 - t) * m.1 + t * t * b.1)
                let reach = cut.next(4.6, 9.4) * (0.55 + 0.6 * t * (1.6 - t))
                let back = cut.next(0.4, 2.8)
                let slip = cut.next(0.9, 3.6)
                nodes.append(.init(x: s.0 + nx * reach + (a.0 - b.0) / l * -slip, y: s.1 + ny * reach + (a.1 - b.1) / l * -slip, corner: true))
                nodes.append(.init(x: s.0 + nx * back, y: s.1 + ny * back, corner: true))
                t -= cut.next(0.1, 0.21)
            }
            g.shape(sep, DoodlePath(nodes: nodes, closed: true), 1.2)
            g.line(.spline([a, m, b]), 0.55)
        }
        frond(&g, (84, 24), (70, 2), (34, 10), sep: 2)
        frond(&g, (84, 24), (104, -2), (132, 18), sep: 2)
        frond(&g, (84, 24), (52, 20), (32, 50), sep: 0)
        frond(&g, (84, 24), (116, 22), (134, 56), sep: 0)
        frond(&g, (84, 24), (82, -8), (62, -16), sep: 2)
        g.shape(1, .circle(78, 32, 5.2), 0.95)
        g.shape(1, .circle(90, 34, 5), 0.95)
        // Ripples under the bar.
        g.line("^-8,112 8,108 ^26,112", 0.8)
        g.line("^94,114 110,110 ^132,114", 0.8)
        g.line("^40,118 58,114 ^78,118", 0.7)
        g.detail(0.2) { g in
            g.speckle(22, 92, 104, 104, n: 14, r: 0.55, seed: 21)
        }
        return g
    }

    static func camera() -> DoodleGlyph {
        var g = DoodleGlyph("camera", 0.2, 0.4, tilt: 12)
        g.must = true
        // An old rangefinder hanging from its strap.
        g.line("^6,28 2,18 16,6 56,1 96,6 110,18 ^106,28", 1.05)
        g.line("^10,28 7,20 18,11 ^38,7", 0.65)
        g.shape(1, "^34,22 ^46,14 ^76,14 ^86,22 z", 1.15)
        g.shape(1, .rrect(10, 16, 16, 8, 1.5), 1)
        g.shape(0, .rrect(0, 22, 112, 70, 5), 1.55)
        g.shape(-1, .rrect(0, 22, 112, 17, 3), 1.15)
        // Dials and finder.
        g.shape(2, .rrect(64, 26, 15, 10, 1.5), 0.8)
        g.shape(1, .rrect(86, 25, 18, 12, 2), 0.85)
        g.line(.circle(95, 31, 3), 0.42)
        g.blot(.circle(10, 31, 2))
        g.blot(.circle(20, 31, 1.6))
        // The lens.
        g.shape(1, .circle(52, 62, 28), 1.5)
        g.shape(1, .circle(52, 62, 21), 0.8)
        g.shape(2, .circle(52, 62, 15), 0.9)
        g.accent(.circle(52, 62, 8.4))
        g.gel("44,56 47,52 ^52,50", 0.9)
        g.gel("^60,70 ^62,66", 0.6)
        g.detail(0.2) { g in
            for i in 0..<28 {
                let a = Double(i) * 360 / 28
                g.line(.poly([K.polar(52, 62, 23, a), K.polar(52, 62, 27, a)]), 0.42)
            }
            g.speckle(6, 44, 22, 88, n: 16, r: 0.5, seed: 31)
            g.speckle(86, 44, 106, 88, n: 16, r: 0.5, seed: 32)
        }
        return g
    }

    static func sailboat() -> DoodleGlyph {
        var g = DoodleGlyph("sailboat", 0.22, 0.44, tilt: 8)
        g.must = true
        // Two sails, a striped mainsail, a hull riding a wave.
        g.line("^56,-8 ^56,92", 1.3)
        g.shape(0, "^56,-8 ^62,-4 ^60,0 ^56,0 z", 0.8)
        g.shape(-1, "^60,4 88,30 106,60 ^112,82 ^60,82 z", 1.5)
        g.tint(0, "^60,28 ^92,36 ^102,52 ^60,46 z")
        g.tint(0, "^60,62 ^109,70 ^112,82 ^60,82 z")
        g.line("^60,28 ^92,36", 0.6)
        g.line("^60,46 ^102,52", 0.6)
        g.line("^60,62 ^109,70", 0.6)
        g.shape(-1, "^52,12 30,44 ^14,82 ^52,82 z", 1.4)
        g.shape(2, "^52,44 ^30,44 ^22,62 ^52,62 z", 0.75)
        g.shape(1, "^4,88 ^122,88 ^112,110 100,116 ^22,116 12,110 z", 1.55)
        g.tint(2, "^6,94 ^119,94 ^116,102 ^10,102 z")
        g.line("^6,94 ^119,94", 0.6)
        g.line("^10,102 ^116,102", 0.6)
        g.detail(0.2) { g in
            for x in [36.0, 58.0, 80.0] { g.line(.circle(x, 98, 2.4), 0.45) }
            g.gel("^72,34 ^84,52", 0.9)
        }
        // Waves.
        g.shape(2, "^-12,118 4,110 22,118 40,110 58,118 76,110 94,118 112,110 ^136,118 ^136,128 ^-12,128 z", 1.25)
        g.line("^0,124 ^18,124", 0.42)
        g.line("^90,124 ^116,124", 0.42)
        return g
    }

    static func liner() -> DoodleGlyph {
        var g = DoodleGlyph("liner", 0.22, 0.44, tilt: 6)
        // A little ocean liner with stacked decks, two raked funnels and a run of portholes.
        for (x, s) in [(66.0, 0), (96.0, 0)] {
            g.shape(s, "^\(x),8 ^\(x + 18),8 ^\(x + 14),44 ^\(x - 4),44 z", 1.35)
            g.shape(1, "^\(x),8 ^\(x + 18),8 ^\(x + 17),16 ^\(x - 1),16 z", 0.8)
        }
        // Smoke drifting off.
        g.shape(-1, K.puff(62, -6, 9, 7, n: 6), 0.85)
        g.shape(-1, K.puff(44, -12, 7, 5, n: 5), 0.75)
        g.shape(-1, K.puff(90, -4, 7, 6, n: 5), 0.75)
        g.shape(-1, .rrect(34, 42, 96, 16, 2), 1.3)
        g.shape(-1, .rrect(20, 56, 136, 16, 2), 1.3)
        for x in stride(from: 42.0, through: 122.0, by: 10) { g.line(.rrect(x, 46, 5, 8, 1), 0.5) }
        for x in stride(from: 28.0, through: 148.0, by: 9.6) { g.blot(.rrect(x, 60, 4.6, 8, 1)) }
        g.shape(0, "^0,70 ^178,66 168,104 ^20,104 z", 1.55)
        g.tint(-1, "^2,78 ^176,74 ^175,80 ^4,84 z")
        g.line("^2,78 ^176,74", 0.55)
        g.line("^4,84 ^175,80", 0.55)
        g.tint(2, "^14,96 ^170,96 ^168,104 ^20,104 z")
        g.line("^14,96 ^170,96", 0.6)
        for x in stride(from: 26.0, through: 156.0, by: 18) { g.shape(1, .circle(x, 90, 2.8), 0.5) }
        g.line("^-8,108 12,104 34,108 ^56,104", 0.8)
        g.line("^120,108 142,104 164,108 ^188,104", 0.8)
        g.line("^50,114 ^86,112", 0.6)
        return g
    }

    static func balloon() -> DoodleGlyph {
        var g = DoodleGlyph("balloon", 0.15, 0.42, tilt: 6)
        g.noFlip = true
        // A striped hot air balloon, a wicker basket, a sandbag.
        g.shape(0, "50,0 80,8 98,34 96,62 78,90 ^60,106 ^40,106 22,90 4,62 2,34 20,8 z", 1.6)
        g.tint(-1, "50,0 62,4 70,34 68,62 60,90 ^54,106 ^46,106 40,90 32,62 30,34 38,4 z")
        g.tint(1, "^80,8 98,34 96,62 78,90 ^60,106 ^60,90 ^78,62 ^80,34 z")
        g.tint(2, "^20,8 2,34 4,62 22,90 ^40,106 ^40,90 ^22,62 ^20,34 z")
        g.line("50,0 38,4 30,34 32,62 40,90 ^46,106", 0.7)
        g.line("50,0 62,4 70,34 68,62 60,90 ^54,106", 0.7)
        g.line("^40,106 ^60,106", 0)
        g.detail(0.2) { g in
            g.line("^3,48 28,52 50,53 72,52 ^97,48", 0.5)
            g.gel("^12,34 ^20,16", 1.1)
            g.hatch("^74,50 ^92,42 ^88,72 ^72,88 z", angle: 66, gap: 3, w: 0.42)
        }
        g.line("^42,106 ^40,120", 0.7)
        g.line("^58,106 ^60,120", 0.7)
        g.line("^46,106 ^46,120", 0.5)
        g.line("^54,106 ^54,120", 0.5)
        g.shape(1, "^36,120 ^64,120 ^62,140 ^38,140 z", 1.35)
        g.line("^37,127 ^63,127", 0.5)
        g.line("^38,134 ^62,134", 0.5)
        for x in [43.0, 50.0, 57.0] { g.line(.poly([(x, 120), (x, 140)]), 0.42) }
        g.line("^64,124 ^72,130", 0.6)
        g.shape(-1, "^68,130 ^78,130 ^78,142 ^68,142 z", 0.75)
        return g
    }

    static func camper() -> DoodleGlyph {
        var g = DoodleGlyph("camper", 0.26, 0.46, tilt: 5)
        g.must = true
        // A rounded camper van, two-tone, a surfboard on the roof. No maker's badge.
        g.shape(0, "^18,12 ^122,6 ^132,4 ^128,14 ^22,20 z", 1.2)
        g.line("^40,18 ^40,26", 0.9)
        g.line("^100,14 ^100,24", 0.9)
        g.shape(-1, "^12,70 8,38 18,26 ^124,24 142,30 152,56 ^156,70 z", 1.6)
        g.shape(0, "^6,64 ^156,64 158,88 150,98 ^10,98 2,88 z", 1.55)
        // The big front window, side windows, door.
        g.shape(2, "^122,32 138,34 146,54 ^122,54 z", 1)
        for x in [28.0, 58.0, 88.0] { g.shape(2, .rrect(x, 34, 24, 20, 3.5), 1) }
        g.line("^56,34 ^56,92", 0)
        g.line("^112,28 ^112,92", 0.7)
        g.line("^86,64 ^86,92", 0.55)
        g.blot(.rrect(102, 70, 6, 2.6, 1))
        g.shape(1, .ellipse(150, 74, 5.4, 5.4), 1)
        g.shape(1, .rrect(-4, 88, 16, 6, 2), 0.95)
        g.shape(1, .rrect(148, 88, 18, 6, 2), 0.95)
        // Wheels.
        for x in [36.0, 124.0] {
            g.accent(.circle(x, 98, 15))
            g.shape(1, .circle(x, 98, 11), 1)
            g.shape(-1, .circle(x, 98, 5.4), 0.8)
            g.blot(.circle(x, 98, 1.5))
        }
        g.detail(0.24) { g in
            g.gel("^34,38 ^40,38", 0.8)
            g.gel("^126,38 ^132,38", 0.8)
            g.stitch("^6,72 ^150,72", dash: 2.2, gap: 2, w: 0.42)
            g.line("^60,10 ^60,17", 0.42)
            g.line("^72,9.4 ^72,16", 0.42)
            g.shape(1, DoodleFillers.starPath(70, 80, 6), 0.5)
            g.line("^-12,114 ^172,114", 0.5)
        }
        return g
    }

    static func rowHouses() -> DoodleGlyph {
        var g = DoodleGlyph("rowHouses", 0.16, 0.42, tilt: 4)
        g.noFlip = true
        // Four tall skinny canal-side houses with different gables and awnings; made up.
        func house(_ g: inout DoodleGlyph, x: Double, w: Double, top: Double, roof: DoodlePath, sep: Int, trim: Int) {
            let b = 118.0
            g.shape(sep, .poly([(x, top), (x + w, top), (x + w, b), (x, b)], closed: true), 1.35)
            g.shape(trim, roof, 1.25)
            var y = top + 8
            while y < b - 34 {
                let n = w > 28 ? 2 : 1
                for i in 0..<n {
                    let wx = n == 1 ? x + w / 2 - 5 : x + 5 + Double(i) * (w - 20) + (i == 1 ? 0 : 0)
                    g.shape(-1, .rrect(wx, y, 10, 13, 1.5), 0.72)
                    g.line(.poly([(wx + 5, y), (wx + 5, y + 13)]), 0.42)
                }
                y += 21
            }
            // An awning over the door.
            g.shape(trim, .poly([(x + 3, b - 32), (x + w - 3, b - 32), (x + w, b - 22), (x, b - 22)], closed: true), 0.85)
            g.blot(.rrect(x + w / 2 - 5, b - 20, 10, 20, 1.5))
        }
        house(&g, x: 0, w: 28, top: 34, roof: "^-2,34 ^30,34 ^14,10 z", sep: 0, trim: 1)
        house(&g, x: 28, w: 34, top: 18, roof: "^26,18 ^26,10 ^34,10 ^34,2 ^44,2 ^44,-8 ^46,-8 ^46,2 ^56,2 ^56,10 ^64,10 ^64,18 z", sep: 1, trim: 0)
        house(&g, x: 62, w: 26, top: 40, roof: "^60,40 ^90,40 ^88,26 ^62,26 z", sep: 2, trim: 1)
        house(&g, x: 88, w: 32, top: 26, roof: "^86,26 88,12 104,2 120,12 ^122,26 z", sep: 0, trim: 2)
        g.line("^-8,118 ^128,118", 1.1)
        g.line("^-6,126 10,123 ^26,126", 0.6)
        g.line("^62,126 80,123 ^100,126", 0.6)
        return g
    }

    static func passport() -> DoodleGlyph {
        var g = DoodleGlyph("passport", 0.16, 0.36, tilt: 20)
        // A worn booklet with a plain globe on the cover and a ticket sticking out. No nation named.
        g.shape(1, "^60,-6 ^92,4 ^78,34 ^50,24 z", 1.1)
        g.line("^60,6 ^78,12", 0.5)
        g.line("^56,14 ^72,20", 0.5)
        g.shape(-1, .rrect(6, 8, 78, 110, 3), 1)
        g.shape(2, .rrect(0, 4, 78, 110, 4), 1.55)
        g.line(.rrect(5, 9, 68, 100, 2), 0.55)
        g.shape(1, .circle(39, 52, 21), 1.1)
        g.line(.ellipse(39, 52, 9.4, 21), 0.55)
        g.line("^18,52 ^60,52", 0.55)
        g.line("^21,41 ^57,41", 0.5)
        g.line("^21,63 ^57,63", 0.5)
        g.line("^18,88 ^60,88", 1.1)
        g.line("^26,97 ^52,97", 0.65)
        g.shape(1, DoodleFillers.starPath(39, 20, 4.6), 0.55)
        return g
    }

    static func lighthouse() -> DoodleGlyph {
        var g = DoodleGlyph("lighthouse", 0.22, 0.44, tilt: 4)
        g.must = true
        g.noFlip = true
        // A striped tower on rocks, a gallery rail, a lamp room with a cone roof; no beams, just a small glow.
        g.shape(0, "^38,-6 ^44,-14 ^50,-6 ^64,10 ^24,10 z", 1.35)
        g.blot(.circle(44, -15, 1.6))
        g.shape(1, .rrect(26, 10, 36, 24, 1.5), 1.3)
        g.line("^38,10 ^38,34", 0.6)
        g.line("^50,10 ^50,34", 0.6)
        g.shape(-1, .rrect(16, 32, 56, 6, 1.5), 1.1)
        for x in stride(from: 20.0, through: 68.0, by: 8) { g.line(.poly([(x, 26), (x, 32)]), 0.5) }
        g.line("^16,26 ^72,26", 0.6)
        g.shape(-1, "^24,38 ^64,38 ^78,136 ^10,136 z", 1.6)
        g.tint(0, "^26.6,56 ^61.4,56 ^65,82 ^23,82 z")
        g.tint(0, "^19.6,108 ^68.4,108 ^72,134 ^16,134 z")
        for (a, b) in [(56.0, 56.0), (82.0, 82.0), (108.0, 108.0)] {
            let t = (a - 38) / 98
            g.line(.poly([(24 - 14 * t, a), (64 + 14 * t, b)]), 0.7)
        }
        g.shape(2, .rrect(38, 62, 12, 14, 6), 0.85)
        g.shape(2, .rrect(38, 90, 12, 12, 6), 0.8)
        g.shape(1, .rrect(36, 116, 16, 20, 7), 0.95)
        g.detail(0.2) { g in
            g.hatch("^56,44 ^64,44 ^76,132 ^62,132 z", angle: 80, gap: 3.2, w: 0.42)
            g.gel("^30,44 ^28,54", 1)
        }
        // Rocks and water.
        g.shape(1, "^-12,136 ^4,124 ^22,134 ^44,128 ^66,134 ^86,122 ^104,136 ^114,146 ^-22,146 z", 1.35)
        g.line("^12,132 ^20,142", 0.5)
        g.line("^80,130 ^90,142", 0.5)
        g.shape(2, "^-30,146 -14,140 2,146 18,140 34,146 50,140 66,146 82,140 98,146 114,140 ^130,146 ^130,156 ^-30,156 z", 1.2)
        // A gull on the wing.
        g.line("^86,12 94,6 ^102,12 110,6 ^118,12", 0.75)
        return g
    }

    static func scooter() -> DoodleGlyph {
        var g = DoodleGlyph("scooter", 0.12, 0.34, tilt: 5)
        g.noTuck = true
        // A rounded little scooter with a crate on the back and a mirror.
        g.shape(1, .circle(24, 88, 15), 1.4)
        g.shape(-1, .circle(24, 88, 8), 0.9)
        g.blot(.circle(24, 88, 2))
        g.shape(1, .circle(112, 88, 15), 1.4)
        g.shape(-1, .circle(112, 88, 8), 0.9)
        g.blot(.circle(112, 88, 2))
        // The rear pod and footboard sweep into the leg shield.
        g.shape(0, "^4,76 4,56 18,42 46,40 58,50 ^60,74 ^88,74 ^96,20 ^108,20 ^116,70 ^118,84 ^92,90 ^48,90 ^24,84 z", 1.6)
        g.shape(0, "^98,70 106,62 124,64 ^132,78 ^92,78 z", 1.3)
        g.line("^14,62 ^52,60", 0.6)
        // The seat.
        g.shape(1, "^10,34 42,30 ^62,32 66,40 ^16,44 z", 1.3)
        // Handlebars, headlamp, mirror.
        g.line("^98,20 ^88,10", 1.2)
        g.line("^88,10 ^78,12", 1.5)
        g.shape(1, .ellipse(110, 22, 7, 8), 1.1)
        g.shape(-1, .ellipse(112, 22, 4, 5), 0.7)
        g.line("^94,12 ^92,-8", 0.75)
        g.shape(2, .ellipse(92, -12, 6.4, 5), 0.8)
        // The back crate.
        g.line("^4,30 ^16,30", 0)
        g.shape(1, .rrect(-14, 8, 30, 24, 1.5), 1.2)
        for x in [-6.0, 2.0, 10.0] { g.line(.poly([(x, 8), (x, 32)]), 0.5) }
        g.line("^-14,20 ^16,20", 0.5)
        g.shape(2, K.leaf((-2, 8), (-10, -8), belly: 7), 0.7)
        g.shape(2, K.leaf((4, 8), (10, -8), belly: 7), 0.7)
        g.detail(0.2) { g in
            g.gel("^12,54 ^22,46", 1)
            g.gel("^100,30 ^102,54", 0.9)
            g.stitch("^62,82 ^92,82", dash: 2, gap: 2, w: 0.5)
        }
        return g
    }

    static func boardingPass() -> DoodleGlyph {
        var g = DoodleGlyph("boardingPass", 0.15, 0.36, tilt: 18)
        g.noFlip = true
        g.shape(-1, "^0,0 ^128,0 ^128,20 122,26 ^128,32 ^128,58 ^0,58 z", 1.45)
        g.tint(2, "^0,0 ^128,0 ^128,13 ^0,13 z")
        g.line("^0,13 ^128,13", 0.7)
        g.stitch("^94,14 ^94,58", dash: 2.4, gap: 2, w: 0.65)
        // A route, a plane, some barcode. Letters are only strokes.
        g.line("^10,24 ^30,24", 1)
        g.line("^60,24 ^82,24", 1)
        g.stitch("^34,24 ^56,24", dash: 2, gap: 1.6, w: 0.6)
        g.shape(0, "^46,17 ^50,17 ^52,23 ^60,25 ^52,27 ^50,32 ^46,32 ^48,27 ^42,27 ^40,30 ^37,30 ^39,25 ^37,20 ^40,20 ^42,23 ^48,23 z", 0.55)
        g.line("^10,38 ^44,38", 0.55)
        g.line("^10,46 ^34,46", 0.55)
        for (i, w) in [1.1, 0.5, 0.8, 0.5, 1.2, 0.5, 0.7, 1.1, 0.5, 0.8].enumerated() {
            let x = 100 + Double(i) * 2.4
            g.line(.poly([(x, 24), (x, 52)]), w * 0.75)
        }
        g.line("^50,38 ^84,38", 0.55)
        g.line("^60,46 ^84,46", 0.55)
        g.shape(0, DoodleFillers.starPath(110, 7, 4.2), 0.45)
        return g
    }

    static func foldedMap() -> DoodleGlyph {
        var g = DoodleGlyph("foldedMap", 0.18, 0.4, tilt: 14)
        // Three panels folded, a made-up coast, a dashed route ending at a cross.
        g.shape(-1, "^0,10 ^40,0 ^80,10 ^120,0 ^120,88 ^80,98 ^40,88 ^0,98 z", 1.5)
        g.tint(2, "^0,10 ^40,0 ^52,3 40,20 44,44 24,56 18,76 ^0,82 z")
        g.tint(2, "^92,7 ^120,0 ^120,56 100,44 88,28 z")
        g.tint(1, "^40,0 ^52,3 40,20 44,44 24,56 18,76 ^0,82 ^0,98 ^40,88 ^80,98 ^120,88 ^120,56 100,44 88,28 ^92,7 ^80,10 z")
        g.line("^52,3 40,20 44,44 24,56 18,76 ^0,82", 0.75)
        g.line("^92,7 88,28 100,44 ^120,56", 0.75)
        g.line("^40,0 ^40,88", 0.7)
        g.line("^80,10 ^80,98", 0.7)
        g.detail(0.16) { g in
            g.hatch("^80,10 ^120,0 ^120,88 ^80,98 z", angle: 80, gap: 4.4, w: 0.4)
            g.line("^6,40 ^14,36", 0.42)
            g.line("^8,52 ^16,48", 0.42)
            g.line("^100,16 ^110,14", 0.42)
        }
        g.stitch("^30,76 52,54 ^62,62 ^78,36 ^96,62", dash: 3, gap: 2.4, w: 0.85)
        g.line("^91,66 ^101,76", 1.15)
        g.line("^101,66 ^91,76", 1.15)
        g.blot(.circle(30, 76, 2.6))
        return g
    }

    static func compassRose() -> DoodleGlyph {
        var g = DoodleGlyph("compassRose", 0.15, 0.36, tilt: 22)
        // A hand-drawn wind rose in a brass ring with a loop, the north point in coral.
        g.line(.circle(50, -8, 6), 1)
        g.shape(1, .circle(50, 50, 48), 1.5)
        g.shape(-1, .circle(50, 50, 40), 1)
        g.detail(0.16) { g in
            for i in 0..<16 {
                let a = Double(i) * 22.5
                g.line(.poly([K.polar(50, 50, 40, a), K.polar(50, 50, i % 4 == 0 ? 34 : 37, a)]), 0.5)
            }
        }
        for i in 0..<4 {
            let a = 45.0 + Double(i) * 90
            let t = K.polar(50, 50, 24, a), l = K.polar(50, 50, 7, a - 45), r = K.polar(50, 50, 7, a + 45)
            g.shape(2, .poly([t, l, r], closed: true), 0.65)
        }
        for i in 0..<4 {
            let a = -90.0 + Double(i) * 90
            let t = K.polar(50, 50, 34, a), l = K.polar(50, 50, 7.6, a - 45), r = K.polar(50, 50, 7.6, a + 45)
            g.shape(i == 0 ? 0 : -1, .poly([t, l, r], closed: true), 0.9)
            g.line(.poly([t, (50, 50)]), 0.42)
        }
        g.blot(.circle(50, 50, 2.4))
        return g
    }

    static func windmill() -> DoodleGlyph {
        var g = DoodleGlyph("windmill", 0.13, 0.38, tilt: 5)
        g.noFlip = true
        // A plain tapering tower with a cap, four lattice sails, grass.
        g.shape(-1, "^28,44 ^72,44 ^86,120 ^14,120 z", 1.5)
        g.shape(0, "^24,46 32,24 ^50,14 68,24 ^76,46 z", 1.4)
        g.shape(1, .rrect(40, 94, 20, 26, 8), 1.05)
        g.line("^50,94 ^50,120", 0.5)
        g.shape(2, .circle(50, 72, 7), 0.85)
        g.line("^50,65 ^50,79", 0.42)
        for i in 0..<4 {
            let a = Double(i) * 90 + 28
            let tip = K.polar(50, 36, 56, a)
            g.line(.poly([(50, 36), tip]), 1.15)
            let n1 = K.polar(tip.0, tip.1, 12, a + 90), n0 = K.polar(50, 36, 12, a)
            let p0 = K.polar(n0.0, n0.1, 12, a + 90)
            g.shape(-1, .poly([n0, p0, n1, tip], closed: true), 0.75)
            g.detail(0.16) { g in
                for t in [0.25, 0.5, 0.75] {
                    let s0 = (n0.0 + (tip.0 - n0.0) * t, n0.1 + (tip.1 - n0.1) * t)
                    let s1 = (p0.0 + (n1.0 - p0.0) * t, p0.1 + (n1.1 - p0.1) * t)
                    g.line(.poly([s0, s1]), 0.42)
                }
            }
        }
        g.blot(.circle(50, 36, 3))
        g.line("^-8,120 ^108,120", 1)
        for (x, c) in [(0.0, -3.0), (8.0, 3.0), (94.0, -2.0), (104.0, 3.0)] { g.line(.poly([(x, 120), (x + c, 112)]), 0.55) }
        return g
    }

    static func domeHouse() -> DoodleGlyph {
        var g = DoodleGlyph("domeHouse", 0.16, 0.38, tilt: 5)
        g.noFlip = true
        // A whitewashed village on a hill, one blue dome, a bell arch. A dream of the south, nowhere real.
        g.shape(1, "^-8,110 8,92 30,84 60,82 92,86 ^118,104 ^122,120 ^-12,120 z", 1.35)
        g.shape(-1, .rrect(52, 50, 54, 44, 2), 1.3)
        g.shape(-1, .rrect(8, 38, 46, 56, 2), 1.4)
        g.shape(2, "^4,40 8,18 30,2 52,18 ^58,40 z", 1.5)
        g.line("^30,2 ^30,-10", 1)
        g.line("^25,-5 ^35,-5", 1)
        g.line("^16,38 18,20 ^30,4", 0.5)
        g.line("^44,38 42,20 ^30,4", 0.5)
        g.shape(-1, "^68,50 ^68,30 76,20 84,30 ^84,50 z", 1.1)
        g.blot("^72,46 ^72,32 76,27 80,32 ^80,46 z")
        g.shape(1, .circle(76, 39, 2.6), 0.42)
        g.shape(2, .rrect(18, 62, 12, 32, 6), 0.95)
        g.shape(2, .rrect(36, 54, 8, 14, 4), 0.7)
        g.shape(2, .rrect(62, 62, 9, 14, 4.5), 0.7)
        g.shape(2, .rrect(86, 62, 9, 14, 4.5), 0.7)
        g.shape(0, "^64,94 ^70,82 ^78,94 z", 0.6)
        g.line("^4,100 ^28,96", 0.42)
        g.line("^74,104 ^100,104", 0.42)
        g.line("^0,114 ^40,112", 0.42)
        return g
    }

    static func marketStall() -> DoodleGlyph {
        var g = DoodleGlyph("marketStall", 0.16, 0.38, tilt: 5)
        g.noFlip = true
        // A striped awning, baskets of fruit, a hanging string of lamps.
        g.line("^6,28 ^6,118", 1.3)
        g.line("^114,28 ^114,118", 1.3)
        for i in 0..<6 {
            let x = -2 + Double(i) * 20.7
            g.shape(i % 2 == 0 ? 0 : -1, .poly([(8 + Double(i) * 17.3, 0), (8 + Double(i + 1) * 17.3, 0), (x + 20.7, 28), (x + 20.7 - 2, 36), (x + 10, 30), (x + 2, 36), (x, 28)], closed: true), 1.1)
        }
        g.line("^10,46 40,52 60,50 80,52 ^110,46", 0.55)
        for (x, y, s) in [(24.0, 49.0, 1), (42.0, 52.0, 0), (60.0, 50.0, 2), (78.0, 52.0, 0), (96.0, 49.0, 1)] {
            g.shape(s, .circle(x, y + 3.4, 2.8), 0.5)
        }
        g.shape(1, .rrect(0, 86, 120, 34, 2), 1.5)
        g.line("^0,96 ^120,96", 0.6)
        for x in [12.0, 30.0, 48.0, 66.0, 84.0, 102.0] { g.line(.poly([(x, 96), (x, 120)]), 0.42) }
        // The goods.
        for (x, y, r, s) in [(20.0, 82.0, 7.0, 0), (32.0, 80.0, 7.4, 1), (14.0, 76.0, 5.6, 2), (26.0, 72.0, 6.2, 0), (86.0, 82.0, 7.4, 2), (100.0, 80.0, 6.4, 0), (92.0, 72.0, 6.2, 1)] {
            g.shape(s, .circle(x, y, r), 0.95)
        }
        g.shape(1, "^48,86 44,70 ^52,76 ^58,62 ^66,76 ^74,70 ^72,86 z", 1)
        g.shape(-1, .rrect(42, 100, 36, 14, 1.5), 0.8)
        g.line("^48,107 ^72,107", 0.55)
        return g
    }

    static func aviators() -> DoodleGlyph {
        var g = DoodleGlyph("aviators", 0.11, 0.26, tilt: 26)
        g.line("^0,14 -14,4 ^-32,6", 1)
        g.line("^112,14 126,4 ^144,6", 1)
        g.shape(2, "^4,10 26,6 ^48,12 50,28 38,48 18,50 6,38 z", 1.35)
        g.shape(2, "^108,10 86,6 ^64,12 62,28 74,48 94,50 106,38 z", 1.35)
        g.line("^48,12 56,9 ^64,12", 1.05)
        g.line("^50,20 56,18 ^62,20", 0.75)
        g.line("^16,18 ^26,14", 0)
        g.gel("^14,18 ^24,14", 0.95)
        g.gel("^74,18 ^84,14", 0.95)
        g.gel("^16,26 ^20,24", 0.6)
        g.detail(0.14) { g in
            g.hatch("^26,36 ^44,28 ^36,46 ^20,48 z", angle: 50, gap: 2.4, w: 0.42)
            g.hatch("^86,36 ^102,28 ^92,46 ^76,48 z", angle: 50, gap: 2.4, w: 0.42)
        }
        return g
    }

    static func train() -> DoodleGlyph {
        var g = DoodleGlyph("train", 0.18, 0.4, tilt: 4)
        g.noFlip = true
        // A small steam engine and a tender, puffing along a sleeper track.
        g.shape(-1, K.puff(120, -8, 12, 9, n: 7), 0.95)
        g.shape(-1, K.puff(100, -16, 8, 6, n: 6), 0.8)
        g.shape(-1, K.puff(84, -22, 5.6, 4.4, n: 5), 0.7)
        g.shape(1, "^114,6 ^130,6 ^126,28 ^118,28 z", 1.2)
        g.shape(0, .rrect(64, 28, 72, 40, 10), 1.5)
        g.shape(1, .ellipse(136, 48, 5, 20), 1.2)
        g.shape(-1, .circle(100, 22, 6), 0.95)
        g.shape(0, .rrect(28, 16, 40, 52, 3), 1.5)
        g.shape(1, "^24,8 ^72,8 ^74,18 ^22,18 z", 1.25)
        g.shape(2, .rrect(36, 26, 24, 18, 2), 0.95)
        g.tint(1, "^68,36 ^134,36 ^134,42 ^68,42 z")
        g.line("^68,36 ^134,36", 0.5)
        g.line("^68,42 ^134,42", 0.5)
        g.shape(1, "^136,68 ^156,68 ^146,78 ^130,78 z", 1)
        // The tender and coupling.
        g.line("^12,62 ^28,62", 1.1)
        g.shape(1, .rrect(-30, 32, 42, 36, 2), 1.45)
        g.shape(1, K.puff(-9, 30, 18, 6, n: 7), 1)
        // Wheels and rod.
        for (x, r) in [(-20.0, 8.0), (2.0, 8.0), (40.0, 13.0), (72.0, 13.0), (104.0, 9.0), (124.0, 9.0)] {
            g.shape(-1, .circle(x, 78, r), 1.25)
            g.blot(.circle(x, 78, r * 0.26))
        }
        g.line("^40,74 ^72,74 ^104,76", 1.1)
        g.line("^-40,92 ^170,92", 1)
        for x in stride(from: -34.0, through: 160.0, by: 15) { g.line(.poly([(x, 92), (x, 97)]), 0.8) }
        return g
    }

    static func globe() -> DoodleGlyph {
        var g = DoodleGlyph("globe", 0.15, 0.36, tilt: 7)
        g.noFlip = true
        // A desk globe, invented continents, a brass half ring and a turned stand.
        g.line("^86,8 106,30 112,64 94,100 ^68,110", 1.45)
        g.line("^83,12 100,32 ^104,64", 0.6)
        g.shape(2, .circle(58, 56, 45), 1.55)
        g.shape(1, "^28,28 44,20 58,28 54,44 66,56 54,70 ^42,76 34,60 22,54 z", 1)
        g.shape(1, "^72,22 88,30 94,48 ^80,50 ^72,36 z", 0.9)
        g.shape(1, "^68,76 80,70 88,78 ^76,92 z", 0.85)
        g.detail(0.16) { g in
            g.line(.ellipse(58, 56, 45, 14), 0.42)
            g.line(.ellipse(58, 56, 18, 45), 0.42)
            g.gel("20,42 26,26 ^38,16", 1.1)
            g.hatch("^76,60 ^102,50 ^92,84 ^72,96 z", angle: 62, gap: 3, w: 0.42)
        }
        g.line("^66,110 ^64,120", 1.5)
        g.shape(1, "^52,120 ^78,120 ^92,134 ^38,134 z", 1.35)
        g.line("^46,128 ^84,128", 0.5)
        return g
    }

    static func backpack() -> DoodleGlyph {
        var g = DoodleGlyph("backpack", 0.16, 0.36, tilt: 8)
        // A soft canvas pack with a bedroll on top and a tin mug.
        g.shape(1, .rrect(8, 0, 74, 18, 8), 1.3)
        g.line(.circle(77, 9, 5), 0.6)
        g.line("^26,0 ^26,18", 0.8)
        g.line("^62,0 ^62,18", 0.8)
        g.shape(0, "^10,18 ^82,18 88,40 90,100 80,116 ^12,116 2,100 4,40 z", 1.55)
        g.shape(0, "^14,18 ^78,18 ^82,44 ^10,44 z", 1.15)
        g.shape(-1, .rrect(38, 36, 16, 14, 2), 0.85)
        g.shape(2, .rrect(18, 64, 56, 40, 4), 1.2)
        g.line("^18,74 ^74,74", 0.6)
        g.stitch("^22,68 ^70,68", dash: 2, gap: 1.2, w: 0.6)
        g.shape(-1, DoodleFillers.starPath(46, 90, 8), 0.75)
        g.line("^-4,52 -10,78 ^0,96", 1)
        g.detail(0.16) { g in
            g.gel("^10,52 ^8,92", 0.9)
            g.hatch("^72,48 ^86,46 ^88,100 ^78,110 z", angle: 70, gap: 3, w: 0.42)
        }
        return g
    }

    static func sunHat() -> DoodleGlyph {
        var g = DoodleGlyph("sunHat", 0.11, 0.28, tilt: 14)
        g.shape(1, .ellipse(60, 44, 60, 20), 1.5)
        g.shape(1, "^28,40 30,18 46,6 ^60,4 76,6 90,18 ^92,40 76,48 ^44,48 z", 1.5)
        g.tint(0, "^28,30 ^92,30 ^92,40 76,48 ^44,48 ^28,40 z")
        g.line("^28,30 44,36 76,36 ^92,30", 0.75)
        g.shape(0, "^88,34 ^102,28 ^104,42 ^94,42 z", 0.85)
        g.detail(0.14) { g in
            g.line(.ellipse(60, 44, 52, 16), 0.42)
            g.line(.ellipse(60, 44, 44, 12.4), 0.42)
            g.line("^38,16 ^84,16", 0.42)
            g.line("^34,24 ^88,24", 0.42)
        }
        return g
    }

    static func flipFlops() -> DoodleGlyph {
        var g = DoodleGlyph("flipFlops", 0.11, 0.28, tilt: 18)
        g.noFlip = true
        func sole(_ g: inout DoodleGlyph, _ T: (DoodlePath) -> DoodlePath, sep: Int) {
            g.shape(sep, T("22,0 40,8 44,30 38,60 40,84 26,96 10,90 6,70 8,40 4,14 z"), 1.4)
            g.line(T("^24,16 ^8,40"), 1.15)
            g.line(T("^24,16 ^40,40"), 1.15)
            g.blot(T(.circle(24, 16, 2.4)))
        }
        sole(&g, { $0.rotated(-10, about: (24, 48)) }, sep: 0)
        sole(&g, { $0.rotated(12, about: (24, 48)).moved(50, 8) }, sep: 2)
        return g
    }

    static func beachBall() -> DoodleGlyph {
        var g = DoodleGlyph("beachBall", 0.11, 0.28, tilt: 40)
        g.shape(-1, .circle(50, 50, 48), 1.5)
        let c = (42.0, 38.0)
        let spokes = [-110.0, -50.0, 10.0, 70.0, 130.0, 190.0]
        for i in stride(from: 0, to: 6, by: 2) {
            let a0 = spokes[i], a1 = spokes[(i + 1) % 6]
            let s = [0, 2, 1][i / 2]
            var pts: [(Double, Double)] = [c]
            for k in 0...6 {
                let a = a0 + (a1 - a0) * Double(k) / 6
                pts.append(K.polar(50, 50, 47.6, a))
            }
            g.tint(s, .poly(pts, closed: true))
        }
        for a in spokes {
            let p = K.polar(50, 50, 48, a)
            let m = ((c.0 + p.0) / 2 + (p.1 - c.1) * 0.1, (c.1 + p.1) / 2 - (p.0 - c.0) * 0.1)
            g.line(.spline([c, m, p]), 0.75)
        }
        g.shape(-1, .ellipse(c.0, c.1, 7, 6), 0.8)
        g.detail(0.13) { g in
            g.hatch("^72,76 ^92,60 ^84,82 ^64,94 z", angle: 50, gap: 2.8, w: 0.42)
            g.gel("^12,44 ^18,28", 1)
        }
        return g
    }

    static func umbrellaChair() -> DoodleGlyph {
        var g = DoodleGlyph("umbrellaChair", 0.13, 0.38, tilt: 5)
        g.noFlip = true
        // A striped beach umbrella over a deck chair in the sand.
        g.line("^54,0 ^78,132", 1.25)
        g.shape(0, "^0,44 10,20 36,4 ^56,0 82,6 106,24 ^112,44 96,40 ^84,48 70,42 ^56,50 40,42 ^28,48 14,40 z", 1.55)
        g.tint(-1, "^56,0 ^40,42 ^56,50 ^70,42 z")
        g.tint(1, "^22,10 ^0,44 14,40 ^28,48 ^36,4 z")
        g.tint(1, "^82,6 ^84,48 96,40 ^112,44 ^106,24 z")
        g.line("^56,0 ^40,42", 0.65)
        g.line("^56,0 ^70,42", 0.65)
        g.line("^36,4 ^28,48", 0.65)
        g.line("^82,6 ^84,48", 0.65)
        // The chair.
        g.shape(2, "^4,72 ^20,70 ^48,118 ^32,120 z", 1.2)
        g.line("^0,120 ^22,84", 1.1)
        g.line("^38,120 ^12,74", 1.1)
        g.line("^32,120 ^74,114", 1.1)
        g.line("^48,118 ^80,116", 1.1)
        g.shape(1, "^-14,122 8,118 50,120 96,116 ^122,122 ^122,134 ^-14,134 z", 1.2)
        g.detail(0.16) { $0.speckle(-6, 124, 112, 132, n: 18, r: 0.5, seed: 41) }
        return g
    }

    static func surfboard() -> DoodleGlyph {
        var g = DoodleGlyph("surfboard", 0.14, 0.4, tilt: 26)
        // A long board stood up, two stripes and a fin, a leash in a loop.
        g.shape(1, "^24,92 ^44,102 ^24,116 z", 1.05)
        g.shape(-1, "26,-4 40,20 46,60 44,100 34,128 26,136 18,128 8,100 6,60 12,20 z", 1.55)
        g.tint(0, "^7,46 ^45,54 ^46,70 ^6,62 z")
        g.tint(2, "^6,70 ^46,78 ^45.4,88 ^6.4,80 z")
        for (a, b) in [("^7,46", "^45,54"), ("^6,62", "^46,70"), ("^6,70", "^46,78"), ("^6.4,80", "^45.4,88")] {
            let p: DoodlePath = DoodlePath(stringLiteral: a + " " + b)
            g.line(p, 0.6)
        }
        g.line("^26,-2 ^26,44", 0.45)
        g.line("^26,92 ^26,134", 0.45)
        g.shape(0, DoodleFillers.starPath(26, 24, 6.4), 0.55)
        g.line("28,132 40,144 56,136 54,120 ^44,118", 0.65)
        g.detail(0.2) { $0.gel("^14,20 ^12,42", 1) }
        return g
    }

    static func iceCream() -> DoodleGlyph {
        var g = DoodleGlyph("iceCream", 0.1, 0.27, tilt: 18)
        // A waffle cone, three scoops, a dripping top.
        g.shape(1, "^12,62 ^56,62 ^34,126 z", 1.4)
        g.line("^18,72 ^44,94", 0.5)
        g.line("^26,62 ^52,76", 0.5)
        g.line("^44,62 ^46,70", 0.5)
        g.line("^50,72 ^26,92", 0.5)
        g.line("^40,62 ^18,76", 0.5)
        g.line("^24,62 ^14,68", 0.5)
        g.line("^44,90 ^30,110", 0.5)
        g.shape(2, "^4,62 2,48 14,36 30,34 44,42 ^46,62 36,68 26,62 16,70 z", 1.3)
        g.shape(-1, "^24,60 22,44 34,30 50,30 62,42 ^64,58 54,66 44,60 34,66 z", 1.3)
        g.shape(0, "^14,34 16,18 32,4 50,8 58,24 ^54,38 42,34 ^32,42 22,34 z", 1.35)
        g.shape(1, "^36,4 ^40,-8 ^46,-4 ^42,6 z", 0.7)
        g.detail(0.13) { g in
            g.gel("^22,20 ^30,10", 0.9)
            g.gel("^30,44 ^38,36", 0.8)
        }
        return g
    }

    static func coconut() -> DoodleGlyph {
        var g = DoodleGlyph("coconut", 0.1, 0.25, tilt: 14)
        // Half a coconut, a striped straw, a paper umbrella.
        g.line("^58,20 ^74,-14", 1.05)
        g.line("^40,18 ^28,-2", 1)
        g.shape(0, "^14,-2 22,-12 ^36,-14 ^42,-2 34,-2 ^28,4 22,-2 z", 0.95)
        g.shape(1, "^4,20 ^92,20 86,52 66,70 ^30,70 10,52 z", 1.5)
        g.shape(-1, .ellipse(48, 20, 44, 9.5), 1.15)
        g.shape(2, .ellipse(48, 21, 34, 5.4), 0.8)
        g.detail(0.12) { g in
            for (x0, y0, x1, y1) in [(16.0, 36.0, 22.0, 44.0), (28.0, 34.0, 32.0, 50.0), (44.0, 36.0, 44.0, 56.0), (58.0, 34.0, 56.0, 50.0), (74.0, 36.0, 70.0, 44.0), (36.0, 56.0, 40.0, 66.0), (62.0, 54.0, 58.0, 64.0)] {
                g.line(.poly([(x0, y0), (x1, y1)]), 0.45)
            }
        }
        return g
    }

    static func pineapple() -> DoodleGlyph {
        var g = DoodleGlyph("pineapple", 0.12, 0.3, tilt: 16)
        for (a, b, s) in [((36.0, 44.0), (8.0, 8.0), 2), ((44.0, 44.0), (72.0, 8.0), 2), ((38.0, 44.0), (26.0, -6.0), 2), ((42.0, 44.0), (56.0, -6.0), 2), ((40.0, 44.0), (40.0, -14.0), 2)] {
            g.shape(s, K.leaf(a, b, belly: 11), 1)
        }
        g.shape(1, "40,40 62,50 74,76 68,108 48,122 32,122 12,108 6,76 18,50 z", 1.5)
        // A diamond lattice, each stroke kept inside the fruit.
        func inside(_ x: Double, _ y: Double) -> Bool { pow((x - 40) / 32, 2) + pow((y - 80) / 40, 2) < 1 }
        for k in stride(from: -60.0, through: 100.0, by: 16) {
            var plus: [(Double, Double)] = [], minus: [(Double, Double)] = []
            for x in stride(from: 6.0, through: 74.0, by: 2) {
                let y1 = 80 + (x - 40) * 0.8 + k - 20, y2 = 80 - (x - 40) * 0.8 + k - 20
                if inside(x, y1) { plus.append((x, y1)) }
                if inside(x, y2) { minus.append((x, y2)) }
            }
            if plus.count > 1 { g.line(.poly([plus.first!, plus.last!]), 0.5) }
            if minus.count > 1 { g.line(.poly([minus.first!, minus.last!]), 0.5) }
        }
        g.detail(0.14) { $0.gel("^14,74 ^18,62", 0.9) }
        return g
    }

    static func starfish() -> DoodleGlyph {
        var g = DoodleGlyph("starfish", 0.07, 0.18, tilt: 40)
        var nodes: [DoodlePath.Node] = []
        for i in 0..<5 {
            let a = -90.0 + Double(i) * 72
            let t = K.polar(40, 42, 40, a), n1 = K.polar(40, 42, 14, a + 36), s = K.polar(40, 42, 26, a + 11)
            nodes += [.init(x: t.0, y: t.1, corner: false), .init(x: s.0, y: s.1, corner: false), .init(x: n1.0, y: n1.1, corner: true)]
        }
        g.shape(0, DoodlePath(nodes: nodes, closed: true), 1.4)
        g.detail(0.1) { g in
            g.blot(.circle(40, 42, 2))
            for i in 0..<5 {
                let a = -90.0 + Double(i) * 72
                for r in [12.0, 20.0, 28.0] {
                    let p = K.polar(40, 42, r, a)
                    g.blot(.circle(p.0, p.1, 1.3))
                }
            }
        }
        return g
    }

    static func crab() -> DoodleGlyph {
        var g = DoodleGlyph("crab", 0.1, 0.26, tilt: 16)
        g.mirror(50) { g in
            // Legs, arm, a big claw.
            g.line("^22,60 8,68 ^0,82", 1.05)
            g.line("^24,66 12,78 ^8,92", 1.05)
            g.line("^28,70 22,84 ^20,96", 1.05)
            g.line("^22,44 8,34 ^6,24", 1.15)
            g.shape(0, "^6,26 -6,22 -8,8 ^2,-2 ^6,10 ^12,0 ^18,12 14,24 z", 1.25)
            g.line("^38,34 ^38,20", 0.9)
            g.shape(-1, .circle(38, 17, 5), 0.8)
            g.blot(.circle(38, 17, 2))
        }
        g.shape(0, "^16,46 26,32 50,28 74,32 84,46 80,66 64,78 ^36,78 20,66 z", 1.5)
        g.line("^38,58 44,63 56,63 ^62,58", 0.8)
        g.detail(0.13) { g in
            g.gel("^28,42 ^38,35", 0.9)
            g.speckle(30, 66, 70, 74, n: 6, r: 0.6, seed: 51)
        }
        return g
    }

    static func turtle() -> DoodleGlyph {
        var g = DoodleGlyph("turtle", 0.13, 0.3, tilt: 26)
        // A sea turtle swimming, seen from above, patterned shell.
        g.shape(1, "^22,34 2,18 -8,28 ^-2,44 ^22,48 z", 1.1)
        g.shape(1, "^72,34 96,12 112,8 ^114,20 96,40 ^72,50 z", 1.25)
        g.shape(1, "^24,74 8,84 ^6,96 ^22,92 ^36,82 z", 1.05)
        g.shape(1, "^72,76 90,88 ^102,88 ^96,76 ^80,66 z", 1.05)
        g.shape(1, "^84,48 100,44 112,52 110,64 98,68 ^84,62 z", 1.25)
        g.blot(.circle(102, 53, 1.5))
        g.line("^112,60 ^106,62", 0.5)
        g.shape(2, "12,56 22,36 46,26 70,32 86,52 78,72 56,84 30,82 z", 1.55)
        g.shape(1, K.gon(50, 55, 12, sides: 6, rot: 0), 0.8)
        for i in 0..<6 {
            let a = Double(i) * 60
            let p = K.polar(50, 55, 12, a), o = K.polar(50, 55, 30, a)
            g.line(.poly([p, o]), 0.6)
        }
        g.detail(0.14) { g in
            g.gel("^26,44 ^38,36", 0.9)
        }
        return g
    }

    static func fish() -> DoodleGlyph {
        var g = DoodleGlyph("fish", 0.08, 0.2, tilt: 26)
        // A stripy tropical fish and two bubbles.
        g.shape(1, "^20,36 ^-8,16 ^-2,36 ^-8,56 z", 1.2)
        g.shape(1, "^48,16 ^60,-4 ^72,10 ^68,22 z", 1)
        g.shape(1, "^48,56 ^56,70 ^68,62 ^66,50 z", 1)
        g.shape(0, "^16,36 34,18 62,14 86,24 ^98,38 86,50 62,58 34,54 z", 1.45)
        g.tint(-1, "^46,16 ^56,14 ^56,58 ^46,57 z")
        g.tint(-1, "^70,16 ^76,20 ^76,52 ^70,55 z")
        for x in [46.0, 56.0, 70.0, 76.0] { g.line(.poly([(x, 16), (x, 56)]), 0.5) }
        g.blot(.circle(86, 32, 2.4))
        g.line("^92,44 ^86,44", 0.6)
        g.line(.circle(108, 22, 3.6), 0.55)
        g.line(.circle(114, 8, 2.4), 0.5)
        return g
    }

    static func anchor() -> DoodleGlyph {
        var g = DoodleGlyph("anchor", 0.1, 0.26, tilt: 22)
        // An anchor with a rope wound through the ring.
        g.band(1, outer: .circle(40, 10, 10), inner: .circle(40, 10, 5), 1.15, innerW: 0.8)
        g.shape(1, .rrect(36, 20, 8, 76, 2), 1.25)
        g.shape(1, .rrect(18, 28, 44, 7.4, 2.5), 1.15)
        g.shape(1, "^0,66 ^-6,58 ^14,62 ^10,70 16,84 ^38,92 ^42,92 ^64,84 70,70 ^66,62 ^86,58 ^80,66 76,88 50,106 ^40,112 ^30,106 4,88 z", 1.4)
        g.line("46,4 58,12 52,28 44,44 30,52 28,66 ^40,76", 0.9)
        return g
    }

    static func lifebuoy() -> DoodleGlyph {
        var g = DoodleGlyph("lifebuoy", 0.1, 0.26, tilt: 18)
        g.line(.circle(46, 46, 49), 0.65)
        g.band(-1, outer: .circle(46, 46, 42), inner: .circle(46, 46, 19), 1.5, innerW: 1.2)
        for i in 0..<4 {
            let a = 45.0 + Double(i) * 90
            let pts = [K.polar(46, 46, 19, a - 22), K.polar(46, 46, 42, a - 14), K.polar(46, 46, 42, a + 14), K.polar(46, 46, 19, a + 22)]
            g.tint(0, .poly(pts, closed: true))
            g.line(.poly([pts[0], pts[1]]), 0.7)
            g.line(.poly([pts[3], pts[2]]), 0.7)
            let t = K.polar(46, 46, 45.6, a)
            g.blot(.circle(t.0, t.1, 3.8))
        }
        g.detail(0.13) { $0.gel("^12,36 ^20,20", 1) }
        return g
    }

    static func postcard() -> DoodleGlyph {
        var g = DoodleGlyph("postcard", 0.14, 0.32, tilt: 20)
        g.noFlip = true
        // A picture card, half a seaside scene, a hand-written line and a stamp.
        g.shape(-1, .rrect(0, 0, 112, 74, 2), 1.5)
        g.tint(2, .rrect(4, 4, 52, 66, 1))
        g.line("^56,4 ^56,70", 0.75)
        g.shape(1, "^4,54 20,48 34,52 ^56,48 ^56,70 ^4,70 z", 0.7)
        g.line("^4,54 20,48 34,52 ^56,48", 0.5)
        g.shape(0, "^22,44 ^40,44 ^36,50 ^26,50 z", 0.6)
        g.line("^31,44 ^31,26", 0.6)
        g.shape(-1, "^32,26 ^44,42 ^32,42 z", 0.5)
        g.line("^62,44 72,40 ^84,45 ^100,41", 0.6)
        g.line("^62,54 74,50 86,55 ^104,51", 0.6)
        g.line("^62,63 ^92,60", 0.6)
        g.shape(1, "^88,6 ^106,6 ^106,30 ^88,30 z", 0.75)
        g.shape(0, DoodleFillers.starPath(97, 18, 6), 0.5)
        return g
    }

    static func stamp() -> DoodleGlyph {
        var g = DoodleGlyph("stamp", 0.07, 0.17, tilt: 22)
        g.noFlip = true
        // A serrated postage stamp with a little palm; no country or value.
        var nodes: [DoodlePath.Node] = []
        let w = 56.0, h = 70.0, n = 7, m = 9
        for i in 0..<n {
            let x = Double(i) * w / Double(n)
            nodes.append(.init(x: x, y: 0, corner: true))
            nodes.append(.init(x: x + w / Double(n) / 2, y: 3, corner: true))
        }
        for i in 0..<m {
            let y = Double(i) * h / Double(m)
            nodes.append(.init(x: w, y: y, corner: true))
            nodes.append(.init(x: w - 3, y: y + h / Double(m) / 2, corner: true))
        }
        for i in 0..<n {
            let x = w - Double(i) * w / Double(n)
            nodes.append(.init(x: x, y: h, corner: true))
            nodes.append(.init(x: x - w / Double(n) / 2, y: h - 3, corner: true))
        }
        for i in 0..<m {
            let y = h - Double(i) * h / Double(m)
            nodes.append(.init(x: 0, y: y, corner: true))
            nodes.append(.init(x: 3, y: y - h / Double(m) / 2, corner: true))
        }
        g.shape(-1, DoodlePath(nodes: nodes, closed: true), 1.05)
        g.tint(2, .rrect(8, 9, 40, 52, 1))
        g.line(.rrect(8, 9, 40, 52, 1), 0.55)
        g.shape(1, .circle(36, 22, 6), 0.55)
        g.line("^22,54 24,40 ^28,30", 0.8)
        g.shape(0, K.leaf((28, 30), (16, 26), belly: 5), 0.45)
        g.shape(0, K.leaf((28, 30), (40, 34), belly: 5), 0.45)
        g.shape(0, K.leaf((28, 30), (20, 40), belly: 5), 0.45)
        return g
    }

    static func wetTicket() -> DoodleGlyph {
        var g = DoodleGlyph("ferryTicket", 0.07, 0.18, tilt: 24)
        g.noFlip = true
        g.shape(1, "^0,6 ^88,6 ^88,16 82,22 ^88,28 ^88,40 ^0,40 ^0,28 6,22 ^0,16 z", 1.25)
        g.stitch("^66,8 ^66,38", dash: 2.2, gap: 2, w: 0.6)
        g.shape(2, "^14,26 ^48,26 ^44,33 ^18,33 z", 0.6)
        g.line("^30,26 ^30,12", 0.55)
        g.shape(-1, "^31,12 ^42,24 ^31,24 z", 0.42)
        g.blot(.circle(77, 22, 2.8))
        return g
    }

    static func luggageTag() -> DoodleGlyph {
        var g = DoodleGlyph("luggageTag", 0.09, 0.22, tilt: 28)
        g.noFlip = true
        g.line("20,12 8,-6 16,-20 30,-18 ^30,-2", 0.7)
        g.shape(1, "^20,0 ^40,14 ^40,86 ^0,86 ^0,14 z", 1.35)
        g.shape(-1, .circle(20, 14, 4), 0.7)
        g.shape(-1, .rrect(6, 30, 28, 48, 1.5), 0.75)
        g.line("^10,40 ^30,40", 0.55)
        g.line("^10,50 ^26,50", 0.55)
        g.line("^10,60 ^30,60", 0.55)
        g.shape(0, DoodleFillers.starPath(20, 70, 4.4), 0.42)
        return g
    }

    static func hotelKey() -> DoodleGlyph {
        var g = DoodleGlyph("hotelKey", 0.09, 0.24, tilt: 34)
        // A brass key on a heavy diamond fob.
        g.band(1, outer: .circle(24, 16, 14), inner: .circle(24, 16, 7), 1.25, innerW: 0.9)
        g.shape(1, .rrect(21, 30, 6, 48, 1.5), 1.1)
        g.shape(1, "^27,62 ^38,62 ^38,68 ^33,68 ^33,72 ^38,72 ^38,78 ^27,78 z", 0.9)
        g.line("^14,6 2,0 ^-4,10", 0.65)
        g.shape(0, "^-22,10 ^-4,10 ^6,32 ^-13,48 ^-30,32 z", 1.2)
        g.shape(-1, .circle(-13, 18, 2.6), 0.5)
        g.line("^-18,28 ^-8,28", 0.8)
        g.line("^-18,34 ^-8,34", 0.5)
        return g
    }

    static func neckPillow() -> DoodleGlyph {
        var g = DoodleGlyph("neckPillow", 0.09, 0.24, tilt: 22)
        g.whole = true
        g.noTuck = true
        g.band(2, outer: "^24,8 8,18 -2,44 8,68 ^28,80 50,84 ^72,80 92,68 102,44 92,18 ^76,8 70,18 ^76,34 72,50 50,58 28,50 24,34 30,18 z", inner: "^24,8 ^24,8 ^24,8 z", 1.5, innerW: 0)
        g.line("^10,20 16,30 ^12,42", 0.5)
        g.line("^88,20 84,30 ^88,42", 0.5)
        g.line("^12,54 22,58 ^26,68", 0.5)
        g.line("^88,54 78,58 ^74,68", 0.5)
        g.line("^44,58 ^44,82", 0.5)
        g.line("^56,58 ^56,82", 0.5)
        g.detail(0.12) { $0.gel("^4,36 ^10,24", 0.9) }
        return g
    }

    static func sunscreen() -> DoodleGlyph {
        var g = DoodleGlyph("sunscreen", 0.08, 0.2, tilt: 24)
        g.shape(0, "^16,-2 ^32,-2 ^34,10 ^14,10 z", 1.1)
        g.shape(-1, "^12,10 ^36,10 44,24 46,94 ^2,94 4,24 z", 1.45)
        g.shape(2, "^3.4,44 ^45,44 ^45.8,80 ^2.6,80 z", 0.75)
        g.shape(1, .circle(24, 62, 10), 0.75)
        g.line("^13,86 ^35,86", 0.5)
        g.detail(0.1) { $0.gel("^38,28 ^39,40", 0.8) }
        return g
    }

    static func guideBook() -> DoodleGlyph {
        var g = DoodleGlyph("guideBook", 0.1, 0.25, tilt: 18)
        // A fat dog-eared guide with a bookmark and page tabs.
        g.shape(0, "^62,80 ^62,104 ^56,102 ^50,104 ^50,80 z", 0.75)
        g.shape(-1, "^8,6 ^78,6 ^84,12 ^84,90 ^8,90 z", 1.2)
        for y in [20.0, 34.0, 48.0] { g.line(.poly([(84, y), (88, y + 4), (88, y + 10), (84, y + 12)]), 0.6) }
        g.shape(1, .rrect(0, 0, 76, 88, 3), 1.5)
        g.line("^8,0 ^8,88", 0.7)
        g.shape(2, .rrect(16, 12, 52, 34, 2), 0.85)
        g.shape(0, "^16,46 ^16,34 28,26 40,32 ^52,24 ^68,36 ^68,46 z", 0.6)
        g.line("^16,58 ^68,58", 1.05)
        g.line("^24,68 ^60,68", 0.6)
        g.shape(-1, "^60,0 ^76,0 ^76,16 z", 0.7)
        return g
    }

    static func coins() -> DoodleGlyph {
        var g = DoodleGlyph("coins", 0.06, 0.15, tilt: 20)
        for (x, y, r, s) in [(50.0, 42.0, 18.0, 1), (22.0, 42.0, 22.0, 1), (40.0, 20.0, 20.0, 1)] {
            g.shape(s, .circle(x, y, r), 1.2)
            g.line(.circle(x, y, r * 0.74), 0.55)
        }
        g.shape(0, DoodleFillers.starPath(40, 20, 7.4), 0.5)
        return g
    }

    static func cactus() -> DoodleGlyph {
        var g = DoodleGlyph("cactus", 0.1, 0.26, tilt: 7)
        g.noFlip = true
        g.shape(2, .rrect(-2, 26, 14, 34, 7), 1.25)
        g.shape(2, "^4,56 ^4,48 ^24,48 ^24,62 ^10,62 z", 1.2)
        g.shape(2, .rrect(58, 12, 14, 34, 7), 1.25)
        g.shape(2, "^64,38 ^64,48 ^46,48 ^46,34 ^60,34 z", 1.2)
        g.shape(2, "^22,88 ^22,16 30,4 38,2 46,6 ^50,16 ^50,88 z", 1.45)
        g.detail(0.13) { g in
            for x in [29.0, 36.0, 43.0] { g.line(.poly([(x, 12), (x, 86)]), 0.42) }
        }
        g.shape(0, K.puff(36, 0, 5, 4, n: 5), 0.6)
        g.shape(0, "^14,84 ^58,84 ^54,112 ^18,112 z", 1.35)
        g.shape(0, .rrect(10, 78, 52, 10, 1.5), 1.15)
        return g
    }

    static func toucan() -> DoodleGlyph {
        var g = DoodleGlyph("toucan", 0.12, 0.28, tilt: 8)
        g.whole = true
        g.noTuck = true
        g.cap = 1
        // A big-billed bird on a branch.
        g.line("^-14,108 40,104 ^118,110", 1.4)
        g.shape(2, K.leaf((98, 108), (122, 92), belly: 12), 0.9)
        g.shape(2, K.leaf((-6, 108), (-22, 90), belly: 12), 0.9)
        g.line("^44,96 ^44,106", 1)
        g.line("^54,98 ^54,106", 1)
        // A long tail, a dark body with a pale bib.
        g.shape(1, "^30,84 ^10,132 ^22,134 ^46,92 z", 1.15)
        g.shape(1, "22,48 22,30 38,16 62,20 72,44 66,78 50,98 34,92 z", 1.55)
        g.shape(-1, "^46,18 62,20 72,44 68,62 52,54 ^40,36 z", 1)
        // Huge bill, curved, banded.
        g.shape(1, "^60,18 76,6 104,8 128,28 ^132,44 110,34 86,32 ^68,38 z", 1.5)
        g.tint(0, "^128,28 ^132,44 110,34 ^102,33 ^108,16 z")
        g.line("^108,16 ^102,33", 0.7)
        g.line("^62,26 92,20 ^128,34", 0.5)
        g.shape(-1, .circle(50, 28, 5), 0.8)
        g.blot(.circle(51, 28, 2))
        g.detail(0.16) { g in
            g.line("^28,54 40,70 ^44,86", 0.5)
            g.line("^36,48 50,70 ^52,84", 0.5)
        }
        return g
    }

    static func gull() -> DoodleGlyph {
        var g = DoodleGlyph("gull", 0.09, 0.22, tilt: 20)
        // On a post, side view.
        g.shape(1, "^38,68 ^52,68 ^52,108 ^38,108 z", 1.2)
        g.line("^38,76 ^52,74", 0.42)
        g.line("^38,86 ^52,84", 0.42)
        g.line("^44,58 ^44,68", 0.9)
        g.line("^52,58 ^52,68", 0.9)
        g.shape(1, "^4,44 ^-14,50 ^-4,36 z", 1)
        g.shape(-1, "^6,44 18,30 48,24 ^60,12 70,6 82,12 ^84,20 72,30 66,52 44,62 18,56 z", 1.45)
        g.shape(1, "^83,14 ^98,20 ^84,22 z", 0.95)
        g.blot(.circle(74, 14, 1.5))
        g.shape(2, "^14,44 30,32 ^56,32 44,50 ^22,52 z", 1)
        return g
    }

    static func cloud() -> DoodleGlyph {
        var g = DoodleGlyph("cloud", 0.1, 0.25, tilt: 4)
        g.shape(-1, "^12,52 0,44 4,32 18,28 24,12 44,6 58,14 74,8 90,20 94,32 108,38 106,50 ^94,54 z", 1.3)
        g.line("^24,12 30,22 ^26,30", 0.55)
        g.line("^74,8 68,18 ^74,26", 0.55)
        g.detail(0.12) { $0.hatch("^40,46 ^100,42 ^92,52 ^44,52 z", angle: 12, gap: 2.6, w: 0.42) }
        return g
    }

    static func shellPair() -> DoodleGlyph {
        var g = DoodleGlyph("shellPair", 0.06, 0.15, tilt: 30)
        g.shape(1, "^26,62 ^16,62 2,44 0,26 12,10 ^26,4 40,10 52,26 50,44 ^36,62 z", 1.25)
        for x in [8.0, 18.0, 34.0, 44.0] { g.line(.poly([(x, 16 + abs(x - 26) * 0.5), (26 + (x - 26) * 0.3, 60)]), 0.5) }
        g.line("^26,4 ^26,60", 0.5)
        return g
    }

    // The marks in the gaps.

    static func dashTrail() -> DoodleGlyph {
        var g = DoodleGlyph("dashTrail", 0.04, 0.09, tilt: 40)
        g.stitch("^0,30 20,12 44,20 ^68,4", dash: 4, gap: 4, w: 0.8)
        return g
    }

    static func tinyPlane() -> DoodleGlyph {
        var g = DoodleGlyph("tinyPlane", 0.03, 0.07, tilt: 40)
        g.shape(-1, "^0,14 ^34,0 ^24,10 ^40,10 ^26,16 ^26,26 ^18,18 ^6,20 z", 0.72)
        return g
    }

    static func tinyWave() -> DoodleGlyph {
        var g = DoodleGlyph("tinyWave", 0.03, 0.07, tilt: 10)
        g.line("^0,10 8,2 16,10 24,2 32,10 40,2 ^48,10", 0.8)
        return g
    }

    static func tinyShell() -> DoodleGlyph {
        var g = DoodleGlyph("tinyShell", 0.025, 0.055, tilt: 30)
        g.shape(1, "^12,24 ^6,22 0,12 6,2 12,0 18,2 24,12 ^18,22 z", 0.7)
        g.line("^12,24 ^6,6", 0.42)
        g.line("^12,24 ^18,6", 0.42)
        return g
    }

    static func tinyX() -> DoodleGlyph {
        var g = DoodleGlyph("tinyX", 0.018, 0.04, tilt: 15)
        g.line("^0,0 ^16,16", 1.1)
        g.line("^16,0 ^0,16", 1.1)
        return g
    }

    static func tinyGull() -> DoodleGlyph {
        var g = DoodleGlyph("tinyGull", 0.025, 0.06, tilt: 20)
        g.line("^0,8 8,1 ^18,8 28,1 ^36,8", 0.85)
        return g
    }

    static func tinyStar() -> DoodleGlyph {
        var g = DoodleGlyph("tinyStar", 0.02, 0.045, tilt: 40)
        g.shape(1, DoodleFillers.starPath(0, 0, 20), 0.75)
        return g
    }

    static func tinyDrop() -> DoodleGlyph {
        var g = DoodleGlyph("tinyDrop", 0.016, 0.034, tilt: 40)
        g.shape(2, "12,0 18,12 16,20 12,24 8,20 6,12 z", 0.65)
        return g
    }
}
