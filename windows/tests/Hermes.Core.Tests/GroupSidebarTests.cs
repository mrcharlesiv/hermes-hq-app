using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// Group chats in the sidebar and the rail, as 93f984bb1's App/Mac/MacBotsRail.swift (`titledGroups`, `groups`, `Item`),
/// App/Bots/BotListModel.swift (`rows`), App/Bots/BotListSections.swift (`file`, `flat`), App/Bots/BotsViewController.swift
/// (`composeSections`) and App/Groups/GroupAvatarView.swift lay them out.
public class GroupSidebarTests
{
    private static BotRow Bot(string id, double time = 0, bool pinned = false)
    {
        var p = RosterProfile.From(JsonNode.Parse($$"""{"name":"{{id}}"}"""))!;
        return new BotRow { Id = id, Name = id, Profile = p, Model = p.ToModel(id, new BotMeta()), Time = time, Pinned = pinned };
    }

    /// `lastAt` in milliseconds, as a room's log keeps it.
    private static GroupRowModel Room(string name, double lastAtSeconds = 0, bool pinned = false, string? section = null, bool hidden = false,
        double? pinnedAt = null, bool running = false, bool unread = false) =>
        new($"name:{name}", name, "Ivy: Hi", GroupRowWords.Tone.Secondary)
        {
            LastAt = lastAtSeconds * 1000, Pinned = pinned, SectionId = section, Hidden = hidden, PinnedAt = pinnedAt, Running = running, Unread = unread,
        };

    private static List<string> Keys(BotListSection s) => [.. s.Heads.Select(h => h.Key)];

    [Fact]
    public void ABlocksBotsAndRoomsMergeByActivityEachKeepingItsOwnOrder()
    {
        // A bot's time is seconds, a room's milliseconds; a tie goes to the bot (`rows`: botTime >= room.lastAt / 1000).
        var s = new BotListSection(BotBlock.Unassigned, null, null, [Bot("a", 300), Bot("b", 100)])
        { Rooms = [Room("R1", 200), Room("R2", 100), Room("R3", 50)] };
        Assert.Equal(["a", "room:name:R1", "b", "room:name:R2", "room:name:R3"], Keys(s));
        Assert.Equal(["a"], Keys(new BotListSection(BotBlock.Unassigned, null, null, [Bot("a")])));
    }

    [Fact]
    public void WithoutUserSectionsRoomsAreAGroupChatsBlockBeforeHidden()
    {
        var bots = new List<BotListSection>
        {
            new(BotBlock.Unassigned, null, null, [Bot("ivy", 500)]),
            new(BotBlock.Hidden, null, "Hidden", [Bot("old")]),
        };
        var (sections, count) = BotListRooms.Compose(bots, [Room("Launch Room", 900), Room("Desk", 100)], []);
        Assert.Equal(2, count);
        Assert.Equal([BotBlock.Unassigned, BotBlock.Groups, BotBlock.Hidden], sections.Select(s => s.Block));
        var groups = BotList.SidebarGroups(sections);
        Assert.Equal(["Bots", "Group Chats"], groups.Select(g => g.Title));
        Assert.Equal("groups", groups[1].Key);
        Assert.Equal(["room:name:Launch Room", "room:name:Desk"], Keys(groups[1]));   // newest message first
        Assert.Equal(["ivy"], Keys(groups[0]));
    }

