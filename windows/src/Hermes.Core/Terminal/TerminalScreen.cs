using System.Globalization;
using System.Text;

namespace Hermes.Core.Terminal;

/// One cell's look. Colours: -1 is the default; 0–255 the xterm palette; 0x1RRGGBB a 24-bit colour.
public readonly record struct CellStyle(int Fg = -1, int Bg = -1, CellStyle.Attr Flags = CellStyle.Attr.None)
{
    [Flags]
    public enum Attr : ushort { None = 0, Bold = 1, Dim = 2, Italic = 4, Underline = 8, Inverse = 16, Hidden = 32, Strike = 64 }

    public static readonly CellStyle Plain = new(-1, -1, Attr.None);
    public bool Has(Attr a) => (Flags & a) != 0;
    public static int Rgb(int r, int g, int b) => 0x1000000 | (r << 16) | (g << 8) | b;
}

/// One character cell: its text ("" for the right half of a wide character, " " when blank) and look.
public struct Cell
{
    public string Text;
    public CellStyle Style;
    public static Cell Blank(CellStyle style) => new() { Text = " ", Style = style with { Flags = CellStyle.Attr.None } };
}

/// A terminal's screen and scrollback, fed with what the shell prints (the job SwiftTerm's `Terminal` does for the Mac's
/// TerminalViewController). An xterm subset: UTF-8, C0 controls, ESC and CSI cursor movement, erasing, inserting and
/// deleting, scroll regions, SGR colours (16, 256 and 24-bit), the alternate screen, bracketed paste, application
/// cursor keys, cursor visibility, window titles (OSC 0/2) and copies from programs (OSC 52). Not thread-safe: the page
/// feeds and reads it on its UI thread.
public sealed class TerminalScreen
{
    public const int MaxScrollback = 5000;

    public int Cols { get; private set; }
    public int Rows { get; private set; }
    public int CursorX { get; private set; }
    public int CursorY { get; private set; }
    public bool CursorVisible { get; private set; } = true;
    public bool BracketedPaste { get; private set; }
    public bool AppCursorKeys { get; private set; }
    public bool AltScreen => _alt != null;
    /// The title the program set (OSC 0 / 2), "" until one does.
    public string Title { get; private set; } = "";
    /// Lines that scrolled off the top of the main screen, oldest first.
    public IReadOnlyList<Cell[]> Scrollback => _scrollback;
    /// Bumped on every change, so a view knows to draw again.
    public long Version { get; private set; }

    /// Bytes the terminal answers with (cursor position reports, device attributes): the page sends them to the shell.
    public event Action<byte[]>? Respond;
    public event Action<string>? TitleChanged;
    /// A program copied text (OSC 52, as tmux and vim do).
    public event Action<string>? Copied;
    public event Action? Bell;

    private Cell[][] _lines;
    private Cell[][]? _alt;          // the main screen while the alternate one is up
    private readonly List<Cell[]> _scrollback = [];
    private CellStyle _style = CellStyle.Plain;
    private int _top, _bottom;       // the scroll region, inclusive
    private bool _wrapPending, _autoWrap = true, _origin, _insert;
    private (int X, int Y, CellStyle Style, bool Origin)? _saved;
    private (int X, int Y, CellStyle Style, bool Origin)? _savedAlt;
    private readonly Decoder _utf8 = new UTF8Encoding(false).GetDecoder();
    private bool[] _tabs = [];

    // Parser state
    private enum S { Ground, Esc, EscInter, Csi, Osc, OscEsc, Str, StrEsc, Charset }
    private S _s = S.Ground;
    private readonly StringBuilder _params = new();
    private char _private;
    private readonly StringBuilder _inter = new();
    private readonly StringBuilder _osc = new();
    private char? _highSurrogate;

    public TerminalScreen(int cols = 80, int rows = 24)
    {
        Cols = Math.Max(2, cols);
        Rows = Math.Max(1, rows);
        _lines = NewLines(Rows, Cols);
        _bottom = Rows - 1;
        ResetTabs();
    }

