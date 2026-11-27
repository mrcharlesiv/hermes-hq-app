namespace Hermes.Core.Settings;

/// An sRGB colour; channels and alpha 0…1 (HermesKit/Theme/ThemeMath.swift `RGBA`). Pure: the resolver runs it once per
/// theme change, never per draw.
public readonly record struct Rgba(double R, double G, double B, double A = 1)
{
    /// Channels 0…255 (the generated seed table), alpha 0…1.
    public static Rgba C(double r255, double g255, double b255, double a = 1) => new(r255 / 255, g255 / 255, b255 / 255, a);

    public static Rgba Hex(uint hex, double alpha = 1) =>
        C((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF, alpha);

    public static readonly Rgba White = Hex(0xFFFFFF);
    public static readonly Rgba Black = Hex(0x000000);
    public static readonly Rgba Clear = new(0, 0, 0, 0);

    public Rgba Alpha(double value) => this with { A = value };

    /// `color-mix(in srgb, self p%, transparent)`.
    public Rgba Faded(double percent) => this with { A = A * percent / 100 };

    /// CSS `color-mix(in srgb, self percent%, other)`: premultiplied interpolation.
    public Rgba Mix(double percent, Rgba other)
    {
        double p = percent / 100, q = 1 - p;
        var alpha = A * p + other.A * q;
        if (alpha <= 0) return Clear;
        return new((R * A * p + other.R * other.A * q) / alpha, (G * A * p + other.G * other.A * q) / alpha,
            (B * A * p + other.B * other.A * q) / alpha, alpha);
    }

    /// CSS `color-mix(in oklab, self percent%, other)` (Björn Ottosson's matrices, as desktop-look.ts:83-85).
    public Rgba MixOklab(double percent, Rgba other)
    {
        double p = percent / 100, q = 1 - p;
        var alpha = A * p + other.A * q;
        if (alpha <= 0) return Clear;
        var x = Oklab;
        var y = other.Oklab;
        var a = A;
        double Lerp(double u, double v) => (u * a * p + v * other.A * q) / alpha;
        return FromOklab(Lerp(x.L, y.L), Lerp(x.A, y.A), Lerp(x.B, y.B), alpha);
    }

    /// Source-over on an opaque colour.
    public Rgba Over(Rgba under) =>
        new(R * A + under.R * (1 - A), G * A + under.G * (1 - A), B * A + under.B * (1 - A), 1);

    private static double ToLinear(double v) => v <= 0.04045 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4);

    private static double ToGamma(double v)
    {
        var c = v <= 0.0031308 ? 12.92 * v : 1.055 * Math.Pow(v, 1 / 2.4) - 0.055;
        return Math.Min(1, Math.Max(0, c));
    }

    public (double L, double A, double B) Oklab
    {
        get
        {
            double lr = ToLinear(R), lg = ToLinear(G), lb = ToLinear(B);
            var l = Math.Cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
            var m = Math.Cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
            var s = Math.Cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
            return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
        }
    }

    public static Rgba FromOklab(double L, double A, double B, double alpha)
    {
        var l = Math.Pow(L + 0.3963377774 * A + 0.2158037573 * B, 3);
        var m = Math.Pow(L - 0.1055613458 * A - 0.0638541728 * B, 3);
        var s = Math.Pow(L - 0.0894841775 * A - 1.291485548 * B, 3);
        return new(ToGamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            ToGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            ToGamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s), alpha);
    }

    /// WCAG relative luminance (the web's own constant, 0.03928, desktop-look.ts:91).
    public double Luminance
    {
        get
        {
            static double Lin(double v) => v <= 0.03928 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4);
            return 0.2126 * Lin(R) + 0.7152 * Lin(G) + 0.0722 * Lin(B);
        }
    }

    public double Contrast(Rgba other)
    {
        double x = Luminance, y = other.Luminance;
        return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05);
    }

    // CIELAB (D50, as CSS lab()/lch()), for the tint floor and the on-tint ink.
    private (double L, double A, double B) LabD50
    {
        get
        {
            double lr = ToLinear(R), lg = ToLinear(G), lb = ToLinear(B);
            var x = 0.4360747 * lr + 0.3850649 * lg + 0.1430804 * lb;
            var y = 0.2225045 * lr + 0.7168786 * lg + 0.0606169 * lb;
            var z = 0.0139322 * lr + 0.0971045 * lg + 0.7141733 * lb;
            static double F(double t) => t > 216.0 / 24389 ? Math.Cbrt(t) : (24389.0 / 27 * t + 16) / 116;
            double fx = F(x / 0.96422), fy = F(y), fz = F(z / 0.82521);
            return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
        }
    }

    /// CIELAB lightness 0…100.
    public double LabL => LabD50.L;

    /// CIELAB ΔE76 to another colour.
    public double LabDistance(Rgba other)
    {
        var a = LabD50;
        var b = other.LabD50;
        return Math.Sqrt((a.L - b.L) * (a.L - b.L) + (a.A - b.A) * (a.A - b.A) + (a.B - b.B) * (a.B - b.B));
    }

    /// The same hue and chroma with CIELAB L raised to at least `floor` (clipped into sRGB).
    public Rgba RaisingL(double floor)
    {
        var lab = LabD50;
        if (lab.L >= floor) return this;
        static double Inv(double t) => t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) / (24389.0 / 27);
        var alpha = A;
        Rgba At(double lightness)
        {
            double fy = (lightness + 16) / 116, fx = lab.A / 500 + fy, fz = fy - lab.B / 200;
            double x = Inv(fx) * 0.96422, y = Inv(fy), z = Inv(fz) * 0.82521;
            var lr = 3.1338561 * x - 1.6168667 * y - 0.4906146 * z;
            var lg = -0.9787684 * x + 1.9161415 * y + 0.0334540 * z;
            var lb = 0.0719453 * x - 0.2289914 * y + 1.4052427 * z;
            return new(ToGamma(lr), ToGamma(lg), ToGamma(lb), alpha);
        }
        // Clipping a saturated colour into sRGB loses lightness, so aim a little higher until the floor holds.
        var result = At(floor);
        var target = floor;
        while (result.LabL < floor - 0.25 && target < 100)
        {
            target += 1;
            result = At(target);
        }
        return result;
    }

    /// "#RRGGBB".
    public string HexString => $"#{Byte(R):X2}{Byte(G):X2}{Byte(B):X2}";

    /// A channel as 0…255, rounded.
    public static byte Byte(double unit) => (byte)Math.Round(Math.Clamp(unit, 0, 1) * 255);

    /// Close within a tolerance per channel (tests and comparisons of computed colours).
    public bool Near(Rgba other, double tolerance = 0.5 / 255) =>
        Math.Abs(R - other.R) <= tolerance && Math.Abs(G - other.G) <= tolerance && Math.Abs(B - other.B) <= tolerance
        && Math.Abs(A - other.A) <= 0.005;
}

