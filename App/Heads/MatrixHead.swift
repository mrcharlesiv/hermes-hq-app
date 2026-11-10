// The dot-matrix head (the Matrix theme, and every bot's head until it is given another): a face of 20 × 20 round
// LEDs in one of thirteen outlines, drawn by hand on a 15 × 15 grid and traced onto the finer one (owner, Oct 26: 30
// across was "way too much"; they chose 20), lit in the bot's own colour on the side it turns to and fading toward the
// back, its eyes LEDs left dark, scaled up with it. Nothing sticks out of the outline: the shape is the
// head. On a dark page the LEDs glow; on a light one they are coloured dots with dark eyes. Pure value code: the grid is
// worked out here and drawn with Core Graphics below, on any thread.

import CoreGraphics
import Foundation

/// What a dot-matrix head is made of: an outline and a face, on the same grid, so heads side by side in a list share one
/// dot size.
nonisolated struct MatrixDesign: Hashable, Sendable {
    /// The head's outline (`MatrixHead.drawing`), each drawn LED by LED.
    enum Silhouette: String, CaseIterable, Sendable {
        case round, square, tall, wide, pebble, cloud, arch, shield, drop, leaf, hex, octagon, heart
    }
    /// `crossed` is never a head's own: a face shows it for a moment when its turn fails (`MatrixPose.eyes`).
    enum Eyes: String, CaseIterable, Sendable { case slits, dots, ovals, googly, happy, sleepy, stars, hearts, crossed }
    enum Mouth: String, CaseIterable, Sendable { case none, smile, open, cat, line }

    var silhouette: Silhouette = .round
    var eyes: Eyes = .slits
    var mouth: Mouth = .none
    var blush = false
    /// The LED colour, sRGB 0xRRGGBB.
    var color: UInt32 = 0x9479FF
    /// Ink: white LEDs on a dark page, black ones on a light page (`color` is not used).
    var mono = false
    /// −1 turned to the left, +1 to the right: where the light falls and the eyes sit.
    var facing = 1
}

nonisolated extension MatrixDesign {
    /// A head's outline and face: its colour the colour's accent, the way it faces from its seed. Slit eyes and nothing
    /// else, whatever the head keeps (owner, 2026-10-28: "i don't want mouths", then "only one kind of eyes - the
    /// normal ones"; `Head.plain`).
    init(_ head: Head) {
        silhouette = head.silhouette
        eyes = .slits
        mouth = .none
        blush = false
        mono = head.color == .ink
        color = HeadTones.accent(head.color).hex
        facing = MatrixHead.facing(seed: head.seed)
    }
}

nonisolated extension MatrixDesign.Silhouette {
    /// A saved head's `form`: an outline's own name, else a Shapes head's form as the outline nearest it (what build 378
    /// saved for a dot-matrix head, and what a Shapes head brings when it becomes one).
    init(stored form: String) {
        if let outline = Self(rawValue: form) {
            self = outline
            return
        }
        self = switch form {
        case "pill": .tall
        case "blob": .pebble
        case "triangle": .drop
        case "star": .octagon
        default: .round
        }
    }

    /// The Shapes form nearest this outline, for a dot-matrix head that becomes a Shapes head.
    var shapesForm: String {
        switch self {
        case .round, .arch: "round"
        case .square, .shield: "square"
        case .tall, .wide: "pill"
        case .pebble: "blob"
        case .cloud: "cloud"
        case .drop, .leaf: "drop"
        case .hex, .octagon: "hex"
        case .heart: "heart"
        }
    }
}

/// A moment of the face: where the eyes look and how far the lids are down. Always the head's own eyes and no mouth:
/// only where the eyes look and the body act (owner, 2026-10-28: "i don't want mouths. just the body and eyes moving",
/// then "only one kind of eyes - the normal ones").
nonisolated struct MatrixPose: Hashable, Sendable {
    /// Columns the eyes move (−1 left … +1 right).
    var gaze = 0
    /// Rows the eyes move (−1 up).
    var lift = 0
    /// 0 open, 1 half shut, 2 shut.
    var lids = 0
    /// A glitch: each band of rows slid sideways a LED or two (0 none; 1… which pattern).
    var glitch = 0

    static let rest = MatrixPose()

    /// The same moment with the eyes turned the other way (a face turned left is one turned right, mirrored).
    var mirrored: MatrixPose {
        var turned = self
        turned.gaze = -gaze
        return turned
    }

    /// What a drawn pose is kept under.
    var key: String { "\(gaze) \(lift) \(lids) \(glitch)" }

    /// LEDs row `row` slides sideways in glitch pattern `glitch`: two or three bands of rows, each a LED or two off.
    static func slide(_ glitch: Int, row: Int) -> Int {
        guard glitch > 0 else { return 0 }
        let offsets = [0, 1, 0, -2, 0, 2, -1, 0]
        return offsets[(row / 3 * 3 + glitch * 5) % offsets.count]
    }

    /// Still, while its bot works (Reduce Motion): looking up, toward the side the face turns to.
    static func thinking(_ design: MatrixDesign) -> MatrixPose { MatrixPose(gaze: design.facing, lift: -1) }

    /// While its bot works: narrowed eyes reading along a line and back.
    static let reading = [MatrixPose(gaze: -1, lids: 1), MatrixPose(lids: 1), MatrixPose(gaze: 1, lids: 1), MatrixPose(lids: 1)]

    /// Every pose a head is drawn in: at rest, glancing, thinking, blinking and reading.
    static let all: [MatrixPose] = [-1, 0].flatMap { lift in
        [-1, 0, 1].flatMap { gaze in (0...2).map { MatrixPose(gaze: gaze, lift: lift, lids: $0) } }
    }
}

