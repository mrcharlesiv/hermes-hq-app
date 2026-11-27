using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// The CI's screenshot walks for `/new`, Auto-Archive and the Keyboard Shortcuts sheet: the checks they make in the
/// stand-ins' records (`WalkProof`), and the wiring between windows/ci/windows.yml (the extras that ask for each walk and
/// the pictures it insists on) and the app's `Automation.NamedWalks` registrations and shot names.
public class WalkProofTests
{
    private static JsonNode Calls(params (string Method, double At, string? Profile)[] calls) => new JsonObject
    {
        ["calls"] = new JsonArray([.. calls.Select(c => (JsonNode)new JsonObject
        {
            ["method"] = c.Method, ["at"] = c.At,
            ["params"] = c.Profile == null ? new JsonObject() : new JsonObject { ["profile"] = c.Profile },
        })]),
    };

    [Fact]
    public void NewChatPassesOnlyWithOneCreateAndNoPromptAfterTheMark()
    {
        var state = Calls(("session.resume", 1, "default"), ("prompt.submit", 2, "default"), ("session.create", 5, "default"),
            ("session.resume", 6, "default"));
        Assert.Equal(6, WalkProof.LastCallAt(state));
        Assert.Null(WalkProof.NewChatSentNothing(state, mark: 3, "default"));   // the earlier prompt is before the mark
        Assert.Equal("/new made 0 chats, not 1", WalkProof.NewChatSentNothing(state, mark: 5, "default"));
        Assert.Equal("/new made a chat for ivy, not default",
            WalkProof.NewChatSentNothing(Calls(("session.create", 5, "ivy")), 0, "default"));
        Assert.Equal("/new made 2 chats, not 1",
            WalkProof.NewChatSentNothing(Calls(("session.create", 5, "default"), ("session.create", 6, "default")), 0, "default"));
        foreach (var method in new[] { "prompt.submit", "prompt.btw", "prompt.background", "session.redirect", "slash.exec", "command.dispatch" })
            Assert.Equal($"/new sent {method} to the gateway",
                WalkProof.NewChatSentNothing(Calls(("session.create", 5, "default"), (method, 7, "default")), 3, "default"));
        Assert.Equal(0, WalkProof.LastCallAt(new JsonObject()));
    }

    /// [WIN-03 review run 138] Bare "/new" by keyboard: the drawer's pick puts "/new " in the box and must reach the
    /// gateway with nothing (no chat made, no prompt); the drawer's own completion read is allowed.
    [Fact]
    public void TheDrawersPickOfNewSendsNothing()
    {
        // The walk's first Enter: /new takes words (argument_mode "text"), so the drawer's pick inserts "/new ".
        Assert.Equal(Hermes.Core.Composer.PickAction.Insert,
            Hermes.Core.Composer.SlashCatalog.PickActionFor(new Hermes.Core.Composer.CommandRow("/new", "", false), CommandsTests.Catalog()));
        Assert.Null(WalkProof.NewChatPickSentNothing(Calls(("prompt.submit", 2, "default"), ("complete.slash", 5, "default")), mark: 3));
        Assert.Null(WalkProof.NewChatPickSentNothing(new JsonObject(), 0));
        Assert.Equal("the drawer's pick of /new made a chat",
            WalkProof.NewChatPickSentNothing(Calls(("complete.slash", 4, "default"), ("session.create", 5, "default")), 3));
        foreach (var method in new[] { "prompt.submit", "prompt.btw", "prompt.background", "session.redirect", "slash.exec", "command.dispatch" })
            Assert.Equal($"the drawer's pick of /new sent {method} to the gateway",
                WalkProof.NewChatPickSentNothing(Calls((method, 7, "default")), 3));
    }

    private static JsonNode Writes(params (string Method, double At, string Config)[] writes) => new JsonObject
    {
        ["writes"] = new JsonArray([.. writes.Select(w => (JsonNode)new JsonObject
        {
            ["method"] = w.Method, ["at"] = w.At,
            ["params"] = new JsonObject { ["profile"] = "default", ["config"] = JsonNode.Parse(w.Config) },
        })]),
    };

    [Fact]
    public void AutoArchiveNeedsSparsePutsThatEndOnWithTheDays()
    {
        // The switch (both keys, the kept 30), then Archive After 14: two PUTs.
        var two = Writes(("PUT /api/config", 2, """{"sessions":{"auto_archive":false,"auto_archive_days":30}}"""),
            ("PUT /api/config", 5, """{"sessions":{"auto_archive":true,"auto_archive_days":30}}"""),
            ("PUT /api/config", 6, """{"sessions":{"auto_archive_days":14}}"""));
        Assert.Equal(6, WalkProof.LastWriteAt(two));
        Assert.Null(WalkProof.AutoArchiveSaved(two, mark: 3, days: 14));
        Assert.Equal("sessions.auto_archive_days ended 30, not 14",
            WalkProof.AutoArchiveSaved(Writes(("PUT /api/config", 5, """{"sessions":{"auto_archive":true,"auto_archive_days":30}}""")), 0, 14));
        // Both inside one debounce: one PUT.
        Assert.Null(WalkProof.AutoArchiveSaved(Writes(("PUT /api/config", 5, """{"sessions":{"auto_archive":true,"auto_archive_days":14}}""")), 0, 14));
        Assert.Equal("no PUT /api/config reached the gateway", WalkProof.AutoArchiveSaved(two, mark: 6, days: 14));
        Assert.Equal("sessions.auto_archive ended false",
            WalkProof.AutoArchiveSaved(Writes(("PUT /api/config", 5, """{"sessions":{"auto_archive":false,"auto_archive_days":14}}""")), 0, 14));
        Assert.Equal("sessions.auto_archive ended unwritten",
            WalkProof.AutoArchiveSaved(Writes(("PUT /api/config", 5, """{"sessions":{"auto_archive_days":14}}""")), 0, 14));
        Assert.StartsWith("a PUT /api/config wrote more than sessions",
            WalkProof.AutoArchiveSaved(Writes(("PUT /api/config", 5, """{"sessions":{"auto_archive":true,"auto_archive_days":14},"model":{"default":"m"}}""")), 0, 14));
        Assert.Equal("a PUT /api/config wrote sessions.max_age = 3",
            WalkProof.AutoArchiveSaved(Writes(("PUT /api/config", 5, """{"sessions":{"auto_archive":true,"auto_archive_days":14,"max_age":3}}""")), 0, 14));
        // Other writes (a bot's ui_meta, an env key) are not config PUTs and are left out.
        Assert.Null(WalkProof.AutoArchiveSaved(Writes(("PUT /api/env", 4, "{}"),
            ("PUT /api/config", 5, """{"sessions":{"auto_archive":true,"auto_archive_days":14}}""")), 0, 14));
    }

    private static JsonNode Rest(params (string Method, string Path, string? Body)[] calls) => new JsonObject
    {
        ["rest"] = new JsonArray([.. calls.Select(c => (JsonNode)new JsonObject
        {
            ["method"] = c.Method, ["path"] = c.Path, ["query"] = new JsonObject(),
            ["body"] = c.Body == null ? null : JsonNode.Parse(c.Body),
        })]),
    };