    private Cell[] NewLine(int cols, CellStyle? style = null)
    {
        var line = new Cell[cols];
        var blank = Cell.Blank(style ?? CellStyle.Plain);
        Array.Fill(line, blank);
        return line;
    }

    private Cell[][] NewLines(int rows, int cols) => [.. Enumerable.Range(0, rows).Select(_ => NewLine(cols))];

    private void ResetTabs()
    {
        _tabs = new bool[Cols];
        for (var i = 8; i < Cols; i += 8) _tabs[i] = true;
    }

    /// The visible row `y` (0 = top).
    public Cell[] Line(int y) => _lines[y];

    /// Row `index` of scrollback then screen (0 = the oldest scrollback line). The alternate screen has no scrollback.
    public int TotalLines => (AltScreen ? 0 : _scrollback.Count) + Rows;
    public Cell[] LineAt(int index)
    {
        var back = AltScreen ? 0 : _scrollback.Count;
        return index < back ? _scrollback[index] : _lines[index - back];
    }

    // MARK: Feeding

    public void Feed(byte[] data) => Feed(data.AsSpan());

    public void Feed(ReadOnlySpan<byte> data)
    {
        var chars = new char[_utf8.GetCharCount(data, flush: false)];
        var n = _utf8.GetChars(data, chars, flush: false);
        Feed(chars.AsSpan(0, n));
    }

    public void Feed(string text) => Feed(text.AsSpan());

    private void Feed(ReadOnlySpan<char> chars)
    {
        foreach (var c in chars) Step(c);
        Version++;
    }

    private void Step(char c)
    {
        switch (_s)
        {
            case S.Ground:
                if (c == '\x1b') { _s = S.Esc; return; }
                if (c < 0x20 || c == 0x7f) { Control(c); return; }
                if (char.IsHighSurrogate(c)) { _highSurrogate = c; return; }
                if (char.IsLowSurrogate(c) && _highSurrogate is { } hi) { _highSurrogate = null; Print(new string([hi, c])); return; }
                _highSurrogate = null;
                Print(c.ToString());
                return;
            case S.Esc:
                Escape(c);
                return;
            case S.EscInter:
                // ESC ( B and friends: the character set is always UTF-8 here.
                _s = S.Ground;
                return;
            case S.Charset:
                _s = S.Ground;
                return;
            case S.Csi:
                if (c == '\x1b') { _s = S.Esc; return; }
                if (c is >= '0' and <= '9' or ';' or ':') { _params.Append(c); return; }
                if (c is '?' or '>' or '<' or '=') { _private = c; return; }
                if (c is >= ' ' and <= '/') { _inter.Append(c); return; }
                if (c < 0x20) { Control(c); return; }
                _s = S.Ground;
                Csi(c);
                return;
            case S.Osc:
                if (c == '\a') { _s = S.Ground; Osc(); return; }
                if (c == '\x1b') { _s = S.OscEsc; return; }
                if (_osc.Length < 1 << 20) _osc.Append(c);
                return;
            case S.OscEsc:
                _s = S.Ground;
                Osc();
                if (c != '\\') Step(c);
                return;
            case S.Str:
                if (c == '\x1b') _s = S.StrEsc;
                else if (c == '\a') _s = S.Ground;
                return;
            case S.StrEsc:
                _s = c == '\\' ? S.Ground : S.Str;
                return;
        }
    }

    private void Control(char c)
    {
        switch (c)
        {
            case '\a': Bell?.Invoke(); break;
            case '\b':
                _wrapPending = false;
                if (CursorX > 0) CursorX--;
                break;
            case '\t':
                _wrapPending = false;
                do CursorX++; while (CursorX < Cols - 1 && !_tabs[CursorX]);
                CursorX = Math.Min(CursorX, Cols - 1);
                break;
            case '\n' or '\v' or '\f': LineFeed(); break;
            case '\r': CursorX = 0; _wrapPending = false; break;
        }
    }

