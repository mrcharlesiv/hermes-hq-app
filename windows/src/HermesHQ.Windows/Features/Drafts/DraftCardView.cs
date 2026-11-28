using Hermes.Core.Drafts;
using Hermes.Core.Model;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Drafts;

/// Native WinUI 3 draft card for `draft_message` (App/Questions/PromptRows.swift `draftWaiting` + `ChatPromptCell`):
/// single-surface calm card (`HQPromptCardBrush` / `HQPromptEdgeBrush`) with To/Cc/Bcc/From/Via/Subject header fields
/// (12-name cap via `DraftCards.ShownPeople`), optional conversation thread preview, left-accent bar beside body,
/// subtle divider, and Don't Send / Edit (opening `DraftEditDialog`) / Send actions.
public static class DraftCardView
{
    private const double MaxCardWidth = 660;
    private const int BodyClampLines = 14;

    /// Builds a draft card for a `draft_message` tool call, or returns null if invalid.
    public static UIElement? TryBuild(ToolCall call, Action<string>? sendMessage) =>
        TryBuild(call, sendMessage, DraftState.Waiting);

    public static UIElement? TryBuild(ToolCall call, Action<string>? sendMessage, DraftState initialState)
    {
        if (DraftCards.Parse(call) is not { } original) return null;
        return Build(original, sendMessage, initialState);
    }

    private static UIElement Build(Draft original, Action<string>? sendMessage, DraftState initialState)
    {
        var current = original;
        var state = initialState;
        var bodyExpanded = false;
        var threadExpanded = false;

        var card = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14, 12, 14, 12),
            Margin = new Thickness(16, 6, 16, 6),
            MaxWidth = MaxCardWidth,
            HorizontalAlignment = HorizontalAlignment.Left,
            Background = ThemeBrushes.Get("HQPromptCardBrush"),
            BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(card, "draft.card");

        bool IsEdited() =>
            current.Body != original.Body
            || current.To != original.To
            || current.Cc != original.Cc
            || current.Bcc != original.Bcc
            || current.Subject != original.Subject;

