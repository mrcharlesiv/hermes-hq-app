using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Layered desktop window transparency preference and glass surface colors (App/Mac/MacGlassShell.swift `e2f3aaf39`).
/// On by default unless turned off in Settings › Appearance › Look › Window Transparency or overridden by system
/// Reduce Transparency. Kept on this PC only (`hqn.macWindowTransparency`).
public static class WindowTransparency
{
    public const string PrefKey = "hqn.macWindowTransparency";
    public const string Label = "Window Transparency";
    public const string RowTarget = "row:window-transparency";
    public const string AutomationId = "settings.window-transparency";
    public const string Note = "Window Transparency lets your desktop show softly through the window.";
    public const string ReduceTransparencyNote = "Window Transparency is off while Reduce Transparency is enabled in Windows Settings.";

    /// Inset between the floating content canvas card and the window's trailing/bottom edges (app pts).
    public const double CanvasInset = 10;
    /// Continuous corner radius of the floating content canvas card (app pts).
    public const double CanvasCornerRadius = 15;
    /// Height of the unified top chrome / workspace tab bar (app pts).
    public const double TopBarHeight = 46;

    private static bool _enabled = true;

    public static IPreferences? Store { get; set; }
    public static event Action? Changed;

    /// User preference for window transparency (`true` unless explicitly set to `"false"`).
    public static bool IsEnabled
    {
        get => Store != null ? Read(Store) : _enabled;
        set
        {
            var prev = IsEnabled;
            _enabled = value;
            Write(Store, value);
            if (prev != value) Changed?.Invoke();
        }
    }

    public static bool Read(IPreferences? prefs) => prefs?.Get(PrefKey) != "false";

    public static void Write(IPreferences? prefs, bool enabled) => prefs?.Set(PrefKey, enabled ? null : "false");

    /// Whether live window translucency is active right now (disabled when system Reduce Transparency is on).
    public static bool IsEffective(bool reduceTransparency) => IsEnabled && !reduceTransparency;

    public static void Reset() => IsEnabled = true;

    /// Soft neutral fallback color for the outer shell when transparency is off or Reduce Transparency is active
    /// (`MacGlassShell.fallbackShellColor`).
    public static Rgba FallbackShellColor(ThemeSet set, bool dark)
    {
        if (set.GroupedPageIsSystem)
            return dark ? new(0.10, 0.105, 0.12, 1) : new(0.915, 0.922, 0.938, 1);
        var page = set.Tokens(dark).Page;
        return Adjusted(page, dark ? -0.04 : -0.055);
    }

    /// Light translucent tint over the live behind-window backdrop so the outer sidebar & top bar feel noticeably
    /// more transparent and glassy than the floating content canvas (`MacGlassShell.glassVeilColor`).
    public static Rgba GlassVeilColor(ThemeSet set, bool dark)
    {
        if (set.GroupedPageIsSystem)
            return dark ? new(0.04, 0.048, 0.065, 0.40) : new(0.99, 0.994, 1.0, 0.34);
        var page = set.Tokens(dark).Page;
        return dark ? Adjusted(page, -0.02).Alpha(0.52) : page.Alpha(0.50);
    }

    /// Opaque base tone of the floating content canvas (`MacGlassShell.canvasBaseColor`).
    public static Rgba CanvasBaseColor(ThemeSet set, bool dark)
    {
        var page = set.Tokens(dark).Page;
        if (set.GroupedPageIsSystem)
        {
            if (dark)
            {
                var lift = set.State.DesktopLook ? 0.010 : 0.014;
                return Adjusted(page, lift);
            }
            return Rgba.White;
        }
        return dark ? Adjusted(page, 0.010) : page;
    }

    /// Subtly translucent surface for the floating content canvas (`MacGlassShell.canvasSurfaceColor`).
    /// Solid `Page` when transparency is off; translucent over the glass shell when on.
    public static Rgba CanvasSurfaceColor(ThemeSet set, bool dark, bool transparent)
    {
        if (!transparent) return set.Tokens(dark).Page;
        var @base = CanvasBaseColor(set, dark);
        if (set.GroupedPageIsSystem)
            return @base.Alpha(dark ? 0.76 : 0.84);
        return @base.Alpha(dark ? 0.78 : 0.84);
    }

    public static Rgba CanvasSurfaceColor(ThemeSet set, bool dark) => CanvasSurfaceColor(set, dark, IsEnabled);

    /// Frosted header veil matching `CanvasBaseColor` when scrolled content passes under the chat bar
    /// (`MacGlassShell.canvasBarVeilColor`).
    public static Rgba CanvasBarVeilColor(ThemeSet set, bool dark, bool transparent)
    {
        var @base = transparent ? CanvasBaseColor(set, dark) : set.Tokens(dark).Page;
        return @base.Alpha(transparent ? 0.42 : 1.0);
    }

    public static Rgba CanvasBarVeilColor(ThemeSet set, bool dark) => CanvasBarVeilColor(set, dark, IsEnabled);

    /// Backing a titled page's bar takes inside the glass canvas once rows scroll under it
    /// (`MacGlassShell.canvasPageBarVeilColor`).
    public static Rgba CanvasPageBarVeilColor(ThemeSet set, bool dark) =>
        Adjusted(CanvasBaseColor(set, dark), dark ? 0.03 : -0.04).Alpha(0.94);

    /// Crisp glass seam separating the floating canvas card from the translucent outer shell
    /// (`MacGlassShell.canvasBorderColor`).
    public static Rgba CanvasBorderColor(bool dark) =>
        dark ? new(1, 1, 1, 0.115) : new(0, 0, 0, 0.08);

    /// Effective outer shell backdrop color: glass veil when transparent, solid fallback when opaque.
    public static Rgba ShellBackdropColor(ThemeSet set, bool dark, bool transparent) =>
        transparent ? GlassVeilColor(set, dark) : FallbackShellColor(set, dark);

    private static Rgba Adjusted(Rgba color, double delta) =>
        new(Math.Clamp(color.R + delta, 0, 1), Math.Clamp(color.G + delta, 0, 1), Math.Clamp(color.B + delta, 0, 1), color.A);
}
