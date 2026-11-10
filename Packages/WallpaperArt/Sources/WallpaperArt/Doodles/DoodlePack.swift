// Packing: drawings fitted into each other's outlines, largest first, so they interlock with almost no gaps.
//
// A grid holds, for every cell, the distance to the nearest ink, and a second one how big a filled shape covers the cell.
// A drawing is a list of sample points on its own silhouette, so a candidate position, lean and size is tested by reading
// the grids at those points. A candidate may tuck part of itself under a clearly bigger drawing. The picture is built in
// stages (heroes, then mid-size drawings everywhere, then small ones, then filler marks in loose clusters), so no stretch
// of it is only filler, and everything is painted smallest first, so the bigger drawing's fill hides what tucked under it.
//
// All of this is in picture units, so a picker tile is the same layout as a full phone screen.

import CoreGraphics
import Foundation

nonisolated struct DoodleItem: Sendable {
    var glyph: Int
    var x, y: Double
    var rot: Double
    var size: Double
    var flip: Bool
    var seed: UInt64
    /// Its colours stand forward (only the Dark pictures use this).
    var lift = false
}

nonisolated enum DoodlePack {
    /// Keep the status bar and the home indicator clear of anything a drawing is recognised by.
    static let topBand = 0.127, bottomBand = 0.076

    /// `wu`, `hu`: the picture in units (a phone: 1 × 2.17).
    static func layout(_ lib: [DoodleGlyph], wu: Double, hu: Double, seed: UInt64) -> [DoodleItem] {
        let cellsPerUnit = 170.0
        let pad = 0.16
        let gw = Int((wu + 2 * pad) * cellsPerUnit), gh = Int((hu + 2 * pad) * cellsPerUnit)
        let cap: UInt16 = 90 // Three per cell: 30 cells.
        var dStore = [UInt16](repeating: cap, count: gw * gh)
        var solidStore = [Float](repeating: 0, count: gw * gh)
        var skipStore = [Bool](repeating: false, count: gw * gh)
        var rng = SplitMix64(seed: seed)
        var items: [DoodleItem] = []
        var used = [Int](repeating: 0, count: lib.count)
        var largest = [Double](repeating: 0, count: lib.count)
        let margin = 2 // Two thirds of a cell of air around a drawing, in chamfer units.
        // How thickly filler gathers: slow noise, so it clusters instead of dusting everything evenly.
        let densityNoise = GradientNoise(seed: seed ^ 0x51D)
        let densityW = 40, densityH = 80
        var density = [Float](repeating: 0, count: densityW * densityH)
        for y in 0..<densityH {
            for x in 0..<densityW {
                let u = Double(x) / Double(densityW - 1) * wu, v = Double(y) / Double(densityH - 1) * hu
                let n = densityNoise.fbm(u * 3.4 + 2.1, v * 3.4 + 5.7, octaves: 2)
                let k = min(1, max(0, 0.5 + n * 1.5))
                density[y * densityW + x] = Float(0.3 + 0.7 * k * k * (3 - 2 * k))
            }
        }

        return dStore.withUnsafeMutableBufferPointer { d -> [DoodleItem] in
            solidStore.withUnsafeMutableBufferPointer { solid -> [DoodleItem] in
            skipStore.withUnsafeMutableBufferPointer { skip -> [DoodleItem] in
            @inline(__always) func fits(_ g: DoodleGlyph, _ x: Double, _ y: Double, _ rot: Double, _ size: Double, _ flip: Bool, _ need: Int, _ tuck: Bool) -> Bool {
                let k = size * cellsPerUnit
                let c = Float(cos(rot) * k), s = Float(sin(rot) * k)
                let ox = Float((x + pad) * cellsPerUnit), oy = Float((y + pad) * cellsPerUnit)
                let sign: Float = flip ? -1 : 1
                let count = size < 0.08 ? min(g.samples.count, 60) : (size < 0.16 ? min(g.samples.count, 150) : g.samples.count)
                var hidden = 0
                let maxHidden = tuck ? count / 4 : 0
                let bigger = Float(size * 1.45)
                for i in 0..<count {
                    let p = g.samples[i]
                    let lx = p.x * sign
                    let gx = Int(ox + c * lx - s * p.y), gy = Int(oy + s * lx + c * p.y)
                    if gx < 0 || gy < 0 || gx >= gw || gy >= gh { return false }
                    let v = Int(d[gy &* gw &+ gx])
                    if v >= need { continue }
                    if !tuck { return false }
                    if v > 0 { continue }
                    if solid[gy &* gw &+ gx] < bigger { return false }
                    hidden += 1
                    if hidden > maxHidden { return false }
                }
                return true
            }

            /// The share of the drawing inside the rectangle.
            func visible(_ g: DoodleGlyph, _ x: Double, _ y: Double, _ rot: Double, _ size: Double, _ flip: Bool, top: Double = 0, bottom: Double = 0) -> Double {
                let c = cos(rot) * size, s = sin(rot) * size
                var inside = 0
                let sign = flip ? -1.0 : 1.0
                for p in g.samples {
                    let lx = Double(p.x) * sign, ly = Double(p.y)
                    let px = x + c * lx - s * ly, py = y + s * lx + c * ly
                    if px >= 0, py >= top, px <= wu, py <= hu - bottom { inside += 1 }
                }
                return Double(inside) / Double(max(1, g.samples.count))
            }

            /// May the drawing sit here, as far as the picture's edges are concerned?
            func edgeOK(_ g: DoodleGlyph, _ x: Double, _ y: Double, _ rot: Double, _ size: Double, _ flip: Bool) -> Bool {
                if g.must || g.whole {
                    // Seen whole, and clear of the status bar and the home indicator.
                    return visible(g, x, y, rot, size, flip, top: topBand, bottom: bottomBand) >= 0.985
                }
                if size > 0.14 { return visible(g, x, y, rot, size, flip) >= 0.9 }
                if size >= 0.08 { return visible(g, x, y, rot, size, flip) >= 0.78 }
                return visible(g, x, y, rot, size, flip) >= 0.6
            }

            func stamp(_ g: DoodleGlyph, _ item: DoodleItem) {
                let k = item.size * cellsPerUnit
                let ox = (item.x + pad) * cellsPerUnit, oy = (item.y + pad) * cellsPerUnit
                let c = cos(item.rot), s = sin(item.rot)
                let reach = k * 0.72 + 1
                let x0 = max(0, Int(ox - reach)), x1 = min(gw - 1, Int(ox + reach))
                let y0 = max(0, Int(oy - reach)), y1 = min(gh - 1, Int(oy + reach))
                guard x0 <= x1, y0 <= y1 else { return }
                let side = DoodleGlyph.maskSide
                let longest = Double(side - 6)
                let sign = item.flip ? -1.0 : 1.0
                let fsize = Float(item.size)
                for gy in y0...y1 {
                    for gx in x0...x1 {
                        let dx = (Double(gx) + 0.5 - ox) / k, dy = (Double(gy) + 0.5 - oy) / k
                        let lx = (c * dx + s * dy) * sign, ly = -s * dx + c * dy
                        let mx = Int((lx * longest + Double(side) / 2).rounded(.down)), my = Int((ly * longest + Double(side) / 2).rounded(.down))
                        if mx >= 0, my >= 0, mx < side, my < side {
                            if g.mask[my * side + mx] > 127 { d[gy * gw + gx] = 0 }
                            if !g.noTuck, g.solid[my * side + mx] > 127, solid[gy * gw + gx] < fsize { solid[gy * gw + gx] = fsize }
                        }
                    }
                }
                // Distances near it change; further away they cannot, because they are capped.
                let r = Int(cap / 3) + 1
                let wx0 = max(1, x0 - r), wx1 = min(gw - 2, x1 + r), wy0 = max(1, y0 - r), wy1 = min(gh - 2, y1 + r)
                guard wx0 <= wx1, wy0 <= wy1 else { return }
                for y in wy0...wy1 {
                    var i = y * gw + wx0
                    for _ in wx0...wx1 {
                        var v = d[i]
                        if v > 0 {
                            v = min(v, d[i - 1] &+ 3, d[i - gw] &+ 3, d[i - gw - 1] &+ 4, d[i - gw + 1] &+ 4)
                            d[i] = v
                        }
                        i += 1
                    }
                }
                for y in stride(from: wy1, through: wy0, by: -1) {
                    var i = y * gw + wx1
                    for _ in wx0...wx1 {
                        var v = d[i]
                        if v > 0 {
                            v = min(v, d[i + 1] &+ 3, d[i + gw] &+ 3, d[i + gw + 1] &+ 4, d[i + gw - 1] &+ 4)
                            d[i] = v
                        }
                        i -= 1
                    }
                }
            }

            /// Is another copy of this drawing too near?
            func crowded(_ glyph: Int, _ x: Double, _ y: Double, _ size: Double) -> Bool {
                for it in items where it.glyph == glyph {
                    let big = max(size, it.size)
                    let reach = big > 0.13 ? 0.82 : (big > 0.06 ? 0.42 : 0.2)
                    let dx = it.x - x, dy = it.y - y
                    if dx * dx + dy * dy < reach * reach { return true }
                }
                return false
            }

            func capOf(_ glyph: Int) -> Int {
                lib[glyph].cap ?? (lib[glyph].maxSize < 0.08 ? 5 : 2)
            }

            func place(_ glyph: Int, _ x: Double, _ y: Double, _ rot: Double, _ size: Double, _ flip: Bool) {
                let item = DoodleItem(glyph: glyph, x: x, y: y, rot: rot, size: size, flip: flip, seed: rng.nextUInt64())
                items.append(item)
                used[glyph] += 1
                largest[glyph] = max(largest[glyph], size)
                stamp(lib[glyph], item)
            }

            /// The biggest size in `lo…hi` at which it fits there, or nil.
            func biggest(_ g: DoodleGlyph, _ x: Double, _ y: Double, _ rot: Double, _ flip: Bool, _ lo: Double, _ hi: Double, tuck: Bool = false) -> Double? {
                guard hi >= lo, fits(g, x, y, rot, lo, flip, margin, tuck) else { return nil }
                if fits(g, x, y, rot, hi, flip, margin, tuck) { return hi }
                var a = lo, b = hi
                for _ in 0..<5 {
                    let m = (a + b) / 2
                    if fits(g, x, y, rot, m, flip, margin, tuck) { a = m } else { b = m }
                }
                return a
            }

            /// A drawing that has been used may come back, but only clearly smaller, never as its own twin.
            func ceiling(_ glyph: Int, _ limit: Double) -> Double {
                let g = lib[glyph]
                var hi = min(g.maxSize, limit)
                if used[glyph] > 0, g.maxSize >= 0.13 { hi = min(hi, largest[glyph] * 0.58) }
                return hi
            }

            /// How far it may lean. Anything below hero size is allowed to lean a little, or the picture stacks in rows.
            func lean(_ g: DoodleGlyph, _ size: Double) -> Double {
                let degrees = size < 0.27 ? max(g.tilt, 13) : g.tilt
                return degrees * .pi / 180
            }

            // The heroes first, spread out: darts with a minimum spacing, so they never bunch.
            let heroes = lib.indices.filter { lib[$0].maxSize >= 0.27 }
            var shuffled = heroes
            for i in shuffled.indices.reversed() where i > 0 { shuffled.swapAt(i, Int(rng.next() * Double(i + 1))) }
            let heroGap = 0.5
            var spots: [(Double, Double)] = []
            var tries = 0
            let heroWanted = Int(wu * hu / (heroGap * heroGap * 0.92))
            while spots.count < heroWanted && tries < 3000 {
                tries += 1
                let x = rng.next(0.02, wu - 0.02), y = rng.next(0.02, hu - 0.02)
                if spots.allSatisfy({ hypot($0.0 - x, $0.1 - y) >= heroGap }) { spots.append((x, y)) }
            }
            // Central spots first, so the drawings the set is about are seen whole; the edges can crop what comes later.
            spots.sort { abs($0.0 - wu / 2) < abs($1.0 - wu / 2) }
            // The drawings the set is about go first, each once, before anything repeats.
            // They search the whole picture on their own, spreading out, so none of them can be lost to a bad run of spots.
            let musts = shuffled.filter { lib[$0].must }, rest = shuffled.filter { !lib[$0].must }
            var mustSpots: [(Double, Double)] = []
            for (order, glyph) in musts.enumerated() {
                let g = lib[glyph]
                // Every other one a little smaller, so the heroes are not all one size.
                let top = g.maxSize * (order % 2 == 0 ? 1 : 0.86)
                let low = max(0.2, g.minSize * 0.85)
                var best: (x: Double, y: Double, rot: Double, size: Double, flip: Bool, score: Double)?
                for _ in 0..<420 {
                    let flip = !g.noFlip && rng.next() < 0.5
                    let rot = rng.next(-g.tilt, g.tilt) * .pi / 180 * 0.7
                    let x = rng.next(0.08, wu - 0.08), y = rng.next(topBand + 0.05, hu - bottomBand - 0.05)
                    guard g.zone.contains(y / hu) else { continue }
                    guard let size = biggest(g, x, y, rot, flip, low, top) else { continue }
                    guard edgeOK(g, x, y, rot, size, flip) else { continue }
                    let near = mustSpots.map { hypot($0.0 - x, $0.1 - y) }.min() ?? 1
                    let spread = min(1, near / 0.62)
                    let score = size * size * g.coverage * spread * spread * rng.next(0.8, 1)
                    if best == nil || score > best!.score { best = (x, y, rot, size, flip, score) }
                }
                if let b = best {
                    place(glyph, b.x, b.y, b.rot, b.size, b.flip)
                    mustSpots.append((b.x, b.y))
                }
            }
            var queue = rest
            for spot in spots where !queue.isEmpty {
                var best: (slot: Int, glyph: Int, x: Double, y: Double, rot: Double, size: Double, flip: Bool, score: Double)?
                // While any of the drawings the set is about are unplaced, only they are in the running.
                let mustsLeft = queue.prefix { lib[$0].must }.count
                let window = mustsLeft > 0 ? mustsLeft : min(queue.count, 6)
                for attempt in 0..<(window * 5) {
                    let slot = attempt % max(1, window)
                    let glyph = queue[slot]
                    let g = lib[glyph]
                    let flip = !g.noFlip && rng.next() < 0.5
                    let rot = rng.next(-g.tilt, g.tilt) * .pi / 180 * 0.7
                    let x = spot.0 + rng.next(-0.04, 0.04), y = spot.1 + rng.next(-0.04, 0.04)
                    guard g.zone.contains(y / hu) else { continue }
                    guard let size = biggest(g, x, y, rot, flip, max(0.24, g.minSize), g.maxSize) else { continue }
                    guard edgeOK(g, x, y, rot, size, flip) else { continue }
                    if crowded(glyph, x, y, 0.3) { continue }
                    // Earlier in the queue beats a slightly larger fit, so the `must` drawings are not squeezed out.
                    let score = size * size * g.coverage * (1 - 0.08 * Double(slot))
                    if best == nil || score > best!.score { best = (slot, glyph, x, y, rot, size, flip, score) }
                }
                if best == nil, mustsLeft > 0, mustsLeft < queue.count {
                    for attempt in 0..<12 {
                        let slot = mustsLeft + attempt % min(queue.count - mustsLeft, 4)
                        let glyph = queue[slot]
                        let g = lib[glyph]
                        let flip = !g.noFlip && rng.next() < 0.5
                        let rot = rng.next(-g.tilt, g.tilt) * .pi / 180 * 0.7
                        let x = spot.0 + rng.next(-0.04, 0.04), y = spot.1 + rng.next(-0.04, 0.04)
                        guard g.zone.contains(y / hu) else { continue }
                        guard let size = biggest(g, x, y, rot, flip, max(0.24, g.minSize), g.maxSize) else { continue }
                        guard edgeOK(g, x, y, rot, size, flip) else { continue }
                        if crowded(glyph, x, y, 0.3) { continue }
                        let score = size * size * g.coverage
                        if best == nil || score > best!.score { best = (slot, glyph, x, y, rot, size, flip, score) }
                    }
                }
                if let b = best {
                    place(b.glyph, b.x, b.y, b.rot, b.size, b.flip)
                    queue.remove(at: b.slot)
                }
            }

            let inX0 = Int(pad * cellsPerUnit), inX1 = min(gw - 1, Int((wu + pad) * cellsPerUnit))
            let inY0 = Int(pad * cellsPerUnit), inY1 = min(gh - 1, Int((hu + pad) * cellsPerUnit))

            /// Always the largest hole, with drawings from `pool`, down to holes `stop` wide (chamfer units).
            func fill(pool: [Int], lo: Double, hi: Double, stop: Int, tuckChance: Double, thin: Bool, limits: [Double], once: Bool = false) {
                var misses = 0
                var cycle = 0
                var budget = 700
                for i in 0..<(gw * gh) { skip[i] = false }
                while budget > 0 {
                    budget -= 1
                    if once, pool.allSatisfy({ used[$0] > 0 }) { break }
                    var bestV: Float = -1, bestX = 0, bestY = 0
                    var y = inY0
                    while y <= inY1 {
                        let row = min(densityH - 1, (y - inY0) * densityH / max(1, inY1 - inY0 + 1))
                        var i = y * gw + inX0
                        var x = inX0
                        while x <= inX1 {
                            if !skip[i] {
                                var v = Float(d[i])
                                if thin {
                                    let col = min(densityW - 1, (x - inX0) * densityW / max(1, inX1 - inX0 + 1))
                                    v *= density[row * densityW + col]
                                }
                                if v > bestV {
                                    bestV = v
                                    bestX = x
                                    bestY = y
                                }
                            }
                            i += 2
                            x += 2
                        }
                        y += 2
                    }
                    if bestV < Float(stop) { break }
                    let cx = (Double(bestX) + 0.5) / cellsPerUnit - pad, cy = (Double(bestY) + 0.5) / cellsPerUnit - pad
                    let hole = Double(d[bestY * gw + bestX]) / 3 / cellsPerUnit // The hole's radius in units (capped).
                    cycle += 1
                    let limit = min(hi, limits[cycle % limits.count])
                    var best: (glyph: Int, x: Double, y: Double, rot: Double, size: Double, flip: Bool, tuck: Bool, score: Double)?
                    let tryCount = hole > 0.03 ? 100 : 40
                    for _ in 0..<tryCount {
                        let glyph = pool[Int(rng.next() * Double(pool.count))]
                        let g = lib[glyph]
                        if used[glyph] >= (once ? 1 : capOf(glyph)) { continue }
                        let low = max(lo, g.minSize)
                        if low > hole * 6.5 { continue }
                        let top = ceiling(glyph, limit)
                        if top < low { continue }
                        let flip = !g.noFlip && rng.next() < 0.5
                        let rot = rng.next(-1, 1) * lean(g, top)
                        let x = cx + rng.next(-0.45, 0.45) * hole, y = cy + rng.next(-0.45, 0.45) * hole
                        let tuck = rng.next() < tuckChance && !g.noTuck
                        guard let size = biggest(g, x, y, rot, flip, low, top, tuck: tuck) else { continue }
                        if crowded(glyph, x, y, size) { continue }
                        // A drawing already used counts for less: five d20s read as a stamp.
                        let tired = (g.maxSize >= 0.13 ? 1.1 : 0.7) * Double(used[glyph])
                        // A drawing not yet seen in this picture goes ahead of anything seen, or the airy ones never get a turn.
                        let fresh = used[glyph] == 0 && g.maxSize >= 0.12 ? 2.4 : 1.0
                        let score = fresh * size * size * g.coverage * g.weight / (1.0 + tired)
                        if let b = best, b.score >= score { continue }
                        if !edgeOK(g, x, y, rot, size, flip) { continue }
                        best = (glyph, x, y, rot, size, flip, tuck, score)
                    }
                    if var b = best {
                        // Let it shuffle and turn into the hole, growing until it touches on all sides.
                        let g = lib[b.glyph]
                        let top = ceiling(b.glyph, limit)
                        if b.size < top {
                            var step = max(0.0035, hole * 0.3)
                            let tiltLimit = lean(g, top)
                            for _ in 0..<5 {
                                var moved = false
                                for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7), (-0.7, -0.7)] {
                                    let nx = b.x + dx * step, ny = b.y + dy * step
                                    if let s = biggest(g, nx, ny, b.rot, b.flip, b.size, top, tuck: b.tuck), s > b.size * 1.004, edgeOK(g, nx, ny, b.rot, s, b.flip) {
                                        b.x = nx
                                        b.y = ny
                                        b.size = s
                                        moved = true
                                    }
                                }
                                for da in [0.1, -0.1] where abs(b.rot + da) <= tiltLimit {
                                    if let s = biggest(g, b.x, b.y, b.rot + da, b.flip, b.size, top, tuck: b.tuck), s > b.size * 1.004, edgeOK(g, b.x, b.y, b.rot + da, s, b.flip) {
                                        b.rot += da
                                        b.size = s
                                        moved = true
                                    }
                                }
                                if !moved { step *= 0.5 }
                                if b.size >= top { break }
                            }
                        }
                        place(b.glyph, b.x, b.y, b.rot, b.size, b.flip)
                        misses = 0
                    } else {
                        // Nothing fits: rule the spot out so the search moves on.
                        for yy in max(0, bestY - 2)...min(gh - 1, bestY + 2) {
                            for xx in max(0, bestX - 2)...min(gw - 1, bestX + 2) { skip[yy * gw + xx] = true }
                        }
                        misses += 1
                        if misses > 200 { break }
                    }
                }
            }

            let all = Array(lib.indices)
            // Mid-size drawings everywhere, before any filler can take a hole.
            let keys = all.filter { lib[$0].key && used[$0] == 0 }
            if !keys.isEmpty { fill(pool: keys, lo: 0.1, hi: 0.27, stop: 12, tuckChance: 0, thin: false, limits: [0.27, 0.2, 0.24, 0.18], once: true) }
            let mids = all.filter { lib[$0].maxSize >= 0.12 }
            fill(pool: mids, lo: 0.115, hi: 0.27, stop: 16, tuckChance: 0.14, thin: false, limits: [0.27, 0.17, 0.22, 0.14])
            // Small drawings.
            let smalls = all.filter { lib[$0].maxSize >= 0.08 }
            fill(pool: smalls, lo: 0.07, hi: 0.13, stop: 10, tuckChance: 0.2, thin: false, limits: [0.13, 0.1, 0.12, 0.085])
            // Filler marks, in loose clusters, and whatever small drawing still has a copy left.
            let marks = all.filter { lib[$0].minSize < 0.07 }
            fill(pool: marks, lo: 0.01, hi: 0.075, stop: 7, tuckChance: 0.22, thin: true, limits: [0.075, 0.05, 0.062, 0.04])
            // Smallest first, so whatever tucked under a bigger drawing is hidden by it.
            return items.sorted { $0.size < $1.size }
            }
            }
        }
    }
}
