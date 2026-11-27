using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Kanban;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// A stand-in for the gateway's REST: answers by method and path, keeps a log of what was asked.
internal sealed class FakeRest(Func<FakeRest.Request, JsonNode?> answer) : IPagesRest
{
    public sealed record Request(string Method, string Path, Dictionary<string, string> Query, JsonNode? Body);
    public List<Request> Log { get; } = [];
    public List<(string Path, string ContentType, byte[] Body)> Uploads { get; } = [];
    public Func<Request, string>? UploadAnswer { get; set; }

    public static GatewayException Http(int status, string? detail) =>
        new("http", $"The gateway answered {status}.", status, detail == null ? null : new JsonObject { ["detail"] = detail }.ToJsonString());

    public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var r = new Request(method.Method, path, (query ?? []).ToDictionary(k => k.Key, k => k.Value), body == null ? null : JsonNode.Parse(body.ToJsonString()));
        lock (Log) Log.Add(r);
        try { return Task.FromResult(answer(r) is { } a ? JsonNode.Parse(a.ToJsonString()) : null); }
        catch (Exception e) { return Task.FromException<JsonNode?>(e); }
    }

    public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
        TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default)
    {
        var r = new Request("UPLOAD", path, (query ?? []).ToDictionary(k => k.Key, k => k.Value), null);
        lock (Log) Log.Add(r);
        Uploads.Add((path, contentType, File.ReadAllBytes(bodyFile)));
        try { return Task.FromResult(UploadAnswer?.Invoke(r) ?? "{}"); }
        catch (Exception e) { return Task.FromException<string>(e); }
    }

    public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling, CancellationToken ct = default)
    {
        File.WriteAllText(file, "downloaded");
        return Task.CompletedTask;
    }
}

public class KanbanModelTests
{
    private static KanbanTask T(string id, string title, string status, string? body = null) => new(id, title, status) { Body = body };

    private static readonly KanbanBoard Board = new([
        new KanbanColumn("triage", []),
        new KanbanColumn("todo", [T("t_1", "Write the brief", "todo")]),
        new KanbanColumn("blocked", [T("t_2", "Fix scene picker", "blocked", "needs the room list")]),
        new KanbanColumn("done", [T("t_3", "Old", "done")]),
    ]);

    private static Dictionary<string, string> WhereIs(KanbanBoard b) =>
        b.Columns.SelectMany(c => c.Tasks.Select(t => (t.Id, c.Name))).ToDictionary(x => x.Id, x => x.Name);

    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    private static DateTimeOffset At(int y, int m, int d, int h) => new(new DateTime(y, m, d, h, 0, 0), Chicago.GetUtcOffset(new DateTime(y, m, d, h, 0, 0)));

    [Fact]
    public void StatusHeadingHasNoFullStop()
    {
        Assert.Equal("2 Tasks · Waiting on something, often you", KanbanModel.GroupHeading(2, "blocked"));
        Assert.Equal("1 Task · Finished. The result is on the task", KanbanModel.GroupHeading(1, "done"));
        Assert.Equal("3 Tasks", KanbanModel.GroupHeading(3, "parked"));
        Assert.Equal("Waiting on something, often you.", KanbanModel.StatusHelp["blocked"]);
    }

    [Fact]
    public void PutsBlockedFirstThenWorkflowOrderThenStatusesTheBackendAdds() =>
        Assert.Equal(["blocked", "triage", "todo", "ready", "running", "done", "parked"],
            KanbanModel.ChipOrder(["triage", "todo", "ready", "running", "blocked", "done", "archived", "parked"]));

    [Fact]
    public void OpensOnTheFirstStatusWithWorkDoneOnlyWhenNothingElseHasAny()
    {
        Assert.Equal("todo", KanbanModel.DefaultStatus(["blocked", "todo", "done"], new Dictionary<string, int> { ["blocked"] = 0, ["todo"] = 2, ["done"] = 9 }));
        Assert.Equal("done", KanbanModel.DefaultStatus(["blocked", "todo", "done"], new Dictionary<string, int> { ["done"] = 9 }));
        Assert.Equal("blocked", KanbanModel.DefaultStatus(["blocked", "todo"], new Dictionary<string, int>()));
    }

