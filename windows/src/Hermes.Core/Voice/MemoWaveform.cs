using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Voice;

// A history memo's waveform when the shape store has none (spec 1x-voice §6.3; HermesKit/Voice/MemoWaveform.swift at
// 93f984bb1): the performance plugin's `media/waveform` route when the gateway advertises it, else the file is fetched
// into the playback cache and its peaks are computed off the UI thread. One computation at a time; a bubble that
// scrolls away cancels its own; a memo whose computation failed is never asked again this launch.

/// 48 peaks (0…1) and the length in seconds.
public readonly record struct MemoPeaks(IReadOnlyList<double> Peaks, double Seconds);

/// Decoded audio, read in blocks of float samples (AVAudioFile's processing format: one array per channel, ±1.0).
public interface IMemoAudioSource : IDisposable
{
    /// Frames in the file (one sample per channel each).
    long Length { get; }
    double SampleRate { get; }
    int Channels { get; }
    /// Reads up to `frames` frames into `buffer[channel][0..]` from the current position; returns how many it read
    /// (0 at the end or when nothing more decodes).
    int Read(float[][] buffer, int frames);
}

/// Opens an audio file for `MemoWaveform.Compute` (the Mac's `AVAudioFile(forReading:)`). `WavMemoAudio` reads WAV
/// (PCM 16-bit, 24-bit, 32-bit and 32-bit float) with no OS help. The recorder's memos are AAC in .m4a: a Windows
/// implementation would open them with Media Foundation (MFCreateSourceReaderFromURL, the first audio stream's output
/// type set to MFAudioFormat_Float, MF_PD_DURATION and MF_MT_AUDIO_SAMPLES_PER_SECOND for the length) and hand WAV
/// files to `WavMemoAudio`. It throws on a file it can't open.
public interface IMemoAudioDecoder
{
    IMemoAudioSource Open(string file);
}

public sealed class MemoWaveformException(string message) : Exception(message);

public static class MemoWaveform
{
    public const int PeakCount = 48;
    /// Audio over this many seconds is refused.
    public const double MaxSeconds = 660;
    /// Frames per read, whatever the length (bounded memory).
    public const int BlockFrames = 4096;

    public const string EmptyOrLong = "Audio is empty or exceeds the memo limit.";
    public const string Undecodable = "Audio could not be decoded.";
    public const string Unavailable = "Waveform unavailable";

    public static MemoPeaks Compute(string file, IMemoAudioDecoder decoder, CancellationToken ct = default)
    {
        using var source = decoder.Open(file);
        return Compute(source, ct);
    }

    /// 48 peaks (0…1, normalised to the loudest) and the length. Refuses audio over 660 s. Bounded memory: 4,096
    /// frames per read, whatever the length. Honours cancellation.
    public static MemoPeaks Compute(IMemoAudioSource file, CancellationToken ct = default)
    {
        var length = file.Length;
        var rate = file.SampleRate;
        var channels = file.Channels;
        if (length <= 0 || !(rate > 0) || channels <= 0 || channels > 8 || length / rate > MaxSeconds)
            throw new MemoWaveformException(EmptyOrLong);
        var buffer = new float[channels][];
        for (var c = 0; c < channels; c++) buffer[c] = new float[BlockFrames];
        var peaks = new double[PeakCount];
        long position = 0;
        while (position < length)
        {
            ct.ThrowIfCancellationRequested();
            var read = file.Read(buffer, (int)Math.Min(BlockFrames, length - position));
            if (read <= 0) throw new MemoWaveformException(Undecodable);
            for (var frame = 0; frame < read; frame++)
            {
                var bin = (int)Math.Min(PeakCount - 1, (position + frame) * PeakCount / length);
                for (var channel = 0; channel < channels; channel++)
                {
                    var sample = (double)Math.Abs(buffer[channel][frame]);
                    if (double.IsFinite(sample)) peaks[bin] = Math.Max(peaks[bin], sample);
                }
            }
            position += read;
        }
        var maximum = peaks.Max();
        var normalised = maximum > 0
            ? peaks.Select(p => Math.Round(p / maximum * 1000, MidpointRounding.AwayFromZero) / 1000).ToArray()
            : peaks;
        return new MemoPeaks(normalised, length / rate);
    }

