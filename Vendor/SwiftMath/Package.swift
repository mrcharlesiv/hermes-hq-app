// swift-tools-version:5.9
// SwiftMath (github.com/mgriebling/SwiftMath, MIT: LICENSE), vendored for the chat's formulas (App/Chat/Render/
// MathTypeset.swift; docs/spec/3x-transcript.md §3.5). Tester 2026-11-09: aligned, cases and matrices "often don't
// render properly" as the Unicode text `MathText.readable` makes.
// Kept in the repo so a build needs no network. Of upstream's twelve math fonts (7 MB) only Latin Modern Math is
// kept (0.7 MB; GUST Font License, mathFonts.bundle/GUST-FONT-LICENSE.txt): the app draws every formula in it.
// To update: copy upstream's Sources/SwiftMath over Sources/SwiftMath, delete the other fonts again and keep
// HQMathLine.swift (ours: the one public way in the app uses).
import PackageDescription

let package = Package(
    name: "SwiftMath",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13), .macCatalyst(.v16)],
    products: [.library(name: "SwiftMath", targets: ["SwiftMath"])],
    targets: [
        .target(name: "SwiftMath", path: "Sources/SwiftMath", resources: [.copy("mathFonts.bundle")]),
    ]
)
