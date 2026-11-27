using System.Text.Json.Nodes;

namespace Hermes.Core.Shell;

/// What the CI's screenshot walks (HermesHQ.Windows/Services/Automation.cs named walks) check in a stand-in's own record
/// after driving the app, so a picture is backed by what went over the wire. Each check answers null when the record
/// shows what it should, otherwise the words of what is wrong (the walk throws them, which fails that extra).
public static partial class WalkProof
{
    /// Anything that would put words into a chat: a prompt (and its side kinds), a steer, or a typed command sent on.
    public static readonly IReadOnlyList<string> PromptMethods =
        ["prompt.submit", "prompt.btw", "prompt.background", "session.redirect", "slash.exec", "command.dispatch"];

    /// The newest `at` in a menus-family stand-in's `GET /__menus/state` call log (0 when it is empty): a mark taken
    /// before the walk acts, so only later calls are judged.
    public static double LastCallAt(JsonNode? menusState) =>
        (menusState.Arr("calls") ?? []).OfType<JsonNode>().Select(c => c.Num("at") ?? 0).DefaultIfEmpty(0).Max();

    private static List<JsonNode> CallsAfter(JsonNode? menusState, double mark) =>
        [.. (menusState.Arr("calls") ?? []).OfType<JsonNode>().Where(c => (c.Num("at") ?? 0) > mark)];

    /// `/new <words>` (Hermes.Core.Composer.NewChatCommand; the Mac's `AppModel.openNewChat`): after `mark` the
    /// stand-in made exactly one chat (`session.create`) for `profile` and took no prompt of any kind, so the old chat got
    /// nothing and the new one waits for its first send with the words only in its box.
    public static string? NewChatSentNothing(JsonNode? menusState, double mark, string profile)
    {
        var calls = CallsAfter(menusState, mark);
        var prompts = calls.Where(c => PromptMethods.Contains(c.Str("method") ?? "")).Select(c => c.Str("method")).ToList();
        if (prompts.Count > 0) return $"/new sent {string.Join(", ", prompts)} to the gateway";
        var creates = calls.Where(c => c.Str("method") == "session.create").ToList();
        if (creates.Count != 1) return $"/new made {creates.Count} chats, not 1";
        var made = creates[0]["params"].Str("profile");
        if (made != profile) return $"/new made a chat for {made ?? "no bot"}, not {profile}";
        return null;
    }

    /// Bare "/new" by keyboard: the first Enter picks /new in the drawer, which only puts "/new " in the box (it takes
    /// words; `SlashCatalog.PickActionFor` → Insert, the Mac's `pickAction` → .insert). After `mark` the stand-in made no
    /// chat and took no prompt of any kind. Null when so.
    public static string? NewChatPickSentNothing(JsonNode? menusState, double mark)
    {
        var calls = CallsAfter(menusState, mark);
        if (calls.FirstOrDefault(c => PromptMethods.Contains(c.Str("method") ?? "")) is { } prompt)
            return $"the drawer's pick of /new sent {prompt.Str("method")} to the gateway";
        return calls.Any(c => c.Str("method") == "session.create") ? "the drawer's pick of /new made a chat" : null;
    }

    /// The newest `at` in settings-gateway.py's `GET /__settings/state` writes (0 when there are none).
    public static double LastWriteAt(JsonNode? settingsState) =>
        (settingsState.Arr("writes") ?? []).OfType<JsonNode>().Select(w => w.Num("at") ?? 0).DefaultIfEmpty(0).Max();

    /// Auto-Archive Stale Chats turned on with Archive After `days` (Settings › Hermes › Archiving & Project Folder;
    /// `Hermes.Core.Settings.AutoArchive`): after `mark` the stand-in took at least one `PUT /api/config`, each a sparse
    /// `{config: {sessions: {…}}}` holding only the two Auto-Archive keys, and together they leave
    /// `sessions.auto_archive = true` and `sessions.auto_archive_days = days`.
    public static string? AutoArchiveSaved(JsonNode? settingsState, double mark, long days)
    {
        var puts = (settingsState.Arr("writes") ?? []).OfType<JsonNode>()
            .Where(w => (w.Num("at") ?? 0) > mark && w.Str("method") == "PUT /api/config").ToList();
        if (puts.Count == 0) return "no PUT /api/config reached the gateway";
        bool? on = null;
        long? saved = null;
        foreach (var put in puts)
        {
            if (put["params"].Get("config") is not JsonObject config) return "a PUT /api/config without a config object";
            if (config.Count != 1 || config["sessions"] is not JsonObject sessions)
                return $"a PUT /api/config wrote more than sessions: {config.ToJsonString()}";
            foreach (var (key, value) in sessions)
            {
                switch (key)
                {
                    case "auto_archive" when value is JsonValue v && v.TryGetValue(out bool b): on = b; break;
                    case "auto_archive_days" when sessions.Int(key) is { } n: saved = n; break;
                    default: return $"a PUT /api/config wrote sessions.{key} = {value?.ToJsonString() ?? "null"}";
                }
            }
        }
        if (on != true) return $"sessions.auto_archive ended {(on == null ? "unwritten" : "false")}";
        if (saved != days) return $"sessions.auto_archive_days ended {(saved == null ? "unwritten" : saved.ToString())}, not {days}";
        return null;
    }

