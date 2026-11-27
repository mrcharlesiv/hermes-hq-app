using Hermes.Core.Bots;

namespace Hermes.Core.Shell;

/// [WIN-44] The walks' checks on the Undo pill's time (App/Kit/UndoPill.swift `UndoPillClock`): after an archive the
/// pill's clock runs with nothing holding it, for the Mac's 4 s (8 at accessibility text sizes), and the pill is gone
/// well inside 10 s. The pill on Windows armed a timer it kept no reference to and stayed for minutes.
public static partial class WalkProof
{
    /// How long a walk gives a pill nothing holds to go (the Mac's 4 s, or 8, with room for a busy runner).
    public const double UndoPillGoneWithin = 10;

    /// The pill's clock as the walk finds it: running, nothing holding it, and the time the Mac gives (`seconds` asked,
    /// at least 8 at accessibility text sizes). Null when so, else what is wrong.
    public static string? UndoPillRuns(UndoPillClock clock, bool accessibilityTextSize, double seconds = UndoPillClock.Seconds)
    {
        if (clock.Holds.Count > 0) return $"the Undo pill is held ({string.Join(", ", clock.Holds.OrderBy(h => h))})";
        if (!clock.IsRunning) return "the Undo pill's clock isn't running";
        var expected = accessibilityTextSize ? Math.Max(UndoPillClock.AccessibilitySeconds, seconds) : seconds;
        return Math.Abs(clock.Remaining - expected) < 0.001 ? null : $"the Undo pill shows for {clock.Remaining:0.##} s, not {expected:0.##} s";
    }

    /// After the wait: the pill has gone. Null when so, else how long it has stayed.
    public static string? UndoPillGone(bool stillShown, double waited) =>
        stillShown ? $"the Undo pill was still up {waited:0.#} s later with nothing holding it" : null;
}
