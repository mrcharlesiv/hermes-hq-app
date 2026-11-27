// [WIN-SCREEN-RFB-CORE] The native RFB client's parser and decoders (Hermes.Core/Screen/RfbProtocol.cs,
// RfbDecoders.cs), ported case for case from the Mac's Tests/Screen/RFBParserTests.swift at 93f984bb1: the handshake
// for 3.8 / 3.7 / 3.3, what it sends, the skipped server messages, the decoder vectors written by the fixture's own
// encoder (`screen-gateway.py --emit-vectors`), feeding one byte at a time, and what the Mac helper sends (L520).

using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.RfbBuild;

namespace Hermes.Core.Tests.Screen;

public class RfbParserTests
{
    [Fact]
    public void Handshake38SendsVersionSecurityInitFormatEncodingsAndAFullRequest()
    {
        var parser = new RfbParser();
        var out_ = RfbFeed.Run(parser, Preamble(1280, 800));
        Assert.True(out_.Ready && parser.Name == "This Mac");
        Assert.True(parser.Framebuffer?.Width == 1280 && parser.Framebuffer?.Height == 800);
        Assert.Equal(6, out_.Send.Count);
        Assert.Equal(Ascii("RFB 003.008\n"), out_.Send[0]);
        Assert.Equal(new byte[] { 1 }, out_.Send[1]);                                     // security None
        Assert.Equal(new byte[] { 1 }, out_.Send[2]);                                     // ClientInit, shared
        Assert.Equal(new byte[] { 0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0 }, out_.Send[3]);
        Assert.Equal(new byte[] { 2, 0, 0, 8, 0, 0, 0, 7, 0, 0, 0, 1, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xE7, 0xFF, 0xFF, 0xFF, 0x02,
                                  0xFF, 0xFF, 0xFF, 0x20, 0xFF, 0xFF, 0xFF, 0x21, 0xFF, 0xFF, 0xFE, 0xCC }, out_.Send[4]);
        Assert.Equal(new byte[] { 3, 0, 0, 0, 0, 0, 0x05, 0x00, 0x03, 0x20 }, out_.Send[5]);   // not incremental, the whole 1280×800
    }

    [Fact]
    public void TheEncodingsListIsExactlyTheEightAllowed()
    {
        Assert.Equal(new[] { 7, 1, 0, -25, -254, -224, -223, -308 }, RfbMessage.Encodings);
        foreach (var forbidden in new[] { -239, -316, -309, -313, -312, 50 }) Assert.DoesNotContain(forbidden, RfbMessage.Encodings);
    }

    [Fact]
    public void Handshake37HasNoSecurityResult()
    {
        var parser = new RfbParser();
        var stream = Cat(Ascii("RFB 003.007\n"), [2, 2, 1], ServerInit(64, 48, "fixture:7"));
        var out_ = RfbFeed.Run(parser, stream);
        Assert.True(out_.Ready && parser.Name == "fixture:7");
        Assert.Equal(Ascii("RFB 003.007\n"), out_.Send[0]);
        Assert.Equal(new byte[] { 1 }, out_.Send[1]);
        Assert.Equal(new byte[] { 1 }, out_.Send[2]);
    }

    [Fact]
    public void Handshake33TakesTheServersChoice()
    {
        var parser = new RfbParser();
        var out_ = RfbFeed.Run(parser, Cat(Ascii("RFB 003.003\n"), Be32(1), ServerInit(64, 48)));
        Assert.True(out_.Ready);
        Assert.Equal(Ascii("RFB 003.003\n"), out_.Send[0]);
        Assert.Equal(new byte[] { 1 }, out_.Send[1]);                                     // no security byte in 3.3: ClientInit only
        Assert.Equal(RfbError.NoSecurity, RfbFeed.Error(Cat(Ascii("RFB 003.003\n"), Be32(2))));   // VNC password
        var reason = Ascii("Too many");
        Assert.Equal(RfbError.SecurityFailed("Too many"), RfbFeed.Error(Cat(Ascii("RFB 003.003\n"), Be32(0), Be32(reason.Length), reason)));
    }

