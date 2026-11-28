namespace Hermes.Core.QuickActions;

// [quick-actions] Where a Favorites tile's tap goes, what is missing for it, how the grid lays tiles out, what Add
// Action offers and when Set Up may save: the pure parts of HermesKit/Intents/QuickTiles.swift (`QuickTileWorld`,
// `QuickTileRoute`, `QuickTileRules`, `QuickTileGrid`) and App/QuickActions/QuickActionSetup.swift (`QuickActionChoice`,
// `QuickActionDraft.canSave` / `finished`). Covers all 28 tile kinds including Voice Memo and Talk on Windows.

/// What is around when a tile is drawn or tapped: the CURRENT gateway's roster, jobs, pages, pins, rooms, sessions,
/// goals, task lists, dashboard pages, boards, and gateway identity. Null: not known yet, which is never "missing".
public sealed record QuickTileWorld(
    IReadOnlyDictionary<string, string>? Bots = null,
    IReadOnlySet<string>? Jobs = null,
    IReadOnlyDictionary<string, string>? Pages = null,
    IReadOnlyDictionary<string, string>? Pins = null,
    IReadOnlyDictionary<string, string>? Rooms = null,
    IReadOnlyDictionary<string, string>? Sessions = null,
    IReadOnlyDictionary<string, string>? Goals = null,
    IReadOnlyDictionary<string, string>? TaskLists = null,
    IReadOnlyDictionary<string, string>? DashboardPages = null,
    IReadOnlyDictionary<string, string>? Boards = null,
    bool? TasksEnabled = null,
    string? CurrentGatewayId = null);

/// Where a tap goes (`QuickTileRoute`): each case is the route its Shortcuts twin or native view takes.
public abstract record QuickTileRoute
{
    // Original routes (names & signatures preserved for existing tests)
    public sealed record NewChat(string Bot, string? Project, string? Message, bool Send) : QuickTileRoute;
    public sealed record Talk(string Profile) : QuickTileRoute;
    public sealed record Memo(string Profile) : QuickTileRoute;
    public sealed record OpenChat(string Profile) : QuickTileRoute;
    public sealed record SendInChat(string Profile, string Words) : QuickTileRoute;
    public sealed record SendInBackground(string Profile, string Words) : QuickTileRoute;
    public sealed record NewTask(string? Bot) : QuickTileRoute;
    public sealed record RunJob(string Key, string Name) : QuickTileRoute;
    public sealed record Page(string Id) : QuickTileRoute;
    public sealed record Search : QuickTileRoute;
    public sealed record DashboardTile(string Id) : QuickTileRoute;

    // Expanded routes
    public sealed record TasksView(string Key) : QuickTileRoute;
    public sealed record Goal(string Id) : QuickTileRoute;
    public sealed record NeedsYou : QuickTileRoute;
    public sealed record GroupChat(string Key) : QuickTileRoute;
    public sealed record ChatSession(string Profile, string SessionId) : QuickTileRoute;
    public sealed record JobDetail(string? Key) : QuickTileRoute;
    public sealed record Kanban(string? Board, string? Status) : QuickTileRoute;
    public sealed record GatewayStatus : QuickTileRoute;
    public sealed record Usage : QuickTileRoute;
    public sealed record QuickAsk(string Profile, bool DefaultOpen) : QuickTileRoute;
    public sealed record SlashCommand(string Profile, string Command) : QuickTileRoute;
    public sealed record DashboardPage(string Id) : QuickTileRoute;
    public sealed record FilesFolder(string? Profile, string Path) : QuickTileRoute;
    public sealed record Link(Uri Url) : QuickTileRoute;
    public sealed record Routine(IReadOnlyList<QuickRoutineStep> Steps, string Name) : QuickTileRoute;
    public sealed record ToggleSection(string Id) : QuickTileRoute;
    public sealed record Unavailable(string Words) : QuickTileRoute;

