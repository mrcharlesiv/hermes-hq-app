using Hermes.Core.Onboarding;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Onboarding;

/// What the guide's Copy and link buttons do (App/Onboarding/GuideActions.swift), behind one value: the app only hands
/// text to the clipboard or a link to the browser. It never runs a command and never fetches the setup script.
public sealed class GuideActions
{
    public Func<string, bool> Copy { get; init; } = text =>
    {
        try
        {
            var package = new DataPackage();
            package.SetText(text);
            Clipboard.SetContent(package);
            Clipboard.Flush();
            return true;
        }
        catch (Exception e) { AppLog.Error("guide", e); return false; }
    };

    public Func<Uri, Task<bool>> Open { get; init; } = async url =>
    {
        if (!Opens(url)) return false;
        try { return await Windows.System.Launcher.LaunchUriAsync(url); }
        catch (Exception e) { AppLog.Error("guide", e); return false; }
    };

    /// Only plain https links with no sign-in part are ever opened.
    public static bool Opens(Uri url) => url.Scheme == "https" && url.UserInfo.Length == 0 && url.Host.Length > 0;

    public static readonly GuideActions Live = new();
}

/// "This PC already uses Tailscale", chosen on the first setup screen and kept for the ones after it.
public sealed class SetupReach
{
    public bool TailnetOnly { get; set; }
}

/// The pieces every guide screen is drawn from (App/Onboarding/OnboardingKit.swift), built in code.
public static class GuideKit
{
    public const double ContentWidth = 440;

    public static Brush Brush(string key) => ThemeBrushes.Get(key);
    public static Style Style(string key) => (Style)Application.Current.Resources[key];
    public static FontFamily CodeFont => (FontFamily)Application.Current.Resources["CodeFont"];

    public static Image AppIcon(double side = 72) => new()
    {
        Source = new BitmapImage(new Uri("ms-appx:///Assets/HermesHQ-256.png")),
        Width = side, Height = side, HorizontalAlignment = HorizontalAlignment.Center,
    };

