using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Gateways;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using HermesHQ.Features.QuickActions;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// [WIN-42] + Wave 5A Tasks › Goals (`App/Pages/Goals/NewGoalSheet.swift`, `GoalsListViews.swift`, `GoalShelfViews.swift`):
/// - Goals view: Active cards with team faces, waiting indicator, context menu (incl. Add to Favorites), Someday, folded
///   Achieved and Let Go headings, and "+ New Goal";
/// - Today's Goals shelf over Today's rows with Favorites context menu;
/// - Full New Goal dialog: NL date parsing via `TodoQuickParse(..., goal: true)`, Date & Number chips (using flyouts
///   rather than nested dialogs), `Who's helping?` bot chips remembered across uses, and auto-opening the goal chat
///   with a plan request when a lead bot is selected.
public sealed partial class TasksPage
{
    private const string LastGoalTeamKey = "HQGoalLastTeam";

    /// Achieved and Let Go opened from their fold (the page's own, as the Mac's `goalFoldsOpen`: never saved).
    private readonly HashSet<GoalGroupKey> _goalFoldsOpen = [];
    private static readonly IKeyValueStore GoalsPrefs = new JsonFileStore(System.IO.Path.Combine(AppPaths.Root, "tasks-goals.json"));
    private static readonly GoalShelfFold ShelfFold = new(GoalsPrefs);

