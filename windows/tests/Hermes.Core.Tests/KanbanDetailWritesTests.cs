using System.Text.RegularExpressions;
using Hermes.Core.Kanban;

namespace Hermes.Core.Tests;

/// The task panel's writes keep to the task they were made on (App/Pages/Kanban/KanbanTaskSheet.swift open(_:), audit
/// 863 08c-5): a notice, alert, Try Again, cleared draft, spinner or re-read of one task never lands on the next one,
/// the same id reopened, or the same id on another board, and a write the person made is still sent. Two synthetic
/// tasks, writes held open by hand; no gateway or host is touched.
public class KanbanDetailWritesTests
{
    /// A stand-in panel with the parts the writes touch.
    private sealed class Panel : IKanbanDetailHost
    {
        public string TaskId = "t_1";
        public string Board = "home";
        public int Epoch;
        public int OpenedCount;
        public bool ReadOnlyGateway;
        public string Draft = "";
        public string? Editing;
        public HashSet<string> BusyKeys { get; } = [];
        public List<string> Notices { get; } = [];
        public List<(string Title, string Reason, Func<Task> Retry)> Alerts { get; } = [];
        public List<string> TaskReads { get; } = [];
        public int BoardReads;
        public List<string> Logs { get; } = [];
        public KanbanDetailWrites Writes { get; }

        public Panel() => Writes = new KanbanDetailWrites(this);

        public KanbanDetailContext Now => new(TaskId, Board, Epoch);
        public int Opened => OpenedCount;
        public bool ReadOnly => ReadOnlyGateway;
        public ISet<string> Busy => BusyKeys;
        public void Changed() { }
        public void Notice(string text) => Notices.Add($"{TaskId}@{Board}: {text}");
        public Task Alert(string title, string reason, Func<Task> retry) { Alerts.Add(($"{TaskId}@{Board}: {title}", reason, retry)); return Task.CompletedTask; }
        public Task ReadTask() { TaskReads.Add($"{TaskId}@{Board}"); return Task.CompletedTask; }
        public Task ReadBoard() { BoardReads++; return Task.CompletedTask; }
        public void Log(string text) => Logs.Add(text);

        /// Open(_:) as the panel does it: the first task's draft, spinners and notice stay with it.
        public void Open(string id)
        {
            TaskId = id;
            OpenedCount++;
            Epoch++;
            Draft = "";
            Editing = null;
            BusyKeys.Clear();
            Notices.Clear();
        }

        public void Close() => Epoch++;
    }

    /// A write the test lets finish (or fail) when it chooses, recording the board it went to.
    private sealed class Held
    {
        private readonly TaskCompletionSource _gate = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<string> Sent { get; } = [];
        public Task Write(string board) { Sent.Add(board); return _gate.Task; }
        public void Finish() => _gate.TrySetResult();
        public void Fail(string why) => _gate.TrySetException(new InvalidOperationException(why));
    }

    private static Task Course(Panel panel, KanbanDetailStep step)
    {
        Assert.Equal(KanbanDetailStart.Started, panel.Writes.Start(step, out var course));
        return course;
    }

    [Fact]
    public async Task AFailedNoticeForTheFirstTaskNeverShowsOnTheSecond()
    {
        var panel = new Panel();
        var held = new Held();
        var course = Course(panel, new KanbanDetailStep("reclaim", held.Write));
        panel.Open("t_2");
        held.Fail("gateway said no");
        await course;
        Assert.Empty(panel.Notices);
        Assert.Empty(panel.Alerts);
        Assert.Equal(["home"], held.Sent);
        Assert.Contains("task write reclaim failed after the panel left the task", panel.Logs);
        Assert.DoesNotContain(panel.Logs, l => l.Contains("gateway said no"));
    }

    [Fact]
    public async Task AFailedNoticeShowsWhileTheSameTaskIsShown()
    {
        var panel = new Panel();
        var held = new Held();
        var course = Course(panel, new KanbanDetailStep("reclaim", held.Write));
        held.Fail("gateway said no");
        await course;
        Assert.Single(panel.Notices);
        Assert.StartsWith("t_1@home: ", panel.Notices[0]);
        Assert.Empty(panel.BusyKeys);
    }

    [Fact]
    public async Task ACommentPostedLateKeepsTheSecondTasksDraftAndReadsOnlyTheBoard()
    {
        var panel = new Panel { Draft = "first note" };
        var held = new Held();
        var course = Course(panel, new KanbanDetailStep("comment", held.Write, () => panel.Draft = ""));
        panel.Open("t_2");
        panel.Draft = "second task's words";
        held.Finish();
        await course;
        Assert.Equal("second task's words", panel.Draft);
        Assert.Equal(["home"], held.Sent);
        Assert.Empty(panel.TaskReads);
        Assert.Equal(1, panel.BoardReads);
    }

