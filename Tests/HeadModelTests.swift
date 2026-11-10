import CoreGraphics
import Foundation
import UIKit
import Testing
@testable import HermesHQNative

/// Spec 02 §10.3 and §10.4.9: vectors computed by the web app's ref238 renderer. The web's default (a plain Shapes
/// head) is `defaultShapeHead`; the app's own default is a dot-matrix head (MatrixHeadTests).
struct HeadModelTests {
    // MARK: default heads (§10.3)

    @Test(arguments: [
        ("default", UInt32(2470140894), Head.ColorName.wine, Head.Form.round, 322657247),
        ("ivy", 2466054493, .teal, .square, 318570846),
        ("hermes", 3348504771, .butter, .round, 1201021124),
        ("inbox", 3797079355, .pink, .round, 1649595708),
        ("otto", 501755363, .grape, .square, 501755363),
    ])
    func defaultShapeHead(profile: String, hash: UInt32, color: Head.ColorName, form: Head.Form, seed: Int) {
        #expect(Head.nameHash(profile) == hash)
        let head = Head.defaultShapeHead(profile: profile)
        #expect(head.theme == .shape)
        #expect(head.color == color)
        #expect(head.form == form)
        #expect(head.seed == seed)
        #expect(head.look == .slits && head.specs == .none && head.hat == .none && head.mouth == .none)
        #expect(head.tile == .none && !head.blush)
    }

    @Test func defaultHeadKeyIsTrimmedAndLowercased() {
        #expect(Head.defaultShapeHead(profile: "  Ivy ") == Head.defaultShapeHead(profile: "ivy"))
        #expect(Head.defaultShapeHead(profile: "   ") == Head.defaultShapeHead(profile: "default"))
    }

    /// §10.4.10: the owner's heads without a saved record, as the web draws them.
    @Test func ownerDefaults() {
        let finance = Head.defaultShapeHead(profile: "finance")
        #expect(finance.color == .butter && finance.form == .square)
        let maple = Head.defaultShapeHead(profile: "maple-revenue-operator")
        #expect(maple.color == .lime && maple.form == .hex)
        let pool = Head.defaultShapeHead(profile: "bike-shop")
        #expect(pool.color == .lime && pool.form == .pill)
    }

    // MARK: parse (§10.2)

    @Test func parseRejectsNonHeads() {
        #expect(Head.parse(nil) == nil)
        #expect(Head.parse(.string("shape")) == nil)
        #expect(Head.parse(.array([])) == nil)
        #expect(Head.parse(["theme": "nope", "form": "round"]) == nil)
    }

    @Test func parseFallsBackFieldByField() throws {
        let head = try #require(Head.parse(["theme": "shape", "v": 6, "color": "chartreuse", "form": "zigzag", "seed": 2.5]))
        #expect(head.color == .mint && head.form == .round && head.seed == 1)
        #expect(head.tile == .dark)     // a v6 record without a tile reads as dark, as the web does
        let clamped = try #require(Head.parse(["theme": "shape", "v": 6, "seed": 1e12]))
        #expect(clamped.seed == 2147483647)
        // An old robot record (shape/face only) is a head, but not a Shapes head: it draws as the robot it names.
        let robot = try #require(Head.parse(["shape": "dome", "face": "visor"]))
        #expect(robot.theme == .robot)
        let old = Head.resolve(["shape": "dome"], profile: "ivy")
        #expect(old.theme == .robot && old.themed?.shape == "dome")
    }

    /// §10.4.10: the primary profile's stored v4 head drops its mouth and board.
    @Test func legacyShapeFixUps() throws {
        let stored: JSONValue = ["v": 4, "theme": "shape", "color": "ink", "form": "round", "look": "ovals",
                                 "mouth": "open", "blush": true, "tile": "color", "seed": 7]
        let head = try #require(Head.parse(stored))
        #expect(head.mouth == .none && !head.blush && head.tile == .none)
        #expect(head.look == .ovals && head.color == .ink)
        let v5 = try #require(Head.parse(["v": 5, "theme": "shape", "mouth": "smile", "tile": "light"]))
        #expect(v5.mouth == .smile && v5.tile == .none)
        let v6 = try #require(Head.parse(["v": "6", "theme": "shape", "tile": "light"]))
        #expect(v6.tile == .light)
    }

    // MARK: geometry (§10.4.9)

    private func shape(_ form: Head.Form, color: Head.ColorName = .grass, seed: Int = 416723) -> Head {
        var head = Head(); head.theme = .shape; head.form = form; head.color = color; head.seed = seed
        head.tile = .none
        return head
    }

