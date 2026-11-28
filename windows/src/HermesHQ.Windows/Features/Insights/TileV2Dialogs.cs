using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Settings;
using HermesHQ.Controls;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace HermesHQ.Features.Insights;

/// Maps Mac SF Symbol names used by Tiles v2 (page icons, New Tile ideas, Change Tile chips) to Segoe Fluent Icons.
internal static class TileSymbolGlyphs
{
    public static string Glyph(string? symbol) => symbol switch
    {
        "rectangle.3.group" => "\uE80A",
        "chart.bar.fill" => "\uE9D2",
        "briefcase.fill" => "\uE821",
        "house.fill" => "\uE80F",
        "calendar" => "\uE787",
        "dollarsign.circle.fill" or "dollarsign.circle" => "\uE8C7",
        "chevron.left.forwardslash.chevron.right" => "\uE943",
        "heart.fill" => "\uEB51",
        "bolt.fill" => "\uE945",
        "star.fill" => "\uE735",
        "globe" => "\uE774",
        "tray.full.fill" => "\uE8F1",
        "envelope.badge" => "\uE715",
        "cloud.sun.fill" => "\uE753",
        "checklist" => "\uE9D5",
        "clock.badge.checkmark" or "clock.arrow.circlepath" => "\uE823",
        "target" => "\uE7C4",
        "chart.line.uptrend.xyaxis" => "\uE9D9",
        "bubble.left.and.exclamationmark.bubble.right" => "\uE8BD",
        "arrow.triangle.pull" => "\uE8AB",
        "server.rack" => "\uE968",
        "airplane" => "\uE709",
        "person.2" => "\uE716",
        "figure.run" => "\uE706",
        "newspaper" => "\uF57E",
        "hourglass" => "\uE916",
        "quote.bubble" => "\uE90A",
        "textformat.size" => "\uE8D2",
        "list.bullet" => "\uE8FD",
        "paintpalette" => "\uE790",
        "wrench.and.screwdriver" => "\uE90F",
        _ => "\uE734",
    };
}

/// Lightweight wrapping flow layout (equivalent to Mac `PagesFlowLayout`) for bot selector chips and quick-change chips.
internal sealed class TileFlowPanel : Panel
{
    public double Spacing { get; set; } = 6;
    public double LineSpacing { get; set; } = 6;

