using Hermes.Core.Model;
using Hermes.Core.Shopping;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Shopping;

/// Native WinUI 3 card for `order_card` (App/Shopping/OrderCardView.swift):
/// store header, clickable line items opening `ProductDetailDialog`, charges, bold total, shipping/payment details,
/// and Pay / Cancel actions that transition immediately to the settled state.
public static class OrderCardView
{
    private const double MaxCardWidth = 660;

    /// Builds an order card for an `order_card` tool call, or returns null if invalid.
    public static UIElement? TryBuild(ToolCall call, Action<string>? sendMessage) =>
        TryBuild(call, sendMessage, OrderState.Waiting, catalogHistory: null);

    /// Builds an order card with explicit settled state and prior catalog history for line-item product resolution.
    public static UIElement? TryBuild(
        ToolCall call,
        Action<string>? sendMessage,
        OrderState initialState,
        IReadOnlyList<ProductOption>? catalogHistory)
    {
        if (ShoppingCards.ParseOrder(call) is not { } order) return null;
        return Build(order, sendMessage, initialState, catalogHistory);
    }

    private static UIElement Build(
        OrderCard order,
        Action<string>? sendMessage,
        OrderState initialState,
        IReadOnlyList<ProductOption>? catalogHistory)
    {
        var state = initialState;
        var card = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14, 12, 14, 12),
            Margin = new Thickness(16, 6, 16, 6),
            MaxWidth = MaxCardWidth,
            HorizontalAlignment = HorizontalAlignment.Left,
            Background = ThemeBrushes.Get("HQPromptCardBrush"),
            BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(card, "shopping.order");

