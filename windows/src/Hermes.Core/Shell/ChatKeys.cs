using System.Text.Json.Nodes;
using Hermes.Core.Sessions;

namespace Hermes.Core.Shell;

/// What the window's content pane holds when a chat key is pressed: nothing, a place's page, a bot's own chat, or a
/// chat (a session).
public enum OpenPane { Nothing, Place, BotChat, Chat }

/// The facts the chat keys decide on (the Mac's `validate` reads the same from the chat on show and its ⋯ menu).
/// `Group`: a group chat (the Mac's `ChatRoomSurface`, not a `LiveChatSession`); Windows has none yet, so the shell
/// passes false, but the rule is the Mac's. `TaskChat`: a task's chat, which offers no Archive.
public sealed record ChatKeyState(OpenPane Pane, string? Profile, string? StoredId, bool Online = true, bool Archived = false,
    bool TaskChat = false, bool Group = false);

public enum ArchiveStep { None, Archive, Unarchive }

/// File › New Chat Here (⌥⌘N), Close Chat (⌘W) and Archive Chat (⌃⌘A) as App/Root/KeyCommands.swift (93f984bb1) has
/// them: `hqNewChatHere`, `hqCloseChat`, `hqArchiveChat` and their `validate` cases. Windows keys (ShellKeys): Ctrl+Alt+N,
/// Ctrl+W, Ctrl+Alt+A. A key that cannot act does nothing, as the Mac's disabled item does.
///
/// - Close Chat: the chat (or the bot's own chat) leaves the pane, which then shows "No Chat Open", and the sidebar has
///   the keyboard (the Mac pops to the list / empties the right pane). No question first. With nothing open, or a
///   place's page, it does nothing: the Mac's ⌘W then closes the window, and Windows has one window, whose closing
///   quits the app (the Close Window gap).
/// - New Chat Here: a new chat with the open chat's bot, in the project holding its folder (`SessionsOrganizer.newChat
///   (like:)`); off with nothing, a page or a group chat open. It opens in the pane, its message box focused.
/// - Archive Chat: the chat's own ⋯ › Archive (or Unarchive): never a bot's own chat, a task's chat or a group chat,
///   never offline. No question first. Archive: the chat leaves the pane and the lists, "Archived “title”" with the way
///   back and Undo shows, and the sidebar has the keyboard. Unarchive keeps the chat open. Failure: the ⋯ menu's
///   "Couldn’t Archive Chat" / "Couldn’t Unarchive Chat" alert.
public static class ChatKeys
{
    public static bool CanCloseChat(ChatKeyState s) => s.Pane is OpenPane.Chat or OpenPane.BotChat;

    /// `validate`'s newChatHere: "Off with no chat of one bot on show (a group chat, a page, nothing open)."
    public static bool CanNewChatHere(ChatKeyState s) => s.Pane is OpenPane.Chat or OpenPane.BotChat && !s.Group;

    /// `newChat(like:)`: `chat.profile.isEmpty ? "default" : chat.profile`; null when New Chat Here is off.
    public static string? NewChatHereProfile(ChatKeyState s) =>
        !CanNewChatHere(s) ? null : string.IsNullOrEmpty(s.Profile) ? "default" : s.Profile;

    /// The folder New Chat Here starts the chat in: the root of the bot's project that holds the open chat's folder;
    /// null (Home) when none does, or the project has no folder of its own.
    public static string? NewChatHereFolder(string? cwd, string profile, IReadOnlyDictionary<string, List<SessionProject>> byProfile)
    {
        if (SessionProjects.KeyOf(cwd, profile, byProfile) == SessionProjects.HomeKey) return null;
        var id = SessionProject.OwnerOf(cwd, byProfile[profile]);
        var root = byProfile[profile].FirstOrDefault(p => p.Id == id)?.Root.Trim();
        return string.IsNullOrEmpty(root) ? null : root;
    }

    /// `canArchive` (ChatMenus+Actions.swift): the ⋯ menu offers Archive (or Unarchive) and it isn't dimmed.
    public static ArchiveStep Archive(ChatKeyState s) =>
        s.Pane != OpenPane.Chat || s.TaskChat || s.Group || !s.Online || string.IsNullOrEmpty(s.StoredId) ? ArchiveStep.None
        : s.Archived ? ArchiveStep.Unarchive : ArchiveStep.Archive;

    /// The item's name as `validate` gives it.
    public static string ArchiveTitle(bool archived) => archived ? "Unarchive Chat" : "Archive Chat";

    public static string FailureTitle(ArchiveStep step) => step == ArchiveStep.Unarchive ? "Couldn’t Unarchive Chat" : "Couldn’t Archive Chat";

    /// The note after an archive (`UndoPill.show(label:)`), the way back (`SessionStore.ArchivedWayBack`) under it.
    public static string ArchivedLabel(string? title)
    {
        var t = title?.Trim() ?? "";
        return $"Archived “{(t.Length == 0 ? "Untitled Chat" : t)}”";
    }

    /// AltGr reaches Windows as Ctrl+Alt: with the right Alt key down a Ctrl+Alt chord is a typed character (ń, ą on
    /// Polish keyboards), so the key is left to the field.
    public static bool Takes(KeyChord chord, bool rightAltDown) => !(chord.Ctrl && chord.Alt && rightAltDown);

    // ------------------------------------------------------------------ the chat-keys walk's proof (composer stand-in)

    /// How many REST requests a menus-family stand-in's `GET /__menus/state` has logged (`rest`): a mark taken before the
    /// walk acts.
    public static int RestCount(JsonNode? menusState) => (menusState?["rest"] as JsonArray)?.Count ?? 0;

    /// Null when, after the first `mark` entries, the stand-in took a `PATCH /api/sessions/{storedId}` whose body sets
    /// `archived` to `archived` (the sidebar's own archive call, `SessionStore.SetArchivedAsync`); else what is wrong.
    public static string? ArchivedOverRest(JsonNode? menusState, int mark, string storedId, bool archived)
    {
        var rest = (menusState?["rest"] as JsonArray)?.Skip(mark) ?? [];
        var path = SessionWrite.PathOf(storedId);
        foreach (var r in rest.OfType<JsonObject>())
            if (r.Str("method") == "PATCH" && r.Str("path") == path && r["body"] is JsonObject body
                && body["archived"] is JsonValue v && v.TryGetValue(out bool b) && b == archived)
                return null;
        return $"no PATCH of {storedId} with archived {(archived ? "true" : "false")} reached the gateway";
    }
}
