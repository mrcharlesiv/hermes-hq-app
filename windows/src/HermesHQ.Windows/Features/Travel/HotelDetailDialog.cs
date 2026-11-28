using System.Globalization;
using Hermes.Core.Shopping;
using Hermes.Core.Travel;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Travel;

/// Hotel detail dialog (App/Travel/HotelDetailSheet.swift + `ffcc94357` 2-line title & full-width single hotel photo):
/// photo gallery, summary & price, coordinates / Open in Maps, copyable address, amenities, notes, Book Hotel,
/// Watch Rate, and safe external Open Site link.
public static class HotelDetailDialog
{
    public static async Task ShowAsync(
        HotelOption hotel,
        XamlRoot? xamlRoot,
        Action<TravelAsk>? onAsk,
        IReadOnlySet<TravelAsk>? asks = null,
        bool bookingLocked = false)
    {
        if (xamlRoot == null) return;
        var currentAsks = asks ?? new HashSet<TravelAsk>();
        var submitted = false;
        ContentDialog? dialog = null;

        void Submit(TravelAsk ask)
        {
            if (submitted) return;
            submitted = true;
            dialog?.Hide();
            onAsk?.Invoke(ask);
        }

        var body = new StackPanel { Spacing = 12, MinWidth = 460, MaxWidth = 580 };

        // Photos: full-width single photo (`ffcc94357`) or interactive multi-photo gallery with counter & thumbnails.
        if (hotel.Images.Count == 1)
        {
            var singlePhoto = TravelUi.PhotoBox(hotel.Images[0], width: null, height: 210, placeholderGlyph: "\uE707", radius: 14);
            singlePhoto.HorizontalAlignment = HorizontalAlignment.Stretch;
            AutomationProperties.SetAutomationId(singlePhoto, "travel.hotel.photo.0");
            body.Children.Add(singlePhoto);
        }
        else if (hotel.Images.Count > 1)
        {
            body.Children.Add(BuildGallery(hotel));
        }

        // Summary card
        var summaryStack = new StackPanel { Spacing = 8 };
        var summaryGrid = new Grid { ColumnSpacing = 12 };
        summaryGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        summaryGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Spacing = 4 };
        left.Children.Add(new TextBlock
        {
            Text = hotel.Name,
            FontSize = 17,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        var subParts = new List<string>();
        if (hotel.Stars is { } s) subParts.Add(new string('★', s));
        if (hotel.Rating is { } r)
            subParts.Add(string.Create(CultureInfo.InvariantCulture, $"{r:F1}") + (hotel.Reviews is { } rev ? $" ({rev})" : ""));
        if (hotel.Neighborhood.Length > 0) subParts.Add(hotel.Neighborhood);
        if (hotel.Distance.Length > 0) subParts.Add(hotel.Distance);
        if (subParts.Count > 0)
        {
            left.Children.Add(new TextBlock
            {
                Text = string.Join(" · ", subParts),
                FontSize = 12.5,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }
        summaryGrid.Children.Add(left);

        var right = new StackPanel { Spacing = 2, HorizontalAlignment = HorizontalAlignment.Right };
        if (hotel.PricePerNight is { } nightly)
        {
            right.Children.Add(new TextBlock
            {
                Text = $"{ShoppingCards.FormatPrice(nightly, hotel.Currency)}/nt",
                FontSize = 16,
                FontWeight = FontWeights.Bold,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                HorizontalAlignment = HorizontalAlignment.Right,
            });
        }
        if (hotel.TotalPrice is { } total)
        {
            right.Children.Add(new TextBlock
            {
                Text = $"{ShoppingCards.FormatPrice(total, hotel.Currency)} total",
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                HorizontalAlignment = HorizontalAlignment.Right,
            });
        }
        if (hotel.Was is { } was)
        {
            right.Children.Add(new TextBlock
            {
                Text = ShoppingCards.FormatPrice(was, hotel.Currency),
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough,
                HorizontalAlignment = HorizontalAlignment.Right,
            });
        }
        Grid.SetColumn(right, 1);
        summaryGrid.Children.Add(right);
        summaryStack.Children.Add(summaryGrid);

        if (hotel.Badge.Length > 0 || hotel.Cancellation.Length > 0 || hotel.Breakfast.Length > 0)
        {
            var pills = new TravelFlowPanel { Spacing = 8, LineSpacing = 8 };
            if (hotel.Badge.Length > 0) pills.Children.Add(TravelUi.Pill(hotel.Badge, accent: true));
            if (hotel.Cancellation.Length > 0) pills.Children.Add(TravelUi.Pill(hotel.Cancellation, accent: false));
            if (hotel.Breakfast.Length > 0) pills.Children.Add(TravelUi.Pill(hotel.Breakfast, accent: false));
            summaryStack.Children.Add(pills);
        }
        body.Children.Add(TravelUi.SectionCard(summaryStack));

        // Coordinates / Map card
        if (hotel.Latitude is { } lat && hotel.Longitude is { } lng)
        {
            var mapRow = new Grid { ColumnSpacing = 12 };
            mapRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            mapRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var locText = new StackPanel { Spacing = 3 };
            locText.Children.Add(TravelUi.SectionHeading("LOCATION"));
            locText.Children.Add(new TextBlock
            {
                Text = string.Create(CultureInfo.InvariantCulture, $"{lat:F4}, {lng:F4}"),
                FontSize = 13,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                IsTextSelectionEnabled = true,
            });
            mapRow.Children.Add(locText);

            var openMapBtn = new Button
            {
                Content = "Open in Maps",
                CornerRadius = new CornerRadius(16),
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetAutomationId(openMapBtn, "travel.hotel.map");
            openMapBtn.Click += (_, _) =>
            {
                var query = Uri.EscapeDataString($"{hotel.Name} {hotel.Address}".Trim());
                var mapUrl = string.Create(CultureInfo.InvariantCulture,
                    $"https://www.bing.com/maps?cp={lat:F6}~{lng:F6}&lvl=15&q={query}");
                if (Uri.TryCreate(mapUrl, UriKind.Absolute, out var uri))
                    TravelUi.OpenSafeLink(uri);
            };
            Grid.SetColumn(openMapBtn, 1);
            mapRow.Children.Add(openMapBtn);
            body.Children.Add(TravelUi.SectionCard(mapRow));
        }

        // Address card with copy button
        if (hotel.Address.Length > 0)
        {
            var addrGrid = new Grid { ColumnSpacing = 10 };
            addrGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            addrGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            addrGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            addrGrid.Children.Add(new FontIcon
            {
                Glyph = "\uE707",
                FontSize = 15,
                Foreground = ThemeBrushes.Get("HQTintTextBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
            var addrText = new TextBlock
            {
                Text = hotel.Address,
                FontSize = 13.5,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            };
            Grid.SetColumn(addrText, 1);
            addrGrid.Children.Add(addrText);

            var copyBtn = new Button
            {
                Content = "Copy address",
                CornerRadius = new CornerRadius(16),
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetAutomationId(copyBtn, "travel.hotel.copyAddress");
            copyBtn.Click += async (_, _) =>
            {
                SafeClipboard.TrySetText(hotel.Address);
                copyBtn.Content = "Copied";
                await Task.Delay(1800);
                copyBtn.Content = "Copy address";
            };
            Grid.SetColumn(copyBtn, 2);
            addrGrid.Children.Add(copyBtn);
            body.Children.Add(TravelUi.SectionCard(addrGrid));
        }

        // Amenities card
        if (hotel.Amenities.Count > 0)
        {
            var amenStack = new StackPanel { Spacing = 6 };
            amenStack.Children.Add(TravelUi.SectionHeading("AMENITIES"));
            amenStack.Children.Add(new TextBlock
            {
                Text = string.Join(" · ", hotel.Amenities),
                FontSize = 13.5,
                TextWrapping = TextWrapping.Wrap,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            });
            body.Children.Add(TravelUi.SectionCard(amenStack));
        }

        // Why It Fits & Things to Note
        if (hotel.Why.Count > 0 || hotel.Caution.Count > 0)
        {
            var notes = new StackPanel { Spacing = 6 };
            if (hotel.Why.Count > 0)
            {
                notes.Children.Add(TravelUi.SectionHeading("WHY IT FITS"));
                foreach (var line in hotel.Why)
                    notes.Children.Add(TravelUi.BulletRow(line, "\uE73E", "HQGreenBrush"));
            }
            if (hotel.Caution.Count > 0)
            {
                var heading = TravelUi.SectionHeading("THINGS TO NOTE", "HQOrangeBrush");
                if (hotel.Why.Count > 0) heading.Margin = new Thickness(0, 6, 0, 0);
                notes.Children.Add(heading);
                foreach (var line in hotel.Caution)
                    notes.Children.Add(TravelUi.BulletRow(line, "\uE7BA", "HQOrangeBrush"));
            }
            body.Children.Add(TravelUi.SectionCard(notes));
        }

        // Actions
        var actions = new StackPanel { Spacing = 8 };
        if (currentAsks.Contains(TravelAsk.Book))
        {
            var booked = TravelUi.SectionCard(TravelUi.BulletRow("Booking requested", "\uE73E", "TextFillColorSecondaryBrush"));
            AutomationProperties.SetAutomationId(booked, "travel.hotel.booked");
            actions.Children.Add(booked);
        }
        else if (!bookingLocked && onAsk != null)
        {
            var rate = hotel.PricePerNight is { } n ? $" · {ShoppingCards.FormatPrice(n, hotel.Currency)}/nt" : "";
            var bookBtn = new Button
            {
                Content = $"Book Hotel{rate}",
                Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                CornerRadius = new CornerRadius(18),
                MinHeight = 38,
                FontWeight = FontWeights.SemiBold,
            };
            AutomationProperties.SetAutomationId(bookBtn, "travel.hotel.book");
            bookBtn.Click += (_, _) => Submit(TravelAsk.Book);
            actions.Children.Add(bookBtn);
        }

        var secondaryRow = new Grid { ColumnSpacing = 8 };
        secondaryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        secondaryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        if (currentAsks.Contains(TravelAsk.WatchPrice))
        {
            secondaryRow.Children.Add(TravelUi.SectionCard(
                TravelUi.BulletRow("Watching rate", "\uEA8F", "TextFillColorSecondaryBrush")));
        }
        else if (onAsk != null)
        {
            var watchBtn = new Button
            {
                Content = "Watch Rate",
                HorizontalAlignment = HorizontalAlignment.Stretch,
                CornerRadius = new CornerRadius(18),
                MinHeight = 36,
            };
            AutomationProperties.SetAutomationId(watchBtn, "travel.hotel.watch");
            watchBtn.Click += (_, _) => Submit(TravelAsk.WatchPrice);
            secondaryRow.Children.Add(watchBtn);
        }

        var openSiteBtn = new Button
        {
            Content = "Open Site",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            CornerRadius = new CornerRadius(18),
            MinHeight = 36,
        };
        AutomationProperties.SetAutomationId(openSiteBtn, "travel.hotel.site");
        openSiteBtn.Click += (_, _) => TravelUi.OpenSafeLink(hotel.Url);
        Grid.SetColumn(openSiteBtn, 1);
        secondaryRow.Children.Add(openSiteBtn);
        actions.Children.Add(secondaryRow);
        body.Children.Add(actions);

        var scroll = new ScrollViewer
        {
            Content = body,
            MaxHeight = 580,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
        };

        dialog = new ContentDialog
        {
            Title = TravelUi.DialogTitle(hotel.Name),
            Content = scroll,
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "travel.hotel.sheet");
        await SafeDialog.ShowAsync(xamlRoot, dialog);
    }

    private static UIElement BuildGallery(HotelOption hotel)
    {
        var index = 0;
        var count = hotel.Images.Count;
        var container = new StackPanel { Spacing = 8 };
        var heroHost = new Grid();
        var counterLabel = new TextBlock
        {
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var prevBtn = new Button { Content = "‹ Prev", CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 4, 10, 4) };
        var nextBtn = new Button { Content = "Next ›", CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 4, 10, 4) };

        void ShowPhoto(int nextIndex)
        {
            if (nextIndex < 0 || nextIndex >= count) return;
            index = nextIndex;
            heroHost.Children.Clear();
            var photo = TravelUi.PhotoBox(hotel.Images[index], width: null, height: 200, placeholderGlyph: "\uE707", radius: 14);
            photo.HorizontalAlignment = HorizontalAlignment.Stretch;
            heroHost.Children.Add(photo);
            counterLabel.Text = $"{index + 1} / {count}";
            prevBtn.IsEnabled = index > 0;
            nextBtn.IsEnabled = index < count - 1;
        }

        prevBtn.Click += (_, _) => ShowPhoto(index - 1);
        nextBtn.Click += (_, _) => ShowPhoto(index + 1);

        var controls = new Grid { ColumnSpacing = 8 };
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        controls.Children.Add(prevBtn);
        counterLabel.HorizontalAlignment = HorizontalAlignment.Center;
        Grid.SetColumn(counterLabel, 1);
        controls.Children.Add(counterLabel);
        Grid.SetColumn(nextBtn, 2);
        controls.Children.Add(nextBtn);

        var thumbs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        for (var i = 0; i < count; i++)
        {
            var target = i;
            var thumbBtn = new Button
            {
                Content = TravelUi.PhotoBox(hotel.Images[i], width: 56, height: 42, placeholderGlyph: "\uE707", radius: 8),
                Padding = new Thickness(0),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
            };
            AutomationProperties.SetAutomationId(thumbBtn, $"travel.hotel.photo.{i}");
            thumbBtn.Click += (_, _) => ShowPhoto(target);
            thumbs.Children.Add(thumbBtn);
        }

        container.Children.Add(heroHost);
        container.Children.Add(controls);
        container.Children.Add(new ScrollViewer
        {
            Content = thumbs,
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });
        ShowPhoto(0);
        return container;
    }
}
