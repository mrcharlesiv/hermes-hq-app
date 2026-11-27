using Hermes.Core.Workspace;

namespace Hermes.Core.Tests;

/// [WIN-INSPECTOR-FILES-LIFETIME] The chat inspector's Files tab (MacInspector `.files`, WorkspacePage(kind: .files,
/// panel: true) in MoreWorkspacePages.swift): only the lifetime on screen, its current folder and its newest read or
/// open may show rows, text or an error, or ask for an alert or an external open. Before, Unloaded cancelled the read
/// but coming back skipped the still-set folder (a spinner for good), a chat losing its folder left its read running,
/// and Open landed text, alerts and external opens after a newer navigation. All I/O here is a fake held by the test.
public class InspectorFilesLifetimeTests
{
    private static readonly WorkspaceEntry Docs = new("docs", "/Users/me/proj/docs", true);
    private static readonly WorkspaceEntry Src = new("src", "/Users/me/proj/src", true);
    private static readonly WorkspaceEntry Readme = new("README.md", "/Users/me/proj/README.md", false);
    private static readonly WorkspaceEntry Photo = new("photo.png", "/Users/me/proj/photo.png", false);

    /// Every call is held until the test answers it; `IgnoreCancel` keeps a cancelled call answerable, as a reader
    /// that doesn't watch its token would be.
    private sealed class HeldReader : IInspectorFilesReader
    {
        public sealed class Call<T>(string path, CancellationToken ct)
        {
            public string Path { get; } = path;
            public CancellationToken Token { get; } = ct;
            public TaskCompletionSource<T> Gate { get; } = new();
        }

        public bool IgnoreCancel;
        public readonly List<Call<List<WorkspaceEntry>>> Lists = [];
        public readonly List<Call<WorkspaceFileText>> Reads = [];
        public readonly List<Call<string>> Downloads = [];

        private Task<T> Hold<T>(List<Call<T>> calls, string path, CancellationToken ct)
        {
            var call = new Call<T>(path, ct);
            calls.Add(call);
            if (!IgnoreCancel) ct.Register(() => call.Gate.TrySetCanceled(ct));
            return call.Gate.Task;
        }

        public Task<List<WorkspaceEntry>> ListAsync(string directory, CancellationToken ct) => Hold(Lists, directory, ct);
        public Task<WorkspaceFileText> ReadTextAsync(string path, CancellationToken ct) => Hold(Reads, path, ct);
        public Task<string> DownloadAsync(WorkspaceEntry entry, CancellationToken ct) => Hold(Downloads, entry.Path, ct);
    }

    private sealed class Harness
    {
        public string? Folder = "/Users/me/proj";
        public HeldReader? Reader = new();
        public readonly Queue<Action> Posted = new();
        public readonly List<(string Path, string Name)> Opened = [];
        public readonly List<string> Alerts = [];
        public readonly InspectorFilesFlow Flow;

        public Harness()
        {
            Flow = new InspectorFilesFlow(() => Folder, () => Reader, Posted.Enqueue, work => work());
            Flow.OpenExternally += (path, name) => Opened.Add((path, name));
            Flow.OpenFailed += Alerts.Add;
        }

        public HeldReader R => Reader!;

        /// The UI thread runs what was posted to it.
        public void Pump()
        {
            while (Posted.TryDequeue(out var work)) work();
        }

        public void AnswerList(int index, params WorkspaceEntry[] rows)
        {
            R.Lists[index].Gate.TrySetResult([.. rows]);
            Pump();
        }

        public void FailList(int index, string reason = "Permission denied")
        {
            R.Lists[index].Gate.TrySetException(new WorkspaceReadException(reason));
            Pump();
        }

        /// Attached and showing the root's two folders and two files.
        public static Harness Listed()
        {
            var h = new Harness();
            h.Flow.Attach();
            h.AnswerList(0, Docs, Src, Readme, Photo);
            return h;
        }
    }

    private static InspectorFilesContent.Listing Listing(Harness h) => Assert.IsType<InspectorFilesContent.Listing>(h.Flow.Content);

    [Fact]
    public void NoFolderSaysNoFolderAndReadsNothing()
    {
        var h = new Harness { Folder = null };
        h.Flow.Attach();
        Assert.IsType<InspectorFilesContent.NoFolder>(h.Flow.Content);
        Assert.Empty(h.R.Lists);
        Assert.False(h.Flow.IsBusy);
    }

