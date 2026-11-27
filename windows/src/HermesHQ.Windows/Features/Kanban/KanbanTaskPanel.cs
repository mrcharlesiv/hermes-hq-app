using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Kanban;
using Hermes.Core.Rpc;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.Storage.Pickers;
using Windows.System;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Kanban;

/// A Kanban task beside the board (App/Pages/Kanban/KanbanTaskSheet.swift, the Mac's panel: "an inspector"): ✕ · Task ·
/// ⋯ at the top; the status pop-up, the title and who made it; what is happening now (the bot at work, what the board
/// needs from you with the one next move, Unblock / Mark Ready / Reopen); Assigned To and Priority; Waiting On / Holding
/// Up; Result; the description (Edit); Latest Update, Last Error; Comments / Activity / Runs / Log; Attachments with
/// Add Attachment; Details; Estimate Effort. Read every 30 s while open.
internal sealed class KanbanTaskPanel : UserControl, IKanbanDetailHost
{
    private enum Feed { Comments, Activity, Runs, Log }

    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly KanbanStore _store;
    private readonly KanbanPage _board;
    private string _taskId;
    private KanbanTaskDetail? _detail;
    private string? _error;
    private (bool Exists, string Content) _log = (false, "");
    private readonly HashSet<string> _busy = [];
    private Feed _feed = Feed.Comments;
    private string _comment = "";
    private string? _editing;
    private string? _estimate;
    private double? _uploadProgress;
    private CancellationTokenSource? _poll;
    private int _generation;
    private readonly StackPanel _page = new() { Spacing = 8, Padding = new Thickness(16, 4, 16, 24) };
    private readonly NoticeLine _notice = new();
    private TextBox? _commentBox;
    private Button? _send;
    private HyperlinkButton? _requeue;
    private bool _pendingRender;
    private TextBox? _bodyBox;
    /// Moves whenever the panel leaves the task it shows (a linked task opened, the panel stopped or closed): a picker
    /// that returns after that sends nothing.
    private int _epoch;
    private readonly KanbanAttachmentFlow _attach;
    /// The writes, each bound to the task, board and epoch it was made on (KanbanDetailWrites).
    private readonly KanbanDetailWrites _writes;
    private HermesClient? _watched;

    public KanbanTaskPanel(KanbanStore store, string taskId, KanbanPage board)
    {
        _store = store;
        _taskId = taskId;
        _board = board;
        _attach = new KanbanAttachmentFlow(AttachmentState);
        _writes = new KanbanDetailWrites(this);
        AutomationProperties.SetAutomationId(this, "kanban.task");
        var close = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(close, KanbanCopy.CloseTask);
        AutomationProperties.SetAutomationId(close, "kanban.task.close");
        close.Click += (_, _) => _board.CloseTask();
        var more = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Style = Style("QuietButtonStyle"), Flyout = MoreMenu() };
        AutomationProperties.SetName(more, KanbanCopy.More);
        var title = Text(KanbanCopy.Task, 14, bold: true);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        title.VerticalAlignment = VerticalAlignment.Center;
        var bar = new Grid { Padding = new Thickness(8, 8, 8, 4) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(close);
        Grid.SetColumn(title, 1);
        bar.Children.Add(title);
        Grid.SetColumn(more, 2);
        bar.Children.Add(more);
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        var scroll = new ScrollViewer { Content = _page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);
        _notice.Bar.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetRow(_notice.Bar, 1);
        root.Children.Add(_notice.Bar);
        Content = root;
        Render();
    }

    private KanbanTask? Task => _detail?.Task;
    private bool Running => Task?.Status == "running";

    // ------------------------------------------------------------------ reads

    public void Start()
    {
        _poll?.Cancel();
        var cts = _poll = new CancellationTokenSource();
        Watch(AppState.Client);
        _ = PollAsync(cts.Token);
    }

    public void Stop() { _epoch++; _poll?.Cancel(); _poll = null; Watch(null); _notice.Clear(); }

    /// Add Attachment shows only while the gateway is reachable: draw again when the link changes.
    private void Watch(HermesClient? client)
    {
        if (ReferenceEquals(client, _watched)) return;
        if (_watched != null) _watched.Rpc.StateChanged -= LinkChanged;
        _watched = client;
        if (client != null) client.Rpc.StateChanged += LinkChanged;
    }

    private void LinkChanged(ConnectionState _) => _ui.TryEnqueue(Render);

    public void Reload() => _ = ReadAsync();

