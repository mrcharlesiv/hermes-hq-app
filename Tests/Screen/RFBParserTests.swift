// The native RFB client's parser and decoders (HermesKit/Screen/RFBProtocol.swift, RFBDecoders.swift): the handshake
// for 3.8 / 3.7 / 3.3, what it sends, the skipped server messages, the decoder vectors written by the fixture's own
// encoder (`screen-gateway.py --emit-vectors`), feeding one byte at a time, and what the Mac helper sends (L520).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct RFBParserTests {
    @Test func handshake38SendsVersionSecurityInitFormatEncodingsAndAFullRequest() throws {
        let parser = RFBParser()
        let out = try RFBFeed.run(parser, RFBBuild.preamble(width: 1280, height: 800))
        #expect(out.ready && parser.name == "This Mac")
        #expect(parser.framebuffer?.width == 1280 && parser.framebuffer?.height == 800)
        #expect(out.send.count == 6)
        #expect(out.send[0] == Data("RFB 003.008\n".utf8))
        #expect(out.send[1] == Data([1]), "security None")
        #expect(out.send[2] == Data([1]), "ClientInit, shared")
        #expect(out.send[3] == Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
        #expect(out.send[4] == Data([2, 0, 0, 8, 0, 0, 0, 7, 0, 0, 0, 1, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xE7, 0xFF, 0xFF, 0xFF, 0x02,
                                     0xFF, 0xFF, 0xFF, 0x20, 0xFF, 0xFF, 0xFF, 0x21, 0xFF, 0xFF, 0xFE, 0xCC]))
        #expect(out.send[5] == Data([3, 0, 0, 0, 0, 0, 0x05, 0x00, 0x03, 0x20]), "not incremental, the whole 1280×800")
    }

    @Test func theEncodingsListIsExactlyTheEightAllowed() {
        #expect(RFBMessage.encodings == [7, 1, 0, -25, -254, -224, -223, -308])
        for forbidden: Int32 in [-239, -316, -309, -313, -312, 50] { #expect(!RFBMessage.encodings.contains(forbidden)) }
    }

    @Test func handshake37HasNoSecurityResult() throws {
        let parser = RFBParser()
        let stream = Data("RFB 003.007\n".utf8) + Data([2, 2, 1]) + RFBBuild.serverInit(width: 64, height: 48, name: "fixture:7")
        let out = try RFBFeed.run(parser, stream)
        #expect(out.ready && parser.name == "fixture:7")
        #expect(out.send[0] == Data("RFB 003.007\n".utf8) && out.send[1] == Data([1]) && out.send[2] == Data([1]))
    }

    @Test func handshake33TakesTheServersChoice() throws {
        let parser = RFBParser()
        let stream = Data("RFB 003.003\n".utf8) + Data(RFBBuild.be32(1)) + RFBBuild.serverInit(width: 64, height: 48)
        let out = try RFBFeed.run(parser, stream)
        #expect(out.ready)
        #expect(out.send[0] == Data("RFB 003.003\n".utf8) && out.send[1] == Data([1]), "no security byte in 3.3: ClientInit only")
        #expect(RFBFeed.error(Data("RFB 003.003\n".utf8) + Data(RFBBuild.be32(2))) == .noSecurity, "VNC password")
        let reason = Array("Too many".utf8)
        #expect(RFBFeed.error(Data("RFB 003.003\n".utf8) + Data(RFBBuild.be32(0) + RFBBuild.be32(reason.count) + reason)) == .securityFailed("Too many"))
    }

    @Test func aNewerServerIsAnsweredWith38() throws {
        let out = try RFBFeed.run(RFBParser(), Data("RFB 003.889\n".utf8))
        #expect(out.send == [Data("RFB 003.008\n".utf8)])
        #expect(RFBFeed.error(Data("RFB 003.002\n".utf8)) == .badVersion)
    }

    @Test func aSecurityFailureCarriesItsReason() {
        let reason = Array("Too many viewers".utf8)
        let failed = Data("RFB 003.008\n".utf8) + Data([1, 1]) + Data(RFBBuild.be32(1) + RFBBuild.be32(reason.count) + reason)
        #expect(RFBFeed.error(failed) == .securityFailed("Too many viewers"))
        #expect(RFBFeed.error(failed, chunk: 1) == .securityFailed("Too many viewers"))
        let none = Data("RFB 003.008\n".utf8) + Data([0]) + Data(RFBBuild.be32(4) + Array("busy".utf8))
        #expect(RFBFeed.error(none) == .securityFailed("busy"))
    }

    @Test func colourMapBellAndCutTextAreSkipped() throws {
        let parser = RFBParser()
        var stream = RFBBuild.preamble(width: 16, height: 16)
        stream += Data([1, 0] + RFBBuild.be16(0) + RFBBuild.be16(3)) + Data(count: 18)
        stream += Data([2])
        stream += Data([3, 0, 0, 0] + RFBBuild.be32(5)) + Data("hello".utf8)
        stream += RFBBuild.update([RFBBuild.tightFill(0, 0, 16, 16, r: 10, g: 20, b: 30)])
        stream += Data([2, 2])
        let out = try RFBFeed.run(parser, stream, chunk: 3)
        #expect(out.updates == 1 && out.rects == 1 && !parser.midUpdate)
        let pixel = try #require(parser.framebuffer).pixel(x: 8, y: 8)
        #expect(pixel.r == 10 && pixel.g == 20 && pixel.b == 30)
    }

    @Test func midUpdateIsTrueOnlyBetweenAnUpdatesFirstAndLastByte() throws {
        let parser = RFBParser()
        try RFBFeed.run(parser, RFBBuild.preamble(width: 16, height: 16))
        let update = RFBBuild.update([RFBBuild.raw(0, 0, 16, 16, b: 1, g: 2, r: 3)])
        _ = try parser.feed(update.prefix(40))
        #expect(parser.midUpdate)
        let rest = try parser.feed(update.dropFirst(40))
        #expect(!parser.midUpdate && rest.updates == 1)
    }

    @Test func anEmptyUpdateCompletesAtOnce() throws {
        let parser = RFBParser()
        let out = try RFBFeed.run(parser, RFBBuild.preamble(width: 16, height: 16) + RFBBuild.update([]))
        #expect(out.updates == 1 && out.rects == 0 && !parser.midUpdate)
    }

    @Test func clientMessagesHaveTheGatewaysFraming() {
        #expect(RFBMessage.key(0xFF0D, down: true) == Data([4, 1, 0, 0, 0, 0, 0xFF, 0x0D]))
        #expect(RFBMessage.key(0x61, down: false) == Data([4, 0, 0, 0, 0, 0, 0, 0x61]))
        #expect(RFBMessage.pointer(mask: 1, x: 640, y: 400) == Data([5, 1, 0x02, 0x80, 0x01, 0x90]))
        #expect(RFBMessage.pointer(mask: 0, x: -5, y: 70_000) == Data([5, 0, 0, 0, 0xFF, 0xFF]), "clamped, never wrapped")
        #expect(RFBMessage.cutText([0x68, 0x69]) == Data([6, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69]))
        #expect(RFBMessage.updateRequest(incremental: true, width: 1920, height: 1080) == Data([3, 1, 0, 0, 0, 0, 0x07, 0x80, 0x04, 0x38]))
        let sent: Set<UInt8> = [RFBMessage.setPixelFormat()[0], RFBMessage.setEncodings()[0], RFBMessage.updateRequest(incremental: true, width: 1, height: 1)[0],
                                RFBMessage.key(1, down: true)[0], RFBMessage.pointer(mask: 0, x: 0, y: 0)[0], RFBMessage.cutText([])[0]]
        #expect(sent == [0, 2, 3, 4, 5, 6])
    }
}