    [Fact]
    public void CountsAndSearchesAcrossTitleDescriptionAndId()
    {
        Assert.Equal(new Dictionary<string, int> { ["triage"] = 0, ["todo"] = 1, ["blocked"] = 1, ["done"] = 1 }, KanbanModel.StatusCounts(Board));
        Assert.Equal(new Dictionary<string, int> { ["triage"] = 0, ["todo"] = 0, ["blocked"] = 1, ["done"] = 0 },
            KanbanModel.StatusCounts(KanbanModel.Filter(Board, "room LIST")));
        Assert.Equal(1, KanbanModel.StatusCounts(KanbanModel.Filter(Board, "t_3"))["done"]);
        Assert.Same(Board, KanbanModel.Filter(Board, "  "));
    }

    [Fact]
    public void MovesAndRemovesCardsInASnapshot()
    {
        var moved = KanbanModel.MoveCard(Board, "t_2", "todo");
        Assert.Equal(["t_2/todo", "t_1/todo"], moved.Columns.First(c => c.Name == "todo").Tasks.Select(t => $"{t.Id}/{t.Status}"));
        Assert.Empty(moved.Columns.First(c => c.Name == "blocked").Tasks);
        Assert.Same(Board, KanbanModel.MoveCard(Board, "missing", "todo"));
        Assert.Empty(KanbanModel.RemoveCard(Board, "t_1").Columns[1].Tasks);
    }

    [Fact]
    public void GroupsDoneByWhenItFinished()
    {
        var now = At(2026, 9, 3, 12);
        double When(int y, int m, int d) => At(y, m, d, 9).ToUnixTimeSeconds();
        Assert.Equal("Today", KanbanModel.DoneGroup(When(2026, 9, 3), now, Chicago));
        Assert.Equal("Yesterday", KanbanModel.DoneGroup(When(2026, 9, 2), now, Chicago));
        Assert.Equal("This Week", KanbanModel.DoneGroup(When(2026, 8, 29), now, Chicago));
        Assert.Equal("June", KanbanModel.DoneGroup(When(2026, 6, 5), now, Chicago));
        Assert.Equal("December 2025", KanbanModel.DoneGroup(When(2025, 12, 1), now, Chicago));
        Assert.Equal("Earlier", KanbanModel.DoneGroup(null, now, Chicago));
        Assert.Equal(["1:2", "2:1", "1:1"], KanbanModel.GroupBy([1, 1, 2, 1], x => x.ToString()).Select(g => $"{g.Heading}:{g.Items.Count}"));
    }

