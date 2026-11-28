using System.Numerics;
using Hermes.Core.Settings;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace HermesHQ.Shell;

/// Layered frosted-glass outer window shell & floating inset content canvas helper for Windows
/// (App/Mac/MacGlassShell.swift `42b8c3557`, `4057e2d30`, `e2f3aaf39`).
/// Switches `Window.SystemBackdrop` between DesktopAcrylic/Mica and solid `null` fallback per
/// `WindowTransparency.IsEffective(reduceTransparency)`, and paints the floating inset rounded canvas card.
public static class GlassShell
{
    /// Whether the OS Reduce Transparency (Advanced Effects off) or High Contrast mode forces solid surfaces.
    public static bool SystemReduceTransparency
    {
        get
        {
            if (ThemeService.SystemHighContrast) return true;
            try { return !new global::Windows.UI.ViewManagement.UISettings().AdvancedEffectsEnabled; }
            catch { return false; }
        }
    }

    /// Whether live behind-window translucency and subtle canvas glass are active right now.
    public static bool IsTransparencyEffective =>
        !Automation.Enabled && !ThemeService.SystemHighContrast && WindowTransparency.IsEffective(SystemReduceTransparency);

    /// Applies or removes the window's behind-window `SystemBackdrop` and outer shell veil/fallback fill.
    /// Safe to call repeatedly on transparency, theme, or appearance changes.
    public static void ApplyWindowBackdrop(Window? window, Panel? rootGrid = null)
    {
        if (window == null || AppShutdown.Stopping) return;

        var effective = IsTransparencyEffective;
        if (effective)
        {
            if (DesktopAcrylicController.IsSupported())
            {
                if (window.SystemBackdrop is not DesktopAcrylicBackdrop)
                    window.SystemBackdrop = new DesktopAcrylicBackdrop();
            }
            else if (MicaController.IsSupported())
            {
                if (window.SystemBackdrop is not MicaBackdrop)
                    window.SystemBackdrop = new MicaBackdrop();
            }
            else if (window.SystemBackdrop != null)
            {
                window.SystemBackdrop = null;
            }
        }
        else if (window.SystemBackdrop != null)
        {
            window.SystemBackdrop = null;
        }

        if (rootGrid == null || Automation.Enabled) return;
        if (ThemeService.SystemHighContrast)
        {
            rootGrid.Background = ThemeBrushes.Get("SolidBackgroundFillColorBaseBrush");
            return;
        }
        rootGrid.Background = new SolidColorBrush(effective ? GlassVeilColor() : FallbackShellColor());
    }

    /// Styles the floating inset rounded content canvas card (`Margin="10,0,10,10"`, `CornerRadius="15"` in Native Look
    /// or `ShapeRadius` in Hermes Look, subtle shadow/border, and translucent or `BackdropPlace.App` surface fill).
    public static void StyleCanvas(Border canvas, Brush? appBackdrop = null, UIElement? shadowReceiver = null)
    {
        if (AppShutdown.Stopping) return;

        double inset = WindowTransparency.CanvasInset;
        double corner = ThemeService.State.ShapeRadius(ShapeRole.Card, WindowTransparency.CanvasCornerRadius);

        canvas.Margin = new Thickness(inset, 0, inset, inset);
        canvas.CornerRadius = new CornerRadius(corner);
        canvas.BorderThickness = new Thickness(1);
        canvas.BorderBrush = ThemeService.SystemHighContrast
            ? ThemeBrushes.Get("CardStrokeColorDefaultBrush")
            : new SolidColorBrush(CanvasBorderColor());
        canvas.Background = appBackdrop ?? CanvasSurfaceBrush();

        if (shadowReceiver != null && !ThemeService.SystemHighContrast)
        {
            try
            {
                if (canvas.Shadow is not ThemeShadow shadow)
                {
                    shadow = new ThemeShadow();
                    canvas.Shadow = shadow;
                }
                if (!shadow.Receivers.Contains(shadowReceiver))
                    shadow.Receivers.Add(shadowReceiver);
                canvas.Translation = new Vector3(0, 0, 16);
            }
            catch (Exception ex) { AppLog.Note("shell", $"canvas shadow skipped: {ex.GetType().Name}"); }
        }
        else if (canvas.Shadow != null)
        {
            canvas.Shadow = null;
            canvas.Translation = Vector3.Zero;
        }
    }

    /// Styles the outer sidebar pane: transparent over the live behind-window glass shell when transparency is effective,
    /// or the solid `HQSidebarPanelBrush` fallback when transparency is off or during automation shots.
    public static void StyleSidebar(Panel sidebar)
    {
        if (AppShutdown.Stopping) return;
        sidebar.Background = IsTransparencyEffective
            ? new SolidColorBrush(Colors.Transparent)
            : ThemeBrushes.Get("HQSidebarPanelBrush");
    }

    /// Unified subtly translucent surface brush for the floating content canvas (`MacGlassShell.canvasSurfaceColor`).
    public static Brush CanvasSurfaceBrush()
    {
        if (ThemeService.SystemHighContrast || !IsTransparencyEffective)
            return ThemeBrushes.Get("HQPageBrush");

        return new SolidColorBrush(ThemeService.ToColor(
            WindowTransparency.CanvasSurfaceColor(ThemeService.Set, ThemeService.Dark, transparent: true)));
    }

    /// Near-solid frosted veil behind a titled page bar once rows scroll beneath it (`MacGlassShell.canvasPageBarVeilColor`).
    public static Brush PageBarVeilBrush()
    {
        if (ThemeService.SystemHighContrast || !IsTransparencyEffective)
            return ThemeBrushes.Get("HQPageBrush");

        return new SolidColorBrush(ThemeService.ToColor(
            WindowTransparency.CanvasPageBarVeilColor(ThemeService.Set, ThemeService.Dark)));
    }

    /// Soft neutral fallback color when Reduce Transparency or Window Transparency off is active (`MacGlassShell.fallbackShellColor`).
    public static Color FallbackShellColor() =>
        ThemeService.ToColor(WindowTransparency.FallbackShellColor(ThemeService.Set, ThemeService.Dark));

    /// Light translucent tint over the behind-window backdrop so the outer sidebar & top bar read as frosted glass
    /// while staying readable over any desktop wallpaper (`MacGlassShell.glassVeilColor`).
    public static Color GlassVeilColor() =>
        ThemeService.ToColor(WindowTransparency.GlassVeilColor(ThemeService.Set, ThemeService.Dark));

    /// Crisp 1px glass seam separating the floating canvas card from the translucent outer shell (`MacGlassShell.canvasBorderColor`).
    public static Color CanvasBorderColor() =>
        ThemeService.ToColor(WindowTransparency.CanvasBorderColor(ThemeService.Dark));
}
