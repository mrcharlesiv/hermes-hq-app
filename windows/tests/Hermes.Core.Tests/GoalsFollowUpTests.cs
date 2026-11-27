using System.Text.Json.Nodes;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-47] The Goals follow-ups' rules (TasksViewController.swift [goals]/[goals-addon], TaskRowViews.swift,
/// App/Pages/Goals/GoalShared.swift `GoalChoices`, HermesKit GoalShelf.swift `markGoal`/`found`/`searchWords`,
/// GoalViews.swift `assign`, TasksStore.swift `goalsNeedAddOn` at 93f984bb1): a search's Goals group, a row's goal mark,
/// Add to Goal's choices and the PATCH they send, the older add-on's Goals pill and state, and the bar's +.
public class GoalsFollowUpTests
{
    private static Goal G(string json) => Goal.From(JsonNode.Parse(json))!;
    private static TodoTask T(string id, string? goal = null, string? milestone = null, string title = "") =>
        new(id) { Title = title.Length == 0 ? "Task " + id : title, Goal = goal, Milestone = milestone };

    private static readonly Goal Run = G("""{"id": "g_run", "title": "Run a 10K", "why": "A friend is running it too.", "color": "orange", "position": 1, "milestones": [{"id": "m_2", "title": "Run 2 miles", "done": true}, {"id": "m_5k", "title": "Run a 5K"}]}""");
    private static readonly Goal Trip = G("""{"id": "g_trip", "title": "Family trip to the coast", "color": "green", "position": 2}""");
    private static readonly Goal Spanish = G("""{"id": "g_es", "title": "Learn conversational Spanish", "status": "paused", "color": "purple"}""");
    private static readonly Goal Books = G("""{"id": "g_books", "title": "Read 12 books", "why": "Run through a shelf.", "status": "achieved", "status_at": "2026-12-01T00:00:00Z"}""");
    private static readonly Goal Untitled = G("""{"id": "g_blank", "title": "", "color": "teal", "position": 3}""");
    private static readonly Goal[] All = [Books, Trip, Spanish, Run, Untitled];

    [Fact]
    public void ASearchFindsGoalsByNameOrWhyAnyStatusInTheGoalsViewsOrder()
    {
        // "run" is in the 10K's name and the achieved goal's why: active first, then Achieved.
        Assert.Equal(["g_run", "g_books"], GoalViews.Found(All, "  RUN ").Select(g => g.Id));
        Assert.Equal(["g_es"], GoalViews.Found(All, "spanish").Select(g => g.Id));   // Someday's too
        Assert.Empty(GoalViews.Found(All, "   "));
        Assert.Empty(GoalViews.Found(All, "#run"));   // a tag search looks for tasks alone
        Assert.Equal("Goals", GoalViews.GroupTitle(GoalGroupKey.Found));
        Assert.Equal("goals.fold.found", GoalViews.FoldId(GoalGroupKey.Found));
        Assert.False(GoalViews.Folds(GoalGroupKey.Found));
        Assert.True(GoalViews.HasHeading(GoalGroupKey.Found));

        // Only a search with every task (or yours alone) has it, on an add-on that keeps goals.
        Assert.True(GoalViews.FindsGoals(goalsSupported: true, scope: "all"));
        Assert.True(GoalViews.FindsGoals(goalsSupported: true, scope: "@me"));
        Assert.False(GoalViews.FindsGoals(goalsSupported: true, scope: "hermes"));
        Assert.False(GoalViews.FindsGoals(goalsSupported: false, scope: "all"));
    }