    /// The page stays open and says what happened (a background tile, section toggle, Quick Ask sheet, or unavailable).
    public bool StaysOnPage => this switch
    {
        SendInBackground or RunJob or Unavailable or ToggleSection or QuickAsk => true,
        Routine r => r.Steps.All(s => s.KnownKind?.IsBackground() == true),
        _ => false,
    };

    /// Validates and normalizes an external web URL (`http` or `https` only, requiring a non-empty host).
    public static Uri? NormalizedUrl(string? raw)
    {
        var trimmed = raw?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return null;
        var candidate = trimmed.Contains("://", StringComparison.Ordinal) ? trimmed : "https://" + trimmed;
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)) return null;
        var scheme = uri.Scheme.ToLowerInvariant();
        if (scheme is not ("http" or "https")) return null;
        if (string.IsNullOrEmpty(uri.Host)) return null;
        return uri;
    }

    /// The route for `tile` against what the current gateway has (`QuickTileRoute.make`). `runs`: the kinds this build
    /// has a route for (null: all, as the Mac); any other kind is `Unavailable(QuickTileRules.NewerApp)`.
    public static QuickTileRoute Make(QuickTile tile, QuickTileWorld world, IReadOnlySet<QuickTileKind>? runs = null)
    {
        if (QuickTileRules.Missing(tile, world, runs) is { } missing) return new Unavailable(missing);
        if (tile.Known is not { } kind) return new Unavailable(QuickTileRules.NewerApp);
        var bot = tile.Bot ?? "";
        var words = string.IsNullOrWhiteSpace(tile.Message) ? null : tile.Message;
        switch (kind)
        {
            case QuickTileKind.NewChat:
                return new NewChat(bot, string.IsNullOrEmpty(tile.Project) ? null : tile.Project, words, tile.Flag ?? true);
            case QuickTileKind.Memo:
                return new Memo(bot);
            case QuickTileKind.Talk:
                return new Talk(bot);
            case QuickTileKind.OpenChat:
            case QuickTileKind.BotCard:
                return new OpenChat(bot);
            case QuickTileKind.Send:
                if (words == null) return new Unavailable("Add the words to send in Edit.");
                return tile.Flag == true ? new SendInChat(bot, words) : new SendInBackground(bot, words);
            case QuickTileKind.Prompt:
                if (words == null) return new Unavailable("Choose a prompt in Edit.");
                return tile.Flag == true ? new SendInChat(bot, words) : new SendInBackground(bot, words);
            case QuickTileKind.SlashCommand:
                var cmd = (tile.Command ?? "").Trim();
                if (cmd.Length == 0) return new Unavailable("Choose a command in Edit.");
                return new SlashCommand(bot, cmd);
            case QuickTileKind.QuickAsk:
                return new QuickAsk(bot, tile.Flag ?? true);
            case QuickTileKind.AddTask:
                return new NewTask(string.IsNullOrEmpty(tile.Bot) ? null : tile.Bot);
            case QuickTileKind.RunJob:
                return new RunJob(tile.Job ?? "", tile.JobName ?? tile.Name);
            case QuickTileKind.Page:
                return new Page(tile.Page ?? "");
            case QuickTileKind.Search:
                return new Search();
            case QuickTileKind.DashboardTile:
                return new DashboardTile(tile.Pin ?? "");
            case QuickTileKind.Tasks:
                return new TasksView(string.IsNullOrEmpty(tile.TaskView) ? "today" : tile.TaskView);
            case QuickTileKind.Goal:
                return new Goal(tile.GoalId ?? "");
            case QuickTileKind.NeedsYou:
                return new NeedsYou();
            case QuickTileKind.GroupChat:
                return new GroupChat(tile.RoomKey ?? "");
            case QuickTileKind.ChatSession:
                return new ChatSession(bot, tile.SessionId ?? "");
            case QuickTileKind.JobCard:
                return new JobDetail(string.IsNullOrEmpty(tile.Job) ? null : tile.Job);
            case QuickTileKind.Kanban:
                return new Kanban(string.IsNullOrEmpty(tile.BoardSlug) ? null : tile.BoardSlug,
                    string.IsNullOrEmpty(tile.ColumnStatus) ? null : tile.ColumnStatus);
            case QuickTileKind.GatewayStatus:
                return new GatewayStatus();
            case QuickTileKind.Usage:
                return new Usage();
            case QuickTileKind.DashboardPage:
                return new DashboardPage(string.IsNullOrEmpty(tile.DashboardPageId) ? "main" : tile.DashboardPageId);
            case QuickTileKind.FilesFolder:
                return new FilesFolder(string.IsNullOrEmpty(tile.Bot) ? null : tile.Bot, tile.FolderPath ?? "");
            case QuickTileKind.Link:
                if (NormalizedUrl(tile.Url) is not { } parsed) return new Unavailable("Add a valid web address in Edit.");
                return new Link(parsed);
            case QuickTileKind.Routine:
                var steps = tile.Steps ?? [];
                if (steps.Count == 0) return new Unavailable("Add at least one step in Edit.");
                return new Routine(steps, tile.Name);
            case QuickTileKind.Section:
                return new ToggleSection(tile.Id);
            default:
                return new Unavailable(QuickTileRules.NewerApp);
        }
    }
}