    // ------------------------------------------------------------------ chat Find (composer-gateway.py)

    /// The composer stand-in's "Trip planning" chat (menus-gateway.py `TRIP`), the chat-find walk's chat, and the word it
    /// finds there: "Food, walking, a little history." and "…good food within a few blocks." (`TRIP_ROWS_TEXT`), so
    /// two matches (WalkProofEndToEndTests checks the stand-in still says so).
    public const string TripStoredId = "20261005_090000_menus001";
    public const string TripTitle = "Trip planning";
    public const string FindWord = "food";
    public const int FindMatches = 2;

    // ------------------------------------------------------------------ Tasks Sort By (pages-fixture-gateway.py --task-lists)

    /// The tasks-sort-select walk's list: Home, as `seed_task_lists` makes it. In My Order (positions 1 and 2, then the
    /// two older tasks moved in by their creation stamps) and by Due Date (the one due today first, the undated after in
    /// their own order).
    public const string HomeList = "sec_home";
    public static readonly IReadOnlyList<string> HomeMyOrder = ["t_h_filter", "t_h_gutters", "t_porch", "t_cleaning"];
    public static readonly IReadOnlyList<string> HomeByDue = ["t_cleaning", "t_h_filter", "t_h_gutters", "t_porch"];

    /// How many REST calls the pages stand-in's `GET /__fixture/state` has logged (`rest`, oldest first): a mark taken
    /// before the walk acts, so only later calls are judged.
    public static int RestCount(JsonNode? fixtureState) => fixtureState.Arr("rest")?.Count ?? 0;

    /// Sort By › `sort` on the Tasks page (Hermes.Core.Tasks.TasksStore.SetSortAsync, the Mac's `TodoSettings` save):
    /// after `mark` the stand-in took at least one `PUT …/tasks/settings`, each the whole settings object (its `sort`
    /// among them), the last saying `sort`; and nothing else was written to the tasks (Sort By and Select move, tick
    /// and delete nothing).
    public static string? TasksSortSaved(JsonNode? fixtureState, int mark, string sort)
    {
        var settings = Tasks.TasksApi.Base + "/settings";
        var after = (fixtureState.Arr("rest") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).ToList();
        var writes = after.Where(r => r.Str("method") is { } m && m != "GET" && (r.Str("path") ?? "").StartsWith(Tasks.TasksApi.Base, StringComparison.Ordinal)).ToList();
        if (writes.FirstOrDefault(w => !(w.Str("method") == "PUT" && w.Str("path") == settings)) is { } other)
            return $"the walk wrote {other.Str("method")} {other.Str("path")}";
        if (writes.Count == 0) return "no PUT /tasks/settings reached the gateway";
        foreach (var put in writes)
            if (put["body"] is not JsonObject body || body.Str("sort") == null)
                return $"a PUT /tasks/settings without the settings' sort: {put["body"]?.ToJsonString() ?? "null"}";
        var saved = writes[^1]["body"].Str("sort");
        return saved == sort ? null : $"the last PUT /tasks/settings saved sort {saved}, not {sort}";
    }

    // ------------------------------------------------------------------ Tasks Select's actions (the same stand-in)

    /// The tasks-select-actions walk, after tasks-sort-select left Home by Due Date: the first two rows picked and marked
    /// done (they fold into Done), the next moved to Work, the last deleted. Home's open rows after each.
    public static readonly IReadOnlyList<string> TasksDonePicks = ["t_cleaning", "t_h_filter"];
    public const string TasksMovePick = "t_h_gutters";
    public const string TasksMoveTo = "sec_work";
    public const string TasksDeletePick = "t_porch";
    public static readonly IReadOnlyList<string> HomeAfterDone = ["t_h_gutters", "t_porch"];
    public static readonly IReadOnlyList<string> HomeAfterMove = ["t_porch"];

    /// The task writes after `mark`, exactly one `method` on `…/tasks/<id>` for each of `ids` and nothing else written
    /// to the tasks, each body passing `body` (null: fine; else what is wrong). Null when so.
    private static string? TasksWritten(JsonNode? fixtureState, int mark, string method, IReadOnlyList<string> ids, Func<JsonNode?, string?> body)
    {
        var after = (fixtureState.Arr("rest") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).ToList();
        var writes = after.Where(r => r.Str("method") is { } m && m != "GET" && (r.Str("path") ?? "").StartsWith(Tasks.TasksApi.Base, StringComparison.Ordinal)).ToList();
        var seen = new List<string>();
        foreach (var w in writes)
        {
            var path = w.Str("path") ?? "";
            var id = path.StartsWith(Tasks.TasksApi.Base + "/", StringComparison.Ordinal) ? path[(Tasks.TasksApi.Base.Length + 1)..] : "";
            if (w.Str("method") != method || !ids.Contains(id)) return $"the walk wrote {w.Str("method")} {path}";
            if (seen.Contains(id)) return $"{method} {id} reached the gateway twice";
            if (body(w["body"]) is { } wrong) return $"{method} {id}: {wrong}";
            seen.Add(id);
        }
        var missing = ids.Where(id => !seen.Contains(id)).ToList();
        return missing.Count == 0 ? null : $"no {method} for {string.Join(", ", missing)} reached the gateway";
    }

