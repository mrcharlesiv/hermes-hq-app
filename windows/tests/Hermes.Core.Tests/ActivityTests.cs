using System.Text.Json.Nodes;
using Hermes.Core.Activity;
using Hermes.Core.Model;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

// Ports of Tests/Activity/ActivityRulesTests.swift (roster, task lists, goal), ActivityStoreTests.swift (event rules,
// strict params, goal actions, steer / stop, reasoning timing) and ActivityRowsTests.swift (thought titles).

internal static class A
{
    public static JsonObject O(string json) => (JsonObject)JsonNode.Parse(json)!;
    public static JsonNode N(string json) => JsonNode.Parse(json)!;
}

public class SubagentRosterTests
{
    private static JsonObject O(string json) => A.O(json);

    [Fact]
    public void IdFallsBackToParentIndexAndGoal()
    {
        Assert.Equal("sa_1", SubagentRules.IdOf(O("""{"subagent_id":"sa_1"}""")));
        Assert.Equal("root:2:Scan", SubagentRules.IdOf(O("""{"goal":"Scan","task_index":2}""")));
        Assert.Equal("p:0:Scan", SubagentRules.IdOf(O("""{"goal":"Scan","parent_id":"p"}""")));
    }

    [Fact]
    public void UpsertKeepsTerminalStatusStable()
    {
        var r = new SubagentRoster();
        r.Upsert(O("""{"goal":"scan files","status":"running","subagent_id":"a1","task_index":0}"""), true, null, 1);
        r.Upsert(O("""{"goal":"scan files","status":"completed","subagent_id":"a1","summary":"done"}"""), true, null, 2);
        r.Upsert(O("""{"goal":"scan files","status":"running","subagent_id":"a1","text":"late"}"""), true, null, 3);
        Assert.Equal(SubagentStatus.Completed, r.Items[0].Status);
        Assert.Equal("done", r.Items[0].Summary);
    }

    [Fact]
    public void CreatesOnlyOnSpawnOrStart()
    {
        var r = new SubagentRoster();
        Assert.False(r.Upsert(O("""{"subagent_id":"x","status":"running"}"""), false, "subagent.tool", 1));
        Assert.Empty(r.Items);
    }

    [Fact]
    public void RetiredChildrenNeverComeBack()
    {
        var r = new SubagentRoster();
        const string finished = """{"subagent_id":"finished","goal":"Finished task","status":"running"}""";
        const string live = """{"subagent_id":"live","goal":"Background task","status":"queued"}""";
        r.Upsert(O(finished), true, "subagent.start", 1);
        r.Upsert(O(live), true, "subagent.spawn_requested", 1);
        r.Upsert(O("""{"subagent_id":"finished","goal":"Finished task","status":"completed","summary":"Done"}"""), false, "subagent.complete", 2);
        r.PruneFinished();
        var pruned = r.Items;
        r.Reconcile([O(finished), O(live)], null, 3);
        r.Upsert(O(finished), true, "subagent.start", 4);
        Assert.Equal(pruned, r.Items);
        Assert.Equal(["live"], r.Items.Select(s => s.Id));
    }

    [Fact]
    public void StatusMappingFailsClosedOnCompletion()
    {
        var r = new SubagentRoster();
        foreach (var (id, status) in new[] { ("a", "timeout"), ("b", "error"), ("c", "cancelled"), ("d", "canceled"), ("e", "running"), ("f", "mystery") })
        {
            r.Upsert(O($$"""{"goal":"{{id}}","status":"running","subagent_id":"{{id}}"}"""), true, "subagent.start", 1);
            r.Upsert(O($$"""{"status":"{{status}}","subagent_id":"{{id}}"}"""), false, "subagent.complete", 2);
        }
        var byId = r.Items.ToDictionary(s => s.Id, s => s.Status);
        Assert.Equal(SubagentStatus.Failed, byId["a"]);
        Assert.Equal(SubagentStatus.Failed, byId["b"]);
        Assert.Equal(SubagentStatus.Interrupted, byId["c"]);
        Assert.Equal(SubagentStatus.Interrupted, byId["d"]);
        Assert.Equal(SubagentStatus.Failed, byId["e"]);
        Assert.Equal(SubagentStatus.Failed, byId["f"]);
        Assert.Equal(0, r.LiveCount);
        // A live event with an unknown status stays lenient.
        r.Upsert(O("""{"goal":"g","status":"running","subagent_id":"u2"}"""), true, "subagent.start", 3);
        r.Upsert(O("""{"status":"some_future_live_status","subagent_id":"u2","text":"still"}"""), false, "subagent.progress", 4);
        Assert.Equal(SubagentStatus.Running, r.Items[^1].Status);
    }