public static class QuickTileRules
{
    public const string NewerApp = "This action needs a newer version of Hermes HQ.";

    /// All 28 kinds supported on Windows (including Voice Memo, Talk, 10 native live cards, Dashboard tiles,
    /// deeper shortcuts, routines, and collapsible sections).
    public static readonly IReadOnlySet<QuickTileKind> Windows =
        Enum.GetValues<QuickTileKind>().ToHashSet();

    /// One sentence when the tile's target isn't on this gateway (null: it is, or that isn't known yet).
    public static string? Missing(QuickTile tile, QuickTileWorld world, IReadOnlySet<QuickTileKind>? runs = null)
    {
        if (tile.Known is not { } kind) return NewerApp;
        if (runs != null && !runs.Contains(kind)) return NewerApp;
        if ((kind.NeedsBot() || (kind == QuickTileKind.AddTask && tile.Bot != null)) && tile.Bot is { } bot && world.Bots is { } bots
            && !bots.ContainsKey(bot))
            return $"{tile.BotName ?? bot} isn’t on this gateway.";
        if (kind.NeedsBot() && string.IsNullOrEmpty(tile.Bot)) return "Choose a bot for this action in Edit.";
        if (kind == QuickTileKind.RunJob)
        {
            if (string.IsNullOrEmpty(tile.Job)) return "Choose a job for this action in Edit.";
            if (world.Jobs is { } jobs && !jobs.Contains(tile.Job)) return $"“{tile.JobName ?? tile.Name}” isn’t on this gateway.";
        }
        if (kind == QuickTileKind.JobCard && !string.IsNullOrEmpty(tile.Job) && world.Jobs is { } cardJobs && !cardJobs.Contains(tile.Job))
            return $"“{tile.JobName ?? tile.Name}” isn’t on this gateway.";
        if (kind == QuickTileKind.Page)
        {
            if (string.IsNullOrEmpty(tile.Page)) return "Choose a page for this action in Edit.";
            if (world.Pages is { } pages && !pages.ContainsKey(tile.Page)) return $"{tile.PageName ?? tile.Name} isn’t on this gateway.";
        }
        if (kind == QuickTileKind.DashboardTile)
        {
            if (string.IsNullOrEmpty(tile.Pin)) return NotOnDashboard(tile);
            if (world.Pins is { } pins && !pins.ContainsKey(tile.Pin)) return NotOnDashboard(tile);
        }
        if (kind == QuickTileKind.Tasks)
        {
            if (world.TasksEnabled == false) return "Tasks is turned off in Settings.";
            if (tile.TaskView is { } view && view.StartsWith("list:", StringComparison.Ordinal) && world.TaskLists is { } lists)
            {
                var listId = view[5..];
                if (!lists.ContainsKey(listId)) return $"“{tile.TaskViewName ?? tile.Name}” isn’t on this gateway.";
            }
        }
        if (kind == QuickTileKind.Goal)
        {
            if (world.TasksEnabled == false) return "Tasks is turned off in Settings.";
            if (string.IsNullOrEmpty(tile.GoalId)) return "Choose a goal in Edit.";
            if (world.Goals is { } goals && !goals.ContainsKey(tile.GoalId)) return $"“{tile.GoalName ?? tile.Name}” isn’t on this gateway.";
        }
        if (kind == QuickTileKind.GroupChat)
        {
            if (string.IsNullOrEmpty(tile.RoomKey)) return "Choose a group chat in Edit.";
            if (world.Rooms is { } rooms && !rooms.ContainsKey(tile.RoomKey)) return $"“{tile.RoomName ?? tile.Name}” isn’t on this gateway.";
        }
        if (kind == QuickTileKind.ChatSession)
        {
            if (string.IsNullOrEmpty(tile.SessionId)) return "Choose a chat in Edit.";
            if (world.Bots is { } chatBots && !string.IsNullOrEmpty(tile.Bot) && !chatBots.ContainsKey(tile.Bot))
                return $"{tile.BotName ?? tile.Bot} isn’t on this gateway.";
        }
        if (kind == QuickTileKind.Kanban && !string.IsNullOrEmpty(tile.BoardSlug) && world.Boards is { } boards && !boards.ContainsKey(tile.BoardSlug))
            return $"“{tile.BoardName ?? tile.Name}” isn’t on this gateway.";
        if (kind == QuickTileKind.DashboardPage && !string.IsNullOrEmpty(tile.DashboardPageId) && tile.DashboardPageId != "main"
            && world.DashboardPages is { } dashPages && !dashPages.ContainsKey(tile.DashboardPageId))
            return $"“{tile.DashboardPageName ?? tile.Name}” isn’t on your Dashboard any more.";
        if (kind == QuickTileKind.FilesFolder && string.IsNullOrWhiteSpace(tile.FolderPath))
            return "Choose a folder in Edit.";
        if (kind == QuickTileKind.Link && QuickTileRoute.NormalizedUrl(tile.Url) == null)
            return "Add a valid web address in Edit.";
        return null;
    }

