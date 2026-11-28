using Hermes.Core.Sessions;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

/// Unit tests for `SessionStripRules` (`App/Chat/SessionStrip.swift`, `App/Mac/BotChatsPanel.swift`, `643492b44`):
/// preference persistence, visibility rules (excluding tasks and group rooms), filtering (archived/cron/tool/canonical),
/// settled tab ordering, dismissed tab removal, inspector Chats grouping (`Active`/`Pinned`/`Today`/`Earlier`),
/// quiet row detail rules, and project subtitle resolution.
public sealed class SessionStripAndChatsPanelTests
{
    private sealed class MemPrefs : IPreferences
    {
        public Dictionary<string, string> Map { get; } = [];
        public string? Get(string key) => Map.GetValueOrDefault(key);
        public void Set(string key, string? value)
        {
            if (value == null) Map.Remove(key);
            else Map[key] = value;
        }
    }

    private static readonly DateTimeOffset Now = new(2026, 11, 28, 15, 0, 0, TimeSpan.Zero);

    private static SessionSummary Chat(
        string id,
        string profile = "ivy",
        string? title = null,
        DateTimeOffset? lastActive = null,
        string? source = "desktop",
        bool archived = false,
        bool running = false,
        bool unread = false,
        bool pinned = false,
        SessionStatus? status = null,
        string? preview = null,
        string? step = null) => new()
    {
        Id = id,
        Profile = profile,
        Title = title ?? $"Chat {id}",
        LastActive = lastActive ?? Now.AddMinutes(-10),
        Source = source,
        Archived = archived,
        IsRunning = running,
        Unread = unread,
        Pinned = pinned,
        Status = status ?? (running ? SessionStatus.Working : unread ? SessionStatus.Unread : SessionStatus.Idle),
        Preview = preview,
        Step = step,
    };

    [Fact]
    public void PreferenceKeyDefaultsOnPersistsAndFiresChanged()
    {
        Assert.Equal("hqn.sessionStrip", SessionStripRules.PrefKey);

        var prevStore = SessionStripRules.Store;
        var prefs = new MemPrefs();
        var changes = 0;
        void OnChanged() => changes++;

        SessionStripRules.Store = prefs;
        SessionStripRules.Changed += OnChanged;
        try
        {
            Assert.True(SessionStripRules.IsEnabled);
            Assert.Null(prefs.Get(SessionStripRules.PrefKey));

            SessionStripRules.IsEnabled = false;
            Assert.False(SessionStripRules.IsEnabled);
            Assert.Equal("false", prefs.Get(SessionStripRules.PrefKey));
            Assert.Equal(1, changes);

            // Setting the same value again does not fire Changed.
            SessionStripRules.IsEnabled = false;
            Assert.Equal(1, changes);

            SessionStripRules.IsEnabled = true;
            Assert.True(SessionStripRules.IsEnabled);
            Assert.Null(prefs.Get(SessionStripRules.PrefKey));
            Assert.Equal(2, changes);
        }
        finally
        {
            SessionStripRules.Changed -= OnChanged;
            SessionStripRules.Store = prevStore;
        }
    }

    [Fact]
    public void ShouldShowExcludesTasksGroupRoomsAndNonChatViewsAndRespectsPreference()
    {
        Assert.True(SessionStripRules.ShouldShow(isBotOrSessionChat: true, isTaskChat: false, isGroupRoom: false, enabled: true));
        Assert.False(SessionStripRules.ShouldShow(isBotOrSessionChat: true, isTaskChat: true, isGroupRoom: false, enabled: true));
        Assert.False(SessionStripRules.ShouldShow(isBotOrSessionChat: true, isTaskChat: false, isGroupRoom: true, enabled: true));
        Assert.False(SessionStripRules.ShouldShow(isBotOrSessionChat: false, isTaskChat: false, isGroupRoom: false, enabled: true));
        Assert.False(SessionStripRules.ShouldShow(isBotOrSessionChat: true, isTaskChat: false, isGroupRoom: false, enabled: false));

        Assert.True(SessionStripRules.IsTaskChatTitle("Task: Ship Windows build"));
        Assert.False(SessionStripRules.IsTaskChatTitle("Ship Windows build"));
        Assert.False(SessionStripRules.IsTaskChatTitle(null));

        var prevStore = SessionStripRules.Store;
        var prefs = new MemPrefs();
        SessionStripRules.Store = prefs;
        try
        {
            Assert.True(SessionStripRules.ShouldShow(true, false, false));
            SessionStripRules.IsEnabled = false;
            Assert.False(SessionStripRules.ShouldShow(true, false, false));
            SessionStripRules.IsEnabled = true;
            Assert.True(SessionStripRules.ShouldShow(true, false, false));
        }
        finally
        {
            SessionStripRules.Store = prevStore;
        }
    }

