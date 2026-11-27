using System.Text.RegularExpressions;
using Hermes.Core.Kanban;

namespace Hermes.Core.Tests;

/// The task panel's comment field (App/Pages/Kanban/KanbanTaskSheet.swift:1187–1213 at 93f984bb1): pasted paragraphs
/// and a trailing line break stay in the draft through a redraw, Return posts the draft once, a blank draft or one
/// already sending cannot post, and Post and Start Over is only its own button. Every task, draft and post here is
/// synthetic, held by a local stand-in panel; no gateway, keyboard or window is touched.
public class KanbanCommentDraftTests
{
    private const string Pasted = "First paragraph of the note.\r\n\r\nSecond paragraph:\r\n- one\r\n- two\r\n";
    private const string Kept = "First paragraph of the note.\n\nSecond paragraph:\n- one\n- two\n";

    /// A stand-in for KanbanTaskPanel's comment box: the field (a multi-line WinUI TextBox, which spells a line break
    /// "\r"), the kept draft, the busy writes, and a gateway that records posts and holds each one until let go.
    private sealed class Panel(string taskId, bool running)
    {
        public string TaskId { get; } = taskId;
        public bool Running { get; } = running;
        public string Field { get; private set; } = "";
        public string Draft { get; private set; } = "";
        public HashSet<string> Busy { get; } = [];
        public List<(string Task, string Body)> Posts { get; } = [];
        public List<string> Restarts { get; } = [];
        public int FieldWrites { get; private set; }
        private readonly Queue<TaskCompletionSource> _pending = new();

        private bool Sending => Busy.Contains("comment") || Busy.Contains("requeue");
        public bool SendEnabled => KanbanCommentDraft.CanSend(Draft, Sending);
        public bool RequeueShown => Running && KanbanCommentDraft.Body(Draft).Length > 0;

        /// What the field does with typed or pasted words (AcceptsReturn on: every break kept, spelt "\r").
        public void Paste(string text)
        {
            Field += KanbanCommentDraft.Normalize(text).Replace('\n', '\r');
            Draft = KanbanCommentDraft.Normalize(Field);
        }

        /// A read redrawing the panel: the field is put back only if it shows something else than the draft.
        public void Refresh()
        {
            if (!KanbanCommentDraft.FieldDiffers(Field, Draft)) return;
            Field = Draft.Replace('\n', '\r');
            FieldWrites++;
        }

        /// Return in the field; true when the key was taken (no new line made).
        public bool Return(bool shift = false, bool repeat = false)
        {
            switch (KanbanCommentDraft.OnReturn(Draft, Sending, shift, repeat))
            {
                case KanbanCommentDraft.ReturnAction.NewLine: Paste("\n"); return false;
                case KanbanCommentDraft.ReturnAction.Post: Send(false); return true;
                default: return true;
            }
        }

        public void Send(bool requeue)
        {
            if (!KanbanCommentDraft.CanSend(Draft, Sending)) return;
            if (requeue && !Running) return;
            var key = requeue ? "requeue" : "comment";
            Busy.Add(key);
            Posts.Add((TaskId, KanbanCommentDraft.Body(Draft)));
            var gate = new TaskCompletionSource();
            _pending.Enqueue(gate);
            _ = Finish();

            async Task Finish()
            {
                var ok = true;
                try { await gate.Task; } catch { ok = false; }
                Busy.Remove(key);
                if (!ok) return;
                Draft = "";
                Field = "";
                if (requeue) Restarts.Add(TaskId);
            }
        }

        public void Land() => _pending.Dequeue().SetResult();
        public void Fail() => _pending.Dequeue().SetException(new HttpRequestException("synthetic failure"));
    }

    [Fact]
    public void TheOldSingleLineFieldKeptOnlyTheFirstLineOfAPaste()
    {
        // What AcceptsReturn = false did to this paste (MultilineTextBoxSourceTests: only the first line survives).
        var singleLine = Pasted.Split(['\r', '\n'])[0];
        Assert.NotEqual(KanbanCommentDraft.Body(Kept), singleLine);
        Assert.Equal("First paragraph of the note.", singleLine);
    }

