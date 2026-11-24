// [first-run] The stage's numbers, ported from the approved mock (build/first-run/spec/prototype.src.html, "the stage"):
// the land as a dot per land bit of a 5200-point spiral (`P`), the round head's 20 × 20 LEDs (`CELLS`), where the
// person is from the clock alone, and where each dot sits at rest in each mode (`globeFn`, `ledFn`, `starsFn`,
// `burstFn`) and which dot each LED takes (`toLED`). Pure value code: no UIKit, no drawing (ArrivalStageView draws it),
// so the unit tests read it directly (Tests/Onboarding/FirstRunArrivalTests.swift).

import Foundation

nonisolated enum ArrivalWorld {
    /// The mock's phone: every position below is in these points (390 × 844), mapped onto the real screen by the view.
    static let phone = (width: 390.0, height: 844.0)
    static let tau = Double.pi * 2
    static let d2r = Double.pi / 180

    // MARK: The land

    /// One bit per 1° square, row-major from 90°N 180°W, most significant bit first (Natural Earth 110m land, public
    /// domain): 360 × 180 bits, 8100 bytes.
    struct Land: Sendable {
        let bits: [UInt8]

        init?(_ data: Data) {
            guard data.count == 8100 else { return nil }
            bits = [UInt8](data)
        }

        /// The mock's `isLand`.
        func isLand(lat: Double, lon: Double) -> Bool {
            let x = Int(floor(((lon + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)))
            let y = Int(min(max(floor(90 - lat), 0), 179))
            let i = y * 360 + x
            return (bits[i >> 3] >> (7 - UInt8(i & 7))) & 1 == 1
        }

        /// The app's copy (App/Resources/FirstRun/first-run-land.bin).
        static let bundled: Land? = Bundle.main.url(forResource: "first-run-land", withExtension: "bin")
            .flatMap { try? Data(contentsOf: $0) }.flatMap(Land.init)
    }

    /// The mock's `R2`: Park–Miller, seeded 11, so the dots' home spots and sizes are the mock's own.
    struct Random: Sendable {
        var state: Int64 = 11
        mutating func next() -> Double {
            state = (state * 16807) % 2147483647
            return Double(state) / 2147483647
        }
    }

    /// One dot of land: where it is on the globe and its home in the stars.
    struct Dot: Sendable, Equatable {
        var u: SIMD3<Double>
        /// Its spot in the stars (mock points) and its own size and brightness (0…1).
        var hx: Double, hy: Double, hs: Double
    }

    static func vec(lat: Double, lon: Double) -> SIMD3<Double> {
        let c = cos(lat * d2r)
        return SIMD3(c * sin(lon * d2r), sin(lat * d2r), c * cos(lon * d2r))
    }

    /// `P`: a dot for every land bit the 5200-point spiral lands on (none south of 58°S), in the mock's order, drawing
    /// from `random` as the mock does (size first, then the star spot).
    static func dots(land: Land, random: inout Random) -> [Dot] {
        var out: [Dot] = []
        out.reserveCapacity(1600)
        let m = 5200
        for i in 0..<m {
            let y = 1 - (Double(i) + 0.5) / Double(m) * 2
            let lat = asin(y) / d2r
            let lon = (Double(i) * 137.50776405).truncatingRemainder(dividingBy: 360) - 180
            if lat < -58 || !land.isLand(lat: lat, lon: lon) { continue }
            let hs = random.next()
            let hx = random.next() * phone.width
            let hy = random.next() * phone.height
            out.append(Dot(u: vec(lat: lat, lon: lon), hx: hx, hy: hy, hs: hs))
        }
        return out
    }

    /// The mock's `STARS`: 90, drawn from the same stream after the dots.
    struct Star: Sendable { var x, y, s, ph: Double }
    static func stars(random: inout Random) -> [Star] {
        (0..<90).map { _ in
            let x = random.next() * phone.width, y = random.next() * phone.height, s = random.next(), ph = random.next() * 40
            return Star(x: x, y: y, s: s, ph: ph)
        }
    }

    // MARK: Where they are

    /// Longitude from the clock alone (seconds east of GMT / 240), clamped to ±180. Nothing is asked for.
    static func longitude(secondsFromGMT: Int) -> Double { min(max(Double(secondsFromGMT) / 240, -180), 180) }

    /// The mock's hemisphere guess, from the time zone's own name (not a location).
    static func south(_ identifier: String) -> Bool {
        ["Australia", "Auckland", "Sao_Paulo", "Buenos_Aires", "Johannesburg", "Santiago", "Lima", "Jakarta"]
            .contains { identifier.contains($0) }
    }

    /// Where the mark sits, where the note goes (122° east of it) and how the globe is tipped.
    struct Place: Sendable, Equatable {
        var lon: Double
        var you: SIMD3<Double>
        var far: SIMD3<Double>
        var tilt: Double

        init(secondsFromGMT: Int, identifier: String) {
            let s = ArrivalWorld.south(identifier)
            lon = ArrivalWorld.longitude(secondsFromGMT: secondsFromGMT)
            you = ArrivalWorld.vec(lat: s ? -28 : 39, lon: lon)
            far = ArrivalWorld.vec(lat: s ? -4 : 16, lon: lon + 122)
            tilt = s ? -0.4 : 0.44
        }

        static var current: Place {
            Place(secondsFromGMT: TimeZone.current.secondsFromGMT(), identifier: TimeZone.current.identifier)
        }

        /// The globe's turn at rest: the person's longitude, the still mode's small offset.
        var restRotation: Double { lon * ArrivalWorld.d2r }
    }

    // MARK: The LEDs

    /// One LED of the round dot-matrix head: 20 across, eyes two LEDs wide, up and to the right (`CELLS`).
    struct Cell: Sendable, Equatable {
        var r: Int, dx: Double, dy: Double, d: Double, light: Double, eye: Bool
    }

    static let cells: [Cell] = {
        var out: [Cell] = []
        for r in 0..<20 {
            for c in 0..<20 {
                let dx = Double(c) - 9.5, dy = Double(r) - 9.5, d = (dx * dx + dy * dy).squareRoot()
                guard d <= 9.9 else { continue }
                let eye = (c == 10 || c == 11 || c == 14 || c == 15) && r >= 5 && r <= 8
                out.append(Cell(r: r, dx: dx, dy: dy, d: d, light: min(max(0.5 + (dx - dy) / 24, 0), 1), eye: eye))
            }
        }
        return out
    }()

    /// `toLED`: each LED, in a shuffled order, takes the nearest dot not yet taken (first among those bright enough to
    /// see, then any); every dot left over goes to its nearest LED and stays dark. Returns, per dot, its LED and whether
    /// it is the one lighting it.
    static func assign(cellCentres: [SIMD2<Double>], dots: [SIMD2<Double>], alphas: [Double],
                       order: [Int]) -> (cell: [Int], prim: [Bool]) {
        let n = dots.count
        var taken = [Bool](repeating: false, count: n)
        var has = [Bool](repeating: false, count: cellCentres.count)
        var cell = [Int](repeating: 0, count: n)
        var prim = [Bool](repeating: false, count: n)
        for pass in [0.05, -1] {
            for ci in order where !has[ci] {
                let t = cellCentres[ci]
                var best = -1, bd = Double.greatestFiniteMagnitude
                for i in 0..<n where !taken[i] && alphas[i] >= pass {
                    let d = dots[i] - t, dd = d.x * d.x + d.y * d.y
                    if dd < bd { bd = dd; best = i }
                }
                if best >= 0 { taken[best] = true; cell[best] = ci; prim[best] = true; has[ci] = true }
            }
        }
        for i in 0..<n where !taken[i] {
            var best = 0, bd = Double.greatestFiniteMagnitude
            for (k, t) in cellCentres.enumerated() {
                let d = t - dots[i], dd = d.x * d.x + d.y * d.y
                if dd < bd { bd = dd; best = k }
            }
            cell[i] = best
        }
        return (cell, prim)
    }

    // MARK: Targets at rest

    /// A dot's target: where it sits, its radius, alpha and colour (0…255), and its glow (lit LEDs only).
    struct Target: Sendable, Equatable {
        var x, y, r, a: Double
        var c: SIMD3<Double>
        var g: Double = 0
    }

    /// Where the globe is and how it is turned (`GP`, `CA`, `SA`, `cT`, `sT`).
    struct Globe: Sendable, Equatable {
        var cx = 195.0, cy = 258.0, r = 116.0
        var rot = 0.0
        var tilt = 0.44

        func project(_ u: SIMD3<Double>, alt: Double = 1) -> (x: Double, y: Double, z: Double, rim: Double) {
            let ca = cos(rot), sa = sin(rot), ct = cos(tilt), st = sin(tilt)
            let x = u.x * ca - u.z * sa, z = u.x * sa + u.z * ca, y = u.y * ct - z * st
            return (cx + x * r * alt, cy - y * r * alt, u.y * st + z * ct, (x * x + y * y).squareRoot() * alt)
        }
    }

    /// `starsFn` at time `now` (ms).
    static func star(_ d: Dot, now: Double, mono: SIMD3<Double>) -> Target {
        Target(x: d.hx, y: d.hy, r: 0.5 + d.hs * 0.9, a: (0.05 + 0.3 * d.hs) * (0.55 + 0.45 * sin(now * 0.0011 + d.hs * 40)), c: mono)
    }

    /// `globeFn`.
    static func globe(_ d: Dot, _ g: Globe, mono: SIMD3<Double>) -> Target {
        let ca = cos(g.rot), sa = sin(g.rot), ct = cos(g.tilt), st = sin(g.tilt)
        let x = d.u.x * ca - d.u.z * sa, z = d.u.x * sa + d.u.z * ca, y = d.u.y * ct - z * st, z2 = d.u.y * st + z * ct
        let f = max(z2, 0)
        let a = clamp(z2 * 3 + 0.12) * (0.32 + 0.68 * f) * clamp(0.74 + 0.3 * (y * 0.6 - x * 0.45))
        return Target(x: g.cx + x * g.r, y: g.cy - y * g.r, r: g.r * (0.0056 + 0.0046 * f) + 0.3, a: a, c: mono)
    }

    /// The LED grid (`LP`): its centre, pitch, when it lit (ms, nil: asleep), how far run together, faded, scanning.
    struct Leds: Sendable, Equatable {
        var cx = 195.0, cy = 188.0, pitch = 7.4
        var ign: Double?
        var fuse = 0.0, fade = 1.0
        var scan: Double?
    }

    /// `ledFn`: `accent` is the head's own colour (the mock's crimson), `hot` the flash's.
    static func led(cell cl: Cell, prim: Bool, _ lp: Leds, now: Double, still: Bool, mono: SIMD3<Double>,
                    accent: SIMD3<Double>, hot: SIMD3<Double>) -> Target {
        let x = lp.cx + cl.dx * lp.pitch, y = lp.cy + cl.dy * lp.pitch
        guard prim else { return Target(x: x, y: y, r: lp.pitch * 0.2, a: 0, c: mono) }
        let lit = lp.ign.map { clamp((now - $0 - cl.d * 42) / 180) } ?? 0
        let flash = lit > 0 && lit < 1 ? sin(lit * .pi) : 0
        var scan = 0.0
        if let s = lp.scan {
            let sweep = ((now - s) / 800).truncatingRemainder(dividingBy: 1) * 26 - 13
            scan = max(0, 1 - abs(cl.dy - sweep) / 1.7)
        }
        let shade = mix(0.6, 1, cl.light), hi = clamp((cl.light - 0.72) / 0.28) * 0.5
        let bright = SIMD3(mix(accent.x * shade, min(accent.x * 1.32, 255), hi),
                           mix(accent.y * shade, min(accent.y * 2.17, 255), hi),
                           mix(accent.z * shade, min(accent.z * 1.62, 255), hi))
        var c = SIMD3<Double>()
        for k in 0..<3 { c[k] = mix(mix(mono[k], mix(bright[k], hot[k], flash * 0.9), lit), accent[k], lp.fuse) }
        let asleep = lp.ign == nil && !still ? 1 + 0.13 * sin(now / 900) : 1   // it breathes while it sleeps
        var a = mix((0.27 + 0.65 * scan) * asleep, 1, lit)
        if cl.eye && cl.r == 7 { a = 0.04 * (1 - lp.fuse) }                    // each eye two dark LEDs in a row
        return Target(x: x, y: y, r: lp.pitch * (0.36 + 0.1 * flash + 0.3 * lp.fuse), a: a * lp.fade, c: c, g: lit * (1 - lp.fuse))
    }

    /// `burstFn`: the LEDs let go outwards from the face, fading as they fly (`bx`, `by`: the spark's direction).
    static func burst(_ d: Dot, prim: Bool, bx: Double, by: Double, face: (x: Double, y: Double, r: Double),
                      accent: SIMD3<Double>, spark: SIMD3<Double>) -> Target {
        guard prim else { return Target(x: face.x, y: face.y, r: 0.5, a: 0, c: accent) }
        let far = face.r * (1.22 + d.hs * 1.15)
        return Target(x: face.x + bx * far, y: face.y + by * far, r: 0.7 + d.hs * 1.5, a: 0, c: spark)
    }

    // MARK: Small maths

    static func clamp(_ v: Double, _ a: Double = 0, _ b: Double = 1) -> Double { max(a, min(b, v)) }
    static func mix(_ a: Double, _ b: Double, _ q: Double) -> Double { a + (b - a) * q }

    /// The mock's easings (`E`).
    enum Ease: Sendable {
        case linear, out, `in`, inOut, back
        func callAsFunction(_ q: Double) -> Double {
            switch self {
            case .linear: q
            case .out: 1 - pow(1 - q, 3)
            case .in: q * q * q
            case .inOut: q < 0.5 ? 4 * q * q * q : 1 - pow(-2 * q + 2, 3) / 2
            case .back: 1 + 2.9 * pow(q - 1, 3) + 1.9 * pow(q - 1, 2)
            }
        }
    }
}
