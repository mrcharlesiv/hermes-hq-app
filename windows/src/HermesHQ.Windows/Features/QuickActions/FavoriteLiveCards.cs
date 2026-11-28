using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Insights;
using Hermes.Core.Jobs;
using Hermes.Core.Kanban;
using Hermes.Core.QuickActions;
using Hermes.Core.Sessions;
using Hermes.Core.Tasks;
using HermesHQ.Controls;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace HermesHQ.Features.QuickActions;

/// Interactive WinUI 3 cards for all 10 native live card kinds (`App/QuickActions/FavoriteLiveCards.swift`),
/// plus collapsible section headers, compact 4-across Mini action tiles, and live page count badges.
internal static class FavoriteLiveCards
{
    public sealed record LiveCardActions(
        Action<QuickTile> OpenTile,
        Action<string> ToggleTaskDone,
        Action<string?> QuickAddTask,
        Action<string> OpenBotMemo,
        Action<string> OpenBotTalk,
        Action<string> OpenBotNewChat,
        Action<QuickTile, CronJob> RunJobNow,
        Action<FavoritesLiveModel.AttentionTarget> OpenAttention,
        Action<string> ToggleSection);

    // ------------------------------------------------------------------ live card router

    public static Button BuildLiveCard(
        QuickTile tile,
        FavoritesLiveModel live,
        LiveCardActions actions,
        bool editing,
        QuickTileSize size,
        bool stacked,
        string? missingReason)
    {
        var body = tile.Known switch
        {
            QuickTileKind.Tasks => BuildTasksCard(tile, live, actions, editing, size, stacked),
            QuickTileKind.Goal => BuildGoalCard(tile, live, actions, editing, size),
            QuickTileKind.NeedsYou => BuildNeedsYouCard(tile, live, actions, editing, size),
            QuickTileKind.BotCard => BuildBotCard(tile, live, actions, editing, size),
            QuickTileKind.GroupChat => BuildGroupChatCard(tile, live, size),
            QuickTileKind.ChatSession => BuildChatSessionCard(tile, live, size),
            QuickTileKind.JobCard => BuildJobCard(tile, live, actions, editing, size),
            QuickTileKind.Kanban => BuildKanbanCard(tile, live, size),
            QuickTileKind.GatewayStatus => BuildGatewayStatusCard(tile, live, size),
            QuickTileKind.Usage => BuildUsageCard(tile, live, size),
            _ => new TextBlock { Text = tile.Name },
        };

        var root = new Grid
        {
            Opacity = missingReason == null ? 1 : 0.5,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        root.Children.Add(body);

        if (live.FeedbackByTile.TryGetValue(tile.Id, out var fb))
            root.Children.Add(BuildFeedbackOverlay(fb));
        else if (live.RunningTiles.Contains(tile.Id))
            root.Children.Add(BuildRunningOverlay());

        var card = new Button
        {
            Content = root,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            Padding = new Thickness(14, 12, 14, 12),
            CornerRadius = new CornerRadius(14),
            Background = PageKit.Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = PageKit.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(card, "quick-tile-" + tile.Id);
        AutomationProperties.SetName(card, $"{tile.Name}, {tile.Subtitle(live.BotName(tile.Bot))}");
        if (missingReason != null) AutomationProperties.SetItemStatus(card, "Unavailable");
        card.Click += (_, _) => actions.OpenTile(tile);
        return card;
    }

    // ------------------------------------------------------------------ 1. Tasks card

    private static FrameworkElement BuildTasksCard(
        QuickTile tile,
        FavoritesLiveModel live,
        LiveCardActions actions,
        bool editing,
        QuickTileSize size,
        bool stacked)
    {
        var maxRows = size switch
        {
            QuickTileSize.Small => 2,
            QuickTileSize.Large or QuickTileSize.ExtraLarge => 6,
            QuickTileSize.TallCard => 5,
            _ => stacked ? 4 : 3,
        };
        var frame = live.TasksSnapshot(tile, maxRows);
        var panel = new Grid { RowSpacing = 6 };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = CardHeader(frame.Title, "\uE9D5", PageKit.Rgb(0xFF, 0x95, 0x00),
            frame.OpenCount > 0 ? frame.OpenCount.ToString() : null, urgent: false);
        if (!editing)
        {
            var add = SmallIconButton("\uE710", "Add Task", () => actions.QuickAddTask(tile.Bot));
            header.Children.Add(add);
            Grid.SetColumn(add, 2);
        }
        panel.Children.Add(header);

        var body = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Top };
        if (frame.Loading)
        {
            body.Children.Add(PageKit.Text("Loading tasks…", 12, color: PageKit.Secondary));
        }
        else if (frame.Rows.Count == 0)
        {
            body.Children.Add(PageKit.Text(frame.EmptyNote ?? "Nothing due.", 12, color: PageKit.Secondary));
        }
        else
        {
            var now = DateTimeOffset.Now;
            var zone = TimeZoneInfo.Local;
            foreach (var task in frame.Rows)
            {
                var taskId = task.Id;
                var ticking = live.TickingTasks.Contains(taskId);
                var rowWords = TodoViews.Row(task, TodoGroupKind.Today, now, zone, live.BotName);
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                var check = new Button
                {
                    Width = 22,
                    Height = 22,
                    Padding = new Thickness(0),
                    CornerRadius = new CornerRadius(11),
                    BorderThickness = new Thickness(1.5),
                    BorderBrush = rowWords.Late ? PageKit.Solid(PageKit.Red) : PageKit.Secondary,
                    Background = ticking ? PageKit.AccentWash(0.18) : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    Content = ticking ? new FontIcon { Glyph = "\uE73E", FontSize = 10 } : null,
                    IsEnabled = !editing && !ticking,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                AutomationProperties.SetName(check, $"Complete {task.Title}");
                check.Click += (_, _) => actions.ToggleTaskDone(taskId);
                row.Children.Add(check);

                var label = new TextBlock
                {
                    Text = string.IsNullOrWhiteSpace(task.Title) ? "Untitled Task" : task.Title,
                    FontSize = 13,
                    MaxLines = 1,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                Grid.SetColumn(label, 1);
                row.Children.Add(label);

                if (!string.IsNullOrEmpty(rowWords.When))
                {
                    var when = new TextBlock
                    {
                        Text = rowWords.When,
                        FontSize = 11,
                        Foreground = rowWords.Late ? PageKit.Solid(PageKit.Red) : PageKit.Secondary,
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                    Grid.SetColumn(when, 2);
                    row.Children.Add(when);
                }
                body.Children.Add(row);
            }
            if (frame.RemainingCount > 0)
                body.Children.Add(PageKit.Text($"+{frame.RemainingCount} more", 11, color: PageKit.Secondary));
        }
        Grid.SetRow(body, 1);
        panel.Children.Add(body);
        return panel;
    }

    // ------------------------------------------------------------------ 2. Goal card

    private static FrameworkElement BuildGoalCard(
        QuickTile tile,
        FavoritesLiveModel live,
        LiveCardActions actions,
        bool editing,
        QuickTileSize size)
    {
        var snap = live.GoalData(tile);
        var (r, g, b) = GoalTints.Rgb(snap.Goal?.Tint ?? "blue");
        var ringColor = PageKit.Rgb(r, g, b);

        var root = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var top = new Grid { ColumnSpacing = 12 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        top.Children.Add(BuildGoalRing(snap.Fraction, ringColor, size == QuickTileSize.Small ? 40 : 48));

        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock
        {
            Text = snap.Goal?.Shown ?? tile.Name,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            MaxLines = size == QuickTileSize.Small ? 2 : 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.WrapWholeWords,
        });
        words.Children.Add(new TextBlock
        {
            Text = snap.Line,
            FontSize = 12,
            Foreground = PageKit.Secondary,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (snap.Pace is { } pace)
        {
            var tone = pace.Tone switch
            {
                GoalPaceTone.Late => PageKit.Red,
                GoalPaceTone.Behind => PageKit.Orange,
                _ => PageKit.Green,
            };
            words.Children.Add(BuildSmallTag(pace.Words, tone));
        }
        Grid.SetColumn(words, 1);
        top.Children.Add(words);
        root.Children.Add(top);

        if (snap.NextTask is { } next && size != QuickTileSize.Small)
        {
            var nextRow = new Grid { ColumnSpacing = 8 };
            nextRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            nextRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var ticking = live.TickingTasks.Contains(next.Id);
            var tick = new Button
            {
                Width = 20,
                Height = 20,
                Padding = new Thickness(0),
                CornerRadius = new CornerRadius(10),
                BorderThickness = new Thickness(1.5),
                BorderBrush = PageKit.Solid(ringColor),
                Background = ticking ? PageKit.AccentWash(0.18) : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                Content = ticking ? new FontIcon { Glyph = "\uE73E", FontSize = 9 } : null,
                IsEnabled = !editing && !ticking,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var nextId = next.Id;
            AutomationProperties.SetName(tick, $"Complete next step {next.Title}");
            tick.Click += (_, _) => actions.ToggleTaskDone(nextId);
            nextRow.Children.Add(tick);

            var nextText = new TextBlock
            {
                Text = "Next: " + (string.IsNullOrWhiteSpace(next.Title) ? "Untitled Task" : next.Title),
                FontSize = 12,
                Foreground = PageKit.Secondary,
                MaxLines = 1,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(nextText, 1);
            nextRow.Children.Add(nextText);
            root.Children.Add(nextRow);
        }

        return root;
    }

    private static Grid BuildGoalRing(double? fraction, Color color, double side)
    {
        var ring = new Grid { Width = side, Height = side, VerticalAlignment = VerticalAlignment.Center };
        var stroke = 4.5;
        ring.Children.Add(new Ellipse
        {
            Width = side,
            Height = side,
            Stroke = PageKit.Brush("ControlStrongStrokeColorDefaultBrush"),
            StrokeThickness = stroke,
            Opacity = 0.25,
        });

        var pct = fraction is { } f ? Math.Clamp(f, 0, 1) : 0;
        if (pct >= 0.999)
        {
            ring.Children.Add(new Ellipse
            {
                Width = side,
                Height = side,
                Stroke = PageKit.Solid(color),
                StrokeThickness = stroke,
            });
        }
        else if (pct > 0.005)
        {
            var r = (side - stroke) / 2.0;
            var cx = side / 2.0;
            var cy = side / 2.0;
            var angle = pct * 2.0 * Math.PI;
            var startX = cx;
            var startY = cy - r;
            var endX = cx + r * Math.Sin(angle);
            var endY = cy - r * Math.Cos(angle);
            var fig = new PathFigure { StartPoint = new Point(startX, startY), IsClosed = false };
            fig.Segments.Add(new ArcSegment
            {
                Point = new Point(endX, endY),
                Size = new Size(r, r),
                IsLargeArc = pct > 0.5,
                SweepDirection = SweepDirection.Clockwise,
            });
            var geo = new PathGeometry();
            geo.Figures.Add(fig);
            ring.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
            {
                Data = geo,
                Stroke = PageKit.Solid(color),
                StrokeThickness = stroke,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
            });
        }

        ring.Children.Add(new TextBlock
        {
            Text = fraction is { } val ? $"{(int)Math.Floor(val * 100)}%" : "—",
            FontSize = side < 44 ? 10 : 11,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        });
        return ring;
    }

    // ------------------------------------------------------------------ 3. Needs You card

    private static FrameworkElement BuildNeedsYouCard(
        QuickTile tile,
        FavoritesLiveModel live,
        LiveCardActions actions,
        bool editing,
        QuickTileSize size)
    {
        var maxItems = size switch
        {
            QuickTileSize.Small => 2,
            QuickTileSize.Large or QuickTileSize.ExtraLarge => 6,
            QuickTileSize.TallCard => 5,
            _ => 3,
        };
        var items = live.AttentionItems(maxItems + 4);
        var panel = new Grid { RowSpacing = 6 };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var urgent = items.Any(i => i.Tone is FavoritesLiveModel.AttentionTone.Critical or FavoritesLiveModel.AttentionTone.Warning);
        panel.Children.Add(CardHeader(tile.Name, "\uEA8F", urgent ? PageKit.Red : PageKit.Green,
            items.Count > 0 ? items.Count.ToString() : null, urgent));

        var body = new StackPanel { Spacing = 4 };
        if (items.Count == 0)
        {
            var clear = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 6, 0, 0) };
            clear.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 14, Foreground = PageKit.Solid(PageKit.Green) });
            clear.Children.Add(PageKit.Text("All clear — nothing waiting on you.", 12, color: PageKit.Secondary));
            body.Children.Add(clear);
        }
        else
        {
            foreach (var item in items.Take(maxItems))
            {
                var dotColor = item.Tone switch
                {
                    FavoritesLiveModel.AttentionTone.Critical => PageKit.Red,
                    FavoritesLiveModel.AttentionTone.Warning => PageKit.Orange,
                    FavoritesLiveModel.AttentionTone.Working => PageKit.Green,
                    _ => PageKit.Blue,
                };
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(PageKit.Dot(dotColor, 7));

                var text = new StackPanel();
                text.Children.Add(new TextBlock { Text = item.Title, FontSize = 12.5, FontWeight = FontWeights.SemiBold, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
                text.Children.Add(new TextBlock { Text = item.Subtitle, FontSize = 11, Foreground = PageKit.Secondary, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
                Grid.SetColumn(text, 1);
                row.Children.Add(text);

                var pill = BuildSmallTag(item.Badge, dotColor);
                Grid.SetColumn(pill, 2);
                row.Children.Add(pill);

                if (!editing)
                {
                    var target = item.Target;
                    var rowBtn = new Button
                    {
                        Content = row,
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        HorizontalContentAlignment = HorizontalAlignment.Stretch,
                        Padding = new Thickness(4, 3, 4, 3),
                        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                        BorderThickness = new Thickness(0),
                    };
                    rowBtn.Click += (_, _) => actions.OpenAttention(target);
                    body.Children.Add(rowBtn);
                }
                else
                {
                    body.Children.Add(row);
                }
            }
            if (items.Count > maxItems)
                body.Children.Add(PageKit.Text($"+{items.Count - maxItems} more", 11, color: PageKit.Secondary));
        }
        Grid.SetRow(body, 1);
        panel.Children.Add(body);
        return panel;
    }

    // ------------------------------------------------------------------ 4. Live Bot Card

    private static FrameworkElement BuildBotCard(
        QuickTile tile,
        FavoritesLiveModel live,
        LiveCardActions actions,
        bool editing,
        QuickTileSize size)
    {
        var profile = tile.Bot ?? "default";
        var row = live.Hub?.Bots.Bot(profile);
        var name = row?.Model.DisplayName ?? tile.BotName ?? tile.Name;

        var panel = new Grid { RowSpacing = 8 };
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var top = new Grid { ColumnSpacing = 10 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var avatarHolder = new Grid { Width = 38, Height = 38, VerticalAlignment = VerticalAlignment.Top };
        var head = new BotHead { Width = 38, Height = 38 };
        if (row != null) head.Bot = row.Model;
        else head.DisplayName = name;
        avatarHolder.Children.Add(head);

        var statusDotColor = row switch
        {
            { NeedsInput.Length: > 0 } => PageKit.Orange,
            { IsWorking: true } => PageKit.Green,
            { Unread: true } => PageKit.Blue,
            _ => (Color?)null,
        };
        if (statusDotColor is { } dc)
        {
            avatarHolder.Children.Add(new Ellipse
            {
                Width = 10,
                Height = 10,
                Fill = PageKit.Solid(dc),
                Stroke = PageKit.Brush("CardBackgroundFillColorDefaultBrush"),
                StrokeThickness = 1.5,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Bottom,
            });
        }
        top.Children.Add(avatarHolder);

        var line = row switch
        {
            { NeedsInput.Length: > 0 } => row.NeedsInput!,
            { IsWorking: true, Step.Length: > 0 } => row.Step!,
            { IsWorking: true } => "Working…",
            { Preview.Text.Length: > 0 } => row.Preview.Text,
            _ => "Ready to chat",
        };
        var lineColor = row switch
        {
            { NeedsInput.Length: > 0 } => PageKit.Solid(PageKit.Orange),
            { IsWorking: true } => PageKit.Solid(PageKit.Green),
            _ => PageKit.Secondary,
        };

        var info = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(new TextBlock { Text = name, FontSize = 14, FontWeight = FontWeights.SemiBold, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
        info.Children.Add(new TextBlock
        {
            Text = line,
            FontSize = 12,
            Foreground = lineColor,
            MaxLines = size == QuickTileSize.Small ? 1 : 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.WrapWholeWords,
        });
        Grid.SetColumn(info, 1);
        top.Children.Add(info);

        if (row is { Unread: true })
        {
            var unread = BuildBadgePill("New", urgent: false);
            Grid.SetColumn(unread, 2);
            top.Children.Add(unread);
        }
        panel.Children.Add(top);

        var pills = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        pills.Children.Add(QuickPill("\uE720", size == QuickTileSize.Small ? null : "Memo", "Voice Memo", !editing, () => actions.OpenBotMemo(profile)));
        pills.Children.Add(QuickPill("\uE8D6", size == QuickTileSize.Small ? null : "Talk", "Talk", !editing, () => actions.OpenBotTalk(profile)));
        pills.Children.Add(QuickPill("\uE70F", size == QuickTileSize.Small ? null : "New", "New Chat", !editing, () => actions.OpenBotNewChat(profile)));
        Grid.SetRow(pills, 1);
        panel.Children.Add(pills);
        return panel;
    }

    // ------------------------------------------------------------------ 5. Group Chat card

    private static FrameworkElement BuildGroupChatCard(QuickTile tile, FavoritesLiveModel live, QuickTileSize size)
    {
        var room = !string.IsNullOrEmpty(tile.RoomKey)
            ? live.Hub?.Groups.Rows().FirstOrDefault(r => r.Id == tile.RoomKey)
            : null;
        var title = room?.Name ?? tile.RoomName ?? tile.Name;
        var panel = new Grid { RowSpacing = 6 };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var faces = new StackPanel { Orientation = Orientation.Horizontal, Spacing = -6 };
        if (room is { Faces.Count: > 0 })
        {
            foreach (var f in room.Faces.Take(3))
                faces.Children.Add(PageKit.Face(f.Profile, 24));
        }
        else
        {
            faces.Children.Add(SmallTileBadge("\uE902", PageKit.Rgb(0x30, 0xB0, 0xC7)));
        }
        header.Children.Add(faces);

        var titleStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titleStack.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
        var sub = room != null
            ? (room.Running ? "Active now" : $"{room.MemberCount} {(room.MemberCount == 1 ? "bot" : "bots")}")
            : "Group chat";
        titleStack.Children.Add(new TextBlock { Text = sub, FontSize = 11, Foreground = room?.Running == true ? PageKit.Solid(PageKit.Green) : PageKit.Secondary });
        Grid.SetColumn(titleStack, 1);
        header.Children.Add(titleStack);

        if (room is { Unread: true })
        {
            var badge = BuildBadgePill("Unread", urgent: false);
            Grid.SetColumn(badge, 2);
            header.Children.Add(badge);
        }
        panel.Children.Add(header);

        var preview = new TextBlock
        {
            Text = room?.Line is { Length: > 0 } l ? l : "Open room to chat with the group.",
            FontSize = 12,
            Foreground = PageKit.Secondary,
            MaxLines = size == QuickTileSize.Small ? 2 : 3,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.WrapWholeWords,
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        Grid.SetRow(preview, 1);
        panel.Children.Add(preview);
        return panel;
    }

    // ------------------------------------------------------------------ 6. Specific Chat Session card

    private static FrameworkElement BuildChatSessionCard(QuickTile tile, FavoritesLiveModel live, QuickTileSize size)
    {
        var session = !string.IsNullOrEmpty(tile.SessionId)
            ? live.Hub?.Sessions.LiveSummaries().FirstOrDefault(s => s.Id == tile.SessionId && (string.IsNullOrEmpty(tile.Bot) || s.Profile == tile.Bot))
            : null;
        var profile = session?.Profile ?? tile.Bot;
        var title = !string.IsNullOrWhiteSpace(tile.Name) ? tile.Name : session?.Title ?? tile.SessionTitle ?? "Chat";

        var panel = new Grid { RowSpacing = 6 };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        header.Children.Add(PageKit.Face(profile, 28));

        var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(new TextBlock { Text = title, FontSize = 13.5, FontWeight = FontWeights.SemiBold, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
        var meta = string.Join(" · ", new[]
        {
            !string.IsNullOrEmpty(profile) ? live.BotName(profile) : null,
            !string.IsNullOrEmpty(session?.Branch) ? session.Branch : null,
        }.OfType<string>());
        info.Children.Add(new TextBlock { Text = meta.Length > 0 ? meta : "Pinned chat", FontSize = 11, Foreground = PageKit.Secondary, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(info, 1);
        header.Children.Add(info);

        if (session != null)
        {
            if (session.Status == SessionStatus.NeedsInput)
            {
                var p = BuildSmallTag("Needs you", PageKit.Orange);
                Grid.SetColumn(p, 2);
                header.Children.Add(p);
            }
            else if (session.IsRunning)
            {
                var p = BuildSmallTag("Working", PageKit.Green);
                Grid.SetColumn(p, 2);
                header.Children.Add(p);
            }
            else if (session.Unread)
            {
                var p = BuildBadgePill("New", urgent: false);
                Grid.SetColumn(p, 2);
                header.Children.Add(p);
            }
        }
        panel.Children.Add(header);

        var line = session switch
        {
            { IsRunning: true, Step.Length: > 0 } => session.Step!,
            { Preview.Length: > 0 } => session.Preview!,
            { Metadata.Length: > 0 } => session.Metadata,
            _ => "Resume conversation",
        };
        var preview = new TextBlock
        {
            Text = line,
            FontSize = 12,
            Foreground = PageKit.Secondary,
            MaxLines = size == QuickTileSize.Small ? 2 : 3,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.WrapWholeWords,
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        Grid.SetRow(preview, 1);
        panel.Children.Add(preview);
        return panel;
    }

    // ------------------------------------------------------------------ 7. Job Card (single job or upcoming overview)

    private static FrameworkElement BuildJobCard(
        QuickTile tile,
        FavoritesLiveModel live,
        LiveCardActions actions,
        bool editing,
        QuickTileSize size)
    {
        if (!string.IsNullOrEmpty(tile.Job))
        {
            var snap = live.JobData(tile);
            var dotColor = snap.Running ? PageKit.Green : snap.Failed || snap.Overdue ? PageKit.Red : snap.Paused ? PageKit.Rgb(0x8E, 0x8E, 0x93) : PageKit.Blue;
            var panel = new Grid { RowSpacing = 8 };
            panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            var top = new StackPanel { Spacing = 4 };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(PageKit.Dot(dotColor, 8));
            head.Children.Add(new TextBlock { Text = snap.Title, FontSize = 14, FontWeight = FontWeights.SemiBold, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
            top.Children.Add(head);
            top.Children.Add(new TextBlock
            {
                Text = snap.Subtitle,
                FontSize = 12,
                Foreground = snap.Failed || snap.Overdue ? PageKit.Solid(PageKit.Red) : PageKit.Secondary,
                MaxLines = 2,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.WrapWholeWords,
            });
            panel.Children.Add(top);

            if (snap.Job is { } job)
            {
                var runBtn = QuickPill("\uE768", snap.Running ? "Running…" : "Run Now", $"Run {snap.Title}", !editing && !snap.Running, () => actions.RunJobNow(tile, job));
                runBtn.HorizontalAlignment = HorizontalAlignment.Left;
                Grid.SetRow(runBtn, 1);
                panel.Children.Add(runBtn);
            }
            return panel;
        }

        // Upcoming Jobs overview
        var limit = size switch
        {
            QuickTileSize.Small => 2,
            QuickTileSize.Large or QuickTileSize.ExtraLarge => 5,
            _ => 3,
        };
        var upcoming = live.UpcomingJobs(limit);
        var overview = new Grid { RowSpacing = 6 };
        overview.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        overview.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        overview.Children.Add(CardHeader(tile.Name, "\uE823", PageKit.Rgb(0xFF, 0x95, 0x00),
            upcoming.Count > 0 ? upcoming.Count.ToString() : null, urgent: upcoming.Any(j => j.Failed || j.Overdue)));

        var rows = new StackPanel { Spacing = 4 };
        if (upcoming.Count == 0)
        {
            rows.Children.Add(PageKit.Text(live.Jobs?.HasList == true ? "No active scheduled jobs." : "Open Jobs to load schedule.", 12, color: PageKit.Secondary));
        }
        else
        {
            foreach (var item in upcoming)
            {
                var dotColor = item.Running ? PageKit.Green : item.Failed || item.Overdue ? PageKit.Red : PageKit.Blue;
                var r = new Grid { ColumnSpacing = 8 };
                r.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                r.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                r.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                r.Children.Add(PageKit.Dot(dotColor, 7));

                var nameText = new TextBlock { Text = item.Title, FontSize = 12.5, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(nameText, 1);
                r.Children.Add(nameText);

                if (!editing && item.Job is { } job)
                {
                    var play = SmallIconButton("\uE768", $"Run {item.Title}", () => actions.RunJobNow(tile, job));
                    Grid.SetColumn(play, 2);
                    r.Children.Add(play);
                }
                rows.Children.Add(r);
            }
        }
        Grid.SetRow(rows, 1);
        overview.Children.Add(rows);
        return overview;
    }

    // ------------------------------------------------------------------ 8. Kanban Board card

    private static FrameworkElement BuildKanbanCard(QuickTile tile, FavoritesLiveModel live, QuickTileSize size)
    {
        var maxCards = size switch
        {
            QuickTileSize.Small => 0,
            QuickTileSize.Large or QuickTileSize.ExtraLarge => 4,
            QuickTileSize.TallCard => 3,
            _ => 2,
        };
        var snap = live.KanbanData(tile, maxCards);
        var panel = new Grid { RowSpacing = 8 };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var blocked = snap.Columns.FirstOrDefault(c => c.Status == "blocked").Count;
        panel.Children.Add(CardHeader(snap.BoardTitle, "\uE8FD", PageKit.Rgb(0x58, 0x56, 0xD6),
            snap.TotalOpen > 0 ? snap.TotalOpen.ToString() : null, urgent: blocked > 0));

        if (snap.Loading)
        {
            var loading = PageKit.Text("Loading board…", 12, color: PageKit.Secondary);
            Grid.SetRow(loading, 1);
            panel.Children.Add(loading);
            return panel;
        }

        var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var shownCols = snap.Columns.Where(c => c.Count > 0).Take(size == QuickTileSize.Small ? 3 : 5).ToList();
        if (shownCols.Count == 0) shownCols = snap.Columns.Take(3).ToList();
        foreach (var (status, label, count) in shownCols)
            chips.Children.Add(BuildSmallTag($"{label} {count}", PageKit.Tone(status)));
        Grid.SetRow(chips, 1);
        panel.Children.Add(chips);

        if (snap.TopCards.Count > 0)
        {
            var cards = new StackPanel { Spacing = 3 };
            foreach (var c in snap.TopCards)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                row.Children.Add(PageKit.Dot(PageKit.Tone(c.Status), 6));
                row.Children.Add(new TextBlock { Text = c.Title, FontSize = 12, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis });
                cards.Children.Add(row);
            }
            Grid.SetRow(cards, 2);
            panel.Children.Add(cards);
        }
        return panel;
    }

    // ------------------------------------------------------------------ 9. Gateway Status card

    private static FrameworkElement BuildGatewayStatusCard(QuickTile tile, FavoritesLiveModel live, QuickTileSize size)
    {
        var status = live.GatewayStatus;
        var panel = new Grid { RowSpacing = 8 };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var stateColor = status switch
        {
            null => PageKit.Rgb(0x8E, 0x8E, 0x93),
            { GatewayRunning: false } => PageKit.Red,
            _ when status.Platforms.Any(p => p.IsDown) => PageKit.Orange,
            _ => PageKit.Green,
        };
        var stateLabel = status == null
            ? (live.StatusLoading ? "Checking…" : "Offline")
            : status.GatewayRunning == false ? "Stopped"
            : status.Platforms.Any(p => p.IsDown) ? "Attention"
            : "Healthy";

        panel.Children.Add(CardHeader(tile.Name, "\uE9D9", stateColor, stateLabel, urgent: status?.GatewayRunning == false));

        var body = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Bottom };
        if (status != null)
        {
            var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            meta.Children.Add(PageKit.Text(status.VersionWords, 12, bold: true));
            meta.Children.Add(PageKit.Text($"{status.SessionsWords} sessions", 12, color: PageKit.Secondary));
            if (live.ActiveSubagents > 0)
                meta.Children.Add(BuildSmallTag($"{live.ActiveSubagents} live", PageKit.Green));
            body.Children.Add(meta);

            if (status.Platforms.Count > 0)
            {
                var platforms = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
                foreach (var p in status.Platforms.Take(size == QuickTileSize.Small ? 2 : 5))
                {
                    var pc = p.IsDown ? PageKit.Red : p.IsUp ? PageKit.Green : PageKit.Rgb(0x8E, 0x8E, 0x93);
                    platforms.Children.Add(BuildSmallTag(p.Name, pc));
                }
                body.Children.Add(platforms);
            }
        }
        else
        {
            body.Children.Add(PageKit.Text(live.StatusLoading ? "Checking gateway health…" : "Open Status & Maintenance to inspect.", 12, color: PageKit.Secondary));
        }
        Grid.SetRow(body, 1);
        panel.Children.Add(body);
        return panel;
    }

    // ------------------------------------------------------------------ 10. Usage card

    private static FrameworkElement BuildUsageCard(QuickTile tile, FavoritesLiveModel live, QuickTileSize size)
    {
        var days = tile.Days is 30 or 90 ? tile.Days.Value : 7;
        live.UsageByDays.TryGetValue(days, out var report);
        var loading = live.UsageLoadingDays.Contains(days);

        var panel = new Grid { RowSpacing = 8 };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        panel.Children.Add(CardHeader(tile.Name, "\uE9D2", PageKit.Rgb(0x30, 0xB0, 0xC7), $"{days}d", urgent: false));

        var kpis = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        if (report != null)
        {
            kpis.Children.Add(KpiBlock(UsageFormat.Compact(report.Tokens), "tokens"));
            kpis.Children.Add(KpiBlock(UsageFormat.Cost(report.Cost), "est. cost"));
            if (size != QuickTileSize.Small && report.Sessions is { } sess)
                kpis.Children.Add(KpiBlock(sess.ToString(), "sessions"));
        }
        else
        {
            kpis.Children.Add(PageKit.Text(loading ? "Loading usage…" : "No usage data yet.", 12, color: PageKit.Secondary));
        }
        Grid.SetRow(kpis, 1);
        panel.Children.Add(kpis);

        if (report is { Daily.Count: > 0 })
        {
            var bars = BuildSparkline(report.Daily, size == QuickTileSize.Small ? 7 : 14);
            Grid.SetRow(bars, 2);
            panel.Children.Add(bars);
        }
        return panel;
    }

    private static StackPanel KpiBlock(string value, string label) => new()
    {
        Children =
        {
            new TextBlock { Text = value, FontSize = 16, FontWeight = FontWeights.SemiBold },
            new TextBlock { Text = label, FontSize = 11, Foreground = PageKit.Secondary },
        },
    };

    private static Grid BuildSparkline(IReadOnlyList<UsageReport.Day> daily, int maxBars)
    {
        var slice = daily.Count > maxBars ? daily.Skip(daily.Count - maxBars).ToList() : daily.ToList();
        var max = Math.Max(1, slice.Max(d => d.Tokens));
        const double maxH = 34;
        var chart = new Grid { ColumnSpacing = 3, Height = maxH, VerticalAlignment = VerticalAlignment.Bottom };
        for (var i = 0; i < slice.Count; i++)
        {
            chart.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var ratio = (double)slice[i].Tokens / max;
            var h = Math.Max(3, Math.Round(ratio * maxH));
            var bar = new Border
            {
                Height = h,
                CornerRadius = new CornerRadius(2),
                Background = PageKit.Brush("AccentFillColorDefaultBrush"),
                Opacity = ratio > 0 ? 0.35 + 0.65 * ratio : 0.18,
                VerticalAlignment = VerticalAlignment.Bottom,
            };
            Grid.SetColumn(bar, i);
            chart.Children.Add(bar);
        }
        return chart;
    }

    // ------------------------------------------------------------------ Section Header & Mini Tile

    public static FrameworkElement BuildSectionHeader(
        QuickTile section,
        int itemCount,
        bool editing,
        Action onToggle,
        Action onEdit,
        Action onRemove)
    {
        var collapsed = section.Collapsed == true;
        var row = new Grid { ColumnSpacing = 8, VerticalAlignment = VerticalAlignment.Center };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var chevron = new FontIcon
        {
            Glyph = collapsed ? "\uE76C" : "\uE70D",
            FontSize = 11,
            Foreground = PageKit.Secondary,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(chevron);

        var title = new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(section.Name) ? "Section" : section.Name,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = PageKit.Secondary,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(title, 1);
        row.Children.Add(title);

        if (collapsed && itemCount > 0)
        {
            var countPill = BuildBadgePill(itemCount.ToString(), urgent: false);
            Grid.SetColumn(countPill, 2);
            row.Children.Add(countPill);
        }

        var rule = new Border
        {
            Height = 1,
            Background = PageKit.Brush("DividerStrokeColorDefaultBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 4, 0),
        };
        Grid.SetColumn(rule, 3);
        row.Children.Add(rule);

        if (editing)
        {
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            controls.Children.Add(SmallIconButton("\uE70F", $"Edit {section.Name}", onEdit));
            controls.Children.Add(SmallIconButton("\uE738", $"Remove {section.Name}", onRemove));
            Grid.SetColumn(controls, 4);
            row.Children.Add(controls);
        }

        var btn = new Button
        {
            Content = row,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(4, 2, 4, 2),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetAutomationId(btn, "quick-tile-" + section.Id);
        AutomationProperties.SetName(btn, collapsed ? $"{section.Name}, collapsed, {itemCount} items" : $"{section.Name}, expanded");
        btn.Click += (_, _) => { if (editing) onEdit(); else onToggle(); };
        return btn;
    }

    public static Button BuildMiniFace(
        QuickTile tile,
        FavoritesLiveModel live,
        bool editing,
        string? missingReason,
        Action onClick)
    {
        var stack = new StackPanel
        {
            Spacing = 4,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = missingReason == null ? 1 : 0.5,
        };

        if (tile.ShowAvatar == true && !string.IsNullOrEmpty(tile.Bot))
        {
            var face = PageKit.Face(tile.Bot, 28);
            face.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(face);
        }
        else
        {
            stack.Children.Add(new Border
            {
                Width = 28,
                Height = 28,
                CornerRadius = new CornerRadius(7),
                Background = QuickActionsPage.TileBrush(tile.Tint),
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = new FontIcon
                {
                    Glyph = QuickActionsPage.Glyph(tile.Symbol),
                    FontSize = 14,
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                },
            });
        }

        stack.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(tile.Name) ? " " : tile.Name,
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        });

        var root = new Grid();
        root.Children.Add(stack);
        if (live.FeedbackByTile.TryGetValue(tile.Id, out var fb))
            root.Children.Add(BuildFeedbackOverlay(fb));
        else if (live.RunningTiles.Contains(tile.Id))
            root.Children.Add(BuildRunningOverlay());

        var btn = new Button
        {
            Content = root,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            Padding = new Thickness(6, 6, 6, 6),
            CornerRadius = new CornerRadius(12),
            Background = PageKit.Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = PageKit.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(btn, "quick-tile-" + tile.Id);
        AutomationProperties.SetName(btn, $"{tile.Name}, {tile.Subtitle(live.BotName(tile.Bot))}");
        if (missingReason != null) AutomationProperties.SetItemStatus(btn, "Unavailable");
        btn.Click += (_, _) => onClick();
        return btn;
    }

    // ------------------------------------------------------------------ shared visual pieces

    public static Border BuildBadgePill(string text, bool urgent) => new()
    {
        Padding = new Thickness(7, 2, 7, 2),
        CornerRadius = new CornerRadius(10),
        VerticalAlignment = VerticalAlignment.Center,
        Background = urgent ? PageKit.Solid(PageKit.Red) : PageKit.AccentWash(0.16),
        Child = new TextBlock
        {
            Text = text,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = urgent ? new SolidColorBrush(Microsoft.UI.Colors.White) : PageKit.Accent,
        },
    };

    private static Grid CardHeader(string title, string glyph, Color tint, string? badgeText, bool urgent)
    {
        var g = new Grid { ColumnSpacing = 8 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        g.Children.Add(SmallTileBadge(glyph, tint));

        var heading = new TextBlock
        {
            Text = title,
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(heading, 1);
        g.Children.Add(heading);

        if (!string.IsNullOrEmpty(badgeText))
        {
            var pill = BuildBadgePill(badgeText, urgent);
            Grid.SetColumn(pill, 2);
            g.Children.Add(pill);
        }
        return g;
    }

    private static Border SmallTileBadge(string glyph, Color tint) => new()
    {
        Width = 24,
        Height = 24,
        CornerRadius = new CornerRadius(6),
        Background = PageKit.Solid(tint),
        VerticalAlignment = VerticalAlignment.Center,
        Child = new FontIcon { Glyph = glyph, FontSize = 12, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
    };

    private static Border BuildSmallTag(string text, Color tint) => new()
    {
        Padding = new Thickness(6, 2, 6, 2),
        CornerRadius = new CornerRadius(6),
        VerticalAlignment = VerticalAlignment.Center,
        Background = new SolidColorBrush(Color.FromArgb(36, tint.R, tint.G, tint.B)),
        Child = new TextBlock
        {
            Text = text,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = PageKit.Solid(tint),
        },
    };

    private static Button QuickPill(string glyph, string? label, string accessibleName, bool enabled, Action onClick)
    {
        var inner = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        inner.Children.Add(new FontIcon { Glyph = glyph, FontSize = 11 });
        if (!string.IsNullOrEmpty(label))
            inner.Children.Add(new TextBlock { Text = label, FontSize = 11.5, FontWeight = FontWeights.SemiBold });
        var btn = new Button
        {
            Content = inner,
            Padding = new Thickness(8, 3, 8, 3),
            MinHeight = 24,
            CornerRadius = new CornerRadius(12),
            IsEnabled = enabled,
        };
        AutomationProperties.SetName(btn, accessibleName);
        btn.Click += (_, _) => onClick();
        return btn;
    }

    private static Button SmallIconButton(string glyph, string tip, Action onClick)
    {
        var btn = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 11 },
            Width = 26,
            Height = 26,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(6),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(btn, tip);
        AutomationProperties.SetName(btn, tip);
        btn.Click += (_, _) => onClick();
        return btn;
    }

    internal static Border BuildFeedbackOverlay(FavoritesLiveModel.TileFeedback fb) => new()
    {
        HorizontalAlignment = HorizontalAlignment.Right,
        VerticalAlignment = VerticalAlignment.Top,
        Padding = new Thickness(7, 2, 7, 2),
        CornerRadius = new CornerRadius(10),
        Background = PageKit.Solid(fb.Ok ? PageKit.Green : PageKit.Red),
        IsHitTestVisible = false,
        Child = new TextBlock
        {
            Text = (fb.Ok ? "✓ " : "! ") + fb.Message,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        },
    };

    internal static Border BuildRunningOverlay() => new()
    {
        HorizontalAlignment = HorizontalAlignment.Right,
        VerticalAlignment = VerticalAlignment.Top,
        Padding = new Thickness(4),
        CornerRadius = new CornerRadius(10),
        Background = PageKit.Brush("SolidBackgroundFillColorBaseBrush"),
        IsHitTestVisible = false,
        Child = new ProgressRing { IsActive = true, Width = 14, Height = 14 },
    };
}
