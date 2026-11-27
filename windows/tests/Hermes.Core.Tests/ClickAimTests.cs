using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-39] The CI walk pointer's aim guard (WIN-30A, ProofWalks `Mouse.Click`): Move To's submenu, which WinUI draws in
/// a window of its own, is the app's and may be clicked (CI run 44993175161 refused it: "the click on tasks.move.sec_work
/// at (740,140) would land on another window (0x8033c)"); another program's window, or another of the app's windows
/// over the point, is still refused.
public class ClickAimTests
{
    private const long Main = 0x10010, Popup = 0x8033c, FileWindow = 0x20020, Other = 0x30030;
    private const int Us = 4242, Them = 777;
    private const uint Overlapped = 0x00CF0000, PopupStyle = ClickAim.WsPopup | 0x02000000, PopupWithCaption = ClickAim.WsPopup | ClickAim.WsCaption;

    [Fact]
    public void TheMainWindowIsAlwaysTheAppsOwn()
    {
        Assert.Equal(AimVerdict.Main, ClickAim.Judge(new(Main, Us, [], Overlapped), Main, Us, inPopup: false));
        Assert.Equal(AimVerdict.Main, ClickAim.Judge(new(Main, Us, [], Overlapped), Main, Us, inPopup: true));
        Assert.Null(ClickAim.Refusal(AimVerdict.Main, "tasks.select.move", 10, 20, Main));
    }

    [Fact]
    public void AMenuInAWindowOfItsOwnIsTheAppsOwnPopup()
    {
        // Owned by the main window (directly or through another popup, a submenu's owner chain).
        Assert.Equal(AimVerdict.OwnPopup, ClickAim.Judge(new(Popup, Us, [Main], PopupStyle), Main, Us, inPopup: true));
        Assert.Equal(AimVerdict.OwnPopup, ClickAim.Judge(new(Popup, Us, [0x8044c, Main], PopupStyle), Main, Us, inPopup: true));
        // Unowned, but a captionless popup window of this process holding the element clicked.
        Assert.Equal(AimVerdict.OwnPopup, ClickAim.Judge(new(Popup, Us, [], PopupStyle), Main, Us, inPopup: true));
        Assert.True(ClickAim.Accepts(AimVerdict.OwnPopup));
        Assert.Null(ClickAim.Refusal(AimVerdict.OwnPopup, "tasks.move.sec_work", 740, 140, Popup));
    }

    [Fact]
    public void AnotherProgramsWindowIsRefusedEvenForAPopupsElement()
    {
        var v = ClickAim.Judge(new(Other, Them, [Main], PopupStyle), Main, Us, inPopup: true);
        Assert.Equal(AimVerdict.Foreign, v);
        Assert.False(ClickAim.Accepts(v));
        Assert.Equal("the click on tasks.move.sec_work at (740,140) would land on another window (0x30030)",
            ClickAim.Refusal(v, "tasks.move.sec_work", 740, 140, Other));
        Assert.Equal(AimVerdict.Foreign, ClickAim.Judge(new(0, 0, [], 0), Main, Us, inPopup: true));   // nothing found there
    }

    [Fact]
    public void AnotherOfTheAppsWindowsOverThePointIsRefused()
    {
        // The window's own content under a file window of the app: refused, popup or not.
        Assert.Equal(AimVerdict.OtherAppWindow, ClickAim.Judge(new(FileWindow, Us, [], Overlapped), Main, Us, inPopup: false));
        Assert.Equal(AimVerdict.OtherAppWindow, ClickAim.Judge(new(Popup, Us, [Main], PopupStyle), Main, Us, inPopup: false));
        Assert.Equal(AimVerdict.OtherAppWindow, ClickAim.Judge(new(FileWindow, Us, [], Overlapped), Main, Us, inPopup: true));
        Assert.Equal(AimVerdict.OtherAppWindow, ClickAim.Judge(new(FileWindow, Us, [], PopupWithCaption), Main, Us, inPopup: true));
        Assert.Equal("the click on shell.account at (5,6) would land on another of the app's windows (0x20020)",
            ClickAim.Refusal(AimVerdict.OtherAppWindow, "shell.account", 5, 6, FileWindow));
    }
}
