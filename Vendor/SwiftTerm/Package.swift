// swift-tools-version:6.0
// SwiftTerm v1.99.2 (a183c15b, MIT: LICENSE), vendored for the app's Terminal page (docs/spec/terminal.md).
// Upstream's manifest runs a build-tool plugin that writes Generated/SwiftTermBuildInfo.swift and
// Generated/SwiftTermTerminfo.swift; command-line builds refuse plugins without -skipPackagePluginValidation, so
// those two files were generated once (SWIFTTERM_BUILD_TAG=v1.99.2) and are kept here instead. Its non-Apple
// graphics dependency (swift-png) is left out: this copy builds for iOS and Mac Catalyst only.
// To update: copy upstream's Sources/SwiftTerm over Sources/SwiftTerm (without Documentation.docc), run its
// SwiftTermBuildInfoGenerator <checkout> Generated/SwiftTermBuildInfo.swift Generated/SwiftTermTerminfo.swift.
// Local change to carry over: `reportsTextBeforeInput` (iOSTerminalView.swift, used in iOSTextInput.swift's text(in:),
// beginningOfDocument, textRange(from:to:) and position(from:offset:)), so a held delete keeps repeating (a
// tester, 2026-11-05).
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v16), .macOS(.v13), .macCatalyst(.v16)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
