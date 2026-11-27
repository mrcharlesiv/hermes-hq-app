using System.Buffers.Binary;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/TalkVAD.swift, TalkStopWord.swift, TalkEcho.swift, plus WAV/PCM encoding utilities.

public static class TalkLevel
{
    public const double MinDb = -50.0;
    public const double FloorRms = 1e-6;

    public static double Rms(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty) return 0;
        double sum = 0;
        for (var i = 0; i < samples.Length; i++)
        {
            double s = samples[i];
            sum += s * s;
        }
        return Math.Sqrt(sum / samples.Length);
    }

    public static double Rms(ReadOnlySpan<short> samples)
    {
        if (samples.IsEmpty) return 0;
        double sum = 0;
        for (var i = 0; i < samples.Length; i++)
        {
            double s = samples[i] / 32768.0;
            sum += s * s;
        }
        return Math.Sqrt(sum / samples.Length);
    }

    public static double Db(double rms) => rms <= FloorRms ? -160.0 : 20.0 * Math.Log10(rms);

    /// Maps RMS amplitude (0..1) into a normalized 0..1 UI meter level matching MemoPolicy.Level.
    public static double Level(double rms) => LevelFromDb(Db(rms));

    public static double LevelFromDb(double db) => Math.Clamp((db - MinDb) / (-MinDb), 0.0, 1.0);
}

public enum EndpointResult
{
    Listening,
    Speaking,
    Ended,
    TimedOut,
    TooShort,
}

/// Simple energy-based Voice Activity Detector with adaptive noise floor and silence hang-time.
public sealed class TakeEndpoint
{
    public double SpeechThreshold { get; set; } = 0.018;
    public double SilenceRatio { get; set; } = 0.6;
    public double MinSpeechMs { get; set; } = 220;
    public double SilenceEndMs { get; set; } = 1100;
    public double MaxTakeMs { get; set; } = 60_000;

    private double _noiseFloor = 0.004;
    private double _speechMs;
    private double _silenceMs;
    private double _totalMs;
    private bool _heardSpeech;

    public bool HeardSpeech => _heardSpeech;
    public double NoiseFloor => _noiseFloor;
    public double SpeechMs => _speechMs;
    public double SilenceMs => _silenceMs;

    public EndpointResult Feed(double rms, double dtMs)
    {
        if (dtMs <= 0) return _heardSpeech ? EndpointResult.Speaking : EndpointResult.Listening;
        var threshold = Math.Max(SpeechThreshold, _noiseFloor * 2.8);
        var releaseThreshold = threshold * SilenceRatio;

        if (!_heardSpeech)
        {
            if (rms >= threshold)
            {
                _heardSpeech = true;
                _speechMs = dtMs;
                _silenceMs = 0;
                _totalMs = dtMs;
                return EndpointResult.Speaking;
            }
            // Slowly adapt ambient noise floor while listening.
            _noiseFloor = _noiseFloor * 0.96 + Math.Min(rms, SpeechThreshold) * 0.04;
            return EndpointResult.Listening;
        }

        _totalMs += dtMs;
        if (rms >= releaseThreshold)
        {
            _speechMs += dtMs;
            _silenceMs = 0;
        }
        else
        {
            _silenceMs += dtMs;
        }

        if (_totalMs >= MaxTakeMs) return EndpointResult.TimedOut;
        if (_silenceMs >= SilenceEndMs)
            return _speechMs >= MinSpeechMs ? EndpointResult.Ended : EndpointResult.TooShort;
        return EndpointResult.Speaking;
    }

    public void Reset()
    {
        _speechMs = 0;
        _silenceMs = 0;
        _totalMs = 0;
        _heardSpeech = false;
    }
}

/// Detects sustained user speech during bot playback to trigger barge-in.
public sealed class BargeMonitor
{
    public double Threshold { get; set; } = 0.055;
    public double RequiredMs { get; set; } = 280;

