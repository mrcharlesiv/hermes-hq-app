using Hermes.Core.Settings;

namespace Hermes.Core.Shell;

/// [WIN-49] The "selection-and-bars" walk's checks (Services/ProofWalks.SelectionAndBars.cs): the sidebar's marked bot
/// row with the window in front is the Mac's accent box (DesktopLook, App/Mac/MacSelection.swift), and the Sessions and
/// Tasks bars are the Mac's page bar (App/Mac/MacWindow.swift `pageBar`). Each returns null when so, else what is wrong.
public static class SelectionAndBarsWalkProof
{
    /// Sessions' bar items, leading to trailing, as the Mac shows them (Filter · New Chat · Search at the edge).
    public static readonly string[] SessionsBar = ["sessions.filter", "sessions.compose", "sessions.search"];

    /// Tasks' bar items before its search field (the Mac's New Task and Search at the bar's end; ⋯ inside them).
    public static readonly string[] TasksBar = ["tasks.more", "tasks.new", "tasks.search"];

    /// [WIN-50] Jobs' bar with more than one bot (App/Pages/Jobs/JobRowView.swift `update(scope:)` on the Mac:
    /// [search] + [New Job] + [All Bots ⌄], read trailing inward): All Bots ⌄ · New Job · Search at the edge.
    public static readonly string[] JobsBar = ["jobs.scope", "jobs.new", "jobs.search"];

    /// [WIN-50] Kanban's bar (App/Pages/Kanban/KanbanViewController.swift: [New Task, Search, How Kanban Works] trailing
    /// inward, then `DesktopBars.searchToEdge`): How Kanban Works · New Task · Search at the edge.
    public static readonly string[] KanbanBar = ["kanban.about", "kanban.new", "kanban.search"];

    const double Tolerance = 0.5 / 255;

    /// The marked row's fill: the chosen-row accent at the Mac's share while emphasized, the grey otherwise.
    public static string? MarkFill(Rgba shown, Rgba chosenRow, Rgba label, bool dark, bool emphasized)
    {
        var want = emphasized ? DesktopLook.Accent(chosenRow, dark) : DesktopLook.Grey(label, dark);
        return Close(shown, want) ? null
            : $"the marked row is {Describe(shown)}, not the Mac's {(emphasized ? "accent" : "grey")} {Describe(want)}";
    }

    /// The marked row's box: no leading bar, the look's corner, inset 2 top and foot.
    public static string? MarkShape(bool leadingBar, double radius, double insetTop, double insetBottom, bool desktopLook)
    {
        if (leadingBar != DesktopLook.LeadingIndicator) return "the marked row has a leading accent bar (the Mac's mark is the box alone)";
        if (Math.Abs(radius - DesktopLook.MarkRadius(desktopLook)) > 0.01) return $"the mark's corner is {radius}, not {DesktopLook.MarkRadius(desktopLook)}";
        if (Math.Abs(insetTop - DesktopLook.MarkInsetTop) > 0.01 || Math.Abs(insetBottom - DesktopLook.MarkInsetBottom) > 0.01)
            return $"the mark is inset {insetTop} over and {insetBottom} under, not {DesktopLook.MarkInsetTop} and {DesktopLook.MarkInsetBottom}";
        return null;
    }

    /// A page's bar: its title's size and weight, and its items in the Mac's order (ids leading to trailing).
    public static string? Bar(string page, double titleSize, int titleWeight, IReadOnlyList<string> shown, IReadOnlyList<string> expected, bool desktopLook)
    {
        if (Math.Abs(titleSize - DesktopLook.PageTitleSize(desktopLook)) > 0.01)
            return $"{page}'s title is {titleSize} pt, not {DesktopLook.PageTitleSize(desktopLook)}";
        if (titleWeight != DesktopLook.PageTitleWeight) return $"{page}'s title weighs {titleWeight}, not {DesktopLook.PageTitleWeight}";
        var want = DesktopLook.BarOrder(expected);
        return shown.SequenceEqual(want) ? null : $"{page}'s bar reads {string.Join(" · ", shown)}, not {string.Join(" · ", want)}";
    }

    static bool Close(Rgba a, Rgba b) =>
        Math.Abs(a.R - b.R) <= Tolerance && Math.Abs(a.G - b.G) <= Tolerance && Math.Abs(a.B - b.B) <= Tolerance && Math.Abs(a.A - b.A) <= 0.01;

    static string Describe(Rgba c) => $"rgba({Rgba.Byte(c.R)},{Rgba.Byte(c.G)},{Rgba.Byte(c.B)},{c.A:0.##})";
}
