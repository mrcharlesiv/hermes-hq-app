using System.Globalization;
using System.Text;

namespace Hermes.Core.Settings;

/// One thing Settings search can find: a page, or a row on a page (HermesKit/Settings/SettingsSearch.swift
/// `SettingsSearchEntry`). `Target` is where it goes: a page id ("theme", "tool-calls", "about", "diagnostics"…), a
/// row ("row:<id>") that the category page scrolls to and marks, or a file action ("action:export" | "action:import" |
/// "action:clear-models" | "action:reset", the Mac's `.action(id)`) that About shows and then runs.
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

    /// The category a target is on (the column marks it while the result shows).
    public static SettingsCategory? Category(string target) => target switch
    {
        "theme" or ChatBubbles.Target or BackdropPrefs.Target or "row:appearance" or "row:desktop-look" or "row:ui-scale" or "row:high-contrast"
            or WorkingRing.RowTarget or DensityRow.RowTarget or ThinkingBarRow.RowTarget or ChatsUnderBotsRow.RowTarget
            or Shell.SidebarPage.Target => SettingsCategory.Appearance,
        "notifications" => SettingsCategory.General,
        "tool-calls" or "row:fewer-timestamps" or "row:attachment-limit" or "row:file-browser" or "row:message-reactions" or "row:intro-splash" => SettingsCategory.Chat,
        "row:completion-sound" or "row:sound" => SettingsCategory.Sounds,
        "gateway" or "voice" or "sessions" or "browser-cloud" => SettingsCategory.Gateway,
        "about" or "diagnostics" or "licenses" or "about:detailed-log" => SettingsCategory.About,
        // SettingsNavigator.open: `.action` jumps to About, whose buttons they are.
        _ when ActionId(target) != null => SettingsCategory.About,
        _ => null,
    };

    /// A file action's target ("action:<id>", the Mac's `Target.action(id)`).
    public const string ActionPrefix = "action:";

    /// The file action a target names ("export", "import", "clear-models", "reset"…), or null when it is a page or a row.
    public static string? ActionId(string target) =>
        target.StartsWith(ActionPrefix, StringComparison.Ordinal) && target.Length > ActionPrefix.Length ? target[ActionPrefix.Length..] : null;

    public static readonly string[] ThemeKeywords =
        ["theme", "skin", "colours", "colors", "desktop themes", "accent", "accent color", "rose pine", "high contrast"];

    /// Everything Settings has on Windows, as the Mac's index words it.
    public static IReadOnlyList<SettingsSearchEntry> Index { get; } =
    [
        new("page:gateway", "Gateway", "", ["gateways", "connection", "address"], "gateway", true),
        new("page:notifications", "Notifications", "", ["alerts", "push", "notify"], "notifications", true),
        new("page:sessions", SettingsWords.SessionsPageTitle, "", ["sessions", "archive", "chats", "project folder", "chat folder", "retention"], "sessions", true),
        new("page:voice", "Voice", "Hermes", ["talk", "read aloud", "voice memo", "speech"], "voice", true),
        new("page:about", "About", "", ["version", "support", "privacy", "build", "app version"], "about", true),
        new("app:diagnostics", "Diagnostics", "About", ["errors", "bug report", "debug", "logs", "connection details", "copy"], "diagnostics"),
        // About opens with the row itself scrolled to and marked ("about:<row>").
        new("app:detailed-log", DetailedLogging.Title, "About", ["logs", "debug", "diagnostics", "verbose"], "about:detailed-log"),
        new("app:share-logs", "Share Logs", "Diagnostics", ["crash", "logs", "zip"], "diagnostics"),
        new("app:theme", "Theme", "Appearance", [.. ThemeKeywords, .. SkinCatalog.All.Select(s => s.Label.ToLowerInvariant())], "theme"),
        new("app:desktop-look", "Desktop Look", "Appearance", ["square corners", "desktop app", "flat"], "row:desktop-look"),
        new("app:high-contrast", "High Contrast", "Theme", ["contrast", "accessibility", "flat themes"], "theme"),
        new("app:working-ring", WorkingRing.Label, "Appearance", ["working animation", "ring", "arc", "outline", "glow", "spinner", "busy", "running", "motion"], WorkingRing.RowTarget),
        // [density] Beside Working Ring and before UI Scale, as the Mac's appRows (so "ui scale" finds Density, then UI Scale).
        new("app:density", DensityRow.Label, "Appearance", ["compact", "dense", "smaller rows", "fit more", "ui scale", "zoom", "smaller text"], DensityRow.RowTarget),
        new("app:ui-scale", "UI Scale", "Theme", ["text size", "bigger text", "smaller text", "larger", "zoom", "make text bigger", "font", "font size", "type size"], "row:ui-scale"),
        // [theme-pages] A row of its own beside Theme, opening its own page (the Mac's next, Message Color, is not on Windows yet).
        new("app:chat-bubbles", ChatBubbles.Label, "Appearance", ["bubble corners", "rounded corners", "message corners", "glass bubbles", "tinted bubbles"], ChatBubbles.Target),
        new("app:appearance", "Light or Dark", "Appearance", ["appearance", "dark", "light", "theme", "mode"], "row:appearance"),
        // [taborder] The Mac's next: Settings › Appearance › Sidebar (`SettingsWords.tabsPageTitle()` on the Mac). Its
        // Kanban entry is not on Windows (no Kanban Tab choice here).
        new("app:tab-order", Shell.SidebarPage.Title, "Appearance", ["tabs", "tab bar", "tab order", "reorder", "rearrange", "organize", "move tabs",
            "sessions first", "sidebar", "hide tabs", "hide bots", "custom tabs", "add a tab", "files tab"], Shell.SidebarPage.Target),
        new("app:backgrounds", BackdropPrefs.Title, "Appearance", ["wallpaper", "background", "chat background", "app background", "solid", "photo", "dim", "blur", "studio matte"], BackdropPrefs.Target),
        new("app:thinking-bar", ThinkingBarRow.Label, "Appearance", ["thinking", "reasoning", "thought", "progress", "bar"], ThinkingBarRow.RowTarget),
        new("app:chats-under-bots", ChatsUnderBotsRow.Label, "Appearance", ["sidebar", "recent chats", "bots", "nested", "limit"], ChatsUnderBotsRow.RowTarget),
        new("app:gateways", "Gateways", "Gateway", ["switch gateway", "add gateway", "another gateway", "accounts", "servers", "connection"], "gateway"),
        new("app:sign-out", "Sign Out", "Gateway", ["log out", "logout", "signout", "account", "disconnect", "connection"], "gateway"),
        new("app:enable-notifications", "Enable Notifications", "Notifications", ["notifications", "alerts", "push", "turn off", "notify"], "notifications"),
        new("app:previews", "Show Previews", "Notifications", ["previews", "alerts", "message text", "lock screen"], "notifications"),
        new("app:banners", "Bot Activity Banners", "Notifications", ["banners", "alerts", "peek", "in-app"], "notifications"),
        new("app:fewer-timestamps", "Fewer Timestamps", "Chat", ["timestamps", "times", "dates", "day line", "clock", SettingsWords.FewerTimestampsNote], "row:fewer-timestamps"),
        new("app:tool-call-style", "Tool Call Style", "Chat", ["tool calls", "steps", "bubbles", "rows", "telegram", "commands"], "tool-calls"),
        new("app:tool-calls", "Tool Calls After Reply", "Chat", ["tool calls", "steps", "hide steps", "keep"], "tool-calls"),
        new("app:attachment-limit", "Largest Attachment", "Chat", ["megabytes", "size", "file size", "limit", "mb", "upload"], "row:attachment-limit"),
        new("app:intro-splash", SettingsWords.IntroSplashLabel, "Chat", ["intro splash", "intro", "greeting", "empty chat", "face", "welcome"], "row:intro-splash"),
        new("app:file-browser", SettingsWords.FileBrowserLabel, "Chat", ["file browser", "files", "folder", "project folder", "workspace"], "row:file-browser"),
        new("app:message-reactions", "Message Reactions", "Chat", ["reactions", "tapback", "tapbacks", "emoji", "react", "like", SettingsWords.MessageReactionsNote], "row:message-reactions"),
        new("app:completion-sound", "Completion Sound", "Sounds", ["sound", "chime", "cue", "reply finished"], "row:completion-sound"),
        new("app:sound", "Sound", "Sounds", ["chime", "preset", "preview", "tone"], "row:sound"),
        new("app:licenses", LicenseNotices.PageTitle, "About", ["licence", "license", "open source"], "licenses"),
        new("app:default-folder", "Default Project Folder", SettingsWords.SessionsPageTitle, ["folder", "directory", "project", "workspace", "cwd", "new chat"], "sessions"),
        new("app:working-directory", "Working Directory", "Hermes", ["default project", "folder", "directory", "cwd", "terminal", "workspace"], "sessions"),
        new("app:new-chat-project", "Ctrl+N Project", "Chat", ["ctrl n", "shortcut", "default project", "folder", "workspace"], "sessions"),
        new("app:auto-archive", AutoArchive.Title, SettingsWords.SessionsPageTitle, ["archive", "old chats", "retention", "inactive"], "sessions"),
        new("app:read-replies", "Read Replies Aloud", "Voice", ["read aloud", "speak replies", "auto speak", "voice", "tts"], "voice"),
        new("app:send-on-release", "Send Memo on Release", "Voice", ["voice memo", "hold to record", "review", "mic"], "voice"),
        new("app:browser-cloud", "Browser Use Cloud", "Hermes", ["browser", "cloud", "chrome", "watch browser", "api key"], "browser-cloud"),
        // SettingsSearch.actions, last as the Mac's index() puts them: About's file buttons, context "About" on the desktop
        // (`actionsContext`), in the Mac's order. [WIN-06d] Clear Model Favorites…, the desktop's label (its button's).
        new("action:export", SettingsFileWords.Export, "About", ["export", "backup", "save settings", "download"], ActionPrefix + "export"),
        new("action:import", SettingsFileWords.Import, "About", ["import", "restore", "load settings", "upload"], ActionPrefix + "import"),
        new("action:clear-models", SettingsFileWords.ClearModels, "About", ["favorites", "favourites", "starred models", "recent models", "unstar", "clear"], ActionPrefix + "clear-models"),
        new("action:reset", SettingsFileWords.Reset, "About", ["reset", "defaults", "factory", "restore defaults"], ActionPrefix + "reset"),
    ];
}
