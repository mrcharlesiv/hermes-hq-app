using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Heads;

/// The Robot, Dots, Orb, Pixel and Emoji heads, ported line for line from App/Heads/ThemeHeadSVG.swift (the web app's
/// `robot.ts`, `parts.ts` and `render.ts`). Each builds the same SVG markup the Mac builds, numbers printed as JavaScript
/// prints them, so the port is checked against the recorded markup (Tests/Fixtures/theme-heads-web.json). On Windows the
/// markup is drawn by Direct2D's SVG renderer (`ForDirect2D`), which has no blur filters or text.
public static class ThemeHeadSvg
{
    const double Tau = Math.PI * 2;

    // MARK: JavaScript number semantics

    /// `Math.round`: halves go up, toward +∞.
    public static double Round(double v) => Math.Floor(v + 0.5);
    /// A number as a template literal prints it (shortest round-trip, integers without ".0", -0 as "0").
    public static string Js(double v)
    {
        if (v == Math.Round(v, MidpointRounding.AwayFromZero) && Math.Abs(v) < 1e21) return ((long)v).ToString(CultureInfo.InvariantCulture);
        return v.ToString("R", CultureInfo.InvariantCulture);
    }
    /// robot.ts / parts.ts `n`: a whole number.
    public static string N(double v) => Js(Round(v));
    /// render.ts `n`: one decimal place.
    public static double N1(double v) => Round(v * 10) / 10;

    // MARK: Tones (`robot.ts:11-37`)

    public sealed record Tone(string Panel, string Accent, string Light, string Deep);
    public const string Ink = "#0A0A0A";
    public static readonly Dictionary<string, Tone> Tones = new()
    {
        ["ink"] = new("#F7F5F0", "#2EC4B6", "#A8F0E8", "#148F86"),
        ["mint"] = new("#BDEEDF", "#078267", "#B4F8E4", "#045845"),
        ["teal"] = new("#AEE6EE", "#057E93", "#B8F2FB", "#005564"),
        ["sky"] = new("#BCD9FF", "#2770D9", "#CBE0FF", "#0048A2"),
        ["lilac"] = new("#D7CCFF", "#795CDF", "#DDD3FF", "#5321B5"),
        ["pink"] = new("#FFC7E1", "#CC3582", "#FFD3E8", "#9C025D"),
        ["coral"] = new("#FFC4B6", "#CD422C", "#FFD5CB", "#9F1B04"),
        ["peach"] = new("#FFDAB6", "#C15003", "#FFE3C4", "#8E3901"),
        ["butter"] = new("#FFDAB6", "#C15003", "#FFE3C4", "#8E3901"),
        ["lime"] = new("#B3E8C6", "#03843C", "#C2ECD1", "#065B28"),
        ["paper"] = new("#E7E1D3", "#EFE9DB", "#FFFFFF", "#8F8672"),
        ["red"] = new("#F9B8B7", "#DE2627", "#FAC6C5", "#9B1B1A"),
        ["grass"] = new("#B3E8C6", "#03843C", "#C2ECD1", "#065B28"),
        ["forest"] = new("#B0CEBF", "#23784E", "#BFD8CC", "#195437"),
        ["cobalt"] = new("#B4C4FF", "#2E5BFF", "#C2CFFF", "#2040B3"),
        ["denim"] = new("#B8C4E0", "#3A5BA8", "#C6CFE6", "#294076"),
        ["grape"] = new("#D0B8F9", "#7C3AED", "#D9C6FA", "#5729A6"),
        ["plum"] = new("#D5BAD9", "#8A3F96", "#DDC7E1", "#612C69"),
        ["magenta"] = new("#F4AFD5", "#D91585", "#F6BFDD", "#980F5C"),
        ["rose"] = new("#FFC7E1", "#CC3582", "#FFD3E8", "#9C025D"),
        ["wine"] = new("#E3B4C2", "#B03055", "#E8C3CE", "#7B223C"),
        ["caramel"] = new("#D5C2B7", "#8A5638", "#DDCEC5", "#613C27"),
        ["cocoa"] = new("#D5C2B7", "#8A5638", "#DDCEC5", "#613C27"),
        ["slate"] = new("#CACED4", "#6B7688", "#D4D7DC", "#4B535F"),
    };
    public static Tone ToneOf(string color) => Tones.TryGetValue(color, out var t) ? t : Tones["mint"];

    // MARK: The icon's parts (`parts.ts:8-19`)

    public const string Frame = HeadGeometry.Frame;
    public const string Panel = HeadGeometry.PanelPath;
    const string Dome = "M600 199c99 3 198 34 252 123 28 46 41 103 44 156 4 55-2 110-32 158-14 23-34 45-58 61-49 33-147 51-206 60-34 5-67 8-100 10-32 2-64 6-95 5-69-1-95-5-153-44-21-14-41-29-56-48-34-42-47-95-49-148-1-28 0-56 6-84 14-65 40-105 90-148 18-16 35-27 57-38 74-37 217-65 300-63z";
    const string VisorPath = "M725 364c13-1 22-2 33-1 10 0 21 3 31 7 45 16 69 50 80 95 3 14 6 30 8 45 4 34-1 64-21 92-19 28-48 44-79 55-17 5-41 10-62 15-20 5-41 11-61 15-42 8-83 14-125 18-21 3-46 6-63 6-58 3-109-18-135-72-4-10-7-22-10-31-3-15-6-31-8-46-5-45 7-86 43-116 17-15 36-22 58-27 17-4 42-8 62-11 42-8 83-15 125-22 21-4 41-7 62-11 21-4 45-9 62-11z";
    const string Shoulders = "M205 1034l7-34c7-26 13-51 24-75 15-32 35-60 64-82 26-19 60-33 92-40 61-14 160-13 223-6 19 2 36 4 53 9 78 22 129 76 154 152 5 14 7 28 10 42l8 34z";
    const string Neck = "M410 728c26-20 163-25 186-6 11 9 4 28 6 40 2 9 3 17 6 24 3 7 13 16 10 20-4 7-43-1-63 0-19 1-37 4-55 7-18 3-37 8-55 13-18 6-45 25-53 20-10-6 3-67 6-78 3-14 0-31 12-40z";
    const string ShoulderLights = "M240 968c20-48 36-86 79-118 13-10 27-18 41-26-53 20-87 41-108 96-6 16-9 31-12 48zM352 858c64-25 136-50 205-54 23-1 47 1 71 2-24-4-47-8-71-8-24-1-48 3-72 8-49 11-89 28-133 52zM503 968c9-34 15-72 43-98 12-11 30-18 46-24 17-6 35-10 53-11 17-1 36 1 52 7 16 5 31 17 44 29 13 11 25 26 35 41 9 15 14 33 21 50-5-18-8-37-16-53-9-16-21-32-34-45-13-13-29-26-46-32-36-14-77-9-112 5-17 6-36 15-49 27-12 13-21 32-27 50-6 17-7 36-10 54z";
    const string NeckLightA = "M522 772c9 1 17 1 26 0 41-1 35-9 49 32 1-4 2-9 2-13 0-29-16-30-39-27-13 2-25 4-38 8z";
    const string NeckLightB = "M414 772c-9 14-13 30-11 46 10-14 15-29 11-46z";
    const string Tuft = "M262 302l26-13 16-7 23-12 9-3 28-4-4-13 28 11 18 1-5-14 31 21 18 6 8 3-4-12 30 22 22 9 10 9 14 4 67 34 25 15-4 1-16-4-34 8 8-16-8-2-56 20 14-35-8-3-55 32 17-46-6-2-43 34 13-43-6-2-56 42 14-51-6-1-34 35 10-38-6-1-38 32 10-30-6 1-33 20 9-14-36 7z";
    const string DomeLights = "M278 293c-7 4-15 7-22 11-36 20-66 55-82 93-6 15-9 32-12 48 6-15 12-31 19-45 22-43 61-76 97-107zM268 330c-9 7-18 14-26 22-22 27-32 61-38 94 13-30 26-61 45-89 6-9 13-18 19-27zM296 346c-32 26-50 57-62 96 20-33 41-64 62-96zM455 241c48-2 92-7 141 0 15 3 31 6 46 9-72-27-113-27-187-9zM566 252c39 10 77 18 115 33 9 4 18 8 27 12 9 4 18 9 26 14 18 9 34 21 50 33-15-14-29-27-46-39-9-5-18-10-27-15-52-28-87-33-145-38zM738 240c20 10 41 18 58 32 52 42 69 116 79 178 0-38-2-64-14-101-12-33-29-65-59-85-19-13-42-18-64-24zM860 634c-9 9-18 19-27 27-16 14-36 25-53 37 40-12 61-25 80-64z";

    // MARK: Outline helpers (`parts.ts:21-63`)

    static (double, double)[] Around(int count, Func<double, (double, double)> at) =>
        [.. Enumerable.Range(0, count).Select(i => at((double)i / count * Tau - Math.PI / 2))];

    static (double, double)[] Cloud()
    {
        (double, double, double)[] puffs = [(-0.58, -0.02, 0.44), (-0.14, -0.36, 0.5), (0.4, -0.26, 0.44), (0.72, 0.08, 0.36)];
        (double, double) origin = (0, 0.12);
        return Around(72, t =>
        {
            double dx = Math.Cos(t), dy = Math.Sin(t);
            var reach = 1 / Math.Sqrt(Math.Pow(dx / 0.98, 2) + Math.Pow(dy / 0.4, 2));
            foreach (var (cx, cy, r) in puffs)
            {
                double x = cx - origin.Item1, y = cy - origin.Item2, b = dx * x + dy * y, q = b * b - (x * x + y * y - r * r);
                if (q >= 0) reach = Math.Max(reach, b + Math.Sqrt(q));
            }
            return (origin.Item1 + dx * reach, origin.Item2 + dy * reach);
        });
    }

