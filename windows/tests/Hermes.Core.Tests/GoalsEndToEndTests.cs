using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-42] Tasks › Goals and Today's Goals shelf against ci/fixtures/pages-fixture-gateway.py with --task-goals
/// --task-lists (its five made-up goals): the store reads `goals`, the Goals view's groups and cards, the shelf's cards,
/// and a tick on a card's next task is one PATCH of that task (GoalsWalkProof, what the tasks-goals walk checks). An add-on
/// with no goals (the plain tasks stand-in) keeps its Goals pill, locked to the update ([WIN-47]); a search finds goals and
/// a row's Add to Goal is one PATCH of its goal and milestone. Run through windows/scripts/e2e.sh
/// (HQW_E2E_GOALS_CREDENTIALS, HQW_E2E_TASKS_CREDENTIALS); without them this passes vacuously.
[Trait("Category", "E2E")]
public class GoalsEndToEndTests
{
    private static async Task<JsonNode> Fixture(string url, string path, object? body = null)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var r = body == null ? await http.GetAsync(url.TrimEnd('/') + path)
            : await http.PostAsync(url.TrimEnd('/') + path, new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json"));
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync()) ?? new JsonObject();
    }

    private static async Task<(TasksStore Store, string Url, IDisposable Session)?> Open(string variable, bool reset)
    {
        var path = Environment.GetEnvironmentVariable(variable);
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        if (reset) await Fixture(url, "/__fixture/reset", new { });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        var store = new TasksStore(new TasksApi(new GatewaySessionRest(session)));
        await store.RefreshAsync(force: true);
        Assert.True(store.HasList, store.Error);
        return (store, url, session);
    }

    [Fact]
    public Task TheGoalsViewAndTheShelfReadTheStandInsGoalsAndATickIsOnePatch() => MainLoop.Drive(async () =>
    {
        if (await Open("HQW_E2E_GOALS_CREDENTIALS", reset: true) is not { } opened) return;
        var (store, url, session) = opened;
        using var _ = session;
        Assert.True(store.GoalsSupported);
        Assert.Equal(5, store.Goals.Count);
        Assert.Equal(3, GoalViews.ActiveCount(store.Goals));
        var now = DateTimeOffset.Now;
        var zone = TimeZoneInfo.Local;

        var groups = GoalViews.Groups(store.Goals);
        Assert.Equal(GoalsWalkProof.ActiveTitles, groups.Active.Select(g => g.Title));
        Assert.Equal(GoalsWalkProof.SomedayTitles, groups.Someday.Select(g => g.Title));
        Assert.Equal(GoalsWalkProof.AchievedTitles, groups.Achieved.Select(g => g.Title));
        Assert.Empty(groups.LetGo);
        var cards = groups.Active.Select(g => GoalCardModel.Make(g, store.Tasks, now, zone)).ToList();
        Assert.StartsWith("340 of 1,000 · by ", cards[0].Line);
        Assert.StartsWith("1 of 4 milestones · by ", cards[1].Line);
        Assert.StartsWith("4 of 6 tasks · by ", cards[2].Line);
        Assert.Equal(GoalsWalkProof.TripNext, cards[2].NextId);
        Assert.StartsWith("Paused ", GoalCardModel.Make(groups.Someday[0], store.Tasks, now, zone).Line);
        Assert.Null(GoalsWalkProof.CardsShown([.. cards.Select(c => c.AutomationId)], GoalsWalkProof.ActiveTitles));

        Assert.True(GoalShelf.Shows(TodoView.Today, false, "all", store.GoalsSupported, store.Goals));
        var shelf = GoalShelf.Cards(store.Goals, store.Tasks, now, zone);
        Assert.Equal(GoalsWalkProof.ShelfNext, shelf.Select(c => c.Next));
        Assert.StartsWith("340 · by ", shelf[0].Line);
        Assert.Null(GoalsWalkProof.CardsShown([.. shelf.Select(c => c.AutomationId)], GoalsWalkProof.ActiveTitles, "goal-shelf-"));

        // The card's circle ticks its next task, as a row's does: one PATCH, and the card's next moves on.
        var mark = WalkProof.RestCount(await Fixture(url, "/__fixture/state"));
        Assert.True(await store.SetDoneAsync(GoalsWalkProof.TripNext, true));
        Assert.Null(GoalsWalkProof.TickRecorded(await Fixture(url, "/__fixture/state"), mark, GoalsWalkProof.TripNext));
        Assert.NotNull(GoalsWalkProof.TickRecorded(await Fixture(url, "/__fixture/state"), mark, "t_other"));
        await store.RefreshAsync(force: true);
        var trip = store.FindGoal(GoalsWalkProof.TripGoal)!;
        Assert.Equal(GoalsWalkProof.TripAfter, GoalCardModel.Make(trip, store.Tasks, now, zone).NextTitle);
        Assert.StartsWith("5 of 6 tasks", GoalCardModel.Make(trip, store.Tasks, now, zone).Line);

        // New Goal: its name and why, POST /goals; the new goal is the last active card, with no plan yet.
        var made = await store.AddGoalAsync("  Plant a herb garden (goals e2e) ", "Fresh basil all summer.");
        Assert.NotNull(made);
        Assert.Null(store.AddGoalFailure);
        var post = (await Fixture(url, "/__fixture/state")).Arr("rest")!.Last(r => r.Str("method") == "POST")!;
        Assert.Equal(TasksApi.Route + "/goals", post.Str("path"));
        Assert.Equal("""{"title":"Plant a herb garden (goals e2e)","why":"Fresh basil all summer."}""", post["body"]!.ToJsonString());
        await store.RefreshAsync(force: true);
        var active = GoalViews.Groups(store.Goals).Active;
        Assert.Equal("Plant a herb garden (goals e2e)", active[^1].Title);
        Assert.Equal("No plan yet", GoalCardModel.Make(active[^1], store.Tasks, now, zone).Line);
        Assert.Null(await store.AddGoalAsync("   "));
        await Fixture(url, "/__fixture/reset", new { });
    });

    [Fact]
    public Task AnAddOnWithNoGoalsHasNoGoalsView() => MainLoop.Drive(async () =>
    {
        if (await Open("HQW_E2E_TASKS_CREDENTIALS", reset: false) is not { } opened) return;
        var (store, _, session) = opened;
        using var _ = session;
        Assert.False(store.GoalsSupported);
        Assert.Empty(store.Goals);
        Assert.False(GoalShelf.Shows(TodoView.Today, false, "all", store.GoalsSupported, store.Goals));
        // [WIN-47] [goals-addon] Its Goals pill stays, with no count, and the Goals view says to update the add-on; the
        // bar's + asks for the update there. No search finds goals, and no row has Add to Goal.
        Assert.True(store.GoalsNeedAddOn);
        Assert.Equal((true, (int?)null), GoalsAddOn.Pill(store.GoalsSupported, store.GoalsNeedAddOn, store.Goals));
        Assert.False(GoalsAddOn.FallsBack(TodoView.Goals, store.GoalsSupported, store.GoalsNeedAddOn));
        Assert.True(GoalsAddOn.Locked(TodoView.Goals, false, store.GoalsSupported));
        Assert.Equal("Update Add-on", GoalsAddOn.AddLabel(TodoView.Goals, store.GoalsNeedAddOn));
        Assert.Equal(GoalsAddAction.UpdateAddOn, GoalsAddOn.AddAction(TodoView.Goals, false, store.GoalsSupported, store.GoalsNeedAddOn));
        Assert.False(GoalViews.FindsGoals(store.GoalsSupported, "all"));
        Assert.Null(GoalChoices.Menu(store.Tasks[0], store.Goals, store.GoalsSupported));
    });

    [Fact]
    public Task ASearchFindsGoalsAndARowsAddToGoalIsOnePatch() => MainLoop.Drive(async () =>
    {
        if (await Open("HQW_E2E_GOALS_CREDENTIALS", reset: true) is not { } opened) return;
        var (store, url, session) = opened;
        using var _ = session;
        Assert.False(store.GoalsNeedAddOn);
        Assert.Equal("New Goal", GoalsAddOn.AddLabel(TodoView.Goals, store.GoalsNeedAddOn));

        // "coast": the trip's card in the search's Goals group, over the trip's tasks (found by their goal's name).
        Assert.True(GoalViews.FindsGoals(store.GoalsSupported, "all"));
        Assert.Equal(GoalsWalkProof.SearchCards, GoalViews.Found(store.Goals, GoalsWalkProof.SearchQuery).Select(g => g.Title));
        var found = TodoSections.Filtered(store.Tasks, GoalsWalkProof.SearchQuery, store.Goals);
        Assert.Contains(found, t => t.Id == GoalsWalkProof.SearchRow);
        Assert.All(found, t => Assert.Equal(GoalsWalkProof.TripGoal, t.Goal));
        Assert.Empty(TodoSections.Filtered(store.Tasks, GoalsWalkProof.SearchQuery));
        // [WIN-53] With the Goals pill still picked, the search's To Do lists them (the view's own groups have none).
        Assert.Empty(TodoViews.Groups(found, TodoView.Goals, store.Sections, [], DateTimeOffset.Now, TimeZoneInfo.Local));
        var toDo = TodoViews.SearchGroups(found, TimeZoneInfo.Local).Single(g => g.Kind == TodoGroupKind.Open);
        Assert.Contains(toDo.Tasks, t => t.Id == GoalsWalkProof.SearchRow);

        // Today's goal task carries its goal's mark; Add to Goal lists the active goals, then No Goal and Open Goal.
        var task = store.Find(GoalsWalkProof.MarkTask)!;
        Assert.Equal(GoalsWalkProof.MarkGoalTitle, GoalViews.MarkGoal(task, store.Goals)!.Title);
        var choices = GoalChoices.Menu(task, store.Goals, store.GoalsSupported)!;
        Assert.Equal(GoalsWalkProof.MarkChoices, choices.Select(c => c.Title));
        Assert.Contains(choices[0].Children, c => c.Ticked && c.Milestone == task.Milestone);
        var pick = choices.Single(c => c.Goal == GoalsWalkProof.MoveGoal && c.Kind == GoalChoiceKind.Goal);
        Assert.Empty(pick.Children);

        // The pick is one PATCH of the task with its goal and no milestone; the row's mark follows.
        var mark = WalkProof.RestCount(await Fixture(url, "/__fixture/state"));
        Assert.True(await store.SetGoalAsync(task.Id, pick.Goal, pick.Milestone));
        Assert.Null(GoalsWalkProof.GoalRecorded(await Fixture(url, "/__fixture/state"), mark, task.Id, GoalsWalkProof.MoveGoal, null));
        Assert.NotNull(GoalsWalkProof.GoalRecorded(await Fixture(url, "/__fixture/state"), mark, task.Id, GoalsWalkProof.MoveGoal, "ms_launch"));
        await store.RefreshAsync(force: true);
        var moved = store.Find(task.Id)!;
        Assert.Equal((GoalsWalkProof.MoveGoal, (string?)null), (moved.Goal, moved.Milestone));
        Assert.Equal(GoalsWalkProof.MoveGoalTitle, GoalViews.MarkGoal(moved, store.Goals)!.Title);
        Assert.Null(GoalsWalkProof.RowMarked("Post the build notes to the forum. Today, for " + GoalsWalkProof.MoveGoalTitle, GoalsWalkProof.MoveGoalTitle));

        // No Goal takes it out (and its mark away).
        Assert.True(await store.SetGoalAsync(task.Id, null, null));
        await store.RefreshAsync(force: true);
        Assert.Null(store.Find(task.Id)!.Goal);
        Assert.Null(GoalViews.MarkGoal(store.Find(task.Id)!, store.Goals));
        await Fixture(url, "/__fixture/reset", new { });
    });
}
