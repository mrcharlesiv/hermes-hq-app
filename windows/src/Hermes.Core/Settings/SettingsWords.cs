using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Settings' categories in the Mac's Settings window (App/Settings/SettingsRootView.swift `SettingsCategory`), in order.
/// Bots & Tools is not on Windows yet: its pages (Capabilities, Bot Profiles…) are the sidebar's places for now.
public enum SettingsCategory { General, Appearance, Chat, Sounds, Gateway, About }

public static class SettingsCategories
{
    public static readonly SettingsCategory[] All =
        [SettingsCategory.General, SettingsCategory.Appearance, SettingsCategory.Chat, SettingsCategory.Sounds, SettingsCategory.Gateway, SettingsCategory.About];

    public static string Title(this SettingsCategory c) => c switch
    {
        SettingsCategory.General => "General",
        SettingsCategory.Appearance => "Appearance",
        SettingsCategory.Chat => "Chat",
        SettingsCategory.Sounds => "Sounds",
        SettingsCategory.Gateway => "Hermes",
        _ => "About",
    };

    public static string Key(this SettingsCategory c) => c.ToString().ToLowerInvariant();

    public static SettingsCategory? Parse(string? key) => All.Cast<SettingsCategory?>().FirstOrDefault(c => c!.Value.Key() == key);

    /// The Settings window opens on the category it was closed on (as the Mac's does).
    public const string LastCategoryKey = "hqn.settings.lastCategory";
}

/// The words the Settings pages choose (HermesKit/Settings/SettingsWords.swift, ChatRowNotes, the pages' own
/// footers), with the Mac's Windows-named counterparts where the Mac names itself.
public static class SettingsWords
{
    // ---------------------------------------------------------------- About › Clear Model Favorites… (SettingsWords.swift)

    /// [WIN-06a] `clearModelsMessage(favorites:recents:)`: what Clear Favorite & Recent Models? takes away.
    public static string ClearModelsMessage(int favorites, int recents)
    {
        static string Count(int n, string one, string many) => n == 1 ? $"1 {one}" : $"{n} {many}";
        var what = (favorites, recents) switch
        {
            (0, 0) => "No models are starred or recent on this device.",
            (_, 0) => $"Unstars {Count(favorites, "model", "models")}.",
            (0, _) => $"Forgets {Count(recents, "recent model", "recent models")}.",
            _ => $"Unstars {Count(favorites, "model", "models")} and forgets {Count(recents, "recent model", "recent models")}.",
        };
        return what + " Bots, chats and each bot’s default model stay.";
    }

    // ---------------------------------------------------------------- Appearance (App/Settings/Theme/ThemeSettingsView.swift)

    public static string LookNote => $"Draws Hermes HQ like the Hermes desktop app: your theme’s own colors on every screen, square corners and solid bars instead of glass. {DeviceWord.OnlyHere}";
    public const string ContrastNote = "Sets your messages, boxes, lines and secondary text further apart from the page, in your theme’s own colors. For themes that look flat.";
    /// The Mac's note names View › Make Text Bigger (⌘+); Windows has the same keys with Ctrl.
    public static string ScaleNote => $"Makes text, faces and rows larger or smaller, in both looks. Ctrl+Plus and Ctrl+Minus change it too, and Ctrl+0 puts it back. {DeviceWord.OnlyHere}";
    public const string GridNote = "Themes include the Hermes desktop app's themes and app-only options. Light or Dark (set in Appearance) applies on top.";
    public static string OneLookNote(Skin skin) => $"{skin.Label} has one look, so Light and Dark draw the same.";

    /// Appearance's Look group's footer: a one-look skin's forced mode, then the Desktop Look's note.
    public static string LookFooter(ThemeState state)
    {
        var forced = Appearance.ForcedBy(state.Skin);
        var parts = new List<string>();
        if (forced != null) parts.Add($"{state.Skin.Label} has only a {(forced == AppearanceSetting.Dark ? "dark" : "light")} look.");
        parts.Add(LookNote);
        return string.Join(" ", parts);
    }

    // ---------------------------------------------------------------- Chat (ChatRowNotes; ToolCallsSettingsView)

    public const string FewerTimestampsNote = "Shows a day line only when the date changes, and a time only under the bot’s replies.";
    public const string MessageReactionsNote = "Adds Tapbacks to a message’s menu, and lets the bot react to yours.";
    /// SettingsSearch.fileBrowserLabel (UX study #69: was "File Browser").
    public const string FileBrowserLabel = "Files Button in Chats";
    /// [WIN-CHAT-INTRO] SettingsSearch.introSplashLabel (UX study #69: was "Intro Splash").
    public const string IntroSplashLabel = "Greeting on Empty Chats";
    public static string ToolCallStyleFooter => $"Each tool call shows as a step. {DeviceWord.TapCap} a line of steps to list them.";
    public const string AfterReplyFooter = "Hide shows each step while the bot works, then clears them when it replies (as in Telegram). A step that failed stays. To see a reply’s steps again, right-click it and choose Show Steps.";

