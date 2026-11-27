namespace Hermes.Core.Artifacts;

// A file, an HTML page a bot made, or a Markdown note in a window of its own (App/Mac/MacFileWindow.swift at
// 93f984bb1; [mac-files] owner 2026-11-09, [mac-pages] owner 2026-11-16). What decides it lives here, without WinUI:
// which window a file or page takes (its key), whether a click opens a new window or brings the one showing it
// forward, the file gone from this PC's copy, what Escape and Ctrl+W close, and where the next window sits. The
// windows themselves are Features/Artifacts/ArtifactWindows.cs. Nothing here is saved, so file windows are never
// reopened at the next launch (MacFileWindow.forgetRestored).

/// The Mac's words for a file window (MacFileWindow.swift, FilePreviewPresenter.alert, FileWindowController).
public static class FileWindowWords
{
    /// FilePreviewPresenter.alert's title, over the main window.
    public const string CouldntOpenTitle = "Couldn’t Open File";

    /// The downloaded copy was cleared before its window came (`couldNotOpen(name, gone: true)`). The Mac says "this
    /// Mac"; Windows says "this PC", as BotIdentity's "Only on this PC" does.
    public static string Gone(string name) => $"“{name}” is no longer on this PC. Click it again to download it.";

    /// The window was asked for and didn't come (`couldNotOpen(name)`).
    public static string DidntOpen(string name) => $"“{name}” didn’t open in a window of its own. Click it again to try once more.";

    /// "Open in Numbers": the app this PC opens the file with, by name. With no name known, Windows' own wording.
    public static string OpenIn(string? app) =>
        string.IsNullOrWhiteSpace(app) ? ArtifactPageWords.OpenInDefaultApp : $"Open in {app.Trim()}";

    /// FileWindowController.openInApp: the app refused the copy it was handed.
    public static string AppDidntOpen(string? app) =>
        $"{(string.IsNullOrWhiteSpace(app) ? "The app" : app.Trim())} didn’t open it. Share… or Save As… still can.";

    /// KeyCommands.validateInFileWindow: ⌘W reads Close Window, Escape reads Close.
    public const string CloseWindow = "Close Window", Close = "Close";
}

/// What names a window, so the same file or page opened again takes the window it has.
public static class FileWindowKey
{
    /// A file on this PC, by its full path (`url.standardizedFileURL.path`). NTFS paths don't care about case, so
    /// "Report.PDF" and "report.pdf" are one window.
    public static string File(string path) => "file:" + Local(path);

    /// A page or a note: where it lives on the bot's computer (`source?.path`, `gateway?.path`), as written there
    /// (that computer's paths may care about case), else the copy on this PC.
    public static string Page(string? gatewayPath, string? localPath) =>
        !string.IsNullOrWhiteSpace(gatewayPath) ? "page:" + gatewayPath : "page:" + Local(localPath ?? "");

    private static string Local(string path)
    {
        if (path.Length == 0) return "";
        string full;
        try { full = Path.GetFullPath(path); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { full = path; }
        return full.Replace('\\', '/').ToLowerInvariant();
    }
}

public enum FileWindowOutcome
{
    /// A new window for it.
    Opened,
    /// Its window was already open: brought forward (a page shows the page just made).
    BroughtForward,
    /// The file isn't on this PC any more: nothing opens; `Alert` says so over the main window.
    Gone,
    /// The window couldn't be made: `Alert` says so over the main window.
    Failed,
}

public sealed record FileWindowResult<T>(FileWindowOutcome Outcome, T? Window, string? Alert = null) where T : class;

/// The open file and page windows, by key (MacFileWindow.scenes). One window per key; a closed window leaves.
public sealed class FileWindowRegistry<T> where T : class
{
    private readonly Dictionary<string, T> _open = new(StringComparer.Ordinal);

    public int Count => _open.Count;
    public IReadOnlyCollection<string> Keys => _open.Keys;
    public T? Find(string key) => _open.GetValueOrDefault(key);
    public string? KeyOf(T window) => _open.FirstOrDefault(p => ReferenceEquals(p.Value, window)).Key;

