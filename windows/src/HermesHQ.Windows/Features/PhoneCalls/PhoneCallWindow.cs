using Hermes.Core.PhoneCalls;
using HermesHQ.Features.Kanban;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.PhoneCalls;

/// Dedicated Phone Call window (`PhoneCallScreen.swift` + `PhoneCallView.swift` port):
/// New Call form -> Review step -> Ringing -> Live (transcript + `ask_owner` prompt + Mute/Hold/Hangup + whisper dock)
/// -> Summary & Transcript view.
public sealed class PhoneCallWindow : Window
{
    private static PhoneCallWindow? _open;

    private readonly PhoneCallController _controller;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherTimer _tickTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer _pollTimer = new() { Interval = TimeSpan.FromMilliseconds(2500) };

    private string? _viewingCallId;
    private bool _reviewStep;
    private bool _showTranscript;
    private bool _polling;
    private bool _closed;
    private TextBlock? _activeStatusText;
    private string _replyDraft = "";
    private string _whisperDraft = "";

    // Form draft state
    private string _toText = "";
    private string _nameText = "";
    private string _goalText = "";
    private PhoneVoicemailChoice _voicemail = PhoneVoicemailChoice.HangUp;
    private string? _chatProfile;
    private string? _chatSessionId;
    private string? _formError;

    private readonly Grid _root = new();
    private readonly StackPanel _body = new() { Spacing = 12, Padding = new Thickness(20, 12, 20, 20) };
    private readonly Border _footer = new() { Padding = new Thickness(16, 10, 16, 14), BorderThickness = new Thickness(0, 1, 0, 0) };
    private readonly TextBlock _headerTitle = Text("Phone Call", 16, bold: true, wrap: false);

    public static void Show(PhoneCallController controller, PhoneStartIntent? prefill = null, string? callId = null, bool startInReview = false)
    {
        if (_open != null)
        {
            _open.ApplyStart(prefill, callId, startInReview);
            _open.Activate();
            return;
        }
        var win = new PhoneCallWindow(controller, prefill, callId, startInReview);
        _open = win;
        win.Closed += (_, _) =>
        {
            if (_open == win) _open = null;
        };
        win.Activate();
    }

    internal static void CloseOpen() => _open?.Close();

    private PhoneCallWindow(PhoneCallController controller, PhoneStartIntent? prefill, string? callId, bool startInReview)
    {
        _controller = controller;
        Title = "Hermes Phone Call";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(520, 700));

        var bar = new Grid { Padding = new Thickness(16, 12, 16, 8), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(_headerTitle);

        var settingsBtn = Quiet("Settings…", () => _ = PhoneCallsFeature.OpenSettingsAsync(_root.XamlRoot));
        Grid.SetColumn(settingsBtn, 1);
        bar.Children.Add(settingsBtn);

        _footer.BorderBrush = Brush("DividerStrokeColorDefaultBrush");

        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.Children.Add(bar);

        var scroller = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroller, 1);
        _root.Children.Add(scroller);
        Grid.SetRow(_footer, 2);
        _root.Children.Add(_footer);
        Content = _root;

        _controller.Changed += OnControllerChanged;
        _tickTimer.Tick += (_, _) => UpdateActiveElapsed();
        _pollTimer.Tick += (_, _) => _ = PollOnceAsync();
        Closed += (_, _) =>
        {
            _closed = true;
            _tickTimer.Stop();
            _pollTimer.Stop();
            _controller.Changed -= OnControllerChanged;
        };

