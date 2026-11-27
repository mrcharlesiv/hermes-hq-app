using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-52] The room's polish, as the Mac's chat screen draws a room (App/Chat/ChatRow.swift `joins`,
/// `applyRunsAndGaps`, the room's typing rows; Cells/ChatCells.swift WaitingCell; App/Groups/GroupRoomChrome.swift
/// `moreItems`, RoomEmptyView).
public class GroupRoomPolishTests
{
    private static readonly ChatSender Ivy = new("ivy", "Ivy", null, "ivy", null);
    private static readonly ChatSender Research = new("research", "Research", null, "research", null);
    private static readonly DateTimeOffset T0 = new(2026, 11, 20, 10, 0, 0, TimeSpan.Zero);

    private static ChatMessage Reply(string id, ChatSender? sender, DateTimeOffset? at) =>
        new(id, Role.Assistant, [new TextPart(id)], at) { Sender = sender };

    [Fact]
    public void ARunIsOneSendersWithinFiveMinutes()
    {
        // ChatRow.joins: same role (never system), same sender, no badges under the first, within 300 s.
        Assert.True(GroupRoomChrome.Joins(Reply("a", Ivy, T0), Reply("b", Ivy, T0.AddSeconds(300))));
        Assert.False(GroupRoomChrome.Joins(Reply("a", Ivy, T0), Reply("b", Ivy, T0.AddSeconds(301))));
        Assert.False(GroupRoomChrome.Joins(Reply("a", Ivy, T0), Reply("b", Research, T0.AddSeconds(5))));
        Assert.True(GroupRoomChrome.Joins(Reply("a", Ivy, null), Reply("b", Ivy, T0)));   // an untimed pair joins
        var you = new ChatMessage("u", Role.User, [new TextPart("hi")], T0);
        Assert.False(GroupRoomChrome.Joins(you, Reply("b", null, T0)));
        var note = new ChatMessage("n", Role.System, [new TextPart("x")], T0);
        Assert.False(GroupRoomChrome.Joins(note, note with { Id = "n2" }));
        var badged = Reply("a", Ivy, T0) with { Reactions = [new MessageReaction("👍", "me")] };
        Assert.False(GroupRoomChrome.Joins(badged, Reply("b", Ivy, T0.AddSeconds(5))));
    }

    [Fact]
    public void TheNameShowsAtTheStartOfEachRunExactlyAsTheMacs()
    {
        // `showsSenderName = sender != nil && !joinsAbove`: a reply 6 minutes after the same member's names it again,
        // as does one under a day line.
        List<ChatMessage> rows =
        [
            new("u", Role.User, [new TextPart("hi")], T0),
            Reply("a", Ivy, T0.AddSeconds(10)),
            Reply("b", Ivy, T0.AddSeconds(20)),
            Reply("c", Ivy, T0.AddMinutes(7)),
            Reply("d", Research, T0.AddMinutes(7)),
            Reply("e", null, T0.AddMinutes(8)),
        ];
        Assert.Equal([false, true, false, true, true, false], Enumerable.Range(0, rows.Count).Select(i => GroupRoomChrome.ShowsSenderName(rows, i)));
        Assert.True(GroupRoomChrome.ShowsSenderName(rows, 2, dayLineAbove: true));
    }

    [Fact]
    public void TheRoomsTypingRowIsPlainWithNoTimer()
    {
        // WaitingCell.tick: a room's typing row is `plain` — its words and the face, never the timer.
        Assert.Equal("", GroupRoomChrome.TypingTimer(75, plain: true));
        Assert.Equal("", GroupRoomChrome.TypingTimer(9, plain: false));
        Assert.Equal("· 0:12", GroupRoomChrome.TypingTimer(12, plain: false));
        Assert.Equal("· 1:05", GroupRoomChrome.TypingTimer(65, plain: false));
        Assert.Equal("chat.typing", GroupRoomChrome.TypingId);
    }

    [Fact]
    public void AnEmptyRoomShowsItsNameMembersAndHint()
    {
        Assert.Equal("Everyone here sees what you send. Type @ to ask one bot.", GroupRoomChrome.EmptyHint);
        Assert.True(GroupRoomChrome.IsEmpty([], []));
        Assert.False(GroupRoomChrome.IsEmpty([], [new RoomTyping(Ivy, "Ivy is replying…")]));
        Assert.False(GroupRoomChrome.IsEmpty([Reply("a", Ivy, T0)], []));
        Assert.Equal("No bots yet", GroupRowWords.MembersOrNone([]));
    }

    [Fact]
    public void TheMoreMenuIsTheMacsInItsOrder()
    {
        string Flat(IReadOnlyList<IReadOnlyList<GroupRoomChrome.MoreItem>> menu) =>
            string.Join(" | ", menu.Select(s => string.Join(", ", s.Select(i => i.Title))));
        Assert.Equal("Find in Chat, Group Info, Add Bots…, Prompts, Activity | Delete Group Chat",
            Flat(GroupRoomChrome.MoreItems(online: true, fixedMembers: false, running: false, paused: false)));
        Assert.Equal("Find in Chat, Group Info, Prompts, Activity | Stop All, Resume All",
            Flat(GroupRoomChrome.MoreItems(online: false, fixedMembers: false, running: true, paused: true)));
        Assert.Equal("Find in Chat, Group Info, Prompts, Activity | Delete Group Chat",
            Flat(GroupRoomChrome.MoreItems(online: true, fixedMembers: true, running: false, paused: false)));
        var all = GroupRoomChrome.MoreItems(online: true, fixedMembers: false, running: true, paused: true).SelectMany(s => s).ToList();
        Assert.Equal(["room.more.find", "room.more.info", "room.more.add", "room.more.prompts", "room.more.activity", "room.more.stop", "room.more.resume", "room.more.delete"],
            all.Select(i => i.AutomationId));
        Assert.True(all.Single(i => i.Id == "delete").Destructive);
        Assert.Equal(34, GroupRoomChrome.TitleAvatarSide);
    }

    [Fact]
    public void TheNewWalkShotsCheckTheTypingRowAndFind()
    {
        Assert.Null(GroupRoomWalkProof.Typing([("Ivy is replying…", "ivy")]));
        Assert.Null(GroupRoomWalkProof.Typing([("Research is replying…", "research")]));
        Assert.NotNull(GroupRoomWalkProof.Typing([("Ivy is replying…", "research")]));
        Assert.NotNull(GroupRoomWalkProof.Typing([]));
        Assert.NotNull(GroupRoomWalkProof.Typing([("Replying…", null)]));
        Assert.Null(GroupRoomWalkProof.Found("1 of 2", 2));
        Assert.NotNull(GroupRoomWalkProof.Found("No Results", 0));
        Assert.NotNull(GroupRoomWalkProof.Found("1 of 2", 0));
    }
}
