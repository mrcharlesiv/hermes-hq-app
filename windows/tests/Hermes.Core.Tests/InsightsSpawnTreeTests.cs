using System.Text.Json.Nodes;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Spawn Tree's decoder, tree builder and words (HermesKit/Pages/More/SpawnTree.swift; the Swift's SpawnTreeTests).
public class InsightsSpawnTreeTests
{
    private static SpawnRecord R(string id, string? parent = null, double? started = null, SpawnStatus status = SpawnStatus.Running,
        string? owner = "s-1", string? goal = null) => new(id, parent, null, goal ?? id, null, started, status, null, owner);

    [Fact]
    public void DecodesLenientlyAndSkipsRowsWithoutAnId()
    {
        var j = JsonNode.Parse("""
        {"active":[
          {"subagent_id":"sa-1","parent_id":"","depth":1,"goal":"  ","model":"claude-opus-5","started_at":100,"status":"completed","tool_count":-3,"owner_agent_session_id":"s-1"},
          {"subagent_id":9,"goal":null,"depth":"2","tool_count":"4","started_at":"65.5","status":7,"owner_agent_session_id":"s-x"},
          {"goal":"No id at all"}, "not a record", null, {"subagent_id":""}
        ],"paused":true,"max_spawn_depth":3,"max_concurrent_children":"3"}
        """);
        var s = DelegationStatus.Parse(j);
        Assert.True(s.Paused);
        Assert.Equal(3, s.MaxDepth);
        Assert.Equal(3, s.MaxChildren);
        Assert.Equal(2, s.Active.Count);
        var a = s.Active[0];
        Assert.Null(a.ParentId);
        Assert.Null(a.Goal);
        Assert.Equal(SpawnStatus.Done, a.Status);
        Assert.Equal(0, a.ToolCount);
        var b = s.Active[1];
        Assert.Equal("9", b.Id);
        Assert.Equal(2, b.Depth);
        Assert.Equal(4, b.ToolCount);
        Assert.Equal(65.5, b.StartedAt);
        Assert.Equal(SpawnStatus.Running, b.Status);
    }

    [Theory]
    [InlineData("queued", SpawnStatus.Queued)]
    [InlineData("STARTING", SpawnStatus.Queued)]
    [InlineData("succeeded", SpawnStatus.Done)]
    [InlineData("timed_out", SpawnStatus.Failed)]
    [InlineData("killed", SpawnStatus.Failed)]
    [InlineData("whatever", SpawnStatus.Running)]
    [InlineData(null, SpawnStatus.Running)]
    public void StatusWords(string? raw, SpawnStatus expected) => Assert.Equal(expected, SpawnStatusWords.Parse(raw));

    [Fact]
    public void FlattenOrdersChildrenByStartAndBreaksCycles()
    {
        var rows = SpawnTree.Flatten([
            R("a", started: 10), R("b", "a", 30), R("c", "a", 20), R("d", "c", 25),
            R("orphan", "gone", 5), R("x", "y", 40), R("y", "x", 41), R("self", "self", 50),
        ]);
        Assert.Equal(["orphan", "a", "c", "d", "b", "self", "x", "y"], rows.Select(r => r.Record.Id));
        Assert.Equal([0, 0, 1, 2, 1, 0, 0, 1], rows.Select(r => r.Level));
    }

    [Fact]
    public void BuildGroupsByBotThenChatAndKeepsARepeatedSubagentOnce()
    {
        var sessions = new Dictionary<string, SpawnTree.Session>
        {
            ["s-release"] = new("deploys", " Ship the 2.4 release notes "),
            ["s-report"] = new("deploys", "The 2.4 report"),
        };
        var deploys = new DelegationStatus([R("r1", owner: "s-release"), R("p1", owner: "s-report"), R("r2", "r1", owner: "s-release", status: SpawnStatus.Done)]);
        // A gateway that answers every bot with the whole list: the subagent stays under the bot that owns its chat.
        var all = new DelegationStatus([R("r1", owner: "s-release"), R("loose", owner: null)], Paused: true);
        var tree = SpawnTree.Build([("default", all), ("deploys", deploys)], sessions);
        Assert.True(tree.Paused);
        Assert.Equal(["default", "deploys"], tree.Bots.Select(b => b.Id));
        Assert.Equal("Chat", tree.Bots[0].Chats.Single().Title);
        Assert.Null(tree.Bots[0].Chats.Single().SessionId);
        var d = tree.Bots[1];
        Assert.Equal(["Ship the 2.4 release notes", "The 2.4 report"], d.Chats.Select(c => c.Title));
        Assert.Equal(["r1", "r2"], d.Chats[0].Rows.Select(r => r.Record.Id));
        Assert.Equal(4, tree.Total);
        Assert.Equal(3, tree.Active);
        Assert.Equal("4 subagents · 3 active", tree.Header);
        Assert.Equal("deploys|r2", d.Chats[0].Rows[1].Id);
        Assert.Equal("3 Subagents Working", tree.Headline);
        Assert.Equal("4 listed, for 2 bots in 3 chats.", tree.HeadlineDetail);
    }

    [Fact]
    public void IndentIsCappedAtFour()
    {
        var chain = Enumerable.Range(0, 7).Select(i => R($"n{i}", i == 0 ? null : $"n{i - 1}", i)).ToList();
        var tree = SpawnTree.Build([("default", new DelegationStatus(chain))], new Dictionary<string, SpawnTree.Session>());
        Assert.Equal([0, 1, 2, 3, 4, 4, 4], tree.Bots[0].Chats[0].Rows.Select(r => r.Indent));
    }