    [Fact]
    public void SaysAgesBlockReasonsAndQuickMovesInWords()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        double s = 1_800_000_000;
        Assert.Equal("now", KanbanModel.ShortAge(s - 30, now));
        Assert.Equal("1h", KanbanModel.ShortAge(s - 90 * 60, now));
        Assert.Equal("3d", KanbanModel.ShortAge(s - 3 * 86_400, now));
        Assert.Equal("3mo", KanbanModel.ShortAge(s - 119 * 86_400, now));
        Assert.Equal("", KanbanModel.ShortAge(null, now));
        Assert.Equal("Needs your input", KanbanModel.BlockReason("needs_input"));
        Assert.Equal("Needs you", KanbanModel.BlockReason(null));
        Assert.Equal(("ready", "Unblock"), KanbanModel.QuickMove("blocked"));
        Assert.Equal(("ready", "Reopen"), KanbanModel.QuickMove("done"));
        Assert.Equal(("ready", "Mark Ready"), KanbanModel.QuickMove("todo"));
        Assert.Null(KanbanModel.QuickMove("running"));
        Assert.Equal("3h ago", KanbanModel.Ago(s - 3 * 3600 - 5, now));
        Assert.Equal("Just now", KanbanModel.Ago(s - 5, now));
    }

    [Fact]
    public void RunningForSpellsItsUnitsOut()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        double s = 1_800_000_000;
        Assert.Equal("Just started", KanbanModel.RunningFor(s - 30, now));
        Assert.Equal("12 min", KanbanModel.RunningFor(s - 12 * 60, now));
        Assert.Equal("3 hr", KanbanModel.RunningFor(s - 3 * 3600 - 60, now));
        Assert.Equal("1 day", KanbanModel.RunningFor(s - 86_400 - 60, now));
        Assert.Equal("9 days", KanbanModel.RunningFor(s - 9 * 86_400, now));
        Assert.Equal("", KanbanModel.RunningFor(null, now));
    }

    [Fact]
    public void AnUnassignedTaskNamesTheDefaultBotWhenThereIsOne()
    {
        Assert.Equal("No One", KanbanModel.NobodyWords(""));
        Assert.Equal("Deploys (default)", KanbanModel.NobodyWords("Deploys"));
        Assert.Equal("3 (higher goes first)", KanbanModel.PriorityWords(3));
    }

    [Fact]
    public void NamesBoardsAsPeopleReadThem()
    {
        Assert.Equal("Savant HA Dashboard", KanbanModel.BoardTitle("savant-ha-dashboard", null));
        Assert.Equal("Maple SaaS Build", KanbanModel.BoardTitle("maple-saas-build", "maple-saas-build"));
        Assert.Equal("Launch Plan", KanbanModel.BoardTitle("x", "Launch Plan"));
        Assert.Equal("Default Board", KanbanModel.BoardTitle("default", null));
    }

    [Fact]
    public void SaysAProgressNoteAndTheMainBotsCommentsInWords()
    {
        string Bot(string name) => name == "default" ? "Hermes" : name;
        var heartbeat = KanbanModel.ActivityLine("heartbeat", JsonValue.Create("{\"note\":\"Running the full suite\"}"),
            ("heartbeat", "note=Running the full suite"), Bot);
        Assert.Equal(("Progress update", "Running the full suite"), heartbeat);
        Assert.Equal("Comment from Hermes", KanbanModel.ActivityLine("commented", new JsonObject { ["author"] = "default" }, ("comment by default", null), Bot).Label);
        Assert.Equal("Comment from you", KanbanModel.ActivityLine("commented", new JsonObject { ["author"] = "desktop" }, ("comment by desktop", null), Bot).Label);
        Assert.Equal("moved to Ready", KanbanModel.ActivityLine("status", JsonValue.Create("{bad"), ("moved to Ready", null), Bot).Label);
        Assert.Equal("moved to Ready", KanbanModel.EventText("status", new JsonObject { ["status"] = "ready" }).Label);
        Assert.Equal("created in Todo · assigned to deploys",
            KanbanModel.EventText("created", new JsonObject { ["status"] = "todo", ["assignee"] = "deploys" }).Label);
        Assert.Equal(("status", "{bad"), KanbanModel.EventText("status", JsonValue.Create("{bad")));
        Assert.Equal(("lease renewed", "attempt=2 worker=w1"),
            KanbanModel.EventText("lease_renewed", new JsonObject { ["worker"] = "w1", ["attempt"] = 2, ["extra"] = new JsonObject() }));
        Assert.Equal("unblocked → Ready", KanbanModel.EventText("unblocked", null).Label);
    }

    [Fact]
    public void LockedStatusesAreNeverMoveTargets()
    {
        foreach (var s in new[] { "running", "review", "scheduled" }) Assert.True(KanbanModel.IsLocked(s));
        Assert.False(KanbanModel.IsLocked("ready"));
        Assert.Equal("A bot moves a task into Running when it starts work on it.", KanbanModel.LockedReason("running"));
        Assert.Equal("Parked is set by the board.", KanbanModel.LockedReason("parked"));
    }

    [Fact]
    public void ACardSaysWhoWhyAndHowOld()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        string Name(string? p) => p == null ? "No One" : p == "deploys" ? "Deploys" : p;
        var blocked = new KanbanTask("t", "Approve", "blocked") { Assignee = "deploys", BlockKind = "needs_input", CreatedAt = 1_800_000_000 - 2 * 86_400, CommentCount = 2 };
        Assert.Equal(["Deploys", "Needs your input", "2d", "2 comments"], KanbanCardModel.BitsFor(blocked, "", Name, now).Select(b => b.Text));
        Assert.True(KanbanCardModel.BitsFor(blocked, "", Name, now)[1].Alert);
        var lonely = new KanbanTask("t", "Tidy", "ready") { CreatedAt = 1_800_000_000 - 2 * 86_400 };
        Assert.Equal(["No One", "No one assigned, won’t run", "2d"], KanbanCardModel.BitsFor(lonely, "", Name, now).Select(b => b.Text));
        Assert.Equal(["Deploys", "2d"], KanbanCardModel.BitsFor(lonely, "deploys", Name, now).Select(b => b.Text));
        Assert.Equal("deploys", KanbanCardModel.For(lonely, "deploys", Name, now).Assignee);
        var running = new KanbanTask("t", "Run", "running") { Assignee = "deploys", CurrentRunStartedAt = 1_800_000_000 - 7200, CommentCount = 1 };
        Assert.Equal(["Deploys", "Running 2h", "1 comment"], KanbanCardModel.BitsFor(running, "", Name, now).Select(b => b.Text));
    }

    [Fact]
    public void FailedWritesHaveTheirOwnTitles()
    {
        Assert.Equal("Couldn’t Move the Task", KanbanWriteWords.FailureTitle("move"));
        Assert.Equal("Couldn’t Post the Comment", KanbanWriteWords.FailureTitle("requeue"));
        Assert.Equal("Couldn’t Undo the Archive", KanbanWriteWords.FailureTitle(KanbanWriteWords.UndoArchive));
        Assert.Null(KanbanWriteWords.FailureTitle("estimate"));
        Assert.Equal("About 12.3K tokens · medium", KanbanApi.EstimateWords(12_345, "medium"));
        Assert.Equal("About 2M tokens", KanbanApi.EstimateWords(2_000_000, ""));
        Assert.Equal("About 640 tokens", KanbanApi.EstimateWords(640, ""));
    }

    [Fact]
    public void ReadsTheWireLeniently()
    {
        var board = KanbanBoard.From(JsonNode.Parse("""
            {"columns":[{"name":"todo","tasks":[{"id":42,"title":"A","status":"todo","assignee":"","priority":"2","created_at":"1795200036",
             "diagnostics":[{"kind":"stuck","title":"Stuck","actions":[{"kind":"cli_hint","label":"Copy","payload":{"command":"hermes kanban"}}]}]},
             {"title":"no id"}]},{"tasks":[]}],"latest_event_id":7}
            """));
        var t = Assert.Single(board.AllTasks);
        Assert.Equal(("42", null, 2, 1795200036d), (t.Id, t.Assignee, t.Priority, t.CreatedAt!.Value));
        Assert.Equal("hermes kanban", t.Diagnostics![0].Actions[0].Command);
        Assert.Single(board.Columns);
        var detail = KanbanTaskDetail.From(JsonNode.Parse("""
            {"task":{"id":"t_1","title":"A"},"comments":[{"id":1,"author":"desktop","body":"hi"}],"links":{"parents":["t_0"],"children":[]},
             "link_tasks":[{"id":"t_0","title":"Before"}]}
            """))!;
        Assert.Null(detail.Attachments);
        Assert.Equal("Before", detail.LinkTitles["t_0"]);
        Assert.Equal("1", detail.Comments[0].Id);
        Assert.NotNull(KanbanTaskDetail.From(JsonNode.Parse("""{"task":{"id":"t"},"attachments":[]}"""))!.Attachments);
        Assert.Null(KanbanTaskDetail.From(JsonNode.Parse("""{"task":{"title":"no id"}}""")));
        var boards = KanbanBoards.From(JsonNode.Parse("""{"boards":[{"slug":"a","total":3},{"slug":"b","is_current":true,"total":2}]}"""));
        Assert.Equal(("b", 5), (boards.Current, boards.TaskCount));
    }

    [Fact]
    public void SaysTheGatewaysOwnReason()
    {
        Assert.Equal("blocked by parent", KanbanRest.Reason(FakeRest.Http(409, "blocked by parent")));
        Assert.Equal(KanbanRest.OlderHermes, KanbanRest.Reason(FakeRest.Http(404, null)));
        Assert.Equal(KanbanRest.OlderHermes, KanbanRest.Reason(FakeRest.Http(404, "Not Found")));
        Assert.Equal("task t_9 not found", KanbanRest.Reason(FakeRest.Http(404, "task t_9 not found")));
        Assert.Equal("The gateway couldn’t do that.", KanbanRest.Reason(new GatewayException("http", "x", 500, "<html>")));
        Assert.Equal(KanbanRest.CantReach, KanbanRest.Reason(new GatewayException("offline", "Can't reach")));
        Assert.Equal("job%2F1", KanbanRest.Segment("job/1"));
        Assert.Equal("t_1", KanbanRest.Segment("t_1"));
    }
}