    static (double, double)[] Superellipse(double w, double h, double power, int count = 40) => Around(count, t =>
    {
        double c = Math.Cos(t), s = Math.Sin(t);
        return (Sign(c) * Math.Pow(Math.Abs(c), power) * w, Sign(s) * Math.Pow(Math.Abs(s), power) * h);
    });

    /// `Math.sign`.
    static double Sign(double v) => v > 0 ? 1 : v < 0 ? -1 : v;

    static (double, double)[] Wobble((double, double)[] points, int seed, double amount)
    {
        double a = seed % 997 / 997.0 * Tau, b = seed % 613 / 613.0 * Tau;
        return [.. points.Select(p =>
        {
            double t = Math.Atan2(p.Item2, p.Item1), k = 1 + amount * (Math.Sin(3 * t + a) * 0.6 + Math.Sin(5 * t + b) * 0.4);
            return (p.Item1 * k, p.Item2 * k);
        })];
    }

    /// A closed Catmull-Rom spline through the points, as a path and as a dense outline to cut highlights from.
    static (string D, List<(double, double)> Dense) Spline(IReadOnlyList<(double, double)> p)
    {
        var count = p.Count;
        var dense = new List<(double, double)>();
        var d = new StringBuilder($"M{N(p[0].Item1)} {N(p[0].Item2)}");
        for (var i = 0; i < count; i++)
        {
            var (p0, p1, p2, p3) = (p[(i - 1 + count) % count], p[i], p[(i + 1) % count], p[(i + 2) % count]);
            var c1 = (p1.Item1 + (p2.Item1 - p0.Item1) / 6, p1.Item2 + (p2.Item2 - p0.Item2) / 6);
            var c2 = (p2.Item1 - (p3.Item1 - p1.Item1) / 6, p2.Item2 - (p3.Item2 - p1.Item2) / 6);
            d.Append($"C{N(c1.Item1)} {N(c1.Item2)} {N(c2.Item1)} {N(c2.Item2)} {N(p2.Item1)} {N(p2.Item2)}");
            for (var step = 0; step < 6; step++)
            {
                double t = step / 6.0, u = 1 - t;
                dense.Add((Math.Pow(u, 3) * p1.Item1 + 3 * u * u * t * c1.Item1 + 3 * u * t * t * c2.Item1 + Math.Pow(t, 3) * p2.Item1,
                    Math.Pow(u, 3) * p1.Item2 + 3 * u * u * t * c1.Item2 + 3 * u * t * t * c2.Item2 + Math.Pow(t, 3) * p2.Item2));
            }
        }
        return (d + "Z", dense);
    }

    // MARK: Faces (`parts.ts:65-111`)

    sealed record Paint(string Ink, string Accent, string Light, string Deep, string Paper);
    const string HeartD = "M0 .8C-.6 .4-1 0-1-.35C-1-.75-.55-.95-.25-.8C-.1-.72 0-.6 0-.5C0-.6 .1-.72 .25-.8C.55-.95 1-.75 1-.35C1 0 .6 .4 0 .8Z";
    const string SparkD = "M0-1Q.14-.14 1 0Q.14 .14 0 1Q-.14 .14-1 0Q-.14-.14 0-1Z";
    static readonly (double, double) Left = (-115, 31), Right = (162, -18);

    static string IconEyes(Paint c) =>
        $"<g transform=\"translate(-595 -534)\"><path d=\"M553 556a73 111-7 1 1-145 18 73 111-7 1 1 145-18z\" fill=\"{c.Accent}\"/><path d=\"M454 458a73 111-7 0 1 97 90 260 260 0 0 1-97-90z\" fill=\"{c.Light}\"/><path d=\"M554 584a73 111-7 1 1-142-70 73 111-7 0 0 142 70z\" fill=\"{c.Deep}\"/><ellipse cx=\"446\" cy=\"516\" rx=\"25\" ry=\"31\" fill=\"#FFF\"/><ellipse cx=\"480\" cy=\"554\" rx=\"10\" ry=\"11\" fill=\"#FFF\"/><ellipse cx=\"533\" cy=\"614\" rx=\"10\" ry=\"11\" fill=\"#FFF\"/><path d=\"M817 509a60 110-7 1 1-120 14 60 110-7 1 1 120-14z\" fill=\"{c.Accent}\"/><path d=\"M730 412a60 110-7 0 1 85 86 240 240 0 0 1-85-86z\" fill=\"{c.Light}\"/><path d=\"M818 543a60 110-7 1 1-117-86 60 110-7 0 0 117 86z\" fill=\"{c.Deep}\"/><ellipse cx=\"730\" cy=\"466\" rx=\"22\" ry=\"29\" fill=\"#FFF\"/><ellipse cx=\"763\" cy=\"504\" rx=\"9\" ry=\"10\" fill=\"#FFF\"/><ellipse cx=\"801\" cy=\"568\" rx=\"10\" ry=\"11\" fill=\"#FFF\"/></g>";

