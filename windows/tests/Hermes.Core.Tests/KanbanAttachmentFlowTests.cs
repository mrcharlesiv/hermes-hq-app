using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Kanban;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Add Attachment on a Kanban task (App/Pages/Kanban/KanbanTaskAttachments.swift): a menu of Photo Library (one photo
/// or video) then Choose File (one file), and one upload to the task and board the row was chosen on. Every pick here
/// is a synthetic file in a scratch folder; no system picker, user file or gateway is touched.
public class KanbanAttachmentFlowTests
{
    private static string Scratch()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hq-kanban-media-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static KanbanAttachmentPick Synthetic(string dir, string name, int bytes = 12)
    {
        var path = Path.Combine(dir, name);
        File.WriteAllBytes(path, new byte[bytes]);
        return new KanbanAttachmentPick(path, name);
    }

    /// A stand-in panel: what it shows can change while the picker is "open".
    private sealed class Panel
    {
        public KanbanAttachmentState Now = new("t_1", "home", 0, ReadOnly: false, Online: true, Uploading: false);
        public List<(KanbanAttachmentTarget Target, KanbanAttachmentPick Pick)> Uploads { get; } = [];
        public List<KanbanAttachmentChoice> Pickers { get; } = [];
        public KanbanAttachmentFlow Flow { get; }
        public Panel() => Flow = new KanbanAttachmentFlow(() => Now);

        public Task<bool> Upload(KanbanAttachmentTarget target, KanbanAttachmentPick pick)
        {
            Uploads.Add((target, pick));
            return Task.FromResult(true);
        }
    }

    [Fact]
    public void TheMenuIsPhotoLibraryThenChooseFileWithTheMacsWordsAndItsOwnNames()
    {
        Assert.Equal([KanbanAttachmentSource.PhotoLibrary, KanbanAttachmentSource.File], KanbanAttachmentFlow.Choices.Select(c => c.Source));
        Assert.Equal(["Photo Library", "Choose File"], KanbanAttachmentFlow.Choices.Select(c => c.Label));
        Assert.Equal(["kanban.task.add-attachment.photo", "kanban.task.add-attachment.file"], KanbanAttachmentFlow.Choices.Select(c => c.AutomationId));
        Assert.Equal(KanbanCopy.PhotoLibrary, KanbanAttachmentFlow.PhotoLibrary.Label);
        Assert.Equal(KanbanCopy.ChooseFile, KanbanAttachmentFlow.ChooseFile.Label);
        Assert.All(KanbanAttachmentFlow.Choices, c => Assert.False(string.IsNullOrEmpty(c.Glyph)));
    }

    [Fact]
    public void PhotoLibraryStartsInPicturesWithPhotosAndVideosOnlyAndChooseFileTakesAnything()
    {
        var photo = KanbanAttachmentFlow.PhotoLibrary;
        Assert.Equal(KanbanPickerStart.PicturesLibrary, photo.Start);
        Assert.True(photo.Thumbnails);
        foreach (var type in new[] { ".jpg", ".jpeg", ".png", ".heic", ".gif", ".mov", ".mp4", ".m4v" }) Assert.Contains(type, photo.FileTypes);
        Assert.DoesNotContain("*", photo.FileTypes);
        Assert.DoesNotContain(".pdf", photo.FileTypes);
        Assert.DoesNotContain(".zip", photo.FileTypes);
        Assert.All(photo.FileTypes, t => Assert.Matches("^\\.[a-z0-9]+$", t));

        var file = KanbanAttachmentFlow.ChooseFile;
        Assert.Equal(KanbanPickerStart.DocumentsLibrary, file.Start);
        Assert.False(file.Thumbnails);
        Assert.Equal(["*"], file.FileTypes);
    }

    [Theory]
    [InlineData(KanbanAttachmentSource.PhotoLibrary, "clip.mov")]
    [InlineData(KanbanAttachmentSource.File, "brief.pdf")]
    public async Task EachRowOpensItsOwnPickerAndSendsOneUploadToTheBoundTaskAndBoard(KanbanAttachmentSource source, string name)
    {
        var dir = Scratch();
        var panel = new Panel();
        var outcome = await panel.Flow.RunAsync(source, choice =>
        {
            panel.Pickers.Add(choice);
            Assert.True(panel.Flow.Picking);
            return Task.FromResult<KanbanAttachmentPick?>(Synthetic(dir, name));
        }, panel.Upload);
        Assert.Equal(KanbanAttachmentOutcome.Uploaded, outcome);
        Assert.Equal(source, Assert.Single(panel.Pickers).Source);
        var (target, pick) = Assert.Single(panel.Uploads);
        Assert.Equal(new KanbanAttachmentTarget("t_1", "home", 0), target);
        Assert.Equal(name, pick.Name);
        Assert.False(panel.Flow.Picking);
    }

    [Fact]
    public async Task ACancelledPickerSendsNothing()
    {
        var panel = new Panel();
        foreach (var source in new[] { KanbanAttachmentSource.PhotoLibrary, KanbanAttachmentSource.File })
            Assert.Equal(KanbanAttachmentOutcome.Cancelled, await panel.Flow.RunAsync(source, _ => Task.FromResult<KanbanAttachmentPick?>(null), panel.Upload));
        Assert.Empty(panel.Uploads);
        Assert.False(panel.Flow.Picking);
    }

    [Fact]
    public async Task ASecondRowWhileAPickerIsOpenOrAnUploadRunsOpensNothing()
    {
        var dir = Scratch();
        var panel = new Panel();
        var open = new TaskCompletionSource<KanbanAttachmentPick?>();
        var first = panel.Flow.RunAsync(KanbanAttachmentSource.PhotoLibrary, _ => open.Task, panel.Upload);
        Assert.True(panel.Flow.Picking);
        Assert.Equal(KanbanAttachmentOutcome.Busy, await panel.Flow.RunAsync(KanbanAttachmentSource.File, c => { panel.Pickers.Add(c); return Task.FromResult<KanbanAttachmentPick?>(Synthetic(dir, "b.txt")); }, panel.Upload));
        open.SetResult(Synthetic(dir, "a.jpg"));
        Assert.Equal(KanbanAttachmentOutcome.Uploaded, await first);
        Assert.Empty(panel.Pickers);
        Assert.Equal("a.jpg", Assert.Single(panel.Uploads).Pick.Name);

        panel.Now = panel.Now with { Uploading = true };
        Assert.Equal(KanbanAttachmentOutcome.Busy, await panel.Flow.RunAsync(KanbanAttachmentSource.File, c => { panel.Pickers.Add(c); return Task.FromResult<KanbanAttachmentPick?>(null); }, panel.Upload));
        Assert.Empty(panel.Pickers);
    }

    [Fact]
    public async Task ReadOnlyOfflineOrNoTaskOpensNoPicker()
    {
        var panel = new Panel();
        Task<KanbanAttachmentPick?> Never(KanbanAttachmentChoice c) { panel.Pickers.Add(c); return Task.FromResult<KanbanAttachmentPick?>(null); }
        var shown = panel.Now;
        panel.Now = shown with { ReadOnly = true };
        Assert.False(KanbanAttachmentFlow.CanOffer(panel.Now));
        Assert.Equal(KanbanAttachmentOutcome.ReadOnly, await panel.Flow.RunAsync(KanbanAttachmentSource.PhotoLibrary, Never, panel.Upload));
        panel.Now = shown with { Online = false };
        Assert.False(KanbanAttachmentFlow.CanOffer(panel.Now));
        Assert.Equal(KanbanAttachmentOutcome.Offline, await panel.Flow.RunAsync(KanbanAttachmentSource.File, Never, panel.Upload));
        panel.Now = shown with { TaskId = null };
        Assert.Equal(KanbanAttachmentOutcome.NoTask, await panel.Flow.RunAsync(KanbanAttachmentSource.File, Never, panel.Upload));
        Assert.True(KanbanAttachmentFlow.CanOffer(shown));
        Assert.Empty(panel.Pickers);
        Assert.Empty(panel.Uploads);
    }

    public static TheoryData<string> Changes => new() { "task", "board", "epoch", "readonly", "offline", "uploading" };

    [Theory]
    [MemberData(nameof(Changes))]
    public async Task WhatChangesWhileThePickerIsOpenSendsNothing(string change)
    {
        var dir = Scratch();
        var panel = new Panel();
        var outcome = await panel.Flow.RunAsync(KanbanAttachmentSource.PhotoLibrary, _ =>
        {
            panel.Now = change switch
            {
                "task" => panel.Now with { TaskId = "t_2" },
                "board" => panel.Now with { Board = "work" },
                "epoch" => panel.Now with { Epoch = panel.Now.Epoch + 1 },   // the panel closed, stopped or opened a linked task
                "readonly" => panel.Now with { ReadOnly = true },
                "offline" => panel.Now with { Online = false },
                _ => panel.Now with { Uploading = true },
            };
            return Task.FromResult<KanbanAttachmentPick?>(Synthetic(dir, "photo.jpg"));
        }, panel.Upload);
        var expected = change switch
        {
            "readonly" => KanbanAttachmentOutcome.ReadOnly,
            "offline" => KanbanAttachmentOutcome.Offline,
            "uploading" => KanbanAttachmentOutcome.Busy,
            _ => KanbanAttachmentOutcome.ContextChanged,
        };
        Assert.Equal(expected, outcome);
        Assert.Empty(panel.Uploads);
    }

    [Fact]
    public async Task ABoardLeftAndReturnedToWhileThePickerIsOpenSendsNothing()
    {
        // The board moved away and back while the picker was open: the epoch says the panel was left, so nothing goes.
        var dir = Scratch();
        var panel = new Panel();
        var outcome = await panel.Flow.RunAsync(KanbanAttachmentSource.File, _ =>
        {
            panel.Now = panel.Now with { Board = "work", Epoch = 1 };
            panel.Now = panel.Now with { Board = "home", Epoch = 2 };
            return Task.FromResult<KanbanAttachmentPick?>(Synthetic(dir, "a.txt"));
        }, panel.Upload);
        Assert.Equal(KanbanAttachmentOutcome.ContextChanged, outcome);
        Assert.Empty(panel.Uploads);
    }

    [Fact]
    public async Task APickerThatThrowsLeavesTheMenuUsable()
    {
        var dir = Scratch();
        var panel = new Panel();
        await Assert.ThrowsAsync<InvalidOperationException>(() => panel.Flow.RunAsync(KanbanAttachmentSource.PhotoLibrary, _ => throw new InvalidOperationException("picker"), panel.Upload));
        Assert.False(panel.Flow.Picking);
        Assert.Equal(KanbanAttachmentOutcome.Uploaded, await panel.Flow.RunAsync(KanbanAttachmentSource.File, _ => Task.FromResult<KanbanAttachmentPick?>(Synthetic(dir, "b.txt")), panel.Upload));
    }

    /// A gateway stand-in whose upload reports progress, then answers or fails.
    private sealed class ProgressRest(Func<string> answer) : IPagesRest
    {
        public List<(string Path, Dictionary<string, string> Query)> Uploads { get; } = [];
        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null, JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default) =>
            Task.FromResult<JsonNode?>(null);
        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile, TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default)
        {
            Uploads.Add((path, (query ?? []).ToDictionary(k => k.Key, k => k.Value)));
            var total = new FileInfo(bodyFile).Length;
            progress?.Invoke(total / 2, total);
            progress?.Invoke(total, total);
            try { return Task.FromResult(answer()); }
            catch (Exception e) { return Task.FromException<string>(e); }
        }
        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling, CancellationToken ct = default) => Task.CompletedTask;
    }

    /// The panel's upload, as KanbanTaskPanel.UploadAsync makes it: the bound task and board, progress past 1 MB.
    private static Func<KanbanAttachmentTarget, KanbanAttachmentPick, Task<bool>> Uploader(KanbanApi api, string scratch, List<double> bar, List<string> failures) => async (target, pick) =>
    {
        double? progress = null;
        try
        {
            progress = KanbanAttachmentFlow.StartProgress(new FileInfo(pick.Path).Length);
            await api.AddAttachmentAsync(target.TaskId, pick.Path, KanbanAttachmentUpload.SendName(pick.Name), target.Board, scratch,
                progress: (sent, total) => { if (progress != null && KanbanAttachmentFlow.Fraction(sent, total) is { } f) { progress = f; bar.Add(f); } });
            return true;
        }
        catch (Exception e)
        {
            failures.Add(KanbanAttachmentFlow.Reason(e).Text);
            return false;
        }
    };

    [Fact]
    public async Task ALargePickShowsProgressAndGoesToTheBoundBoardOnce()
    {
        var dir = Scratch();
        var rest = new ProgressRest(() => """{"attachment":{"id":9,"filename":"clip.mov","size":2097152}}""");
        var api = new KanbanApi(rest);
        var bar = new List<double>();
        var failures = new List<string>();
        var panel = new Panel();
        var outcome = await panel.Flow.RunAsync(KanbanAttachmentSource.PhotoLibrary,
            _ => Task.FromResult<KanbanAttachmentPick?>(Synthetic(dir, "clip.mov", 2 * 1024 * 1024)), Uploader(api, Path.Combine(dir, "scratch"), bar, failures));
        Assert.Equal(KanbanAttachmentOutcome.Uploaded, outcome);
        var (path, query) = Assert.Single(rest.Uploads);
        Assert.Equal("/api/plugins/kanban/tasks/t_1/attachments", path);
        Assert.Equal("home", query["board"]);
        Assert.Equal([0.5, 1.0], bar.Select(f => Math.Round(f, 1)));
        Assert.Empty(failures);
        Assert.True(File.Exists(Path.Combine(dir, "clip.mov")), "the picked file is read in place, never removed");
        Assert.Null(KanbanAttachmentFlow.StartProgress(1024));
        Assert.Null(KanbanAttachmentFlow.Fraction(5, 0));
    }

    [Fact]
    public async Task AFailedUploadSaysWhyAndTheNextPickStillWorks()
    {
        var dir = Scratch();
        var fail = true;
        var rest = new ProgressRest(() => fail ? throw FakeRest.Http(404, null) : """{"attachment":{"id":1,"filename":"a.txt","size":3}}""");
        var api = new KanbanApi(rest);
        var failures = new List<string>();
        var panel = new Panel();
        var upload = Uploader(api, Path.Combine(dir, "scratch"), [], failures);
        Assert.Equal(KanbanAttachmentOutcome.Failed, await panel.Flow.RunAsync(KanbanAttachmentSource.File, _ => Task.FromResult<KanbanAttachmentPick?>(Synthetic(dir, "a.txt")), upload));
        Assert.Equal(["This task is no longer on the board."], failures);
        Assert.True(KanbanAttachmentFlow.Reason(FakeRest.Http(404, null)).Gone);
        fail = false;
        Assert.Equal(KanbanAttachmentOutcome.Uploaded, await panel.Flow.RunAsync(KanbanAttachmentSource.File, _ => Task.FromResult<KanbanAttachmentPick?>(Synthetic(dir, "a.txt")), upload));
        Assert.Equal(2, rest.Uploads.Count);
    }

    [Fact]
    public async Task APickThatCannotBeReadWhereItLiesSaysSoAndSendsNothing()
    {
        var dir = Scratch();
        var rest = new ProgressRest(() => "{}");
        var failures = new List<string>();
        var panel = new Panel();
        var outcome = await panel.Flow.RunAsync(KanbanAttachmentSource.File,
            _ => Task.FromResult<KanbanAttachmentPick?>(new KanbanAttachmentPick(Path.Combine(dir, "gone.txt"), "gone.txt")),
            Uploader(new KanbanApi(rest), Path.Combine(dir, "scratch"), [], failures));
        Assert.Equal(KanbanAttachmentOutcome.Failed, outcome);
        Assert.Equal(["This file could not be read."], failures);
        Assert.Equal("This file could not be read.", KanbanAttachmentFlow.Reason(new ArgumentException("empty path")).Text);
        Assert.Empty(rest.Uploads);
    }

    // ------------------------------------------------------------------ the panel's hookup (source)

    private static string PanelSource()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Kanban", "KanbanTaskPanel.cs"));
    }

    // A Windows checkout (core.autocrlf) hands us CRLF; the method boundary below is written in LF.
    private static string Method(string source, string signature)
    {
        source = source.ReplaceLineEndings("\n");
        var at = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(at >= 0, signature + " not found");
        var end = source.IndexOf("\n    }\n", at, StringComparison.Ordinal);
        return source[at..end];
    }

    [Fact]
    public void TheAddAttachmentRowOpensTheTwoChoiceMenuNotAPicker()
    {
        var panel = PanelSource();
        var row = Method(panel, "private void Attachments(");
        Assert.Contains("Flyout = AttachmentMenu()", row);
        Assert.Contains("\"kanban.task.add-attachment\"", row);
        Assert.Contains("SetName(add, KanbanCopy.AddAttachment)", row);
        Assert.DoesNotContain("add.Click", row);
        Assert.Contains("KanbanAttachmentFlow.CanOffer(AttachmentState())", row);
        var menu = Method(panel, "private MenuFlyout AttachmentMenu()");
        Assert.Contains("foreach (var choice in KanbanAttachmentFlow.Choices)", menu);
        Assert.Contains("AddAttachmentAsync(source)", menu);
        Assert.Contains("SetName(item, choice.Label)", menu);
        Assert.Contains("SetAutomationId(item, choice.AutomationId)", menu);
        Assert.DoesNotContain("ChooseFileAsync", panel);
    }

    [Fact]
    public void TheSourceChecksReadTheSameMethodFromACrlfCheckout()
    {
        var lf = PanelSource().ReplaceLineEndings("\n");
        var crlf = lf.Replace("\n", "\r\n");
        Assert.Equal(Method(lf, "private void Attachments("), Method(crlf, "private void Attachments("));
    }

    [Fact]
    public void ThePickerIsSetFromTheChoiceAndNeverListsALibrary()
    {
        var panel = PanelSource();
        var pick = Method(panel, "private async Task<KanbanAttachmentPick?> PickAsync(");
        Assert.Contains("new FileOpenPicker", pick);
        Assert.Contains("choice.Start == KanbanPickerStart.PicturesLibrary ? PickerLocationId.PicturesLibrary : PickerLocationId.DocumentsLibrary", pick);
        Assert.Contains("foreach (var type in choice.FileTypes) picker.FileTypeFilter.Add(type);", pick);
        Assert.Contains("PickSingleFileAsync()", pick);
        Assert.DoesNotContain("FileTypeFilter.Add(\"*\")", panel);
        foreach (var broad in new[] { "KnownFolders", "GetFilesAsync", "GetItemsAsync", "StorageLibrary", "picturesLibrary", "videosLibrary" })
            Assert.DoesNotContain(broad, panel);
    }

    [Fact]
    public void TheUploadUsesTheBoundTargetAndLeavingTheTaskMovesTheEpoch()
    {
        var panel = PanelSource();
        var upload = Method(panel, "private async Task<bool> UploadAsync(");
        Assert.Contains("AddAttachmentAsync(target.TaskId, pick.Path, KanbanAttachmentUpload.SendName(pick.Name), target.Board,", upload);
        Assert.DoesNotContain("_store.Slug", upload);
        Assert.DoesNotContain("_taskId", upload);
        Assert.Contains("KanbanAttachmentFlow.StartProgress(", upload);
        Assert.Contains("KanbanAttachmentFlow.Reason(e)", upload);
        Assert.Contains("FailedAsync(XamlRoot, KanbanAttachmentUpload.FailureTitle", upload);
        Assert.Contains("_attach.RunAsync(source, PickAsync,", Method(panel, "private async Task AddAttachmentAsync(KanbanAttachmentSource source)"));
        Assert.Matches(new Regex(@"public void Stop\(\) \{ _epoch\+\+;"), panel);
        Assert.Contains("_epoch++;", Method(panel, "private void Open(string id)"));
        var state = Method(panel, "private KanbanAttachmentState AttachmentState()");
        Assert.Contains("_store.Slug, _epoch, _store.ReadOnlyGateway", state);
        Assert.Contains("c.AccountId == _store.AccountId && c.Rpc.State == ConnectionState.Open", state);
    }
}
