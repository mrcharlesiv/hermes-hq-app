using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using Hermes.Core.Settings;

namespace Hermes.Core.Shell;

/// Next / Previous Chat's order (HermesKit/Layout/KeyRules.swift `ChatWalk`, 93f984bb1): one step along the list the
/// chat on show was opened from, top to bottom as it shows now. No wraparound: past the last row (or before the first)
/// there is nothing, and the menu's item is off. With nothing current in the list, Next opens the first row and
/// Previous is off.
public static class ChatWalk
{
    public static string? Target(IReadOnlyList<string> order, string? current, bool forward)
    {
        if (order.Count == 0) return null;
        var index = current == null ? -1 : IndexOf(order, current);
        if (index < 0) return forward ? order[0] : null;
        var next = index + (forward ? 1 : -1);
        return next >= 0 && next < order.Count ? order[next] : null;
    }

    private static int IndexOf(IReadOnlyList<string> order, string key)
    {
        for (var i = 0; i < order.Count; i++) if (order[i] == key) return i;
        return -1;
    }

    /// A Sessions row's key: profile and stored id, as `KeyCommands.walkList` makes it (`profile + "\u{1F}" + id`).
    public static string SessionKey(string profile, string storedId) => profile + "\u001F" + storedId;

    public static (string Profile, string StoredId)? SplitSessionKey(string key)
    {
        var at = key.IndexOf('\u001F');
        return at < 0 ? null : (key[..at], key[(at + 1)..]);
    }

    /// The bots as the list shows them, top to bottom (`BotsViewController.paneOrder`): the Pinned group first, then each
    /// section in order, Unassigned, and Hidden only with Show Hidden Bots (`BotList.SidebarGroups`); a collapsed group's
    /// bots are left out, as a collapsed section's rows are. Each bot once.
    public static List<string> BotOrder(IReadOnlyList<BotListSection> groups, IReadOnlyCollection<string> collapsed)
    {
        var seen = new HashSet<string>();
        var order = new List<string>();
        foreach (var g in groups)
        {
            if (collapsed.Contains(g.Key)) continue;
            foreach (var b in g.Bots) if (seen.Add(b.Id)) order.Add(b.Id);
        }
        return order;
    }

    /// The Sessions list's chat rows, top to bottom (`SessionsViewController.paneOrder`): the groups as the page draws
    /// them (the page header's group has no rows), each chat once.
    public static List<string> SessionOrder(IReadOnlyList<SessionGroup> groups)
    {
        var seen = new HashSet<string>();
        var order = new List<string>();
        foreach (var g in groups)
        {
            if (g.Id == SessionListPipeline.PageId) continue;
            foreach (var s in g.Sessions)
            {
                var key = SessionKey(s.Profile, s.Id);
                if (seen.Add(key)) order.Add(key);
            }
        }
        return order;
    }
}

/// Which list Next / Previous Chat walk (`KeyCommands.walkList`): the Bots list (a bot's own chat, or the chats opened
/// from the bots), the Sessions list (a chat opened from Sessions, or Sessions on show), or none (another page on show;
/// the Mac's Jobs and Tasks walks are not on Windows yet).
public enum WalkList { None, Bots, Sessions }

/// What the walk decides on. `PlaceId`: the place on show when `Pane` is `Place`. `FromSessions`: the chat on show was
/// opened from Sessions (its tab on the Mac). `Covered`: a sheet or dialog is up. `FieldHasText`: the caret is in a field
/// holding words (⌘↑ / ⌘↓ are then the caret's, `validate`).
public sealed record WalkFacts(OpenPane Pane, string? Profile, string? StoredId, string? PlaceId, bool FromSessions,
    IReadOnlyList<string> Bots, IReadOnlyList<string> Sessions, bool Covered = false, bool FieldHasText = false);

/// View › Next Chat (⌘↓) and Previous Chat (⌘↑) as App/Root/KeyCommands.swift (93f984bb1) decides them: `walkList`,
/// `walkTarget`, `validate`'s nextChat / previousChat case and `hqNextChat` / `hqPreviousChat`.
public static class WalkKeys
{
    public const string NextTitle = "Next Chat", PreviousTitle = "Previous Chat";

