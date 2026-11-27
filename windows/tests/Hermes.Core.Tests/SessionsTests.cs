using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

public class SessionsPipelineTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1791560000);   // 2026-10-01 evening, UTC

    private static JsonNode Sidebar() => Fixture.Load("demo-sidebar.json") is var j && j["result"] is { } r ? r : j;

    private static SessionSummary S(string id, string profile = "ivy", double at = 1791550000, bool pinned = false, bool unread = false,
        SessionStatus status = SessionStatus.Idle, string? cwd = null, long tokens = 0, double cost = 0, bool archived = false) => new()
    {
        Id = id, Profile = profile, Title = id, LastActive = DateTimeOffset.FromUnixTimeSeconds((long)at), Pinned = pinned,
        Unread = unread, Status = status, Cwd = cwd, Tokens = tokens, Cost = cost, Archived = archived,
        IsRunning = status == SessionStatus.Working,
    };

    [Fact]
    public void DecodesTheDemoSidebar()
    {
        var payload = SidebarPayload.Decode(Sidebar());
        Assert.Equal(7, payload.Recents!.Count);
        var first = payload.Recents[0];
        Assert.Equal("deploys", first.Profile);
        Assert.True(first.Pinned);
        Assert.Equal("Cut the 2.4 branch", SessionRules.Title(first));
        // A failed scan is "Retry", not "No sessions".
        Assert.Null(SidebarPayload.Decode(JsonNode.Parse("""{"recents":{"failed":true,"retry":true},"cron":{"sessions":[]}}""")).Recents);
    }

    [Fact]
    public void RowWords()
    {
        var row = SidebarSessionRow.From(JsonNode.Parse("""
            {"id":"a","profile":"ivy","title":"","preview":"[System: The active model for this chat has changed to gpt-5.] ok",
             "git_branch":"main","model":"openai/gpt-5","message_count":2,"tool_call_count":1,"input_tokens":14200,"output_tokens":1200,
             "actual_cost_usd":null,"estimated_cost_usd":0.34}
            """))!;
        Assert.Equal("Model changed to gpt-5", SessionRules.Title(row));
        Assert.Equal("main · gpt-5 · 2 messages · 1 tool call", SessionRules.Metadata(row.GitBranch, row.Model, row.MessageCount, row.ToolCallCount));
        Assert.Equal(15400, row.TotalTokens);
        Assert.Equal(0.34, row.CostUsd);
        Assert.Equal("15.4k", SessionRowWords.CompactTokens(15400));
        Assert.Equal("1.2M", SessionRowWords.CompactTokens(1_200_000));
        Assert.Equal("$0.34", SessionRowWords.Cost(0.34));
        Assert.Null(SessionRowWords.Cost(0.001));
        Assert.Equal("Ivy", SessionRules.OwnerName("ivy", new Dictionary<string, string>()));
        Assert.Equal("Hermes", SessionRules.OwnerName("default", new Dictionary<string, string>()));
        Assert.Equal("Show 1 more chat", SessionRowWords.ShowMoreLabel(1));
    }

    [Fact]
    public void BackgroundRunsAndBotChatsStayOff()
    {
        Assert.True(SessionRules.IsBackgroundRun(new SidebarSessionRow { Id = "a", Profile = "p", Source = "kanban" }));
        Assert.True(SessionRules.IsProbe(new SidebarSessionRow { Id = "a", Profile = "p", Source = "cli", Preview = "Reply with exactly ROUTE_OK.", MessageCount = 2 }));
        Assert.False(SessionRules.IsProbe(new SidebarSessionRow { Id = "a", Profile = "p", Source = "desktop", Preview = "Reply with exactly ROUTE_OK." }));
        Assert.True(SessionRules.IsBotChat(new SidebarSessionRow { Id = "a", Profile = "p", Title = "Bot Chat" }));
        Assert.True(SessionRules.IsBotChat(new SidebarSessionRow { Id = "a", Profile = "p", Hidden = true }));
    }

    [Fact]
    public void RecentGroupsPinnedThenDays()
    {
        var input = new SessionListInput
        {
            Live = [S("pin", pinned: true), S("today", at: 1791555000), S("yday", at: 1791555000 - 86400), S("old", at: 1791555000 - 20 * 86400)],
            Now = Now, Zone = TimeZoneInfo.Utc,
        };
        var groups = SessionListPipeline.Groups(input);
        Assert.Equal(["Pinned", "Today", "Yesterday", "Older"], groups.Select(g => g.Title));
        Assert.Equal(["pin"], groups[0].Sessions.Select(s => s.Id));
        // Older starts closed when a newer day shows.
        Assert.True(groups[3].Collapsed);
        Assert.Empty(groups[3].Sessions);
        Assert.Equal(1, groups[3].Total);
    }

    [Fact]
    public void FiltersAndChips()
    {
        var live = new List<SessionSummary>
        {
            S("a", unread: true), S("b", status: SessionStatus.Working), S("c", "inbox", status: SessionStatus.NeedsInput), S("d"),
        };
        var counts = SessionListPipeline.ChipCounts(new SessionListInput { Live = live });
        Assert.Equal(2, counts[SessionStatusChip.New]);       // unread, waiting on you
        Assert.Equal(1, counts[SessionStatusChip.Working]);
        Assert.Equal((1, 1, 1), SessionListPipeline.StateCounts(new SessionListInput { Live = live }));
        var chip = SessionListPipeline.Groups(new SessionListInput { Live = live, StatusChip = SessionStatusChip.New, Now = Now });
        Assert.Equal(["a", "c"], chip.Single().Sessions.Select(s => s.Id).Order());
        var bot = SessionListPipeline.Groups(new SessionListInput { Live = live, BotFilter = "inbox", Now = Now });
        Assert.Equal(["c"], bot.SelectMany(g => g.Sessions).Select(s => s.Id));
        var prefs = new SessionsViewPrefs { StatusFilter = [SessionStatus.Working] };
        Assert.Equal(["b"], SessionListPipeline.Groups(new SessionListInput { Live = live, Prefs = prefs, Now = Now }).SelectMany(g => g.Sessions).Select(s => s.Id));
    }

    [Fact]
    public void SortsAndFlatRuns()
    {
        var live = new List<SessionSummary> { S("a", tokens: 10, cost: 2), S("b", tokens: 300, cost: 1), S("c", tokens: 20, cost: 3) };
        var tokens = SessionListPipeline.Groups(new SessionListInput { Live = live, Prefs = new SessionsViewPrefs { SortBy = SessionSortBy.Tokens } });
        Assert.Equal(SessionListPipeline.FlatId, tokens.Single().Id);
        Assert.Equal(["b", "c", "a"], tokens[0].Sessions.Select(s => s.Id));
        Assert.Equal(["c", "a", "b"], SessionListPipeline.Sort(live, SessionSortBy.Cost).Select(s => s.Id));
        var status = SessionListPipeline.Groups(new SessionListInput
        {
            Live = [S("w", status: SessionStatus.Working), S("i")], Prefs = new SessionsViewPrefs { GroupBy = SessionGroupBy.Status }, Now = Now,
        });
        Assert.Equal(["Working", "Done"], status.Select(g => g.Title));
    }

    [Fact]
    public void ProjectsGroupByTheLongestFolderAndOpenAsPages()
    {
        var projects = new Dictionary<string, List<SessionProject>>
        {
            ["ivy"] = [new SessionProject("p1", "Site", "/w/site", ["/w/site"]), new SessionProject("p2", "Docs", "/w/site/docs", ["/w/site/docs"])],
        };
        Assert.Equal("p2", SessionProject.OwnerOf("/w/site/docs/a", projects["ivy"]));
        Assert.Equal("/w/site", SessionProjects.KeyOf("/w/site/src", "ivy", projects));
        Assert.Equal(SessionProjects.HomeKey, SessionProjects.KeyOf("/elsewhere", "ivy", projects));
        var entries = SessionProjects.MenuEntries(projects, ["ivy"]);
        Assert.Equal(["Docs", "Site", "Home"], entries.Select(e => e.Label));
        var live = new List<SessionSummary>
        {
            S("s1", cwd: "/w/site/src", at: 1791550000), S("d1", cwd: "/w/site/docs", at: 1791551000, unread: true), S("h1", at: 1791552000),
        };
        var prefs = new SessionsViewPrefs { GroupBy = SessionGroupBy.Project };
        var groups = SessionListPipeline.Groups(new SessionListInput { Live = live, Prefs = prefs, ProjectsByProfile = projects, Projects = entries, LiveUnderProjects = true });
        Assert.Equal(["Docs", "Site", "Home"], groups.Select(g => g.Title));      // what needs the owner first, Home last
        Assert.True(groups[0].Collapsed);
        Assert.Equal(["d1"], groups[0].Sessions.Select(s => s.Id));               // a closed project keeps its live chats
        prefs.ProjectFilter = ["/w/site"];
        var page = SessionListPipeline.Groups(new SessionListInput
        {
            Live = live, Archived = [S("old", cwd: "/w/site", archived: true)], Prefs = prefs, ProjectsByProfile = projects, Projects = entries,
        });
        Assert.Equal(SessionListPipeline.PageId, page[0].Id);
        Assert.Equal("Site", page[0].LatestTitle);
        Assert.Equal(["Active", "Done"], page.Skip(1).Select(g => g.Title));
        Assert.True(page[2].Collapsed);                                            // Done starts closed
    }

    [Fact]
    public void FilterMenuWordsAndPicks()
    {
        var state = new SessionFilterState { BotCount = 3, HasUnread = true, Projects = [new("/w", "Site"), new("home", "Home")] };
        var nodes = SessionFilterMenu.Nodes(state);
        Assert.Equal(["Sort By", "Group By", "Row Detail"], nodes[0].Children!.Select(n => n.Title));
        Assert.Equal(["Status", "Project", "All Bots", "Show"], nodes[1].Children!.Select(n => n.Title));
        Assert.Equal("Mark All as Read", nodes[2].Children![0].Title);
        Assert.Equal("Recent", nodes[0].Children![1].Subtitle);
        Assert.Equal(["Needs Input", "Working", "Unread", "Draft", "Idle"], nodes[1].Children![0].Children!.Select(n => n.Title));
        Assert.Equal(["Bot Faces", "Projects", "Background Runs", "Archived"], nodes[1].Children![3].Children!.Select(n => n.Title));
        Assert.Equal("Filter and Sort", SessionFilterWords.ButtonLabel(state));

        SessionFilterMenu.Apply(new(SessionFilterActionKind.Status, SessionStatus.Unread), state, "ivy");
        SessionFilterMenu.Apply(new(SessionFilterActionKind.Project, "/w"), state, "ivy");
        Assert.Equal("Filter and Sort, 2 filters on", SessionFilterWords.ButtonLabel(state));
        Assert.Equal("Unread · Project", SessionFilterWords.StripText(state));
        Assert.Equal("Clear Filters", SessionFilterMenu.Nodes(state)[2].Children![0].Title);
        SessionFilterMenu.Apply(new(SessionFilterActionKind.AllBots), state, "ivy");
        Assert.Equal("ivy", state.BotFilter);
        SessionFilterMenu.Apply(new(SessionFilterActionKind.Clear), state, "ivy");
        Assert.Null(state.BotFilter);
        Assert.Empty(state.Prefs.StatusFilter);
        // Into the projects' pills the bot pick goes; out of them the project pick goes.
        state.BotFilter = "ivy";
        SessionFilterMenu.Apply(new(SessionFilterActionKind.Group, SessionGroupBy.Project), state, "ivy");
        Assert.Null(state.BotFilter);
        Assert.Equal(SessionPills.Projects, state.Prefs.Pills);
        state.Prefs.ProjectFilter = ["/w"];
        Assert.Equal(0, SessionFilterWords.FilterCount(state));                    // a project pill is no filter
        SessionFilterMenu.Apply(new(SessionFilterActionKind.Group, SessionGroupBy.Date), state, "ivy");
        Assert.Empty(state.Prefs.ProjectFilter);
    }

    [Fact]
    public void UnreadDotsForSessions()
    {
        var u = new SessionUnreadState();
        var row = new SidebarSessionRow { Id = "a", Profile = "ivy", MessageCount = 4 };
        u.Observe([row]);
        Assert.False(u.IsUnread(row));                                   // a fresh install shows nothing
        var more = row with { MessageCount = 6 };
        Assert.True(u.IsUnread(more));
        Assert.False(u.IsUnread(more, running: true));                   // a turn at work is not a reply yet
        u.Opened(more, false);
        Assert.False(u.IsUnread(more));
        Assert.True(u.IsUnread(more with { Unread = true }));            // the server's flag
        u.Mark(more);
        Assert.True(u.IsUnread(more));
        Assert.False(u.IsUnread(more, onScreen: true, selected: true) && false);
    }

    [Fact]
    public void LiveStatusWaitsForTwoReadsBeforeWaiting()
    {
        var live = new LiveStatus();
        var answer = JsonNode.Parse("""{"sessions":[{"session_key":"a","status":"waiting"},{"session_key":"b","status":"working"},{"session_key":"b","status":"starting"}]}""");
        Assert.True(live.Apply(LiveStatus.Statuses(answer)));
        Assert.Empty(live.Waiting);
        Assert.Equal(["a", "b"], live.Working.Order());
        live.Apply(LiveStatus.Statuses(answer));
        Assert.Equal(["a"], live.Waiting);
    }

    [Fact]
    public void ChatsUnderABot()
    {
        var sessions = new List<SessionSummary> { S("p", pinned: true), S("r1", at: 3), S("r2", at: 2), S("r3", at: 1), S("x", "other") };
        var (shown, more) = BotChatsUnder.Pick(sessions, "ivy", BotChatsChoice.Standard);
        Assert.Equal(["p", "r1", "r2"], shown.Select(s => s.Id));
        Assert.Equal(1, more);
        Assert.Empty(BotChatsUnder.Pick(sessions, "ivy", BotChatsChoice.Initial).Shown);
        Assert.Equal("recent:3", new BotChatsChoice(BotChatsMode.Recent, 3).Stored);
        Assert.Equal(BotChatsMode.Pinned, BotChatsChoice.Parse("pinned")!.Mode);
        Assert.Equal("Pinned + 2 recent", BotChatsChoice.Standard.Summary);
    }
}

