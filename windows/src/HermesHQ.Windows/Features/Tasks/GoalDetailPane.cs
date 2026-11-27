using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Goal detail side pane (`App/Pages/Goals/GoalPlainView.swift` + `GoalOfferViews.swift` port):
/// ring, inline title/why, number reading + update dialog, target date, bots team picker, Where It Stands,
/// 14-day stall card, pending Setup Plan & Check-in offer cards with Accept/Decline/Undo, milestones CRUD + nested tasks,
/// loose tasks, Goal Chat, and Goal Page preview.
internal sealed class GoalDetailPane : UserControl
{
    private readonly TasksStore _store;
    private readonly string _goalId;
    private readonly TasksPage _page;
    private readonly StackPanel _body = new() { Spacing = 8, Padding = new Thickness(16, 4, 16, 24) };
    private readonly TextBlock _barTitle = Text(GoalsCopy.Goals, 14, bold: true, wrap: false);
    private TextBox? _titleBox, _whyBox, _newMilestoneBox, _newTaskBox;
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.Local;

    public GoalDetailPane(TasksStore store, string goalId, TasksPage page)
    {
        _store = store;
        _goalId = goalId;
        _page = page;
        AutomationProperties.SetAutomationId(this, "tasks.goal-pane");

        var close = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 14 }, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(close, "Close Goal");
        close.Click += (_, _) => _page.CloseTask();

