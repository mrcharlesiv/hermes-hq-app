// Watch Browser feature registration and entrypoints (C# twin of App/Browser/AppModel+Browser.swift, matching
// Features/Screen/ScreenFeature.cs): owns the signed-in account's BrowserService and DPAPI-protected BrowserLastPages,
// wires ChatExtensions.OnOpen (shelf BrowserChatCard + ⋯ menu "Watch Browser"), provides Bots menu MenuItem(BotRow),
// viewer Open(...), BrowserChoiceDialog, BrowserCloudSettingsDialog, and clean account sign-out / quit shutdown.

using System.Runtime.InteropServices.WindowsRuntime;
using Hermes.Core;
using Hermes.Core.Bots;
using Hermes.Core.Browser;
using Hermes.Core.Capabilities;
using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using Hermes.Core.Rpc;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Capabilities;
using HermesHQ.Features.Composer;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using BotRow = Hermes.Core.Bots.BotRow;

namespace HermesHQ.Features.Browser;

public static class BrowserFeature
{
    private static BrowserService? _service;
    private static string? _serviceAccount;
    private static bool _registered;

    private static readonly IKeyValueStore Prefs = new JsonFileStore(Path.Combine(AppPaths.Root, "browser.json"));
    public static BrowserLastPages LastPages { get; } = new(DpapiLastPageProtector.Folder, new DpapiLastPageProtector());

    /// Registers Watch Browser's chat hooks, fixed SentTitles pairs, and account lifecycle listeners. Call once at app startup.
    public static void Register()
    {
        if (_registered) return;
        _registered = true;

        NoteFixedTitles();
        AppState.ClientChanged += OnClientChanged;
        ChatExtensions.OnOpen.Add(HookChat);
    }

    /// The signed-in account's BrowserService, created lazily on the UI thread and shut down on account switch/sign-out.
    public static BrowserService? Service
    {
        get
        {
            var client = AppState.Client;
            if (client == null) { Drop(); return null; }
            if (_service != null && _serviceAccount == client.AccountId) return _service;
            Drop();
            var ui = DispatcherQueue.GetForCurrentThread();
            var service = BrowserService.For(client, Prefs, LastPages, WicBrowserImageDecoder.Instance);
            service.PostToMain = action =>
            {
                if (AppShutdown.Stopping) return;
                if (ui == null || ui.HasThreadAccess) action();
                else ui.TryEnqueue(() => { if (!AppShutdown.Stopping) action(); });
            };
            service.Note = line => AppLog.Note("browser", line);
            _service = service;
            _serviceAccount = client.AccountId;
            return _service;
        }
    }

    /// Bot context menu item ("Watch Browser"), matching ScreenFeature.MenuItem(BotRow).
    public static MenuFlyoutItem? MenuItem(BotRow bot)
    {
        if (Service == null) return null;
        var item = new MenuFlyoutItem
        {
            Text = "Watch Browser",
            Icon = new FontIcon { Glyph = "\uE774" },
        };
        AutomationProperties.SetAutomationId(item, "bot-menu.browser");
        item.Click += (_, _) => Open(bot.Id, bot.Name);
        return item;
    }

    /// Bot Info › Browser settings menu item.
    public static MenuFlyoutItem? ChoiceMenuItem(BotRow bot, Func<XamlRoot?> xamlRoot)
    {
        if (Service == null) return null;
        var item = new MenuFlyoutItem
        {
            Text = "Browser Profile & Cloud…",
            Icon = new FontIcon { Glyph = "\uE713" },
        };
        AutomationProperties.SetAutomationId(item, "bot-menu.browserChoice");
        item.Click += (_, _) =>
        {
            if (xamlRoot() is { } root) _ = ShowChoiceDialogAsync(bot, root);
        };
        return item;
    }

    /// Opens Watch Browser for a bot by profile and display name.
    public static BrowserViewerPage? Open(string profile, string name)
    {
        if (Service is not { } service) return null;
        var bot = ListsHub.Current?.Bots.Bot(profile);
        var ownChats = new List<string>();
        if (!string.IsNullOrEmpty(bot?.OpenId)) ownChats.Add(bot.OpenId);
        if (!string.IsNullOrEmpty(bot?.RegistryId) && !ownChats.Contains(bot.RegistryId, StringComparer.Ordinal)) ownChats.Add(bot.RegistryId);
        var scope = new BrowserScope(profile, name, ownChats: ownChats);
        return Open(scope, service);
    }

