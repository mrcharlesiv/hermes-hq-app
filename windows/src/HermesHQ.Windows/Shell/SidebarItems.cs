using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Sessions;
using WorkingRing = Hermes.Core.Settings.WorkingRing;
using Tokens = Hermes.Core.Settings.ChatVisualTokens;
using DensitySizes = Hermes.Core.Settings.DensitySizes;
using ThemeService = HermesHQ.Features.Settings.ThemeService;
using HermesHQ.Controls;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Shell;

/// The sidebar is one list (one selection mark, arrow keys run through all of it) of these rows
/// (App/Mac/MacSidebar.swift): group headings, bots with their step line, the chats under a bot, New Bot, the places and
/// Tools. Each row is drawn in code (`SidebarRowView`), so the whole sidebar is type-checked.
public abstract class SidebarItem
{
    public virtual bool Selectable => true;
}

/// A heading: Pinned, a user section, Unassigned/Bots, Hidden, Tools. Folds on click.
public sealed class SidebarHeader(string title, string key, bool collapsed, string? sectionId = null) : SidebarItem
{
    public string Title { get; } = title;
    public string Key { get; } = key;
    public bool Collapsed { get; } = collapsed;
    /// A user section's id (its heading has Rename…, Move Up/Down, Delete Section; bots dropped on it are filed there).
    public string? SectionId { get; } = sectionId;
    public override bool Selectable => false;
}

public sealed class SidebarBot(BotRow bot, bool muted, BotBlock block, string? sectionId) : SidebarItem
{
    public BotRow Bot { get; } = bot;
    public bool Muted { get; } = muted;
    public BotBlock Block { get; } = block;
    public string? SectionId { get; } = sectionId;
    public string Name => Bot.Name;
}

/// [groups] A group chat's head among the bots (MacBotsRail `Item.room`): its tile face, name, "Working…" while a round
/// runs, its unread dot and muted bell. Opening a room is the next slice: the row is inert until then.
public sealed class SidebarRoom(GroupRowModel room, BotBlock block, string? sectionId) : SidebarItem
{
    public GroupRowModel Room { get; } = room;
    public BotBlock Block { get; } = block;
    public string? SectionId { get; } = sectionId;
    public string Name => Room.Name;
    /// The sidebar's automation id for a room's row (the CI walk finds the rows by it).
    public static string AutomationId(GroupRowModel room) => "sidebar.room." + room.Id;
}

/// [chats-under] One of a bot's own chats under its row.
public sealed class SidebarChat(SessionSummary chat, string bot, bool last, bool first = false, bool showsPin = false, Bot? botModel = null) : SidebarItem
{
    public SessionSummary Chat { get; } = chat;
    public string Bot { get; } = bot;
    public bool Last { get; } = last;
    public bool First { get; } = first;
    public bool ShowsPin { get; } = showsPin;
    public Bot? BotModel { get; } = botModel;
}

/// "N more ›": the rest of the bot's chats, in Sessions with its chip picked.
public sealed class SidebarMore(string bot, int count, bool first = false, Bot? botModel = null) : SidebarItem
{
    public string Bot { get; } = bot;
    public int Count { get; } = count;
    public bool First { get; } = first;
    public Bot? BotModel { get; } = botModel;
}

public sealed class SidebarPlace(Place place, bool isTool) : SidebarItem
{
    public Place Place { get; } = place;
    public bool IsTool { get; } = isTool;
    public string Title => Place.Title;
    public string Glyph => Place.Glyph;
    public string Count { get; set; } = "";
}

public sealed class SidebarAction(string title, string glyph, Action run) : SidebarItem
{
    public string Title { get; } = title;
    public string Glyph { get; } = glyph;
    public Action Run { get; } = run;
}

/// The line between the bots and the places (and between the rail's groups).
public sealed class SidebarDivider : SidebarItem
{
    public override bool Selectable => false;
}

/// Draws the rows. `rail`: the folded sidebar (faces alone, or with names under them when `named`).
public static class SidebarRowView
{
    // Code-created sidebar rows outlive theme changes. Keep the palette's recolorable brushes,
    // not the stock secondary/tertiary text brushes for the theme that was active at creation.
    private static Brush Res(string key) => ThemeBrushes.Get(key switch
    {
        "TextFillColorSecondaryBrush" => "HQLabel2Brush",
        "TextFillColorTertiaryBrush" => "HQLabel3Brush",
        _ => key,
    });

