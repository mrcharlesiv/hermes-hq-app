// [WIN-SCREEN-RFB-CORE] The picture side of the native RFB client (docs/spec/3x-screen.md §2.3), ported from the
// Mac's HermesKit/Screen/RFBDecoders.swift at 93f984bb1: the framebuffer (BGRX in memory, the Mac helper's own format
// and the little-endian 32-bit one Windows bitmaps use, so pixels are never converted one by one) and the decoders
// that write into it: Raw rows, CopyRect, Tight Fill / JPEG / Basic with its four zlib streams. Everything here runs
// on the stream's own task, never on the UI thread.

using System.IO.Compression;

namespace Hermes.Core.Screen;

public sealed class ScreenFramebuffer
{
    public const int MaxSide = 8192;
    public const int MaxBytes = 64 * 1024 * 1024;

    public int Width { get; }
    public int Height { get; }
    readonly byte[] pixels;
    int Stride => Width * 4;

    public static bool Allowed(int width, int height) =>
        width > 0 && height > 0 && width <= MaxSide && height <= MaxSide && (long)width * height * 4 <= MaxBytes;

    /// null for a size outside the limits (bad data can never make the app reserve more than 64 MB).
    public static ScreenFramebuffer? Create(int width, int height) => Allowed(width, height) ? new ScreenFramebuffer(width, height) : null;

    ScreenFramebuffer(int width, int height)
    {
        Width = width;
        Height = height;
        pixels = new byte[width * height * 4];
    }

    public bool Contains(int x, int y, int w, int h) => x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= Width && y + h <= Height;

    /// `rows` full rows of BGRX starting at row `y` of the rect at `x`.
    public void WriteRaw(int x, int y, int w, int rows, ReadOnlySpan<byte> source)
    {
        if (w <= 0) return;
        for (var row = 0; row < rows; row++)
            source.Slice(row * w * 4, w * 4).CopyTo(pixels.AsSpan((y + row) * Stride + x * 4));
    }

    /// Overlap-safe: rows go bottom-up when the copy moves down.
    public void CopyRect(int x, int y, int w, int h, int fromX, int fromY)
    {
        if (w <= 0 || h <= 0) return;
        for (var i = 0; i < h; i++)
        {
            var row = y > fromY ? h - 1 - i : i;
            Buffer.BlockCopy(pixels, (fromY + row) * Stride + fromX * 4, pixels, (y + row) * Stride + x * 4, w * 4);   // memmove
        }
    }

    public void Fill(int x, int y, int w, int h, byte r, byte g, byte b)
    {
        if (w <= 0 || h <= 0) return;
        var first = y * Stride + x * 4;
        for (var col = 0; col < w; col++)
        {
            pixels[first + col * 4] = b; pixels[first + col * 4 + 1] = g; pixels[first + col * 4 + 2] = r; pixels[first + col * 4 + 3] = 0;
        }
        for (var row = 1; row < Math.Max(1, h); row++) Buffer.BlockCopy(pixels, first, pixels, (y + row) * Stride + x * 4, w * 4);
    }

    /// Tight's 3-byte RGB pixels, row by row.
    public void WriteRgb(int x, int y, int w, int h, ReadOnlySpan<byte> rgb)
    {
        for (var row = 0; row < h; row++)
        {
            var line = (y + row) * Stride + x * 4;
            var source = row * w * 3;
            for (var col = 0; col < w; col++)
            {
                pixels[line + col * 4] = rgb[source + col * 3 + 2];
                pixels[line + col * 4 + 1] = rgb[source + col * 3 + 1];
                pixels[line + col * 4 + 2] = rgb[source + col * 3];
                pixels[line + col * 4 + 3] = 0;
            }
        }
    }

    /// false when the bytes are not a JPEG that decodes: the rect is left as it was. The picture is drawn into the rect
    /// at the rect's size (nearest pixel when they differ, as the Mac's `.none` interpolation).
    public bool DrawJpeg(ReadOnlySpan<byte> data, int x, int y, int w, int h, IScreenJpegDecoder? decoder = null)
    {
        if (w <= 0 || h <= 0 || data.Length <= 3 || data[0] != 0xFF || data[1] != 0xD8) return false;
        ScreenJpegImage? image;
        try { image = (decoder ?? ScreenJpeg.Decoder).Decode(data); }
        catch (Exception) { return false; }
        if (image is not { Width: > 0, Height: > 0 } picture || picture.Rgb.Length < picture.Width * picture.Height * 3) return false;
        for (var row = 0; row < h; row++)
        {
            var sy = (int)((long)row * picture.Height / h);
            var line = (y + row) * Stride + x * 4;
            for (var col = 0; col < w; col++)
            {
                var at = (sy * picture.Width + (int)((long)col * picture.Width / w)) * 3;
                pixels[line + col * 4] = picture.Rgb[at + 2];
                pixels[line + col * 4 + 1] = picture.Rgb[at + 1];
                pixels[line + col * 4 + 2] = picture.Rgb[at];
                pixels[line + col * 4 + 3] = 0;
            }
        }
        return true;
    }

    /// An immutable snapshot (BGRX, `Width * 4` a row, the fourth byte unused), safe to hand to the UI thread while
    /// decoding goes on: the Swift `makeImage()`.
    public byte[] Snapshot() => (byte[])pixels.Clone();