    // ---------------------------------------------------------------- Sounds

    public const string SoundsFooter = "Completion Sound plays when a bot’s reply finishes.";

    // ---------------------------------------------------------------- Hermes (On Your Gateway)

    public const string SessionsPageTitle = "Archiving & Project Folder";
    public static string GatewayFooter => $"Hermes’ settings, saved on {HostWord.Phrase} so they apply wherever you use Hermes. Other bots keep their own. Voice’s Read Replies Aloud and Send Memo on Release, and the default project folder, are kept on this {DeviceWord.Name}.";
    public static string DefaultFolderFooter => $"New chats start in this folder on {HostWord.Phrase} unless you pick another. Leave it empty to use the folder set in Settings › Workspace › Projects.";
    public const string FolderMissing = "Couldn’t open the folder.";
    public const string FolderFailed = "Couldn’t update the default folder.";

    // ---------------------------------------------------------------- About

    public const string AboutFooter = "Your personal agent, based on Hermes Agent by Nous Research (MIT).";
    public const string SupportUrl = "https://gethermeshq.com/support";
    public const string PrivacyUrl = "https://gethermeshq.com/privacy";

    // ---------------------------------------------------------------- Notifications (App/Notifications/NotificationsSettingsView.swift)

    public static string NotificationsOffFooter(bool outside) =>
        outside ? "Off silences everything above, and Outside Chats below." : "Off silences everything above.";
    public const string PreviewsFooter = "Off, alerts only say who needs you.";
    public const string BannersFooter = "A banner at the top of Hermes HQ when a bot you aren’t looking at finishes a reply.";

    // ---------------------------------------------------------------- Voice (HermesKit/Settings/VoiceSettingsCatalog.swift)

    public static string ReadRepliesHint => $"Speaks each new reply in the chat on screen with the voice below. A voice conversation always speaks its replies. {DeviceWord.OnlyHere}";
    public const string SendOnReleaseHint = "When this is off, letting go stops the recording so you can play it back before sending.";
    /// The Mac's words (a mouse clicks and holds); Windows types by voice with Win+H.
    public static string MemoNote(bool sendOnRelease) => sendOnRelease
        ? "Voice memos: click and hold the mic to record, let go to send. Click it to record hands-free. Type by voice with Windows voice typing (Win+H)."
        : "Voice memos: click and hold the mic to record, let go to play it back before you send. Click it to record hands-free. Type by voice with Windows voice typing (Win+H).";

    // ---------------------------------------------------------------- the gateway card (#64; SettingsRootModel)

    public const string GatewayCardHint = "Opens gateway settings";

    public static string StateWords(GatewayConnection state) => state switch
    {
        GatewayConnection.Ready => "Connected",
        GatewayConnection.Connecting => "Connecting…",
        GatewayConnection.Reconnecting => "Reconnecting…",
        GatewayConnection.Offline => "Offline",
        _ => "Signed Out",
    };

    /// `["9 Bots", "Hermes 0.21.5"]`: the card's facts after the state, each kept on one line.
    public static IReadOnlyList<string> FactPieces(int bots, string? version)
    {
        var pieces = new List<string>();
        if (bots > 0) pieces.Add($"{bots} {(bots == 1 ? "Bot" : "Bots")}");
        if (!string.IsNullOrEmpty(version)) pieces.Add($"Hermes {version}");
        return pieces;
    }

    public static string StatusLine(GatewayConnection state, int bots, string? version) =>
        string.Join(" · ", new[] { StateWords(state) }.Concat(FactPieces(bots, version)));

    /// The card's spoken label: the name and status, then the address only when it says something the name doesn't.
    public static string GatewayCardLabel(string name, string status, string host)
    {
        var same = host.Length == 0 || string.Equals(host, name, StringComparison.OrdinalIgnoreCase);
        return same ? $"{name}, {status}" : $"{name}, {status}, {host}";
    }

    /// The gateway's `/api/status` version as shown: no leading "v", nothing from the first "+" or "-" on.
    public static string CleanVersion(string raw)
    {
        var text = raw.Trim();
        if (text.StartsWith('v') || text.StartsWith('V')) text = text[1..];
        var cut = text.IndexOfAny(['+', '-']);
        return cut >= 0 ? text[..cut] : text;
    }