    private const string Settings = "/api/plugins/hermes-hq-push/tasks/settings";
    private const string Whole = """{"enabled":true,"capture":"ask","group":"smart","sort":"due","ideas":false}""";

    [Fact]
    public void TasksSortNeedsTheWholeSettingsPutWithTheSortAndNoTaskWrites()
    {
        var state = Rest(("GET", "/api/plugins/hermes-hq-push/tasks", null), ("PUT", Settings, Whole.Replace("\"due\"", "\"added\"")),
            ("GET", "/api/plugins/hermes-hq-push/tasks", null), ("PUT", Settings, Whole), ("GET", "/api/plugins/hermes-hq-push/tasks", null));
        Assert.Equal(5, WalkProof.RestCount(state));
        Assert.Equal(0, WalkProof.RestCount(new JsonObject()));
        Assert.Null(WalkProof.TasksSortSaved(state, mark: 2, "due"));
        Assert.Null(WalkProof.TasksSortSaved(state, mark: 0, "due"));   // the last PUT is what stands
        Assert.Equal("the last PUT /tasks/settings saved sort added, not due",
            WalkProof.TasksSortSaved(Rest(("PUT", Settings, Whole), ("PUT", Settings, Whole.Replace("\"due\"", "\"added\""))), 0, "due"));
        Assert.Equal("no PUT /tasks/settings reached the gateway", WalkProof.TasksSortSaved(state, mark: 4, "due"));
        Assert.Equal("no PUT /tasks/settings reached the gateway", WalkProof.TasksSortSaved(new JsonObject(), 0, "due"));
        Assert.StartsWith("a PUT /tasks/settings without the settings' sort",
            WalkProof.TasksSortSaved(Rest(("PUT", Settings, """{"group":"smart"}""")), 0, "due"));
        // Select picks rows and Esc ends it: a tick, a move or a delete in the walk is wrong.
        Assert.Equal("the walk wrote PATCH /api/plugins/hermes-hq-push/tasks/t_h_filter",
            WalkProof.TasksSortSaved(Rest(("PUT", Settings, Whole), ("PATCH", "/api/plugins/hermes-hq-push/tasks/t_h_filter", """{"status":"done"}""")), 0, "due"));
        Assert.Equal("the walk wrote DELETE /api/plugins/hermes-hq-push/tasks/t_porch",
            WalkProof.TasksSortSaved(Rest(("PUT", Settings, Whole), ("DELETE", "/api/plugins/hermes-hq-push/tasks/t_porch", null)), 0, "due"));
        // Writes elsewhere (a Kanban card) aren't the Tasks page's.
        Assert.Null(WalkProof.TasksSortSaved(Rest(("POST", "/api/plugins/kanban/tasks", "{}"), ("PUT", Settings, Whole)), 0, "due"));
    }

    [Fact]
    public void OrderNamesWhatIsShownAgainstWhatShouldBe()
    {
        Assert.Null(WalkProof.Order(["a", "b"], ["a", "b"], "Home"));
        Assert.Equal("Home shows b, a, not a, b", WalkProof.Order(["b", "a"], ["a", "b"], "Home"));
        Assert.Equal("Home shows a, not a, b", WalkProof.Order(["a"], ["a", "b"], "Home"));
        // The two orders the walk tells apart are the same four tasks, in different places.
        Assert.Equal(WalkProof.HomeMyOrder.Order(), WalkProof.HomeByDue.Order());
        Assert.NotNull(WalkProof.Order(WalkProof.HomeMyOrder, WalkProof.HomeByDue, "Home"));
    }

    // ------------------------------------------------------------------ windows.yml ↔ the app's walks

