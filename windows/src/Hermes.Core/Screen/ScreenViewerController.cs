// [WIN-SCREEN-VIEWER-CORE] A bot's whole-computer Screen (docs/spec/3x-screen.md §4), the viewer's controller: the
// C# twin of the Mac's App/Screen/ScreenViewerController.swift at 93f984bb1 without its UIKit. It watches the
// ScreenSession, decides what the page shows (the state panel, the notes, the control bar, the latest-screenshots
// page, the short notes over the picture), runs the on-view rules (§5.11), the keyboard and paste rules, compact
// typing (§5.7) and leaving (§5.8, §6.2). One at a time (`Current`).
//
// Windows is the Mac (Catalyst) build's twin: the [mac] branches are taken (control taken gives the bot's screen the
// keys, = / - / 0 zoom, Escape and Ctrl+W close), DeviceWord gives "PC" and "click". The view is IScreenViewerHost,
// the timers IScreenViewerTimers, the display link IScreenFrameTicks, the wall clock `now`. Every call is made on the
// UI thread (the Swift's main actor), as ScreenSession's are; nothing in here locks.

using Hermes.Core.Gateways;
using P = Hermes.Core.Screen.ScreenSession.Phase;

namespace Hermes.Core.Screen;

public sealed class ScreenViewerController
{
    private static WeakReference<ScreenViewerController>? _current;

    /// The open Screen, if any (Swift `static weak var current`).
    public static ScreenViewerController? Current => _current != null && _current.TryGetTarget(out var viewer) ? viewer : null;

    public string Profile { get; }
    public string BotName { get; }
    public ScreenSession Session { get; }
    public ScreenStageState Stage { get; }
    /// The key field's rules (ScreenKeyField): the page feeds it KeyDown and CharacterReceived while it has focus.
    public ScreenKeyInput KeyInput { get; }

    /// "Set up with Hermes" (`resume`: a request made before may be continued). Set by the app.
    public Func<bool, Task<ScreenSetupError?>>? RequestSetup { get; set; }
    /// Whether setup was already requested for this bot in this run.
    public Func<bool>? SetupRequested { get; set; }
    /// The bot's gateway is a Hermes Cloud agent: Nous picks its image, so there is nothing to install there. Opens that
    /// agent's page in Hermes Cloud.
    public Action? OpenCloudAgent { get; set; }
    /// Whether a live event's runtime session is one of this bot's chats.
    public Func<string, bool>? OwnsSession { get; set; }

    /// The latest-screenshots page's setup card is the Windows-gateway one (one sentence, no buttons): nothing to wait
    /// for, so its Screen is not re-read in the background (`page.card.windows`).
    public bool FallbackWindowsCard { get; set; }
    /// The page's shape, for the rotate hint (`view.bounds`, `userInterfaceIdiom == .phone`). A PC is never a phone.
    public bool Portrait { get; set; }
    public bool Phone { get; set; }

    private readonly ScreenService _service;
    private readonly IScreenViewerHost _host;
    private readonly IScreenViewerTimers _timers;
    private readonly Func<DateTimeOffset> _now;

    private IDisposable? _pillTimer;
    private IDisposable? _refreshTimer;
    private HashSet<ScreenKeys.Modifier> _armed = [];
    private bool _couldSendInput;
    private bool _typing;
    /// The person raised the keyboard: it comes back by itself when a paused stream does, until they lower it or
    /// control ends.
    private bool _typingWanted;
    private bool _pasting;
    private (string Text, DateTimeOffset Until)? _pendingPaste;
    private bool _appActive = true;
    private bool _appeared;
    private bool _covered;
    private bool _sheetUp;
    private bool _gone;
    private bool _loaded;
    private bool _inCompact;
    private ScreenView? _savedView;
    private bool _touchedView;
    private bool _pathSatisfied = true;
    private bool _awake;
    private ScreenView _stageView = ScreenView.Fit;
    private ScreenSize _visible = ScreenSize.Zero;
    private double? _tappedRow;
    private ScreenPill? _pill;
    private ScreenFallbackModel? _fallback;
    private bool _fallbackShown;
    private ScreenViewerState _state = new();

    /// How many short notes were shown, and the newest one's identifier and words (UI tests read them).
    public int PillsShown { get; private set; }
    public string LastPill { get; private set; } = "-";

