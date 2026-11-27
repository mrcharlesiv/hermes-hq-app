using Hermes.Core.Questions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using static HermesHQ.Features.Questions.QuestionUi;

namespace HermesHQ.Features.Questions;

/// What the approval card shows (App/Questions/PromptRows.swift `ApprovalCardRow`).
internal sealed record ApprovalCardState(ApprovalPrompt Approval, int Position, int Total, bool Expired, bool StackExpired,
    string? BotName);

internal enum ApprovalButton { Reject, Dismiss, Session, Always, Run }

/// The approval card at the transcript's newest end (spec 1x §4.2; Mac: PromptRows.approval, ChatPromptCell): "Approval
/// needed", "Command" / "Command details" with "1 / 2" and the countdown, the command (monospaced, at most 8 lines,
/// Show All), the reason, and Reject · More… · Run. Expired: "Approval expired", the expired line, and Dismiss.
internal sealed class ApprovalCard
{
    public const int CommandClampLines = 8;

    private readonly TextBlock _expiry = Text("", 12, "TextFillColorTertiaryBrush");

    public Border View { get; }
    public ApprovalCardState State { get; }
    /// The card's actions row (the jump brings its bottom into view).
    public FrameworkElement Actions { get; }

    public ApprovalCard(ApprovalCardState s, string expiry, Action<ApprovalButton> tapped, Action showAll)
    {
        State = s;
        var a = s.Approval;
        var stack = new StackPanel();
        stack.Children.Add(Header(Title(s), "", dim: s.Expired)); // CommandPrompt

        // "Command" / "Command details", then "1 / 2" and the countdown (trailing, updated in place).
        var meta = new Grid { Margin = new Thickness(0, 10, 0, 0), ColumnSpacing = 8 };
        meta.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        meta.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        meta.Children.Add(Text(a.ShowsDescription ? "Command details" : "Command", 12, "TextFillColorSecondaryBrush"));
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (s.Total > 1) trailing.Children.Add(Text($"{s.Position} / {s.Total}", 11, "TextFillColorTertiaryBrush"));
        _expiry.Text = expiry;
        trailing.Children.Add(_expiry);
        Grid.SetColumn(trailing, 1);
        meta.Children.Add(trailing);
        stack.Children.Add(meta);

        // The command (or the description) on an inset panel, wrapping anywhere, at most 8 lines.
        var details = (a.ShowsDescription ? a.Description : a.Command).Trim();
        if (details.Length > 0)
        {
            var body = new TextBlock
            {
                Text = details, TextWrapping = TextWrapping.Wrap, MaxLines = CommandClampLines,
                TextTrimming = TextTrimming.CharacterEllipsis, IsTextSelectionEnabled = true,
                FontSize = 12.5,
            };
            if (!a.ShowsDescription) body.FontFamily = Mono;
            var paperStack = new StackPanel { Spacing = 4 };
            paperStack.Children.Add(body);
            var more = new HyperlinkButton { Content = "Show All", Padding = new Thickness(0), FontSize = 12, Visibility = Visibility.Collapsed };
            more.Click += (_, _) => showAll();
            body.IsTextTrimmedChanged += (_, _) => more.Visibility = body.IsTextTrimmed ? Visibility.Visible : Visibility.Collapsed;
            paperStack.Children.Add(more);
            stack.Children.Add(new Border
            {
                Child = paperStack, Padding = new Thickness(12), Margin = new Thickness(0, 8, 0, 0),
                CornerRadius = new CornerRadius(8), Background = Brush("SubtleFillColorSecondaryBrush"),
            });
        }
        // The reason under a shown command.
        if (!a.ShowsDescription && a.Description.Trim() is { Length: > 0 } reason)
        {
            var r = Text(reason, 12, "TextFillColorSecondaryBrush");
            r.Margin = new Thickness(0, 4, 0, 0);
            stack.Children.Add(r);
        }
        if (s.Expired)
        {
            var who = s.BotName?.Trim() is { Length: > 0 } n ? n : "the bot";
            var line = Text($"This request expired. Ask {who} to try again.", 12, "TextFillColorSecondaryBrush");
            line.Margin = new Thickness(0, 8, 0, 0);
            stack.Children.Add(line);
        }

        // Reject · More… (or the one extra) · Run, trailing; Dismiss alone once expired.
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
        };
        var buttons = new List<Control>();
        Button Add(ApprovalButton which, string title, bool accent = false, bool plain = false)
        {
            var b = Capsule(title, accent, plain);
            if (a.Answering is { } choice && Choice(which) == choice) b.Content = Spinner();
            b.Click += (_, _) => tapped(which);
            buttons.Add(b);
            row.Children.Add(b);
            return b;
        }
        if (s.Expired) Add(ApprovalButton.Dismiss, "Dismiss", plain: true);
        else
        {
            Add(ApprovalButton.Reject, "Reject", plain: true);
            if (a.AllowSession && a.AllowAlways)
            {
                var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.TopEdgeAlignedRight };
                var session = new MenuFlyoutItem { Text = "Allow for This Chat" };
                session.Click += (_, _) => tapped(ApprovalButton.Session);
                var always = new MenuFlyoutItem { Text = "Always Allow…" };
                always.Click += (_, _) => tapped(ApprovalButton.Always);
                menu.Items.Add(session);
                menu.Items.Add(always);
                var more = new DropDownButton
                {
                    Content = a.Answering is ApprovalChoice.Session or ApprovalChoice.Always ? Spinner() : "More…",
                    Flyout = menu, CornerRadius = new CornerRadius(16), Padding = new Thickness(14, 6, 10, 6), MinHeight = 32,
                };
                buttons.Add(more);
                row.Children.Add(more);
            }
            else if (a.AllowSession) Add(ApprovalButton.Session, "Allow for This Chat");
            else if (a.AllowAlways) Add(ApprovalButton.Always, "Always Allow…");
            Add(ApprovalButton.Run, "Run", accent: true);
        }
        if (a.Answering != null) foreach (var b in buttons) b.IsEnabled = false;
        stack.Children.Add(row);
        Actions = row;

        View = Card(stack);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(View, "prompt.approval");
        View.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(200) };
        AutomationName(View, $"{Title(s)}. {(a.ShowsDescription ? "Command details" : "Command")}: {details}. {expiry}");
    }

    /// The countdown, once a second, in place.
    public void SetExpiry(string label) => _expiry.Text = label;

    /// Answered: the card fades out (200 ms) before it goes.
    public void Leave() => View.Opacity = 0;

    public static string Title(ApprovalCardState s) => s.StackExpired ? "Approval expired" : "Approval needed";

    private static ApprovalChoice? Choice(ApprovalButton b) => b switch
    {
        ApprovalButton.Run => ApprovalChoice.Once,
        ApprovalButton.Reject => ApprovalChoice.Deny,
        ApprovalButton.Session => ApprovalChoice.Session,
        ApprovalButton.Always => ApprovalChoice.Always,
        _ => null,
    };

    private static void AutomationName(UIElement e, string name) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(e, name);
}