    [Fact]
    public void WithAUserSectionRoomsAreFiledInItOrUnassignedAmongTheBots()
    {
        var bots = new List<BotListSection>
        {
            new(BotBlock.User, "sec-work", "Work", [Bot("ivy", 500), Bot("research", 100)]),
            new(BotBlock.Unassigned, null, null, [Bot("notes", 50)]),
        };
        var (sections, _) = BotListRooms.Compose(bots, [Room("Launch Room", 300, section: "sec-work"), Room("Loose", 900), Room("Gone", 10, section: "sec-deleted")],
            [new RosterSectionRecord("sec-work", "Work")]);
        Assert.DoesNotContain(sections, s => s.Block == BotBlock.Groups);
        var groups = BotList.SidebarGroups(sections);
        Assert.Equal(["Work", "Unassigned"], groups.Select(g => g.Title));
        Assert.Equal(["ivy", "room:name:Launch Room", "research"], Keys(groups[0]));
        // A room whose section was deleted is in no section again (Unassigned).
        Assert.Equal(["room:name:Loose", "notes", "room:name:Gone"], Keys(groups[1]));
    }

    [Fact]
    public void OnlyRoomsLeftUnassignedMakeAnUnassignedHeadingBeforeHidden()
    {
        var bots = new List<BotListSection>
        {
            new(BotBlock.User, "sec-work", "Work", [Bot("ivy")]),
            new(BotBlock.Hidden, null, "Hidden", [Bot("old")]),
        };
        var (sections, _) = BotListRooms.Compose(bots, [Room("Loose", 1)], [new RosterSectionRecord("sec-work", "Work")]);
        Assert.Equal([BotBlock.User, BotBlock.Unassigned, BotBlock.Hidden], sections.Select(s => s.Block));
        Assert.Equal("Unassigned", sections[1].Title);
    }

    [Fact]
    public void PinnedRoomsAreTilesAfterTheBotsTilesThenPinnedRowsAndTheGroupKeepsThePinsOrder()
    {
        var tiles = Enumerable.Range(1, 5).Select(i => Bot($"t{i}", 1000 - i, pinned: true)).ToList();
        var bots = new List<BotListSection>
        {
            new(BotBlock.Tiles, null, null, tiles),
            new(BotBlock.User, "sec-work", "Work", [Bot("ivy", 10)]),
        };
        // Five bot tiles leave one slot: the first pinned room by pin time takes it, the other is a Pinned row.
        var (sections, _) = BotListRooms.Compose(bots,
            [Room("Second", 5000, pinned: true, pinnedAt: 2), Room("First", 1, pinned: true, pinnedAt: 1)], [new RosterSectionRecord("sec-work", "Work")]);
        Assert.Equal(["room:name:First"], sections[0].Rooms.Select(r => BotListHead.RoomKey(r.Id)));
        Assert.Equal(BotBlock.Pinned, sections[1].Block);
        var groups = BotList.SidebarGroups(sections);
        Assert.Equal("Pinned", groups[0].Title);
        // Bots then rooms in each, never merged by activity (the newest room stays after the pinned bots).
        Assert.Equal([.. tiles.Select(t => t.Id), "room:name:First", "room:name:Second"], Keys(groups[0]));
        Assert.Equal(["Pinned", "Work"], groups.Select(g => g.Title));
    }

    [Fact]
    public void HiddenRoomsShowOnlyUnderHiddenWithShowHiddenBots()
    {
        var bots = new List<BotListSection> { new(BotBlock.Unassigned, null, null, [Bot("ivy")]) };
        var (sections, count) = BotListRooms.Compose(bots, [Room("Secret", 1, hidden: true), Room("Open", 2)], []);
        Assert.Equal(1, count);
        Assert.Equal(["Bots", "Group Chats"], BotList.SidebarGroups(sections).Select(g => g.Title));
        var shown = BotList.SidebarGroups(sections, showHidden: true);
        Assert.Equal(["Bots", "Group Chats", "Hidden"], shown.Select(g => g.Title));
        Assert.Equal(["room:name:Secret"], Keys(shown[2]));
    }