/// Port of HermesKit/Theme/ThemeMath.swift `ThemeMath`.
public static class ThemeMath
{
    /// Port of `legibleMix` (desktop-look.ts:96-105): how much of `source` is kept (100 = untouched) when it is mixed
    /// toward `text` in 10 % steps until it reads at 4.5:1 on `page`.
    public static int LegibleKeep(Rgba source, Rgba text, Rgba page)
    {
        var ground = page.Over(Rgba.White);
        for (var keep = 100; keep >= 0; keep -= 10)
        {
            var colour = source.MixOklab(keep, text);
            if (colour.Over(ground).Contrast(ground) >= 4.5) return keep;
        }
        return 0;
    }

    public static Rgba Legible(Rgba source, Rgba text, Rgba page)
    {
        var keep = LegibleKeep(source, text, page);
        return keep == 100 ? source : source.MixOklab(keep, text);
    }

    /// Mixes toward `text` in 5 % steps until `ratio` holds, and falls back to `text` itself.
    public static Rgba Readable(Rgba source, Rgba text, Rgba page, double ratio = 4.5)
    {
        var ground = page.Over(Rgba.White);
        for (var keep = 100; keep >= 0; keep -= 5)
        {
            var colour = source.MixOklab(keep, text);
            if (colour.Over(ground).Contrast(ground) >= ratio) return colour;
        }
        return text;
    }
}
