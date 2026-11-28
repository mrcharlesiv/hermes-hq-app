using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Wave 2C tests:
/// - `WorkspaceTabList` (open-chats-only, stable spatial order, no eviction cap, neighbor selection on close,
///   close others/right/all, `CycledIndex`, `ClosingGuardId`, per-gateway persistence).
/// - `WorkspaceHistory` (Back/Forward stack with cap 40).
/// - `BotChatsStylePrefs` (all 9 styles, labels, MarksRows, persistence & Changed notification).
/// - `BotChatsUnder.ShowsPin` (solo vs multi) and manual per-bot shortcuts.
public class WorkspaceTabsAndBranchTests
{
    private static WorkspaceTabRecord Session(string profile, string id, string title) =>
        new(WorkspaceTabKind.Session, profile, id, title);

    private static WorkspaceTabRecord BotTab(string id, string title) =>
        new(WorkspaceTabKind.Bot, id, id, title);

    private static SessionSummary Summary(string id, string profile = "ivy", bool pinned = false, bool archived = false, long at = 1) =>
        new()
        {
            Id = id,
            Profile = profile,
            Title = id,
            Pinned = pinned,
            Archived = archived,
            LastActive = DateTimeOffset.FromUnixTimeSeconds(at),
        };

    // ------------------------------------------------------------------ WorkspaceTabList

    [Fact]
    public void TabIdsDistinguishSessionsAndBots()
    {
        Assert.Equal("session:default:s1", Session("default", "s1", "Trip").TabId);
        Assert.Equal("bot:otto", BotTab("otto", "Otto").TabId);
    }

    [Fact]
    public void OpenAppendsWithoutCapAndUpdatesTitleInPlaceWithoutMoving()
    {
        var list = new WorkspaceTabList();
        for (var i = 0; i < 50; i++)
            Assert.True(list.Open(Session("default", $"s{i}", $"Chat {i}")));
        Assert.Equal(50, list.Tabs.Count);
        Assert.Equal("s0", list.Tabs[0].Id);
        Assert.Equal("s49", list.Tabs[49].Id);

        // Re-opening with identical title changes nothing and keeps position
        Assert.False(list.Open(Session("default", "s5", "Chat 5")));
        Assert.Equal("s5", list.Tabs[5].Id);

        // Re-opening with new title updates in place without moving to the right
        Assert.True(list.Open(Session("default", "s5", "Renamed 5")));
        Assert.Equal("Renamed 5", list.Tabs[5].Title);
        Assert.Equal(50, list.Tabs.Count);

        // UpdateTitle ignores empty and unchanged titles
        Assert.False(list.UpdateTitle("session:default:s5", ""));
        Assert.False(list.UpdateTitle("session:default:s5", "Renamed 5"));
        Assert.True(list.UpdateTitle("session:default:s5", "Final 5"));
        Assert.Equal("Final 5", list.Tabs[5].Title);
    }

    [Fact]
    public void CloseSelectsRightThenLeftThenNullAndLeavesInactiveCloseUntouched()
    {
        var a = BotTab("otto", "Otto");
        var b = Session("otto", "s1", "Plan");
        var c = Session("otto", "s2", "Build");
        var list = new WorkspaceTabList([a, b, c]);

        // Closing an inactive tab returns null nextActive
        var inactive = list.Close(c.TabId, activeTabId: a.TabId);
        Assert.True(inactive.Removed);
        Assert.Null(inactive.NextActive);
        Assert.Equal([a.TabId, b.TabId], list.Tabs.Select(t => t.TabId));

        // Re-add c so we have [a, b, c]; closing active middle tab selects right neighbor (c)
        list.Open(c);
        var middle = list.Close(b.TabId, activeTabId: b.TabId);
        Assert.True(middle.Removed);
        Assert.Equal(c, middle.NextActive);
        Assert.Equal([a.TabId, c.TabId], list.Tabs.Select(t => t.TabId));

        // Closing active rightmost tab selects left neighbor (a)
        var rightmost = list.Close(c.TabId, activeTabId: c.TabId);
        Assert.True(rightmost.Removed);
        Assert.Equal(a, rightmost.NextActive);

        // Closing the last active tab falls back to null ("No Chat Open")
        var last = list.Close(a.TabId, activeTabId: a.TabId);
        Assert.True(last.Removed);
        Assert.Null(last.NextActive);
        Assert.Empty(list.Tabs);

        // Closing a missing tab returns Removed = false
        var missing = list.Close("session:x:y", activeTabId: null);
        Assert.False(missing.Removed);
        Assert.Null(missing.NextActive);
    }