    /// A screen of the guide: heading, content, then its ways on, centred in a column at most 440 wide.
    public static FrameworkElement Page(string heading, IEnumerable<UIElement> content, IEnumerable<UIElement>? footer = null,
        TextBlock? error = null, bool centred = false)
    {
        var column = new StackPanel { Spacing = 18, MaxWidth = ContentWidth, Padding = new Thickness(24, centred ? 0 : 12, 24, 32) };
        if (heading.Length > 0) column.Children.Add(Heading(heading));
        foreach (var c in content) column.Children.Add(c);
        if (error != null) column.Children.Add(error);
        if (footer != null)
        {
            var feet = new StackPanel { Spacing = 12, Margin = new Thickness(0, 8, 0, 0) };
            foreach (var f in footer) feet.Children.Add(f);
            column.Children.Add(feet);
        }
        return new ScrollViewer
        {
            Content = new Grid
            {
                Children = { column },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = centred ? VerticalAlignment.Center : VerticalAlignment.Top,
            },
            HorizontalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    public static TextBlock Heading(string text)
    {
        var t = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Style = Style("TitleTextBlockStyle") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        return t;
    }

    /// A paragraph in the guide's markup. `onLink` opens `<<text|address>>` links (null: drawn as plain text).
    public static TextBlock Paragraph(string markup, Action<string>? onLink = null, bool small = false, bool primary = false)
    {
        var t = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = onLink == null,
            Foreground = Brush(primary ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
            FontSize = small ? 13 : 14,
            LineHeight = small ? 19 : 21,
        };
        Fill(t.Inlines, markup, onLink);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(t, GuideText.Plain(markup));
        return t;
    }

    public static void Fill(InlineCollection inlines, string markup, Action<string>? onLink)
    {
        foreach (var span in GuideText.Parse(markup))
        {
            switch (span.Kind)
            {
                case GuideText.Kind.Bold:
                    inlines.Add(new Run { Text = span.Text, FontWeight = FontWeights.SemiBold });
                    break;
                case GuideText.Kind.Key:
                    inlines.Add(new Run { Text = span.Text, FontWeight = FontWeights.SemiBold, FontFamily = CodeFont });
                    break;
                case GuideText.Kind.Code:
                    inlines.Add(new Run { Text = span.Text, FontFamily = CodeFont });
                    break;
                case GuideText.Kind.Link when onLink != null && span.Address is { } address:
                    var link = new Hyperlink();
                    link.Inlines.Add(new Run { Text = span.Text });
                    link.Click += (_, _) => onLink(address);
                    inlines.Add(link);
                    break;
                default:
                    inlines.Add(new Run { Text = span.Text });
                    break;
            }
        }
    }

    /// A row of a chooser: its symbol, a title and a line, the whole row one button.
    public static Button ChoiceRow(string glyph, string title, string text, Action action)
    {
        var grid = new Grid { ColumnSpacing = 14, Padding = new Thickness(4, 6, 4, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 20, Foreground = Brush("AccentTextFillColorPrimaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        words.Children.Add(new TextBlock { Text = text, FontSize = 13, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush") });
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var chevron = new FontIcon { Glyph = "", FontSize = 11, Foreground = Brush("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 2);
        grid.Children.Add(chevron);
        var b = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(12, 8, 12, 8),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, title + ". " + text);
        b.Click += (_, _) => action();
        return b;
    }

    /// The screen's way on: the accent button, or the plain one beside or under it.
    public static Button Action(string title, Action action, bool prominent = true)
    {
        var b = new Button { Content = title, HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 34 };
        if (prominent) b.Style = Style("AccentButtonStyle");
        b.Click += (_, _) => action();
        return b;
    }

    /// A tinted text button (Get Tailscale, Copy All Steps, the guides' links).
    public static HyperlinkButton Link(string title, Action action)
    {
        var b = new HyperlinkButton { Content = title, Padding = new Thickness(0, 4, 0, 4) };
        b.Click += (_, _) => action();
        return b;
    }

    /// Numbered steps (`GuideSteps`).
    public static StackPanel Steps(IReadOnlyList<string> steps, Action<string>? onLink = null)
    {
        var panel = new StackPanel { Spacing = 14 };
        for (var i = 0; i < steps.Count; i++) panel.Children.Add(StepRow(i + 1, Paragraph(steps[i], onLink, primary: true)));
        return panel;
    }

    public static Grid StepRow(int number, UIElement content)
    {
        var g = new Grid { ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var badge = new Border
        {
            Width = 26, Height = 26, CornerRadius = new CornerRadius(13), VerticalAlignment = VerticalAlignment.Top,
            Background = Brush("AccentFillColorDefaultBrush"),
            Child = new TextBlock
            {
                Text = number.ToString(), FontWeight = FontWeights.SemiBold, FontSize = 13,
                Foreground = Brush("TextOnAccentFillColorPrimaryBrush"),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(badge, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        g.Children.Add(badge);
        if (content is FrameworkElement fe) Grid.SetColumn(fe, 1);
        g.Children.Add(content);
        return g;
    }

    /// A quiet card under steps (`GuideNote`).
    public static Border Note(string markup) => Card(Paragraph(markup, small: true));

    public static Border Card(UIElement child) => new()
    {
        Child = child, Padding = new Thickness(14, 12, 14, 12), CornerRadius = new CornerRadius(8),
        Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"),
        BorderThickness = new Thickness(1),
    };

    /// A command or message to select and copy (`GuideBlock`).
    public static Border Block(string text) => new()
    {
        Child = new TextBlock
        {
            Text = text, FontFamily = CodeFont, FontSize = 13, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        },
        Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(6),
        Background = Brush("SubtleFillColorSecondaryBrush"),
    };

    /// A status line under a Copy button (the web's `.ios-setup-copied`): it belongs to its card and stays until the
    /// next click on it.
    public static TextBlock StatusLine() => new()
    {
        FontSize = 13, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush"),
        Visibility = Visibility.Collapsed,
    };

    public static void Say(TextBlock line, string text)
    {
        line.Text = text;
        line.Visibility = text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// The command card: the text (or a disclosure holding it), Copy, and its status line (`CommandCard`).
    public static Border CommandCard(OnboardingCopy.FeedbackKind kind, string copyTitle, GuideActions actions,
        Func<bool> tailnetOnly, UIElement? body = null, string? block = null)
    {
        var panel = new StackPanel { Spacing = 10 };
        if (block != null) panel.Children.Add(Block(block));
        if (body != null) panel.Children.Add(body);
        var status = StatusLine();
        var copy = new Button { Content = copyTitle, Style = Style("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Stretch };
        copy.Click += (_, _) =>
        {
            Say(status, "");
            Say(status, actions.Copy(OnboardingCopy.Text(kind, tailnetOnly()))
                ? OnboardingCopy.Copied(kind) : OnboardingCopy.CouldNotCopy(kind));
        };
        panel.Children.Add(copy);
        panel.Children.Add(status);
        return Card(panel);
    }

    /// A disclosure (`GuideDisclosure`).
    public static Expander Disclosure(string title, UIElement content) => new()
    {
        Header = title, Content = content, HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
    };

    /// "This PC already uses Tailscale" (`GuideTailnetToggle`).
    public static StackPanel TailnetToggle(SetupReach reach, Action changed)
    {
        var toggle = new ToggleSwitch { IsOn = reach.TailnetOnly, OnContent = "", OffContent = "" };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, OnboardingCopy.Tailnet.ToggleTitle);
        toggle.Toggled += (_, _) => { reach.TailnetOnly = toggle.IsOn; changed(); };
        var g = new Grid { ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(new TextBlock { Text = OnboardingCopy.Tailnet.ToggleTitle, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        words.Children.Add(new TextBlock { Text = OnboardingCopy.Tailnet.ToggleText, FontSize = 13, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush") });
        g.Children.Add(words);
        Grid.SetColumn(toggle, 1);
        g.Children.Add(toggle);
        return new StackPanel { Children = { g } };
    }

    /// A screen's error line (`.ios-doc-error`): cleared on each click, set when a link could not open.
    public static TextBlock ErrorLine() => new()
    {
        TextWrapping = TextWrapping.Wrap, Foreground = Brush("SystemFillColorCriticalBrush"), Visibility = Visibility.Collapsed,
        IsTextSelectionEnabled = true,
    };

    /// Opens `address`; on failure the screen's error line says where to open it instead.
    public static async void OpenLink(GuideActions actions, string address, TextBlock error, Func<string, string>? failure = null)
    {
        Say(error, "");
        var opened = Uri.TryCreate(address, UriKind.Absolute, out var url) && await actions.Open(url);
        if (!opened) Say(error, (failure ?? OnboardingCopy.CouldNotOpen)(address));
    }
}
