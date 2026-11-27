namespace Hermes.Core.Sessions;

/// [WIN-ARCHIVE-UNDO] What an archive's "Archived “title” · Undo" takes back (App/Sessions/SessionsOrganizer.swift
/// `archive(_:)` at 93f984bb1): the very chat that was archived — its profile and stored id, nothing looked up again —
/// unarchived through the sidebar's own write (`SessionStore.SetArchivedAsync(archived, false)`, the Mac's
/// `store.setArchived(archived, false)`). A failure is the Mac's "Couldn’t Unarchive Chat" (`run(_:)`), whose Try Again
/// sends the same write again.
///
/// One restore at a time: a second call while the first is on its way joins it, and once it has landed the chat is back
/// and nothing more is sent. Only a failed restore lets the next call (Try Again) write again. Together with the pill's
/// single press (`UndoPillPress`) two rapid clicks cannot send two unarchives.
public sealed class ArchiveUndo
{
    /// The alert's title when the unarchive fails (the Mac's).
    public const string FailureTitle = "Couldn’t Unarchive Chat";

    private readonly SessionStore _store;
    private readonly object _gate = new();
    private Task? _restore;

    public ArchiveUndo(SessionStore store, SessionSummary chat)
    {
        _store = store;
        Chat = chat with { Archived = true };
    }

    /// The chat as archived: the profile and id the restore writes.
    public SessionSummary Chat { get; }

    /// How many unarchive writes this undo has started (one, or one more per Try Again after a failure).
    public int Writes { get; private set; }

    /// The chat is back (the restore landed).
    public bool Restored { get; private set; }

    /// Unarchives the chat once; joins a restore already on its way; after it landed, does nothing.
    public Task RestoreAsync()
    {
        lock (_gate)
        {
            if (_restore is { IsFaulted: false, IsCanceled: false } running) return running;
            Writes++;
            return _restore = RunAsync();
        }
    }

    private async Task RunAsync()
    {
        await _store.SetArchivedAsync(Chat, false);
        Restored = true;
    }
}