    [Fact]
    public void LineBreaksAreKeptInTheMacsSpellingWithTheTrailingOne()
    {
        Assert.Equal(Kept, KanbanCommentDraft.Normalize(Pasted));
        Assert.Equal("a\n\nb\n", KanbanCommentDraft.Normalize("a\r\rb\r"));
        Assert.Equal("", KanbanCommentDraft.Normalize(null));
        Assert.False(KanbanCommentDraft.FieldDiffers("a\rb\r", "a\nb\n"));
        Assert.True(KanbanCommentDraft.FieldDiffers("a\rb", "a\nb\n"));
    }

    [Fact]
    public void BlankOrSendingCannotPost()
    {
        Assert.False(KanbanCommentDraft.CanSend("", false));
        Assert.False(KanbanCommentDraft.CanSend(" \r\n\t\n", false));
        Assert.False(KanbanCommentDraft.CanSend("words", true));
        Assert.True(KanbanCommentDraft.CanSend("words", false));
    }

    [Fact]
    public void ReturnPostsShiftReturnMakesALineAndAHeldKeyNeverPostsTwice()
    {
        Assert.Equal(KanbanCommentDraft.ReturnAction.Post, KanbanCommentDraft.OnReturn("hi", false, shift: false, repeat: false));
        Assert.Equal(KanbanCommentDraft.ReturnAction.NewLine, KanbanCommentDraft.OnReturn("hi", false, shift: true, repeat: false));
        Assert.Equal(KanbanCommentDraft.ReturnAction.Swallow, KanbanCommentDraft.OnReturn("hi", false, shift: false, repeat: true));
        Assert.Equal(KanbanCommentDraft.ReturnAction.Swallow, KanbanCommentDraft.OnReturn("  \n", false, shift: false, repeat: false));
        Assert.Equal(KanbanCommentDraft.ReturnAction.Swallow, KanbanCommentDraft.OnReturn("hi", true, shift: false, repeat: false));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void APasteSurvivesRefreshesAndReturnPostsTheWholeDraftOnce(bool running)
    {
        var panel = new Panel(running ? "t_synthetic_running" : "t_synthetic_ready", running);
        panel.Paste(Pasted);
        Assert.Equal(Kept, panel.Draft);
        panel.Refresh();
        panel.Refresh();
        Assert.Equal(Kept, panel.Draft);
        Assert.EndsWith("\n", panel.Draft);
        Assert.Equal(0, panel.FieldWrites); // the field was never rewritten under the caret
        Assert.Empty(panel.Posts);
        Assert.Equal(running, panel.RequeueShown);

        Assert.True(panel.Return());
        Assert.True(panel.Return());            // a second press while the first is on its way
        Assert.True(panel.Return(repeat: true)); // the key held down
        panel.Send(false);                       // the Send button too
        panel.Send(true);                        // and Post and Start Over
        Assert.Equal([(panel.TaskId, KanbanCommentDraft.Body(Kept))], panel.Posts);
        Assert.Contains("\n\nSecond paragraph:\n- one\n- two", panel.Posts[0].Body);
        Assert.False(panel.SendEnabled);

        panel.Land();
        Assert.Equal("", panel.Draft);
        Assert.Empty(panel.Restarts); // Return never starts the task over
        Assert.True(panel.Return());  // nothing left to post
        Assert.Single(panel.Posts);
    }

    [Fact]
    public void ShiftReturnAddsALineAndPostsNothing()
    {
        var panel = new Panel("t_synthetic_ready", running: false);
        panel.Paste("line one");
        Assert.False(panel.Return(shift: true));
        panel.Paste("line two");
        panel.Refresh();
        Assert.Equal("line one\nline two", panel.Draft);
        Assert.Empty(panel.Posts);
    }

    [Fact]
    public void ABlankDraftNeverPostsAndKeepsItsBreaks()
    {
        var panel = new Panel("t_synthetic_running", running: true);
        panel.Paste("\r\n  \r\n");
        Assert.True(panel.Return());
        panel.Send(false);
        panel.Send(true);
        Assert.Empty(panel.Posts);
        Assert.False(panel.SendEnabled);
        Assert.False(panel.RequeueShown);
        Assert.Equal("\n  \n", panel.Draft);
    }

    [Fact]
    public void PostAndStartOverIsItsOwnChoiceOnARunningTask()
    {
        var panel = new Panel("t_synthetic_running", running: true);
        panel.Paste(Pasted);
        panel.Send(true);
        Assert.True(panel.Return()); // Return while it is on its way posts nothing more
        panel.Land();
        Assert.Equal([("t_synthetic_running", KanbanCommentDraft.Body(Kept))], panel.Posts);
        Assert.Equal(["t_synthetic_running"], panel.Restarts);

        var ready = new Panel("t_synthetic_ready", running: false);
        ready.Paste("note");
        ready.Send(true);
        Assert.Empty(ready.Posts);
        Assert.False(ready.RequeueShown);
    }

    [Fact]
    public void AFailedPostKeepsTheWholeDraftForTryAgain()
    {
        var panel = new Panel("t_synthetic_ready", running: false);
        panel.Paste(Pasted);
        panel.Return();
        panel.Fail();
        panel.Refresh();
        Assert.Equal(Kept, panel.Draft);
        Assert.True(panel.SendEnabled);
        Assert.True(panel.Return());
        panel.Land();
        Assert.Equal(2, panel.Posts.Count);
        Assert.All(panel.Posts, p => Assert.Equal(KanbanCommentDraft.Body(Kept), p.Body));
    }

    // ------------------------------------------------------------------ the panel's hookup (source)

    private static string PanelSource()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Kanban", "KanbanTaskPanel.cs"));
    }

