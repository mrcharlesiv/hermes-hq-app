using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;

namespace HermesHQ.Features.Voice;

/// Voice Memos feature registration & lifecycle wiring.
/// Replaces the placeholder Unavailable* audio seams with real Windows `winmm.dll` capture +
/// WinRT `MediaPlayer` playback, attaches `MemoMicControl`, `MemoRecorderBar`, `MemoDraftChip`,
/// `MemoNoticeCardView`, and tip banner to every open `ChatPage`, and exposes `TryCreateMemoBubble`
/// for `MessageView`.
public static class VoiceMemosFeature
{
    private static MemoAppWiring? _wiring;
    private static bool _registered;

    public static MemoAppWiring? Wiring => _wiring;
    public static MemoAccountStores? Stores => _wiring?.Stores;
    public static MemoController? Controller => _wiring?.Controller;
    public static MemoPlayer? Player => _wiring?.Player;

    /// Allows the app host (e.g. `MemoApp.Start()`) to supply a shared `MemoAppWiring` instance
    /// built with `WindowsVoiceAudio.*` so every composer and bubble shares one controller/player.
    public static void UseWiring(MemoAppWiring wiring) => _wiring = wiring;

    /// Builds the real Windows-backed MemoAppWiring on the UI thread (idempotent).
    public static MemoAppWiring? EnsureStarted()
    {
        if (_wiring != null) return _wiring;
        try
        {
            var paths = new MemoPaths(AppPaths.Root, Path.Combine(AppPaths.Root, "cache"), WindowsVoiceAudio.FolderGuard);
            _wiring = MemoAppWiring.Build(
                paths,
                WindowsVoiceAudio.MemoInput,
                WindowsVoiceAudio.MemoOutput,
                WindowsVoiceAudio.SystemEvents,
                FilePreferences.Shared,
                new JsonFileStore(Path.Combine(AppPaths.Root, "memo-player.json")),
                WindowsVoiceAudio.IsWindowActive);
            if (AppState.Client is { } client) _wiring.SignedIn(client.AccountId);
            AppLog.Note("memo", "voice memos ready (Windows winmm capture + MediaPlayer playback)");
        }
        catch (Exception ex)
        {
            AppLog.Error("memo", ex);
        }
        return _wiring;
    }

    public static void SignedIn(string accountId) => Run(w => w.SignedIn(accountId));
    public static void SignedOut(string accountId) => Run(w => w.SignedOut(accountId));
    public static void Ended() => Run(w => w.TearDown());
    public static void Forget(string accountId) => Run(w => w.Forget(accountId));
    internal static void StopForQuit() => Ended();

    private static void Run(Action<MemoAppWiring> act)
    {
        if (_wiring is not { } w) return;
        try { act(w); } catch (Exception ex) { AppLog.Error("memo", ex); }
    }

    /// Registers Voice Memos with `ChatExtensions.OnOpen` and `AppState.ClientChanged`.
    /// Call once from `FeatureRegistry.RegisterAll()`.
    public static void Register()
    {
        if (_registered) return;
        _registered = true;

        AppState.ClientChanged += client =>
        {
            if (client != null) SignedIn(client.AccountId);
            else Ended();
        };

        ChatExtensions.OnOpen.Add(ctx =>
        {
            if (ctx.Page is not ChatPage) return;
            var wiring = EnsureStarted();
            if (wiring == null) return;
            var host = new ChatMemoHost(ctx, wiring);
            ctx.Closed += host.Dispose;
        });
    }

    /// Transcript hook for `MessageView.UserBubble`: renders a voice memo message as `MemoBubbleView`,
    /// or returns null for ordinary text messages.
    public static FrameworkElement? TryCreateMemoBubble(ChatMessage message, ChatSession? session = null) =>
        MemoBubbleView.TryCreate(message, session);

    /// Opens Windows Privacy & security > Microphone settings.
    public static void OpenMicrophoneSettings()
    {
        _ = Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-microphone"));
    }

