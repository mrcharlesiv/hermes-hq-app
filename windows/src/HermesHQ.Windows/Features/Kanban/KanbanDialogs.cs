using Hermes.Core.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Kanban;

/// How Kanban Works and New Task (App/Pages/Kanban/KanbanViewController.swift KanbanAboutView, NewTaskSheet.swift).
internal static class KanbanDialogs
{
    /// Who runs tasks, each status with its dot and help, and the gestures.
    public static async Task ShowAboutAsync(XamlRoot? root)
    {
        var stack = new StackPanel { Spacing = 12, Width = 440 };
        stack.Children.Add(Text(KanbanCopy.AboutIntro, 14));
        var statuses = new StackPanel { Spacing = 8 };
        foreach (var status in KanbanModel.StatusOrder)
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var dot = Dot(Tone(status));
            dot.VerticalAlignment = VerticalAlignment.Top;
            dot.Margin = new Thickness(0, 6, 0, 0);
            row.Children.Add(dot);
            var words = new StackPanel { Spacing = 2 };
            words.Children.Add(Text(KanbanModel.Label(status), 14, bold: true));
            words.Children.Add(Text(KanbanModel.Help(status), 13, color: Secondary));
            Grid.SetColumn(words, 1);
            row.Children.Add(words);
            statuses.Children.Add(row);
        }
        stack.Children.Add(Card(statuses));
        stack.Children.Add(Text(KanbanCopy.AboutGestures, 13, color: Secondary));
        await ShowAsync(root, new ContentDialog
        {
            Title = KanbanCopy.HowKanbanWorks, Content = new ScrollViewer { Content = stack, MaxHeight = 520 },
            CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close,
        });
    }

    /// New Task (§4.7): what needs doing and its details; who does it (the board's default first, every bot, No One
    /// Yet); Start In Triage or Ready; More Options: priority, skills, Goal Mode. Add sends it; a failure stays in the
    /// sheet with the gateway's reason. Cancel or Escape with words typed in asks Discard Changes? (Keep Editing its
    /// default) and closes only on Discard Changes; nothing closes while Add is sending (KanbanNewTaskDraft).
    public static async Task NewTaskAsync(XamlRoot? root, KanbanStore store, Action<string?> created, string startIn = "triage")
    {
        // The board showing now is the one the task goes to, even if the store moves on while the sheet is up.
        var draft = new KanbanNewTaskDraft(store.Slug, store.ResolvedDefault, startIn);
        var title = new TextBox { PlaceholderText = KanbanCopy.WhatNeedsDoing };
        AutomationProperties.SetAutomationId(title, "kanban.new.title");
        var details = new TextBox { PlaceholderText = KanbanCopy.DetailsOptional, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64, MaxHeight = 160 };
        var failure = Text("", 13, color: Critical);
        failure.Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(failure, "kanban.new.failure");

        // The resolved default first, then every bot, then "" (No One Yet).
        var seen = new HashSet<string>();
        var people = new[] { store.ResolvedDefault }.Concat(store.Profiles.Select(p => p.Name)).Where(n => n.Length > 0 && seen.Add(n)).Append("").ToList();
        var who = draft.Who;
        var whoFooter = Text(KanbanCopy.WaitsUntilAssigned, 12, color: Secondary);
        var strip = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 84, ItemHeight = 84 };
        var tiles = new List<(string Name, Border Tile)>();
        void PaintWho()
        {
            foreach (var (name, tile) in tiles) tile.Background = name == who ? AccentWash(0.14) : Solid(Microsoft.UI.Colors.Transparent);
            whoFooter.Visibility = who.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        foreach (var person in people)
        {
            var name = person;
            var face = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
            var head = Face(name.Length == 0 ? null : name, 40);
            head.HorizontalAlignment = HorizontalAlignment.Center;
            face.Children.Add(head);
            var label = Text(name.Length == 0 ? KanbanCopy.NoOneYet : BotName(name), 12, color: Secondary);
            label.TextAlignment = TextAlignment.Center;
            label.MaxLines = 2;
            face.Children.Add(label);
            var tile = new Border { Child = face, Padding = new Thickness(4, 6, 4, 4), CornerRadius = new CornerRadius(14), Margin = new Thickness(2) };
            var button = new Button { Content = tile, Padding = new Thickness(0), Style = Style("QuietButtonStyle") };
            AutomationProperties.SetName(button, name.Length == 0 ? KanbanCopy.NoOneYet : BotName(name));
            AutomationProperties.SetAutomationId(button, name.Length == 0 ? "kanban.new.nobody" : "kanban.new.who." + name);
            button.Click += (_, _) => { who = draft.Who = name; PaintWho(); };
            tiles.Add((name, tile));
            strip.Children.Add(button);
        }
        PaintWho();

        var start = draft.Start;
        var startHelp = Text(KanbanModel.Help(start), 12, color: Secondary);
        var triage = new RadioButton { Content = "Triage", GroupName = "start", IsChecked = start == "triage" };
        var ready = new RadioButton { Content = "Ready", GroupName = "start", IsChecked = start == "ready" };
        triage.Checked += (_, _) => { start = draft.Start = "triage"; startHelp.Text = KanbanModel.Help(start); };
        ready.Checked += (_, _) => { start = draft.Start = "ready"; startHelp.Text = KanbanModel.Help(start); };
        var startRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        startRow.Children.Add(triage);
        startRow.Children.Add(ready);
        AutomationProperties.SetAutomationId(startRow, "kanban.new.start");

        var priority = draft.Priority;
        var pendingOther = false;
        ContentDialog? dialogRef = null;
        var priorityButton = new DropDownButton { Content = KanbanCopy.None };
        AutomationProperties.SetAutomationId(priorityButton, "kanban.new.priority");
        void PriorityMenu()
        {
            var menu = new MenuFlyout();
            foreach (var value in new[] { 0, 1, 2, 3, 5, 10, priority }.Distinct().Order())
            {
                var v = value;
                var item = new RadioMenuFlyoutItem { Text = v == 0 ? KanbanCopy.None : v.ToString(), IsChecked = v == priority, GroupName = "p" };
                item.Click += (_, _) => { priority = draft.Priority = v; priorityButton.Content = v == 0 ? KanbanCopy.None : v.ToString(); PriorityMenu(); };
                menu.Items.Add(item);
            }
            menu.Items.Add(new MenuFlyoutSeparator());
            var other = new MenuFlyoutItem { Text = KanbanCopy.OtherNumber };
            other.Click += (_, _) =>
            {
                // The dialog under it closes while the prompt shows; New Task opens again after (one dialog at a time).
                // An internal step, not a close: Closing lets it through without asking (unless Add is sending).
                pendingOther = true;
                dialogRef?.Hide();
            };
            menu.Items.Add(other);
            priorityButton.Flyout = menu;
        }
        PriorityMenu();
        var skills = new TextBox { PlaceholderText = KanbanCopy.SkillsPlaceholder, Width = 220 };
        AutomationProperties.SetAutomationId(skills, "kanban.new.skills");
        AutomationProperties.SetAutomationId(details, "kanban.new.details");
        var goal = new ToggleSwitch { Header = KanbanCopy.GoalMode };
        goal.Toggled += (_, _) => draft.GoalMode = goal.IsOn;
        title.TextChanged += (_, _) => draft.Title = title.Text;
        details.TextChanged += (_, _) => draft.Details = details.Text;
        skills.TextChanged += (_, _) => draft.Skills = skills.Text;
        // Keep Editing (and Other Number…) bring back the field that was being typed in, caret and selection included.
        var lastField = title;
        var (caret, selected) = (0, 0);
        foreach (var box in new[] { title, details, skills }) { var b = box; b.GotFocus += (_, _) => lastField = b; }

        var more = new StackPanel { Spacing = 10 };
        more.Children.Add(Labeled(KanbanCopy.Priority, priorityButton, KanbanCopy.HigherGoesFirst));
        more.Children.Add(Labeled(KanbanCopy.Skills, skills, KanbanCopy.SkillsHelp));
        var goalStack = new StackPanel { Spacing = 2 };
        goalStack.Children.Add(goal);
        goalStack.Children.Add(Text(KanbanCopy.GoalModeHelp, 12, color: Secondary));
        more.Children.Add(goalStack);
        more.Children.Add(Text(KanbanCopy.BoardSettingsNote, 12, color: Secondary));
        var expander = new Expander { Header = KanbanCopy.MoreOptions, Content = more, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };

        var form = new StackPanel { Spacing = 8, Width = 460 };
        form.Children.Add(failure);
        form.Children.Add(title);
        form.Children.Add(details);
        form.Children.Add(Header(KanbanCopy.WhoDoesIt));
        form.Children.Add(strip);
        form.Children.Add(whoFooter);
        form.Children.Add(Header(KanbanCopy.StartIn));
        form.Children.Add(startRow);
        form.Children.Add(startHelp);
        form.Children.Add(expander);

        var added = false;
        var askDiscard = false;
        while (true)
        {
            var fields = new ScrollViewer { Content = form, MaxHeight = 560 };
            var dialog = dialogRef = new ContentDialog
            {
                Title = KanbanCopy.NewTask, Content = fields,
                PrimaryButtonText = KanbanCopy.Add, CloseButtonText = KanbanCopy.Cancel, DefaultButton = ContentDialogButton.Primary,
                IsPrimaryButtonEnabled = draft.CanAdd,
            };
            AutomationProperties.SetAutomationId(dialog, "kanban.new");
            void Enable(object s, TextChangedEventArgs e) => dialog.IsPrimaryButtonEnabled = draft.CanAdd;
            title.TextChanged += Enable;
            dialog.PrimaryButtonClick += async (d, e) =>
            {
                var deferral = e.GetDeferral();
                // One Add at a time (Return held down, a second click): a write already sending is never repeated.
                if (!draft.CanAdd) { e.Cancel = true; deferral.Complete(); return; }
                dialog.IsPrimaryButtonEnabled = false;
                fields.IsEnabled = false;
                failure.Visibility = Visibility.Collapsed;
                try
                {
                    var (outcome, warning) = await draft.AddAsync(store);
                    if (outcome == KanbanNewTaskDraft.AddResult.Added) { added = true; created(warning); }
                    else
                    {
                        // A failed Add stays with every field as typed and says why.
                        e.Cancel = true;
                        if (draft.Failure is { } reason)
                        {
                            failure.Text = KanbanCopy.CouldNotAdd(reason);
                            failure.Visibility = Visibility.Visible;
                        }
                    }
                }
                catch (Exception ex)
                {
                    e.Cancel = true;
                    HermesHQ.Services.AppLog.Error("kanban", ex);
                }
                finally
                {
                    fields.IsEnabled = true;
                    dialog.IsPrimaryButtonEnabled = draft.CanAdd;
                    deferral.Complete();
                }
            };
            dialog.Closing += (d, e) =>
            {
                if (e.Result == ContentDialogResult.Primary && added) return;
                switch (draft.Close(pendingOther ? KanbanNewTaskDraft.CloseReason.OtherNumber : KanbanNewTaskDraft.CloseReason.Dismiss))
                {
                    case KanbanNewTaskDraft.CloseDecision.Hold:
                        e.Cancel = true;
                        pendingOther = false;
                        return;
                    case KanbanNewTaskDraft.CloseDecision.AskToDiscard:
                        askDiscard = true;
                        break;
                }
                (caret, selected) = (lastField.SelectionStart, lastField.SelectionLength);
            };
            dialog.Opened += (_, _) =>
            {
                lastField.Focus(FocusState.Programmatic);
                if (caret + selected <= lastField.Text.Length) lastField.Select(caret, selected);
            };
            var result = await ShowAsync(root, dialog);
            title.TextChanged -= Enable;
            if (dialog.Content is ScrollViewer holder) holder.Content = null;
            dialog.Content = null;
            if (added) return;
            if (pendingOther)
            {
                pendingOther = false;
                var text = (await PromptAsync(root, KanbanCopy.Priority, KanbanCopy.PriorityPrompt, priority.ToString(), KanbanCopy.Set, "0"))?.Trim();
                if (int.TryParse(text, out var value) && value >= 0) { priority = draft.Priority = value; priorityButton.Content = value == 0 ? KanbanCopy.None : value.ToString(); PriorityMenu(); }
                continue;
            }
            if (askDiscard)
            {
                askDiscard = false;
                // EditingGuard.askToDiscard: Keep Editing is the default for Return and Escape; only Discard Changes drops it.
                if (draft.ConfirmDiscard(await AskToDiscardAsync(root))) return;
                continue;
            }
            _ = result;
            return;
        }
    }

    /// "Discard Changes?" over New Task: Discard Changes, and Keep Editing as the default for Return and Escape.
    private static async Task<bool> AskToDiscardAsync(XamlRoot? root)
    {
        var ask = new ContentDialog
        {
            Title = KanbanNewTaskDraft.DiscardTitle, PrimaryButtonText = KanbanNewTaskDraft.DiscardConfirm,
            CloseButtonText = KanbanNewTaskDraft.DiscardKeep, DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(ask, "kanban.new.discard");
        return await ShowAsync(root, ask) == ContentDialogResult.Primary;
    }

    private static FrameworkElement Labeled(string label, FrameworkElement control, string help)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = Text(label, 14);
        l.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(l);
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(grid);
        stack.Children.Add(Text(help, 12, color: Secondary));
        return stack;
    }
}
