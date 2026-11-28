using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Tasks Settings (`App/Pages/Tasks/TodoSettingsSheet.swift`, commit f3a9b867a): Catch Tasks in Chats, Getting Tasks
/// Ready, and Ideas (Suggest Tasks, Who Looks, Where to Look ›, Each Day At, Ideas a Day).
internal static class TasksSettingsDialog
{
    public static async Task PresentAsync(XamlRoot? root, TasksStore store, TaskIdeasStore? ideasStore = null)
    {
        while (true)
        {
            var openSources = await PresentOnceAsync(root, store, ideasStore);
            if (!openSources) return;
            await IdeasSourcesDialog.PresentAsync(root, store, ideasStore);
        }
    }

    private static async Task<bool> PresentOnceAsync(XamlRoot? root, TasksStore store, TaskIdeasStore? ideasStore)
    {
        var bots = PageKit.Bots.Select(b => (b.Name, BotName(b.Name))).ToList();
        var model = new TodoSettingsModel(store, bots);
        var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var body = new StackPanel { Spacing = 6, MinWidth = 400 };
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 560 };
        AutomationProperties.SetAutomationId(scroll, "tasks.settings");

        var openSourcesAfterClose = false;
        ContentDialog? dialog = null;

        void Header(string text)
        {
            var t = Text(text, 13, bold: true, color: Secondary);
            t.Margin = new Thickness(0, 14, 0, 2);
            AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
            body.Children.Add(t);
        }
        void Footer(string text) => body.Children.Add(Text(text, 12, color: Secondary));
        FrameworkElement Row(string label, FrameworkElement control)
        {
            var grid = new Grid { ColumnSpacing = 12, MinHeight = 36 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var l = Text(label, 14);
            l.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(l);
            control.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(control, 1);
            grid.Children.Add(control);
            body.Children.Add(grid);
            return grid;
        }
        FrameworkElement Stepper(string label, string id, int value, int min, int max, Func<int, string> words, Func<int, Task<bool>> set)
        {
            var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            var shown = new TextBlock { Text = words(value), Foreground = Secondary, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
            var minus = new Button { Content = new FontIcon { Glyph = "\uE738", FontSize = 12 }, IsEnabled = value > min };
            var plus = new Button { Content = new FontIcon { Glyph = "\uE710", FontSize = 12 }, IsEnabled = value < max };
            AutomationProperties.SetName(minus, "Decrement");
            AutomationProperties.SetName(plus, "Increment");
            AutomationProperties.SetAutomationId(minus, id + ".minus");
            AutomationProperties.SetAutomationId(plus, id + ".plus");
            minus.Click += (_, _) => _ = set(value - 1);
            plus.Click += (_, _) => _ = set(value + 1);
            panel.Children.Add(shown);
            panel.Children.Add(minus);
            panel.Children.Add(plus);
            AutomationProperties.SetAutomationId(panel, id);
            AutomationProperties.SetName(panel, $"{label}, {words(value)}");
            return Row(label, panel);
        }
        TimePicker Time(string label, string id, string value, Func<TimeSpan, Task<bool>> set)
        {
            var picker = new TimePicker { SelectedTime = TodoSettingsCopy.Time(value), MinuteIncrement = 1 };
            AutomationProperties.SetName(picker, label);
            AutomationProperties.SetAutomationId(picker, id);
            picker.SelectedTimeChanged += (sender, e) => { if (e.NewTime is { } t && TodoSettingsCopy.Text(t) != value) _ = set(t); };
            Row(label, picker);
            return picker;
        }

        void Build()
        {
            body.Children.Clear();
            var draft = model.Draft;

            Header(TodoSettingsCopy.CatchTasks);
            var capture = new RadioButtons { MaxColumns = TodoSettingsCopy.CaptureOptions.Count };
            AutomationProperties.SetName(capture, TodoSettingsCopy.CatchTasks);
            AutomationProperties.SetAutomationId(capture, "tasks.settings.capture");
            foreach (var (title, key) in TodoSettingsCopy.CaptureOptions)
            {
                var option = new RadioButton { Content = title, Tag = key, IsChecked = draft.Capture == key };
                AutomationProperties.SetAutomationId(option, "tasks.settings.capture." + key);
                option.Checked += (_, _) => { if (model.Draft.Capture != key) _ = model.SetCapture(key); };
                capture.Items.Add(option);
            }
            body.Children.Add(capture);
            Footer(TodoSettingsCopy.CaptureFooter(draft.Capture));

            Header(TodoSettingsCopy.GettingReady);
            Stepper(TodoSettingsCopy.TimesADay, "tasks.settings.per-day", draft.PrepPerDay, TodoSettingsCopy.PerDayMin, TodoSettingsCopy.PerDayMax,
                TodoSettingsCopy.PerDay, model.SetPrepPerDay);
            Time(TodoSettingsCopy.QuietFrom, "tasks.settings.quiet-start", draft.QuietStart, model.SetQuietStart);
            Time(TodoSettingsCopy.QuietUntil, "tasks.settings.quiet-end", draft.QuietEnd, model.SetQuietEnd);
            Footer(TodoSettingsCopy.GettingReadyFooter);

            if (model.ShowsIdeas)
            {
                Header(TodoSettingsCopy.Ideas);
                var on = new ToggleSwitch { IsOn = model.IdeasOn, OnContent = "", OffContent = "" };
                AutomationProperties.SetName(on, TodoSettingsCopy.SuggestTasks);
                AutomationProperties.SetAutomationId(on, "tasks.settings.ideas");
                on.Toggled += (_, _) => { if (on.IsOn != model.IdeasOn) _ = model.SetIdeas(on.IsOn); };
                Row(TodoSettingsCopy.SuggestTasks, on);
                if (model.IdeasOn)
                {
                    if (model.ShowsWhoLooks)
                    {
                        var activeBots = draft.ActiveIdeasBots;
                        if (draft.IdeasSources != null || activeBots.Count > 1)
                        {
                            var label = TaskIdeasSummary.ActiveBotsLabel(activeBots, bots);
                            var btn = Quiet(label + " ›", () =>
                            {
                                openSourcesAfterClose = true;
                                dialog?.Hide();
                            });
                            AutomationProperties.SetAutomationId(btn, "tasks.settings.ideas-bots");
                            Row(TodoSettingsCopy.WhoLooks, btn);
                        }
                        else
                        {
                            var who = new ComboBox { MinWidth = 160 };
                            foreach (var (id, name) in model.Bots) who.Items.Add(new ComboBoxItem { Content = name, Tag = id });
                            who.SelectedIndex = Math.Max(0, model.Bots.ToList().FindIndex(b => b.Id == model.Looker));
                            AutomationProperties.SetName(who, TodoSettingsCopy.WhoLooks);
                            AutomationProperties.SetAutomationId(who, "tasks.settings.ideas-bot");
                            who.SelectionChanged += (_, _) =>
                            {
                                if (who.SelectedItem is ComboBoxItem { Tag: string id } && id != model.Looker) _ = model.SetIdeasBot(id);
                            };
                            Row(TodoSettingsCopy.WhoLooks, who);
                        }
                    }

                    // "Where to Look" row (0.9.86+ sources UI)
                    if (draft.IdeasSources != null || ideasStore != null)
                    {
                        var sources = draft.IdeasSources ?? ideasStore?.Page.Sources ?? new TodoIdeasSources();
                        var connectors = ideasStore?.Page.AvailableSources?.Connectors ?? [];
                        var summary = TaskIdeasSummary.ActiveSourcesLabel(sources, connectors);
                        var whereBtn = Quiet(summary + " ›", () =>
                        {
                            openSourcesAfterClose = true;
                            dialog?.Hide();
                        });
                        AutomationProperties.SetName(whereBtn, "Where to Look: " + summary);
                        AutomationProperties.SetAutomationId(whereBtn, "tasks.settings.ideas-sources");
                        Row("Where to Look", whereBtn);
                    }

                    Time(TodoSettingsCopy.EachDayAt, "tasks.settings.ideas-at", draft.IdeasAt ?? TodoSettingsCopy.DefaultIdeasAt, model.SetIdeasAt);
                    Stepper(TodoSettingsCopy.IdeasADay, "tasks.settings.ideas-max", draft.IdeasMax ?? TodoSettingsCopy.DefaultIdeasMax,
                        TodoSettingsCopy.IdeasMin, TodoSettingsCopy.IdeasMax, TodoSettingsCopy.UpTo, model.SetIdeasMax);
                }
                var botsSummary = TaskIdeasSummary.ActiveBotsLabel(draft.ActiveIdeasBots, bots);
                Footer(TodoSettingsCopy.IdeasFooter(botsSummary));
            }
        }

        model.Changed += () => ui.TryEnqueue(Build);
        model.IdeasChanged += () => { if (ideasStore != null) _ = ideasStore.RefreshAsync(force: true); };
        Build();
        dialog = new ContentDialog
        {
            Title = TodoSettingsCopy.Title,
            Content = scroll,
            CloseButtonText = TodoSettingsCopy.Done,
            DefaultButton = ContentDialogButton.Close,
        };
        await PageKit.ShowAsync(root, dialog);
        return openSourcesAfterClose;
    }
}