    [Fact]
    public void TimeoutSynthesisesItsReason()
    {
        var r = new SubagentRoster();
        r.Upsert(O("""{"goal":"scan","status":"running","subagent_id":"t1"}"""), true, "subagent.start", 1);
        r.Upsert(O("""{"status":"timeout","subagent_id":"t1","duration_seconds":612.3}"""), false, "subagent.complete", 2);
        Assert.Equal(SubagentStatus.Failed, r.Items[0].Status);
        Assert.Equal("Timed out after 612.3s", r.Items[0].Summary);
        r.Upsert(O("""{"goal":"x","status":"running","subagent_id":"t2"}"""), true, "subagent.start", 1);
        r.Upsert(O("""{"status":"timeout","subagent_id":"t2","duration_seconds":9}"""), false, "subagent.complete", 2);
        Assert.Equal("Timed out after 9s", r.Items[1].Summary);
    }

    [Fact]
    public void StreamCapturesToolThinkingProgressAndSummary()
    {
        var r = new SubagentRoster();
        r.Upsert(O("""{"goal":"scan files","status":"queued","subagent_id":"a1"}"""), true, "subagent.spawn_requested", 1);
        r.Upsert(O("""{"status":"running","subagent_id":"a1","tool_name":"search_files","tool_preview":"pattern=hermes"}"""), false, "subagent.tool", 2);
        r.Upsert(O("""{"status":"running","subagent_id":"a1","text":"plan the search order"}"""), false, "subagent.thinking", 3);
        r.Upsert(O("""{"status":"running","subagent_id":"a1","text":"found candidate matches"}"""), false, "subagent.progress", 4);
        r.Upsert(O("""{"status":"completed","subagent_id":"a1","summary":"search complete"}"""), false, "subagent.complete", 5);
        var item = r.Items[0];
        Assert.Equal([SubagentStreamKind.Tool, SubagentStreamKind.Thinking, SubagentStreamKind.Progress, SubagentStreamKind.Summary],
            item.Stream.Select(e => e.Kind));
        Assert.Equal("Search Files(\"pattern=hermes\")", item.Stream[0].Text);
        Assert.Equal("search complete", item.Stream[3].Text);
        Assert.Null(item.CurrentTool);
    }

    [Fact]
    public void StreamIsCappedAndDeduped()
    {
        var r = new SubagentRoster();
        r.Upsert(O("""{"goal":"g","status":"running","subagent_id":"s"}"""), true, "subagent.start", 0);
        for (var i = 0; i < 30; i++)
        {
            r.Upsert(O($$"""{"status":"running","subagent_id":"s","text":"step {{i}}"}"""), false, "subagent.progress", i);
            r.Upsert(O($$"""{"status":"running","subagent_id":"s","text":"step {{i}}"}"""), false, "subagent.progress", i);
        }
        Assert.Equal(24, r.Items[0].Stream.Count);
        Assert.Equal("step 29", r.Items[0].Stream[^1].Text);
    }

    [Fact]
    public void FormatsToolsAndCompactsPreviews()
    {
        Assert.Equal("Read File(\"CHANGELOG.md\")", SubagentRules.FormatTool("read_file", "CHANGELOG.md"));
        Assert.Equal("Terminal", SubagentRules.FormatTool("terminal"));
        var compacted = SubagentRules.Compact(string.Concat(Enumerable.Repeat("a ", 200)));
        Assert.Equal(220, compacted.Length);
        Assert.EndsWith("…", compacted);
    }

    [Fact]
    public void TurnStartPrunesFinishedAndStopClearsAll()
    {
        var r = new SubagentRoster();
        foreach (var (id, status) in new[] { ("live-a", "running"), ("live-b", "queued"), ("done", "completed"), ("broken", "failed") })
            r.Upsert(O($$"""{"goal":"{{id}}","status":"{{status}}","subagent_id":"{{id}}"}"""), true, null, 1);
        r.PruneFinished();
        Assert.Equal(["live-a", "live-b"], r.Items.Select(s => s.Id).Order());
        r.Clear();
        Assert.Empty(r.Items);
    }

