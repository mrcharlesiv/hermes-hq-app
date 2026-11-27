// [WIN-SCREEN-RFB-CORE] Bad data on the screen stream (docs/spec/3x-screen.md §9.4), ported case for case from the
// Mac's Tests/Screen/RFBBadDataTests.swift at 93f984bb1: every case ends in a typed error or is survived, never a
// crash, and never makes the parser hold more than its caps.

using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.RfbBuild;

namespace Hermes.Core.Tests.Screen;

public class RfbBadDataTests
{
    readonly byte[] start = Preamble(64, 64);
    readonly byte[] junk = Enumerable.Range(0, 600).Select(i => (byte)((i * 131 + 7) % 251)).ToArray();

    byte[] Junk(int count) => junk.Take(count).ToArray();

    static void Fails(byte[] data, RfbError expected, string name)
    {
        Assert.True(RfbFeed.Error(data) == expected, $"{name}: {RfbFeed.Error(data)}");
        Assert.True(RfbFeed.Error(data, chunk: 1) == expected, $"{name} (one byte at a time): {RfbFeed.Error(data, chunk: 1)}");
    }

    [Fact]
    public void BadVersion()
    {
        Fails(Ascii("HTTP/1.1 400 Bad Request\r\n\r\n"), RfbError.BadVersion, "an HTTP answer instead of RFB");
        Fails(Ascii("RFB 00x.008\n"), RfbError.BadVersion, "not a number");
        Assert.Null(RfbFeed.Error(Ascii("RFB 003")));                     // not enough bytes yet is not an error
    }

    [Fact]
    public void SecurityNoneMissing()
    {
        Fails(Cat(Ascii("RFB 003.008\n"), [1, 2]), RfbError.NoSecurity, "only VNC password offered");
        Fails(Cat(Ascii("RFB 003.008\n"), [3, 2, 16, 19]), RfbError.NoSecurity, "three schemes, none of them None");
    }

    [Fact]
    public void SecurityFailed()
    {
        var reason = Ascii("Too many viewers");
        Fails(Cat(Ascii("RFB 003.008\n"), [1, 1], Be32(1), Be32(reason.Length), reason), RfbError.SecurityFailed("Too many viewers"), "result 1");
        Fails(Cat(Ascii("RFB 003.008\n"), [1, 1], Be32(1), Be32(1_000_000)), RfbError.SecurityFailed(""), "a reason too long to be one");
    }

    [Fact]
    public void ZeroAndHugeSizes()
    {
        var head = Cat(Ascii("RFB 003.008\n"), [1, 1], Be32(0));
        Fails(Cat(head, ServerInit(0, 0)), RfbError.BadSize, "0 × 0");
        Fails(Cat(head, ServerInit(65535, 65535)), RfbError.BadSize, "65535 × 65535");
        Fails(Cat(head, ServerInit(6016, 3384)), RfbError.BadSize, "over 64 MB");
        Fails(Cat(head, Be16(64), Be16(64), Zeros(16), Be32(1_000_000)), RfbError.TooLong, "a desktop name of 1 MB");
        Fails(Cat(start, Update([DesktopSize(0, 0)])), RfbError.BadSize, "a resize to nothing");
        Fails(Cat(start, Update([ExtendedDesktopSize(9000, 9000)])), RfbError.BadSize, "a resize past the limit");
    }

    [Fact]
    public void RectOutside()
    {
        Fails(Cat(start, Update([Raw(54, 0, 64, 4, 0, 0, 0)])), RfbError.RectOutside, "raw");
        Fails(Cat(start, Update([TightFill(0, 60, 8, 8, 0, 0, 0)])), RfbError.RectOutside, "fill");
        Fails(Cat(start, Update([CopyRect(0, 0, 32, 32, fromX: 56, fromY: 56)])), RfbError.RectOutside, "copyrect source");
        Fails(Cat(start, Update([CopyRect(56, 56, 32, 32, fromX: 0, fromY: 0)])), RfbError.RectOutside, "copyrect target");
    }