        void Render()
        {
            var edited = IsEdited();
            var stack = new StackPanel { Spacing = 8 };

            // Header: round app mark + "<App> draft" (+ " · Edited")
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(new Border
            {
                Width = 26,
                Height = 26,
                CornerRadius = new CornerRadius(13),
                Background = ThemeBrushes.Get(state == DraftState.Skipped
                    ? "ControlStrongFillColorDisabledBrush"
                    : state == DraftState.Sent ? "HQGreenBrush" : "AccentFillColorDefaultBrush"),
                Child = new FontIcon
                {
                    Glyph = state == DraftState.Sent ? "\uE73E" : GlyphFor(current),
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get("TextOnAccentFillColorPrimaryBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            });
            head.Children.Add(new TextBlock
            {
                Text = DraftCards.Heading(current) + (edited ? " · Edited" : ""),
                FontSize = 14.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
            });
            stack.Children.Add(head);

            // Header fields: To, Cc, Bcc, From, Via, Subject (with 12-name cap for people lists)
            var fields = DraftCards.Fields(current);
            if (fields.Count > 0)
            {
                var fieldGrid = new Grid { ColumnSpacing = 12, RowSpacing = 4 };
                fieldGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                fieldGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                for (var i = 0; i < fields.Count; i++)
                {
                    var f = fields[i];
                    fieldGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                    var lbl = new TextBlock
                    {
                        Text = f.Label,
                        FontSize = 13,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    };
                    var shownValue = f.People ? DraftCards.ShownPeople(f.Value) : f.Value;
                    var val = new TextBlock
                    {
                        Text = shownValue,
                        FontSize = 13,
                        FontWeight = f.Strong ? FontWeights.SemiBold : FontWeights.Normal,
                        Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                        TextWrapping = TextWrapping.Wrap,
                        IsTextSelectionEnabled = true,
                    };
                    if (!f.People)
                    {
                        val.MaxLines = 2;
                        val.TextTrimming = TextTrimming.CharacterEllipsis;
                    }
                    Grid.SetRow(lbl, i);
                    Grid.SetRow(val, i);
                    Grid.SetColumn(val, 1);
                    fieldGrid.Children.Add(lbl);
                    fieldGrid.Children.Add(val);
                }
                stack.Children.Add(fieldGrid);
            }

            // Optional conversation thread preview
            if (current.Thread.Count > 0)
            {
                var threadGrid = new Grid { ColumnSpacing = 10, Margin = new Thickness(0, 2, 0, 2) };
                threadGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                threadGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                threadGrid.Children.Add(new Border
                {
                    Width = 2.5,
                    CornerRadius = new CornerRadius(1.25),
                    Background = ThemeBrushes.Get("HQSeparatorBrush"),
                });
                var messagesStack = new StackPanel { Spacing = 6 };
                var shownMessages = threadExpanded
                    ? current.Thread
                    : current.Thread.Skip(Math.Max(0, current.Thread.Count - 2)).ToList();
                foreach (var msg in shownMessages)
                {
                    var itemStack = new StackPanel { Spacing = 1 };
                    var meta = string.Join("  ", new[] { msg.From, msg.When }.Where(s => s.Length > 0));
                    if (meta.Length > 0)
                    {
                        itemStack.Children.Add(new TextBlock
                        {
                            Text = meta,
                            FontSize = 11.5,
                            FontWeight = FontWeights.SemiBold,
                            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                        });
                    }
                    itemStack.Children.Add(new TextBlock
                    {
                        Text = msg.Text,
                        FontSize = 12.5,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                        TextWrapping = TextWrapping.Wrap,
                        MaxLines = threadExpanded ? 0 : 4,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    });
                    messagesStack.Children.Add(itemStack);
                }
                if (current.Thread.Count > 1 || current.Thread[0].Text.Length > 180)
                {
                    var toggleThread = new HyperlinkButton
                    {
                        Content = threadExpanded ? "Hide Conversation" : DraftCards.ThreadTitle(current),
                        Padding = new Thickness(0, 2, 0, 0),
                        FontSize = 12,
                    };
                    toggleThread.Click += (_, _) => { threadExpanded = !threadExpanded; Render(); };
                    messagesStack.Children.Add(toggleThread);
                }
                Grid.SetColumn(messagesStack, 1);
                threadGrid.Children.Add(messagesStack);
                stack.Children.Add(threadGrid);
            }

            // Single-surface body beside left accent bar (calm-chat design: no nested paper box)
            var bodyGrid = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 2, 0, 2) };
            bodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            bodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            bodyGrid.Children.Add(new Border
            {
                Width = 2.5,
                Margin = new Thickness(11, 2, 0, 2),
                CornerRadius = new CornerRadius(1.25),
                Background = ThemeBrushes.Get(state == DraftState.Waiting ? "HQTintBrush" : "HQSeparatorBrush"),
            });

            var bodyStack = new StackPanel { Spacing = 4 };
            var bodyText = new TextBlock
            {
                Text = current.Body,
                FontSize = 14,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                MaxLines = bodyExpanded ? 0 : BodyClampLines,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            bodyStack.Children.Add(bodyText);

            var showAll = new HyperlinkButton
            {
                Content = bodyExpanded ? "Show Less" : "Show All",
                Padding = new Thickness(0),
                FontSize = 12,
                Visibility = bodyExpanded ? Visibility.Visible : Visibility.Collapsed,
            };
            bodyText.IsTextTrimmedChanged += (_, _) =>
            {
                if (!bodyExpanded && bodyText.IsTextTrimmed)
                    showAll.Visibility = Visibility.Visible;
            };
            showAll.Click += (_, _) => { bodyExpanded = !bodyExpanded; Render(); };
            bodyStack.Children.Add(showAll);

            Grid.SetColumn(bodyStack, 1);
            bodyGrid.Children.Add(bodyStack);
            stack.Children.Add(bodyGrid);

            // Footer: subtle divider + Don't Send / Edit / Send while waiting, else quiet settled status
            if (DraftCards.StatusText(state, edited) is { } statusText)
            {
                var statusRow = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    Margin = new Thickness(0, 4, 0, 0),
                };
                statusRow.Children.Add(new FontIcon
                {
                    Glyph = state == DraftState.Sent ? "\uE73E" : "\uE738",
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get(state == DraftState.Sent ? "HQGreenBrush" : "TextFillColorTertiaryBrush"),
                });
                statusRow.Children.Add(new TextBlock
                {
                    Text = statusText,
                    FontSize = 12.5,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                });
                stack.Children.Add(statusRow);
            }
            else
            {
                stack.Children.Add(new Border
                {
                    Height = 1,
                    Margin = new Thickness(0, 4, 0, 2),
                    Background = ThemeBrushes.Get("DividerStrokeColorDefaultBrush"),
                });
                var actions = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    HorizontalAlignment = HorizontalAlignment.Right,
                };
                var skipBtn = new Button
                {
                    Content = "Don’t Send",
                    CornerRadius = new CornerRadius(16),
                    Padding = new Thickness(14, 6, 14, 6),
                    MinHeight = 34,
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0),
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    FontWeight = FontWeights.SemiBold,
                };
                AutomationProperties.SetAutomationId(skipBtn, "draft.skip");
                skipBtn.Click += (_, _) =>
                {
                    state = DraftState.Skipped;
                    sendMessage?.Invoke(DraftCards.SkipMessage(original));
                    Render();
                };

                var editBtn = new Button
                {
                    Content = "Edit",
                    CornerRadius = new CornerRadius(16),
                    Padding = new Thickness(14, 6, 14, 6),
                    MinHeight = 34,
                    FontWeight = FontWeights.SemiBold,
                };
                AutomationProperties.SetAutomationId(editBtn, "draft.edit");
                editBtn.Click += async (_, _) =>
                {
                    var xr = card.XamlRoot ?? App.Window?.Content?.XamlRoot;
                    var result = await DraftEditDialog.ShowAsync(current, xr);
                    if (result == null) return;
                    current = current with
                    {
                        To = result.To,
                        Cc = result.Cc,
                        Bcc = result.Bcc,
                        Subject = result.Subject,
                        Body = result.Body,
                    };
                    Render();
                };

                var sendBtn = new Button
                {
                    Content = "Send",
                    Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
                    CornerRadius = new CornerRadius(16),
                    Padding = new Thickness(16, 6, 16, 6),
                    MinHeight = 34,
                    FontWeight = FontWeights.SemiBold,
                };
                AutomationProperties.SetAutomationId(sendBtn, "draft.send");
                sendBtn.Click += (_, _) =>
                {
                    state = DraftState.Sent;
                    sendMessage?.Invoke(DraftCards.SendMessage(
                        original,
                        current.Body,
                        current.To,
                        current.Cc,
                        current.Bcc,
                        current.Subject));
                    Render();
                };

                actions.Children.Add(skipBtn);
                actions.Children.Add(editBtn);
                actions.Children.Add(sendBtn);
                stack.Children.Add(actions);
            }

            card.Child = stack;
        }

        Render();
        return card;
    }

    private static string GlyphFor(Draft draft)
    {
        var kind = DraftCards.Name(draft).ToLowerInvariant();
        if (kind.Contains("mail") || kind.Contains("gmail") || kind.Contains("outlook"))
            return "\uE715"; // Mail
        if (kind.Contains("slack") || kind.Contains("telegram") || kind.Contains("discord")
            || kind.Contains("message") || kind.Contains("text") || kind.Contains("whatsapp")
            || kind.Contains("sms") || kind.Contains("signal") || kind.Contains("teams"))
            return "\uE8BD"; // Message
        return "\uE70F"; // Edit
    }
}
