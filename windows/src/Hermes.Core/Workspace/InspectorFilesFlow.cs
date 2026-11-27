namespace Hermes.Core.Workspace;

/// The I/O the chat inspector's Files tab needs, so its lifetime can be driven by a fake reader in tests.
public interface IInspectorFilesReader
{
    Task<List<WorkspaceEntry>> ListAsync(string directory, CancellationToken ct);
    /// A text file's start (throws ChatWorkspace.TooLargeException past the gateway's text read).
    Task<WorkspaceFileText> ReadTextAsync(string path, CancellationToken ct);
    /// Downloads the file somewhere local and answers where.
    Task<string> DownloadAsync(WorkspaceEntry entry, CancellationToken ct);
}

/// What the Files tab shows.
public abstract record InspectorFilesContent
{
    /// The chat has no folder (the Mac's "No Folder").
    public sealed record NoFolder : InspectorFilesContent;
    public sealed record Loading(string Folder) : InspectorFilesContent;
    /// A folder's rows, or why it couldn't be read (`Failure`, with Try Again). `Up` is Back's folder, null at the root.
    public sealed record Listing(string Folder, string? Up, IReadOnlyList<WorkspaceEntry> Rows, WorkspaceRoot.Words? Failure)
        : InspectorFilesContent;
    /// A text file in the panel; Back returns to `Under`, the listing it was opened from, as it was.
    public sealed record Text(string Name, WorkspaceFileText File, Listing Under) : InspectorFilesContent;
}

/// The lifetime of the chat inspector's Files tab (MacInspector `.files`, the chat's `WorkspacePage(kind: .files,
/// panel: true)`), without UI. Every call is made on the UI thread; reads run on `background` and their answers come
/// back through `post`. Only the current lifetime (attached), folder and operation may change what is shown or ask
/// for an alert or an external open:
/// - Detach cancels the read and the open in flight; a listing or text already shown is kept. Back on screen with the
///   same root, an interrupted read or a failed one is read again (MoreWorkspaces's viewWillAppear on the Mac).
/// - A chat with no folder cancels everything outstanding and says No Folder; a new root starts over at its top.
/// - A newer navigation (a folder, Back, Try Again, another file) supersedes the read and the open before it.
public sealed class InspectorFilesFlow
{
    private readonly Func<string?> _folderOf;
    private readonly Func<IInspectorFilesReader?> _reader;
    private readonly Action<Action> _post;
    private readonly Func<Func<Task>, Task> _background;
    private CancellationTokenSource? _load;
    private CancellationTokenSource? _opening;
    private long _navigation;
    private long _openId;
    private bool _interrupted;

    /// Shown content changed.
    public event Action? Changed;
    /// A file that isn't text, downloaded: open it in its own app (local path, name).
    public event Action<string, string>? OpenExternally;
    /// An open failed: "Couldn't Open This File" with this reason.
    public event Action<string>? OpenFailed;

    public InspectorFilesContent Content { get; private set; } = new InspectorFilesContent.NoFolder();
    public string? Root { get; private set; }
    public string? Folder { get; private set; }
    public bool IsAttached { get; private set; }
    /// A read or open is out (tests and the busy state).
    public bool IsBusy => _load != null || _opening != null;

    public InspectorFilesFlow(Func<string?> folderOf, Func<IInspectorFilesReader?> reader, Action<Action> post,
        Func<Func<Task>, Task>? background = null)
    {
        _folderOf = folderOf;
        _reader = reader;
        _post = post;
        _background = background ?? (work => Task.Run(work));
    }

    /// On screen (Loaded).
    public void Attach()
    {
        IsAttached = true;
        Refresh(returning: true);
    }

    /// Off screen (Unloaded): nothing outstanding may land, but what is shown is kept.
    public void Detach()
    {
        IsAttached = false;
        if (_load != null) _interrupted = true;
        Supersede();
        _navigation++;
    }

    /// The chat's folder may have changed.
    public void FolderChanged()
    {
        if (IsAttached) Refresh(returning: false);
    }

