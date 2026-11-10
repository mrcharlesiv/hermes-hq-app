// The Sports drawings. Spot colours mean something: 0 is tomato red, 1 is deep teal, 2 is a pale sun yellow; bare paper is the
// white of a ball. No team, league or maker's mark anywhere.

import CoreGraphics
import Foundation

nonisolated enum DoodleSports {
    static func all() -> [DoodleGlyph] {
        var list = [soccerBall(), sneaker(), boxingGloves(), bicycle(), trophy(), golfBag(), tennisRacket(), hoop(), basketball(), mitt(), hockeySticks(), iceSkate(),
                    football(), volleyball(), rugby(), baseballBat(), medal(), whistle(), golfGreen(), golfTee(), hockeyHelmet(), shuttlecock(), badminton(), pingPong(), bowling(), dartboard(),
                    skateboard(), rollerSkate(), bikeHelmet(), dumbbell(), kettlebell(), jumpRope(), stopwatch(), squeezeBottle(), swimGoggles(), cap(), jersey(), scoreboard(), goal(), trainingCone(),
                    pennant(), megaphone(), podium(), archery(), cricket(), eightBall(), frisbee(), gymBag(), ticket(), gridHelmet(), tennisBall(), wristband(),
                    playXO(), tinyBall(), tinyPuck(), tinyStar(), motionLines(), chevronUp(), tinyShuttle(), tinyPlus()]
        list += DoodleFillers.common().filter { ["dot"].contains($0.name) }
        list += extras() + littles()
        for i in list.indices {
            list[i].fixed = true
            list[i].done()
        }
        return list
    }

    static func soccerBall() -> DoodleGlyph {
        var g = DoodleGlyph("soccerBall", 0.16, 0.42, tilt: 40)
        g.must = true
        let c = 50.0, R = 48.0
        g.shape(-1, .circle(c, c, R), 1.5)
        typealias K = DoodleKit
        for i in 0..<5 {
            let a = -90 + Double(i) * 72
            // A black patch on the rim, its outer edge following the ball.
            let p0 = K.polar(c, c, 34, a - 15), p1 = K.polar(c, c, 34, a + 15)
            var pts = [p0, K.polar(c, c, 28, a), p1]
            pts.append(K.polar(c, c, 47.4, a + 23))
            pts.append(K.polar(c, c, 47.8, a + 8))
            pts.append(K.polar(c, c, 47.8, a - 8))
            pts.append(K.polar(c, c, 47.4, a - 23))
            g.accent(.poly(pts, closed: true))
            // Seams: centre patch to rim patch, then a fork between neighbours.
            g.line(.poly([K.polar(c, c, 14.5, a), K.polar(c, c, 28, a)]), 0.85)
            let fork = K.polar(c, c, 41, a + 36)
            g.line(.poly([p1, fork]), 0.85)
            g.line(.poly([K.polar(c, c, 34, a + 72 - 15), fork]), 0.85)
            g.line(.poly([fork, K.polar(c, c, 48, a + 36)]), 0.85)
        }
        g.accent(K.gon(c, c, 15, sides: 5))
        g.detail(0.2) { g in
            g.hatch("^70,76 ^88,62 ^86,74 ^72,90 ^60,96 z", angle: 52, gap: 2.8, w: 0.45)
            g.gel("14,36 20,24 ^30,14", 1.1)
        }
        return g
    }

    static func basketball() -> DoodleGlyph {
        var g = DoodleGlyph("basketball", 0.14, 0.38, tilt: 50)
        g.shape(0, .circle(50, 50, 48), 1.45)
        g.line("^50,2 ^50,98", 1.05)
        g.line("^2,50 ^98,50", 1.05)
        g.line("^17,16 30,34 32,50 30,66 ^17,84", 1.05)
        g.line("^83,16 70,34 68,50 70,66 ^83,84", 1.05)
        g.detail(0.16) { g in
            g.speckle(10, 56, 28, 80, n: 12, r: 0.55, seed: 3)
            g.speckle(72, 22, 90, 44, n: 10, r: 0.55, seed: 4)
            g.gel("14,34 20,24 ^28,17", 1.2)
            g.hatch("^60,86 ^78,76 ^88,64 ^92,70 ^80,86 ^64,94 z", angle: 50, gap: 2.8, w: 0.45)
        }
        return g
    }

    static func football() -> DoodleGlyph {
        var g = DoodleGlyph("football", 0.12, 0.32, tilt: 40)
        g.shape(0, "^0,40 16,18 50,8 84,18 ^100,40 84,62 50,72 16,62 z", 1.45)
        // Bands at each end, laces on top.
        g.shape(-1, "^16,18 22,15.5 ^28,40 22,64.5 ^16,62 22,40 z", 0.8)
        g.shape(-1, "^84,18 78,15.5 ^72,40 78,64.5 ^84,62 78,40 z", 0.8)
        g.line("^34,24 50,23 ^66,24", 0.95)
        for x in stride(from: 37.0, through: 63.0, by: 6.5) { g.line("^\(x),19 ^\(x),28", 0.95) }
        g.detail(0.15) { g in
            g.line("^10,40 ^20,40", 0.42)
            g.gel("30,14 40,11.5 ^48,11", 1)
            g.hatch("^40,58 ^72,56 ^62,66 ^46,68 z", angle: 60, gap: 2.8, w: 0.45)
        }
        return g
    }

    static func volleyball() -> DoodleGlyph {
        var g = DoodleGlyph("volleyball", 0.12, 0.32, tilt: 60)
        g.shape(-1, .circle(50, 50, 48), 1.45)
        let c = (50.0, 50.0)
        // Three families of panels swirl out from one pole. Each is three long strips lying side by side, the middle one coloured.
        for (k, rot) in [0.0, 120, 240].enumerated() where k < 2 {
            let strip: DoodlePath = "^38,45.5 46,34 56,25 68,17 ^82.5,14.6 72.9,7.8 ^62,3.6 44,14 32,26 ^24,40 ^31,42.6 z"
            g.tint(k == 0 ? 1 : 0, strip.rotated(rot, about: c))
        }
        for rot in [0.0, 120, 240] {
            func T(_ p: DoodlePath) -> DoodlePath { p.rotated(rot, about: c) }
            g.line(T("^50,50 64,38 76,30 ^92,27"), 1.05)
            g.line(T("^38,45.5 46,34 56,25 68,17 ^82.5,14.6"), 0.85)
            g.line(T("^24,40 32,26 44,14 ^62,3.6"), 0.85)
        }
        g.detail(0.16) { $0.gel("9,42 12,31 ^18,23", 1.1) }
        return g
    }

    static func rugby() -> DoodleGlyph {
        var g = DoodleGlyph("rugby", 0.1, 0.27, tilt: 50)
        g.shape(-1, "50,0 72,14 84,44 72,80 50,92 28,80 16,44 28,14 z", 1.4)
        g.tint(1, "^21,28 ^79,28 ^83,44 ^81,58 ^19,58 ^17,44 z")
        g.line("^21,28 ^79,28", 0.75)
        g.line("^19,58 ^81,58", 0.75)
        g.line("50,0 42,22 40,46 42,70 ^50,92", 0.75)
        g.line("50,0 58,22 60,46 58,70 ^50,92", 0.75)
        for y in [36.0, 42.0, 48.0] { g.line("^46,\(y) ^54,\(y)", 0.75) }
        g.detail(0.14) { $0.gel("26,26 30,18 ^37,10", 1) }
        return g
    }

    static func baseballBat() -> DoodleGlyph {
        var g = DoodleGlyph("baseballBat", 0.14, 0.36, tilt: 40)
        // A bat with a knob and a taped grip; a ball leaning on it.
        g.shape(2, "^47,0 56,0 60,10 60,54 54,92 53,118 ^46,118 45,92 40,54 40,10 z", 1.35)
        g.shape(1, .rrect(45, 102, 9.5, 26, 2), 1)
        g.shape(1, .ellipse(50, 131, 9, 4.2), 1.05)
        g.detail(0.16) { g in
            for y in stride(from: 106.0, through: 124.0, by: 4.0) { g.line("^45,\(y) ^54.5,\(y + 2)", 0.42) }
            g.gel("^45,10 ^45.6,50", 1)
            g.hatch("^52,6 ^59,10 ^59,52 ^52,84 z", angle: 80, gap: 3, w: 0.42)
        }
        g.shape(-1, .circle(80, 112, 19), 1.3)
        g.stitch("66,99 71,110 ^69,124", dash: 2, gap: 1.5, w: 0.8)
        g.stitch("92,98 88,110 ^92,125", dash: 2, gap: 1.5, w: 0.8)
        g.detail(0.16) { $0.hatch("^84,120 ^96,108 ^92,124 ^82,130 z", angle: 50, gap: 2.4, w: 0.4) }
        return g
    }

    static func mitt() -> DoodleGlyph {
        var g = DoodleGlyph("mitt", 0.16, 0.36, tilt: 22)
        // Fingers fan up, the thumb comes in from the right, webbing between.
        g.shape(1, "^62,36 ^78,28 ^88,40 ^78,60 ^60,60 z", 1.15)
        g.strings(72, 44, 12, 15, gapX: 5, gapY: 5, w: 0.5)
        g.shape(2, "20,84 6,62 4,38 10,28 18,28 22,36 ^22,14 30,6 38,12 ^40,26 ^42,8 52,2 60,10 ^60,28 ^66,14 74,12 78,20 ^72,46 ^88,34 98,36 100,48 92,66 80,88 66,100 42,104 26,98 z", 1.5)
        // The palm pocket, stitched, a ball sitting in it.
        g.shape(1, "26,62 36,50 52,46 68,50 76,62 72,80 56,92 38,90 28,78 z", 1)
        g.line("^22,36 ^24,54", 0.6)
        g.line("^40,26 ^42,46", 0.6)
        g.line("^60,28 ^58,46", 0.6)
        g.stitch("^18,50 16,66 ^26,86", dash: 2.2, gap: 1.8, w: 0.5)
        g.stitch("^88,50 84,70 ^72,90", dash: 2.2, gap: 1.8, w: 0.5)
        g.shape(-1, .circle(50, 69, 15), 1.15)
        g.stitch("^40,58 44,68 ^40,80", dash: 1.8, gap: 1.2, w: 0.6)
        g.stitch("^60,58 56,68 ^60,80", dash: 1.8, gap: 1.2, w: 0.6)
        // Wrist strap.
        g.shape(0, "^24,94 ^70,98 ^66,112 ^28,110 z", 1.15)
        g.shape(-1, .rrect(40, 99, 12, 9, 1.5), 0.7)
        return g
    }

    static func tennisRacket() -> DoodleGlyph {
        var g = DoodleGlyph("tennisRacket", 0.2, 0.42, tilt: 30)
        g.must = true
        // A taped handle and throat first, then the head.
        g.shape(1, .rrect(39, 102, 12, 38, 2.5), 1.25)
        g.detail(0.2) { g in
            for y in stride(from: 106.0, through: 136.0, by: 4.6) { g.line("^39,\(y) ^51,\(y + 2.2)", 0.42) }
        }
        g.shape(1, .rrect(37, 138, 16, 6, 2), 1.05)
        g.line("^41,84 ^41,102", 1.15)
        g.line("^49,84 ^49,102", 1.15)
        g.line("^26,76 ^40,102", 1.15)
        g.line("^64,76 ^50,102", 1.15)
        g.shape(2, "^33,86 ^57,86 ^50,100 ^40,100 z", 0.8)
        g.band(0, outer: .ellipse(45, 44, 42, 46), inner: .ellipse(45, 44, 34.5, 38.5), 1.45, innerW: 0.9)
        g.strings(45, 44, 33.5, 37.5, gapX: 6, gapY: 6, w: 0.5)
        g.detail(0.2) { $0.gel("9,30 13,18 ^23,9", 0.8) }
        // The ball resting on the strings' edge.
        g.shape(2, .circle(82, 112, 13), 1.2)
        g.line("^71,105 77,112 ^74,122", 0.7)
        g.line("^93,104 87,112 ^92,120", 0.7)
        return g
    }

    static func tennisBall() -> DoodleGlyph {
        var g = DoodleGlyph("tennisBall", 0.05, 0.13, tilt: 60)
        g.shape(2, .circle(30, 30, 29), 1.2)
        g.line("^8,12 18,28 ^12,50", 0.95)
        g.line("^52,10 42,30 ^50,50", 0.95)
        return g
    }

    static func badminton() -> DoodleGlyph {
        var g = DoodleGlyph("badminton", 0.12, 0.3, tilt: 32)
        g.shape(0, .rrect(25, 92, 8, 34, 2), 1.1)
        g.line("^29,56 ^29,92", 1.3)
        g.band(1, outer: "29,0 46,8 54,28 48,48 ^29,62 ^10,48 4,28 12,8 z", inner: "29,5 42,12 49,28 44,44 ^29,55 ^14,44 9,28 16,12 z", 1.2, innerW: 0.8)
        g.strings(29, 29, 19, 24, gapX: 5, gapY: 5, w: 0.42)
        g.detail(0.16) { g in
            for y in stride(from: 96.0, through: 122.0, by: 4.5) { g.line("^25,\(y) ^33,\(y + 2)", 0.42) }
        }
        return g
    }

    static func shuttlecock() -> DoodleGlyph {
        var g = DoodleGlyph("shuttlecock", 0.07, 0.18, tilt: 60)
        g.shape(-1, "^24,50 ^6,6 14,4 24,8 34,4 ^44,2 ^38,50 z", 1.15)
        g.line("^12,5 ^28,50", 0.55)
        g.line("^24,8 ^31,50", 0.55)
        g.line("^35,4 ^34,50", 0.55)
        g.line("^16,24 ^39,23", 0.6)
        g.line("^20,34 ^38,33", 0.6)
        g.shape(0, "^22,50 ^40,50 42,62 36,70 ^26,70 20,62 z", 1.25)
        g.line("^22,56 ^41,56", 0.6)
        return g
    }

    static func sneaker() -> DoodleGlyph {
        var g = DoodleGlyph("sneaker", 0.26, 0.42, tilt: 10)
        g.must = true
        // Tongue, standing proud of the collar.
        g.shape(2, "^44,16 46,4 54,0 62,4 64,14 ^62,26 ^52,34 z", 1.1)
        // A high canvas upper.
        g.shape(0, "^10,88 11,62 13,36 12,14 26,12 ^46,12 ^52,30 60,40 74,50 88,57 104,62 ^116,68 ^124,86 ^124,92 ^10,92 z", 1.4)
        // The white toe bumper and heel stay.
        g.shape(-1, "^88,92 90,76 98,62 ^104,62 ^116,68 124,80 ^124,92 z", 1.2)
        g.shape(1, "^10,88 11,62 12,48 ^24,50 26,70 ^28,92 ^10,92 z", 1.1)
        g.shape(-1, "^12,14 26,12 ^46,12 ^48,20 ^12,22 z", 1)
        g.detail(0.2) { g in
            g.stitch("^92,88 94,76 ^100,66", dash: 2.2, gap: 1.8, w: 0.45)
            g.line("^62,44 56,62 62,78 ^68,92", 0.55)
            g.stitch("^59,44 53,62 59,78 ^65,92", dash: 2.2, gap: 1.8, w: 0.42)
            g.hatch("^30,56 ^46,52 ^52,86 ^30,88 z", angle: 62, gap: 3.2, w: 0.42)
            g.gel("^16,28 ^15,44", 0.8)
        }
        // An ankle badge, round, a bolt on it.
        g.shape(-1, .circle(30, 38, 11), 1.05)
        g.shape(2, "^33,29 ^25,39 ^30,39 ^27,47 ^36,36 ^31,36 z", 0.75)
        // Laces, crossing up the throat, with eyelets.
        let near: [(Double, Double)] = [(50, 26), (56, 37), (65, 45), (76, 52), (87, 58)]
        let far: [(Double, Double)] = [(60, 20), (68, 30), (77, 38), (88, 45), (98, 51)]
        for i in 0..<4 {
            g.line(.poly([near[i + 1], far[i]]), 1.1)
            g.line(.poly([far[i + 1], near[i]]), 1.1)
        }
        for p in near { g.blot(.circle(p.0, p.1, 1.5)) }
        g.line("^60,20 68,10 78,10 76,18 ^60,20", 0.85)
        g.line("^60,20 54,28 ^48,26", 0.8)
        // The rubber sole, one stripe, a little tread.
        g.shape(-1, "^6,90 ^128,90 134,96 130,106 ^8,106 3,98 z", 1.35)
        g.tint(1, "^5,94 ^132,94 ^131.5,98 ^4,98 z")
        g.line("^5,94 ^132,94", 0.5)
        g.line("^4,98 ^131.5,98", 0.5)
        for x in stride(from: 12.0, through: 124.0, by: 7.4) { g.line("^\(x),102 ^\(x + 1.6),106", 0.6) }
        return g
    }

    static func boxingGloves() -> DoodleGlyph {
        var g = DoodleGlyph("boxingGloves", 0.24, 0.42, tilt: 10)
        g.must = true
        // They hang by their laces.
        g.line("^62,-8 ^66,-16", 0.9)
        g.line("^34,24 44,6 ^62,-8 78,8 ^90,30", 1)
        func glove(_ g: inout DoodleGlyph, sep: Int, _ T: (DoodlePath) -> DoodlePath) {
            // Thumb on the outside, the big padded fist, a cuff.
            g.shape(sep, T("^12,62 2,50 2,34 12,28 22,32 ^26,46 z"), 1.3)
            g.shape(sep, T("^16,92 8,70 8,46 20,20 40,8 62,14 74,34 74,60 66,80 ^62,92 z"), 1.55)
            g.line(T("^8,46 22,48 ^32,62"), 0.8)
            g.detail(0.2) { g in
                g.gel(T("24,26 34,18 ^46,16"), 1.3)
                g.gel(T("^18,36 ^16,42"), 1)
                g.hatch(T("^58,20 ^72,36 ^72,60 ^64,78 ^54,78 z"), angle: 62, gap: 3.2, w: 0.45)
                g.line(T("^30,66 44,70 ^60,66"), 0.5)
            }
            g.shape(-1, T(.rrect(13, 90, 52, 24, 3)), 1.35)
            g.shape(1, T("^13,94 ^65,94 ^65,101 ^13,101 z"), 0.8)
            g.line(T("^34,88 ^44,116"), 0.8)
            g.line(T("^44,88 ^34,116"), 0.8)
        }
        glove(&g, sep: 0) { $0.mirrored(about: 40).rotated(10, about: (40, 60)).moved(-4, 8) }
        glove(&g, sep: 1) { $0.rotated(-8, about: (40, 60)).moved(50, 18) }
        return g
    }

    static func trophy() -> DoodleGlyph {
        var g = DoodleGlyph("trophy", 0.2, 0.42, tilt: 10)
        g.must = true
        // Two big handles, doubled.
        g.line("^24,18 6,16 -2,30 6,48 ^30,60", 1.4)
        g.line("^26,26 12,24 6,31 12,44 ^30,52", 0.8)
        g.line("^100,18 118,16 126,30 118,48 ^94,60", 1.4)
        g.line("^98,26 112,24 118,31 112,44 ^94,52", 0.8)
        g.shape(2, "^56,78 ^68,78 ^70,104 ^54,104 z", 1.2)
        g.shape(2, "^20,8 ^104,8 104,32 94,58 74,76 ^62,82 ^50,76 30,58 20,32 z", 1.55)
        g.shape(-1, .ellipse(62, 8, 42, 7), 1.2)
        g.accent(.ellipse(62, 9, 35, 3.8))
        g.tint(0, "^26,20 ^98,20 ^97,30 ^27,30 z")
        g.line("^25.6,20 ^98.4,20", 0.6)
        g.line("^27,30 ^97,30", 0.6)
        g.shape(-1, DoodleFillers.starPath(62, 52, 15), 1.05)
        // Laurel either side of the star.
        g.detail(0.2) { g in
            for i in 0..<4 {
                let t = Double(i)
                g.line(.poly([(42 - t * 2, 40 + t * 7), (36 - t * 2, 37 + t * 7)]), 0.55)
                g.line(.poly([(82 + t * 2, 40 + t * 7), (88 + t * 2, 37 + t * 7)]), 0.55)
            }
            g.line("42,38 36,50 ^46,66", 0.5)
            g.line("82,38 88,50 ^78,66", 0.5)
            g.gel("^30,16 ^33,36", 1.3)
            g.hatch("^86,34 ^100,34 ^92,56 ^76,72 z", angle: 62, gap: 3, w: 0.42)
        }
        // A stepped base with a plate.
        g.shape(0, "^44,104 ^80,104 ^86,112 ^38,112 z", 1.15)
        g.shape(1, .rrect(28, 112, 68, 22, 2.5), 1.4)
        g.shape(-1, .rrect(44, 117, 36, 11, 1.5), 0.8)
        g.line("^50,121 ^74,121", 0.45)
        g.line("^52,124.5 ^72,124.5", 0.45)
        return g
    }

    static func medal() -> DoodleGlyph {
        var g = DoodleGlyph("medal", 0.12, 0.3, tilt: 24)
        g.noFlip = true
        // A striped ribbon in a V.
        g.shape(0, "^10,0 ^32,0 ^52,50 ^40,60 z", 1.25)
        g.shape(1, "^70,0 ^48,0 ^28,50 ^40,60 z", 1.25)
        g.line("^21,1 ^46,55", 0.7)
        g.line("^59,1 ^34,55", 0.7)
        g.shape(2, .rrect(30, 50, 20, 8, 2), 1.05)
        g.shape(2, .circle(40, 84, 28), 1.5)
        g.line(.circle(40, 84, 21.5), 0.7)
        g.shape(-1, DoodleFillers.starPath(40, 85, 14), 1)
        g.detail(0.16) { g in
            for i in 0..<30 {
                let a = Double(i) * 12
                g.line(.poly([DoodleKit.polar(40, 84, 23.6, a), DoodleKit.polar(40, 84, 26.4, a)]), 0.42)
            }
            g.gel("17,76 21,68 ^28,62", 1)
        }
        return g
    }

    static func whistle() -> DoodleGlyph {
        var g = DoodleGlyph("whistle", 0.09, 0.26, tilt: 28)
        // The cord loops away from the ring.
        g.line("10,44 -2,30 2,12 20,6 38,12 ^44,24", 0.85)
        g.line(.circle(10, 50, 5.6), 1)
        // Mouthpiece, barrel.
        g.shape(0, "^52,28 ^112,20 ^114,40 ^76,48 ^72,50 z", 1.3)
        g.shape(0, .circle(44, 58, 28), 1.5)
        g.shape(-1, .circle(44, 58, 19), 0.95)
        g.shape(2, .circle(50, 62, 8.6), 0.95)
        g.accent("^54,29 ^72,26 ^66,38 ^52,38 z")
        g.line("^112,20 ^114,40", 0)
        g.detail(0.14) { g in
            g.gel("24,42 30,35 ^38,32", 1)
            g.hatch("^60,74 ^70,56 ^70,66 ^58,82 z", angle: 50, gap: 2.4, w: 0.42)
            g.line("^78,30 ^108,26", 0.45)
        }
        return g
    }

    static func golfBag() -> DoodleGlyph {
        var g = DoodleGlyph("golfBag", 0.22, 0.42, tilt: 8)
        g.must = true
        g.noTuck = true
        // An iron head side on: a hosel at the shaft, a blade reaching away from it, grooves across the face.
        func iron(_ g: inout DoodleGlyph, sep: Int, _ T: (DoodlePath) -> DoodlePath) {
            g.shape(sep, T("^0,0 ^-2,-5 ^-24,-14 ^-30,-10 -31,0 ^-28,6 ^-3,8 z"), 1.2)
            g.detail(0.2) { g in
                for t in [0.0, 1, 2, 3] { g.line(T(.poly([(-25 + t * 5, -8 + t * 1.4), (-24 + t * 5, 2 + t * 0.6)])), 0.4) }
            }
        }
        // Far clubs first, standing well clear of the bag so they read as clubs: two irons, a bare driver, a head cover in front.
        g.line("^32,64 ^24,14", 1.1)
        iron(&g, sep: 1) { $0.moved(24, 12) }
        g.line("^52,64 ^58,2", 1.1)
        iron(&g, sep: 0) { $0.mirrored(about: 0).moved(58, 0) }
        // The driver: a deep rounded head with a flat face.
        g.line("^62,64 ^84,28", 1.1)
        g.shape(2, "^81,33 ^82,26 90,16 104,13 116,19 ^119,31 ^112,36 ^94,36 z", 1.25)
        g.shade("^81,33 ^112,36 ^119,31 ^116,29 ^94,31 z")
        g.detail(0.2) { g in
            g.line("^112,22 ^115,29", 0.42)
            g.line("^108,24 ^111,30", 0.42)
            g.gel("88,23 95,18 ^104,17", 0.8)
        }
        // A knitted head cover slumped over the side, with its bands and a little number tag.
        // Slumped over the side, its toe hanging down: a sock, not a ball.
        g.shape(1, "^37,66 36,50 33,38 28,26 20,24 10,28 4,38 ^7,44 18,44 26,44 30,52 ^31,66 z", 0)
        g.shape(1, "^36,66 37,48 40,34 46,20 40,10 24,9 11,15 5,26 7,36 16,34 26,32 28,44 28,54 ^26,66 z", 1.3)
        g.tint(2, "^27,42 ^41,34 ^38,44 ^27,50 z")
        g.line("^27.6,42 ^41,33", 0.5)
        g.line("^28,50 ^38.6,44", 0.5)
        g.detail(0.2) { g in
            for x in [30.0, 33.0] { g.line(.poly([(x, 54), (x, 64)]), 0.38) }
            g.gel("^14,20 ^24,14", 0.7)
        }
        // The strap goes on before the bag: its ends disappear behind the tabs that hold it.
        g.shape(-1, DoodlePath.taper([(72, 74), (86, 80), (95, 96), (97, 124), (88, 148), (68, 160)], 5, 5), 1)
        g.shape(1, DoodlePath.taper([(92, 88), (99, 106), (98, 132)], 10, 10), 1.15)
        g.detail(0.2) { $0.stitch("^92,92 ^96,106 ^95.4,128", dash: 2, gap: 1.6, w: 0.42) }
        // The bag, a long tube wide at the mouth, narrowing to a stiff foot.
        g.shape(0, "^16,70 ^74,70 73,110 69,150 ^65,186 ^25,186 ^21,150 17,110 z", 1.5)
        g.shade("^60,70 ^74,70 73,110 69,150 ^65,186 ^56,186 61,150 64,110 z")
        // The stiff cuff with its dividers.
        g.shape(-1, "^12,60 ^78,60 ^75,76 ^15,76 z", 1.35)
        g.line("^34,60 ^35,76", 0.65)
        g.line("^56,60 ^55,76", 0.65)
        g.detail(0.2) { $0.stitch("^16,71 ^74,71", dash: 2, gap: 1.4, w: 0.42) }
        // A band round it, a little ball pocket, the long club pocket with its zip.
        g.tint(2, "^17.5,84 ^72.5,84 ^72,94 ^18,94 z")
        g.line("^17.4,84 ^72.6,84", 0.7)
        g.line("^18,94 ^72,94", 0.7)
        g.shape(-1, .circle(45, 110, 9.5), 0.95)
        g.detail(0.2) { g in
            for (x, y) in [(41.0, 106.0), (45.0, 104.6), (49.0, 106.0), (39.6, 110.4), (43.6, 110), (47.8, 110), (51, 110.6), (41.4, 114.4), (45.4, 114.4), (49.4, 114.4)] { g.blot(.circle(x, y, 0.75)) }
        }
        g.shape(1, "^26,126 ^64,126 ^62,164 58,170 ^32,170 28,164 z", 1.2)
        g.line("^30,135 ^60,135", 1)
        g.shape(-1, .rrect(55, 133, 4.4, 9, 1.4), 0.6)
        g.detail(0.2) { $0.stitch("^33,146 ^57,146", dash: 2, gap: 1.2, w: 0.42) }
        // The tough foot and its two little feet.
        g.shape(1, "^22,176 ^68,176 ^65,188 ^25,188 z", 1.1)
        g.shape(1, "^28,188 ^37,188 ^36,194 ^29,194 z", 0.9)
        g.shape(1, "^53,188 ^62,188 ^61,194 ^54,194 z", 0.9)
        // The tabs and rivets that hold the strap on.
        g.shape(1, "^66,72 ^76,72 ^76,82 ^66,82 z", 0.9)
        g.blot(.circle(71, 77, 1.2))
        g.shape(1, "^60,154 ^71,154 ^70,166 ^59,166 z", 0.9)
        g.blot(.circle(65, 160, 1.2))
        g.detail(0.2) { g in
            g.gel("^21,98 ^25,150", 0.9)
            g.gel("^17,64 ^32,64", 0.7)
        }
        return g
    }

    static func golfGreen() -> DoodleGlyph {
        var g = DoodleGlyph("golfGreen", 0.12, 0.34, tilt: 6)
        // A green with a hole, the pin and its pennant, a ball rolling in.
        g.shape(1, "^-8,98 10,84 40,78 80,80 108,88 ^120,100 96,110 50,114 10,110 z", 1.4)
        g.detail(0.16) { g in
            g.line("^6,100 ^16,98", 0.45)
            g.line("^90,102 ^104,99", 0.45)
            g.line("^30,104 ^44,106", 0.45)
            g.line("^70,106 ^80,105", 0.45)
        }
        g.accent(.ellipse(56, 92, 9, 3.4))
        g.line("^56,92 ^56,-2", 1.25)
        g.shape(0, "^56,0 76,8 ^96,14 ^76,20 ^56,28 z", 1.25)
        g.detail(0.16) { $0.line("^60,8 ^60,22", 0.42) }
        g.shape(-1, .circle(28, 92, 7), 1)
        g.stitch("^34,91 ^46,91", dash: 2, gap: 1.8, w: 0.6)
        return g
    }

    static func golfTee() -> DoodleGlyph {
        var g = DoodleGlyph("golfTee", 0.08, 0.2, tilt: 12)
        g.shape(0, "^12,46 ^48,46 ^34,58 ^33,90 ^30,98 ^27,90 ^26,58 z", 1.1)
        g.shape(-1, .circle(30, 25, 24), 1.4)
        g.detail(0.1) { g in
            for r in 0..<4 {
                for c in 0..<(5 - r % 2) {
                    let x = 13 + Double(c) * 8.4 + (r % 2 == 1 ? 4.2 : 0), y = 12 + Double(r) * 8
                    if hypot(x - 30, y - 25) < 19 { g.blot(.circle(x, y, 1.15)) }
                }
            }
        }
        return g
    }

    static func hockeySticks() -> DoodleGlyph {
        var g = DoodleGlyph("hockeySticks", 0.14, 0.36, tilt: 8)
        // Crossed, each blade pointing out to its own side, tape on the blades, a puck where they meet.
        func stick(_ g: inout DoodleGlyph, sep: Int, _ T: (DoodlePath) -> DoodlePath) {
            g.shape(sep, T("^-4,0 ^4,0 ^6,92 ^10,98 ^44,111 49,117 46,127 ^2,110 -3,104 ^-4,92 z"), 1.35)
            // The grip.
            g.shape(1, T("^-4,0 ^4,0 ^4.6,24 ^-4,24 z"), 0.9)
            g.shape(-1, T(.rrect(-5.2, -3, 10.4, 5, 1.5)), 0.8)
            // Tape round the blade, with a seam or two.
            g.shape(-1, T("^12,99.6 ^38,109 ^36,121 ^9,111 z"), 0.7)
            g.detail(0.16) { g in
                for x in [18.0, 24.0, 30.0] { g.line(T(.poly([(x, 101.6 + (x - 12) * 0.36), (x - 2.4, 112.6 + (x - 12) * 0.36)])), 0.4) }
                for y in [5.0, 10.0, 15.0, 20.0] { g.line(T(.poly([(-3.6, y), (3.8, y + 1.2)])), 0.4) }
            }
        }
        let a: (DoodlePath) -> DoodlePath = { $0.rotated(-23, about: (0, 60)).moved(50, 0) }
        stick(&g, sep: 2, a)
        stick(&g, sep: 0) { a($0).mirrored(about: 50) }
        // The puck.
        g.shape(1, .ellipse(50, 112, 12.5, 5), 1.15)
        g.shape(1, "^37.5,112 ^37.5,119 44,123.6 50,124.6 56,123.6 ^62.5,119 ^62.5,112 56,116 50,117 44,116 z", 1.15)
        g.shade("^37.5,112 ^37.5,119 44,123.6 50,124.6 56,123.6 ^62.5,119 ^62.5,112 56,116 50,117 44,116 z")
        g.detail(0.16) { $0.gel("42,110.6 48,109 ^55,109.4", 0.7) }
        return g
    }

    static func iceSkate() -> DoodleGlyph {
        var g = DoodleGlyph("iceSkate", 0.16, 0.34, tilt: 10)
        // The boot: a tall heel, a padded toe.
        g.shape(2, "^10,70 8,44 12,8 ^48,4 52,24 58,36 74,46 96,50 110,60 ^114,74 ^10,74 z", 1.45)
        g.shape(1, "^10,74 ^114,74 110,60 96,50 ^78,47 ^76,60 ^26,60 ^16,50 ^9,50 z", 1)
        g.shape(-1, "^8,4 ^52,0 ^54,12 ^10,16 z", 1.1)
        // Laces.
        for i in 0..<4 {
            let t = Double(i)
            g.line(.poly([(48 + t * 7, 22 + t * 7), (62 + t * 9, 18 + t * 8)]), 1)
            g.line(.poly([(62 + t * 9, 18 + t * 8), (55 + t * 7, 29 + t * 7)]), 1)
        }
        g.detail(0.16) { g in
            g.gel("^16,24 ^15,44", 0.9)
            g.stitch("^20,66 ^104,66", dash: 2.4, gap: 2, w: 0.45)
        }
        // The steel holder and blade.
        g.shape(1, "^14,76 ^36,76 ^32,88 ^20,88 z", 1.05)
        g.shape(1, "^80,76 ^104,76 ^98,88 ^84,88 z", 1.05)
        g.shape(-1, "^4,90 ^112,88 118,84 ^122,86 116,94 ^104,97 ^12,97 z", 1.25)
        g.line("^38,88 ^82,88", 0.8)
        g.line("^12,93 ^108,92", 0.45)
        return g
    }

    static func hockeyHelmet() -> DoodleGlyph {
        var g = DoodleGlyph("hockeyHelmet", 0.12, 0.3, tilt: 16)
        // Shell, ear guard, and a wire cage over the face.
        g.shape(1, "^12,62 4,38 16,12 44,2 72,8 88,26 ^92,46 ^82,50 ^78,64 ^50,70 ^22,70 z", 1.45)
        g.shape(0, "^20,30 46,18 ^76,24 ^78,14 44,8 18,18 z", 0.85)
        g.accent(.ellipse(40, 44, 6, 8))
        g.shape(-1, "^10,48 ^26,46 ^30,72 ^16,72 z", 1.05)
        g.blot(.circle(20, 54, 1.4))
        g.blot(.circle(22, 66, 1.4))
        g.detail(0.16) { g in
            g.gel("^12,34 ^22,20", 1)
            g.accent(.rrect(38, 12, 10, 3, 1.4))
            g.accent(.rrect(54, 12, 10, 3, 1.4))
        }
        // The cage.
        g.line("^50,34 ^104,40 ^106,70 ^84,102 ^52,96 ^44,70", 1.1)
        for x in [62.0, 76.0, 90.0] { g.line(.poly([(x, 36 + (x - 62) * 0.1), (x + (x > 84 ? -4 : 0), 100 - (x - 62) * 0.1 - (x == 90 ? 6 : 0))]), 0.65) }
        for y in [48.0, 62.0, 76.0, 90.0] {
            let x1 = y < 72 ? 105.0 : 105 - (y - 70) * 0.72
            g.line(.poly([(48, y - 2), (x1, y)]), 0.65)
        }
        g.line("^52,96 40,104 ^26,72", 0.8)
        return g
    }

    static func pingPong() -> DoodleGlyph {
        var g = DoodleGlyph("pingPong", 0.1, 0.27, tilt: 40)
        g.shape(2, "^30,70 ^46,70 ^47,108 42,114 ^34,114 29,108 z", 1.25)
        g.detail(0.13) { g in
            g.line("^33,76 ^33,108", 0.42)
            g.line("^43,76 ^43,108", 0.42)
        }
        g.shape(0, "38,0 62,8 76,32 70,58 48,74 28,74 6,58 0,32 14,8 z", 1.5)
        g.line("^2,48 16,70 ^24,76", 0)
        g.detail(0.14) { g in
            g.speckle(14, 16, 62, 60, n: 22, r: 0.5, seed: 7)
            g.gel("10,26 16,14 ^26,8", 1)
        }
        g.shape(-1, .circle(84, 14, 11), 1.15)
        g.stitch("^68,24 ^60,32", dash: 2, gap: 2, w: 0.6)
        return g
    }

    static func bowling() -> DoodleGlyph {
        var g = DoodleGlyph("bowling", 0.14, 0.34, tilt: 8)
        g.shape(-1, "^12,118 ^36,118 42,92 38,72 28,54 30,34 34,20 28,4 20,0 12,4 6,20 10,34 12,54 2,72 -2,92 z", 1.3)
        g.tint(0, "^9.6,28 ^30.6,28 ^31.4,36 ^11,36 z")
        g.line("^9.6,28 ^30.6,28", 0.6)
        g.line("^11,36 ^31.4,36", 0.6)
        g.shape(-1, "^62,120 ^86,120 94,96 90,76 80,58 82,38 86,24 80,8 72,4 64,8 58,24 62,38 64,58 54,76 50,96 z", 1.4)
        g.tint(0, "^61.6,32 ^82.4,32 ^83,40 ^63,40 z")
        g.line("^61.6,32 ^82.4,32", 0.6)
        g.line("^63,40 ^83,40", 0.6)
        g.detail(0.16) { g in
            g.gel("^58,84 ^62,70", 0.9)
            g.hatch("^78,78 ^90,78 ^92,98 ^84,118 ^74,118 z", angle: 68, gap: 3, w: 0.42)
        }
        g.shape(1, .circle(48, 106, 26), 1.5)
        g.accent(.circle(42, 96, 3.2))
        g.accent(.circle(52, 94, 3.2))
        g.accent(.circle(48, 104, 3.4))
        g.gel("28,104 32,92 ^40,86", 1.1)
        return g
    }

    static func dartboard() -> DoodleGlyph {
        var g = DoodleGlyph("dartboard", 0.13, 0.32, tilt: 10)
        g.shape(1, .circle(50, 50, 48), 1.5)
        g.shape(-1, .circle(50, 50, 38), 0.8)
        typealias K = DoodleKit
        // Alternating wedges, twelve of them.
        for i in stride(from: 0, to: 12, by: 2) {
            let a0 = Double(i) * 30 - 15, a1 = a0 + 30
            g.tint(2, .poly([K.polar(50, 50, 7, a0), K.polar(50, 50, 38, a0), K.polar(50, 50, 38, a1), K.polar(50, 50, 7, a1)], closed: true))
        }
        for i in 0..<12 {
            let a = Double(i) * 30 - 15
            g.line(.poly([K.polar(50, 50, 7, a), K.polar(50, 50, 38, a)]), 0.5)
        }
        g.line(.circle(50, 50, 30), 0.75)
        g.line(.circle(50, 50, 18), 0.75)
        g.shape(0, .circle(50, 50, 7), 0.9)
        g.blot(.circle(50, 50, 2.6))
        // A dart thrown in, from the upper right.
        g.line("^58,42 ^84,16", 1.1)
        g.shape(0, "^84,16 ^98,-2 ^94,12 ^108,8 ^92,22 z", 1)
        return g
    }

    static func skateboard() -> DoodleGlyph {
        var g = DoodleGlyph("skateboard", 0.14, 0.36, tilt: 22)
        g.noTuck = true
        // Trucks, then wheels, then the deck with its kick at each end.
        g.shape(1, "^28,28 ^44,28 ^40,40 ^32,40 z", 1)
        g.shape(1, "^96,28 ^112,28 ^108,40 ^100,40 z", 1)
        for x in [24.0, 36.0, 104.0, 116.0] {
            g.shape(x == 24 || x == 104 ? 1 : 2, .circle(x, 44, 9.5), 1.2)
            g.line(.circle(x, 44, 3.4), 0.6)
        }
        g.shape(0, "^-6,6 2,16 14,24 ^126,24 138,16 ^146,6 ^150,10 140,24 128,34 ^12,34 0,24 -10,10 z", 1.45)
        g.detail(0.14) { g in
            g.line("^20,29 ^120,29", 0.5)
            g.stitch("^56,29 ^84,29", dash: 3, gap: 2, w: 0.75)
        }
        return g
    }

    static func rollerSkate() -> DoodleGlyph {
        var g = DoodleGlyph("rollerSkate", 0.14, 0.34, tilt: 10)
        // A retro boot with a big toe stop and four fat wheels.
        g.shape(-1, "^12,70 10,40 12,6 ^46,2 50,20 56,32 72,42 92,46 102,54 ^106,72 ^12,74 z", 1.45)
        g.shape(0, "^12,70 10,50 ^26,50 ^34,74 z", 0.9)
        g.shape(0, "^106,72 102,54 92,46 ^80,44 ^76,74 z", 0.9)
        g.shape(0, "^10,6 ^48,2 ^50,12 ^11,16 z", 1.05)
        for i in 0..<4 {
            let t = Double(i)
            g.line(.poly([(48 + t * 6.4, 22 + t * 5), (60 + t * 8, 18 + t * 6.4)]), 1)
            g.line(.poly([(60 + t * 8, 18 + t * 6.4), (54 + t * 6.4, 28 + t * 5)]), 1)
        }
        g.shape(1, .rrect(6, 74, 106, 6, 2), 1.15)
        g.shape(1, "^22,80 ^36,80 ^32,90 ^26,90 z", 0.9)
        g.shape(1, "^80,80 ^94,80 ^90,90 ^84,90 z", 0.9)
        g.shape(0, .rrect(108, 78, 12, 13, 3), 1.05)
        for (x, s) in [(16.0, 2), (40.0, 2), (74.0, 2), (98.0, 2)] {
            g.shape(s, .circle(x, 95, 11), 1.3)
            g.shape(-1, .circle(x, 95, 4.6), 0.75)
            g.blot(.circle(x, 95, 1.3))
        }
        return g
    }

    static func bikeHelmet() -> DoodleGlyph {
        var g = DoodleGlyph("bikeHelmet", 0.11, 0.28, tilt: 22)
        g.line("^40,54 48,74 58,80 ^76,56", 0.85)
        g.shape(-1, .rrect(50, 74, 8, 7, 1), 0.7)
        g.shape(2, "^2,54 ^6,36 20,14 48,4 80,8 102,26 ^112,44 ^92,50 ^72,60 ^28,60 z", 1.45)
        // Swept vents.
        for (p, s) in [("^18,38 30,20 ^48,12 40,26 ^26,42 z", 1), ("^36,44 48,26 ^68,14 60,30 ^46,46 z", 1), ("^56,48 68,30 ^88,20 80,36 ^66,50 z", 1)] as [(DoodlePath, Int)] {
            g.accent(p)
            _ = s
        }
        g.tint(0, "^2,54 ^28,60 ^72,60 ^92,50 ^112,44 ^106,36 ^88,42 ^70,52 ^30,52 ^4,46 z")
        g.line("^4,46 30,52 70,52 88,42 ^106,36", 0.7)
        g.detail(0.14) { $0.gel("^12,30 ^22,18", 1) }
        return g
    }

    static func bicycle() -> DoodleGlyph {
        var g = DoodleGlyph("bicycle", 0.3, 0.46, tilt: 5)
        g.must = true
        let back = (30.0, 66.0), front = (120.0, 66.0), R = 29.0
        // Wheels: tyre, rim, spokes.
        for c in [back, front] {
            g.band(1, outer: .circle(c.0, c.1, R), inner: .circle(c.0, c.1, R - 4.6), 1.4, innerW: 0.7)
            g.detail(0.2) { g in
                for i in 0..<12 {
                    let a = Double(i) * 30 + 8
                    g.line(.poly([DoodleKit.polar(c.0, c.1, 3, a), DoodleKit.polar(c.0, c.1, R - 5, a)]), 0.4)
                }
            }
        }
        let bb = (66.0, 68.0), seat = (54.0, 26.0), head = (104.0, 24.0), headLow = (107.0, 36.0)
        func tube(_ g: inout DoodleGlyph, _ a: (Double, Double), _ b: (Double, Double), _ w: Double, _ s: Int = 0) {
            g.shape(s, DoodlePath.taper([a, b], w, w), 1)
        }
        // Rear triangle, thin; the main frame, thick.
        tube(&g, back, seat, 3)
        tube(&g, back, bb, 3)
        tube(&g, seat, head, 5)
        tube(&g, bb, headLow, 5.4)
        tube(&g, (52, 16), bb, 5.4)
        // Fork, stem, bars.
        g.shape(0, DoodlePath.taper([(102, 16), (108, 40), (118, 58), front], 5, 3), 1.05)
        g.line("^100,12 104,8 ^118,8", 1.35)
        g.line("118,8 130,8 134,16 128,24 ^122,22", 1.35)
        g.shape(2, DoodlePath.taper([(128, 16), (122, 23)], 4.6, 4.6), 0.75)
        // Saddle.
        g.line("^50,16 ^52,8", 1.3)
        g.shape(1, "^34,4 50,1 ^70,4 ^70,8 54,12 42,11 z", 1.2)
        // Hubs, chainring, crank, pedal.
        g.blot(.circle(back.0, back.1, 3))
        g.blot(.circle(front.0, front.1, 3))
        g.shape(2, .circle(bb.0, bb.1, 9.5), 1.1)
        g.line(.poly([back, bb]), 0)
        g.line(.poly([bb, (58, 84)]), 1.25)
        g.shape(1, .rrect(50, 83, 16, 4.6, 1.6), 0.85)
        g.line(.poly([(33, 73), (66, 77)]), 0.65)
        g.detail(0.2) { g in
            g.blot(.circle(bb.0, bb.1, 1.6))
            // A little bell, a basket hint on the front.
            g.blot(.circle(112, 5.6, 1.8))
        }
        return g
    }

    static func dumbbell() -> DoodleGlyph {
        var g = DoodleGlyph("dumbbell", 0.1, 0.28, tilt: 34)
        g.shape(-1, .rrect(26, 22, 72, 10, 2), 1.15)
        g.detail(0.14) { g in
            var x = 44.0
            while x < 80 {
                g.line("^\(x),23 ^\(x + 3),31", 0.4)
                g.line("^\(x + 3),23 ^\(x),31", 0.4)
                x += 5
            }
        }
        for (p, s) in [(DoodlePath.rrect(16, 8, 12, 38, 3), 1), (.rrect(4, 14, 12, 26, 3), 0), (.rrect(96, 8, 12, 38, 3), 1), (.rrect(108, 14, 12, 26, 3), 0)] {
            g.shape(s, p, 1.25)
        }
        g.detail(0.14) { g in
            g.gel("^20,12 ^20,26", 0.8)
            g.gel("^100,12 ^100,26", 0.8)
        }
        return g
    }

    static func kettlebell() -> DoodleGlyph {
        var g = DoodleGlyph("kettlebell", 0.09, 0.24, tilt: 18)
        g.band(1, outer: "14,38 8,18 18,4 34,0 50,4 60,18 54,38 z", inner: "24,34 18,18 24,10 34,8 44,10 50,18 44,34 z", 1.3, innerW: 0.9)
        g.shape(0, "34,26 54,32 66,50 66,70 54,88 34,94 14,88 2,70 2,50 14,32 z", 1.5)
        g.shape(-1, .circle(34, 60, 13), 0.95)
        g.line("^29,53 ^29,67 ^39,67", 1)
        g.detail(0.13) { g in
            g.gel("10,46 16,38 ^24,34", 1.1)
            g.hatch("^50,40 ^64,54 ^62,74 ^48,86 z", angle: 62, gap: 3, w: 0.42)
        }
        return g
    }

    static func jumpRope() -> DoodleGlyph {
        var g = DoodleGlyph("jumpRope", 0.11, 0.28, tilt: 24)
        g.line("28,26 14,44 6,70 16,94 44,106 74,100 92,78 90,52 ^76,26", 1.1)
        g.line("28,26 40,50 60,62 ^76,26", 0)
        for (x, y, r, s) in [(28.0, 26.0, -22.0, 0), (76.0, 26.0, 22.0, 2)] {
            func T(_ p: DoodlePath) -> DoodlePath { p.rotated(r, about: (0, 0)).moved(x, y) }
            g.shape(s, T(.rrect(-7.5, -32, 15, 32, 5)), 1.3)
            g.shape(1, T(.rrect(-9, -6, 18, 7, 2)), 0.95)
            g.detail(0.13) { g in
                g.line(T("^-7.5,-22 ^7.5,-22"), 0.45)
                g.line(T("^-7.5,-16 ^7.5,-16"), 0.45)
            }
        }
        return g
    }

    static func stopwatch() -> DoodleGlyph {
        var g = DoodleGlyph("stopwatch", 0.1, 0.27, tilt: 18)
        g.noFlip = true
        g.line(.circle(40, 5, 5), 0.95)
        g.shape(1, .rrect(33, 7, 14, 11, 2), 1.15)
        g.shape(1, DoodlePath.rrect(58, 8, 11, 8, 2).rotated(38, about: (63, 12)), 1)
        g.shape(0, .circle(40, 56, 40), 1.55)
        g.shape(-1, .circle(40, 56, 32), 1.05)
        g.detail(0.13) { g in
            for i in 0..<36 {
                let a = Double(i) * 10
                let long = i % 9 == 0
                let mid = i % 3 == 0
                g.line(.poly([DoodleKit.polar(40, 56, long ? 25 : (mid ? 27.6 : 29), a), DoodleKit.polar(40, 56, 31, a)]), long ? 0.8 : 0.42)
            }
            g.line(.circle(40, 41, 5.6), 0.5)
            g.line(.poly([(40, 41), (43, 37)]), 0.5)
        }
        g.line(.poly([(40, 56), (60, 42)]), 1.15)
        g.line(.poly([(40, 56), (31, 66)]), 0.7)
        g.blot(.circle(40, 56, 2.4))
        return g
    }

    static func squeezeBottle() -> DoodleGlyph {
        var g = DoodleGlyph("squeezeBottle", 0.09, 0.24, tilt: 24)
        g.shape(1, "^18,0 ^26,0 ^28,12 ^16,12 z", 1)
        g.shape(1, "^10,12 ^34,12 ^38,26 ^6,26 z", 1.2)
        g.shape(-1, "^6,26 ^38,26 44,36 44,52 38,58 42,66 44,100 38,108 ^6,108 0,100 2,66 6,58 0,52 0,36 z", 1.45)
        g.tint(1, "^1.6,66 ^42.4,66 44,100 38,108 ^6,108 0,100 z")
        g.line("^2,66 ^42,66", 0.6)
        g.shape(0, .rrect(10, 72, 24, 26, 2), 0.9)
        g.shape(-1, DoodleFillers.starPath(22, 85, 8), 0.7)
        g.detail(0.13) { g in
            for y in [32.0, 37.0, 42.0, 47.0] { g.line("^3,\(y) ^8,\(y)", 0.42) }
            g.gel("^34,32 ^35,48", 0.9)
        }
        return g
    }

    static func swimGoggles() -> DoodleGlyph {
        var g = DoodleGlyph("swimGoggles", 0.1, 0.24, tilt: 22)
        g.line("^4,24 -10,6 8,-8 56,-14 100,-8 118,6 ^104,24", 1.15)
        g.line("^4,30 -14,10 6,-3 ^28,-6", 0.75)
        g.shape(2, "4,28 10,14 28,10 44,16 50,28 44,42 26,48 10,42 z", 1.4)
        g.shape(2, "104,28 98,14 80,10 64,16 58,28 64,42 82,48 98,42 z", 1.4)
        g.shape(1, "11,28 15,18 28,15.6 40,20 44,28 40,38 26,42 15,38 z", 0.9)
        g.shape(1, "97,28 93,18 80,15.6 68,20 64,28 68,38 82,42 93,38 z", 0.9)
        g.line("^50,24 54,21 ^58,24", 1.25)
        g.gel("17,26 21,21 ^28,19", 0.95)
        g.gel("70,26 74,21 ^81,19", 0.95)
        return g
    }

    static func cap() -> DoodleGlyph {
        var g = DoodleGlyph("cap", 0.1, 0.27, tilt: 20)
        // Crown in panels, a curved brim, a button.
        g.shape(1, "^8,54 8,32 22,12 46,6 66,12 76,28 ^82,50 ^46,50 z", 1.45)
        g.shape(-1, .circle(45, 5, 3.2), 0.8)
        g.tint(2, "^46,6 66,12 76,28 ^82,50 ^62,50 ^54,26 z")
        g.line("^46,6 54,26 ^62,50", 0.7)
        g.line("^46,6 30,24 ^26,52", 0.7)
        g.shape(0, "^46,50 ^82,48 112,52 124,60 120,66 ^88,62 ^50,60 z", 1.35)
        g.detail(0.13) { g in
            g.stitch("^56,56 ^88,57 ^114,60", dash: 2, gap: 1.8, w: 0.45)
            g.blot(.circle(18, 28, 0.9))
            g.blot(.circle(38, 18, 0.9))
            g.gel("^15,30 ^24,18", 0.9)
        }
        g.line("^8,54 26,52 ^46,50", 0.9)
        return g
    }

    static func jersey() -> DoodleGlyph {
        var g = DoodleGlyph("jersey", 0.14, 0.34, tilt: 16)
        g.noFlip = true
        g.shape(0, "^28,6 40,14 ^60,14 ^72,6 ^100,22 ^90,50 ^76,44 ^78,112 ^22,112 ^24,44 ^10,50 ^0,22 z", 1.5)
        g.shape(-1, "^40,14 50,22 ^60,14 ^72,6 ^66,4 54,12 ^46,12 ^34,4 ^28,6 z", 0.95)
        // Sleeve bands.
        g.tint(1, "^6,34 ^20,40 ^17,47 ^3,41 z")
        g.tint(1, "^94,34 ^80,40 ^83,47 ^97,41 z")
        g.line("^6,34 ^20,40", 0.6)
        g.line("^3,41 ^17,47", 0.6)
        g.line("^94,34 ^80,40", 0.6)
        g.line("^97,41 ^83,47", 0.6)
        // A hand-painted 7.
        g.shape(-1, "^34,40 ^68,40 ^68,50 ^52,92 ^40,92 ^54,52 ^34,52 z", 1.1)
        g.detail(0.16) { g in
            g.stitch("^25,104 ^75,104", dash: 2.2, gap: 1.8, w: 0.45)
            g.hatch("^64,60 ^76,50 ^77,102 ^62,102 z", angle: 66, gap: 3.2, w: 0.42)
        }
        return g
    }

    static func scoreboard() -> DoodleGlyph {
        var g = DoodleGlyph("scoreboard", 0.12, 0.3, tilt: 10)
        g.noFlip = true
        g.line("^24,66 ^24,84", 1.4)
        g.line("^86,66 ^86,84", 1.4)
        g.line("^12,84 ^36,84", 0.9)
        g.line("^74,84 ^98,84", 0.9)
        g.shape(1, .rrect(2, 6, 106, 62, 4), 1.55)
        g.shape(-1, .rrect(10, 24, 36, 36, 2), 1)
        g.shape(-1, .rrect(64, 24, 36, 36, 2), 1)
        g.line("^10,42 ^46,42", 0.5)
        g.line("^64,42 ^100,42", 0.5)
        // 3 to 2, drawn by hand.
        g.line("^20,30 ^36,30 ^28,41 34,46 33,54 27,56 ^20,52", 1.25)
        g.line("^74,34 80,29 88,31 90,37 ^74,55 ^91,55", 1.25)
        g.blot(.circle(55, 38, 2))
        g.blot(.circle(55, 48, 2))
        g.line("^14,15 ^44,15", 0.8)
        g.line("^66,15 ^96,15", 0.8)
        g.shape(0, .circle(55, 15, 4), 0.8)
        return g
    }

    static func goal() -> DoodleGlyph {
        var g = DoodleGlyph("goal", 0.14, 0.36, tilt: 5)
        // The back of the net.
        g.line("^22,20 ^124,20 ^112,76 ^10,76 z", 0.5)
        var x = 34.0
        while x < 124 {
            g.line(.poly([(x, 20), (x - 12, 76)]), 0.42)
            x += 12
        }
        var y = 32.0
        while y < 76 {
            let t = (y - 20) / 56
            g.line(.poly([(22 - t * 12, y), (124 - t * 12, y)]), 0.42)
            y += 12
        }
        // Posts and bar.
        g.shape(-1, "^0,2 ^108,2 ^108,8 ^6,8 ^6,88 ^0,88 z", 1.25)
        g.shape(-1, "^102,8 ^108,8 ^108,88 ^102,88 z", 1.25)
        g.line("^0,2 ^22,20", 0.8)
        g.line("^108,2 ^124,20", 0.8)
        g.line("^108,88 ^112,76", 0.7)
        // The ball just over the line.
        g.shape(-1, .circle(46, 76, 10.5), 1.15)
        g.accent(DoodleKit.gon(46, 76, 3.6, sides: 5))
        g.line("^-8,89 ^118,89", 0.8)
        return g
    }

    static func trainingCone() -> DoodleGlyph {
        var g = DoodleGlyph("trainingCone", 0.06, 0.16, tilt: 20)
        g.shape(0, "^26,0 ^34,0 ^52,60 ^8,60 z", 1.35)
        g.tint(-1, "^19.6,22 ^40.4,22 ^44.6,36 ^15.4,36 z")
        g.line("^19.6,22 ^40.4,22", 0.7)
        g.line("^15.4,36 ^44.6,36", 0.7)
        g.shape(1, "^0,58 ^60,58 ^64,68 ^-4,68 z", 1.2)
        return g
    }

    static func pennant() -> DoodleGlyph {
        var g = DoodleGlyph("pennant", 0.11, 0.3, tilt: 20)
        g.noFlip = true
        g.line("^4,-4 ^4,70", 1.35)
        g.shape(0, "^4,2 ^120,26 ^4,48 z", 1.45)
        g.tint(-1, "^4,2 ^20,5.3 ^20,44.8 ^4,48 z")
        g.line("^20,5.3 ^20,44.8", 0.75)
        g.shape(-1, DoodleFillers.starPath(52, 25, 13), 1)
        g.detail(0.14) { g in
            g.line("^76,21 ^94,24", 0.45)
            g.line("^76,31 ^94,28", 0.45)
        }
        return g
    }

    static func megaphone() -> DoodleGlyph {
        var g = DoodleGlyph("megaphone", 0.11, 0.28, tilt: 18)
        // A hand-loop, the body flaring, a bright rim.
        g.line("44,48 40,72 56,76 ^60,50", 1.1)
        g.shape(0, "^6,24 ^22,20 ^88,2 ^88,58 ^22,40 ^6,38 z", 1.5)
        g.shape(-1, "^22,20 ^38,16 ^38,44 ^22,40 z", 1)
        g.shape(1, .rrect(-4, 22, 12, 18, 3), 1.15)
        g.shape(2, .ellipse(88, 30, 9, 29), 1.45)
        g.accent(.ellipse(88, 30, 5, 21))
        g.detail(0.14) { g in
            g.gel("^44,16 ^76,8", 1)
            g.line("^48,50 ^80,54", 0.45)
        }
        return g
    }

    static func podium() -> DoodleGlyph {
        var g = DoodleGlyph("podium", 0.13, 0.32, tilt: 6)
        g.noFlip = true
        g.shape(1, .rrect(-2, 46, 40, 44, 1), 1.35)
        g.shape(2, .rrect(38, 22, 40, 68, 1), 1.45)
        g.shape(0, .rrect(78, 58, 40, 32, 1), 1.35)
        // 2, 1, 3, drawn.
        g.line("^10,60 15,55 22,57 23,62 ^10,76 ^25,76", 1.1)
        g.line("^52,38 ^58,32 ^58,58", 1.25)
        g.line("^52,58 ^65,58", 1.1)
        g.line("^90,66 ^106,66 ^98,74 102,76 103,82 98,86 ^90,83", 1)
        g.blot(DoodleFillers.starPath(58, 8, 11))
        g.detail(0.16) { g in
            g.line("^-10,92 ^126,92", 0.8)
            g.hatch("^66,26 ^77,26 ^77,88 ^66,88 z", angle: 70, gap: 3, w: 0.42)
        }
        return g
    }

    static func archery() -> DoodleGlyph {
        var g = DoodleGlyph("archery", 0.12, 0.34, tilt: 8)
        // A tripod, the straw target, and an arrow home in the gold.
        g.line("^44,70 ^16,126", 1.25)
        g.line("^52,70 ^84,126", 1.25)
        g.line("^48,70 ^48,116", 1)
        g.shape(-1, .circle(48, 46, 44), 1.5)
        g.shape(1, .circle(48, 46, 35), 0.9)
        g.shape(0, .circle(48, 46, 26), 0.9)
        g.shape(-1, .circle(48, 46, 17), 0.9)
        g.shape(2, .circle(48, 46, 9), 0.9)
        g.blot(.circle(48, 46, 1.6))
        g.line("^48,46 ^90,10", 1.2)
        g.shape(0, "^84,15 ^92,0 ^94,10 ^106,8 ^96,18 z", 1)
        g.line("^88,12 ^97,10", 0.5)
        return g
    }

    static func cricket() -> DoodleGlyph {
        var g = DoodleGlyph("cricket", 0.14, 0.34, tilt: 12)
        g.noTuck = true
        // Three stumps and bails behind, a flat bat across them, a stitched ball.
        for x in [24.0, 40.0, 56.0] {
            g.shape(2, .rrect(x, 8, 7, 92, 2), 1.15)
            g.blot("^\(x + 1.5),100 ^\(x + 5.5),100 ^\(x + 3.5),106 z")
        }
        g.shape(-1, .rrect(26, 4, 16, 4.6, 2), 0.85)
        g.shape(-1, .rrect(42, 4, 16, 4.6, 2), 0.85)
        func T(_ p: DoodlePath) -> DoodlePath { p.rotated(32, about: (50, 60)).moved(6, -4) }
        g.shape(1, T(.rrect(45, -8, 10, 38, 2.5)), 1.2)
        g.shape(-1, T("^36,30 ^64,30 ^66,118 60,124 ^40,124 34,118 z"), 1.45)
        g.tint(0, T("^35,90 ^65.4,90 ^65.8,106 ^34.2,106 z"))
        g.line(T("^35,90 ^65.4,90"), 0.6)
        g.line(T("^34.2,106 ^65.8,106"), 0.6)
        g.detail(0.16) { g in
            for y in [-4.0, 2.0, 8.0, 14.0, 20.0] { g.line(T(.poly([(45, y), (55, y + 2)])), 0.42) }
            g.line(T("^50,34 ^50,86"), 0.5)
        }
        g.shape(0, .circle(14, 100, 12.5), 1.25)
        g.stitch("^6,92 13,100 ^22,108", dash: 2, gap: 1.3, w: 0.65)
        return g
    }

    static func eightBall() -> DoodleGlyph {
        var g = DoodleGlyph("eightBall", 0.06, 0.15, tilt: 30)
        g.noFlip = true
        g.shape(1, .circle(30, 30, 29), 1.35)
        g.shape(-1, .ellipse(28, 26, 13, 13), 0.8)
        g.line(.ellipse(28, 21.4, 3.8, 4), 1)
        g.line(.ellipse(28, 30, 4.6, 4.6), 1)
        g.gel("8,22 13,12 ^21,6", 1)
        return g
    }

    static func frisbee() -> DoodleGlyph {
        var g = DoodleGlyph("frisbee", 0.08, 0.2, tilt: 26)
        g.shape(0, "^4,26 18,12 50,6 82,12 ^96,26 98,32 84,42 50,46 16,42 2,32 z", 1.4)
        g.line(.ellipse(50, 24, 33, 11), 0.7)
        g.line(.ellipse(50, 24, 22, 7), 0.6)
        g.line("^2,30 18,38 50,41 82,38 ^98,30", 0.7)
        g.detail(0.12) { $0.gel("24,18 36,14 ^50,13", 0.9) }
        g.line("^-20,10 ^-6,14", 0.75)
        g.line("^-22,22 ^-8,24", 0.75)
        return g
    }

    static func gymBag() -> DoodleGlyph {
        var g = DoodleGlyph("gymBag", 0.14, 0.34, tilt: 10)
        // Two handles over a soft barrel, a zip, a side pocket and a tag.
        g.line("^34,26 30,6 44,0 ^52,24", 1.1)
        g.line("^76,24 84,0 98,6 ^94,26", 1.1)
        g.shape(1, "^10,28 22,20 ^106,20 118,28 124,48 124,76 116,86 ^12,86 4,76 4,48 z", 1.5)
        g.shape(-1, .ellipse(16, 54, 11, 25), 1.15)
        g.shape(-1, .ellipse(112, 54, 11, 25), 1.15)
        g.line(.ellipse(16, 54, 5, 14), 0.6)
        g.line(.ellipse(112, 54, 5, 14), 0.6)
        g.stitch("^24,30 ^104,30", dash: 2, gap: 1.2, w: 0.8)
        g.shape(0, .rrect(38, 44, 52, 32, 3), 1.15)
        g.line("^38,52 ^90,52", 0.7)
        g.shape(-1, DoodleFillers.starPath(64, 64, 8.4), 0.7)
        g.line("^104,30 110,38 ^108,46", 0.7)
        g.shape(2, .rrect(103, 44, 9, 12, 1.5), 0.7)
        g.detail(0.15) { g in
            g.gel("^28,24 ^60,23", 0.9)
            g.hatch("^96,60 ^102,44 ^104,84 ^92,84 z", angle: 70, gap: 3, w: 0.42)
        }
        return g
    }

    static func ticket() -> DoodleGlyph {
        var g = DoodleGlyph("ticket", 0.08, 0.2, tilt: 26)
        g.noFlip = true
        g.shape(2, "^0,6 ^110,6 ^110,20 104,26 ^110,32 ^110,48 ^0,48 ^0,32 6,26 ^0,20 z", 1.3)
        g.stitch("^82,8 ^82,46", dash: 2.4, gap: 2, w: 0.7)
        g.shape(0, DoodleFillers.starPath(96, 27, 8), 0.8)
        g.line("^14,18 ^68,18", 0.9)
        g.line("^14,27 ^56,27", 0.55)
        g.line("^14,34 ^62,34", 0.55)
        return g
    }

    static func gridHelmet() -> DoodleGlyph {
        var g = DoodleGlyph("gridHelmet", 0.14, 0.34, tilt: 14)
        // Facemask bars first, the shell over them.
        g.line("^68,44 104,44 112,58 106,76 ^76,78", 1.25)
        g.line("^68,60 ^110,60", 1.1)
        g.line("^92,44 ^90,78", 1)
        g.shape(1, "^2,56 2,34 16,12 44,2 70,8 86,26 ^88,42 ^70,42 ^68,58 ^76,72 ^58,84 ^22,80 ^10,70 z", 1.55)
        // A centre stripe and a pale ear hole.
        g.tint(2, "^16,12 44,2 ^52,3 ^24,16 ^8,38 ^4,32 z")
        g.line("^52,3 24,16 ^8,38", 0.7)
        g.shape(-1, .ellipse(36, 50, 8, 9), 1)
        g.blot(.ellipse(36, 50, 2.6, 3))
        g.shape(0, "^60,62 ^76,62 ^84,70 ^76,78 ^58,84 z", 1.1)
        g.detail(0.16) { g in
            g.gel("^58,14 ^76,28", 1.1)
            g.line("^14,62 28,70 ^46,70", 0.5)
            g.hatch("^48,58 ^62,58 ^60,78 ^44,78 z", angle: 66, gap: 2.8, w: 0.42)
        }
        return g
    }

    static func hoop() -> DoodleGlyph {
        var g = DoodleGlyph("hoop", 0.2, 0.42, tilt: 8)
        g.must = true
        g.noTuck = true
        g.noFlip = true
        // A pole and arm, a backboard with its target square, a rim and a torn-free net.
        g.shape(1, "^80,70 ^88,70 ^88,150 ^80,150 z", 1.2)
        g.shape(-1, .rrect(14, 0, 96, 66, 3), 1.55)
        g.line(.rrect(20, 6, 84, 54, 1.5), 0.55)
        g.line("^46,26 ^78,26 ^78,50 ^46,50 z", 1)
        g.shape(1, "^52,62 ^72,62 ^72,70 ^52,70 z", 1)
        // The net, hanging from the rim.
        let topL = 36.0, topR = 88.0, botL = 46.0, botR = 78.0, y0 = 76.0, y1 = 112.0
        for i in 0...5 {
            let t = Double(i) / 5
            let a = (topL + (topR - topL) * t, y0)
            let b = (botL + (botR - botL) * (1 - t), y1)
            g.line(.poly([a, b]), 0.55)
            let c = (botL + (botR - botL) * t, y1)
            g.line(.poly([a, c]), 0.55)
        }
        g.line("^\(botL),\(y1) ^\(botR),\(y1)", 0.6)
        g.shape(0, .ellipse(62, 74, 29, 7.4), 1.35)
        g.shape(-1, .ellipse(62, 74, 22, 3.8), 0.8)
        g.line("^52,66 ^46,73", 0.8)
        g.line("^72,66 ^78,73", 0.8)
        g.detail(0.2) { g in
            g.hatch("^92,8 ^102,8 ^102,58 ^92,58 z", angle: 70, gap: 3, w: 0.42)
            g.line("^60,150 ^108,150", 1)
        }
        return g
    }

    static func wristband() -> DoodleGlyph {
        var g = DoodleGlyph("wristband", 0.06, 0.15, tilt: 30)
        g.band(0, outer: .ellipse(34, 26, 33, 24), inner: .ellipse(34, 26, 20, 13), 1.35, innerW: 1)
        g.line(.ellipse(34, 26, 27, 19), 0.5)
        g.detail(0.1) { g in
            for i in 0..<16 {
                let a = Double(i) * 22.5
                g.line(.poly([DoodleKit.polar(34, 26, 22, a), DoodleKit.polar(34, 26, 31, a)]), 0.4)
            }
        }
        return g
    }

    // The marks in the gaps.

    static func playXO() -> DoodleGlyph {
        var g = DoodleGlyph("playXO", 0.05, 0.12, tilt: 20)
        g.line("^0,0 ^14,14", 1.1)
        g.line("^14,0 ^0,14", 1.1)
        g.line(.circle(58, 40, 8), 1)
        g.line("^16,18 34,24 ^46,34", 0.75)
        g.line("^46,34 ^38,34", 0.75)
        g.line("^46,34 ^44,26", 0.75)
        return g
    }

    static func tinyBall() -> DoodleGlyph {
        var g = DoodleGlyph("tinyBall", 0.022, 0.05, tilt: 60)
        g.shape(2, .circle(16, 16, 16), 0.85)
        g.line("^4,6 11,16 ^6,27", 0.6)
        return g
    }

    static func tinyPuck() -> DoodleGlyph {
        var g = DoodleGlyph("tinyPuck", 0.02, 0.045, tilt: 30)
        g.shape(1, "^0,6 8,0 24,0 ^32,6 ^32,13 24,19 8,19 ^0,13 z", 0.8)
        g.line("^0,6 8,11 24,11 ^32,6", 0.5)
        return g
    }

    static func tinyStar() -> DoodleGlyph {
        var g = DoodleGlyph("tinyStar", 0.02, 0.05, tilt: 40)
        g.shape(0, DoodleFillers.starPath(0, 0, 20), 0.8)
        return g
    }

    static func motionLines() -> DoodleGlyph {
        var g = DoodleGlyph("motionLines", 0.03, 0.075, tilt: 60)
        g.line("^0,0 ^30,0", 0.85)
        g.line("^8,9 ^40,9", 0.85)
        g.line("^2,18 ^24,18", 0.85)
        return g
    }

    static func chevronUp() -> DoodleGlyph {
        var g = DoodleGlyph("chevronUp", 0.02, 0.05, tilt: 30)
        g.line("^0,14 ^12,2 ^24,14", 1)
        g.line("^0,26 ^12,14 ^24,26", 1)
        return g
    }

    static func tinyShuttle() -> DoodleGlyph {
        var g = DoodleGlyph("tinyShuttle", 0.025, 0.055, tilt: 70)
        g.shape(-1, "^8,18 ^0,0 ^22,0 ^14,18 z", 0.75)
        g.shape(0, .circle(11, 22, 5), 0.75)
        return g
    }

    static func tinyPlus() -> DoodleGlyph {
        var g = DoodleGlyph("tinyPlus", 0.018, 0.034, tilt: 30)
        g.line("^10,0 ^10,20", 1)
        g.line("^0,10 ^20,10", 1)
        return g
    }
}
