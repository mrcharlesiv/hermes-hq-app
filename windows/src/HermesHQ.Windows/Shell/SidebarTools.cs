using Hermes.Core.Shell;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Shell;

/// [mac-layout] The sidebar's top (App/Mac/MacBotsRail.swift `MacSidebarTools`): Search, which opens Open Quickly as
/// Ctrl+K does, and New Chat (Ctrl+N). Open, a field-like well (glass, "Search", the quiet "Ctrl+K") beside New Chat's
/// square well, each lighter under the pointer; folded into the rail, named or not, the two small and quiet side by side
/// with a hairline under them ([rail-actions]). Made again when the sidebar folds or opens, as the Mac makes it again.
/// Sizes, words and inks are `Hermes.Core.Shell.SidebarSearch`.
public static class SidebarTools
{
    private const string Glass = "\uE721", Pencil = "\uE70F";

    /// The row for the open sidebar or the rail. `openQuickly` is the shell's own Ctrl+K action; `newChat` its Ctrl+N.
    public static FrameworkElement Build(bool rail, Action openQuickly, Action newChat)
    {
        var search = new Button { Padding = new Thickness(0), BorderThickness = new Thickness(0) };
        AutomationProperties.SetAutomationId(search, SidebarSearch.SearchAutomationId);
        AutomationProperties.SetName(search, SidebarSearch.SearchName);
        ToolTipService.SetToolTip(search, SidebarSearch.SearchToolTip);
        search.Click += (_, _) => openQuickly();

        var compose = new Button { Padding = new Thickness(0), BorderThickness = new Thickness(0) };
        AutomationProperties.SetAutomationId(compose, SidebarSearch.ComposeAutomationId);
        AutomationProperties.SetName(compose, SidebarSearch.ComposeName);
        ToolTipService.SetToolTip(compose, SidebarSearch.ComposeToolTip);
        compose.Click += (_, _) => newChat();

        FrameworkElement row = SidebarSearch.Layout(rail) switch
        {
            SidebarSearch.Arrangement.SideBySideWithRule => Folded(search, compose),
            _ => Open(search, compose),
        };
        AutomationProperties.SetAutomationId(row, SidebarSearch.ToolsAutomationId);
        return row;
    }

