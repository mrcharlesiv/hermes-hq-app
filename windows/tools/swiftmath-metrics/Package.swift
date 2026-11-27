// swift-tools-version:5.9
// Measures formulas with the Mac's own typesetter (Vendor/SwiftMath through HQMathLine, as App/Chat/Render/
// MathTypeset.swift does) so the Windows engine (Hermes.Math, CSharpMath) can be checked against it.
// Usage (macOS): copy this folder and ../../../Vendor/SwiftMath side by side into scratch, then
//   swift run -c release swiftmath-metrics < inputs.json > mac-swiftmath-metrics.json
// inputs.json: [{"source": ..., "latex": ..., "block": bool}]; sizes come from the "size" field (default 19).
import PackageDescription

let package = Package(
    name: "swiftmath-metrics",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../../Vendor/SwiftMath")],
    targets: [.executableTarget(name: "swiftmath-metrics", dependencies: [.product(name: "SwiftMath", package: "SwiftMath")])]
)