    [Fact]
    public void RootListsOnAttachAndShowsItsRows()
    {
        var h = new Harness();
        h.Flow.Attach();
        Assert.Equal(new InspectorFilesContent.Loading("/Users/me/proj"), h.Flow.Content);
        h.AnswerList(0, Docs, Readme);
        var listing = Listing(h);
        Assert.Equal("/Users/me/proj", listing.Folder);
        Assert.Null(listing.Up);
        Assert.Equal(["docs", "README.md"], listing.Rows.Select(r => r.Name));
        Assert.False(h.Flow.IsBusy);
    }

    [Fact]
    public void FolderRemovedWhileReadingCancelsItAndALateAnswerShowsNothing()
    {
        var h = new Harness();
        h.R.IgnoreCancel = true;
        h.Flow.Attach();
        h.Folder = null;
        h.Flow.FolderChanged();
        Assert.True(h.R.Lists[0].Token.IsCancellationRequested);
        Assert.IsType<InspectorFilesContent.NoFolder>(h.Flow.Content);
        h.AnswerList(0, Readme);
        Assert.IsType<InspectorFilesContent.NoFolder>(h.Flow.Content);
        Assert.False(h.Flow.IsBusy);
    }

    [Fact]
    public void FolderRemovedWhileOpeningCancelsTheOpen()
    {
        var h = Harness.Listed();
        h.R.IgnoreCancel = true;
        h.Flow.Open(Photo);
        h.Folder = null;
        h.Flow.FolderChanged();
        Assert.True(h.R.Downloads[0].Token.IsCancellationRequested);
        h.R.Downloads[0].Gate.SetResult("/tmp/photo.png");
        h.Pump();
        Assert.Empty(h.Opened);
        Assert.IsType<InspectorFilesContent.NoFolder>(h.Flow.Content);
    }

    [Fact]
    public void ReplacedRootShowsOnlyTheNewRoot()
    {
        var h = new Harness();
        h.R.IgnoreCancel = true;
        h.Flow.Attach();
        h.Folder = "/Users/me/other";
        h.Flow.FolderChanged();
        Assert.Equal(["/Users/me/proj", "/Users/me/other"], h.R.Lists.Select(c => c.Path));
        h.AnswerList(1, Src);
        h.AnswerList(0, Readme);   // the old root's late answer
        var listing = Listing(h);
        Assert.Equal("/Users/me/other", listing.Folder);
        Assert.Equal(["src"], listing.Rows.Select(r => r.Name));
        Assert.Equal("/Users/me/other", h.Flow.Root);
    }

    [Fact]
    public void ReplacedRootFromABrowsedFolderStartsAtTheNewTop()
    {
        var h = Harness.Listed();
        h.Flow.Open(Docs);
        h.AnswerList(1, Readme);
        h.Folder = "/Users/me/other";
        h.Flow.FolderChanged();
        Assert.Equal("/Users/me/other", h.R.Lists[2].Path);
    }

    [Fact]
    public void SameRootSaidAgainKeepsWhatIsShown()
    {
        var h = Harness.Listed();
        var shown = h.Flow.Content;
        h.Flow.FolderChanged();
        Assert.Single(h.R.Lists);
        Assert.Same(shown, h.Flow.Content);
    }

    [Fact]
    public void ConsecutiveReadsShowOnlyTheNewest()
    {
        var h = Harness.Listed();
        h.R.IgnoreCancel = true;
        h.Flow.Open(Docs);
        // The rows are still the root's until Docs answers; a second click goes to Src instead.
        Assert.IsType<InspectorFilesContent.Loading>(h.Flow.Content);
        h.Flow.List(Src.Path);
        Assert.True(h.R.Lists[1].Token.IsCancellationRequested);
        h.AnswerList(2, Readme);
        h.AnswerList(1, Photo);   // Docs's late answer
        var listing = Listing(h);
        Assert.Equal(Src.Path, listing.Folder);
        Assert.Equal(["README.md"], listing.Rows.Select(r => r.Name));
    }