    [Fact]
    public void GroupByNoneIsOneUntitledBlockBetweenTheTilesAndHidden()
    {
        var bots = new List<BotListSection>
        {
            new(BotBlock.Tiles, null, null, [Bot("pin", 1, pinned: true)]),
            new(BotBlock.User, "sec-work", "Work", [Bot("ivy", 100)]),
            new(BotBlock.Unassigned, null, null, [Bot("notes", 300)]),
            new(BotBlock.Hidden, null, "Hidden", [Bot("old")]),
        };
        var (sections, _) = BotListRooms.Compose(bots, [Room("Launch Room", 200, section: "sec-work")], [new RosterSectionRecord("sec-work", "Work")], groupByNone: true);
        Assert.Equal([BotBlock.Tiles, BotBlock.Everything, BotBlock.Hidden], sections.Select(s => s.Block));
        var groups = BotList.SidebarGroups(sections, showHidden: true);
        Assert.Equal(["Pinned", "", "Hidden"], groups.Select(g => g.Title));
        Assert.Equal(["notes", "room:name:Launch Room", "ivy"], Keys(groups[1]));
        Assert.Equal("everything", groups[1].Key);
    }

    [Fact]
    public void AGroupSectionSubBlockKeepsItsNameAndFoldKey()
    {
        var s = new BotListSection(BotBlock.GroupSection, "sec-1", "Launch", []) { Rooms = [Room("A", 1)] };
        Assert.Equal("group-section:sec-1", s.Key);
        var empty = new BotListSection(BotBlock.Groups, null, null, []);
        Assert.Empty(BotList.SidebarGroups([empty]));
        Assert.Equal("Group Chats", BotList.SidebarGroups([empty with { Rooms = [Room("B", 1)] }])[0].Title);
    }

    [Fact]
    public void NoRoomsLeavesTheBotsListAsItWas()
    {
        var bots = new List<BotListSection> { new(BotBlock.Unassigned, null, null, [Bot("ivy")]) };
        var (sections, count) = BotListRooms.Compose(bots, [], [new RosterSectionRecord("sec-work", "Work")]);
        Assert.Equal(0, count);
        Assert.Equal(bots, sections);
    }

    [Fact]
    public void ARoomsRowWordsMarkAndReadAloudLabel()
    {
        var idle = Room("Launch Room", 5, unread: true);
        Assert.Null(BotListRooms.Status(idle));
        Assert.Equal(BotListRooms.FaceMark.Unread, BotListRooms.Mark(idle));
        Assert.Equal("Launch Room. Ivy: Hi. Unread", BotListRooms.AccessibilityLabel(idle));
        var running = Room("Launch Room", 5, running: true, unread: true);
        Assert.Equal("Working…", BotListRooms.Status(running));
        Assert.Equal(BotListRooms.FaceMark.Working, BotListRooms.Mark(running));
        Assert.Equal(BotListRooms.FaceMark.None, BotListRooms.Mark(Room("Quiet")));
        Assert.Equal("No messages yet", BotListRooms.PeekLine(Room("Quiet") with { Line = "  " }));
        Assert.Equal("room:name:Quiet", new BotListHead(null, Room("Quiet")).Key);
        Assert.Equal("Quiet", new BotListHead(null, Room("Quiet")).Name);
    }

    [Fact]
    public void TheAvatarsFacesSitAtTheWebsPlacements()
    {
        Assert.Empty(GroupAvatarLayout.Placements(0));
        Assert.Equal([new GroupAvatarLayout.Place(1, 0, 0)], GroupAvatarLayout.Placements(1));
        Assert.Equal([new GroupAvatarLayout.Place(0.64, 0, 0), new GroupAvatarLayout.Place(0.64, 0.36, 0.36)], GroupAvatarLayout.Placements(2));
        Assert.Equal(3, GroupAvatarLayout.Placements(5).Count);
        Assert.Equal(new GroupAvatarLayout.Place(0.42, 0.56, 0.54), GroupAvatarLayout.Placements(3)[2]);
        Assert.Equal([1, 2, 3], GroupAvatarLayout.ImageData("data:image/png;base64,AQID"));
        Assert.Null(GroupAvatarLayout.ImageData("https://example.com/a.png"));
        Assert.Null(GroupAvatarLayout.ImageData(null));
    }