    /// The checkout holding `windows/HermesHQ.sln`: the full Mac repo here, or the Windows-only CI mirror.
    private static string WindowsDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln")))
                return Path.Combine(dir.FullName, "windows");
        throw new InvalidOperationException("repo root not found");
    }

    /// Each screenshot extra in windows.yml: its tag, its script, its arguments, the walks it asks for and the pictures
    /// those walks must leave besides their own (`shots`).
    private static List<(string Tag, string Script, string Args, List<string> Walks, List<string> Shots)> Extras()
    {
        var yml = File.ReadAllText(Path.Combine(WindowsDir(), "ci", "windows.yml"));
        var found = new List<(string, string, string, List<string>, List<string>)>();
        List<string> Names(string rest, string key) => Regex.Match(rest, key + @" = @\((?<w>[^)]*)\)") is { Success: true } w
            ? Regex.Matches(w.Groups["w"].Value, @"""([^""]+)""").Select(x => x.Groups[1].Value).ToList() : [];
        foreach (Match m in Regex.Matches(yml, @"@\{ tag = ""(?<tag>[^""]+)""; args = @\((?<args>[^)]*)\);(?<rest>[^\n]*)\}"))
        {
            var script = Regex.Match(m.Groups["args"].Value, @"windows/ci/fixtures/[\w-]+\.py").Value;
            found.Add((m.Groups["tag"].Value, script, m.Groups["args"].Value, Names(m.Groups["rest"].Value, "walks"), Names(m.Groups["rest"].Value, "shots")));
        }
        return found;
    }

    private static string AppSource() => string.Join("\n",
        Directory.EnumerateFiles(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows"), "*.cs", SearchOption.AllDirectories).Select(File.ReadAllText));

    [Fact]
    public void TheNewChatAutoArchiveAndShortcutsWalksRunOnTheirStandIns()
    {
        var extras = Extras();
        Assert.NotEmpty(extras);
        string ScriptFor(string walk) => Assert.Single(extras, e => e.Walks.Contains(walk)).Script;
        Assert.Equal("windows/ci/fixtures/composer-gateway.py", ScriptFor("new-chat-draft"));
        // [WIN-03 review run 138] bare /new by keyboard, on the same stand-in, right after the draft walk.
        Assert.Equal("windows/ci/fixtures/composer-gateway.py", ScriptFor("new-chat-bare"));
        var composer = Assert.Single(extras, e => e.Walks.Contains("new-chat-bare")).Walks;
        Assert.Equal(composer.IndexOf("new-chat-draft") + 1, composer.IndexOf("new-chat-bare"));
        Assert.Equal("windows/ci/fixtures/settings-gateway.py", ScriptFor("settings-auto-archive-on"));
        Assert.Contains(ScriptFor("shortcuts-sheet"), new[] { "windows/ci/fixtures/composer-gateway.py", "windows/ci/fixtures/settings-gateway.py" });
        // The step fails the run when any asked-for walk's picture is missing.
        var yml = File.ReadAllText(Path.Combine(WindowsDir(), "ci", "windows.yml"));
        Assert.Contains("""if (-not (Test-Path "$shots/*-$walk.png")) { throw "Missing screenshot: $walk" }""", yml);
    }

    [Fact]
    public void EveryWalkWindowsYmlAsksForIsRegisteredAndTakesItsPicture()
    {
        var source = AppSource();
        Assert.Single(Regex.Matches(source, @"\bRegisterToastsWalks\(\);"));
        Assert.Single(Regex.Matches(source, @"Automation\.BoundWalks\.Add\(""toasts"", ToastsAsync\)"));
        Assert.DoesNotMatch(@"NamedWalks\s*(?:\[\s*|\.(?:Try)?Add\(\s*)""toasts""", source);
        foreach (var walk in Extras().SelectMany(e => e.Walks))
        {
            if (walk != "toasts") Assert.True(source.Contains($"Automation.NamedWalks[\"{walk}\"]"), $"no NamedWalks registration for {walk}");
            Assert.True(source.Contains($"shot(\"{walk}\")"), $"walk {walk} never takes its picture");
        }
        foreach (var picture in Extras().SelectMany(e => e.Shots))
            Assert.True(source.Contains($"shot(\"{picture}\")"), $"no walk takes {picture}");
        // An extra lists pictures only for walks it asks for.
        Assert.All(Extras().Where(e => e.Shots.Count > 0), e => Assert.NotEmpty(e.Walks));
    }

    [Fact]
    public void TheOpenQuicklyFindTypeToChatAndTasksWalksRunOnTheirStandIns()
    {
        var extras = Extras();
        (string Script, string Args, List<string> Shots) For(string walk)
        {
            var e = Assert.Single(extras, e => e.Walks.Contains(walk));
            return (e.Script, e.Args, e.Shots);
        }
        // Open Quickly, Find and type-to-chat on the composer stand-in: its bots (Hermes, Sam), its chats for Recent and
        // its Trip planning chat with "food" twice (WalkProof.TripStoredId).
        foreach (var walk in new[] { "open-quickly", "chat-find", "type-to-chat" })
            Assert.Equal("windows/ci/fixtures/composer-gateway.py", For(walk).Script);
        Assert.Contains("open-quickly-recent", For("open-quickly").Shots);
        Assert.Contains("open-quickly-results", For("open-quickly").Shots);
        Assert.Contains("open-quickly-settings", For("open-quickly").Shots);
        Assert.Contains("open-quickly-settings-opened", For("open-quickly").Shots);
        Assert.Contains("chat-find-closed", For("chat-find").Shots);
        // Sort By and Select on the pages stand-in with its lists (Home, WalkProof.HomeList), on a port of its own so
        // the pages extra's Tasks picture stays as it was.
        var tasks = For("tasks-sort-select");
        Assert.Equal("windows/ci/fixtures/pages-fixture-gateway.py", tasks.Script);
        Assert.Contains("\"--task-lists\"", tasks.Args);
        Assert.Contains("tasks-sorted-due", tasks.Shots);
        Assert.Contains("tasks-select", tasks.Shots);
        var yml = File.ReadAllText(Path.Combine(WindowsDir(), "ci", "windows.yml"));
        Assert.Contains("""foreach ($shot in @($d.shots | Where-Object { $_ })) {""", yml);
        Assert.Contains("""if (-not (Test-Path "$shots/*-$shot.png")) { throw "Missing screenshot: $shot" }""", yml);
        // The same stand-in runs for the E2E step (windows.yml) and scripts/e2e.sh, where WalkProofEndToEndTests checks
        // the walk's expectations against it.
        Assert.Contains("--task-lists", Regex.Match(yml, @"\$tasks = Start-Process python -ArgumentList [^\n]*").Value);
        Assert.Contains("$env:HQW_E2E_TASKS_CREDENTIALS", yml);
        var e2e = File.ReadAllText(Path.Combine(WindowsDir(), "scripts", "e2e.sh"));
        Assert.Matches(@"pages-fixture-gateway\.py --port \$TPORT [^\n]*--task-lists", e2e);
        Assert.Contains("export HQW_E2E_TASKS_CREDENTIALS=", e2e);
    }

    // ------------------------------------------------------------------ sidebar Search, About, Detailed Logging

    [Fact]
    public void TheSidebarSearchAndAboutWalksRunOnTheirStandIns()
    {
        var extras = Extras();
        (string Script, List<string> Shots) For(string walk)
        {
            var e = Assert.Single(extras, e => e.Walks.Contains(walk));
            return (e.Script, e.Shots);
        }
        // Sidebar Search on the composer stand-in (its bots and chats fill Open Quickly's Recent).
        var sidebar = For("sidebar-search");
        Assert.Equal("windows/ci/fixtures/composer-gateway.py", sidebar.Script);
        Assert.Contains("sidebar-search-open", sidebar.Shots);
        Assert.Contains("sidebar-search-rail", sidebar.Shots);
        // About, its licences and Detailed Logging on the settings stand-in (its GET /api/config is the probe request).
        var about = For("about-licenses");
        Assert.Equal("windows/ci/fixtures/settings-gateway.py", about.Script);
        Assert.Contains("about-page", about.Shots);
        Assert.Contains("about-license-text", about.Shots);
        var log = For("about-detailed-log");
        Assert.Equal("windows/ci/fixtures/settings-gateway.py", log.Script);
        Assert.Contains("about-detailed-log-search", log.Shots);
    }

    [Fact]
    public void SearchingSettingsForVerboseLeadsFirstToDetailedLogging()
    {
        var first = Assert.IsType<Hermes.Core.Settings.SettingsSearchEntry>(
            Hermes.Core.Settings.SettingsSearch.Results(WalkProof.LogSearchWord, Hermes.Core.Settings.SettingsSearch.Index).FirstOrDefault());
        Assert.Equal(Hermes.Core.Settings.DetailedLogging.Title, first.Label);
        Assert.Equal(WalkProof.LogSearchResultId, "search." + first.Id);
        Assert.Equal(WalkProof.LogRowTarget, first.Target);
        // The notice the walk opens is the list's first row, and its row is named as the page names it.
        var notices = Hermes.Core.Settings.LicenseNotices.Load();
        Assert.NotNull(notices);
        Assert.Equal(Hermes.Core.Settings.LicenseNotices.First, notices![0].Name);
        Assert.Equal("license-row-" + Hermes.Core.Settings.LicenseNotices.First, WalkProof.LicenseRowId(notices[0].Name));
    }

    private const string Probe = "GET /api/config";

    private static string Log(params string[] lines) => string.Join("\r\n", lines.Select(l => "2026-11-21 10:00:00.000 " + l)) + "\r\n";

    [Fact]
    public void DetailedLoggingOffDropsHttpLinesAndOnBringsThemBack()
    {
        var good = Log("[launch] logging: detailed on", "[http] GET /api/config → 200, 512 B, 4 ms", "[settings] detailed logging off",
            "[automation] walk keys: Space by keyboard", "[settings] detailed logging on", "[http] GET /api/config → 200, 512 B, 3 ms");
        Assert.Null(WalkProof.DetailedLogToggled(good, Probe));
        // Only the last off … on pair is judged: an older run's lines don't count.
        Assert.Null(WalkProof.DetailedLogToggled(Log("[settings] detailed logging off", "[http] GET /x → 200, 1 B, 1 ms") + good, Probe));
        Assert.Equal("no \u201Cdetailed logging off\u201D in the app log",
            WalkProof.DetailedLogToggled(Log("[http] GET /api/config → 200, 1 B, 1 ms"), Probe));
        Assert.Equal("no \u201Cdetailed logging on\u201D after it was turned off",
            WalkProof.DetailedLogToggled(Log("[http] GET /api/config → 200, 1 B, 1 ms", "[settings] detailed logging off"), Probe));
        Assert.Equal("no GET /api/config line before Detailed Logging went off",
            WalkProof.DetailedLogToggled(Log("[settings] detailed logging off", "[settings] detailed logging on", "[http] GET /api/config → 200, 1 B, 1 ms"), Probe));
        Assert.Equal("1 [http] line while Detailed Logging was off: GET /api/sessions → 200, 9 B, 2 ms",
            WalkProof.DetailedLogToggled(Log("[http] GET /api/config → 200, 1 B, 1 ms", "[settings] detailed logging off",
                "[http] GET /api/sessions → 200, 9 B, 2 ms", "[settings] detailed logging on", "[http] GET /api/config → 200, 1 B, 1 ms"), Probe));
        Assert.Equal("no GET /api/config line after Detailed Logging came back on",
            WalkProof.DetailedLogToggled(Log("[http] GET /api/config → 200, 1 B, 1 ms", "[settings] detailed logging off",
                "[settings] detailed logging on", "[http] GET /api/status → 200, 1 B, 1 ms"), Probe));
        // A note that merely mentions http isn't a request line.
        Assert.Null(WalkProof.DetailedLogToggled(Log("[http] GET /api/config → 200, 1 B, 1 ms", "[settings] detailed logging off",
            "[automation] walk: [http] lines expected none", "[settings] detailed logging on", "[http] GET /api/config → 500, 1 B, 1 ms: disk full"), Probe));
    }

    [Fact]
    public void TheRailsSearchAndNewChatSitSideBySideOnOneLine()
    {
        var side = Hermes.Core.Shell.SidebarSearch.RailSide;
        var gap = Hermes.Core.Shell.SidebarSearch.RailGap;
        var rail = new WalkProof.Box(0, 0, 64, 600);
        var search = new WalkProof.Box(32 - gap / 2 - side, 40, side, side);
        var compose = new WalkProof.Box(32 + gap / 2, 40, side, side);
        Assert.Null(WalkProof.RailToolsSideBySide(search, compose, rail));
        Assert.Equal("New Chat sits 40 below Search, not beside it",
            WalkProof.RailToolsSideBySide(search, compose with { Y = 80 }, rail));
        Assert.Equal("New Chat isn't after Search (they overlap or swapped)",
            WalkProof.RailToolsSideBySide(compose, search, rail));
        Assert.Equal("Search and New Chat are 12 apart, not 2",
            WalkProof.RailToolsSideBySide(search with { X = search.X - 10 }, compose, rail));
        Assert.StartsWith("the tools spill out of the rail", WalkProof.RailToolsSideBySide(search, compose, rail with { Width = 50 }));
    }

    // ------------------------------------------------------------------ Quick Actions and New Chat With…

    [Fact]
    public void TheQuickActionsAndNewChatSheetWalksRunOnTheirStandIns()
    {
        var extras = Extras();
        (string Script, List<string> Shots) For(string walk)
        {
            var e = Assert.Single(extras, e => e.Walks.Contains(walk));
            return (e.Script, e.Shots);
        }
        // Quick Actions on the pages stand-in: its roster seeds the starter set, and its Tasks page is where Add Task goes.
        var quick = For("quick-actions");
        Assert.Equal("windows/ci/fixtures/pages-fixture-gateway.py", quick.Script);
        Assert.Contains("quick-actions-editing", quick.Shots);
        Assert.Contains("quick-actions-edit", quick.Shots);
        // New Chat With… on the sessions stand-in: Hermes, Research and Deploys, their projects, and its rpc record.
        var sheet = For("new-chat-sheet");
        Assert.Equal("windows/ci/fixtures/sessions-gateway.py", sheet.Script);
        Assert.Contains("new-chat-sheet-started", sheet.Shots);
        var here = For("new-chat-here");
        Assert.Equal(sheet.Script, here.Script);
        foreach (var picture in new[] { "new-chat-here-project", "new-chat-here-home", "new-chat-here-bot" })
            Assert.Contains(picture, here.Shots);
        var source = AppSource();
        Assert.Contains("Keys.Press(Keys.K, ctrl: true, shift: true)", source);   // Ctrl+Shift+K, the Mac's ⇧⌘K
        Assert.Contains("Keys.Press(Keys.N, ctrl: true, shift: true)", source);   // Ctrl+Shift+N, the Mac's ⇧⌘N
    }

    [Fact]
    public void TheWalksStarterSetIsTheSeededOneWithTheMacsWords()
    {
        var starter = Hermes.Core.QuickActions.QuickTileStore.Starter("default", "Hermes");
        Assert.Equal(WalkProof.QuickStarterIds, starter.Select(t => t.Id));
        // The Mac's tiles (93f984bb1 artifacts/quick-actions/15-desktop-look-light.png), as the walk reads them aloud.
        Assert.Equal(["Memo, to Hermes", "Talk, with Hermes", "New Chat, with Hermes", "Add Task, for me", "Search Chats, all chats"],
            starter.Select(t => $"{t.Name}, {t.Subtitle("Hermes")}"));
        Assert.Equal([false, false, true, false, false], starter.Select(t => t.Wide));
        // The edit the walk makes, done on the list itself, gives the order it expects saved.
        var list = new Hermes.Core.QuickActions.QuickTileList(starter, seeded: true);
        Assert.True(list.Step(WalkProof.QuickMovedDown, 1));
        list.Remove(WalkProof.QuickRemoved);
        Assert.Equal(WalkProof.QuickEditedIds, list.Tiles.Select(t => t.Id));
        // A move that did nothing would leave a different order (Memo first), so the check can tell.
        Assert.NotEqual(WalkProof.QuickStarterIds.Where(id => id != WalkProof.QuickRemoved), WalkProof.QuickEditedIds);
        // Add Task opens the Tasks page.
        var addTask = starter.Single(t => t.Id == WalkProof.QuickPlaceTile);
        var route = Hermes.Core.QuickActions.QuickTileRoute.Make(addTask,
            new Hermes.Core.QuickActions.QuickTileWorld(Bots: new Dictionary<string, string> { ["default"] = "Hermes" }, Pages: new Dictionary<string, string>()),
            Hermes.Core.QuickActions.QuickTileRules.Windows);
        Assert.IsType<Hermes.Core.QuickActions.QuickTileRoute.NewTask>(route);
        Assert.Equal("quick-tile-starter-add-task", WalkProof.QuickTileAutomationId(WalkProof.QuickPlaceTile));
    }

    [Fact]
    public void QuickTilesSavedNeedsTheSeededListInTheWalksOrder()
    {
        var store = new Hermes.Core.Composer.MemoryStore();
        Assert.Equal("nothing saved under hqn.quickActions", WalkProof.QuickTilesSaved(store, WalkProof.QuickEditedIds));
        var starter = Hermes.Core.QuickActions.QuickTileStore.Starter("default", "Hermes");
        var list = new Hermes.Core.QuickActions.QuickTileList(starter, seeded: true);
        Hermes.Core.QuickActions.QuickTileStore.Save(list, store);
        Assert.Equal("the saved Quick Actions shows starter-memo, starter-talk, starter-new-chat, starter-add-task, starter-search, " +
            "not starter-talk, starter-memo, starter-new-chat, starter-add-task", WalkProof.QuickTilesSaved(store, WalkProof.QuickEditedIds));
        list.Step(WalkProof.QuickMovedDown, 1);
        list.Remove(WalkProof.QuickRemoved);
        Hermes.Core.QuickActions.QuickTileStore.Save(list, store);
        Assert.Null(WalkProof.QuickTilesSaved(store, WalkProof.QuickEditedIds));
        store.Set(Hermes.Core.QuickActions.QuickTileStore.Key, "not json");
        Assert.NotNull(WalkProof.QuickTilesSaved(store, WalkProof.QuickEditedIds));
    }

    private static JsonNode Rpc(params (string Method, JsonObject Params)[] calls) => new JsonObject
    {
        ["rpc"] = new JsonArray([.. calls.Select(c => (JsonNode)new JsonObject { ["method"] = c.Method, ["params"] = c.Params })]),
    };

    private static JsonObject Create(string profile, string? cwd, bool explicitCwd = true)
    {
        var p = new JsonObject { ["profile"] = profile, ["follow_profile_config"] = true, ["source"] = "desktop" };
        if (cwd != null) { p["cwd"] = cwd; p["cwd_explicit"] = explicitCwd; }
        return p;
    }

    [Fact]
    public void NewChatStartedInNeedsOneCreateForTheBotInTheFolderAndNoPrompt()
    {
        const string bot = WalkProof.NewChatBot, folder = WalkProof.NewChatFolder;
        var earlier = (Method: "session.create", Params: Create("default", null));
        var state = Rpc(earlier, ("projects.tree", new JsonObject { ["profile"] = bot }), ("session.create", Create(bot, folder)));
        Assert.Equal(3, WalkProof.RpcCount(state));
        Assert.Equal(0, WalkProof.RpcCount(new JsonObject()));
        Assert.Null(WalkProof.NewChatStartedIn(state, mark: 1, bot, folder));   // the earlier chat is before the mark
        Assert.Equal("the sheet made 2 chats, not 1", WalkProof.NewChatStartedIn(state, mark: 0, bot, folder));
        Assert.Equal("the sheet made 0 chats, not 1", WalkProof.NewChatStartedIn(state, mark: 3, bot, folder));
        Assert.Equal("the sheet made a chat for default, not research",
            WalkProof.NewChatStartedIn(Rpc(("session.create", Create("default", folder))), 0, bot, folder));
        Assert.Equal("the sheet made the chat in no folder, not /home/hermes/reading",
            WalkProof.NewChatStartedIn(Rpc(("session.create", Create(bot, null))), 0, bot, folder));
        Assert.Equal("the sheet made the chat in /home/hermes/app, not /home/hermes/reading",
            WalkProof.NewChatStartedIn(Rpc(("session.create", Create(bot, "/home/hermes/app"))), 0, bot, folder));
        Assert.Equal("session.create didn't mark its folder cwd_explicit",
            WalkProof.NewChatStartedIn(Rpc(("session.create", Create(bot, folder, explicitCwd: false))), 0, bot, folder));
        Assert.Equal("the sheet sent prompt.submit to the gateway",
            WalkProof.NewChatStartedIn(Rpc(("session.create", Create(bot, folder)), ("prompt.submit", new JsonObject())), 0, bot, folder));
    }

    [Fact]
    public void TheSheetsIdsForTheWalksPicksAreTheMacs()
    {
        Assert.Equal("new-chat-bot-research", Hermes.Core.Sessions.NewChatText.BotId(WalkProof.NewChatBot));
        Assert.Equal("new-chat-project-Reading", Hermes.Core.Sessions.NewChatText.RowId(new("/home/hermes/reading", WalkProof.NewChatProject)));
        // Hermes first, then the stand-in's other bots in the roster's order: Research is the second pill.
        var offered = Hermes.Core.Sessions.NewChatCompose.Offered(
            [new("research", "Research"), new("default", "Hermes"), new("deploys", "Deploys")], null);
        Assert.Equal(["default", "research", "deploys"], offered.Select(b => b.Id));
    }

    // ------------------------------------------------------------------ WIN-28: Quick Action tiles, Select's actions, link drops

    private const string TaskPath = "/api/plugins/hermes-hq-push/tasks/";

    [Fact]
    public void SelectsMarkDoneNeedsOnePatchDonePerPickAndNothingElse()
    {
        string[] picks = [.. WalkProof.TasksDonePicks];
        var done = """{"status":"done","rev":2}""";
        var state = Rest(("PUT", Settings, Whole), ("PATCH", TaskPath + picks[0], done), ("GET", "/api/plugins/hermes-hq-push/tasks", null),
            ("PATCH", TaskPath + picks[1], done));
        Assert.Null(WalkProof.TasksMarkedDone(state, mark: 1, picks));
        Assert.Equal("the walk wrote PUT /api/plugins/hermes-hq-push/tasks/settings", WalkProof.TasksMarkedDone(state, mark: 0, picks));
        Assert.Equal($"no PATCH for {picks[1]} reached the gateway", WalkProof.TasksMarkedDone(Rest(("PATCH", TaskPath + picks[0], done)), 0, picks));
        Assert.Equal($"PATCH {picks[0]}: status open, not done",
            WalkProof.TasksMarkedDone(Rest(("PATCH", TaskPath + picks[0], """{"status":"open","rev":2}""")), 0, picks));
        Assert.Equal($"PATCH {picks[0]}: no rev", WalkProof.TasksMarkedDone(Rest(("PATCH", TaskPath + picks[0], """{"status":"done"}""")), 0, picks));
        Assert.Equal($"PATCH {picks[0]} reached the gateway twice",
            WalkProof.TasksMarkedDone(Rest(("PATCH", TaskPath + picks[0], done), ("PATCH", TaskPath + picks[0], done)), 0, picks));
        Assert.Equal("the walk wrote PATCH /api/plugins/hermes-hq-push/tasks/t_porch",
            WalkProof.TasksMarkedDone(Rest(("PATCH", TaskPath + "t_porch", done)), 0, picks));
    }

    [Fact]
    public void SelectsMoveToAndDeleteNeedTheirOwnWriteForThePickOnly()
    {
        string[] pick = [WalkProof.TasksMovePick];
        var moved = Rest(("PATCH", TaskPath + pick[0], """{"position":7,"section":"sec_work","rev":3}"""));
        Assert.Null(WalkProof.TasksMovedTo(moved, 0, pick, WalkProof.TasksMoveTo));
        Assert.Equal($"PATCH {pick[0]}: section sec_home, not sec_work",
            WalkProof.TasksMovedTo(Rest(("PATCH", TaskPath + pick[0], """{"position":7,"section":"sec_home","rev":3}""")), 0, pick, WalkProof.TasksMoveTo));
        Assert.Equal($"PATCH {pick[0]}: no position",
            WalkProof.TasksMovedTo(Rest(("PATCH", TaskPath + pick[0], """{"section":"sec_work","rev":3}""")), 0, pick, WalkProof.TasksMoveTo));
        Assert.Equal($"no PATCH for {pick[0]} reached the gateway", WalkProof.TasksMovedTo(moved, 1, pick, WalkProof.TasksMoveTo));
        string[] gone = [WalkProof.TasksDeletePick];
        Assert.Null(WalkProof.TasksDeleted(Rest(("DELETE", TaskPath + gone[0], null)), 0, gone));
        Assert.Equal($"the walk wrote PATCH {TaskPath}{pick[0]}", WalkProof.TasksDeleted(moved, 0, gone));
        Assert.Equal($"no DELETE for {gone[0]} reached the gateway", WalkProof.TasksDeleted(new JsonObject(), 0, gone));
        // Home by Due Date loses the two marked done, then the one moved; the one deleted was the last open row.
        Assert.Equal(WalkProof.HomeByDue.Take(2), WalkProof.TasksDonePicks);
        Assert.Equal(WalkProof.HomeByDue.Skip(2), WalkProof.HomeAfterDone);
        Assert.Equal([WalkProof.TasksMovePick, WalkProof.TasksDeletePick], WalkProof.HomeAfterDone);
        Assert.Equal([WalkProof.TasksDeletePick], WalkProof.HomeAfterMove);
        Assert.Equal("Delete 1 Task?", Hermes.Core.Tasks.TodoSelection.DeleteTitle(1));
    }

    private static JsonNode Prompts(params (string Method, double At, string? Text)[] calls) => new JsonObject
    {
        ["calls"] = new JsonArray([.. calls.Select(c => (JsonNode)new JsonObject
        {
            ["method"] = c.Method, ["at"] = c.At,
            ["params"] = c.Text == null ? new JsonObject() : new JsonObject { ["text"] = c.Text, ["session_id"] = "rt1" },
        })]),
    };

    [Fact]
    public void TheSendTileNeedsOnePromptSubmitOfItsWordsAfterTheMark()
    {
        const string words = WalkProof.QuickSendWords;
        var state = Prompts(("prompt.submit", 1, "earlier"), ("session.resume", 4, null), ("prompt.submit", 5, words));
        Assert.Null(WalkProof.QuickSentInChat(state, mark: 2, words));
        Assert.Equal("the tile sent 2 prompts, not 1", WalkProof.QuickSentInChat(state, mark: 0, words));
        Assert.Equal("the tile sent 0 prompts, not 1", WalkProof.QuickSentInChat(state, mark: 5, words));
        Assert.Equal("the tile sent \u201Cwhat\u201D, not \u201C" + words + "\u201D", WalkProof.QuickSentInChat(Prompts(("prompt.submit", 1, "what")), 0, words));
        Assert.Equal("the tile sent prompt.background, not prompt.submit", WalkProof.QuickSentInChat(Prompts(("prompt.background", 1, words)), 0, words));
    }

    private static JsonNode JobRest(params (string Method, string Path, string? Profile)[] calls) => new JsonObject
    {
        ["rest"] = new JsonArray([.. calls.Select(c => (JsonNode)new JsonObject
        {
            ["method"] = c.Method, ["path"] = c.Path, ["query"] = c.Profile == null ? new JsonObject() : new JsonObject { ["profile"] = c.Profile },
        })]),
    };

    [Fact]
    public void TheRunJobTileNeedsOneTriggerForTheJobsOwner()
    {
        const string id = WalkProof.QuickRunJobId, owner = WalkProof.QuickRunJobOwner;
        var job = "/api/cron/jobs/" + id;
        var state = JobRest(("POST", job + "/pause", owner), ("GET", job, owner), ("POST", job + "/trigger", owner), ("GET", "/api/cron/jobs", "all"));
        Assert.Null(WalkProof.QuickJobTriggered(state, mark: 1, id, owner));
        Assert.Equal($"the tile wrote POST {job}/pause", WalkProof.QuickJobTriggered(state, mark: 0, id, owner));
        Assert.Equal($"0 triggers for {id} reached the gateway, not 1", WalkProof.QuickJobTriggered(state, mark: 3, id, owner));
        Assert.Equal($"2 triggers for {id} reached the gateway, not 1",
            WalkProof.QuickJobTriggered(JobRest(("POST", job + "/trigger", owner), ("POST", job + "/trigger", owner)), 0, id, owner));
        Assert.Equal("the trigger named default, not inbox", WalkProof.QuickJobTriggered(JobRest(("POST", job + "/trigger", "default")), 0, id, owner));
        Assert.Equal("the tile wrote POST /api/cron/jobs/j-watch/trigger",
            WalkProof.QuickJobTriggered(JobRest(("POST", "/api/cron/jobs/j-watch/trigger", owner)), 0, id, owner));
    }

    [Fact]
    public void TheWalksTilesRouteAsTheMacsAndTheNoticeIsItsWords()
    {
        var world = new Hermes.Core.QuickActions.QuickTileWorld();
        var rules = Hermes.Core.QuickActions.QuickTileRules.Windows;
        var send = Assert.IsType<Hermes.Core.QuickActions.QuickTileRoute.SendInChat>(
            Hermes.Core.QuickActions.QuickTileRoute.Make(WalkProof.QuickSendTile("Hermes"), world, rules));
        Assert.Equal((WalkProof.QuickSendBot, WalkProof.QuickSendWords), (send.Profile, send.Words));
        var run = Assert.IsType<Hermes.Core.QuickActions.QuickTileRoute.RunJob>(
            Hermes.Core.QuickActions.QuickTileRoute.Make(WalkProof.QuickRunTile(), world, rules));
        Assert.Equal(("inbox|j-triage", "Morning inbox triage"), (run.Key, run.Name));
        Assert.Equal(("inbox", "j-triage"), Hermes.Core.QuickActions.QuickTileRun.Job(run.Key, null));
        Assert.Equal("\u2713 Running Morning inbox triage", WalkProof.QuickRunNotice(run.Name));
        // Both survive the store's round trip (the page reads them back from quick-actions.json).
        var store = new Hermes.Core.Composer.MemoryStore();
        Hermes.Core.QuickActions.QuickTileStore.Save(new([WalkProof.QuickSendTile("Hermes"), WalkProof.QuickRunTile()], seeded: true), store);
        Assert.Null(WalkProof.QuickTilesSaved(store, [WalkProof.QuickSendTileId, WalkProof.QuickRunTileId]));
    }

    [Fact]
    public void LinkDropsAreOnlyTheComposerWalksDropsAndThrows()
    {
        var log = Log("[rpc] link dropped: closed by the gateway", "[automation] composer walk new-chat-draft",
            "[rpc] link dropped: no frame in 45 s", "[automation] composer walk new-chat-draft finished",
            "[rpc] a Event listener threw NullReferenceException (0x80004003) in ChatPage.OnEvent", "[automation] composer walk chat-keys",
            "[automation] signed in to settings", "[rpc] link dropped: closed by the gateway", "[automation] done");
        var drops = WalkProof.LinkDrops(log, "composer");
        Assert.Equal(2, drops.Count);
        Assert.EndsWith("[rpc] link dropped: no frame in 45 s", drops[0]);
        Assert.Contains("listener threw NullReferenceException", drops[1]);
        Assert.Empty(WalkProof.LinkDrops(log, "tasks"));
        Assert.Empty(WalkProof.LinkDrops(Log("[automation] composer walk chat-keys", "[rpc] link up", "[automation] done", "[rpc] link dropped: x"), "composer"));
        // The words are AppState's own.
        var appState = File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Services", "AppState.cs"));
        Assert.Contains("AppLog.Note(\"rpc\", $\"link dropped: {why}\")", appState);
        Assert.Contains("listener threw {e.GetType().Name}", appState);
    }

    [Fact]
    public void TheQuickTileAndSelectActionWalksRunOnTheirStandIns()
    {
        var extras = Extras();
        (string Script, List<string> Walks, List<string> Shots) For(string walk)
        {
            var e = Assert.Single(extras, e => e.Walks.Contains(walk));
            return (e.Script, e.Walks, e.Shots);
        }
        // Send a Message on the composer stand-in (it runs prompts), Run Job on the jobs stand-in (it has the job).
        Assert.Equal("windows/ci/fixtures/composer-gateway.py", For("quick-action-send").Script);
        Assert.Contains("quick-action-tiles", For("quick-action-send").Shots);
        Assert.Equal("windows/ci/fixtures/jobs-gateway.py", For("quick-action-run").Script);
        // Select's actions after Sort By and Select, on the same stand-in, in that order.
        var tasks = For("tasks-select-actions");
        Assert.Equal("windows/ci/fixtures/pages-fixture-gateway.py", tasks.Script);
        Assert.True(tasks.Walks.IndexOf("tasks-sort-select") is >= 0 and var i && tasks.Walks.IndexOf("tasks-select-actions") == i + 1);
        foreach (var shot in new[] { "tasks-select-done", "tasks-select-moved", "tasks-select-deleted" }) Assert.Contains(shot, tasks.Shots);
        // The link-drop guard: AppState's words, printed before the app log, and the step fails on them.
        var yml = File.ReadAllText(Path.Combine(WindowsDir(), "ci", "windows.yml"));
        Assert.Contains("'[rpc] link dropped'", yml);
        Assert.Contains("'listener threw'", yml);
        Assert.True(yml.IndexOf("--- link drops during the composer walks", StringComparison.Ordinal) < yml.IndexOf("--- app log", StringComparison.Ordinal));
        Assert.Contains("throw \"The gateway link dropped (or a listener threw) during the composer walks.\"", yml);
    }

    // ------------------------------------------------------------------ [WIN-34] the window keys and file windows

    [Fact]
    public void WalkedToIsEveryRowPastTheStartInOrderAndNothingMore()
    {
        string[] order = ["default", "ivy", "wren"];
        Assert.Null(WalkProof.WalkedTo(order, "default", forward: true, ["ivy", "wren"]));
        Assert.Null(WalkProof.WalkedTo(order, "wren", forward: false, ["ivy", "default"]));
        Assert.Null(WalkProof.WalkedTo(order, "wren", forward: true, []));   // at the end already: nothing
        // A wraparound, a skipped row, a stop short, the wrong direction: each named.
        Assert.Equal("Next Chat shows ivy, wren, default, not ivy, wren", WalkProof.WalkedTo(order, "default", true, ["ivy", "wren", "default"]));
        Assert.Equal("Next Chat shows wren, not ivy, wren", WalkProof.WalkedTo(order, "default", true, ["wren"]));
        Assert.Equal("Previous Chat shows ivy, not ivy, default", WalkProof.WalkedTo(order, "wren", false, ["ivy"]));
        Assert.Equal("nobody isn't in the list walked", WalkProof.WalkedTo(order, "nobody", true, []));
        // ChatWalk itself agrees: pressing from the start visits exactly that.
        var seen = new List<string>();
        for (var at = "default"; ChatWalk.Target(order, at, forward: true) is { } next; at = next) seen.Add(next);
        Assert.Null(WalkProof.WalkedTo(order, "default", true, seen));
    }

    private static JsonNode Rest(params (string Method, string Path)[] rows) => new JsonObject
    {
        ["rest"] = new JsonArray([.. rows.Select(r => (JsonNode)new JsonObject { ["method"] = r.Method, ["path"] = r.Path })]),
    };

    [Fact]
    public void RefetchedWantsAnotherGetOfTheListAfterTheMarkAndNoWrite()
    {
        var list = WalkProof.SessionsListPath;
        Assert.Equal("/api/profiles/sessions/sidebar", list);
        var state = Rest(("GET", list), ("GET", "/api/profiles"), ("GET", list));
        Assert.Null(WalkProof.Refetched(state, 2));
        Assert.Equal($"no second GET {list} reached the gateway", WalkProof.Refetched(state, 3));   // only the first read
        Assert.Equal($"no second GET {list} reached the gateway", WalkProof.Refetched(Rest(("GET", list), ("GET", "/api/profiles")), 1));
        Assert.Equal("Refresh wrote PATCH /api/sessions/x",
            WalkProof.Refetched(Rest(("GET", list), ("PATCH", "/api/sessions/x"), ("GET", list)), 1));
        Assert.Equal($"no second GET {list} reached the gateway", WalkProof.Refetched(new JsonObject(), 0));
    }

    /// [WIN-39] CI run 44993175161: the walk read Sessions' first row before Ctrl+R's read was applied. The chat the
    /// new-chat-draft walk started was listed first once read, so Ctrl+Down opened it (as the Mac's `walkTarget` reads
    /// `paneOrder` as it shows now) while the walk waited for the old first row.
    [Fact]
    public void SessionsFirstRowIsReadAfterCtrlRsListingIsApplied()
    {
        var list = WalkProof.SessionsListPath;
        var trip = ChatWalk.SessionKey("default", WalkProof.TripStoredId);
        var started = ChatWalk.SessionKey("default", "20261011_120000_branch01");
        WalkFacts OnSessions(IReadOnlyList<string> rows) => new(OpenPane.Place, null, null, "sessions", false, ["default", "ivy"], rows);
        var before = WalkKeys.Target(OnSessions([trip]), forward: true);
        var after = WalkKeys.Target(OnSessions([started, trip]), forward: true);
        Assert.Equal(trip, before);
        Assert.Equal(started, after);   // what the key opened: the refreshed list's first row
        // The walk waits for every listing served since its mark: two GETs (Ctrl+R's and the page's) mean two applied.
        var state = Rest(("GET", list), ("GET", "/api/profiles"), ("GET", list), ("PATCH", "/api/sessions/x"), ("GET", list));
        Assert.Equal(2, WalkProof.ListReads(state, 1));
        Assert.Equal(0, WalkProof.ListReads(state, 5));
        Assert.Equal(3, WalkProof.ListReads(state, -1));
        Assert.Equal(0, WalkProof.ListReads(new JsonObject(), 0));
    }

    [Fact]
    public void AWalkKeyThatActedElsewhereFailsWithWhatItOpenedAndOnlyAMissedKeyFallsBack()
    {
        Assert.Equal(WalkProof.Press.Landed, WalkProof.Pressed(true, 3, 4));
        Assert.Equal(WalkProof.Press.Missed, WalkProof.Pressed(false, 3, 3));     // `[keys] next chat` never logged
        Assert.Equal(WalkProof.Press.Elsewhere, WalkProof.Pressed(false, 3, 4));  // it was, and opened another row
        var opened = new WalkFacts(OpenPane.Chat, "default", "20261011_120000_branch01", null, true, [], []);
        Assert.Equal("Ctrl+Down on Sessions opened the chat default/20261011_120000_branch01 from Sessions, not the chat default/trip from Sessions (its first row)",
            WalkProof.OpenedInstead("Ctrl+Down on Sessions", opened, "the chat default/trip from Sessions (its first row)"));
        Assert.Equal("the chat ivy/s1 from the bots", WalkProof.Showing(opened with { Profile = "ivy", StoredId = "s1", FromSessions = false }));
        Assert.Equal("ivy's chat", WalkProof.Showing(opened with { Pane = OpenPane.BotChat, Profile = "ivy" }));
        Assert.Equal("the jobs page", WalkProof.Showing(opened with { Pane = OpenPane.Place, PlaceId = "jobs" }));
        Assert.Equal("no chat", WalkProof.Showing(opened with { Pane = OpenPane.Nothing }));
    }

    [Fact]
    public void SupportIsListedOnceAndSignOutStaysLast()
    {
        Assert.Null(WalkProof.SupportListed(["Signed in as me", "Settings", "Keyboard Shortcuts", HelpMenu.SupportTitle, "Sign Out"]));
        Assert.Equal("the menu lists “Hermes HQ Support” 0 times", WalkProof.SupportListed(["Settings", "Sign Out"]));
        Assert.Equal("the menu lists “Hermes HQ Support” 2 times", WalkProof.SupportListed([HelpMenu.SupportTitle, HelpMenu.SupportTitle, "Sign Out"]));
        Assert.Equal("“Hermes HQ Support” is the menu's last item", WalkProof.SupportListed(["Sign Out", HelpMenu.SupportTitle]));
    }

    [Fact]
    public void AFileWindowsBarReadsOpenInShareAndSaveAs()
    {
        Assert.Equal(["Open in Microsoft Edge", "Share…", "Save As…"], WalkProof.FileWindowBar("Microsoft Edge"));
        Assert.Equal([Hermes.Core.Artifacts.ArtifactPageWords.OpenInDefaultApp, "Share…", "Save As…"], WalkProof.FileWindowBar(null));
        Assert.Null(WalkProof.BarReads(["Open in Notepad", "Share…", "Save As…"], "Notepad"));
        Assert.Equal("the file window's bar shows Share…, Save As…, not Open in Notepad, Share…, Save As…",
            WalkProof.BarReads(["Share…", "Save As…"], "Notepad"));
    }

    [Fact]
    public void FileWindowsOpenOnceComeForwardAndCtrlWClosesOnlyItsOwn()
    {
        var page = Hermes.Core.Artifacts.FileWindowKey.Page(null, "/tmp/walk/index.html");
        var note = Hermes.Core.Artifacts.FileWindowKey.Page(null, "/tmp/walk/index.md");
        Assert.Null(WalkProof.WindowOpened([], [page], page));
        Assert.Null(WalkProof.WindowOpened([page], [page, note], note));
        Assert.Equal($"{page} had a window before it was opened", WalkProof.WindowOpened([page], [page], page));
        Assert.Equal($"{note} has 0 windows, not 1", WalkProof.WindowOpened([page], [page], note));
        Assert.Equal("2 windows opened, not 1", WalkProof.WindowOpened([], [page, note], note));

        Assert.Null(WalkProof.BroughtForward([page, note], [note, page], page));
        Assert.Equal("opening it again made 1 more windows", WalkProof.BroughtForward([page], [page, note], page));
        Assert.Equal($"{page} has 0 windows after opening it again", WalkProof.BroughtForward([page], [note], page));

        Assert.Null(WalkProof.ClosedKeepingChat([page, note], [note], page, "s-notes", "s-notes"));
        Assert.Equal($"{page}'s window is still open", WalkProof.ClosedKeepingChat([page, note], [page, note], page, "s-notes", "s-notes"));
        Assert.Equal("Ctrl+W closed another file window too", WalkProof.ClosedKeepingChat([page, note], [], page, "s-notes", "s-notes"));
        Assert.Equal("the main window shows no chat, not s-notes", WalkProof.ClosedKeepingChat([page], [], page, "s-notes", null));
        Assert.Equal("the main window had no chat open", WalkProof.ClosedKeepingChat([page], [], page, null, null));

        // The registry the windows live in agrees: the same page opened again is the window it has; closed, it leaves.
        var registry = new Hermes.Core.Artifacts.FileWindowRegistry<object>();
        var made = registry.OpenPage(page, "index.html", _ => new object());
        Assert.Equal(Hermes.Core.Artifacts.FileWindowOutcome.Opened, made.Outcome);
        var again = registry.OpenPage(page, "index.html", _ => new object());
        Assert.Equal(Hermes.Core.Artifacts.FileWindowOutcome.BroughtForward, again.Outcome);
        Assert.Same(made.Window, again.Window);
        Assert.Null(WalkProof.BroughtForward([page], [.. registry.Keys], page));
        registry.Closed(made.Window!);
        Assert.Null(WalkProof.ClosedKeepingChat([page], [.. registry.Keys], page, "s-notes", "s-notes"));
    }

    [Fact]
    public void TheWindowKeysAndFileWindowsWalksRunOnTheirStandIns()
    {
        var extras = Extras();
        var composer = Assert.Single(extras, e => e.Walks.Contains("window-keys"));
        Assert.Equal("windows/ci/fixtures/composer-gateway.py", composer.Script);
        foreach (var shot in new[] { "window-keys-sessions", "window-keys-last", "window-keys-first", "window-keys-support" })
            Assert.Contains(shot, composer.Shots);
        var artifacts = Assert.Single(extras, e => e.Walks.Contains("file-windows"));
        Assert.Equal("windows/ci/fixtures/artifacts-gateway.py", artifacts.Script);
        Assert.Contains("file-windows-page", artifacts.Shots);
        Assert.Contains("file-windows-note", artifacts.Shots);
        // The walks press keys by SendInput and note where they fall back.
        var walks = File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Services", "ProofWalks.Windows.cs"));
        Assert.Contains("unproven by keyboard", walks);
        Assert.Contains("Keys.Press(Keys.W, ctrl: true, target: pageWindow)", walks);
        Assert.Contains("RegisterWindowWalks();", AppSource());
    }
}