    [Fact]
    public void ANewerServerIsAnsweredWith38()
    {
        var out_ = RfbFeed.Run(new RfbParser(), Ascii("RFB 003.889\n"));
        Assert.Single(out_.Send);
        Assert.Equal(Ascii("RFB 003.008\n"), out_.Send[0]);
        Assert.Equal(RfbError.BadVersion, RfbFeed.Error(Ascii("RFB 003.002\n")));
    }

    [Fact]
    public void ASecurityFailureCarriesItsReason()
    {
        var reason = Ascii("Too many viewers");
        var failed = Cat(Ascii("RFB 003.008\n"), [1, 1], Be32(1), Be32(reason.Length), reason);
        Assert.Equal(RfbError.SecurityFailed("Too many viewers"), RfbFeed.Error(failed));
        Assert.Equal(RfbError.SecurityFailed("Too many viewers"), RfbFeed.Error(failed, chunk: 1));
        var none = Cat(Ascii("RFB 003.008\n"), [0], Be32(4), Ascii("busy"));
        Assert.Equal(RfbError.SecurityFailed("busy"), RfbFeed.Error(none));
    }

    [Fact]
    public void ColourMapBellAndCutTextAreSkipped()
    {
        var parser = new RfbParser();
        var stream = Cat(Preamble(16, 16),
            Cat([1, 0], Be16(0), Be16(3)), Zeros(18),
            [2],
            Cat([3, 0, 0, 0], Be32(5)), Ascii("hello"),
            Update([TightFill(0, 0, 16, 16, 10, 20, 30)]),
            [2, 2]);
        var out_ = RfbFeed.Run(parser, stream, chunk: 3);
        Assert.True(out_.Updates == 1 && out_.Rects == 1 && !parser.MidUpdate);
        var pixel = parser.Framebuffer!.Pixel(8, 8);
        Assert.True(pixel.R == 10 && pixel.G == 20 && pixel.B == 30);
    }

    [Fact]
    public void MidUpdateIsTrueOnlyBetweenAnUpdatesFirstAndLastByte()
    {
        var parser = new RfbParser();
        RfbFeed.Run(parser, Preamble(16, 16));
        var update = Update([Raw(0, 0, 16, 16, 1, 2, 3)]);
        parser.Feed(update.AsSpan(0, 40));
        Assert.True(parser.MidUpdate);
        var rest = parser.Feed(update.AsSpan(40));
        Assert.True(!parser.MidUpdate && rest.Updates == 1);
    }

    [Fact]
    public void AnEmptyUpdateCompletesAtOnce()
    {
        var parser = new RfbParser();
        var out_ = RfbFeed.Run(parser, Cat(Preamble(16, 16), Update([])));
        Assert.True(out_.Updates == 1 && out_.Rects == 0 && !parser.MidUpdate);
    }

    [Fact]
    public void ClientMessagesHaveTheGatewaysFraming()
    {
        Assert.Equal(new byte[] { 4, 1, 0, 0, 0, 0, 0xFF, 0x0D }, RfbMessage.Key(0xFF0D, down: true));
        Assert.Equal(new byte[] { 4, 0, 0, 0, 0, 0, 0, 0x61 }, RfbMessage.Key(0x61, down: false));
        Assert.Equal(new byte[] { 5, 1, 0x02, 0x80, 0x01, 0x90 }, RfbMessage.Pointer(1, 640, 400));
        Assert.Equal(new byte[] { 5, 0, 0, 0, 0xFF, 0xFF }, RfbMessage.Pointer(0, -5, 70_000));           // clamped, never wrapped
        Assert.Equal(new byte[] { 6, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69 }, RfbMessage.CutText([0x68, 0x69]));
        Assert.Equal(new byte[] { 3, 1, 0, 0, 0, 0, 0x07, 0x80, 0x04, 0x38 }, RfbMessage.UpdateRequest(incremental: true, width: 1920, height: 1080));
        var sent = new HashSet<byte> { RfbMessage.SetPixelFormat()[0], RfbMessage.SetEncodings()[0], RfbMessage.UpdateRequest(true, 1, 1)[0],
                                       RfbMessage.Key(1, true)[0], RfbMessage.Pointer(0, 0, 0)[0], RfbMessage.CutText([])[0] };
        Assert.True(sent.SetEquals(new byte[] { 0, 2, 3, 4, 5, 6 }));
    }
}

