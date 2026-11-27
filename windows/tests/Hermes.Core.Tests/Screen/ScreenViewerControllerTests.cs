// [WIN-SCREEN-VIEWER-CORE] The Bot Screen viewer's controller (the Mac's App/Screen/ScreenViewerController.swift at
// 93f984bb1) over a real ScreenSession and the FakeDisplay gateway model: one case per state the Swift shows (S0
// connecting, no answer, missing / Hermes Cloud, off, attaching, live, ended, the latest-screenshots fallback), the
// control notices and their notes, the keyboard, modifiers and paste, on-view and leaving, and AppModel+Screen's
// setup ledger. The Mac has no unit suite for this controller (its UI tests drive it on a simulator); the cases pin
// its words and rules as written. Runs on a MainLoop in the ScreenSession collection (Current is process-wide).

using Hermes.Core.Composer;
using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.ScreenWaits;
using P = Hermes.Core.Screen.ScreenSession.Phase;

namespace Hermes.Core.Tests.Screen;

internal sealed class FakeViewerTimers : IScreenViewerTimers
{
    public sealed class Timer(FakeViewerTimers owner, TimeSpan after, bool repeats, Action fire) : IDisposable
    {
        public TimeSpan After { get; } = after;
        public bool Repeats { get; } = repeats;
        public bool Disposed { get; private set; }
        public void Fire() { if (!Disposed) { if (!Repeats) Disposed = true; fire(); } }
        public void Dispose() { Disposed = true; owner.All.Remove(this); }
    }

    public List<Timer> All { get; } = [];
    public IDisposable Schedule(TimeSpan after, bool repeats, Action fire)
    {
        var timer = new Timer(this, after, repeats, fire);
        All.Add(timer);
        return timer;
    }
}

internal sealed class FakeViewerHost : IScreenViewerHost
{
    public ScreenViewerController? Viewer;
    public ScreenViewerState? Last;
    public int Renders;
    public bool Focused;
    public int Raised, Lowered, Dismissed, TookKeys;
    public List<ScreenHaptic> Haptics { get; } = [];
    public List<string> Said { get; } = [];
    public List<string> Copied { get; } = [];
    public List<bool> Awake { get; } = [];
    public List<ScreenView> Views { get; } = [];
    public List<double> Zooms { get; } = [];
    public int Fits;
    public string? Clipboard;
    /// When set, the clipboard read waits for it (iOS's "Allow Paste" question).
    public TaskCompletionSource<string?>? ClipboardGate;
    public Action? SheetGone;

    public void Render(ScreenViewerState state) { Last = state; Renders++; }
    public bool KeyboardFocused => Focused;
    public void RaiseKeyboard() { Raised++; if (!Focused) { Focused = true; Viewer?.KeyboardFocusChanged(true); } }
    public void LowerKeyboard() { Lowered++; if (Focused) { Focused = false; Viewer?.KeyboardFocusChanged(false); } }
    public void Haptic(ScreenHaptic kind) => Haptics.Add(kind);
    public void Announce(string text) => Said.Add(text);
    public void CopyText(string text) => Copied.Add(text);
    public Task<string?> ReadClipboard() => ClipboardGate?.Task ?? Task.FromResult(Clipboard);
    public void SetStageView(ScreenView view, bool animated) => Views.Add(view);
    public void ZoomStage(double factor) => Zooms.Add(factor);
    public void FitStage() => Fits++;
    public void KeepAwake(bool on) => Awake.Add(on);
    public void PresentControlSetup(Action gone) => SheetGone = gone;
    public void Dismiss() => Dismissed++;
    public void TakeKeys() => TookKeys++;
}

/// A viewer over a session on `FakeDisplay`, everything on one main loop.
internal sealed class ViewerRig : IDisposable
{
    public FakeDisplay Display { get; } = new();
    public FakeUptime Clock { get; } = new();
    public MainLoop Main { get; } = new();
    public ScreenService Service { get; private set; } = null!;
    public FakeViewerHost Host { get; } = new();
    public FakeViewerTimers Timers { get; } = new();
    public FakeFrameTicks Ticks { get; } = new();
    public DateTimeOffset Now = new(2026, 11, 22, 12, 0, 0, TimeSpan.Zero);
    public ScreenViewerController Viewer { get; private set; } = null!;
    public bool Slow;