    /// Opens Watch Browser for a specific scope (e.g. a chat session or bot).
    public static BrowserViewerPage? Open(BrowserScope scope)
    {
        if (Service is not { } service) return null;
        return Open(scope, service);
    }

    /// Opens Watch Browser over any BrowserService (also usable by tests / walks).
    public static BrowserViewerPage? Open(
        BrowserScope scope,
        BrowserService service,
        Action<BrowserViewerController>? configure = null)
    {
        var decision = BrowserViewerController.CheckReopen(scope.Profile, ownWindow: true);
        if (decision == BrowserViewerReopen.Front && BrowserWindow.Showing is { } existing)
        {
            existing.Activate();
            return existing.Page;
        }
        if (decision == BrowserViewerReopen.Replace)
        {
            BrowserWindow.CloseOpen();
        }

        var ui = DispatcherQueue.GetForCurrentThread();
        var page = new BrowserViewerPage();
        var timers = ui != null ? new DispatcherBrowserTimers(ui) : null;
        var viewer = new BrowserViewerController(service, scope, page, timers)
        {
            Helper = MainBotName(),
            CanAsk = EnsureCanAskMainBot,
            AskToInstall = AskMainBotAsync,
            OpenPluginsAction = () => OpenBotPlugins(scope.Profile),
            UpdateAddOnAction = () => OpenBotPlugins(scope.Profile),
        };
        configure?.Invoke(viewer);
        viewer.RegisterCurrent();

        page.OnOpenSettings = () =>
        {
            if (page.XamlRoot is { } root) _ = ShowChoiceDialogAsync(scope.Profile, viewer.Name, root);
        };

        var window = new BrowserWindow(page, viewer);
        page.Attach(viewer);
        window.Activate();
        return page;
    }

    /// Creates the chat shelf card for an open chat context.
    public static BrowserChatCard? CreateChatCard(ChatContext ctx)
    {
        if (Service is not { } service) return null;
        var card = new BrowserChatCard(ctx.Session, service, () => ScopeForChat(ctx.Session))
        {
            OnOpen = scope => Open(scope),
        };
        return card;
    }

    /// Opens Bot Info › Browser (Chrome profile choice, window mode, Browser Use Cloud / Hermes Cloud).
    public static Task ShowChoiceDialogAsync(BotRow bot, XamlRoot root) =>
        ShowChoiceDialogAsync(bot.Id, bot.Name, root);

    public static async Task ShowChoiceDialogAsync(string profile, string name, XamlRoot root)
    {
        if (Service is not { } service) return;
        var model = new BrowserChoiceModel(service, profile, name);
        await BrowserChoiceDialog.ShowAsync(model, root);
    }

    /// Opens Settings › Browser Use Cloud.
    public static async Task ShowCloudSettingsDialogAsync(XamlRoot root)
    {
        var model = new BrowserCloudSettingsModel(Service, setUp: () => Open("default", MainBotName()));
        await BrowserCloudSettingsDialog.ShowAsync(model, root);
    }

    /// Builds embeddable Settings › Browser Use Cloud content for Settings panes.
    public static FrameworkElement BuildCloudSettingsContent()
    {
        var model = new BrowserCloudSettingsModel(Service, setUp: () => Open("default", MainBotName()));
        return BrowserCloudSettingsDialog.BuildContent(model);
    }

    /// Clean account sign-out / purge (closes open windows, shuts down service, purges DPAPI last pages for the account).
    public static void SignedOut(string accountId)
    {
        if (_serviceAccount == accountId) Drop();
        if (!string.IsNullOrEmpty(accountId)) LastPages.Purge(accountId);
    }

    /// Clean app shutdown hook (called from AppShutdown before gateway teardown).
    public static void CloseForQuit()
    {
        AppState.ClientChanged -= OnClientChanged;
        PreviewTabWindow.CloseOpen();
        Drop();
    }

    // ------------------------------------------------------------------ Internal wiring

    private static void OnClientChanged(HermesClient? client)
    {
        NoteFixedTitles();
        if (client == null || _serviceAccount != client.AccountId) Drop();
    }

    private static void NoteFixedTitles()
    {
        SentTitles.Shared.Note(BrowserSetupPrompt.Text, BrowserSetupPrompt.InstallTitle);
        SentTitles.Shared.Note(BrowserSetupPrompt.Update, BrowserSetupPrompt.UpdateTitle);
    }

    private static void Drop()
    {
        BrowserWindow.CloseOpen();
        _service?.Shutdown();
        _service = null;
        _serviceAccount = null;
    }