    /// Select's Mark Done (TasksStore.SetDoneAsync; the Mac's TasksStore `PATCH` with `status`): one PATCH per picked
    /// task, `{status: "done", rev}`, nothing else written.
    public static string? TasksMarkedDone(JsonNode? fixtureState, int mark, IReadOnlyList<string> ids) =>
        TasksWritten(fixtureState, mark, "PATCH", ids, b =>
            b.Str("status") != "done" ? $"status {b.Str("status") ?? "unwritten"}, not done"
            : b.Int("rev") == null ? "no rev" : null);

    /// Select's Move To › a list (TasksStore.MoveAsync): one PATCH per picked task naming `section` and a position.
    public static string? TasksMovedTo(JsonNode? fixtureState, int mark, IReadOnlyList<string> ids, string section) =>
        TasksWritten(fixtureState, mark, "PATCH", ids, b =>
            b.Str("section") != section ? $"section {b.Str("section") ?? "unwritten"}, not {section}"
            : b.Num("position") == null ? "no position" : b.Int("rev") == null ? "no rev" : null);

    /// Select's Delete, confirmed (TasksStore.DeleteAsync): one DELETE per picked task.
    public static string? TasksDeleted(JsonNode? fixtureState, int mark, IReadOnlyList<string> ids) =>
        TasksWritten(fixtureState, mark, "DELETE", ids, _ => null);

    /// The rows a page shows, top to bottom, against what they should be: null when they match.
    public static string? Order(IReadOnlyList<string> shown, IReadOnlyList<string> expected, string what) =>
        shown.SequenceEqual(expected) ? null : $"{what} shows {string.Join(", ", shown)}, not {string.Join(", ", expected)}";

    // ------------------------------------------------------------------ sidebar Search folded (SidebarSearch)

    /// An element's place in the window, in its own units.
    public readonly record struct Box(double X, double Y, double Width, double Height)
    {
        public double Right => X + Width;
    }

    /// Folded into the rail, Search and New Chat are side by side on one line (App/Mac/MacBotsRail.swift
    /// `MacSidebarTools`, [rail-actions]): the same top, Search first, `SidebarSearch.RailGap` apart, both inside the
    /// rail. Null when so (half a unit either way for rounding).
    public static string? RailToolsSideBySide(Box search, Box compose, Box rail)
    {
        const double slack = 0.5;
        if (Math.Abs(compose.Y - search.Y) > slack) return $"New Chat sits {compose.Y - search.Y:0.#} below Search, not beside it";
        if (compose.X < search.Right - slack) return "New Chat isn't after Search (they overlap or swapped)";
        var gap = compose.X - search.Right;
        if (Math.Abs(gap - SidebarSearch.RailGap) > slack) return $"Search and New Chat are {gap:0.#} apart, not {SidebarSearch.RailGap:0.#}";
        if (search.X < rail.X - slack || compose.Right > rail.Right + slack)
            return $"the tools spill out of the rail ({search.X:0.#}–{compose.Right:0.#} in {rail.X:0.#}–{rail.Right:0.#})";
        return null;
    }

    // ------------------------------------------------------------------ Settings › About (settings-gateway.py)

    /// Settings search for "verbose" (one of Detailed Logging's keywords, `SettingsSearch.Index`): its result row's id and
    /// where it leads, About with the row marked.
    public const string LogSearchWord = "verbose";
    public const string LogSearchResultId = "search.app:detailed-log";
    public const string LogRowTarget = "about:detailed-log";

    /// A notice's row on Open-Source Licenses (AboutView.swift `license-row-<name>`).
    public static string LicenseRowId(string name) => "license-row-" + name;

    /// The app log's request lines (`AppLog.Note("http", …)`: "<time> [http] <route> → …").
    private static bool IsRequestLine(string line, out string route)
    {
        const string tag = " [http] ";
        var at = line.IndexOf(tag, StringComparison.Ordinal);
        route = at < 0 ? "" : line[(at + tag.Length)..].Trim();
        // The tag sits right after the time stamp; a note elsewhere that mentions it isn't a request line.
        return at >= 0 && at <= 24 && !line[..at].Contains('[');
    }

    /// Detailed Logging turned off, then on again (DetailedLogging.Set's "detailed logging off|on" notes): judged on the
    /// last off and the first on after it. Before the off, the walk's probe (`probe`, e.g. "GET /api/config") has its
    /// request line; between them no request line at all; after the on, the probe's line again. Null when so.
    public static string? DetailedLogToggled(string log, string probe)
    {
        var lines = log.Replace("\r\n", "\n").Split('\n');
        var off = Array.FindLastIndex(lines, l => l.EndsWith("[settings] detailed logging off", StringComparison.Ordinal));
        if (off < 0) return "no \u201Cdetailed logging off\u201D in the app log";
        var on = Array.FindIndex(lines, off + 1, l => l.EndsWith("[settings] detailed logging on", StringComparison.Ordinal));
        if (on < 0) return "no \u201Cdetailed logging on\u201D after it was turned off";
        bool Probed(string l) => IsRequestLine(l, out var r) && r.StartsWith(probe + " \u2192", StringComparison.Ordinal);
        if (!lines[..off].Any(Probed)) return $"no {probe} line before Detailed Logging went off";
        var leaked = lines[(off + 1)..on].Select(l => IsRequestLine(l, out var r) ? r : null).OfType<string>().ToList();
        if (leaked.Count > 0) return $"{leaked.Count} [http] line{(leaked.Count == 1 ? "" : "s")} while Detailed Logging was off: {leaked[0]}";
        if (!lines[(on + 1)..].Any(Probed)) return $"no {probe} line after Detailed Logging came back on";
        return null;
    }