    [Fact]
    public void TheDefaultProfilesRowCarriesTheMirrorAndTheRosterSeatsARoomsMembers()
    {
        var store = new BotStore(new NoGateway(), new MemoryDeviceStore());
        var mirror = new JsonObject
        {
            ["version"] = 3, ["updatedAt"] = 1_790_000_000_000,
            ["rooms"] = new JsonObject
            {
                ["id:r1"] = new JsonObject
                {
                    ["name"] = "Launch Room", ["roomId"] = "r1", ["revision"] = 1,
                    ["members"] = new JsonArray(new JsonObject { ["name"] = "ivy" }, new JsonObject { ["name"] = "research" }),
                    ["log"] = new JsonArray(new JsonObject { ["at"] = 1_790_000_000_000, ["from"] = new JsonObject { ["kind"] = "member", ["name"] = "ivy" }, ["text"] = "I can take the notes." }),
                },
            },
        };
        var profiles = new JsonArray(
            new JsonObject { ["name"] = "default", ["is_default"] = true, ["ui_meta"] = new JsonObject { [GroupSnapshot.MetaKey] = mirror } },
            new JsonObject { ["name"] = "ivy", ["display_name"] = "Ivy", ["ui_meta"] = new JsonObject { ["hermes-bots"] = new JsonObject { ["groups"] = new JsonArray("Launch Room") } } },
            new JsonObject { ["name"] = "research", ["display_name"] = "Research", ["ui_meta"] = new JsonObject { ["hermes-bots"] = new JsonObject { ["groups"] = new JsonArray("Launch Room") } } });
        store.ApplyFull(new JsonObject { ["profiles"] = profiles }, DateTimeOffset.UtcNow);
        var row = store.DefaultProfileRow()!;
        Assert.Equal("default", row["name"]!.GetValue<string>());
        var groups = new GroupStore { Roster = new BotStoreGroupRoster(store) };
        new GroupSync(groups, new NoGateway()).Pulled(row);
        var room = Assert.Single(groups.Rows());
        Assert.Equal("Launch Room", room.Name);
        Assert.Equal(2, room.MemberCount);
        Assert.Equal(["ivy", "research"], room.Faces.Select(f => f.Profile));
        Assert.StartsWith("Ivy: I can take the notes.", room.Line);
    }

    [Fact]
    public void TheWalksCheckRefusesAWrongOrderAHeadingInTheRailAndAMissingRoom()
    {
        string[] good = ["header:Pinned", "default", "header:Unassigned", .. WalkProof.GroupChatsUnassigned, "divider", "header:Tools"];
        Assert.Null(WalkProof.SidebarGroupChats(good, rail: false));
        Assert.NotNull(WalkProof.SidebarGroupChats(["header:Unassigned", "room:id:rfixture-weekend", "room:id:rfixture-launch", "notes"], rail: false));
        Assert.NotNull(WalkProof.SidebarGroupChats(["header:Bots", "notes"], rail: false));
        string[] rail = ["default", "divider", .. WalkProof.GroupChatsUnassigned, "divider"];
        Assert.Null(WalkProof.SidebarGroupChats(rail, rail: true));
        Assert.NotNull(WalkProof.SidebarGroupChats(["default", .. WalkProof.GroupChatsUnassigned], rail: true));
        Assert.NotNull(WalkProof.SidebarGroupChats(["header:Unassigned", "divider", .. WalkProof.GroupChatsUnassigned], rail: true));
        Assert.NotNull(WalkProof.SidebarGroupChats(["default", "divider", "notes"], rail: true));
    }

    private sealed class NoGateway : IListsGateway
    {
        public string AccountId => "test";
        public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default) =>
            throw new Net.GatewayException("offline", "offline");
        public Task<RestAnswer> RestAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, CancellationToken ct = default) => throw new Net.GatewayException("offline", "offline");
    }
}