@MainActor
struct RFBDecoderTests {
    @Test func everyVectorDecodesToItsExpectedPicture() throws {
        let vectors = try ScreenVector.all()
        #expect(vectors.count >= 13)
        for vector in vectors {
            let parser = RFBParser()
            let out = try RFBFeed.run(parser, vector.stream)
            let buffer = try #require(parser.framebuffer, "\(vector.name)")
            #expect(out.ready && out.updates >= 1 && !parser.midUpdate, "\(vector.name)")
            #expect(buffer.width == vector.width && buffer.height == vector.height, "\(vector.name)")
            if let expected = vector.expected {
                #expect(buffer.bgr() == expected, "\(vector.name): \(vector.note)")
            }
            for sample in vector.samples ?? [] {
                let pixel = buffer.pixel(x: sample[0], y: sample[1])
                let off = max(abs(Int(pixel.b) - sample[2]), abs(Int(pixel.g) - sample[3]), abs(Int(pixel.r) - sample[4]))
                #expect(off <= (vector.tolerance ?? 0), "\(vector.name) at \(sample[0]),\(sample[1]): off by \(off)")
            }
        }
    }

    /// RFB messages do not line up with WebSocket frames: any split must give the same picture.
    @Test func oneByteAtATimeGivesTheSamePictureAsOneBuffer() throws {
        for vector in try ScreenVector.all() where vector.stream.count < 400_000 {
            let whole = RFBParser(), single = RFBParser(), sevens = RFBParser()
            let a = try RFBFeed.run(whole, vector.stream)
            let b = try RFBFeed.run(single, vector.stream, chunk: 1)
            let c = try RFBFeed.run(sevens, vector.stream, chunk: 7)
            #expect(a == b && a == c, "\(vector.name)")
            #expect(whole.framebuffer?.bgr() == single.framebuffer?.bgr(), "\(vector.name)")
            #expect(whole.framebuffer?.bgr() == sevens.framebuffer?.bgr(), "\(vector.name)")
        }
    }

