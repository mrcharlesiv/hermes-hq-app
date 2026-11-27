using System.Text.Json.Nodes;
using Hermes.Core.Groups;
using Xunit;

namespace Hermes.Core.Tests;

// Ports of Tests/Groups/GroupRulesTests.swift, GroupSnapshotTests.swift and GroupScreenRulesTests.swift (93f984bb1):
// keys, membership patches, marks, @mentions, the row's words, the stored log's bounds, the mirror, and the list plan.
internal static class G
{
    public static GroupSeat Seat(string name, string? title = null, string? display = null, string? handle = null, string[]? friendly = null,
        string[]? previous = null, bool remote = false) =>
        new(name, name, display ?? title ?? name, handle ?? GroupMentions.Handle(name, null), new GroupMember(name))
        {
            Title = title, Friendly = friendly ?? new[] { title, display }.OfType<string>().ToArray(), PreviousNames = previous ?? [], Remote = remote,
        };

    public static readonly GroupSeat[] Launch = [Seat("default", title: "Hermes"), Seat("ivy", title: "Ivy", friendly: ["Ivy"]),
        Seat("research", title: "Research", friendly: ["Research", "Research"])];

    public static GroupMessage You(string text, double at = 1, string? thread = "t1", string? id = null) => new(id, at, GroupAuthor.You, text, thread);
    public static GroupMessage Member(string name, string text, double at = 2, string? thread = "t1", string? id = null, string? source = null) =>
        new(id, at, new GroupAuthor(GroupAuthorKind.Member, name, source), text, thread);

    public static GroupRoom Room(string name, string? id = null, int entries = 3, int revision = 1, double start = 1_000, string text = "hello")
    {
        var room = new GroupRoom(name, id) { Members = [new GroupMember("ivy", "ivy"), new GroupMember("research", "research")], SyncRevision = revision };
        room.Log = [.. Enumerable.Range(0, entries).Select(i => You($"{text} {i}", start + i, id: $"{name}-{i}"))];
        return room;
    }

    public static JsonObject Meta(string json) => (JsonObject)JsonNode.Parse(json)!;
}

public class GroupRulesTests
{
    [Fact]
    public void RoomAndMemberKeys()
    {
        Assert.Equal("id:rm1", GroupKeys.RoomKey("rm1", "Launch"));
        Assert.Equal("name:Launch", GroupKeys.RoomKey(null, "Launch"));
        Assert.Equal("name:Launch", GroupKeys.RoomKey("", "Launch"));
        var remote = new GroupMember("ivy");
        Assert.Equal("ivy", GroupKeys.MemberKey(remote));
        remote.SourceScoped = true;
        remote.ConnectionId = "conn-9";
        Assert.Equal("conn-9::ivy", GroupKeys.MemberKey(remote));
        Assert.Equal("legacy", GroupKeys.Thread(null));
        Assert.Equal("legacy", GroupKeys.Thread(""));
        Assert.Equal("t1", GroupKeys.Thread("t1"));
        Assert.Equal("thread:t1::ivy", GroupKeys.SessionKey("t1", "ivy"));
        Assert.Equal("t1::ivy", GroupKeys.WatermarkKey("t1", "ivy"));
        Assert.Equal("room:id:rm1", GroupKeys.MuteKey("id:rm1"));
        Assert.Equal("group:id:rm1", GroupKeys.PinEntry("id:rm1"));
        Assert.Equal("gw:ivy/room-1", new GroupRoom("Hosted") { Hosted = new HostedRoomRef("ivy", "room-1") }.Key);
    }

