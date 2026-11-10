// Makes the attachments stream's test media (docs/spec/1x-attachments.md §15.2): a 4032×3024 HEIC taken "on a phone"
// (orientation 6, GPS, camera make/model, capture date), an opaque PNG, a PNG with real transparency, a 3-frame GIF and
// a small PDF. Invented content. Usage: swift scripts/fixtures/make-attachment-media.swift <output dir>
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "UITests/Fixtures/attachments")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func image(_ w: Int, _ h: Int, alpha: Bool = false, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

func write(_ name: String, type: UTType, images: [CGImage], properties: [CFString: Any]? = nil, frameProps: [CFString: Any]? = nil) {
    let url = out.appending(path: name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)!
    if let properties { CGImageDestinationSetProperties(dest, properties as CFDictionary) }
    for i in images { CGImageDestinationAddImage(dest, i, frameProps as CFDictionary?) }
    precondition(CGImageDestinationFinalize(dest), "couldn't write \(name)")
    print("wrote \(url.path)")
}

// A phone photo: sky over grass, a sun; stored landscape with orientation 6 (shown portrait).
let photo = image(4032, 3024) { c in
    c.setFillColor(CGColor(red: 0.45, green: 0.7, blue: 0.95, alpha: 1)); c.fill(CGRect(x: 0, y: 1200, width: 4032, height: 1824))
    c.setFillColor(CGColor(red: 0.3, green: 0.65, blue: 0.3, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 4032, height: 1200))
    c.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)); c.fillEllipse(in: CGRect(x: 2900, y: 2000, width: 600, height: 600))
}
let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                            kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W", kCGImagePropertyGPSAltitude: 12.0]
let props: [CFString: Any] = [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: gps,
                              kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture", kCGImagePropertyTIFFModel: "Phone 1"],
                              kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:10 09:00:00"],
                              kCGImageDestinationLossyCompressionQuality: 0.6]
write("photo-gps.heic", type: .heic, images: [photo], frameProps: props)
write("photo-gps.jpg", type: .jpeg, images: [photo], frameProps: props)

let chart = image(800, 600) { c in
    for i in 0..<8 {
        c.setFillColor(CGColor(red: CGFloat(i) / 8, green: 0.3, blue: 1 - CGFloat(i) / 8, alpha: 1))
        c.fill(CGRect(x: 40 + i * 92, y: 40, width: 70, height: 60 + i * 60))
    }
}
write("chart.png", type: .png, images: [chart])

let clear = image(256, 256, alpha: true) { c in
    c.clear(CGRect(x: 0, y: 0, width: 256, height: 256))
    c.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1)); c.fillEllipse(in: CGRect(x: 28, y: 28, width: 200, height: 200))
}
write("badge.png", type: .png, images: [clear])

let frames = (0..<3).map { k in image(120, 120) { c in
    c.setFillColor(CGColor(red: k == 0 ? 1 : 0, green: k == 1 ? 1 : 0, blue: k == 2 ? 1 : 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
} }
write("spin.gif", type: .gif, images: frames, properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
      frameProps: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]])

let pdf = """
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 44>>stream
BT /F1 18 Tf 40 100 Td (Quarterly report) Tj ET
endstream endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
trailer<</Root 1 0 R>>
%%EOF
"""
try! Data(pdf.utf8).write(to: out.appending(path: "report.pdf"))
print("wrote report.pdf")
