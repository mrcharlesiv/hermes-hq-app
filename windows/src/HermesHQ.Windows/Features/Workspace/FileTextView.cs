using HermesHQ.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Workspace;

/// A file's text or a change's diff beside the table (MoreWorkspaceTextPage and the chat's WorkspaceTextPage): its
/// bar (✕ Close File, the file's name, Save As…), "Showing the first 512 KB of 2.5 MB." under it when only the start is
/// shown, then the text: monospaced and selectable, a diff's added lines washed green, removed ones red, its hunk heads
/// blue and its file heads grey. A Markdown file reads formatted, with Preview | Source.
internal sealed class FileTextView : Grid
{
    /// Bounded: a huge file shows its first 400,000 characters (Save As… hands over the whole file).
    private const int Shown = 400_000;
    private readonly bool _diff;
    private readonly ContentControl _body = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Button? _save;
    private string? _text;
    private bool _preview = true;
    private readonly bool _markdown;

    public FileTextView(string title, string? text, bool diff, string? notice, bool markdown, Func<Task>? save, Action close)
    {
        _diff = diff;
        _markdown = markdown;
        AutomationProperties.SetAutomationId(this, diff ? "more.review.diff" : "more.files.text");
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var bar = new Grid { Padding = new Thickness(8, 4, 8, 4) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var closeButton = W.BarButton("", "Close File", "workspace.file.close");
        closeButton.Click += (_, _) => close();
        bar.Children.Add(closeButton);
        var name = W.Text(title, 14, bold: true);
        name.HorizontalAlignment = HorizontalAlignment.Center;
        name.Margin = new Thickness(8, 0, 8, 0);
        Grid.SetColumn(name, 1);
        bar.Children.Add(name);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        if (markdown)
        {
            var preview = new ToggleButton { Content = "Preview", IsChecked = true, Padding = new Thickness(10, 3, 10, 3), FontSize = 12 };
            var source = new ToggleButton { Content = "Source", IsChecked = false, Padding = new Thickness(10, 3, 10, 3), FontSize = 12 };
            preview.Click += (_, _) => { _preview = true; preview.IsChecked = true; source.IsChecked = false; Draw(); };
            source.Click += (_, _) => { _preview = false; preview.IsChecked = false; source.IsChecked = true; Draw(); };
            tools.Children.Add(preview);
            tools.Children.Add(source);
        }
        if (save != null)
        {
            _save = W.BarButton("", "Save As…", "workspace.share");
            _save.Click += async (_, _) =>
            {
                _save.IsEnabled = false;
                try { await save(); }
                catch (Exception x) { await W.AskAsync(XamlRoot, "Couldn’t Save This File", x.Message); }
                finally { _save.IsEnabled = true; }
            };
            tools.Children.Add(_save);
        }
        Grid.SetColumn(tools, 2);
        bar.Children.Add(tools);
        bar.BorderBrush = W.Res<Brush>("CardStrokeColorDefaultBrush");
        bar.BorderThickness = new Thickness(0, 0, 0, 1);
        Children.Add(bar);

        if (notice != null)
        {
            var band = new Border
            {
                Background = W.Res<Brush>("LayerFillColorAltBrush"), Padding = new Thickness(16, 10, 16, 10),
                BorderBrush = W.Res<Brush>("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 0, 0, 1),
                Child = W.Text(notice, 12, W.Secondary, wrap: true),
            };
            AutomationProperties.SetAutomationId(band, "workspace.truncated");
            Grid.SetRow(band, 1);
            Children.Add(band);
        }
        Grid.SetRow(_body, 2);
        Children.Add(_body);
        if (text != null) SetText(text); else _body.Content = W.Loading();
    }

    public void SetText(string text)
    {
        _text = text;
        Draw();
    }

    public void Failed(string reason) =>
        _body.Content = W.State("exclamationmark.triangle", "Couldn’t Open", reason, id: "workspace.text.failed");

    private void Draw()
    {
        if (_text is not { } text) return;
        if (_markdown && _preview)
        {
            var stack = new StackPanel { Spacing = 6, Padding = new Thickness(20, 16, 20, 24) };
            MarkdownRenderer.Render(text, stack);
            _body.Content = new ScrollViewer { Content = stack };
            return;
        }
        var shown = text.Length > Shown ? text[..Shown] + "\n…" : text;
        if (!_diff)
        {
            var block = new TextBlock
            {
                Text = shown, FontFamily = W.Mono, FontSize = 13, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.NoWrap,
                Padding = new Thickness(16, 12, 16, 24),
            };
            AutomationProperties.SetAutomationId(block, "workspace.text");
            _body.Content = new ScrollViewer
            {
                Content = block, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Auto,
            };
            return;
        }
        // A diff: one row per line, washed by what it is (virtualised, for a 2,000-line diff).
        var list = new ItemsRepeater { Layout = new StackLayout() };
        var lines = shown.Split('\n');
        var green = Wash(0x2E, 0xA0, 0x43);
        var red = Wash(0xE5, 0x48, 0x4D);
        list.ItemsSource = lines;
        list.ItemTemplate = new LineFactory(line =>
        {
            Brush? background = null;
            Brush? color = null;
            if (line.StartsWith("+++") || line.StartsWith("---")) color = W.Secondary;
            else if (line.StartsWith('+')) background = green;
            else if (line.StartsWith('-')) background = red;
            else if (line.StartsWith("@@")) color = W.Res<Brush>("AccentTextFillColorPrimaryBrush");
            var block = new TextBlock { Text = line.Length == 0 ? " " : line, FontFamily = W.Mono, FontSize = 13, IsTextSelectionEnabled = true };
            if (color != null) block.Foreground = color;
            return new Border
            {
                Background = background, Padding = new Thickness(16, 0, 16, 0),
                Child = block,
            };
        });
        AutomationProperties.SetAutomationId(list, "workspace.diff");
        _body.Content = new ScrollViewer
        {
            Content = new Border { Padding = new Thickness(0, 12, 0, 24), Child = list },
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Auto,
        };
    }

    private static SolidColorBrush Wash(byte r, byte g, byte b) => new(Windows.UI.Color.FromArgb(38, r, g, b));

    /// Makes one row per diff line.
    private sealed class LineFactory(Func<string, UIElement> make) : IElementFactory
    {
        public UIElement GetElement(ElementFactoryGetArgs args) => make(args.Data as string ?? "");
        public void RecycleElement(ElementFactoryRecycleArgs args) { }
    }
}