    private func slit(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ rx: Double, rotate a: Double, _ cx: Double, _ cy: Double) -> HeadMark {
        HeadMark(primitive: .rect(x: x, y: y, width: w, height: h, rx: rx), transform: [.rotate(a, cx: cx, cy: cy)],
                 style: .filled(HeadRGB(0xFFFFFF)))
    }

    @Test(arguments: [
        (Head.Form.round, 1.64, -327.7, -327.7, [515, 359, 54, 114, 27, 542, 416], 635.0, 662.0),
        (.blob, 1.528, -257.8, -270.2, [515, 359, 54, 114, 27, 542, 416], 635, 662),
        (.square, 1.763, -390.9, -390.9, [515, 359, 54, 114, 27, 542, 416], 635, 662),
        (.pill, 1.519, -265.5, -265.5, [514.8, 376.3, 49.7, 104.9, 24.8, 539.6, 428.7], 625.2, 650),
        (.triangle, 2.001, -512.5, -546.4, [514.6, 480.8, 46.4, 98, 23.2, 537.8, 529.8], 617.8, 641),
        (.hex, 1.749, -383.7, -383.7, [515, 365, 54, 114, 27, 542, 422], 635, 662),
        (.cloud, 1.502, -244, -240.4, [508.8, 412.3, 49.7, 104.9, 24.8, 533.6, 464.7], 619.2, 644),
        (.drop, 1.547, -280.2, -243, [514.7, 487.1, 48.6, 102.6, 24.3, 539, 538.4], 622.7, 647),
        (.star, 1.692, -354.4, -347.1, [514.3, 438, 42.1, 88.9, 21.1, 535.4, 482.5], 607.9, 629),
        (.heart, 1.608, -311.2, -329.9, [502.7, 409.1, 48.6, 102.6, 24.3, 527, 460.4], 610.7, 635),
    ])
    func formVectors(form: Head.Form, k: Double, tx: Double, ty: Double, eye: [Double], rightX: Double, rightCx: Double) {
        let layout = HeadGeometry.layout(shape(form), compact: true, darkPage: false)
        #expect(layout.placement == HeadPlacement(k: k, tx: tx, ty: ty))
        #expect(layout.face.count == 2)
        #expect(layout.face.first == slit(eye[0], eye[1], eye[2], eye[3], eye[4], rotate: -20, eye[5], eye[6]))
        #expect(layout.face.last == slit(rightX, eye[1], eye[2], eye[3], eye[4], rotate: -20, rightCx, eye[6]))
    }

    @Test func roundOutlinePath() {
        let layout = HeadGeometry.layout(shape(.round), compact: true, darkPage: false)
        #expect(layout.outlinePath.hasPrefix("M512 212C528 212 543 213 559 216C574 218"))
    }

    @Test func nonCompactSlitsAndStates() {
        let big = HeadGeometry.layout(shape(.round), compact: false, darkPage: false)
        #expect(big.face.first == slit(519.5, 359, 45, 114, 22.5, rotate: -20, 542, 416))
        #expect(big.face.last == slit(639.5, 359, 45, 114, 22.5, rotate: -20, 662, 416))
        let thinking = HeadGeometry.layout(shape(.round), state: .thinking, compact: true, darkPage: false)
        #expect(thinking.face.first == slit(425, 457, 54, 98, 27, rotate: 0, 452, 506))
        #expect(thinking.face.last == slit(545, 457, 54, 98, 27, rotate: 0, 572, 506))
        let done = HeadGeometry.layout(shape(.round), state: .done, compact: true, darkPage: false)
        #expect(done.face.first == slit(425, 419, 54, 114, 27, rotate: 24, 452, 476))
        #expect(done.face.last == slit(545, 419, 54, 114, 27, rotate: -24, 572, 476))
        let offline = HeadGeometry.layout(shape(.round), state: .offline, compact: true, darkPage: false)
        #expect(offline.face.first == slit(425, 488, 54, 84, 27, rotate: 90, 452, 530))
    }

