using System.Globalization;
using System.Text.RegularExpressions;
using Hermes.Core.Bots;
using Hermes.Core.Voice;

namespace Hermes.Core.Groups;

// [groups] The words of a room (HermesKit/Groups/GroupRowWords.swift; docs/spec/3x-groups.md §7.1, §7.2, §7.13): its
// list second line, "1 bot" / "N bots", typing and paused lines, and the Activity page's lines.
public static class GroupRowWords
{
    public enum Tone { Secondary, Tint, Orange }

    public sealed record Line(string Text, Tone Tone);

    public static string Bots(int count) => count == 1 ? "1 bot" : $"{count} bots";

    /// `Ivy is replying…` / `Ivy and Research are replying…` / `Ivy, Research and 2 more are replying…`.
    public static string Replying(IReadOnlyList<string> names) => names.Count switch
    {
        0 => "Replying…",
        1 => $"{names[0]} is replying…",
        2 => $"{names[0]} and {names[1]} are replying…",
        _ => $"{names[0]}, {names[1]} and {names.Count - 2} more are replying…",
    };

    public static string Paused(IReadOnlyList<string> names) => names.Count == 1 ? $"{names[0]} is paused" : $"{names.Count} bots paused";

    /// An empty room's second line: every name, or `No bots yet`.
    public static string MembersOrNone(IReadOnlyList<string> names) => names.Count == 0 ? "No bots yet" : string.Join(", ", names);

    /// The room's title-bar line when nothing runs: the members' names, or `N bots` when that is long.
    public static string Members(IReadOnlyList<string> names)
    {
        var joined = string.Join(", ", names);
        return joined.Length == 0 ? "No bots yet" : GroupKeys.Characters(joined) > 32 ? Bots(names.Count) : joined;
    }

    /// `You: <text>` / `Ivy: <text>`, Markdown stripped, `…` when it has no words.
    public static string Preview(GroupMessage entry, IReadOnlyDictionary<string, string> labels)
    {
        var who = entry.From.Kind == GroupAuthorKind.User ? "You" : labels.GetValueOrDefault(entry.From.Name) ?? entry.From.Name;
        var said = VoiceMemoLine(entry.Text) ?? entry.Text;   // a voice memo: "Voice Memo: <words>"
        var flat = string.Join(" ", RosterPreview.StripMarkdown(said).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var text = GroupKeys.Prefix(flat, 160);
        return $"{who}: {(text.Length == 0 ? "…" : text)}";
    }

    /// The row's second line, first state that applies (§7.1's table).
    public static Line SecondLine(bool waitingOnUser, IReadOnlyList<string> replying, int available, int driven, bool offline,
        GroupMessage? last, IReadOnlyDictionary<string, string> labels, int memberCount)
    {
        if (waitingOnUser) return new Line("Waiting for your reply", Tone.Orange);
        if (replying.Count > 0) return new Line(Replying(replying), Tone.Tint);
        if (driven > 0 && (offline || available < driven)) return new Line($"{(offline ? 0 : available)} of {driven} available", Tone.Orange);
        if (last != null) return new Line(Preview(last, labels), Tone.Secondary);
        return new Line(Bots(memberCount), Tone.Secondary);
    }

    /// The Mac draws `Symbol` as an SF Symbol; the Windows screens map the name to a glyph.
    public sealed record ActivityLine(string Text, string Symbol, bool Red = false);

    /// One Activity line (§7.2's table). `name` is the member's display name.
    public static ActivityLine Activity(GroupActivityEvent e, string name)
    {
        switch (e.Kind)
        {
            case GroupActivityKind.Queued: return new("You sent a message", "bubble.left");
            case GroupActivityKind.Working: return new($"{name} is working…", "arrow.triangle.2.circlepath");
            case GroupActivityKind.Replied: return new($"{name} replied", "checkmark");
            case GroupActivityKind.Passed: return new($"{name} passed", "circle");
            case GroupActivityKind.TimedOut: return new($"{name} took too long", "clock", true);
            case GroupActivityKind.Failed:
                var reason = (e.Detail ?? "").Trim();
                if (reason == "no-slot") return new($"{name} couldn't start — too many bots running", "exclamationmark.circle", true);
                return new(reason.Length == 0 ? $"{name} hit an error" : $"{name} hit an error — {reason}", "exclamationmark.circle", true);
            case GroupActivityKind.Cancelled: return new("Turn interrupted by a newer message", "xmark");
            case GroupActivityKind.Settled: return new("Turn settled", "checkmark.circle");
            case GroupActivityKind.Capped: return new("Turn stopped at the round/message cap", "forward.end");
            case GroupActivityKind.Delivered: return new($"{name} delivered a late reply", "envelope.open");
            case GroupActivityKind.Held: return new($"{name} is held (stopped by you) — @mention it or say resume to release", "pause");
            default: return new("You stopped the room — remaining turns are held until resumed", "stop");
        }
    }

    /// The row read aloud: `Launch Room. Ivy: I can take the notes. 2 min ago. Unread. Pinned. Muted. Hidden`.
    public static string AccessibilityLabel(string name, string line, string time, bool unread, bool pinned, bool muted, bool hidden = false)
    {
        var parts = new List<string> { name, line };
        if (time.Length > 0) parts.Add(time);
        if (unread) parts.Add("Unread");
        if (pinned) parts.Add("Pinned");
        if (muted) parts.Add("Muted");
        if (hidden) parts.Add("Hidden");
        // A line that already ends its own sentence ("…the notes.", "Ivy is replying…") gets no second full stop.
        return string.Join(" ", parts.Select((p, i) => i == parts.Count - 1 || (p.Length > 0 && ".…?!".Contains(p[^1])) ? p : p + "."));
    }

    /// VoiceMemo.parse(text)?.transcriptLine (HermesKit/Voice/MemoText.swift; Hermes.Core.Voice.VoiceMemo): "<title>:
    /// <said>", then what was typed. Null: not a memo.
    internal static string? VoiceMemoLine(string text) => VoiceMemo.Parse(text)?.TranscriptLine;
}

/// A sender's name in its bot's colour, made readable at 4.5:1 on the bubble (row L301; `S/ui-chat/name-color.ts`).
public static class NameColor
{
    public readonly record struct Rgb(double R, double G, double B);