    /// Opens the Screen when none is: the Swift's `present(…)`. Null while another is open.
    public static ScreenViewerController? Open(string profile, string name, ScreenService service, IScreenViewerHost host,
                                               IScreenViewerTimers timers, IScreenFrameTicks ticks,
                                               Action<ScreenViewerController>? configure = null, Func<DateTimeOffset>? now = null)
    {
        if (Current != null) return null;
        var viewer = new ScreenViewerController(profile, name, service, host, timers, ticks, now);
        configure?.Invoke(viewer);
        _current = new WeakReference<ScreenViewerController>(viewer);
        host.Haptic(ScreenHaptic.Selection);
        return viewer;
    }

    public ScreenViewerController(string profile, string name, ScreenService service, IScreenViewerHost host,
                                  IScreenViewerTimers timers, IScreenFrameTicks ticks, Func<DateTimeOffset>? now = null)
    {
        Profile = profile;
        BotName = name.Length == 0 ? "This bot" : name;
        _service = service;
        _host = host;
        _timers = timers;
        _now = now ?? (() => DateTimeOffset.Now);
        Session = service.Session(profile, name);
        Stage = new ScreenStageState(ticks, timers);
        KeyInput = ScreenKeyInput.For(this);
    }

    /// Whether this device is in control right now (other streams ask before interrupting).
    public bool IsInControl => Session.Holding;
    public bool Gone => _gone;
    public ScreenViewerState State => _state;
    /// The page's title: the Browser viewer's pattern ("Ivy’s Browser").
    public string Title => $"{BotName}’s Screen";

    // View

    /// `viewDidLoad`: wires the session and the stage, draws, and opens the session.
    public void Load()
    {
        if (_loaded) return;
        _loaded = true;
        Session.OnChange = Render;
        Session.OnFrame = (image, width, height) =>
        {
            var first = !Stage.HasPicture;
            Stage.Show(image, width, height);
            if (first) Render();
        };
        Session.OnNotice = Noticed;
        Stage.OnPointer = (mask, x, y) => Session.SendPointer(mask, x, y);
        Render();
        Session.Open();
    }

    /// `viewDidAppear`.
    public void Appeared()
    {
        _appeared = true;
        OnViewChanged(immediately: true);
        TakeKeys();
    }

    /// The network path (`NWPathMonitor`): coming back asks the session to resume.
    public void NetworkChanged(bool satisfied)
    {
        if (_gone) return;
        var back = satisfied && !_pathSatisfied;
        _pathSatisfied = satisfied;
        if (back) Session.ResumeSignal();
    }

    // On view (§5.11)

    private bool OnView => _appeared && _appActive && !_sheetUp && !_gone;

    /// The app resigned active (`background` false: a system question over it), went to the background, or came back.
    public void AppChanged(bool active, bool background)
    {
        _appActive = active;
        if (!active)
        {
            // Another computer's screen should not sit in the task switcher (DECISION D17).
            _covered = true;
            Stage.Covered = true;
            Stage.DropTouches();
            // A system question over the app leaves the keyboard where it is.
            if (background) _host.LowerKeyboard();
        }
        else
        {
            _covered = false;
            Stage.Covered = false;
        }
        OnViewChanged(immediately: active || background);
        if (active) Session.ResumeSignal();
    }

    private void OnViewChanged(bool immediately)
    {
        Session.SetOnView(OnView, immediately);
        Render();
    }

    // Render

