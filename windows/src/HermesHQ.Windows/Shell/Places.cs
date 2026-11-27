using Hermes.Core.BotPages;
using Hermes.Core.QuickActions;
using HermesHQ.Pages;

namespace HermesHQ.Shell;

/// Where a sidebar row goes. The Mac sidebar's places (App/Mac/MacSidebar.swift) and More's pages
/// (App/Pages/More/Kit/MorePages.swift), in the same order and with the same names.
public sealed record Place(string Id, string Title, string Glyph, string Section, Type Page, string[] Keywords)
{
    /// Each feature registers its page here, replacing the placeholder.
    public Type Page { get; set; } = Page;
    public Func<bool, Microsoft.UI.Xaml.FrameworkElement?>? Badge { get; set; }
    public Func<string?>? BadgeAccessibility { get; set; }
}

public static class Places
{
    public static event Action? BadgesChanged;
    public static void InvalidateBadges() => BadgesChanged?.Invoke();
    public const string Main = "main", Tools = "tools";

    /// Segoe Fluent Icons glyphs standing in for the Mac's SF Symbols.
    public static readonly List<Place> All =
    [
        new("sessions", "Sessions", "", Main, typeof(SessionsPage), ["chats", "history"]),
        new("jobs", "Jobs", "", Main, typeof(PlaceholderPage), ["cron", "schedule"]),
        new("artifacts", "Artifacts", "", Main, typeof(PlaceholderPage), ["files", "images"]),
        // First ordinary Tool, not a forced sidebar preference. The old name still finds this same place.
        new(QuickTileStore.RowID, "Favorites", "\uE735", Tools, typeof(PlaceholderPage),
            [.. MoreSearch.PageKeywords["favorites"], "Quick Actions", "tiles", "actions", "quick"]),
        new("tasks", "Tasks", "", Tools, typeof(PlaceholderPage), ["todo"]),
        new("files", "Files", "", Tools, typeof(PlaceholderPage), ["folder", "browse"]),
        new("review", "Changes", "", Tools, typeof(PlaceholderPage), ["diff", "review", "git"]),
        new("terminal", "Terminal", "", Tools, typeof(PlaceholderPage), ["shell", "console"]),
        new("kanban", "Kanban", "", Tools, typeof(PlaceholderPage), ["board", "tasks"]),
        new("tiles", "Tiles", "", Tools, typeof(PlaceholderPage), ["dashboard"]),
        new("command-center", "Status & Maintenance", "", Tools, typeof(PlaceholderPage), ["status", "logs", "doctor"]),
        new("usage", "Usage", "", Tools, typeof(PlaceholderPage), ["cost", "tokens", "limits"]),
        new("spawn-tree", "Spawn Tree", "", Tools, typeof(PlaceholderPage), ["subagents", "helpers"]),
        new("star-map", "Star Map", "", Tools, typeof(PlaceholderPage), ["memory", "skills"]),
        new("marketplace", "Marketplace", "", Tools, typeof(PlaceholderPage), ["plugins", "store"]),
        new("profiles", "Bot Profiles", "", Tools, typeof(PlaceholderPage), ["soul", "persona"]),
        new("messaging", "Messaging", "", Tools, typeof(PlaceholderPage), ["telegram", "whatsapp", "slack"]),
        new("capabilities", "Capabilities", "", Tools, typeof(PlaceholderPage), ["skills", "connectors", "tools"]),
        new("webhooks", "Webhooks", "", Tools, typeof(PlaceholderPage), ["hooks", "triggers"]),
        new("import-sessions", "Import Sessions", "", Tools, typeof(PlaceholderPage), ["claude", "codex"]),
        new("settings", "Settings", "", Tools, typeof(PlaceholderPage), ["preferences", "appearance"]),
    ];

    public static Place Get(string id) => All.First(p => p.Id == id);

    /// A feature claims its place: Places.Register("jobs", typeof(JobsPage)).
    public static void Register(string id, Type page) => Get(id).Page = page;
}
