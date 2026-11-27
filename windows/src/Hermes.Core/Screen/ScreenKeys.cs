// [WIN-SCREEN-WIRE-KEYS-MATH] Keys for a controlled screen, the C# twin of the Mac's HermesKit/Screen/ScreenKeys.swift
// at 93f984bb1 (docs/spec/3x-screen.md §5.6), a port of the web app's keysym rules: Latin-1 maps to itself, anything else
// is 0x01000000 + code point; modifiers go down in the order shift, ctrl, alt, meta and come up in reverse; ⌘ is Super_L
// and ⌥ is Alt_L, as the Mac helper maps them.
//
// Windows virtual keys: none here, on purpose. Everything this layer sends is an X11 keysym for the *remote* desktop,
// which is the same whichever computer is watching; the Mac file has no Mac key codes to translate (the ⌘V for a Mac
// host is about the host, not this device). Reading a Windows key press (VK_HOME, VK_F1, VK_CONTROL/VK_LWIN…) into
// `Named` / `Modifier` belongs to the Screen view (the next slice), where the keyboard events arrive.

using System.Globalization;
using System.Text;

namespace Hermes.Core.Screen;

/// What Paste does with the text (Swift `ScreenKeys.Paste`).
public abstract record ScreenPaste
{
    private ScreenPaste() { }

    /// Nothing to paste: the pill "There’s no text to paste.".
    public sealed record Empty : ScreenPaste;

    /// A Mac host and Latin-1 text: the remote clipboard is set, then ⌘V.
    public sealed record Clipboard(IReadOnlyList<byte[]> Messages) : ScreenPaste
    {
        public bool Equals(Clipboard? other) =>
            other is not null && Messages.Count == other.Messages.Count && Messages.Zip(other.Messages).All(p => p.First.AsSpan().SequenceEqual(p.Second));

        public override int GetHashCode() => Messages.Count;
    }

    /// Anything else is typed key by key.
    public sealed record Typed(string Text) : ScreenPaste;
}

public static class ScreenKeys
{
    public enum Modifier { Shift, Ctrl, Alt, Meta }

    /// Audit 09-18: Home, End, Page Up/Down and F1–F12 too, from a hardware keyboard (the web's list stopped at the
    /// arrows).
    public enum Named
    {
        Backspace, Tab, Enter, Escape, Delete, Left, Up, Right, Down,
        Home, End, PageUp, PageDown,
        F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    }

    /// F1 to F12, in order.
    public static IReadOnlyList<Named> Function => FunctionKeys;

    private static readonly Named[] FunctionKeys =
        [Named.F1, Named.F2, Named.F3, Named.F4, Named.F5, Named.F6, Named.F7, Named.F8, Named.F9, Named.F10, Named.F11, Named.F12];

    public static uint Keysym(this Modifier modifier) => modifier switch
    {
        Modifier.Shift => 0xFFE1,
        Modifier.Ctrl => 0xFFE3,
        Modifier.Alt => 0xFFE9,
        _ => 0xFFEB,
    };

    public static uint Keysym(this Named key)
    {
        var index = Array.IndexOf(FunctionKeys, key);
        if (index >= 0) return 0xFFBEu + (uint)index;
        return key switch
        {
            Named.Backspace => 0xFF08,
            Named.Tab => 0xFF09,
            Named.Enter => 0xFF0D,
            Named.Escape => 0xFF1B,
            Named.Delete => 0xFFFF,
            Named.Left => 0xFF51,
            Named.Up => 0xFF52,
            Named.Right => 0xFF53,
            Named.Down => 0xFF54,
            Named.Home => 0xFF50,
            Named.End => 0xFF57,
            Named.PageUp => 0xFF55,
            Named.PageDown => 0xFF56,
            _ => 0xFFBE,
        };
    }