    private double _aboveMs;

    public bool Feed(double rms, double dtMs)
    {
        if (dtMs <= 0) return false;
        if (rms >= Threshold)
        {
            _aboveMs += dtMs;
            if (_aboveMs >= RequiredMs)
            {
                _aboveMs = 0;
                return true;
            }
        }
        else
        {
            _aboveMs = Math.Max(0, _aboveMs - dtMs * 1.5);
        }
        return false;
    }

    public void Reset() => _aboveMs = 0;
}

/// Circular PCM buffer keeping the last ~350ms before speech onset so initial consonants aren't clipped.
public sealed class PreRoll
{
    private readonly short[] _ring;
    private int _write;
    private int _count;

    public PreRoll(int capacitySamples = 5600)
    {
        _ring = new short[Math.Max(1, capacitySamples)];
    }

    public int Capacity => _ring.Length;
    public int Count => _count;

    public void Push(ReadOnlySpan<short> samples)
    {
        for (var i = 0; i < samples.Length; i++)
        {
            _ring[_write] = samples[i];
            _write = (_write + 1) % _ring.Length;
            if (_count < _ring.Length) _count++;
        }
    }

    public short[] Drain()
    {
        if (_count == 0) return [];
        var result = new short[_count];
        var start = (_write - _count + _ring.Length) % _ring.Length;
        for (var i = 0; i < _count; i++)
            result[i] = _ring[(start + i) % _ring.Length];
        Clear();
        return result;
    }

    public void Clear()
    {
        _write = 0;
        _count = 0;
    }
}

/// Pure RIFF/WAVE 16-bit PCM encoder/decoder & resampler (no OS calls, cross-platform net9.0).
public static class TalkWave
{
    public const int HeaderSize = 44;