    private void Render()
    {
        if (!_loaded || _gone) return;
        var phase = Session.CurrentPhase;
        var live = phase is P.Live;
        ScreenSession.Fallback? fallbackReason = phase is P.FallbackTo f ? f.Kind : null;
        var label = Session.Label;
        Stage.Control = Session.CanSendInput;
        Stage.Dimmed = phase is P.Attaching && Stage.HasPicture;
        // [mac] A tester 2026-11-19: "I cannot type anything while controlling a bot's screen." Taking control is what
        // gives the bot's screen the keys, as in any remote desktop. The button still lets go of them.
        if (Session.CanSendInput != _couldSendInput)
        {
            _couldSendInput = Session.CanSendInput;
            if (_couldSendInput) _typingWanted = true;
        }
        if (!Session.CanSendInput)
        {
            if (_host.KeyboardFocused) _host.LowerKeyboard();
        }
        else if (_typingWanted && _appActive && !_sheetUp && !_host.KeyboardFocused) _host.RaiseKeyboard();
        FlushPaste();
        if (_gone) return;
        var panel = PanelModel(phase);
        RenderFallback(fallbackReason);
        KeepAwake(live && OnView && Stage.HasPicture);
        if (live && Stage.HasPicture) OfferRotateHint();
        _state = new ScreenViewerState
        {
            Title = Title,
            Subtitle = fallbackReason != null || _inCompact || label.Length == 0 ? null : label,
            StageLabel = label,
            StageHidden = !(live || phase is P.Attaching),
            StageDimmed = Stage.Dimmed,
            StageControl = Stage.Control,
            StageCovered = _covered,
            BarHidden = !live,
            Bar = BarModel(),
            Notes = NotesModel(phase),
            Panel = panel,
            Fallback = _fallback,
            FallbackShown = _fallbackShown,
            KeepAwake = _awake,
            Zoomable = live && Stage.HasPicture,
            InCompact = _inCompact,
            Pill = _pill,
        };
        _host.Render(_state);
    }

    private void RenderBar()
    {
        if (!_loaded || _gone) return;
        _state = _state with { Bar = BarModel() };
        _host.Render(_state);
    }

    private ScreenBarModel BarModel() => new()
    {
        Caption = Session.Caption,
        Held = Session.Held != null && !Session.Holding,
        Take = Session.Holding ? null : ControlWords.TakeLabel(Session.Held != null),
        TakeEnabled = Session.CanTake,
        Give = Session.Holding || Session.Held != null,
        Force = Session.OtherHolds,
        Busy = Session.BusyWith,
        Fit = _stageView.Zoom > 1.001,
        Keyboard = Session.CanSendInput,
        Typing = _typing,
        Mac = Session.IsMac,
        Armed = new HashSet<ScreenKeys.Modifier>(_armed),
    };

    private ScreenNotesModel NotesModel(P phase)
    {
        var lines = new List<ScreenNoteLine>();
        var enableControl = false;
        if (phase is P.Live or P.Attaching)
        {
            if (Session.Held != null && !Session.Holding) lines.Add(new(ControlWords.HeldNote, "screen.note.held"));
            if (Session.OtherHolds) lines.Add(new(ControlWords.OtherNote, "screen.note.other"));
            if (Session.IsMac && !_inCompact)
                lines.Add(new("This is the Mac’s own screen, shared by all bots on this Mac.", "screen.note.mac"));
            if (Session.Mac is { } mac)
            {
                if (!mac.Control)
                    lines.Add(new($"Control needs setup on this Mac before {DeviceWord.Tap}s and typing can work.", "screen.note.control", Warning: true));
                if (mac.Locked)
                    lines.Add(new($"The Mac is locked: {DeviceWord.Tap}s and typing are ignored until it is unlocked at the Mac.", "screen.note.locked", Warning: true));
                if (mac.SecureInput)
                    lines.Add(new("A password field has focus on the Mac, so macOS blocks typed text.", "screen.note.secure", Warning: true));
            }
            enableControl = phase is P.Live && Session.IsMac && Session.Mac?.InputReady != true && !_inCompact;
        }
        return new ScreenNotesModel
        {
            Error = Session.ErrorLine is { } error ? ScreenWire.Plain(error) : null,
            Lines = lines,
            EnableControl = enableControl,
        };
    }