        void Render()
        {
            var settled = state != OrderState.Waiting;
            var dim = state is OrderState.Cancelled or OrderState.Replaced;
            var ink = ThemeBrushes.Get(settled ? "TextFillColorSecondaryBrush" : "TextFillColorPrimaryBrush");

            var stack = new StackPanel { Spacing = 6 };

            // Header: round bag icon + "Order at <store>"
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(new Border
            {
                Width = 26,
                Height = 26,
                CornerRadius = new CornerRadius(13),
                Background = ThemeBrushes.Get(dim ? "ControlStrongFillColorDisabledBrush" : "AccentFillColorDefaultBrush"),
                Child = new FontIcon
                {
                    Glyph = "\uE7BF",
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get("TextOnAccentFillColorPrimaryBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            });
            head.Children.Add(new TextBlock
            {
                Text = $"Order at {order.Store}",
                FontSize = 14.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
            });
            stack.Children.Add(head);

            // Line items (clickable when product page resolves)
            var itemsPanel = new StackPanel { Spacing = 4, Margin = new Thickness(0, 4, 0, 0) };
            for (var i = 0; i < order.Items.Count; i++)
            {
                var item = order.Items[i];
                var resolved = ShoppingCards.ProductFor(item, order, catalogHistory);
                var openable = resolved != null;

                var rowGrid = new Grid { ColumnSpacing = 8 };
                rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                if (openable)
                    rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                var itemLeft = new StackPanel { Spacing = 1 };
                itemLeft.Children.Add(new TextBlock
                {
                    Text = $"{item.Qty} × {item.Title}",
                    FontSize = 13.5,
                    Foreground = openable && !settled ? ThemeBrushes.Get("HQTintTextBrush") : ink,
                    TextWrapping = TextWrapping.Wrap,
                });
                if (item.Detail.Length > 0)
                {
                    itemLeft.Children.Add(new TextBlock
                    {
                        Text = item.Detail,
                        FontSize = 12,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        MaxLines = 1,
                    });
                }
                rowGrid.Children.Add(itemLeft);

                if (item.Price is { } price)
                {
                    var pText = new TextBlock
                    {
                        Text = ShoppingCards.FormatPrice(price, order.Currency),
                        FontSize = 13.5,
                        Foreground = ink,
                        VerticalAlignment = VerticalAlignment.Top,
                    };
                    Grid.SetColumn(pText, 1);
                    rowGrid.Children.Add(pText);
                }

                if (openable && resolved != null)
                {
                    var chev = new FontIcon
                    {
                        Glyph = "\uE76C",
                        FontSize = 10,
                        Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                    Grid.SetColumn(chev, 2);
                    rowGrid.Children.Add(chev);

                    var itemBtn = new Button
                    {
                        Content = rowGrid,
                        Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        HorizontalContentAlignment = HorizontalAlignment.Stretch,
                        Padding = new Thickness(4, 3, 4, 3),
                        CornerRadius = new CornerRadius(8),
                    };
                    AutomationProperties.SetAutomationId(itemBtn, $"order.item.{i}");
                    AutomationProperties.SetName(itemBtn, $"Open {item.Title}");
                    itemBtn.Click += (_, _) =>
                    {
                        var xr = card.XamlRoot ?? App.Window?.Content?.XamlRoot;
                        _ = ProductDetailDialog.ShowAsync(resolved, xr, ask =>
                        {
                            if (ShoppingCards.FormatMessage(ask, resolved) is { } msg)
                                sendMessage?.Invoke(msg);
                        });
                    };
                    itemsPanel.Children.Add(itemBtn);
                }
                else
                {
                    itemsPanel.Children.Add(rowGrid);
                }
            }
            stack.Children.Add(itemsPanel);

            // Charges
            if (order.Charges.Count > 0)
            {
                var chargesPanel = new StackPanel { Spacing = 2, Margin = new Thickness(0, 2, 0, 0) };
                foreach (var charge in order.Charges)
                {
                    var line = new Grid { ColumnSpacing = 8 };
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    line.Children.Add(new TextBlock
                    {
                        Text = charge.Label,
                        FontSize = 12.5,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    });
                    var amt = new TextBlock
                    {
                        Text = ShoppingCards.ChargeAmountText(charge.Amount, order.Currency),
                        FontSize = 12.5,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    };
                    Grid.SetColumn(amt, 1);
                    line.Children.Add(amt);
                    chargesPanel.Children.Add(line);
                }
                stack.Children.Add(chargesPanel);
            }

            // Divider + Total
            stack.Children.Add(new Border
            {
                Height = 1,
                Margin = new Thickness(0, 4, 0, 2),
                Background = ThemeBrushes.Get("DividerStrokeColorDefaultBrush"),
            });
            var totalRow = new Grid { ColumnSpacing = 8 };
            totalRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            totalRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            totalRow.Children.Add(new TextBlock
            {
                Text = "Total",
                FontSize = 14.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ink,
            });
            var totalVal = new TextBlock
            {
                Text = ShoppingCards.TotalText(order),
                FontSize = 14.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ink,
            };
            Grid.SetColumn(totalVal, 1);
            totalRow.Children.Add(totalVal);
            stack.Children.Add(totalRow);

            // Details: Ship to, Pay with, Arrives
            var details = new List<(string Label, string Value)>();
            var ship = string.Join(", ", new[] { order.ShipName, order.ShipAddress }.Where(s => s.Length > 0));
            if (ship.Length > 0) details.Add(("Ship to", ship));
            if (order.PayWith.Length > 0) details.Add(("Pay with", order.PayWith));
            if (order.Arrives.Length > 0) details.Add(("Arrives", order.Arrives));
            if (details.Count > 0)
            {
                var detailGrid = new Grid { ColumnSpacing = 10, RowSpacing = 3, Margin = new Thickness(0, 6, 0, 0) };
                detailGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                detailGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                for (var r = 0; r < details.Count; r++)
                {
                    detailGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                    var lbl = new TextBlock
                    {
                        Text = details[r].Label,
                        FontSize = 12,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    };
                    var val = new TextBlock
                    {
                        Text = details[r].Value,
                        FontSize = 12,
                        Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                        TextWrapping = TextWrapping.Wrap,
                        MaxLines = 2,
                    };
                    Grid.SetRow(lbl, r);
                    Grid.SetRow(val, r);
                    Grid.SetColumn(val, 1);
                    detailGrid.Children.Add(lbl);
                    detailGrid.Children.Add(val);
                }
                stack.Children.Add(detailGrid);
            }

            if (order.Note.Length > 0)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = order.Note,
                    FontSize = 12,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 3,
                    Margin = new Thickness(0, 4, 0, 0),
                });
            }

            // Footer: status when settled, else Cancel + Pay
            if (ShoppingCards.StatusText(state, order) is { } statusText)
            {
                var statusRow = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    Margin = new Thickness(0, 8, 0, 0),
                };
                statusRow.Children.Add(new FontIcon
                {
                    Glyph = state == OrderState.Approved ? "\uE73E" : state == OrderState.Replaced ? "\uE8AB" : "\uE738",
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get(state == OrderState.Approved ? "HQTintTextBrush" : "TextFillColorTertiaryBrush"),
                });
                statusRow.Children.Add(new TextBlock
                {
                    Text = statusText,
                    FontSize = 12.5,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                });
                stack.Children.Add(statusRow);
            }
            else
            {
                var buttons = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Margin = new Thickness(0, 10, 0, 0),
                };
                var cancelBtn = new Button
                {
                    Content = "Cancel",
                    CornerRadius = new CornerRadius(16),
                    Padding = new Thickness(14, 6, 14, 6),
                    MinHeight = 34,
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0),
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    FontWeight = FontWeights.SemiBold,
                };
                AutomationProperties.SetAutomationId(cancelBtn, "order.cancel");
                cancelBtn.Click += (_, _) =>
                {
                    state = OrderState.Cancelled;
                    sendMessage?.Invoke(ShoppingCards.CancelMessage(order));
                    Render();
                };
                var payBtn = new Button
                {
                    Content = $"Pay {ShoppingCards.TotalText(order)}",
                    Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
                    CornerRadius = new CornerRadius(16),
                    Padding = new Thickness(16, 6, 16, 6),
                    MinHeight = 34,
                    FontWeight = FontWeights.SemiBold,
                };
                AutomationProperties.SetAutomationId(payBtn, "order.pay");
                payBtn.Click += (_, _) =>
                {
                    state = OrderState.Approved;
                    sendMessage?.Invoke(ShoppingCards.PayMessage(order));
                    Render();
                };
                buttons.Children.Add(cancelBtn);
                buttons.Children.Add(payBtn);
                stack.Children.Add(buttons);
            }

            card.Child = stack;
        }

        Render();
        return card;
    }
}