    [Fact]
    public void UnknownEncodingAndMessage()
    {
        Fails(Cat(start, Update([Cat(Rect(0, 0, 16, 16, 16), Junk(64))])), RfbError.UnknownEncoding(16), "ZRLE was never asked for");
        Fails(Cat(start, Update([Cat(Rect(0, 0, 16, 16, -239), Junk(64))])), RfbError.UnknownEncoding(-239), "Cursor was never asked for");
        Fails(Cat(start, [9], Junk(32)), RfbError.UnknownMessage(9), "type 9");
        Fails(Cat(start, [150, 0, 0, 0]), RfbError.UnknownMessage(150), "EndOfContinuousUpdates was never asked for");
    }

    /// Tight's compact length is 22 bits at most (4 MiB - 1), which is exactly the cap: the largest length that can be
    /// declared is waited for, not refused, and the stream's stuck rule (no bytes for 8 s mid-update) ends it.
    [Fact]
    public void TightLengthOverflow()
    {
        Assert.Equal(4 * 1024 * 1024, RfbParser.MaxTight);
        foreach (var control in new byte[] { 0x00, 0x90 })
        {
            var parser = new RfbParser();
            var out_ = RfbFeed.Run(parser, Cat(start, Update([Cat(Rect(0, 0, 64, 64, 7), [control, 0xFF, 0xFF, 0xFF])]), junk), chunk: 1);
            Assert.True(out_.Updates == 0 && parser.MidUpdate, $"control {control}");
        }
    }

    [Fact]
    public void ZlibGarbageAndTruncated()
    {
        Fails(Cat(start, Update([Cat(Rect(0, 0, 64, 64, 7), [0x00], Compact(junk.Length), junk)])), RfbError.Zlib, "not a zlib stream");
        var packed = Deflate(new byte[64 * 64 * 3]).Take(9).ToArray();
        Fails(Cat(start, Update([Cat(Rect(0, 0, 64, 64, 7), [0x0F], Compact(packed.Length), packed)])), RfbError.Zlib, "a stream cut short");
        var long_ = Deflate(Enumerable.Repeat((byte)3, 64 * 64 * 3 + 300).ToArray());
        Fails(Cat(start, Update([Cat(Rect(0, 0, 64, 64, 7), [0x01], Compact(long_.Length), long_)])), RfbError.Zlib, "more pixels than the rect holds");
    }

    [Fact]
    public void OneBadJPEGIsSurvivedThreeInARowEndTheStream()
    {
        var bad = Update([TightJpeg(0, 0, 64, 64, junk)]);
        var good = Update([TightJpeg(0, 0, 64, 64, ScreenTestImage.Green64)]);
        var parser = new RfbParser();
        var out_ = RfbFeed.Run(parser, Cat(start, bad, bad, good, bad, bad));
        Assert.True(out_.Updates == 5 && parser.FailedJpegs == 4, "a good one resets the run");
        Assert.True(parser.Framebuffer!.Pixel(30, 30).G > 200);
        Fails(Cat(start, bad, bad, bad), RfbError.BadJpegs, "three in a row");
        // A real JPEG header followed by rubbish is the same failure, not a crash in the decoder.
        var rubbish = Update([TightJpeg(0, 0, 64, 64, Cat([0xFF, 0xD8, 0xFF, 0xE0], junk))]);
        Fails(Cat(start, rubbish, rubbish, rubbish), RfbError.BadJpegs, "header then rubbish");
    }

    [Fact]
    public void PaletteZeroAndBadFilters()
    {
        Fails(Cat(start, Update([Cat(Rect(0, 0, 8, 8, 7), [0x40, 1, 0, 1, 2, 3], Zeros(8))])), RfbError.BadFilter, "a palette of one colour");
        Fails(Cat(start, Update([Cat(Rect(0, 0, 8, 8, 7), [0x40, 9])])), RfbError.BadFilter, "filter 9");
        Fails(Cat(start, Update([Cat(Rect(0, 0, 8, 8, 7), [0xA0, 0, 0, 0])])), RfbError.BadFilter, "Tight PNG was never asked for");
        // An index past the palette: three colours, index 7.
        var indices = Deflate(Enumerable.Repeat((byte)7, 64).ToArray());
        Fails(Cat(start, Update([Cat(Rect(0, 0, 8, 8, 7), [0x41, 1, 2, 1, 1, 1, 2, 2, 2, 3, 3, 3], Compact(indices.Length), indices)])), RfbError.BadFilter, "index past the palette");
    }

