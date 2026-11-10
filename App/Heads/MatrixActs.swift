// [moods] How a dot-matrix face acts out what its bot is doing (BotMood): the body and the eyes go as every face's do
// (FaceRoutines), the eyes a LED at a time, and a light effect plays over its LEDs. Only the eyes and the body act
// (owner, 2026-10-28: "i don't want mouths. just the body and eyes moving"). Pure values and pictures, worked out
// here; HeadView plays them with Core Animation (whole pictures swapped, masks moved), so nothing is drawn per frame.
//
// The light effects all work one way: a second picture of the head with every LED at full light (`MatrixHeadRenderer
// .drawLit`) sits over it, and a moving mask (a comet, a sweep, falling streaks) shows it through. Where the mask
// passes, the LEDs flare up, LED by LED, because the picture under it is only dots.

import CoreGraphics
import Foundation

nonisolated struct MatrixAct: Sendable {
    enum Effect: Hashable, Sendable {
        /// Thinking: a comet of light running round the outline.
        case orbit
        /// Searching: a radar sweep from the middle.
        case radar
        /// Reading: a line of light going down the face.
        case scan
        /// Running: code falling down the LEDs, in two speeds.
        case rain
        /// Writing: LEDs lighting one by one along two lines under the eyes, then clearing.
        case typing
        /// Browsing: a pointer moving about, a ripple where it clicks.
        case pointer
        /// Messaging: rings going out to the side the face turns to.
        case waves
        /// Making: LEDs twinkling here and there.
        case sparkle
        /// Replying: the head glowing softly with each nod.
        case pulse
        /// Asking: the face flashing as it lands from each hop.
        case flash
        /// Done: rings and sparkles out from the middle.
        case burst
        /// Failed: the face flickering.
        case flicker
    }

    var mood: BotMood
    var design: MatrixDesign
    /// How the body and the eyes go (FaceRoutines); the eyes step a LED at a time (`pose`).
    var clips: [FaceClip]
    var effect: Effect?
    /// The face kept still under Reduce Motion or Low Power Mode.
    var still: MatrixPose

    /// Played once (done, failed), not over and over.
    var once: Bool { mood.once }

    /// Where the pointer stops while browsing (fractions of the head) and how long each stop lasts.
    static let stops = FaceRoutines.stops
    static let stopLength = FaceRoutines.stopLength

    /// When writing: how long a line takes to type, and the pause before the lines clear.
    static let lineLength = FaceRoutines.lineLength
    static let typingPause = FaceRoutines.typingPause

    /// Failed: the panel glitching as it starts (each band of rows slid, 0.07 s each).
    static let glitches = [1, 2, 0, 3, 0, 4, 1]
    static let glitchLength = 0.07

    static func make(_ mood: BotMood, design: MatrixDesign) -> MatrixAct {
        let effect: Effect = switch mood {
        case .thinking: .orbit
        case .reading: .scan
        case .searching: .radar
        case .running: .rain
        case .writing: .typing
        case .browsing: .pointer
        case .messaging: .waves
        case .making: .sparkle
        case .replying: .pulse
        case .asking: .flash
        case .done: .burst
        case .failed: .flicker
        }
        let still = pose(.rest, FaceRoutines.still(mood, facing: design.facing), design: design)
        return MatrixAct(mood: mood, design: design, clips: FaceRoutines.clips(mood, facing: design.facing), effect: effect, still: still)
    }

    /// The face at a moment of a routine, in whole LEDs: the eyes look (and follow the body as it turns or tips, as on
    /// something round) a LED aside or up; the lids half shut or shut.
    static func pose(_ body: FaceBody, _ eyes: FaceEyes, design: MatrixDesign) -> MatrixPose {
        let x = eyes.x + body.turn / 22, y = eyes.y + body.tip / 30
        let lids = eyes.lids >= 0.75 ? 2 : eyes.lids >= 0.25 ? 1 : 0
        return MatrixPose(gaze: x > 0.35 ? 1 : x < -0.35 ? -1 : 0, lift: y < -0.35 ? -1 : 0, lids: lids)
    }

    /// The faces `loop` goes through, each from when it shows: a new one only where the face changes (failed glitching
    /// first).
    func frames(_ loop: FaceLoop) -> [(at: Double, pose: MatrixPose)] {
        var frames: [(at: Double, pose: MatrixPose)] = []
        if mood == .failed {
            for (index, glitch) in Self.glitches.enumerated() {
                frames.append((Double(index) * Self.glitchLength, MatrixPose(lids: 2, glitch: glitch)))
            }
        }
        let after = frames.isEmpty ? -1 : Double(Self.glitches.count) * Self.glitchLength
        for sample in loop.samples() where sample.at >= after && sample.at < loop.period - 1e-9 {
            let pose = Self.pose(sample.body, sample.eyes, design: design)
            if frames.last?.pose != pose { frames.append((sample.at, pose)) }
        }
        return frames
    }

    /// Every face the act goes through, once each, in any order of its routines.
    var poses: [MatrixPose] {
        var seen = Set<MatrixPose>()
        var all = mood == .failed ? Self.glitches.map { MatrixPose(lids: 2, glitch: $0) } : []
        for clip in clips {
            for t in clip.times(rate: 30) { all.append(Self.pose(clip.body(at: t), clip.eyes(at: t), design: design)) }
        }
        all.append(still)
        return all.filter { seen.insert($0).inserted }
    }

    /// The face LEDs in any of the act's faces: a flare never covers them, wherever the eyes are.
    func faceCells(_ design: MatrixDesign) -> Set<MatrixHead.Cell> {
        var cells = Set<MatrixHead.Cell>()
        for pose in poses + [.rest] { cells.formUnion(MatrixHead.faceLEDs(design, pose: pose).keys) }
        return cells
    }

    /// Whether the flare is the outline's edge only (a light running round it).
    var rimOnly: Bool { effect == .orbit }
}