    [Fact]
    public void NewIdsHaveTheWebShape()
    {
        Assert.Matches("^r[0-9a-z]+-[0-9a-z]{5}$", GroupKeys.NewRoomId());
        Assert.Matches("^t[0-9a-z]+-[0-9a-z]{5}$", GroupKeys.NewThreadId());
        var entry = GroupKeys.NewEntryId();
        Assert.Equal(entry.ToLowerInvariant(), entry);
        Assert.Equal(36, entry.Length);
        Assert.NotEqual(entry, GroupKeys.NewEntryId());
        // Date.now().toString(36) for 1700000000000.
        Assert.Equal("loyw3v28", GroupKeys.Stamp(DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_000)));
    }

    [Fact]
    public void SessionTitleIsTheRoomIdThenTheName()
    {
        Assert.Equal("Group: rmfixture-launch · t1", GroupKeys.SessionTitle(new GroupRoom("Launch Room", "rmfixture-launch"), "t1"));
        Assert.Equal("Group: Launch Room · legacy", GroupKeys.SessionTitle(new GroupRoom("Launch Room"), "legacy"));
        Assert.True(GroupKeys.IsPlumbingTitle("Group: rm1 · t1"));
        Assert.False(GroupKeys.IsPlumbingTitle("Groups project notes"));
        Assert.False(GroupKeys.IsPlumbingTitle("My Group: plans"));
    }

    [Fact]
    public void NamesAreTrimmedCutAndMadeUnique()
    {
        Assert.Equal("Launch Room", GroupKeys.CleanName("  Launch Room \n"));
        Assert.Equal(64, GroupKeys.CleanName(new string('a', 80)).Length);
        Assert.Equal(new string('a', 63), GroupKeys.CleanName(new string('a', 63) + " b"));
        Assert.Equal("Ivy, Research", GroupKeys.UniqueName("Ivy, Research", new HashSet<string>()));
        Assert.Equal("Ivy, Research 2", GroupKeys.UniqueName("Ivy, Research", new HashSet<string> { "Ivy, Research" }));
        Assert.Equal("Ivy, Research 3", GroupKeys.UniqueName("Ivy, Research", new HashSet<string> { "Ivy, Research", "Ivy, Research 2" }));
        var longName = new string('x', 64);
        var next = GroupKeys.UniqueName(longName, new HashSet<string> { longName });
        Assert.Equal(64, next.Length);
        Assert.EndsWith(" 2", next);
    }

    [Fact]
    public void MembershipPatches()
    {
        var meta = G.Meta("""{"groups":["A","B","A",""]}""");
        Assert.Equal(["A", "B"], GroupKeys.Groups(meta));
        Assert.Equal(["Old"], GroupKeys.Groups(G.Meta("""{"group":"Old"}""")));
        Assert.Empty(GroupKeys.Groups(G.Meta("""{"groups":[],"group":"Old"}""")));
        Assert.Empty(GroupKeys.Groups(G.Meta("{}")));
        Assert.Equal(["A", "B", "C"], GroupKeys.MembershipAdding(meta, "C"));
        Assert.Null(GroupKeys.MembershipAdding(meta, "A"));
        Assert.Equal(["B"], GroupKeys.MembershipRemoving(meta, "A"));
        Assert.Null(GroupKeys.MembershipRemoving(meta, "Z"));
        Assert.Equal(["B"], GroupKeys.MembershipRenaming(meta, "A", "B"));
        Assert.Equal(["C", "B"], GroupKeys.MembershipRenaming(meta, "A", "C"));
        Assert.Null(GroupKeys.MembershipRenaming(meta, "Z", "C"));
        Assert.Equal("""{"groups":["A","B"],"group":"A"}""", GroupKeys.Patch(["A", "B"]).ToJsonString());
        Assert.Equal("""{"groups":[],"group":null}""", GroupKeys.Patch([]).ToJsonString());
    }

    [Fact]
    public void MarksMoveWithARenameAndDropOnATombstone()
    {
        static GroupMarks.Snapshot S(string key, string name, string? id) => new(key, name, id);
        var none = new HashSet<string>();
        Assert.True(GroupMarks.Of([S("id:r1", "Launch", "r1")], [S("id:r1", "Release", "r1")], none).IsEmpty);
        var named = GroupMarks.Of([S("name:Launch", "Launch", null)], [S("name:Release", "Release", null)], none,
            new Dictionary<string, string> { ["Launch"] = "Release" });
        Assert.Equal("name:Release", named.Moved["name:Launch"]);
        Assert.Empty(named.Dropped);
        Assert.Equal("id:r1", GroupMarks.Of([S("name:Launch", "Launch", null)], [S("id:r1", "Launch", "r1")], none).Moved["name:Launch"]);
        var deleted = GroupMarks.Of([S("id:r1", "Launch", "r1")], [], new HashSet<string> { "id:r1" });
        Assert.Equal(["id:r1"], deleted.Dropped);
        Assert.Empty(deleted.Moved);
        Assert.True(GroupMarks.Of([S("id:r1", "Launch", "r1")], [], none).IsEmpty);
        Assert.True(GroupMarks.Of([S("name:Launch", "Launch", null)], [S("name:Other", "Other", null)], none).IsEmpty);
    }

    [Fact]
    public void HandlesAndNameForms()
    {
        Assert.Equal("hermes", GroupMentions.Handle("default", "anything"));
        Assert.Equal("ivy", GroupMentions.Handle("ivy", null));
        Assert.Equal("sammy", GroupMentions.Handle("ivy", " sammy "));
        Assert.Equal("ivy", GroupMentions.Handle("ivy", "default"));
        Assert.Equal(["research-buddy", "researchbuddy"], GroupMentions.NameForms("Research Buddy"));
        Assert.Equal(["ivy"], GroupMentions.NameForms("Ivy"));
        Assert.Empty(GroupMentions.NameForms("Hermes"));
        Assert.Empty(GroupMentions.NameForms("All"));
        Assert.Empty(GroupMentions.NameForms("  "));
        Assert.Empty(GroupMentions.NameForms("日本"));
        Assert.Equal(["head-writer", "headwriter"], GroupMentions.NameForms("Head Writer!"));
    }

    [Fact]
    public void TagsAreTheFriendlyNameThenTheHandle()
    {
        Assert.Equal(["hermes", "ivy", "research"], G.Launch.Select(GroupMentions.TagFor));
        Assert.Equal("head-writer", GroupMentions.TagFor(G.Seat("writer", title: "Head Writer!")));
        Assert.Equal("ops-bot", GroupMentions.TagFor(G.Seat("ops-bot", friendly: [])));
        Assert.Equal("x1", GroupMentions.TagFor(G.Seat("x1", title: "日本", friendly: ["日本"])));
    }

    [Fact]
    public void MentionsResolveNamesTitlesAndEveryone()
    {
        GroupSeat[] seats = [.. G.Launch, G.Seat("writer", title: "Head Writer", previous: ["Scribe"])];
        Assert.Equal(new GroupMentions.Parsed(false, ["ivy"]), GroupMentions.Parse("@ivy what's next?", seats));
        Assert.Equal(["ivy", "research"], GroupMentions.Parse("@Ivy and @RESEARCH, please", seats).Mentioned);
        Assert.Equal(["default"], GroupMentions.Parse("@hermes hello", seats).Mentioned);
        Assert.Equal(["writer"], GroupMentions.Parse("@head-writer @headwriter @head @writer", seats).Mentioned);
        Assert.Equal(["writer"], GroupMentions.Parse("@scribe are you there", seats).Mentioned);
        Assert.Equal(new GroupMentions.Parsed(true, []), GroupMentions.Parse("@all go", seats));
        Assert.Equal(new GroupMentions.Parsed(true, ["ivy"]), GroupMentions.Parse("@everyone and @ivy", seats));
        Assert.Equal(GroupMentions.Parsed.None, GroupMentions.Parse("@user @nobody mail me at a@b.co", seats));
        Assert.Equal(["ivy"], GroupMentions.Parse("@ivy @ivy", seats).Mentioned);
        Assert.Equal(["ivy"], GroupMentions.Parse("@ivy-local hi", seats).Mentioned);
        GroupSeat[] clash = [G.Seat("ivy", display: "Ivy"), G.Seat("other", display: "Other", previous: ["Ivy"])];
        Assert.Equal(["ivy"], GroupMentions.Parse("@ivy", clash).Mentioned);
    }

    [Fact]
    public void TypingQueryIsTheWordAfterAnAtSign()
    {
        Assert.Equal("", GroupMentions.TypingQuery("@"));
        Assert.Equal("sa", GroupMentions.TypingQuery("hello @Sa"));
        Assert.Null(GroupMentions.TypingQuery("hello @ivy "));
        Assert.Null(GroupMentions.TypingQuery("mail a@b"));
        Assert.Null(GroupMentions.TypingQuery("no mention"));
        Assert.Equal("re", GroupMentions.TypingQuery("line\n@re"));
    }

    [Fact]
    public void CompactCutsInsideTheBudget()
    {
        Assert.Equal(("short", false), GroupPrompt.Compact("short", 1_200));
        var cut = GroupPrompt.Compact(new string('a', 1_300), 1_200);
        Assert.True(cut.Truncated);
        Assert.Equal(1_200, cut.Text.Length);
        Assert.EndsWith("… [truncated]", cut.Text);
        Assert.False(GroupPrompt.Compact(new string('a', 1_200), 1_200).Truncated);
    }

    [Fact]
    public void RowSecondLineByState()
    {
        var labels = new Dictionary<string, string> { ["ivy"] = "Ivy" };
        var last = G.Member("ivy", "I can **take** the notes.\nMore.");
        GroupRowWords.Line Line(bool waiting = false, string[]? replying = null, int available = 3, int driven = 3, bool offline = false, GroupMessage? l = null, bool noLast = false) =>
            GroupRowWords.SecondLine(waiting, replying ?? [], available, driven, offline, noLast ? null : l ?? last, labels, 3);
        Assert.Equal(new GroupRowWords.Line("Waiting for your reply", GroupRowWords.Tone.Orange), Line(waiting: true, replying: ["Ivy"]));
        Assert.Equal(new GroupRowWords.Line("Ivy is replying…", GroupRowWords.Tone.Tint), Line(replying: ["Ivy"]));
        Assert.Equal("Ivy and Research are replying…", Line(replying: ["Ivy", "Research"]).Text);
        Assert.Equal(new GroupRowWords.Line("2 of 3 available", GroupRowWords.Tone.Orange), Line(available: 2));
        Assert.Equal("0 of 3 available", Line(offline: true).Text);
        Assert.Equal(new GroupRowWords.Line("Ivy: I can take the notes. More.", GroupRowWords.Tone.Secondary), Line());
        Assert.Equal("You: hello", Line(l: G.You("hello")).Text);
        Assert.Equal("3 bots", Line(noLast: true).Text);
        Assert.Equal("Ivy: …", GroupRowWords.Preview(G.Member("ivy", "  \n "), labels));
        Assert.Equal(5 + 160, GroupRowWords.Preview(G.Member("ivy", new string('a', 400)), labels).Length);
        // A voice memo reads as what was said.
        Assert.Equal("You: Voice Memo: Call me back",
            GroupRowWords.Preview(G.You("MEDIA:\"/tmp/voice-memo.m4a\"\nVoice memo transcript: Call me back"), labels));
    }

    [Fact]
    public void RowWordsAndCounts()
    {
        Assert.Equal("1 bot", GroupRowWords.Bots(1));
        Assert.Equal("6 bots", GroupRowWords.Bots(6));
        Assert.Equal("Replying…", GroupRowWords.Replying([]));
        Assert.Equal("Ivy, Research and 2 more are replying…", GroupRowWords.Replying(["Ivy", "Research", "Inbox", "Notes"]));
        Assert.Equal("Ivy is paused", GroupRowWords.Paused(["Ivy"]));
        Assert.Equal("2 bots paused", GroupRowWords.Paused(["Ivy", "Research"]));
        Assert.Equal("Hermes, Ivy, Research", GroupRowWords.Members(["Hermes", "Ivy", "Research"]));
        Assert.Equal("6 bots", GroupRowWords.Members(["Hermes", "Ivy", "Research", "Inbox", "Notes", "Ops"]));
        Assert.Equal("No bots yet", GroupRowWords.Members([]));
        Assert.Equal("No bots yet", GroupRowWords.MembersOrNone([]));
        Assert.Equal("Launch Room. Ivy: On it. 2 min ago. Unread. Pinned. Muted",
            GroupRowWords.AccessibilityLabel("Launch Room", "Ivy: On it", "2 min ago", true, true, true));
        Assert.Equal("R. 3 bots", GroupRowWords.AccessibilityLabel("R", "3 bots", "", false, false, false));
        Assert.Equal("R. 3 bots. Hidden", GroupRowWords.AccessibilityLabel("R", "3 bots", "", false, false, false, hidden: true));
        Assert.Equal("R. Ivy is replying… Unread", GroupRowWords.AccessibilityLabel("R", "Ivy is replying…", "", true, false, false));
    }

    [Fact]
    public void ActivityLines()
    {
        static GroupActivityEvent E(GroupActivityKind k, string? detail = null) => new(k, "ivy", detail, 1, 1, "t1");
        Assert.Equal("You sent a message", GroupRowWords.Activity(E(GroupActivityKind.Queued), "Ivy").Text);
        Assert.Equal("Ivy is working…", GroupRowWords.Activity(E(GroupActivityKind.Working), "Ivy").Text);
        Assert.Equal("Ivy replied", GroupRowWords.Activity(E(GroupActivityKind.Replied), "Ivy").Text);
        Assert.Equal("Research passed", GroupRowWords.Activity(E(GroupActivityKind.Passed), "Research").Text);
        Assert.Equal(new GroupRowWords.ActivityLine("Ivy took too long", "clock", true), GroupRowWords.Activity(E(GroupActivityKind.TimedOut), "Ivy"));
        Assert.Equal("Ivy hit an error", GroupRowWords.Activity(E(GroupActivityKind.Failed), "Ivy").Text);
        Assert.Equal("Ivy hit an error — model unavailable", GroupRowWords.Activity(E(GroupActivityKind.Failed, "model unavailable"), "Ivy").Text);
        Assert.Equal("Ivy couldn't start — too many bots running", GroupRowWords.Activity(E(GroupActivityKind.Failed, "no-slot"), "Ivy").Text);
        Assert.Equal("Ivy delivered a late reply", GroupRowWords.Activity(E(GroupActivityKind.Delivered), "Ivy").Text);
        Assert.Equal("Ivy is held (stopped by you) — @mention it or say resume to release", GroupRowWords.Activity(E(GroupActivityKind.Held), "Ivy").Text);
        Assert.Equal("You stopped the room — remaining turns are held until resumed", GroupRowWords.Activity(E(GroupActivityKind.Stopped), "").Text);
        Assert.Equal("Turn stopped at the round/message cap", GroupRowWords.Activity(E(GroupActivityKind.Capped), "").Text);
        Assert.Equal("Turn settled", GroupRowWords.Activity(E(GroupActivityKind.Settled), "").Text);
        Assert.Equal("Turn interrupted by a newer message", GroupRowWords.Activity(E(GroupActivityKind.Cancelled), "").Text);
    }

    [Fact]
    public void LogKeepsFourHundredEntriesAndMovesTheMarks()
    {
        var room = new GroupRoom("R") { Log = [.. Enumerable.Range(0, 450).Select(i => G.You($"m{i}", i))] };
        room.Watermarks = new() { ["t1::ivy"] = 440, ["t1::research"] = 20 };
        room.EnforceBounds();
        Assert.Equal(400, room.Log.Count);
        Assert.Equal("m50", room.Log[0].Text);
        Assert.Equal(390, room.Watermarks["t1::ivy"]);
        Assert.Equal(0, room.Watermarks["t1::research"]);
        var heavy = new GroupRoom("H") { Log = [.. Enumerable.Range(0, 40).Select(i => G.You(new string('z', 8_000), i))] };
        heavy.EnforceBounds();
        Assert.Equal(32, heavy.Log.Count);
        var single = new GroupRoom("S") { Log = [G.You(new string('z', 300_000))] };
        single.EnforceBounds();
        Assert.Single(single.Log);
    }

    [Fact]
    public void ARoomRecordSurvivesAnOlderOrDamagedFile()
    {
        var room = new GroupRoom("Launch Room", "r1") { Log = [G.You("hi", id: "a")], Pinned = true, PinnedAt = 5, Running = true, Epoch = 7 };
        room.Undelivered["a"] = "model unavailable";
        var back = GroupRoom.FromDeviceJson(JsonNode.Parse(room.ToDeviceJson().ToJsonString()))!;
        Assert.Equal("Launch Room", back.Name);
        Assert.Equal("r1", back.RoomId);
        Assert.Equal(room.Log, back.Log);
        Assert.True(back.Pinned);
        Assert.Equal(5, back.PinnedAt);
        Assert.Equal("model unavailable", back.Undelivered["a"]);
        Assert.False(back.Running);
        Assert.Equal(0, back.Epoch);
        var sparse = GroupRoom.FromDeviceJson(JsonNode.Parse("""{"name":"Old","log":"oops","holds":7}"""))!;
        Assert.Equal("Old", sparse.Name);
        Assert.Empty(sparse.Log);
        Assert.Empty(sparse.Holds);
        Assert.True(sparse.HoldDetection);
    }

    [Fact]
    public void AnInterruptedTurnBecomesAStrandedReplyAndMovesTheMark()
    {
        var room = G.Room("R", "r", entries: 4);
        room.Asking["ivy"] = new GroupAsking(2, "t1", 9, "s1", "t1::ivy", "R-2", 3);
        room.RecoverInterruptedTurns();
        Assert.Empty(room.Asking);
        Assert.Equal(3, room.Watermarks["t1::ivy"]);
        Assert.Equal(new GroupStranded(2, "t1", 9, "s1"), room.Stranded["ivy"]);
    }
}

