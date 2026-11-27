using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using static Hermes.Core.Kanban.KanbanNewTaskDraft;

namespace Hermes.Core.Tests;

/// New Task's typed words survive Cancel and Escape (App/Pages/Kanban/NewTaskSheet.swift NewTaskHostController
/// .hasChanges/installClose; App/BotInfo/BotInfoSheet.swift EditingGuard.askToDiscard). Synthetic stand-ins only.
public class KanbanNewTaskDraftTests
{
    /// The add-on's REST with every POST held until the test lets it go (a slow gateway).
    private sealed class DelayedRest : IPagesRest
    {
        public readonly List<(string Method, string Path, string Board, JsonNode? Body)> Log = [];
        public readonly List<TaskCompletionSource<JsonNode?>> Held = [];
        public Exception? Refuse;

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            var board = (query ?? []).FirstOrDefault(q => q.Key == "board").Value ?? "";
            lock (Log) Log.Add((method.Method, path, board, body?.DeepClone()));
            if (method == HttpMethod.Post && path.EndsWith("/tasks"))
            {
                var gate = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
                lock (Held) Held.Add(gate);
                return gate.Task;
            }
            if (path.EndsWith("/boards"))
                return Task.FromResult(JsonNode.Parse("""{"boards":[{"slug":"release-2-4","is_current":true},{"slug":"home"},{"slug":"garden"}],"current":"release-2-4"}"""));
            if (path.EndsWith("/board")) return Task.FromResult(JsonNode.Parse("""{"columns":[]}"""));
            return Task.FromResult<JsonNode?>(new JsonObject { ["ok"] = true });
        }

        public void Release()
        {
            TaskCompletionSource<JsonNode?> gate;
            lock (Held) { gate = Held[0]; Held.RemoveAt(0); }
            if (Refuse is { } x) gate.SetException(x);
            else gate.SetResult(new JsonObject { ["task"] = new JsonObject { ["id"] = "t_new", ["status"] = "triage" } });
        }

