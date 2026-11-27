namespace Hermes.Core.Workspace;

/// What a Files or Changes list shows: rows, or a state with its words and buttons. The decisions of
/// `MoreWorkspaceController.reload()` and `read(_:)` (App/Pages/More/Workspace/MoreWorkspacePages.swift), without UI.
public abstract record ListingContent
{
    public sealed record Loading : ListingContent;
    public sealed record Entries(IReadOnlyList<WorkspaceEntry> Rows) : ListingContent;
    public sealed record Changes(IReadOnlyList<WorkspaceChange> Rows, string? RepoRoot) : ListingContent;
    /// `Glyph` is the Mac's symbol name (the app maps it); `Retry` offers Try Again, `Choose` Choose Folder….
    public sealed record State(WorkspaceRoot.Words Words, string Glyph, bool Retry, bool Choose) : ListingContent;
}

public static class WorkspaceListing
{
    /// The root page's read: the root by precedence, then the folder (`browsed` when it is still under the root).
    /// Returns the content and the folder it lists (null when there is none).
    public static async Task<(ListingContent Content, string? Directory)> LoadRootAsync(WorkspaceVisit visit, string? browsed,
        CancellationToken ct = default)
    {
        string? root;
        try { root = (await visit.ResolveRootAsync(ct))?.Path; }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            var missing = WorkspaceRoot.IsMissingRoute(e);
            return (new ListingContent.State(
                new(missing ? WorkspaceRoot.NotAvailableTitle : visit.PageKind == WorkspaceVisit.Kind.Files ? "Couldn’t Load Files" : "Couldn’t Load Changes",
                    missing ? WorkspaceRoot.NotAvailableBody(visit.Title) : ChatWorkspace.Reason(e)),
                "exclamationmark.triangle", !missing, !missing), null);
        }
        var directory = browsed != null && root != null && WorkspaceRoot.IsUnder(browsed, root) ? browsed : root;
        if (directory == null) return (new ListingContent.State(WorkspaceRoot.NoFolderYet, "folder.badge.questionmark", false, true), null);
        return (await ReadAsync(visit, directory, isRoot: true, chooser: false, ct), directory);
    }

    /// One folder's rows (Files, the chooser) or the root's changes (Changes).
    public static async Task<ListingContent> ReadAsync(WorkspaceVisit visit, string directory, bool isRoot, bool chooser,
        CancellationToken ct = default)
    {
        var showsChanges = isRoot && !chooser && visit.PageKind == WorkspaceVisit.Kind.Review;
        var workspace = visit.Workspace;
        try
        {
            if (showsChanges)
            {
                var changes = WorkspaceRoot.Deduped(await workspace.ChangesAsync(directory, ct));
                if (changes.Count == 0)
                {
                    // Hermes answers an empty list for a folder that is not a repository: ask which it is.
                    var repository = await workspace.IsRepositoryAsync(directory, ct);
                    return repository == false
                        ? new ListingContent.State(WorkspaceRoot.NotGit, "arrow.triangle.branch", false, true)
                        : new ListingContent.State(WorkspaceRoot.NoChanges, "checkmark.circle", false, false);
                }
                return new ListingContent.Changes(changes, await workspace.GitRootAsync(directory, ct));
            }
            var entries = WorkspaceRoot.Deduped(await workspace.ListAsync(directory, ct));
            if (chooser) entries = [.. entries.Where(e => e.IsDirectory)];
            if (entries.Count == 0 && !chooser) return new ListingContent.State(WorkspaceRoot.EmptyFolder, "folder", false, false);
            return new ListingContent.Entries(entries);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            var reason = ChatWorkspace.Reason(e);
            if (e is not WorkspaceReadException && WorkspaceRoot.IsMissingRoute(e) && isRoot)
                return new ListingContent.State(new(WorkspaceRoot.NotAvailableTitle, WorkspaceRoot.NotAvailableBody(visit.Title)),
                    "exclamationmark.triangle", false, false);
            if (showsChanges)
                return WorkspaceRoot.IsNotGit(reason)
                    ? new ListingContent.State(WorkspaceRoot.NotGit, "arrow.triangle.branch", false, true)
                    : new ListingContent.State(new("Couldn’t Load Changes", reason), "exclamationmark.triangle", true, false);
            var words = WorkspaceRoot.FolderErrorText(reason, chatFolder: isRoot && visit.Root?.Source == WorkspaceRoot.Source.Chat);
            return new ListingContent.State(words, "exclamationmark.triangle", true, isRoot && !chooser);
        }
    }
}
