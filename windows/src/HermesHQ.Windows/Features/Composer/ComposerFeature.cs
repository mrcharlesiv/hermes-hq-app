using Hermes.Core.Composer;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Composer;

/// The composer and its menus (PARITY.md Chat: the queue card, the model chip and Models list, ☰ Commands, the slash
/// and @ drawers, typed slash commands, Prompts, Usage & Limits, Model Prices). One controller per open chat.
public static class ComposerFeature
{
    public static void Register()
    {
        ChatExtensions.OnOpen.Add(ctx => _ = new ComposerController(ctx));
        ChatExtensions.PartRenderers[typeof(SlashOutputPart)] = (part, _) => ComposerRows.Slash((SlashOutputPart)part);
        ChatExtensions.PartRenderers[typeof(SideResultPart)] = (part, _) => ComposerRows.Side((SideResultPart)part);
    }
}

/// What every chat's composer shares on this PC: the settings file (favourites, recents, presets, starred commands),
/// the Prompts library, and the models.dev price list.
public static class ComposerServices
{
    public static IKeyValueStore Store { get; } = new JsonFileStore(Path.Combine(AppPaths.Root, "composer.json"));
    public static PromptLibrary Prompts { get; } = new(Store);
    public static ModelsDevCache ModelsDev { get; } = new(Path.Combine(AppPaths.Root, "models-dev-prices.json"));
    public static ModelPrefs Prefs(string account) => new(account, Store);
}

/// The transcript rows the composer adds: a slash command's output (spec 1x §8.4) and a /btw or /bg result.
public static class ComposerRows
{
    /// Centred, at most 85 % wide, small and secondary. One line: "<command> · <output>" with the command monospaced;
    /// several lines: the command on its own line, the output under it left-aligned and monospaced.
    public static FrameworkElement Slash(SlashOutputPart part)
    {
        var mono = Ui.Res<FontFamily>("CodeFont");
        var body = part.Output.Trim('\n', '\r');
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(40, 6, 40, 6), MaxWidth = 680 };
        var error = body.StartsWith("error:", StringComparison.Ordinal);
        var color = Ui.Res<Brush>(error ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush");
        if (body.Contains('\n'))
        {
            if (part.Command != null)
                panel.Children.Add(new TextBlock { Text = part.Command, FontFamily = mono, FontSize = 12, Foreground = color, HorizontalAlignment = HorizontalAlignment.Center });
            panel.Children.Add(new TextBlock
            {
                Text = body, FontFamily = mono, FontSize = 12, Foreground = color, TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true, Margin = new Thickness(0, 2, 0, 0),
            });
        }
        else
        {
            var line = new TextBlock { FontSize = 12, Foreground = color, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, IsTextSelectionEnabled = true };
            if (part.Command != null) line.Inlines.Add(new Run { Text = part.Command, FontFamily = mono });
            if (body.Length > 0) line.Inlines.Add(new Run { Text = (part.Command != null ? " · " : "") + body });
            panel.Children.Add(line);
        }
        return panel;
    }

    /// A side task's result: its title, the answer under it (a /btw answer opens as it lands).
    public static FrameworkElement Side(SideResultPart part)
    {
        var content = new StackPanel();
        Controls.MarkdownRenderer.Render(part.Result, content);
        return new Expander
        {
            Header = part.Title,
            Content = content,
            IsExpanded = part.Kind == "btw",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(16, 4, 16, 4),
        };
    }
}

/// Small helpers for building the composer's panels in code (no XAML: nothing here needs the XAML compiler).
internal static class Ui
{
    public static T Res<T>(string key) => ThemeBrushes.Res<T>(key);

    /// Primary text inherits the theme's brush: a local null Foreground would leave the words undrawn (WIN-45, the
    /// Models sheet's blank rows), so only secondary text sets one.
    public static TextBlock Text(string text, double size = 14, bool secondary = false, bool bold = false, bool wrap = true)
    {
        var t = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        };
        if (secondary) t.Foreground = Res<Brush>("TextFillColorSecondaryBrush");
        return t;
    }

    public static TextBlock Header(string text) => new()
    {
        Text = text, FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(4, 12, 0, 4),
        Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
    };

    public static Button Quiet(UIElement content, string tip, RoutedEventHandler click)
    {
        var b = new Button { Content = content, Style = Res<Style>("QuietButtonStyle") };
        ToolTipService.SetToolTip(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
        b.Click += click;
        return b;
    }

    public static FontIcon Glyph(string glyph, double size = 14) => new() { Glyph = glyph, FontSize = size };

    /// A row that reads as a list row and clicks as a button.
    public static Button Row(UIElement content, RoutedEventHandler click)
    {
        var b = new Button
        {
            Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(8, 6, 8, 6),
        };
        b.Click += click;
        return b;
    }

    public static Task<ContentDialogResult> Show(XamlRoot? root, ContentDialog dialog) =>
        SafeDialog.ShowAsync(root, dialog);

    public static Task Alert(XamlRoot? root, string title, string message) =>
        Show(root, new ContentDialog { Title = title, Content = Text(message), CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close });
}