    // ------------------------------------------------------------------ Quick Actions (pages-fixture-gateway.py)

    /// The starter set as it is seeded (QuickTileStore.Starter; the Mac's QuickActionsViewController, shot
    /// artifacts/quick-actions/15-desktop-look-light.png at 93f984bb1): Memo, Talk, New Chat (wide), Add Task, Search Chats.
    public static readonly IReadOnlyList<string> QuickStarterIds =
        ["starter-memo", "starter-talk", "starter-new-chat", "starter-add-task", "starter-search"];

    /// The quick-actions walk's edit: Memo moved down one (Move Down), Search Chats removed (its − badge).
    public const string QuickMovedDown = "starter-memo";
    public const string QuickRemoved = "starter-search";
    public static readonly IReadOnlyList<string> QuickEditedIds = ["starter-talk", "starter-memo", "starter-new-chat", "starter-add-task"];

    /// The tile the walk runs afterwards, and the place it opens (QuickTileRoute.NewTask → the Tasks page).
    public const string QuickPlaceTile = "starter-add-task";
    public const string QuickPlaceId = "tasks";

    /// A tile's UI Automation id on the page (QuickActionsPage).
    public static string QuickTileAutomationId(string tileId) => "quick-tile-" + tileId;

    /// What the page saved under `hqn.quickActions` (QuickTileStore) after Done: a readable list, marked seeded, holding
    /// `expected` in that order. Null when so.
    public static string? QuickTilesSaved(Composer.IKeyValueStore store, IReadOnlyList<string> expected)
    {
        if (store.Get(QuickActions.QuickTileStore.Key) is null) return $"nothing saved under {QuickActions.QuickTileStore.Key}";
        if (store.Get(QuickActions.QuickTileStore.UnreadableKey) != null) return "the saved Quick Actions were set aside as unreadable";
        var list = QuickActions.QuickTileStore.Load(store);
        if (!list.Seeded) return "the saved Quick Actions aren't marked seeded (the starter set would come back)";
        return Order([.. list.Tiles.Select(t => t.Id)], expected, "the saved Quick Actions");
    }

    // ------------------------------------------------------------------ Quick Action tiles that run (WIN-24)

    /// The walks' own tiles, saved as the person's list before the page opens (the starter set has neither kind): a
    /// Send a Message tile with Open the Chat on for the composer stand-in's main bot, and a Run Job tile for the jobs
    /// stand-in's Morning inbox triage (pages-fixture-gateway.py `seed_jobs`, owned by inbox).
    public const string QuickSendTileId = "walk-send";
    public const string QuickRunTileId = "walk-run-job";
    public const string QuickSendBot = "default";
    public const string QuickSendWords = "What is on my plate this afternoon?";
    public const string QuickRunJobId = "j-triage";
    public const string QuickRunJobOwner = "inbox";
    public const string QuickRunJobName = "Morning inbox triage";

    /// Send a Message, Open the Chat on (QuickTile.Flag), for `bot` shown as `botName`.
    public static QuickActions.QuickTile QuickSendTile(string botName) =>
        QuickActions.QuickTile.Create(QuickActions.QuickTileKind.Send, id: QuickSendTileId)
            with { Bot = QuickSendBot, BotName = botName, Message = QuickSendWords, Flag = true };

    /// Run Job for `<owner>|<id>`, named for the job as Set Up names it.
    public static QuickActions.QuickTile QuickRunTile() =>
        QuickActions.QuickTile.Create(QuickActions.QuickTileKind.RunJob, id: QuickRunTileId, name: QuickRunJobName)
            with { Job = QuickRunJobOwner + "|" + QuickRunJobId, JobName = QuickRunJobName };

    /// What the page says once the job's trigger is in (QuickTileRun.RunJobAsync's Done, QuickActionsViewController.say).
    public static string QuickRunNotice(string job) => "\u2713 Running " + job;

    /// Send a Message with Open the Chat on (QuickActionsFeature.SendInOpenChat; NewChatRouter.send(_:inBotChatOf:)):
    /// after `mark` the composer stand-in took exactly one prompt of any kind, a `prompt.submit` of `words`. Null when so.
    public static string? QuickSentInChat(JsonNode? menusState, double mark, string words)
    {
        var prompts = CallsAfter(menusState, mark).Where(c => PromptMethods.Contains(c.Str("method") ?? "")).ToList();
        if (prompts.Count != 1) return $"the tile sent {prompts.Count} prompts, not 1";
        if (prompts[0].Str("method") != "prompt.submit") return $"the tile sent {prompts[0].Str("method")}, not prompt.submit";
        var text = prompts[0]["params"].Str("text");
        return text == words ? null : $"the tile sent \u201C{text}\u201D, not \u201C{words}\u201D";
    }

