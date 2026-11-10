// Gradient noise behind the Doodles' colour field and paper.

import Foundation

/// Smooth gradient noise on a hashed lattice. Unlike `Noise2D`'s sum of sine waves it never lines up into stripes,
/// which a rock face needs.
nonisolated struct GradientNoise: Sendable {
    private let seed: UInt32

    init(seed: UInt64) { self.seed = UInt32(truncatingIfNeeded: seed ^ (seed >> 29)) }

    @inline(__always) private func corner(_ ix: Int, _ iy: Int, _ dx: Double, _ dy: Double) -> Double {
        var h = (UInt32(truncatingIfNeeded: ix) &* 0x8DA6_B343) ^ (UInt32(truncatingIfNeeded: iy) &* 0xD816_3841) ^ seed
        h ^= h >> 13
        h = h &* 0x5BD1_E995
        h ^= h >> 15
        switch h & 7 {
        case 0: return dx + dy
        case 1: return dx - dy
        case 2: return dy - dx
        case 3: return -dx - dy
        case 4: return dx * 1.4
        case 5: return -dx * 1.4
        case 6: return dy * 1.4
        default: return -dy * 1.4
        }
    }

    /// Roughly -1…1, about one feature per unit step.
    func value(_ x: Double, _ y: Double) -> Double {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int(fx), iy = Int(fy)
        let dx = x - fx, dy = y - fy
        let u = dx * dx * dx * (dx * (dx * 6 - 15) + 10), v = dy * dy * dy * (dy * (dy * 6 - 15) + 10)
        let a = corner(ix, iy, dx, dy), b = corner(ix + 1, iy, dx - 1, dy)
        let c = corner(ix, iy + 1, dx, dy - 1), d = corner(ix + 1, iy + 1, dx - 1, dy - 1)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    /// Octaves of `value`, each twice as fine and half as strong.
    func fbm(_ x: Double, _ y: Double, octaves: Int) -> Double {
        var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0
        for o in 0..<octaves {
            sum += amp * value(x * freq + Double(o) * 17.3, y * freq - Double(o) * 9.1)
            norm += amp
            amp *= 0.5
            freq *= 2.03
        }
        return sum / norm
    }

    /// 0…1, with sharp crests where the noise crosses zero: ribs and arêtes between broad hollows.
    func ridged(_ x: Double, _ y: Double, octaves: Int) -> Double {
        var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0
        for o in 0..<octaves {
            let n = 1 - abs(value(x * freq + Double(o) * 17.3, y * freq - Double(o) * 9.1))
            sum += amp * n * n
            norm += amp
            amp *= 0.5
            freq *= 2.03
        }
        return sum / norm
    }
}
