// Shared helpers for the Bot Screen tests: a small RFB server-side encoder (the shapes the Mac helper and Xvnc send),
// the decoder vectors written by `scripts/fixtures/screen-gateway.py --emit-vectors`, and JPEG makers.

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import zlib
@testable import HermesHQNative

nonisolated enum RFBBuild {
    static func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    static func serverInit(width: Int, height: Int, name: String = "This Mac") -> Data {
        let format: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        return Data(be16(width) + be16(height) + format + be32(name.utf8.count) + Array(name.utf8))
    }

    /// Everything a 3.8 server sends up to and including ServerInit.
    static func preamble(width: Int, height: Int, name: String = "This Mac") -> Data {
        Data("RFB 003.008\n".utf8) + Data([1, 1]) + Data(be32(0)) + serverInit(width: width, height: height, name: name)
    }

    static func update(_ rects: [Data], count: Int? = nil) -> Data {
        var out = Data([0, 0] + be16(count ?? rects.count))
        for rect in rects { out.append(rect) }
        return out
    }

    static func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: Int32) -> Data {
        Data(be16(x) + be16(y) + be16(w) + be16(h) + be32(Int(UInt32(bitPattern: encoding))))
    }

    static func raw(_ x: Int, _ y: Int, _ w: Int, _ h: Int, b: UInt8, g: UInt8, r: UInt8) -> Data {
        var out = rect(x, y, w, h, 0)
        for _ in 0..<(w * h) { out.append(contentsOf: [b, g, r, 0]) }
        return out
    }

    static func copyRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, fromX: Int, fromY: Int) -> Data {
        rect(x, y, w, h, 1) + Data(be16(fromX) + be16(fromY))
    }

    static func compact(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        if length < 0x4000 { return [UInt8(length & 0x7F) | 0x80, UInt8(length >> 7)] }
        return [UInt8(length & 0x7F) | 0x80, UInt8((length >> 7) & 0x7F) | 0x80, UInt8(length >> 14)]
    }

    static func tightFill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> Data {
        rect(x, y, w, h, 7) + Data([0x80, r, g, b])
    }

    static func tightJPEG(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ jpeg: Data) -> Data {
        rect(x, y, w, h, 7) + Data([0x90] + compact(jpeg.count)) + jpeg
    }

    /// Tight Basic, copy filter, zlib stream `stream` (a fresh deflate stream per call, so pass `reset` for a reused id).
    static func tightBasic(_ x: Int, _ y: Int, _ w: Int, _ h: Int, rgb: [UInt8], stream: Int = 0, reset: Bool = true) -> Data {
        let control = UInt8(stream << 4) | (reset ? UInt8(1 << stream) : 0)
        if rgb.count < 12 { return rect(x, y, w, h, 7) + Data([control] + rgb) }
        let packed = deflate(rgb)
        return rect(x, y, w, h, 7) + Data([control] + compact(packed.count)) + packed
    }

    static func deflate(_ bytes: [UInt8]) -> Data {
        var length = uLongf(compressBound(uLong(bytes.count)))
        var out = [UInt8](repeating: 0, count: Int(length))
        compress2(&out, &length, bytes, uLong(bytes.count), 6)
        return Data(out.prefix(Int(length)))
    }

    static func lastRect() -> Data { rect(0, 0, 0, 0, -224) }
    static func desktopSize(_ w: Int, _ h: Int) -> Data { rect(0, 0, w, h, -223) }
    static func extendedDesktopSize(_ w: Int, _ h: Int, status: Int = 0) -> Data {
        rect(0, status, w, h, -308) + Data([1, 0, 0, 0] + be32(1) + be16(0) + be16(0) + be16(w) + be16(h) + be32(0))
    }
}

nonisolated enum ScreenTestImage {
    /// A JPEG of one colour (`noise` adds per-pixel variation, which makes the file large).
    static func jpeg(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat, noise: Bool = false) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise, let data = context.data {
            let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            var seed: UInt32 = 12345
            for i in 0..<(width * height * 4) where i % 4 != 3 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[i] = UInt8(truncatingIfNeeded: seed >> 16)
            }
        }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}

nonisolated struct ScreenVector: Decodable {
    let name: String
    let width: Int
    let height: Int
    let note: String
    let samples: [[Int]]?
    let tolerance: Int?

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/screen")

    static func all() throws -> [ScreenVector] {
        try JSONDecoder().decode([ScreenVector].self, from: Data(contentsOf: folder.appending(path: "vectors.json")))
    }

    var stream: Data { (try? Data(contentsOf: Self.folder.appending(path: "\(name).rfb"))) ?? Data() }
    /// The expected picture as B, G, R triples (nil for the JPEG vector, which has samples instead).
    var expected: [UInt8]? {
        guard let data = try? Data(contentsOf: Self.folder.appending(path: "\(name).bgrx")) else { return nil }
        var out = [UInt8](repeating: 0, count: data.count / 4 * 3)
        data.withUnsafeBytes { raw in
            for i in 0..<(data.count / 4) { out[i * 3] = raw[i * 4]; out[i * 3 + 1] = raw[i * 4 + 1]; out[i * 3 + 2] = raw[i * 4 + 2] }
        }
        return out
    }
}

