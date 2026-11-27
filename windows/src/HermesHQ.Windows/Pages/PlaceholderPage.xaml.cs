using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace HermesHQ.Pages;

/// Stands in for a place whose Windows page isn't built yet.
public sealed partial class PlaceholderPage : Page
{
    public PlaceholderPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is PlaceArgs { Place: var p } args)
        {
            TitleText.Text = p.Title; Glyph.Glyph = p.Glyph;
            if (args.Argument is Exception failure)
            {
                NoteText.Text = "This page couldn't open.";
                DetailText.Text = failure.GetType().Name + ": " + failure.Message;
                DetailText.Visibility = Visibility.Visible;
            }
        }
    }
}