    [Fact]
    public void CloseOthersCloseToRightAndCloseAllWorkAsExpected()
    {
        var a = BotTab("a", "A");
        var b = Session("a", "1", "One");
        var c = Session("a", "2", "Two");
        var d = Session("a", "3", "Three");

        var list = new WorkspaceTabList([a, b, c, d]);
        Assert.False(list.CloseToRight(d.TabId));
        Assert.True(list.CloseToRight(b.TabId));
        Assert.Equal([a.TabId, b.TabId], list.Tabs.Select(t => t.TabId));

        list.Open(c);
        list.Open(d);
        Assert.True(list.CloseOthers(c.TabId));
        Assert.Equal([c.TabId], list.Tabs.Select(t => t.TabId));
        Assert.False(list.CloseOthers(c.TabId));

        Assert.True(list.CloseAll());
        Assert.Empty(list.Tabs);
        Assert.False(list.CloseAll());
    }

    [Fact]
    public void CycledIndexWrapsBothWaysAndStartsFromEndsWhenNoTabIsActive()
    {
        Assert.Null(WorkspaceTabList.CycledIndex(0, null, 1));
        Assert.Null(WorkspaceTabList.CycledIndex(3, 1, 0));
        Assert.Null(WorkspaceTabList.CycledIndex(1, 0, 1));
        Assert.Null(WorkspaceTabList.CycledIndex(1, 0, -1));

        // No active tab (viewing a sidebar page with no top tab): forward -> first, backward -> last
        Assert.Equal(0, WorkspaceTabList.CycledIndex(3, null, 1));
        Assert.Equal(2, WorkspaceTabList.CycledIndex(3, null, -1));
        Assert.Equal(0, WorkspaceTabList.CycledIndex(1, null, 1));

        // Forward and backward wrapping
        Assert.Equal(1, WorkspaceTabList.CycledIndex(3, 0, 1));
        Assert.Equal(2, WorkspaceTabList.CycledIndex(3, 1, 1));
        Assert.Equal(0, WorkspaceTabList.CycledIndex(3, 2, 1));
        Assert.Equal(2, WorkspaceTabList.CycledIndex(3, 0, -1));
        Assert.Equal(0, WorkspaceTabList.CycledIndex(3, 1, -1));
        Assert.Equal(1, WorkspaceTabList.CycledIndex(3, 2, -1));

        // ClosingGuardId suppresses only when active tab itself was removed
        Assert.Equal("bot:a", WorkspaceTabList.ClosingGuardId(new HashSet<string> { "bot:a", "bot:b" }, "bot:a"));
        Assert.Null(WorkspaceTabList.ClosingGuardId(new HashSet<string> { "bot:b" }, "bot:a"));
        Assert.Null(WorkspaceTabList.ClosingGuardId(new HashSet<string> { "bot:a" }, null));
    }

    [Fact]
    public void PersistenceIsolatesGatewaysDeduplicatesAndClearsWhenEmpty()
    {
        Assert.Equal("HQMacWorkspaceTabs.default", WorkspaceTabList.StorageKey(null));
        Assert.Equal("HQMacWorkspaceTabs.default", WorkspaceTabList.StorageKey("   "));
        Assert.Equal("HQMacWorkspaceTabs.gw-1", WorkspaceTabList.StorageKey(" gw-1 "));

        var prefs = new MemoryPrefs();
        var gw1 = new WorkspaceTabList([BotTab("otto", "Otto"), Session("otto", "s1", "Plan")]);
        var gw2 = new WorkspaceTabList([Session("ivy", "s9", "Notes")]);
        gw1.Save("gw-1", prefs);
        gw2.Save("gw-2", prefs);

        var loaded1 = WorkspaceTabList.Load("gw-1", prefs);
        var loaded2 = WorkspaceTabList.Load("gw-2", prefs);
        Assert.Equal(["bot:otto", "session:otto:s1"], loaded1.Tabs.Select(t => t.TabId));
        Assert.Equal(["Otto", "Plan"], loaded1.Tabs.Select(t => t.Title));
        Assert.Equal(["session:ivy:s9"], loaded2.Tabs.Select(t => t.TabId));

        // Saving empty clears stored preference
        loaded1.CloseAll();
        loaded1.Save("gw-1", prefs);
        Assert.Null(prefs.Get(WorkspaceTabList.StorageKey("gw-1")));
        Assert.Empty(WorkspaceTabList.Load("gw-1", prefs).Tabs);
        // Gateway 2 unaffected
        Assert.Single(WorkspaceTabList.Load("gw-2", prefs).Tabs);

        // Corrupt JSON fails gracefully to empty list
        prefs.Set(WorkspaceTabList.StorageKey("gw-bad"), "not-json");
        Assert.Empty(WorkspaceTabList.Load("gw-bad", prefs).Tabs);
    }

