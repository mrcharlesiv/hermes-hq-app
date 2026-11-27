// The chat's browser card state machine (C# twin of App/Browser/BrowserChatCard.swift):
// listens to BrowserActivityChannel only while the chat is visible, evaluates BrowserScope.DrivenRow and
// BrowserCard.Row/Words whenever the activity list or the chat's running state changes, and emits a BrowserChatChip.

namespace Hermes.Core.Browser;

public sealed record BrowserChatChip(string Words, bool Asking);

public sealed class BrowserChatCardModel : IDisposable
{
    private readonly BrowserService _service;
    private readonly Func<BrowserScope> _scope;
    private readonly Func<bool> _isTurnRunning;
    private BrowserSubscription? _subscription;
    private BrowserRow? _showing;
    private BrowserChatChip? _chip;

    public BrowserChatChip? Chip => _chip;
    public event Action<BrowserChatChip?>? Changed;

    public BrowserChatCardModel(BrowserService service, Func<BrowserScope> scope, Func<bool> isTurnRunning)
    {
        _service = service;
        _scope = scope;
        _isTurnRunning = isTurnRunning;
    }

    public void SetVisible(bool on)
    {
        if (on && _subscription == null)
        {
            _subscription = _service.Activity.Subscribe(Update);
            Update();
        }
        else if (!on && _subscription != null)
        {
            _subscription.Cancel();
            _subscription = null;
        }
    }

    public void Update()
    {
        if (_subscription == null) return;
        var scope = _scope();
        var row = BrowserCard.Row(scope.DrivenRow(_service.Activity.Rows), _showing, _isTurnRunning());
        var changed = row?.Id != _showing?.Id;
        _showing = row;
        var next = row == null
            ? null
            : new BrowserChatChip(
                BrowserCard.Words(row, string.IsNullOrEmpty(scope.Title) ? "This bot" : scope.Title),
                row.Ask != null && row.Control == BrowserControl.Bot);
        if (next != _chip)
        {
            if (changed) _service.Note?.Invoke(row == null ? "chat card gone" : "chat card shown");
            _chip = next;
            Changed?.Invoke(next);
        }
    }

    public BrowserScope CurrentScope() => _scope();

    public void Dispose()
    {
        _subscription?.Cancel();
        _subscription = null;
    }
}