    /// The plugin's answer, or null when the route is off or answered "not here" (it then stays off for the account
    /// until the next `replay_epoch`). Accepts only `{"schema":"media.waveform.v1","peaks":[48 in 0…1],"seconds":>0}`.
    /// `GET /api/plugins/<route>/media/waveform?path=&profile=`.
    public static async Task<MemoPeaks?> FromPluginAsync(string path, string? profile, string route, IMemoGateway client,
        string epoch, WaveformRouteGate gate, CancellationToken ct = default)
    {
        var account = client.AccountId;
        if (gate.IsDisabled(account, epoch)) return null;
        var query = new List<KeyValuePair<string, string>> { new("path", path) };
        if (!string.IsNullOrEmpty(profile)) query.Add(new("profile", profile));
        byte[] data;
        try
        {
            data = await client.RestAsync("GET", $"/api/plugins/{route}/media/waveform", query, null, ct);
        }
        catch (GatewayException e) when (e.Code == "http"
            && (e.Status is 405 or 501 || (e.Status == 404 && (e.Body ?? "").Contains("Not Found", StringComparison.Ordinal))))
        {
            gate.Disable(account, epoch);
            return null;
        }
        var answer = JsonNode.Parse(Encoding.UTF8.GetString(data));
        if (answer.Str("schema") != "media.waveform.v1" || answer.Arr("peaks") is not { Count: PeakCount } raw
            || Number(answer.Get("seconds")) is not { } seconds || !double.IsFinite(seconds) || seconds <= 0)
            throw new MemoWaveformException(Unavailable);
        var peaks = raw.Select(Number).Where(v => v.HasValue).Select(v => v!.Value).ToArray();
        if (peaks.Length != PeakCount || !peaks.All(p => double.IsFinite(p) && p >= 0 && p <= 1))
            throw new MemoWaveformException(Unavailable);
        return new MemoPeaks(peaks, seconds);
    }

    // JSONValue.double: a JSON number (never a string or a bool).
    private static double? Number(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.Number && v.TryGetValue<double>(out var d) ? d : null;
}

/// Accounts whose waveform route was refused: off until the gateway restarts (a new replay epoch). Thread-safe.
public sealed class WaveformRouteGate
{
    public static readonly WaveformRouteGate Shared = new();
    private readonly Dictionary<string, string> _disabled = [];

    public bool IsDisabled(string account, string epoch)
    {
        lock (_disabled) return _disabled.TryGetValue(account, out var e) && e == epoch;
    }

    public void Disable(string account, string epoch)
    {
        lock (_disabled) _disabled[account] = epoch;
    }
}

/// One waveform computation at a time (W:src/memo-waveform-queue.ts). Requests for one path share a flight; a
/// requester that goes away (its bubble scrolled off) cancels a flight nobody else waits for. Thread-safe.
public sealed class MemoWaveformQueue
{
    public static readonly MemoWaveformQueue Shared = new();

    private sealed class Entry(Task<MemoPeaks> task, CancellationTokenSource cancel)
    {
        public Task<MemoPeaks> Task { get; } = task;
        public CancellationTokenSource Cancel { get; } = cancel;
        public int Users = 1;
    }

    private readonly object _gate = new();
    private readonly Dictionary<string, Entry> _pending = [];
    private Task _tail = Task.CompletedTask;

    /// Loads `path`'s shape with `work`, serialised behind the computation before it. Call `Leave` when the asker goes.
    public Task<MemoPeaks> Load(string path, Func<CancellationToken, Task<MemoPeaks>> work)
    {
        lock (_gate)
        {
            if (_pending.TryGetValue(path, out var entry))
            {
                entry.Users++;
                return entry.Task;
            }
            var previous = _tail;
            var cancel = new CancellationTokenSource();
            var task = Run(previous, cancel.Token, work);
            _tail = task.ContinueWith(_ => { }, TaskScheduler.Default);
            var made = new Entry(task, cancel);
            _pending[path] = made;
            task.ContinueWith(_ => Finished(path, made), TaskScheduler.Default);
            return task;
        }
    }

    private static async Task<MemoPeaks> Run(Task previous, CancellationToken ct, Func<CancellationToken, Task<MemoPeaks>> work)
    {
        await previous.ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return await work(ct).ConfigureAwait(false);
    }

    /// The bubble that asked went away: cancel when nobody else waits.
    public void Leave(string path)
    {
        lock (_gate)
        {
            if (!_pending.TryGetValue(path, out var entry)) return;
            entry.Users--;
            if (entry.Users <= 0)
            {
                entry.Cancel.Cancel();
                _pending.Remove(path);
            }
        }
    }

