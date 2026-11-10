// The picture side of the native RFB client (docs/spec/3x-screen.md §2.3): the framebuffer (BGRX in memory, the Mac
// helper's own format and CoreGraphics' little-endian 32-bit one, so pixels are never converted one by one) and the
// decoders that write into it: Raw rows, CopyRect, Tight Fill / JPEG / Basic with its four zlib streams.
// Everything here runs on the stream's own task, never on the main thread.

import CoreGraphics
import Foundation
import ImageIO
import zlib

nonisolated final class ScreenFramebuffer {
    static let maxSide = 8192
    static let maxBytes = 64 * 1024 * 1024

    let width: Int
    let height: Int
    private let context: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>
    private var stride: Int { width * 4 }

    static func allowed(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxSide && height <= maxSide && width * height * 4 <= maxBytes
    }

    /// nil for a size outside the limits (bad data can never make the app reserve more than 64 MB).
    init?(width: Int, height: Int) {
        guard Self.allowed(width: width, height: height),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        self.width = width
        self.height = height
        self.context = context
        pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
    }

    func contains(x: Int, y: Int, w: Int, h: Int) -> Bool { x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height }

    /// `rows` full rows of BGRX starting at row `y` of the rect at `x`.
    func writeRaw(x: Int, y: Int, w: Int, rows: Int, from source: UnsafePointer<UInt8>) {
        guard w > 0 else { return }
        for row in 0..<rows {
            memcpy(pixels + (y + row) * stride + x * 4, source + row * w * 4, w * 4)
        }
    }

    /// Overlap-safe: rows go bottom-up when the copy moves down.
    func copyRect(x: Int, y: Int, w: Int, h: Int, fromX: Int, fromY: Int) {
        guard w > 0, h > 0 else { return }
        let rows = y > fromY ? Array((0..<h).reversed()) : Array(0..<h)
        for row in rows {
            memmove(pixels + (y + row) * stride + x * 4, pixels + (fromY + row) * stride + fromX * 4, w * 4)
        }
    }

    func fill(x: Int, y: Int, w: Int, h: Int, r: UInt8, g: UInt8, b: UInt8) {
        guard w > 0, h > 0 else { return }
        let first = pixels + y * stride + x * 4
        for col in 0..<w {
            first[col * 4] = b; first[col * 4 + 1] = g; first[col * 4 + 2] = r; first[col * 4 + 3] = 0
        }
        for row in 1..<max(1, h) { memcpy(pixels + (y + row) * stride + x * 4, first, w * 4) }
    }

    /// Tight's 3-byte RGB pixels, row by row.
    func writeRGB(x: Int, y: Int, w: Int, h: Int, from rgb: UnsafePointer<UInt8>) {
        for row in 0..<h {
            let line = pixels + (y + row) * stride + x * 4
            let source = rgb + row * w * 3
            for col in 0..<w {
                line[col * 4] = source[col * 3 + 2]
                line[col * 4 + 1] = source[col * 3 + 1]
                line[col * 4 + 2] = source[col * 3]
                line[col * 4 + 3] = 0
            }
        }
    }

    /// false when the bytes are not a JPEG that decodes: the rect is left as it was.
    func drawJPEG(_ data: Data, x: Int, y: Int, w: Int, h: Int) -> Bool {
        guard w > 0, h > 0, data.count > 3, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width > 0, image.height > 0 else { return false }
        context.draw(image, in: CGRect(x: x, y: height - y - h, width: w, height: h))
        return true
    }

    /// An immutable snapshot (copy-on-write), safe to hand to the main thread while decoding goes on.
    func makeImage() -> CGImage? { context.makeImage() }

    func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        let at = pixels + min(height - 1, max(0, y)) * stride + min(width - 1, max(0, x)) * 4
        return (at[0], at[1], at[2])
    }

    /// The five sample points the fixture reports (`/__fixture/screen/expect`), as hex BGR.
    func probe() -> String {
        [(0.25, 0.25), (0.75, 0.25), (0.5, 0.5), (0.25, 0.75), (0.75, 0.75)].map { fx, fy in
            let p = pixel(x: Int(Double(width) * fx), y: Int(Double(height) * fy))
            return String(format: "%02x%02x%02x", p.b, p.g, p.r)
        }.joined()
    }

    /// The pixels as B, G, R triples (tests compare these with a vector's expected picture).
    func bgr() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            out[i * 3] = pixels[i * 4]; out[i * 3 + 1] = pixels[i * 4 + 1]; out[i * 3 + 2] = pixels[i * 4 + 2]
        }
        return out
    }
}

