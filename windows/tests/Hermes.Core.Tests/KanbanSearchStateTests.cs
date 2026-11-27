using Hermes.Core.Kanban;

namespace Hermes.Core.Tests;

/// Search and New Task as the board empties (App/Pages/Kanban/KanbanViewController.swift `reload`, `reloadBoard`,
/// `searchShownWhileEmpty` and KanbanRowView.swift `KanbanEmptyView`, 93f984bb1). The decisions are the ones KanbanPage
/// renders with (KanbanSearchState.Decide); the boards are synthetic. The last tests tie the page's Render to them.
public class KanbanSearchStateTests
{
    private static readonly KanbanBoardBar Hidden = new(false, false);

    private static KanbanBoard Board(params (string Status, string Title)[] tasks) =>
        new([.. KanbanModel.StatusOrder.Select(s => new KanbanColumn(s,
            [.. tasks.Where(t => t.Status == s).Select((t, i) => new KanbanTask($"t_{s}_{i}", t.Title, s))]))]);

    private static readonly KanbanBoard Empty = Board();
    private static readonly KanbanBoard Two = Board(("ready", "Draft the release notes"), ("done", "Fix the login bug"));

    // ------------------------------------------------------------------ one state at a time

    [Fact]
    public void ABoardWithTasksShowsItsColumnsWithSearchAndNewTaskOnTheBar()
    {
        var view = KanbanSearchState.Decide(Two, "", searchEditing: false, Hidden);
        Assert.Equal(KanbanBoardFace.Columns, view.Face);
        Assert.False(view.OffersNewTask);
        Assert.Equal(KanbanBoardBar.Full, view.Bar);
    }

    [Fact]
    public void AnEmptyBoardOffersNewTaskInItsStateAndTakesSearchAndPlusOffTheBar()
    {
        var view = KanbanSearchState.Decide(Empty, "", searchEditing: false, KanbanBoardBar.Full);
        Assert.Equal(KanbanBoardFace.NoTasksYet, view.Face);
        Assert.True(view.OffersNewTask);
        Assert.Equal(Hidden, view.Bar);
    }

    [Theory]
    [InlineData(" ")]
    [InlineData("   ")]
    [InlineData("\t \n")]
    public void AQueryOfSpacesIsNoSearchSoTheEmptyBoardsBarMatchesItsState(string spaces)
    {
        // The state said "No Tasks Yet" with New Task… while + and Search stayed (Length > 0): two New Tasks.
        var view = KanbanSearchState.Decide(Empty, spaces, searchEditing: false, KanbanBoardBar.Full);
        Assert.Equal(KanbanBoardFace.NoTasksYet, view.Face);
        Assert.Equal("", view.Words);
        Assert.True(view.OffersNewTask);
        Assert.Equal(Hidden, view.Bar);
        Assert.Equal(view.OffersNewTask, !view.Bar.AddShown);   // one place per action
    }

