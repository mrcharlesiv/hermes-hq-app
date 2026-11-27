using System.Globalization;
using Hermes.Core.BotPages;
using Hermes.Core.Model;
using Hermes.Core.Settings;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;

namespace HermesHQ.Features.BotPages;

/// More search behind the sidebar's search field (Ctrl+K), as the Mac's Open Quickly shows it (App/Mac/MacOpenQuickly.swift,
/// App/Pages/More/MoreSearchUI.swift `results(for:)`): Go To (every sidebar place, with each page's own search words),
/// Bots, Sessions, Settings and Actions, ranked by `MoreSearch`. A result opens where its own key or button would.
public static class MoreSearchHook
{
    private static IReadOnlyList<SessionRow> _sessions = [];
    private static DateTimeOffset _sessionsRead = DateTimeOffset.MinValue;
    private static bool _reading;

    public static IReadOnlyList<ShellSearchHit> Results(string query, IReadOnlyList<Bot> bots)
    {
        RefreshSessions();
        var trimmed = query.Trim();
        var pages = Places.All.Select(p => new MoreSearch.Item(p.Id, p.Title, "Sidebar",
            [.. p.Keywords, .. MoreSearch.MorePageWords.TryGetValue(p.Id, out var w) ? w : []], p.Glyph));
        var choices = BotChoiceStore.Choices(bots);
        var botItems = choices.Select(b => new MoreSearch.Item(b.Name, b.DisplayName, MoreSearch.BotDetail(b.Name, b.DisplayName),
            [b.Name, b.Description ?? ""]));
        var sessions = _sessions.Where(s => !MoreSearch.HiddenSession(s.Title)).Select(s => new MoreSearch.Item(
            s.Profile + "|" + s.Id, MoreSearch.SessionTitle(s.Title), SessionDetail(s, bots), [s.Preview ?? ""]));
        var facts = new MoreSearch.ActionFacts(Writable: true, Kanban: Ported("kanban"), CommandCenter: Ported("command-center"));
        var groups = MoreSearch.Results(trimmed, pages, botItems, sessions, MoreSearch.SettingsShown(SettingsSearch.Index), MoreSearch.Actions(facts));
        var start = MoreSearch.StartRow(groups, trimmed);
        var hits = new List<ShellSearchHit>();
        for (var g = 0; g < groups.Count; g++)
            for (var r = 0; r < groups[g].Rows.Count; r++)
            {
                var (kind, item) = (groups[g].Kind, groups[g].Rows[r]);
                hits.Add(new ShellSearchHit(item.Title, item.Detail.Length > 0 ? item.Detail : MoreSearch.Title(kind),
                    () => Open(kind, item, bots), g == start.Section && r == start.Row));
            }
        return hits;
    }

    private static bool Ported(string place) => Places.All.Any(p => p.Id == place && p.Page != typeof(PlaceholderPage));

    private static void RefreshSessions()
    {
        if (_reading || DateTimeOffset.UtcNow - _sessionsRead < TimeSpan.FromSeconds(30) || AppState.Client is not { } client) return;
        _reading = true;
        _ = Task.Run(async () =>
        {
            try
            {
                var sidebar = await client.SessionsAsync();
                _sessions = sidebar.Recents.Rows;
                _sessionsRead = DateTimeOffset.UtcNow;
            }
            catch (Exception) { _sessionsRead = DateTimeOffset.UtcNow - TimeSpan.FromSeconds(20); }
            finally { _reading = false; }
        });
    }

    /// "<bot> · Today" (the medium date with relative words).
    private static string SessionDetail(SessionRow s, IReadOnlyList<Bot> bots)
    {
        var bot = bots.FirstOrDefault(b => b.Name == s.Profile)?.DisplayName ?? ProfileName.Readable(s.Profile);
        if (s.LastActive is not { } when) return bot;
        var day = when.ToLocalTime().Date;
        var today = DateTime.Today;
        var text = day == today ? "Today" : day == today.AddDays(-1) ? "Yesterday" : day.ToString("MMM d, yyyy", CultureInfo.CurrentCulture);
        return bot + " · " + text;
    }

    private static void Open(MoreSearch.Kind kind, MoreSearch.Item item, IReadOnlyList<Bot> bots)
    {
        // The desktop sidebar and Ctrl+K use the same Settings window and preserve the open chat.
        if (Hermes.Core.Shell.OpenQuickly.Route(kind, item) is Hermes.Core.Shell.OpenQuickly.OpenSettings settings)
        {
            SettingsWindows.Show(settings.Argument);
            return;
        }
        switch (kind)
        {
            case MoreSearch.Kind.GoTo:
                Navigator.Open(item.Id);
                break;
            case MoreSearch.Kind.Bots:
                if (bots.FirstOrDefault(b => b.Name == item.Id) is { } bot) Navigator.Go(new BotChatDestination(bot));
                break;
            case MoreSearch.Kind.Sessions:
                var cut = item.Id.IndexOf('|');
                Navigator.Go(new ChatDestination(item.Id[..cut], item.Id[(cut + 1)..], item.Title));
                break;
            case MoreSearch.Kind.Actions:
                switch (item.Id)
                {
                    case "new-chat": Navigator.Open("sessions", "new-chat"); break;
                    case "new-bot": Navigator.Open("profiles", "new"); break;
                    case "new-task": Navigator.Open("kanban", "new-task"); break;
                    case "restart-gateway" or "update-hermes": Navigator.Open("command-center", item.Id); break;
                }
                break;
        }
    }
}
