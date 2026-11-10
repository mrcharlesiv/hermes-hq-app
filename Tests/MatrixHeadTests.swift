import CoreGraphics
import Foundation
import UIKit
import Testing
@testable import HermesHQNative

/// The dot-matrix head (MatrixHead.swift): every bot's head until it is given another, one of thirteen outlines drawn
/// LED by LED with nothing sticking out of it. Its default is picked from the profile name, so a bot wears the same
/// face, in the same colour family, on every device.
struct MatrixHeadTests {
    struct Vector: CustomTestStringConvertible, Sendable {
        var profile: String
        var hash: UInt32
        var color: Head.ColorName
        var silhouette: MatrixDesign.Silhouette
        var look: Head.Look
        var mouth: Head.Mouth = .none
        var blush = false
        var seed: Int
        var facing: Int
        var testDescription: String { profile }
    }

    // MARK: Defaults

    /// Worked out by a separate script from the same rules (FNV-1a of the name, then mulberry32 picks in order; the
    /// outline from FNV-1a of "matrix:" + the name). Colours, eyes, mouths and blush are build 378's.
    @Test(arguments: [
        Vector(profile: "default", hash: 2470140894, color: .teal, silhouette: .arch, look: .happy, seed: 322657247, facing: 1),
        Vector(profile: "ivy", hash: 2466054493, color: .peach, silhouette: .hex, look: .slits, seed: 318570846, facing: -1),
        Vector(profile: "finance", hash: 2503230957, color: .lilac, silhouette: .pebble, look: .slits, seed: 355747310, facing: 1),
        Vector(profile: "maple-revenue-operator", hash: 836524966, color: .grape, silhouette: .drop, look: .dots, seed: 836524966,
               facing: 1),
        Vector(profile: "bike-shop", hash: 2598610963, color: .sky, silhouette: .pebble, look: .ovals, seed: 451127316, facing: -1),
        Vector(profile: "hermes", hash: 3348504771, color: .lime, silhouette: .octagon, look: .dots, mouth: .smile, seed: 1201021124,
               facing: 1),
        Vector(profile: "inbox", hash: 3797079355, color: .sky, silhouette: .round, look: .slits, seed: 1649595708, facing: -1),
        Vector(profile: "otto", hash: 501755363, color: .pink, silhouette: .round, look: .slits, seed: 501755363, facing: 1),
        Vector(profile: "research", hash: 1658572492, color: .grass, silhouette: .arch, look: .slits, seed: 1658572492, facing: 1),
        Vector(profile: "codex", hash: 3570262116, color: .red, silhouette: .wide, look: .slits, seed: 1422778469, facing: -1),
        Vector(profile: "scout", hash: 3273829637, color: .mint, silhouette: .hex, look: .slits, seed: 1126345990, facing: -1),
        Vector(profile: "atlas", hash: 3407328204, color: .red, silhouette: .round, look: .slits, seed: 1259844557, facing: 1),
    ])
    func defaultHead(_ vector: Vector) {
        #expect(Head.nameHash(vector.profile) == vector.hash)
        let head = Head.defaultMatrixHead(profile: vector.profile)
        #expect(head.theme == .matrix)
        #expect(head.themed == nil)
        #expect(head.color == vector.color)
        #expect(head.silhouette == vector.silhouette)
        #expect(head.look == vector.look)
        #expect(head.mouth == vector.mouth)
        #expect(head.blush == vector.blush)
        #expect(head.seed == vector.seed)
        #expect(MatrixDesign(head).facing == vector.facing)
        #expect(head.specs == .none && head.tile == .none && head.hat == .none)
    }

    @Test func defaultIsTheSameForTheSameName() throws {
        #expect(Head.defaultMatrixHead(profile: "  Ivy ") == Head.defaultMatrixHead(profile: "ivy"))
        #expect(Head.defaultMatrixHead(profile: "   ") == Head.defaultMatrixHead(profile: "default"))
        #expect(Head.defaultMatrixHead(profile: "ivy") != Head.defaultMatrixHead(profile: "finance"))
        // Drawn twice, the same pixels.
        let design = MatrixDesign(Head.defaultMatrixHead(profile: "finance"))
        for dark in [false, true] {
            let first = try #require(MatrixHeadRenderer.makeImage(design, side: 44, scale: 3, dark: dark))
            let second = try #require(MatrixHeadRenderer.makeImage(design, side: 44, scale: 3, dark: dark))
            #expect(pixels(first) == pixels(second))
        }
    }

    /// A roster of new bots: every colour family, every outline but the heart (given, never picked), and no two faces
    /// alike; most are plain.
    @Test func defaultsVary() {
        let heads = (0..<48).map { Head.defaultMatrixHead(profile: "bot-\($0)") }
        #expect(Set(heads.map(\.color)).count == Head.matrixColours.count)
        #expect(Set(heads.map(\.silhouette)) == Set(MatrixDesign.Silhouette.allCases).subtracting([.heart]))
        #expect(Set(heads.map(\.look)) == [.slits, .ovals, .dots, .happy])
        let faces = Set(heads.map { "\($0.color)|\($0.silhouette)|\($0.look)|\($0.mouth)|\($0.blush)|\(MatrixDesign($0).facing)" })
        #expect(faces.count == heads.count)
        #expect(heads.filter { $0.mouth != .none || $0.blush }.count < heads.count / 4)
        #expect(!(0..<400).contains { Head.defaultMatrixHead(profile: "bot-\($0)").silhouette == .heart })
    }

    // MARK: Sizes