/// R21: a failed optimistic write undoes only its own task.
public class KanbanRestoreTests
{
    private static readonly KanbanBoard Board = new([
        new KanbanColumn("todo", [new KanbanTask("t_1", "Write the brief", "todo")]),
        new KanbanColumn("blocked", [new KanbanTask("t_2", "Fix", "blocked")]),
        new KanbanColumn("done", [new KanbanTask("t_3", "Old", "done")]),
    ]);

    private static Dictionary<string, string> WhereIs(KanbanBoard b) =>
        b.Columns.SelectMany(c => c.Tasks.Select(t => (t.Id, c.Name))).ToDictionary(x => x.Id, x => x.Name);

    [Fact]
    public void ASlowFailedMoveOfADoesNotUndoALaterSuccessfulMoveOfB()
    {
        var afterA = KanbanModel.MoveCard(Board, "t_1", "done", 1);
        var afterB = KanbanModel.MoveCard(afterA, "t_2", "todo", 2);
        var undone = KanbanModel.RestoreTask(afterB, Board, afterA, "t_1");
        Assert.Equal(new Dictionary<string, string> { ["t_1"] = "todo", ["t_2"] = "todo", ["t_3"] = "done" }, WhereIs(undone));
        Assert.Equal(["t_1", "t_2"], undone.Columns.First(c => c.Name == "todo").Tasks.Select(t => t.Id));
    }