    /// The gateway's Hermes version from its `/api/status` answer, or null when it doesn't say.
    public static string? Version(JsonNode? status) =>
        status.Str("version") is { } raw && raw.Trim().Length > 0 ? CleanVersion(raw) : null;
}

/// The connection words the gateway card uses (the Mac's `ConnectionState`).
public enum GatewayConnection { Ready, Connecting, Reconnecting, Offline, SignedOut }

/// Settings › Chat switches the Windows app keeps here (App/Settings/AppPreferences.swift): Files Button in Chats.
/// Tool Calls, Fewer Timestamps and Message Reactions are `ChatDisplaySettings` (the transcript feature's).
public static class ChatPrefs
{
    public const string FileBrowserKey = "hqn.fileBrowser";
    public static IPreferences? Store { get; set; }
    /// Raised after a change, for the files feature (a chat's Files button).
    public static event Action? Changed;

    /// Off by default.
    public static bool FileBrowser
    {
        get => Store?.Get(FileBrowserKey) == "true";
        set { Store?.Set(FileBrowserKey, value ? "true" : null); Changed?.Invoke(); }
    }
}

/// Settings › Notifications as stored (HermesKit/Push/NotificationPrefs.swift, the web's `hermes.notificationPrefs`):
/// Enable Notifications, one switch per kind, Show Previews; plus Bot Activity Banners. The notifications feature reads
/// these; the page writes them.
public sealed record NotificationPrefs(bool Enabled, IReadOnlyDictionary<string, bool> Kinds, bool Previews)
{
    public const string Key = "hermes.notificationPrefs";
    public const string BannersKey = "hermes.botActivityBanners";
    /// The kinds, in Settings order, all on by default.
    public static readonly string[] AllKinds = ["approval", "input", "turnDone", "turnError", "backgroundDone", "credits", "plugin"];
    /// "plugin" is stored but has no watcher yet, so it is not drawn.
    public static readonly string[] Shown = [.. AllKinds.Where(k => k != "plugin")];

    public static readonly NotificationPrefs Default = new(true, new Dictionary<string, bool>(), true);

    public bool Allows(string kind) => Enabled && (!Kinds.TryGetValue(kind, out var on) || on);

    public static string Label(string kind) => kind switch
    {
        "approval" => "Approval Needed",
        "input" => "Input Needed",
        "turnDone" => "Response Ready",
        "turnError" => "Turn Failed",
        "backgroundDone" => "Background Task Finished",
        "credits" => "Credit Alerts",
        "plugin" => "Plugin Notifications",
        _ => kind,
    };

    public static string Detail(string kind) => kind switch
    {
        "approval" => "A command is waiting for you to approve or reject it.",
        "input" => "Hermes asked a question or needs a password or secret.",
        "turnDone" => "A bot finished a reply while you were somewhere else.",
        "turnError" => "A reply couldn’t finish.",
        "backgroundDone" => "A backgrounded terminal command completed.",
        "credits" => "Credit access is paused or restored.",
        "plugin" => "A gateway plugin sent a notification.",
        _ => "",
    };

    public static NotificationPrefs Load(IPreferences prefs)
    {
        var raw = J.Parse(prefs.Get(Key) ?? "") as JsonObject;
        if (raw == null) return Default;
        var kinds = new Dictionary<string, bool>();
        if (raw.Obj("kinds") is { } k)
            foreach (var (name, value) in k)
                if (value is JsonValue v && v.TryGetValue(out bool b)) kinds[name] = b;
        return new NotificationPrefs(raw.Bool("enabled") != false, kinds, raw.Bool("previews") != false);
    }

    public void Save(IPreferences prefs)
    {
        var kinds = new JsonObject();
        foreach (var (k, v) in Kinds) kinds[k] = v;
        prefs.Set(Key, new JsonObject { ["enabled"] = Enabled, ["kinds"] = kinds, ["previews"] = Previews }.ToJsonString());
    }

    public NotificationPrefs WithKind(string kind, bool on)
    {
        var kinds = new Dictionary<string, bool>(Kinds) { [kind] = on };
        return this with { Kinds = kinds };
    }

    /// Bot Activity Banners (the reply peek while the app is open). On by default.
    public static bool Banners(IPreferences prefs) => prefs.Get(BannersKey) != "false";
    public static void SetBanners(IPreferences prefs, bool on) => prefs.Set(BannersKey, on ? "true" : "false");
}

/// The voice switches kept on this PC (App/Chat/Voice/TalkController.swift, MemoController.swift), for the voice feature
/// to read: Read Replies Aloud (chosen, else the gateway's, else off) and Send Memo on Release (on by default).
public static class VoicePrefs
{
    public const string ReadRepliesKey = "hq.voice.readRepliesAloud";
    public const string ReadRepliesGatewayKey = "hq.voice.readRepliesAloud.gateway";
    public const string SendOnReleaseKey = "hq.voice.sendOnRelease";