public class RfbDecoderTests
{
    [Fact]
    public void EveryVectorDecodesToItsExpectedPicture()
    {
        var vectors = ScreenVector.All();
        Assert.True(vectors.Count >= 13);
        foreach (var vector in vectors)
        {
            var parser = new RfbParser();
            var out_ = RfbFeed.Run(parser, vector.Stream);
            var buffer = parser.Framebuffer;
            Assert.True(buffer != null, vector.Name);
            Assert.True(out_.Ready && out_.Updates >= 1 && !parser.MidUpdate, vector.Name);
            Assert.True(buffer!.Width == vector.Width && buffer.Height == vector.Height, vector.Name);
            if (vector.Expected is { } expected) Assert.True(buffer.Bgr().SequenceEqual(expected), $"{vector.Name}: {vector.Note}");
            foreach (var sample in vector.Samples ?? [])
            {
                var pixel = buffer.Pixel(sample[0], sample[1]);
                var off = Math.Max(Math.Abs(pixel.B - sample[2]), Math.Max(Math.Abs(pixel.G - sample[3]), Math.Abs(pixel.R - sample[4])));
                Assert.True(off <= (vector.Tolerance ?? 0), $"{vector.Name} at {sample[0]},{sample[1]}: off by {off}");
            }
        }
    }

    /// RFB messages do not line up with WebSocket frames: any split must give the same picture.
    [Fact]
    public void OneByteAtATimeGivesTheSamePictureAsOneBuffer()
    {
        foreach (var vector in ScreenVector.All().Where(v => v.Stream.Length < 400_000))
        {
            RfbParser whole = new(), single = new(), sevens = new();
            var a = RfbFeed.Run(whole, vector.Stream);
            var b = RfbFeed.Run(single, vector.Stream, chunk: 1);
            var c = RfbFeed.Run(sevens, vector.Stream, chunk: 7);
            Assert.True(a.Equals(b) && a.Equals(c), vector.Name);
            Assert.True(whole.Framebuffer!.Bgr().SequenceEqual(single.Framebuffer!.Bgr()), vector.Name);
            Assert.True(whole.Framebuffer!.Bgr().SequenceEqual(sevens.Framebuffer!.Bgr()), vector.Name);
        }
    }

    [Fact]
    public void TheNamedVectorsCoverEveryDecoder()
    {
        var names = ScreenVector.All().Select(v => v.Name).ToHashSet();
        foreach (var needed in new[] { "raw", "copyrect-overlap", "tight-fill", "tight-copy", "tight-palette", "tight-gradient", "tight-reset", "tight-long",
                                       "desktop-size", "ext-desktop-size", "last-rect", "skipped-messages", "tight-jpeg" })
            Assert.True(names.Contains(needed), needed);
    }

    [Fact]
    public void CopyRectMovesOverlappingRowsWithoutSmearing()
    {
        var buffer = ScreenFramebuffer.Create(8, 8)!;
        for (var y = 0; y < 8; y++) buffer.Fill(0, y, 8, 1, (byte)(y * 10), 0, 0);
        buffer.CopyRect(0, 2, 8, 5, fromX: 0, fromY: 0);                    // down by two, overlapping
        Assert.Equal(new byte[] { 0, 10, 0, 10, 20, 30, 40, 70 }, Enumerable.Range(0, 8).Select(y => buffer.Pixel(3, y).R).ToArray());
        buffer.CopyRect(0, 0, 8, 5, fromX: 0, fromY: 2);                    // back up
        Assert.Equal(new byte[] { 0, 10, 20, 30, 40, 30, 40, 70 }, Enumerable.Range(0, 8).Select(y => buffer.Pixel(3, y).R).ToArray());
    }

