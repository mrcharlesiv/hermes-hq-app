using HermesHQ.Shell;

namespace HermesHQ.Features.Kanban;

/// Kanban (App/Pages/Kanban): the board, a task's panel, archive with Undo, Add Attachment. Claims the "kanban" place.
/// `Navigator.Open("kanban", taskId)` opens the board with that task's panel.
public static class KanbanFeature
{
    public static void Register()
    {
        Places.Register("kanban", typeof(KanbanPage));
        KanbanWalks.Register();   // the CI's board picker pictures (8 menu, 9 list, 13 search)
    }
}