nonisolated enum RFBFeed {
    /// Feeds `data` in pieces of `chunk` bytes; returns the summed output.
    @discardableResult
    static func run(_ parser: RFBParser, _ data: Data, chunk: Int = .max) throws -> RFBParser.Output {
        var total = RFBParser.Output()
        var at = data.startIndex
        while at < data.endIndex {
            let end = chunk == .max ? data.endIndex : min(data.endIndex, at + chunk)
            let out = try parser.feed(data.subdata(in: at..<end))
            total.send += out.send
            total.ready = total.ready || out.ready
            total.updates += out.updates
            total.rects += out.rects
            total.resized = total.resized || out.resized
            at = end
        }
        return total
    }

    static func error(_ data: Data, chunk: Int = .max) -> RFBError? {
        do { try run(RFBParser(), data, chunk: chunk) } catch let error as RFBError { return error } catch { return nil }
        return nil
    }
}

/// One zlib stream fed part by part with a sync flush after each (how a Tight server feeds one of its four streams).
nonisolated final class RFBTestDeflater {
    func run(_ parts: [[UInt8]]) -> [Data] {
        var stream = z_stream()
        deflateInit_(&stream, 6, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        return parts.map { part in
            var input = part
            var out = [UInt8](repeating: 0, count: part.count + 256)
            let produced: Int = input.withUnsafeMutableBufferPointer { source in
                out.withUnsafeMutableBufferPointer { target in
                    stream.next_in = source.baseAddress
                    stream.avail_in = UInt32(source.count)
                    stream.next_out = target.baseAddress
                    stream.avail_out = UInt32(target.count)
                    deflate(&stream, Z_SYNC_FLUSH)
                    return target.count - Int(stream.avail_out)
                }
            }
            return Data(out.prefix(produced))
        }
    }
}

/// A display socket a test drives by hand: `push` delivers a frame, `end` closes it as the gateway would.
nonisolated final class FakeScreenSocket: ScreenSocketing, @unchecked Sendable {
    private struct State {
        var sent: [Data] = []
        var closes: [Bool] = []
        var code: Int?
        var reason: String?
        var pings = 0
        var answerPings = true
        var sendDelay: Duration?
        var failSends = false
    }
    private let state = Mutex(State())
    private let frames: AsyncStream<ScreenSocketFrame>
    private let feed: AsyncStream<ScreenSocketFrame>.Continuation

    init() { (frames, feed) = AsyncStream<ScreenSocketFrame>.makeStream() }

    var sent: [Data] { state.withLock { $0.sent } }
    /// One entry per `close` call: true = with a 1000 close frame (hand back).
    var closes: [Bool] { state.withLock { $0.closes } }
    var pings: Int { state.withLock { $0.pings } }
    var requests: [Data] { sent.filter { $0.first == 3 } }
    var inputs: [Data] { sent.filter { [4, 5, 6].contains($0.first ?? 0) } }
    func answerPings(_ on: Bool) { state.withLock { $0.answerPings = on } }
    func slowSends(_ delay: Duration?) { state.withLock { $0.sendDelay = delay } }
    /// Every send from now fails while receiving goes on (a link that can't send).
    func failSends() { state.withLock { $0.failSends = true } }

    func push(_ data: Data) { feed.yield(.binary(data)) }
    func pushText() { feed.yield(.text) }
    /// The gateway ends the socket (`code` nil: the link dropped, no close frame).
    func end(code: Int? = nil, reason: String? = nil) {
        state.withLock { $0.code = code; $0.reason = reason }
        feed.finish()
    }

    func receive() async throws -> ScreenSocketFrame {
        for await frame in frames { return frame }
        throw URLError(.networkConnectionLost)
    }

    func send(_ data: Data) async throws {
        let delay = state.withLock { $0.sendDelay }
        if let delay { try? await Task.sleep(for: delay) }
        let closed = state.withLock { state -> Bool in
            if !state.closes.isEmpty || state.failSends { return true }
            state.sent.append(data)
            return false
        }
        if closed { throw URLError(.cancelled) }
    }

    func ping(timeout: Duration) async -> Bool {
        let answer = state.withLock { state -> Bool in state.pings += 1; return state.answerPings }
        if !answer { try? await Task.sleep(for: .milliseconds(50)) }
        return answer
    }

    /// Like the real socket, only the first close counts.
    func close(handBack: Bool) {
        state.withLock { if $0.closes.isEmpty { $0.closes.append(handBack) } }
        feed.finish()
    }

    var closeCode: Int? { state.withLock { $0.code } }
    var closeReason: String? { state.withLock { $0.reason } }
}

/// A clock a test moves by hand.
nonisolated final class FakeUptime: Sendable {
    private let value = Mutex(1000.0)
    var now: TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@MainActor
func screenWait(_ seconds: Double = 5, _ done: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if done() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return done()
}
