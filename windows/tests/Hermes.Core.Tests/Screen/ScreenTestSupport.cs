// [WIN-SCREEN-RFB-CORE] Shared helpers for the Bot Screen protocol tests, ported from the Mac's
// Tests/Screen/ScreenTestSupport.swift at 93f984bb1: a small RFB server-side encoder (the shapes the Mac helper and
// Xvnc send), the decoder vectors written by `scripts/fixtures/screen-gateway.py --emit-vectors` (shared with the Swift
// tests from Tests/Fixtures/screen), and the test JPEGs. The JPEGs are the exact bytes the Swift ScreenTestImage.jpeg
// makes (CoreGraphics, quality 0.86), saved once under Screen/Fixtures because .NET has no JPEG encoder: synthetic,
// one colour (or the seeded noise) each.

using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

internal static class RfbBuild
{
    public static byte[] Be16(int value) => [(byte)((value >> 8) & 0xFF), (byte)(value & 0xFF)];
    public static byte[] Be32(long value) => [(byte)((value >> 24) & 0xFF), (byte)((value >> 16) & 0xFF), (byte)((value >> 8) & 0xFF), (byte)(value & 0xFF)];
    public static byte[] Ascii(string text) => Encoding.UTF8.GetBytes(text);
    public static byte[] Cat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();
    public static byte[] Zeros(int count) => new byte[count];

    public static byte[] ServerInit(int width, int height, string name = "This Mac")
    {
        byte[] format = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0];
        var utf8 = Encoding.UTF8.GetBytes(name);
        return Cat(Be16(width), Be16(height), format, Be32(utf8.Length), utf8);
    }

    /// Everything a 3.8 server sends up to and including ServerInit.
    public static byte[] Preamble(int width, int height, string name = "This Mac") =>
        Cat(Ascii("RFB 003.008\n"), [1, 1], Be32(0), ServerInit(width, height, name));

    public static byte[] Update(byte[][] rects, int? count = null) => Cat([Cat([0, 0], Be16(count ?? rects.Length)), .. rects]);

    public static byte[] Rect(int x, int y, int w, int h, int encoding) =>
        Cat(Be16(x), Be16(y), Be16(w), Be16(h), Be32(unchecked((uint)encoding)));

    public static byte[] Raw(int x, int y, int w, int h, byte b, byte g, byte r)
    {
        var out_ = new List<byte>(Rect(x, y, w, h, 0));
        for (var i = 0; i < w * h; i++) out_.AddRange([b, g, r, 0]);
        return [.. out_];
    }

    public static byte[] CopyRect(int x, int y, int w, int h, int fromX, int fromY) => Cat(Rect(x, y, w, h, 1), Be16(fromX), Be16(fromY));

    public static byte[] Compact(int length)
    {
        if (length < 0x80) return [(byte)length];
        if (length < 0x4000) return [(byte)((length & 0x7F) | 0x80), (byte)(length >> 7)];
        return [(byte)((length & 0x7F) | 0x80), (byte)(((length >> 7) & 0x7F) | 0x80), (byte)(length >> 14)];
    }

    public static byte[] TightFill(int x, int y, int w, int h, byte r, byte g, byte b) => Cat(Rect(x, y, w, h, 7), [0x80, r, g, b]);

    public static byte[] TightJpeg(int x, int y, int w, int h, byte[] jpeg) => Cat(Rect(x, y, w, h, 7), [0x90], Compact(jpeg.Length), jpeg);

    /// A whole zlib stream (header, data, end) at level 6, as zlib's compress2 makes.
    public static byte[] Deflate(byte[] bytes)
    {
        using var buffer = new MemoryStream();
        using (var z = new ZLibStream(buffer, CompressionLevel.Optimal, leaveOpen: true)) z.Write(bytes);
        return buffer.ToArray();
    }

    public static byte[] LastRect() => Rect(0, 0, 0, 0, -224);
    public static byte[] DesktopSize(int w, int h) => Rect(0, 0, w, h, -223);
    public static byte[] ExtendedDesktopSize(int w, int h, int status = 0) =>
        Cat(Rect(0, status, w, h, -308), [1, 0, 0, 0], Be32(1), Be16(0), Be16(0), Be16(w), Be16(h), Be32(0));
}

