namespace Hermes.Core.Composer;

/// The new chat `/new` opens: its bot, its stored id, and the words typed after the command for its message box.
public sealed record NewChatOpening(string Profile, string StoredId, string Draft);

/// `/new` (`/reset`, `/clear`; docs/spec/3x-composer.md §8.2, the Mac's `AppModel.openNewChat(like:draft:replacing:)`):
/// a fresh chat with this chat's bot, made as Bots › New Chat makes one, put in this chat's place with the rest of the
/// line in its message box. Nothing is sent: the old chat gets no request and no output row, and the new one waits for
/// its first send. A bot the app doesn't know opens nothing (the dispatcher then shows `SlashResults.NewChatFailed`).
public static class NewChatCommand
{
    /// The title a new chat opens under (Bots › New Chat's).
    public const string Title = "New Chat";

    /// The `SlashHooks.NewChat` body. `knowsBot`: the roster has this profile; `create`: the gateway's new chat (the
    /// Sessions store's `NewChatAsync`), its stored id; `open`: shows it in this chat's place; `failed`: the make
    /// failed (the caller words it as Bots › New Chat does). Null when nothing could open (an unknown bot); otherwise
    /// the running make, which never throws.
    public static Task? Start(string profile, string arg, Func<string, bool> knowsBot, Func<string, Task<string>> create,
        Action<NewChatOpening> open, Action<Exception> failed)
    {
        if (profile.Length == 0 || !knowsBot(profile)) return null;
        var draft = arg.Trim();
        return Run();

        async Task Run()
        {
            string id;
            try { id = await create(profile); }
            catch (Exception e) { failed(e); return; }
            open(new NewChatOpening(profile, id, draft));
        }
    }
}