    private sealed class ChatMemoHost : IMemoChatHost, IDisposable
    {
        private readonly ChatContext _ctx;
        private readonly MemoAppWiring _wiring;
        private readonly DispatcherQueue _queue;
        private readonly MemoMicControl _mic;
        private readonly MemoRecorderBar _recorderBar;
        private readonly MemoDraftChip _draftChip;
        private readonly MemoNoticeCardView _noticeCard;
        private readonly Border _tipCard;
        private readonly TextBlock _tipTitle;
        private readonly TextBlock _tipBody;
        private readonly Func<bool> _hasDraft;
        private readonly Func<string, bool> _sendHandler;
        private MemoTip? _shownTip;
        private bool _disposed;

        public ChatMemoHost(ChatContext ctx, MemoAppWiring wiring)
        {
            _ctx = ctx;
            _wiring = wiring;
            _queue = DispatcherQueue.GetForCurrentThread();

            if (ctx.Session.MemoStores == null) ctx.Session.MemoStores = wiring.Stores;

            _mic = new MemoMicControl(
                () => _wiring.Controller,
                MakeTarget,
                () => ctx.Composer.ActualWidth > 0 ? ctx.Composer.ActualWidth : 340,
                () => ctx.Composer.FocusState != FocusState.Unfocused);
            _mic.BeforeRecordStart += () =>
            {
                ReadAloudFeature.Center.Stop();
                if (TalkFeature.Controller.IsActive) TalkFeature.Controller.End(TalkEnd.Replaced);
                if (DictationFeature.Controller.IsActive) DictationFeature.Controller.Cancel();
            };

            _recorderBar = new MemoRecorderBar(_wiring.Controller, _wiring.Player);

            _draftChip = new MemoDraftChip();
            _draftChip.SendClicked += () => SendCurrentDraft();
            _draftChip.RemoveClicked += () =>
            {
                if (_wiring.Stores.Drafts is { } drafts && drafts.Draft(Scope) is { } draft)
                {
                    if (_wiring.Player?.IsCurrent(draft.Path) == true) _wiring.Player.Stop();
                    drafts.Set(null, Scope);
                }
            };

            _noticeCard = new MemoNoticeCardView();
            _noticeCard.DismissClicked += () => _wiring.Controller.DismissNotice(Scope);
            _noticeCard.ActionClicked += OnNoticeAction;

            _tipTitle = new TextBlock { FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
            _tipBody = new TextBlock
            {
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            };
            var tipClose = new Button
            {
                Content = new FontIcon { Glyph = "\uE711", FontSize = 11 },
                MinWidth = 26,
                MinHeight = 26,
                Padding = new Thickness(4),
                Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
            };
            AutomationProperties.SetName(tipClose, "Dismiss tip");
            tipClose.Click += (_, _) =>
            {
                if (_shownTip is { } tip) MemoTips.Finish(FilePreferences.Shared, tip);
                MemoDismissTip();
            };
            var tipWords = new StackPanel { Spacing = 1 };
            tipWords.Children.Add(_tipTitle);
            tipWords.Children.Add(_tipBody);
            var tipGrid = new Grid { ColumnSpacing = 8 };
            tipGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            tipGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(tipWords, 0);
            Grid.SetColumn(tipClose, 1);
            tipGrid.Children.Add(tipWords);
            tipGrid.Children.Add(tipClose);
            _tipCard = new Border
            {
                Child = tipGrid,
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(12, 8, 8, 8),
                Margin = new Thickness(0, 0, 0, 6),
                BorderThickness = new Thickness(1),
                Background = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush"),
                BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
                Visibility = Visibility.Collapsed,
            };
            AutomationProperties.SetAutomationId(_tipCard, "memo.tip");

            ctx.Shelf.Children.Add(_tipCard);
            ctx.Shelf.Children.Add(_noticeCard);
            ctx.Shelf.Children.Add(_draftChip);
            ctx.Shelf.Children.Add(_recorderBar);
            ctx.ComposerTrailing.Children.Add(_mic);

            _hasDraft = () => HasDraft || _wiring.Controller.IsActive(this);
            _sendHandler = HandleComposerSend;
            ctx.HasDraftContent.Add(_hasDraft);
            ctx.SendHandlers.Add(_sendHandler);

            _wiring.Controller.NoticesChanged += OnNoticesChanged;
            if (_wiring.Stores.Drafts != null) _wiring.Stores.Drafts.Changed += OnDraftsChanged;
            if (_wiring.Player != null) _wiring.Player.Changed += OnPlayerChanged;

            RefreshAll();
        }

        private string Scope => _ctx.Session.MemoScope ?? _ctx.Session.DraftScope;
        private bool HasDraft => _wiring.Stores.Drafts?.Draft(Scope) != null;

        private MemoTarget? MakeTarget()
        {
            if (_wiring.Stores.Key is not { } accountKey) return null;
            var botName = string.IsNullOrWhiteSpace(_ctx.Session.MemoBotName) ? _ctx.Session.Title : _ctx.Session.MemoBotName;
            return new MemoTarget(Scope, this, _ctx.Session, botName, accountKey);
        }

        private bool HandleComposerSend(string typed)
        {
            if (_wiring.Controller.IsActive(this) && _wiring.Controller.State.Phase is MemoPhase.Locked or MemoPhase.Review)
            {
                _wiring.Controller.Input(new MemoInput.Send());
                return true;
            }
            if (!HasDraft) return false;
            return SendCurrentDraft(typed);
        }

        private bool SendCurrentDraft(string? typedOverride = null)
        {
            if (_wiring.Stores.Drafts?.Take(Scope) is not { } draft) return false;
            if (_wiring.Player?.IsCurrent(draft.Path) == true) _wiring.Player.Stop();
            var words = (typedOverride ?? _ctx.Composer.Text).Trim();
            if (typedOverride == null) _ctx.Composer.Text = "";
            _ = _ctx.Session.SendMemoAsync(draft, words);
            RefreshAll();
            return true;
        }

        private void OnNoticeAction(MemoNoticeAction action)
        {
            _wiring.Controller.DismissNotice(Scope);
            switch (action)
            {
                case MemoNoticeAction.OpenSettings:
                    OpenMicrophoneSettings();
                    break;
                case MemoNoticeAction.VoiceSettings:
                    SettingsWindows.Show("voice");
                    break;
                case MemoNoticeAction.Retry:
                    if (MakeTarget() is { } tgt)
                        _wiring.Controller.MemoDown(tgt, Math.Max(220, _ctx.Composer.ActualWidth), a11y: true);
                    break;
                case MemoNoticeAction.RetryDictation:
                    DictationFeature.StartDictation(_ctx);
                    break;
                case MemoNoticeAction.RetryTalk:
                    TalkFeature.StartTalk(_ctx);
                    break;
            }
        }

        // MARK: IMemoChatHost

        public bool IsOnScreen => !_disposed && _ctx.Page.IsLoaded && _ctx.Page.XamlRoot != null;
        public bool CanSendMemo => IsOnScreen && _ctx.Dock.Content == null;

        public void MemoSend(MemoFile file, bool keyboardWasUp)
        {
            _queue.TryEnqueue(() =>
            {
                _ = _ctx.Session.SendMemoAsync(file, "");
                RefreshAll();
            });
        }

        public void MemoStateChanged() => _queue.TryEnqueue(RefreshAll);
        public void MemoLevelChanged() => _queue.TryEnqueue(RefreshLevels);
        public void MemoWordsChanged() => _queue.TryEnqueue(() => _recorderBar.Refresh(this));
        public void MemoFocusStatus() => _queue.TryEnqueue(() => _recorderBar.FocusPrimary());

        public void MemoConfirmDelete(double seconds, bool recording, Action<bool> answer)
        {
            _queue.TryEnqueue(async () =>
            {
                if (_ctx.Page.XamlRoot is not { } root)
                {
                    answer(false);
                    return;
                }
                var dialog = new ContentDialog
                {
                    Title = "Delete Voice Memo?",
                    Content = $"Discard this {MemoPolicy.Total(seconds)} recording?",
                    PrimaryButtonText = "Delete",
                    CloseButtonText = recording ? "Keep Recording" : "Keep",
                    DefaultButton = ContentDialogButton.Close,
                    XamlRoot = root,
                };
                AutomationProperties.SetAutomationId(dialog, "memo.delete.confirm");
                try
                {
                    var res = await dialog.ShowAsync();
                    answer(res == ContentDialogResult.Primary);
                }
                catch (Exception)
                {
                    answer(false);
                }
            });
        }

        public void MemoShowTip(MemoTip tip)
        {
            _queue.TryEnqueue(() =>
            {
                if (MemoTips.IsDone(FilePreferences.Shared, tip)) return;
                _shownTip = tip;
                MemoTips.TalkName = _ctx.Session.Title;
                _tipTitle.Text = MemoTips.Title(tip);
                _tipBody.Text = MemoTips.Message(tip);
                _tipCard.Visibility = Visibility.Visible;
            });
        }

        public void MemoDismissTip()
        {
            _queue.TryEnqueue(() =>
            {
                _shownTip = null;
                _tipCard.Visibility = Visibility.Collapsed;
            });
        }

        private void OnNoticesChanged(string scope)
        {
            if (scope == Scope) _queue.TryEnqueue(RefreshNotice);
        }

        private void OnDraftsChanged(string scope)
        {
            if (scope == Scope) _queue.TryEnqueue(RefreshAll);
        }

        private void OnPlayerChanged(string? path)
        {
            _queue.TryEnqueue(() =>
            {
                _draftChip.Update(_wiring.Stores.Drafts?.Draft(Scope), _wiring.Player);
                if (_wiring.Controller.IsActive(this)) _recorderBar.Refresh(this);
            });
        }

        private void RefreshAll()
        {
            if (_disposed || AppShutdown.Stopping) return;
            var activeHere = _wiring.Controller.IsActive(this);
            _mic.UpdateVisual(_wiring.Controller.State, activeHere);
            _recorderBar.Refresh(this);
            _draftChip.Update(activeHere ? null : _wiring.Stores.Drafts?.Draft(Scope), _wiring.Player);
            RefreshNotice();
            _ctx.RefreshComposer();
        }

        private void RefreshLevels()
        {
            if (_disposed || AppShutdown.Stopping) return;
            var activeHere = _wiring.Controller.IsActive(this);
            _mic.UpdateVisual(_wiring.Controller.State, activeHere);
            _recorderBar.Refresh(this);
        }

        private void RefreshNotice()
        {
            if (_disposed || AppShutdown.Stopping) return;
            _noticeCard.Update(_wiring.Controller.Notice(Scope));
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _wiring.Controller.ScreenLeft(this);
            _wiring.Controller.NoticesChanged -= OnNoticesChanged;
            if (_wiring.Stores.Drafts != null) _wiring.Stores.Drafts.Changed -= OnDraftsChanged;
            if (_wiring.Player != null) _wiring.Player.Changed -= OnPlayerChanged;
            _ctx.HasDraftContent.Remove(_hasDraft);
            _ctx.SendHandlers.Remove(_sendHandler);
            _ctx.Shelf.Children.Remove(_tipCard);
            _ctx.Shelf.Children.Remove(_noticeCard);
            _ctx.Shelf.Children.Remove(_draftChip);
            _ctx.Shelf.Children.Remove(_recorderBar);
            _ctx.ComposerTrailing.Children.Remove(_mic);
        }
    }
}
