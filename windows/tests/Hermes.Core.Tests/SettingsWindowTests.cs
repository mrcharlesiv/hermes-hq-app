using Hermes.Core.Artifacts;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Settings in a window of its own, as App/Mac/MacSettingsWindow.swift, App/Root/KeyCommands.swift (hqSettings,
/// hqCloseChat, settingsEscape) and App/Settings/SettingsRootView.swift (the category it opens on) decide it (93f984bb1).
public class SettingsWindowTests
{
    private sealed class Win { }

    [Fact]
    public void TheWindowIsTitledSettingsAndSettingsSized()
    {
        Assert.Equal("Settings", SettingsWindowLayout.Title);
        // "about 860 × 640 pt on the screen"; the minimum is 900 × 600 of the app's points, drawn at 77 %.
        Assert.Equal(860, SettingsWindowLayout.Width);
        Assert.Equal(640, SettingsWindowLayout.Height);
        Assert.Equal(693, SettingsWindowLayout.MinimumWidth);
        Assert.Equal(462, SettingsWindowLayout.MinimumHeight);
    }

    [Fact]
    public void OneWindowOnlyOpenedAgainItComesForward()
    {
        var windows = new SettingsWindowRegistry<Win>();
        var made = 0;
        var first = windows.Show(() => { made++; return new Win(); });
        Assert.Equal(FileWindowOutcome.Opened, first.Outcome);
        Assert.Same(first.Window, windows.Open);
        var again = windows.Show(() => { made++; return new Win(); });
        Assert.Equal(FileWindowOutcome.BroughtForward, again.Outcome);
        Assert.Same(first.Window, again.Window);
        Assert.Equal(1, made);
        Assert.Equal(1, windows.Count);

        windows.Closed(first.Window!);
        Assert.Null(windows.Open);
        Assert.Equal(0, windows.Count);
        Assert.Equal(FileWindowOutcome.Opened, windows.Show(() => { made++; return new Win(); }).Outcome);
        Assert.Equal(2, made);
    }

    [Fact]
    public void AWindowThatCantBeMadeLeavesNoneOpen()
    {
        var windows = new SettingsWindowRegistry<Win>();
        var result = windows.Show(() => throw new InvalidOperationException("no window"));
        Assert.Equal(FileWindowOutcome.Failed, result.Outcome);
        Assert.Null(windows.Open);
    }

    [Fact]
    public void WithNoMainWindowSettingsOpensWhereItDid()
    {
        // MacSettingsWindow.open: false while the app has no main window to read its gateway from (the sign-in form).
        var step = SettingsWindowPlan.Open(hasMainWindow: false, isOpen: false, argument: "about");
        Assert.Equal(SettingsWindowOutcome.InMainWindow, step.Outcome);
        Assert.Equal("about", step.Show);
    }

    [Fact]
    public void OpenedItShowsWhatWasAskedOtherwiseTheCategoryItWasClosedOn()
    {
        var plain = SettingsWindowPlan.Open(hasMainWindow: true, isOpen: false, argument: null);
        Assert.Equal(SettingsWindowOutcome.Opened, plain.Outcome);
        Assert.Null(plain.Show);
        Assert.False(plain.BackToIndex);

        var asked = SettingsWindowPlan.Open(hasMainWindow: true, isOpen: false, argument: "sidebar");
        Assert.Equal(SettingsWindowOutcome.Opened, asked.Outcome);
        Assert.Equal("sidebar", asked.Show);

        Assert.Equal(SettingsCategory.Appearance, SettingsWindowPlan.OpeningCategory("appearance"));
        Assert.Equal(SettingsCategory.General, SettingsWindowPlan.OpeningCategory(null));
        Assert.Equal(SettingsCategory.General, SettingsWindowPlan.OpeningCategory("no-such-category"));
    }

    [Fact]
    public void BroughtForwardItKeepsItsPageUnlessAPageIsAsked()
    {
        // ⌘, with the window open: to the front, its page as it was left.
        var plain = SettingsWindowPlan.Open(hasMainWindow: true, isOpen: true, argument: null);
        Assert.Equal(SettingsWindowOutcome.BroughtForward, plain.Outcome);
        Assert.Null(plain.Show);
        Assert.False(plain.BackToIndex);
        // Sidebar Settings… with it open: back to the index first, then the page (`openWindow(then:)`).
        var asked = SettingsWindowPlan.Open(hasMainWindow: true, isOpen: true, argument: "sidebar");
        Assert.Equal(SettingsWindowOutcome.BroughtForward, asked.Outcome);
        Assert.Equal("sidebar", asked.Show);
        Assert.True(asked.BackToIndex);
    }

    [Fact]
    public void CtrlWClosesTheWindowNeverTheMainWindowsChat()
    {
        Assert.Equal(SettingsWindowKeyAction.CloseWindow, SettingsWindowKeys.Route(SettingsWindowKeyPress.CtrlW, somethingOver: false, searching: false, canGoBack: false));
        Assert.Equal(SettingsWindowKeyAction.CloseWindow, SettingsWindowKeys.Route(SettingsWindowKeyPress.CtrlW, somethingOver: false, searching: true, canGoBack: true));
        // While a sheet is up only Escape acts.
        Assert.Equal(SettingsWindowKeyAction.Nothing, SettingsWindowKeys.Route(SettingsWindowKeyPress.CtrlW, somethingOver: true, searching: false, canGoBack: false));
    }

    [Fact]
    public void EscapeTakesOneStepAndNeverClosesTheWindow()
    {
        Assert.Equal(SettingsWindowKeyAction.LeaveToWhatIsOver, SettingsWindowKeys.Route(SettingsWindowKeyPress.Escape, somethingOver: true, searching: true, canGoBack: true));
        Assert.Equal(SettingsWindowKeyAction.ClearSearch, SettingsWindowKeys.Route(SettingsWindowKeyPress.Escape, somethingOver: false, searching: true, canGoBack: true));
        Assert.Equal(SettingsWindowKeyAction.GoBack, SettingsWindowKeys.Route(SettingsWindowKeyPress.Escape, somethingOver: false, searching: false, canGoBack: true));
        Assert.Equal(SettingsWindowKeyAction.Nothing, SettingsWindowKeys.Route(SettingsWindowKeyPress.Escape, somethingOver: false, searching: false, canGoBack: false));
    }

    [Fact]
    public void CtrlCommaInTheWindowBringsItForward()
    {
        Assert.Equal(SettingsWindowKeyAction.BringForward, SettingsWindowKeys.Route(SettingsWindowKeyPress.CtrlComma, somethingOver: false, searching: false, canGoBack: false));
        Assert.Equal(SettingsWindowKeyAction.Nothing, SettingsWindowKeys.Route(SettingsWindowKeyPress.CtrlComma, somethingOver: true, searching: false, canGoBack: false));
    }

    [Fact]
    public void ItOpensAsLeftElseBesideTheMainWindowElseInTheMiddle()
    {
        var screen = new WindowFrame(0, 0, 1920, 1040);
        var main = new WindowFrame(100, 80, 1400, 900);
        Assert.Equal(new WindowFrame(160, 120, 860, 640), SettingsWindowLayout.Frame(null, main, screen));
        Assert.Equal(new WindowFrame(320, 240, 1720, 1280), SettingsWindowLayout.Frame(null, main with { X = 200, Y = 160 }, new WindowFrame(0, 0, 3840, 2080), scale: 2));
        Assert.Equal(new WindowFrame(530, 200, 860, 640), SettingsWindowLayout.Frame(null, null, screen));
        var kept = new WindowFrame(300, 200, 900, 700);
        Assert.Equal(kept, SettingsWindowLayout.Frame(kept, main, screen));
        // Kept inside the screen it is on now (a second screen unplugged).
        Assert.Equal(new WindowFrame(1020, 200, 900, 700), SettingsWindowLayout.Frame(kept with { X = 2400 }, main, screen));
        // Beside a main window at the screen's right edge: moved in, not off it.
        Assert.Equal(new WindowFrame(1060, 400, 860, 640), SettingsWindowLayout.Frame(null, new WindowFrame(1500, 600, 1000, 800), screen));
    }

    [Fact]
    public void ItsFrameIsKeptAsWholeNumbers()
    {
        Assert.Equal("300,200,900,700", SettingsWindowLayout.Encode(new WindowFrame(300.4, 199.6, 900, 700)));
        Assert.Equal(new WindowFrame(-40, 12, 900, 700), SettingsWindowLayout.Decode("-40,12,900,700"));
        Assert.Null(SettingsWindowLayout.Decode(null));
        Assert.Null(SettingsWindowLayout.Decode(""));
        Assert.Null(SettingsWindowLayout.Decode("1,2,3"));
        Assert.Null(SettingsWindowLayout.Decode("a,2,900,700"));
        Assert.Null(SettingsWindowLayout.Decode("0,0,300,700"));   // under 320 × 240
        Assert.Null(SettingsWindowLayout.Decode("0,0,900,200"));
        Assert.Equal("hqn.settings.windowFrame", SettingsWindowLayout.FrameKey);
    }

    [Fact]
    public void TheWalkProofSaysWhatIsWrong()
    {
        Assert.Null(SettingsWindowWalkProof.OneWindow(1, "Settings"));
        Assert.Equal("2 Settings windows are open, not one", SettingsWindowWalkProof.OneWindow(2, "Settings"));
        Assert.Equal("no Settings window is open", SettingsWindowWalkProof.OneWindow(0, "Settings"));
        Assert.Equal("the Settings window is titled Hermes HQ", SettingsWindowWalkProof.OneWindow(1, "Hermes HQ"));

        var before = new WalkFacts(OpenPane.Place, null, null, "sessions", false, [], []);
        Assert.Null(SettingsWindowWalkProof.MainUnchanged(before, before with { Bots = ["otto"] }, mainShowsSettings: false));
        Assert.Equal("the main window went from the sessions page to the settings page",
            SettingsWindowWalkProof.MainUnchanged(before, before with { PlaceId = "settings" }, mainShowsSettings: true));
        Assert.Equal("the main window shows Settings", SettingsWindowWalkProof.MainUnchanged(before, before, mainShowsSettings: true));

        Assert.Null(SettingsWindowWalkProof.ShowsCategory("Appearance", "Appearance", "Appearance"));
        Assert.Equal("the window shows Chat, not Appearance", SettingsWindowWalkProof.ShowsCategory("Appearance", "Chat", "Appearance"));
        Assert.Equal("the column marks General, not Appearance", SettingsWindowWalkProof.ShowsCategory("Appearance", "Appearance", "General"));
    }
}
