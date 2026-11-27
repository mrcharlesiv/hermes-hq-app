using System.Text.Json.Nodes;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// File › New Chat Here, Close Chat and Archive Chat (App/Root/KeyCommands.swift at 93f984bb1: `hqNewChatHere`,
/// `hqCloseChat`, `hqArchiveChat` and their `validate` cases; ChatMenus+Actions.swift `canArchive` / `archive`;
/// SessionsOrganizer.swift `newChat(like:)`): when each acts, what it does, and the Windows keys they are on.
public class ChatKeysTests
{
    private static ChatKeyState Chat(bool archived = false, bool online = true) => new(OpenPane.Chat, "otto", "s1", online, archived);
    private static readonly ChatKeyState BotChat = new(OpenPane.BotChat, "otto", "b1");
    private static readonly ChatKeyState Nothing = new(OpenPane.Nothing, null, null);
    private static readonly ChatKeyState Place = new(OpenPane.Place, null, null);

    [Fact]
    public void TheKeysAreCtrlWAndCtrlAltNAndCtrlAltA()
    {
        Assert.Equal(new KeyChord("W", Ctrl: true), ShellKeys.CloseChat);
        Assert.Equal(new KeyChord("N", Ctrl: true, Alt: true), ShellKeys.NewChatHere);
        Assert.Equal(new KeyChord("A", Ctrl: true, Alt: true), ShellKeys.ArchiveChat);
        Assert.Equal("Ctrl+W", ShellKeys.CloseChat.Display);
        Assert.Equal("Ctrl+Alt+N", ShellKeys.NewChatHere.Display);
        Assert.Equal("Control Alt A", ShellKeys.ArchiveChat.Spoken);
    }

    /// None of the four lands on a key something else already registers (Ctrl+Shift+A is Attach Files, Ctrl+N New Chat).
    [Fact]
    public void NoChatKeyCollidesWithAnotherRegisteredKey()
    {
        var chords = KeyShortcuts.Registered.Select(r => r.Chord).ToList();
        foreach (var key in new[] { ShellKeys.CloseChat, ShellKeys.NewChatHere, ShellKeys.ArchiveChat })
            Assert.Single(chords, c => c == key);
        Assert.All(chords.GroupBy(c => c), g => Assert.Single(g));   // no two registrations share a chord
    }

    [Fact]
    public void CloseChatActsOnAChatOrABotsChatAndNeverOnAPlaceOrNothing()
    {
        Assert.True(ChatKeys.CanCloseChat(Chat()));
        Assert.True(ChatKeys.CanCloseChat(BotChat));
        Assert.False(ChatKeys.CanCloseChat(Place));
        Assert.False(ChatKeys.CanCloseChat(Nothing));
    }

    /// `validate`: "Off with no chat of one bot on show (a group chat, a page, nothing open)."
    [Fact]
    public void NewChatHereNeedsAChatOfOneBot()
    {
        Assert.True(ChatKeys.CanNewChatHere(Chat()));
        Assert.True(ChatKeys.CanNewChatHere(BotChat));
        Assert.False(ChatKeys.CanNewChatHere(Nothing));
        Assert.False(ChatKeys.CanNewChatHere(Place));
        Assert.False(ChatKeys.CanNewChatHere(Chat() with { Group = true }));
        Assert.Equal("otto", ChatKeys.NewChatHereProfile(Chat()));
        Assert.Equal("default", ChatKeys.NewChatHereProfile(Chat() with { Profile = "" }));   // `chat.profile.isEmpty ? "default"`
        Assert.Null(ChatKeys.NewChatHereProfile(Nothing));
    }

    /// `canArchive`: the ⋯ menu's Archive (or Unarchive) row, offered and not dimmed: never in a bot's own chat or a task's
    /// chat, never offline (the row is dimmed "Offline"), never with nothing or a page open.
    [Fact]
    public void ArchiveActsWhereTheChatsMenuOffersArchive()
    {
        Assert.Equal(ArchiveStep.Archive, ChatKeys.Archive(Chat()));
        Assert.Equal(ArchiveStep.Unarchive, ChatKeys.Archive(Chat(archived: true)));
        Assert.Equal(ArchiveStep.None, ChatKeys.Archive(BotChat));
        Assert.Equal(ArchiveStep.None, ChatKeys.Archive(Chat() with { TaskChat = true }));
        Assert.Equal(ArchiveStep.None, ChatKeys.Archive(Chat() with { Group = true }));
        Assert.Equal(ArchiveStep.None, ChatKeys.Archive(Chat(online: false)));
        Assert.Equal(ArchiveStep.None, ChatKeys.Archive(Nothing));
        Assert.Equal(ArchiveStep.None, ChatKeys.Archive(Place));
    }

