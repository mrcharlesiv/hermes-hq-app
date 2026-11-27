using Hermes.Core.Transcripts;

namespace Hermes.Core.Gateways;

/// [WIN-FOOTER-GATEWAY-CLIP] How the open sidebar's foot fits the gateway's name between the sidebar button and the gear
/// (App/Mac/MacSidebar.swift `showGateway`, `[sidebar-tidy]` / `[gateway-foot]`):
///
/// - The dot, 6 before the line (`gatewayDot.trailingAnchor … gatewayLine.leadingAnchor, constant: -6`).
/// - The line: the name, then (more than one gateway) the pop-up's chevrons and the news dot, 4 apart
///   (`gatewayLine.spacing = 4`). The chevrons never shrink (`setContentHuggingPriority(.required)`,
///   `setContentCompressionResistancePriority(.required)`) and the news dot is a fixed 6 × 6, so only the name gives way.
/// - The line ends at least 6 before the gear (`gatewayLine.trailingAnchor.constraint(lessThanOrEqualTo:
///   settingsButton.leadingAnchor, constant: -6)`); the gear and its neighbours keep their size.
/// - The name is one line cut in the middle (`gatewayName.lineBreakMode = .byTruncatingMiddle`): "127.0…1:9863", the
///   host's start and its port both still there. No fixed cap: only the gear bounds it, at any text size.
///
/// Windows hard-clipped it instead: a 170-wide name in a StackPanel (which measures at any width) was cut off at the
/// foot's column with no ellipsis at 150 % text ("127.0.0.1:98"). The name's room is worked out here and the name cut to it.
public static class GatewayFootFit
{
    /// The dot's gap before the line, the line's gaps, and the least gap from the line's end to the gear (points).
    public const double DotGap = 6, LineGap = 4, GearGap = 6;

    /// The room the name has in `line` (the width the line may take, the gear gap already out), after the chevrons and the
    /// news dot when they show, each `LineGap` after the one before. Never below 0.
    public static double NameRoom(double line, double arrows = 0, double news = 0)
    {
        if (double.IsInfinity(line) || double.IsNaN(line)) return double.PositiveInfinity;
        var room = line;
        if (arrows > 0) room -= LineGap + arrows;
        if (news > 0) room -= LineGap + news;
        return Math.Max(0, room);
    }

    /// The name as the foot shows it in `room`: whole when it fits, else cut in the middle (`.byTruncatingMiddle`), a unit
    /// short of the room so the TextBlock's own tail ellipsis never cuts what was already cut. Whole with no bound.
    public static string Name(string whole, double room, Func<string, double> measure)
    {
        if (string.IsNullOrEmpty(whole)) return whole ?? "";
        if (double.IsPositiveInfinity(room)) return whole;
        return LinkChipSize.MiddleTrim(whole, Math.Max(0, room - 1), measure);
    }

    /// The text-scale walk's check of the drawn foot (all in one coordinate space): null when the name lies within the
    /// room its line is given (`nameRight` no further than `roomRight`: nothing hard-clipped at the foot's column), isn't
    /// cut at its end by the TextBlock's own ellipsis (`tailCut`), ends at least `GearGap` before the gear, and shows the
    /// whole name or that name cut in the middle; else everything that is wrong. `shown` is the TextBlock's text.
    public static string? Judge(string whole, string shown, double nameRight, double roomRight, double gearLeft, bool tailCut)
    {
        var wrong = new List<string>();
        if (nameRight > roomRight + 0.5)
            wrong.Add($"the gateway's name runs {nameRight - roomRight:0.#} past its room: hard-clipped, not cut in the middle");
        if (tailCut) wrong.Add("the gateway's name is cut at its end, not in the middle");
        if (nameRight > gearLeft - GearGap + 0.5)
            wrong.Add($"the gateway's name ends {gearLeft - nameRight:0.#} before the gear, not at least {GearGap:0}");
        if (shown != whole && !IsMiddleCut(whole, shown))
            wrong.Add($"the gateway's name ({whole.Length} characters) shows {shown.Length}, not cut in the middle around one \"…\"");
        return wrong.Count == 0 ? null : "sidebar foot: " + string.Join("; ", wrong);
    }

    /// `shown` is `whole` cut in the middle: its start, one "…", its end, the start a character longer at most (the odd
    /// one goes first, as `LinkChipSize.MiddleTrim` cuts; a surrogate pair counts two here).
    public static bool IsMiddleCut(string whole, string shown)
    {
        var at = shown.IndexOf('…');
        if (at < 0 || shown.IndexOf('…', at + 1) >= 0) return false;
        var head = shown[..at];
        var tail = shown[(at + 1)..];
        var lean = head.Length - tail.Length;
        return head.Length + tail.Length < whole.Length && whole.StartsWith(head, StringComparison.Ordinal)
            && whole.EndsWith(tail, StringComparison.Ordinal) && lean >= -1 && lean <= 2;
    }
}