    /// [density] The open sidebar's sizes at the density drawn now (Theme › Density › Compact, the iOS look's): the bots',
    /// the chats' under them and the places' rows, faces and names (SidebarType `current`, `MacBotsRail`). The rail keeps
    /// its own sizes, as the Mac's.
    private static DensitySizes.SidebarSizes Sizes => DensitySizes.Sidebar(ThemeService.State.Compact);

    public static ListViewItem Make(SidebarItem item, bool rail, bool named)
    {
        var z = Sizes;
        var container = new ListViewItem
        {
            Tag = item, VerticalContentAlignment = VerticalAlignment.Center, Padding = rail ? new Thickness(0) : new Thickness(8, 0, 8, 0),
            MinHeight = item is SidebarDivider ? 0 : item is SidebarChat or SidebarMore ? z.ChatRow : rail ? 40
                : item is SidebarBot or SidebarRoom ? z.BotRow : item is SidebarPlace or SidebarAction ? z.PlaceRow : Tokens.HeadingHeight,
            HorizontalContentAlignment = rail ? HorizontalAlignment.Center : HorizontalAlignment.Stretch,
            IsTabStop = item.Selectable,
        };
        container.Content = rail ? RailView(item, named) : OpenView(item, container);
        // [WIN-49] The Mac's mark: the look's corner, 2 over and under (MinHeight less those 4, so rows keep their pitch).
        if (item is not SidebarDivider)
        {
            SelectionMark.Shape(container);
            container.MinHeight = Math.Max(0, container.MinHeight - Hermes.Core.Shell.DesktopLook.MarkInsetTop - Hermes.Core.Shell.DesktopLook.MarkInsetBottom);
        }
        if (item is SidebarDivider) container.IsHitTestVisible = false;
        if (rail && item switch { SidebarBot b => b.Name, SidebarRoom r => r.Name, SidebarPlace p => p.Title, SidebarAction a => a.Title, _ => null } is { } tip)
            ToolTipService.SetToolTip(container, tip);
        AutomationName(container, item);
        if (item is SidebarRoom room) Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(container, SidebarRoom.AutomationId(room.Room));
        return container;
    }

    private static void AutomationName(DependencyObject target, SidebarItem item)
    {
        var name = item switch
        {
            SidebarBot b => BotList.AccessibilityLabel(b.Bot, ListTime.Format(b.Bot.Time), b.Muted),
            SidebarRoom r => BotListRooms.AccessibilityLabel(r.Room),
            SidebarHeader h => h.Title + (h.Collapsed ? ", collapsed" : ""),
            // [working-ring] Its state is heard with the title, ring or no ring.
            SidebarChat c => WorkingRing.ChatSpokenName(c.Chat),
            SidebarMore m => $"{m.Count} more",
            SidebarPlace p => p.Place.BadgeAccessibility?.Invoke() is { Length: > 0 } value ? p.Title + ", " + value : p.Title,
            SidebarAction a => a.Title,
            _ => null,
        };
        if (name != null) Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(target, name);
    }

    private static UIElement OpenView(SidebarItem item, ListViewItem row) => item switch
    {
        SidebarHeader h => Header(h),
        SidebarBot b => BotRowView(b, row),
        SidebarRoom r => RoomRowView(r, row),
        SidebarChat c => ChatRow(c, row),
        SidebarMore m => MoreRow(m, row),
        SidebarPlace p => PlaceRow(p, row),
        SidebarAction a => ActionRow(a.Title, a.Glyph),
        _ => new Rectangle { Height = 1, Margin = new Thickness(4, 6, 4, 6), Fill = Res("DividerStrokeColorDefaultBrush") },
    };

    private static UIElement Header(SidebarHeader h)
    {
        var g = new Grid { Padding = new Thickness(2, 0, 4, 0) };
        g.Children.Add(new TextBlock { Text = h.Title, FontSize = Tokens.SidebarSmall, FontWeight = FontWeights.SemiBold, Foreground = Res("TextFillColorSecondaryBrush") });
        g.Children.Add(new FontIcon
        {
            Glyph = h.Collapsed ? "" : "", FontSize = 9, HorizontalAlignment = HorizontalAlignment.Right,
            Foreground = Res("TextFillColorTertiaryBrush"),
        });
        return g;
    }