// MARK: - Pictures

/// What a face needs to play an act: its faces, the lit picture and the effect's masks, drawn on any thread.
nonisolated struct MatrixActPictures: @unchecked Sendable {
    var faces: [MatrixPose: CGImage] = [:]
    /// The head at full light, without its face (the outline's edge only for a light running round it).
    var lit: CGImage?
    /// The effect's own masks: rain's two speeds, sparkle's three sets.
    var masks: [CGImage] = []

    /// Bytes held.
    var cost: Int { ([lit].compactMap { $0 } + masks + Array(faces.values)).reduce(0) { $0 + $1.bytesPerRow * $1.height } }

    final class Box {
        let pictures: MatrixActPictures
        init(_ pictures: MatrixActPictures) { self.pictures = pictures }
    }

    /// `mark`: an update mark's act (`MatrixHead.coarseBelow`).
    static func draw(_ design: MatrixDesign, mood: BotMood, side: CGFloat, scale: CGFloat, mark: Bool = false, dark: Bool) -> MatrixActPictures {
        let act = MatrixAct.make(mood, design: design)
        var pictures = MatrixActPictures()
        for pose in act.poses {
            pictures.faces[pose] = MatrixHeadRenderer.makeImage(design, pose: pose, side: side, scale: scale, mark: mark, dark: dark)
        }
        guard act.effect != nil else { return pictures }
        let skip = act.faceCells(design)
        pictures.lit = MatrixHeadRenderer.makeLitImage(design, side: side, scale: scale, mark: mark, dark: dark, skip: skip, rim: act.rimOnly ? 2 : nil)
        let pixels = side * scale, seed = Int(design.color) &* 31 &+ (MatrixDesign.Silhouette.allCases.firstIndex(of: design.silhouette) ?? 0) &* 7 &+ design.facing
        switch act.effect {
        case .rain:
            pictures.masks = [MatrixActMasks.rain(seed: seed, side: pixels, streaks: 13),
                              MatrixActMasks.rain(seed: seed &+ 7, side: pixels, streaks: 8)].compactMap { $0 }
        case .sparkle, .burst:
            pictures.masks = (0..<3).compactMap { MatrixActMasks.sparkles(design, skip: skip, seed: seed &+ $0 * 31, count: 4, side: pixels) }
        default: break
        }
        return pictures
    }
}

// MARK: - Masks

