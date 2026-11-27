using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// Kanban and Tasks against ci/fixtures/pages-fixture-gateway.py (a copy of scripts/pages-fixture-gateway.py): the
/// board, a task's page, moves and their refusals, comments, Add Attachment, archive and its Undo, New Task, delete; the
/// shared to-do list's views, add, tick, the rev on every write and delete; the board picker against stand-ins started
/// with --many-boards 9 and 13 (HQW_E2E_BOARDS9_CREDENTIALS, HQW_E2E_BOARDS13_CREDENTIALS). Run through
/// windows/scripts/e2e.sh (HQW_E2E_PAGES_CREDENTIALS); without them these pass vacuously.
[Trait("Category", "E2E")]
[Collection(PagesStandIn.Name)]
public class KanbanEndToEndTests
{
    private static (string Url, string User, string Password)? Credentials(string variable = "HQW_E2E_PAGES_CREDENTIALS")
    {
        var path = Environment.GetEnvironmentVariable(variable);
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        return (cred.Str("url")!, cred.Str("username")!, cred.Str("password")!);
    }

    private static async Task Until(Func<Task<bool>> condition, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!await condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(100);
        }
    }

    private static async Task<JsonNode> Fixture(string url, string path, object? body = null)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var r = body == null ? await http.GetAsync(url.TrimEnd('/') + path)
            : await http.PostAsync(url.TrimEnd('/') + path, new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json"));
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync()) ?? new JsonObject();
    }

    private static async Task<GatewaySession> SignInAsync((string Url, string User, string Password) c) =>
        await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(c.Url), c.User, c.Password);

    [Fact]
    public Task TheBoardATaskMovesCommentsAttachmentsArchiveAndNewTask() => MainLoop.Drive(async () =>
    {
        if (Credentials() is not { } c) return;
        await Fixture(c.Url, "/__fixture/reset", new { });
        using var session = await SignInAsync(c);
        var api = new KanbanApi(new GatewaySessionRest(session));
        var store = new KanbanStore(api, session.Account.Key);
        var failures = new List<string>();
        store.WriteFailed += failures.Add;

        // Probe, the boards and the current board.
        Assert.Equal(KanbanAvailability.On, await KanbanProbe.ProbeAsync(api));
        await store.ReadBoardsAsync();
        Assert.Equal("release-2-4", store.Boards!.Current);
        Assert.Equal("Release 2.4", store.BoardTitle);
        Assert.Null(await store.ReadBoardAsync());
        var order = KanbanModel.ChipOrder(store.Board!.Columns.Select(col => col.Name));
        Assert.Equal(KanbanModel.StatusOrder, order);
        var demo = store.Board.AllTasks.Single(t => t.Title == "Record the export demo");
        Assert.Equal(("todo", "deploys", 1), (demo.Status, demo.Assignee, demo.CommentCount));
        await store.ReadProfilesAsync();
        Assert.Contains(store.Profiles, p => p.Name == "deploys");
        Assert.Equal(("", "default"), (store.Fallback, store.ResolvedDefault));

        // A task's page: its comment, attachment and activity.
        var detail = await api.TaskAsync(demo.Id, store.Slug);
        Assert.Equal("demo-script.txt", Assert.Single(detail.Attachments!).Filename);
        Assert.Single(detail.Comments);
        Assert.Equal("created in Todo · assigned to deploys", KanbanModel.EventText(detail.Events[0].Kind, detail.Events[0].Payload).Label);
        var download = Path.Combine(Path.GetTempPath(), "kanban-e2e-" + Guid.NewGuid().ToString("N"));
        await api.AttachmentAsync("a1", store.Slug, download);
        Assert.StartsWith("Open on the export menu.", File.ReadAllText(download));
        File.Delete(download);
        var blocked = store.Board.AllTasks.Single(t => t.Title == "Approve the 2.4 release notes");
        var blockedDetail = await api.TaskAsync(blocked.Id, "");
        Assert.Equal("Waiting on you", blockedDetail.Task.Diagnostics![0].Title);
        // [kanban markdown] A Markdown description arrives as written; the renderer gets it with its code untouched and
        // its plain lines kept apart; editing shows the raw text.
        var thread = store.Board.AllTasks.Single(t => t.Title == "Draft the launch thread");
        var threadBody = (await api.TaskAsync(thread.Id, store.Slug)).Task.Body!;
        Assert.StartsWith("## Launch thread\nFive posts, **short** and *friendly*. Start from `docs/launch.md`.\n\n- the export menu\n", threadBody);
        var shown = KanbanText.Description(threadBody, null);
        Assert.Equal(KanbanDescriptionMode.Markdown, shown.Mode);
        Assert.Contains("```sh\nmake thread-preview\n```\nPlain line one  \nPlain line two", shown.Text);
        Assert.Contains("1. [style guide](https://example.com/style)\n", shown.Text);
        Assert.Equal(threadBody, KanbanText.Description(threadBody, threadBody).Text);

        // A move shows at once and nudges the dispatcher; a refused one puts back only its task and says why.
        var dispatchBefore = (await Fixture(c.Url, "/__fixture/state")).Int("dispatch") ?? 0;
        await store.MoveAsync(demo, "ready");
        Assert.Empty(failures);
        await Until(async () => ((await Fixture(c.Url, "/__fixture/state")).Int("dispatch") ?? 0) > dispatchBefore);
        await Until(async () => { await store.ReadBoardAsync(); return store.Board!.Task(demo.Id)?.Status == "ready"; });
        var changelog = store.Board!.AllTasks.Single(t => t.Title == "Publish the 2.4 changelog");
        await store.MoveAsync(changelog, "ready");
        Assert.StartsWith("Cannot move to 'ready': blocked by parent(s) not done", Assert.Single(failures));
        Assert.Equal("todo", store.Board!.Task(changelog.Id)!.Status);

        // Assign, priority, comment, the estimate.
        await store.AssignAsync(store.Board.Task(demo.Id)!, "finance");
        await Until(async () => (await api.TaskAsync(demo.Id, "")).Task.Assignee == "finance");
        await api.PatchAsync(demo.Id, new JsonObject { ["priority"] = 5 }, "");
        await api.CommentAsync(demo.Id, "Keep the order from the changelog.", "");
        detail = await api.TaskAsync(demo.Id, "");
        Assert.Equal((5, 2), (detail.Task.Priority, detail.Comments.Count));
        Assert.Equal("desktop", detail.Comments[^1].Author);
        Assert.Equal("About 42K tokens · M", await api.EstimateAsync(demo.Id, ""));

        // Add Attachment: the file part alone, then the task lists it.
        var file = Path.Combine(Path.GetTempPath(), "brief-" + Guid.NewGuid().ToString("N") + ".md");
        File.WriteAllText(file, "# Brief\nShow Markdown, then JSON.\n");
        var scratch = Path.Combine(Path.GetTempPath(), "kanban-e2e-scratch-" + Guid.NewGuid().ToString("N"));
        var made = await api.AddAttachmentAsync(demo.Id, file, KanbanAttachmentUpload.SendName("C:\\docs\\brief.md"), "", scratch);
        Assert.Equal("brief.md", made!.Filename);
        Assert.Contains((await api.TaskAsync(demo.Id, "")).Attachments!, a => a.Filename == "brief.md");
        Assert.Empty(Directory.GetFiles(scratch));
        var gone = await Assert.ThrowsAsync<GatewayException>(() => api.AddAttachmentAsync("t_missing", file, "brief.md", "", scratch));
        Assert.Equal(("This task is no longer on the board.", true), KanbanAttachmentUpload.Reason(gone));
        File.Delete(file);

        // Archive leaves the board; Undo puts it back where it was.
        await store.ReadBoardAsync();
        var done = store.Board!.AllTasks.First(t => t.Status == "done");
        var left = await store.ArchiveAsync(done);
        Assert.Equal("", left);
        Assert.Null(store.Board!.Task(done.Id));
        await Until(async () => { await store.ReadBoardAsync(); return store.Board!.Task(done.Id) == null; });
        Assert.Null(await store.UnarchiveAsync(done, "done", left!));
        Assert.Equal("done", store.Board!.Task(done.Id)!.Status);

        // New Task on another board, in Ready, then deleted.
        await store.ReadBoardsAsync();
        store.Select("home");
        await Until(async () => { await Task.Yield(); return store.Board?.AllTasks.Any(t => t.Title == "Cover the tomatoes") == true; });
        var warning = await store.CreateAsync("Water the tomatoes", "Every morning.", "default", 2, [], "ready", false);
        Assert.Null(warning);
        await Until(async () => { await store.ReadBoardAsync(); return store.Board!.AllTasks.Any(t => t.Title == "Water the tomatoes"); });
        var water = store.Board!.AllTasks.Single(t => t.Title == "Water the tomatoes");
        Assert.Equal(("ready", "default", 2), (water.Status, water.Assignee, water.Priority));
        var post = (await Fixture(c.Url, "/__fixture/state")).Arr("rest")!.Last(r => r.Str("method") == "POST" && r.Str("path") == "/api/plugins/kanban/tasks");
        Assert.Equal("home", post.Obj("query").Arr("board")?[0]?.GetValue<string>() ?? post.Obj("query").Str("board"));
        Assert.True(await store.DeleteAsync(water));
        await Until(async () => { await store.ReadBoardAsync(); return store.Board!.Task(water.Id) == null; });
        Assert.Single(failures);
    });

    [Fact]
    public Task TheSharedToDoListViewsAddTickAndDelete() => MainLoop.Drive(async () =>
    {
        if (Credentials() is not { } c) return;
        await Fixture(c.Url, "/__fixture/reset", new { });
        using var session = await SignInAsync(c);
        var store = new TasksStore(new TasksApi(new GatewaySessionRest(session)));
        var notices = new List<string>();
        store.Notice += (text, _) => notices.Add(text);
        await store.RefreshAsync();
        Assert.True(store.HasList, store.Error);
        Assert.False(store.NeedsAddOn);
        var dentist = store.Find("t_dentist")!;
        Assert.Equal(("Call the dentist", TodoWho.Together, "ready"), (dentist.Title, dentist.WhoKind, dentist.Status));
        var zone = TimeZoneInfo.Local;
        var now = DateTimeOffset.Now;
        var today = TodoViews.Groups(store.Tasks, TodoView.Today, store.Sections, [], now, zone);
        Assert.Contains(today.SelectMany(g => g.Tasks), t => t.Id == "t_dentist");
        Assert.Equal("Hermes: Number and a Dec 9 slot",
            TodoViews.Row(dentist, TodoGroupKind.Today, now, zone, p => p is null or "default" ? "Hermes" : p).Note);

        // Add, tick (with the task's rev), open again, delete.
        var made = await store.AddAsync(TodoWire.NewTask("Buy stamps", TodoWho.Me, null, TodoDates.Wire(now, false), null, false));
        Assert.NotNull(made);
        Assert.False(TodoIds.IsLocal(made!.Id));
        Assert.Contains(TodoViews.Groups(store.Tasks, TodoView.Today, store.Sections, [], now, zone).SelectMany(g => g.Tasks), t => t.Id == made.Id);
        Assert.True(await store.SetDoneAsync(made.Id, true));
        Assert.Equal("done", store.Find(made.Id)!.Status);
        Assert.True(store.Find(made.Id)!.Rev > made.Rev);
        var patch = (await Fixture(c.Url, "/__fixture/state")).Arr("rest")!.Last(r => r.Str("method") == "PATCH");
        Assert.Equal(made.Rev, (int)(patch.Obj("body").Int("rev") ?? -1));
        await store.RefreshAsync(force: true);
        Assert.Equal("done", store.Find(made.Id)!.Status);
        Assert.True(await store.SetDoneAsync(made.Id, false));
        Assert.True(await store.DeleteAsync(made.Id));
        await store.RefreshAsync(force: true);
        Assert.Null(store.Find(made.Id));
        Assert.Empty(notices);
    });

    /// Sort By and Select against the add-on stand-in: the sort is kept in the Tasks settings on the gateway (a new
    /// store reads it back), each sort orders a list's open tasks, a drag sets the position between the new neighbours,
    /// and Select's Move To, Mark Done and Delete reach the gateway.
    [Fact]
    public Task TasksSortByPersistsAndSelectMovesMarksAndDeletes() => MainLoop.Drive(async () =>
    {
        if (Credentials() is not { } c) return;
        await Fixture(c.Url, "/__fixture/reset", new { });
        using var session = await SignInAsync(c);
        var api = new TasksApi(new GatewaySessionRest(session));
        var store = new TasksStore(api);
        var notices = new List<string>();
        store.Notice += (text, _) => notices.Add(text);
        await store.RefreshAsync();
        Assert.True(store.HasList, store.Error);
        Assert.Equal("smart", store.Settings.Sort);
        Assert.True(store.FieldsSupported && store.SectionsSupported);
        Assert.Equal(["smart", "due", "priority", "added"], TodoSortBy.Options(store.FieldsSupported, store.Settings.Sort).Select(o => o.Key));

        // A list of its own (PUT /tasks/sections, as New List does) and three tasks moved into it in this order.
        await api.Rest.JsonAsync(HttpMethod.Put, TasksApi.Base + "/sections", body: new JsonObject
        {
            ["sections"] = new JsonArray([.. store.Sections.Select(s => (JsonNode)new JsonObject { ["id"] = s.Id, ["name"] = s.Name }),
                new JsonObject { ["id"] = "", ["name"] = "Errands (sort e2e)" }]),
        });
        await store.RefreshAsync(force: true);
        var list = store.Sections.Single(s => s.Name == "Errands (sort e2e)").Id;
        var now = DateTimeOffset.Now;
        var zone = TimeZoneInfo.Local;
        async Task<string> Add(string title, string? due, int priority)
        {
            var fields = TodoWire.NewTask(title, TodoWho.Me, null, due, null, false);
            fields["priority"] = priority;
            var id = (await store.AddAsync(fields))!.Id;
            await Task.Delay(1100);   // the stand-in stamps created_at to the second: Date Added needs them apart
            return id;
        }
        var undated = await Add("Return the library books", null, 2);
        var later = await Add("Renew the parking permit", TodoDates.Wire(now.AddDays(9), false), 0);
        var soon = await Add("Pick up the dry cleaning", TodoDates.Wire(now.AddDays(2), false), 1);
        Assert.True(await store.MoveAsync([undated, later, soon], list));
        string[] Open() => [.. TodoViews.Groups(store.Tasks, TodoView.List(list), store.Sections, [], DateTimeOffset.Now, zone, store.Settings.Sort)
            .First(g => g.Kind == TodoGroupKind.Open).Tasks.Select(t => t.Id)];
        await store.RefreshAsync(force: true);
        Assert.Equal([undated, later, soon], Open());

        // Due Date: saved on the gateway, read back by a new store; soonest first, undated last.
        Assert.True(await store.SetSortAsync("due"));
        var put = (await Fixture(c.Url, "/__fixture/state")).Arr("rest")!.Last(r => r.Str("method") == "PUT" && r.Str("path") == TasksApi.Base + "/settings");
        Assert.Equal("due", put.Obj("body").Str("sort"));
        var again = new TasksStore(new TasksApi(new GatewaySessionRest(session)));
        await again.RefreshAsync();
        Assert.Equal("due", again.Settings.Sort);
        Assert.Equal([soon, later, undated], Open());
        Assert.True(await store.SetSortAsync("priority"));
        Assert.Equal([soon, undated, later], Open());
        Assert.True(await store.SetSortAsync("added"));
        Assert.Equal([soon, later, undated], Open());

        // A drag in Date Added still saves the place (and the page says why the row went back); My Order shows it.
        Assert.NotNull(TodoArrange.SortedNotice(store.Settings.Sort));
        Assert.True(await store.SetSortAsync("smart"));
        Assert.Equal([undated, later, soon], Open());
        var position = TodoArrange.DropPosition(Open(), soon, 0, store.Find, DateTimeOffset.Now);
        Assert.True(await store.MoveAsync([soon], list, position));
        await store.RefreshAsync(force: true);
        Assert.Equal([soon, undated, later], Open());

        // Select: pick two, Move To No List, Mark Done, then Delete them.
        var pick = new TodoSelection();
        pick.Start();
        pick.Toggle(later);
        pick.Toggle(undated);
        var ids = pick.SelectedIds(id => store.Find(id) != null);
        Assert.Equal([later, undated], ids);
        Assert.Equal(list, TodoSelection.MoveTick(ids, store.Find));
        Assert.True(await store.MoveAsync(ids, null));
        await store.RefreshAsync(force: true);
        Assert.Equal([soon], Open());
        Assert.Equal("", TodoSelection.MoveTick(ids, store.Find));
        foreach (var id in TodoSelection.ToMarkDone(ids, store.Find)) Assert.True(await store.SetDoneAsync(id, true));
        Assert.Empty(TodoSelection.ToMarkDone(ids, store.Find));
        Assert.Equal("Delete 2 Tasks?", TodoSelection.DeleteTitle(ids.Count));
        foreach (var id in ids) Assert.True(await store.DeleteAsync(id));
        Assert.True(pick.End());
        await store.RefreshAsync(force: true);
        Assert.All(ids, id => Assert.Null(store.Find(id)));
        Assert.True(await store.DeleteAsync(soon));
        Assert.Empty(notices);
    });

    // ------------------------------------------------------------------ the board picker (8 menu, 9 list, 13 search)

    /// Every GET of a board on the wire, with the board it asked for ('' = the server's current one).
    private static async Task<List<string>> BoardReads(string url)
    {
        var reads = new List<string>();
        foreach (var r in (await Fixture(url, "/__fixture/state")).Arr("rest") ?? [])
        {
            if (r is null || r.Str("method") != "GET" || r.Str("path") != "/api/plugins/kanban/board") continue;
            var q = r.Obj("query");
            reads.Add(q.Arr("board")?[0]?.GetValue<string>() ?? q.Str("board") ?? "");
        }
        return reads;
    }

    /// What KanbanPage.PickBoard does with a pick (KanbanViewController.swift `pickBoard`): the open board does nothing.
    private static bool Pick(KanbanStore store, string slug)
    {
        if (!KanbanBoardPicker.Switches(slug, store.BoardKey)) return false;
        store.Select(slug);
        return true;
    }

    /// A pick reads the new board (a GET for it on the wire) and the store shows it; picking it again reads nothing.
    private static async Task PickSwitchesAndPickingCurrentDoesNothing(string url, KanbanStore store, string slug, string title)
    {
        var before = (await BoardReads(url)).Count;
        Assert.True(Pick(store, slug));
        await Until(async () => (await BoardReads(url)).Skip(before).Contains(slug));
        await Until(async () => { await Task.Yield(); return store.Board != null && store.BoardKey == slug; });
        Assert.Equal(title, store.BoardTitle);
        var list = new KanbanBoardList(store.Boards!.Boards, store.BoardKey);
        Assert.Equal(slug, Assert.Single(list.Shown, b => b.IsCurrent).Slug);

        var settled = (await BoardReads(url)).Count;
        Assert.False(Pick(store, slug));
        await Task.Delay(1500);
        Assert.Equal(settled, (await BoardReads(url)).Count);
        Assert.Equal(slug, store.BoardKey);
    }

    [Fact]
    public Task EightBoardsAreAMenuNineAreTheBoardsListWithoutSearch() => MainLoop.Drive(async () =>
    {
        if (Credentials("HQW_E2E_BOARDS9_CREDENTIALS") is not { } c) return;
        await Fixture(c.Url, "/__fixture/reset", new { });
        using var session = await SignInAsync(c);
        var store = new KanbanStore(new KanbanApi(new GatewaySessionRest(session)), session.Account.Key);
        try
        {
            // Eight boards (the same stand-in re-seeded): the pop-up menu, every board in it.
            Assert.Equal(8, (await Fixture(c.Url, "/__fixture/many-boards", new { count = 8 })).Int("boards"));
            await store.ReadBoardsAsync();
            Assert.Equal(8, store.Boards!.Boards.Count);
            Assert.Equal(KanbanBoardPickerStyle.Menu, store.BoardPickerStyle);
            Assert.Equal(8, store.BoardChoices.Count);
            Assert.Equal("Release 2.4  ·  14 tasks", store.BoardChoices[0].MenuText);
            Assert.True(store.BoardChoices[0].IsCurrent);
        }
        finally { await Fixture(c.Url, "/__fixture/reset", new { }); }

        // Nine (as started, --many-boards 9): the pushed Boards list, no search, in the server's order with totals.
        await store.ReadBoardsAsync();
        Assert.Equal(KanbanBoardPickerStyle.List, store.BoardPickerStyle);
        var list = new KanbanBoardList(store.Boards!.Boards, store.BoardKey);
        Assert.Equal("Boards", list.Title);
        Assert.False(list.HasSearch);
        Assert.Equal(["release-2-4", "home", "garden", "launch-plan", "reading-list", "bakery-orders", "bike-repairs", "podcast", "studio-move"],
            list.Shown.Select(b => b.Slug));
        Assert.Equal(["Release 2.4", "Home", "Garden", "Launch Plan", "Reading List", "Bakery Orders", "Bike Repairs", "Podcast", "Studio Move"],
            list.Shown.Select(b => b.Title));
        Assert.Equal(["14 tasks", "3 tasks", "2 tasks", "3 tasks", "0 tasks", "1 task", "2 tasks", "3 tasks", "0 tasks"],
            list.Shown.Select(b => b.Subtitle));
        Assert.Equal("release-2-4", Assert.Single(list.Shown, b => b.IsCurrent).Slug);

        // The open board read first; picking it does nothing; another board is read and shown.
        Assert.Null(await store.ReadBoardAsync());
        Assert.Contains(store.Board!.AllTasks, t => t.Title == "Record the export demo");
        var settled = (await BoardReads(c.Url)).Count;
        Assert.False(Pick(store, "release-2-4"));
        await Task.Delay(1500);
        Assert.Equal(settled, (await BoardReads(c.Url)).Count);
        await PickSwitchesAndPickingCurrentDoesNothing(c.Url, store, "bakery-orders", "Bakery Orders");
        Assert.Equal(["Bakery Orders: step 1"], store.Board!.AllTasks.Select(t => t.Title));
    });

    [Fact]
    public Task ThirteenBoardsAreTheBoardsListWithSearch() => MainLoop.Drive(async () =>
    {
        if (Credentials("HQW_E2E_BOARDS13_CREDENTIALS") is not { } c) return;
        await Fixture(c.Url, "/__fixture/reset", new { });
        using var session = await SignInAsync(c);
        var store = new KanbanStore(new KanbanApi(new GatewaySessionRest(session)), session.Account.Key);
        await store.ReadBoardsAsync();
        Assert.Equal(13, store.Boards!.Boards.Count);
        Assert.Equal(KanbanBoardPickerStyle.List, store.BoardPickerStyle);
        var list = new KanbanBoardList(store.Boards.Boards, store.BoardKey);
        Assert.True(list.HasSearch);
        Assert.Equal(13, list.Shown.Count);
        Assert.Equal(["Tax Prep", "Recipes", "Band Practice", "Trip Planning"], list.Shown.Skip(9).Select(b => b.Title));

        // The search: trimmed, any case, inside the read name; nothing found is an empty list; no words is every board.
        list.Search("plan");
        Assert.Equal(["launch-plan", "trip-planning"], list.Shown.Select(b => b.Slug));
        list.Search("  PLAN ");
        Assert.Equal(["Launch Plan", "Trip Planning"], list.Shown.Select(b => b.Title));
        list.Search("zzz");
        Assert.Empty(list.Shown);
        list.Search("");
        Assert.Equal(13, list.Shown.Count);

        // A pick from the filtered list switches the board on the wire; picking the open board after does nothing.
        list.Search("plan");
        Assert.Null(await store.ReadBoardAsync());
        await PickSwitchesAndPickingCurrentDoesNothing(c.Url, store, list.Shown[1].Slug, "Trip Planning");
        Assert.Empty(store.Board!.AllTasks);
        // And back to the server's current board, read as '' (the store keeps no slug for it).
        var before = (await BoardReads(c.Url)).Count;
        Assert.True(Pick(store, "release-2-4"));
        await Until(async () => (await BoardReads(c.Url)).Skip(before).Contains(""));
        await Until(async () => { await Task.Yield(); return store.Board?.AllTasks.Any(t => t.Title == "Record the export demo") == true; });
        Assert.Equal("Release 2.4", store.BoardTitle);
    });
}
