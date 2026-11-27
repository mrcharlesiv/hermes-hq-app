// [WIN-SCREEN-RFB-CORE] The native RFB 3.8 client that replaces noVNC (docs/spec/3x-screen.md §2.3), ported from the
// Mac's HermesKit/Screen/RFBProtocol.swift at 93f984bb1: an incremental parser over a growing byte buffer (RFB
// messages do not line up with WebSocket frames, so it must give the same result fed one byte at a time), the
// handshake, the server messages, and the client message encoders. Bad data ends in a typed error, never a crash, and
// never grows memory without bound. No sockets, no UI: ScreenStream / ScreenSession (later slices) own the transport.

using System.Globalization;
using System.Text;

namespace Hermes.Core.Screen;

public enum RfbErrorKind
{
    BadVersion,
    NoSecurity,                 // "None" is not offered (Hermes serves None on a private socket)
    SecurityFailed,
    BadSize,                    // 0 × 0, or over 8192 a side / 64 MB
    UnknownMessage,
    UnknownEncoding,
    RectOutside,
    TooLong,                    // a declared length over its cap
    Zlib,
    BadFilter,
    BadJpegs,                   // three in a row
    Overflow,                   // the parse buffer passed 16 MiB
}

/// The Swift `RFBError`: a kind plus the payload two of its cases carry (the security failure's reason, the unknown
/// message type or encoding). Value equality, as the Swift enum's.
public sealed record RfbError(RfbErrorKind Kind, string Reason = "", int Value = 0)
{
    public static readonly RfbError BadVersion = new(RfbErrorKind.BadVersion);
    public static readonly RfbError NoSecurity = new(RfbErrorKind.NoSecurity);
    public static readonly RfbError BadSize = new(RfbErrorKind.BadSize);
    public static readonly RfbError RectOutside = new(RfbErrorKind.RectOutside);
    public static readonly RfbError TooLong = new(RfbErrorKind.TooLong);
    public static readonly RfbError Zlib = new(RfbErrorKind.Zlib);
    public static readonly RfbError BadFilter = new(RfbErrorKind.BadFilter);
    public static readonly RfbError BadJpegs = new(RfbErrorKind.BadJpegs);
    public static readonly RfbError Overflow = new(RfbErrorKind.Overflow);
    public static RfbError SecurityFailed(string reason) => new(RfbErrorKind.SecurityFailed, Reason: reason);
    public static RfbError UnknownMessage(byte type) => new(RfbErrorKind.UnknownMessage, Value: type);
    public static RfbError UnknownEncoding(int encoding) => new(RfbErrorKind.UnknownEncoding, Value: encoding);

    /// A content-free name for the log.
    public string LogName => Kind switch
    {
        RfbErrorKind.BadVersion => "bad-version",
        RfbErrorKind.NoSecurity => "no-security",
        RfbErrorKind.SecurityFailed => "security-failed",
        RfbErrorKind.BadSize => "bad-size",
        RfbErrorKind.UnknownMessage => "unknown-message",
        RfbErrorKind.UnknownEncoding => "unknown-encoding",
        RfbErrorKind.RectOutside => "rect-outside",
        RfbErrorKind.TooLong => "too-long",
        RfbErrorKind.Zlib => "zlib",
        RfbErrorKind.BadFilter => "bad-filter",
        RfbErrorKind.BadJpegs => "bad-jpegs",
        _ => "overflow",
    };
}

/// What `RfbParser.Feed` throws (the Swift typed `throws(RFBError)`).
public sealed class RfbException(RfbError error) : Exception(error.LogName)
{
    public RfbError Error { get; } = error;
}

/// What the client sends (only message types 0, 2, 3, 4, 5, 6: anything else closes the gateway's stream with 1003).
public static class RfbMessage
{
    /// Tight, CopyRect, Raw, quality 7, compression 2, LastRect, DesktopSize, ExtendedDesktopSize: in this order. Never
    /// Cursor (-239), ExtendedMouseButtons, ContinuousUpdates, Fence, XVP or H.264 (they break the gateway's framing
    /// or the pull model).
    public static readonly IReadOnlyList<int> Encodings = [7, 1, 0, -25, -254, -224, -223, -308];
    public const int MaxCutText = 262_144;

