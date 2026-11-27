using System.Text;
using Hermes.Core.Terminal;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VirtualKey = Windows.System.VirtualKey;

namespace HermesHQ.Features.Workspace;

/// One tab's screen: a text grid drawn from a `TerminalScreen` (the Mac's SwiftTerm view, a native terminal, not a web
/// page). Each row is a line of runs in the chosen monospaced face over its cells' backgrounds; a steady block cursor
/// (as Terminal.app's default) in the app's accent; a click-drag selects; the wheel goes back through the scrollback.
/// Keys go to the shell as xterm sends them; Ctrl+Shift+C / Ctrl+C with a selection copies, Ctrl+V / Ctrl+Shift+V
/// pastes (Windows Terminal's keys, for the Mac's ⌘C / ⌘V).
internal sealed class TerminalView : UserControl
{
    public TerminalScreen Screen { get; } = new(80, 24);
    /// What typed keys send.
    public event Action<byte[]>? Typed;
    /// The page asked to paste (Ctrl+V).
    public event Action? PasteRequested;
    /// The grid's size in cells changed.
    public event Action<int, int>? CellsChanged;
    public event Action<string>? Copied;

    private readonly Grid _root = new();
    private readonly Canvas _canvas = new();
    private readonly Rectangle _cursor = new();
    private readonly List<(Canvas Back, TextBlock Text)> _rows = [];
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _timer;
    private long _drawn = -1;
    private int _scroll;   // lines back from the bottom
    private double _cellW = 8, _cellH = 17;
    private string _family = TerminalSettings.Family(TerminalSettings.Face.System);
    private double _size = TerminalSettings.DefaultSize;
    private (int X, int Y)? _selStart, _selEnd;   // in TotalLines coordinates
    private char? _high;
    private bool _dirty = true;

    public static readonly SolidColorBrush Panel = Brush(TerminalColors.Background);