    /// The Swift raw value ("backspace", "pageUp", "f1", …).
    public static string Raw(this Named key)
    {
        var name = key.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    public const int MaxCutText = RfbMessage.MaxCutText;
    /// Typed text goes out this many characters per turn of the run loop (DECISION D18).
    public const int TypingSlice = 500;

    /// X11 keysym for a Unicode code point.
    public static uint KeysymFor(uint codePoint) =>
        codePoint is >= 0x20 and <= 0x7E or >= 0xA0 and <= 0xFF ? codePoint : 0x0100_0000 + codePoint;

    /// The key pressed and released under `mods`: modifiers down in order, the key, modifiers up in reverse.
    public static List<byte[]> Chord(uint keysym, IReadOnlyCollection<Modifier>? mods = null)
    {
        var held = Enum.GetValues<Modifier>().Where(m => mods?.Contains(m) == true).ToList();
        var out_ = held.Select(m => RfbMessage.Key(m.Keysym(), down: true)).ToList();
        out_.Add(RfbMessage.Key(keysym, down: true));
        out_.Add(RfbMessage.Key(keysym, down: false));
        for (var i = held.Count - 1; i >= 0; i--) out_.Add(RfbMessage.Key(held[i].Keysym(), down: false));
        return out_;
    }

    /// Typed text: one key press per code point, each under the held modifiers. A line break is Return and a tab is
    /// Tab (DECISION: the web sent their raw code points, which no desktop understands); a carriage return is dropped.
    public static List<byte[]> Text(string text, IReadOnlyCollection<Modifier>? mods = null)
    {
        var out_ = new List<byte[]>();
        foreach (var rune in text.EnumerateRunes())
        {
            switch (rune.Value)
            {
                case 0x0D: continue;
                case 0x0A: out_.AddRange(Chord(Named.Enter.Keysym(), mods)); break;
                case 0x09: out_.AddRange(Chord(Named.Tab.Keysym(), mods)); break;
                default: out_.AddRange(Chord(KeysymFor((uint)rune.Value), mods)); break;
            }
        }
        return out_;
    }

    /// The text as Latin-1 bytes when every code point is at most U+00FF and it fits a ClientCutText; null otherwise
    /// (it is typed instead).
    public static byte[]? Latin1(string text)
    {
        var bytes = new List<byte>(Math.Min(text.Length, MaxCutText + 1));
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value > 0xFF) return null;
            bytes.Add((byte)rune.Value);
            if (bytes.Count > MaxCutText) return null;
        }
        return [.. bytes];
    }

    public static ScreenPaste Paste(string? text, bool mac)
    {
        if (string.IsNullOrEmpty(text)) return new ScreenPaste.Empty();
        if (mac && Latin1(text) is { } bytes)
            return new ScreenPaste.Clipboard([RfbMessage.CutText(bytes), .. Chord(0x76, [Modifier.Meta])]);
        return new ScreenPaste.Typed(text);
    }

    /// What a text field change means: nothing while an input method is still composing, the text once it commits.
    public static string? Committed(string? text, bool composing) => composing || string.IsNullOrEmpty(text) ? null : text;
}

/// Typed text waiting to go out in slices, so a long paste never stalls the app; `Cancel` drops the rest (hand back,
/// control lost, Close). Characters are grapheme clusters, as Swift's `Character`.
public sealed class ScreenTyper
{
    private readonly Queue<string> _pending = new();
    private IReadOnlyCollection<ScreenKeys.Modifier> _mods = [];

    public bool IsEmpty => _pending.Count == 0;
    public int Count => _pending.Count;

    public void Add(string text, IReadOnlyCollection<ScreenKeys.Modifier> mods)
    {
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext()) _pending.Enqueue(elements.GetTextElement());
        _mods = mods.ToArray();
    }

    /// The next slice's key events (at most `ScreenKeys.TypingSlice` characters).
    public List<byte[]> Next()
    {
        if (_pending.Count == 0) return [];
        var slice = new StringBuilder();
        for (var i = 0; i < ScreenKeys.TypingSlice && _pending.Count > 0; i++) slice.Append(_pending.Dequeue());
        return ScreenKeys.Text(slice.ToString(), _mods);
    }

    public void Cancel() => _pending.Clear();
}
