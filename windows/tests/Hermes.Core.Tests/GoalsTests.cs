using System.Text.Json.Nodes;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-42] The Goals view's and Today's Goals shelf's rules (HermesKit/Pages/Goals/GoalViews.swift and GoalShelf.swift at
/// 93f984bb1, mirrored from Tests/Pages/GoalViewsTests and GoalShelfTests): decoding with and without `goals`, the ring's
/// fraction, the pace's words, the next task, the card and shelf lines, the groups and their folds.
public class GoalsTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    private static readonly DateTimeOffset Now = new(2026, 12, 14, 9, 41, 0, TimeSpan.FromHours(-6));

    private static Goal G(string json) => Goal.From(JsonNode.Parse(json))!;
    private static TodoTask T(string id, string goal, string? milestone = null, bool done = false, double position = 1) =>
        new(id) { Title = "Task " + id, Goal = goal, Milestone = milestone, Status = done ? "done" : "open", Position = position };

    [Fact]
    public void TheListAnswerReadsGoalsAndTheirAbsence()
    {
        var with = TodoListAnswer.From(JsonNode.Parse("""
            {"rev": 4, "tasks": [{"id": "t1", "title": "a", "goal": "g1", "milestone": "m1"}],
             "goals": [{"id": "g1", "title": "Run a 10K", "status": "paused", "color": "orange",
                        "milestones": [{"id": "m1", "title": "Run a 5K", "done": true}],
                        "measure": {"unit": "km", "start": 0, "target": 10}},
                       {"title": "no id"}, {"id": "g2", "status": "someday?", "color": "plaid"}]}
            """));
        Assert.NotNull(with.Goals);
        Assert.Equal(["g1", "g2"], with.Goals!.Select(g => g.Id));
        var run = with.Goals[0];
        Assert.Equal(GoalState.Paused, run.State);
        Assert.Equal("orange", run.Tint);
        Assert.True(run.Milestones[0].Done);
        Assert.Equal(0, run.Measure!.Now);   // `now` missing reads as the start
        Assert.Equal(GoalState.Active, with.Goals[1].State);   // an unknown status still shows
        Assert.Equal("blue", with.Goals[1].Tint);
        Assert.Equal("Untitled Goal", with.Goals[1].Shown);
        Assert.Equal("m1", with.Tasks![0].Milestone);
        Assert.Null(TodoListAnswer.From(JsonNode.Parse("""{"rev": 1, "tasks": []}""")).Goals);
        Assert.Equal(TodoView.Goals, TodoView.FromKey("goals"));
    }

    [Fact]
    public void TheRingNeverLies()
    {
        var measured = G("""{"id": "g", "measure": {"unit": "testers", "start": 0, "target": 1000, "now": 340}, "milestones": [{"id": "m", "done": false}]}""");
        Assert.Equal(0.34, GoalViews.Fraction(measured, [])!.Value, 3);
        var down = G("""{"id": "g", "measure": {"unit": "lbs", "start": 185, "target": 170, "now": 180}}""");
        Assert.Equal(1.0 / 3, GoalViews.Fraction(down, [])!.Value, 3);
        Assert.Equal("180, down to 170 lbs", GoalViews.MeasureWords(down.Measure!, unit: true));
        Assert.Equal(1.0, GoalViews.Fraction(new GoalMeasure("", 0, 10, 14)));
        var milestones = G("""{"id": "g", "milestones": [{"id": "a", "done": true}, {"id": "b"}, {"id": "c"}, {"id": "d"}]}""");
        Assert.Equal(0.25, GoalViews.Fraction(milestones, []));
        var tasks = G("""{"id": "g"}""");
        Assert.Equal(0.5, GoalViews.Fraction(tasks, [T("1", "g", done: true), T("2", "g"), T("3", "other")]));
        Assert.Null(GoalViews.Fraction(tasks, [T("3", "other")]));
        Assert.Equal("34%", GoalViews.Percent(0.349));
        Assert.Equal("$1,200", GoalViews.Number(1200, "$"));
        Assert.Equal("12.5", GoalViews.Number(12.5));
    }

    [Fact]
    public void PaceIsSaidInWords()
    {
        Assert.Equal("on pace", new GoalPace.OnPace().Words);
        Assert.Equal("ahead", new GoalPace.Ahead().Words);
        Assert.Equal("1 day behind", new GoalPace.Behind(1).Words);
        Assert.Equal("3 days behind", new GoalPace.Behind(3).Words);
        Assert.Equal("a week behind", new GoalPace.Behind(7).Words);
        Assert.Equal("a week behind", new GoalPace.Behind(13).Words);
        Assert.Equal("2 weeks behind", new GoalPace.Behind(14).Words);
        Assert.Equal("1 day late", new GoalPace.Late(1).Words);
        Assert.Equal("3 days late", new GoalPace.Late(3).Words);
        Assert.Equal(GoalPaceTone.Late, new GoalPace.Late(3).Tone);

        // 100 days, 50 gone: even is 50%. At 50% on pace, at 80% ahead, at 30% 20 days behind.
        string At(double now) => GoalViews.Pace(G($$"""{"id": "g", "created_at": "2026-10-25T09:00:00-05:00", "due": "2027-02-02", "measure": {"start": 0, "target": 100, "now": {{now}} } }"""), [], Now, Chicago)!.Words;
        Assert.Equal("on pace", At(52));
        Assert.Equal("ahead", At(80));
        Assert.Equal("2 weeks behind", At(30));
        var late = G("""{"id": "g", "created_at": "2026-10-01T09:00:00-05:00", "due": "2026-12-11"}""");
        Assert.Equal(new GoalPace.Late(3), GoalViews.Pace(late, [], Now, Chicago));
        // No date, paused, or no plan (not yet late): no pace.
        Assert.Null(GoalViews.Pace(G("""{"id": "g", "measure": {"target": 10}}"""), [], Now, Chicago));
        Assert.Null(GoalViews.Pace(G("""{"id": "g", "status": "paused", "due": "2026-12-01"}"""), [], Now, Chicago));
        Assert.Null(GoalViews.Pace(G("""{"id": "g", "created_at": "2026-12-01T09:00:00-06:00", "due": "2027-01-31"}"""), [], Now, Chicago));
    }

    [Fact]
    public void TheNextTaskIsTheOpenMilestonesFirstElseTheFirstLooseOne()
    {
        var goal = G("""{"id": "g", "milestones": [{"id": "m1", "done": true}, {"id": "m2"}, {"id": "m3"}]}""");
        List<TodoTask> tasks = [T("loose", "g", position: 0), T("m2b", "g", "m2", position: 3), T("m2a", "g", "m2", position: 2),
            T("m1a", "g", "m1", position: 1), T("m3a", "g", "m3", position: 0.5)];
        Assert.Equal("m2a", GoalViews.NextTask(goal, tasks)!.Id);
        tasks = [.. tasks.Select(t => t.Milestone == "m2" ? t with { Status = "done" } : t)];
        Assert.Equal("loose", GoalViews.NextTask(goal, tasks)!.Id);   // the open milestone's tasks done: the loose one
        Assert.Null(GoalViews.NextTask(goal, [.. tasks.Select(t => t with { Status = "done" })]));
    }

    [Fact]
    public void ACardsLineAndASomedayCardsStatus()
    {
        var testers = G("""{"id": "g", "title": "1,000 public testers", "due": "2027-01-31", "created_at": "2026-11-08T09:00:00-06:00", "measure": {"unit": "testers", "start": 0, "target": 1000, "now": 340}}""");
        Assert.Equal("340 of 1,000 · by Jan 31, 2027", GoalViews.Line(testers, [], Now, Chicago));
        Assert.Equal("340 · by Jan 31", GoalViews.ShortLine(testers, [], Now, Chicago));   // the shelf drops the year within 11 months
        var miles = G("""{"id": "g", "milestones": [{"id": "a", "done": true}, {"id": "b"}]}""");
        Assert.Equal("1 of 2 milestones", GoalViews.Line(miles, [], Now, Chicago));
        Assert.Equal("1 of 2", GoalViews.ShortLine(miles, [], Now, Chicago));
        var one = G("""{"id": "g"}""");
        Assert.Equal("0 of 1 task", GoalViews.Line(one, [T("1", "g")], Now, Chicago));
        Assert.Equal("No plan yet", GoalViews.Line(one, [], Now, Chicago));
        Assert.Equal("", GoalViews.ShortLine(one, [], Now, Chicago));
        var paused = G("""{"id": "g", "title": "Spanish", "status": "paused", "status_at": "2026-11-30T10:00:00-06:00"}""");
        Assert.Equal("Paused Nov 30", GoalViews.StatusLine(paused, Now, Chicago));
        var card = GoalCardModel.Make(paused, [T("1", "g")], Now, Chicago);
        Assert.Equal("Paused Nov 30", card.Line);
        Assert.True(card.Quiet);
        Assert.True(card.GreyRing);
        Assert.Null(card.NextId);   // only an active goal offers its next task
        Assert.Equal("goal-card-Spanish", card.AutomationId);
        Assert.Equal("Achieved Dec 20", GoalViews.StatusLine(G("""{"id": "g", "status": "achieved", "status_at": "2025-12-20T10:00:00-06:00"}"""), new DateTimeOffset(2025, 12, 22, 9, 0, 0, TimeSpan.FromHours(-6)), Chicago));
        Assert.Equal("Let go", GoalViews.StatusLine(G("""{"id": "g", "status": "let_go"}"""), Now, Chicago));
        Assert.Null(GoalViews.StatusLine(testers, Now, Chicago));
        Assert.Equal("1,000 public testers, 34 percent, next: Task 1",
            GoalViews.Spoken(testers with { Due = null }, [T("1", "g")], Now, Chicago));
    }

    [Fact]
    public void GroupsOrderAndFold()
    {
        Goal Make(string id, string status, double position, string? at = null) =>
            G($$"""{"id": "{{id}}", "status": "{{status}}", "position": {{position}}, "status_at": {{(at == null ? "null" : $"\"{at}\"")}}}""");
        var groups = GoalViews.Groups([Make("b", "active", 2), Make("a", "active", 1), Make("p", "paused", 1),
            Make("old", "achieved", 1, "2026-01-01T00:00:00Z"), Make("new", "achieved", 2, "2026-06-01T00:00:00Z"), Make("l", "let_go", 1)]);
        Assert.Equal(["a", "b"], groups.Active.Select(g => g.Id));
        Assert.Equal(["p"], groups.Someday.Select(g => g.Id));
        Assert.Equal(["new", "old"], groups.Achieved.Select(g => g.Id));   // latest first
        Assert.Equal(["l"], groups.LetGo.Select(g => g.Id));
        Assert.True(GoalViews.Groups([]).IsEmpty);
        Assert.Equal(2, GoalViews.ActiveCount([Make("b", "active", 2), Make("a", "active", 1), Make("p", "paused", 1)]));

        Assert.Equal(["Active", "Someday", "Achieved", "Let Go", "Goals"],
            new[] { GoalGroupKey.Active, GoalGroupKey.Someday, GoalGroupKey.Achieved, GoalGroupKey.LetGo, GoalGroupKey.Found }.Select(GoalViews.GroupTitle));
        Assert.Equal("goals.fold.letGo", GoalViews.FoldId(GoalGroupKey.LetGo));
        Assert.Equal("goals.fold.achieved", GoalViews.FoldId(GoalGroupKey.Achieved));
        Assert.False(GoalViews.HasHeading(GoalGroupKey.Active));
        Assert.True(GoalViews.HasHeading(GoalGroupKey.Someday));
        Assert.False(GoalViews.Folds(GoalGroupKey.Someday));
        Assert.Equal("Show", GoalViews.FoldWord(GoalGroupKey.Achieved, open: false));
        Assert.Equal("Hide", GoalViews.FoldWord(GoalGroupKey.LetGo, open: true));
        Assert.Null(GoalViews.FoldWord(GoalGroupKey.Someday, open: false));

        var found = GoalViews.Found([G("""{"id": "x", "title": "Run a 10K"}"""), G("""{"id": "y", "title": "Trip", "why": "a long RUN by the sea", "status": "paused"}""")], " run ");
        Assert.Equal(["x", "y"], found.Select(g => g.Id));
        Assert.Empty(GoalViews.Found([G("""{"id": "x", "title": "#run"}""")], "#run"));
    }

    [Fact]
    public void TheShelfShowsOnTodayWithAnActiveGoal()
    {
        Goal[] goals = [G("""{"id": "a", "title": "Trip", "position": 2}"""), G("""{"id": "p", "status": "paused"}"""), G("""{"id": "z", "title": "Testers", "position": 1, "measure": {"start": 0, "target": 10, "now": 5}}""")];
        Assert.True(GoalShelf.Shows(TodoView.Today, false, "all", true, goals));
        Assert.True(GoalShelf.Shows(TodoView.Today, false, "@me", true, goals));
        Assert.False(GoalShelf.Shows(TodoView.Today, false, "otto", true, goals));
        Assert.False(GoalShelf.Shows(TodoView.Upcoming, false, "all", true, goals));
        Assert.False(GoalShelf.Shows(TodoView.Goals, false, "all", true, goals));
        Assert.False(GoalShelf.Shows(TodoView.Today, true, "all", true, goals));
        Assert.False(GoalShelf.Shows(TodoView.Today, false, "all", false, goals));
        Assert.False(GoalShelf.Shows(TodoView.Today, false, "all", true, [goals[1]]));

        var cards = GoalShelf.Cards(goals, [T("1", "a", done: true), T("2", "a")], Now, Chicago);
        Assert.Equal(["z", "a"], cards.Select(c => c.Id));   // active only, your order
        Assert.Equal("Nothing next", cards[0].Next);   // a number and no task: nothing next
        Assert.Equal("Next: Task 2", cards[1].Next);
        Assert.Equal("1 of 2", cards[1].Line);
        Assert.Equal("No plan yet", GoalShelf.Card(G("""{"id": "n"}"""), [], Now, Chicago).Next);
        Assert.Equal("goal-shelf-Trip", cards[1].AutomationId);
        Assert.Equal("All 3", GoalShelf.AllWords(3));
        Assert.Equal(3, GoalShelf.HeadingCount(3, folded: true));
        Assert.Null(GoalShelf.HeadingCount(3, folded: false));
        Assert.Equal("3, hidden", GoalShelf.HeadingValue(3, folded: true));
        Assert.Equal("3, shown", GoalShelf.HeadingValue(3, folded: false));
    }

    [Fact]
    public void TheShelfsFoldIsKeptOnThisDeviceAndTintsAreTheListColours()
    {
        var prefs = new Hermes.Core.Composer.MemoryStore();
        var fold = new GoalShelfFold(prefs);
        Assert.False(fold.Folded);
        fold.Folded = true;
        Assert.True(new GoalShelfFold(prefs).Folded);
        Assert.Equal("true", prefs.Get("HQGoalShelfFolded"));
        fold.Folded = false;
        Assert.Null(prefs.Get("HQGoalShelfFolded"));
        Assert.Equal(((byte)0xFF, (byte)0x95, (byte)0x00), GoalTints.Rgb("orange"));
        Assert.Equal(GoalTints.Rgb("blue"), GoalTints.Rgb("plaid"));
    }
}
