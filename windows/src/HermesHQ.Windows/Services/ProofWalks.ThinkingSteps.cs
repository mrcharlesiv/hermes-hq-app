using Hermes.Core.Composer;
using Hermes.Core.Shell;
using HermesHQ.Features.Composer;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-MODEL-THINKING-STEPS] The Models sheet's foot draws Thinking as the Mac's lit step bar (ThinkingStepsBar; the
/// Mac's MacThinkingSteps at 93f984bb1), read on each Models sheet the transcript-extras walk opens: no Thinking
/// drop-down, the bar only with two or more levels, and its UIA RangeValue and Value as the words beside the title say.
internal static partial class ProofWalks
{
    private static void ThinkingStepsFoot(ContentDialog sheet, string how)
    {
        var shown = Shown(sheet).ToList();
        var combo = shown.OfType<ComboBox>().Any(b => b.Header as string == ModelSettingsFoot.ThinkingTitle);
        var words = shown.OfType<TextBlock>().FirstOrDefault(t => Id(t) == ModelsDialog.ThinkingValueId);
        var bar = shown.OfType<ThinkingStepsBar>().FirstOrDefault();
        if (words == null && bar == null && !combo)
        {
            AppLog.Note("automation", $"walk transcript-extras: the Models sheet ({how}) has no Thinking row (the model has no levels)");
            return;
        }
        var peer = bar == null ? null : FrameworkElementAutomationPeer.FromElement(bar) ?? FrameworkElementAutomationPeer.CreatePeerForElement(bar);
        var range = peer?.GetPattern(PatternInterface.RangeValue) as IRangeValueProvider;
        var value = peer?.GetPattern(PatternInterface.Value) as IValueProvider;
        // The words are runs (the name semibold): read them as one line.
        var text = words == null ? null : string.Concat(words.Inlines.OfType<Microsoft.UI.Xaml.Documents.Run>().Select(r => r.Text));
        var stops = bar?.Stops.Count ?? (words == null ? 0 : 1);
        var barShown = bar != null && bar.Visibility == Microsoft.UI.Xaml.Visibility.Visible;
        if (ThinkingStepsWalkProof.Read(combo, barShown, peer?.GetName(), value?.Value, text, stops, bar?.Stop ?? 0,
                range?.Maximum ?? 0, range?.Value ?? 0) is { } wrong)
            throw new InvalidOperationException($"{how}: Thinking: {wrong}");
        AppLog.Note("automation", $"walk transcript-extras: the Models sheet ({how}) draws Thinking as {stops} step(s) at “{text}”");
    }
}