    [Fact]
    public void AQueryOfSpacesOnABoardWithTasksShowsEveryTask()
    {
        var view = KanbanSearchState.Decide(Two, "  ", searchEditing: false, KanbanBoardBar.Full);
        Assert.Equal(KanbanBoardFace.Columns, view.Face);
        Assert.Equal(KanbanBoardBar.Full, view.Bar);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ASearchWithNoMatchKeepsSearchSoItCanBeCleared(bool editing)
    {
        var view = KanbanSearchState.Decide(Two, "  zebra ", editing, KanbanBoardBar.Full);
        Assert.Equal(KanbanBoardFace.NoResults, view.Face);
        Assert.Equal("zebra", view.Words);
        Assert.Equal(KanbanCopy.NoResults("zebra"), KanbanCopy.NoResults(view.Words));
        Assert.False(view.OffersNewTask);
        Assert.True(view.Bar.SearchShown);
        Assert.True(view.Bar.AddShown);   // the state offers no New Task…, so + stays
    }

    [Fact]
    public void ASearchOnABoardWithNoTaskIsStillASearchToUndo()
    {
        var view = KanbanSearchState.Decide(Empty, "zebra", searchEditing: false, Hidden);
        Assert.Equal(KanbanBoardFace.NoResults, view.Face);
        Assert.False(view.OffersNewTask);
        Assert.Equal(KanbanBoardBar.Full, view.Bar);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void LoadingOrCantLoadIsNotAnEmptyBoardSoThePreviousBoardsHiddenBarComesBack(bool hadQuery)
    {
        // Render returned before touching the bar: an empty board's switch to another left Search and + off while it
        // loaded, and for good if it could not load.
        var view = KanbanSearchState.Decide(null, hadQuery ? "  " : "", searchEditing: false, Hidden);
        Assert.Equal(KanbanBoardFace.Status, view.Face);
        Assert.False(view.OffersNewTask);
        Assert.Equal(KanbanBoardBar.Full, view.Bar);
    }

    [Fact]
    public void WhileTheSearchIsBeingEditedTheBarIsLeftAsItIs()
    {
        // `searchCapsule?.isSearchShown != true`: the field never leaves under the caret.
        Assert.Equal(KanbanBoardBar.Full, KanbanSearchState.Decide(Empty, "", searchEditing: true, KanbanBoardBar.Full).Bar);
        Assert.Equal(KanbanBoardBar.Full, KanbanSearchState.Decide(Empty, "  ", searchEditing: true, KanbanBoardBar.Full).Bar);
        Assert.Equal(KanbanBoardBar.Full, KanbanSearchState.Decide(null, "", searchEditing: true, KanbanBoardBar.Full).Bar);
        // The state is still the board's own: "No Tasks Yet" with New Task….
        Assert.True(KanbanSearchState.Decide(Empty, "  ", searchEditing: true, KanbanBoardBar.Full).OffersNewTask);
    }

    // ------------------------------------------------------------------ transitions

    /// The page's loop: each render starts from the bar the previous one left.
    private static List<KanbanSearchView> Walk(params (KanbanBoard? Board, string Query, bool Editing)[] steps)
    {
        var bar = KanbanBoardBar.Full;
        var views = new List<KanbanSearchView>();
        foreach (var (board, query, editing) in steps)
        {
            var view = KanbanSearchState.Decide(board, query, editing, bar);
            bar = view.Bar;
            views.Add(view);
        }
        return views;
    }

    [Fact]
    public void TheLastTaskLeavingTakesSearchAwayAndTheFirstBringsItBack()
    {
        var views = Walk((Two, "", false), (Empty, "", false), (Two, "", false));
        Assert.Equal([KanbanBoardBar.Full, Hidden, KanbanBoardBar.Full], views.Select(v => v.Bar));
        Assert.Equal([KanbanBoardFace.Columns, KanbanBoardFace.NoTasksYet, KanbanBoardFace.Columns], views.Select(v => v.Face));
    }

    [Fact]
    public void ABoardThatEmptiesUnderAnOpenSearchReconcilesWhenTheEditingEnds()
    {
        var views = Walk((Two, "", true), (Empty, "", true), (Empty, "", false));
        Assert.Equal([KanbanBoardBar.Full, KanbanBoardBar.Full, Hidden], views.Select(v => v.Bar));
    }

    [Fact]
    public void SpacesTypedThenLeftOnAnEmptyingBoardEndWithTheStatesNewTaskAlone()
    {
        var views = Walk((Two, " ", true), (Empty, " ", true), (Empty, " ", false));
        Assert.Equal(Hidden, views[^1].Bar);
        Assert.True(views[^1].OffersNewTask);
    }

    [Fact]
    public void ClearingANoMatchSearchOnAnEmptyBoardLandsOnNoTasksYet()
    {
        var views = Walk((Empty, "zebra", true), (Empty, "", true), (Empty, "", false));
        Assert.Equal(KanbanBoardFace.NoResults, views[0].Face);
        Assert.Equal(KanbanBoardBar.Full, views[0].Bar);
        Assert.Equal(KanbanBoardFace.NoTasksYet, views[2].Face);
        Assert.Equal(Hidden, views[2].Bar);
    }

    [Fact]
    public void SwitchingFromAnEmptyBoardLoadsWithTheFullBarAndTheNewBoardDecides()
    {
        // pickBoard clears the query; the new board loads (Status), then shows.
        var toTasks = Walk((Empty, "", false), (null, "", false), (Two, "", false));
        Assert.Equal([Hidden, KanbanBoardBar.Full, KanbanBoardBar.Full], toTasks.Select(v => v.Bar));
        var toEmpty = Walk((Two, "zebra", false), (null, "", false), (Empty, "", false));
        Assert.Equal([KanbanBoardBar.Full, KanbanBoardBar.Full, Hidden], toEmpty.Select(v => v.Bar));
    }

    // ------------------------------------------------------------------ the real page

    private static string PageSource()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Kanban", "KanbanPage.cs"));
    }

    private static string Method(string source, string signature)
    {
        var start = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(start >= 0, "missing " + signature);
        var open = source.IndexOf('{', start);
        var depth = 0;
        for (var i = open; i < source.Length; i++)
        {
            if (source[i] == '{') depth++;
            else if (source[i] == '}' && --depth == 0) return source[start..(i + 1)];
        }
        throw new InvalidOperationException("unbalanced " + signature);
    }

    [Fact]
    public void ThePageRendersWithTheseDecisionsAndSetsTheBarBeforeTheStatusReturn()
    {
        var page = PageSource();
        var render = Method(page, "private void Render()");
        Assert.Contains("KanbanSearchState.Decide(store.Board, _query, SearchEditing, CurrentBar)", render);
        var bar = render.IndexOf("ApplyBar(view.Bar)", StringComparison.Ordinal);
        var status = render.IndexOf("KanbanBoardFace.Status", StringComparison.Ordinal);
        Assert.True(bar >= 0 && status > bar, "the bar is set before the loading/error return");
        Assert.Contains("newTask: view.OffersNewTask", render);
        Assert.Contains("KanbanCopy.NoResults(view.Words)", render);
        // No second, untrimmed rule for the bar anywhere on the page.
        Assert.DoesNotContain("_query.Length", page);
        Assert.DoesNotContain("_query.Trim()", page);
        Assert.Equal(1, page.Split("_search.Visibility = ").Length - 1);
        Assert.Equal(1, page.Split("_add.Visibility = ").Length - 1);
    }

    [Fact]
    public void EditingIsTheFieldsFocusAndItsEndReconcilesTheBarWithoutRebuildingTheState()
    {
        var page = PageSource();
        Assert.Contains("private bool SearchEditing => _search.FocusState != FocusState.Unfocused;", page);
        var lost = page.IndexOf("_search.LostFocus +=", StringComparison.Ordinal);
        Assert.True(lost >= 0, "the field's LostFocus reconciles the bar");
        var handler = page[lost..page.IndexOf(';', page.IndexOf("ReconcileBar", lost))];
        Assert.DoesNotContain("Render", handler);   // a Render would rebuild New Task… while it is being clicked
        var reconcile = Method(page, "private void ReconcileBar()");
        Assert.Contains("KanbanSearchState.Decide(store.Board, _query, SearchEditing, CurrentBar)", reconcile);
        Assert.Contains("ApplyBar(", reconcile);
    }

    [Fact]
    public void BoardSwitchNewTaskAndReadOnlyRulesStay()
    {
        var page = PageSource();
        var pick = Method(page, "private void PickBoard(string slug)");
        Assert.Contains("_search.Text = \"\";", pick);
        Assert.Contains("_query = \"\";", pick);
        var newTask = Method(page, "private void NewTask()");
        Assert.Contains("if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }", newTask);
        var empty = Method(page, "private UIElement EmptyState(string title, string help, bool newTask)");
        Assert.Contains("Push(KanbanCopy.NewTaskEllipsis, NewTask)", empty);
        Assert.Contains("\"kanban.empty.new\"", empty);
    }
}