    public static readonly Rgb WebLightBubble = new(242, 242, 247), WebDarkBubble = new(44, 44, 46);
    /// The surfaces a name sits on in this app, the harder case each way.
    public static readonly Rgb LightBubble = new(233, 233, 235), DarkBubble = new(44, 44, 46);

    private static readonly Regex Hex = new("^#([0-9a-f]{3}|[0-9a-f]{6})$", RegexOptions.IgnoreCase);
    private static readonly Regex RgbRx = new(@"^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)", RegexOptions.IgnoreCase);
    private static readonly Regex HslRx = new(@"^hsla?\(\s*([\d.]+)(?:deg)?[\s,]+([\d.]+)%[\s,]+([\d.]+)%", RegexOptions.IgnoreCase);

    private static bool D(string s, out double d) => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d);

    /// `parseColor`: `#rgb`, `#rrggbb`, `rgb()`, `hsl()`; null for anything else.
    public static Rgb? Parse(string color)
    {
        var value = color.Trim();
        if (Hex.Match(value) is { Success: true } h)
        {
            var hex = h.Groups[1].Value;
            var digits = hex.Length == 3 ? string.Concat(hex.Select(c => $"{c}{c}")) : hex;
            var n = Convert.ToUInt32(digits, 16);
            return new Rgb((n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF);
        }
        if (RgbRx.Match(value) is { Success: true } m && D(m.Groups[1].Value, out var r) && D(m.Groups[2].Value, out var g) && D(m.Groups[3].Value, out var b))
            return new Rgb(r, g, b);
        if (HslRx.Match(value) is { Success: true } s && D(s.Groups[1].Value, out var hue) && D(s.Groups[2].Value, out var sat) && D(s.Groups[3].Value, out var light))
        {
            double hh = hue % 360 / 360, ss = sat / 100, l = light / 100;
            double q = l < 0.5 ? l * (1 + ss) : l + ss - l * ss, p = 2 * l - q;
            double Channel(double raw)
            {
                var t = raw;
                if (t < 0) t += 1;
                if (t > 1) t -= 1;
                var c = t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p;
                return Math.Round(c * 255, MidpointRounding.AwayFromZero);
            }
            return new Rgb(Channel(hh + 1.0 / 3), Channel(hh), Channel(hh - 1.0 / 3));
        }
        return null;
    }

    public static double Luminance(Rgb c)
    {
        static double F(double raw) { var v = raw / 255; return v <= 0.03928 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4); }
        return 0.2126 * F(c.R) + 0.7152 * F(c.G) + 0.0722 * F(c.B);
    }

    public static double Contrast(Rgb a, Rgb b)
    {
        double la = Luminance(a), lb = Luminance(b);
        return (Math.Max(la, lb) + 0.05) / (Math.Min(la, lb) + 0.05);
    }

    /// The colour mixed toward `toward` in steps of 5% until it holds `ratio` (4.5:1) on `surface`.
    public static Rgb Readable(Rgb color, Rgb surface, Rgb toward, double ratio = 4.5)
    {
        static double R(double v) => Math.Round(v, MidpointRounding.AwayFromZero);
        for (var step = 0; step <= 20; step++)
        {
            var amount = step / 20.0;
            var candidate = new Rgb(R(color.R + (toward.R - color.R) * amount), R(color.G + (toward.G - color.G) * amount), R(color.B + (toward.B - color.B) * amount));
            if (Contrast(candidate, surface) >= ratio) return candidate;
        }
        return toward;
    }

    /// The name's colour on the light and the dark bubble; null when the colour cannot be read (the label colour then).
    public static (Rgb Light, Rgb Dark)? Readable(string? color, Rgb? light = null, Rgb? dark = null)
    {
        if (color == null || Parse(color) is not { } rgb) return null;
        return (Readable(rgb, light ?? LightBubble, new Rgb(0, 0, 0)), Readable(rgb, dark ?? DarkBubble, new Rgb(255, 255, 255)));
    }
}

/// A message another bot delivered into a chat (row L301; `S/ui-chat/run.ts:36, 78-83`).
public static class DeliverySender
{
    private static readonly Regex Pattern = new(
        "^(?:Message from (?:🤖\\s*)?([^:\\n(]{1,64}?)(?:\\s*\\(@([a-z0-9][a-z0-9_-]{0,63})(?:@[a-zA-Z0-9][a-zA-Z0-9_-]{0,63})?\\))?:\\s*|\\[Message from agent '([^']{1,64})'\\]\\s*)");

    public sealed record Parsed(string Name, string Handle, string Body);

    public static Parsed? Parse(string text)
    {
        var m = Pattern.Match(text);
        if (!m.Success) return null;
        string? Group(int i) => m.Groups[i].Success ? m.Groups[i].Value : null;
        var agent = Group(3);
        var name = (Group(1) ?? agent ?? "agent").Trim(' ', '\t');
        if (name.Length == 0) return null;
        var handle = (Group(2) ?? agent ?? name).Trim(' ', '\t').ToLowerInvariant();
        var body = text[(m.Index + m.Length)..].Trim();
        return new Parsed(name, handle, body);
    }
}
