using Hermes.Core.Groups;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-59] A room's @ list (App/Groups/GroupRoomChrome.swift `updateMentions`, `insertMention`, RoomMentionList `key` /
/// `pickMarked`): the rows a typed @word offers, the list keys, Escape, and the text a pick leaves in the box. The key
/// cases are Tests/MacPolish6Tests.swift `theGroupChatsMentionListTakesTheListKeys`; the narrowing and the picked text are
/// UITests/groups/GroupsEndToEndTests+Room.swift testD12_MentionSuggestions.
public class GroupMentionListTests
{
    private static readonly IReadOnlyList<(string Tag, string Name, ChatSender? Sender)> Members =
    [
        ("hermes", "Hermes", null),
        ("ivy", "Ivy", new ChatSender("ivy", "Ivy", null, "ivy", null)),
        ("research", "Research", new ChatSender("research", "Research", null, "research", null)),
    ];

    private static GroupMentionList.Row R(string tag, string name, string detail) => new(tag, name, detail, null);

    [Fact]
    public void AnAtSignOffersEveryoneThenEachMember()
    {
        var rows = GroupMentionList.RowsFor("@", Members);
        Assert.Equal(["everyone", "hermes", "ivy", "research"], rows.Select(r => r.Tag));
        Assert.Equal("@everyone", rows[0].Name);
        Assert.Equal("Every bot in this group chat", rows[0].Detail);
        Assert.Null(rows[0].Sender);
        Assert.Equal(("Research", "@research", "research"), (rows[3].Name, rows[3].Detail, rows[3].Sender?.Profile));
        Assert.Equal("room.mention.research", rows[3].AutomationId);
        Assert.Equal(GroupMentionList.ListId, "room.mentions");
    }

    [Fact]
    public void TypingNarrowsTheListByTagPrefixOrNameWithin()
    {
        Assert.Equal(["research"], GroupMentionList.RowsFor("@re", Members).Select(r => r.Tag));
        Assert.Equal(["research"], GroupMentionList.RowsFor("hello @Re", Members).Select(r => r.Tag));
        // A name matches anywhere in it ("arch" is inside "Research"); a tag only from its start.
        Assert.Equal(["research"], GroupMentionList.RowsFor("@arch", Members).Select(r => r.Tag));
        Assert.Equal(["everyone"], GroupMentionList.RowsFor("@every", Members).Select(r => r.Tag));
        Assert.Empty(GroupMentionList.RowsFor("@zz", Members));
    }

    [Fact]
    public void NoAtWordBeingTypedOffersNothing()
    {
        Assert.Empty(GroupMentionList.RowsFor("and mail a@", Members));   // an @ inside a word suggests nothing
        Assert.Empty(GroupMentionList.RowsFor("@research ", Members));    // the word is finished
        Assert.Empty(GroupMentionList.RowsFor("no mention", Members));
    }

    [Fact]
    public void TheListTakesTheListKeys()
    {
        var list = new GroupMentionList();
        list.Set([R("everyone", "@everyone", "Every bot"), R("finn", "Finn", "@finn"), R("fiona", "Fiona", "@fiona")]);
        Assert.Null(list.Marked);
        Assert.Null(list.PickMarked());   // nothing marked: Return sends as ever
        list.Key(GroupMentionList.DrawerKey.Down);
        list.Key(GroupMentionList.DrawerKey.Down);
        Assert.Equal(1, list.Marked);
        list.Key(GroupMentionList.DrawerKey.Down);
        list.Key(GroupMentionList.DrawerKey.Down);
        Assert.Equal(2, list.Marked);   // ↓ stops at the last row
        Assert.Equal("fiona", list.PickMarked());   // Return picks the marked row
        list.Key(GroupMentionList.DrawerKey.Up);
        list.Key(GroupMentionList.DrawerKey.Up);
        list.Key(GroupMentionList.DrawerKey.Up);
        Assert.Null(list.Marked);   // ↑ from the first row marks none
        Assert.Equal("everyone", list.Key(GroupMentionList.DrawerKey.Tab));   // Tab with nothing marked picks the first
        list.Set([R("finn", "Finn", "@finn")]);
        Assert.Null(list.Marked);   // typing starts over
    }

    [Fact]
    public void TheSameRowsKeepTheMarkAndAnEmptyListTakesNoKeys()
    {
        var list = new GroupMentionList();
        Assert.Null(list.Key(GroupMentionList.DrawerKey.Tab));
        Assert.Null(list.Marked);
        Assert.True(list.Set([R("finn", "Finn", "@finn")]));
        list.Key(GroupMentionList.DrawerKey.Down);
        Assert.False(list.Set([R("finn", "Finn", "@finn")]));   // unchanged rows: no change, the mark stays
        Assert.Equal(0, list.Marked);
        Assert.Equal("finn", list.Key(GroupMentionList.DrawerKey.Tab));   // Tab picks the marked row
    }

    [Fact]
    public void UpdateOpensTheListAndEscapeClosesItUntilTheWordsChange()
    {
        var list = new GroupMentionList();
        Assert.True(list.Update("@Re", "@Re", Members));
        Assert.True(list.IsOpen);
        Assert.Equal(["research"], list.Rows.Select(r => r.Tag));
        list.Key(GroupMentionList.DrawerKey.Down);
        Assert.True(list.Escape("@Re"));
        Assert.False(list.IsOpen);
        Assert.Null(list.Marked);
        Assert.False(list.Escape("@Re"));   // closed: Escape does what it always does
        Assert.False(list.Update("@Re", "@Re", Members));   // the same words: it stays closed
        Assert.False(list.IsOpen);
        Assert.True(list.Update("@Res", "@Res", Members));   // typing starts over
        Assert.True(list.IsOpen);
        Assert.Null(list.Marked);
    }

    [Fact]
    public void TheSuggestionFollowsTheTextUpToTheCaret()
    {
        var list = new GroupMentionList();
        list.Update("@re and more", "@re", Members);
        Assert.Equal(["research"], list.Rows.Select(r => r.Tag));
    }

    [Fact]
    public void APickReplacesTheWordBeingTyped()
    {
        Assert.Equal(("@research ", 10), GroupMentionList.Insert("@Re", 3, "research", replacingQuery: true));
        Assert.Equal(("hello @research ", 16), GroupMentionList.Insert("hello @Re", 9, "research", replacingQuery: true));
        // Mid-text: the tail keeps its words, without a second space.
        Assert.Equal(("@ivy then", 5), GroupMentionList.Insert("@iv then", 3, "ivy", replacingQuery: true));
    }

    [Fact]
    public void TheHoldMenusMentionAddsTheTagAfterASpace()
    {
        Assert.Equal(("@research ", 10), GroupMentionList.Insert("", 0, "research", replacingQuery: false));
        Assert.Equal(("Thanks @research ", 17), GroupMentionList.Insert("Thanks", 6, "research", replacingQuery: false));
        Assert.Equal(("Thanks @research ", 17), GroupMentionList.Insert("Thanks ", 7, "research", replacingQuery: false));
    }
}
