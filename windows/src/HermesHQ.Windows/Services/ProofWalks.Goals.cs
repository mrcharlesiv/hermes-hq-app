using Hermes.Core.Shell;
using Hermes.Core.Tasks;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace HermesHQ.Services;

/// [WIN-42] The CI's walk for Tasks › Goals (windows/ci/windows.yml's "tasks-goals" extra runs it on the pages stand-in
/// with --task-goals --task-lists), backed by the app's state and the stand-in's own record (`GoalsWalkProof`):
///   tasks-goals  Tasks opens on Today with Goals as the first pill; Today leads with the Goals shelf, its three active
///                goals' cards in order, each with its "Next: …" (shot tasks-today-goals). A click on the shelf's "Goals"
///                folds it to its heading ("3, hidden") and another opens it. "All 3 ›" opens the Goals view: the active
///                cards then Someday's, Achieved folded to its heading until its Show (goals.fold.achieved), then
///                "+ New Goal" (shot tasks-goals). A click on the trip card's circle ticks its next task: the stand-in took
///                that one PATCH, and the card's next task moves on. [WIN-47] The bar's + reads New Goal there. A search
///                for "coast" leads with its Goals group (the trip's card) over the trip's tasks, each with the trip's
///                mark (shot tasks-goals-search). In Today the testers goal's task carries its mark, and its menu's Add
///                to Goal (the active goals, No Goal, Open Goal) moves it to the trip: one PATCH of goal and milestone,
///                and the row's mark follows (shot tasks-goal-mark).
internal static partial class ProofWalks
{
    /// The Tasks page's search box.
    private const string TasksSearchId = "tasks.search";

    private static void RegisterGoalsWalks()
    {
        Automation.NamedWalks["tasks-goals"] = TasksGoalsAsync;
    }

    /// A click where the pointer lands; where the runner's desktop doesn't take it, what the click does, said in the log.
    private static void ClickGoals(FrameworkElement element)
    {
        try { Mouse.Click(element); }
        catch (InvalidOperationException e)
        {
            AppLog.Note("automation", $"walk tasks-goals: {Id(element)} wasn't clicked ({e.Message}); invoking it");
            Invoke(element);
        }
    }

    private static async Task TasksGoalsAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        Navigator.Open("tasks");
        var goalsPill = await Until(() => Find("tasks.view." + TodoView.Goals.Key) as ToggleButton, "the Goals pill");
        var pills = goalsPill.Parent as Panel ?? throw new InvalidOperationException("the Goals pill isn't in the views row");
        if (pills.Children.FirstOrDefault() != goalsPill) throw new InvalidOperationException("Goals isn't the first pill");
        if (AutomationProperties.GetName(goalsPill) != GoalsAddOn.PillName(GoalsWalkProof.ActiveTitles.Length))
            throw new InvalidOperationException($"the Goals pill reads {AutomationProperties.GetName(goalsPill)}");
        await Until(() => Find("tasks.view." + TodoView.Today.Key) is ToggleButton { IsChecked: true } p ? p : null, "Today picked");

        // Today's shelf: its heading, "All 3 ›" and the active goals' cards in order.
        var shelf = await Until(() => Find(GoalShelf.ShelfId), "Today's Goals shelf");
        // Wait for the heading to say which way the shelf is: CI run 45124170121 saw the shelf before its cards were
        // laid out (the heading still 0×0), took the missing cards for a fold and pressed the heading, which folded
        // an open shelf. Press it only when the heading itself says the shelf is folded.
        var heading = await Until(() => Find(GoalShelf.HeadingId) is { } h
            && AutomationProperties.GetItemStatus(h) is var s && (s == GoalShelf.HeadingValue(3, folded: true) || s == GoalShelf.HeadingValue(3, folded: false)) ? h : null,
            "the shelf's heading to say shown or hidden");
        if (AutomationProperties.GetItemStatus(heading) == GoalShelf.HeadingValue(3, folded: true))
        {
            // A fold left from an earlier run on this machine: open it first.
            ClickGoals(Need(GoalShelf.HeadingId));
            await Until(() => Find("goals.shelf.cards"), "the shelf opened");
        }
        await Until(() => GoalsWalkProof.CardsShown([.. Shown(Root).Select(Id)], GoalsWalkProof.ActiveTitles, "goal-shelf-") == null ? shelf : null,
            "the shelf's three cards");
        var texts = Shown(Need("goals.shelf.cards")).OfType<TextBlock>().Select(t => AutomationProperties.GetName(t) is { Length: > 0 } n ? n : t.Text).ToList();
        foreach (var next in GoalsWalkProof.ShelfNext)
            if (!texts.Contains(next)) throw new InvalidOperationException($"no shelf card says “{next}” ({string.Join(" | ", texts)})");
        if (AutomationProperties.GetItemStatus(Need(GoalShelf.HeadingId)) != GoalShelf.HeadingValue(3, folded: false))
            throw new InvalidOperationException($"the shelf's heading says {AutomationProperties.GetItemStatus(Need(GoalShelf.HeadingId))}");
        await shot("tasks-today-goals");

