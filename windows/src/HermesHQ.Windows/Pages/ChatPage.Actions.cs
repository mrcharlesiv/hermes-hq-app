using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Pages;

/// [WIN-43] The message and reply actions, as the Mac's ChatMenus+Actions.swift: Regenerate (one step from the menu,
/// a confirm from the reply's button), Branch in New Chat ("Branching…", then the branch opens in this chat's place
/// titled "Branch of <parent>" and says "Branched into a new chat."), Rewind to Here (a confirm first) and Edit (your
/// words back in the box under an "Editing Message" strip; the next send goes out as the edit, asking first when later
/// messages would go). Failures show the Mac's alerts.
public sealed partial class ChatPage
{
    /// The words the chat's notice shows now (the walk reads it; null when none).
    public string? NoticeText => _notice?.Visibility == Visibility.Visible ? _noticeText?.Text : null;

    /// A notice the next chat shows as it opens (the branch's "Branched into a new chat."), by its stored id.
    private static (string StoredId, string Text)? _pendingNotice;
    private Border? _notice;
    private TextBlock? _noticeText;
    private ProgressRing? _noticeSpinner;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _noticeTimer;
    private bool _actionInFlight;
    /// Edit's send: takes the next send while the strip shows.
    private Func<string, bool>? _sendOverride;
    private Border? _editBanner;

