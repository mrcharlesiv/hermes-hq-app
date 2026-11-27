// [WIN-SCREEN-RFB-CORE] Tight JPEG pictures for the RFB parser. The Mac draws them with ImageIO (RFBDecoders.swift
// drawJPEG); Hermes.Core builds and tests on any OS with no image codec, so it carries a small baseline JPEG decoder
// (sequential Huffman, 8-bit, 1 or 3 components, any sampling, restart intervals): what Tight servers send (libjpeg's
// baseline output, and the Mac helper's ImageIO JPEGs, which are 4:2:0 baseline with restart markers). Progressive,
// arithmetic, 12-bit and lossless JPEGs decode as failures, which the parser counts like any bad JPEG. The Windows
// app may swap in a faster decoder (WIC) through IScreenJpegDecoder.

namespace Hermes.Core.Screen;

/// A decoded picture: RGB triples, row by row.
public sealed record ScreenJpegImage(int Width, int Height, byte[] Rgb);

public interface IScreenJpegDecoder
{
    /// The picture, or null when the bytes are not a JPEG that decodes. May throw; the caller treats that as null.
    ScreenJpegImage? Decode(ReadOnlySpan<byte> jpeg);
}

public sealed class ScreenJpeg : IScreenJpegDecoder
{
    public static readonly ScreenJpeg Decoder = new();

    static readonly int[] ZigZag =
    [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ];

    static readonly float[,] Cosines = MakeCosines();

    static float[,] MakeCosines()
    {
        var table = new float[8, 8];
        for (var x = 0; x < 8; x++)
            for (var u = 0; u < 8; u++)
                table[x, u] = (float)((u == 0 ? Math.Sqrt(0.5) : 1.0) * Math.Cos((2 * x + 1) * u * Math.PI / 16));
        return table;
    }

    sealed class Huffman
    {
        public readonly int[] MaxCode = new int[18];
        public readonly int[] ValPtr = new int[17];
        public readonly int[] MinCode = new int[17];
        public byte[] Values = [];

        public Huffman(ReadOnlySpan<byte> counts, byte[] values)
        {
            Values = values;
            int code = 0, k = 0;
            for (var length = 1; length <= 16; length++)
            {
                var n = counts[length - 1];
                if (n == 0) { MaxCode[length] = -1; }
                else
                {
                    ValPtr[length] = k;
                    MinCode[length] = code;
                    code += n;
                    k += n;
                    MaxCode[length] = code - 1;
                }
                code <<= 1;
            }
            MaxCode[17] = int.MaxValue;
        }
    }

    sealed class Component
    {
        public int Id, H, V, Tq, Td, Ta, Pred, BlocksPerLine, BlocksPerColumn;
        public byte[] Plane = [];
    }

    ref struct Bits(ReadOnlySpan<byte> data, int at)
    {
        readonly ReadOnlySpan<byte> data = data;
        public int At = at;
        int buffer;
        int count;
        public int Overrun;

        public int Bit()
        {
            if (count == 0)
            {
                int next;
                if (At >= data.Length) { next = 0; Overrun++; }
                else if (data[At] == 0xFF)
                {
                    var marker = At + 1 < data.Length ? data[At + 1] : 0xD9;
                    if (marker == 0) { next = 0xFF; At += 2; }
                    else { next = 0; Overrun++; }                    // a marker: pad with zeros, leave it for the caller
                }
                else next = data[At++];
                buffer = next;
                count = 8;
            }
            count--;
            return (buffer >> count) & 1;
        }

        public int Receive(int length)
        {
            var value = 0;
            for (var i = 0; i < length; i++) value = value << 1 | Bit();
            return value;
        }

        public int Decode(Huffman table)
        {
            var code = Bit();
            var length = 1;
            while (code > table.MaxCode[length])
            {
                code = code << 1 | Bit();
                length++;
                if (length > 16) throw new InvalidDataException("huffman");
            }
            return table.Values[table.ValPtr[length] + code - table.MinCode[length]];
        }

        /// A restart: drop the partial byte and step over the RSTn marker.
        public void Restart()
        {
            count = 0;
            while (At + 1 < data.Length && !(data[At] == 0xFF && data[At + 1] is >= 0xD0 and <= 0xD7)) At++;
            if (At + 1 >= data.Length) throw new InvalidDataException("restart");
            At += 2;
        }
    }

    static int Extend(int value, int length) => length == 0 ? 0 : value < 1 << (length - 1) ? value - (1 << length) + 1 : value;