    @Test func theNamedVectorsCoverEveryDecoder() throws {
        let names = Set(try ScreenVector.all().map(\.name))
        for needed in ["raw", "copyrect-overlap", "tight-fill", "tight-copy", "tight-palette", "tight-gradient", "tight-reset", "tight-long",
                       "desktop-size", "ext-desktop-size", "last-rect", "skipped-messages", "tight-jpeg"] {
            #expect(names.contains(needed), "\(needed)")
        }
    }

    @Test func copyRectMovesOverlappingRowsWithoutSmearing() throws {
        let buffer = try #require(ScreenFramebuffer(width: 8, height: 8))
        for y in 0..<8 { buffer.fill(x: 0, y: y, w: 8, h: 1, r: UInt8(y * 10), g: 0, b: 0) }
        buffer.copyRect(x: 0, y: 2, w: 8, h: 5, fromX: 0, fromY: 0)             // down by two, overlapping
        #expect((0..<8).map { buffer.pixel(x: 3, y: $0).r } == [0, 10, 0, 10, 20, 30, 40, 70])
        buffer.copyRect(x: 0, y: 0, w: 8, h: 5, fromX: 0, fromY: 2)             // back up
        #expect((0..<8).map { buffer.pixel(x: 3, y: $0).r } == [0, 10, 20, 30, 40, 30, 40, 70])
    }

