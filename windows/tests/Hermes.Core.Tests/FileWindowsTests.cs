using Hermes.Core.Artifacts;

namespace Hermes.Core.Tests;

/// Files, bot pages and notes in a window of their own, as App/Mac/MacFileWindow.swift and HermesKit/Layout/WindowFit.swift
/// (93f984bb1) decide them. Synthetic paths only.
public class FileWindowsTests
{
    private sealed class Win(string key) { public string Key { get; } = key; }

    private static bool Exists(string _) => true;

    [Fact]
    public void TheCouldntOpenWordsAreTheMacs()
    {
        Assert.Equal("Couldn’t Open File", FileWindowWords.CouldntOpenTitle);
        Assert.Equal("“report.pdf” is no longer on this PC. Click it again to download it.", FileWindowWords.Gone("report.pdf"));
        Assert.Equal("“report.pdf” didn’t open in a window of its own. Click it again to try once more.", FileWindowWords.DidntOpen("report.pdf"));
        Assert.Equal("Open in Excel", FileWindowWords.OpenIn("Excel"));
        Assert.Equal("Open in Default App", FileWindowWords.OpenIn(null));
        Assert.Equal("Open in Default App", FileWindowWords.OpenIn("  "));
        Assert.Equal("Excel didn’t open it. Share… or Save As… still can.", FileWindowWords.AppDidntOpen("Excel"));
        Assert.Equal("Close Window", FileWindowWords.CloseWindow);
        Assert.Equal("Close", FileWindowWords.Close);
    }

    [Fact]
    public void TheSameFileOpenedAgainBringsItsWindowForward()
    {
        var windows = new FileWindowRegistry<Win>();
        var made = 0;
        var first = windows.OpenFile("/Users/me/cache/a1/budget.csv", "budget.csv", Exists, k => { made++; return new Win(k); });
        Assert.Equal(FileWindowOutcome.Opened, first.Outcome);
        var again = windows.OpenFile("/Users/me/cache/a1/./budget.csv", "budget.csv", Exists, k => { made++; return new Win(k); });
        Assert.Equal(FileWindowOutcome.BroughtForward, again.Outcome);
        Assert.Same(first.Window, again.Window);
        Assert.Equal(1, made);
        Assert.Equal(1, windows.Count);
    }

    [Fact]
    public void AnotherFileGetsAWindowOfItsOwn()
    {
        var windows = new FileWindowRegistry<Win>();
        windows.OpenFile("/Users/me/cache/a1/budget.csv", "budget.csv", Exists, k => new Win(k));
        var other = windows.OpenFile("/Users/me/cache/b2/notes.pdf", "notes.pdf", Exists, k => new Win(k));
        Assert.Equal(FileWindowOutcome.Opened, other.Outcome);
        Assert.Equal(2, windows.Count);
    }

    [Fact]
    public void AFileKeyIgnoresCaseAndSlashesLikeNtfs()
    {
        Assert.Equal(FileWindowKey.File("/Users/me/Cache/Report.PDF"), FileWindowKey.File("/users/me/cache/report.pdf"));
        Assert.Equal(FileWindowKey.File("/Users/me/cache/x/../report.pdf"), FileWindowKey.File("/Users/me/cache/report.pdf"));
        Assert.NotEqual(FileWindowKey.File("/Users/me/report.pdf"), FileWindowKey.Page(null, "/Users/me/report.pdf"));
    }

    [Fact]
    public void APageIsNamedByItsPathOnTheBotsComputer()
    {
        // HTMLPageSheet.present: key = source?.path ?? url.standardizedFileURL.path; MarkdownFileSheet: gateway?.path ?? url path.
        Assert.Equal("page:/home/otto/out/plan.html", FileWindowKey.Page("/home/otto/out/plan.html", "/Users/me/cache/1/plan.html"));
        Assert.Equal(FileWindowKey.Page(null, "/Users/me/cache/1/plan.html"), FileWindowKey.Page("", "/Users/me/cache/1/Plan.html"));
        // The bot's computer may care about case: two pages there are two windows.
        Assert.NotEqual(FileWindowKey.Page("/home/otto/A.html", null), FileWindowKey.Page("/home/otto/a.html", null));
    }

