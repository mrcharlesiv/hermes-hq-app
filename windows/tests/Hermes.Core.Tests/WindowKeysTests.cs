using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// View's Next / Previous Chat, ⌘1…⌘9 and Refresh, and Help › Hermes HQ Support, as App/Root/KeyCommands.swift and
/// HermesKit/Layout/KeyRules.swift (93f984bb1) decide them.
public class WindowKeysTests
{
    private static readonly string[] Abc = ["a", "b", "c"];

    [Fact]
    public void TheWalkStepsOneRowAndStopsAtEitherEnd()
    {
        Assert.Equal("b", ChatWalk.Target(Abc, "a", forward: true));
        Assert.Equal("a", ChatWalk.Target(Abc, "b", forward: false));
        // No wraparound: the Mac's `order.indices.contains(next) ? order[next] : nil`.
        Assert.Null(ChatWalk.Target(Abc, "c", forward: true));
        Assert.Null(ChatWalk.Target(Abc, "a", forward: false));
        // Nothing current (or a row no longer listed): Next opens the first row, Previous does nothing.
        Assert.Equal("a", ChatWalk.Target(Abc, null, forward: true));
        Assert.Null(ChatWalk.Target(Abc, null, forward: false));
        Assert.Equal("a", ChatWalk.Target(Abc, "gone", forward: true));
        Assert.Null(ChatWalk.Target(Abc, "gone", forward: false));
        Assert.Null(ChatWalk.Target([], null, forward: true));
    }

    private static BotRow Bot(string id)
    {
        var p = RosterProfile.From(JsonNode.Parse($$"""{"name":"{{id}}"}"""))!;
        return new BotRow { Id = id, Name = id, Profile = p, Model = p.ToModel(id, new BotMeta()) };
    }

    [Fact]
    public void TheBotsWalkInTheSidebarsOrderPinsFirstCollapsedGroupsLeftOut()
    {
        var groups = new List<BotListSection>
        {
            new(BotBlock.Tiles, null, "Pinned", [Bot("otto"), Bot("herald")]),
            new(BotBlock.User, "s1", "Work", [Bot("ivy"), Bot("otto")]),   // a bot listed twice walks once
            new(BotBlock.User, "s2", "Home", [Bot("wren")]),
            new(BotBlock.Unassigned, null, "Unassigned", [Bot("juno")]),
        };
        Assert.Equal(["otto", "herald", "ivy", "wren", "juno"], ChatWalk.BotOrder(groups, []));
        Assert.Equal(["otto", "herald", "ivy", "juno"], ChatWalk.BotOrder(groups, ["user:s2"]));
        Assert.Equal(["ivy", "otto", "wren", "juno"], ChatWalk.BotOrder(groups, ["tiles"]));
    }

    private static SessionSummary S(string profile, string id) => new() { Id = id, Profile = profile, Title = id };

    [Fact]
    public void TheSessionsWalkTheirRowsTopToBottomThePageHeaderLeftOut()
    {
        var groups = new List<SessionGroup>
        {
            new() { Id = SessionListPipeline.PageId, Sessions = [S("otto", "p1")] },
            new() { Id = "today", Sessions = [S("otto", "s1"), S("ivy", "s2")] },
            new() { Id = "earlier", Sessions = [S("otto", "s3"), S("otto", "s1")] },
        };
        var order = ChatWalk.SessionOrder(groups);
        Assert.Equal([ChatWalk.SessionKey("otto", "s1"), ChatWalk.SessionKey("ivy", "s2"), ChatWalk.SessionKey("otto", "s3")], order);
        Assert.Equal(("ivy", "s2"), ChatWalk.SplitSessionKey(order[1]));
        Assert.Null(ChatWalk.SplitSessionKey("nope"));
    }

    private static readonly string[] Bots = ["otto", "herald", "ivy"];
    private static readonly string[] Sessions = [ChatWalk.SessionKey("otto", "s1"), ChatWalk.SessionKey("ivy", "s2")];

    private static WalkFacts F(OpenPane pane, string? profile = null, string? id = null, string? place = null, bool fromSessions = false,
        bool covered = false, bool typed = false) => new(pane, profile, id, place, fromSessions, Bots, Sessions, covered, typed);

    [Fact]
    public void ABotsOwnChatWalksTheBots()
    {
        var f = F(OpenPane.BotChat, "herald", "x");
        Assert.Equal(WalkList.Bots, WalkKeys.ListFor(f));
        Assert.Equal("ivy", WalkKeys.Target(f, forward: true));
        Assert.Equal("otto", WalkKeys.Target(f, forward: false));
        Assert.False(WalkKeys.Enabled(F(OpenPane.BotChat, "ivy", "x"), forward: true));   // the last bot: Next is off
        Assert.False(WalkKeys.Enabled(F(OpenPane.BotChat, "otto", "x"), forward: false));
    }

