using System.Globalization;
using System.Text;
using Hermes.Core.Settings;

namespace Hermes.Core.BotPages;

/// More search, the command palette (HermesKit/Pages/More/MoreSearch.swift): what the search finds, grouped Go To, Bots,
/// Sessions, Settings, Actions. Pure: the caller hands in what is on show right now and gets rows back. On the Mac it
/// is also what Open Quickly shows (App/Mac/MacOpenQuickly.swift); on Windows the sidebar's search (Ctrl+K) uses it.
public static class MoreSearch
{
    public enum Kind { GoTo, Bots, Sessions, Settings, Actions }

    public static string Title(Kind k) => k switch
    {
        Kind.GoTo => "Go To",
        Kind.Bots => "Bots",
        Kind.Sessions => "Sessions",
        Kind.Settings => "Settings",
        _ => "Actions",
    };

    /// `Id` is unique within its group. `Detail`: "Settings › Chat", "Bot", a session's bot and time.
    public sealed record Item(string Id, string Title, string Detail = "", IReadOnlyList<string>? Keywords = null, string? Glyph = null)
    {
        public IReadOnlyList<string> Words => Keywords ?? [];
    }

    public sealed record Group(Kind Kind, IReadOnlyList<Item> Rows, int Total)
    {
        /// Sessions offers "Show All N" when more matched than are shown.
        public string? ShowAll => Kind == Kind.Sessions && Total > Rows.Count ? $"Show All {Total}" : null;
    }

    public const int Limit = 6;
    public const string Placeholder = "Search Sessions, Pages and Actions";
    public const string FieldPlaceholder = "Sessions, Pages and Actions";

    /// The web's extra words for More's pages, by place id.
    public static readonly IReadOnlyDictionary<string, string[]> PageKeywords = new Dictionary<string, string[]>
    {
        ["files"] = ["files", "browse", "folder", "documents"],
        ["favorites"] = ["favorites", "favourites", "starred", "shortcuts", "pinned pages", "quick access"],
        ["review"] = ["review", "changes", "diff", "git"],
        ["command-center"] = ["command center", "system", "status", "maintenance"],
        ["usage"] = ["usage", "tokens", "cost"],
        ["passwords"] = ["passwords", "logins", "cards", "addresses", "keys", "vault", "keychain", "1password", "bitwarden"],
        ["composio"] = ["composio", "connect apps", "api key", "gmail", "slack", "apps"],
        ["webhooks"] = ["webhooks", "hooks", "triggers"],
        ["import-sessions"] = ["import", "claude", "codex", "conversation", "sessions"],
    };

    /// Each More page's own search words (App/Pages/More/Kit/MorePages.swift `pages[].keywords`).
    public static readonly IReadOnlyDictionary<string, string[]> MorePageWords = new Dictionary<string, string[]>
    {
        ["profiles"] = ["profiles", "soul", "bots"],
        ["messaging"] = ["telegram", "discord", "slack", "platforms", "pairing"],
        ["files"] = ["files", "browse", "folder", "documents"],
        ["review"] = ["review", "changes", "diff", "git"],
        ["tasks"] = ["tasks", "to do", "todo", "reminders", "checklist", "list"],
        ["terminal"] = ["terminal", "shell", "command line", "console", "ssh", "bash", "zsh"],
        ["command-center"] = ["command center", "system", "status", "maintenance", "logs", "doctor"],
        ["usage"] = ["usage", "tokens", "cost", "spend", "analytics"],
        ["spawn-tree"] = ["subagents", "agents", "helpers", "delegation"],
        ["star-map"] = ["memory", "graph", "skills", "learning"],
        ["webhooks"] = ["webhooks", "hooks", "triggers"],
        ["import-sessions"] = ["import", "claude", "codex", "conversation", "sessions"],
    };

