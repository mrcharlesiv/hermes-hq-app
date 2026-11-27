using Hermes.Core.Onboarding;
using Hermes.Core.Settings;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;
using Copy = Hermes.Core.Onboarding.OnboardingCopy.Welcome;

namespace HermesHQ.Features.Onboarding;

/// The first-run welcome block (Mac 1245, WelcomeView.swift:11–64,77–84). No guide action runs when this view loads.
public sealed partial class WelcomeScreen : UserControl
{
    private readonly UISettings _text = new();
    private readonly bool _rootWelcome;
    private readonly ResourceDictionary _light = new(), _dark = new();
    private readonly List<(ColumnDefinition Track, FontIcon Symbol, TextBlock Title, TextBlock Detail)> _rows = [];

    public WelcomeScreen() : this(null) { }

    internal WelcomeScreen(GuideContext? c)
    {
        _rootWelcome = c?.Centred == true;
        // Resolve the actual button template keys here, closer than WinUI's copy of the system-accent brushes.
        // No Button keys in HighContrast: keep the user's native colours for every interaction state.
        PaintButtons(install: true);
        Resources.ThemeDictionaries["Light"] = _light;
        Resources.ThemeDictionaries["Dark"] = _dark;
        Resources.ThemeDictionaries["HighContrast"] = new ResourceDictionary();
        InitializeComponent();

        Heading.Text = Copy.HeadingLine1 + "\n" + Copy.HeadingLine2;
        AutomationProperties.SetName(Heading, Copy.HeadingLine1 + " " + Copy.HeadingLine2);
        Lead.Text = Copy.Lead;
        foreach (var point in Copy.Points) AddPoint(point);
        Start.Content = Copy.Start;
        Address.Content = Copy.HaveAddress;
        AutomationProperties.SetName(Start, Copy.Start);
        AutomationProperties.SetName(Address, Copy.HaveAddress);
        if (c != null)
        {
            Start.Click += (_, _) => c.Go(OnboardingStep.Start);
            Address.Click += (_, _) => c.Go(OnboardingStep.Connect);
        }
        if (c is { Centred: false })
        {
            Column.VerticalAlignment = VerticalAlignment.Top;
            Room.Padding = new Thickness(24 * WelcomeMetrics.Catalyst, 12 * WelcomeMetrics.Catalyst,
                24 * WelcomeMetrics.Catalyst, 32 * WelcomeMetrics.Catalyst);
        }
        SizeType();
        Loaded += (_, _) => ObserveAppearance(true);
        Unloaded += (_, _) => ObserveAppearance(false);
    }

    internal Style GuideBarStyle => (Style)PageGround.Resources["WelcomeGuideBar"];

    private void AddPoint(OnboardingCopy.Point point)
    {
        var track = new ColumnDefinition();
        var row = new Grid { ColumnSpacing = WelcomeMetrics.SymbolGap };
        row.ColumnDefinitions.Add(track);
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var symbol = new FontIcon { Glyph = point.Glyph, Style = (Style)PageGround.Resources["PointSymbol"], VerticalAlignment = VerticalAlignment.Top };
        AutomationProperties.SetAccessibilityView(symbol, AccessibilityView.Raw);
        TextBlock Words(string text, string style) => new()
        {
            Text = text, Style = (Style)PageGround.Resources[style], TextWrapping = TextWrapping.Wrap,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
        };
        var title = Words(point.Title, "PointTitle");
        var detail = Words(point.Text, "PointDetail");
        var words = new StackPanel { Spacing = WelcomeMetrics.PointTextGap, Children = { title, detail } };
        Grid.SetColumn(words, 1);
        row.Children.Add(symbol);
        row.Children.Add(words);
        AutomationProperties.SetName(row, point.Title + " " + point.Text);
        Points.Children.Add(row);
        _rows.Add((track, symbol, title, detail));
    }

    private void ObserveAppearance(bool observe)
    {
        _text.TextScaleFactorChanged -= TextChanged;
        ThemeService.Changed -= AppearanceChanged;
        if (!observe) return;
        _text.TextScaleFactorChanged += TextChanged;
        ThemeService.Changed += AppearanceChanged;
        AppearanceChanged(); // the app or OS text size may have changed while detached
    }

    private void AppearanceChanged() { PaintButtons(); SizeType(); }
    private void TextChanged(UISettings sender, object args)
    {
        if (Services.AppShutdown.Stopping) return;
        DispatcherQueue?.TryEnqueue(() => { if (!Services.AppShutdown.Stopping && IsLoaded) SizeType(); });
    }

    // OnboardingKit.swift:149–155. A minimum, never a fixed height: wrapped/large text starts at the top and scrolls.
    private void ViewportChanged(object sender, SizeChangedEventArgs e) => Room.MinHeight = e.NewSize.Height;

    private void SizeType()
    {
        double scale;
        try { scale = _text.TextScaleFactor; }
        catch (System.Runtime.InteropServices.COMException) { scale = 1; }
        var theme = ThemeService.State;
        var m = WelcomeMetrics.For(scale, theme.DesktopLook, _rootWelcome ? theme.UiScalePercent : 100);
        static void Leading(TextBlock words, WelcomeLine line)
        {
            words.LineHeight = line.Pitch;
            var margin = words.Margin;
            words.Margin = new Thickness(margin.Left, margin.Top, margin.Right, line.EndMargin);
        }
        Heading.FontSize = m.Title;
        Leading(Heading, m.TitleLine);
        Lead.FontSize = Start.FontSize = Address.FontSize = m.Body;
        Leading(Lead, m.LeadLine);
        Start.MinHeight = Address.MinHeight = m.ButtonMinHeight;
        Start.CornerRadius = Address.CornerRadius = new CornerRadius(m.ButtonCorner);
        foreach (var row in _rows)
        {
            row.Track.Width = new GridLength(m.SymbolTrack);
            row.Symbol.FontSize = m.Symbol;
            row.Title.FontSize = m.Body;
            row.Title.LineHeight = m.HeadlineLine;
            row.Detail.FontSize = m.Detail;
            row.Detail.LineHeight = m.DetailLine;
        }
    }

    private void PaintButtons(bool install = false)
    {
        void Paint(ResourceDictionary palette, ThemeTokens t, bool dark)
        {
            WelcomeMetrics.ButtonBrushes(t, dark, ThemeService.State.DesktopLook, (key, value) =>
            {
                var color = ThemeService.ToColor(value);
                if (install) palette[key] = new SolidColorBrush(color);
                else ((SolidColorBrush)palette[key]).Color = color;
            });
        }
        Paint(_light, ThemeService.Set.Light, dark: false);
        Paint(_dark, ThemeService.Set.Dark, dark: true);
    }
}