    protected override Size MeasureOverride(Size availableSize)
    {
        var maxWidth = double.IsInfinity(availableSize.Width) || availableSize.Width <= 0 ? 440 : availableSize.Width;
        double x = 0, y = 0, rowHeight = 0, usedWidth = 0;
        foreach (var child in Children)
        {
            child.Measure(new Size(maxWidth, double.PositiveInfinity));
            var d = child.DesiredSize;
            if (x > 0 && x + d.Width > maxWidth)
            {
                y += rowHeight + LineSpacing;
                x = 0;
                rowHeight = 0;
            }
            x += d.Width;
            usedWidth = Math.Max(usedWidth, x);
            x += Spacing;
            rowHeight = Math.Max(rowHeight, d.Height);
        }
        return new Size(usedWidth, y + rowHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var maxWidth = finalSize.Width > 0 ? finalSize.Width : 440;
        double x = 0, y = 0, rowHeight = 0;
        foreach (var child in Children)
        {
            var d = child.DesiredSize;
            if (x > 0 && x + d.Width > maxWidth)
            {
                y += rowHeight + LineSpacing;
                x = 0;
                rowHeight = 0;
            }
            child.Arrange(new Rect(x, y, d.Width, d.Height));
            x += d.Width + Spacing;
            rowHeight = Math.Max(rowHeight, d.Height);
        }
        return new Size(maxWidth, y + rowHeight);
    }
}

/// Collected options from the New Tile blank draft dialog.
internal sealed record NewTileRequest(Bot Bot, string What, TileSize Size, TileScheduleChoice Schedule, string PageId);

/// [tiles-v2] New Tile blank draft sheet (Mac build 1266 `NewTile.swift`):
///   1. On the Tile (prompt box)
///   2. Made By (bot selector ABOVE Ideas so switching bots live-ranks Ideas & Fit badges!)
///   3. Ideas (6 ranked ideas + More Ideas toggle, hidden once prompt has text)
///   4. Layout & Updates (Size, Updates, Page)
/// Make stays disabled until a prompt is entered and a bot is selected.
internal static class NewTileDialog
{
    public static async Task<NewTileRequest?> ShowAsync(
        XamlRoot? root,
        IReadOnlyList<Bot> bots,
        string? initialBotId,
        IReadOnlyList<TilePage> pages,
        string currentPageId,
        Func<ContentDialog, Task<ContentDialogResult>> show)
    {
        if (root == null) return null;
        var orderedBots = bots.OrderBy(b => b.Name == "default" ? 0 : 1).ToList();
        var selectedBot = orderedBots.FirstOrDefault(b => b.Name == initialBotId) ?? orderedBots.FirstOrDefault();
        var selectedSize = TileSize.Small;
        var selectedSchedule = TileScheduleChoice.Auto;
        var selectedPageId = pages.Any(p => p.Id == currentPageId) ? currentPageId : TilePage.MainId;
        var showAllIdeas = false;

        var dialog = new ContentDialog
        {
            Title = TileWords.NewTile,
            XamlRoot = root,
            PrimaryButtonText = TileWords.Make,
            CloseButtonText = TileWords.Cancel,
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        AutomationProperties.SetAutomationId(dialog, "tile.new.sheet");

        var form = new StackPanel { Spacing = 14, MinWidth = 440, MaxWidth = 500 };

        // 1. On the Tile
        var whatBox = new TextBox
        {
            PlaceholderText = TileWords.WhatShouldItShow,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 68,
            MaxHeight = 140,
        };
        AutomationProperties.SetName(whatBox, TileWords.OnTheTile);
        AutomationProperties.SetAutomationId(whatBox, "tile.new.what");
        var whatSection = SectionBlock(TileWords.OnTheTile, whatBox, TileWords.NewTileFooter);
        form.Children.Add(whatSection);

        // 2. Made By (ABOVE Ideas!)
        var botFlow = new TileFlowPanel { Spacing = 6, LineSpacing = 6 };
        var botSection = SectionBlock(TileWords.MadeBy, botFlow, TileWords.MadeByFooter);
        AutomationProperties.SetAutomationId(botSection, "tile.new.made-by");
        form.Children.Add(botSection);

        // 3. Ideas (below Made By, visible when prompt is empty)
        var ideasList = new StackPanel { Spacing = 4 };
        var ideasSection = SectionBlock(TileWords.Ideas, ideasList, null);
        AutomationProperties.SetAutomationId(ideasSection, "tile.new.ideas");
        form.Children.Add(ideasSection);

        // 4. Layout & Updates
        var layoutStack = new StackPanel { Spacing = 8 };
        var sizeCombo = new ComboBox { Header = TileWords.Size, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(sizeCombo, "tile.new.size");
        foreach (var s in TileSizes.All) sizeCombo.Items.Add(s.Title());
        sizeCombo.SelectedIndex = 0;
        sizeCombo.SelectionChanged += (_, _) =>
        {
            if (sizeCombo.SelectedIndex >= 0 && sizeCombo.SelectedIndex < TileSizes.All.Length)
                selectedSize = TileSizes.All[sizeCombo.SelectedIndex];
        };
        layoutStack.Children.Add(sizeCombo);

        var schedCombo = new ComboBox { Header = TileWords.Updates, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(schedCombo, "tile.new.schedule");
        foreach (var ch in TileScheduleChoice.AllChoices) schedCombo.Items.Add(ch.Title);
        schedCombo.SelectedIndex = 0;
        schedCombo.SelectionChanged += (_, _) =>
        {
            if (schedCombo.SelectedIndex >= 0 && schedCombo.SelectedIndex < TileScheduleChoice.AllChoices.Count)
                selectedSchedule = TileScheduleChoice.AllChoices[schedCombo.SelectedIndex];
        };
        layoutStack.Children.Add(schedCombo);

        if (pages.Count > 1)
        {
            var pageCombo = new ComboBox { Header = "Page", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(pageCombo, "tile.new.page");
            foreach (var p in pages) pageCombo.Items.Add(p.Name);
            pageCombo.SelectedIndex = Math.Max(0, pages.ToList().FindIndex(p => p.Id == selectedPageId));
            pageCombo.SelectionChanged += (_, _) =>
            {
                if (pageCombo.SelectedIndex >= 0 && pageCombo.SelectedIndex < pages.Count)
                    selectedPageId = pages[pageCombo.SelectedIndex].Id;
            };
            layoutStack.Children.Add(pageCombo);
        }
        form.Children.Add(SectionBlock(TileWords.LayoutAndUpdates, layoutStack, null));

        void RefreshCanMake() =>
            dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(whatBox.Text) && selectedBot != null;

        void RebuildIdeas()
        {
            var hasText = !string.IsNullOrWhiteSpace(whatBox.Text);
            ideasSection.Visibility = hasText ? Visibility.Collapsed : Visibility.Visible;
            if (hasText) return;
            ideasList.Children.Clear();
            var signals = selectedBot == null
                ? Array.Empty<string?>()
                : new[] { selectedBot.DisplayName, selectedBot.Name, selectedBot.Description };
            var ranked = TileIdeaMatcher.RankedFor(signals);
            var shown = showAllIdeas ? ranked : ranked.Take(TileIdeaMatcher.FirstIdeas).ToList();
            foreach (var idea in shown)
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new FontIcon
                {
                    Glyph = TileSymbolGlyphs.Glyph(idea.Symbol),
                    FontSize = 14,
                    Foreground = Kit.Brush("AccentTextFillColorPrimaryBrush"),
                    VerticalAlignment = VerticalAlignment.Center,
                });
                var label = Kit.Text(idea.Words, 13);
                label.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(label, 1);
                row.Children.Add(label);
                if (idea.Matched)
                {
                    var badge = new Border
                    {
                        CornerRadius = new CornerRadius(10),
                        Padding = new Thickness(7, 2, 7, 2),
                        VerticalAlignment = VerticalAlignment.Center,
                        Background = Kit.Brush("AccentFillColorSecondaryBrush"),
                        Child = new TextBlock
                        {
                            Text = TileWords.Fit,
                            FontSize = 11,
                            FontWeight = FontWeights.SemiBold,
                            Foreground = Kit.Brush("TextOnAccentFillColorPrimaryBrush"),
                        },
                    };
                    AutomationProperties.SetAutomationId(badge, "tile.new.idea.fit");
                    Grid.SetColumn(badge, 2);
                    row.Children.Add(badge);
                }
                var btn = new Button
                {
                    Content = row,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Padding = new Thickness(10, 7, 10, 7),
                    CornerRadius = new CornerRadius(8),
                    Background = Kit.Brush("CardBackgroundFillColorDefaultBrush"),
                    BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"),
                    BorderThickness = new Thickness(1),
                };
                AutomationProperties.SetName(btn, idea.Matched ? $"{idea.Words}, {TileWords.Fit}" : idea.Words);
                btn.Click += (_, _) =>
                {
                    whatBox.Text = idea.Words;
                    whatBox.SelectionStart = whatBox.Text.Length;
                };
                ideasList.Children.Add(btn);
            }
            if (!showAllIdeas && ranked.Count > TileIdeaMatcher.FirstIdeas)
            {
                var more = new Button
                {
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Padding = new Thickness(10, 7, 10, 7),
                    CornerRadius = new CornerRadius(8),
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0),
                    Content = new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 8,
                        Children =
                        {
                            new FontIcon { Glyph = "\uE712", FontSize = 14, Foreground = Kit.Brush("AccentTextFillColorPrimaryBrush") },
                            new TextBlock { Text = TileWords.MoreIdeas, FontSize = 13, Foreground = Kit.Brush("AccentTextFillColorPrimaryBrush") },
                        },
                    },
                };
                AutomationProperties.SetAutomationId(more, "tile.new.more-ideas");
                more.Click += (_, _) => { showAllIdeas = true; RebuildIdeas(); };
                ideasList.Children.Add(more);
            }
        }

        void RebuildBots()
        {
            botFlow.Children.Clear();
            foreach (var bot in orderedBots)
            {
                var b = bot;
                var isSelected = selectedBot?.Name == b.Name;
                var head = new BotHead { Bot = b, DisplayName = b.DisplayName, Width = 36, Height = 36, HorizontalAlignment = HorizontalAlignment.Center, IsHitTestVisible = false };
                var name = new TextBlock
                {
                    Text = b.DisplayName,
                    FontSize = 11.5,
                    FontWeight = isSelected ? FontWeights.SemiBold : FontWeights.Normal,
                    Foreground = isSelected ? Kit.Brush("AccentTextFillColorPrimaryBrush") : Kit.Brush("TextFillColorSecondaryBrush"),
                    MaxLines = 2,
                    TextAlignment = TextAlignment.Center,
                    TextWrapping = TextWrapping.Wrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                };
                var content = new StackPanel { Spacing = 4, Width = 72, HorizontalAlignment = HorizontalAlignment.Center, Children = { head, name } };
                var chip = new Button
                {
                    Content = content,
                    Padding = new Thickness(6, 6, 6, 6),
                    CornerRadius = new CornerRadius(12),
                    Background = isSelected ? Kit.Brush("SubtleFillColorSecondaryBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderBrush = isSelected ? Kit.Brush("AccentFillColorDefaultBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(isSelected ? 1.5 : 1),
                };
                AutomationProperties.SetName(chip, b.DisplayName);
                AutomationProperties.SetAutomationId(chip, "tile.new.bot." + b.Name);
                AutomationProperties.SetItemStatus(chip, isSelected ? "Selected" : "");
                chip.Click += (_, _) =>
                {
                    if (selectedBot?.Name == b.Name) return;
                    selectedBot = b;
                    RebuildBots();
                    RebuildIdeas();
                    RefreshCanMake();
                };
                botFlow.Children.Add(chip);
            }
        }

        whatBox.TextChanged += (_, _) => { RefreshCanMake(); RebuildIdeas(); };
        RebuildBots();
        RebuildIdeas();
        RefreshCanMake();

        dialog.Content = new ScrollViewer
        {
            Content = form,
            MaxHeight = 560,
            HorizontalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };

        while (true)
        {
            var result = await show(dialog);
            if (result == ContentDialogResult.Primary)
            {
                if (selectedBot == null || string.IsNullOrWhiteSpace(whatBox.Text)) return null;
                return new NewTileRequest(selectedBot, whatBox.Text.Trim(), selectedSize, selectedSchedule, selectedPageId);
            }
            var typed = whatBox.Text.Trim();
            var hasChanges = typed.Length > 0 && !TileIdeaMatcher.Catalog.Any(c => c.Words == typed);
            if (!hasChanges) return null;
            if (await ConfirmDiscardAsync(root, show)) return null;
        }
    }

    internal static async Task<bool> ConfirmDiscardAsync(XamlRoot root, Func<ContentDialog, Task<ContentDialogResult>> show)
    {
        var confirm = new ContentDialog
        {
            Title = "Discard Changes?",
            Content = new TextBlock
            {
                Text = "Your typed prompt hasn’t been sent yet.",
                TextWrapping = TextWrapping.Wrap,
            },
            XamlRoot = root,
            PrimaryButtonText = "Keep Editing",
            CloseButtonText = "Discard",
            DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(confirm, "tile.discard.confirm");
        return await show(confirm) != ContentDialogResult.Primary;
    }

    internal static StackPanel SectionBlock(string heading, UIElement content, string? footer)
    {
        var panel = new StackPanel { Spacing = 6 };
        var h = Kit.Text(heading.ToUpperInvariant(), 11, secondary: true, bold: true, wrap: false);
        AutomationProperties.SetHeadingLevel(h, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        panel.Children.Add(h);
        panel.Children.Add(content);
        if (!string.IsNullOrEmpty(footer)) panel.Children.Add(Kit.Text(footer, 11.5, secondary: true));
        return panel;
    }
}

/// [tiles-v2] Change Tile / Duplicate Tile dialog (`ChangeTile.swift`) with quick-change toggle chips.
internal static class ChangeTileDialog
{
    public static async Task<string?> ShowAsync(
        XamlRoot? root,
        string tileName,
        Bot bot,
        bool duplicate,
        string? statusLine,
        string initialWhat,
        Func<ContentDialog, Task<ContentDialogResult>> show)
    {
        if (root == null) return null;
        var dialog = new ContentDialog
        {
            Title = duplicate ? "Duplicate Tile" : "Change Tile",
            XamlRoot = root,
            PrimaryButtonText = duplicate ? "Duplicate" : "Change",
            CloseButtonText = TileWords.Cancel,
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(initialWhat),
        };
        AutomationProperties.SetAutomationId(dialog, "tile.change.sheet");

        var form = new StackPanel { Spacing = 14, MinWidth = 440, MaxWidth = 500 };

        // Tile summary header
        var headInfo = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        headInfo.Children.Add(Kit.Text(tileName, 14, bold: true));
        headInfo.Children.Add(Kit.Text(duplicate ? $"Based on this tile · made by {bot.DisplayName}" : $"Changed by {bot.DisplayName}", 12, secondary: true));
        if (!string.IsNullOrWhiteSpace(statusLine))
            headInfo.Children.Add(Kit.Text(statusLine, 11.5, secondary: true));
        var headerRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            Padding = new Thickness(12, 10, 12, 10),
            Children = { new BotHead { Bot = bot, DisplayName = bot.DisplayName, Width = 32, Height = 32 }, headInfo },
        };
        form.Children.Add(Kit.Card([headerRow]));

        var field = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Text = initialWhat,
            PlaceholderText = duplicate ? "For example: show expenses instead of revenue" : "For example: make it a bar chart and add last month",
            MinHeight = 76,
            MaxHeight = 160,
        };
        AutomationProperties.SetAutomationId(field, "tile.change.field");
        form.Children.Add(NewTileDialog.SectionBlock(duplicate ? "How Should the New Tile Differ?" : "What Should Change?", field, null));

        var chips = new TileFlowPanel { Spacing = 6, LineSpacing = 6 };
        void RebuildChips()
        {
            chips.Children.Clear();
            foreach (var quick in TileChangeWords.Quick)
            {
                var q = quick;
                var on = TileChangeWords.Contains(field.Text, q.Words);
                var btn = new Button
                {
                    Padding = new Thickness(10, 5, 10, 5),
                    CornerRadius = new CornerRadius(14),
                    Background = on ? Kit.Brush("AccentFillColorSecondaryBrush") : Kit.Brush("ControlFillColorSecondaryBrush"),
                    BorderBrush = on ? Kit.Brush("AccentFillColorDefaultBrush") : Kit.Brush("CardStrokeColorDefaultBrush"),
                    BorderThickness = new Thickness(1),
                    Content = new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 5,
                        Children =
                        {
                            new FontIcon
                            {
                                Glyph = on ? "\uE73E" : TileSymbolGlyphs.Glyph(q.Symbol),
                                FontSize = 11,
                                Foreground = on ? Kit.Brush("TextOnAccentFillColorPrimaryBrush") : Kit.Brush("TextFillColorPrimaryBrush"),
                            },
                            new TextBlock
                            {
                                Text = q.Label,
                                FontSize = 12,
                                Foreground = on ? Kit.Brush("TextOnAccentFillColorPrimaryBrush") : Kit.Brush("TextFillColorPrimaryBrush"),
                            },
                        },
                    },
                };
                AutomationProperties.SetName(btn, q.Label);
                AutomationProperties.SetAutomationId(btn, "tile.change.quick");
                btn.Click += (_, _) =>
                {
                    field.Text = TileChangeWords.Toggling(q.Words, field.Text);
                    field.SelectionStart = field.Text.Length;
                };
                chips.Children.Add(btn);
            }
        }
        field.TextChanged += (_, _) =>
        {
            dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(field.Text);
            RebuildChips();
        };
        RebuildChips();
        var footer = duplicate
            ? $"{bot.DisplayName} copies this tile’s style into a new tile in a separate chat. The original tile stays untouched."
            : $"{bot.DisplayName} changes it in a new chat. The tile stays where it is and shows it’s being changed, then it’s drawn again when it’s done.";
        form.Children.Add(NewTileDialog.SectionBlock("Quick Changes", chips, footer));

        dialog.Content = new ScrollViewer { Content = form, MaxHeight = 520, HorizontalScrollMode = ScrollMode.Disabled };
        var initialTrimmed = initialWhat.Trim();
        while (true)
        {
            var result = await show(dialog);
            if (result == ContentDialogResult.Primary)
                return string.IsNullOrWhiteSpace(field.Text) ? null : field.Text.Trim();
            var typed = field.Text.Trim();
            var hasChanges = typed.Length > 0 && typed != initialTrimmed;
            if (!hasChanges) return null;
            if (await NewTileDialog.ConfirmDiscardAsync(root, show)) return null;
        }
    }
}

/// One in-flight tile creation/change tracked on TilesPage, persisted via `TilePendingStore`, and rendered as an
/// inline `TileMakingCard` + in Tile Activity.
internal sealed class ActiveTileMaker
{
    public required string Id { get; init; }
    public required string AccountId { get; init; }
    public required Bot Bot { get; init; }
    public required string What { get; init; }
    public required string SessionId { get; init; }
    public string? PinId { get; init; }
    public string? PinName { get; init; }
    public string Path { get; init; } = "";
    public string DashboardPage { get; init; } = TilePage.MainId;
    public TileSize? DesiredSize { get; init; }
    public bool Acting { get; init; }
    public DateTimeOffset AskedAt { get; init; } = DateTimeOffset.UtcNow;
    public bool Watching { get; set; } = true;
    public string Status { get; set; } = "Working…";
    public Action? CancelAction { get; set; }
    public bool IsChange => PinId != null && !Acting;
    public string DisplayTitle => Acting && PinName != null ? $"Updating {PinName}: {What}" : PinName != null ? $"{PinName}: {What}" : What;
    public string TileWords => Acting ? "Updating…" : $"{Bot.DisplayName} is changing it…";

