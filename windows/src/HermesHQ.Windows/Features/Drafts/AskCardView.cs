using Hermes.Core.Asks;
using Hermes.Core.Model;
using Hermes.Core.Travel;
using HermesHQ.Features.Travel;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Drafts;

/// Native WinUI 3 card for `ask_to_act` (App/Asks/AskCardView.swift):
/// source line with app mark, optional quoted message, attachment chips, safe external link, bold question,
/// choice buttons (v1 immediate send or v2 ready-reply preview with Edit + Send), "Something else…" inline composer,
/// and "then" explanation.
public static class AskCardView
{
    private const double MaxCardWidth = 660;

    /// Builds an ask-to-act card for an `ask_to_act` tool call, or returns null if invalid.
    public static UIElement? TryBuild(ToolCall call, Action<string>? sendMessage) =>
        TryBuild(call, sendMessage, initialAnswer: null);

    public static UIElement? TryBuild(ToolCall call, Action<string>? sendMessage, AskAnswer? initialAnswer)
    {
        if (AskCards.Parse(call) is not { } ask) return null;
        return Build(ask, sendMessage, initialAnswer);
    }

    private static UIElement Build(AskCard ask, Action<string>? sendMessage, AskAnswer? initialAnswer)
    {
        var answer = initialAnswer;
        int? pickedChoice = null;
        var editedReplies = new Dictionary<int, string>();
        var showingOther = false;
        var otherDraft = "";

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
        AutomationProperties.SetAutomationId(card, "ask.card");

        void Render()
        {
            var stack = new StackPanel { Spacing = 8 };

            // Source line beside round app mark
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(new Border
            {
                Width = 26,
                Height = 26,
                CornerRadius = new CornerRadius(13),
                Background = ThemeBrushes.Get(answer != null ? "HQGreenBrush" : "AccentFillColorDefaultBrush"),
                Child = new FontIcon
                {
                    Glyph = answer != null ? "\uE73E" : GlyphFor(ask),
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get("TextOnAccentFillColorPrimaryBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            });

            var lead = ask.App;
            var rest = new[] { ask.From, ask.Place, ask.When }.Where(s => s.Length > 0).ToList();
            if (lead.Length == 0 && rest.Count > 0)
            {
                lead = rest[0];
                rest.RemoveAt(0);
            }
            if (lead.Length == 0) lead = "A question for you";
            var sourceLine = rest.Count > 0 ? $"{lead} · {string.Join(" · ", rest)}" : lead;
            head.Children.Add(new TextBlock
            {
                Text = sourceLine,
                FontSize = 13.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 2,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            stack.Children.Add(head);

            // Quoted message beside left accent bar
            if (ask.Quote.Length > 0)
            {
                var quoteGrid = new Grid { ColumnSpacing = 10 };
                quoteGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                quoteGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                quoteGrid.Children.Add(new Border
                {
                    Width = 3,
                    CornerRadius = new CornerRadius(1.5),
                    Background = ThemeBrushes.Get("HQTintBrush"),
                    Opacity = 0.65,
                });
                var qText = new TextBlock
                {
                    Text = $"“{ask.Quote}”",
                    FontSize = 13.5,
                    Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 6,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    IsTextSelectionEnabled = true,
                };
                Grid.SetColumn(qText, 1);
                quoteGrid.Children.Add(qText);
                stack.Children.Add(quoteGrid);
            }

            // Attachment chips
            if (ask.Attachments.Count > 0)
            {
                var chips = new StackPanel { Spacing = 4 };
                foreach (var att in ask.Attachments)
                {
                    var chipRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                    chipRow.Children.Add(new FontIcon
                    {
                        Glyph = "\uE8A5",
                        FontSize = 12,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    });
                    chipRow.Children.Add(new TextBlock
                    {
                        Text = att.Note.Length > 0 ? $"{att.Name} · {att.Note}" : att.Name,
                        FontSize = 12,
                        Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        MaxLines = 1,
                    });
                    chips.Children.Add(new Border
                    {
                        Child = chipRow,
                        Padding = new Thickness(10, 4, 10, 4),
                        CornerRadius = new CornerRadius(12),
                        BorderBrush = ThemeBrushes.Get("HQSeparatorBrush"),
                        BorderThickness = new Thickness(1),
                        HorizontalAlignment = HorizontalAlignment.Left,
                    });
                }
                stack.Children.Add(chips);
            }

            // Safe external link
            if (ask.Link is { } link && TravelCards.IsSafeWebUri(link.Url))
            {
                var linkBtn = new HyperlinkButton
                {
                    Content = $"{link.Title} ↗",
                    Padding = new Thickness(0, 2, 0, 2),
                    FontSize = 13.5,
                };
                AutomationProperties.SetAutomationId(linkBtn, "ask.link");
                linkBtn.Click += (_, _) => TravelUi.OpenSafeLink(link.Url);
                stack.Children.Add(linkBtn);
            }

            // Question
            stack.Children.Add(new TextBlock
            {
                Text = ask.Question,
                FontSize = 15,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 0),
            });

            if (answer != null)
            {
                var statusRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 2, 0, 0) };
                statusRow.Children.Add(new FontIcon
                {
                    Glyph = "\uE73E",
                    FontSize = 13,
                    Foreground = ThemeBrushes.Get("HQGreenBrush"),
                });
                statusRow.Children.Add(new TextBlock
                {
                    Text = AskCards.StatusText(ask, answer),
                    FontSize = 12.5,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                });
                stack.Children.Add(statusRow);

                if (answer is AskAnswer.Sent sent && sent.Reply.Length > 0)
                {
                    stack.Children.Add(new TextBlock
                    {
                        Text = sent.Reply,
                        FontSize = 13,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                        TextWrapping = TextWrapping.Wrap,
                        Margin = new Thickness(20, 0, 0, 0),
                    });
                }
            }
            else
            {
                // Choice buttons
                var choiceGrid = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 4, 0, 0) };
                for (var i = 0; i < ask.Choices.Count; i++)
                {
                    choiceGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    var idx = i;
                    var isFilled = pickedChoice.HasValue ? pickedChoice.Value == idx : idx == 0;
                    var choiceBtn = new Button
                    {
                        Content = ask.Choices[idx],
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        CornerRadius = new CornerRadius(18),
                        MinHeight = 36,
                        FontWeight = FontWeights.SemiBold,
                    };
                    if (isFilled) choiceBtn.Style = ThemeBrushes.Res<Style>("AccentButtonStyle");
                    AutomationProperties.SetAutomationId(choiceBtn, $"ask.choice.{idx + 1}");
                    choiceBtn.Click += (_, _) =>
                    {
                        if (AskCards.Reply(ask, idx) != null)
                        {
                            pickedChoice = idx;
                            showingOther = false;
                            Render();
                        }
                        else if (AskCards.ChoiceMessage(ask, idx) is { } msg)
                        {
                            answer = new AskAnswer.Choice(idx + 1, AskCards.Sentence(ask.Choices[idx]));
                            sendMessage?.Invoke(msg);
                            Render();
                        }
                    };
                    Grid.SetColumn(choiceBtn, idx);
                    choiceGrid.Children.Add(choiceBtn);
                }
                stack.Children.Add(choiceGrid);

                // v2 ready-reply preview when a choice with a pre-written reply is picked
                if (pickedChoice is { } picked && ask.ReplyTo is { } to && AskCards.Reply(ask, picked) is { } baseReply)
                {
                    var currentReply = editedReplies.TryGetValue(picked, out var ed) ? ed : baseReply;
                    var isEdited = currentReply != baseReply;

                    stack.Children.Add(new TextBlock
                    {
                        Text = AskCards.ReplyHeading(to) + (isEdited ? " · Edited" : ""),
                        FontSize = 12,
                        FontWeight = FontWeights.SemiBold,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                        Margin = new Thickness(0, 6, 0, 0),
                    });

                    var replyGrid = new Grid { ColumnSpacing = 10 };
                    replyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    replyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    replyGrid.Children.Add(new Border
                    {
                        Width = 2.5,
                        CornerRadius = new CornerRadius(1.25),
                        Background = ThemeBrushes.Get("HQTintBrush"),
                    });
                    var rText = new TextBlock
                    {
                        Text = currentReply,
                        FontSize = 14,
                        Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                        TextWrapping = TextWrapping.Wrap,
                        IsTextSelectionEnabled = true,
                    };
                    Grid.SetColumn(rText, 1);
                    replyGrid.Children.Add(rText);
                    stack.Children.Add(replyGrid);

                    stack.Children.Add(new Border
                    {
                        Height = 1,
                        Margin = new Thickness(0, 4, 0, 2),
                        Background = ThemeBrushes.Get("DividerStrokeColorDefaultBrush"),
                    });

                    var replyActions = new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 8,
                        HorizontalAlignment = HorizontalAlignment.Right,
                    };
                    var editReplyBtn = new Button
                    {
                        Content = "Edit",
                        CornerRadius = new CornerRadius(16),
                        Padding = new Thickness(14, 6, 14, 6),
                        MinHeight = 34,
                        FontWeight = FontWeights.SemiBold,
                    };
                    AutomationProperties.SetAutomationId(editReplyBtn, "ask.reply.edit");
                    editReplyBtn.Click += async (_, _) =>
                    {
                        var xr = card.XamlRoot ?? App.Window?.Content?.XamlRoot;
                        var edited = await EditReplyDialogAsync(currentReply, xr);
                        if (edited == null) return;
                        editedReplies[picked] = edited;
                        Render();
                    };

                    var sendReplyBtn = new Button
                    {
                        Content = "Send",
                        Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
                        CornerRadius = new CornerRadius(16),
                        Padding = new Thickness(16, 6, 16, 6),
                        MinHeight = 34,
                        FontWeight = FontWeights.SemiBold,
                    };
                    AutomationProperties.SetAutomationId(sendReplyBtn, "ask.reply.send");
                    sendReplyBtn.Click += (_, _) =>
                    {
                        if (AskCards.SendMessage(ask, picked, currentReply) is not { } msg) return;
                        answer = new AskAnswer.Sent(picked + 1, AskCards.Sentence(ask.Choices[picked]), currentReply);
                        sendMessage?.Invoke(msg);
                        Render();
                    };
                    replyActions.Children.Add(editReplyBtn);
                    replyActions.Children.Add(sendReplyBtn);
                    stack.Children.Add(replyActions);
                }

                // "Something else…"
                if (showingOther)
                {
                    var otherBox = new TextBox
                    {
                        PlaceholderText = "Type your answer…",
                        AcceptsReturn = true,
                        TextWrapping = TextWrapping.Wrap,
                        Text = otherDraft,
                        MaxHeight = 120,
                    };
                    var sendOtherBtn = new Button
                    {
                        Content = "Send",
                        Style = ThemeBrushes.Res<Style>("AccentButtonStyle"),
                        CornerRadius = new CornerRadius(16),
                        IsEnabled = !string.IsNullOrWhiteSpace(otherDraft),
                    };
                    otherBox.TextChanged += (_, _) =>
                    {
                        otherDraft = otherBox.Text;
                        sendOtherBtn.IsEnabled = !string.IsNullOrWhiteSpace(otherDraft);
                    };
                    var cancelOtherBtn = new Button
                    {
                        Content = "Cancel",
                        Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
                        CornerRadius = new CornerRadius(16),
                    };
                    cancelOtherBtn.Click += (_, _) => { showingOther = false; Render(); };
                    sendOtherBtn.Click += (_, _) =>
                    {
                        var trimmed = otherDraft.Trim();
                        if (trimmed.Length == 0) return;
                        answer = new AskAnswer.Other(trimmed);
                        sendMessage?.Invoke(AskCards.OtherMessage(ask, trimmed));
                        Render();
                    };
                    var otherRow = new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 8,
                        HorizontalAlignment = HorizontalAlignment.Right,
                    };
                    otherRow.Children.Add(cancelOtherBtn);
                    otherRow.Children.Add(sendOtherBtn);
                    stack.Children.Add(otherBox);
                    stack.Children.Add(otherRow);
                }
                else
                {
                    var otherBtn = new Button
                    {
                        Content = "Something else…",
                        Style = ThemeBrushes.Res<Style>("QuietButtonStyle"),
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        FontSize = 12.5,
                    };
                    AutomationProperties.SetAutomationId(otherBtn, "ask.other");
                    otherBtn.Click += (_, _) => { showingOther = true; Render(); };
                    stack.Children.Add(otherBtn);
                }

                if (ask.Then.Length > 0)
                {
                    stack.Children.Add(new TextBlock
                    {
                        Text = ask.Then,
                        FontSize = 12,
                        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                        TextWrapping = TextWrapping.Wrap,
                    });
                }
            }

            card.Child = stack;
        }