    [Fact]
    public void ARemovedCardComesBackAndANewerWriteOrRefetchIsLeftAlone()
    {
        var removed = KanbanModel.RemoveCard(Board, "t_3");
        Assert.Equal("done", WhereIs(KanbanModel.RestoreTask(removed, Board, removed, "t_3"))["t_3"]);
        var afterA = KanbanModel.MoveCard(Board, "t_1", "done", 1);
        var newer = KanbanModel.MoveCard(afterA, "t_1", "blocked", 2);
        Assert.Same(newer, KanbanModel.RestoreTask(newer, Board, afterA, "t_1"));
        var refetched = afterA with { Columns = [.. afterA.Columns.Select(c => new KanbanColumn(c.Name, [.. c.Tasks.Select(t => t with { EditToken = 0 })]))] };
        Assert.Same(refetched, KanbanModel.RestoreTask(refetched, Board, afterA, "t_1"));
    }
}

public class KanbanStoreTests
{
    internal static JsonNode BoardJson(params (string Id, string Title, string Status)[] tasks) => new JsonObject
    {
        ["columns"] = new JsonArray([.. new[] { "triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done" }.Select(name =>
            (JsonNode)new JsonObject
            {
                ["name"] = name,
                ["tasks"] = new JsonArray([.. tasks.Where(t => t.Status == name).Select(t => (JsonNode)new JsonObject { ["id"] = t.Id, ["title"] = t.Title, ["status"] = t.Status })]),
            })]),
        ["latest_event_id"] = 1,
    };

    private static JsonNode Moved(ref bool moved)
    {
        moved = true;
        return new JsonObject { ["task"] = new JsonObject { ["id"] = "t_a", ["status"] = "ready" } };
    }

    private static JsonNode Archived(ref bool archived, JsonNode? body)
    {
        archived = body.Str("status") == "archived";
        return new JsonObject();
    }

    private static JsonNode Boards() => JsonNode.Parse("""{"boards":[{"slug":"release-2-4","total":2,"is_current":true}],"current":"release-2-4"}""")!;