        // "Goals" folds the shelf to its heading, and opens it again.
        ClickGoals(Need(GoalShelf.HeadingId));
        await Until(() => Find("goals.shelf.cards") == null && Find(GoalShelf.HeadingId) is { } h
            && AutomationProperties.GetItemStatus(h) == GoalShelf.HeadingValue(3, folded: true) ? h : null, "the shelf folded");
        ClickGoals(Need(GoalShelf.HeadingId));
        await Until(() => Find("goals.shelf.cards"), "the shelf open again");

        // "All 3 ›": the Goals view.
        ClickGoals(Need(GoalShelf.AllId));
        await Until(() => Find("tasks.view." + TodoView.Goals.Key) is ToggleButton { IsChecked: true } p ? p : null, "the Goals view");
        string[] folded = [.. GoalsWalkProof.ActiveTitles, .. GoalsWalkProof.SomedayTitles];
        await Until(() => GoalsWalkProof.CardsShown([.. Shown(Root).Select(Id)], folded) == null ? Root : null, "active and Someday cards, Achieved folded");
        if (Find(TodoViews.SectionAutomationId("Someday")) == null) throw new InvalidOperationException("no Someday heading");
        if (Find(GoalsCopy.NewId) == null) throw new InvalidOperationException("no + New Goal row");
        var show = (HyperlinkButton)Need(GoalViews.FoldId(GoalGroupKey.Achieved));
        if (show.Content as string != "Show") throw new InvalidOperationException($"Achieved's fold reads {show.Content}");
        ClickGoals(show);
        string[] all = [.. folded, .. GoalsWalkProof.AchievedTitles];
        await Until(() => GoalsWalkProof.CardsShown([.. Shown(Root).Select(Id)], all) == null ? Root : null, "Achieved opened");
        if ((Need(GoalViews.FoldId(GoalGroupKey.Achieved)) as HyperlinkButton)?.Content as string != "Hide") throw new InvalidOperationException("Achieved's fold doesn't say Hide");
        await shot("tasks-goals");

        // The trip card's circle ticks its next task: one PATCH, and its next moves on.
        var trip = Need("goal-card-" + GoalsWalkProof.ActiveTitles[2]);
        var tick = Need(trip, GoalsCopy.TickId);
        if (AutomationProperties.GetName(tick) != GoalsCopy.MarkDone(GoalsWalkProof.TripNextTitle))
            throw new InvalidOperationException($"the trip card's tick is named {AutomationProperties.GetName(tick)}");
        var mark = WalkProof.RestCount(await StandIn(url, "/__fixture/state"));
        ClickGoals(tick);
        await Until(() => Find("goal-card-" + GoalsWalkProof.ActiveTitles[2]) is { } card
            && Shown(card).OfType<TextBlock>().Any(t => t.Text == GoalsWalkProof.TripAfter) ? card : null, "the trip card's next task moved on", 20);
        if (GoalsWalkProof.TickRecorded(await StandIn(url, "/__fixture/state"), mark, GoalsWalkProof.TripNext) is { } wrong)
            throw new InvalidOperationException(wrong);