    private void Escape(char c)
    {
        _s = S.Ground;
        switch (c)
        {
            case '[': _s = S.Csi; _params.Clear(); _inter.Clear(); _private = '\0'; break;
            case ']': _s = S.Osc; _osc.Clear(); break;
            case 'P' or '_' or '^' or 'X': _s = S.Str; break;
            case '(' or ')' or '*' or '+' or '-' or '.' or '/': _s = S.Charset; break;
            case '#' or '%' or ' ': _s = S.EscInter; break;
            case '7': SaveCursor(); break;
            case '8': RestoreCursor(); break;
            case 'D': LineFeed(); break;
            case 'E': CursorX = 0; LineFeed(); break;
            case 'M': ReverseIndex(); break;
            case 'H': if (CursorX < Cols) _tabs[CursorX] = true; break;
            case 'c': FullReset(); break;
            case '=': AppCursorKeys = AppCursorKeys; break;   // keypad modes: the arrows follow DECCKM only
            case '\x1b': _s = S.Esc; break;
        }
    }

    private void FullReset()
    {
        if (_alt != null) { _lines = _alt; _alt = null; }
        _lines = NewLines(Rows, Cols);
        _scrollback.Clear();
        _style = CellStyle.Plain;
        CursorX = CursorY = 0;
        _top = 0; _bottom = Rows - 1;
        _wrapPending = false; _autoWrap = true; _origin = false; _insert = false;
        CursorVisible = true; BracketedPaste = false; AppCursorKeys = false;
        ResetTabs();
    }

    // MARK: Printing

