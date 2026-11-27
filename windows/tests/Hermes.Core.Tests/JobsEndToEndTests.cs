using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Jobs;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Jobs against windows/ci/fixtures/jobs-gateway.py (which layers on pages-fixture-gateway.py): the list and its
/// sections, run history, Pause / Resume, Run Now, New Job (plain and from a template), Edit Job sending only what
/// changed, the editor's reads, Delete, `cron.changed` over the socket and a read-only refusal. Run through
/// windows/scripts/e2e.sh (HQW_E2E_JOBS_CREDENTIALS); without it these pass vacuously. Every wait is a deadline.
[Trait("Category", "E2E")]
[Collection(JobsStandIn.Name)]
public class JobsEndToEndTests
{
    private static async Task Until(Func<bool> condition, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    private static async Task<JsonNode> Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var r = await http.PostAsync(url.TrimEnd('/') + path,
            new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json"));
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync())!;
    }

    private static async Task<List<JsonNode>> Requests(string url, string method, string path)
    {
        using var http = new HttpClient();
        var state = JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + "/__fixture/state"))!;
        return [.. (state.Arr("requests") ?? []).OfType<JsonNode>().Where(r => r.Str("method") == method && r.Str("path") == path)];
    }

    [Fact]
    public async Task ListRunPauseCreateEditTemplateDeleteAndChangeEvents()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_JOBS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__fixture/reset", new { });

        var signIn = new SignIn(new MemoryTokenStore());
        var session = await signIn.PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        using var store = new JobsStore(new JobsApi(session));

        // The list, sorted by title, in the web's sections.
        await store.RefreshAsync();
        await Until(() => store.HasList);
        var titles = store.Jobs.Select(store.Title).ToList();
        Assert.Contains("Morning inbox triage", titles);
        Assert.Contains("Release watch", titles);
        Assert.Equal(titles.OrderBy(t => t, NaturalComparer.Instance), titles);
        var bySection = store.Jobs.GroupBy(j => JobWords.Section(j)).ToDictionary(g => g.Key, g => g.Select(store.Title).ToList());
        Assert.Contains("Nightly finance report", bySection[JobSection.Paused]);
        Assert.Contains("One-off backup", bySection[JobSection.Completed]);
        Assert.Contains("Gbrain daily update check local", bySection[JobSection.NeedsAttention]);

        // Run history.
        var triage = store.Jobs.First(j => j.Id == "j-triage");
        var runs = await store.LoadRunsAsync(triage);
        Assert.NotEmpty(runs);
        Assert.All(runs, r => Assert.NotEqual("", JobWords.CronRunLabel(r).Title));

        // Pause and Resume replace the row with the gateway's answer.
        Assert.Equal(WriteKind.Done, (await store.SetPausedAsync(triage, true)).Kind);
        await Until(() => JobWords.IsPaused(store.Job(triage.Key)!));
        Assert.Equal(JobSection.Paused, JobWords.Section(store.Job(triage.Key)!));
        Assert.Equal(WriteKind.Done, (await store.SetPausedAsync(store.Job(triage.Key)!, false)).Kind);
        await Until(() => !JobWords.IsPaused(store.Job(triage.Key)!));

        // Run Now: the trigger answers when the run ends.
        var watch = store.Jobs.First(j => j.Id == "j-watch");
        var run = await store.RunNowAsync(watch);
        Assert.Equal(RunKind.Started, run.Kind);
        Assert.NotEmpty(await Requests(url, "POST", "/api/cron/jobs/j-watch/trigger"));

        // New Job: the editor's reads, then a plain create with a model and a delivery place.
        var bots = new List<(string, string)> { ("default", "Hermes"), ("inbox", "Inbox") };
        var create = new JobEditorModel(store, null, bots, "default");
        await create.LoadAsync();
        await Until(() => create.TargetsState == EditorLoad.Loaded && create.ModelsState == EditorLoad.Loaded);
        var groups = create.DeliveryGroups;
        Assert.Contains(groups.Places, r => r.Id == "telegram");
        Assert.Contains("Discord", groups.NeedsHome);
        Assert.Contains(groups.Bots, r => r.Id == "bot-chat:inbox");
        Assert.Equal(["anthropic", "nous"], create.Providers.Select(p => p.Slug));
        await Until(() => create.Blueprints.Count > 0);
        create.SetPrompt("Collect the week's receipts and file them.");
        create.SetName("Receipts");
        create.SetFrequency(JobFrequency.Weekly);
        create.SetFields(create.Fields with { Hour = 7, Minute = 30 });
        Assert.True(create.ToggleDelivery("telegram"));
        create.SetModel(new JobModelChoice("anthropic", "claude-sonnet-5"));
        var made = await create.SaveAsync();
        Assert.Equal(EditorOutcomeKind.Created, made.Kind);
        var posted = (await Requests(url, "POST", "/api/cron/jobs")).Last()["body"]!;
        Assert.Equal("30 7 * * 1", posted.Str("schedule"));
        Assert.Equal("telegram", posted.Str("deliver"));
        Assert.Equal("anthropic", posted.Str("provider"));
        await Until(() => store.Jobs.Any(j => j.Name == "Receipts"));
        var receipts = store.Jobs.First(j => j.Name == "Receipts");

        // Edit Job sends only what changed.
        var edit = new JobEditorModel(store, receipts, bots, receipts.Owner);
        await edit.LoadAsync();
        edit.SetFields(edit.Fields with { Hour = 8 });
        Assert.Equal(EditorOutcomeKind.Saved, (await edit.SaveAsync()).Kind);
        var put = (await Requests(url, "PUT", "/api/cron/jobs/" + receipts.Id)).Last()["body"]!["updates"]!.AsObject();
        Assert.Equal(["schedule"], put.Select(kv => kv.Key));
        Assert.Equal("30 8 * * 1", put["schedule"]!.GetValue<string>());
        await Until(() => store.Job(receipts.Key)?.Schedule?.Expr == "30 8 * * 1");

        // A template: Morning briefing with its time and deliver slots.
        var brief = create.Blueprints.First(b => b.Key == "morning-brief");
        var fromTemplate = new JobEditorModel(store, null, bots, "default", brief);
        Assert.Equal("08:00", fromTemplate.Form.Slots["time"]);
        Assert.Equal("local", fromTemplate.Form.Slots["deliver"]);
        fromTemplate.SetSlot("time", "06:45");
        Assert.Equal(EditorOutcomeKind.Created, (await fromTemplate.SaveAsync()).Kind);
        var instantiated = (await Requests(url, "POST", "/api/cron/blueprints/instantiate")).Last()["body"]!;
        Assert.Equal("06:45", instantiated["values"]!.Str("time"));
        await Until(() => store.Jobs.Any(j => j.Schedule?.Expr == "45 6 * * *"));

        // Delete.
        Assert.Equal(WriteKind.Done, (await store.DeleteAsync(store.Job(receipts.Key)!)).Kind);
        Assert.Null(store.Job(receipts.Key));
        await store.RefreshAsync();
        Assert.Null(store.Job(receipts.Key));

        // Another client's change arrives as cron.changed over the socket; the store reads again.
        var changed = 0;
        client.Rpc.Event += e => { if (e.Type == "cron.changed") { Interlocked.Increment(ref changed); store.CronChanged(); } };
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(20)).Token);
        await Post(url, "/__fixture/job", new { add = new { id = "j-other", name = "Added elsewhere", profile = "default" } });
        await Until(() => changed > 0 && store.Jobs.Any(j => j.Id == "j-other"));

        // A gateway job that disappeared closes its page.
        string? removed = null;
        store.JobRemoved += key => removed = key;
        await Post(url, "/__fixture/job", new { delete = "j-other", broadcast = false });
        var (read, gone) = await store.ReloadAsync(store.Jobs.First(j => j.Id == "j-other"));
        Assert.True(read);
        Assert.Null(gone);
        Assert.Equal("default|j-other", removed);

        // Read-only: refused before any request.
        store.ReadOnlyGateway = true;
        var before = (await Requests(url, "POST", "/api/cron/jobs/j-watch/trigger")).Count;
        Assert.Equal(RunKind.Refused, (await store.RunNowAsync(store.Jobs.First(j => j.Id == "j-watch"))).Kind);
        Assert.Equal(before, (await Requests(url, "POST", "/api/cron/jobs/j-watch/trigger")).Count);
    }
}