    [Fact]
    public void ThePageOpenedAgainTakesTheWindowItHas()
    {
        var windows = new FileWindowRegistry<Win>();
        var key = FileWindowKey.Page("/home/otto/out/plan.html", null);
        var first = windows.OpenPage(key, "Trip plan", k => new Win(k));
        var again = windows.OpenPage(key, "Trip plan", _ => throw new InvalidOperationException("no second window"));
        Assert.Equal(FileWindowOutcome.Opened, first.Outcome);
        Assert.Equal(FileWindowOutcome.BroughtForward, again.Outcome);
        Assert.Same(first.Window, again.Window);
        Assert.Equal(key, windows.KeyOf(first.Window!));
    }

    [Fact]
    public void AFileGoneFromThisPcSaysSoAndOpensNothing()
    {
        var windows = new FileWindowRegistry<Win>();
        var shown = windows.OpenFile("/Users/me/cache/a1/budget.csv", "budget.csv", Exists, k => new Win(k));
        var gone = windows.OpenFile("/Users/me/cache/a1/budget.csv", "budget.csv", _ => false, _ => throw new InvalidOperationException());
        Assert.Equal(FileWindowOutcome.Gone, gone.Outcome);
        Assert.Null(gone.Window);
        Assert.Equal("“budget.csv” is no longer on this PC. Click it again to download it.", gone.Alert);
        Assert.Same(shown.Window, windows.Find(FileWindowKey.File("/Users/me/cache/a1/budget.csv")));
    }

    [Fact]
    public void AWindowThatDidntComeSaysSoAndIsntKept()
    {
        var windows = new FileWindowRegistry<Win>();
        var failed = windows.OpenFile("/Users/me/cache/a1/deck.pptx", "deck.pptx", Exists, _ => throw new InvalidOperationException("refused"));
        Assert.Equal(FileWindowOutcome.Failed, failed.Outcome);
        Assert.Equal("“deck.pptx” didn’t open in a window of its own. Click it again to try once more.", failed.Alert);
        Assert.Equal(0, windows.Count);
        var page = windows.OpenPage(FileWindowKey.Page("/home/otto/p.html", null), "Weekly page", _ => throw new InvalidOperationException());
        Assert.Equal("“Weekly page” didn’t open in a window of its own. Click it again to try once more.", page.Alert);
        // Clicked again: tries once more.
        Assert.Equal(FileWindowOutcome.Opened, windows.OpenFile("/Users/me/cache/a1/deck.pptx", "deck.pptx", Exists, k => new Win(k)).Outcome);
    }

    [Fact]
    public void AClosedWindowLeavesSoTheNextClickOpensANewOne()
    {
        var windows = new FileWindowRegistry<Win>();
        var first = windows.OpenFile("/Users/me/cache/a1/budget.csv", "budget.csv", Exists, k => new Win(k)).Window!;
        windows.Closed(first);
        Assert.Equal(0, windows.Count);
        var next = windows.OpenFile("/Users/me/cache/a1/budget.csv", "budget.csv", Exists, k => new Win(k));
        Assert.Equal(FileWindowOutcome.Opened, next.Outcome);
        Assert.NotSame(first, next.Window);
    }

    [Fact]
    public void ANewRegistryHoldsNoWindowsSoNoneReopensAtLaunch()
    {
        // MacFileWindow.forgetRestored: nothing about file windows is kept between launches.
        Assert.Equal(0, new FileWindowRegistry<Win>().Count);
    }

    [Theory]
    [InlineData(FileWindowKeyPress.CtrlW, true, false, FileWindowKeyAction.CloseWindow)]
    [InlineData(FileWindowKeyPress.Escape, true, false, FileWindowKeyAction.CloseWindow)]
    [InlineData(FileWindowKeyPress.Escape, true, true, FileWindowKeyAction.CloseWhatIsOver)]
    [InlineData(FileWindowKeyPress.CtrlW, true, true, FileWindowKeyAction.Nothing)]
    [InlineData(FileWindowKeyPress.CtrlW, false, false, FileWindowKeyAction.MainWindow)]
    [InlineData(FileWindowKeyPress.Escape, false, true, FileWindowKeyAction.MainWindow)]
    public void CtrlWAndEscapeCloseTheFileWindowNotTheChat(FileWindowKeyPress press, bool inFront, bool over, FileWindowKeyAction expected) =>
        Assert.Equal(expected, FileWindowKeys.Route(press, inFront, over));

