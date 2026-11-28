using Hermes.Core;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using HermesHQ.Features.Bots;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Threads;

/// [threads] Session Threads feature (ready for 1-line `ThreadsFeature.Register()` in `FeatureRegistry.cs`):
/// wires `ThreadStore` per signed-in account, renders inline thread cards in `ctx.TranscriptFooter`,
/// displays the proactive busy-thread banner in `ctx.Shelf`, intercepts proactive busy sends, and adds
/// "Reply in Thread" to the chat's ⋯ menu.
public static class ThreadsFeature
{
    private static bool _registered;
    private static ThreadStore? _store;
    private static string? _accountId;

    /// The active account's `ThreadStore`, or null when signed out.
    public static ThreadStore? CurrentStore => EnsureStore(AppState.Client);

    public static void Register()
    {
        if (_registered) return;
        _registered = true;
        AppState.ClientChanged += OnClientChanged;
        ChatExtensions.OnOpen.Add(Attach);
    }

    private static void OnClientChanged(HermesClient? client)
    {
        if (client == null || client.AccountId != _accountId)
        {
            _store?.Reset();
            _store = null;
            _accountId = null;
        }
        if (client != null) EnsureStore(client);
    }

    private static ThreadStore? EnsureStore(HermesClient? client)
    {
        if (client == null) return null;
        if (_store != null && _accountId == client.AccountId)
        {
            _store.Client = client;
            return _store;
        }
        _store?.Reset();
        var disk = new FileDeviceStore(Path.Combine(AppPaths.Root, "lists"));
        _store = new ThreadStore(client.AccountId, disk) { Client = client };
        _accountId = client.AccountId;
        return _store;
    }