    private void Finished(string path, Entry entry)
    {
        lock (_gate)
        {
            if (_pending.TryGetValue(path, out var current) && current == entry) _pending.Remove(path);
        }
    }
}

/// WAV files with no OS help (RIFF/WAVE, `fmt ` PCM 16/24/32-bit or IEEE float 32-bit, 1–8 channels, and
/// WAVE_FORMAT_EXTENSIBLE of those). What the fixture recorder writes, and what a gateway's WAV memos are.
public sealed class WavMemoAudio : IMemoAudioSource
{
    private readonly Stream _stream;
    private readonly int _bits;
    private readonly bool _float;
    private readonly long _dataEnd;
    private byte[] _scratch = [];

    public long Length { get; }
    public double SampleRate { get; }
    public int Channels { get; }

    public static readonly IMemoAudioDecoder Decoder = new WavDecoder();

    private sealed class WavDecoder : IMemoAudioDecoder
    {
        public IMemoAudioSource Open(string file) => new WavMemoAudio(File.OpenRead(file));
    }

    public WavMemoAudio(Stream stream)
    {
        _stream = stream;
        var reader = new BinaryReader(stream, Encoding.ASCII, leaveOpen: true);
        if (Encoding.ASCII.GetString(reader.ReadBytes(4)) != "RIFF") throw Bad();
        reader.ReadUInt32();
        if (Encoding.ASCII.GetString(reader.ReadBytes(4)) != "WAVE") throw Bad();
        int format = 0, channels = 0, bits = 0;
        uint rate = 0;
        while (true)
        {
            var id = Encoding.ASCII.GetString(reader.ReadBytes(4));
            if (id.Length < 4) throw Bad();
            var size = reader.ReadUInt32();
            var start = stream.Position;
            if (id == "fmt ")
            {
                format = reader.ReadUInt16();
                channels = reader.ReadUInt16();
                rate = reader.ReadUInt32();
                reader.ReadUInt32();
                reader.ReadUInt16();
                bits = reader.ReadUInt16();
                if (format == 0xFFFE && size >= 40)
                {
                    reader.ReadUInt16();
                    reader.ReadUInt16();
                    reader.ReadUInt32();
                    format = reader.ReadUInt16();   // the sub-format GUID's first two bytes
                }
            }
            else if (id == "data")
            {
                if (format == 0 || channels <= 0 || rate == 0) throw Bad();
                _float = format == 3;
                if (!(format == 1 && bits is 16 or 24 or 32) && !(_float && bits == 32)) throw Bad();
                _bits = bits;
                Channels = channels;
                SampleRate = rate;
                var available = Math.Min(size, stream.Length - start);
                Length = available / (channels * (bits / 8));
                _dataEnd = start + Length * channels * (bits / 8);
                stream.Position = start;
                return;
            }
            stream.Position = start + size + (size & 1);
        }
    }

    private static InvalidDataException Bad() => new("Not a WAV file this app can read.");

    public int Read(float[][] buffer, int frames)
    {
        var frameBytes = Channels * (_bits / 8);
        var want = (int)Math.Min(frames, (_dataEnd - _stream.Position) / frameBytes);
        if (want <= 0) return 0;
        if (_scratch.Length < want * frameBytes) _scratch = new byte[want * frameBytes];
        var got = 0;
        while (got < want * frameBytes)
        {
            var n = _stream.Read(_scratch, got, want * frameBytes - got);
            if (n <= 0) break;
            got += n;
        }
        var count = got / frameBytes;
        var step = _bits / 8;
        for (var frame = 0; frame < count; frame++)
        {
            for (var channel = 0; channel < Channels; channel++)
            {
                var at = (frame * Channels + channel) * step;
                buffer[channel][frame] = _bits switch
                {
                    16 => BitConverter.ToInt16(_scratch, at) / 32768f,
                    24 => ((_scratch[at] | (_scratch[at + 1] << 8) | (_scratch[at + 2] << 16)) << 8 >> 8) / 8388608f,
                    _ when _float => BitConverter.ToSingle(_scratch, at),
                    _ => BitConverter.ToInt32(_scratch, at) / 2147483648f,
                };
            }
        }
        return count;
    }

    public void Dispose() => _stream.Dispose();
}