    /// A face and its name on one line; while it works its step ("Working…", "Waiting for you") under the name, its
    /// unread dot, a bell-slash when muted, an eye-slash when hidden.
    private static UIElement BotRowView(SidebarBot b, ListViewItem row)
    {
        var bot = b.Bot;
        var z = Sizes;
        var g = new Grid { ColumnSpacing = 10 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(Face(bot, z.Face));
        var (prefix, text, tone) = BotList.SecondLine(bot);
        var name = RowName(row, bot.Name, z.Name, BotList.ShowsUnread(bot));
        var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { name } };
        if (BotList.StatusOf(bot) != BotList.RowStatus.Idle)
        {
            var words = new TextBlock
            {
                Text = prefix == null ? text : $"{prefix} {text}", FontSize = Tokens.SidebarSmall, TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = Res(tone switch
                {
                    BotList.Tone.Attention => "SystemFillColorCautionBrush",
                    BotList.Tone.Tint => "AccentTextFillColorPrimaryBrush",
                    _ => "TextFillColorSecondaryBrush",
                }),
            };
            // [botslist] [WIN-WAKING-SPINNER] "Waking up…" has a small spinner before the words (BotRowViews.swift
            // `bottomLine`), hidden from UI Automation: the row's name already says "Waking up…".
            if (BotList.RowShowsSpinner(bot))
            {
                var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                line.Children.Add(Spinner(12));
                line.Children.Add(words);
                lines.Children.Add(line);
            }
            else lines.Children.Add(words);
        }
        Grid.SetColumn(lines, 1);
        g.Children.Add(lines);
        var marks = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (b.Muted) marks.Children.Add(new FontIcon { Glyph = "", FontSize = 11, Foreground = Res("TextFillColorTertiaryBrush") });
        if (bot.Hidden) marks.Children.Add(new FontIcon { Glyph = "", FontSize = 11, Foreground = Res("TextFillColorTertiaryBrush") });
        if (BotList.ShowsUnread(bot))
            marks.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = Res(b.Muted ? "TextFillColorTertiaryBrush" : "AccentFillColorDefaultBrush") });
        Grid.SetColumn(marks, 2);
        g.Children.Add(marks);
        // [working-ring] The ring round the row while it works (not while it waits on you), when Working Ring is on; off,
        // the face's mark and "Working…" still say it works.
        return WorkingRingView.Wrap(g, WorkingRing.ShowsBotRing(bot, WorkingRing.IsOn), new Thickness(6, 1, 6, 1));
    }

    /// [groups] A room's row as a bot's (MacBotsRailHead in the open sidebar): the group face, the name (bold while unread),
    /// "Working…" under it in the accent while a round runs, the bell-slash when muted, the unread dot (grey when muted).
    private static UIElement RoomRowView(SidebarRoom r, ListViewItem row)
    {
        var room = r.Room;
        var z = Sizes;
        var g = new Grid { ColumnSpacing = 10 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(RoomFace(room, z.Face));
        var name = RowName(row, room.Name, z.Name, room.Unread);
        var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { name } };
        if (BotListRooms.Status(room) is { } status)
            lines.Children.Add(new TextBlock { Text = status, FontSize = Tokens.SidebarSmall, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = Res("AccentTextFillColorPrimaryBrush") });
        Grid.SetColumn(lines, 1);
        g.Children.Add(lines);
        var marks = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (room.Muted) marks.Children.Add(new FontIcon { Glyph = "\uE7ED", FontSize = 11, Foreground = Res("TextFillColorTertiaryBrush") });
        if (room.Hidden) marks.Children.Add(new FontIcon { Glyph = "\uED1A", FontSize = 11, Foreground = Res("TextFillColorTertiaryBrush") });
        if (room.Unread)
            marks.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = Res(room.Muted ? "TextFillColorTertiaryBrush" : "AccentFillColorDefaultBrush") });
        Grid.SetColumn(marks, 2);
        g.Children.Add(marks);
        return g;
    }

    /// A room's group face (`GroupAvatar`) with the rail's corner mark: the accent working badge while a round runs, else
    /// the unread dot (`MacBotsRailHead.configuration`); the open row carries its dot beside the name instead.
    private static Grid RoomFace(GroupRowModel room, double size, bool unreadMark = false)
    {
        var face = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        var roster = HermesHQ.Features.Bots.ListsHub.Current?.Bots;
        face.Children.Add(new GroupAvatar(room, size, profile => roster?.Bot(profile)?.Model));
        var mark = BotListRooms.Mark(room);
        if (mark == BotListRooms.FaceMark.Working || (unreadMark && mark == BotListRooms.FaceMark.Unread))
            face.Children.Add(new Ellipse
            {
                Width = 10, Height = 10, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(0, 0, -2, -2), StrokeThickness = 1.5, Stroke = Res("SolidBackgroundFillColorBaseBrush"),
                Fill = Res("AccentFillColorDefaultBrush"),
            });
        return face;
    }

    /// A bot's face with its corner badge, `BotAvatar`'s one rule (`BotList.FaceBadgeOf`). [WIN-ROW-FACE-CORNER] A row
    /// (`tile` false) has its second line, so its face reads idle: no standing-problem badge, spinner or orange waiting
    /// dot; the working dots while a turn runs (waiting on you or not, Working Ring on or off), else the unread presence
    /// dot. `tile`: a face with no line beside it (the rail, as MacBotsRail's `BotAvatar(tile: true)`): its standing
    /// problem's orange badge unless the working dots take it, the waking spinner, waiting on you, then the same.
    private static Grid Face(BotRow bot, double size, bool tile = false)
    {
        var face = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        face.Children.Add(new BotHead { Bot = bot.Model, Width = size, Height = size });
        switch (BotList.FaceBadgeOf(bot, tile, WorkingRing.IsOn, presence: true))
        {
            case BotList.FaceBadge.Attention: face.Children.Add(AttentionBadge(BotList.BadgeSize(size))); break;
            case BotList.FaceBadge.Waking: face.Children.Add(WakingBadge(BotList.BadgeSize(size))); break;
            case BotList.FaceBadge.Waiting: face.Children.Add(WaitingBadge(BotList.WaitingSize(size))); break;
            case BotList.FaceBadge.Working: face.Children.Add(WorkingBadge(BotList.BadgeSize(size))); break;
            case BotList.FaceBadge.Unread: face.Children.Add(PresenceDot(BotList.PresenceSize(size))); break;
        }
        return face;
    }

    /// [WIN-ROW-FACE-RING-PANEL] What every sidebar face's badges are ringed in: the sidebar panel, on the open sidebar's
    /// rows and the folded rail alike (MacBotsRail.swift `MacRailHead.configuration` sets `hqBadgeRing` to
    /// `MacSidebar.panelColor`), not the page colour, which showed as a halo round every dot.
    private static Brush Ring => Res(BotList.BadgeRingBrushKey(BotList.BadgeGround.SidebarPanel));

    /// A dot in the face's corner (1 outside, `.offset(x: 1, y: 1)`), ringed 2 in the sidebar panel's colour, hidden
    /// from UI Automation: `PresenceDot` and `WaitingBadge`.
    private static Grid RingedDot(double dot, string fill)
    {
        const double ring = BotList.BadgeRingWidth;
        var g = new Grid
        {
            Width = dot + 2 * ring, Height = dot + 2 * ring, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, -(1 + ring), -(1 + ring)), IsHitTestVisible = false,
        };
        g.Children.Add(new Ellipse { Fill = Ring });
        g.Children.Add(new Ellipse { Width = dot, Height = dot, Fill = Res(fill) });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(g, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return g;
    }

    /// [heads] Unread: a small round dot in the label colour (`PresenceDot`, `Color.hqLabel`: white on a dark page, black
    /// on a light one). The row's unread circle stays at its trailing edge.
    private static Grid PresenceDot(double dot)
    {
        return RingedDot(dot, "TextFillColorPrimaryBrush");
    }

    /// Waiting for the person on a tile: an orange dot (`WaitingBadge`), never on a row's face.
    private static Grid WaitingBadge(double dot)
    {
        return RingedDot(dot, "SystemFillColorCautionBrush");
    }

    /// Working: an accent circle with three white dots that brighten in turn (`WorkingBadge`: the chat's typing wave,
    /// 0.2 s apart every 1.2 s on the shared clock); with Windows' animations off they stand at full strength, as the
    /// Mac's under Reduce Motion. The waves start when the badge is shown and stop when it goes.
    private static Grid WorkingBadge(double badge)
    {
        var (side, gap) = BotList.WorkingDots(badge);
        var mark = new Grid { Width = badge, Height = badge, Margin = new Thickness(BotList.BadgeRingWidth) };
        mark.Children.Add(new Ellipse { Fill = Res("AccentFillColorDefaultBrush") });
        var dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = gap, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        for (var d = 0; d < TypingDots.Count; d++)
            dots.Children.Add(new Ellipse { Width = side, Height = side, Fill = Res("TextOnAccentFillColorPrimaryBrush") });
        mark.Children.Add(dots);
        var waves = new List<Microsoft.UI.Xaml.Media.Animation.Storyboard>();
        mark.Loaded += (_, _) =>
        {
            if (waves.Count > 0 || !TypingDots.Animates(new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)) return;
            var clock = Environment.TickCount64 / 1000.0;   // the shared clock: a row drawn again doesn't restart the wave
            for (var d = 0; d < dots.Children.Count; d++)
            {
                try { waves.Add(HermesHQ.Pages.GroupRoomPage.Wave(dots.Children[d], d, clock)); }
                catch (System.Runtime.InteropServices.COMException) { }   // the dot stays still
            }
        };
        mark.Unloaded += (_, _) =>
        {
            foreach (var wave in waves) wave.Stop();
            waves.Clear();
            foreach (var dot in dots.Children) dot.Opacity = 1;
        };
        return RingedBadge(badge, mark);
    }

    /// A badge in the face's corner (bottom-right, 2 outside), ringed 2 in the sidebar panel's colour (`BotAvatar`'s
    /// `.background(Circle().fill(ring).padding(-2)).offset(x: 2, y: 2)`), hidden from UI Automation.
    private static Grid RingedBadge(double badge, UIElement content)
    {
        const double ring = BotList.BadgeRingWidth;
        var g = new Grid
        {
            Width = badge + 2 * ring, Height = badge + 2 * ring, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, -(2 + ring), -(2 + ring)), IsHitTestVisible = false,
        };
        g.Children.Add(new Ellipse { Fill = Ring });
        g.Children.Add(content);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(g, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return g;
    }

    /// [botslist] A standing problem on a tile: an orange circle with a white "!" (`AttentionBadge`).
    private static Grid AttentionBadge(double badge)
    {
        var mark = new Grid { Width = badge, Height = badge, Margin = new Thickness(BotList.BadgeRingWidth) };
        mark.Children.Add(new Ellipse { Fill = Res("SystemFillColorCautionBrush") });
        mark.Children.Add(new TextBlock
        {
            Text = "!", FontSize = badge * 0.55, FontWeight = FontWeights.Black, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        });
        return RingedBadge(badge, mark);
    }

    /// [botslist] [WIN-WAKING-SPINNER] "Waking up…" on a tile: a small spinner in the badge's place.
    private static Grid WakingBadge(double badge)
    {
        var spinner = Spinner(badge);
        spinner.Margin = new Thickness(BotList.BadgeRingWidth);
        return RingedBadge(badge, spinner);
    }

    /// The small spinner (the Mac's `ProgressView().controlSize(.mini/.small)`), hidden from UI Automation.
    private static ProgressRing Spinner(double size)
    {
        var ring = new ProgressRing
        {
            IsActive = true, Width = size, Height = size, MinWidth = 0, MinHeight = 0, IsHitTestVisible = false,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(ring, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return ring;
    }

    /// A chat under its bot: vector branch connector (`BotChatsLineView`), optional solo-aware pin glyph
    /// (`BotChatsUnder.ShowsPin`), its title, its time (or "Working…"), and its unread dot.
    private static UIElement ChatRow(SidebarChat c, ListViewItem row)
    {
        var z = Sizes;
        var style = BotChatsStylePrefs.Current;
        var g = new Grid { ColumnSpacing = 6, Margin = new Thickness(10, 0, 0, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var tint = BotChatsLineView.BotTintColor(c.BotModel, c.Bot);
        var line = new BotChatsLineView(
            first: c.First,
            last: c.Last,
            more: false,
            style: style,
            status: BotChatsLineView.StatusOf(c.Chat),
            tint: tint,
            lineX: 5,
            reach: 10.5);
        BindConnectorEmphasis(row, line);
        g.Children.Add(line);

        var title = new TextBlock
        {
            Text = c.Chat.Title, FontSize = z.ChatTitle, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
            FontWeight = c.Chat.Unread ? FontWeights.SemiBold : FontWeights.Normal,
        };
        if (c.ShowsPin)
        {
            var titleHost = new Grid { ColumnSpacing = 5, VerticalAlignment = VerticalAlignment.Center };
            titleHost.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            titleHost.ColumnDefinitions.Add(new ColumnDefinition());
            var pin = new FontIcon
            {
                Glyph = "\uE718", FontSize = 10, Foreground = Res("TextFillColorTertiaryBrush"),
                VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false,
            };
            AutomationProperties.SetAccessibilityView(pin, AccessibilityView.Raw);
            titleHost.Children.Add(pin);
            Grid.SetColumn(title, 1);
            titleHost.Children.Add(title);
            Grid.SetColumn(titleHost, 1);
            g.Children.Add(titleHost);
        }
        else
        {
            Grid.SetColumn(title, 1);
            g.Children.Add(title);
        }

        var status = SessionRowWords.StatusWords(c.Chat.Status, c.Chat.Step);
        var trail = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        trail.Children.Add(new TextBlock
        {
            Text = status ?? ListTime.Format(c.Chat.LastActive), FontSize = Tokens.SidebarSmall,
            Foreground = Res(status != null ? "AccentTextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
        });
        if (c.Chat.Unread) trail.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = Res("AccentFillColorDefaultBrush") });
        Grid.SetColumn(trail, 2);
        g.Children.Add(trail);

        if (style == BotChatsStyleKind.Dividers && !c.Last)
        {
            var sep = new Rectangle
            {
                Height = 1, VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false,
                Fill = Res("DividerStrokeColorDefaultBrush"), Opacity = 0.5,
            };
            Grid.SetColumn(sep, 1);
            Grid.SetColumnSpan(sep, 2);
            g.Children.Add(sep);
        }

        // [working-ring] A working chat's ring (Working Ring on); its "Working…" stays either way.
        return WorkingRingView.Wrap(g, WorkingRing.ShowsChatRing(c.Chat, WorkingRing.IsOn), new Thickness(2, 1, 6, 1));
    }

    private static UIElement MoreRow(SidebarMore m, ListViewItem row)
    {
        var g = new Grid { ColumnSpacing = 6, Margin = new Thickness(10, 0, 0, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var tint = BotChatsLineView.BotTintColor(m.BotModel, m.Bot);
        var line = new BotChatsLineView(
            first: m.First,
            last: true,
            more: true,
            style: BotChatsStylePrefs.Current,
            status: BotChatNodeStatus.Quiet,
            tint: tint,
            lineX: 5,
            reach: 10.5);
        BindConnectorEmphasis(row, line);
        g.Children.Add(line);
        var words = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = $"{m.Count} more", FontSize = Tokens.SidebarMore, FontWeight = FontWeights.Medium, Foreground = Res("AccentTextFillColorPrimaryBrush") });
        words.Children.Add(new FontIcon { Glyph = "", FontSize = 9, Foreground = Res("AccentTextFillColorPrimaryBrush") });
        Grid.SetColumn(words, 1);
        g.Children.Add(words);
        return g;
    }

    private static void BindConnectorEmphasis(ListViewItem row, BotChatsLineView line)
    {
        var hovered = false;
        void Sync() => line.SetEmphasized(hovered || row.IsSelected);
        void Enter(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e) { hovered = true; Sync(); }
        void Exit(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e) { hovered = false; Sync(); }

        long? token = null;
        line.Loaded += (_, _) =>
        {
            row.PointerEntered += Enter;
            row.PointerExited += Exit;
            token ??= row.RegisterPropertyChangedCallback(ListViewItem.IsSelectedProperty, (_, _) => Sync());
            Sync();
        };
        line.Unloaded += (_, _) =>
        {
            row.PointerEntered -= Enter;
            row.PointerExited -= Exit;
            if (token is { } t) row.UnregisterPropertyChangedCallback(ListViewItem.IsSelectedProperty, t);
            token = null;
        };
    }

    // Only the name changes weight when chosen, not its status, time or count. Drop the native
    // callback when the sidebar replaces its items; repaint after reattachment.
    private static TextBlock RowName(ListViewItem row, string title, double size, bool unread = false)
    {
        var name = new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = size };
        void Paint() => name.FontWeight = new Windows.UI.Text.FontWeight { Weight = unread || row.IsSelected ? Tokens.Semibold : Tokens.Regular };
        Paint();
        long? subscription = null;
        name.Loaded += (_, _) => { Paint(); subscription ??= row.RegisterPropertyChangedCallback(ListViewItem.IsSelectedProperty, (_, _) => Paint()); };
        name.Unloaded += (_, _) =>
        {
            if (subscription is { } token) row.UnregisterPropertyChangedCallback(ListViewItem.IsSelectedProperty, token);
            subscription = null;
        };
        return name;
    }

    private static UIElement PlaceRow(SidebarPlace p, ListViewItem row)
    {
        var z = Sizes;
        var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(2, 0, 2, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new FontIcon { Glyph = p.Glyph, FontSize = Tokens.PlaceIcon });
        var t = RowName(row, p.Title, z.Name);
        Grid.SetColumn(t, 1);
        g.Children.Add(t);
        var c = p.Place.Badge?.Invoke(false) ?? new TextBlock { Text = p.Count, FontSize = Tokens.SidebarCount, Foreground = Res("TextFillColorTertiaryBrush") };
        Grid.SetColumn(c, 2);
        g.Children.Add(c);
        return g;
    }

    private static UIElement ActionRow(string title, string glyph) => new StackPanel
    {
        Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(6, 0, 6, 0),
        Children =
        {
            new FontIcon { Glyph = glyph, FontSize = 13, Foreground = Res("TextFillColorSecondaryBrush") },
            new TextBlock { Text = title, FontSize = Sizes.Name, Foreground = Res("TextFillColorSecondaryBrush") },
        },
    };

    /// The rail: faces centred (a name under each when pulled out), the places as icons, lines between groups.
    private static UIElement RailView(SidebarItem item, bool named)
    {
        switch (item)
        {
            case SidebarBot b:
            {
                var s = new StackPanel { Spacing = 2, Padding = new Thickness(0, 4, 0, 4), HorizontalAlignment = HorizontalAlignment.Center };
                s.Children.Add(Face(b.Bot, 34, tile: true));
                if (named)
                    s.Children.Add(new TextBlock { Text = b.Name, FontSize = 11, MaxWidth = 100, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center });
                return s;
            }
            case SidebarRoom r:
            {
                var s = new StackPanel { Spacing = 2, Padding = new Thickness(0, 4, 0, 4), HorizontalAlignment = HorizontalAlignment.Center };
                s.Children.Add(RoomFace(r.Room, 34, unreadMark: true));
                if (named)
                    s.Children.Add(new TextBlock { Text = r.Name, FontSize = 11, MaxWidth = 100, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center });
                return s;
            }
            case SidebarPlace p:
            {
                var s = new StackPanel { Spacing = 2, Padding = new Thickness(0, 6, 0, 6), HorizontalAlignment = HorizontalAlignment.Center };
                var icon = new Grid();
                icon.Children.Add(new FontIcon { Glyph = p.Glyph, FontSize = 16 });
                if (p.Place.Badge?.Invoke(true) is { } badge) icon.Children.Add(badge);
                s.Children.Add(icon);
                if (named) s.Children.Add(new TextBlock { Text = p.Title, FontSize = 11, MaxWidth = 100, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center });
                return s;
            }
            case SidebarAction a:
                return new FontIcon { Glyph = a.Glyph, FontSize = 14, Margin = new Thickness(0, 8, 0, 8), Foreground = Res("TextFillColorSecondaryBrush") };
            default:
                return new Rectangle { Height = 1, Width = 28, Margin = new Thickness(0, 6, 0, 6), Fill = Res("DividerStrokeColorDefaultBrush") };
        }
    }
}
