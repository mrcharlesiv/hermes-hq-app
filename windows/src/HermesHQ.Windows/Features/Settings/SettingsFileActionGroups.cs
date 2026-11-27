using Hermes.Core.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace HermesHQ.Features.Settings;

/// About alone: try both natural-width button groups on one line, then two leading-aligned lines.
/// A horizontal viewport is only needed when even a pair is wider than the card (large text or a narrow window).
internal sealed partial class SettingsFileActionGroups : Panel
{
    private readonly Rows _rows;
    private readonly Button _first;
    private readonly ScrollViewer _scroll;
    private readonly SettingsFileActionViewport _layout = new();
    private ScrollContentPresenter? _presenter;
    private double _cardEdge;

    public static Border InCard(Button export, Button import, Button clearModels, Button reset)
    {
        var group = new SettingsFileActionGroups(export, import, clearModels, reset);
        var card = Kit.Card(group);
        group._cardEdge = card.BorderThickness.Left; // Kit.Card's uniform native stroke
        return card;
    }

    private SettingsFileActionGroups(Button export, Button import, Button clearModels, Button reset)
    {
        _first = export;
        UseResetInk(reset);
        _rows = new Rows(export, import, clearModels, reset);
        Children.Add(_scroll = new ScrollViewer
        {
            Content = _rows, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            BringIntoViewOnFocusChange = true, IsTabStop = false,
        });
        _rows.Loaded += (_, _) => AttachPresenter();
        _rows.Unloaded += (_, _) => DetachPresenter();
    }

    private void AttachPresenter()
    {
        DetachPresenter();
        // Stay inside this ScrollViewer, not the vertical scroller that owns the Settings page.
        for (var p = VisualTreeHelper.GetParent(_rows); p != null && p != _scroll; p = VisualTreeHelper.GetParent(p))
        {
            if (p is not ScrollContentPresenter presenter) continue;
            _presenter = presenter;
            presenter.SizeChanged += PresenterSizeChanged;
            InvalidateMeasure();
            break;
        }
    }

    private void PresenterSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (e.NewSize.Width != e.PreviousSize.Width && Equals(sender, _presenter)) InvalidateArrange();
    }

    private void DetachPresenter()
    {
        if (_presenter != null) _presenter.SizeChanged -= PresenterSizeChanged;
        _presenter = null;
    }

    private static void UseResetInk(Button reset)
    {
        // Override only the native template's *normal* ink. A local Foreground would hold today's
        // brush across a Windows contrast change. Disabled, focus and contrast stay native.
        foreach (var mode in new[] { "Light", "Dark" })
        {
            if (Application.Current.Resources.ThemeDictionaries.TryGetValue(mode, out var entry) &&
                entry is ResourceDictionary palette && palette.TryGetValue("SystemFillColorCriticalBrush", out var ink))
                reset.Resources.ThemeDictionaries[mode] = new ResourceDictionary { ["ButtonForeground"] = ink };
        }
        reset.Resources.ThemeDictionaries["HighContrast"] = new ResourceDictionary(); // fall through to WinUI's button colours
        reset.ClearValue(Control.ForegroundProperty);
    }

    protected override Size MeasureOverride(Size available)
    {
        // In the stock template the presenter spans the * content row and the Auto scrollbar row.
        // Keep it in the first row even on a remeasure: the second is zero when hidden and otherwise
        // reserves the real expanded track and its margins. No copied scrollbar or assumed thickness.
        if (_presenter is { } p && Grid.GetRowSpan(p) == 2 && Grid.GetRow(p) == 0 &&
            VisualTreeHelper.GetParent(p) is Grid { RowDefinitions.Count: 2 } grid && grid.RowDefinitions[1].Height.IsAuto)
            Grid.SetRowSpan(p, 1);

        var inMain = XamlRoot is { } root && root == App.Window?.Content?.XamlRoot;
        var focusRoom = Math.Max(0, -_first.FocusVisualMargin.Top); // default native push buttons have one uniform focus outset
        var (slot, viewport) = _layout.Measure(available.Width);
        _rows.Propose(viewport, SettingsFileActionMetrics.For(ThemeService.State, inMain, _cardEdge, focusRoom));
        _scroll.Measure(new Size(slot, available.Height));
        // This stretch child follows the column, not the reverse. Don't turn the old inline width
        // into a minimum that WinUI would arrange beyond a newly narrowed card.
        return new Size(double.IsInfinity(available.Width) ? _scroll.DesiredSize.Width : 0, _scroll.DesiredSize.Height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        _scroll.Arrange(new Rect(0, 0, final.Width, final.Height));
        var viewport = _presenter == null ? final.Width : (float)_presenter.ActualWidth;
        if (_layout.Arrange(final.Width, viewport)) InvalidateMeasure();
        return final;
    }

    private sealed partial class Rows : Panel
    {
        private readonly StackPanel _files, _resets;
        private SettingsFileActionMetrics _metrics;
        private SettingsFileActionRows _fit;
        private double _viewportWidth;

        public Rows(Button export, Button import, Button clearModels, Button reset)
        {
            Children.Add(_files = Pair(export, import));
            Children.Add(_resets = Pair(clearModels, reset));
        }

        private static StackPanel Pair(Button first, Button second) => new()
        {
            Orientation = Orientation.Horizontal, Children = { first, second },
        };

        public void Propose(double width, SettingsFileActionMetrics metrics)
        {
            if (_metrics == metrics && _viewportWidth == width) return;
            if (_metrics != metrics)
            {
                foreach (var pair in new[] { _files, _resets })
                {
                    pair.Spacing = metrics.Gap;
                    foreach (Button button in pair.Children)
                    {
                        button.FontSize = metrics.FontSize;
                        // MacPush overlays its stroke; WinUI's ContentPresenter measures border *plus*
                        // padding. Keep the real native border inside the same label inset.
                        var edge = button.BorderThickness;
                        button.Padding = new Thickness(
                            Math.Max(0, metrics.ButtonSide - edge.Left), Math.Max(0, metrics.ButtonVertical - edge.Top),
                            Math.Max(0, metrics.ButtonSide - edge.Right), Math.Max(0, metrics.ButtonVertical - edge.Bottom));
                    }
                }
                _metrics = metrics;
            }
            _viewportWidth = width;
            InvalidateMeasure();
        }

        protected override Size MeasureOverride(Size available)
        {
            var natural = new Size(double.PositiveInfinity, double.PositiveInfinity);
            _files.Measure(natural);
            _resets.Measure(natural);
            var a = _files.DesiredSize;
            var b = _resets.DesiredSize;
            _fit = _metrics.Fit(_viewportWidth, a.Width, a.Height, b.Width, b.Height);
            return new Size(_fit.Width, _fit.Height);
        }

        protected override Size ArrangeOverride(Size final)
        {
            // Arrange the same measured buttons. The scroll extent is not a new offer to fit four across.
            var a = _files.DesiredSize;
            var b = _resets.DesiredSize;
            // The insets are inside the extent, leaving room for the system focus outline even at either end.
            _files.Arrange(new Rect(_metrics.SideInset, _fit.FirstY, a.Width, a.Height));
            _resets.Arrange(new Rect(_fit.SecondX, _fit.SecondY, b.Width, b.Height));
            return final;
        }
    }
}
