// swift-tools-version: 6.2
// [backdrop] The Photographic, Illustrated, Painted and Doodles wallpapers. A package of its own because the painters are
// pixel loops: unoptimised, as an app target's Debug build would be, one picture takes minutes and the tests with it.
import PackageDescription

let package = Package(
    name: "WallpaperArt",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "WallpaperArt", targets: ["WallpaperArt"])],
    targets: [.target(name: "WallpaperArt", swiftSettings: [.unsafeFlags(["-O"])])]
)