    /// A capsule over the transcript's bottom edge (the Mac's showNotice): `duration` null keeps it until hidden.
    public void ShowNotice(string text, TimeSpan? duration = null, bool spinner = false)
    {
        if (_notice == null)
        {
            _noticeText = new TextBlock { FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetAutomationId(_noticeText, "chat.notice.text");
            _noticeSpinner = new ProgressRing { Width = 14, Height = 14, IsActive = false, Visibility = Visibility.Collapsed };
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Children.Add(_noticeSpinner);
            row.Children.Add(_noticeText);
            _notice = new Border
            {
                Child = row, Padding = new Thickness(14, 8, 14, 8), CornerRadius = new CornerRadius(16),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(0, 0, 0, 12), Background = ThemeBrushes.Get("AcrylicInAppFillColorDefaultBrush"),
                BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
            };
            AutomationProperties.SetAutomationId(_notice, "chat.notice");
            TranscriptOverlay.Children.Add(_notice);
            _noticeTimer = DispatcherQueue.CreateTimer();
            _noticeTimer.IsRepeating = false;
            _noticeTimer.Tick += (_, _) => HideNotice();
        }
        _noticeText!.Text = text;
        AutomationProperties.SetName(_notice, text);
        _noticeSpinner!.IsActive = spinner;
        _noticeSpinner.Visibility = spinner ? Visibility.Visible : Visibility.Collapsed;
        _notice.Visibility = Visibility.Visible;
        _noticeTimer!.Stop();
        if (duration is { } d) { _noticeTimer.Interval = d; _noticeTimer.Start(); }
    }

    public void HideNotice()
    {
        if (_noticeSpinner != null) _noticeSpinner.IsActive = false;
        if (_notice != null) _notice.Visibility = Visibility.Collapsed;
        _noticeTimer?.Stop();
    }

    private void StopActionsForClose()
    {
        HideNotice();
        EndEdit();
    }

    private static readonly TimeSpan NoticeSeconds = TimeSpan.FromSeconds(3);

    /// Called as the chat opens: a branch's pending notice.
    private void ShowPendingNotice()
    {
        if (_pendingNotice is { } p && p.StoredId == StoredId)
        {
            _pendingNotice = null;
            ShowNotice(p.Text, NoticeSeconds);
        }
    }

    /// Edit's override of the message box's send; true when it took the send.
    private bool TakeEditSend(string text) => _sendOverride?.Invoke(text) == true;

    // MARK: The menu's and the action row's actions

    public void PerformMessageAction(MessageMenuItem id, string messageId)
    {
        if (_vm == null) return;
        AppLog.Note("chatui", $"message action chosen: {id}");
        switch (id)
        {
            case MessageMenuItem.Edit: BeginEdit(messageId); break;
            case MessageMenuItem.Regenerate: RegenerateLatest(); break;
            case MessageMenuItem.Branch: _ = BranchAsync(messageId); break;
            case MessageMenuItem.Rewind: _ = ConfirmRewindAsync(messageId); break;
        }
    }

    /// The latest reply's Regenerate: the prompt runs again in its place.
    public void RegenerateLatest()
    {
        if (_vm is not { } vm) return;
        if (ChatActionRules.RegenerateBlocked(vm.Busy, offline: false) is { } why) { ShowNotice(why, NoticeSeconds); return; }
        ScrollToEnd();
        var done = vm.Session.Regenerate(reason => DispatcherQueue.TryEnqueue(() =>
            _ = FailureAsync(ChatActionWords.RegenerateFailed, reason, RegenerateLatest)));
        if (!done) ShowNotice(ChatActionWords.CantRegenerate, NoticeSeconds);
    }

    /// The action row's Regenerate: a confirm first (the reply it replaces can't be brought back).
    public async Task ConfirmRegenerateAsync()
    {
        if (_vm is not { } vm) return;
        if (ChatActionRules.RegenerateBlocked(vm.Busy, offline: false) is { } why) { ShowNotice(why, NoticeSeconds); return; }
        var dialog = new ContentDialog
        {
            Title = ChatActionWords.RegenerateTitle, Content = ChatActionWords.RegenerateMessage,
            PrimaryButtonText = ChatActionWords.RegenerateButton, CloseButtonText = ChatActionWords.Cancel,
            DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        AutomationProperties.SetAutomationId(dialog, "chat.regenerate.confirm");
        if (await SafeDialog.ShowAsync(XamlRoot, dialog) == ContentDialogResult.Primary) RegenerateLatest();
    }

    /// A new chat from the start through a message; it opens in this one's place.
    public async Task BranchAsync(string? messageId)
    {
        if (_vm is not { } vm || _actionInFlight) return;
        _actionInFlight = true;
        ShowNotice(ChatActionWords.Branching, spinner: true);
        try
        {
            var result = await vm.Session.BranchAsync(messageId);
            _actionInFlight = false;
            HideNotice();
            AppLog.Note("chatui", "branch chat succeeded");
            _pendingNotice = (result.StoredId, ChatActionWords.Branched);
            Navigator.Go(new ChatDestination(vm.Session.Profile, result.StoredId, ChatActionWords.BranchTitle(ChatTitle)));
        }
        catch (GatewayException e)
        {
            _actionInFlight = false;
            HideNotice();
            AppLog.Note("chatui", $"branch chat failed: {e.Code}");
            await FailureAsync(ChatActionWords.BranchFailed, e.Message, () => _ = BranchAsync(messageId));
        }
    }

    /// Rewind to Here: a confirm first.
    private async Task ConfirmRewindAsync(string messageId)
    {
        if (_vm is not { } vm) return;
        var dialog = new ContentDialog
        {
            Title = ChatActionWords.RewindTitle, Content = ChatActionWords.RewindMessage,
            PrimaryButtonText = ChatActionWords.RewindButton, CloseButtonText = ChatActionWords.Cancel,
            DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot,
        };
        AutomationProperties.SetAutomationId(dialog, "chat.rewind.confirm");
        if (await SafeDialog.ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;
        ScrollToEnd();
        var done = vm.Session.Rewind(messageId, reason => DispatcherQueue.TryEnqueue(() =>
            _ = FailureAsync(ChatActionWords.RewindFailed, reason, null)));
        if (!done) ShowNotice(ChatActionWords.CantRewind, NoticeSeconds);
    }

    /// Edit: your message's words in the box with an "Editing Message" strip; the next send goes out as the edit.
    private void BeginEdit(string messageId)
    {
        if (_vm is not { } vm || vm.Session.Messages.FirstOrDefault(m => m.Id == messageId) is not { } message) return;
        var draft = Composer.Text;
        var later = ChatActionRules.HasLaterMessages(vm.Session.Messages, messageId);
        EndEdit();
        _editBanner = EditBanner(later, () => { EndEdit(); Composer.Text = draft; });
        Shelf.Children.Add(_editBanner);
        Composer.Text = message.Text;
        Composer.SelectionStart = Composer.Text.Length;
        _sendOverride = text =>
        {
            if (!ChatActionRules.HasLaterMessages(vm.Session.Messages, messageId)) { SendEdit(messageId, text, draft); return true; }
            _ = ConfirmEditAsync(messageId, text, draft);
            return true;
        };
        Composer.Focus(FocusState.Programmatic);
    }

    private async Task ConfirmEditAsync(string messageId, string text, string draft)
    {
        var dialog = new ContentDialog
        {
            Title = ChatActionWords.EditTitle, Content = ChatActionWords.EditMessage,
            PrimaryButtonText = ChatActionWords.EditButton, CloseButtonText = ChatActionWords.Cancel,
            DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot,
        };
        AutomationProperties.SetAutomationId(dialog, "chat.edit.confirm");
        if (await SafeDialog.ShowAsync(XamlRoot, dialog) == ContentDialogResult.Primary) SendEdit(messageId, text, draft);
        else if (Composer.Text.Length == 0) Composer.Text = text;   // Cancel keeps editing: the words go back
    }

    private void SendEdit(string messageId, string text, string draft)
    {
        if (_vm is not { } vm) return;
        EndEdit();
        if (draft.Length > 0 && Composer.Text.Length == 0) Composer.Text = draft;
        ScrollToEnd();
        var done = vm.Session.Edit(messageId, text, reason => DispatcherQueue.TryEnqueue(() =>
        {
            // An edit that didn't go out comes back into the box as typed.
            if (Composer.Text.Length == 0) Composer.Text = text;
            _ = FailureAsync(ChatActionWords.EditFailed, reason, null);
        }));
        if (!done)
        {
            Composer.Text = text;
            ShowNotice(ChatActionWords.CantEdit, NoticeSeconds);
        }
    }

    private void EndEdit()
    {
        _sendOverride = null;
        if (_editBanner != null) Shelf.Children.Remove(_editBanner);
        _editBanner = null;
    }

    /// The Mac's ComposerEditBanner: "Editing Message" (and "Later messages will be removed"), ✕ to cancel.
    private static Border EditBanner(bool removesLater, Action cancel)
    {
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = ChatActionWords.EditingTitle, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        if (removesLater)
        {
            var note = new TextBlock { Text = ChatActionWords.EditingNote, FontSize = 12, Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush") };
            AutomationProperties.SetAutomationId(note, "composer.editing.note");
            words.Children.Add(note);
        }
        var close = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 12 }, MinWidth = 32, MinHeight = 32, Background = null, BorderThickness = new Thickness(0) };
        AutomationProperties.SetName(close, ChatActionWords.CancelEditing);
        AutomationProperties.SetAutomationId(close, "composer.editing.cancel");
        ToolTipService.SetToolTip(close, ChatActionWords.CancelEditing);
        close.Click += (_, _) => cancel();
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new FontIcon { Glyph = "\uE70F", FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(icon);
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        Grid.SetColumn(close, 2);
        grid.Children.Add(close);
        var banner = new Border
        {
            Child = grid, Padding = new Thickness(14, 4, 4, 4), CornerRadius = new CornerRadius(18), Margin = new Thickness(0, 0, 0, 6),
            Background = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(banner, "composer.editing");
        return banner;
    }

    /// The Mac's failure alert: the title, the reason, Try Again when it can be tried again.
    private async Task FailureAsync(string title, string reason, Action? retry)
    {
        if (XamlRoot == null) return;
        var dialog = new ContentDialog
        {
            Title = title, Content = reason, CloseButtonText = "OK", XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Close,
        };
        if (retry != null) dialog.PrimaryButtonText = "Try Again";
        AutomationProperties.SetAutomationId(dialog, "chat.action.failure");
        if (await SafeDialog.ShowAsync(XamlRoot, dialog) == ContentDialogResult.Primary) retry?.Invoke();
    }
}