public class SessionStoreTests
{
    private static JsonNode Sidebar() => Fixture.Load("demo-sidebar.json") is var j && j["result"] is { } r ? r : j;

    private static (SessionStore Store, FakeGateway Gw) Make()
    {
        var gw = new FakeGateway();
        var sidebar = Sidebar();
        gw.OnRest = (method, path, query, body) => (method, path) switch
        {
            ("GET", "/api/profiles/sessions/sidebar") => new RestAnswer(200, sidebar.ToJsonString()),
            ("GET", var p) when p.EndsWith("/mutation-snapshot") => new RestAnswer(200, """{"exists":true,"runtime_revision":7,"runtime_generation":2}"""),
            ("PATCH", _) => new RestAnswer(200, body!["title"] is { } t ? $$"""{"ok":true,"title":{{t.ToJsonString()}}}""" : """{"ok":true}"""),
            ("DELETE", _) => new RestAnswer(200, """{"ok":true}"""),
            _ => null,
        };
        return (new SessionStore(gw, new MemoryDeviceStore()), gw);
    }

    [Fact]
    public async Task ReadsTheSidebarWithTheWebsQuery()
    {
        var (store, gw) = Make();
        await store.RefreshAsync();
        Assert.Null(store.Failure);
        Assert.Equal(7, store.LiveSummaries().Count);
        var (_, path, query, _) = gw.Rest.Single();
        Assert.Equal("/api/profiles/sessions/sidebar", path);
        Assert.Contains("recents_profile=all&recents_limit=50&cron_limit=50&messaging_limit=100", query);
        store.Prefs.StatusFilter.Add(SessionStatus.Unread);
        Assert.Equal(300, store.RecentsLimit);                         // a filter deepens the read
    }