    public static string NotOnDashboard(QuickTile tile) => $"“{tile.PinName ?? tile.Name}” isn’t on your Dashboard any more.";

    /// Whether a tile belongs to another gateway when "This Gateway Only" filter is on (`QuickTileRules.isOtherGateway`).
    public static bool IsOtherGateway(QuickTile tile, QuickTileWorld world)
    {
        if (!string.IsNullOrEmpty(tile.GatewayId) && !string.IsNullOrEmpty(world.CurrentGatewayId)
            && !string.Equals(tile.GatewayId, world.CurrentGatewayId, StringComparison.Ordinal))
            return true;
        if (tile.Known is { } kind && (kind.IsSection() || kind is QuickTileKind.Link or QuickTileKind.Search
            or QuickTileKind.NeedsYou or QuickTileKind.GatewayStatus or QuickTileKind.Usage))
            return false;
        return Missing(tile, world) != null;
    }

    /// QuickActionsRouter.missingBot / missingPage: what a foreground route says when its target went away on the way.
    public static string MissingBot(QuickTile tile) => $"{tile.BotName ?? tile.Bot ?? "That bot"} isn’t on this gateway.";
    public static string MissingPage(QuickTile tile) => $"{tile.PageName ?? tile.Name} isn’t on this gateway.";
}