    /// Case and accents folded, runs of white space as one space (SettingsSearch.normalize).
    public static string Normalize(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder();
        foreach (var c in decomposed)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return string.Join(" ", sb.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant()
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }

    /// Null = no match. 0 the title starts with the query, 1 a title word starts with it, 2 it is inside the title, 3 only
    /// the keywords (or the detail) hold it. Every typed word must be found somewhere.
    public static int? Score(string query, string title, IReadOnlyList<string>? keywords = null, string detail = "")
    {
        var wanted = Normalize(query);
        var terms = wanted.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (terms.Length == 0) return null;
        var name = Normalize(title);
        var all = Normalize(string.Join(" ", new[] { title, detail }.Concat(keywords ?? [])));
        if (!terms.All(all.Contains)) return null;
        if (name.StartsWith(wanted, StringComparison.Ordinal)) return 0;
        var words = name.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (terms.All(t => words.Any(w => w.StartsWith(t, StringComparison.Ordinal)))) return 1;
        if (terms.All(name.Contains)) return 2;
        return 3;
    }

    /// Matching rows best first; rows of one score keep the order they came in. Duplicate ids are dropped.
    public static IReadOnlyList<Item> Rank(IEnumerable<Item> items, string query)
    {
        var seen = new HashSet<string>();
        return [.. items.Select((item, index) => (item, index))
            .Where(x => seen.Add(x.item.Id))
            .Select(x => (x.item, x.index, score: Score(query, x.item.Title, x.item.Words, x.item.Detail)))
            .Where(x => x.score != null)
            .OrderBy(x => x.score).ThenBy(x => x.index)
            .Select(x => x.item)];
    }

    /// `pages`: every place on show. `settings`: the Settings index (`SettingsShown`), found as Settings' own search finds
    /// it — pages first, then the index's order, one row per label and place, at most `Limit` (MoreSearch.swift:104-109:
    /// `SettingsSearch.results`, not More's scores, and not by the "Settings ›" of a row's detail). `allSessions`: after
    /// "Show All N". An empty query has no results.
    public static IReadOnlyList<Group> Results(string query, IEnumerable<Item> pages, IEnumerable<Item> bots, IEnumerable<Item> sessions,
        IEnumerable<SettingsSearchEntry> settings, IEnumerable<Item> actions, bool allSessions = false)
    {
        if (Normalize(query).Length == 0) return [];
        var groups = new List<Group>();
        void Add(Kind kind, IEnumerable<Item> items, int cap = Limit)
        {
            var ranked = Rank(items, query);
            if (ranked.Count > 0) groups.Add(new Group(kind, [.. ranked.Take(cap)], ranked.Count));
        }
        Add(Kind.GoTo, pages.Select(p => p with
        {
            Keywords = [.. p.Words, .. PageKeywords.TryGetValue(p.Id, out var extra) ? extra : []],
        }));
        Add(Kind.Bots, bots);
        Add(Kind.Sessions, sessions, allSessions ? int.MaxValue : Limit);
        var found = SettingsSearch.Results(query, settings, Limit);
        if (found.Count > 0) groups.Add(new Group(Kind.Settings, [.. found.Select(SettingsItem)], found.Count));
        Add(Kind.Actions, actions);
        return groups;
    }

    /// A Settings result as a row: its label, "Settings › <context>" ("Settings" for a page with none), its entry id.
    public static Item SettingsItem(SettingsSearchEntry e) =>
        new(e.Id, e.Label, e.Context.Length == 0 ? "Settings" : "Settings › " + e.Context);

    /// What the Settings group searches (MoreSearchUI.swift:242-245): the index without its file actions (`.action`, About's
    /// Export / Import / Reset buttons). The Mac also drops Kanban Tab before a board is known and the rows
    /// `SettingsRootModel.searchRowShown` hides (Thinking Drive, New Chat Project); the Windows index has none of them.
    public static IReadOnlyList<SettingsSearchEntry> SettingsShown(IEnumerable<SettingsSearchEntry> index) =>
        [.. index.Where(e => SettingsSearch.ActionId(e.Target) == null)];

    /// Where the mark starts: the row whose name is exactly what was typed, wherever its group sits, else the first row.
    public static (int Section, int Row) StartRow(IReadOnlyList<Group> groups, string query)
    {
        var wanted = Normalize(query);
        for (var s = 0; s < groups.Count; s++)
            for (var r = 0; r < groups[s].Rows.Count; r++)
                if (Normalize(groups[s].Rows[r].Title) == wanted) return (s, r);
        return (0, 0);
    }

    /// The first row Return opens.
    public static (Kind Kind, Item Item)? First(IReadOnlyList<Group> groups) =>
        groups.FirstOrDefault(g => g.Rows.Count > 0) is { } g ? (g.Kind, g.Rows[0]) : null;

    public sealed record ActionFacts(bool Writable = true, bool Kanban = false, bool CommandCenter = false, string? Version = null);

    /// "1.2.3" from "v1.2.3+abc".
    public static string ShortVersion(string version)
    {
        var text = version.Trim();
        if (text.StartsWith('v') || text.StartsWith('V')) text = text[1..];
        var cut = text.IndexOfAny(['+', '-']);
        return cut >= 0 ? text[..cut] : text;
    }

    /// Each action shows only where its feature exists and the gateway is writable.
    public static IReadOnlyList<Item> Actions(ActionFacts facts)
    {
        var output = new List<Item>();
        if (facts.Writable)
        {
            output.Add(new("new-chat", "New Chat", Keywords: ["chat", "message", "start", "compose"], Glyph: ""));
            output.Add(new("new-bot", "New Bot", Keywords: ["bot", "profile", "create", "add"], Glyph: ""));
            if (facts.Kanban) output.Add(new("new-task", "New Kanban Task", Keywords: ["kanban", "task", "card", "add"], Glyph: ""));
            if (facts.CommandCenter)
            {
                output.Add(new("restart-gateway", "Restart Gateway", Keywords: ["restart", "reboot", "gateway"], Glyph: ""));
                var version = facts.Version is { } v && ShortVersion(v) is { Length: > 0 } s ? "Hermes " + s : "";
                output.Add(new("update-hermes", "Update Hermes", version, ["update", "upgrade", "version"], ""));
            }
        }
        output.Add(new("perf-logs", "Send Performance Logs", "Settings › About", ["performance", "logs", "diagnostics", "janky"], ""));
        return output;
    }

    /// The Bots group's detail: "Bot", or "Bot · <id>" when the name isn't the id.
    public static string BotDetail(string id, string name) => id == "default" || id == name ? "Bot" : $"Bot · {id}";

    /// A session's title for a result: "Untitled Chat" when it has none.
    public static string SessionTitle(string? title) => title?.Trim() is { Length: > 0 } t ? t : "Untitled Chat";

    /// Background runs are not offered: the Bot Chat and group rooms.
    public static bool HiddenSession(string? title) => title == "Bot Chat" || (title ?? "").StartsWith("Group: ", StringComparison.Ordinal);
}

/// The per-page search every list page shares (App/Pages/PageKit.swift `PageStates.searchMiss`, the pages' `matches`):
/// any-case containment over a row's words, and the miss state's words.
public static class ListSearch
{
    /// Rows whose words hold what was typed (trimmed, any case). An empty query keeps every row.
    public static IReadOnlyList<T> Filter<T>(IEnumerable<T> rows, string query, Func<T, IEnumerable<string?>> words)
    {
        var needle = query.Trim().ToLowerInvariant();
        if (needle.Length == 0) return [.. rows];
        return [.. rows.Where(r => words(r).Any(w => (w ?? "").ToLowerInvariant().Contains(needle)))];
    }

    public static bool IsSearching(string query) => query.Trim().Length > 0;

    /// "No Results for “words”" (UIContentUnavailableConfiguration.search's title).
    public static string MissTitle(string words) => $"No Results for “{words.Trim()}”";
    public const string MissText = "Check the spelling, or try another word.";
    public const string Placeholder = "Search";
}
