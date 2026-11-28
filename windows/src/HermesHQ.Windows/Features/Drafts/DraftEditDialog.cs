using Hermes.Core.Drafts;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Drafts;

/// Edited values saved from `DraftEditDialog` (unsent until the user taps Send on the draft card).
public sealed record DraftEditResult(string To, string Cc, string Bcc, string Subject, string Body);

/// Edit dialog for a draft card (To, Cc, Bcc, Subject, Body) — saving updates the card in place without sending.
public static class DraftEditDialog
{
    public static async Task<DraftEditResult?> ShowAsync(Draft current, XamlRoot? xamlRoot)
    {
        if (xamlRoot == null) return null;

        var toBox = new TextBox
        {
            Header = "To",
            Text = current.To,
            PlaceholderText = "Recipient",
        };
        AutomationProperties.SetAutomationId(toBox, "draft.edit.to");

        var ccBox = new TextBox
        {
            Header = "Cc",
            Text = current.Cc,
            PlaceholderText = "Comma-separated recipients",
        };
        AutomationProperties.SetAutomationId(ccBox, "draft.edit.cc");

        var bccBox = new TextBox
        {
            Header = "Bcc",
            Text = current.Bcc,
            PlaceholderText = "Comma-separated recipients",
        };
        AutomationProperties.SetAutomationId(bccBox, "draft.edit.bcc");

        var subjectBox = new TextBox
        {
            Header = "Subject",
            Text = current.Subject,
            PlaceholderText = "Subject",
        };
        AutomationProperties.SetAutomationId(subjectBox, "draft.edit.subject");

        var bodyBox = new TextBox
        {
            Header = "Message",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Text = current.Body,
            MinHeight = 140,
            MaxHeight = 280,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(bodyBox, ScrollBarVisibility.Auto);
        AutomationProperties.SetAutomationId(bodyBox, "draft.edit.body");

        var form = new StackPanel { Spacing = 10, MinWidth = 440, MaxWidth = 540 };
        form.Children.Add(toBox);
        form.Children.Add(ccBox);
        form.Children.Add(bccBox);
        form.Children.Add(subjectBox);
        form.Children.Add(bodyBox);

        var scroll = new ScrollViewer
        {
            Content = form,
            MaxHeight = 520,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
        };

        var dialog = new ContentDialog
        {
            Title = "Edit Draft",
            Content = scroll,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(current.Body),
        };
        AutomationProperties.SetAutomationId(dialog, "draft.edit.dialog");

        bodyBox.TextChanged += (_, _) =>
        {
            dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(bodyBox.Text);
        };

        var result = await SafeDialog.ShowAsync(xamlRoot, dialog);
        if (result != ContentDialogResult.Primary) return null;

        var body = bodyBox.Text.Trim();
        if (body.Length == 0) return null;

        return new DraftEditResult(
            To: toBox.Text.Trim(),
            Cc: ccBox.Text.Trim(),
            Bcc: bccBox.Text.Trim(),
            Subject: subjectBox.Text.Trim(),
            Body: body);
    }
}