    private ScreenPanelModel PanelModel(P phase)
    {
        switch (phase)
        {
            case P.Connecting:
                return new() { Id = "screen.connecting", Spinner = true, Body = "Connecting to the screen…" };
            case P.NoAnswer noAnswer:
            {
                var lead = noAnswer.Message is { } failure ? ScreenWire.Sentence(ScreenWire.Plain(failure)) : "The screen’s status never arrived.";
                return new()
                {
                    Id = "screen.no-answer", Title = $"Couldn’t Reach {BotName}’s Screen",
                    Body = $"{lead} Check that {HostWord.Phrase} is on and reachable, then try again.",
                    Primary = "Try Again", PrimaryId = "screen.retry",
                };
            }
            case P.Missing when OpenCloudAgent != null:
                // The desktop app's words for the same case: no install offer on a managed agent.
                return new()
                {
                    Id = "screen.cloud-missing", Title = "Screen Isn’t Included",
                    Body = $"Hermes Cloud includes Screen on agents with 8 GB of memory or more. {BotName}’s agent is smaller, so it can’t be added there.",
                    Primary = "Agent Size…", PrimaryId = "screen.cloud-agent",
                };
            case P.Missing:
            {
                var command = Session.Status?.InstallCommand is { Length: > 0 } c ? c : null;
                // Plain words (UX study #83): the add-on, not its package names; the command stays for whoever runs it.
                return new()
                {
                    Id = "screen.missing", Title = "Screen Add-on Missing",
                    Body = $"{HostWord.Sentence} needs a desktop add-on before {BotName} can have a screen. Whoever looks after it can run this there:",
                    Code = command, Primary = "Check Again", PrimaryId = "screen.check-again",
                    Secondary = command == null ? null : "Copy", SecondaryId = "screen.copy",
                };
            }
            case P.Off:
            {
                string? note = null;
                if (Session.Status?.Placement is { } placement && placement.StartsWith("terminal:", StringComparison.Ordinal))
                    note = $"Screen runs inside the {placement["terminal:".Length..]} sandbox, with the terminal.";
                return new()
                {
                    Id = "screen.off", Title = "Screen Is Off",
                    Body = "Start this bot’s desktop to watch what it does and take over when it needs you.",
                    Footnote = note, Primary = "Start Screen", PrimaryId = "screen.start",
                    Working = Session.BusyWith == ScreenSession.Busy.Start,
                };
            }
            case P.Attaching:
                return new() { Id = "screen.attaching", Spinner = true, Body = "Connecting to the screen…", OverPicture = true };
            case P.Ended ended:
                // The panel carries the words now: the short note over it would say the same thing twice.
                if (_pill is { Id: "screen.pill.taken", Shown: true }) HidePill(emit: false);
                return new()
                {
                    Id = "screen.ended", Title = ScreenWire.Plain(ended.Title), Body = ended.Detail is { } d ? ScreenWire.Plain(d) : "",
                    Primary = "Reconnect", PrimaryId = "screen.reconnect",
                };
            default:                                                // live, fallback
                return new() { Hidden = true };
        }
    }

    private void RenderFallback(ScreenSession.Fallback? reason)
    {
        if (reason is not { } kind)
        {
            if (_fallback != null) _fallback = _fallback with { Visible = false };
            _fallbackShown = false;
            StopRefresh();
            return;
        }
        _fallback = new ScreenFallbackModel(kind, Session.Status?.Blocker, Managed: OpenCloudAgent != null, Visible: OnView);
        _fallbackShown = true;
        // The plugin can finish installing while its Screen is still open: the live Screen then opens by itself.
        var wanted = OnView && !FallbackWindowsCard;
        if (wanted && _refreshTimer == null)
        {
            var every = TimeSpan.FromSeconds(_service.Slow() ? 10 : 5);
            _refreshTimer = _timers.Schedule(every, repeats: true, () => Session.Refresh());
        }
        else if (!wanted) StopRefresh();
    }

    /// A repeating status read is running for the latest-screenshots page.
    public bool Refreshing => _refreshTimer != null;

    private void StopRefresh()
    {
        _refreshTimer?.Dispose();
        _refreshTimer = null;
    }

    // Setup cards (the fallback page's and the control-only sheet's)

    /// The card shows "requested" at once: setup was asked for this bot in this run.
    public bool SetupRequestedBefore => SetupRequested?.Invoke() == true;

    /// The card's "Set up with Hermes". `cardRequested`: the card had already been requested once.
    public async Task<ScreenSetupError?> RequestSetupAsync(bool cardRequested, bool controlOnly)
    {
        if (RequestSetup is not { } request) return new ScreenSetupError(ScreenSetupFailure.NotConnected);
        return await request(cardRequested || controlOnly);
    }

    /// The card's "Check setup": the one line, plain, and the status read again.
    public async Task<string> CheckSetupAsync()
    {
        var line = await _service.CheckSetupAsync(Profile);
        Session.Refresh();
        return ScreenWire.Plain(line);
    }