    [Fact]
    public void ATaskIsFoundByItsGoalsAndMilestonesName()
    {
        var tasks = new[] { T("a", "g_run", "m_5k", "Buy shoes"), T("b", "g_trip", title: "Pack"), T("c", title: "Call the plumber") };
        Assert.Equal(["Run a 10K", "Run a 5K"], GoalViews.SearchWords(tasks[0], All));
        Assert.Equal(["Family trip to the coast"], GoalViews.SearchWords(tasks[1], All));
        Assert.Empty(GoalViews.SearchWords(tasks[2], All));
        Assert.Empty(GoalViews.SearchWords(T("d", "g_gone"), All));
        Assert.Equal(["a"], TodoSections.Filtered(tasks, "5k", All).Select(t => t.Id));
        Assert.Equal(["b"], TodoSections.Filtered(tasks, "coast", All).Select(t => t.Id));
        Assert.Empty(TodoSections.Filtered(tasks, "coast"));   // with no goals given, as before
        Assert.Empty(TodoSections.Filtered(tasks, "#coast", All));
    }

    [Fact]
    public void ARowCarriesItsActiveOrPausedGoalsMark()
    {
        Assert.Same(Run, GoalViews.MarkGoal(T("a", "g_run"), All));
        Assert.Same(Spanish, GoalViews.MarkGoal(T("a", "g_es"), All));   // paused still marks
        Assert.Null(GoalViews.MarkGoal(T("a", "g_books"), All));   // achieved: the list's dot again
        Assert.Null(GoalViews.MarkGoal(T("a", "g_gone"), All));
        Assert.Null(GoalViews.MarkGoal(T("a"), All));
        Assert.Equal("orange", GoalViews.MarkGoal(T("a", "g_run"), All)!.Tint);
        // VoiceOver's words: "…, for <goal>", an untitled goal by its stand-in name.
        Assert.Equal("for Run a 10K", GoalViews.MarkWords(Run));
        Assert.Equal("for Untitled Goal", GoalViews.MarkWords(Untitled));
        Assert.Equal("tasks.goal-mark", GoalViews.MarkId);
    }

    [Fact]
    public void AddToGoalListsActiveGoalsWithMilestonesThenNoGoalAndOpenGoal()
    {
        // A task in no goal: each active goal; one with milestones is a submenu (No Milestone, then the open ones).
        var loose = GoalChoices.Menu(T("a"), All, goalsSupported: true)!;
        Assert.Equal("Add to Goal", GoalChoices.Title);
        Assert.Equal(["Run a 10K", "Family trip to the coast", ""], loose.Select(c => c.Title));
        Assert.Equal(["No Milestone", "Run a 5K"], loose[0].Children.Select(c => c.Title));   // a done milestone left out
        Assert.All(loose.SelectMany(c => c.Children.Prepend(c)), c => Assert.False(c.Ticked));
        Assert.Empty(loose[1].Children);
        Assert.Equal(("g_trip", (string?)null), (loose[1].Goal, loose[1].Milestone));

        // A task in the 10K under its done milestone: that milestone stays to show the tick; then No Goal, Open Goal.
        var inRun = GoalChoices.Menu(T("b", "g_run", "m_2"), All, goalsSupported: true)!;
        Assert.Equal(["Run a 10K", "Family trip to the coast", "", "No Goal", "Open Goal"], inRun.Select(c => c.Title));
        Assert.Equal(["No Milestone", "Run 2 miles", "Run a 5K"], inRun[0].Children.Select(c => c.Title));
        Assert.Equal([false, true, false], inRun[0].Children.Select(c => c.Ticked));
        Assert.Equal(GoalChoiceKind.NoGoal, inRun[3].Kind);
        Assert.Equal((GoalChoiceKind.OpenGoal, "g_run"), (inRun[4].Kind, inRun[4].Goal));
        var inTrip = GoalChoices.Menu(T("c", "g_trip"), All, goalsSupported: true)!;
        Assert.True(inTrip[1].Ticked);
        Assert.False(inTrip[0].Ticked);
        Assert.Equal(GoalChoiceKind.Goal, inTrip[1].Kind);

        // An achieved goal's task: no active goal ticked, and it can still leave its goal.
        var inBooks = GoalChoices.Menu(T("d", "g_books"), All, goalsSupported: true)!;
        Assert.Equal(["No Goal", "Open Goal"], inBooks.Skip(3).Select(c => c.Title));

        // None on an add-on without goals, nor with nothing to choose.
        Assert.Null(GoalChoices.Menu(T("a"), All, goalsSupported: false));
        Assert.Null(GoalChoices.Menu(T("a"), [Books], goalsSupported: true));
    }