    public ViewerRig(Action<FakeDisplay.State>? display = null, Action<ScreenViewerController>? configure = null, string name = "Hermes")
    {
        if (display != null) Display.Set(display);
        var fake = Display;
        var clock = Clock;
        Main.Run(() =>
        {
            Service = new ScreenService(fake, fake.Dial, new ScreenHolds(new MemoryStore()))
            {
                Timing = new ScreenSession.Timing
                {
                    StatusWait = TimeSpan.FromMilliseconds(300), PauseDelay = TimeSpan.FromMilliseconds(150),
                    RetryDelay = TimeSpan.FromMilliseconds(40), HealthEvery = TimeSpan.FromMilliseconds(250),
                },
                Now = () => clock.Now,
                Slow = () => Slow,
            };
            Viewer = new ScreenViewerController("default", name, Service, Host, Timers, Ticks, () => Now);
            Host.Viewer = Viewer;
            configure?.Invoke(Viewer);
        });
    }

    /// Loaded and on view, as the page is once it appeared.
    public void Show() => Do(v => { v.Load(); v.Appeared(); });

    public T Get<T>(Func<ScreenViewerController, T> read) => Main.Read(() => read(Viewer));
    public void Do(Action<ScreenViewerController> act) => Main.Run(() => act(Viewer));
    public ScreenViewerState State => Main.Read(() => Host.Last!);
    public ScreenPanelModel Panel => State.Panel;
    public P Phase => Get(v => v.Session.CurrentPhase);
    public FakeScreenSocket? Socket => Display.Sockets.LastOrDefault();

    public Task<bool> Live() => ScreenWait(() => Phase is P.Live && Get(v => v.Stage.HasPicture));
    public Task<bool> Until(Func<ScreenViewerState, bool> done) => ScreenWait(() => Main.Read(() => Host.Last is { } s && done(s)));

    public async Task<bool> TakeOver()
    {
        if (!await ScreenWait(() => Get(v => v.Session.CanTake))) return false;
        Do(v => v.Take());
        return await ScreenWait(() => Get(v => v.Session.Holding && v.Session.BusyWith == null && v.Session.CanSendInput));
    }

    public void Dispose()
    {
        try { Main.Run(() => { Viewer.Left(); Service.Shutdown(); }); } catch (Exception) { }
        Main.Dispose();
        Assert.Empty(Main.Failures);
    }
}

[Collection("ScreenSession")]
public sealed class ScreenViewerControllerTests
{
    private const string Linux = "Xvfb :99";

    // The states that are not a picture (S0, S1, S3, S4, S5, S7)

    [Fact]
    public async Task ConnectingShowsTheSpinnerAndNothingElse()
    {
        using var rig = new ViewerRig(s => s.Hang = ["display.status"]);
        rig.Show();
        var state = rig.State;
        Assert.Equal("Hermes’s Screen", state.Title);
        Assert.Equal(new ScreenPanelModel { Id = "screen.connecting", Spinner = true, Body = "Connecting to the screen…" }, state.Panel);
        Assert.True(state.StageHidden && state.BarHidden && !state.KeepAwake);
        Assert.Null(state.Fallback);
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.no-answer"));
    }

    [Fact]
    public async Task AStatusThatNeverArrivesSaysSoAndTryAgainOpensAgain()
    {
        using var rig = new ViewerRig(s => s.Hang = ["display.status"]);
        rig.Show();
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.no-answer"));
        Assert.Equal(new ScreenPanelModel
        {
            Id = "screen.no-answer", Title = "Couldn’t Reach Hermes’s Screen",
            Body = "The screen’s status never arrived. Check that the computer running Hermes is on and reachable, then try again.",
            Primary = "Try Again", PrimaryId = "screen.retry",
        }, rig.Panel);
        rig.Display.Set(s => s.Hang = []);
        // In the same turn, as on the UI thread: the panel goes back to connecting before the answer.
        Assert.Equal("screen.connecting", rig.Get(v => { v.PanelPrimary(); return rig.Host.Last!.Panel.Id; }));
        Assert.True(await rig.Live());
        Assert.True(await rig.Until(s => s.Panel.Hidden && !s.BarHidden));
    }

    [Fact]
    public async Task TheGatewaysOwnWordsLeadTheNoAnswerPanel()
    {
        using var rig = new ViewerRig(s => s.Fail["display.status"] = FakeDisplay.Rpc(5300, "Bot Desktop state is unreadable"));
        rig.Show();
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.no-answer"));
        Assert.Equal("Bot Desktop state is unreadable. Check that the computer running Hermes is on and reachable, then try again.", rig.Panel.Body);
        // The network coming back asks again (NWPathMonitor).
        rig.Display.Set(s => s.Fail.Clear());
        rig.Do(v => { v.NetworkChanged(false); v.NetworkChanged(true); });
        Assert.True(await rig.Live());
    }

