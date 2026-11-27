using System.Globalization;
using Hermes.Core.BotPages;
using Hermes.Core.Settings;

namespace Hermes.Core.Shell;

/// Open Quickly (App/Mac/MacOpenQuickly.swift at 93f984bb1): a panel near the window's top, over the whole window. The
/// latest chats show before anything is typed (`MoreSearchUI.recent`); typing searches what More's search finds
/// (`MoreSearch.Results`: Go To, Bots, Sessions, Settings, Actions). ↑ and ↓ move the mark, Enter opens the marked row,
/// Esc or a click outside closes. A result opens where its own row, key or button opens it (`openOnOwnTab`, `runAction`).
/// On Windows Ctrl+K (the Mac's ⌘K) opens it, and so does the sidebar's Search button (`SidebarSearch`), as on the Mac.
public static class OpenQuickly
{
    /// The field's accessibility label.
    public const string FieldName = "Open Quickly";
    public const string Placeholder = MoreSearch.Placeholder;
    /// The heading over the latest chats, while nothing is typed.
    public const string RecentTitle = "Recent";
    public const string NoRecent = "No recent chats";
    public static string NoResults(string query) => $"No results for \u201C{query}\u201D";
    public const int RecentLimit = 8;

    /// A chat as the panel offers it. `Detail`: "<bot> · Today" (`ChatDetail`).
    public sealed record Chat(string Profile, string Id, string Title, DateTimeOffset? LastActive, string Detail);

    /// What shows before typing: the latest chats first (no date counts as the oldest), background runs left out, at most
    /// `limit`, as one Sessions group; none at all is no group.
    public static IReadOnlyList<MoreSearch.Group> Recent(IEnumerable<Chat> chats, int limit = RecentLimit)
    {
        var latest = chats.Where(c => !MoreSearch.HiddenSession(c.Title))
            .OrderByDescending(c => c.LastActive ?? DateTimeOffset.MinValue)
            .Take(limit)
            .Select(c => new MoreSearch.Item(c.Profile + "|" + c.Id, MoreSearch.SessionTitle(c.Title), c.Detail))
            .ToList();
        return latest.Count == 0 ? [] : [new MoreSearch.Group(MoreSearch.Kind.Sessions, latest, latest.Count)];
    }

    /// "<bot> · Today", "· Yesterday" or the medium date ("Nov 2, 2026"); the bot alone with no date.
    public static string ChatDetail(string bot, DateTime? localWhen, DateTime today, CultureInfo? culture = null)
    {
        if (localWhen is not { } when) return bot;
        var day = when.Date;
        var text = day == today.Date ? "Today" : day == today.Date.AddDays(-1) ? "Yesterday"
            : day.ToString("MMM d, yyyy", culture ?? CultureInfo.CurrentCulture);
        return bot + " · " + text;
    }

    /// The kind as the Mac names it in a row's identifier (`MoreSearch.Kind.rawValue`).
    public static string KindId(MoreSearch.Kind kind) => kind switch
    {
        MoreSearch.Kind.GoTo => "goTo",
        MoreSearch.Kind.Bots => "bots",
        MoreSearch.Kind.Sessions => "sessions",
        MoreSearch.Kind.Settings => "settings",
        _ => "actions",
    };

    /// A row's UI Automation id (the Mac's "open-quickly.<kind>.<id>").
    public static string RowAutomationId(MoreSearch.Kind kind, MoreSearch.Item item) => $"openquickly.{KindId(kind)}.{item.Id}";

    /// What Narrator reads for a row: its title, then its detail when it has one (the subtitle cell's two lines).
    public static string SpokenName(MoreSearch.Item item) => item.Detail.Length == 0 ? item.Title : $"{item.Title}, {item.Detail}";

    // ------------------------------------------------------------------ the panel's size

    // Mac Catalyst 640 pt × 0.77 = 493 DIPs (matches measured Mac 1258/1259 492.46 px panel width).
    public const double PanelWidth = 493;

    /// 493 DIPs wide, at most the window less 80.
    public static double PanelWidthIn(double windowWidth) => Math.Max(0, Math.Min(PanelWidth, windowWidth - 80));

    /// The panel's top: a tenth of the way down the window, at least 72.
    public static double TopRoom(double windowHeight) => Math.Max(72, Math.Round(windowHeight * 0.1, MidpointRounding.AwayFromZero));

    /// The list's height: its rows plus 6, at most what the window leaves (120…460); 80 for the empty note.
    public static double ListHeight(double windowHeight, double contentHeight, bool empty)
    {
        if (empty) return 80;
        var room = Math.Min(Math.Max(windowHeight - TopRoom(windowHeight) - 80, 120), 460);
        return Math.Min(room, contentHeight + 6);
    }

    // ------------------------------------------------------------------ where a result opens