    [Fact]
    public void LateFailureAfterANewerReadShowsNoError()
    {
        var h = Harness.Listed();
        h.R.IgnoreCancel = true;
        h.Flow.Open(Docs);
        h.Flow.Back();
        h.AnswerList(2, Readme);
        h.FailList(1);
        var listing = Listing(h);
        Assert.Null(listing.Failure);
        Assert.Equal("/Users/me/proj", listing.Folder);
    }

    [Fact]
    public void FailureShowsTryAgainWhichReadsTheSameFolder()
    {
        var h = new Harness();
        h.Flow.Attach();
        h.FailList(0);
        Assert.NotNull(Listing(h).Failure);
        h.Flow.Retry();
        Assert.Equal("/Users/me/proj", h.R.Lists[1].Path);
        h.AnswerList(1, Readme);
        Assert.Null(Listing(h).Failure);
    }

    [Fact]
    public void BackFromAFolderListsTheOneHoldingIt()
    {
        var h = Harness.Listed();
        h.Flow.Open(Docs);
        h.AnswerList(1, Readme);
        Assert.Equal("/Users/me/proj", Listing(h).Up);
        h.Flow.Back();
        Assert.Equal("/Users/me/proj", h.R.Lists[2].Path);
        h.AnswerList(2, Docs);
        Assert.Null(Listing(h).Up);
    }

    [Fact]
    public void BackAtTheRootDoesNothing()
    {
        var h = Harness.Listed();
        h.Flow.Back();
        Assert.Single(h.R.Lists);
    }

    [Fact]
    public void DetachWhileReadingThenReturnReadsTheSameFolderAgain()
    {
        // The original bug: Unloaded cancelled the read, and Loaded skipped the still-set folder: a spinner for good.
        var h = new Harness();
        h.Flow.Attach();
        h.Flow.Detach();
        Assert.True(h.R.Lists[0].Token.IsCancellationRequested);
        h.Flow.Attach();
        Assert.Equal(2, h.R.Lists.Count);
        Assert.Equal("/Users/me/proj", h.R.Lists[1].Path);
        h.AnswerList(1, Readme);
        Assert.Equal(["README.md"], Listing(h).Rows.Select(r => r.Name));
    }

    [Fact]
    public void DetachWhileReadingASubfolderReturnsToThatSubfolder()
    {
        var h = Harness.Listed();
        h.Flow.Open(Docs);
        h.Flow.Detach();
        h.Flow.Attach();
        Assert.Equal(Docs.Path, h.R.Lists[^1].Path);
        h.AnswerList(h.R.Lists.Count - 1, Readme);
        Assert.Equal(Docs.Path, Listing(h).Folder);
    }

    [Fact]
    public void LateSuccessWhileDetachedShowsNothingAndReturnRecovers()
    {
        var h = new Harness();
        h.R.IgnoreCancel = true;
        h.Flow.Attach();
        h.Flow.Detach();
        h.AnswerList(0, Photo);
        Assert.IsType<InspectorFilesContent.Loading>(h.Flow.Content);
        h.Flow.Attach();
        h.AnswerList(1, Readme);
        Assert.Equal(["README.md"], Listing(h).Rows.Select(r => r.Name));
    }

    [Fact]
    public void LateFailureWhileDetachedShowsNothing()
    {
        var h = new Harness();
        h.R.IgnoreCancel = true;
        h.Flow.Attach();
        h.Flow.Detach();
        h.FailList(0);
        Assert.IsType<InspectorFilesContent.Loading>(h.Flow.Content);
    }

    [Fact]
    public void ReturnAfterSuccessKeepsTheListingWithoutReadingAgain()
    {
        var h = Harness.Listed();
        h.Flow.Open(Docs);
        h.AnswerList(1, Readme);
        var shown = h.Flow.Content;
        h.Flow.Detach();
        h.Flow.Attach();
        Assert.Equal(2, h.R.Lists.Count);
        Assert.Same(shown, h.Flow.Content);
    }

    [Fact]
    public void ReturnAfterAFailureReadsAgain()
    {
        var h = new Harness();
        h.Flow.Attach();
        h.FailList(0);
        h.Flow.Detach();
        h.Flow.Attach();
        Assert.Equal(2, h.R.Lists.Count);
    }

    [Fact]
    public void ReturnWithANewRootListsTheNewRoot()
    {
        var h = Harness.Listed();
        h.Flow.Detach();
        h.Folder = "/Users/me/other";
        h.Flow.Attach();
        Assert.Equal("/Users/me/other", h.R.Lists[^1].Path);
    }