public class GroupScreenRulesTests
{
    [Fact]
    public void TheWebExamplesReadAtFourPointFiveToOne()
    {
        var light = NameColor.WebLightBubble;
        var dark = NameColor.WebDarkBubble;
        foreach (var hex in new[] { "#FFD60A", "#64D2FF" })
        {
            var raw = NameColor.Parse(hex)!.Value;
            Assert.True(NameColor.Contrast(raw, light) < 4.5);
            var made = NameColor.Readable(hex, light, dark)!.Value;
            Assert.True(NameColor.Contrast(made.Light, light) >= 4.5, hex);
            Assert.True(NameColor.Contrast(made.Dark, dark) >= 4.5, hex);
            Assert.NotEqual(raw, made.Light);
            Assert.Equal(raw, made.Dark);
        }
        var violet = NameColor.Readable("#5E5CE6", light, dark)!.Value;
        Assert.Equal(new NameColor.Rgb(94, 92, 230), violet.Light);
        Assert.NotEqual(new NameColor.Rgb(94, 92, 230), violet.Dark);
        Assert.Equal(new NameColor.Rgb(255, 0, 0), NameColor.Parse("hsl(0, 100%, 50%)"));
        Assert.Equal(new NameColor.Rgb(1, 2, 3), NameColor.Parse("rgb(1, 2, 3)"));
        Assert.Equal(new NameColor.Rgb(0xAA, 0xBB, 0xCC), NameColor.Parse("#abc"));
        Assert.Null(NameColor.Parse("teal"));
        Assert.Null(NameColor.Readable(null));
    }

