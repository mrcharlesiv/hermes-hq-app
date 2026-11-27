using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Pages;

/// The content pane with nothing in it, after Close Chat or Archive Chat (Hermes.Core.Shell.ChatKeys): navigating here
/// lets the chat page go (its OnNavigatedFrom closes the chat), and the shell's "No Chat Open" shows over it. A
/// code-only Frame target, so it is marked Bindable for the Release XAML compiler (windows/PORTING.md).
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class EmptyPane : Page
{
}
