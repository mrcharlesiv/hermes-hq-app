// The native RFB 3.8 client that replaces noVNC (docs/spec/3x-screen.md §2.3): an incremental parser over a growing
// byte buffer (RFB messages do not line up with WebSocket frames, so it must give the same result fed one byte at a
// time), the handshake, the server messages, and the client message encoders. Bad data ends in a typed error, never a
// crash, and never grows memory without bound.

import Foundation

nonisolated enum RFBError: Error, Equatable, Sendable {
    case badVersion
    case noSecurity                 // "None" is not offered (Hermes serves None on a private socket)
    case securityFailed(String)
    case badSize                    // 0 × 0, or over 8192 a side / 64 MB
    case unknownMessage(UInt8)
    case unknownEncoding(Int32)
    case rectOutside
    case tooLong                    // a declared length over its cap
    case zlib
    case badFilter
    case badJPEGs                   // three in a row
    case overflow                   // the parse buffer passed 16 MiB

    /// A content-free name for the log.
    var logName: String {
        switch self {
        case .badVersion: "bad-version"
        case .noSecurity: "no-security"
        case .securityFailed: "security-failed"
        case .badSize: "bad-size"
        case .unknownMessage: "unknown-message"
        case .unknownEncoding: "unknown-encoding"
        case .rectOutside: "rect-outside"
        case .tooLong: "too-long"
        case .zlib: "zlib"
        case .badFilter: "bad-filter"
        case .badJPEGs: "bad-jpegs"
        case .overflow: "overflow"
        }
    }
}

/// What the client sends (only message types 0, 2, 3, 4, 5, 6: anything else closes the gateway's stream with 1003).
nonisolated enum RFBMessage {
    /// Tight, CopyRect, Raw, quality 7, compression 2, LastRect, DesktopSize, ExtendedDesktopSize: in this order. Never
    /// Cursor (-239), ExtendedMouseButtons, ContinuousUpdates, Fence, XVP or H.264 (they break the gateway's framing
    /// or the pull model).
    static let encodings: [Int32] = [7, 1, 0, -25, -254, -224, -223, -308]
    static let maxCutText = 262_144

    /// 32 bits per pixel, depth 24, little-endian, true colour, 255/255/255, shifts R 16 · G 8 · B 0 (BGRX in memory).
    static func setPixelFormat() -> Data {
        Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
    }

    static func setEncodings(_ list: [Int32] = encodings) -> Data {
        var out = Data([2, 0, UInt8(list.count >> 8), UInt8(list.count & 0xFF)])
        for value in list { out.append(contentsOf: be32(UInt32(bitPattern: value))) }
        return out
    }

    static func updateRequest(incremental: Bool, width: Int, height: Int) -> Data {
        Data([3, incremental ? 1 : 0, 0, 0, 0, 0] + be16(width) + be16(height))
    }

    static func key(_ keysym: UInt32, down: Bool) -> Data { Data([4, down ? 1 : 0, 0, 0] + be32(keysym)) }

    static func pointer(mask: UInt8, x: Int, y: Int) -> Data { Data([5, mask] + be16(x) + be16(y)) }

    /// Latin-1 bytes, at most 262,144 (longer text is typed instead).
    static func cutText(_ latin1: [UInt8]) -> Data { Data([6, 0, 0, 0] + be32(UInt32(latin1.count)) + latin1) }

    private static func be16(_ value: Int) -> [UInt8] { [UInt8((max(0, min(65535, value)) >> 8) & 0xFF), UInt8(max(0, min(65535, value)) & 0xFF)] }
    private static func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
}