    /// [WIN-39] Each listing applied counts once (the CI's window-keys walk waits for Ctrl+R's), a failed read too, and
    /// a read the gateway refused (no answer to apply) not at all.
    [Fact]
    public async Task EveryAppliedListingCountsAsARead()
    {
        var (store, _) = Make();
        Assert.Equal(0, store.Reads);
        await store.RefreshAsync();
        await store.RefreshAsync();
        Assert.Equal(2, store.Reads);
        var failed = new FakeGateway { OnRest = (_, _, _, _) => new RestAnswer(200, """{"recents":{"failed":true},"cron":{"sessions":[]},"messaging":{"sessions":[]}}""") };
        var scan = new SessionStore(failed, new MemoryDeviceStore());
        await scan.RefreshAsync();
        Assert.Equal(1, scan.Reads);
        var refused = new SessionStore(new FakeGateway { OnRest = (_, _, _, _) => new RestAnswer(500, "{}") }, new MemoryDeviceStore());
        await refused.RefreshAsync();
        Assert.Equal(0, refused.Reads);
        Assert.NotNull(refused.Failure);
    }

    [Fact]
    public async Task AFailedScanSaysRetry()
    {
        var gw = new FakeGateway { OnRest = (_, _, _, _) => new RestAnswer(200, """{"recents":{"failed":true},"cron":{"sessions":[]},"messaging":{"sessions":[]}}""") };
        var store = new SessionStore(gw, new MemoryDeviceStore());
        await store.RefreshAsync();
        Assert.Equal("Your gateway couldn’t list sessions.", store.Failure);
    }