    [Fact]
    public async Task ADescriptionSavedLateLeavesTheSecondTasksEditorOpen()
    {
        var panel = new Panel { Editing = "first body" };
        var held = new Held();
        var course = Course(panel, new KanbanDetailStep("body", held.Write, () => panel.Editing = null));
        panel.Open("t_2");
        panel.Editing = "second body being typed";
        held.Finish();
        await course;
        Assert.Equal("second body being typed", panel.Editing);
    }

    [Fact]
    public async Task AFailedCommentAfterLeavingRaisesNoAlertAndIsNeverSentAgain()
    {
        var panel = new Panel();
        var held = new Held();
        var course = Course(panel, new KanbanDetailStep("comment", held.Write, () => panel.Draft = ""));
        panel.Open("t_2");
        panel.Draft = "kept";
        held.Fail("offline");
        await course;
        Assert.Empty(panel.Alerts);
        Assert.Empty(panel.Notices);
        Assert.Single(held.Sent);
        Assert.Equal("kept", panel.Draft);
    }

    [Fact]
    public async Task ReopeningTheSameIdIsANewLifetime()
    {
        // t_1 → t_2 → back to t_1 through the links: the old comment's success must not clear the new draft.
        var panel = new Panel();
        var held = new Held();
        var course = Course(panel, new KanbanDetailStep("comment", held.Write, () => panel.Draft = ""));
        panel.Open("t_2");
        panel.Open("t_1");
        panel.Draft = "a fresh note on t_1";
        held.Finish();
        await course;
        Assert.Equal("a fresh note on t_1", panel.Draft);
        Assert.Empty(panel.TaskReads);

        var failing = new Held();
        var second = Course(panel, new KanbanDetailStep("move", failing.Write));
        panel.Open("t_2");
        panel.Open("t_1");
        failing.Fail("conflict");
        await second;
        Assert.Empty(panel.Alerts);
        Assert.Empty(panel.Notices);
    }

    [Fact]
    public async Task TheSameIdOnAnotherBoardIsAnotherTask()
    {
        // Within one panel the board is part of where a write belongs, even if nothing else moved.
        var panel = new Panel();
        var held = new Held();
        var course = Course(panel, new KanbanDetailStep("move", held.Write));
        panel.Board = "work";
        held.Fail("gone");
        await course;
        Assert.Equal(["home"], held.Sent);
        Assert.Empty(panel.Alerts);
        Assert.Empty(panel.TaskReads);

        // Switching board closes the panel and a new one opens t_1 on the other board: the first panel's write
        // reaches neither.
        var first = new Panel();
        var second = new Panel { Board = "work" };
        var late = new Held();
        var lateCourse = Course(first, new KanbanDetailStep("assign", late.Write));
        first.Close();
        second.Draft = "draft on work's t_1";
        late.Fail("nope");
        await lateCourse;
        Assert.Equal(["home"], late.Sent);
        Assert.Empty(first.Alerts);
        Assert.Empty(second.Alerts);
        Assert.Equal("draft on work's t_1", second.Draft);
    }

    [Fact]
    public async Task AClosedPanelGetsNoFeedbackButTheWriteIsStillSent()
    {
        var panel = new Panel();
        var held = new Held();
        var done = 0;
        var course = Course(panel, new KanbanDetailStep("priority", held.Write, () => done++));
        panel.Close();
        held.Finish();
        await course;
        Assert.Equal(["home"], held.Sent);
        Assert.Equal(0, done);
        Assert.Empty(panel.TaskReads);
        Assert.Equal(1, panel.BoardReads);
    }

    [Fact]
    public async Task PostAndStartOverStillStartsTheFirstTaskAgainButQuietly()
    {
        var panel = new Panel { Draft = "start over with this" };
        var comment = new Held();
        var restart = new Held();
        var restartDone = 0;
        var course = Course(panel, new KanbanDetailStep("requeue", comment.Write, () => panel.Draft = "",
            new KanbanDetailStep(KanbanWriteWords.Restart, restart.Write, () => restartDone++)));
        panel.Open("t_2");
        panel.Draft = "t_2's draft";
        comment.Finish();
        restart.Fail("still running");
        await course;
        Assert.Equal(["home"], comment.Sent);
        Assert.Equal(["home"], restart.Sent);
        Assert.Equal(0, restartDone);
        Assert.Empty(panel.Notices);
        Assert.Empty(panel.Alerts);
        Assert.Empty(panel.BusyKeys);
        Assert.Equal("t_2's draft", panel.Draft);
    }

    [Fact]
    public async Task PostAndStartOverOnTheSameTaskClearsTheBoxThenStartsAgainWithItsNotice()
    {
        var panel = new Panel { Draft = "note" };
        var restartCourse = new TaskCompletionSource();
        var course = Course(panel, new KanbanDetailStep("requeue", _ => Task.CompletedTask, () => panel.Draft = "",
            new KanbanDetailStep(KanbanWriteWords.Restart, _ => Task.CompletedTask, () => { panel.Notice(KanbanCopy.NotePosted); restartCourse.TrySetResult(); })));
        await course;
        await restartCourse.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("", panel.Draft);
        Assert.Equal([$"t_1@home: {KanbanCopy.NotePosted}"], panel.Notices);
    }

