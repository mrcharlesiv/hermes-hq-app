using Hermes.Core.Composer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace HermesHQ.Features.Composer;

/// + › Link… (docs/spec/3x-composer.md §4; App/Chat/Attachments/ChatAttachmentsController.swift presentLinkDialog):
/// "Add Link", "The page is fetched and included with your next message.", Attach off until the text is a link (no
/// https:// needed), "Include the full URL, e.g. https://…" while it isn't. The + menu and its tray belong to the
/// attachments feature: it calls this and adds the chip (`RefValue.UrlRef(url)` rides the next send).
public static class LinkDialog
{
    /// The link to attach, normalised ("https://example.com/post"), or null for Cancel.
    public static async Task<string?> ShowAsync(XamlRoot root)
    {
        var field = new TextBox { PlaceholderText = LinkText.Placeholder, IsSpellCheckEnabled = false, InputScope = null };
        AutomationProperties.SetName(field, "Link");
        var message = Ui.Text(LinkText.Message, 13, secondary: true);
        var body = new StackPanel { Spacing = 8, Width = 380 };
        body.Children.Add(message);
        body.Children.Add(field);
        var dialog = new ContentDialog
        {
            Title = LinkText.Title, Content = body, PrimaryButtonText = "Attach", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false,
        };
        field.TextChanged += (_, _) =>
        {
            var url = LinkText.Normalised(field.Text);
            var ok = LinkText.IsLink(url);
            dialog.IsPrimaryButtonEnabled = ok;
            message.Text = field.Text.Trim().Length > 0 && !ok ? LinkText.NotALink : LinkText.Message;
        };
        var submittedByEnter = false;
        field.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            e.Handled = true;
            if (dialog.IsPrimaryButtonEnabled) { submittedByEnter = true; dialog.Hide(); }
        };
        dialog.Opened += (_, _) => field.Focus(FocusState.Programmatic);
        var result = await Ui.Show(root, dialog);
        var link = LinkText.Normalised(field.Text);
        return (result == ContentDialogResult.Primary || submittedByEnter) && LinkText.IsLink(link) ? link : null;
    }
}
