using Hermes.Core.Jobs;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Features.Jobs;

internal static partial class JobsSidebarBadge
{
    private static void RegisterAppearance()
    {
        var place = Places.Get("jobs");
        place.Badge = Draw;
        place.BadgeAccessibility = () => JobsBadge.Accessibility(_running, _attention);
        SettingsHooks.Sidebar.Add(Settings);
    }

    // MacSidebar.PlaceRow: a trailing secondary count, a tint-coloured dot when folded.
    private static FrameworkElement? Draw(bool folded)
    {
        if (JobsBadge.Title(_attention) is not { } title) return null;
        if (folded) return new Ellipse
        {
            Width = 7, Height = 7, Fill = JobsUi.Brush("AccentFillColorDefaultBrush"),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -2, -3, 0),
        };
        return JobsUi.Text(title, 15, JobsUi.Secondary, wrap: false);
    }

    private static FrameworkElement Settings()
    {
        const string lead = "The red number on Jobs counts the jobs under Needs Attention: a failed run, a late run or an error. Paused jobs never count.";
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Right };
        picker.Items.Add("When Fixed");
        picker.Items.Add("When Seen");
        picker.SelectedIndex = Clear == JobsBadgeClear.WhenFixed ? 0 : 1;
        AutomationProperties.SetName(picker, "Jobs Badge");
        AutomationProperties.SetAutomationId(picker, "settings.jobs-badge");
        var footer = JobsUi.Text("", 12, JobsUi.Secondary);
        void SetFooter() => footer.Text = lead + (Clear == JobsBadgeClear.WhenFixed
            ? " When Fixed: a job counts until it runs without a problem, or you pause or delete it."
            : " When Seen: the number clears once you open Jobs, and a job counts again if it fails or runs late again.");
        SetFooter();
        picker.SelectionChanged += (_, _) =>
        {
            FilePreferences.Shared.Set(PreferenceKey, picker.SelectedIndex == 1 ? "whenSeen" : null);
            SetFooter();
            Update();
        };
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(JobsUi.Text("Jobs Badge", 14));
        Grid.SetColumn(picker, 1);
        row.Children.Add(picker);
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(JobsUi.Card(row));
        panel.Children.Add(footer);
        return panel;
    }
}
