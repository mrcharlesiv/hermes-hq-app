using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-TASK-PILL-COUNT] A view pill's count and spoken name (App/Pages/Tasks/TaskViewsHeader.swift at 93f984bb1:
/// line 76 `detail: pill.count.flatMap { $0 > 0 ? "\($0)" : nil }`, lines 153–156 `spoken`). The count shows only
/// above 0; screen readers hear "Title, 1 task" / "Title, N tasks", or the title alone for 0 or no count.
public class TasksPillCountTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 9, 41, 0, TimeSpan.FromHours(-6));
    private static readonly TodoUserSection[] Lists = [new("work", "Work"), new("home", "Home")];

    [Theory]
    [InlineData(null, null, "Home")]
    [InlineData(0, null, "Home")]
    [InlineData(1, "1", "Home, 1 task")]
    [InlineData(8, "8", "Home, 8 tasks")]
    [InlineData(1234, "1234", "Home, 1234 tasks")]
    public void APillShowsAndSaysItsCountOnlyAboveZero(int? count, string? detail, string name)
    {
        Assert.Equal(detail, TasksCopy.PillDetail(count));
        Assert.Equal(name, TasksCopy.PillName("Home", count));
    }

    [Fact]
    public void ANegativeCountIsNotShown()
    {
        Assert.Null(TasksCopy.PillDetail(-1));
        Assert.Equal("Home", TasksCopy.PillName("Home", -1));
    }

    [Fact]
    public void TheGoalsPillFollowsTheSameRule()
    {
        // Goals with none active (add-on keeps goals) and Goals on an older add-on (no count) both read "Goals".
        Assert.Equal("Goals", GoalsAddOn.PillName(0));
        Assert.Equal("Goals", GoalsAddOn.PillName(null));
        Assert.Equal("Goals, 1 task", GoalsAddOn.PillName(1));
        Assert.Equal("Goals, 3 tasks", GoalsAddOn.PillName(3));
        var (shows, none) = GoalsAddOn.Pill(goalsSupported: true, goalsNeedAddOn: false, []);
        Assert.True(shows);
        Assert.Equal(0, none);
        Assert.Null(TasksCopy.PillDetail(none));
        var (stays, missing) = GoalsAddOn.Pill(goalsSupported: false, goalsNeedAddOn: true, []);
        Assert.True(stays);
        Assert.Null(missing);
        Assert.Null(TasksCopy.PillDetail(missing));
    }

    [Fact]
    public void AnEmptiedListReadsByItsNameAlone()
    {
        // Shot 121's state: Home's only open task deleted, two done ones left. The stored count stays 0; the pill
        // draws "Home", not "Home 0".
        TodoTask[] tasks =
        [
            TodoViewsTests.Task("w1", section: "work"),
            TodoViewsTests.Task("h1", section: "home", status: "done", doneAt: "2026-11-04T08:00:00-06:00"),
            TodoViewsTests.Task("h2", section: "home", status: "done", doneAt: "2026-11-04T08:10:00-06:00"),
        ];
        var home = TodoViews.OpenCount(tasks, TodoView.List("home"), Lists, Now, Chicago);
        var work = TodoViews.OpenCount(tasks, TodoView.List("work"), Lists, Now, Chicago);
        Assert.Equal(0, home);
        Assert.Equal(1, work);
        Assert.Null(TasksCopy.PillDetail(home));
        Assert.Equal("Home", TasksCopy.PillName("Home", home));
        Assert.Equal("1", TasksCopy.PillDetail(work));
        Assert.Equal("Work, 1 task", TasksCopy.PillName("Work", work));
    }
}