    [Fact]
    public void TabsForBotFiltersArchivedCronToolOtherBotsAndCanonicalAndPinsBotChatFirst()
    {
        SessionSummary[] sessions =
        [
            Chat("canon", running: true),
            Chat("arch", archived: true, pinned: true),
            Chat("cron1", source: "cron", unread: true),
            Chat("tool1", source: "tool", running: true),
            Chat("other-bot", profile: "otto", running: true),
            Chat("idle-not-open", lastActive: Now.AddMinutes(-1)),
            Chat("pinned1", pinned: true, lastActive: Now.AddMinutes(-20)),
            Chat("unread1", unread: true, lastActive: Now.AddMinutes(-5), preview: "Line 1\nLine 2"),
            Chat("working1", running: true, lastActive: Now.AddMinutes(-30), step: "Running tests…"),
            Chat("current-idle", lastActive: Now.AddDays(-3)),
        ];

        var tabs = SessionStripRules.TabsForBot(
            "ivy",
            sessions,
            currentSessionId: "current-idle",
            dismissedIds: null,
            botName: "Ivy",
            botCanonicalSessionId: "canon");

        Assert.Equal(["canon", "working1", "unread1", "pinned1", "current-idle"], tabs.Select(t => t.Id));
        Assert.True(tabs[0].IsBotChat);
        Assert.Equal("Ivy", tabs[0].Title);
        Assert.False(tabs[0].Current);

        Assert.True(tabs[1].Working);
        Assert.Equal("Running tests…", tabs[1].Detail);

        Assert.True(tabs[2].Unread);
        Assert.Equal("Line 1 Line 2", tabs[2].Detail);

        Assert.True(tabs[3].Pinned);
        Assert.True(tabs[4].Current);
        Assert.False(tabs[4].Unread);
    }

    [Fact]
    public void SettledOrderKeepsExistingPositionsAndPrependsFreshWorkingThenUnread()
    {
        SessionSummary[] sessions =
        [
            Chat("a", pinned: true, lastActive: Now.AddMinutes(-40)),
            Chat("b", pinned: true, lastActive: Now.AddMinutes(-30)),
            Chat("fresh-unread", unread: true, lastActive: Now.AddMinutes(-2)),
            Chat("fresh-working", running: true, lastActive: Now.AddMinutes(-5)),
            Chat("fresh-pinned", pinned: true, lastActive: Now.AddMinutes(-1)),
        ];

        var tabs = SessionStripRules.TabsForBot(
            "ivy",
            sessions,
            currentSessionId: null,
            dismissedIds: null,
            botName: "Ivy",
            previousOrder: ["b", "a"]);

        // Bot Chat pinned first; fresh tabs arrive ahead of prior tabs (working -> unread -> rest); prior order [b, a] is preserved.
        Assert.Equal(["", "fresh-working", "fresh-unread", "fresh-pinned", "b", "a"], tabs.Select(t => t.Id));
        Assert.True(tabs[0].IsBotChat);
        Assert.True(tabs[0].Current);
    }

    [Fact]
    public void DismissedIdsRemovesTabUnlessCurrentlyOpen()
    {
        SessionSummary[] sessions =
        [
            Chat("kept-1", lastActive: Now.AddMinutes(-5)),
            Chat("kept-2", lastActive: Now.AddMinutes(-10)),
            Chat("cur", lastActive: Now.AddMinutes(-15)),
        ];
        var kept = new HashSet<string> { "kept-1", "kept-2" };
        var dismissed = new HashSet<string> { "kept-1", "cur" };

        var tabs = SessionStripRules.TabsForBot(
            "ivy",
            sessions,
            currentSessionId: "cur",
            dismissedIds: dismissed,
            botName: "Ivy",
            keptIds: kept);

        // "kept-1" is dismissed and omitted; "kept-2" remains; "cur" stays because it is the active chat on screen.
        Assert.Equal(["", "kept-2", "cur"], tabs.Select(t => t.Id));

        var (bot, scrolling) = SessionStripRules.Split(tabs);
        Assert.NotNull(bot);
        Assert.Equal(["kept-2", "cur"], scrolling.Select(s => s.Id));
        Assert.True(SessionStripRules.DrawsStrip(bot, scrolling, otherCount: 0, onBotChat: false));
        Assert.False(SessionStripRules.DrawsStrip(bot, [], otherCount: 0, onBotChat: true));
    }

