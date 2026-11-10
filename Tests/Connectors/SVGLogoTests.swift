// App logos drawn from SVG (App/ConnectApps/SVGLogo.swift): logos.composio.dev answers every app in SVG.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

struct SVGLogoTests {
    /// The colour at (x, y) of the logo's pixels, 0-255 premultiplied.
    private func pixel(_ image: UIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let cg = image.cgImage!
        let data = cg.dataProvider!.data!, bytes = CFDataGetBytePtr(data)!
        let i = y * cg.bytesPerRow + x * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    private func draw(_ svg: String) -> UIImage? { SVGLogo.image(Data(svg.utf8), pixels: 100) }

    @Test func aFilledPathLandsTheRightWayUp() throws {
        let image = try #require(draw(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" fill="none"><path fill="#FF0000" d="M0 0h10v5H0z"/></svg>"##))
        #expect(pixel(image, 50, 20).r > 240 && pixel(image, 50, 20).a > 240, "the top half is red")
        #expect(pixel(image, 50, 80).a == 0, "the bottom half is empty")
    }

    @Test func aGradientClipAndMaskAreHonoured() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs>
            <linearGradient id="g" x1="0" x2="100" y1="0" y2="0" gradientUnits="userSpaceOnUse">
              <stop stop-color="#0000FF"/><stop offset="1" stop-color="#00FF00"/>
            </linearGradient>
            <clipPath id="c"><rect width="100" height="50"/></clipPath>
            <mask id="m" style="mask-type:alpha"><rect x="50" width="50" height="100" fill="#123456"/></mask>
          </defs>
          <rect width="100" height="100" fill="url(#g)" clip-path="url(#c)"/>
          <g mask="url(#m)"><rect y="50" width="100" height="50" fill="rgb(100%,0%,0%)"/></g>
        </svg>
        """
        let image = try #require(draw(svg))
        #expect(pixel(image, 5, 10).b > 200, "the gradient starts blue")
        #expect(pixel(image, 95, 10).g > 200, "and ends green")
        #expect(pixel(image, 20, 70).a == 0, "the mask hides the left of the red band")
        #expect(pixel(image, 80, 70).r > 240, "and shows its right")
    }

    @Test func somethingThatIsNotADrawingGivesNothing() {
        #expect(draw("<html><body>no</body></html>") == nil)
        #expect(draw(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path fill="none" d="M0 0h10v10H0z"/></svg>"##) == nil)
        #expect(SVGLogo.image(Data("not xml".utf8)) == nil)
    }

    /// TEST_RUNNER_HQN_SVG_DIR=<folder of .svg>: draws each to <name>.png beside it (a look at real logos; skipped otherwise).
    @Test func drawsAFolderOfLogosWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["HQN_SVG_DIR"] else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".svg") }
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(file))
            let out = URL(fileURLWithPath: dir).appendingPathComponent(file.replacingOccurrences(of: ".svg", with: ".png"))
            if let png = SVGLogo.image(data)?.pngData() { try png.write(to: out) } else { try? FileManager.default.removeItem(at: out) }
        }
    }
}