    /// Crisp at every size a head is shown: one pixel grid per scale, nothing in the corners, the face drawn.
    @Test(arguments: [16, 20, 24, 28, 32, 36, 44, 50, 56, 72, 96, 128, 288] as [CGFloat])
    func drawsAtEverySize(side: CGFloat) throws {
        let designs = MatrixDesign.Silhouette.allCases.enumerated().map { index, silhouette in
            MatrixDesign(silhouette: silhouette, eyes: MatrixDesign.Eyes.allCases[index % 8], facing: index % 2 == 0 ? 1 : -1)
        }
        for design in designs {
            for scale in [1, 2, 3] as [CGFloat] {
                for dark in [false, true] {
                    let image = try #require(MatrixHeadRenderer.makeImage(design, side: side, scale: scale, dark: dark))
                    let width = Int((side * scale).rounded(.up))
                    #expect(image.width == width && image.height == width)
                    let bytes = pixels(image)
                    // (At 16 pixels across the shield's top corner LEDs graze the corner pixels: 1 in 255.)
                    for (x, y) in [(0, 0), (width - 1, 0), (0, width - 1), (width - 1, width - 1)] {
                        #expect(bytes[(y * width + x) * 4 + 3] <= 2, "\(design.silhouette) corner \(x),\(y) at \(side) pt @\(scale)x dark \(dark)")
                    }
                    let alpha = stride(from: 3, to: bytes.count, by: 4).reduce(0.0) { $0 + Double(bytes[$1]) } / Double(width * width * 255)
                    #expect(alpha > 0.15 && alpha < 0.8, "\(design.silhouette) coverage \(alpha) at \(side) pt @\(scale)x dark \(dark)")
                }
            }
        }
    }

    /// On a dark page the glow behind a head fades out before the picture's edge: cut off there, it showed as a
    /// square behind each head in a list.
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func glowStaysInside(silhouette: MatrixDesign.Silhouette) throws {
        for facing in [-1, 1] {
            let design = MatrixDesign(silhouette: silhouette, facing: facing)
            let image = try #require(MatrixHeadRenderer.makeImage(design, side: 56, scale: 3, dark: true))
            let bytes = pixels(image), width = image.width
            let pitch = Double(width) / Double(MatrixHead.grid)
            let centres = MatrixHead.dots(design).map { ((Double($0.col) + 0.5) * pitch, (Double($0.row) + 0.5) * pitch) }
            var edge: [(Int, Int)] = []
            for i in 0..<width { edge += [(i, 0), (i, width - 1), (0, i), (width - 1, i)] }
            var lit: [String] = []
            for (x, y) in edge {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                // Only where no LED (or its bloom) reaches: what's there is the glow.
                guard centres.allSatisfy({ hypot($0.0 - px, $0.1 - py) > pitch * 0.7 }) else { continue }
                if bytes[(y * width + x) * 4 + 3] > 1 { lit.append("\(x),\(y)") }
            }
            #expect(lit.isEmpty, "\(silhouette) facing \(facing): \(lit.prefix(6))")
        }
    }

    /// The dots fill more of their cell when they are close together (a small head), so its shape still reads.
    @Test func smallHeadsHavePlumperDots() {
        func fill(_ pitch: CGFloat) -> Double { MatrixHeadRenderer.fill(pitch: pitch) }
        #expect(fill(2) > fill(2.4))
        #expect(fill(2.4) > fill(2.8))
        #expect(fill(2.94) == fill(20) && fill(20) == 0.74)
        #expect(fill(1.46) == fill(0.5) && fill(0.5) <= 0.9)
        #expect(fill(44 / CGFloat(MatrixHead.grid)) > fill(88 / CGFloat(MatrixHead.grid)), "a list's head against Edit Head's")
    }

    // MARK: Outlines