    @Test func looks() throws {
        var head = shape(.round)
        head.look = .dots
        var layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(layout.face.map(\.primitive) == [.circle(cx: 542, cy: 416, r: 39.6), .circle(cx: 662, cy: 416, r: 39.6)])
        #expect(HeadGeometry.layout(head, compact: false, darkPage: false).face.first?.primitive == .circle(cx: 542, cy: 416, r: 33))

        head.look = .ovals
        layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(layout.face.first?.primitive == .ellipse(cx: 542, cy: 416, rx: 39.6, ry: 57))
        #expect(layout.face.first?.transform == [.rotate(-10, cx: 542, cy: 416)])
        #expect(HeadGeometry.layout(head, compact: false, darkPage: false).face.first?.primitive == .ellipse(cx: 542, cy: 416, rx: 33, ry: 57))

        head.look = .googly
        layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        let ring = try #require(layout.face.first)
        #expect(ring.transform == [.translate(530, 416), .scale(1)])
        #expect(ring.primitive == .circle(cx: 0, cy: 0, r: 51) && abs(ring.style.strokeWidth - 10.8) < 1e-9)
        #expect(layout.face[1].primitive == .circle(cx: 18, cy: -16.8, r: 30.6))
        #expect(layout.face[2].transform == [.translate(674, 416), .scale(1)])

        for look in [Head.Look.happy, .sleepy, .hearts] {
            head.look = look
            layout = HeadGeometry.layout(head, compact: true, darkPage: false)
            #expect(layout.face.first?.transform == [.translate(542, 416), .scale(1.2)])
            #expect(layout.face.last?.transform == [.translate(662, 416), .scale(1.2)])
        }
        head.look = .stars
        layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(layout.face.first?.transform == [.translate(542, 416), .scale(1.2), .rotate(-10, cx: 0, cy: 0)])
    }

    @Test func glassesMouthAndBlush() throws {
        var head = shape(.round)
        head.specs = .shades
        var layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(Set(layout.face.map(\.transform)) == [[.translate(602, 416), .scale(1)]])
        #expect(layout.face.count == 3)       // lenses, glints, bridge: no separate eyes

        head.specs = .round
        layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(layout.under.allSatisfy { $0.transform == [.translate(602, 416), .scale(1)] })
        #expect(layout.face.first == slit(497, 359, 54, 114, 27, rotate: -20, 524, 416))
        #expect(layout.face.last == slit(653, 359, 54, 114, 27, rotate: -20, 680, 416))

        head.specs = .none
        head.mouth = .smile
        layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        let mouth = try #require(layout.under.first)
        #expect(mouth.transform == [.translate(602, 512), .scale(1)])
        #expect(mouth.style.strokeWidth == 23.4)

        head.mouth = .none
        head.blush = true
        layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(layout.under.map(\.primitive) == [.ellipse(cx: -102, cy: 66, rx: 30, ry: 18), .ellipse(cx: 102, cy: 66, rx: 30, ry: 18)])
    }

    /// Hats are never drawn, but their placement maths is the web's (test vectors only).
    @Test(arguments: [
        (Head.Hat.crown, 1.235, -120.1, 1.5), (.halo, 1.305, -156.2, -55.7), (.sprout, 1.265, -135.6, -23),
        (.party, 1.085, -43.5, 123.1), (.bow, 1.482, -246.7, -199.3), (.beanie, 1.337, -172.5, -81.6),
    ])
    func hatPlacement(hat: Head.Hat, k: Double, tx: Double, ty: Double) {
        var head = shape(.round)
        head.hat = hat
        let points = HeadGeometry.form(.round, seed: head.seed).outline
        #expect(HeadGeometry.placement(head, points: points, withHat: true) == HeadPlacement(k: k, tx: tx, ty: ty))
        // Drawn heads ignore the hat entirely.
        #expect(HeadGeometry.layout(head, compact: true, darkPage: false).placement == HeadPlacement(k: 1.64, tx: -327.7, ty: -327.7))
        head.tile = .dark
        #expect(HeadGeometry.placement(head, points: points, withHat: true) == HeadPlacement(k: 0.8, tx: 102.4, ty: 160))
    }

    @Test func hatSeats() {
        var head = shape(.round)
        head.hat = .bow
        let points = HeadGeometry.form(.round, seed: 1).outline
        let bow = HeadGeometry.hatSeat(head, points: points)
        #expect(HeadGeometry.n1(bow.x) == 547.2 && bow.y == 212)
        head.hat = .beanie
        #expect(HeadGeometry.hatSeat(head, points: points).stretch == 1.19)
    }