    [Fact]
    public void AChoiceSendsTheGoalAndAMilestoneTheGoalHas()
    {
        Assert.Equal("""{"goal":"g_run","milestone":"m_5k"}""", GoalViews.Assign("g_run", "m_5k", All).ToJsonString());
        Assert.Equal("""{"goal":"g_run","milestone":null}""", GoalViews.Assign("g_run", "m_other", All).ToJsonString());
        Assert.Equal("""{"goal":"g_trip","milestone":null}""", GoalViews.Assign("g_trip", null, All).ToJsonString());
        Assert.Equal("""{"goal":null,"milestone":null}""", GoalViews.Assign(null, "m_5k", All).ToJsonString());
        // The edit shows at once: the task reads its new goal and milestone.
        var task = TodoTask.From(JsonNode.Parse("""{"id": "t1", "rev": 3, "title": "Buy shoes", "goal": "g_trip"}"""))!;
        var shown = TodoEdits.Applying(GoalViews.Assign("g_run", "m_5k", All), task)!;
        Assert.Equal(("g_run", "m_5k"), (shown.Goal, shown.Milestone));
        var cleared = TodoEdits.Applying(GoalViews.Assign(null, null, All), shown)!;
        Assert.Equal(((string?)null, (string?)null), (cleared.Goal, cleared.Milestone));
    }

    [Fact]
    public void AnOlderAddOnKeepsTheGoalsPillAndSaysToUpdate()
    {
        Assert.True(GoalsAddOn.NeedsAddOn(hasList: true, needsAddOn: false, goalsSupported: false));
        Assert.False(GoalsAddOn.NeedsAddOn(hasList: false, needsAddOn: false, goalsSupported: false));
        Assert.False(GoalsAddOn.NeedsAddOn(hasList: true, needsAddOn: true, goalsSupported: false));
        Assert.False(GoalsAddOn.NeedsAddOn(hasList: true, needsAddOn: false, goalsSupported: true));

        // The pill: with its active count on an add-on that keeps goals; with no count on an older one; else none.
        Assert.Equal((true, (int?)2), GoalsAddOn.Pill(goalsSupported: true, goalsNeedAddOn: false, [Run, Trip, Spanish]));
        Assert.Equal((true, (int?)null), GoalsAddOn.Pill(goalsSupported: false, goalsNeedAddOn: true, []));
        Assert.Equal((false, (int?)null), GoalsAddOn.Pill(goalsSupported: false, goalsNeedAddOn: false, []));
        Assert.Equal("Goals", GoalsAddOn.PillName(null));
        Assert.Equal("Goals, 2 tasks", GoalsAddOn.PillName(2));
        Assert.Equal("Goals", GoalsAddOn.PillName(0));

        // Goals stays picked on an older add-on (its update state alone); it falls back to Today only with no list yet.
        Assert.False(GoalsAddOn.FallsBack(TodoView.Goals, goalsSupported: false, goalsNeedAddOn: true));
        Assert.True(GoalsAddOn.FallsBack(TodoView.Goals, goalsSupported: false, goalsNeedAddOn: false));
        Assert.False(GoalsAddOn.FallsBack(TodoView.Today, goalsSupported: false, goalsNeedAddOn: false));
        Assert.True(GoalsAddOn.Locked(TodoView.Goals, searching: false, goalsSupported: false));
        Assert.False(GoalsAddOn.Locked(TodoView.Goals, searching: true, goalsSupported: false));
        Assert.False(GoalsAddOn.Locked(TodoView.Goals, searching: false, goalsSupported: true));
        Assert.False(GoalsAddOn.Locked(TodoView.Today, searching: false, goalsSupported: false));
        Assert.Equal("Goals Need a Newer Add-on", GoalsAddOn.StateTitle);
        Assert.Equal("Update Hermes HQ Add-on on your computer to set goals, milestones and the tasks under them.",
            GoalsAddOn.StateText("your computer"));
        Assert.Equal("Update Add-on", GoalsAddOn.UpdateButton);
        Assert.Equal("Updating…", GoalsAddOn.UpdatingButton);
    }