    [Theory]
    [InlineData(45.0, "45s")]
    [InlineData(130.0, "2m 10s")]
    [InlineData(3900.0, "1h 5m")]
    [InlineData(93600.0, "1d 2h")]
    [InlineData(-1.0, null)]
    [InlineData(4e9, null)]
    public void Durations(double seconds, string? words) => Assert.Equal(words, SpawnTree.Duration(seconds));

    [Fact]
    public void DetailAndSpokenWords()
    {
        var r = new SpawnRecord("sa", null, null, "Read the networking changes", "claude-opus-5", 1000, SpawnStatus.Running, 7, "s");
        Assert.Equal("Opus 5 · 7 tools · running 1m 35s", SpawnTree.Detail(r, 1095));
        Assert.Equal("1 tool · queued", SpawnTree.Detail(r with { Model = null, ToolCount = 1, Status = SpawnStatus.Queued }, 1095));
        Assert.Equal("running", SpawnTree.Detail(r with { Model = null, ToolCount = null, StartedAt = null }, 1095));
        var spoken = SpawnTree.Spoken(new SpawnTree.Row("x", r, 1), 1095);
        Assert.Equal("Read the networking changes, Running, Opus 5, 7 tools, for 1 minute, 35 seconds, level 2", spoken);
        Assert.Equal("Subagent, Failed", SpawnTree.Spoken(new SpawnTree.Row("x", new SpawnRecord("y", Status: SpawnStatus.Failed), 0), 0));
    }

    [Fact]
    public void TilesCountByState()
    {
        var tree = SpawnTree.Build([("default", new DelegationStatus([
            R("a", started: 100), R("b", started: 50), R("c", status: SpawnStatus.Queued), R("d", status: SpawnStatus.Failed)]))],
            new Dictionary<string, SpawnTree.Session>());
        var tiles = tree.Tiles(200);
        Assert.Equal(("Running", "2", "longest 2m 30s", false), tiles[0]);
        Assert.Equal(("Queued", "1", "waiting to start", false), tiles[1]);
        Assert.Equal(("Done", "0", "finished, still listed", false), tiles[2]);
        Assert.Equal(("Failed", "1", "stopped with an error", true), tiles[3]);
        Assert.Equal("4 subagents · 2 running", SpawnTree.BotSummary(tree.Bots[0]));
        var empty = new SpawnTree();
        Assert.Equal("No Subagents Working", empty.Headline);
        Assert.Equal("Helpers a bot starts show up here while they run.", empty.HeadlineDetail);
        Assert.Equal(("Running", "0", "working now", false), empty.Tiles(0)[0]);
        Assert.Equal(("Failed", "0", "none", false), empty.Tiles(0)[3]);
    }

    [Fact]
    public void LoaderStates()
    {
        var none = new Dictionary<string, SpawnTree.Session>();
        var loader = new SpawnTreeLoader();
        var refused = new GatewayException("rpc", "The delegation registry is not available.", rpcCode: -32000);
        loader.Apply(["default"], new Dictionary<string, (DelegationStatus?, Exception?)> { ["default"] = (null, refused) }, none, 0);
        Assert.Equal(SpawnTreeLoader.Load.Failed, loader.State);
        Assert.Equal("The delegation registry is not available.", loader.Reason);
        Assert.True(loader.LastFailed);

        loader.Apply(["default", "b"], new Dictionary<string, (DelegationStatus?, Exception?)>
        {
            ["default"] = (new DelegationStatus([R("a")]), null), ["b"] = (null, refused),
        }, none, 5);
        Assert.Equal(SpawnTreeLoader.Load.Ready, loader.State);
        Assert.Equal(1, loader.Tree.Total);
        Assert.False(loader.LastFailed);

        // A failed refresh keeps the last tree.
        loader.Apply(["default"], new Dictionary<string, (DelegationStatus?, Exception?)> { ["default"] = (null, refused) }, none, 9);
        Assert.Equal(SpawnTreeLoader.Load.Ready, loader.State);
        Assert.True(loader.RefreshFailed);
        Assert.Equal(1, loader.Tree.Total);

        var missing = new GatewayException("rpc", "Method not found", rpcCode: -32601);
        loader.Apply(["default"], new Dictionary<string, (DelegationStatus?, Exception?)> { ["default"] = (null, missing) }, none, 9);
        Assert.Equal(SpawnTreeLoader.Load.Older, loader.State);
        Assert.True(loader.Tree.IsEmpty);
    }

    [Fact]
    public void Words()
    {
        Assert.Equal("No Subagents Running", SpawnTreeCopy.EmptyTitle);
        Assert.Equal("When a bot hands work to subagents (helper bots it starts), they show up here while they run.", SpawnTreeCopy.EmptyText);
        Assert.Equal("Couldn’t refresh. Showing the last list.", SpawnTreeCopy.RefreshFailed);
        Assert.Equal("New subagents are paused on this gateway.", SpawnTreeCopy.Paused);
        Assert.Equal("This Hermes doesn’t have Spawn Tree. Updating Hermes may add it.", InsightsWire.NotAvailableBody(SpawnTreeCopy.Title));
    }
}
