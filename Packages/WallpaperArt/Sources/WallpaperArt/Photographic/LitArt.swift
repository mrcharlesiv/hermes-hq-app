// Lit3D core: maths, noise, atmosphere, tone curve. Physically lit pictures: everything is computed, per pixel.
import CoreGraphics
import Foundation
import simd

typealias LitV3 = SIMD3<Float>
typealias LitV2 = SIMD2<Float>

@inline(__always) nonisolated func litSat(_ x: Float) -> Float { min(1, max(0, x)) }
@inline(__always) nonisolated func litLerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) nonisolated func litLerp(_ a: LitV3, _ b: LitV3, _ t: Float) -> LitV3 { a + (b - a) * t }
@inline(__always) nonisolated func litSstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = litSat((x - a) / (b - a)); return t * t * (3 - 2 * t)
}
@inline(__always) nonisolated func litRemap(_ v: Float, _ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float { c + (v - a) / (b - a) * (d - c) }
@inline(__always) nonisolated func litDot3(_ a: LitV3, _ b: LitV3) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
@inline(__always) nonisolated func litLen3(_ a: LitV3) -> Float { litDot3(a, a).squareRoot() }
@inline(__always) nonisolated func litNorm3(_ a: LitV3) -> LitV3 { a / litDot3(a, a).squareRoot() }
@inline(__always) nonisolated func litExp3(_ a: LitV3) -> LitV3 { LitV3(expf(a.x), expf(a.y), expf(a.z)) }
@inline(__always) nonisolated func litLuma(_ c: LitV3) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
@inline(__always) nonisolated func litReflect3(_ d: LitV3, _ n: LitV3) -> LitV3 { d - n * (2 * litDot3(d, n)) }

/// Rows in parallel; `chunk` rows per work item so a thread stays on neighbouring memory.
@inline(__always) nonisolated func litParallelFor(_ n: Int, chunk: Int = 4, _ body: (Int) -> Void) {
    if n <= 0 { return }
    let chunks = (n + chunk - 1) / chunk
    withoutActuallyEscaping(body) { esc in
        nonisolated(unsafe) let run = esc
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let end = min(n, (c + 1) * chunk)
            var i = c * chunk
            while i < end { run(i); i += 1 }
        }
    }
}

@inline(__always) nonisolated func litNorm2(_ a: LitV2) -> LitV2 { a / (a.x * a.x + a.y * a.y).squareRoot() }

/// DEV ONLY (stripped by join.py): where the time goes, process CPU and wall, when LIT3D_CLOCK is set.


// MARK: Noise

@inline(__always) nonisolated func litHash32(_ x: Int32, _ y: Int32, _ s: UInt32) -> UInt32 {
    var h = (UInt32(bitPattern: x) &* 0x8DA6_B343) ^ (UInt32(bitPattern: y) &* 0xD816_3841) ^ s
    h ^= h >> 13
    h = h &* 0x5BD1_E995
    h ^= h >> 15
    return h
}

@inline(__always) nonisolated func litHash32(_ x: Int32, _ y: Int32, _ z: Int32, _ s: UInt32) -> UInt32 {
    var h = (UInt32(bitPattern: x) &* 0x8DA6_B343) ^ (UInt32(bitPattern: y) &* 0xD816_3841) ^ (UInt32(bitPattern: z) &* 0xCB1A_B31F) ^ s
    h ^= h >> 13
    h = h &* 0x5BD1_E995
    h ^= h >> 15
    return h
}

@inline(__always) nonisolated func litUnit(_ h: UInt32) -> Float { Float(h & 0xFFFFFF) * (1.0 / 16777216.0) }

@inline(__always) nonisolated private func gradDot(_ i: Int32, _ j: Int32, _ dx: Float, _ dy: Float, _ s: UInt32) -> Float {
    let h = litHash32(i, j, s)
    let gx = Float(h & 0xFFFF) * (1.0 / 32768.0) - 1
    let gy = Float(h >> 16) * (1.0 / 32768.0) - 1
    return gx * dx + gy * dy
}

/// Gradient noise, about -1…1 (typically ±0.7).
@inline(__always) nonisolated func litGnoise(_ x: Float, _ y: Float, _ s: UInt32) -> Float {
    let fx = x.rounded(.down), fy = y.rounded(.down)
    let ix = Int32(fx), iy = Int32(fy)
    let dx = x - fx, dy = y - fy
    let u = dx * dx * dx * (dx * (dx * 6 - 15) + 10), v = dy * dy * dy * (dy * (dy * 6 - 15) + 10)
    let a = gradDot(ix, iy, dx, dy, s), b = gradDot(ix + 1, iy, dx - 1, dy, s)
    let c = gradDot(ix, iy + 1, dx, dy - 1, s), d = gradDot(ix + 1, iy + 1, dx - 1, dy - 1, s)
    return (a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v) * 1.5
}

@inline(__always) nonisolated func litFbm(_ x: Float, _ y: Float, _ octaves: Int, _ s: UInt32, gain: Float = 0.5) -> Float {
    var sum: Float = 0, amp: Float = 1, norm: Float = 0
    var px = x, py = y
    var o = 0
    while o < octaves {
        sum += amp * litGnoise(px, py, s &+ UInt32(o) &* 131)
        norm += amp
        amp *= gain
        let nx = (0.8 * px - 0.6 * py) * 2.03 + 11.3
        py = (0.6 * px + 0.8 * py) * 2.03 - 7.1
        px = nx
        o += 1
    }
    return sum / norm
}

/// Ridged octaves, 0…1: sharp crests where the noise crosses zero. Each octave damped where the last was low.
@inline(__always) nonisolated func litRidged(_ x: Float, _ y: Float, _ octaves: Int, _ s: UInt32, gain: Float = 0.5) -> Float {
    var sum: Float = 0, amp: Float = 1, norm: Float = 0, weight: Float = 1
    var px = x, py = y
    var o = 0
    while o < octaves {
        var n = 1 - abs(litGnoise(px, py, s &+ UInt32(o) &* 131))
        n = n * n
        sum += amp * n * weight
        norm += amp
        weight = litSat(n * 1.6)
        amp *= gain
        let nx = (0.8 * px - 0.6 * py) * 2.03 + 11.3
        py = (0.6 * px + 0.8 * py) * 2.03 - 7.1
        px = nx
        o += 1
    }
    return sum / norm
}

// MARK: Tiling 3D textures (the clouds' shape and detail)

nonisolated struct LitTex3D: @unchecked Sendable {
    let n: Int32
    let mask: Int32
    let p: UnsafeMutablePointer<Float>
    init(n: Int) {
        self.n = Int32(n); mask = Int32(n - 1)
        p = UnsafeMutablePointer<Float>.allocate(capacity: n * n * n)
    }
    func free() { p.deallocate() }

    /// Trilinear; a whole tile is 1.0.
    @inline(__always) func sample(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let fn = Float(n)
        let sx = x * fn, sy = y * fn, sz = z * fn
        let fx = sx.rounded(.down), fy = sy.rounded(.down), fz = sz.rounded(.down)
        let ax = sx - fx, ay = sy - fy, az = sz - fz
        let ix = Int32(fx) & mask, iy = Int32(fy) & mask, iz = Int32(fz) & mask
        let jx = (ix + 1) & mask, jy = (iy + 1) & mask, jz = (iz + 1) & mask
        let n1 = Int(n), n2 = n1 * n1
        let ky0 = Int(iy) * n1, ky1 = Int(jy) * n1, kz0 = Int(iz) * n2, kz1 = Int(jz) * n2
        let c000 = p[kz0 + ky0 + Int(ix)], c100 = p[kz0 + ky0 + Int(jx)]
        let c010 = p[kz0 + ky1 + Int(ix)], c110 = p[kz0 + ky1 + Int(jx)]
        let c001 = p[kz1 + ky0 + Int(ix)], c101 = p[kz1 + ky0 + Int(jx)]
        let c011 = p[kz1 + ky1 + Int(ix)], c111 = p[kz1 + ky1 + Int(jx)]
        let x00 = c000 + (c100 - c000) * ax, x10 = c010 + (c110 - c010) * ax
        let x01 = c001 + (c101 - c001) * ax, x11 = c011 + (c111 - c011) * ax
        let y0 = x00 + (x10 - x00) * ay, y1 = x01 + (x11 - x01) * ay
        return y0 + (y1 - y0) * az
    }
}

@inline(__always) nonisolated private func grad3(_ i: Int32, _ j: Int32, _ k: Int32, _ d: LitV3, _ per: Int32, _ s: UInt32) -> Float {
    let h = litHash32(i & (per - 1), j & (per - 1), k & (per - 1), s)
    let gx = Float(h & 0x3FF) * (1.0 / 512.0) - 1
    let gy = Float((h >> 10) & 0x3FF) * (1.0 / 512.0) - 1
    let gz = Float((h >> 20) & 0x3FF) * (1.0 / 512.0) - 1
    return gx * d.x + gy * d.y + gz * d.z
}

/// Tiling Perlin noise; `per` lattice cells per tile (power of two), p in tile units.
@inline(__always) nonisolated func litPerlin3(_ p: LitV3, per: Int32, _ s: UInt32) -> Float {
    let q = p * Float(per)
    let f = q.rounded(.down)
    let i = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z))
    let d = q - f
    let u = d * d * d * (d * (d * 6 - LitV3(repeating: 15)) + LitV3(repeating: 10))
    let n000 = grad3(i.x, i.y, i.z, d, per, s)
    let n100 = grad3(i.x + 1, i.y, i.z, d - LitV3(1, 0, 0), per, s)
    let n010 = grad3(i.x, i.y + 1, i.z, d - LitV3(0, 1, 0), per, s)
    let n110 = grad3(i.x + 1, i.y + 1, i.z, d - LitV3(1, 1, 0), per, s)
    let n001 = grad3(i.x, i.y, i.z + 1, d - LitV3(0, 0, 1), per, s)
    let n101 = grad3(i.x + 1, i.y, i.z + 1, d - LitV3(1, 0, 1), per, s)
    let n011 = grad3(i.x, i.y + 1, i.z + 1, d - LitV3(0, 1, 1), per, s)
    let n111 = grad3(i.x + 1, i.y + 1, i.z + 1, d - LitV3(1, 1, 1), per, s)
    let x00 = litLerp(n000, n100, u.x), x10 = litLerp(n010, n110, u.x), x01 = litLerp(n001, n101, u.x), x11 = litLerp(n011, n111, u.x)
    return litLerp(litLerp(x00, x10, u.y), litLerp(x01, x11, u.y), u.z)
}

/// Tiling Worley: 1 at feature points, falling to 0 a cell away. Puffy when added in octaves.
@inline(__always) nonisolated func litWorley3(_ p: LitV3, per: Int32, _ s: UInt32) -> Float {
    let q = p * Float(per)
    let f = q.rounded(.down)
    let i = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z))
    let d = q - f
    var best: Float = 9
    var k: Int32 = -1
    while k <= 1 {
        var j: Int32 = -1
        while j <= 1 {
            var a: Int32 = -1
            while a <= 1 {
                let h = litHash32((i.x + a) & (per - 1), (i.y + j) & (per - 1), (i.z + k) & (per - 1), s)
                let fp = LitV3(Float(h & 0x3FF), Float((h >> 10) & 0x3FF), Float((h >> 20) & 0x3FF)) * (1.0 / 1024.0)
                let r = LitV3(Float(a), Float(j), Float(k)) + fp - d
                best = min(best, litDot3(r, r))
                a += 1
            }
            j += 1
        }
        k += 1
    }
    return litSat(1 - best.squareRoot())
}

/// The clouds' two tiling textures. Shape: Perlin-Worley (billows with wispy gaps). Detail: three octaves of Worley.
nonisolated func litMakeCloudTextures(seed: UInt32, shapeN: Int = 64, detailN: Int = 32) -> (shape: LitTex3D, detail: LitTex3D) {
    let shape = LitTex3D(n: shapeN), detail = LitTex3D(n: detailN)
    let invS = 1 / Float(shapeN), invD = 1 / Float(detailN)
    litParallelFor(shapeN, chunk: 1) { k in
        for j in 0..<shapeN {
            for i in 0..<shapeN {
                let p = LitV3(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * invS
                var pf: Float = 0, amp: Float = 1, nrm: Float = 0
                var per: Int32 = 4
                for o in 0..<4 {
                    pf += amp * litPerlin3(p, per: per, seed &+ UInt32(o) &* 17)
                    nrm += amp
                    amp *= 0.55
                    per *= 2
                }
                pf = litSat(pf / nrm * 1.3 + 0.5)
                let w1 = litWorley3(p, per: 4, seed &+ 101), w2 = litWorley3(p, per: 8, seed &+ 102), w3 = litWorley3(p, per: 16, seed &+ 103)
                let w = w1 * 0.625 + w2 * 0.25 + w3 * 0.125
                shape.p[k * shapeN * shapeN + j * shapeN + i] = litSat(litRemap(pf, -(1 - w) * 0.9, 1, 0, 1))
            }
        }
    }
    litParallelFor(detailN, chunk: 1) { k in
        for j in 0..<detailN {
            for i in 0..<detailN {
                let p = LitV3(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * invD
                let w1 = litWorley3(p, per: 4, seed &+ 201), w2 = litWorley3(p, per: 8, seed &+ 202), w3 = litWorley3(p, per: 16, seed &+ 203)
                detail.p[k * detailN * detailN + j * detailN + i] = w1 * 0.625 + w2 * 0.25 + w3 * 0.125
            }
        }
    }
    return (shape, detail)
}

// MARK: LitAtmosphere: Rayleigh, Mie and ozone over a curved planet

nonisolated struct LitAtmosphere: @unchecked Sendable {
    let R: Float = 6_371_000, Ra: Float = 6_451_000
    let betaR = LitV3(5.802e-6, 13.558e-6, 33.1e-6)
    let betaO: LitV3
    let betaM: Float
    let Hr: Float = 8000
    let Hm: Float
    let g: Float
    let sunDir: LitV3
    let sunE: LitV3
    let altBase: Float
    /// Multiplies what the sky itself sends out (below 1 for a dark night sky over a moonlit land).
    let skyGain: Float
    let airGain: Float
    let msGain: Float

    // Transmittance: [mu][r]
    private let nTR = 32, nTM = 192
    private let tl: UnsafeMutablePointer<LitV3>
    // Sky as seen from the camera: [elevation][azimuth from the sun]
    private let nSA = 48, nSE = 192
    private let sl: UnsafeMutablePointer<LitV3>
    // Sun colour at altitude (metres above y = 0 mapped through sqrt)
    private let nSH = 96
    private let sh: UnsafeMutablePointer<LitV3>
    let camAlt: Float

    init(sunDir: LitV3, sunE: LitV3, altBase: Float, camY: Float, turbidity: Float, g: Float = 0.8, Hm: Float = 1200, skyGain: Float = 1, msGain: Float = 1, airGain: Float? = nil, ozone: Float = 1) {
        self.betaO = LitV3(0.650e-6, 1.881e-6, 0.085e-6) * ozone
        self.sunDir = litNorm3(sunDir)
        self.sunE = sunE
        self.altBase = altBase
        self.betaM = 2.0e-5 * turbidity
        self.g = g
        self.Hm = Hm
        self.skyGain = skyGain
        self.airGain = airGain ?? skyGain
        self.msGain = msGain
        camAlt = altBase + camY
        tl = .allocate(capacity: 32 * 192)
        sl = .allocate(capacity: 48 * 192)
        sh = .allocate(capacity: 96)
        build()
    }

    func free() { tl.deallocate(); sl.deallocate(); sh.deallocate() }

    @inline(__always) private func muToU(_ mu: Float) -> Float {
        0.5 + 0.5 * (mu < 0 ? -(-mu).squareRoot() : mu.squareRoot())
    }
    @inline(__always) private func hToU(_ h: Float) -> Float { (max(0, h) / (Ra - R)).squareRoot() }

    private func build() {
        let nTR = self.nTR, nTM = self.nTM, nSA = self.nSA, nSE = self.nSE, nSH = self.nSH
        let tl = self.tl, sl = self.sl, sh = self.sh
        let R = self.R, Ra = self.Ra, Hr = self.Hr, Hm = self.Hm
        let betaR = self.betaR, betaM = self.betaM, betaO = self.betaO
        // Transmittance towards a direction with cosine mu at radius r.
        litParallelFor(nTM, chunk: 8) { im in
            let u = (Float(im) + 0.5) / Float(nTM) * 2 - 1
            let mu = u < 0 ? -(u * u) : u * u
            for ir in 0..<nTR {
                let uh = (Float(ir) + 0.5) / Float(nTR)
                let r = R + uh * uh * (Ra - R)
                // Distance to the top of the atmosphere; a ray into the ground gets a soft fall to black.
                let b = r * mu
                let dTop = -b + max(0, b * b - r * r + Ra * Ra).squareRoot()
                let disc = b * b - r * r + R * R
                let hitsGround = mu < 0 && disc > 0
                let end = dTop
                var odR: Float = 0, odM: Float = 0, odO: Float = 0
                let N = 40
                for s in 0..<N {
                    let t0 = Float(s) / Float(N), t1 = Float(s + 1) / Float(N)
                    let a0 = t0 * t0 * end, a1 = t1 * t1 * end
                    let m = (a0 + a1) * 0.5, ds = a1 - a0
                    let rr = (r * r + m * m + 2 * r * m * mu).squareRoot()
                    let h = max(0, rr - R)
                    odR += expf(-h / Hr) * ds
                    odM += expf(-h / Hm) * ds
                    odO += max(0, 1 - abs(h - 25000) / 15000) * ds
                }
                var tau = betaR * odR + LitV3(repeating: betaM * 1.1) * odM + betaO * odO
                if hitsGround {
                    // Light from below the geometric horizon: gone, but over a thin soft edge.
                    let depth = (-b - disc.squareRoot()) // distance to the ground point
                    _ = depth
                    tau += LitV3(repeating: 30)
                }
                tl[im * nTR + ir] = litExp3(-tau)
            }
        }
        // Sky.
        let sun = sunDir, r0 = R + max(1, camAlt)
        let g = self.g, ms = msGain
        let gg = g * g
        let base = sunE
        litParallelFor(nSE, chunk: 4) { ie in
            let v = (Float(ie) + 0.5) / Float(nSE)
            // Tightly packed around the horizon.
            let elev = LitAtmosphere.vToElev(v)
            let ce = cosf(elev), se = sinf(elev)
            for ia in 0..<nSA {
                let az = (Float(ia) + 0.5) / Float(nSA) * Float.pi
                // Azimuth measured from the sun's own.
                let sunAz = atan2f(sun.x, sun.z)
                let dir = LitV3(ce * sinf(az + sunAz), se, ce * cosf(az + sunAz))
                let mu = se
                let b = r0 * mu
                let dTop = -b + max(0, b * b - r0 * r0 + Ra * Ra).squareRoot()
                let disc = b * b - r0 * r0 + R * R
                let end = (mu < 0 && disc > 0) ? (-b - disc.squareRoot()) : dTop
                let cosT = litDot3(dir, sun)
                let pr = 3 / (16 * Float.pi) * (1 + cosT * cosT)
                let den = 1 + gg - 2 * g * cosT
                let pm = 3 / (8 * Float.pi) * ((1 - gg) * (1 + cosT * cosT)) / ((2 + gg) * den * den.squareRoot())
                var odR: Float = 0, odM: Float = 0, odO: Float = 0
                var sumR = LitV3.zero, sumM = LitV3.zero, sumMS = LitV3.zero
                let N = 32
                for s in 0..<N {
                    let t0 = Float(s) / Float(N), t1 = Float(s + 1) / Float(N)
                    let a0 = t0 * t0 * end, a1 = t1 * t1 * end
                    let m = (a0 + a1) * 0.5, ds = a1 - a0
                    let P = LitV3(0, r0, 0) + dir * m
                    let rr = litLen3(P)
                    let h = max(0, rr - R)
                    let dR = expf(-h / Hr), dM = expf(-h / Hm)
                    let dO = max(0, 1 - abs(h - 25000) / 15000)
                    odR += dR * ds * 0.5; odM += dM * ds * 0.5; odO += dO * ds * 0.5
                    let tv = litExp3(-(betaR * odR + LitV3(repeating: betaM * 1.1) * odM + betaO * odO))
                    odR += dR * ds * 0.5; odM += dM * ds * 0.5; odO += dO * ds * 0.5
                    let muS = litDot3(P, sun) / rr
                    let ts = self.transmittance(r: rr, mu: muS)
                    sumR += tv * ts * dR * ds
                    sumM += tv * ts * dM * ds
                    // Light scattered more than once arrives from everywhere: softened in sun height so the
                    // zenith keeps its blue when the sun has gone.
                    let tsSoft = self.transmittance(r: rr, mu: muS * 0.6 + 0.25)
                    sumMS += tv * tsSoft * (dR * 0.9 + dM * 0.2) * ds
                }
                var L = base * (betaR * sumR * pr + LitV3(repeating: betaM) * sumM * pm)
                L += base * betaR * sumMS * (0.35 * ms / (4 * Float.pi)) * max(0.02, litSat(sun.y * 6 + 0.35))
                sl[ie * nSA + ia] = L
            }
        }
        for i in 0..<nSH {
            let u = (Float(i) + 0.5) / Float(nSH)
            let alt = u * u * 40000
            let rr = R + alt
            sh[i] = transmittance(r: rr, mu: sunDir.y)
        }
    }

    @inline(__always) static func vToElev(_ v: Float) -> Float {
        // v 0…1 → elevation -0.15…π/2, dense at the horizon.
        let c: Float = 0.25 // v at elevation 0 (below it: below the horizon)
        if v < c {
            let t = (c - v) / c
            return -0.15 * t * t
        }
        let t = (v - c) / (1 - c)
        return t * t * (Float.pi / 2)
    }
    @inline(__always) static func elevToV(_ e: Float) -> Float {
        let c: Float = 0.25
        if e < 0 { return c - (min(0.15, -e) / 0.15).squareRoot() * c }
        return c + min(1, (e / (Float.pi / 2))).squareRoot() * (1 - c)
    }

    /// Fraction of light surviving from radius r towards a direction of cosine mu.
    @inline(__always) func transmittance(r: Float, mu: Float) -> LitV3 {
        let um = litSat(muToU(max(-1, min(1, mu)))) * Float(nTM) - 0.5
        let ur = hToU(r - R) * Float(nTR) - 0.5
        let fm = min(Float(nTM - 2), max(0, um.rounded(.down))), fr = min(Float(nTR - 2), max(0, ur.rounded(.down)))
        let am = litSat(um - fm), ar = litSat(ur - fr)
        let i = Int(fm) * nTR + Int(fr)
        let a = litLerp(tl[i], tl[i + 1], ar), b = litLerp(tl[i + nTR], tl[i + nTR + 1], ar)
        return litLerp(a, b, am)
    }

    /// What the sun's light looks like arriving at altitude y (scene metres). 
    @inline(__always) func sunColor(y: Float) -> LitV3 {
        let alt = max(0, altBase + y)
        let u = (alt / 40000).squareRoot() * Float(nSH) - 0.5
        let f = min(Float(nSH - 2), max(0, u.rounded(.down)))
        let a = litSat(u - f)
        let i = Int(f)
        return litLerp(sh[i], sh[i + 1], a) * sunE
    }

    /// Radiance of the clear sky in a direction, from the camera's height.
    @inline(__always) func sky(_ d: LitV3) -> LitV3 {
        let e = asin(max(-1, min(1, d.y)))
        let sunAz = atan2f(sunDir.x, sunDir.z)
        var az = atan2f(d.x, d.z) - sunAz
        if az < 0 { az = -az }
        if az > Float.pi { az = 2 * Float.pi - az }
        if az > Float.pi { az = az - 2 * Float.pi; az = -az }
        let va = az / Float.pi * Float(nSA) - 0.5
        let ve = LitAtmosphere.elevToV(e) * Float(nSE) - 0.5
        let fa = min(Float(nSA - 2), max(0, va.rounded(.down))), fe = min(Float(nSE - 2), max(0, ve.rounded(.down)))
        let aa = litSat(va - fa), ae = litSat(ve - fe)
        let i = Int(fe) * nSA + Int(fa)
        let a = litLerp(sl[i], sl[i + 1], aa), b = litLerp(sl[i + nSA], sl[i + nSA + 1], aa)
        return litLerp(a, b, ae) * skyGain
    }

    /// Aerial perspective between the camera (`ro`) and a point `t` along `rd`: what survives and what gets added.
    @inline(__always) func aerial(ro: LitV3, rd: LitV3, t: Float, steps: Int = 8) -> (trans: LitV3, add: LitV3) {
        let cosT = litDot3(rd, sunDir)
        let gg = g * g
        let pr = 3 / (16 * Float.pi) * (1 + cosT * cosT)
        let den = 1 + gg - 2 * g * cosT
        let pm = 3 / (8 * Float.pi) * ((1 - gg) * (1 + cosT * cosT)) / ((2 + gg) * den * den.squareRoot())
        var odR: Float = 0, odM: Float = 0
        var sum = LitV3.zero
        let bm = LitV3(repeating: betaM)
        let tp = betaR * pr + bm * pm
        // Rayleigh multiple-scattering: a bit of blue from everywhere.
        let amb = betaR * (0.06 * msGain) + bm * (0.03 * msGain)
        var s = 0
        let fs = Float(steps)
        while s < steps {
            let t0 = Float(s) / fs, t1 = Float(s + 1) / fs
            let a0 = t0 * t0 * t, a1 = t1 * t1 * t
            let m = (a0 + a1) * 0.5, ds = a1 - a0
            let y = ro.y + rd.y * m
            let alt = max(0, altBase + y)
            let dR = expf(-alt / Hr), dM = expf(-alt / Hm)
            odR += dR * ds * 0.5; odM += dM * ds * 0.5
            let tv = litExp3(-(betaR * odR + bm * (1.1 * odM)))
            odR += dR * ds * 0.5; odM += dM * ds * 0.5
            let sc = sunColor(y: y)
            // Separately weight Rayleigh and Mie by their own densities.
            let scat = (betaR * (pr * dR) + bm * (pm * dM))
            _ = tp
            let ms2 = amb * (dR + dM) * sunE * max(0.03, litSat(sunDir.y * 5 + 0.3))
            sum += tv * (sc * scat + ms2) * ds
            s += 1
        }
        let trans = litExp3(-(betaR * odR + bm * (1.1 * odM)))
        return (trans, sum * airGain)
    }
}

// MARK: The filmic curve (ACES fit by Stephen Hill)

@inline(__always) nonisolated func litAcesFilm(_ c: LitV3) -> LitV3 {
    let x = LitV3(0.59719 * c.x + 0.35458 * c.y + 0.04823 * c.z,
               0.07600 * c.x + 0.90834 * c.y + 0.01566 * c.z,
               0.02840 * c.x + 0.13383 * c.y + 0.83777 * c.z)
    let a = x * (x + LitV3(repeating: 0.0245786)) - LitV3(repeating: 0.000090537)
    let b = x * (x * 0.983729 + LitV3(repeating: 0.4329510)) + LitV3(repeating: 0.238081)
    let y = a / b
    return LitV3(1.60475 * y.x - 0.53108 * y.y - 0.07367 * y.z,
              -0.10208 * y.x + 1.10813 * y.y - 0.00605 * y.z,
              -0.00327 * y.x - 0.07276 * y.y + 1.07602 * y.z)
}

@inline(__always) nonisolated func litToSRGB(_ x: Float) -> Float {
    let v = litSat(x)
    return v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
}

// MARK: Terrain: real fluvial erosion on a grid (stream-power law, Braun & Willett's O(n) implicit solve)

nonisolated struct LitPeak: Sendable {
    var x: Float, z: Float, h: Float, r: Float
    var power: Float = 1.3
}

nonisolated struct LitTerrainSpec {
    var x0: Float, z0: Float, size: Float
    var seed: UInt32
    /// Design shape, 0…1-ish, at (x, z). LitErosion carves into it and uplifts in proportion to it.
    var shape: @Sendable (Float, Float) -> Float
    /// Cells that are a fixed base level (a lake, the sea, the domain's edge is always fixed): the rivers end here.
    var isBase: @Sendable (Float, Float) -> Bool
    /// Vertical scale at the end: the highest point of the domain becomes this.
    var top: Float
    var talus: Float = 1.1
    /// Base erosion strength per iteration per level, finest last.
    var kdt: [Float] = [0.08, 0.07, 0.06, 0.05]
    var iters: [Int] = [36, 18, 8, 4]
    var upliftPerIter: Float = 0.008
    /// How rough, in world metres, the fine detail added on the final upsampling is.
    var detail: Float = 9
    var wander: Float = 0.8
    var seedNoise: Float = 0.55
    /// How steep the rock can stand here, as a multiple of `talus`: competent rock makes cliffs, shale makes shoulders.
    var hardness: (@Sendable (Float, Float) -> Float)? = nil
    /// Faces looking this way (unit vector in x, z) stand steeper by `scarpGain`, faces looking away lie back: dip slope and scarp.
    var scarpDir: LitV2 = .zero
    var scarpGain: Float = 0
    /// Hard and soft beds by height (tilted): cliff bands and ledges. Amplitude 0 = none; spacing in metres.
    var bedAmp: Float = 0
    var bedSpacing: Float = 210
    var bedTilt: LitV2 = LitV2(0.10, -0.05)
}

nonisolated struct LitHeightLayer: @unchecked Sendable {
    let n: Int
    let x0: Float, z0: Float, size: Float, cell: Float, icell: Float
    let h: UnsafeMutablePointer<Float>
    /// Max-mip pyramid over the grid's cells (level 0: the four corners of each cell).
    let mip: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let mipN: UnsafeMutablePointer<Int>
    let mipCell: UnsafeMutablePointer<Float>
    var levels = 0
    let shadow: UnsafeMutablePointer<Float>
    let aoN: Int
    let ao: UnsafeMutablePointer<Float>
    /// Square root of upstream area over cell size, smoothed: how much water passes here. Same grid as `ao`.
    let flow: UnsafeMutablePointer<Float>
    var forest: UnsafeMutablePointer<Float>?
    /// Signed snow depth on the main grid, metres: above 0 snow lies here, below 0 how far short of it.
    var snow: UnsafeMutablePointer<Float>? = nil
    var forestTop: Float = 0
    /// Ribs against gullies, about -1…1, on the AO grid: rock colour follows the shape of the ground.
    var curve: UnsafeMutablePointer<Float>? = nil
    /// Depth of loose scree on the AO grid, metres.
    var scree: UnsafeMutablePointer<Float>? = nil

    init(n: Int, x0: Float, z0: Float, size: Float) {
        self.n = n; self.x0 = x0; self.z0 = z0; self.size = size
        cell = size / Float(n - 1); icell = Float(n - 1) / size
        h = .allocate(capacity: n * n)
        let m = n <= 257 ? n : (n - 1) / 2 + 1
        aoN = m
        shadow = .allocate(capacity: n * n)
        ao = .allocate(capacity: m * m)
        flow = .allocate(capacity: m * m)
        mip = .allocate(capacity: 16)
        mipN = .allocate(capacity: 16)
        mipCell = .allocate(capacity: 16)
    }

    func free() {
        h.deallocate(); shadow.deallocate(); ao.deallocate(); flow.deallocate(); forest?.deallocate()
        curve?.deallocate(); scree?.deallocate(); snow?.deallocate()
        for i in 0..<levels { mip[i].deallocate() }
        mip.deallocate(); mipN.deallocate(); mipCell.deallocate()
    }

    @inline(__always) func hAt(_ x: Float, _ z: Float) -> Float {
        let fx = max(0, min(Float(n - 1) - 0.001, (x - x0) * icell)), fz = max(0, min(Float(n - 1) - 0.001, (z - z0) * icell))
        let ix = Int(fx), iz = Int(fz)
        let ax = fx - Float(ix), az = fz - Float(iz)
        let i = iz * n + ix
        let a = h[i] + (h[i + 1] - h[i]) * ax
        let b = h[i + n] + (h[i + n + 1] - h[i + n]) * ax
        return a + (b - a) * az
    }

    @inline(__always) func inside(_ x: Float, _ z: Float) -> Bool {
        x >= x0 && z >= z0 && x <= x0 + size && z <= z0 + size
    }

    /// Bilinear look-up on a square field of `m` points per side over this layer's domain.
    @inline(__always) func field(_ f: UnsafeMutablePointer<Float>, _ m: Int, _ x: Float, _ z: Float) -> Float {
        let s = Float(m - 1) / size
        let fx = max(0, min(Float(m - 1) - 0.001, (x - x0) * s)), fz = max(0, min(Float(m - 1) - 0.001, (z - z0) * s))
        let ix = Int(fx), iz = Int(fz)
        let ax = fx - Float(ix), az = fz - Float(iz)
        let i = iz * m + ix
        let a = f[i] + (f[i + 1] - f[i]) * ax
        let b = f[i + m] + (f[i + m + 1] - f[i + m]) * ax
        return a + (b - a) * az
    }

    mutating func buildMips(extra: Float = 0) {
        for i in 0..<levels { mip[i].deallocate() }
        levels = 0
        let nc = n - 1
        let l0 = UnsafeMutablePointer<Float>.allocate(capacity: nc * nc)
        let n = self.n, h = self.h
        let fTop = forestTop, fm = forest, an = aoN, ratio = (n - 1) / (aoN - 1)
        litParallelFor(nc, chunk: 16) { z in
            for x in 0..<nc {
                let i = z * n + x
                var m = max(h[i], max(h[i + 1], max(h[i + n], h[i + n + 1])))
                if let fm {
                    // Canopy above the ground wherever a forest may stand.
                    let ai = (z / ratio) * an + x / ratio
                    let f = max(fm[ai], max(fm[ai + 1], max(fm[ai + an], fm[ai + an + 1])))
                    if f > 0.001 { m += fTop }
                }
                l0[z * nc + x] = m + extra
            }
        }
        mip[0] = l0; mipN[0] = nc; mipCell[0] = cell; levels = 1
        var cur = l0, cn = nc, cs = cell
        while cn > 4 {
            let nn = (cn + 1) / 2
            let nx = UnsafeMutablePointer<Float>.allocate(capacity: nn * nn)
            let prev = cur, pn = cn
            litParallelFor(nn, chunk: 16) { z in
                for x in 0..<nn {
                    var m = -Float.infinity
                    for dz in 0..<2 {
                        for dx in 0..<2 {
                            let zz = z * 2 + dz, xx = x * 2 + dx
                            if zz < pn && xx < pn { m = max(m, prev[zz * pn + xx]) }
                        }
                    }
                    nx[z * nn + x] = m
                }
            }
            cs *= 2
            mip[levels] = nx; mipN[levels] = nn; mipCell[levels] = cs; levels += 1
            cur = nx; cn = nn
        }
    }
}

nonisolated enum LitErosion {
    /// Priority-flood: raises every depression to its spill point + epsilon, so every cell drains.
    static func fill(_ h: UnsafeMutablePointer<Float>, _ n: Int, _ base: UnsafePointer<UInt8>) {
        var heap: [(Float, Int32)] = []
        heap.reserveCapacity(n * 4)
        func push(_ k: Float, _ v: Int32) {
            heap.append((k, v))
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if heap[p].0 <= heap[i].0 { break }
                heap.swapAt(p, i)
                i = p
            }
        }
        func pop() -> (Float, Int32) {
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                let c = heap.count
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < c && heap[l].0 < heap[m].0 { m = l }
                    if r < c && heap[r].0 < heap[m].0 { m = r }
                    if m == i { break }
                    heap.swapAt(m, i)
                    i = m
                }
            }
            return top
        }
        let seen = UnsafeMutablePointer<UInt8>.allocate(capacity: n * n)
        defer { seen.deallocate() }
        seen.initialize(repeating: 0, count: n * n)
        for z in 0..<n {
            for x in 0..<n where x == 0 || z == 0 || x == n - 1 || z == n - 1 || base[z * n + x] != 0 {
                seen[z * n + x] = 1
                push(h[z * n + x], Int32(z * n + x))
            }
        }
        let eps: Float = 0.01
        while !heap.isEmpty {
            let (k, v) = pop()
            let i = Int(v)
            let x = i % n, z = i / n
            for dz in -1...1 {
                for dx in -1...1 where dx != 0 || dz != 0 {
                    let xx = x + dx, zz = z + dz
                    if xx < 0 || zz < 0 || xx >= n || zz >= n { continue }
                    let j = zz * n + xx
                    if seen[j] != 0 { continue }
                    seen[j] = 1
                    if h[j] <= k + eps { h[j] = k + eps }
                    push(h[j], Int32(j))
                }
            }
        }
    }

    /// `iters` steps of stream-power erosion with uplift and a talus limit. Returns the drainage area (m²) of the last step.
    static func run(h: UnsafeMutablePointer<Float>, uplift: UnsafePointer<Float>, base: UnsafePointer<UInt8>, n: Int, cell: Float,
                    iters: Int, kdt: Float, talus: Float, area outArea: UnsafeMutablePointer<Float>?, wander: Float = 0.8, seed: UInt32 = 1,
                    hard: UnsafePointer<Float>? = nil, tilt: UnsafePointer<Float>? = nil, scarp: LitV2 = .zero, scarpGain: Float = 0,
                    bedTable: UnsafePointer<Float>? = nil, bedScale: Float = 0, bedN: Int = 0) {
        let total = n * n
        let rcv = UnsafeMutablePointer<Int32>.allocate(capacity: total)
        let order = UnsafeMutablePointer<Int32>.allocate(capacity: total)
        let ndon = UnsafeMutablePointer<Int32>.allocate(capacity: total)
        let area = UnsafeMutablePointer<Float>.allocate(capacity: total)
        let dist = UnsafeMutablePointer<Float>.allocate(capacity: total)
        defer { rcv.deallocate(); order.deallocate(); ndon.deallocate(); area.deallocate(); dist.deallocate() }
        let dDiag = cell * 1.41421356, cellArea = cell * cell
        for iter in 0..<iters {
            // Steepest descent, with a random lean per neighbour: flow paths stop lining up with the grid.
            let iterSeed = UInt32(truncatingIfNeeded: iter) &* 0x9E37_79B1 &+ seed
            litParallelFor(n, chunk: 16) { z in
                for x in 0..<n {
                    let i = z * n + x
                    if x == 0 || z == 0 || x == n - 1 || z == n - 1 || base[i] != 0 {
                        rcv[i] = Int32(i); dist[i] = cell
                        continue
                    }
                    let hi = h[i]
                    var best: Float = 0, r = i, d = cell
                    for dz in -1...1 {
                        for dx in -1...1 where dx != 0 || dz != 0 {
                            let j = i + dz * n + dx
                            let dd = (dx != 0 && dz != 0) ? dDiag : cell
                            var s = (hi - h[j]) / dd
                            if s > 0 {
                                s *= 1 + wander * (Float(litHash32(Int32(truncatingIfNeeded: i), Int32(truncatingIfNeeded: j), iterSeed) & 0xFFFF) / 65536 - 0.5)
                            }
                            if s > best { best = s; r = j; d = dd }
                        }
                    }
                    rcv[i] = Int32(r); dist[i] = d
                }
            }
            // Upstream → downstream order (Kahn), accumulating drainage area.
            memset(ndon, 0, total * MemoryLayout<Int32>.size)
            for i in 0..<total {
                let r = Int(rcv[i])
                if r != i { ndon[r] += 1 }
                area[i] = cellArea
            }
            var head = 0, tail = 0
            for i in 0..<total where ndon[i] == 0 { order[tail] = Int32(i); tail += 1 }
            while head < tail {
                let i = Int(order[head]); head += 1
                let r = Int(rcv[i])
                if r != i {
                    area[r] += area[i]
                    ndon[r] -= 1
                    if ndon[r] == 0 { order[tail] = Int32(r); tail += 1 }
                }
            }
            // Downstream → upstream implicit solve with uplift and a talus limit.
            var k = tail - 1
            while k >= 0 {
                let i = Int(order[k]); k -= 1
                let r = Int(rcv[i])
                if r == i {
                    if !(base[i] != 0) && i % n != 0 && i % n != n - 1 && i >= n && i < total - n {
                        // A pit: fill it up to its lowest neighbour, it will drain next time.
                        var m = Float.infinity
                        for dz in -1...1 { for dx in -1...1 where dx != 0 || dz != 0 { m = min(m, h[i + dz * n + dx]) } }
                        if m > h[i] { h[i] = m + 0.01 }
                    }
                    continue
                }
                let d = dist[i]
                let f = kdt * area[i].squareRoot() / d
                var v = (h[i] + uplift[i] + f * h[r]) / (1 + f)
                var t = talus
                if let hard { t *= hard[i] }
                if scarpGain != 0 {
                    // The way this cell faces: towards its receiver.
                    let rx = r % n, ix = i % n
                    let dx = Float(rx - ix), dz = Float((r - rx - (i - ix)) / n)
                    let inv = (dx != 0 && dz != 0) ? Float(0.7071) : 1
                    t *= 1 + scarpGain * (dx * scarp.x + dz * scarp.y) * inv
                }
                if let bedTable, let tilt {
                    let q = (v + tilt[i]) * bedScale
                    if q > 0 { t *= bedTable[Int(q) % bedN] }
                }
                let cap = h[r] + t * d
                if v > cap { v = cap }
                h[i] = v
            }
        }
        if let outArea { memcpy(outArea, area, total * MemoryLayout<Float>.size) }
    }

    /// Catmull-Rom doubling: n → 2n-1.
    static func upsample(_ src: UnsafePointer<Float>, _ n: Int, into dst: UnsafeMutablePointer<Float>) {
        let m = 2 * n - 1
        @inline(__always) func cr(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
            (-a + 9 * b + 9 * c - d) / 16
        }
        // Rows at even z.
        litParallelFor(n, chunk: 16) { z in
            let zd = z * 2
            for x in 0..<n { dst[zd * m + x * 2] = src[z * n + x] }
            for x in 0..<(n - 1) {
                let a = src[z * n + max(0, x - 1)], b = src[z * n + x], c = src[z * n + x + 1], d = src[z * n + min(n - 1, x + 2)]
                dst[zd * m + x * 2 + 1] = cr(a, b, c, d)
            }
        }
        // Rows at odd z.
        litParallelFor(n - 1, chunk: 16) { z in
            let zd = z * 2 + 1
            for x in 0..<m {
                let a = dst[max(0, zd - 3) * m + x], b = dst[(zd - 1) * m + x], c = dst[(zd + 1) * m + x], d = dst[min(m - 1, zd + 3) * m + x]
                dst[zd * m + x] = cr(a, b, c, d)
            }
        }
    }

    /// The whole pyramid: design shape at 129², eroded and doubled until `maxN`, then a last doubling with fine detail.
    static func build(_ spec: LitTerrainSpec, maxN: Int, erodeN: Int) -> LitHeightLayer {
        var n = 129
        var h = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        var u = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        var b = UnsafeMutablePointer<UInt8>.allocate(capacity: n * n)
        var area = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        let top = spec.top
        // One period of the bedding: a hard bed stands steep, the soft bed on top of it lies back into a ledge.
        let bedN = 256
        let bedScale = Float(bedN) / max(1, spec.bedSpacing)
        var bedTable = [Float](repeating: 1, count: bedN)
        for i in 0..<bedN {
            let u = Float(i) / Float(bedN)
            let cliff = litSstep(0.0, 0.08, u) * (1 - litSstep(0.48, 0.58, u))
            bedTable[i] = 1 + spec.bedAmp * (cliff * 2 - 0.85)
        }
        func initBase() {
            let cell = spec.size / Float(n - 1)
            litParallelFor(n, chunk: 8) { z in
                for x in 0..<n {
                    let wx = spec.x0 + Float(x) * cell, wz = spec.z0 + Float(z) * cell
                    b[z * n + x] = spec.isBase(wx, wz) ? 1 : 0
                }
            }
        }
        do {
            let cell = spec.size / Float(n - 1)
            let nn = n
            let hh = h, uu = u
            litParallelFor(n, chunk: 8) { z in
                for x in 0..<nn {
                    let wx = spec.x0 + Float(x) * cell, wz = spec.z0 + Float(z) * cell
                    let s = spec.shape(wx, wz)
                    hh[z * nn + x] = s * top
                    uu[z * nn + x] = max(0, s) * top * spec.upliftPerIter
                }
            }
        }
        initBase()
        var level = 0
        while true {
            let cell = spec.size / Float(n - 1)
            let levelSeed = spec.seed &+ UInt32(level) &* 911
            if level > 0 {
                // Fresh small-scale irregularity gives the new, finer rivers somewhere to start.
                let hh = h, nn = n
                let amp = cell * spec.seedNoise
                litParallelFor(n, chunk: 16) { z in
                    for x in 0..<nn {
                        let wx = Float(x), wz = Float(z)
                        let nv = litFbm(wx * 0.31, wz * 0.31, 3, levelSeed)
                        hh[z * nn + x] += nv * amp * litSat(hh[z * nn + x] / 80)
                    }
                }
            }
            if n <= 513 { fill(h, n, b) }
            let it = level < spec.iters.count ? spec.iters[level] : 1
            let kd = level < spec.kdt.count ? spec.kdt[level] : 0.1
            // Rock strength and bedding on this level's grid.
            var hardMap: UnsafeMutablePointer<Float>? = nil
            var tiltMap: UnsafeMutablePointer<Float>? = nil
            if let hf = spec.hardness {
                let hm = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
                let nn = n
                litParallelFor(n, chunk: 16) { z in
                    for x in 0..<nn { hm[z * nn + x] = hf(spec.x0 + Float(x) * cell, spec.z0 + Float(z) * cell) }
                }
                hardMap = hm
            }
            if spec.bedAmp != 0 {
                let tm = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
                let nn = n, seed2 = spec.seed &+ 777, tl = spec.bedTilt, x0 = spec.x0, z0 = spec.z0
                litParallelFor(n, chunk: 16) { z in
                    for x in 0..<nn {
                        let wx = x0 + Float(x) * cell, wz = z0 + Float(z) * cell
                        tm[z * nn + x] = wx * tl.x + wz * tl.y + 70 * litFbm(wx / 1500, wz / 1500, 2, seed2) + 2000
                    }
                }
                tiltMap = tm
            }
            // Uplift per iteration falls with level, the levels have fewer iterations of a shorter dt.
            bedTable.withUnsafeBufferPointer { bt in
                run(h: h, uplift: u, base: b, n: n, cell: cell, iters: it, kdt: kd, talus: spec.talus, area: area, wander: spec.wander, seed: levelSeed,
                    hard: hardMap, tilt: tiltMap, scarp: spec.scarpDir, scarpGain: spec.scarpGain, bedTable: bt.baseAddress, bedScale: bedScale, bedN: bedN)
            }
            hardMap?.deallocate(); tiltMap?.deallocate()
            if n >= erodeN { break }
            let m = 2 * n - 1
            let h2 = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
            let u2 = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
            let a2 = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
            upsample(h, n, into: h2)
            upsample(u, n, into: u2)
            upsample(area, n, into: a2)
            litParallelFor(m, chunk: 32) { z in for x in 0..<m { u2[z * m + x] *= 0.5 } }
            h.deallocate(); u.deallocate(); area.deallocate(); b.deallocate()
            h = h2; u = u2; area = a2
            n = m
            b = UnsafeMutablePointer<UInt8>.allocate(capacity: n * n)
            initBase()
            level += 1
        }
        // Rescale so the top of the domain is exactly `top`.
        var mx: Float = 1
        for i in 0..<(n * n) { mx = max(mx, h[i]) }
        let sc = top / mx
        let nn0 = n
        let hh0 = h
        litParallelFor(n, chunk: 32) { z in for x in 0..<nn0 { hh0[z * nn0 + x] *= sc } }

        // To the final grid: smooth doubling, with detail that grows on steep high ground.
        var finalH = h, fn = n
        var aA = area, aN = n
        while fn < maxN {
            let m = 2 * fn - 1
            let h2 = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
            upsample(finalH, fn, into: h2)
            finalH.deallocate()
            finalH = h2
            fn = m
        }
        // Layer object.
        let layer = LitHeightLayer(n: fn, x0: spec.x0, z0: spec.z0, size: spec.size)
        memcpy(layer.h, finalH, fn * fn * MemoryLayout<Float>.size)
        finalH.deallocate()
        // Flow onto the AO-sized grid.
        while aN < layer.aoN {
            let m = 2 * aN - 1
            let a2 = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
            upsample(aA, aN, into: a2)
            aA.deallocate(); aA = a2; aN = m
        }
        do {
            let an = aN, step = max(1, (aN - 1) / (layer.aoN - 1)), aoN = layer.aoN
            let fcell = layer.size / Float(aoN - 1)
            let flow = layer.flow, src = aA
            litParallelFor(aoN, chunk: 16) { z in
                for x in 0..<aoN {
                    flow[z * aoN + x] = max(0, src[z * step * an + x * step]).squareRoot() / fcell
                }
            }
        }
        aA.deallocate(); u.deallocate(); b.deallocate()
        return layer
    }
}

nonisolated extension LitHeightLayer {
    /// Gullies and ribs that run down the fall line and branch: for each octave, stripes across the local slope,
    /// blended from a jittered lattice so they never line up, and the stripes' own slope bends the next octave's.
    func addGullies(seed: UInt32, lambda: Float, octaves: Int, depth: Float, gain: Float = 0.55, minHeight: Float = 25, visible: @Sendable (Float, Float) -> Bool) {
        let n = self.n, h = self.h, c = cell, x0 = self.x0, z0 = self.z0
        let benchK: Float = 1
        let coh: Float = 2.8
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        defer { tmp.deallocate() }
        let tabN = 1024
        let cosT = UnsafeMutablePointer<Float>.allocate(capacity: tabN)
        defer { cosT.deallocate() }
        for i in 0..<tabN { cosT[i] = cosf(Float(i) / Float(tabN) * 2 * .pi) }
        let toIdx = Float(tabN)
        let e = max(c, min(c * 3, lambda * 0.1))
        let ie = Int((e / c).rounded())
        litParallelFor(n, chunk: 8) { z in
            for x in 0..<n {
                let i = z * n + x
                let y = h[i]
                if x < ie || z < ie || x >= n - ie || z >= n - ie || y < minHeight { tmp[i] = y; continue }
                let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                if !visible(wx, wz) { tmp[i] = y; continue }
                let d = Float(2 * ie) * c
                var gx = (h[i + ie] - h[i - ie]) / d, gz = (h[i + ie * n] - h[i - ie * n]) / d
                var off: Float = 0
                var lam = lambda, amp = lambda * depth
                var o: UInt32 = 0
                // Some faces are rougher than others: broad snowfields and smooth slabs next to broken rock.
                let rough = 0.3 + 0.7 * litSstep(-0.25, 0.3, litFbm(wx / 1300, wz / 1300, 2, seed &+ 500))
                let hFade = litSat((y - minHeight) / 150) * rough
                while o < UInt32(octaves) {
                    let sl = (gx * gx + gz * gz).squareRoot()
                    if sl < 0.03 { break }
                    let sideX = -gz / sl, sideZ = gx / sl
                    // Groups of gullies, then a smooth buttress: the ribs must not run evenly across a whole face.
                    let group = litSstep(-0.26, 0.2, litGnoise(wx / (lam * 3.7), wz / (lam * 3.7), seed &+ 600 &+ o))
                    let mask = litSstep(0.10, 0.5, sl) * hFade * (0.16 + 0.84 * group)
                    // Lattice much wider than the stripes: each gully stays one line over several wavelengths instead of breaking into scales.
                    let cell2 = lam * coh
                    let px = wx / cell2, pz = wz / cell2
                    let fx = px.rounded(.down), fz = pz.rounded(.down)
                    let ix = Int32(fx), iz = Int32(fz)
                    let dx = px - fx, dz = pz - fz
                    var C: Float = 0, S: Float = 0
                    var jj: Int32 = -1
                    while jj <= 1 {
                        var ii: Int32 = -1
                        while ii <= 1 {
                            let hh = litHash32(ix + ii, iz + jj, seed &+ o &* 97)
                            let ox = Float(ii) + Float(hh & 0xFFFF) / 65536 * 0.5
                            let oz = Float(jj) + Float(hh >> 16) / 65536 * 0.5
                            let vx = dx - ox, vz = dz - oz
                            let d2 = vx * vx + vz * vz
                            var w = 1 - d2 / 2.25
                            if w > 0 {
                                w = w * w * w
                                // Each lattice point has its own spacing, so neighbouring gullies are never evenly apart.
                                let wave = (vx * sideX + vz * sideZ) * coh * (0.62 + 0.86 * Float((hh >> 8) & 0xFF) / 255)
                                var f = wave - wave.rounded(.down)
                                f = f * toIdx
                                let idx = Int(f) & (tabN - 1)
                                C += w * cosT[idx]
                                S += w * cosT[(idx + 768) & (tabN - 1)]
                            }
                            ii += 1
                        }
                        jj += 1
                    }
                    let mag = (C * C + S * S).squareRoot()
                    if mag > 1e-4 { C /= mag; S /= mag }
                    let k = amp * mask
                    // 0 at a gully floor, 1 on a rib crest.
                    let prof = C * 0.5 + 0.5
                    off += k * (prof * prof * 0.6 + prof * 0.4 - 0.5)
                    let dOff = -S * 0.5 * k * 2 * Float.pi / lam
                    gx += sideX * dOff * 0.7
                    gz += sideZ * dOff * 0.7
                    lam *= 0.5
                    amp *= gain
                    o += 1
                }
                // Level strata cut benches across the fall line.
                let tilt = wx * 0.17 - wz * 0.09 + 30 * litFbm(wx / 700, wz / 700, 2, seed &+ 501)
                let q = (y + tilt) / 74
                let tri = abs(q - q.rounded(.down) - 0.5) * 2
                let q2 = (y + tilt) / 23
                let tri2 = abs(q2 - q2.rounded(.down) - 0.5) * 2
                let sl0 = (gx * gx + gz * gz).squareRoot()
                let bench = litSstep(0.35, 0.8, sl0) * hFade * benchK
                off += bench * (9 * (tri * tri - 0.4) + 2.5 * (tri2 - 0.5))
                tmp[i] = y + off
            }
        }
        // Spike limiter: nothing stands more than a whisker above its neighbours (hair-thin needles alias badly).
        litParallelFor(n, chunk: 16) { z in
            for x in 0..<n {
                let i = z * n + x
                if x < 1 || z < 1 || x >= n - 1 || z >= n - 1 { h[i] = tmp[i]; continue }
                let a = (tmp[i - 1] + tmp[i + 1] + tmp[i - n] + tmp[i + n]) * 0.25
                let lim = a + c * 0.75
                h[i] = tmp[i] > lim ? lim : tmp[i]
            }
        }
    }

    /// Sun shadow per grid point, `shadow` 0 (dark) … 1 (lit), on the main grid: one sweep from the sun's side, carrying the top of the shadow
    /// and how far it has travelled from what threw it, so a shadow is hard near its caster and softer far away.
    func buildShadow(sun: LitV3, softness: Float = 18) {
        let m = n
        let c = cell
        let hLen = (sun.x * sun.x + sun.z * sun.z).squareRoot()
        let dirx = sun.x / max(1e-4, hLen), dirz = sun.z / max(1e-4, hLen)
        let tanS = sun.y / max(1e-4, hLen)
        let alongX = abs(dirx) >= abs(dirz)
        // Lines run across the sweep; each line reads the one nearer the sun.
        let main = alongX ? dirx : dirz, cross = alongX ? dirz : dirx
        let slopeC = cross / abs(main)
        let stepW = c * (1 + slopeC * slopeC).squareRoot()
        let drop = tanS * stepW
        let g = h
        let topA = UnsafeMutablePointer<Float>.allocate(capacity: m), topB = UnsafeMutablePointer<Float>.allocate(capacity: m)
        let runA = UnsafeMutablePointer<Float>.allocate(capacity: m), runB = UnsafeMutablePointer<Float>.allocate(capacity: m)
        defer { topA.deallocate(); topB.deallocate(); runA.deallocate(); runB.deallocate() }
        let s = shadow
        // Line k = 0 faces the sun.
        for k in 0..<m {
            let line = main > 0 ? m - 1 - k : k
            let curTop = k % 2 == 0 ? topA : topB, curRun = k % 2 == 0 ? runA : runB
            let upTop = k % 2 == 0 ? topB : topA, upRun = k % 2 == 0 ? runB : runA
            for j in 0..<m {
                let i = alongX ? j * m + line : line * m + j
                let y = g[i]
                if k == 0 {
                    curTop[j] = y; curRun[j] = 0; s[i] = 1
                    continue
                }
                let q = max(0, min(Float(m - 1) - 0.001, Float(j) + slopeC))
                let qi = Int(q)
                let a = q - Float(qi)
                let t = upTop[qi] + (upTop[qi + 1] - upTop[qi]) * a - drop
                let r = upRun[qi] + (upRun[qi + 1] - upRun[qi]) * a + stepW
                if y >= t {
                    curTop[j] = y; curRun[j] = 0
                    s[i] = 1
                } else {
                    curTop[j] = t; curRun[j] = r
                    s[i] = litSat(0.5 + 0.5 * softness * (y + 1.5 - t) / r)
                }
            }
        }
    }

    /// How much of the sky a point sees, from its horizon in eight directions.
    func buildAO() {
        let m = aoN
        let a = ao
        let c = size / Float(m - 1)
        let x0 = self.x0, z0 = self.z0, sz = size
        let dirs: [(Float, Float)] = (0..<8).map { (cosf(Float($0) * .pi / 4 + 0.2), sinf(Float($0) * .pi / 4 + 0.2)) }
        dirs.withUnsafeBufferPointer { dp in
            litParallelFor(m, chunk: 8) { z in
                for x in 0..<m {
                    let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                    let y0 = self.hAt(wx, wz)
                    var vis: Float = 0
                    for k in 0..<8 {
                        let (dx, dz) = dp[k]
                        var tanH: Float = 0
                        var d = c
                        while d < sz * 0.3 {
                            let qx = wx + dx * d, qz = wz + dz * d
                            if !self.inside(qx, qz) { break }
                            tanH = max(tanH, (self.hAt(qx, qz) - y0) / d)
                            d += max(c, d * 0.45)
                        }
                        vis += 1 / (1 + tanH * tanH)
                    }
                    a[z * m + x] = vis / 8
                }
            }
        }
    }

    /// Hierarchical ray walk over the max-mip pyramid. `surf` is the real surface height at a point on the finest level.
    @inline(__always) func trace(ro: LitV3, rd: LitV3, tmin: Float, tmax: Float, surf: (Float, Float, Float) -> Float) -> Float {
        var t = tmin
        var end = tmax
        // Clip to the domain.
        let x1 = x0 + size, z1 = z0 + size
        if abs(rd.x) > 1e-6 {
            let a = (x0 - ro.x) / rd.x, b = (x1 - ro.x) / rd.x
            t = max(t, min(a, b)); end = min(end, max(a, b))
        } else if ro.x < x0 || ro.x > x1 { return .infinity }
        if abs(rd.z) > 1e-6 {
            let a = (z0 - ro.z) / rd.z, b = (z1 - ro.z) / rd.z
            t = max(t, min(a, b)); end = min(end, max(a, b))
        } else if ro.z < z0 || ro.z > z1 { return .infinity }
        if t >= end { return .infinity }
        var lvl = levels - 1
        let eps: Float = 0.01
        var guardN = 0
        while t < end && guardN < 2000 {
            guardN += 1
            let px = ro.x + rd.x * t, pz = ro.z + rd.z * t, py = ro.y + rd.y * t
            let cs = mipCell[lvl], nl = mipN[lvl]
            let ix = max(0, min(nl - 1, Int((px - x0) / cs))), iz = max(0, min(nl - 1, Int((pz - z0) / cs)))
            let top = mip[lvl][iz * nl + ix]
            let tx: Float = rd.x > 0 ? (x0 + Float(ix + 1) * cs - ro.x) / rd.x : (rd.x < 0 ? (x0 + Float(ix) * cs - ro.x) / rd.x : .infinity)
            let tz: Float = rd.z > 0 ? (z0 + Float(iz + 1) * cs - ro.z) / rd.z : (rd.z < 0 ? (z0 + Float(iz) * cs - ro.z) / rd.z : .infinity)
            let tExit = min(tx, tz) + eps
            let yExit = ro.y + rd.y * tExit
            if min(py, yExit) > top {
                t = max(tExit, t + eps)
                if lvl < levels - 1 { lvl += 1 }
                continue
            }
            if lvl > 0 { lvl -= 1; continue }
            // Finest cell: walk the real surface.
            let span = tExit - t
            let stepsN = Swift.max(2, Swift.min(14, Int(span / Swift.max(0.6, t * 0.0009))))
            var prevT = t
            var k = 1
            while k <= stepsN {
                let tt = t + span * Float(k) / Float(stepsN)
                let xx = ro.x + rd.x * tt, zz = ro.z + rd.z * tt, yy = ro.y + rd.y * tt
                if yy <= surf(xx, zz, tt) {
                    var a = prevT, b = tt
                    for _ in 0..<5 {
                        let m = (a + b) * 0.5
                        if ro.y + rd.y * m <= surf(ro.x + rd.x * m, ro.z + rd.z * m, m) { b = m } else { a = m }
                    }
                    return b
                }
                prevT = tt
                k += 1
            }
            t = max(tExit, t + eps)
        }
        return .infinity
    }
}


// MARK: Rock blocks and the snowpack

nonisolated extension LitHeightLayer {
    /// Jointed rock: the steep ground is broken into tilted facets that sit a little proud of or behind each other.
    func addBlocks(seed: UInt32, octaves: [(lambda: Float, amp: Float)], visible: @Sendable (Float, Float) -> Bool) {
        let n = self.n, cell = self.cell, x0 = self.x0, z0 = self.z0, hp = self.h
        let add = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        defer { add.deallocate() }
        litParallelFor(n, chunk: 8) { z in
            for x in 0..<n {
                let i = z * n + x
                add[i] = 0
                if x < 2 || z < 2 || x >= n - 2 || z >= n - 2 { continue }
                let wx = x0 + Float(x) * cell, wz = z0 + Float(z) * cell
                if !visible(wx, wz) { continue }
                let y = hp[i]
                if y < 60 { continue }
                let sx = (hp[i + 2] - hp[i - 2]) / (4 * cell), sz = (hp[i + 2 * n] - hp[i - 2 * n]) / (4 * cell)
                let slope = (sx * sx + sz * sz).squareRoot()
                let mask = litSstep(0.28, 0.8, slope) * litSstep(60, 260, y)
                if mask < 0.01 { continue }
                var sum: Float = 0
                var o = 0
                for oct in octaves {
                    let lam = oct.lambda
                    // Blocks are longer along the strike than up the dip.
                    let qx = (wx * 0.82 + wz * 0.24) / lam, qz = (-wx * 0.3 + wz * 0.95) / (lam * 0.72)
                    let fx = qx.rounded(.down), fz = qz.rounded(.down)
                    let ix = Int32(fx), iz = Int32(fz)
                    var f1: Float = 9, f2: Float = 9
                    var off: Float = 0
                    var dz: Int32 = -1
                    while dz <= 1 {
                        var dx: Int32 = -1
                        while dx <= 1 {
                            let hsh = litHash32(ix + dx, iz + dz, seed &+ UInt32(o) &* 77)
                            let cx = Float(ix + dx) + 0.15 + 0.7 * Float(hsh & 0x3FF) / 1024
                            let cz = Float(iz + dz) + 0.15 + 0.7 * Float((hsh >> 10) & 0x3FF) / 1024
                            let rx = qx - cx, rz = qz - cz
                            let d = rx * rx + rz * rz
                            if d < f1 {
                                f2 = f1; f1 = d
                                let h2 = hsh &* 0x9E37_79B1
                                let v = Float(h2 >> 24) / 128 - 1
                                let tx = Float((h2 >> 8) & 0xFF) / 128 - 1, tz = Float((h2 >> 16) & 0xFF) / 128 - 1
                                off = v + (tx * rx + tz * rz) * 2.2
                            } else if d < f2 {
                                f2 = d
                            }
                            dx += 1
                        }
                        dz += 1
                    }
                    let edge = litSstep(0, 0.10, f2.squareRoot() - f1.squareRoot())
                    sum += oct.amp * off * edge
                    o += 1
                }
                add[i] = sum * mask
            }
        }
        litParallelFor(n * n, chunk: 4096) { i in hp[i] += add[i] }
    }

}

nonisolated extension LitHeightLayer {
    /// Lifts the whole field: erosion works on the relief, the massif then stands on a high plateau.
    func raise(by v: Float) {
        let hp = self.h
        litParallelFor(n * n, chunk: 8192) { i in hp[i] += v }
    }
}

// MARK: Loose material sliding down: the same sweep for snow and for scree

nonisolated extension LitHeightLayer {
    /// Point `step` of a field on the main grid, gathered onto the AO grid (the two differ by 1 or 2).
    func gatherH() -> UnsafeMutablePointer<Float> {
        let m = aoN, n = self.n, step = (n - 1) / (m - 1), hp = self.h
        let g = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        litParallelFor(m, chunk: 16) { z in for x in 0..<m { g[z * m + x] = hp[z * step * n + x * step] } }
        return g
    }

    /// Separable two-pass box blur on an m×m field: nearly a gaussian.
    static func blurred(_ src: UnsafePointer<Float>, _ n: Int, radius r: Int) -> UnsafeMutablePointer<Float> {
        let a = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        let b = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        if r <= 0 { memcpy(b, src, n * n * MemoryLayout<Float>.stride); a.deallocate(); return b }
        let inv = 1 / Float(2 * r + 1)
        for pass in 0..<2 {
            let from: UnsafePointer<Float> = pass == 0 ? src : UnsafePointer(b)
            litParallelFor(n, chunk: 16) { z in
                var s: Float = 0
                let row = z * n
                for k in -r...r { s += from[row + min(n - 1, max(0, k))] }
                for x in 0..<n {
                    a[row + x] = s * inv
                    s += from[row + min(n - 1, x + r + 1)] - from[row + max(0, x - r)]
                }
            }
            litParallelFor(n, chunk: 16) { x in
                var s: Float = 0
                for k in -r...r { s += a[min(n - 1, max(0, k)) * n + x] }
                for z in 0..<n {
                    b[z * n + x] = s * inv
                    s += a[min(n - 1, z + r + 1) * n + x] - a[max(0, z - r) * n + x]
                }
            }
        }
        a.deallocate()
        return b
    }

    /// Sends mass down an m×m ground `g`, highest cell first. Every cell keeps what `hold` says it can and passes
    /// the rest on to its lower neighbours in proportion to their slope, so it gathers in gullies and piles up in fans.
    static func slide(_ g: UnsafePointer<Float>, _ m: Int, cell: Float,
                      source: UnsafePointer<Float>, hold: UnsafePointer<Float>) -> UnsafeMutablePointer<Float> {
        let total = m * m
        // Bucket sort by height, top first.
        var lo = Float.infinity, hi = -Float.infinity
        for i in 0..<total { lo = min(lo, g[i]); hi = max(hi, g[i]) }
        let B = 1 << 16
        let scale = Float(B - 1) / max(1, hi - lo)
        let count = UnsafeMutablePointer<Int32>.allocate(capacity: B + 1)
        count.initialize(repeating: 0, count: B + 1)
        let order = UnsafeMutablePointer<Int32>.allocate(capacity: total)
        defer { count.deallocate(); order.deallocate() }
        for i in 0..<total { count[B - 1 - Int((g[i] - lo) * scale)] += 1 }
        var acc: Int32 = 0
        for b in 0..<B { let c = count[b]; count[b] = acc; acc += c }
        for i in 0..<total {
            let b = B - 1 - Int((g[i] - lo) * scale)
            order[Int(count[b])] = Int32(i)
            count[b] += 1
        }
        let dep = UnsafeMutablePointer<Float>.allocate(capacity: total)
        let inflow = UnsafeMutablePointer<Float>.allocate(capacity: total)
        defer { inflow.deallocate() }
        inflow.initialize(repeating: 0, count: total)
        let dDiag = cell * 1.41421356
        for k in 0..<total {
            let i = Int(order[k])
            var M = inflow[i] + source[i]
            let d = min(M, hold[i])
            dep[i] = d
            M -= d
            if M <= 0 { continue }
            let x = i % m, z = i / m
            if x == 0 || z == 0 || x == m - 1 || z == m - 1 { continue }
            let gi = g[i]
            var sum: Float = 0
            var dz = -1
            while dz <= 1 {
                var dx = -1
                while dx <= 1 {
                    if dx != 0 || dz != 0 {
                        let s = gi - g[i + dz * m + dx]
                        if s > 0 {
                            let sl = s / ((dx != 0 && dz != 0) ? dDiag : cell)
                            sum += sl * sl
                        }
                    }
                    dx += 1
                }
                dz += 1
            }
            if sum <= 0 { dep[i] += M; continue }
            dz = -1
            while dz <= 1 {
                var dx = -1
                while dx <= 1 {
                    if dx != 0 || dz != 0 {
                        let j = i + dz * m + dx
                        let s = gi - g[j]
                        if s > 0 {
                            let sl = s / ((dx != 0 && dz != 0) ? dDiag : cell)
                            inflow[j] += M * (sl * sl) / sum
                        }
                    }
                    dx += 1
                }
                dz += 1
            }
        }
        return dep
    }

    /// Doubles an m×m field onto the main grid when the grids differ.
    func toMainGrid(_ f: UnsafePointer<Float>) -> UnsafeMutablePointer<Float> {
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        if aoN == n { memcpy(dst, f, n * n * MemoryLayout<Float>.stride) } else { LitErosion.upsample(f, aoN, into: dst) }
        return dst
    }

    /// Broken rock falls from what is too steep to hold it and comes to rest in cones at about 34°.
    /// The ground rises by what lies there; `scree` remembers it.
    mutating func addScree(rate: Float, minHeight: Float, seed: UInt32) {
        let m = aoN
        let g = gatherH()
        defer { g.deallocate() }
        let c = size / Float(m - 1)
        let src = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        let cap = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        defer { src.deallocate(); cap.deallocate() }
        let x0 = self.x0, z0 = self.z0
        litParallelFor(m, chunk: 8) { z in
            for x in 0..<m {
                let i = z * m + x
                if x < 1 || z < 1 || x >= m - 1 || z >= m - 1 { src[i] = 0; cap[i] = 0; continue }
                let sx = (g[i + 1] - g[i - 1]) / (2 * c), sz = (g[i + m] - g[i - m]) / (2 * c)
                let s = (sx * sx + sz * sz).squareRoot()
                let ang = atanf(s) * 57.29578
                let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                let nv = litFbm(wx / 300, wz / 300, 2, seed) * 0.5 + 0.5
                src[i] = g[i] < minHeight ? 0 : rate * litSstep(38, 58, ang) * (0.4 + 1.2 * nv)
                // Holds much on gentle ground, nothing past the angle of repose.
                cap[i] = 16 * (1 - litSstep(24, 36, ang))
            }
        }
        let dep = LitHeightLayer.slide(UnsafePointer(g), m, cell: c, source: UnsafePointer(src), hold: UnsafePointer(cap))
        defer { dep.deallocate() }
        let r = max(1, Int((9 / c).rounded()))
        let smooth = LitHeightLayer.blurred(UnsafePointer(dep), m, radius: r)
        scree = smooth
        let up = toMainGrid(UnsafePointer(smooth))
        defer { up.deallocate() }
        let hp = self.h
        litParallelFor(n * n, chunk: 8192) { i in hp[i] += up[i] }
    }

    /// Ribs and gullies on the AO grid at two sizes, with the slope's own fall-off taken out.
    mutating func buildCurve(wide: Float = 60, narrow: Float = 16) {
        let m = aoN
        let g = gatherH()
        defer { g.deallocate() }
        let c = size / Float(m - 1)
        let r1 = max(1, Int((narrow / c).rounded())), r2 = max(r1 + 1, Int((wide / c).rounded()))
        let a = LitHeightLayer.blurred(UnsafePointer(g), m, radius: r1)
        let b = LitHeightLayer.blurred(UnsafePointer(g), m, radius: r2)
        defer { a.deallocate(); b.deallocate() }
        let f = curve ?? UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        let k1 = 1 / max(1, narrow * 0.3), k2 = 1 / max(1, wide * 0.3)
        litParallelFor(m, chunk: 16) { z in
            for x in 0..<m {
                let i = z * m + x
                let v = (g[i] - a[i]) * k1 * 0.55 + (g[i] - b[i]) * k2 * 0.65
                f[i] = max(-1.5, min(1.5, v))
            }
        }
        curve = f
    }

    /// Snow as a real surface: it falls above the line, slides off what is too steep, gathers in couloirs and basins
    /// and smooths over the ground it buries. The height field becomes the top of the snow; `snow` holds signed depth.
    /// `amount` is the metres that fall at the top of the mountain; `steepLimit` the slope angle (degrees) past which it will not stay.
    mutating func addSnowSlide(line: Float, band: Float, amount: Float, steepLimit: Float, seed: UInt32, smooth: Float = 22, patch: Float = 5, ribMargin: Float = 3) {
        let m = aoN
        let g = gatherH()
        defer { g.deallocate() }
        let c = size / Float(m - 1)
        // Snow feels the mountain, not each rib: its slope and its routes are read from ground smoothed over a few gullies.
        let rB = max(1, Int((smooth * 3.2 / c).rounded()))
        let broad = LitHeightLayer.blurred(UnsafePointer(g), m, radius: rB)
        defer { broad.deallocate() }
        let src = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        let cap = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        let bench = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        defer { src.deallocate(); cap.deallocate(); bench.deallocate() }
        let x0 = self.x0, z0 = self.z0
        litParallelFor(m, chunk: 8) { z in
            for x in 0..<m {
                let i = z * m + x
                if x < 1 || z < 1 || x >= m - 1 || z >= m - 1 { src[i] = 0; cap[i] = 0; bench[i] = 0; continue }
                let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                let sx = (broad[i + 1] - broad[i - 1]) / (2 * c), sz = (broad[i + m] - broad[i - m]) / (2 * c)
                let ang = atanf((sx * sx + sz * sz).squareRoot()) * 57.29578
                let nA = litFbm(wx / 1400, wz / 1400, 3, seed)
                let nB = litFbm(wx / 210, wz / 210, 3, seed &+ 1)
                let y = g[i] + nA * band * 0.5 + nB * band * 0.22
                let high = litSstep(line - band, line + band, y)
                src[i] = amount * high * (0.75 + 0.5 * nB)
                // What a slope can hold, in metres; the limit moves with the wind and with the rock under it.
                let lim = steepLimit - 14 + nA * (patch + 22) + nB * 8
                let holds = 18 * (1 - litSstep(lim - 26, lim - 8, ang))
                cap[i] = holds * high * high
                // Faces too steep for a field keep snow only on their ledges, read below from the ground itself.
                bench[i] = high * high * litSstep(lim - 26, lim - 6, ang)
            }
        }
        let dep = LitHeightLayer.slide(UnsafePointer(broad), m, cell: c, source: UnsafePointer(src), hold: UnsafePointer(cap))
        defer { dep.deallocate() }
        // Surface: ground + snow, smoothed over; what lies under it is buried, what stands proud of it is rock.
        let raised = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        defer { raised.deallocate() }
        litParallelFor(m * m, chunk: 8192) { i in raised[i] = g[i] + min(dep[i], 7) }
        let r1 = max(1, Int((smooth / c).rounded()))
        let surfaceFine = LitHeightLayer.blurred(UnsafePointer(raised), m, radius: max(1, r1 / 2))
        let depSoft = LitHeightLayer.blurred(UnsafePointer(dep), m, radius: r1)
        defer { surfaceFine.deallocate(); depSoft.deallocate() }
        let sd = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        defer { sd.deallocate() }
        let margin = ribMargin
        litParallelFor(m * m, chunk: 8192) { i in
            // Rock shows where a big rib stands above the smooth surface, and where hardly any snow stayed.
            sd[i] = min(surfaceFine[i] - g[i] + margin, min(depSoft[i], 7) * 2.2 - 0.9) + min(1.5, depSoft[i] * 0.4)
        }
        let sdMain = toMainGrid(UnsafePointer(sd))
        let benchMain = toMainGrid(UnsafePointer(bench))
        let broadMain = toMainGrid(UnsafePointer(broad))
        defer { benchMain.deallocate(); broadMain.deallocate() }
        let hp = self.h, n = self.n, cM = self.cell
        let ledgeA = max(cM * 2.2, smooth * 1.5), ledgeB = max(cM * 3.5, smooth * 4), bandH = max(cM * 3.4, smooth * 2.4)
        let rise = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        defer { rise.deallocate() }
        litParallelFor(n, chunk: 8) { z in
            for x in 0..<n {
                let i = z * n + x
                var d = sdMain[i]
                rise[i] = max(0, min(d, 7))
                if x > 0 && z > 0 && x < n - 1 && z < n - 1 && benchMain[i] > 0.01 {
                    // A ledge is ground flatter than the face it sits on. Gaps across the face, so no two ledges line up.
                    let lx = (hp[i + 1] - hp[i - 1]) / (2 * cM), lz = (hp[i + n] - hp[i - n]) / (2 * cM)
                    let bx = (broadMain[i + 1] - broadMain[i - 1]) / (2 * cM), bz = (broadMain[i + n] - broadMain[i - n]) / (2 * cM)
                    let local = atanf((lx * lx + lz * lz).squareRoot()) * 57.29578
                    let face = atanf((bx * bx + bz * bz).squareRoot()) * 57.29578
                    let wx = x0 + Float(x) * cM, wz = z0 + Float(z) * cM
                    let gap = litGnoise(wx / ledgeB, wz / ledgeB, seed &+ 4) * 0.75 + litGnoise(wx / ledgeA, wz / ledgeA, seed &+ 5) * 0.55
                    let tilted = hp[i] + wx * 0.07 - wz * 0.05 + litGnoise(wx / (bandH * 5), wz / (bandH * 5), seed &+ 6) * bandH * 1.2
                    let q1 = tilted / bandH, q2 = tilted / (bandH * 0.37) + 0.37
                    let band = abs(q1 - q1.rounded(.down) - 0.5) * 1.24 + abs(q2 - q2.rounded(.down) - 0.5) * 0.76 - 0.5
                    let ledge = benchMain[i] * ((face - local) / 14 + gap * 1.15 + band * 1.1 - 0.04) * 5
                    if ledge > d {
                        d = ledge
                        rise[i] = max(rise[i], min(1.5, ledge))
                    }
                }
                sdMain[i] = d
            }
        }
        litParallelFor(n * n, chunk: 8192) { i in hp[i] += rise[i] }
        snow = sdMain
    }
}

// MARK: Volumetric clouds: Perlin-Worley density, Beer-Lambert through the volume, multiple scattering by octaves

nonisolated struct LitCloudLayer: @unchecked Sendable {
    var base: Float, top: Float
    /// Metres per tile of the shape and detail textures.
    var scale: Float, detailScale: Float
    /// Vertical squash of the shape texture: above 1 flattens the billows.
    var vstretch: Float = 1
    /// Extinction per metre at density 1.
    var sigma: Float
    /// 0…1 how far the detail noise eats into the edge.
    var erode: Float = 0.4
    /// Coverage map, 0…1, over ±`half` metres around the origin.
    var weather: UnsafeMutablePointer<Float>
    var wN: Int
    var half: Float
    /// Where in the column the mass sits: bottom fade, top fade start.
    var fadeBottom: Float = 0.06
    var fadeTopFrom: Float = 0.55
    /// Horizontal shift of the top against the bottom.
    var shearX: Float = 0, shearZ: Float = 0
    var minStep: Float = 60
    var stepK: Float = 0.012
    var lightSteps: Int = 6
    var lightFirst: Float = 40
    var lightGrow: Float = 1.7
    /// Rounded-top cumulus reading of the coverage: columns reach a height set by coverage (anvil look).
    var towering: Float = 0
    /// How fast the density grows with the coverage.
    var massGain: Float = 2.4
    /// Steps just under a cloud's surface: at least this many metres, or this share of the distance.
    var fineStep: Float = 10
    var fineK: Float = 0.0018
    /// Share of the extinction that the light towards the sun feels: scattering forward carries light deep into a cloud.
    var lightK: Float = 0.5
    /// How much the detail noise bites where the cloud is thin (1 = as hard as anywhere): low values keep thin parts whole instead of crumbling.
    var erodeThin: Float = 1
    /// Beer-powder darkening at edges facing the light.
    var powder: Float = 0.5

    /// Coverage ends with the map, rather than smearing its edge into streaks that fan out from the horizon.
    var edgeFade = false

    @inline(__always) func coverage(_ x: Float, _ z: Float) -> Float {
        var keep: Float = 1
        if edgeFade {
            let e = max(abs(x), abs(z)) / half
            if e >= 1 { return 0 }
            keep = 1 - litSstep(0.8, 1, e)
        }
        let s = Float(wN - 1) / (2 * half)
        let fx = max(0, min(Float(wN - 1) - 0.001, (x + half) * s)), fz = max(0, min(Float(wN - 1) - 0.001, (z + half) * s))
        let ix = Int(fx), iz = Int(fz)
        let ax = fx - Float(ix), az = fz - Float(iz)
        let i = iz * wN + ix
        let a = weather[i] + (weather[i + 1] - weather[i]) * ax
        let b = weather[i + wN] + (weather[i + wN + 1] - weather[i + wN]) * ax
        return (a + (b - a) * az) * keep
    }
}

/// Builds a coverage map from a closure.
nonisolated func litMakeWeather(n: Int, half: Float, _ f: (Float, Float) -> Float) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
    let s = 2 * half / Float(n - 1)
    litParallelFor(n, chunk: 8) { z in
        for x in 0..<n {
            p[z * n + x] = f(-half + Float(x) * s, -half + Float(z) * s)
        }
    }
    return p
}

nonisolated struct LitClouds: @unchecked Sendable {
    let shape: LitTex3D, detail: LitTex3D
    var layers: UnsafeMutablePointer<LitCloudLayer>
    var count: Int
    let planetR: Float = 6_371_000
    /// How much sun reaches a level `castLevel` over ±`castHalf` metres: peaks throw shadows on the deck.
    var castMap: UnsafeMutablePointer<Float>? = nil
    var castN: Int = 0
    var castHalf: Float = 0
    var castZ: Float = 0
    var castLevel: Float = 0
    var sun: LitV3 = LitV3(0, 1, 0)
    var ambTop = LitV3.zero, ambBottom = LitV3.zero
    var g1: Float = 0.8, g2: Float = -0.25, gMix: Float = 0.72
    var hiQuality = true
    /// Extra brightness of sunlight in the cloud.
    var sunGain: Float = 1
    /// Multiple scattering whitens what a low sun tints: a colour over the sunlight inside the cloud.
    var sunTint = LitV3(1, 1, 1)

    @inline(__always) func altitude(_ p: LitV3) -> Float { p.y + (p.x * p.x + p.z * p.z) / (2 * planetR) }

    @inline(__always) func density(_ l: LitCloudLayer, _ p: LitV3, hi: Bool) -> Float {
        let alt = altitude(p)
        let hN = (alt - l.base) / (l.top - l.base)
        if hN <= 0 || hN >= 1 { return 0 }
        let qx = p.x + l.shearX * hN, qz = p.z + l.shearZ * hN
        let cov = l.coverage(qx, qz)
        if cov <= 0.001 { return 0 }
        // Column profile: flat-ish base, rounded top; a tall column where the coverage is high.
        let topFade = 1 - litSstep(l.fadeTopFrom + l.towering * (cov - 0.5), 1, hN + (1 - cov) * l.towering)
        let grad = litSstep(0, l.fadeBottom, hN) * topFade
        let g = cov * grad
        if g <= 0.001 { return 0 }
        let b = shape.sample(qx / l.scale, alt / (l.scale * l.vstretch), qz / l.scale)
        // Thin where the coverage is thin: a low coverage gives wisps, never hard little lumps.
        var d = litSat(litRemap(b, 1 - g, 1, 0, 1)) * litSat(g * l.massGain)
        if d <= 0 { return 0 }
        if hi {
            let ds = l.detailScale
            let e1 = detail.sample(qx / ds, alt / ds, qz / ds)
            let ds2 = ds * 0.27
            let e2 = detail.sample((qx + 311) / ds2, (alt + 173) / ds2, (qz - 97) / ds2)
            let e = e1 * 0.68 + e2 * 0.32
            let edge = litLerp(e, 1 - e, litSat(hN * 3.5))
            let bite = l.erodeThin >= 1 ? l.erode : l.erode * (l.erodeThin + (1 - l.erodeThin) * litSstep(0.02, 0.5, d))
            d = litSat(litRemap(d, edge * bite, 1, 0, 1))
        }
        return d * d.squareRoot()
    }

    /// Optical depth from p towards the sun.
    @inline(__always) func lightDepth(_ l: LitCloudLayer, _ p: LitV3) -> Float {
        var od: Float = 0
        var ds = l.lightFirst
        var s: Float = ds * 0.5
        var i = 0
        while i < l.lightSteps {
            let q = p + sun * s
            od += density(l, q, hi: hiQuality && i < 2) * ds
            s += ds * 0.5
            ds *= l.lightGrow
            s += ds * 0.5
            i += 1
        }
        return od * l.sigma * l.lightK
    }

    /// The t interval(s) of a ray inside a layer, up to `tMax`.
    @inline(__always) func interval(_ l: LitCloudLayer, ro: LitV3, rd: LitV3, tMax: Float) -> (Float, Float, Float, Float) {
        let a = max(1e-12, (1 - rd.y * rd.y)) / (2 * planetR)
        // Roots of a t² + rd.y t + (ro.y - level).
        func roots(_ level: Float) -> (Float, Float)? {
            let c = altitude(ro) - level
            let disc = rd.y * rd.y - 4 * a * c
            if disc < 0 { return nil }
            let q = disc.squareRoot()
            return ((-rd.y - q) / (2 * a), (-rd.y + q) / (2 * a))
        }
        guard let top = roots(l.top) else { return (0, -1, 0, -1) }
        let t1 = top.0, t2 = top.1
        if t2 <= 0 { return (0, -1, 0, -1) }
        if let bot = roots(l.base) {
            let t3 = bot.0, t4 = bot.1
            // [t1, t3] ∪ [t4, t2]
            let a0 = max(0, t1), b0 = min(tMax, t3)
            let a1 = max(0, t4), b1 = min(tMax, t2)
            return (a0, b0, a1, b1)
        }
        return (max(0, t1), min(tMax, t2), 0, -1)
    }

    /// Radiance scattered towards the camera along a ray and what's left of the background.
    func march(ro: LitV3, rd: LitV3, tMax: Float, jitter: Float, A: LitAtmosphere, maxSteps: Int = 110) -> (L: LitV3, T: Float, tm: Float) {
        var T: Float = 1
        var L = LitV3.zero
        var tSum: Float = 0, wSum: Float = 0
        let cosT = litDot3(rd, sun)
        // Three scattering orders, each with a lower phase anisotropy.
        var phases = SIMD3<Float>.zero
        var gc: Float = 1
        for o in 0..<3 {
            let g = g1 * gc, gb = g2 * gc
            let p1 = (1 - g * g) / (4 * Float.pi * powf(1 + g * g - 2 * g * cosT, 1.5))
            let p2 = (1 - gb * gb) / (4 * Float.pi * powf(1 + gb * gb - 2 * gb * cosT, 1.5))
            phases[o] = gMix * p1 + (1 - gMix) * p2
            gc *= 0.55
        }
        var steps = 0
        let up = rd.y >= 0
        var li = up ? 0 : count - 1
        while li >= 0 && li < count && T > 0.012 && steps < maxSteps {
            let l = layers[li]
            let iv = interval(l, ro: ro, rd: rd, tMax: tMax)
            for span in 0..<2 {
                var t = span == 0 ? iv.0 : iv.2
                let end = span == 0 ? iv.1 : iv.3
                if end <= t { continue }
                // The whole sample lattice slides with the jitter, so no layer-locked bands.
                let spanStart = t
                t += max(l.minStep, t * l.stepK) * (jitter - 1)
                t = max(0, t)
                var inside = false
                var dtFine: Float = 0
                var empty = 0
                while t < end && T > 0.012 && steps < maxSteps {
                    steps += 1
                    if !inside {
                        // Long strides through clear air until the cloud's surface is bracketed, then pin it down.
                        let dt0 = max(l.minStep, t * l.stepK)
                        let tt = t + dt0
                        let p = ro + rd * tt
                        if density(l, p, hi: false) <= 0 || density(l, p, hi: hiQuality) <= 0.0005 {
                            t = tt
                            continue
                        }
                        var lo = max(spanStart, t), hi = tt
                        var b = 0
                        while b < 4 {
                            let mid = (lo + hi) * 0.5
                            if density(l, ro + rd * mid, hi: hiQuality) > 0.0005 { hi = mid } else { lo = mid }
                            b += 1
                        }
                        t = hi
                        inside = true
                        empty = 0
                        dtFine = max(l.fineStep, t * l.fineK)
                    }
                    let dt0 = dtFine
                    let tt = t + dt0 * 0.5
                    let p = ro + rd * tt
                    let d = density(l, p, hi: hiQuality)
                    if d > 0.0005 {
                        empty = 0
                        let sigma = d * l.sigma
                        let od = lightDepth(l, p)
                        var light = phases[0] * expf(-od) + phases[1] * 0.5 * expf(-od * 0.4) + phases[2] * 0.25 * expf(-od * 0.16)
                        // Beer-powder: edges facing the light are not darker than the interior gets.
                        let powder = 1 - l.powder * expf(-sigma * 60)
                        light *= powder
                        let alt = altitude(p)
                        var sunC = A.sunColor(y: alt) * sunTint * sunGain
                        if let cm = castMap {
                            // Peaks in the way of the light: carried along the sun's ray down to the map's level.
                            let run = (alt - castLevel) / max(0.03, sun.y)
                            let qx = (p.x - sun.x * run + castHalf) / (2 * castHalf) * Float(castN - 1)
                            let qz = (p.z - sun.z * run - castZ + castHalf) / (2 * castHalf) * Float(castN - 1)
                            if qx >= 0 && qz >= 0 && qx < Float(castN - 1) && qz < Float(castN - 1) {
                                let ix = Int(qx), iz = Int(qz)
                                let ax = qx - Float(ix), az = qz - Float(iz)
                                let i = iz * castN + ix
                                let a = cm[i] + (cm[i + 1] - cm[i]) * ax
                                let b = cm[i + castN] + (cm[i + castN + 1] - cm[i + castN]) * ax
                                sunC = sunC * (a + (b - a) * az)
                            }
                        }
                        let hN = litSat((alt - l.base) / (l.top - l.base))
                        // LitAmbient: sky from above, what comes up from below; thick clouds are darker inside.
                        let inner = expf(-od * 0.08)
                        let amb = litLerp(ambBottom, ambTop, hN * 0.8 + 0.2) * (0.45 + 0.55 * inner)
                        let S = (sunC * light + amb * (1 / (4 * Float.pi)))
                        let dT = expf(-sigma * dt0)
                        L += S * (1 - dT) * T
                        tSum += tt * T * (1 - dT)
                        wSum += T * (1 - dT)
                        T *= dT
                    } else {
                        empty += 1
                        if empty >= 3 { inside = false }
                    }
                    t += dt0
                    dtFine = min(dtFine * 1.28, max(l.minStep, t * l.stepK))
                }
            }
            li += up ? 1 : -1
        }
        return (L, T, wSum > 1e-5 ? tSum / wSum : 0)
    }

}

/// Half-resolution scattered light and transmittance, with the depth they were computed against.
nonisolated struct LitCloudBuffer: @unchecked Sendable {
    let w: Int, h: Int, scale: Int
    let I: UnsafeMutablePointer<LitV3>
    let T: UnsafeMutablePointer<Float>
    let D: UnsafeMutablePointer<Float>
    init(w: Int, h: Int, scale: Int) {
        self.w = w; self.h = h; self.scale = scale
        I = .allocate(capacity: w * h); T = .allocate(capacity: w * h); D = .allocate(capacity: w * h)
    }
    func free() { I.deallocate(); T.deallocate(); D.deallocate() }

    /// Depth-aware bilinear look-up at a full-resolution position.
    @inline(__always) func sample(x: Float, y: Float, depth: Float) -> (LitV3, Float) {
        let fs = Float(scale)
        let u = max(0, min(Float(w) - 1.001, x / fs - 0.5)), v = max(0, min(Float(h) - 1.001, y / fs - 0.5))
        let ix = Int(u), iy = Int(v)
        let ax = u - Float(ix), ay = v - Float(iy)
        let i0 = iy * w + ix, i1 = i0 + 1, i2 = i0 + w, i3 = i2 + 1
        @inline(__always) func wgt(_ d: Float) -> Float {
            if depth == .infinity { return d == .infinity ? 1 : 0.0005 }
            if d == .infinity { return 0.0005 }
            let r = abs(d - depth) / max(depth, 1)
            return max(0.1, litSat(1 - (r - 0.04) / 0.12))
        }
        let w0 = (1 - ax) * (1 - ay) * wgt(D[i0]), w1 = ax * (1 - ay) * wgt(D[i1])
        let w2 = (1 - ax) * ay * wgt(D[i2]), w3 = ax * ay * wgt(D[i3])
        let s = max(1e-6, w0 + w1 + w2 + w3)
        let col = (I[i0] * w0 + I[i1] * w1 + I[i2] * w2 + I[i3] * w3) / s
        let tr = (T[i0] * w0 + T[i1] * w1 + T[i2] * w2 + T[i3] * w3) / s
        return (col, tr)
    }

    /// Plain bilinear (for mirrored look-ups in water).
    @inline(__always) func sample(x: Float, y: Float) -> (LitV3, Float) {
        let fs = Float(scale)
        let u = max(0, min(Float(w) - 1.001, x / fs - 0.5)), v = max(0, min(Float(h) - 1.001, y / fs - 0.5))
        let ix = Int(u), iy = Int(v)
        let ax = u - Float(ix), ay = v - Float(iy)
        let i0 = iy * w + ix, i1 = i0 + 1, i2 = i0 + w, i3 = i2 + 1
        let c = litLerp(litLerp(I[i0], I[i1], ax), litLerp(I[i2], I[i3], ax), ay)
        let t = litLerp(litLerp(T[i0], T[i1], ax), litLerp(T[i2], T[i3], ax), ay)
        return (c, t)
    }
}

nonisolated enum LitCloudPass {
    @inline(__always) static func ign(_ x: Int, _ y: Int) -> Float {
        let v = 52.9829189 * Float(x % 1024) * 0.06711056 + 52.9829189 * Float(y % 1024) * 0.00583715
        return v - v.rounded(.down)
    }

    /// Renders scattered light + transmittance for a frame, respecting `depth` (full-res, metres; inf for sky).
    static func render(_ c: LitClouds, A: LitAtmosphere, cam: LitCamera, fw: Int, fh: Int, scale: Int, rows: Range<Int>? = nil,
                       maxSteps: Int = 110, depth: UnsafeMutablePointer<Float>?, refine: Float? = nil, tent: Bool = true) -> LitCloudBuffer {
        let w = (fw + scale - 1) / scale, h = (fh + scale - 1) / scale
        let buf = LitCloudBuffer(w: w, h: h, scale: scale)
        let tFar: Float = 320_000
        let fs = Float(scale)
        litParallelFor(h, chunk: 2) { y in
            for x in 0..<w {
                let i = y * w + x
                let px = (Float(x) + 0.5) * fs, py = (Float(y) + 0.5) * fs
                var d: Float = .infinity
                if let depth {
                    let sx = min(fw - 1, Int(px)), sy = min(fh - 1, Int(py))
                    d = depth[sy * fw + sx]
                }
                buf.D[i] = d
                if let rows, !rows.contains(y * scale) {
                    buf.I[i] = .zero; buf.T[i] = 1
                    continue
                }
                let rd = cam.dir(px, py)
                let r = c.march(ro: cam.ro, rd: rd, tMax: min(tFar, d), jitter: ign(x, y), A: A, maxSteps: maxSteps)
                if r.T >= 0.999 && litLuma(r.L) < 1e-5 {
                    buf.I[i] = .zero; buf.T[i] = 1
                    continue
                }
                let air = A.aerial(ro: cam.ro, rd: rd, t: r.tm, steps: 6)
                buf.I[i] = r.L * air.trans + air.add * (1 - r.T)
                buf.T[i] = r.T
            }
        }
        if tent { smooth(buf) }
        if scale > 1, let thr = refine {
            let full = refined(buf, c, A: A, cam: cam, fw: fw, fh: fh, rows: rows, maxSteps: maxSteps, depth: depth, tFar: tFar, threshold: thr)
            buf.free()
            return full
        }
        return buf
    }

    /// Full-resolution result: the half-size picture where it is smooth, a fresh march where the half-size picture has an edge.
    static func refined(_ b: LitCloudBuffer, _ c: LitClouds, A: LitAtmosphere, cam: LitCamera, fw: Int, fh: Int, rows: Range<Int>?, maxSteps: Int,
                        depth: UnsafeMutablePointer<Float>?, tFar: Float, threshold: Float) -> LitCloudBuffer {
        let w = b.w, h = b.h
        let contrast = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { contrast.deallocate() }
        litParallelFor(h, chunk: 8) { y in
            for x in 0..<w {
                let i = y * w + x
                let l0 = litLuma(b.I[i]).squareRoot(), t0 = b.T[i]
                var m: Float = 0
                var yy = max(0, y - 1)
                while yy <= min(h - 1, y + 1) {
                    var xx = max(0, x - 1)
                    while xx <= min(w - 1, x + 1) {
                        let j = yy * w + xx
                        m = max(m, abs(litLuma(b.I[j]).squareRoot() - l0) + abs(b.T[j] - t0) * 0.35)
                        xx += 1
                    }
                    yy += 1
                }
                contrast[i] = m
            }
        }
        let f = LitCloudBuffer(w: fw, h: fh, scale: 1)
        let s = b.scale
        litParallelFor(fh, chunk: 2) { y in
            for x in 0..<fw {
                let i = y * fw + x
                var d: Float = .infinity
                if let depth { d = depth[i] }
                f.D[i] = d
                if let rows, !rows.contains(y) {
                    f.I[i] = .zero; f.T[i] = 1
                    continue
                }
                let hi = min(h - 1, y / s) * w + min(w - 1, x / s)
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                if contrast[hi] < threshold {
                    let r = b.sample(x: px, y: py, depth: d)
                    f.I[i] = r.0; f.T[i] = r.1
                    continue
                }
                let rd = cam.dir(px, py)
                let r = c.march(ro: cam.ro, rd: rd, tMax: min(tFar, d), jitter: ign(x, y), A: A, maxSteps: maxSteps)
                if r.T >= 0.999 && litLuma(r.L) < 1e-5 {
                    f.I[i] = .zero; f.T[i] = 1
                    continue
                }
                let air = A.aerial(ro: cam.ro, rd: rd, t: r.tm, steps: 5)
                f.I[i] = r.L * air.trans + air.add * (1 - r.T)
                f.T[i] = r.T
            }
        }
        smooth(f)
        thinOverRock(f)
        return f
    }

    /// Thin cloud crossing rock ends at the rock, so each pixel's march stops somewhere else in the sampling pattern. A wider, more forgiving blur takes that speckle out; only those pixels pay for it.
    static func thinOverRock(_ b: LitCloudBuffer) {
        let w = b.w, h = b.h
        let I2 = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        let T2 = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { I2.deallocate(); T2.deallocate() }
        let k: [Float] = [1, 4, 6, 4, 1]
        k.withUnsafeBufferPointer { kp in
            litParallelFor(h, chunk: 8) { y in
                for x in 0..<w {
                    let c = y * w + x
                    let d0 = b.D[c], t0 = b.T[c]
                    if d0 == .infinity || t0 <= 0.015 || t0 >= 0.985 {
                        I2[c] = b.I[c]; T2[c] = t0
                        continue
                    }
                    var s = LitV3.zero, t: Float = 0, sw: Float = 0
                    let reach = d0 * 0.12
                    for dy in -2...2 {
                        let yy = y + dy
                        if yy < 0 || yy >= h { continue }
                        for dx in -2...2 {
                            let xx = x + dx
                            if xx < 0 || xx >= w { continue }
                            let i = yy * w + xx
                            let d = b.D[i]
                            if d == .infinity || abs(d - d0) > reach { continue }
                            let wg = kp[dx + 2] * kp[dy + 2]
                            s += b.I[i] * wg
                            t += b.T[i] * wg
                            sw += wg
                        }
                    }
                    I2[c] = s / max(1e-5, sw)
                    T2[c] = t / max(1e-5, sw)
                }
            }
        }
        memcpy(b.I, I2, w * h * MemoryLayout<LitV3>.stride)
        memcpy(b.T, T2, w * h * MemoryLayout<Float>.stride)
    }

    /// A small tent over the half-size result takes out the sampling noise; depth edges are kept.
    static func smooth(_ b: LitCloudBuffer) {
        let w = b.w, h = b.h
        let I2 = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        let T2 = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { I2.deallocate(); T2.deallocate() }
        let k: (Float, Float, Float) = (0.25, 0.5, 0.25)
        @inline(__always) func wt(_ i: Int) -> Float { i == -1 ? k.0 : (i == 0 ? k.1 : k.2) }
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let c = y * w + x
                let d0 = b.D[c]
                var s = LitV3.zero, t: Float = 0, sw: Float = 0
                for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= w { continue }
                        let i = yy * w + xx
                        let d = b.D[i]
                        if (d == .infinity) != (d0 == .infinity) { continue }
                        if d0 != .infinity && abs(d - d0) > d0 * 0.06 { continue }
                        let wg = wt(dx) * wt(dy)
                        s += b.I[i] * wg
                        t += b.T[i] * wg
                        sw += wg
                    }
                }
                I2[c] = s / max(1e-5, sw)
                T2[c] = t / max(1e-5, sw)
            }
        }
        memcpy(b.I, I2, w * h * MemoryLayout<LitV3>.stride)
        memcpy(b.T, T2, w * h * MemoryLayout<Float>.stride)
    }
}

// MARK: Ocean: FFT wave tiles (Tessendorf), crest sharpening, slope pyramids

nonisolated struct LitFFT2: @unchecked Sendable {
    let n: Int, logN: Int
    let cosT: UnsafeMutablePointer<Float>, sinT: UnsafeMutablePointer<Float>
    let rev: UnsafeMutablePointer<Int32>
    init(n: Int) {
        self.n = n
        var l = 0
        while (1 << l) < n { l += 1 }
        logN = l
        cosT = .allocate(capacity: n); sinT = .allocate(capacity: n); rev = .allocate(capacity: n)
        for i in 0..<n {
            let a = 2 * Float.pi * Float(i) / Float(n)
            cosT[i] = cosf(a); sinT[i] = sinf(a)
            var r = 0
            for b in 0..<l where i & (1 << b) != 0 { r |= 1 << (l - 1 - b) }
            rev[i] = Int32(r)
        }
    }
    func free() { cosT.deallocate(); sinT.deallocate(); rev.deallocate() }

    /// In-place inverse transform of one line (stride 1).
    @inline(__always) private func line(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        for i in 0..<n {
            let j = Int(rev[i])
            if j > i {
                let a = re[i]; re[i] = re[j]; re[j] = a
                let b = im[i]; im[i] = im[j]; im[j] = b
            }
        }
        var size = 2
        while size <= n {
            let half = size / 2, step = n / size
            var s = 0
            while s < n {
                var k = 0
                var tw = 0
                while k < half {
                    let c = cosT[tw], d = sinT[tw]
                    let ar = re[s + k + half], ai = im[s + k + half]
                    let tr = ar * c - ai * d, ti = ar * d + ai * c
                    re[s + k + half] = re[s + k] - tr
                    im[s + k + half] = im[s + k] - ti
                    re[s + k] += tr
                    im[s + k] += ti
                    k += 1
                    tw += step
                }
                s += size
            }
            size *= 2
        }
    }

    /// In-place 2D inverse transform, no normalisation (amplitudes are set by hand).
    func inverse(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        let n = self.n
        litParallelFor(n, chunk: 16) { y in line(re + y * n, im + y * n) }
        litParallelFor(n, chunk: 16) { x in
            withUnsafeTemporaryAllocation(of: Float.self, capacity: 2 * n) { buf in
                let r = buf.baseAddress!, i = r + n
                for y in 0..<n { r[y] = re[y * n + x]; i[y] = im[y * n + x] }
                line(r, i)
                for y in 0..<n { re[y * n + x] = r[y]; im[y * n + x] = i[y] }
            }
        }
    }
}

nonisolated struct LitOceanTile: @unchecked Sendable {
    let n: Int
    let L: Float, dx: Float
    let height: UnsafeMutablePointer<Float>
    /// (slope x, slope z, unresolved slope variance, foam) pyramid.
    let mips: UnsafeMutablePointer<UnsafeMutablePointer<SIMD4<Float>>>
    let levels: Int

    init(n: Int, L: Float, fft: LitFFT2, seed: UInt32, wind: LitV2, spectrum: (Float, Float) -> Float, heightRMS: Float, chop: Float) {
        self.n = n; self.L = L; dx = L / Float(n)
        var lv = 0
        while (1 << lv) < n { lv += 1 }
        levels = lv + 1
        mips = .allocate(capacity: levels)
        height = .allocate(capacity: n * n)
        // Spectrum → amplitude with Gaussian randoms.
        let total = n * n
        let hr = UnsafeMutablePointer<Float>.allocate(capacity: total), hi = UnsafeMutablePointer<Float>.allocate(capacity: total)
        let f1r = UnsafeMutablePointer<Float>.allocate(capacity: total), f1i = UnsafeMutablePointer<Float>.allocate(capacity: total)
        defer { hr.deallocate(); hi.deallocate(); f1r.deallocate(); f1i.deallocate() }
        let k0 = 2 * Float.pi / L
        // Hermitian amplitudes.
        for y in 0..<n {
            for x in 0..<n {
                let kx = Float(x <= n / 2 ? x : x - n) * k0, kz = Float(y <= n / 2 ? y : y - n) * k0
                let i = y * n + x
                let a0 = spectrum(kx, kz).squareRoot()
                var h1 = litHash32(Int32(x <= n / 2 ? x : x - n), Int32(y <= n / 2 ? y : y - n), seed)
                let u1 = max(1e-6, litUnit(h1)); h1 = h1 &* 0x9E37_79B1 &+ 7
                let u2 = litUnit(h1)
                let rg = (-2 * logf(u1)).squareRoot()
                hr[i] = a0 * rg * cosf(2 * .pi * u2)
                hi[i] = a0 * rg * sinf(2 * .pi * u2)
            }
        }
        // Symmetrise so the result is real: H(-k) = conj H(k).
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x, j = ((n - y) % n) * n + (n - x) % n
                if j >= i {
                    if i == j { hi[i] = 0; continue }
                    hr[j] = hr[i]; hi[j] = -hi[i]
                }
            }
        }
        // Height + i dispX, then dispZ + i 0.
        let re = UnsafeMutablePointer<Float>.allocate(capacity: total), im = UnsafeMutablePointer<Float>.allocate(capacity: total)
        defer { re.deallocate(); im.deallocate() }
        for y in 0..<n {
            for x in 0..<n {
                let kx = Float(x <= n / 2 ? x : x - n) * k0, kz = Float(y <= n / 2 ? y : y - n) * k0
                let k = (kx * kx + kz * kz).squareRoot()
                let i = y * n + x
                let ax = k > 1e-6 ? kx / k : 0, az = k > 1e-6 ? kz / k : 0
                // D = -i (k/|k|) H; field = height + i D_x:  re = hr + ax*hr, im = hi + ax*hi  (i * -i = 1)
                re[i] = hr[i] + ax * hr[i]
                im[i] = hi[i] + ax * hi[i]
                // D_z alone: -i az H.
                f1r[i] = az * hi[i]
                f1i[i] = -az * hr[i]
            }
        }
        fft.inverse(re, im)
        fft.inverse(f1r, f1i)
        // Normalise height to the wanted RMS.
        var s2: Float = 0
        for i in 0..<total { s2 += re[i] * re[i] }
        let gain = heightRMS / max(1e-6, (s2 / Float(total)).squareRoot())
        let chopG = chop * gain
        let n1 = n
        let dx1 = dx
        // Sharpen crests: find the undisplaced point for each texel (fixed point) and read its height.
        @inline(__always) func wrap(_ i: Int) -> Int { i & (n1 - 1) }
        let hp = height
        litParallelFor(n, chunk: 8) { y in
            for x in 0..<n1 {
                var px = Float(x), py = Float(y)
                for _ in 0..<3 {
                    let fx = px.rounded(.down), fy = py.rounded(.down)
                    let ix = Int(fx), iy = Int(fy)
                    let ax = px - fx, ay = py - fy
                    let i00 = wrap(iy) * n1 + wrap(ix), i10 = wrap(iy) * n1 + wrap(ix + 1)
                    let i01 = wrap(iy + 1) * n1 + wrap(ix), i11 = wrap(iy + 1) * n1 + wrap(ix + 1)
                    let dxv = litLerp(litLerp(im[i00], im[i10], ax), litLerp(im[i01], im[i11], ax), ay) * chopG / dx1
                    let dzv = litLerp(litLerp(f1r[i00], f1r[i10], ax), litLerp(f1r[i01], f1r[i11], ax), ay) * chopG / dx1
                    px = Float(x) - dxv
                    py = Float(y) - dzv
                }
                let fx = px.rounded(.down), fy = py.rounded(.down)
                let ix = Int(fx), iy = Int(fy)
                let ax = px - fx, ay = py - fy
                let i00 = wrap(iy) * n1 + wrap(ix), i10 = wrap(iy) * n1 + wrap(ix + 1)
                let i01 = wrap(iy + 1) * n1 + wrap(ix), i11 = wrap(iy + 1) * n1 + wrap(ix + 1)
                hp[y * n1 + x] = litLerp(litLerp(re[i00], re[i10], ax), litLerp(re[i01], re[i11], ax), ay) * gain
            }
        }
        // Level 0: slopes by differences of the sharpened height; foam where the surface folds.
        let l0 = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: total)
        litParallelFor(n, chunk: 8) { y in
            for x in 0..<n1 {
                let xm = wrap(x - 1), xp = wrap(x + 1), ym = wrap(y - 1), yp = wrap(y + 1)
                let sx = (hp[y * n1 + xp] - hp[y * n1 + xm]) / (2 * dx1)
                let sz = (hp[yp * n1 + x] - hp[ym * n1 + x]) / (2 * dx1)
                // Jacobian of the horizontal displacement.
                let ddxx = (im[y * n1 + xp] - im[y * n1 + xm]) * chopG / (2 * dx1)
                let ddzz = (f1r[yp * n1 + x] - f1r[ym * n1 + x]) * chopG / (2 * dx1)
                let ddxz = (im[yp * n1 + x] - im[ym * n1 + x]) * chopG / (2 * dx1)
                let J = (1 + ddxx) * (1 + ddzz) - ddxz * ddxz
                l0[y * n1 + x] = SIMD4(sx, sz, 0, litSat((0.35 - J) * 2))
            }
        }
        mips[0] = l0
        var cn = n
        for l in 1..<levels {
            let nn = cn / 2
            let m = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: nn * nn)
            let prev = mips[l - 1]
            let pn = cn
            litParallelFor(nn, chunk: 16) { y in
                for x in 0..<nn {
                    let a = prev[y * 2 * pn + x * 2], b = prev[y * 2 * pn + x * 2 + 1]
                    let c = prev[(y * 2 + 1) * pn + x * 2], d = prev[(y * 2 + 1) * pn + x * 2 + 1]
                    var avg = (a + b + c + d) * 0.25
                    // Slope variance that this level can no longer show.
                    let vx = (a.x - avg.x) * (a.x - avg.x) + (b.x - avg.x) * (b.x - avg.x) + (c.x - avg.x) * (c.x - avg.x) + (d.x - avg.x) * (d.x - avg.x)
                    let vz = (a.y - avg.y) * (a.y - avg.y) + (b.y - avg.y) * (b.y - avg.y) + (c.y - avg.y) * (c.y - avg.y) + (d.y - avg.y) * (d.y - avg.y)
                    avg.z = (a.z + b.z + c.z + d.z) * 0.25 + (vx + vz) * 0.25 * 0.5
                    m[y * nn + x] = avg
                }
            }
            mips[l] = m
            cn = nn
        }
    }

    func free() {
        height.deallocate()
        for l in 0..<levels { mips[l].deallocate() }
        mips.deallocate()
    }

    @inline(__always) func heightAt(_ x: Float, _ z: Float) -> Float {
        let u = x / dx, v = z / dx
        let fu = u.rounded(.down), fv = v.rounded(.down)
        let m = n - 1
        let ix = Int(fu) & m, iz = Int(fv) & m, jx = (ix + 1) & m, jz = (iz + 1) & m
        let ax = u - fu, az = v - fv
        return litLerp(litLerp(height[iz * n + ix], height[iz * n + jx], ax), litLerp(height[jz * n + ix], height[jz * n + jx], ax), az)
    }

    /// Slope pair, unresolved variance, foam for a footprint of `fp` metres.
    @inline(__always) func slope(_ x: Float, _ z: Float, fp: Float) -> SIMD4<Float> {
        let lod = max(0, log2f(max(fp, dx) / dx))
        if lod >= Float(levels - 1) { return mips[levels - 1][0] }
        let l0 = Int(lod)
        let a = fetch(l0, x, z)
        let t = lod - Float(l0)
        if t < 0.01 { return a }
        let b = fetch(l0 + 1, x, z)
        return a + (b - a) * t
    }

    @inline(__always) private func fetch(_ l: Int, _ x: Float, _ z: Float) -> SIMD4<Float> {
        let nl = n >> l
        let d = dx * Float(1 << l)
        let u = x / d - 0.5, v = z / d - 0.5
        let fu = u.rounded(.down), fv = v.rounded(.down)
        let m = nl - 1
        let ix = Int(fu) & m, iz = Int(fv) & m, jx = (ix + 1) & m, jz = (iz + 1) & m
        let ax = u - fu, az = v - fv
        let p = mips[l]
        let a = p[iz * nl + ix], b = p[iz * nl + jx], c = p[jz * nl + ix], e = p[jz * nl + jx]
        let q = a + (b - a) * ax
        let r = c + (e - c) * ax
        return q + (r - q) * az
    }
}

/// Sky and clouds in every direction a wave can reflect: azimuth ±`azMax`, elevation 0…~80° (dense at the horizon).
nonisolated struct LitEnvMap: @unchecked Sendable {
    let w: Int, h: Int
    let azMax: Float
    let p: UnsafeMutablePointer<LitV3>
    init(w: Int, h: Int, azMax: Float) {
        self.w = w; self.h = h; self.azMax = azMax
        p = .allocate(capacity: w * h)
    }
    func free() { p.deallocate() }

    @inline(__always) func dirAt(_ x: Int, _ y: Int) -> LitV3 {
        let az = (Float(x) + 0.5) / Float(w) * 2 * azMax - azMax
        let v = (Float(y) + 0.5) / Float(h)
        let el = v * v * 1.45
        return LitV3(cosf(el) * sinf(az), sinf(el), cosf(el) * cosf(az))
    }

    /// A box blur, twice, into `out`: close to a gaussian of the given radii in map cells.
    func blurred(into out: LitEnvMap, rx: Int, ry: Int) {
        let w = self.w, h = self.h
        let tmp = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        defer { tmp.deallocate() }
        let src = p, dst = out.p
        memcpy(dst, src, w * h * MemoryLayout<LitV3>.stride)
        for _ in 0..<2 {
            litParallelFor(h, chunk: 8) { y in
                var acc = LitV3.zero
                let n = Float(2 * rx + 1)
                for i in -rx...rx { acc += dst[y * w + max(0, min(w - 1, i))] }
                for x in 0..<w {
                    tmp[y * w + x] = acc / n
                    acc += dst[y * w + min(w - 1, x + rx + 1)] - dst[y * w + max(0, x - rx)]
                }
            }
            litParallelFor(w, chunk: 8) { x in
                var acc = LitV3.zero
                let n = Float(2 * ry + 1)
                for i in -ry...ry { acc += tmp[max(0, min(h - 1, i)) * w + x] }
                for y in 0..<h {
                    dst[y * w + x] = acc / n
                    acc += tmp[min(h - 1, y + ry + 1) * w + x] - tmp[max(0, y - ry) * w + x]
                }
            }
        }
    }

    @inline(__always) func sample(_ d: LitV3) -> LitV3 {
        let az = atan2f(d.x, d.z)
        let el = asinf(max(0, min(1, d.y)))
        let u = max(0, min(Float(w) - 1.001, (az + azMax) / (2 * azMax) * Float(w) - 0.5))
        let v = max(0, min(Float(h) - 1.001, (el / 1.45).squareRoot() * Float(h) - 0.5))
        let ix = Int(u), iy = Int(v)
        let ax = u - Float(ix), ay = v - Float(iy)
        let i = iy * w + ix
        return litLerp(litLerp(p[i], p[i + 1], ax), litLerp(p[i + w], p[i + w + 1], ax), ay)
    }
}

// MARK: Near conifers: one painted spruce per tree, branch by branch, at the pixel size it will show

nonisolated struct LitTreeSprite: @unchecked Sendable {
    let w: Int, h: Int
    /// Where the foot of the trunk is, in sprite pixels.
    let baseX: Int, baseY: Int
    let cover: UnsafeMutablePointer<Float>
    let shade: UnsafeMutablePointer<Float>
    func free() { cover.deallocate(); shade.deallocate() }
}

nonisolated enum LitSpruce {
    private struct Branch { var y: Float, dirx: Float, depth: Float, len: Float, droop: Float, seed: UInt32 }

    static func raster(pixelHeight H: Float, seed: UInt32, slim: Float) -> LitTreeSprite {
        let spread = 0.30 * slim + 0.03
        let w = Int(2 * (spread * H).rounded(.up)) + 8
        // Low boughs droop past the foot of the trunk: they need rows below it, or the tree ends in a straight cut.
        let below = Int((H * 0.16).rounded(.up))
        let h = Int((H * 1.04).rounded(.up)) + 6 + below
        let baseX = w / 2, baseY = h - 3 - below
        let cover = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        let shade = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        cover.initialize(repeating: 0, count: w * h)
        shade.initialize(repeating: 0, count: w * h)
        var st = UInt64(seed) &* 0x9E37_79B9 &+ 11
        func rnd() -> Float {
            st &+= 0x9E37_79B9_7F4A_7C15
            var z = st
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(z >> 40) * (1.0 / 16777216.0)
        }
        func disc(_ cx: Float, _ cy: Float, _ r0: Float, _ sTop: Float, _ sBot: Float) {
            // Finer than a pixel: a fainter stroke rather than a stair-step.
            let r = max(0.55, r0)
            let gain = min(1, r0 / 0.55)
            let x0 = max(0, Int(cx - r - 1)), x1 = min(w - 1, Int(cx + r + 1))
            let y0 = max(0, Int(cy - r - 1)), y1 = min(h - 1, Int(cy + r + 1))
            if x0 > x1 || y0 > y1 { return }
            var y = y0
            while y <= y1 {
                var x = x0
                let dy = Float(y) + 0.5 - cy
                while x <= x1 {
                    let dx = Float(x) + 0.5 - cx
                    let d = (dx * dx + dy * dy).squareRoot()
                    let a = litSat(r - d + 0.5) * gain
                    if a > 0.001 {
                        let i = y * w + x
                        let tt = litSat(0.5 - 0.5 * dy / r)
                        let sv = sBot + (sTop - sBot) * tt
                        shade[i] += (sv - shade[i]) * a
                        cover[i] = 1 - (1 - cover[i]) * (1 - a)
                    }
                    x += 1
                }
                y += 1
            }
        }
        // The crown: whorls packed tighter towards the top, longest low down.
        var branches: [Branch] = []
        branches.reserveCapacity(400)
        var y = H * (0.05 + 0.05 * rnd())
        let lean = (rnd() - 0.5) * 0.03
        while y < H * 0.985 {
            let rel = y / H
            let lmax = H * (0.25 * slim * powf(1 - rel, 0.86) + 0.012)
            let nb = 4 + Int(rnd() * 3.5)
            for _ in 0..<nb {
                let phi = rnd() * 6.2831853
                var L = lmax * (0.62 + 0.55 * rnd())
                if rnd() < 0.1 { L *= 0.45 }
                let droop = (0.16 + 0.72 * powf(1 - rel, 1.2)) * (0.75 + 0.5 * rnd())
                branches.append(Branch(y: y, dirx: cosf(phi), depth: sinf(phi), len: L, droop: droop, seed: UInt32(truncatingIfNeeded: st)))
            }
            y += H * (0.011 + 0.014 * (1 - rel)) * (0.7 + 0.6 * rnd())
        }
        // Behind the trunk first, then the trunk, then what is in front of it.
        branches.sort { $0.depth < $1.depth }
        let bx = Float(baseX), by = Float(baseY)
        var trunkDone = false
        let pxPerStep: Float = max(0.8, H * 0.0035)
        for b in branches {
            if !trunkDone && b.depth >= 0 {
                trunkDone = true
                let n = Int(H)
                for i in stride(from: 0, to: n, by: 2) {
                    let t = Float(i) / H
                    disc(bx + lean * t * H, by - t * H, H * 0.0085 * (1 - t) + 0.3, 0.1, 0.04)
                }
            }
            let rel = b.y / H
            let cx0 = bx + lean * rel * H, cy0 = by - b.y
            let steps = max(3, Int(abs(b.dirx) * b.len / pxPerStep) + 2)
            let front = b.depth > 0 ? 1 + 0.35 * b.depth : 1 + 0.55 * b.depth
            let side: Float = b.dirx < 0 ? 1.18 : 0.9
            let wob = (rnd() - 0.5) * 0.08
            var s = 0
            while s <= steps {
                let u = Float(s) / Float(steps)
                let px = cx0 + b.dirx * b.len * u
                let py = cy0 + b.len * b.droop * powf(u, 1.25) - b.len * 0.2 * u * u * u + b.len * wob * u
                let r = H * 0.0036 * (1 - 0.66 * u) * (0.6 + 0.7 * (1 - rel)) + 0.2
                let lit = (0.10 + 0.62 * u) * front * side
                disc(px, py, r, lit, lit * 0.28)
                // Twigs hanging from the branch make the feathered edge.
                if rnd() < 0.62 {
                    let tl = b.len * (0.09 + 0.15 * rnd()) * (1 - 0.45 * u) + 0.8
                    let lean2 = b.dirx * (0.12 + 0.35 * rnd()) + (rnd() - 0.5) * 0.4
                    let ts = max(2, Int(tl / max(0.8, pxPerStep)))
                    for k in 1...ts {
                        let v = Float(k) / Float(ts)
                        disc(px + lean2 * tl * v, py + tl * v, (0.34 + H * 0.0011) * (1.1 - 0.7 * v), lit * 0.95, lit * 0.35)
                    }
                }
                s += 1
            }
        }
        return LitTreeSprite(w: w, h: h, baseX: baseX, baseY: baseY, cover: cover, shade: shade)
    }
}

/// Column-wise running totals over a picture: a vertical blur of any radius costs one subtraction.
nonisolated struct LitColumnSAT: @unchecked Sendable {
    let w: Int, h: Int
    let s: UnsafeMutablePointer<LitV3>
    init(_ src: UnsafePointer<LitV3>, w: Int, h: Int) {
        self.w = w; self.h = h
        s = .allocate(capacity: w * (h + 1))
        let s = self.s
        litParallelFor(w, chunk: 16) { x in
            var acc = LitV3.zero
            s[x] = acc
            for y in 0..<h {
                acc += src[y * w + x]
                s[(y + 1) * w + x] = acc
            }
        }
    }
    func free() { s.deallocate() }

    /// Mean over [v - r, v + r] in column u; u, v in pixels (pixel centres at .5).
    @inline(__always) func blur(u: Float, v: Float, r: Float) -> LitV3 {
        let cu = max(0, min(Float(w) - 1.001, u - 0.5))
        let iu = Int(cu)
        let au = cu - Float(iu)
        let a = column(iu, v, r), b = column(iu + 1, v, r)
        return litLerp(a, b, au)
    }

    @inline(__always) private func column(_ x: Int, _ v: Float, _ r0: Float) -> LitV3 {
        let r = max(0.5, r0)
        let fh = Float(h)
        let top = max(0, min(fh, v - r)), bot = max(0, min(fh, v + r))
        if bot - top < 0.01 {
            let y = min(h - 1, max(0, Int(v)))
            return s[(y + 1) * w + x] - s[y * w + x]
        }
        return (cum(x, bot) - cum(x, top)) / (bot - top)
    }

    @inline(__always) private func cum(_ x: Int, _ y: Float) -> LitV3 {
        let iy = min(h - 1, Int(y))
        let a = y - Float(iy)
        let c0 = s[iy * w + x], c1 = s[(iy + 1) * w + x]
        return c0 + (c1 - c0) * a
    }
}

nonisolated enum LitAA {
    /// Marks land pixels whose light differs from a neighbour by more than a quarter: snow edges and shadow edges. Read-only, so the result does not depend on thread timing.
    static func contrast(_ hdr: UnsafePointer<LitV3>, depth: UnsafePointer<Float>, w: Int, h: Int, enabled: Bool, threshold: Float = 0.3) -> UnsafeMutablePointer<UInt8> {
        let hot = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        hot.initialize(repeating: 0, count: w * h)
        if !enabled { return hot }
        litParallelFor(h, chunk: 8) { y in
            for x in 0..<w {
                let i = y * w + x
                let d = depth[i]
                if d <= 0 || d == .infinity { continue }
                let l0 = litLuma(hdr[i])
                var m: Float = 0
                if x > 0 { m = max(m, abs(litLuma(hdr[i - 1]) - l0) / max(1e-5, max(l0, litLuma(hdr[i - 1])))) }
                if x < w - 1 { m = max(m, abs(litLuma(hdr[i + 1]) - l0) / max(1e-5, max(l0, litLuma(hdr[i + 1])))) }
                if y > 0 { m = max(m, abs(litLuma(hdr[i - w]) - l0) / max(1e-5, max(l0, litLuma(hdr[i - w])))) }
                if y < h - 1 { m = max(m, abs(litLuma(hdr[i + w]) - l0) / max(1e-5, max(l0, litLuma(hdr[i + w])))) }
                if m > threshold { hot[i] = 1 }
            }
        }
        return hot
    }
}

// MARK: LitAmbient light as first-order spherical harmonics

nonisolated struct LitAmbient: Sendable {
    var a0 = LitV3.zero, ax = LitV3.zero, ay = LitV3.zero, az = LitV3.zero
    @inline(__always) func irradiance(_ n: LitV3) -> LitV3 {
        simd_max(LitV3.zero, a0 + ax * n.x + ay * n.y + az * n.z)
    }
    /// From the clear sky over ground of radiance `ground`.
    init(atmos: LitAtmosphere, ground: LitV3, radiance: ((LitV3) -> LitV3)? = nil) {
        let N = 400
        var c0 = LitV3.zero, cx = LitV3.zero, cy = LitV3.zero, cz = LitV3.zero
        for i in 0..<N {
            let y = 1 - (Float(i) + 0.5) / Float(N) * 2
            let r = max(0, 1 - y * y).squareRoot()
            let phi = Float(i) * 2.399963
            let d = LitV3(r * cosf(phi), y, r * sinf(phi))
            let L = y > 0 ? (radiance?(d) ?? atmos.sky(d)) : ground
            c0 += L; cx += L * d.x; cy += L * d.y; cz += L * d.z
        }
        let dw = 4 * Float.pi / Float(N)
        a0 = c0 * dw / 4
        ax = cx * dw / 2; ay = cy * dw / 2; az = cz * dw / 2
    }
    func scaled(_ k: Float) -> LitAmbient {
        var c = self
        c.a0 *= k; c.ax *= k; c.ay *= k; c.az *= k
        return c
    }
}

nonisolated struct LitCamera: Sendable {
    var ro: LitV3
    var f: Float
    var cx: Float
    var horizon: Float
    @inline(__always) func dir(_ px: Float, _ py: Float) -> LitV3 {
        litNorm3(LitV3((px - cx) / f, (horizon - py) / f, 1))
    }
}

// MARK: How the land is painted

nonisolated struct LitLandLook: Sendable {
    var snowLine: Float
    var snowBand: Float = 420
    var treeLine: Float = 900
    var seed: UInt32 = 77
    var rockWarm = LitV3(0.17, 0.155, 0.14)
    var rockCool = LitV3(0.078, 0.084, 0.094)
    var scree = LitV3(0.20, 0.19, 0.175)
    var snow = LitV3(0.80, 0.82, 0.85)
    var bump: Float = 1
    var strata: Float = 0.18
    var snowRelief: Float = 1.2
    var edgeScale: Float = 1
    var shoreTop: Float = 0
    var facetBig: Float = 0.42
    var facetSmall: Float = 0.24
    /// Above 0 ledges hold more snow on a face, below 0 less.
    var ledgeBias: Float = 0.05
}

nonisolated struct LitLightRig: Sendable {
    var sun: LitV3
    var ambient: LitAmbient
    /// Warm bounce from lit ground into shadow, as a colour multiplied by the sun's.
    var bounce: Float = 0.25
}

nonisolated enum LitLand {
    /// Broken rock: nearest of a jittered lattice, each cell a plane with its own tilt. x, z: slope; z-channel of the result: tone.
    @inline(__always) static func facet(_ x: Float, _ z: Float, lambda: Float, seed: UInt32) -> LitV3 {
        let qx = (x * 0.86 + z * 0.3) / lambda, qz = (-x * 0.3 + z * 0.86) / (lambda * 0.7)
        let fx = qx.rounded(.down), fz = qz.rounded(.down)
        let ix = Int32(fx), iz = Int32(fz)
        var best: Float = 9
        var pick: UInt32 = 0
        var dz: Int32 = -1
        while dz <= 1 {
            var dx: Int32 = -1
            while dx <= 1 {
                let h = litHash32(ix + dx, iz + dz, seed)
                let cx = Float(ix + dx) + Float(h & 0x3FF) / 1024
                let cz = Float(iz + dz) + Float((h >> 10) & 0x3FF) / 1024
                let d = (qx - cx) * (qx - cx) + (qz - cz) * (qz - cz)
                if d < best { best = d; pick = h }
                dx += 1
            }
            dz += 1
        }
        let h2 = pick &* 0x9E37_79B1
        return LitV3(Float(h2 & 0xFF) / 128 - 1, Float((h2 >> 8) & 0xFF) / 128 - 1, Float((h2 >> 16) & 0xFF) / 128 - 1)
    }

    /// Tree canopy above the ground at (x, z); 0 outside a tree. Conifer: tiered cone.
    @inline(__always) static func tree(_ x: Float, _ z: Float, mask: Float, seed: UInt32) -> Float {
        if mask < 0.02 { return 0 }
        let cell: Float = 8.5
        let gx = x / cell, gz = z / cell
        // Stands of an age: tall old timber next to young growth, with clearings.
        let age = litGnoise(x / 95, z / 95, seed &+ 9)
        let stand = 0.62 + 0.86 * litSat(0.5 + age * 1.5)
        let gapN = litGnoise(x / 41, z / 41, seed &+ 10)
        if gapN > 0.42 - 0.2 * mask { return 0 }
        let fx = gx.rounded(.down), fz = gz.rounded(.down)
        let ix = Int32(fx), iz = Int32(fz)
        var best: Float = 0
        var dz: Int32 = -1
        while dz <= 1 {
            var dx: Int32 = -1
            while dx <= 1 {
                let h = litHash32(ix + dx, iz + dz, seed)
                // Thinner forest at its edge.
                if litUnit(h) * 0.85 + 0.15 < mask * 1.15 {
                    let h2 = h &* 0x9E37_79B1
                    let px = (Float(ix + dx) + 0.15 + 0.7 * Float(h2 & 0xFFF) / 4096) * cell
                    let pz = (Float(iz + dz) + 0.15 + 0.7 * Float((h2 >> 12) & 0xFFF) / 4096) * cell
                    let tall = (14 + 20 * Float(h2 >> 24) / 256) * (0.55 + 0.45 * mask) * stand
                    let R = tall * 0.21
                    let ddx = x - px, ddz = z - pz
                    let d2 = ddx * ddx + ddz * ddz
                    if d2 < R * R * 1.6 {
                        let d = d2.squareRoot()
                        // Branches: the radius wobbles around the trunk.
                        let w = litGnoise(x * 1.1, z * 1.1, seed &+ 5)
                        let u = d / (R * (0.92 + 0.38 * w))
                        if u < 1 {
                            let yn = 1 - u
                            let N: Float = 7
                            let q = yn * N
                            let tier = q.rounded(.down)
                            let fr = q - tier
                            let stepped = (tier + fr * fr * fr) / N
                            best = max(best, tall * powf(stepped, 0.92))
                        }
                    }
                }
                dx += 1
            }
            dz += 1
        }
        return best
    }

    /// Radiance leaving the land at p.
    static func shade(layer L: LitHeightLayer, p: LitV3, rd: LitV3, t: Float, pixel: Float, atmos A: LitAtmosphere, rig: LitLightRig, look: LitLandLook) -> LitV3 {
        let facetBig = look.facetBig, facetSmall = look.facetSmall
        let c = L.cell
        let x = p.x, z = p.z
        let hC = L.hAt(x, z)
        var fmask: Float = 0
        if let f = L.forest { fmask = L.field(f, L.aoN, x, z) }
        let shadowV = L.field(L.shadow, L.n, x, z)
        let vis = L.field(L.ao, L.aoN, x, z)
        let sunCol = A.sunColor(y: p.y)
        // Tree?
        if fmask > 0.02 && p.y > hC + 0.25 && t < 5200 {
            let e: Float = max(0.25, pixel)
            let tx = tree(x + e, z, mask: fmask, seed: look.seed) - tree(x - e, z, mask: fmask, seed: look.seed)
            let tz = tree(x, z + e, mask: fmask, seed: look.seed) - tree(x, z - e, mask: fmask, seed: look.seed)
            var n = litNorm3(LitV3(-tx / (2 * e), 1, -tz / (2 * e)))
            let y = p.y - hC
            let h = litHash32(Int32((x / 8.5).rounded(.down)), Int32((z / 8.5).rounded(.down)), look.seed &+ 3)
            // Stands differ: darker spruce, paler larch and birch in clumps, a few bright tips.
            let clump = litFbm(x / 70, z / 70, 2, look.seed &+ 7)
            let tint = (0.72 + 0.56 * litUnit(h)) * (0.85 + 0.5 * litSat(clump + 0.5))
            let pale = litSat((clump - 0.18) * 3) * 0.55
            let needle = 0.6 + 0.8 * litSat(0.5 + 0.8 * litFbm(x * 1.7, z * 1.7 + y * 1.1, 2, 91))
            n = litNorm3(n + LitV3(0, 0.25, 0))
            let albedo = litLerp(LitV3(0.042, 0.072, 0.044), LitV3(0.085, 0.105, 0.05), pale) * tint * needle
            // Deep in the stand it is dark; tips catch light.
            let lift = litSat(y / 26)
            let ao = (0.20 + 0.8 * lift * lift) * (0.5 + 0.5 * vis)
            let ndl = max(0, litDot3(n, rig.sun) * 0.8 + 0.2)
            let direct = sunCol * (ndl * shadowV * (0.35 + 0.65 * lift))
            let amb = rig.ambient.irradiance(n) * ao
            return albedo * (direct + amb) * (1 / Float.pi)
        }
        let seed = look.seed
        // Ground normal, from the grid: the light works on real shapes.
        let hx = L.hAt(x + c, z) - L.hAt(x - c, z)
        let hz = L.hAt(x, z + c) - L.hAt(x, z - c)
        let nGrid = litNorm3(LitV3(-hx / (2 * c), 1, -hz / (2 * c)))
        let steep = (1 - nGrid.y * nGrid.y).squareRoot()
        let alt = p.y
        let w2 = c * 1.5
        let avg2 = (L.hAt(x + w2, z) + L.hAt(x - w2, z) + L.hAt(x, z + w2) + L.hAt(x, z - w2)) * 0.25
        let cav = (hC - avg2) / w2
        let flow = L.field(L.flow, L.aoN, x, z)
        var cv: Float = 0
        if let cf = L.curve { cv = L.field(cf, L.aoN, x, z) }
        // Noise coordinates that follow the view: across and up the face. On steep ground plain x-z noise
        // stretches into vertical hair; this mapping cannot collapse on any surface the camera can see.
        let qx = x * 0.55, qz = hC + z * 0.5

        // Rock. Tone comes from whole formations and from the shape of the ground, not from a repeating blotch.
        let nA = litFbm(x / 900, z / 900, 3, seed &+ 11)
        let nF = litFbm(qx / 210, qz / 150, 3, seed &+ 12)
        let nC = litFbm(qx / 46, qz / 30, 3, seed &+ 13)
        let bedY = p.y + x * 0.10 - z * 0.05 + nA * 70 + nF * 12
        var rock = litLerp(look.rockCool, look.rockWarm, litSat(0.5 + nA * 1.3 + nF * 1.1))
        var tone: Float = 1 + 0.30 * nF + 0.20 * nC + 0.42 * cv
        // Bedding, only on real cliffs.
        let steepBed = litSstep(0.72, 0.88, steep)
        tone += look.strata * steepBed * litGnoise(bedY / 37, 3.1, seed &+ 14)
        // Dark cracks: bedding planes and cross joints, broken up, never finer than the screen shows.
        let w = max(1.6, pixel * 0.8)
        var crack: Float = 0
        if pixel < 26 {
            let fadeC = litSat((26 - pixel) / 14) * look.bump
            let jv = (x * 0.8 - z * 0.6 + 18 * nC + 9 * litGnoise(qx / 14, qz / 14, seed &+ 41)) / 58
            let jfr = abs(jv - jv.rounded()) * 58
            let gateJ = litSstep(-0.05, 0.25, litFbm(qx / 70, qz / 24, 2, seed &+ 42))
            let lineJ = (1 - litSstep(w * 0.4, w * 1.6, jfr)) * gateJ
            let bq = (bedY + 6 * litGnoise(qx / 18, qz / 18, seed &+ 43)) / 41
            let bfr = abs(bq - bq.rounded()) * 41
            let gateB = litSstep(-0.1, 0.2, litFbm(qx / 26, qz / 90, 2, seed &+ 44))
            let lineB = (1 - litSstep(w * 0.4, w * 1.6, bfr)) * gateB
            crack = max(lineJ, lineB * 0.8) * fadeC * litSat(steep * 1.6)
            tone *= 1 - 0.5 * crack
        }
        // Water stains down the fall line.
        tone *= 1 - 0.20 * litSat(flow / 80)
        // Broken rock: planes with their own tilt and tone, and sharp edges between them; never smaller than the screen shows.
        var n0 = nGrid
        if look.bump > 0 && pixel < 60 {
            let fade = look.bump * litSat((60 - pixel) / 30)
            let f1 = facet(qx, qz, lambda: max(30, pixel * 6), seed: seed &+ 34)
            let f2 = facet(qx + 13, qz - 7, lambda: max(11, pixel * 2.6), seed: seed &+ 35)
            n0 = litNorm3(nGrid + LitV3((f1.x * facetBig + f2.x * facetSmall) * fade, 0, (f1.y * facetBig + f2.y * facetSmall) * fade))
            tone *= 1 + (f1.z * 0.13 + f2.z * 0.08) * fade
        }
        rock = rock * max(0.25, tone)
        rock = simd_max(rock, LitV3(repeating: 0.008))

        // Scree: pale, loose, even.
        var albedo = rock
        if let sc = L.scree {
            let dp = L.field(sc, L.aoN, x, z)
            if dp > 0.05 {
                let k = litSstep(0.3, 3.0, dp + nC * 1.5) * (1 - litSstep(0.75, 0.92, steep))
                let grain = 0.85 + 0.35 * litSat(0.5 + litFbm(qx / 6, qz / 6, 2, seed &+ 45))
                albedo = litLerp(albedo, look.scree * grain * (0.85 + 0.5 * litSat(nF + 0.5)), k)
            }
        }

        // Lower ground: meadow, forest.
        let tl = look.treeLine + nA * 180
        let meadowA = (1 - litSstep(tl + 160, tl + 620, alt + nC * 60)) * (1 - litSstep(0.55, 0.85, steep))
        let meadow = litLerp(LitV3(0.15, 0.17, 0.065), LitV3(0.10, 0.125, 0.045), litSat(0.5 + nC * 1.4))
        albedo = litLerp(albedo, meadow, meadowA)
        // Distant forest as tone, where single trees are below a pixel.
        if fmask > 0.02 {
            let mott = 0.65 + 0.7 * litSat(0.5 + litFbm(x / 26, z / 26, 2, seed &+ 21) * 1.5)
            albedo = litLerp(albedo, LitV3(0.044, 0.074, 0.044) * mott, litSat(fmask * 1.3))
        }
        // Pale gravel at the water's edge.
        if alt < look.shoreTop {
            albedo = litLerp(albedo, LitV3(0.26, 0.245, 0.22) * (0.8 + 0.5 * litSat(0.5 + nC)), 1 - litSstep(look.shoreTop * 0.5, look.shoreTop, alt))
        }

        // Snow: the pack's edge is measured in metres of ground and broken at three sizes, with rock showing through where it is thin.
        var snowA: Float = 0
        var edgeDist: Float = 99
        if let sn = L.snow {
            let sd = L.field(sn, L.n, x, z)
            if sd > -45 {
                let e = c * 1.5
                let gx = (L.field(sn, L.n, x + e, z) - L.field(sn, L.n, x - e, z)) / (2 * e)
                let gz = (L.field(sn, L.n, x, z + e) - L.field(sn, L.n, x, z - e)) / (2 * e)
                let gm = max(0.07, (gx * gx + gz * gz).squareRoot())
                let wa = litFbm(qx / 110, qz / 80, 2, seed &+ 51) * 34
                let wb = litFbm(qx / 110 + 7, qz / 80, 2, seed &+ 52) * 34
                let e1 = litFbm((qx + wa) / 74, (qz + wb) / 52, 3, seed &+ 53)
                let e2 = litFbm((qx + wb * 0.5) / 21, (qz + wa * 0.5) / 15, 3, seed &+ 54)
                let e3 = litFbm(qx / 6.5, qz / 4.6, 2, seed &+ 55)
                // A sharp edge in the depth field (a ledge) keeps its shape; a soft one (a field) is torn by the noise.
                let tear = litSat(0.14 / gm)
                // On a face the grid stretches everything downhill, so the pack's edge would run in streaks. Snow lies on ramps: long ledges a little off level,
                // leaning one way on this buttress and the other on the next, as dipping beds do. Only the margin of the pack is broken; a deep field stays a field.
                var dist = sd / gm + look.edgeScale * (e1 * 34 * tear + e2 * 15 * tear + e3 * 5)
                let onFace = litSstep(0.72, 0.92, steep)
                if onFace > 0.01 && dist > -70 && dist < 70 {
                    let lq = p.y + e1 * 14
                    let ra = qx * 0.84 + lq * 0.54, rb = qx * 0.84 - lq * 0.54
                    let which = litSstep(-0.06, 0.06, litFbm(qx / 340, lq / 300, 2, seed &+ 59))
                    let lean = litLerp(litFbm(ra / 150 + 3, rb / 19, 2, seed &+ 57), litFbm(rb / 150 + 7, ra / 19, 2, seed &+ 58), which)
                    let near = 1 - litSstep(18, 70, abs(dist))
                    dist += 40 * onFace * near * (lean + look.ledgeBias)
                }
                edgeDist = dist
                let ww = max(0.9, pixel * 0.9)
                snowA = litSstep(-ww, ww, dist)
                // Thin snow: a dusting that lets dark rock through, for a few metres either side of the edge.
                if dist > -30 && dist < 34 {
                    let thin = litSat(sd / 1.5 + 0.35)
                    let speck = litFbm(qx / 3.2, qz / 2.6, 2, seed &+ 56) * 0.9 + e3 * 0.5
                    let dust = litSstep(-0.05, 0.3, speck + (thin - 0.55) * 1.3)
                    snowA = max(snowA * (0.25 + 0.75 * dust), 0.4 * dust * (1 - litSstep(4, 16, -dist)) * thin)
                }
            }
        }

        // Its own relief: flutes and wind-carved swells.
        var nSnow = nGrid
        var snowTone: Float = 1
        if snowA > 0.01 {
            let sc: Float = max(90, pixel * 3)
            let e: Float = 0.45
            let sq: Float = sc * 2.0
            let s0 = litFbm(qx / sc, qz / sq, 2, seed &+ 33)
            let s1 = litFbm((qx + e * sc) / sc, qz / sq, 2, seed &+ 33)
            let s2 = litFbm(qx / sc, (qz + e * sq) / sq, 2, seed &+ 33)
            nSnow = litNorm3(nGrid + LitV3(-(s1 - s0) * look.snowRelief, 0, -(s2 - s0) * look.snowRelief))
            // Dirtier and greyer next to rock; a little uneven all over.
            snowTone = 0.93 + 0.07 * litSat(0.5 + nF) - 0.35 * (1 - litSstep(3, 16, edgeDist))
        }
        albedo = litLerp(albedo, look.snow * snowTone, snowA)
        let n = litNorm3(litLerp(n0, nSnow, snowA))
        let ndl = max(0, litDot3(n, rig.sun))
        let cavity = litSat(1 + cav * 1.4 * (1 - snowA * 0.8))
        // Snow throws light on itself: its hollows never go as dark as rock's.
        let aoRock = vis * (0.55 + 0.45 * cavity)
        let aoSnow = powf(vis, 0.55) * (0.8 + 0.2 * cavity)
        let ao = litLerp(aoRock, aoSnow, snowA)
        var direct = sunCol * (ndl * shadowV)
        let backlit = powf(max(0, litDot3(rd, rig.sun)), 3) * snowA * 0.25
        direct += sunCol * (backlit * shadowV)
        let sky = rig.ambient.irradiance(n) * ao
        // Light bounced off the sunlit land opposite.
        let bounceAmount = (1 - vis) * rig.bounce * (0.35 + 0.65 * shadowV * 0.5)
        let bounce = sunCol * (max(0, rig.sun.y + 0.15) * bounceAmount)
        return albedo * (direct + sky + bounce * litLerp(LitV3(0.55, 0.5, 0.45), LitV3(1, 1, 1), snowA)) * (1 / Float.pi)
    }
}

// MARK: LitPost

nonisolated struct LitGrade: Sendable {
    var exposure: Float = 1
    var saturation: Float = 1
    var lift = LitV3.zero
    var gamma = LitV3(1, 1, 1)
    var gain = LitV3(1, 1, 1)
    var vignette: Float = 0.18
    var bloom: Float = 0.04
    var grain: Float = 0.006
    var ceiling: Float = 1
    /// Colour of the light before the film curve; night pictures lean blue here.
    var tint = LitV3(1, 1, 1)
    /// Night vision: colour drains towards grey before the tint, so moonlight never reads cream or olive.
    var night: Float = 0
    /// Local contrast put back after the enlargement.
    var sharpen: Float = 0.45
}

nonisolated enum LitPost {
    /// Bloom, film curve and grade on the canvas; then a touch of sharpening, a smooth enlargement in display space (so bright edges do not ring), and dither at the final size.
    static func finish(hdr: UnsafeMutablePointer<LitV3>, w: Int, h: Int, outW: Int, outH: Int, grade: LitGrade, seed: UInt32) -> CGImage? {
        // Bloom: quarter-size, wide gaussian in two passes.
        let bw = max(4, w / 4), bh = max(4, h / 4)
        let small = UnsafeMutablePointer<LitV3>.allocate(capacity: bw * bh)
        let tmp = UnsafeMutablePointer<LitV3>.allocate(capacity: bw * bh)
        defer { small.deallocate(); tmp.deallocate() }
        litParallelFor(bh, chunk: 8) { y in
            for x in 0..<bw {
                var s = LitV3.zero
                let x0 = x * w / bw, y0 = y * h / bh
                let x1 = max(x0 + 1, (x + 1) * w / bw), y1 = max(y0 + 1, (y + 1) * h / bh)
                var yy = y0
                while yy < y1 {
                    var xx = x0
                    while xx < x1 { s += hdr[yy * w + xx]; xx += 1 }
                    yy += 1
                }
                s /= Float((x1 - x0) * (y1 - y0))
                // Only what is really bright glows.
                let l = litLuma(s) * grade.exposure
                let k = litSat((l - 0.9) / 1.2)
                small[y * bw + x] = simd_min(s * k, LitV3(repeating: 40))
            }
        }
        // The width comes from the output, in proportion, so a picture glows alike at every size.
        let radius = max(2, bw / 22)
        var weights = [Float](repeating: 0, count: radius * 2 + 1)
        for i in -radius...radius { let v = Float(i) / (Float(radius) * 0.5); weights[i + radius] = expf(-v * v) }
        let sumW = weights.reduce(0, +)
        for i in weights.indices { weights[i] /= sumW }
        weights.withUnsafeBufferPointer { wp in
            litParallelFor(bh, chunk: 8) { y in
                for x in 0..<bw {
                    var s = LitV3.zero
                    for i in -radius...radius { s += small[y * bw + min(bw - 1, max(0, x + i))] * wp[i + radius] }
                    tmp[y * bw + x] = s
                }
            }
            litParallelFor(bw, chunk: 8) { x in
                for y in 0..<bh {
                    var s = LitV3.zero
                    for i in -radius...radius { s += tmp[min(bh - 1, max(0, y + i)) * bw + x] * wp[i + radius] }
                    small[y * bw + x] = s
                }
            }
        }
        let aspect = Float(h) / Float(w)
        // Film curve and grade, canvas pixel by canvas pixel, in place.
        litParallelFor(h, chunk: 8) { y in
            let v = (Float(y) + 0.5) / Float(h)
            for x in 0..<w {
                let i = y * w + x
                var c = hdr[i]
                let bu: Float = (Float(x) + 0.5) / Float(w) * Float(bw) - 0.5
                let bv: Float = (Float(y) + 0.5) / Float(h) * Float(bh) - 0.5
                let bxF: Float = min(Float(bw) - 1.001, max(0, bu))
                let byF: Float = min(Float(bh) - 1.001, max(0, bv))
                let bi = Int(bxF), bj = Int(byF)
                let bax = bxF - Float(bi), bay = byF - Float(bj)
                let b0 = litLerp(small[bj * bw + bi], small[bj * bw + bi + 1], bax)
                let b1 = litLerp(small[(bj + 1) * bw + bi], small[(bj + 1) * bw + bi + 1], bax)
                c += litLerp(b0, b1, bay) * grade.bloom
                let u = (Float(x) + 0.5) / Float(w)
                let dx = (u - 0.5) * 1.0, dy = (v - 0.5) * aspect * 0.62
                let vig = 1 - grade.vignette * litSat((dx * dx + dy * dy) * 2.6)
                if grade.night > 0 { c = litLerp(c, LitV3(repeating: litDot3(c, LitV3(0.2126, 0.7152, 0.0722))), grade.night) }
                c = c * grade.tint * (grade.exposure * vig)
                var f = litAcesFilm(c)
                f = simd_max(f, LitV3.zero)
                let lum = litLuma(f)
                f = LitV3(repeating: lum) + (f - LitV3(repeating: lum)) * grade.saturation
                f = simd_max(f, LitV3.zero)
                f = LitV3(powf(f.x, grade.gamma.x), powf(f.y, grade.gamma.y), powf(f.z, grade.gamma.z))
                f = grade.lift + f * grade.gain
                var r = litToSRGB(f.x), g = litToSRGB(f.y), b = litToSRGB(f.z)
                if grade.ceiling < 1 {
                    // A soft shoulder: highlights roll off below the ceiling instead of clipping flat.
                    let cc = grade.ceiling, k0 = cc * 0.6
                    @inline(__always) func soft(_ v: Float) -> Float { v <= k0 ? v : k0 + (cc - k0) * (1 - expf(-(v - k0) / (cc - k0))) }
                    r = soft(r); g = soft(g); b = soft(b)
                }
                hdr[i] = LitV3(r, g, b)
            }
        }
        let same = w == outW && h == outH
        // A small unsharp mask: what an enlargement softens, the local contrast gives back. Limited, so it cannot draw halos.
        var disp = UnsafeMutablePointer<LitV3>(hdr)
        var ownDisp: UnsafeMutablePointer<LitV3>? = nil
        defer { ownDisp?.deallocate() }
        if !same && grade.sharpen > 0 {
            let sh = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
            ownDisp = sh
            let k = grade.sharpen
            let src = hdr
            litParallelFor(h, chunk: 16) { y in
                let ym = max(0, y - 1), yp = min(h - 1, y + 1)
                for x in 0..<w {
                    let xm = max(0, x - 1), xp = min(w - 1, x + 1)
                    let c = src[y * w + x]
                    var bl = c * 0.25
                    bl += (src[y * w + xm] + src[y * w + xp] + src[ym * w + x] + src[yp * w + x]) * 0.125
                    bl += (src[ym * w + xm] + src[ym * w + xp] + src[yp * w + xm] + src[yp * w + xp]) * 0.0625
                    let d = litLuma(c) - litLuma(bl)
                    let dl = max(-0.07, min(0.07, d * k))
                    sh[y * w + x] = simd_max(LitV3.zero, c + LitV3(repeating: dl))
                }
            }
            disp = sh
        }
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bpr * outH)
        let scaleX = Float(w) / Float(outW), scaleY = Float(h) / Float(outH)
        let source = UnsafePointer<LitV3>(disp)
        litParallelFor(outH, chunk: 8) { oy in
            let sy = (Float(oy) + 0.5) * scaleY - 0.5
            let fy = sy.rounded(.down)
            let iy = Int(fy)
            let wy = catrom(sy - fy)
            for ox in 0..<outW {
                var c: LitV3
                if same {
                    c = source[oy * w + ox]
                } else {
                    let sx = (Float(ox) + 0.5) * scaleX - 0.5
                    let fx = sx.rounded(.down)
                    let ix = Int(fx)
                    let wx = catrom(sx - fx)
                    c = .zero
                    for j in 0..<4 {
                        let yy = min(h - 1, max(0, iy + j - 1))
                        var row = LitV3.zero
                        for i in 0..<4 {
                            row += source[yy * w + min(w - 1, max(0, ix + i - 1))] * wx[i]
                        }
                        c += row * wy[j]
                    }
                }
                // Triangular dither + a whisper of film grain.
                let hd = litHash32(Int32(truncatingIfNeeded: ox), Int32(truncatingIfNeeded: oy), seed)
                let hd2 = (hd ^ (hd >> 11)) &* 0x9E37_79B1
                let n1 = Float(hd2 >> 16) / 65536
                let n2 = Float(hd2 & 0xFFFF) / 65536
                let d = (n1 + n2 - 1)
                let gr = d * grade.grain + d * 0.75 / 255
                let i = oy * bpr + ox * 4
                pixels[i] = UInt8(min(255, max(0, (c.x + gr) * 255 + 0.5)))
                pixels[i + 1] = UInt8(min(255, max(0, (c.y + gr) * 255 + 0.5)))
                pixels[i + 2] = UInt8(min(255, max(0, (c.z + gr) * 255 + 0.5)))
                pixels[i + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    @inline(__always) static func catrom(_ t: Float) -> SIMD4<Float> {
        let t2 = t * t, t3 = t2 * t
        return SIMD4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
    }
}

// MARK: Scene: mountain lake

/// How large a canvas a picture is computed on, and how fine its world is. The canvas is capped: the cost of a picture does not grow past phone size,
/// a larger output is an enlargement.
nonisolated struct LitPlan: Sendable {
    let outW: Int, outH: Int
    let w: Int, h: Int
    /// 0: a picker tile; 1: small; 2: full size.
    var tier: Int
    /// Canvas pixels above which the world stops getting finer.
    static let maxCanvas: Float = 1_060_000
    init(width: Int, height: Int, canvas: Float = LitPlan.maxCanvas) {
        outW = width; outH = height
        let px = Float(width) * Float(height)
        let k = min(1, (canvas / px).squareRoot())
        w = max(1, Int((Float(width) * k).rounded()))
        h = max(1, Int((Float(height) * k).rounded()))
        let cpx = w * h
        tier = cpx < 170_000 ? 0 : (cpx < 500_000 ? 1 : 2)
    }
    /// The same picture on a larger canvas, for a scene that has budget to spare.
    func enlarged(_ k: Float) -> LitPlan {
        var p = LitPlan(width: outW, height: outH, canvas: LitPlan.maxCanvas * k)
        p.tier = tier
        return p
    }
    /// A smaller canvas for a tile, on the same terrain grids: the enlargement hides it and the budget needs it.
    func tileCanvas(_ area: Float) -> LitPlan {
        if tier != 0 { return self }
        var p = LitPlan(width: outW, height: outH, canvas: Float(outW) * Float(outH) * area)
        p.tier = tier
        return p
    }
    var grid: (maxN: Int, erodeN: Int) { tier == 2 ? (1025, 1025) : (tier == 1 ? (513, 513) : (257, 257)) }
}

nonisolated enum LitArt {
    static func render(scene: String, width: Int, height: Int, dark: Bool) -> CGImage? {
        guard width >= 1, height >= 1 else { return nil }
        let plan = LitPlan(width: width, height: height)
        switch scene {
        case "photoLake": return lake(plan, dark: dark)
        case "photoOcean": return ocean(plan.tileCanvas(0.78), dark: dark)
        case "photoClouds": return deck(plan.tier == 0 ? plan.tileCanvas(0.60) : plan.enlarged(0.90), dark: dark)
        case "photoAlpenglow": return alpenglow(plan.tileCanvas(0.8), dark: dark)
        case "photoCanyon": return canyon(plan, dark: dark)
        case "photoDunes": return dunes(plan, dark: dark)
        case "photoForest": return forest(plan, dark: dark)
        case "photoAurora": return aurora(plan, dark: dark)
        default: return nil
        }
    }

    static func lake(_ plan0: LitPlan, dark: Bool) -> CGImage? {
        let plan = plan0.tileCanvas(0.68)
        let w = plan.w, h = plan.h, tier = plan.tier
        let unitS = Float(min(w, h))
        let (maxN, erodeN) = plan.grid

        let seed: UInt32 = 4242
        let shoreZ: @Sendable (Float) -> Float = { x in
            let wob = litGnoise(x / 620, 3.3, seed) * 150 + litGnoise(x / 170, 9.1, seed) * 40
            let v = x < 0 ? 0.85 * max(0, -x - 60) : 0.55 * max(0, x - 120)
            return 980 + wob - min(620, v)
        }
        // A massif, not a cone: a long summit ridge with shoulders, a ridge out of frame to the left that throws the valley into shade.
        let peaks: [LitPeak] = [
            LitPeak(x: -300, z: 6400, h: 1.00, r: 4200, power: 1.05),
            LitPeak(x: 1500, z: 7000, h: 0.82, r: 3000, power: 1.1),
            LitPeak(x: -1900, z: 7100, h: 0.84, r: 2900, power: 1.1),
            LitPeak(x: 300, z: 4300, h: 0.40, r: 1700, power: 1.15),
            LitPeak(x: -1300, z: 4300, h: 0.34, r: 1500, power: 1.2),
            LitPeak(x: 2600, z: 3600, h: 0.34, r: 1800, power: 1.25),
            LitPeak(x: -3800, z: 2600, h: 0.46, r: 2100, power: 1.15),
            LitPeak(x: 3700, z: 6200, h: 0.56, r: 2500, power: 1.15),
            LitPeak(x: -3900, z: 5900, h: 0.60, r: 2500, power: 1.15),
        ]
        var spec = LitTerrainSpec(x0: -5000, z0: 300, size: 10000, seed: seed, shape: { x, z in
            let wx = x + 500 * litFbm(x / 2600, z / 2600, 3, seed &+ 1)
            let wz = z + 500 * litFbm(x / 2600 + 9, z / 2600, 3, seed &+ 2)
            var m: Float = 0
            for p in peaks {
                let dx = wx - p.x, dz = wz - p.z
                let r = (dx * dx + dz * dz).squareRoot() / p.r
                if r < 1 { m = max(m, p.h * powf(1 - r, p.power)) }
            }
            let rr = litRidged(wx / 2500, wz / 2500, 5, seed &+ 3)
            let v = m * (0.58 + 0.72 * rr) + 0.015 + 0.012 * litFbm(x / 500, z / 500, 2, seed &+ 4)
            let s = shoreZ(x)
            return v * litSstep(s - 10, s + 1500, z) + 0.01 * litSstep(s, s + 60, z)
        }, isBase: { x, z in z < shoreZ(x) }, top: 2800)
        spec.detail = 9
        spec.talus = 0.92
        // Strong rock and weak rock in big bodies; faces towards the camera and the light stand as cliffs, the far side lies back.
        spec.hardness = { x, z in 0.74 + 0.62 * litSat(0.5 + 1.4 * litFbm(x / 1500, z / 1500, 3, seed &+ 30)) }
        spec.scarpDir = litNorm2(LitV2(-0.45, -0.9))
        spec.scarpGain = 0.18
        spec.bedAmp = 0.28
        spec.bedSpacing = 230
        spec.bedTilt = LitV2(0.11, -0.06)
        var L = LitErosion.build(spec, maxN: maxN, erodeN: erodeN)
        defer { L.free() }
        // The lake basin.
        do {
            let L = L
            let n = L.n, hp = L.h, cell = L.cell, x0 = L.x0, z0 = L.z0
            litParallelFor(n, chunk: 16) { z in
                for x in 0..<n {
                    let wx = x0 + Float(x) * cell, wz = z0 + Float(z) * cell
                    let s = shoreZ(wx)
                    let d = s - wz
                    if d > -2 {
                        hp[z * n + x] = min(hp[z * n + x], -min(46, max(0, d) * 0.12) - litSat((d + 2) / 3) * 0.4 + litSat(-d / 2) * 1.0)
                    } else {
                        hp[z * n + x] += 1.0 * litSat(-d / 30)
                    }
                }
            }
        }
        let seenLake: @Sendable (Float, Float) -> Bool = { x, z in abs(x) < z * 0.5 + 400 }
        L.addScree(rate: 0.9, minHeight: 120, seed: seed &+ 80)
        let ba: Float = 1
        var blockOct: [(lambda: Float, amp: Float)] = [(lambda: 230, amp: 22 * ba), (lambda: 96, amp: 9 * ba)]
        if tier > 0 { blockOct.append((lambda: 40, amp: 3.5 * ba)) }
        L.addBlocks(seed: seed &+ 70, octaves: blockOct, visible: seenLake)
        L.addGullies(seed: seed &+ 40, lambda: 280, octaves: tier == 2 ? 4 : (tier == 1 ? 3 : 2), depth: 0.16, visible: seenLake)
        L.addSnowSlide(line: 900, band: 340, amount: 20, steepLimit: 86, seed: seed &+ 75, ribMargin: 4.5)
        L.buildCurve()

        // Forest: on the low ground, not too steep, thinned by noise.
        let treeLine: Float = 1040
        do {
            let L0 = L
            let m = L.aoN
            let f = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
            let c = L.size / Float(m - 1), x0 = L.x0, z0 = L.z0
            litParallelFor(m, chunk: 8) { z in
                for x in 0..<m {
                    let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                    let y = L0.hAt(wx, wz)
                    let e = c * 2
                    let sx = (L0.hAt(wx + e, wz) - L0.hAt(wx - e, wz)) / (2 * e)
                    let sz = (L0.hAt(wx, wz + e) - L0.hAt(wx, wz - e)) / (2 * e)
                    let s = (sx * sx + sz * sz).squareRoot()
                    let n1 = litFbm(wx / 420, wz / 420, 3, seed &+ 50)
                    let tl = treeLine + n1 * 200
                    let v = litSstep(0.4, 3.0, y) * (1 - litSstep(tl - 170, tl, y)) * (1 - litSstep(1.5, 2.3, s + n1 * 0.3))
                    f[z * m + x] = litSat(v * (0.9 + 0.8 * litFbm(wx / 140, wz / 140, 3, seed &+ 51)))
                }
            }
            L.forest = f
            L.forestTop = 36
        }
        L.buildMips()
        let LL = L

        // Light: a low sun from the left, a little behind the camera. The top of the massif glows, the valley lies in cool shade.
        let sun = litNorm3(dark ? LitV3(-0.72, 0.42, -0.30) : LitV3(-0.86, 0.06, -0.30))
        let camY: Float = 15
        let A = LitAtmosphere(sunDir: sun, sunE: dark ? LitV3(1, 1.02, 1.1) * 8 : LitV3(1, 0.98, 0.95) * 20, altBase: 1500, camY: camY,
                           turbidity: dark ? 0.7 : 0.8, skyGain: dark ? 0.5 : 1.85, msGain: 1.7, airGain: dark ? 0.4 : 0.8, ozone: dark ? 1 : 1.6)
        defer { A.free() }
        LL.buildShadow(sun: sun)
        LL.buildAO()
        let ambLand = LitAmbient(atmos: A, ground: LitV3(0.06, 0.07, 0.06) * (dark ? 0.2 : 1.6)).scaled(dark ? 3 : 1)
        let rig = LitLightRig(sun: sun, ambient: ambLand, bounce: dark ? 1.0 : 0.5)
        var look = LitLandLook(snowLine: 1150, treeLine: treeLine, seed: seed)
        look.shoreTop = 2.2
        look.ledgeBias = 0.14
        if dark { look.bump = 0.5 }

        // LitCamera with a shift lens: horizon low in the frame, verticals stay vertical.
        let fw = Float(w), fh = Float(h)
        let f = max(min(1.75 * fw, 0.81 * fh), 0.72 * fw)
        let cam = LitCamera(ro: LitV3(0, camY, 0), f: f, cx: fw * 0.5, horizon: fh * 0.665)
        let hdr = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        defer { hdr.deallocate() }
        let depth = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { depth.deallocate() }

        // LitClouds: a scatter of cumulus over the massif, altocumulus higher up, a veil of cirrus.
        let tex = litMakeCloudTextures(seed: seed &+ 900, shapeN: plan.tier == 0 ? 32 : 64, detailN: plan.tier == 0 ? 16 : 32)
        defer { tex.shape.free(); tex.detail.free() }
        let wN = tier == 2 ? 1024 : (tier == 1 ? 512 : 256)
        let wxA = litMakeWeather(n: wN, half: 90000) { x, z in
            let n = litFbm(x / 7000, z / 7000, 5, seed &+ 901) * 0.5 + 0.5
            let big = litFbm(x / 26000, z / 26000, 2, seed &+ 902)
            // Heaps stay low behind the massif: no stray puffs overhead.
            return litSat((n - 0.36 + big * 0.22) * 3.6) * litSstep(11000, 19000, z)
        }
        let wxB = litMakeWeather(n: wN, half: 110000) { x, z in
            let n = litFbm(x / 5200, z / 12000, 5, seed &+ 903) * 0.5 + 0.5
            let big = litFbm(x / 40000 + 3, z / 40000, 2, seed &+ 904)
            return litSat((n - 0.37 + big * 0.2) * 3)
        }
        // No low rags in this picture; the slot stays so the layers keep their order.
        let wxC = litMakeWeather(n: wN, half: 12000) { x, z in
            let n = litFbm(x / 1700, z / 1700, 5, seed &+ 906) * 0.5 + 0.5
            let dx = (x - 2600) / 2200, dz = (z - 5600) / 1500
            let near = litSat(1 - (dx * dx + dz * dz))
            return litSat((n - 0.56 + near * 0.2) * 5) * near * 0
        }
        defer { wxA.deallocate(); wxB.deallocate(); wxC.deallocate() }
        let layers = UnsafeMutablePointer<LitCloudLayer>.allocate(capacity: 3)
        defer { layers.deallocate() }
        layers[0] = LitCloudLayer(base: 1500, top: 2300, scale: 1400, detailScale: 240, vstretch: 0.8, sigma: 0.09, erode: 0.55, weather: wxC, wN: wN, half: 12000,
                               fadeBottom: 0.2, fadeTopFrom: 0.4, shearX: 300, minStep: 40, stepK: 0.008, lightSteps: 5, lightFirst: 40, lightGrow: 1.8, towering: 0.1)
        layers[1] = LitCloudLayer(base: 4700, top: 7000, scale: 3200, detailScale: 420, vstretch: 1.1, sigma: 0.14, erode: 0.5, weather: wxA, wN: wN, half: 90000,
                               fadeBottom: 0.05, fadeTopFrom: 0.25, shearX: 500, minStep: 60, stepK: 0.0075, lightSteps: 6, lightFirst: 50, lightGrow: 1.8, towering: 0.5)
        layers[2] = LitCloudLayer(base: 8600, top: 9400, scale: 7000, detailScale: 1200, vstretch: 0.25, sigma: 0.0055, erode: 0.62, weather: wxB, wN: wN, half: 110000,
                               fadeBottom: 0.2, fadeTopFrom: 0.5, shearX: 2500, minStep: 150, stepK: 0.01, lightSteps: 2, lightFirst: 200, lightGrow: 2, massGain: 1.3)
        var clouds = LitClouds(shape: tex.shape, detail: tex.detail, layers: layers, count: 3)
        clouds.sun = sun
        clouds.g1 = 0.72; clouds.g2 = -0.25; clouds.gMix = 0.7
        clouds.sunGain = dark ? 0.6 : 1
        clouds.ambTop = rig.ambient.irradiance(LitV3(0, 1, 0)) * 1.6
        clouds.ambBottom = rig.ambient.irradiance(LitV3(0, -1, 0)) * 1.6 + clouds.ambTop * 0.25

        // Reflection first: the same world from the mirrored camera.
        let mirror = LitCamera(ro: LitV3(0, -camY, 0), f: f, cx: cam.cx, horizon: cam.horizon)
        let reflTop = max(0, Int(cam.horizon - (fh - cam.horizon) * 1.2))
        let reflRows = Int(cam.horizon) + 2 - reflTop
        let refl = UnsafeMutablePointer<LitV3>.allocate(capacity: w * reflRows)
        defer { refl.deallocate() }
        // Low mist over the water: thickest at the surface, in slow patches.
        let mistH: Float = 16
        let up0 = rig.ambient.irradiance(LitV3(0, 1, 0))
        let sunLow = A.sunColor(y: 10)
        let mistCol = up0 * (0.30 / Float.pi) + sunLow * (dark ? 0.012 : 0.018)
        let mistK: Float = 0.00055
        // Valley haze: thick in the bottom few hundred metres, so the massif's foot sits lighter and bluer than its summit.
        let hazeH: Float = 260
        let hazeK: Float = (dark ? 0.00005 : 0.00004)
        let hazeGain: Float = dark ? 0.75 : 0.98
        @inline(__always) func mist(_ c: LitV3, t: Float, yEnd: Float, rd: LitV3) -> LitV3 {
            let y0 = abs(camY)
            let dy = yEnd - y0
            let e0 = expf(-y0 / mistH)
            let I: Float = abs(dy) < 0.01 ? t * e0 : t * mistH / dy * (e0 - expf(-yEnd / mistH))
            let patch = 0.35 + 1.3 * litSat(0.5 + litGnoise(rd.x / max(0.02, abs(rd.z)) * 1.6 + 5, 2.5, seed &+ 62))
            let T = expf(-mistK * max(0, I) * patch)
            let h0 = expf(-y0 / hazeH)
            let Ih: Float = abs(dy) < 0.5 ? t * h0 : t * hazeH / dy * (h0 - expf(-yEnd / hazeH))
            let Th = expf(-hazeK * max(0, Ih))
            let horizon = A.sky(litNorm3(LitV3(rd.x, 0.012, abs(rd.z)))) * hazeGain
            let c1 = c * Th + horizon * (1 - Th)
            return c1 * T + mistCol * (1 - T)
        }
        let treeF = LL.forest
        // One ray of the direct view: colour, depth (negative: water at that distance, infinity: sky).
        @inline(__always) func directRay(_ px: Float, _ py: Float) -> (LitV3, Float) {
            let rd = cam.dir(px, py)
            let tw: Float = rd.y < -1e-5 ? cam.ro.y / -rd.y : .infinity
            let hit = LL.trace(ro: cam.ro, rd: rd, tmin: 0.5, tmax: min(tw, 60000)) { xx, zz, tt in
                let g = LL.hAt(xx, zz)
                if let treeF {
                    let m = LL.field(treeF, LL.aoN, xx, zz)
                    return tt < 5200 ? g + LitLand.tree(xx, zz, mask: m, seed: seed) : g + 15 * m
                }
                return g
            }
            if hit < tw {
                let p = cam.ro + rd * hit
                let lit = LitLand.shade(layer: LL, p: p, rd: rd, t: hit, pixel: hit / f, atmos: A, rig: rig, look: look)
                let air = A.aerial(ro: cam.ro, rd: rd, t: hit)
                return (mist(lit * air.trans + air.add, t: hit, yEnd: p.y, rd: rd), hit)
            }
            if tw < .infinity { return (.zero, -tw) }
            return (A.sky(rd), .infinity)
        }
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let r = directRay(Float(x) + 0.5, Float(y) + 0.5)
                hdr[y * w + x] = r.0
                depth[y * w + x] = r.1
            }
        }
        // Edges: where the depth jumps, or the light does (a snow edge, a shadow's edge), four more rays. `waterShare` is how much of the pixel turned out water.
        let waterShare = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { waterShare.deallocate() }
        let hot = LitAA.contrast(hdr, depth: depth, w: w, h: h, enabled: tier > 0, threshold: dark ? 0.5 : 0.3)
        defer { hot.deallocate() }
        // The edge test reads a still copy of the depths, so that the outcome does not hang on which row a thread got to first.
        let seen = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { seen.deallocate() }
        seen.update(from: depth, count: w * h)
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let i = y * w + x
                waterShare[i] = 0
                let d0 = seen[i]
                var edge = false
                var yy = max(0, y - 1)
                while yy <= min(h - 1, y + 1) && !edge {
                    var xx = max(0, x - 1)
                    while xx <= min(w - 1, x + 1) {
                        let d1 = seen[yy * w + xx]
                        if (d0 < 0) != (d1 < 0) || (d0 == .infinity) != (d1 == .infinity) { edge = true; break }
                        if d0 > 0 && d0 != .infinity && abs(d1 - d0) > min(d0, d1) * 0.05 { edge = true; break }
                        xx += 1
                    }
                    yy += 1
                }
                if !edge && hot[i] == 0 { continue }
                if !edge {
                    // A snow or shadow edge on the land: one more ray either side of the centre is enough.
                    let a = directRay(Float(x) + 0.25, Float(y) + 0.3), b = directRay(Float(x) + 0.75, Float(y) + 0.7)
                    if a.1 > 0 && b.1 > 0 { hdr[i] = (hdr[i] + a.0 + b.0) * (1.0 / 3.0) }
                    continue
                }
                var sum = LitV3.zero
                var nw: Float = 0, nc: Float = 0
                var o = 0
                let edgeRays = tier == 0 ? 2 : 4
                while o < edgeRays {
                    // Rotated grid.
                    let ox: Float = edgeRays == 2 ? (o == 0 ? 0.25 : 0.75) : (o == 0 ? 0.375 : (o == 1 ? 0.875 : (o == 2 ? 0.125 : 0.625)))
                    let oy: Float = edgeRays == 2 ? (o == 0 ? 0.3 : 0.7) : Float(o) * 0.25 + 0.125
                    let r = directRay(Float(x) + ox, Float(y) + oy)
                    if r.1 < 0 { nw += 1 } else { sum += r.0; nc += 1 }
                    o += 1
                }
                if nc > 0 {
                    hdr[i] = sum / nc
                    if d0 < 0 { depth[i] = 1000 }
                    waterShare[i] = nw / Float(edgeRays)
                } else if d0 >= 0 {
                    depth[i] = -1
                }
            }
        }
        if dark { addStars(hdr, depth: depth, w: w, h: h, cam: cam, density: 900, gain: 0.5, seed: seed) }
        // LitClouds at half size against that depth (water pixels: skipped by the mirror look-up below).
        let cloudScale = tier > 0 ? 2 : 1
        litParallelFor(h, chunk: 16) { y in
            for x in 0..<w where depth[y * w + x] < 0 { depth[y * w + x] = 0.01 }
        }
        let cbuf = LitCloudPass.render(clouds, A: A, cam: cam, fw: w, fh: h, scale: cloudScale, depth: depth, refine: tier > 0 ? 0.03 : nil)
        defer { cbuf.free() }
        // Mirrored world for the water, at half size: ripples soften it anyway.
        let mw = (w + 1) / 2, mh = (reflRows + 1) / 2
        let reflHalf = UnsafeMutablePointer<LitV3>.allocate(capacity: mw * mh)
        let reflDepth = UnsafeMutablePointer<Float>.allocate(capacity: mw * mh)
        defer { reflDepth.deallocate(); reflHalf.deallocate() }
        litParallelFor(mh, chunk: 4) { ry in
            let y = Float(ry) * 2 + 1 + Float(reflTop)
            for x in 0..<mw {
                let rd = mirror.dir(Float(x) * 2 + 1, y)
                let start = rd.y > 1e-5 ? -mirror.ro.y / rd.y : 0
                let tree = LL.forest
                let hit = LL.trace(ro: mirror.ro, rd: rd, tmin: max(0.5, start), tmax: 60000) { xx, zz, tt in
                    let g = LL.hAt(xx, zz)
                    if let tree {
                        let m = LL.field(tree, LL.aoN, xx, zz)
                        return tt < 5200 ? g + LitLand.tree(xx, zz, mask: m, seed: seed) : g + 15 * m
                    }
                    return g
                }
                var col: LitV3
                var dd: Float = .infinity
                if hit < .infinity {
                    let p = mirror.ro + rd * hit
                    let lit = LitLand.shade(layer: LL, p: p, rd: rd, t: hit, pixel: hit / f * 2, atmos: A, rig: rig, look: look)
                    let air = A.aerial(ro: cam.ro, rd: litNorm3(LitV3(rd.x, abs(rd.y), rd.z)), t: hit, steps: 4)
                    col = mist(lit * air.trans + air.add, t: hit, yEnd: p.y, rd: litNorm3(LitV3(rd.x, abs(rd.y), rd.z)))
                    dd = hit
                } else {
                    col = A.sky(rd)
                }
                reflHalf[ry * mw + x] = col
                reflDepth[ry * mw + x] = dd
            }
        }
        if dark {
            // The same stars, in the water.
            let mirrorStars = LitCamera(ro: cam.ro, f: f * 0.5, cx: cam.cx * 0.5, horizon: (cam.horizon - Float(reflTop)) * 0.5)
            addStars(reflHalf, depth: reflDepth, w: mw, h: mh, cam: mirrorStars, density: 900 * Float(reflRows) / Float(max(1, Int(cam.horizon))), gain: 0.5, seed: seed, unitW: fw)
        }
        litParallelFor(mh, chunk: 4) { ry in
            let y = ry * 2 + 1 + reflTop
            for x in 0..<mw {
                let (ci, ct) = cbuf.sample(x: Float(x) * 2 + 1, y: Float(y), depth: reflDepth[ry * mw + x])
                reflHalf[ry * mw + x] = reflHalf[ry * mw + x] * ct + ci
            }
        }
        // Up to the size the water reads it at. A cubic look-up, held to its four nearest values so nothing rings against a bright sky, then a little sharpening of the brightness alone.
        let cubic: (Float) -> (Float, Float, Float, Float) = { t in
            let t2 = t * t, t3 = t2 * t
            return (-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
        }
        litParallelFor(reflRows, chunk: 8) { ry in
            let vy = max(0, min(Float(mh) - 1.001, Float(ry) * 0.5 - 0.25))
            let iy = Int(vy)
            let wy = cubic(vy - Float(iy))
            let r0 = max(0, iy - 1) * mw, r1 = iy * mw, r2 = (iy + 1) * mw, r3 = min(mh - 1, iy + 2) * mw
            for x in 0..<w {
                let vx = max(0, min(Float(mw) - 1.001, Float(x) * 0.5 - 0.25))
                let ix = Int(vx)
                let wx = cubic(vx - Float(ix))
                let c0 = max(0, ix - 1), c1 = ix, c2 = ix + 1, c3 = min(mw - 1, ix + 2)
                @inline(__always) func row(_ r: Int) -> LitV3 {
                    let a = reflHalf[r + c0] * wx.0 + reflHalf[r + c1] * wx.1
                    let b = reflHalf[r + c2] * wx.2 + reflHalf[r + c3] * wx.3
                    return a + b
                }
                let up = row(r0) * wy.0 + row(r1) * wy.1 + row(r2) * wy.2 + row(r3) * wy.3
                let n0 = reflHalf[r1 + c1], n1 = reflHalf[r1 + c2], n2 = reflHalf[r2 + c1], n3 = reflHalf[r2 + c2]
                let lo = pointwiseMin(pointwiseMin(n0, n1), pointwiseMin(n2, n3)), hi = pointwiseMax(pointwiseMax(n0, n1), pointwiseMax(n2, n3))
                refl[ry * w + x] = pointwiseMax(lo, pointwiseMin(hi, up))
            }
        }
        if reflRows > 4 {
            let lumaN = reflRows * w
            let lum = UnsafeMutablePointer<Float>.allocate(capacity: lumaN), lumB = UnsafeMutablePointer<Float>.allocate(capacity: lumaN)
            defer { lum.deallocate(); lumB.deallocate() }
            litParallelFor(reflRows, chunk: 16) { ry in
                for x in 0..<w { lum[ry * w + x] = litLuma(refl[ry * w + x]) }
            }
            litParallelFor(reflRows, chunk: 16) { ry in
                let a0 = max(0, ry - 2), a1 = max(0, ry - 1), a3 = min(reflRows - 1, ry + 1), a4 = min(reflRows - 1, ry + 2)
                for x in 0..<w {
                    let b0 = max(0, x - 2), b1 = max(0, x - 1), b3 = min(w - 1, x + 1), b4 = min(w - 1, x + 2)
                    let m = lum[ry * w + x] * 6 + lum[ry * w + b1] * 4 + lum[ry * w + b3] * 4 + lum[ry * w + b0] + lum[ry * w + b4]
                    let v = lum[ry * w + x] * 6 + lum[a1 * w + x] * 4 + lum[a3 * w + x] * 4 + lum[a0 * w + x] + lum[a4 * w + x]
                    lumB[ry * w + x] = (m + v) / 32
                }
            }
            litParallelFor(reflRows, chunk: 16) { ry in
                for x in 0..<w {
                    let i = ry * w + x
                    let k = 1 + 0.8 * (lum[i] - lumB[i]) / max(1e-4, lumB[i])
                    refl[i] = refl[i] * max(0.72, min(1.32, k))
                }
            }
        }
        // A point of land near the camera on the right, a smaller one further off on the left: real depth in front of the far shore.
        let bankH: Float = 1.7
        @inline(__always) func nearLand(_ X: Float, _ Z: Float) -> Float {
            let wob = litFbm(Z / 16, X / 16, 3, seed &+ 300) * 3.2 + litGnoise(Z / 3.1, X / 3.1, seed &+ 301) * 0.6
            let dzR = Z - 172
            let right = X - (15 + 0.0052 * dzR * dzR + wob)
            let dzL = Z - 560
            let left = -X - (118 + 0.0011 * dzL * dzL + wob * 2.2)
            return max(right, left)
        }
        let nearUp = rig.ambient.irradiance(LitV3(0, 1, 0))
        let nearFace = rig.ambient.irradiance(LitV3(0, 0.2, -1))
        @inline(__always) func landTop(_ X: Float, _ Z: Float) -> LitV3 {
            let a = litFbm(X / 4.5, Z / 4.5, 3, seed &+ 310), b = litFbm(X / 0.9, Z / 0.9, 2, seed &+ 311)
            let moss = litLerp(LitV3(0.030, 0.042, 0.024), LitV3(0.075, 0.085, 0.045), litSat(0.5 + a * 1.4))
            let rock = LitV3(0.11, 0.105, 0.10) * (0.7 + 0.6 * litSat(b + 0.5))
            let alb = litLerp(moss, rock, litSstep(0.18, 0.32, a + b * 0.3))
            let ao = 0.5 + 0.5 * litSat(0.5 + b)
            return alb * nearUp * ((1 / Float.pi) * ao)
        }
        @inline(__always) func landFace(_ X: Float, _ Z: Float, _ y: Float) -> LitV3 {
            let a = litFbm(X / 1.6 + Z / 1.6, y / 0.8, 3, seed &+ 312)
            let wet = 1 - 0.55 * litSstep(0.8, 0.0, y)
            return LitV3(0.085, 0.082, 0.078) * (0.55 + 0.8 * litSat(a + 0.5)) * wet * nearFace * (1 / Float.pi)
        }
        // The near land in the mirror: only its front face shows from below.
        if !(unitS < 1) {
            litParallelFor(reflRows, chunk: 8) { ry in
                let y = ry + reflTop
                let fy = Float(y) + 0.5
                if fy >= cam.horizon { return }
                for x in 0..<w {
                    let rd = mirror.dir(Float(x) + 0.5, fy)
                    if rd.y <= 1e-5 { continue }
                    // Crosses y = 0 at t0 and the top of the bank at t1.
                    let t0 = -mirror.ro.y / rd.y, t1 = (bankH - mirror.ro.y) / rd.y
                    if t0 > 1500 { continue }
                    let x0 = rd.x * t0, z0 = rd.z * t0, x1 = rd.x * t1, z1 = rd.z * t1
                    if nearLand(x0, z0) > 0 || nearLand(x1, z1) > 0 {
                        let air = A.aerial(ro: cam.ro, rd: litNorm3(LitV3(rd.x, abs(rd.y), rd.z)), t: t0, steps: 3)
                        refl[ry * w + x] = landFace(x0, z0, 0.5) * air.trans + air.add
                    }
                }
            }
        }
        // Trees of the two points, farthest first.
        var trees: [(x: Float, z: Float, h: Float, slim: Float, seed: UInt32)] = []
        do {
            var st: UInt32 = seed &+ 400
            func r() -> Float { st = st &* 0x6C07_8965 &+ 0x2F1B_3A5D; return Float(st >> 8) * (1.0 / 16777216.0) }
            // Right: a loose stand on the point, tallest at the back.
            var k = 0
            while trees.count < 15 && k < 400 {
                k += 1
                let z = 128 + r() * 150
                let x = 12 + r() * 62
                let edge = nearLand(x, z)
                if edge < 3.5 { continue }
                if trees.contains(where: { ($0.x - x) * ($0.x - x) + ($0.z - z) * ($0.z - z) < 90 }) { continue }
                trees.append((x, z, (17 + 15 * r()) * (0.85 + 0.3 * litSat((z - 130) / 120)), 0.82 + 0.35 * r(), UInt32(k) &* 977 &+ seed))
            }
            // Left: further off, so much smaller.
            k = 0
            let rightCount = trees.count
            while trees.count < rightCount + 16 && k < 400 {
                k += 1
                let z = 470 + r() * 240
                let x = -(120 + r() * 120)
                let edge = nearLand(x, z)
                if edge < 5 { continue }
                trees.append((x, z, 17 + 16 * r(), 0.82 + 0.35 * r(), UInt32(k) &* 1409 &+ seed &+ 31))
            }
            trees.sort { $0.z > $1.z }
        }
        let treeBase: Float = bankH + 0.2
        let sprites = UnsafeMutablePointer<LitTreeSprite>.allocate(capacity: max(1, trees.count))
        defer { sprites.deallocate() }
        let treeList = trees
        litParallelFor(treeList.count, chunk: 1) { i in
            let t = treeList[i]
            sprites[i] = LitSpruce.raster(pixelHeight: t.h * f / t.z, seed: t.seed, slim: t.slim)
        }
        defer { for i in 0..<treeList.count { sprites[i].free() } }
        let needle = dark ? LitV3(0.058, 0.084, 0.060) : LitV3(0.095, 0.135, 0.095)
        @inline(__always) func treeColor(_ tr: (x: Float, z: Float, h: Float, slim: Float, seed: UInt32), _ sh: Float, _ py: Float) -> LitV3 {
            // Mostly sky from above, a whisper of the low sun on what stands high enough.
            let high = litSat(py)
            let warm = A.sunColor(y: 10) * (dark ? 0.025 : 0.035) * (0.3 + 0.7 * high)
            return needle * (nearUp * (0.10 + 1.15 * sh) + warm * sh) * (1 / Float.pi)
        }
        // Into the mirror.
        for i in 0..<treeList.count {
            let tr = treeList[i], sp = sprites[i]
            let s = f / tr.z
            let baseU = cam.cx + tr.x * s
            let baseV = cam.horizon - (camY + treeBase) * s - Float(reflTop)
            let ox = Int(baseU) - sp.baseX, oy = Int(baseV) - sp.baseY
            let rdT = litNorm3(LitV3(tr.x, 8, tr.z))
            for sy in 0..<sp.h {
                let yy = oy + sy
                if yy < 0 || yy >= reflRows { continue }
                for sx in 0..<sp.w {
                    let xx = ox + sx
                    if xx < 0 || xx >= w { continue }
                    let a = sp.cover[sy * sp.w + sx]
                    if a < 0.003 { continue }
                    let rel = Float(sp.baseY - sy) / max(1, Float(sp.h))
                    let c = mist(treeColor(tr, sp.shade[sy * sp.w + sx], rel), t: tr.z, yEnd: 8, rd: rdT)
                    refl[yy * w + xx] = litLerp(refl[yy * w + xx], c, a)
                }
            }
        }
        let sat2 = LitColumnSAT(UnsafePointer(refl), w: w, h: reflRows)
        defer { sat2.free() }
        let reflH = Float(reflRows)
        // Composite: land + clouds, then water from the mirror.
        let waterBody: LitV3 = dark ? LitV3(0.0030, 0.0065, 0.0105) : LitV3(0.012, 0.030, 0.036)
        let fExp: Float = dark ? 3.9 : 2.8
        let wc1: Float = 0.0009, wg1: Float = 0.0050, wc2: Float = 0.0012, wg2: Float = 0.0040
        @inline(__always) func waterAt(_ x: Int, _ y: Int) -> LitV3 {
            let rd = cam.dir(Float(x) + 0.5, Float(y) + 0.5)
            let down = max(0.00002, -rd.y)
            let tw = cam.ro.y / down
            let X = rd.x * tw, Z = rd.z * tw
            // How much water one pixel covers along and across the view.
            let fpZ = tw / f / down, fpX = tw / f
            // Bands where the wind touches the surface; the rest lies still. In the logarithm of distance, so they stay bands all the way out.
            let lz = logf(max(10, Z))
            let bandA = litFbm(X / 1100 + 3, lz * 6.5, 3, seed &+ 60)
            let bandB = litFbm(X / 300, lz * 22, 2, seed &+ 63)
            let wind = litSstep(0.10, 0.42, bandA + bandB * 0.22)
            let sig = 0.0016 + 0.0010 * litSat(bandB + 0.5) + wind * 0.0085
            // A wave moves the image only when it is tall enough on screen to draw, and never by more than its own height; otherwise it folds into scan lines. Anything finer smears the image instead.
            var dv: Float = 0, du: Float = 0, smear: Float = 0
            @inline(__always) func wave(_ lxx: Float, _ lzz: Float, _ calm: Float, _ gust: Float, _ sd: UInt32) {
                let amp = calm + wind * gust
                let wP = lzz / fpZ
                let vis = litSstep(9, 26, wP)
                smear += (1 - vis) * amp * f * 1.1
                if vis < 0.01 { return }
                let e = lzz * 0.2
                let a0 = litFbm(X / lxx, Z / lzz, 2, sd)
                let a1 = litFbm((X + lxx * 0.2) / lxx, Z / lzz, 2, sd)
                let a2 = litFbm(X / lxx, (Z + e) / lzz, 2, sd)
                let cap = 0.42 * wP
                let d = (a2 - a0) / 0.2 * amp * 2 * f
                dv += vis * cap * (d / cap) / (1 + abs(d / cap))
                du += vis * (a1 - a0) / 0.2 * amp * 2 * f * 0.1
            }
            wave(10, 1.6, wc1, wg1, seed &+ 61)
            wave(30, 6.0, wc2, wg2, seed &+ 64)
            let r0 = max(0.5, 2 * sig * f + smear)
            let u = cam.cx + rd.x / rd.z * f + du
            let v = min(reflH - 0.5, (cam.horizon + (down / rd.z) * -f) - Float(reflTop) + dv)
            _ = fpX
            // Mostly along the view, and a little across it, as ripples do.
            let rx = max(0.5, r0 * 0.09)
            let col = (sat2.blur(u: u - rx, v: v, r: r0) + sat2.blur(u: u + rx, v: v, r: r0)) * 0.5
            let cosI = max(0.002, down / litLen3(rd))
            let fr = 0.02 + 0.98 * powf(1 - cosI, fExp)
            let air = A.aerial(ro: cam.ro, rd: rd, t: tw, steps: 4)
            let body = waterBody * (dark ? 1 : (0.6 + 0.8 * litSat(tw / 500)))
            return mist(litLerp(body, col, fr) * air.trans + air.add, t: tw, yEnd: 0.05, rd: rd)
        }
        @inline(__always) func nearAt(_ rd: LitV3) -> LitV3? {
            if rd.y >= -1e-4 { return nil }
            let t1 = (camY - bankH) / -rd.y
            let x1 = rd.x * t1, z1 = rd.z * t1
            if z1 > 1200 { return nil }
            let e1 = nearLand(x1, z1)
            if e1 > 0 {
                let air = A.aerial(ro: cam.ro, rd: rd, t: t1, steps: 3)
                return mist(landTop(x1, z1) * air.trans + air.add, t: t1, yEnd: bankH, rd: rd)
            }
            let t0 = camY / -rd.y
            let x0 = rd.x * t0, z0 = rd.z * t0
            if nearLand(x0, z0) > 0 {
                let f0 = 1 - (t1 / t0)
                let air = A.aerial(ro: cam.ro, rd: rd, t: t0, steps: 3)
                return mist(landFace(x0, z0, f0 * bankH) * air.trans + air.add, t: t0, yEnd: 0.8, rd: rd)
            }
            return nil
        }
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let i = y * w + x
                let d = depth[i]
                if d > 0.02 {
                    let (ci, ct) = cbuf.sample(x: Float(x) + 0.5, y: Float(y) + 0.5, depth: d)
                    let land = hdr[i] * ct + ci
                    let share = waterShare[i]
                    hdr[i] = share > 0 ? litLerp(land, waterAt(x, y), share) : land
                } else {
                    hdr[i] = waterAt(x, y)
                }
                if Float(y) + 0.5 > cam.horizon {
                    var sum = LitV3.zero
                    var n: Float = 0
                    var o = 0
                    while o < 4 {
                        let ox: Float = o == 0 ? 0.375 : (o == 1 ? 0.875 : (o == 2 ? 0.125 : 0.625))
                        if let c = nearAt(cam.dir(Float(x) + ox, Float(y) + Float(o) * 0.25 + 0.125)) { sum += c; n += 1 }
                        o += 1
                    }
                    if n > 0 { hdr[i] = litLerp(hdr[i], sum / n, n / 4) }
                }
            }
        }
        // The trees over everything.
        for i in 0..<treeList.count {
            let tr = treeList[i], sp = sprites[i]
            let s = f / tr.z
            let baseU = cam.cx + tr.x * s
            let baseV = cam.horizon + (camY - treeBase) * s
            let ox = Int(baseU) - sp.baseX, oy = Int(baseV) - sp.baseY
            litParallelFor(sp.h, chunk: 16) { sy in
                let yy = oy + sy
                if yy < 0 || yy >= h { return }
                let rdT = cam.dir(baseU, Float(yy))
                let ySc = camY + rdT.y * tr.z
                for sx in 0..<sp.w {
                    let xx = ox + sx
                    if xx < 0 || xx >= w { continue }
                    let a = sp.cover[sy * sp.w + sx]
                    if a < 0.003 { continue }
                    let rel = Float(sp.baseY - sy) / max(1, Float(sp.h))
                    let c = mist(treeColor(tr, sp.shade[sy * sp.w + sx], rel), t: tr.z, yEnd: ySc, rd: rdT)
                    hdr[yy * w + xx] = litLerp(hdr[yy * w + xx], c, a)
                }
            }
        }
        var g = LitGrade()
        g.exposure = dark ? 0.78 : 1.72
        g.vignette = 0.2
        if dark {
            g.tint = LitV3(0.5, 0.68, 1.0)
            g.ceiling = 0.68
            g.night = 0.5
        }
        return LitPost.finish(hdr: hdr, w: w, h: h, outW: plan.outW, outH: plan.outH, grade: g, seed: seed)
    }

    /// Stars (only where `depth` is sky), scattered by seed, sized a little above one pixel at every resolution.
    static func addStars(_ hdr: UnsafeMutablePointer<LitV3>, depth: UnsafeMutablePointer<Float>, w: Int, h: Int, cam: LitCamera, density: Float, gain: Float, seed: UInt32, unitW: Float? = nil) {
        var st = UInt64(seed) &+ 7
        @inline(__always) func rnd() -> Float {
            st &+= 0x9E37_79B9_7F4A_7C15
            var z = st
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(z >> 40) * (1.0 / 16777216.0)
        }
        // Uniform in the sky picture: position in units of the picture width so a tile shows the same stars.
        let unitS = unitW ?? Float(min(w, h))
        // A small tile shows fewer, finer stars: the same sky, not a snowstorm.
        let count = Int(density * min(1, max(0.08, powf(unitS / 1179, 1.3))))
        // Sizes are in canvas pixels, so a star keeps its look when the canvas is smaller than the output.
        let scale = max(0.5, unitS / 1179 * 0.82) * Float(min(w, h)) / max(1, unitS)
        for _ in 0..<count {
            let u = rnd(), v = rnd()
            let m = rnd()
            // Power law: many faint, few bright.
            let bright = powf(m, 22) * 7 + powf(m, 5) * 1.4 + 0.08
            let temp = rnd()
            let tint = temp < 0.33 ? LitV3(1, 0.86, 0.72) : (temp < 0.72 ? LitV3(1, 0.97, 0.92) : LitV3(0.76, 0.86, 1))
            let px = u * Float(w), py = v * cam.horizon
            let rd = cam.dir(px, py)
            let air = litSat(rd.y * 9)
            let col = tint * (bright * gain * air * air)
            let rad = scale * (0.75 + 0.5 * litSat(bright / 6))
            let r = Int(rad * 2.5) + 1
            let cx = Int(px), cy = Int(py)
            var y = max(0, cy - r)
            while y <= min(h - 1, cy + r) {
                var x = max(0, cx - r)
                while x <= min(w - 1, cx + r) {
                    if depth[y * w + x] == .infinity {
                        let dx = Float(x) + 0.5 - px, dy = Float(y) + 0.5 - py
                        hdr[y * w + x] += col * expf(-(dx * dx + dy * dy) / (rad * rad))
                    }
                    x += 1
                }
                y += 1
            }
        }
    }

    // MARK: Scene: sea of clouds

    static func deck(_ plan: LitPlan, dark: Bool) -> CGImage? {
        let w = plan.w, h = plan.h
        let seed: UInt32 = 5150
        let big = plan.tier == 2, mid = plan.tier > 0
        // One horn left of centre, cliffs to the sun, a long shoulder running out of the frame on the left; lesser summits step away to the right.
        let peaks: [LitPeak] = [
            LitPeak(x: -950, z: 9400, h: 1.00, r: 3900, power: 1.0),
            LitPeak(x: -3300, z: 10300, h: 0.70, r: 3400, power: 1.1),
            LitPeak(x: -6400, z: 11500, h: 0.72, r: 3900, power: 1.1),
            LitPeak(x: 2850, z: 15200, h: 0.72, r: 2300, power: 1.15),
            LitPeak(x: 6300, z: 18500, h: 0.70, r: 2500, power: 1.15),
            LitPeak(x: 800, z: 19500, h: 0.60, r: 2000, power: 1.15),
        ]
        var spec = LitTerrainSpec(x0: -10000, z0: 2000, size: 20000, seed: seed, shape: { x, z in
            let wx = x + 620 * litFbm(x / 3400, z / 3400, 3, seed &+ 1)
            let wz = z + 620 * litFbm(x / 3400 + 9, z / 3400, 3, seed &+ 2)
            var m: Float = 0
            for p in peaks {
                let dx0 = wx - p.x, dz = wz - p.z
                // Steep on the sunlit side, drawn out on the other.
                let dx = dx0 > 0 ? dx0 * 1.3 : dx0 * 0.86
                let r = (dx * dx + dz * dz).squareRoot() / p.r
                if r < 1 { m = max(m, p.h * powf(1 - r, p.power)) }
            }
            let rr = litRidged(wx / 3200, wz / 3200, 5, seed &+ 3)
            return m * (0.66 + 0.5 * rr) + 0.02 + 0.015 * litFbm(x / 800, z / 800, 2, seed &+ 4)
        }, isBase: { x, z in z < 2400 || abs(x) > 9700 || z > 21700 }, top: 4900)
        spec.detail = 9
        spec.talus = 0.86
        spec.hardness = { x, z in 0.8 + 0.42 * litSat(0.5 + 1.4 * litFbm(x / 1300, z / 1300, 3, seed &+ 30)) }
        spec.scarpDir = litNorm2(LitV2(0.9, -0.42))
        spec.scarpGain = 0.14
        spec.bedAmp = 0.22
        spec.bedSpacing = 260
        spec.bedTilt = LitV2(-0.09, 0.05)
        var L = LitErosion.build(spec, maxN: plan.grid.maxN, erodeN: plan.grid.erodeN)
        defer { L.free() }
        let seen: @Sendable (Float, Float) -> Bool = { x, z in abs(x) < z * 0.42 + 600 }
        L.addScree(rate: 0.5, minHeight: 500, seed: seed &+ 74)
        L.addBlocks(seed: seed &+ 70, octaves: mid ? [(lambda: 260, amp: 26), (lambda: 110, amp: 13), (lambda: 50, amp: 7)] : [(lambda: 260, amp: 26), (lambda: 110, amp: 13)], visible: seen)
        L.addGullies(seed: seed &+ 40, lambda: 300, octaves: big ? 4 : (mid ? 3 : 2), depth: 0.12, visible: seen)
        // LitErosion made the relief; it stands on a high plateau, hidden under the deck.
        L.raise(by: 2800)
        L.addSnowSlide(line: 4500, band: 400, amount: 26, steepLimit: 80, seed: seed &+ 75, patch: 18)
        L.buildCurve()
        L.buildMips()
        let LL = L

        // Far ranges, in the haze.
        var farSpec = LitTerrainSpec(x0: -34000, z0: 22000, size: 68000, seed: seed &+ 200, shape: { x, z in
            let wx = x + 3000 * litFbm(x / 14000, z / 14000, 3, seed &+ 201)
            let band = litSstep(26000, 38000, z) * (1 - litSstep(70000, 88000, z))
            let rr = litRidged(wx / 13000, z / 13000, 5, seed &+ 203)
            return band * (0.3 + 0.85 * rr * rr) * (0.8 + 0.4 * litFbm(x / 34000, z / 34000, 2, seed &+ 204))
        }, isBase: { x, z in z < 24000 || z > 88000 || abs(x) > 33000 }, top: 7400)
        farSpec.detail = 9
        var F = LitErosion.build(farSpec, maxN: big ? 513 : 257, erodeN: big ? 257 : 129)
        defer { F.free() }
        if mid {
            F.addBlocks(seed: seed &+ 271, octaves: [(lambda: 1000, amp: 70), (lambda: 420, amp: 30)]) { _, _ in true }
            F.addGullies(seed: seed &+ 240, lambda: 1100, octaves: 3, depth: 0.14) { _, _ in true }
        }
        F.addSnowSlide(line: 3200, band: 800, amount: 5, steepLimit: 58, seed: seed &+ 76, smooth: 70)
        F.buildCurve(wide: 300, narrow: 90)
        F.buildMips()
        let FF = F

        // Light: low and from ahead on the right for the day; the moon stays out of the frame at night.
        let sun = litNorm3(dark ? LitV3(0.88, 0.30, 0.10) : LitV3(0.93, 0.2, -0.30))
        let camY: Float = 6200
        let A = LitAtmosphere(sunDir: sun, sunE: dark ? LitV3(1, 1.02, 1.1) * 8 : LitV3(1, 0.97, 0.92) * 20, altBase: 0, camY: camY,
                           turbidity: dark ? 0.7 : 1.15, skyGain: dark ? 0.42 : 2.3, msGain: 1.7, airGain: dark ? 0.32 : 1.2)
        defer { A.free() }
        LL.buildShadow(sun: sun)
        LL.buildAO()
        FF.buildShadow(sun: sun)
        FF.buildAO()
        // Shadows of passing clouds, drifting over the rock.
        do {
            let m = LL.n, sh = LL.shadow
            let c = LL.cell, x0 = LL.x0, z0 = LL.z0
            litParallelFor(m, chunk: 16) { iz in
                for ix in 0..<m {
                    let wx = x0 + Float(ix) * c, wz = z0 + Float(iz) * c
                    let n = litFbm(wx / 1500 + 2, wz / 1500, 3, seed &+ 77)
                    sh[iz * m + ix] *= 1 - 0.62 * litSstep(0.03, 0.28, n)
                }
            }
        }
        let rig = LitLightRig(sun: sun, ambient: LitAmbient(atmos: A, ground: LitV3(0.5, 0.52, 0.55) * (dark ? 0.1 : 1.1)).scaled(dark ? 2.4 : 1), bounce: 0.9)
        var look = LitLandLook(snowLine: 4500, treeLine: -100, seed: seed)
        look.rockWarm = LitV3(0.17, 0.14, 0.118)
        var lookFar = look
        lookFar.snowLine = 3200
        lookFar.bump = 0
        lookFar.edgeScale = 4

        let fw = Float(w), fh = Float(h)
        let f = max(min(1.75 * fw, 0.81 * fh), 0.72 * fw)
        let cam = LitCamera(ro: LitV3(0, camY, 0), f: f, cx: fw * 0.5, horizon: fh * 0.47)
        let hdr = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        defer { hdr.deallocate() }
        let depth = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { depth.deallocate() }

        @inline(__always) func landRay(_ px: Float, _ py: Float) -> (LitV3, Float) {
            let rd = cam.dir(px, py)
            let tNear = LL.trace(ro: cam.ro, rd: rd, tmin: 1, tmax: 90000) { xx, zz, _ in LL.hAt(xx, zz) }
            if tNear < .infinity {
                let p = cam.ro + rd * tNear
                let lit = LitLand.shade(layer: LL, p: p, rd: rd, t: tNear, pixel: tNear / f, atmos: A, rig: rig, look: look)
                let air = A.aerial(ro: cam.ro, rd: rd, t: tNear)
                return (lit * air.trans + air.add, tNear)
            }
            let tFar = FF.trace(ro: cam.ro, rd: rd, tmin: 1, tmax: 120000) { xx, zz, _ in FF.hAt(xx, zz) }
            if tFar < .infinity {
                let p = cam.ro + rd * tFar
                let lit = LitLand.shade(layer: FF, p: p, rd: rd, t: tFar, pixel: tFar / f, atmos: A, rig: rig, look: lookFar)
                let air = A.aerial(ro: cam.ro, rd: rd, t: tFar)
                return (lit * air.trans + air.add, tFar)
            }
            return (A.sky(rd), .infinity)
        }
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let r = landRay(Float(x) + 0.5, Float(y) + 0.5)
                hdr[y * w + x] = r.0
                depth[y * w + x] = r.1
            }
        }
        // Edge rays over the silhouettes.
        let fixC = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        defer { fixC.deallocate() }
        let hot = LitAA.contrast(hdr, depth: depth, w: w, h: h, enabled: mid)
        defer { hot.deallocate() }
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let i = y * w + x
                let d0 = depth[i]
                var edge = false
                var yy = max(0, y - 1)
                while yy <= min(h - 1, y + 1) && !edge {
                    var xx = max(0, x - 1)
                    while xx <= min(w - 1, x + 1) {
                        let d1 = depth[yy * w + xx]
                        if (d0 == .infinity) != (d1 == .infinity) || (d0 != .infinity && abs(d1 - d0) > min(d0, d1) * 0.05) { edge = true; break }
                        xx += 1
                    }
                    yy += 1
                }
                if !edge {
                    if hot[i] != 0 {
                        fixC[i] = (hdr[i] + landRay(Float(x) + 0.25, Float(y) + 0.3).0 + landRay(Float(x) + 0.75, Float(y) + 0.7).0) * (1.0 / 3.0)
                    } else {
                        fixC[i] = hdr[i]
                    }
                    continue
                }
                var sum = LitV3.zero
                var o = 0
                while o < 4 {
                    let ox: Float = o == 0 ? 0.375 : (o == 1 ? 0.875 : (o == 2 ? 0.125 : 0.625))
                    sum += landRay(Float(x) + ox, Float(y) + Float(o) * 0.25 + 0.125).0
                    o += 1
                }
                fixC[i] = sum * 0.25
            }
        }
        memcpy(hdr, fixC, w * h * MemoryLayout<LitV3>.stride)
        if dark { addStars(hdr, depth: depth, w: w, h: h, cam: cam, density: 1400, gain: 0.34, seed: seed) }

        // The deck.
        let deckTop: Float = 4750
        let tex = litMakeCloudTextures(seed: seed &+ 900, shapeN: plan.tier == 0 ? 32 : 64, detailN: plan.tier == 0 ? 16 : 32)
        defer { tex.shape.free(); tex.detail.free() }
        let wN = big ? 1024 : (mid ? 512 : 256)
        let halfA: Float = 120000
        // A closed deck: lanes and dips, almost no holes.
        let covBase: Float = 0.84
        let wxA = litMakeWeather(n: wN, half: halfA) { x, z in
            let n = litFbm(x / 5200, z / 5200, 5, seed &+ 901)
            let large = litFbm(x / 26000, z / 26000, 2, seed &+ 902)
            return litSat(covBase + n * 0.42 + large * 0.16)
        }
        // High, thin, and pulled about; clear over the summit.
        let wxB = litMakeWeather(n: wN, half: 160000) { x, z in
            let wx = x + 9000 * litFbm(x / 21000, z / 21000, 3, seed &+ 906)
            let wz = z + 9000 * litFbm(x / 21000 + 7, z / 21000, 3, seed &+ 907)
            let n = litFbm(wx / 15000, wz / 7500, 5, seed &+ 905)
            let clear = 1 - 0.95 * expf(-powf((z - 16000) / 8500, 2))
            return litSat((n + 0.05) * 3.0) * clear
        }
        // Rags of cloud climbing the ridges: only near rock, only in places.
        let wxC = litMakeWeather(n: wN, half: 30000) { x, z in
            var near: Float = 0
            for p in peaks {
                let dx = (x - p.x) / (p.r * 0.72), dz = (z - p.z) / (p.r * 0.72)
                near = max(near, expf(-(dx * dx + dz * dz)))
            }
            let n = litFbm(x / 1500, z / 1500, 4, seed &+ 908)
            return litSat((n + 0.08) * 2.6) * litSstep(0.12, 0.5, near)
        }
        defer { wxA.deallocate(); wxB.deallocate(); wxC.deallocate() }
        let layers = UnsafeMutablePointer<LitCloudLayer>.allocate(capacity: 3)
        defer { layers.deallocate() }
        layers[0] = LitCloudLayer(base: deckTop - 1500, top: deckTop + 260, scale: 2100, detailScale: 190, vstretch: 1.0, sigma: 0.32, erode: 0.46, weather: wxA, wN: wN, half: halfA,
                               fadeBottom: 0.1, fadeTopFrom: 0.5, shearX: 0, minStep: 30, stepK: 0.005, lightSteps: 6, lightFirst: 20, lightGrow: 1.8, towering: 0.4, fineStep: 6, lightK: 0.38)
        layers[1] = LitCloudLayer(base: 9000, top: 9800, scale: 9000, detailScale: 700, vstretch: 0.3, sigma: dark ? 0.003 : 0.0042, erode: 0.62, weather: wxB, wN: wN, half: 160000,
                               fadeBottom: 0.25, fadeTopFrom: 0.45, shearX: 2400, minStep: 120, stepK: 0.01, lightSteps: 2, lightFirst: 150, lightGrow: 2, massGain: 1.3)
        // Sorted by altitude for the march.
        let cirrus = layers[1]
        layers[1] = LitCloudLayer(base: deckTop + 100, top: deckTop + 1050, scale: 800, detailScale: 110, vstretch: 0.8, sigma: 0.016, erode: 0.6, weather: wxC, wN: wN, half: 30000,
                               fadeBottom: 0.3, fadeTopFrom: 0.2, shearX: 300, minStep: 30, stepK: 0.006, lightSteps: 3, lightFirst: 40, lightGrow: 2, towering: 0.6, massGain: 1.6, fineStep: 12)
        layers[2] = cirrus
        var clouds = LitClouds(shape: tex.shape, detail: tex.detail, layers: layers, count: 3)
        clouds.sun = sun
        clouds.g1 = 0.72; clouds.g2 = -0.25; clouds.gMix = 0.72
        clouds.sunGain = dark ? 0.8 : 3.2
        clouds.sunTint = dark ? LitV3(1, 1, 1) : LitV3(0.95, 0.99, 1.05)
        clouds.ambTop = rig.ambient.irradiance(LitV3(0, 1, 0)) * 2.3
        clouds.ambBottom = rig.ambient.irradiance(LitV3(0, 1, 0)) * 1.8
        // Shadows of the peaks on the deck, on a grid at the deck's level.
        let castN = mid ? 512 : 256
        let castHalf: Float = 26000, castZ: Float = 12000
        let cast = UnsafeMutablePointer<Float>.allocate(capacity: castN * castN)
        defer { cast.deallocate() }
        let hLen = (sun.x * sun.x + sun.z * sun.z).squareRoot()
        let tanS = sun.y / hLen, dirX = sun.x / hLen, dirZ = sun.z / hLen
        litParallelFor(castN, chunk: 8) { iz in
            for ix in 0..<castN {
                let px = -castHalf + Float(ix) / Float(castN - 1) * 2 * castHalf
                let pz = castZ - castHalf + Float(iz) / Float(castN - 1) * 2 * castHalf
                var res: Float = 1
                var d: Float = 90
                var k = 0
                while k < 44 {
                    let qx = px + dirX * d, qz = pz + dirZ * d
                    if !LL.inside(qx, qz) { if d > 400 { break } }
                    if LL.inside(qx, qz) {
                        let y = deckTop + tanS * d
                        res = min(res, 14 * (y - LL.hAt(qx, qz)) / d)
                        if res < -0.5 { break }
                    }
                    d += max(90, d * 0.09)
                    k += 1
                }
                cast[iz * castN + ix] = 0.16 + 0.84 * litSat(0.5 + 0.5 * res)
            }
        }
        clouds.castMap = cast
        clouds.castN = castN
        clouds.castHalf = castHalf
        clouds.castZ = castZ
        clouds.castLevel = deckTop
        let cloudScale = Int(1)
        let cbuf = LitCloudPass.render(clouds, A: A, cam: cam, fw: w, fh: h, scale: cloudScale, maxSteps: 240, depth: depth, refine: mid ? 0.03 : nil, tent: !mid)
        defer { cbuf.free() }
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let i = y * w + x
                let (ci, ct) = cbuf.sample(x: Float(x) + 0.5, y: Float(y) + 0.5, depth: depth[i])
                hdr[i] = hdr[i] * ct + ci
            }
        }
        if dark {
            // A moon-lit deck falls away towards the camera, so the rows on top of it stay readable.
            let hz = cam.horizon
            litParallelFor(h, chunk: 8) { y in
                let t = litSat((Float(y) - hz) / (fh - hz))
                let k = 1 - 0.62 * litSstep(0.12, 0.95, t)
                for x in 0..<w { hdr[y * w + x] *= k }
            }
        }
        var g = LitGrade()
        g.exposure = dark ? 0.74 : 0.48
        g.vignette = 0.2
        g.bloom = 0.05
        if dark {
            g.tint = LitV3(0.5, 0.68, 1.0)
            g.ceiling = 0.62
            g.night = 0.5
        }
        return LitPost.finish(hdr: hdr, w: w, h: h, outW: plan.outW, outH: plan.outH, grade: g, seed: seed)
    }

    // MARK: Scene: ocean

    static func ocean(_ plan: LitPlan, dark: Bool) -> CGImage? {
        let w = plan.w, h = plan.h, tier = plan.tier
        let seed: UInt32 = dark ? 1711 : 1712
        let sun = dark ? litNorm3(LitV3(-0.15, 0.40, 1)) : litNorm3(LitV3(0.11, 0.022, 1))
        let camY: Float = 26
        let A = LitAtmosphere(sunDir: sun, sunE: dark ? LitV3(0.95, 0.98, 1.08) * 9 : LitV3(1, 0.98, 0.95) * 26, altBase: 0, camY: camY,
                           turbidity: dark ? 0.55 : 0.5, g: dark ? 0.8 : 0.86, Hm: 1300, skyGain: dark ? 0.14 : 1.3, msGain: 1, airGain: dark ? 0.14 : 1.0, ozone: dark ? 1 : 1.8)
        defer { A.free() }
        let amb = LitAmbient(atmos: A, ground: LitV3(0.01, 0.02, 0.03) * (dark ? 0.4 : 1.5))
        let fw = Float(w), fh = Float(h)
        let f = max(min(1.75 * fw, 0.81 * fh), 0.72 * fw)
        let cam = LitCamera(ro: LitV3(0, camY, 0), f: f, cx: fw * 0.5, horizon: fh * 0.625)

        // LitClouds: low heaps, a broken mid deck that fills the upper picture, ice high up.
        let tex = litMakeCloudTextures(seed: seed &+ 900, shapeN: plan.tier == 0 ? 32 : 64, detailN: plan.tier == 0 ? 16 : 32)
        defer { tex.shape.free(); tex.detail.free() }
        let wN = tier == 2 ? 1024 : (tier == 1 ? 512 : 256)
        // Low heaps only far off, thinning as they near the sea's edge.
        let wxA = litMakeWeather(n: wN, half: 180000) { x, z in
            let n = litFbm(x / 11000 + 2, z / 15000, 4, seed &+ 901) * 0.5 + 0.5
            // By night the sky overhead stays open: only the far banks remain.
            let far: Float = dark ? litSstep(9000, 26000, z) : litSstep(14000, 38000, z)
            let edge = 1 - litSstep(dark ? 82000 : 58000, dark ? 125000 : 92000, (x * x + z * z).squareRoot())
            // Nothing low stands between the sun and the sea's edge.
            let lane = dark ? 1 : litSstep(900, 4200, abs(x - sun.x / max(0.05, sun.z) * z))
            return litSat((n - (dark ? 0.42 : 0.47)) * 3.2) * far * edge * lane
        }
        // The big broken deck: large masses, lanes of open sky, no scatter of small bits.
        let wxB = litMakeWeather(n: wN, half: 180000) { x, z in
            let wx = x + 5000 * litFbm(x / 16000, z / 16000, 2, seed &+ 910), wz = z + 5000 * litFbm(x / 16000 + 5, z / 16000, 2, seed &+ 911)
            let n = litFbm(wx / 13000, wz / 21000, 4, seed &+ 903) * 0.5 + 0.5
            let big = litFbm(x / 34000 + 3, z / 44000, 2, seed &+ 904)
            // A clearing low over the light, so that it can reach the deck from beneath.
            let dx = x - sun.x / max(0.05, sun.z) * z
            let clear = litSstep(9000, 26000, abs(dx) + max(0, z - 90000) * 0.2) * 0.5 + 0.5
            // Towards the sea's edge the deck thins out instead of breaking into crumbs.
            let thin = dark ? 1 : 1 - 0.88 * litSstep(17000, 46000, z)
            let far: Float = dark ? litSstep(20000, 42000, z) : 1
            let edge = 1 - litSstep(82000, 125000, (x * x + z * z).squareRoot())
            return litSat((n - 0.40 + big * 0.5) * 3.4) * (dark ? far : clear) * thin * edge
        }
        let wxC = litMakeWeather(n: wN, half: 220000) { x, z in
            // Pulled about by the wind rather than laid in stripes.
            let wx = x + 11000 * litFbm(x / 24000, z / 24000, 3, seed &+ 912), wz = z + 11000 * litFbm(x / 24000 + 7, z / 24000, 3, seed &+ 913)
            let n = litFbm(wx / 15000, wz / 9500, 5, seed &+ 905) * 0.5 + 0.5
            let edge = 1 - litSstep(70000, 120000, (x * x + z * z).squareRoot())
            return litSat((n - 0.46) * 3) * edge
        }
        defer { wxA.deallocate(); wxB.deallocate(); wxC.deallocate() }
        let layers = UnsafeMutablePointer<LitCloudLayer>.allocate(capacity: 3)
        defer { layers.deallocate() }
        layers[0] = LitCloudLayer(base: 900, top: 3000, scale: 3000, detailScale: 400, vstretch: 1, sigma: 0.14, erode: 0.5, weather: wxA, wN: wN, half: 180000,
                               fadeBottom: 0.05, fadeTopFrom: 0.3, shearX: 300, minStep: 60, stepK: 0.0075, lightSteps: 6, lightFirst: 60, lightGrow: 1.8, towering: 0.5, erodeThin: 0.3, powder: dark ? 0.28 : 0.5)
        layers[1] = LitCloudLayer(base: 4600, top: 6200, scale: (dark ? 3600 : 5200), detailScale: (dark ? 240 : 340), vstretch: 0.6, sigma: 0.145, erode: 0.54, weather: wxB, wN: wN, half: 180000,
                               fadeBottom: 0.12, fadeTopFrom: 0.45, shearX: 900, minStep: 70, stepK: 0.0075, lightSteps: 5, lightFirst: 70, lightGrow: 1.8, towering: 0.2, lightK: 0.3, erodeThin: 0.3, powder: dark ? 0.28 : 0.5)
        layers[2] = LitCloudLayer(base: 9000, top: 9700, scale: 9000, detailScale: 700, vstretch: 0.3, sigma: 0.004, erode: 0.62, weather: wxC, wN: wN, half: 220000,
                               fadeBottom: 0.25, fadeTopFrom: 0.45, shearX: 2400, minStep: 110, stepK: 0.01, lightSteps: 2, lightFirst: 150, lightGrow: 2, massGain: 1.3)
        var clouds = LitClouds(shape: tex.shape, detail: tex.detail, layers: layers, count: 3)
        // By sunset the light rises from just under the sea's edge at cloud height: decks catch it from beneath.
        clouds.sun = dark ? sun : litNorm3(LitV3(sun.x, -0.028, sun.z))
        clouds.g1 = 0.75; clouds.g2 = -0.3; clouds.gMix = 0.7
        clouds.sunGain = dark ? 0.55 : 2.2
        clouds.ambTop = amb.irradiance(LitV3(0, 1, 0)) * (dark ? 1.5 : 3.2)
        clouds.ambBottom = amb.irradiance(LitV3(0, -1, 0)) * 1.5 + clouds.ambTop * (dark ? 0.3 : 0.55)

        let hdr = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        defer { hdr.deallocate() }
        let depth = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { depth.deallocate() }
        // Towards the zenith the evening goes from rose to indigo.
        let zenithTint = dark ? LitV3(1, 1, 1) : LitV3(0.66, 0.96, 1.1)
        let horizonTint = LitV3(0.40, 0.27, 0.16)
        @inline(__always) func skyFilter(_ rd: LitV3) -> LitV3 {
            dark ? LitV3(1, 1, 1) : litLerp(horizonTint, zenithTint, litSstep(0.0, 0.34, rd.y))
        }
        // Sea curvature.
        let R: Float = 6_371_000
        @inline(__always) func seaHit(_ rd: LitV3) -> Float {
            if rd.y >= 0 { return .infinity }
            let a = (1 - rd.y * rd.y) / (2 * R)
            let disc = rd.y * rd.y - 4 * a * camY
            if disc < 0 { return .infinity }
            return (-rd.y - disc.squareRoot()) / (2 * a)
        }
        // Sky.
        let sunRadius: Float = dark ? 0.0165 : 0.0092
        let discU = cam.cx + sun.x / sun.z * f, discV = cam.horizon - sun.y / sun.z * f, discR = sunRadius * f
        let sunL = dark ? A.sunColor(y: 3000) * 1.25 : LitV3(1.0, 0.50, 0.12) * 4
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let rd = cam.dir(Float(x) + 0.5, Float(y) + 0.5)
                let t = seaHit(rd)
                depth[y * w + x] = t
                var c = A.sky(rd)
                // The disc is drawn round on the picture; a wide lens would stretch it.
                let dxs = (Float(x) + 0.5 - discU) / discR, dys = (Float(y) + 0.5 - discV) / discR
                let rr = (dxs * dxs + dys * dys).squareRoot()
                if dark {
                    c += sunL * (0.022 * expf(-max(0, rr - 1) / 1.6))
                    if rr < 1.1 {
                        let e = litSat((1.02 - rr) / 0.05)
                        // The moon: maria and a soft limb.
                        let mar = litFbm(dxs * 1.25 + 4, dys * 1.25, 4, seed &+ 70)
                        let mar2 = litSstep(-0.05, 0.28, mar)
                        let limb = 1 - 0.22 * rr * rr
                        c += sunL * (0.78 - 0.5 * mar2 + 0.12 * litFbm(dxs * 6, dys * 6, 2, seed &+ 71)) * limb * e
                    }
                } else if rr < 1.15 {
                    let e = 1 - litSstep(0.84, 1.06, rr)
                    // A burnt-out core that falls to deep orange at the limb and reddens low down, so the disc melts into its own glow.
                    let low = litSat(0.5 + dys * 0.5)
                    let limb = litLerp(LitV3(30, 9.5, 0.5), LitV3(30, 6.2, 0.22), low)
                    c = litLerp(c, litLerp(limb, LitV3(44, 27, 2.6), litSstep(0.05, 0.8, 1 - rr)), e)
                }
                hdr[y * w + x] = c
            }
        }
        if dark { addStars(hdr, depth: depth, w: w, h: h, cam: cam, density: 900, gain: 0.5, seed: seed) }
        // LitClouds in the sky part.
        let horizonRow = Int(cam.horizon) + 2
        let cbuf = LitCloudPass.render(clouds, A: A, cam: cam, fw: w, fh: h, scale: 1, rows: 0..<horizonRow, maxSteps: 220, depth: nil, tent: true)
        defer { cbuf.free() }
        // Env for reflections.
        let env = LitEnvMap(w: tier > 0 ? 900 : 300, h: tier > 0 ? 360 : 120, azMax: 1.25)
        defer { env.free() }
        litParallelFor(env.h, chunk: 2) { y in
            for x in 0..<env.w {
                let rd = env.dirAt(x, y)
                var c = A.sky(rd)
                let r = clouds.march(ro: cam.ro, rd: rd, tMax: 320_000, jitter: LitCloudPass.ign(x, y), A: A, maxSteps: 70)
                if r.T < 0.999 {
                    let air = A.aerial(ro: cam.ro, rd: rd, t: r.tm, steps: 4)
                    c = c * r.T + r.L * air.trans + air.add * (1 - r.T)
                }
                env.p[y * env.w + x] = c * skyFilter(rd)
            }
        }
        // The same sky through rough water: long up and down, narrower sideways.
        let envSoft = LitEnvMap(w: env.w, h: env.h, azMax: env.azMax)
        defer { envSoft.free() }
        env.blurred(into: envSoft, rx: max(2, env.w / 110), ry: max(2, env.h / 22))
        // Waves.
        let N = tier > 0 ? 256 : 128
        let fft = LitFFT2(n: N)
        defer { fft.free() }
        let windDir = litNorm3(LitV3(0.77, 0, -0.64))
        let phillips: (Float, Float, Float, Float) -> Float = { kx, kz, lo, hi in
            let k2 = kx * kx + kz * kz
            if k2 < 1e-8 { return 0 }
            let k = k2.squareRoot()
            if k < lo || k > hi { return 0 }
            let LL: Float = 9.5 * 9.5 / 9.81
            let c = (kx * windDir.x + kz * windDir.z) / k
            let align = c * c
            return expf(-1 / (k2 * LL * LL)) / (k2 * k2) * (align + 0.25)
        }
        let swell = LitOceanTile(n: N, L: 2200, fft: fft, seed: seed &+ 11, wind: LitV2(0, 1), spectrum: { kx, kz in
            let k = (kx * kx + kz * kz).squareRoot()
            if k < 1e-5 { return 0 }
            let kp: Float = 2 * .pi / 190
            // Two swells crossing, from different storms.
            let c = (kx * 0.55 + kz * -0.83) / k
            let c2 = (kx * -0.62 + kz * -0.78) / k
            let kp2 = kp * 1.5
            return expf(-powf((k - kp) / (kp * 0.35), 2)) * powf(max(0, c), 10)
                + 0.45 * expf(-powf((k - kp2) / (kp2 * 0.35), 2)) * powf(max(0, c2), 8)
        }, heightRMS: 0.75, chop: 0.6)
        let tA = LitOceanTile(n: N, L: 620, fft: fft, seed: seed &+ 12, wind: LitV2(0, 1), spectrum: { kx, kz in phillips(kx, kz, 2 * .pi / 620, 2 * .pi / 40) }, heightRMS: 0.55, chop: 0.7)
        let tB = LitOceanTile(n: N, L: 73, fft: fft, seed: seed &+ 13, wind: LitV2(0, 1), spectrum: { kx, kz in phillips(kx, kz, 2 * .pi / 40, 2 * .pi / 5) }, heightRMS: 0.13, chop: 1.2)
        let tC = LitOceanTile(n: N, L: 11, fft: fft, seed: seed &+ 14, wind: LitV2(0, 1), spectrum: { kx, kz in phillips(kx, kz, 2 * .pi / 5, 2 * .pi / 0.2) }, heightRMS: 0.018, chop: 0.8)
        defer { swell.free(); tA.free(); tB.free(); tC.free() }

        // Sky irradiance & sea colour.
        let seaUp = amb.irradiance(LitV3(0, 1, 0))
        let sunAtSea = A.sunColor(y: 0)
        let deep = LitV3(0.0018, 0.0095, 0.0145) * (dark ? 1 : 4.5)
        let fresnelP: Float = dark ? 5 : 3.5
        let sss = LitV3(0.012, 0.055, 0.05)
        let E = sunAtSea * (dark ? 0.048 : 1)
        // Composite sky.
        litParallelFor(horizonRow, chunk: 4) { y in
            for x in 0..<w where depth[y * w + x] == .infinity {
                let (ci, ct) = cbuf.sample(x: Float(x) + 0.5, y: Float(y) + 0.5)
                hdr[y * w + x] = (hdr[y * w + x] * ct + ci) * skyFilter(cam.dir(Float(x) + 0.5, Float(y) + 0.5))
            }
        }
        // The sea's far edge melts into the composited sky just over it, not into a sky of its own.
        let skyAboveHorizon = UnsafeMutablePointer<LitV3>.allocate(capacity: w)
        defer { skyAboveHorizon.deallocate() }
        let seaEdge = cam.horizon + f * (2 * camY / R).squareRoot()
        do {
            let row = max(0, Int(cam.horizon) - 2)
            for x in 0..<w { skyAboveHorizon[x] = hdr[row * w + x] }
        }
        // Water.
        let edgeBand = max(2, 7 * fh / 2556)
        litParallelFor(h - max(0, horizonRow - 3), chunk: 2) { yy in
            let y = yy + max(0, horizonRow - 3)
            var rng = litHash32(Int32(y), 991, seed)
            for x in 0..<w {
                let center = cam.dir(Float(x) + 0.5, Float(y) + 0.5)
                let tC0 = seaHit(center)
                // More samples where a pixel covers a long stretch of sea.
                let nS = tC0 > 1500 || tC0 == .infinity ? 16 : (tC0 > 200 ? 10 : 6)
                var col = LitV3.zero
                var hits = 0
                var missCol = LitV3.zero
                var misses = 0
                var tSum: Float = 0
                for s in 0..<nS {
                    rng = rng &* 0x6C07_8965 &+ 0x2F1B_3A5D
                    let j1 = Float(rng >> 8) * (1.0 / 16777216.0)
                    rng = rng &* 0x6C07_8965 &+ 0x2F1B_3A5D
                    let j2 = Float(rng >> 8) * (1.0 / 16777216.0)
                    let sx = Float(x) + (Float(s) + j1) / Float(nS)
                    let sy = Float(y) + j2
                    let rd = cam.dir(sx, sy)
                    var t = seaHit(rd)
                    if t == .infinity {
                        // Above the sea's edge: sky.
                        let (ci, ct) = cbuf.sample(x: sx, y: sy)
                        missCol += (A.sky(rd) * ct + ci) * skyFilter(rd)
                        misses += 1
                        continue
                    }
                    // The wave's real height moves the hit point (near and mid distance).
                    var p = cam.ro + rd * t
                    if t < 2500 {
                        for _ in 0..<2 {
                            let hgt = swell.heightAt(p.x, p.z) + tA.heightAt(p.x, p.z) + tB.heightAt(p.x, p.z)
                            t = (camY - hgt) / -rd.y
                            p = cam.ro + rd * t
                        }
                    }
                    let fpX = t / f
                    let grazing = max(0.0015, -rd.y)
                    // Footprint between the short (across) and long (along) axes: anisotropy is handled by the many samples.
                    let fp = fpX * (1 / grazing).squareRoot() * 1.1
                    let a = swell.slope(p.x, p.z, fp: fp), b = tA.slope(p.x, p.z, fp: fp)
                    let c = tB.slope(p.x, p.z, fp: fp), d = tC.slope(p.x, p.z, fp: fp)
                    let sxv = a.x + b.x + c.x + d.x, szv = a.y + b.y + c.y + d.y
                    // Slope variance beyond the footprint: it spreads the reflection, read from a blurred sky rather than drawn at random.
                    let vr = a.z + b.z + c.z + d.z + 0.0004
                    var n = litNorm3(LitV3(-sxv, 1, -szv))
                    let v = -rd
                    var ndv = litDot3(n, v)
                    if ndv < 0.015 {
                        n = litNorm3(n + v * (0.015 - ndv + 0.01))
                        ndv = litDot3(n, v)
                    }
                    var r = litReflect3(rd, n)
                    if r.y < 0.002 { r.y = 0.002 + abs(r.y); r = litNorm3(r) }
                    let F = 0.02 + 0.98 * powf(max(0, 1 - ndv), fresnelP)
                    let envL = litLerp(env.sample(r), envSoft.sample(r), litSstep(0.0, 0.012, vr))
                    // Sun glitter: Cox-Munk on the unresolved slopes around this sample's facet.
                    let hv = litNorm3(v + sun)
                    let zx = hv.x / hv.y, zz = hv.z / hv.y
                    let ex = zx + sxv, ez = zz + szv
                    let sig2 = dark ? vr * 1.2 + 0.0006 : vr + 0.0002
                    let pdf = expf(-(ex * ex + ez * ez) / (2 * sig2)) / (2 * Float.pi * sig2)
                    let cos4 = hv.y * hv.y * hv.y * hv.y
                    let vdh = max(0, litDot3(v, hv))
                    let Fs = 0.02 + 0.98 * powf(1 - vdh, 5)
                    let glitter = E * (Fs * pdf / (4 * max(0.02, ndv) * cos4)) * max(0, sun.y + 0.02) / max(0.02, sun.y + 0.02)
                    // Water body, with light through the steep sides of waves.
                    let hNear = t < 3000 ? (swell.heightAt(p.x, p.z) + tA.heightAt(p.x, p.z)) : 0
                    let body = deep * (seaUp * 0.6) * (1 / Float.pi)
                    let backlit = powf(max(0, litDot3(rd, sun) * 0.5 + 0.5), 3)
                    let through = E * (0.012 * litSat(hNear * 0.8 + 0.5) * backlit) * sss * 18
                    // Foam in folded water.
                    let foam = litSat((b.w * 1.1 + c.w * 0.8)) 
                    let foamNoise = litSat(litFbm(p.x / 2.4, p.z / 2.4, 3, seed &+ 80) * 1.2 + 0.65)
                    let foamA = litSstep(0.25, 1, foam * foamNoise * 1.4) * (dark ? 0.6 : 0.4)
                    let foamC = (seaUp + E * max(0.05, sun.y)) * (0.75 / Float.pi)
                    var pc = (body + through) * (1 - F) + envL * F + glitter
                    pc = litLerp(pc, foamC, foamA)
                    col += simd_min(pc, LitV3(repeating: 60))
                    tSum += t
                    hits += 1
                }
                var out = LitV3.zero
                if hits > 0 {
                    let tm = tSum / Float(hits)
                    let air = A.aerial(ro: cam.ro, rd: center, t: tm, steps: 5)
                    out = (col / Float(hits)) * air.trans + air.add
                }
                let total = Float(hits + misses)
                var pix = (out * Float(hits) + missCol) / total
                let melt = 1 - litSstep(seaEdge - 1, seaEdge + edgeBand, Float(y) + 0.5)
                if melt > 0 { pix = litLerp(pix, skyAboveHorizon[x], melt * 0.9) }
                hdr[y * w + x] = pix
            }
        }
        if dark {
            // The moon's path fades towards the bottom, where the rows and bubbles sit.
            let edge = cam.horizon
            litParallelFor(h, chunk: 8) { y in
                let t = litSat((Float(y) - edge) / (fh - edge))
                let k = (1 - 0.27 * litSstep(0.02, 0.32, t)) * (1 - 0.68 * litSstep(0.24, 1, t))
                for x in 0..<w { hdr[y * w + x] *= k }
            }
        }
        var g = LitGrade()
        g.exposure = dark ? 0.62 : 0.62
        g.vignette = 0.22
        g.bloom = dark ? 0.08 : 0.12
        if dark {
            g.tint = LitV3(0.52, 0.72, 1.0)
            g.ceiling = 0.66
            g.night = 0.7
        }
        return LitPost.finish(hdr: hdr, w: w, h: h, outW: plan.outW, outH: plan.outH, grade: g, seed: seed)
    }
}

// MARK: What the land pictures share

nonisolated enum LitCommon {
    /// One view of the world: `ray` gives a colour and a distance (infinity: sky). Where the distance jumps, or (`contrast`) the light does, more rays.
    static func primary(w: Int, h: Int, tier: Int, hdr: UnsafeMutablePointer<LitV3>, depth: UnsafeMutablePointer<Float>, jump: Float = 0.05, contrast: Float = 0.3,
                        ray: (Float, Float) -> (LitV3, Float)) {
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let r = ray(Float(x) + 0.5, Float(y) + 0.5)
                hdr[y * w + x] = r.0
                depth[y * w + x] = r.1
            }
        }
        let hot = LitAA.contrast(hdr, depth: depth, w: w, h: h, enabled: tier > 0, threshold: contrast)
        defer { hot.deallocate() }
        let fix = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        defer { fix.deallocate() }
        let n = tier == 0 ? 2 : 4
        // The edge test reads a still copy of the depths, so that the outcome does not hang on which row a thread got to first.
        let seen = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { seen.deallocate() }
        seen.update(from: depth, count: w * h)
        litParallelFor(h, chunk: 4) { y in
            for x in 0..<w {
                let i = y * w + x
                fix[i] = hdr[i]
                let d0 = seen[i]
                var edge = false
                var yy = max(0, y - 1)
                while yy <= min(h - 1, y + 1) && !edge {
                    var xx = max(0, x - 1)
                    while xx <= min(w - 1, x + 1) {
                        let d1 = seen[yy * w + xx]
                        if (d0 == .infinity) != (d1 == .infinity) || (d0 != .infinity && abs(d1 - d0) > min(d0, d1) * jump) { edge = true; break }
                        xx += 1
                    }
                    yy += 1
                }
                if edge {
                    var sum = LitV3.zero
                    var near = d0
                    var o = 0
                    while o < n {
                        let ox: Float = n == 2 ? (o == 0 ? 0.25 : 0.75) : (o == 0 ? 0.375 : (o == 1 ? 0.875 : (o == 2 ? 0.125 : 0.625)))
                        let oy: Float = n == 2 ? (o == 0 ? 0.3 : 0.7) : Float(o) * 0.25 + 0.125
                        let r = ray(Float(x) + ox, Float(y) + oy)
                        sum += r.0
                        near = min(near, r.1)
                        o += 1
                    }
                    fix[i] = sum / Float(n)
                    if near != .infinity { depth[i] = near }
                } else if hot[i] != 0 {
                    fix[i] = (hdr[i] + ray(Float(x) + 0.25, Float(y) + 0.3).0 + ray(Float(x) + 0.75, Float(y) + 0.7).0) * (1.0 / 3.0)
                }
            }
        }
        litParallelFor(h, chunk: 16) { y in
            for x in 0..<w { hdr[y * w + x] = fix[y * w + x] }
        }
    }

    /// Forest on the low ground: not too steep, thinned by noise.
    static func plantForest(_ L: inout LitHeightLayer, treeLine: Float, seed: UInt32, top: Float = 36) {
        let L0 = L
        let m = L.aoN
        let f = UnsafeMutablePointer<Float>.allocate(capacity: m * m)
        let c = L.size / Float(m - 1), x0 = L.x0, z0 = L.z0
        litParallelFor(m, chunk: 8) { z in
            for x in 0..<m {
                let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                let y = L0.hAt(wx, wz)
                let e = c * 2
                let sx = (L0.hAt(wx + e, wz) - L0.hAt(wx - e, wz)) / (2 * e)
                let sz = (L0.hAt(wx, wz + e) - L0.hAt(wx, wz - e)) / (2 * e)
                let s = (sx * sx + sz * sz).squareRoot()
                let n1 = litFbm(wx / 420, wz / 420, 3, seed &+ 50)
                let tl = treeLine + n1 * 200
                let v = litSstep(0.4, 3.0, y) * (1 - litSstep(tl - 170, tl, y)) * (1 - litSstep(1.5, 2.3, s + n1 * 0.3))
                f[z * m + x] = litSat(v * (0.9 + 0.8 * litFbm(wx / 140, wz / 140, 3, seed &+ 51)))
            }
        }
        L.forest = f
        L.forestTop = top
    }

    /// Near conifers, dark against what is behind them: farthest first, each painted branch by branch.
    struct NearTree: Sendable { var x: Float, z: Float, y: Float, h: Float, slim: Float, seed: UInt32 }

    static func paintTrees(_ trees: [NearTree], cam: LitCamera, hdr: UnsafeMutablePointer<LitV3>, w: Int, h: Int, color: (NearTree, Float, Float, LitV3) -> LitV3) {
        if trees.isEmpty { return }
        let sprites = UnsafeMutablePointer<LitTreeSprite>.allocate(capacity: trees.count)
        defer { sprites.deallocate() }
        litParallelFor(trees.count, chunk: 1) { i in
            let t = trees[i]
            sprites[i] = LitSpruce.raster(pixelHeight: t.h * cam.f / t.z, seed: t.seed, slim: t.slim)
        }
        defer { for i in 0..<trees.count { sprites[i].free() } }
        for i in 0..<trees.count {
            let tr = trees[i], sp = sprites[i]
            let s = cam.f / tr.z
            let baseU = cam.cx + (tr.x - cam.ro.x) * s
            let baseV = cam.horizon + (cam.ro.y - tr.y) * s
            let ox = Int(baseU) - sp.baseX, oy = Int(baseV) - sp.baseY
            litParallelFor(sp.h, chunk: 16) { sy in
                let yy = oy + sy
                if yy < 0 || yy >= h { return }
                for sx in 0..<sp.w {
                    let xx = ox + sx
                    if xx < 0 || xx >= w { continue }
                    let a = sp.cover[sy * sp.w + sx]
                    if a < 0.003 { continue }
                    let rel = Float(sp.baseY - sy) / max(1, Float(sp.h))
                    let i = yy * w + xx
                    hdr[i] = litLerp(hdr[i], color(tr, sp.shade[sy * sp.w + sx], rel, hdr[i]), a)
                }
            }
        }
    }

    /// Low haze of a valley: thick in the bottom `H` metres, the colour of the sky at the horizon.
    @inline(__always) static func haze(_ c: LitV3, camY: Float, t: Float, yEnd: Float, H: Float, k: Float, air: LitV3) -> LitV3 {
        let dy = yEnd - camY
        let h0 = expf(-camY / H)
        let I: Float = abs(dy) < 0.5 ? t * h0 : t * H / dy * (h0 - expf(-yEnd / H))
        let T = expf(-k * max(0, I))
        return c * T + air * (1 - T)
    }
}

// MARK: Scene: last light on a massif

nonisolated extension LitArt {
    static func alpenglow(_ plan: LitPlan, dark: Bool) -> CGImage? {
        let w = plan.w, h = plan.h, tier = plan.tier
        let (maxN, erodeN) = plan.grid
        let seed: UInt32 = 6120
        // A wedge coming in from the right and going out of the frame there, the summit high in the picture, its long ridge stepping down to the left into a valley that runs away into the blue.
        let K: Float = 1.8
        let peaks: [LitPeak] = [
            LitPeak(x: 700 * K, z: 4700 * K, h: 1.00, r: 2500 * K, power: 0.82),
            LitPeak(x: 1250 * K, z: 4950 * K, h: 0.90, r: 2000 * K, power: 0.9),
            LitPeak(x: 2300 * K, z: 5000 * K, h: 0.84, r: 2500 * K, power: 0.92),
            LitPeak(x: 3600 * K, z: 5200 * K, h: 0.78, r: 2600 * K, power: 1.0),
            LitPeak(x: 150 * K, z: 5100 * K, h: 0.60, r: 1500 * K, power: 1.0),
            LitPeak(x: -620 * K, z: 5000 * K, h: 0.40, r: 1500 * K, power: 1.1),
            LitPeak(x: -1500 * K, z: 5400 * K, h: 0.24, r: 1500 * K, power: 1.2),
            LitPeak(x: -2900 * K, z: 5900 * K, h: 0.17, r: 1800 * K, power: 1.2),
            LitPeak(x: 1500 * K, z: 2850 * K, h: 0.11, r: 1900 * K, power: 1.1),
            LitPeak(x: 2500 * K, z: 2700 * K, h: 0.14, r: 2100 * K, power: 1.15),
            LitPeak(x: -4300 * K, z: 9500 * K, h: 0.27, r: 2500 * K, power: 1.1),
            LitPeak(x: -1700 * K, z: 9900 * K, h: 0.30, r: 2500 * K, power: 1.1),
            LitPeak(x: -1150 * K, z: 1250 * K, h: 0.065, r: 1000 * K, power: 1.2),
            LitPeak(x: 950 * K, z: 1300 * K, h: 0.085, r: 1200 * K, power: 1.2),
        ]
        var spec = LitTerrainSpec(x0: -5200 * K, z0: 250 * K, size: 10400 * K, seed: seed, shape: { x, z in
            let wx = x + 700 * litFbm(x / 3000, z / 3000, 3, seed &+ 1)
            let wz = z + 700 * litFbm(x / 3000 + 9, z / 3000, 3, seed &+ 2)
            var m: Float = 0
            for p in peaks {
                let dx = wx - p.x, dz = wz - p.z
                let r = (dx * dx + dz * dz).squareRoot() / p.r
                if r < 1 { m = max(m, p.h * powf(1 - r, p.power)) }
            }
            let rr = litRidged(wx / 3200, wz / 3200, 5, seed &+ 3)
            return (m * (0.62 + 0.62 * rr) + 0.03 + 0.012 * litFbm(x / 500, z / 500, 2, seed &+ 4)) * litSstep(300 * K, 1900 * K, z) * (1 - 0.35 * litSstep(3800 * K, 5150 * K, abs(x)))
        }, isBase: { _, z in z < 500 * K }, top: 8400)
        spec.detail = 9
        spec.talus = 0.88
        spec.hardness = { x, z in 0.68 + 0.78 * litSat(0.5 + 1.7 * litFbm(x / 1600, z / 1600, 3, seed &+ 30)) }
        spec.scarpDir = litNorm2(LitV2(0.3, -0.95))
        spec.scarpGain = 0.14
        spec.bedAmp = 0.40
        spec.bedSpacing = 290
        var L = LitErosion.build(spec, maxN: maxN, erodeN: erodeN)
        defer { L.free() }
        // The coarser grids keep a taller, thinner summit than the full erosion leaves; bring them to its height, so the tile shows the picture you get.
        if tier < 2 {
            let k: Float = tier == 0 ? 0.86 : 0.96, hp = L.h, nn = L.n
            litParallelFor(nn, chunk: 32) { z in for x in 0..<nn { hp[z * nn + x] *= k } }
        }
        let seen: @Sendable (Float, Float) -> Bool = { x, z in abs(x) < z * 0.5 + 400 }
        L.addScree(rate: 0.7, minHeight: 400, seed: seed &+ 80)
        var blockOct: [(lambda: Float, amp: Float)] = [(lambda: 420, amp: 60), (lambda: 170, amp: 28)]
        if tier > 0 { blockOct.append((lambda: 70, amp: 11)) }
        L.addBlocks(seed: seed &+ 70, octaves: blockOct, visible: seen)
        L.addGullies(seed: seed &+ 40, lambda: 500, octaves: tier == 2 ? 4 : (tier == 1 ? 3 : 2), depth: 0.08, visible: seen)
        L.addSnowSlide(line: 2500, band: 1100, amount: 46, steepLimit: 96, seed: seed &+ 75, patch: 7, ribMargin: 4.5)
        if let sn = L.snow {
            // Below the pack's real edge a stray patch reads as a tick mark, not as snow.
            let hp = L.h, n = L.n, c = L.cell, x0 = L.x0, z0 = L.z0
            litParallelFor(n, chunk: 8) { z in
                for x in 0..<n {
                    let i = z * n + x
                    let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                    sn[i] = min(sn[i], (hp[i] - 2300 + 900 * litFbm(wx / 1500, wz / 1500, 3, seed &+ 92)) / 14)
                }
            }
        }
        L.buildCurve()
        let treeLine: Float = 2150
        LitCommon.plantForest(&L, treeLine: treeLine, seed: seed)
        L.buildMips()
        let LL = L

        // The sun is about to go: it reaches only the high ground, red through all that air; the valley is already in the blue.
        let sun = litNorm3(dark ? LitV3(0.56, 0.012, -0.83) : LitV3(0.56, 0.02, -0.83))
        let camY: Float = 560
        let A = LitAtmosphere(sunDir: sun, sunE: LitV3(1, 0.97, 0.92) * 34, altBase: 2300, camY: camY,
                           turbidity: 0.9, skyGain: dark ? 1.35 : 1.9, msGain: 1.9, airGain: 0.3, ozone: dark ? 2.1 : 1.3)
        defer { A.free() }
        LL.buildShadow(sun: sun, softness: 26)
        do {
            // The shadow of the Earth, climbing the wall; in the blue hour only the top still has any of it.
            let line: Float = (dark ? 4800 : 4450) * (tier == 0 ? 0.86 : (tier == 1 ? 0.96 : 1))
            let sh = LL.shadow, hp = LL.h, n = LL.n, c = LL.cell, x0 = LL.x0, z0 = LL.z0
            litParallelFor(n, chunk: 8) { z in
                for x in 0..<n {
                    let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                    let i = z * n + x
                    let y = hp[i] + 300 * litFbm(wx / 2000, wz / 2000, 2, seed &+ 90) + wx * 0.05
                    sh[i] *= litSstep(line - 110, line + 170, y)
                }
            }
        }
        LL.buildAO()
        var ambLand = LitAmbient(atmos: A, ground: LitV3(0.05, 0.06, 0.07) * (dark ? 0.2 : 1.4)).scaled(dark ? 1.1 : 1.15)
        do {
            // The shade of the valley is blue, not the mauve of the sky overhead.
            let cool = LitV3(0.74, 0.92, 1.16)
            ambLand.a0 *= cool; ambLand.ax *= cool; ambLand.ay *= cool; ambLand.az *= cool
            // The bright side of the sky lights the shade from one side, and that is what gives a wall in shadow its form.
            let glow: LitV3 = ambLand.a0 * LitV3(1.05, 1.0, 0.92) * 0.68
            ambLand.ax += glow * sun.x
            ambLand.az += glow * sun.z
        }
        let rig = LitLightRig(sun: sun, ambient: ambLand, bounce: dark ? 0.6 : 0.5)
        var look = LitLandLook(snowLine: 2650, treeLine: treeLine, seed: seed)
        look.snow = LitV3(0.84, 0.85, 0.88)
        look.snowBand = 1300
        look.edgeScale = 1.6
        look.snowRelief = dark ? 0.35 : 0.6

        let fw = Float(w), fh = Float(h)
        let f = max(min(1.75 * fw, 0.81 * fh), 0.72 * fw)
        let cam = LitCamera(ro: LitV3(120 * K + 480, camY, 0), f: f, cx: fw * 0.5, horizon: fh * 0.72)
        let hdr = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        let depth = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { hdr.deallocate(); depth.deallocate() }

        // The band of pink over the Earth's shadow, in the sky away from the sun.
        let anti = litNorm3(LitV3(-sun.x, 0, -sun.z))
        @inline(__always) func skyAt(_ rd: LitV3) -> LitV3 {
            var c = A.sky(rd)
            if !dark {
                let e = rd.y
                let away = litSat(0.5 + 0.5 * litDot3(litNorm3(LitV3(rd.x, 0, rd.z)), anti))
                let belt = litSstep(0.0, 0.07, e) * (1 - litSstep(0.08, 0.30, e))
                c += LitV3(0.30, 0.12, 0.14) * (belt * (0.35 + 0.65 * away))
                c *= LitV3(1, 1, 1) - LitV3(0.25, 0.22, 0.12) * ((1 - litSstep(0.0, 0.05, e)) * away)
            }
            return c
        }
        let airCol = rig.ambient.irradiance(LitV3(0, 1, 0)) * LitV3(0.8, 0.95, 1.2) * (dark ? 0.26 : 0.12)
        let treeF = LL.forest!
        LitCommon.primary(w: w, h: h, tier: tier, hdr: hdr, depth: depth, contrast: dark ? 0.5 : 0.3) { px, py in
            let rd = cam.dir(px, py)
            let hit = LL.trace(ro: cam.ro, rd: rd, tmin: 0.5, tmax: 90000) { xx, zz, tt in
                let g = LL.hAt(xx, zz)
                let m = LL.field(treeF, LL.aoN, xx, zz)
                return tt < 7000 ? g + LitLand.tree(xx, zz, mask: m, seed: seed) : g + 15 * m
            }
            if hit < .infinity {
                let p = cam.ro + rd * hit
                let lit = LitLand.shade(layer: LL, p: p, rd: rd, t: hit, pixel: hit / f, atmos: A, rig: rig, look: look)
                let air = A.aerial(ro: cam.ro, rd: rd, t: hit, steps: 5)
                return (LitCommon.haze(lit * air.trans + air.add, camY: camY, t: hit, yEnd: p.y, H: 640, k: dark ? 0.00026 : 0.00013, air: airCol), hit)
            }
            return (skyAt(rd), .infinity)
        }
        if dark { addStars(hdr, depth: depth, w: w, h: h, cam: cam, density: 900, gain: 0.22, seed: seed, unitW: fw) }

        // A veil of high cloud that still has the sun.
        let tex = litMakeCloudTextures(seed: seed &+ 900, shapeN: tier == 0 ? 32 : 64, detailN: tier == 0 ? 16 : 32)
        defer { tex.shape.free(); tex.detail.free() }
        let wN = tier == 2 ? 1024 : (tier == 1 ? 512 : 256)
        let wxA = litMakeWeather(n: wN, half: 110000) { x, z in
            let n = litFbm(x / 5200, z / 14000, 5, seed &+ 903) * 0.5 + 0.5
            let big = litFbm(x / 40000 + 3, z / 40000, 2, seed &+ 904)
            return litSat((n - (dark ? 0.5 : 0.40) + big * 0.2) * 3)
        }
        defer { wxA.deallocate() }
        let layers = UnsafeMutablePointer<LitCloudLayer>.allocate(capacity: 1)
        defer { layers.deallocate() }
        layers[0] = LitCloudLayer(base: 8600, top: 9600, scale: 7000, detailScale: 1200, vstretch: 0.25, sigma: 0.0065, erode: 0.62, weather: wxA, wN: wN, half: 110000,
                               fadeBottom: 0.2, fadeTopFrom: 0.5, shearX: 2500, minStep: 150, stepK: 0.01, lightSteps: 2, lightFirst: 200, lightGrow: 2, massGain: 1.3)
        for i in 0..<1 { layers[i].edgeFade = true }
        var clouds = LitClouds(shape: tex.shape, detail: tex.detail, layers: layers, count: 1)
        clouds.sun = sun
        clouds.g1 = 0.72; clouds.g2 = -0.25; clouds.gMix = 0.7
        clouds.sunGain = dark ? 0.5 : 1
        clouds.ambTop = rig.ambient.irradiance(LitV3(0, 1, 0)) * 1.6
        clouds.ambBottom = rig.ambient.irradiance(LitV3(0, -1, 0)) * 1.6 + clouds.ambTop * 0.25
        let cbuf = LitCloudPass.render(clouds, A: A, cam: cam, fw: w, fh: h, scale: tier > 0 ? 2 : 1, depth: depth, refine: tier > 0 ? 0.03 : nil)
        defer { cbuf.free() }
        litParallelFor(h, chunk: 8) { y in
            for x in 0..<w {
                let i = y * w + x
                let (ci, ct) = cbuf.sample(x: Float(x) + 0.5, y: Float(y) + 0.5, depth: depth[i])
                hdr[i] = hdr[i] * ct + ci
            }
        }

        var g = LitGrade()
        g.exposure = dark ? 0.58 : 1.55
        g.vignette = 0.2
        if !dark { g.gain = LitV3(0.95, 0.98, 1.05) }
        if dark {
            g.gain = LitV3(0.84, 0.94, 1.14)
            g.ceiling = 0.72
        }
        return LitPost.finish(hdr: hdr, w: w, h: h, outW: plan.outW, outH: plan.outH, grade: g, seed: seed)
    }
}

// MARK: Scene: a frozen lake under the aurora

/// A level camera with its lens shifted: the horizon stays straight, verticals stay upright, and a long exposure of the northern sky is framed from a tripod low over the ice.
nonisolated struct LitShiftCam: Sendable {
    let f: Float, cx: Float, hz: Float
    @inline(__always) func dir(_ px: Float, _ py: Float) -> LitV3 { litNorm3(LitV3((px - cx) / f, (hz - py) / f, 1)) }
    @inline(__always) func project(_ d: LitV3) -> (x: Float, y: Float, front: Float) { (cx + f * d.x / d.z, hz - f * d.y / d.z, d.z) }
}

/// One auroral arc. Its lower hem is drawn as a path on the sky (tangent of the azimuth, tangent of the elevation), which fixes it on the ground: the hem stands at 100 km. Over every point of it stands a field line, and the air along that line glows.
nonisolated struct LitAuroraRibbon: Sendable {
    var points: [LitV2]
    var gain: Float
    var reach: Float
    var seed: UInt32
}

nonisolated enum LitAuroraPaint {
    @inline(__always) private static func spline(_ p: [LitV2], _ u: Float) -> LitV2 {
        let n = p.count
        let k = min(n - 4, max(0, Int(u)))
        let t = u - Float(k)
        let p0 = p[k], p1 = p[k + 1], p2 = p[k + 2], p3 = p[k + 3]
        let t2 = t * t, t3 = t2 * t
        let a: LitV2 = p1 * 2 + (p2 - p0) * t
        let b: LitV2 = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
        let c: LitV2 = (p1 * 3 - p0 - p2 * 3 + p3) * t3
        return (a + b + c) * 0.5
    }

    /// Adds each ribbon to `buf` (w × h), line by line, each sample worth what it gives along a ray: E dA / d². A sheet seen edge-on piles up by itself, which is what draws a fold.
    static func paint(_ ribbons: [LitAuroraRibbon], cam: LitShiftCam, w: Int, h: Int, into buf: UnsafeMutablePointer<LitV3>) {
        let f2 = cam.f * cam.f
        let fw = Float(w), fh = Float(h)
        let green = LitV3(0.075, 1.0, 0.40), yellow = LitV3(0.20, 1.0, 0.26), top = LitV3(0.30, 0.13, 0.62), rim = LitV3(0.60, 0.14, 0.50)
        for r in ribbons {
            let umax = Float(r.points.count - 3)
            let sdA = r.seed, sdB = r.seed &+ 1, sdC = r.seed &+ 2, sdD = r.seed &+ 3, sdE = r.seed &+ 4, sdF = r.seed &+ 5, sdG = r.seed &+ 6, sdH = r.seed &+ 7
            @inline(__always) func ground(_ u: Float) -> (x: Float, z: Float) {
                let q = spline(r.points, u)
                let z0 = 100 / max(0.04, q.y)
                let wob = z0 * 0.018
                let z = z0 + wob * (litFbm(u * 2.3, 0.7, 3, sdG) + 0.5 * litGnoise(u * 13, 2.1, sdG))
                // The sideways wander is what pleats the curtain: where it runs back on itself the sheet turns edge-on and draws a bright fold.
                let x = q.x * z + z * 0.040 * litFbm(u * 2.9, 5.7, 3, sdH)
                return (x, z)
            }
            var u: Float = 0, s: Float = 0
            var line: Int32 = 0
            while u < umax {
                let p = ground(u), q = ground(u + 1e-3)
                let dd: Float = max(4, ((p.z - 100) * 0.4 + 100) * 0.0) + 100
                let pa = (cam.f * p.x / p.z, cam.f * dd / p.z), pb = (cam.f * q.x / q.z, cam.f * dd / q.z)
                let img = (((pb.0 - pa.0) * (pb.0 - pa.0) + (pb.1 - pa.1) * (pb.1 - pa.1)).squareRoot()) / 1e-3
                let wrl = (((q.x - p.x) * (q.x - p.x) + (q.z - p.z) * (q.z - p.z)).squareRoot()) / 1e-3
                let du = min(0.55 / max(1e-3, img), 0.6 / max(1e-3, wrl))
                let ds = wrl * du
                defer { u += du; s += ds; line &+= 1 }
                // Patches along the arc, single rays and the finest threads of them.
                let macro = 0.30 + 0.70 * litSstep(-0.34, 0.26, litFbm(s / 95, 0.37, 2, sdA))
                let meso = 0.55 + 0.95 * litSat(0.5 + 1.3 * litFbm(s / 9, 1.37, 2, sdB))
                let fine = 0.72 + 0.56 * litSat(0.5 + 1.6 * litFbm(s / 1.7, 2.37, 2, sdC))
                let tall = 0.72 * litSat(0.5 + 1.5 * litFbm(s / 5.6, 3.37, 2, sdD)) + 0.28 * litSat(0.5 + 1.2 * litFbm(s / 48, 4.37, 2, sdE))
                let H = (13 + 60 * tall * tall) * r.reach
                let u0 = 5 + 9 * litSat(0.5 + 1.4 * litGnoise(s / 26, 8.1, sdF))
                let power = macro * meso * fine * r.gain
                if power < 0.003 { continue }
                let h0 = 100 + 2.6 * litGnoise(s / 21, 5.37, sdF) + 0.9 * litGnoise(s / 4.2, 6.37, sdF)
                let hTop = min(380, h0 + 4.8 * H + 60)
                // The lines all lean to one point above the picture, each a little its own way.
                let lx = 0.012 + 0.05 * litGnoise(s / 34, 7.37, sdB)
                let lz = 0.17 + 0.05 * litGnoise(s / 70, 8.37, sdB)
                let x0 = p.x - lx * 100, z0 = p.z - lz * 100
                let bot = (cam.cx + cam.f * (x0 + lx * h0) / (z0 + lz * h0), cam.hz - cam.f * h0 / (z0 + lz * h0))
                let tp = (cam.cx + cam.f * (x0 + lx * hTop) / (z0 + lz * hTop), cam.hz - cam.f * hTop / (z0 + lz * hTop))
                if (bot.0 < -3 && tp.0 < -3) || (bot.0 > fw + 3 && tp.0 > fw + 3) { continue }
                let span = ((tp.0 - bot.0) * (tp.0 - bot.0) + (tp.1 - bot.1) * (tp.1 - bot.1)).squareRoot()
                let n = max(4, min(1400, Int(span / 0.8)))
                let dh = (hTop - h0 + 3) / Float(n)
                // Each line starts somewhere else within its first step, or the lines would beat against the pixels.
                let jit = litUnit(litHash32(line, 17, r.seed))
                var i = 0
                while i < n {
                    let hh = h0 - 3 + (Float(i) + jit) * dh
                    i += 1
                    let up = hh - h0
                    let rise = litSstep(-3, u0, up)
                    let decay = expf(-max(0, up - u0) / H)
                    let wx = x0 + lx * hh, wz = z0 + lz * hh
                    if wz < 5 { continue }
                    let px = cam.cx + cam.f * wx / wz, py = cam.hz - cam.f * hh / wz
                    if px < 0 || py < 0 || px >= fw - 1 || py >= fh - 1 { continue }
                    let d2 = wx * wx + hh * hh + wz * wz
                    let sinE = hh / d2.squareRoot()
                    let air = expf(-0.035 / max(0.012, sinE))
                    let warmth = 1 - litSstep(0, 26, up)
                    var c: LitV3 = litLerp(green, yellow, warmth) * (rise * decay)
                    c += top * (0.040 * litSstep(40, 150, up) * litSat((hTop - hh) / 60))
                    c += rim * (0.035 * rise * (1 - litSat(up / 7)))
                    let weight = power * air * dh * ds * f2 / d2
                    let col = c * weight
                    let ix = Int(px), iy = Int(py)
                    let ax = px - Float(ix), ay = py - Float(iy)
                    let k = iy * w + ix
                    buf[k] += col * ((1 - ax) * (1 - ay))
                    buf[k + 1] += col * (ax * (1 - ay))
                    buf[k + w] += col * ((1 - ax) * ay)
                    buf[k + w + 1] += col * (ax * ay)
                }
            }
        }
    }

    /// Smooth (cubic B-spline) look-up.
    @inline(__always) static func sample(_ b: UnsafePointer<LitV3>, _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> LitV3 {
        let fx = max(1, min(Float(w) - 3.001, x - 0.5)), fy = max(1, min(Float(h) - 3.001, y - 0.5))
        let ix = Int(fx), iy = Int(fy)
        let tx = fx - Float(ix), ty = fy - Float(iy)
        @inline(__always) func wts(_ t: Float) -> SIMD4<Float> {
            let t2 = t * t, t3 = t2 * t
            return SIMD4((1 - 3 * t + 3 * t2 - t3) / 6, (4 - 6 * t2 + 3 * t3) / 6, (1 + 3 * t + 3 * t2 - 3 * t3) / 6, t3 / 6)
        }
        let wx = wts(tx), wy = wts(ty)
        var out = LitV3.zero
        for j in 0..<4 {
            let row = (iy + j - 1) * w + ix - 1
            let v: LitV3 = b[row] * wx[0] + b[row + 1] * wx[1] + b[row + 2] * wx[2] + b[row + 3] * wx[3]
            out += v * wy[j]
        }
        return out
    }

    /// Distance to the nearest edge of a jittered cell pattern: the cracks in lake ice.
    @inline(__always) static func crack(_ x: Float, _ z: Float, cell: Float, seed: UInt32) -> Float {
        let qx = x / cell, qz = z / cell
        let fx = qx.rounded(.down), fz = qz.rounded(.down)
        let ix = Int32(fx), iz = Int32(fz)
        var d1: Float = 9, d2: Float = 9
        var dz: Int32 = -1
        while dz <= 1 {
            var dx: Int32 = -1
            while dx <= 1 {
                let h = litHash32(ix + dx, iz + dz, seed)
                let cx = Float(ix + dx) + Float(h & 0x3FF) / 1024, cz = Float(iz + dz) + Float((h >> 10) & 0x3FF) / 1024
                let d = ((qx - cx) * (qx - cx) + (qz - cz) * (qz - cz)).squareRoot()
                if d < d1 { d2 = d1; d1 = d } else if d < d2 { d2 = d }
                dx += 1
            }
            dz += 1
        }
        return (d2 - d1) * cell * 0.5
    }
}

nonisolated extension LitArt {
    static func aurora(_ plan0: LitPlan, dark: Bool) -> CGImage? {
        let plan = plan0.enlarged(1.6)
        let w = plan.w, h = plan.h, tier = plan.tier
        let (maxN, erodeN) = plan.grid
        let seed: UInt32 = 9150
        let fw = Float(w), fh = Float(h)
        // A wide lens, low over the ice: the horizon at 78% of the height, the mountains only a low band over it.
        let f = max(0.55 * fh, 0.62 * fw)
        let hzY = fh * 0.78
        let cam = LitShiftCam(f: f, cx: fw * 0.5, hz: hzY)
        let camY: Float = 4
        let ro = LitV3(0, camY, 0)

        // The far range, 12 to 30 km off.
        let peaks: [LitPeak] = [
            LitPeak(x: -9500, z: 17000, h: 0.92, r: 5200, power: 1.0),
            LitPeak(x: -4400, z: 19500, h: 0.78, r: 5000, power: 1.05),
            LitPeak(x: 700, z: 16500, h: 1.00, r: 5400, power: 1.0),
            LitPeak(x: 5600, z: 19000, h: 0.74, r: 5000, power: 1.05),
            LitPeak(x: 10500, z: 17500, h: 0.86, r: 5200, power: 1.0),
            LitPeak(x: 15500, z: 19000, h: 0.70, r: 5000, power: 1.05),
            LitPeak(x: -15000, z: 19500, h: 0.72, r: 5000, power: 1.05),
        ]
        var spec = LitTerrainSpec(x0: -18000, z0: 6000, size: 36000, seed: seed, shape: { x, z in
            let wx = x + 1100 * litFbm(x / 5200, z / 5200, 3, seed &+ 1)
            let wz = z + 1100 * litFbm(x / 5200 + 9, z / 5200, 3, seed &+ 2)
            var m: Float = 0
            for p in peaks {
                let dx = wx - p.x, dz = wz - p.z
                let r = (dx * dx + dz * dz).squareRoot() / p.r
                if r < 1 { m = max(m, p.h * powf(1 - r, p.power)) }
            }
            let rr = litRidged(wx / 5200, wz / 5200, 5, seed &+ 3)
            return (m * (0.62 + 0.62 * rr) + 0.02) * litSstep(8500, 12500, z)
        }, isBase: { _, z in z < 8500 }, top: 1750)
        spec.talus = 0.8
        spec.hardness = { x, z in 0.8 + 0.42 * litSat(0.5 + 1.4 * litFbm(x / 2600, z / 2600, 3, seed &+ 30)) }
        spec.scarpDir = litNorm2(LitV2(0.2, -0.95))
        spec.scarpGain = 0.1
        var L = LitErosion.build(spec, maxN: maxN, erodeN: erodeN)
        defer { L.free() }
        L.buildMips()
        let LL = L
        // Where the light is. By day low on the right, just under the horizon, raking the faces of the range; by night a faint skylight from behind the viewer's shoulder.
        let key = dark ? litNorm3(LitV3(-0.55, 0.42, -0.72)) : litNorm3(LitV3(0.90, 0.16, -0.12))
        LL.buildShadow(sun: key, softness: 40)
        LL.buildAO()

        // The aurora itself, on a half-size buffer: soft enough, and a long exposure softens it more.
        let bw = max(8, w / 2), bh = max(8, h / 2)
        let aur = UnsafeMutablePointer<LitV3>.allocate(capacity: bw * bh)
        aur.initialize(repeating: .zero, count: bw * bh)
        defer { aur.deallocate() }
        let camB = LitShiftCam(f: f * Float(bw) / fw, cx: Float(bw) * 0.5, hz: hzY * Float(bh) / fh)
        let ribbons: [LitAuroraRibbon] = [
            // Far away, low: the arc that lies along the range and goes down behind it.
            LitAuroraRibbon(points: [LitV2(-1.6, 0.040), LitV2(-0.95, 0.044), LitV2(-0.48, 0.064), LitV2(-0.12, 0.050), LitV2(0.22, 0.058), LitV2(0.62, 0.066), LitV2(1.05, 0.044), LitV2(1.6, 0.045)], gain: 0.50, reach: 1.25, seed: seed &+ 40),
            // The great curtain: low on the left, rising to the right in one long S.
            LitAuroraRibbon(points: [LitV2(-1.6, 0.165), LitV2(-0.95, 0.178), LitV2(-0.54, 0.205), LitV2(-0.31, 0.262), LitV2(-0.13, 0.330), LitV2(0.02, 0.365), LitV2(0.13, 0.378), LitV2(0.215, 0.402), LitV2(0.285, 0.448), LitV2(0.40, 0.515), LitV2(0.60, 0.575), LitV2(0.92, 0.70), LitV2(1.5, 0.94)], gain: 1.0, reach: 1, seed: seed &+ 50),
        ]
        LitAuroraPaint.paint(ribbons, cam: camB, w: bw, h: bh, into: aur)
        // A long exposure holds the brightest parts back rather than burning them white.
        let knee: Float = 0.95
        for i in 0..<(bw * bh) {
            let c = aur[i]
            let m = max(c.x, max(c.y, c.z))
            if m > 1e-5 { aur[i] = c * (1 / (1 + (m / knee) * (m / knee)).squareRoot()) }
        }
        let aurC = UnsafePointer<LitV3>(aur)

        // What the air does with it: a wide faint glow around the bright parts.
        let gw = max(4, bw / 6), gh = max(4, bh / 6)
        let glow = UnsafeMutablePointer<LitV3>.allocate(capacity: gw * gh)
        let glowT = UnsafeMutablePointer<LitV3>.allocate(capacity: gw * gh)
        defer { glow.deallocate(); glowT.deallocate() }
        var mean = LitV3.zero
        for y in 0..<gh {
            for x in 0..<gw {
                var s = LitV3.zero
                let x0 = x * bw / gw, x1 = max(x0 + 1, (x + 1) * bw / gw), y0 = y * bh / gh, y1 = max(y0 + 1, (y + 1) * bh / gh)
                var yy = y0
                while yy < y1 {
                    var xx = x0
                    while xx < x1 { s += aur[yy * bw + xx]; xx += 1 }
                    yy += 1
                }
                s /= Float((x1 - x0) * (y1 - y0))
                glow[y * gw + x] = s
                mean += s
            }
        }
        mean /= Float(gw * gh)
        let gr = max(2, gw / 16)
        for _ in 0..<2 {
            for y in 0..<gh {
                var acc = LitV3.zero
                for k in -gr...gr { acc += glow[y * gw + min(gw - 1, max(0, k))] }
                for x in 0..<gw {
                    glowT[y * gw + x] = acc / Float(2 * gr + 1)
                    acc += glow[y * gw + min(gw - 1, x + gr + 1)] - glow[y * gw + max(0, x - gr)]
                }
            }
            for x in 0..<gw {
                var acc = LitV3.zero
                for k in -gr...gr { acc += glowT[min(gh - 1, max(0, k)) * gw + x] }
                for y in 0..<gh {
                    glow[y * gw + x] = acc / Float(2 * gr + 1)
                    acc += glowT[min(gh - 1, y + gr + 1) * gw + x] - glowT[max(0, y - gr) * gw + x]
                }
            }
        }
        let glowC = UnsafePointer<LitV3>(glow)
        let aurGain: Float = dark ? 0.50 : 0.085
        let glowGain: Float = dark ? 0.30 : 0.05
        let aurTint = dark ? LitV3(1, 1, 1) : LitV3(0.95, 1.0, 0.98)
        @inline(__always) func auroraAt(_ px: Float, _ py: Float) -> LitV3 {
            let sx = px * Float(bw) / fw, sy = py * Float(bh) / fh
            let a = LitAuroraPaint.sample(aurC, bw, bh, sx, sy)
            let gx = max(0, min(Float(gw) - 1.001, px * Float(gw) / fw - 0.5)), gy = max(0, min(Float(gh) - 1.001, py * Float(gh) / fh - 0.5))
            let ix = Int(gx), iy = Int(gy)
            let ax = gx - Float(ix), ay = gy - Float(iy)
            let g0 = litLerp(glowC[iy * gw + ix], glowC[iy * gw + ix + 1], ax)
            let g1 = litLerp(glowC[(iy + 1) * gw + ix], glowC[(iy + 1) * gw + ix + 1], ax)
            return (a * aurGain + litLerp(g0, g1, ay) * glowGain) * aurTint
        }

        // The sky without the aurora.
        let sunAz = litNorm2(LitV2(0.97, 0.24))
        let cloudSd = seed &+ 70
        @inline(__always) func baseSky(_ rd: LitV3) -> LitV3 {
            let e = max(0, rd.y)
            if dark {
                // Deep blue overhead; a little green airglow low down.
                let zen = LitV3(0.0032, 0.0048, 0.0110), low = LitV3(0.0085, 0.0135, 0.0210)
                var c = litLerp(low, zen, litSstep(0.0, 0.42, e))
                c += LitV3(0.002, 0.0080, 0.0045) * expf(-e * 11)
                return c
            }
            // Before dawn, with the sun some way under the horizon: pale gold low down on the sun's side, the pale green-blue of polar twilight above it, a clean blue at the top.
            let az = 0.5 + 0.5 * (rd.x * sunAz.x + rd.z * sunAz.y) / max(0.05, (rd.x * rd.x + rd.z * rd.z).squareRoot())
            let warm = az * az
            let a0 = LitV3(0.30, 0.50, 0.86), a1 = LitV3(0.50, 0.73, 0.94), a2 = LitV3(0.82, 0.90, 0.92)
            var c = litLerp(a2, a1, litSstep(0.04, 0.34, e))
            c = litLerp(c, a0, litSstep(0.30, 1.05, e))
            // The band of warm light along the horizon.
            let band = expf(-e / (0.040 + 0.085 * warm))
            let peach = litLerp(LitV3(0.98, 0.84, 0.84), LitV3(1.65, 1.02, 0.66), warm)
            c = litLerp(c, peach, band * (0.60 + 0.40 * warm))
            // Thin high cloud, drawn out and only touched with the coming light.
            if rd.y > 0.03 {
                let tx = rd.x / rd.y, tz = rd.z / rd.y
                let wisp = litFbm((tx * 0.86 + tz * 0.5) * 0.30, (-tx * 0.5 + tz * 0.86) * 1.45, 4, cloudSd)
                let cover = litSstep(0.08, 0.50, wisp + 0.22 * litFbm(tx * 0.1 + 3, tz * 0.1, 2, cloudSd &+ 1)) * litSat(rd.y * 6)
                c = litLerp(c, litLerp(LitV3(1.05, 0.90, 0.92), LitV3(1.35, 0.92, 0.82), band), cover * 0.40)
            }
            return c
        }

        // Lit by what there is: the sky and, at night, the aurora.
        let auroraE: LitV3 = mean * (aurGain * 3.14159 * 0.42) * (dark ? 4 : 1)
        let skyE: LitV3 = dark ? LitV3(0.050, 0.066, 0.110) : LitV3(1.30, 1.65, 2.05)
        let keyE: LitV3 = dark ? LitV3(0.24, 0.30, 0.46) : LitV3(2.6, 1.55, 1.02)
        let hazeCol: LitV3 = dark ? LitV3(0.009, 0.016, 0.024) + mean * (aurGain * 0.10) : LitV3(0.80, 0.82, 0.86)

        @inline(__always) func hazed(_ c: LitV3, _ t: Float, _ k: Float) -> LitV3 { litLerp(hazeCol, c, expf(-t * k)) }
        let hazeK: Float = dark ? 0.00003 : 0.000034
        // The far shore: its distance and its trees, one column at a time.
        @inline(__always) func shoreD(_ u: Float) -> Float {
            2600 + 900 * litFbm(u * 3.2, 1.3, 3, seed &+ 80)
        }
        let sTree = seed &+ 81
        @inline(__always) func treeTop(_ u: Float, _ D: Float) -> Float {
            // A tree every few metres, its top a spike over the general level of the wood.
            let X = u * D
            let cell: Float = 6.5
            let q = X / cell
            let i0 = q.rounded(.down)
            var top: Float = 0
            var k: Int32 = -1
            let level = 17 + 9 * litFbm(X / 90, 0.3, 2, sTree) + 6 * litFbm(X / 22, 1.3, 2, sTree &+ 1)
            while k <= 1 {
                let id = Int32(i0) + k
                let hs = litHash32(id, 7, sTree &+ 2)
                let cx = Float(id) + 0.2 + 0.6 * litUnit(hs)
                let tall = level * (0.72 + 0.55 * litUnit(hs &* 0x9E37_79B1))
                let wd: Float = 0.62
                let v = tall * (1 - min(1, abs(q - cx) / wd))
                top = max(top, v)
                k += 1
            }
            return max(top, level * 0.62)
        }
        @inline(__always) func hillTop(_ u: Float, _ d: Float, _ a: Float, _ sd: UInt32) -> Float {
            let X = u * d
            let body = a * (0.42 + 0.85 * litSat(0.5 + 1.5 * litFbm(X / 1250, 2.1, 3, sd)))
            return body + 9 * litFbm(X / 60, 3.1, 2, sd &+ 1) + 5 * litFbm(X / 16, 4.1, 2, sd &+ 2)
        }
        let forestAlb = dark ? LitV3(0.05, 0.065, 0.06) : LitV3(0.030, 0.042, 0.042)
        @inline(__always) func wood(_ X: Float, _ y: Float, _ t: Float) -> LitV3 {
            // Standing timber, close enough to show as clumps and shaded sides of clumps.
            let clump = 0.62 + 0.76 * litSat(0.5 + 1.4 * litFbm(X / 220, y / 90, 3, sTree &+ 3))
            let side = litSat(0.5 + 2.2 * litFbm(X / 70, y / 40, 2, sTree &+ 4))
            let e: LitV3 = skyE * (0.6 + 0.3 * clump) + keyE * (0.42 * side * clump) + auroraE * 0.7
            return forestAlb * e * (1 / Float.pi) * clump
        }
        @inline(__always) func mountain(_ p: LitV3, _ t: Float) -> LitV3 {
            let c = LL.cell
            let hx = LL.hAt(p.x + c, p.z) - LL.hAt(p.x - c, p.z), hz = LL.hAt(p.x, p.z + c) - LL.hAt(p.x, p.z - c)
            let n = litNorm3(LitV3(-hx / (2 * c), 1, -hz / (2 * c)))
            let steep = (1 - n.y * n.y).squareRoot()
            let vis = LL.field(LL.ao, LL.aoN, p.x, p.z)
            let sh = LL.field(LL.shadow, LL.n, p.x, p.z)
            let tone = 0.75 + 0.5 * litSat(0.5 + 1.2 * litFbm(p.x / 500, p.z / 500 + p.y / 240, 3, seed &+ 90))
            // Dark rock under a thin, even dust of snow; no bright fields to fight the sky.
            let alb = litLerp(LitV3(0.070, 0.074, 0.085) * tone, LitV3(0.30, 0.32, 0.36) * tone, (1 - litSstep(0.34, 0.80, steep)) * 0.8)
            let ndl = max(0, litDot3(n, key))
            let e: LitV3 = skyE * (0.65 * vis * (0.5 + 0.5 * n.y)) + keyE * (ndl * sh) + auroraE * (0.8 * vis)
            return alb * e * (1 / Float.pi)
        }

        // The view above the ice, with more rays where the distance jumps.
        let topRows = min(h, Int(hzY) + 5)
        let hdr = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        let depth = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { hdr.deallocate(); depth.deallocate() }
        LitCommon.primary(w: w, h: topRows, tier: tier, hdr: hdr, depth: depth, jump: 0.03, contrast: dark ? 0.7 : 0.5) { px, py in
            let rd = cam.dir(px, py)
            let u = rd.x / rd.z, e = rd.y / rd.z
            let D = shoreD(u)
            let treeE = (treeTop(u, D) - camY) / D
            if e < treeE {
                return (hazed(wood(u * D, e * D, D), D, hazeK), D)
            }
            // Wooded hills between the shore and the range.
            let d1: Float = 5200, d2: Float = 8600
            let top1 = (hillTop(u, d1, 150, seed &+ 83) - camY) / d1
            if e < top1 {
                return (hazed(wood(u * d1, e * d1, d1), d1, hazeK * 1.3), d1)
            }
            let top2 = (hillTop(u, d2, 260, seed &+ 86) - camY) / d2
            if e < top2 {
                return (hazed(wood(u * d2, e * d2, d2), d2, hazeK * 1.4), d2)
            }
            if e < 0.2 {
                let hit = LL.trace(ro: ro, rd: rd, tmin: 9000, tmax: 60000) { xx, zz, _ in LL.hAt(xx, zz) }
                if hit < .infinity {
                    let p = ro + rd * hit
                    return (hazed(mountain(p, hit), hit, hazeK), hit)
                }
            }
            return (baseSky(rd) + auroraAt(px, py), .infinity)
        }
        if dark {
            let camS = LitCamera(ro: ro, f: f, cx: fw * 0.5, horizon: hzY)
            addStars(hdr, depth: depth, w: w, h: topRows, cam: camS, density: 1400, gain: tier == 0 ? 0.11 : 0.3, seed: seed, unitW: fw)
        }

        // The ice mirrors all of that.
        let mirrorRows = min(h, Int(hzY) + 2)
        let sat = LitColumnSAT(UnsafePointer(hdr), w: w, h: mirrorRows)
        defer { sat.free() }
        let windC: Float = 0.90, windS: Float = 0.44
        let s1 = seed &+ 100, s2 = seed &+ 101, s3 = seed &+ 102, s4 = seed &+ 103, s5 = seed &+ 104, s6 = seed &+ 105, s7 = seed &+ 106, s8 = seed &+ 107
        @inline(__always) func cover(_ a: Float, _ b: Float, _ foot: Float) -> Float {
            var v = litFbm(a / 230, b / 70, 3, s1) * 1.15 + litFbm(a / 38, b / 11, 3, s2) * 0.60
            if foot < 2.4 { v += litFbm(a / 6.2, b / 1.8, 3, s3) * 0.27 }
            return v
        }
        /// The snow's own surface: wind-cut ridges, sharp on one side.
        @inline(__always) func sastrugi(_ a: Float, _ b: Float, _ foot: Float) -> Float {
            if foot > 0.5 { return 0 }
            let warp = litFbm(a / 3.4, b / 1.9, 2, s4) * 0.7
            let q = b / 0.62 + warp
            let r1 = 1 - abs(litGnoise(a / 4.6, q, s4 &+ 1)) * 2.2
            let r2 = 1 - abs(litGnoise(a / 1.7 + 4, q * 2.7, s4 &+ 2)) * 2.2
            let fade = 1 - litSstep(0.14, 0.5, foot)
            return (max(0, r1) * 0.085 + max(0, r2) * 0.028) * fade
        }
        let keyFlat = litNorm3(LitV3(key.x, dark ? 0.28 : 0.20, key.z))
        let snowAlb = LitV3(0.86, 0.89, 0.93)
        let bodyIce: LitV3 = dark ? LitV3(0.0020, 0.0038, 0.0056) : LitV3(0.14, 0.23, 0.31)
        let threshold: Float = dark ? 0.05 : 0.03
        @inline(__always) func iceAt(_ px: Float, _ py: Float) -> LitV3 {
            let rd = cam.dir(px, py)
            let down = max(1e-5, -rd.y)
            let t = camY / down
            let X = rd.x * t, Z = rd.z * t
            let foot = t / f / max(0.02, down)
            let a = X * windC + Z * windS, b = -X * windS + Z * windC
            let v = cover(a, b, foot)
            let edge = 0.016 + min(0.25, foot * 0.02)
            let snowK = litSstep(threshold - edge, threshold + edge, v)
            // A dusting, ahead of the drift, in streaks along the wind.
            let streak = foot < 3 ? litFbm(a / 2.4, b / 0.36, 2, s5) : 0
            let dust = litSstep(threshold - 0.34, threshold, v) * litSat(0.38 + 1.8 * streak)
            // The relief, in the light that comes low across the ice.
            let e = max(0.025, foot * 0.8)
            let s0 = sastrugi(a, b, foot)
            let vx = cover(a + e * windC, b - e * windS, foot) + sastrugi(a + e * windC, b - e * windS, foot) / 0.42
            let vz = cover(a + e * windS, b + e * windC, foot) + sastrugi(a + e * windS, b + e * windC, foot) / 0.42
            let v0 = v + s0 / 0.42
            let relief: Float = dark ? 0.20 : 0.42
            let n = litNorm3(LitV3(-(vx - v0) / e * relief, 1, -(vz - v0) / e * relief))
            let lit = dark ? litSstep(-0.25, 0.65, litDot3(n, keyFlat)) : litSstep(0.0, 0.34, litDot3(n, keyFlat))
            let thick = 0.74 + 0.26 * litSstep(threshold, threshold + 0.20, v)
            let hemi = 0.80 + 0.20 * n.y
            let grit = foot < 0.2 ? 0.965 + 0.07 * litSat(0.5 + 1.8 * litFbm(a / 0.16, b / 0.09, 2, s4 &+ 3)) : 1
            let snow: LitV3 = snowAlb * ((skyE * hemi + auroraE) * thick + keyE * (lit * 0.72)) * (grit / Float.pi)
            // Glare ice: a sheet of dark glass, wavering a little, with clouded bands inside it.
            let wv = t < 700 ? litFbm(X / 6, Z / 2.4, 2, s5 &+ 1) * 0.012 * litSat(1 - t / 700) : 0
            let wu = t < 700 ? litFbm(X / 4 + 5, Z / 7, 2, s6) * 0.006 * litSat(1 - t / 700) : 0
            let r = litNorm3(LitV3(rd.x + wu, down + wv + 0.0005, rd.z))
            let pr = cam.project(r)
            let spread = 3 + 13 * litSat(1 - t / 90) + 4 * litSat(0.5 + litFbm(X / 30, Z / 11, 2, s7) * 1.6)
            let col = sat.blur(u: pr.x, v: min(pr.y, Float(mirrorRows) - 1), r: spread * fh / 1400)
            let fr = 0.045 + 0.955 * powf(1 - down, 4.6)
            let cloud = litSat(0.5 + 1.5 * litFbm(a / 16, b / 5, 3, s8))
            let bubbles = t < 60 ? litSat(0.5 + 2.0 * litFbm(X / 0.7, Z / 0.7, 2, s8 &+ 1)) * (1 - litSstep(14, 60, t)) : 0
            let white: LitV3 = snowAlb * (skyE + auroraE * 1.3 + keyE * 0.14) * (1 / Float.pi)
            var ice: LitV3 = litLerp(bodyIce * (0.72 + 0.56 * cloud), col, fr)
            ice = litLerp(ice, white, 0.05 * cloud + 0.05 * bubbles)
            // Cracks, white where they are full of air, with a pale sheet of broken ice standing under each.
            if t < 300 {
                let fade = 1 - litSstep(90, 300, t)
                let wob = litFbm(X / 3.1, Z / 3.1, 2, s5 &+ 9) * 1.3
                let c1 = LitAuroraPaint.crack(X + wob, Z - wob, cell: 13, seed: s6 &+ 9)
                let ww = max(0.014, foot * 0.55)
                let vary = 0.55 + 0.9 * litSat(0.5 + 1.6 * litFbm(X / 5, Z / 5, 2, s7 &+ 3))
                var line = (1 - litSstep(ww * 0.5, ww * 1.6, c1)) * min(1, 0.028 / ww + 0.22) * vary
                let sheet = expf(-c1 / max(ww * 3, 0.10)) * 0.16 * vary
                line = max(line, sheet)
                if t < 90 {
                    let c2 = LitAuroraPaint.crack(X - wob * 0.6, Z + wob * 0.8, cell: 3.9, seed: s6 &+ 10)
                    let w2 = max(0.006, foot * 0.5)
                    line = max(line, (1 - litSstep(w2 * 0.5, w2 * 1.6, c2)) * 0.5 * min(1, 0.011 / w2 + 0.18) * (1 - litSstep(30, 90, t)))
                }
                ice = litLerp(ice, white, min(1, line) * fade * 0.8)
            }
            ice = litLerp(ice, snow, dust * 0.55)
            return hazed(litLerp(ice, snow, snowK), t, hazeK * 2.2)
        }
        litParallelFor(h - topRows + 6, chunk: 4) { yy in
            let y = topRows - 6 + yy
            if y < 0 || y >= h { return }
            for x in 0..<w {
                let i = y * w + x
                if y < topRows {
                    // The shore's foot: only what is ice in those last rows.
                    let rd = cam.dir(Float(x) + 0.5, Float(y) + 0.5)
                    if rd.y >= -1e-5 { continue }
                    let D = shoreD(rd.x / rd.z)
                    if camY / -rd.y > D * 0.98 { continue }
                }
                hdr[i] = iceAt(Float(x) + 0.5, Float(y) + 0.5)
            }
        }
        var g = LitGrade()
        g.exposure = 1
        g.vignette = dark ? 0.22 : 0.12
        g.saturation = dark ? 1.04 : 1
        if dark { g.ceiling = 0.74 }
        return LitPost.finish(hdr: hdr, w: w, h: h, outW: plan.outW, outH: plan.outH, grade: g, seed: seed)
    }
}

// MARK: Scene: a layered canyon, far above its river

nonisolated struct LitCanyonRock: @unchecked Sendable {
    /// Colour of the rock per half metre of height: each bed pale on its top ledge, dark under its lip.
    let col: UnsafeMutablePointer<LitV3>
    let n: Int
    init(seed: UInt32) {
        // Bottom to top: dark basement, brown ledge, grey-green slope, the great red cliff, red ledges, red slope, pale cliff, tan slope, pale cap.
        let beds: [(top: Float, c: LitV3, bed: Float, cut: Float)] = [
            (250, LitV3(0.085, 0.066, 0.070), 26, 0.30),
            (335, LitV3(0.270, 0.170, 0.110), 12, 0.42),
            (640, LitV3(0.240, 0.172, 0.108), 15, 0.22),
            (870, LitV3(0.400, 0.130, 0.062), 38, 0.34),
            (1150, LitV3(0.330, 0.130, 0.075), 11, 0.60),
            (1285, LitV3(0.410, 0.155, 0.085), 14, 0.30),
            (1420, LitV3(0.600, 0.400, 0.235), 30, 0.30),
            (1490, LitV3(0.440, 0.245, 0.140), 10, 0.36),
            (1800, LitV3(0.480, 0.350, 0.235), 15, 0.46),
        ]
        n = 3800
        col = .allocate(capacity: n)
        var st = UInt64(seed) &+ 99
        func rnd() -> Float {
            st &+= 0x9E37_79B9_7F4A_7C15
            var z = st
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(z >> 40) * (1.0 / 16777216.0)
        }
        var k = 0
        var bedBottom: Float = 0
        var bedTop: Float = 0
        var bedTone: Float = 1
        for i in 0..<n {
            let y = Float(i) * 0.5
            let wob = litGnoise(y / 9, 2.2, seed &+ 1) * 4
            while k < beds.count - 1 && y + wob > beds[k].top { k += 1 }
            if y >= bedTop {
                bedBottom = y
                bedTop = y + beds[k].bed * (0.45 + 1.1 * rnd())
                bedTone = 0.82 + 0.36 * rnd()
            }
            let s = (y - bedBottom) / max(0.5, bedTop - bedBottom)
            // Undercut at the foot of a bed, pale along its upper lip.
            let edge = 1 - 0.55 * beds[k].cut * powf(1 - s, 3) + beds[k].cut * 0.25 * powf(s, 6)
            let lam = 1 + 0.22 * litGnoise(y / 31, 1.1, seed &+ 2) + 0.05 * litGnoise(y / 3.7, 7.7, seed &+ 4)
            col[i] = beds[k].c * max(0.3, lam * edge * bedTone)
        }
    }
    func free() { col.deallocate() }
    @inline(__always) func at(_ y: Float, pixel: Float) -> LitV3 {
        let v = max(0, min(Float(n) - 1.01, y * 2))
        let i = Int(v)
        if pixel < 3 { return litLerp(col[i], col[i + 1], v - Float(i)) }
        // Further off, a few metres of beds averaged so they do not shimmer.
        let r = min(40, Int(pixel))
        let a = max(0, i - r), b = min(n - 1, i + r)
        return (col[a] + col[i] * 2 + col[b] + col[(a + i) / 2] + col[(i + b) / 2]) * (1.0 / 6.0)
    }
}

/// The ground as "worn surface pushed through the beds": a smooth worn height per grid point goes through one table
/// of hard and soft rock when a ray asks, so a ledge is sharp at any distance, however coarse the grid.
nonisolated struct LitCanyonStrata: @unchecked Sendable {
    let table: UnsafeMutablePointer<Float>
    let tableN: Int
    let tableTop: Float
    let src: UnsafeMutablePointer<Float>
    let res: UnsafeMutablePointer<Float>
    let n: Int
    let x0: Float, z0: Float, inv: Float
    init(n: Int, x0: Float, z0: Float, size: Float, tableN: Int, tableTop: Float) {
        self.n = n; self.x0 = x0; self.z0 = z0; inv = Float(n - 1) / size
        self.tableN = tableN; self.tableTop = tableTop
        table = .allocate(capacity: tableN)
        src = .allocate(capacity: n * n)
        res = .allocate(capacity: n * n)
    }
    func free() { table.deallocate(); src.deallocate(); res.deallocate() }
    @inline(__always) func lift(_ s: Float) -> Float {
        let v = max(0, min(Float(tableN) - 1.01, s / tableTop * Float(tableN - 1)))
        let i = Int(v)
        return table[i] + (table[i + 1] - table[i]) * (v - Float(i))
    }
    @inline(__always) func sample(_ x: Float, _ z: Float) -> (s: Float, r: Float) {
        let fx = max(0, min(Float(n - 1) - 0.001, (x - x0) * inv)), fz = max(0, min(Float(n - 1) - 0.001, (z - z0) * inv))
        let ix = Int(fx), iz = Int(fz)
        let ax = fx - Float(ix), az = fz - Float(iz)
        let i = iz * n + ix
        let sa = src[i] + (src[i + 1] - src[i]) * ax, sb = src[i + n] + (src[i + n + 1] - src[i + n]) * ax
        let ra = res[i] + (res[i + 1] - res[i]) * ax, rb = res[i + n] + (res[i + n + 1] - res[i + n]) * ax
        return (sa + (sb - sa) * az, ra + (rb - ra) * az)
    }
}

nonisolated extension LitArt {
    static func canyon(_ plan0: LitPlan, dark: Bool) -> CGImage? {
        let plan = plan0.enlarged(1.6)
        let w = plan.w, h = plan.h, tier = plan.tier
        // This scene's grid holds three tables as well as the ground: it erodes at one level below the largest.
        let (maxN, erodeN) = plan.tier == 2 ? (1025, 513) : plan.grid
        let seed: UInt32 = 7301
        let rim: Float = 1700
        // The river swings across the view and goes out of it behind the far buttes.
        let riverX: @Sendable (Float) -> Float = { z in 170 + 270 * sinf(z * 0.0025 + 2.2) + 60 * sinf(z * 0.0063 + 1.3) }
        let buttes: [LitPeak] = [
            LitPeak(x: -120, z: 5000, h: 1.2, r: 620, power: 0.32),
            LitPeak(x: 1250, z: 4100, h: 1.2, r: 520, power: 0.32),
            LitPeak(x: -1650, z: 3500, h: 1.2, r: 560, power: 0.32),
            LitPeak(x: 900, z: 6900, h: 1.2, r: 800, power: 0.32),
            LitPeak(x: -1300, z: 6500, h: 1.2, r: 760, power: 0.32),
        ]
        var spec = LitTerrainSpec(x0: -5500, z0: 0, size: 11000, seed: seed, shape: { x, z in
            let wx = x + 240 * litFbm(x / 1100, z / 1100, 3, seed &+ 1)
            let wz = z + 240 * litFbm(x / 1100 + 9, z / 1100, 3, seed &+ 2)
            let d = abs(wx - riverX(wz))
            let width = 1250 + 0.2 * max(0, wz) + 420 * litFbm(wx / 1500, wz / 1500, 2, seed &+ 5)
            var m = 1.2 * powf(litSstep(22, width, d), 0.6)
            // Long side canyons wander back into the plateau, and it is lower close under the camera.
            let slot = abs(litFbm(wx / 2600, wz / 2600, 2, seed &+ 6))
            m *= 1 - 0.8 * (1 - litSstep(0.012, 0.075, slot)) * litSstep(100, 500, d)
            m *= 0.5 + 0.5 * litSstep(1000, 2600, wz)
            for p in buttes {
                let dx = wx - p.x, dz = wz - p.z
                let r = (dx * dx + dz * dz).squareRoot() / p.r
                if r < 1 { m = max(m, p.h * powf(1 - r, p.power)) }
            }
            return m + 0.18 * litFbm(x / 1300, z / 1300, 4, seed &+ 3) * litSstep(100, 700, d)
        }, isBase: { x, z in abs(x - riverX(z)) < 22 }, top: 1860)
        spec.detail = 7
        spec.talus = 1.0
        spec.kdt = [0.07, 0.06, 0.05, 0.04]
        spec.hardness = { x, z in 0.9 + 0.5 * litSat(0.5 + 1.4 * litFbm(x / 900, z / 900, 3, seed &+ 30)) }
        var L = LitErosion.build(spec, maxN: maxN, erodeN: erodeN)
        defer { L.free() }
        // Height to height: hard beds stand as cliffs, soft ones lie back as slopes and benches. The plateau is the top of the cap.
        let G = LitCanyonStrata(n: L.n, x0: L.x0, z0: L.z0, size: L.size, tableN: 8192, tableTop: 1860)
        defer { G.free() }
        do {
            let knots: [(y: Float, k: Float)] = [(120, 0.8), (250, 1.6), (330, 5), (385, 0.16), (640, 0.7), (860, 7), (1150, 1.2), (1320, 0.7), (1420, 8), (1490, 0.5), (1660, 4.5), (1700, 0.3), (2300, 0)]
            let lutN = 2400
            let lut = UnsafeMutablePointer<Float>.allocate(capacity: lutN)
            defer { lut.deallocate() }
            // The inverse: where each output height comes from in the eroded ground.
            var acc: Float = 0
            var bedTop: Float = 0, bedSoft: Float = 1
            lut[0] = 0
            var k = 1
            for i in 1..<lutN {
                let out = Float(i)
                while k < knots.count - 1 && out > knots[k].y { k += 1 }
                let steep = max(0.05, knots[k].k)
                // Fine steps in the ledgy beds.
                let step = 1 + 0.72 * sinf(out * 0.13 + 2 * sinf(out * 0.031)) * litSstep(870, 900, out) * (1 - litSstep(1120, 1150, out)) + 0.35 * sinf(out * 0.09) * (1 - litSstep(240, 260, out))
                // Every bed is its own small step: a hard one stands, a soft one lies back under it.
                if out >= bedTop {
                    bedTop = out + 7 + 22 * litUnit(litHash32(Int32(i), 11, seed &+ 53))
                    bedSoft = 0.25 + 2.8 * litUnit(litHash32(Int32(i), 12, seed &+ 54))
                }
                let inBench = 0.15 + 0.85 * litSstep(0.3, 1.2, steep)
                acc += (1 + inBench * (bedSoft - 1)) / (steep * step)
                lut[i] = acc
            }
            // Rescale so that the rim stays at the rim, and invert.
            let scale = 1700 / lut[Int(rim)]
            let tN = G.tableN, tb = G.table
            var o = 1
            for i in 0..<tN {
                let want = Float(i) / Float(tN - 1) * G.tableTop
                while o < lutN - 1 && lut[o] * scale < want { o += 1 }
                let a = lut[o - 1] * scale, b = lut[o] * scale
                tb[i] = min(rim, Float(o - 1) + litSat((want - a) / max(1e-5, b - a)))
            }
            let L0 = L, G0 = G
            let n = L0.n, hp = L0.h, c = L0.cell, x0 = L0.x0, z0 = L0.z0
            let capLut = UnsafePointer(lut), capLutN = lutN, capScale = scale
            // What the rock around each point rises to, so that a tower near the camera can end in a table instead of a dome.
            let topR = max(1, Int((85 / c).rounded()))
            let topA = UnsafeMutablePointer<Float>.allocate(capacity: n * n), topB = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
            defer { topA.deallocate(); topB.deallocate() }
            litParallelFor(n, chunk: 16) { z in
                for x in 0..<n {
                    var m = hp[z * n + x]
                    for o in max(0, x - topR)...min(n - 1, x + topR) { m = max(m, hp[z * n + o]) }
                    topA[z * n + x] = m
                }
            }
            litParallelFor(n, chunk: 16) { z in
                for x in 0..<n {
                    var m = topA[z * n + x]
                    for o in max(0, z - topR)...min(n - 1, z + topR) { m = max(m, topA[o * n + x]) }
                    topB[z * n + x] = m
                }
            }
            let topUp = UnsafePointer(topB)
            litParallelFor(n, chunk: 8) { z in
                for x in 0..<n {
                    let wx = x0 + Float(x) * c, wz = z0 + Float(z) * c
                    let i = z * n + x
                    // The cliff lines wander in plan: bays, points and small notches, at every size the grid can hold.
                    var worn = hp[i] + 44 * litFbm(wx / 640, wz / 640, 2, seed &+ 41)
                    if c < 70 { worn += 26 * litFbm(wx / 240, wz / 240, 2, seed &+ 47) }
                    if c < 24 {
                        worn += 2.2 * litFbm(wx / 90, wz / 90, 2, seed &+ 48)
                        // Joints: the rock comes away in blocks, so a cliff's line turns corners.
                        let ju = (wx * 0.83 + wz * 0.56) / 170 + 0.5 * litFbm(wx / 500, wz / 500, 2, seed &+ 49)
                        let fu = ju.rounded(.down)
                        let jv = (-wx * 0.56 + wz * 0.83) / 96 + 0.5 * litFbm(wx / 500 + 7, wz / 500, 2, seed &+ 50) + litUnit(litHash32(Int32(fu), 3, seed &+ 51)) * 7
                        worn += 5 * (litUnit(litHash32(Int32(fu), Int32(jv.rounded(.down)), seed &+ 52)) - 0.5)
                        let ku = (wx * 0.71 + wz * 0.70) / 340 + 0.6 * litFbm(wx / 800, wz / 800, 2, seed &+ 59)
                        let fk = ku.rounded(.down)
                        let kv = (-wx * 0.70 + wz * 0.71) / 210 + 0.6 * litFbm(wx / 800 + 5, wz / 800, 2, seed &+ 60) + litUnit(litHash32(Int32(fk), 5, seed &+ 61)) * 7
                        worn += 13 * (litUnit(litHash32(Int32(fk), Int32(kv.rounded(.down)), seed &+ 62)) - 0.5)
                    }
                    let d = abs(wx - riverX(wz))
                    let wR = 15 + 5 * litGnoise(wz / 260, 1.5, seed &+ 43)
                    // The inner gorge: nothing lies flat beside the river, the walls start at the water.
                    let dw = max(0, d - wR - 6 + 22 * litFbm(wx / 160, wz / 160, 2, seed &+ 55))
                    let side = abs(litFbm(wx / 520 + 3, wz / 340, 2, seed &+ 57))
                    let cut = 0.76 + 0.24 * litSstep(0.0, 0.26, side)
                    worn = max(worn, dw * (0.62 + (0.68 + 0.5 * litFbm(wx / 500, wz / 500, 2, seed &+ 56)) * litSstep(260, 900, dw)) * cut)
                    // Close under the camera the towers are cut off at a hard bed: it stands as a table with a broken edge, not as a worn thumb of soft rock.
                    let nearK = 1 - litSstep(2600, 4600, wz)
                    if nearK > 0.001 {
                        let dTop = topUp[i] - hp[i]
                        let reach = 70 + 46 * litFbm(wx / 95, wz / 95, 2, seed &+ 63)
                        if dTop < reach {
                            let flat = nearK * (1 - litSstep(reach * 0.72, reach, dTop)) * litSstep(240, 620, dw)
                            worn += flat * (dTop * 0.92 + 2.5 * litFbm(wx / 34, wz / 34, 2, seed &+ 65))
                        }
                        let cellX = (wx / 480 + 1.6 * litFbm(wx / 900, wz / 900, 2, seed &+ 64)).rounded(.down), cellZ = (wz / 390 + 1.6 * litFbm(wx / 900 + 4, wz / 900, 2, seed &+ 67)).rounded(.down)
                        let capStep = (litUnit(litHash32(Int32(cellX), Int32(cellZ), seed &+ 64)) - 0.5) * 150
                        let capBite = 26 * litFbm(wx / 130, wz / 130, 2, seed &+ 65) + 9 * litFbm(wx / 38, wz / 38, 2, seed &+ 66)
                        let capY = litLerp(2299, 1090 + capStep + capBite, 1 - litSstep(1700, 3700, wz))
                        worn = min(worn, capLut[max(0, min(capLutN - 1, Int(capY)))] * capScale)
                    }
                    // The domain's edge is the plateau, and the far rim is no straight line.
                    let wob = 0.10 * litFbm(wx / 1500, wz / 1500, 3, seed &+ 44)
                    let ex = abs(wx) / 5500 + wob, ez = abs(wz - 5500) / 5500 + wob
                    let closed = litSstep(0.60, 0.94, max(ex, ez)) * litSstep(3000, 7000, wz)
                    worn = max(0, min(1859, litLerp(worn, 1790, closed)))
                    // Nothing crosses the river.
                    worn = min(worn, 9 + max(0, d - wR) * 2.2 + 1860 * litSstep(0.3, 0.8, closed))
                    G0.src[i] = worn
                    var y = G0.lift(worn)
                    // A little roll on the plateau.
                    y += litSstep(rim - 40, rim, y) * 5 * litFbm(wx / 300, wz / 300, 2, seed &+ 42)
                    G0.res[i] = y - G0.lift(worn)
                    // On the grid the channel is a little narrower than the exact one, so the walk's upper bound holds.
                    let chan = (1 - litSstep(wR - 5, wR + 9, d)) * (1 - litSstep(0.1, 0.3, closed))
                    y = max(y, 2.5 + (d - wR) * 0.05)
                    hp[i] = litLerp(y, -3, chan)
                }
            }
        }
        // Nothing a single cell wide stands proud: such needles read as flaws, not as rock.
        do {
            let L0 = L
            let n = L0.n, hp = L0.h, lim = L0.cell * 1.4
            let still = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
            defer { still.deallocate() }
            for _ in 0..<2 {
                still.update(from: hp, count: n * n)
                litParallelFor(n - 2, chunk: 16) { zz in
                    let z = zz + 1
                    for x in 1..<(n - 1) {
                        let i = z * n + x
                        let a = (still[i - 1] + still[i + 1] + still[i - n] + still[i + n]) * 0.25
                        if still[i] > a + lim { hp[i] = a + lim }
                    }
                }
            }
        }
        L.buildCurve(wide: 150, narrow: 64)
        L.buildMips(extra: 3)
        let LL = L
        // From this far off the grid draws the beds well enough by itself.
        let sharpTo = LL.cell * 0.8, sharpFrom = LL.cell * 0.45
        let g2 = seed &+ 91, g3 = seed &+ 92
        @inline(__always) func ground(_ x: Float, _ z: Float, _ pixel: Float) -> Float {
            if pixel >= sharpTo { return LL.hAt(x, z) }
            let q = G.sample(x, z)
            // Rock falls away from a ledge in small bites, never out past it, so the walk's upper bound stays good.
            var bite: Float = 0
            if pixel < 6 {
                bite = 2.3 * litGnoise(x / 13, z / 13, g2) - 1.6
                if pixel < 3 { bite += 1.1 * litGnoise(x / 5.5, z / 5.5, g3) }
                bite = min(0, bite)
            }
            var y = G.lift(q.s + bite) + q.r
            if y < 40 {
                // The river's bed is drawn exactly, so that its banks do not show the grid.
                let d = abs(x - riverX(z))
                let wR = 15 + 5 * litGnoise(z / 260, 1.5, seed &+ 43) + 2.5 * litGnoise(x / 21, z / 21, seed &+ 45)
                y = litLerp(max(y, 2.5 + (d - wR) * 0.05), -3, 1 - litSstep(wR, wR + 16, d))
            }
            if pixel <= sharpFrom { return y }
            return y + (LL.hAt(x, z) - y) * ((pixel - sharpFrom) / (sharpTo - sharpFrom))
        }

        // Light: a low sun from the left. The left wall lies in shadow, the right wall burns, the river is already in the blue.
        let sun = litNorm3(dark ? LitV3(0.30, -0.055, 1.0) : LitV3(-0.78, 0.27, -0.32))
        let camY: Float = 2250
        let A = LitAtmosphere(sunDir: sun, sunE: dark ? LitV3(1, 1, 1) * 20 : LitV3(1, 0.93, 0.82) * 21, altBase: 900, camY: camY,
                           turbidity: dark ? 0.8 : 0.9, skyGain: dark ? 2.6 : 1.5, msGain: 1.7, airGain: dark ? 0.4 : 0.3, ozone: dark ? 1.2 : 1.2)
        defer { A.free() }
        if !dark { LL.buildShadow(sun: sun, softness: 30) } else { litParallelFor(LL.n * LL.n, chunk: 65536) { LL.shadow[$0] = 0 } }
        if !dark {
            // A wall's whole height falls in one or two cells of this grid: a little blur keeps them from showing as squares.
            let n = LL.n, sh = LL.shadow
            let tmp = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
            defer { tmp.deallocate() }
            for _ in 0..<2 {
                litParallelFor(n, chunk: 16) { z in
                    let zm = max(0, z - 1) * n, zp = min(n - 1, z + 1) * n, zc = z * n
                    for x in 0..<n {
                        let xm = max(0, x - 1), xp = min(n - 1, x + 1)
                        let e = sh[zc + xm] + sh[zc + xp] + sh[zm + x] + sh[zp + x]
                        tmp[zc + x] = (sh[zc + x] * 2 + e) * (1.0 / 6.0)
                    }
                }
                litParallelFor(n * n, chunk: 65536) { sh[$0] = tmp[$0] }
            }
        }
        LL.buildAO()
        let amb = LitAmbient(atmos: A, ground: LitV3(0.10, 0.06, 0.045) * (dark ? 0.2 : 1.6)).scaled(dark ? 13 : 1)
        let rock = LitCanyonRock(seed: seed)
        defer { rock.free() }

        let fw = Float(w), fh = Float(h)
        let f = max(min(1.75 * fw, 0.81 * fh), 0.72 * fw)
        let cam = LitCamera(ro: LitV3(0, camY, 0), f: f, cx: fw * 0.5, horizon: fh * 0.235)
        let hdr = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        let depth = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { hdr.deallocate(); depth.deallocate() }

        @inline(__always) func land(_ p: LitV3, rd: LitV3, t: Float) -> LitV3 {
            let c = LL.cell, x = p.x, z = p.z
            let pixel = t / f
            // Wider than a cell up close too, or the facets of the grid show on a tall wall as squares of light.
            let dl = max(c * 0.85, min(c, pixel * 0.75))
            let hx = ground(x + dl, z, pixel) - ground(x - dl, z, pixel), hz = ground(x, z + dl, pixel) - ground(x, z - dl, pixel)
            let nG = litNorm3(LitV3(-hx / (2 * dl), 1, -hz / (2 * dl)))
            let steep = (1 - nG.y * nG.y).squareRoot()
            let q = G.sample(x, z)
            let strata = p.y - q.r
            let qx = x * 0.6, qz = strata + z * 0.5
            let nF = litFbm(qx / 130, qz / 90, 2, seed &+ 12)
            let nC = litFbm(qx / 26, qz / 18, 2, seed &+ 13)
            let nD = pixel < 9 ? litFbm(qx / 7.5, qz / 5, 2, seed &+ 16) : 0
            let nW = litFbm(x / 900, z / 900, 2, seed &+ 17)
            // A bed never follows the contour exactly: it wanders, thins and breaks.
            let wander = 3 * nF + 1 * nC + 0.5 * nD + 14 * nW
            let bed = rock.at(strata + wander, pixel: pixel)
            let cliff = litSstep(0.62, 0.86, steep)
            // On the slopes, loose stone washed down from the cliff above covers most of the beds.
            let wash = rock.at(strata + wander + 18 + 34 * litSat(0.5 + nF * 1.5), pixel: 26)
            var alb = litLerp(wash, bed, (0.10 + 0.72 * cliff) * litSat(0.5 + nC * 2.2))
            alb = alb * (1 + 0.24 * nF + 0.16 * nC + 0.10 * nD)
            var cv: Float = 0
            if let cf = LL.curve { cv = LL.field(cf, LL.aoN, x, z) }
            alb = alb * max(0.5, 1 + 0.32 * cv)
            // Dark varnish runs down the walls from the ledges, in long streaks.
            let streak = litFbm(x * 0.8 / 16 - z * 0.6 / 16, strata / 190, 2, seed &+ 14)
            alb = alb * (1 - 0.30 * litSstep(-0.1, 0.34, streak))
            // Joints: dark cracks straight up through the beds, in patches.
            if pixel < 14 {
                let jw = max(1.4, pixel * 0.8)
                let jv = (x * 0.8 - z * 0.6 + 2.5 * nC) / 47
                let jfr = abs(jv - jv.rounded()) * 47
                let gate = litSstep(-0.05, 0.25, litFbm(qx / 60, qz / 22, 2, seed &+ 42))
                alb = alb * (1 - 0.3 * (1 - litSstep(jw * 0.4, jw * 1.6, jfr)) * gate * cliff * litSat((14 - pixel) / 7))
            }
            // Benches and the plateau: dust, and dark scrub in specks and thickets.
            let flat = 1 - litSstep(0.22, 0.56, steep)
            if flat > 0.01 {
                let dust = litLerp(alb, alb * 0.78 + LitV3(0.085, 0.045, 0.024), 0.6)
                let thicket = litFbm(x / 70, z / 70, 2, seed &+ 18)
                alb = alb * (1 + 0.22 * litFbm(x / 210, z / 140, 3, seed &+ 19))
                let up = litSstep(rim - 90, rim - 20, strata)
                // Single bushes up close; further off only how thick they stand.
                let cover = litSat(0.34 + 0.9 * thicket * (1 - 0.6 * litSstep(3, 7, pixel)) + 0.3 * up)
                let specks = pixel < 5 ? litSstep(0.0, 0.3, litFbm(x / 5, z / 5, 2, seed &+ 15) + 0.55 * (cover - 0.5)) : cover
                let scrub = litLerp(litLerp(cover, specks, 0.5), cover, litSstep(2.5, 5, pixel)) * (0.42 + 0.3 * up)
                alb = litLerp(alb, litLerp(dust, LitV3(0.075, 0.075, 0.045), scrub), flat)
            }
            // A pale beach where the rock meets the river.
            if p.y < 3.5 { alb = litLerp(LitV3(0.30, 0.24, 0.17) * (0.85 + 0.3 * litSat(0.5 + nC)), alb, litSstep(0.5, 3.5, p.y)) }
            var n = nG
            if pixel < 40 {
                // Broken faces on the walls; open ground keeps only a trace of them.
                let fade = litSat((40 - pixel) / 24) * (0.2 + 0.8 * cliff)
                let f1 = LitLand.facet(qx, qz, lambda: max(18, pixel * 5), seed: seed &+ 34)
                let f2 = LitLand.facet(qx + 13, qz - 7, lambda: max(7, pixel * 2.4), seed: seed &+ 35)
                n = litNorm3(nG + LitV3((f1.x * 0.14 + f2.x * 0.10) * fade, 0, (f1.y * 0.14 + f2.y * 0.10) * fade))
                alb = alb * (1 + (f1.z * 0.05 + f2.z * 0.05) * fade)
            }
            // Four looks at each grid, turned off its axes: a wall crossing cells must not show them.
            let o1 = c * 0.9, o2 = c * 0.35
            let sh = (LL.field(LL.shadow, LL.n, x + o1, z + o2) + LL.field(LL.shadow, LL.n, x - o2, z + o1) + LL.field(LL.shadow, LL.n, x - o1, z - o2) + LL.field(LL.shadow, LL.n, x + o2, z - o1)) * 0.25
            let visA = LL.field(LL.ao, LL.aoN, x + o1, z + o2) + LL.field(LL.ao, LL.aoN, x - o2, z + o1)
            let vis = (visA + LL.field(LL.ao, LL.aoN, x - o1, z - o2) + LL.field(LL.ao, LL.aoN, x + o2, z - o1)) * 0.25
            let ndl = max(0, litDot3(n, sun))
            let sunC = A.sunColor(y: p.y)
            let sky = amb.irradiance(n) * vis
            // Light handed from wall to wall: what stands in shadow glows from the burning rock across the way.
            let across = max(0, 0.6 + 0.4 * litDot3(n, LitV3(-sun.x, 0.2, -sun.z)))
            let bounce = dark ? LitV3.zero : sunC * LitV3(0.30, 0.15, 0.085) * (across * (1 - 0.6 * sh) * (0.2 + 0.8 * vis))
            return alb * (sunC * (ndl * sh * 0.58) + sky + bounce * 0.7) * (1 / Float.pi)
        }
        @inline(__always) func water(_ p: LitV3, rd: LitV3, t: Float) -> LitV3 {
            let pixel = t / f
            let a = max(pixel * 2, 2.4)
            let nx = litFbm(p.x / (a * 6), p.z / (a * 16), 2, seed &+ 80) * 0.05
            let nz = litFbm(p.x / (a * 6) + 4, p.z / (a * 16), 2, seed &+ 81) * 0.05
            let n = litNorm3(LitV3(nx, 1, nz))
            let r = litReflect3(rd, n)
            let cosI = max(0.02, -litDot3(rd, n))
            let fres = 0.02 + 0.98 * powf(1 - cosI, 5)
            let sh = LL.field(LL.shadow, LL.n, p.x, p.z)
            let up = amb.irradiance(LitV3(0, 1, 0))
            let vis = LL.field(LL.ao, LL.aoN, p.x, p.z)
            // Deep and green down the middle, sandy at the banks, with the current drawn out along its length.
            let dc = p.x - riverX(p.z)
            let bank = litSat(abs(dc) / 24)
            let stream = litFbm(dc / 7, p.z / 90, 3, seed &+ 82)
            var body = litLerp(LitV3(0.070, 0.150, 0.110), LitV3(0.14, 0.16, 0.11), powf(bank, 6))
            body = body * (1 + 0.5 * stream)
            let lightOn = up * (0.35 + 0.65 * vis) + A.sunColor(y: 0) * (max(0, sun.y) * sh * 0.45)
            var col = body * lightOn * (1 / Float.pi)
            // Rapids: a few pale, broken tongues of water.
            let rapid = litSstep(0.28, 0.42, litFbm(p.z / 210, 3.3, 2, seed &+ 83)) * litSstep(0.02, 0.28, litFbm(dc / 6, p.z / 26, 3, seed &+ 84))
            col = litLerp(col, LitV3(0.55, 0.58, 0.56) * lightOn * (1 / Float.pi), rapid * 0.6)
            // It mirrors the sky down the middle and the burning walls towards the banks.
            let skyR = A.sky(litNorm3(LitV3(r.x, abs(r.y), r.z)))
            let wall = dark ? skyR * 0.3 : (A.sunColor(y: 800) * LitV3(0.08, 0.035, 0.02) + up * 0.02)
            let refl = litLerp(skyR * 0.9, wall, 0.35)
            return litLerp(col, refl, dark ? min(1, fres + 0.22) : min(1, fres + 0.06))
        }
        // Beyond the grid: the plateau going off into the haze until it is the sky's own colour.
        @inline(__always) func hazed(_ c: LitV3, _ rd: LitV3, _ tt: Float) -> LitV3 {
            let air = A.aerial(ro: cam.ro, rd: rd, t: min(tt, 14000), steps: 4)
            let thick = 1 - expf(-max(0, tt - 7000) / 19000)
            let veil = A.sky(litNorm3(LitV3(rd.x, 0.002, rd.z)))
            return litLerp(c * air.trans + air.add, veil, thick)
        }
        @inline(__always) func far(_ rd: LitV3) -> (LitV3, Float)? {
            let e = rd.y / rd.z
            let flatLight = A.sunColor(y: rim) * (dark ? LitV3.zero : LitV3(0.16 + 0.07, 0.16 + 0.035, 0.16 + 0.02)) + amb.irradiance(LitV3(0, 1, 0))
            let tp: Float = e < -0.0002 ? (camY - rim + 25) / -rd.y : .infinity
            if tp < 200000 {
                let t = min(tp, 110000)
                let wx = rd.x * t, wz = rd.z * t
                // Dust and juniper, in long bands: the same ground as the rim's.
                let tone = litSat(0.46 + 1.25 * litFbm(wx / 1900, wz / 7000, 3, seed &+ 62))
                let col = litLerp(LitV3(0.21, 0.15, 0.098), LitV3(0.40, 0.28, 0.185), tone)
                return (hazed(col * flatLight * (1 / Float.pi), rd, t), t)
            }
            return nil
        }
        LitCommon.primary(w: w, h: h, tier: tier, hdr: hdr, depth: depth, contrast: dark ? 0.5 : 0.35) { px, py in
            let rd = cam.dir(px, py)
            let tw: Float = rd.y < -1e-5 ? cam.ro.y / -rd.y : .infinity
            let hit = LL.trace(ro: cam.ro, rd: rd, tmin: 5, tmax: min(tw, 40000)) { xx, zz, tt in ground(xx, zz, tt / f) }
            if hit < tw {
                let p = cam.ro + rd * hit
                let air = A.aerial(ro: cam.ro, rd: rd, t: hit, steps: 5)
                return (land(p, rd: rd, t: hit) * air.trans + air.add, hit)
            }
            if tw < .infinity && LL.inside(rd.x * tw, rd.z * tw) {
                let p = cam.ro + rd * tw
                let air = A.aerial(ro: cam.ro, rd: rd, t: tw, steps: 5)
                return (water(p, rd: rd, t: tw) * air.trans + air.add, tw)
            }
            if let r = far(rd) { return r }
            return (A.sky(rd), .infinity)
        }
        if dark { addStars(hdr, depth: depth, w: w, h: h, cam: cam, density: 380, gain: 0.34, seed: seed, unitW: fw) }

        // Soft heaps of cloud over the far rim, a veil higher up.
        let tex = litMakeCloudTextures(seed: seed &+ 900, shapeN: tier == 0 ? 32 : 64, detailN: tier == 0 ? 16 : 32)
        defer { tex.shape.free(); tex.detail.free() }
        let wN = tier == 2 ? 1024 : (tier == 1 ? 512 : 256)
        let wxA = litMakeWeather(n: wN, half: 90000) { x, z in
            let n = litFbm(x / 6000, z / 6000, 5, seed &+ 901) * 0.5 + 0.5
            let big = litFbm(x / 26000, z / 26000, 2, seed &+ 902)
            return litSat((n - (dark ? 0.72 : 0.655) + big * 0.22) * 3.6) * litSstep(9000, 16000, z)
        }
        let wxB = litMakeWeather(n: wN, half: 110000) { x, z in
            let n = litFbm(x / 14000, z / 5200, 5, seed &+ 903) * 0.5 + 0.5
            let big = litFbm(x / 40000 + 3, z / 40000, 2, seed &+ 904)
            return litSat((n - 0.42 + big * 0.2) * 3)
        }
        defer { wxA.deallocate(); wxB.deallocate() }
        let layers = UnsafeMutablePointer<LitCloudLayer>.allocate(capacity: 2)
        defer { layers.deallocate() }
        layers[0] = LitCloudLayer(base: 4700, top: 6800, scale: 6000, detailScale: 620, vstretch: 1.1, sigma: 0.07, erode: 0.5, weather: wxA, wN: wN, half: 90000,
                               fadeBottom: 0.18, fadeTopFrom: 0.25, shearX: 500, minStep: 60, stepK: 0.0075, lightSteps: 6, lightFirst: 50, lightGrow: 1.8, towering: 0.5)
        layers[1] = LitCloudLayer(base: 8600, top: 9400, scale: 7000, detailScale: 1200, vstretch: 0.25, sigma: 0.0055, erode: 0.62, weather: wxB, wN: wN, half: 110000,
                               fadeBottom: 0.2, fadeTopFrom: 0.5, shearX: 2500, minStep: 150, stepK: 0.01, lightSteps: 2, lightFirst: 200, lightGrow: 2, massGain: 1.3)
        for i in 0..<2 { layers[i].edgeFade = true }
        var clouds = LitClouds(shape: tex.shape, detail: tex.detail, layers: layers, count: 2)
        clouds.sun = sun
        clouds.g1 = 0.72; clouds.g2 = -0.25; clouds.gMix = 0.7
        clouds.sunGain = dark ? 0.0 : 1
        clouds.ambTop = amb.irradiance(LitV3(0, 1, 0)) * (dark ? 1.3 : 1.6)
        clouds.ambBottom = amb.irradiance(LitV3(0, -1, 0)) * (dark ? 1.3 : 1.6) + clouds.ambTop * (dark ? 0.6 : 0.25)
        let cbuf = LitCloudPass.render(clouds, A: A, cam: cam, fw: w, fh: h, scale: tier > 0 ? 2 : 1, rows: 0..<Int(cam.horizon + 2), depth: depth, refine: tier > 0 ? 0.03 : nil)
        defer { cbuf.free() }
        let cloudRows = Int(cam.horizon + 2)
        litParallelFor(min(h, cloudRows), chunk: 8) { y in
            for x in 0..<w {
                let i = y * w + x
                let (ci, ct) = cbuf.sample(x: Float(x) + 0.5, y: Float(y) + 0.5, depth: depth[i])
                hdr[i] = hdr[i] * ct + ci
            }
        }
        var g = LitGrade()
        g.exposure = dark ? 1.3 : 1.26
        g.saturation = dark ? 0.95 : 1.2
        g.vignette = 0.22
        if dark {
            g.tint = LitV3(0.46, 0.66, 1.0)
            g.ceiling = 0.68
            g.night = 0.25
        }
        return LitPost.finish(hdr: hdr, w: w, h: h, outW: plan.outW, outH: plan.outH, grade: g, seed: seed)
    }
}

// MARK: Scene: wind-carved dunes at low sun

/// The sand: long windward slope, razor crest, steep slip face. The crest is a kink in a smooth phase field, so it stays sharp at any distance, and the normal comes from a stored gradient, so no grid lines show in the light.
nonisolated struct LitDuneField: @unchecked Sendable {
    static let crest: Float = 0.74
    let n: Int
    let half: Float, cz: Float
    let c: Float
    let phase: UnsafeMutablePointer<Float>
    let gradX: UnsafeMutablePointer<Float>
    let gradZ: UnsafeMutablePointer<Float>
    let amp: UnsafeMutablePointer<Float>
    let small: UnsafeMutablePointer<Float>
    var maxHeight: Float = 0
    init(seed: UInt32, n: Int, half: Float, cz: Float, across: LitV2, wave: Float) {
        self.n = n; self.half = half; self.cz = cz
        c = 2 * half / Float(n - 1)
        let c = self.c
        let count = n * n
        phase = .allocate(capacity: count)
        gradX = .allocate(capacity: count)
        gradZ = .allocate(capacity: count)
        amp = .allocate(capacity: count)
        small = .allocate(capacity: count)
        let phase = self.phase, gradX = self.gradX, gradZ = self.gradZ, amp = self.amp, small = self.small
        litParallelFor(n, chunk: 4) { zi in
            for xi in 0..<n {
                let x = -half + Float(xi) * c, z = cz - half + Float(zi) * c
                let i = zi * n + xi
                let w = 640 * litFbm(x / 1500, z / 1500, 2, seed &+ 1) + 150 * litFbm(x / 380, z / 380, 2, seed &+ 2)
                // Close to the viewer one crest swings through a long S, the way a real one wanders.
                let along = x * across.y - z * across.x
                let near = expf(-((x + 60) * (x + 60) + (z - 520) * (z - 520)) / (900 * 900))
                let hero = near * (66 * sinf(along / 165 + 0.9) + 21 * sinf(along / 61 + 2.3))
                phase[i] = (x * across.x + z * across.y + w + hero) / wave
                let big = litFbm(x / 900, z / 900, 2, seed &+ 4)
                amp[i] = 4 + 24 * litSat(0.55 + 1.9 * big)
                small[i] = litSstep(-0.12, 0.28, litFbm(x / 520, z / 520, 2, seed &+ 5))
            }
        }
        litParallelFor(n, chunk: 16) { zi in
            for xi in 0..<n {
                let i = zi * n + xi
                let xa = max(0, xi - 1), xb = min(n - 1, xi + 1), za = max(0, zi - 1), zb = min(n - 1, zi + 1)
                gradX[i] = (phase[zi * n + xb] - phase[zi * n + xa]) / (Float(xb - xa) * c)
                gradZ[i] = (phase[zb * n + xi] - phase[za * n + xi]) / (Float(zb - za) * c)
            }
        }
        maxHeight = 28 * 1.25
    }
    @inline(__always) func phaseRateX(_ x: Float, _ z: Float) -> Float { gradAt(gradX, x, z) }
    @inline(__always) func phaseRateZ(_ x: Float, _ z: Float) -> Float { gradAt(gradZ, x, z) }
    @inline(__always) private func gradAt(_ g: UnsafeMutablePointer<Float>, _ x: Float, _ z: Float) -> Float {
        let ix = max(0, min(n - 1, Int((x + half) / c + 0.5))), iz = max(0, min(n - 1, Int((z - cz + half) / c + 0.5)))
        return g[iz * n + ix]
    }
    func free() { phase.deallocate(); gradX.deallocate(); gradZ.deallocate(); amp.deallocate(); small.deallocate() }

    /// Ridge profile in 0...1 along a phase: windward up to `crest`, slip face after it.
    @inline(__always) static func profile(_ ph: Float) -> Float {
        let s = ph - ph.rounded(.down)
        if s < crest {
            let u = s / crest
            return u * u * (1.45 - 0.45 * u)
        }
        let u = (s - crest) / (1 - crest)
        return (1 - u) * (1 - 0.6 * u)
    }
    @inline(__always) static func slope(_ ph: Float) -> Float {
        let s = ph - ph.rounded(.down)
        if s < crest {
            let u = s / crest
            return u * (2.9 - 1.35 * u) / crest
        }
        let u = (s - crest) / (1 - crest)
        return (-1.6 + 1.2 * u) / (1 - crest)
    }
    /// Lesser dunes that cross the great ones at an angle.
    @inline(__always) static func minorPhase(_ x: Float, _ z: Float) -> Float {
        let w1 = sinf(x * 0.0048 + 1.3 * sinf(z * 0.0031))
        let w2 = sinf(z * 0.0059 + x * 0.0024)
        return (x * 0.30 + z * 0.95) / 62 + 1.5 * w1 + 1.1 * w2
    }

    @inline(__always) func phaseAt(_ x: Float, _ z: Float) -> Float {
        let fx = max(0, min(Float(n) - 1.001, (x + half) / c)), fz = max(0, min(Float(n) - 1.001, (z - cz + half) / c))
        let ix = Int(fx), iz = Int(fz)
        let ax = fx - Float(ix), az = fz - Float(iz)
        let i = iz * n + ix
        let p0: Float = phase[i] + (phase[i + 1] - phase[i]) * ax
        let p1: Float = phase[i + n] + (phase[i + n + 1] - phase[i + n]) * ax
        return p0 + (p1 - p0) * az
    }
    @inline(__always) private func lerp2(_ g: UnsafeMutablePointer<Float>, _ i: Int, _ ax: Float, _ az: Float) -> Float {
        let p0: Float = g[i] + (g[i + 1] - g[i]) * ax
        let p1: Float = g[i + n] + (g[i + n + 1] - g[i + n]) * ax
        return p0 + (p1 - p0) * az
    }
    @inline(__always) func height(_ x: Float, _ z: Float) -> Float {
        let fx = max(0, min(Float(n) - 1.001, (x + half) / c)), fz = max(0, min(Float(n) - 1.001, (z - cz + half) / c))
        let ix = Int(fx), iz = Int(fz)
        let ax = fx - Float(ix), az = fz - Float(iz)
        let i = iz * n + ix
        let ph = lerp2(phase, i, ax, az), a = lerp2(amp, i, ax, az), m = lerp2(small, i, ax, az)
        let p1 = LitDuneField.profile(ph)
        var h = p1
        if m > 0.001 {
            let on: Float = litSat(p1 * 1.6) * (1 - p1 * p1 * p1) * 0.2 * m
            h += on * LitDuneField.profile(LitDuneField.minorPhase(x, z))
        }
        return a * h
    }
    /// Height, its gradient, and how far along a slip face this point is.
    @inline(__always) func surface(_ x: Float, _ z: Float) -> (h: Float, gx: Float, gz: Float, slip: Float, ph: Float, amp: Float) {
        let fx = max(0, min(Float(n) - 1.001, (x + half) / c)), fz = max(0, min(Float(n) - 1.001, (z - cz + half) / c))
        let ix = Int(fx), iz = Int(fz)
        let ax = fx - Float(ix), az = fz - Float(iz)
        let i = iz * n + ix
        let ph = lerp2(phase, i, ax, az), a = lerp2(amp, i, ax, az), m = lerp2(small, i, ax, az)
        let px = lerp2(gradX, i, ax, az), pz = lerp2(gradZ, i, ax, az)
        let p1 = LitDuneField.profile(ph), d1 = LitDuneField.slope(ph)
        var h = p1
        var gx = d1 * px, gz = d1 * pz
        if m > 0.001 {
            let on: Float = litSat(p1 * 1.6) * (1 - p1 * p1 * p1) * 0.2 * m
            let e: Float = 0.5
            let ph2 = LitDuneField.minorPhase(x, z)
            let qx = (LitDuneField.minorPhase(x + e, z) - ph2) / e, qz = (LitDuneField.minorPhase(x, z + e) - ph2) / e
            let d2 = LitDuneField.slope(ph2)
            h += on * LitDuneField.profile(ph2)
            gx += on * d2 * qx
            gz += on * d2 * qz
        }
        let fr = ph - ph.rounded(.down)
        // 1 at the crest, fading to nothing at the foot of the slip face.
        var slip: Float = 0
        if fr >= LitDuneField.crest {
            let u = (fr - LitDuneField.crest) / (1 - LitDuneField.crest)
            slip = 1 - u * u
        }
        return (a * h, a * gx, a * gz, slip, ph, a)
    }
}

nonisolated extension LitArt {
    static func dunes(_ plan0: LitPlan, dark: Bool) -> CGImage? {
        let plan = plan0.enlarged(2.0)
        let w = plan.w, h = plan.h, tier = plan.tier
        let seed: UInt32 = 8411
        let field = LitDuneField(seed: seed, n: tier == 2 ? 1025 : 513, half: 9000, cz: 8200, across: LitV2(0.74, -0.67), wave: 118)
        defer { field.free() }
        let sun = litNorm3(dark ? LitV3(-0.86, 0.26, 0.42) : LitV3(-0.90, 0.205, 0.40))
        let camY: Float = 84
        let A = LitAtmosphere(sunDir: sun, sunE: dark ? LitV3(0.82, 0.93, 1.16) * 6 : LitV3(1, 0.97, 0.90) * 22, altBase: 300, camY: camY,
                           turbidity: dark ? 0.5 : 0.9, skyGain: dark ? 0.08 : 1.15, msGain: 1.7, airGain: dark ? 0.2 : 0.5, ozone: 1.2)
        defer { A.free() }
        let amb = LitAmbient(atmos: A, ground: dark ? LitV3(0.02, 0.016, 0.012) : LitV3(0.34, 0.20, 0.11)).scaled(dark ? 9 : 0.82)
        let fw = Float(w), fh = Float(h)
        let f = max(1.28 * fw, 0.56 * fh)
        let cam = LitCamera(ro: LitV3(-40, camY, 0), f: f, cx: fw * 0.5, horizon: fh * 0.37)
        let hdr = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        let depth = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        defer { hdr.deallocate(); depth.deallocate() }
        let tFar: Float = 16000

        let top = field.maxHeight
        // The ground under a ray, by marching: bigger steps further off, a bisection at the end so the crest stays clean.
        @inline(__always) func hit(_ rd: LitV3) -> Float {
            if rd.y >= 0.004 { return .infinity }
            var t = max(4, (camY - top) / max(0.001, -rd.y))
            if rd.y > -0.0002 { t = 4 }
            var pt = t
            while t < tFar {
                let x = cam.ro.x + rd.x * t, z = cam.ro.z + rd.z * t, y = cam.ro.y + rd.y * t
                if y <= field.height(x, z) {
                    var a = pt, b = t
                    for _ in 0..<7 {
                        let m = (a + b) * 0.5
                        if cam.ro.y + rd.y * m <= field.height(cam.ro.x + rd.x * m, cam.ro.z + rd.z * m) { b = m } else { a = m }
                    }
                    return b
                }
                pt = t
                t += max(t * 0.012, 0.8)
            }
            return .infinity
        }
        // Towards the sun, crest to crest: each crest is found exactly on the phase field, so a shadow's edge is the true image of the ridge, with the sun's own width as its penumbra.
        @inline(__always) func lit(_ x: Float, _ z: Float, _ y: Float, _ ph0: Float, rate: Float) -> Float {
            let crest = LitDuneField.crest
            var tPrev: Float = 0, phPrev = ph0
            var k0 = (phPrev - crest).rounded(.down)
            var light: Float = 1
            let dt = max(5, min(90, 0.24 / max(0.0005, abs(rate))))
            var i = 0
            while i < 14 {
                let t = tPrev + dt
                if y + 0.15 + sun.y * tPrev > top { return light }
                let ph = field.phaseAt(x + sun.x * t, z + sun.z * t)
                let k = (ph - crest).rounded(.down)
                if k != k0 {
                    let target = max(k, k0) + crest
                    var a = tPrev, b = t, fa = phPrev - target, fb = ph - target
                    for _ in 0..<2 {
                        let m = a + (b - a) * fa / (fa - fb)
                        let fm = field.phaseAt(x + sun.x * m, z + sun.z * m) - target
                        if (fm < 0) == (fa < 0) { a = m; fa = fm } else { b = m; fb = fm }
                    }
                    let tc = a + (b - a) * fa / (fa - fb)
                    let gh = field.height(x + sun.x * tc, z + sun.z * tc)
                    let above = gh - (y + 0.15 + sun.y * tc)
                    light = min(light, litSat(0.5 - above / max(0.14, tc * 0.006)))
                    if light <= 0 { return 0 }
                    k0 = k
                }
                tPrev = t
                phPrev = ph
                i += 1
            }
            return light
        }
        // Starlight has no warmth to give: at night the sand keeps only some of its colour.
        let nightAlb = dark ? LitV3(0.82, 1.12, 1.75) : LitV3(1, 1, 1)
        @inline(__always) func sandAt(_ p: LitV3, rd: LitV3, t: Float) -> LitV3 {
            let pixel = t / f
            let x = p.x, z = p.z
            let sf = field.surface(x, z)
            var n = litNorm3(LitV3(-sf.gx, 1, -sf.gz))
            let slip = sf.slip
            // Swells at every size keep the light moving over a face; at this sun the least tilt shows.
            let se: Float = 9
            let sw0 = litFbm(x / 150, z / 150, 3, seed &+ 26)
            let swx = litFbm((x + se) / 150, z / 150, 3, seed &+ 26), swz = litFbm(x / 150, (z + se) / 150, 3, seed &+ 26)
            let swellK: Float = 2.6 * (1 - litSat(pixel / 6))
            let swell = LitV3(-(swx - sw0) / se * swellK * 150 / 9, 0, -(swz - sw0) / se * swellK * 150 / 9) * 0.075
            n = litNorm3(n + swell)
            // Wind ripples: fine, wavering, in patches; two sets of different spacing that hand over to each other.
            var ripple: Float = 0
            if pixel < 0.34 && slip < 0.98 {
                let warp = litFbm(x / 9, z / 14, 2, seed &+ 20) * 1.3
                let dirU = x * 0.84 - z * 0.54
                let wob = 0.42 * litGnoise(x / 6.5, z / 9, seed &+ 21)
                let which = litSstep(-0.16, 0.16, litFbm(x / 34, z / 34, 2, seed &+ 27))
                @inline(__always) func saw(_ fr: Float) -> Float { fr < 0.72 ? fr / 0.72 : (1 - fr) / 0.28 }
                let u1 = (dirU + warp) / 0.46 + wob, u2 = (dirU * 0.96 + warp * 1.2) / 0.98 + wob * 0.8
                let fr1 = u1 - u1.rounded(.down), fr2 = u2 - u2.rounded(.down)
                let saw1 = saw(fr1), saw2 = saw(fr2)
                let sawM = litLerp(saw1, saw2, which)
                let frM = which < 0.5 ? fr1 : fr2
                let patch = litSstep(0.30, 0.72, 0.5 + 1.2 * litFbm(x / 11, z / 17, 2, seed &+ 25))
                let distFade = litSat((0.34 - pixel) / 0.18)
                let fade = distFade * (1 - slip) * patch
                ripple = (sawM - 0.5) * fade
                let along: Float = frM < 0.72 ? 0.14 : -0.36
                let tiltK: Float = -along * fade * 0.085
                n = litNorm3(n + LitV3(0.84, 0, -0.54) * tiltK)
            }
            let m1 = litFbm(x / 26, z / 26, 3, seed &+ 22)
            let m2 = litFbm(x / 240, z / 240, 2, seed &+ 23)
            var tone: Float = 1 + 0.05 * m1 + 0.14 * m2 + 0.02 * ripple
            // Close up the sand has a grain of its own: lag patches, darker in the troughs of the ripples.
            if pixel < 0.25 {
                tone += (0.020 * litFbm(x / 0.55, z / 0.55, 2, seed &+ 28) + 0.016 * litFbm(x / 2.6, z / 2.6, 2, seed &+ 29)) * litSat(1 - pixel / 0.25)
            }
            // Grain streaks run down a slip face, very faint and only up close.
            if slip > 0.01 && pixel < 0.5 {
                let fall = litFbm((x * 0.54 + z * 0.84) / 3.5, sf.h / 30, 2, seed &+ 24)
                tone *= 1 + 0.03 * fall * slip * litSat(1 - pixel / 0.5)
            }
            let warm = litSat(0.5 + m2 * 1.5)
            let alb = litLerp(LitV3(0.66, 0.285, 0.105), LitV3(0.78, 0.385, 0.155), warm) * tone * nightAlb
            let rate = sun.x * field.phaseRateX(x, z) + sun.z * field.phaseRateZ(x, z)
            let sh = lit(x, z, sf.h, sf.ph, rate: rate)
            let ndl = max(0, litDot3(n, sun))
            let sunC = A.sunColor(y: p.y)
            // Less sky in a trough than on a crest; a slip face looks at the lit flank opposite, more so towards its foot.
            let hFrac = litSat(sf.h / max(1, sf.amp))
            let vis = 0.60 + 0.40 * hFrac
            let sky = amb.irradiance(n) * vis
            let bounce = sunC * LitV3(0.094, 0.050, 0.025) * ((1 - sh * 0.75) * max(0, 0.75 - 0.35 * n.y) * (1 - 0.72 * slip))
            return alb * (sunC * (ndl * sh) + sky + bounce) * (1 / Float.pi)
        }
        // High cloud in thin curls for the day picture; for the night, the galaxy.
        let mwP = litNorm3(LitV3(-0.42, 0.0, 1)), mwQ = litNorm3(LitV3(0.34, 0.56, 1))
        let mwN = litNorm3(simd_cross(mwP, mwQ)), mwS = litNorm3(mwQ - mwP)
        @inline(__always) func skyAt(_ rd: LitV3) -> LitV3 {
            var c = A.sky(LitV3(rd.x, max(rd.y, 0.002), rd.z))
            if dark {
                let b = litDot3(rd, mwN), along = litDot3(rd, mwS)
                let band = expf(-b * b * 46)
                let core = expf(-b * b * 190) * litSat(0.5 - 0.9 * along)
                let dust = litFbm(along * 9 + b * 4, b * 26, 5, seed &+ 30)
                let lane = 1 - 0.72 * litSstep(-0.12, 0.5, dust) * expf(-b * b * 120)
                let clouds: Float = 0.72 + 0.7 * litFbm(along * 6, b * 11, 3, seed &+ 31)
                let air = litSat(rd.y * 7)
                let glow: LitV3 = LitV3(0.55, 0.62, 0.85) * (band * 0.13 * clouds)
                let heart: LitV3 = LitV3(1.0, 0.80, 0.60) * (core * 0.22 * clouds)
                c += LitV3(0.34, 0.42, 0.62) * (0.040 * expf(-max(0, rd.y) * 16))
                c += (glow + heart) * (lane * air)
            } else {
                let tx = rd.x / max(0.02, rd.y), tz = rd.z / max(0.02, rd.y)
                let wisp = litFbm(tx * 0.22, tz * 0.05, 4, seed &+ 32)
                let cover = litSstep(0.1, 0.45, wisp + 0.3 * litFbm(tx * 0.05 + 3, tz * 0.02, 2, seed &+ 33)) * litSat(rd.y * 7)
                c = litLerp(c, A.sunColor(y: 8000) * 0.04 + amb.irradiance(LitV3(0, -1, 0)) * 0.2, cover * 0.3)
                // Dust in the low air.
                c = litLerp(c, c * LitV3(1.02, 0.90, 0.78), expf(-max(0, rd.y) * 7))
            }
            return c
        }
        LitCommon.primary(w: w, h: h, tier: tier, hdr: hdr, depth: depth, jump: 0.06, contrast: dark ? 0.6 : 0.42) { px, py in
            let rd = cam.dir(px, py)
            let t = hit(rd)
            if t == .infinity { return (skyAt(rd), .infinity) }
            let p = cam.ro + rd * t
            let air = A.aerial(ro: cam.ro, rd: rd, t: t, steps: 4)
            // Far off the sand goes into the dusty air, so the ground meets the sky without a ruled line.
            let far = 1 - expf(-t / (dark ? 7000 : 4600))
            let c: LitV3 = litLerp(sandAt(p, rd: rd, t: t) * air.trans + air.add, skyAt(LitV3(rd.x, 0.004, rd.z)), far)
            return (c, t)
        }
        if dark {
            addStars(hdr, depth: depth, w: w, h: h, cam: cam, density: 2600, gain: 0.3, seed: seed, unitW: fw)
            // The galaxy is made of stars: a thick dust of faint ones along the band.
            var st = UInt64(seed) &+ 71
            func rnd() -> Float {
                st &+= 0x9E37_79B9_7F4A_7C15
                var z = st
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                return Float(z >> 40) * (1.0 / 16777216.0)
            }
            let count = Int(26000 * min(1, fw * fh / 700_000))
            for _ in 0..<count {
                let px = rnd() * fw, py = rnd() * cam.horizon
                let rd = cam.dir(px, py)
                let b = litDot3(rd, mwN)
                if rnd() > expf(-b * b * 46) { continue }
                let i = Int(py) * w + Int(px)
                if depth[i] != .infinity { continue }
                let m = rnd()
                hdr[i] += LitV3(0.8, 0.85, 1.0) * ((0.02 + 0.12 * m * m) * litSat(rd.y * 8))
            }
        }
        var g = LitGrade()
        g.exposure = dark ? 0.98 : 1.36
        g.saturation = dark ? 1 : 1.06
        g.vignette = 0.2
        if dark {
            g.tint = LitV3(0.60, 0.74, 1.0)
            g.ceiling = 0.62
            g.night = 0.25
        }
        return LitPost.finish(hdr: hdr, w: w, h: h, outW: plan.outW, outH: plan.outH, grade: g, seed: seed)
    }
}

// MARK: Scene: fog in a conifer valley, seen from above

/// Spurs that interlock from either side of a valley: each is a line of crests falling towards the valley floor, so the fog lies between them.
nonisolated struct LitValleyField: @unchecked Sendable {
    let nx: Int, nz: Int
    let cx: Float, cz: Float
    let halfX: Float, zMax: Float
    let ground: UnsafeMutablePointer<Float>
    let fogTop: UnsafeMutablePointer<Float>

    struct Spur { var z: Float, y: Float, drop: Float, side: Float, die: Float, slopeFront: Float, slopeBack: Float }

    init(seed: UInt32, nx: Int, nz: Int, tanH: Float, fogLevel: Float, spurs: [Spur]) {
        self.nx = nx; self.nz = nz
        let zMax: Float = 13000
        let halfX = max(1200, tanH * zMax * 1.08)
        self.zMax = zMax; self.halfX = halfX
        let cx = 2 * halfX / Float(nx - 1), cz = zMax / Float(nz - 1)
        self.cx = cx; self.cz = cz
        let ground = UnsafeMutablePointer<Float>.allocate(capacity: nx * nz)
        let fogTop = UnsafeMutablePointer<Float>.allocate(capacity: nx * nz)
        self.ground = ground; self.fogTop = fogTop
        // Each spur's crest and its wander, along x, once.
        let lutN = 2048
        let crest = UnsafeMutablePointer<Float>.allocate(capacity: lutN * spurs.count)
        let wander = UnsafeMutablePointer<Float>.allocate(capacity: lutN * spurs.count)
        defer { crest.deallocate(); wander.deallocate() }
        let spursC = spurs
        litParallelFor(spurs.count, chunk: 1) { si in
            let s = spursC[si]
            let wide = tanH * s.z
            let sd = seed &+ UInt32(si) &* 31
            for i in 0..<lutN {
                let x = -halfX + 2 * halfX * Float(i) / Float(lutN - 1)
                let u = s.side * x / wide
                let rise = litSstep(s.die, s.die + 1.8, u)
                let beyond = max(0, u - 1) * s.drop * 0.3
                let lumps = 16 + s.z * 0.012
                let noise = litFbm(x / (s.z * 0.2 + 70), Float(si) * 7.3, 4, sd &+ 1) * 2 * lumps
                crest[si * lutN + i] = s.y - s.drop * (1 - rise) + beyond + noise
                wander[si * lutN + i] = litFbm(x / (s.z * 0.5 + 200), Float(si) * 3.1 + 4, 3, sd &+ 2) * s.z * 0.2 + x * 0.12 * s.side
            }
        }
        let count = spursC.count
        litParallelFor(nz, chunk: 4) { zi in
            let z = Float(zi) * cz
            for xi in 0..<nx {
                let x = -halfX + Float(xi) * cx
                let fi = (x + halfX) / (2 * halfX) * Float(lutN - 1)
                let li = min(lutN - 2, Int(fi))
                let la = fi - Float(li)
                var m: Float = 30
                for si in 0..<count {
                    let s = spursC[si]
                    let k = si * lutN + li
                    let cr = crest[k] + (crest[k + 1] - crest[k]) * la
                    let wa = wander[k] + (wander[k + 1] - wander[k]) * la
                    let d = z - (s.z + wa)
                    let v = cr - (d < 0 ? -d * s.slopeFront : d * s.slopeBack)
                    if v > m { m = v }
                }
                let i = zi * nx + xi
                let detail = litFbm(x / 170, z / 170, 3, seed &+ 90) * 26
                let far = litSstep(3500, 9000, z)
                let rough = far > 0.001 ? litRidged(x / 1300, z / 1300, 5, seed &+ 91) * 420 * far : 0
                ground[i] = m + detail + rough
                fogTop[i] = fogLevel + 70 * litFbm(x / 760, z / 1300, 3, seed &+ 92) + 20 * litFbm(x / 190, z / 300, 2, seed &+ 93)
            }
        }
    }
    func free() { ground.deallocate(); fogTop.deallocate() }

    @inline(__always) func sample(_ g: UnsafeMutablePointer<Float>, _ x: Float, _ z: Float) -> Float {
        let fx = max(0, min(Float(nx) - 1.001, (x + halfX) / cx)), fz = max(0, min(Float(nz) - 1.001, z / cz))
        let ix = Int(fx), iz = Int(fz)
        let ax = fx - Float(ix), az = fz - Float(iz)
        let i = iz * nx + ix
        let a: Float = g[i] + (g[i + 1] - g[i]) * ax
        let b: Float = g[i + nx] + (g[i + nx + 1] - g[i + nx]) * ax
        return a + (b - a) * az
    }
}

nonisolated extension LitArt {
    static func forest(_ plan0: LitPlan, dark: Bool) -> CGImage? {
        let plan = plan0.enlarged(2.0)
        let w = plan.w, h = plan.h, tier = plan.tier
        let seed: UInt32 = 3307
        let fw = Float(w), fh = Float(h)
        let f = max(min(1.75 * fw, 0.81 * fh), 0.72 * fw)
        let tanH = fw * 0.5 / f
        let camY: Float = 620
        let fogLevel: Float = dark ? 330 : 292
        let spurs: [LitValleyField.Spur] = [
            .init(z: 225, y: 450, drop: 150, side: 1, die: -1.0, slopeFront: 0.7, slopeBack: 0.5),
            .init(z: 420, y: 430, drop: 130, side: -1, die: -1.0, slopeFront: 0.6, slopeBack: 0.5),
            .init(z: 760, y: 410, drop: 110, side: 1, die: -1.0, slopeFront: 0.55, slopeBack: 0.45),
            .init(z: 1250, y: 425, drop: 120, side: -1, die: -1.0, slopeFront: 0.5, slopeBack: 0.42),
            .init(z: 2000, y: 465, drop: 130, side: 1, die: -1.0, slopeFront: 0.45, slopeBack: 0.4),
            .init(z: 3200, y: 540, drop: 150, side: -1, die: -1.0, slopeFront: 0.4, slopeBack: 0.36),
            .init(z: 5000, y: 700, drop: 170, side: 1, die: -1.0, slopeFront: 0.36, slopeBack: 0.32),
            .init(z: 7500, y: 1000, drop: 220, side: -1, die: -1.0, slopeFront: 0.3, slopeBack: 0.25),
        ]
        let field = LitValleyField(seed: seed, nx: tier == 2 ? 897 : (tier == 1 ? 513 : 257), nz: tier == 2 ? 1281 : (tier == 1 ? 769 : 385), tanH: tanH, fogLevel: fogLevel, spurs: spurs)
        defer { field.free() }

        let sun = litNorm3(dark ? LitV3(-0.62, 0.42, 0.66) : LitV3(-0.74, 0.20, 0.64))
        let A = LitAtmosphere(sunDir: sun, sunE: dark ? LitV3(0.86, 0.94, 1.1) * 4.5 : LitV3(1, 0.95, 0.86) * 19, altBase: 400, camY: camY,
                           turbidity: dark ? 0.5 : 1.3, skyGain: dark ? 0.1 : 1.35, msGain: 1.9, airGain: dark ? 0.15 : 0.35, ozone: 1)
        defer { A.free() }
        let amb = LitAmbient(atmos: A, ground: dark ? LitV3(0.012, 0.016, 0.022) : LitV3(0.34, 0.36, 0.38)).scaled(dark ? 15 : 1)
        let cam = LitCamera(ro: LitV3(0, camY, 0), f: f, cx: fw * 0.5, horizon: fh * 0.215)
        let hdr = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        let depth = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        // Where each pixel's ray enters the fog, and how the fog looks there: the trees are fogged with exactly the same veil as the ground behind them.
        let enter = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        let fogTint = UnsafeMutablePointer<LitV3>.allocate(capacity: w * h)
        defer { hdr.deallocate(); depth.deallocate(); enter.deallocate(); fogTint.deallocate() }

        let sunC = A.sunColor(y: 600)
        let skyUp = amb.irradiance(LitV3(0, 1, 0))
        let fogK: Float = 0.021
        let fogS: Float = 46
        @inline(__always) func fogOptical(_ dt: Float, _ sinT: Float) -> Float {
            let ds = fogS / max(0.012, sinT)
            return dt < ds ? fogK * dt * dt / (2 * ds) : fogK * (dt - ds * 0.5)
        }
        let hazeY0: Float = fogLevel - 40
        let hazeH: Float = dark ? 300 : 240
        let hazeK: Float = dark ? 0.00085 : 0.00052
        let horizonAir = A.sky(litNorm3(LitV3(0.1, 0.012, 1)))
        let airRaw: LitV3 = horizonAir * 0.62 + (sunC * 0.042 + skyUp * 0.2)
        let airCol: LitV3 = dark ? (skyUp * 0.2 + sunC * 0.024) * 2.15 : litLerp(airRaw, LitV3(1.02, 1.0, 0.985) * litLuma(airRaw), 0.75) * 1.42
        // By day the mist takes the sun's warmth on its side of the valley and a little of the sky's cool on the other.
        let sunFlat = (sun.x * sun.x + sun.z * sun.z).squareRoot()
        let warmth: (Float, Float) -> LitV3 = { dx, dz in
            if dark { return LitV3(1, 1, 1) }
            let toward = (dx * sun.x + dz * sun.z) / (sunFlat * max(1e-4, (dx * dx + dz * dz).squareRoot()))
            let k = litSat((toward - 0.35) / 0.55)
            return litLerp(LitV3(0.965, 0.995, 1.035), LitV3(1.11, 1.0, 0.83), k * k * (3 - 2 * k))
        }
        @inline(__always) func fogColour(_ rd: LitV3, _ x: Float, _ z: Float, _ top: Float) -> LitV3 {
            let e: Float = 40
            let gx = (field.sample(field.fogTop, x + e, z) - top) / e
            let gz = (field.sample(field.fogTop, x, z + e) - top) / e
            let nn = litNorm3(LitV3(-gx * 2.6, 1, -gz * 2.6))
            let ndl = max(0, litDot3(nn, sun))
            let bright = 0.62 + 0.62 * litSat(ndl * 2.4 - 0.1)
            let toward = max(0, litDot3(rd, sun))
            let glow = 1 + 0.55 * toward * toward * toward * toward
            let raw: LitV3 = sunC * (0.052 * bright * glow) + skyUp * (0.21 * (0.82 + 0.3 * litSat(ndl * 2)))
            // Fog scatters every colour alike: most of the pink of low sun stays in the sky.
            let neutral: LitV3 = (dark ? LitV3(0.8, 0.9, 1.1) : warmth(rd.x, rd.z)) * litLuma(raw)
            return litLerp(raw, neutral, 0.72) * (dark ? 2.5 : 1.55)
        }
        @inline(__always) func march(_ rd: LitV3) -> (t: Float, te: Float, tint: LitV3) {
            let tFar: Float = 13000
            var t: Float = 40
            var te = Float.infinity
            var tint = LitV3.zero
            let sinT = max(0.012, -rd.y)
            var i = 0
            while t < tFar && i < 220 {
                let x = cam.ro.x + rd.x * t, z = cam.ro.z + rd.z * t, y = cam.ro.y + rd.y * t
                if z >= field.zMax - 1 || abs(x) >= field.halfX - 1 { return (.infinity, te, tint) }
                let gh = field.sample(field.ground, x, z)
                if y <= gh {
                    var a = t - 1, b = t
                    a = max(40, t - max(1.5, t * 0.006))
                    for _ in 0..<5 {
                        let m = (a + b) * 0.5
                        let py = cam.ro.y + rd.y * m
                        if py <= field.sample(field.ground, cam.ro.x + rd.x * m, cam.ro.z + rd.z * m) { b = m } else { a = m }
                    }
                    return (b, te, tint)
                }
                var ceiling = gh
                if te == .infinity {
                    let top = field.sample(field.fogTop, x, z)
                    if y <= top {
                        te = t
                        tint = fogColour(rd, x, z, top)
                    } else {
                        ceiling = max(ceiling, top)
                    }
                } else if fogOptical(t - te, sinT) > 5 {
                    return (t, te, tint)
                }
                t += max(max(1.5, t * 0.006), (y - ceiling) / (abs(rd.y) + 1.0))
                i += 1
            }
            return (.infinity, te, tint)
        }
        let cloudSeed = seed &+ 40
        @inline(__always) func skyAt(_ rd: LitV3) -> LitV3 {
            var c = A.sky(LitV3(rd.x, max(rd.y, 0.004), rd.z))
            let tx = rd.x / max(0.03, rd.y), tz = rd.z / max(0.03, rd.y)
            let veil = litSstep(-0.05, 0.4, litFbm(tx * 0.16, tz * 0.05, 4, cloudSeed)) * litSat(rd.y * 9)
            if !dark {
                c = litLerp(c, sunC * 0.05 + skyUp * 0.2, veil * 0.5)
            } else {
                // The glow along the horizon stands clear above the farthest ridge, so the ridge reads against it, darker than the sky.
                c = c * (1 - 0.25 * veil) + airCol * (0.5 * expf(-max(0, rd.y) * 9) + 0.8 * powf(1 - litSstep(0.02, 0.36, rd.y), 2.2))
            }
            return c
        }
        @inline(__always) func canopy(_ p: LitV3, _ rd: LitV3, _ t: Float) -> LitV3 {
            let e = max(field.cx, t * 0.004)
            let g0 = p.y
            let gx = (field.sample(field.ground, p.x + e, p.z) - g0) / e
            let gz = (field.sample(field.ground, p.x, p.z + e) - g0) / e
            let n = litNorm3(LitV3(-gx, 1, -gz))
            let ndl = max(0, litDot3(n, sun))
            let m = litFbm(p.x / 26, p.z / 26, 3, seed &+ 70)
            let far = litSstep(4200, 8000, p.z)
            // Moss and needle litter under the trees: dark, but never a hole.
            let moss = litFbm(p.x / 9, p.z / 9, 2, seed &+ 71)
            let floor = litLerp(LitV3(0.015, 0.026, 0.015), LitV3(0.022, 0.026, 0.014), litSat(0.5 + moss))
            let alb = litLerp(floor, LitV3(0.05, 0.072, 0.082), far) * (0.8 + 0.8 * m)
            return alb * (sunC * (ndl * 0.8) + amb.irradiance(n)) * (1 / Float.pi)
        }

        LitCommon.primary(w: w, h: h, tier: tier, hdr: hdr, depth: depth, jump: 0.06, contrast: 0.9) { px, py in
            let rd = cam.dir(px, py)
            let i = Int(py) * w + Int(px)
            if rd.y > 0.13 {
                enter[i] = .infinity
                return (skyAt(rd), .infinity)
            }
            let m = march(rd)
            enter[i] = m.te
            fogTint[i] = m.tint
            if m.t == .infinity { return (skyAt(rd), .infinity) }
            let p = cam.ro + rd * m.t
            let gy = field.sample(field.ground, p.x, p.z)
            var c = canopy(LitV3(p.x, gy, p.z), rd, m.t)
            let kNear = hazeK * (0.3 + 0.7 * litSstep(250, 1800, m.t))
            c = LitCommon.haze(c, camY: camY - hazeY0, t: m.t, yEnd: max(0, p.y - hazeY0), H: hazeH, k: kNear, air: airCol * warmth(rd.x, rd.z))
            if m.te != .infinity {
                let T = expf(-fogOptical(m.t - m.te, max(0.012, -rd.y)))
                c = litLerp(m.tint, c, T)
            }
            return (c, m.t)
        }
        if dark { addStars(hdr, depth: depth, w: w, h: h, cam: cam, density: 1500, gain: 0.25, seed: seed, unitW: fw) }

        // A stock of spruces at the sizes needed; every tree in the valley is one of these.
        let sizes: [Float] = tier == 0 ? [5, 7, 10, 14, 20, 28, 40, 56, 80, 110] : [6, 8, 11, 15, 20, 27, 36, 48, 64, 85, 113, 150, 200, 265, 350]
        let variants = tier == 0 ? 3 : 5
        let bankN = sizes.count * variants
        let bank = UnsafeMutablePointer<LitTreeSprite>.allocate(capacity: bankN)
        defer {
            for i in 0..<bankN { bank[i].free() }
            bank.deallocate()
        }
        litParallelFor(bankN, chunk: 1) { i in
            let si = i / variants, v = i % variants
            bank[i] = LitSpruce.raster(pixelHeight: sizes[si], seed: seed &+ UInt32(i) &* 131, slim: 0.62 + 0.09 * Float(v))
        }
        // The trees, far to near.
        struct Planted { var x: Float, y: Float, z: Float, h: Float, tone: Float, lean: Float, sprite: Int32 }
        var planted: [Planted] = []
        planted.reserveCapacity(16000)
        var st: UInt64 = UInt64(seed) &+ 5
        @inline(__always) func rnd() -> Float {
            st &+= 0x9E37_79B9_7F4A_7C15
            var q = st
            q = (q ^ (q >> 30)) &* 0xBF58_476D_1CE4_E5B9
            q = (q ^ (q >> 27)) &* 0x94D0_49BB_1331_11EB
            q ^= q >> 31
            return Float(q >> 40) * (1.0 / 16777216.0)
        }
        // The same walk at every size, so the tile holds the same trees as the full picture. Every draw is made whether the tree is kept or not.
        let treeFar: Float = 3900
        var z: Float = 70
        let plant: (Float, Float, Float, Float, Float, Float) -> Void = { tx, tz, tallness, tone, lean, pick in
            let gy = field.sample(field.ground, tx, tz)
            if gy < field.sample(field.fogTop, tx, tz) - 75 { return }
            // Above the camera's line of sight only if it can be seen at all.
            let topPy = cam.horizon + (camY - gy - tallness) * f / tz
            if topPy > fh + 4 { return }
            let want = tallness * f / tz
            if want < sizes[0] * 0.65 { return }
            var si = 0
            while si < sizes.count - 1 && abs(sizes[si + 1] - want) < abs(sizes[si] - want) { si += 1 }
            planted.append(Planted(x: tx, y: gy, z: tz, h: tallness, tone: tone, lean: lean, sprite: Int32(si * variants + Int(pick * Float(variants) * 0.999))))
        }
        while z < treeFar {
            let sp = 7.5 + z * 0.0042
            let wide = tanH * z + 40
            var x = -wide + rnd() * sp
            while x < wide {
                let tx = x + (rnd() - 0.5) * sp * 0.9, tz = z + (rnd() - 0.5) * sp * 0.9
                x += sp
                let r1 = rnd(), r2 = rnd(), r3 = rnd(), r4 = rnd()
                plant(tx, tz, 32 * (0.6 + 0.6 * r1), 0.72 + 0.6 * r2, (r3 - 0.5) * 0.07, r4)
                // Young growth and low brush between the big trees, where the camera can see down to the floor.
                let u0 = rnd(), u1 = rnd(), u2 = rnd(), u3 = rnd(), u4 = rnd(), u5 = rnd(), u6 = rnd()
                if z < 1500 && u0 < 0.8 {
                    plant(tx + (u1 - 0.5) * sp * 1.1, tz + (u2 - 0.5) * sp * 0.8, 5 + 11 * u3 * u3, 0.95 + 0.6 * u4, (u5 - 0.5) * 0.12, u6)
                }
            }
            z += sp
        }
        planted.sort { $0.z > $1.z }
        let sinTAt: (Float) -> Float = { py in
            let s = (py - cam.horizon) / f
            return max(0.012, s / (1 + s * s).squareRoot())
        }
        let airRow = UnsafeMutablePointer<LitV3>.allocate(capacity: w)
        defer { airRow.deallocate() }
        for x in 0..<w { airRow[x] = airCol * warmth((Float(x) + 0.5 - cam.cx) / f, 1) }
        for tr in planted {
            let sp = bank[Int(tr.sprite)]
            let s = f / tr.z
            let baseU = cam.cx + tr.x * s
            let baseV = cam.horizon + (camY - tr.y) * s
            let ox = Int(baseU) - sp.baseX, oy = Int(baseV) - sp.baseY
            let e: Float = max(field.cx, 12)
            let g0 = tr.y
            let gx = (field.sample(field.ground, tr.x + e, tr.z) - g0) / e
            let gz = (field.sample(field.ground, tr.x, tr.z + e) - g0) / e
            let n = litNorm3(LitV3(-gx * 0.6, 1, -gz * 0.6))
            let ndl = max(0, litDot3(n, sun))
            let fromSun: Float = 0.4 + 0.6 * litSat(ndl * 2.2)
            let alb = LitV3(0.015, 0.025, 0.019) * tr.tone
            let lightA: LitV3 = sunC * (0.42 * fromSun) + skyUp * 0.36
            let lightB: LitV3 = skyUp * 0.2 + sunC * (0.02 * fromSun)
            let kNear = 0.3 + 0.7 * litSstep(250, 1800, tr.z)
            let yy0 = max(0, oy), yy1 = min(h - 1, oy + sp.h - 1)
            if yy0 > yy1 { continue }
            for yy in yy0...yy1 {
                let sy = yy - oy
                let row = (Float(yy) + 0.5)
                let sinT = sinTAt(row)
                let sec = (1 + ((row - cam.horizon) / f) * ((row - cam.horizon) / f)).squareRoot()
                let wy = camY - (row - cam.horizon) * tr.z / f
                let tt = tr.z * sec
                let T0 = LitCommon.haze(LitV3(1, 1, 1), camY: camY - hazeY0, t: tt, yEnd: max(0, wy - hazeY0), H: hazeH, k: hazeK * kNear, air: LitV3.zero).x
                let rel = litSat((wy - tr.y) / tr.h)
                let tip = 0.6 + 0.8 * rel
                let leanX = Int((Float(sp.baseY - sy) * tr.lean).rounded())
                for sx in 0..<sp.w {
                    let xx = ox + sx + leanX
                    if xx < 0 || xx >= w { continue }
                    let a = sp.cover[sy * sp.w + sx]
                    if a < 0.004 { continue }
                    let i = yy * w + xx
                    if depth[i] < tt - 10 - tt * 0.01 { continue }
                    let sh = sp.shade[sy * sp.w + sx]
                    var c: LitV3 = alb * (lightA * (sh * tip) + lightB) * (1 / Float.pi) * 3.1
                    c = c * T0 + airRow[xx] * (1 - T0)
                    let te = enter[i]
                    if te < tt {
                        let T = expf(-fogOptical(tt - te, sinT))
                        c = litLerp(fogTint[i], c, T)
                    }
                    hdr[i] += (c - hdr[i]) * a
                }
            }
        }

        var g = LitGrade()
        g.exposure = dark ? 1.0 : 1.42
        g.vignette = 0.18
        if dark {
            g.tint = LitV3(0.56, 0.72, 1.0)
            g.ceiling = 0.6
            g.night = 0.55
        }
        return LitPost.finish(hdr: hdr, w: w, h: h, outW: plan.outW, outH: plan.outH, grade: g, seed: seed)
    }
}
