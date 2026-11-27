using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-TASKS-STORE-THREAD] TasksStore is used from one thread (the app's UI thread; the Mac's TasksStore is
/// @MainActor). A Move of several tasks starts one PATCH per task and waits for them all; when the gateway's answers
/// arrive on pool threads, every bit of the store's state is still touched on the thread that drives it, so the first
/// answer being put away never races the next PATCH starting (the e2e flake: "Operations that change non-concurrent
/// collections must have exclusive access" from Begin). End-to-end tests drive the store the same way (MainLoop.Drive).
public class TasksStoreThreadTests
{
    /// As the wire sends it (read back from its text, as FakeRest's answers are).
    private static JsonNode Wire(JsonNode n) => JsonNode.Parse(n.ToJsonString())!;

    private static JsonNode TaskJson(string id, int rev, string? section = null, double position = 0) =>
        new JsonObject { ["id"] = id, ["rev"] = rev, ["title"] = id, ["who"] = "me", ["status"] = "open", ["section"] = section, ["position"] = position };

    /// The add-on's routes, with every PATCH answered from a pool thread once all of a Move's PATCHes are out, as a
    /// real gateway's answers come back (HttpClient completes off the caller's thread).
    private sealed class PoolRest(int patches) : IPagesRest
    {
        private readonly object _gate = new();
        private readonly List<(TaskCompletionSource<JsonNode?> Answer, JsonNode Task)> _waiting = [];
        public List<int> Threads { get; } = [];

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            lock (_gate) Threads.Add(Environment.CurrentManagedThreadId);
            if (method == HttpMethod.Get)
                return Task.FromResult<JsonNode?>(Wire(new JsonObject
                {
                    ["rev"] = 3,
                    ["tasks"] = new JsonArray(TaskJson("t0", 1, "home", 40), TaskJson("t1", 1), TaskJson("t2", 1), TaskJson("t3", 1, "home", 7)),
                    ["sections"] = new JsonArray(new JsonObject { ["id"] = "home", ["name"] = "Home" }),
                }));
            var id = path[(path.LastIndexOf('/') + 1)..];
            var answer = new TaskCompletionSource<JsonNode?>();
            List<(TaskCompletionSource<JsonNode?> Answer, JsonNode Task)> release = [];
            lock (_gate)
            {
                _waiting.Add((answer, Wire(TaskJson(id, 2, body!.Str("section") ?? "home", body!.Num("position") ?? 0))));
                if (_waiting.Count == patches) release = [.. _waiting];
            }
            // Each answer completes on a pool thread of its own, all at about the same time.
            foreach (var (waiting, task) in release) ThreadPool.QueueUserWorkItem(_ => waiting.SetResult(task));
            return answer.Task;
        }

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => throw new NotSupportedException();

        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => throw new NotSupportedException();
    }

    [Fact]
    public Task AMoveOfManyTasksWhoseAnswersArriveOnPoolThreadsTouchesTheStoreOnlyOnItsOwnThread() => MainLoop.Drive(async () =>
    {
        var owner = Environment.CurrentManagedThreadId;
        var rest = new PoolRest(patches: 3);
        var store = new TasksStore(new TasksApi(rest));
        var changed = new List<int>();
        var notices = new List<string>();
        store.Changed += () => changed.Add(Environment.CurrentManagedThreadId);
        store.Notice += (text, _) => notices.Add(text);
        await store.RefreshAsync();
        Assert.True(store.SectionsSupported);

        Assert.True(await store.MoveAsync(["t1", "t2", "t3"], "home"));

        // Every change, and every call the store made, on the one thread that drives it.
        Assert.All(changed, t => Assert.Equal(owner, t));
        Assert.All(rest.Threads, t => Assert.Equal(owner, t));
        Assert.Equal(1 + 3, rest.Threads.Count);
        Assert.Equal(owner, Environment.CurrentManagedThreadId);
        // In Home, in the order given, at its end, each with the gateway's rev; nothing refused.
        Assert.Equal([("t0", 40.0, 1), ("t1", 41.0, 2), ("t2", 42.0, 2), ("t3", 43.0, 2)],
            store.Tasks.Where(t => t.Section == "home").OrderBy(t => t.Order).Select(t => (t.Id, t.Order, t.Rev)));
        Assert.Empty(notices);
    });
}
