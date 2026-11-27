using Hermes.Core.Sessions;
using HermesHQ.Features.Bots;
using Microsoft.UI.Xaml;

namespace HermesHQ.Features.Sessions;

/// [WIN-ARCHIVE-UNDO] The Undo every chat archive's pill runs — a Sessions row's right-click Archive and Archive Chat
/// (Ctrl+Alt+A) on the open chat — as the Mac's SessionsOrganizer `archive(_:)` (93f984bb1): the archived chat's own
/// profile and id unarchived (`ArchiveUndo`), a failure the "Couldn’t Unarchive Chat" alert whose Try Again writes once
/// more. The Sessions row's Undo used to drop its write (`_ = Store.SetArchivedAsync(…)`): a failure said nothing.
public static class ArchiveUndoRoute
{
    /// The most recent archive's undo (walks read how many writes it sent).
    public static ArchiveUndo? Last { get; private set; }

    /// The action for `UndoPill.Show(…, undo)`.
    public static Action For(Func<XamlRoot> root, SessionStore store, SessionSummary archived)
    {
        var undo = new ArchiveUndo(store, archived);
        Last = undo;
        return () => _ = Prompts.RunAsync(root(), ArchiveUndo.FailureTitle, undo.RestoreAsync);
    }
}
