using Hermes.Core;
using Hermes.Core.Model;
using Hermes.Core.Questions;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using static HermesHQ.Features.Questions.QuestionUi;

namespace HermesHQ.Features.Questions;

/// One open chat's server requests (Mac: App/Questions/ChatPromptsController.swift): the approval card and the
/// question note at the transcript's newest end, the question dock in the message box's place (or its "Answer
/// question" bar while minimized), the password sheets and their chip, the failure notices, "Approval needed" over the
/// transcript when the card is out of view, and the header's "Waiting for your approval / reply".
internal sealed class QuestionsChat
{
    public const string TimedOutText = "Approval timed out — the command was not run. Ask Hermes to try again.";

    private readonly ChatContext _ctx;
    private readonly QuestionCenter _center;
    private readonly ChatQuestions _link;
    private readonly DispatcherQueue _ui;
    private ChatPrompts _prompts = ChatPrompts.None;
    private bool _closed;
    private int _refreshQueued;

    // The transcript's newest end: timed-out notices, the question note, the approval card (top to bottom).
    private readonly StackPanel _footer = new() { Spacing = 0 };
    private readonly StackPanel _notices = new();
    private readonly ContentControl _noteHost = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly ContentControl _cardHost = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private string? _noteKey;

    // The approval card and its expiry (§4.2).
    private ApprovalCard? _card;
    private (TimeSpan Value, DateTimeOffset ReadAt)? _timeout;
    private bool _timeoutReading;
    private readonly HashSet<string> _expired = [];
    private readonly DispatcherQueueTimer _ticker;
    private readonly Button _jump;
    private ScrollViewer? _scroller;

    // The dock (§4.3).
    private QuestionDock? _dock;
    /// [questions] The settled card whose unanswered questions the dock is answering now (a live question takes the
    /// dock back from it), and the chat's later answers as last drawn.
    private SettledClarifyCard? _late;
    private IReadOnlyDictionary<string, ClarifyLate.Found> _lateShown = new Dictionary<string, ClarifyLate.Found>();
    private string _lateSignature = "";
    private int _lateQueued;

    /// The chats open now, for the settled cards their transcripts draw.
    private static readonly List<QuestionsChat> OpenChats = [];
    private readonly Button _resume;
    private UIElement? _dockContent;