    public static bool ReadsRepliesAloud(IPreferences prefs) =>
        Flag(prefs.Get(ReadRepliesKey)) ?? Flag(prefs.Get(ReadRepliesGatewayKey)) ?? false;

    /// [WIN-62] The switch changed (TalkController.readRepliesAloudChanged): every open chat and Settings show one state.
    /// (the preferences it changed in, on). Raised on the thread that set it.
    public static event Action<IPreferences, bool>? ReadRepliesChanged;

    /// Kept even when unchanged: switching it once, anywhere, is the choice that outranks the gateway
    /// (TalkController.readsRepliesAloud's setter); only a change is told.
    public static void SetReadsRepliesAloud(IPreferences prefs, bool on)
    {
        var was = ReadsRepliesAloud(prefs);
        prefs.Set(ReadRepliesKey, on ? "true" : "false");
        if (was != on) ReadRepliesChanged?.Invoke(prefs, on);
    }

    public static bool SendOnRelease(IPreferences prefs) => Flag(prefs.Get(SendOnReleaseKey)) ?? true;

    public static void SetSendOnRelease(IPreferences prefs, bool on) => prefs.Set(SendOnReleaseKey, on ? "true" : "false");

    private static bool? Flag(string? v) => v switch { "true" => true, "false" => false, _ => null };
}

/// Default Project Folder (HermesKit/Settings/DefaultProjectFolder.swift; docs/spec/3x-settings.md §5): the folder new
/// chats start in, per gateway, kept on this PC. Every `session.create` for a chat the person starts goes through
/// `SessionCreate` (the sessions feature's New Chat).
public static class DefaultProjectFolder
{
    public static IPreferences? Store { get; set; }

    public static string Key(string account, string profile) => $"hqn.defaultProjectFolder.{account}.{profile}";

    public static string? Path(string account, string profile = "default")
    {
        var value = Store?.Get(Key(account, profile))?.Trim();
        return string.IsNullOrEmpty(value) ? null : value;
    }

    public static void Set(string? path, string account, string profile = "default")
    {
        var trimmed = path?.Trim() ?? "";
        Store?.Set(Key(account, profile), trimmed.Length == 0 ? null : trimmed);
    }

    private static volatile string? _active;

    /// The signed-in gateway (the app sets it when the gateway in use changes).
    public static string? ActiveAccount { get => _active; set => _active = value; }

    /// The folder for `profile` on the signed-in gateway, if one is set. Settings has no per-bot view, so the folder set
    /// there is stored under "default" and applies to every bot; one stored for a particular bot wins.
    public static string? Current(string profile) =>
        ActiveAccount is { } account ? Path(account, profile) ?? Path(account, "default") : null;

    /// The gateway's answer to `GET /api/fs/list` is a folder when it has an `entries` array and no `error`.
    public static bool IsFolder(JsonNode? body) =>
        string.IsNullOrEmpty(body.Str("error")) && body.Arr("entries") != null;

    /// Whether `path` is a folder on the computer running Hermes.
    public static async Task<bool> ExistsAsync(Net.GatewaySession session, string path, CancellationToken ct = default) =>
        IsFolder(await session.GetJsonAsync("/api/fs/list", [new("path", path)], TimeSpan.FromSeconds(15), ct));
}

/// `session.create` for a chat the person starts (HermesKit `SessionCreate`): with the default folder when one is set
/// (`cwd` and `cwd_explicit`, so it wins over the profile's own `terminal.cwd`), and always `source: "desktop"`.
public static class SessionCreate
{
    public static JsonObject Params(JsonObject @base, string profile, string? folder = null)
    {
        var p = (JsonObject)@base.DeepClone();
        if (!p.ContainsKey("source")) p["source"] = "desktop";
        if ((folder ?? DefaultProjectFolder.Current(profile)) is { } f)
        {
            p["cwd"] = f;
            p["cwd_explicit"] = true;
        }
        return p;
    }

    /// Swift retries an implicit default folder once without it; an explicit project's folder is never dropped.
    public static async Task<JsonNode> CallAsync(
        Func<string, JsonObject, TimeSpan, CancellationToken, Task<JsonNode>> call,
        JsonObject @base, string profile, TimeSpan timeout, string? folder = null, CancellationToken ct = default)
    {
        var parameters = Params(@base, profile, folder);
        try { return await call("session.create", parameters, timeout, ct); }
        catch (Exception e) when (folder == null && parameters["cwd"] != null && e is not OperationCanceledException && !ct.IsCancellationRequested)
        {
            return await call("session.create", (JsonObject)@base.DeepClone(), timeout, ct);
        }
    }
}
