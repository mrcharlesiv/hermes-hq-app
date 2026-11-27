using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Chat;

/// Where an open chat's first read stands (ChatViewController `openPhase` at 93f984bb1).
public enum ChatOpenPhase { Opening, Failed, Open }

/// What the transcript shows while it has no rows (ChatPlaceholderView.Mode): None (rows, or messages still to come),
/// the page's own loading and failure states, the bot's intro, or nothing drawn with the switch off.
public enum ChatIntroMode { None, Loading, Failed, Empty, Blank }

public static class ChatIntroModeExtensions
{
    /// Only an open, empty chat with the switch on greets.
    public static bool ShowsIntro(this ChatIntroMode mode) => mode == ChatIntroMode.Empty;
}

/// [WIN-CHAT-INTRO] An empty chat's intro (App/Chat/ChatPlaceholderView.swift `.empty`, ChatViewController
/// `updatePlaceholder` / `emptyIntro`) and its switch (AppPreferences.swift `IntroSplash`, docs/spec/3x-settings.md §7):
/// the bot's face, its name, its role and description (each only when it says something new), else
/// "No messages yet. Say hello."; off, the empty chat is blank above the message bar but still says "No messages yet"
/// to a screen reader.
public static class ChatIntro
{
    public const string Key = "hqn.introSplash";
    public const string Fallback = "No messages yet. Say hello.";
    /// What a screen reader hears over an empty chat with the switch off.
    public const string OffLabel = "No messages yet";

    /// The app's preference store (the settings feature sets it at startup).
    public static IPreferences? Store { get; set; }
    /// Raised after the switch changes, so open chats redraw at once (the Mac's `IntroSplash.didChange`).
    public static event Action? Changed;

    /// On unless turned off (absent = on).
    public static bool IsOnIn(IPreferences? store) => store?.Get(Key) != "false";

    /// Saves the switch; true when it changed (then `Changed` is raised). On is stored as absence.
    public static bool SetIn(IPreferences? store, bool on)
    {
        if (store == null || on == IsOnIn(store)) return false;
        store.Set(Key, on ? null : "false");
        Changed?.Invoke();
        return true;
    }

    public static bool IsOn
    {
        get => IsOnIn(Store);
        set => SetIn(Store, value);
    }

    /// Which placeholder fits (updatePlaceholder's precedence): rows win; then a chat still opening; then messages that
    /// exist but aren't rows yet; then a failed open; then a room (it draws its own centre); then the switch.
    public static ChatIntroMode ModeFor(int rows, bool hiddenRows, bool room, ChatOpenPhase phase, bool splashOn)
    {
        if (rows > 0) return ChatIntroMode.None;
        if (phase == ChatOpenPhase.Opening) return ChatIntroMode.Loading;
        if (hiddenRows) return ChatIntroMode.None;
        if (phase == ChatOpenPhase.Failed) return ChatIntroMode.Failed;
        if (room) return ChatIntroMode.None;
        return splashOn ? ChatIntroMode.Empty : ChatIntroMode.Blank;
    }

    /// The role shows only when it differs from the name; the description only when it differs from the role
    /// (`Intro.lines`, `W:src/ui-bots/bot-intro.tsx`).
    public static (string? Role, string? About) Lines(string name, string? role, string? about)
    {
        var title = (role ?? "").Trim();
        var shownRole = title.Length > 0 && !string.Equals(title, name.Trim(), StringComparison.OrdinalIgnoreCase) ? title : null;
        var text = (about ?? "").Trim();
        return (shownRole, text.Length > 0 && text != shownRole ? text : null);
    }

    /// The line under the name (and role): the description, else the greeting.
    public static string Body((string? Role, string? About) lines) => lines.About ?? Fallback;

    /// The bot's name, never the chat's title (ChatViewController `botName`: the details' bot name): the roster's
    /// display name, else the profile's own ("default" is Hermes).
    public static string BotName(string? rosterName, string profile) =>
        rosterName is { } n && n.Trim().Length > 0 ? n.Trim()
            : profile is "" or "default" ? "Hermes" : Bot.TitleCase(profile);

    /// A chat with no name of its own yet (ChatMenus.isUnnamed).
    public static bool IsUnnamed(string? title) =>
        (title ?? "").Trim().ToLowerInvariant() is "" or "new chat" or "untitled chat";

    /// Name Chat shows under the intro (ChatMenus.canName): not the bot's own chat, and still unnamed.
    public static bool CanName(string? title) => title != Bot.BotChatTitle && IsUnnamed(title);
}
