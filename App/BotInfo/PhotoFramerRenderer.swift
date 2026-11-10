// [photoheads] What Move and Scale stores (docs/spec/3x-photoheads.md §7.5): the framed photo as a 256 × 256 PNG, and
// the blurred copy of the photo that fills the gaps when the photo is zoomed out past filling the frame (the web's
// `renderFramedPhoto`, `src/ui-bots/photo-framer.tsx:15-30`). Pure and `nonisolated`: call it off the main thread.
//
// DECISION (spec D13): the stored picture is fully opaque. The blur's input is edge-clamped and the bitmap has no alpha
// channel, so a see-through photo lands on black (the framer's own stage colour: what was framed is what is stored).

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PhotoFramerRenderer {
    /// The stored picture's side in pixels (`PHOTO_EDGE`): never 288 (a head's desktop copy) or 160 (desktop's face).
    static let edge = BotPicture.uploadSide
    /// The backdrop is the photo at "fill" size grown by this much, blurred by `blurShare` of the frame side.
    static let backdropGrowth = 1.15
    static let blurShare = 0.05

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The blurred copy that shows in the gaps, `side` pixels square and opaque.
    static func backdrop(photo: CGImage, side: Int = edge) -> CGImage? {
        guard side > 0, let context = bitmap(side) else { return nil }
        let size = CGSize(width: photo.width, height: photo.height)
        let fill = PhotoFrame.start.rect(size, edge: Double(side))
        let grown = fill.insetBy(dx: -fill.width * (backdropGrowth - 1) / 2, dy: -fill.height * (backdropGrowth - 1) / 2)
        context.interpolationQuality = .medium
        context.draw(photo, in: flipped(grown, side: side))
        guard let sharp = context.makeImage() else { return nil }
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let blurred = CIImage(cgImage: sharp).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(side) * blurShare])
            .cropped(to: extent)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let soft = ciContext.createCGImage(blurred, from: extent, format: .RGBA8, colorSpace: space) else { return sharp }
        // Through the opaque bitmap once more, so the backdrop itself carries no alpha channel either.
        guard let flat = bitmap(side) else { return soft }
        flat.draw(soft, in: extent)
        return flat.makeImage() ?? soft
    }

    /// The framed picture: `edge` pixels square, 8-bit sRGB, no alpha.
    static func image(photo: CGImage, view: PhotoFrame, backdrop ready: CGImage? = nil, side: Int = edge) -> CGImage? {
        guard side > 0, photo.width > 0, photo.height > 0, let context = bitmap(side) else { return nil }
        let size = CGSize(width: photo.width, height: photo.height)
        let placed = view.clamped(size)
        if placed.leavesGaps(size), let fill = ready ?? backdrop(photo: photo, side: side) {
            context.draw(fill, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        context.interpolationQuality = .high
        context.draw(photo, in: flipped(placed.rect(size, edge: Double(side)), side: side))
        return context.makeImage()
    }

    /// §7.5: the PNG that is uploaded. nil only when the system refuses a bitmap (out of memory).
    static func png(photo: CGImage, view: PhotoFrame, backdrop: CGImage? = nil) -> Data? {
        guard let framed = image(photo: photo, view: view, backdrop: backdrop) else { return nil }
        return png(framed)
    }

    static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    static func dataURL(png: Data) -> String { "data:image/png;base64," + png.base64EncodedString() }

    /// An opaque 8-bit sRGB bitmap, black to start with.
    private static func bitmap(_ side: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context
    }

    /// `PhotoFrame.rect` counts y from the top; a bitmap context counts it from the bottom.
    private static func flipped(_ rect: CGRect, side: Int) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(side) - rect.maxY, width: rect.width, height: rect.height)
    }
}
