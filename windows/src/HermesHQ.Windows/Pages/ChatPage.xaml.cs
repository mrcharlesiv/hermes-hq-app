using Hermes.Core.Net;
using HermesHQ.Services;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;
using Windows.UI.Core;

namespace HermesHQ.Pages;

/// One chat. Enter sends, Shift+Enter adds a line, Esc stops a reply. Scrolling near the top reads older history.
public sealed partial class ChatPage : Page
{
    private ScrollViewer? _scroller;
    private bool _loadingOlder;
    private bool _stickToEnd = true; // the view follows new messages while you're at the bottom
    private string? _statusOverride; // a feature's words over "Replying…" (Waiting for your approval)

    private readonly Features.Composer.DirectComposerFit _composerFit;

    public ChatPage()
    {
        InitializeComponent();
        _composerFit = new(ComposerRow, ComposerMetrics, Composer, ComposerModel);
        Composer.GotFocus += (_, _) => App.Window?.DismissToolTips();
        Loaded += (_, _) =>
        {
            ApplyLook();
            Features.Settings.ThemeService.Changed -= ApplyLook;
            Features.Settings.ThemeService.Changed += ApplyLook;
            Hermes.Core.Settings.BackdropPrefs.Changed -= ApplyLook;
            Hermes.Core.Settings.BackdropPrefs.Changed += ApplyLook;
        };
        Unloaded += (_, _) =>
        {
            Features.Settings.ThemeService.Changed -= ApplyLook;
            Hermes.Core.Settings.BackdropPrefs.Changed -= ApplyLook;
        };
    }

    private void ApplyLook()
    {
        var desktop = Features.Settings.ThemeService.State.DesktopLook;
        ComposerBox.CornerRadius = new CornerRadius(desktop ? 8 : 20);
        Background = Features.Settings.BackdropPainter.CreateBrush(Hermes.Core.Settings.BackdropPlace.Chats)
            ?? ThemeBrushes.Get("HQPageBrush");
    }

    private void ComposerModel_Click(object sender, RoutedEventArgs e) => _context?.OpenModelPicker?.Invoke();