    [Fact]
    public async Task EditsGoBehindTheRevisionFence()
    {
        var (store, gw) = Make();
        await store.RefreshAsync();
        var s = store.LiveSummaries().First(x => !x.Pinned);
        await store.SetPinnedAsync(s, true);
        var patch = gw.Rest.Last(r => r.Method == "PATCH");
        Assert.Equal(SessionWrite.PathOf(s.Id), patch.Path);
        Assert.Equal("profile=" + s.Profile, patch.Query);
        Assert.True(patch.Body!["pinned"]!.GetValue<bool>());
        Assert.Equal(s.Profile, patch.Body["profile"]!.GetValue<string>());
        Assert.Equal(7, patch.Body["expected_revision"]!.GetValue<long>());
        Assert.Equal(2, patch.Body["expected_generation"]!.GetValue<long>());
        Assert.NotNull(patch.Body["request_id"]);
        Assert.True(store.LiveSummaries().First(x => x.Id == s.Id).Pinned);

        Assert.Equal("Renamed", await store.RenameAsync(s, " Renamed "));
        Assert.Equal("Renamed", store.LiveSummaries().First(x => x.Id == s.Id).Title);

        await store.SetArchivedAsync(s, true);
        Assert.DoesNotContain(store.LiveSummaries(), x => x.Id == s.Id);
        Assert.Contains(store.ArchivedSummaries(), x => x.Id == s.Id);

        await store.DeleteAsync(s);
        var del = gw.Rest.Last(r => r.Method == "DELETE");
        Assert.Contains("expected_revision=7", del.Query);
        Assert.DoesNotContain(store.ArchivedSummaries(), x => x.Id == s.Id);
    }

