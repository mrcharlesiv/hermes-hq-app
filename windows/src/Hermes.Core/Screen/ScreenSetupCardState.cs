// [WIN-SCREEN-SETUP-SEND] The setup card's state (docs/spec/3x-screen.md §5.9, §5.13), from the Mac's
// App/Screen/ScreenSetupCard.swift at 93f984bb1 (`apply`, `showRequested`, `setup`, `check`) and the viewer's
// `configure(_:controlOnly:)` and `showControlSetup` (App/Screen/ScreenViewerController.swift): what the card shows in
// each state, and the control-only sheet's own words. The WinUI card (Features/Screen/ScreenSetupCard.cs) draws `Look`;
// the sheet (Features/Screen/ScreenSetupSheet.cs) holds a control-only card made by `ScreenSetupSheetModel.Card`.

namespace Hermes.Core.Screen;

/// What the card shows: one look per state, read by the view after every change.
public sealed record ScreenSetupCardLook(
    string Heading, bool HeadingShown, bool WindowsNoteShown, bool PointsShown, bool ButtonsShown, bool UpdateShown,
    string Message, bool MessageShown, string Error, bool ErrorShown, string Primary, string Check, bool Enabled,
    string AutomationId);

/// One setup card's state. Runs on the UI thread, as the Swift's card does.
public sealed class ScreenSetupCardState(bool controlOnly)
{
    public bool ControlOnly { get; } = controlOnly;
    /// Starts the request. Returns a failure only when it happened before the Screen closed.
    public Func<Task<ScreenSetupError?>>? OnSetup { get; set; }
    /// "Check setup": the readiness line.
    public Func<Task<string>>? OnCheck { get; set; }
    /// Said aloud (the Mac's HQAnnounce).
    public Action<string>? Announce { get; set; }
    /// Fired after every change; the view draws `Look`.
    public event Action? Changed;

    private bool _requested, _needsUpdate, _windows;

    /// Setup was already requested for this bot in this run.
    public bool Requested { get => _requested; set { if (value != _requested) { _requested = value; Changed?.Invoke(); } } }
    /// The gateway predates the Screen: the card adds the update line.
    public bool NeedsUpdate { get => _needsUpdate; set { if (value != _needsUpdate) { _needsUpdate = value; Changed?.Invoke(); } } }
    /// A Windows gateway: one sentence, no buttons.
    public bool WindowsGateway { get => _windows; set { if (value != _windows) { _windows = value; Changed?.Invoke(); } } }
    public bool Busy { get; private set; }
    public bool Checking { get; private set; }
    public string Message { get; private set; } = "";
    public string Error { get; private set; } = "";

    public ScreenSetupCardLook Look => new(
        Heading: ScreenSetupCopy.Heading(ControlOnly),
        HeadingShown: !_windows,
        WindowsNoteShown: _windows,
        PointsShown: !_windows,
        ButtonsShown: !_windows,
        UpdateShown: !_windows && _needsUpdate,
        Message: Message,
        MessageShown: !_windows && Message.Length > 0,
        Error: Error,
        ErrorShown: !_windows && Error.Length > 0,
        Primary: ScreenSetupCopy.Primary(_requested, ControlOnly, Busy),
        Check: ScreenSetupCopy.Check(Checking),
        Enabled: !Busy && !Checking,
        AutomationId: ControlOnly ? "screen.setup.card.control" : "screen.setup.card");

    /// Shows the "requested" line (the Screen was reopened after a request).
    public void ShowRequested()
    {
        _requested = true;
        Message = ScreenSetupCopy.Requested;
        Changed?.Invoke();
    }

    /// The primary button: one request at a time; a failure is shown and said, a request shows the requested line.
    public async Task SetupAsync()
    {
        if (Busy || OnSetup is not { } setup) return;
        Busy = true;
        Error = "";
        Changed?.Invoke();
        ScreenSetupError? failure;
        try { failure = await setup(); }
        catch (ScreenSetupError e) { failure = e; }
        Busy = false;
        if (failure != null)
        {
            Error = failure.Message;
            Announce?.Invoke(failure.Message);
        }
        else
        {
            _requested = true;
            Message = ScreenSetupCopy.Requested;
        }
        Changed?.Invoke();
    }

    /// "Check Setup": the readiness line in the message, said aloud; a failure's words in the error line.
    public async Task CheckAsync()
    {
        if (Checking || OnCheck is not { } check) return;
        Checking = true;
        Error = "";
        Changed?.Invoke();
        string? line = null, failure = null;
        try { line = await check(); }
        catch (Exception e) { failure = ScreenWire.Message(e); }
        Checking = false;
        if (line != null)
        {
            Message = line;
            Announce?.Invoke(line);
        }
        if (failure != null) Error = failure;
        Changed?.Invoke();
    }
}

/// The control-only card as a sheet over a live Mac Screen, so it never covers the picture (§5.9).
public static class ScreenSetupSheetModel
{
    /// The sheet's title (`ChatSheet.wrap(sheet, title: "Screen Control")`).
    public const string Title = "Screen Control";
    /// Its close button: a Mac sheet closes with the word Done (stress test 2026-10-28 #32, #55).
    public const string Close = "Done";
    public const string AutomationId = "screen.setup.sheet";

    /// `configure(card, controlOnly: true)`: the requested line when setup was requested this run; Set Up asks the app
    /// to continue (a control-only request always continues); Check Setup reads the readiness line.
    public static ScreenSetupCardState Card(Func<bool> setupRequested, Func<bool, bool, Task<ScreenSetupError?>> requestSetup,
        Func<Task<string>> check)
    {
        var card = new ScreenSetupCardState(controlOnly: true);
        if (setupRequested()) card.ShowRequested();
        card.OnSetup = () => requestSetup(card.Requested, true);
        card.OnCheck = check;
        return card;
    }

    /// The card over a viewer (the app's sheet).
    public static ScreenSetupCardState Card(ScreenViewerController viewer) =>
        Card(() => viewer.SetupRequestedBefore, viewer.RequestSetupAsync, viewer.CheckSetupAsync);
}
