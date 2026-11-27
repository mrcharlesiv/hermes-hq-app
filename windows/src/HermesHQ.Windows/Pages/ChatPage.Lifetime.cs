using System.ComponentModel;
using Hermes.Core.Chat;
using Hermes.Core.Net;
using HermesHQ.Services;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace HermesHQ.Pages;

public sealed partial class ChatPage
{
    /// `Draft`: the message box's words as the chat opens (`/new <words>`). `BotChat`: the bot's own chat (its face
    /// shows in the header; a session's title has none, Hermes.Core.Chat.ChatHeaderFace).
    public sealed record Args(string Profile, string StoredId, string Title, string Draft = "", bool BotChat = false);

    private ChatContext? _context;
    private ChatViewModel? _vm;
    private string? _botChatProfile; // the bot whose own chat is opening (the list's “Waking up…” row)

    /// The chat on screen, also used by the walk and the shutdown coordinator.
    public static ChatPage? Current { get; private set; }

    // UI-thread ownership. A reused page with the same stored chat ID is still a different opening.
    private bool Owns(ChatContext opening) => ReferenceEquals(_context, opening);

    private void AttachOpening(ChatContext opening, ChatViewModel vm, Args args)
    {
        _context = opening;
        _vm = vm;
        _botChatProfile = args.BotChat ? args.Profile : null;
        Current = this;
        var ui = DispatcherQueue;
        var session = vm.Session;
        void TitleChanged(string title) => ui.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || !Owns(opening)) return;
            ChatTitle = title;
            TitleText.Text = title.ToUpperInvariant();
            _composerFit.SetTitle(title);
        });
        // Try Again succeeded. Removing the subscription can't recall work already in the UI queue.
        void Recovered() => ui.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || !Owns(opening)) return;
            LoadProblem.Visibility = Visibility.Collapsed;
            LoadingRing.IsActive = false;
            opening.SetPhase(ChatOpenPhase.Open);
            if (Owns(opening)) UpdateComposer();
        });
        void PropertyChanged(object? sender, PropertyChangedEventArgs e) { if (!AppShutdown.Stopping && Owns(opening)) UpdateComposer(); }
        void RowsChanged()
        {
            if (AppShutdown.Stopping || !Owns(opening)) return;
            LoadingRing.IsActive = false;
            opening.RaiseTranscriptChanged(); // the first message replaces the empty-chat intro
            if (Owns(opening) && _stickToEnd) ui.TryEnqueue(DispatcherQueuePriority.Low, () => { if (!AppShutdown.Stopping && Owns(opening)) ScrollToEnd(); });
        }
        session.TitleChanged += TitleChanged;
        session.OpenRecovered += Recovered;
        vm.PropertyChanged += PropertyChanged;
        vm.ItemsChanged += RowsChanged;
        opening.Closed += () =>
        {
            session.TitleChanged -= TitleChanged;
            session.OpenRecovered -= Recovered;
            vm.PropertyChanged -= PropertyChanged;
            vm.ItemsChanged -= RowsChanged;
        };
    }

    private async Task FinishOpeningAsync(ChatContext opening, ChatViewModel vm, Args args)
    {
        GatewayException? refusal = null;
        try { await vm.Session.OpenAsync(); }
        catch (GatewayException x) { refusal = x; } // only the gateway open, not UI callbacks or application exit

        if (!Owns(opening)) return;
        LoadingRing.IsActive = false;
        opening.SetPhase(refusal == null ? ChatOpenPhase.Open : ChatOpenPhase.Failed);
        if (!Owns(opening)) return; // a phase observer may leave the chat synchronously
        if (refusal == null) LandOrScrollToEnd();
        else
        {
            if (vm.Items.Count == 0)
            {
                LoadProblem.Text = refusal.Status == 404 ? "This chat isn't on the gateway anymore." : $"Couldn't load this chat. {refusal.Message}";
                LoadProblem.Visibility = Visibility.Visible;
            }
            AppLog.Note("chat", $"open failed: {refusal.Code} {refusal.Status}");
        }
        // [botslist] The open settled, bound or failed: the bot's row stops saying "Waking up…" (AppModel.chatOpened).
        if (Owns(opening) && args.BotChat) HermesHQ.Features.Bots.ListsHub.Current?.Bots.NoteBotOpening(args.Profile, false);
        if (Owns(opening)) UpdateComposer();
    }

    /// The open chat's feature callbacks and view model stop before the gateway socket closes.
    internal Task EndForQuitAsync() => DetachAsync(leaving: false);

    // Like ChatViewController.detach at d60cdb0ca: invalidate ownership before notifying anyone or awaiting disposal.
    private async Task DetachAsync(bool leaving)
    {
        if (Current == this) Current = null;
        if (leaving) LoadingRing.IsActive = false;
        StopActionsForClose();
        var context = _context;
        _context = null;
        var vm = _vm;
        _vm = null;
        var waking = _botChatProfile;
        _botChatProfile = null;
        try
        {
            // AppModel.chatLeft: navigation ends the bot row's wait. A quit needs no list repaint.
            if (leaving && waking != null) HermesHQ.Features.Bots.ListsHub.Current?.Bots.NoteBotOpening(waking, false);
        }
        finally
        {
            try { context?.Close(); }
            finally { if (vm != null) await vm.DisposeAsync(); }
        }
    }
}