    [Fact]
    public void ZlibStateCarriesAcrossRectsAndAResetStartsAFreshStream()
    {
        var parser = new RfbParser();
        var red = Enumerable.Range(0, 16 * 16 * 3).Select(i => i % 3 == 0 ? (byte)200 : (byte)0).ToArray();
        var blue = Enumerable.Range(0, 16 * 16 * 3).Select(i => i % 3 == 2 ? (byte)180 : (byte)0).ToArray();
        // One deflate stream cut in two with a sync flush: the second rect continues the first one's stream.
        var stream = RfbTestDeflater.Run(red, blue);
        var first = Cat(Rect(0, 0, 16, 16, 7), [0x10], Compact(stream[0].Length), stream[0]);
        var second = Cat(Rect(16, 0, 16, 16, 7), [0x10], Compact(stream[1].Length), stream[1]);
        RfbFeed.Run(parser, Cat(Preamble(32, 16), Update([first]), Update([second])), chunk: 5);
        var buffer = parser.Framebuffer!;
        Assert.True(buffer.Pixel(4, 4).R == 200 && buffer.Pixel(20, 4).B == 180 && buffer.Pixel(20, 4).R == 0);
        // A reset bit: the same stream id starts over with a fresh deflate stream.
        stream = RfbTestDeflater.Run(blue);
        var fresh = Cat(Rect(0, 0, 16, 16, 7), [0x12], Compact(stream[0].Length), stream[0]);
        RfbFeed.Run(parser, Update([fresh]));
        buffer = parser.Framebuffer!;
        Assert.True(buffer.Pixel(4, 4).B == 180 && buffer.Pixel(4, 4).R == 0);
    }

    [Fact]
    public void AFramebufferOutsideTheLimitsIsRefused()
    {
        Assert.Null(ScreenFramebuffer.Create(0, 0));
        Assert.Null(ScreenFramebuffer.Create(8193, 10));
        Assert.Null(ScreenFramebuffer.Create(6016, 3384));                  // 81 MB
        Assert.True(ScreenFramebuffer.Allowed(5120, 2880));                 // 59 MB
        Assert.False(ScreenFramebuffer.Allowed(8192, 8192));
    }

    [Fact]
    public void TheProbeReadsFivePointsAsHexBGR()
    {
        var buffer = ScreenFramebuffer.Create(40, 40)!;
        buffer.Fill(0, 0, 40, 40, 0x11, 0x22, 0x33);
        buffer.Fill(20, 20, 1, 1, 0xAA, 0xBB, 0xCC);
        Assert.Equal("332211" + "332211" + "ccbbaa" + "332211" + "332211", buffer.Probe());
    }
}

public class RfbHelperConformanceTests
{
    // What "Hermes HQ Screen" on the Mac serves (docs/spec/3x-screen.md §5.15 acceptance 2): ServerInit named
    // "This Mac", Tight Fill, Tight JPEG, Raw, and a resize by -308 or -223.