    @Test func zlibStateCarriesAcrossRectsAndAResetStartsAFreshStream() throws {
        let parser = RFBParser()
        let red = [UInt8](repeating: 0, count: 16 * 16 * 3).enumerated().map { $0.offset % 3 == 0 ? UInt8(200) : UInt8(0) }
        let blue = [UInt8](repeating: 0, count: 16 * 16 * 3).enumerated().map { $0.offset % 3 == 2 ? UInt8(180) : UInt8(0) }
        // One deflate stream cut in two with a sync flush: the second rect continues the first one's stream.
        var stream = z_streamCompress([red, blue])
        let first = RFBBuild.rect(0, 0, 16, 16, 7) + Data([0x10] + RFBBuild.compact(stream[0].count)) + stream[0]
        let second = RFBBuild.rect(16, 0, 16, 16, 7) + Data([0x10] + RFBBuild.compact(stream[1].count)) + stream[1]
        try RFBFeed.run(parser, RFBBuild.preamble(width: 32, height: 16) + RFBBuild.update([first]) + RFBBuild.update([second]), chunk: 5)
        var buffer = try #require(parser.framebuffer)
        #expect(buffer.pixel(x: 4, y: 4).r == 200 && buffer.pixel(x: 20, y: 4).b == 180 && buffer.pixel(x: 20, y: 4).r == 0)
        // A reset bit: the same stream id starts over with a fresh deflate stream.
        stream = z_streamCompress([blue])
        let fresh = RFBBuild.rect(0, 0, 16, 16, 7) + Data([0x12] + RFBBuild.compact(stream[0].count)) + stream[0]
        try RFBFeed.run(parser, RFBBuild.update([fresh]))
        buffer = try #require(parser.framebuffer)
        #expect(buffer.pixel(x: 4, y: 4).b == 180 && buffer.pixel(x: 4, y: 4).r == 0)
    }

    @Test func aFramebufferOutsideTheLimitsIsRefused() {
        #expect(ScreenFramebuffer(width: 0, height: 0) == nil)
        #expect(ScreenFramebuffer(width: 8193, height: 10) == nil)
        #expect(ScreenFramebuffer(width: 6016, height: 3384) == nil, "81 MB")
        #expect(ScreenFramebuffer.allowed(width: 5120, height: 2880), "59 MB")
        #expect(!ScreenFramebuffer.allowed(width: 8192, height: 8192))
    }

    @Test func theProbeReadsFivePointsAsHexBGR() throws {
        let buffer = try #require(ScreenFramebuffer(width: 40, height: 40))
        buffer.fill(x: 0, y: 0, w: 40, h: 40, r: 0x11, g: 0x22, b: 0x33)
        buffer.fill(x: 20, y: 20, w: 1, h: 1, r: 0xAA, g: 0xBB, b: 0xCC)
        #expect(buffer.probe() == "332211" + "332211" + "ccbbaa" + "332211" + "332211")
    }
}

/// Deflates each part into the same zlib stream, sync-flushed after each (how Tight's streams are fed).
private func z_streamCompress(_ parts: [[UInt8]]) -> [Data] {
    RFBTestDeflater().run(parts)
}

@MainActor
struct RFBHelperConformanceTests {
    // What "Hermes HQ Screen" on the Mac serves (docs/spec/3x-screen.md §5.15 acceptance 2): ServerInit named
    // "This Mac", Tight Fill, Tight JPEG, Raw, and a resize by -308 or -223.

    @Test func serverInitNamedThisMacThenFillRawAndJPEG() throws {
        let parser = RFBParser()
        let small = ScreenTestImage.jpeg(width: 64, height: 64, r: 0.9, g: 0.1, b: 0.1)                      // 2-byte length
        let large = ScreenTestImage.jpeg(width: 256, height: 256, r: 0.5, g: 0.5, b: 0.5, noise: true)        // 3-byte length
        #expect((128..<16_384).contains(small.count) && large.count >= 16_384)
        let stream = RFBBuild.preamble(width: 640, height: 400) + RFBBuild.update([
            RFBBuild.tightFill(0, 0, 640, 400, r: 12, g: 34, b: 56),
            RFBBuild.raw(100, 100, 32, 16, b: 7, g: 8, r: 9),
            RFBBuild.tightJPEG(200, 40, 64, 64, small),
            RFBBuild.tightJPEG(320, 40, 256, 256, large),
        ])
        for chunk in [Int.max, 1, 4096] {
            let each = RFBParser()
            let out = try RFBFeed.run(each, stream, chunk: chunk)
            #expect(out.ready && out.updates == 1 && out.rects == 4 && each.name == "This Mac" && each.failedJPEGs == 0, "chunk \(chunk)")
        }
        try RFBFeed.run(parser, stream)
        let buffer = try #require(parser.framebuffer)
        let fill = buffer.pixel(x: 5, y: 300)
        #expect(fill.r == 12 && fill.g == 34 && fill.b == 56)
        let raw = buffer.pixel(x: 110, y: 110)
        #expect(raw.r == 9 && raw.g == 8 && raw.b == 7)
        let red = buffer.pixel(x: 230, y: 70)
        #expect(red.r > 200 && red.g < 60 && red.b < 60, "the JPEG lands where the rect says, the right way up")
        let edge = buffer.pixel(x: 199, y: 70)
        #expect(edge.r == 12, "nothing drawn outside the rect")
    }

