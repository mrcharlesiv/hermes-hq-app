namespace Hermes.Core.Kanban;

/// What a task panel shows right now: the task, the board it was read from, and a counter that moves whenever the panel
/// leaves that task (a linked task opened, even the same id again; the panel stopped or closed).
public sealed record KanbanDetailContext(string TaskId, string Board, int Epoch);

/// One write a person made in the panel. `Write` gets the board the write started on. `Done` is the panel's own follow-up
/// (clear the comment box, close the description editor, a notice) and runs only if the panel still shows the same task
/// on the same board in the same lifetime. `Next` is the second half of the same deliberate act (Post and Start Over's
/// start again): it is sent even if the panel has moved on, but then quietly.
public sealed record KanbanDetailStep(string Key, Func<string, Task> Write, Action? Done = null, KanbanDetailStep? Next = null);

/// The panel the writes report back to (KanbanTaskPanel).
public interface IKanbanDetailHost
{
    KanbanDetailContext Now { get; }
    /// Moves only when another task opens in the panel: the spinners belong to that opening.
    int Opened { get; }
    bool ReadOnly { get; }
    ISet<string> Busy { get; }
    void Changed();
    void Notice(string text);
    /// A "Couldn’t …" alert; `retry` is Try Again.
    Task Alert(string title, string reason, Func<Task> retry);
    /// The task shown is read again.
    Task ReadTask();
    /// The board is read again (always: it holds the write whatever the panel shows).
    Task ReadBoard();
    void Log(string text);
}

public enum KanbanDetailStart { Started, Busy, ReadOnly }

/// The task panel's writes (App/Pages/Kanban/KanbanTaskSheet.swift `run`, audit 863 08c-5): one per key at a time, and
/// every bit of feedback bound to where the write started. A write the person made is never cancelled by leaving the
/// task; but once the panel shows another task (or the same id reopened, or on another board), or has closed, nothing
/// of the first write reaches it: no alert, no Try Again, no notice, no cleared draft, no spinner, no re-read of the
/// wrong detail. A failure there is logged by key only, and nothing is sent again by itself.
public sealed class KanbanDetailWrites(IKanbanDetailHost host)
{
    /// The panel still shows the task, board and lifetime `at` was taken in.
    public bool Holds(KanbanDetailContext at) => host.Now == at;

    public KanbanDetailStart Run(KanbanDetailStep step) => Start(step, out _);

    /// As Run, and hands back the write's whole course (its feedback, the re-reads) for a test to wait on.
    public KanbanDetailStart Start(KanbanDetailStep step, out Task course)
    {
        course = Task.CompletedTask;
        if (host.Busy.Contains(step.Key)) return KanbanDetailStart.Busy;
        if (host.ReadOnly) { host.Notice(KanbanRest.ReadOnlyNotice); return KanbanDetailStart.ReadOnly; }
        var at = host.Now;
        var opened = host.Opened;
        host.Busy.Add(step.Key);
        host.Changed();
        course = Go(step, at, opened);
        return KanbanDetailStart.Started;
    }

    private async Task Go(KanbanDetailStep step, KanbanDetailContext at, int opened)
    {
        var sent = false;
        try
        {
            await step.Write(at.Board);
            sent = true;
        }
        catch (Exception e)
        {
            var reason = KanbanRest.Reason(e);
            if (Holds(at))
            {
                host.Log($"task write {step.Key} failed");
                // A write the person made here is an alert with Try Again; the rest keep the short notice.
                if (KanbanWriteWords.FailureTitle(step.Key) is { } title)
                    _ = host.Alert(title, reason, () =>
                    {
                        if (Holds(at)) Run(step);
                        else host.Log($"task write {step.Key}: Try Again dropped, the panel left the task");
                        return Task.CompletedTask;
                    });
                else host.Notice(reason);
            }
            else host.Log($"task write {step.Key} failed after the panel left the task");
        }
        if (sent && Holds(at)) step.Done?.Invoke();
        if (opened == host.Opened && host.Busy.Remove(step.Key)) host.Changed();
        if (sent && step.Next is { } next)
        {
            if (Holds(at)) Run(next);
            else await Quietly(next, at);
        }
        if (Holds(at)) await host.ReadTask();
        await host.ReadBoard();
    }

    /// The rest of a deliberate act whose panel has moved on: sent to the board it started on, told nowhere, never
    /// tried again by itself.
    private async Task Quietly(KanbanDetailStep step, KanbanDetailContext at)
    {
        try { await step.Write(at.Board); }
        catch (Exception) { host.Log($"task write {step.Key} failed after the panel left the task"); return; }
        if (step.Next is { } next) await Quietly(next, at);
    }
}
