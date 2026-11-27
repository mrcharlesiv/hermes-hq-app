using System.Text;

namespace Hermes.Core.Terminal;

/// What a key sends to the shell, as xterm encodes it (SwiftTerm's key handling for the Mac's real keyboard).
public static class TerminalKeys
{
    public enum Key { Up, Down, Right, Left, Home, End, PageUp, PageDown, Insert, Delete, Backspace, Tab, Enter, Escape, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12 }

    /// The bytes for `key`; `appCursor` is DECCKM (the arrows send ESC O A in vim and less).
    public static byte[] Encode(Key key, bool shift = false, bool ctrl = false, bool alt = false, bool appCursor = false)
    {
        var mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
        string Cursor(char c) => mod > 1 ? $"\x1b[1;{mod}{c}" : appCursor ? $"\x1bO{c}" : $"\x1b[{c}";
        string Tilde(int n) => mod > 1 ? $"\x1b[{n};{mod}~" : $"\x1b[{n}~";
        string Ss3(char c) => mod > 1 ? $"\x1b[1;{mod}{c}" : $"\x1bO{c}";
        var text = key switch
        {
            Key.Up => Cursor('A'),
            Key.Down => Cursor('B'),
            Key.Right => Cursor('C'),
            Key.Left => Cursor('D'),
            Key.Home => Cursor('H'),
            Key.End => Cursor('F'),
            Key.PageUp => Tilde(5),
            Key.PageDown => Tilde(6),
            Key.Insert => Tilde(2),
            Key.Delete => Tilde(3),
            Key.Backspace => ctrl ? "\b" : alt ? "\x1b\x7f" : "\x7f",
            Key.Tab => shift ? "\x1b[Z" : "\t",
            Key.Enter => alt ? "\x1b\r" : "\r",
            Key.Escape => "\x1b",
            Key.F1 => Ss3('P'),
            Key.F2 => Ss3('Q'),
            Key.F3 => Ss3('R'),
            Key.F4 => Ss3('S'),
            Key.F5 => Tilde(15),
            Key.F6 => Tilde(17),
            Key.F7 => Tilde(18),
            Key.F8 => Tilde(19),
            Key.F9 => Tilde(20),
            Key.F10 => Tilde(21),
            Key.F11 => Tilde(23),
            Key.F12 => Tilde(24),
            _ => "",
        };
        return Encoding.ASCII.GetBytes(text);
    }

    /// A typed character with Ctrl held: Ctrl+C is 0x03, Ctrl+Space and Ctrl+@ NUL, Ctrl+[ ESC … Null when Ctrl means
    /// nothing for it.
    public static byte? Control(char c)
    {
        c = char.ToUpperInvariant(c);
        if (c is >= '@' and <= '_') return (byte)(c - '@');
        if (c == ' ' || c == '2') return 0;
        if (c == '/' || c == '7') return 0x1f;
        if (c == '?' || c == '8') return 0x7f;
        if (c is >= '3' and <= '6') return (byte)(c - '3' + 0x1b);
        return null;
    }

    /// Typed text (Alt adds an ESC before it, as xterm's metaSendsEscape).
    public static byte[] Text(string text, bool alt = false) =>
        Encoding.UTF8.GetBytes((alt ? "\x1b" : "") + text);

    /// A paste: line breaks as Return, wrapped in ESC[200~ … ESC[201~ when the shell asked for bracketed paste.
    public static byte[] Paste(string text, bool bracketed)
    {
        var body = text.Replace("\r\n", "\r").Replace('\n', '\r');
        if (bracketed) body = "\x1b[200~" + body.Replace("\x1b[201~", "") + "\x1b[201~";
        return Encoding.UTF8.GetBytes(body);
    }
}
