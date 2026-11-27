using Hermes.Core.Attachments;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Attachments;

/// Settings › Chat Behavior › Largest Attachment (the Mac's row: a number field with "MB" beside it and its help
/// under it; HermesKit/Attachments/AttachmentLimit.swift). Ready for the Settings page to place; 1…100, 100 by default,
/// set on this PC for every bot.
public sealed partial class LargestAttachmentRow : StackPanel
{
    public LargestAttachmentRow()
    {
        Spacing = 4;
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new TextBlock { Text = "Largest Attachment", VerticalAlignment = VerticalAlignment.Center });
        var box = new NumberBox
        {
            Minimum = AttachmentLimit.Min, Maximum = AttachmentLimit.Max, Value = AttachmentLimit.Megabytes, Width = 90,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, SmallChange = 1, LargeChange = 10,
        };
        AutomationProperties.SetName(box, "Largest Attachment, in MB");
        box.ValueChanged += (_, e) =>
        {
            if (double.IsNaN(e.NewValue)) { box.Value = AttachmentLimit.Megabytes; return; }
            AttachmentLimit.Megabytes = (int)Math.Floor(e.NewValue);
            if (box.Value != AttachmentLimit.Megabytes) box.Value = AttachmentLimit.Megabytes;
        };
        Grid.SetColumn(box, 1);
        row.Children.Add(box);
        var mb = new TextBlock { Text = "MB", VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(mb, 2);
        row.Children.Add(mb);
        Children.Add(row);
        Children.Add(new TextBlock
        {
            Text = AttachmentLimit.Footer, TextWrapping = TextWrapping.Wrap, FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        });
    }
}