    [Fact]
    public void ReconcileKeepsTerminalAndListedSeedsLastToolAndAddsFailedDelegations()
    {
        var r = new SubagentRoster();
        r.Upsert(O("""{"goal":"a","status":"running","subagent_id":"a"}"""), true, "subagent.start", 1);
        r.Upsert(O("""{"goal":"b","status":"running","subagent_id":"b"}"""), true, "subagent.start", 1);
        r.Upsert(O("""{"goal":"c","status":"completed","subagent_id":"c"}"""), true, null, 1);
        List<JsonObject> Children() =>
        [
            O("""{"subagent_id":"a","goal":"a","status":"running","started_at":100,"last_tool":"terminal"}"""),
            O("""{"subagent_id":"n","goal":"new","status":"running","started_at":200,"last_tool":"read_file"}"""),
        ];
        r.Reconcile(Children(),
            [O("""{"delegation_id":"d1","task_index":0,"goal":"Audit","status":"error","error":"interrupted","dispatched_at":1000,"completed_at":1300}""")], 5);
        Assert.Equal(["a", "c", "n", "delegation:d1:0"], r.Items.Select(s => s.Id));
        Assert.Equal(100, r.Items[0].StartedAt);
        Assert.Equal(["Read File"], r.Items[2].Stream.Select(e => e.Text));
        var failed = r.Items[3];
        Assert.Equal(SubagentStatus.Failed, failed.Status);
        Assert.Equal("interrupted", failed.Summary);
        Assert.Equal(300, failed.DurationSeconds);
        // Repeated reads change nothing.
        var before = r.Items;
        var again = r.Reconcile(Children(), [O("""{"delegation_id":"d1","task_index":0,"goal":"Audit","error":"interrupted"}""")], 6);
        Assert.False(again);
        Assert.Equal(before, r.Items);
    }

    [Fact]
    public void DelegateStandInsAndTheirRemoval()
    {
        var start = A.N("""{"name":"delegate_task","tool_id":"call_d1","args":{"tasks":[{"goal":"Read the changelog"},{"goal":"Check issues"}]}}""");
        var payloads = SubagentRules.DelegatePayloads(start, complete: false, sourceEventType: "tool.start");
        Assert.Equal(["delegate-tool:call_d1:0", "delegate-tool:call_d1:1"], payloads.Select(p => ActivityJson.Str(p["subagent_id"])));
        var r = new SubagentRoster();
        foreach (var p in payloads) r.Upsert(p, true, "delegate.running", 1);
        Assert.Equal(2, r.LiveCount);
        Assert.Equal("Read the changelog", r.Items[0].Goal);
        var done = A.N("""{"name":"delegate_task","tool_id":"call_d1","args":{"goal":"Solo"},"result":{"status":"timeout"}}""");
        Assert.Equal("failed", ActivityJson.Str(SubagentRules.DelegatePayloads(done, complete: true, sourceEventType: "tool.complete")[0]["status"]));
        r.PruneDelegateStandIns();
        Assert.Empty(r.Items);
    }

    [Fact]
    public void StatsAndWords()
    {
        Assert.Equal("7s", SubagentRules.FormatElapsed(7));
        Assert.Equal("1:05", SubagentRules.FormatElapsed(65));
        Assert.Equal("1:15:00", SubagentRules.FormatElapsed(4500)); // never "75:00"
        Assert.Equal("", SubagentRules.FormatDuration(null));
        Assert.Equal("4.2s", SubagentRules.FormatDuration(4.2));
        Assert.Equal("2m", SubagentRules.FormatDuration(119.6)); // never "1m 60s"
        Assert.Equal("12m 34s", SubagentRules.FormatDuration(754.3));
        Assert.Equal("1.2k", SubagentRules.CompactNumber(1230));
        Assert.Equal("999", SubagentRules.CompactNumber(999));
        Assert.Equal("1 helper", SubagentRules.ChipWords(1));
        Assert.Equal("2 helpers", SubagentRules.ChipWords(2));
        var s = new SubagentProgress
        {
            Id = "a", Goal = "g", Model = "m", Status = SubagentStatus.Completed, StartedAt = 0, UpdatedAt = 100,
            DurationSeconds = 4.2, InputTokens = 18200, OutputTokens = 1300, ToolCount = 9,
        };
        Assert.Equal("m · 4.0s · 9 tools · 19.5k tok · updated 30s ago", SubagentRules.StatsLine(s, 130));
    }
}

public class TodoRulesTests
{
    [Fact]
    public void ParsesArraysStringsAndWrappedLists()
    {
        var raw = A.N("""[{"id":"1","content":"Read","status":"completed"},{"id":"","content":"x","status":"pending"},{"id":"2","content":"Write","status":"bogus"},{"id":"3","content":"Sub","status":"pending","parent":"3"}]""");
        var parsed = TodoRules.ParseTodos(raw)!;
        Assert.Equal(["1", "3"], parsed.Select(t => t.Id));
        Assert.Null(parsed[1].Parent);
        Assert.Equal(TodoStatus.InProgress,
            TodoRules.ParseTodos(JsonValue.Create("""{"todos":[{"id":"a","content":"A","status":"in_progress"}]}"""))![0].Status);
        Assert.Null(TodoRules.ParseTodos(JsonValue.Create(3)));
    }

