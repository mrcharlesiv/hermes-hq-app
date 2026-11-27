using Hermes.Core.Composer;
using Hermes.Core.Net;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Composer;

/// The Mac's model selector (App/Chat/Menus/MacModelPicker.swift, design B; ModelSheetViewController.swift): the
/// Models list, one selector — "Search Models", Favorites, then each provider's models with a star, the current one
/// marked — and at its foot the chat's settings card: Thinking (the reasoning levels), Fast | YOLO, and Approval Mode
/// with its pop-up (ModelSettingsFoot). A click switches the model for the next reply.
internal static class ModelsDialog
{
    public const string OfflineText = "You’re offline. Models can be changed when you reconnect.";
    public const string EmptyTitle = "No Models Available";
    /// The automation id on each model row's name (the walk reads the rows by it).
    public const string RowNameId = "models.row.name";
    public const string EmptyText = "Hermes sent no models for this chat. Check Again asks it once more.";
    /// The automation id on the words beside Thinking ("High · Thinks hard"); the walk reads them by it.
    public const string ThinkingValueId = "model.panel.thinking.value";

    public static async Task ShowAsync(XamlRoot root, ChatComposer c, IModelSwitchUi ui, string? query)
    {
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        var dialog = new ContentDialog { Title = "Models", CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close };
        var search = new TextBox { PlaceholderText = "Search Models", Text = query ?? "" };
        AutomationProperties.SetName(search, "Search Models");
        var list = new StackPanel();
        var strip = new StackPanel { Spacing = 10, Margin = new Thickness(0, 8, 0, 0) };
        var content = new Grid { Width = 460, RowSpacing = 8 };
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.Children.Add(search);
        var scroll = new ScrollViewer { Content = list, Height = 380 };
        Grid.SetRow(scroll, 1);
        content.Children.Add(scroll);
        Grid.SetRow(strip, 2);
        content.Children.Add(strip);
        dialog.Content = content;

        var loading = false;
        Exception? failure = null;
        var closed = false;
        (string Title, string Reason)? footFailure = null;
        // The Mac names the bot as the roster does (`actions.bot?.name`), not by its profile slug.
        var bot = HermesHQ.Features.Bots.ListsHub.Current?.Bots.Bot(c.Session.Profile)?.Name is { Length: > 0 } shown
            ? shown : ModelSettingsFoot.BotName(c.Session.Profile);
        dialog.Closed += (_, _) => closed = true;

        void Pick(ModelChoice model)
        {
            void SwitchAfterClose(ContentDialog d, ContentDialogClosedEventArgs e)
            {
                dialog.Closed -= SwitchAfterClose;
                _ = c.SwitchModelAsync(model, ui);
            }
            dialog.Closed += SwitchAfterClose;
            dialog.Hide();
        }

        void Draw(bool redrawStrip = true)
        {
            HermesHQ.Services.UiTree.ClearPanel(list);
            var options = c.Options;
            if (options == null)
            {
                if (loading)
                {
                    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(8, 16, 8, 16) };
                    row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                    row.Children.Add(Ui.Text("Loading Models", 14, secondary: true));
                    list.Children.Add(row);
                }
                else if (c.Offline) list.Children.Add(Note(OfflineText, null, null));
                else if (failure != null)
                    list.Children.Add(Note(ModelLoad.FailureTitle + (ModelLoad.Words(failure, c.Offline) is { } w ? "\n" + w : ""), "Try Again", () => Load(true)));
                if (redrawStrip) DrawStrip();
                return;
            }
            var current = c.Current();
            var favorites = c.Prefs.Favorites;
            var models = options.Choices;
            if (models.Count == 0)
            {
                list.Children.Add(Note(EmptyTitle + "\n" + EmptyText, "Check Again", () => Load(true)));
                if (redrawStrip) DrawStrip();
                return;
            }
            var q = search.Text.Trim();
            if (q.Length == 0 && ModelSheetModel.FavoriteRows(models, favorites) is { Count: > 0 } starred)
            {
                list.Children.Add(Ui.Header(ModelSheetModel.FavoritesTitle));
                foreach (var m in starred) list.Children.Add(Row(m, current, true));
            }
            var sections = ModelSheetModel.Sections(models, q, (current.Id, current.Provider));
            if (sections.Count == 0) list.Children.Add(Note($"No Results for “{q}”", null, null));
            foreach (var section in sections)
            {
                list.Children.Add(Ui.Header(section.Title));
                foreach (var m in section.Models) list.Children.Add(Row(m, current, favorites.Contains(m.Key)));
            }
            if (redrawStrip) DrawStrip();
        }