nonisolated struct MatrixDot: Hashable, Sendable {
    /// `hole`: an eye or mouth LED left dark (a gap on a dark page, an ink dot on a light one); `white`: a googly eye's
    /// white, a gap on both.
    enum Kind: Hashable, Sendable { case body, hole, white, blush, pupil }
    var col: Int
    var row: Int
    var kind: Kind
    /// How much of the LED colour the dot shows (0 unlit grey … 1 fully lit).
    var light: Double
    /// How near the dot is to where the light strikes (0 … 1).
    var hot: Double
}

nonisolated enum MatrixHead {
    /// LEDs across (and down) a head.
    static let grid = 20
    /// The grid the outlines and faces are drawn on, coarser than the head's.
    static let drawn = 15

    struct Cell: Hashable, Sendable {
        var col: Int, row: Int
        init(_ col: Int, _ row: Int) { self.col = col; self.row = row }
    }

    /// Where an outline sits in its grid: its centre and half sizes, in cells.
    struct Box: Sendable { var cx: Double, cy: Double, hw: Double, hh: Double }

    /// The bounds of the cells set in `body` (`[row][col]`, square): the box the light is worked out in.
    static func box(_ body: [[Bool]]) -> Box {
        let size = body.count
        let rows = body.indices.filter { body[$0].contains(true) }
        let cols = (0..<size).filter { col in body.contains { $0[col] } }
        guard let top = rows.first, let bottom = rows.last, let first = cols.first, let last = cols.last
        else { return Box(cx: Double(size) / 2, cy: Double(size) / 2, hw: 1, hh: 1) }
        return Box(cx: Double(first + last + 1) / 2, cy: Double(top + bottom + 1) / 2,
                   hw: Double(last - first + 1) / 2, hh: Double(bottom - top + 1) / 2)
    }

    /// The way a head with this seed faces (bit 7, so neighbouring seeds don't all face one way).
    static func facing(seed: Int) -> Int { (seed >> 7) & 1 == 0 ? -1 : 1 }

    /// `seed` turned to face the other way (bit 7 flipped; 128, which would become 0, becomes 256).
    static func turned(seed: Int) -> Int {
        let next = seed ^ 0x80
        return next > 0 ? next : 0x100
    }

    // MARK: Outlines

    /// One outline as drawn (on the `drawn` grid), as it faces: which cells are LEDs, and where the eyes go.
    struct Outline: Sendable {
        /// `body[row][col]`.
        var body: [[Bool]]
        /// The eye line, and each eye's column (a two-wide eye grows outward from it).
        var eyeRow: Int, left: Int, right: Int

        init(_ drawing: [String]) {
            body = drawing.map { $0.map { $0 != "." } }
            let eyes = drawing.enumerated().flatMap { row, line in
                line.enumerated().filter { $0.element == "o" }.map { Cell($0.offset, row) }
            }
            eyeRow = eyes.first?.row ?? drawn / 2
            left = eyes.first?.col ?? drawn / 2 - 2
            right = eyes.last?.col ?? drawn / 2 + 2
        }

        /// The same outline turned the other way.
        var mirrored: Outline {
            var next = self
            next.body = body.map { $0.reversed() }
            next.left = drawn - 1 - right
            next.right = drawn - 1 - left
            return next
        }

        /// The drawn LEDs' bounds.
        var box: Box { MatrixHead.box(body) }

        func contains(_ cell: Cell) -> Bool {
            cell.row >= 0 && cell.row < drawn && cell.col >= 0 && cell.col < drawn && body[cell.row][cell.col]
        }
    }

    /// Every outline as drawn facing right, parsed once.
    private static let outlines = Dictionary(uniqueKeysWithValues: MatrixDesign.Silhouette.allCases.map { ($0, Outline(drawing($0))) })

    static func outline(_ silhouette: MatrixDesign.Silhouette, facing: Int) -> Outline {
        let outline = outlines[silhouette] ?? Outline(drawing(silhouette))
        return facing < 0 ? outline.mirrored : outline
    }

    static func outline(_ design: MatrixDesign) -> Outline { outline(design.silhouette, facing: design.facing) }

    /// Each outline LED by LED, facing right: `#` an LED, `o` the LED an eye is centred on (the eye line). Symmetric
    /// ones keep their eyes a column toward the way they face where there's room; pebble, cloud and leaf lean that way
    /// too. Every LED touches two others, the edges step evenly (no lone dots, no notches), and the eyes and mouth
    /// keep a ring of lit LEDs round them in every pose (MatrixHeadTests).
    static func drawing(_ silhouette: MatrixDesign.Silhouette) -> [String] {
        switch silhouette {
        case .round: [  // 177 LEDs
            ".....#####.....",
            "...#########...",
            "..###########..",
            ".#############.",
            ".#############.",
            "###############",
            "######o###o####",
            "###############",
            "###############",
            "###############",
            ".#############.",
            ".#############.",
            "..###########..",
            "...#########...",
            ".....#####.....",
        ]
        case .square: [  // 157 LEDs
            "...............",
            "...#########...",
            "..###########..",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#####o###o###.",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#############.",
            "..###########..",
            "...#########...",
            "...............",
        ]
        case .tall: [  // 133 LEDs
            "......###......",
            "....#######....",
            "...#########...",
            "...#########...",
            "..###########..",
            "..###########..",
            "..###########..",
            "..###o###o###..",
            "..###########..",
            "..###########..",
            "..###########..",
            "...#########...",
            "...#########...",
            "....#######....",
            "......###......",
        ]
        case .wide: [  // 133 LEDs
            "...............",
            "...............",
            "....#######....",
            "..###########..",
            ".#############.",
            ".#############.",
            "#####o###o#####",
            "###############",
            "###############",
            ".#############.",
            ".#############.",
            "..###########..",
            "....#######....",
            "...............",
            "...............",
        ]
        case .pebble: [  // 149 LEDs
            "...............",
            ".......#####...",
            ".....#########.",
            "...###########.",
            "..#############",
            ".##############",
            "######o###o####",
            "###############",
            "###############",
            "##############.",
            "#############..",
            ".###########...",
            "..#########....",
            "....#####......",
            "...............",
        ]
        case .cloud: [  // 167 LEDs
            "...............",
            ".........####..",
            "..###...######.",
            ".#####.#######.",
            "###############",
            "###############",
            "###############",
            "######o###o####",
            "###############",
            "###############",
            "###############",
            "###############",
            ".#############.",
            "...#########...",
            "...............",
        ]
        case .arch: [  // 177 LEDs
            ".....#####.....",
            "...#########...",
            "..###########..",
            "..###########..",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#####o###o###.",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#############.",
            "..###########..",
        ]
        case .shield: [  // 179 LEDs
            ".#############.",
            "###############",
            "###############",
            "###############",
            "###############",
            "######o###o####",
            "###############",
            "###############",
            ".#############.",
            ".#############.",
            "..###########..",
            "...#########...",
            "....#######....",
            ".....#####.....",
            "......###......",
        ]
        case .drop: [  // 151 LEDs
            ".......#.......",
            "......###......",
            ".....#####.....",
            "....#######....",
            "...#########...",
            "..###########..",
            ".#############.",
            ".#############.",
            "###############",
            "#####o###o#####",
            "###############",
            ".#############.",
            ".#############.",
            "..###########..",
            "....#######....",
        ]
        case .leaf: [  // 145 LEDs
            "...............",
            "......########.",
            "....##########.",
            "...###########.",
            "..############.",
            "..############.",
            ".#####o###o###.",
            ".#############.",
            ".#############.",
            ".############..",
            ".############..",
            ".###########...",
            ".##########....",
            ".########......",
            "...............",
        ]
        case .hex: [  // 147 LEDs
            ".......#.......",
            ".....#####.....",
            "...#########...",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#####o###o###.",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#############.",
            ".#############.",
            "...#########...",
            ".....#####.....",
            ".......#.......",
        ]
        case .octagon: [  // 165 LEDs
            ".....#####.....",
            "....#######....",
            "...#########...",
            "..###########..",
            ".#############.",
            "###############",
            "###############",
            "######o###o####",
            "###############",
            "###############",
            ".#############.",
            "..###########..",
            "...#########...",
            "....#######....",
            ".....#####.....",
        ]
        case .heart: [  // 142 LEDs
            "...............",
            "..####...####..",
            ".######.######.",
            "###############",
            "###############",
            "###############",
            "#####o###o#####",
            ".#############.",
            ".#############.",
            "..###########..",
            "...#########...",
            "....#######....",
            ".....#####.....",
            "......###......",
            ".......#.......",
        ]
        }
    }

    // MARK: The head's LEDs

    /// Each outline traced onto the head's grid, facing right, worked out once.
    private static let traced = Dictionary(uniqueKeysWithValues: MatrixDesign.Silhouette.allCases.map {
        ($0, trace(outline($0, facing: 1)))
    })

    /// The head's LEDs for an outline facing that way, `[row][col]` on the `grid`-square grid. Turned left, they are
    /// those facing right mirrored, LED for LED.
    static func leds(_ silhouette: MatrixDesign.Silhouette, facing: Int) -> [[Bool]] {
        let body = traced[silhouette] ?? trace(outline(silhouette, facing: 1))
        return facing < 0 ? body.map { $0.reversed() } : body
    }

    static func leds(_ design: MatrixDesign) -> [[Bool]] { leds(design.silhouette, facing: design.facing) }

    /// The box the light of `design`'s LEDs is worked out in, in the head's cells.
    static func box(_ design: MatrixDesign) -> Box { box(leds(design)) }

    /// A drawn outline on the head's grid: the drawing softened (each drawn LED a square, blurred by 0.85 of one) and
    /// an LED lit where it is more than half covered, so straight edges stay where they were drawn and the steps between
    /// them come out as curves; then an LED touching fewer than two others (a tip traced down to one) is dropped, as
    /// the drawings have none.
    static func trace(_ outline: Outline) -> [[Bool]] {
        let step = Double(drawn) / Double(grid), spread = 0.85 * 2.0.squareRoot()
        /// How much of a blur centred on `x` falls on the drawn cell `[lo, lo + 1]`.
        func share(_ lo: Double, _ x: Double) -> Double { 0.5 * (erf((lo + 1 - x) / spread) - erf((lo - x) / spread)) }
        var body = (0..<grid).map { row in
            (0..<grid).map { col in
                let x = (Double(col) + 0.5) * step, y = (Double(row) + 0.5) * step
                var covered = 0.0
                for r in max(0, Int(y) - 3)...min(drawn - 1, Int(y) + 3) {
                    let down = share(Double(r), y)
                    for c in max(0, Int(x) - 3)...min(drawn - 1, Int(x) + 3) where outline.body[r][c] { covered += down * share(Double(c), x) }
                }
                return covered > 0.5
            }
        }
        var changed = true
        while changed {
            changed = false
            for row in 0..<grid {
                for col in 0..<grid where body[row][col] {
                    var touching = 0
                    for dr in -1...1 {
                        for dc in -1...1 where (dr != 0 || dc != 0) && (0..<grid).contains(row + dr) && (0..<grid).contains(col + dc) {
                            if body[row + dr][col + dc] { touching += 1 }
                        }
                    }
                    if touching < 2 { body[row][col] = false; changed = true }
                }
            }
        }
        return body
    }

    // MARK: Small heads

    /// [updates] A mark (an update line's face, its card's member faces) under this many points is drawn on its drawn
    /// grid (`drawn` LEDs across) as drawn, not traced onto the finer one: at mark sizes 20 LEDs ran together into a
    /// blur of colour with no eyes (review 2026-10-28: "Ivy = blue pill, Inbox = teal smudge"; owner: the line should
    /// "show that bot's face"). Every other head, at any size, and a mark from here up are drawn as ever.
    static let coarseBelow: CGFloat = 30

    /// LEDs across a head drawn `pointSide` points square; `mark`: it's an update mark (`coarseBelow`).
    static func size(pointSide: CGFloat, mark: Bool) -> Int { mark && pointSide < coarseBelow ? drawn : grid }

    /// The head's LEDs on a grid `size` across (`grid`, or `drawn` for a small head: the outline as drawn).
    static func leds(_ design: MatrixDesign, size: Int) -> [[Bool]] { size == grid ? leds(design) : outline(design).body }

    /// The face's LEDs on a grid `size` across: on the drawn grid, the face as drawn, LED for LED, its slit eyes two
    /// LEDs wide (one LED was a hairline at mark sizes; review 2026-10-28).
    static func faceLEDs(_ design: MatrixDesign, pose: MatrixPose, size: Int) -> [Cell: MatrixDot.Kind] {
        size == grid ? faceLEDs(design, pose: pose) : faceCells(design, outline: outline(design), pose: pose, wide: true).kinds
    }

    /// Every LED of `design` at `pose`, lit or not, row by row.
    static func dots(_ design: MatrixDesign, pose: MatrixPose = .rest, size: Int = grid) -> [MatrixDot] {
        let body = leds(design, size: size)
        let box = box(body)
        let face = faceLEDs(design, pose: pose, size: size)
        var dots: [MatrixDot] = []
        for row in 0..<size {
            for col in 0..<size where body[row][col] {
                let (light, hot) = lighting(design, box, Double(col) + 0.5, Double(row) + 0.5)
                dots.append(MatrixDot(col: col, row: row, kind: face[Cell(col, row)] ?? .body, light: light, hot: hot))
            }
        }
        return dots
    }

    /// The face on the head's grid. It is worked out on the drawn grid and each part of it (an eye, the mouth, a cheek)
    /// scaled up on its own, so both eyes come out alike; a glance or a look up moves it whole LEDs, one for each drawn
    /// one, so it stays inside the outline and reads in even steps. Turned left, it is the face turned right mirrored,
    /// glancing the other way.
    static func faceLEDs(_ design: MatrixDesign, pose: MatrixPose) -> [Cell: MatrixDot.Kind] {
        if design.facing < 0 {
            var right = design
            right.facing = 1
            return Dictionary(uniqueKeysWithValues: faceLEDs(right, pose: pose.mirrored).map { (Cell(grid - 1 - $0.key.col, $0.key.row), $0.value) })
        }
        let face = faceCells(design, outline: outline(design), pose: pose)
        var leds: [Cell: MatrixDot.Kind] = [:]
        for part in face.parts {
            for (cell, kind) in scaled(part, face.kinds, moved: Cell(pose.gaze, pose.lift)) where leds[cell].map({ faceOrder.firstIndex(of: $0)! > faceOrder.firstIndex(of: kind)! }) ?? true {
                leds[cell] = kind
            }
        }
        return leds
    }

    /// Which kind of face LED wins where two meet or tie.
    static let faceOrder: [MatrixDot.Kind] = [.pupil, .white, .hole, .blush]

    /// One part of the face on the head's grid: scaled to the nearest whole number of LEDs each way (one at least) and
    /// centred on an LED or between two as that number is odd or even, each LED taking the kind most of it covers, if
    /// the part covers more than half of it. A part `moved` drawn LEDs from where it rests is placed at rest and moved
    /// that many of the head's LEDs.
    static func scaled(_ part: Set<Cell>, _ kinds: [Cell: MatrixDot.Kind], moved: Cell = Cell(0, 0)) -> [Cell: MatrixDot.Kind] {
        guard let first = part.map(\.col).min(), let last = part.map(\.col).max(),
              let top = part.map(\.row).min(), let bottom = part.map(\.row).max() else { return [:] }
        let scale = Double(grid) / Double(drawn), samples = 4
        let w = last - first + 1, h = bottom - top + 1
        let wide = max(1, Int((Double(w) * scale).rounded())), high = max(1, Int((Double(h) * scale).rounded()))
        func start(_ from: Int, _ span: Int, _ count: Int) -> Int {
            let middle = (Double(from) + Double(span) / 2) * scale
            let centre = count % 2 == 1 ? (middle - 0.5).rounded() + 0.5 : middle.rounded()
            return Int(centre - Double(count) / 2)
        }
        let left = start(first - moved.col, w, wide) + moved.col, upper = start(top - moved.row, h, high) + moved.row
        var leds: [Cell: MatrixDot.Kind] = [:]
        for row in upper..<(upper + high) {
            for col in left..<(left + wide) {
                var counts = [Int](repeating: 0, count: faceOrder.count)
                for sy in 0..<samples {
                    for sx in 0..<samples {
                        let fx = (Double(col - left) + (Double(sx) + 0.5) / Double(samples)) / Double(wide)
                        let fy = (Double(row - upper) + (Double(sy) + 0.5) / Double(samples)) / Double(high)
                        let cell = Cell(first + Int(fx * Double(w)), top + Int(fy * Double(h)))
                        if part.contains(cell), let kind = kinds[cell], let index = faceOrder.firstIndex(of: kind) { counts[index] += 1 }
                    }
                }
                guard counts.reduce(0, +) * 2 > samples * samples, let most = counts.max() else { continue }
                leds[Cell(col, row)] = faceOrder[counts.firstIndex(of: most)!]
            }
        }
        return leds
    }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Light

    /// Lit from above on the side the face turns to: the colour fills the face and fades to unlit grey toward the
    /// bottom, the far side and the rim. (how lit, how near the glint)
    static func lighting(_ design: MatrixDesign, _ box: Box, _ x: Double, _ y: Double) -> (Double, Double) {
        let u = (x - box.cx) / max(box.hw, 1), v = (y - box.cy) / max(box.hh, 1)
        let f = Double(design.facing)
        let shadow = 0.6 * v - 0.38 * f * u + 0.38 * (u * u + v * v)
        let light = 1 - smooth(0.25, 1.25, shadow)
        let hot = 1 - smooth(0.0, 0.62, hypot(u - 0.32 * f, v + 0.5))
        return (light, hot)
    }

    // MARK: The face

    struct Face {
        var holes = Set<Cell>(), whites = Set<Cell>(), pupils = Set<Cell>(), blush = Set<Cell>()
        /// The same LEDs by part: the eyes (left first), then the mouth and the cheeks.
        var parts: [Set<Cell>] = []

        /// Each LED's kind.
        var kinds: [Cell: MatrixDot.Kind] {
            var kinds: [Cell: MatrixDot.Kind] = [:]
            for cell in blush { kinds[cell] = .blush }
            for cell in holes { kinds[cell] = .hole }
            for cell in whites { kinds[cell] = .white }
            for cell in pupils { kinds[cell] = .pupil }
            return kinds
        }
    }

    /// `wide`: slits drawn two LEDs wide (as ovals), for a small head.
    static func faceCells(_ design: MatrixDesign, outline: Outline, pose: MatrixPose, wide: Bool = false) -> Face {
        var face = Face()
        let look: MatrixDesign.Eyes = wide && design.eyes == .slits ? .ovals : design.eyes
        let ey = outline.eyeRow + pose.lift
        let eyes = [outline.left + pose.gaze, outline.right + pose.gaze]
        for (index, x) in eyes.enumerated() {
            // A two-wide eye grows outward from its column, so the pair stays even.
            let outward = twoWide(look) && index == 0 ? -1 : 0
            var cells = eyeShape(look, lids: pose.lids).map { Cell(x + $0.0 + outward, ey + $0.1) }
            var part = Set(cells)
            if look == .googly, pose.lids == 0 {
                let pupil = Cell(x + max(-1, min(1, pose.gaze)), ey + (pose.lift < 0 ? 0 : 1))
                cells.removeAll { $0 == pupil }
                face.pupils.insert(pupil)
                part.insert(pupil)
            }
            if look == .googly { face.whites.formUnion(cells) } else { face.holes.formUnion(cells) }
            face.parts.append(part)
        }
        let my = ey + 3, mx = (eyes[0] + eyes[1]) / 2
        let mouth: [(Int, Int)] = switch design.mouth {
        case .none: []
        case .smile: [(-2, 0), (-1, 1), (0, 1), (1, 1), (2, 0)]
        case .open: [(0, 0), (0, 1)]
        case .cat: [(-2, 0), (-1, 1), (0, 0), (1, 1), (2, 0)]
        case .line: [(-1, 0), (0, 0), (1, 0)]
        }
        for (dx, dy) in mouth { face.holes.insert(Cell(mx + dx, my + dy)) }
        face.parts.append(Set(mouth.map { Cell(mx + $0.0, my + $0.1) }))
        if design.blush {
            for x in [eyes[0] - 1, eyes[1] + 1] { face.blush.insert(Cell(x, ey + 2)); face.parts.append([Cell(x, ey + 2)]) }
        }
        face.parts = face.parts.map { $0.filter(outline.contains) }.filter { !$0.isEmpty }
        face.holes = face.holes.filter(outline.contains)
        face.whites = face.whites.filter(outline.contains)
        face.pupils = face.pupils.filter(outline.contains)
        face.blush = face.blush.filter(outline.contains)
        face.holes.subtract(face.pupils)
        face.whites.subtract(face.pupils)
        face.blush.subtract(face.holes.union(face.whites))
        return face
    }

    static func twoWide(_ eyes: MatrixDesign.Eyes) -> Bool { eyes == .dots || eyes == .ovals }

    /// One eye's dark cells about its centre, with the lids `lids` steps down.
    static func eyeShape(_ eyes: MatrixDesign.Eyes, lids: Int) -> [(Int, Int)] {
        let open: [(Int, Int)] = switch eyes {
        case .slits: [(0, -1), (0, 0), (0, 1)]
        case .dots: [(0, 0), (1, 0), (0, 1), (1, 1)]
        case .ovals: [(0, -1), (1, -1), (0, 0), (1, 0), (0, 1), (1, 1)]
        case .googly: [(-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        case .happy: [(-1, 1), (0, 0), (1, 1)]
        case .sleepy: [(-1, 1), (0, 1), (1, 1)]
        case .stars: [(0, -1), (-1, 0), (0, 0), (1, 0), (0, 1)]
        case .hearts: [(-1, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (0, 1)]
        case .crossed: [(-1, -1), (1, -1), (0, 0), (-1, 1), (1, 1)]
        }
        guard lids > 0 else { return open }
        let rows = open.map(\.1)
        let bottom = rows.max() ?? 0, top = rows.min() ?? 0
        if eyes == .happy || eyes == .sleepy { return lids >= 2 ? open.filter { $0.1 == bottom } : open }
        if lids >= 2 {
            // Shut: one line low in the eye.
            let line = bottom - (bottom - top) / 2
            return Set(open.map(\.0)).sorted().map { ($0, line) }
        }
        return open.filter { $0.1 > top }
    }
}

// MARK: - Colour

/// The LED colours of one head on one page.
nonisolated struct MatrixPalette: Sendable {
    var lit: OKLab
    var hot: OKLab
    var unlit: OKLab
    var shade: OKLab
    var blush: OKLab
    /// A googly eye's pupil.
    var pupil: OKLab
    /// A dark LED: nil leaves a gap (a dark page, or black LEDs on a light one).
    var hole: OKLab?

    static func make(_ design: MatrixDesign, dark: Bool) -> MatrixPalette {
        if design.mono { return mono(dark: dark) }
        let base = OKLab(rgb: HeadRGB(design.color))
        // As bright as an LED on a dark page; deep enough to hold its own against a light one.
        var lit = base
        lit.l = dark ? min(max(base.l, 0.68), 0.80) : min(max(base.l, 0.55), 0.64)
        let chroma = hypot(lit.a, lit.b)
        if chroma > 0.02 {
            let want = max(chroma, 0.11)
            lit.a *= want / chroma
            lit.b *= want / chroma
        }
        var hot = lit
        hot.l = min(0.97, lit.l + (dark ? 0.15 : 0.1))
        hot.a *= 0.62
        hot.b *= 0.62
        // Unlit LEDs: a grey with a breath of the colour, darker still deep in the shade.
        let unlit = OKLab(l: dark ? 0.56 : 0.72, a: lit.a * 0.14, b: lit.b * 0.14)
        let shade = OKLab(l: dark ? 0.44 : 0.78, a: lit.a * 0.06, b: lit.b * 0.06)
        let ink = OKLab(l: 0.24, a: lit.a * 0.18, b: lit.b * 0.18)
        return MatrixPalette(lit: lit, hot: hot, unlit: unlit, shade: shade,
                             blush: OKLab(l: dark ? 0.76 : 0.7, a: 0.15, b: 0.02),
                             pupil: dark ? OKLab(l: 0.99, a: 0, b: 0) : OKLab(l: 0.22, a: lit.a * 0.15, b: lit.b * 0.15),
                             hole: dark ? nil : ink)
    }

    /// Ink: white LEDs on a dark page, black ones on a light page, its dark LEDs gaps on both.
    static func mono(dark: Bool) -> MatrixPalette {
        let lit = OKLab(l: dark ? 0.94 : 0.25, a: 0, b: 0)
        return MatrixPalette(lit: lit, hot: OKLab(l: dark ? 1 : 0.36, a: 0, b: 0), unlit: OKLab(l: dark ? 0.5 : 0.8, a: 0, b: 0),
                             shade: OKLab(l: dark ? 0.38 : 0.88, a: 0, b: 0), blush: OKLab(l: dark ? 0.76 : 0.7, a: 0.15, b: 0.02),
                             pupil: OKLab(l: dark ? 0.99 : 0.2, a: 0, b: 0), hole: nil)
    }
}

/// Björn Ottosson's OKLab: colours mixed in it stay vivid in between.
nonisolated struct OKLab: Hashable, Sendable {
    var l: Double, a: Double, b: Double

    init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

    init(rgb: HeadRGB) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(rgb.red), g = linear(rgb.green), bl = linear(rgb.blue)
        let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    }

    func mixed(_ other: OKLab, _ t: Double) -> OKLab {
        OKLab(l: l + (other.l - l) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }

    /// sRGB 0…1, clipped to the gamut.
    var rgb: (red: Double, green: Double, blue: Double) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        func gamma(_ c: Double) -> Double {
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return max(0, min(1, v))
        }
        return (gamma(4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S),
                gamma(-1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S),
                gamma(-0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S))
    }

    func cgColor(alpha: Double = 1) -> CGColor {
        let c = rgb
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
    }
}

// MARK: - Drawing

nonisolated enum MatrixHeadRenderer {
    /// How much of a cell a dot fills, by how far apart the dots are (points): 74% when they are 2.9 pt apart or more,
    /// up to 90% at 1.5 pt or less, so the shape still reads where single dots are too small to see.
    static func fill(pitch: CGFloat) -> Double {
        0.74 + 0.16 * MatrixHead.smooth(0, 1, Double((44 - pitch * 15) / 22))
    }

    /// Where the LEDs go in a `side`-square (`pointSide` points): how many across, how far apart and the inset of the
    /// first. [updates] A small mark (`MatrixHead.coarseBelow`) has its drawn grid's 15 across.
    static func grid(side: CGFloat, pointSide: CGFloat?, mark: Bool) -> (size: Int, pitch: CGFloat, inset: CGFloat) {
        // The LEDs span the whole square, as the head's 20 across do: whole pixels shrank a 29 pt head to 75 of its 87
        // pixels, a step down from 30 pt (review 2026-10-28).
        let size = MatrixHead.size(pointSide: pointSide ?? side, mark: mark)
        return (size, side / CGFloat(size), 0)
    }

    /// Draws the head into a `side`-square at the context's origin (y down). `pointSide`: the head's size in points,
    /// which sets how plump the dots are (`side` may be in pixels). `mark`: an update mark (`MatrixHead.coarseBelow`).
    static func draw(_ design: MatrixDesign, pose: MatrixPose = .rest, in ctx: CGContext, side: CGFloat, pointSide: CGFloat? = nil,
                     mark: Bool = false, dark: Bool) {
        let palette = MatrixPalette.make(design, dark: dark)
        let (size, pitch, inset) = grid(side: side, pointSide: pointSide, mark: mark)
        let small = size != MatrixHead.grid
        let dots = MatrixHead.dots(design, pose: pose, size: size)
        // A small head's LEDs fill less of their cell, so the gaps between them show (the LED look), and keep more of
        // their colour toward the back, so the outline reads as the bot's colour rather than fading into grey.
        let full = small ? 0.86 : fill(pitch: (pointSide ?? side) / CGFloat(MatrixHead.grid))
        func colour(_ dot: MatrixDot) -> OKLab? {
            switch dot.kind {
            case .body:
                let lit = palette.lit.mixed(palette.hot, dot.hot * 0.8)
                // Small, the back of the head keeps most of its colour: faded, a light-page mark read washed out.
                let light = small ? 0.8 + 0.2 * dot.light : dot.light
                let grey = palette.shade.mixed(palette.unlit, MatrixHead.smooth(0, 0.5, light))
                return grey.mixed(lit, MatrixHead.smooth(0.1, 1, light))
            case .hole: return palette.hole
            case .white: return nil
            case .blush: return palette.blush
            case .pupil: return palette.pupil
            }
        }
        func radius(_ dot: MatrixDot) -> CGFloat {
            let share = dot.kind == .body && !small ? full * (0.8 + 0.2 * MatrixHead.smooth(0, 0.6, dot.light)) : full
            return pitch * CGFloat(share) / 2
        }
        func centre(_ dot: MatrixDot) -> CGPoint {
            CGPoint(x: inset + (CGFloat(dot.col + MatrixPose.slide(pose.glitch, row: dot.row)) + 0.5) * pitch,
                    y: inset + (CGFloat(dot.row) + 0.5) * pitch)
        }
        if dark {
            // The light the face gives off, pooled behind it and gone before the picture's edge (cut off there, it
            // would show as a square in a list).
            let box = MatrixHead.box(MatrixHead.leds(design, size: size))
            let middle = CGPoint(x: inset + (box.cx + Double(design.facing) * box.hw * 0.1) * pitch,
                                 y: inset + (box.cy - box.hh * 0.12) * pitch)
            let reach = min(middle.x, side - middle.x, middle.y, side - middle.y)
            let glow = design.mono ? 0.12 : 0.2
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [palette.lit.cgColor(alpha: glow), palette.lit.cgColor(alpha: glow * 0.45),
                                                  palette.lit.cgColor(alpha: 0)] as CFArray,
                                         locations: [0, 0.55, 1]) {
                ctx.drawRadialGradient(gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: reach, options: [])
            }
            // A soft bloom under the lit LEDs, inside the picture (an outline can reach its edge, and a shield's top its
            // corners: cut off there, a bloom would show a straight line).
            for dot in dots where dot.kind != .hole && dot.kind != .white && (dot.kind != .body || dot.light > 0.4) {
                guard let c = colour(dot) else { continue }
                let p = centre(dot), r = min(pitch * 0.62, p.x, p.y, side - p.x, side - p.y)
                ctx.setFillColor(c.cgColor(alpha: dot.kind == .body ? 0.16 * dot.light : 0.22))
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
        for dot in dots {
            guard let c = colour(dot) else { continue }
            let r = radius(dot), p = centre(dot)
            ctx.setFillColor(c.cgColor())
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// A bitmap of the head, `side` points square at `scale` pixels per point.
    static func makeImage(_ design: MatrixDesign, pose: MatrixPose = .rest, side: CGFloat, scale: CGFloat, mark: Bool = false,
                          dark: Bool) -> CGImage? {
        bitmap(side: side, scale: scale) { ctx, pixels in
            draw(design, pose: pose, in: ctx, side: pixels, pointSide: side, mark: mark, dark: dark)
        }
    }

    /// [moods] The head with every LED at full light, which a face's effects show through (a light running round, a
    /// radar sweep, code rain): where an effect passes, the LEDs flare up. On a dark page they glow brighter, on a light
    /// page their colour deepens. `rim`: only the LEDs at the outline's edge, `depth` deep. LEDs in `skip` (the eyes and
    /// mouth wherever the face puts them) stay out, so a flare never covers the face.
    static func drawLit(_ design: MatrixDesign, in ctx: CGContext, side: CGFloat, pointSide: CGFloat? = nil, mark: Bool = false, dark: Bool,
                        skip: Set<MatrixHead.Cell> = [], rim depth: Int? = nil) {
        let palette = MatrixPalette.make(design, dark: dark)
        let (size, pitch, inset) = grid(side: side, pointSide: pointSide, mark: mark)
        let small = size != MatrixHead.grid
        let body = MatrixHead.leds(design, size: size)
        let full = small ? 0.86 : fill(pitch: (pointSide ?? side) / CGFloat(MatrixHead.grid))
        // [updates] A small head's lit picture is on its drawn grid too: the face (given on the head's grid) is found
        // there by where each of its LEDs falls.
        let skip = small ? Set(skip.map { MatrixHead.Cell(Int((Double($0.col) + 0.5) * Double(size) / Double(MatrixHead.grid)),
                                                          Int((Double($0.row) + 0.5) * Double(size) / Double(MatrixHead.grid))) })
                         : skip
        let flare: OKLab
        if design.mono {
            flare = OKLab(l: dark ? 1 : 0.12, a: 0, b: 0)
        } else if dark {
            flare = OKLab(l: min(0.95, palette.lit.l + 0.16), a: palette.lit.a * 0.8, b: palette.lit.b * 0.8)
        } else {
            flare = OKLab(l: max(0.4, palette.lit.l - 0.12), a: palette.lit.a * 1.25, b: palette.lit.b * 1.25)
        }
        func lit(_ col: Int, _ row: Int) -> Bool { (0..<size).contains(row) && (0..<size).contains(col) && body[row][col] }
        var cells: [MatrixHead.Cell] = []
        for row in 0..<size {
            for col in 0..<size where body[row][col] && !skip.contains(MatrixHead.Cell(col, row)) {
                if let depth {
                    // At the edge: an unlit cell within `depth` LEDs (across or down).
                    let edge = (1...depth).contains { d in !lit(col - d, row) || !lit(col + d, row) || !lit(col, row - d) || !lit(col, row + d) }
                    guard edge else { continue }
                }
                cells.append(MatrixHead.Cell(col, row))
            }
        }
        if dark {
            ctx.setFillColor(flare.cgColor(alpha: design.mono ? 0.18 : 0.3))
            for cell in cells {
                let p = CGPoint(x: inset + (CGFloat(cell.col) + 0.5) * pitch, y: inset + (CGFloat(cell.row) + 0.5) * pitch)
                let r = min(pitch * 0.72, p.x, p.y, side - p.x, side - p.y)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
        ctx.setFillColor(flare.cgColor())
        let r = pitch * CGFloat(full) / 2
        for cell in cells {
            let p = CGPoint(x: inset + (CGFloat(cell.col) + 0.5) * pitch, y: inset + (CGFloat(cell.row) + 0.5) * pitch)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// [moods] `drawLit` as a bitmap.
    static func makeLitImage(_ design: MatrixDesign, side: CGFloat, scale: CGFloat, mark: Bool = false, dark: Bool,
                             skip: Set<MatrixHead.Cell> = [], rim: Int? = nil) -> CGImage? {
        bitmap(side: side, scale: scale) { ctx, pixels in
            drawLit(design, in: ctx, side: pixels, pointSide: side, mark: mark, dark: dark, skip: skip, rim: rim)
        }
    }

    /// A clear `side`-point square at `scale`, y down, drawn by `draw` (handed the context and the side in pixels).
    static func bitmap(side: CGFloat, scale: CGFloat, _ draw: (CGContext, CGFloat) -> Void) -> CGImage? {
        let pixels = max(1, Int((side * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        draw(ctx, CGFloat(pixels))
        return ctx.makeImage()
    }
}
