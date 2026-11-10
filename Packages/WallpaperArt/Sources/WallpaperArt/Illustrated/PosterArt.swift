// The one way in. Everything else in these files is prefixed or private, so it can sit beside the other styles.

import CoreGraphics
import Foundation

nonisolated enum PosterArt {
    /// A finished opaque picture. `scene`: posterLake, posterOcean, posterClouds, posterMesa, northernLights, snowyVillage, cityDusk, rollingHills.
    static func render(scene: String, width: Int, height: Int, dark: Bool) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        // The three from the bake-off keep their old names here: the grain is seeded from the name, and they must not change.
        let seedName: String
        switch scene {
        case "posterLake": seedName = "lake"
        case "posterOcean": seedName = "ocean"
        case "posterClouds": seedName = "clouds"
        case "posterMesa", "northernLights", "snowyVillage", "cityDusk", "rollingHills": seedName = scene
        default: return nil
        }
        // Small sizes are drawn at twice the size and averaged: the grain becomes tone and thin shapes stay.
        let small = min(width, height) < 640
        let rw = small ? width * 2 : width, rh = small ? height * 2 : height
        var seed: UInt64 = 0xcbf29ce484222325
        for b in seedName.utf8 { seed = (seed ^ UInt64(b)) &* 0x100000001b3 }
        guard let c = PosterCanvas(w: rw, h: rh, seed: seed, focusY: focus(scene)) else { return nil }
        switch scene {
        case "posterLake": Poster.lake(c, dark: dark)
        case "posterOcean": Poster.ocean(c, dark: dark)
        case "posterClouds": Poster.clouds(c, dark: dark)
        case "posterMesa": Poster.mesa(c, dark: dark)
        case "northernLights": Poster.northernLights(c, dark: dark)
        case "snowyVillage": Poster.snowyVillage(c, dark: dark)
        case "cityDusk": Poster.cityDusk(c, dark: dark)
        case "rollingHills": Poster.rollingHills(c, dark: dark)
        default: return nil
        }
        guard small else { return c.ctx.makeImage() }
        guard let out = BackdropCanvas.context(width: width, height: height), let d = out.data else { return nil }
        let o = d.bindMemory(to: UInt8.self, capacity: out.bytesPerRow * height)
        let bpr = out.bytesPerRow
        c.rows(0, height) { r in
            let a = c.px + (r * 2) * c.bpr, b = c.px + (r * 2 + 1) * c.bpr
            let line = o + r * bpr
            for x in 0..<width {
                for k in 0..<3 {
                    let s = Int(a[x * 8 + k]) + Int(a[x * 8 + 4 + k]) + Int(b[x * 8 + k]) + Int(b[x * 8 + 4 + k])
                    line[x * 4 + k] = UInt8((s + 2) / 4)
                }
                line[x * 4 + 3] = 255
            }
        }
        return out.makeImage()
    }

    /// Design-space y that stays centred when a wider frame (an iPad's, say) has to crop the design's height.
    private static func focus(_ scene: String) -> Double {
        switch scene {
        case "posterLake": return 1000
        case "posterOcean": return 1130
        case "posterClouds": return 1080
        case "posterMesa": return 1120
        case "northernLights": return 1200
        case "snowyVillage": return 1170
        case "cityDusk": return 1200
        case "rollingHills": return 1240
        default: return 1084
        }
    }
}