        Render();
        return card;
    }

    private static async Task<string?> EditReplyDialogAsync(string currentReply, XamlRoot? xamlRoot)
    {
        if (xamlRoot == null) return null;
        var box = new TextBox
        {
            Header = "Reply",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Text = currentReply,
            MinWidth = 420,
            MinHeight = 140,
            MaxHeight = 280,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        var dialog = new ContentDialog
        {
            Title = "Edit Reply",
            Content = box,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(currentReply),
        };
        box.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(box.Text);
        var result = await SafeDialog.ShowAsync(xamlRoot, dialog);
        if (result != ContentDialogResult.Primary) return null;
        var trimmed = box.Text.Trim();
        return trimmed.Length > 0 ? trimmed : null;
    }

    private static string GlyphFor(AskCard ask)
    {
        var kind = ask.App.ToLowerInvariant();
        if (kind.Contains("mail") || kind.Contains("gmail") || kind.Contains("outlook"))
            return "\uE715"; // Mail
        if (kind.Contains("slack") || kind.Contains("telegram") || kind.Contains("discord")
            || kind.Contains("message") || kind.Contains("text") || kind.Contains("whatsapp")
            || kind.Contains("sms") || kind.Contains("signal") || kind.Contains("teams") || kind.Contains("chat"))
            return "\uE8BD"; // Message
        return "\uE897"; // Help
    }
}
