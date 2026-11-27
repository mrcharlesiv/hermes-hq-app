using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace HermesHQ.Features.Onboarding;

/// MainWindow's frame measures at room/zoom and then draws at zoom. Only the root welcome needs the
/// original room for layout (including its guide bar and ScrollViewer), with UI Scale applied to type instead.
internal sealed partial class WelcomeScaleHost : Panel
{
    private readonly Grid _guide;
    private bool _welcome;
    private double _zoom = 1;

    internal WelcomeScaleHost(Grid guide)
    {
        _guide = guide;
        Children.Add(guide);
        Loaded += (_, _) => FollowScale();
        Unloaded += (_, _) => ThemeService.Changed -= UpdateScale;
    }

    internal void ShowWelcome(bool welcome)
    {
        if (_welcome == welcome) return;
        _welcome = welcome;
        FollowScale();
    }

    private void FollowScale()
    {
        ThemeService.Changed -= UpdateScale;
        if (_welcome && IsLoaded) ThemeService.Changed += UpdateScale;
        UpdateScale();
    }

    private void UpdateScale()
    {
        var zoom = _welcome ? ThemeService.State.Scale : 1;
        if (zoom == _zoom) return;
        _zoom = zoom;
        _guide.RenderTransform = zoom == 1 ? null : new ScaleTransform { ScaleX = 1 / zoom, ScaleY = 1 / zoom };
        InvalidateMeasure();
    }

    protected override Size MeasureOverride(Size available)
    {
        _guide.Measure(new Size(available.Width * _zoom, available.Height * _zoom));
        return new Size(_guide.DesiredSize.Width / _zoom, _guide.DesiredSize.Height / _zoom);
    }

    protected override Size ArrangeOverride(Size slot)
    {
        _guide.Arrange(new Rect(0, 0, slot.Width * _zoom, slot.Height * _zoom));
        return slot;
    }
}