    [Fact]
    public void TreeOrderPutsParentsFirstAndKeepsCycles()
    {
        TodoItem[] items =
        [
            new("c", "C", TodoStatus.Pending, "a"), new("a", "A", TodoStatus.Pending), new("x", "X", TodoStatus.Pending, "missing"),
            new("p", "P", TodoStatus.Pending, "q"), new("q", "Q", TodoStatus.Pending, "p"),
        ];
        var tree = TodoRules.Tree(items);
        Assert.Equal(["a", "c", "x", "p", "q"], tree.Select(t => t.Item.Id));
        Assert.Equal([0, 1, 0, 0, 0], tree.Select(t => t.Depth));
    }

    [Fact]
    public void RevisionWatermarkAndLinger()
    {
        var s = new TodoState();
        TodoItem[] active = [new("1", "A", TodoStatus.InProgress), new("2", "B", TodoStatus.Pending)];
        Assert.True(s.Set(active, 1, 0));
        Assert.Equal(2, s.Live!.Count);
        Assert.Null(s.DropAt);
        var done = active.Select(t => t with { Status = TodoStatus.Completed }).ToList();
        s.Set(done, 3, 10);
        Assert.Equal(14, s.DropAt);
        Assert.False(s.Set(active, 2, 11)); // older revision ignored
        Assert.False(s.Expire(13));
        Assert.True(s.Expire(14));
        Assert.Null(s.Live);
        Assert.Equal(2, s.Retained.Count);
    }

    [Fact]
    public void MergePatchUpdatesAndAppends()
    {
        TodoItem[] current = [new("1", "A", TodoStatus.Pending)];
        var payload = A.N("""{"args":{"merge":true,"todos":[{"id":"1","status":"completed"},{"id":"2","status":"pending"}]}}""");
        Assert.Equal([new TodoItem("1", "A", TodoStatus.Completed), new TodoItem("2", "(no description)", TodoStatus.Pending)],
            TodoRules.NextTodos(current, payload)!);
    }

    [Fact]
    public void ResumeRunningVersusIdle()
    {
        var active = A.N("""{"todos":[{"id":"1","content":"A","status":"in_progress"},{"id":"2","content":"B","status":"pending"}],"revision":5}""");
        var idle = new TodoState();
        idle.Restore(active, running: false, now: 0);
        Assert.Null(idle.Live);
        Assert.Equal(2, idle.Retained.Count);
        var running = new TodoState();
        running.Restore(active, running: true, now: 0);
        Assert.Equal(2, running.Live!.Count);
        Assert.False(new TodoState().Restore(A.N("""{"todos":[],"revision":0}"""), running: false, now: 0));
    }

    [Fact]
    public void ResumeIdleFinishedGoesStraightToPrevious()
    {
        var finished = A.N("""{"todos":[{"id":"1","content":"A","status":"completed"},{"id":"2","content":"B","status":"completed"}],"revision":7}""");
        var opened = new TodoState();
        Assert.True(opened.Restore(finished, running: false, now: 100));
        Assert.Null(opened.Live);
        Assert.Equal(2, opened.Retained.Count);
        Assert.Null(opened.DropAt);
        var onScreen = new TodoState();
        onScreen.Set([new("1", "A", TodoStatus.Completed), new("2", "B", TodoStatus.InProgress)], 6, 90);
        onScreen.Restore(finished, running: false, now: 100);
        Assert.Equal(2, onScreen.Live!.Count);
        Assert.Equal(100 + TodoRules.FinishedLinger, onScreen.DropAt);
    }

    [Fact]
    public void TurnEndDropsAnActiveListAndStopClearsAll()
    {
        var s = new TodoState();
        s.Set([new("1", "A", TodoStatus.Pending)], 1, 0);
        Assert.True(s.DropActive());
        Assert.Null(s.Live);
        Assert.Single(s.Retained);
        s.Clear();
        Assert.True(s.IsEmpty);
        Assert.Equal("Tasks 1/2", TodoRules.ChipWords([new("1", "A", TodoStatus.Completed), new("2", "B", TodoStatus.Cancelled)], previous: false));
    }
}

public class ControlRulesTests
{
    internal const string Goal = """{"title":"Ship 2.4","status":"active","turns_used":3,"max_turns":20,"contract":{"outcome":"Notes published","verification":"","constraints":"","boundaries":"","stop_when":""},"subgoals":["Draft notes"],"gates":[],"last_verdict":"continue","last_reason":"Notes drafted"}""";

