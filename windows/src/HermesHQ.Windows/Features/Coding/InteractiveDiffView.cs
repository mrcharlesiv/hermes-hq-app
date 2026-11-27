using Hermes.Core.Coding;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Coding;

/// Interactive unified diff viewer with parsed hunks, old/new line numbers, and inline line-comment composer.
public sealed class InteractiveDiffView : UserControl
{
    private readonly SessionPRFile _file;
    private readonly DiffCommentStore _comments;
    private readonly string? _prLabel;
    private readonly Action<string>? _onSendReview;
    private readonly ParsedDiff _parsed;

    private (DiffLineSide Side, int LineNumber)? _composingAt;
    private string? _editingCommentId;
    private readonly StackPanel _body = new() { Spacing = 2 };
    private static readonly FontFamily Mono = new("Cascadia Code, Consolas, Courier New");

    public InteractiveDiffView(
        SessionPRFile file,
        DiffCommentStore comments,
        string? prLabel = null,
        Action<string>? onSendReview = null)
    {
        _file = file;
        _comments = comments;
        _prLabel = prLabel;
        _onSendReview = onSendReview;
        _parsed = DiffParser.Parse(file.Path, file.Patch, file.PatchCut);

        AutomationProperties.SetAutomationId(this, "coding.diff");
        Content = _body;
        Render();
    }