    public (byte B, byte G, byte R) Pixel(int x, int y)
    {
        var at = Math.Min(Height - 1, Math.Max(0, y)) * Stride + Math.Min(Width - 1, Math.Max(0, x)) * 4;
        return (pixels[at], pixels[at + 1], pixels[at + 2]);
    }

    /// The five sample points the fixture reports (`/__fixture/screen/expect`), as hex BGR.
    public string Probe() => string.Concat(new[] { (0.25, 0.25), (0.75, 0.25), (0.5, 0.5), (0.25, 0.75), (0.75, 0.75) }.Select(point =>
    {
        var p = Pixel((int)(Width * point.Item1), (int)(Height * point.Item2));
        return $"{p.B:x2}{p.G:x2}{p.R:x2}";
    }));

    /// The pixels as B, G, R triples (tests compare these with a vector's expected picture).
    public byte[] Bgr()
    {
        var out_ = new byte[Width * Height * 3];
        for (var i = 0; i < Width * Height; i++)
        {
            out_[i * 3] = pixels[i * 4]; out_[i * 3 + 1] = pixels[i * 4 + 1]; out_[i * 3 + 2] = pixels[i * 4 + 2];
        }
        return out_;
    }
}

/// Tight's four zlib streams. They live as long as the connection: a rect continues the stream an earlier one left.
public sealed class TightStreams
{
    /// The bytes of the rect being inflated, handed to the zlib reader as its whole input.
    sealed class Input : Stream
    {
        byte[] data = [];
        int at;
        public int Left => data.Length - at;
        public void Set(ReadOnlySpan<byte> bytes) { data = bytes.ToArray(); at = 0; }
        public override int Read(byte[] buffer, int offset, int count)
        {
            var n = Math.Min(count, Left);
            Buffer.BlockCopy(data, at, buffer, offset, n);
            at += n;
            return n;
        }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => data.Length;
        public override long Position { get => at; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    readonly Input?[] inputs = new Input?[4];
    readonly ZLibStream?[] streams = new ZLibStream?[4];

    public void Reset(int index)
    {
        streams[index]?.Dispose();
        streams[index] = null;
        inputs[index] = null;
    }

    /// Inflates `input` on stream `index` into exactly `count` bytes; throws `RfbException(Zlib)` otherwise.
    public byte[] Inflate(int index, ReadOnlySpan<byte> input, int count)
    {
        var source = inputs[index] ??= new Input();
        var stream = streams[index] ??= new ZLibStream(source, CompressionMode.Decompress, leaveOpen: true);
        source.Set(input);
        var out_ = new byte[count];
        try
        {
            var filled = 0;
            while (filled < count)
            {
                var n = stream.Read(out_, filled, count - filled);
                if (n == 0) break;
                filled += n;
            }
            if (filled != count) throw new RfbException(RfbError.Zlib);
            // The sync marker after the last byte may still be unread: take it in, so the next rect starts clean. Any
            // byte it gives back is more pixels than the rect holds.
            var scratch = new byte[16];
            if (stream.Read(scratch, 0, 16) != 0) throw new RfbException(RfbError.Zlib);
            if (source.Left > 0) throw new RfbException(RfbError.Zlib);
        }
        catch (InvalidDataException) { throw new RfbException(RfbError.Zlib); }
        return out_;
    }
}

public static class TightFilter
{
    /// The palette filter's index data → RGB triples. null when an index points past the palette.
    public static byte[]? Palette(byte[] data, byte[] palette, int w, int h)
    {
        var colours = palette.Length / 3;
        var out_ = new byte[w * h * 3];
        if (colours == 2)
        {
            var rowBytes = (w + 7) / 8;
            if (data.Length < rowBytes * h) return null;
            for (var row = 0; row < h; row++)
                for (var col = 0; col < w; col++)
                {
                    var index = (data[row * rowBytes + col / 8] >> (7 - col % 8)) & 1;
                    var at = (row * w + col) * 3;
                    out_[at] = palette[index * 3]; out_[at + 1] = palette[index * 3 + 1]; out_[at + 2] = palette[index * 3 + 2];
                }
        }
        else
        {
            if (data.Length < w * h) return null;
            for (var i = 0; i < w * h; i++)
            {
                int index = data[i];
                if (index >= colours) return null;
                out_[i * 3] = palette[index * 3]; out_[i * 3 + 1] = palette[index * 3 + 1]; out_[i * 3 + 2] = palette[index * 3 + 2];
            }
        }
        return out_;
    }

    /// The gradient filter: each component is stored as its difference from left + up − up-left (clamped).
    public static byte[] Gradient(byte[] data, int w, int h)
    {
        var out_ = new byte[w * h * 3];
        for (var row = 0; row < h; row++)
            for (var col = 0; col < w; col++)
            {
                var at = (row * w + col) * 3;
                for (var c = 0; c < 3; c++)
                {
                    var left = col > 0 ? out_[at - 3 + c] : 0;
                    var up = row > 0 ? out_[at - w * 3 + c] : 0;
                    var corner = row > 0 && col > 0 ? out_[at - w * 3 - 3 + c] : 0;
                    var predicted = Math.Min(255, Math.Max(0, left + up - corner));
                    out_[at + c] = (byte)((data[at + c] + predicted) & 0xFF);
                }
            }
        return out_;
    }
}
