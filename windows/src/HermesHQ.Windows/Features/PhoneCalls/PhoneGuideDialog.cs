using Hermes.Core.PhoneCalls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.PhoneCalls;

/// Port of `App/PhoneCalls/PhoneGuideView.swift`: plain-language guide covering 4-step samplehost setup,
/// how to place and steer calls from a chat, Voice API vs. TeXML troubleshooting (with copyable
/// `https://voice-events.invalid/hermes-hq`), and samplehost Level 1 vs. Level 2 verification.
public static class PhoneGuideDialog
{
    public static Task PresentAsync(XamlRoot? root)
    {
        var dialog = new ContentDialog
        {
            Title = "Phone Calls — Setup & how to use",
            Content = new ScrollViewer
            {
                Content = BuildContent(),
                MaxHeight = 560,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            },
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "phone.guide");
        return ShowAsync(root, dialog);
    }

    public static FrameworkElement BuildContent()
    {
        var body = new StackPanel { Spacing = 8, MinWidth = 460, MaxWidth = 560 };

        // 1. Quick setup (4 steps)
        body.Children.Add(Header("Quick setup"));
        var setupCard = new StackPanel { Spacing = 10 };
        setupCard.Children.Add(GuideStep(
            "1",
            "Add credit & get a samplehost number",
            "In portal.samplehost.com, add a few dollars of credit under Billing and buy an active voice number under Numbers › Buy Numbers."));
        setupCard.Children.Add(GuideStep(
            "2",
            "Connect your samplehost API key",
            "Create an API key under Keys & Credentials › API Keys and paste it into Phone Settings. Your key stays in Windows Credential Locker and is never sent to your gateway."));
        setupCard.Children.Add(GuideStep(
            "3",
            "Create your Voice API connection & AI Assistant",
            "Use Create Voice Connection and Create right in Phone Settings. One click configures an Outbound Voice Profile, a Voice API (Call Control) application, your number assignment, and a tuned voice assistant."));
        setupCard.Children.Add(GuideStep(
            "4",
            "Run Check My Setup",
            "Click Check My Setup in Phone Settings to confirm your key, number, Voice API connection, outbound profile, assistant, and balance all pass."));
        body.Children.Add(Card(setupCard, 12));

        // 2. How to use Phone Calls
        body.Children.Add(Header("How to use Phone Calls"));
        var useCard = new StackPanel { Spacing = 10 };
        useCard.Children.Add(GuideRow(
            "\uE734",
            "Ask your bot in any chat",
            "Ask in plain words — for example, “Call Corner Bistro at 212 555 0142 to book a table for two at 7” or “Call me to plan my afternoon.” Your bot prepares a Call card with the goal and opening line. Nothing dials until you click Review and Place call."));
        useCard.Children.Add(GuideRow(
            "\uE717",
            "Start a call manually",
            "Open any chat, click Phone Call, pick Someone else or Myself, enter the phone number and purpose, then review the opening line before dialing."));
        useCard.Children.Add(GuideRow(
            "\uE8F2",
            "Follow & steer live",
            "Watch the live transcript as they speak (a few seconds behind while samplehost streams batches). If the assistant needs a decision only you have, a Waiting on you card appears with click-to-answer choices. You can also whisper instructions at any point to guide it mid-call."));
        useCard.Children.Add(GuideRow(
            "\uE8A5",
            "Automatic chat summary",
            "When the call ends, Hermes HQ posts a summary card, any questions you answered, and the transcript back into the chat so your bot knows what happened."));
        body.Children.Add(Card(useCard, 12));

        // 3. Troubleshooting connection_id & TeXML errors
        body.Children.Add(Header("Troubleshooting connection_id & TeXML errors"));
        var texmlCard = new StackPanel { Spacing = 8 };
        texmlCard.Children.Add(Text("Use Voice API (Call Control), not TeXML", 14, bold: true));
        texmlCard.Children.Add(Text(
            "When an AI Assistant turns on telephony in samplehost, samplehost automatically creates a TeXML Application for it. Outbound calls from Hermes HQ use samplehost’s Voice API (POST /v2/calls), which rejects TeXML and SIP connections with “connection_id (Call Control App ID) is either invalid or does not exist.”",
            12, color: Secondary));
        texmlCard.Children.Add(Text(
            "Use Create Voice Connection in Phone Settings so Hermes HQ sets up a real Voice API application and links your number to it. If you create one manually in the samplehost portal, go to Voice › Programmable Voice › Voice API Applications (not TeXML), attach an enabled Outbound Voice Profile allowing your country, assign your phone number to it, and set an https:// webhook URL.",
            12, color: Secondary));

        var copyTitle = Text("Copy no-server webhook URL", 13, bold: true);
        var copyUrl = Text(PhoneLimits.VoiceWebhookUrl, 12, color: Secondary);
        var copyIcon = new FontIcon { Glyph = "\uE8C8", FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
        var copyGrid = new Grid { ColumnSpacing = 10 };
        copyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        copyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var copyLabels = new StackPanel { Spacing = 2 };
        copyLabels.Children.Add(copyTitle);
        copyLabels.Children.Add(copyUrl);
        copyGrid.Children.Add(copyLabels);
        Grid.SetColumn(copyIcon, 1);
        copyGrid.Children.Add(copyIcon);

        var copyBtn = new Button
        {
            Content = copyGrid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 8, 10, 8),
        };
        AutomationProperties.SetAutomationId(copyBtn, "phone.guide.copy-webhook");
        copyBtn.Click += (_, _) =>
        {
            Copy(PhoneLimits.VoiceWebhookUrl);
            copyTitle.Text = "Copied webhook URL";
            copyIcon.Glyph = "\uE73E";
            copyIcon.Foreground = Solid(Green);
        };
        texmlCard.Children.Add(copyBtn);
        texmlCard.Children.Add(Text(
            "Hermes HQ reads call status, events, and transcripts directly from samplehost with your API key, so no webhook server is needed.",
            11, color: Tertiary));
        body.Children.Add(Card(texmlCard, 12));

        // 4. Calling outside your own number (Level 1 vs Level 2)
        body.Children.Add(Header("Calling outside your own number"));
        var verifyCard = new StackPanel { Spacing = 6 };
        verifyCard.Children.Add(Text("Why a new samplehost account may only call your Verified Number", 14, bold: true));
        verifyCard.Children.Add(Text(
            "Brand-new samplehost accounts start at Level 1 verification. At Level 1, samplehost often restricts outbound calls to numbers you have verified under Verified Numbers in the samplehost portal, caps hourly call volume, or plays a brief automated-call notice.",
            12, color: Secondary));
        verifyCard.Children.Add(Text(
            "To call businesses and other people freely, complete Level 2 verification in the samplehost portal and make sure your Outbound Voice Profile lists the destination country (such as US).",
            12, color: Secondary));
        body.Children.Add(Card(verifyCard, 12));

        return body;
    }

    private static FrameworkElement GuideStep(string number, string title, string detail)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var num = Text(number, 14, bold: true, color: Accent);
        num.VerticalAlignment = VerticalAlignment.Top;
        grid.Children.Add(num);
        var col = new StackPanel { Spacing = 2 };
        col.Children.Add(Text(title, 13, bold: true));
        col.Children.Add(Text(detail, 12, color: Secondary));
        Grid.SetColumn(col, 1);
        grid.Children.Add(col);
        return grid;
    }

    private static FrameworkElement GuideRow(string glyph, string title, string detail)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = new FontIcon
        {
            Glyph = glyph,
            FontSize = 14,
            Foreground = Accent,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 0, 0),
        };
        grid.Children.Add(icon);
        var col = new StackPanel { Spacing = 2 };
        col.Children.Add(Text(title, 13, bold: true));
        col.Children.Add(Text(detail, 12, color: Secondary));
        Grid.SetColumn(col, 1);
        grid.Children.Add(col);
        return grid;
    }
}