        public int Posts { get { lock (Log) return Log.Count(r => r.Method == "POST" && r.Path.EndsWith("/tasks")); } }

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => throw new NotSupportedException();

        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => throw new NotSupportedException();
    }

    private static async Task Until(Func<bool> condition)
    {
        var until = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(10);
        }
    }

    private static (DelayedRest Gateway, KanbanStore Store) Make(string slug = "home")
    {
        var rest = new DelayedRest();
        var prefs = new MemoryKanbanPrefs();
        prefs.Set(KanbanStore.SlugKey("acct"), slug);
        return (rest, new KanbanStore(new KanbanApi(rest, new KanbanNudger(rest, TimeSpan.FromMilliseconds(5))), "acct", prefs));
    }

    private static KanbanNewTaskDraft Typed(string board = "home")
    {
        var d = new KanbanNewTaskDraft(board, "otto", "ready") { Title = "  Water the ferns ", Details = "both shelves", Skills = "garden, notes" };
        d.Priority = 7;
        d.GoalMode = true;
        return d;
    }

    [Theory]
    [InlineData("", "", "")]
    [InlineData("   ", "\n\t", " ")]
    public void AnEmptyOrWhitespaceFormClosesWithoutAsking(string title, string details, string skills)
    {
        var d = new KanbanNewTaskDraft("", "otto", "triage") { Title = title, Details = details, Skills = skills };
        // Who, Start In, priority and Goal Mode aren't typed words: the Mac doesn't ask about them either.
        d.Who = "";
        d.Start = "ready";
        d.Priority = 3;
        d.GoalMode = true;
        Assert.False(d.HasChanges);
        Assert.Equal(CloseDecision.Close, d.Close(CloseReason.Dismiss));
    }

    [Theory]
    [InlineData("Water the ferns", "", "")]
    [InlineData("", "both shelves", "")]
    [InlineData("", "", "garden")]
    public void TypedWordsInAnyFieldAskBeforeCancelOrEscapeDropsThem(string title, string details, string skills)
    {
        var d = new KanbanNewTaskDraft("", "otto", "triage") { Title = title, Details = details, Skills = skills };
        Assert.True(d.HasChanges);
        Assert.Equal(CloseDecision.AskToDiscard, d.Close(CloseReason.Dismiss));
    }

    [Fact]
    public void KeepEditingAndEscapeKeepEveryFieldOnlyDiscardChangesLeaves()
    {
        var d = Typed();
        Assert.Equal(CloseDecision.AskToDiscard, d.Close(CloseReason.Dismiss));
        // Keep Editing, Return (its default) and Escape all answer "not discard".
        Assert.False(d.ConfirmDiscard(discardChosen: false));
        Assert.Equal(("  Water the ferns ", "both shelves", "garden, notes", "otto", "ready", 7, true),
            (d.Title, d.Details, d.Skills, d.Who, d.Start, d.Priority, d.GoalMode));
        Assert.Equal(CloseDecision.AskToDiscard, d.Close(CloseReason.Dismiss));
        Assert.True(d.ConfirmDiscard(discardChosen: true));
    }

    [Fact]
    public void OtherNumberIsAnInternalStepNotAClose()
    {
        var d = Typed();
        Assert.Equal(CloseDecision.Close, d.Close(CloseReason.OtherNumber));
        Assert.Equal("  Water the ferns ", d.Title);
    }

    [Fact]
    public Task WhileAddIsSendingNothingClosesAndNothingIsSentTwice() => MainLoop.Drive(async () =>
    {
        var (rest, store) = Make();
        var d = Typed();
        var first = d.AddAsync(store);
        await Until(() => rest.Held.Count == 1);
        Assert.True(d.Saving);
        Assert.False(d.CanAdd);
        Assert.Equal(CloseDecision.Hold, d.Close(CloseReason.Dismiss));
        Assert.Equal(CloseDecision.Hold, d.Close(CloseReason.OtherNumber));
        Assert.False(d.ConfirmDiscard(discardChosen: true));
        Assert.Equal((AddResult.Ignored, (string?)null), await d.AddAsync(store));
        Assert.Equal(1, rest.Posts);
        rest.Release();
        Assert.Equal(AddResult.Added, (await first).Result);
        Assert.False(d.Saving);
        Assert.Equal(1, rest.Posts);
    });

    [Fact]
    public Task AFailedAddKeepsEveryFieldSaysWhyAndSendsTheSameAgain() => MainLoop.Drive(async () =>
    {
        var (rest, store) = Make();
        rest.Refuse = new GatewayException("http", "The gateway answered 500.", 500, """{"detail":"The board is busy."}""");
        var d = Typed();
        var add = d.AddAsync(store);
        await Until(() => rest.Held.Count == 1);
        rest.Release();
        Assert.Equal(AddResult.Failed, (await add).Result);
        Assert.Equal("The board is busy.", d.Failure);
        Assert.False(d.Saving);
        Assert.Equal(("  Water the ferns ", "both shelves", "garden, notes", "otto", "ready", 7, true),
            (d.Title, d.Details, d.Skills, d.Who, d.Start, d.Priority, d.GoalMode));
        Assert.Equal(CloseDecision.AskToDiscard, d.Close(CloseReason.Dismiss));
        rest.Refuse = null;
        add = d.AddAsync(store);
        Assert.Null(d.Failure);
        await Until(() => rest.Held.Count == 1);
        rest.Release();
        Assert.Equal(AddResult.Added, (await add).Result);
        var posts = rest.Log.Where(r => r.Method == "POST" && r.Path.EndsWith("/tasks")).Select(r => r.Body!.ToJsonString()).ToList();
        Assert.Equal(2, posts.Count);
        Assert.Equal(posts[0], posts[1]);
        Assert.Equal("""{"title":"Water the ferns","priority":7,"triage":false,"goal_mode":true,"body":"both shelves","assignee":"otto","skills":["garden","notes"]}""", posts[0]);
    });

    [Fact]
    public Task TheTaskGoesToTheBoardNewTaskWasOpenedOnEvenIfTheStoreMovesOn() => MainLoop.Drive(async () =>
    {
        var (rest, store) = Make("home");
        var d = new KanbanNewTaskDraft(store.Slug, "otto", "ready") { Title = "Water the ferns" };
        // The board picked away while the sheet was up and while Add was out.
        await store.ReadBoardsAsync();
        store.Select("garden");
        var add = d.AddAsync(store);
        await Until(() => rest.Held.Count == 1);
        store.Select("release-2-4");
        rest.Release();
        Assert.Equal(AddResult.Added, (await add).Result);
        var writes = rest.Log.Where(r => r.Method is "POST" or "PATCH" && r.Path.Contains("/tasks")).ToList();
        Assert.Equal([("POST", "home"), ("PATCH", "home")], writes.Select(w => (w.Method, w.Board)));
        Assert.EndsWith("/tasks/t_new", writes[1].Path);
    });

    [Fact]
    public Task WithoutABoardTheStoreStillWritesToTheBoardShowing() => MainLoop.Drive(async () =>
    {
        var (rest, store) = Make("garden");
        var create = store.CreateAsync("x", "", null, 0, [], "triage", false);
        await Until(() => rest.Held.Count == 1);
        rest.Release();
        await create;
        Assert.Equal("garden", rest.Log.First(r => r.Method == "POST").Board);
    });

    /// Source-level only: the WinUI dialog routes every non-Add close through the draft (no WinUI run here).
    [Fact]
    public void TheNewTaskDialogAsksThroughTheDraftAndKeepsEditingByDefault()
    {
        string root = AppContext.BaseDirectory;
        for (var dir = new DirectoryInfo(root); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln"))) { root = dir.FullName; break; }
        var source = File.ReadAllText(Path.Combine(root, "windows", "src", "HermesHQ.Windows", "Features", "Kanban", "KanbanDialogs.cs"));
        Assert.DoesNotContain("if (!pendingOther) return;", source);
        Assert.Contains("new KanbanNewTaskDraft(store.Slug", source);
        Assert.Contains("dialog.Closing +=", source);
        Assert.Contains("draft.Close(pendingOther ? KanbanNewTaskDraft.CloseReason.OtherNumber : KanbanNewTaskDraft.CloseReason.Dismiss)", source);
        Assert.Contains("draft.ConfirmDiscard(await AskToDiscardAsync(root))", source);
        Assert.Contains("await draft.AddAsync(store)", source);
        // Unlike IsHitTestVisible, IsEnabled also locks a focused text box and its keyboard shortcuts while Add is in flight.
        Assert.Contains("fields.IsEnabled = false;", source);
        Assert.Contains("fields.IsEnabled = true;", source);
        var ask = source[source.IndexOf("private static async Task<bool> AskToDiscardAsync", StringComparison.Ordinal)..];
        Assert.Contains("CloseButtonText = KanbanNewTaskDraft.DiscardKeep, DefaultButton = ContentDialogButton.Close", ask);
    }
}
