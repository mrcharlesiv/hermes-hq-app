using System.Globalization;
using Hermes.Core.Artifacts;

namespace Hermes.Core.Settings;

/// [mac-layout] Settings in a window of its own (App/Mac/MacSettingsWindow.swift, 93f984bb1): Ctrl+, (the Mac's ⌘,),
/// the sidebar foot's gear and Sidebar Settings… open it, or bring it forward when it is open, and it sits beside the
/// main window instead of taking its pane over. Titled "Settings", settings-sized, its frame kept where it was left.
public static class SettingsWindowLayout
{
    /// `windowScene.title = "Settings"`.
    public const string Title = "Settings";

    /// "A settings-sized window (about 860 × 640 pt on the screen …)".
    public const double Width = 860, Height = 640;

    /// `sizeRestrictions.minimumSize = 900 × 600` in the app's own points, which the Mac draws at 77 % (the same
    /// comment's 860 × 640 on the screen): 693 × 462 on the screen.
    public const double MinimumWidth = 693, MinimumHeight = 462;

    /// Where it was left (`MacSettingsWindow.frameKey`, [mac-feel D29]); the app's own preferences file here.
    public const string FrameKey = "hqn.settings.windowFrame";

    /// SettingsSceneDelegate's frame: as it was left (`kept`), else beside the main window (60 right and 40 down of its
    /// top left), else in the middle of the screen; always inside the screen's visible part (`WindowFit.inside`).
    /// `scale`: physical pixels per point, for a main window and screen in pixels.
    public static WindowFrame Frame(WindowFrame? kept, WindowFrame? main, WindowFrame? visible, double scale = 1)
    {
        double w = Width * scale, h = Height * scale;
        var asked = kept
            ?? (main is { } m ? new WindowFrame(m.X + 60 * scale, m.Y + 40 * scale, w, h) : null as WindowFrame?)
            ?? (visible is { IsEmpty: false } v
                ? new WindowFrame(Math.Round(v.X + v.Width / 2 - w / 2), Math.Round(v.Y + v.Height / 2 - h / 2), w, h)
                : new WindowFrame(0, 0, w, h));
        return FileWindowPlacement.Inside(asked, visible);
    }

    /// `WindowFit.encode`: "x,y,width,height" in whole numbers.
    public static string Encode(WindowFrame f) =>
        string.Join(",", new[] { f.X, f.Y, f.Width, f.Height }.Select(n => ((long)Math.Round(n, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture)));

    /// `WindowFit.decode(_, minimum: 320 × 240)`: the frame Encode wrote, or null (nothing kept, damaged, too small).
    public static WindowFrame? Decode(string? text, double minimumWidth = 320, double minimumHeight = 240)
    {
        var parts = text?.Split(',');
        if (parts is not { Length: 4 }) return null;
        var n = new double[4];
        for (var i = 0; i < 4; i++)
            if (!double.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out n[i])) return null;
        if (n[2] < minimumWidth || n[3] < minimumHeight) return null;
        return new WindowFrame(n[0], n[1], n[2], n[3]);
    }
}

/// The one Settings window (MacSettingsWindow.scene): opened, or the open one brought forward; a closed one leaves.
public sealed class SettingsWindowRegistry<T> where T : class
{
    private const string Key = "settings";
    private readonly FileWindowRegistry<T> _one = new();

    public T? Open => _one.Find(Key);
    public int Count => _one.Count;

    /// `make` is called only when none is open; a window that can't be made leaves none (Failed).
    public FileWindowResult<T> Show(Func<T> make) => _one.OpenPage(Key, SettingsWindowLayout.Title, _ => make());

    /// sceneDidDisconnect: the next Ctrl+, opens a new one.
    public void Closed(T window) => _one.Closed(window);
}

public enum SettingsWindowOutcome
{
    /// No main window to read the gateway from (the sign-in form): Settings opens where it did.
    InMainWindow,
    Opened,
    BroughtForward,
}

/// `Show`: the page or row asked for (a Settings link's argument), or null. `BackToIndex`: an open window goes back to
/// its category's own page before it.
public sealed record SettingsWindowStep(SettingsWindowOutcome Outcome, string? Show, bool BackToIndex);

/// MacSettingsWindow.open / open(then:) / openWindow(then:).
public static class SettingsWindowPlan
{
    public static SettingsWindowStep Open(bool hasMainWindow, bool isOpen, string? argument)
    {
        if (!hasMainWindow) return new(SettingsWindowOutcome.InMainWindow, argument, false);
        if (isOpen) return new(SettingsWindowOutcome.BroughtForward, argument, argument != null);
        return new(SettingsWindowOutcome.Opened, argument, false);
    }

    /// [macpass-settings2] The window opens on the category it was closed on (SettingsRootModel.category), else General.
    public static SettingsCategory OpeningCategory(string? last) => SettingsCategories.Parse(last) ?? SettingsCategory.General;
}

public enum SettingsWindowKeyPress { Escape, CtrlW, CtrlComma }

public enum SettingsWindowKeyAction
{
    /// Ctrl+W: the Settings window closes, not the main window's chat.
    CloseWindow,
    /// Escape with a dialog over the window: the dialog takes it.
    LeaveToWhatIsOver,
    /// Escape in Search Settings: the search clears.
    ClearSearch,
    /// Escape on a page over the category's: back a page.
    GoBack,
    /// Held (Ctrl+W or Ctrl+, under a dialog), or Escape with nothing to step back from.
    Nothing,
    /// Ctrl+, in the window: it stays, in front.
    BringForward,
}

/// The keys while the Settings window is in front (KeyCommands.settingsInFront): ⌘W closes it (hqCloseChat), Escape
/// takes one step of the ladder (settingsEscape: a sheet, the search, then back a page) and never closes it, ⌘, opens
/// Settings (it is already here). While a sheet is up only Escape acts.
public static class SettingsWindowKeys
{
    public static SettingsWindowKeyAction Route(SettingsWindowKeyPress press, bool somethingOver, bool searching, bool canGoBack) => press switch
    {
        SettingsWindowKeyPress.Escape when somethingOver => SettingsWindowKeyAction.LeaveToWhatIsOver,
        SettingsWindowKeyPress.Escape when searching => SettingsWindowKeyAction.ClearSearch,
        SettingsWindowKeyPress.Escape => canGoBack ? SettingsWindowKeyAction.GoBack : SettingsWindowKeyAction.Nothing,
        _ when somethingOver => SettingsWindowKeyAction.Nothing,
        SettingsWindowKeyPress.CtrlW => SettingsWindowKeyAction.CloseWindow,
        _ => SettingsWindowKeyAction.BringForward,
    };
}
