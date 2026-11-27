using Hermes.Core;
using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Insights;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using static HermesHQ.Features.Insights.Kit;

namespace HermesHQ.Features.Insights;

/// The one Update sheet for Hermes (App/Pages/More/CommandCenter/HermesUpdate.swift; on the Mac the compact layout of
/// App/Mac/MacGatewayUpdateSheets.swift): the symbol beside the headline and its lines (versions, which gateway, what
/// happens), the steps and What's New on cards, and the Mac's button row with the default button last. The run lives in
/// `HermesUpdateCenter`: the sheet may be closed (Hide) and the update keeps going; Status & Maintenance's row brings it
/// back.
public static class UpdateSheet
{
    private static ContentDialog? _open;

    /// The gateway's name as the Gateways list shows it.
    public static string Name(StoredAccount account) => GatewayNaming.Title(new Uri(account.Url.TrimEnd('/') + "/"), account.Label);

    public static HermesUpdate MakeRun(HermesClient client, string key)
    {
        var account = AppState.Account ?? client.Session.Account;
        var host = GatewayNaming.Host(new Uri(account.Url.TrimEnd('/') + "/"), port: true);
        var bots = client.Bots ?? [];
        string BotName(string profile) => bots.FirstOrDefault(b => b.Name == profile)?.DisplayName
            ?? (profile == "default" ? "Hermes" : profile.Length > 0 ? char.ToUpperInvariant(profile[0]) + profile[1..] : profile);
        var run = new HermesUpdate(key, Name(account), HermesUpdate.PlaceWords(inUse: true, host),
            new HermesUpdateApi(new SessionRest(client.Session)), BotName);
        run.Ended += end => AppLog.Note("config", $"update flow ended: {end.GetType().Name}");
        return run;
    }

    /// Update Hermes on the gateway in use: the sheet opens on "Checking…" and asks before anything changes. A run already
    /// under way comes back instead. `afterUpdated`: runs when the sheet closes on "Updated to …".
    public static void Update(HermesClient client, XamlRoot? root, Action? afterUpdated = null)
    {
        var key = client.AccountId;
        HermesUpdate Make()
        {
            var run = MakeRun(client, key);
            run.Again = () => Update(client, root, afterUpdated);
            return run;
        }
        var run = HermesUpdateCenter.Shared.Update(key, Make);
        if (afterUpdated != null) run.AfterUpdated = afterUpdated;
        Show(run, root);
    }

    public static void Show(HermesUpdate run, XamlRoot? root)
    {
        if (root == null || _open != null) return;
        var ui = DispatcherQueue.GetForCurrentThread();
        var body = new ContentPresenter();
        var dialog = new ContentDialog { XamlRoot = root, Content = body, Padding = new Thickness(0) };
        dialog.Resources["ContentDialogMaxWidth"] = 560.0;
        AutomationProperties.SetAutomationId(dialog, "hermes-update");
        _open = dialog;
        run.SheetOpen = true;
        void Render()
        {
            if (AppShutdown.Stopping || _open != dialog) return;
            UiTree.DeactivateProgressRings(body);
            body.Content = Build(run, dialog);
        }
        void OnChanged() => ui.TryEnqueue(Render);
        run.Changed += OnChanged;
        var ticker = ui.CreateTimer();
        ticker.Interval = TimeSpan.FromSeconds(1);
        ticker.Tick += (_, _) => { if (AppShutdown.Stopping) { ticker.Stop(); return; } if (run.Phase == HermesUpdate.PhaseKind.Working) Render(); };
        ticker.Start();
        dialog.Closed += (_, _) =>
        {
            ticker.Stop();
            run.Changed -= OnChanged;
            UiTree.DeactivateProgressRings(body);
            if (_open == dialog) _open = null;
            run.SheetClosed();
        };
        Render();
        _ = ShowSafeAsync(root, dialog);
    }

    private static async Task ShowSafeAsync(XamlRoot root, ContentDialog dialog)
    {
        try { await SafeDialog.ShowAsync(root, dialog); }
        finally { if (_open == dialog) _open = null; }
    }

