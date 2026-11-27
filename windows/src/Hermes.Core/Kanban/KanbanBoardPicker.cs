namespace Hermes.Core.Kanban;

/// How the board button picks a board (App/Pages/Kanban/KanbanViewController.swift `configureBoardButton`): up to eight
/// boards are a single-selection pop-up menu titled "Boards"; more than eight, the button pushes the "Boards" list
/// (`KanbanBoardListController`) instead.
public enum KanbanBoardPickerStyle { Menu, List }

/// One board as the menu or the list shows it: its read name, "N task(s)" under it when the server counts them, and a
/// tick on the open one.
public sealed record KanbanBoardChoice(string Slug, string Title, string? Subtitle, bool IsCurrent)
{
    /// A Windows menu item has one line: the name, then the count (the Mac's menu subtitle).
    public string MenuText => Subtitle is { } s ? $"{Title}  ·  {s}" : Title;
}

public static class KanbanBoardPicker
{
    /// The most boards the pop-up menu lists (`boards.count > 8` pushes the list).
    public const int MostInMenu = 8;
    /// The most boards the list shows without a search field (`boards.count > 12` adds one).
    public const int MostWithoutSearch = 12;

    public static KanbanBoardPickerStyle StyleFor(int count) => count > MostInMenu ? KanbanBoardPickerStyle.List : KanbanBoardPickerStyle.Menu;

    public static bool ListSearches(int count) => count > MostWithoutSearch;

    /// The boards in the server's order.
    public static IReadOnlyList<KanbanBoardChoice> Choices(IEnumerable<KanbanBoardMeta>? boards, string current) =>
        [.. (boards ?? []).Select(meta => new KanbanBoardChoice(meta.Slug, KanbanModel.BoardTitle(meta.Slug, meta.Name),
            meta.Total is { } t ? KanbanCopy.TaskCount(t) : null, meta.Slug == current))];

    public static IReadOnlyList<KanbanBoardChoice> Choices(KanbanBoards? boards, string current) => Choices(boards?.Boards, current);

    /// The list's search: the trimmed words, lower-cased, inside the board's read name; no words shows every board.
    public static IReadOnlyList<KanbanBoardChoice> Filter(IReadOnlyList<KanbanBoardChoice> choices, string? words)
    {
        var w = (words ?? "").Trim().ToLowerInvariant();
        return w.Length == 0 ? choices : [.. choices.Where(c => c.Title.ToLowerInvariant().Contains(w, StringComparison.Ordinal))];
    }

    /// `pickBoard`: picking the open board does nothing (no search cleared, no read).
    public static bool Switches(string slug, string current) => slug != current;
}

/// The pushed "Boards" list for more than eight boards (`KanbanBoardListController`): every board in order, a tick on the
/// open one, a search field over twelve. A pick switches the board and goes back to the board.
public sealed class KanbanBoardList
{
    private readonly IReadOnlyList<KanbanBoardChoice> _all;

    public KanbanBoardList(IEnumerable<KanbanBoardMeta> boards, string current)
    {
        _all = KanbanBoardPicker.Choices(boards, current);
        Shown = _all;
    }

    public string Title => KanbanCopy.Boards;
    public bool HasSearch => KanbanBoardPicker.ListSearches(_all.Count);
    public string Query { get; private set; } = "";
    public IReadOnlyList<KanbanBoardChoice> Shown { get; private set; }

    public void Search(string? words)
    {
        Query = words ?? "";
        Shown = KanbanBoardPicker.Filter(_all, Query);
    }
}
