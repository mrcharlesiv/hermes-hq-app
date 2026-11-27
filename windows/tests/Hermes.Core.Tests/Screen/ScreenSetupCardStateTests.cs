// [WIN-SCREEN-SETUP-SEND] The setup card's states and the control-only "Screen Control" sheet (App/Screen/
// ScreenSetupCard.swift `apply`/`setup`/`check`, `ScreenSetupSheet`, and ScreenViewerController.swift
// `configure(_:controlOnly:)`/`showControlSetup` at 93f984bb1). The Mac has no unit test of the card; its
// UITests/screen/ScreenEndToEndTests.swift test11_notes walks the sheet (heading "Enable Screen Control", primary
// "Enable Control with Hermes", Check Setup's lines in screen.setup.message) and test14 the full card ("Set Up
// Viewing and Control", "Continue with Hermes" with the requested line after a request, the Windows sentence with no
// buttons). Each is a case here, plus one per state. Synthetic data only.

using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenSetupCardStateTests
{
    [Fact]
    public void TheSheetIsScreenControlClosedWithDone()
    {
        Assert.Equal("Screen Control", ScreenSetupSheetModel.Title);
        Assert.Equal("Done", ScreenSetupSheetModel.Close);
    }

    // test11: the control-only card's first look.
    [Fact]
    public void TheControlOnlyCardAsItOpens()
    {
        var card = ScreenSetupSheetModel.Card(() => false, (_, _) => Task.FromResult<ScreenSetupError?>(null), () => Task.FromResult(""));
        var look = card.Look;
        Assert.True(card.ControlOnly);
        Assert.Equal("screen.setup.card.control", look.AutomationId);
        Assert.Equal("Enable Screen Control", look.Heading);
        Assert.Equal("Enable Control with Hermes", look.Primary);
        Assert.Equal("Check Setup", look.Check);
        Assert.True(look.HeadingShown && look.PointsShown && look.ButtonsShown && look.Enabled);
        Assert.False(look.WindowsNoteShown || look.UpdateShown || look.MessageShown || look.ErrorShown);
    }

    // test14: the full card under the screenshots.
    [Fact]
    public void TheFullCardAsItOpens()
    {
        var look = new ScreenSetupCardState(controlOnly: false).Look;
        Assert.Equal("screen.setup.card", look.AutomationId);
        Assert.Equal("Set Up Viewing and Control", look.Heading);
        Assert.Equal("Set Up with Hermes", look.Primary);
        Assert.Equal("Check Setup", look.Check);
    }

    // test14 reopened, and the sheet over a Screen whose bot had setup requested this run.
    [Fact]
    public void RequestedThisRunSaysContinueAndTheRequestedLine()
    {
        var card = ScreenSetupSheetModel.Card(() => true, (_, _) => Task.FromResult<ScreenSetupError?>(null), () => Task.FromResult(""));
        Assert.True(card.Requested);
        Assert.Equal("Continue with Hermes", card.Look.Primary);
        Assert.Equal("Setup was requested in your bot’s chat. Hermes will report any permissions or requirements that still need attention.", card.Look.Message);
        Assert.True(card.Look.MessageShown);
    }

    [Fact]
    public async Task TheSheetAlwaysContinuesAndSaysOpeningWhileItWorks()
    {
        var asked = new List<(bool Requested, bool ControlOnly)>();
        var gate = new TaskCompletionSource<ScreenSetupError?>();
        var card = ScreenSetupSheetModel.Card(() => false, (r, c) => { asked.Add((r, c)); return gate.Task; }, () => Task.FromResult(""));
        var looks = new List<ScreenSetupCardLook>();
        card.Changed += () => looks.Add(card.Look);

        var running = card.SetupAsync();
        Assert.Equal("Opening setup…", card.Look.Primary);
        Assert.False(card.Look.Enabled);
        await card.SetupAsync();   // a second tap while busy does nothing
        gate.SetResult(null);
        await running;

        Assert.Equal([(false, true)], asked);
        Assert.Equal("Continue with Hermes", card.Look.Primary);
        Assert.Equal(ScreenSetupCopy.Requested, card.Look.Message);
        Assert.True(card.Look.Enabled);
        Assert.Equal(["Opening setup…", "Continue with Hermes"], looks.Select(l => l.Primary));
        // The second request continues.
        await card.SetupAsync();
        Assert.Equal([(false, true), (true, true)], asked);
    }

    [Fact]
    public async Task AFailureBeforeTheScreenClosedIsShownAndSaidAndIsNotARequest()
    {
        var said = new List<string>();
        var card = ScreenSetupSheetModel.Card(() => false,
            (_, _) => Task.FromResult<ScreenSetupError?>(new ScreenSetupError(ScreenSetupFailure.NotConnected)), () => Task.FromResult(""));
        card.Announce = said.Add;
        await card.SetupAsync();
        Assert.Equal("This bot’s gateway is no longer connected.", card.Look.Error);
        Assert.True(card.Look.ErrorShown);
        Assert.Equal("Enable Control with Hermes", card.Look.Primary);
        Assert.False(card.Requested);
        Assert.Equal(["This bot’s gateway is no longer connected."], said);
    }

    // test11: Check Setup's lines land in screen.setup.message, one after another.
    [Fact]
    public async Task CheckSetupShowsAndSaysEachLine()
    {
        var lines = new Queue<string>([
            "Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing.",
            "Allow Screen Recording for Hermes HQ Screen on the Mac.",
            "Allow Accessibility for Hermes HQ Screen on the Mac to use control.",
            "Viewing and control are ready. Open Screen, then tap Take Control to use the pointer and keyboard.",
        ]);
        var said = new List<string>();
        var card = ScreenSetupSheetModel.Card(() => false, (_, _) => Task.FromResult<ScreenSetupError?>(null), () => Task.FromResult(lines.Dequeue()));
        card.Announce = said.Add;
        var seen = new List<string>();
        for (var i = 0; i < 4; i++)
        {
            await card.CheckAsync();
            seen.Add(card.Look.Message);
            Assert.True(card.Look.MessageShown);
            Assert.Equal("Check Setup", card.Look.Check);
        }
        Assert.Equal(said, seen);
        Assert.Equal("Viewing and control are ready. Open Screen, then tap Take Control to use the pointer and keyboard.", seen[^1]);
    }

    [Fact]
    public async Task CheckingSaysCheckingAndHoldsBothButtons()
    {
        var gate = new TaskCompletionSource<string>();
        var card = ScreenSetupSheetModel.Card(() => false, (_, _) => Task.FromResult<ScreenSetupError?>(null), () => gate.Task);
        var running = card.CheckAsync();
        Assert.Equal("Checking…", card.Look.Check);
        Assert.False(card.Look.Enabled);   // both buttons held (the Swift's `isEnabled = !busy && !checking`)
        await card.CheckAsync();   // a second check while one runs does nothing
        gate.SetResult("Screen sharing is not enabled on the Mac yet.");
        await running;
        Assert.True(card.Look.Enabled);
        Assert.Equal("Screen sharing is not enabled on the Mac yet.", card.Look.Message);
    }

    [Fact]
    public async Task ACheckThatFailsShowsItsWordsInTheErrorLineAndKeepsTheLastLine()
    {
        var first = true;
        var card = ScreenSetupSheetModel.Card(() => false, (_, _) => Task.FromResult<ScreenSetupError?>(null), () =>
        {
            if (first) { first = false; return Task.FromResult("Screen sharing is not enabled on the Mac yet."); }
            throw new InvalidOperationException("The gateway took too long to answer.");
        });
        await card.CheckAsync();
        await card.CheckAsync();
        Assert.Equal("Screen sharing is not enabled on the Mac yet.", card.Look.Message);
        Assert.Equal(ScreenWire.Message(new InvalidOperationException("The gateway took too long to answer.")), card.Look.Error);
        Assert.True(card.Look.ErrorShown);
        // The next try clears the error first.
        first = true;
        await card.CheckAsync();
        Assert.Equal("", card.Look.Error);
        Assert.False(card.Look.ErrorShown);
    }

    // test14's Windows gateway: the sentence alone, no buttons that could do nothing.
    [Fact]
    public void AWindowsGatewayShowsTheSentenceAloneWithNoButtons()
    {
        var card = new ScreenSetupCardState(controlOnly: false) { NeedsUpdate = true };
        card.ShowRequested();
        card.WindowsGateway = true;
        var look = card.Look;
        Assert.True(look.WindowsNoteShown);
        Assert.False(look.HeadingShown || look.PointsShown || look.ButtonsShown || look.UpdateShown || look.MessageShown || look.ErrorShown);
        Assert.Equal("Live screen sharing isn’t available on Windows yet. Your bot’s latest screenshots will appear here.", ScreenSetupCopy.Windows);
    }

    [Fact]
    public void AnOldGatewayAddsTheUpdateLine()
    {
        var card = new ScreenSetupCardState(controlOnly: false);
        var changes = 0;
        card.Changed += () => changes++;
        card.NeedsUpdate = true;
        card.NeedsUpdate = true;   // no change, no redraw
        Assert.Equal(1, changes);
        Assert.True(card.Look.UpdateShown);
        Assert.Equal("Hermes will also check whether your gateway needs an update.", ScreenSetupCopy.Update);
    }

    [Fact]
    public async Task NoHooksDoNothing()
    {
        var card = new ScreenSetupCardState(controlOnly: true);
        await card.SetupAsync();
        await card.CheckAsync();
        Assert.False(card.Busy || card.Checking || card.Requested);
        Assert.Equal("", card.Look.Message);
    }
}
