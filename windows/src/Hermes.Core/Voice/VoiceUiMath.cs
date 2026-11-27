namespace Hermes.Core.Voice;

// Pure UI layout & display math for Voice Memos, Dictation, Live Words, and Talk visualizers
// so every bar-height calculation, speed label, countdown, and intro copy is unit-testable in Hermes.Core.Tests.

public sealed record MemoBubbleSnapshot(
    VoiceMemo Memo,
    MemoPlayState PlayState,
    bool LoadFailed,
    double DurationSeconds,
    double CurrentTimeSeconds,
    double Progress,
    double Speed,
    string SpeedLabel,
    string ClockText,
    string WordsText,
    IReadOnlyList<double> Peaks,
    bool HasPeaks);

public static class MemoBubbleLayout
{
    public const int BarCount = 48;
    public const double SeekStepSeconds = 5.0;

    public static string SpeedLabel(double speed) => speed switch
    {
        >= 1.9 => "2×",
        >= 1.4 => "1.5×",
        _ => "1×",
    };

    public static double[] BarHeights(IReadOnlyList<double>? peaks, int count = BarCount, double minHeight = 3.0, double maxHeight = 24.0)
    {
        var n = Math.Max(1, count);
        var heights = new double[n];
        if (peaks == null || peaks.Count == 0)
        {
            // Flat placeholder bars while waveform computes.
            for (var i = 0; i < n; i++) heights[i] = minHeight + 2.0;
            return heights;
        }
        var span = Math.Max(0, maxHeight - minHeight);
        for (var i = 0; i < n; i++)
        {
            var src = i * peaks.Count / n;
            var v = Math.Clamp(peaks[Math.Min(src, peaks.Count - 1)], 0, 1);
            // Gentle perceptual lift so quiet speech remains visible.
            var lifted = Math.Pow(v, 0.72);
            heights[i] = Math.Round(minHeight + lifted * span, 2);
        }
        return heights;
    }

    public static MemoBubbleSnapshot Snapshot(
        VoiceMemo memo,
        MemoPlayer? player,
        MemoShapeStore? shapes,
        bool pending,
        bool sendFailed)
    {
        var state = player?.StateOf(memo.Path) ?? MemoPlayState.Idle;
        var failed = (player?.Failed.Contains(memo.Path) ?? false) || MemoLoadFailures.Contains(memo.Path);
        var shape = shapes?.Shape(memo.Path);
        var duration = player != null && player.IsCurrent(memo.Path) && player.Duration > 0
            ? player.Duration
            : shape?.Seconds ?? 0;
        var current = player?.CurrentTime(memo.Path) ?? 0;
        var progress = duration > 0 ? Math.Clamp(current / duration, 0, 1) : 0;
        var speed = player?.Speed ?? 1.0;
        var clock = state is MemoPlayState.Playing or MemoPlayState.Paused && duration > 0
            ? MemoPolicy.Length(Math.Max(0, duration - current))
            : duration > 0 ? MemoPolicy.Total(duration) : "0:00";
        var words = MemoText.BubbleWords(memo, pending, sendFailed);
        var peaks = shape?.Peaks ?? [];
        return new MemoBubbleSnapshot(
            memo, state, failed, duration, current, progress, speed, SpeedLabel(speed), clock, words, peaks, peaks.Count > 0);
    }

    public static double ClampFraction(double x, double width) =>
        width <= 0 ? 0 : Math.Clamp(x / width, 0, 1);
}

public static class MemoLiveWaveMath
{
    /// Shapes the newest `visibleBars` live meter levels (right-aligned scrolling waveform).
    public static double[] Shape(IReadOnlyList<double> levels, int visibleBars, double minHeight = 3.0, double maxHeight = 26.0)
    {
        var n = Math.Max(1, visibleBars);
        var result = new double[n];
        var span = Math.Max(0, maxHeight - minHeight);
        var start = Math.Max(0, levels.Count - n);
        var pad = Math.Max(0, n - levels.Count);
        for (var i = 0; i < n; i++)
        {
            if (i < pad)
            {
                result[i] = minHeight;
                continue;
            }
            var v = Math.Clamp(levels[start + (i - pad)], 0, 1);
            result[i] = Math.Round(minHeight + Math.Pow(v, 0.75) * span, 2);
        }
        return result;
    }
}

public static class DictationBarsMath
{
    private static readonly double[] Weights = [0.55, 0.85, 1.0, 0.8, 0.5];

    public static double[] Heights(double level, double phaseSeconds = 0, double minHeight = 4.0, double maxHeight = 20.0)
    {
        var clamped = Math.Clamp(level, 0, 1);
        var span = Math.Max(0, maxHeight - minHeight);
        var outHeights = new double[Weights.Length];
        for (var i = 0; i < Weights.Length; i++)
        {
            var ripple = 0.82 + 0.18 * Math.Sin(phaseSeconds * 7.0 + i * 1.15);
            var h = minHeight + span * clamped * Weights[i] * ripple;
            outHeights[i] = Math.Round(Math.Clamp(h, minHeight, maxHeight), 2);
        }
        return outHeights;
    }
}