    /// Run Job (QuickTileRun.RunJobAsync; RunJobIntent.run without the wait): after `mark` the jobs stand-in took exactly
    /// one `POST /api/cron/jobs/<id>/trigger`, for `owner`, and no other job write (a running job is never paused). Null
    /// when so.
    public static string? QuickJobTriggered(JsonNode? fixtureState, int mark, string id, string owner)
    {
        var after = (fixtureState.Arr("rest") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).ToList();
        var writes = after.Where(r => r.Str("method") is { } m && m != "GET"
            && (r.Str("path") ?? "").StartsWith(Jobs.JobsApi.ListPath, StringComparison.Ordinal)).ToList();
        var trigger = Jobs.JobsApi.JobPath(id) + "/trigger";
        if (writes.FirstOrDefault(w => !(w.Str("method") == "POST" && w.Str("path") == trigger)) is { } other)
            return $"the tile wrote {other.Str("method")} {other.Str("path")}";
        if (writes.Count != 1) return $"{writes.Count} triggers for {id} reached the gateway, not 1";
        var profile = writes[0]["query"].Str("profile");
        return profile == owner ? null : $"the trigger named {profile ?? "no bot"}, not {owner}";
    }

    // ------------------------------------------------------------------ the gateway link, during a stand-in's walks

    /// The app log's link drops and throwing listeners (AppState's `[rpc] link dropped: …` and `[rpc] a … listener
    /// threw …`) between the first `[automation] <tag> walk ` note and the next extra's sign-in (or the end): the lines
    /// windows.yml fails the job on for the composer walks.
    public static IReadOnlyList<string> LinkDrops(string log, string tag)
    {
        var found = new List<string>();
        var inside = false;
        foreach (var line in log.Replace("\r\n", "\n").Split('\n'))
        {
            if (line.Contains($"[automation] {tag} walk ", StringComparison.Ordinal)) inside = true;
            else if (inside && (line.Contains("[automation] signed in to ", StringComparison.Ordinal) || line.EndsWith("[automation] done", StringComparison.Ordinal)))
                inside = false;
            if (inside && (line.Contains("[rpc] link dropped", StringComparison.Ordinal) || line.Contains("listener threw", StringComparison.Ordinal)))
                found.Add(line);
        }
        return found;
    }

    // ------------------------------------------------------------------ New Chat With… (sessions-gateway.py)

    /// The new-chat-sheet walk's pick on the sessions stand-in: the sheet's second pill (Research; Hermes is first) and
    /// Research's own project Reading, whose root the chat starts in (NewChatCompose.Folder).
    public const string NewChatBot = "research";
    public const string NewChatProject = "Reading";
    public const string NewChatFolder = "/home/hermes/reading";

    /// How many RPCs the sessions stand-in's `GET /__fixture/state` has logged (`rpc`, oldest first): a mark taken before
    /// the walk acts.
    public static int RpcCount(JsonNode? fixtureState) => fixtureState.Arr("rpc")?.Count ?? 0;

    /// Start in the New Chat sheet (SessionStore.NewChatAsync(bot, folder)): after `mark` the stand-in took exactly one
    /// `session.create`, for `profile`, in `folder` given as an explicit cwd, and no prompt of any kind. Null when so.
    public static string? NewChatStartedIn(JsonNode? fixtureState, int mark, string profile, string folder)
    {
        var after = (fixtureState.Arr("rpc") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).ToList();
        var prompts = after.Select(c => c.Str("method") ?? "").Where(PromptMethods.Contains).ToList();
        if (prompts.Count > 0) return $"the sheet sent {string.Join(", ", prompts)} to the gateway";
        var creates = after.Where(c => c.Str("method") == "session.create").ToList();
        if (creates.Count != 1) return $"the sheet made {creates.Count} chats, not 1";
        var p = creates[0]["params"];
        if (p.Str("profile") is var made && made != profile) return $"the sheet made a chat for {made ?? "no bot"}, not {profile}";
        if (p.Str("cwd") is var cwd && cwd != folder) return $"the sheet made the chat in {cwd ?? "no folder"}, not {folder}";
        if (p?["cwd_explicit"] is not JsonValue v || !v.TryGetValue(out bool explicitCwd) || !explicitCwd)
            return "session.create didn't mark its folder cwd_explicit";
        return null;
    }

    // ------------------------------------------------------------------ View's walk keys (WIN-26; composer stand-in)

    /// The sidebar's chats listing (SessionStore.RefreshAsync), which View › Refresh on Sessions reads again.
    public const string SessionsListPath = "/api/profiles/sessions/sidebar";

    /// Next Chat (Ctrl+Down) or Previous Chat (Ctrl+Up) pressed from `start` until it stopped, against ChatWalk: one row
    /// a press, every row after (or before) `start` in the list's order, ending at its end, no wraparound. Null when the
    /// rows `visited` are those.
    public static string? WalkedTo(IReadOnlyList<string> order, string start, bool forward, IReadOnlyList<string> visited)
    {
        var at = -1;
        for (var i = 0; i < order.Count; i++) if (order[i] == start) { at = i; break; }
        if (at < 0) return $"{start} isn't in the list walked";
        IReadOnlyList<string> expected = forward ? [.. order.Skip(at + 1)] : [.. order.Take(at).Reverse()];
        return Order(visited, expected, forward ? WalkKeys.NextTitle : WalkKeys.PreviousTitle);
    }