    [Theory]
    [InlineData("plan.html", 10, FileWindowShows.Page)]
    [InlineData("PLAN.HTM", 10, FileWindowShows.Page)]
    [InlineData("notes.md", 10, FileWindowShows.Note)]
    [InlineData("notes.markdown", 10, FileWindowShows.Note)]
    [InlineData("huge.md", 3 << 20, FileWindowShows.OwnApp)]
    [InlineData("report.pdf", 10, FileWindowShows.Pdf)]
    [InlineData("run.log", 10, FileWindowShows.Text)]
    [InlineData("big.log", 3 << 20, FileWindowShows.OwnApp)]
    [InlineData("budget.xlsx", 10, FileWindowShows.OwnApp)]
    [InlineData("README", 10, FileWindowShows.OwnApp)]
    public void WhatAFileOpensIn(string name, long bytes, FileWindowShows expected) =>
        Assert.Equal(expected, FileWindowRoute.For(name, bytes));

    [Fact]
    public void AFileWindowIsTheMainWindowLessALittleDownAndRightOfIt()
    {
        var main = new WindowFrame(100, 80, 1200, 900);
        var frame = FileWindowPlacement.Frame(main, [], new WindowFrame(0, 0, 2560, 1400));
        Assert.Equal(new WindowFrame(140, 110, 1120, 840), frame);
        // At least 900 × 680, at most 1,400 × 1,000.
        Assert.Equal(new WindowFrame(140, 110, 900, 680), FileWindowPlacement.Frame(main with { Width = 700, Height = 500 }, [], null));
        Assert.Equal(new WindowFrame(140, 110, 1400, 1000), FileWindowPlacement.Frame(main with { Width = 2400, Height = 1300 }, [], null));
        // At 150 % the same in pixels.
        Assert.Equal(new WindowFrame(160, 125, 1680, 1260), FileWindowPlacement.Frame(new WindowFrame(100, 80, 1800, 1350), [], null, scale: 1.5));
    }

    [Fact]
    public void ASecondFileNeverOpensExactlyOverTheFirst()
    {
        var main = new WindowFrame(100, 80, 1200, 900);
        var visible = new WindowFrame(0, 0, 2560, 1400);
        var second = FileWindowPlacement.Frame(main, [(140, 110)], visible);
        Assert.Equal(new WindowFrame(168, 138, 1120, 840), second);
        var third = FileWindowPlacement.Frame(main, [(140, 110), (168, 138)], visible);
        Assert.Equal((196.0, 166.0), (third.X, third.Y));
    }

    [Fact]
    public void ACascadePastTheScreensFootStartsAgainNearTheTopLeft()
    {
        var visible = new WindowFrame(0, 0, 1300, 1000);
        var frame = new WindowFrame(140, 150, 1120, 840);
        var placed = FileWindowPlacement.Cascaded(frame, [(140, 150)], visible);
        Assert.Equal(new WindowFrame(28, 28, 1120, 840), placed);
        Assert.Equal(new WindowFrame(0, 0, 800, 600), FileWindowPlacement.Inside(new WindowFrame(-50, -20, 800, 600), visible));
        Assert.Equal(new WindowFrame(0, 0, 1300, 1000), FileWindowPlacement.Inside(new WindowFrame(10, 10, 1500, 1200), visible));
    }

    [Fact]
    public void TheOtherAppGetsACopyInAFolderOfItsOwn()
    {
        var id = Guid.Parse("00000000-0000-0000-0000-0000000000ab");
        Assert.Equal(Path.Combine("/tmp/hq", "Opened", "000000000000000000000000000000ab", "budget.xlsx"), FileWindowCopies.ForOtherApp("/tmp/hq", "budget.xlsx", id));
        Assert.Equal(Path.Combine("/tmp/hq", "Opened", "000000000000000000000000000000ab", "evil.txt"), FileWindowCopies.ForOtherApp("/tmp/hq", "../../evil.txt", id));
        Assert.Equal(Path.Combine("/tmp/hq", "Opened", "000000000000000000000000000000ab", "a_b.txt"), FileWindowCopies.ForOtherApp("/tmp/hq", "a:b.txt", id));
        Assert.EndsWith("file", FileWindowCopies.ForOtherApp("/tmp/hq", "..", id));
    }
}
