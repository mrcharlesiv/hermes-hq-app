using System.Text.Json.Nodes;
using Hermes.Core.Kanban;

namespace Hermes.Core.Tests;

/// [WIN-KANBAN-STORE-THREAD] KanbanStore is used from one thread (the app's UI thread; the Mac's KanbanStore is
/// @MainActor). Two quick drags start two PATCHes; when the gateway's answers arrive on pool threads, every bit of the
/// store's state (the optimistic board, the count of writes on their way, the board generation) is still touched on the
/// thread that drives it, and the board is read once, after the last write landed. Called from a thread with no
/// SynchronizationContext the answers are put away on pool threads (each continuation, the reads that follow and their
/// Changed all off the caller's thread); end-to-end tests drive the store the same way the app does (MainLoop.Drive).
public class KanbanStoreThreadTests
{
    /// The Kanban add-on's routes: the board and boards answered at once, every PATCH held until both are out and then
    /// answered from a pool thread of its own, as a real gateway's answers come back (HttpClient completes off the
    /// caller's thread). The dispatcher nudge (KanbanNudger's own Task.Run, not the store's) isn't recorded.
    private sealed class PoolRest(int patches) : IPagesRest
    {
        private readonly object _gate = new();
        private readonly List<TaskCompletionSource<JsonNode?>> _waiting = [];
        public List<(string Method, string Path, int Thread)> Calls { get; } = [];
        public bool Moved { get; private set; }

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            if (path.EndsWith("/dispatch")) return Task.FromResult<JsonNode?>(new JsonObject { ["ok"] = true });
            lock (_gate) Calls.Add((method.Method, path, Environment.CurrentManagedThreadId));
            if (method == HttpMethod.Get && path.EndsWith("/boards"))
                return Task.FromResult(JsonNode.Parse("""{"boards":[{"slug":"release-2-4","total":2,"is_current":true}],"current":"release-2-4"}"""));
            if (method == HttpMethod.Get)
            {
                bool moved;
                lock (_gate) moved = Moved;
                var status = moved ? "ready" : "todo";
                return Task.FromResult<JsonNode?>(KanbanStoreTests.BoardJson(("t_a", "A", status), ("t_b", "B", status)));
            }
            var answer = new TaskCompletionSource<JsonNode?>();
            List<TaskCompletionSource<JsonNode?>> release = [];
            lock (_gate)
            {
                _waiting.Add(answer);
                if (_waiting.Count == patches) { release = [.. _waiting]; Moved = true; }
            }
            // Each answer completes on a pool thread of its own, all at about the same time.
            foreach (var waiting in release) ThreadPool.QueueUserWorkItem(_ => waiting.SetResult(new JsonObject { ["ok"] = true }));
            return answer.Task;
        }

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => throw new NotSupportedException();

        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => throw new NotSupportedException();
    }

    [Fact]
    public Task TwoQuickMovesWhoseAnswersArriveOnPoolThreadsTouchTheStoreOnlyOnItsOwnThread() => MainLoop.Drive(async () =>
    {
        var owner = Environment.CurrentManagedThreadId;
        var rest = new PoolRest(patches: 2);
        var store = new KanbanStore(new KanbanApi(rest), "acct");
        await store.ReadBoardAsync();
        var changed = new List<int>();
        var failures = new List<string>();
        store.Changed += () => changed.Add(Environment.CurrentManagedThreadId);
        store.WriteFailed += failures.Add;
        var reads = rest.Calls.Count(c => c is { Method: "GET", Path: "/api/plugins/kanban/board" });

        // Two drags, one after the other, before either answer is back.
        var a = store.MoveAsync(store.Board!.Task("t_a")!, "ready");
        var b = store.MoveAsync(store.Board!.Task("t_b")!, "ready");
        Assert.Equal(["ready", "ready"], store.Board!.AllTasks.Select(t => t.Status));
        await Task.WhenAll(a, b);

        // The read after the last write, and the boards list after each, land on this thread too.
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (store.LoadingBoard || rest.Calls.Count(c => c.Path.EndsWith("/boards")) < 2)
        {
            Assert.True(DateTime.UtcNow < deadline, "the reads after the writes never landed");
            await Task.Delay(20);
        }
        await Task.Delay(100);   // nothing more comes

        // Every change, and every call the store made, on the one thread that drives it.
        Assert.All(changed, t => Assert.Equal(owner, t));
        Assert.All(rest.Calls, c => Assert.Equal(owner, c.Thread));
        Assert.Equal(owner, Environment.CurrentManagedThreadId);
        // The board read once more, after both writes (not once per write, never lost), and it shows them.
        Assert.Equal(reads + 1, rest.Calls.Count(c => c is { Method: "GET", Path: "/api/plugins/kanban/board" }));
        Assert.Equal(2, rest.Calls.Count(c => c.Method == "PATCH"));
        Assert.Equal(["ready", "ready"], store.Board!.AllTasks.Select(t => t.Status));
        Assert.False(store.LoadingBoard);
        Assert.Empty(failures);
    });
}