    private static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(20);
        }
    }

    [Fact]
    public Task AFailedMovePutsBackOnlyItsTaskAndSaysWhy() => MainLoop.Drive(async () =>
    {
        const string refuse = "Cannot move to 'ready': blocked by parent(s) not done";
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", "/api/plugins/kanban/board") => BoardJson(("t_a", "A", "todo"), ("t_b", "B", "blocked")),
            ("GET", "/api/plugins/kanban/boards") => Boards(),
            ("PATCH", "/api/plugins/kanban/tasks/t_a") => throw FakeRest.Http(409, refuse),
            _ => new JsonObject { ["ok"] = true },
        });
        var store = new KanbanStore(new KanbanApi(rest, new KanbanNudger(rest, TimeSpan.FromMilliseconds(10))), "acct");
        await store.ReadBoardAsync();
        string? failed = null;
        store.WriteFailed += reason => failed = reason;
        await store.MoveAsync(store.Board!.Task("t_a")!, "ready");
        Assert.Equal(refuse, failed);
        Assert.Equal(["t_a"], store.Board!.Columns.First(c => c.Name == "todo").Tasks.Select(t => t.Id));
        var patch = rest.Log.First(r => r.Method == "PATCH");
        Assert.Equal("""{"status":"ready"}""", patch.Body!.ToJsonString());
        Assert.False(patch.Query.ContainsKey("board"));
        await Task.Delay(80);
        Assert.DoesNotContain(rest.Log, r => r.Path.EndsWith("/dispatch"));
    });

    [Fact]
    public Task AMoveShowsAtOnceNamesItsBoardAndNudgesTheDispatcher() => MainLoop.Drive(async () =>
    {
        var moved = false;
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", "/api/plugins/kanban/board") => moved ? BoardJson(("t_a", "A", "ready")) : BoardJson(("t_a", "A", "todo")),
            ("GET", "/api/plugins/kanban/boards") => JsonNode.Parse("""{"boards":[{"slug":"release-2-4","total":1,"is_current":true},{"slug":"home","total":1}],"current":"release-2-4"}"""),
            ("PATCH", _) => Moved(ref moved),
            _ => new JsonObject { ["ok"] = true },
        });
        var prefs = new MemoryKanbanPrefs();
        var store = new KanbanStore(new KanbanApi(rest, new KanbanNudger(rest, TimeSpan.FromMilliseconds(10))), "acct", prefs);
        await store.ReadBoardsAsync();
        store.Select("home");
        Assert.Equal("home", prefs.Get(KanbanStore.SlugKey("acct")));
        await Until(() => store.Board != null);
        var changes = new List<string>();
        store.Changed += () => changes.Add(store.Board?.Task("t_a")?.Status ?? "");
        await store.MoveAsync(store.Board!.Task("t_a")!, "ready");
        Assert.Equal("ready", changes[0]);
        Assert.Equal("home", rest.Log.First(r => r.Method == "PATCH").Query["board"]);
        await Until(() => rest.Log.Any(r => r.Path.EndsWith("/dispatch")));
        Assert.Equal("home", rest.Log.First(r => r.Path.EndsWith("/dispatch")).Query["board"]);
        // The server's current board is kept as ''.
        store.Select("release-2-4");
        Assert.Equal("", store.Slug);
    });

    [Fact]
    public Task ALockedStatusOrAReadOnlyGatewayIsRefusedBeforeSending() => MainLoop.Drive(async () =>
    {
        var rest = new FakeRest(r => r.Path.EndsWith("/board") ? BoardJson(("t_a", "A", "todo")) : new JsonObject());
        var store = new KanbanStore(new KanbanApi(rest), "acct");
        await store.ReadBoardAsync();
        var notices = new List<string>();
        store.Notice += notices.Add;
        await store.MoveAsync(store.Board!.Task("t_a")!, "running");
        store.ReadOnlyGateway = true;
        await store.MoveAsync(store.Board!.Task("t_a")!, "ready");
        Assert.False(await store.DeleteAsync(store.Board!.Task("t_a")!));
        Assert.Equal(["A bot moves a task into Running when it starts work on it.", KanbanRest.ReadOnlyNotice, KanbanRest.ReadOnlyNotice], notices);
        Assert.DoesNotContain(rest.Log, r => r.Method != "GET");
        await Assert.ThrowsAsync<PagesMessageException>(() => store.CreateAsync("x", "", null, 0, [], "triage", false));
    });

    [Fact]
    public Task AFailedDeleteIsToldToTheCallerAndArchiveReturnsItsBoardForUndo() => MainLoop.Drive(async () =>
    {
        var archived = false;
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", "/api/plugins/kanban/board") => archived ? BoardJson(("t_a", "A", "done")) : BoardJson(("t_a", "A", "done"), ("t_b", "B", "done")),
            ("DELETE", _) => throw FakeRest.Http(409, "The board is busy."),
            ("PATCH", _) => Archived(ref archived, r.Body),
            _ => new JsonObject { ["ok"] = true },
        });
        var store = new KanbanStore(new KanbanApi(rest), "acct");
        await store.ReadBoardAsync();
        string? told = null, notice = null;
        store.WriteFailed += r => notice = r;
        Assert.False(await store.DeleteAsync(store.Board!.Task("t_a")!, r => told = r));
        Assert.Equal("The board is busy.", told);
        Assert.Null(notice);
        Assert.NotNull(store.Board!.Task("t_a"));
        var b = store.Board.Task("t_b")!;
        Assert.Equal("", await store.ArchiveAsync(b));
        Assert.Null(store.Board!.Task("t_b"));
        Assert.Equal("""{"status":"archived"}""", rest.Log.Last(r => r.Method == "PATCH").Body!.ToJsonString());
        Assert.Null(await store.UnarchiveAsync(b, "done", ""));
        Assert.Equal("""{"status":"done"}""", rest.Log.Last(r => r.Method == "PATCH").Body!.ToJsonString());
    });

    [Fact]
    public Task NewTaskSendsItsFieldsAndMovesItWhereItStarts() => MainLoop.Drive(async () =>
    {
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("POST", "/api/plugins/kanban/tasks") => new JsonObject { ["task"] = new JsonObject { ["id"] = "t_new", ["status"] = "todo" }, ["warning"] = "No bot named x" },
            _ => new JsonObject { ["ok"] = true },
        });
        var store = new KanbanStore(new KanbanApi(rest), "acct");
        var warning = await store.CreateAsync("  Ship it ", " notes ", "deploys", 3, ["github"], "ready", true);
        Assert.Equal("No bot named x", warning);
        var post = rest.Log.First(r => r.Method == "POST" && r.Path.EndsWith("/tasks"));
        Assert.Equal("""{"title":"Ship it","priority":3,"triage":false,"goal_mode":true,"body":"notes","assignee":"deploys","skills":["github"]}""",
            post.Body!.ToJsonString());
        Assert.Equal("""{"status":"ready"}""", rest.Log.First(r => r.Method == "PATCH").Body!.ToJsonString());
        Assert.EndsWith("/tasks/t_new", rest.Log.First(r => r.Method == "PATCH").Path);
    });

    [Fact]
    public Task TheFallbackAndProfilesAreRead() => MainLoop.Drive(async () =>
    {
        var rest = new FakeRest(r => r.Path switch
        {
            "/api/plugins/kanban/profiles" => JsonNode.Parse("""{"profiles":[{"name":"default","is_default":true},{"name":"deploys"},{"bad":1}]}"""),
            "/api/plugins/kanban/orchestration" => JsonNode.Parse("""{"default_assignee":" deploys ","resolved_default_assignee":""}"""),
            _ => new JsonObject(),
        });
        var store = new KanbanStore(new KanbanApi(rest), "acct");
        await store.ReadProfilesAsync();
        Assert.Equal(["default", "deploys"], store.Profiles.Select(p => p.Name));
        Assert.Equal(("deploys", "default"), (store.Fallback, store.ResolvedDefault));
    });
}