    // ------------------------------------------------------------------ WorkspaceHistory (cap 40)

    [Fact]
    public void HistoryNavigatesBackAndForwardTruncatesTailAndCapsAtForty()
    {
        var history = new WorkspaceHistory();
        Assert.False(history.CanGoBack);
        Assert.False(history.CanGoForward);
        Assert.Null(history.GoBack());
        Assert.Null(history.GoForward());

        var d1 = new WorkspaceBotNav("otto");
        var d2 = new WorkspaceSessionNav("otto", "s1");
        var d3 = new WorkspacePlaceNav("sessions");
        history.Record(d1);
        history.Record(d1); // consecutive duplicate collapsed
        Assert.Equal(1, history.Count);
        history.Record(d2);
        history.Record(d3);

        Assert.True(history.CanGoBack);
        Assert.False(history.CanGoForward);
        Assert.Equal(d2, history.GoBack());
        Assert.True(history.CanGoBack);
        Assert.True(history.CanGoForward);
        Assert.Equal(d1, history.GoBack());
        Assert.False(history.CanGoBack);
        Assert.Equal(d2, history.GoForward());

        // Recording a new destination after going back drops forward tail (d3)
        var d4 = new WorkspaceSessionNav("ivy", "s2");
        history.Record(d4);
        Assert.False(history.CanGoForward);
        Assert.Equal(3, history.Count);
        Assert.Equal(d4, history.Current);

        // Cap at 40 entries
        history.Clear();
        for (var i = 0; i < 55; i++)
            history.Record(new WorkspaceSessionNav("otto", $"s{i}"));
        Assert.Equal(WorkspaceHistory.MaxEntries, history.Count);
        Assert.Equal(40, history.Count);
        Assert.Equal(new WorkspaceSessionNav("otto", "s54"), history.Current);
        WorkspaceNavDestination? oldest = null;
        while (history.GoBack() is { } prev) oldest = prev;
        Assert.Equal(new WorkspaceSessionNav("otto", "s15"), oldest);
    }

    // ------------------------------------------------------------------ BotChatsStylePrefs

    [Fact]
    public void BotChatsStylePrefsCoversAllNineStylesLabelsAndPersistence()
    {
        Assert.Equal("hq.bots.chatsUnder.style", BotChatsStylePrefs.PrefKey);
        Assert.Equal(9, BotChatsStylePrefs.All.Count);
        Assert.Equal(
            [
                BotChatsStyleKind.Branch,
                BotChatsStyleKind.Arrows,
                BotChatsStyleKind.Splines,
                BotChatsStyleKind.Quill,
                BotChatsStyleKind.Dots,
                BotChatsStyleKind.Rail,
                BotChatsStyleKind.Line,
                BotChatsStyleKind.Dividers,
                BotChatsStyleKind.None,
            ],
            BotChatsStylePrefs.All);

        Assert.Equal("Curved Elbows", BotChatsStylePrefs.Label(BotChatsStyleKind.Branch));
        Assert.Equal("Swept Arrows", BotChatsStylePrefs.Label(BotChatsStyleKind.Arrows));
        Assert.Equal("Spline Fan", BotChatsStylePrefs.Label(BotChatsStyleKind.Splines));
        Assert.Equal("Tapered Quill", BotChatsStylePrefs.Label(BotChatsStyleKind.Quill));
        Assert.Equal("Metro Track", BotChatsStylePrefs.Label(BotChatsStyleKind.Dots));
        Assert.Equal("Soft Rail", BotChatsStylePrefs.Label(BotChatsStyleKind.Rail));
        Assert.Equal("Line", BotChatsStylePrefs.Label(BotChatsStyleKind.Line));
        Assert.Equal("Dividers", BotChatsStylePrefs.Label(BotChatsStyleKind.Dividers));
        Assert.Equal("No Line", BotChatsStylePrefs.Label(BotChatsStyleKind.None));

        Assert.True(BotChatsStylePrefs.MarksRows(BotChatsStyleKind.Branch));
        Assert.True(BotChatsStylePrefs.MarksRows(BotChatsStyleKind.Rail));
        Assert.False(BotChatsStylePrefs.MarksRows(BotChatsStyleKind.Line));
        Assert.False(BotChatsStylePrefs.MarksRows(BotChatsStyleKind.Dividers));
        Assert.False(BotChatsStylePrefs.MarksRows(BotChatsStyleKind.None));

        var prevStore = BotChatsStylePrefs.Store;
        var prefs = new MemoryPrefs();
        var changes = 0;
        void OnChanged() => changes++;
        BotChatsStylePrefs.Store = prefs;
        BotChatsStylePrefs.Changed += OnChanged;
        try
        {
            Assert.Equal(BotChatsStyleKind.Branch, BotChatsStylePrefs.Current);
            foreach (var style in BotChatsStylePrefs.All)
            {
                BotChatsStylePrefs.Current = style;
                Assert.Equal(style, BotChatsStylePrefs.Current);
                Assert.Equal(style, BotChatsStylePrefs.Read(prefs));
            }
            Assert.Equal(8, changes); // Branch -> Arrows -> ... -> None (8 transitions)
            BotChatsStylePrefs.Current = BotChatsStyleKind.None;
            Assert.Equal(8, changes); // setting same value does not re-fire
            BotChatsStylePrefs.Current = BotChatsStyleKind.Branch;
            Assert.Equal(9, changes);
        }
        finally
        {
            BotChatsStylePrefs.Changed -= OnChanged;
            BotChatsStylePrefs.Store = prevStore;
        }
    }

