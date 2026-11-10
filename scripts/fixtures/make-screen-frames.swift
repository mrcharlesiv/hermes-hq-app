// Makes the Bot Screen fixture's desktop frames (scripts/fixtures/screen-gateway.py): 30 frames of an invented desktop
// (menu bar, two windows, a counter band that changes every frame, a coordinate grid, text) at 1280×800 and 1920×1080.
// Python has no JPEG encoder in its standard library, which is why the Tight-JPEG tiles are made here.
//
// Per size, in <out>/<W>x<H>/:
//   base.bgrx                          frame 0, raw BGRX pixels (for Raw / Tight Basic / CopyRect and the fixture's own picture)
//   full-NN.jpg                        the whole frame NN as one JPEG (quality 86), for a full update
//   frame-NN/tile-<x>-<y>-<w>x<h>.jpg  the 64-px-aligned tiles of frame NN that differ from frame NN-1 (frame 0: from 29)
//   frame-NN/tile-<x>-<y>-<w>x<h>.bgrx the same tiles as raw BGRX
//   manifest.json                      {"width", "height", "frames": [{"rects": [[x, y, w, h], …]}, …]}
// Usage: swift scripts/fixtures/make-screen-frames.swift <output dir>     (default build/fixtures/screen-frames)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/fixtures/screen-frames")
let frameCount = 30

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }

func draw(_ index: Int, _ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    func top(_ y: CGFloat, _ height: CGFloat) -> CGFloat { H - y - height }       // CG's origin is bottom-left
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                    kCTForegroundColorAttributeName as NSAttributedString.Key: color])
        c.textPosition = CGPoint(x: x, y: H - y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), c)
    }
    // Wallpaper and a coordinate grid every 160 px.
    c.setFillColor(rgb(0.16, 0.30, 0.46)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    c.setFillColor(rgb(0.20, 0.36, 0.54))
    var gx: CGFloat = 0
    while gx < W { c.fill(CGRect(x: gx, y: 0, width: 1, height: H)); gx += 160 }
    var gy: CGFloat = 0
    while gy < H { c.fill(CGRect(x: 0, y: top(gy, 1), width: W, height: 1)); gy += 160 }
    gx = 0
    while gx < W {
        gy = 160
        while gy < H { text("\(Int(gx)),\(Int(gy))", gx + 6, gy + 16, size: 11, color: rgb(0.55, 0.68, 0.82)); gy += 160 }
        gx += 160
    }
    // Menu bar.
    c.setFillColor(rgb(0.93, 0.93, 0.95)); c.fill(CGRect(x: 0, y: top(0, 28), width: W, height: 28))
    text("Fixture Desktop    File    Edit    View    Window    Help", 16, 19, size: 13, color: rgb(0.1, 0.1, 0.12))
    // Window 1: notes.
    let w1 = CGRect(x: W * 0.06, y: top(H * 0.30, H * 0.52), width: W * 0.42, height: H * 0.52)
    c.setFillColor(rgb(0.98, 0.98, 0.99)); c.fill(w1)
    c.setFillColor(rgb(0.86, 0.87, 0.90)); c.fill(CGRect(x: w1.minX, y: w1.maxY - 30, width: w1.width, height: 30))
    text("Notes", w1.minX + 14, H * 0.30 + 20, size: 14, color: rgb(0.2, 0.2, 0.24))
    for (row, line) in ["Things this invented desktop is for:", "• watching a stand-in screen", "• clicks, drags and typing",
                        "• nothing here is real"].enumerated() {
        text(line, w1.minX + 18, H * 0.30 + 64 + CGFloat(row) * 26, size: 16, color: rgb(0.15, 0.15, 0.18))
    }
    // Window 2: a browser-like window.
    let w2 = CGRect(x: W * 0.54, y: top(H * 0.36, H * 0.50), width: W * 0.40, height: H * 0.50)
    c.setFillColor(rgb(1, 1, 1)); c.fill(w2)
    c.setFillColor(rgb(0.80, 0.84, 0.92)); c.fill(CGRect(x: w2.minX, y: w2.maxY - 30, width: w2.width, height: 30))
    text("example.test", w2.minX + 14, H * 0.36 + 20, size: 14, color: rgb(0.2, 0.2, 0.3))
    c.setFillColor(rgb(0.22, 0.48, 0.96)); c.fill(CGRect(x: w2.minX + 24, y: w2.minY + 30, width: 160, height: 44))
    text("Save", w2.minX + 82, H * 0.36 + H * 0.50 - 46, size: 17, color: rgb(1, 1, 1))
    // The counter band: changes every frame (a label and a block that slides).
    let bandY: CGFloat = 64, bandH: CGFloat = 96
    c.setFillColor(rgb(0.10, 0.12, 0.16)); c.fill(CGRect(x: 0, y: top(bandY, bandH), width: W, height: bandH))
    text(String(format: "Frame %02d", index + 1), 24, bandY + 60, size: 36, color: rgb(0.95, 0.95, 0.98))
    let travel = W - 320 - 96
    c.setFillColor(rgb(0.98, 0.62, 0.10))
    c.fill(CGRect(x: 320 + travel * CGFloat(index) / CGFloat(frameCount - 1), y: top(bandY + 24, 48), width: 96, height: 48))
    return c
}

func jpeg(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
}

for (w, h) in [(1280, 800), (1920, 1080)] {
    let dir = out.appending(path: "\(w)x\(h)")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var pixels: [Data] = [], images: [CGImage] = []
    for i in 0..<frameCount {
        let c = draw(i, w, h)
        pixels.append(Data(bytes: c.data!, count: w * h * 4))
        images.append(c.makeImage()!)
    }
    try pixels[0].write(to: dir.appending(path: "base.bgrx"))
    var manifest: [[String: Any]] = []
    for i in 0..<frameCount {
        jpeg(images[i], dir.appending(path: String(format: "full-%02d.jpg", i)))
        let frameDir = dir.appending(path: String(format: "frame-%02d", i))
        try FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
        let now = pixels[i], before = pixels[(i + frameCount - 1) % frameCount]
        var rects: [[Int]] = []
        var by = 0
        while by < h {
            let bh = min(64, h - by)
            var run: (x: Int, w: Int)?
            var bx = 0
            func flush() {
                guard let r = run else { return }
                rects.append([r.x, by, r.w, bh]); run = nil
            }
            while bx < w {
                let bw = min(64, w - bx)
                var changed = false
                for row in by..<(by + bh) where !changed {
                    let start = (row * w + bx) * 4
                    changed = now.subdata(in: start..<(start + bw * 4)) != before.subdata(in: start..<(start + bw * 4))
                }
                if changed { run = run.map { ($0.x, $0.w + bw) } ?? (bx, bw); if run!.w >= 1024 { flush() } } else { flush() }
                bx += bw
            }
            flush()
            by += bh
        }
        for r in rects {
            let name = "tile-\(r[0])-\(r[1])-\(r[2])x\(r[3])"
            jpeg(images[i].cropping(to: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))!, frameDir.appending(path: name + ".jpg"))
            var raw = Data(capacity: r[2] * r[3] * 4)
            for row in r[1]..<(r[1] + r[3]) {
                let start = (row * w + r[0]) * 4
                raw.append(now.subdata(in: start..<(start + r[2] * 4)))
            }
            try raw.write(to: frameDir.appending(path: name + ".bgrx"))
        }
        manifest.append(["rects": rects])
    }
    let json = try JSONSerialization.data(withJSONObject: ["width": w, "height": h, "frames": manifest])
    try json.write(to: dir.appending(path: "manifest.json"))
}
print("wrote \(frameCount) frames per size to \(out.path)")