    [Fact]
    public async Task TheFirstTasksSpinnerNeverClearsTheSecondTasksOwn()
    {
        var panel = new Panel();
        var first = new Held();
        var firstCourse = Course(panel, new KanbanDetailStep("move", first.Write));
        panel.Open("t_2");
        var second = new Held();
        var secondCourse = Course(panel, new KanbanDetailStep("move", second.Write));
        first.Finish();
        await firstCourse;
        Assert.Contains("move", panel.BusyKeys);
        second.Finish();
        await secondCourse;
        Assert.DoesNotContain("move", panel.BusyKeys);
        Assert.Equal(["t_2@home"], panel.TaskReads);
    }

    [Fact]
    public async Task TryAgainWorksOnTheSameTaskAndIsDroppedOnceThePanelMoves()
    {
        var panel = new Panel();
        var tries = 0;
        Task Failing(string board) { tries++; return Task.FromException(new InvalidOperationException("no")); }
        await Course(panel, new KanbanDetailStep("assign", Failing));
        var alert = Assert.Single(panel.Alerts);
        Assert.Equal("t_1@home: " + KanbanWriteWords.FailureTitle("assign"), alert.Title);
        Assert.Empty(panel.BusyKeys);
        await alert.Retry();
        Assert.Equal(2, tries);

        panel.Open("t_2");
        await panel.Alerts[^1].Retry();
        Assert.Equal(2, tries);
        Assert.Contains("task write assign: Try Again dropped, the panel left the task", panel.Logs);
    }

    [Fact]
    public void OneWritePerKeyAndReadOnlyStaysLocal()
    {
        var panel = new Panel();
        var held = new Held();
        Assert.Equal(KanbanDetailStart.Started, panel.Writes.Run(new KanbanDetailStep("move", held.Write)));
        Assert.Equal(KanbanDetailStart.Busy, panel.Writes.Run(new KanbanDetailStep("move", held.Write)));
        Assert.Single(held.Sent);

        var locked = new Panel { ReadOnlyGateway = true };
        var never = new Held();
        Assert.Equal(KanbanDetailStart.ReadOnly, locked.Writes.Run(new KanbanDetailStep("comment", never.Write)));
        Assert.Empty(never.Sent);
        Assert.Equal([$"t_1@home: {KanbanRest.ReadOnlyNotice}"], locked.Notices);
        Assert.Empty(locked.BusyKeys);
    }

    // ------------------------------------------------------------------ the panel's hookup (source)

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", "Features", "Kanban", .. parts])).ReplaceLineEndings("\n");
    }

    private static string Method(string source, string signature)
    {
        var at = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(at >= 0, signature + " not found");
        var end = source.IndexOf("\n    }\n", at, StringComparison.Ordinal);
        return source[at..end];
    }

    [Fact]
    public void OpeningAnotherTaskClearsTheNoticeAndItsPendingHide()
    {
        var panel = Source("KanbanTaskPanel.cs");
        Assert.Contains("_notice.Clear();", Method(panel, "private void Open(string id)"));
        Assert.Contains("_notice.Clear();", Method(panel, "public void Stop()"));
        var kit = Source("PageKit.cs");
        var clear = Method(kit, "public void Clear()");
        Assert.Contains("_shown++", clear);
        Assert.Contains("Bar.IsOpen = false", clear);
        Assert.Contains("Bar.ActionButton = null", clear);
    }

    [Fact]
    public void ThePanelsWritesGoThroughTheBoundRunner()
    {
        var panel = Source("KanbanTaskPanel.cs");
        var run = Method(panel, "private void Run(");
        Assert.Contains("_writes.Run(", run);
        Assert.DoesNotContain("FailedAsync", run);
        Assert.DoesNotContain("_taskId", Method(panel, "private void SendComment("));
        Assert.Contains("_store.Slug, _epoch", Method(panel, "KanbanDetailContext IKanbanDetailHost.Now"));
        // The estimate lands only on the task it was asked for, through the bound follow-up.
        var estimate = Method(panel, "private void RunEstimate()");
        Assert.DoesNotContain("_taskId", estimate);
        Assert.Matches(new Regex(@"\(\) => _estimate = said"), estimate);
        // A read lands only where it was asked.
        Assert.Contains("_writes.Holds(at)", Method(panel, "private async Task ReadAsync()"));
        Assert.Contains("_writes.Holds(at)", Method(panel, "private async Task ReadLogAsync()"));
        Assert.Contains("_writes.Holds(at)", Method(panel, "private async Task OpenAttachmentAsync("));
    }
}