    public abstract record Target;
    /// A chat, as its sidebar row opens it.
    public sealed record OpenChat(string Profile, string Id, string Title) : Target;
    /// A bot's chat, as its sidebar row opens it.
    public sealed record OpenBot(string Id) : Target;
    /// A page or Tool in the main window, with what it opens to.
    public sealed record OpenPlace(string Id, string? Argument = null) : Target;
    /// The separate Settings window; leave the main window's chat or page in place.
    public sealed record OpenSettings(string? Argument = null) : Target;
    /// File › New Chat (Ctrl+N): its bot, the open one.
    public sealed record NewChat : Target;
    /// The sidebar's New Bot.
    public sealed record NewBot : Target;

    /// MacOpenQuickly.openOnOwnTab and runAction on Windows: a chat and a bot open as their sidebar rows, a page as its
    /// place, a setting in Settings, New Chat as Ctrl+N, New Bot as the sidebar's row, New Kanban Task on the board,
    /// Restart Gateway and Update Hermes on Status & Maintenance where both are, Send Performance Logs in Settings ›
    /// About. Null: nothing to open (an id the panel can't read).
    public static Target? Route(MoreSearch.Kind kind, MoreSearch.Item item)
    {
        switch (kind)
        {
            case MoreSearch.Kind.Sessions:
                var cut = item.Id.IndexOf('|');
                return cut <= 0 ? null : new OpenChat(item.Id[..cut], item.Id[(cut + 1)..], item.Title);
            case MoreSearch.Kind.Bots:
                return new OpenBot(item.Id);
            case MoreSearch.Kind.GoTo:
                return item.Id == "settings" ? new OpenSettings() : new OpenPlace(item.Id);
            case MoreSearch.Kind.Settings:
                // Its entry's target ("row:ui-scale", "about:detailed-log"…), as Settings' own search opens it
                // (MacOpenQuickly.swift:450-461 looks the id up in `SettingsSearch.index()`).
                return SettingsSearch.Index.FirstOrDefault(e => e.Id == item.Id) is { } entry ? new OpenSettings(entry.Target) : null;
            default:
                return item.Id switch
                {
                    "new-chat" => new NewChat(),
                    "new-bot" => new NewBot(),
                    "new-task" => new OpenPlace("kanban", "new-task"),
                    "restart-gateway" or "update-hermes" => new OpenPlace("command-center"),
                    "perf-logs" => new OpenSettings("about"),
                    _ => null,
                };
        }
    }
}

/// The panel's state: what was typed, the groups on show, the marked row. `results` gives More's groups for a trimmed,
/// non-empty query; `recent` the latest chats.
public sealed class OpenQuicklyState(Func<string, IReadOnlyList<MoreSearch.Group>> results, Func<IReadOnlyList<MoreSearch.Group>> recent)
{
    /// The field's text as typed (headings follow it untrimmed: "Recent" only for an empty field, as the Mac's).
    public string Text { get; private set; } = "";
    public IReadOnlyList<MoreSearch.Group> Groups { get; private set; } = [];
    public (int Section, int Row) Marked { get; private set; }

    /// The field changed: the latest chats for nothing typed, else what the words find; the mark on an exact name, else
    /// the first row.
    public void Type(string text)
    {
        Text = text;
        var query = text.Trim();
        Groups = query.Length == 0 ? recent() : results(query);
        Marked = MoreSearch.StartRow(Groups, query);
    }

    /// A section's heading.
    public string Header(int section) => Text.Length == 0 ? OpenQuickly.RecentTitle : MoreSearch.Title(Groups[section].Kind);

    /// The note in place of the list when nothing shows; null while there are rows.
    public string? EmptyNote => Groups.Count > 0 ? null : Text.Trim() is { Length: > 0 } q ? OpenQuickly.NoResults(q) : OpenQuickly.NoRecent;

    /// The marked row, or null when there is none.
    public (MoreSearch.Kind Kind, MoreSearch.Item Item)? MarkedRow =>
        Marked.Section < Groups.Count && Marked.Row < Groups[Marked.Section].Rows.Count
            ? (Groups[Marked.Section].Kind, Groups[Marked.Section].Rows[Marked.Row]) : null;

    /// ↑ (-1) or ↓ (+1) through every row across the groups, stopping at the ends. False: the mark didn't move.
    public bool Move(int step)
    {
        var flat = Groups.SelectMany((g, s) => g.Rows.Select((_, r) => (s, r))).ToList();
        var at = flat.IndexOf(Marked);
        if (at < 0) return false;
        var next = flat[Math.Clamp(at + step, 0, flat.Count - 1)];
        if (next == Marked) return false;
        Marked = next;
        return true;
    }

    /// The pointer moved over a row (or a click picked it): the mark follows. A place with no row leaves it.
    public void Mark(int section, int row)
    {
        if (section >= 0 && section < Groups.Count && row >= 0 && row < Groups[section].Rows.Count) Marked = (section, row);
    }
}
