using Hermes.Core.Settings;
using HermesHQ.Features.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using PillViewport = Hermes.Core.Shell.TaskPillViewportProof;
using RectangleF = System.Drawing.RectangleF;

namespace HermesHQ.Services;

internal static partial class ProofWalks
{
    /// Tasks: every view pill (tasks.view.*, + New List), the picked one Highlight under HighlightText, the others
    /// ButtonFace under ButtonText, words and count in that ink, no backplate. Needs a picked pill and one not picked.
    private static List<string> PillFills((string Area, DependencyObject Root)[] roots, IReadOnlyDictionary<string, uint> named)
    {
        var found = new List<string>();
        var pills = roots.SelectMany(r => Shown(r.Root)).OfType<ButtonBase>()
            .Where(p => Id(p).StartsWith("tasks.view.", StringComparison.Ordinal)).ToList();
        var picked = 0;
        string? pickedInView = null, unpickedInView = null;
        foreach (var pill in pills)
        {
            if (PillPaint(pill, named, out var presenter) is { } wrong) found.Add(wrong);
            if (pill is not ToggleButton view) continue; // + New List is judged but isn't an unpicked view
            if (view.IsChecked == true) picked++;
            if (presenter == null) continue; // PillPaint already reported the missing part; it can't witness a state.
            switch (InPillViewport(presenter))
            {
                case null: found.Add($"Tasks · {Id(view)}: couldn't resolve the scroll-content viewport up to the window root"); break;
                case false when view.IsChecked == true: found.Add("Tasks · the picked pill is outside the viewport"); break;
                case true when view.IsChecked == true: pickedInView = Id(view); break;
                case true when view.IsChecked == false: unpickedInView ??= Id(view); break;
            }
        }
        if (picked != 1) found.Add($"Tasks · {picked} picked pills shown (one is)");
        if (unpickedInView == null) found.Add("Tasks · no unpicked view pill in the viewport");
        if (roots.Select(r => r.Root).OfType<TasksPage>().FirstOrDefault()?.Content is not Panel host)
            found.Add("Tasks · can't lay out the pill mismatch control");
        else if (PillMismatchControl(host, named) is { } missed) found.Add(missed);
        AppLog.Note("automation", $"walk high-contrast: Tasks {pills.Count} pills judged, {picked} picked; in the content viewport: picked {pickedInView ?? "none"}, unpicked {unpickedInView ?? "none"}");
        return found;
    }

    // WinUI 1.8's DefaultButtonStyle and DefaultToggleButtonStyle both paint their named root ContentPresenter;
    // the Checked storyboard can replace its Background. Don't substitute a nested presenter or the control's brush.
    private static ContentPresenter? PillPresenter(ButtonBase pill)
    {
        pill.ApplyTemplate();
        pill.UpdateLayout();
        var parts = Shown(pill).OfType<ContentPresenter>().Where(p => p.Name == "ContentPresenter"
            && ReferenceEquals(VisualTreeHelper.GetParent(p), pill) && HasPaintArea(p)).Take(2).ToArray();
        return parts is [var presenter] ? presenter : null;
    }

    private static bool HasPaintArea(FrameworkElement element)
    {
        if (element.XamlRoot == null || element.ActualWidth <= 0 || element.ActualHeight <= 0) return false;
        for (DependencyObject? at = element; at != null; at = VisualTreeHelper.GetParent(at))
            if (at is UIElement u && (u.Visibility != Visibility.Visible || u.Opacity != 1)) return false;
        return true;
    }

    // The stock ScrollViewer puts its Padding on the ScrollContentPresenter's margin. Its outside bounds
    // and the button's layout slot can both overlap the window without any of the pill's fill showing.
    private static bool? InPillViewport(ContentPresenter presenter)
    {
        if (presenter.XamlRoot?.Content is not FrameworkElement root) return null;
        RectangleF Bounds(FrameworkElement e)
        {
            var r = e.TransformToVisual(root).TransformBounds(new Rect(0, 0, e.ActualWidth, e.ActualHeight));
            return new((float)r.X, (float)r.Y, (float)r.Width, (float)r.Height);
        }
        IEnumerable<(PillViewport.Boundary, RectangleF)> Boundaries()
        {
            for (var at = VisualTreeHelper.GetParent(presenter); at != null; at = VisualTreeHelper.GetParent(at))
            {
                if (at is ScrollContentPresenter { Name: "ScrollContentPresenter" } viewport)
                    yield return (PillViewport.Boundary.ContentViewport, Bounds(viewport));
                if (at is ScrollViewer rail) yield return (PillViewport.Boundary.ScrollViewer, Bounds(rail));
                if (ReferenceEquals(at, root)) { yield return (PillViewport.Boundary.Root, Bounds(root)); yield break; }
            }
        }
        return PillViewport.InView(Bounds(presenter), Boundaries());
    }