    // Sheets and the chip (§4.5), and the failure notice (§4.7).
    private readonly Dictionary<string, PromptSheet> _sheets = [];
    private readonly Button _chip;
    private readonly TextBlock _chipText = new() { FontSize = 13.5, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private string? _chipFor;
    private readonly InfoBar _notice;
    private DispatcherQueueTimer? _noticeTimer;

    public QuestionsChat(ChatContext ctx, HermesClient client)
    {
        _ctx = ctx;
        _ui = ctx.Page.DispatcherQueue;
        _center = client.Questions;
        _link = _center.Link(ctx.Session.Profile);
        _link.InterruptedProbe = () => ctx.Session.TurnInterrupted;

        _footer.Children.Add(_notices);
        _footer.Children.Add(_noteHost);
        _footer.Children.Add(_cardHost);
        ctx.TranscriptFooter.Children.Add(_footer);

        _jump = new Button
        {
            Content = "Approval needed", Style = Res<Style>("AccentButtonStyle"), CornerRadius = new CornerRadius(18),
            Padding = new Thickness(16, 8, 16, 8), Visibility = Visibility.Collapsed,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(_jump, "Scrolls to the request.");
        _jump.Click += (_, _) => JumpToApproval();
        ctx.TranscriptOverlay.Children.Add(_jump);

        _resume = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center,
            CornerRadius = new CornerRadius(22), MinHeight = 44, Padding = new Thickness(16, 10, 16, 10),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(_resume, "Reopens the question with your answers kept.");
        _resume.Click += (_, _) =>
        {
            if (_dock is not { Draft.Minimized: true } dock) return;
            dock.SetMinimized(false);
            ShowDock(dock);
        };

        var chipContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        chipContent.Children.Add(new FontIcon { Glyph = "", FontSize = 12 }); // Lock
        chipContent.Children.Add(_chipText);
        _chip = new Button
        {
            Content = chipContent, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 256, CornerRadius = new CornerRadius(16),
            Padding = new Thickness(14, 6, 14, 6), Visibility = Visibility.Collapsed,
        };
        _chip.Click += (_, _) =>
        {
            if (_chipFor != null && _sheets.TryGetValue(_chipFor, out var sheet)) { sheet.Tucked = false; Present(sheet); }
        };
        _notice = new InfoBar { IsClosable = true, IsOpen = false, Severity = InfoBarSeverity.Error };
        ctx.Shelf.Children.Add(_notice);
        ctx.Shelf.Children.Add(_chip);

        _ticker = _ui.CreateTimer();
        _ticker.Interval = TimeSpan.FromSeconds(1);
        _ticker.IsRepeating = true;
        _ticker.Tick += (_, _) => Tick();

        ctx.Session.RuntimeBound += OnBound;
        ctx.Session.Changed += QueueLateCheck;
        OpenChats.Add(this);
        _lateShown = ClarifyLate.Answers(ctx.Session.Messages);
        _lateSignature = ClarifyLate.Signature(_lateShown);
        _link.Changed += QueueRefresh;
        _center.ApprovalTimedOut += OnTimedOut;
        ctx.Transcript.Loaded += (_, _) => HookScroller();
        HookScroller();
        ctx.Closed += Close;
        if (ctx.Session.RuntimeId is { } runtime) OnBound(runtime);
        QueueRefresh();
    }

    private void OnBound(string runtime)
    {
        _link.Bind(runtime, _ctx.Session.StoredId);
        _link.CameOnScreen();
        QueueRefresh();
    }

    private void QueueRefresh()
    {
        if (Interlocked.Exchange(ref _refreshQueued, 1) == 1) return;
        _ui.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref _refreshQueued, 0);
            Refresh();
        });
    }

    private void Refresh()
    {
        if (_closed) return;
        _prompts = _link.Prompts;
        _ctx.SetStatus(_prompts.NeedsInput?.StatusText());
        _ctx.SetWaitsOnUser(_prompts.NeedsInput != null);   // [WIN-THINKING-STEP] no thinking row over the question
        _expired.IntersectWith(_prompts.Approvals.Select(a => a.Id));
        if (_prompts.Approvals.Count > 0)
        {
            if (!_ticker.IsRunning) _ticker.Start();
            if (_timeout == null) ReadTimeout(false);
        }
        else _ticker.Stop();
        var atEnd = AtEnd();
        UpdateNote();
        UpdateCard();
        UpdateDock();
        UpdateSheets();
        if (atEnd) _ui.TryEnqueue(DispatcherQueuePriority.Low, ScrollToEnd);
        _ui.TryEnqueue(DispatcherQueuePriority.Low, UpdateJump);
    }

    // ------------------------------------------------------------------ the approval card

    private void UpdateCard()
    {
        if (_prompts.Approvals.FirstOrDefault() is not { } first)
        {
            _card = null;
            _cardHost.Content = null;
            return;
        }
        if (_card != null && _card.State.Approval.Id == first.Id && first.Leaving) { _card.Leave(); return; }
        var count = _prompts.Approvals.Count;
        var total = Math.Max(_prompts.ApprovalStackTotal, count);
        var state = new ApprovalCardState(first, Math.Max(1, total - count + 1), total, _expired.Contains(first.Id),
            _prompts.Approvals.All(a => _expired.Contains(a.Id)), _ctx.Session.Title);
        if (_card?.State == state) return;
        _card = new ApprovalCard(state, ExpiryLabel(first.FirstSeen), b => CardTapped(first.Id, b), () => ShowAll(first.Id));
        _cardHost.Content = _card.View;
    }

    private string ExpiryLabel(DateTimeOffset firstSeen) => _timeout is { } t
        ? ApprovalExpiry.Countdown(firstSeen, t.Value, t.ReadAt, DateTimeOffset.UtcNow).Label : "";

    private void ReadTimeout(bool fresh)
    {
        if (_timeoutReading) return;
        _timeoutReading = true;
        var asked = DateTimeOffset.UtcNow;
        _ = Task.Run(async () =>
        {
            var value = await _link.ApprovalTimeoutAsync(fresh);
            _ui.TryEnqueue(() =>
            {
                _timeoutReading = false;
                _timeout = (value, asked);
                Tick();
            });
        });
    }

    /// Once a second: the countdown in place; a card whose count ran out on a timeout read before it was due reads it
    /// again, and only then is it Expired (its card is redrawn then).
    private void Tick()
    {
        if (_closed || _timeout is not { } t) return;
        var changed = false;
        foreach (var a in _prompts.Approvals)
        {
            var (label, stale) = ApprovalExpiry.Countdown(a.FirstSeen, t.Value, t.ReadAt, DateTimeOffset.UtcNow);
            if (stale) ReadTimeout(true);
            if (label == ApprovalExpiry.Expired && _expired.Add(a.Id)) changed = true;
        }
        if (changed) UpdateCard();
        else if (_card != null) _card.SetExpiry(ExpiryLabel(_card.State.Approval.FirstSeen));
    }

    private bool IsOpen(string id) => _prompts.Approvals.Any(a => a.Id == id && a.Answering == null && !a.Leaving);

    private void CardTapped(string id, ApprovalButton button)
    {
        switch (button)
        {
            case ApprovalButton.Run: Answer(id, ApprovalChoice.Once); break;
            case ApprovalButton.Reject: Answer(id, ApprovalChoice.Deny); break;
            case ApprovalButton.Session: Answer(id, ApprovalChoice.Session); break;
            case ApprovalButton.Always: _ = ConfirmAlways(id); break;
            case ApprovalButton.Dismiss: _link.DismissExpiredApproval(id); break;
        }
    }

    private async Task ConfirmAlways(string id)
    {
        if (_prompts.Approvals.FirstOrDefault(a => a.Id == id) is not { } approval) return;
        var command = approval.Command.Trim();
        var message = $"{_ctx.Session.Title} won’t ask again before running commands that match “{approval.Description}” — in this chat or any other, from now on.";
        if (command.Length > 0) message += $"\n\n{command}";
        if (await Dialogs.ConfirmAsync(_ctx.Page.XamlRoot, "Always Allow This Command?", message, "Always Allow"))
            Answer(id, ApprovalChoice.Always); // answered elsewhere meanwhile: IsOpen stops it
    }

    private void Answer(string id, ApprovalChoice choice)
    {
        if (!IsOpen(id)) return;
        _ = Run(() => _link.AnswerApprovalAsync(id, choice), QuestionCenter.ApprovalFailed);
    }

    private async void ShowAll(string id)
    {
        if (_prompts.Approvals.FirstOrDefault(a => a.Id == id) is not { } approval) return;
        var text = approval.ShowsDescription ? approval.Description : approval.Command;
        var box = new TextBox
        {
            AcceptsReturn = true, Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 420,
            Header = approval.ShowsDescription ? "Command details" : null,
        };
        if (!approval.ShowsDescription) box.FontFamily = Mono;
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        await Dialogs.ShowAsync(new ContentDialog { Title = "Command", Content = box, CloseButtonText = "Close" }, _ctx.Page.XamlRoot);
    }

    private void OnTimedOut(string session)
    {
        if (!_link.Covers(session)) return;
        _ui.TryEnqueue(() =>
        {
            if (_closed) return;
            _notices.Children.Add(new TextBlock
            {
                Text = TimedOutText, FontSize = 12, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(40, 6, 40, 6),
                Foreground = Brush("TextFillColorSecondaryBrush"),
            });
        });
    }

    // ------------------------------------------------------------------ the question note

    private void UpdateNote()
    {
        var p = _prompts;
        var key = $"{p.Clarify?.Id}|{p.Clarify?.Questions.Count}|{p.ClarifyUndelivered}|{p.SentClarify?.RequestId}";
        if (key == _noteKey) return;
        _noteKey = key;
        _noteHost.Content = ClarifyNote.Build(p);
    }

    // ------------------------------------------------------------------ the dock

    private void UpdateDock()
    {
        if (_prompts.Clarify != null) _late = null;
        if (_late != null && _dock is { Later: true }) return;
        if (_prompts.Clarify is { } clarify)
        {
            if (_dock is { } dock && dock.Prompt.Id == clarify.Id)
            {
                var sending = clarify.Sending ? (dock.Sending == DockSending.None ? DockSending.Send : dock.Sending) : DockSending.None;
                if (sending != dock.Sending) dock.Sending = sending;
                if (dock.MergeReplayed(clarify.LockedAnswers)) _link.SaveClarifyDraft(clarify.Id, dock.Draft);
                return;
            }
            var draft = ClarifyStaging.InitialDraft(clarify, _link.ClarifyDraft(clarify.Id));
            var fresh = new QuestionDock(clarify, draft, _ui)
            {
                OnSend = DockSend, OnSkip = d => _ = DockSkip(d), OnMinimize = DockMinimize,
                OnDraftChanged = d => _link.SaveClarifyDraft(d.Prompt.Id, d.Draft),
            };
            _link.SaveClarifyDraft(clarify.Id, draft);
            _dock = fresh;
            ShowDock(fresh);
        }
        else if (_dock is { } gone)
        {
            _dock = null;
            // The bot stopped waiting (its clarify timeout, a Stop, a reconnect's prune) while answers were being typed:
            // they stay in the dock, now as Answer Now's, and Send puts them in the chat.
            if (KeepAnswering(gone)) return;
            SetDock(null);
        }
    }

    /// A live dock that went unsent with something typed or picked comes back as a later dock holding the same draft.
    /// Its card is the settled one for the same questions (looked up again at Send, when it has arrived).
    private bool KeepAnswering(QuestionDock gone)
    {
        if (gone.Later || gone.Sending != DockSending.None || !SettledClarify.HasAnswers(gone.Draft)) return false;
        var (card, prompt) = SettledClarify.Kept(gone.Prompt);
        _late = card;
        var view = new QuestionDock(prompt, gone.Draft, _ui, later: true)
        {
            OnSend = SendLater, OnSkip = _ => CloseLater(), OnMinimize = DockMinimize,
        };
        _dock = view;
        AppLog.Note("questions", "clarify ended unsent with answers typed: kept as Answer Now");
        ShowDock(view);
        return true;
    }

    // ------------------------------------------------------------------ the settled card and Answer Now

    /// The settled Q&A card for a clarify call in a transcript (ChatExtensions.ToolRenderers["clarify"]); null leaves
    /// the call a step line (still running, or a result without `responses`).
    internal static UIElement? SettledCard(ToolCall call, ChatMessage message)
    {
        if (call.Name != "clarify" || call.State == ToolState.Running) return null;
        var owner = OpenChats.LastOrDefault(c => !c._closed && c._ctx.Session.Messages.Any(m => m.Id == message.Id));
        IReadOnlyList<ChatMessage> messages = owner?._ctx.Session.Messages ?? [message];
        if (SettledClarify.Card(call, message, messages, room: owner == null) is not { } card) return null;
        return ClarifyNote.Settled(card, owner == null ? null : owner.AnswerLater);
    }

    /// Answer Now on a settled card: its unanswered questions come back in the dock, with the choices they offered.
    /// The bot's clarify call is long over, so Send puts the answers in the chat as a message of yours naming the card;
    /// the card then shows them. A live question owns the dock and wins.
    internal void AnswerLater(SettledClarifyCard card)
    {
        if (_closed || _prompts.Clarify != null) return;
        if (_dock is { Later: true } shown && _late?.Key == card.Key)
        {
            if (shown.Draft.Minimized) { shown.SetMinimized(false); ShowDock(shown); }
            return;
        }
        if (SettledClarify.LaterPrompt(card) is not { } prompt) return;
        _late = card;
        var view = new QuestionDock(prompt, ClarifyDraft.Empty, _ui, later: true)
        {
            OnSend = SendLater, OnSkip = _ => CloseLater(), OnMinimize = DockMinimize,
        };
        _dock = view;
        ShowDock(view);
    }

    private void SendLater(QuestionDock dock)
    {
        if (_dock != dock || _late is not { } card) { CloseLater(); return; }
        var plan = SettledClarify.LateSend(card, dock.Prompt, dock.Draft, _ctx.Session.Messages);
        if (!plan.Close) return;
        CloseLater();
        if (plan.Text is not { } text) return;
        // The words go out as they are (the mark must lead); behind a running reply the composer's queue takes them.
        if (_ctx.Session.Busy && _ctx.SendHandler is { } queue && queue(text)) { }
        else _ = _ctx.Session.SendAsync(text);
        Redraw([plan.MessageId]);
    }

    private void CloseLater()
    {
        _late = null;
        if (_dock is not { Later: true }) return;
        _dock = null;
        SetDock(null);
        UpdateDock();
    }

    /// The chat changed: a card whose later answer arrived (from here, another device) is drawn again.
    private void QueueLateCheck()
    {
        if (Interlocked.Exchange(ref _lateQueued, 1) == 1) return;
        _ui.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            Interlocked.Exchange(ref _lateQueued, 0);
            if (_closed) return;
            var messages = _ctx.Session.Messages;
            var now = ClarifyLate.Answers(messages);
            var signature = ClarifyLate.Signature(now);
            if (signature == _lateSignature) return;
            var changed = ClarifyLate.Changed(_lateShown, now);
            _lateShown = now;
            _lateSignature = signature;
            Redraw(messages.Where(m => m.Role == Hermes.Core.Model.Role.Assistant && m.Tools.Any(call => call.Name == "clarify"
                && ClarifySettled.Parse(call.ResultText) is { Count: > 0 } rows && changed.Contains(ClarifyLate.Key(rows.Select(r => r.Question)))))
                .Select(m => m.Id));
        });
    }

    private void Redraw(IEnumerable<string> messageIds)
    {
        var ids = messageIds.Where(id => id.Length > 0).ToHashSet();
        if (ids.Count == 0) return;
        foreach (var item in _ctx.Transcript.Items.OfType<HermesHQ.ViewModels.MessageItem>())
            if (ids.Contains(item.Id)) item.Redraw();
    }

    /// The dock, or its "Answer question" bar while minimized (same draft, page and picks).
    private void ShowDock(QuestionDock dock)
    {
        if (dock.Draft.Minimized)
        {
            var count = dock.Prompt.Questions.Count;
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            content.Children.Add(new TextBlock { Text = count > 1 ? "Answer questions" : "Answer question", FontSize = 14 });
            content.Children.Add(new FontIcon { Glyph = "", FontSize = 12 }); // ChevronUp
            _resume.Content = content;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(_resume,
                count > 1 ? $"Question {dock.Draft.Page + 1} of {count}" : "");
            SetDock(_resume);
        }
        else
        {
            SetDock(dock.View);
            dock.TakeKeys();
        }
    }

    private void SetDock(UIElement? content)
    {
        // Only ever takes back what this feature put there.
        if (content == null && _ctx.Dock.Content != null && !ReferenceEquals(_ctx.Dock.Content, _dockContent)) return;
        _dockContent = content;
        _ctx.Dock.Content = content;
        if (content == null) _ctx.Composer.Focus(FocusState.Programmatic);
    }

    private void DockMinimize(QuestionDock dock)
    {
        if (_dock != dock || dock.Sending != DockSending.None || dock.Draft.Minimized) return;
        dock.SetMinimized(true);
        ShowDock(dock);
    }

    private void DockSend(QuestionDock dock)
    {
        if (dock.Sending != DockSending.None) return;
        dock.Sending = DockSending.Send;
        var id = dock.Prompt.Id;
        _link.SaveClarifyDraft(id, dock.Draft);
        var answers = dock.Answers;
        _ = Run(() => _link.SendClarifyAsync(id, answers), QuestionCenter.ClarifyFailed, () => dock.Sending = DockSending.None);
    }

    /// Skip cancels every question, so answers already given would be lost: with several questions it asks first.
    private async Task DockSkip(QuestionDock dock)
    {
        if (dock.Sending != DockSending.None) return;
        if (dock.Prompt.Questions.Count > 1 && dock.AnsweredCount > 0)
        {
            var sure = await Dialogs.ConfirmAsync(_ctx.Page.XamlRoot, "Skip All Questions?",
                "The answers you’ve given so far won’t be sent.", "Skip All");
            // Answered or withdrawn elsewhere while the confirm was up: nothing to skip.
            if (!sure || _dock != dock || _prompts.Clarify?.Id != dock.Prompt.Id) return;
        }
        dock.Sending = DockSending.Skip;
        var id = dock.Prompt.Id;
        _ = Run(() => _link.SkipClarifyAsync(id), QuestionCenter.ClarifyFailed, () => dock.Sending = DockSending.None);
    }

    // ------------------------------------------------------------------ sheets and the chip (§4.5, Q14)

    private void UpdateSheets()
    {
        var values = _prompts.Values;
        var ids = values.Select(v => v.Id).ToHashSet();
        foreach (var gone in _sheets.Keys.Where(k => !ids.Contains(k)).ToList())
        {
            _sheets[gone].Drop(); // closes without a chip and clears the text
            _sheets.Remove(gone);
        }
        foreach (var v in values)
        {
            if (_sheets.ContainsKey(v.Id)) continue;
            var sheet = new PromptSheet(v, _ctx.Session.Title) { OnAnswer = SheetAnswered };
            _sheets[v.Id] = sheet;
        }
        // The oldest untucked prompt comes up when nothing else is over the chat; tucked ones wait behind the chip.
        if (!_sheets.Values.Any(s => s.Showing) && !Dialogs.Busy
            && values.FirstOrDefault(v => !v.Sending && !_sheets[v.Id].Tucked) is { } next)
            Present(_sheets[next.Id]);
        var tucked = values.FirstOrDefault(v => _sheets[v.Id].Tucked && !_sheets[v.Id].Showing);
        _chipFor = tucked?.Id;
        if (tucked != null)
        {
            var label = _sheets[tucked.Id].Copy.Chip;
            _chipText.Text = label;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_chip, $"{label}. Opens the request.");
        }
        _chip.Visibility = tucked != null ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Present(PromptSheet sheet)
    {
        if (_ctx.Page.XamlRoot == null) return;
        await sheet.ShowAsync(_ctx.Page.XamlRoot);
        if (!_closed) Refresh(); // the next untucked one comes up; the chip follows
    }

    private void SheetAnswered(PromptSheet sheet, string value)
    {
        var id = sheet.Prompt.Id;
        _ = Run(() => _link.AnswerValueAsync(id, value), QuestionCenter.ValueFailed(sheet.Prompt.Kind), () =>
        {
            // Not sent: the sheet comes back with its text.
            sheet.Reopen();
            sheet.Tucked = false;
            Refresh();
        });
    }

    // ------------------------------------------------------------------ failures (§4.7)

    /// Runs an answer; a failure shows the notice (with Reconnect when Hermes is offline) and runs `failed`.
    private async Task Run(Func<Task> answer, string fallback, Action? failed = null)
    {
        try { await answer(); }
        catch (PromptAnswerException e)
        {
            _ui.TryEnqueue(() =>
            {
                failed?.Invoke();
                ShowNotice(e.Message, e.Offline);
            });
        }
        catch (Exception e)
        {
            AppLog.Error("questions", e);
            _ui.TryEnqueue(() =>
            {
                failed?.Invoke();
                ShowNotice(fallback, false);
            });
        }
    }

    private void ShowNotice(string message, bool offline)
    {
        if (_closed) return;
        _notice.Message = message;
        _notice.Severity = offline ? InfoBarSeverity.Warning : InfoBarSeverity.Error;
        if (offline)
        {
            var reconnect = new Button { Content = "Reconnect" };
            reconnect.Click += (_, _) => { _link.ReconnectNow(); _notice.IsOpen = false; };
            _notice.ActionButton = reconnect;
        }
        else _notice.ActionButton = null;
        _notice.IsOpen = true;
        _noticeTimer?.Stop();
        _noticeTimer = _ui.CreateTimer();
        _noticeTimer.Interval = TimeSpan.FromSeconds(8);
        _noticeTimer.IsRepeating = false;
        _noticeTimer.Tick += (_, _) => _notice.IsOpen = false;
        _noticeTimer.Start();
    }

    // ------------------------------------------------------------------ Approval needed (the jump)

    private void HookScroller()
    {
        if (_scroller != null) return;
        _scroller = FindChild<ScrollViewer>(_ctx.Transcript);
        if (_scroller != null) _scroller.ViewChanged += (_, _) => UpdateJump();
    }

    /// Where the card's actions row ends, in the transcript's viewport (null when unknown).
    private double? ActionsBottom()
    {
        if (_card == null || _scroller == null || _card.Actions.XamlRoot == null) return null;
        try { return _card.Actions.TransformToVisual(_scroller).TransformPoint(new Point(0, _card.Actions.ActualHeight)).Y; }
        catch (ArgumentException) { return null; }
    }

    /// While an approval is open and its card's buttons aren't fully in view, "Approval needed" floats over the
    /// transcript (Mac: the jump button in approval mode).
    private void UpdateJump()
    {
        if (_closed) return;
        var show = false;
        if (_card != null && !_card.State.Approval.Leaving && _scroller != null && ActionsBottom() is { } bottom)
            show = bottom > _scroller.ViewportHeight + 1 || bottom < 0;
        _jump.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Scrolls so the actions row's bottom sits 16 above the message box.
    private void JumpToApproval()
    {
        HookScroller();
        if (_scroller == null || ActionsBottom() is not { } bottom) return;
        _scroller.ChangeView(null, Math.Max(0, _scroller.VerticalOffset + bottom - _scroller.ViewportHeight + 16), null, false);
    }

    private bool AtEnd() => _scroller == null || _scroller.VerticalOffset >= _scroller.ScrollableHeight - 80;

    private void ScrollToEnd()
    {
        if (_closed || _scroller == null) return;
        _scroller.ChangeView(null, _scroller.ScrollableHeight, null, true);
    }

    private static T? FindChild<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T hit) return hit;
            if (FindChild<T>(child) is { } deeper) return deeper;
        }
        return null;
    }

    // ------------------------------------------------------------------ close

    private void Close()
    {
        if (_closed) return;
        _closed = true;
        _ticker.Stop();
        _noticeTimer?.Stop();
        _ctx.Session.RuntimeBound -= OnBound;
        _ctx.Session.Changed -= QueueLateCheck;
        OpenChats.Remove(this);
        _link.Changed -= QueueRefresh;
        _center.ApprovalTimedOut -= OnTimedOut;
        _link.Dispose();
        foreach (var sheet in _sheets.Values) sheet.Drop();
        _sheets.Clear();
        _ctx.TranscriptFooter.Children.Remove(_footer);
        _ctx.TranscriptOverlay.Children.Remove(_jump);
        _ctx.Shelf.Children.Remove(_notice);
        _ctx.Shelf.Children.Remove(_chip);
        if (_dock != null) _dock.Stop();
        if (_ctx.Dock.Content != null && ReferenceEquals(_ctx.Dock.Content, _dockContent)) _ctx.Dock.Content = null;
    }
}
