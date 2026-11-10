// The Forest drawings that carry the picture, and the small things around them.

import CoreGraphics
import Foundation

nonisolated extension DoodleForest {
    /// Short fur strokes in rows that follow a form: `rows` are lines across the body, each stroke leaning along `lean`.
    static func fur(_ g: inout DoodleGlyph, rows: [[(Double, Double)]], lean: (Double, Double), len: Double, w: Double = 0.55, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for row in rows {
            for (i, p) in row.enumerated() {
                if i % 3 == 2, rng.next() < 0.35 { continue }
                let l = len * rng.next(0.75, 1.2)
                let bend = rng.next(-0.18, 0.18) * l
                g.line(DoodlePath.spline([p, (p.0 + lean.0 * l * 0.5 - lean.1 * bend, p.1 + lean.1 * l * 0.5 + lean.0 * bend), (p.0 + lean.0 * l, p.1 + lean.1 * l)]), w)
            }
        }
    }

    static func bear() -> DoodleGlyph {
        var g = DoodleGlyph("bear", 0.3, 0.46, tilt: 6)
        g.must = true
        g.whole = true
        // The far legs, set back and darker, in the near body's shadow. The hind one is mid-step: its paw has left the ground.
        let farHind: DoodlePath = "^38,54 ^62,56 64,64 62,72 ^69,80 ^68,85 ^47,85 49,76 46,68 z"
        let farFore: DoodlePath = "^68,58 ^88,58 85,68 81,78 ^88,90 ^66,90 ^70,80 70,68 z"
        g.shape(1, farHind, 1)
        g.shade(farHind)
        g.shape(1, farFore, 1)
        g.shade(farFore)
        for x in [62.0, 67.0] { g.line("^\(x - 2),83 \(x),85 ^\(x + 1.5),85.6", 0.55) }
        for x in [81.0, 86.0] { g.line("^\(x - 2),88 \(x),90 ^\(x + 2),91", 0.55) }
        // The ear sits on the skull, behind it.
        g.shape(1, .circle(90, 14, 6), 1.05)
        g.shade(.circle(90.5, 15, 3))
        // The body in one line: rump, the long back, the shoulder hump, dished face, snout, jaw, chest, the near legs with a real knee and hock.
        g.shape(1, "6,40 10,25 22,16 38,14 50,13 60,8 70,6 80,10 88,17 94,19 101,21 106,27 113,30 121,30 ^127,33 127,38 121,41 113,43 106,44 100,49 96,56 96,64 101,73 107,82 ^118,91 ^92,91 88,82 82,72 ^74,62 56,63 44,62 37,61 38,68 32,75 30,82 ^37,91 ^3,91 2,85 7,76 ^11,68 8,60 5,50 z", 1.3)
        // A pale muzzle, the belly in shadow.
        g.tint(2, "106,28 113,31 121,31 126,34 126,38 121,40 113,42 107,43 103,36 z")
        g.shade("^30,52 44,58 58,58 ^72,56 ^72,61 56,62 44,61 34,57 z")
        g.shade("^80,62 87,72 ^94,89 ^108,89 ^102,76 ^97,64 95,58 ^86,56 z")
        g.detail(0.2) { g in
            // Fur that follows the form: gathered on the hump and the haunch, none on the flank.
            fur(&g, rows: [[(58, 13), (62, 19), (65, 26), (67, 33), (68, 40)],
                           [(68, 11), (71, 18), (73, 26), (75, 33), (76, 41), (75, 48)],
                           [(78, 15), (81, 22), (83, 30), (85, 38)]], lean: (-0.42, 0.91), len: 6.4, seed: 7)
            fur(&g, rows: [[(13, 28), (11, 36), (12, 45), (15, 53)],
                           [(21, 22), (19, 31), (20, 41), (23, 50)],
                           [(30, 19), (28, 28), (29, 37)]], lean: (-0.28, 0.96), len: 6, seed: 8)
            // The belly fringe.
            for x in stride(from: 42.0, through: 68.0, by: 5.5) {
                g.line("^\(x),\(60.5 + (x > 54 ? 1.0 : 0)) ^\(x - 1.5),\(65.5 + (x > 54 ? 1.0 : 0))", 0.55)
            }
            // The hock, one short line where the leg folds.
            g.line("^14,66 18,70 ^17,76", 0.5)
        }
        // Brow, eye, nose, mouth.
        g.line("^99,23 103,23.6 ^106.5,26", 0.6)
        g.accent(.ellipse(104, 27.5, 1.6, 1.8))
        g.accent("^121,30 125,30.5 ^128,33.5 127,37 123,36 121,33 z")
        g.line("^124,37 123,40 117,41 ^110,38.5", 0.7)
        // Claws.
        for (x, y) in [(112.0, 90.0), (31.0, 90.0)] {
            g.line("^\(x - 9),\(y - 4) \(x - 7),\(y - 1) ^\(x - 3.5),\(y + 1)", 0.75)
            g.line("^\(x - 4),\(y - 4) \(x - 2),\(y - 1) ^\(x + 1.5),\(y + 1)", 0.75)
            g.line("^\(x + 0.5),\(y - 3.5) \(x + 2),\(y - 1) ^\(x + 5),\(y + 1)", 0.75)
        }
        // A few strokes of ground under the feet, no more.
        g.line("^2,93.5 ^38,94", 0.6)
        g.line("^46,88 ^68,88", 0.4)
        g.line("^64,92.5 ^88,93", 0.5)
        g.line("^92,93.5 ^120,93", 0.6)
        return g
    }

    static func deer() -> DoodleGlyph {
        var g = DoodleGlyph("deer", 0.34, 0.46, tilt: 5)
        g.must = true
        g.whole = true
        // Far antler first, shaded, with its tines.
        let farTines: [[(Double, Double)]] = [[(105, 27), (108, 18), (106, 8)], [(113, 16), (116, 7), (113, -4)], [(118.5, 3), (122, -6), (119, -15)]]
        for t in farTines { g.shape(1, DoodlePath.taper(t, 2.8, 0.9), 0.75) }
        let farBeam = DoodlePath.taper([(96, 38), (102, 30), (110, 20), (116, 8), (118, -6), (114, -20)], 4.2, 1.1)
        g.shape(1, farBeam, 0.85)
        g.shade(farBeam)
        // Far legs, set off, in shadow.
        let farFore: DoodlePath = "^58,100 ^72,100 71,118 70,130 71,134 68,140 67,152 68,158 ^73,167 ^60,167 60,157 60,142 60,134 58,120 z"
        let farHind: DoodlePath = "^26,100 ^44,100 42,116 41,124 37,133 39,146 40,156 ^45,167 ^32,167 31,157 29,144 25,134 28,122 z"
        g.shape(1, farFore, 0.95)
        g.shade(farFore)
        g.shape(1, farHind, 0.95)
        g.shade(farHind)
        g.accent("^60,163 ^71.5,163 ^73,167 ^60,167 z")
        g.accent("^31.5,163 ^43.5,163 ^45,167 ^32,167 z")
        // Tail behind the rump.
        g.shape(-1, "^12,88 5,88 1,95 3,104 9,102 ^14,96 z", 0.95)
        // Near body: deep chest, tucked belly, a knee and a hock that look like joints.
        g.shape(1, "11,92 17,84 30,80 50,80 64,78 74,66 83,52 90,42 97,39 104,42 111,47 ^119,52 119,57 ^110,60 102,59 99,66 99,80 100,98 93,114 89,123 86.5,131 88.5,136 85,141 83,152 83,160 ^88.5,172 ^75,172 75,162 75,152 74,141 72,130 66,118 50,115 34,111 28,115 28,123 26,132 21,138 24,152 25,160 ^31,172 ^17.5,172 16,162 15,150 8,138 10.5,128 7,114 7,100 z", 1.3)
        // A pale rump, throat and belly.
        g.tint(-1, "11,92 7,100 7,112 12,116 18,102 ^17,86 z")
        g.tint(2, "^99,62 ^99,80 ^99,98 ^91,112 ^86,100 ^90,80 z")
        g.shade("^34,110 50,114 ^66,117 ^68,108 ^50,105 ^36,102 z")
        // Hoof blocks, solid.
        g.accent("^75.2,167.5 ^86.5,167.5 ^88.5,172 ^75,172 z")
        g.accent("^17,167.5 ^29,167.5 ^31,172 ^17.5,172 z")
        g.detail(0.22) { g in
            // The neck's ruff and the line of the shoulder.
            fur(&g, rows: [[(86, 60), (84, 67), (82, 74), (79, 80)], [(92, 56), (90, 64), (88, 72), (86, 80)]], lean: (-0.55, 0.83), len: 5, seed: 9)
            g.line("^72,84 66,94 ^64,106", 0.55)
            g.line("^28,88 22,100 ^22,114", 0.55)
            // Knee and hock creases.
            g.line("^75,136 ^83,136", 0.45)
            g.line("^13,138 ^21,138", 0.45)
        }
        // Ear, swept back from the skull.
        g.shape(1, "^92,40 86,33 76,33 80,41 ^88,45 z", 1)
        g.line("^89,41 ^81,37", 0.5)
        // Near antler, tines, the brow tine pointing forward.
        let nearTines: [[(Double, Double)]] = [[(87, 34), (95, 28), (102, 27)], [(79, 27), (82, 16), (80, 6)], [(70, 20), (73, 8), (71, -4)], [(64, 8), (70, -3), (70, -14)]]
        for t in nearTines { g.shape(1, DoodlePath.taper(t, 3, 0.9), 0.85) }
        g.shape(1, DoodlePath.taper([(91, 38), (83, 30), (73, 22), (65, 10), (62, -6), (66, -22)], 4.6, 1.1), 0.95)
        // Eye, nose, mouth.
        g.accent(.ellipse(102, 45, 1.8, 2.1))
        g.line("^98,42 ^104,42.4", 0.5)
        g.accent("^114,48.4 ^119.4,52 119.4,56 115,55 z")
        g.line("^116,56 ^107,56", 0.55)
        g.line("^16,173.5 ^34,173.5", 0.55)
        g.line("^60,172 ^92,173.5", 0.55)
        return g
    }

    static func tent() -> DoodleGlyph {
        var g = DoodleGlyph("tent", 0.3, 0.46, tilt: 5)
        g.must = true
        g.noTuck = true
        g.zone = 0...0.66
        // Guy lines run out behind the canvas to their pegs.
        g.line("^54,10 ^4,72", 0.6)
        g.line("^104,18 ^142,68", 0.6)
        g.line("^84,17 ^112,78", 0.5)
        // The far wall, the long side, with its seams.
        g.shape(1, "^54,10 ^104,18 ^130,70 ^84,76 z", 1.2)
        g.shade("^92,16 ^104,18 ^130,70 ^112,73 z")
        g.detail(0.2) { g in
            g.line("^69,12.5 ^98,74", 0.55)
            g.line("^86,15 ^113,72", 0.55)
            g.stitch("^87,71 ^127,65.5", dash: 2.6, gap: 2.2, w: 0.5)
            // A patch sewn on where a branch went through.
            g.shape(2, "^88,38 ^98,36 ^103,46 ^93,48 z", 0.6)
            g.stitch("^90,39.5 ^97,38 ^100.5,45 ^94,46.4 z", dash: 1.4, gap: 1.4, w: 0.36)
        }
        // The near end.
        g.shape(0, "^54,10 ^84,76 ^22,76 z", 1.35)
        // The door, dark, and its two flaps tied back.
        g.accent("^54,24 ^67,76 ^41,76 z")
        g.shape(2, "^54,16 47,36 ^32,76 ^43,76 49,54 z", 1)
        g.shape(2, "^54,16 61,36 ^76,76 ^65,76 59,54 z", 1)
        g.detail(0.2) { g in
            g.line("^37,56 ^48,58", 0.85)
            g.line("^71,56 ^60,58", 0.85)
            g.line("^40,66 ^40,74", 0.45)
            g.line("^68,66 ^68,74", 0.45)
            g.stitch("^27,74 ^48,23", dash: 2, gap: 1.8, w: 0.42)
            g.stitch("^81,74 ^60,23", dash: 2, gap: 1.8, w: 0.42)
        }
        // Ridge, pole, pennant.
        g.line("^54,10 ^104,18", 1.4)
        g.line("^54,10 ^54,-8", 0.95)
        g.shape(2, "^54,-8 ^74,-3 ^54,2 z", 0.9)
        // Pegs driven in at a slant, a tick of ground at each.
        for (x, y) in [(4.0, 72.0), (142.0, 68.0), (112.0, 78.0)] {
            g.line("^\(x),\(y - 1) ^\(x + 2),\(y + 8)", 1.25)
            g.line("^\(x - 3),\(y + 8) ^\(x + 6),\(y + 8.6)", 0.6)
        }
        g.line("^16,78 ^46,79", 0.6)
        g.line("^60,79 ^96,78.5", 0.6)
        g.detail(0.22) { g in
            g.line("^10,80 ^12,75 ^15,80", 0.55)
            g.line("^122,78 ^124,73 ^127,78", 0.55)
        }
        return g
    }

    static func pines() -> DoodleGlyph {
        var g = DoodleGlyph("pines", 0.2, 0.4, tilt: 6)
        g.must = true
        conifer(&g, cx: 76, top: 14, bottom: 84, half: 23, tiers: 3, seed: 21, needles: false)
        conifer(&g, cx: 12, top: 30, bottom: 90, half: 18, tiers: 3, seed: 22, needles: false)
        conifer(&g, cx: 44, top: 0, bottom: 92, half: 28, tiers: 4, seed: 23)
        g.detail(0.2) { g in
            g.line("^0,103 ^14,104", 0.6)
            g.line("^36,104 ^54,103.5", 0.6)
            g.line("^68,96 ^86,95.5", 0.6)
            g.line("^92,98 ^94,93 ^97,98", 0.6)
            g.line("10,-3 13,-5 16,-3", 0.6)
            g.line("16,5 19,3 22,5", 0.6)
        }
        return g
    }

    static func fish() -> DoodleGlyph {
        var g = DoodleGlyph("fish", 0.13, 0.32, tilt: 16)
        // The line comes straight down into the lip.
        g.line("^128,-22 ^127,12", 0.6)
        g.line("^127,12 127,20 123,24 119,21 ^119,17", 0.95)
        g.blot("^127,10 ^129,13 ^125,13 z")
        // Tail, fins with rays, all growing out of the body.
        g.shape(0, "^22,34 ^4,14 ^10,34 ^2,56 ^22,42 z", 1.05)
        g.shape(0, "^52,14 ^60,4 ^72,2 ^84,5 ^92,14 z", 1)
        g.shape(0, "^62,58 ^66,70 ^76,68 ^82,56 z", 0.95)
        g.shape(0, "^38,52 ^37,62 ^47,60 ^52,54 z", 0.95)
        g.shape(0, "^34,17 ^37,8 ^44,15 z", 0.85)
        // The body, a trout's: slim, deep behind the gill.
        g.shape(2, "^22,36 38,21 60,14 88,14 108,18 120,24 ^127,29 122,36 106,47 84,55 60,57 38,52 z", 1.3)
        g.tint(-1, "^24,38 40,46 60,50 84,49 104,42 120,34 122,36 106,47 84,55 60,57 38,52 z")
        // Gill, pectoral fin, eye, mouth, a row of spots.
        g.line("^97,16 91,26 91,38 ^97,48", 0.85)
        g.shape(0, "^88,38 76,36 ^68,41 ^71,47 ^80,48 z", 0.9)
        g.shape(-1, .circle(108, 26, 3.6), 0.8)
        g.accent(.circle(108.4, 26, 1.9))
        g.line("^127,29 ^116,31", 0.75)
        g.detail(0.16) { g in
            g.line("^60,5 ^60,13", 0.42)
            g.line("^68,3 ^68,13", 0.42)
            g.line("^76,3 ^76,13", 0.42)
            g.line("^84,6 ^84,13", 0.42)
            g.line("^8,22 ^19,33", 0.42)
            g.line("^8,47 ^19,39", 0.42)
            g.line("^71,59 ^71,66", 0.42)
            g.line("^75,44 ^83,41", 0.42)
            for (x, y) in [(40.0, 30.0), (50.0, 25.0), (60.0, 30.0), (70.0, 24.0), (80.0, 29.0), (48.0, 37.0), (64.0, 38.0), (86.0, 22.0)] {
                g.blot(.ellipse(x, y, 1.6, 1.2))
            }
        }
        return g
    }

    // MARK: Small things

    static func matchbox() -> DoodleGlyph {
        var g = DoodleGlyph("matchbox", 0.08, 0.17, tilt: 30)
        // The drawer pushed half out, a few matches lying in it.
        g.shape(-1, "^50,8 ^96,20 ^88,46 ^42,34 z", 1)
        g.shade("^56,14 ^88,22 ^82,40 ^50,32 z")
        for (a, b, c, d) in [(60.0, 18.0, 82.0, 25.0), (58.0, 23.0, 80.0, 30.0), (56.0, 28.0, 76.0, 34.0)] {
            g.line(.poly([(a, b), (c, d)]), 1.1)
            g.blot(.circle(c, d, 2.4))
        }
        g.shape(2, "^8,20 ^60,34 ^52,62 ^0,48 z", 1.15)
        g.shape(0, "^16,28 ^46,36 ^41,54 ^11,46 z", 0.8)
        g.blot("^26,44 ^30,36 ^36,48 z")
        g.line("^60,34 ^68,37 ^60,64 ^52,62", 0.9)
        g.detail(0.1) { g in
            g.hatch("^61,38 ^67,39 ^60,62 ^54,60 z", angle: 72, gap: 1.8, w: 0.42)
        }
        return g
    }

    static func knife() -> DoodleGlyph {
        var g = DoodleGlyph("knife", 0.09, 0.2, tilt: 40)
        // A folding knife, blade out.
        g.shape(-1, "^60,18 ^98,6 118,4 ^132,6 118,16 96,24 ^62,30 z", 1.05)
        g.line("^68,23 ^116,10", 0.5)
        g.shape(1, "6,24 14,16 ^60,14 ^64,32 ^16,42 6,38 z", 1.2)
        g.shape(2, "^10,24 ^20,20 ^20,36 ^10,38 z", 0.6)
        g.shape(2, "^52,17 ^60,16 ^62,30 ^54,32 z", 0.6)
        g.blot(.circle(57, 24, 1.5))
        g.blot(.circle(15, 29, 1.5))
        g.detail(0.12) { g in
            g.line("^26,22 ^48,19", 0.45)
            g.line("^26,33 ^48,30", 0.45)
            g.line(.circle(4, 32, 3.4), 0.7)
        }
        return g
    }

    static func thermos() -> DoodleGlyph {
        var g = DoodleGlyph("thermos", 0.1, 0.22, tilt: 18)
        g.shape(1, "^20,0 ^52,0 54,4 ^54,18 ^18,18 ^18,4 z", 1.1)
        g.detail(0.14) { g in
            for x in stride(from: 24.0, through: 48.0, by: 5) { g.line("^\(x),3 ^\(x),15", 0.45) }
        }
        g.shape(2, "^22,18 ^50,18 ^50,26 ^22,26 z", 0.9)
        g.shape(0, "22,26 50,26 60,34 62,44 ^62,118 56,126 ^16,126 10,118 ^10,44 12,34 z", 1.25)
        // Handle.
        g.line("^62,46 72,46 76,56 76,86 72,96 ^62,96", 1.25)
        g.line("^62,54 68,54 69,60 69,82 68,88 ^62,88", 0.75)
        g.shape(-1, "^10,60 ^62,60 ^62,92 ^10,92 z", 0.9)
        g.blot("^20,86 ^32,68 ^38,76 ^44,70 ^54,86 z")
        g.detail(0.13) { g in
            g.gel("^16,38 ^16,54", 0.8)
            g.gel("^16,98 ^16,116", 0.8)
            g.hatch("^50,98 ^61,98 ^61,118 ^50,124 z", angle: 68, gap: 2.8, w: 0.45)
            g.line("^10,108 ^62,108", 0.45)
        }
        return g
    }

    static func log() -> DoodleGlyph {
        var g = DoodleGlyph("log", 0.09, 0.2, tilt: 18)
        g.shape(1, "^20,12 ^112,4 120,14 124,28 120,42 ^112,50 ^22,56 z", 1.2)
        g.detail(0.12) { g in
            g.line("^36,18 56,14 ^80,14", 0.55)
            g.line("^44,40 70,38 ^96,36", 0.55)
            g.line("^60,28 ^82,26", 0.45)
            g.line("^94,12 ^106,11", 0.45)
            g.shade("^28,46 ^112,40 ^112,50 ^22,56 z")
        }
        g.shape(2, .ellipse(22, 34, 15, 22), 1.25)
        g.line(.ellipse(22, 34, 9.5, 15), 0.6)
        g.line(.ellipse(22, 34, 4.6, 8), 0.55)
        g.line("^20,26 ^24,30", 0.45)
        // A stub of a branch.
        g.shape(2, "^78,6 ^82,-8 ^92,-8 ^92,6 z", 0.95)
        g.line(.ellipse(87, -8, 5, 2.4), 0.6)
        return g
    }

    static func beetle() -> DoodleGlyph {
        var g = DoodleGlyph("beetle", 0.05, 0.11, tilt: 60)
        for (a, b) in [("^22,30 ^6,22 ^2,12", "left"), ("^20,44 ^4,46 ^0,56", "left"), ("^24,58 ^10,70 ^10,82", "left")] {
            _ = b
            g.line(DoodlePath(stringLiteral: a), 0.9)
        }
        for a in ["^42,30 ^58,22 ^62,12", "^44,44 ^60,46 ^64,56", "^40,58 ^54,70 ^54,82"] { g.line(DoodlePath(stringLiteral: a), 0.9) }
        g.line("^26,14 20,6 ^14,4", 0.7)
        g.line("^38,14 44,6 ^50,4", 0.7)
        g.shape(0, "32,28 44,32 48,50 42,68 32,76 22,68 16,50 20,32 z", 1.1)
        g.line("^32,28 ^32,76", 0.8)
        g.accent("24,14 32,10 40,14 42,26 32,30 22,26 z")
        g.gel("23,40 22,50", 0.7)
        return g
    }

    static func snail() -> DoodleGlyph {
        var g = DoodleGlyph("snail", 0.06, 0.13, tilt: 10)
        g.shape(0, "^6,62 60,62 80,60 92,52 96,38 ^90,30 ^84,44 74,50 60,48 ^20,50 8,54 z", 1.05)
        g.line("^92,32 ^88,16", 0.8)
        g.line("^96,32 ^100,16", 0.8)
        g.blot(.circle(87.5, 15, 1.8))
        g.blot(.circle(100.5, 15, 1.8))
        g.shape(2, "46,50 22,50 10,36 12,18 28,6 48,6 62,18 66,34 58,46 z", 1.15)
        g.line("40,48 28,46 20,34 22,22 34,16 46,20 50,30 44,38 34,36 32,28", 0.85)
        g.detail(0.09) { g in
            g.line("^6,66 ^26,67", 0.5)
            g.line("^60,66 ^90,65", 0.5)
        }
        return g
    }

    static func rabbit() -> DoodleGlyph {
        var g = DoodleGlyph("rabbit", 0.09, 0.2, tilt: 8)
        g.whole = true
        // Sitting up, ears back: the far ear first.
        g.shape(1, "^74,24 72,10 80,-4 86,2 86,14 ^82,28 z", 1)
        g.shade("^78,18 80,6 84,4 85,14 ^81,26 z")
        // Body, one line from the tail round to the paws.
        g.shape(1, "16,80 8,66 12,50 26,38 44,34 58,36 66,26 78,22 88,26 94,34 96,42 90,48 78,50 72,56 72,68 ^76,84 ^64,88 ^60,78 56,72 50,78 ^54,88 ^24,88 z", 1.2)
        g.shape(-1, .ellipse(9, 74, 8, 8.4), 0.95)
        // Near ear, pale inside.
        g.shape(1, "^68,28 62,12 66,-6 74,0 76,14 ^76,28 z", 1.05)
        g.tint(2, "^71,24 67,12 68,2 72,6 73,16 ^73,24 z")
        g.accent(.ellipse(82, 32, 1.8, 2))
        g.accent("^92,34 ^97,38 ^93,41 z")
        g.line("^90,44 82,45", 0.5)
        g.detail(0.12) { g in
            g.line("^96,42 ^108,40", 0.4)
            g.line("^96,44 ^108,46", 0.4)
            g.line("^52,72 44,60 ^32,58", 0.55)
            g.line("^64,84 ^66,88", 0.45)
            g.line("^20,92 ^78,91", 0.55)
            g.fur_(at: [(30, 46), (24, 52), (20, 60), (38, 42)], lean: (-0.4, 0.9), len: 5)
        }
        return g
    }

    static func dragonfly() -> DoodleGlyph {
        var g = DoodleGlyph("dragonfly", 0.06, 0.14, tilt: 60)
        for (w, s) in [("^44,28 60,6 86,2 92,10 74,24 ^46,34", 0), ("^44,34 66,30 88,34 90,44 68,46 ^46,38", 0)] {
            g.shape(s, DoodlePath(stringLiteral: w), 0.8)
        }
        for w in ["^36,28 20,6 -6,2 -12,10 6,24 ^34,34", "^36,34 14,30 -8,34 -10,44 12,46 ^34,38"] {
            g.shape(0, DoodlePath(stringLiteral: w), 0.8)
        }
        g.detail(0.09) { g in
            g.line("^48,30 72,12", 0.35)
            g.line("^50,36 ^84,38", 0.35)
            g.line("^32,30 8,12", 0.35)
            g.line("^30,36 ^-4,38", 0.35)
        }
        g.line("^40,44 ^40,100", 1.8)
        g.detail(0.09) { g in
            for y in stride(from: 54.0, through: 92.0, by: 9) { g.gel("^38.6,\(y) ^41.4,\(y)", 0.5) }
        }
        g.shape(2, .ellipse(40, 34, 5.4, 9), 0.95)
        g.accent(.ellipse(40, 21, 5, 4))
        return g
    }

    static func bee() -> DoodleGlyph {
        var g = DoodleGlyph("bee", 0.045, 0.1, tilt: 40)
        g.shape(-1, "^30,24 22,6 30,-2 40,6 ^38,24 z", 0.85)
        g.shape(-1, "^38,24 46,4 58,0 62,10 ^44,28 z", 0.85)
        g.shape(2, "10,36 20,24 38,22 54,26 62,36 54,46 38,50 20,48 z", 1.1)
        g.accent("^26,23.6 ^34,22.2 ^34,49.6 ^26,49 z")
        g.accent("^42,23 ^50,24.8 ^50,47 ^42,49 z")
        g.line("^10,36 ^2,36", 1.1)
        g.line("^60,30 ^68,22", 0.7)
        g.line("^62,34 ^72,30", 0.7)
        g.detail(0.07) { $0.stitch("^-14,20 -6,30 ^-14,42", dash: 2.5, gap: 3, w: 0.6) }
        return g
    }

    static func marshmallow() -> DoodleGlyph {
        var g = DoodleGlyph("marshmallow", 0.08, 0.17, tilt: 30)
        g.line("^0,4 ^56,48", 1.3)
        g.line("^2,1 ^58,45", 0.6)
        g.line("^8,10 ^2,14", 0.8)
        g.shape(-1, "^54,44 60,36 70,36 82,44 92,54 92,62 84,68 ^76,68 64,60 z", 1.15)
        g.shape(2, "^76,40 82,44 92,54 92,62 84,68 ^80,66 78,56 z", 0.7)
        g.shade("^84,50 92,56 92,62 84,66 z")
        g.line("^72,34 70,24 75,18", 0.6)
        g.line("^90,44 92,34 88,28", 0.6)
        return g
    }

    static func flashlight() -> DoodleGlyph {
        var g = DoodleGlyph("flashlight", 0.09, 0.2, tilt: 40)
        g.shape(1, "^0,14 ^66,14 ^66,42 ^0,42 z", 1.2)
        g.shape(2, "^66,14 ^76,14 ^92,2 ^92,54 ^76,42 ^66,42 z", 1.2)
        g.shape(-1, "^92,2 96,6 98,28 96,50 ^92,54 88,28 z", 1)
        g.shape(0, .rrect(26, 8, 22, 6, 2.4), 0.85)
        g.detail(0.12) { g in
            for x in stride(from: 6.0, through: 22.0, by: 4) { g.line("^\(x),16 ^\(x),40", 0.45) }
            g.shade("^0,34 ^66,34 ^66,42 ^0,42 z")
            g.gel("^30,20 ^60,20", 0.8)
            g.line("^106,14 ^116,8", 0.6)
            g.line("^108,28 ^120,28", 0.6)
            g.line("^106,42 ^116,48", 0.6)
        }
        return g
    }

    static func whistle() -> DoodleGlyph {
        var g = DoodleGlyph("whistle", 0.05, 0.11, tilt: 40)
        g.line("10,16 4,6 12,-4 24,-2 ^30,10", 0.9)
        g.shape(2, "22,28 40,16 ^86,16 ^86,30 ^62,30 62,46 46,58 26,54 14,42 z", 1.2)
        g.blot(.circle(36, 38, 7.5))
        g.gel("^66,20 ^82,20", 0.7)
        g.line("^56,30 ^62,22", 0.7)
        return g
    }

    static func mapleLeaf() -> DoodleGlyph {
        var g = DoodleGlyph("mapleLeaf", 0.05, 0.13, tilt: 60)
        g.shape(2, "^40,0 ^48,16 ^56,12 ^54,30 ^70,22 ^68,32 ^80,36 ^68,50 ^72,58 ^48,56 ^44,70 ^36,70 ^32,56 ^8,58 ^12,50 ^0,36 ^12,32 ^10,22 ^26,30 ^24,12 ^32,16 z", 1.05)
        g.line("^40,88 ^40,10", 0.85)
        g.detail(0.07) { g in
            g.line("^40,50 ^62,30", 0.5)
            g.line("^40,50 ^18,30", 0.5)
            g.line("^40,60 ^60,52", 0.45)
            g.line("^40,60 ^20,52", 0.45)
        }
        return g
    }

    static func clover() -> DoodleGlyph {
        var g = DoodleGlyph("clover", 0.035, 0.08, tilt: 50)
        for (x, y) in [(30.0, 15.0), (15.0, 34.0), (45.0, 34.0)] {
            g.shape(0, .circle(x, y, 13), 0.9)
        }
        g.line("^30,30 34,50 ^44,66", 0.9)
        g.line("^30,10 ^30,24", 0.4)
        return g
    }

    static func tinyShroom() -> DoodleGlyph {
        var g = DoodleGlyph("tinyShroom", 0.035, 0.085, tilt: 24)
        g.shape(-1, "^24,30 22,50 ^18,58 ^42,58 38,50 ^36,30 z", 0.9)
        g.shape(2, "2,32 8,14 30,4 52,14 58,32 40,36 20,36 z", 1.05)
        g.blot(.circle(24, 18, 3.2))
        g.blot(.circle(40, 24, 2.4))
        return g
    }

    static func twig() -> DoodleGlyph {
        var g = DoodleGlyph("twig", 0.045, 0.11, tilt: 70)
        g.line("^0,44 24,34 56,28 ^92,12", 1.2)
        g.line("^38,31 50,18 ^60,12", 0.9)
        g.line("^62,26 76,32 ^86,30", 0.8)
        g.shape(0, "^60,12 70,4 80,6 74,16 z", 0.8)
        g.shape(0, "^86,30 98,30 102,38 90,38 z", 0.8)
        return g
    }

    static func quill() -> DoodleGlyph {
        var g = DoodleGlyph("quill", 0.06, 0.15, tilt: 60)
        g.shape(2, "^62,2 70,18 66,34 ^60,38 62,44 50,62 ^38,60 40,66 28,76 16,74 18,58 ^26,54 ^20,46 28,28 42,12 z", 1)
        g.line("^2,106 16,78 34,52 ^62,2", 0.9)
        g.detail(0.08) { g in
            g.line("^48,28 ^62,26", 0.4)
            g.line("^40,40 ^58,42", 0.4)
            g.line("^32,48 ^24,36", 0.4)
        }
        return g
    }

    static func skillet() -> DoodleGlyph {
        var g = DoodleGlyph("skillet", 0.1, 0.2, tilt: 40)
        g.shape(1, "^68,26 ^124,18 128,24 ^126,30 ^70,38 z", 1.15)
        g.blot(.circle(120, 24, 2.2))
        g.shape(1, .ellipse(36, 34, 36, 30), 1.3)
        g.shape(-1, .ellipse(36, 32, 28, 22), 0.9)
        // Two eggs in it.
        g.shape(-1, "16,30 22,20 34,20 40,28 34,38 22,40 z", 0.75)
        g.shape(2, .circle(27, 29, 4.8), 0.75)
        g.shape(-1, "36,40 42,30 52,32 56,40 50,48 40,48 z", 0.75)
        g.shape(2, .circle(46, 39, 4.4), 0.75)
        g.detail(0.13) { g in
            g.line("^24,10 28,4 24,-2", 0.6)
            g.line("^44,8 48,2 44,-4", 0.6)
            g.shade("^6,46 20,58 36,61 54,58 66,46 56,50 36,54 18,50 z")
        }
        return g
    }

    static func ladybug() -> DoodleGlyph {
        var g = DoodleGlyph("ladybug", 0.03, 0.07, tilt: 90)
        g.line("^14,16 ^6,8", 0.7)
        g.line("^10,34 ^0,34", 0.7)
        g.line("^46,16 ^54,8", 0.7)
        g.line("^50,34 ^60,34", 0.7)
        g.shape(2, "30,10 46,16 52,34 44,52 30,58 16,52 8,34 14,16 z", 1.05)
        g.accent("20,12 30,4 40,12 30,16 z")
        g.line("^30,16 ^30,58", 0.8)
        for (x, y) in [(20.0, 26.0), (40.0, 26.0), (20.0, 42.0), (40.0, 42.0)] { g.blot(.circle(x, y, 3.2)) }
        return g
    }

    static func saw() -> DoodleGlyph {
        var g = DoodleGlyph("saw", 0.1, 0.22, tilt: 22)
        // A bow saw: the arched frame and the toothed blade.
        g.band(1, outer: "^0,48 8,20 36,4 72,0 104,8 ^124,44 ^116,48 98,16 72,8 40,12 14,26 ^8,50 z", inner: "^0,48 ^0,48 ^0,48 z", 1.2)
        var nodes: [DoodlePath.Node] = [.init(x: 4, y: 48, corner: true)]
        for i in 0..<14 {
            let x = 8 + Double(i) * 8
            nodes.append(.init(x: x, y: 54, corner: true))
            nodes.append(.init(x: x + 4, y: 49, corner: true))
        }
        nodes.append(.init(x: 120, y: 45, corner: true))
        g.shape(-1, DoodlePath(nodes: nodes, closed: true), 0.85)
        g.detail(0.14) { g in
            g.line("^20,20 38,12", 0.4)
            g.line("^60,6 ^80,6", 0.4)
        }
        return g
    }

    static func beans() -> DoodleGlyph {
        var g = DoodleGlyph("beans", 0.07, 0.15, tilt: 20)
        g.shape(1, "^6,14 ^6,76 16,84 44,84 54,76 ^54,14 z", 1.2)
        g.shape(-1, "^6,32 ^54,32 ^54,62 ^6,62 z", 0.85)
        for (x, y) in [(18.0, 42.0), (28.0, 47.0), (38.0, 42.0), (24.0, 53.0), (36.0, 53.0)] { g.shape(2, .ellipse(x, y, 4.6, 3.2, rot: 20), 0.6) }
        g.shape(-1, .ellipse(30, 14, 24, 7), 1.05)
        // The lid bent back.
        g.shape(2, "^42,10 54,-2 66,-4 70,4 62,12 ^52,14 z", 0.95)
        g.detail(0.1) { g in
            g.line("^6,22 ^54,22", 0.45)
            g.line("^6,70 ^54,70", 0.45)
            g.shade("^44,32 ^54,32 ^54,76 44,84 ^40,84 z")
        }
        return g
    }

    static func sleepingBag() -> DoodleGlyph {
        var g = DoodleGlyph("sleepingBag", 0.1, 0.22, tilt: 18)
        // Rolled, tied with two straps.
        g.shape(1, "^22,10 ^100,6 ^104,62 ^24,66 z", 1.2)
        for (a, b) in [(40.0, 42.0), (78.0, 80.0)] {
            g.shape(2, .poly([(a - 5, 7.5), (a + 5, 7), (b + 5, 64), (b - 5, 64.5)], closed: true), 0.9)
            g.detail(0.13) { $0.blot(.rrect(a - 3, 28, 7, 7, 1)) }
        }
        g.shape(0, .ellipse(100, 34, 16, 28), 1.25)
        g.line("100,14 92,24 92,38 100,48 106,40 106,28 100,26 ^97,32", 0.75)
        g.detail(0.13) { g in
            g.shade("^24,50 ^100,46 ^102,62 ^24,66 z")
            g.line("^52,8 ^54,64", 0.45)
            g.line("^64,8 ^66,63", 0.45)
        }
        return g
    }

    static func paddle() -> DoodleGlyph {
        var g = DoodleGlyph("paddle", 0.1, 0.24, tilt: 34)
        g.shape(1, "^24,4 ^40,4 ^42,12 ^22,12 z", 1)
        g.shape(2, "^29,12 ^35,12 ^36,88 ^28,88 z", 1)
        g.shape(1, "^28,84 ^36,84 46,100 50,132 44,160 32,172 20,160 14,132 18,100 z", 1.2)
        g.line("^32,92 ^32,160", 0.6)
        g.detail(0.15) { g in
            g.line("^24,120 ^22,146", 0.45)
            g.gel("^42,110 ^44,136", 0.8)
            g.stitch("^30,30 ^31,60", dash: 3, gap: 3, w: 0.45)
        }
        return g
    }

    static func tuftGrass() -> DoodleGlyph {
        var g = DoodleGlyph("tuftGrass", 0.03, 0.075, tilt: 12)
        g.line("^20,50 16,30 ^6,14", 1)
        g.line("^24,50 24,24 ^22,2", 1)
        g.line("^28,50 32,32 ^42,18", 1)
        g.line("^14,50 ^34,50", 0.7)
        return g
    }

    static func flint() -> DoodleGlyph {
        var g = DoodleGlyph("flint", 0.04, 0.09, tilt: 40)
        // An arrowhead knapped from stone.
        g.shape(1, "^30,0 ^50,44 ^38,54 ^34,46 ^26,46 ^22,54 ^10,44 z", 1)
        g.line("^30,4 ^30,44", 0.5)
        g.line("^24,20 ^30,28", 0.42)
        g.line("^36,20 ^30,28", 0.42)
        g.line("^20,34 ^30,40", 0.42)
        g.line("^40,34 ^30,40", 0.42)
        return g
    }

    static func sparkTrio() -> DoodleGlyph {
        // A few rising embers.
        var g = DoodleGlyph("embers", 0.03, 0.07, tilt: 30)
        g.shape(2, "^18,0 ^24,12 ^18,20 ^12,12 z", 0.7)
        g.shape(2, "^38,18 ^42,26 ^38,32 ^34,26 z", 0.6)
        g.blot(.circle(6, 34, 1.8))
        g.blot(.circle(28, 42, 1.4))
        return g
    }
}

nonisolated extension DoodleGlyph {
    /// A handful of short strokes at given places, for small animals.
    mutating func fur_(at points: [(Double, Double)], lean: (Double, Double), len: Double, w: Double = 0.5) {
        for p in points { line(.poly([p, (p.0 + lean.0 * len, p.1 + lean.1 * len)]), w) }
    }
}
