using Hermes.Core;
using Hermes.Core.Gateways;
using Hermes.Core.Rpc;
using Hermes.Core.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace HermesHQ.Features.Settings;

/// Settings and themes (PARITY "Settings (Settings, Theme)"): the Settings place (the Mac's Settings window in two
/// columns), the app's palette and Light or Dark (ThemeService), UI Scale and its keys, the completion sound when a reply
/// finishes, Default Project Folder's gateway, and Diagnostics' recent errors.
public static class SettingsFeature
{
    public static void Register()
    {
        Places.Register("settings", typeof(SettingsPage));
        // [mac-layout] Ctrl+, the sidebar's gear and Sidebar Settings… open Settings in a window of its own
        // (MacSettingsWindow); signed out, it closes (AppDelegate's sign-out: Settings has no gateway to show).
        SettingsWindows.Open = SettingsWindow.Open;
        AppState.ClientChanged += CloseSettingsWhenSignedOut;
        ChatPrefs.Store = FilePreferences.Shared;
        Hermes.Core.Chat.ChatIntro.Store = FilePreferences.Shared;   // [WIN-CHAT-INTRO] Greeting on Empty Chats
        DefaultProjectFolder.Store = FilePreferences.Shared;
        ThemeService.Install();
        AppLog.Noted += ErrorLog.Note;
        // Settings › About › Detailed Logging: request lines go to the app log; the launch line says whether it is whole.
        AppLog.Note("launch", DetailedLogging.Start(FilePreferences.Shared, AppLog.Note));
        AppState.ClientChanged += OnClient;
        Automation.Walks.Add(WalkAsync);
        // Once the window is up (OnLaunched makes it right after the features register).
        DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || App.Window is not { } w) return;
            ThemeService.Attach(w);
            w.Closed += (_, _) => { if (!AppShutdown.Stopping) SettingsWindow.CloseOpen(); };   // it sits beside the main window, never alone
            w.Activated += (_, e) => { if (!AppShutdown.Stopping) _active = e.WindowActivationState != WindowActivationState.Deactivated; };
            OnClient(AppState.Client);
        });
    }

    private static void CloseSettingsWhenSignedOut(HermesClient? c)
    {
        if (c == null && !AppShutdown.Stopping)
            App.Window?.DispatcherQueue.TryEnqueue(() => { if (!AppShutdown.Stopping) SettingsWindow.CloseOpen(); });
    }

    internal static void StopForQuit()
    {
        AppState.ClientChanged -= CloseSettingsWhenSignedOut;
        AppState.ClientChanged -= OnClient;
        if (_client != null)
        {
            _client.Rpc.Event -= OnEvent;
            _client.Rpc.StateChanged -= OnState;
            _client = null;
        }
    }

    /// The CI's pictures of Settings (Services/Automation.cs): each page, then the themes at work, then back as it was.
    private static async Task WalkAsync(Func<string, Task> shot)
    {
        foreach (var (arg, name) in new[]
                 {
                     ("row:appearance", "appearance"), ("theme", "theme"), ("tool-calls", "tool-calls"), ("row:completion-sound", "sounds"),
                     ("notifications", "notifications"), ("voice", "voice"), ("sessions", "project-folder"), ("about", "about"),
                     ("diagnostics", "diagnostics"), ("gateway", "gateway"),
                 })
        {
            Navigator.Open("settings", arg);
            await Task.Delay(1200);
            await shot("settings-" + name);
        }
        var before = ThemeService.State;
        var chosen = ThemeService.Chosen;
        try
        {
            ThemeService.SetAppearance(AppearanceSetting.Dark);
            ThemeService.PickSkin("rose-pine");
            Navigator.Open("settings", "theme");
            await Task.Delay(1200);
            await shot("settings-theme-rose-pine-dark");
            ThemeService.SetDesktopLook(true);
            ThemeService.PickSkin("midnight");
            ThemeService.SetUiScale(125);
            Navigator.Open("settings", "row:ui-scale");
            await Task.Delay(1200);
            await shot("settings-midnight-desktop-look-125");
            ThemeService.SetAppearance(AppearanceSetting.Light);
            ThemeService.PickSkin("paper");
            ThemeService.SetUiScale(90);
            Navigator.Open("sessions");
            await Task.Delay(1500);
            await shot("settings-paper-light-90-sessions");
        }
        finally
        {
            ThemeService.SetUiScale(before.UiScalePercent);
            ThemeService.SetDesktopLook(before.DesktopLook);
            ThemeService.PickSkin(before.SkinId);
            ThemeService.SetAppearance(chosen);
        }
    }

    public static string AppVersion => typeof(App).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "1.0";

    // ---------------------------------------------------------------- the gateway in use (the card, About, the Gateway page)

    public sealed record GatewayInfo(string Name, string Host, GatewayConnection State, int Bots, string? Version);

    private static readonly object Gate = new();
    private static string? _versionAccount;
    private static string? _version;
    private static DateTimeOffset _versionReadAt;
    private static HermesClient? _client;
    private static bool _wasOpen;

    public static GatewayInfo Gateway()
    {
        if (AppState.Client is not { } c) return new GatewayInfo("Not Signed In", "", GatewayConnection.SignedOut, 0, null);
        var title = AppState.Gateways.CurrentTitle;
        var host = GatewayNaming.Host(c.Session.Address.Base, port: true);
        if (title.Length == 0) title = host;
        string? version;
        lock (Gate) version = _versionAccount == c.AccountId ? _version : null;
        return new GatewayInfo(title, host, Connection(c.Rpc.State), c.Bots?.Count ?? 0, version);
    }

    private static GatewayConnection Connection(ConnectionState s) => s switch
    {
        ConnectionState.Open => GatewayConnection.Ready,
        ConnectionState.Connecting => _wasOpen ? GatewayConnection.Reconnecting : GatewayConnection.Connecting,
        ConnectionState.Offline => GatewayConnection.Offline,
        _ => GatewayConnection.SignedOut,
    };

    /// Reads the gateway's Hermes version from /api/status (at most once a minute), then calls `done`.
    public static void RefreshVersion(Action done)
    {
        if (AppState.Client is not { } c) return;
        lock (Gate)
            if (_versionAccount == c.AccountId && DateTimeOffset.UtcNow - _versionReadAt < TimeSpan.FromSeconds(60)) return;
        _ = Task.Run(async () =>
        {
            try
            {
                var status = await c.Session.GetJsonAsync("/api/status", timeout: TimeSpan.FromSeconds(10));
                lock (Gate)
                {
                    _versionAccount = c.AccountId;
                    _version = SettingsWords.Version(status);
                    _versionReadAt = DateTimeOffset.UtcNow;
                }
                done();
            }
            catch (Exception x) when (x is global::Hermes.Core.Net.GatewayException or HttpRequestException or OperationCanceledException)
            {
                AppLog.Note("settings", $"version read failed: {x.GetType().Name}");
            }
        });
    }

    private static void OnClient(HermesClient? client)
    {
        if (_client != null)
        {
            _client.Rpc.Event -= OnEvent;
            _client.Rpc.StateChanged -= OnState;
        }
        _client = client;
        _wasOpen = false;
        DefaultProjectFolder.ActiveAccount = client?.AccountId;
        if (client == null) return;
        client.Rpc.Event += OnEvent;
        client.Rpc.StateChanged += OnState;
    }

    private static void OnState(ConnectionState s)
    {
        if (s == ConnectionState.Open) _wasOpen = true;
    }

    // ---------------------------------------------------------------- the completion sound

    private static volatile bool _active = true;
    private static readonly CompletionCueGate CueGate = new();

    /// Every live `message.complete` while the app is in front (CompletionCue.turnEnded).
    private static void OnEvent(RpcEvent e)
    {
        if (e.Type != "message.complete" || !_active || AppShutdown.Stopping) return;
        App.Window?.DispatcherQueue.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping) return;
            var prefs = new CompletionSoundPrefs(FilePreferences.Shared);
            if (CueGate.ShouldPlay(e.SessionId, DateTimeOffset.UtcNow, prefs.IsOn)) CompletionCue.Play(prefs.Variant);
        });
    }
}

/// What Diagnostics lists under Recent errors: AppLog's errors and failures since launch (no message text: AppLog never
/// holds any), redacted again when shown and copied.
internal static class ErrorLog
{
    private static readonly List<(string Message, DateTimeOffset? At)> Entries = [];

    public static void Note(string area, string text)
    {
        var failure = area is "unhandled" || text.Contains("failed", StringComparison.OrdinalIgnoreCase)
            || text.Contains("Exception", StringComparison.Ordinal) || text.Contains("couldn't", StringComparison.OrdinalIgnoreCase);
        if (!failure) return;
        lock (Entries)
        {
            Entries.Add(($"[{area}] {text}", DateTimeOffset.Now));
            if (Entries.Count > 200) Entries.RemoveRange(0, Entries.Count - 200);
        }
    }

    public static IReadOnlyList<DiagnosticsReport.ErrorGroup> Recent()
    {
        lock (Entries) return DiagnosticsReport.RecentErrors(Entries.ToList());
    }
}
