using System.Text.Json.Nodes;

namespace Hermes.Core.Tasks;

/// [WIN-47] What a choice in Add to Goal is (App/Pages/Goals/GoalShared.swift `GoalChoices` at 93f984bb1).
public enum GoalChoiceKind { Goal, NoMilestone, Milestone, NoGoal, OpenGoal }

/// One row of Add to Goal: a goal (a submenu when `Children` has its milestones), No Milestone, a milestone, No Goal or
/// Open Goal. `Goal`/`Milestone` say where a pick puts the task (Open Goal: the goal it opens). `Ticked`: where it is.
public sealed record GoalChoice(GoalChoiceKind Kind, string Title, bool Ticked, string? Goal, string? Milestone, IReadOnlyList<GoalChoice> Children);

/// [WIN-47] "Add to Goal" on a task row's right-click menu, beside Move To (TasksViewController.swift
/// `contextMenuConfigurationForItemsAt` and GoalShared.swift `GoalChoices.menu` at 93f984bb1): each active goal (one with
/// milestones a submenu: No Milestone, then its open milestones and the task's own), then, for a task in a goal, No Goal
/// and Open Goal. A pick is `TasksStore.SetGoalAsync` (`PATCH …/tasks/<id>` with `goal` and `milestone`).
public static class GoalChoices
{
    public const string Title = "Add to Goal";
    public const string NoMilestone = "No Milestone";
    public const string NoGoal = "No Goal";
    public const string OpenGoal = "Open Goal";
    /// The menu's identifier (Windows' own, for the walk).
    public const string MenuId = "tasks.add-to-goal";

    /// The choices for `task`; null on an add-on that keeps no goals or with nothing to choose (no row then).
    public static IReadOnlyList<GoalChoice>? Menu(TodoTask task, IEnumerable<Goal> goals, bool goalsSupported)
    {
        if (!goalsSupported) return null;
        var rows = new List<GoalChoice>();
        foreach (var goal in GoalViews.Groups(goals).Active)
        {
            var here = task.Goal == goal.Id;
            if (goal.Milestones.Count == 0)
            {
                rows.Add(new GoalChoice(GoalChoiceKind.Goal, goal.Title, here, goal.Id, null, []));
                continue;
            }
            List<GoalChoice> inner = [new(GoalChoiceKind.NoMilestone, NoMilestone, here && task.Milestone == null, goal.Id, null, [])];
            inner.AddRange(goal.Milestones.Where(m => !m.Done || task.Milestone == m.Id)
                .Select(m => new GoalChoice(GoalChoiceKind.Milestone, m.Title, here && task.Milestone == m.Id, goal.Id, m.Id, [])));
            // A submenu carries no tick of its own on the Mac (UIMenu); `Ticked` says the task is in it.
            rows.Add(new GoalChoice(GoalChoiceKind.Goal, goal.Title, false, goal.Id, null, inner));
        }
        if (task.Goal is { } current)
        {
            rows.Add(new GoalChoice(GoalChoiceKind.NoGoal, NoGoal, false, null, null, []));
            rows.Add(new GoalChoice(GoalChoiceKind.OpenGoal, OpenGoal, false, current, null, []));
        }
        return rows.Count == 0 ? null : rows;
    }
}

/// [WIN-47] What the + on the bar does (TasksViewController.swift `addTapped` at 93f984bb1).
public enum GoalsAddAction { NewTask, NewGoal, UpdateAddOn }

/// [WIN-47] [goals-addon] Goals on an add-on from before Goals (TasksStore.swift `goalsNeedAddOn`;
/// TasksViewController.swift `views`, `updateEmptyState`, line 805's + label and `addTapped` at 93f984bb1): the Goals
/// pill stays, with no count, and the Goals view is the update state alone ("Goals Need a Newer Add-on").
public static class GoalsAddOn
{
    public const string StateTitle = "Goals Need a Newer Add-on";
    public static string StateText(string host) => $"Update {TasksCopy.AddOnName} on {host} to set goals, milestones and the tasks under them.";
    public const string UpdateButton = "Update Add-on";
    public const string UpdatingButton = "Updating…";
    /// The state's identifier (Windows' own, for the walk).
    public const string StateId = "goals.need-addon";

    /// Tasks work, but the add-on keeps no goals.
    public static bool NeedsAddOn(bool hasList, bool needsAddOn, bool goalsSupported) => hasList && !needsAddOn && !goalsSupported;

    /// The Goals pill: shown with its active goals' count where goals are kept, shown with no count on an older add-on.
    public static (bool Shows, int? Count) Pill(bool goalsSupported, bool goalsNeedAddOn, IEnumerable<Goal> goals) =>
        goalsSupported ? (true, GoalViews.ActiveCount(goals)) : goalsNeedAddOn ? (true, null) : (false, null);

    /// The pill's spoken name, by the same rule as every view pill (TaskViewsHeader.swift `spoken`): "Goals, 2 tasks",
    /// or "Goals" with no count or none active.
    public static string PillName(int? count) => TasksCopy.PillName(GoalsCopy.Goals, count);

    /// Goals picked with no goals to show and nothing to update (no list yet): Today instead.
    public static bool FallsBack(TodoView view, bool goalsSupported, bool goalsNeedAddOn) =>
        view == TodoView.Goals && !goalsSupported && !goalsNeedAddOn;

    /// The Goals view on an add-on without goals: the update state alone, no task lines (`goalsLocked`).
    public static bool Locked(TodoView view, bool searching, bool goalsSupported) => view == TodoView.Goals && !searching && !goalsSupported;

    /// The bar's + as screen readers hear it (line 805): "New Goal" in Goals ("Update Add-on" on an older add-on).
    public static string AddLabel(TodoView view, bool goalsNeedAddOn) =>
        view == TodoView.Goals ? goalsNeedAddOn ? UpdateButton : GoalsCopy.NewGoal : TasksCopy.NewTask;

    public static GoalsAddAction AddAction(TodoView view, bool searching, bool goalsSupported, bool goalsNeedAddOn) =>
        view != TodoView.Goals || searching ? GoalsAddAction.NewTask
        : goalsNeedAddOn ? GoalsAddAction.UpdateAddOn
        : goalsSupported ? GoalsAddAction.NewGoal : GoalsAddAction.NewTask;
}