    private static string Method(string source, string signature)
    {
        var start = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(start >= 0, signature);
        var open = source.IndexOf('{', start);
        var depth = 0;
        for (var i = open; i < source.Length; i++)
        {
            if (source[i] == '{') depth++;
            else if (source[i] == '}' && --depth == 0) return source[start..(i + 1)];
        }
        throw new InvalidOperationException(signature);
    }

    [Fact]
    public void TheFieldTakesLineBreaksAndReturnIsReadBeforeTheFieldMakesALine()
    {
        var box = Method(PanelSource(), "private FrameworkElement CommentBoxOnce()");
        Assert.Matches(new Regex(@"_commentBox\s*=\s*new TextBox\s*\{\s*AcceptsReturn\s*=\s*true"), box);
        Assert.DoesNotContain("AcceptsReturn = false", box);
        // A multi-line TextBox takes Return itself before KeyDown, so the panel reads it on PreviewKeyDown.
        Assert.Contains("_commentBox.PreviewKeyDown +=", box);
        Assert.DoesNotContain("_commentBox.KeyDown +=", box);
        Assert.Contains("KanbanCommentDraft.OnReturn(", box);
        Assert.Contains("KanbanCommentDraft.Normalize(_commentBox.Text)", box);
        Assert.Contains("KanbanCommentDraft.FieldDiffers(_commentBox.Text, _comment)", box);
        Assert.DoesNotContain("SendComment(true)", box.Replace("_requeue.Click += (_, _) => SendComment(true);", ""));
    }

    [Fact]
    public void SendingPostsTheKeptDraftOnceThroughTheSameWrite()
    {
        var send = Method(PanelSource(), "private void SendComment(bool requeue)");
        Assert.Contains("KanbanCommentDraft.CanSend(_comment, Sending())", send);
        Assert.Contains("KanbanCommentDraft.Body(_comment)", send);
        Assert.Contains("api.CommentAsync(id, body, board)", send);
        var buttons = Method(PanelSource(), "private void UpdateCommentButtons()");
        Assert.Contains("KanbanCommentDraft.CanSend(_comment, Sending())", buttons);
    }
}