    internal static JsonObject Snapshot(JsonNode goal) =>
        new() { ["goal"] = goal, ["loop"] = null, ["heartbeat"] = null, ["revision"] = "r1", ["updated_at"] = 1791633600.0 };

    [Fact]
    public void ParsesAValidSnapshotAndItsWords()
    {
        var g = ControlRules.ParseSnapshot(Snapshot(A.N(Goal)))!.Goal!;
        Assert.Equal("Goal active · Turn 3/20", ControlRules.ChipWords(g));
        Assert.Equal("Notes drafted", ControlRules.Reason(g));
        Assert.True(ControlRules.HasDetails(g));
        Assert.Equal(["Objective", "Outcome"], ControlRules.DetailSections(g, _ => "").Select(s => s.Label));
    }

    [Fact]
    public void AMissingContractKeyDropsTheWholeSnapshot()
    {
        var goal = A.O(Goal);
        goal["contract"] = new JsonObject { ["outcome"] = "x" };
        Assert.Null(ControlRules.ParseSnapshot(Snapshot(goal)));
        var extra = A.O(Goal);
        extra["surprise"] = 1;
        Assert.Null(ControlRules.ParseSnapshot(Snapshot(extra)));
    }

    [Fact]
    public void LabelsForEveryState()
    {
        var g = ControlRules.ParseGoal(A.N(Goal))! with { Status = GoalStatus.Done, TurnsUsed = 5 };
        Assert.Equal("Goal done · 5 turns", ControlRules.ChipWords(g));
        g = g with { Status = GoalStatus.Paused, TurnsUsed = 3, MaxTurns = 0 };
        Assert.Equal("Goal paused · Turn 3", ControlRules.ChipWords(g));
        g = g with { LastVerdict = GoalVerdict.Blocked, MaxTurns = 20, TurnsUsed = 14 };
        Assert.Equal("Goal blocked · Turn 14/20", ControlRules.ChipWords(g));
        g = g with { LastVerdict = null, Status = GoalStatus.Active, WaitBarrier = new WaitSession("s1", "child") };
        Assert.StartsWith("Goal waiting", ControlRules.ChipWords(g));
        Assert.Equal("Wait condition: child", ControlRules.Reason(g));
        Assert.Equal(["View Details", "Resume Now", "Pause Goal", "Clear Goal"], GoalWords.Menu(g).Select(i => i.Title).Where(t => t != "Add Criterion"));
        Assert.Equal("Action failed: unknown error", ControlRules.ActionFailure("  "));
    }
}

public class ActivityStoreTests
{
    private const string Rid = "5cc537d1";
    private readonly ActivityStore _store = new("default", Rid, "s1");

    private bool Event(string type, string payload = "null", string? sid = null) =>
        _store.Apply(new RpcEvent(type, sid ?? Rid, JsonNode.Parse(payload), null));

    [Fact]
    public void SubagentEventsBuildTheRosterAndStopClearsIt()
    {
        Event("subagent.start", """{"goal":"Read","task_count":1,"task_index":0,"subagent_id":"sa_1","status":"running"}""");
        Event("subagent.tool", """{"goal":"Read","task_count":1,"task_index":0,"subagent_id":"sa_1","tool_name":"read_file","tool_preview":"A.md"}""");
        Assert.Single(_store.Snapshot.LiveSubagents);
        Assert.True(_store.HasLiveWork);
        _store.Stopped();
        Assert.Empty(_store.Snapshot.Subagents);
        // Late frames of the stopped turn are dropped until the next send.
        Assert.False(Event("subagent.start", """{"goal":"Late","task_count":1,"task_index":0,"subagent_id":"sa_2"}"""));
        Assert.Empty(_store.Snapshot.Subagents);
        _store.SetInterrupted(false);
        Event("subagent.start", """{"goal":"Next","task_count":1,"task_index":0,"subagent_id":"sa_3"}""");
        Assert.Single(_store.Snapshot.Subagents);
    }

    [Fact]
    public void EventsForOtherChatsAreIgnored()
    {
        Assert.False(Event("subagent.start", """{"goal":"x","task_count":1,"task_index":0,"subagent_id":"a"}""", sid: "other"));
        Assert.True(_store.Snapshot.IsEmpty);
        Event("subagent.start", """{"goal":"x","task_count":1,"task_index":0,"subagent_id":"a"}""");
        _store.Bind("aaaa0001", "s1");
        Assert.Single(_store.Snapshot.Subagents);
        Assert.Equal("aaaa0001", _store.Snapshot.RuntimeId);
    }