    private static void Attach(ChatContext ctx)
    {
        var store = EnsureStore(AppState.Client);
        if (store == null) return;

        var session = ctx.Session;
        if (session.IsThread || store.IsThreadSession(session.StoredId, session.Profile))
        {
            session.IsThread = true;
            session.DisableThreads();
            return;
        }

        var ui = DispatcherQueue.GetForCurrentThread();
        session.IsBotChat = ctx.IsBotChat;
        session.Observing = true;
        store.WireParent(session);

        var bannerHost = new ContentControl
        {
            IsTabStop = false,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Visibility = Visibility.Collapsed,
        };
        var noticeBar = new Border
        {
            Padding = new Thickness(10, 6, 10, 6),
            CornerRadius = new CornerRadius(8),
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
            Margin = new Thickness(0, 0, 0, 6),
            Visibility = Visibility.Collapsed,
        };
        var noticeLabel = new TextBlock
        {
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            TextWrapping = TextWrapping.Wrap,
        };
        noticeBar.Child = noticeLabel;
        AutomationProperties.SetAutomationId(noticeBar, "chat.thread.notice");

        var cardsHost = new StackPanel { Spacing = 4, Margin = new Thickness(0, 6, 0, 4) };
        AutomationProperties.SetAutomationId(cardsHost, "chat.threads.footer");

        ctx.Shelf.Children.Insert(0, noticeBar);
        ctx.Shelf.Children.Insert(0, bannerHost);
        ctx.TranscriptFooter.Children.Add(cardsHost);

        CancellationTokenSource? noticeCts = null;
        void ShowNotice(string text)
        {
            ui.TryEnqueue(() =>
            {
                noticeCts?.Cancel();
                noticeCts?.Dispose();
                noticeCts = new CancellationTokenSource();
                var token = noticeCts.Token;
                noticeLabel.Text = text;
                noticeBar.Visibility = Visibility.Visible;
                _ = Task.Run(async () =>
                {
                    try
                    {
                        await Task.Delay(4500, token);
                        if (!token.IsCancellationRequested)
                            ui.TryEnqueue(() => noticeBar.Visibility = Visibility.Collapsed);
                    }
                    catch (OperationCanceledException) { }
                });
            });
        }
        session.OnNotice = ShowNotice;

        void OpenThreadKey(string key)
        {
            var threadSession = store.GetOrOpenSession(key);
            if (threadSession == null) return;
            var title = store.Name(key) ?? ThreadRules.DefaultTitle;
            _ = ThreadWindow.ShowAsync(ctx.Page.XamlRoot, threadSession, title, RefreshUi);
        }

        void RefreshUi()
        {
            // Banner
            var banner = store.BusyBanner(session, session.EffectiveBotName);
            if (banner != null)
            {
                bannerHost.Content = ThreadWindow.BuildBusyBanner(
                    banner,
                    onUseMain: () => store.OptOutBusyRouting(session),
                    onOpenThread: OpenThreadKey);
                bannerHost.Visibility = Visibility.Visible;
            }
            else
            {
                bannerHost.Content = null;
                bannerHost.Visibility = Visibility.Collapsed;
            }

            // Inline thread cards
            UiTree.ClearPanel(cardsHost);
            var canonical = ListsHub.Current?.Bots.Bot(session.Profile)?.OpenId;
            var parentIds = ThreadStore.ParentIds(session, canonical);
            var threads = store.Threads(session.Profile, parentIds, session.IsBotChat);
            var messages = session.Messages;
            var anchored = ThreadRules.ByAnchor(threads, messages);
            var unanchored = ThreadRules.Unanchored(threads, messages);

            foreach (var (idx, group) in anchored.OrderBy(kv => kv.Key))
            {
                foreach (var t in group)
                {
                    var open = ThreadRules.IsOpen(t, idx, messages);
                    cardsHost.Children.Add(ThreadCardView.Build(t, open, chosen => OpenThreadKey(chosen.Id)));
                }
            }
            foreach (var t in unanchored)
                cardsHost.Children.Add(ThreadCardView.Build(t, isOpen: true, chosen => OpenThreadKey(chosen.Id)));

            cardsHost.Visibility = cardsHost.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        void OnStoreChanged(string profile)
        {
            if (profile == session.Profile) ui.TryEnqueue(RefreshUi);
        }

        void OnSessionChanged() => ui.TryEnqueue(RefreshUi);

        // Proactive busy-chat send routing through `SendHandlers`.
        bool HandleProactiveBusySend(string text)
        {
            var trimmed = text.Trim();
            if (trimmed.Length == 0 || !store.ShouldRouteToBusyThread(session)) return false;
            _ = session.SendWithThreadRoutingAsync(trimmed);
            return true;
        }
        ctx.SendHandlers.Add(HandleProactiveBusySend);

        // "Reply in Thread" in the chat's ⋯ menu.
        var startItem = new MenuFlyoutItem
        {
            Text = "Reply in Thread",
            Icon = new FontIcon { Glyph = "\uE8BD" },
        };
        AutomationProperties.SetAutomationId(startItem, "chat.more.replyInThread");
        startItem.Click += async (_, _) =>
        {
            var box = new TextBox { PlaceholderText = "Start a side thread…" };
            var dialog = new ContentDialog
            {
                Title = "Reply in Thread",
                Content = box,
                PrimaryButtonText = "Send",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await SafeDialog.ShowAsync(ctx.Page.XamlRoot, dialog) != ContentDialogResult.Primary) return;
            var prompt = box.Text.Trim();
            if (prompt.Length == 0) return;
            var anchor = ThreadRules.ComposerAnchor(session.Messages, session.Busy);
            var key = await store.StartAsync(prompt, session, anchor);
            RefreshUi();
            if (key != null) OpenThreadKey(key);
        };
        ctx.MoreMenu.Items.Add(startItem);

        store.Changed += OnStoreChanged;
        session.Changed += OnSessionChanged;
        RefreshUi();

        ctx.Closed += () =>
        {
            store.Changed -= OnStoreChanged;
            session.Changed -= OnSessionChanged;
            session.OnNotice = null;
            session.Observing = false;
            ctx.SendHandlers.Remove(HandleProactiveBusySend);
            ctx.MoreMenu.Items.Remove(startItem);
            ctx.Shelf.Children.Remove(bannerHost);
            ctx.Shelf.Children.Remove(noticeBar);
            UiTree.ClearPanel(cardsHost);
            ctx.TranscriptFooter.Children.Remove(cardsHost);
            noticeCts?.Cancel();
            noticeCts?.Dispose();
        };
    }
}
