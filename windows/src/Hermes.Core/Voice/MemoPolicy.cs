namespace Hermes.Core.Voice;

/// Why the recorder stopped on its own (MemoTypes.swift `MemoStopReason`, spec 1x-voice §3.3 step 4, §3.4).
public enum MemoStopReason { Interrupted, RouteLost, Reset, Background, Error, Limit, Cancel }

/// What becomes of a take the recorder stopped on its own.
public enum MemoFinish { Await, Draft, Discard }

/// The recorder's pure rules (HermesKit/Voice/MemoPolicy.swift at 93f984bb1): the gesture's runner uses `Finish`; the
/// recorder (MemoRecorder.cs, [WIN-VOICE-RECORDER]) the busy-input retry, the waveform and the two-decimal length.
public static class MemoPolicy
{
    /// The one retry after a busy input starts the microphone only for the same take, not stopped, with the app in
    /// front and no trip to the background during the 150 ms pause (MemoPolicy.swift lines 21-23).
    public static bool MayRetry(bool sameTake, bool stopped, bool active, bool backgrounded) =>
        sameTake && !stopped && active && !backgrounded;

    /// The recorder's average power (dBFS) as a 0…1 level (MemoPolicy.swift line 26).
    public static double Level(float power) => Math.Max(0, Math.Min(1, (power + 50f) / 50f));

    /// `count` bars from the per-100 ms levels: each bar is its stretch's loudest moment (three decimals), so a short
    /// memo still fills the bubble and a long one keeps its peaks (MemoPolicy.swift lines 30-38).
    public static double[] Peaks(IReadOnlyList<double> samples, int count = 48)
    {
        if (samples.Count == 0 || count <= 0) return new double[Math.Max(0, count)];
        var bars = new double[count];
        for (var bar = 0; bar < count; bar++)
        {
            var start = bar * samples.Count / count;
            var end = Math.Max(start + 1, (bar + 1) * samples.Count / count);
            var loudest = 0.0;
            for (var i = Math.Min(start, samples.Count - 1); i < Math.Min(end, samples.Count); i++)
                loudest = Math.Max(loudest, samples[i]);
            bars[bar] = Math.Round(loudest * 1000, MidpointRounding.AwayFromZero) / 1000;
        }
        return bars;
    }

    /// Two decimals (a MemoFile's `seconds`; MemoPolicy.swift line 63).
    public static double TwoDecimals(double value) => Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100;

    /// What happens to a take the recorder stopped on its own. Never a send: only the person's release or Send sends
    /// (C1). The length limit waits for the release rule; a call, a lost headset or the app hidden keeps the take as a
    /// draft once it is a second long.
    public static MemoFinish Finish(MemoStopReason reason, double elapsed) => reason switch
    {
        MemoStopReason.Limit => MemoFinish.Await,
        MemoStopReason.Cancel => MemoFinish.Discard,
        _ => elapsed >= 1 ? MemoFinish.Draft : MemoFinish.Discard,
    };

    /// The attachment limit until a Settings value exists: 32 MiB.
    public const int DefaultLimitBytes = 32 * 1024 * 1024;

    /// AAC mono 24 kHz at 48 kbps is 6 kB a second: ten minutes, or less when the attachment limit is smaller.
    public static double LimitSeconds(int limitBytes = DefaultLimitBytes) => Math.Min(600, Math.Floor(limitBytes * 0.95 / 6000));

    /// Below this a memo can't be recorded at all (`too-small`).
    public const double MinimumLimit = 10;

    /// "0:04", "1:30": whole seconds rounded down. For a clock that runs: the live timer, the time left while playing.
    public static string Length(double seconds)
    {
        var whole = Math.Max(0, double.IsFinite(seconds) ? (long)Math.Floor(seconds) : 0);
        return $"{whole / 60}:{whole % 60:00}";
    }

    /// A finished memo's length, rounded to the nearest second (half away from zero, as Swift's `rounded()`).
    public static string Total(double seconds) =>
        Length(double.IsFinite(seconds) ? Math.Round(seconds, MidpointRounding.AwayFromZero) : 0);
}