    /// 32 bits per pixel, depth 24, little-endian, true colour, 255/255/255, shifts R 16 · G 8 · B 0 (BGRX in memory).
    public static byte[] SetPixelFormat() => [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0];

    public static byte[] SetEncodings(IReadOnlyList<int>? list = null)
    {
        list ??= Encodings;
        var out_ = new List<byte> { 2, 0, (byte)((list.Count >> 8) & 0xFF), (byte)(list.Count & 0xFF) };
        foreach (var value in list) out_.AddRange(Be32(unchecked((uint)value)));
        return [.. out_];
    }

    public static byte[] UpdateRequest(bool incremental, int width, int height) =>
        [3, (byte)(incremental ? 1 : 0), 0, 0, 0, 0, .. Be16(width), .. Be16(height)];

    public static byte[] Key(uint keysym, bool down) => [4, (byte)(down ? 1 : 0), 0, 0, .. Be32(keysym)];

    public static byte[] Pointer(byte mask, int x, int y) => [5, mask, .. Be16(x), .. Be16(y)];

    /// Latin-1 bytes, at most 262,144 (longer text is typed instead).
    public static byte[] CutText(ReadOnlySpan<byte> latin1) => [6, 0, 0, 0, .. Be32((uint)latin1.Length), .. latin1];

    static byte[] Be16(int value)
    {
        var clamped = Math.Max(0, Math.Min(65535, value));
        return [(byte)((clamped >> 8) & 0xFF), (byte)(clamped & 0xFF)];
    }

    static byte[] Be32(uint value) => [(byte)(value >> 24), (byte)((value >> 16) & 0xFF), (byte)((value >> 8) & 0xFF), (byte)(value & 0xFF)];
}

/// One connection's parser and decoders. Owned by the stream's task (not thread-safe).
public sealed class RfbParser
{
    public sealed class Output : IEquatable<Output>
    {
        /// Bytes to send now (handshake replies, then SetPixelFormat, SetEncodings and the first request).
        public List<byte[]> Send { get; } = [];
        /// ServerInit arrived: the desktop's size and name.
        public bool Ready { get; set; }
        /// FramebufferUpdates completed in this feed.
        public int Updates { get; set; }
        public int Rects { get; set; }
        /// The desktop changed size: the next request must ask for the whole picture.
        public bool Resized { get; set; }

        public bool Equals(Output? other) =>
            other is not null && Ready == other.Ready && Updates == other.Updates && Rects == other.Rects && Resized == other.Resized
            && Send.Count == other.Send.Count && Send.Zip(other.Send).All(pair => pair.First.AsSpan().SequenceEqual(pair.Second));
        public override bool Equals(object? obj) => Equals(obj as Output);
        public override int GetHashCode() => HashCode.Combine(Ready, Updates, Rects, Resized, Send.Count);
    }

    public const int MaxBuffer = 16 * 1024 * 1024;
    public const int MaxTight = 4 * 1024 * 1024;
    public const int MaxSkip = 16 * 1024 * 1024;

    public ScreenFramebuffer? Framebuffer { get; private set; }
    public string Name { get; private set; } = "";
    /// An update has begun and its last rect has not arrived (the stuck rule watches this).
    public bool MidUpdate { get; private set; }
    public int FailedJpegs { get; private set; }

    enum Phase { Version, SecurityTypes, SecurityResult, LegacySecurity, FailReason, ServerInit, Message, Rect, RawRows, Skip }
    Phase phase = Phase.Version;
    // rawRows(x, y, w, h, row) and skip(left)
    int rawX, rawY, rawW, rawH, rawRow;
    long skipLeft;

    byte[] bytes = new byte[4096];
    int count;
    int head;
    int minor = 8;
    int rectsLeft;
    int jpegRun;
    readonly TightStreams streams = new();
    readonly IScreenJpegDecoder jpeg;

    public RfbParser(IScreenJpegDecoder? jpeg = null) => this.jpeg = jpeg ?? ScreenJpeg.Decoder;

    int Available => count - head;
    int U8(int offset) => bytes[head + offset];
    int U16(int offset) => bytes[head + offset] << 8 | bytes[head + offset + 1];
    long U32(int offset) => (long)bytes[head + offset] << 24 | (long)bytes[head + offset + 1] << 16 | (long)bytes[head + offset + 2] << 8 | bytes[head + offset + 3];

