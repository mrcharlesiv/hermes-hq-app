using System.Text;

namespace Hermes.Core.BotPages;

/// A QR code for Telegram's setup link (the Mac draws it with CoreImage's `CIQRCodeGenerator`, correction level "M"):
/// byte mode, error correction M, the smallest version that fits, the mask with the lowest penalty. After the public
/// QR Code specification (ISO/IEC 18004) as Project Nayuki's reference encoder lays it out. Pure.
public sealed class QrCode
{
    public int Version { get; }
    public int Size { get; }
    public int Mask { get; }
    private readonly bool[,] _modules;
    private readonly bool[,] _function;

    /// Dark at row `y`, column `x`.
    public bool this[int x, int y] => _modules[y, x];

    private static readonly int[] EccPerBlock =
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
    private static readonly int[] Blocks =
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];
    private const int FormatBitsM = 0;

    /// `text` as UTF-8 bytes; null when it is too long for any version. `mask` -1 picks the best.
    public static QrCode? Encode(string text, int mask = -1)
    {
        var data = Encoding.UTF8.GetBytes(text);
        for (var ver = 1; ver <= 40; ver++)
        {
            var capacityBits = DataCodewords(ver) * 8;
            var used = 4 + (ver <= 9 ? 8 : 16) + data.Length * 8;
            if (used <= capacityBits) return new QrCode(ver, data, mask);
        }
        return null;
    }

    private QrCode(int ver, byte[] data, int mask)
    {
        Version = ver;
        Size = ver * 4 + 17;
        _modules = new bool[Size, Size];
        _function = new bool[Size, Size];
        DrawFunctionPatterns();
        DrawCodewords(AddEccAndInterleave(DataBytes(ver, data)));
        if (mask < 0)
        {
            var best = int.MaxValue;
            for (var m = 0; m < 8; m++)
            {
                ApplyMask(m);
                DrawFormatBits(m);
                var p = Penalty();
                if (p < best) { best = p; mask = m; }
                ApplyMask(m);
            }
        }
        Mask = mask;
        ApplyMask(mask);
        DrawFormatBits(mask);
    }

    // ------------------------------------------------------------------ data

    private static int RawDataModules(int ver)
    {
        var result = (16 * ver + 128) * ver + 64;
        if (ver >= 2)
        {
            var numAlign = ver / 7 + 2;
            result -= (25 * numAlign - 10) * numAlign - 55;
            if (ver >= 7) result -= 36;
        }
        return result;
    }

    private static int DataCodewords(int ver) => RawDataModules(ver) / 8 - EccPerBlock[ver] * Blocks[ver];

    private static byte[] DataBytes(int ver, byte[] data)
    {
        var bits = new List<bool>();
        void Append(int value, int length) { for (var i = length - 1; i >= 0; i--) bits.Add(((value >> i) & 1) != 0); }
        Append(4, 4);
        Append(data.Length, ver <= 9 ? 8 : 16);
        foreach (var b in data) Append(b, 8);
        var capacity = DataCodewords(ver) * 8;
        Append(0, Math.Min(4, capacity - bits.Count));
        Append(0, (8 - bits.Count % 8) % 8);
        for (var pad = 0xEC; bits.Count < capacity; pad ^= 0xEC ^ 0x11) Append(pad, 8);
        var output = new byte[bits.Count / 8];
        for (var i = 0; i < bits.Count; i++) if (bits[i]) output[i >> 3] |= (byte)(1 << (7 - (i & 7)));
        return output;
    }

    private byte[] AddEccAndInterleave(byte[] data)
    {
        var numBlocks = Blocks[Version];
        var blockEccLen = EccPerBlock[Version];
        var rawCodewords = RawDataModules(Version) / 8;
        var numShortBlocks = numBlocks - rawCodewords % numBlocks;
        var shortBlockLen = rawCodewords / numBlocks;
        var divisor = RsDivisor(blockEccLen);
        var blocks = new List<byte[]>();
        for (int i = 0, k = 0; i < numBlocks; i++)
        {
            var len = shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1);
            var dat = data[k..(k + len)];
            k += len;
            var ecc = RsRemainder(dat, divisor);
            var block = new List<byte>(dat);
            if (i < numShortBlocks) block.Add(0);
            block.AddRange(ecc);
            blocks.Add([.. block]);
        }
        var result = new List<byte>();
        for (var i = 0; i < blocks[0].Length; i++)
            for (var j = 0; j < blocks.Count; j++)
                if (i != shortBlockLen - blockEccLen || j >= numShortBlocks) result.Add(blocks[j][i]);
        return [.. result];
    }

    private static byte[] RsDivisor(int degree)
    {
        var result = new byte[degree];
        result[degree - 1] = 1;
        var root = 1;
        for (var i = 0; i < degree; i++)
        {
            for (var j = 0; j < result.Length; j++)
            {
                result[j] = (byte)Multiply(result[j], root);
                if (j + 1 < result.Length) result[j] ^= result[j + 1];
            }
            root = Multiply(root, 0x02);
        }
        return result;
    }

    private static byte[] RsRemainder(byte[] data, byte[] divisor)
    {
        var result = new byte[divisor.Length];
        foreach (var b in data)
        {
            var factor = b ^ result[0];
            Array.Copy(result, 1, result, 0, result.Length - 1);
            result[^1] = 0;
            for (var i = 0; i < result.Length; i++) result[i] ^= (byte)Multiply(divisor[i], factor);
        }
        return result;
    }

    private static int Multiply(int x, int y)
    {
        var z = 0;
        for (var i = 7; i >= 0; i--)
        {
            z = (z << 1) ^ ((z >> 7) * 0x11D);
            z ^= ((y >> i) & 1) * x;
        }
        return z;
    }

    // ------------------------------------------------------------------ drawing

    private void Set(int x, int y, bool dark) { _modules[y, x] = dark; _function[y, x] = true; }

    private void DrawFunctionPatterns()
    {
        for (var i = 0; i < Size; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
        Finder(3, 3); Finder(Size - 4, 3); Finder(3, Size - 4);
        var align = AlignmentPositions();
        var n = align.Count;
        for (var i = 0; i < n; i++)
            for (var j = 0; j < n; j++)
                if (!(i == 0 && j == 0 || i == 0 && j == n - 1 || i == n - 1 && j == 0)) Alignment(align[i], align[j]);
        DrawFormatBits(0);
        DrawVersion();
    }

    private void Finder(int x, int y)
    {
        for (var dy = -4; dy <= 4; dy++)
            for (var dx = -4; dx <= 4; dx++)
            {
                int xx = x + dx, yy = y + dy;
                var dist = Math.Max(Math.Abs(dx), Math.Abs(dy));
                if (xx >= 0 && xx < Size && yy >= 0 && yy < Size) Set(xx, yy, dist != 2 && dist != 4);
            }
    }

    private void Alignment(int x, int y)
    {
        for (var dy = -2; dy <= 2; dy++)
            for (var dx = -2; dx <= 2; dx++) Set(x + dx, y + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
    }

    private List<int> AlignmentPositions()
    {
        if (Version == 1) return [];
        var numAlign = Version / 7 + 2;
        var step = Version == 32 ? 26 : (Version * 4 + numAlign * 2 + 1) / (numAlign * 2 - 2) * 2;
        var result = new List<int> { 6 };
        for (var pos = Size - 7; result.Count < numAlign; pos -= step) result.Insert(1, pos);
        return result;
    }

    private void DrawFormatBits(int mask)
    {
        var data = FormatBitsM << 3 | mask;
        var rem = data;
        for (var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        var bits = (data << 10 | rem) ^ 0x5412;
        bool Bit(int i) => ((bits >> i) & 1) != 0;
        for (var i = 0; i <= 5; i++) Set(8, i, Bit(i));
        Set(8, 7, Bit(6)); Set(8, 8, Bit(7)); Set(7, 8, Bit(8));
        for (var i = 9; i < 15; i++) Set(14 - i, 8, Bit(i));
        for (var i = 0; i < 8; i++) Set(Size - 1 - i, 8, Bit(i));
        for (var i = 8; i < 15; i++) Set(8, Size - 15 + i, Bit(i));
        Set(8, Size - 8, true);
    }

    private void DrawVersion()
    {
        if (Version < 7) return;
        var rem = Version;
        for (var i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        var bits = Version << 12 | rem;
        for (var i = 0; i < 18; i++)
        {
            var bit = ((bits >> i) & 1) != 0;
            int a = Size - 11 + i % 3, b = i / 3;
            Set(a, b, bit); Set(b, a, bit);
        }
    }

    private void DrawCodewords(byte[] data)
    {
        var i = 0;
        for (var right = Size - 1; right >= 1; right -= 2)
        {
            if (right == 6) right = 5;
            for (var vert = 0; vert < Size; vert++)
                for (var j = 0; j < 2; j++)
                {
                    var x = right - j;
                    var upward = ((right + 1) & 2) == 0;
                    var y = upward ? Size - 1 - vert : vert;
                    if (!_function[y, x] && i < data.Length * 8)
                    {
                        _modules[y, x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0;
                        i++;
                    }
                }
        }
    }

    private void ApplyMask(int mask)
    {
        for (var y = 0; y < Size; y++)
            for (var x = 0; x < Size; x++)
            {
                var invert = mask switch
                {
                    0 => (x + y) % 2 == 0,
                    1 => y % 2 == 0,
                    2 => x % 3 == 0,
                    3 => (x + y) % 3 == 0,
                    4 => (x / 3 + y / 2) % 2 == 0,
                    5 => x * y % 2 + x * y % 3 == 0,
                    6 => (x * y % 2 + x * y % 3) % 2 == 0,
                    _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
                };
                if (invert && !_function[y, x]) _modules[y, x] = !_modules[y, x];
            }
    }

    // ------------------------------------------------------------------ penalty

    private int Penalty()
    {
        var result = 0;
        for (var pass = 0; pass < 2; pass++)
            for (var a = 0; a < Size; a++)
            {
                var runColor = false;
                var run = 0;
                var history = new int[7];
                for (var b = 0; b < Size; b++)
                {
                    var c = pass == 0 ? _modules[a, b] : _modules[b, a];
                    if (c == runColor)
                    {
                        run++;
                        if (run == 5) result += 3;
                        else if (run > 5) result++;
                    }
                    else
                    {
                        AddHistory(run, history);
                        if (!runColor) result += CountPatterns(history) * 40;
                        runColor = c;
                        run = 1;
                    }
                }
                result += TerminateAndCount(runColor, run, history) * 40;
            }
        for (var y = 0; y < Size - 1; y++)
            for (var x = 0; x < Size - 1; x++)
            {
                var c = _modules[y, x];
                if (c == _modules[y, x + 1] && c == _modules[y + 1, x] && c == _modules[y + 1, x + 1]) result += 3;
            }
        var dark = 0;
        foreach (var m in _modules) if (m) dark++;
        var total = Size * Size;
        var k = (Math.Abs(dark * 20 - total * 10) + total - 1) / total - 1;
        return result + k * 10;
    }

    private void AddHistory(int run, int[] history)
    {
        if (history[0] == 0) run += Size;
        Array.Copy(history, 0, history, 1, history.Length - 1);
        history[0] = run;
    }

    private static int CountPatterns(int[] h)
    {
        var n = h[1];
        var core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n;
        return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0);
    }

    private int TerminateAndCount(bool runColor, int run, int[] history)
    {
        if (runColor) { AddHistory(run, history); run = 0; }
        run += Size;
        AddHistory(run, history);
        return CountPatterns(history);
    }

    /// Rows of '#' (dark) and ' ' (light), for tests.
    public string Text()
    {
        var sb = new StringBuilder();
        for (var y = 0; y < Size; y++)
        {
            for (var x = 0; x < Size; x++) sb.Append(_modules[y, x] ? '#' : ' ');
            sb.Append('\n');
        }
        return sb.ToString();
    }
}
