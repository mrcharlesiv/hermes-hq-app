using Hermes.Core.Composer;
using Hermes.Core.Gateways;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// [WIN-42] Tasks › Goals (docs/goals.md "The Goals view" and "The shelf"; TasksViewController.swift's [goals] parts,
/// App/Pages/Goals/GoalsListViews.swift and GoalShelfViews.swift at 93f984bb1). The rules are Hermes.Core.Tasks'
/// GoalViews and GoalShelf; this file only draws:
/// - the Goals view: Active cards in your order, then Someday's quieter ones, then Achieved and Let Go folded to their
///   headings ("goals.fold.<key>": Show / Hide), then "+ New Goal"; with no goals, what a goal is, with New Goal;
/// - Today's Goals shelf over Today's rows: "Goals" (a tap folds it; "Goals 3" folded, kept on this device) with
///   "All 3 ›" at its end, then the active goals' small cards side by side.
/// A card's circle ticks its next task, as a task row's does. New Goal here takes a name and why (POST /goals); the
/// Mac sheet's date chips, Number and Who's helping?, and a goal's own page, are later slices.
public sealed partial class TasksPage
{
    /// Achieved and Let Go opened from their fold (the page's own, as the Mac's `goalFoldsOpen`: never saved).
    private readonly HashSet<GoalGroupKey> _goalFoldsOpen = [];
    private static readonly GoalShelfFold ShelfFold = new(new JsonFileStore(System.IO.Path.Combine(AppPaths.Root, "tasks-goals.json")));

    /// The Goals view, in place of a view's task groups.
    private void RenderGoals(TasksStore store, DateTimeOffset now)
    {
        var groups = GoalViews.Groups(store.Goals);
        if (groups.IsEmpty)
        {
            // GoalsEmptyRow: what a goal is, in two lines, with New Goal under it.
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

    /// One goal as a card (GoalCard): the ring, the name, one grey line with the pace after it, and under a hairline
    /// the goal's next task with its circle.
    private FrameworkElement GoalCardView(GoalCardModel card, TasksStore store)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Ring(card.Fraction, card.GreyRing ? Rgb(0x8E, 0x8E, 0x93) : Tint(card.Color), 34));
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(Text(card.Title, 16, bold: true, color: card.Quiet ? Secondary : null, wrap: false));
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
        box.Tapped += (_, _) => OpenGoal(card.Id);
        return box;
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

    /// The Mac offers the add-on's update here (PushSetupOffer) and then reads the whole list again; Windows has no
    /// update offer yet, so this reads the list again (the pill turns into Goals once the add-on keeps them).
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

    /// [WIN-47] "Add to Goal" on a row's menu, beside Move To (GoalShared.swift `GoalChoices.menu`): each active goal
    /// (with milestones, a submenu), then No Goal and Open Goal for a task in one. null with nothing to choose.
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
        AutomationProperties.SetItemStatus(all, cards.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));
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
        var stack = new StackPanel { Spacing = 3, Width = 196 };
        var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        top.Children.Add(Ring(card.Fraction, Tint(card.Color), 22));
        var name = Text(card.Title, 14, bold: true, wrap: false);
        name.MaxWidth = 150;
        name.VerticalAlignment = VerticalAlignment.Center;
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

    /// New Goal: a name and why (NewGoalSheet's two lines: "New goal", "Why it matters"), then Add. It closes on Add and
    /// the Goals view shows the new card.
    private void NewGoal()
    {
        if (_store is not { } store) return;
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        _ = NewGoalAsync(store);
    }

    private async Task NewGoalAsync(TasksStore store)
    {
        var title = new TextBox { PlaceholderText = "New goal" };
        AutomationProperties.SetAutomationId(title, "goals.new.title");
        AutomationProperties.SetName(title, "New goal");
        var why = new TextBox { PlaceholderText = "Why it matters", TextWrapping = TextWrapping.Wrap, AcceptsReturn = false };
        AutomationProperties.SetAutomationId(why, "goals.new.why");
        AutomationProperties.SetName(why, "Why it matters");
        var failure = Text("", 13, color: Critical);
        failure.Visibility = Visibility.Collapsed;
        var body = new StackPanel { Spacing = 10, MinWidth = 360 };
        body.Children.Add(title);
        body.Children.Add(why);
        body.Children.Add(failure);
        var dialog = new ContentDialog
        {
            Title = GoalsCopy.NewGoal, Content = body, PrimaryButtonText = "Add", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false,
        };
        title.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = title.Text.Trim().Length > 0;
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var wait = e.GetDeferral();
            try
            {
                if (await store.AddGoalAsync(title.Text, why.Text) is { } made)
                {
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
    }
}