    static string FaceMarkup(string face, Paint c, string id)
    {
        var serial = 0;
        // A glossy gem cut to any outline: a deep underside, a light cap, and three specks, as the icon's eyes.
        string Gem((double, double) at, double k, string shape, double w, double h, Paint? paint = null, bool specks = true, double? lid = null)
        {
            paint ??= c;
            var clip = $"{id}e{serial}";
            serial += 1;
            var cut = lid is { } l0 ? $"<clipPath id=\"{clip}l\"><path d=\"M-200 {Js(-28 - l0 * 200)}L200 {Js(-28 + l0 * 200)}V300H-200Z\"/></clipPath>" : "";
            var o = new StringBuilder();
            o.Append($"<g transform=\"translate({Js(at.Item1)} {Js(at.Item2)}) rotate(-7) scale({Js(k)})\">{cut}<g{(lid == null ? "" : $" clip-path=\"url(#{clip}l)\"")}><clipPath id=\"{clip}\">{shape}</clipPath><g clip-path=\"url(#{clip})\"><rect x=\"{Js(-w - 20)}\" y=\"{Js(-h - 20)}\" width=\"{Js(2 * w + 40)}\" height=\"{Js(2 * h + 40)}\" fill=\"{paint.Deep}\"/><g transform=\"translate({N(w * 0.14)} {N(-h * 0.16)})\" fill=\"{paint.Accent}\">{shape}</g><path d=\"M{Js(-w * 0.4)} {Js(-h - 20)}H{Js(w + 20)}V{Js(h * 0.3)}A{Js(w * 3.2)} {Js(w * 3.2)} 0 0 1 {Js(-w * 0.4)} {Js(-h - 20)}Z\" fill=\"{paint.Light}\"/></g>");
            if (specks)
                o.Append($"<ellipse cx=\"{N(-w * 0.42)}\" cy=\"{N(-h * 0.42)}\" rx=\"{N(Math.Min(w, h) * 0.32)}\" ry=\"{N(Math.Min(w, h) * 0.4)}\" fill=\"#FFF\"/><circle cx=\"{N(w * 0.02)}\" cy=\"{N(-h * 0.08)}\" r=\"{N(Math.Max(7, w * 0.13))}\" fill=\"#FFF\"/><circle cx=\"{N(w * 0.5)}\" cy=\"{N(h * 0.45)}\" r=\"{N(Math.Max(7, w * 0.13))}\" fill=\"#FFF\"/>");
            o.Append("</g>");
            if (lid is { } l) o.Append($"<path d=\"M-92 {N(-28 - l * 92)}L92 {N(-28 + l * 92)}\" stroke=\"{paint.Light}\" stroke-width=\"13\" stroke-linecap=\"round\"/>");
            return o + "</g>";
        }
        string Oval(double rx, double ry) => $"<ellipse rx=\"{Js(rx)}\" ry=\"{Js(ry)}\"/>";
        string Both(Func<(double, double), double, string> draw) => draw(Left, 1) + draw(Right, 0.86);
        string Glow((double, double) at, double k, string d, double w = 36) =>
            $"<g transform=\"translate({Js(at.Item1)} {Js(at.Item2)}) rotate(-7) scale({Js(k)})\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"{d}\" stroke=\"{c.Deep}\" stroke-width=\"{Js(w)}\"/><path d=\"{d}\" transform=\"translate(3 -6)\" stroke=\"{c.Accent}\" stroke-width=\"{Js(w - 10)}\"/><path d=\"{d}\" transform=\"translate(5 -11)\" stroke=\"{c.Light}\" stroke-width=\"{N(w * 0.22)}\" stroke-dasharray=\"{Js(w * 1.6)} 999\"/></g>";
        var pinkish = c with { Accent = "#FF5C93", Light = "#FFC2D6", Deep = "#C92C62" };
        switch (face)
        {
            case "visor": return IconEyes(c);
            case "pill": return Both((a, k) => Gem(a, k, Oval(50, 104), 50, 104));
            case "dots": return Both((a, k) => Gem(a, k, Oval(62, 62), 62, 62));
            case "surprised": return Both((a, k) => Gem(a, k, Oval(86, 100), 86, 100));
            case "happy": return Both((a, k) => Glow(a, k, "M-70 38Q0 -96 70 38", 48));
            case "content": return Both((a, k) => Glow(a, k, "M-70 -30Q0 92 70 -30", 48));
            case "sleepy":
                return Both((a, k) => Glow(a, k, "M-66 10H66", 44))
                    + $"<path d=\"M196 -150h42l-42 46h42\" fill=\"none\" stroke=\"{c.Light}\" stroke-width=\"11\" stroke-linecap=\"round\" stroke-linejoin=\"round\" transform=\"rotate(-7)\"/>";
            case "wink": return Gem(Left, 1, Oval(62, 100), 62, 100) + Glow(Right, 0.86, "M-70 38Q0 -96 70 38", 48);
            case "bars": return Both((a, k) => Gem(a, k, "<rect x=\"-36\" y=\"-100\" width=\"72\" height=\"200\" rx=\"34\"/>", 36, 100));
            case "side": return Both((a, k) => Gem((a.Item1 + 34, a.Item2 - 6), k, Oval(58, 98), 58, 98));
            case "angry": return Gem(Left, 1, Oval(70, 96), 70, 96, c, true, 0.3) + Gem(Right, 0.86, Oval(70, 96), 70, 96, c, true, -0.3);
            case "worried": return Gem(Left, 1, Oval(70, 96), 70, 96, c, true, -0.26) + Gem(Right, 0.86, Oval(70, 96), 70, 96, c, true, 0.26);
            case "heart": return Both((a, k) => Gem(a, k, $"<path transform=\"scale(88 98)\" d=\"{HeartD}\"/>", 88, 92, pinkish));
            case "sparkle":
                return Both((a, k) => Gem(a, k, $"<path transform=\"scale(84 112)\" d=\"{SparkD}\"/>", 84, 112, c, false)
                    + $"<circle cx=\"{Js(a.Item1 - 16 * k)}\" cy=\"{Js(a.Item2 - 22 * k)}\" r=\"{Js(12 * k)}\" fill=\"#FFF\"/>");
            case "dizzy": return Both((a, k) => Glow(a, k, "M-56 -56L56 56M56 -56L-56 56", 42));
            default:
                return Glow((22, 8), 1, "M-200 0H200", 62)
                    + "<path d=\"M-150 -6h120\" transform=\"rotate(-7)\" stroke=\"#FFF\" stroke-width=\"12\" stroke-linecap=\"round\"/>";
        }
    }

    static string MouthMarkup(string mouth, Paint c)
    {
        string Lit(string d) =>
            $"<g transform=\"translate(26 112) rotate(-7)\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"{d}\" stroke=\"{c.Deep}\" stroke-width=\"19\"/><path d=\"{d}\" transform=\"translate(1 -3)\" stroke=\"{c.Light}\" stroke-width=\"11\"/></g>";
        return mouth switch
        {
            "smile" => Lit("M-34 -8Q0 24 34 -8"),
            "open" => $"<g transform=\"translate(26 116) rotate(-7)\"><ellipse rx=\"20\" ry=\"24\" fill=\"{c.Deep}\"/><ellipse cx=\"2\" cy=\"-4\" rx=\"14\" ry=\"17\" fill=\"{c.Light}\"/></g>",
            "cat" => Lit("M-40 -8Q-20 22 0 -6Q20 22 40 -8"),
            "grille" => Lit("M-36 -12V14M-12 -12V14M12 -12V14M36 -12V14"),
            _ => "",
        };
    }

    // MARK: Robot (`robot.ts`)

    static double Turned(double a, double b) => Math.Abs(((a - b) % 360 + 540) % 360 - 180);
    static double Degrees(double t) => t * 180 / Math.PI;

    static (double, double)[] Eared() => Around(96, t =>
    {
        double a = Degrees(t), ear = Math.Max(0, 1 - Math.Min(Turned(a, -134), Turned(a, -46)) / 21);
        return (Math.Cos(t) * (1 + 0.46 * ear) * 1.06, Math.Sin(t) * (0.86 + 0.6 * ear) + 0.1);
    });

    static (double, double)[] Corners((double, double)[] list, double cut) => [.. list.SelectMany((p, i) =>
    {
        var (a, b) = (list[(i + list.Length - 1) % list.Length], list[(i + 1) % list.Length]);
        return new[] { (p.Item1 + (a.Item1 - p.Item1) * cut, p.Item2 + (a.Item2 - p.Item2) * cut), (p.Item1 + (b.Item1 - p.Item1) * cut, p.Item2 + (b.Item2 - p.Item2) * cut) };
    })];

    sealed record Model(Func<(double, double)[]> Points, double Size, (double, double) At, (double, double) Eyes,
        (double, double)? Up = null, double? Tilt = null, bool Soft = false);

    static readonly Dictionary<string, Model> Models = new()
    {
        ["blob"] = new(() => Around(40, t =>
        {
            var r = 1 + 0.04 * Math.Sin(2 * t + 1.3) + 0.025 * Math.Sin(3 * t + 0.4);
            return (r * Math.Cos(t) * 1.12, r * Math.Sin(t) * 0.92);
        }), 0.86, (522, 486), (0.14, 0.78), Soft: true),
        ["puff"] = new(() => Superellipse(1.1, 0.86, 0.42, 48), 0.86, (522, 506), (0.1, 0.8)),
        ["pebble"] = new(() => Superellipse(1.2, 0.72, 0.6, 48), 0.86, (522, 548), (0.04, 0.78)),
        ["shield"] = new(() => [.. Superellipse(1, 0.88, 0.4, 48).Select(p => (p.Item1 * (1 - 0.17 * p.Item2), p.Item2))], 0.88, (522, 500), (0.02, 0.78)),
        ["diamond"] = new(() => Corners(Around(6, t => (Math.Cos(t + Math.PI / 2) * 1.08, Math.Sin(t + Math.PI / 2) * 0.98)), 0.22), 0.9, (522, 478), (0.06, 0.78)),
        ["cat"] = new(Eared, 0.8, (522, 526), (0.22, 0.78), Up: (0, -1)),
        ["ghost"] = new(() => [.. Enumerable.Range(0, 9).Select(i =>
            {
                var t = Math.PI + i / 8.0 * Math.PI;
                return (Math.Cos(t) * 0.9, Math.Sin(t) * 0.88 - 0.12);
            }), (0.92, 0.35), (0.92, 0.86), (0.61, 0.66), (0.3, 0.9), (0, 0.7), (-0.3, 0.9), (-0.61, 0.66), (-0.92, 0.86), (-0.92, 0.35)],
            0.86, (522, 510), (-0.1, 0.78), Tilt: -3),
        ["cloud"] = new(Cloud, 0.94, (506, 524), (0.2, 0.7), Tilt: 0, Soft: true),
        ["heart"] = new(() => Around(48, t =>
        {
            var u = t + Math.PI / 2;
            return (Math.Pow(Math.Sin(u), 3) * 1.08, -(13 * Math.Cos(u) - 5 * Math.Cos(2 * u) - 2 * Math.Cos(3 * u) - Math.Cos(4 * u)) / 16 + 0.1);
        }), 0.9, (522, 474), (-0.22, 0.7), Tilt: 0),
        ["star"] = new(() => Around(10, t =>
        {
            var r = (int)Round((t + Math.PI / 2) / Tau * 10) % 2 != 0 ? 0.66 : 1.1;
            return (Math.Cos(t) * r, Math.Sin(t) * r + 0.06);
        }), 0.86, (522, 548), (0.14, 0.78), Tilt: 0),
        ["drop"] = new(() => [(0, -1.04), (0.3, -0.62), (0.7, -0.1), (0.86, 0.36), (0.64, 0.8), (0, 0.98), (-0.64, 0.8), (-0.86, 0.36), (-0.7, -0.1), (-0.3, -0.62)],
            0.8, (522, 540), (0.36, 0.8), Tilt: 0),
    };

    public sealed record Geometry(string D, string Inset, string Lights, (double, double) Antenna, (double, double) Antenna2,
        (double, double) Ear, string TuftTransform, (double, double) At, double K);

    static readonly Geometry DomeGeometry = new(Dome, Dome, DomeLights, (0, 0), (742, 262), (0, 0), "", (595, 534), 1);
    static readonly ConcurrentDictionary<string, Geometry> GeometryCache = new();

    public static Geometry RobotGeometry(string shape, int seed)
    {
        if (!Models.TryGetValue(shape, out var model)) return DomeGeometry;
        return GeometryCache.GetOrAdd($"{shape}:{(model.Soft ? seed : 0)}", _ => MakeGeometry(model, seed));
    }

    static Geometry MakeGeometry(Model model, int seed)
    {
        double r = 370 * model.Size, cx = model.At.Item1, cy = model.At.Item2, tilt = (model.Tilt ?? -5) * Math.PI / 180;
        (double, double) Turn((double, double) p) =>
            (p.Item1 * Math.Cos(tilt) - p.Item2 * Math.Sin(tilt), p.Item1 * Math.Sin(tilt) + p.Item2 * Math.Cos(tilt));
        var flat = model.Points();
        if (model.Soft) flat = Wobble(flat, seed, 0.02);
        var outline = Spline(flat).Dense;
        var across = outline.Where(p => Math.Abs(p.Item2 - model.Eyes.Item1) < 0.1).Select(p => p.Item1).ToList();
        double left = across.Count > 0 ? across.Min() : 0, right = across.Count > 0 ? across.Max() : 0;
        var tall = outline.Max(p => p.Item2) - outline.Min(p => p.Item2);
        var k = Math.Min((right - left) * r * model.Eyes.Item2 / 564, tall * r * 0.6 / 344);
        var eye = Turn((right - (right - left) * 0.035 - 564 * k / r / 2, model.Eyes.Item1));
        var unit = flat.Select(Turn).ToList();
        var (d, dense) = Spline([.. unit.Select(p => (cx + p.Item1 * r, cy + p.Item2 * r))]);
        (double, double) Pull((double, double) p, double by)
        {
            double dx = p.Item1 - cx, dy = p.Item2 - cy;
            var len = Math.Sqrt(dx * dx + dy * dy);
            if (len == 0) len = 1;
            return (p.Item1 - dx / len * by, p.Item2 - dy / len * by);
        }
        double Bearing((double, double) p) => Degrees(Math.Atan2(p.Item2 - cy, p.Item1 - cx));
        string Crescent(double from, double to, double gap, double thick)
        {
            var span = new List<(int I, (double, double) P, double A)>();
            for (var i = 0; i < dense.Count; i++)
            {
                var turned = (Bearing(dense[i]) - from) % 360 + 360;
                var a = turned % 360;
                if (a <= to - from) span.Add((i, dense[i], a));
            }
            span.Sort((x, y) => x.A != y.A ? x.A.CompareTo(y.A) : x.I.CompareTo(y.I));
            if (span.Count < 3) return "";
            var outer = span.Select(s => Pull(s.P, gap)).ToList();
            var inner = new List<(double, double)>();
            for (var i = 0; i < span.Count; i++)
            {
                var swell = Math.Pow(Math.Max(0, Math.Sin(Math.PI * i / (span.Count - 1))), 0.6);
                inner.Add(Pull(span[i].P, gap + thick * swell));
            }
            inner.Reverse();
            return "M" + string.Join("L", outer.Concat(inner).Select(p => $"{N(p.Item1)} {N(p.Item2)}")) + "Z";
        }
        var lights = Crescent(-182, -132, 26, 26) + Crescent(-172, -140, 66, 16) + Crescent(-100, -66, 30, 15)
            + Crescent(-54, -8, 26, 28) + Crescent(18, 54, 22, 14) + Crescent(70, 112, 40, 9);
        (double, double) Furthest(double dx, double dy) => dense.Skip(1).Aggregate(dense[0], (best, p) =>
            (p.Item1 - cx) * dx + (p.Item2 - cy) * dy > (best.Item1 - cx) * dx + (best.Item2 - cy) * dy ? p : best);
        var up = model.Up ?? (-0.42, -0.9);
        var top = Pull(Furthest(up.Item1, up.Item2), 26);
        var negated = -up.Item1;
        var top2 = Pull(Furthest(negated == 0 ? 0.42 : negated, up.Item2), 26);
        var side = Furthest(-1, 0.25);
        var brow = Furthest(-0.34, -0.94);
        return new Geometry(d, Spline([.. unit.Select(p => (cx + p.Item1 * (r - 24), cy + p.Item2 * (r - 24)))]).D, lights,
            (top.Item1 - 362, top.Item2 - 268), top2, (side.Item1 + 44 - 207, side.Item2 - 598),
            $"translate({N(brow.Item1 + 6)} {N(brow.Item2 + 60)}) scale({Js(Round(model.Size * 100) / 100)}) translate(-392 -262)",
            (cx + eye.Item1 * r, cy + eye.Item2 * r), k);
    }

    /// The glass the eyes sit behind, around 0,0 at the icon's size. `line` keeps the keyline's weight.
    static string VisorMarkup(string kind, Tone tone, double line, string id)
    {
        var key = $"fill=\"{Ink}\" stroke=\"#FFF\" stroke-width=\"{Js(line)}\"";
        if (kind == "goggles")
        {
            string Lens((double, double) at, double rx, double ry) =>
                $"<g transform=\"translate({Js(at.Item1)} {Js(at.Item2)}) rotate(-7)\"><ellipse rx=\"{Js(rx + 22)}\" ry=\"{Js(ry + 22)}\" {key}/><ellipse rx=\"{Js(rx)}\" ry=\"{Js(ry)}\" fill=\"{tone.Deep}\" opacity=\".36\"/><ellipse rx=\"{Js(rx)}\" ry=\"{Js(ry)}\" fill=\"none\" stroke=\"#FFF\" stroke-width=\"{N(line * 0.7)}\" opacity=\".55\"/><path d=\"M{Js(-rx * 0.8)} {Js(-ry * 0.2)}A{Js(rx)} {Js(ry)} 0 0 1 {Js(-rx * 0.1)} {Js(-ry * 0.92)}\" fill=\"none\" stroke=\"#FFF\" stroke-width=\"{Js(line * 1.4)}\" stroke-linecap=\"round\" opacity=\".5\"/></g>";
            return $"<path d=\"M{Js(Left.Item1)} {Js(Left.Item2)}L{Js(Right.Item1)} {Js(Right.Item2)}\" stroke=\"#FFF\" stroke-width=\"{Js(46 + line * 2)}\"/><path d=\"M{Js(Left.Item1)} {Js(Left.Item2)}L{Js(Right.Item1)} {Js(Right.Item2)}\" stroke=\"{Ink}\" stroke-width=\"46\"/>"
                + Lens(Left, 104, 132) + Lens(Right, 90, 116);
        }
        if (kind == "screen")
            return $"<g transform=\"rotate(-7)\"><rect x=\"-272\" y=\"-164\" width=\"544\" height=\"328\" rx=\"78\" {key}/><rect x=\"-246\" y=\"-138\" width=\"492\" height=\"276\" rx=\"54\" fill=\"{tone.Deep}\" opacity=\".4\"/><path d=\"M-246 -30L-96 -138H24L-246 60Z\" fill=\"#FFF\" opacity=\".1\"/></g>";
        if (kind == "none") return "";
        return $"<g transform=\"translate(-595 -534)\"><clipPath id=\"{id}g\"><path d=\"{VisorPath}\"/></clipPath><path d=\"{VisorPath}\" fill=\"{Ink}\"/><path d=\"M300 560L640 330H760L300 650Z\" fill=\"#FFF\" opacity=\".08\" clip-path=\"url(#{id}g)\"/><path d=\"{VisorPath}\" fill=\"none\" stroke=\"#FFF\" stroke-width=\"{Js(line)}\"/></g>";
    }

    const string ChromeTop = "#FFFFFF", ChromeMid = "#C9D0DA", ChromeLow = "#7C8592";

    /// ` transform="translate(x 0)"` for the face group, when the face rests looking right (`restLook`), else nothing.
    static string Shift(double x) => x == 0 ? "" : $" transform=\"translate({Js(x)} 0)\"";

    /// Just the robot (no tile). A finished bot smiles; one that can't be reached sleeps.
    static string RobotMarkup(HeadRecord head, Tone tone, HeadState? state, string id, double look)
    {
        var geo = RobotGeometry(head.Shape, head.Seed);
        var isDome = !Models.ContainsKey(head.Shape);
        var paint = new Paint(Ink, tone.Accent, tone.Light, tone.Deep, tone.Panel);
        string Moved((double, double) by, string inner) =>
            by.Item1 != 0 || by.Item2 != 0 ? $"<g transform=\"translate({N(by.Item1)} {N(by.Item2)})\">{inner}</g>" : inner;
        bool painted = head.Shell != "ink", chrome = head.Shell == "chrome";
        string skin = chrome ? $"url(#{id}m)" : tone.Accent, under = chrome ? ChromeLow : tone.Deep;
        var coat = painted && head.Shell != "duo" ? skin : Ink;
        var defs = $"<clipPath id=\"{id}n\"><rect y=\"700\" width=\"1024\" height=\"92\"/></clipPath>";
        if (chrome)
            defs += $"<linearGradient id=\"{id}m\" x1=\".2\" y1=\"0\" x2=\".7\" y2=\"1\"><stop offset=\"0\" stop-color=\"{ChromeTop}\"/><stop offset=\".5\" stop-color=\"{ChromeMid}\"/><stop offset=\"1\" stop-color=\"{ChromeLow}\"/></linearGradient>";
        if (painted) defs += $"<clipPath id=\"{id}s\"><path d=\"{geo.D}\"/></clipPath>";
        var edge = $"stroke=\"{Ink}\" stroke-width=\"14\" stroke-linejoin=\"round\"";
        var skull = painted
            ? $"<path d=\"{geo.D}\" fill=\"{under}\" {edge}/><g clip-path=\"url(#{id}s)\"><path d=\"{geo.D}\" fill=\"{skin}\" transform=\"translate(-22 -28)\"/></g><path d=\"{geo.D}\" fill=\"none\" {edge}/>"
            : $"<path d=\"{geo.D}\" fill=\"{Ink}\"/>";
        string Torso(string clip) => $"<path d=\"{(clip.Length == 0 ? Shoulders + Neck : Neck)}\" fill=\"{coat}\"{(coat == Ink ? "" : " " + edge)}{clip}/>";

        const string stem = "M284 160q56 26 78 108", bolt = "M286 56L384 150L338 164L392 276L282 172L330 158Z";
        var kinds = new Dictionary<string, (string, string)>
        {
            ["bulb"] = (
                $"<path d=\"{stem}\" fill=\"none\" stroke=\"{tone.Panel}\" stroke-width=\"56\" stroke-linecap=\"round\"/><circle cx=\"270\" cy=\"147\" r=\"62\" fill=\"{tone.Panel}\"/>",
                $"<path d=\"{stem}\" fill=\"none\" stroke=\"{Ink}\" stroke-width=\"40\" stroke-linecap=\"round\"/><path d=\"M322 181q30 19 46 63\" fill=\"none\" stroke=\"#FFF\" stroke-width=\"9\" stroke-linecap=\"round\"/><circle cx=\"270\" cy=\"147\" r=\"54\" fill=\"{Ink}\"/><g class=\"dh-bulb\"><circle cx=\"270\" cy=\"147\" r=\"42\" fill=\"{tone.Accent}\"/><path d=\"M306 168a42 42 0 0 1-72 0a60 60 0 0 0 72 0z\" fill=\"{tone.Deep}\"/><circle cx=\"254\" cy=\"130\" r=\"11\" fill=\"#FFF\"/></g>"),
            ["bolt"] = (
                $"<path d=\"{bolt}\" fill=\"{tone.Panel}\" stroke=\"{tone.Panel}\" stroke-width=\"44\" stroke-linejoin=\"round\"/>",
                $"<path d=\"{bolt}\" fill=\"{Ink}\" stroke=\"{Ink}\" stroke-width=\"28\" stroke-linejoin=\"round\"/><g class=\"dh-bulb\"><path d=\"{bolt}\" fill=\"{tone.Accent}\"/><path d=\"M286 56L384 150L338 164L310 110Z\" fill=\"{tone.Light}\"/></g>"),
            ["ring"] = (
                $"<ellipse cx=\"400\" cy=\"168\" rx=\"150\" ry=\"44\" transform=\"rotate(-9 400 168)\" fill=\"none\" stroke=\"{tone.Panel}\" stroke-width=\"58\"/>",
                $"<g transform=\"rotate(-9 400 168)\" fill=\"none\"><ellipse cx=\"400\" cy=\"168\" rx=\"150\" ry=\"44\" stroke=\"{Ink}\" stroke-width=\"42\"/><g class=\"dh-bulb\"><ellipse cx=\"400\" cy=\"168\" rx=\"150\" ry=\"44\" stroke=\"{tone.Accent}\" stroke-width=\"22\"/><path d=\"M262 150a150 44 0 0 1 150-26\" stroke=\"{tone.Light}\" stroke-width=\"9\" stroke-linecap=\"round\"/></g></g>"),
        };
        var hasKind = kinds.TryGetValue(head.Antenna == "twin" ? "bulb" : head.Antenna, out var kind);
        string Second(string inner) => head.Antenna == "twin"
            ? $"<g transform=\"translate({N(geo.Antenna2.Item1 + 362 * 0.8)} {N(geo.Antenna2.Item2 - 268 * 0.8)}) scale(-.8 .8)\">{inner}</g>" : "";
        var floats = head.Antenna == "ring";
        var antennaHalo = hasKind ? Moved(geo.Antenna, kind.Item1) + Second(kind.Item1) : "";
        var antenna = hasKind ? Moved(geo.Antenna, kind.Item2) + Second(kind.Item2) : "";

        var ears = new Dictionary<string, string>
        {
            ["headset"] = $"<path d=\"M246 594a58 95-4 1 1-116 8 58 95-4 1 1 116-8zm27 6a66 109 2 1 1-132-4 66 109 2 1 1 132 4z\" fill=\"{tone.Panel}\" stroke=\"{tone.Panel}\" stroke-width=\"16\" stroke-linejoin=\"round\"/><path d=\"M273 600a66 109 2 1 1-132-4 66 109 2 1 1 132 4z\" fill=\"{Ink}\"/><path d=\"M246 594a58 95-4 1 1-116 8 58 95-4 1 1 116-8z\" fill=\"{Ink}\"/><path d=\"M148 539a51 88-4 1 1 61 142 51 88-4 0 0-61-142z\" fill=\"#FFF\"/>",
            ["bolts"] = $"<g transform=\"rotate(-6 190 600)\"><rect x=\"118\" y=\"548\" width=\"112\" height=\"104\" rx=\"26\" fill=\"{tone.Panel}\" stroke=\"{tone.Panel}\" stroke-width=\"16\"/><rect x=\"118\" y=\"548\" width=\"112\" height=\"104\" rx=\"26\" fill=\"{Ink}\"/><rect x=\"96\" y=\"574\" width=\"46\" height=\"52\" rx=\"14\" fill=\"{Ink}\" stroke=\"{tone.Panel}\" stroke-width=\"8\"/><path d=\"M158 566v68M186 566v68\" stroke=\"#FFF\" stroke-width=\"9\" stroke-linecap=\"round\"/><circle cx=\"119\" cy=\"600\" r=\"9\" fill=\"{tone.Accent}\"/></g>",
            ["fins"] = $"<path d=\"M236 520L74 452Q116 596 226 676Z\" fill=\"{tone.Panel}\" stroke=\"{tone.Panel}\" stroke-width=\"30\" stroke-linejoin=\"round\"/><path d=\"M236 520L74 452Q116 596 226 676Z\" fill=\"{Ink}\" stroke=\"{Ink}\" stroke-width=\"12\" stroke-linejoin=\"round\"/><path d=\"M214 532L112 490Q140 572 206 636Z\" fill=\"{tone.Accent}\"/><path d=\"M196 528L118 494Q128 528 150 560Z\" fill=\"{tone.Light}\"/>",
        };
        var ear = ears.TryGetValue(head.EarsKind, out var e) ? Moved(geo.Ear, e) : "";
        var soft = painted ? " opacity=\".85\"" : "";
        var lights = isDome
            ? $"<path d=\"{Tuft}{geo.Lights}\" fill=\"#FFF\"{soft}/>"
            : $"<clipPath id=\"{id}h\"><path d=\"{geo.Inset}\"/></clipPath><path d=\"{geo.Lights}\" fill=\"#FFF\"{soft}/><g clip-path=\"url(#{id}h)\"{soft}><path d=\"{Tuft}\" transform=\"{geo.TuftTransform}\" fill=\"#FFF\"/></g>";
        var blush = head.Blush
            ? "<g fill=\"#FF7FA8\" transform=\"rotate(-7)\"><ellipse cx=\"-222\" cy=\"104\" rx=\"30\" ry=\"17\"/><ellipse cx=\"258\" cy=\"104\" rx=\"24\" ry=\"15\"/></g>" : "";
        var eyes = state == HeadState.Done ? "happy" : state == HeadState.Offline ? "sleepy" : head.Face;
        var opener = isDome ? "<g>" : $"<clipPath id=\"{id}v\"><path d=\"{geo.D}\"/></clipPath><g clip-path=\"url(#{id}v)\">";
        var face = opener + $"<g transform=\"translate({N(geo.At.Item1)} {N(geo.At.Item2)}) scale({Js(Round(geo.K * 100) / 100)})\">"
            + VisorMarkup(eyes == "scanner" && head.Visor == "goggles" ? "band" : head.Visor, tone, Round(8 / geo.K * 1.15), id)
            + $"<g class=\"dh-face\"{Shift(look)}>{FaceMarkup(eyes, paint, id)}</g>{MouthMarkup(head.Mouth, paint)}{blush}</g></g>";
        return defs + Torso("") + $"<path d=\"{ShoulderLights}\" fill=\"#FFF\"{(painted && head.Shell != "duo" ? " opacity=\".8\"" : "")}/>"
            + $"<g class=\"dh-body\">{(floats ? "" : antennaHalo)}<path d=\"{geo.D}\" fill=\"{tone.Panel}\" stroke=\"{tone.Panel}\" stroke-width=\"{(painted ? 30 : 16)}\" stroke-linejoin=\"round\"/>{(floats ? "" : antenna)}"
            + Torso($" clip-path=\"url(#{id}n)\"") + skull
            + $"<path d=\"{NeckLightA}\" fill=\"{(coat == Ink ? tone.Panel : "#FFF")}\"/><path d=\"{NeckLightB}\" fill=\"#FFF\"/>{lights}{ear}{face}{(floats ? antennaHalo + antenna : "")}</g>";
    }

    // MARK: Tiles (`render.ts:29-37`)

    sealed record Made(string Frame, string Panel, string Defs, string Body);
    sealed record Ground(string Frame, string Panel, string Mark, bool Dark, string Defs);

    static Ground GroundOf(HeadRecord head, Tone tone, string id)
    {
        if (head.Tile == "light") return new(Ink, "#F7F5F0", Ink, false, "");
        if (head.Tile == "color") return new(Ink, tone.Panel, Ink, false, "");
        return new("#000", $"url(#{id}k)", "#FFFFFF", true,
            $"<radialGradient id=\"{id}k\" cx=\".5\" cy=\".12\" r=\"1\"><stop offset=\"0\" stop-color=\"#2B2B33\"/><stop offset=\".6\" stop-color=\"#121216\"/><stop offset=\"1\" stop-color=\"#08080A\"/></radialGradient>");
    }

    // MARK: Dots (`render.ts:39-135`)

    static readonly Dictionary<string, (string, string)> LampEyes = new()
    {
        ["visor"] = (".........|.1111111.|.1111111.|.........|.........", ".....|11111|....."),
        ["pill"] = (".........|..11.11..|..11.11..|..11.11..|.........", ".....|.1.1.|.1.1."),
        ["dots"] = (".........|.........|..1...1..|.........|.........", ".....|.1.1.|....."),
        ["surprised"] = (".........|.111.111.|.111.111.|.111.111.|.........", "11.11|11.11|....."),
        ["happy"] = (".........|..1...1..|.1.1.1.1.|.........|.........", ".1.1.|1.1.1|....."),
        ["content"] = (".........|.........|.1.1.1.1.|..1...1..|.........", ".....|1.1.1|.1.1."),
        ["wink"] = (".........|..11.....|..11.111.|..11.....|.........", ".....|.1...|.1.11"),
        ["sleepy"] = (".........|.........|.........|.111.111.|.........", ".....|.....|11.11"),
        ["bars"] = (".........|.........|.111.111.|.111.111.|.........", ".....|11.11|....."),
        ["side"] = (".........|.111.111.|...1...1.|...1...1.|.........", "11.11|.1..1|....."),
        ["angry"] = (".........|.1.....1.|.11...11.|.111.111.|.........", "1...1|11.11|....."),
        ["worried"] = (".........|...1.1...|..11.11..|.111.111.|.........", ".1.1.|11.11|....."),
        ["heart"] = (".........|.4.4.4.4.|.444.444.|..4...4..|.........", "4.4.4|44444|.4.4."),
        ["sparkle"] = (".........|..1...1..|.111.111.|..1...1..|.........", ".1.1.|11111|.1.1."),
        ["dizzy"] = (".........|.1.1.1.1.|..1...1..|.1.1.1.1.|.........", "1.1.1|.1.1.|1.1.1"),
        ["scanner"] = (".........|.........|.2212222.|.........|.........", ".....|22122|....."),
    };
    static readonly Dictionary<string, (string, string)> LampMouths = new()
    {
        ["none"] = (".........|.........", ".....|....."),
        ["smile"] = ("..2...2..|...222...", "2...2|.222."),
        ["open"] = ("...222...|...222...", ".222.|.222."),
        ["cat"] = (".2.2.2.2.|..2.2.2..", "2.2.2|.2.2."),
        ["grille"] = ("...222...|.........", ".222.|....."),
    };

    struct Lamp { public double V; public bool Hot, Hole, Pink; }

    static Made Dots(HeadRecord head, Tone tone, string id, bool compact, HeadState? state, double look, bool d2d)
    {
        var small = compact;
        int grid = small ? 5 : 9;
        double pitch = small ? 158.0 : 86.0, mid = (grid - 1) / 2.0, step = small ? 2.0 : 1.0;
        var g = GroundOf(head, tone, id);
        var random = new SeededRandom(unchecked((uint)head.Seed));
        double phase = random.Next() * Tau, twist = random.Next();
        var plain = head.Color is "ink" or "paper";
        var accent = plain ? g.Mark : g.Dark ? tone.Accent : tone.Deep;
        var lamp = new Lamp[grid, grid];
        void Each(Func<double, double, double, double, (double, bool)> set)
        {
            for (var row = 0; row < grid; row++)
                for (var col = 0; col < grid; col++)
                {
                    double x = (col - mid) * step, y = (row - mid) * step;
                    var (v, hot) = set(x, y, Math.Sqrt(x * x + y * y), Math.Atan2(y, x));
                    lamp[row, col].V = Math.Max(0, Math.Min(1, v));
                    lamp[row, col].Hot = hot;
                }
        }
        var face = head.Eyes && head.Pattern is "ring" or "bloom";
        switch (head.Pattern)
        {
            case "grid":
                {
                    double ox = (random.Next() - 0.5) * 5, oy = (random.Next() - 0.5) * 5, reach = 1.5 + twist * 1.6;
                    Each((x, y, _, _) =>
                    {
                        double dx = x - ox, dy = y - oy;
                        var v = 0.5 + 0.5 * Math.Cos(Math.Sqrt(dx * dx + dy * dy) / reach * Math.PI + phase);
                        return (0.12 + 0.88 * v, v > 0.86);
                    });
                    break;
                }
            case "bloom":
                {
                    var band = 1 + Math.Floor(twist * 3);
                    Each((x, y, d, _) =>
                        (d > 4.4 || (face && Math.Abs(x) < 2.5 && Math.Abs(y) < 1.5) ? 0 : Math.Pow(1 - d / 4.8, 0.7), !face && Round(d) == band));
                    break;
                }
            case "ring":
                Each((_, _, d, a) =>
                {
                    var sweep = ((a - phase) % Tau + Tau) % Tau / Tau;
                    var on = Math.Exp(-Math.Pow((d - (small ? 4 : 3.4)) / (small ? 1.1 : 0.62), 2));
                    return (on * (0.22 + 0.78 * sweep), on > 0.5 && sweep > 0.86);
                });
                break;
            case "spark":
                {
                    var sharp = 0.72 + twist * 0.14;
                    Each((x, y, d, _) =>
                    {
                        var v = 1 - (Math.Pow(Math.Abs(x), sharp) + Math.Pow(Math.Abs(y), sharp)) / Math.Pow(4.4, sharp);
                        return (v <= 0 ? 0 : 0.2 + 0.8 * Math.Pow(v, 0.8), d < 1.2);
                    });
                    break;
                }
            case "wave":
                Each((x, y, _, _) =>
                {
                    var tall = 0.4 + 3.6 * Math.Abs(Math.Sin(x * (0.6 + twist * 0.5) + phase)) * (1 - Math.Abs(x) * 0.1);
                    return (Math.Abs(y) <= tall ? 1 - Math.Abs(y) * 0.13 : 0, x == 0);
                });
                break;
            default:
                {
                    // A face: the head's eyes over its mouth, with pink cheeks when it blushes.
                    List<string> Part(Dictionary<string, (string, string)> table, string key)
                    {
                        var entry = table.TryGetValue(key, out var en) ? en : table.Values.First();
                        return [.. (small ? entry.Item2 : entry.Item1).Split('|')];
                    }
                    var rows = small ? [.. Part(LampEyes, head.Face), .. Part(LampMouths, head.Mouth)]
                        : new List<string> { "........." }.Concat(Part(LampEyes, head.Face)).Concat(Part(LampMouths, head.Mouth)).Append(".........").ToList();
                    if (head.Blush)
                    {
                        foreach (var col in small ? new[] { 0, 4 } : [1, 7])
                        {
                            var row = small ? 2 : 5;
                            var chars = rows[row].ToCharArray();
                            if (chars[col] == '.') { chars[col] = '3'; rows[row] = new string(chars); }
                        }
                    }
                    for (var row = 0; row < grid; row++)
                    {
                        var chars = rows[row];
                        for (var col = 0; col < grid; col++)
                        {
                            var mark = chars[col];
                            lamp[row, col].V = mark == '.' ? 0 : mark == '2' ? 0.62 : mark == '3' ? 0.5 : 1;
                            lamp[row, col].Hot = mark is '1' or '4';
                            lamp[row, col].Pink = mark > '2';
                        }
                    }
                    break;
                }
        }
        int[] eyeRows = small ? [2] : [3, 4];
        if (face) foreach (var col in small ? new[] { 1, 3 } : [3, 5]) foreach (var row in eyeRows) lamp[row, col].Hole = true;
        var moving = state is HeadState.Thinking or HeadState.Speaking;
        StringBuilder dim = new(), lit = new(), hot = new(), cheek = new(), love = new();
        for (var row = 0; row < grid; row++)
        {
            for (var col = 0; col < grid; col++)
            {
                var cell = lamp[row, col];
                double x = 512 + (col - mid) * pitch, y = 512 + (row - mid) * pitch;
                if (cell.Hole)
                {
                    if (row == eyeRows[0])
                        hot.Append($"<rect x=\"{Js(x - pitch * 0.32)}\" y=\"{Js(y - pitch * 0.32)}\" width=\"{Js(N1(pitch * 0.64))}\" height=\"{Js(N1(pitch * (eyeRows.Length - 1) + pitch * 0.64))}\" rx=\"{Js(N1(pitch * 0.32))}\"/>");
                    continue;
                }
                if (cell.V < 0.06) { dim.Append($"<circle cx=\"{Js(x)}\" cy=\"{Js(y)}\" r=\"{Js(N1(pitch * 0.08))}\"/>"); continue; }
                string place;
                if (!moving) place = "";
                else if (state == HeadState.Thinking)
                {
                    double dc = col - mid, dr = row - mid;
                    place = $" style=\"--i:{Js(Round(Math.Sqrt(dc * dc + dr * dr) * step))}\"";
                }
                else place = $" style=\"--i:{col}\"";
                var dot = $"<circle cx=\"{Js(x)}\" cy=\"{Js(y)}\" r=\"{Js(N1(pitch * (0.15 + 0.26 * cell.V)))}\"{place}/>";
                if (cell.Pink) { if (cell.Hot) love.Append(dot); else cheek.Append(dot); }
                else if (cell.Hot) hot.Append(dot);
                else lit.Append(dot);
            }
        }
        var glow = g.Dark && !plain && !d2d ? $"<g fill=\"{accent}\" filter=\"url(#{id}g)\" opacity=\".75\">{hot}</g>" : "";
        var faceClass = face || head.Pattern == "face";
        var body = $"<g fill=\"{g.Mark}\" opacity=\"{(g.Dark ? "0.16" : "0.13")}\">{dim}</g><g class=\"dh-lamps\" fill=\"{g.Mark}\">{lit}</g>{glow}<g class=\"dh-lamps{(faceClass ? " dh-face" : "")}\" fill=\"{accent}\"{(faceClass ? Shift(look) : "")}>{hot}</g>";
        if (cheek.Length > 0) body += $"<g class=\"dh-lamps\" fill=\"#FF7FA8\">{cheek}</g>";
        if (love.Length > 0) body += $"<g class=\"dh-lamps dh-face\" fill=\"#FF4D8D\"{Shift(look)}>{love}</g>";
        return new Made(g.Frame, g.Panel,
            g.Defs + (d2d ? "" : $"<filter id=\"{id}g\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feGaussianBlur stdDeviation=\"20\"/></filter>"),
            body);
    }

    /// Whether a themed head draws eyes (`dh-face`): robots and pixel creatures always, an orb or a ring/bloom pattern
    /// with Eyes on, a dots face; never an emoji (HeadView.hasFace).
    public static bool HasFace(HeadRecord record) => record.Theme switch
    {
        "robot" or "pixel" => true,
        "orb" => record.Eyes,
        "dots" => record.Pattern == "face" || (record.Eyes && record.Pattern is "ring" or "bloom"),
        _ => false,
    };

    /// How far to the right a drawn head's eyes rest, in the picture's 1024 units: every face looks to the right, at the
    /// words beside it (owner, 2026-11-16).
    public static double RestLook(HeadRecord head, bool compact) => head.Theme switch
    {
        "robot" => 22 * Round(RobotGeometry(head.Shape, head.Seed).K * 100) / 100,
        "dots" => HasFace(head) ? (compact ? 158 : 86) : 0,
        "orb" => head.Eyes ? 34 : 0,
        _ => 0,
    };

    // MARK: Orb (`render.ts:137-166`)

    static readonly Dictionary<string, string[]> Neighbour = new()
    {
        ["ink"] = ["#2EC4B6", "#2770D9", "#795CDF"], ["mint"] = ["#078267", "#2770D9", "#D7F36B"], ["teal"] = ["#057E93", "#795CDF", "#6BF3C8"],
        ["sky"] = ["#2770D9", "#795CDF", "#22D8C8"], ["lilac"] = ["#795CDF", "#CC3582", "#2770D9"], ["pink"] = ["#CC3582", "#C15003", "#795CDF"],
        ["coral"] = ["#CD422C", "#C15003", "#CC3582"], ["peach"] = ["#C15003", "#CC3582", "#FF8A3D"], ["butter"] = ["#C15003", "#CC3582", "#FF8A3D"],
        ["paper"] = ["#D9D2C2", "#FFFFFF", "#A39A86"],
    };

    /// A soft spot for Direct2D, which has no blur: a radial gradient from `colour` at `opacity` to nothing.
    static string Soft(string gid, string colour, double opacity, double inner) =>
        $"<radialGradient id=\"{gid}\"><stop offset=\"0\" stop-color=\"{colour}\" stop-opacity=\"{Js(opacity)}\"/><stop offset=\"{Js(inner)}\" stop-color=\"{colour}\" stop-opacity=\"{Js(opacity * 0.7)}\"/><stop offset=\"1\" stop-color=\"{colour}\" stop-opacity=\"0\"/></radialGradient>";

    static Made Orb(HeadRecord head, Tone tone, string id, bool plain, double look, bool d2d)
    {
        var g = GroundOf(head, tone, id);
        var random = new SeededRandom(unchecked((uint)head.Seed));
        var hues = Neighbour.TryGetValue(head.Color, out var h) ? h : [tone.Accent, tone.Light, tone.Deep];
        var blobs = new StringBuilder();
        var turn = random.Next() * Tau;
        for (var i = 0; i < 4; i++)
        {
            double angle = turn + i * Tau / 4 + (random.Next() - 0.5) * 0.8, reach = 150 + random.Next() * 130;
            string cx = Js(N1(512 + Math.Cos(angle) * reach)), cy = Js(N1(512 + Math.Sin(angle) * reach));
            double rxv = N1(190 + random.Next() * 90), ryv = N1(140 + random.Next() * 70);
            var rot = Js(N1(random.Next() * 180));
            if (d2d)
                blobs.Append($"<ellipse cx=\"{cx}\" cy=\"{cy}\" rx=\"{Js(rxv + 90)}\" ry=\"{Js(ryv + 90)}\" transform=\"rotate({rot} 512 512)\" fill=\"url(#{id}q{1 + i % 2})\"/>");
            else
                blobs.Append($"<ellipse cx=\"{cx}\" cy=\"{cy}\" rx=\"{Js(rxv)}\" ry=\"{Js(ryv)}\" transform=\"rotate({rot} 512 512)\" fill=\"{hues[1 + i % 2]}\" opacity=\".9\"/>");
        }
        var defs = g.Defs + $"<clipPath id=\"{id}c\"><circle cx=\"512\" cy=\"512\" r=\"340\"/></clipPath>"
            + (d2d
                ? Soft($"{id}q1", hues[1], 0.9, 0.55) + Soft($"{id}q2", hues[2], 0.9, 0.55) + Soft($"{id}qw", hues[0], 0.6, 0.7)
                    + Soft($"{id}qs", Ink, 0.22, 0.5) + Soft($"{id}qh", "#FFF", 0.85, 0.6)
                : $"<filter id=\"{id}b\" x=\"-60%\" y=\"-60%\" width=\"220%\" height=\"220%\"><feGaussianBlur stdDeviation=\"78\"/></filter><filter id=\"{id}f\" x=\"-60%\" y=\"-60%\" width=\"220%\" height=\"220%\"><feGaussianBlur stdDeviation=\"16\"/></filter><filter id=\"{id}w\" x=\"-60%\" y=\"-60%\" width=\"220%\" height=\"220%\"><feGaussianBlur stdDeviation=\"46\"/></filter>")
            + $"<radialGradient id=\"{id}e\" cx=\".4\" cy=\".34\" r=\".72\"><stop offset=\".62\" stop-color=\"#000\" stop-opacity=\"0\"/><stop offset=\"1\" stop-color=\"#000\" stop-opacity=\".5\"/></radialGradient>"
            + $"<radialGradient id=\"{id}r\" cx=\".36\" cy=\".3\" r=\".78\"><stop offset=\".8\" stop-color=\"#FFF\" stop-opacity=\"0\"/><stop offset=\".95\" stop-color=\"#FFF\" stop-opacity=\".5\"/><stop offset=\"1\" stop-color=\"#FFF\" stop-opacity=\".1\"/></radialGradient>";
        string Eye(string fill, double dy, double opacity) =>
            $"<g fill=\"{fill}\" opacity=\"{Js(opacity)}\" transform=\"translate(0 {Js(dy)})\"><rect x=\"412\" y=\"462\" width=\"54\" height=\"140\" rx=\"27\"/><rect x=\"558\" y=\"462\" width=\"54\" height=\"140\" rx=\"27\"/></g>";
        var body = g.Dark
            ? (d2d ? $"<circle cx=\"512\" cy=\"512\" r=\"440\" fill=\"url(#{id}qw)\"/>"
                : $"<circle cx=\"512\" cy=\"512\" r=\"350\" fill=\"{hues[0]}\" filter=\"url(#{id}w)\" opacity=\".6\"/>")
            : (d2d ? $"<ellipse cx=\"512\" cy=\"892\" rx=\"282\" ry=\"62\" fill=\"url(#{id}qs)\"/>"
                : $"<ellipse cx=\"512\" cy=\"892\" rx=\"250\" ry=\"30\" fill=\"{Ink}\" filter=\"url(#{id}f)\" opacity=\".22\"/>");
        body += $"<g clip-path=\"url(#{id}c)\"><rect width=\"1024\" height=\"1024\" fill=\"{hues[0]}\"/>"
            + (d2d ? $"<g>{blobs}</g>" : $"<g filter=\"url(#{id}b)\"><g class=\"dh-drift\">{blobs}</g></g>")
            + $"<circle cx=\"512\" cy=\"512\" r=\"340\" fill=\"url(#{id}e)\"/><circle cx=\"512\" cy=\"512\" r=\"340\" fill=\"url(#{id}r)\"/>"
            + (d2d ? $"<ellipse cx=\"408\" cy=\"330\" rx=\"182\" ry=\"106\" transform=\"rotate(-30 408 330)\" fill=\"url(#{id}qh)\"/></g>"
                : $"<ellipse cx=\"408\" cy=\"330\" rx=\"150\" ry=\"74\" transform=\"rotate(-30 408 330)\" fill=\"#FFF\" filter=\"url(#{id}f)\" opacity=\".85\"/></g>")
            + "<ellipse cx=\"372\" cy=\"322\" rx=\"46\" ry=\"26\" transform=\"rotate(-30 372 322)\" fill=\"#FFF\" opacity=\".95\"/>";
        if (head.Eyes)
            body += plain ? $"<g class=\"dh-face\"{Shift(look)}>{Eye(Ink, 10, 0.22)}{Eye("#FFF", 0, 1)}</g>"
                : Eye(Ink, 10, 0.22) + $"<g class=\"dh-face\"{Shift(look)}>{Eye("#FFF", 0, 1)}</g>";
        return new Made(g.Frame, g.Panel, defs, body);
    }

    // MARK: Pixel (`render.ts:168-227`)

    static readonly int[][] Bodies =
    [
        [2, 3, 4, 4, 4, 4, 4, 3], // round
        [3, 4, 4, 4, 4, 4, 4, 4], // ghost
        [3, 4, 4, 4, 4, 4, 3], // block
        [3, 4, 5, 5, 5, 5, 4], // wide
        [2, 3, 3, 3, 3, 3, 3, 3, 2], // tall
    ];

    static Made Pixel(HeadRecord head, Tone tone, string id, bool plain)
    {
        var g = GroundOf(head, tone, id);
        var random = new SeededRandom(unchecked((uint)head.Seed));
        int Pick(int count) => (int)Math.Floor(random.Next() * count);
        const int size = 17, mid = 8;
        const double cell = 48.0;
        var origin = 512 - size * cell / 2;
        var on = new bool[size, size];
        void Put(int row, int col)
        {
            if (row >= 0 && row < size && col >= 0 && col <= mid) { on[row, mid - col] = true; on[row, mid + col] = true; }
        }
        var body = Bodies[Pick(Bodies.Length)];
        const int top = 5;
        var bottom = top + body.Length - 1;
        for (var i = 0; i < body.Length; i++) for (var col = 0; col <= body[i]; col++) Put(top + i, col);
        var wide = body[1];
        switch (Pick(5))
        {
            case 0: Put(top - 1, 0); Put(top - 2, 0); Put(top - 3, 0); Put(top - 3, 1); break;
            case 1: Put(top - 1, 2); Put(top - 2, 3); Put(top - 3, 3); break;
            case 2: Put(top - 1, wide); Put(top - 1, wide - 1); Put(top - 2, wide); break;
            case 3: Put(top - 1, wide - 1); Put(top - 1, wide - 2); Put(top - 2, wide - 1); Put(top - 2, wide - 2); break;
        }
        int arm = top + 4, reach = body[4];
        switch (Pick(4))
        {
            case 0: Put(arm, reach + 1); Put(arm, reach + 2); break;
            case 1: Put(arm, reach + 1); Put(arm - 1, reach + 2); Put(arm - 2, reach + 2); break;
            case 2: Put(arm, reach + 1); Put(arm + 1, reach + 2); break;
        }
        var feet = body[^1];
        switch (Pick(4))
        {
            case 0: Put(bottom + 1, 1); Put(bottom + 2, 1); Put(bottom + 2, 2); break;
            case 1: for (var col = 0; col <= feet; col += 2) Put(bottom + 1, col); break;
            case 2: Put(bottom + 1, 0); Put(bottom + 1, 2); Put(bottom + 1, feet); Put(bottom + 2, feet); break;
            default: Put(bottom + 1, 2); Put(bottom + 1, 1); break;
        }
        var inkColor = g.Dark ? "#000" : Ink;
        var fill = tone.Accent;
        const int eyeRow = top + 2, eyeCol = 2;
        var drawnTall = random.Next() < 0.6;
        var drawnMouth = Pick(3);
        var belly = random.Next() < 0.5;
        var tallEyes = drawnTall || plain;
        var mouth = plain ? 2 : drawnMouth;
        StringBuilder outline = new(), cells = new(), light = new(), shade = new(), tummy = new();
        string Box(int col, int row, double w = 1, double h = 1) =>
            $"M{Js(origin + col * cell)} {Js(origin + row * cell)}h{Js(cell * w)}v{Js(cell * h)}h{Js(-cell * w)}z";
        bool At(int row, int col) => row >= 0 && row < size && col >= 0 && col < size && on[row, col];
        for (var row = -1; row <= size; row++)
        {
            for (var col = -1; col <= size; col++)
            {
                if (At(row, col))
                {
                    cells.Append(Box(col, row));
                    var thick = (At(row, col - 1) && At(row, col + 1)) || (At(row - 1, col) && At(row + 1, col) && (At(row, col - 1) || At(row, col + 1)));
                    if (!thick) continue;
                    if ((!At(row - 1, col) && At(row + 1, col)) || (!At(row, col - 1) && col < mid && At(row - 1, col))) light.Append(Box(col, row));
                    else if ((!At(row + 1, col) && At(row - 1, col)) || (!At(row, col + 1) && col > mid)) shade.Append(Box(col, row));
                    else if (belly && row > eyeRow + 2 && row < bottom && Math.Abs(col - mid) <= 1) tummy.Append(Box(col, row));
                }
                else
                {
                    var near = false;
                    for (var dy = -1; dy <= 1 && !near; dy++) for (var dx = -1; dx <= 1 && !near; dx++) if (At(row + dy, col + dx)) near = true;
                    if (near) outline.Append(Box(col, row));
                }
            }
        }
        string Eye(int col) =>
            $"<path d=\"{Box(col, eyeRow, 1, tallEyes ? 2 : 1)}\" fill=\"{inkColor}\"/><rect x=\"{Js(plain ? origin + (col + 1) * cell - 25 : origin + col * cell + 8)}\" y=\"{Js(origin + eyeRow * cell + 8)}\" width=\"17\" height=\"17\" fill=\"#FFF\"/>";
        var smile = mouth == 0 ? Box(mid - 1, eyeRow + 3, 3, 1) : mouth == 1 ? Box(mid, eyeRow + 3) : "";
        var cheeks = random.Next() < 0.4 && !plain ? $"<path d=\"{Box(mid - 4, eyeRow + 2)}{Box(mid + 4, eyeRow + 2)}\" fill=\"#FF7FA8\" opacity=\".85\"/>" : "";
        var rows = Enumerable.Range(0, size).Where(r => Enumerable.Range(0, size).Any(c => on[r, c])).ToList();
        var lift = (size - 1 - rows[0] - rows[^1]) * cell / 2;
        return new Made(g.Frame, g.Panel, g.Defs,
            $"<g shape-rendering=\"crispEdges\" transform=\"translate(0 {Js(N1(lift))})\">{(g.Dark ? "" : $"<path d=\"{outline}\" fill=\"{inkColor}\"/>")}<path d=\"{cells}\" fill=\"{fill}\"/><path d=\"{light}\" fill=\"{tone.Light}\" opacity=\".62\"/><path d=\"{shade}\" fill=\"{tone.Deep}\"/><path d=\"{tummy}\" fill=\"{tone.Light}\" opacity=\".7\"/>"
            + $"{cheeks}<g class=\"dh-face\">{Eye(mid - eyeCol)}{Eye(mid + eyeCol)}</g><path d=\"{smile}\" fill=\"{inkColor}\"/></g>");
    }

    // MARK: Emoji (`render.ts:229-240`)

    public static string EscapeText(string text)
    {
        var o = new StringBuilder();
        foreach (var r in text.EnumerateRunes())
        {
            if (r.Value is '&' or '<' or '>' or '"' or '\'') o.Append($"&#{r.Value};");
            else o.Append(r.ToString());
        }
        return o.ToString();
    }

    /// The words an Emoji head shows, for a renderer that draws the text itself (Direct2D's SVG has no text).
    public sealed record GlyphLabel(string Text, bool Emoji, string Fill, double FontSize, double CentreY, bool Bold);

    public static GlyphLabel Label(HeadRecord head)
    {
        var tone = ToneOf(head.Color);
        var g = GroundOf(head, tone, "x");
        var text = HeadRecord.CleanGlyph(head.Glyph);
        var emoji = HeadRecord.IsEmoji(text);
        if (emoji) return new GlyphLabel(text, true, Ink, 520, 500, false);
        var fill = g.Dark ? (head.Color == "ink" ? "#FFF" : tone.Accent) : Ink;
        return new GlyphLabel(text, false, fill, HeadRecord.TextElements(text).Count > 1 ? 400 : 560, 524, true);
    }

    static Made Glyph(HeadRecord head, Tone tone, string id, bool d2d)
    {
        var g = GroundOf(head, tone, id);
        var label = Label(head);
        string top = head.Tile == "color" ? tone.Light : "#FFFFFF", bottom = head.Tile == "color" ? tone.Accent : "#E9E4D8";
        var defs = g.Defs + $"<linearGradient id=\"{id}t\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"{top}\"/><stop offset=\"1\" stop-color=\"{bottom}\"/></linearGradient>"
            + (d2d ? Soft($"{id}qs", "#000", g.Dark ? 0.6 : 0.2, 0.5) : $"<filter id=\"{id}s\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\"><feGaussianBlur stdDeviation=\"18\"/></filter>");
        var body = (g.Dark ? "" : $"<rect width=\"1024\" height=\"1024\" fill=\"url(#{id}t)\"/>")
            + (d2d ? $"<ellipse cx=\"512\" cy=\"838\" rx=\"256\" ry=\"62\" fill=\"url(#{id}qs)\"/>"
                : $"<ellipse cx=\"512\" cy=\"838\" rx=\"220\" ry=\"26\" fill=\"#000\" filter=\"url(#{id}s)\" opacity=\"{(g.Dark ? "0.6" : "0.2")}\"/>");
        if (!d2d)
        {
            if (label.Emoji)
                body += $"<text x=\"512\" y=\"500\" text-anchor=\"middle\" dominant-baseline=\"central\" font-size=\"520\">{EscapeText(label.Text)}</text>";
            else
                body += $"<text x=\"512\" y=\"524\" text-anchor=\"middle\" dominant-baseline=\"central\" font-family=\"ui-rounded,-apple-system,system-ui,sans-serif\" font-weight=\"800\" font-size=\"{Js(label.FontSize)}\" letter-spacing=\"-12\" fill=\"{label.Fill}\">{EscapeText(label.Text)}</text>";
        }
        return new Made(g.Frame, g.Panel, defs, body);
    }

    // MARK: headSvg (`render.ts:250-264`)

    /// The themes this file draws (Shapes is HeadGeometry's; Character was removed by the owner).
    public static readonly HashSet<string> DrawnThemes = ["robot", "dots", "orb", "pixel", "glyph"];

    /// The whole picture as an SVG document, in the icon's 1024 space. `id` prefixes every def.
    /// `plain` (the app's own drawing, `Head.Plain`): eyes only, always the normal ones. `restLook`: the eyes drawn over to
    /// the right as the app shows a head at rest (the Mac draws the face layer moved; here the face group is). `d2d`: for
    /// Direct2D's SVG renderer (no filters, no text, no CSS hooks): soft gradients stand in for the blurs.
    public static string Svg(HeadRecord head, HeadState? state = null, bool compact = false, string id = "dh1", string robotId = "rb1",
        bool plain = false, bool restLook = false, bool d2d = false)
    {
        if (plain) head = head.Plain;
        var tone = ToneOf(head.Color);
        double look = 0;
        if (restLook && state is null or HeadState.Idle)
            look = head.Theme switch { "robot" => 22, "dots" or "orb" => RestLook(head, compact), _ => 0 };
        var made = head.Theme switch
        {
            "dots" => Dots(head, tone, id, compact, state, look, d2d),
            "orb" => Orb(head, tone, id, plain, look, d2d),
            "pixel" => Pixel(head, tone, id, plain),
            "glyph" => Glyph(head, tone, id, d2d),
            _ => new Made(Ink, tone.Panel, "", RobotMarkup(head, tone, plain ? null : state, robotId, look)),
        };
        var body = head.Theme is "dots" or "orb" or "pixel" or "glyph" ? $"<g class=\"dh-body\">{made.Body}</g>" : made.Body;
        var stated = state is { } st && st != HeadState.Idle ? $" data-state=\"{HeadWire.Name(st)}\"" : "";
        var theme = DrawnThemes.Contains(head.Theme) ? head.Theme : "robot";
        var svg = $"<svg class=\"dh dh-icon\" data-theme=\"{theme}\"{stated} xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" aria-hidden=\"true\"><defs><clipPath id=\"{id}p\"><path d=\"{Panel}\"/></clipPath>{made.Defs}</defs>"
            + $"<path d=\"{Frame}\" fill=\"{made.Frame}\"/><path d=\"{Panel}\" fill=\"{made.Panel}\"/><g clip-path=\"url(#{id}p)\">{body}</g></svg>";
        return d2d ? ForDirect2D(svg) : svg;
    }

    static readonly Regex Hooks = new(" (?:class|data-[a-z]+|aria-hidden|style|shape-rendering)=\"[^\"]*\"", RegexOptions.CultureInvariant);

    /// The markup without the web's CSS hooks (classes, data and ARIA attributes, inline styles), which Direct2D's SVG
    /// reader has no use for.
    public static string ForDirect2D(string svg) => Hooks.Replace(svg, "");
}