    public void Render()
    {
        _body.Children.Clear();

        // Top file summary + review send bar
        var topBar = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 0, 0, 8) };
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topBar.Children.Add(Text($"{_file.Path}   +{_parsed.Additions} \u2212{_parsed.Deletions}", 12, bold: true, color: Secondary));
        if (_comments.OpenCount > 0 && _onSendReview != null)
        {
            var send = Push($"Send Review ({_comments.OpenCount})", () =>
            {
                var msg = _comments.FormatReviewMessage(_prLabel);
                if (!string.IsNullOrWhiteSpace(msg)) _onSendReview(msg);
            }, accent: true);
            Grid.SetColumn(send, 1);
            topBar.Children.Add(send);
        }
        _body.Children.Add(topBar);

        if (_file.Binary)
        {
            _body.Children.Add(Card(Text("Binary file diff is not displayed inline.", 13, color: Secondary)));
            return;
        }
        if (_parsed.Hunks.Count == 0)
        {
            _body.Children.Add(Card(Text(_file.PatchCut ? "Diff too large to show inline. Open on GitHub to view full file." : "No patch content available.", 13, color: Secondary)));
            return;
        }

        if (_parsed.Truncated)
            _body.Children.Add(Card(Text("Diff truncated to 20,000 characters. Open on GitHub for the complete patch.", 12, color: Secondary), 8));

        foreach (var hunk in _parsed.Hunks)
        {
            foreach (var line in hunk.Lines)
            {
                _body.Children.Add(DiffLineRow(line));

                if (line.CanComment && line.AnchorLineNumber is { } anchorLine)
                {
                    var existing = _comments.ForLine(_file.Path, line.AnchorSide, anchorLine);
                    foreach (var comment in existing)
                        _body.Children.Add(CommentCard(comment));

                    if (_composingAt is { } target && target.Side == line.AnchorSide && target.LineNumber == anchorLine)
                        _body.Children.Add(InlineComposer(line.AnchorSide, anchorLine));
                }
            }
        }
    }

    private FrameworkElement DiffLineRow(DiffLine line)
    {
        var grid = new Grid { ColumnSpacing = 6, Padding = new Thickness(4, 1, 8, 1) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        if (line.CanComment && line.AnchorLineNumber is { } anchorLine)
        {
            var addBtn = new Button
            {
                Content = "+",
                FontSize = 11,
                Padding = new Thickness(4, 0, 4, 0),
                MinWidth = 22,
                MinHeight = 20,
                Style = Style("QuietButtonStyle"),
            };
            ToolTipService.SetToolTip(addBtn, $"Add comment on line {anchorLine}");
            AutomationProperties.SetName(addBtn, $"Add comment on line {anchorLine}");
            var side = line.AnchorSide;
            addBtn.Click += (_, _) =>
            {
                _composingAt = (side, anchorLine);
                Render();
            };
            grid.Children.Add(addBtn);
        }

        var oldText = new TextBlock
        {
            Text = line.OldLine?.ToString() ?? "",
            FontFamily = Mono,
            FontSize = 11,
            Foreground = Tertiary,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(oldText, 1);
        grid.Children.Add(oldText);

        var newText = new TextBlock
        {
            Text = line.NewLine?.ToString() ?? "",
            FontFamily = Mono,
            FontSize = 11,
            Foreground = Tertiary,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(newText, 2);
        grid.Children.Add(newText);

        var code = new TextBlock
        {
            Text = line.Text.Length == 0 ? " " : line.Text,
            FontFamily = Mono,
            FontSize = 12,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.NoWrap,
            Foreground = line.Kind switch
            {
                DiffLineKind.HunkHeader => Accent,
                DiffLineKind.FileHeader or DiffLineKind.NoNewline => Secondary,
                _ => Brush("TextFillColorPrimaryBrush"),
            },
        };
        Grid.SetColumn(code, 3);
        grid.Children.Add(code);

        Brush? bg = line.Kind switch
        {
            DiffLineKind.Added => new SolidColorBrush(Color.FromArgb(36, 0x2E, 0xA0, 0x43)),
            DiffLineKind.Removed => new SolidColorBrush(Color.FromArgb(36, 0xE5, 0x48, 0x4D)),
            DiffLineKind.HunkHeader => new SolidColorBrush(Color.FromArgb(24, 0x0A, 0x84, 0xFF)),
            _ => null,
        };

        return new Border { Background = bg, Child = grid };
    }

    private FrameworkElement InlineComposer(DiffLineSide side, int lineNumber)
    {
        var input = new TextBox
        {
            PlaceholderText = $"Leave a review comment on {(side == DiffLineSide.Old ? "old " : "")}line {lineNumber}…",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 56,
        };
        AutomationProperties.SetAutomationId(input, $"coding.diff.composer.{lineNumber}");

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(Quiet("Cancel", () => { _composingAt = null; Render(); }));
        buttons.Children.Add(Push("Add Comment", () =>
        {
            if (_comments.Add(_file.Path, side, lineNumber, input.Text) != null)
            {
                _composingAt = null;
                Render();
            }
        }, accent: true));

        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(input);
        stack.Children.Add(buttons);
        var box = Card(stack, 10);
        box.Margin = new Thickness(32, 4, 8, 6);
        return box;
    }

    private FrameworkElement CommentCard(DiffComment comment)
    {
        var stack = new StackPanel { Spacing = 6 };
        var head = new Grid { ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var label = $"{comment.Author} · {(comment.Side == DiffLineSide.Old ? "old " : "")}line {comment.LineNumber}" + (comment.Resolved ? " · Resolved" : "");
        head.Children.Add(Text(label, 12, bold: true, color: comment.Resolved ? Tertiary : Secondary));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        actions.Children.Add(Quiet(comment.Resolved ? "Reopen" : "Resolve", () => { _comments.SetResolved(comment.Id, !comment.Resolved); Render(); }));
        actions.Children.Add(Quiet("Edit", () => { _editingCommentId = _editingCommentId == comment.Id ? null : comment.Id; Render(); }));
        var del = Quiet("Delete", () => { _comments.Delete(comment.Id); Render(); });
        del.Foreground = Critical;
        actions.Children.Add(del);
        Grid.SetColumn(actions, 1);
        head.Children.Add(actions);
        stack.Children.Add(head);

        if (_editingCommentId == comment.Id)
        {
            var editor = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Text = comment.Body, MinHeight = 48 };
            var editButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
            editButtons.Children.Add(Quiet("Cancel", () => { _editingCommentId = null; Render(); }));
            editButtons.Children.Add(Push("Save", () =>
            {
                if (_comments.Edit(comment.Id, editor.Text)) _editingCommentId = null;
                Render();
            }, accent: true));
            stack.Children.Add(editor);
            stack.Children.Add(editButtons);
        }
        else
        {
            stack.Children.Add(Text(comment.Body, 13, color: comment.Resolved ? Tertiary : null));
        }

        var box = Card(stack, 10);
        box.Margin = new Thickness(32, 3, 8, 4);
        if (comment.Resolved) box.Opacity = 0.72;
        return box;
    }
}
