using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-37] Which group heading the Tasks page draws in red: Overdue alone, as TasksViewController.configureHeader at
/// 93f984bb1 builds `TodoGroupHeaderView(…, red: kind == .overdue)` (the name in `Color.hqRed`).
public class TasksHeadingRedTests
{
    [Fact]
    public void OnlyOverdueIsRed()
    {
        Assert.True(TodoViews.HeadingIsRed(TodoGroupKind.Overdue));
        foreach (var kind in new[]
        {
            TodoGroupKind.Today, TodoGroupKind.Waiting, TodoGroupKind.Open, TodoGroupKind.Done, TodoGroupKind.Stale,
            TodoGroupKind.Bot("otto"), TodoGroupKind.Day("2026-11-05"), TodoGroupKind.Next("home"),
        })
            Assert.False(TodoViews.HeadingIsRed(kind));
    }
}