/// One connection's parser and decoders. Owned by the stream's task (not Sendable).
nonisolated final class RFBParser {
    struct Output: Equatable {
        /// Bytes to send now (handshake replies, then SetPixelFormat, SetEncodings and the first request).
        var send: [Data] = []
        /// ServerInit arrived: the desktop's size and name.
        var ready = false
        /// FramebufferUpdates completed in this feed.
        var updates = 0
        var rects = 0
        /// The desktop changed size: the next request must ask for the whole picture.
        var resized = false
    }

    static let maxBuffer = 16 * 1024 * 1024
    static let maxTight = 4 * 1024 * 1024
    static let maxSkip = 16 * 1024 * 1024

    private(set) var framebuffer: ScreenFramebuffer?
    private(set) var name = ""
    /// An update has begun and its last rect has not arrived (the stuck rule watches this).
    private(set) var midUpdate = false
    private(set) var failedJPEGs = 0

    private enum Phase {
        case version, securityTypes, securityResult, legacySecurity, failReason, serverInit, message, rect
        case rawRows(x: Int, y: Int, w: Int, h: Int, row: Int)
        case skip(Int)
    }
    private var phase: Phase = .version
    private var bytes: [UInt8] = []
    private var head = 0
    private var minor = 8
    private var rectsLeft = 0
    private var jpegRun = 0
    private let streams = TightStreams()

    private var available: Int { bytes.count - head }
    private func u8(_ offset: Int) -> Int { Int(bytes[head + offset]) }
    private func u16(_ offset: Int) -> Int { Int(bytes[head + offset]) << 8 | Int(bytes[head + offset + 1]) }
    private func u32(_ offset: Int) -> Int {
        Int(bytes[head + offset]) << 24 | Int(bytes[head + offset + 1]) << 16 | Int(bytes[head + offset + 2]) << 8 | Int(bytes[head + offset + 3])
    }

    /// Takes more server bytes. Throws `RFBError` on bad data; after a throw the parser must not be fed again.
    func feed(_ data: Data) throws(RFBError) -> Output {
        bytes.append(contentsOf: data)
        var out = Output()
        while try step(&out) {}
        if head > 0 {
            bytes.removeFirst(head)
            head = 0
        }
        guard bytes.count <= Self.maxBuffer else { throw .overflow }
        return out
    }

    /// One unit of progress. false: more bytes are needed.
    private func step(_ out: inout Output) throws(RFBError) -> Bool {
        switch phase {
        case .version:
            guard available >= 12 else { return false }
            let line = String(decoding: bytes[head..<(head + 12)], as: UTF8.self)
            guard line.hasPrefix("RFB "), line.hasSuffix("\n"), let major = Int(line.dropFirst(4).prefix(3)),
                  let minorValue = Int(line.dropFirst(8).prefix(3)), major == 3 && minorValue >= 3 || major > 3 else { throw .badVersion }
            head += 12
            minor = major > 3 || minorValue >= 8 ? 8 : (minorValue == 7 ? 7 : 3)
            out.send.append(Data("RFB 003.00\(minor)\n".utf8))
            phase = minor == 3 ? .legacySecurity : .securityTypes
        case .securityTypes:
            guard available >= 1 else { return false }
            let count = u8(0)
            if count == 0 {
                head += 1
                phase = .failReason
                return true
            }
            guard available >= 1 + count else { return false }
            let offered = bytes[(head + 1)..<(head + 1 + count)]
            head += 1 + count
            guard offered.contains(1) else { throw .noSecurity }
            out.send.append(Data([1]))
            if minor == 8 { phase = .securityResult } else { clientInit(&out) }
        case .legacySecurity:
            guard available >= 4 else { return false }
            let kind = u32(0)
            head += 4
            if kind == 0 { phase = .failReason; return true }
            guard kind == 1 else { throw .noSecurity }
            clientInit(&out)
        case .securityResult:
            guard available >= 4 else { return false }
            let result = u32(0)
            head += 4
            if result != 0 { phase = .failReason; return true }
            clientInit(&out)
        case .failReason:
            guard available >= 4 else { return false }
            let length = u32(0)
            guard length <= 4096 else { throw .securityFailed("") }
            guard available >= 4 + length else { return false }
            let reason = String(decoding: bytes[(head + 4)..<(head + 4 + length)], as: UTF8.self)
            head += 4 + length
            throw .securityFailed(reason)
        case .serverInit:
            guard available >= 24 else { return false }
            let width = u16(0), height = u16(2), length = u32(20)
            guard length <= 4096 else { throw .tooLong }
            guard available >= 24 + length else { return false }
            name = String(decoding: bytes[(head + 24)..<(head + 24 + length)], as: UTF8.self)
            head += 24 + length
            guard let buffer = ScreenFramebuffer(width: width, height: height) else { throw .badSize }
            framebuffer = buffer
            out.ready = true
            out.send.append(RFBMessage.setPixelFormat())
            out.send.append(RFBMessage.setEncodings())
            out.send.append(RFBMessage.updateRequest(incremental: false, width: width, height: height))
            phase = .message
        case .message:
            guard available >= 1 else { return false }
            switch u8(0) {
            case 0:
                guard available >= 4 else { return false }
                rectsLeft = u16(2)
                head += 4
                if rectsLeft == 0 { out.updates += 1 } else { midUpdate = true; phase = .rect }
            case 1:                                     // SetColourMapEntries: skipped
                guard available >= 6 else { return false }
                let count = u16(4)
                head += 6
                phase = .skip(count * 6)
            case 2:                                     // Bell
                head += 1
            case 3:                                     // ServerCutText: skipped (the phone never copies the remote clipboard)
                guard available >= 8 else { return false }
                let length = u32(4)
                guard length <= Self.maxSkip else { throw .tooLong }
                head += 8
                phase = .skip(length)
            default:
                throw .unknownMessage(UInt8(u8(0)))
            }
        case .skip(let left):
            if left == 0 { phase = .message; return true }
            guard available > 0 else { return false }
            let taken = min(left, available)
            head += taken
            phase = taken == left ? .message : .skip(left - taken)
        case .rect:
            return try rect(&out)
        case .rawRows(let x, let y, let w, let h, let row):
            let rowBytes = w * 4
            if rowBytes == 0 || row >= h { endRect(&out); return true }
            let rows = min(h - row, available / rowBytes)
            guard rows > 0, let buffer = framebuffer else { return false }
            bytes.withUnsafeBufferPointer { buffer.writeRaw(x: x, y: y + row, w: w, rows: rows, from: $0.baseAddress! + head) }
            head += rows * rowBytes
            if row + rows >= h { endRect(&out) } else { phase = .rawRows(x: x, y: y, w: w, h: h, row: row + rows) }
        }
        return true
    }

    private func clientInit(_ out: inout Output) {
        out.send.append(Data([1]))                      // shared, as noVNC asks
        phase = .serverInit
    }

    private func endRect(_ out: inout Output) {
        out.rects += 1
        rectsLeft -= 1
        if rectsLeft <= 0 { endUpdate(&out) } else { phase = .rect }
    }

    private func endUpdate(_ out: inout Output) {
        rectsLeft = 0
        midUpdate = false
        out.updates += 1
        phase = .message
    }

    private func rect(_ out: inout Output) throws(RFBError) -> Bool {
        guard available >= 12, let buffer = framebuffer else { return false }
        let x = u16(0), y = u16(2), w = u16(4), h = u16(6)
        let encoding = Int32(truncatingIfNeeded: u32(8))
        switch encoding {
        case -224:                                      // LastRect
            head += 12
            out.rects += 1
            endUpdate(&out)
            return true
        case -223, -308:                                // DesktopSize / ExtendedDesktopSize
            var extra = 0
            if encoding == -308 {
                guard available >= 16 else { return false }
                extra = 4 + 16 * u8(12)
                guard available >= 12 + extra else { return false }
            }
            head += 12 + extra
            // An ExtendedDesktopSize that answers a request of ours with an error (y != 0) changes nothing.
            if !(encoding == -308 && y != 0), w != buffer.width || h != buffer.height {
                guard let resized = ScreenFramebuffer(width: w, height: h) else { throw .badSize }
                framebuffer = resized
                out.resized = true
            }
            endRect(&out)
            return true
        default:
            break
        }
        guard buffer.contains(x: x, y: y, w: w, h: h) else { throw .rectOutside }
        switch encoding {
        case 0:
            head += 12
            phase = .rawRows(x: x, y: y, w: w, h: h, row: 0)
            return true
        case 1:
            guard available >= 16 else { return false }
            let fromX = u16(12), fromY = u16(14)
            guard buffer.contains(x: fromX, y: fromY, w: w, h: h) else { throw .rectOutside }
            head += 16
            buffer.copyRect(x: x, y: y, w: w, h: h, fromX: fromX, fromY: fromY)
            endRect(&out)
            return true
        case 7:
            return try tight(&out, buffer, x: x, y: y, w: w, h: h)
        default:
            throw .unknownEncoding(encoding)
        }
    }

    /// Tight's 1–3 byte length at `offset`: (value, bytes used), nil when it has not all arrived.
    private func compact(_ offset: Int) -> (Int, Int)? {
        guard available > offset else { return nil }
        var value = u8(offset) & 0x7F
        guard u8(offset) & 0x80 != 0 else { return (value, 1) }
        guard available > offset + 1 else { return nil }
        value |= (u8(offset + 1) & 0x7F) << 7
        guard u8(offset + 1) & 0x80 != 0 else { return (value, 2) }
        guard available > offset + 2 else { return nil }
        return (value | u8(offset + 2) << 14, 3)
    }

    private func tight(_ out: inout Output, _ buffer: ScreenFramebuffer, x: Int, y: Int, w: Int, h: Int) throws(RFBError) -> Bool {
        guard available >= 13 else { return false }
        let control = u8(12)
        let kind = control >> 4
        var at = 13
        if kind == 8 {                                  // Fill
            guard available >= at + 3 else { return false }
            resetStreams(control)
            buffer.fill(x: x, y: y, w: w, h: h, r: bytes[head + at], g: bytes[head + at + 1], b: bytes[head + at + 2])
            head += at + 3
            endRect(&out)
            return true
        }
        if kind == 9 {                                  // JPEG
            guard let (length, used) = compact(at) else { return false }
            guard length <= Self.maxTight else { throw .tooLong }
            at += used
            guard available >= at + length else { return false }
            resetStreams(control)
            let ok = buffer.drawJPEG(Data(bytes[(head + at)..<(head + at + length)]), x: x, y: y, w: w, h: h)
            head += at + length
            if ok { jpegRun = 0 } else {
                jpegRun += 1
                failedJPEGs += 1
                if jpegRun >= 3 { throw .badJPEGs }
            }
            endRect(&out)
            return true
        }
        guard kind < 8 else { throw .badFilter }
        // Basic: stream in bits 4–5, bit 6 = an explicit filter byte.
        let stream = kind & 3
        var filter = 0
        var palette: [UInt8] = []
        if kind & 4 != 0 {
            guard available >= at + 1 else { return false }
            filter = u8(at)
            at += 1
        }
        var size = w * h * 3
        switch filter {
        case 0, 2: break
        case 1:
            guard available >= at + 1 else { return false }
            let colours = u8(at) + 1
            guard colours >= 2 else { throw .badFilter }
            guard available >= at + 1 + colours * 3 else { return false }
            palette = Array(bytes[(head + at + 1)..<(head + at + 1 + colours * 3)])
            at += 1 + colours * 3
            size = colours == 2 ? (w + 7) / 8 * h : w * h
        default: throw .badFilter
        }
        let data: [UInt8]
        if size < 12 {
            guard available >= at + size else { return false }
            resetStreams(control)
            data = Array(bytes[(head + at)..<(head + at + size)])
            at += size
        } else {
            guard let (length, used) = compact(at) else { return false }
            guard length <= Self.maxTight else { throw .tooLong }
            at += used
            guard available >= at + length else { return false }
            resetStreams(control)
            let start = head + at
            var inflated: Result<[UInt8], RFBError> = .failure(.zlib)
            bytes.withUnsafeBufferPointer { all in
                let input = UnsafeBufferPointer(rebasing: all[start..<(start + length)])
                do throws(RFBError) { inflated = .success(try streams.inflate(stream, input: input, count: size)) } catch { inflated = .failure(error) }
            }
            data = try inflated.get()
            at += length
        }
        head += at
        let rgb: [UInt8]
        switch filter {
        case 1:
            guard let mapped = TightFilter.palette(data, palette: palette, w: w, h: h) else { throw .badFilter }
            rgb = mapped
        case 2: rgb = TightFilter.gradient(data, w: w, h: h)
        default: rgb = data
        }
        if w > 0, h > 0 { rgb.withUnsafeBufferPointer { buffer.writeRGB(x: x, y: y, w: w, h: h, from: $0.baseAddress!) } }
        endRect(&out)
        return true
    }

    /// The control byte's low four bits reset zlib streams 0–3 (applied once the whole rect has arrived).
    private func resetStreams(_ control: Int) {
        for index in 0..<4 where control & (1 << index) != 0 { streams.reset(index) }
    }
}