    /// The notes' Enable Control row: the control-only setup sheet. The Screen under it is out of view: its stream
    /// pauses after a second and comes back by itself.
    public void EnableControl()
    {
        _sheetUp = true;
        OnViewChanged(immediately: false);
        _host.PresentControlSetup(() =>
        {
            _sheetUp = false;
            OnViewChanged(immediately: true);
        });
    }

    // Actions

    public void Take() => Session.TakeOver();

    public void Give()
    {
        _host.Haptic(ScreenHaptic.Selection);                      // as the Browser's Give Back
        Session.HandBack();
    }

    public void Force() => Session.ForceHandBack();

    public void DismissError() => Session.DismissError();

    public void Fit()
    {
        if (_inCompact) _touchedView = true;
        _stageView = ScreenView.Fit;
        _host.SetStageView(ScreenView.Fit, animated: true);
        RenderBar();
    }

    /// The bar's keyboard button.
    public void Keyboard()
    {
        if (_host.KeyboardFocused)
        {
            _typingWanted = false;
            _host.LowerKeyboard();
        }
        else if (Session.CanSendInput)
        {
            _typingWanted = true;
            _host.RaiseKeyboard();
        }
    }

    public void Key(ScreenKeys.Named key) => Press(key.Keysym(), []);

    /// A modifier held for the next key, or let go.
    public void Modifier(ScreenKeys.Modifier which)
    {
        _host.Haptic(ScreenHaptic.Selection);
        if (!_armed.Remove(which)) _armed.Add(which);
        RenderBar();
    }

    public IReadOnlySet<ScreenKeys.Modifier> Armed => _armed;

    /// Text the key field typed.
    public void KeyText(string text)
    {
        if (!Session.CanSendInput) return;
        Session.Type(text, _armed);
        ClearArmed();
    }

    public void KeyPress(uint keysym, IReadOnlyCollection<ScreenKeys.Modifier> mods) => Press(keysym, mods);

    /// A character under a modifier (Ctrl+C).
    public void Chord(string character, IReadOnlyCollection<ScreenKeys.Modifier> mods)
    {
        if (character.Length == 0) return;
        Press(ScreenKeys.KeysymFor((uint)char.ConvertToUtf32(character, 0)), mods);
    }

    /// The key field gained or lost the keyboard.
    public void KeyboardFocusChanged(bool on)
    {
        _typing = on;
        UpdateCompactTyping(_visible, _tappedRow);
        Render();
        if (!on)
        {
            if (SynchronizationContext.Current is { } main) main.Post(_ => TakeKeys(), null);
            else TakeKeys();
        }
    }

    /// The stage's local view changed (`committed` false while fingers or the wheel still shape it).
    public void StageViewChanged(ScreenView view, bool committed)
    {
        _stageView = view;
        if (_inCompact) _touchedView = true;
        if (committed) RenderBar();
        else if (_state.Bar.Fit != view.Zoom > 1.001) RenderBar();
    }

    public void PanelPrimary()
    {
        switch (Session.CurrentPhase)
        {
            case P.Missing when OpenCloudAgent != null: OpenCloudAgent(); break;
            case P.NoAnswer or P.Missing: Session.Open(); break;
            case P.Off: Session.Start(); break;
            case P.Ended: Session.Reconnect(); break;
        }
    }

    public void PanelSecondary()
    {
        if (Session.CurrentPhase is not P.Missing || Session.Status?.InstallCommand is not { Length: > 0 } command) return;
        _host.CopyText(command);
        _host.Haptic(ScreenHaptic.Success);
        ShowPill("Copied", "screen.pill.copied", 2);
    }

    private void Press(uint keysym, IReadOnlyCollection<ScreenKeys.Modifier> extra)
    {
        if (!Session.CanSendInput) return;
        Session.SendKeys(ScreenKeys.Chord(keysym, _armed.Union(extra).ToHashSet()));
        ClearArmed();
    }

    private void ClearArmed()
    {
        if (_armed.Count == 0) return;
        _armed = [];
        RenderBar();
    }

