namespace Hermes.Core.Terminal;

/// The Terminal's colours (TerminalViewController.swift): a dark panel (rgb 0.075 / 0.078 / 0.09) in every look, text
/// white 0.9, and VS Code's dark terminal for the 16 ANSI colours (SwiftTerm's own blue was too dark on the panel).
public static class TerminalColors
{
    public const int Background = 0x131417;
    public const int Foreground = 0xE6E6E6;

    public static readonly int[] Ansi =
    [
        0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
        0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
    ];

    /// 0xRRGGBB for a cell colour (-1: the default foreground or background; 0–255: the xterm palette; 0x1RRGGBB).
    public static int Rgb(int color, bool foreground)
    {
        if (color < 0) return foreground ? Foreground : Background;
        if (color >= 0x1000000) return color & 0xFFFFFF;
        if (color < 16) return Ansi[color];
        if (color < 232)
        {
            var i = color - 16;
            int Level(int v) => v == 0 ? 0 : 55 + v * 40;
            return (Level(i / 36) << 16) | (Level(i / 6 % 6) << 8) | Level(i % 6);
        }
        var g = 8 + (color - 232) * 10;
        return (g << 16) | (g << 8) | g;
    }

    /// The colours a cell draws with: inverse swaps them; bold brightens the first eight ANSI colours, as xterm does.
    public static (int Fg, int Bg) Resolve(CellStyle style)
    {
        var fgIndex = style.Has(CellStyle.Attr.Bold) && style.Fg is >= 0 and < 8 ? style.Fg + 8 : style.Fg;
        int fg = Rgb(fgIndex, true), bg = Rgb(style.Bg, false);
        if (style.Has(CellStyle.Attr.Inverse)) (fg, bg) = (bg, fg);
        if (style.Has(CellStyle.Attr.Hidden)) fg = bg;
        return (fg, bg);
    }
}
