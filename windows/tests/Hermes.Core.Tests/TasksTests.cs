using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// The Tasks page's views (HermesKit TodoViews; Tests/Pages/TodoViewsTests.swift): which tasks each view shows and in
/// what order, and a row's words.
public class TodoViewsTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    /// Wednesday 2026-11-04, 09:41 in Chicago.
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 9, 41, 0, TimeSpan.FromHours(-6));

    internal static TodoTask Task(string id, string who = "me", string? bot = null, string status = "open", string note = "",
        string? due = null, string? section = null, bool[]? steps = null, string notes = "", string? repeats = null,
        string updated = "2026-11-04T08:00:00-06:00", string created = "2026-11-03T08:00:00-06:00", string? doneAt = null,
        string? by = null, double position = 0, string[]? tags = null)
    {
        var o = new JsonObject
        {
            ["id"] = id, ["rev"] = 1, ["title"] = id, ["who"] = who, ["status"] = status, ["status_note"] = note, ["updated_at"] = updated,
            ["created_at"] = created, ["notes"] = notes, ["position"] = position,
            ["steps"] = new JsonArray([.. (steps ?? []).Select((d, i) => (JsonNode)new JsonObject { ["id"] = $"s{i}", ["title"] = "x", ["who"] = "me", ["done"] = d })]),
        };
        if (bot != null) o["bot"] = bot;
        if (due != null) o["due"] = due;
        if (section != null) o["section"] = section;
        if (repeats != null) o["repeat"] = repeats;
        if (doneAt != null) o["done_at"] = doneAt;
        if (by != null) o["created_by"] = by;
        if (tags != null) o["tags"] = new JsonArray([.. tags.Select(t => (JsonNode)t)]);
        return TodoTask.From(o)!;
    }

    private static readonly TodoUserSection[] Lists = [new("work", "Work"), new("home", "Home")];

    private static List<(string Kind, string[] Ids)> Groups(IReadOnlyList<TodoTask> tasks, TodoView view, string sort = "smart") =>
        [.. TodoViews.Groups(tasks, view, Lists, ["default", "finance", "research"], Now, Chicago, sort).Select(g => (g.Kind.Key, g.Tasks.Select(t => t.Id).ToArray()))];

    private static string Name(string? profile) => (profile ?? "default") switch
    {
        "default" => "Hermes", "finance" => "Finance", "research" => "Research", var p => p,
    };

    private static readonly TodoTask[] List =
    [
        Task("late", due: "2026-11-01"),
        Task("cleaning", due: "2026-11-04T18:00:00-06:00"),
        Task("apps", due: "2026-11-04T17:00:00-06:00", section: "work"),
        Task("dentist", who: "together", bot: "default", status: "ready", note: "Number and a Dec 9 slot", due: "2026-11-04"),
        Task("passport", who: "together", bot: "default", status: "working", due: "2026-11-04"),
        Task("contract", who: "together", bot: "default", status: "ready", due: "2026-11-05T10:00:00-06:00", updated: "2026-11-04T09:00:00-06:00"),
        Task("venues", who: "bot", bot: "research", status: "needs_you", note: "What’s the budget?", due: "2026-11-08", updated: "2026-11-04T09:30:00-06:00"),
        Task("invoices", who: "bot", bot: "finance", status: "working", note: "3 of 5 accounts", due: "2026-11-04"),
        Task("report", who: "bot", bot: "finance", due: "2026-11-06"),
        Task("gift", who: "together", bot: "default", due: "2026-11-12"),
        Task("porch"),
        Task("desk", section: "home"),
        Task("water", status: "done", due: "2026-11-04", doneAt: "2026-11-04T08:10:00-06:00"),
        Task("flights", status: "done", section: "work", doneAt: "2026-11-01T08:10:00-06:00"),
        Task("ledger", who: "bot", bot: "finance", status: "done", doneAt: "2026-11-04T07:00:00-06:00"),
    ];

    [Fact]
    public void TodayIsYourDayThenWhatWaitsOnYou()
    {
        var today = Groups(List, TodoView.Today);
        Assert.Equal(["overdue", "today", "waiting", "next:home", "done"], today.Select(g => g.Kind));
        Assert.Equal(["late"], today[0].Ids);
        Assert.Equal(["dentist", "passport", "apps", "cleaning"], today[1].Ids);
        Assert.Equal(["venues", "contract"], today[2].Ids);
        Assert.Equal(["desk"], today[3].Ids);
        Assert.Equal(["water"], today[4].Ids);
    }

    [Fact]
    public void ABotsOwnTaskStaysOutOfYourDay()
    {
        var today = Groups(List, TodoView.Today).SelectMany(g => g.Ids).ToList();
        Assert.DoesNotContain("invoices", today);
        Assert.Contains("venues", today);
        Assert.DoesNotContain("report", Groups(List, TodoView.Upcoming).SelectMany(g => g.Ids));
        Assert.DoesNotContain("report", Groups(List, TodoView.Inbox).SelectMany(g => g.Ids));
    }

    [Fact]
    public void UpcomingIsEachComingDay()
    {
        var upcoming = Groups(List, TodoView.Upcoming);
        Assert.Equal(["day:2026-11-05", "day:2026-11-08", "day:2026-11-12"], upcoming.Select(g => g.Kind));
        Assert.Equal([["contract"], ["venues"], ["gift"]], upcoming.Select(g => g.Ids));
    }

    [Fact]
    public void InboxIsWhatHasNoList()
    {
        HashSet<string> loose = ["late", "cleaning", "dentist", "passport", "contract", "gift", "porch"];
        var inbox = Groups([.. List, Task("orphan", section: "gone"),
            Task("stale", updated: "2026-10-10T08:00:00-05:00", created: "2026-10-10T08:00:00-05:00", by: "default")], TodoView.Inbox);
        Assert.Equal(["open", "stale", "done"], inbox.Select(g => g.Kind));
        Assert.True(inbox[0].Ids.ToHashSet().SetEquals(loose.Append("orphan")));
        Assert.Equal(["stale"], inbox[1].Ids);
        Assert.Equal(["water"], inbox[2].Ids);
    }

    [Fact]
    public void AListIsItsTasksInYourOrder()
    {
        var work = Groups(List, TodoView.List("work"));
        Assert.Equal(["open", "done"], work.Select(g => g.Kind));
        Assert.Equal(["apps"], work[0].Ids);
        Assert.Equal(["flights"], work[1].Ids);
        TodoTask[] ordered = [Task("b", section: "work", position: 2), Task("a", due: "2026-11-09", section: "work", position: 1),
            Task("c", due: "2026-11-05", section: "work", position: 3)];
        Assert.Equal(["a", "b", "c"], Groups(ordered, TodoView.List("work"))[0].Ids);
        Assert.Equal(["c", "a", "b"], Groups(ordered, TodoView.List("work"), "due")[0].Ids);
    }

    [Fact]
    public void BotsIsWhatEachDoesByItself()
    {
        var bots = Groups(List, TodoView.Bots);
        Assert.Equal(["bot:finance", "bot:research", "done"], bots.Select(g => g.Kind));
        Assert.Equal(["invoices", "report"], bots[0].Ids);
        Assert.Equal(["ledger"], bots[2].Ids);
        Assert.True(TodoViews.ShowsBots(List));
        Assert.False(TodoViews.ShowsBots(List.Where(t => t.WhoKind != TodoWho.Bot)));
    }

    [Fact]
    public void NoOpenTaskIsLostAndThePillsCount()
    {
        TodoView[] views = [TodoView.Today, TodoView.Upcoming, TodoView.Inbox, TodoView.List("work"), TodoView.List("home"), TodoView.Bots];
        var shown = views.SelectMany(v => Groups(List, v).Where(g => g.Kind != "done").SelectMany(g => g.Ids)).ToHashSet();
        Assert.True(shown.SetEquals(List.Where(t => !t.IsDone).Select(t => t.Id)));
        int Count(TodoView v) => TodoViews.OpenCount(List, v, Lists, Now, Chicago);
        Assert.Equal(7, Count(TodoView.Today));
        Assert.Equal(3, Count(TodoView.Upcoming));
        Assert.Equal(7, Count(TodoView.Inbox));
        Assert.Equal(1, Count(TodoView.List("work")));
        Assert.Equal(3, Count(TodoView.Bots));
        Assert.Equal(TodoView.List("abc"), TodoView.FromKey("list:abc"));
        Assert.Null(TodoView.FromKey("list:"));
    }

    private static TodoRowWords Row(TodoTask task, TodoGroupKind kind) => TodoViews.Row(task, kind, Now, Chicago, Name);

    [Fact]
    public void ARowSaysWhen()
    {
        Assert.Equal("5:00 PM", Row(Task("a", due: "2026-11-04T17:00:00-06:00"), TodoGroupKind.Today).When);
        Assert.Null(Row(Task("a", due: "2026-11-04"), TodoGroupKind.Today).When);
        var late = Row(Task("a", due: "2026-11-01"), TodoGroupKind.Overdue);
        Assert.True(late.When == "Nov 1" && late.Late);
        Assert.Equal("Yesterday", Row(Task("a", due: "2026-11-03"), TodoGroupKind.Overdue).When);
        Assert.Equal("9:00 AM", Row(Task("a", due: "2026-11-06T09:00:00-06:00"), TodoGroupKind.Day("2026-11-06")).When);
        var today = Row(Task("a", due: "2026-11-04T17:00:00-06:00"), TodoGroupKind.Open);
        Assert.True(today.When == "5:00 PM" && today.Late);
        Assert.Equal("Today", Row(Task("a", due: "2026-11-04"), TodoGroupKind.Open).When);
        Assert.Equal("Tomorrow", Row(Task("a", due: "2026-11-05"), TodoGroupKind.Open).When);
        Assert.Equal("Mon", Row(Task("a", due: "2026-11-09"), TodoGroupKind.Open).When);
        var far = Row(Task("a", due: "2026-11-16"), TodoGroupKind.Open);
        Assert.True(far.When == "Nov 16" && !far.Late);
        Assert.Null(Row(Task("a"), TodoGroupKind.Open).When);
        Assert.Equal("Today", Row(Task("a", status: "done", due: "2026-11-01", doneAt: "2026-11-04T08:00:00-06:00"), TodoGroupKind.Done).When);
        var words = Row(Task("a", steps: [true, true, false, false], repeats: "weekly", tags: ["hiring", "q4", "x"]), TodoGroupKind.Open);
        Assert.True(words.Steps == "2/4" && words.Repeats);
        Assert.Equal(["hiring", "q4"], words.Tags);
    }

    [Fact]
    public void TheSecondLineIsOnlyWhatABotHasForYou()
    {
        var working = Row(Task("a", who: "together", bot: "default", status: "working", note: "Filling in the form"), TodoGroupKind.Today);
        Assert.True(working.Note == null && working.Dot == "working");
        var ready = Row(Task("a", who: "together", bot: "default", status: "ready", note: "Number and a Dec 9 slot"), TodoGroupKind.Today);
        Assert.True(ready.Note == "Hermes: Number and a Dec 9 slot" && ready.Tone == TodoTone.Ready && ready.Dot == "ready");
        Assert.Equal("Hermes finished its part", Row(Task("a", who: "together", bot: "default", status: "ready"), TodoGroupKind.Today).Note);
        var asks = Row(Task("a", who: "bot", bot: "research", status: "needs_you", note: "What’s the budget?"), TodoGroupKind.Waiting);
        Assert.True(asks.Note == "Research asks: What’s the budget?" && asks.Tone == TodoTone.NeedsYou && asks.Dot == "question");
        Assert.Equal("Research needs you: Send the reply to Lee",
            Row(Task("a", who: "bot", bot: "research", status: "needs_you", note: "Send the reply to Lee"), TodoGroupKind.Waiting).Note);
        Assert.Equal("Research needs you", Row(Task("a", who: "bot", bot: "research", status: "needs_you"), TodoGroupKind.Waiting).Note);
        Assert.Equal("3 of 5 accounts", Row(Task("a", who: "bot", bot: "finance", status: "working", note: "3 of 5 accounts"), TodoGroupKind.Bot("finance")).Note);
        Assert.Equal("Added by Hermes · Oct 20", Row(Task("a", created: "2026-10-20T08:00:00-05:00", by: "default"), TodoGroupKind.Stale).Note);
    }

    [Fact]
    public void HeadingsAndEmptyWords()
    {
        Assert.Equal("Overdue", TodoViews.Heading(TodoGroupKind.Overdue, Now, Chicago, Lists, Name)?.Title);
        Assert.Equal("Waiting on You", TodoViews.Heading(TodoGroupKind.Waiting, Now, Chicago, Lists, Name)?.Title);
        Assert.Null(TodoViews.Heading(TodoGroupKind.Open, Now, Chicago, Lists, Name));
        Assert.Equal("Finance", TodoViews.Heading(TodoGroupKind.Bot("finance"), Now, Chicago, Lists, Name)?.Title);
        Assert.Equal("Next in Work", TodoViews.Heading(TodoGroupKind.Next("work"), Now, Chicago, Lists, Name)?.Title);
        Assert.Equal(("Tomorrow", "Thu, Nov 5"), TodoViews.DayHeading("2026-11-05", Now, Chicago));
        Assert.Equal(("Sat, Nov 7", null), TodoViews.DayHeading("2026-11-07", Now, Chicago));
        Assert.Equal("No tasks in Work yet.", TodoViews.EmptyText(TodoView.List("work"), "Work"));
        Assert.Equal("Nothing due today.", TodoViews.EmptyText(TodoView.Today, null));
        Assert.Equal("You & Hermes", TodoViews.Who(Task("a", who: "together", bot: "default"), Name));
        Assert.Equal("Finance", TodoViews.Who(Task("a", who: "bot", bot: "finance"), Name));
        Assert.Equal(("Has a question", TodoTone.NeedsYou), TodoViews.BotState(Task("a", who: "bot", bot: "research", status: "needs_you")));
        Assert.Null(TodoViews.BotState(Task("a")));
        Assert.Equal("Work", TodoViews.ListTitle(Task("a", section: "work"), Lists));
        Assert.Equal("No List", TodoViews.ListTitle(Task("a"), Lists));
        Assert.Equal("Task", TodoViews.ListTitle(Task("a"), []));
        Assert.Equal(["hiring", "q4"], TodoViews.TagsFrom("#hiring, q4, HIRING,  "));
        Assert.Equal("Today, 5:00 PM", TodoWords.DueTile(Task("a", due: "2026-11-04T17:00:00-06:00"), Now, Chicago));
        Assert.Equal("None", TodoWords.DueTile(Task("a"), Now, Chicago));
    }

    [Fact]
    public void DatesGoOnTheWireAsTheAddOnTakesThem()
    {
        var at = new DateTimeOffset(2026, 11, 5, 17, 0, 0, TimeSpan.FromHours(-6));
        Assert.Equal("2026-11-05", TodoDates.Wire(at, false, Chicago));
        Assert.Equal("2026-11-05T17:00:00-06:00", TodoDates.Wire(at, true, Chicago));
        Assert.Equal(new DateTimeOffset(2026, 11, 5, 0, 0, 0, TimeSpan.FromHours(-6)), TodoDates.Due("2026-11-05", Chicago)!.Value.Date);
        Assert.False(TodoDates.Due("2026-11-05", Chicago)!.Value.HasTime);
        Assert.True(TodoDates.Due("2026-11-05T17:00:00Z", Chicago)!.Value.HasTime);
        Assert.Null(TodoDates.Due("someday", Chicago));
    }
}

