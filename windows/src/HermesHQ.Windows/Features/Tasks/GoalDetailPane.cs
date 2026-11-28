using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using HermesHQ.Features.QuickActions;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Goal detail side pane (`App/Pages/Goals/GoalPage.swift`, `GoalPlainView.swift`, `GoalOfferViews.swift`):
/// ring, inline title/why with `FlushUnsavedEdits` on unload, number reading + bot-source handoff warning, target date,
/// bots team picker + weekly check-in day/time picker, Where It Stands, Looks Done banner, 14-day stall card, full Goal
/// Offer cards (`Built on`, `Also sets`, expandable milestones/tasks, Accept/Decline/Undo/`Change It`), milestone CRUD
/// (rename, due date, reorder up/down, add task, delete), loose tasks, Goal Chat, Add to Favorites, and WebView2 Goal Page.
internal sealed class GoalDetailPane : UserControl
{
    private readonly TasksStore _store;
    private readonly string _goalId;
    private readonly TasksPage _page;
    private readonly StackPanel _body = new() { Spacing = 8, Padding = new Thickness(16, 4, 16, 24) };
    private readonly TextBlock _barTitle = Text(GoalsCopy.Goals, 14, bold: true, wrap: false);
    private readonly HashSet<string> _expandedOffers = [];
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
        menu.Opening += (_, _) => FillMoreMenu(menu);
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

