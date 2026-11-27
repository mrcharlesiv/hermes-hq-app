namespace Hermes.Core.Kanban;

/// New Task's form and its close rules (App/Pages/Kanban/NewTaskSheet.swift NewTaskModel, NewTaskHostController
/// .hasChanges/installClose; App/BotInfo/BotInfoSheet.swift EditingGuard.askToDiscard). The words typed in (the task,
/// its details, skills) are asked about before Cancel or Escape drops them; nothing closes while Add is sending; a failed
/// Add keeps every field; the task goes to the board the sheet was opened on.
public sealed class KanbanNewTaskDraft(string board, string who, string start)
{
    public const string DiscardTitle = "Discard Changes?";
    public const string DiscardConfirm = "Discard Changes";
    public const string DiscardKeep = "Keep Editing";

    /// The board New Task was opened on ('' = the server's current board): Add writes there and nowhere else.
    public string Board { get; } = board;
    public string Title { get; set; } = "";
    public string Details { get; set; } = "";
    public string Who { get; set; } = who;
    public string Start { get; set; } = start;
    public int Priority { get; set; }
    public string Skills { get; set; } = "";
    public bool GoalMode { get; set; }
    public bool Saving { get; private set; }
    public string? Failure { get; private set; }

    /// Typed words worth asking about (NewTaskHostController.hasChanges): whitespace alone is not a change.
    public bool HasChanges => (Title + Details + Skills).Trim().Length > 0;

    public bool CanAdd => Title.Trim().Length > 0 && !Saving;

    public IReadOnlyList<string> SkillList => [.. Skills.Split(',').Select(s => s.Trim()).Where(s => s.Length > 0)];

    public enum CloseReason
    {
        /// Cancel, Escape or the window closing it: the person asked to leave.
        Dismiss,
        /// Other Number…: the sheet steps aside for the priority prompt and opens again. Not a close.
        OtherNumber,
    }

    public enum CloseDecision
    {
        /// Close (nothing typed, or an internal step that reopens the sheet).
        Close,
        /// Close the sheet only after Discard Changes is chosen; Keep Editing brings every field back.
        AskToDiscard,
        /// Stay put: Add is sending.
        Hold,
    }

    public CloseDecision Close(CloseReason reason)
    {
        if (Saving) return CloseDecision.Hold;
        if (reason == CloseReason.OtherNumber) return CloseDecision.Close;
        return HasChanges ? CloseDecision.AskToDiscard : CloseDecision.Close;
    }

    /// The answer to Discard Changes?: true only for the deliberate Discard Changes (never out from under a Save).
    public bool ConfirmDiscard(bool discardChosen) => discardChosen && !Saving;

    public enum AddResult { Added, Failed, Ignored }

    /// Add (NewTaskModel.add): once at a time, only with a title; a failure keeps the form and says why.
    /// `create` is handed this draft's board, never the store's board of the moment.
    public async Task<(AddResult Result, string? Warning)> AddAsync(Func<KanbanNewTaskDraft, Task<string?>> create, Func<Exception, string> reason)
    {
        if (!CanAdd) return (AddResult.Ignored, null);
        Saving = true;
        Failure = null;
        try
        {
            var warning = await create(this);
            return (AddResult.Added, warning);
        }
        catch (Exception x)
        {
            Failure = reason(x);
            return (AddResult.Failed, null);
        }
        finally { Saving = false; }
    }

    /// Sends this draft through the store, on the board it was opened on.
    public Task<(AddResult Result, string? Warning)> AddAsync(KanbanStore store) =>
        AddAsync(d => store.CreateAsync(d.Title, d.Details, d.Who.Length == 0 ? null : d.Who, d.Priority, d.SkillList, d.Start, d.GoalMode, d.Board),
            KanbanRest.Reason);
}