/// The grid: two columns, a Wide tile across both; one full-width column when stacked (`QuickTileGrid`).
public static class QuickTileGrid
{
    /// Rows of tile indices. A small tile left alone before a wide one keeps its own row (the order never changes).
    public static IReadOnlyList<IReadOnlyList<int>> Rows(IReadOnlyList<QuickTile> tiles, int columns)
    {
        if (columns <= 1) return tiles.Select((_, i) => (IReadOnlyList<int>)[i]).ToList();
        var rows = new List<IReadOnlyList<int>>();
        var open = new List<int>();
        for (var i = 0; i < tiles.Count; i++)
        {
            if (tiles[i].Wide)
            {
                if (open.Count > 0) { rows.Add(open); open = []; }
                rows.Add([i]);
            }
            else
            {
                open.Add(i);
                if (open.Count == columns) { rows.Add(open); open = []; }
            }
        }
        if (open.Count > 0) rows.Add(open);
        return rows;
    }
}

/// One row of Add Action (`QuickActionChoice`): an action kind, live widget, Dashboard tile, shortcut, page, or section.
public sealed record QuickActionChoice(
    string Id,
    QuickTileKind Kind,
    string Title,
    string Detail,
    string? PageId = null,
    string? PageTitle = null,
    string? PinId = null,
    string? PinName = null,
    string? Symbol = null)
{
    public static readonly IReadOnlyList<QuickActionChoice> Chats =
    [
        Of(QuickTileKind.NewChat, "New Chat", "bot · project · words"),
        Of(QuickTileKind.Memo, "Voice Memo", "bot"),
        Of(QuickTileKind.Talk, "Talk", "bot"),
        Of(QuickTileKind.Send, "Send a Message", "bot · words"),
        Of(QuickTileKind.OpenChat, "Open a Chat", "bot"),
    ];

    public static readonly IReadOnlyList<QuickActionChoice> Work =
    [
        Of(QuickTileKind.AddTask, "Add Task", "bot"),
        Of(QuickTileKind.RunJob, "Run Job", "job"),
    ];

    public static readonly IReadOnlyList<QuickActionChoice> LiveWidgets =
    [
        Of(QuickTileKind.Tasks, "Tasks List", "live checklist with check-off"),
        Of(QuickTileKind.Goal, "Goal Progress", "ring, pace, and next step"),
        Of(QuickTileKind.NeedsYou, "Needs You", "approvals, waiting tasks, active bots"),
        Of(QuickTileKind.BotCard, "Live Bot Card", "avatar, status, Memo & Talk"),
        Of(QuickTileKind.GroupChat, "Group Chat", "live room card"),
        Of(QuickTileKind.ChatSession, "Specific Chat", "pin an ongoing thread"),
        Of(QuickTileKind.JobCard, "Job Status / Upcoming", "live status and Run Now"),
        Of(QuickTileKind.Kanban, "Kanban Board", "live column counts & cards"),
        Of(QuickTileKind.GatewayStatus, "Gateway Status", "health, sessions, platforms"),
        Of(QuickTileKind.Usage, "Usage Overview", "tokens, cost & sparkline"),
    ];

    public static readonly IReadOnlyList<QuickActionChoice> Shortcuts =
    [
        Of(QuickTileKind.QuickAsk, "Quick Ask…", "prompt right on Favorites"),
        Of(QuickTileKind.Prompt, "Saved Prompt", "from your prompt library"),
        Of(QuickTileKind.SlashCommand, "Slash Command", "run a favorite command"),
        Of(QuickTileKind.Routine, "Routine", "run several steps at once"),
        Of(QuickTileKind.DashboardPage, "Dashboard Page", "jump to a Tiles page"),
        Of(QuickTileKind.FilesFolder, "Files Folder", "open a specific folder"),
        Of(QuickTileKind.Link, "Web Link", "open any URL"),
    ];

    public static readonly IReadOnlyList<QuickActionChoice> Organize =
    [
        Of(QuickTileKind.Section, "Section Header", "collapsible group divider"),
    ];

    private static QuickActionChoice Of(QuickTileKind kind, string title, string detail) =>
        new(kind.Raw(), kind, title, detail, Symbol: kind.DefaultLook().Symbol);

    /// Every page (place id, title, group), then Search Chats. Favorites itself is never one.
    public static IReadOnlyList<QuickActionChoice> Pages(IEnumerable<(string Id, string Title, string Group)> pages)
    {
        var seen = new HashSet<string> { QuickTileStore.RowID };
        var out_ = pages.Where(p => seen.Add(p.Id))
            .Select(p => new QuickActionChoice("page." + p.Id, QuickTileKind.Page, p.Title, p.Group, p.Id, p.Title)).ToList();
        out_.Add(new QuickActionChoice(QuickTileKind.Search.Raw(), QuickTileKind.Search, "Search Chats", "page"));
        return out_;
    }

    /// Dashboard tiles not yet on `list` (`QuickActionChoice.dashboardTiles`).
    public static IReadOnlyList<QuickActionChoice> DashboardTiles(
        IEnumerable<(string Id, string Name, string Symbol)> pins,
        QuickTileList list)
    {
        var added = list.Pins;
        return pins.Where(p => !added.Contains(p.Id))
            .Select(p => new QuickActionChoice("tile." + p.Id, QuickTileKind.DashboardTile, p.Name, "tile",
                PinId: p.Id, PinName: p.Name, Symbol: p.Symbol))
            .ToList();
    }

    /// Classic 3 groups (`Chats`, `Work`, `Pages`), kept compatible with existing callers/tests.
    public static IReadOnlyList<(string Header, IReadOnlyList<QuickActionChoice> Rows)> Groups(
        IReadOnlyList<QuickActionChoice> pages, string words = "", IReadOnlySet<QuickTileKind>? runs = null)
    {
        var query = words.Trim();
        bool Keep(QuickActionChoice c) => (runs == null || runs.Contains(c.Kind))
            && (query.Length == 0 || c.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || c.Detail.Contains(query, StringComparison.OrdinalIgnoreCase));
        var groups = new List<(string, IReadOnlyList<QuickActionChoice>)>();
        foreach (var (header, rows) in new[] { ("Chats", Chats), ("Work", Work), ("Pages", pages) })
        {
            var kept = rows.Where(Keep).ToList();
            if (kept.Count > 0) groups.Add((header, kept));
        }
        return groups;
    }

    /// Full expanded 7 groups matching `QuickActionAddView` (`Chats`, `Work`, `Dashboard Tiles`, `Live Widgets`,
    /// `Smart Actions & Shortcuts`, `Pages`, `Organize`), filtered by search `words` and supported `runs`.
    public static IReadOnlyList<(string Header, IReadOnlyList<QuickActionChoice> Rows)> AllGroups(
        IReadOnlyList<QuickActionChoice> pages,
        IReadOnlyList<QuickActionChoice>? dashboardTiles = null,
        string words = "",
        IReadOnlySet<QuickTileKind>? runs = null)
    {
        var query = words.Trim();
        bool Keep(QuickActionChoice c) => (runs == null || runs.Contains(c.Kind))
            && (query.Length == 0 || c.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || c.Detail.Contains(query, StringComparison.OrdinalIgnoreCase));
        var groups = new List<(string, IReadOnlyList<QuickActionChoice>)>();
        var sections = new (string Header, IReadOnlyList<QuickActionChoice> Rows)[]
        {
            ("Chats", Chats),
            ("Work", Work),
            ("Dashboard Tiles", dashboardTiles ?? []),
            ("Live Widgets", LiveWidgets),
            ("Smart Actions & Shortcuts", Shortcuts),
            ("Pages", pages),
            ("Organize", Organize),
        };
        foreach (var (header, rows) in sections)
        {
            var kept = rows.Where(Keep).ToList();
            if (kept.Count > 0) groups.Add((header, kept));
        }
        return groups;
    }

    /// "No actions or pages match “words”."
    public static string NoMatch(string words) => $"No actions or pages match “{words}”.";

    /// The new tile this choice starts Set Up with (matching `QuickActionChoice.newTile()`).
    public QuickTile NewTile()
    {
        var tile = QuickTile.Create(Kind);
        if (PinId != null)
            tile = tile with { Pin = PinId, PinName = PinName ?? Title, Name = PinName ?? Title, Symbol = Symbol ?? tile.Symbol };
        if (PageId != null)
            tile = tile with { Page = PageId, PageName = PageTitle, Name = PageTitle ?? tile.Name };
        if (Kind is QuickTileKind.NewChat or QuickTileKind.QuickAsk) tile = tile with { Flag = true };
        if (Kind is QuickTileKind.Send or QuickTileKind.Prompt) tile = tile with { Flag = false };
        if (Kind == QuickTileKind.Tasks)
            tile = tile with { TaskView = "today", TaskViewName = "Today", Name = "Today", Wide = true };
        if (Kind == QuickTileKind.Goal)
            tile = tile with { Wide = true };
        if (Kind is QuickTileKind.NeedsYou or QuickTileKind.BotCard or QuickTileKind.Kanban or QuickTileKind.Usage or QuickTileKind.JobCard)
            tile = tile with { Wide = true };
        if (Kind == QuickTileKind.Usage) tile = tile with { Days = 7 };
        if (Kind == QuickTileKind.SlashCommand) tile = tile with { Command = "/status", Name = "/status" };
        if (Kind == QuickTileKind.DashboardPage) tile = tile with { DashboardPageId = "main", DashboardPageName = "Main", Name = "Main" };
        if (Kind == QuickTileKind.Routine) tile = tile with { Name = "Morning Routine", Steps = [] };
        if (Kind == QuickTileKind.Section) tile = tile with { Name = "My Section" };
        return tile;
    }
}