    [Fact]
    public void GroupsForBotBucketsActivePinnedTodayAndEarlierInOrder()
    {
        SessionSummary[] sessions =
        [
            Chat("canon", running: true),
            Chat("archived", archived: true, lastActive: Now.AddMinutes(-1)),
            Chat("cron", source: "cron", lastActive: Now.AddMinutes(-1)),
            Chat("tool", source: "tool", lastActive: Now.AddMinutes(-1)),
            Chat("other-bot", profile: "otto", lastActive: Now.AddMinutes(-1)),

            Chat("unread-newer", unread: true, lastActive: Now.AddMinutes(-2)),
            Chat("working-older", running: true, lastActive: Now.AddMinutes(-20)),
            Chat("pinned-old", pinned: true, lastActive: Now.AddDays(-5)),
            Chat("pinned-new", pinned: true, lastActive: Now.AddHours(-1)),
            Chat("today-1", lastActive: Now.AddHours(-2)),
            Chat("today-2", lastActive: Now.AddHours(-4)),
            Chat("earlier-1", lastActive: Now.AddDays(-1)),
            Chat("earlier-2", lastActive: Now.AddDays(-10)),
        ];

        var groups = SessionStripRules.GroupsForBot("ivy", sessions, Now, botCanonicalSessionId: "canon");

        Assert.Equal(["Active", "Pinned", "Today", "Earlier"], groups.Select(g => g.Title));
        // Working always precedes Unread inside Active.
        Assert.Equal(["working-older", "unread-newer"], groups[0].Chats.Select(c => c.Id));
        Assert.Equal(["pinned-new", "pinned-old"], groups[1].Chats.Select(c => c.Id));
        Assert.Equal(["today-1", "today-2"], groups[2].Chats.Select(c => c.Id));
        Assert.Equal(["earlier-1", "earlier-2"], groups[3].Chats.Select(c => c.Id));

        // Empty groups are omitted.
        var onlyEarlier = SessionStripRules.GroupsForBot("ivy", [Chat("old", lastActive: Now.AddDays(-3))], Now);
        Assert.Equal(["Earlier"], onlyEarlier.Select(g => g.Title));
    }

    [Fact]
    public void PanelDetailShowsSecondLineOnlyForWorkingOrUnreadRows()
    {
        var working = Chat("w", running: true, step: "Editing files…", preview: "Ignored while working");
        var unread = Chat("u", unread: true, preview: "First line\nSecond line");
        var quiet = Chat("q", preview: "Old message");

        Assert.Equal("Editing files…", SessionStripRules.PanelDetail(working, current: false));
        Assert.Equal("First line Second line", SessionStripRules.PanelDetail(unread, current: false));
        Assert.Equal("", SessionStripRules.PanelDetail(unread, current: true));
        Assert.Equal("", SessionStripRules.PanelDetail(quiet, current: false));
    }

    [Fact]
    public void ResolveProjectBadgeHandlesProjectLookAndExcludesBotTaskGroupAndHome()
    {
        var project = new SessionProject("p1", "acme-api", "/work/acme-api", ["/work/acme-api"]);
        var byProfile = new Dictionary<string, List<SessionProject>> { ["ivy"] = [project] };
        var entries = SessionProjects.Entries(byProfile, ["ivy"]);

        var badge = SessionStripRules.ResolveProjectBadge(
            "ivy",
            "/work/acme-api/src",
            byProfile,
            entries,
            isBotChat: false,
            lookFor: _ => ("🚀", "blue"));

        Assert.Equal(new ChatProjectBadge("acme-api", "🚀", "blue"), badge);

        // No custom look -> folder glyph fallback (Emoji == null).
        var plain = SessionStripRules.ResolveProjectBadge("ivy", "/work/acme-api", byProfile, entries, isBotChat: false);
        Assert.Equal(new ChatProjectBadge("acme-api", null, null), plain);

        // Bot chat, task chat, group room, and Home chats return null.
        Assert.Null(SessionStripRules.ResolveProjectBadge("ivy", "/work/acme-api", byProfile, entries, isBotChat: true));
        Assert.Null(SessionStripRules.ResolveProjectBadge("ivy", "/work/acme-api", byProfile, entries, isBotChat: false, isTaskChat: true));
        Assert.Null(SessionStripRules.ResolveProjectBadge("ivy", "/work/acme-api", byProfile, entries, isBotChat: false, isGroupRoom: true));
        Assert.Null(SessionStripRules.ResolveProjectBadge("ivy", "/elsewhere/random", byProfile, entries, isBotChat: false));
    }
}
