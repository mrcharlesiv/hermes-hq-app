using Hermes.Core.Shopping;
using Hermes.Core.Travel;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Travel;

/// Flight detail dialog (App/Travel/FlightDetailSheet.swift + `ffcc94357` 2-line sheet title):
/// route & schedule, multi-leg itinerary, collapsible fare/bag/change/refund rules, notes, Book Flight,
/// Watch Fare, and safe external Open Site link.
public static class FlightDetailDialog
{
    public static async Task ShowAsync(
        FlightOption flight,
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

        var body = new StackPanel { Spacing = 12, MinWidth = 440, MaxWidth = 560 };

        // Header card
        var headerGrid = new Grid { ColumnSpacing = 12 };
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var headerLeft = new StackPanel { Spacing = 3 };
        headerLeft.Children.Add(new TextBlock
        {
            Text = flight.Airline + (flight.FlightNumber.Length > 0 ? $" · {flight.FlightNumber}" : ""),
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        headerLeft.Children.Add(new TextBlock
        {
            Text = $"{flight.DepartTime} – {flight.ArriveTime}",
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        var summaryLine = string.Join(" · ", new[]
        {
            flight.Duration,
            flight.StopsLabel,
            flight.Cabin,
            flight.FareTier,
        }.Where(s => s.Length > 0));
        if (summaryLine.Length > 0)
        {
            headerLeft.Children.Add(new TextBlock
            {
                Text = summaryLine,
                FontSize = 12.5,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }
        headerGrid.Children.Add(headerLeft);

        var headerRight = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
        headerRight.Children.Add(new TextBlock
        {
            Text = ShoppingCards.FormatPrice(flight.Price, flight.Currency),
            FontSize = 18,
            FontWeight = FontWeights.Bold,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Right,
        });
        if (flight.Was is { } was)
        {
            headerRight.Children.Add(new TextBlock
            {
                Text = ShoppingCards.FormatPrice(was, flight.Currency),
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough,
                HorizontalAlignment = HorizontalAlignment.Right,
            });
        }
        if (flight.Badge.Length > 0)
        {
            var badge = TravelUi.Pill(flight.Badge, accent: true);
            badge.HorizontalAlignment = HorizontalAlignment.Right;
            headerRight.Children.Add(badge);
        }
        Grid.SetColumn(headerRight, 1);
        headerGrid.Children.Add(headerRight);
        body.Children.Add(TravelUi.SectionCard(headerGrid));

        // Multi-leg itinerary card
        if (flight.Segments.Count > 0)
        {
            var segStack = new StackPanel { Spacing = 8 };
            segStack.Children.Add(TravelUi.SectionHeading("ITINERARY"));
            for (var i = 0; i < flight.Segments.Count; i++)
            {
                var seg = flight.Segments[i];
                if (i > 0)
                {
                    segStack.Children.Add(new Border
                    {
                        Height = 1,
                        Background = ThemeBrushes.Get("DividerStrokeColorDefaultBrush"),
                    });
                }
                var top = new Grid { ColumnSpacing = 8 };
                top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                top.Children.Add(new TextBlock
                {
                    Text = $"{seg.Origin} → {seg.Destination}",
                    FontSize = 14,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                });
                if (seg.Duration.Length > 0)
                {
                    var dur = new TextBlock
                    {
                        Text = seg.Duration,
                        FontSize = 12.5,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    };
                    Grid.SetColumn(dur, 1);
                    top.Children.Add(dur);
                }
                segStack.Children.Add(top);

                var carrier = seg.FlightNumber.Length > 0 ? $" · {seg.Airline} {seg.FlightNumber}" : "";
                segStack.Children.Add(new TextBlock
                {
                    Text = $"{seg.DepartTime} – {seg.ArriveTime}{carrier}",
                    FontSize = 12.5,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                });
                if (seg.Layover.Length > 0)
                {
                    segStack.Children.Add(new TextBlock
                    {
                        Text = seg.Layover,
                        FontSize = 12,
                        FontWeight = FontWeights.SemiBold,
                        Foreground = ThemeBrushes.Get("HQOrangeBrush"),
                        TextWrapping = TextWrapping.Wrap,
                    });
                }
            }
            body.Children.Add(TravelUi.SectionCard(segStack));
        }

        // Collapsible rules card
        var hasRules = flight.CarryOn.Length > 0 || flight.CheckedBag.Length > 0
            || flight.ChangeRule.Length > 0 || flight.RefundRule.Length > 0;
        if (hasRules)
        {
            var rulesExpanded = true;
            var rulesContent = new StackPanel { Spacing = 8 };
            void AddRule(string glyph, string title, string value)
            {
                if (value.Length == 0) return;
                var row = new Grid { ColumnSpacing = 10 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.Children.Add(new FontIcon
                {
                    Glyph = glyph,
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get("HQTintTextBrush"),
                    VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(0, 2, 0, 0),
                });
                var textStack = new StackPanel { Spacing = 1 };
                textStack.Children.Add(new TextBlock
                {
                    Text = title,
                    FontSize = 11.5,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                });
                textStack.Children.Add(new TextBlock
                {
                    Text = value,
                    FontSize = 13.5,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                });
                Grid.SetColumn(textStack, 1);
                row.Children.Add(textStack);
                rulesContent.Children.Add(row);
            }
            AddRule("\uE7B8", "Carry-on", flight.CarryOn);
            AddRule("\uE821", "Checked bag", flight.CheckedBag);
            AddRule("\uE8AB", "Changes", flight.ChangeRule);
            AddRule("\uE7A7", "Refunds", flight.RefundRule);

            var chevron = new FontIcon
            {
                Glyph = "\uE70E",
                FontSize = 11,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            };
            var toggleGrid = new Grid();
            toggleGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            toggleGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            toggleGrid.Children.Add(TravelUi.SectionHeading("BAGS, CHANGES & REFUNDS"));
            Grid.SetColumn(chevron, 1);
            toggleGrid.Children.Add(chevron);

            var toggleBtn = new Button
            {
                Content = toggleGrid,
                Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(0, 2, 0, 2),
            };
            AutomationProperties.SetAutomationId(toggleBtn, "travel.flight.rulesToggle");
            toggleBtn.Click += (_, _) =>
            {
                rulesExpanded = !rulesExpanded;
                rulesContent.Visibility = rulesExpanded ? Visibility.Visible : Visibility.Collapsed;
                chevron.Glyph = rulesExpanded ? "\uE70E" : "\uE70D";
            };

            var rulesStack = new StackPanel { Spacing = 8 };
            rulesStack.Children.Add(toggleBtn);
            rulesStack.Children.Add(rulesContent);
            body.Children.Add(TravelUi.SectionCard(rulesStack));
        }

        // Why It Fits & Things to Note
        if (flight.Why.Count > 0 || flight.Caution.Count > 0)
        {
            var notes = new StackPanel { Spacing = 6 };
            if (flight.Why.Count > 0)
            {
                notes.Children.Add(TravelUi.SectionHeading("WHY IT FITS"));
                foreach (var line in flight.Why)
                    notes.Children.Add(TravelUi.BulletRow(line, "\uE73E", "HQGreenBrush"));
            }
            if (flight.Caution.Count > 0)
            {
                var heading = TravelUi.SectionHeading("THINGS TO NOTE", "HQOrangeBrush");
                if (flight.Why.Count > 0) heading.Margin = new Thickness(0, 6, 0, 0);
                notes.Children.Add(heading);
                foreach (var line in flight.Caution)
                    notes.Children.Add(TravelUi.BulletRow(line, "\uE7BA", "HQOrangeBrush"));
            }
            body.Children.Add(TravelUi.SectionCard(notes));
        }

        // Actions
        var actions = new StackPanel { Spacing = 8 };
        if (currentAsks.Contains(TravelAsk.Book))
        {
            var booked = TravelUi.SectionCard(TravelUi.BulletRow("Booking requested", "\uE73E", "TextFillColorSecondaryBrush"));
            AutomationProperties.SetAutomationId(booked, "travel.flight.booked");
            actions.Children.Add(booked);
        }
        else if (!bookingLocked && onAsk != null)
        {
            var bookBtn = new Button
            {
                Content = $"Book Flight · {ShoppingCards.FormatPrice(flight.Price, flight.Currency)}",
                Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                CornerRadius = new CornerRadius(18),
                MinHeight = 38,
                FontWeight = FontWeights.SemiBold,
            };
            AutomationProperties.SetAutomationId(bookBtn, "travel.flight.book");
            bookBtn.Click += (_, _) => Submit(TravelAsk.Book);
            actions.Children.Add(bookBtn);
        }

        var secondaryRow = new Grid { ColumnSpacing = 8 };
        secondaryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        secondaryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        if (currentAsks.Contains(TravelAsk.WatchPrice))
        {
            secondaryRow.Children.Add(TravelUi.SectionCard(
                TravelUi.BulletRow("Watching fare", "\uEA8F", "TextFillColorSecondaryBrush")));
        }
        else if (onAsk != null)
        {
            var watchBtn = new Button
            {
                Content = "Watch Fare",
                HorizontalAlignment = HorizontalAlignment.Stretch,
                CornerRadius = new CornerRadius(18),
                MinHeight = 36,
            };
            AutomationProperties.SetAutomationId(watchBtn, "travel.flight.watch");
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
        AutomationProperties.SetAutomationId(openSiteBtn, "travel.flight.site");
        openSiteBtn.Click += (_, _) => TravelUi.OpenSafeLink(flight.Url);
        Grid.SetColumn(openSiteBtn, 1);
        secondaryRow.Children.Add(openSiteBtn);
        actions.Children.Add(secondaryRow);
        body.Children.Add(actions);

        var scroll = new ScrollViewer
        {
            Content = body,
            MaxHeight = 560,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
        };

        dialog = new ContentDialog
        {
            Title = TravelUi.DialogTitle(flight.RouteLabel),
            Content = scroll,
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "travel.flight.sheet");
        await SafeDialog.ShowAsync(xamlRoot, dialog);
    }
}