    /// Takes more server bytes. Throws `RfbException` on bad data; after a throw the parser must not be fed again.
    public Output Feed(ReadOnlySpan<byte> data)
    {
        Append(data);
        var out_ = new Output();
        while (Step(out_)) { }
        if (head > 0)
        {
            Buffer.BlockCopy(bytes, head, bytes, 0, count - head);
            count -= head;
            head = 0;
        }
        if (count > MaxBuffer) throw new RfbException(RfbError.Overflow);
        return out_;
    }

    void Append(ReadOnlySpan<byte> data)
    {
        if (count + data.Length > bytes.Length)
        {
            var grown = new byte[Math.Max(bytes.Length * 2, count + data.Length)];
            Buffer.BlockCopy(bytes, 0, grown, 0, count);
            bytes = grown;
        }
        data.CopyTo(bytes.AsSpan(count));
        count += data.Length;
    }

    static RfbException Fail(RfbError error) => new(error);

    /// One unit of progress. false: more bytes are needed.
    bool Step(Output out_)
    {
        switch (phase)
        {
            case Phase.Version:
            {
                if (Available < 12) return false;
                var line = Encoding.UTF8.GetString(bytes, head, 12);
                if (!line.StartsWith("RFB ", StringComparison.Ordinal) || !line.EndsWith('\n') || line.Length != 12
                    || !SwiftInt(line.Substring(4, 3), out var major) || !SwiftInt(line.Substring(8, 3), out var minorValue)
                    || !(major == 3 && minorValue >= 3 || major > 3))
                    throw Fail(RfbError.BadVersion);
                head += 12;
                minor = major > 3 || minorValue >= 8 ? 8 : (minorValue == 7 ? 7 : 3);
                out_.Send.Add(Encoding.UTF8.GetBytes($"RFB 003.00{minor}\n"));
                phase = minor == 3 ? Phase.LegacySecurity : Phase.SecurityTypes;
                break;
            }
            case Phase.SecurityTypes:
            {
                if (Available < 1) return false;
                var n = U8(0);
                if (n == 0)
                {
                    head += 1;
                    phase = Phase.FailReason;
                    return true;
                }
                if (Available < 1 + n) return false;
                var offered = bytes.AsSpan(head + 1, n).Contains((byte)1);
                head += 1 + n;
                if (!offered) throw Fail(RfbError.NoSecurity);
                out_.Send.Add([1]);
                if (minor == 8) phase = Phase.SecurityResult; else ClientInit(out_);
                break;
            }
            case Phase.LegacySecurity:
            {
                if (Available < 4) return false;
                var kind = U32(0);
                head += 4;
                if (kind == 0) { phase = Phase.FailReason; return true; }
                if (kind != 1) throw Fail(RfbError.NoSecurity);
                ClientInit(out_);
                break;
            }
            case Phase.SecurityResult:
            {
                if (Available < 4) return false;
                var result = U32(0);
                head += 4;
                if (result != 0) { phase = Phase.FailReason; return true; }
                ClientInit(out_);
                break;
            }
            case Phase.FailReason:
            {
                if (Available < 4) return false;
                var length = U32(0);
                if (length > 4096) throw Fail(RfbError.SecurityFailed(""));
                if (Available < 4 + length) return false;
                var reason = Encoding.UTF8.GetString(bytes, head + 4, (int)length);
                head += 4 + (int)length;
                throw Fail(RfbError.SecurityFailed(reason));
            }
            case Phase.ServerInit:
            {
                if (Available < 24) return false;
                int width = U16(0), height = U16(2);
                var length = U32(20);
                if (length > 4096) throw Fail(RfbError.TooLong);
                if (Available < 24 + length) return false;
                Name = Encoding.UTF8.GetString(bytes, head + 24, (int)length);
                head += 24 + (int)length;
                Framebuffer = ScreenFramebuffer.Create(width, height) ?? throw Fail(RfbError.BadSize);
                out_.Ready = true;
                out_.Send.Add(RfbMessage.SetPixelFormat());
                out_.Send.Add(RfbMessage.SetEncodings());
                out_.Send.Add(RfbMessage.UpdateRequest(incremental: false, width, height));
                phase = Phase.Message;
                break;
            }
            case Phase.Message:
            {
                if (Available < 1) return false;
                switch (U8(0))
                {
                    case 0:
                        if (Available < 4) return false;
                        rectsLeft = U16(2);
                        head += 4;
                        if (rectsLeft == 0) out_.Updates += 1; else { MidUpdate = true; phase = Phase.Rect; }
                        break;
                    case 1:                                     // SetColourMapEntries: skipped
                    {
                        if (Available < 6) return false;
                        var n = U16(4);
                        head += 6;
                        skipLeft = n * 6;
                        phase = Phase.Skip;
                        break;
                    }
                    case 2:                                     // Bell
                        head += 1;
                        break;
                    case 3:                                     // ServerCutText: skipped (the phone never copies the remote clipboard)
                    {
                        if (Available < 8) return false;
                        var length = U32(4);
                        if (length > MaxSkip) throw Fail(RfbError.TooLong);
                        head += 8;
                        skipLeft = length;
                        phase = Phase.Skip;
                        break;
                    }
                    default:
                        throw Fail(RfbError.UnknownMessage((byte)U8(0)));
                }
                break;
            }
            case Phase.Skip:
            {
                if (skipLeft == 0) { phase = Phase.Message; return true; }
                if (Available <= 0) return false;
                var taken = (int)Math.Min(skipLeft, Available);
                head += taken;
                if (taken == skipLeft) phase = Phase.Message; else skipLeft -= taken;
                break;
            }
            case Phase.Rect:
                return Rect(out_);
            case Phase.RawRows:
            {
                var rowBytes = rawW * 4;
                if (rowBytes == 0 || rawRow >= rawH) { EndRect(out_); return true; }
                var rows = Math.Min(rawH - rawRow, Available / rowBytes);
                if (rows <= 0 || Framebuffer is not { } buffer) return false;
                buffer.WriteRaw(rawX, rawY + rawRow, rawW, rows, bytes.AsSpan(head, rows * rowBytes));
                head += rows * rowBytes;
                if (rawRow + rows >= rawH) EndRect(out_); else rawRow += rows;
                break;
            }
        }
        return true;
    }