    /// The Goals view, in place of a view's task groups.
    private void RenderGoals(TasksStore store, DateTimeOffset now)
    {
        var groups = GoalViews.Groups(store.Goals);
        if (groups.IsEmpty)
        {
            var empty = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(24, 48, 24, 24), MaxWidth = 460 };
            var words = Text(GoalViews.EmptyText, 14, color: Secondary);
            words.TextAlignment = TextAlignment.Center;
            AutomationProperties.SetAutomationId(words, GoalsCopy.EmptyId);
            empty.Children.Add(words);
            var add = Push(GoalsCopy.NewGoal, NewGoal, accent: true);
            add.HorizontalAlignment = HorizontalAlignment.Center;
            add.IsEnabled = !store.ReadOnlyGateway;
            AutomationProperties.SetAutomationId(add, GoalsCopy.EmptyNewId);
            empty.Children.Add(add);
            _list.Children.Add(empty);
            return;
        }
        foreach (var (key, goals) in groups.All())
        {
            if (goals.Count == 0) continue;
            var open = !GoalViews.Folds(key) || _goalFoldsOpen.Contains(key);
            if (GoalViews.HasHeading(key)) _list.Children.Add(GoalGroupHeading(key, goals.Count, open));
            if (!open) continue;
            foreach (var goal in goals) _list.Children.Add(GoalCardView(GoalCardModel.Make(goal, store.Tasks, now, Zone), store));
        }
        _list.Children.Add(NewGoalRow());
    }

    /// "Someday 1", "Achieved 1 … Show" (TasksViewController.configureGoalHeader): the name, its count in grey, the fold.
    private FrameworkElement GoalGroupHeading(GoalGroupKey key, int count, bool open)
    {
        var title = GoalViews.GroupTitle(key);
        var head = new TextBlock { FontSize = 15, VerticalAlignment = VerticalAlignment.Center };
        head.Inlines.Add(new Run { Text = title, FontWeight = FontWeights.SemiBold });
        head.Inlines.Add(new Run { Text = "  " + count, Foreground = Secondary });
        AutomationProperties.SetHeadingLevel(head, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        var row = new Grid { Margin = new Thickness(6, 16, 8, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(head);
        AutomationProperties.SetAutomationId(row, TodoViews.SectionAutomationId(title));
        if (GoalViews.FoldWord(key, open) is { } word)
        {
            var toggle = new HyperlinkButton { Content = word, Padding = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAutomationId(toggle, GoalViews.FoldId(key));
            AutomationProperties.SetName(toggle, $"{word} {title}");
            toggle.Click += (_, _) =>
            {
                if (!_goalFoldsOpen.Remove(key)) _goalFoldsOpen.Add(key);
                Render();
            };
            Grid.SetColumn(toggle, 1);
            row.Children.Add(toggle);
        }
        return row;
    }

    private static Color Tint(string name) => GoalTints.Rgb(name) is var (r, g, b) ? Rgb(r, g, b) : Blue;

    /// The ring: how far the goal has come, in its colour (grey when paused or let go); empty with no plan.
    private static FrameworkElement Ring(double? fraction, Color color, double size)
    {
        var ring = new ProgressRing
        {
            IsIndeterminate = false, IsActive = true, Width = size, Height = size, Minimum = 0, Maximum = 100,
            Value = Math.Round((fraction ?? 0) * 100), Foreground = Solid(color), Background = Brush("ControlStrongStrokeColorDisabledBrush"),
            VerticalAlignment = VerticalAlignment.Top,
        };
        AutomationProperties.SetAccessibilityView(ring, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return ring;
    }

    /// One goal as a card (GoalCard): the ring, the name, team avatars + waiting dot, one grey line with the pace after
    /// it, and under a hairline the goal's next task with its circle.
    private FrameworkElement GoalCardView(GoalCardModel card, TasksStore store)
    {
        var goal = store.FindGoal(card.Id);
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Ring(card.Fraction, card.GreyRing ? Rgb(0x8E, 0x8E, 0x93) : Tint(card.Color), 34));

        var words = new StackPanel { Spacing = 2 };
        var titleRow = new Grid { ColumnSpacing = 8 };
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleRow.Children.Add(Text(card.Title, 16, bold: true, color: card.Quiet ? Secondary : null, wrap: false));

        if (goal != null)
        {
            var badges = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            if (GoalBots.WaitsForYou(goal, store.Offers))
            {
                var dot = new Ellipse { Width = 8, Height = 8, Fill = Solid(Orange), VerticalAlignment = VerticalAlignment.Center };
                ToolTipService.SetToolTip(dot, "Needs your attention");
                badges.Children.Add(dot);
            }
            foreach (var member in goal.Team.Take(3))
                badges.Children.Add(Face(member, 18));
            if (badges.Children.Count > 0)
            {
                Grid.SetColumn(badges, 1);
                titleRow.Children.Add(badges);
            }
        }
        words.Children.Add(titleRow);

        var line = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis };
        line.Inlines.Add(new Run { Text = card.Line, Foreground = Secondary });
        if (card.Pace is { } pace)
        {
            line.Inlines.Add(new Run { Text = " · ", Foreground = Secondary });
            line.Inlines.Add(new Run
            {
                Text = pace.Words,
                Foreground = pace.Tone switch { GoalPaceTone.Late => Brush("HQRedBrush"), GoalPaceTone.Behind => Solid(Orange), _ => Solid(Green) },
            });
        }
        words.Children.Add(line);
        if (card.NextId is { } nextId && store.Find(nextId) is { } next)
        {
            words.Children.Add(new Rectangle { Height = 1, Fill = Brush("DividerStrokeColorDefaultBrush"), Margin = new Thickness(0, 8, 0, 6) });
            var nextRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var circle = Circle(next, () => ToggleDone(next));
            AutomationProperties.SetAutomationId(circle, GoalsCopy.TickId);
            AutomationProperties.SetName(circle, GoalsCopy.MarkDone(card.NextTitle ?? ""));
            nextRow.Children.Add(circle);
            var title = Text(card.NextTitle is { Length: > 0 } t ? t : TasksCopy.Untitled, 14, wrap: false);
            title.VerticalAlignment = VerticalAlignment.Center;
            nextRow.Children.Add(title);
            words.Children.Add(nextRow);
        }
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var box = Card(grid, 14);
        box.Margin = new Thickness(0, 4, 0, 4);
        if (_selectedGoal == card.Id) box.BorderBrush = Accent;
        if (card.Quiet) box.Opacity = 0.8;
        AutomationProperties.SetName(box, card.Spoken);
        AutomationProperties.SetItemStatus(box, card.RingWords);
        AutomationProperties.SetAutomationId(box, card.AutomationId);
        if (goal != null) box.ContextFlyout = GoalContextMenu(store, goal);
        box.Tapped += (_, _) => OpenGoal(card.Id);
        return box;
    }

    private MenuFlyout GoalContextMenu(TasksStore store, Goal goal)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item("Open Goal", "\uE8A7", () => OpenGoal(goal.Id)));
        menu.Items.Add(FavoritesPinAction.ForGoal(goal.Id, goal.Shown));
        if (!store.ReadOnlyGateway)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            if (goal.State == GoalState.Active)
                menu.Items.Add(Item("Pause", "\uE769", () => _ = store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = "paused", ["status_at"] = TodoDates.Now() })));
            else if (goal.State == GoalState.Paused)
                menu.Items.Add(Item("Resume", "\uE768", () => _ = store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = "active", ["status_at"] = TodoDates.Now() })));
            else
                menu.Items.Add(Item("Make Active Again", "\uE7A7", () => _ = store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = "active", ["status_at"] = TodoDates.Now() })));

            if (goal.State != GoalState.Achieved)
                menu.Items.Add(Item("Mark Achieved", "\uE73E", () => _ = store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = "achieved", ["status_at"] = TodoDates.Now() })));
            if (goal.State != GoalState.LetGo)
                menu.Items.Add(Item("Let It Go", "\uE711", () => _ = store.PatchGoalAsync(goal.Id, new JsonObject { ["status"] = "let_go", ["status_at"] = TodoDates.Now() })));

            menu.Items.Add(new MenuFlyoutSeparator());
            var delete = Item("Delete Goal…", "\uE74D", () => _ = ConfirmDeleteGoalCardAsync(store, goal));
            delete.Foreground = Critical;
            menu.Items.Add(delete);
        }
        return menu;
    }

    private async Task ConfirmDeleteGoalCardAsync(TasksStore store, Goal goal)
    {
        if (!await ConfirmAsync(XamlRoot, $"Delete “{goal.Shown}”?", "Its tasks are kept, with no goal.", "Delete Goal")) return;
        if (_selectedGoal == goal.Id) CloseTask();
        await store.DeleteGoalAsync(goal.Id);
    }

    // ------------------------------------------------------------------ [WIN-47] follow-ups

    /// Asked the add-on to update from the Goals view's state ("Updating…" until the list is read again).
    private bool _goalsUpdateAsked;

    /// [WIN-47] A search's "Goals" group, over its To Do and Done (TasksViewController.appendFoundGoals): the goals whose
    /// name or why holds the words, any status, drawn as the Goals view draws them. True when it added the group.
    private bool RenderFoundGoals(TasksStore store, DateTimeOffset now)
    {
        if (!GoalViews.FindsGoals(store.GoalsSupported, "all")) return false;
        var found = GoalViews.Found(store.Goals, _query);
        if (found.Count == 0) return false;
        _list.Children.Add(GoalGroupHeading(GoalGroupKey.Found, found.Count, open: true));
        foreach (var goal in found) _list.Children.Add(GoalCardView(GoalCardModel.Make(goal, store.Tasks, now, Zone), store));
        return true;
    }

    /// [WIN-47] [goals-addon] Goals on an add-on from before Goals: "Goals Need a Newer Add-on", with Update Add-on
    /// (TasksViewController.updateEmptyState).
    private UIElement GoalsLockedState(TasksStore store)
    {
        var state = State("\uE7C1", GoalsAddOn.StateTitle, GoalsAddOn.StateText(HostWord.UpdateTarget),
            _goalsUpdateAsked ? GoalsAddOn.UpdatingButton : GoalsAddOn.UpdateButton, () => _ = UpdateGoalsAddOnAsync(store));
        AutomationProperties.SetAutomationId(state, GoalsAddOn.StateId);
        return state;
    }

    private async Task UpdateGoalsAddOnAsync(TasksStore store)
    {
        if (_goalsUpdateAsked) return;
        _goalsUpdateAsked = true;
        Render();
        try { await store.RefreshAsync(force: true); }
        finally { _goalsUpdateAsked = false; Render(); }
    }

    /// [WIN-47] The goal's mark on a task's row, in the list dot's place (TaskRowViews.swift `goalMark`): a small
    /// filled circle in a ring, in the goal's colour (grey once the task is done).
    private static FrameworkElement GoalMarkView(Goal goal, bool done)
    {
        var color = done ? Rgb(0x8E, 0x8E, 0x93) : Tint(goal.Tint);
        var mark = new Grid { Width = 12, Height = 12, VerticalAlignment = VerticalAlignment.Center };
        mark.Children.Add(new Ellipse { Width = 12, Height = 12, Stroke = Solid(color), StrokeThickness = 1.5 });
        mark.Children.Add(new Ellipse { Width = 5, Height = 5, Fill = Solid(color), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        AutomationProperties.SetAutomationId(mark, GoalViews.MarkId);
        AutomationProperties.SetName(mark, goal.Shown);
        ToolTipService.SetToolTip(mark, goal.Shown);
        return mark;
    }

    /// [WIN-47] "Add to Goal" on a row's menu, beside Move To (GoalShared.swift `GoalChoices.menu`).
    private MenuFlyoutSubItem? AddToGoalMenu(TasksStore store, TodoTask task)
    {
        if (GoalChoices.Menu(task, store.Goals, store.GoalsSupported) is not { } choices) return null;
        var menu = new MenuFlyoutSubItem { Text = GoalChoices.Title, Icon = new FontIcon { Glyph = "\uE91F" } };
        AutomationProperties.SetAutomationId(menu, GoalChoices.MenuId);
        foreach (var choice in choices) menu.Items.Add(GoalChoiceItem(store, task, choice));
        return menu;
    }

    private MenuFlyoutItemBase GoalChoiceItem(TasksStore store, TodoTask task, GoalChoice choice)
    {
        if (choice.Children.Count > 0)
        {
            var sub = new MenuFlyoutSubItem { Text = choice.Title, Icon = new FontIcon { Glyph = "\uE91F" } };
            foreach (var inner in choice.Children) sub.Items.Add(GoalChoiceItem(store, task, inner));
            return sub;
        }
        if (choice.Kind == GoalChoiceKind.OpenGoal)
        {
            return Item(choice.Title, "\uE8A7", () =>
            {
                if (choice.Goal is { } gid) OpenGoal(gid);
                else { _query = ""; _search.Text = ""; _view = TodoView.Goals; Render(); }
            });
        }
        if (choice.Kind == GoalChoiceKind.NoGoal)
            return Item(choice.Title, "\uE738", () => _ = SetGoalAsync(store, task.Id, null, null));
        var item = new ToggleMenuFlyoutItem { Text = choice.Title, IsChecked = choice.Ticked };
        if (choice.Kind == GoalChoiceKind.Goal) item.Icon = new FontIcon { Glyph = "\uE91F" };
        item.Click += (_, _) => _ = SetGoalAsync(store, task.Id, choice.Goal, choice.Milestone);
        return item;
    }

    private async Task SetGoalAsync(TasksStore store, string taskId, string? goal, string? milestone)
    {
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        await store.SetGoalAsync(taskId, goal, milestone);
    }

    /// "+ New Goal", the view's last row, in the accent colour (GoalNewRow).
    private FrameworkElement NewGoalRow()
    {
        var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        face.Children.Add(new FontIcon { Glyph = "\uE710", FontSize = 13, Foreground = Accent });
        face.Children.Add(new TextBlock { Text = GoalsCopy.NewGoal, FontSize = 15, Foreground = Accent });
        var row = new Button { Content = face, Style = Style("QuietButtonStyle"), Padding = new Thickness(10, 10, 10, 10), Margin = new Thickness(0, 4, 0, 0) };
        AutomationProperties.SetName(row, GoalsCopy.NewGoal);
        AutomationProperties.SetAutomationId(row, GoalsCopy.NewId);
        row.Click += (_, _) => NewGoal();
        return row;
    }

    /// Today's Goals shelf (GoalShelfView), over Today's rows.
    private FrameworkElement GoalShelfView(TasksStore store, DateTimeOffset now)
    {
        var cards = GoalShelf.Cards(store.Goals, store.Tasks, now, Zone);
        var folded = ShelfFold.Folded;
        var shelf = new StackPanel { Spacing = 6, Margin = new Thickness(0, 8, 0, 4) };
        AutomationProperties.SetAutomationId(shelf, GoalShelf.ShelfId);
        var top = new Grid { Margin = new Thickness(0, 0, 8, 0) };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new TextBlock { FontSize = 15 };
        words.Inlines.Add(new Run { Text = GoalsCopy.Goals, FontWeight = FontWeights.SemiBold });
        if (GoalShelf.HeadingCount(cards.Count, folded) is { } count) words.Inlines.Add(new Run { Text = "  " + count, Foreground = Secondary });
        var heading = new Button { Content = words, Style = Style("QuietButtonStyle"), Padding = new Thickness(6, 4, 6, 4) };
        AutomationProperties.SetName(heading, GoalsCopy.Goals);
        AutomationProperties.SetItemStatus(heading, GoalShelf.HeadingValue(cards.Count, folded));
        AutomationProperties.SetHelpText(heading, folded ? "Shows your goals" : "Folds your goals to this line");
        AutomationProperties.SetAutomationId(heading, GoalShelf.HeadingId);
        heading.Click += (_, _) => { ShelfFold.Folded = !ShelfFold.Folded; Render(); };
        top.Children.Add(heading);
        var all = new HyperlinkButton { Content = GoalShelf.AllWords(cards.Count) + " ›", VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(all, "All Goals");
        AutomationProperties.SetItemStatus(all, cards.Count.ToString(CultureInfo.InvariantCulture));
        AutomationProperties.SetHelpText(all, "Opens the Goals view");
        AutomationProperties.SetAutomationId(all, GoalShelf.AllId);
        all.Click += (_, _) => { _view = TodoView.Goals; Render(); };
        Grid.SetColumn(all, 1);
        top.Children.Add(all);
        shelf.Children.Add(top);
        if (folded) return shelf;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        AutomationProperties.SetAutomationId(row, "goals.shelf.cards");
        foreach (var card in cards)
        {
            var c = card;
            var view = ShelfCardView(c);
            if (store.FindGoal(c.Id) is { } goal) view.ContextFlyout = GoalContextMenu(store, goal);
            view.Tapped += (_, _) => OpenGoal(c.Id);
            row.Children.Add(view);
        }
        shelf.Children.Add(new ScrollViewer
        {
            Content = row, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(0, 0, 0, 6),
        });
        return shelf;
    }

    /// One small shelf card (GoalShelfCardView): the ring, the name, the grey line, and "Next: …".
    private static FrameworkElement ShelfCardView(GoalShelfCard card)
    {
        var stack = new StackPanel { Spacing = 4, Width = 280 };
        var top = new Grid { ColumnSpacing = 8 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.Children.Add(Ring(card.Fraction, Tint(card.Color), 22));
        var name = Text(card.Title, 14, bold: true, wrap: false);
        name.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(name, 1);
        top.Children.Add(name);
        stack.Children.Add(top);
        stack.Children.Add(Text(card.Line.Length == 0 ? " " : card.Line, 12, color: Secondary, wrap: false));
        var next = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis };
        if (card.NextId != null && card.Next.StartsWith("Next: ", StringComparison.Ordinal))
        {
            next.Inlines.Add(new Run { Text = "Next: ", Foreground = Secondary });
            next.Inlines.Add(new Run { Text = card.Next["Next: ".Length..] });
        }
        else next.Inlines.Add(new Run { Text = card.Next, Foreground = Secondary });
        AutomationProperties.SetName(next, card.Next);
        stack.Children.Add(next);
        var box = Card(stack, 12);
        AutomationProperties.SetName(box, card.Spoken);
        AutomationProperties.SetItemStatus(box, card.Fraction is { } f ? $"{(int)Math.Floor(f * 100)} percent" : "No plan yet");
        AutomationProperties.SetAutomationId(box, card.AutomationId);
        return box;
    }

    // ------------------------------------------------------------------ Full New Goal dialog (`NewGoalSheet.swift`)

    private static List<string> LoadRememberedGoalTeam(IReadOnlyList<string> availableBots)
    {
        var raw = GoalsPrefs.Get(LastGoalTeamKey);
        if (raw == null)
        {
            // First time: root bot leads (or first bot available), matching GoalPlanWith.start.
            var root = availableBots.FirstOrDefault(b => b == "default") ?? availableBots.FirstOrDefault();
            return root != null ? [root] : [];
        }
        if (raw.Length == 0) return [];
        var known = availableBots.ToHashSet(StringComparer.Ordinal);
        return [.. raw.Split(',', StringSplitOptions.RemoveEmptyEntries).Where(known.Contains).Distinct(StringComparer.Ordinal)];
    }

    private static void SaveRememberedGoalTeam(IReadOnlyList<string> team) =>
        GoalsPrefs.Set(LastGoalTeamKey, string.Join(",", team));

    private static string GoalTeamNote(IReadOnlyList<string> team, Func<string?, string> botName)
    {
        if (team.Count == 0) return "Just you on this goal. You can add bots later.";
        var lead = botName(team[0]);
        if (team.Count == 1) return $"{lead} will lead this goal and draft a setup plan with you.";
        var helpers = string.Join(", ", team.Skip(1).Select(b => botName(b)));
        return $"{lead} leads and drafts the plan; {helpers} helps.";
    }

    private void NewGoal()
    {
        if (_store is not { } store) return;
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        _ = NewGoalAsync(store);
    }

    private async Task NewGoalAsync(TasksStore store)
    {
        var bots = PageKit.Bots.ToList();
        var offersPlan = store.GoalBotsSupported && bots.Count > 0;
        var team = offersPlan ? LoadRememberedGoalTeam([.. bots.Select(b => b.Name)]) : new List<string>();
        var manualDue = false;
        var keepLiteral = false;
        DateTimeOffset? manualDate = null;
        GoalMeasure? measure = null;
        Goal? createdGoal = null;
        string? createdLead = null;

        var title = new TextBox { PlaceholderText = "What's your goal? Like “Run a 5K”" };
        AutomationProperties.SetAutomationId(title, "goals.new.title");
        AutomationProperties.SetName(title, "New goal");

        var parseRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
        var parseText = Text("", 12, color: Secondary);
        parseText.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(parseText, "goals.new.read");
        var keepBtn = new HyperlinkButton { Content = "Keep literal", Padding = new Thickness(4, 0, 4, 0), FontSize = 12 };
        parseRow.Children.Add(parseText);
        parseRow.Children.Add(keepBtn);

        var why = new TextBox { AcceptsReturn = false, Text = "", PlaceholderText = "Why it matters to you (optional)", TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetAutomationId(why, "goals.new.why");
        AutomationProperties.SetName(why, "Why it matters");

        // Who's helping? section
        var whoSection = new StackPanel { Spacing = 6, Visibility = offersPlan ? Visibility.Visible : Visibility.Collapsed };
        var whoHeader = Text("Who's helping?", 12, bold: true, color: Secondary);
        AutomationProperties.SetAutomationId(whoHeader, "goals.new.who");
        var whoChips = new TaskWrapPanel { HorizontalSpacing = 6, VerticalSpacing = 6 };
        var whoNote = Text("", 12, color: Secondary);
        AutomationProperties.SetAutomationId(whoNote, "goals.new.who.note");
        whoSection.Children.Add(whoHeader);
        whoSection.Children.Add(whoChips);
        whoSection.Children.Add(whoNote);

        // Date & Number chips row (uses Flyouts, never nested ContentDialogs)
        var chipsRow = new TaskWrapPanel { HorizontalSpacing = 8, VerticalSpacing = 6 };
        var dateBtn = new DropDownButton { Content = "Date" };
        AutomationProperties.SetAutomationId(dateBtn, "goals.new.due");
        var numberBtn = new Button { Content = "Number" };
        AutomationProperties.SetAutomationId(numberBtn, "goals.new.number");
        chipsRow.Children.Add(dateBtn);
        chipsRow.Children.Add(numberBtn);

        var failure = Text("", 13, color: Critical);
        failure.Visibility = Visibility.Collapsed;

        var body = new StackPanel { Spacing = 10, MinWidth = 400 };
        body.Children.Add(title);
        body.Children.Add(parseRow);
        body.Children.Add(why);
        body.Children.Add(whoSection);
        body.Children.Add(chipsRow);
        body.Children.Add(failure);

        var dialog = new ContentDialog
        {
            Title = GoalsCopy.NewGoal,
            Content = new ScrollViewer { Content = body, MaxHeight = 520, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            PrimaryButtonText = "Add",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };

        TodoQuickRead CurrentRead() =>
            TodoQuickParse.Read(title.Text, DateTimeOffset.Now, Zone, dates: !manualDue, goal: true, keepLiteral: keepLiteral);

        DateTimeOffset? EffectiveDue() => manualDue ? manualDate : CurrentRead().Due;

        string EffectiveName()
        {
            var r = CurrentRead();
            var cleaned = r.Title.Trim();
            return cleaned.Length > 0 ? cleaned : title.Text.Trim();
        }

        void RefreshUi()
        {
            var now = DateTimeOffset.Now;
            var read = CurrentRead();
            var effDue = EffectiveDue();
            var effName = EffectiveName();

            dialog.IsPrimaryButtonEnabled = effName.Length > 0;
            dialog.PrimaryButtonText = offersPlan && team.Count > 0 ? $"Plan With {BotName(team[0])}" : "Add";

            if (!manualDue && read.Due is { } parsedDue && !string.Equals(read.Title.Trim(), title.Text.Trim(), StringComparison.Ordinal))
            {
                parseText.Text = $"“{read.Title.Trim()}” · By {TodoWords.MonthDay(parsedDue, now, Zone)}";
                keepBtn.Content = "Keep literal";
                parseRow.Visibility = Visibility.Visible;
            }
            else if (keepLiteral && !manualDue && TodoQuickParse.Read(title.Text, now, Zone, dates: true, goal: true, keepLiteral: false).Due != null)
            {
                parseText.Text = "Keeping title literal";
                keepBtn.Content = "Read date";
                parseRow.Visibility = Visibility.Visible;
            }
            else
            {
                parseRow.Visibility = Visibility.Collapsed;
            }

            dateBtn.Content = effDue is { } d ? "By " + TodoWords.MonthDay(d, now, Zone) : "Date";
            if (measure is { } m)
            {
                var unitSuffix = m.Unit.Length == 0 || m.Unit == "$" ? "" : " " + m.Unit;
                numberBtn.Content = $"{GoalViews.Number(m.Start, m.Unit)} → {GoalViews.Number(m.Target, m.Unit)}{unitSuffix}";
            }
            else
            {
                numberBtn.Content = "Number";
            }

            if (offersPlan)
            {
                whoChips.Children.Clear();
                foreach (var b in bots)
                {
                    var botId = b.Name;
                    var on = team.Contains(botId);
                    var leads = team.Count > 0 && team[0] == botId;
                    var faceRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
                    faceRow.Children.Add(Face(botId, 20));
                    var labelStack = new StackPanel { Spacing = 0 };
                    labelStack.Children.Add(Text(b.DisplayName, 12.5, bold: on, wrap: false));
                    if (leads) labelStack.Children.Add(Text("Leads", 10.5, color: on ? Brush("TextOnAccentFillColorSecondaryBrush") : Secondary, wrap: false));
                    faceRow.Children.Add(labelStack);

                    var chip = new Button
                    {
                        Content = faceRow,
                        Padding = new Thickness(8, 4, 10, 4),
                        CornerRadius = new CornerRadius(16),
                        Style = on ? Style("AccentButtonStyle") : null,
                    };
                    AutomationProperties.SetName(chip, leads ? $"{b.DisplayName}, Leads" : on ? $"{b.DisplayName}, Helps" : b.DisplayName);
                    AutomationProperties.SetAutomationId(chip, "goals.new.who." + botId);
                    chip.Click += (_, _) =>
                    {
                        if (!team.Remove(botId)) team.Add(botId);
                        SaveRememberedGoalTeam(team);
                        RefreshUi();
                    };
                    if (on && !leads)
                    {
                        var ctx = new MenuFlyout();
                        ctx.Items.Add(Item("Make Lead", "\uE734", () =>
                        {
                            team.Remove(botId);
                            team.Insert(0, botId);
                            SaveRememberedGoalTeam(team);
                            RefreshUi();
                        }));
                        ctx.Items.Add(Item("Take Off", "\uE738", () =>
                        {
                            team.Remove(botId);
                            SaveRememberedGoalTeam(team);
                            RefreshUi();
                        }));
                        chip.ContextFlyout = ctx;
                    }
                    whoChips.Children.Add(chip);
                }

                var justMeOn = team.Count == 0;
                var justMe = new Button
                {
                    Content = "Just Me",
                    Padding = new Thickness(12, 6, 12, 6),
                    CornerRadius = new CornerRadius(16),
                    Style = justMeOn ? Style("AccentButtonStyle") : null,
                };
                AutomationProperties.SetName(justMe, "Just Me");
                AutomationProperties.SetAutomationId(justMe, "goals.new.who.just-me");
                justMe.Click += (_, _) =>
                {
                    team.Clear();
                    SaveRememberedGoalTeam(team);
                    RefreshUi();
                };
                whoChips.Children.Add(justMe);
                whoNote.Text = GoalTeamNote(team, BotName);
            }
        }

        keepBtn.Click += (_, _) => { keepLiteral = !keepLiteral; RefreshUi(); };
        title.TextChanged += (_, _) => RefreshUi();
        title.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; why.Focus(FocusState.Programmatic); } };

        // Date menu + CalendarDatePicker Flyout (avoids nested ContentDialog)
        var dateMenu = new MenuFlyout();
        dateMenu.Opening += (_, _) =>
        {
            dateMenu.Items.Clear();
            var now = DateTimeOffset.Now;
            var today = TodoDates.LocalDay(now, Zone);
            void Pick(DateTimeOffset? picked)
            {
                manualDue = true;
                manualDate = picked;
                RefreshUi();
            }
            dateMenu.Items.Add(Item("In a Month", "\uE787", () => Pick(new DateTimeOffset(today.AddMonths(1), Zone.GetUtcOffset(today.AddMonths(1))))));
            dateMenu.Items.Add(Item("In 3 Months", "\uE787", () => Pick(new DateTimeOffset(today.AddMonths(3), Zone.GetUtcOffset(today.AddMonths(3))))));
            var eoy = new DateTime(today.Year, 12, 31);
            dateMenu.Items.Add(Item("End of the Year", "\uE787", () => Pick(new DateTimeOffset(eoy, Zone.GetUtcOffset(eoy)))));
            dateMenu.Items.Add(Item("Choose Date…", "\uE787", () =>
            {
                var flyout = new Flyout();
                var picker = new CalendarDatePicker
                {
                    Date = EffectiveDue() ?? DateTimeOffset.Now.AddMonths(1),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Header = "Target Date",
                };
                var setBtn = Push("Set Date", () =>
                {
                    if (picker.Date is { } d) Pick(d);
                    flyout.Hide();
                }, accent: true);
                var stack = new StackPanel { Spacing = 8, MinWidth = 240 };
                stack.Children.Add(picker);
                stack.Children.Add(setBtn);
                flyout.Content = stack;
                flyout.ShowAt(dateBtn);
            }));
            if (EffectiveDue() != null)
            {
                dateMenu.Items.Add(new MenuFlyoutSeparator());
                var clear = Item("No Date", "\uE711", () => Pick(null));
                clear.Foreground = Critical;
                dateMenu.Items.Add(clear);
            }
        };
        dateBtn.Flyout = dateMenu;

        // Number Flyout (avoids nested ContentDialog)
        numberBtn.Click += (_, _) =>
        {
            var flyout = new Flyout();
            var startBox = new TextBox { Header = "Start", Text = measure != null ? measure.Start.ToString(CultureInfo.InvariantCulture) : "0" };
            var targetBox = new TextBox { Header = "Target", Text = measure != null ? measure.Target.ToString(CultureInfo.InvariantCulture) : "" };
            var unitBox = new TextBox { Header = "Unit (optional, e.g. km, $)", Text = measure?.Unit ?? "" };
            var err = Text("", 12, color: Critical);
            err.Visibility = Visibility.Collapsed;
            var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            btns.Children.Add(Push("Set", () =>
            {
                if (!double.TryParse(targetBox.Text.Trim(), CultureInfo.InvariantCulture, out var targetVal))
                {
                    err.Text = "Enter a target number.";
                    err.Visibility = Visibility.Visible;
                    return;
                }
                if (!double.TryParse(startBox.Text.Trim(), CultureInfo.InvariantCulture, out var startVal)) startVal = 0;
                measure = new GoalMeasure(unitBox.Text.Trim(), startVal, targetVal, startVal);
                flyout.Hide();
                RefreshUi();
            }, accent: true));
            if (measure != null)
            {
                var clear = Quiet("No Number", () => { measure = null; flyout.Hide(); RefreshUi(); });
                clear.Foreground = Critical;
                btns.Children.Add(clear);
            }
            var panel = new StackPanel { Spacing = 8, MinWidth = 260 };
            panel.Children.Add(startBox);
            panel.Children.Add(targetBox);
            panel.Children.Add(unitBox);
            panel.Children.Add(err);
            panel.Children.Add(btns);
            flyout.Content = panel;
            flyout.ShowAt(numberBtn);
        };

        RefreshUi();

        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var wait = e.GetDeferral();
            try
            {
                var finalName = EffectiveName();
                if (finalName.Length > 200) finalName = finalName[..200];
                var finalWhy = why.Text.Trim();
                if (finalWhy.Length > 300) finalWhy = finalWhy[..300];
                var dueKey = EffectiveDue() is { } d ? TodoViews.DayKey(TodoDates.LocalDay(d, Zone)) : null;
                var lead = offersPlan && team.Count > 0 ? team[0] : null;
                var helpers = offersPlan && team.Count > 1 ? team.Skip(1).ToList() : null;
                var review = lead != null ? new GoalReview(0, "08:00") : null;

                if (await store.AddGoalAsync(finalName, finalWhy, due: dueKey, measure: measure, lead: lead, helpers: helpers, review: review) is { } made)
                {
                    createdGoal = made;
                    createdLead = lead;
                    _view = TodoView.Goals;
                    AppLog.Note("tasks", "goal added");
                    return;
                }
                e.Cancel = true;
                failure.Text = store.AddGoalFailure ?? "Check your connection, then try again.";
                failure.Visibility = Visibility.Visible;
            }
            catch (Exception ex)
            {
                e.Cancel = true;
                AppLog.Error("tasks", ex);
                failure.Text = "Check your connection, then try again.";
                failure.Visibility = Visibility.Visible;
            }
            finally { wait.Complete(); }
        };

        await ShowAsync(XamlRoot, dialog);
        Render();

        if (createdGoal != null)
        {
            if (createdLead != null)
                OpenGoalChatForPlan(createdGoal, createdLead);
            else
                OpenGoal(createdGoal.Id);
        }
    }

    private static void OpenGoalChatForPlan(Goal goal, string leadId)
    {
        var prompt = GoalBots.PlanRequest(goal);
        if (goal.Chat is { } chat)
        {
            Navigator.Go(new ChatDestination(chat.Profile, chat.SessionId, TaskChatLinks.GoalSessionTitle(goal), prompt));
            return;
        }
        var bot = PageKit.Bots.FirstOrDefault(b => b.Name == leadId) ?? PageKit.Bots.FirstOrDefault();
        if (bot == null) return;
        if (bot.Canonical?.OpenId is { Length: > 0 } cid)
            Navigator.Go(new ChatDestination(bot.Name, cid, TaskChatLinks.GoalSessionTitle(goal), prompt));
        else
            Navigator.Go(new BotChatDestination(bot));
    }
}
