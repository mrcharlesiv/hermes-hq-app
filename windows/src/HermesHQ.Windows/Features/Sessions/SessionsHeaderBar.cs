using Hermes.Core.Sessions;
using HermesHQ.Features.Settings;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace HermesHQ.Features.Sessions;

/// What one drawing of the row under Sessions' bar shows: the switch's side, the menu's name and flyout, the counts.
internal sealed record SessionsHeaderInput(
    bool ShowsSwitch, bool ProjectsShown, Action Flip,
    string? MenuTitle, Func<FlyoutBase>? Menu,
    IReadOnlyList<(SessionStatusChip Chip, int Count, bool Picked, Action Pick)> Counts);

/// [WIN-SESSIONS-WORKING-CHIP] The Mac's row under Sessions' bar (93f984bb1 App/Sessions/SessionsHeaderView.swift
/// `macRow`, numbers in Hermes.Core `SessionsHeaderRow`): the Chats | Projects switch at the left, the All Bots / All
/// Projects menu and the New and Working counts at the right, one height, corner and type size. `Fit` draws the four
/// drawings the Mac's `ViewThatFits` tries and keeps the first that fits the pane (the counts' words go first, then the
/// switch's glyphs), so a count is never cut at the pane's edge; in the last only the menu's name gives way.
internal static class SessionsHeaderBar
{
    public const string RowAutomationId = "sessions.header";
    public static string CountAutomationId(SessionStatusChip chip) => "sessions.chip.status." + (chip == SessionStatusChip.New ? "new" : "working");

    private static Brush Ink(Hermes.Core.Settings.Rgba c) => new SolidColorBrush(ThemeService.ToColor(c));

    /// One drawing of the row.
    public static SessionsHeaderRowPanel Build(SessionsHeaderInput input, SessionsHeaderVariant variant)
    {
        var desktop = ThemeService.State.DesktopLook;
        var row = new SessionsHeaderRowPanel { Spacing = variant.Spacing, Height = SessionsHeaderRow.ControlHeight, Variant = variant };
        if (input.ShowsSwitch) row.Switch = Switch(input, variant, desktop);
        if (input.MenuTitle != null && input.Menu != null) row.Menu = Menu(input.MenuTitle, input.Menu, desktop);
        foreach (var c in input.Counts) row.Counts.Add(Count(c.Chip, c.Count, c.Picked, c.Pick, variant, desktop));
        if (row.Switch != null) row.Children.Add(row.Switch);
        if (row.Menu != null) row.Children.Add(row.Menu);
        foreach (var c in row.Counts) row.Children.Add(c);
        AutomationProperties.SetAutomationId(row, RowAutomationId);
        return row;
    }

