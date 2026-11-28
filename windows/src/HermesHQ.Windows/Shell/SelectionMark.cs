using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Shell;

/// [WIN-49] The Mac's one selection mark (App/Mac/MacSelection.swift; numbers in Hermes.Core.Shell.DesktopLook) on the
/// sidebar's list: a rounded box inset in its row with no leading bar, the chosen-row accent at 24 % (42 % dark) while the
/// sidebar holds the focus (the last click landed in it) and the window is in front, the label's grey (9 %, 14 % dark)
/// otherwise; a press is the grey. WinUI's ListViewItem draws its marks from the list's lightweight-style keys, so the
/// list is given its own brushes under those keys and they are repainted as the focus, the window or the theme changes.
public static class SelectionMark
{
    private static readonly SolidColorBrush Selected = new(), Pressed = new();

    public static DesktopLook.Pane Focus { get; private set; } = DesktopLook.FirstFocus;
    public static bool WindowActive { get; private set; } = true;

    /// The mark the sidebar's chosen row shows now.
    public static DesktopLook.Mark SidebarMark => DesktopLook.Fill(true, false, DesktopLook.Pane.Sidebar, Focus, WindowActive);

    /// The chosen row's fill, as painted.
    public static Windows.UI.Color SelectedColor => Selected.Color;

    private static bool _hooked;

    /// The sidebar's list takes the mark's keys; `sidebar` and `detail` are where a click moves the focus to.
    public static void Install(ListView list, UIElement sidebar, UIElement detail)
    {
        var keys = list.Resources;
        keys["ListViewItemSelectionIndicatorVisualEnabled"] = DesktopLook.LeadingIndicator;
        keys["ListViewItemBackgroundSelected"] = Selected;
        keys["ListViewItemBackgroundSelectedPointerOver"] = Selected;
        keys["ListViewItemBackgroundSelectedPressed"] = Selected;
        keys["ListViewItemBackgroundPressed"] = Pressed;
        keys["ListViewItemBackgroundSelectedDisabled"] = Selected;
        sidebar.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => SetFocus(DesktopLook.Pane.Sidebar)), true);
        detail.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => SetFocus(DesktopLook.Pane.Detail)), true);
        if (!_hooked)
        {
            _hooked = true;
            ThemeService.Changed += Paint;
            if (App.Window is { } window)
                window.Activated += (_, e) => { if (!Services.AppShutdown.Stopping) SetWindowActive(e.WindowActivationState != WindowActivationState.Deactivated); };
        }
        Paint();
    }

    /// A pane takes the focus without a click (a place chosen by Ctrl+1…9: `MacSelection.focus(on:)`).
    public static void SetFocus(DesktopLook.Pane pane)
    {
        if (pane == Focus) return;
        Focus = pane;
        Paint();
    }

    public static void SetWindowActive(bool active)
    {
        if (active == WindowActive) return;
        WindowActive = active;
        Paint();
    }

    /// The row's box: role-scaled control corner (`ThemeState.ShapeRadius(ShapeRole.Control, 6)`), 2 over and under it
    /// (its side room is the sidebar's own 8 padding).
    public static void Shape(ListViewItem row)
    {
        row.CornerRadius = new CornerRadius(ThemeService.State.ShapeRadius(ShapeRole.Control, 6));
        row.Margin = new Thickness(0, DesktopLook.MarkInsetTop, 0, DesktopLook.MarkInsetBottom);
    }

    private static void Paint()
    {
        if (Services.AppShutdown.Stopping) return;
        var tokens = ThemeService.Tokens;
        var dark = ThemeService.Dark;
        var grey = DesktopLook.Grey(tokens.Label, dark);
        Selected.Color = ThemeService.ToColor(SidebarMark == DesktopLook.Mark.Accent ? DesktopLook.Accent(tokens.ChosenRow, dark) : grey);
        Pressed.Color = ThemeService.ToColor(grey);
    }
}