    private async Task PollAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            await ReadAsync();
            await ReadLogAsync();
            try { await System.Threading.Tasks.Task.Delay(TimeSpan.FromSeconds(_feed == Feed.Log ? (Running ? 3 : 15) : 30), ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// A read lands only on the task, board and epoch it was asked for.
    private async Task ReadAsync()
    {
        var at = ((IKanbanDetailHost)this).Now;
        try
        {
            var fresh = await _store.Api.TaskAsync(at.TaskId, at.Board);
            if (!_writes.Holds(at)) return;
            _detail = fresh;
            _error = null;
        }
        catch (Exception e)
        {
            if (!_writes.Holds(at)) return;
            if (_detail == null) _error = KanbanRest.Reason(e);
        }
        Render();
    }

    private async Task ReadLogAsync()
    {
        var at = ((IKanbanDetailHost)this).Now;
        try
        {
            var found = await _store.Api.LogAsync(at.TaskId, at.Board);
            if (_writes.Holds(at) && found != _log) { _log = found; Render(); }
        }
        catch (Exception) { }
    }

    /// A linked task opens in the same panel.
    private void Open(string id)
    {
        _taskId = id;
        _generation++;
        _epoch++;
        _detail = null;
        _error = null;
        _editing = null;
        _estimate = null;
        _comment = "";
        _busy.Clear();
        // Audit 863 (08c-5): the first task's notice, and its pending hide, stay with it.
        _notice.Clear();
        _feed = Feed.Comments;
        _log = (false, "");
        if (_commentBox != null) _commentBox.Text = "";
        _pendingRender = false;
        _page.Children.Clear();
        Render();
        Start();
    }

    // ------------------------------------------------------------------ writes (one per key at a time; the task and the board read again after each)

    private void Show(string text) => _notice.Show(text);

    /// One write, bound to where it was made: its alert, Try Again, notice, follow-up, spinner and re-read reach only
    /// this task on this board in this opening; the write itself is never cancelled by leaving (KanbanDetailWrites).
    private void Run(string key, Func<KanbanApi, string, Task> write, Action? done = null, KanbanDetailStep? next = null) =>
        _writes.Run(Step(key, write, done, next));

    private KanbanDetailStep Step(string key, Func<KanbanApi, string, Task> write, Action? done = null, KanbanDetailStep? next = null)
    {
        var api = _store.Api;
        return new KanbanDetailStep(key, board => write(api, board), done, next);
    }

    // ------------------------------------------------------------------ IKanbanDetailHost (what the bound writes see)

    KanbanDetailContext IKanbanDetailHost.Now => new(_taskId, _store.Slug, _epoch);
    int IKanbanDetailHost.Opened => _generation;
    bool IKanbanDetailHost.ReadOnly => _store.ReadOnlyGateway;
    ISet<string> IKanbanDetailHost.Busy => _busy;
    void IKanbanDetailHost.Changed() => Render();
    void IKanbanDetailHost.Notice(string text) => Show(text);
    Task IKanbanDetailHost.Alert(string title, string reason, Func<Task> retry) => FailedAsync(XamlRoot, title, reason, retry);
    Task IKanbanDetailHost.ReadTask() => ReadAsync();
    Task IKanbanDetailHost.ReadBoard() => _store.ReadBoardAsync();
    void IKanbanDetailHost.Log(string text) => AppLog.Note("kanban", text);

    private void Move(string to)
    {
        if (Task is not { } task || to == task.Status) return;
        if (KanbanModel.IsLocked(to)) { Show(KanbanModel.LockedReason(to)); return; }
        var id = task.Id;
        Run("move", (api, board) => api.PatchAsync(id, new JsonObject { ["status"] = to }, board));
    }

    private void Assign(string profile)
    {
        if (Task is not { } task || profile == (task.Assignee ?? "")) return;
        var id = task.Id;
        Run("assign", (api, board) => api.ReassignAsync(id, profile, board));
    }

    private void SetPriority(int value)
    {
        if (Task is not { } task || value == (task.Priority ?? 0)) return;
        var id = task.Id;
        Run("priority", (api, board) => api.PatchAsync(id, new JsonObject { ["priority"] = value }, board));
    }

    private void SaveBody()
    {
        if (Task is not { } task || _editing is not { } text) return;
        var id = task.Id;
        Run("body", (api, board) => api.PatchAsync(id, new JsonObject { ["body"] = text }, board), () => _editing = null);
    }

    private void SendComment(bool requeue)
    {
        // Once at a time and only with words: Return, Send and Post and Start Over all come through here.
        if (Task is not { } task || !KanbanCommentDraft.CanSend(_comment, Sending())) return;
        var body = KanbanCommentDraft.Body(_comment);
        var id = task.Id;
        // Post and Start Over is two writes, told apart: once the comment is posted the box clears; only the start
        // again is tried again.
        // Its follow-ups run only while this task is still shown here; the start again is still sent if the panel has
        // moved on, quietly (KanbanDetailWrites).
        Run(requeue ? "requeue" : "comment", (api, board) => api.CommentAsync(id, body, board), () =>
        {
            _comment = "";
            if (_commentBox != null) _commentBox.Text = "";
        }, requeue ? Step(KanbanWriteWords.Restart, (api, board) => api.ReclaimAsync(id, board), () => Show(KanbanCopy.NotePosted)) : null);
    }

    private void Reclaim()
    {
        if (Task is not { } task) return;
        var id = task.Id;
        Run("reclaim", (api, board) => api.ReclaimAsync(id, board));
    }

    private void RunEstimate()
    {
        if (Task is not { } task) return;
        var id = task.Id;
        string? said = null;
        Run("estimate", async (api, board) => said = await api.EstimateAsync(id, board), () => _estimate = said);
    }

    private void CopyText(string text, string what)
    {
        Copy(text);
        Show(KanbanCopy.Copied(what));
    }

    private async Task AskPriorityAsync()
    {
        if (Task is not { } task) return;
        var text = (await PromptAsync(XamlRoot, KanbanCopy.Priority, KanbanCopy.PriorityPrompt, (task.Priority ?? 0).ToString(), KanbanCopy.Set, "0"))?.Trim();
        if (string.IsNullOrEmpty(text)) return;
        if (!int.TryParse(text, out var value) || value < 0) { Show(KanbanCopy.PriorityWhole); return; }
        SetPriority(value);
    }

    // ------------------------------------------------------------------ Add Attachment (KanbanTaskAttachments.swift)

    /// The task, board and link right now. Online only on this store's own account (another account's gateway is not
    /// this board's).
    private KanbanAttachmentState AttachmentState() => new(Task?.Id, _store.Slug, _epoch, _store.ReadOnlyGateway,
        AppState.Client is { } c && c.AccountId == _store.AccountId && c.Rpc.State == ConnectionState.Open, _busy.Contains("upload"));

    /// A row of the Add Attachment menu: its system picker, then one upload to the task and board it was chosen on.
    private async Task AddAttachmentAsync(KanbanAttachmentSource source)
    {
        var outcome = await _attach.RunAsync(source, PickAsync, (target, pick) => UploadAsync(target, pick));
        switch (outcome)
        {
            case KanbanAttachmentOutcome.ReadOnly: Show(KanbanRest.ReadOnlyNotice); break;
            case KanbanAttachmentOutcome.Offline: Render(); break;
            case KanbanAttachmentOutcome.ContextChanged: AppLog.Note("kanban", "attachment pick dropped: the task or board changed"); break;
        }
    }

    /// The system picker for a choice: user-mediated, one file, starting in Pictures (photos and videos) or Documents
    /// (anything). Nothing is listed or opened until the person picks.
    private async Task<KanbanAttachmentPick?> PickAsync(KanbanAttachmentChoice choice)
    {
        if (App.Window is not { } window) return null;
        var picker = new FileOpenPicker(window.AppWindow.Id)
        {
            ViewMode = choice.Thumbnails ? PickerViewMode.Thumbnail : PickerViewMode.List,
            SuggestedStartLocation = choice.Start == KanbanPickerStart.PicturesLibrary ? PickerLocationId.PicturesLibrary : PickerLocationId.DocumentsLibrary,
        };
        foreach (var type in choice.FileTypes) picker.FileTypeFilter.Add(type);
        try { return await picker.PickSingleFileAsync() is { Path.Length: > 0 } file ? new KanbanAttachmentPick(file.Path, Path.GetFileName(file.Path)) : null; }
        catch (Exception e) { AppLog.Error("kanban", e); return null; }
    }

    /// Sends the picked file (read in place, never changed) to the bound task on the bound board; "Adding…" with a bar
    /// past 1 MB, then the task is read again. A failure is an alert.
    private async Task<bool> UploadAsync(KanbanAttachmentTarget target, KanbanAttachmentPick pick)
    {
        var epoch = target.Epoch;
        _busy.Add("upload");
        try
        {
            _uploadProgress = KanbanAttachmentFlow.StartProgress(new FileInfo(pick.Path).Length);
            Render();
            await _store.Api.AddAttachmentAsync(target.TaskId, pick.Path, KanbanAttachmentUpload.SendName(pick.Name), target.Board,
                progress: (sent, total) => _ui.TryEnqueue(() =>
                {
                    if (epoch != _epoch || _uploadProgress == null || KanbanAttachmentFlow.Fraction(sent, total) is not { } fraction) return;
                    _uploadProgress = fraction;
                    Render();
                }));
            FinishUpload(epoch);
            if (epoch != _epoch) return true;
            await ReadAsync();
            Show(KanbanCopy.AttachmentAdded);
            return true;
        }
        catch (Exception e)
        {
            FinishUpload(epoch);
            var (text, gone) = KanbanAttachmentFlow.Reason(e);
            AppLog.Note("kanban", $"attachment failed ({Path.GetExtension(pick.Name)})");
            if (epoch != _epoch) return false;
            await FailedAsync(XamlRoot, KanbanAttachmentUpload.FailureTitle, text, null);
            if (gone) { await ReadAsync(); await _store.ReadBoardAsync(); }
            return false;
        }
    }

    private void FinishUpload(int epoch)
    {
        if (epoch != _epoch) return;
        _busy.Remove("upload");
        _uploadProgress = null;
        Render();
    }

    private async Task OpenAttachmentAsync(KanbanAttachment attachment)
    {
        var key = "attachment-" + attachment.Id;
        if (!_busy.Add(key)) return;
        var at = ((IKanbanDetailHost)this).Now;
        Render();
        try
        {
            var dir = Path.Combine(AppPaths.Root, "kanban-files", attachment.Id);
            Directory.CreateDirectory(dir);
            var file = Path.Combine(dir, KanbanAttachmentUpload.SendName(attachment.Filename) is { Length: > 0 } n ? n : "attachment");
            await _store.Api.AttachmentAsync(attachment.Id, at.Board, file);
            var storage = await Windows.Storage.StorageFile.GetFileFromPathAsync(file);
            await Launcher.LaunchFileAsync(storage);
        }
        catch (Exception e) { if (_writes.Holds(at)) Show(KanbanRest.Reason(e)); }
        finally { _busy.Remove(key); Render(); }
    }

    // ------------------------------------------------------------------ drawing

    private MenuFlyout MoreMenu()
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            if (Task is not { } task) return;
            menu.Items.Add(MenuItem(KanbanCopy.CopyTitle, "", () => CopyText(task.Title.Length == 0 ? task.Id : task.Title, "title")));
            menu.Items.Add(MenuItem(KanbanCopy.CopyTaskId, "", () => CopyText(task.Id, "task ID")));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(MenuItem(KanbanCopy.Archive, "", () => _ = _board.ArchiveAsync(task)));
            var delete = MenuItem(KanbanCopy.Delete, "", () => _ = _board.ConfirmDeleteAsync(task));
            delete.Foreground = Critical;
            menu.Items.Add(delete);
        };
        return menu;
    }

