using HermesHQ.Services;
using Microsoft.UI.Xaml;

namespace HermesHQ.Features.Gateways;

public sealed partial class OfflineView
{
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private bool _ended;

    private void ObserveCountdown()
    {
        _model.Announce = words => { if (!_ended && !AppShutdown.Stopping) AnnounceStatus(words); };
        _tick.Tick += Tick;
        Loaded += StartCountdown;
        Unloaded += PauseCountdown;
    }

    private void StartCountdown(object sender, RoutedEventArgs args)
    {
        if (!_ended && !AppShutdown.Stopping) _tick.Start();
    }

    private void PauseCountdown(object sender, RoutedEventArgs args)
    {
        if (!_ended && _tick.IsEnabled) _tick.Stop();
    }

    private void Tick(object? sender, object args)
    {
        if (!_ended && !AppShutdown.Stopping && _tick.IsEnabled) RenderStatus();
    }

    // Navigation can temporarily unload and reload a live view. Only its owner permanently ends it.
    internal void EndCountdown()
    {
        if (_ended) return;
        _ended = true;
        _model.Announce = _ => { };
        try
        {
            Loaded -= StartCountdown;
            Unloaded -= PauseCountdown;
            _tick.Tick -= Tick;
        }
        finally { if (_tick.IsEnabled) _tick.Stop(); }
    }
}