    @Test func fillsAndEyes() {
        var head = shape(.round, color: .paper)
        var layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(layout.fill == HeadRGB(0xEFE9DB) && layout.rim == HeadRGB(0xB8AD95) && layout.eyeColor == HeadRGB(0x1A1A1A))
        head.tile = .light
        #expect(HeadGeometry.layout(head, compact: true, darkPage: false).fill == HeadRGB(0xD9D0BD))
        head.tile = .color
        #expect(HeadGeometry.layout(head, compact: true, darkPage: false).fill == HeadRGB(0xFFFDF8))

        head = shape(.round, color: .ink)
        layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(layout.fill == HeadRGB(0x0A0A0A) && layout.eyeColor == HeadRGB(0xFFFFFF) && layout.rim == nil)
        layout = HeadGeometry.layout(head, compact: true, darkPage: true)
        #expect(layout.fill == HeadRGB(0xF4F4F2) && layout.eyeColor == HeadRGB(0x1A1A1A))
        layout = HeadGeometry.layout(head, compact: true, darkPage: nil)
        #expect(layout.fill == HeadRGB(0x0A0A0A) && layout.rim == HeadRGB(0x636366))
        head.tile = .dark
        layout = HeadGeometry.layout(head, compact: true, darkPage: false)
        #expect(layout.fill == HeadRGB(0xF4F4F2) && layout.eyeColor == HeadRGB(0x1A1A1A))
        #expect(layout.board?.frame == HeadRGB(0x000000) && layout.board?.panel == HeadRGB(0x1C1C1E))

        head = shape(.round, color: .grass)
        head.tile = .dark
        #expect(HeadGeometry.layout(head, compact: true, darkPage: true).eyeColor == HeadRGB(0x1A1A1A))
        head.tile = .none
        #expect(HeadGeometry.layout(head, compact: true, darkPage: false).fill == HeadRGB(0x2DBE60))
        #expect(HeadGeometry.layout(head, compact: true, darkPage: false).eyeColor == HeadRGB(0xFFFFFF))
        #expect(HeadGeometry.layout(head, compact: true, darkPage: true).eyeColor == HeadRGB(0x1A1A1A))
    }