        ApplyStart(prefill, callId, startInReview);
    }

    private void ApplyStart(PhoneStartIntent? prefill, string? callId, bool startInReview)
    {
        _formError = null;
        _showTranscript = false;
        if (callId != null)
        {
            _viewingCallId = callId;
            _reviewStep = false;
        }
        else if (prefill != null)
        {
            _viewingCallId = null;
            _toText = prefill.To;
            _nameText = prefill.TargetName ?? "";
            _goalText = prefill.Goal;
            _voicemail = prefill.Voicemail;
            _chatProfile = prefill.ChatProfile;
            _chatSessionId = prefill.ChatSessionId;
            _reviewStep = startInReview && !string.IsNullOrWhiteSpace(_toText) && !string.IsNullOrWhiteSpace(_goalText);
        }
        else if (_controller.ActiveCall != null)
        {
            _viewingCallId = _controller.ActiveCall.Id;
            _reviewStep = false;
        }
        Render();
    }

    private void OnControllerChanged()
    {
        if (_closed || AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!_closed && !AppShutdown.Stopping) Render(); });
    }

    private void UpdateActiveElapsed()
    {
        if (_closed || AppShutdown.Stopping) return;
        if (_controller.ActiveCall is { IsActive: true } call && _activeStatusText != null)
            _activeStatusText.Text = ActiveStatusLabel(call, DateTimeOffset.UtcNow);
    }

    private static string ActiveStatusLabel(PhoneCallRecord call, DateTimeOffset now)
    {
        var timer = PhoneFormatting.FormatTimer(call.Elapsed(now));
        return call.State switch
        {
            PhoneCallState.Dialing => "Dialing…",
            PhoneCallState.Ringing => "Ringing…",
            PhoneCallState.OnHold => $"On Hold · {timer}",
            PhoneCallState.Ending => "Ending call…",
            _ => call.VoicemailDetected ? $"Voicemail · {timer}" : $"Connected · {timer}",
        };
    }

    private async Task PollOnceAsync()
    {
        if (_polling || _controller.ActiveCall is not { IsActive: true }) return;
        _polling = true;
        try { await _controller.RefreshActiveAsync(); }
        catch (Exception ex) { AppLog.Note("phone", $"poll skipped: {ex.GetType().Name}"); }
        finally { _polling = false; }
    }

    private void Render()
    {
        if (_closed || AppShutdown.Stopping) return;
        _activeStatusText = null;
        _body.Children.Clear();
        _footer.Child = null;
        _footer.Visibility = Visibility.Collapsed;

        var active = _controller.ActiveCall;
        if (active is { IsActive: true })
        {
            _viewingCallId = active.Id;
            if (!_tickTimer.IsEnabled) _tickTimer.Start();
            if (!_pollTimer.IsEnabled) _pollTimer.Start();
            RenderActiveCall(active);
            return;
        }

        _tickTimer.Stop();
        _pollTimer.Stop();

        if (_viewingCallId != null && _controller.FindCall(_viewingCallId) is { IsDone: true } finished)
        {
            RenderSummary(finished);
            return;
        }

        if (_reviewStep) RenderReviewForm();
        else RenderComposeForm();
    }

    private void RenderComposeForm()
    {
        _headerTitle.Text = "New Phone Call";
        if (!_controller.IsReady)
        {
            var setupNotice = new StackPanel { Spacing = 8 };
            setupNotice.Children.Add(Text("Finish Phone Setup", 14, bold: true));
            setupNotice.Children.Add(Text("Connect your samplehost API key, outbound number, voice connection, and AI assistant to place calls.", 13, color: Secondary));
            setupNotice.Children.Add(Push("Open Phone Settings…", () => _ = PhoneCallsFeature.OpenSettingsAsync(_root.XamlRoot), accent: true));
            _body.Children.Add(Card(setupNotice, 12));
        }

        _body.Children.Add(Header("Phone Number"));
        var toBox = new TextBox { Text = _toText, PlaceholderText = "+1 555 010 0123" };
        toBox.TextChanged += (_, _) => _toText = toBox.Text;
        AutomationProperties.SetAutomationId(toBox, "phone.form.to");
        _body.Children.Add(toBox);

        _body.Children.Add(Header("Name (Optional)"));
        var nameBox = new TextBox { Text = _nameText, PlaceholderText = "Dentist office, clinic, etc." };
        nameBox.TextChanged += (_, _) => _nameText = nameBox.Text;
        AutomationProperties.SetAutomationId(nameBox, "phone.form.name");
        _body.Children.Add(nameBox);

        _body.Children.Add(Header("Goal for This Call"));
        var goalBox = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Text = _goalText,
            PlaceholderText = "Check next Tuesday morning availability and book an appointment.",
            MinHeight = 88,
        };
        goalBox.TextChanged += (_, _) => _goalText = goalBox.Text;
        AutomationProperties.SetAutomationId(goalBox, "phone.form.goal");
        _body.Children.Add(goalBox);

        _body.Children.Add(Header("If Voicemail Answers"));
        var vmStack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        var hang = new RadioButton { Content = "Hang up", GroupName = "phone-vm", IsChecked = _voicemail == PhoneVoicemailChoice.HangUp };
        var leave = new RadioButton { Content = "Leave a message", GroupName = "phone-vm", IsChecked = _voicemail == PhoneVoicemailChoice.LeaveMessage };
        hang.Checked += (_, _) => _voicemail = PhoneVoicemailChoice.HangUp;
        leave.Checked += (_, _) => _voicemail = PhoneVoicemailChoice.LeaveMessage;
        vmStack.Children.Add(hang);
        vmStack.Children.Add(leave);
        _body.Children.Add(vmStack);

        if (!string.IsNullOrEmpty(_formError))
            _body.Children.Add(Text(_formError, 13, color: Critical));

        var reviewBtn = Push("Review Call", () =>
        {
            if (PhoneFormatting.NormalizeDestination(_toText) == null)
            {
                _formError = "Enter a valid phone number (for example, +1 555 010 0123).";
                Render();
                return;
            }
            if (string.IsNullOrWhiteSpace(_goalText))
            {
                _formError = "Describe what the call should accomplish.";
                Render();
                return;
            }
            _formError = null;
            _reviewStep = true;
            Render();
        }, accent: true);
        reviewBtn.HorizontalAlignment = HorizontalAlignment.Right;
        _footer.Child = reviewBtn;
        _footer.Visibility = Visibility.Visible;
    }

    private void RenderReviewForm()
    {
        _headerTitle.Text = "Review Call";
        var normalized = PhoneFormatting.NormalizeDestination(_toText) ?? _toText;
        var summary = new StackPanel { Spacing = 8 };
        summary.Children.Add(Text(string.IsNullOrWhiteSpace(_nameText) ? PhoneFormatting.FormatShown(normalized) : _nameText.Trim(), 18, bold: true));
        summary.Children.Add(Text(PhoneFormatting.FormatShown(normalized), 13, color: Secondary));
        summary.Children.Add(Header("Goal"));
        summary.Children.Add(Text(_goalText.Trim(), 14));
        summary.Children.Add(Header("Options"));
        summary.Children.Add(Text(
            $"Voicemail: {(_voicemail == PhoneVoicemailChoice.LeaveMessage ? "Leave a message" : "Hang up")} · Recording: {(_controller.Setup.RecordCalls ? "On" : "Off")}",
            12, color: Secondary));
        _body.Children.Add(Card(summary, 14));

        if (!string.IsNullOrEmpty(_formError))
            _body.Children.Add(Text(_formError, 13, color: Critical));

        var actions = new Grid();
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        actions.Children.Add(Quiet("Edit", () => { _reviewStep = false; Render(); }));
        var callBtn = Push("Place Call", () => _ = DialFromReviewAsync(), accent: true);
        callBtn.IsEnabled = _controller.IsReady;
        AutomationProperties.SetAutomationId(callBtn, "phone.review.call");
        Grid.SetColumn(callBtn, 2);
        actions.Children.Add(callBtn);
        _footer.Child = actions;
        _footer.Visibility = Visibility.Visible;
    }

    private async Task DialFromReviewAsync()
    {
        _formError = null;
        try
        {
            var intent = new PhoneStartIntent(_toText, _goalText, string.IsNullOrWhiteSpace(_nameText) ? null : _nameText.Trim(), _voicemail, _chatProfile, _chatSessionId);
            var call = await _controller.DialAsync(intent);
            _viewingCallId = call.Id;
            _reviewStep = false;
            Render();
        }
        catch (Exception ex)
        {
            _formError = PhoneMessages.Format(ex, PhoneCallsFeature.KeyStore.ReadKey(_controller.AccountId));
            Render();
        }
    }

    private void RenderActiveCall(PhoneCallRecord call)
    {
        var now = DateTimeOffset.UtcNow;
        _headerTitle.Text = call.DisplayTarget;

        // Status hero card
        var hero = new StackPanel { Spacing = 8 };
        var statusRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var stateColor = call.PendingQuestion != null ? Red : call.IsLive ? Green : Blue;
        statusRow.Children.Add(Dot(stateColor, 10));
        _activeStatusText = Text(ActiveStatusLabel(call, now), 15, bold: true);
        statusRow.Children.Add(_activeStatusText);
        hero.Children.Add(statusRow);
        hero.Children.Add(Text(PhoneFormatting.FormatShown(call.To), 12, color: Secondary));
        hero.Children.Add(Text(call.Goal, 13, color: Secondary));

        // Live call controls: Mute, Hold, Hang Up
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 6, 0, 0) };
        if (call.IsLive)
        {
            var muteBtn = Push(call.IsMuted ? "Unmute" : "Mute", () => _ = _controller.ToggleMuteAsync());
            var holdBtn = Push(call.IsOnHold ? "Resume" : "Hold", () => _ = _controller.ToggleHoldAsync());
            controls.Children.Add(muteBtn);
            controls.Children.Add(holdBtn);
        }
        var hangupBtn = Push("Hang Up", () => _ = _controller.HangupAsync(PhoneLocalEnd.YouHungUp));
        hangupBtn.Foreground = Critical;
        AutomationProperties.SetAutomationId(hangupBtn, "phone.live.hangup");
        controls.Children.Add(hangupBtn);
        hero.Children.Add(controls);
        _body.Children.Add(Card(hero, 14));

        // `ask_owner` question card when assistant pauses for input
        if (call.PendingQuestion is { } q)
        {
            var qStack = new StackPanel { Spacing = 8 };
            qStack.Children.Add(Text("Assistant needs your answer", 12, bold: true, color: Critical));
            qStack.Children.Add(Text(q.Question, 15, bold: true));

            if (q.Choices.Count > 0)
            {
                var choicesRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                foreach (var choice in q.Choices)
                {
                    var c = choice;
                    choicesRow.Children.Add(Push(c, () => _ = _controller.AnswerQuestionAsync(q.ToolCallId, c), accent: true));
                }
                qStack.Children.Add(choicesRow);
            }

            var replyGrid = new Grid { ColumnSpacing = 8 };
            replyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            replyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var replyBox = new TextBox { PlaceholderText = "Type an answer…", Text = _replyDraft };
            replyBox.TextChanged += (_, _) => _replyDraft = replyBox.Text;
            replyGrid.Children.Add(replyBox);
            var sendAns = Push("Reply", () =>
            {
                var answer = replyBox.Text;
                _replyDraft = "";
                replyBox.Text = "";
                _ = _controller.AnswerQuestionAsync(q.ToolCallId, answer);
            }, accent: true);
            Grid.SetColumn(sendAns, 1);
            replyGrid.Children.Add(sendAns);
            qStack.Children.Add(replyGrid);

            var qCard = Card(qStack, 12);
            qCard.BorderBrush = Critical;
            _body.Children.Add(qCard);
        }

        // Live transcript stream
        _body.Children.Add(Header("Live Transcript"));
        if (call.Lines.Count == 0)
        {
            _body.Children.Add(Text(call.IsLive ? "Listening for speech…" : "Waiting for answer…", 13, color: Secondary));
        }
        else
        {
            foreach (var line in call.Lines)
                _body.Children.Add(TranscriptBubble(line, call.DisplayTarget));
        }

        // Bottom whisper dock ("Tell the assistant")
        if (call.IsLive)
        {
            var dock = new Grid { ColumnSpacing = 8 };
            dock.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            dock.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var whisperBox = new TextBox { PlaceholderText = "Tell the assistant something…", Text = _whisperDraft };
            whisperBox.TextChanged += (_, _) => _whisperDraft = whisperBox.Text;
            dock.Children.Add(whisperBox);
            var sendBtn = Push("Send", () =>
            {
                var txt = whisperBox.Text.Trim();
                if (txt.Length == 0) return;
                _whisperDraft = "";
                whisperBox.Text = "";
                _ = _controller.TellAssistantAsync(txt);
            });
            Grid.SetColumn(sendBtn, 1);
            dock.Children.Add(sendBtn);
            _footer.Child = dock;
            _footer.Visibility = Visibility.Visible;
        }
    }

    private void RenderSummary(PhoneCallRecord call)
    {
        var now = DateTimeOffset.UtcNow;
        _headerTitle.Text = _showTranscript ? "Transcript" : call.DisplayTarget;

        if (_showTranscript)
        {
            _body.Children.Add(Quiet("‹ Back to Summary", () => { _showTranscript = false; Render(); }));
            if (call.Lines.Count == 0)
                _body.Children.Add(Text("No transcript was captured for this call.", 13, color: Secondary));
            else
                foreach (var line in call.Lines) _body.Children.Add(TranscriptBubble(line, call.DisplayTarget));
            return;
        }

        var titleCard = new StackPanel { Spacing = 6 };
        titleCard.Children.Add(Text(PhoneCallPresentation.Title(call), 18, bold: true));
        titleCard.Children.Add(Text(PhoneCallPresentation.WhatHappened(call), 14));
        _body.Children.Add(Card(titleCard, 14));

        if (call.QAs.Count > 0)
        {
            _body.Children.Add(Header("Questions Answered"));
            var qaStack = new StackPanel { Spacing = 6 };
            foreach (var qa in call.QAs)
            {
                qaStack.Children.Add(Text("Q: " + qa.Question, 13, bold: true));
                qaStack.Children.Add(Text("A: " + qa.Answer, 13, color: Secondary));
            }
            _body.Children.Add(Card(qaStack, 12));
        }

        _body.Children.Add(Header("Call Details"));
        var factsStack = new StackPanel { Spacing = 6 };
        foreach (var (label, value) in PhoneCallPresentation.Facts(call, now))
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(Text(label, 12, color: Secondary));
            var val = Text(value, 13);
            Grid.SetColumn(val, 1);
            row.Children.Add(val);
            factsStack.Children.Add(row);
        }
        _body.Children.Add(Card(factsStack, 12));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (call.Lines.Count > 0)
            actions.Children.Add(Push($"Transcript ({call.Lines.Count})", () => { _showTranscript = true; Render(); }));
        actions.Children.Add(Push("Call Again", () =>
        {
            ApplyStart(new PhoneStartIntent(call.To, call.Goal, call.TargetName, call.Voicemail, call.ChatProfile, call.ChatSessionId), null, startInReview: true);
        }, accent: true));
        if (call.Outcome?.Kind == PhoneOutcomeKind.Voicemail && call.Voicemail == PhoneVoicemailChoice.HangUp)
        {
            actions.Children.Add(Push("Leave a Message", () =>
            {
                ApplyStart(new PhoneStartIntent(call.To, call.Goal, call.TargetName, PhoneVoicemailChoice.LeaveMessage, call.ChatProfile, call.ChatSessionId), null, startInReview: true);
            }));
        }
        actions.Children.Add(Quiet("Copy Share", () =>
        {
            var key = PhoneCallsFeature.KeyStore.ReadKey(_controller.AccountId);
            Copy(PhoneCallPresentation.ShareText(call, key));
        }));
        _body.Children.Add(actions);

        var doneBtn = Push("Done", Close);
        doneBtn.HorizontalAlignment = HorizontalAlignment.Right;
        _footer.Child = doneBtn;
        _footer.Visibility = Visibility.Visible;
    }

    private static FrameworkElement TranscriptBubble(PhoneTranscriptLine line, string remoteLabel)
    {
        var who = line.Speaker switch
        {
            PhoneSpeaker.Assistant => "Assistant",
            PhoneSpeaker.Them => remoteLabel,
            PhoneSpeaker.You => line.Pending ? "You (sending…)" : "You",
            _ => "System",
        };
        var accentColor = line.Speaker switch
        {
            PhoneSpeaker.You => Blue,
            PhoneSpeaker.Assistant => Green,
            _ => Rgb(0x8E, 0x8E, 0x93),
        };
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(Text(who, 11, bold: true, color: Solid(accentColor)));
        stack.Children.Add(Text(line.Text, 13));
        return Card(stack, 9);
    }
}
