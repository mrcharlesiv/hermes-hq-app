using System.Globalization;
using System.Text;

namespace Hermes.Core.Settings;

/// One thing Settings search can find: a page, or a row on a page (HermesKit/Settings/SettingsSearch.swift
/// `SettingsSearchEntry`). `Target` is where it goes: a page id ("theme", "tool-calls", "about", "diagnostics"…), a
/// row ("row:<id>") that the category page scrolls to and marks, or a file action ("action:export" | "action:import" |
/// "action:clear-models" | "action:reset", the Mac's `.action(id)`).
public sealed record SettingsSearchEntry(string Id, string Label, string Context, string[] Keywords, string Target, bool IsPage = false);

/// Settings search (`src/settings-ios-list.tsx` searchResults): every word typed must match; pages come first; one row
/// per label and place; at most 60. The index is the Windows app's own rows, with the Mac's labels and keywords.
public static class SettingsSearch
{
    public static string Normalize(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(decomposed.Length);
        foreach (var c in decomposed)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return string.Join(' ', sb.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant()
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }

    public static IReadOnlyList<SettingsSearchEntry> Results(string query, IEnumerable<SettingsSearchEntry> entries, int limit = 60)
    {
        var terms = Normalize(query).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (terms.Length == 0) return [];
        bool Matches(SettingsSearchEntry e)
        {
            var haystack = Normalize(string.Join(' ', new[] { e.Label, e.Context }.Concat(e.Keywords)));
            return terms.All(haystack.Contains);
        }
        var list = entries.ToList();
        var seen = new HashSet<string>();
        var out_ = new List<SettingsSearchEntry>();
        foreach (var e in list.Where(e => e.IsPage).Concat(list.Where(e => !e.IsPage)))
        {
            if (!Matches(e)) continue;
            if (!seen.Add(Normalize(e.Context) + "\0" + Normalize(e.Label))) continue;
            out_.Add(e);
            if (out_.Count == limit) break;
        }
        return out_;
    }

    /// The category a target is on across the 7 Mac categories (App/Settings/SettingsNavigator.swift `category(of:)`,
    /// SettingsRootView.swift `category(ofRow:)`, e27566897).
    public static SettingsCategory? Category(string target) => target switch
    {
        "theme" or ChatBubbles.Target or BackdropPrefs.Target or "row:appearance" or "row:desktop-look" or "row:ui-scale"
            or "row:high-contrast" or "row:window-transparency" or "row:hermes-corners" or "row:desktop-radius"
            or "row:reply-bubbles" or "row:bot-chats-style"
            or WorkingRing.RowTarget or DensityRow.RowTarget or ThinkingBarRow.RowTarget or ChatsUnderBotsRow.RowTarget
            or Shell.SidebarPage.Target => SettingsCategory.Appearance,
        "notifications" or "proactivity-beta" or "row:completion-sound" or "row:sound" or "sound-picker"
            or "row:resume-last-chat" or "row:tips" => SettingsCategory.General,
        "tool-calls" or "row:fewer-timestamps" or "row:attachment-limit" or "row:file-browser" or "row:message-reactions"
            or "row:intro-splash" or "row:session-strip" or "row:send-while-busy" or "row:new-chat-asks-project"
            or "action:clear-models" => SettingsCategory.Chat,
        "gateway" or "voice" or "sessions" or "browser-cloud" or "models" or "main-model" or "fallback-models"
            or "auxiliary-models" or "moa" or "backup-reset" => SettingsCategory.Gateway,
        "vault" or "providers" or "keys" or "billing" => SettingsCategory.Accounts,
        "capabilities" or "more:profiles" or "more:messaging" or "more:webhooks" or "more:import-sessions"
            or "row:plugin-update-checks" or "row:check-plugin-updates" => SettingsCategory.Tools,
        "about" or "diagnostics" or "licenses" or "about:detailed-log" or "about:perf-log" or "about:mark"
            or "discord" or "row:discord" => SettingsCategory.About,
        // Backup & Reset file actions moved under Hermes (Gateway) on desktop (SettingsNavigator.swift:16).
        _ when ActionId(target) is { } action => action == "clear-models" ? SettingsCategory.Chat : SettingsCategory.Gateway,
        _ => null,
    };

    /// A file action's target ("action:<id>", the Mac's `Target.action(id)`).
    public const string ActionPrefix = "action:";

    /// The file action a target names ("export", "import", "clear-models", "reset"…), or null when it is a page or a row.
    public static string? ActionId(string target) =>
        target.StartsWith(ActionPrefix, StringComparison.Ordinal) && target.Length > ActionPrefix.Length ? target[ActionPrefix.Length..] : null;

    public static readonly string[] ThemeKeywords =
        ["theme", "skin", "colours", "colors", "desktop themes", "accent", "accent color", "rose pine", "high contrast"];

    /// Everything Settings has on Windows, as the Mac's index words it (e27566897, b446e2abf, dcf89ffb1, 517927687).
    public static IReadOnlyList<SettingsSearchEntry> Index { get; } =
    [
        new("page:gateway", "Gateway", "", ["gateways", "connection", "address"], "gateway", true),
        new("page:notifications", "Notifications", "", ["alerts", "push", "notify"], "notifications", true),
        new("page:proactivity-beta", ProactivityBeta.PageLabel, "", ["proactive", "proactivity", "beta", "open loops", "daily brief", "follow up", "anticipation", "calibration", ProactivityBeta.PluginName], "proactivity-beta", true),
        new("page:models", SettingsWords.ModelsLabel, "Hermes", ["model", "main model", "default model", "change model", "fallback models", "fallback", "moa", "mixture of agents"], "models", true),
        new("page:auxiliary-models", SettingsWords.AuxiliaryModelsLabel, "Models", ["auxiliary", "helper", "vision", "compression", "titles", "review", "triage", "curator"], "auxiliary-models", true),
        new("page:sessions", SettingsWords.SessionsPageTitle, "", ["sessions", "archive", "chats", "project folder", "chat folder", "retention"], "sessions", true),
        new("page:voice", "Voice", "Hermes", ["talk", "read aloud", "voice memo", "speech"], "voice", true),
        new("page:vault", "Passwords", "Accounts & Keys", ["vault", "passwords", "logins", "cards", "addresses", "keychain", "credential locker"], "vault", true),
        new("page:providers", "Providers", "Accounts & Keys", ["api keys", "accounts", "sign in", "openai", "anthropic", "openrouter", "custom provider"], "providers", true),
        new("page:keys", "Keys", "Accounts & Keys", ["api keys", "tools", "tokens", "environment", "env"], "keys", true),
        new("page:billing", "Billing", "Accounts & Keys", ["balance", "credits", "plan", "nous portal", "usage"], "billing", true),
        new("page:capabilities", "Capabilities", "Bots & Tools", ["abilities", "skills", "connectors", "plugins", "toolsets", "what bots can do"], "capabilities", true),
        new("more:profiles", "Bot Profiles", "Bots & Tools", ["bots", "personas", "profiles"], "more:profiles", true),
        new("more:messaging", "Messaging", "Bots & Tools", ["telegram", "slack", "whatsapp", "signal", "email", "sms", "platforms"], "more:messaging", true),
        new("more:webhooks", "Webhooks", "Bots & Tools", ["webhook", "hooks", "http", "events"], "more:webhooks", true),
        new("more:import-sessions", "Import Sessions", "Bots & Tools", ["history", "claude code", "codex", "chats"], "more:import-sessions", true),
        new("page:about", "About", "", ["version", "support", "privacy", "build", "app version"], "about", true),
        new("app:diagnostics", "Diagnostics", "About", ["errors", "bug report", "debug", "logs", "connection details", "copy"], "diagnostics"),
        // About opens with the row itself scrolled to and marked ("about:<row>").
        new("app:detailed-log", DetailedLogging.Title, "About", ["logs", "debug", "diagnostics", "verbose"], "about:detailed-log"),
        new("app:share-logs", "Share Logs", "Diagnostics", ["crash", "logs", "zip"], "diagnostics"),
        new("app:discord", CommunityInvite.DiscordLabel, "Community", ["discord", "community", "invite", "server", "feedback", "hermes hq"], "discord"),
        new("app:theme", "Theme", "Appearance", [.. ThemeKeywords, .. SkinCatalog.All.Select(s => s.Label.ToLowerInvariant())], "theme"),
        // Keep "desktop look" as a search keyword alias for "Hermes Look" (SettingsSearch.swift:99).
        new("app:desktop-look", SettingsWords.HermesLookTitle, "Appearance", ["native", "native look", "look", "desktop look", "desktop app", "square corners", "flat"], "row:desktop-look"),
        new("app:window-transparency", SettingsWords.WindowTransparencyLabel, "Appearance", ["transparency", "translucent", "glass", "frosted", "vibrancy", "opaque", "solid", "window", "sidebar", "mica", "acrylic"], "row:window-transparency"),
        new("app:high-contrast", "High Contrast", "Appearance", ["contrast", "accessibility", "borders", "crisp", "flat themes", "hermes look", "desktop look"], "row:high-contrast"),
        new("app:hermes-corners", SettingsWords.HermesCornersLabel, "Appearance", ["border radius", "corner radius", "corners", "rounded", "boxy", "square", "hermes corners", "hermes look", "desktop look"], "row:hermes-corners"),
        new("app:working-ring", WorkingRing.Label, "Appearance", ["working animation", "ring", "arc", "outline", "glow", "spinner", "busy", "running", "motion"], WorkingRing.RowTarget),
        // [density] Beside Working Ring and before UI Scale, as the Mac's appRows (so "ui scale" finds Density, then UI Scale).
        new("app:density", DensityRow.Label, "Appearance", ["compact", "dense", "smaller rows", "fit more", "ui scale", "zoom", "smaller text"], DensityRow.RowTarget),
        new("app:ui-scale", "UI Scale", "Theme", ["text size", "bigger text", "smaller text", "larger", "zoom", "make text bigger", "font", "font size", "type size"], "row:ui-scale"),
        // [theme-pages] Immediately after UI Scale as the Mac's index.
        new("app:chat-bubbles", ChatBubbles.Label, "Appearance", ["bubble corners", "rounded corners", "message corners", "glass bubbles", "tinted bubbles"], ChatBubbles.Target),
        new("app:reply-bubbles", SettingsWords.ReplyBubblesLabel, "Chat Bubbles", ["reply bubbles", "plain replies", "bot bubbles", "no bubble", "full width"], "row:reply-bubbles"),
        new("app:appearance", "Light or Dark", "Appearance", ["appearance", "dark", "light", "theme", "mode"], "row:appearance"),
        // [taborder] Immediately after Light or Dark as the Mac's index.
        new("app:tab-order", Shell.SidebarPage.Title, "Appearance", ["tabs", "tab bar", "tab order", "reorder", "rearrange", "organize", "move tabs",
            "sessions first", "sidebar", "hide tabs", "hide bots", "custom tabs", "add a tab", "files tab"], Shell.SidebarPage.Target),
        new("app:backgrounds", BackdropPrefs.Title, "Appearance", ["wallpaper", "background", "chat background", "app background", "solid", "photo", "dim", "blur", "studio matte"], BackdropPrefs.Target),
        new("app:thinking-bar", ThinkingBarRow.Label, "Appearance", ["thinking", "reasoning", "thought", "progress", "bar"], ThinkingBarRow.RowTarget),
        new("app:chats-under-bots", ChatsUnderBotsRow.Label, "Appearance", ["sidebar", "recent chats", "bots", "nested", "limit"], ChatsUnderBotsRow.RowTarget),
        new("app:bot-chats-style", SettingsWords.BotChatsStyleLabel, "Appearance", ["branch", "arrows", "splines", "quill", "dots", "rail", "line", "dividers", "chats under bots", "connector"], "row:bot-chats-style"),
        new("app:gateways", "Gateways", "Gateway", ["switch gateway", "add gateway", "another gateway", "accounts", "servers", "connection"], "gateway"),
        new("app:sign-out", "Sign Out", "Gateway", ["log out", "logout", "signout", "account", "disconnect", "connection"], "gateway"),
        new("app:enable-notifications", "Enable Notifications", "Notifications", ["notifications", "alerts", "push", "turn off", "notify"], "notifications"),
        new("app:previews", "Show Previews", "Notifications", ["previews", "alerts", "message text", "lock screen"], "notifications"),
        new("app:banners", "Bot Activity Banners", "Notifications", ["banners", "alerts", "peek", "in-app"], "notifications"),
        new("app:resume-last-chat", SettingsWords.ResumeLastChatLabel, "General", ["resume", "restore", "last session", "startup", "launch"], "row:resume-last-chat"),
        new("app:tips", SettingsWords.InAppTipsLabel, "General", ["tips", "hints", "help"], "row:tips"),
        new("app:fewer-timestamps", "Fewer Timestamps", "Chat", ["timestamps", "times", "dates", "day line", "clock", SettingsWords.FewerTimestampsNote], "row:fewer-timestamps"),
        new("app:tool-call-style", "Tool Call Style", "Chat", ["tool calls", "steps", "bubbles", "rows", "telegram", "commands"], "tool-calls"),
        new("app:tool-calls", "Tool Calls After Reply", "Chat", ["tool calls", "steps", "hide steps", "keep"], "tool-calls"),
        new("app:attachment-limit", "Largest Attachment", "Chat", ["megabytes", "size", "file size", "limit", "mb", "upload"], "row:attachment-limit"),
        new("app:intro-splash", SettingsWords.IntroSplashLabel, "Chat", ["intro splash", "intro", "greeting", "empty chat", "face", "welcome"], "row:intro-splash"),
        new("app:file-browser", SettingsWords.FileBrowserLabel, "Chat", ["file browser", "files", "folder", "project folder", "workspace"], "row:file-browser"),
        new("app:session-strip", SettingsWords.SessionStripLabel, "Chat", ["session strip", "sessions", "chats", "switch chats", "pills", "top bar", "move between chats", "other sessions"], "row:session-strip"),
        new("app:send-while-busy", SettingsWords.SendWhileBusyLabel, "Chat", ["steer", "queue", "send mode", "busy", "while running", "interrupt", SettingsWords.SendWhileBusyNote], "row:send-while-busy"),
        new("app:new-chat-asks-project", SettingsWords.NewChatAsksProjectLabel, "Chat", ["new chat", "project", "no project", "ask", "choose project", "folder", SettingsWords.NewChatAsksProjectNote], "row:new-chat-asks-project"),
        new("app:message-reactions", "Message Reactions", "Chat", ["reactions", "tapback", "tapbacks", "emoji", "react", "like", SettingsWords.MessageReactionsNote], "row:message-reactions"),
        new("app:completion-sound", "Completion Sound", "General", ["sound", "chime", "cue", "reply finished"], "row:completion-sound"),
        new("app:sound", "Sound", "General", ["chime", "preset", "preview", "tone"], "row:sound"),
        new("app:licenses", LicenseNotices.PageTitle, "About", ["licence", "license", "open source"], "licenses"),
        new("app:default-folder", "Default Project Folder", SettingsWords.SessionsPageTitle, ["folder", "directory", "project", "workspace", "cwd", "new chat"], "sessions"),
        new("app:working-directory", "Working Directory", "Hermes", ["default project", "folder", "directory", "cwd", "terminal", "workspace"], "sessions"),
        new("app:new-chat-project", "Ctrl+N Project", "Chat", ["ctrl n", "shortcut", "default project", "folder", "workspace"], "sessions"),
        new("app:auto-archive", AutoArchive.Title, SettingsWords.SessionsPageTitle, ["archive", "old chats", "retention", "inactive"], "sessions"),
        new("app:read-replies", "Read Replies Aloud", "Voice", ["read aloud", "speak replies", "auto speak", "voice", "tts"], "voice"),
        new("app:send-on-release", "Send Memo on Release", "Voice", ["voice memo", "hold to record", "review", "mic"], "voice"),
        new("app:browser-cloud", "Browser Use Cloud", "Hermes", ["browser", "cloud", "chrome", "watch browser", "api key"], "browser-cloud"),
        // SettingsSearch.actions, last as the Mac's index() puts them (e27566897): Backup & Reset lives under Hermes,
        // Clear Model Favorites lives under Chat.
        new("action:export", SettingsFileWords.Export, "Hermes", ["export", "backup", "save settings", "download"], ActionPrefix + "export"),
        new("action:import", SettingsFileWords.Import, "Hermes", ["import", "restore", "load settings", "upload"], ActionPrefix + "import"),
        new("action:clear-models", SettingsFileWords.ClearModels, "Chat", ["favorites", "favourites", "starred models", "recent models", "unstar", "clear"], ActionPrefix + "clear-models"),
        new("action:reset", SettingsFileWords.Reset, "Hermes", ["reset", "defaults", "factory", "restore defaults"], ActionPrefix + "reset"),
    ];
}