    /// Display width of a character: 0 for combining marks, 2 for wide East Asian characters and emoji, else 1.
    public static int Width(string s)
    {
        if (s.Length == 0) return 0;
        var r = Rune.GetRuneAt(s, 0);
        var v = r.Value;
        if (v == 0x200D || (v >= 0xFE00 && v <= 0xFE0F)) return 0;
        var cat = Rune.GetUnicodeCategory(r);
        if (cat is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.Format) return 0;
        if ((v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF && v != 0x303F) || (v >= 0xAC00 && v <= 0xD7A3)
            || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0xFE30 && v <= 0xFE4F) || (v >= 0xFF00 && v <= 0xFF60)
            || (v >= 0xFFE0 && v <= 0xFFE6) || (v >= 0x1F300 && v <= 0x1F64F) || (v >= 0x1F900 && v <= 0x1F9FF)
            || (v >= 0x1F680 && v <= 0x1F6FF) || (v >= 0x20000 && v <= 0x3FFFD))
            return 2;
        return 1;
    }

    private void Print(string ch)
    {
        var w = Width(ch);
        if (w == 0)
        {
            // A combining mark joins the cell before the cursor.
            var x = _wrapPending ? CursorX : CursorX - 1;
            if (x >= 0)
            {
                var line = _lines[CursorY];
                if (line[x].Text.Length == 0 && x > 0) x--;
                line[x].Text += ch;
            }
            return;
        }
        if (_wrapPending)
        {
            _wrapPending = false;
            if (_autoWrap) { CursorX = 0; LineFeed(); }
        }
        if (w == 2 && CursorX == Cols - 1)
        {
            if (_autoWrap) { _lines[CursorY][CursorX] = Cell.Blank(_style); CursorX = 0; LineFeed(); }
            else return;
        }
        var row = _lines[CursorY];
        if (_insert)
        {
            Array.Copy(row, CursorX, row, CursorX + w, Cols - CursorX - w);
        }
        row[CursorX] = new Cell { Text = ch, Style = _style };
        if (w == 2) row[CursorX + 1] = new Cell { Text = "", Style = _style };
        if (CursorX + w >= Cols) { CursorX = Cols - 1; _wrapPending = true; }
        else CursorX += w;
    }

    private void LineFeed()
    {
        _wrapPending = false;
        if (CursorY == _bottom) ScrollUp(1);
        else if (CursorY < Rows - 1) CursorY++;
    }

    private void ReverseIndex()
    {
        _wrapPending = false;
        if (CursorY == _top) ScrollDown(1);
        else if (CursorY > 0) CursorY--;
    }

    private void ScrollUp(int n)
    {
        n = Math.Min(n, _bottom - _top + 1);
        for (var i = 0; i < n; i++)
        {
            var gone = _lines[_top];
            if (_top == 0 && _alt == null)
            {
                _scrollback.Add(gone);
                if (_scrollback.Count > MaxScrollback) _scrollback.RemoveAt(0);
            }
            Array.Copy(_lines, _top + 1, _lines, _top, _bottom - _top);
            _lines[_bottom] = NewLine(Cols, _style);
        }
    }

    private void ScrollDown(int n)
    {
        n = Math.Min(n, _bottom - _top + 1);
        for (var i = 0; i < n; i++)
        {
            Array.Copy(_lines, _top, _lines, _top + 1, _bottom - _top);
            _lines[_top] = NewLine(Cols, _style);
        }
    }

    // MARK: CSI

    private int[] Params(int defaultValue = 0)
    {
        if (_params.Length == 0) return [];
        return [.. _params.ToString().Split(';').Select(p =>
        {
            var head = p.Split(':')[0];
            return int.TryParse(head, out var v) ? v : defaultValue;
        })];
    }

    private static int P(int[] ps, int i, int fallback) => i < ps.Length && ps[i] > 0 ? ps[i] : fallback;

    private void Csi(char final)
    {
        var ps = Params();
        if (_inter.Length > 0)
        {
            // DECSCUSR (cursor shape, "CSI n SP q") and the like: nothing to draw differently.
            return;
        }
        if (_private == '?')
        {
            if (final is 'h' or 'l') foreach (var p in ps) PrivateMode(p, final == 'h');
            return;
        }
        if (_private is '>' or '=' or '<')
        {
            if (final == 'c' && _private == '>') Respond?.Invoke(Encoding.ASCII.GetBytes("\x1b[>0;10;1c"));
            return;
        }
        switch (final)
        {
            case 'A': MoveTo(CursorX, Math.Max(CursorY - P(ps, 0, 1), CursorY >= _top ? _top : 0)); break;
            case 'B' or 'e': MoveTo(CursorX, Math.Min(CursorY + P(ps, 0, 1), CursorY <= _bottom ? _bottom : Rows - 1)); break;
            case 'C' or 'a': MoveTo(CursorX + P(ps, 0, 1), CursorY); break;
            case 'D': MoveTo(CursorX - P(ps, 0, 1), CursorY); break;
            case 'E': MoveTo(0, Math.Min(CursorY + P(ps, 0, 1), _bottom)); break;
            case 'F': MoveTo(0, Math.Max(CursorY - P(ps, 0, 1), _top)); break;
            case 'G' or '`': MoveTo(P(ps, 0, 1) - 1, CursorY); break;
            case 'H' or 'f':
                {
                    var y = P(ps, 0, 1) - 1 + (_origin ? _top : 0);
                    MoveTo(P(ps, 1, 1) - 1, _origin ? Math.Min(y, _bottom) : y);
                    break;
                }
            case 'd': MoveTo(CursorX, P(ps, 0, 1) - 1 + (_origin ? _top : 0)); break;
            case 'J': EraseDisplay(ps.Length > 0 ? ps[0] : 0); break;
            case 'K': EraseLine(ps.Length > 0 ? ps[0] : 0); break;
            case 'X':
                {
                    var row = _lines[CursorY];
                    for (int i = CursorX, end = Math.Min(Cols, CursorX + P(ps, 0, 1)); i < end; i++) row[i] = Cell.Blank(_style);
                    _wrapPending = false;
                    break;
                }
            case '@':
                {
                    var n = Math.Min(P(ps, 0, 1), Cols - CursorX);
                    var row = _lines[CursorY];
                    Array.Copy(row, CursorX, row, CursorX + n, Cols - CursorX - n);
                    for (var i = 0; i < n; i++) row[CursorX + i] = Cell.Blank(_style);
                    break;
                }
            case 'P':
                {
                    var n = Math.Min(P(ps, 0, 1), Cols - CursorX);
                    var row = _lines[CursorY];
                    Array.Copy(row, CursorX + n, row, CursorX, Cols - CursorX - n);
                    for (var i = Cols - n; i < Cols; i++) row[i] = Cell.Blank(_style);
                    _wrapPending = false;
                    break;
                }
            case 'L':
                if (CursorY >= _top && CursorY <= _bottom)
                {
                    var keep = _top; _top = CursorY; ScrollDown(P(ps, 0, 1)); _top = keep;
                    CursorX = 0;
                }
                break;
            case 'M':
                if (CursorY >= _top && CursorY <= _bottom)
                {
                    var keep = _top; _top = CursorY;
                    // Deleted lines never go to the scrollback.
                    var n = Math.Min(P(ps, 0, 1), _bottom - _top + 1);
                    for (var i = 0; i < n; i++)
                    {
                        Array.Copy(_lines, _top + 1, _lines, _top, _bottom - _top);
                        _lines[_bottom] = NewLine(Cols, _style);
                    }
                    _top = keep;
                    CursorX = 0;
                }
                break;
            case 'S': ScrollUp(P(ps, 0, 1)); break;
            case 'T': ScrollDown(P(ps, 0, 1)); break;
            case 'm': Sgr(ps); break;
            case 'r':
                {
                    var top = P(ps, 0, 1) - 1;
                    var bottom = P(ps, 1, Rows) - 1;
                    if (bottom > Rows - 1) bottom = Rows - 1;
                    if (top < bottom)
                    {
                        _top = top; _bottom = bottom;
                        MoveTo(0, _origin ? _top : 0);
                    }
                    break;
                }
            case 's': SaveCursor(); break;
            case 'u': RestoreCursor(); break;
            case 'h' or 'l':
                foreach (var p in ps) if (p == 4) _insert = final == 'h';
                break;
            case 'n':
                if (P(ps, 0, 0) == 6)
                    Respond?.Invoke(Encoding.ASCII.GetBytes($"\x1b[{CursorY + 1 - (_origin ? _top : 0)};{CursorX + 1}R"));
                else if (P(ps, 0, 0) == 5) Respond?.Invoke(Encoding.ASCII.GetBytes("\x1b[0n"));
                break;
            case 'c':
                Respond?.Invoke(Encoding.ASCII.GetBytes("\x1b[?62;22c"));
                break;
            case 'g':
                if (P(ps, 0, 0) == 3) Array.Fill(_tabs, false);
                else if (CursorX < Cols) _tabs[CursorX] = false;
                break;
            case 'I':
                for (var i = 0; i < P(ps, 0, 1); i++) Control('\t');
                break;
            case 'Z':
                for (var i = 0; i < P(ps, 0, 1); i++)
                {
                    do CursorX--; while (CursorX > 0 && !_tabs[CursorX]);
                    CursorX = Math.Max(0, CursorX);
                }
                break;
        }
    }

    private void MoveTo(int x, int y)
    {
        CursorX = Math.Clamp(x, 0, Cols - 1);
        CursorY = Math.Clamp(y, 0, Rows - 1);
        _wrapPending = false;
    }

    private void SaveCursor()
    {
        var s = (CursorX, CursorY, _style, _origin);
        if (AltScreen) _savedAlt = s; else _saved = s;
    }

    private void RestoreCursor()
    {
        if ((AltScreen ? _savedAlt : _saved) is { } s)
        {
            _style = s.Style;
            _origin = s.Origin;
            MoveTo(s.X, s.Y);
        }
        else MoveTo(0, 0);
    }

    private void EraseDisplay(int mode)
    {
        switch (mode)
        {
            case 0:
                EraseLine(0);
                for (var y = CursorY + 1; y < Rows; y++) _lines[y] = NewLine(Cols, _style);
                break;
            case 1:
                EraseLine(1);
                for (var y = 0; y < CursorY; y++) _lines[y] = NewLine(Cols, _style);
                break;
            case 2:
                for (var y = 0; y < Rows; y++) _lines[y] = NewLine(Cols, _style);
                break;
            case 3:
                _scrollback.Clear();
                break;
        }
        _wrapPending = false;
    }

    private void EraseLine(int mode)
    {
        var row = _lines[CursorY];
        var (from, to) = mode switch { 0 => (CursorX, Cols), 1 => (0, CursorX + 1), _ => (0, Cols) };
        for (var i = from; i < Math.Min(to, Cols); i++) row[i] = Cell.Blank(_style);
        _wrapPending = false;
    }

    private void PrivateMode(int mode, bool on)
    {
        switch (mode)
        {
            case 1: AppCursorKeys = on; break;
            case 6: _origin = on; MoveTo(0, on ? _top : 0); break;
            case 7: _autoWrap = on; break;
            case 25: CursorVisible = on; break;
            case 2004: BracketedPaste = on; break;
            case 47 or 1047 or 1049:
                if (on && _alt == null)
                {
                    if (mode == 1049) SaveCursor();
                    _alt = _lines;
                    _lines = NewLines(Rows, Cols);
                    if (mode == 1049) { var s = _saved; _savedAlt = s; }
                }
                else if (!on && _alt != null)
                {
                    _lines = _alt;
                    _alt = null;
                    if (mode == 1049) RestoreCursor();
                }
                break;
        }
    }

    private void Sgr(int[] ps)
    {
        if (ps.Length == 0) { _style = CellStyle.Plain; return; }
        // Colon sub-parameters (38:2::r:g:b) arrive as the head only; the common semicolon forms are read in full.
        for (var i = 0; i < ps.Length; i++)
        {
            var p = ps[i];
            var f = _style.Flags;
            switch (p)
            {
                case 0: _style = CellStyle.Plain; continue;
                case 1: f |= CellStyle.Attr.Bold; break;
                case 2: f |= CellStyle.Attr.Dim; break;
                case 3: f |= CellStyle.Attr.Italic; break;
                case 4: f |= CellStyle.Attr.Underline; break;
                case 7: f |= CellStyle.Attr.Inverse; break;
                case 8: f |= CellStyle.Attr.Hidden; break;
                case 9: f |= CellStyle.Attr.Strike; break;
                case 21 or 22: f &= ~(CellStyle.Attr.Bold | CellStyle.Attr.Dim); break;
                case 23: f &= ~CellStyle.Attr.Italic; break;
                case 24: f &= ~CellStyle.Attr.Underline; break;
                case 27: f &= ~CellStyle.Attr.Inverse; break;
                case 28: f &= ~CellStyle.Attr.Hidden; break;
                case 29: f &= ~CellStyle.Attr.Strike; break;
                case >= 30 and <= 37: _style = _style with { Fg = p - 30 }; continue;
                case 39: _style = _style with { Fg = -1 }; continue;
                case >= 40 and <= 47: _style = _style with { Bg = p - 40 }; continue;
                case 49: _style = _style with { Bg = -1 }; continue;
                case >= 90 and <= 97: _style = _style with { Fg = p - 90 + 8 }; continue;
                case >= 100 and <= 107: _style = _style with { Bg = p - 100 + 8 }; continue;
                case 38 or 48:
                    {
                        int? color = null;
                        if (i + 2 < ps.Length && ps[i + 1] == 5) { color = Math.Clamp(ps[i + 2], 0, 255); i += 2; }
                        else if (i + 4 < ps.Length && ps[i + 1] == 2)
                        {
                            color = CellStyle.Rgb(Math.Clamp(ps[i + 2], 0, 255), Math.Clamp(ps[i + 3], 0, 255), Math.Clamp(ps[i + 4], 0, 255));
                            i += 4;
                        }
                        if (color is { } c) _style = p == 38 ? _style with { Fg = c } : _style with { Bg = c };
                        continue;
                    }
                default: continue;
            }
            _style = _style with { Flags = f };
        }
    }

    // MARK: OSC

    private void Osc()
    {
        var text = _osc.ToString();
        var semi = text.IndexOf(';');
        if (semi < 0) return;
        var code = text[..semi];
        var rest = text[(semi + 1)..];
        switch (code)
        {
            case "0" or "2":
                if (rest != Title) { Title = rest; TitleChanged?.Invoke(rest); }
                break;
            case "52":
                {
                    // OSC 52 ; <selection> ; <base64>  ("?" asks to read the clipboard: never answered).
                    var at = rest.IndexOf(';');
                    var data = at >= 0 ? rest[(at + 1)..] : rest;
                    if (data == "?" || data.Length == 0) break;
                    try { Copied?.Invoke(Encoding.UTF8.GetString(Convert.FromBase64String(data))); }
                    catch (FormatException) { }
                    break;
                }
        }
    }

    // MARK: Size

    /// The page's new size in cells: the screen keeps its text (cut or padded), the cursor stays on its line.
    public void Resize(int cols, int rows)
    {
        cols = Math.Max(2, cols);
        rows = Math.Max(1, rows);
        if (cols == Cols && rows == Rows) return;
        Cell[] Fit(Cell[] line)
        {
            if (line.Length == cols) return line;
            var o = NewLine(cols);
            Array.Copy(line, o, Math.Min(cols, line.Length));
            return o;
        }
        Cell[][] FitScreen(Cell[][] lines, bool main)
        {
            var list = lines.Select(Fit).ToList();
            var cursor = CursorY;
            while (list.Count > rows)
            {
                // Blank lines under the cursor go first, then lines leave from the top into the scrollback.
                if (list.Count - 1 > cursor && Text(list[^1]).Length == 0) list.RemoveAt(list.Count - 1);
                else { if (main) _scrollback.Add(list[0]); list.RemoveAt(0); cursor--; }
            }
            while (list.Count < rows)
            {
                if (main && _scrollback.Count > 0) { list.Insert(0, Fit(_scrollback[^1])); _scrollback.RemoveAt(_scrollback.Count - 1); cursor++; }
                else list.Add(NewLine(cols));
            }
            CursorY = Math.Clamp(cursor, 0, rows - 1);
            return [.. list];
        }
        if (_alt != null)
        {
            // The alternate screen (vim, less) is drawn again by its program at the new size; the main one waits under it.
            _alt = Pad([.. _alt.Select(Fit)], rows, cols);
            _lines = Pad([.. _lines.Select(Fit)], rows, cols);
            CursorY = Math.Clamp(CursorY, 0, rows - 1);
        }
        else _lines = FitScreen(_lines, main: true);
        while (_scrollback.Count > MaxScrollback) _scrollback.RemoveAt(0);
        Cols = cols;
        Rows = rows;
        CursorX = Math.Min(CursorX, cols - 1);
        _top = 0;
        _bottom = rows - 1;
        _wrapPending = false;
        ResetTabs();
        Version++;
    }

    private Cell[][] Pad(Cell[][] lines, int rows, int cols)
    {
        var list = lines.ToList();
        while (list.Count > rows) list.RemoveAt(list.Count - 1);
        while (list.Count < rows) list.Add(NewLine(cols));
        return [.. list];
    }

    /// Clears everything (a socket that starts over from what the computer kept).
    public void Clear()
    {
        FullReset();
        Version++;
    }

    // MARK: Text

    public static string Text(Cell[] line) => string.Concat(line.Select(c => c.Text)).TrimEnd(' ');

    /// The visible screen as plain text, rows joined with "\n", blank rows at the end left out.
    public string ScreenText() => Join(_lines);

    /// Everything the screen and its scrollback hold, as plain text, without the blank rows at the end (⋯ › Copy All).
    public string AllText() => Join(AltScreen ? _lines : [.. _scrollback, .. _lines]);

    private static string Join(IEnumerable<Cell[]> lines)
    {
        var texts = lines.Select(Text).ToList();
        while (texts.Count > 0 && texts[^1].Length == 0) texts.RemoveAt(texts.Count - 1);
        return string.Join("\n", texts);
    }
}
