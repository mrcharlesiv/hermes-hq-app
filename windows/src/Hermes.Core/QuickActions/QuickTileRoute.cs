namespace Hermes.Core.QuickActions;

// [quick-actions] Where a Quick Actions tile's tap goes, what is missing for it, how the grid lays tiles out, what Add
// Action offers and when Set Up may save: the pure parts of HermesKit/Intents/QuickTiles.swift (QuickTileWorld,
// QuickTileRoute, QuickTileRules, QuickTileGrid) and App/QuickActions/QuickActionSetup.swift (QuickActionChoice,
// QuickActionDraft.canSave / finished) at 93f984bb1. The page (Features/QuickActions) runs a route through the
// Windows route that already does the same thing; a kind with no Windows route yet is `Unavailable` with the Mac's own
// "needs a newer version" sentence, so a tile never does something its Mac twin doesn't.

/// What is around when a tile is drawn or tapped: the CURRENT gateway's roster (profile → shown name), jobs and pages
/// (place id → title). Null: not known yet (the roster hasn't answered), which is never "missing".
public sealed record QuickTileWorld(
    IReadOnlyDictionary<string, string>? Bots = null,
    IReadOnlySet<string>? Jobs = null,
    IReadOnlyDictionary<string, string>? Pages = null);

/// Where a tap goes (QuickTileRoute): each case is the route its Shortcuts twin takes on the Mac (spec I22).
public abstract record QuickTileRoute
{
    /// NewChatRouter.open with NewChatIntent's link: the bot, its project, the first message and whether it is sent.
    public sealed record NewChat(string Bot, string? Project, string? Message, bool Send) : QuickTileRoute;
    public sealed record Talk(string Profile) : QuickTileRoute;
    public sealed record Memo(string Profile) : QuickTileRoute;
    /// The bot's own chat (OpenBotChatIntent).
    public sealed record OpenChat(string Profile) : QuickTileRoute;
    /// The bot's own chat, then the words sent as typed words are.
    public sealed record SendInChat(string Profile, string Words) : QuickTileRoute;
    /// AskBotIntent's background send, no wait.
    public sealed record SendInBackground(string Profile, string Words) : QuickTileRoute;
    /// The New Task sheet, the bot chosen when there is one.
    public sealed record NewTask(string? Bot) : QuickTileRoute;
    public sealed record RunJob(string Key, string Name) : QuickTileRoute;
    /// A page, opened as Favorites (on Windows: the sidebar's place) opens one.
    public sealed record Page(string Id) : QuickTileRoute;
    /// The Home Screen item's Search Chats (DECISION I6).
    public sealed record Search : QuickTileRoute;
    /// Not on this gateway (or not this build's): one sentence, nothing runs.
    public sealed record Unavailable(string Words) : QuickTileRoute;

    /// The page stays open and says what happened (a background tile, or one that can't run).
    public bool StaysOnPage => this is SendInBackground or RunJob or Unavailable;

    /// The route for `tile` against what the current gateway has (QuickTileRoute.make). `runs`: the kinds this build
    /// has a route for (null: all, as the Mac); any other kind is `Unavailable(QuickTileRules.NewerApp)`.
    public static QuickTileRoute Make(QuickTile tile, QuickTileWorld world, IReadOnlySet<QuickTileKind>? runs = null)
    {
        if (QuickTileRules.Missing(tile, world, runs) is { } missing) return new Unavailable(missing);
        if (tile.Known is not { } kind) return new Unavailable(QuickTileRules.NewerApp);
        var bot = tile.Bot ?? "";
        var words = string.IsNullOrWhiteSpace(tile.Message) ? null : tile.Message;
        return kind switch
        {
            QuickTileKind.NewChat => new NewChat(bot, string.IsNullOrEmpty(tile.Project) ? null : tile.Project, words, tile.Flag ?? true),
            QuickTileKind.Memo => new Memo(bot),
            QuickTileKind.Talk => new Talk(bot),
            QuickTileKind.OpenChat => new OpenChat(bot),
            QuickTileKind.Send => words == null ? new Unavailable("Add the words to send in Edit.")
                : tile.Flag == true ? new SendInChat(bot, words) : new SendInBackground(bot, words),
            QuickTileKind.AddTask => new NewTask(string.IsNullOrEmpty(tile.Bot) ? null : tile.Bot),
            QuickTileKind.RunJob => new RunJob(tile.Job ?? "", tile.JobName ?? tile.Name),
            QuickTileKind.Page => new Page(tile.Page ?? ""),
            _ => new Search(),
        };
    }
}