    [Fact]
    public void CutTextHugeIsRefusedAndASmallOneSkipped()
    {
        Fails(Cat(start, [3, 0, 0, 0], Be32(512L * 1024 * 1024), junk), RfbError.TooLong, "512 MiB declared");
        var parser = new RfbParser();
        var big = Cat([3, 0, 0, 0], Be32(300_000), Zeros(300_000));
        var out_ = RfbFeed.Run(parser, Cat(start, big, Update([TightFill(0, 0, 4, 4, 1, 1, 1)])), chunk: 4096);
        Assert.True(out_.Updates == 1, "skipped without being kept");
    }

    [Fact]
    public void ColourMapHugeIsSkipped()
    {
        var parser = new RfbParser();
        var map = Cat([1, 0], Be16(0), Be16(65535), Zeros(6 * 65535));
        var out_ = RfbFeed.Run(parser, Cat(start, map, Update([TightFill(0, 0, 4, 4, 1, 1, 1)])), chunk: 10_000);
        Assert.Equal(1, out_.Updates);
    }

    [Fact]
    public void TrailingBellsAfterAnUpdateAreIgnored()
    {
        var parser = new RfbParser();
        var out_ = RfbFeed.Run(parser, Cat(start, Update([TightFill(0, 0, 4, 4, 1, 1, 1)]), [2, 2, 2]));
        Assert.True(out_.Updates == 1 && !parser.MidUpdate);
    }

    /// 65,535 one-pixel rects with no LastRect: the count runs down and the update ends.
    [Fact]
    public void ANeverEndingUpdateEndsWhenItsCountRunsOut()
    {
        var parser = new RfbParser();
        var data = new List<byte> { 0, 0, 0xFF, 0xFF };
        for (var i = 0; i < 65_535; i++) data.AddRange(TightFill(i % 64, (i / 64) % 64, 1, 1, 0x10, 0x20, 0x30));
        var out_ = RfbFeed.Run(parser, Cat(start, [.. data]), chunk: 65_536);
        Assert.True(out_.Updates == 1 && out_.Rects == 65_535 && !parser.MidUpdate);
        Assert.Equal(0x20, parser.Framebuffer!.Pixel(5, 5).G);
        // With LastRect the same count ends early.
        var early = new RfbParser();
        var short_ = RfbFeed.Run(early, Cat(start, [0, 0, 0xFF, 0xFF], TightFill(0, 0, 1, 1, 1, 1, 1), LastRect(), [2]));
        Assert.True(short_.Updates == 1 && !early.MidUpdate);
    }

    /// A rect waits for the bytes it declared (at most 4 MiB) and nothing else: an unfinished one is not an error, and
    /// what was skipped or decoded is not kept.
    [Fact]
    public void AnUnfinishedRectWaitsWithoutAnError()
    {
        var parser = new RfbParser();
        var out_ = RfbFeed.Run(parser, Cat(start, [0, 0, 0, 1], Rect(0, 0, 64, 64, 7), [0x90, 0xFF, 0xFF, 0x7E], Zeros(1_000_000)));
        Assert.True(out_.Updates == 0 && parser.MidUpdate);
        Assert.True(RfbParser.MaxBuffer == 16 * 1024 * 1024 && RfbParser.MaxSkip == 16 * 1024 * 1024);
    }

    [Fact]
    public void NothingIsFedAfterAnErrorWithoutThrowingAgainOrCrashing()
    {
        var parser = new RfbParser();
        Assert.Throws<RfbException>(() => parser.Feed(Cat(start, [9])));
        Assert.Throws<RfbException>(() => parser.Feed(new byte[] { 0, 0, 0, 0 }));
    }
}