    public ScreenJpegImage? Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length < 4 || data[0] != 0xFF || data[1] != 0xD8) return null;
        var quant = new int[4][];
        var dc = new Huffman?[4];
        var ac = new Huffman?[4];
        List<Component> components = [];
        int width = 0, height = 0, interval = 0, hMax = 1, vMax = 1;
        var scanned = false;
        var at = 2;
        while (at + 4 <= data.Length)
        {
            if (data[at] != 0xFF) return null;
            var marker = data[at + 1];
            if (marker == 0xFF) { at++; continue; }
            if (marker == 0xD9) break;
            if (marker is >= 0xD0 and <= 0xD7 or 0x01) { at += 2; continue; }
            var length = data[at + 2] << 8 | data[at + 3];
            if (length < 2 || at + 2 + length > data.Length) return null;
            var segment = data.Slice(at + 4, length - 2);
            switch (marker)
            {
                case 0xDB:
                {
                    var i = 0;
                    while (i < segment.Length)
                    {
                        var precision = segment[i] >> 4;
                        var id = segment[i] & 3;
                        var table = new int[64];
                        for (var k = 0; k < 64; k++)
                            table[k] = precision == 0 ? segment[i + 1 + k] : segment[i + 1 + 2 * k] << 8 | segment[i + 2 + 2 * k];
                        quant[id] = table;
                        i += 1 + (precision == 0 ? 64 : 128);
                    }
                    break;
                }
                case 0xC4:
                {
                    var i = 0;
                    while (i < segment.Length)
                    {
                        var kind = segment[i] >> 4;
                        var id = segment[i] & 3;
                        var counts = segment.Slice(i + 1, 16);
                        var total = 0;
                        foreach (var n in counts) total += n;
                        var table = new Huffman(counts, segment.Slice(i + 17, total).ToArray());
                        if (kind == 0) dc[id] = table; else ac[id] = table;
                        i += 17 + total;
                    }
                    break;
                }
                case 0xC0 or 0xC1:
                {
                    if (segment[0] != 8) return null;
                    height = segment[1] << 8 | segment[2];
                    width = segment[3] << 8 | segment[4];
                    var n = segment[5];
                    if (width <= 0 || height <= 0 || !ScreenFramebuffer.Allowed(width, height) || n is not (1 or 3)) return null;
                    for (var c = 0; c < n; c++)
                    {
                        var component = new Component
                        {
                            Id = segment[6 + 3 * c], H = segment[7 + 3 * c] >> 4, V = segment[7 + 3 * c] & 15, Tq = segment[8 + 3 * c] & 3,
                        };
                        if (component.H is < 1 or > 4 || component.V is < 1 or > 4) return null;
                        components.Add(component);
                    }
                    hMax = components.Max(c => c.H);
                    vMax = components.Max(c => c.V);
                    var mcuX = (width + 8 * hMax - 1) / (8 * hMax);
                    var mcuY = (height + 8 * vMax - 1) / (8 * vMax);
                    foreach (var component in components)
                    {
                        component.BlocksPerLine = mcuX * component.H;
                        component.BlocksPerColumn = mcuY * component.V;
                        component.Plane = new byte[component.BlocksPerLine * 8 * component.BlocksPerColumn * 8];
                    }
                    break;
                }
                case >= 0xC2 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC:
                    return null;                                            // progressive, lossless, arithmetic
                case 0xDD:
                    interval = segment[0] << 8 | segment[1];
                    break;
                case 0xDA:
                {
                    if (components.Count == 0) return null;
                    var n = segment[0];
                    List<Component> scan = [];
                    for (var c = 0; c < n; c++)
                    {
                        int wanted = segment[1 + 2 * c];
                        var component = components.FirstOrDefault(x => x.Id == wanted);
                        if (component is null) return null;
                        component.Td = segment[2 + 2 * c] >> 4;
                        component.Ta = segment[2 + 2 * c] & 15;
                        scan.Add(component);
                    }
                    at = DecodeScan(data, at + 2 + length, scan, components, quant, dc, ac, interval, width, height, hMax, vMax);
                    if (at < 0) return null;
                    scanned = true;
                    continue;
                }
            }
            at += 2 + length;
        }
        if (!scanned) return null;
        return new ScreenJpegImage(width, height, ToRgb(components, width, height, hMax, vMax));
    }

    static int DecodeScan(ReadOnlySpan<byte> data, int start, List<Component> scan, List<Component> all, int[][] quant,
                          Huffman?[] dc, Huffman?[] ac, int interval, int width, int height, int hMax, int vMax)
    {
        foreach (var component in scan)
        {
            if (quant[component.Tq] is null || dc[component.Td & 3] is null || ac[component.Ta & 3] is null) return -1;
            component.Pred = 0;
        }
        var bits = new Bits(data, start);
        var block = new int[64];
        var mcus = 0;
        void Restart(ref Bits reader)
        {
            reader.Restart();
            foreach (var component in scan) component.Pred = 0;
        }
        if (scan.Count == 1)
        {
            var component = scan[0];
            var blocksX = ((width * component.H + hMax - 1) / hMax + 7) / 8;
            var blocksY = ((height * component.V + vMax - 1) / vMax + 7) / 8;
            for (var by = 0; by < blocksY; by++)
                for (var bx = 0; bx < blocksX; bx++)
                {
                    if (interval > 0 && mcus > 0 && mcus % interval == 0) Restart(ref bits);
                    DecodeBlock(ref bits, component, quant, dc, ac, block, bx, by);
                    mcus++;
                }
        }
        else
        {
            var mcuX = (width + 8 * hMax - 1) / (8 * hMax);
            var mcuY = (height + 8 * vMax - 1) / (8 * vMax);
            for (var my = 0; my < mcuY; my++)
                for (var mx = 0; mx < mcuX; mx++)
                {
                    if (interval > 0 && mcus > 0 && mcus % interval == 0) Restart(ref bits);
                    foreach (var component in scan)
                        for (var v = 0; v < component.V; v++)
                            for (var h = 0; h < component.H; h++)
                                DecodeBlock(ref bits, component, quant, dc, ac, block, mx * component.H + h, my * component.V + v);
                    mcus++;
                }
        }
        if (bits.Overrun > 64) throw new InvalidDataException("the scan ran out of data");
        // The scan's end: the next marker.
        var at = bits.At;
        while (at + 1 < data.Length && !(data[at] == 0xFF && data[at + 1] != 0 && data[at + 1] is not (>= 0xD0 and <= 0xD7))) at++;
        return at;
    }

    static void DecodeBlock(ref Bits bits, Component component, int[][] quant, Huffman?[] dc, Huffman?[] ac, int[] block, int bx, int by)
    {
        Array.Clear(block);
        var q = quant[component.Tq];
        var t = bits.Decode(dc[component.Td & 3]!);
        component.Pred += Extend(bits.Receive(t), t);
        block[0] = component.Pred * q[0];
        var table = ac[component.Ta & 3]!;
        for (var k = 1; k < 64;)
        {
            var rs = bits.Decode(table);
            int r = rs >> 4, s = rs & 15;
            if (s == 0)
            {
                if (r == 15) { k += 16; continue; }
                break;
            }
            k += r;
            if (k > 63) throw new InvalidDataException("coefficient");
            block[ZigZag[k]] = Extend(bits.Receive(s), s) * q[k];
            k++;
        }
        // Separable inverse DCT, then level shift and clamp into the component's plane.
        Span<float> rows = stackalloc float[64];
        for (var y = 0; y < 8; y++)
            for (var x = 0; x < 8; x++)
            {
                var sum = 0f;
                for (var u = 0; u < 8; u++) sum += Cosines[x, u] * block[y * 8 + u];
                rows[y * 8 + x] = sum / 2;
            }
        var stride = component.BlocksPerLine * 8;
        if (bx >= component.BlocksPerLine || by >= component.BlocksPerColumn) return;
        for (var x = 0; x < 8; x++)
            for (var y = 0; y < 8; y++)
            {
                var sum = 0f;
                for (var v = 0; v < 8; v++) sum += Cosines[y, v] * rows[v * 8 + x];
                var value = (int)MathF.Round(sum / 2) + 128;
                component.Plane[(by * 8 + y) * stride + bx * 8 + x] = (byte)Math.Clamp(value, 0, 255);
            }
    }

    static byte[] ToRgb(List<Component> components, int width, int height, int hMax, int vMax)
    {
        var rgb = new byte[width * height * 3];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var at = (y * width + x) * 3;
                if (components.Count == 1)
                {
                    var c = components[0];
                    var g = c.Plane[y * c.V / vMax * c.BlocksPerLine * 8 + x * c.H / hMax];
                    rgb[at] = g; rgb[at + 1] = g; rgb[at + 2] = g;
                    continue;
                }
                float Sample(Component c) => c.Plane[y * c.V / vMax * c.BlocksPerLine * 8 + x * c.H / hMax];
                float luma = Sample(components[0]), cb = Sample(components[1]) - 128, cr = Sample(components[2]) - 128;
                rgb[at] = (byte)Math.Clamp((int)MathF.Round(luma + 1.402f * cr), 0, 255);
                rgb[at + 1] = (byte)Math.Clamp((int)MathF.Round(luma - 0.344136f * cb - 0.714136f * cr), 0, 255);
                rgb[at + 2] = (byte)Math.Clamp((int)MathF.Round(luma + 1.772f * cb), 0, 255);
            }
        return rgb;
    }
}