    public TerminalView()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        Background = Panel;
        Content = _root;
        _root.Background = Panel;
        _root.Padding = new Thickness(12, 10, 12, 10);   // Terminal's margin all round (macpass-tools 2026-11-14)
        _root.Children.Add(_canvas);
        _cursor.Fill = W.Res<Brush>("AccentFillColorDefaultBrush");
        _cursor.Opacity = 0.85;
        AutomationProperties.SetAutomationId(this, "terminal.screen");
        AutomationProperties.SetName(this, "Terminal");
        _root.SizeChanged += (_, _) => Fit();
        PreviewKeyDown += OnKey;
        CharacterReceived += OnCharacter;
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += (_, e) => ReleasePointerCaptures();
        PointerWheelChanged += OnWheel;
        _timer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(16);
        _timer.Tick += (_, _) => { if (_dirty || Screen.Version != _drawn) Draw(); };
        Loaded += (_, _) => _timer.Start();
        Unloaded += (_, _) => _timer.Stop();
        Screen.Copied += text => Copied?.Invoke(text);
        Measure0();
    }

    private static SolidColorBrush Brush(int rgb) =>
        new(Windows.UI.Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));

    private readonly Dictionary<int, SolidColorBrush> _brushes = [];
    private SolidColorBrush Cached(int rgb) => _brushes.TryGetValue(rgb, out var b) ? b : _brushes[rgb] = Brush(rgb);

    /// The face and size (⋯ › Text Size, ⋯ › Font), for every tab alike.
    public void SetFont(string family, double size)
    {
        _family = family;
        _size = size;
        Measure0();
        foreach (var (_, text) in _rows) { text.FontFamily = new FontFamily(family); text.FontSize = size; }
        Fit();
        _dirty = true;
    }

    /// One cell's size in the face, measured on a probe of 40 characters.
    private void Measure0()
    {
        var probe = new TextBlock { Text = new string('M', 40), FontFamily = new FontFamily(_family), FontSize = _size };
        probe.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        if (probe.DesiredSize.Width > 0) _cellW = probe.DesiredSize.Width / 40;
        if (probe.DesiredSize.Height > 0) _cellH = Math.Ceiling(probe.DesiredSize.Height);
        _cursor.Width = _cellW;
        _cursor.Height = _cellH;
    }

    public (int Cols, int Rows) Cells => (Screen.Cols, Screen.Rows);

    private void Fit()
    {
        var width = _root.ActualWidth - _root.Padding.Left - _root.Padding.Right;
        var height = _root.ActualHeight - _root.Padding.Top - _root.Padding.Bottom;
        if (width <= 0 || height <= 0) return;
        var cols = Math.Max(10, (int)(width / _cellW));
        var rows = Math.Max(3, (int)(height / _cellH));
        if (cols == Screen.Cols && rows == Screen.Rows && _rows.Count == rows) return;
        Screen.Resize(cols, rows);
        while (_rows.Count < rows)
        {
            var back = new Canvas();
            var text = new TextBlock { FontFamily = new FontFamily(_family), FontSize = _size, Foreground = Brush(TerminalColors.Foreground), TextWrapping = TextWrapping.NoWrap, IsHitTestVisible = false };
            _canvas.Children.Add(back);
            _canvas.Children.Add(text);
            _rows.Add((back, text));
        }
        while (_rows.Count > rows)
        {
            var (back, text) = _rows[^1];
            _canvas.Children.Remove(back);
            _canvas.Children.Remove(text);
            _rows.RemoveAt(_rows.Count - 1);
        }
        _dirty = true;
        CellsChanged?.Invoke(cols, rows);
    }

    // MARK: Drawing

    private void Draw()
    {
        _dirty = false;
        _drawn = Screen.Version;
        var total = Screen.TotalLines;
        _scroll = Math.Clamp(_scroll, 0, total - Screen.Rows);
        var first = total - Screen.Rows - _scroll;
        var selection = Selection();
        for (var y = 0; y < _rows.Count && y < Screen.Rows; y++)
        {
            var (back, text) = _rows[y];
            Canvas.SetTop(back, y * _cellH);
            Canvas.SetTop(text, y * _cellH);
            back.Children.Clear();
            text.Inlines.Clear();
            var index = first + y;
            if (index < 0 || index >= total) continue;
            var line = Screen.LineAt(index);
            var run = new StringBuilder();
            CellStyle? runStyle = null;
            void Flush()
            {
                if (run.Length == 0 || runStyle is not { } s) return;
                var (fg, _) = TerminalColors.Resolve(s);
                var r = new Run { Text = run.ToString(), Foreground = Cached(fg) };
                if (s.Has(CellStyle.Attr.Bold)) r.FontWeight = FontWeights.Bold;
                if (s.Has(CellStyle.Attr.Italic)) r.FontStyle = Windows.UI.Text.FontStyle.Italic;
                if (s.Has(CellStyle.Attr.Underline)) r.TextDecorations = Windows.UI.Text.TextDecorations.Underline;
                if (s.Has(CellStyle.Attr.Strike)) r.TextDecorations |= Windows.UI.Text.TextDecorations.Strikethrough;
                text.Inlines.Add(r);
                run.Clear();
            }
            for (var x = 0; x < line.Length; x++)
            {
                var cell = line[x];
                var (_, bg) = TerminalColors.Resolve(cell.Style);
                var selected = selection is var (a, b) && Inside((x, index), a, b);
                if (bg != TerminalColors.Background || selected)
                {
                    var rect = new Rectangle
                    {
                        Width = _cellW + 0.5, Height = _cellH,
                        Fill = selected ? W.Res<Brush>("AccentFillColorSecondaryBrush") : Cached(bg),
                        Opacity = selected ? 0.55 : 1,
                    };
                    Canvas.SetLeft(rect, x * _cellW);
                    back.Children.Add(rect);
                }
                if (cell.Text.Length == 0) continue;   // the right half of a wide character
                if (runStyle != cell.Style) { Flush(); runStyle = cell.Style; }
                run.Append(cell.Text);
            }
            Flush();
        }
        // The cursor, on the live screen only.
        _canvas.Children.Remove(_cursor);
        if (Screen.CursorVisible && _scroll == 0 && FocusState != FocusState.Unfocused)
        {
            Canvas.SetLeft(_cursor, Screen.CursorX * _cellW);
            Canvas.SetTop(_cursor, Screen.CursorY * _cellH);
            _canvas.Children.Insert(0, _cursor);
        }
    }

    protected override void OnGotFocus(RoutedEventArgs e) { base.OnGotFocus(e); _dirty = true; }
    protected override void OnLostFocus(RoutedEventArgs e) { base.OnLostFocus(e); _dirty = true; }

    // MARK: Selecting

    private ((int X, int Y) A, (int X, int Y) B)? Selection()
    {
        if (_selStart is not { } s || _selEnd is not { } e || s == e) return null;
        return (s.Y < e.Y || (s.Y == e.Y && s.X <= e.X)) ? (s, e) : (e, s);
    }

    private static bool Inside((int X, int Y) p, (int X, int Y) a, (int X, int Y) b) =>
        (p.Y > a.Y || (p.Y == a.Y && p.X >= a.X)) && (p.Y < b.Y || (p.Y == b.Y && p.X < b.X));

    private (int X, int Y) CellAt(Windows.Foundation.Point point)
    {
        var x = Math.Clamp((int)((point.X - _root.Padding.Left) / _cellW), 0, Screen.Cols);
        var y = Math.Clamp((int)((point.Y - _root.Padding.Top) / _cellH), 0, Screen.Rows - 1);
        return (x, Screen.TotalLines - Screen.Rows - _scroll + y);
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        Focus(FocusState.Pointer);
        var point = e.GetCurrentPoint(this);
        if (!point.Properties.IsLeftButtonPressed) return;
        CapturePointer(e.Pointer);
        _selStart = _selEnd = CellAt(point.Position);
        _dirty = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        if (!point.Properties.IsLeftButtonPressed || _selStart == null) return;
        _selEnd = CellAt(point.Position);
        _dirty = true;
    }

    /// The selected text, rows joined with line breaks; null without a selection.
    public string? SelectedText
    {
        get
        {
            if (Selection() is not var (a, b)) return null;
            var lines = new List<string>();
            for (var y = a.Y; y <= b.Y && y < Screen.TotalLines; y++)
            {
                var line = Screen.LineAt(y);
                int from = y == a.Y ? a.X : 0, to = y == b.Y ? b.X : line.Length;
                lines.Add(string.Concat(line.Skip(from).Take(Math.Max(0, to - from)).Select(c => c.Text)).TrimEnd(' '));
            }
            return string.Join("\n", lines);
        }
    }

    public void ClearSelection()
    {
        _selStart = _selEnd = null;
        _dirty = true;
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var delta = e.GetCurrentPoint(this).Properties.MouseWheelDelta;
        _scroll = Math.Clamp(_scroll + delta / 40, 0, Math.Max(0, Screen.TotalLines - Screen.Rows));
        _dirty = true;
        e.Handled = true;
    }

    /// Clears everything shown (a socket that starts over from what the computer kept, New Shell).
    public void Clear()
    {
        Screen.Clear();
        _scroll = 0;
        ClearSelection();
    }

    // MARK: Keys

    private void Send(byte[] data)
    {
        if (data.Length == 0) return;
        if (_scroll != 0) { _scroll = 0; _dirty = true; }
        if (_selStart != null) ClearSelection();
        Typed?.Invoke(data);
    }

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        bool ctrl = Down(VirtualKey.Control), shift = Down(VirtualKey.Shift), alt = Down(VirtualKey.Menu);
        var app = Screen.AppCursorKeys;
        TerminalKeys.Key? key = e.Key switch
        {
            VirtualKey.Up => TerminalKeys.Key.Up,
            VirtualKey.Down => TerminalKeys.Key.Down,
            VirtualKey.Left => TerminalKeys.Key.Left,
            VirtualKey.Right => TerminalKeys.Key.Right,
            VirtualKey.Home => TerminalKeys.Key.Home,
            VirtualKey.End => TerminalKeys.Key.End,
            VirtualKey.PageUp => TerminalKeys.Key.PageUp,
            VirtualKey.PageDown => TerminalKeys.Key.PageDown,
            VirtualKey.Insert => TerminalKeys.Key.Insert,
            VirtualKey.Delete => TerminalKeys.Key.Delete,
            VirtualKey.Back => TerminalKeys.Key.Backspace,
            VirtualKey.Tab => TerminalKeys.Key.Tab,
            VirtualKey.Enter => TerminalKeys.Key.Enter,
            VirtualKey.Escape => TerminalKeys.Key.Escape,
            >= VirtualKey.F1 and <= VirtualKey.F12 => TerminalKeys.Key.F1 + (e.Key - VirtualKey.F1),
            _ => null,
        };
        // Shift+PageUp / PageDown go through the scrollback, as in Windows Terminal.
        if (shift && key is TerminalKeys.Key.PageUp or TerminalKeys.Key.PageDown)
        {
            _scroll = Math.Clamp(_scroll + (key == TerminalKeys.Key.PageUp ? 1 : -1) * (Screen.Rows - 1), 0, Math.Max(0, Screen.TotalLines - Screen.Rows));
            _dirty = true;
            e.Handled = true;
            return;
        }
        if (key is { } k)
        {
            Send(TerminalKeys.Encode(k, shift, ctrl, alt, app));
            e.Handled = true;
            return;
        }
        if (ctrl && !alt)
        {
            if (e.Key == VirtualKey.C && (shift || SelectedText != null))
            {
                if (SelectedText is { } text) { CopySelection(text); ClearSelection(); }
                e.Handled = true;
                return;
            }
            if (e.Key == VirtualKey.V)
            {
                PasteRequested?.Invoke();
                e.Handled = true;
                return;
            }
            var ch = KeyChar(e.Key, shift);
            if (ch != null && TerminalKeys.Control(ch.Value) is { } b)
            {
                Send([b]);
                e.Handled = true;
            }
        }
    }

    private void CopySelection(string text) { Features.Attachments.MediaActions.CopyText(text); Copied?.Invoke(text); }

    /// The character a key stands for under Ctrl (letters, and the punctuation Ctrl means something for).
    private static char? KeyChar(VirtualKey key, bool shift) => key switch
    {
        >= VirtualKey.A and <= VirtualKey.Z => (char)('a' + (key - VirtualKey.A)),
        VirtualKey.Space => ' ',
        (VirtualKey)219 => '[',   // OEM 4
        (VirtualKey)220 => '\\',  // OEM 5
        (VirtualKey)221 => ']',   // OEM 6
        (VirtualKey)191 => shift ? '?' : '/',
        (VirtualKey)189 => '_',
        VirtualKey.Number2 => '@',
        VirtualKey.Number6 => '^',
        _ => null,
    };

    private void OnCharacter(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        var c = e.Character;
        if (c < ' ' || c == '\x7f') return;                  // Enter, Tab, Backspace and Ctrl keys went through OnKey
        if (Down(VirtualKey.Control) && !Down(VirtualKey.Menu)) return;
        e.Handled = true;
        if (char.IsHighSurrogate(c)) { _high = c; return; }
        var text = char.IsLowSurrogate(c) && _high is { } hi ? new string([hi, c]) : c.ToString();
        _high = null;
        Send(Encoding.UTF8.GetBytes(text));
    }
}
