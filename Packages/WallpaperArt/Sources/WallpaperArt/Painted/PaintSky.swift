// A gradient of colour stops, used for the skies.

import Foundation
import simd

nonisolated struct PaintGradient: Sendable {
    var stops: [(Float, PaintV3)]
    func at(_ f: Float) -> PaintV3 {
        if f <= stops[0].0 { return stops[0].1 }
        for i in 0..<(stops.count - 1) where f <= stops[i + 1].0 {
            return PaintMix(stops[i].1, stops[i + 1].1, PaintSstep(stops[i].0, stops[i + 1].0, f))
        }
        return stops[stops.count - 1].1
    }
}
