using System.Text.Json.Nodes;
using Hermes.Core.Sessions;

namespace Hermes.Core.Shell;

/// What New Chat Here starts: the bot (`session.create`'s `profile`) and the folder (its explicit `cwd`; null: Home, no
/// folder of its own, so the bot's default project folder or none).
public sealed record NewChatHereStart(string Profile, string? Folder);

/// File › New Chat Here (Ctrl+Alt+N, the Mac's ⌥⌘N) from the open chat to the one `session.create`
/// (App/Root/KeyCommands.swift `hqNewChatHere` → App/Sessions/SessionsOrganizer.swift `newChat(like:)` at 93f984bb1):
/// the open chat's bot (`chat.profile.isEmpty ? "default"`), in the project that holds the chat's working directory —
/// that project's root as the chat's explicit folder (`newChat(inProject:profile:)`, the bot holds it) — else Home
/// (`newChat(profile:)`, no folder). Off with nothing, a place's page or a group chat on show.
///
/// The folder the Mac reads is the live chat's (`LiveChatSession.workingDirectory`, `menus.cwd`: the `cwd` of the
/// chat's resume info and `session.info`), not the list's row: a bot's own chat is hidden from the lists, and a chat's
/// folder can move while it is open. Windows reads the open chat's live `ChatSession.Cwd` the same way, and the list row's
/// `cwd` only while the live one isn't known yet.
public static class NewChatHere
{
    /// The chat's working directory as `newChat(like:)` reads it: the live chat's, else its list row's.
    public static string? WorkingDirectory(string? liveCwd, string? rowCwd) =>
        string.IsNullOrWhiteSpace(liveCwd) ? rowCwd : liveCwd;

    /// What the key starts with this chat on show; null when New Chat Here is off (and so nothing is made).
    public static NewChatHereStart? Plan(ChatKeyState state, string? liveCwd, string? rowCwd,
        IReadOnlyDictionary<string, List<SessionProject>> byProfile)
    {
        if (ChatKeys.NewChatHereProfile(state) is not { } profile) return null;
        return new(profile, ChatKeys.NewChatHereFolder(WorkingDirectory(liveCwd, rowCwd), profile, byProfile));
    }

    // ------------------------------------------------------------------ the proof (sessions stand-in's record)

    /// Null when, after the first `mark` calls in a sessions stand-in's `GET /__fixture/state` (`rpc`), New Chat Here made
    /// exactly one `session.create`, for `profile`, with `folder` as its explicit `cwd` (`cwd_explicit` true) — or, for
    /// Home (`folder` null), with no `cwd` at all — from the desktop, and sent nothing into any chat. Else what is wrong.
    public static string? StartedOnce(JsonNode? fixtureState, int mark, string profile, string? folder)
    {
        var after = (fixtureState.Arr("rpc") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).ToList();
        var prompts = after.Select(c => c.Str("method") ?? "").Where(WalkProof.PromptMethods.Contains).ToList();
        if (prompts.Count > 0) return $"New Chat Here sent {string.Join(", ", prompts)} to the gateway";
        var creates = after.Where(c => c.Str("method") == "session.create").ToList();
        if (creates.Count != 1) return $"New Chat Here made {creates.Count} chats, not 1";
        var p = creates[0]["params"];
        if (p.Str("profile") is var made && made != profile) return $"New Chat Here made a chat for {made ?? "no bot"}, not {profile}";
        if (p.Str("source") is var source && source != "desktop") return $"New Chat Here's session.create came from {source ?? "nowhere"}, not desktop";
        var cwd = p.Str("cwd");
        if (folder == null)
            return cwd == null && p?["cwd_explicit"] == null ? null : $"New Chat Here started a Home chat in {cwd ?? "an explicit folder"}";
        if (cwd != folder) return $"New Chat Here made the chat in {cwd ?? "no folder"}, not {folder}";
        if (p?["cwd_explicit"] is not JsonValue v || !v.TryGetValue(out bool explicitCwd) || !explicitCwd)
            return "New Chat Here's session.create didn't mark its folder cwd_explicit";
        return null;
    }

    /// Null when, after `mark`, the stand-in took no `session.create` and no prompt (the key was off). Else what is wrong.
    public static string? StartedNothing(JsonNode? fixtureState, int mark)
    {
        var after = (fixtureState.Arr("rpc") ?? []).OfType<JsonNode>().Skip(Math.Max(0, mark)).Select(c => c.Str("method") ?? "").ToList();
        var made = after.Where(m => m == "session.create" || WalkProof.PromptMethods.Contains(m)).ToList();
        return made.Count == 0 ? null : $"New Chat Here, off, still sent {string.Join(", ", made)}";
    }
}
