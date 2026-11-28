using Hermes.Core.Model;
using Hermes.Core.Shopping;
using Hermes.Core.Travel;
using HermesHQ.Features.Travel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace HermesHQ.Features.Shopping;

/// Native WinUI 3 cards for `show_products` (App/Shopping/ProductCardsView.swift):
/// 1 = single wide card with Buy / Notify Me, 2 = side-by-side pair, 3–8 = horizontal carousel strip,
/// 9–12 = compact list card (first 5 + "N more ›"). Tapping any product opens `ProductDetailDialog`.
public static class ProductCardsView
{
    private const int ListFirst = 5;
    private const double MaxCardWidth = 660;

    /// Builds a product cards view for a `show_products` tool call, or returns null if invalid.
    public static UIElement? TryBuild(ToolCall call, Action<string>? sendMessage)
    {
        if (ShoppingCards.ParseProducts(call) is not { } model) return null;
        return Build(model, sendMessage);
    }

    private static UIElement Build(ProductList model, Action<string>? sendMessage)
    {
        var asked = new Dictionary<string, HashSet<ShoppingAsk>>(StringComparer.Ordinal);
        var expanded = false;

        var root = new StackPanel
        {
            Spacing = 8,
            MaxWidth = MaxCardWidth,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(16, 6, 16, 6),
        };
        AutomationProperties.SetAutomationId(root, "shopping.products");

        void HandleAsk(ProductOption product, ShoppingAsk ask)
        {
            if (ShoppingCards.FormatMessage(ask, product) is not { } message) return;
            if (!asked.TryGetValue(product.Id, out var set))
            {
                set = [];
                asked[product.Id] = set;
            }
            set.Add(ask);
            sendMessage?.Invoke(message);
            Render();
        }

        void OpenDetail(ProductOption product)
        {
            var xr = root.XamlRoot ?? App.Window?.Content?.XamlRoot;
            IReadOnlySet<ShoppingAsk> current = asked.TryGetValue(product.Id, out var set) ? set : new HashSet<ShoppingAsk>();
            _ = ProductDetailDialog.ShowAsync(product, xr, ask => HandleAsk(product, ask), current);
        }

        void Render()
        {
            root.Children.Clear();

            if (model.Note.Length > 0)
            {
                root.Children.Add(new TextBlock
                {
                    Text = model.Note,
                    FontSize = 13.5,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 2,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
            }

            var count = model.Products.Count;
            if (count == 1)
            {
                var p = model.Products[0];
                IReadOnlySet<ShoppingAsk> pAsks = asked.TryGetValue(p.Id, out var set) ? set : new HashSet<ShoppingAsk>();
                root.Children.Add(BuildSingleCard(p, pAsks, () => OpenDetail(p), ask => HandleAsk(p, ask)));
            }
            else if (count == 2)
            {
                var grid = new Grid { ColumnSpacing = 8 };
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                for (var i = 0; i < 2; i++)
                {
                    var p = model.Products[i];
                    var tile = (FrameworkElement)BuildTileCard(p, width: null, photoHeight: 160, () => OpenDetail(p));
                    Grid.SetColumn(tile, i);
                    grid.Children.Add(tile);
                }
                root.Children.Add(grid);
            }
            else if (count <= 8)
            {
                var strip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                foreach (var product in model.Products)
                {
                    var p = product;
                    strip.Children.Add(BuildTileCard(p, width: 204, photoHeight: 136, () => OpenDetail(p)));
                }
                root.Children.Add(new ScrollViewer
                {
                    Content = strip,
                    HorizontalScrollMode = ScrollMode.Auto,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    VerticalScrollMode = ScrollMode.Disabled,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    MaxWidth = MaxCardWidth,
                });
            }
            else
            {
                var listStack = new StackPanel();
                var shown = expanded ? count : Math.Min(count, ListFirst);
                for (var i = 0; i < shown; i++)
                {
                    if (i > 0)
                    {
                        listStack.Children.Add(new Border
                        {
                            Height = 1,
                            Margin = new Thickness(70, 0, 0, 0),
                            Background = ThemeBrushes.Get("DividerStrokeColorDefaultBrush"),
                        });
                    }
                    var p = model.Products[i];
                    listStack.Children.Add(BuildListRow(p, () => OpenDetail(p)));
                }
                if (count > ListFirst)
                {
                    listStack.Children.Add(new Border
                    {
                        Height = 1,
                        Margin = new Thickness(70, 0, 0, 0),
                        Background = ThemeBrushes.Get("DividerStrokeColorDefaultBrush"),
                    });
                    var more = new Button
                    {
                        Content = expanded ? "Show Less" : $"{count - ListFirst} more ›",
                        Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
                        Foreground = ThemeBrushes.Get("HQTintTextBrush"),
                        FontWeight = FontWeights.SemiBold,
                        FontSize = 12.5,
                        Margin = new Thickness(62, 2, 8, 2),
                        HorizontalAlignment = HorizontalAlignment.Left,
                    };
                    AutomationProperties.SetAutomationId(more, "shopping.seeAll");
                    more.Click += (_, _) => { expanded = !expanded; Render(); };
                    listStack.Children.Add(more);
                }
                root.Children.Add(new Border
                {
                    Child = listStack,
                    CornerRadius = new CornerRadius(14),
                    Background = ThemeBrushes.Get("HQPromptCardBrush"),
                    BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
                    BorderThickness = new Thickness(1),
                });
            }

            if (model.FollowUps.Count > 0)
            {
                var chips = new TravelFlowPanel { Spacing = 6, LineSpacing = 6 };
                foreach (var text in model.FollowUps)
                {
                    var prompt = text;
                    var chip = new Button
                    {
                        Content = prompt,
                        CornerRadius = new CornerRadius(16),
                        Padding = new Thickness(12, 5, 12, 5),
                        FontSize = 12.5,
                        FontWeight = FontWeights.Medium,
                    };
                    AutomationProperties.SetAutomationId(chip, "shopping.followUp");
                    chip.Click += (_, _) => sendMessage?.Invoke(prompt);
                    chips.Children.Add(chip);
                }
                root.Children.Add(chips);
            }
        }

        Render();
        return root;
    }

    private static UIElement BuildSingleCard(
        ProductOption product,
        IReadOnlySet<ShoppingAsk> asks,
        Action onOpen,
        Action<ShoppingAsk> onAsk)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var photo = ShoppingUi.PhotoWithBadge(product, width: 96, height: 96, radius: 10);
        grid.Children.Add(photo);

        var info = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(new TextBlock
        {
            Text = product.Title,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        info.Children.Add(ShoppingUi.PriceAndRatingLine(product));

        var bottom = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 4, 0, 0) };
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bottom.Children.Add(new TextBlock
        {
            Text = product.Store,
            FontSize = 12.5,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });

        var mainAsk = product.Buyable ? ShoppingAsk.Buy : ShoppingAsk.WatchStock;
        var done = product.Buyable ? asks.Contains(ShoppingAsk.Buy) : asks.Contains(ShoppingAsk.WatchStock);
        if (done)
        {
            var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            status.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 13, Foreground = ThemeBrushes.Get("HQTintTextBrush") });
            status.Children.Add(new TextBlock
            {
                Text = product.Buyable ? "Asked to buy" : "Watching",
                FontSize = 12.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
            Grid.SetColumn(status, 1);
            bottom.Children.Add(status);
        }
        else
        {
            var buyBtn = new Button
            {
                Content = product.Buyable ? "Buy" : "Notify Me",
                Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
                CornerRadius = new CornerRadius(16),
                Padding = new Thickness(14, 5, 14, 5),
                FontWeight = FontWeights.SemiBold,
            };
            AutomationProperties.SetAutomationId(buyBtn, "shopping.cardBuy");
            buyBtn.Tapped += (_, e) => e.Handled = true;
            buyBtn.Click += (_, _) => onAsk(mainAsk);
            Grid.SetColumn(buyBtn, 1);
            bottom.Children.Add(buyBtn);
        }
        info.Children.Add(bottom);

        Grid.SetColumn(info, 1);
        grid.Children.Add(info);

        var card = new Border
        {
            Child = grid,
            Padding = new Thickness(10),
            CornerRadius = new CornerRadius(14),
            Background = ThemeBrushes.Get("HQPromptCardBrush"),
            BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
            BorderThickness = new Thickness(1),
        };
        card.Tapped += (_, _) => onOpen();
        AutomationProperties.SetAutomationId(card, "shopping.card");
        AutomationProperties.SetName(card, product.Title);
        return card;
    }

    private static UIElement BuildTileCard(ProductOption product, double? width, double photoHeight, Action onOpen)
    {
        var stack = new StackPanel();
        if (width.HasValue) stack.Width = width.Value;

        stack.Children.Add(ShoppingUi.PhotoWithBadge(product, width: width, height: photoHeight, radius: 0));

        var info = new StackPanel { Spacing = 3, Padding = new Thickness(10, 8, 10, 10) };
        info.Children.Add(new TextBlock
        {
            Text = product.Title,
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        info.Children.Add(ShoppingUi.PriceAndRatingLine(product));
        info.Children.Add(new TextBlock
        {
            Text = product.Store,
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        stack.Children.Add(info);

        var btn = new Button
        {
            Content = stack,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(14),
            Background = ThemeBrushes.Get("HQPromptCardBrush"),
            BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = width.HasValue ? HorizontalAlignment.Left : HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top,
        };
        AutomationProperties.SetAutomationId(btn, "shopping.card");
        AutomationProperties.SetName(btn, product.Title);
        btn.Click += (_, _) => onOpen();
        return btn;
    }

    private static UIElement BuildListRow(ProductOption product, Action onOpen)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var thumb = ShoppingUi.PhotoBox(product.Image, width: 48, height: 48, radius: 8, dimmed: product.Stock == StockState.Out);
        grid.Children.Add(thumb);

        var info = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var topLine = new Grid { ColumnSpacing = 8 };
        topLine.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topLine.Children.Add(new TextBlock
        {
            Text = product.Title,
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var accessoryText = ShoppingCards.StockText(product.Stock) ?? (product.Badge.Length > 0 ? product.Badge : null);
        if (accessoryText != null)
        {
            var acc = new TextBlock
            {
                Text = accessoryText,
                FontSize = 12,
                FontWeight = ShoppingCards.StockText(product.Stock) != null ? FontWeights.Normal : FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get(ShoppingCards.StockText(product.Stock) != null
                    ? "TextFillColorSecondaryBrush" : "HQTintTextBrush"),
            };
            Grid.SetColumn(acc, 1);
            topLine.Children.Add(acc);
        }
        info.Children.Add(topLine);

        var metaParts = new List<string>();
        if (ShoppingCards.PriceText(product) is { } price) metaParts.Add(price);
        metaParts.Add(product.Store);
        if (ShoppingCards.RatingText(product.Rating, reviews: null) is { } rating) metaParts.Add($"★ {rating}");
        info.Children.Add(new TextBlock
        {
            Text = string.Join(" · ", metaParts),
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        Grid.SetColumn(info, 1);
        grid.Children.Add(info);

        var btn = new Button
        {
            Content = grid,
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(12, 8, 12, 8),
        };
        AutomationProperties.SetAutomationId(btn, "shopping.card");
        AutomationProperties.SetName(btn, product.Title);
        btn.Click += (_, _) => onOpen();
        return btn;
    }
}

/// Shared WinUI helpers for shopping cards and dialogs.
internal static class ShoppingUi
{
    public static void OpenSafeLink(Uri? uri)
    {
        if (!TravelCards.IsSafeWebUri(uri)) return;
        try { _ = Launcher.LaunchUriAsync(uri); }
        catch (Exception) { }
    }

    public static Border PhotoBox(Uri? uri, double? width, double height, double radius = 0, bool dimmed = false)
    {
        var grid = new Grid
        {
            Height = height,
            Opacity = dimmed ? 0.55 : 1.0,
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
        };
        if (width.HasValue) grid.Width = width.Value;

        var placeholder = new FontIcon
        {
            Glyph = "\uE7BF",
            FontSize = 22,
            Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        grid.Children.Add(placeholder);

        if (uri != null && TravelCards.IsSafeWebUri(uri))
        {
            var decodeW = width.HasValue ? (int)Math.Ceiling(width.Value * 2) : 720;
            var bmp = new BitmapImage(uri) { DecodePixelWidth = decodeW };
            var img = new Image { Source = bmp, Stretch = Stretch.UniformToFill, Opacity = 0 };
            bmp.ImageOpened += (_, _) => { img.Opacity = 1; placeholder.Visibility = Visibility.Collapsed; };
            bmp.ImageFailed += (_, _) => { img.Visibility = Visibility.Collapsed; };
            grid.Children.Add(img);
        }

        return new Border
        {
            Child = grid,
            CornerRadius = new CornerRadius(radius),
        };
    }

    public static Grid PhotoWithBadge(ProductOption product, double? width, double height, double radius)
    {
        var container = new Grid { Height = height };
        if (width.HasValue) container.Width = width.Value;
        container.Children.Add(PhotoBox(product.Image, width, height, radius, dimmed: product.Stock == StockState.Out));

        var stockText = ShoppingCards.StockText(product.Stock);
        var pillText = stockText ?? (product.Badge.Length > 0 ? product.Badge : null);
        if (pillText != null)
        {
            var quiet = stockText != null;
            var badge = new Border
            {
                Padding = new Thickness(7, 2, 7, 2),
                CornerRadius = new CornerRadius(10),
                Margin = new Thickness(6),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Background = ThemeBrushes.Get(quiet ? "HQPromptCardBrush" : "AccentFillColorDefaultBrush"),
                Child = new TextBlock
                {
                    Text = pillText,
                    FontSize = 11,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get(quiet ? "TextFillColorPrimaryBrush" : "TextOnAccentFillColorPrimaryBrush"),
                },
            };
            container.Children.Add(badge);
        }
        return container;
    }

    public static UIElement PriceAndRatingLine(ProductOption product)
    {
        var row = new Grid { ColumnSpacing = 6 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var priceRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (ShoppingCards.PriceText(product) is { } price)
        {
            priceRow.Children.Add(new TextBlock
            {
                Text = price,
                FontSize = 13.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            });
        }
        if (ShoppingCards.WasText(product) is { } was)
        {
            priceRow.Children.Add(new TextBlock
            {
                Text = was,
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        if (priceRow.Children.Count == 0 && ShoppingCards.StockText(product.Stock) is { } stock)
        {
            priceRow.Children.Add(new TextBlock
            {
                Text = stock,
                FontSize = 13,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
        }
        row.Children.Add(priceRow);

        if (ShoppingCards.RatingText(product.Rating, reviews: null) is { } rating)
        {
            var rText = new TextBlock
            {
                Text = $"★ {rating}",
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(rText, 1);
            row.Children.Add(rText);
        }
        return row;
    }
}