    [Fact]
    public void TheThreeDeliveryShapes()
    {
        Assert.Equal(new DeliverySender.Parsed("Inbox", "inbox", "Three new emails need a reply."),
            DeliverySender.Parse("Message from Inbox (@inbox): Three new emails need a reply."));
        Assert.Equal(new DeliverySender.Parsed("Billing Bot", "billing bot", "Invoice sent."), DeliverySender.Parse("Message from Billing Bot: Invoice sent."));
        Assert.Equal(new DeliverySender.Parsed("research", "research", "Findings are in the doc."),
            DeliverySender.Parse("[Message from agent 'research'] Findings are in the doc."));
        Assert.Equal(new DeliverySender.Parsed("Ops", "ops", "line one\nline two"), DeliverySender.Parse("Message from 🤖 Ops (@ops):\nline one\nline two"));
        Assert.Equal(new DeliverySender.Parsed("Ivy", "ivy", "hi"), DeliverySender.Parse("Message from Ivy (@ivy@studio-mac): hi"));
    }

    [Fact]
    public void WhatIsNotADelivery()
    {
        var longName = new string('n', 65);
        foreach (var text in new[] { "I got a Message from Inbox (@inbox): hi", "message from Inbox: hi", "Message from : hi", $"Message from {longName}: hi",
                     "Message from Inbox", " Message from Inbox: hi", "[Message from agent ''] hi", "Message from A\nB: hi" })
            Assert.Null(DeliverySender.Parse(text));
        Assert.Equal(64, DeliverySender.Parse($"Message from {new string('n', 64)}: hi")!.Name.Length);
    }