public static class QuickTileRules
{
    public const string NewerApp = "This action needs a newer version of Hermes HQ.";

    /// The kinds the Windows app runs today, each through a route it already has: New Chat (Ctrl+N's new chat, the
    /// first message left in the box), Open a Chat (the bot's sidebar row), Send a Message (the bot's chat and its
    /// send, QuickTileRun), Add Task (Tasks), Run Job (Jobs' Run Now, QuickTileRun), a page (its sidebar place) and
    /// Search Chats (Open Quickly). Voice Memo and Talk have no Windows route yet.
    public static readonly IReadOnlySet<QuickTileKind> Windows = new HashSet<QuickTileKind>
    {
        QuickTileKind.NewChat, QuickTileKind.OpenChat, QuickTileKind.Send, QuickTileKind.AddTask, QuickTileKind.RunJob,
        QuickTileKind.Page, QuickTileKind.Search,
    };

    /// One sentence when the tile's bot, job or page isn't on this gateway (null: it is, or that isn't known yet).
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
        if (kind == QuickTileKind.Page)
        {
            if (string.IsNullOrEmpty(tile.Page)) return "Choose a page for this action in Edit.";
            if (world.Pages is { } pages && !pages.ContainsKey(tile.Page)) return $"{tile.PageName ?? tile.Name} isn’t on this gateway.";
        }
        return null;
    }

    /// QuickActionsRouter.missingBot / missingPage: what a foreground route says when its target went away on the way.
    public static string MissingBot(QuickTile tile) => $"{tile.BotName ?? tile.Bot ?? "That bot"} isn’t on this gateway.";
    public static string MissingPage(QuickTile tile) => $"{tile.PageName ?? tile.Name} isn’t on this gateway.";
}

/// The grid: two columns, a Wide tile across both; one full-width column when stacked (QuickTileGrid).
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

/// One row of Add Action (QuickActionChoice): an action kind or a page.
public sealed record QuickActionChoice(string Id, QuickTileKind Kind, string Title, string Detail, string? PageId = null, string? PageTitle = null)
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

    private static QuickActionChoice Of(QuickTileKind kind, string title, string detail) => new(kind.Raw(), kind, title, detail);

    /// Every page (place id, title, group), then Search Chats. Quick Actions itself is never one.
    public static IReadOnlyList<QuickActionChoice> Pages(IEnumerable<(string Id, string Title, string Group)> pages)
    {
        var seen = new HashSet<string> { QuickTileStore.RowID };
        var out_ = pages.Where(p => seen.Add(p.Id))
            .Select(p => new QuickActionChoice("page." + p.Id, QuickTileKind.Page, p.Title, p.Group, p.Id, p.Title)).ToList();
        out_.Add(new QuickActionChoice(QuickTileKind.Search.Raw(), QuickTileKind.Search, "Search Chats", "page"));
        return out_;
    }

    /// The groups Add Action lists (Chats, Work, Pages), keeping only kinds `runs` has (null: all) and rows whose
    /// title or detail holds `words` (case-insensitive); an empty group is left out.
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

    /// "No actions or pages match “words”."
    public static string NoMatch(string words) => $"No actions or pages match “{words}”.";

    /// The new tile this choice starts Set Up with (a page tile is named for its page).
    public QuickTile NewTile()
    {
        var tile = QuickTile.Create(Kind);
        if (PageId != null) tile = tile with { Page = PageId, PageName = PageTitle, Name = PageTitle ?? tile.Name };
        return tile;
    }
}

/// Set Up's rules (QuickActionDraft): when Add / Save is on, and the tile as saved.
public static class QuickTileDraft
{
    public static bool CanSave(QuickTile tile)
    {
        if (string.IsNullOrWhiteSpace(tile.Name) || tile.Known is not { } kind) return false;
        if (kind.NeedsBot() && string.IsNullOrEmpty(tile.Bot)) return false;
        if (kind == QuickTileKind.Send && string.IsNullOrWhiteSpace(tile.Message)) return false;
        if (kind == QuickTileKind.RunJob && string.IsNullOrEmpty(tile.Job)) return false;
        if (kind == QuickTileKind.Page && string.IsNullOrEmpty(tile.Page)) return false;
        return true;
    }

    /// The name trimmed, the words without surrounding space (none: no words).
    public static QuickTile Finished(QuickTile tile)
    {
        var words = tile.Message?.Trim();
        return tile with { Name = tile.Name.Trim(), Message = string.IsNullOrEmpty(words) ? null : words };
    }
}