/// Tight's four zlib streams. They live as long as the connection: a rect continues the stream an earlier one left.
nonisolated final class TightStreams {
    private let streams = UnsafeMutablePointer<z_stream>.allocate(capacity: 4)
    private var ready = [false, false, false, false]

    init() { streams.initialize(repeating: z_stream(), count: 4) }

    deinit {
        for i in 0..<4 where ready[i] { inflateEnd(streams + i) }
        streams.deinitialize(count: 4)
        streams.deallocate()
    }

    func reset(_ index: Int) {
        guard ready[index] else { return }
        inflateEnd(streams + index)
        streams[index] = z_stream()
        ready[index] = false
    }

    /// Inflates `input` on stream `index` into exactly `count` bytes.
    func inflate(_ index: Int, input: UnsafeBufferPointer<UInt8>, count: Int) throws(RFBError) -> [UInt8] {
        let stream = streams + index
        if !ready[index] {
            guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw .zlib }
            ready[index] = true
        }
        var out = [UInt8](repeating: 0, count: count)
        stream.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
        stream.pointee.avail_in = UInt32(input.count)
        let code: Int32 = out.withUnsafeMutableBufferPointer { buffer in
            stream.pointee.next_out = buffer.baseAddress
            stream.pointee.avail_out = UInt32(count)
            return zlib.inflate(stream, Z_SYNC_FLUSH)
        }
        guard code == Z_OK || code == Z_STREAM_END || code == Z_BUF_ERROR, stream.pointee.avail_out == 0 else { throw .zlib }
        // The sync marker after the last byte may still be unread: take it in, so the next rect starts clean.
        var scratch = [UInt8](repeating: 0, count: 16)
        var rounds = 0
        while stream.pointee.avail_in > 0, rounds < 4 {
            rounds += 1
            let left: UInt32 = scratch.withUnsafeMutableBufferPointer { buffer in
                stream.pointee.next_out = buffer.baseAddress
                stream.pointee.avail_out = 16
                _ = zlib.inflate(stream, Z_SYNC_FLUSH)
                return stream.pointee.avail_out
            }
            if left != 16 { throw .zlib }       // more pixels than the rect holds
        }
        if stream.pointee.avail_in > 0 { throw .zlib }
        stream.pointee.next_in = nil
        stream.pointee.next_out = nil
        return out
    }
}

nonisolated enum TightFilter {
    /// The palette filter's index data → RGB triples. nil when an index points past the palette.
    static func palette(_ data: [UInt8], palette: [UInt8], w: Int, h: Int) -> [UInt8]? {
        let colours = palette.count / 3
        var out = [UInt8](repeating: 0, count: w * h * 3)
        if colours == 2 {
            let rowBytes = (w + 7) / 8
            guard data.count >= rowBytes * h else { return nil }
            for row in 0..<h {
                for col in 0..<w {
                    let index = Int((data[row * rowBytes + col / 8] >> UInt8(7 - col % 8)) & 1)
                    let at = (row * w + col) * 3
                    out[at] = palette[index * 3]; out[at + 1] = palette[index * 3 + 1]; out[at + 2] = palette[index * 3 + 2]
                }
            }
        } else {
            guard data.count >= w * h else { return nil }
            for i in 0..<(w * h) {
                let index = Int(data[i])
                guard index < colours else { return nil }
                out[i * 3] = palette[index * 3]; out[i * 3 + 1] = palette[index * 3 + 1]; out[i * 3 + 2] = palette[index * 3 + 2]
            }
        }
        return out
    }

    /// The gradient filter: each component is stored as its difference from left + up − up-left (clamped).
    static func gradient(_ data: [UInt8], w: Int, h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for row in 0..<h {
            for col in 0..<w {
                let at = (row * w + col) * 3
                for c in 0..<3 {
                    let left = col > 0 ? Int(out[at - 3 + c]) : 0
                    let up = row > 0 ? Int(out[at - w * 3 + c]) : 0
                    let corner = row > 0 && col > 0 ? Int(out[at - w * 3 - 3 + c]) : 0
                    let predicted = min(255, max(0, left + up - corner))
                    out[at + c] = UInt8((Int(data[at + c]) + predicted) & 0xFF)
                }
            }
        }
        return out
    }
}