    [Fact]
    public async Task AMissingAddOnShowsItsCommandAndCopiesIt()
    {
        using var rig = new ViewerRig(s => { s.Installed = false; s.InstallCommand = "sudo apt install tigervnc"; });
        rig.Show();
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.missing"));
        Assert.Equal(new ScreenPanelModel
        {
            Id = "screen.missing", Title = "Screen Add-on Missing",
            Body = "The computer running Hermes needs a desktop add-on before Hermes can have a screen. Whoever looks after it can run this there:",
            Code = "sudo apt install tigervnc", Primary = "Check Again", PrimaryId = "screen.check-again",
            Secondary = "Copy", SecondaryId = "screen.copy",
        }, rig.Panel);
        rig.Do(v => v.PanelSecondary());
        Assert.Equal(["sudo apt install tigervnc"], rig.Host.Copied);
        Assert.Contains(ScreenHaptic.Success, rig.Host.Haptics);
        Assert.Equal(new ScreenPill("Copied", "screen.pill.copied", true), rig.State.Pill);
        Assert.Equal("screen.pill.copied:Copied", rig.Get(v => v.LastPill));
        var timer = rig.Main.Read(() => rig.Timers.All.Single(t => !t.Repeats));
        Assert.Equal(TimeSpan.FromSeconds(2), timer.After);
        rig.Main.Run(timer.Fire);
        Assert.Equal(new ScreenPill("Copied", "screen.pill.copied", false), rig.State.Pill);
        // Check Again reads the status again; installed now, the picture comes.
        rig.Display.Set(s => s.Installed = true);
        rig.Do(v => v.PanelPrimary());
        Assert.True(await rig.Live());
    }

    [Fact]
    public async Task AMissingAddOnWithNoCommandOffersNoCopy()
    {
        using var rig = new ViewerRig(s => s.Installed = false);
        rig.Show();
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.missing"));
        Assert.True(rig.Panel.Code == null && rig.Panel.Secondary == null);
        rig.Do(v => v.PanelSecondary());
        Assert.Empty(rig.Host.Copied);
    }

    [Fact]
    public async Task AHermesCloudAgentWithoutScreenOpensItsAgentPage()
    {
        var opened = 0;
        using var rig = new ViewerRig(s => s.Installed = false, v => v.OpenCloudAgent = () => opened++);
        rig.Show();
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.cloud-missing"));
        Assert.Equal(new ScreenPanelModel
        {
            Id = "screen.cloud-missing", Title = "Screen Isn’t Included",
            Body = "Hermes Cloud includes Screen on agents with 8 GB of memory or more. Hermes’s agent is smaller, so it can’t be added there.",
            Primary = "Agent Size…", PrimaryId = "screen.cloud-agent",
        }, rig.Panel);
        rig.Do(v => v.PanelPrimary());
        Assert.Equal(1, opened);
    }

    [Fact]
    public async Task AScreenThatIsOffStartsAndSaysWhereItRuns()
    {
        using var rig = new ViewerRig(s => { s.Running = false; s.Placement = "terminal:docker"; s.Display = Linux; });
        rig.Show();
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.off"));
        Assert.Equal(new ScreenPanelModel
        {
            Id = "screen.off", Title = "Screen Is Off",
            Body = "Start this bot’s desktop to watch what it does and take over when it needs you.",
            Footnote = "Screen runs inside the docker sandbox, with the terminal.", Primary = "Start Screen", PrimaryId = "screen.start",
        }, rig.Panel);
        rig.Do(v => v.PanelPrimary());
        Assert.True(rig.Panel.Working || await rig.Live());
        Assert.True(await rig.Live());
    }

    [Fact]
    public async Task AScreenOffOnTheGatewayItselfHasNoFootnote()
    {
        using var rig = new ViewerRig(s => s.Running = false);
        rig.Show();
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.off"));
        Assert.Null(rig.Panel.Footnote);
    }