    [Fact]
    public void ReturnWithNoFolderSaysNoFolder()
    {
        var h = Harness.Listed();
        h.Flow.Detach();
        h.Folder = null;
        h.Flow.Attach();
        Assert.IsType<InspectorFilesContent.NoFolder>(h.Flow.Content);
        Assert.Single(h.R.Lists);
    }

    [Fact]
    public void FolderEventsWhileDetachedReadNothing()
    {
        var h = Harness.Listed();
        h.Flow.Detach();
        h.Folder = "/Users/me/other";
        h.Flow.FolderChanged();
        Assert.Single(h.R.Lists);
    }

    [Fact]
    public void NoConnectionWaitsAndReadsOnReturn()
    {
        var h = new Harness();
        var reader = h.Reader;
        h.Reader = null;
        h.Flow.Attach();
        Assert.IsType<InspectorFilesContent.Loading>(h.Flow.Content);
        h.Reader = reader;
        h.Flow.Detach();
        h.Flow.Attach();
        Assert.Single(h.R.Lists);
        h.AnswerList(0, Readme);
        Assert.Single(Listing(h).Rows);
    }

    [Fact]
    public void TextFileShowsInThePanelAndBackRestoresTheListingAsItWas()
    {
        var h = Harness.Listed();
        var listing = Listing(h);
        h.Flow.Open(Readme);
        h.R.Reads[0].Gate.SetResult(new WorkspaceFileText(Readme.Path, "# Hello", false, false));
        h.Pump();
        var text = Assert.IsType<InspectorFilesContent.Text>(h.Flow.Content);
        Assert.Equal("README.md", text.Name);
        Assert.Equal("# Hello", text.File.Text);
        h.Flow.Back();
        Assert.Same(listing, h.Flow.Content);
        Assert.Single(h.R.Lists);
        Assert.Empty(h.Opened);
    }

    [Fact]
    public void TextReturnedAfterNavigationIsNotShown()
    {
        var h = Harness.Listed();
        h.R.IgnoreCancel = true;
        h.Flow.Open(Readme);
        h.Flow.Open(Docs);
        Assert.True(h.R.Reads[0].Token.IsCancellationRequested);
        h.R.Reads[0].Gate.SetResult(new WorkspaceFileText(Readme.Path, "late", false, false));
        h.Pump();
        Assert.IsType<InspectorFilesContent.Loading>(h.Flow.Content);
        h.AnswerList(1, Photo);
        Assert.Equal(Docs.Path, Listing(h).Folder);
    }

    [Fact]
    public void DownloadReturnedAfterNavigationOpensNothing()
    {
        var h = Harness.Listed();
        h.R.IgnoreCancel = true;
        h.Flow.Open(Photo);
        Assert.Empty(h.R.Reads);   // not text: never read as text
        h.Flow.Open(Docs);
        h.R.Downloads[0].Gate.SetResult("/tmp/photo.png");
        h.Pump();
        Assert.Empty(h.Opened);
    }

    [Fact]
    public void FailedOpenAfterNavigationShowsNoAlert()
    {
        var h = Harness.Listed();
        h.R.IgnoreCancel = true;
        h.Flow.Open(Photo);
        h.Flow.Open(Docs);
        h.R.Downloads[0].Gate.SetException(new WorkspaceReadException("Gone"));
        h.Pump();
        Assert.Empty(h.Alerts);
    }

    [Fact]
    public void OpenAfterDetachRequestsNothing()
    {
        var h = Harness.Listed();
        h.R.IgnoreCancel = true;
        h.Flow.Open(Photo);
        h.Flow.Open(Readme);
        h.Flow.Detach();
        Assert.True(h.R.Downloads[0].Token.IsCancellationRequested);
        Assert.True(h.R.Reads[0].Token.IsCancellationRequested);
        h.R.Downloads[0].Gate.SetResult("/tmp/photo.png");
        h.R.Reads[0].Gate.SetException(new WorkspaceReadException("Gone"));
        h.Pump();
        Assert.Empty(h.Opened);
        Assert.Empty(h.Alerts);
        Assert.IsType<InspectorFilesContent.Listing>(h.Flow.Content);
        // Back with the same root: the listing that was shown stays, with no new read.
        h.Flow.Attach();
        Assert.Single(h.R.Lists);
        h.Flow.Open(Photo);
        h.R.Downloads[1].Gate.SetResult("/tmp/photo2.png");
        h.Pump();
        Assert.Equal([("/tmp/photo2.png", "photo.png")], h.Opened);
    }