    private static uint? OpaqueRgb(Brush? brush) => brush is SolidColorBrush { Color.A: 255, Opacity: 1 } solid ? Rgb(solid.Color) : null;

    private static string? PillPaint(ButtonBase pill, IReadOnlyDictionary<string, uint> named, out ContentPresenter? measured)
    {
        var what = "Tasks · " + Id(pill);
        measured = PillPresenter(pill);
        if (measured is not { } presenter) return $"{what}: couldn't resolve one visible template ContentPresenter after layout";
        if (OpaqueRgb(presenter.Background) is not { } fill) return $"{what}: ContentPresenter.Background isn't an opaque solid colour";

        // Read the TextBlock actually under this presenter (inside the face panel for + New List), not detached Content
        // or the presenter's default Foreground: the label and its count can override the inherited ink independently.
        var labels = Shown(presenter).OfType<TextBlock>().Where(t => HasPaintArea(t) &&
            (ReferenceEquals(t, presenter.Content) || (presenter.Content is Panel face && ReferenceEquals(VisualTreeHelper.GetParent(t), face)))).Take(2).ToArray();
        if (labels is not [var words] || OpaqueRgb(words.Foreground) is not { } ink) return $"{what}: couldn't resolve one visible label with an opaque foreground";
        var surface = ContrastTheme.PillSurface(pill is ToggleButton { IsChecked: true });
        var backplate = words.HighContrastAdjustment != ElementHighContrastAdjustment.None;
        if (ContrastTheme.Judge(what, surface, fill, ink, backplate, named) is { } wrong) return wrong;
        foreach (var run in words.Inlines.OfType<Run>())
        {
            // An unset foreground inherits the label's. A present but unresolved brush isn't evidence of that ink.
            if (run.Foreground == null && run.ReadLocalValue(TextElement.ForegroundProperty) == DependencyProperty.UnsetValue) continue;
            if (OpaqueRgb(run.Foreground) is not { } runInk) return $"{what}: a text run has no opaque foreground";
            if (ContrastTheme.Judge(what + " (a text run)", surface, fill, runInk, backplate, named) is { } wrongRun) return wrongRun;
        }
        AppLog.Note("automation", $"walk high-contrast: {what} ({surface}): presenter #{fill:X6}, words #{ink:X6}");
        return null;
    }

    // Negative control for the measurement itself. Only this throwaway stock button's template part is changed;
    // the real pills, their brushes and their template bindings stay intact. Removed before the Tasks picture.
    private static string? PillMismatchControl(Panel host, IReadOnlyDictionary<string, uint> named)
    {
        const string id = "contrast.mismatch";
        static SolidColorBrush BrushOf(uint rgb) => new(Microsoft.UI.ColorHelper.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        var configured = BrushOf(named["ButtonFace"]);
        var ink = named["ButtonText"];
        var probe = new ToggleButton { Background = configured, Foreground = BrushOf(ink), IsHitTestVisible = false, IsTabStop = false,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Content = new TextBlock { Text = "Test", Foreground = BrushOf(ink), HighContrastAdjustment = ElementHighContrastAdjustment.None } };
        AutomationProperties.SetAutomationId(probe, id);
        probe.Resources["ToggleButtonBackground"] = configured;
        host.Children.Add(probe);
        try
        {
            if (PillPaint(probe, named, out var part) is { } before) return $"Tasks · mismatch control didn't start in the expected pair: {before}";
            if (part == null) return "Tasks · mismatch control has no visible ContentPresenter";
            var different = named["ButtonFace"] ^ 0xFFFFFFu; // differs even for a custom OS palette
            part.Background = BrushOf(different);
            if (OpaqueRgb(part.Background) != different || OpaqueRgb(probe.Background) != named["ButtonFace"]
                || OpaqueRgb(probe.Resources["ToggleButtonBackground"] as Brush) != named["ButtonFace"])
                return "Tasks · couldn't induce a presenter-only fill mismatch";
            var expected = ContrastTheme.Judge("Tasks · " + id, ContrastTheme.Surface.Pill, different, ink, false, named);
            var measured = PillPaint(probe, named, out _);
            if (expected != null && measured == expected) // a missing part or unrelated failure doesn't count
            {
                AppLog.Note("automation", $"walk high-contrast: Tasks mismatch control rejected presenter #{different:X6} with configured #{Rgb(configured.Color):X6}");
                return null;
            }
            return $"Tasks · mismatch control didn't report its painted fill #{different:X6}: {measured ?? "accepted configured fill"}";
        }
        finally { host.Children.Remove(probe); host.UpdateLayout(); }
    }
}