    private static GroupRowModel Row(string name, bool pinned = false, double? pinnedAt = null, string? section = null, int? order = null, double lastAt = 0,
        bool running = false, string? search = null, bool hidden = false) =>
        new($"id:{name}", name, "2 bots", GroupRowWords.Tone.Secondary)
        {
            Pinned = pinned, PinnedAt = pinnedAt, SectionId = section, Order = order, LastAt = lastAt, Running = running, MemberCount = 2,
            Search = search ?? name.ToLowerInvariant(), Hidden = hidden,
        };

    [Fact]
    public void PinnedRoomsAreTilesInPinOrderAndTheRestAreNewestFirst()
    {
        GroupRowModel[] rooms = [Row("Old", lastAt: 10), Row("New", lastAt: 90), Row("B pin", pinned: true, pinnedAt: 2), Row("A pin", pinned: true, pinnedAt: 5),
            Row("Filed", section: "s1", lastAt: 50), Row("Orphan", section: "deleted", lastAt: 70)];
        (string, string)[] sections = [("s1", "Work"), ("s2", "Home")];
        var plan = GroupList.Make(rooms, 9, sections, false);
        Assert.Equal(["B pin", "A pin"], plan.Tiles.Select(r => r.Name));
        Assert.Equal(["New", "Orphan", "Old"], plan.Loose.Select(r => r.Name));
        Assert.Equal(["Work"], plan.FiledSections.Select(f => f.Name));
        Assert.Equal(["Filed"], plan.FiledSections[0].Rooms.Select(r => r.Name));
        Assert.False(plan.FiledSections[0].Hint);
        Assert.Equal(4, plan.Count);
        Assert.False(plan.IsEmpty);
        var full = GroupList.Make(rooms, 1, sections, true);
        Assert.Equal(["B pin"], full.Tiles.Select(r => r.Name));
        Assert.Equal("A pin", full.Loose[0].Name);
        Assert.Equal(["A pin"], full.Overflow.Select(r => r.Name));
        Assert.Empty(plan.Overflow);
        Assert.Equal(["Work", "Home"], full.FiledSections.Select(f => f.Name));
        Assert.True(full.FiledSections[1].Hint);
        Assert.Empty(full.FiledSections[1].Rooms);
        Assert.True(GroupList.Make([], 9, [], false).IsEmpty);
    }