    [Fact]
    public async Task AGatewayWithoutTheFenceTakesThePlainWrite()
    {
        var gw = new FakeGateway { OnRest = (m, p, _, _) => m == "PATCH" ? new RestAnswer(200, "{}") : null };
        await SessionWrite.PatchAsync(gw, "s1", "ivy", new JsonObject { ["unread"] = true });
        var patch = gw.Rest.Last();
        Assert.Null(patch.Body!["request_id"]);
        Assert.True(patch.Body["unread"]!.GetValue<bool>());
    }

    [Fact]
    public async Task AConflictReadsAgainOnce()
    {
        var tries = 0;
        var gw = new FakeGateway
        {
            OnRest = (m, p, _, _) => m == "GET" ? new RestAnswer(200, $$"""{"exists":true,"runtime_revision":{{tries}}}""")
                : ++tries == 1 ? new RestAnswer(409, """{"detail":"revision_conflict"}""") : new RestAnswer(200, "{}"),
        };
        await SessionWrite.PatchAsync(gw, "s2", "ivy", new JsonObject { ["archived"] = true });
        Assert.Equal(2, gw.Rest.Count(r => r.Method == "PATCH"));
        var refused = new FakeGateway { OnRest = (m, _, _, _) => m == "GET" ? new RestAnswer(404, "") : new RestAnswer(403, """{"detail":"permission_denied"}""") };
        var e = await Assert.ThrowsAsync<GatewayException>(() => SessionWrite.PatchAsync(refused, "s3", "ivy", new JsonObject { ["pinned"] = true }));
        Assert.Equal(403, e.Status);
    }

