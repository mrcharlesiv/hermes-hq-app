// The pictures. Design space: x 0...1000, y 0...2168, y down.

import CoreGraphics
import Foundation

/// The inks of a massif, lightest last, and how light picks among them.
nonisolated enum PosterForeground {
    /// A dark foreground rock, drawn the way a woodcut draws it: a plain dark mass under a jagged crest, ledges of stratified rock
    /// catching a little light just below the crest and thinning out into dark further down, and a rim only on the crests that face the sun.
    static func ledge(_ c: PosterCanvas, line: [PosterP], foot: Double, deep: PosterInk, ledge: PosterInk, rim: PosterInk, ledges: Int = 90, reach: Double = 170, rng: inout SplitMix64) {
        let skyline = Poster.cut(line, amp: 0.05, minLen: 14, rng: &rng)
        let mask = PosterPlate(c) { g in
            var pts = skyline
            pts.append(PosterP(skyline.last!.x, foot + 40))
            pts.append(PosterP(skyline.first!.x, foot + 40))
            Poster.fillPoly(g, pts)
        }
        c.flat(deep, plate: mask)
        func crest(_ x: Double) -> (y: Double, slope: Double) {
            for i in 0..<(skyline.count - 1) where x >= skyline[i].x && x <= skyline[i + 1].x {
                let dx = max(0.001, skyline[i + 1].x - skyline[i].x)
                let sl = (skyline[i + 1].y - skyline[i].y) / dx
                return (skyline[i].y + sl * (x - skyline[i].x), sl)
            }
            return (x < skyline[0].x ? skyline[0].y : skyline.last!.y, 0)
        }
        // Stratified ledges: each a thin wedge with a broken lower edge, following the slope of the crest above it, more or less.
        var near: [[PosterP]] = [], far: [[PosterP]] = []
        let minX = skyline.first!.x, maxX = skyline.last!.x
        for _ in 0..<ledges {
            let x = rng.next(minX, maxX)
            let (cy, _) = crest(x)
            let depth = pow(rng.next(), 1.7) * reach + 6
            let (_, sl) = crest(x + 30)
            let slope = sl * 0.6 + rng.next(-0.14, 0.14)
            let len = rng.next(26, 120) * (1 - 0.4 * depth / reach)
            let th = rng.next(2.5, 9) * (1 - 0.5 * depth / reach)
            var top: [PosterP] = [], bot: [PosterP] = []
            let n = max(3, Int(len / 12))
            for i in 0...n {
                let u = Double(i) / Double(n)
                let px = x + len * u
                let py = cy + depth + slope * len * u + rng.next(-0.6, 0.6)
                let s = pow(sin(.pi * pow(u, 0.7)), 0.8)
                top.append(PosterP(px, py))
                bot.append(PosterP(px, py + th * s * rng.next(0.45, 1.2)))
            }
            if depth < reach * 0.42 { near.append(top + bot.reversed()) } else { far.append(top + bot.reversed()) }
        }
        let farP = PosterPlate(c) { g in for p in far { Poster.fillPoly(g, p) } }
        let nearP = PosterPlate(c) { g in for p in near { Poster.fillPoly(g, p) } }
        c.flat(ledge, plate: farP, opacity: 0.4)
        c.flat(ledge, plate: nearP, opacity: 0.85)
        // The rim: a few tapered pieces along the crest, never a constant wire.
        let rimP = PosterPlate(c) { g in
            var x = skyline.first!.x + rng.next(10, 60)
            let end = skyline.last!.x
            while x < end {
                let span = rng.next(46, 210)
                let thick = rng.next(1.0, 2.6)
                var top: [PosterP] = [], bot: [PosterP] = []
                var q = 0.0
                while q <= 1.0001 {
                    let px = x + span * q
                    let cy = crest(px).y
                    let v = q < 0.35 ? q / 0.35 * 0.5 : 0.5 + (q - 0.35) / 0.65 * 0.5
                    top.append(PosterP(px, cy - 0.3))
                    bot.append(PosterP(px, cy + thick * pow(sin(.pi * v), 0.9)))
                    q += 0.1
                }
                Poster.fillPoly(g, top + bot.reversed())
                x += span + rng.next(30, 170)
            }
        }
        c.flat(rim, plate: rimP, opacity: 0.6)
    }
}

nonisolated enum PosterSky {
}
