using Hermes.Core.Voice;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Windows.UI.Text;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/LiveWordsView.swift: italic live transcript strip shown above the
/// recorder bar, dictation row, or Talk dock. Settled words render in primary text, up to two
/// trailing tentative words render in secondary text, and review mode supports click-to-edit.
public sealed class LiveWordsView : UserControl
{
    private readonly TextBlock _display;
    private readonly TextBox _editor;
    private bool _editable;
    private bool _editing;
    private LiveWordsText _last = LiveWordsText.Empty;

    public event Action<string>? WordsEdited;

    public LiveWordsView(int maxLines = 2)
    {
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, "voice.liveWords");

        _display = new TextBlock
        {
            FontSize = 13,
            FontStyle = FontStyle.Italic,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = Math.Max(1, maxLines),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _display.PointerPressed += OnDisplayPressed;

        _editor = new TextBox
        {
            FontSize = 13,
            AcceptsReturn = false,
            TextWrapping = TextWrapping.Wrap,
            PlaceholderText = "Edit transcript…",
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_editor, "voice.liveWords.editor");
        _editor.TextChanged += (_, _) =>
        {
            if (_editing) WordsEdited?.Invoke(_editor.Text);
        };
        _editor.LostFocus += (_, _) => ExitEdit();

        var grid = new Grid();
        grid.Children.Add(_display);
        grid.Children.Add(_editor);
        Content = new Border
        {
            Padding = new Thickness(10, 4, 10, 4),
            CornerRadius = new CornerRadius(8),
            Child = grid,
        };
    }

    public bool IsEditable
    {
        get => _editable;
        set
        {
            _editable = value;
            if (!value && _editing) ExitEdit();
            ToolTipService.SetToolTip(this, value ? "Click to edit transcript" : null);
        }
    }

    public void Update(LiveWordsText text, bool showWhenEmpty = false)
    {
        _last = text;
        if (_editing) return;
        if (!showWhenEmpty && text.IsEmpty)
        {
            Visibility = Visibility.Collapsed;
            return;
        }
        Visibility = Visibility.Visible;
        RenderRun(LiveWordsDisplay.Format(text));
    }

    public void UpdatePlain(string? text, bool editable = false)
    {
        IsEditable = editable;
        var clean = text?.Trim() ?? "";
        _last = new LiveWordsText(clean, "");
        if (_editing) return;
        if (clean.Length == 0)
        {
            Visibility = Visibility.Collapsed;
            return;
        }
        Visibility = Visibility.Visible;
        RenderRun(LiveWordsDisplay.Format(_last));
    }

    public void Reset()
    {
        _editing = false;
        _editable = false;
        _last = LiveWordsText.Empty;
        _editor.Visibility = Visibility.Collapsed;
        _display.Visibility = Visibility.Visible;
        _display.Inlines.Clear();
        Visibility = Visibility.Collapsed;
    }

    private void RenderRun(LiveWordsRun run)
    {
        _display.Inlines.Clear();
        if (run.IsPlaceholder)
        {
            _display.Inlines.Add(new Run
            {
                Text = run.Secondary,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            });
            return;
        }
        if (run.Primary.Length > 0)
        {
            _display.Inlines.Add(new Run
            {
                Text = run.Primary,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            });
        }
        if (run.Secondary.Length > 0)
        {
            _display.Inlines.Add(new Run
            {
                Text = run.Primary.Length > 0 ? " " + run.Secondary : run.Secondary,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
        }
    }

    private void OnDisplayPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!_editable || _editing) return;
        _editing = true;
        _editor.Text = _last.Text;
        _editor.SelectionStart = _editor.Text.Length;
        _display.Visibility = Visibility.Collapsed;
        _editor.Visibility = Visibility.Visible;
        _editor.Focus(FocusState.Programmatic);
    }

    private void ExitEdit()
    {
        if (!_editing) return;
        _editing = false;
        _last = new LiveWordsText(_editor.Text.Trim(), "");
        _editor.Visibility = Visibility.Collapsed;
        _display.Visibility = Visibility.Visible;
        if (_last.IsEmpty) Visibility = Visibility.Collapsed;
        else RenderRun(LiveWordsDisplay.Format(_last));
    }
}