    [Fact]
    public void AChatFromTheBotsHasNoRowSoNextOpensTheFirstBot()
    {
        var f = F(OpenPane.Chat, "herald", "s9");
        Assert.Equal(WalkList.Bots, WalkKeys.ListFor(f));
        Assert.Null(WalkKeys.Current(f));
        Assert.Equal("otto", WalkKeys.Target(f, forward: true));
        Assert.False(WalkKeys.Enabled(f, forward: false));
        // Nothing open is the Bots place with nothing beside it: the same.
        Assert.Equal("otto", WalkKeys.Target(F(OpenPane.Nothing), forward: true));
    }

    [Fact]
    public void AChatFromSessionsWalksTheSessions()
    {
        var f = F(OpenPane.Chat, "otto", "s1", fromSessions: true);
        Assert.Equal(WalkList.Sessions, WalkKeys.ListFor(f));
        Assert.Equal(Sessions[1], WalkKeys.Target(f, forward: true));
        Assert.Null(WalkKeys.Target(f, forward: false));
        // Sessions on show with no chat beside it: Next opens its first row.
        Assert.Equal(Sessions[0], WalkKeys.Target(F(OpenPane.Place, place: "sessions"), forward: true));
    }

    [Fact]
    public void AnotherPageASheetOrWordsInAFieldTurnTheWalkOff()
    {
        Assert.Equal(WalkList.None, WalkKeys.ListFor(F(OpenPane.Place, place: "jobs")));
        Assert.False(WalkKeys.Enabled(F(OpenPane.Place, place: "terminal"), forward: true));
        Assert.False(WalkKeys.Enabled(F(OpenPane.BotChat, "otto", "x", covered: true), forward: true));
        Assert.False(WalkKeys.Enabled(F(OpenPane.BotChat, "otto", "x", typed: true), forward: true));
        Assert.Equal("Next Chat", WalkKeys.NextTitle);
        Assert.Equal("Previous Chat", WalkKeys.PreviousTitle);
    }

    [Fact]
    public void TheNumbersGoToThePlacesInOrderAndNineIsTheLastPastNine()
    {
        var numbered = PlaceKeys.Numbered(["sessions", "jobs", "artifacts"], ["tasks", "files"]);
        Assert.Equal(["bots", "sessions", "jobs", "artifacts", "tasks", "files"], numbered);
        Assert.Equal(0, PlaceKeys.Place(0, numbered.Count));   // Ctrl+1: Bots
        Assert.Equal(5, PlaceKeys.Place(5, numbered.Count));
        Assert.Null(PlaceKeys.Place(6, numbered.Count));        // Ctrl+7 with six places: nothing
        // Twelve places: Ctrl+9 picks the last (as Safari's ⌘9), Ctrl+1…8 the first eight; the rest have no number.
        Assert.Equal(11, PlaceKeys.Place(8, 12));
        Assert.Equal(7, PlaceKeys.Place(7, 12));
        Assert.Equal(8, PlaceKeys.Place(8, 9));
        Assert.Equal(9, PlaceKeys.Number(11, 12));
        Assert.Null(PlaceKeys.Number(8, 12));
        Assert.Null(PlaceKeys.Place(9, 12));
        Assert.Null(PlaceKeys.Place(-1, 12));
    }

    [Fact]
    public void RefreshIsThePagesOwnTheListsBesideAChatAndOffOnAPageWithout()
    {
        Assert.Equal(RefreshTarget.Page, RefreshKeys.Target(OpenPane.Place, pageRefreshes: true));
        Assert.Equal(RefreshTarget.None, RefreshKeys.Target(OpenPane.Place, pageRefreshes: false));
        Assert.Equal(RefreshTarget.Lists, RefreshKeys.Target(OpenPane.Chat, pageRefreshes: false));
        Assert.Equal(RefreshTarget.Lists, RefreshKeys.Target(OpenPane.BotChat, pageRefreshes: false));
        Assert.Equal(RefreshTarget.Lists, RefreshKeys.Target(OpenPane.Nothing, pageRefreshes: false));
        Assert.Equal(RefreshTarget.None, RefreshKeys.Target(OpenPane.Chat, pageRefreshes: false, covered: true));
    }

    [Fact]
    public void HelpOpensTheMacsSupportPage()
    {
        Assert.Equal("Hermes HQ Support", HelpMenu.SupportTitle);
        Assert.Equal("https://gethermeshq.com/support", HelpMenu.SupportUrl);   // MacWindow.supportPage
    }
}
