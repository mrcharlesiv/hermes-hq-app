// The Painted wallpapers: one entry point. A scene computes its study, the brush engine paints it.

import CoreGraphics

nonisolated enum PaintArt {
    /// The eight pictures, in picker order.
    static let scenes = ["paintLake", "paintOcean", "paintClouds", "paintHills", "paintForest", "paintDesert", "paintPeaks", "paintHarbor"]

    /// A finished opaque picture, or nil for an unknown scene or an impossible size. Deterministic, and safe to run concurrently.
    static func render(scene: String, width: Int, height: Int, dark: Bool) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let study: PaintSceneRef
        let seed: UInt64
        switch scene {
        case "paintLake":
            study = PaintLakeScene.scene(width: width, height: height, dark: dark)
            seed = 0x1A4E
        case "paintOcean":
            study = PaintOceanScene.scene(width: width, height: height, dark: dark)
            seed = 0x0CEA
        case "paintClouds":
            study = PaintCloudSeaScene.scene(width: width, height: height, dark: dark)
            seed = 0xC10D
        case "paintHills":
            study = PaintHillsScene.scene(width: width, height: height, dark: dark)
            seed = 0x417A
        case "paintForest":
            study = PaintForestScene.scene(width: width, height: height, dark: dark)
            seed = 0xB1C4
        case "paintDesert":
            study = PaintDesertScene.scene(width: width, height: height, dark: dark)
            seed = 0xDE5E
        case "paintPeaks":
            study = PaintPeaksScene.scene(width: width, height: height, dark: dark)
            seed = 0x9EAB
        case "paintHarbor":
            study = PaintHarborScene.scene(width: width, height: height, dark: dark)
            seed = 0xA4B0
        default:
            return nil
        }
        return PaintEngine.paint(ref: study, width: width, height: height, seed: seed)
    }
}