    [Fact]
    public async Task ProjectsNewChatAndMoves()
    {
        var (store, gw) = Make();
        await store.RefreshAsync();
        gw.OnCall = (m, p) => m switch
        {
            "projects.tree" => JsonNode.Parse("""{"projects":[{"id":"p1","label":"App","path":"/home/hermes/app","repos":[]},{"id":"home","label":"Home","path":null,"isNoProject":true}]}"""),
            "projects.create" => JsonNode.Parse("""{"project":{"id":"p9","name":"Site","primary_path":"/home/hermes/site","folders":[{"path":"/home/hermes/site"}]}}"""),
            "session.workspace.move" => JsonNode.Parse("""{"cwd":"/home/hermes/site"}"""),
            "session.create" => JsonNode.Parse("""{"session_id":"rt","stored_session_id":"st9"}"""),
            _ => null,
        };
        await store.LoadProjectsAsync();
        Assert.Contains(store.ProjectEntries(), e => e.Label == "App");
        Assert.All(gw.Calls.Where(c => c.Method == "projects.tree"), c => Assert.Equal(3, c.Params["preview_limit"]!.GetValue<int>()));
        var s = store.LiveSummaries()[0];
        Assert.Equal("App", store.ProjectOf(s)?.Label);
        var site = await store.CreateProjectAsync("Site", "/home/hermes/site", s.Profile);
        await store.MoveAsync(s, site);
        Assert.Equal("/home/hermes/site", store.LiveSummaries().First(x => x.Id == s.Id).Cwd);
        var create = gw.Calls.First(c => c.Method == "projects.create").Params;
        Assert.False(create["use"]!.GetValue<bool>());
        Assert.Equal("st9", await store.NewChatAsync(s.Profile, "/home/hermes/site"));
        Assert.True(gw.Calls.Last().Params["cwd_explicit"]!.GetValue<bool>());
    }

    [Fact]
    public async Task OpeningClearsTheServersUnreadFlag()
    {
        var gw = new FakeGateway();
        gw.OnRest = (m, p, _, _) => (m, p) switch
        {
            ("GET", "/api/profiles/sessions/sidebar") => new RestAnswer(200, """{"recents":{"sessions":[{"id":"u1","profile":"ivy","title":"T","unread":true,"message_count":3,"last_active":5}]},"cron":{"sessions":[]},"messaging":{"sessions":[]}}"""),
            ("GET", _) => new RestAnswer(404, ""),
            _ => new RestAnswer(200, "{}"),
        };
        var store = new SessionStore(gw, new MemoryDeviceStore());
        await store.RefreshAsync();
        Assert.True(store.LiveSummaries()[0].Unread);
        await store.OpenedAsync("ivy", "u1");
        Assert.False(store.LiveSummaries()[0].Unread);
        Assert.False(gw.Rest.Last(r => r.Method == "PATCH").Body!["unread"]!.GetValue<bool>());
    }

    [Fact]
    public void PrefsSurviveARelaunch()
    {
        var disk = new MemoryDeviceStore();
        var gw = new FakeGateway();
        var a = new SessionStore(gw, disk);
        a.ApplyFilter(new(SessionFilterActionKind.Sort, SessionSortBy.Created), "ivy");
        a.ApplyFilter(new(SessionFilterActionKind.Runs), "ivy");
        var b = new SessionStore(gw, disk);
        Assert.Equal(SessionSortBy.Created, b.Prefs.SortBy);
        Assert.True(b.Device.ShowBackgroundRuns);
        Assert.Null(b.BotFilter);                                             // the chip's bot is never kept
    }
}