    /// View › Refresh (Ctrl+R) on a list's page (`IKeyRefreshing`): after the first `mark` entries of a menus-family
    /// stand-in's `rest` log, at least one more GET of `path` (the page read its list again) and nothing written.
    public static string? Refetched(JsonNode? menusState, int mark, string path = SessionsListPath)
    {
        var after = (menusState.Arr("rest") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).ToList();
        if (after.FirstOrDefault(r => r.Str("method") is { } m && m != "GET") is { } write)
            return $"Refresh wrote {write.Str("method")} {write.Str("path")}";
        return after.Any(r => r.Str("method") == "GET" && r.Str("path") == path) ? null : $"no second GET {path} reached the gateway";
    }

    /// [WIN-39] How many GETs of `path` reached the stand-in after the first `mark` entries of its `rest` log: each one is
    /// a chats listing the app applies (SessionStore.Reads), so the walk waits for that many before it reads the list's
    /// order. Sessions' first row is the newest chat as the gateway lists it now, not as it was before Ctrl+R.
    public static int ListReads(JsonNode? menusState, int mark, string path = SessionsListPath) =>
        (menusState.Arr("rest") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).Count(r => r.Str("method") == "GET" && r.Str("path") == path);

    /// [WIN-39] One walk key pressed: it `landed` where the walk expected; or the shell never acted on it (`acted` the
    /// same before and after: the key didn't arrive, and the walk may call what the key calls); or the shell acted and
    /// opened something else, which fails with what it opened.
    public enum Press { Landed, Missed, Elsewhere }

    public static Press Pressed(bool landed, int actedBefore, int actedAfter) =>
        landed ? Press.Landed : actedAfter != actedBefore ? Press.Elsewhere : Press.Missed;

    /// What the pane shows, in the walk's words (a failure's reason).
    public static string Showing(WalkFacts f) => f.Pane switch
    {
        OpenPane.Chat => $"the chat {f.Profile}/{f.StoredId}{(f.FromSessions ? " from Sessions" : " from the bots")}",
        OpenPane.BotChat => $"{f.Profile}'s chat",
        OpenPane.Place => $"the {f.PlaceId} page",
        _ => "no chat",
    };

    /// A walk key the shell acted on that opened something other than `expected`.
    public static string OpenedInstead(string what, WalkFacts now, string expected) => $"{what} opened {Showing(now)}, not {expected}";

    /// The sidebar foot's menu (Help › Hermes HQ Support on the Mac, MacWindow.trimMenus): the Support item once, and
    /// not last (the menu's own last item, Sign Out, stays last). Null when so.
    public static string? SupportListed(IReadOnlyList<string> items)
    {
        var count = items.Count(i => i == HelpMenu.SupportTitle);
        if (count != 1) return $"the menu lists \u201C{HelpMenu.SupportTitle}\u201D {count} times";
        return items[^1] == HelpMenu.SupportTitle ? $"\u201C{HelpMenu.SupportTitle}\u201D is the menu's last item" : null;
    }

    // ------------------------------------------------------------------ file and page windows (WIN-31; artifacts stand-in)

    /// The files the file-windows walk downloads from the artifacts stand-in and opens as a chat's file click does
    /// (MediaActions.OpenAsync → FileWindows.Open): the release page (pages-fixture-gateway.py `index.html`, in the
    /// deploys bot's \u201CThe 2.4 report\u201D) and the project notes' index (artifacts-gateway.py `NOTES`, research's
    /// \u201CProject notes\u201D, which the main window keeps open meanwhile).
    public const string WalkPagePath = "/home/hermes/site/index.html", WalkPageName = "index.html", WalkPageSession = "s-report", WalkPageBot = "deploys";
    public const string WalkNotePath = "/home/hermes/app/notes/index.md", WalkNoteName = "index.md", WalkNoteSession = "s-notes", WalkNoteBot = "research";
    public const string WalkChatTitle = "Project notes";
    /// The release page's heading (pages-fixture-gateway.py `index.html`: `<h1>Release 2.4</h1>`).
    public const string WalkPageHeading = "Release 2.4";

    /// A page's Preview in its window, as the walk reads it once it settled (ArtifactHtmlView; Artifacts/PagePreview.cs):
    /// drawn, and its live page reads `heading`. A drawn bar over a blank body is not a drawn page. Null when so.
    public static string? PageDrawn(Artifacts.PagePreviewPhase phase, string? reason, string? pageText, string heading) => phase switch
    {
        Artifacts.PagePreviewPhase.Shown when pageText?.Contains(heading, StringComparison.Ordinal) == true => null,
        Artifacts.PagePreviewPhase.Shown => $"the page drew but its body reads \u201C{Clip(pageText ?? "")}\u201D, not \u201C{heading}\u201D",
        Artifacts.PagePreviewPhase.Failed => $"the page didn't draw: {reason}",
        _ => $"the page's Preview is {phase}, not drawn",
    };

    private static string Clip(string text) => text.Length <= 80 ? text : text[..80] + "\u2026";