    public static byte[] EncodeWav(ReadOnlySpan<short> pcm, int sampleRate = 16000, int channels = 1)
    {
        var dataBytes = pcm.Length * sizeof(short);
        var wav = new byte[HeaderSize + dataBytes];
        WriteHeaderBytes(wav.AsSpan(0, HeaderSize), sampleRate, channels, 16, dataBytes);
        for (var i = 0; i < pcm.Length; i++)
            BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(HeaderSize + i * 2, 2), pcm[i]);
        return wav;
    }

    public static void WriteWavHeader(Stream stream, int sampleRate, int channels, int bitsPerSample, int dataBytes)
    {
        Span<byte> header = stackalloc byte[HeaderSize];
        WriteHeaderBytes(header, sampleRate, channels, bitsPerSample, dataBytes);
        stream.Write(header);
    }

    public static void PatchWavHeader(Stream stream, int dataBytes)
    {
        if (!stream.CanSeek) return;
        Span<byte> buf = stackalloc byte[4];
        stream.Position = 4;
        BinaryPrimitives.WriteInt32LittleEndian(buf, 36 + dataBytes);
        stream.Write(buf);
        stream.Position = 40;
        BinaryPrimitives.WriteInt32LittleEndian(buf, dataBytes);
        stream.Write(buf);
        stream.Flush();
    }

    private static void WriteHeaderBytes(Span<byte> h, int sampleRate, int channels, int bitsPerSample, int dataBytes)
    {
        Encoding.ASCII.GetBytes("RIFF", h[0..4]);
        BinaryPrimitives.WriteInt32LittleEndian(h[4..8], 36 + dataBytes);
        Encoding.ASCII.GetBytes("WAVE", h[8..12]);
        Encoding.ASCII.GetBytes("fmt ", h[12..16]);
        BinaryPrimitives.WriteInt32LittleEndian(h[16..20], 16);
        BinaryPrimitives.WriteInt16LittleEndian(h[20..22], 1); // PCM
        BinaryPrimitives.WriteInt16LittleEndian(h[22..24], (short)channels);
        BinaryPrimitives.WriteInt32LittleEndian(h[24..28], sampleRate);
        var blockAlign = channels * (bitsPerSample / 8);
        BinaryPrimitives.WriteInt32LittleEndian(h[28..32], sampleRate * blockAlign);
        BinaryPrimitives.WriteInt16LittleEndian(h[32..34], (short)blockAlign);
        BinaryPrimitives.WriteInt16LittleEndian(h[34..36], (short)bitsPerSample);
        Encoding.ASCII.GetBytes("data", h[36..40]);
        BinaryPrimitives.WriteInt32LittleEndian(h[40..44], dataBytes);
    }

    public static (short[] Samples, int SampleRate, int Channels) DecodePcm16(byte[] wav)
    {
        if (wav.Length < HeaderSize) throw new InvalidDataException("WAV too short.");
        if (Encoding.ASCII.GetString(wav, 0, 4) != "RIFF" || Encoding.ASCII.GetString(wav, 8, 4) != "WAVE")
            throw new InvalidDataException("Not a RIFF/WAVE file.");
        var pos = 12;
        int channels = 0, sampleRate = 0, bits = 0;
        while (pos + 8 <= wav.Length)
        {
            var id = Encoding.ASCII.GetString(wav, pos, 4);
            var size = BinaryPrimitives.ReadInt32LittleEndian(wav.AsSpan(pos + 4, 4));
            pos += 8;
            if (size < 0 || pos + size > wav.Length) break;
            if (id == "fmt " && size >= 16)
            {
                channels = BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(pos + 2, 2));
                sampleRate = BinaryPrimitives.ReadInt32LittleEndian(wav.AsSpan(pos + 4, 4));
                bits = BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(pos + 14, 2));
            }
            else if (id == "data")
            {
                if (bits != 16 || channels <= 0 || sampleRate <= 0)
                    throw new InvalidDataException("Unsupported WAV PCM format.");
                var count = size / 2;
                var samples = new short[count];
                for (var i = 0; i < count; i++)
                    samples[i] = BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(pos + i * 2, 2));
                return (samples, sampleRate, channels);
            }
            pos += size + (size & 1);
        }
        throw new InvalidDataException("No data chunk found in WAV.");
    }

    public static short[] FloatToPcm16(ReadOnlySpan<float> samples)
    {
        var pcm = new short[samples.Length];
        for (var i = 0; i < samples.Length; i++)
        {
            var clamped = Math.Clamp(samples[i], -1f, 1f);
            pcm[i] = (short)Math.Round(clamped * 32767f);
        }
        return pcm;
    }

    public static float[] Pcm16ToFloat(ReadOnlySpan<short> pcm)
    {
        var output = new float[pcm.Length];
        for (var i = 0; i < pcm.Length; i++) output[i] = pcm[i] / 32768f;
        return output;
    }

    public static short[] ResampleLinear(ReadOnlySpan<short> input, int fromRate, int toRate)
    {
        if (input.IsEmpty || fromRate <= 0 || toRate <= 0 || fromRate == toRate) return input.ToArray();
        var outLen = (int)Math.Round(input.Length * (double)toRate / fromRate);
        if (outLen <= 0) return [];
        var output = new short[outLen];
        var ratio = (double)(input.Length - 1) / Math.Max(1, outLen - 1);
        for (var i = 0; i < outLen; i++)
        {
            var src = i * ratio;
            var idx = (int)src;
            var frac = src - idx;
            var a = input[Math.Min(idx, input.Length - 1)];
            var b = input[Math.Min(idx + 1, input.Length - 1)];
            output[i] = (short)Math.Round(a + (b - a) * frac);
        }
        return output;
    }
}

// MARK: - TalkStopWord (TalkStopWord.swift)

public static class TalkStopWord
{
    private static readonly Regex StripPunct = new(@"[^\p{L}\p{N}\s']", RegexOptions.CultureInvariant);
    private static readonly Regex Spaces = new(@"\s+", RegexOptions.CultureInvariant);