    /// The archive's words are the Mac's: "Archived “title”" (Untitled Chat for no title) with the way back under it, and
    /// the failure titles of the ⋯ menu's Archive.
    [Fact]
    public void ArchiveWordsAreTheMacs()
    {
        Assert.Equal("Archived “Trip planning”", ChatKeys.ArchivedLabel("  Trip planning "));
        Assert.Equal("Archived “Untitled Chat”", ChatKeys.ArchivedLabel("   "));
        Assert.Equal("Archived “Untitled Chat”", ChatKeys.ArchivedLabel(null));
        Assert.Equal("Find it in Filter and Sort › Show › Archived.", SessionStore.ArchivedWayBack);
        Assert.Equal("Couldn’t Archive Chat", ChatKeys.FailureTitle(ArchiveStep.Archive));
        Assert.Equal("Couldn’t Unarchive Chat", ChatKeys.FailureTitle(ArchiveStep.Unarchive));
        Assert.Equal("Archive Chat", ChatKeys.ArchiveTitle(archived: false));
        Assert.Equal("Unarchive Chat", ChatKeys.ArchiveTitle(archived: true));
    }

    /// `newChat(like:)`: the open chat's bot, in the project that holds its folder (Home, so no folder, when none does).
    [Fact]
    public void NewChatHereStartsInTheProjectHoldingTheChatsFolder()
    {
        var byProfile = new Dictionary<string, List<SessionProject>>
        {
            ["otto"] = [new SessionProject("p1", "Site", "/home/me/site", ["/home/me/site"]),
                        new SessionProject("p2", "Notes", "", ["/home/me/notes"])],
        };
        Assert.Equal("/home/me/site", ChatKeys.NewChatHereFolder("/home/me/site/src", "otto", byProfile));
        Assert.Null(ChatKeys.NewChatHereFolder("/home/me/elsewhere", "otto", byProfile));   // Home
        Assert.Null(ChatKeys.NewChatHereFolder(null, "otto", byProfile));
        Assert.Null(ChatKeys.NewChatHereFolder("/home/me/site", "herald", byProfile));      // not this bot's project
        Assert.Null(ChatKeys.NewChatHereFolder("/home/me/notes/a", "otto", byProfile));     // a project with no folder
    }

    /// AltGr is Ctrl+Alt to Windows: with the right Alt key down, Ctrl+Alt+N and Ctrl+Alt+A are a typed ń or ą (Polish,
    /// and other layouts), so the keys pass the press on to the field.
    [Fact]
    public void AltChordsStepAsideForAltGr()
    {
        Assert.True(ChatKeys.Takes(ShellKeys.NewChatHere, rightAltDown: false));
        Assert.False(ChatKeys.Takes(ShellKeys.NewChatHere, rightAltDown: true));
        Assert.False(ChatKeys.Takes(ShellKeys.ArchiveChat, rightAltDown: true));
        Assert.True(ChatKeys.Takes(ShellKeys.CloseChat, rightAltDown: true));
    }

    /// The chat-keys walk's proof: after `mark` the stand-in took one PATCH of the chat with `archived` true.
    [Fact]
    public void TheWalkReadsTheArchiveFromTheStandInsRestLog()
    {
        var state = JsonNode.Parse("""
            {"rest": [
              {"method": "GET", "path": "/api/sessions", "query": ""},
              {"method": "PATCH", "path": "/api/sessions/s1", "query": "profile=default", "body": {"archived": true, "profile": "default"}}
            ]}
            """);
        Assert.Equal(2, ChatKeys.RestCount(state));
        Assert.Null(ChatKeys.ArchivedOverRest(state, 1, "s1", archived: true));
        Assert.Equal("no PATCH of s1 with archived true reached the gateway", ChatKeys.ArchivedOverRest(state, 2, "s1", archived: true));
        Assert.Equal("no PATCH of s1 with archived false reached the gateway", ChatKeys.ArchivedOverRest(state, 0, "s1", archived: false));
        Assert.Equal("no PATCH of s2 with archived true reached the gateway", ChatKeys.ArchivedOverRest(state, 0, "s2", archived: true));
    }
}