        Unloaded += (_, _) => FlushUnsavedEdits();
        Render();
    }

    private bool Typing => new[] { _titleBox, _whyBox, _newMilestoneBox, _newTaskBox }.Any(b => b != null && b.FocusState != FocusState.Unfocused);

    /// Saves any unsaved inline title/why edits before closing, switching panes, or unloading.
    internal void FlushUnsavedEdits()
    {
        if (_store.FindGoal(_goalId) is not { } goal || _store.ReadOnlyGateway) return;
        var patch = new JsonObject();
        if (_titleBox != null)
        {
            var nextTitle = _titleBox.Text.Trim();
            if (nextTitle.Length > 0 && nextTitle != goal.Title) patch["title"] = nextTitle;
        }
        if (_whyBox != null)
        {
            var nextWhy = _whyBox.Text.Trim();
            if (nextWhy != goal.Why.Trim()) patch["why"] = nextWhy;
        }
        if (patch.Count > 0) _ = _store.PatchGoalAsync(goal.Id, patch);
    }

    private void FillMoreMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_store.FindGoal(_goalId) is not { } goal) return;

        if (_store.GoalPagesSupported || _store.PagesSupported || goal.PageAt != null)
            menu.Items.Add(MenuItem("Goal Page", "\uE8A5", () => _ = OpenGoalPageAsync(goal)));

        if (_store.GoalBotsSupported && goal.Lead != null)
            menu.Items.Add(MenuItem("Ask for an Update", "\uE8BD", () => AskForUpdate(goal)));

        if (_store.GoalBotsSupported && PageKit.Bots.Count > 0 && !_store.ReadOnlyGateway)
            menu.Items.Add(MenuItem(goal.Team.Count == 0 ? "Add Bots…" : "Bots…", "\uE716", () => _ = EditTeamAsync(goal)));

        menu.Items.Add(FavoritesPinAction.ForGoal(goal.Id, goal.Shown));

        if (!_store.ReadOnlyGateway)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            if (goal.State == GoalState.Active)
                menu.Items.Add(MenuItem("Pause", "\uE769", () => _ = SetStatusAsync(goal, "paused")));
            else if (goal.State == GoalState.Paused)
                menu.Items.Add(MenuItem("Resume", "\uE768", () => _ = SetStatusAsync(goal, "active")));
            else
                menu.Items.Add(MenuItem("Make Active Again", "\uE7A7", () => _ = SetStatusAsync(goal, "active")));

            if (goal.State != GoalState.Achieved)
                menu.Items.Add(MenuItem("Mark Achieved", "\uE73E", () => _ = SetStatusAsync(goal, "achieved")));
            if (goal.State != GoalState.LetGo)
                menu.Items.Add(MenuItem("Let It Go", "\uE711", () => _ = SetStatusAsync(goal, "let_go")));

            menu.Items.Add(new MenuFlyoutSeparator());
            var delete = MenuItem("Delete Goal…", "\uE74D", () => _ = ConfirmDeleteGoalAsync());
            delete.Foreground = Critical;
            menu.Items.Add(delete);
        }
    }

    private Task<bool> SetStatusAsync(Goal goal, string status) =>
        _store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = status, ["status_at"] = TodoDates.Now() });

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
            IsReadOnly = _store.ReadOnlyGateway,
        };
        AutomationProperties.SetName(titleBox, "Goal name");
        void SaveTitle()
        {
            var t = titleBox.Text.Trim();
            if (t.Length > 0 && t != goal.Title) _ = _store.PatchGoalAsync(goal.Id, new JsonObject { ["title"] = t });
        }
        titleBox.LostFocus += (_, _) => SaveTitle();
        titleBox.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; SaveTitle(); Focus(FocusState.Programmatic); } };
        headWords.Children.Add(titleBox);

        // AcceptsReturn MUST be set BEFORE Text on multiline TextBox (WinUI rule).
        var whyBox = _whyBox = new TextBox
        {
            AcceptsReturn = true,
            Text = goal.Why,
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            PlaceholderText = "Why it matters",
            BorderThickness = new Thickness(0),
            Background = Solid(Microsoft.UI.Colors.Transparent),
            Foreground = Secondary,
            IsReadOnly = _store.ReadOnlyGateway,
        };
        AutomationProperties.SetName(whyBox, "Why it matters");
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

        // Quick action chips: Status, Chat, Draft Plan, Goal Page
        var actionBar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 4, 0, 4) };
        actionBar.Children.Add(StatusMenuButton(goal));
        actionBar.Children.Add(Quiet("Goal Chat", () => OpenGoalChat(goal)));
        actionBar.Children.Add(Quiet("Draft Plan", () => AskBotForSetupPlan(goal)));
        if (_store.GoalPagesSupported || _store.PagesSupported || goal.PageAt != null)
            actionBar.Children.Add(Quiet("Goal Page", () => _ = OpenGoalPageAsync(goal)));
        _body.Children.Add(new ScrollViewer
        {
            Content = actionBar, HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled,
        });

        // Key rows: Number, Target Date, Team, Weekly Check-in
        var measureDisplay = goal.Measure is { } m
            ? GoalViews.MeasureWords(m, unit: true) + (GoalBots.SourceWords(m, now, BotName, Zone) is { } src ? $" · {src}" : "")
            : "Add a target number";
        _body.Children.Add(FieldRow("Number", measureDisplay, () => _ = EditMeasureAsync(goal)));

        _body.Children.Add(FieldRow("Target Date",
            goal.Due is { Length: >= 10 } d && TodoDates.Day(d[..10], Zone) is { } dt ? TodoWords.MonthDay(dt, now, Zone) : "No date",
            () => _ = EditDueDateAsync(goal)));

        _body.Children.Add(FieldRow("Team", GoalTeamPick.Summary(goal, BotName), () => _ = EditTeamAsync(goal)));

        if (_store.GoalBotsSupported && goal.Lead != null)
            _body.Children.Add(FieldRow("Check-in", GoalBots.ReviewWords(goal.Review), () => _ = EditReviewAsync(goal)));

        // Looks Done offer banner (`GoalBots.LooksDone`)
        if (GoalBots.LooksDone(goal) is { } doneOffer)
        {
            var stack = new StackPanel { Spacing = 6 };
            stack.Children.Add(Text(GoalBots.LooksDoneText(doneOffer, goal, BotName), 13, bold: true, color: Solid(Green)));
            var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            btns.Children.Add(Push(GoalBots.LooksDoneYes(doneOffer), () => _ = _store.AnswerGoalLooksDoneAsync(goal.Id, achieved: true), accent: true));
            btns.Children.Add(Quiet("Not Yet", () => _ = _store.AnswerGoalLooksDoneAsync(goal.Id, achieved: false)));
            stack.Children.Add(btns);
            _body.Children.Add(Card(stack, 10));
        }

        // 14-day Stall card
        if (GoalStall.IsStalled(goal, _store.Tasks, now))
        {
            var stack = new StackPanel { Spacing = 6 };
            stack.Children.Add(Text("Quiet Goal", 13, bold: true, color: Solid(Orange)));
            stack.Children.Add(Text(GoalStall.Message(goal, _store.Tasks, now), 13, color: Secondary));
            var btns = new TaskWrapPanel { HorizontalSpacing = 6, VerticalSpacing = 6 };
            btns.Children.Add(Push("Keep Going", () => _ = _store.KeepGoalGoingAsync(goal.Id)));
            btns.Children.Add(Quiet("Smaller Step", () => SuggestSmallerStep(goal)));
            btns.Children.Add(Quiet("Pause", () => _ = SetStatusAsync(goal, "paused")));
            var letGo = Quiet("Let Go", () => _ = SetStatusAsync(goal, "let_go"));
            letGo.Foreground = Critical;
            btns.Children.Add(letGo);
            stack.Children.Add(btns);
            _body.Children.Add(Card(stack, 10));
        }

        // Pending & Accepted (Undoable) Goal Offer cards (`GoalOffers.OnGoal`)
        foreach (var offer in GoalOffers.OnGoal(_store.Offers, goal.Id))
            _body.Children.Add(RenderGoalOfferCard(offer, goal, now));

        // Where It Stands / Check-in
        if (goal.Stands is { } stands)
        {
            var stack = new StackPanel { Spacing = 4 };
            var headRow = new Grid();
            headRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            headRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            headRow.Children.Add(Text("Where It Stands", 12, bold: true, color: Secondary));
            if (_store.GoalPagesSupported || _store.PagesSupported || goal.PageAt != null)
            {
                var pageLink = new HyperlinkButton { Content = "Goal Page ›", Padding = new Thickness(0), FontSize = 12 };
                pageLink.Click += (_, _) => _ = OpenGoalPageAsync(goal);
                Grid.SetColumn(pageLink, 1);
                headRow.Children.Add(pageLink);
            }
            stack.Children.Add(headRow);
            stack.Children.Add(Text(stands.Text, 13));
            if (!string.IsNullOrWhiteSpace(stands.Next))
                stack.Children.Add(Text("Next: " + stands.Next, 12, color: Accent));
            _body.Children.Add(Card(stack, 10));
        }
        else if (goal.Checkin is { } checkin && !string.IsNullOrWhiteSpace(checkin.Summary))
        {
            var stack = new StackPanel { Spacing = 4 };
            stack.Children.Add(Text($"Check-in from {BotName(checkin.By)}", 12, bold: true, color: Secondary));
            stack.Children.Add(Text(checkin.Summary, 13));
            _body.Children.Add(Card(stack, 10));
        }

        // Milestones & nested tasks
        _body.Children.Add(Header($"Milestones ({goal.Milestones.Count(m => m.Done)}/{goal.Milestones.Count})"));
        if (goal.Milestones.Count == 0 && GoalViews.TasksOf(goal, _store.Tasks).Count == 0 && _store.GoalBotsSupported && goal.Lead != null && GoalOffers.OnGoal(_store.Offers, goal.Id).Count == 0)
        {
            var emptyPlan = new StackPanel { Spacing = 6 };
            emptyPlan.Children.Add(Text("No plan yet", 13, bold: true));
            emptyPlan.Children.Add(Text($"{BotName(goal.Lead)} can break this goal into milestones and first tasks.", 12.5, color: Secondary));
            emptyPlan.Children.Add(Push($"Ask {BotName(goal.Lead)} for a Plan", () => AskBotForSetupPlan(goal), accent: true));
            _body.Children.Add(Card(emptyPlan, 10));
        }

        for (var i = 0; i < goal.Milestones.Count; i++)
        {
            var milestone = goal.Milestones[i];
            var idx = i;
            var msStack = new StackPanel { Spacing = 4 };
            var msTop = new Grid { ColumnSpacing = 6 };
            msTop.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            msTop.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            msTop.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var cb = new CheckBox { IsChecked = milestone.Done, Content = milestone.Title, MinWidth = 0, IsEnabled = !_store.ReadOnlyGateway };
            cb.Click += (_, _) => _ = _store.SetGoalMilestoneDoneAsync(goal.Id, milestone.Id, cb.IsChecked == true);
            msTop.Children.Add(cb);

            if (milestone.Due is { Length: >= 10 } md && TodoDates.Day(md[..10], Zone) is { } mdt)
            {
                var dueChip = Text(TodoWords.MonthDay(mdt, now, Zone), 11.5, color: Secondary, wrap: false);
                dueChip.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(dueChip, 1);
                msTop.Children.Add(dueChip);
            }

            if (!_store.ReadOnlyGateway)
            {
                var msMenu = new MenuFlyout();
                msMenu.Items.Add(MenuItem("Rename…", "\uE8AC", () => _ = PromptRenameMilestoneAsync(goal, milestone)));
                msMenu.Items.Add(MenuItem("Set Due Date…", "\uE787", () => _ = PromptMilestoneDateAsync(goal, milestone)));
                if (milestone.Due != null)
                    msMenu.Items.Add(MenuItem("Clear Due Date", "\uE711", () => _ = _store.EditGoalMilestoneAsync(goal.Id, milestone.Id, clearDue: true)));
                if (idx > 0)
                    msMenu.Items.Add(MenuItem("Move Up", "\uE74A", () => _ = _store.MoveGoalMilestoneAsync(goal.Id, milestone.Id, -1)));
                if (idx < goal.Milestones.Count - 1)
                    msMenu.Items.Add(MenuItem("Move Down", "\uE74B", () => _ = _store.MoveGoalMilestoneAsync(goal.Id, milestone.Id, 1)));
                msMenu.Items.Add(MenuItem("Add Task…", "\uE710", () => _ = NewTodoDialog.PresentAsync(XamlRoot, _store, null, null, _ => { }, initialGoal: goal.Id, initialMilestone: milestone.Id)));
                msMenu.Items.Add(new MenuFlyoutSeparator());
                var delMsItem = MenuItem("Delete Milestone…", "\uE74D", () => _ = ConfirmDeleteMilestoneAsync(goal, milestone));
                delMsItem.Foreground = Critical;
                msMenu.Items.Add(delMsItem);

                var msMore = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 12 }, Style = Style("QuietButtonStyle"), Flyout = msMenu };
                AutomationProperties.SetName(msMore, $"Milestone actions for {milestone.Title}");
                Grid.SetColumn(msMore, 2);
                msTop.Children.Add(msMore);
            }
            msStack.Children.Add(msTop);

            foreach (var task in GoalViews.TasksOf(goal, milestone.Id, _store.Tasks))
                msStack.Children.Add(NestedTaskRow(task));

            _body.Children.Add(Card(msStack, 8));
        }

        if (!_store.ReadOnlyGateway)
        {
            var addMs = _newMilestoneBox = new TextBox { PlaceholderText = "Add milestone… (Enter to save)" };
            AutomationProperties.SetName(addMs, "Add milestone");
            addMs.KeyDown += (_, e) =>
            {
                if (e.Key != VirtualKey.Enter || addMs.Text.Trim().Length == 0) return;
                e.Handled = true;
                var text = addMs.Text.Trim();
                addMs.Text = "";
                _ = _store.AddGoalMilestoneAsync(goal.Id, text);
            };
            _body.Children.Add(addMs);
        }

        // Loose tasks under this goal
        var loose = GoalViews.LooseTasks(goal, _store.Tasks);
        _body.Children.Add(Header($"Tasks ({loose.Count})"));
        foreach (var task in loose) _body.Children.Add(NestedTaskRow(task));

        if (!_store.ReadOnlyGateway)
        {
            var addTask = _newTaskBox = new TextBox { PlaceholderText = "Add task to this goal… (Enter to save)" };
            AutomationProperties.SetName(addTask, "Add task to this goal");
            addTask.KeyDown += (_, e) =>
            {
                if (e.Key != VirtualKey.Enter || addTask.Text.Trim().Length == 0) return;
                e.Handled = true;
                var fields = TodoWire.NewTask(addTask.Text.Trim(), TodoWho.Me, null, null, null, false, goal: goal.Id);
                addTask.Text = "";
                _ = _store.AddAsync(fields);
            };
            _body.Children.Add(addTask);
        }
    }

    /// Full Goal Offer card (`GoalOfferViews.swift`): Built on, Also sets, expandable milestones & tasks, buttons, Change It, Undo.
    private FrameworkElement RenderGoalOfferCard(TodoOffer offer, Goal goal, DateTimeOffset now)
    {
        var expanded = _expandedOffers.Contains(offer.Id);
        var added = offer.State == "accepted";
        var gone = offer.State is "undone" or "declined";
        var stack = new StackPanel { Spacing = 6 };

        if (offer.Kind == "checkin")
        {
            var kickerRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            kickerRow.Children.Add(Face(offer.Bot, 16));
            kickerRow.Children.Add(Text($"{BotName(offer.Bot)} · Check-in", 12, bold: true, color: Accent, wrap: false));
            stack.Children.Add(kickerRow);
        }

        stack.Children.Add(Text(TodoOfferRules.OfferTitle(offer, BotName), 14, bold: true));

        var desc = offer.Kind == "checkin" ? offer.Summary : (offer.Kind == "goal" ? offer.Why : offer.Summary);
        if (!string.IsNullOrWhiteSpace(desc)) stack.Children.Add(Text(desc, 13, color: Secondary));

        var builtOn = GoalOffers.BuiltOnLines(offer);
        if (builtOn.Count > 0)
        {
            stack.Children.Add(Text(GoalOffers.BuiltOnHeader.ToUpperInvariant(), 11, bold: true, color: Secondary));
            foreach (var line in builtOn) stack.Children.Add(Text("• " + line, 12, color: Secondary));
        }

        var setupRows = GoalOffers.SetupRows(offer, now, Zone);
        if (setupRows.Count > 0)
        {
            stack.Children.Add(Text(GoalOffers.SetupHeader.ToUpperInvariant(), 11, bold: true, color: Secondary));
            foreach (var row in setupRows)
            {
                var line = new Grid { ColumnSpacing = 8 };
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(60) });
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                line.Children.Add(Text(row.Label, 12, color: Secondary, wrap: false));
                var val = Text(row.Value, 12, color: gone ? Secondary : null);
                if (gone) val.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
                Grid.SetColumn(val, 1);
                line.Children.Add(val);
                stack.Children.Add(line);
            }
        }

        var milestones = offer.Milestones.Count > 0 ? offer.Milestones : (offer.Plan?.Milestones ?? []);
        if (milestones.Count > 0)
        {
            stack.Children.Add(Text(GoalOffers.MilestoneCount(milestones.Count).ToUpperInvariant(), 11, bold: true, color: Secondary));
            var shownMs = expanded ? milestones : [.. milestones.Take(3)];
            foreach (var ms in shownMs)
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var mark = added ? "+ " : "◦ ";
                var t = Text(mark + ms.Title, 12, color: gone ? Secondary : null);
                if (gone) t.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
                row.Children.Add(t);
                if (ms.Due is { Length: >= 10 } d && TodoDates.Day(d[..10], Zone) is { } dt)
                {
                    var dueLabel = Text(TodoWords.MonthDay(dt, now, Zone), 11.5, color: Secondary, wrap: false);
                    Grid.SetColumn(dueLabel, 1);
                    row.Children.Add(dueLabel);
                }
                stack.Children.Add(row);
            }
            if (!expanded && milestones.Count > 3)
            {
                var moreMs = new HyperlinkButton { Content = $"{milestones.Count - 3} more ›", Padding = new Thickness(0), FontSize = 12 };
                moreMs.Click += (_, _) => { _expandedOffers.Add(offer.Id); Render(); };
                stack.Children.Add(moreMs);
            }
        }

        var offerTasks = offer.Tasks.Count > 0 ? offer.Tasks : (offer.Plan?.Tasks ?? []);
        if (offerTasks.Count > 0)
        {
            var tasksHead = offer.Kind == "checkin" ? "THIS WEEK" : $"THIS WEEK · {TodoOfferRules.Count(offerTasks.Count).ToUpperInvariant()}";
            stack.Children.Add(Text(tasksHead, 11, bold: true, color: Secondary));
            var shownTasks = expanded ? offerTasks : [.. offerTasks.Take(3)];
            foreach (var t in shownTasks)
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var mark = added ? "+ " : "☐ ";
                var titleBlock = Text(mark + t.Title, 12, color: gone ? Secondary : null);
                if (gone) titleBlock.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
                row.Children.Add(titleBlock);
                var botId = t.BotFor(offer);
                var trail = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
                if (botId != null)
                {
                    trail.Children.Add(Face(botId, 14));
                    trail.Children.Add(Text(BotName(botId), 11.5, color: Secondary, wrap: false));
                }
                else
                {
                    var dueStr = t.Due is { Length: > 0 } raw && TodoDates.Due(raw, Zone) is { } dt ? " · " + TodoWords.Day(dt.Date, now, Zone) : "";
                    trail.Children.Add(Text("You" + dueStr, 11.5, color: Secondary, wrap: false));
                }
                Grid.SetColumn(trail, 1);
                row.Children.Add(trail);
                stack.Children.Add(row);
            }
            if (!expanded && offerTasks.Count > 3)
            {
                var moreTasks = new HyperlinkButton { Content = $"{offerTasks.Count - 3} more ›", Padding = new Thickness(0), FontSize = 12 };
                moreTasks.Click += (_, _) => { _expandedOffers.Add(offer.Id); Render(); };
                stack.Children.Add(moreTasks);
            }
        }

        if (expanded && (milestones.Count > 3 || offerTasks.Count > 3))
        {
            var lessBtn = new HyperlinkButton { Content = "Show less", Padding = new Thickness(0), FontSize = 12 };
            lessBtn.Click += (_, _) => { _expandedOffers.Remove(offer.Id); Render(); };
            stack.Children.Add(lessBtn);
        }

        var buttons = new TaskWrapPanel { HorizontalSpacing = 8, VerticalSpacing = 6, Margin = new Thickness(0, 4, 0, 0) };
        foreach (var btn in GoalOffers.Buttons(offer))
        {
            var b = btn;
            var uiBtn = Push(b.Label, () => _ = _store.AnswerOfferAsync(offer.Id, b.Action, list: b.MakesList, plan: b.Plan, inGoal: b.InGoal), accent: b.Primary);
            uiBtn.IsEnabled = !_store.ReadOnlyGateway;
            if (b.Destructive && !b.Primary) uiBtn.Foreground = Critical;
            buttons.Children.Add(uiBtn);
        }
        if (offer.IsWaiting && goal.Lead != null)
            buttons.Children.Add(Quiet("Change It", () => OpenGoalChat(goal)));
        if (buttons.Children.Count > 0) stack.Children.Add(buttons);

        if (GoalOffers.Foot(offer, BotName) is { } foot)
            stack.Children.Add(Text(foot, 11, color: Tertiary));

        var card = Card(stack, 12);
        card.BorderBrush = Accent;
        AutomationProperties.SetAutomationId(card, "goal.offer-card." + offer.Kind);
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
            item.Click += (_, _) => _ = SetStatusAsync(goal, wire);
            menu.Items.Add(item);
        }
        AddChoice("Active", "active");
        AddChoice("Someday (Paused)", "paused");
        AddChoice("Achieved", "achieved");
        AddChoice("Let Go", "let_go");
        return new DropDownButton
        {
            Content = GoalViews.GroupTitle(goal.State switch
            {
                GoalState.Paused => GoalGroupKey.Someday,
                GoalState.Achieved => GoalGroupKey.Achieved,
                GoalState.LetGo => GoalGroupKey.LetGo,
                _ => GoalGroupKey.Active,
            }),
            Flyout = menu,
            IsEnabled = !_store.ReadOnlyGateway,
        };
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

    private void OpenGoalChat(Goal goal, string? prompt = null)
    {
        if (goal.Chat is { } chat)
        {
            Navigator.Go(new ChatDestination(chat.Profile, chat.SessionId, TaskChatLinks.GoalSessionTitle(goal), prompt ?? ""));
            return;
        }
        var planner = GoalBots.PickPlanner(goal, [.. PageKit.Bots.Select(b => b.Name)]);
        var bot = PageKit.Bots.FirstOrDefault(b => b.Name == planner) ?? PageKit.Bots.FirstOrDefault();
        if (bot == null) return;
        var text = prompt ?? TaskChatLinks.OutgoingGoalPrompt(goal);
        if (bot.Canonical?.OpenId is { Length: > 0 } cid)
            Navigator.Go(new ChatDestination(bot.Name, cid, TaskChatLinks.GoalSessionTitle(goal), text));
        else
            Navigator.Go(new BotChatDestination(bot));
    }

    private void AskBotForSetupPlan(Goal goal) => OpenGoalChat(goal, GoalBots.PlanRequest(goal));

    private void AskForUpdate(Goal goal) =>
        OpenGoalChat(goal, $"Give me a concise status update on my goal “{goal.Shown}” (goal id: {goal.Id}) and refresh Where It Stands.");

    private void SuggestSmallerStep(Goal goal)
    {
        if (goal.Lead != null && _store.GoalBotsSupported)
        {
            OpenGoalChat(goal, $"My goal “{goal.Shown}” (goal id: {goal.Id}) has been quiet for a while. Suggest one small, concrete first step I can do today.");
            return;
        }
        _newTaskBox?.Focus(FocusState.Programmatic);
    }

    /// Opens the Goal Page in WebView2 (`TaskPane.OpenHtmlInWebViewWindow`) instead of stripping HTML to plain text.
    private async Task OpenGoalPageAsync(Goal goal)
    {
        var names = PageKit.Bots.ToDictionary(b => b.Name, b => b.DisplayName, StringComparer.Ordinal);
        string? html = null;
        try { html = await _store.Api.GetGoalPageHtmlAsync(goal.Id, names); } catch (Exception) { }
        if (string.IsNullOrWhiteSpace(html))
        {
            var fallback = $"{goal.Shown}\n\n{goal.Why}\n\n{goal.Stands?.Text ?? GoalViews.Line(goal, _store.Tasks, DateTimeOffset.Now, Zone)}".Trim();
            html = TaskPane.WrapPlainAsHtml(goal.Shown, fallback);
        }
        else if (!html.Contains("<html", StringComparison.OrdinalIgnoreCase) && !html.Contains("<body", StringComparison.OrdinalIgnoreCase))
        {
            html = TaskPane.WrapPlainAsHtml(goal.Shown, html);
        }
        TaskPane.OpenHtmlInWebViewWindow($"goal-page:{goal.Id}", goal.Shown, html);
    }

    private async Task EditMeasureAsync(Goal goal)
    {
        if (_store.ReadOnlyGateway) return;
        var cur = goal.Measure;
        var takeOwnership = false;
        if (cur?.EffectiveSource is { Bot: { Length: > 0 } srcBot } src && _store.GoalBotsSupported)
        {
            var fromText = string.IsNullOrWhiteSpace(src.What) ? "" : $" from {src.What}";
            var msg = $"{BotName(srcBot)} reads this number{fromText}. If you set it yourself, {BotName(srcBot)} stops reading it.";
            if (!await ConfirmAsync(XamlRoot, "Set It Yourself?", msg, "Set It Myself")) return;
            takeOwnership = true;
        }

        var nowBox = new TextBox { Header = "Current number", Text = cur != null ? cur.Now.ToString(CultureInfo.InvariantCulture) : "0" };
        var startBox = new TextBox { Header = "Start", Text = cur != null ? cur.Start.ToString(CultureInfo.InvariantCulture) : "0" };
        var targetBox = new TextBox { Header = "Target", Text = cur != null ? cur.Target.ToString(CultureInfo.InvariantCulture) : "100" };
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
        if (!double.TryParse(nowBox.Text, CultureInfo.InvariantCulture, out var nowVal)) return;
        if (!double.TryParse(startBox.Text, CultureInfo.InvariantCulture, out var startVal)) startVal = 0;
        if (!double.TryParse(targetBox.Text, CultureInfo.InvariantCulture, out var targetVal)) return;

        var next = new GoalMeasure(unitBox.Text.Trim(), startVal, targetVal, nowVal)
        {
            At = TodoDates.Now(),
            Source = takeOwnership ? GoalSource.You : cur?.Source,
            History = cur?.History ?? [],
        };
        await _store.UpdateGoalMeasureAsync(goal.Id, next);
    }

    private async Task EditDueDateAsync(Goal goal)
    {
        if (_store.ReadOnlyGateway) return;
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
            await _store.PatchGoalAsync(goal.Id, new JsonObject { ["due"] = TodoViews.DayKey(TodoDates.LocalDay(picked, Zone)) });
    }

    /// Weekly check-in day & time picker (`GoalBots.Weekdays`, `GoalBots.ReviewTimes`, `GoalReview`).
    private async Task EditReviewAsync(Goal goal)
    {
        if (_store.ReadOnlyGateway) return;
        var dayBox = new ComboBox { Header = "Weekly Check-in Day", MinWidth = 240 };
        dayBox.Items.Add(new ComboBoxItem { Content = "Off", Tag = -1 });
        for (var i = 0; i < GoalBots.Weekdays.Count; i++)
            dayBox.Items.Add(new ComboBoxItem { Content = GoalBots.Weekdays[i] + "s", Tag = i });
        dayBox.SelectedIndex = goal.Review != null ? goal.Review.Day + 1 : 0;

        var timeBox = new ComboBox { Header = "Time", MinWidth = 240 };
        foreach (var t in GoalBots.ReviewTimes)
            timeBox.Items.Add(new ComboBoxItem { Content = GoalBots.Time(t), Tag = t });
        var curTime = goal.Review?.Time ?? "08:00";
        var tIdx = GoalBots.ReviewTimes.ToList().IndexOf(curTime);
        timeBox.SelectedIndex = tIdx >= 0 ? tIdx : 1;
        timeBox.IsEnabled = dayBox.SelectedIndex > 0;
        dayBox.SelectionChanged += (_, _) => timeBox.IsEnabled = dayBox.SelectedIndex > 0;

        var panel = new StackPanel { Spacing = 10, MinWidth = 280 };
        panel.Children.Add(Text("Your lead bot reviews progress and checks in with you on this schedule.", 12.5, color: Secondary));
        panel.Children.Add(dayBox);
        panel.Children.Add(timeBox);

        var dialog = new ContentDialog
        {
            Title = "Weekly Check-in",
            Content = panel,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;

        var day = (dayBox.SelectedItem as ComboBoxItem)?.Tag is int d ? d : -1;
        var time = (timeBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "08:00";
        var next = day >= 0 ? new GoalReview(day, time) : null;
        await _store.PatchGoalAsync(goal.Id, new JsonObject { ["review"] = next?.Wire() });
    }

    private async Task EditTeamAsync(Goal goal)
    {
        if (_store.ReadOnlyGateway) return;
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

        // Weekly check-in day & time inline in Team sheet as well
        var dayBox = new ComboBox { Header = "Weekly Check-in", MinWidth = 220 };
        dayBox.Items.Add(new ComboBoxItem { Content = "Off", Tag = -1 });
        for (var i = 0; i < GoalBots.Weekdays.Count; i++)
            dayBox.Items.Add(new ComboBoxItem { Content = GoalBots.Weekdays[i] + "s", Tag = i });
        dayBox.SelectedIndex = goal.Review != null ? goal.Review.Day + 1 : 0;

        var timeBox = new ComboBox { Header = "Check-in Time", MinWidth = 220 };
        foreach (var t in GoalBots.ReviewTimes)
            timeBox.Items.Add(new ComboBoxItem { Content = GoalBots.Time(t), Tag = t });
        var tIdx = GoalBots.ReviewTimes.ToList().IndexOf(goal.Review?.Time ?? "08:00");
        timeBox.SelectedIndex = tIdx >= 0 ? tIdx : 1;
        timeBox.IsEnabled = dayBox.SelectedIndex > 0;
        dayBox.SelectionChanged += (_, _) => timeBox.IsEnabled = dayBox.SelectedIndex > 0;

        var autoAdds = new ToggleSwitch { Header = "Let bots add tasks without asking", IsOn = goal.Adds == "auto", OnContent = "Automatic", OffContent = "Ask first" };
        var knownAll = new ToggleSwitch { Header = "Share goal context with all bots", IsOn = goal.KnownToAll, OnContent = "Shared", OffContent = "Team only" };

        var panel = new StackPanel { Spacing = 10, MinWidth = 340 };
        panel.Children.Add(leadBox);
        if (helperBoxes.Count > 0)
        {
            panel.Children.Add(Header("Helper Bots"));
            panel.Children.Add(helpersStack);
        }
        panel.Children.Add(dayBox);
        panel.Children.Add(timeBox);
        panel.Children.Add(autoAdds);
        panel.Children.Add(knownAll);

        var dialog = new ContentDialog
        {
            Title = "Goal Team",
            Content = new ScrollViewer { Content = panel, MaxHeight = 480 },
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;

        var lead = (leadBox.SelectedItem as ComboBoxItem)?.Tag as string;
        var helpers = helperBoxes.Where(x => x.Box.IsChecked == true).Select(x => x.Bot).ToList();
        var fields = GoalTeamPick.PatchFields(lead, helpers, autoAdds.IsOn ? "auto" : "ask", knownAll.IsOn);
        var pickedDay = (dayBox.SelectedItem as ComboBoxItem)?.Tag is int d ? d : -1;
        var pickedTime = (timeBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "08:00";
        fields["review"] = !string.IsNullOrEmpty(lead) && pickedDay >= 0 ? new GoalReview(pickedDay, pickedTime).Wire() : null;
        await _store.PatchGoalAsync(goal.Id, fields);
    }

    private async Task PromptRenameMilestoneAsync(Goal goal, GoalMilestone milestone)
    {
        var box = new TextBox { Text = milestone.Title, PlaceholderText = "Milestone name" };
        var dialog = new ContentDialog
        {
            Title = "Rename Milestone",
            Content = box,
            PrimaryButtonText = "Rename",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = box.Text.Trim().Length > 0,
        };
        box.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = box.Text.Trim().Length > 0;
        if (await ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;
        var clean = box.Text.Trim();
        if (clean.Length > 0 && clean != milestone.Title)
            await _store.EditGoalMilestoneAsync(goal.Id, milestone.Id, title: clean);
    }

    private async Task PromptMilestoneDateAsync(Goal goal, GoalMilestone milestone)
    {
        var picker = new CalendarDatePicker
        {
            Date = milestone.Due is { Length: >= 10 } raw && TodoDates.Day(raw[..10], Zone) is { } dt ? dt : DateTimeOffset.Now.AddDays(14),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var dialog = new ContentDialog
        {
            Title = "Milestone Date",
            Content = picker,
            PrimaryButtonText = "Set",
            SecondaryButtonText = milestone.Due != null ? "Clear Date" : "",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var res = await ShowAsync(XamlRoot, dialog);
        if (res == ContentDialogResult.Secondary)
        {
            await _store.EditGoalMilestoneAsync(goal.Id, milestone.Id, clearDue: true);
            return;
        }
        if (res == ContentDialogResult.Primary && picker.Date is { } picked)
            await _store.EditGoalMilestoneAsync(goal.Id, milestone.Id, due: TodoViews.DayKey(TodoDates.LocalDay(picked, Zone)));
    }

    private async Task ConfirmDeleteMilestoneAsync(Goal goal, GoalMilestone milestone)
    {
        if (!await ConfirmAsync(XamlRoot, $"Delete “{milestone.Title}”?", "Its tasks stay in this goal, under No Milestone.", "Delete Milestone")) return;
        await _store.DeleteGoalMilestoneAsync(goal.Id, milestone.Id);
    }

    private async Task ConfirmDeleteGoalAsync()
    {
        if (_store.FindGoal(_goalId) is not { } goal) return;
        if (!await ConfirmAsync(XamlRoot, $"Delete “{goal.Shown}”?", "Its tasks are kept, with no goal.", "Delete Goal")) return;
        _page.CloseTask();
        await _store.DeleteGoalAsync(goal.Id);
    }

    private static MenuFlyoutItem MenuItem(string text, string glyph, Action run)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += (_, _) => run();
        return item;
    }
}
