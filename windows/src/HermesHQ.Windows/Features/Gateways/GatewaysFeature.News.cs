using Hermes.Core;
using Hermes.Core.Gateways;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace HermesHQ.Features.Gateways;

public static partial class GatewaysFeature
{
    private static DispatcherQueue? _newsUi;
    private static DispatcherQueueTimer? _news;
    private static Window? _newsWindow;

    internal static void RegisterNews()
    {
        if (AppShutdown.Stopping || _newsUi != null) return;
        _newsUi = DispatcherQueue.GetForCurrentThread();
        AppState.ClientChanged += ClientChanged;
    }

    // ClientChanged can arrive off the UI thread. Initialization and teardown must own the same queue.
    private static void ClientChanged(HermesClient? client)
    {
        if (!AppShutdown.Stopping) _newsUi?.TryEnqueue(StartNews);
    }

    /// Four seconds after a gateway is in use, then every three minutes (GatewaySwitcherModel.start).
    private static void StartNews()
    {
        if (AppShutdown.Stopping || _news != null || App.Window is not { } window) return;
        _news = window.DispatcherQueue.CreateTimer();
        _news.Interval = GatewayHub.FirstCheck;
        _news.IsRepeating = false;
        _news.Tick += NewsTick;
        _newsWindow = window;
        window.Activated += Activated;
        _news.Start();
    }

    private static void NewsTick(DispatcherQueueTimer timer, object args)
    {
        if (AppShutdown.Stopping) return;
        timer.Interval = GatewayHub.Every;
        timer.Start();
        if (AppState.Client != null && AppState.Gateways.IsShown) _ = AppState.Gateways.CheckAsync(force: false);
    }

    private static void Activated(object sender, WindowActivatedEventArgs args)
    {
        if (!AppShutdown.Stopping && args.WindowActivationState != WindowActivationState.Deactivated)
            AppState.Gateways.CheckSoon(force: false);
    }

    internal static async Task StopNewsForQuit()
    {
        try { DetachNews(); }
        finally { await AppState.Gateways.StopNewsForQuitAsync(); }
    }

    private static void DetachNews()
    {
        AppState.ClientChanged -= ClientChanged;
        var timer = _news;
        var window = _newsWindow;
        _news = null;
        _newsWindow = null;
        _newsUi = null;
        try { if (window != null) window.Activated -= Activated; }
        finally
        {
            if (timer != null)
            {
                try { timer.Tick -= NewsTick; }
                finally { timer.Stop(); }
            }
        }
    }
}