    /// A JPEG under 128 bytes cannot exist, so the 1-byte length is proven with bytes that are not a JPEG: the length
    /// is read, the rect is left as it was, one failure is counted and the stream carries on.
    @Test func aOneByteJPEGLengthIsReadAndABadJPEGLeavesTheRectAlone() throws {
        let parser = RFBParser()
        let junk = Data((0..<100).map { UInt8(($0 * 131 + 7) % 251) })
        let stream = RFBBuild.preamble(width: 64, height: 64) + RFBBuild.update([RFBBuild.tightFill(0, 0, 64, 64, r: 1, g: 2, b: 3)])
            + RFBBuild.update([RFBBuild.tightJPEG(0, 0, 32, 32, junk)]) + RFBBuild.update([RFBBuild.tightFill(40, 40, 8, 8, r: 9, g: 9, b: 9)])
        let out = try RFBFeed.run(parser, stream, chunk: 1)
        #expect(out.updates == 3 && parser.failedJPEGs == 1)
        let buffer = try #require(parser.framebuffer)
        #expect(buffer.pixel(x: 10, y: 10).r == 1 && buffer.pixel(x: 44, y: 44).r == 9)
    }

    @Test func aResizeByEitherPseudoRectGivesANewBlackPictureAndAsksForAFullOne() throws {
        for extended in [true, false] {
            let parser = RFBParser()
            try RFBFeed.run(parser, RFBBuild.preamble(width: 64, height: 48) + RFBBuild.update([RFBBuild.tightFill(0, 0, 64, 48, r: 200, g: 200, b: 200)]))
            let resize = extended ? RFBBuild.extendedDesktopSize(96, 60) : RFBBuild.desktopSize(96, 60)
            let out = try RFBFeed.run(parser, RFBBuild.update([resize]), chunk: 1)
            let buffer = try #require(parser.framebuffer)
            #expect(out.resized && out.updates == 1 && buffer.width == 96 && buffer.height == 60, "extended \(extended)")
            #expect(buffer.pixel(x: 10, y: 10).r == 0, "the new picture starts black")
            let after = try RFBFeed.run(parser, RFBBuild.update([RFBBuild.tightFill(64, 48, 32, 12, r: 5, g: 6, b: 7)]))
            #expect(after.updates == 1 && !after.resized && parser.framebuffer?.pixel(x: 90, y: 55).g == 6)
        }
    }

    @Test func aRefusedResizeRequestChangesNothing() throws {
        let parser = RFBParser()
        try RFBFeed.run(parser, RFBBuild.preamble(width: 64, height: 48))
        let out = try RFBFeed.run(parser, RFBBuild.update([RFBBuild.extendedDesktopSize(10, 10, status: 1)]))
        #expect(!out.resized && parser.framebuffer?.width == 64)
        let same = try RFBFeed.run(parser, RFBBuild.update([RFBBuild.extendedDesktopSize(64, 48)]))
        #expect(!same.resized, "the same size is not a resize")
    }
}