    [Fact]
    public void DelegateStandInsUntilANativeEvent()
    {
        Event("message.start");
        Event("tool.start", """{"tool_id":"call_d1","name":"delegate_task","args":{"tasks":[{"goal":"A"},{"goal":"B"}]}}""");
        Assert.Equal(["delegate-tool:call_d1:0", "delegate-tool:call_d1:1"], _store.Snapshot.Subagents.Select(s => s.Id));
        Event("subagent.start", """{"goal":"A","task_count":2,"task_index":0,"subagent_id":"sa_1","status":"running"}""");
        Assert.Equal(["sa_1"], _store.Snapshot.Subagents.Select(s => s.Id));
        Assert.True(_store.Snapshot.NativeSubagentEvents);
        Event("message.start");
        Assert.False(_store.Snapshot.NativeSubagentEvents);
    }

    [Fact]
    public void ALiveStandInGoesWhenItsTurnEnds()
    {
        Event("tool.start", """{"tool_id":"call_d1","name":"delegate_task","args":{"goal":"Solo"}}""");
        Assert.True(_store.HasLiveWork);
        Event("message.complete", """{"text":"done"}""");
        Assert.Empty(_store.Snapshot.Subagents);
    }

    [Fact]
    public void TodoEventsRevisionsAndTurnEnd()
    {
        Event("todo.updated", """{"todos":[{"id":"1","content":"Read","status":"in_progress"},{"id":"2","content":"Write","status":"pending"}],"revision":1}""");
        Assert.Equal(2, _store.Snapshot.LiveTodos!.Count);
        Event("todo.updated", """{"todos":[{"id":"1","content":"Read","status":"completed"}],"revision":3}""");
        Event("todo.updated", """{"todos":[{"id":"1","content":"Read","status":"pending"}],"revision":2}""");
        Assert.Equal(TodoStatus.Completed, _store.Snapshot.LiveTodos![0].Status);
        var clock = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 5.0;
        _store.Now = () => clock;
        Assert.True(_store.ExpireTodos());
        Assert.Null(_store.Snapshot.LiveTodos);
        Assert.Single(_store.Snapshot.RetainedTodos);
        Event("tool.start", """{"name":"todo","args":{"todos":[{"id":"9","content":"Plan","status":"in_progress"}]}}""");
        Assert.Equal("9", _store.Snapshot.LiveTodos![0].Id);
        Event("message.complete", """{"text":"done"}""");
        Assert.Null(_store.Snapshot.LiveTodos);
    }

    [Fact]
    public void ResumeTodoStateWhileIdleKeepsOnlyThePreviousList()
    {
        _store.ApplyResume(A.N($$$"""{"session_id":"{{{Rid}}}","running":false,"todo_state":{"todos":[{"id":"1","content":"A","status":"pending"},{"id":"2","content":"B","status":"completed"}],"revision":5}}"""));
        Assert.Null(_store.Snapshot.LiveTodos);
        Assert.Equal("Previous tasks 1/2", TodoRules.ChipWords(_store.Snapshot.RetainedTodos, previous: true));
    }

    [Fact]
    public void ListRequestUsesStrictParamsAndReconciles()
    {
        var (method, p) = ActivityStore.SubagentList(Rid, "default");
        Assert.Equal("subagent.list", method);
        Assert.True(JsonNode.DeepEquals(A.N($$"""{"session_id":"{{Rid}}","profile":"default"}"""), p));
        Assert.True(JsonNode.DeepEquals(A.N($$"""{"session_id":"{{Rid}}"}"""), ActivityStore.SubagentList(Rid, "").Params));
        var version = _store.Version;
        Assert.True(_store.ApplyList(A.N("""{"subagents":[{"subagent_id":"sa_1","goal":"Read","status":"running","started_at":100.0,"last_tool":"read_file","accepting_steer":true}],"delegations":[]}"""), version));
        Assert.Single(_store.Snapshot.Subagents);
        Assert.Equal(["Read File"], _store.Snapshot.Subagents[0].Stream.Select(e => e.Text));
        // An answer to a read sent before a newer change is discarded.
        Assert.False(_store.ApplyList(A.N("""{"subagents":[],"delegations":[]}"""), version));
        Assert.True(_store.ApplyList(A.N("""{"subagents":[],"delegations":[]}"""), _store.Version));
        Assert.Empty(_store.Snapshot.Subagents);
    }

    [Fact]
    public void StaleClaimIsDroppedByDelegationStatus()
    {
        Event("subagent.start", """{"goal":"x","task_count":1,"task_index":0,"subagent_id":"sa_9","status":"running"}""");
        Assert.True(_store.HasStaleClaim);
        var (method, p) = ActivityStore.DelegationStatus("default");
        Assert.Equal("delegation.status", method);
        Assert.True(JsonNode.DeepEquals(A.N("""{"profile":"default"}"""), p));
        Assert.Empty(ActivityStore.DelegationStatus("").Params);
        Assert.True(_store.ApplyDelegationStatus(A.N("""{"active":[],"paused":false,"max_spawn_depth":1,"max_concurrent_children":3}"""), _store.Version));
        Assert.False(_store.HasLiveWork);
    }

