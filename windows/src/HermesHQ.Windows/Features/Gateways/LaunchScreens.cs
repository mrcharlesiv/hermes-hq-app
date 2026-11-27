using Hermes.Core.Offline;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Onboarding.GuideKit;

namespace HermesHQ.Features.Gateways;

/// The launch screen (App/Offline/LaunchViewController.swift): the icon alone; an activity indicator once the wait is
/// noticeable; a caption; after 12 s still not connected, Try Again and Change Address or Sign In.
public sealed class LaunchView : UserControl
{
    private readonly ProgressRing _spinner;
    private readonly TextBlock _caption;
    private readonly StackPanel _actions;
    private readonly Button _different;
    private string _spoken = "";

    public LaunchView(Action tryAgain, Action differentGateway)
    {
        var icon = AppIcon(96);
        AutomationProperties.SetName(icon, "Hermes HQ");
        _spinner = new ProgressRing { Width = 24, Height = 24, IsActive = false, Opacity = 0 };
        _caption = new TextBlock { TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 360, Foreground = Brush("TextFillColorSecondaryBrush"), MinHeight = 40 };
        var again = Action(OfflineCopy.TryAgain, tryAgain);
        _different = Action(OfflineCopy.DifferentGateway, differentGateway, prominent: false);
        _actions = new StackPanel { Spacing = 12, Width = 300, Visibility = Visibility.Collapsed, Children = { again, _different } };
        var column = new StackPanel { Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        foreach (var e in new UIElement[] { icon, _spinner, _caption, _actions }) column.Children.Add(e);
        Content = new Grid { Children = { column } };
    }

    /// "Change Address or Sign In" needs a gateway to start from.
    public bool OffersDifferentGateway { set => _different.Visibility = value ? Visibility.Visible : Visibility.Collapsed; }

    public void Render(LaunchGate.View view)
    {
        _spinner.IsActive = view.Spinner;
        _spinner.Opacity = view.Spinner ? 1 : 0;
        var words = view.Phase == LaunchGate.Phase.Gone ? "" : view.Status;
        _caption.Text = words;
        _actions.Visibility = view.Actions ? Visibility.Visible : Visibility.Collapsed;
        Opacity = view.Phase == LaunchGate.Phase.Shown ? 1 : 0;
        if (words.Length > 0 && words != _spoken)
        {
            _spoken = words;
            FrameworkElementAutomationPeer.FromElement(_caption)?.RaiseNotificationEvent(AutomationNotificationKind.Other,
                AutomationNotificationProcessing.MostRecent, words, "launch");
        }
    }
}

/// The offline screen (App/Offline/OfflineView.swift): icon, cause title, recovery words, a card naming the gateway,
/// Try Again / Change Address or Sign In / Sign In Again / Switch to another saved gateway, and the status line — a
/// countdown redrawn from the due date four times a second. Narrator hears "Trying again automatically", never a number.
public sealed partial class OfflineView : UserControl
{
    private readonly OfflineScreenModel _model;
    private readonly TextBlock _title, _recovery, _cardName, _cardDetail, _status;
    private readonly Border _card;
    private readonly Button _tryAgain, _different, _signInAgain;
    private readonly StackPanel _switches;
    private readonly ProgressRing _ring;
    private readonly Action<string> _switch;

    public OfflineView(OfflineScreenModel model, Action tryAgain, Action differentGateway, Action signInAgain, Action<string> switchTo)
    {
        _model = model;
        _switch = switchTo;
        _title = new TextBlock { Style = Style("TitleTextBlockStyle"), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center };
        AutomationProperties.SetHeadingLevel(_title, AutomationHeadingLevel.Level1);
        _recovery = new TextBlock { TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 360, Foreground = Brush("TextFillColorSecondaryBrush"), IsTextSelectionEnabled = true, HorizontalAlignment = HorizontalAlignment.Center };
        _cardName = new TextBlock { FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        _cardDetail = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush") };
        _card = Card(new StackPanel { Spacing = 3, Children = { _cardName, _cardDetail } });
        _tryAgain = Action(OfflineCopy.TryAgain, tryAgain);
        _different = Action(OfflineCopy.DifferentGateway, differentGateway, prominent: false);
        _signInAgain = Action(OfflineCopy.SignInAgain, signInAgain, prominent: false);
        _switches = new StackPanel { Spacing = 12 };
        _ring = new ProgressRing { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        _status = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = Brush("TextFillColorSecondaryBrush") };
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        var statusRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 22, Children = { _ring, _status } };
        var buttons = new StackPanel { Spacing = 14, Children = { _tryAgain, _different, _signInAgain, _switches } };
        var column = new StackPanel { Spacing = 0, MaxWidth = ContentWidth, Padding = new Thickness(24, 32, 24, 32), VerticalAlignment = VerticalAlignment.Center };
        var header = new StackPanel { Spacing = 10, Margin = new Thickness(0, 0, 0, 24) };
        header.Children.Add(AppIcon());
        header.Children.Add(_title);
        header.Children.Add(_recovery);
        column.Children.Add(header);
        _card.Margin = new Thickness(0, 0, 0, 24);
        column.Children.Add(_card);
        column.Children.Add(buttons);
        statusRow.Margin = new Thickness(0, 20, 0, 0);
        column.Children.Add(statusRow);
        Content = new ScrollViewer { Content = new Grid { Children = { column } }, HorizontalScrollMode = ScrollMode.Disabled };
        ObserveCountdown();
        Render();
    }

    private void AnnounceStatus(string words) => FrameworkElementAutomationPeer.FromElement(_status)?.RaiseNotificationEvent(
        AutomationNotificationKind.Other, AutomationNotificationProcessing.MostRecent, words, "offline");

    /// The reason, the gateway or the other gateways changed.
    public void Render()
    {
        var screen = _model.Screen;
        _title.Text = screen.Title;
        _recovery.Text = screen.Recovery;
        if (_model.Card is { } card)
        {
            _cardName.Text = card.Name;
            _cardDetail.Text = card.Detail;
            _cardDetail.Visibility = card.Detail.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            _card.Visibility = Visibility.Visible;
        }
        else _card.Visibility = Visibility.Collapsed;
        _different.Visibility = _model.ShowsDifferentGateway ? Visibility.Visible : Visibility.Collapsed;
        _signInAgain.Visibility = _model.ShowsSignInAgain ? Visibility.Visible : Visibility.Collapsed;
        _switches.Children.Clear();
        foreach (var other in _model.OtherGateways)
        {
            var key = other.Key;
            _switches.Children.Add(Action(OfflineCopy.SwitchTo(other.Title), () => _switch(key), prominent: false));
        }
        RenderStatus();
    }

    private void RenderStatus()
    {
        _status.Text = _model.StatusText(DateTimeOffset.UtcNow);
        AutomationProperties.SetName(_status, _model.SpokenStatus);
        var busy = _model.ConnectingNow && string.IsNullOrEmpty(_model.Problem);
        _ring.IsActive = busy;
        _ring.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        _tryAgain.IsEnabled = _model.TryAgainEnabled;
    }

    /// Try Again was pressed: focus moves to the status line.
    public void FocusStatus() => _tryAgain.Focus(FocusState.Programmatic);
}