    private static MenuFlyoutItem MenuItem(string text, string? glyph, Action run)
    {
        var item = new MenuFlyoutItem { Text = text };
        if (glyph != null) item.Icon = new FontIcon { Glyph = glyph };
        item.Click += (_, _) => run();
        return item;
    }

    /// Someone is typing a comment or a description: a read waits to draw until they leave the field.
    private bool Typing => (_commentBox != null && _commentBox.FocusState != FocusState.Unfocused)
        || (_bodyBox != null && _bodyBox.FocusState != FocusState.Unfocused);

    private void Render()
    {
        if (Typing && _detail != null && _page.Children.Count > 0) { _pendingRender = true; UpdateCommentButtons(); return; }
        _pendingRender = false;
        _bodyBox = null;
        _page.Children.Clear();
        if (_detail is not { } detail)
        {
            if (_error is { } error)
            {
                var stack = new StackPanel { Spacing = 4 };
                stack.Children.Add(Text(KanbanCopy.CouldNotLoadTask, 14));
                stack.Children.Add(Text(KanbanCopy.CheckConnection, 12, color: Critical));
                stack.Children.Add(Text(error, 12, color: Secondary));
                _page.Children.Add(Card(stack));
            }
            else
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 40, 0, 0) };
                row.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 });
                row.Children.Add(Text(KanbanCopy.Loading, 14, color: Secondary));
                _page.Children.Add(row);
            }
            return;
        }
        var task = detail.Task;
        var now = DateTimeOffset.Now;
        _page.Children.Add(StatusButton(task));
        var title = Text(task.Title.Length == 0 ? task.Id : task.Title, 20, bold: true);
        title.IsTextSelectionEnabled = true;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        AutomationProperties.SetAutomationId(title, "kanban.task.title");
        _page.Children.Add(title);
        if (KanbanModel.MadeLine(task, now, BotName) is { } made) _page.Children.Add(Text(made, 13, color: Secondary));
        NowBlock(task, now);
        _page.Children.Add(FactRow(KanbanCopy.AssignedTo, AssignButton(task), _busy.Contains("assign")));
        _page.Children.Add(FactRow(KanbanCopy.Priority, PriorityButton(task), _busy.Contains("priority")));

        if (detail.Parents.Count > 0) { _page.Children.Add(Header(KanbanCopy.WaitingOn)); _page.Children.Add(Links(detail.Parents, detail)); }
        if (detail.Children.Count > 0) { _page.Children.Add(Header(KanbanCopy.HoldingUp)); _page.Children.Add(Links(detail.Children, detail)); }
        if (task.Result is { Length: > 0 } result) { _page.Children.Add(Header(KanbanCopy.Result)); _page.Children.Add(Folded(result, KanbanTextPart.Result)); }
        Description(task);
        if (!Running && KanbanModel.LatestUpdate(task) is { } summary) { _page.Children.Add(Header(KanbanCopy.LatestUpdate)); _page.Children.Add(Folded(summary, KanbanTextPart.LatestUpdate)); }
        if (task.LastFailureError is { Length: > 0 } failure)
        {
            _page.Children.Add(Header(KanbanCopy.LastError));
            var text = Text(failure, 12, color: Critical);
            text.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
            text.IsTextSelectionEnabled = true;
            _page.Children.Add(text);
        }
        History(detail, now);
        if (detail.Attachments is { } attachments) Attachments(attachments);
        Details(task);
        var estimate = new HyperlinkButton
        {
            Content = _estimate ?? (_busy.Contains("estimate") ? KanbanCopy.Estimating : KanbanCopy.EstimateEffort),
            IsEnabled = !_busy.Contains("estimate") && _estimate == null, Margin = new Thickness(0, 8, 0, 0),
        };
        estimate.Click += (_, _) => RunEstimate();
        _page.Children.Add(estimate);
        if (_estimate == null) _page.Children.Add(Text(KanbanCopy.EstimateFooter, 12, color: Secondary));
    }

    private FrameworkElement StatusButton(KanbanTask task)
    {
        // Statuses only a bot sets are left out, as on the board's Move To, unless the task is in one.
        var columns = (_store.Board?.Columns.Select(c => c.Name).Where(n => n != "archived") ?? KanbanModel.StatusOrder)
            .Where(n => n == task.Status || !KanbanModel.IsLocked(n));
        var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        face.Children.Add(Dot(Tone(task.Status)));
        face.Children.Add(Text(KanbanModel.Label(task.Status), 13, bold: true, wrap: false));
        var menu = new MenuFlyout();
        foreach (var name in columns)
        {
            var to = name;
            var item = new RadioMenuFlyoutItem { Text = KanbanModel.Label(to), IsChecked = to == task.Status, GroupName = "status" };
            item.Click += (_, _) => Move(to);
            menu.Items.Add(item);
        }
        var button = new DropDownButton { Content = face, Flyout = menu, IsEnabled = !_busy.Contains("move"), CornerRadius = new CornerRadius(12) };
        AutomationProperties.SetName(button, $"Status: {KanbanModel.Label(task.Status)}. Change");
        AutomationProperties.SetAutomationId(button, "kanban.task.status");
        return button;
    }

    /// What is happening now: the bot at work, what the board needs from you, or the usual next move.
    private void NowBlock(KanbanTask task, DateTimeOffset now)
    {
        var quick = KanbanModel.QuickMove(task.Status) is { } q && !KanbanModel.IsLocked(q.To) ? q : ((string To, string Label)?)null;
        var diagnostics = task.Diagnostics ?? [];
        var unassignedReady = task.Status == "ready" && task.Assignee == null && _store.Fallback.Length == 0;
        if (task.Status == "running") _page.Children.Add(WorkingCard(task, now));
        if (diagnostics.Count == 0 && task.Status == "blocked")
            _page.Children.Add(Callout("warning", KanbanModel.BlockReason(task.BlockKind), KanbanCopy.BlockedDetail, [], quick));
        for (var i = 0; i < diagnostics.Count; i++)
        {
            var d = diagnostics[i];
            // The board's own Unblock is the primary button when that is the page's next move.
            var actions = d.Actions.Where(a => a.Kind is "reclaim" or "unblock" or "cli_hint" && !(a.Kind == "unblock" && quick?.To == "ready")).ToList();
            _page.Children.Add(Callout(d.Severity, d.Title + (d.Count > 1 ? $" ×{d.Count}" : ""), d.Detail, actions, i == 0 ? quick : null));
        }
        if (unassignedReady) _page.Children.Add(Callout("warning", KanbanCopy.WontRunYet, KanbanCopy.WontRunDetail, [], null));
        if (quick is { } move && diagnostics.Count == 0 && task.Status != "blocked")
        {
            if (task.Status == "done" && task.CompletedAt is { } done)
            {
                var row = new Grid { ColumnSpacing = 12 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new FontIcon { Glyph = "", FontSize = 22, Foreground = Solid(Green) });
                var words = new StackPanel { Spacing = 2 };
                words.Children.Add(Text(KanbanCopy.Finished, 13, bold: true));
                words.Children.Add(Text(KanbanModel.When(done), 12, color: Secondary));
                Grid.SetColumn(words, 1);
                row.Children.Add(words);
                var reopen = PrimaryButton(move, accent: false);
                Grid.SetColumn(reopen, 2);
                row.Children.Add(reopen);
                _page.Children.Add(Card(row));
            }
            else
            {
                if (KanbanModel.StatusLine(task.Status, null) is { Length: > 0 } line) _page.Children.Add(Text(line, 13, color: Secondary));
                _page.Children.Add(PrimaryButton(move, accent: true));
            }
        }
        else if (quick == null && task.Status != "running" && diagnostics.Count == 0 && !unassignedReady)
        {
            if (KanbanModel.StatusLine(task.Status, task.Assignee == null ? null : BotName(task.Assignee)) is { Length: > 0 } line)
                _page.Children.Add(Text(line, 13, color: Secondary));
        }
    }

    private Button PrimaryButton((string To, string Label) move, bool accent)
    {
        var b = Push(_busy.Contains("move") ? KanbanCopy.Moving : move.Label, () => Move(move.To), accent);
        b.IsEnabled = !_busy.Contains("move");
        b.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(b, "kanban.task.primary");
        return b;
    }

    private FrameworkElement WorkingCard(KanbanTask task, DateTimeOffset now)
    {
        var top = new Grid { ColumnSpacing = 12 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (task.Assignee != null) top.Children.Add(Face(task.Assignee, 40));
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(Text(KanbanCopy.WorkingOnIt(task.Assignee == null ? null : BotName(task.Assignee)), 13, bold: true));
        words.Children.Add(Text(KanbanCopy.SoFar(KanbanModel.RunningFor(task.CurrentRunStartedAt ?? task.StartedAt, now)), 12, color: Secondary));
        Grid.SetColumn(words, 1);
        top.Children.Add(words);
        var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
        Grid.SetColumn(ring, 2);
        top.Children.Add(ring);
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(top);
        if (KanbanModel.LatestUpdate(task) is { } summary)
        {
            stack.Children.Add(new Border { Height = 1, Background = Brush("DividerStrokeColorDefaultBrush") });
            stack.Children.Add(Text(KanbanCopy.LatestUpdate, 12, bold: true, color: Secondary));
            stack.Children.Add(Folded(summary, KanbanTextPart.WorkingUpdate));
        }
        var card = Card(stack, 14);
        AutomationProperties.SetAutomationId(card, "kanban.task.working");
        return card;
    }

    /// Something that needs you: the board's diagnostic (title ×N, detail folded at 180 characters, its fixes), or a
    /// blocked task's reason; the first carries the page's next move as its prominent button.
    private FrameworkElement Callout(string severity, string title, string detail, IReadOnlyList<KanbanDiagnosticAction> actions, (string To, string Label)? primary)
    {
        var tone = severity == "error" ? Red : Orange;
        var stack = new StackPanel { Spacing = 8 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(new FontIcon { Glyph = severity == "error" ? "" : "", FontSize = 14, Foreground = Solid(tone) });
        head.Children.Add(Text(title, 13, bold: true, color: Solid(tone)));
        stack.Children.Add(head);
        if (detail.Length > 0)
        {
            var open = false;
            var body = Text(detail.Length > 180 ? detail[..180] + "…" : detail, 13);
            stack.Children.Add(body);
            if (detail.Length > 180)
            {
                var toggle = new HyperlinkButton { Content = KanbanCopy.ShowMore, Padding = new Thickness(0) };
                toggle.Click += (_, _) => { open = !open; body.Text = open ? detail : detail[..180] + "…"; toggle.Content = open ? KanbanCopy.ShowLess : KanbanCopy.ShowMore; };
                stack.Children.Add(toggle);
            }
        }
        if (primary != null || actions.Count > 0)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            if (primary is { } move) row.Children.Add(PrimaryButton(move, accent: true));
            foreach (var action in actions)
            {
                var a = action;
                var label = a.Kind == "cli_hint" && a.Command != null ? $"{a.Label} (Copies {a.Command})" : a.Label;
                row.Children.Add(Push(label, () =>
                {
                    switch (a.Kind)
                    {
                        case "reclaim": Reclaim(); break;
                        case "unblock": Move("ready"); break;
                        default: CopyText(a.Command ?? a.Label, "command"); break;
                    }
                }));
            }
            stack.Children.Add(row);
        }
        return new Border
        {
            Child = stack, Padding = new Thickness(14), CornerRadius = new CornerRadius(8),
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(tone) { Opacity = 0.1 },
        };
    }

    private static FrameworkElement FactRow(string label, FrameworkElement value, bool busy)
    {
        var grid = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 2, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = Text(label, 13, color: Secondary);
        l.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(l);
        if (busy)
        {
            var ring = new ProgressRing { IsActive = true, Width = 12, Height = 12 };
            Grid.SetColumn(ring, 1);
            grid.Children.Add(ring);
        }
        Grid.SetColumn(value, 2);
        grid.Children.Add(value);
        return grid;
    }

    private FrameworkElement AssignButton(KanbanTask task)
    {
        var nobody = KanbanModel.NobodyWords(_store.Fallback.Length == 0 ? "" : BotName(_store.Fallback));
        var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (task.Assignee != null) face.Children.Add(Face(task.Assignee, 18));
        face.Children.Add(Text(task.Assignee == null ? nobody : BotName(task.Assignee), 13, wrap: false));
        var menu = new MenuFlyout();
        foreach (var profile in _store.Profiles)
        {
            var name = profile.Name;
            var item = new RadioMenuFlyoutItem { Text = BotName(name), IsChecked = name == task.Assignee, GroupName = "assign" };
            item.Click += (_, _) => Assign(name);
            menu.Items.Add(item);
        }
        var none = new RadioMenuFlyoutItem { Text = nobody, IsChecked = task.Assignee == null, GroupName = "assign" };
        none.Click += (_, _) => Assign("");
        menu.Items.Add(none);
        var button = new DropDownButton { Content = face, Flyout = menu };
        AutomationProperties.SetName(button, $"Assigned To: {(task.Assignee == null ? nobody : BotName(task.Assignee))}. Change");
        AutomationProperties.SetAutomationId(button, "kanban.task.assign");
        return button;
    }

    private FrameworkElement PriorityButton(KanbanTask task)
    {
        var current = task.Priority ?? 0;
        var menu = new MenuFlyout();
        foreach (var value in new[] { 0, 1, 2, 3, 5, 10, current }.Distinct().Order())
        {
            var v = value;
            var item = new RadioMenuFlyoutItem { Text = v == 0 ? KanbanCopy.None : v.ToString(), IsChecked = v == current, GroupName = "priority" };
            item.Click += (_, _) => SetPriority(v);
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem(KanbanCopy.OtherNumber, null, () => _ = AskPriorityAsync()));
        var button = new DropDownButton { Content = current == 0 ? KanbanCopy.None : current.ToString(), Flyout = menu };
        ToolTipService.SetToolTip(button, KanbanCopy.PriorityMenu);
        AutomationProperties.SetName(button, $"Priority: {(current == 0 ? KanbanCopy.None : current.ToString())}, higher goes first. Change");
        AutomationProperties.SetAutomationId(button, "kanban.task.priority");
        return button;
    }

    private FrameworkElement Links(IReadOnlyList<string> ids, KanbanTaskDetail detail)
    {
        var stack = new StackPanel { Spacing = 2 };
        foreach (var id in ids)
        {
            var linked = _store.Board?.Task(id);
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(Dot(linked == null ? Rgb(0x8E, 0x8E, 0x93) : Tone(linked.Status)));
            var name = Text(detail.LinkTitles.GetValueOrDefault(id) ?? linked?.Title ?? id, 13);
            name.MaxLines = 2;
            Grid.SetColumn(name, 1);
            row.Children.Add(name);
            if (linked != null)
            {
                var status = Text(KanbanModel.Label(linked.Status), 12, color: Secondary);
                Grid.SetColumn(status, 2);
                row.Children.Add(status);
            }
            var target = id;
            var button = new Button { Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Style = Style("QuietButtonStyle") };
            button.Click += (_, _) => Open(target);
            stack.Children.Add(button);
        }
        return Card(stack, 4);
    }

    /// Agent-written Markdown folded to about twelve lines, with Show More / Show Less (KanbanTaskSheet.swift
    /// FoldedMarkdown → PagesMarkdown: the chat's own renderer). Headings, emphasis, code, lists, quotes, tables and
    /// links draw as in a bot's reply, and a link opens the way the chat's does (MarkdownRenderer: web links, nothing for
    /// the gateway computer's own localhost). The words sit in a scroller that never scrolls, as tall as the fold, so the
    /// whole text is measured and Show More appears only when it runs past the fold.
    private static FrameworkElement Folded(string text, KanbanTextPart part)
    {
        var fold = KanbanText.FoldLines(part) * FoldLineHeight;
        var stack = new StackPanel { Spacing = 4 };
        var body = new StackPanel();
        HermesHQ.Controls.MarkdownRenderer.Render(KanbanText.Markdown(text), body);
        var window = new ScrollViewer
        {
            Content = body, MaxHeight = fold, IsTabStop = false,
            VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        AutomationProperties.SetAutomationId(window, "kanban.task.text." + part.ToString().ToLowerInvariant());
        stack.Children.Add(window);
        var toggle = new HyperlinkButton { Content = KanbanCopy.ShowMore, Padding = new Thickness(0), Visibility = Visibility.Collapsed };
        toggle.Click += (_, _) =>
        {
            var open = !double.IsPositiveInfinity(window.MaxHeight);
            window.MaxHeight = open ? double.PositiveInfinity : fold;
            toggle.Content = open ? KanbanCopy.ShowLess : KanbanCopy.ShowMore;
            if (!open) window.ChangeView(null, 0, null, true);
        };
        // The words are measured at full height (the scroller gives them all the room they ask for).
        body.SizeChanged += (_, _) =>
            toggle.Visibility = double.IsPositiveInfinity(window.MaxHeight) || body.ActualHeight > fold + 1 ? Visibility.Visible : Visibility.Collapsed;
        stack.Children.Add(toggle);
        return stack;
    }

    /// One line of the chat renderer's prose (MarkdownRenderer's paragraphs: 21 px lines).
    private const double FoldLineHeight = 21;

    private void Description(KanbanTask task)
    {
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(Header(KanbanCopy.Description));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Bottom };
        if (_editing == null)
        {
            if ((task.Body ?? "").Length > 0)
            {
                var edit = Quiet(KanbanCopy.Edit, () => { _editing = task.Body ?? ""; Render(); });
                AutomationProperties.SetAutomationId(edit, "kanban.task.edit");
                buttons.Children.Add(edit);
            }
        }
        else
        {
            var cancel = Quiet(KanbanCopy.Cancel, () => { _editing = null; Render(); });
            AutomationProperties.SetAutomationId(cancel, "kanban.task.cancel");
            buttons.Children.Add(cancel);
            var save = Push(KanbanCopy.Save, SaveBody, accent: true);
            save.IsEnabled = !_busy.Contains("body");
            buttons.Children.Add(save);
        }
        Grid.SetColumn(buttons, 1);
        head.Children.Add(buttons);
        _page.Children.Add(head);
        if (_editing != null)
        {
            var box = _bodyBox = new TextBox { AcceptsReturn = true, Text = _editing, TextWrapping = TextWrapping.Wrap, Height = 180 };
            box.LostFocus += (_, _) => { if (_pendingRender) Render(); };
            AutomationProperties.SetName(box, KanbanCopy.Description);
            AutomationProperties.SetAutomationId(box, "kanban.task.body");
            box.TextChanged += (_, _) => _editing = box.Text;
            // Ctrl+Enter saves the description, as in New Job.
            var save = new KeyboardAccelerator { Key = VirtualKey.Enter, Modifiers = VirtualKeyModifiers.Control };
            save.Invoked += (_, e) => { e.Handled = true; SaveBody(); };
            box.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
            box.KeyboardAccelerators.Add(save);
            _page.Children.Add(box);
        }
        else if (KanbanText.Description(task.Body, null) is { Mode: KanbanDescriptionMode.Markdown }) _page.Children.Add(Card(Folded(task.Body!, KanbanTextPart.Description)));
        else
        {
            var add = new HyperlinkButton { Content = KanbanCopy.AddDescription };
            add.Click += (_, _) => { _editing = ""; Render(); };
            _page.Children.Add(add);
        }
    }

    private void History(KanbanTaskDetail detail, DateTimeOffset now)
    {
        var feeds = new List<Feed> { Feed.Comments };
        if (detail.Events.Count > 0) feeds.Add(Feed.Activity);
        if (detail.Runs.Count > 0) feeds.Add(Feed.Runs);
        if (_log.Exists && _log.Content.Length > 0) feeds.Add(Feed.Log);
        var shown = feeds.Contains(_feed) ? _feed : Feed.Comments;
        if (feeds.Count > 1)
        {
            var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(0, 14, 0, 4) };
            foreach (var feed in feeds)
            {
                var f = feed;
                var label = f switch
                {
                    Feed.Comments => KanbanCopy.CommentsTab(detail.Comments.Count),
                    Feed.Activity => KanbanCopy.Activity,
                    Feed.Runs => KanbanCopy.Runs,
                    _ => KanbanCopy.Log,
                };
                var tab = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = label, IsChecked = f == shown };
                tab.Click += (_, _) => { _feed = f; Render(); if (f == Feed.Log) _ = ReadLogAsync(); };
                tabs.Children.Add(tab);
            }
            AutomationProperties.SetName(tabs, "Task history");
            _page.Children.Add(tabs);
        }
        else _page.Children.Add(Header(KanbanCopy.Comments));

        var box = new StackPanel { Spacing = 10 };
        switch (shown)
        {
            case Feed.Comments:
                foreach (var comment in detail.Comments)
                {
                    var row = new Grid { ColumnSpacing = 10 };
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.Children.Add(comment.Author == "desktop"
                        ? new FontIcon { Glyph = "", FontSize = 22, Foreground = Tertiary, VerticalAlignment = VerticalAlignment.Top }
                        : Face(comment.Author, 24));
                    var words = new StackPanel { Spacing = 3 };
                    var who = new TextBlock { FontSize = 13 };
                    who.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = comment.Author == "desktop" ? KanbanCopy.You : BotName(comment.Author), FontWeight = FontWeights.SemiBold });
                    who.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "  " + KanbanModel.Ago(comment.CreatedAt, now), Foreground = Tertiary, FontSize = 12 });
                    words.Children.Add(who);
                    words.Children.Add(Folded(comment.Body, KanbanTextPart.Comment));
                    Grid.SetColumn(words, 1);
                    row.Children.Add(words);
                    box.Children.Add(row);
                }
                box.Children.Add(CommentBox());
                break;
            case Feed.Activity:
                foreach (var e in Enumerable.Reverse(detail.Events))
                {
                    var line = KanbanModel.ActivityLine(e.Kind, e.Payload, KanbanModel.EventText(e.Kind, e.Payload), BotName);
                    box.Children.Add(FeedRow(EventGlyph(e.Kind), null, line.Label, line.Detail, KanbanModel.Ago(e.CreatedAt, now), false));
                }
                break;
            case Feed.Runs:
                foreach (var r in Enumerable.Reverse(detail.Runs))
                {
                    var failed = KanbanModel.RunFailed(r);
                    var glyph = failed ? "" : KanbanModel.RunLive(r) ? "" : "";
                    var tone = failed ? Red : KanbanModel.RunLive(r) ? (Windows.UI.Color?)null : Green;
                    box.Children.Add(FeedRow(glyph, tone, KanbanModel.RunWords(r, BotName), r.Error ?? r.Summary, KanbanModel.Ago(r.EndedAt ?? r.StartedAt, now), failed));
                }
                break;
            case Feed.Log:
                var log = Text(_log.Content, 11);
                log.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
                log.IsTextSelectionEnabled = true;
                box.Children.Add(log);
                break;
        }
        _page.Children.Add(Card(box));
        if (shown == Feed.Comments) _page.Children.Add(Text(Running ? KanbanCopy.CommentsFooterRunning : KanbanCopy.CommentsFooter, 12, color: Secondary));
    }

    private static string EventGlyph(string kind) => kind switch
    {
        "created" => "",
        "commented" or "comment" => "",
        "assigned" or "reassigned" => "",
        "completed" or "done" => "",
        "blocked" => "",
        "claimed" or "started" or "running" => "",
        "failed" or "crashed" => "",
        _ => "",
    };

    private static FrameworkElement FeedRow(string glyph, Windows.UI.Color? tone, string label, string? detail, string when, bool failed)
    {
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new FontIcon { Glyph = glyph, FontSize = 13, Foreground = tone is { } t ? Solid(t) : Secondary, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(Text(label, 13, color: failed ? Critical : null));
        if (detail is { Length: > 0 }) words.Children.Add(Text(detail, 12, color: failed ? Critical : Secondary));
        Grid.SetColumn(words, 1);
        row.Children.Add(words);
        var w = Text(when, 12, color: Tertiary, wrap: false);
        Grid.SetColumn(w, 2);
        row.Children.Add(w);
        return row;
    }

    private FrameworkElement CommentBox()
    {
        try { return CommentBoxOnce(); }
        catch (System.Runtime.InteropServices.COMException x)
        {
            // [WIN-08] CI run 45014201465: Edit's drawing threw here ("No installed components were detected", an
            // element still a child elsewhere) when the field was moved from the last drawing. Say where it still sat,
            // then make the field afresh (what was typed is kept in _comment) rather than lose the whole panel.
            AppLog.Note("kanban", $"comment field kept its old place ({Holder(_commentBox)}, {Holder(_send)}, {Holder(_requeue)}): {x.HResult:X8}; made anew");
            _commentBox = null; _send = null; _requeue = null;
            return CommentBoxOnce();
        }
    }

    private static string Holder(FrameworkElement? e) =>
        e == null ? "none" : $"{e.Parent?.GetType().Name ?? "no parent"}/{(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(e))?.GetType().Name ?? "no visual parent"}";

    private FrameworkElement CommentBoxOnce()
    {
        // The field, its send button and Post and Start Over are made once and moved into each drawing, so what is
        // typed and the focus stay through a read.
        if (_commentBox == null)
        {
            // AcceptsReturn on (and first), so a pasted paragraph keeps every line: off, WinUI kept only the first.
            _commentBox = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 140 };
            AutomationProperties.SetAutomationId(_commentBox, "kanban.task.comment");
            _send = new Button { Content = new FontIcon { Glyph = "\uE724", FontSize = 14 }, VerticalAlignment = VerticalAlignment.Bottom, Style = Style("AccentButtonStyle") };
            AutomationProperties.SetAutomationId(_send, "kanban.task.send");
            _requeue = new HyperlinkButton { Content = KanbanCopy.PostAndStartOver };
            AutomationProperties.SetAutomationId(_requeue, "kanban.task.requeue");
            _commentBox.TextChanged += (_, _) => { _comment = KanbanCommentDraft.Normalize(_commentBox.Text); UpdateCommentButtons(); };
            // Return posts the comment once, as a message field does, and never makes a line; Shift+Return does. A
            // multi-line TextBox takes Return before KeyDown, so it is read here first.
            _commentBox.PreviewKeyDown += (_, e) =>
            {
                if (e.Key != VirtualKey.Enter) return;
                var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                    .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                var action = KanbanCommentDraft.OnReturn(_comment, Sending(), shift, e.KeyStatus.WasKeyDown);
                if (action == KanbanCommentDraft.ReturnAction.NewLine) return;
                e.Handled = true;
                if (action == KanbanCommentDraft.ReturnAction.Post) SendComment(false);
            };
            _commentBox.LostFocus += (_, _) => { if (_pendingRender) Render(); };
            _send.Click += (_, _) => SendComment(false);
            _requeue.Click += (_, _) => SendComment(true);
        }
        foreach (var e in new FrameworkElement[] { _commentBox, _send!, _requeue! })
        {
            if (e.Parent is Panel panel) panel.Children.Remove(e);
            else if (Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(e) is Panel shown) shown.Children.Remove(e);
        }
        if (KanbanCommentDraft.FieldDiffers(_commentBox.Text, _comment)) _commentBox.Text = _comment;
        _commentBox.PlaceholderText = Running ? KanbanCopy.MessageWorker : KanbanCopy.AddComment;
        AutomationProperties.SetName(_send!, Running ? "Send" : "Comment");
        UpdateCommentButtons();
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(_commentBox);
        Grid.SetColumn(_send!, 1);
        row.Children.Add(_send!);
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(row);
        stack.Children.Add(_requeue!);
        return stack;
    }

    private bool Sending() => _busy.Contains("comment") || _busy.Contains("requeue");

    private void UpdateCommentButtons()
    {
        if (_send == null || _requeue == null) return;
        var typed = KanbanCommentDraft.Body(_comment).Length > 0;
        _send.IsEnabled = KanbanCommentDraft.CanSend(_comment, Sending());
        // Only once there is a comment to post: greyed out under an empty field it read as more placeholder text.
        _requeue.Visibility = Running && typed ? Visibility.Visible : Visibility.Collapsed;
        _requeue.IsEnabled = !Sending();
    }

    private void Attachments(IReadOnlyList<KanbanAttachment> attachments)
    {
        _page.Children.Add(Header(KanbanCopy.Attachments));
        var stack = new StackPanel { Spacing = 2 };
        foreach (var attachment in attachments)
        {
            var a = attachment;
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new FontIcon { Glyph = FileGlyph(a.Filename), FontSize = 16, Foreground = Accent });
            var name = Text(a.Filename, 13, wrap: false);
            Grid.SetColumn(name, 1);
            row.Children.Add(name);
            FrameworkElement end = _busy.Contains("attachment-" + a.Id)
                ? new ProgressRing { IsActive = true, Width = 14, Height = 14 }
                : new FontIcon { Glyph = "", FontSize = 11, Foreground = Tertiary };
            Grid.SetColumn(end, 2);
            row.Children.Add(end);
            var button = new Button { Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Style = Style("QuietButtonStyle") };
            button.Click += (_, _) => _ = OpenAttachmentAsync(a);
            stack.Children.Add(button);
        }
        // The row shows while the gateway takes writes and is reachable.
        if (KanbanAttachmentFlow.CanOffer(AttachmentState()))
        {
            if (_busy.Contains("upload"))
            {
                var adding = new StackPanel { Spacing = 6, Padding = new Thickness(8, 6, 8, 6) };
                var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                line.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                line.Children.Add(Text(KanbanCopy.Adding, 13, color: Secondary));
                adding.Children.Add(line);
                if (_uploadProgress is { } p)
                {
                    var bar = new ProgressBar { Value = p * 100, Maximum = 100 };
                    AutomationProperties.SetName(bar, "Upload progress");
                    adding.Children.Add(bar);
                }
                AutomationProperties.SetAutomationId(adding, "kanban.task.adding");
                stack.Children.Add(adding);
            }
            else
            {
                var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                face.Children.Add(new FontIcon { Glyph = "\uECC8", FontSize = 18, Foreground = Solid(Green) });
                face.Children.Add(Text(KanbanCopy.AddAttachment, 13, color: Accent, wrap: false));
                // The whole row opens the menu: Photo Library, then Choose File (KanbanAddAttachmentRow).
                var add = new Button { Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Style = Style("QuietButtonStyle"), Flyout = AttachmentMenu() };
                AutomationProperties.SetName(add, KanbanCopy.AddAttachment);
                AutomationProperties.SetAutomationId(add, "kanban.task.add-attachment");
                stack.Children.Add(add);
            }
        }
        _page.Children.Add(Card(stack, 4));
        if (attachments.Count == 0) _page.Children.Add(Text(KanbanCopy.AttachmentsFooter, 12, color: Secondary));
    }

    private MenuFlyout AttachmentMenu()
    {
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft };
        foreach (var choice in KanbanAttachmentFlow.Choices)
        {
            var source = choice.Source;
            var item = MenuItem(choice.Label, choice.Glyph, () => _ui.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => _ = AddAttachmentAsync(source)));
            AutomationProperties.SetName(item, choice.Label);
            AutomationProperties.SetAutomationId(item, choice.AutomationId);
            menu.Items.Add(item);
        }
        return menu;
    }

    private static string FileGlyph(string name) => Path.GetExtension(name).TrimStart('.').ToLowerInvariant() switch
    {
        "png" or "jpg" or "jpeg" or "gif" or "heic" or "webp" => "",
        "pdf" => "",
        "csv" or "xlsx" or "numbers" => "",
        "zip" or "gz" or "tar" => "",
        "mov" or "mp4" or "m4v" => "",
        "mp3" or "m4a" or "wav" => "",
        _ => "",
    };

    private void Details(KanbanTask task)
    {
        _page.Children.Add(Header(KanbanCopy.Details));
        var stack = new StackPanel { Spacing = 6 };
        void Fact(string label, string value, bool mono = false)
        {
            var grid = new Grid { ColumnSpacing = 12 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.Children.Add(Text(label, 13, color: Secondary, wrap: false));
            var v = Text(value, 13);
            v.TextAlignment = TextAlignment.Right;
            v.IsTextSelectionEnabled = mono;
            if (mono) v.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
            Grid.SetColumn(v, 1);
            grid.Children.Add(v);
            stack.Children.Add(grid);
        }
        if (task.CreatedAt is { } created) Fact(KanbanCopy.Created, KanbanModel.When(created));
        if (task.CreatedBy is { Length: > 0 } by) Fact(KanbanCopy.CreatedBy, BotName(by));
        if (task.Status == "done" && task.CompletedAt is { } done) Fact(KanbanCopy.Finished, KanbanModel.When(done));
        if (task.ConsecutiveFailures is > 0 and var failures) Fact(KanbanCopy.FailedRuns, failures.ToString());
        Fact(KanbanCopy.Model, task.ModelOverride is { } m ? m + (task.ReasoningEffort is { } r ? $" · {r}" : "") : KanbanCopy.BotsOwnModel);
        if (task.WorkspacePath is { Length: > 0 } path)
        {
            var words = new StackPanel { Spacing = 2 };
            words.Children.Add(Text(KanbanCopy.Workspace, 13));
            var p = Text(path, 12, color: Secondary);
            p.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
            words.Children.Add(p);
            var copy = new Button { Content = words, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Style = Style("QuietButtonStyle") };
            ToolTipService.SetToolTip(copy, "Copies the path");
            copy.Click += (_, _) => CopyText(path, "path");
            stack.Children.Add(copy);
        }
        Fact(KanbanCopy.TaskId, task.Id, mono: true);
        _page.Children.Add(Card(stack));
    }
}