    [Fact]
    public void GoalReadAndActions()
    {
        var snapshot = ControlRulesTests.Snapshot(A.N(ControlRulesTests.Goal));
        Assert.True(JsonNode.DeepEquals(A.N($$"""{"session_id":"{{Rid}}","profile":"default"}"""), ActivityStore.ControlRead(Rid, "default").Params));
        Assert.True(_store.ApplyControlRead(new JsonObject { ["control"] = snapshot.DeepClone() }, _store.ControlVersion));
        Assert.NotNull(_store.Snapshot.Goal);
        var request = _store.Control(GoalActions.Pause)!.Value;
        Assert.Equal("session.control", request.Method);
        Assert.True(JsonNode.DeepEquals(A.N($$$"""{"session_id":"{{{Rid}}}","profile":"default","action":"goal.pause","args":{}}"""), request.Params));
        _store.BeginControl(GoalActions.Pause);
        Assert.Equal("goal.pause", _store.Snapshot.Control.PendingAction);
        var paused = A.O(ControlRulesTests.Goal);
        paused["status"] = "paused";
        var answer = new JsonObject
        {
            ["control"] = ControlRulesTests.Snapshot(paused),
            ["dispatch"] = A.N("""{"type":"exec","output":"⏸ Goal paused","notice":null,"message":null,"display":null}"""),
        };
        var dispatch = _store.EndControl(answer);
        Assert.Equal("exec", dispatch.Type);
        Assert.Null(_store.Snapshot.Control.PendingAction);
        Assert.Equal(GoalStatus.Paused, _store.Snapshot.Goal!.Status);
        // An update event replaces it; a malformed one is ignored.
        Assert.True(Event("session.control.update", new JsonObject { ["control"] = snapshot.DeepClone() }.ToJsonString()));
        Assert.Equal(GoalStatus.Active, _store.Snapshot.Goal!.Status);
        Assert.False(Event("session.control.update", """{"control":{"goal":"nope"}}"""));
        Assert.Equal(GoalStatus.Active, _store.Snapshot.Goal!.Status);
        // A turn end asks for the snapshot again on a gateway with goals.
        Event("message.complete", """{"text":"done"}""");
        Assert.True(_store.TakeControlReadDue());
        Assert.False(_store.TakeControlReadDue());
        _store.FailControl("boom");
        Assert.Equal("Action failed: boom", _store.Snapshot.Control.ActionError);
        Assert.True(JsonNode.DeepEquals(A.N("""{"index":2}"""), GoalActions.RemoveCriterionArgs(2)));
    }

    [Fact]
    public void ControlMethodNotFoundMeansNoGoal()
    {
        Assert.True(_store.ControlReadFailed(-32601, "Method not found"));
        Assert.Equal(ControlCapability.Unsupported, _store.Snapshot.Control.Capability);
        Assert.False(_store.ControlReadFailed(5031, "busy"));
    }

    [Fact]
    public void SteerAndStopRequestsAndAnswers()
    {
        var steer = ActivityStore.Steer(Rid, "default", "sa_1", "  Only open issues ")!.Value;
        Assert.Equal("subagent.steer", steer.Method);
        Assert.True(JsonNode.DeepEquals(A.N($$"""{"session_id":"{{Rid}}","profile":"default","subagent_id":"sa_1","text":"Only open issues"}"""), steer.Params));
        Assert.Null(ActivityStore.Steer(Rid, "default", "sa_1", "   "));
        Assert.Equal(SteerOutcome.Queued, ActivityStore.ReadSteer(A.N("""{"status":"queued","subagent_id":"sa_1","text":"Only open issues"}""")));
        Assert.Equal(SteerOutcome.Rejected, ActivityStore.ReadSteer(null));
        var stop = _store.StopChild("sa_1")!.Value;
        Assert.Equal("subagent.interrupt", stop.Method);
        Assert.True(JsonNode.DeepEquals(A.N($$"""{"session_id":"{{Rid}}","profile":"default","subagent_id":"sa_1"}"""), stop.Params));
        Assert.False(ActivityStore.ReadInterrupt(A.N("""{"found":false,"subagent_id":"sa_1"}""")));
        Assert.True(ActivityStore.ReadInterrupt(A.N("""{"found":true}""")));
        Assert.Equal("subagent.tail", ActivityStore.SubagentTailRequest(Rid, "default", "sa_1").Method);
    }

