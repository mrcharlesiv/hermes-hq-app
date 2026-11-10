// Makes the browser fixture's page frames (scripts/fixtures/browser-gateway.py): 30 JPEGs of an invented 1280×720
// sign-in page — a title, a username box (y 30–38 %), a password box (y 42–50 %) and a bar sliding across the top so
// motion is visible. Usage: swift scripts/fixtures/make-browser-frames.swift <output dir>
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/fixtures/browser-frames")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let w = 1280, h = 720

func text(_ c: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, gray: CGFloat = 0.15) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let color = CGColor(gray: gray, alpha: 1)
    let attributed = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                kCTForegroundColorAttributeName as NSAttributedString.Key: color])
    let line = CTLineCreateWithAttributedString(attributed)
    c.textPosition = CGPoint(x: x, y: CGFloat(h) - y)
    CTLineDraw(line, c)
}

for i in 0..<30 {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // A bar sliding along the top (CG's origin is bottom-left).
    c.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1))
    c.fill(CGRect(x: CGFloat(i) * CGFloat(w - 200) / 29, y: CGFloat(h) - 24, width: 200, height: 12))
    text(c, "Example Sign In", 440, 150, size: 44)
    for (label, top) in [("Username", 0.30), ("Password", 0.42)] {
        let y = CGFloat(h) * (1 - top - 0.08)
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 384, y: y, width: 512, height: CGFloat(h) * 0.08))
        c.setStrokeColor(CGColor(gray: 0.6, alpha: 1)); c.setLineWidth(2); c.stroke(CGRect(x: 384, y: y, width: 512, height: CGFloat(h) * 0.08))
        text(c, label, 400, CGFloat(h) * CGFloat(top) + 38, size: 22, gray: 0.55)
    }
    c.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)); c.fill(CGRect(x: 384, y: CGFloat(h) * 0.38, width: 512, height: 50))
    text(c, "Frame \(i + 1)", 40, 690, size: 20, gray: 0.5)
    let url = out.appending(path: String(format: "frame-%02d.jpg", i))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
}
print("wrote 30 frames to \(out.path)")
