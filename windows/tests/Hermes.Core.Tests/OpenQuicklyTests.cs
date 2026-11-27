using Hermes.Core.BotPages;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Open Quickly (App/Mac/MacOpenQuickly.swift, MoreSearchUI.recent/results at 93f984bb1): the latest chats before typing,
/// More's search after, the mark, the empty notes and where each result opens.
public class OpenQuicklyTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 21, 15, 0, 0, TimeSpan.Zero);

    private static OpenQuickly.Chat Chat(string profile, string id, string title, int hoursAgo) =>
        new(profile, id, title, hoursAgo < 0 ? null : Now.AddHours(-hoursAgo), "Otto");

    private static MoreSearch.Item I(string id, string title, string detail = "") => new(id, title, detail);

    /// Pages, bots, sessions, settings and actions as `MoreSearch.Results` ranks them (the panel's typed groups).
    private static IReadOnlyList<MoreSearch.Group> Results(string q) => MoreSearch.Results(q,
        pages: [I("kanban", "Kanban", "Sidebar"), I("usage", "Usage", "Sidebar"), I("themes", "Themes Gallery", "Sidebar")],
        bots: [I("otto", "Otto", "Bot"), I("herald", "Herald", "Bot")],
        sessions: [I("otto|s1", "Trip notes", "Otto · Today"), I("ivy|s2", "Otto’s birthday", "Ivy · Today")],
        settings: [SettingsSearch.Index.Single(e => e.Id == "app:theme")],
        actions: MoreSearch.Actions(new MoreSearch.ActionFacts(Kanban: true, CommandCenter: true)));

    private static OpenQuicklyState State(params OpenQuickly.Chat[] chats) =>
        new(Results, () => OpenQuickly.Recent(chats));

    [Fact]
    public void TheSwiftWords()
    {
        Assert.Equal("Open Quickly", OpenQuickly.FieldName);
        Assert.Equal("Search Sessions, Pages and Actions", OpenQuickly.Placeholder);
        Assert.Equal("Recent", OpenQuickly.RecentTitle);
        Assert.Equal("No recent chats", OpenQuickly.NoRecent);
        Assert.Equal("No results for \u201Cxyz\u201D", OpenQuickly.NoResults("xyz"));
        Assert.Equal(8, OpenQuickly.RecentLimit);
    }

    /// Before typing: the latest chats first, at most eight, background runs (Bot Chat, "Group: …") left out, untitled
    /// ones named "Untitled Chat", one Sessions group headed "Recent".
    [Fact]
    public void BeforeTypingTheLatestChatsShowUnderRecent()
    {
        var chats = new List<OpenQuickly.Chat>
        {
            Chat("otto", "old", "Old", 50), Chat("otto", "bc", "Bot Chat", 0), Chat("ivy", "g", "Group: team", 0),
            Chat("ivy", "none", "  ", 3), Chat("otto", "never", "Never", -1),
        };
        for (var i = 0; i < 9; i++) chats.Add(Chat("wren", $"w{i}", $"Chat {i}", 10 + i));
        var state = State([.. chats]);
        state.Type("");
        var group = Assert.Single(state.Groups);
        Assert.Equal(MoreSearch.Kind.Sessions, group.Kind);
        Assert.Equal(["Untitled Chat", "Chat 0", "Chat 1", "Chat 2", "Chat 3", "Chat 4", "Chat 5", "Chat 6"], group.Rows.Select(r => r.Title));
        Assert.Equal("ivy|none", group.Rows[0].Id);
        Assert.Equal("Recent", state.Header(0));
        Assert.Null(state.EmptyNote);
        Assert.Equal((0, 0), state.Marked);
    }

    [Fact]
    public void NoChatsSaysNoRecentChats()
    {
        var state = State(Chat("otto", "bc", "Bot Chat", 1));
        state.Type("");
        Assert.Empty(state.Groups);
        Assert.Equal("No recent chats", state.EmptyNote);
        Assert.Null(state.MarkedRow);
    }

    /// Typing: More's groups in their order (Go To, Bots, Sessions, Settings, Actions), each headed by its own title.
    [Fact]
    public void TypingShowsMoreSearchGroupsInOrder()
    {
        var state = State(Chat("otto", "s1", "Trip notes", 1));
        state.Type("otto");
        Assert.Equal([MoreSearch.Kind.Bots, MoreSearch.Kind.Sessions], state.Groups.Select(g => g.Kind));
        Assert.Equal(["Bots", "Sessions"], new[] { state.Header(0), state.Header(1) });
        state.Type("new");
        Assert.Equal("Actions", state.Header(0));
        Assert.Equal(["New Chat", "New Bot", "New Kanban Task"], state.Groups[0].Rows.Select(r => r.Title));
    }

    /// Only spaces typed: the recent chats show, but headed by their kind (the Mac heads "Recent" only for an empty field).
    [Fact]
    public void SpacesShowRecentUnderSessions()
    {
        var state = State(Chat("otto", "s1", "Trip notes", 1));
        state.Type("   ");
        Assert.Equal("Trip notes", Assert.Single(Assert.Single(state.Groups).Rows).Title);
        Assert.Equal("Sessions", state.Header(0));
    }

    [Fact]
    public void NoMatchSaysNoResultsForTheTrimmedQuery()
    {
        var state = State();
        state.Type("  zzqx ");
        Assert.Empty(state.Groups);
        Assert.Equal("No results for \u201Czzqx\u201D", state.EmptyNote);
    }

    /// The mark starts on the row named exactly what was typed, wherever its group sits, else the first row.
    [Fact]
    public void TheMarkStartsOnAnExactName()
    {
        var state = State();
        state.Type("usage");
        Assert.Equal((0, 0), state.Marked);
        state.Type("Herald");
        Assert.Equal("Herald", state.MarkedRow?.Item.Title);
        state.Type("theme");   // Go To: Themes Gallery; Settings: Theme
        Assert.Equal([MoreSearch.Kind.GoTo, MoreSearch.Kind.Settings], state.Groups.Select(g => g.Kind));
        Assert.Equal((1, 0), state.Marked);
    }

    /// ↑ and ↓ move through every row across the groups and stop at the ends.
    [Fact]
    public void ArrowsMoveAcrossGroupsAndStopAtTheEnds()
    {
        var state = State();
        state.Type("otto");   // Bots: Otto; Sessions: Otto’s birthday (its title), Trip notes (its bot)
        Assert.False(state.Move(-1));
        Assert.True(state.Move(1));
        Assert.Equal((1, 0), state.Marked);
        Assert.True(state.Move(1));
        Assert.Equal((1, 1), state.Marked);
        Assert.False(state.Move(1));
        Assert.Equal((1, 1), state.Marked);
        Assert.True(state.Move(-1));
        Assert.True(state.Move(-1));
        Assert.Equal((0, 0), state.Marked);
        state.Mark(1, 1);   // the pointer moved over a row
        Assert.Equal("Trip notes", state.MarkedRow?.Item.Title);
        state.Mark(5, 0);   // not a row: the mark stays
        Assert.Equal((1, 1), state.Marked);
    }

    [Fact]
    public void ArrowsOnNoRowsDoNothing()
    {
        var state = State();
        state.Type("zzqx");
        Assert.False(state.Move(1));
        Assert.Null(state.MarkedRow);
    }

    /// Where each result opens (MacOpenQuickly.openOnOwnTab, runAction): a chat as its sidebar row, a bot's chat, a page as
    /// its place, a setting in Settings, actions where their own key or button runs them.
    [Fact]
    public void EachKindOpensWhereItsOwnRowWould()
    {
        Assert.Equal(new OpenQuickly.OpenChat("otto", "s1", "Trip notes"), OpenQuickly.Route(MoreSearch.Kind.Sessions, I("otto|s1", "Trip notes")));
        Assert.Equal(new OpenQuickly.OpenBot("otto"), OpenQuickly.Route(MoreSearch.Kind.Bots, I("otto", "Otto")));
        Assert.Equal(new OpenQuickly.OpenPlace("kanban"), OpenQuickly.Route(MoreSearch.Kind.GoTo, I("kanban", "Kanban")));
        Assert.Equal(new OpenQuickly.OpenSettings(), OpenQuickly.Route(MoreSearch.Kind.GoTo, I("settings", "Settings")));
        Assert.Equal(new OpenQuickly.OpenSettings("theme"), OpenQuickly.Route(MoreSearch.Kind.Settings, I("app:theme", "Theme")));
        Assert.Equal(new OpenQuickly.NewChat(), OpenQuickly.Route(MoreSearch.Kind.Actions, I("new-chat", "New Chat")));
        Assert.Equal(new OpenQuickly.NewBot(), OpenQuickly.Route(MoreSearch.Kind.Actions, I("new-bot", "New Bot")));
        Assert.Equal(new OpenQuickly.OpenPlace("kanban", "new-task"), OpenQuickly.Route(MoreSearch.Kind.Actions, I("new-task", "New Kanban Task")));
        Assert.Equal(new OpenQuickly.OpenPlace("command-center"), OpenQuickly.Route(MoreSearch.Kind.Actions, I("restart-gateway", "Restart Gateway")));
        Assert.Equal(new OpenQuickly.OpenPlace("command-center"), OpenQuickly.Route(MoreSearch.Kind.Actions, I("update-hermes", "Update Hermes")));
        Assert.Equal(new OpenQuickly.OpenSettings("about"), OpenQuickly.Route(MoreSearch.Kind.Actions, I("perf-logs", "Send Performance Logs")));
        Assert.Null(OpenQuickly.Route(MoreSearch.Kind.Sessions, I("broken", "No bar")));
        Assert.Null(OpenQuickly.Route(MoreSearch.Kind.Actions, I("unknown", "Unknown")));
    }

    /// Rows are named for UI Automation by kind (the Swift rawValue) and id; Narrator reads the title, then the detail.
    [Fact]
    public void RowsCarryAutomationIdsAndSpokenNames()
    {
        Assert.Equal("openquickly.goTo.kanban", OpenQuickly.RowAutomationId(MoreSearch.Kind.GoTo, I("kanban", "Kanban")));
        Assert.Equal("openquickly.sessions.otto|s1", OpenQuickly.RowAutomationId(MoreSearch.Kind.Sessions, I("otto|s1", "Trip")));
        Assert.Equal(["goTo", "bots", "sessions", "settings", "actions"], Enum.GetValues<MoreSearch.Kind>().Select(OpenQuickly.KindId));
        Assert.Equal("Trip notes, Otto · Today", OpenQuickly.SpokenName(I("otto|s1", "Trip notes", "Otto · Today")));
        Assert.Equal("New Chat", OpenQuickly.SpokenName(I("new-chat", "New Chat")));
    }

    /// A chat's detail: its bot, then "Today", "Yesterday" or the medium date.
    [Fact]
    public void ChatDetail()
    {
        var today = new DateTime(2026, 11, 21);
        Assert.Equal("Otto", OpenQuickly.ChatDetail("Otto", null, today));
        Assert.Equal("Otto · Today", OpenQuickly.ChatDetail("Otto", new DateTime(2026, 11, 21, 9, 0, 0), today));
        Assert.Equal("Otto · Yesterday", OpenQuickly.ChatDetail("Otto", new DateTime(2026, 11, 20, 23, 0, 0), today));
        Assert.Equal("Otto · Nov 2, 2026", OpenQuickly.ChatDetail("Otto", new DateTime(2026, 11, 2), today, System.Globalization.CultureInfo.InvariantCulture));
    }

    /// The panel stands a tenth of the way down (at least 72), 640 wide; the list is as tall as its rows (+6), at most
    /// what the window leaves (120…460), and 80 for an empty note.
    [Fact]
    public void PanelGeometry()
    {
        Assert.Equal(493, OpenQuickly.PanelWidth);
        Assert.Equal(72, OpenQuickly.TopRoom(500));
        Assert.Equal(90, OpenQuickly.TopRoom(900));
        Assert.Equal(80, OpenQuickly.ListHeight(900, 300, empty: true));
        Assert.Equal(306, OpenQuickly.ListHeight(900, 300, empty: false));
        Assert.Equal(460, OpenQuickly.ListHeight(1200, 900, empty: false));
        Assert.Equal(120, OpenQuickly.ListHeight(200, 900, empty: false));
        Assert.Equal(440, OpenQuickly.PanelWidthIn(520));
        Assert.Equal(493, OpenQuickly.PanelWidthIn(1400));
    }

    /// Ctrl+K opens the panel (the Mac's ⌘K, KeyCommands.hqOpenQuickly), not the sidebar's field.
    [Fact]
    public void CtrlKOpensThePanel()
    {
        var root = RepoRoot();
        var shell = File.ReadAllText(Path.Combine(root, "windows", "src", "HermesHQ.Windows", "Pages", "ShellPage.xaml.cs"));
        Assert.Contains("AddShortcut(ShellKeys.OpenQuickly, ShowOpenQuickly);", shell);
        Assert.Contains("OpenQuicklyPanel.Show(", shell);
        Assert.Equal(new KeyChord("K", Ctrl: true), ShellKeys.OpenQuickly);
        var panel = File.ReadAllText(Path.Combine(root, "windows", "src", "HermesHQ.Windows", "Features", "OpenQuickly", "OpenQuicklyPanel.cs"));
        foreach (var id in new[] { "\"openquickly\"", "\"openquickly.field\"", "\"openquickly.results\"", "\"openquickly.empty\"", "OpenQuickly.RowAutomationId(" })
            Assert.Contains(id, panel);
        foreach (var key in new[] { "VirtualKey.Up", "VirtualKey.Down", "VirtualKey.Enter", "VirtualKey.Escape" })
            Assert.Contains(key, panel);
    }

    /// The words above are literals in the Swift source (full checkout only; the Windows CI mirror has no Swift).
    [Fact]
    public void WordsAreTheSwiftStrings()
    {
        var file = Path.Combine(RepoRoot(), "App", "Mac", "MacOpenQuickly.swift");
        if (!Directory.Exists(Path.Combine(RepoRoot(), "App"))) return;
        var swift = File.ReadAllText(file);
        foreach (var s in new[] { "\"No recent chats\"", "\"No results for \\u{201C}", "\"Recent\"", "\"Open Quickly\"", "max(72, (height * 0.1).rounded())",
                     "equalToConstant: 640", "min(max(view.bounds.height - chrome, 100), 460)", "groups.isEmpty ? 80" })
            Assert.Contains(s, swift);
        var ui = File.ReadAllText(Path.Combine(RepoRoot(), "App", "Pages", "More", "MoreSearchUI.swift"));
        Assert.Contains("func recent(limit: Int = 8)", ui);
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "windows", "src"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repo root not found");
    }
}