    /// §10.4.10: book-club (lilac cloud, ovals) and inbox (sky blob, ovals).
    @Test func ownerHeads() throws {
        let dance = try #require(Head.parse(["v": 6, "theme": "shape", "color": "lilac", "form": "cloud", "look": "ovals", "tile": "none"]))
        let layout = HeadGeometry.layout(dance, compact: true, darkPage: false)
        #expect(layout.placement == HeadPlacement(k: 1.502, tx: -244, ty: -240.4))
        #expect(layout.face.map(\.primitive) == [.ellipse(cx: 533.6, cy: 464.7, rx: 36.4, ry: 52.4),
                                                .ellipse(cx: 644, cy: 464.7, rx: 36.4, ry: 52.4)])
        let inbox = try #require(Head.parse(["v": 6, "theme": "shape", "color": "sky", "form": "blob", "look": "ovals",
                                             "seed": 416723, "tile": "none"]))
        #expect(HeadGeometry.layout(inbox, compact: true, darkPage: false).placement == HeadPlacement(k: 1.528, tx: -257.8, ty: -270.2))
    }

    @Test func starAndHeartMarkup() {
        #expect(HeadGeometry.star == "M0 -54L14.1 -19.4L51.4 -16.7L22.8 7.4L31.7 43.7L0 24L-31.7 43.7L-22.8 7.4L-51.4 -16.7L-14.1 -19.4Z")
        #expect(HeadGeometry.heart == "M0 -12.9L0.6 -16.1L4.2 -23.7L12.4 -31.5L24.4 -35L37.3 -31.8L47.3 -22.6L51 -9.8L47.3 3.8L37.3 16.5L24.4 28.2L12.4 38.8L4.2 48.1L0.6 54.8L0 57.2L-0.6 54.8L-4.2 48.1L-12.4 38.8L-24.4 28.2L-37.3 16.5L-47.3 3.8L-51 -9.7L-47.3 -22.6L-37.3 -31.8L-24.4 -35L-12.4 -31.5L-4.2 -23.7L-0.6 -16.1Z")
    }

    @Test func cacheKeyIgnoresSeedUnlessBlob() {
        var a = shape(.round, seed: 1), b = shape(.round, seed: 2)
        #expect(a.cacheKey == b.cacheKey)
        a.form = .blob; b.form = .blob
        #expect(a.cacheKey != b.cacheKey)
    }

    // MARK: SVG path data

    @Test func svgPathReader() {
        let sleepy = SVGPathData.path("M-42-9A42 33 0 0 0 42-9Z").boundingBoxOfPath
        #expect(abs(sleepy.minX + 42) < 0.01 && abs(sleepy.maxX - 42) < 0.01)
        #expect(abs(sleepy.minY + 9) < 0.01 && abs(sleepy.maxY - 24) < 0.01)   // the bowl hangs below its rim
        let frame = SVGPathData.path(HeadGeometry.frame).boundingBoxOfPath
        #expect(abs(frame.minX) < 0.5 && abs(frame.maxX - 1024) < 0.5 && abs(frame.maxY - 1024) < 0.5)
        let relative = SVGPathData.path("M10 10h20v5l-5 5z").boundingBoxOfPath
        #expect(relative == CGRect(x: 10, y: 10, width: 20, height: 10))
        let monocle = SVGPathData.path("M123 48q42 78 6 144").currentPoint
        #expect(monocle == CGPoint(x: 129, y: 192))
    }

    /// The grass round default (§10.4.9 round row) drawn at 56 pt × 3: fill in the middle, clear corners, white slit
    /// eyes where the vectors put them — and not where a flipped or unplaced picture would.
    @Test func rendersAPicture() throws {
        var grassRound = Head.defaultShapeHead(profile: "ivy")
        grassRound.color = .grass; grassRound.form = .round
        let layout = HeadGeometry.layout(grassRound, compact: true, darkPage: false)
        let image = try #require(HeadRenderer.makeImage(layout, side: 56, scale: 3))
        #expect(image.width == 168 && image.height == 168)
        let pixels = try #require(Pixels(image))
        // Eye centres (542, 416) / (662, 416) through the matrix `1.64 0 0 1.64 -327.7 -327.7`, then × 168/1024.
        func px(_ v: Double) -> Int { Int(((1.64 * v - 327.7) * 168 / 1024).rounded()) }
        let (left, right, eyeY) = (px(542), px(662), px(416))
        #expect(left == 92 && right == 124 && eyeY == 58)
        #expect(pixels.isNear(84, 84, red: 0x2D, green: 0xBE, blue: 0x60))      // the fill, #2DBE60
        #expect(pixels.alpha(0, 0) == 0 && pixels.alpha(167, 167) == 0 && pixels.alpha(167, 0) == 0)
        #expect(pixels.isNear(left, eyeY, red: 255, green: 255, blue: 255))
        #expect(pixels.isNear(right, eyeY, red: 255, green: 255, blue: 255))
        // Upside down the eyes would sit low; mirrored, the left eye would sit left of the middle.
        #expect(pixels.isNear(left, 167 - eyeY, red: 0x2D, green: 0xBE, blue: 0x60))
        #expect(pixels.isNear(167 - left, eyeY, red: 0x2D, green: 0xBE, blue: 0x60))
        // The eyes alone: nothing but the eyes.
        let faceImage = try #require(HeadRenderer.makeImage(layout, side: 56, scale: 3, parts: .face))
        let face = try #require(Pixels(faceImage))
        #expect(face.alpha(84, 84) == 0 && face.isNear(left, eyeY, red: 255, green: 255, blue: 255))
    }

    /// On a dark page the same head's eyes are #1A1A1A.
    @Test func darkPageEyes() throws {
        let layout = HeadGeometry.layout(Head.defaultShapeHead(profile: "ivy"), compact: true, darkPage: true)
        let image = try #require(HeadRenderer.makeImage(layout, side: 56, scale: 3))
        let pixels = try #require(Pixels(image))
        #expect(pixels.isNear(92, 58, red: 0x1A, green: 0x1A, blue: 0x1A))
    }
}

/// An sRGB RGBA8 copy of a picture, row 0 at the top.
private struct Pixels {
    let width: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        bytes = data
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

    /// Opaque and within a few levels of the colour.
    func isNear(_ x: Int, _ y: Int, red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let i = (y * width + x) * 4
        func close(_ a: UInt8, _ b: UInt8) -> Bool { abs(Int(a) - Int(b)) <= 3 }
        return bytes[i + 3] == 255 && close(bytes[i], red) && close(bytes[i + 1], green) && close(bytes[i + 2], blue)
    }
}

/// Heads move only when allowed, and a setting change from any queue is safe.
struct HeadMotionTests {
    /// iOS posts `NSProcessInfoPowerStateDidChange` (Low Power Mode on or off) on a background queue. A main-actor
    /// selector observer trapped there; the shared block observer hops to main.
    @Test func powerStateChangeFromABackgroundQueue() async {
        let views = (0..<3).map { _ in HeadView(side: 56) }
        views[0].configure(head: Head.defaultHead(profile: "inbox"), working: true)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
                done.resume()
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        #expect(HeadMotionSettings.shared.isStill
                == (UIAccessibility.isReduceMotionEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled))
        #expect(views.allSatisfy { $0.working == ($0 === views[0]) })
    }
}
