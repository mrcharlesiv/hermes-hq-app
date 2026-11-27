using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace HermesHQ.Features.Gateways;

/// Hosts a launch-flow screen (launch, offline, onboarding) in the window's frame, so leaving the shell is a real
/// navigation: ShellPage's OnNavigatedFrom stops its polls and drops its handlers.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class RootHostPage : Page
{
    protected override void OnNavigatedTo(NavigationEventArgs e) => Content = e.Parameter as UIElement;

    protected override void OnNavigatedFrom(NavigationEventArgs e) => Content = null;
}
