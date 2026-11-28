using Hermes.Core.Questions;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Questions.QuestionUi;

namespace HermesHQ.Features.Questions;

/// The question note at the transcript's newest end (spec 1x §4.4; Mac: PromptRows.note): asked ("A question for
/// you" and the first question), not delivered, or the answers just sent ("Your answers", until the clarify tool's
/// settled card arrives).
internal static class ClarifyNote
{
    public const string UndeliveredText =
        "This question didn’t reach the app, so it can’t be answered here. Press Stop to end the turn, then reply in chat.";

    /// The note for what the chat shows now, or null for none. When `clarifyDockExpanded` is true, the live
    /// "A question for you" card is suppressed so it does not duplicate the expanded dock (Mac: PromptRows.swift).
    public static Border? Build(ChatPrompts p, bool clarifyDockExpanded = false)
    {
        if (p.Clarify is { } c)
        {
            if (clarifyDockExpanded) return null;
            var count = c.Questions.Count;
            var title = count > 1 ? $"{count} questions for you" : "A question for you";
            var full = c.Questions.Select(q => q.Question.Trim()).Where(q => q.Length > 0).ToList();
            var detail = full.Count > 0 ? string.Join("\n\n", full) : (c.Questions.FirstOrDefault()?.Question ?? "");
            var body = Text(detail, 13.5);
            body.MaxLines = 8;
            body.TextTrimming = TextTrimming.CharacterEllipsis;
            return Note(title, "", body); // Help (a question mark)
        }
        if (p.ClarifyUndelivered)
            return Note("A question for you", "", Text(UndeliveredText, 13.5, "TextFillColorSecondaryBrush")); // Warning
        if (p.SentClarify is { } sent) return Answers(sent.Rows);
        return null;
    }

    /// A clarify call's settled card in the transcript, in its tool part's place (Mac: PromptRows.settled,
    /// ChatPromptCell's Answer Now): each question, its answer beside the picked mark, or "No answer" / "Skipped" in
    /// italics beside a hollow mark; hairlines between. A question left without an answer (and none given later):
    /// Answer Now, an accent capsule at the card's trailing foot, beside the last "No answer" when that ends the card.
    public static Border Settled(SettledClarifyCard card, Action<SettledClarifyCard>? answerNow)
    {
        var (title, skipped) = SettledClarify.Header(card);
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(Header(title, skipped ? "\uE738" : "\uE897", dim: skipped)); // Remove (minus) : Help
        Button? button = null;
        if (card.Answerable && answerNow != null)
        {
            button = Capsule(SettledClarify.AnswerNowTitle, accent: true);
            button.HorizontalAlignment = HorizontalAlignment.Right;
            button.VerticalAlignment = VerticalAlignment.Center;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(button, "clarify.answerNow");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(button, SettledClarify.AnswerNowHint(card));
            button.Click += (_, _) => answerNow(card);
        }
        for (var i = 0; i < card.Rows.Count; i++)
        {
            var row = card.Rows[i];
            if (i > 0)
                stack.Children.Add(new Border
                {
                    Height = 1, Background = Brush("DividerStrokeColorDefaultBrush"), Margin = new Thickness(0, 4, 0, 4),
                });
            stack.Children.Add(Text(row.Question, 13, "TextFillColorSecondaryBrush"));
            var blank = row.Answer.Trim().Length == 0;
            var line = new Grid { ColumnSpacing = 8 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new FontIcon
            {
                Glyph = blank ? "\uE738" : "\uE73E", FontSize = 14, VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 0, 0),
                Foreground = Brush(blank ? "TextFillColorTertiaryBrush" : "AccentTextFillColorPrimaryBrush"),
            });
            var text = Text(SettledClarify.Words(row), 14, blank ? "TextFillColorTertiaryBrush" : "TextFillColorPrimaryBrush", semibold: !blank);
            if (blank) text.FontStyle = Windows.UI.Text.FontStyle.Italic;
            Grid.SetColumn(text, 1);
            line.Children.Add(text);
            // Beside the last "No answer" (the Mac: no wasted space), centred on its line.
            if (button != null && blank && i == card.Rows.Count - 1)
            {
                Grid.SetColumn(button, 2);
                line.Children.Add(button);
                button = null;
            }
            stack.Children.Add(line);
        }
        if (button != null)
        {
            button.Margin = new Thickness(0, 4, 0, 0);
            stack.Children.Add(button);
        }
        var view = Card(stack);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(view, "clarify.note");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(view, SettledClarify.Spoken(card));
        return view;
    }

    private static Border Note(string title, string glyph, TextBlock detail)
    {
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(Header(title, glyph));
        stack.Children.Add(detail);
        var card = Card(stack);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, $"{title}. {detail.Text}");
        return card;
    }

    /// "Your answer(s)", or "Question skipped" / "N questions skipped" when none was given; each question, its answer
    /// beside the dock's picked mark, or "Skipped" / "No answer" in italics; hairlines between.
    private static Border Answers(IReadOnlyList<SentClarifyRow> rows)
    {
        var none = rows.Count > 0 && rows.All(r => string.IsNullOrWhiteSpace(r.Answer));
        var title = none ? (rows.Count == 1 ? "Question skipped" : $"{rows.Count} questions skipped")
            : rows.Count == 1 ? "Your answer" : "Your answers";
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(Header(title, none ? "" : "")); // Remove (minus) : Help
        var spoken = new List<string> { title };
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            if (i > 0)
                stack.Children.Add(new Border
                {
                    Height = 1, Background = Brush("DividerStrokeColorDefaultBrush"), Margin = new Thickness(0, 4, 0, 4),
                });
            stack.Children.Add(Text(row.Question, 13, "TextFillColorSecondaryBrush"));
            var answer = row.Answer?.Trim() ?? "";
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var blank = answer.Length == 0;
            line.Children.Add(new FontIcon
            {
                Glyph = blank ? "" : "", FontSize = 14, VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 0, 0),
                Foreground = Brush(blank ? "TextFillColorTertiaryBrush" : "AccentTextFillColorPrimaryBrush"),
            });
            var words = blank ? (row.Answer == null ? "No answer" : "Skipped") : answer;
            var text = Text(words, 14, blank ? "TextFillColorTertiaryBrush" : "TextFillColorPrimaryBrush", semibold: !blank);
            if (blank) text.FontStyle = Windows.UI.Text.FontStyle.Italic;
            line.Children.Add(text);
            stack.Children.Add(line);
            spoken.Add($"{row.Question}: {words}");
        }
        var card = Card(stack);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, string.Join(". ", spoken));
        return card;
    }
}