    [Fact]
    public void TheBarsPlusSaysWhatItMakes()
    {
        Assert.Equal("New Goal", GoalsAddOn.AddLabel(TodoView.Goals, goalsNeedAddOn: false));
        Assert.Equal("Update Add-on", GoalsAddOn.AddLabel(TodoView.Goals, goalsNeedAddOn: true));
        Assert.Equal("New Task", GoalsAddOn.AddLabel(TodoView.Today, goalsNeedAddOn: true));
        Assert.Equal("New Task", GoalsAddOn.AddLabel(TodoView.List("s1"), goalsNeedAddOn: false));
        // What the + does: a goal in the Goals view (not while searching), the update on an older add-on.
        Assert.Equal(GoalsAddAction.NewGoal, GoalsAddOn.AddAction(TodoView.Goals, searching: false, goalsSupported: true, goalsNeedAddOn: false));
        Assert.Equal(GoalsAddAction.UpdateAddOn, GoalsAddOn.AddAction(TodoView.Goals, searching: false, goalsSupported: false, goalsNeedAddOn: true));
        Assert.Equal(GoalsAddAction.NewTask, GoalsAddOn.AddAction(TodoView.Goals, searching: true, goalsSupported: true, goalsNeedAddOn: false));
        Assert.Equal(GoalsAddAction.NewTask, GoalsAddOn.AddAction(TodoView.Today, searching: false, goalsSupported: true, goalsNeedAddOn: false));
    }

    [Fact]
    public void ASearchListsItsTasksInEveryViewGoalsToo()
    {
        // [WIN-53] CI run 45004280241: “coast” with the Goals pill picked showed the trip's card and none of its tasks,
        // since the view's own groups (none, in Goals) were drawn. The Mac's search looks through every view
        // (TasksViewController.reload `if searching`): To Do, soonest due first, then Done, newest first.
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
        var now = new DateTimeOffset(2026, 11, 4, 9, 41, 0, TimeSpan.FromHours(-6));
        TodoTask[] tasks =
        [
            T("t_pack", "g_trip", title: "Make the packing list") with { Position = 2 },
            T("t_tickets", "g_trip", title: "Book the aquarium tickets") with { Due = "2026-11-20", Position = 3 },
            T("t_rooms", "g_trip", title: "Book the rooms") with { Status = "done", DoneAt = "2026-11-01T10:00:00Z" },
            T("t_car", "g_trip", title: "Rent the car") with { Status = "done", DoneAt = "2026-11-03T10:00:00Z" },
            T("t_plumber", title: "Call the plumber"),
        ];
        var found = TodoSections.Filtered(tasks, "coast", All);
        Assert.Empty(TodoViews.Groups(found, TodoView.Goals, [], [], now, zone));   // the Goals view's own groups: no tasks
        var groups = TodoViews.SearchGroups(found, zone);
        Assert.Equal([TodoGroupKind.Open, TodoGroupKind.Done], groups.Select(g => g.Kind));
        Assert.Equal(["t_tickets", "t_pack"], groups[0].Tasks.Select(t => t.Id));   // dated first, then your order
        Assert.Equal(["t_car", "t_rooms"], groups[1].Tasks.Select(t => t.Id));      // newest done first
        Assert.Equal(("To Do", (string?)null), TodoViews.PageHeading(TodoGroupKind.Open, TodoView.Goals, true, now, zone, [], _ => ""));
        // Today's own groups would drop the undated packing list too; the search has it whichever pill is picked.
        Assert.DoesNotContain(TodoViews.Groups(found, TodoView.Today, [], [], now, zone).SelectMany(g => g.Tasks), t => t.Id == "t_pack");
        Assert.Empty(TodoViews.SearchGroups([], zone));
    }
}
