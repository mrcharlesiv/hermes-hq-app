using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// New List, Rename List, Move Right, Delete List and Tasks Settings against ci/fixtures/pages-fixture-gateway.py (the
/// add-on's `PUT /tasks/sections` and `PUT /tasks/settings`). Run through windows/scripts/e2e.sh
/// (HQW_E2E_PAGES_CREDENTIALS); without them this passes vacuously. Shares the stand-in with KanbanEndToEndTests, so the
/// two never run at once.
[Trait("Category", "E2E")]
[Collection(PagesStandIn.Name)]
public class TasksListsEndToEndTests
{
    private static async Task<JsonNode> Fixture(string url, string path, object? body = null)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var r = body == null ? await http.GetAsync(url.TrimEnd('/') + path)
            : await http.PostAsync(url.TrimEnd('/') + path, new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json"));
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync()) ?? new JsonObject();
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

    [Fact]
    public Task ListsAreMadeRenamedMovedAndDeletedAndASettingReadsBack() => MainLoop.Drive(async () =>
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_PAGES_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Fixture(url, "/__fixture/reset", new { });
        using var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        var store = new TasksStore(new TasksApi(new GatewaySessionRest(session)));
        var notices = new List<string>();
        store.Notice += (text, _) => notices.Add(text);
        await store.RefreshAsync();
        Assert.True(store.HasList, store.Error);
        Assert.True(store.EditsLists);
        var before = store.Sections.Select(s => s.Id).ToList();

        // New List, then Move To › New List… with a task of the stand-in's.
        var errands = await store.AddSectionAsync("Errands (lists e2e)");
        Assert.NotNull(errands);
        Assert.False(TodoIds.IsLocal(errands!.Id));
        var task = (await store.AddAsync(TodoWire.NewTask("Return the library books (lists e2e)", TodoWho.Me, null, null, null, false)))!;
        var done = (await store.AddAsync(TodoWire.NewTask("Buy stamps (lists e2e)", TodoWho.Me, null, null, null, false)))!;
        var garden = await store.AddSectionAsync("Garden (lists e2e)");
        Assert.True(await store.MoveAsync([task.Id, done.Id], garden!.Id));
        Assert.True(await store.SetDoneAsync(done.Id, true));
        var again = new TasksStore(new TasksApi(new GatewaySessionRest(session)));
        await again.RefreshAsync();
        Assert.Equal([.. before, errands.Id, garden.Id], again.Sections.Select(s => s.Id));
        Assert.NotNull(again.Sections.Single(s => s.Id == garden.Id).Color);   // 0.9.55: a new list has a colour

        // Rename List keeps its colour; Move Left puts Garden before Errands.
        var colour = again.Sections.Single(s => s.Id == errands.Id).Color;
        Assert.True(await store.RenameSectionAsync(errands.Id, "Weekend Errands (lists e2e)"));
        Assert.True(await store.MoveSectionAsync(garden.Id, -1));
        await again.RefreshAsync(force: true);
        var renamed = again.Sections.Single(s => s.Id == errands.Id);
        Assert.Equal(("Weekend Errands (lists e2e)", colour), (renamed.Name, renamed.Color));
        Assert.Equal([.. before, garden.Id, errands.Id], again.Sections.Select(s => s.Id));

        // Delete List: its words count what's in it, and its tasks stay, in no list.
        var inside = again.Tasks.Where(t => t.Section == garden.Id).ToList();
        Assert.Equal("Its 1 task and 1 done task are kept, in no list.", TodoListCopy.DeleteMessage(inside.Count(t => !t.IsDone), inside.Count(t => t.IsDone)));
        Assert.True(await store.DeleteSectionAsync(garden.Id));
        await Until(async () => { await again.RefreshAsync(force: true); return !again.Sections.Any(s => s.Id == garden.Id); });
        Assert.Equal((null, null), (again.Find(task.Id)?.Section, again.Find(done.Id)?.Section));
        Assert.NotNull(again.Find(task.Id));
        Assert.NotNull(again.Find(done.Id));
        Assert.True(await store.DeleteSectionAsync(errands.Id));
        await again.RefreshAsync(force: true);
        Assert.Equal(before, again.Sections.Select(s => s.Id));

        // Tasks Settings: Catch Tasks in Chats › Automatic and Times a Day 9, read back by a new store.
        var model = new TodoSettingsModel(store, [("default", "Hermes")]);
        Assert.True(await model.SetCapture("auto"));
        Assert.True(await model.SetPrepPerDay(9));
        Assert.True(await model.SetQuietStart(new TimeSpan(21, 30, 0)));
        var put = (await Fixture(url, "/__fixture/state")).Arr("rest")!.Last(r => r.Str("method") == "PUT" && r.Str("path") == TasksApi.Base + "/settings");
        Assert.Equal(("auto", 9L, "21:30"), (put.Obj("body").Str("capture"), put.Obj("body").Int("prep_per_day"), put.Obj("body").Str("quiet_start")));
        var fresh = new TasksStore(new TasksApi(new GatewaySessionRest(session)));
        await fresh.RefreshAsync();
        Assert.Equal(("auto", 9, "21:30"), (fresh.Settings.Capture, fresh.Settings.PrepPerDay, fresh.Settings.QuietStart));
        Assert.True(await model.SetCapture("ask"));
        await fresh.RefreshAsync(force: true);
        Assert.Equal("ask", fresh.Settings.Capture);

        foreach (var id in new[] { task.Id, done.Id }) Assert.True(await store.DeleteAsync(id));
        Assert.Empty(notices);
    });
}

/// The pages stand-in is one gateway: the tests that reset it run one at a time.
[CollectionDefinition(PagesStandIn.Name)]
public sealed class PagesStandIn { public const string Name = "pages-stand-in"; }