    /// A file window's bar (ArtifactFileWindow.ShowContent): Open in <its app>, Share…, Save As…, in that order.
    public static IReadOnlyList<string> FileWindowBar(string? app) =>
        [Artifacts.FileWindowWords.OpenIn(app), Artifacts.ArtifactPageWords.Share, Artifacts.ArtifactPageWords.SaveAs];

    /// The bar's buttons as shown against FileWindowBar. Null when they match.
    public static string? BarReads(IReadOnlyList<string> shown, string? app) => Order(shown, FileWindowBar(app), "the file window's bar");

    /// A file opened into a window of its own: the windows open after are those before and `key`, once. Null when so.
    public static string? WindowOpened(IReadOnlyCollection<string> before, IReadOnlyCollection<string> after, string key)
    {
        if (before.Contains(key)) return $"{key} had a window before it was opened";
        if (after.Count(k => k == key) != 1) return $"{key} has {after.Count(k => k == key)} windows, not 1";
        var others = after.Where(k => k != key).ToList();
        return others.Count == before.Count && others.All(before.Contains) ? null : $"{after.Count - before.Count} windows opened, not 1";
    }

    /// The same file opened again (MacFileWindow.open, FileWindowRegistry): no new window, its own still there once.
    public static string? BroughtForward(IReadOnlyCollection<string> before, IReadOnlyCollection<string> after, string key)
    {
        if (after.Count(k => k == key) != 1) return $"{key} has {after.Count(k => k == key)} windows after opening it again";
        return after.Count == before.Count && after.All(before.Contains) ? null : $"opening it again made {after.Count - before.Count} more windows";
    }

    /// Ctrl+W in a file window (FileWindowKeys.Route): that window gone, the others kept, and the main window's chat
    /// (`chatBefore`, its stored id) still on show. Null when so.
    public static string? ClosedKeepingChat(IReadOnlyCollection<string> before, IReadOnlyCollection<string> after, string key,
        string? chatBefore, string? chatAfter)
    {
        if (after.Contains(key)) return $"{key}'s window is still open";
        var kept = before.Where(k => k != key).ToList();
        if (after.Count != kept.Count || !kept.All(after.Contains)) return "Ctrl+W closed another file window too";
        if (chatBefore == null) return "the main window had no chat open";
        return chatAfter == chatBefore ? null : $"the main window shows {chatAfter ?? "no chat"}, not {chatBefore}";
    }

    // ------------------------------------------------------------------ group chats in the sidebar (settings-gateway.py --group-rooms)

    /// The stand-in's two rooms (no device section: Unassigned, with the user section Work) among Unassigned's one bot,
    /// newest first (`BotListRooms.Rows`): Launch Room (30 min ago), Weekend Plans (2.5 h), Notes (nothing said).
    public const string GroupChatsHeading = "Unassigned";
    public static readonly IReadOnlyList<string> GroupChatsUnassigned = ["room:id:rfixture-launch", "room:id:rfixture-weekend", "notes"];
    /// Launch Room's row read aloud (`GroupRowWords.AccessibilityLabel`): its name and its last line, Ivy's.
    public const string GroupChatsLaunchLabel = "Launch Room. Ivy: I can take the notes.";

    /// The sidebar's rows top to bottom as keys ("header:<title>", "divider", a bot's profile, "room:<key>", "" for the
    /// rest). Open: the rows under the Unassigned heading are the rooms and Notes in that order. Rail (`rail`): no
    /// headings, and the same heads together between two lines. Null when so.
    public static string? SidebarGroupChats(IReadOnlyList<string> keys, bool rail)
    {
        if (rail)
        {
            if (keys.FirstOrDefault(k => k.StartsWith("header:", StringComparison.Ordinal)) is { } heading) return $"the rail shows the heading {heading[7..]}";
            var start = keys.ToList().IndexOf(GroupChatsUnassigned[0]);
            if (start < 0) return "the rail has no Launch Room head";
            if (start == 0 || keys[start - 1] != "divider") return "Launch Room's head doesn't start its group in the rail";
            return Order([.. keys.Skip(start).Take(GroupChatsUnassigned.Count)], GroupChatsUnassigned, "the rail's Unassigned group");
        }
        var at = keys.ToList().IndexOf("header:" + GroupChatsHeading);
        if (at < 0) return $"the sidebar has no {GroupChatsHeading} heading";
        var rows = keys.Skip(at + 1).TakeWhile(k => !k.StartsWith("header:", StringComparison.Ordinal) && k != "divider").Where(k => k.Length > 0).ToList();
        return Order(rows, GroupChatsUnassigned, $"the sidebar's {GroupChatsHeading}");
    }

    // ------------------------------------------------------------------ transcript extras (WIN-36; composer stand-in)

    /// The composer stand-in's “Release review” chat (composer-gateway.py `EXTRAS`, never listed): its history holds a
    /// lone web address (a link chip), a wide table, a model-change note, a scheduled job's delivery and a turn that
    /// edited two files. WalkProofEndToEndTests checks the stand-in still says so.
    public const string ExtrasStoredId = "20261012_100000_extras01";
    public const string ExtrasTitle = "Release review";
    public const string ExtrasBot = "default";
    public const string ExtrasLink = "https://example.com/releases/2-4";
    public const string ExtrasLinkTitle = "Release 2.4 notes";
    public const string ExtrasJob = "Morning brief";
    public const string ExtrasModelNote = "[System: The active model for this chat has changed to claude-sonnet-5. From this point on, answer as that model.]";
    public const int ExtrasTableRows = 3, ExtrasTableColumns = 7, ExtrasFilesChanged = 2;

