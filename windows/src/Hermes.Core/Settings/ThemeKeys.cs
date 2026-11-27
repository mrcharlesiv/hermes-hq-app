namespace Hermes.Core.Settings;

/// [WIN-THEME-APP-RESOURCES] Rules for looking a WinUI theme resource up by key in the mode on show. A lookup through
/// `Application.Current.Resources[key]` resolves in the APPLICATION's theme (the system's, fixed at launch), not the
/// window root's RequestedTheme that Settings › Appearance sets: on a light Windows with Appearance › Dark it handed
/// back the light theme's near-black text and light ground (CI run 45095225249, shot 194). The app looks keys up in
/// the theme dictionary named for the mode on show instead (HermesHQ.Windows/Services/ThemeBrushes.cs).
public static class ThemeKeys
{
    /// The theme dictionaries that hold a key in this mode, in the order WinUI reads them: XamlControlsResources keeps
    /// its dark values under "Default", the app's own under "Dark"; a Windows contrast theme is "HighContrast".
    public static IReadOnlyList<string> Dictionaries(bool dark, bool highContrast = false) =>
        highContrast ? ["HighContrast"] : dark ? ["Dark", "Default"] : ["Light"];

    /// The screenshot ground under the window (CI runs only; the live window keeps Mica): WinUI 1.8 generic.xaml's
    /// SolidBackgroundFillColorBase, #202020 in Dark and #F3F3F3 in Light, in the mode on show.
    public static Rgba ShotGround(bool dark) => dark ? Rgba.Hex(0x202020) : Rgba.Hex(0xF3F3F3);
}