    private void Refresh(bool returning)
    {
        var folder = _folderOf();
        if (folder == null)
        {
            Supersede();
            _navigation++;
            _interrupted = false;
            Root = null;
            Folder = null;
            Show(new InspectorFilesContent.NoFolder());
            return;
        }
        if (folder != Root || Folder == null)
        {
            Root = folder;
            List(folder);
            return;
        }
        // Same root: a read cut short by leaving is read again; a failed one is too when coming back on screen.
        if (_interrupted || (returning && Content is InspectorFilesContent.Listing { Failure: not null }))
            List(Folder);
    }

    /// Lists `folder` (a row's folder, Back, Try Again), superseding whatever was out.
    public void List(string folder)
    {
        if (!IsAttached || Root == null) return;
        Supersede();
        var navigation = ++_navigation;
        Folder = folder;
        if (_reader() is not { } reader)
        {
            // No connection yet: wait, and read when back on screen or the folder is said again.
            _interrupted = true;
            Show(new InspectorFilesContent.Loading(folder));
            return;
        }
        _interrupted = false;
        var cts = _load = new CancellationTokenSource();
        var up = folder != Root ? WorkspaceRoot.Parent(folder) : null;
        var chatFolder = folder == Root;
        Show(new InspectorFilesContent.Loading(folder));
        _ = _background(async () =>
        {
            InspectorFilesContent.Listing answer;
            try
            {
                var rows = WorkspaceRoot.Deduped(await reader.ListAsync(folder, cts.Token));
                answer = new(folder, up, rows, null);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception x)
            {
                answer = new(folder, up, [], WorkspaceRoot.FolderErrorText(ChatWorkspace.Reason(x), chatFolder));
            }
            _post(() =>
            {
                if (!Current(navigation, cts)) return;
                _load = null;
                cts.Dispose();
                Show(answer);
            });
        });
    }

    /// Back: from a file's text to its listing as it was; from a folder to the one holding it.
    public void Back()
    {
        if (!IsAttached) return;
        switch (Content)
        {
            case InspectorFilesContent.Text text:
                Supersede();
                _navigation++;
                Folder = text.Under.Folder;
                Show(text.Under);
                break;
            case InspectorFilesContent.Listing { Up: { } up }:
                List(up);
                break;
            case InspectorFilesContent.Loading loading when loading.Folder != Root && WorkspaceRoot.Parent(loading.Folder) is { } parent:
                List(parent);
                break;
        }
    }

    /// Try Again on a failed listing.
    public void Retry()
    {
        if (Folder != null) List(Folder);
    }

    /// A row: a folder opens in place; a text file reads into the panel; anything else is downloaded and handed to
    /// its own app. A newer navigation or open supersedes it.
    public void Open(WorkspaceEntry entry)
    {
        if (!IsAttached || Content is not InspectorFilesContent.Listing { Failure: null } under) return;
        if (entry.IsDirectory) { List(entry.Path); return; }
        if (_reader() is not { } reader) return;
        _opening?.Cancel();
        var cts = _opening = new CancellationTokenSource();
        var navigation = _navigation;
        var id = ++_openId;
        _ = _background(async () =>
        {
            Action land;
            try
            {
                WorkspaceFileText? read = null;
                if (WorkspaceRoot.Opening(entry.Name) == WorkspaceRoot.OpeningKind.Text)
                {
                    try { read = await reader.ReadTextAsync(entry.Path, cts.Token); }
                    catch (ChatWorkspace.TooLargeException) { }
                }
                if (read is { Binary: false } file)
                    land = () => Show(new InspectorFilesContent.Text(entry.Name, file, under));
                else
                {
                    var local = await reader.DownloadAsync(entry, cts.Token);
                    land = () => OpenExternally?.Invoke(local, entry.Name);
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception x)
            {
                var reason = ChatWorkspace.Reason(x);
                land = () => OpenFailed?.Invoke(reason);
            }
            _post(() =>
            {
                if (!Current(navigation, cts) || id != _openId || !ReferenceEquals(Content, under)) return;
                _opening = null;
                cts.Dispose();
                land();
            });
        });
    }

    private bool Current(long navigation, CancellationTokenSource cts) =>
        IsAttached && navigation == _navigation && !cts.IsCancellationRequested;

    private void Supersede()
    {
        _load?.Cancel();
        _load = null;
        _opening?.Cancel();
        _opening = null;
        _openId++;
    }

    private void Show(InspectorFilesContent content)
    {
        Content = content;
        Changed?.Invoke();
    }
}
