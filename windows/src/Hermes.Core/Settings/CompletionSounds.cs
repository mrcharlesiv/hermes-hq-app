using System.Text;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Settings › Sounds › Completion Sound (spec 1x-settings §3.7; App/Audio/CompletionCue.swift): on by default, a cue
/// when a bot's reply finishes, and Sound (the web's `$completionSoundVariantId`, default 1 "Two-Note Comfort"). Kept
/// under the Mac's keys in this PC's preferences file. The app plays the WAV bytes `CompletionSoundSynth` makes.
public sealed class CompletionSoundPrefs(IPreferences prefs)
{
    public const string Key = "hqn.completionSoundOn";
    public const string VariantKey = "hqn.completionSoundVariant";

    public bool IsOn
    {
        get => prefs.Get(Key) != "false";
        set => prefs.Set(Key, value ? null : "false");
    }

    /// An id that isn't a preset's reads as 1.
    public int Variant
    {
        get => int.TryParse(prefs.Get(VariantKey), out var id) && CompletionSoundSynth.Presets.Any(p => p.Id == id) ? id : 1;
        set => prefs.Set(VariantKey, value == 1 ? null : value.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    /// Plays at most one cue per chat every 2 s (`dedupeWindow`).
    public static readonly TimeSpan DedupeWindow = TimeSpan.FromSeconds(2);
}

/// One reply finished: whether its cue plays (on, at most once per chat in the window). Not thread-safe; the UI thread
/// calls it.
public sealed class CompletionCueGate
{
    private readonly Dictionary<string, DateTimeOffset> _last = [];

    public bool ShouldPlay(string sessionKey, DateTimeOffset now, bool on)
    {
        if (!on) return false;
        if (_last.TryGetValue(sessionKey, out var last) && now - last < CompletionSoundPrefs.DedupeWindow) return false;
        _last[sessionKey] = now;
        if (_last.Count > 64)
            foreach (var k in _last.Where(kv => now - kv.Value >= CompletionSoundPrefs.DedupeWindow).Select(kv => kv.Key).ToList()) _last.Remove(k);
        return true;
    }
}

/// The cue's samples (pure maths; App/Audio/CompletionSounds.swift and CompletionCueSynth): fourteen presets rendered
/// as the web renders them, through master gain, a low-pass and a small room, as 16-bit mono WAV.
public static class CompletionSoundSynth
{
    public const double SampleRate = 44_100;

    public enum Wave { Sine, Square, Triangle }

    public abstract record Voice;
    public sealed record Tone(double Freq, double Start = 0, double Dur = 0, double Gain = 0.5, double Attack = 0.006, Wave Shape = Wave.Sine) : Voice;
    public sealed record Pluck(double From, double To, double Start = 0, double Gain = 0, double Decay = 0, double Glide = 0.16, double Attack = 0.004) : Voice;
    public sealed record Bloom(double Freq, double Start = 0, double Gain = 0, double Attack = 0, double Hold = 0.08, double Decay = 0,
        double Detune = 0, double? FreqTo = null, Wave Shape = Wave.Sine) : Voice;
    public sealed record Air(double Freq, double Start = 0, double Gain = 0, double Decay = 0, double Q = 1.2) : Voice;
    public sealed record Whoosh(double From, double To, double Start = 0, double Gain = 0, double Decay = 0, double Q = 0.8) : Voice;
    public sealed record Sweep(double From, double To, double Start = 0, double Gain = 0, double Decay = 0, double Attack = 0.003, Wave Shape = Wave.Triangle) : Voice;

    public sealed record Preset(int Id, string Name, IReadOnlyList<Voice> Voices);

    // Notes (equal temperament), as the web names them.
    private const double A2 = 110.0, A3 = 220.0, A4 = 440.0, A5 = 880.0, B5 = 987.77, C3 = 130.81, C4 = 261.63, E4 = 329.63;
    private const double E5 = 659.25, E6 = 1318.51, G4 = 392.0, G5 = 783.99, C5 = 523.25, C6 = 1046.5;

    public static readonly IReadOnlyList<Preset> Presets =
    [
        new(1, "Two-Note Comfort", [
            new Tone(E4, Dur: 0.22, Gain: 0.05, Attack: 0.03), new Tone(C4, Start: 0.08, Dur: 0.52, Gain: 0.07, Attack: 0.08),
            new Tone(C3, Start: 0.08, Dur: 0.46, Gain: 0.02, Attack: 0.1)]),
        new(2, "Glass Ping", [
            new Tone(C6, Dur: 0.55, Gain: 0.032, Attack: 0.002), new Tone(E5, Start: 0.01, Dur: 0.42, Gain: 0.018, Attack: 0.004),
            new Air(3200, Gain: 0.004, Decay: 0.1, Q: 1.4)]),
        new(3, "Soft Marimba", [
            new Pluck(E5, G5, Gain: 0.03, Decay: 0.14, Glide: 0.08),
            new Bloom(C5, Start: 0.04, Gain: 0.028, Attack: 0.08, Hold: 0.04, Decay: 0.62),
            new Bloom(G4, Start: 0.06, Gain: 0.014, Attack: 0.12, Hold: 0.06, Decay: 0.55)]),
        new(4, "Tri-Tone Message", [
            new Tone(C6, Dur: 0.14, Gain: 0.045, Attack: 0.004), new Tone(A5, Start: 0.1, Dur: 0.16, Gain: 0.04, Attack: 0.004),
            new Tone(G5, Start: 0.2, Dur: 0.22, Gain: 0.035, Attack: 0.006)]),
        new(5, "Airy Whoosh", [
            new Whoosh(4200, 900, Gain: 0.022, Decay: 0.28, Q: 0.7), new Tone(A5, Start: 0.12, Dur: 0.35, Gain: 0.02, Attack: 0.02)]),
        new(6, "Discovery Cluster", [
            .. new[] { -14.0, -5, 0, 7, 12 }.Select((detune, i) =>
                (Voice)new Bloom(A3, Start: i * 0.03, Gain: 0.012, Attack: 0.38, Hold: 0.12, Decay: 1.05, Detune: detune)),
            new Bloom(E4, Start: 0.1, Gain: 0.008, Attack: 0.45, Hold: 0.08, Decay: 0.9, Detune: 3)]),
        new(7, "Systems Online", [
            new Tone(C5, Dur: 0.16, Gain: 0.04, Attack: 0.006), new Tone(G5, Start: 0.09, Dur: 0.28, Gain: 0.042, Attack: 0.008),
            new Tone(C4, Start: 0.09, Dur: 0.24, Gain: 0.012, Attack: 0.01)]),
        new(8, "Retro Terminal", [
            new Tone(B5, Dur: 0.12, Gain: 0.038, Attack: 0.002, Shape: Wave.Square),
            new Tone(E5, Start: 0.14, Dur: 0.1, Gain: 0.028, Attack: 0.002, Shape: Wave.Square)]),
        new(9, "Modem Chirp", [
            new Sweep(320, 2200, Gain: 0.024, Decay: 0.16), new Sweep(480, 1400, Start: 0.1, Gain: 0.014, Decay: 0.12, Shape: Wave.Sine)]),
        new(10, "Wind Chimes", [.. new[] { G5, C6, E5, A5 }.Select((f, i) =>
            (Voice)new Tone(f, Start: i * 0.13, Dur: 0.72, Gain: 0.028 - i * 0.003, Attack: 0.003))]),
        new(11, "Singing Bowl", [
            new Bloom(A3, Gain: 0.022, Attack: 0.58, Hold: 0.16, Decay: 1.35),
            new Bloom(E4, Start: 0.08, Gain: 0.01, Attack: 0.62, Hold: 0.12, Decay: 1.2, Detune: 4),
            new Bloom(A4, Start: 0.14, Gain: 0.006, Attack: 0.68, Hold: 0.08, Decay: 1.05, Detune: -3)]),
        new(12, "Harp Lift", [
            .. new[] { C5, E5, G5, C6 }.Select((f, i) => (Voice)new Tone(f, Start: i * 0.075, Dur: 0.38, Gain: 0.034 - i * 0.004, Attack: 0.012)),
            new Bloom(C4, Start: 0.2, Gain: 0.01, Attack: 0.18, Hold: 0.06, Decay: 0.7)]),
        new(13, "Sonar Ping", [
            new Tone(A2, Dur: 0.95, Gain: 0.036, Attack: 0.008), new Tone(A3, Start: 0.42, Dur: 0.55, Gain: 0.014, Attack: 0.01),
            new Air(600, Gain: 0.005, Decay: 0.2, Q: 0.5)]),
        new(14, "Music Box", [.. new[] { E6, C6, G5, E5 }.Select((f, i) =>
            (Voice)new Pluck(f, f * 0.998, Start: i * 0.09, Gain: 0.02 - i * 0.002, Decay: 0.2, Glide: 0.06))]),
    ];

    public static Preset Find(int id) => Presets.FirstOrDefault(p => p.Id == id) ?? Presets[0];

    /// WebAudio's `exponentialRampToValueAtTime` from `v0` at `t0` to `v1` at `t1`.
    public static double Ramp(double v0, double v1, double t0, double t1, double t) => v0 * Math.Pow(v1 / v0, (t - t0) / (t1 - t0));

    /// WebAudio's envelope: 0.0001 at `start`, exponential to `peak` at `start + attack`, held to `holdEnd`, exponential
    /// to 0.0001 at `end`; silent after.
    public static double Envelope(double t, double start, double attack, double holdEnd, double end, double peak)
    {
        var top = Math.Max(peak, 0.0002);
        if (t < start || t > end + 0.02) return 0;
        if (t <= start + attack) return Ramp(0.0001, top, start, start + attack, t);
        if (t <= holdEnd) return top;
        if (t <= end) return Ramp(top, 0.0001, holdEnd, end, t);
        return 0.0001;
    }

    public static double Shape(Wave wave, double phase)
    {
        var cycle = phase - Math.Floor(phase);
        return wave switch
        {
            Wave.Square => cycle < 0.5 ? 1 : -1,
            Wave.Triangle => 4 * Math.Abs(cycle - 0.5) - 1,
            _ => Math.Sin(2 * Math.PI * cycle),
        };
    }

    // ---------------------------------------------------------------- variant 1, as shipped (CompletionCueSynth)

    private sealed record CueVoice(double Freq, double Start, double Dur, double Peak, double Attack);

    private static readonly CueVoice[] CueVoices =
    [
        new(329.63, 0.01, 0.22, 0.05, 0.03),
        new(261.63, 0.09, 0.52, 0.07, 0.08),
        new(130.81, 0.09, 0.46, 0.02, 0.10),
    ];

    private static double[] CueDry()
    {
        var count = (int)(SampleRate * 1.0);
        var out_ = new double[count];
        foreach (var v in CueVoices)
        {
            double start = v.Start, peakAt = start + v.Attack, end = start + v.Dur, top = Math.Max(v.Peak, 0.0002);
            for (var i = 0; i < count; i++)
            {
                var t = i / SampleRate;
                double gain;
                if (t < start || t > end + 0.02) gain = 0;
                else if (t <= peakAt) gain = Ramp(0.0001, top, start, peakAt, t);
                else if (t <= end) gain = Ramp(top, 0.0001, peakAt, end, t);
                else gain = 0.0001;
                if (gain > 0) out_[i] += Math.Sin(2 * Math.PI * v.Freq * (t - v.Start)) * gain;
            }
        }
        return out_;
    }

    // ---------------------------------------------------------------- the other presets

    /// The voices summed (before the master chain), long enough for the longest tail.
    public static double[] Dry(Preset preset)
    {
        var length = preset.Voices.Count > 0 ? Math.Min(2.6, preset.Voices.Max(End) + 0.3) : 1;
        var out_ = new double[(int)(SampleRate * length)];
        var noise = new SplitMix(unchecked((ulong)preset.Id * 0x9E3779B97F4A7C15UL));
        foreach (var v in preset.Voices) Add(v, out_, ref noise);
        return out_;
    }

    private static double End(Voice v) => v switch
    {
        Tone t => t.Start + t.Dur,
        Pluck p => p.Start + p.Decay,
        Bloom b => b.Start + b.Attack + b.Hold + b.Decay,
        Air a => a.Start + a.Decay,
        Whoosh w => w.Start + w.Decay,
        Sweep s => s.Start + s.Decay,
        _ => 0,
    };

    private static void Add(Voice voice, double[] out_, ref SplitMix noise)
    {
        switch (voice)
        {
            case Tone t:
                Oscillate(out_, t.Start, t.Start + t.Dur, _ => t.Freq, t.Shape,
                    x => Envelope(x, t.Start, t.Attack, t.Start + t.Attack, t.Start + t.Dur, t.Gain));
                break;
            case Pluck p:
                Oscillate(out_, p.Start, p.Start + p.Decay,
                    x => x >= p.Start + p.Glide ? p.To : Ramp(p.From, p.To, p.Start, p.Start + p.Glide, Math.Max(x, p.Start)), Wave.Triangle,
                    x => Envelope(x, p.Start, p.Attack, p.Start + p.Attack, p.Start + p.Decay, p.Gain));
                break;
            case Bloom b:
                var baseF = b.Freq * Math.Pow(2, b.Detune / 1200);
                var target = (b.FreqTo ?? b.Freq) * Math.Pow(2, b.Detune / 1200);
                var glideEnd = b.Start + b.Attack + b.Hold * 0.6;
                var end = b.Start + b.Attack + b.Hold + b.Decay;
                Oscillate(out_, b.Start, end,
                    x => b.FreqTo == null || x >= glideEnd ? (b.FreqTo == null ? baseF : target) : Ramp(baseF, target, b.Start, glideEnd, Math.Max(x, b.Start)),
                    b.Shape, x => Envelope(x, b.Start, b.Attack, b.Start + b.Attack + b.Hold, end, b.Gain));
                break;
            case Air a:
                FilteredNoise(out_, a.Start, a.Start + a.Decay, _ => a.Freq, a.Q, ref noise,
                    x => Envelope(x, a.Start, 0.018, a.Start + 0.018, a.Start + a.Decay, a.Gain));
                break;
            case Whoosh w:
                FilteredNoise(out_, w.Start, w.Start + w.Decay,
                    x => Ramp(w.From, w.To, w.Start, w.Start + w.Decay, Math.Min(Math.Max(x, w.Start), w.Start + w.Decay)), w.Q, ref noise,
                    x => Envelope(x, w.Start, 0.03, w.Start + 0.03, w.Start + w.Decay, w.Gain));
                break;
            case Sweep s:
                var sweepEnd = s.Start + s.Decay - 0.02;
                Oscillate(out_, s.Start, s.Start + s.Decay,
                    x => x >= sweepEnd ? s.To : Ramp(s.From, s.To, s.Start, sweepEnd, Math.Max(x, s.Start)), s.Shape,
                    x => Envelope(x, s.Start, s.Attack, s.Start + s.Attack, s.Start + s.Decay, s.Gain));
                break;
        }
    }

    private static void Oscillate(double[] out_, double start, double end, Func<double, double> frequency, Wave shape, Func<double, double> gain)
    {
        var phase = 0.0;
        int first = Math.Max(0, (int)(start * SampleRate)), last = Math.Min(out_.Length, (int)((end + 0.02) * SampleRate));
        for (var i = first; i < last; i++)
        {
            var t = i / SampleRate;
            out_[i] += Shape(shape, phase) * gain(t);
            phase += frequency(t) / SampleRate;
        }
    }

    /// White noise through an RBJ band-pass (constant peak gain) whose centre may move.
    private static void FilteredNoise(double[] out_, double start, double end, Func<double, double> center, double q, ref SplitMix noise,
        Func<double, double> gain)
    {
        int first = Math.Max(0, (int)(start * SampleRate)), last = Math.Min(out_.Length, (int)((end + 0.02) * SampleRate));
        double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
        for (var i = first; i < last; i++)
        {
            var t = i / SampleRate;
            var w0 = 2 * Math.PI * Math.Min(center(t), SampleRate * 0.45) / SampleRate;
            double alpha = Math.Sin(w0) / (2 * q), cw = Math.Cos(w0);
            double b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
            var x = noise.NextSigned();
            var y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            out_[i] += y * gain(t);
        }
    }

    // ---------------------------------------------------------------- master chain, room, WAV

    /// Master 0.48, then an RBJ low-pass biquad (3,800 Hz, Q 0.32).
    public static float[] Master(double[] samples)
    {
        double w0 = 2 * Math.PI * 3800 / SampleRate, alpha = Math.Sin(w0) / (2 * 0.32), cw = Math.Cos(w0);
        double b0 = (1 - cw) / 2, b1 = 1 - cw, b2 = (1 - cw) / 2, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
        double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
        var out_ = new float[samples.Length];
        for (var i = 0; i < samples.Length; i++)
        {
            var x = samples[i] * 0.48;
            var y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            out_[i] = (float)y;
        }
        return out_;
    }

    /// Dry 0.88 plus a small room (a short Schroeder reverb: 4 combs, 2 all-passes).
    public static float[] Mixed(float[] dry)
    {
        var combs = new[] { 1116, 1188, 1277, 1356 }.Select(d => (int)(d * SampleRate / 44_100)).ToArray();
        var wet = new float[dry.Length];
        foreach (var delay in combs)
        {
            var buffer = new float[delay];
            var index = 0;
            for (var i = 0; i < dry.Length; i++)
            {
                var out_ = buffer[index];
                buffer[index] = dry[i] + out_ * 0.72f;
                index = (index + 1) % delay;
                wet[i] += out_ / combs.Length;
            }
        }
        foreach (var delay in new[] { 556, 441 })
        {
            var buffer = new float[delay];
            var index = 0;
            for (var i = 0; i < wet.Length; i++)
            {
                var held = buffer[index];
                var out_ = -wet[i] + held;
                buffer[index] = wet[i] + held * 0.5f;
                index = (index + 1) % delay;
                wet[i] = out_;
            }
        }
        var mixed = new float[dry.Length];
        for (var i = 0; i < dry.Length; i++) mixed[i] = dry[i] * 0.88f + wet[i] * 0.34f;
        return mixed;
    }

    /// The chosen preset as 16-bit mono WAV bytes (variant 1 keeps its original renderer).
    public static byte[] Wav(int id) =>
        Wav(Mixed(Master(id == 1 ? CueDry() : Dry(Find(id)))));

    public static byte[] Wav(float[] samples)
    {
        var peak = samples.Length == 0 ? 0 : samples.Max(Math.Abs);
        // The web's level is quiet by design; leave it, only guard against clipping.
        var scale = peak > 0.98f ? 0.98f / peak : 1f;
        using var ms = new MemoryStream(44 + samples.Length * 2);
        using var w = new BinaryWriter(ms, Encoding.ASCII);
        var dataBytes = samples.Length * 2;
        w.Write("RIFF"u8); w.Write((uint)(36 + dataBytes));
        w.Write("WAVE"u8); w.Write("fmt "u8);
        w.Write(16u); w.Write((ushort)1); w.Write((ushort)1);
        w.Write((uint)SampleRate); w.Write((uint)(SampleRate * 2));
        w.Write((ushort)2); w.Write((ushort)16);
        w.Write("data"u8); w.Write((uint)dataBytes);
        foreach (var s in samples) w.Write((short)(Math.Clamp(s * scale, -1f, 1f) * short.MaxValue));
        w.Flush();
        return ms.ToArray();
    }

    /// A small deterministic noise source (the same cue every time).
    public struct SplitMix(ulong seed)
    {
        private ulong _state = seed;

        public ulong Next()
        {
            unchecked
            {
                _state += 0x9E3779B97F4A7C15UL;
                var z = _state;
                z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
                z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
                return z ^ (z >> 31);
            }
        }

        public double NextSigned() => (Next() >> 11) / (double)(1UL << 53) * 2 - 1;
    }
}