    /// Each outline is drawn as one clean piece: no stray or lone LEDs (each touches at least three others, one of them
    /// side on), no notches or holes, as big on the grid as the others, symmetric unless it's meant to lean, and its
    /// eyes inside it on one line.
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func outlineIsClean(silhouette: MatrixDesign.Silhouette) {
        let outline = MatrixHead.outline(silhouette, facing: 1)
        let grid = MatrixHead.drawn
        #expect(outline.body.count == grid && outline.body.allSatisfy { $0.count == grid })
        let cells = (0..<grid).flatMap { row in (0..<grid).map { MatrixHead.Cell($0, row) } }
        let leds = cells.filter(outline.contains)
        #expect((125...185).contains(leds.count), "\(silhouette): \(leds.count) LEDs")
        for led in leds {
            let around = (-1...1).flatMap { dy in (-1...1).map { dx in MatrixHead.Cell(led.col + dx, led.row + dy) } }
                .filter { $0 != led && outline.contains($0) }
            let sideOn = around.filter { $0.col == led.col || $0.row == led.row }
            #expect(around.count >= 3 && !sideOn.isEmpty, "\(silhouette): a stray LED at \(led.col),\(led.row)")
        }
        // One piece, and every gap reaches the edge of the grid.
        #expect(pieces(of: Set(leds)).count == 1, "\(silhouette) is in pieces")
        let gaps = Set(cells.filter { !outline.contains($0) })
        for piece in pieces(of: gaps) {
            #expect(piece.contains { $0.col == 0 || $0.row == 0 || $0.col == grid - 1 || $0.row == grid - 1 },
                    "\(silhouette) has a hole at \(piece.first.map { "\($0.col),\($0.row)" } ?? "")")
        }
        let rows = Set(leds.map(\.row)), cols = Set(leds.map(\.col))
        #expect(rows.count >= 11 && cols.count >= 11, "\(silhouette) is \(cols.count) × \(rows.count)")
        let leaning: Set<MatrixDesign.Silhouette> = [.pebble, .cloud, .leaf]
        #expect((outline.body == outline.mirrored.body) == !leaning.contains(silhouette), "\(silhouette) symmetric")
        #expect(outline.contains(MatrixHead.Cell(outline.left, outline.eyeRow))
                && outline.contains(MatrixHead.Cell(outline.right, outline.eyeRow)))
        #expect(outline.right - outline.left == 4, "\(silhouette)'s eyes")
    }

    /// Traced onto the head's grid, each outline is still one piece with no holes and no lone LEDs, follows its drawing
    /// (every drawn LED inside the outline lit whole, nothing lit more than a drawn LED beyond it), and is symmetric
    /// where the drawing is.
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func ledsFollowTheDrawing(silhouette: MatrixDesign.Silhouette) {
        let outline = MatrixHead.outline(silhouette, facing: 1)
        let body = MatrixHead.leds(silhouette, facing: 1)
        let grid = MatrixHead.grid, step = Double(MatrixHead.drawn) / Double(grid)
        /// The drawn LED an LED's centre falls in.
        func drawn(_ led: MatrixHead.Cell) -> MatrixHead.Cell { MatrixHead.Cell(Int((Double(led.col) + 0.5) * step), Int((Double(led.row) + 0.5) * step)) }
        #expect(body.count == grid && body.allSatisfy { $0.count == grid })
        let cells = (0..<grid).flatMap { row in (0..<grid).map { MatrixHead.Cell($0, row) } }
        let leds = cells.filter { body[$0.row][$0.col] }
        func lit(_ cell: MatrixHead.Cell) -> Bool { (0..<grid).contains(cell.row) && (0..<grid).contains(cell.col) && body[cell.row][cell.col] }
        for led in leds {
            let around = (-1...1).flatMap { dy in (-1...1).map { dx in MatrixHead.Cell(led.col + dx, led.row + dy) } }.filter { $0 != led && lit($0) }
            #expect(around.count >= 2, "\(silhouette): a lone LED at \(led.col),\(led.row)")
            let under = drawn(led)
            let near = (-1...1).flatMap { dy in (-1...1).map { dx in MatrixHead.Cell(under.col + dx, under.row + dy) } }
            #expect(near.contains(where: outline.contains), "\(silhouette): \(led.col),\(led.row) is far outside the drawing")
        }
        #expect(pieces(of: Set(leds)).count == 1, "\(silhouette) is in pieces")
        for piece in pieces(of: Set(cells.filter { !lit($0) })) {
            #expect(piece.contains { $0.col == 0 || $0.row == 0 || $0.col == grid - 1 || $0.row == grid - 1 },
                    "\(silhouette) has a hole at \(piece.first.map { "\($0.col),\($0.row)" } ?? "")")
        }
        for cell in cells {
            let under = drawn(cell)
            let inside = (-1...1).allSatisfy { dy in (-1...1).allSatisfy { dx in outline.contains(MatrixHead.Cell(under.col + dx, under.row + dy)) } }
            if inside { #expect(lit(cell), "\(silhouette): \(cell.col),\(cell.row) on drawn LED \(under.col),\(under.row) isn't lit") }
        }
        let leaning: Set<MatrixDesign.Silhouette> = [.pebble, .cloud, .leaf]
        if !leaning.contains(silhouette) { #expect(body == body.map { $0.reversed() }, "\(silhouette) symmetric") }
        #expect(MatrixHead.leds(silhouette, facing: -1) == body.map { $0.reversed() })
    }

    /// No two outlines are near one another, either way they face: they stay tell-apart in a list.
    @Test func outlinesDiffer() {
        let all = MatrixDesign.Silhouette.allCases
        for (index, first) in all.enumerated() {
            for second in all[(index + 1)...] {
                let a = MatrixHead.outline(first, facing: 1)
                let difference = [1, -1].map { facing in
                    let b = MatrixHead.outline(second, facing: facing)
                    return zip(a.body.joined(), b.body.joined()).filter { $0 != $1 }.count
                }.min() ?? 0
                #expect(difference >= 12, "\(first) and \(second) differ in \(difference) LEDs")
            }
        }
    }

    /// Every face on every outline, whichever way it faces and in every pose it's drawn in: both eyes and the mouth
    /// whole, each of their dark LEDs ringed by LEDs (a face never breaks the outline's edge), and both cheeks there.
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func everyFaceFits(silhouette: MatrixDesign.Silhouette) {
        for facing in [-1, 1] {
            for eyes in MatrixDesign.Eyes.allCases {
                for mouth in MatrixDesign.Mouth.allCases {
                    let design = MatrixDesign(silhouette: silhouette, eyes: eyes, mouth: mouth, blush: true, facing: facing)
                    let outline = MatrixHead.outline(design)
                    for pose in MatrixPose.all + MatrixPose.reading + [.thinking(design)] {
                        let label = "\(silhouette) \(eyes) \(mouth) facing \(facing) at \(pose)"
                        let face = MatrixHead.faceCells(design, outline: outline, pose: pose)
                        let dark = face.holes.union(face.whites).union(face.pupils)
                        let mouthCells = [MatrixDesign.Mouth.none: 0, .smile: 5, .open: 2, .cat: 5, .line: 3][mouth] ?? 0
                        #expect(dark.count == 2 * MatrixHead.eyeShape(eyes, lids: pose.lids).count + mouthCells, "whole: \(label)")
                        #expect(face.blush.count == 2, "cheeks: \(label)")
                        for cell in dark {
                            let ring = (-1...1).flatMap { dy in (-1...1).map { dx in MatrixHead.Cell(cell.col + dx, cell.row + dy) } }
                            #expect(ring.allSatisfy(outline.contains), "\(cell.col),\(cell.row) at the edge: \(label)")
                        }
                    }
                }
            }
        }
    }

    /// On the head's LEDs too, every face in every pose is whole: every part of it there (both eyes, the mouth, both
    /// cheeks), on lit LEDs, each dark one ringed by lit ones, and the two eyes alike.
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func everyFaceFitsTheLEDs(silhouette: MatrixDesign.Silhouette) {
        for facing in [-1, 1] {
            let body = MatrixHead.leds(silhouette, facing: facing)
            func lit(_ col: Int, _ row: Int) -> Bool { (0..<MatrixHead.grid).contains(row) && (0..<MatrixHead.grid).contains(col) && body[row][col] }
            for eyes in MatrixDesign.Eyes.allCases {
                for mouth in MatrixDesign.Mouth.allCases {
                    let design = MatrixDesign(silhouette: silhouette, eyes: eyes, mouth: mouth, blush: true, facing: facing)
                    for pose in MatrixPose.all + MatrixPose.reading + [.thinking(design)] {
                        let label = "\(silhouette) \(eyes) \(mouth) facing \(facing) at \(pose)"
                        let leds = MatrixHead.faceLEDs(design, pose: pose)
                        for (cell, kind) in leds {
                            let ring = kind == .blush ? 0 : 1
                            let all = (-ring...ring).allSatisfy { dy in (-ring...ring).allSatisfy { dx in lit(cell.col + dx, cell.row + dy) } }
                            #expect(all, "\(label): \(cell.col),\(cell.row)")
                        }
                        #expect(leds.values.filter { $0 == .blush }.count >= 2, "cheeks: \(label)")
                        // Each part on the head's grid, worked out facing right (a face turned left is that mirrored).
                        var right = design
                        right.facing = 1
                        let face = MatrixHead.faceCells(right, outline: MatrixHead.outline(right), pose: MatrixPose(gaze: pose.gaze * facing, lift: pose.lift, lids: pose.lids))
                        #expect(face.parts.count == (mouth == .none ? 4 : 5), "parts: \(label)")
                        let scaled = face.parts.map { MatrixHead.scaled($0, face.kinds) }
                        #expect(scaled.allSatisfy { !$0.isEmpty }, "a part with no LEDs: \(label)")
                        // Both eyes alike: the same LEDs, moved along.
                        func shape(_ leds: [MatrixHead.Cell: MatrixDot.Kind]) -> [String] {
                            let col = leds.keys.map(\.col).min() ?? 0, row = leds.keys.map(\.row).min() ?? 0
                            return leds.map { "\($0.key.col - col),\($0.key.row - row) \($0.value)" }.sorted()
                        }
                        #expect(shape(scaled[0]) == shape(scaled[1]), "eyes differ: \(label)")
                    }
                }
            }
        }
    }

    /// The colour fills the face: the light fades only toward the back and the rim, so the outline reads in the bot's
    /// colour.
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func mostOfTheFaceIsLit(silhouette: MatrixDesign.Silhouette) {
        for facing in [-1, 1] {
            let dots = MatrixHead.dots(MatrixDesign(silhouette: silhouette, facing: facing))
            let lit = Double(dots.filter { $0.light >= 0.5 }.count) / Double(dots.count)
            #expect(lit >= 0.8, "\(silhouette) facing \(facing): \(lit)")
        }
    }

    /// A head turned to the left is the same head turned to the right, mirrored, glancing the other way.
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func facingMirrors(silhouette: MatrixDesign.Silhouette) {
        for (index, eyes) in MatrixDesign.Eyes.allCases.enumerated() {
            let mouth = MatrixDesign.Mouth.allCases[index % MatrixDesign.Mouth.allCases.count]
            let right = MatrixDesign(silhouette: silhouette, eyes: eyes, mouth: mouth, blush: index % 2 == 0, facing: 1)
            var left = right
            left.facing = -1
            func cells(_ design: MatrixDesign, _ pose: MatrixPose, mirrored: Bool) -> [MatrixHead.Cell: String] {
                Dictionary(MatrixHead.dots(design, pose: pose).map { dot in
                    let col = mirrored ? MatrixHead.grid - 1 - dot.col : dot.col
                    return (MatrixHead.Cell(col, dot.row), "\(dot.kind) \((dot.light * 1000).rounded()) \((dot.hot * 1000).rounded())")
                }, uniquingKeysWith: { first, second in "\(first) + \(second)" })
            }
            for pose in MatrixPose.all {
                let turned = MatrixPose(gaze: -pose.gaze, lift: pose.lift, lids: pose.lids)
                #expect(cells(left, turned, mirrored: true) == cells(right, pose, mirrored: false), "\(silhouette) \(eyes) at \(pose)")
            }
        }
    }

    @Test func facingComesFromTheSeed() {
        for seed in [1, 127, 128, 255, 256, 322657247, 2147483647] {
            let turned = MatrixHead.turned(seed: seed)
            #expect(turned > 0 && turned <= 2147483647)
            #expect(MatrixHead.facing(seed: turned) == -MatrixHead.facing(seed: seed))
        }
        var record = HeadRecord.defaultMatrixRecord(profile: "ivy")
        let facing = record.facing
        record.facing = -facing
        #expect(record.facing == -facing)
        #expect(MatrixDesign(record.head).facing == -facing)
        record.facing = -facing
        #expect(record.facing == -facing, "setting the same way changes nothing")
    }

    // MARK: Motion frames

    /// A blink and a glance are different pictures from the face at rest, and each step of reading from the next.
    @Test(arguments: MatrixDesign.Eyes.allCases)
    func posesChangeTheFace(eyes: MatrixDesign.Eyes) {
        let design = MatrixDesign(silhouette: .round, eyes: eyes, facing: 1)
        let rest = MatrixHead.dots(design)
        if eyes != .sleepy {
            #expect(MatrixHead.dots(design, pose: MatrixPose(lids: 2)) != rest, "a blink shuts the eyes")
        }
        #expect(MatrixHead.dots(design, pose: MatrixPose(gaze: -1, lift: -1)) != rest, "a glance moves them")
        #expect(MatrixHead.dots(design, pose: .thinking(design)) != rest)
        let reading = MatrixPose.reading.map { MatrixHead.dots(design, pose: $0) }
        for (index, frame) in reading.enumerated() { #expect(frame != reading[(index + 1) % reading.count], "reading step \(index)") }
        #expect(MatrixPose.thinking(design) == MatrixPose(gaze: 1, lift: -1))
    }

    // MARK: Colour

    /// Every colour holds its own on both pages: the lit LEDs against a light page (3:1, a graphic) and a dark one
    /// (4.5:1), and the eyes against the lit LEDs on a light page.
    @Test(arguments: HeadRecord.shapeColors.filter { $0 != "ink" })
    func coloursHaveContrast(name: String) throws {
        let colour = try #require(Head.ColorName(rawValue: name))
        var head = Head.defaultMatrixHead(profile: "ivy")
        head.color = colour
        let design = MatrixDesign(head)
        let light = MatrixPalette.make(design, dark: false)
        let lit = luminance(light.lit)
        #expect(contrast(lit, 1) >= 3, "\(name) on white: \(contrast(lit, 1))")
        let hole = try #require(light.hole)
        #expect(contrast(luminance(hole), lit) >= 3, "\(name) eyes: \(contrast(luminance(hole), lit))")
        let dark = MatrixPalette.make(design, dark: true)
        #expect(dark.hole == nil, "a dark page's eyes are gaps")
        for page in [0, luminance(OKLab(rgb: HeadRGB(0x1C1C1E)))] {
            #expect(contrast(luminance(dark.lit), page) >= 4.5, "\(name) on dark: \(contrast(luminance(dark.lit), page))")
        }
        // The unlit back of the head still shows, so the whole outline reads on either page.
        #expect(contrast(luminance(light.unlit), 1) >= 2.1, "\(name) unlit on white: \(contrast(luminance(light.unlit), 1))")
        #expect(contrast(luminance(light.shade), 1) >= 1.7, "\(name) shade on white: \(contrast(luminance(light.shade), 1))")
        #expect(contrast(luminance(dark.unlit), 0) >= 3.6, "\(name) unlit on black: \(contrast(luminance(dark.unlit), 0))")
        #expect(contrast(luminance(dark.shade), 0) >= 2.2, "\(name) shade on black: \(contrast(luminance(dark.shade), 0))")
    }

    /// Ink is white LEDs on a dark page and black ones on a light page, its eyes gaps on both.
    @Test func inkIsMono() {
        var head = Head.defaultMatrixHead(profile: "ivy")
        head.color = .ink
        let design = MatrixDesign(head)
        #expect(design.mono)
        let light = MatrixPalette.make(design, dark: false), dark = MatrixPalette.make(design, dark: true)
        #expect(light.hole == nil && dark.hole == nil)
        #expect(contrast(luminance(light.lit), 1) >= 4.5)
        #expect(contrast(luminance(dark.lit), 0) >= 4.5)
        #expect(abs(light.lit.a) < 0.001 && abs(dark.lit.b) < 0.001, "no colour")
        #expect(HeadGeometry.invertsOnDarkPage(head))
        head.blush = true
        #expect(!HeadGeometry.invertsOnDarkPage(head), "pink cheeks would invert green")
        head.color = .teal
        head.blush = false
        #expect(!HeadGeometry.invertsOnDarkPage(head))
    }

    // MARK: Records

    @Test func headMapsToParts() {
        var head = Head.defaultMatrixHead(profile: "ivy")
        head.silhouette = .leaf
        head.mouth = .grille
        head.color = .grape
        let design = MatrixDesign(head)
        #expect(design.silhouette == .leaf)
        #expect(design.mouth == .none, "a dot-matrix head draws no mouth")
        #expect(design.color == HeadTones.accent(.grape).hex && !design.mono)
        #expect(design.facing == MatrixHead.facing(seed: head.seed))
    }

    /// A saved `form` is an outline's own name, or a Shapes form read as the outline nearest it (what build 378 saved,
    /// and what a Shapes head brings); an outline becomes a Shapes head as the nearest form.
    @Test func formsMapToOutlines() {
        let nearest: [String: MatrixDesign.Silhouette] = ["round": .round, "blob": .pebble, "square": .square, "pill": .tall,
                                                          "triangle": .drop, "hex": .hex, "cloud": .cloud, "drop": .drop,
                                                          "star": .octagon, "heart": .heart, "junk": .round, "": .round]
        for (form, outline) in nearest { #expect(MatrixDesign.Silhouette(stored: form) == outline, "\(form)") }
        for outline in MatrixDesign.Silhouette.allCases {
            #expect(MatrixDesign.Silhouette(stored: outline.rawValue) == outline)
            #expect(HeadRecord.forms.contains(outline.shapesForm), "\(outline)")
        }
    }

    /// A saved dot-matrix head comes back as it was, and a saved Shapes head stays one: only a bot with no head at all
    /// gets the new default.
    @Test func recordsRoundTrip() throws {
        let record = HeadRecord.defaultMatrixRecord(profile: "ivy")
        #expect(record.theme == "matrix" && record.form == "hex" && record.tile == "none")
        #expect(record.specs == "none" && record.antenna == "none" && record.ears == "none", "no visor, antenna or ears")
        let parsed = try #require(HeadRecord.parse(record.stored))
        #expect(parsed == record)
        let head = Head.resolve(record.stored, profile: "someone-else")
        #expect(head == Head.defaultMatrixHead(profile: "ivy"))
        #expect(head.cacheKey == record.pictureKey)
        #expect(head.cacheKey == "matrix|hex|slits|none|0|peach|-1")
        #expect(record.forSaving.theme == "matrix")
        #expect(record.head == head)

        // Build 378 saved a Shapes form, a visor, an antenna and ears: the form reads as the nearest outline, and the
        // rest is neither drawn nor saved again.
        var old = record
        old.form = "pill"
        old.specs = "shades"
        old.antenna = "bulb"
        old.ears = "headset"
        let read = try #require(HeadRecord.parse(old.stored))
        #expect(read.form == "tall")
        #expect(Head(record: read)?.silhouette == .tall)
        #expect(Head(record: old)?.silhouette == .tall)
        #expect(old.pictureKey == read.pictureKey && read.pictureKey == Head(record: read)?.cacheKey)
        let saved = read.forSaving
        #expect(saved.specs == "none" && saved.antenna == "none" && saved.ears == "none" && saved.form == "tall")

        #expect(Head.resolve(nil, profile: "finance") == Head.defaultShapeHead(profile: "finance"))
        #expect(Head.defaultHead(profile: "finance") == Head.defaultShapeHead(profile: "finance"))
        #expect(HeadRecord.defaultRecord(profile: "finance") == HeadRecord.defaultShapeRecord(profile: "finance"))
        let shapes = HeadRecord.defaultShapeRecord(profile: "finance")
        let shape = Head.resolve(shapes.stored, profile: "finance")
        #expect(shape.theme == .shape)
        #expect(shape == Head.defaultShapeHead(profile: "finance"))
    }

    @Test func shuffleAndIdeasStayMatrix() throws {
        var random = SeededRandom(seed: 42)
        var outlines = Set<String>()
        for _ in 0..<60 {
            let record = HeadRecord.roll({ random.next() }, theme: "matrix")
            #expect(record.theme == "matrix" && record.tile == "none" && record.hat == "none")
            #expect(record.specs == "none" && record.antenna == "none" && record.ears == "none")
            #expect(record.color != "slate" && record.color != "paper")
            #expect(MatrixDesign.Silhouette(rawValue: record.form) != nil, "\(record.form)")
            outlines.insert(record.form)
            let head = try #require(Head(record: record))
            #expect(head.theme == .matrix)
        }
        #expect(outlines.count >= 11, "\(outlines)")
        let ideas = HeadRecord.ideas(profile: "ivy", about: "reads my email", round: 0, theme: "matrix")
        #expect(ideas.count == 10)
        #expect(ideas.allSatisfy { $0.theme == "matrix" && Head(record: $0)?.theme == .matrix })
        #expect(ideas.allSatisfy { $0.antenna == "none" && $0.ears == "none" && $0.mouth == "none" })
        #expect(Set(ideas.map(\.pictureKey)).count == ideas.count)
        #expect(ideas[0].form == "wide", "the first idea for mail is wide, like an envelope")
        let guarding = HeadRecord.ideas(profile: "ivy", about: "security guard", round: 0, theme: "matrix")
        #expect(guarding[0].form == "shield")
        #expect(guarding.allSatisfy { $0.antenna == "none" && $0.ears == "none" }, "the topic's robot extras stay off")
        let cooking = HeadRecord.ideas(profile: "ivy", about: "cooks dinner", round: 0, theme: "matrix")
        #expect(cooking.allSatisfy { $0.mouth == "none" }, "a cook's smile stays off")
    }

    /// Every head draws its eyes and nothing else, and only the normal eyes (owner, 2026-10-28: "i don't want mouths",
    /// then "only one kind of eyes - the normal ones"), whatever its record keeps: the hermes bot's build 378 smile is
    /// still saved, and its face is its slit eyes alone.
    @Test func everyHeadDrawsOnlyItsNormalEyes() throws {
        let hermes = Head.defaultMatrixHead(profile: "hermes")
        #expect(hermes.mouth == .smile, "kept in the record")
        let plain = MatrixDesign(hermes)
        #expect(plain.eyes == .slits && plain.mouth == .none && !plain.blush)
        let plainPicture = try #require(HeadRenderer.picture(hermes, side: 44, scale: 2, dark: false))
        for look in Head.Look.allCases {
            for mouth in [Head.Mouth.none, .smile] {
                var head = hermes
                head.look = look
                head.mouth = mouth
                head.blush = look == .stars
                #expect(MatrixDesign(head) == plain, "\(look) \(mouth)")
                let drawn = try #require(HeadRenderer.picture(head, side: 44, scale: 2, dark: false))
                #expect(pixels(drawn) == pixels(plainPicture), "\(look) \(mouth)")
            }
        }
        // A Shapes head: slits, no glasses, mouth or cheeks.
        var shape = Head.defaultShapeHead(profile: "finance")
        let plainShape = try #require(HeadRenderer.picture(shape, side: 44, scale: 2, dark: false))
        shape.look = .hearts; shape.specs = .aviators; shape.mouth = .cat; shape.blush = true
        #expect(shape.plain == Head.defaultShapeHead(profile: "finance"))
        #expect(pixels(try #require(HeadRenderer.picture(shape, side: 44, scale: 2, dark: false))) == pixels(plainShape))
        // A robot: its own icon eyes, even when done; a Dots face: two tall lamp eyes; neither with a mouth or cheeks.
        var robot = HeadRecord()
        robot.face = "dizzy"; robot.mouth = "cat"; robot.blush = true
        #expect(robot.plain.face == "visor" && robot.plain.mouth == "none" && !robot.plain.blush)
        #expect(ThemeHeadSVG.svg(robot, state: .done, plain: true).contains("M553 556a73 111"), "the icon's eyes")
        var dots = HeadRecord()
        dots.theme = "dots"; dots.pattern = "face"; dots.face = "heart"; dots.mouth = "smile"; dots.blush = true
        #expect(dots.plain.face == "pill" && dots.plain.mouth == "none" && !dots.plain.blush)
        // A pixel creature: never pink cheeks (the web gives four in ten).
        var pixel = HeadRecord()
        pixel.theme = "pixel"
        let seeds = 1...40
        #expect(seeds.contains { pixel.seed = $0; return ThemeHeadSVG.svg(pixel).contains("#FF7FA8") })
        #expect(!seeds.contains { pixel.seed = $0; return ThemeHeadSVG.svg(pixel, plain: true).contains("#FF7FA8") })
    }

    @Test func labelsAndWords() {
        #expect(HeadLabels.offeredThemes.first == "shape")
        #expect(HeadLabels.themes["matrix"] == "Matrix")
        #expect(HeadLabels.summary(HeadRecord.defaultMatrixRecord(profile: "scout")) == "Matrix, Mint, Hex")
        #expect(HeadRecord.outlines == MatrixDesign.Silhouette.allCases.map(\.rawValue))
        #expect(MatrixDesign.Silhouette.allCases.allSatisfy { HeadLabels.outlines[$0.rawValue] != nil })
        #expect(HeadDescribe.describe("led cat").parts["theme"] == "matrix")
        #expect(HeadDescribe.describe("a dot matrix robot").parts["theme"] == "matrix", "Matrix beats Dots and Robot")
        #expect(HeadDescribe.describe("glowing dots").parts["theme"] == "dots")
        // Describe it: an outline's own word, or the outline nearest a Shapes word.
        var head = HeadRecord.defaultMatrixRecord(profile: "ivy")
        head.applyDescribed(HeadDescribe.describe("a leaf").parts)
        #expect(head.form == "leaf")
        head.applyDescribed(HeadDescribe.describe("pill").parts)
        #expect(head.form == "tall")
        head.applyDescribed(HeadDescribe.describe("shield badge").parts)
        #expect(head.form == "shield")
        #expect(HeadDescribe.describe("a leaf").understood == ["leaf"])
        // Made a Shapes head, the outline turns into the nearest form.
        head.applyDescribed(HeadDescribe.describe("shapes").parts)
        #expect(head.theme == "shape" && head.form == "square")
    }

    /// Edit Head's theme strip: a Shapes form and an outline carry over as the nearest one in the other theme.
    @MainActor @Test func themesCarryTheShapeOver() {
        var shape = HeadRecord.defaultShapeRecord(profile: "finance")
        shape.form = "star"
        #expect(EditHeadModel.themed(shape, "matrix").form == "octagon")
        shape.form = "pill"
        #expect(EditHeadModel.themed(shape, "matrix").form == "tall")
        var matrix = HeadRecord.defaultMatrixRecord(profile: "ivy")
        matrix.form = "shield"
        let back = EditHeadModel.themed(matrix, "shape")
        #expect(back.form == "square" && back.tile == "none")
        #expect(EditHeadModel.themed(matrix, "robot").form == "square", "a robot keeps a form a Shapes head can wear")
        #expect(EditHeadModel.themed(matrix, "matrix").form == "shield")
    }

    @MainActor @Test func presenceDotFollowsTheHead() {
        #expect(BotAvatar.presenceSize(20) == 8)
        #expect(BotAvatar.presenceSize(50) == 12)
        #expect(BotAvatar.presenceSize(56) == 13)
        #expect(BotAvatar.presenceSize(96) == 16)
    }

    /// The working badge's dots move as the chat's typing dots do: up to full at 0.3 s, back by 0.6 s, rest until 1.2 s.
    @MainActor @Test func workingBadgeDotsWave() {
        #expect(abs(WorkingBadge.wave(0) - 0.3) < 0.001)
        #expect(abs(WorkingBadge.wave(0.3) - 1) < 0.001)
        #expect(abs(WorkingBadge.wave(0.9) - 0.3) < 0.001)
        #expect(abs(WorkingBadge.wave(1.5) - 1) < 0.001, "repeats every 1.2 s")
        #expect(abs(WorkingBadge.wave(-0.9) - 1) < 0.001, "the later dots' times before zero wrap too")
    }

    // MARK: Helpers

    /// The 4-connected pieces of `cells`.
    private func pieces(of cells: Set<MatrixHead.Cell>) -> [Set<MatrixHead.Cell>] {
        var left = cells, found: [Set<MatrixHead.Cell>] = []
        while let start = left.first {
            var piece: Set<MatrixHead.Cell> = [start], queue = [start]
            left.remove(start)
            while let cell = queue.popLast() {
                for next in [MatrixHead.Cell(cell.col + 1, cell.row), MatrixHead.Cell(cell.col - 1, cell.row),
                             MatrixHead.Cell(cell.col, cell.row + 1), MatrixHead.Cell(cell.col, cell.row - 1)] where left.contains(next) {
                    left.remove(next)
                    piece.insert(next)
                    queue.append(next)
                }
            }
            found.append(piece)
        }
        return found
    }

    // MARK: [updates] Small marks

    /// Every head that isn't an update mark draws on the 20-across grid at every size, small ones too (a room's 28 pt
    /// sender faces, group avatars, the waiting face): the coarse grid is the update marks' alone.
    @Test func plainHeadsKeepTheirGridAtEverySize() throws {
        for side: CGFloat in [12, 18, 22, 28, 29.5, 30, 64] {
            #expect(MatrixHead.size(pointSide: side, mark: false) == MatrixHead.grid, "\(side)")
            let grid = MatrixHeadRenderer.grid(side: side * 3, pointSide: side, mark: false)
            #expect(grid.size == 20 && grid.pitch == side * 3 / 20 && grid.inset == 0, "\(side)")
        }
        // The default picture is the plain one, LED for LED and pixel for pixel.
        for silhouette in MatrixDesign.Silhouette.allCases {
            let design = MatrixDesign(silhouette: silhouette, eyes: .slits)
            #expect(MatrixHead.dots(design) == MatrixHead.dots(design, size: MatrixHead.grid))
            for side: CGFloat in [16, 22, 28] {
                for dark in [false, true] {
                    let plain = try #require(MatrixHeadRenderer.makeImage(design, side: side, scale: 3, dark: dark))
                    let unmarked = try #require(MatrixHeadRenderer.makeImage(design, side: side, scale: 3, mark: false, dark: dark))
                    #expect(pixels(plain) == pixels(unmarked), "\(silhouette) \(side) \(dark)")
                }
            }
        }
    }

    /// An update mark under 30 pt is its outline as drawn (15 across), LEDs on whole pixels with both eyes dark; from
    /// 30 pt up it is the 20-across head as ever (review 2026-10-28: at mark sizes the fine grid read as a blur).
    @Test func smallMarksAreTheDrawnGrid() throws {
        #expect(MatrixHead.size(pointSide: 22, mark: true) == MatrixHead.drawn && MatrixHead.size(pointSide: 29.5, mark: true) == MatrixHead.drawn)
        #expect(MatrixHead.size(pointSide: 30, mark: true) == MatrixHead.grid && MatrixHead.size(pointSide: 64, mark: true) == MatrixHead.grid)
        // The LEDs span the whole square, as the 20 across do: no step down in size at 30 pt (review 2026-10-28).
        let small = MatrixHeadRenderer.grid(side: 87, pointSide: 29, mark: true)
        #expect(small.size == 15 && small.pitch == 87.0 / 15 && small.inset == 0)
        let large = MatrixHeadRenderer.grid(side: 90, pointSide: 30, mark: true)
        #expect(large.size == 20 && large.pitch == 4.5 && large.inset == 0)
        for silhouette in MatrixDesign.Silhouette.allCases {
            let design = MatrixDesign(silhouette: silhouette, eyes: .slits)
            let dots = MatrixHead.dots(design, size: MatrixHead.drawn)
            #expect(dots.count == MatrixHead.outline(design).body.joined().filter { $0 }.count, "\(silhouette)")
            // Both slit eyes are there, two LEDs wide and three tall each, so they read at mark sizes.
            #expect(dots.filter { $0.kind == .hole }.count == 12, "\(silhouette)")
            // The mark's picture is that grid, not the plain head's.
            let mark = try #require(MatrixHeadRenderer.makeImage(design, side: 22, scale: 3, mark: true, dark: false))
            let plain = try #require(MatrixHeadRenderer.makeImage(design, side: 22, scale: 3, dark: false))
            #expect(pixels(mark) != pixels(plain), "\(silhouette)")
        }
    }
}

/// The matrix head's pictures, cached like every head's.
@MainActor @Suite struct MatrixHeadCacheTests {
    @Test func framesAreDrawnOnce() {
        let head = Head.defaultMatrixHead(profile: "bike-shop")
        let cache = HeadImageCache.shared
        let rest = cache.matrixFrame(for: head, pose: .rest, side: 44, scale: 2, dark: false)
        #expect(rest === cache.matrixFrame(for: head, pose: .rest, side: 44, scale: 2, dark: false))
        #expect(rest.size == CGSize(width: 44, height: 44) && rest.scale == 2)
        let blink = cache.matrixFrame(for: head, pose: MatrixPose(lids: 2), side: 44, scale: 2, dark: false)
        #expect(blink !== rest)
        #expect(cache.matrixFrame(for: head, pose: .rest, side: 44, scale: 2, dark: true) !== rest)
    }

    /// [updates] An update mark's picture is kept apart from the same head drawn plain at the same size.
    @Test func marksAreCachedApart() {
        let head = Head.defaultMatrixHead(profile: "bike-shop")
        let cache = HeadImageCache.shared
        let plain = cache.matrixFrame(for: head, pose: .rest, side: 22, scale: 2, dark: false)
        let mark = cache.matrixFrame(for: head, pose: .rest, side: 22, scale: 2, dark: false, mark: true)
        #expect(mark !== plain)
        #expect(mark === cache.matrixFrame(for: head, pose: .rest, side: 22, scale: 2, dark: false, mark: true))
        #expect(plain === cache.matrixFrame(for: head, pose: .rest, side: 22, scale: 2, dark: false))
    }

    /// While its bot works (and motion is reduced) the still picture looks up toward the side it faces.
    @Test func thinkingPictureLooksUp() throws {
        let head = Head.defaultMatrixHead(profile: "finance")
        let design = MatrixDesign(head)
        let thinking = try #require(HeadRenderer.picture(head, side: 44, scale: 2, dark: true, state: .thinking))
        let expected = try #require(MatrixHeadRenderer.makeImage(design, pose: .thinking(design), side: 44, scale: 2, dark: true))
        #expect(pixels(thinking) == pixels(expected))
        let idle = try #require(HeadRenderer.picture(head, side: 44, scale: 2, dark: true))
        #expect(pixels(idle) != pixels(thinking))
    }
}

/// The image's pixels as premultiplied RGBA bytes, top row first.
private func pixels(_ image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return bytes
}

/// WCAG relative luminance of an OKLab colour (clipped to sRGB).
private func luminance(_ colour: OKLab) -> Double {
    func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    let c = colour.rgb
    return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
}

private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

#if DEBUG
/// The brief's sample sheet draws on both pages; with `TEST_RUNNER_HQ_HEAD_GALLERY=<folder>` on the test run it is
/// written there as bot-heads-face-shapes-light.png and -dark.png.
@MainActor @Suite struct MatrixHeadGalleryTests {
    @Test func drawsBothPages() throws {
        for dark in [false, true] {
            let image = MatrixHeadGallery.render(dark: dark)
            #expect(image.size.width == MatrixHeadGallery.width && image.size.height > 1000)
            guard let folder = ProcessInfo.processInfo.environment["HQ_HEAD_GALLERY"], !folder.isEmpty else { continue }
            let data = try #require(image.pngData())
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("bot-heads-face-shapes-\(dark ? "dark" : "light").png"))
        }
    }
}
#endif
