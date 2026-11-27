using HermesHQ.Shell;

namespace HermesHQ.Features.Tasks;

/// Tasks (App/Pages/Tasks; docs/tasks.md): the shared to-do list of you and your bots, kept by the Hermes HQ add-on.
/// Claims the "tasks" place; `Navigator.Open("tasks", taskId)` opens the list with that task beside it.
public static class TasksFeature
{
    public static void Register() => Places.Register("tasks", typeof(TasksPage));
}
