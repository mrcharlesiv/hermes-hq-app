// The one door into the package. Each style's scene names are the ids in App/Theme/BackdropPresets.swift.

import CoreGraphics

public nonisolated enum WallpaperArt {
    public enum Style: Sendable { case photographic, illustrated, painted, doodles }

    /// A finished opaque picture, or nil for an unknown scene. Deterministic, and safe to run concurrently off the main thread.
    public static func render(_ style: Style, scene: String, width: Int, height: Int, dark: Bool) -> CGImage? {
        switch style {
        case .photographic: LitArt.render(scene: scene, width: width, height: height, dark: dark)
        case .illustrated: PosterArt.render(scene: scene, width: width, height: height, dark: dark)
        case .painted: PaintArt.render(scene: scene, width: width, height: height, dark: dark)
        case .doodles: DoodleArt.render(scene: scene, width: width, height: height, dark: dark)
        }
    }
}