    [Fact]
    public void ServerInitNamedThisMacThenFillRawAndJPEG()
    {
        var parser = new RfbParser();
        var small = ScreenTestImage.Red64;                                  // 2-byte length
        var large = ScreenTestImage.Noise256;                               // 3-byte length
        Assert.True(small.Length is >= 128 and < 16_384 && large.Length >= 16_384);
        var stream = Cat(Preamble(640, 400), Update([
            TightFill(0, 0, 640, 400, 12, 34, 56),
            Raw(100, 100, 32, 16, 7, 8, 9),
            TightJpeg(200, 40, 64, 64, small),
            TightJpeg(320, 40, 256, 256, large),
        ]));
        foreach (var chunk in new[] { int.MaxValue, 1, 4096 })
        {
            var each = new RfbParser();
            var o = RfbFeed.Run(each, stream, chunk);
            Assert.True(o.Ready && o.Updates == 1 && o.Rects == 4 && each.Name == "This Mac" && each.FailedJpegs == 0, $"chunk {chunk}");
        }
        RfbFeed.Run(parser, stream);
        var buffer = parser.Framebuffer!;
        var fill = buffer.Pixel(5, 300);
        Assert.True(fill.R == 12 && fill.G == 34 && fill.B == 56);
        var raw = buffer.Pixel(110, 110);
        Assert.True(raw.R == 9 && raw.G == 8 && raw.B == 7);
        var red = buffer.Pixel(230, 70);
        Assert.True(red.R > 200 && red.G < 60 && red.B < 60, "the JPEG lands where the rect says, the right way up");
        var edge = buffer.Pixel(199, 70);
        Assert.True(edge.R == 12, "nothing drawn outside the rect");
    }

    /// A JPEG under 128 bytes cannot exist, so the 1-byte length is proven with bytes that are not a JPEG: the length
    /// is read, the rect is left as it was, one failure is counted and the stream carries on.
    [Fact]
    public void AOneByteJPEGLengthIsReadAndABadJPEGLeavesTheRectAlone()
    {
        var parser = new RfbParser();
        var junk = Enumerable.Range(0, 100).Select(i => (byte)((i * 131 + 7) % 251)).ToArray();
        var stream = Cat(Preamble(64, 64), Update([TightFill(0, 0, 64, 64, 1, 2, 3)]),
            Update([TightJpeg(0, 0, 32, 32, junk)]), Update([TightFill(40, 40, 8, 8, 9, 9, 9)]));
        var out_ = RfbFeed.Run(parser, stream, chunk: 1);
        Assert.True(out_.Updates == 3 && parser.FailedJpegs == 1);
        var buffer = parser.Framebuffer!;
        Assert.True(buffer.Pixel(10, 10).R == 1 && buffer.Pixel(44, 44).R == 9);
    }

    [Fact]
    public void AResizeByEitherPseudoRectGivesANewBlackPictureAndAsksForAFullOne()
    {
        foreach (var extended in new[] { true, false })
        {
            var parser = new RfbParser();
            RfbFeed.Run(parser, Cat(Preamble(64, 48), Update([TightFill(0, 0, 64, 48, 200, 200, 200)])));
            var resize = extended ? ExtendedDesktopSize(96, 60) : DesktopSize(96, 60);
            var out_ = RfbFeed.Run(parser, Update([resize]), chunk: 1);
            var buffer = parser.Framebuffer!;
            Assert.True(out_.Resized && out_.Updates == 1 && buffer.Width == 96 && buffer.Height == 60, $"extended {extended}");
            Assert.True(buffer.Pixel(10, 10).R == 0, "the new picture starts black");
            var after = RfbFeed.Run(parser, Update([TightFill(64, 48, 32, 12, 5, 6, 7)]));
            Assert.True(after.Updates == 1 && !after.Resized && parser.Framebuffer?.Pixel(90, 55).G == 6);
        }
    }

    [Fact]
    public void ARefusedResizeRequestChangesNothing()
    {
        var parser = new RfbParser();
        RfbFeed.Run(parser, Preamble(64, 48));
        var out_ = RfbFeed.Run(parser, Update([ExtendedDesktopSize(10, 10, status: 1)]));
        Assert.True(!out_.Resized && parser.Framebuffer?.Width == 64);
        var same = RfbFeed.Run(parser, Update([ExtendedDesktopSize(64, 48)]));
        Assert.False(same.Resized, "the same size is not a resize");
    }
}