    /// MacFileWindow.open(url): a file gone from this PC says so (even with its window still open: its copy is what
    /// the window reads); the one already showing it comes forward; else `make` builds a window for it.
    public FileWindowResult<T> OpenFile(string path, string name, Func<string, bool> exists, Func<string, T> make)
    {
        if (!exists(path)) return new(FileWindowOutcome.Gone, null, FileWindowWords.Gone(name));
        return Open(FileWindowKey.File(path), name, make);
    }

    /// MacFileWindow.open(page:title:key:): the page's window, or a new one. The caller hands a brought-forward
    /// window the page it just made (FileSceneDelegate.scene(_:continue:)).
    public FileWindowResult<T> OpenPage(string key, string title, Func<string, T> make) => Open(key, title, make);

    private FileWindowResult<T> Open(string key, string name, Func<string, T> make)
    {
        if (_open.TryGetValue(key, out var shown)) return new(FileWindowOutcome.BroughtForward, shown);
        T window;
        try { window = make(key); }
        catch (Exception) { return new(FileWindowOutcome.Failed, null, FileWindowWords.DidntOpen(name)); }
        _open[key] = window;
        return new(FileWindowOutcome.Opened, window);
    }

    /// A window that closed (sceneDidDisconnect): the next click on its file opens a new one.
    public void Closed(T window)
    {
        foreach (var key in _open.Where(p => ReferenceEquals(p.Value, window)).Select(p => p.Key).ToList()) _open.Remove(key);
    }
}

public enum FileWindowKeyPress { Escape, CtrlW }

public enum FileWindowKeyAction
{
    /// Not a file window's key: the main window's own (its chat's Ctrl+W, its Escape).
    MainWindow,
    /// The file or page window closes.
    CloseWindow,
    /// What is over the window (a share sheet, a save dialog, an alert) closes first.
    CloseWhatIsOver,
    /// Held: Ctrl+W with something over the window, as on a Mac.
    Nothing,
}

/// Escape and Ctrl+W while a file window is in front (AppDelegate.hqCloseChat, escapeInFileWindow,
/// validateInFileWindow): they close it, never the main window's chat.
public static class FileWindowKeys
{
    public static FileWindowKeyAction Route(FileWindowKeyPress press, bool fileWindowInFront, bool somethingOver)
    {
        if (!fileWindowInFront) return FileWindowKeyAction.MainWindow;
        return press switch
        {
            FileWindowKeyPress.Escape => somethingOver ? FileWindowKeyAction.CloseWhatIsOver : FileWindowKeyAction.CloseWindow,
            _ => somethingOver ? FileWindowKeyAction.Nothing : FileWindowKeyAction.CloseWindow,
        };
    }
}

/// A screen rectangle (left, top, width, height), y down.
public readonly record struct WindowFrame(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public bool IsEmpty => Width <= 0 || Height <= 0;
}

/// Where a file window opens (FileSceneDelegate.show; HermesKit/Layout/WindowFit.swift): the main window's size less a
/// little (at least 900 × 680, at most 1,400 × 1,000), just down and right of it, inside the screen's visible part, and
/// a step down and right of every file window already there, so a second file never hides the first ([mac-feel D29]).
public static class FileWindowPlacement
{
    public const double MinimumWidth = 520, MinimumHeight = 420;

    public static WindowFrame Frame(WindowFrame main, IEnumerable<(double X, double Y)> taken, WindowFrame? visible, double scale = 1)
    {
        var width = Math.Min(Math.Max(main.Width - 80 * scale, 900 * scale), 1400 * scale);
        var height = Math.Min(Math.Max(main.Height - 60 * scale, 680 * scale), 1000 * scale);
        return Cascaded(new WindowFrame(main.X + 40 * scale, main.Y + 30 * scale, width, height), taken.ToList(), visible, 28 * scale);
    }

