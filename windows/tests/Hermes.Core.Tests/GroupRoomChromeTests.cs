using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-41] An open room's chrome (App/Groups/GroupRoomChrome.swift, AppModel+Groups.swift `makeRoomScreen`), the
/// sender line over a member's reply (ChatRow.swift `showsSenderName`, ChatSenderPalette.swift), and the checks behind
/// the group-room walk (Services/ProofWalks.GroupRoom.cs).
public class GroupRoomChromeTests
{
    private static GroupStore Launch(out GroupRoom room)
    {
        room = new GroupRoom("Launch Room", "rfixture-launch") { Members = [new GroupMember("ivy", "ivy"), new GroupMember("research", "research")] };
        room.Log = [G.You("Who takes the notes?", 1, id: "e1"), G.Member("ivy", "I can take the notes.", 2, id: "e2")];
        return new GroupStore([room]) { Roster = FakeRoster.Launch() };
    }

    [Fact]
    public void TheTitleWearsTheFirstThreeSeatedMembersFaces()
    {
        var store = Launch(out var room);
        Assert.Equal(["ivy", "research"], GroupRoomChrome.Faces(store, store.Room("id:rfixture-launch")!).Select(f => f.Profile));
        Assert.Equal("Message Launch Room", GroupRoomChrome.Placeholder("Launch Room"));
        Assert.Equal("Launch Room", room.Name);
    }

    [Fact]
    public void OpeningTheRoomMarksItReadAndItsRowLosesTheMark()
    {
        var store = Launch(out _);
        var engine = new GroupEngine(store, new FakeRoomGateway().Client);
        store.SetUnread("id:rfixture-launch", true);
        Assert.True(store.Rows().Single(r => r.Name == "Launch Room").Unread);
        Assert.Equal(BotListRooms.FaceMark.Unread, BotListRooms.Mark(store.Rows().Single(r => r.Name == "Launch Room")));
        var session = GroupRoomSession.Open("id:rfixture-launch", store, engine, "acct")!;
        GroupRoomChrome.Open(session);
        var row = store.Rows().Single(r => r.Name == "Launch Room");
        Assert.False(row.Unread);
        Assert.Equal(BotListRooms.FaceMark.None, BotListRooms.Mark(row));
        Assert.Null(GroupRoomWalkProof.Opened(session.Title, [.. GroupRoomChrome.Faces(store, store.Room("id:rfixture-launch")!).Select(f => f.Profile)], row.Unread));
        engine.Shutdown();
        session.Dispose();
    }

    [Fact]
    public void ASendersNameShowsOnTheFirstOfItsRunOnly()
    {
        var ivy = new ChatSender("ivy", "Ivy", null, "ivy", "#e0b030");
        var research = new ChatSender("research", "Research", null, "research", null);
        IReadOnlyList<ChatMessage> rows =
        [
            new("u", Role.User, [new TextPart("hi")]),
            new("a", Role.Assistant, [new TextPart("one")]) { Sender = ivy },
            new("b", Role.Assistant, [new TextPart("two")]) { Sender = ivy },
            new("c", Role.Assistant, [new TextPart("three")]) { Sender = research },
            new("d", Role.Assistant, [new TextPart("plain")]),
        ];
        Assert.Equal([false, true, false, true, false], Enumerable.Range(0, rows.Count).Select(i => GroupRoomChrome.ShowsSenderName(rows, i)));
    }

    [Fact]
    public void ANamesColourIsTheMacsReadableLightAndDarkPair()
    {
        // ChatSenderPalette.nameColor: light toward black at 6:1 on the light bubble, dark from NameColor.readable.
        var pair = GroupRoomChrome.NameColor("#e0b030")!.Value;
        Assert.True(NameColor.Contrast(pair.Light, NameColor.LightBubble) >= 6);
        Assert.True(NameColor.Contrast(pair.Dark, NameColor.DarkBubble) >= 4.5);
        Assert.Equal(NameColor.Readable("#e0b030")!.Value.Dark, pair.Dark);
        Assert.Null(GroupRoomChrome.NameColor(null));
        Assert.Null(GroupRoomChrome.NameColor("not a colour"));
    }

    [Fact]
    public void TheComposerOffersStopWhileTheRoomRuns()
    {
        Assert.Equal(("\uE71A", "Stop (Esc)"), GroupRoomChrome.SendButton(running: true));
        Assert.Equal(("\uE74A", "Send (Enter)"), GroupRoomChrome.SendButton(running: false));
    }

    [Fact]
    public void TheWalkChecksNameWhatIsWrong()
    {
        Assert.Null(GroupRoomWalkProof.Opened("Launch Room", ["ivy", "research"], unread: false));
        Assert.Equal("the room's row is still unread", GroupRoomWalkProof.Opened("Launch Room", ["ivy", "research"], unread: true));
        Assert.Equal("the room is titled Weekend Plans", GroupRoomWalkProof.Opened("Weekend Plans", ["ivy", "research"], unread: false));
        Assert.Equal("the title's faces are notes", GroupRoomWalkProof.Opened("Launch Room", ["notes"], unread: false));

        (string? Sender, string Role, string Text)[] good =
        [
            (null, "user", GroupRoomWalkProof.Line), ("Ivy", "assistant", "Ivy here: noted."), ("Research", "assistant", "Research here: noted."),
        ];
        Assert.Null(GroupRoomWalkProof.Replies(good));
        Assert.Equal("no line of yours reads \"Who has the release notes this week?\"", GroupRoomWalkProof.Replies(good[1..]));
        Assert.Equal("no reply from Research under the line", GroupRoomWalkProof.Replies(good[..2]));
        Assert.Equal("Ivy's reply shows the name \"\"", GroupRoomWalkProof.Replies([good[0], (null, "assistant", "Ivy here: noted."), good[2]]));

        GroupActivityKind[] stopped = [GroupActivityKind.Queued, GroupActivityKind.Working, GroupActivityKind.Stopped];
        Assert.Null(GroupRoomWalkProof.StoppedMidRound(stopped, running: false, stopShown: false));
        Assert.Equal("the room still runs after Stop", GroupRoomWalkProof.StoppedMidRound(stopped, running: true, stopShown: false));
        Assert.Equal("the composer still offers Stop", GroupRoomWalkProof.StoppedMidRound(stopped, running: false, stopShown: true));
        Assert.Equal("the round was not stopped (Queued, Settled)",
            GroupRoomWalkProof.StoppedMidRound([GroupActivityKind.Queued, GroupActivityKind.Settled], running: false, stopShown: false));
        Assert.Equal("the round had ended before Stop (Queued, Settled, Stopped)",
            GroupRoomWalkProof.StoppedMidRound([GroupActivityKind.Queued, GroupActivityKind.Settled, GroupActivityKind.Stopped], running: false, stopShown: false));
    }
}
