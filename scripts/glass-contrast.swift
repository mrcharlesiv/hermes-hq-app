// glass: how readable is every line of text in a screenshot? Finds the text with Vision, then measures each line's ink
// against what is right behind it (the darkest and lightest tenth of the line's pixels) and prints the WCAG ratio.
// Made for text over Liquid Glass, where the backdrop changes with whatever scrolls under it (owner 2026-10-30).
//
// Usage: swift scripts/glass-contrast.swift [--min 4.5] [--below 0.0] shot.png…
//   --min    ratio a line must reach (default 4.5, WCAG body text); lines under it print FAIL and the exit code is 1
//   --below  only lines whose top is below this fraction of the height (e.g. 0.45: only a half-height sheet)
import AppKit
import Vision

func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
    func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

var minimum = 4.5, below = 0.0, files: [String] = []
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    if a == "--min", let v = args.popFirst() { minimum = Double(v) ?? minimum }
    else if a == "--below", let v = args.popFirst() { below = Double(v) ?? below }
    else { files.append(a) }
}

var failed = false
for path in files {
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("\(path): cannot read"); failed = true; continue
    }
    let w = cg.width, h = cg.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: cg).perform([request])
    var worst = Double.infinity, lines = 0
    for result in request.results ?? [] {
        guard let text = result.topCandidates(1).first?.string, text.count >= 3 else { continue }
        let box = result.boundingBox   // normalised, origin bottom left
        let top = 1 - box.maxY
        guard top >= below else { continue }
        let x0 = max(0, Int(box.minX * Double(w))), x1 = min(w, Int(box.maxX * Double(w)))
        let y0 = max(0, Int(top * Double(h))), y1 = min(h, Int((1 - box.minY) * Double(h)))
        guard x1 - x0 > 4, y1 - y0 > 4 else { continue }
        var lums: [Double] = []
        lums.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                lums.append(luminance(Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255))
            }
        }
        lums.sort()
        let tenth = max(1, lums.count / 10)
        let dark = lums[..<tenth].reduce(0, +) / Double(tenth)
        let light = lums[(lums.count - tenth)...].reduce(0, +) / Double(tenth)
        let ratio = (light + 0.05) / (dark + 0.05)
        lines += 1
        worst = min(worst, ratio)
        let mark = ratio < minimum ? "FAIL" : "ok  "
        if ratio < minimum { failed = true }
        print(String(format: "%@ %5.2f:1  y %4d  %@", mark, ratio, y0, String(text.prefix(60))))
    }
    print(String(format: "%@: %d lines, worst %.2f:1", (path as NSString).lastPathComponent, lines, lines == 0 ? 0 : worst))
}
exit(failed ? 1 : 0)
