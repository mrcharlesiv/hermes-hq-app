namespace Hermes.Core.Tasks;

// Pure layout, breakpoint, and navigation models for the collapsible Tasks sidebar & overview
// (`App/Pages/Tasks/TasksNavigationViews.swift`, commit 58708c584 / 1da255c07).

public static class TasksNavigationLayout
{
    /// Internal Tasks sidebar width in DIPs.
    public const double SidebarWidth = 216;
    /// Minimum Tasks pane width to display the internal sidebar beside the list; narrower panes (such as when a
    /// task or goal detail pane opens beside Tasks) auto-collapse the sidebar into the bar's view switcher.
    public const double SidebarMinPaneWidth = 640;
    /// Minimum list content width to render the multi-column wide table layout.
    public const double TableMinContentWidth = 760;
    /// Maximum number of suggested tasks shown inline on compact overview before "See all".
    public const int OverviewSuggestedLimit = 3;

    public static bool ShouldShowSidebar(bool isDesktop, double paneWidth, bool userCollapsed, bool hasList, bool needsAddOn) =>
        isDesktop && hasList && !needsAddOn && !userCollapsed && paneWidth >= SidebarMinPaneWidth;

    public static bool ShouldUseTable(bool isDesktop, double contentWidth) =>
        isDesktop && contentWidth >= TableMinContentWidth;

    public static string Title(TodoView view, IReadOnlyList<TodoUserSection> sections) => view.Key switch
    {
        "today" => "Today",
        "upcoming" => "Upcoming",
        "inbox" => "Inbox",
        "goals" => "Goals",
        "suggested" => "Suggested",
        "bots" => "Bots’ Tasks",
        _ when view.ListId is { } id => sections.FirstOrDefault(s => s.Id == id)?.Name ?? "List",
        _ => "Tasks",
    };

    /// SF Symbol name matching the Mac sidebar (mapped to Segoe Fluent glyphs in `TasksSidebarView`).
    public static string Symbol(TodoView view, IReadOnlyList<TodoUserSection> sections) => view.Key switch
    {
        "today" => "sun.max",
        "upcoming" => "calendar",
        "inbox" => "tray",
        "goals" => "smallcircle.filled.circle",
        "suggested" => "sparkle",
        "bots" => "person.2",
        _ when view.ListId is { } id => sections.FirstOrDefault(s => s.Id == id)?.Icon ?? TodoListIcons.Fallback,
        _ => TodoListIcons.Fallback,
    };
}

public sealed record TasksSmartTileModel(TodoView View, string Title, string Symbol, int? Count)
{
    public string Id => View.Key;
    public string Identifier => $"tasks.view.{View.Key}";

    public string Spoken
    {
        get
        {
            if (Count is not { } n) return Title;
            if (View == TodoView.Goals) return $"{Title}, {n} {(n == 1 ? "goal" : "goals")}";
            return $"{Title}, {n} {(n == 1 ? "task" : "tasks")}";
        }
    }
}

public sealed record TasksOverviewListModel(
    string Id,
    string Name,
    string Icon,
    string? Color,
    string? Subtitle,
    int Count,
    int Index,
    int Total)
{
    public string Identifier => $"tasks.view.list.{Name}";

    public string Spoken
    {
        get
        {
            var parts = new List<string> { Name, $"{Count} {(Count == 1 ? "task" : "tasks")}" };
            if (!string.IsNullOrEmpty(Subtitle)) parts.Add(Subtitle);
            return string.Join(", ", parts);
        }
    }
}

public sealed record TasksOverviewSuggestedRowModel(int Count, bool IsOn, bool Looking)
{
    public string Identifier => "tasks.view.suggested";

    public string? Subtitle => Looking ? "Looking for ideas…" : !IsOn ? "Off" : null;

    public string Spoken => Looking
        ? "Suggested, looking for ideas"
        : !IsOn
            ? "Suggested, off"
            : $"Suggested, {Count} {(Count == 1 ? "idea" : "ideas")}";
}

public sealed record TasksOverviewAgentsModel(TasksOverviewSuggestedRowModel? Suggested, int? BotsCount)
{
    public bool IsEmpty => Suggested == null && BotsCount == null;
    public string BotsIdentifier => "tasks.view.bots";
    public string BotsSpoken
    {
        get
        {
            var count = BotsCount ?? 0;
            return $"Bots’ Tasks, {count} {(count == 1 ? "task" : "tasks")}";
        }
    }
}
