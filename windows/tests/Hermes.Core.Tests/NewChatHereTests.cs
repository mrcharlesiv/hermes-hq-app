using System.Text.Json.Nodes;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// New Chat Here's route from the open chat to its one `session.create` (`Hermes.Core.Shell.NewChatHere`; the Mac's
/// SessionsOrganizer.swift `newChat(like:)` at 93f984bb1), and the check the stand-in tests read its record with.
public class NewChatHereTests
{
    private static readonly Dictionary<string, List<SessionProject>> ByProfile = new()
    {
        ["otto"] = [new SessionProject("p1", "Site", "/home/me/site", ["/home/me/site"]),
                    new SessionProject("p2", "Docs", "/home/me/site/docs", ["/home/me/site/docs"])],
        ["herald"] = [new SessionProject("p3", "Notes", "/home/me/notes", ["/home/me/notes"])],
    };

    private static ChatKeyState Chat(string? profile = "otto") => new(OpenPane.Chat, profile, "s-1");

    [Fact]
    public void TheNewChatKeepsTheBotAndStartsAtTheRootOfTheProjectHoldingTheFolder()
    {
        Assert.Equal(new NewChatHereStart("otto", "/home/me/site"), NewChatHere.Plan(Chat(), "/home/me/site/src/app", null, ByProfile));
        // The longest folder wins: a project inside another one.
        Assert.Equal(new NewChatHereStart("otto", "/home/me/site/docs"), NewChatHere.Plan(Chat(), "/home/me/site/docs/a", null, ByProfile));
        // Its bot's projects only: herald's Notes isn't otto's, so Home.
        Assert.Equal(new NewChatHereStart("otto", null), NewChatHere.Plan(Chat(), "/home/me/notes/x", null, ByProfile));
        Assert.Equal(new NewChatHereStart("herald", "/home/me/notes"), NewChatHere.Plan(Chat("herald"), "/home/me/notes/x", null, ByProfile));
        // No folder known, or one outside every project: Home.
        Assert.Equal(new NewChatHereStart("otto", null), NewChatHere.Plan(Chat(), null, null, ByProfile));
        Assert.Equal(new NewChatHereStart("otto", null), NewChatHere.Plan(Chat(), "/elsewhere", null, ByProfile));
        // A bot with no projects at all, and `chat.profile.isEmpty ? "default"`.
        Assert.Equal(new NewChatHereStart("wren", null), NewChatHere.Plan(Chat("wren"), "/home/me/site", null, ByProfile));
        Assert.Equal(new NewChatHereStart("default", null), NewChatHere.Plan(Chat(""), "/home/me/site", null, ByProfile));
        // A bot's own chat too.
        Assert.Equal(new NewChatHereStart("otto", "/home/me/site"),
            NewChatHere.Plan(new ChatKeyState(OpenPane.BotChat, "otto", "bc"), "/home/me/site", null, ByProfile));
    }

    /// The Mac reads the live chat's folder (`LiveChatSession.workingDirectory`); the list row only stands in before it's known.
    [Fact]
    public void TheLiveFolderComesBeforeTheListRow()
    {
        Assert.Equal("/home/me/site/docs", NewChatHere.Plan(Chat(), "/home/me/site/docs", "/elsewhere", ByProfile)!.Folder);
        Assert.Equal("/home/me/site", NewChatHere.Plan(Chat(), null, "/home/me/site/x", ByProfile)!.Folder);
        Assert.Equal("/home/me/site", NewChatHere.Plan(Chat(), "  ", "/home/me/site/x", ByProfile)!.Folder);
        Assert.Null(NewChatHere.Plan(Chat(), "/elsewhere", "/home/me/site/x", ByProfile)!.Folder);
    }

    [Fact]
    public void OffWithAGroupAPageOrNothing()
    {
        Assert.Null(NewChatHere.Plan(Chat() with { Group = true }, "/home/me/site", null, ByProfile));
        Assert.Null(NewChatHere.Plan(new ChatKeyState(OpenPane.Place, null, null), "/home/me/site", null, ByProfile));
        Assert.Null(NewChatHere.Plan(new ChatKeyState(OpenPane.Nothing, null, null), "/home/me/site", null, ByProfile));
    }

    private static JsonNode State(params JsonObject[] calls) => new JsonObject { ["rpc"] = new JsonArray(calls) };
    private static JsonObject Call(string method, JsonObject? p = null) => new() { ["method"] = method, ["params"] = p ?? new JsonObject() };
    private static JsonObject Create(string profile, string? cwd, bool? explicitCwd = true, string source = "desktop")
    {
        var p = new JsonObject { ["profile"] = profile, ["source"] = source, ["follow_profile_config"] = true };
        if (cwd != null) p["cwd"] = cwd;
        if (cwd != null && explicitCwd != null) p["cwd_explicit"] = explicitCwd;
        return Call("session.create", p);
    }

    [Fact]
    public void TheRecordShowsOneStartWithTheExactBotAndFolder()
    {
        var before = Call("session.resume");
        Assert.Null(NewChatHere.StartedOnce(State(before, Create("otto", "/home/me/site")), 1, "otto", "/home/me/site"));
        Assert.Null(NewChatHere.StartedOnce(State(Create("otto", null)), 0, "otto", null));
        // A start before the mark is not this one's.
        Assert.Equal("New Chat Here made 0 chats, not 1", NewChatHere.StartedOnce(State(Create("otto", "/home/me/site")), 1, "otto", "/home/me/site"));
        Assert.Equal("New Chat Here made 2 chats, not 1",
            NewChatHere.StartedOnce(State(Create("otto", "/home/me/site"), Create("otto", "/home/me/site")), 0, "otto", "/home/me/site"));
        Assert.Equal("New Chat Here made a chat for herald, not otto", NewChatHere.StartedOnce(State(Create("herald", null)), 0, "otto", null));
        Assert.Equal("New Chat Here made the chat in /home/me/site/src, not /home/me/site",
            NewChatHere.StartedOnce(State(Create("otto", "/home/me/site/src")), 0, "otto", "/home/me/site"));
        Assert.Equal("New Chat Here made the chat in no folder, not /home/me/site", NewChatHere.StartedOnce(State(Create("otto", null)), 0, "otto", "/home/me/site"));
        Assert.Equal("New Chat Here's session.create didn't mark its folder cwd_explicit",
            NewChatHere.StartedOnce(State(Create("otto", "/home/me/site", explicitCwd: null)), 0, "otto", "/home/me/site"));
        Assert.Equal("New Chat Here started a Home chat in /home/me/site", NewChatHere.StartedOnce(State(Create("otto", "/home/me/site")), 0, "otto", null));
        Assert.Equal("New Chat Here's session.create came from tui, not desktop",
            NewChatHere.StartedOnce(State(Create("otto", null, source: "tui")), 0, "otto", null));
        Assert.Equal("New Chat Here sent prompt.submit to the gateway",
            NewChatHere.StartedOnce(State(Create("otto", null), Call("prompt.submit")), 0, "otto", null));
    }

    [Fact]
    public void AnOffKeyLeavesNoStartInTheRecord()
    {
        Assert.Null(NewChatHere.StartedNothing(State(Call("session.resume"), Call("projects.tree")), 0));
        Assert.Null(NewChatHere.StartedNothing(State(Create("otto", null), Call("session.resume")), 1));
        Assert.Equal("New Chat Here, off, still sent session.create", NewChatHere.StartedNothing(State(Create("otto", null)), 0));
        Assert.Null(NewChatHere.StartedNothing(null, 0));
    }
}
