using System.Text.Json.Nodes;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// Dragging a task up or down its list (App/Pages/Tasks/TasksViewController.swift at 93f984bb1, "MARK: Drag a task up or
/// down its list": `canArrange`, `itemsForBeginning`, `dropIndex`, `dropSessionDidUpdate` with `dropPlace`,
/// `performDropWith`; HermesKit TasksStore.swift `move(_:to:position:)`, TodoModel.swift `position(between:and:)`).
public class TasksDragReorderTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 9, 41, 0, TimeSpan.FromHours(-6));

    private static TodoTask T(string id, double position, string status = "open") =>
        TodoTask.From(TodoEdits.Reparse(new JsonObject { ["id"] = id, ["title"] = id, ["status"] = status, ["section"] = "work", ["position"] = position }))!;

    [Fact]
    public void OnlyAnOpenTaskOfAListOnShowLifts()
    {
        // `itemsForBeginning`: canArrange, a task, and not done.
        var open = T("a", 1);
        var done = T("d", 2, status: "done");
        Assert.True(TodoArrange.CanLift(open, TodoView.List("work"), searching: false, selecting: false, readOnly: false));
        Assert.False(TodoArrange.CanLift(done, TodoView.List("work"), false, false, false));
        Assert.False(TodoArrange.CanLift(open, TodoView.Today, false, false, false));
        Assert.False(TodoArrange.CanLift(open, TodoView.List("work"), true, false, false));
        Assert.False(TodoArrange.CanLift(open, TodoView.List("work"), false, true, false));
        Assert.False(TodoArrange.CanLift(open, TodoView.List("work"), false, false, true));
        Assert.False(TodoArrange.CanLift(null, TodoView.List("work"), false, false, false));
    }

    [Fact]
    public void ADropLandsOnlyAmongTheListsOpenRows()
    {
        string[] open = ["a", "b", "c"];
        // Over a row's upper half: its own place; its lower half: the place under it (the Windows rows' stand-in for
        // UIKit's destination index path in the `.group(.open)` section).
        Assert.Equal(0, TodoArrange.DropIndex(open, "a", pointerY: 3, rowHeight: 40));
        Assert.Equal(1, TodoArrange.DropIndex(open, "a", 30, 40));
        Assert.Equal(2, TodoArrange.DropIndex(open, "c", 20, 40));   // the middle is still the upper half
        Assert.Equal(3, TodoArrange.DropIndex(open, "c", 21, 40));   // under the last: the end
        // Anywhere else (a Done row, a heading, another view's row) is no place: `.forbidden`.
        Assert.Null(TodoArrange.DropIndex(open, "done-1", 3, 40));
        Assert.Null(TodoArrange.DropIndex([], "a", 3, 40));
        // A row with no height yet reads as its upper half.
        Assert.Equal(1, TodoArrange.DropIndex(open, "b", 5, 0));
    }

    [Fact]
    public void ThePlaceTicksEachTimeItMovesButNotWhereTheTaskWasPickedUp()
    {
        var place = new TodoDropPlace();
        Assert.Null(place.Current);
        Assert.False(place.Update(2));   // the first place is where the task was picked up
        Assert.Equal(2, place.Current);
        Assert.False(place.Update(2));   // the same place: no tick
        Assert.True(place.Update(3));    // a new place: a tick
        Assert.True(place.Update(2));
        place.Reset();                   // `dropSessionDidExit` / `dropSessionDidEnd`
        Assert.Null(place.Current);
        Assert.False(place.Update(0));
    }

    [Fact]
    public void TheDropSavesOnePositionInTheSameListAndSaysWhyInAnotherSort()
    {
        var find = new Dictionary<string, TodoTask> { ["a"] = T("a", 10), ["b"] = T("b", 20), ["c"] = T("c", 30) };
        TodoTask? Find(string id) => find.GetValueOrDefault(id);
        string[] open = ["a", "b", "c"];
        // c up to the top of Work in My Order: before a, no notice, and the list stays Work.
        var top = TodoArrange.Plan(open, "c", 0, TodoView.List("work"), Find, Now, "smart");
        Assert.Equal(new TodoDropPlan("c", "work", 9, null), top);
        // a down under b in Due Date: halfway between b and c, and the "Sorted by" line.
        var down = TodoArrange.Plan(open, "a", 2, TodoView.List("work"), Find, Now, "due");
        Assert.Equal(new TodoDropPlan("a", "work", 25,
            "Sorted by Due Date. Choose My Order in Sort By to arrange tasks by hand."), down);
        // No list on show, or no place: nothing is written.
        Assert.Null(TodoArrange.Plan(open, "a", 2, TodoView.Today, Find, Now, "smart"));
        Assert.Null(TodoArrange.Plan(open, "a", null, TodoView.List("work"), Find, Now, "smart"));
    }

    [Fact]
    public void TheWindowsRowsUseTheseRulesAndShowThePlace()
    {
        var page = Source("Features", "Tasks", "TasksPage.cs");
        var arrange = Body(page, "private void AllowArrange(");
        Assert.Contains("TodoArrange.CanLift(", arrange);
        Assert.Contains("TodoArrange.DropIndex(", arrange);
        Assert.Contains("_dropPlace.Update(", arrange);
        Assert.Contains("_dropPlace.Reset()", arrange);
        Assert.Contains("TodoArrange.Plan(", arrange);
        Assert.Contains("store.MoveAsync([plan.Id], plan.List, plan.Position)", arrange);
        Assert.Contains("DragLeave", arrange);
        // The old in-page arithmetic is gone: one source of truth in Hermes.Core.
        Assert.DoesNotContain("row.ActualHeight / 2", arrange);
    }

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts])).Replace("\r\n", "\n");
    }

    private static string Body(string source, string signature)
    {
        var start = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(start >= 0, signature);
        var end = source.IndexOf("\n    }\n", start, StringComparison.Ordinal);
        return source[start..end];
    }
}