    [Fact]
    public void HiddenRoomsGoUnderHidden()
    {
        var plan = GroupList.Make([Row("Shown", lastAt: 10), Row("Hidden pin", pinned: true, pinnedAt: 1, hidden: true), Row("Hidden filed", section: "s1", lastAt: 40, hidden: true)],
            9, [("s1", "Work")], false);
        Assert.Empty(plan.Tiles);
        Assert.Equal(["Shown"], plan.Loose.Select(r => r.Name));
        Assert.Empty(plan.FiledSections);
        Assert.Equal(["Hidden filed", "Hidden pin"], plan.Hidden.Select(r => r.Name));
        Assert.Equal(1, plan.Count);
    }

    [Fact]
    public void AUserOrderBeatsRecencyAndNamesBreakTies()
    {
        GroupRowModel[] rooms = [Row("b", lastAt: 5), Row("a", lastAt: 5), Row("second", order: 2, lastAt: 1), Row("first", order: 1, lastAt: 0), Row("newest", lastAt: 99)];
        Assert.Equal(["first", "second", "newest", "a", "b"], GroupList.Sorted(rooms).Select(r => r.Name));
    }

    [Fact]
    public void SearchAndActivityFilterRooms()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000);
        var nowMs = now.ToUnixTimeMilliseconds();
        GroupRowModel[] rooms = [Row("Launch Room", lastAt: nowMs - 60_000, search: "launch room hermes ivy research"),
            Row("Archive", lastAt: nowMs - 9 * 24 * 3_600_000.0, search: "archive notes ops"),
            Row("Busy", lastAt: nowMs, running: true, search: "busy ivy"), Row("Silent", search: "silent writer")];
        List<string> Names(string q, BotActivityFilter a) => [.. GroupList.Results(rooms, q, a, now).Select(r => r.Name)];
        Assert.Equal(["Busy", "Launch Room", "Archive", "Silent"], Names("", BotActivityFilter.All));
        Assert.Equal(["Busy", "Launch Room"], Names("ivy", BotActivityFilter.All));
        Assert.Equal(["Launch Room"], Names("LAUNCH rés", BotActivityFilter.All));
        Assert.Equal(["Busy"], Names("", BotActivityFilter.Active));
        Assert.Equal(["Busy", "Launch Room"], Names("", BotActivityFilter.Recent));
        Assert.Equal(["Archive", "Silent"], Names("", BotActivityFilter.Older));
        Assert.Empty(Names("nothing", BotActivityFilter.All));
    }

    [Fact]
    public void ADraggedRoomDropsOnlyInTheGroupChatsBlock()
    {
        Assert.Equal(new GroupList.Drop(null), GroupList.DropFor(true, new BotListSectionId.Groups()));
        Assert.Equal(new GroupList.Drop("s1"), GroupList.DropFor(true, new BotListSectionId.GroupSection("s1")));
        Assert.Equal(new GroupList.Drop("s1"), GroupList.DropFor(true, new BotListSectionId.User("s1")));
        Assert.Equal(new GroupList.Drop(null), GroupList.DropFor(true, new BotListSectionId.Unassigned()));
        foreach (BotListSectionId s in new BotListSectionId[] { new BotListSectionId.Tiles(), new BotListSectionId.Pinned(), new BotListSectionId.Hidden(),
                     new BotListSectionId.Results(), new BotListSectionId.Everything() })
            Assert.Null(GroupList.DropFor(true, s));
        Assert.Null(GroupList.DropFor(true, null));
        Assert.Null(GroupList.DropFor(false, new BotListSectionId.Groups()));
        Assert.Equal("Drop a group chat here.", GroupList.DropHint);
    }

    [Fact]
    public void ShowFilterWordsAndTokens()
    {
        Assert.Equal(["All", "Bots", "Group Chats"], Enum.GetValues<BotKindFilter>().Select(f => f.Title()));
        Assert.Null(GroupFilters.Token(BotKindFilter.All, BotActivityFilter.All));
        Assert.Equal("Group Chats · Active Now", GroupFilters.Token(BotKindFilter.Groups, BotActivityFilter.Active));
        Assert.Equal("Recently Active", GroupFilters.Token(BotKindFilter.All, BotActivityFilter.Recent));
        Assert.True(GroupFilters.FiltersActive(BotKindFilter.Bots, BotActivityFilter.All));
        Assert.False(GroupFilters.FiltersActive(BotKindFilter.All, BotActivityFilter.All));
    }
}