    /// `SessionsPillsSwitch.macBody`: a click anywhere flips the view; the side shown is a raised grey box.
    private static Button Switch(SessionsHeaderInput input, SessionsHeaderVariant variant, bool desktop)
    {
        var tokens = ThemeService.Tokens;
        var sides = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var projects in new[] { false, true })
        {
            var here = projects == input.ProjectsShown;
            var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = SessionsHeaderRow.SwitchGlyphGap, VerticalAlignment = VerticalAlignment.Center };
            if (variant.SwitchIcons)
                face.Children.Add(new FontIcon { Glyph = projects ? "\uE8B7" : "\uE8F2", FontSize = SessionsHeaderRow.SwitchGlyph, VerticalAlignment = VerticalAlignment.Center });
            face.Children.Add(new TextBlock
            {
                Text = projects ? "Projects" : "Chats", FontSize = SessionsHeaderRow.FontSize(desktop),
                FontWeight = new Windows.UI.Text.FontWeight { Weight = (ushort)(SessionsHeaderRow.ControlWeight) }, VerticalAlignment = VerticalAlignment.Center,
            });
            sides.Children.Add(new Border
            {
                Child = face, Padding = new Thickness(variant.SwitchPadding, 0, variant.SwitchPadding, 0),
                CornerRadius = new CornerRadius(SessionsHeaderRow.SwitchThumbRadius),
                Background = here ? Ink(tokens.Label.Alpha(SessionsHeaderRow.SwitchThumbShare)) : null,
                // Foreground flows to the glyph and the name.
            });
            foreach (var t in face.Children.OfType<TextBlock>()) t.Foreground = Ink(here ? tokens.Label : tokens.Label2);
            foreach (var g in face.Children.OfType<FontIcon>()) g.Foreground = Ink(here ? tokens.Label : tokens.Label2);
        }
        var track = new Border
        {
            Child = sides, Padding = new Thickness(SessionsHeaderRow.SwitchTrack), Height = SessionsHeaderRow.ControlHeight,
            CornerRadius = new CornerRadius(SessionsHeaderRow.ControlRadius), Background = Ink(tokens.Fill3),
        };
        var other = input.ProjectsShown ? "Chats" : "Projects";
        var button = new Button
        {
            Content = track, Padding = new Thickness(0), BorderThickness = new Thickness(0), MinWidth = 0, MinHeight = 0,
            Height = SessionsHeaderRow.ControlHeight, CornerRadius = new CornerRadius(SessionsHeaderRow.ControlRadius),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(button, "Show " + other);
        AutomationProperties.SetName(button, "Switch to " + other);
        AutomationProperties.SetItemStatus(button, input.ProjectsShown ? "Projects" : "Chats");
        AutomationProperties.SetAutomationId(button, "sessions.pills." + (input.ProjectsShown ? "bots" : "projects"));
        button.Click += (_, _) => input.Flip();
        return button;
    }

    /// The view's menu as a Mac pop-up: an outline, its name cut at the tail, a chevron 8 after it.
    private static Button Menu(string title, Func<FlyoutBase> flyout, bool desktop)
    {
        var tokens = ThemeService.Tokens;
        var grid = new Grid { ColumnSpacing = SessionsHeaderRow.MenuChevronGap, VerticalAlignment = VerticalAlignment.Center };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock
        {
            Text = title, FontSize = SessionsHeaderRow.FontSize(desktop), FontWeight = new Windows.UI.Text.FontWeight { Weight = (ushort)(SessionsHeaderRow.ControlWeight) },
            TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, MaxLines = 1, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Ink(tokens.Label),
        });
        var chevron = new FontIcon { Glyph = "\uE70D", FontSize = SessionsHeaderRow.MenuChevron, FontWeight = FontWeights.Bold, Foreground = Ink(tokens.Label2), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 1);
        grid.Children.Add(chevron);
        var button = new Button
        {
            Content = grid, Height = SessionsHeaderRow.ControlHeight, MinHeight = 0, MinWidth = SessionsHeaderRow.MenuMinWidth,
            Padding = new Thickness(SessionsHeaderRow.MenuLeading, 0, SessionsHeaderRow.MenuTrailing, 0),
            CornerRadius = new CornerRadius(SessionsHeaderRow.ControlRadius), BorderThickness = new Thickness(SessionsHeaderRow.MenuStroke),
            BorderBrush = Ink(tokens.StrokePrimary), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(button, title);
        AutomationProperties.SetAutomationId(button, "sessions.scope");
        button.Click += (_, _) => flyout().ShowAt(button);
        return button;
    }

    /// `macStatus`: the mark, the count (with its word in a wide pane), a fill only while picked.
    private static Button Count(SessionStatusChip chip, int count, bool picked, Action pick, SessionsHeaderVariant variant, bool desktop)
    {
        var tokens = ThemeService.Tokens;
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = SessionsHeaderRow.CountMarkGap, VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(Mark(chip));
        content.Children.Add(new TextBlock
        {
            Text = SessionsHeaderRow.CountText(chip, count, variant.CountWords), FontSize = SessionsHeaderRow.FontSize(desktop),
            FontWeight = new Windows.UI.Text.FontWeight { Weight = (ushort)(picked ? SessionsHeaderRow.CountPickedWeight : SessionsHeaderRow.CountWeight) },
            Foreground = Ink(picked ? tokens.Label : tokens.Label2), VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap,
        });
        var button = new Button
        {
            Content = content, Height = SessionsHeaderRow.ControlHeight, MinHeight = 0, MinWidth = 0,
            Padding = new Thickness(variant.CountPadding, 0, variant.CountPadding, 0), BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(SessionsHeaderRow.ControlRadius),
            Background = picked ? Ink(tokens.Fill3) : new SolidColorBrush(Microsoft.UI.Colors.Transparent), VerticalAlignment = VerticalAlignment.Center,
        };
        var noun = chip == SessionStatusChip.New ? "New" : "Working";
        ToolTipService.SetToolTip(button, chip == SessionStatusChip.New ? "Chats with a reply you haven’t read" : "Chats a bot is working in");
        AutomationProperties.SetName(button, $"{noun}, {count} {(count == 1 ? "chat" : "chats")}");
        if (picked) AutomationProperties.SetItemStatus(button, "Selected");
        AutomationProperties.SetAutomationId(button, CountAutomationId(chip));
        button.Click += (_, _) => pick();
        return button;
    }

    /// `StatusChipMark` (unpicked): New the tint's 8 pt dot; Working a still quarter ring on a faint full one, 12 pt, 2 wide.
    private static FrameworkElement Mark(SessionStatusChip chip)
    {
        var tokens = ThemeService.Tokens;
        if (chip == SessionStatusChip.New)
            return new Ellipse { Width = SessionsHeaderRow.NewDot, Height = SessionsHeaderRow.NewDot, Fill = Ink(tokens.Tint), VerticalAlignment = VerticalAlignment.Center };
        var side = SessionsHeaderRow.WorkingMark;
        var r = side / 2;
        var line = SessionsHeaderRow.WorkingMarkLine;
        var box = new Grid { Width = side, Height = side, VerticalAlignment = VerticalAlignment.Center };
        // SwiftUI strokes on the circle's own edge (half the line outside it), as a path's stroke does here.
        box.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = new EllipseGeometry { Center = new Point(r, r), RadiusX = r, RadiusY = r },
            Stroke = Ink(tokens.Label.Alpha(SessionsHeaderRow.WorkingMarkTrack)), StrokeThickness = line,
        });
        // `trim(from: 0, to: 0.25)`: from the right round to the foot, clockwise.
        var figure = new PathFigure { StartPoint = new Point(side, r), IsClosed = false, IsFilled = false };
        figure.Segments.Add(new ArcSegment { Point = new Point(r, side), Size = new Size(r, r), SweepDirection = SweepDirection.Clockwise });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        box.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = geometry, Stroke = Ink(tokens.Label), StrokeThickness = line,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        });
        AutomationProperties.SetAccessibilityView(box, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return box;
    }

    /// The drawings' ideal widths, measured as laid out: each one at its own width, nothing cut.
    public static IReadOnlyList<double> Ideals(IReadOnlyList<SessionsHeaderRowPanel> rows, Panel probe)
    {
        var ideals = new List<double>();
        foreach (var row in rows)
        {
            probe.Children.Add(row);
            row.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            ideals.Add(row.Ideal);
            probe.Children.Remove(row);
        }
        return ideals;
    }
}