    [Fact]
    public void FailedHelpersWaitUntilAcknowledged()
    {
        Event("subagent.start", """{"goal":"x","subagent_id":"sa_1","status":"running"}""");
        Event("subagent.complete", """{"subagent_id":"sa_1","status":"error","summary":"broke"}""");
        Assert.Equal(["sa_1"], _store.Snapshot.UnreadHelperFailures.Select(s => s.Id));
        Event("message.start");
        Assert.Empty(_store.Snapshot.Subagents);
        Assert.Single(_store.Snapshot.UnreadHelperFailures);
        Assert.True(_store.AcknowledgeHelperFailure("sa_1"));
        Assert.Empty(_store.Snapshot.UnreadHelperFailures);
    }
}

public class ReasoningTimingTests
{
    [Fact]
    public void ThoughtForSecondsThenBrieflyThenHistory()
    {
        var clock = new ReasoningClock();
        var now = DateTimeOffset.FromUnixTimeSeconds(1000);
        clock.Clock = () => now;
        var m = new ChatMessage("m1", Role.Assistant, [new ReasoningPart("thinking")], IsStreaming: true);
        ChatMessage? Find(string id) => id == m.Id ? m : null;
        clock.Note("m1", Find);
        now = now.AddSeconds(7.4);
        m = m with { Parts = [.. m.Parts, new ToolPart(new ToolCall("t", "terminal", null, null, ToolState.Running))] };
        clock.Note("m1", Find);
        Assert.Equal(new Dictionary<int, double> { [0] = 7 }, clock.Seconds("m1"));
        // A second, brief thought.
        m = m with { Parts = [.. m.Parts, new ReasoningPart("more")] };
        clock.Note("m1", Find);
        now = now.AddSeconds(0.4);
        m = m with { IsStreaming = false };
        clock.Note(null, Find);
        Assert.Equal(0, clock.Seconds("m1")[2]);
        Assert.Empty(clock.Seconds("history"));
    }

    [Theory]
    [InlineData(7.0, false, "Thought for 7s")]
    [InlineData(0.0, false, "Thought briefly")]
    [InlineData(65.0, false, "Thought for 1:05")]
    [InlineData(null, false, "Thought")]
    [InlineData(3.0, true, "Thinking")]
    public void ThoughtTitles(double? seconds, bool live, string expected) =>
        Assert.Equal(expected, ReasoningClock.ThoughtTitle(seconds, live));
}

public class ShelfWordsTests
{
    [Fact]
    public void HelperRowsAndDetail()
    {
        var child = new SubagentProgress { Id = "a", Goal = "Read", Status = SubagentStatus.Queued, StartedAt = 100, UpdatedAt = 100 };
        Assert.Equal("Queued", SubagentWords.RowLine(child));
        Assert.Equal("Waiting for activity", SubagentWords.RowLine(child with { Status = SubagentStatus.Running }));
        Assert.Equal("Read, Queued", SubagentWords.RowAccessibilityLabel(child));
        Assert.Equal("1:05", SubagentWords.Timer(child, 165));
        var done = child with { Status = SubagentStatus.Completed, Summary = "All good", DurationSeconds = 41.6 };
        Assert.Equal("All good", SubagentWords.RowLine(done));
        Assert.Equal("42s", SubagentWords.Timer(done, 999));
        Assert.Equal("Stopped", SubagentWords.Status(SubagentStatus.Interrupted));
        Assert.Equal("Dispatched · status unavailable", SubagentWords.Status(SubagentStatus.Dispatched));
        Assert.Equal("All 3 Helpers", SubagentWords.BackRow(3));
        Assert.Equal("All Helpers", SubagentWords.BackRow(1));
        Assert.Equal("2 running · 1 queued · 1 done",
            SubagentWords.HelperCounts([SubagentStatus.Running, SubagentStatus.Running, SubagentStatus.Queued], 1));
        Assert.Equal("Steps · latest 12 of 20", SubagentWords.StepsHeader(12, 20));
        Assert.Equal("Files · 9", SubagentWords.FilesHeader(8, 9));
        Assert.Equal("Show All 30 Lines", SubagentWords.OutputToggle(false, 30));
        Assert.Equal("Remove Criterion 1?", GoalWords.RemoveCriterion(ControlRules.ParseGoal(A.N(ControlRulesTests.Goal))!, 1).Title);
        Assert.Equal("“Draft notes” is removed from this goal.", GoalWords.RemoveCriterion(ControlRules.ParseGoal(A.N(ControlRulesTests.Goal))!, 1).Message);
    }
}