    /// Swift's `Int(String)`: an optional sign then decimal digits, nothing else.
    static bool SwiftInt(string text, out int value) =>
        int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value);

    void ClientInit(Output out_)
    {
        out_.Send.Add([1]);                                     // shared, as noVNC asks
        phase = Phase.ServerInit;
    }

    void EndRect(Output out_)
    {
        out_.Rects += 1;
        rectsLeft -= 1;
        if (rectsLeft <= 0) EndUpdate(out_); else phase = Phase.Rect;
    }

    void EndUpdate(Output out_)
    {
        rectsLeft = 0;
        MidUpdate = false;
        out_.Updates += 1;
        phase = Phase.Message;
    }

    bool Rect(Output out_)
    {
        if (Available < 12 || Framebuffer is not { } buffer) return false;
        int x = U16(0), y = U16(2), w = U16(4), h = U16(6);
        var encoding = unchecked((int)(uint)U32(8));
        switch (encoding)
        {
            case -224:                                          // LastRect
                head += 12;
                out_.Rects += 1;
                EndUpdate(out_);
                return true;
            case -223 or -308:                                  // DesktopSize / ExtendedDesktopSize
            {
                var extra = 0;
                if (encoding == -308)
                {
                    if (Available < 16) return false;
                    extra = 4 + 16 * U8(12);
                    if (Available < 12 + extra) return false;
                }
                head += 12 + extra;
                // An ExtendedDesktopSize that answers a request of ours with an error (y != 0) changes nothing.
                if (!(encoding == -308 && y != 0) && (w != buffer.Width || h != buffer.Height))
                {
                    Framebuffer = ScreenFramebuffer.Create(w, h) ?? throw Fail(RfbError.BadSize);
                    out_.Resized = true;
                }
                EndRect(out_);
                return true;
            }
        }
        if (!buffer.Contains(x, y, w, h)) throw Fail(RfbError.RectOutside);
        switch (encoding)
        {
            case 0:
                head += 12;
                (rawX, rawY, rawW, rawH, rawRow) = (x, y, w, h, 0);
                phase = Phase.RawRows;
                return true;
            case 1:
            {
                if (Available < 16) return false;
                int fromX = U16(12), fromY = U16(14);
                if (!buffer.Contains(fromX, fromY, w, h)) throw Fail(RfbError.RectOutside);
                head += 16;
                buffer.CopyRect(x, y, w, h, fromX, fromY);
                EndRect(out_);
                return true;
            }
            case 7:
                return Tight(out_, buffer, x, y, w, h);
            default:
                throw Fail(RfbError.UnknownEncoding(encoding));
        }
    }

    /// Tight's 1–3 byte length at `offset`: (value, bytes used), null when it has not all arrived.
    (int Value, int Used)? Compact(int offset)
    {
        if (Available <= offset) return null;
        var value = U8(offset) & 0x7F;
        if ((U8(offset) & 0x80) == 0) return (value, 1);
        if (Available <= offset + 1) return null;
        value |= (U8(offset + 1) & 0x7F) << 7;
        if ((U8(offset + 1) & 0x80) == 0) return (value, 2);
        if (Available <= offset + 2) return null;
        return (value | U8(offset + 2) << 14, 3);
    }

    bool Tight(Output out_, ScreenFramebuffer buffer, int x, int y, int w, int h)
    {
        if (Available < 13) return false;
        var control = U8(12);
        var kind = control >> 4;
        var at = 13;
        if (kind == 8)                                          // Fill
        {
            if (Available < at + 3) return false;
            ResetStreams(control);
            buffer.Fill(x, y, w, h, bytes[head + at], bytes[head + at + 1], bytes[head + at + 2]);
            head += at + 3;
            EndRect(out_);
            return true;
        }
        if (kind == 9)                                          // JPEG
        {
            if (Compact(at) is not var (length, used)) return false;
            if (length > MaxTight) throw Fail(RfbError.TooLong);
            at += used;
            if (Available < at + length) return false;
            ResetStreams(control);
            var ok = buffer.DrawJpeg(bytes.AsSpan(head + at, length), x, y, w, h, jpeg);
            head += at + length;
            if (ok) jpegRun = 0;
            else
            {
                jpegRun += 1;
                FailedJpegs += 1;
                if (jpegRun >= 3) throw Fail(RfbError.BadJpegs);
            }
            EndRect(out_);
            return true;
        }
        if (kind >= 8) throw Fail(RfbError.BadFilter);
        // Basic: stream in bits 4–5, bit 6 = an explicit filter byte.
        var stream = kind & 3;
        var filter = 0;
        byte[] palette = [];
        if ((kind & 4) != 0)
        {
            if (Available < at + 1) return false;
            filter = U8(at);
            at += 1;
        }
        var size = w * h * 3;
        switch (filter)
        {
            case 0 or 2: break;
            case 1:
            {
                if (Available < at + 1) return false;
                var colours = U8(at) + 1;
                if (colours < 2) throw Fail(RfbError.BadFilter);
                if (Available < at + 1 + colours * 3) return false;
                palette = bytes.AsSpan(head + at + 1, colours * 3).ToArray();
                at += 1 + colours * 3;
                size = colours == 2 ? (w + 7) / 8 * h : w * h;
                break;
            }
            default: throw Fail(RfbError.BadFilter);
        }
        byte[] data;
        if (size < 12)
        {
            if (Available < at + size) return false;
            ResetStreams(control);
            data = bytes.AsSpan(head + at, size).ToArray();
            at += size;
        }
        else
        {
            if (Compact(at) is not var (length, used)) return false;
            if (length > MaxTight) throw Fail(RfbError.TooLong);
            at += used;
            if (Available < at + length) return false;
            ResetStreams(control);
            data = streams.Inflate(stream, bytes.AsSpan(head + at, length), size);
            at += length;
        }
        head += at;
        byte[] rgb = filter switch
        {
            1 => TightFilter.Palette(data, palette, w, h) ?? throw Fail(RfbError.BadFilter),
            2 => TightFilter.Gradient(data, w, h),
            _ => data,
        };
        if (w > 0 && h > 0) buffer.WriteRgb(x, y, w, h, rgb);
        EndRect(out_);
        return true;
    }

    /// The control byte's low four bits reset zlib streams 0–3 (applied once the whole rect has arrived).
    void ResetStreams(int control)
    {
        for (var index = 0; index < 4; index++) if ((control & (1 << index)) != 0) streams.Reset(index);
    }
}