    [Fact]
    public void NewerOpenSupersedesTheOneBefore()
    {
        var h = Harness.Listed();
        h.R.IgnoreCancel = true;
        h.Flow.Open(Photo);
        h.Flow.Open(Readme);
        h.R.Reads[0].Gate.SetResult(new WorkspaceFileText(Readme.Path, "hi", false, false));
        h.R.Downloads[0].Gate.SetResult("/tmp/photo.png");
        h.Pump();
        Assert.Empty(h.Opened);
        Assert.IsType<InspectorFilesContent.Text>(h.Flow.Content);
    }

    [Fact]
    public void CurrentOpenOpensOnceOrAlertsOnce()
    {
        var h = Harness.Listed();
        h.Flow.Open(Photo);
        h.R.Downloads[0].Gate.SetResult("/tmp/photo.png");
        h.Pump();
        Assert.Equal([("/tmp/photo.png", "photo.png")], h.Opened);
        h.Flow.Open(Photo);
        h.R.Downloads[1].Gate.SetException(new WorkspaceReadException("No such file"));
        h.Pump();
        Assert.Equal(["No such file"], h.Alerts);
        Assert.Single(h.Opened);
    }

    [Fact]
    public void BinaryOrTooLargeTextIsDownloadedInstead()
    {
        var h = Harness.Listed();
        h.Flow.Open(Readme);
        h.R.Reads[0].Gate.SetResult(new WorkspaceFileText(Readme.Path, "", true, false));
        Assert.Single(h.R.Downloads);
        h.R.Downloads[0].Gate.SetResult("/tmp/a");
        h.Pump();
        h.Flow.Open(Readme);
        h.R.Reads[1].Gate.SetException(new ChatWorkspace.TooLargeException());
        Assert.Equal(2, h.R.Downloads.Count);
        h.R.Downloads[1].Gate.SetResult("/tmp/b");
        h.Pump();
        Assert.Equal([("/tmp/a", "README.md"), ("/tmp/b", "README.md")], h.Opened);
        Assert.Empty(h.Alerts);
    }

    [Fact]
    public void OpenOnAFailedListingDoesNothing()
    {
        var h = new Harness();
        h.Flow.Attach();
        h.FailList(0);
        h.Flow.Open(Readme);
        Assert.Empty(h.R.Reads);
        Assert.Empty(h.R.Downloads);
    }

    // MARK: The view (source coverage; the WinUI view itself is proven only on Windows)

    private static string ViewSource()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Workspace", "InspectorFiles.cs"));
    }

    [Fact]
    public void ViewLeavesLifetimeToTheFlow()
    {
        var source = ViewSource();
        Assert.Contains("new InspectorFilesFlow(", source);
        Assert.Contains("Loaded += (_, _) => { ChatFolders.FolderChanged += OnFolder; _flow.Attach(); };", source);
        Assert.Contains("Unloaded += (_, _) => { ChatFolders.FolderChanged -= OnFolder; _flow.Detach(); };", source);
        Assert.Contains("_flow.FolderChanged", source);
        // No reads, tokens or folder state of its own: those are what let stale answers land.
        Assert.DoesNotContain("Task.Run", source);
        Assert.DoesNotContain("CancellationTokenSource", source);
        Assert.DoesNotContain("_folder", source);
        Assert.DoesNotContain("_root", source);
    }

    [Fact]
    public void ViewOpensAndAlertsOnlyWhenTheFlowAsks()
    {
        var source = ViewSource();
        Assert.Contains("_flow.OpenExternally += (path, name) => _ = MediaActions.OpenAsync(path, name);", source);
        Assert.Contains("_flow.OpenFailed += reason => _ = W.AskAsync(XamlRoot, \"Couldn’t Open This File\", reason);", source);
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(source, @"MediaActions\.OpenAsync\("));
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(source, @"W\.AskAsync\("));
        Assert.Contains("b.Click += (_, _) => _flow.Open(entry);", source);
        Assert.Contains("() => _flow.Back()", source);
        Assert.Contains("() => _flow.Retry()", source);
    }
}
