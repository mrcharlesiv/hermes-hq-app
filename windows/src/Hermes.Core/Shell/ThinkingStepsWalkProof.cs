namespace Hermes.Core.Shell;

/// [WIN-MODEL-THINKING-STEPS] What the transcript-extras walk reads on the open Models sheet's foot
/// (ProofWalks.ThinkingSteps.cs): no Thinking drop-down; the step bar only with two or more stops, named "Thinking",
/// its UIA range 0…stops-1 at the lit stop, and its value the Mac's "name, line" for the words drawn beside the title.
public static class ThinkingStepsWalkProof
{
    /// Null when the foot reads right, else what is wrong.
    public static string? Read(bool comboHeadedThinking, bool barShown, string? barName, string? barValue, string? shownText,
        int stops, int lit, double maximum, double value)
    {
        if (comboHeadedThinking) return "the foot still draws Thinking as a drop-down";
        if (barShown != (stops > 1)) return barShown ? $"a step bar with {stops} stop(s)" : $"no step bar for {stops} stops";
        if (!barShown) return null;
        if (barName != "Thinking") return $"the bar is named “{barName}”";
        if (maximum != stops - 1) return $"the bar's range ends at {maximum}, not {stops - 1}";
        if (value != lit) return $"the bar's value is {value}, the lit stop {lit}";
        // "High · Thinks hard" is heard "High, Thinks hard": only the separator after the name turns.
        var heard = shownText is { } s && s.IndexOf(" · ", StringComparison.Ordinal) is var at and >= 0
            ? s[..at] + ", " + s[(at + 3)..] : shownText;
        if (barValue != heard) return $"the bar says “{barValue}” beside “{shownText}”";
        return null;
    }
}