        // [WIN-47] The bar's + reads "New Goal" in the Goals view.
        if (AutomationProperties.GetName(Need("tasks.new")) != GoalsAddOn.AddLabel(TodoView.Goals, goalsNeedAddOn: false))
            throw new InvalidOperationException($"the bar's + reads {AutomationProperties.GetName(Need("tasks.new"))} in Goals");

        // [WIN-47] A search: its Goals group (the trip's card) over its To Do, whose rows carry the trip's mark.
        var search = (TextBox)Need(TasksSearchId);
        search.Text = GoalsWalkProof.SearchQuery;
        await Until(() => Find(TodoViews.SectionAutomationId(GoalViews.GroupTitle(GoalGroupKey.Found))), "the search's Goals group");
        await Until(() => GoalsWalkProof.CardsShown([.. Shown(Root).Select(Id)], GoalsWalkProof.SearchCards) == null ? Root : null, "the trip's card found");
        var foundRow = await Until(() => Find("tasks.row." + GoalsWalkProof.SearchRow), "the trip's task found by its goal's name");
        if (FindIn(foundRow, GoalViews.MarkId) == null) throw new InvalidOperationException("the found row has no goal mark");
        if (GoalsWalkProof.RowMarked(AutomationProperties.GetName(foundRow), GoalsWalkProof.MoveGoalTitle) is { } unmarked) throw new InvalidOperationException(unmarked);
        await shot("tasks-goals-search");
        search.Text = "";

        // [WIN-47] Today: the goal's task carries its mark; its menu's Add to Goal moves it to the trip (one PATCH).
        ClickGoals(Need("tasks.view." + TodoView.Today.Key));
        var row = await Until(() => Find("tasks.row." + GoalsWalkProof.MarkTask), "Today's goal task");
        if (FindIn(row, GoalViews.MarkId) == null) throw new InvalidOperationException("Today's goal task has no goal mark");
        if (GoalsWalkProof.RowMarked(AutomationProperties.GetName(row), GoalsWalkProof.MarkGoalTitle) is { } bare) throw new InvalidOperationException(bare);
        var addToGoal = (row.ContextFlyout as MenuFlyout)?.Items.OfType<MenuFlyoutSubItem>().FirstOrDefault(i => Id(i) == GoalChoices.MenuId)
            ?? throw new InvalidOperationException("the row's menu has no Add to Goal");
        if (addToGoal.Text != GoalChoices.Title) throw new InvalidOperationException($"Add to Goal reads {addToGoal.Text}");
        var rows = addToGoal.Items.OfType<MenuFlyoutItemBase>().Select(i => i switch { MenuFlyoutItem m => m.Text, MenuFlyoutSubItem m => m.Text, _ => "" }).ToList();
        if (!rows.SequenceEqual(GoalsWalkProof.MarkChoices)) throw new InvalidOperationException($"Add to Goal lists {string.Join(" | ", rows)}");
        var trip2 = addToGoal.Items.OfType<ToggleMenuFlyoutItem>().First(i => i.Text == GoalsWalkProof.MoveGoalTitle);
        var before = WalkProof.RestCount(await StandIn(url, "/__fixture/state"));
        switch (FrameworkElementAutomationPeer.CreatePeerForElement(trip2))
        {
            case IInvokeProvider invoke: invoke.Invoke(); break;
            case IToggleProvider toggle: toggle.Toggle(); break;
            default: throw new InvalidOperationException("Add to Goal's trip can't be picked");
        }
        await Until(() => Find("tasks.row." + GoalsWalkProof.MarkTask) is { } r
            && GoalsWalkProof.RowMarked(AutomationProperties.GetName(r), GoalsWalkProof.MoveGoalTitle) == null ? r : null, "the row's mark moved to the trip", 20);
        if (GoalsWalkProof.GoalRecorded(await StandIn(url, "/__fixture/state"), before, GoalsWalkProof.MarkTask, GoalsWalkProof.MoveGoal, null) is { } off)
            throw new InvalidOperationException(off);
        await shot("tasks-goal-mark");
        AppLog.Note("automation", "walk tasks-goals: shelf, folds, Goals view, a card's tick, search's Goals and Add to Goal checked");
    }
}
