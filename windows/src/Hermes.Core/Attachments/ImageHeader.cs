using System.Buffers.Binary;
using System.Security.Cryptography;

namespace Hermes.Core.Attachments;

/// A picture's pixel size from its first bytes (PNG, GIF, JPEG, WebP, BMP), without decoding it: the stand-in for
/// ImageIO's properties read (PhotoNormalizer.pixelSize, spec §8.3). Pure.
public static class ImageHeader
{
    public static (int Width, int Height)? PixelSize(ReadOnlySpan<byte> d)
    {
        try
        {
            if (d.Length >= 24 && d[0] == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G')
                return Valid(BinaryPrimitives.ReadInt32BigEndian(d[16..]), BinaryPrimitives.ReadInt32BigEndian(d[20..]));
            if (d.Length >= 10 && d[0] == 'G' && d[1] == 'I' && d[2] == 'F')
                return Valid(BinaryPrimitives.ReadUInt16LittleEndian(d[6..]), BinaryPrimitives.ReadUInt16LittleEndian(d[8..]));
            if (d.Length >= 26 && d[0] == 'B' && d[1] == 'M')
                return Valid(BinaryPrimitives.ReadInt32LittleEndian(d[18..]), Math.Abs(BinaryPrimitives.ReadInt32LittleEndian(d[22..])));
            if (d.Length >= 30 && d[0] == 'R' && d[1] == 'I' && d[2] == 'F' && d[3] == 'F' && d[8] == 'W' && d[9] == 'E' && d[10] == 'B' && d[11] == 'P')
                return WebP(d);
            if (d.Length >= 4 && d[0] == 0xFF && d[1] == 0xD8) return Jpeg(d);
        }
        catch (ArgumentOutOfRangeException) { }
        return null;
    }

    public static (int Width, int Height)? PixelSizeOfFile(string path)
    {
        try
        {
            using var f = File.OpenRead(path);
            // JPEG SOF can sit after a large EXIF block: read up to 512 KiB.
            var buffer = new byte[Math.Min(f.Length, 512 * 1024)];
            var n = f.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
            return PixelSize(buffer.AsSpan(0, n));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    private static (int, int)? Valid(int w, int h) => w > 0 && h > 0 ? (w, h) : null;

    private static (int, int)? WebP(ReadOnlySpan<byte> d)
    {
        var chunk = d.Slice(12, 4);
        if (chunk.SequenceEqual("VP8X"u8))
            return Valid(1 + (d[24] | d[25] << 8 | d[26] << 16), 1 + (d[27] | d[28] << 8 | d[29] << 16));
        if (chunk.SequenceEqual("VP8L"u8))
        {
            var b = BinaryPrimitives.ReadUInt32LittleEndian(d[21..]);
            return Valid((int)(b & 0x3FFF) + 1, (int)((b >> 14) & 0x3FFF) + 1);
        }
        if (chunk.SequenceEqual("VP8 "u8))
            return Valid(BinaryPrimitives.ReadUInt16LittleEndian(d[26..]) & 0x3FFF, BinaryPrimitives.ReadUInt16LittleEndian(d[28..]) & 0x3FFF);
        return null;
    }

    private static (int, int)? Jpeg(ReadOnlySpan<byte> d)
    {
        var i = 2;
        while (i + 9 < d.Length)
        {
            if (d[i] != 0xFF) { i++; continue; }
            var marker = d[i + 1];
            if (marker == 0xFF) { i++; continue; }
            if (marker is 0xD8 or 0x01 || marker is >= 0xD0 and <= 0xD7) { i += 2; continue; }
            var len = BinaryPrimitives.ReadUInt16BigEndian(d[(i + 2)..]);
            if (marker is >= 0xC0 and <= 0xCF && marker is not 0xC4 and not 0xC8 and not 0xCC)
                return Valid(BinaryPrimitives.ReadUInt16BigEndian(d[(i + 7)..]), BinaryPrimitives.ReadUInt16BigEndian(d[(i + 5)..]));
            i += 2 + len;
        }
        return null;
    }
}

/// Decoded data: images from history (spec §7.1 rule 6, §8.1): kept on disk by content, never in the transcript or its
/// cache; a message part carries only the key. The app points Root at its cache folder; purged on sign-out.
public static class InlineMediaStore
{
    /// Inline data: images are decoded up to 32 MB each (spec §3.9).
    public const long MaxBytes = 32L << 20;

    public static string Root { get; set; } = Path.Combine(Path.GetTempPath(), "HermesHQ-inline");

    /// Writes the bytes (once per content) and answers their key.
    public static string Store(byte[] data)
    {
        var key = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        var path = PathFor(key);
        try
        {
            if (!File.Exists(path))
            {
                Directory.CreateDirectory(Root);
                var tmp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllBytes(tmp, data);
                File.Move(tmp, path, overwrite: true);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return key;
    }

    public static string PathFor(string key) =>
        Path.Combine(Root, string.Concat(key.Where(char.IsAsciiLetterOrDigit)));

    public static void Purge()
    {
        try { Directory.Delete(Root, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
