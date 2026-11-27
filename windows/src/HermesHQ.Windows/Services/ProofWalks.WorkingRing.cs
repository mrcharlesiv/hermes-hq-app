using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using SettingsWindow = HermesHQ.Features.Settings.SettingsWindow;

namespace HermesHQ.Services;

internal static partial class ProofWalks
{
    // The existing row-steps fixture holds two different chats mid-turn. Use its real rows and the real
    // Settings switch, without putting a Working Ring choice in the user's preference file.
    private sealed class RingWalkPreferences : IPreferences
    {
        public string? Value { get; private set; }
        public string? Get(string key) => key == WorkingRing.Key ? Value : throw new ArgumentException(nameof(key));
        public void Set(string key, string? value)
        {
            if (key != WorkingRing.Key) throw new ArgumentException(nameof(key));
            Value = value;
        }
    }

    private static async Task CheckWorkingRingAsync(ShellPage shell, Func<string, Task> shot)
    {
        var address = AppState.Client?.Session.Address.Base;
        if (!Automation.Enabled || address?.AbsoluteUri != "http://127.0.0.1:9838/")
            throw new InvalidOperationException("Working Ring proof requires the row-steps loopback fixture.");
        var oldStore = WorkingRing.Store;
        if (SettingsWindow.OpenCount != 0 || oldStore == null || oldStore.Get(WorkingRing.Key) != null)
            throw new InvalidOperationException("Working Ring proof requires fresh fixture settings and no Settings window.");
        var oldCategory = FilePreferences.Shared.Get(SettingsCategories.LastCategoryKey);
        var prefs = new RingWalkPreferences();
        SettingsWindow? window = null;
        WorkingRing.Store = prefs;
        try
        {
            if (!SettingsWindow.Open(WorkingRing.RowTarget) || (window = SettingsWindow.Showing) == null)
                throw new InvalidOperationException("Working Ring did not open in its own Settings window.");
            var toggle = await Until(() => FindIn(window.Content, WorkingRing.AutomationId) as ToggleSwitch, "Working Ring on Appearance", 15);
            toggle.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
            async Task Check(bool on, string? stored)
            {
                await UntilChecked(() => toggle.IsOn != on || !RingWalkVisible(toggle) || prefs.Value != stored
                    ? "Working Ring switch or saved choice does not match" : RingWalkRows(shell, on), "the switch and both live rows", 15);
            }
            await Check(false, null);
            await ShotOfAsync(window, () => shot("working-ring-switch-off"));
            await shot("working-ring-rows-off");
            Pattern<IToggleProvider>(toggle, PatternInterface.Toggle).Toggle();
            await Check(true, "true");
            await ShotOfAsync(window, () => shot("working-ring-switch-on"));
            await shot("working-ring-rows-on");
            Pattern<IToggleProvider>(toggle, PatternInterface.Toggle).Toggle();
            await Check(false, "false");
        }
        finally
        {
            // Restore drawing through the same change event while writes still target ONLY the in-memory store.
            try { WorkingRing.IsOn = false; }
            finally
            {
                WorkingRing.Store = oldStore;
                window?.Close();
                if (FilePreferences.Shared.Get(SettingsCategories.LastCategoryKey) != oldCategory)
                    FilePreferences.Shared.Set(SettingsCategories.LastCategoryKey, oldCategory);
            }
        }
    }

    // Require a laid-out witness in the visual tree, not a virtualized/offscreen container or an empty ring tag.
    private static bool RingWalkVisible(FrameworkElement e)
    {
        if (!e.IsLoaded || e.ActualWidth <= 0 || e.ActualHeight <= 0 || e.XamlRoot?.Content is not FrameworkElement root) return false;
        var middle = new Point(e.ActualWidth / 2, e.ActualHeight / 2);
        for (DependencyObject? at = e; at != null; at = VisualTreeHelper.GetParent(at))
        {
            if (at is not FrameworkElement p) continue;
            if (p.Visibility != Visibility.Visible || p.Opacity <= 0) return false;
            if (p is ScrollContentPresenter || ReferenceEquals(p, root))
            {
                var point = e.TransformToVisual(p).TransformPoint(middle);
                if (point.X < 0 || point.Y < 0 || point.X >= p.ActualWidth || point.Y >= p.ActualHeight) return false;
            }
            if (ReferenceEquals(p, root)) return true;
        }
        return false;
    }

    private static string? RingWalkRows(ShellPage shell, bool on)
    {
        var bot = Shown(shell.SidebarList).OfType<ListViewItem>().FirstOrDefault(i => i.Tag is SidebarBot b && b.Bot.Id == RowStepsWalkProof.Bot);
        var list = Shown(Root).OfType<SessionsPage>().FirstOrDefault()?.FindName("SessionList") as ListView;
        var chat = list == null ? null : Shown(list).OfType<ListViewItem>().FirstOrDefault(i =>
            AutomationProperties.GetName(i)?.StartsWith(RowStepsWalkProof.SideTitle + ". ", StringComparison.Ordinal) == true);
        if (bot == null || chat == null || !RingWalkVisible(bot) || !RingWalkVisible(chat)) return "missing visible bot or session row";
        var b = Drawn(bot); var c = Drawn(chat);
        var state = RowStepsWalkProof.BotRow(b.Name, b.Texts, RowStepsWalkProof.BotName, RowStepsWalkProof.BotLine)
            ?? RowStepsWalkProof.SessionRow(c.Name, c.Texts, RowStepsWalkProof.SideTitle, RowStepsWalkProof.SideLine);
        if (state != null) return state;
        if (!Shown(bot).OfType<StackPanel>().Any(p => p.Children.Count == 3 && p.Children.All(dot => dot is Ellipse e && e.Fill != null && RingWalkVisible(e))))
            return "the working bot lost its three visible dots";
        foreach (var row in new[] { bot, chat })
        {
            var rings = Shown(row).OfType<Border>().Where(r => Equals(r.Tag, "working-ring")).ToList();
            if (rings.Count != (on ? 1 : 0)) return "working row has the wrong number of rings";
            if (on && (!RingWalkVisible(rings[0]) || rings[0].BorderThickness.Left <= 0 ||
                rings[0].BorderBrush is not LinearGradientBrush brush || !brush.GradientStops.Any(s => s.Color.A > 0)))
                return "the ring has no visible stroke";
        }
        return null;
    }
}