/// The store: a 409 sends the change again on the current rev, or shows the other edit; a failed tick comes back.
public class TasksStoreTests
{
    private static JsonNode Record<T>(List<T> list, T item, JsonNode answer) { list.Add(item); return answer; }

    private static JsonNode TaskJson(string id, int rev, string status = "open", string title = "Call the dentist") =>
        new JsonObject { ["id"] = id, ["rev"] = rev, ["title"] = title, ["who"] = "me", ["status"] = status };

    [Fact]
    public async Task AConflictOnOtherFieldsIsSentAgainOnTheCurrentRev()
    {
        var patches = new List<JsonNode>();
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", TasksApi.Base) => new JsonObject { ["rev"] = 5, ["tasks"] = new JsonArray(TaskJson("t1", 1), new JsonObject { ["bad"] = 1 }), ["sections"] = new JsonArray() },
            ("PATCH", _) when r.Body!.Int("rev") == 1 => throw new Net.GatewayException("http", "409", 409,
                new JsonObject { ["detail"] = new JsonObject { ["task"] = TaskJson("t1", 2, title: "Call the dentist today") } }.ToJsonString()),
            ("PATCH", _) => Record(patches, r.Body!, TaskJson("t1", 3, "done", "Call the dentist today")),
            _ => new JsonObject(),
        });
        var store = new TasksStore(new TasksApi(rest));
        await store.RefreshAsync();
        Assert.Single(store.Tasks);
        Assert.True(store.HasList);
        Assert.True(await store.SetDoneAsync("t1", true));
        Assert.Equal("""{"status":"done","rev":2}""", Assert.Single(patches).ToJsonString());
        Assert.Equal(("done", 3), (store.Find("t1")!.Status, store.Find("t1")!.Rev));
        // The next read asks only for what changed.
        await store.RefreshAsync();
        Assert.Equal("5", rest.Log.Last(r => r.Method == "GET").Query["since"]);
    }

    [Fact]
    public async Task AConflictOnTheSameFieldShowsTheirsAndAFailedTickComesBack()
    {
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", TasksApi.Base) => new JsonObject { ["rev"] = 5, ["tasks"] = new JsonArray(TaskJson("t1", 1), TaskJson("t2", 1)) },
            ("PATCH", "/api/plugins/hermes-hq-push/tasks/t1") => throw new Net.GatewayException("http", "409", 409,
                new JsonObject { ["detail"] = new JsonObject { ["task"] = TaskJson("t1", 2, "done") } }.ToJsonString()),
            ("PATCH", _) => throw FakeRest.Http(500, "disk full"),
            ("DELETE", _) => throw FakeRest.Http(500, "busy"),
            _ => new JsonObject(),
        });
        var store = new TasksStore(new TasksApi(rest));
        var notices = new List<string>();
        store.Notice += (text, _) => notices.Add(text);
        await store.RefreshAsync();
        Assert.False(await store.PatchAsync("t1", new JsonObject { ["status"] = "done" }));
        Assert.Equal("done", store.Find("t1")!.Status);
        Assert.False(await store.SetDoneAsync("t2", true));
        Assert.Equal("open", store.Find("t2")!.Status);
        Assert.False(await store.DeleteAsync("t2"));
        Assert.NotNull(store.Find("t2"));
        Assert.Equal([TasksCopy.ChangedElsewhere, "Couldn’t save the change. disk full", "Couldn’t delete the task. busy"], notices);
    }

    [Fact]
    public async Task AnAddShowsAtOnceThenTakesTheGatewaysTask()
    {
        var seen = new List<int>();
        TasksStore? store = null;
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("POST", TasksApi.Base) => Record(seen, store!.Tasks.Count, TaskJson("t_new", 1, title: "Buy milk")),
            _ => new JsonObject(),
        });
        store = new TasksStore(new TasksApi(rest));
        var made = await store.AddAsync(TodoWire.NewTask("Buy milk", TodoWho.Me, null, "2026-11-05", null, false));
        Assert.Equal([1], seen);
        Assert.Equal("t_new", made!.Id);
        Assert.Equal(["t_new"], store.Tasks.Select(t => t.Id));
        var body = rest.Log.Single(r => r.Method == "POST").Body!;
        Assert.Equal(("Buy milk", "me", "2026-11-05", "app"), (body.Str("title"), body.Str("who"), body.Str("due"), body.Obj("source").Str("kind")));
        Assert.Null(body.Get("bot"));
        var together = TodoWire.NewTask("Plan", TodoWho.Together, null, null, "weekly", true);
        Assert.Equal(("together", "default", true), (together.Str("who"), together.Str("bot"), together.Bool("prep")));
        Assert.Null(together.Get("repeat"));
    }

    [Fact]
    public async Task AnAddOnWithoutTasksAsksForTheUpdate()
    {
        var rest = new FakeRest(r => r.Path switch
        {
            TasksApi.Base => throw FakeRest.Http(404, "Not Found"),
            "/api/plugins/hermes-hq-push/status" => new JsonObject { ["seal"] = true },
            _ => new JsonObject(),
        });
        var store = new TasksStore(new TasksApi(rest));
        await store.RefreshAsync();
        Assert.True(store.NeedsAddOn);
        Assert.Null(store.Error);
        Assert.Equal("Tasks needs Hermes HQ Add-on 0.9.32 or later on the computer running Hermes.", TasksCopy.UpdateAddOnText(Gateways.HostWord.Phrase));
    }
}