    /// What the walk sends: words the stand-in takes and fails with a usage limit (the error card), and words it refuses
    /// (“Couldn’t Send”), with the refusal it gives.
    public const string ExtrasLimitWords = "Try the release again";
    public const string ExtrasRefused = "Send the release notes";
    public const string ExtrasRefusal = "The gateway is restarting";

    /// The chip's words once its page was read from the stand-in (LinkChips.Face with the page's title): its accessible
    /// name, and the stand-in's record of that page read (`GET /__extras/state` `linkReads`). Null when so.
    public static string? ChipShowsFetched(string? accessibleName, JsonNode? extrasState)
    {
        var url = new Uri(ExtrasLink);
        var expected = Transcripts.LinkChips.Face(ExtrasLink, url, new Transcripts.LinkPreview(ExtrasLinkTitle, null)).AccessibleName;
        if (accessibleName != expected) return $"the chip reads \u201C{accessibleName ?? "nothing"}\u201D, not \u201C{expected}\u201D";
        var read = "/" + url.Host + url.AbsolutePath;
        var reads = (extrasState.Arr("linkReads") ?? []).Select(r => J.AsString(r)).ToList();
        return reads.Contains(read) ? null : $"the stand-in served no read of {read} (its title came from elsewhere)";
    }

    /// The other extras the chat's history draws, as words a person sees: the model-change note, the job's byline and
    /// the edited files' footer. `shown`: every piece of text the transcript shows. Null when all are there.
    public static string? ExtrasShown(IReadOnlyCollection<string> shown, string botName)
    {
        var expected = new[]
        {
            Transcripts.TimelineNotes.Note(ExtrasModelNote).Text ?? "",
            Transcripts.CronDeliveries.Header(botName, ExtrasJob),
            Transcripts.ChangedFiles.Title(ExtrasFilesChanged),
            Transcripts.TableText.FooterCounts(ExtrasTableRows, ExtrasTableColumns),
        };
        var missing = expected.Where(e => !shown.Contains(e)).ToList();
        return missing.Count == 0 ? null : $"the transcript doesn't show {string.Join(", ", missing.Select(m => $"\u201C{m}\u201D"))}";
    }

    /// The Table sheet open (MarkdownRenderer's Expand): titled “Table”, its buttons Copy as Text and Done.
    public static string? TableSheetReads(string? title, IReadOnlyList<string> buttons)
    {
        if (title != Transcripts.TableText.SheetTitle) return $"the table sheet is titled {title ?? "nothing"}, not {Transcripts.TableText.SheetTitle}";
        return Order(buttons, [Transcripts.TableText.CopyTitle, "Done"], "the table sheet's buttons");
    }

    /// The usage-limit turn's card (ErrorCard.Make; TurnErrors' UsageLimit): “Usage limit reached”, Choose a Model
    /// (no Try Again: a retry would hit the same limit) and Copy Details.
    public static string? LimitCardReads(string? title, IReadOnlyList<string> buttons)
    {
        const string expected = "Usage limit reached";
        if (title != expected) return $"the error card is titled {title ?? "nothing"}, not {expected}";
        return Order(buttons, ["Choose a Model", "Copy Details"], "the error card's buttons");
    }

    /// The “Couldn’t Send” card for the refused send (SendFailure; App/Chat/ChatNoticeCard.swift): its title and body.
    public static string? CouldntSendReads(string? title, string? body)
    {
        if (title != Transcripts.SendFailure.Title) return $"the card is titled {title ?? "nothing"}, not {Transcripts.SendFailure.Title}";
        var expected = Transcripts.SendFailure.Make(ExtrasRefusal).Body;
        return body == expected ? null : $"the card says \u201C{body}\u201D, not \u201C{expected}\u201D";
    }

    /// Choose a Model opened the chat composer's Models sheet (ModelsDialog, titled “Models”).
    public static string? ModelsSheetOpened(IReadOnlyList<string> dialogTitles) =>
        dialogTitles.Count(t => t == "Models") == 1 ? null : $"the open sheets are {(dialogTitles.Count == 0 ? "none" : string.Join(", ", dialogTitles))}, not one Models";

    /// The stand-in's record of the walk's sends in the chat (`sends`, after the first `mark`): exactly `expected`, in
    /// order. Null when so.
    public static string? ExtrasSent(JsonNode? extrasState, int mark, IReadOnlyList<string> expected)
    {
        var sends = (extrasState.Arr("sends") ?? []).Skip(Math.Max(0, mark)).Select(s => J.AsString(s) ?? "").ToList();
        return Order(sends, expected, "the chat's sends");
    }

    /// How many sends the stand-in has taken in the chat: a mark taken before the walk sends.
    public static int ExtrasSendCount(JsonNode? extrasState) => extrasState.Arr("sends")?.Count ?? 0;
}
