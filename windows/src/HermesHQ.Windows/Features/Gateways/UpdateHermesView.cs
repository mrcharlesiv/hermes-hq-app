using Hermes.Core.Gateways;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Onboarding.GuideKit;

namespace HermesHQ.Features.Gateways;

/// "Update Hermes" (App/Onboarding/UpdateHermesView.swift): the gateway accepted the sign-in, but its Hermes is older
/// than this app needs. It says what to do on that computer; Check Again enters once it is updated, and Continue
/// Anyway is the person's call (the sign-in is saved either way, so the next launch goes straight in).
/// The Mac's Update Hermes button (running the update from the app) comes with Status & Maintenance.
public sealed class UpdateHermesView : UserControl
{
    private readonly UpdateHermesModel _model;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly TextBlock _recovery, _release, _status;
    private readonly ProgressRing _ring;
    private readonly Button _check, _continue;
    private readonly Button? _update;

    /// [insights] Opens the Update sheet for the gateway in use (`root`, then what to run once it updated). Null: no
    /// Update Hermes button (Check Again leads).
    public static Action<Microsoft.UI.Xaml.XamlRoot?, Action>? UpdateHook { get; set; }

    public UpdateHermesView(UpdateHermesModel model)
    {
        _model = model;
        var title = new TextBlock { Text = OutdatedCopy.Title, Style = Style("TitleTextBlockStyle"), TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        _recovery = new TextBlock { TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush"), LineHeight = 21 };
        var name = new TextBlock { Text = model.Name, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        _release = new TextBlock { FontSize = 13, Foreground = Brush("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap };
        var card = Card(new StackPanel { Spacing = 3, Children = { name, _release } });
        // [insights] The Mac's Update Hermes button: the one Update sheet (Features/Insights/UpdateSheet.cs), set through
        // `UpdateHook`; once the sheet closes on "Updated to …", the page checks again by itself.
        var update = UpdateHook != null && model.Info.CanUpdate
            ? Action("Update Hermes", () => UpdateHook?.Invoke(XamlRoot, () => _ = _model.CheckAgainAsync())) : null;
        _check = Action(OutdatedCopy.CheckAgain, () => _ = _model.CheckAgainAsync(), prominent: update == null);
        _update = update;
        _continue = Action(OutdatedCopy.ContinueAnyway, _model.ContinueAnyway, prominent: false);
        _ring = new ProgressRing { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        _status = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush"), TextAlignment = TextAlignment.Center };
        var statusRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 24, Children = { _ring, _status } };
        var column = new StackPanel { Spacing = 14, MaxWidth = ContentWidth, Padding = new Thickness(24, 32, 24, 32), VerticalAlignment = VerticalAlignment.Center };
        foreach (var e in new UIElement?[] { AppIcon(), title, _recovery, card, update, _check, _continue, statusRow }) if (e != null) column.Children.Add(e);
        Content = new ScrollViewer { Content = new Grid { Children = { column } }, HorizontalScrollMode = ScrollMode.Disabled };
        model.Changed += () => _ui.TryEnqueue(Render);
        Render();
    }

    private void Render()
    {
        _recovery.Text = _model.Recovery;
        _release.Text = _model.Release;
        _status.Text = _model.Status;
        _ring.IsActive = _model.Busy;
        _ring.Visibility = _model.Busy ? Visibility.Visible : Visibility.Collapsed;
        _check.IsEnabled = _continue.IsEnabled = !_model.Busy;
        if (_update != null) _update.IsEnabled = !_model.Busy;
        Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(_status)?
            .RaiseNotificationEvent(Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.ActionCompleted,
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.MostRecent, _model.Status, "update-hermes");
    }
}
