using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// Sort By and Select on the Tasks page (App/Pages/Tasks/TasksViewController.swift `menuItems`, "MARK: Select", "MARK:
/// Drag a task up or down its list"; HermesKit TodoModel.swift `TodoSettings` / `TodoSections.ordered` / `position`,
/// TasksStore.swift `setLayout` / `move` / `saveSettings`; Tests/Pages/TasksTests.swift, TodoFieldsTests.swift).
public class TodoSortByTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 9, 41, 0, TimeSpan.FromHours(-6));
    private static TodoTask T(string id, string? due = null, double position = 0, int priority = 0, string created = "2026-11-03T08:00:00-06:00",
        string? section = "work", string status = "open")
    {
        var o = new JsonObject { ["id"] = id, ["title"] = id, ["status"] = status, ["created_at"] = created, ["position"] = position, ["priority"] = priority };
        if (due != null) o["due"] = due;
        if (section != null) o["section"] = section;
        return TodoTask.From(TodoEdits.Reparse(o))!;   // read as the gateway's JSON is
    }

    [Fact]
    public void TheMenuIsMyOrderDueDatePriorityDateAddedInAListOnly()
    {
        // In a list on an add-on that keeps fields (0.9.53): the four, in the Mac's order, with My Order the default.
        Assert.Equal([("smart", "My Order"), ("due", "Due Date"), ("priority", "Priority"), ("added", "Date Added")],
            TodoSortBy.Options(fieldsSupported: true, current: "smart").Select(o => (o.Key, o.Title)));
        // An older add-on: no Priority, unless it is the sort already in force.
        Assert.Equal(["smart", "due", "added"], TodoSortBy.Options(fieldsSupported: false, current: "due").Select(o => o.Key));
        Assert.Equal(["smart", "due", "priority", "added"], TodoSortBy.Options(fieldsSupported: false, current: "priority").Select(o => o.Key));
        Assert.Equal("Sort By", TodoSortBy.Title);
        Assert.Equal("My Order", TodoSortBy.Subtitle("smart"));
        Assert.Equal("Date Added", TodoSortBy.Subtitle("added"));
        Assert.Null(TodoSortBy.Subtitle("sections"));
        Assert.Equal("smart", new TodoSettings().Sort);
        Assert.Equal("smart", TodoSettings.From(new JsonObject()).Sort);
        // "A list is in your order until you say otherwise": Sort By shows in a list's view, never elsewhere.
        Assert.True(TodoSortBy.Shows(TodoView.List("work")));
        foreach (var v in new[] { TodoView.Today, TodoView.Upcoming, TodoView.Inbox, TodoView.Bots }) Assert.False(TodoSortBy.Shows(v));
        Assert.Equal("Select Tasks", TodoSelection.MenuTitle);
        Assert.Equal("Select", TodoSelection.RowMenuTitle);
    }

    [Fact]
    public void EachSortOrdersAListsOpenTasks()
    {
        var tasks = new[]
        {
            T("none", position: 1), T("low", position: 2, priority: 3), T("high-b", position: 4, priority: 1),
            T("medium", position: 3, priority: 2), T("high-a", position: 0.5, priority: 1),
        };
        string[] Open(string sort, IEnumerable<TodoTask> items) =>
            [.. TodoViews.Groups([.. items], TodoView.List("work"), [new("work", "Work")], [], Now, Chicago, sort).First(g => g.Kind == TodoGroupKind.Open).Tasks.Select(t => t.Id)];
        Assert.Equal(["high-a", "high-b", "medium", "low", "none"], Open("priority", tasks));
        Assert.Equal(["high-a", "none", "low", "medium", "high-b"], Open("smart", tasks));
        // Due: soonest first, undated last; a tie keeps your order (position, then id).
        var dated = new[] { T("b", position: 2), T("a", due: "2026-11-09", position: 1), T("c", due: "2026-11-05", position: 3),
            T("c2", due: "2026-11-05", position: 0.5), T("z", position: 2) };
        Assert.Equal(["c2", "c", "a", "b", "z"], Open("due", dated));
        // A time on the same day comes after the day itself (a day is its start).
        Assert.Equal(["day", "five"], Open("due", [T("five", due: "2026-11-05T17:00:00-06:00", position: 0), T("day", due: "2026-11-05", position: 9)]));
        // Date Added: newest first, ties by id from the end.
        Assert.Equal(["new", "old-b", "old-a"], Open("added", [T("old-a", created: "2026-11-01T08:00:00-06:00"),
            T("new", created: "2026-11-04T08:00:00-06:00"), T("old-b", created: "2026-11-01T08:00:00-06:00")]));
        // Unknown words read as My Order; an older add-on's task with no position sits at its added time.
        Assert.Equal(["high-a", "none", "low", "medium", "high-b"], Open("sections", tasks));
        // Sort By orders a list's open tasks alone: Today's "Next in Work" keeps your order whatever the sort.
        var next = TodoViews.Groups([T("x", position: 2, priority: 1), T("y", position: 1)], TodoView.Today, [new("work", "Work")], [], Now, Chicago, "priority");
        Assert.Equal(["y", "x"], next.Single(g => g.Kind.IsNext).Tasks.Select(t => t.Id));
        // Done stays newest done first in every sort.
        var done = TodoViews.Groups([T("d1", status: "done", position: 1), T("o", position: 5)], TodoView.List("work"), [new("work", "Work")], [], Now, Chicago, "due");
        Assert.Equal(["open", "done"], done.Select(g => g.Kind.Key));
    }

    [Fact]
    public void ADragLandsHalfwayBetweenItsNewNeighbours()
    {
        TodoTask a = T("a", position: 10), b = T("b", position: 20);
        // TodoSections.position(between:and:) (TasksTests.swift: 15, 21, 9; none: now).
        Assert.Equal(15, TodoSections.Position(b, a, Now));
        Assert.Equal(11, TodoSections.Position(a, null, Now));
        Assert.Equal(19, TodoSections.Position(null, b, Now));
        Assert.Equal(Now.ToUnixTimeMilliseconds() / 1000.0, TodoSections.Position(null, null, Now));
        var c = T("c", position: 30);
        var find = new Dictionary<string, TodoTask> { ["a"] = a, ["b"] = b, ["c"] = c };
        // Dropped at index 0 (above a), c sits before a; dropped at 3 (the end), a sits after c.
        Assert.Equal(9, TodoArrange.DropPosition(["a", "b", "c"], "c", 0, id => find.GetValueOrDefault(id), Now));
        Assert.Equal(31, TodoArrange.DropPosition(["a", "b", "c"], "a", 3, id => find.GetValueOrDefault(id), Now));
        // Down one place: from 0 to the slot under b (index 2): halfway between b and c.
        Assert.Equal(25, TodoArrange.DropPosition(["a", "b", "c"], "a", 2, id => find.GetValueOrDefault(id), Now));
        // Past the end clamps.
        Assert.Equal(31, TodoArrange.DropPosition(["a", "b", "c"], "b", 99, id => find.GetValueOrDefault(id), Now));
        // Only in a list, not searching, not selecting, and a gateway that takes writes.
        Assert.True(TodoArrange.CanArrange(TodoView.List("work"), searching: false, selecting: false, readOnly: false));
        Assert.False(TodoArrange.CanArrange(TodoView.Today, false, false, false));
        Assert.False(TodoArrange.CanArrange(TodoView.List("work"), true, false, false));
        Assert.False(TodoArrange.CanArrange(TodoView.List("work"), false, true, false));
        Assert.False(TodoArrange.CanArrange(TodoView.List("work"), false, false, true));
        // A drag in another sort still saves the place, and says why the row doesn't stay there.
        Assert.Null(TodoArrange.SortedNotice("smart"));
        Assert.Equal("Sorted by Due Date. Choose My Order in Sort By to arrange tasks by hand.", TodoArrange.SortedNotice("due"));
        Assert.Equal("Sorted by Priority. Choose My Order in Sort By to arrange tasks by hand.", TodoArrange.SortedNotice("priority"));
        Assert.Equal("Sorted by Date Added. Choose My Order in Sort By to arrange tasks by hand.", TodoArrange.SortedNotice("added"));
        Assert.Equal(4, TodoArrange.NoticeSeconds);
    }

    [Fact]
    public void SettingsGoBackWholeAsTheMacEncodesThem()
    {
        var read = TodoSettings.From(JsonNode.Parse("""
            {"enabled":true,"capture":"auto","prep_per_day":4,"quiet_start":"21:00","quiet_end":"07:00","prep_every_hours":2,
             "group":"sections","sort":"due","ideas":true,"ideas_bot":"finance","ideas_at":"07:30","ideas_max":3,"extra":1}
            """));
        Assert.Equal("""{"enabled":true,"capture":"auto","prep_per_day":4,"quiet_start":"21:00","quiet_end":"07:00","prep_every_hours":2,"group":"sections","sort":"priority","ideas":true,"ideas_bot":"finance","ideas_at":"07:30","ideas_max":3}""",
            (read with { Sort = "priority" }).Wire().ToJsonString());
        // An older add-on's settings (no ideas): nothing about ideas is sent back; missing fields go as the Mac's defaults.
        Assert.Equal("""{"enabled":true,"capture":"ask","prep_per_day":6,"quiet_start":"22:00","quiet_end":"08:00","prep_every_hours":3,"group":"smart","sort":"added"}""",
            (TodoSettings.From(new JsonObject()) with { Sort = "added" }).Wire().ToJsonString());
    }
}

