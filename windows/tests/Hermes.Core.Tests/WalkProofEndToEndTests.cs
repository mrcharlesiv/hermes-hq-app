using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// The stand-in records the screenshot walks read (`WalkProof`), produced by the same Hermes.Core paths the app drives:
/// `/new draft words` through the composer against composer-gateway.py, and Auto-Archive on with Archive After 14
/// against settings-gateway.py. Run through windows/scripts/e2e.sh; without the credentials these pass vacuously. Each
/// shares its stand-in's collection, so no other test resets or writes to that stand-in meanwhile.
[Trait("Category", "E2E")]
public class WalkProofEndToEndTests
{
    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
    }

    private static async Task Until(Func<bool> condition, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    [Collection(ComposerStandIn.Name)]
    [Trait("Category", "E2E")]
    public class NewChat
    {
        [Fact]
        public async Task NewWithWordsMakesOneChatAndSendsNothing()
        {
            var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
            if (path == null || !File.Exists(path)) return;
            var cred = JsonNode.Parse(File.ReadAllText(path))!;
            var url = cred.Str("url")!;
            var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
            await using var client = new HermesClient(session);
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            var bot = (await client.BotsAsync()).First(b => b.Name == "default");
            await using var chat = client.OpenChat(bot.Name, await client.BotChatIdAsync(bot), bot.DisplayName);
            using var composer = new ChatComposer(chat, new ModelPrefs(client.AccountId, new MemoryStore()), isBotChat: true);
            await chat.OpenAsync();
            // The collection's earlier tests (Composer's steer and queue) can leave this bot's chat replying on a slow
            // runner; a send then queues instead of submitting, so start from an idle chat.
            await Until(() => !chat.Busy, 30);
            var sessions = new SessionStore(new ClientGateway(client), new MemoryDeviceStore());
            NewChatOpening? opened = null;
            Exception? failed = null;
            Task? making = null;
            composer.Hooks.NewChat = arg =>
                (making = NewChatCommand.Start(chat.Profile, arg, p => p == bot.Name, p => sessions.NewChatAsync(p),
                    o => opened = o, e => failed = e)) != null;
            await Task.Delay(500);   // the open chat's own binding calls settle before the mark
            var mark = WalkProof.LastCallAt(await Get(url, "/__menus/state"));

            composer.Send("/new draft words");
            await Until(() => making != null);
            await making!;
            Assert.Null(failed);
            Assert.NotNull(opened);
            Assert.Equal((bot.Name, "draft words"), (opened!.Profile, opened.Draft));
            Assert.NotEqual(chat.StoredId, opened.StoredId);
            await Task.Delay(500);
            var state = await Get(url, "/__menus/state");
            Assert.Null(WalkProof.NewChatSentNothing(state, mark, bot.Name));
            Assert.DoesNotContain(chat.Messages, m => m.Role == Role.User && m.Text.Contains("draft words"));

            // The check sees a prompt when there is one: a real send afterwards is caught.
            composer.Send("hello there");
            await Until(() => (WalkProof.NewChatSentNothing(Get(url, "/__menus/state").Result, mark, bot.Name) ?? "").Contains("prompt.submit"));
            await Until(() => !chat.Busy, 20);
        }
    }

    /// The chat-find walk's chat and word: the composer stand-in's Trip planning chat, opened as the app opens it, finds
    /// "food" twice, and Find counts it as the walk expects (the newest first, then F3 wraps to the oldest and steps on).
    [Collection(ComposerStandIn.Name)]
    [Trait("Category", "E2E")]
    public class TripFind
    {
        [Fact]
        public async Task TheTripChatFindsFoodTwice()
        {
            var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
            if (path == null || !File.Exists(path)) return;
            var cred = JsonNode.Parse(File.ReadAllText(path))!;
            var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(cred.Str("url")!), cred.Str("username")!, cred.Str("password")!);
            await using var client = new HermesClient(session);
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            var sessions = new SessionStore(new ClientGateway(client), new MemoryDeviceStore());
            await sessions.RefreshAsync();
            var listed = sessions.LiveSummaries();
            Assert.Contains(listed, s => s.Id == WalkProof.TripStoredId);
            await using var chat = client.OpenChat("default", WalkProof.TripStoredId, WalkProof.TripTitle);
            await chat.OpenAsync();
            await Until(() => chat.Messages.Count(m => m.Role is Role.User or Role.Assistant) >= 6);
            var find = new Hermes.Core.Transcripts.ChatFindModel();
            find.Open();
            find.Search(WalkProof.FindWord, chat.Messages, keepCurrent: false, chat.HasOlder);
            Assert.Equal(WalkProof.FindMatches, find.Matches.Count);
            Assert.Equal($"{WalkProof.FindMatches} of {WalkProof.FindMatches}", find.CountText);
            find.Step(forward: true);
            Assert.Equal($"1 of {WalkProof.FindMatches}", find.CountText);
            find.Step(forward: true);
            Assert.Equal($"2 of {WalkProof.FindMatches}", find.CountText);
        }
    }

    /// The tasks-sort-select walk's list against the stand-in it runs on (pages-fixture-gateway.py --task-lists,
    /// HQW_E2E_TASKS_CREDENTIALS): Home in My Order, then Sort By › Due Date saved as the walk checks it and shown in
    /// the order it expects; then My Order again, as the stand-in started.
    [Trait("Category", "E2E")]
    public class TasksSortByDue
    {
        [Fact]
        public Task HomeSortsByDueAndTheStandInRecordsTheWholeSettings() => MainLoop.Drive(async () =>
        {
            var path = Environment.GetEnvironmentVariable("HQW_E2E_TASKS_CREDENTIALS");
            if (path == null || !File.Exists(path)) return;
            var cred = JsonNode.Parse(File.ReadAllText(path))!;
            var url = cred.Str("url")!;
            var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
            var store = new Hermes.Core.Tasks.TasksStore(new Hermes.Core.Tasks.TasksApi(new Hermes.Core.Kanban.GatewaySessionRest(session)));
            await store.RefreshAsync();
            Assert.True(store.HasList, store.Error);
            Assert.Contains(store.Sections, s => s.Id == WalkProof.HomeList && s.Name == "Home");
            var home = Hermes.Core.Tasks.TodoView.List(WalkProof.HomeList);
            Assert.True(Hermes.Core.Tasks.TodoSortBy.Shows(home));
            Assert.Contains(Hermes.Core.Tasks.TodoSortBy.Options(store.FieldsSupported, store.Settings.Sort), o => o.Key == "due" && o.Title == "Due Date");
            string[] Shown() => [.. Hermes.Core.Tasks.TodoViews.Groups(store.Tasks, home, store.Sections, [], DateTimeOffset.Now, TimeZoneInfo.Local, store.Settings.Sort)
                .SelectMany(g => g.Tasks).Select(t => t.Id)];
            Assert.Equal("smart", store.Settings.Sort);
            Assert.Null(WalkProof.Order(Shown(), WalkProof.HomeMyOrder, "Home"));
            var mark = WalkProof.RestCount(await Get(url, "/__fixture/state"));
            try
            {
                Assert.True(await store.SetSortAsync("due"));
                Assert.Null(WalkProof.Order(Shown(), WalkProof.HomeByDue, "Home"));
                var state = await Get(url, "/__fixture/state");
                Assert.Null(WalkProof.TasksSortSaved(state, mark, "due"));
                Assert.Equal("the last PUT /tasks/settings saved sort due, not added", WalkProof.TasksSortSaved(state, mark, "added"));
                // A tick is a write the check catches.
                Assert.True(await store.SetDoneAsync("t_porch", true));
                Assert.Equal("the walk wrote PATCH /api/plugins/hermes-hq-push/tasks/t_porch",
                    WalkProof.TasksSortSaved(await Get(url, "/__fixture/state"), mark, "due"));
            }
            finally
            {
                // As the stand-in started, for the walk's own run on a fresh copy and anything after this test.
                await store.SetDoneAsync("t_porch", false);
                await store.SetSortAsync("smart");
            }
            await store.RefreshAsync(force: true);
            Assert.Null(WalkProof.Order(Shown(), WalkProof.HomeMyOrder, "Home"));
        });

        /// [WIN-28] The tasks-select-actions walk against the same stand-in (a fact of this class, so it never runs
        /// beside the Sort By one): Home by Due Date, Mark Done on the first two, Move To › Work on the next, Delete on
        /// the last, each through the TasksStore call Select makes and each recorded as the walk checks it. The stand-in
        /// is re-seeded before and after.
        [Fact]
        public Task SelectsActionsAreWhatTheStandInRecords() => MainLoop.Drive(async () =>
        {
            var path = Environment.GetEnvironmentVariable("HQW_E2E_TASKS_CREDENTIALS");
            if (path == null || !File.Exists(path)) return;
            var cred = JsonNode.Parse(File.ReadAllText(path))!;
            var url = cred.Str("url")!;
            using var http = new HttpClient();
            async Task Reset() => (await http.PostAsync(url.TrimEnd('/') + "/__fixture/reset", new StringContent("{}"))).EnsureSuccessStatusCode();
            await Reset();
            var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
            var store = new Hermes.Core.Tasks.TasksStore(new Hermes.Core.Tasks.TasksApi(new Hermes.Core.Kanban.GatewaySessionRest(session)));
            await store.RefreshAsync();
            Assert.True(store.HasList, store.Error);
            Assert.Contains(store.Sections, s => s.Id == WalkProof.TasksMoveTo && s.Name == "Work");
            var home = Hermes.Core.Tasks.TodoView.List(WalkProof.HomeList);
            // The open rows the page shows (Done folds away under its own line).
            string[] Open() => [.. Hermes.Core.Tasks.TodoViews.Groups(store.Tasks, home, store.Sections, [], DateTimeOffset.Now, TimeZoneInfo.Local, store.Settings.Sort)
                .SelectMany(g => g.Tasks).Where(t => !t.IsDone).Select(t => t.Id)];
            try
            {
                Assert.True(await store.SetSortAsync("due"));
                Assert.Null(WalkProof.Order(Open(), WalkProof.HomeByDue, "Home"));

                var mark = WalkProof.RestCount(await Get(url, "/__fixture/state"));
                var toMark = Hermes.Core.Tasks.TodoSelection.ToMarkDone(WalkProof.TasksDonePicks, store.Find);
                Assert.Equal(WalkProof.TasksDonePicks, toMark);
                Assert.All(await Task.WhenAll(toMark.Select(id => store.SetDoneAsync(id, true))), Assert.True);
                Assert.Null(WalkProof.TasksMarkedDone(await Get(url, "/__fixture/state"), mark, WalkProof.TasksDonePicks));
                Assert.Null(WalkProof.Order(Open(), WalkProof.HomeAfterDone, "Home after Mark Done"));

                mark = WalkProof.RestCount(await Get(url, "/__fixture/state"));
                Assert.True(await store.MoveAsync([WalkProof.TasksMovePick], WalkProof.TasksMoveTo));
                Assert.Null(WalkProof.TasksMovedTo(await Get(url, "/__fixture/state"), mark, [WalkProof.TasksMovePick], WalkProof.TasksMoveTo));
                Assert.Null(WalkProof.Order(Open(), WalkProof.HomeAfterMove, "Home after Move To"));

                mark = WalkProof.RestCount(await Get(url, "/__fixture/state"));
                Assert.True(await store.DeleteAsync(WalkProof.TasksDeletePick));
                Assert.Null(WalkProof.TasksDeleted(await Get(url, "/__fixture/state"), mark, [WalkProof.TasksDeletePick]));
                Assert.Empty(Open());
                // A second Mark Done would be caught as a write the Delete step never makes.
                Assert.Equal("the walk wrote DELETE /api/plugins/hermes-hq-push/tasks/" + WalkProof.TasksDeletePick,
                    WalkProof.TasksMovedTo(await Get(url, "/__fixture/state"), mark, [WalkProof.TasksMovePick], WalkProof.TasksMoveTo));
            }
            finally
            {
                await Reset();   // as the stand-in started, for the walk's own run on a fresh copy and the Sort By fact
            }
        });
    }

    /// [WIN-28] The quick-action-send walk's tile against the composer stand-in: the bot's own chat takes the words as
    /// one prompt.submit, as the walk checks it.
    [Collection(ComposerStandIn.Name)]
    [Trait("Category", "E2E")]
    public class QuickActionSend
    {
        [Fact]
        public async Task TheSendTilesWordsAreOnePromptInTheBotsOwnChat()
        {
            var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
            if (path == null || !File.Exists(path)) return;
            var cred = JsonNode.Parse(File.ReadAllText(path))!;
            var url = cred.Str("url")!;
            var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
            await using var client = new HermesClient(session);
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            var bot = (await client.BotsAsync()).First(b => b.Name == WalkProof.QuickSendBot);
            var tile = WalkProof.QuickSendTile(bot.DisplayName);
            var world = new Hermes.Core.QuickActions.QuickTileWorld(Bots: new Dictionary<string, string> { [bot.Name] = bot.DisplayName });
            var route = Assert.IsType<Hermes.Core.QuickActions.QuickTileRoute.SendInChat>(
                Hermes.Core.QuickActions.QuickTileRoute.Make(tile, world, Hermes.Core.QuickActions.QuickTileRules.Windows));
            var chatId = await client.BotChatIdAsync(bot);
            await Task.Delay(300);
            var mark = WalkProof.LastCallAt(await Get(url, "/__menus/state"));
            await using var chat = client.OpenChat(route.Profile, chatId, bot.DisplayName);
            Assert.Equal(SendOutcome.Accepted, await chat.SendAsync(route.Words));
            string? why;
            var until = DateTime.UtcNow.AddSeconds(15);
            while ((why = WalkProof.QuickSentInChat(await Get(url, "/__menus/state"), mark, WalkProof.QuickSendWords)) != null && DateTime.UtcNow < until)
                await Task.Delay(100);
            Assert.Null(why);
        }
    }

    /// [WIN-28] The quick-action-run walk's tile against the jobs stand-in: its job is there under the walk's name and
    /// owner, and running it is one trigger for that owner and the words the page shows.
    [Collection(JobsStandIn.Name)]
    [Trait("Category", "E2E")]
    public class QuickActionRun
    {
        [Fact]
        public async Task TheRunJobTileTriggersMorningInboxTriageOnce()
        {
            var path = Environment.GetEnvironmentVariable("HQW_E2E_JOBS_CREDENTIALS");
            if (path == null || !File.Exists(path)) return;
            var cred = JsonNode.Parse(File.ReadAllText(path))!;
            var url = cred.Str("url")!;
            var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
            using var store = new Hermes.Core.Jobs.JobsStore(new Hermes.Core.Jobs.JobsApi(session));
            await store.RefreshAsync();
            var until = DateTime.UtcNow.AddSeconds(15);
            while (!store.HasList && DateTime.UtcNow < until) await Task.Delay(100);
            Assert.True(store.HasList);
            var job = Assert.Single(store.Jobs, j => j.Id == WalkProof.QuickRunJobId);
            Assert.Equal(WalkProof.QuickRunJobOwner, job.Owner);
            Assert.Equal(WalkProof.QuickRunJobName, store.Title(job));
            Assert.Equal(job.Key, WalkProof.QuickRunTile().Job);
            var world = new Hermes.Core.QuickActions.QuickTileWorld(Jobs: Hermes.Core.QuickActions.QuickTileRun.WorldJobs(store.Jobs, store.Scope));
            var route = Assert.IsType<Hermes.Core.QuickActions.QuickTileRoute.RunJob>(
                Hermes.Core.QuickActions.QuickTileRoute.Make(WalkProof.QuickRunTile(), world, Hermes.Core.QuickActions.QuickTileRules.Windows));
            var (owner, id) = Hermes.Core.QuickActions.QuickTileRun.Job(route.Key, store.Jobs)!.Value;
            var mark = WalkProof.RestCount(await Get(url, "/__fixture/state"));
            var said = await Hermes.Core.QuickActions.QuickTileRun.RunJobAsync(store.Api, owner, id, route.Name);
            var done = Assert.IsType<Hermes.Core.QuickActions.QuickTileSaid.Done>(said);
            Assert.Equal(WalkProof.QuickRunNotice(WalkProof.QuickRunJobName), "\u2713 " + done.Words);
            Assert.Null(WalkProof.QuickJobTriggered(await Get(url, "/__fixture/state"), mark, WalkProof.QuickRunJobId, WalkProof.QuickRunJobOwner));
        }
    }

    [Collection(SettingsStandIn.Name)]
    [Trait("Category", "E2E")]
    public class AutoArchiveOn
    {
        [Fact]
        public async Task SwitchOnThenFourteenDaysIsWhatTheStandInRecords()
        {
            var path = Environment.GetEnvironmentVariable("HQW_E2E_SETTINGS_CREDENTIALS");
            if (path == null || !File.Exists(path)) return;
            var cred = JsonNode.Parse(File.ReadAllText(path))!;
            var url = cred.Str("url")!;
            var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
            var store = new GatewayConfigStore(new GatewayConfigApi(session));   // the app's own 550 ms debounce
            await store.LoadAsync();
            Assert.Equal(GatewayConfigStore.LoadPhase.Loaded, store.Phase);
            var wasOn = AutoArchive.Enabled(store);
            var wasDays = AutoArchive.StoredDays(store);
            if (wasOn) { AutoArchive.Toggle(store, false); await store.Flush(); }
            await Task.Delay(100);
            var mark = WalkProof.LastWriteAt(await Get(url, "/__settings/state"));
            try
            {
                // As the walk does it: the switch, then 14 typed in Archive After and the field left, then the debounce.
                AutoArchive.Toggle(store, true);
                Assert.Equal("14", AutoArchive.CommitDays(store, "14"));
                await Task.Delay(store.Debounce + TimeSpan.FromSeconds(1.5));
                Assert.Null(store.Failure);
                Assert.Null(WalkProof.AutoArchiveSaved(await Get(url, "/__settings/state"), mark, 14));
                Assert.Equal("sessions.auto_archive_days ended 14, not 30",
                    WalkProof.AutoArchiveSaved(await Get(url, "/__settings/state"), mark, 30));
            }
            finally
            {
                // Back as it was, for the other settings tests on this stand-in.
                store.Set(AutoArchive.EnabledKey, JsonValue.Create(wasOn));
                store.Set(AutoArchive.DaysKey, JsonValue.Create(wasDays));
                await store.Flush();
            }
        }
    }
    /// [WIN-34] View › Refresh on Sessions (SessionsPage.KeyRefresh → SessionStore.RefreshAsync): the composer stand-in logs
    /// a second GET of the chats listing and nothing written, as the window-keys walk checks after Ctrl+R.
    [Collection(ComposerStandIn.Name)]
    [Trait("Category", "E2E")]
    public class SessionsRefresh
    {
        [Fact]
        public async Task ASecondReadOfTheSessionsListReachesTheStandIn()
        {
            var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
            if (path == null || !File.Exists(path)) return;
            var cred = JsonNode.Parse(File.ReadAllText(path))!;
            var url = cred.Str("url")!;
            var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
            await using var client = new HermesClient(session);
            var sessions = new SessionStore(new ClientGateway(client), new MemoryDeviceStore());
            await sessions.RefreshAsync();
            Assert.Contains(sessions.LiveSummaries(), s => s.Id == WalkProof.TripStoredId);
            var mark = ChatKeys.RestCount(await Get(url, "/__menus/state"));
            Assert.Equal($"no second GET {WalkProof.SessionsListPath} reached the gateway", WalkProof.Refetched(await Get(url, "/__menus/state"), mark));
            await sessions.RefreshAsync();
            Assert.Null(WalkProof.Refetched(await Get(url, "/__menus/state"), mark));
        }
    }
}

/// The tests that drive composer-gateway.py one at a time (ComposerEndToEndTests resets it and sends prompts).
[CollectionDefinition(Name, DisableParallelization = true)]
public class ComposerStandIn { public const string Name = "composer stand-in"; }

/// The tests that drive settings-gateway.py one at a time (SettingsEndToEndTests resets it and writes its config).
[CollectionDefinition(Name, DisableParallelization = true)]
public class SettingsStandIn { public const string Name = "settings stand-in"; }