    /// The bar's Paste: the clipboard is read only on this click, off the UI work; a refusal reads as empty.
    public async Task Paste()
    {
        if (!Session.CanSendInput || _pasting) return;
        _pasting = true;
        string? text;
        try { text = await _host.ReadClipboard(); }
        catch (Exception) { text = null; }
        _pasting = false;
        if (_gone) return;
        if (string.IsNullOrEmpty(text))
        {
            _host.Haptic(ScreenHaptic.Warning);                    // as the Browser's Paste
            ShowPill(ControlWords.NothingToPaste, "screen.pill.clipboard", 3);
            ClearArmed();
            return;
        }
        _pendingPaste = (text, _now().AddSeconds(8));
        FlushPaste();
    }

    /// The text goes out as soon as this device can send input (a question can pause the stream for a moment). It is
    /// kept for a few seconds at most, and never once control has ended.
    private void FlushPaste()
    {
        if (_pendingPaste is not { } pending) return;
        if (_now() > pending.Until)
        {
            _pendingPaste = null;
            return;
        }
        if (!Session.CanSendInput) return;
        _pendingPaste = null;
        Session.Paste(pending.Text);
        _host.Haptic(ScreenHaptic.Selection);                      // the text went
        ClearArmed();
    }

    /// A paste waits for input to come back.
    public bool PastePending => _pendingPaste != null;

    private void Noticed(ScreenSession.Notice notice)
    {
        switch (notice)
        {
            case ScreenSession.Notice.ControlStarted:
                _host.Haptic(ScreenHaptic.Light);
                _host.Announce("You are in control");
                ShowPill(ControlWords.ScreenGestures, "screen.hint.gestures", 8, announce: true);
                break;
            case ScreenSession.Notice.ControlEnded:
                _typingWanted = false;
                _pendingPaste = null;
                _host.LowerKeyboard();
                Stage.DropTouches();
                if (_pill?.Id == "screen.hint.gestures") HidePill();
                _host.Announce(Session.Caption);
                break;
            case ScreenSession.Notice.ControlTaken:
                _host.Haptic(ScreenHaptic.Warning);
                _typingWanted = false;
                _pendingPaste = null;
                _host.LowerKeyboard();
                Stage.DropTouches();
                ShowPill(ScreenSession.ControlTakenText, "screen.pill.taken", 5, announce: true);
                break;
        }
        Render();
    }

    private void OfferRotateHint()
    {
        if (!ScreenViewMath.WantsRotateHint(_service.Holds.RotateHintSeen, Portrait, Phone)) return;
        _service.Holds.RotateHintSeen = true;
        if (_pill is { Shown: true }) return;
        // UX study #179: the device by name.
        ShowPill($"Turn your {DeviceWord.Name} sideways for a larger screen", "screen.hint.rotate", 6, announce: true, emit: false);
    }

    // Compact typing (§5.7)

    /// The stage's size changed (`viewDidLayoutSubviews`); `tappedRow` is the row last tapped, a fraction of the height.
    public void UpdateCompactTyping(ScreenSize visible, double? tappedRow = null)
    {
        _visible = visible;
        _tappedRow = tappedRow;
        if (!_loaded) return;
        var compact = ScreenViewMath.CompactTyping(_typing, visible) && Session.CurrentPhase is P.Live;
        if (compact == _inCompact) return;
        _inCompact = compact;
        if (compact)
        {
            _savedView = _stageView;
            _touchedView = false;
            if (ScreenViewMath.FillWidthView(visible.Width, visible.Height, Stage.Aspect, tappedRow) is { } next)
            {
                _stageView = next;
                _host.SetStageView(next, animated: true);
            }
        }
        else
        {
            if (!_touchedView && _savedView is { } saved)
            {
                _stageView = saved;
                _host.SetStageView(saved, animated: true);
            }
            _savedView = null;
        }
        Render();
    }

    // Pills (above the bar, never under the top bar)

    private void ShowPill(string text, string id, double seconds, bool announce = false, bool emit = true)
    {
        PillsShown++;
        LastPill = id + ":" + text.Replace(" ", "_", StringComparison.Ordinal);
        _pillTimer?.Dispose();
        _pill = new ScreenPill(text, id, Shown: true);
        if (announce) _host.Announce(text);
        _pillTimer = _timers.Schedule(TimeSpan.FromSeconds(seconds), repeats: false, () => HidePill());
        if (emit) Emit();
    }