public class KanbanAttachmentUploadTests
{
    private static string Scratch()
    {
        var dir = Path.Combine(Path.GetTempPath(), "kanban-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void TheBodyIsTheFilePartAlone()
    {
        var dir = Scratch();
        var file = Path.Combine(dir, "src.txt");
        File.WriteAllText(file, "hello");
        var built = KanbanAttachmentUpload.BuildFileOnly(file, "brief.txt", "text/plain", "hermes-TEST", Path.Combine(dir, "out"), 100);
        var golden = "--hermes-TEST\r\nContent-Disposition: form-data; name=\"file\"; filename=\"brief.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--hermes-TEST--\r\n";
        Assert.Equal(golden, File.ReadAllText(built.FilePath));
        Assert.Equal(Encoding.UTF8.GetByteCount(golden), built.Length);
        Assert.Equal("multipart/form-data; boundary=hermes-TEST", built.ContentType);
    }

    [Fact]
    public void UnsafeNamesAndFilesPastTheLimitAreRefusedAndLeaveNothing()
    {
        var dir = Scratch();
        var file = Path.Combine(dir, "src.txt");
        File.WriteAllText(file, "hello world");
        var output = Path.Combine(dir, "out");
        foreach (var bad in new[] { "a\"b.txt", "a\\b.txt", "a\r\nb.txt", "" })
            Assert.Equal(MultipartBody.Failure.UnsafeName,
                Assert.Throws<MultipartBody.BuildException>(() => KanbanAttachmentUpload.BuildFileOnly(file, bad, "text/plain", "b", output, 100)).Failure);
        Assert.Equal(MultipartBody.Failure.TooLarge,
            Assert.Throws<MultipartBody.BuildException>(() => KanbanAttachmentUpload.BuildFileOnly(file, "a.txt", "text/plain", "b", output, 5)).Failure);
        Assert.Equal(MultipartBody.Failure.Unreadable,
            Assert.Throws<MultipartBody.BuildException>(() => KanbanAttachmentUpload.BuildFileOnly(Path.Combine(dir, "gone"), "a.txt", "text/plain", "b", output, 5)).Failure);
        Assert.True(!Directory.Exists(output) || Directory.GetFiles(output).Length == 0);
    }

    [Fact]
    public void TheWordsForEachRefusal()
    {
        (string Text, bool Gone) Said(int status, string? detail) => KanbanAttachmentUpload.Reason(FakeRest.Http(status, detail));
        Assert.Equal(25L * 1024 * 1024, KanbanAttachmentUpload.MaxBytes);
        Assert.Equal("This file is larger than 25 MB, the most a task can hold.",
            KanbanAttachmentUpload.Reason(new MultipartBody.BuildException(MultipartBody.Failure.TooLarge)).Text);
        Assert.Equal("This file is larger than 10 MB, the most a task can hold.", Said(413, "attachment exceeds 10 MB limit").Text);
        Assert.Equal("This file is larger than 25 MB, the most a task can hold.", Said(413, null).Text);
        Assert.Equal("invalid attachment filename", Said(400, "invalid attachment filename").Text);
        Assert.Equal("The gateway couldn’t use this file’s name.", Said(400, null).Text);
        Assert.Equal(("This task is no longer on the board.", true), Said(404, "task t_1 not found"));
        Assert.False(Said(413, null).Gone);
        Assert.NotEmpty(Said(500, "failed to store attachment: disk full").Text);
    }

    [Fact]
    public void TheNameSentIsTheLastComponentWithoutHeaderBreakers()
    {
        Assert.Equal("brief.pdf", KanbanAttachmentUpload.SendName("brief.pdf"));
        Assert.Equal("brief.pdf", KanbanAttachmentUpload.SendName("/a/b/brief.pdf"));
        Assert.Equal("brief.pdf", KanbanAttachmentUpload.SendName("C:\\docs\\brief.pdf"));
        Assert.Equal("a_b.txt", KanbanAttachmentUpload.SendName("a\"b\r\n.txt"));
        Assert.Equal("hidden", KanbanAttachmentUpload.SendName("..hidden"));
        Assert.Equal("", KanbanAttachmentUpload.SendName("..."));
        Assert.Equal("application/pdf", KanbanAttachmentUpload.ContentType("a.pdf"));
        Assert.Equal("application/octet-stream", KanbanAttachmentUpload.ContentType("noext"));
    }

    [Fact]
    public async Task TheUploadGoesToTheTasksAttachmentsWithItsBoardAndTheBodyIsRemoved()
    {
        var dir = Scratch();
        var file = Path.Combine(dir, "notes.md");
        File.WriteAllText(file, "# Notes");
        var rest = new FakeRest(_ => null) { UploadAnswer = _ => """{"attachment":{"id":7,"filename":"notes.md","size":7}}""" };
        var api = new KanbanApi(rest);
        var scratch = Path.Combine(dir, "scratch");
        var made = await api.AddAttachmentAsync("t/1", file, "notes.md", "home", scratch);
        Assert.Equal(new KanbanAttachment("7", "notes.md", 7), made);
        var (path, type, body) = Assert.Single(rest.Uploads);
        Assert.Equal("/api/plugins/kanban/tasks/t%2F1/attachments", path);
        Assert.StartsWith("multipart/form-data; boundary=hermes-", type);
        Assert.Contains("filename=\"notes.md\"\r\nContent-Type: text/markdown\r\n\r\n# Notes\r\n", Encoding.UTF8.GetString(body));
        Assert.Equal("home", rest.Log.Single(r => r.Method == "UPLOAD").Query["board"]);
        Assert.Empty(Directory.GetFiles(scratch));
        rest.UploadAnswer = _ => throw FakeRest.Http(413, "attachment exceeds 25 MB limit");
        await Assert.ThrowsAsync<GatewayException>(() => api.AddAttachmentAsync("t1", file, "notes.md", "", scratch));
        Assert.Empty(Directory.GetFiles(scratch));
    }
}