    private static void HookChat(ChatContext ctx)
    {
        var card = CreateChatCard(ctx);
        if (card != null)
        {
            ctx.Shelf.Children.Insert(0, card);
            ctx.Closed += () =>
            {
                ctx.Shelf.Children.Remove(card);
                card.Dispose();
            };
        }

        // Chat ⋯ menu item: "Watch Browser" (disabled while offline via BrowserMenuRule.ChatItem).
        var item = new MenuFlyoutItem
        {
            Text = "Watch Browser",
            Icon = new FontIcon { Glyph = "\uE774" },
        };
        AutomationProperties.SetAutomationId(item, "chat-menu.browser");
        item.Click += (_, _) => Open(ScopeForChat(ctx.Session));

        void RefreshMenuItem()
        {
            var offline = AppState.Client?.Rpc.State != ConnectionState.Open;
            var spec = BrowserMenuRule.ChatItem(offline);
            item.IsEnabled = !spec.Disabled;
        }

        RefreshMenuItem();
        ctx.MoreMenu.Opening += OnMenuOpening;
        ctx.MoreMenu.Items.Add(item);
        ctx.Closed += () =>
        {
            ctx.MoreMenu.Opening -= OnMenuOpening;
            ctx.MoreMenu.Items.Remove(item);
        };

        void OnMenuOpening(object? sender, object e) => RefreshMenuItem();
    }

    private static BrowserScope ScopeForChat(ChatSession session)
    {
        var bot = ListsHub.Current?.Bots.Bot(session.Profile);
        var title = bot?.Name ?? session.Title;
        var sessionIds = new List<string>();
        if (!string.IsNullOrEmpty(session.StoredId)) sessionIds.Add(session.StoredId);
        if (!string.IsNullOrEmpty(session.RuntimeId) && !sessionIds.Contains(session.RuntimeId, StringComparer.Ordinal))
            sessionIds.Add(session.RuntimeId);

        var isBotOwnChat = bot != null &&
            ((!string.IsNullOrEmpty(bot.OpenId) && bot.OpenId == session.StoredId) ||
             (!string.IsNullOrEmpty(bot.RegistryId) && bot.RegistryId == session.StoredId));

        if (isBotOwnChat && bot != null)
        {
            var ownChats = new List<string>(sessionIds);
            if (!string.IsNullOrEmpty(bot.OpenId) && !ownChats.Contains(bot.OpenId, StringComparer.Ordinal))
                ownChats.Add(bot.OpenId);
            if (!string.IsNullOrEmpty(bot.RegistryId) && !ownChats.Contains(bot.RegistryId, StringComparer.Ordinal))
                ownChats.Add(bot.RegistryId);
            return new BrowserScope(session.Profile, title, ownChats: ownChats);
        }
        return new BrowserScope(session.Profile, title, sessionIds: sessionIds, chatOnly: true);
    }

    private static string MainBotName() =>
        ListsHub.Current?.Bots.Bot("default")?.Name
        ?? AppState.Client?.Bots?.FirstOrDefault(b => b.Name == "default")?.DisplayName
        ?? "Hermes";

    private static void EnsureCanAskMainBot()
    {
        var client = AppState.Client;
        if (client == null || client.Rpc.State != ConnectionState.Open)
            throw new InvalidOperationException(BrowserSetupPrompt.CouldNotSend);
        if (FindMainBot() == null)
            throw new InvalidOperationException(BrowserSetupPrompt.CouldNotSend);
    }

    private static Bot? FindMainBot() =>
        ListsHub.Current?.Bots.Bot("default")?.Model
        ?? AppState.Client?.Bots?.FirstOrDefault(b => b.Name == "default");

