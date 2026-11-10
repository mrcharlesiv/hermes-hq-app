// [app-icons] The alternate app icons that are the app's own faces (AppIconChoice.Art): drawn here at 1024 by the
// same code that draws the heads in the app, so an icon is exactly the face the app shows. Each comes in the three
// looks a Home Screen asks for: light, dark, and tinted (grey on black: iOS colours it). The face sits in Apple's
// icon grid, centred, inside the middle circle (`faceSide`), on the app's own grounds: the light page's warm white and
// the dark tile's soft black. Pure drawing code, any thread.

import CoreGraphics
import Foundation

nonisolated enum AppIconArt {
    enum Variant: String, CaseIterable, Sendable {
        case light, dark, tinted
        /// The file name's ending in the icon set ("AppIcon-Shapes-Dark.png").
        var suffix: String {
            switch self {
            case .light: ""
            case .dark: "-Dark"
            case .tinted: "-Tinted"
            }
        }
    }

    static let side: CGFloat = 1024
    /// How wide a round face is on the icon: the grid's middle circle (about 62 % of the side).
    static let faceSide: CGFloat = 636

    /// Hermes's own colour: the one its dot-matrix head (`Head.defaultMatrixHead("default")`) wears, so the icons stay
    /// as they were when the bots' default became Shapes.
    static var hermesColour: Head.ColorName { Head.defaultMatrixHead(profile: "default").color }

    /// The icon, `pixels` square, opaque.
    static func image(_ art: AppIconChoice.Art, variant: Variant, pixels: Int = 1024) -> CGImage? {
        guard art != .picture,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: CGFloat(pixels) / side, y: -CGFloat(pixels) / side)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        draw(art, variant: variant, in: ctx)
        guard let made = ctx.makeImage() else { return nil }
        // The robot is ink on paper; its tinted look is the light one turned to grey and inverted (a light figure on
        // black, its highlights dark lines), which keeps every line of the drawing.
        return art == .robot && variant == .tinted ? inverted(made) : made
    }

    /// Draws the icon into `ctx`, which is 1024 square, y down.
    static func draw(_ art: AppIconChoice.Art, variant: Variant, in ctx: CGContext) {
        switch art {
        case .picture: return
        case .shapes:
            ground(variant, in: ctx)
            shapes(variant, in: ctx)
        case .matrix:
            ground(variant, in: ctx)
            matrix(variant, in: ctx)
        case .robot:
            robot(variant == .dark, in: ctx)
        }
    }

    // MARK: Grounds

    /// Light: the app's light page, warm white with the faintest fall of light. Dark: the app's dark head tile (a soft
    /// black lit from the top). Tinted: black, as iOS wants.
    static func ground(_ variant: Variant, in ctx: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        func rgb(_ hex: UInt32) -> CGColor { HeadRenderer.color(HeadRGB(hex)) }
        switch variant {
        case .tinted:
            ctx.setFillColor(rgb(0x000000))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        case .light:
            if let gradient = CGGradient(colorsSpace: space, colors: [rgb(0xFCFBF8), rgb(0xF7F5F0), rgb(0xEDEAE3)] as CFArray,
                                         locations: [0, 0.45, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: side), options: [])
            }
        case .dark:
            ctx.setFillColor(rgb(0x08080A))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            // ThemeHeadSVG's dark tile: a radial from the top middle (cx .5, cy .12, r 1).
            if let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x2B2B33), rgb(0x121216), rgb(0x08080A)] as CFArray,
                                         locations: [0, 0.6, 1]) {
                let centre = CGPoint(x: side / 2, y: side * 0.12)
                ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: side,
                                       options: [.drawsAfterEndLocation])
            }
        }
    }

    // MARK: The faces

    /// The plain Shapes head: a round head in Hermes's colour with two slit eyes, white on the light icon and dark on
    /// the dark one, as on the app's pages. Tinted: a white head with its eyes cut to black.
    static func shapes(_ variant: Variant, in ctx: CGContext) {
        var head = Head()
        head.theme = .shape
        head.form = .round
        head.color = hermesColour
        head.tile = .none
        head.look = .slits
        // Straight on: the pose with the eyes upright in the middle of the face (at rest a head looks off to one side,
        // which on an icon reads as turned away).
        var layout = HeadGeometry.layout(head, state: .thinking, compact: false, darkPage: variant != .light)
        if variant == .tinted {
            layout.fill = HeadRGB(0xF4F4F4)
            layout.face = layout.face.map { mark in
                var mark = mark
                mark.style.fill = HeadRGB(0x000000)
                return mark
            }
        }
        // The outline's own box (as placed) grown to the grid's circle and centred: the eyes keep their place on it.
        var box = HeadRenderer.outlinePath(layout.outline).boundingBoxOfPath
        if let p = layout.placement {
            box = box.applying(CGAffineTransform(a: p.k, b: 0, c: 0, d: p.k, tx: p.tx, ty: p.ty))
        }
        let k = faceSide / max(box.width, box.height)
        ctx.saveGState()
        ctx.translateBy(x: side / 2, y: side / 2)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -box.midX, y: -box.midY)
        HeadRenderer.draw(layout, in: ctx, side: side)
        ctx.restoreGState()
    }

    /// The dot-matrix head Hermes wears by default, as the app draws it small (its drawn grid, 15 LEDs across, with
    /// eyes two LEDs wide: at icon sizes one LED is a hairline), looking straight out: coloured LEDs with dark eyes on
    /// the light icon, lit ones glowing on the dark, white LEDs on black when tinted.
    static func matrix(_ variant: Variant, in ctx: CGContext) {
        var design = MatrixDesign(Head.defaultMatrixHead(profile: "default"))
        if variant == .tinted { design.mono = true }
        let size = MatrixHead.drawn
        // The outline's own box decides the square, so a narrow outline is as tall as a round one is wide.
        let box = MatrixHead.box(MatrixHead.leds(design, size: size))
        let outline = MatrixHead.outline(design)
        // Eyes moved whole LEDs to the middle of the head (a head keeps them a column toward the way it faces).
        let gaze = Int((box.cx - (Double(outline.left + outline.right) / 2 + 0.5)).rounded())
        let cells = CGFloat(max(box.hw, box.hh) * 2)
        let square = faceSide * CGFloat(size) / cells
        // Centre the LEDs (not the square): an outline that leans one way sits in the middle all the same.
        let pitch = square / CGFloat(size)
        let x = side / 2 - CGFloat(box.cx) * pitch, y = side / 2 - CGFloat(box.cy) * pitch
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        MatrixHeadRenderer.draw(design, pose: MatrixPose(gaze: gaze), in: ctx, side: square, pointSide: MatrixHead.coarseBelow - 1,
                                mark: true, dark: variant != .light)
        ctx.restoreGState()
    }

    /// The original robot (the web app's first icon, `HeadRecord.icon`) as the app draws it, eyes only, its frame left
    /// off (the icon's own edge is the frame now): the bust centred in the icon grid with even margins, on its own
    /// paper. `dark`: on the dark tile, lit from behind and rimmed in light so the black shell doesn't sink into it.
    static func robot(_ dark: Bool, in ctx: CGContext) {
        ground(dark ? .dark : .light, in: ctx)
        guard let figure = robotFigure, let crop = figure.cropping(to: robotBox) else { return }
        let k = robotSpan / max(robotBox.width, robotBox.height)
        let w = robotBox.width * k, h = robotBox.height * k
        let dest = CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
        func place(_ draw: () -> Void) {
            ctx.saveGState()
            ctx.translateBy(x: dest.minX, y: dest.maxY)
            ctx.scaleBy(x: 1, y: -1)
            draw()
            ctx.restoreGState()
        }
        let frame = CGRect(origin: .zero, size: dest.size)
        if dark {
            // Light from behind (a soft pool under the head), then a fine rim round the figure.
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            if let pool = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.42, green: 0.45, blue: 0.5, alpha: 0.42),
                                                               CGColor(srgbRed: 0.42, green: 0.45, blue: 0.5, alpha: 0)] as CFArray,
                                     locations: [0, 1]) {
                let centre = CGPoint(x: side / 2, y: dest.minY + h * 0.42)
                ctx.drawRadialGradient(pool, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: side * 0.42, options: [])
            }
            place {
                ctx.setShadow(offset: .zero, blur: 7, color: CGColor(srgbRed: 0.8, green: 0.84, blue: 0.9, alpha: 0.75))
                ctx.draw(crop, in: frame)
            }
        }
        place { ctx.draw(crop, in: frame) }
    }

    /// How big the bust is drawn: its longer side, inside the grid's outer circle with even margins.
    static let robotSpan: CGFloat = 760

    /// The robot alone on a clear 1024 square, as the web drew it inside its frame, and the box round what it covers.
    static let robotFigure: CGImage? = {
        guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: 1024)
        ctx.scaleBy(x: 1, y: -1)
        let record = HeadRecord.icon.plain
        let body = ThemeHeadSVG.robotMarkup(record, ThemeHeadSVG.tone(record.color), state: nil, id: "ai")
        guard let root = SVGMini.parse("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\">\(body)</svg>")
        else { return nil }
        SVGMini.draw(root, in: ctx, side: 1024, pixels: CGSize(width: 1024, height: 1024))
        return ctx.makeImage()
    }()

    static let robotBox: CGRect = {
        guard let image = robotFigure, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return CGRect(x: 0, y: 0, width: 1024, height: 1024)
        }
        var minX = image.width, maxX = -1, minY = image.height, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return CGRect(x: 0, y: 0, width: 1024, height: 1024) }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }()

    // MARK: Tinted from light

    /// `image` turned to grey and inverted, its darkest 4 % pulled to black (a tinted icon's ground must be black).
    static func inverted(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0..<(w * h) {
            let v = 255 - Double(pixels[i])
            pixels[i] = UInt8(max(0, min(255, (v - 10) * 255 / 245)).rounded())
        }
        guard let grey = ctx.makeImage(),
              let rgb = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        rgb.draw(grey, in: CGRect(x: 0, y: 0, width: w, height: h))
        return rgb.makeImage()
    }
}
