using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-33] The Tasks page's group headings and Done's fold, as TasksViewController.heading / configureHeader / reload
/// draw them at 93f984bb1: Done folded until its heading's Show, Hide folds it again, a search shows the rows with no
/// fold, Today calls it "Done Today", the open tasks get "To Do" only while searching, and each heading is
/// `tasks.section.<title>`. `doneOpen` is the page's own (an instance var on the Mac): never saved.
public class TasksDoneFoldTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 9, 41, 0, TimeSpan.FromHours(-6));
    private static readonly IReadOnlyList<TodoUserSection> NoLists = [];
    private static string Bot(string? p) => p ?? "default";

    private static (string Title, string? Detail)? Head(TodoGroupKind kind, TodoView view, bool searching) =>
        TodoViews.PageHeading(kind, view, searching, Now, Chicago, NoLists, Bot);

    [Fact]
    public void DoneIsFoldedUntilShowAndOpenWhileSearching()
    {
        // Folded by default: the heading, no rows.
        Assert.False(TodoViews.ShowsRows(TodoGroupKind.Done, doneOpen: false, searching: false));
        Assert.Equal("Show", TodoViews.DoneFold(TodoGroupKind.Done, doneOpen: false, searching: false));
        // Show: the rows, and the fold says Hide.
        Assert.True(TodoViews.ShowsRows(TodoGroupKind.Done, doneOpen: true, searching: false));
        Assert.Equal("Hide", TodoViews.DoneFold(TodoGroupKind.Done, doneOpen: true, searching: false));
        // A search shows the matches that are done, with no fold.
        Assert.True(TodoViews.ShowsRows(TodoGroupKind.Done, doneOpen: false, searching: true));
        Assert.Null(TodoViews.DoneFold(TodoGroupKind.Done, doneOpen: false, searching: true));
        Assert.Null(TodoViews.DoneFold(TodoGroupKind.Done, doneOpen: true, searching: true));
        // Every other group always shows its rows and never folds.
        foreach (var kind in new[] { TodoGroupKind.Open, TodoGroupKind.Overdue, TodoGroupKind.Today, TodoGroupKind.Stale, TodoGroupKind.Bot("otto") })
        {
            Assert.True(TodoViews.ShowsRows(kind, doneOpen: false, searching: false));
            Assert.Null(TodoViews.DoneFold(kind, doneOpen: false, searching: false));
        }
        Assert.Equal("tasks.show-done", TodoViews.DoneFoldId);
    }

    [Fact]
    public void HeadingsAsThePageDrawsThem()
    {
        var home = TodoView.List("home");
        Assert.Equal(("Done Today", (string?)null), Head(TodoGroupKind.Done, TodoView.Today, searching: false));
        Assert.Equal(("Done", (string?)null), Head(TodoGroupKind.Done, TodoView.Today, searching: true));
        Assert.Equal(("Done", (string?)null), Head(TodoGroupKind.Done, home, searching: false));
        Assert.Equal(("Done", (string?)null), Head(TodoGroupKind.Done, TodoView.Inbox, searching: false));
        // A list's and Inbox's open tasks have no heading, but a search's are "To Do".
        Assert.Null(Head(TodoGroupKind.Open, home, searching: false));
        Assert.Equal(("To Do", (string?)null), Head(TodoGroupKind.Open, home, searching: true));
        Assert.Equal(("Overdue", (string?)null), Head(TodoGroupKind.Overdue, TodoView.Today, searching: false));
        Assert.Equal("tasks.section.Done Today", TodoViews.SectionAutomationId("Done Today"));
        Assert.Equal("tasks.section.Done", TodoViews.SectionAutomationId("Done"));
    }

    [Fact]
    public void AListWithTwoDoneShowsOnlyItsOpenTasksUntilShow()
    {
        // The CI walk's Home after Select › Mark Done: two open, two done.
        var tasks = new[]
        {
            TodoViewsTests.Task("t_h_gutters", section: "home"), TodoViewsTests.Task("t_porch", section: "home"),
            TodoViewsTests.Task("t_h_filter", section: "home", status: "done", doneAt: "2026-11-04T09:00:00-06:00"),
            TodoViewsTests.Task("t_cleaning", section: "home", status: "done", doneAt: "2026-11-04T09:01:00-06:00"),
        };
        var sections = new[] { new TodoUserSection("home", "Home") };
        var groups = TodoViews.Groups(tasks, TodoView.List("home"), sections, [], Now, Chicago);
        IEnumerable<string> Shown(bool open) => groups.Where(g => TodoViews.ShowsRows(g.Kind, open, searching: false))
            .SelectMany(g => g.Tasks).Select(t => t.Id);
        Assert.Equal(["t_h_gutters", "t_porch"], Shown(open: false).Order());
        Assert.Equal(["t_cleaning", "t_h_filter", "t_h_gutters", "t_porch"], Shown(open: true).Order());
        // The Done heading still shows, with its count, folded.
        var done = groups.Single(g => g.Kind == TodoGroupKind.Done);
        Assert.Equal(2, done.Tasks.Count);
    }
}