public static class TalkVisualMath
{
    private static readonly double[] Profile = [0.52, 0.82, 1.0, 0.84, 0.56];

    public static double[] BarHeights(double level, double phaseSeconds, double minHeight = 4.0, double maxHeight = 24.0)
    {
        var clamped = Math.Clamp(level, 0, 1);
        var span = Math.Max(0, maxHeight - minHeight);
        var heights = new double[Profile.Length];
        for (var i = 0; i < Profile.Length; i++)
        {
            var wave = 0.75 + 0.25 * Math.Sin(phaseSeconds * 6.5 + i * 1.1);
            var active = Math.Max(0.14, clamped);
            heights[i] = Math.Round(Math.Clamp(minHeight + span * active * Profile[i] * wave, minHeight, maxHeight), 2);
        }
        return heights;
    }

    public static double[] DotOpacities(double phaseSeconds, int count = 3)
    {
        var n = Math.Max(1, count);
        var opacities = new double[n];
        for (var i = 0; i < n; i++)
        {
            var v = 0.35 + 0.65 * (0.5 + 0.5 * Math.Sin(phaseSeconds * 5.0 - i * 0.9));
            opacities[i] = Math.Round(v, 3);
        }
        return opacities;
    }
}

public sealed record LiveWordsRun(string Primary, string Secondary, bool IsPlaceholder);

public static class LiveWordsDisplay
{
    public const string Placeholder = "Listening…";

    /// Formats live words matching LiveWordsView.swift: primary text + up to 2 trailing tentative words,
    /// front-truncated with "… " when longer than `maxChars`.
    public static LiveWordsRun Format(LiveWordsText text, int maxTrailingWords = 2, int maxChars = 140)
    {
        var full = text.Text;
        if (string.IsNullOrWhiteSpace(full))
            return new LiveWordsRun("", Placeholder, IsPlaceholder: true);

        var primary = text.Settled.Trim();
        var secondary = text.Pending.Trim();
        if (secondary.Length > 0)
        {
            var words = secondary.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length > maxTrailingWords)
            {
                var move = string.Join(" ", words.Take(words.Length - maxTrailingWords));
                primary = string.IsNullOrEmpty(primary) ? move : $"{primary} {move}";
                secondary = string.Join(" ", words.Skip(words.Length - maxTrailingWords));
            }
        }

        var combinedLen = primary.Length + (primary.Length > 0 && secondary.Length > 0 ? 1 : 0) + secondary.Length;
        if (maxChars > 4 && combinedLen > maxChars)
        {
            var keep = maxChars - 2;
            var all = string.IsNullOrEmpty(secondary) ? primary : string.IsNullOrEmpty(primary) ? secondary : $"{primary} {secondary}";
            var tail = all[^Math.Min(keep, all.Length)..].TrimStart();
            var cut = tail.IndexOf(' ');
            if (cut > 0 && cut < tail.Length - 4) tail = tail[(cut + 1)..];
            var prefixed = "… " + tail;
            if (secondary.Length > 0 && prefixed.EndsWith(secondary, StringComparison.Ordinal))
            {
                var p = prefixed[..^secondary.Length].TrimEnd();
                return new LiveWordsRun(p, secondary, IsPlaceholder: false);
            }
            return new LiveWordsRun(prefixed, "", IsPlaceholder: false);
        }

        return new LiveWordsRun(primary, secondary, IsPlaceholder: false);
    }
}

public sealed record TalkIntroRow(string Glyph, string Title, string Detail);

public static class TalkIntroModel
{
    public static string Title(string botName) => $"Talk with {botName}";
    public const string InfoTitle = "How Voice Works";
    public const string StartButton = "Start Talking";
    public const string LaterButton = "Not Now";
    public const string DoneButton = "Done";

    public static IReadOnlyList<TalkIntroRow> Rows(string botName, bool isLiveOffered) =>
    [
        new("\uE720", "Hands-free conversation",
            $"Speak naturally and {botName} replies out loud. Say \"stop\" or click End whenever you’re done."),
        new("\uE995", "Interrupt any time",
            "Start talking while a reply is playing — or click Interrupt — to jump right in."),
        new("\uE8BD", "Saved right in your chat",
            isLiveOffered
                ? "Your conversation stays in the transcript, and Live Voice can delegate tool tasks directly to Hermes."
                : "Every turn stays in your chat transcript so you can pick up typing at any time."),
        new("\uE72E", "Microphone stays under your control",
            "Mute at any time, or leave the chat and jump back from the floating voice pill."),
    ];
}