/// Set Up's rules (`QuickActionDraft.canSave` / `finished`): when Add / Save is on, and the tile as saved.
public static class QuickTileDraft
{
    public static bool CanSave(QuickTile tile)
    {
        if (string.IsNullOrWhiteSpace(tile.Name) || tile.Known is not { } kind) return false;
        if (kind.NeedsBot() && string.IsNullOrEmpty(tile.Bot)) return false;
        if (kind is QuickTileKind.Send or QuickTileKind.Prompt && string.IsNullOrWhiteSpace(tile.Message)) return false;
        if (kind == QuickTileKind.SlashCommand && string.IsNullOrWhiteSpace(tile.Command)) return false;
        if (kind == QuickTileKind.RunJob && string.IsNullOrEmpty(tile.Job)) return false;
        if (kind == QuickTileKind.Page && string.IsNullOrEmpty(tile.Page)) return false;
        if (kind == QuickTileKind.DashboardTile && string.IsNullOrEmpty(tile.Pin)) return false;
        if (kind == QuickTileKind.Goal && string.IsNullOrEmpty(tile.GoalId)) return false;
        if (kind == QuickTileKind.GroupChat && string.IsNullOrEmpty(tile.RoomKey)) return false;
        if (kind == QuickTileKind.ChatSession && string.IsNullOrEmpty(tile.SessionId)) return false;
        if (kind == QuickTileKind.FilesFolder && string.IsNullOrWhiteSpace(tile.FolderPath)) return false;
        if (kind == QuickTileKind.Link && QuickTileRoute.NormalizedUrl(tile.Url) == null) return false;
        if (kind == QuickTileKind.Routine && (tile.Steps == null || tile.Steps.Count == 0)) return false;
        return true;
    }

    /// The name trimmed, the words without surrounding space (none: no words), command normalized with leading `/`.
    public static QuickTile Finished(QuickTile tile)
    {
        var words = tile.Message?.Trim();
        var cmd = tile.Command?.Trim();
        if (!string.IsNullOrEmpty(cmd) && !cmd.StartsWith('/')) cmd = "/" + cmd;
        var url = tile.Url?.Trim();
        var folder = tile.FolderPath?.Trim();
        return tile with
        {
            Name = tile.Name.Trim(),
            Message = string.IsNullOrEmpty(words) ? null : words,
            Command = string.IsNullOrEmpty(cmd) ? null : cmd,
            Url = string.IsNullOrEmpty(url) ? null : url,
            FolderPath = string.IsNullOrEmpty(folder) ? null : folder,
        };
    }
}