public class SidebarLayoutTests
{
    private static readonly List<PlaceInfo> All =
    [
        new("sessions", "Sessions", false), new("jobs", "Jobs", false), new("artifacts", "Artifacts", false),
        new("tasks", "Tasks", true), new("files", "Files", true),
    ];

    [Fact]
    public void PlacesMoveAreRemovedAndAddedBack()
    {
        var l = new SidebarLayout();
        Assert.Equal(["sessions", "jobs", "artifacts"], l.Shown(All));
        Assert.False(l.CanMove("sessions", -1, All));
        l.Move("sessions", 1, All);
        Assert.Equal(["jobs", "sessions", "artifacts"], l.Shown(All));
        l.Remove("artifacts", All);
        Assert.Equal(["Artifacts"], l.Addable(All).Select(p => p.Title));
        l.Add("artifacts", All);
        Assert.Empty(l.Addable(All));
        l.Add("tasks", All);                                   // a tool moved to the places
        Assert.Equal(["files"], l.Tools(All));
        l.MoveBefore("tasks", "jobs", All);
        Assert.Equal(["tasks", "jobs", "sessions", "artifacts"], l.Shown(All));
        l.MoveBefore("tasks", null, All);
        Assert.Equal("tasks", l.Shown(All)[^1]);
        foreach (var id in new[] { "tasks", "jobs", "sessions" }) l.Remove(id, All);
        Assert.False(l.CanRemove("artifacts", All));          // never the last place
    }

    [Fact]
    public void WidthAndRail()
    {
        Assert.Equal(SidebarLayout.NarrowestOpen, SidebarLayout.ClampOpen(50));
        Assert.Equal(SidebarLayout.WidestOpen, SidebarLayout.ClampOpen(900));
        Assert.Equal(300, SidebarLayout.ClampOpen(300));
        Assert.Equal(SidebarLayout.NarrowestOpen, SidebarLayout.ClampOpen(400, windowWidth: 500));
        Assert.Equal((SidebarLayout.NamedRailWidth, true), SidebarLayout.SettleRail(110));
        Assert.Equal((SidebarLayout.CompactRailWidth, false), SidebarLayout.SettleRail(70));
        Assert.True(SidebarLayout.NarrowWindow(500));
        var disk = new MemoryDeviceStore();
        new SidebarLayout { OpenWidth = 333, Collapsed = true, RailNamed = true }.Save(disk);
        var back = SidebarLayout.Load(disk);
        Assert.Equal(333, back.OpenWidth);
        Assert.True(back.Collapsed && back.RailNamed);
    }
}

public class ChatInfoTests
{
    [Fact]
    public void RowsFromTheStoredRow()
    {
        var row = SidebarSessionRow.From(JsonNode.Parse("""
            {"id":"s1","profile":"research","source":"telegram","model":"anthropic/claude-opus-5.5","message_count":14,"cwd":"/home/hermes/reading",
             "git_branch":"main","input_tokens":14200,"output_tokens":1200,"estimated_cost_usd":0.0042}
            """))!;
        var rows = ChatInfoRows.Rows(row, "Research", "studio.local", "Connected");
        Assert.Equal(["Model", "Tokens", "Cost", "Messages", "Folder", "Bot", "Source", "Gateway", "Chat ID"], rows.Select(r => r.Label));
        Assert.Equal("15.4K", rows[1].Value);
        Assert.Equal("14.2K in · 1.2K out", rows[1].Note);
        Assert.Equal("$0.0042", rows[2].Value);
        Assert.Equal("Estimated", rows[2].Note);
        Assert.Equal("Telegram", rows[6].Value);
        Assert.Equal("200K", ChatInfoRows.Count(200_000));
        Assert.Equal("1.5M", ChatInfoRows.Count(1_500_000));
        Assert.Null(ChatInfoRows.SourceName("desktop"));
        Assert.Equal("Scheduled job", ChatInfoRows.SourceName("cron"));
        Assert.Contains("Bot: Research (research)", ChatInfoRows.CopyText(rows, "research"));   // the Mac's SessionInfoRows copy
    }
}
