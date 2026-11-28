using Hermes.Core.Model;
using Hermes.Core.Shopping;
using Hermes.Core.Travel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.System;

namespace HermesHQ.Features.Travel;

/// Native WinUI 3 cards for `show_flights` and `show_hotels` (App/Travel/TravelCardsView.swift).
/// Uses `HQPromptCardBrush` / `HQPromptEdgeBrush`, 2-line hotel/flight titles, wrapping headers, and opens
/// `FlightDetailDialog` or `HotelDetailDialog`.
public static class TravelCardsView
{
    private const int FlightsShownCollapsed = 4;
    private const double MaxCardWidth = 660;

    /// Builds a flight or hotel card for a travel tool call, or returns null if not a valid travel card.
    public static UIElement? TryBuild(ToolCall call, Action<string>? sendMessage)
    {
        if (call.Name == TravelCards.FlightsTool && TravelCards.ParseFlights(call) is { } flights)
            return BuildFlights(flights, sendMessage);
        if (call.Name == TravelCards.HotelsTool && TravelCards.ParseHotels(call) is { } hotels)
            return BuildHotels(hotels, sendMessage);
        return null;
    }

    private static UIElement BuildFlights(FlightList model, Action<string>? sendMessage)
    {
        var asked = new Dictionary<string, HashSet<TravelAsk>>(StringComparer.Ordinal);
        var expanded = false;

        var root = new StackPanel
        {
            Spacing = 8,
            MaxWidth = MaxCardWidth,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(16, 6, 16, 6),
        };
        AutomationProperties.SetAutomationId(root, "travel.flights");
        AutomationProperties.SetName(root, $"{model.Flights.Count} flights");

        void Render()
        {
            root.Children.Clear();

            if (model.Step.Length > 0)
            {
                var step = new TextBlock
                {
                    Text = model.Step,
                    FontSize = 12,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("HQTintTextBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 2,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                };
                AutomationProperties.SetAutomationId(step, "travel.flights.step");
                root.Children.Add(step);
            }

            if (model.Note.Length > 0)
            {
                root.Children.Add(new TextBlock
                {
                    Text = model.Note,
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 3,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
            }

            if (model.RelaxedFilters.Count > 0)
            {
                var relaxedText = new TextBlock
                {
                    Text = TravelCards.RelaxedFiltersText(model),
                    FontSize = 12,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 3,
                };
                AutomationProperties.SetAutomationId(relaxedText, "travel.flights.relaxed");
                root.Children.Add(new Border
                {
                    Child = relaxedText,
                    Padding = new Thickness(10, 6, 10, 6),
                    CornerRadius = new CornerRadius(10),
                    Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
                });
            }

            var bookingLocked = asked.Values.Any(s => s.Contains(TravelAsk.Book));
            var count = expanded ? model.Flights.Count : Math.Min(FlightsShownCollapsed, model.Flights.Count);
            for (var i = 0; i < count; i++)
            {
                var flight = model.Flights[i];
                IReadOnlySet<TravelAsk> flightAsks = asked.TryGetValue(flight.Id, out var set) ? set : new HashSet<TravelAsk>();
                root.Children.Add(BuildFlightRow(flight, i, flightAsks, bookingLocked, root, ask =>
                {
                    if (!asked.TryGetValue(flight.Id, out var bucket))
                    {
                        bucket = [];
                        asked[flight.Id] = bucket;
                    }
                    bucket.Add(ask);
                    sendMessage?.Invoke(TravelCards.FormatMessage(ask, flight));
                    Render();
                }));
            }

            if (model.Flights.Count > FlightsShownCollapsed)
            {
                var hidden = model.Flights.Count - FlightsShownCollapsed;
                var toggle = new Button
                {
                    Content = expanded ? "Show Less" : $"{hidden} more ›",
                    Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
                    Foreground = ThemeBrushes.Get("HQTintTextBrush"),
                    FontWeight = FontWeights.SemiBold,
                    FontSize = 13,
                    Padding = new Thickness(4, 4, 8, 4),
                    HorizontalAlignment = HorizontalAlignment.Left,
                };
                AutomationProperties.SetAutomationId(toggle, "travel.flights.toggle");
                toggle.Click += (_, _) => { expanded = !expanded; Render(); };
                root.Children.Add(toggle);
            }

            if (model.FollowUps.Count > 0)
                root.Children.Add(BuildFollowUpChips(model.FollowUps, sendMessage));
        }

        Render();
        return root;
    }

    private static UIElement BuildFlightRow(
        FlightOption flight,
        int index,
        IReadOnlySet<TravelAsk> asks,
        bool bookingLocked,
        FrameworkElement anchor,
        Action<TravelAsk> onAsk)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var times = $"{flight.DepartTime} – {flight.ArriveTime}";
        var details = string.Join(" · ", new[]
        {
            flight.Airline,
            flight.Duration,
            flight.StopsLabel,
            flight.FareTier.Length > 0 ? flight.FareTier : flight.Cabin,
        }.Where(s => s.Length > 0));
        var bagSummary = string.Join(" · ", new[] { flight.CarryOn, flight.RefundRule }.Where(s => s.Length > 0));

        var left = new StackPanel { Spacing = 2 };
        left.Children.Add(new TextBlock
        {
            Text = $"{times}  ·  {flight.RouteLabel}",
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        left.Children.Add(new TextBlock
        {
            Text = details,
            FontSize = 12.5,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        left.Children.Add(new TextBlock
        {
            Text = bagSummary.Length > 0 ? bagSummary : "Click for bags, changes & refund rules",
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        grid.Children.Add(left);

        var right = new StackPanel
        {
            Spacing = 2,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };
        right.Children.Add(new TextBlock
        {
            Text = ShoppingCards.FormatPrice(flight.Price, flight.Currency),
            FontSize = 14.5,
            FontWeight = FontWeights.Bold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Right,
        });
        if (flight.Was is { } was)
        {
            right.Children.Add(new TextBlock
            {
                Text = ShoppingCards.FormatPrice(was, flight.Currency),
                FontSize = 11.5,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough,
                HorizontalAlignment = HorizontalAlignment.Right,
            });
        }
        var statusText = asks.Contains(TravelAsk.Book)
            ? "Requested"
            : flight.Badge.Length > 0 ? flight.Badge : "Details ›";
        right.Children.Add(new TextBlock
        {
            Text = statusText,
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get(asks.Contains(TravelAsk.Book) ? "TextFillColorSecondaryBrush" : "HQTintTextBrush"),
            HorizontalAlignment = HorizontalAlignment.Right,
        });
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);

        var btn = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(12, 10, 12, 10),
            CornerRadius = new CornerRadius(14),
            Background = ThemeBrushes.Get("HQPromptCardBrush"),
            BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(btn, $"travel.flight.{index}");
        AutomationProperties.SetName(btn,
            $"{flight.Airline}, {flight.RouteLabel}, {flight.DepartTime} to {flight.ArriveTime}, {flight.StopsLabel}, {ShoppingCards.FormatPrice(flight.Price, flight.Currency)}");
        btn.Click += (_, _) =>
        {
            var xr = anchor.XamlRoot ?? App.Window?.Content?.XamlRoot;
            _ = FlightDetailDialog.ShowAsync(flight, xr, onAsk, asks, bookingLocked);
        };
        return btn;
    }

    private static UIElement BuildHotels(HotelList model, Action<string>? sendMessage)
    {
        var asked = new Dictionary<string, HashSet<TravelAsk>>(StringComparer.Ordinal);

        var root = new StackPanel
        {
            Spacing = 8,
            MaxWidth = MaxCardWidth,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(16, 6, 16, 6),
        };
        AutomationProperties.SetAutomationId(root, "travel.hotels");
        AutomationProperties.SetName(root, $"{model.Hotels.Count} hotels");

        void Render()
        {
            root.Children.Clear();

            if (model.Step.Length > 0)
            {
                root.Children.Add(new TextBlock
                {
                    Text = model.Step,
                    FontSize = 12,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("HQTintTextBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 2,
                });
            }

            var meta = TravelCards.HotelMetaWords(model);
            if (meta.Length > 0)
            {
                root.Children.Add(new TextBlock
                {
                    Text = meta,
                    FontSize = 12.5,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 3,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
            }

            if (model.Note.Length > 0)
            {
                root.Children.Add(new TextBlock
                {
                    Text = model.Note,
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 3,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                });
            }

            var bookingLocked = asked.Values.Any(s => s.Contains(TravelAsk.Book));
            var single = model.Hotels.Count == 1;
            var tileWidth = single ? 340.0 : 224.0;

            var strip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            for (var i = 0; i < model.Hotels.Count; i++)
            {
                var hotel = model.Hotels[i];
                IReadOnlySet<TravelAsk> hotelAsks = asked.TryGetValue(hotel.Id, out var set) ? set : new HashSet<TravelAsk>();
                strip.Children.Add(BuildHotelTile(hotel, i, tileWidth, hotelAsks, bookingLocked, root, ask =>
                {
                    if (!asked.TryGetValue(hotel.Id, out var bucket))
                    {
                        bucket = [];
                        asked[hotel.Id] = bucket;
                    }
                    bucket.Add(ask);
                    sendMessage?.Invoke(TravelCards.FormatMessage(ask, hotel));
                    Render();
                }));
            }

            if (single)
            {
                root.Children.Add(strip);
            }
            else
            {
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

            if (model.FollowUps.Count > 0)
                root.Children.Add(BuildFollowUpChips(model.FollowUps, sendMessage));
        }

        Render();
        return root;
    }

    private static UIElement BuildHotelTile(
        HotelOption hotel,
        int index,
        double width,
        IReadOnlySet<TravelAsk> asks,
        bool bookingLocked,
        FrameworkElement anchor,
        Action<TravelAsk> onAsk)
    {
        var body = new StackPanel { Width = width };

        var photo = TravelUi.PhotoBox(hotel.Image, width, 120, "\uE707");
        body.Children.Add(photo);

        var info = new StackPanel { Spacing = 3, Padding = new Thickness(10, 8, 10, 10) };
        // 2-line hotel title so chain + property name is not clipped after line 1 (`1f8bf0cae`).
        info.Children.Add(new TextBlock
        {
            Text = hotel.Name,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var subtitle = TravelCards.HotelSubtitle(hotel);
        if (subtitle.Length > 0)
        {
            info.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                MaxLines = 1,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }

        string priceText;
        if (hotel.PricePerNight is { } nightly)
        {
            var suffix = asks.Contains(TravelAsk.Book)
                ? " · Requested"
                : hotel.HasCoordinates ? " · Map" : "";
            priceText = $"{ShoppingCards.FormatPrice(nightly, hotel.Currency)}/nt{suffix}";
        }
        else
        {
            priceText = hotel.HasCoordinates ? "View map & details" : "View details";
        }
        info.Children.Add(new TextBlock
        {
            Text = priceText,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("HQTintTextBrush"),
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        body.Children.Add(info);

        var btn = new Button
        {
            Content = body,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(14),
            Background = ThemeBrushes.Get("HQPromptCardBrush"),
            BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top,
        };
        AutomationProperties.SetAutomationId(btn, $"travel.hotel.{index}");
        var spokenPrice = hotel.PricePerNight is { } p ? ShoppingCards.FormatPrice(p, hotel.Currency) + " per night" : "";
        AutomationProperties.SetName(btn,
            string.Join(", ", new[] { hotel.Name, hotel.Neighborhood, spokenPrice }.Where(s => s.Length > 0)));
        btn.Click += (_, _) =>
        {
            var xr = anchor.XamlRoot ?? App.Window?.Content?.XamlRoot;
            _ = HotelDetailDialog.ShowAsync(hotel, xr, onAsk, asks, bookingLocked);
        };
        return btn;
    }

    private static UIElement BuildFollowUpChips(IReadOnlyList<string> followUps, Action<string>? sendMessage)
    {
        var panel = new TravelFlowPanel { Spacing = 6, LineSpacing = 6 };
        foreach (var text in followUps)
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
            chip.Click += (_, _) => sendMessage?.Invoke(prompt);
            panel.Children.Add(chip);
        }
        return panel;
    }
}

/// Shared WinUI helpers for travel cards and dialogs.
internal static class TravelUi
{
    /// Opens an external URL only when its scheme is safe (`http` or `https`).
    public static void OpenSafeLink(Uri? uri)
    {
        if (!TravelCards.IsSafeWebUri(uri)) return;
        try { _ = Launcher.LaunchUriAsync(uri); }
        catch (Exception) { }
    }

    /// Rounded remote photo container with subtle placeholder glyph while loading or when absent.
    public static Border PhotoBox(Uri? uri, double? width, double height, string placeholderGlyph, double radius = 0)
    {
        var grid = new Grid
        {
            Height = height,
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
        };
        if (width.HasValue) grid.Width = width.Value;

        var placeholder = new FontIcon
        {
            Glyph = placeholderGlyph,
            FontSize = 24,
            Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        grid.Children.Add(placeholder);

        if (uri != null && TravelCards.IsSafeWebUri(uri))
        {
            var decodeW = width.HasValue ? (int)Math.Ceiling(width.Value * 2) : 900;
            var bmp = new BitmapImage(uri) { DecodePixelWidth = decodeW };
            var img = new Image
            {
                Source = bmp,
                Stretch = Stretch.UniformToFill,
                Opacity = 0,
            };
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

    public static Border SectionCard(UIElement child) => new()
    {
        Child = child,
        Padding = new Thickness(14, 12, 14, 12),
        CornerRadius = new CornerRadius(14),
        Background = ThemeBrushes.Get("HQPromptCardBrush"),
        BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
        BorderThickness = new Thickness(1),
    };

    public static TextBlock DialogTitle(string text) => new()
    {
        Text = text,
        FontSize = 18,
        FontWeight = FontWeights.SemiBold,
        TextWrapping = TextWrapping.Wrap,
        MaxLines = 2,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    public static TextBlock SectionHeading(string text, string brushKey = "TextFillColorSecondaryBrush") => new()
    {
        Text = text,
        FontSize = 11.5,
        FontWeight = FontWeights.SemiBold,
        Foreground = ThemeBrushes.Get(brushKey),
    };

    public static UIElement BulletRow(string text, string glyph, string tintBrush)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon
        {
            Glyph = glyph,
            FontSize = 13,
            Foreground = ThemeBrushes.Get(tintBrush),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 0, 0),
        });
        var label = new TextBlock
        {
            Text = text,
            FontSize = 13.5,
            TextWrapping = TextWrapping.Wrap,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
        };
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        return grid;
    }

    public static Border Pill(string text, bool accent) => new()
    {
        Padding = new Thickness(9, 4, 9, 4),
        CornerRadius = new CornerRadius(10),
        Background = ThemeBrushes.Get(accent ? "AccentFillColorDefaultBrush" : "SubtleFillColorSecondaryBrush"),
        Child = new TextBlock
        {
            Text = text,
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get(accent ? "TextOnAccentFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 3,
        },
    };
}

/// Lightweight wrapping flow panel for travel follow-up chips and pills.
internal sealed class TravelFlowPanel : Panel
{
    public double Spacing { get; set; } = 6;
    public double LineSpacing { get; set; } = 6;

    protected override Size MeasureOverride(Size availableSize)
    {
        var maxWidth = double.IsInfinity(availableSize.Width) || availableSize.Width <= 0 ? 560 : availableSize.Width;
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
        var maxWidth = finalSize.Width > 0 ? finalSize.Width : 560;
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