    /// WindowFit.inside: moved, and made smaller only if it can't fit, so it lies inside `visible`.
    public static WindowFrame Inside(WindowFrame frame, WindowFrame? visible)
    {
        if (visible is not { IsEmpty: false } v) return frame;
        var width = Math.Min(frame.Width, v.Width);
        var height = Math.Min(frame.Height, v.Height);
        return new WindowFrame(Math.Min(Math.Max(frame.X, v.X), v.Right - width), Math.Min(Math.Max(frame.Y, v.Y), v.Bottom - height), width, height);
    }

    /// WindowFit.cascaded: one `step` down and right for every window already at the spot; past the screen's foot or
    /// right edge it starts again a step in from the top left.
    public static WindowFrame Cascaded(WindowFrame frame, IReadOnlyList<(double X, double Y)> taken, WindowFrame? visible, double step = 28)
    {
        bool IsTaken(WindowFrame r) => taken.Any(t => Math.Abs(t.X - r.X) < 4 && Math.Abs(t.Y - r.Y) < 4);
        var output = Inside(frame, visible);
        var wrapped = false;
        for (var i = 0; i < 40 && IsTaken(output); i++)
        {
            var next = output with { X = output.X + step, Y = output.Y + step };
            if (visible is { IsEmpty: false } v && (next.Right > v.Right + 0.5 || next.Bottom > v.Bottom + 0.5))
            {
                if (wrapped) break;
                wrapped = true;
                output = Inside(new WindowFrame(v.X + step, v.Y + step, output.Width, output.Height), visible);
            }
            else output = next;
        }
        return output;
    }
}

public enum FileWindowShows
{
    /// An HTML page a bot made, live, in a page window (HTMLPageSheet).
    Page,
    /// A Markdown note, formatted, in a page window (MarkdownFileSheet; up to 2 MiB).
    Note,
    /// A PDF's pages in a file window (the Mac's Quick Look).
    Pdf,
    /// Plain text or code in a file window (the Mac's Quick Look reads it).
    Text,
    /// [WIN-FILE-DELIMITED] A .csv or .tsv in the app's own table in a file window (SpreadsheetFile, MacFileWindow.viewer);
    /// one the table can't read goes to its own app as before (DelimitedFile.Read answers null).
    Table,
    /// Nothing here draws it: its own app, as before (the Mac's share sheet for a file Quick Look can't show).
    OwnApp,
}

/// What a file opened from a chat, a tile, a task or the files list opens in (FilePreviewPresenter.present): a note
/// formatted, a page live, anything this app can draw in a window of its own.
public static class FileWindowRoute
{
    public static FileWindowShows For(string name, long bytes)
    {
        var dot = name.LastIndexOf('.');
        var ext = dot <= 0 ? "" : name[(dot + 1)..].ToLowerInvariant();
        if (ArtifactFiles.MarkdownExtensions.Contains(ext)) return bytes <= ArtifactFiles.TextLimit ? FileWindowShows.Note : FileWindowShows.OwnApp;
        if (ext is "html" or "htm") return FileWindowShows.Page;
        if (ext == "pdf") return FileWindowShows.Pdf;
        if (DelimitedFile.Extensions.Contains(ext)) return DelimitedFile.Opens(name, bytes) ? FileWindowShows.Table : FileWindowShows.OwnApp;
        if (ArtifactFiles.TextExtensions.Contains(ext) && bytes <= ArtifactFiles.TextLimit) return FileWindowShows.Text;
        return FileWindowShows.OwnApp;
    }
}

/// MacFileWindow.openInDefaultApp: the other app gets a copy in a folder of its own, so its edits and the kept copy
/// keep apart.
public static class FileWindowCopies
{
    public static string ForOtherApp(string tempRoot, string name, Guid id)
    {
        // Not Path.GetFileName: on Windows it reads "a:b.txt" as a drive and keeps "b.txt" (CI run 44990350697).
        var leaf = name.Replace('\\', '/').Split('/').Last();
        var safe = string.Concat(leaf.Select(c => Path.GetInvalidFileNameChars().Contains(c) || c is '<' or '>' or ':' or '"' or '|' or '?' or '*' ? '_' : c));
        if (safe.Length == 0 || safe is "." or "..") safe = "file";
        return Path.Combine(tempRoot, "Opened", id.ToString("N"), safe);
    }
}
