namespace Hermes.Core.Composer;

/// What the Thinking row says: the level's name (semibold on screen) and what it means; `Text` is the row's value at
/// the right, `AccessibleValue` what a screen reader hears on the bar.
public sealed record ThinkingValue(string? Name, string Line)
{
    public string Text => Name is null ? Line : $"{Name} · {Line}";
    public string AccessibleValue => Name is null ? Line : $"{Name}, {Line}";
}

/// [WIN-MODEL-THINKING-STEPS] The Models foot's Thinking (App/Chat/Menus/MacModelPicker.swift MacModelSettingsFoot and
/// MacThinkingSteps at 93f984bb1): the "Thinking" title with its value at the right ("High · Thinks hard", relabel())
/// and the lit step bar under it. Stops are HermesKit/Chat/ModelPanelModel.swift's `efforts`; a level's line is its
/// `effortLine`, its name ModelNames.effortLabel.
public static class ThinkingSteps
{
    public const string Id = "model.panel.thinking";
    public const string AccessibleName = "Thinking";
    public const string NoThinkingLine = "This model answers without a thinking step";
    public const string OnlyLevelNote = " · its only level";
    /// A run of key presses sends one change: the level is set once the keys pause this long.
    public static readonly TimeSpan Settle = TimeSpan.FromSeconds(0.35);
    public const double TrackHeight = 16;
    public const double KnobSide = 24;
    public const double DotSide = 5;
    /// The bar's own height: the knob, and room for its focus ring.
    public const double Height = KnobSide + 8;
    public const double DisabledOpacity = 0.45;
    /// The knob's centre at the first stop: half a knob and 2 pt in.
    public const double From = KnobSide / 2 + 2;

    public static double To(double width) => width - KnobSide / 2 - 2;

    /// The model's levels: "none" first when it can turn thinking off, then each level once (`ModelPanelModel.build`).
    public static IReadOnlyList<string> Stops(IReadOnlyList<string> reasoningLevels, bool canTurnOff)
    {
        var efforts = new List<string>();
        if (reasoningLevels.Count == 0) return efforts;
        if (canTurnOff) efforts.Add("none");
        foreach (var level in reasoningLevels)
            if (level != "none" && !efforts.Contains(level)) efforts.Add(level);
        return efforts;
    }

    /// The chat's level when it is a stop, else Medium when that is one, else the first; "" with no stops.
    public static string Effort(IReadOnlyList<string> efforts, string current) =>
        efforts.Contains(current) ? current
            : efforts.Contains(ModelNames.DefaultReasoningEffort) ? ModelNames.DefaultReasoningEffort
            : efforts.Count > 0 ? efforts[0] : "";

    /// Which stop is lit: the effort's, else the first (`setStop(efforts.firstIndex(of: effort) ?? 0)`).
    public static int Lit(IReadOnlyList<string> efforts, string effort) => Math.Max(0, IndexOf(efforts, effort));

    /// Thinking's row (title and value) shows when the model has any level.
    public static bool ShowsThinking(int efforts) => efforts > 0;

    /// The bar shows when there are levels to step between.
    public static bool ShowsBar(int efforts) => efforts > 1;

    /// The foot changes height only when the row or the bar comes or goes (`heightChanged`).
    public static bool HeightChanged(int before, int after) =>
        ShowsThinking(before) != ShowsThinking(after) || ShowsBar(before) != ShowsBar(after);

    /// What a thinking level means (ModelPanelModel.effortLine).
    public static string EffortLine(string level) => level switch
    {
        "none" => "Answers straight away",
        "minimal" => "A moment's thought",
        "low" => "Thinks briefly",
        "medium" => "Thinks it through",
        "high" => "Thinks hard",
        "xhigh" => "Thinks very hard",
        "max" => "As hard as it can",
        "ultra" => "Goes all out",
        _ => $"Thinks at {ModelNames.EffortLabel(level)}",
    };

    /// relabel(): the level the bar is on (moving or settled) by name and line; one stop says it is the only one.
    public static ThinkingValue Value(string? level, int efforts) => level is null
        ? new ThinkingValue(null, NoThinkingLine)
        : new ThinkingValue(ModelNames.EffortLabel(level), EffortLine(level) + (efforts == 1 ? OnlyLevelNote : ""));

    /// effortChosen: the settled level goes out unless it is the chat's already.
    public static bool ShouldCommit(string? level, string effort) => level is not null && level != effort;

    /// A stop's place along the travel, 0 at the first, 1 at the last.
    public static double Position(int index, int count) => count > 1 ? (double)index / (count - 1) : 0;

    /// The stop nearest a place along the travel.
    public static int Nearest(double fraction, int count) =>
        count > 1 ? (int)Math.Round(Math.Clamp(fraction, 0, 1) * (count - 1), MidpointRounding.AwayFromZero) : 0;

    /// A pointer's x as a place along the travel of a bar this wide.
    public static double Fraction(double x, double width) => Math.Clamp((x - From) / Math.Max(1, To(width) - From), 0, 1);

    private static int IndexOf(IReadOnlyList<string> list, string value)
    {
        for (var i = 0; i < list.Count; i++) if (list[i] == value) return i;
        return -1;
    }
}

/// MacThinkingSteps' state without its drawing: the stops, the lit one, a drag. `Press`/`Move`/`Step` say whether a
/// level was crossed (the Mac's .valueChanged, which relabels); `Release` hands back the level to commit (its
/// .primaryActionTriggered); keys commit after `ThinkingSteps.Settle`, which the control times.
public sealed class ThinkingStepsTrack
{
    public IReadOnlyList<string> Stops { get; private set; } = [];
    public int Stop { get; private set; }
    public bool Dragging { get; private set; }
    public bool Enabled { get; set; } = true;
    public string? Level => Stop >= 0 && Stop < Stops.Count ? Stops[Stop] : null;

    public void Set(IReadOnlyList<string> stops, int stop)
    {
        Stops = stops;
        Stop = Math.Max(0, Math.Min(stop, stops.Count - 1));
    }

    /// A click jumps to the nearest stop and starts a drag; nothing with fewer than two stops or disabled.
    public bool Press(double fraction)
    {
        if (!Enabled || Stops.Count < 2) return false;
        Dragging = true;
        return Follow(fraction);
    }

    public bool Move(double fraction) => Dragging && Follow(fraction);

    /// The let-go: the level to commit (null when no drag was on).
    public string? Release()
    {
        if (!Dragging) return null;
        Dragging = false;
        return Level;
    }

    public void Cancel() => Dragging = false;

    /// ← / →: one stop, none past the ends.
    public bool Step(int by)
    {
        var next = Math.Max(0, Math.Min(Stops.Count - 1, Stop + by));
        if (!Enabled || next == Stop || Stops.Count == 0) return false;
        Stop = next;
        return true;
    }

    private bool Follow(double fraction)
    {
        var next = ThinkingSteps.Nearest(fraction, Stops.Count);
        if (next == Stop) return false;
        Stop = next;
        return true;
    }
}