public class TodoSelectionTests
{
    private static TodoTask T(string id, string? section = null, string status = "open") =>
        TodoTask.From(new JsonObject { ["id"] = id, ["title"] = id, ["status"] = status, ["section"] = section })!;

    [Fact]
    public void PicksInTheOrderTappedAndTheBarFollowsTheCount()
    {
        var s = new TodoSelection();
        Assert.False(s.Active);
        Assert.False(s.CanAct(0, readOnly: false));
        s.Start();
        Assert.True(s.Active);
        s.Toggle("b"); s.Toggle("a"); s.Toggle("c"); s.Toggle("a");
        Assert.Equal(["b", "c"], s.Picked);
        Assert.True(s.IsPicked("b") && !s.IsPicked("a"));
        // A task gone from the list since it was picked doesn't count.
        var live = new HashSet<string> { "c", "x" };
        Assert.Equal(["c"], s.SelectedIds(live.Contains));
        Assert.True(s.CanAct(1, readOnly: false));
        Assert.False(s.CanAct(1, readOnly: true));
        Assert.False(s.CanAct(0, readOnly: false));
        // Start again (already on) keeps the picks; Done ends it and forgets them.
        s.Start();
        Assert.Equal(["b", "c"], s.Picked);
        Assert.True(s.End());
        Assert.False(s.Active);
        Assert.Empty(s.Picked);
        Assert.False(s.End());
        // A row's Select: Select mode on, that row picked.
        s.StartWith("z");
        Assert.Equal(["z"], s.Picked);
    }