    /// Open: Search fills the row, New Chat a square after it; both wells, 2 above and 6 below.
    private static Grid Open(Button search, Button compose)
    {
        var side = SidebarSearch.OpenSide;
        var row = new Grid { ColumnSpacing = SidebarSearch.OpenGap, Margin = new Thickness(0, SidebarSearch.OpenTop, 0, SidebarSearch.OpenBottom) };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        Well(search);
        search.Height = side;
        search.HorizontalAlignment = HorizontalAlignment.Stretch;
        search.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        search.VerticalContentAlignment = VerticalAlignment.Stretch;
        // The glass in the places' icon column, "Search" where their names start, the hint at the trailing end.
        var inside = new Grid { ColumnSpacing = 12, Padding = new Thickness(10, 0, SidebarSearch.HintTrailing, 0) };
        inside.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(15) });
        inside.ColumnDefinitions.Add(new ColumnDefinition());
        inside.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var glass = new FontIcon
        {
            Glyph = Glass, FontSize = SidebarSearch.GlassSize, Foreground = Res("HQLabel2Brush"),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        var word = new TextBlock
        {
            Text = SidebarSearch.SearchName, FontSize = SidebarSearch.WordSize, Foreground = Res("HQLabel2Brush"),
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(word, 1);
        var hint = new TextBlock
        {
            Text = SidebarSearch.SearchHint, FontSize = SidebarSearch.HintSize, Foreground = Res("HQLabelBrush"),
            Opacity = SidebarSearch.QuietInk, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(SidebarSearch.HintGap - 12, 0, 0, 0),
        };
        Grid.SetColumn(hint, 2);
        inside.Children.Add(glass);
        inside.Children.Add(word);
        inside.Children.Add(hint);
        search.Content = inside;
        DimsWhenPressed(search, glass, word, hint);
        row.Children.Add(search);

        Well(compose);
        compose.Width = side;
        compose.Height = side;
        compose.Content = new FontIcon { Glyph = Pencil, FontSize = SidebarSearch.ComposeGlyphSize(rail: false), Foreground = Res("HQLabelBrush") };
        Grid.SetColumn(compose, 1);
        row.Children.Add(compose);
        return row;
    }

    /// Folded: the two side by side about the rail's centre, 2 apart, quieter than the places; the hairline 7 under them,
    /// 2 in from their outer edges, then 8 before the places.
    private static StackPanel Folded(Button search, Button compose)
    {
        var side = SidebarSearch.RailSide;
        foreach (var b in new[] { search, compose })
        {
            b.Style = (Style)Application.Current.Resources["QuietButtonStyle"];
            b.Padding = new Thickness(0);
            b.Width = side;
            b.Height = side;
        }
        search.Content = new FontIcon { Glyph = Glass, FontSize = SidebarSearch.RailGlassSize, Foreground = Res("HQLabel2Brush") };
        compose.Content = new FontIcon { Glyph = Pencil, FontSize = SidebarSearch.ComposeGlyphSize(rail: true), Foreground = Res("HQLabel2Brush") };
        var pair = new StackPanel { Orientation = Orientation.Horizontal, Spacing = SidebarSearch.RailGap, HorizontalAlignment = HorizontalAlignment.Center };
        pair.Children.Add(search);
        pair.Children.Add(compose);
        var rule = new Rectangle
        {
            Height = 1, Width = SidebarSearch.RailRowWidth - 2 * SidebarSearch.RuleInset, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, SidebarSearch.RuleGap, 0, SidebarSearch.RuleBottom),
        };
        void Paint() => rule.Fill = Ink(rule.ActualTheme == ElementTheme.Dark, SidebarSearch.RuleAlpha(rule.ActualTheme == ElementTheme.Dark));
        rule.Loaded += (_, _) => Paint();
        rule.ActualThemeChanged += (_, _) => Paint();
        var column = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        column.Children.Add(pair);
        column.Children.Add(rule);
        return column;
    }

    /// A well: label ink at 6 % (white at 8 % dark), 10 % (13 %) under the pointer and while pressed; corners 9 (7 here).
    private static void Well(Button button)
    {
        button.CornerRadius = new CornerRadius(SidebarSearch.WellCorner);
        var resources = new ResourceDictionary();
        foreach (var (theme, dark) in new[] { ("Light", false), ("Dark", true) })
        {
            var d = new ResourceDictionary
            {
                ["ButtonBackground"] = Ink(dark, SidebarSearch.WellAlpha(dark)),
                ["ButtonBackgroundPointerOver"] = Ink(dark, SidebarSearch.WellHoverAlpha(dark)),
                ["ButtonBackgroundPressed"] = Ink(dark, SidebarSearch.WellHoverAlpha(dark)),
                ["ButtonBorderBrush"] = new SolidColorBrush(Colors.Transparent),
                ["ButtonBorderBrushPointerOver"] = new SolidColorBrush(Colors.Transparent),
                ["ButtonBorderBrushPressed"] = new SolidColorBrush(Colors.Transparent),
            };
            resources.ThemeDictionaries[theme] = d;
        }
        button.Resources = resources;
    }

    private static SolidColorBrush Ink(bool dark, double alpha)
    {
        var v = (byte)(dark ? 255 : 0);
        return new SolidColorBrush(ColorHelper.FromArgb((byte)Math.Round(alpha * 255), v, v, v));
    }

    /// A press dims the glass, the word and the hint to half (the Mac's configurationUpdateHandler); the hint keeps its
    /// own quietness under that.
    private static void DimsWhenPressed(Button button, params FrameworkElement[] ink)
    {
        var rest = ink.Select(e => e.Opacity).ToArray();
        void Set(bool pressed)
        {
            for (var i = 0; i < ink.Length; i++) ink[i].Opacity = rest[i] * (pressed ? SidebarSearch.PressedInk : 1);
        }
        button.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => Set(true)), true);
        foreach (var e in new[] { UIElement.PointerReleasedEvent, UIElement.PointerCanceledEvent, UIElement.PointerCaptureLostEvent, UIElement.PointerExitedEvent })
            button.AddHandler(e, new PointerEventHandler((_, _) => Set(false)), true);
    }

    private static Brush Res(string key) => ThemeBrushes.Get(key);
}