        UIElement Row(ModelChoice m, ModelChoice current, bool starred)
        {
            var words = ModelSheetModel.Row(m, current, starred);
            var grid = new Grid { ColumnSpacing = 8 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            if (words.Current) grid.Children.Add(Ui.Glyph("\uE73E", 12));
            var name = Ui.Text(words.Title, 14, bold: words.Current, wrap: false);
            AutomationProperties.SetAutomationId(name, RowNameId);
            ToolTipService.SetToolTip(name, words.Tip);
            Grid.SetColumn(name, 1);
            grid.Children.Add(name);
            var star = Ui.Quiet(Ui.Glyph(words.Starred ? "\uE735" : "\uE734", 13), words.StarName, (_, _) =>
            {
                c.Prefs.ToggleFavorite(m.Provider, m.Id);
                Draw();
            });
            Grid.SetColumn(star, 2);
            grid.Children.Add(star);
            var button = Ui.Row(grid, (_, _) => Pick(m));
            AutomationProperties.SetName(button, words.AccessibleName);
            button.IsEnabled = !c.Offline;
            return button;
        }

        // [WIN-MODEL-YOLO-APPROVAL] The foot card (MacModelPicker.swift MacModelSettingsFoot): Thinking, a hairline,
        // Fast | YOLO side by side with an upright hairline between, a hairline, Approval Mode with its pop-up; the
        // offline note under the card. The rules (words, ids, enablement, tab order, requests) are ModelSettingsFoot's.
        void DrawStrip()
        {
            strip.Children.Clear();
            var input = c.MenuInput();
            var enabled = ModelSettingsFoot.Enabled(input.Offline, switching: false, input.FastSupported);
            var stops = ModelSettingsFoot.TabStops(ThinkingSteps.Stops(input.ReasoningLevels, input.CanTurnOff).Count, input.FastSupported,
                input.Offline, switching: false);
            var rows = new StackPanel();
            var card = new Border
            {
                Child = rows, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1),
                Background = Ui.Res<Brush>("CardBackgroundFillColorDefaultBrush"), BorderBrush = Ui.Res<Brush>("CardStrokeColorDefaultBrush"),
            };
            strip.Children.Add(card);

            // Thinking … High · Thinks hard, and the lit step bar under it (MacModelSettingsFoot relabel(),
            // MacThinkingSteps): the row with any level, the bar with two or more; the words follow the bar as it moves,
            // and only the level it settles on is sent, as the drop-down sent it.
            var efforts = ThinkingSteps.Stops(input.ReasoningLevels, input.CanTurnOff);
            if (ThinkingSteps.ShowsThinking(efforts.Count))
            {
                var effort = ThinkingSteps.Effort(efforts, input.ReasoningCurrent);
                var head = new Grid { ColumnSpacing = 12, Margin = new Thickness(14, 8, 14, ThinkingSteps.ShowsBar(efforts.Count) ? 2 : 8) };
                head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var title = Ui.Text(ModelSettingsFoot.ThinkingTitle, 14, bold: true, wrap: false);
                AutomationProperties.SetAccessibilityView(title, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                head.Children.Add(title);
                var value = new TextBlock
                {
                    FontSize = 14, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
                    TextAlignment = TextAlignment.Right, HorizontalAlignment = HorizontalAlignment.Stretch,
                };
                AutomationProperties.SetAutomationId(value, ThinkingValueId);
                AutomationProperties.SetAccessibilityView(value, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                // Cut short, its tooltip is the whole line (the runs' text; TextBlock.Text doesn't carry them).
                var valueText = "";
                value.IsTextTrimmedChanged += (_, _) => ToolTipService.SetToolTip(value, value.IsTextTrimmed ? valueText : null);
                Grid.SetColumn(value, 1);
                head.Children.Add(value);
                rows.Children.Add(head);

                var bar = new ThinkingStepsBar()
                {
                    IsEnabled = enabled.Bar, TabIndex = 1, IsTabStop = stops.Contains(FootStop.Bar), Margin = new Thickness(10, 0, 10, 2),
                    Visibility = ThinkingSteps.ShowsBar(efforts.Count) ? Visibility.Visible : Visibility.Collapsed,
                };
                bar.Set(efforts, ThinkingSteps.Lit(efforts, effort));
                void Relabel()
                {
                    var words = ThinkingSteps.Value(bar.Level, efforts.Count);
                    valueText = words.Text;
                    if (value.IsTextTrimmed) ToolTipService.SetToolTip(value, valueText);
                    value.Inlines.Clear();
                    if (words.Name is { } levelName)
                    {
                        value.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = levelName, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                        value.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = " · ", Foreground = Ui.Res<Brush>("TextFillColorSecondaryBrush") });
                    }
                    value.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = words.Line, Foreground = Ui.Res<Brush>("TextFillColorSecondaryBrush") });
                    bar.SetAccessibleValue(words.AccessibleValue);
                }
                Relabel();
                bar.LevelMoved += Relabel;
                bar.EffortChosen += level =>
                {
                    if (!ThinkingSteps.ShouldCommit(level, effort) || level is null) return;
                    effort = level;   // the card's state.effort: the same level settling again sends nothing more
                    _ = c.SetReasoningAsync(level, ui).ContinueWith(_ => dispatcher.TryEnqueue(Redraw));
                };
                rows.Children.Add(bar);
                rows.Children.Add(Line(horizontal: true));
            }

            // Fast | YOLO.
            var halves = new Grid { MinHeight = 40 };
            halves.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            halves.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            halves.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var fast = SwitchHalf("\uE945", ModelSettingsFoot.FastName, ModelSettingsFoot.FastId, input.FastSupported && input.FastOn,
                warning: false, enabled.Fast, input.FastSupported, ModelSettingsFoot.FastTip(input.FastSupported), note: null,
                tabIndex: 2, tabStop: stops.Contains(FootStop.Fast), on =>
                {
                    if (on != input.FastOn) _ = c.SetFastAsync(on, ui).ContinueWith(_ => dispatcher.TryEnqueue(Redraw));
                });
            halves.Children.Add(fast);
            var upright = Line(horizontal: false);
            Grid.SetColumn(upright, 1);
            halves.Children.Add(upright);
            var yolo = SwitchHalf("\uEA18", ModelSettingsFoot.YoloName, ModelSettingsFoot.YoloId, input.Yolo, warning: input.Yolo,
                enabled.Yolo, supported: true, tip: ModelSettingsFoot.YoloNote, note: ModelSettingsFoot.YoloNote,
                tabIndex: 3, tabStop: stops.Contains(FootStop.Yolo), on =>
                {
                    if (on == input.Yolo) return;
                    _ = Task.Run(async () =>
                    {
                        try { await c.SetYoloAsync(on); footFailure = null; }
                        catch (Exception x) when (x is GatewayException or OperationCanceledException)
                        {
                            footFailure = (ModelSettingsFoot.YoloFailureTitle(on), MenusText.Of(x));
                        }
                        dispatcher.TryEnqueue(Redraw);
                    });
                });
            Grid.SetColumn(yolo, 2);
            halves.Children.Add(yolo);
            rows.Children.Add(halves);
            rows.Children.Add(Line(horizontal: true));

            // Approval Mode … all Ivy chats ……… [Smart ⌄]
            rows.Children.Add(ApprovalRow(input, enabled, stops));

            if (input.Offline)
            {
                var offline = Ui.Text(ModelSettingsFoot.OfflineNote, 12);
                offline.Foreground = Ui.Res<Brush>("SystemFillColorCautionBrush");
                offline.Margin = new Thickness(8, 0, 8, 0);
                AutomationProperties.SetAutomationId(offline, ModelSettingsFoot.OfflineId);
                strip.Children.Add(offline);
            }
            if (footFailure is { } f)
            {
                // A ContentDialog can't open over this one: the failure reads under the card instead of an alert.
                var words = Ui.Text($"{f.Title}. {f.Reason}", 12);
                words.Foreground = Ui.Res<Brush>("SystemFillColorCriticalBrush");
                words.Margin = new Thickness(8, 0, 8, 0);
                AutomationProperties.SetLiveSetting(words, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Assertive);
                strip.Children.Add(words);
            }
        }

        UIElement ApprovalRow(ModelMenuInput input, FootEnablement enabled, IReadOnlyList<FootStop> stops)
        {
            var mode = input.ApprovalMode;
            var row = new Grid { MinHeight = 40, ColumnSpacing = 6, Padding = new Thickness(12, 0, 6, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var warns = ModelSettingsFoot.ApprovalWarns(mode);
            var icon = Ui.Glyph(warns ? "\uE7BA" : "\uEA18", 14);
            icon.Foreground = Ui.Res<Brush>(warns ? "SystemFillColorCautionBrush" : "AccentTextFillColorPrimaryBrush");
            icon.VerticalAlignment = VerticalAlignment.Center;
            icon.Opacity = enabled.Approvals ? 1 : 0.45;
            AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            row.Children.Add(icon);
            var name = Ui.Text(ModelSettingsFoot.ApprovalTitle, 14, wrap: false);
            name.VerticalAlignment = VerticalAlignment.Center;
            name.Opacity = enabled.Approvals ? 1 : 0.45;
            AutomationProperties.SetAccessibilityView(name, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            Grid.SetColumn(name, 1);
            row.Children.Add(name);
            // The note shows whole or not at all: the pop-up's tooltip, its spoken value and its heading still say it.
            var reach = new TextBlock
            {
                Text = ModelSettingsFoot.ReachNote(bot), FontSize = 14, TextWrapping = TextWrapping.NoWrap, Margin = new Thickness(2, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center, Foreground = Ui.Res<Brush>("TextFillColorSecondaryBrush"),
            };
            AutomationProperties.SetAccessibilityView(reach, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            var reachBox = new Border { Child = reach };
            reachBox.SizeChanged += (_, e) =>
            {
                reach.Measure(new global::Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
                reach.Opacity = reach.DesiredSize.Width <= e.NewSize.Width + 0.5 ? 1 : 0;
            };
            Grid.SetColumn(reachBox, 2);
            row.Children.Add(reachBox);

            var pick = new StackPanel { MinWidth = 280 };
            var flyout = new Flyout { Content = pick };
            var button = new DropDownButton
            {
                Content = ModelSettingsFoot.ApprovalValue(mode), Flyout = flyout, IsEnabled = enabled.Approvals, VerticalAlignment = VerticalAlignment.Center,
                TabIndex = 4, IsTabStop = stops.Contains(FootStop.Approvals),
            };
            AutomationProperties.SetAutomationId(button, ModelSettingsFoot.ApprovalsId);
            AutomationProperties.SetName(button, ModelSettingsFoot.ApprovalTitle);
            AutomationProperties.SetItemStatus(button, ModelSettingsFoot.ApprovalAccessibleValue(mode, bot));
            ToolTipService.SetToolTip(button, ModelSettingsFoot.ApprovalTip(bot));
            // Read each time it opens, so it shows what the gateway last said, under the reach as its heading.
            flyout.Opening += (_, _) =>
            {
                pick.Children.Clear();
                pick.Children.Add(Ui.Header(ModelSettingsFoot.ApprovalsReach(bot)));
                var now = c.ModelState.ApprovalMode;
                foreach (var entry in ModelSettingsFoot.ApprovalModes)
                {
                    var grid = new Grid { ColumnSpacing = 8 };
                    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
                    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    if (now == entry.Mode) grid.Children.Add(Ui.Glyph("\uE73E", 12));
                    var words = new StackPanel();
                    words.Children.Add(Ui.Text(entry.Name, 14));
                    words.Children.Add(Ui.Text(entry.Line, 12, secondary: true));
                    Grid.SetColumn(words, 1);
                    grid.Children.Add(words);
                    var choose = Ui.Row(grid, (_, _) =>
                    {
                        flyout.Hide();
                        ChooseApprovals(entry.Mode);
                    });
                    AutomationProperties.SetAutomationId(choose, ModelSettingsFoot.ApprovalItemId(entry.Mode));
                    AutomationProperties.SetName(choose, entry.Name);
                    AutomationProperties.SetHelpText(choose, entry.Line);
                    if (now == entry.Mode) AutomationProperties.SetItemStatus(choose, "Selected");
                    pick.Children.Add(choose);
                }
            };
            Grid.SetColumn(button, 3);
            row.Children.Add(button);
            return row;
        }

        void ChooseApprovals(string mode)
        {
            if (!ModelSettingsFoot.ShouldSetApprovalMode(c.ModelState.ApprovalMode, mode)) return;
            var sending = c.SetApprovalModeAsync(mode);   // shown at once (the composer paints it before the call)
            Redraw();
            _ = Task.Run(async () =>
            {
                try { await sending; footFailure = null; }
                catch (Exception x) when (x is GatewayException or OperationCanceledException)
                {
                    footFailure = (ModelSettingsFoot.ApprovalFailureTitle, MenusText.Of(x));
                }
                dispatcher.TryEnqueue(Redraw);
            });
        }

        // The late state refresh: an answer that lands after the selector closed changes nothing on screen.
        void Redraw()
        {
            if (!closed) DrawStrip();
        }

        // An older Hermes leaves the mode out of the chat's info: read it once, and the pop-up fills in.
        void LoadApprovalsIfUnknown()
        {
            if (!ModelSettingsFoot.ShouldLoadApprovals(c.ModelState.ApprovalMode, c.Offline)) return;
            _ = Task.Run(async () =>
            {
                await c.LoadApprovalModeAsync();
                dispatcher.TryEnqueue(() =>
                {
                    if (ModelSettingsFoot.RepaintAfterLoad(closed, c.ModelState.ApprovalMode)) DrawStrip();
                });
            });
        }

        void Load(bool refresh)
        {
            loading = true;
            failure = null;
            Draw();
            _ = Task.Run(async () =>
            {
                Exception? error = null;
                try { await c.LoadModelsAsync(refresh); }
                catch (Exception x) { error = x; }
                dispatcher.TryEnqueue(() => { if (closed) return; loading = false; failure = error; Draw(); });
            });
        }

        search.TextChanged += (_, _) => Draw(redrawStrip: false);
        dialog.Opened += (_, _) => search.Focus(FocusState.Programmatic);
        Load(false);
        LoadApprovalsIfUnknown();
        await Ui.Show(root, dialog);
    }

    /// The card's hairlines: across between its rows, upright between Fast and YOLO.
    private static FrameworkElement Line(bool horizontal) => new Microsoft.UI.Xaml.Shapes.Rectangle
    {
        Fill = Ui.Res<Brush>("DividerStrokeColorDefaultBrush"),
        Height = horizontal ? 1 : double.NaN, Width = horizontal ? double.NaN : 1,
        Margin = horizontal ? new Thickness(14, 0, 0, 0) : new Thickness(0, 8, 0, 8),
    };

    /// One half of the Fast | YOLO row (MacSwitchHalf): its glyph, its name and a switch; dimmed, its tip says why.
    /// Unsupported (Fast on a model without it), the switch is hidden.
    private static FrameworkElement SwitchHalf(string glyph, string name, string id, bool on, bool warning, bool enabled, bool supported,
        string tip, string? note, int tabIndex, bool tabStop, Action<bool> changed)
    {
        var grid = new Grid { ColumnSpacing = 6, Padding = new Thickness(12, 0, 8, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Ui.Glyph(glyph, 14);
        icon.Foreground = Ui.Res<Brush>(warning ? "SystemFillColorCautionBrush" : "AccentTextFillColorPrimaryBrush");
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Opacity = enabled ? 1 : 0.45;
        AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        grid.Children.Add(icon);
        var words = Ui.Text(name, 14, wrap: false);
        words.VerticalAlignment = VerticalAlignment.Center;
        words.Opacity = enabled ? 1 : 0.45;
        AutomationProperties.SetAccessibilityView(words, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var toggle = new ToggleSwitch
        {
            IsOn = on, IsEnabled = enabled, OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center,
            Visibility = supported ? Visibility.Visible : Visibility.Collapsed, TabIndex = tabIndex, IsTabStop = tabStop,
        };
        AutomationProperties.SetAutomationId(toggle, id);
        AutomationProperties.SetName(toggle, name);
        if (note != null) AutomationProperties.SetHelpText(toggle, note);
        toggle.Toggled += (_, _) => changed(toggle.IsOn);
        Grid.SetColumn(toggle, 2);
        grid.Children.Add(toggle);
        ToolTipService.SetToolTip(grid, tip);
        return grid;
    }

    private static UIElement Note(string text, string? action, Action? act)
    {
        var box = new StackPanel { Spacing = 8, Margin = new Thickness(12, 20, 12, 20), HorizontalAlignment = HorizontalAlignment.Center };
        var t = Ui.Text(text, 14, secondary: true);
        t.TextAlignment = TextAlignment.Center;
        box.Children.Add(t);
        if (action != null && act != null)
        {
            var b = new Button { Content = action, HorizontalAlignment = HorizontalAlignment.Center };
            b.Click += (_, _) => act();
            box.Children.Add(b);
        }
        return box;
    }
}