    public PendingTileMaker ToPending() => new()
    {
        Id = Id,
        AccountId = AccountId,
        SessionId = SessionId,
        BotId = Bot.Name,
        PinId = PinId,
        PinName = PinName,
        Path = Path,
        What = What,
        DashboardPage = DashboardPage,
        DesiredSize = DesiredSize,
        Acting = Acting,
        AskedAt = AskedAt.ToUnixTimeMilliseconds() / 1000.0,
    };
}

/// [tiles-v2] Inline `TileMakingCell` card shown at the top of the Tiles page while a tile is being made or changed
/// (`NewTile.swift` `TileMakingCell`): sparkles/wand icon, title, live step words, spinner, Stop button, chevron, tap opens chat.
internal static class TileMakingCard
{
    public static Border Create(ActiveTileMaker maker, Action openChat, Action stop)
    {
        var icon = new FontIcon
        {
            Glyph = maker.PinId != null ? "\uE70F" : "\uE734",
            FontSize = 18,
            Foreground = Kit.Brush("AccentTextFillColorPrimaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var title = new TextBlock
        {
            Text = maker.DisplayTitle,
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Kit.Brush("TextFillColorPrimaryBrush"),
        };
        var detail = new TextBlock
        {
            Text = $"{maker.Bot.DisplayName} · {maker.Status}",
            FontSize = 12,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = Kit.Brush("TextFillColorSecondaryBrush"),
        };
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Children = { title, detail } };
        var spinner = new ProgressRing { Width = 16, Height = 16, IsActive = true, VerticalAlignment = VerticalAlignment.Center };
        var stopBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE71A", FontSize = 13 },
            Padding = new Thickness(7, 5, 7, 5),
            CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(stopBtn, "Stop");
        AutomationProperties.SetName(stopBtn, "Stop");
        AutomationProperties.SetAutomationId(stopBtn, "tile.making.stop");
        stopBtn.Click += (_, _) => stop();

        var chevron = new FontIcon
        {
            Glyph = "\uE76C",
            FontSize = 11,
            Foreground = Kit.Brush("TextFillColorTertiaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };

        var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(14, 10, 14, 10) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(icon);
        Grid.SetColumn(words, 1); row.Children.Add(words);
        Grid.SetColumn(spinner, 2); row.Children.Add(spinner);
        Grid.SetColumn(stopBtn, 3); row.Children.Add(stopBtn);
        Grid.SetColumn(chevron, 4); row.Children.Add(chevron);

        var card = new Border
        {
            Child = row,
            CornerRadius = new CornerRadius(12),
            Background = Kit.Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(card, "tile.making");
        AutomationProperties.SetName(card, (maker.PinId != null ? "Changing a tile: " : "Making a tile: ") + maker.DisplayTitle);
        card.Tapped += (_, e) =>
        {
            if (e.OriginalSource is DependencyObject src && IsInside(src, stopBtn)) return;
            e.Handled = true;
            openChat();
        };
        return card;
    }

    private static bool IsInside(DependencyObject node, DependencyObject ancestor)
    {
        for (var cur = node; cur != null; cur = VisualTreeHelper.GetParent(cur))
            if (ReferenceEquals(cur, ancestor)) return true;
        return false;
    }
}

/// [tiles-v2] Failure recovery dialog (`TileMaker.offerChat`): `<Bot> Needs You` / `Couldn’t Make the Tile` /
/// `Couldn’t Change <Name>` with Not Now, Open Chat, and optional Try Again.
internal static class TileMakerFailureDialog
{
    public static async Task ShowAsync(
        XamlRoot? root,
        string title,
        string message,
        Action openChat,
        Action? retry,
        Func<ContentDialog, Task<ContentDialogResult>> show)
    {
        if (root == null) return;
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            XamlRoot = root,
            PrimaryButtonText = "Open Chat",
            CloseButtonText = "Not Now",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (retry != null) dialog.SecondaryButtonText = "Try Again";
        AutomationProperties.SetAutomationId(dialog, "tile.maker.failure");
        var result = await show(dialog);
        if (result == ContentDialogResult.Primary) openChat();
        else if (result == ContentDialogResult.Secondary) retry?.Invoke();
    }
}

/// [tile-models] Full model catalog chooser for a single tile (`Updates › Model › Other Model…`).
internal static class TileModelChooserDialog
{
    public static async Task<TileModelPick?> ShowAsync(
        XamlRoot? root,
        GatewaySession session,
        string profile,
        string botName,
        TileModelPick? current,
        Func<ContentDialog, Task<ContentDialogResult>> show)
    {
        if (root == null) return null;
        TileModelPick? picked = null;
        var dialog = new ContentDialog
        {
            Title = "Tile Model",
            XamlRoot = root,
            CloseButtonText = TileWords.Cancel,
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "tile.model.chooser");

        var search = new TextBox { PlaceholderText = "Search models…" };
        var list = new StackPanel { Spacing = 6 };
        var status = Kit.Text("Loading models…", 12.5, secondary: true);
        var ring = new ProgressRing { IsActive = true, Width = 20, Height = 20 };
        var body = new StackPanel
        {
            Spacing = 10,
            MinWidth = 420,
            MaxWidth = 500,
            Children =
            {
                Kit.Text($"This tile alone. {botName} keeps its own model for everything else.", 12, secondary: true),
                search,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { ring, status } },
                new ScrollViewer { Content = list, MaxHeight = 360, HorizontalScrollMode = ScrollMode.Disabled },
            },
        };
        dialog.Content = body;

        IReadOnlyList<ModelProviderOption> providers = [];
        void RenderList()
        {
            list.Children.Clear();
            var q = search.Text.Trim();
            foreach (var prov in providers.Where(p => p.IsReady && p.Models.Count > 0))
            {
                var matches = prov.Models.Where(m =>
                    q.Length == 0
                    || m.Contains(q, StringComparison.OrdinalIgnoreCase)
                    || ModelNames.DisplayModelName(m).Contains(q, StringComparison.OrdinalIgnoreCase)
                    || prov.Name.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
                if (matches.Count == 0) continue;
                list.Children.Add(Kit.Text(ModelNames.PlainProviderName(prov.Name), 11.5, secondary: true, bold: true));
                foreach (var modelId in matches)
                {
                    var pick = new TileModelPick(prov.Slug, modelId);
                    var selected = current != null && current.Same(pick);
                    var btn = new Button
                    {
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        HorizontalContentAlignment = HorizontalAlignment.Left,
                        Padding = new Thickness(10, 6, 10, 6),
                        CornerRadius = new CornerRadius(8),
                        Background = selected ? Kit.Brush("SubtleFillColorSecondaryBrush") : Kit.Brush("CardBackgroundFillColorDefaultBrush"),
                        BorderBrush = selected ? Kit.Brush("AccentFillColorDefaultBrush") : Kit.Brush("CardStrokeColorDefaultBrush"),
                        BorderThickness = new Thickness(1),
                        Content = new StackPanel
                        {
                            Spacing = 1,
                            Children =
                            {
                                Kit.Text(TileModels.Name(pick), 13, bold: selected),
                                Kit.Text(modelId, 11, secondary: true),
                            },
                        },
                    };
                    btn.Click += (_, _) => { picked = pick; dialog.Hide(); };
                    list.Children.Add(btn);
                }
            }
            if (list.Children.Count == 0 && !ring.IsActive)
                list.Children.Add(Kit.Text("No matching models.", 12.5, secondary: true));
        }

        search.TextChanged += (_, _) => RenderList();
        dialog.Loaded += async (_, _) =>
        {
            try
            {
                var api = new ModelSettingsApi(session, profile == "default" ? null : profile);
                providers = await api.GetModelOptionsAsync();
                ring.IsActive = false;
                ring.Visibility = Visibility.Collapsed;
                status.Visibility = Visibility.Collapsed;
                RenderList();
            }
            catch (Exception)
            {
                ring.IsActive = false;
                ring.Visibility = Visibility.Collapsed;
                status.Text = "Couldn’t load models from your gateway.";
            }
        };
        await show(dialog);
        ring.IsActive = false;
        return picked;
    }
}

/// One scheduled tile entry shown inside the Tile Activity dialog.
internal sealed record TileActivityRow(TilePin Pin, string TileName, string BotName, string? BotModel, TileCronJob Job);

/// [tiles-v2] Tile Activity dialog: summarizes active tile jobs & estimated daily runs, lists in-flight makers,
/// and provides per-tile Run Now / Pause / Resume plus batch Update All / Pause All / Resume All actions.
internal static class TileActivityDialog
{
    public static async Task ShowAsync(
        XamlRoot? root,
        IReadOnlyList<ActiveTileMaker> makers,
        IReadOnlyList<TileActivityRow> scheduled,
        Action<ActiveTileMaker> openMakerChat,
        Action<ActiveTileMaker> cancelMaker,
        Func<TileCronJob, Task> runJob,
        Func<TileCronJob, bool, Task> setJobPaused,
        Func<Task> updateAll,
        Func<bool, Task> setAllPaused,
        Func<ContentDialog, Task<ContentDialogResult>> show)
    {
        if (root == null) return;
        var summary = TileActivitySummary.Summarize(scheduled.Select(s => s.Job), DateTimeOffset.Now);
        var dialog = new ContentDialog
        {
            Title = TileWords.TileActivity,
            XamlRoot = root,
            CloseButtonText = TileWords.Done,
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "tile.activity.sheet");

        var body = new StackPanel { Spacing = 14, MinWidth = 460, MaxWidth = 540 };

        // Summary card
        var summaryPanel = new StackPanel { Spacing = 4, Padding = new Thickness(14, 12, 14, 12) };
        summaryPanel.Children.Add(Kit.Text(summary.Headline, 14, bold: true));
        if (summary.Detail is { } detail) summaryPanel.Children.Add(Kit.Text(detail, 12, secondary: true));
        if (scheduled.Count > 0)
        {
            var batch = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
            var runAllBtn = new Button { Content = TileWords.UpdateAllNow, FontSize = 12, Padding = new Thickness(10, 4, 10, 5) };
            AutomationProperties.SetAutomationId(runAllBtn, "tile.activity.update-all");
            runAllBtn.Click += async (_, _) => { runAllBtn.IsEnabled = false; await updateAll(); dialog.Hide(); };
            batch.Children.Add(runAllBtn);

            if (summary.ActiveJobs > 0)
            {
                var pauseAllBtn = new Button { Content = TileWords.PauseAllUpdates, FontSize = 12, Padding = new Thickness(10, 4, 10, 5) };
                AutomationProperties.SetAutomationId(pauseAllBtn, "tile.activity.pause-all");
                pauseAllBtn.Click += async (_, _) => { pauseAllBtn.IsEnabled = false; await setAllPaused(true); dialog.Hide(); };
                batch.Children.Add(pauseAllBtn);
            }
            if (summary.PausedJobs > 0)
            {
                var resumeAllBtn = new Button { Content = TileWords.ResumeAllUpdates, FontSize = 12, Padding = new Thickness(10, 4, 10, 5) };
                AutomationProperties.SetAutomationId(resumeAllBtn, "tile.activity.resume-all");
                resumeAllBtn.Click += async (_, _) => { resumeAllBtn.IsEnabled = false; await setAllPaused(false); dialog.Hide(); };
                batch.Children.Add(resumeAllBtn);
            }
            summaryPanel.Children.Add(batch);
        }
        body.Children.Add(Kit.Card([summaryPanel]));

        // Active makers
        if (makers.Count > 0)
        {
            var makerRows = new List<UIElement>();
            foreach (var maker in makers)
            {
                var m = maker;
                var row = new Grid { Padding = new Thickness(14, 10, 14, 10), ColumnSpacing = 10 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center });
                var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
                words.Children.Add(Kit.Text(m.DisplayTitle, 13, bold: true));
                words.Children.Add(Kit.Text($"{m.Bot.DisplayName} · {m.Status}", 11.5, secondary: true));
                Grid.SetColumn(words, 1);
                row.Children.Add(words);
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
                var openBtn = new Button { Content = "Open Chat", FontSize = 12, Padding = new Thickness(8, 3, 8, 4) };
                openBtn.Click += (_, _) => { dialog.Hide(); openMakerChat(m); };
                var stopBtn = new Button { Content = "Stop", FontSize = 12, Padding = new Thickness(8, 3, 8, 4) };
                stopBtn.Click += (_, _) => { cancelMaker(m); dialog.Hide(); };
                actions.Children.Add(openBtn);
                actions.Children.Add(stopBtn);
                Grid.SetColumn(actions, 2);
                row.Children.Add(actions);
                makerRows.Add(row);
            }
            body.Children.Add(NewTileDialog.SectionBlock("In Progress", Kit.Card(makerRows), null));
        }

        // Scheduled tile jobs
        if (scheduled.Count > 0)
        {
            var now = DateTimeOffset.Now;
            var jobRows = new List<UIElement>();
            foreach (var entry in scheduled)
            {
                var e = entry;
                var paused = TileJobs.IsPaused(e.Job);
                var row = new Grid { Padding = new Thickness(14, 10, 14, 10), ColumnSpacing = 10 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var words = new StackPanel { Spacing = 2 };
                words.Children.Add(Kit.Text(e.TileName, 13.5, bold: true));
                words.Children.Add(Kit.Text($"{TileJobs.Status(e.Job, now)} · {TileJobs.ModelWords(e.Job, e.BotName, e.BotModel)}", 11.5, secondary: true));
                row.Children.Add(words);
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
                var runBtn = new Button { Content = "Run", FontSize = 12, Padding = new Thickness(8, 3, 8, 4) };
                runBtn.Click += async (_, _) => { runBtn.IsEnabled = false; await runJob(e.Job); };
                var pauseBtn = new Button { Content = paused ? "Resume" : "Pause", FontSize = 12, Padding = new Thickness(8, 3, 8, 4) };
                pauseBtn.Click += async (_, _) => { pauseBtn.IsEnabled = false; await setJobPaused(e.Job, !paused); dialog.Hide(); };
                actions.Children.Add(runBtn);
                actions.Children.Add(pauseBtn);
                Grid.SetColumn(actions, 1);
                row.Children.Add(actions);
                jobRows.Add(row);
            }
            body.Children.Add(NewTileDialog.SectionBlock("Scheduled Tiles", Kit.Card(jobRows), null));
        }
        else if (makers.Count == 0)
        {
            body.Children.Add(Kit.Text("Tiles kept up to date by a scheduled job appear here.", 12.5, secondary: true));
        }

        dialog.Content = new ScrollViewer { Content = body, MaxHeight = 520, HorizontalScrollMode = ScrollMode.Disabled };
        await show(dialog);
    }
}
