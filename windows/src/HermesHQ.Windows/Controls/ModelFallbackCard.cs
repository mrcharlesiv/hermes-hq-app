using Hermes.Core.Chat;
using HermesHQ.Features.Workspace;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace HermesHQ.Controls;

/// Tiered inline UI for model and provider fallbacks in the chat timeline (port of App/Chat/ModelFallbackViews.swift):
/// - Actionable failures (auth, billing/quota, missing model, or CLI fix command) render as a compact amber card
///   (`chat.model-fallback.card`) opening `ModelFallbackDialog`.
/// - Transient blips (rate limit, busy, timeout) render as a compact 1-line pill (`chat.model-fallback.pill`).
/// - Primary recovery ("Primary model restored") renders as a quiet 1-line pill with a green dot (`chat.model-fallback.restored`).
public static class ModelFallbackCard
{
    private static readonly Color Amber = Color.FromArgb(255, 245, 158, 11);
    private static readonly Color Green = Color.FromArgb(255, 48, 185, 77);
    private static readonly Brush AmberBrush = new SolidColorBrush(Amber);
    private static readonly Brush AmberFill = new SolidColorBrush(Color.FromArgb(36, 245, 158, 11));
    private static readonly Brush AmberCardFill = new SolidColorBrush(Color.FromArgb(20, 245, 158, 11));
    private static readonly Brush AmberBorder = new SolidColorBrush(Color.FromArgb(115, 245, 158, 11));
    private static readonly Brush GreenBrush = new SolidColorBrush(Green);

    /// SHARED CONTRACT: renders a parsed `ModelFallback` as an actionable amber card or transient pill.
    public static UIElement Build(ModelFallback fallback, Action? openModels = null, Action? openProviders = null) =>
        BuildRow(ModelFallbackRow.FromFallback(fallback), openModels, openProviders, runInTerminal: null, setEnvVar: null);

    /// Renders any gateway fallback or primary-restored notice text; returns null for unrelated system text.
    public static UIElement? BuildFromNotice(
        string? text,
        Action? openModels = null,
        Action? openProviders = null,
        Action<string?>? runInTerminal = null,
        Action<string>? setEnvVar = null) =>
        ModelFallbackRow.Parse(text) is { } row
            ? BuildRow(row, openModels, openProviders, runInTerminal, setEnvVar)
            : null;

    public static UIElement BuildRow(
        ModelFallbackRow row,
        Action? openModels = null,
        Action? openProviders = null,
        Action<string?>? runInTerminal = null,
        Action<string>? setEnvVar = null) =>
        row.Presentation switch
        {
            ModelFallbackRow.PresentationKind.Card => BuildActionableCard(row, openModels, openProviders, runInTerminal, setEnvVar),
            ModelFallbackRow.PresentationKind.Pill => BuildTransientPill(row, openModels, openProviders, runInTerminal, setEnvVar),
            _ => BuildRestoredPill(row),
        };

