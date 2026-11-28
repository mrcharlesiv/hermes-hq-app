using Hermes.Core.Shopping;
using HermesHQ.Features.Travel;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Shopping;

/// Product detail dialog (App/Shopping/ProductPageSheet.swift):
/// photo gallery, brand & title, price + struck list price + badge, rating/stock/delivery, options,
/// Buy / Notify Me / Notify Me of a Price Drop actions, Why It Fits, Where to Buy (safe links), and Details specs.
public static class ProductDetailDialog
{
    public static async Task ShowAsync(
        ProductOption product,
        XamlRoot? xamlRoot,
        Action<ShoppingAsk>? onAsk,
        IReadOnlySet<ShoppingAsk>? asks = null)
    {
        if (xamlRoot == null) return;
        var currentAsks = asks ?? new HashSet<ShoppingAsk>();
        var submitted = false;
        ContentDialog? dialog = null;

        void Submit(ShoppingAsk ask)
        {
            if (submitted) return;
            submitted = true;
            dialog?.Hide();
            onAsk?.Invoke(ask);
        }

        var body = new StackPanel { Spacing = 10, MinWidth = 440, MaxWidth = 560 };

        // Photos
        if (product.Images.Count == 1)
        {
            var singlePhoto = ShoppingUi.PhotoBox(product.Images[0], width: null, height: 220, radius: 14);
            singlePhoto.HorizontalAlignment = HorizontalAlignment.Stretch;
            body.Children.Add(singlePhoto);
        }
        else if (product.Images.Count > 1)
        {
            body.Children.Add(BuildPhotoPager(product));
        }

        if (product.Brand.Length > 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = product.Brand,
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
        }

        body.Children.Add(new TextBlock
        {
            Text = product.Title,
            FontSize = 17,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
        });

        // Price, struck list price, badge
        var priceRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (ShoppingCards.PriceText(product) is { } priceText)
        {
            priceRow.Children.Add(new TextBlock
            {
                Text = priceText,
                FontSize = 20,
                FontWeight = FontWeights.Bold,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            });
        }
        if (ShoppingCards.WasText(product) is { } wasText)
        {
            priceRow.Children.Add(new TextBlock
            {
                Text = wasText,
                FontSize = 14,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        if (product.Badge.Length > 0)
        {
            priceRow.Children.Add(new TextBlock
            {
                Text = product.Badge,
                FontSize = 12.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("HQTintTextBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        if (priceRow.Children.Count > 0)
            body.Children.Add(priceRow);

        // Facts line: rating, stock, delivery
        var facts = new List<string>();
        if (ShoppingCards.RatingText(product.Rating, product.Reviews) is { } rating) facts.Add($"★ {rating}");
        if (ShoppingCards.StockText(product.Stock) is { } stock) facts.Add(stock);
        if (product.Delivery.Length > 0) facts.Add(product.Delivery);
        if (facts.Count > 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = string.Join(" · ", facts),
                FontSize = 13,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        // Options card
        if (product.Options.Count > 0)
            body.Children.Add(KeyValueCard(product.Options.Select(o => (o.Name, o.Value))));

        // Buy / Notify Me actions
        if (ShoppingCards.AskedText(currentAsks) is { } askedText)
        {
            var askedRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 4, 0, 4) };
            askedRow.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 14, Foreground = ThemeBrushes.Get("HQTintTextBrush") });
            askedRow.Children.Add(new TextBlock
            {
                Text = askedText,
                FontSize = 13.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
            AutomationProperties.SetAutomationId(askedRow, "shopping.asked");
            body.Children.Add(askedRow);
        }
        else if (onAsk != null)
        {
            var mainAsk = product.Buyable ? ShoppingAsk.Buy : ShoppingAsk.WatchStock;
            var mainBtn = new Button
            {
                Content = product.Buyable ? "Buy" : "Notify Me",
                Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                CornerRadius = new CornerRadius(18),
                MinHeight = 38,
                FontWeight = FontWeights.SemiBold,
            };
            AutomationProperties.SetAutomationId(mainBtn, product.Buyable ? "shopping.buy" : "shopping.watch-stock");
            mainBtn.Click += (_, _) => Submit(mainAsk);
            body.Children.Add(mainBtn);

            if (product.Buyable && product.Price.HasValue)
            {
                var dropBtn = new Button
                {
                    Content = "Notify Me of a Price Drop",
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    CornerRadius = new CornerRadius(18),
                    MinHeight = 36,
                    FontWeight = FontWeights.SemiBold,
                };
                AutomationProperties.SetAutomationId(dropBtn, "shopping.watch-price");
                dropBtn.Click += (_, _) => Submit(ShoppingAsk.WatchPrice);
                body.Children.Add(dropBtn);
            }
        }

        // Why It Fits
        if (product.Why.Count > 0 || product.Caution.Count > 0)
        {
            body.Children.Add(TravelUi.SectionHeading("Why It Fits"));
            var lines = new StackPanel { Spacing = 8 };
            foreach (var w in product.Why)
                lines.Children.Add(TravelUi.BulletRow(w, "\uE73E", "HQGreenBrush"));
            foreach (var c in product.Caution)
                lines.Children.Add(TravelUi.BulletRow(c, "\uE7BA", "HQOrangeBrush"));
            body.Children.Add(TravelUi.SectionCard(lines));
        }

        // Where to Buy
        body.Children.Add(TravelUi.SectionHeading("Where to Buy"));
        var here = new ProductOffer(product.Store, product.Url, product.Price, product.Was, product.Stock, product.Delivery);
        var allOffers = new List<ProductOffer>(1 + product.Offers.Count) { here };
        allOffers.AddRange(product.Offers);
        var offersStack = new StackPanel { Spacing = 4 };
        for (var i = 0; i < allOffers.Count; i++)
        {
            if (i > 0)
            {
                offersStack.Children.Add(new Border
                {
                    Height = 1,
                    Background = ThemeBrushes.Get("DividerStrokeColorDefaultBrush"),
                });
            }
            offersStack.Children.Add(OfferRow(allOffers[i], product.Currency, quiet: i == 0));
        }
        body.Children.Add(TravelUi.SectionCard(offersStack));

        // Details / Specs
        if (product.Specs.Count > 0)
        {
            body.Children.Add(TravelUi.SectionHeading("Details"));
            body.Children.Add(KeyValueCard(product.Specs.Select(s => (s.Label, s.Value))));
        }

        var scroll = new ScrollViewer
        {
            Content = body,
            MaxHeight = 580,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
        };

        dialog = new ContentDialog
        {
            Title = TravelUi.DialogTitle(product.Store),
            Content = scroll,
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "shopping.page");
        await SafeDialog.ShowAsync(xamlRoot, dialog);
    }

    private static UIElement BuildPhotoPager(ProductOption product)
    {
        var index = 0;
        var count = product.Images.Count;
        var stack = new StackPanel { Spacing = 6 };
        var photoHost = new Grid();
        var counter = new TextBlock
        {
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var prev = new Button { Content = "‹ Prev", CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 4, 10, 4) };
        var next = new Button { Content = "Next ›", CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 4, 10, 4) };

        void Show(int i)
        {
            if (i < 0 || i >= count) return;
            index = i;
            photoHost.Children.Clear();
            var photo = ShoppingUi.PhotoBox(product.Images[index], width: null, height: 220, radius: 14);
            photo.HorizontalAlignment = HorizontalAlignment.Stretch;
            photoHost.Children.Add(photo);
            counter.Text = $"{index + 1} / {count}";
            prev.IsEnabled = index > 0;
            next.IsEnabled = index < count - 1;
        }

        prev.Click += (_, _) => Show(index - 1);
        next.Click += (_, _) => Show(index + 1);

        var bar = new Grid { ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(prev);
        Grid.SetColumn(counter, 1);
        bar.Children.Add(counter);
        Grid.SetColumn(next, 2);
        bar.Children.Add(next);

        stack.Children.Add(photoHost);
        stack.Children.Add(bar);
        Show(0);
        return stack;
    }

    private static UIElement KeyValueCard(IEnumerable<(string Key, string Value)> pairs)
    {
        var stack = new StackPanel { Spacing = 6 };
        var first = true;
        foreach (var (key, value) in pairs)
        {
            if (!first)
            {
                stack.Children.Add(new Border
                {
                    Height = 1,
                    Background = ThemeBrushes.Get("DividerStrokeColorDefaultBrush"),
                });
            }
            first = false;
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new TextBlock
            {
                Text = key,
                FontSize = 13,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
            var val = new TextBlock
            {
                Text = value,
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                HorizontalAlignment = HorizontalAlignment.Right,
                TextAlignment = TextAlignment.Right,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            };
            Grid.SetColumn(val, 1);
            row.Children.Add(val);
            stack.Children.Add(row);
        }
        return TravelUi.SectionCard(stack);
    }

    private static UIElement OfferRow(ProductOffer offer, string currency, bool quiet)
    {
        var rowStack = new StackPanel { Spacing = 2 };
        var top = new Grid { ColumnSpacing = 8 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        top.Children.Add(new TextBlock
        {
            Text = offer.Store,
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            TextWrapping = TextWrapping.Wrap,
        });

        var prices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (offer.Price is { } amount)
        {
            prices.Children.Add(new TextBlock
            {
                Text = ShoppingCards.FormatPrice(amount, currency),
                FontSize = 13.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            });
        }
        if (offer.Was is { } was)
        {
            prices.Children.Add(new TextBlock
            {
                Text = ShoppingCards.FormatPrice(was, currency),
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough,
            });
        }
        Grid.SetColumn(prices, 1);
        top.Children.Add(prices);

        var arrow = new FontIcon
        {
            Glyph = "\uE8A7",
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(arrow, 2);
        top.Children.Add(arrow);
        rowStack.Children.Add(top);

        if (!quiet)
        {
            var under = new List<string>();
            if (ShoppingCards.StockText(offer.Stock) is { } st) under.Add(st);
            if (offer.Delivery.Length > 0) under.Add(offer.Delivery);
            if (under.Count > 0)
            {
                rowStack.Children.Add(new TextBlock
                {
                    Text = string.Join(" · ", under),
                    FontSize = 12,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
        }

        var btn = new Button
        {
            Content = rowStack,
            Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(4, 6, 4, 6),
        };
        btn.Click += (_, _) => ShoppingUi.OpenSafeLink(offer.Url);
        return btn;
    }
}