    public static WalkList ListFor(WalkFacts f) => f.Pane switch
    {
        OpenPane.Chat when f.FromSessions => WalkList.Sessions,
        OpenPane.Chat or OpenPane.BotChat or OpenPane.Nothing => WalkList.Bots,
        OpenPane.Place when f.PlaceId == "sessions" => WalkList.Sessions,
        _ => WalkList.None,
    };

    /// The row on show in the walked list: a bot's own chat's bot (a chat that is not one has no row in the Bots list),
    /// or the Sessions row of the chat on show.
    public static string? Current(WalkFacts f) => ListFor(f) switch
    {
        WalkList.Bots when f.Pane == OpenPane.BotChat => string.IsNullOrEmpty(f.Profile) ? "default" : f.Profile,
        WalkList.Sessions when f.Pane == OpenPane.Chat && f.Profile != null && f.StoredId != null => ChatWalk.SessionKey(f.Profile, f.StoredId),
        _ => null,
    };

    /// The row the key opens, or null when its item is off (nothing to walk, at an end, a sheet up, a field's words).
    public static string? Target(WalkFacts f, bool forward)
    {
        if (f.Covered || f.FieldHasText) return null;
        var order = ListFor(f) switch { WalkList.Bots => f.Bots, WalkList.Sessions => f.Sessions, _ => [] };
        return ChatWalk.Target(order, Current(f), forward);
    }

    public static bool Enabled(WalkFacts f, bool forward) => Target(f, forward) != null;
}

/// View's ⌘1…⌘9 (`KeyCommands.tabIndex`, HermesKit/Layout/KeyRules.swift `TabShortcut`, Mac branch): the numbers go to
/// the sidebar's places in order (Bots, Sessions, Jobs, Artifacts as Settings › Tabs has them, then the Tools), More
/// taking none; with more than nine places ⌘9 picks the last, as it picks Safari's last tab. A number with no place is
/// hidden and does nothing.
public static class PlaceKeys
{
    public const int Keys = 9;
    /// The Mac's Bots place: on Windows the bots are the sidebar itself, so it has no row of its own (as on the Mac with
    /// the bots in the sidebar), but it keeps ⌘1.
    public const string Bots = "bots", BotsTitle = "Bots";

    /// The place Ctrl+(`index` + 1) picks, as an index into `places`; null when none.
    public static int? Place(int index, int places)
    {
        if (index < 0 || index >= Keys || index >= places) return null;
        if (index == Keys - 1 && places > Keys) return places - 1;
        return index;
    }

    /// The places in the Mac's numbered order: Bots, the places shown in the sidebar, then the Tools.
    public static List<string> Numbered(IEnumerable<string> shown, IEnumerable<string> tools) =>
        [Bots, .. shown.Where(id => id != Bots), .. tools.Where(id => id != Bots)];

    /// The number whose key picks the place at `index`, if one does (the sidebar's tooltips, the sheet's rows).
    public static int? Number(int index, int places)
    {
        for (var n = 0; n < Keys; n++) if (Place(n, places) == index) return n + 1;
        return null;
    }
}

/// What View › Refresh (⌘R) refreshes (`hqRefresh`, `refreshTarget`): the page on show when it has a refresh of its own;
/// with a chat or nothing on show, the list (the sidebar's bots and chats); a page with none leaves the item off
/// (Mac UI check K9). Windows also takes F5.
public enum RefreshTarget { None, Page, Lists }

public static class RefreshKeys
{
    public static RefreshTarget Target(OpenPane pane, bool pageRefreshes, bool covered = false) =>
        covered ? RefreshTarget.None
        : pane == OpenPane.Place ? (pageRefreshes ? RefreshTarget.Page : RefreshTarget.None)
        : RefreshTarget.Lists;
}

/// Help › Hermes HQ Support (App/Mac/MacWindow.swift `trimMenus`, `supportPage`): the website's support page, as About ›
/// Support opens it.
public static class HelpMenu
{
    public const string SupportTitle = "Hermes HQ Support";
    public const string SupportUrl = SettingsWords.SupportUrl;
}