    private static UIElement Build(HermesUpdate run, ContentDialog dialog)
    {
        var col = new StackPanel { Spacing = 14, MinWidth = 440 };
        col.Children.Add(Header(run));
        if (run.CommandToCopy is { } command)
        {
            var t = new TextBlock
            {
                Text = command, FontFamily = (FontFamily)Application.Current.Resources["CodeFont"], FontSize = 13, TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            };
            AutomationProperties.SetAutomationId(t, "hermes-update.command");
            col.Children.Add(UpdateCard(t));
        }
        if (run.ShowsSteps) col.Children.Add(StepsCard(run));
        if (run.ShowsWhatsNew)
        {
            var notes = new StackPanel { Spacing = 6 };
            foreach (var c in run.Commits)
                notes.Children.Add(new Grid
                {
                    ColumnSpacing = 8,
                    ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) } },
                    Children = { Text("•", 13, secondary: true), Cell(Text(c.Summary, 13), 1) },
                });
            var whatsNew = new StackPanel { Spacing = 6 };
            whatsNew.Children.Add(Text("What’s New", 13, secondary: true, bold: true));
            whatsNew.Children.Add(UpdateCard(notes));
            AutomationProperties.SetAutomationId(whatsNew, "hermes-update.whats-new");
            col.Children.Add(whatsNew);
        }
        col.Children.Add(Buttons(run, dialog));
        return new ScrollViewer { Content = col, MaxHeight = 640, HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private static FrameworkElement Cell(FrameworkElement e, int column) { Grid.SetColumn(e, column); return e; }

    private static Border UpdateCard(UIElement child) => new()
    {
        Child = child, Padding = new Thickness(14), CornerRadius = new CornerRadius(8),
        Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
    };

    private static FrameworkElement Header(HermesUpdate run)
    {
        var g = new Grid { ColumnSpacing = 14 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(56) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        FrameworkElement symbol = run.Symbol switch
        {
            HermesUpdate.Mark.None => new ProgressRing { IsActive = true, Width = 32, Height = 32 },
            HermesUpdate.Mark.Asking => Glyph("", Brush("AccentTextFillColorPrimaryBrush")),
            HermesUpdate.Mark.Good => Glyph("", new SolidColorBrush(Green)),
            HermesUpdate.Mark.Unsure => Glyph("", new SolidColorBrush(Orange)),
            HermesUpdate.Mark.Terminal => Glyph("", new SolidColorBrush(Orange)),
            _ => Glyph("", new SolidColorBrush(Orange)),
        };
        symbol.VerticalAlignment = VerticalAlignment.Top;
        symbol.HorizontalAlignment = HorizontalAlignment.Center;
        g.Children.Add(symbol);
        var lines = new StackPanel { Spacing = 3 };
        var headline = Text(run.Headline, 17, bold: true);
        headline.FontWeight = FontWeights.Bold;
        AutomationProperties.SetAutomationId(headline, "hermes-update.headline");
        AutomationProperties.SetHeadingLevel(headline, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        lines.Children.Add(headline);
        if (run.Versions is { } versions)
        {
            var v = Text(versions, 14, secondary: true);
            AutomationProperties.SetAutomationId(v, "hermes-update.versions");
            lines.Children.Add(v);
        }
        // Which machine this is, so a gateway is never taken for something else.
        var place = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6,
            Children = { new FontIcon { Glyph = "", FontSize = 12, Foreground = Brush("TextFillColorSecondaryBrush") }, Text(run.Place, 12, secondary: true) },
        };
        AutomationProperties.SetAutomationId(place, "hermes-update.place");
        lines.Children.Add(place);
        if (run.Line is { } line)
        {
            var l = Text(line, 13, secondary: true);
            AutomationProperties.SetAutomationId(l, "hermes-update.line");
            lines.Children.Add(l);
        }
        Grid.SetColumn(lines, 1);
        g.Children.Add(lines);
        return g;
    }

    private static FontIcon Glyph(string glyph, Brush brush) => new() { Glyph = glyph, FontSize = 36, Foreground = brush };

    private static FrameworkElement StepsCard(HermesUpdate run)
    {
        var rows = new StackPanel();
        var first = true;
        foreach (var step in run.Steps)
        {
            if (!first) rows.Children.Add(new Border { Height = 1, Margin = new Thickness(34, 0, 0, 0), Background = Brush("DividerStrokeColorDefaultBrush") });
            first = false;
            var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 7, 0, 7) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            FrameworkElement mark = step.State switch
            {
                HermesUpdateStepState.Done => new FontIcon { Glyph = "", FontSize = 18, Foreground = new SolidColorBrush(Green) },
                HermesUpdateStepState.Active => new ProgressRing { IsActive = true, Width = 16, Height = 16 },
                HermesUpdateStepState.Skipped => new FontIcon { Glyph = "", FontSize = 16, Foreground = Brush("TextFillColorTertiaryBrush") },
                HermesUpdateStepState.Failed => new FontIcon { Glyph = "", FontSize = 18, Foreground = new SolidColorBrush(Red) },
                _ => new FontIcon { Glyph = "", FontSize = 18, Foreground = Brush("TextFillColorTertiaryBrush") },
            };
            mark.VerticalAlignment = VerticalAlignment.Top;
            mark.Margin = new Thickness(0, 1, 0, 0);
            g.Children.Add(mark);
            var words = new StackPanel { Spacing = 2 };
            var title = Text(step.Title, 14);
            if (step.State is HermesUpdateStepState.Waiting or HermesUpdateStepState.Skipped) title.Foreground = Brush("TextFillColorSecondaryBrush");
            words.Children.Add(title);
            if (HermesUpdate.StepDetail(step) is { } detail)
            {
                var d = Text(detail, 12, secondary: true);
                AutomationProperties.SetAutomationId(d, "hermes-update.detail." + step.Id.ToString().ToLowerInvariant());
                words.Children.Add(d);
            }
            Grid.SetColumn(words, 1);
            g.Children.Add(words);
            AutomationProperties.SetAutomationId(g, "hermes-update.step." + step.Id.ToString().ToLowerInvariant());
            AutomationProperties.SetName(g, step.Title);
            AutomationProperties.SetItemStatus(g, step.State switch
            {
                HermesUpdateStepState.Done => "Done", HermesUpdateStepState.Active => "In progress", HermesUpdateStepState.Skipped => "Not needed",
                HermesUpdateStepState.Failed => "Failed", _ => "Waiting",
            });
            rows.Children.Add(g);
        }
        var card = UpdateCard(rows);
        card.Padding = new Thickness(14, 6, 14, 6);
        AutomationProperties.SetAutomationId(card, "hermes-update.steps");
        return card;
    }

    /// The Mac's order: a secondary action on the left, the close word, the default button last on the right.
    private static FrameworkElement Buttons(HermesUpdate run, ContentDialog dialog)
    {
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        Button Push(string title, string id, Action perform, bool prominent = false)
        {
            var b = new Button { Content = title, MinWidth = 80 };
            if (prominent) b.Style = Style("AccentButtonStyle");
            AutomationProperties.SetAutomationId(b, id);
            b.Click += (_, _) => perform();
            return b;
        }
        void Close() => dialog.Hide();
        void CopyDetails() => Share.Copy(run.Details());
        void Output()
        {
            if (run.Action is not { } action) return;
            if (Navigator_OpenOutput is { } open) { dialog.Hide(); open(action); return; }
            // No page to push it on (the "too old" page): the output in a dialog of its own once this one closes.
            var root = dialog.XamlRoot;
            void ShowOutput(ContentDialog d, ContentDialogClosedEventArgs e)
            {
                dialog.Closed -= ShowOutput;
                var view = new ActionOutputView(action, ActionWords.Update, "Update Output");
                var output = new ContentDialog { Title = "Update Output", Content = view, CloseButtonText = "Done" };
                output.Closed += (_, _) => view.Detach();
                _ = SafeDialog.ShowAsync(root, output);
            }
            dialog.Closed += ShowOutput;
            dialog.Hide();
        }
        switch (run.Phase)
        {
            case HermesUpdate.PhaseKind.Checking:
                right.Children.Add(Push("Hide", "hermes-update.close", Close, prominent: true)); break;
            case HermesUpdate.PhaseKind.Asking:
                right.Children.Add(Push("Not Now", "hermes-update.close", Close));
                right.Children.Add(Push("Update", "hermes-update.go", run.Confirm, prominent: true)); break;
            case HermesUpdate.PhaseKind.Working:
                if ((run.WorkStarted ?? run.Steps.FirstOrDefault(s => s.Id != HermesUpdateStepId.Check)?.Started) is { } started)
                    left.Children.Add(Text($"{HermesUpdateWords.Elapsed((int)(DateTimeOffset.Now - started).TotalSeconds)} so far", 12, secondary: true, wrap: false));
                right.Children.Add(Push("Hide", "hermes-update.close", Close, prominent: true)); break;
            default:
                switch (run.End)
                {
                    case HermesUpdateEnd.CantUpdateHere { Command: not null }:
                        right.Children.Add(Push("Done", "hermes-update.close", Close));
                        right.Children.Add(Push("Copy Command", "hermes-update.copy-command", () => Share.Copy(run.CommandToCopy!), prominent: true)); break;
                    case HermesUpdateEnd.Failed when run.CheckFailed:
                        // Nothing started: the check can simply run again.
                        left.Children.Add(Push("Copy Details", "hermes-update.copy", CopyDetails));
                        right.Children.Add(Push("Done", "hermes-update.close", Close));
                        right.Children.Add(Push("Try Again", "hermes-update.retry", run.Check, prominent: true)); break;
                    case HermesUpdateEnd.Failed when run.Again != null:
                        left.Children.Add(Push("Copy Details", "hermes-update.copy", CopyDetails));
                        if (run.HasOutput) right.Children.Add(Push("Show Update Output", "hermes-update.output", Output));
                        right.Children.Add(Push("Done", "hermes-update.close", Close));
                        right.Children.Add(Push("Try Again", "hermes-update.retry", () =>
                        {
                            var again = run.Again;
                            if (HermesUpdateCenter.Shared.Run(run.Key) == run) HermesUpdateCenter.Shared.Forget(run.Key);
                            void Reopen(ContentDialog d, ContentDialogClosedEventArgs e)
                            {
                                dialog.Closed -= Reopen;
                                again?.Invoke();
                            }
                            dialog.Closed += Reopen;
                            dialog.Hide();
                        }, prominent: true)); break;
                    case HermesUpdateEnd.Failed:
                        if (run.HasOutput) left.Children.Add(Push("Show Update Output", "hermes-update.output", Output));
                        right.Children.Add(Push("Done", "hermes-update.close", Close));
                        right.Children.Add(Push("Copy Details", "hermes-update.copy", CopyDetails, prominent: true)); break;
                    case HermesUpdateEnd.Updated or HermesUpdateEnd.Unchanged or HermesUpdateEnd.Unconfirmed:
                        // What Hermes printed stays reachable after any finished run.
                        if (run.HasOutput) left.Children.Add(Push("Show Update Output", "hermes-update.output", Output));
                        right.Children.Add(Push("Done", "hermes-update.close", Close, prominent: true)); break;
                    default:
                        right.Children.Add(Push("Done", "hermes-update.close", Close, prominent: true)); break;
                }
                break;
        }
        var row = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        left.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(left);
        Grid.SetColumn(right, 1);
        row.Children.Add(right);
        return row;
    }

    /// Show Update Output: Status & Maintenance pushes the output page (set by the page while it is on screen); without
    /// it, the output in a dialog of its own.
    public static Action<GatewayActionRun>? Navigator_OpenOutput { get; set; }
}
