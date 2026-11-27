namespace Hermes.Core.Shell;

/// [WIN-39] What the CI walk's pointer would hit (HermesHQ.Windows/Services/ProofWalks.cs `Mouse.Click`, the WIN-30A aim
/// guard): the top-level window under the point, its process, its owner chain and its style. A menu or submenu that
/// WinUI draws in a window of its own (Move To › Work) is the app's: same process, owned by the main window, or a
/// captionless popup window holding the element clicked. Anything else is refused rather than clicked: another
/// program's window, or another of the app's own windows (a file window) lying over the point.
public sealed record AimTarget(long Window, int ProcessId, IReadOnlyList<long> Owners, uint Style);

public enum AimVerdict { Main, OwnPopup, OtherAppWindow, Foreign }

public static class ClickAim
{
    public const uint WsPopup = 0x80000000, WsCaption = 0x00C00000;

    /// `under`: the window at the point. `main`: the app's main window. `inPopup`: the element clicked is in an open
    /// popup (a flyout, a menu, a submenu), not the window's own content.
    public static AimVerdict Judge(AimTarget under, long main, int ourProcess, bool inPopup)
    {
        if (under.Window == main) return AimVerdict.Main;
        if (under.Window == 0 || under.ProcessId != ourProcess) return AimVerdict.Foreign;
        if (!inPopup) return AimVerdict.OtherAppWindow;
        if (under.Owners.Contains(main)) return AimVerdict.OwnPopup;
        return (under.Style & WsPopup) != 0 && (under.Style & WsCaption) != WsCaption ? AimVerdict.OwnPopup : AimVerdict.OtherAppWindow;
    }

    public static bool Accepts(AimVerdict v) => v is AimVerdict.Main or AimVerdict.OwnPopup;

    /// The refusal's words, or null when the click may go.
    public static string? Refusal(AimVerdict v, string id, int x, int y, long window) => v switch
    {
        AimVerdict.Foreign => $"the click on {id} at ({x},{y}) would land on another window (0x{window:x})",
        AimVerdict.OtherAppWindow => $"the click on {id} at ({x},{y}) would land on another of the app's windows (0x{window:x})",
        _ => null,
    };
}