    public int MessageCount => _vm?.Items.Count ?? 0;
    public bool IsBusy => _vm?.Busy == true;
    /// The open chat's stored id and title (the screenshot walks check `/new` put a new chat in this one's place).
    public string? StoredId { get; private set; }
    public string? ChatTitle { get; private set; }
    /// The chat's folder as its resume info and `session.info` give it (the Mac's `LiveChatSession.workingDirectory`);
    /// null until known. New Chat Here starts in the project holding it (Hermes.Core.Shell.NewChatHere).
    public string? LiveCwd => _context?.Session.Cwd;
    public void AutomationSend(string text) { Composer.Text = text; Send(); }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not Args args || AppState.Client is not { } client)
        {
            LoadingRing.IsActive = false;
            return;
        }
        try
        {
            _statusOverride = null;
            StoredId = args.StoredId;
            ChatTitle = args.Title;
            TitleText.Text = args.Title.ToUpperInvariant();
            ShowHeaderFace(args);
            _composerFit.SetTitle(args.Title);
            _composerFit.SetModel(null);
            var session = client.OpenChat(args.Profile, args.StoredId, args.Title);
            var vm = new ChatViewModel(session, DispatcherQueue);
            var opening = new ChatContext
            {
                Session = session, Page = this, Shelf = Shelf, ComposerLeading = ComposerLeading,
                ComposerTrailing = ComposerTrailing, Dock = Dock, MoreMenu = MoreMenu, HeaderTrailing = HeaderTrailing, Inspector = Inspector,
                ShowInspector = ShowInspector, IsInspectorShown = () => InspectorShown, IsBotChat = args.BotChat, Composer = Composer,
                TranscriptFooter = TranscriptFooter, TranscriptOverlay = TranscriptOverlay, Transcript = Messages, TranscriptEmpty = TranscriptEmpty,
                RowCount = () => vm.Items.Count, HasHiddenRows = () => session.HasOlder,
                SetStatus = s => { if (_vm == vm) { _statusOverride = s; UpdateComposer(); } },
            };
            AttachOpening(opening, vm, args);
            opening.SetModelChip = name => { if (Owns(opening)) _composerFit.SetModel(name); };
            opening.RefreshComposer = () => { if (Owns(opening)) UpdateComposer(); };
            opening.Submit = () => { if (Owns(opening)) Send(); };
            var dockChange = Dock.RegisterPropertyChangedCallback(ContentControl.ContentProperty, (_, _) =>
            {
                if (!Owns(opening)) return;
                var docked = Dock.Content != null;
                Dock.Visibility = docked ? Visibility.Visible : Visibility.Collapsed;
                ComposerBox.Visibility = docked ? Visibility.Collapsed : Visibility.Visible;
            });
            opening.Closed += () => Dock.UnregisterPropertyChangedCallback(ContentControl.ContentProperty, dockChange);
            foreach (var hook in ChatExtensions.OnOpen)
            {
                if (!Owns(opening)) return;
                try { hook(opening); }
                catch (Exception x) { AppLog.Error("chat-extension", x); }
            }
            if (!Owns(opening)) return;
            MoreButton.Visibility = MoreMenu.Items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            InspectorToggle.Visibility = Inspector.Content != null ? Visibility.Visible : Visibility.Collapsed;
            Messages.ItemsSource = vm.Items;
            void MessagesLoaded(object sender, RoutedEventArgs e) { if (Owns(opening)) HookScroller(); }
            Messages.Loaded += MessagesLoaded;
            opening.Closed += () => Messages.Loaded -= MessagesLoaded;
            ShowPendingNotice();   // [chat actions] a branch opens saying "Branched into a new chat."
            if (args.Draft.Length > 0)   // [composer] /new's words, after the features hooked the box (its drawers see them)
            {
                Composer.Text = args.Draft;
                Composer.SelectionStart = args.Draft.Length;
            }
            // The message box has the keyboard as the chat opens. Before the page is in the window (a chat opened as a sheet
            // closes: New Chat With…) the focus doesn't take, so it is given again once the page has loaded.
            if (Composer.Focus(FocusState.Programmatic))
            {
                App.Window?.DismissToolTips();
            }
            else
            {
                void Again(object sender, RoutedEventArgs _)
                {
                    Loaded -= Again;
                    if (Owns(opening))
                    {
                        Composer.Focus(FocusState.Programmatic);
                        App.Window?.DismissToolTips();
                    }
                }
                Loaded += Again;
                opening.Closed += () => Loaded -= Again;
            }
            if (Owns(opening)) await FinishOpeningAsync(opening, vm, args);
        }
        catch (Exception ex) { AppLog.Error("chat", ex); LoadingRing.IsActive = false; }
    }

    /// The bot's face left of the name (AppModel.makeChatScreen at 93f984bb1): the chat's own bot by its profile, in a
    /// bot's own chat only. It was drawn from the title, so a just-started "New Chat" wore that name's default head.
    private void ShowHeaderFace(Args args)
    {
        var face = Hermes.Core.Chat.ChatHeaderFace.For(args.Profile, args.Title, args.BotChat,
            p => HermesHQ.Features.Bots.ListsHub.Current?.Bots.Bot(p)?.Model);
        Head.Visibility = face == null ? Visibility.Collapsed : Visibility.Visible;
        if (face == null) return;
        Head.DisplayName = face.Profile;
        Head.Bot = face.Bot;
    }

    protected override async void OnNavigatedFrom(NavigationEventArgs e)
    {
        try
        {
            App.Window?.DismissToolTips();
            await DetachAsync(leaving: true);
        }
        catch (Exception ex) { AppLog.Error("chat", ex); }
    }

    private void HookScroller()
    {
        if (_scroller != null) return;
        _scroller = FindChild<ScrollViewer>(Messages);
        if (_scroller != null) _scroller.ViewChanged += OnViewChanged;
    }

    private async void OnViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        try
        {
            if (_scroller == null) return;
            if (!e.IsIntermediate) _stickToEnd = _scroller.VerticalOffset >= _scroller.ScrollableHeight - 60;
            if (!e.IsIntermediate && _stickToEnd) MarkSeen();
            if (_vm == null || _loadingOlder || !_vm.Session.HasOlder) return;
            if (_scroller.VerticalOffset > 400) return;
            _loadingOlder = true;
            try { await _vm.Session.LoadOlderAsync(); }
            catch (GatewayException x) { AppLog.Note("chat", $"older failed: {x.Code}"); }
            finally { _loadingOlder = false; }
        }
        catch (Exception ex) { AppLog.Error("chat", ex); }
    }

    /// [transcript] Landing on unread replies (§4.1): a chat reopened with replies you haven't seen opens at the first of
    /// them, not at the newest end; the newest message you saw at the end is remembered (TurnMarks.swift SeenStore).
    private void LandOrScrollToEnd()
    {
        if (_vm == null) { ScrollToEnd(); return; }
        var items = _vm.Items;
        var chat = $"{_vm.Session.Profile}\u0001{_vm.Session.StoredId}";
        var landing = Hermes.Core.Transcripts.SeenStore.Landing(Seen.MarkFor(chat),
            [.. items.Select(i => i.Id)], [.. items.Select(i => i.Role == Hermes.Core.Model.Role.Assistant)]);
        if (landing.Unseen && landing.FirstIndex < items.Count)
        {
            _stickToEnd = false;
            Messages.ScrollIntoView(items[landing.FirstIndex], ScrollIntoViewAlignment.Leading);
        }
        else ScrollToEnd();
    }

    /// What was last seen of each chat, kept across launches.
    private static readonly Hermes.Core.Transcripts.SeenStore Seen = new(
        LoadSeen(), entries => Features.Transcript.FilePreferences.Shared.Set(Hermes.Core.Transcripts.SeenStore.StorageKey,
            System.Text.Json.JsonSerializer.Serialize(entries.Select(e => new[] { e.Chat, e.Mark.NewestId, e.Mark.Count.ToString() }))));

    private static IEnumerable<Hermes.Core.Transcripts.SeenEntry> LoadSeen()
    {
        try
        {
            var raw = Features.Transcript.FilePreferences.Shared.Get(Hermes.Core.Transcripts.SeenStore.StorageKey);
            var rows = raw == null ? null : System.Text.Json.JsonSerializer.Deserialize<string[][]>(raw);
            return rows?.Where(r => r.Length == 3).Select(r => new Hermes.Core.Transcripts.SeenEntry(r[0],
                new Hermes.Core.Transcripts.SeenMark(r[1], int.TryParse(r[2], out var n) ? n : 0, DateTimeOffset.Now))).ToList() ?? [];
        }
        catch (System.Text.Json.JsonException) { return []; }
    }

    /// At the newest end: the reader has seen everything up to the last message.
    private void MarkSeen()
    {
        if (_vm is not { Items.Count: > 0 } vm) return;
        Seen.Mark($"{vm.Session.Profile}\u0001{vm.Session.StoredId}", vm.Items[^1].Id, vm.Items.Count);
    }

    /// Lands on the newest message. A virtualized list only knows its full height after it has measured the last
    /// items, so this scrolls the last item into view and then to the very end, over a few layout passes.
    private async void ScrollToEnd()
    {
        try
        {
            if (_vm is not { Items.Count: > 0 } vm) return;
            _stickToEnd = true;
            for (var pass = 0; pass < 4; pass++)
            {
                if (AppShutdown.Stopping || _vm != vm || !_stickToEnd || vm.Items.Count == 0) return;
                Messages.ScrollIntoView(vm.Items[^1], ScrollIntoViewAlignment.Leading);
                Messages.UpdateLayout();
                HookScroller();
                _scroller?.ChangeView(null, _scroller.ScrollableHeight, null, disableAnimation: true);
                await Task.Delay(40);
                if (AppShutdown.Stopping || _vm != vm || !_stickToEnd) return;
                if (_scroller != null && _scroller.VerticalOffset >= _scroller.ScrollableHeight - 2) break;
            }
        }
        catch (Exception ex) { AppLog.Error("chat", ex); }
    }

    private void Composer_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_context is { } ctx)
            foreach (var hook in ctx.ComposerKeys)
                if (hook(e)) { e.Handled = true; return; }
        if (e.Key == VirtualKey.Enter)
        {
            var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
            if (shift) return; // a new line
            e.Handled = true;
            if (_vm?.Busy != true || _context?.SendHandler != null) Send();
        }
        else if (e.Key == VirtualKey.Escape && _vm?.Busy == true)
        {
            e.Handled = true;
            _ = _vm.Session.StopAsync();
        }
    }

    private void Composer_TextChanged(object sender, TextChangedEventArgs e) => UpdateComposer();

    private void Send_Click(object sender, RoutedEventArgs e)
    {
        var hasDraft = Composer.Text.Trim().Length > 0 || _context?.HasDraftContent.Any(has => has()) == true;
        if (_vm?.Busy == true && (_context?.SendHandler == null || !hasDraft)) _ = _vm.Session.StopAsync();
        else Send();
    }

    private void Send()
    {
        if (_vm == null) return;
        if (!CanSend())
        {
            if (Composer.Text.Trim().Length == 0 && _context?.SendHandler is { } emptyHandler)
                emptyHandler(Composer.Text);
            return;
        }
        var typed = Composer.Text;
        // [chat actions] Edit's strip takes the next send as the edit (clear box first so SendEdit/Cancel can restore draft or failed edit).
        if (_sendOverride != null && typed.Trim().Length > 0)
        {
            Composer.Text = "";
            if (TakeEditSend(typed))
            {
                _stickToEnd = true;
                return;
            }
            Composer.Text = typed;
        }
        // Active Talk sessions can intercept typed stop phrases ("stop") even without a draft/attachment.
        if (_context != null && Features.Voice.TalkFeature.InterceptTypedSend(_context, typed))
        {
            Composer.Text = "";
            _stickToEnd = true;
            return;
        }
        // Photos and files in the tray go with the words (Features/Attachments); the composer's queue and steering
        // take every other send (Features/Composer). Either clears the box when it takes the send.
        var taken = _context?.HasDraftContent.Any(has => has()) == true && _context.SendHandlers.Any(take => take(typed));
        if (!taken && _context?.SendHandler is { } handler)
        {
            if (!handler(typed)) return;
            taken = true;
        }
        if (taken)
        {
            Composer.Text = "";
            LoadProblem.Visibility = Visibility.Collapsed;
            _stickToEnd = true;
            ScrollToEnd();
            return;
        }
        var text = Composer.Text;
        Composer.Text = "";
        LoadProblem.Visibility = Visibility.Collapsed;
        _stickToEnd = true;
        if (_context?.SendHandlers.Any(take => take(text)) != true) _ = _vm.Session.SendAsync(text);
        ScrollToEnd();
    }

    private void UpdateComposer()
    {
        var busy = _vm?.Busy == true;
        var hasDraft = Composer.Text.Trim().Length > 0 || _context?.HasDraftContent.Any(has => has()) == true;
        // [composer] While a reply runs, typed words or attachments go into it (Send); an empty box offers Stop.
        var stop = busy && (_context?.SendHandler == null || !hasDraft);
        SendGlyph.Glyph = stop ? "\uE71A" : "\uE74A"; // Stop : Send (an up arrow, as the Mac's)
        ToolTipService.SetToolTip(SendButton, stop ? "Stop (Esc)" : "Send (Enter)");
        // [WIN-55] ComposerView.swift: `case .stop: accessibilityLabel = "Stop"`, `case .send, .disabled: … "Send"`.
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(SendButton, stop ? "Stop" : "Send");
        SendButton.IsEnabled = busy || CanSend();
        StatusText.Text = _statusOverride ?? _vm?.Status ?? (busy ? "Replying…" : "");
        StatusText.Foreground = ThemeBrushes.Get(_statusOverride != null
            ? "SystemFillColorCautionBrush" : "TextFillColorSecondaryBrush");
    }

    /// Typed words or a feature's draft (attachments), and nothing holding Send back (a photo still being prepared).
    private bool CanSend() =>
        (Composer.Text.Trim().Length > 0 || _context?.HasDraftContent.Any(has => has()) == true)
        && _context?.HoldsSend.Any(holds => holds()) != true;

    /// The inspector is open beside the chat (Help › Keyboard Shortcuts names Ctrl+I "Hide Inspector" then).
    internal bool InspectorShown => InspectorColumn.Width.Value > 0;

    private void ShowInspector(bool show)
    {
        InspectorColumn.Width = show ? new GridLength(300) : new GridLength(0);
        InspectorToggle.IsChecked = show;
        if (show && Inspector.Content is FrameworkElement) _context?.RaiseTranscriptChanged();
    }

    private void InspectorToggle_Click(object sender, RoutedEventArgs e) => ShowInspector(InspectorToggle.IsChecked == true);

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
}