    [Fact]
    public async Task AnEndedStreamSaysWhyAndReconnects()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        rig.Display.Set(s => s.DialFails = true);
        rig.Socket!.End();                                         // the retry cannot attach: it asks for a click
        Assert.True(await ScreenWait(() => rig.Phase is P.Ended));
        rig.Display.Set(s => s.DialFails = false);
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.ended"));
        Assert.Equal(new ScreenPanelModel { Id = "screen.ended", Title = "Screen Stopped", Body = "", Primary = "Reconnect", PrimaryId = "screen.reconnect" }, rig.Panel);
        Assert.True(rig.State.BarHidden && rig.State.StageHidden);
        rig.Do(v => v.PanelPrimary());
        Assert.True(await rig.Until(s => s.Panel.Hidden && !s.BarHidden));
    }

    [Fact]
    public async Task AttachingOverAnOldPictureDimsItUnderTheSpinner()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        rig.Display.Set(s => s.Hang.Add("display.observe"));
        rig.Do(v => v.Session.Reconnect());
        Assert.True(await rig.Until(s => s.Panel.Id == "screen.attaching"));
        Assert.Equal(new ScreenPanelModel { Id = "screen.attaching", Spinner = true, Body = "Connecting to the screen…", OverPicture = true }, rig.Panel);
        Assert.True(rig.State is { StageDimmed: true, StageHidden: false, BarHidden: true });
        rig.Display.Set(s => s.Hang.Clear());
    }

    // Live (S2) and control (S6)

    [Fact]
    public async Task LiveShowsThePictureTheLabelAndTheBarAndKeepsTheDisplayOn()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.Until(s => s.KeepAwake));
        var state = rig.State;
        Assert.True(state.Panel.Hidden && !state.StageHidden && !state.BarHidden && state.Zoomable);
        Assert.Equal("Xvfb :99 · 64×48", state.Subtitle);
        Assert.Equal(state.Subtitle, state.StageLabel);
        Assert.Equal("Hermes is in control", state.Bar.Caption);
        Assert.Equal(ControlWords.Take, state.Bar.Take);
        Assert.True(state.Bar.TakeEnabled && !state.Bar.Give && !state.Bar.Force && !state.Bar.Keyboard && !state.Bar.Mac);
        Assert.Empty(state.Notes.Lines);
        Assert.Equal([true], rig.Host.Awake);
        // A PC is never a phone: no rotate hint.
        Assert.Equal(0, rig.Get(v => v.PillsShown));
    }

    [Fact]
    public async Task APortraitPhoneGetsTheRotateHintOnce()
    {
        using var rig = new ViewerRig(s => s.Display = Linux, v => { v.Portrait = true; v.Phone = true; });
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.Until(s => s.Pill?.Id == "screen.hint.rotate"));
        Assert.Equal("Turn your PC sideways for a larger screen", rig.State.Pill!.Text);
        Assert.Contains("Turn your PC sideways for a larger screen", rig.Host.Said);
        Assert.True(rig.Main.Read(() => rig.Service.Holds.RotateHintSeen));
        rig.Do(v => v.Fit());
        Assert.Equal(1, rig.Get(v => v.PillsShown));
    }

    [Fact]
    public async Task TakingControlGivesTheScreenTheKeysAndGivingBackTakesThem()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        Assert.True(await rig.Until(s => s.Bar.Caption == "You are in control" && s.StageControl));
        var state = rig.State;
        Assert.True(state.Bar.Take == null && state.Bar.Give && state.Bar.Keyboard);
        Assert.Contains(ScreenHaptic.Light, rig.Host.Haptics);
        Assert.Equal(["You are in control", ControlWords.ScreenGestures], rig.Host.Said.Take(2));
        Assert.Equal(new ScreenPill(ControlWords.ScreenGestures, "screen.hint.gestures", true), state.Pill);
        Assert.Equal(TimeSpan.FromSeconds(8), rig.Main.Read(() => rig.Timers.All.Single(t => !t.Repeats).After));
        // [mac] control taken raises the key field by itself.
        Assert.True(rig.Main.Read(() => rig.Host.Focused));
        Assert.True(rig.State.Bar.Typing);
        rig.Do(v => v.KeyText("hi"));
        Assert.True(await ScreenWait(() => ViewerInputs(rig).Count(i => i.StartsWith("key", StringComparison.Ordinal)) == 4));
        // The pointer goes out once per display frame.
        rig.Main.Run(() => { rig.Viewer.Stage.PointerPixel = (7, 9); rig.Viewer.Stage.ScheduleMove(); rig.Ticks.Frame(); });
        Assert.True(await ScreenWait(() => ViewerInputs(rig).Contains("pointer 0 7,9")));
        rig.Do(v => v.Give());
        Assert.True(await rig.Until(s => s.Bar.Caption == "Hermes is in control" && !s.StageControl));
        Assert.False(rig.Main.Read(() => rig.Host.Focused));
        Assert.False(rig.State.Pill!.Shown);                       // the gestures hint goes with control
        Assert.Contains("Hermes is in control", rig.Host.Said);
        Assert.False(rig.Get(v => v.Stage.DebugHasMoveLink));
    }

    private static List<string> ViewerInputs(ViewerRig rig) => SessionRig.Inputs(rig.Socket);

    [Fact]
    public async Task AnotherViewerTakingControlSaysSoAndOffersToEndIt()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        rig.Display.OtherTakes();
        Assert.True(await rig.Until(s => s.Pill?.Id == "screen.pill.taken"));
        Assert.Equal(ScreenSession.ControlTakenText, rig.State.Pill!.Text);
        Assert.Contains(ScreenHaptic.Warning, rig.Host.Haptics);
        Assert.Contains(ScreenSession.ControlTakenText, rig.Host.Said);
        Assert.False(rig.Main.Read(() => rig.Host.Focused));
        Assert.True(await rig.Until(s => s.Bar.Force && s.Notes.Lines.Any(l => l.Id == "screen.note.other")));
        Assert.Equal(new ScreenNoteLine(ControlWords.OtherNote, "screen.note.other"), rig.State.Notes.Lines.Single());
        Assert.Equal("Another viewer is in control", rig.State.Bar.Caption);
    }

    [Fact]
    public async Task OnAMacTheNotesSayWhatControlNeeds()
    {
        using var rig = new ViewerRig();                           // FakeDisplay's screen is "This Mac"
        rig.Display.OnRest(() => """{"installed":true,"control":false,"helper":{"ok":true,"locked":true,"secure_input":true,"tcc":{"screen":true,"events":false}}}""");
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.Until(s => s.Notes.Lines.Any(l => l.Id == "screen.note.control")));
        var notes = rig.State.Notes;
        Assert.Contains(new ScreenNoteLine("This is the Mac’s own screen, shared by all bots on this Mac.", "screen.note.mac"), notes.Lines);
        Assert.Contains(new ScreenNoteLine("Control needs setup on this Mac before clicks and typing can work.", "screen.note.control", true), notes.Lines);
        Assert.True(notes.EnableControl);
        Assert.True(rig.State.Bar.Mac && !rig.State.Bar.TakeEnabled);
        Assert.Contains(new ScreenNoteLine("The Mac is locked: clicks and typing are ignored until it is unlocked at the Mac.", "screen.note.locked", true), notes.Lines);
        Assert.Contains(new ScreenNoteLine("A password field has focus on the Mac, so macOS blocks typed text.", "screen.note.secure", true), notes.Lines);
    }

    [Fact]
    public async Task EnableControlOpensTheSheetAndTheScreenUnderItIsOutOfView()
    {
        using var rig = new ViewerRig();
        rig.Display.OnRest(() => """{"installed":true,"control":false,"helper":{"ok":true,"tcc":{"screen":true,"events":false}}}""");
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.Until(s => s.KeepAwake));
        rig.Do(v => v.EnableControl());
        Assert.False(rig.Get(v => v.CanClose));
        Assert.False(rig.State.KeepAwake);
        Assert.True(await ScreenWait(() => !rig.Get(v => v.Session.OnView)));          // paused after the look-away delay
        rig.Main.Run(() => rig.Host.SheetGone!());
        Assert.True(rig.Get(v => v.Session.OnView && v.CanClose));
        Assert.True(await rig.Until(s => s.KeepAwake));
    }

    // Keys and paste

    [Fact]
    public async Task ArmedModifiersGoWithTheNextKeyAndThenLetGo()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        rig.Do(v => v.Modifier(ScreenKeys.Modifier.Ctrl));
        Assert.Equal([ScreenKeys.Modifier.Ctrl], rig.State.Bar.Armed);
        rig.Do(v => v.Key(ScreenKeys.Named.Tab));                  // watching: nothing goes, the modifier stays
        Assert.Single(rig.State.Bar.Armed);
        Assert.True(await rig.TakeOver());
        rig.Do(v => v.Chord("c", []));
        Assert.True(await ScreenWait(() => ViewerInputs(rig).Count(i => i.StartsWith("key", StringComparison.Ordinal)) == 4));
        Assert.Equal(["key ffe3 down", "key 63 down", "key 63 up", "key ffe3 up"], ViewerInputs(rig).Where(i => i.StartsWith("key", StringComparison.Ordinal)));
        Assert.Empty(rig.State.Bar.Armed);
        rig.Do(v => v.Modifier(ScreenKeys.Modifier.Shift));
        rig.Do(v => v.Modifier(ScreenKeys.Modifier.Shift));        // pressed again: let go
        Assert.Empty(rig.State.Bar.Armed);
    }

    [Fact]
    public async Task EscapeIsTheBotsWhileTypingAndClosesOtherwise()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        Assert.True(rig.Main.Read(() => rig.Host.Focused));
        rig.Do(v => v.Escape());
        Assert.True(await ScreenWait(() => ViewerInputs(rig).Contains("key ff1b down")));
        Assert.Equal(0, rig.Host.Dismissed);
        rig.Do(v => v.Keyboard());                                 // the bar's button lowers the keyboard
        Assert.False(rig.Main.Read(() => rig.Host.Focused));
        rig.Do(v => v.Escape());
        Assert.True(rig.Get(v => v.Gone));
        Assert.Equal(1, rig.Host.Dismissed);
    }

    [Fact]
    public async Task AnEmptyClipboardSaysSoAndTextIsPasted()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        await rig.Main.RunAsync(() => rig.Viewer.Paste());
        Assert.Equal(new ScreenPill(ControlWords.NothingToPaste, "screen.pill.clipboard", true), rig.State.Pill);
        Assert.Contains(ScreenHaptic.Warning, rig.Host.Haptics);
        rig.Host.Clipboard = "clip";
        await rig.Main.RunAsync(() => rig.Viewer.Paste());
        Assert.True(await ScreenWait(() => ViewerInputs(rig).Any(i => i.StartsWith("cut", StringComparison.Ordinal) || i.StartsWith("key", StringComparison.Ordinal))));
        Assert.False(rig.Get(v => v.PastePending));
    }

    [Theory]
    [InlineData(3, true)]
    [InlineData(9, false)]
    public async Task APasteWaitsEightSecondsAtMostForInputToComeBack(int seconds, bool sent)
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        var gate = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Host.ClipboardGate = gate;
        var paste = rig.Main.RunAsync(() => rig.Viewer.Paste());
        // While the question is up the Screen goes out of view (a sheet here): its stream pauses.
        rig.Do(v => v.EnableControl());
        Assert.True(await ScreenWait(() => !rig.Get(v => v.Session.CanSendInput)));
        gate.SetResult("clip");
        await paste;
        Assert.True(rig.Get(v => v.PastePending));
        rig.Now = rig.Now.AddSeconds(seconds);
        rig.Main.Run(() => rig.Host.SheetGone!());
        Assert.True(await ScreenWait(() => rig.Get(v => v.Session.CanSendInput) && !rig.Get(v => v.PastePending)));
        if (sent) Assert.True(await ScreenWait(() => ViewerInputs(rig).Any(i => !i.StartsWith("pointer", StringComparison.Ordinal))));
        else
        {
            await Task.Delay(150);
            Assert.DoesNotContain(ViewerInputs(rig), i => !i.StartsWith("pointer", StringComparison.Ordinal));
        }
    }

    // On view (§5.11)

    [Fact]
    public async Task GoingToTheBackgroundCoversThePictureAndComingBackUncoversIt()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        rig.Do(v => v.AppChanged(active: false, background: true));
        var state = rig.State;
        Assert.True(state.StageCovered && !state.KeepAwake);
        Assert.False(rig.Main.Read(() => rig.Host.Focused));
        Assert.True(rig.Get(v => !v.Session.OnView && v.Stage.Covered));
        rig.Do(v => v.AppChanged(active: true, background: false));
        Assert.False(rig.State.StageCovered);
        Assert.True(await rig.Until(s => s.KeepAwake && s.StageControl));
        // The keyboard the person had up comes back with the stream.
        Assert.True(await ScreenWait(() => rig.Main.Read(() => rig.Host.Focused)));
    }

    [Fact]
    public async Task ASystemQuestionOverTheAppLeavesTheKeyboard()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        var lowered = rig.Main.Read(() => rig.Host.Lowered);
        rig.Do(v => v.AppChanged(active: false, background: false));
        Assert.True(rig.State.StageCovered);
        Assert.Equal(lowered, rig.Main.Read(() => rig.Host.Lowered));
    }

    // The latest screenshots (fallback)

    [Fact]
    public async Task WithoutALiveScreenTheLatestScreenshotsShowAndTheStatusIsReadAgain()
    {
        using var rig = new ViewerRig(s => s.Supported = false);
        rig.Do(v => v.Load());                                     // loaded, not yet on view
        Assert.True(await rig.Until(s => s.FallbackShown));
        Assert.Equal(new ScreenFallbackModel(ScreenSession.Fallback.Unsupported, null, false, false), rig.State.Fallback);
        Assert.Null(rig.State.Subtitle);
        Assert.False(rig.Get(v => v.Refreshing));
        rig.Do(v => v.Appeared());
        Assert.True(rig.State.Fallback!.Visible);
        var refresh = rig.Main.Read(() => rig.Timers.All.Single(t => t.Repeats));
        Assert.Equal(TimeSpan.FromSeconds(5), refresh.After);
        // The add-on finishes installing while the page is open: the live Screen opens by itself.
        rig.Display.Set(s => s.Supported = true);
        rig.Main.Run(refresh.Fire);
        Assert.True(await rig.Live());
        Assert.True(await rig.Until(s => !s.FallbackShown && s.Fallback is { Visible: false }));
        Assert.False(rig.Get(v => v.Refreshing));
    }

    [Fact]
    public async Task ALowPowerDeviceReadsEveryTenSecondsAndAWindowsCardNever()
    {
        using var rig = new ViewerRig(s => { s.Installed = true; s.Running = false; s.Blocker = "Allow Screen Recording"; });
        rig.Slow = true;
        rig.Show();
        Assert.True(await rig.Until(s => s.FallbackShown));
        Assert.Equal(new ScreenFallbackModel(ScreenSession.Fallback.Blocked, "Allow Screen Recording", false, true), rig.State.Fallback);
        Assert.Equal(TimeSpan.FromSeconds(10), rig.Main.Read(() => rig.Timers.All.Single(t => t.Repeats).After));
        rig.Do(v => { v.FallbackWindowsCard = true; v.AppChanged(active: true, background: false); });
        Assert.False(rig.Get(v => v.Refreshing));
    }

    [Fact]
    public async Task TheSetupCardsAskThroughTheApp()
    {
        var asked = new List<bool>();
        using var rig = new ViewerRig(s => s.Supported = false, v =>
        {
            v.RequestSetup = resume => { asked.Add(resume); return Task.FromResult<ScreenSetupError?>(null); };
            v.SetupRequested = () => asked.Count > 0;
        });
        rig.Show();
        Assert.False(rig.Get(v => v.SetupRequestedBefore));
        Assert.Null(await rig.Main.RunAsync(() => rig.Viewer.RequestSetupAsync(cardRequested: false, controlOnly: false)));
        await rig.Main.RunAsync(() => rig.Viewer.RequestSetupAsync(cardRequested: false, controlOnly: true));
        Assert.Equal([false, true], asked);
        Assert.True(rig.Get(v => v.SetupRequestedBefore));
        // No app hook: not connected.
        rig.Do(v => v.RequestSetup = null);
        var failure = await rig.Main.RunAsync(() => rig.Viewer.RequestSetupAsync(false, false));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.NotConnected), failure);
    }

    // Compact typing, zoom

    [Fact]
    public async Task TypingOnAShortWideStageFillsItsWidthAndPutsTheViewBack()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        Assert.True(rig.Main.Read(() => rig.Host.Focused));
        rig.Do(v => v.UpdateCompactTyping(new ScreenSize(800, 300), 0.5));
        Assert.True(rig.State.InCompact);
        Assert.Null(rig.State.Subtitle);
        var filled = rig.Main.Read(() => rig.Host.Views.Last());
        Assert.True(filled.Zoom > 1.05);
        rig.Do(v => v.Keyboard());                                 // the keyboard goes down
        Assert.False(rig.State.InCompact);
        Assert.Equal(ScreenView.Fit, rig.Main.Read(() => rig.Host.Views.Last()));
    }

    [Fact]
    public async Task TheZoomKeysWorkOnALivePictureOnlyWhileNothingTypes()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(rig.Get(v => v.ZoomKey("=") && v.ZoomKey("-") && v.ZoomKey("0") && !v.ZoomKey("x")));
        Assert.Equal([1.5, 1 / 1.5], rig.Host.Zooms);
        Assert.Equal(1, rig.Host.Fits);
        rig.Do(v => v.StageViewChanged(new ScreenView(2, 0, 0), committed: true));
        Assert.True(rig.State.Bar.Fit);
        rig.Do(v => v.Fit());
        Assert.False(rig.State.Bar.Fit);
        Assert.True(await rig.TakeOver());
        Assert.False(rig.Get(v => v.ZoomKey("=")));                // the key field types: = is the bot's
    }

    // Leaving (§5.8, §6.2)

    [Fact]
    public async Task OneScreenAtATimeAndLeavingIsIdempotent()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        var opened = rig.Main.Read(() => ScreenViewerController.Open("default", "", rig.Service, rig.Host, rig.Timers, rig.Ticks));
        Assert.NotNull(opened);
        Assert.Equal("This bot’s Screen", opened!.Title);
        Assert.Same(opened, ScreenViewerController.Current);
        Assert.Null(rig.Main.Read(() => ScreenViewerController.Open("other", "Ivy", rig.Service, rig.Host, rig.Timers, rig.Ticks)));
        Assert.Contains(ScreenHaptic.Selection, rig.Host.Haptics);
        rig.Main.Run(() => { opened.Left(); opened.Left(); });
        Assert.Null(ScreenViewerController.Current);
        Assert.True(opened.Session.Left);
        var again = rig.Main.Read(() => ScreenViewerController.Open("default", "Hermes", rig.Service, rig.Host, rig.Timers, rig.Ticks));
        Assert.NotNull(again);
        rig.Main.Run(() => again!.Left());
        await Task.CompletedTask;
    }

    [Fact]
    public async Task ClosingLeavesFirstStopsEveryTimerAndLetsTheDisplaySleep()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        Assert.True(await rig.TakeOver());
        Assert.True(await rig.Until(s => s.KeepAwake && s.Pill is { Shown: true }));
        rig.Main.Run(() => { rig.Viewer.Stage.ScheduleMove(); });
        rig.Do(v => v.Close());
        var renders = rig.Main.Read(() => rig.Host.Renders);
        Assert.True(rig.Get(v => v.Gone && v.Session.Left && !v.CanClose));
        Assert.Equal(1, rig.Host.Dismissed);
        Assert.Empty(rig.Main.Read(() => rig.Timers.All));
        Assert.Empty(rig.Main.Read(() => rig.Ticks.Links));
        Assert.False(rig.Host.Awake.Last());
        Assert.False(rig.Main.Read(() => rig.Host.Focused));
        // Nothing draws once gone, whatever the session says next.
        rig.Do(v => v.Session.OnChange?.Invoke());
        Assert.Equal(renders, rig.Main.Read(() => rig.Host.Renders));
        // Closing while in control hands back through the close frame.
        Assert.True(await ScreenWait(() => rig.Display.Sockets.Last().Closes.SequenceEqual([true])));
    }

    [Fact]
    public async Task TheDebugLineCarriesTheViewersState()
    {
        using var rig = new ViewerRig(s => s.Display = Linux);
        rig.Show();
        Assert.True(await rig.Live());
        var line = rig.Get(v => v.DebugSummary());
        // [WIN-SCREEN-GESTURE] The pointer is the gesture's (`stage.pointerPixel`): it starts mid-desktop.
        var (width, height) = rig.Get(v => v.Stage.Framebuffer);
        Assert.Contains($" zoom=1.00 pan=0,0 pointer={width / 2},{height / 2} control=0 typing=0 compact=0 landscape=0 idle=1 backlog=0 covered=0 shotZoom=0.00 pills=0 lastPill=-", line);
    }
}