internal static class ScreenTestImage
{
    static string Folder => Path.Combine(AppContext.BaseDirectory, "Screen", "Fixtures");

    /// 64×64, red (0.9, 0.1, 0.1): 849 bytes, a 2-byte compact length.
    public static byte[] Red64 => File.ReadAllBytes(Path.Combine(Folder, "red-64.jpg"));
    /// 256×256, grey with seeded per-pixel noise: over 16 KiB, a 3-byte compact length.
    public static byte[] Noise256 => File.ReadAllBytes(Path.Combine(Folder, "noise-256.jpg"));
    /// 64×64, green (0, 1, 0).
    public static byte[] Green64 => File.ReadAllBytes(Path.Combine(Folder, "green-64.jpg"));
}

internal sealed record ScreenVector(string Name, int Width, int Height, string Note, int[][]? Samples, int? Tolerance)
{
    public static string Folder => Path.Combine(AppContext.BaseDirectory, "Fixtures", "screen");

    public static List<ScreenVector> All()
    {
        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        return JsonSerializer.Deserialize<List<ScreenVector>>(File.ReadAllText(Path.Combine(Folder, "vectors.json")), options)!;
    }

    public byte[] Stream => File.Exists(Path.Combine(Folder, Name + ".rfb")) ? File.ReadAllBytes(Path.Combine(Folder, Name + ".rfb")) : [];

    /// The expected picture as B, G, R triples (null for the JPEG vector, which has samples instead).
    public byte[]? Expected
    {
        get
        {
            var path = Path.Combine(Folder, Name + ".bgrx");
            if (!File.Exists(path)) return null;
            var data = File.ReadAllBytes(path);
            var out_ = new byte[data.Length / 4 * 3];
            for (var i = 0; i < data.Length / 4; i++) { out_[i * 3] = data[i * 4]; out_[i * 3 + 1] = data[i * 4 + 1]; out_[i * 3 + 2] = data[i * 4 + 2]; }
            return out_;
        }
    }
}

internal static class RfbFeed
{
    /// Feeds `data` in pieces of `chunk` bytes; returns the summed output.
    public static RfbParser.Output Run(RfbParser parser, byte[] data, int chunk = int.MaxValue)
    {
        var total = new RfbParser.Output();
        var at = 0;
        while (at < data.Length)
        {
            var end = chunk == int.MaxValue ? data.Length : Math.Min(data.Length, at + chunk);
            var out_ = parser.Feed(data.AsSpan(at, end - at));
            total.Send.AddRange(out_.Send);
            total.Ready = total.Ready || out_.Ready;
            total.Updates += out_.Updates;
            total.Rects += out_.Rects;
            total.Resized = total.Resized || out_.Resized;
            at = end;
        }
        return total;
    }

    public static RfbError? Error(byte[] data, int chunk = int.MaxValue)
    {
        try { Run(new RfbParser(), data, chunk); }
        catch (RfbException error) { return error.Error; }
        return null;
    }
}

/// One zlib stream fed part by part with a sync flush after each (how a Tight server feeds one of its four streams).
internal static class RfbTestDeflater
{
    public static List<byte[]> Run(params byte[][] parts)
    {
        using var buffer = new MemoryStream();
        using var z = new ZLibStream(buffer, CompressionLevel.Optimal, leaveOpen: true);
        var out_ = new List<byte[]>();
        foreach (var part in parts)
        {
            z.Write(part);
            z.Flush();                                              // Z_SYNC_FLUSH
            out_.Add(buffer.ToArray());
            buffer.SetLength(0);
        }
        return out_;
    }
}
