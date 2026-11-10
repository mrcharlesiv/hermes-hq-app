// Bad data on the screen stream (docs/spec/3x-screen.md §9.4): every case ends in a typed error or is survived, never a
// crash, and never makes the parser hold more than its caps. The same cases are sent by the stand-in gateway
// (`stream {garbage: <name>}`) in ScreenLiveWireTests.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct RFBBadDataTests {
    private let start = RFBBuild.preamble(width: 64, height: 64)
    private let junk = Data((0..<600).map { UInt8(($0 * 131 + 7) % 251) })

    private func fails(_ data: Data, _ expected: RFBError, _ name: Comment) {
        #expect(RFBFeed.error(data) == expected, name)
        #expect(RFBFeed.error(data, chunk: 1) == expected, name)
    }

    @Test func badVersion() {
        fails(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8), .badVersion, "an HTTP answer instead of RFB")
        fails(Data("RFB 00x.008\n".utf8), .badVersion, "not a number")
        #expect(RFBFeed.error(Data("RFB 003".utf8)) == nil, "not enough bytes yet is not an error")
    }

    @Test func securityNoneMissing() {
        fails(Data("RFB 003.008\n".utf8) + Data([1, 2]), .noSecurity, "only VNC password offered")
        fails(Data("RFB 003.008\n".utf8) + Data([3, 2, 16, 19]), .noSecurity, "three schemes, none of them None")
    }

    @Test func securityFailed() {
        let reason = Array("Too many viewers".utf8)
        fails(Data("RFB 003.008\n".utf8) + Data([1, 1]) + Data(RFBBuild.be32(1) + RFBBuild.be32(reason.count) + reason), .securityFailed("Too many viewers"), "result 1")
        fails(Data("RFB 003.008\n".utf8) + Data([1, 1]) + Data(RFBBuild.be32(1) + RFBBuild.be32(1_000_000)), .securityFailed(""), "a reason too long to be one")
    }

    @Test func zeroAndHugeSizes() {
        let head = Data("RFB 003.008\n".utf8) + Data([1, 1]) + Data(RFBBuild.be32(0))
        fails(head + RFBBuild.serverInit(width: 0, height: 0), .badSize, "0 × 0")
        fails(head + RFBBuild.serverInit(width: 65535, height: 65535), .badSize, "65535 × 65535")
        fails(head + RFBBuild.serverInit(width: 6016, height: 3384), .badSize, "over 64 MB")
        fails(head + Data(RFBBuild.be16(64) + RFBBuild.be16(64)) + Data(count: 16) + Data(RFBBuild.be32(1_000_000)), .tooLong, "a desktop name of 1 MB")
        fails(start + RFBBuild.update([RFBBuild.desktopSize(0, 0)]), .badSize, "a resize to nothing")
        fails(start + RFBBuild.update([RFBBuild.extendedDesktopSize(9000, 9000)]), .badSize, "a resize past the limit")
    }

    @Test func rectOutside() {
        fails(start + RFBBuild.update([RFBBuild.raw(54, 0, 64, 4, b: 0, g: 0, r: 0)]), .rectOutside, "raw")
        fails(start + RFBBuild.update([RFBBuild.tightFill(0, 60, 8, 8, r: 0, g: 0, b: 0)]), .rectOutside, "fill")
        fails(start + RFBBuild.update([RFBBuild.copyRect(0, 0, 32, 32, fromX: 56, fromY: 56)]), .rectOutside, "copyrect source")
        fails(start + RFBBuild.update([RFBBuild.copyRect(56, 56, 32, 32, fromX: 0, fromY: 0)]), .rectOutside, "copyrect target")
    }

    @Test func unknownEncodingAndMessage() {
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 16, 16, 16) + junk.prefix(64)]), .unknownEncoding(16), "ZRLE was never asked for")
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 16, 16, -239) + junk.prefix(64)]), .unknownEncoding(-239), "Cursor was never asked for")
        fails(start + Data([9]) + junk.prefix(32), .unknownMessage(9), "type 9")
        fails(start + Data([150, 0, 0, 0]), .unknownMessage(150), "EndOfContinuousUpdates was never asked for")
    }

    /// Tight's compact length is 22 bits at most (4 MiB - 1), which is exactly the cap: the largest length that can be
    /// declared is waited for, not refused, and the stream's stuck rule (no bytes for 8 s mid-update) ends it.
    @Test func tightLengthOverflow() throws {
        #expect(RFBParser.maxTight == 4 * 1024 * 1024)
        for control: UInt8 in [0x00, 0x90] {
            let parser = RFBParser()
            let out = try RFBFeed.run(parser, start + RFBBuild.update([RFBBuild.rect(0, 0, 64, 64, 7) + Data([control, 0xFF, 0xFF, 0xFF])]) + junk, chunk: 1)
            #expect(out.updates == 0 && parser.midUpdate, "control \(control)")
        }
    }

    @Test func zlibGarbageAndTruncated() {
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 64, 64, 7) + Data([0x00] + RFBBuild.compact(junk.count)) + junk]), .zlib, "not a zlib stream")
        let packed = RFBBuild.deflate([UInt8](repeating: 0, count: 64 * 64 * 3)).prefix(9)
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 64, 64, 7) + Data([0x0F] + RFBBuild.compact(packed.count)) + packed]), .zlib, "a stream cut short")
        let long = RFBBuild.deflate([UInt8](repeating: 3, count: 64 * 64 * 3 + 300))
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 64, 64, 7) + Data([0x01] + RFBBuild.compact(long.count)) + long]), .zlib, "more pixels than the rect holds")
    }

    @Test func oneBadJPEGIsSurvivedThreeInARowEndTheStream() throws {
        let bad = RFBBuild.update([RFBBuild.tightJPEG(0, 0, 64, 64, junk)])
        let good = RFBBuild.update([RFBBuild.tightJPEG(0, 0, 64, 64, ScreenTestImage.jpeg(width: 64, height: 64, r: 0, g: 1, b: 0))])
        let parser = RFBParser()
        let out = try RFBFeed.run(parser, start + bad + bad + good + bad + bad)
        #expect(out.updates == 5 && parser.failedJPEGs == 4, "a good one resets the run")
        #expect(try #require(parser.framebuffer).pixel(x: 30, y: 30).g > 200)
        fails(start + bad + bad + bad, .badJPEGs, "three in a row")
        // A real JPEG header followed by rubbish is the same failure, not a crash in the decoder.
        fails(start + Array(repeating: RFBBuild.update([RFBBuild.tightJPEG(0, 0, 64, 64, Data([0xFF, 0xD8, 0xFF, 0xE0]) + junk)]), count: 3).reduce(Data(), +), .badJPEGs, "header then rubbish")
    }

    @Test func paletteZeroAndBadFilters() {
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 8, 8, 7) + Data([0x40, 1, 0, 1, 2, 3]) + Data(count: 8)]), .badFilter, "a palette of one colour")
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 8, 8, 7) + Data([0x40, 9])]), .badFilter, "filter 9")
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 8, 8, 7) + Data([0xA0, 0, 0, 0])]), .badFilter, "Tight PNG was never asked for")
        // An index past the palette: three colours, index 7.
        let indices = RFBBuild.deflate([UInt8](repeating: 7, count: 64))
        fails(start + RFBBuild.update([RFBBuild.rect(0, 0, 8, 8, 7) + Data([0x41, 1, 2, 1, 1, 1, 2, 2, 2, 3, 3, 3] + RFBBuild.compact(indices.count)) + indices]), .badFilter, "index past the palette")
    }

    @Test func cutTextHugeIsRefusedAndASmallOneSkipped() throws {
        fails(start + Data([3, 0, 0, 0] + RFBBuild.be32(512 * 1024 * 1024)) + junk, .tooLong, "512 MiB declared")
        let parser = RFBParser()
        let big = Data([3, 0, 0, 0] + RFBBuild.be32(300_000)) + Data(count: 300_000)
        let out = try RFBFeed.run(parser, start + big + RFBBuild.update([RFBBuild.tightFill(0, 0, 4, 4, r: 1, g: 1, b: 1)]), chunk: 4096)
        #expect(out.updates == 1, "skipped without being kept")
    }

    @Test func colourMapHugeIsSkipped() throws {
        let parser = RFBParser()
        let map = Data([1, 0] + RFBBuild.be16(0) + RFBBuild.be16(65535)) + Data(count: 6 * 65535)
        let out = try RFBFeed.run(parser, start + map + RFBBuild.update([RFBBuild.tightFill(0, 0, 4, 4, r: 1, g: 1, b: 1)]), chunk: 10_000)
        #expect(out.updates == 1)
    }

    @Test func trailingBellsAfterAnUpdateAreIgnored() throws {
        let parser = RFBParser()
        let out = try RFBFeed.run(parser, start + RFBBuild.update([RFBBuild.tightFill(0, 0, 4, 4, r: 1, g: 1, b: 1)]) + Data([2, 2, 2]))
        #expect(out.updates == 1 && !parser.midUpdate)
    }

    /// 65,535 one-pixel rects with no LastRect: the count runs down and the update ends.
    @Test func aNeverEndingUpdateEndsWhenItsCountRunsOut() throws {
        let parser = RFBParser()
        var data = Data([0, 0, 0xFF, 0xFF])
        for i in 0..<65_535 { data += RFBBuild.tightFill(i % 64, (i / 64) % 64, 1, 1, r: 0x10, g: 0x20, b: 0x30) }
        let out = try RFBFeed.run(parser, start + data, chunk: 65_536)
        #expect(out.updates == 1 && out.rects == 65_535 && !parser.midUpdate)
        #expect(try #require(parser.framebuffer).pixel(x: 5, y: 5).g == 0x20)
        // With LastRect the same count ends early.
        let early = RFBParser()
        let short = try RFBFeed.run(early, start + Data([0, 0, 0xFF, 0xFF]) + RFBBuild.tightFill(0, 0, 1, 1, r: 1, g: 1, b: 1) + RFBBuild.lastRect() + Data([2]))
        #expect(short.updates == 1 && !early.midUpdate)
    }

    /// A rect waits for the bytes it declared (at most 4 MiB) and nothing else: an unfinished one is not an error, and
    /// what was skipped or decoded is not kept.
    @Test func anUnfinishedRectWaitsWithoutAnError() throws {
        let parser = RFBParser()
        let out = try RFBFeed.run(parser, start + Data([0, 0, 0, 1]) + RFBBuild.rect(0, 0, 64, 64, 7) + Data([0x90, 0xFF, 0xFF, 0x7E]) + Data(count: 1_000_000))
        #expect(out.updates == 0 && parser.midUpdate)
        #expect(RFBParser.maxBuffer == 16 * 1024 * 1024 && RFBParser.maxSkip == 16 * 1024 * 1024)
    }

    @Test func nothingIsFedAfterAnErrorWithoutThrowingAgainOrCrashing() {
        let parser = RFBParser()
        #expect(throws: RFBError.self) { try parser.feed(self.start + Data([9])) }
        #expect(throws: RFBError.self) { try parser.feed(Data([0, 0, 0, 0])) }
    }
}
