using Hermes.Core.Composer;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-MODEL-THINKING-STEPS] The Models foot's Thinking as the Mac draws it (App/Chat/Menus/MacModelPicker.swift at
/// 93f984bb1): the "Thinking" title with its value at the right ("High · Thinks hard": relabel(), ModelNames.effortLabel,
/// ModelPanelModel.effortLine) and MacThinkingSteps, the lit step bar (stops = state.efforts; the lit stop is the
/// effort's index; .valueChanged on each level crossed relabels, .primaryActionTriggered on a let-go or a key pause
/// commits; ± one stop for the keys and VoiceOver).
public class ThinkingStepsTests
{
    private static string Src(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir)!;
        return File.ReadAllText(Path.Combine([dir, .. parts])).Replace("\r\n", "\n");
    }

    private static readonly string[] All = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"];

    [Fact]
    public void TheStopsAreOffWhenItCanTurnOffThenTheModelsLevelsOnceEach()
    {
        // ModelPanelModel.swift: none first when the model can turn thinking off, then each level (never "none" again).
        Assert.Equal(All, ThinkingSteps.Stops(["minimal", "low", "medium", "high", "xhigh", "max", "ultra"], canTurnOff: true));
        Assert.Equal(["low", "high"], ThinkingSteps.Stops(["none", "low", "high", "low"], canTurnOff: false));
        Assert.Equal(["none", "low"], ThinkingSteps.Stops(["low", "none"], canTurnOff: true));
        // No levels at all: no stops, even when it could turn off.
        Assert.Empty(ThinkingSteps.Stops([], canTurnOff: true));
    }

    [Fact]
    public void TheEffortIsTheChatsWhenItIsAStopElseMediumElseTheFirst()
    {
        Assert.Equal("high", ThinkingSteps.Effort(All, "high"));
        Assert.Equal("medium", ThinkingSteps.Effort(All, "extreme"));
        Assert.Equal("low", ThinkingSteps.Effort(["low", "high"], "medium"));
        Assert.Equal("", ThinkingSteps.Effort([], "high"));
    }

    [Fact]
    public void TheLitStopIsTheEffortsIndexElseTheFirst()
    {
        Assert.Equal(4, ThinkingSteps.Lit(All, "high"));
        Assert.Equal(0, ThinkingSteps.Lit(All, "none"));
        Assert.Equal(0, ThinkingSteps.Lit(All, "nope"));
        Assert.Equal(0, ThinkingSteps.Lit([], "high"));
    }

    [Fact]
    public void TheTitleShowsWithAnyLevelAndTheBarOnlyWithTwoOrMore()
    {
        // heightChanged / layoutSubviews: Thinking's row hides with no efforts; the bar with fewer than two.
        Assert.False(ThinkingSteps.ShowsThinking(0));
        Assert.True(ThinkingSteps.ShowsThinking(1));
        Assert.False(ThinkingSteps.ShowsBar(0));
        Assert.False(ThinkingSteps.ShowsBar(1));
        Assert.True(ThinkingSteps.ShowsBar(2));
        // The foot's height changes only when one of those flips.
        Assert.True(ThinkingSteps.HeightChanged(0, 1));
        Assert.True(ThinkingSteps.HeightChanged(1, 2));
        Assert.False(ThinkingSteps.HeightChanged(2, 8));
        Assert.False(ThinkingSteps.HeightChanged(0, 0));
    }

    [Fact]
    public void EachLevelHasTheMacsLine()
    {
        Assert.Equal(
        [
            "Answers straight away", "A moment's thought", "Thinks briefly", "Thinks it through", "Thinks hard",
            "Thinks very hard", "As hard as it can", "Goes all out",
        ], All.Select(ThinkingSteps.EffortLine));
        Assert.Equal("Thinks at Extra Deep", ThinkingSteps.EffortLine("extra_deep"));
    }

    [Fact]
    public void TheValueIsTheLevelsNameAndItsLine()
    {
        var high = ThinkingSteps.Value("high", 8);
        Assert.Equal("High", high.Name);
        Assert.Equal("Thinks hard", high.Line);
        Assert.Equal("High · Thinks hard", high.Text);
        Assert.Equal("High, Thinks hard", high.AccessibleValue);
        Assert.Equal("Extra High · Thinks very hard", ThinkingSteps.Value("xhigh", 8).Text);
        Assert.Equal("Off · Answers straight away", ThinkingSteps.Value("none", 2).Text);
        // One stop: the line says it is the only one.
        var only = ThinkingSteps.Value("high", 1);
        Assert.Equal("High · Thinks hard · its only level", only.Text);
        Assert.Equal("High, Thinks hard · its only level", only.AccessibleValue);
        // No level: no name, the model's own line.
        var none = ThinkingSteps.Value(null, 0);
        Assert.Null(none.Name);
        Assert.Equal("This model answers without a thinking step", none.Text);
        Assert.Equal("This model answers without a thinking step", none.AccessibleValue);
    }

    [Fact]
    public void TheBarsNamesAreTheMacs()
    {
        Assert.Equal("Thinking", ThinkingSteps.AccessibleName);
        Assert.Equal("model.panel.thinking", ThinkingSteps.Id);
        Assert.Equal(TimeSpan.FromSeconds(0.35), ThinkingSteps.Settle);
        // The Mac's size: a 16 pt track, a 24 pt knob, a 5 pt dot, the bar the knob's height and room for its ring.
        Assert.Equal((16d, 24d, 5d, 32d), (ThinkingSteps.TrackHeight, ThinkingSteps.KnobSide, ThinkingSteps.DotSide, ThinkingSteps.Height));
        // Dimmed when it can't be set.
        Assert.Equal(0.45, ThinkingSteps.DisabledOpacity);
    }

    [Fact]
    public void PositionsSpreadTheStopsEndToEndAndAPointPicksTheNearest()
    {
        Assert.Equal(0, ThinkingSteps.Position(0, 8));
        Assert.Equal(1, ThinkingSteps.Position(7, 8));
        Assert.Equal(4d / 7, ThinkingSteps.Position(4, 8), 6);
        Assert.Equal(0, ThinkingSteps.Position(0, 1));
        Assert.Equal(4, ThinkingSteps.Nearest(4d / 7, 8));
        Assert.Equal(4, ThinkingSteps.Nearest(0.55, 8));
        Assert.Equal(0, ThinkingSteps.Nearest(-0.3, 8));
        Assert.Equal(7, ThinkingSteps.Nearest(1.4, 8));
        Assert.Equal(0, ThinkingSteps.Nearest(0.9, 1));
        // The knob's travel: half a knob and 2 pt in from each end.
        Assert.Equal((14d, 186d), (ThinkingSteps.From, ThinkingSteps.To(200)));
        Assert.Equal(0.5, ThinkingSteps.Fraction(100, 200), 6);
        Assert.Equal(0, ThinkingSteps.Fraction(-50, 200));
        Assert.Equal(1, ThinkingSteps.Fraction(500, 200));
    }

    [Fact]
    public void AKeyStepsOneStopAndStopsAtTheEnds()
    {
        var bar = new ThinkingStepsTrack();
        bar.Set(All, ThinkingSteps.Lit(All, "medium"));
        Assert.Equal(3, bar.Stop);
        Assert.True(bar.Step(1));
        Assert.Equal("high", bar.Level);
        Assert.True(bar.Step(-1));
        Assert.True(bar.Step(-1));
        Assert.Equal("low", bar.Level);
        bar.Set(All, 7);
        Assert.False(bar.Step(1));       // at the end: nothing moves, nothing fires
        Assert.Equal(7, bar.Stop);
        bar.Set(All, 0);
        Assert.False(bar.Step(-1));
        // Disabled (offline, mid-switch), keys move nothing.
        bar.Set(All, 3);
        bar.Enabled = false;
        Assert.False(bar.Step(1));
        Assert.Equal(3, bar.Stop);
    }

    [Fact]
    public void ADragMovesTheLitStopAndOnlyTheLetGoCommits()
    {
        var bar = new ThinkingStepsTrack();
        bar.Set(All, 3);
        Assert.True(bar.Press(4d / 7));          // a click jumps there: a level crossed
        Assert.True(bar.Dragging);
        Assert.Equal("high", bar.Level);
        Assert.False(bar.Move(4.2 / 7));         // still nearest High: no change
        Assert.True(bar.Move(1));
        Assert.Equal("ultra", bar.Level);
        Assert.Equal("ultra", bar.Release());    // the let-go commits the level it settled on
        Assert.False(bar.Dragging);
        // A cancelled drag commits nothing.
        bar.Set(All, 3);
        bar.Press(0);
        Assert.Equal(0, bar.Stop);
        bar.Cancel();
        Assert.False(bar.Dragging);
        // With fewer than two stops, or disabled, a press does nothing.
        var one = new ThinkingStepsTrack();
        one.Set(["high"], 0);
        Assert.False(one.Press(1));
        Assert.False(one.Dragging);
        Assert.Null(one.Release());
        bar.Set(All, 3);
        bar.Enabled = false;
        Assert.False(bar.Press(1));
        Assert.Equal(3, bar.Stop);
    }

    [Fact]
    public void NewStopsKeepTheStopInRange()
    {
        var bar = new ThinkingStepsTrack();
        bar.Set(All, 7);
        bar.Set(["low", "high"], 7);
        Assert.Equal(1, bar.Stop);
        bar.Set([], 3);
        Assert.Equal(0, bar.Stop);
        Assert.Null(bar.Level);
        bar.Set(All, -4);
        Assert.Equal(0, bar.Stop);
    }

    [Fact]
    public void OnlyANewLevelIsSent()
    {
        // effortChosen: the level the bar settled on, unless it is the chat's already.
        Assert.True(ThinkingSteps.ShouldCommit("high", effort: "medium"));
        Assert.False(ThinkingSteps.ShouldCommit("medium", effort: "medium"));
        Assert.False(ThinkingSteps.ShouldCommit(null, effort: "medium"));
    }

    [Fact]
    public void TheWalkReadsTheBarAsTheMacsValue()
    {
        Assert.Null(ThinkingStepsWalkProof.Read(comboHeadedThinking: false, barShown: true, barName: "Thinking",
            barValue: "High, Thinks hard", shownText: "High · Thinks hard", stops: 8, lit: 4, maximum: 7, value: 4));
        Assert.NotNull(ThinkingStepsWalkProof.Read(comboHeadedThinking: true, barShown: true, barName: "Thinking",
            barValue: "High, Thinks hard", shownText: "High · Thinks hard", stops: 8, lit: 4, maximum: 7, value: 4));
        Assert.NotNull(ThinkingStepsWalkProof.Read(false, true, "Thinking", "High, Thinks hard", "Medium · Thinks it through", 8, 4, 7, 4));
        Assert.NotNull(ThinkingStepsWalkProof.Read(false, true, "", "High, Thinks hard", "High · Thinks hard", 8, 4, 7, 4));
        Assert.NotNull(ThinkingStepsWalkProof.Read(false, true, "Thinking", "High, Thinks hard", "High · Thinks hard", 8, 4, 6, 4));
        Assert.NotNull(ThinkingStepsWalkProof.Read(false, true, "Thinking", "High, Thinks hard", "High · Thinks hard", 8, 4, 7, 3));
        // One stop: the words without a bar is right; a bar there is wrong.
        Assert.Null(ThinkingStepsWalkProof.Read(false, false, null, null, "High · Thinks hard · its only level", 1, 0, 0, 0));
        Assert.NotNull(ThinkingStepsWalkProof.Read(false, true, "Thinking", "High, Thinks hard · its only level", "High · Thinks hard · its only level", 1, 0, 0, 0));
    }

    [Fact]
    public void TheWindowsFootDrawsTheStepBarNotADropDown()
    {
        var dialog = Src("src", "HermesHQ.Windows", "Features", "Composer", "ModelsDialog.cs");
        Assert.DoesNotContain("new ComboBox", dialog);
        foreach (var use in new[]
        {
            "new ThinkingStepsBar(", "ThinkingSteps.ShowsThinking(", "ThinkingSteps.Value(", "ThinkingSteps.Effort(",
            "ThinkingSteps.Lit(", "ThinkingSteps.ShouldCommit(", "ModelSettingsFoot.ThinkingTitle",
            // The wire as the drop-down sent it: the chat's reasoning, then a redraw.
            "c.SetReasoningAsync(level, ui).ContinueWith(_ => dispatcher.TryEnqueue(Redraw))",
        })
            Assert.Contains(use, dialog);
        // The value text moves with the bar; only a settled level is sent.
        Assert.Contains(".LevelMoved +=", dialog);
        Assert.Contains(".EffortChosen +=", dialog);
        var bar = Src("src", "HermesHQ.Windows", "Features", "Composer", "ThinkingStepsBar.cs");
        foreach (var use in new[]
        {
            "IRangeValueProvider", "IValueProvider", "ThinkingSteps.Id", "ThinkingSteps.AccessibleName", "ThinkingSteps.Settle",
            "VirtualKey.Left", "VirtualKey.Right", "VirtualKey.Enter", "PointerReleased", "PointerCaptureLost", "ActualThemeChanged",
            "ThinkingSteps.DisabledOpacity", "track.Release()", "track.Step(",
        })
            Assert.Contains(use, bar);
    }
}
