using Hermes.Core;
using Hermes.Core.Offline;
using Hermes.Core.Rpc;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Gateways;

/// The reconnect notice at the sidebar's top (HermesKit/Offline/ReconnectBanner.swift): a dropped socket holds it for
/// 4 s, so one that comes straight back shows nothing; it says only "Reconnecting to the computer running Hermes…"
/// until a reconnect attempt has failed, then why; after 120 s the header reads "Offline" and the notice says Hermes
/// HQ keeps trying. A first connection is the launch screen's to word, not this.
public sealed class ConnectionNotice : IDisposable
{
    private readonly HermesClient _client;
    private readonly InfoBar _bar;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherQueueTimer _hold, _turn;
    private int _failedAtDrop;
    private DateTimeOffset? _since;
    private string _shown = "";
    private bool _disposed;

    public ConnectionNotice(HermesClient client, InfoBar bar)
    {
        _client = client;
        _bar = bar;
        bar.IsClosable = false;
        bar.Severity = InfoBarSeverity.Warning;
        _hold = _ui.CreateTimer();
        _hold.Interval = ReconnectNotice.Hold;
        _hold.IsRepeating = false;
        _hold.Tick += (_, _) => Render(force: true);
        _turn = _ui.CreateTimer();
        _turn.Interval = HeaderLink.OfflineAfter;
        _turn.IsRepeating = false;
        _turn.Tick += (_, _) => Render(force: false);
        client.Rpc.StateChanged += OnState;
        client.Rpc.RetryChanged += OnRetry;
        Changed();
    }

    private void OnState(ConnectionState _)
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        _ui.TryEnqueue(Changed);
    }

    private void OnRetry()
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!_disposed && !Services.AppShutdown.Stopping && _shown.Length > 0) Render(force: false); });
    }

    private void Changed()
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        var rpc = _client.Rpc;
        if (rpc.State == ConnectionState.Open || rpc.State == ConnectionState.SignedOut || !rpc.EverOpen)
        {
            _hold.Stop(); _turn.Stop();
            _since = null;
            Clear();
            return;
        }
        if (_since == null)
        {
            _since = DateTimeOffset.UtcNow;
            _failedAtDrop = rpc.FailedDials;
            _hold.Start();
            _turn.Start();
            return;
        }
        if (_shown.Length > 0) Render(force: false);
    }

    private void Render(bool force)
    {
        if (_disposed || Services.AppShutdown.Stopping) return;
        if (_since is not { } since || (!force && _shown.Length == 0)) return;
        var rpc = _client.Rpc;
        var failed = rpc.FailedDials > _failedAtDrop;
        var offline = DateTimeOffset.UtcNow - since >= HeaderLink.OfflineAfter;
        var text = ReconnectNotice.Text(networkDown: false, rpc.LastFailure, failed, offline);
        if (text == _shown) return;
        _shown = text;
        _bar.Message = text;
        _bar.IsOpen = true;
    }

    private void Clear()
    {
        _shown = "";
        _bar.IsOpen = false;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _hold.Stop(); _turn.Stop();
        _client.Rpc.StateChanged -= OnState;
        _client.Rpc.RetryChanged -= OnRetry;
        if (!Services.AppShutdown.Stopping) Clear();
    }
}
