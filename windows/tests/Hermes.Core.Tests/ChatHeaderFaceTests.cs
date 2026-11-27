using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Heads;
using Hermes.Core.Model;

namespace Hermes.Core.Tests;

/// [WIN-37] The chat header's face (AppModel.makeChatScreen at 93f984bb1): `HeadView.configure(raw: model.head,
/// profile: model.profile)`, shown only when the chat is a bot's own (`isBotChat`: `menus.isBotChat || title ==
/// "Bot Chat"`; [session-title-clean] "a session's title has no face"). Windows drew every header's face from the
/// chat's title, so a chat just started from New Chat With… on Research wore the default head of "New Chat" (green)
/// instead of nothing; and a bot chat with a saved head wore its name's default instead of the head it saved.
public class ChatHeaderFaceTests
{
    private static readonly JsonNode GrapeHead =
        JsonNode.Parse("""{"theme":"shape","v":6,"color":"grape","form":"square","look":"dots","seed":3}""")!;

    private static Bot Research(JsonNode? head = null) =>
        new("research", "Research", null, null, false, false, false, null, false, null, null) { HeadRaw = head };

    private static Func<string, Bot?> Roster(params Bot[] bots) => p => bots.FirstOrDefault(b => b.Name == p);

    [Fact]
    public void ANewChatStartedOnABotHasNoFaceInItsTitle()
    {
        // The CI shot 40-new-chat-sheet-started: profile "research", title "New Chat". The title's default head is not
        // Research's (the green face in the shot), and the Mac draws no face over a session's title at all.
        Assert.NotEqual(HeadStore.HeadOf(Research(GrapeHead)).Color, Head.DefaultHead("New Chat").Color);
        Assert.Null(ChatHeaderFace.For("research", "New Chat", botChat: false, Roster(Research(GrapeHead))));
    }

    [Fact]
    public void ABotsOwnChatWearsThatBotsHead()
    {
        var bot = Research(GrapeHead);
        var face = ChatHeaderFace.For("research", "Research", botChat: true, Roster(bot));
        Assert.NotNull(face);
        Assert.Equal("research", face.Profile);
        Assert.Same(bot, face.Bot);
        Assert.Equal(HeadColor.Grape, face.Head.Color);
        Assert.Equal(HeadStore.HeadOf(bot), face.Head);
    }

    [Fact]
    public void ABotChatIsKnownByItsTitleToo()
    {
        // `isBotChat`: the menus' flag, or the title "Bot Chat".
        var face = ChatHeaderFace.For("research", Bot.BotChatTitle, botChat: false, Roster(Research()));
        Assert.NotNull(face);
        Assert.Equal(Head.DefaultHead("research"), face.Head);
    }

    [Fact]
    public void ABotNotInTheRosterWearsItsProfilesDefaultNotItsTitles()
    {
        var face = ChatHeaderFace.For("wren", "Wren's Notes", botChat: true, Roster());
        Assert.NotNull(face);
        Assert.Null(face.Bot);
        Assert.Equal("wren", face.Profile);
        Assert.Equal(Head.DefaultHead("wren"), face.Head);
    }
}