/// One drawing of the row: the switch at the left, the menu and the counts at the right
/// (`SessionsHeaderRow.Place`), the menu's name cut when the room runs short.
internal sealed partial class SessionsHeaderRowPanel : Panel
{
    public FrameworkElement? Switch { get; set; }
    public FrameworkElement? Menu { get; set; }
    public List<FrameworkElement> Counts { get; } = [];
    public double Spacing { get; set; } = SessionsHeaderRow.WordsSpacing;
    public SessionsHeaderVariant Variant { get; set; } = SessionsHeaderRow.Variants[0];
    /// The row's width with every item whole (`IdealWidth`), from the last measure.
    public double Ideal { get; private set; }
    private double? _menuIdeal;

    private IReadOnlyList<double> CountWidths => [.. Counts.Select(c => c.DesiredSize.Width)];

    protected override Size MeasureOverride(Size availableSize)
    {
        var free = new Size(double.PositiveInfinity, availableSize.Height);
        foreach (var child in Children) child.Measure(free);
        _menuIdeal = Menu?.DesiredSize.Width;
        var counts = CountWidths;
        Ideal = SessionsHeaderRow.IdealWidth(Switch?.DesiredSize.Width, _menuIdeal, counts, Spacing);
        var height = Children.Count == 0 ? 0 : Children.Max(c => c.DesiredSize.Height);
        if (!double.IsFinite(availableSize.Width)) return new Size(Ideal, height);
        if (Menu != null && Ideal > availableSize.Width)
        {
            var place = SessionsHeaderRow.Place(availableSize.Width, Switch?.DesiredSize.Width, _menuIdeal, counts, Spacing);
            Menu.Measure(new Size(place.MenuWidth, availableSize.Height));
        }
        return new Size(Math.Min(Ideal, availableSize.Width), height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var place = SessionsHeaderRow.Place(finalSize.Width, Switch?.DesiredSize.Width, _menuIdeal, CountWidths, Spacing);
        void Put(FrameworkElement e, double x, double width)
        {
            var h = Math.Min(e.DesiredSize.Height, finalSize.Height);
            e.Arrange(new Rect(x, (finalSize.Height - h) / 2, width, h));
        }
        if (Switch != null && place.SwitchX is { } sx) Put(Switch, sx, Switch.DesiredSize.Width);
        if (Menu != null && place.MenuX is { } mx) Put(Menu, mx, place.MenuWidth);
        for (var i = 0; i < Counts.Count; i++) Put(Counts[i], place.CountXs[i], Counts[i].DesiredSize.Width);
        return finalSize;
    }
}
