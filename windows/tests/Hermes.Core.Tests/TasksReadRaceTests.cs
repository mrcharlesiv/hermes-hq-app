using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// A read of the list that leaves before an add or a delete lands, and answers after it (HermesKit/Pages/Tasks/
/// TasksStore.swift `adopt`). New List saves the lists and reads the list again without waiting; a task added while
/// that read is out isn't in its answer, and the answer must not take the task away (nor bring back one deleted while
/// it was out). Before the fix, Move To then skipped the missing task, so TasksListsEndToEndTests found only the done
/// task in Garden about half the time.
public class TasksReadRaceTests
{
    /// The add-on, with each `GET /tasks` answered from what it held when the read left, but only when the test lets it go.
    private sealed class HeldReads : IPagesRest
    {
        public readonly Dictionary<string, JsonObject> Tasks = [];
        public JsonArray Sections = [];
        public bool Hold;
        public readonly List<(JsonObject Answer, TaskCompletionSource<JsonNode?> Gate)> Held = [];
        public readonly List<(string Method, string Path, JsonNode? Body)> Log = [];
        private int _rev = 1, _made;

        private JsonObject List() => new()
        {
            ["rev"] = _rev, ["tasks"] = new JsonArray([.. Tasks.Values.Select(t => (JsonNode)t.DeepClone())]),
            ["sections"] = Sections.DeepClone(), ["settings"] = new JsonObject(), ["fields"] = true, ["lists"] = true,
        };

        /// Lets the oldest held read answer, with what it saw when it left.
        public async Task ReleaseAsync()
        {
            var (answer, gate) = Held[0];
            Held.RemoveAt(0);
            gate.SetResult(answer);
            await Task.Yield();
        }

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            Log.Add((method.Method, path, body?.DeepClone()));
            if (method == HttpMethod.Get && path == TasksApi.Base)
            {
                if (!Hold) return Task.FromResult<JsonNode?>(List());
                var gate = new TaskCompletionSource<JsonNode?>();
                Held.Add((List(), gate));
                return gate.Task;
            }
            if (method == HttpMethod.Post && path == TasksApi.Base)
            {
                var id = "t_" + ++_made;
                var row = new JsonObject { ["id"] = id, ["title"] = body.Str("title"), ["status"] = "open", ["who"] = "me", ["rev"] = 1 };
                Tasks[id] = row;
                _rev++;
                return Task.FromResult<JsonNode?>(row.DeepClone());
            }
            if (method == HttpMethod.Put && path == TasksApi.Base + "/sections")
            {
                var saved = new JsonArray();
                foreach (var s in body.Arr("sections")!)
                {
                    var row = (JsonObject)s!.DeepClone();
                    if (row.Str("id") is null or "") row["id"] = "sec_" + ++_made;
                    saved.Add(row);
                }
                Sections = saved;
                _rev++;
                return Task.FromResult<JsonNode?>(new JsonObject { ["rev"] = _rev, ["sections"] = saved.DeepClone() });
            }
            var tid = path[(TasksApi.Base.Length + 1)..];
            if (!Tasks.TryGetValue(tid, out var task)) return Task.FromException<JsonNode?>(FakeRest.Http(404, "Task not found"));
            if (method == HttpMethod.Delete) { Tasks.Remove(tid); _rev++; return Task.FromResult<JsonNode?>(new JsonObject { ["ok"] = true }); }
            foreach (var (k, v) in body!.AsObject()) if (k != "rev") task[k] = v?.DeepClone();
            task["rev"] = task.Int("rev") + 1;
            _rev++;
            return Task.FromResult<JsonNode?>(task.DeepClone());
        }

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => throw new NotSupportedException();

        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => throw new NotSupportedException();
    }

    [Fact]
    public async Task ATaskAddedWhileNewListsReadIsOutStaysAndMovesIntoTheList()
    {
        // The end-to-end test's steps: New List (its read held), then two adds, then the read answers between them.
        var addOn = new HeldReads();
        var store = new TasksStore(new TasksApi(addOn));
        await store.RefreshAsync();
        addOn.Hold = true;
        var errands = await store.AddSectionAsync("Errands");
        Assert.NotNull(errands);
        Assert.Single(addOn.Held);   // New List's own read, still out
        var task = (await store.AddAsync(TodoWire.NewTask("Return the library books", TodoWho.Me, null, null, null, false)))!;
        await addOn.ReleaseAsync();   // it left before the add landed, so the task isn't in it
        Assert.NotNull(store.Find(task.Id));
        var done = (await store.AddAsync(TodoWire.NewTask("Buy stamps", TodoWho.Me, null, null, null, false)))!;
        Assert.Equal([task.Id, done.Id], store.Tasks.Select(t => t.Id).Order());

        addOn.Hold = false;
        Assert.True(await store.MoveAsync([task.Id, done.Id], errands!.Id));
        Assert.Equal([errands.Id, errands.Id], new[] { task.Id, done.Id }.Select(id => addOn.Tasks[id].Str("section")));
        while (addOn.Held.Count > 0) await addOn.ReleaseAsync();
    }

    [Fact]
    public async Task ATaskDeletedWhileAReadIsOutDoesNotComeBack()
    {
        var addOn = new HeldReads();
        addOn.Tasks["t_old"] = new JsonObject { ["id"] = "t_old", ["title"] = "Old", ["status"] = "open", ["who"] = "me", ["rev"] = 1 };
        var store = new TasksStore(new TasksApi(addOn));
        await store.RefreshAsync();
        Assert.NotNull(store.Find("t_old"));
        addOn.Hold = true;
        var read = store.RefreshAsync(force: true);   // leaves while t_old is still there
        Assert.True(await store.DeleteAsync("t_old"));
        await addOn.ReleaseAsync();
        await read;
        Assert.Null(store.Find("t_old"));

        // A read that leaves after the delete landed is the truth again (nothing is held back from it).
        addOn.Hold = false;
        addOn.Tasks["t_old"] = new JsonObject { ["id"] = "t_old", ["title"] = "Old", ["status"] = "open", ["who"] = "me", ["rev"] = 1 };
        await store.RefreshAsync(force: true);
        Assert.NotNull(store.Find("t_old"));
    }

    [Fact]
    public async Task ATaskDeletedElsewhereStillGoesOnTheNextRead()
    {
        // The guard is only for reads that crossed this store's own writes: one deleted on the gateway still goes.
        var addOn = new HeldReads();
        var store = new TasksStore(new TasksApi(addOn));
        await store.RefreshAsync();
        var made = (await store.AddAsync(TodoWire.NewTask("Water the plants", TodoWho.Me, null, null, null, false)))!;
        addOn.Tasks.Remove(made.Id);
        await store.RefreshAsync(force: true);
        Assert.Null(store.Find(made.Id));
    }
}