        var menu = new MenuFlyout();
        var delete = new MenuFlyoutItem { Text = "Delete Goal", Icon = new FontIcon { Glyph = "\uE74D" }, Foreground = Critical };
        delete.Click += (_, _) => _ = ConfirmDeleteGoalAsync();
        menu.Items.Add(delete);
        var more = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 14 }, Style = Style("QuietButtonStyle"), Flyout = menu };
        AutomationProperties.SetName(more, "Goal Actions");

        _barTitle.HorizontalAlignment = HorizontalAlignment.Center;
        _barTitle.VerticalAlignment = VerticalAlignment.Center;

        var bar = new Grid { Padding = new Thickness(8, 8, 8, 4) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(close);
        Grid.SetColumn(_barTitle, 1);
        bar.Children.Add(_barTitle);
        Grid.SetColumn(more, 2);
        bar.Children.Add(more);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        var scroll = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);
        Content = root;
        Render();
    }

    private bool Typing => new[] { _titleBox, _whyBox, _newMilestoneBox, _newTaskBox }.Any(b => b != null && b.FocusState != FocusState.Unfocused);

    public void Render()
    {
        if (Typing) return;
        _body.Children.Clear();
        if (_store.FindGoal(_goalId) is not { } goal)
        {
            _barTitle.Text = GoalsCopy.Goals;
            _body.Children.Add(Text("This goal was deleted.", 14, color: Secondary));
            return;
        }

        var now = DateTimeOffset.Now;
        var fraction = GoalViews.Fraction(goal, _store.Tasks);
        var pace = GoalViews.Pace(goal, _store.Tasks, now, Zone);
        var rgb = GoalTints.Rgb(goal.Tint);
        var tint = Rgb(rgb.R, rgb.G, rgb.B);
        _barTitle.Text = goal.State switch
        {
            GoalState.Paused => "Someday Goal",
            GoalState.Achieved => "Achieved Goal",
            GoalState.LetGo => "Let Go",
            _ => "Goal",
        };

        // Ring + editable title + why
        var head = new Grid { ColumnSpacing = 12 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var ring = new ProgressRing
        {
            IsIndeterminate = false, IsActive = true, Width = 38, Height = 38, Minimum = 0, Maximum = 100,
            Value = Math.Round((fraction ?? 0) * 100),
            Foreground = Solid(goal.State is GoalState.Paused or GoalState.LetGo ? Rgb(0x8E, 0x8E, 0x93) : tint),
            Background = Brush("ControlStrongStrokeColorDisabledBrush"),
            VerticalAlignment = VerticalAlignment.Top,
        };
        head.Children.Add(ring);

        var headWords = new StackPanel { Spacing = 4 };
        var titleBox = _titleBox = new TextBox
        {
            Text = goal.Title, FontSize = 19, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
            PlaceholderText = "Goal name", BorderThickness = new Thickness(0), Background = Solid(Microsoft.UI.Colors.Transparent),
        };
        void SaveTitle()
        {
            var t = titleBox.Text.Trim();
            if (t.Length > 0 && t != goal.Title) _ = _store.PatchGoalAsync(goal.Id, new JsonObject { ["title"] = t });
        }
        titleBox.LostFocus += (_, _) => SaveTitle();
        titleBox.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; SaveTitle(); Focus(FocusState.Programmatic); } };
        headWords.Children.Add(titleBox);

        var whyBox = _whyBox = new TextBox
        {
            Text = goal.Why, FontSize = 13, TextWrapping = TextWrapping.Wrap, PlaceholderText = "Why it matters",
            BorderThickness = new Thickness(0), Background = Solid(Microsoft.UI.Colors.Transparent), Foreground = Secondary,
        };
        void SaveWhy()
        {
            var w = whyBox.Text.Trim();
            if (w != goal.Why.Trim()) _ = _store.PatchGoalAsync(goal.Id, new JsonObject { ["why"] = w });
        }
        whyBox.LostFocus += (_, _) => SaveWhy();
        headWords.Children.Add(whyBox);

        var statusSummary = GoalViews.Line(goal, _store.Tasks, now, Zone) + (pace != null ? " · " + pace.Words : "");
        headWords.Children.Add(Text(statusSummary, 12, color: Secondary));

        Grid.SetColumn(headWords, 1);
        head.Children.Add(headWords);
        _body.Children.Add(head);

        // Quick action chips: Status, Chat, Setup Plan, Goal Page
        var actionBar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 4, 0, 4) };
        actionBar.Children.Add(StatusMenuButton(goal));
        actionBar.Children.Add(Quiet("Goal Chat", () => OpenGoalChat(goal)));
        actionBar.Children.Add(Quiet("Draft Plan", () => AskBotForSetupPlan(goal)));
        if (_store.PagesSupported || goal.PageAt != null)
            actionBar.Children.Add(Quiet("Goal Page", () => _ = OpenGoalPageAsync(goal)));
        _body.Children.Add(new ScrollViewer
        {
            Content = actionBar, HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled,
        });

        // Key rows: Number, Target Date, Bots Team
        _body.Children.Add(FieldRow("Number",
            goal.Measure is { } m ? GoalViews.MeasureWords(m, unit: true) : "Add a target number",
            () => _ = EditMeasureAsync(goal)));
        _body.Children.Add(FieldRow("Target Date",
            goal.Due is { Length: >= 10 } d && TodoDates.Day(d[..10], Zone) is { } dt ? TodoWords.MonthDay(dt, now, Zone) : "No date",
            () => _ = EditDueDateAsync(goal)));
        _body.Children.Add(FieldRow("Team",
            GoalTeamPick.Summary(goal, BotName),
            () => _ = EditTeamAsync(goal)));

        // Looks Done offer banner
        if (goal.Offer is { Kept: false } doneOffer && goal.State == GoalState.Active)
        {
            var stack = new StackPanel { Spacing = 6 };
            stack.Children.Add(Text($"{BotName(doneOffer.By)} thinks this goal looks achieved", 13, bold: true, color: Solid(Green)));
            if (!string.IsNullOrWhiteSpace(doneOffer.Text)) stack.Children.Add(Text(doneOffer.Text, 13));
            var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            btns.Children.Add(Push("Mark Achieved", () => _ = _store.AnswerGoalLooksDoneAsync(goal.Id, achieved: true), accent: true));
            btns.Children.Add(Quiet("Keep Going", () => _ = _store.AnswerGoalLooksDoneAsync(goal.Id, achieved: false)));
            stack.Children.Add(btns);
            _body.Children.Add(Card(stack, 10));
        }

        // 14-day Stall card
        if (GoalStall.IsStalled(goal, _store.Tasks, now))
        {
            var stack = new StackPanel { Spacing = 6 };
            stack.Children.Add(Text("Quiet Goal", 13, bold: true, color: Solid(Orange)));
            stack.Children.Add(Text(GoalStall.Message(goal, _store.Tasks, now), 13, color: Secondary));
            var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            btns.Children.Add(Push("Keep Going", () => _ = _store.KeepGoalGoingAsync(goal.Id)));
            btns.Children.Add(Quiet("Pause", () => _ = _store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = "paused", ["status_at"] = TodoDates.Now() })));
            var letGo = Quiet("Let Go", () => _ = _store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = "let_go", ["status_at"] = TodoDates.Now() }));
            letGo.Foreground = Critical;
            btns.Children.Add(letGo);
            stack.Children.Add(btns);
            _body.Children.Add(Card(stack, 10));
        }

        // Pending Setup Plan / Check-in Offers for this goal
        foreach (var offer in _store.Offers.Where(o => o.GoalId == goal.Id && (o.IsWaiting || o.Undoable)))
            _body.Children.Add(RenderGoalOfferCard(offer, now));

        // Where It Stands / Check-in
        if (goal.Stands is { } stands)
        {
            var stack = new StackPanel { Spacing = 4 };
            stack.Children.Add(Text("Where It Stands", 12, bold: true, color: Secondary));
            stack.Children.Add(Text(stands.Summary, 13));
            if (!string.IsNullOrWhiteSpace(stands.Next))
                stack.Children.Add(Text("Next: " + stands.Next, 12, color: Accent));
            _body.Children.Add(Card(stack, 10));
        }
        else if (goal.Checkin is { } checkin)
        {
            var stack = new StackPanel { Spacing = 4 };
            stack.Children.Add(Text($"Check-in from {BotName(checkin.By)}", 12, bold: true, color: Secondary));
            stack.Children.Add(Text(checkin.Summary, 13));
            _body.Children.Add(Card(stack, 10));
        }

        // Milestones & nested tasks
        _body.Children.Add(Header($"Milestones ({goal.Milestones.Count(m => m.Done)}/{goal.Milestones.Count})"));
        foreach (var ms in goal.Milestones)
        {
            var milestone = ms;
            var msStack = new StackPanel { Spacing = 4 };
            var msTop = new Grid { ColumnSpacing = 8 };
            msTop.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            msTop.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var cb = new CheckBox { IsChecked = milestone.Done, Content = milestone.Title, MinWidth = 0 };
            cb.Click += (_, _) => _ = _store.SetGoalMilestoneDoneAsync(goal.Id, milestone.Id, cb.IsChecked == true);
            msTop.Children.Add(cb);

            var delMs = new Button { Content = new FontIcon { Glyph = "\uE74D", FontSize = 12 }, Style = Style("QuietButtonStyle") };
            AutomationProperties.SetName(delMs, "Delete Milestone");
            delMs.Click += (_, _) => _ = _store.DeleteGoalMilestoneAsync(goal.Id, milestone.Id);
            Grid.SetColumn(delMs, 1);
            msTop.Children.Add(delMs);
            msStack.Children.Add(msTop);

            foreach (var task in GoalViews.TasksOf(goal, milestone.Id, _store.Tasks))
                msStack.Children.Add(NestedTaskRow(task));

            _body.Children.Add(Card(msStack, 8));
        }

        var addMs = _newMilestoneBox = new TextBox { PlaceholderText = "Add milestone… (Enter to save)" };
        addMs.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter || addMs.Text.Trim().Length == 0) return;
            e.Handled = true;
            var text = addMs.Text.Trim();
            addMs.Text = "";
            _ = _store.AddGoalMilestoneAsync(goal.Id, text);
        };
        _body.Children.Add(addMs);

        // Loose tasks under this goal
        var loose = GoalViews.LooseTasks(goal, _store.Tasks);
        _body.Children.Add(Header($"Tasks ({loose.Count})"));
        foreach (var task in loose) _body.Children.Add(NestedTaskRow(task));

        var addTask = _newTaskBox = new TextBox { PlaceholderText = "Add task to this goal… (Enter to save)" };
        addTask.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter || addTask.Text.Trim().Length == 0) return;
            e.Handled = true;
            var fields = TodoWire.NewTask(addTask.Text.Trim(), TodoWho.Me, null, null, null, false);
            fields["goal"] = goal.Id;
            addTask.Text = "";
            _ = _store.AddAsync(fields);
        };
        _body.Children.Add(addTask);
    }

    private FrameworkElement RenderGoalOfferCard(TodoOffer offer, DateTimeOffset now)
    {
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(Text(TodoOfferRules.OfferTitle(offer, BotName), 14, bold: true));
        if (!string.IsNullOrWhiteSpace(offer.Summary)) stack.Children.Add(Text(offer.Summary, 13, color: Secondary));

        var builtOn = GoalOffers.BuiltOnLines(offer);
        if (builtOn.Count > 0)
        {
            stack.Children.Add(Text("Built on:", 12, bold: true, color: Secondary));
            foreach (var line in builtOn) stack.Children.Add(Text("• " + line, 12, color: Secondary));
        }

        if (offer.Plan is { } plan)
        {
            foreach (var row in GoalOffers.SetupRows(plan, now, Zone))
                stack.Children.Add(Text($"{row.Label}: {row.Value}", 12));
            if (plan.Milestones.Count > 0)
            {
                stack.Children.Add(Text("Milestones:", 12, bold: true, color: Secondary));
                foreach (var ms in plan.Milestones) stack.Children.Add(Text("◦ " + ms.Title, 12));
            }
            if (plan.Tasks.Count > 0)
            {
                stack.Children.Add(Text("First tasks:", 12, bold: true, color: Secondary));
                foreach (var t in plan.Tasks) stack.Children.Add(Text("☐ " + t.Title, 12));
            }
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
        foreach (var btn in GoalOffers.Buttons(offer))
        {
            var b = btn;
            var uiBtn = Push(b.Label, () => _ = _store.AnswerOfferAsync(offer.Id, b.Action), accent: b.Primary);
            if (b.Destructive && !b.Primary) uiBtn.Foreground = Critical;
            buttons.Children.Add(uiBtn);
        }
        if (buttons.Children.Count > 0) stack.Children.Add(buttons);
        if (GoalOffers.Foot(offer, BotName) is { } foot) stack.Children.Add(Text(foot, 11, color: Tertiary));

        var card = Card(stack, 12);
        card.BorderBrush = Accent;
        return card;
    }

    private FrameworkElement NestedTaskRow(TodoTask task)
    {
        var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(4, 3, 4, 3) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(TasksPage.Circle(task, () => _page.ToggleDone(task)));
        var title = Text(task.Title.Length == 0 ? TasksCopy.Untitled : task.Title, 13, color: task.IsDone ? Secondary : null, wrap: false);
        title.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(title, 1);
        row.Children.Add(title);
        var box = new Border { Child = row, CornerRadius = new CornerRadius(6) };
        box.Tapped += (_, _) => _page.OpenTask(task.Id);
        return box;
    }

    private DropDownButton StatusMenuButton(Goal goal)
    {
        var menu = new MenuFlyout();
        void AddChoice(string title, string wire)
        {
            var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = goal.Status == wire };
            item.Click += (_, _) => _ = _store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = wire, ["status_at"] = TodoDates.Now() });
            menu.Items.Add(item);
        }
        AddChoice("Active", "active");
        AddChoice("Someday (Paused)", "paused");
        AddChoice("Achieved", "achieved");
        AddChoice("Let Go", "let_go");
        return new DropDownButton { Content = GoalViews.GroupTitle(goal.State switch { GoalState.Paused => GoalGroupKey.Someday, GoalState.Achieved => GoalGroupKey.Achieved, GoalState.LetGo => GoalGroupKey.LetGo, _ => GoalGroupKey.Active }), Flyout = menu };
    }

    private static FrameworkElement FieldRow(string label, string value, Action onClick)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(88) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var l = Text(label, 12, color: Secondary);
        l.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(l);
        var btn = Quiet(value, onClick);
        btn.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetColumn(btn, 1);
        grid.Children.Add(btn);
        return grid;
    }

    private void OpenGoalChat(Goal goal)
    {
        if (goal.Chat is { } chat)
        {
            Navigator.Go(new ChatDestination(chat.Profile, chat.SessionId, TaskChatLinks.GoalSessionTitle(goal)));
            return;
        }
        var planner = GoalBots.PickPlanner(goal, [.. PageKit.Bots.Select(b => b.Name)]);
        var bot = PageKit.Bots.FirstOrDefault(b => b.Name == planner) ?? PageKit.Bots.FirstOrDefault();
        if (bot == null) return;
        if (bot.Canonical?.OpenId is { Length: > 0 } cid)
            Navigator.Go(new ChatDestination(bot.Name, cid, TaskChatLinks.GoalSessionTitle(goal), TaskChatLinks.OutgoingGoalPrompt(goal)));
        else
            Navigator.Go(new BotChatDestination(bot));
    }

    private void AskBotForSetupPlan(Goal goal)
    {
        var planner = GoalBots.PickPlanner(goal, [.. PageKit.Bots.Select(b => b.Name)]);
        var bot = PageKit.Bots.FirstOrDefault(b => b.Name == planner) ?? PageKit.Bots.FirstOrDefault();
        if (bot == null) return;
        var prompt = GoalBots.PlanRequest(goal);
        if (goal.Chat is { } chat)
            Navigator.Go(new ChatDestination(chat.Profile, chat.SessionId, TaskChatLinks.GoalSessionTitle(goal), prompt));
        else if (bot.Canonical?.OpenId is { Length: > 0 } cid)
            Navigator.Go(new ChatDestination(bot.Name, cid, TaskChatLinks.GoalSessionTitle(goal), prompt));
        else
            Navigator.Go(new BotChatDestination(bot));
    }

    private async Task OpenGoalPageAsync(Goal goal)
    {
        string? content = null;
        try { content = await _store.Api.GetGoalPageHtmlAsync(goal.Id); } catch (Exception) { }
        var shown = !string.IsNullOrWhiteSpace(content)
            ? TaskPane.StripHtmlToText(content!)
            : $"{goal.Shown}\n\n{goal.Why}\n\n{goal.Stands?.Summary ?? GoalViews.Line(goal, _store.Tasks, DateTimeOffset.Now, Zone)}";
        var dialog = new ContentDialog
        {
            Title = goal.Shown,
            Content = new ScrollViewer { Content = Text(shown, 13), MaxHeight = 480 },
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        await ShowAsync(XamlRoot, dialog);
    }

    private async Task EditMeasureAsync(Goal goal)
    {
        var cur = goal.Measure;
        var nowBox = new TextBox { Header = "Current number", Text = cur != null ? cur.Now.ToString(System.Globalization.CultureInfo.InvariantCulture) : "0" };
        var startBox = new TextBox { Header = "Start", Text = cur != null ? cur.Start.ToString(System.Globalization.CultureInfo.InvariantCulture) : "0" };
        var targetBox = new TextBox { Header = "Target", Text = cur != null ? cur.Target.ToString(System.Globalization.CultureInfo.InvariantCulture) : "100" };
        var unitBox = new TextBox { Header = "Unit (optional, e.g. testers, $)", Text = cur?.Unit ?? "" };
        var panel = new StackPanel { Spacing = 8, MinWidth = 320 };
        panel.Children.Add(nowBox);
        panel.Children.Add(targetBox);
        panel.Children.Add(startBox);
        panel.Children.Add(unitBox);

        var dialog = new ContentDialog
        {
            Title = "Goal Number",
            Content = panel,
            PrimaryButtonText = "Save",
            SecondaryButtonText = cur != null ? "Remove Number" : "",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var res = await ShowAsync(XamlRoot, dialog);
        if (res == ContentDialogResult.Secondary)
        {
            await _store.UpdateGoalMeasureAsync(goal.Id, null);
            return;
        }
        if (res != ContentDialogResult.Primary) return;
        if (!double.TryParse(nowBox.Text, System.Globalization.CultureInfo.InvariantCulture, out var nowVal)) return;
        if (!double.TryParse(startBox.Text, System.Globalization.CultureInfo.InvariantCulture, out var startVal)) startVal = 0;
        if (!double.TryParse(targetBox.Text, System.Globalization.CultureInfo.InvariantCulture, out var targetVal)) return;

        var next = new GoalMeasure(unitBox.Text.Trim(), startVal, targetVal, nowVal)
        {
            At = TodoDates.Now(),
            Source = cur?.Source,
            History = cur?.History ?? [],
        };
        await _store.UpdateGoalMeasureAsync(goal.Id, next);
    }

    private async Task EditDueDateAsync(Goal goal)
    {
        var picker = new CalendarDatePicker
        {
            Date = goal.Due is { Length: >= 10 } raw && TodoDates.Day(raw[..10], Zone) is { } dt ? dt : DateTimeOffset.Now.AddMonths(1),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var dialog = new ContentDialog
        {
            Title = "Target Date",
            Content = picker,
            PrimaryButtonText = "Set",
            SecondaryButtonText = goal.Due != null ? "Clear Date" : "",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var res = await ShowAsync(XamlRoot, dialog);
        if (res == ContentDialogResult.Secondary)
        {
            await _store.PatchGoalAsync(goal.Id, new JsonObject { ["due"] = null });
            return;
        }
        if (res == ContentDialogResult.Primary && picker.Date is { } picked)
            await _store.PatchGoalAsync(goal.Id, new JsonObject { ["due"] = TodoDates.Wire(picked, hasTime: false, Zone) });
    }

    private async Task EditTeamAsync(Goal goal)
    {
        var leadBox = new ComboBox { Header = "Lead Bot", MinWidth = 220 };
        leadBox.Items.Add(new ComboBoxItem { Content = "Just Me (no lead bot)", Tag = "" });
        foreach (var b in PageKit.Bots) leadBox.Items.Add(new ComboBoxItem { Content = b.DisplayName, Tag = b.Name });
        var leadIdx = leadBox.Items.OfType<ComboBoxItem>().ToList().FindIndex(i => (i.Tag as string) == (goal.Lead ?? ""));
        leadBox.SelectedIndex = leadIdx >= 0 ? leadIdx : 0;

        var helpersStack = new StackPanel { Spacing = 4 };
        var helperBoxes = new List<(string Bot, CheckBox Box)>();
        foreach (var b in PageKit.Bots)
        {
            var cb = new CheckBox { Content = b.DisplayName, IsChecked = goal.Helpers.Contains(b.Name) };
            helperBoxes.Add((b.Name, cb));
            helpersStack.Children.Add(cb);
        }

        var autoAdds = new ToggleSwitch { Header = "Let bots add tasks without asking", IsOn = goal.Adds == "auto", OnContent = "Automatic", OffContent = "Ask first" };
        var knownAll = new ToggleSwitch { Header = "Share goal context with all bots", IsOn = goal.KnownToAll, OnContent = "Shared", OffContent = "Team only" };

        var panel = new StackPanel { Spacing = 10, MinWidth = 340 };
        panel.Children.Add(leadBox);
        if (helperBoxes.Count > 0)
        {
            panel.Children.Add(Header("Helper Bots"));
            panel.Children.Add(helpersStack);
        }
        panel.Children.Add(autoAdds);
        panel.Children.Add(knownAll);

        var dialog = new ContentDialog
        {
            Title = "Goal Team",
            Content = new ScrollViewer { Content = panel, MaxHeight = 460 },
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;

        var lead = (leadBox.SelectedItem as ComboBoxItem)?.Tag as string;
        var helpers = helperBoxes.Where(x => x.Box.IsChecked == true).Select(x => x.Bot).ToList();
        var fields = GoalTeamPick.PatchFields(lead, helpers, autoAdds.IsOn ? "auto" : "ask", knownAll.IsOn);
        await _store.PatchGoalAsync(goal.Id, fields);
    }

    private async Task ConfirmDeleteGoalAsync()
    {
        if (_store.FindGoal(_goalId) is not { } goal) return;
        if (!await ConfirmAsync(XamlRoot, $"Delete “{goal.Shown}”?", "Its tasks are kept, with no goal.", "Delete Goal")) return;
        _page.CloseTask();
        await _store.DeleteGoalAsync(goal.Id);
    }
}