    [Fact]
    public void EscDecidesNothingWhileSelectingAndKeepsThePicks()
    {
        // The Mac's Escape while selecting: `[keys] escape: nothing`; only Done, an action or leaving the page ends Select.
        var s = new TodoSelection();
        Assert.Equal(TodoSelection.EscapeAction.CloseTask, s.OnEscape());
        s.Start();
        s.Toggle("a"); s.Toggle("b");
        Assert.Equal(TodoSelection.EscapeAction.Nothing, s.OnEscape());
        Assert.True(s.Active);
        Assert.Equal(["a", "b"], s.Picked);
        Assert.Equal(TodoSelection.EscapeAction.Nothing, s.OnEscape());
        Assert.Equal(["a", "b"], s.Picked);
        Assert.True(s.End());
        Assert.Equal(TodoSelection.EscapeAction.CloseTask, s.OnEscape());
    }

    [Fact]
    public void TheBarsWordsAndWhatEachActionTakes()
    {
        Assert.Equal(["Done", "Delete", "Mark Done", "Move To"], TodoSelection.BarOrder);
        Assert.Equal("Delete 1 Task?", TodoSelection.DeleteTitle(1));
        Assert.Equal("Delete 3 Tasks?", TodoSelection.DeleteTitle(3));
        var tasks = new[] { T("a", "work"), T("b", "work"), T("c"), T("d", status: "done") };
        TodoTask? Find(string id) => tasks.FirstOrDefault(t => t.Id == id);
        // Mark Done skips what is done already.
        Assert.Equal(["a", "c"], TodoSelection.ToMarkDone(["a", "d", "c"], Find));
        // Move To's tick: the one list every picked task is in ("" for No List); none when they differ.
        Assert.Equal("work", TodoSelection.MoveTick(["a", "b"], Find));
        Assert.Equal("", TodoSelection.MoveTick(["c"], Find));
        Assert.Null(TodoSelection.MoveTick(["a", "c"], Find));
        Assert.Null(TodoSelection.MoveTick([], Find));
        Assert.Equal("Move To", TasksCopy.MoveTo);
    }
}

public class TasksOrganizeStoreTests
{
    private static JsonNode TaskJson(string id, int rev, string? section = null, double position = 0) =>
        new JsonObject { ["id"] = id, ["rev"] = rev, ["title"] = id, ["who"] = "me", ["status"] = "open", ["section"] = section, ["position"] = position };