public sealed class ScreenSetupLedgerTests
{
    [Fact]
    public async Task ASecondRequestJoinsTheOneInFlight()
    {
        var ledger = new ScreenSetupLedger();
        var key = ScreenSetupLedger.Key("account", "default");
        Assert.Equal("account|default", key);
        var gate = new TaskCompletionSource<ScreenSetupError?>();
        var runs = 0;
        var first = ledger.Request(key, () => { runs++; return gate.Task; });
        Assert.True(ledger.InFlight(key) && ledger.Requested(key));
        var second = ledger.Request(key, () => { runs++; return Task.FromResult<ScreenSetupError?>(null); });
        var failure = new ScreenSetupError(ScreenSetupFailure.ChatDidNotOpen);
        gate.SetResult(failure);
        Assert.Equal(failure, await first);
        Assert.Equal(failure, await second);
        Assert.Equal(1, runs);
        Assert.False(ledger.InFlight(key) || ledger.Requested(key));
    }

    [Fact]
    public void ARequestAlreadyThereIsMarkedSubmitted()
    {
        var ledger = new ScreenSetupLedger();
        Assert.False(ledger.AlreadyThere("k", hasQueuedSetup: false, resume: false));
        Assert.True(ledger.AlreadyThere("k", hasQueuedSetup: true, resume: false));
        Assert.True(ledger.Submitted("k"));
        Assert.True(ledger.AlreadyThere("k", hasQueuedSetup: false, resume: false));     // made this run, not continued
        Assert.False(ledger.AlreadyThere("k", hasQueuedSetup: false, resume: true));     // continued: send again
    }

    [Fact]
    public void TheInfoRowsWords()
    {
        Assert.Equal("See what was on its screen last", ScreenInfoRowWords.Subtitle(ScreenKind.Screenshots));
        Assert.Equal("See its desktop live", ScreenInfoRowWords.Subtitle(ScreenKind.Live));
        Assert.Equal("See its desktop live", ScreenInfoRowWords.Subtitle(ScreenKind.Unknown));
        Assert.Equal("Computer", ScreenInfoRowWords.Header);
        var alert = ScreenInfoRowWords.SetupFailed(new ScreenSetupError(ScreenSetupFailure.NotConnected));
        Assert.Equal(ScreenSetupError.AlertTitle, alert.Title);
        Assert.Equal("OK", alert.Button);
    }
}