    private static readonly HashSet<string> ExactPhrases = new(StringComparer.OrdinalIgnoreCase)
    {
        "stop",
        "stop talking",
        "stop voice",
        "stop voice chat",
        "end voice",
        "end voice chat",
        "end conversation",
        "end the conversation",
        "end call",
        "hang up",
        "goodbye",
        "good bye",
        "bye",
        "bye bye",
        "exit voice",
        "exit voice mode",
        "quit voice",
        "turn off voice",
        "that's all",
        "thats all",
        "we're done",
        "were done",
        "i'm done",
        "im done",
    };

    public static string Normalize(string text)
    {
        var clean = StripPunct.Replace(text.Replace('’', '\''), " ");
        return Spaces.Replace(clean, " ").Trim().ToLowerInvariant();
    }

    public static bool IsStopPhrase(string text, string? botName = null)
    {
        var norm = Normalize(text);
        if (norm.Length == 0) return false;
        if (ExactPhrases.Contains(norm)) return true;
        if (!string.IsNullOrWhiteSpace(botName))
        {
            var bot = Normalize(botName);
            if (bot.Length > 0)
            {
                if (norm.EndsWith(" " + bot, StringComparison.Ordinal))
                {
                    var withoutBot = norm[..^(bot.Length + 1)].Trim();
                    if (ExactPhrases.Contains(withoutBot)) return true;
                }
                if (norm.StartsWith(bot + " ", StringComparison.Ordinal))
                {
                    var withoutBot = norm[(bot.Length + 1)..].Trim();
                    if (ExactPhrases.Contains(withoutBot)) return true;
                }
            }
        }
        return false;
    }

    public static bool IsTypedStop(string text)
    {
        var norm = Normalize(text);
        return norm is "stop" or "end voice" or "end voice chat" or "hang up" or "stop voice" or "stop talking";
    }
}

// MARK: - TalkEcho (TalkEcho.swift)

public static class TalkEcho
{
    private static readonly Regex NonWord = new(@"[^\p{L}\p{N}\s]", RegexOptions.CultureInvariant);
    private static readonly Regex Spaces = new(@"\s+", RegexOptions.CultureInvariant);

    public const double DefaultWindowSeconds = 4.0;
    public const double DefaultThreshold = 0.65;

    public static string Normalize(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        return Spaces.Replace(NonWord.Replace(text.ToLowerInvariant(), " "), " ").Trim();
    }

    /// Word-level containment / Dice-Sørensen similarity in 0..1 to detect bot TTS leaking back into the mic.
    public static double Similarity(string heard, string spoken)
    {
        var a = Normalize(heard);
        var b = Normalize(spoken);
        if (a.Length == 0 || b.Length == 0) return 0;
        if (b.Contains(a, StringComparison.Ordinal)) return 1.0;

        var aWords = a.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var bWords = b.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (aWords.Length == 0 || bWords.Length == 0) return 0;

        var bCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var w in bWords) bCounts[w] = bCounts.GetValueOrDefault(w) + 1;

        var matched = 0;
        foreach (var w in aWords)
        {
            if (bCounts.TryGetValue(w, out var left) && left > 0)
            {
                bCounts[w] = left - 1;
                matched++;
            }
        }
        // Fraction of heard words present in what the bot just spoke.
        return (double)matched / aWords.Length;
    }

    public static bool IsEcho(string heard, string recentlySpoken, double elapsedSinceSpokenSeconds,
        double threshold = DefaultThreshold, double windowSeconds = DefaultWindowSeconds)
    {
        if (elapsedSinceSpokenSeconds < 0 || elapsedSinceSpokenSeconds > windowSeconds) return false;
        if (string.IsNullOrWhiteSpace(heard) || string.IsNullOrWhiteSpace(recentlySpoken)) return false;
        return Similarity(heard, recentlySpoken) >= threshold;
    }
}