    private static async Task AskMainBotAsync(string prompt)
    {
        var client = AppState.Client ?? throw new InvalidOperationException(BrowserSetupPrompt.CouldNotSend);
        var mainBot = FindMainBot() ?? throw new InvalidOperationException(BrowserSetupPrompt.CouldNotSend);
        var displayTitle = prompt == BrowserSetupPrompt.Update
            ? BrowserSetupPrompt.UpdateTitle
            : BrowserSetupPrompt.InstallTitle;

        SentTitles.Shared.Note(prompt, displayTitle);

        // Navigate to the main bot's chat on the UI thread and capture the BotStore reference there.
        BotStore? bots = null;
        var ui = App.Window?.DispatcherQueue;
        if (ui != null)
        {
            var navDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            ui.TryEnqueue(() =>
            {
                try
                {
                    bots = ListsHub.Current?.Bots;
                    App.Window?.Activate();
                    Navigator.Go(new BotChatDestination(mainBot));
                }
                finally { navDone.TrySetResult(); }
            });
            await navDone.Task.ConfigureAwait(false);
        }

        // Wait briefly for the main bot's ChatPage to attach so we send through its live session.
        ChatSession? liveSession = null;
        for (var i = 0; i < 20 && liveSession == null; i++)
        {
            if (ui != null)
            {
                var check = new TaskCompletionSource<ChatSession?>(TaskCreationOptions.RunContinuationsAsynchronously);
                ui.TryEnqueue(() =>
                {
                    var page = ChatPage.Current;
                    var composer = page != null ? ComposerController.For(page) : null;
                    check.TrySetResult(composer?.Composer.Session.Profile == "default" ? composer.Composer.Session : null);
                });
                liveSession = await check.Task.ConfigureAwait(false);
            }
            if (liveSession == null) await Task.Delay(100).ConfigureAwait(false);
        }

        if (liveSession != null)
        {
            var outcome = await liveSession.SendAsync(prompt, queued: liveSession.Busy, display: displayTitle).ConfigureAwait(false);
            if (outcome == SendOutcome.Refused || outcome == SendOutcome.NotSent)
                throw new InvalidOperationException(BrowserSetupPrompt.CouldNotSend);
            return;
        }

        // Fallback: open the default bot's chat directly if ChatPage didn't attach in time.
        if (bots == null) throw new InvalidOperationException(BrowserSetupPrompt.CouldNotSend);
        var storedId = await bots.BotChatIdAsync("default").ConfigureAwait(false);
        await using var session = client.OpenChat("default", storedId, mainBot.DisplayName);
        var result = await session.SendAsync(prompt, display: displayTitle).ConfigureAwait(false);
        if (result == SendOutcome.Refused || result == SendOutcome.NotSent)
            throw new InvalidOperationException(BrowserSetupPrompt.CouldNotSend);
    }

    private static void OpenBotPlugins(string profile)
    {
        App.Window?.Activate();
        var bot = ListsHub.Current?.Bots.Bot(profile)?.Model
            ?? AppState.Client?.Bots?.FirstOrDefault(b => b.Name == profile);
        if (bot != null) CapabilitiesFeature.OpenForBot(bot, CapabilitiesTab.Plugins);
        else Navigator.Open("capabilities", new CapabilitiesTarget(Tab: CapabilitiesTab.Plugins, Profile: profile));
    }
}

/// UI-thread timers for BrowserViewerController & BrowserStageState over DispatcherQueueTimer.
internal sealed class DispatcherBrowserTimers(DispatcherQueue queue) : IBrowserTimers
{
    public IDisposable Schedule(TimeSpan after, bool repeats, Action fire)
    {
        var timer = queue.CreateTimer();
        timer.Interval = after < TimeSpan.Zero ? TimeSpan.Zero : after;
        timer.IsRepeating = repeats;
        timer.Tick += (t, _) =>
        {
            if (!repeats) t.Stop();
            fire();
        };
        timer.Start();
        return new Stop(timer.Stop);
    }

    private sealed class Stop(Action stop) : IDisposable
    {
        private bool _done;
        public void Dispose() { if (_done) return; _done = true; stop(); }
    }
}

/// Off-UI-thread WIC JPEG decoder (supports both baseline and progressive JPEGs), with pure-managed fallback.
internal sealed class WicBrowserImageDecoder : IBrowserImageDecoder
{
    public static readonly WicBrowserImageDecoder Instance = new();

    public BrowserDecodedImage? Decode(byte[] jpeg)
    {
        if (jpeg.Length < 4) return null;
        try
        {
            return DecodeWicAsync(jpeg).GetAwaiter().GetResult();
        }
        catch (Exception)
        {
            return ManagedBrowserImageDecoder.Instance.Decode(jpeg);
        }
    }

    private static async Task<BrowserDecodedImage?> DecodeWicAsync(byte[] jpeg)
    {
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(jpeg.AsBuffer()).AsTask().ConfigureAwait(false);
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask().ConfigureAwait(false);
        var width = (int)decoder.PixelWidth;
        var height = (int)decoder.PixelHeight;
        if (width <= 0 || height <= 0) return null;
        var pixelData = await decoder.GetPixelDataAsync(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Ignore,
            new BitmapTransform(),
            ExifOrientationMode.IgnoreExifOrientation,
            ColorManagementMode.DoNotColorManage).AsTask().ConfigureAwait(false);
        var pixels = pixelData.DetachPixelData();
        for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 0xFF;
        return new BrowserDecodedImage(width, height, pixels);
    }
}