    [Fact]
    public async Task SortBySavesTheWholeSettingsAndComesBackWhenRefused()
    {
        var fail = false;
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", TasksApi.Base) => new JsonObject
            {
                ["rev"] = 3, ["tasks"] = new JsonArray(), ["sections"] = new JsonArray(),
                ["settings"] = new JsonObject { ["enabled"] = true, ["capture"] = "auto", ["sort"] = "smart", ["group"] = "smart" },
            },
            ("PUT", TasksApi.Base + "/settings") when fail => throw FakeRest.Http(500, "disk full"),
            ("PUT", TasksApi.Base + "/settings") => r.Body,
            _ => new JsonObject(),
        });
        var store = new TasksStore(new TasksApi(rest));
        var notices = new List<string>();
        store.Notice += (text, _) => notices.Add(text);
        await store.RefreshAsync();
        Assert.True(await store.SetSortAsync("smart"));
        Assert.DoesNotContain(rest.Log, r => r.Method == "PUT");   // nothing to change is not a failure, and sends nothing
        Assert.True(await store.SetSortAsync("due"));
        var put = rest.Log.Single(r => r.Method == "PUT").Body!;
        Assert.Equal(("due", "auto", 6), (put.Str("sort"), put.Str("capture"), (int)(put.Int("prep_per_day") ?? 0)));
        Assert.Equal("due", store.Settings.Sort);
        fail = true;
        var seen = new List<string>();
        store.Changed += () => seen.Add(store.Settings.Sort);
        Assert.False(await store.SetSortAsync("added"));
        Assert.Equal("added", seen.First());   // shown at once
        Assert.Equal("due", store.Settings.Sort);   // and back when refused
        Assert.Equal(["Couldn’t save Tasks settings. disk full"], notices);
        store.ReadOnlyGateway = true;
        Assert.False(await store.SetSortAsync("priority"));
        Assert.Equal(KanbanRest.ReadOnlyNotice, notices.Last());
    }

    [Fact]
    public async Task MoveToPutsTasksAtTheEndOfTheListInTheOrderGiven()
    {
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", TasksApi.Base) => new JsonObject
            {
                ["rev"] = 3, ["tasks"] = new JsonArray(TaskJson("t1", 1), TaskJson("t2", 1, "home", 7), TaskJson("t3", 1, "home", 40)),
                ["sections"] = new JsonArray(new JsonObject { ["id"] = "home", ["name"] = "Home" }),
            },
            ("PATCH", var p) when p.EndsWith("/t3") => throw FakeRest.Http(422, "Not now"),
            ("PATCH", var p) => TaskJson(p[(p.LastIndexOf('/') + 1)..], 2, r.Body!.Str("section") ?? "home", r.Body!.Num("position") ?? 0),
            _ => new JsonObject(),
        });
        var store = new TasksStore(new TasksApi(rest));
        await store.RefreshAsync();
        Assert.True(store.SectionsSupported);
        // t2 is in Home already: it moves to the end with no section field; t1 gets the section.
        Assert.True(await store.MoveAsync(["t1", "t2"], "home"));
        var patches = rest.Log.Where(r => r.Method == "PATCH").ToList();
        Assert.Equal("""{"position":41,"section":"home","rev":1}""", patches.Single(p => p.Path.EndsWith("/t1")).Body!.ToJsonString());
        Assert.Equal("""{"position":42,"rev":1}""", patches.Single(p => p.Path.EndsWith("/t2")).Body!.ToJsonString());
        // One refused: false (the notice has said why).
        Assert.False(await store.MoveAsync(["t3", "t1"], null));
        // A drag: the one task at the position given.
        Assert.True(await store.MoveAsync(["t1"], "home", 8.5));
        Assert.Equal(8.5, rest.Log.Last(r => r.Method == "PATCH").Body!.Num("position"));
    }

    [Fact]
    public async Task AnAddOnWithNoListsCantMove()
    {
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", TasksApi.Base) => new JsonObject { ["rev"] = 3, ["tasks"] = new JsonArray(TaskJson("t1", 1)) },
            _ => new JsonObject(),
        });
        var store = new TasksStore(new TasksApi(rest));
        var notices = new List<string>();
        store.Notice += (text, _) => notices.Add(text);
        await store.RefreshAsync();
        Assert.False(store.SectionsSupported);
        Assert.False(await store.MoveAsync(["t1"], "home"));
        Assert.Equal(["Sections need the newest HQ add-on on your computer (0.9.36 or later)."], notices);
        Assert.DoesNotContain(rest.Log, r => r.Method == "PATCH");
    }
}