    private void HidePill(bool emit = true)
    {
        _pillTimer?.Dispose();
        _pillTimer = null;
        if (_pill is { } pill) _pill = pill with { Shown = false };
        if (emit) Emit();
    }

    private void Emit()
    {
        if (!_loaded || _gone) return;
        _state = _state with { Pill = _pill };
        _host.Render(_state);
    }

    /// The display stays on while a live picture is on view.
    private void KeepAwake(bool on)
    {
        if (on == _awake) return;
        _awake = on;
        _host.KeepAwake(on);
    }

    // Keys and zoom (round 2 #37)

    /// = / - / 0 zoom while a live picture is up, not while the key field types on the bot's screen.
    public bool ZoomKeysActive => !_host.KeyboardFocused && Stage.HasPicture && Session.CurrentPhase is P.Live;

    /// One of the zoom keys; false when the viewer does not take it now.
    public bool ZoomKey(string input)
    {
        if (!ZoomKeysActive || ScreenZoomSteps.ForKey(input) is not { } step) return false;
        Zoom(step);
        return true;
    }

    /// Zoom In / Zoom Out beside the title, and the keys.
    public void Zoom(ScreenZoomStep step)
    {
        if (!Stage.HasPicture) return;
        if (_inCompact) _touchedView = true;
        if (step.Factor() is { } factor) _host.ZoomStage(factor);
        else _host.FitStage();
    }

    private void TakeKeys()
    {
        if (_gone || _host.KeyboardFocused || _sheetUp) return;
        _host.TakeKeys();
    }

    /// Ctrl+W and Escape close the viewer: not while a sheet is up over it (the app's own Escape ladder closes that).
    public bool CanClose => !_sheetUp && !_gone;

    /// Escape: typing on the bot's screen, Escape is the bot's; else it closes the viewer.
    public void Escape()
    {
        if (_host.KeyboardFocused) Press(ScreenKeys.Named.Escape.Keysym(), []);
        else Close();
    }

    // Leaving (§5.8, §6.2)

    /// The close button, Ctrl+W, Escape.
    public void Close()
    {
        _typingWanted = false;
        _pendingPaste = null;
        _host.LowerKeyboard();
        // Leave first: the hand-back does not wait for the dismissal, and never for the network.
        Left();
        _host.Dismiss();
    }

    /// Idempotent. Every way out (Close, a notification that dismisses the page, sign-out) ends here: runs the leaving
    /// rules, stops every timer and gives the screen back to the system.
    public void Left()
    {
        if (_gone) return;
        _gone = true;
        _typingWanted = false;
        _pendingPaste = null;
        Stage.DropTouches();
        Session.Leave();
        _pillTimer?.Dispose();
        _pillTimer = null;
        StopRefresh();
        if (_fallback != null)
        {
            _fallback = _fallback with { Visible = false };
            _state = _state with { Fallback = _fallback };
            _host.Render(_state);
        }
        KeepAwake(false);
        if (Current == this) _current = null;
    }

    /// The UI tests' debug line (`screen.debug`): the stream's pacing and the viewer's state. The page adds what only it
    /// knows (the pan, the pointer, the page's shape, the screenshot's zoom).
    public string DebugSummary(bool landscape = false, double shotZoom = 0) =>
        Session.Pacing.Summary
        + string.Create(System.Globalization.CultureInfo.InvariantCulture,
            $" zoom={_stageView.Zoom:0.00} pan={_stageView.X:0},{_stageView.Y:0} pointer={Stage.PointerPixel.X},{Stage.PointerPixel.Y}")
        + $" control={(Session.CanSendInput ? 1 : 0)} typing={(_typing ? 1 : 0)} compact={(_inCompact ? 1 : 0)}"
        + $" landscape={(landscape ? 1 : 0)} idle={(_awake ? 1 : 0)}"
        + $" backlog={Session.TypingBacklog} covered={(_covered ? 1 : 0)}"
        + string.Create(System.Globalization.CultureInfo.InvariantCulture, $" shotZoom={shotZoom:0.00}")
        + $" pills={PillsShown} lastPill={LastPill}";
}
