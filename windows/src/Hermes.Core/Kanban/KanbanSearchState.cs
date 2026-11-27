namespace Hermes.Core.Kanban;

/// What the board area shows in place of (or as) the columns.
public enum KanbanBoardFace
{
    /// No board read yet, or it could not be read: \"Loading…\" or the failure with Try Again.
    Status,
    /// The columns.
    Columns,
    /// A board with no task at all: \"No Tasks Yet\" and its New Task… button.
    NoTasksYet,
    /// A search that matched nothing: \"No Results for “words”\", no New Task… (the search stays to be undone).
    NoResults,
}

/// The two bar items the empty board takes away: Search and + (New Task).
public readonly record struct KanbanBoardBar(bool SearchShown, bool AddShown)
{
    /// Both on the bar, as the page starts.
    public static KanbanBoardBar Full => new(true, true);
}

/// One render's decisions: the face, the trimmed words it names, whether it offers New Task…, and the bar.
public sealed record KanbanSearchView(KanbanBoardFace Face, string Words, bool OffersNewTask, KanbanBoardBar Bar);

/// The board's search and New Task as KanbanViewController.swift (93f984bb1) decides them in `reload`/`reloadBoard`,
/// `KanbanEmptyView` and `searchShownWhileEmpty`:
/// - the words are the query trimmed (`pgTrim`); a query of spaces is no search;
/// - a board is empty only when it is read, the words are empty and every column is empty; then Search and + leave the
///   bar (the empty state offers New Task…, one place per action) and come back with the first task;
/// - a search that empties the board keeps Search (and +) so it can be undone; its state names the words, no New Task…;
/// - loading or can't load is not an empty board: Search and + are on the bar (the previous board's hidden bar is not
///   kept);
/// - while the search is open (on Windows: its field is being edited) the bar is left as it is, so the field never
///   leaves under the caret; it is reconciled when the editing ends.
public static class KanbanSearchState
{
    /// The words a query searches for.
    public static string Words(string? query) => (query ?? "").Trim();

    /// `query.pgTrim.isEmpty && columns.allSatisfy { $0.tasks.isEmpty }` on a read board.
    public static bool BoardEmpty(KanbanBoard? board, string? query) =>
        board != null && Words(query).Length == 0 && board.Columns.All(c => c.Tasks.Count == 0);

    /// `searchShownWhileEmpty`: an open search leaves the bar as it is; otherwise Search and + show unless the board is
    /// empty.
    public static KanbanBoardBar Bar(bool boardEmpty, bool searchEditing, KanbanBoardBar previous) =>
        searchEditing ? previous : new KanbanBoardBar(!boardEmpty, !boardEmpty);

    /// Every decision of one render. `board` is the board as read (unfiltered); the filter is KanbanModel.Filter.
    public static KanbanSearchView Decide(KanbanBoard? board, string? query, bool searchEditing, KanbanBoardBar previous)
    {
        var words = Words(query);
        var bar = Bar(BoardEmpty(board, query), searchEditing, previous);
        if (board == null) return new KanbanSearchView(KanbanBoardFace.Status, words, false, bar);
        var shown = KanbanModel.Filter(board, query ?? "");
        if (shown.Columns.Any(c => c.Tasks.Count > 0)) return new KanbanSearchView(KanbanBoardFace.Columns, words, false, bar);
        return words.Length > 0
            ? new KanbanSearchView(KanbanBoardFace.NoResults, words, false, bar)
            : new KanbanSearchView(KanbanBoardFace.NoTasksYet, words, true, bar);
    }
}