    private static UIElement BuildActionableCard(
        ModelFallbackRow row,
        Action? openModels,
        Action? openProviders,
        Action<string?>? runInTerminal,
        Action<string>? setEnvVar)
    {
        var labelBrush = ThemeBrushes.Get("TextFillColorPrimaryBrush");
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");

        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var badge = new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(17),
            Background = AmberFill,
            BorderBrush = AmberBorder,
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new FontIcon
            {
                Glyph = "\uE7BA",
                FontSize = 15,
                Foreground = AmberBrush,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };

        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock
        {
            Text = row.Title,
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = labelBrush,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrEmpty(row.Subtitle))
        {
            words.Children.Add(new TextBlock
            {
                Text = row.Subtitle,
                FontSize = 12,
                Foreground = secondaryBrush,
                TextWrapping = TextWrapping.Wrap,
            });
        }

        var chevron = new FontIcon
        {
            Glyph = "\uE76C",
            FontSize = 11,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };

        Grid.SetColumn(words, 1);
        Grid.SetColumn(chevron, 2);
        grid.Children.Add(badge);
        grid.Children.Add(words);
        grid.Children.Add(chevron);

        var button = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Left,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            MaxWidth = 460,
            Padding = new Thickness(12, 10, 12, 10),
            CornerRadius = new CornerRadius(12),
            Background = AmberCardFill,
            BorderBrush = AmberBorder,
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 4, 0, 4),
        };
        AutomationProperties.SetAutomationId(button, "chat.model-fallback.card");
        AutomationProperties.SetName(button, row.Spoken);

        if (row.Detail is { } detail)
        {
            button.Click += (_, _) => _ = ModelFallbackDialog.ShowAsync(
                button.XamlRoot, detail, openModels, openProviders, runInTerminal, setEnvVar);
            button.ContextFlyout = BuildContextMenu(detail, openModels, openProviders, runInTerminal);
        }
        return button;
    }

    private static UIElement BuildTransientPill(
        ModelFallbackRow row,
        Action? openModels,
        Action? openProviders,
        Action<string?>? runInTerminal,
        Action<string>? setEnvVar)
    {
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var surface = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
        var stroke = ThemeBrushes.Get("CardStrokeColorDefaultBrush");

        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        content.Children.Add(new Ellipse
        {
            Width = 7,
            Height = 7,
            Fill = AmberBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        content.Children.Add(new TextBlock
        {
            Text = row.Title,
            FontSize = 12,
            Foreground = secondaryBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        });
        content.Children.Add(new FontIcon
        {
            Glyph = "\uE76C",
            FontSize = 9,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var button = new Button
        {
            Content = content,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(11, 5, 11, 5),
            CornerRadius = new CornerRadius(14),
            Background = surface,
            BorderBrush = stroke,
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 4, 0, 4),
        };
        AutomationProperties.SetAutomationId(button, "chat.model-fallback.pill");
        AutomationProperties.SetName(button, row.Spoken);

        if (row.Detail is { } detail)
        {
            button.Click += (_, _) => _ = ModelFallbackDialog.ShowAsync(
                button.XamlRoot, detail, openModels, openProviders, runInTerminal, setEnvVar);
            button.ContextFlyout = BuildContextMenu(detail, openModels, openProviders, runInTerminal);
        }
        return button;
    }

    private static UIElement BuildRestoredPill(ModelFallbackRow row)
    {
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var surface = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
        var stroke = ThemeBrushes.Get("CardStrokeColorDefaultBrush");

        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        content.Children.Add(new Ellipse
        {
            Width = 7,
            Height = 7,
            Fill = GreenBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        content.Children.Add(new TextBlock
        {
            Text = row.Title,
            FontSize = 12,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var pill = new Border
        {
            Child = content,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(11, 5, 11, 5),
            CornerRadius = new CornerRadius(14),
            Background = surface,
            BorderBrush = stroke,
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 4, 0, 4),
        };
        AutomationProperties.SetAutomationId(pill, "chat.model-fallback.restored");
        AutomationProperties.SetName(pill, row.Spoken);
        return pill;
    }

    private static MenuFlyout BuildContextMenu(
        ModelFallbackRow.DetailModel detail,
        Action? openModels,
        Action? openProviders,
        Action<string?>? runInTerminal)
    {
        var menu = new MenuFlyout();
        if (detail.PrimaryCommand is { } command)
        {
            var runItem = new MenuFlyoutItem
            {
                Text = detail.RunnableCommand != null ? "Run in Terminal" : "Copy & Open Terminal",
                Icon = new FontIcon { Glyph = "\uE756" },
            };
            runItem.Click += (_, _) =>
            {
                if (detail.RunnableCommand is { } runnable)
                {
                    if (runInTerminal != null) runInTerminal(runnable);
                    else TerminalPage.OpenWithCommand(runnable);
                }
                else
                {
                    SafeClipboard.TrySetText(command);
                    if (runInTerminal != null) runInTerminal(null);
                    else Navigator.Open("terminal");
                }
            };
            menu.Items.Add(runItem);

            var copyCmd = new MenuFlyoutItem { Text = "Copy Fix Command", Icon = new FontIcon { Glyph = "\uE8C8" } };
            copyCmd.Click += (_, _) => SafeClipboard.TrySetText(command);
            menu.Items.Add(copyCmd);
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        var choose = new MenuFlyoutItem { Text = "Choose a Model", Icon = new FontIcon { Glyph = "\uE945" } };
        choose.Click += (_, _) =>
        {
            if (openModels != null) openModels();
            else SettingsWindows.Show("models");
        };
        menu.Items.Add(choose);

        var providers = new MenuFlyoutItem { Text = "Provider Settings", Icon = new FontIcon { Glyph = "\uE713" } };
        providers.Click += (_, _) =>
        {
            if (openProviders != null) openProviders();
            else SettingsWindows.Show("providers");
        };
        menu.Items.Add(providers);

        var copyDetails = new MenuFlyoutItem { Text = "Copy Details", Icon = new FontIcon { Glyph = "\uE8C8" } };
        copyDetails.Click += (_, _) => SafeClipboard.TrySetText(ModelFallbackDialog.BuildTechnicalDump(detail));
        menu.Items.Add(copyDetails);
        return menu;
    }
}