/// The pictures the effects move about: white where the light is, for masks.
nonisolated enum MatrixActMasks {
    /// A small fixed random sequence, so a head's rain and sparkles are its own and the same every time.
    struct Dice {
        var state: UInt64
        init(_ seed: Int) { state = UInt64(truncatingIfNeeded: seed) &* 0x9E3779B97F4A7C15 &+ 0x2545F4914F6CDD1D }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    }

    /// Two heads' heights of falling streaks, one a column of LEDs wide each: a bright head and a tail fading up. The
    /// second height repeats the first, so moving it down by one height loops without a seam. `side` in pixels.
    static func rain(seed: Int, side: CGFloat, streaks: Int) -> CGImage? {
        let grid = MatrixHead.grid, pitch = side / CGFloat(grid)
        let width = Int(side.rounded(.up)), height = Int((side * 2).rounded(.up))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        var dice = Dice(seed)
        var columns = Array(0..<grid)
        for i in columns.indices.reversed() { columns.swapAt(i, dice.int(0..<(i + 1))) }
        for n in 0..<streaks {
            let col = columns[n % grid]
            let head = dice.int(0..<grid), length = dice.int(3..<8)
            for k in 0..<length {
                let row = ((head - k) % grid + grid) % grid
                let alpha = k == 0 ? 1 : 0.75 * (1 - Double(k) / Double(length))
                ctx.setAlpha(alpha)
                for tile in 0..<2 {
                    ctx.fill(CGRect(x: CGFloat(col) * pitch + pitch * 0.05, y: CGFloat(tile * grid + row) * pitch, width: pitch * 0.9, height: pitch))
                }
            }
        }
        return ctx.makeImage()
    }

    /// `count` LEDs of the head's own (none of the face's), each a soft round light, for a twinkle. `side` in pixels.
    static func sparkles(_ design: MatrixDesign, skip: Set<MatrixHead.Cell>, seed: Int, count: Int, side: CGFloat) -> CGImage? {
        let grid = MatrixHead.grid, pitch = side / CGFloat(grid)
        let body = MatrixHead.leds(design)
        var cells: [MatrixHead.Cell] = []
        for row in 0..<grid { for col in 0..<grid where body[row][col] && !skip.contains(MatrixHead.Cell(col, row)) { cells.append(.init(col, row)) } }
        guard !cells.isEmpty else { return nil }
        let pixels = Int(side.rounded(.up))
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)
        var dice = Dice(seed)
        for _ in 0..<count {
            let cell = cells[dice.int(0..<cells.count)]
            let centre = CGPoint(x: (CGFloat(cell.col) + 0.5) * pitch, y: (CGFloat(cell.row) + 0.5) * pitch)
            // The LED itself, and its four neighbours dimmer: a little star.
            ctx.setAlpha(1)
            ctx.fillEllipse(in: CGRect(x: centre.x - pitch * 0.6, y: centre.y - pitch * 0.6, width: pitch * 1.2, height: pitch * 1.2))
            ctx.setAlpha(0.45)
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let p = CGPoint(x: centre.x + CGFloat(dx) * pitch, y: centre.y + CGFloat(dy) * pitch)
                ctx.fillEllipse(in: CGRect(x: p.x - pitch * 0.5, y: p.y - pitch * 0.5, width: pitch, height: pitch))
            }
        }
        return ctx.makeImage()
    }

    /// The two lines a writing face types along, in the head's LEDs: (row, first column, last column), under the eyes
    /// and clear of the mouth's row, each at least four LEDs long.
    static func typingLines(_ design: MatrixDesign) -> [(row: Int, first: Int, last: Int)] {
        let body = MatrixHead.leds(design)
        let face = MatrixHead.faceLEDs(design, pose: .rest)
        // The eyes are the face's top part, up to four LEDs tall.
        let top = face.filter { $0.value != .blush }.keys.map(\.row).min() ?? MatrixHead.grid / 2
        let eyeBottom = face.keys.filter { $0.row <= top + 3 }.map(\.row).max() ?? top
        var lines: [(Int, Int, Int)] = []
        var row = eyeBottom + 3
        while lines.count < 2, row < MatrixHead.grid - 1 {
            let cols = (0..<MatrixHead.grid).filter { body[row][$0] }
            if let first = cols.first, let last = cols.last, last - first - 2 >= 4 {
                lines.append((row, first + 2, last - 2))
                row += 2
            } else {
                row += 1
            }
        }
        return lines
    }
}
