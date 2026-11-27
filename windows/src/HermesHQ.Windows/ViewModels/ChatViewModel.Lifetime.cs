using Hermes.Core.Transcripts;
using Microsoft.UI.Dispatching;

namespace HermesHQ.ViewModels;

public sealed partial class ChatViewModel
{
    private volatile bool _dirty;
    private volatile bool _disposed;

    private void ObserveChanges()
    {
        _timer.Tick += OnTick;
        Session.Changed += OnChanged;
        ChatDisplaySettings.Changed += OnChanged;
    }

    private void OnTick(DispatcherQueueTimer sender, object args) { if (!_disposed) Apply(); }

    private void OnChanged()
    {
        if (_disposed || _dirty) return;
        _dirty = true;
        // A changed notification may have posted this before the UI thread detached the chat.
        _ui.TryEnqueue(() => { if (!_disposed && !_timer.IsRunning) _timer.Start(); });
    }

    public async ValueTask DisposeAsync()
    {
        _disposed = true;
        Session.Changed -= OnChanged;
        ChatDisplaySettings.Changed -= OnChanged;
        try { _timer.Tick -= OnTick; }
        finally
        {
            try { _timer.Stop(); }
            finally { await Session.DisposeAsync(); }
        }
    }
}