    // ------------------------------------------------------------------ BotChatsUnder.ShowsPin & Shortcuts

    [Fact]
    public void ShowsPinHidesPinForSoloSessionAndShowsForMultiple()
    {
        var pinned = Summary("p1", pinned: true);
        var plain = Summary("r1", pinned: false);

        // Solo pinned chat under a bot: pin icon suppressed
        Assert.False(BotChatsUnder.ShowsPin(pinned, [pinned]));
        Assert.False(BotChatsUnder.ShowsPin(plain, [plain]));

        // Two or more chats under a bot: pin icon shown only on pinned chat(s)
        Assert.True(BotChatsUnder.ShowsPin(pinned, [pinned, plain]));
        Assert.False(BotChatsUnder.ShowsPin(plain, [pinned, plain]));
    }

    [Fact]
    public void PickHonorsManualShortcutsEvenWhenModeIsOffAndDeduplicates()
    {
        var s1 = Summary("s1", "ivy", pinned: true, at: 10);
        var s2 = Summary("s2", "ivy", pinned: false, at: 9);
        var s3 = Summary("s3", "ivy", pinned: false, at: 8);
        var archived = Summary("s4", "ivy", archived: true, at: 7);
        var otherBot = Summary("s5", "otto", at: 11);

        // Mode Off still displays manual shortcuts for this bot (ignoring archived & other bots)
        var off = BotChatsUnder.Pick([s1, s2, s3], "ivy", BotChatsChoice.Initial, shortcuts: [s2, archived, otherBot]);
        Assert.Equal(["s2"], off.Shown.Select(s => s.Id));
        Assert.Equal(0, off.More);

        // Mode Pinned + Recent puts shortcuts first without duplicating them from sessions
        var combined = BotChatsUnder.Pick([s1, s2, s3], "ivy", new BotChatsChoice(BotChatsMode.Recent, 1), shortcuts: [s3]);
        Assert.Equal(["s3", "s1", "s2"], combined.Shown.Select(s => s.Id));
        Assert.Equal(0, combined.More);

        // ResolveShortcuts maps BotChatShortcut records to live sessions in order
        var resolved = BotChatsUnder.ResolveShortcuts([s1, s2, s3, archived, otherBot],
            [new BotChatShortcut("ivy", "s3"), new BotChatShortcut("ivy", "s1"), new BotChatShortcut("otto", "s5")], "ivy");
        Assert.Equal(["s3", "s1"], resolved.Select(s => s.Id));
    }

    // ------------------------------------------------------------------ ShellKeys tab cycling & HideList

    [Fact]
    public void ShellKeysIncludeTabCyclingAndHideListChords()
    {
        Assert.Equal("Ctrl+Tab", ShellKeys.NextTab.Display);
        Assert.Equal("Ctrl+Shift+Tab", ShellKeys.PreviousTab.Display);
        Assert.Equal("Ctrl+Shift+]", ShellKeys.NextTabBracket.Display);
        Assert.Equal("Ctrl+Shift+[", ShellKeys.PreviousTabBracket.Display);
        Assert.Equal("Ctrl+Shift+L", ShellKeys.HideList.Display);
    }
}
