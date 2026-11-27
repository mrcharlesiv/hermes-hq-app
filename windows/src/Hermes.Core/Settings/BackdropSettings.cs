using System.Globalization;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Where a background applies (App/Theme/Backdrop.swift `Backdrop.Place`): behind app pages or behind chats.
public enum BackdropPlace { App, Chats }

/// Groups in the Backgrounds picker (App/Theme/BackdropPresets.swift `BackdropPreset.Group`).
public enum BackdropGroup { Classic, Solids, Photographic, Illustrated, Painted, Doodles }

/// Built-in background presets, including Studio Matte solid-color pigments and dynamic Theme Tint.
public sealed record BackdropPresetInfo(string Id, string Label, BackdropGroup Group, uint LightHex, uint DarkHex, uint LightAccent = 0, uint DarkAccent = 0)
{
    public bool IsSolid => Group == BackdropGroup.Solids;
    public bool UsesAccent => Id is "glow" or "solidTint";
}

/// What a background place draws: None, a built-in preset, a custom #RRGGBB color, or a local photo file.
public abstract record BackdropSource
{
    public bool IsSolid => this is CustomColor || (this is Preset p && BackdropCatalog.Find(p.Id)?.IsSolid == true);
    public sealed record Preset(string Id) : BackdropSource;
    public sealed record CustomColor(uint Hex) : BackdropSource;
    public sealed record Photo(string FileName) : BackdropSource;
}

/// Built-in Studio Matte solids (10 Mineral & Studio Light/Dark pairs + Theme Tint) and Classic presets
/// ported 1:1 from App/Theme/BackdropPresets.swift (`c4ce59722`).
public static class BackdropCatalog
{
    public static readonly IReadOnlyList<BackdropPresetInfo> Solids =
    [
        new("solidStone", "Stone", BackdropGroup.Solids, 0xDCD6CB, 0x312F2B),
        new("solidGraphite", "Graphite", BackdropGroup.Solids, 0xBDC2CA, 0x23272F),
        new("solidSlate", "Slate", BackdropGroup.Solids, 0xAEC1D2, 0x223447),
        new("solidCobalt", "Cobalt", BackdropGroup.Solids, 0x8AB0EA, 0x1B3669),
        new("solidSpruce", "Spruce", BackdropGroup.Solids, 0x8CC2BC, 0x143F40),
        new("solidSage", "Sage", BackdropGroup.Solids, 0xA5C59F, 0x203E2C),
        new("solidSand", "Sand", BackdropGroup.Solids, 0xE3C692, 0x47361E),
        new("solidTerracotta", "Terracotta", BackdropGroup.Solids, 0xDC9C84, 0x502920),
        new("solidRosewood", "Rosewood", BackdropGroup.Solids, 0xE0AEBA, 0x4A2434),
        new("solidPlum", "Plum", BackdropGroup.Solids, 0xBFAEDE, 0x322450),
        new("solidTint", "Theme Tint", BackdropGroup.Solids, 0x8AB0EA, 0x1B3669),
    ];

    public static readonly IReadOnlyList<BackdropPresetInfo> Classic =
    [
        new("aurora", "Aurora", BackdropGroup.Classic, 0xCFE8F3, 0x10253A, 0xC6EBD8, 0x1A4B4F),
        new("sunset", "Sunset", BackdropGroup.Classic, 0xFAD7C5, 0x3A1E2B, 0xF4B5C8, 0x592C3A),
        new("ocean", "Ocean", BackdropGroup.Classic, 0xC7E0F4, 0x0F253E, 0xA4D4E6, 0x16415E),
        new("meadow", "Meadow", BackdropGroup.Classic, 0xD3E8CF, 0x183123, 0xE5EED1, 0x284733),
        new("blossom", "Blossom", BackdropGroup.Classic, 0xF5D6E3, 0x3A1D2D, 0xEAD4F2, 0x4A2744),
        new("dunes", "Dunes", BackdropGroup.Classic, 0xEFE0C8, 0x382A1E, 0xE3C7A3, 0x4F3A26),
        new("nebula", "Nebula", BackdropGroup.Classic, 0xDDD4F0, 0x1E1736, 0xC6D2F5, 0x332259),
        new("paper", "Paper", BackdropGroup.Classic, 0xF3EEE4, 0x282623, 0xEAE2D3, 0x33302C),
        new("contours", "Contours", BackdropGroup.Classic, 0xDCE3E8, 0x1E252B, 0xCBD5DC, 0x2A343D),
        new("glow", "Theme Glow", BackdropGroup.Classic, 0xD5E2FA, 0x18253E, 0xE6EEFD, 0x223659),
    ];

    public static readonly IReadOnlyList<BackdropPresetInfo> All = [.. Classic, .. Solids];

    public static BackdropPresetInfo? Find(string? id) =>
        string.IsNullOrEmpty(id) ? null : All.FirstOrDefault(p => p.Id == id);

    /// Studio Matte pigment for a solid preset, or OKLab-adapted pigment for Theme Tint / Custom color.
    public static Rgba ResolveSolidBase(BackdropSource source, bool dark, Rgba themeTint) => source switch
    {
        BackdropSource.CustomColor c => OkLabSolidAdapt.Adapt(Rgba.Hex(c.Hex), dark, isTint: false),
        BackdropSource.Preset p when p.Id == "solidTint" => OkLabSolidAdapt.Adapt(themeTint, dark, isTint: true),
        BackdropSource.Preset p when Find(p.Id) is { } info => Rgba.Hex(dark ? info.DarkHex : info.LightHex),
        _ => dark ? Rgba.Hex(0x23272F) : Rgba.Hex(0xDCD6CB),
    };

    /// Studio Matte vertical gradient stops matching BackdropArt.studioMatte (lit top, true base at 0.45, grounded foot).
    public static (Rgba Top, Rgba Mid, Rgba Bottom) StudioMatteStops(Rgba baseColor, bool dark)
    {
        var top = Lerp(baseColor, Rgba.White, dark ? 0.08 : 0.24);
        var bottomTarget = dark ? Rgba.Black : Rgba.Hex(0x12161E);
        var bottom = Lerp(baseColor, bottomTarget, dark ? 0.22 : 0.08);
        return (top, baseColor, bottom);
    }

    private static Rgba Lerp(Rgba a, Rgba b, double t)
    {
        t = Math.Clamp(t, 0, 1);
        return new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t, 1);
    }
}

/// OKLab gamut-clamped solid wallpaper adaptation (App/Theme/BackdropPresets.swift `adaptedSolid`).
public static class OkLabSolidAdapt
{
    private static double ToGamma(double v)
    {
        var c = v <= 0.0031308 ? 12.92 * v : 1.055 * Math.Pow(v, 1.0 / 2.4) - 0.055;
        return Math.Clamp(c, 0, 1);
    }

    private static (double R, double G, double B) OklabToLinear(double L, double a, double b)
    {
        var l = Math.Pow(L + 0.3963377774 * a + 0.2158037573 * b, 3);
        var m = Math.Pow(L - 0.1055613458 * a - 0.0638541728 * b, 3);
        var s = Math.Pow(L - 0.0894841775 * a - 1.291485548 * b, 3);
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s);
    }

    public static Rgba FromOklabInGamut(double L, double a, double b)
    {
        L = Math.Clamp(L, 0, 1);
        bool Fits(double k)
        {
            var (lr, lg, lb) = OklabToLinear(L, a * k, b * k);
            return lr >= -0.0005 && lg >= -0.0005 && lb >= -0.0005
                && lr <= 1.0005 && lg <= 1.0005 && lb <= 1.0005;
        }
        var scale = 1.0;
        if (!Fits(1))
        {
            double low = 0.0, high = 1.0;
            for (var i = 0; i < 14; i++)
            {
                var mid = (low + high) / 2;
                if (Fits(mid)) low = mid; else high = mid;
            }
            scale = low;
        }
        var (r, g, bl) = OklabToLinear(L, a * scale, b * scale);
        return new(ToGamma(r), ToGamma(g), ToGamma(bl), 1);
    }

    /// Adapts an arbitrary picked color (or the theme's accent) into a calm Studio Matte solid for Light or Dark.
    public static Rgba Adapt(Rgba input, bool dark, bool isTint = false)
    {
        var (L, a, b) = input.Oklab;
        var chroma = Math.Sqrt(a * a + b * b);
        var clampedL = Math.Clamp(L, 0, 1);
        var targetL = dark
            ? (isTint ? 0.33 : 0.16 + 0.22 * Math.Pow(clampedL, 0.45))
            : (isTint ? 0.78 : 0.72 + 0.16 * clampedL);
        var maxChroma = isTint ? 0.085 : 0.092;
        var targetC = Math.Min(chroma, maxChroma);
        var (na, nb) = chroma > 0.0001 ? (a / chroma * targetC, b / chroma * targetC) : (0.0, 0.0);
        return FromOklabInGamut(targetL, na, nb);
    }
}

/// Stored state for App Background or Chat Background (`hqn.appBackground.*` / `hqn.chatBackground.*`).
public sealed record BackdropState(BackdropPlace Place, BackdropSource? Source, int Dim, bool Blur, bool SameAsApp, bool Cards)
{
    public static int DefaultDim(BackdropPlace place) => place == BackdropPlace.App ? 45 : 30;
    public const int MinDim = 0, MaxDim = 80;

    /// Effective source drawn by this place, resolving SameAsApp against the app's background.
    public BackdropSource? EffectiveSource(BackdropState? appState) =>
        Place == BackdropPlace.Chats && SameAsApp ? appState?.Source : Source;

    public bool EffectiveIsSolid(BackdropState? appState) => EffectiveSource(appState)?.IsSolid == true;

    /// Blur is skipped for Studio Matte solids while preserving the stored blur preference for photos.
    public bool EffectiveBlur(BackdropState? appState) => Blur && !EffectiveIsSolid(appState);

    public string Summary(BackdropState? appState)
    {
        if (Place == BackdropPlace.Chats && SameAsApp)
            return appState?.Source != null ? "Same as App" : "None";
        return Source switch
        {
            null => "None",
            BackdropSource.Preset p => BackdropCatalog.Find(p.Id)?.Label ?? p.Id,
            BackdropSource.CustomColor c => BackdropPrefs.HexString(c.Hex),
            BackdropSource.Photo => "Your Photo",
            _ => "None",
        };
    }
}

/// Reads and writes `hqn.appBackground.*` and `hqn.chatBackground.*` matching App/Theme/Backdrop.swift.
public sealed class BackdropPrefs(IPreferences prefs)
{
    public const string Target = "backgrounds";
    public const string Title = "Backgrounds";

    public static event Action? Changed;

    private static string Prefix(BackdropPlace place) => place == BackdropPlace.App ? "hqn.appBackground" : "hqn.chatBackground";

    public static uint? ParseHex(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var s = value.Trim();
        if (s.StartsWith('#')) s = s[1..];
        if (s.Length != 6 || !uint.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var hex)) return null;
        return hex & 0xFFFFFF;
    }

    public static string HexString(uint hex) => $"#{(hex & 0xFFFFFF):X6}";

    public static int ClampedDim(string? raw, BackdropPlace place)
    {
        if (raw == null || !double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var v))
            return BackdropState.DefaultDim(place);
        var pct = Math.Round(v, MidpointRounding.AwayFromZero);
        if (!double.IsFinite(pct) || pct < BackdropState.MinDim || pct > BackdropState.MaxDim)
            return BackdropState.DefaultDim(place);
        return (int)pct;
    }

    public BackdropState Load(BackdropPlace place)
    {
        var p = Prefix(place);
        var photo = prefs.Get(p + ".photo");
        var preset = prefs.Get(p + ".preset");
        var color = ParseHex(prefs.Get(p + ".color"));
        BackdropSource? source = !string.IsNullOrEmpty(photo) ? new BackdropSource.Photo(photo)
            : BackdropCatalog.Find(preset) != null ? new BackdropSource.Preset(preset!)
            : color is { } hex ? new BackdropSource.CustomColor(hex)
            : null;
        var dim = ClampedDim(prefs.Get(p + ".dim"), place);
        var blur = prefs.Get(p + ".blur") == "true";
        var cards = place == BackdropPlace.App && prefs.Get(p + ".cards") == "true";
        var storedSame = prefs.Get(p + ".sameAsApp");
        var sameAsApp = place == BackdropPlace.Chats && (storedSame == null ? source == null : storedSame == "true");
        return new(place, source, dim, blur, sameAsApp, cards);
    }

    public void SetPreset(BackdropPlace place, string presetId)
    {
        var p = Prefix(place);
        prefs.Set(p + ".preset", presetId);
        prefs.Set(p + ".photo", null);
        prefs.Set(p + ".color", null);
        if (place == BackdropPlace.Chats) prefs.Set(p + ".sameAsApp", "false");
        Changed?.Invoke();
    }

    public void SetCustomColor(BackdropPlace place, uint hex)
    {
        var p = Prefix(place);
        prefs.Set(p + ".color", HexString(hex));
        prefs.Set(p + ".preset", null);
        prefs.Set(p + ".photo", null);
        if (place == BackdropPlace.Chats) prefs.Set(p + ".sameAsApp", "false");
        Changed?.Invoke();
    }

    public void SetPhoto(BackdropPlace place, string fileName)
    {
        var p = Prefix(place);
        prefs.Set(p + ".photo", fileName);
        prefs.Set(p + ".preset", null);
        prefs.Set(p + ".color", null);
        if (place == BackdropPlace.Chats) prefs.Set(p + ".sameAsApp", "false");
        Changed?.Invoke();
    }

    public void Clear(BackdropPlace place)
    {
        var p = Prefix(place);
        prefs.Set(p + ".preset", null);
        prefs.Set(p + ".photo", null);
        prefs.Set(p + ".color", null);
        if (place == BackdropPlace.Chats) prefs.Set(p + ".sameAsApp", "false");
        Changed?.Invoke();
    }

    public void SetSameAsApp(bool on)
    {
        prefs.Set(Prefix(BackdropPlace.Chats) + ".sameAsApp", on ? "true" : "false");
        Changed?.Invoke();
    }

    public void SetDim(BackdropPlace place, int percent)
    {
        var clamped = Math.Clamp(percent, BackdropState.MinDim, BackdropState.MaxDim);
        prefs.Set(Prefix(place) + ".dim", clamped == BackdropState.DefaultDim(place) ? null : clamped.ToString(CultureInfo.InvariantCulture));
        Changed?.Invoke();
    }

    public void SetBlur(BackdropPlace place, bool on)
    {
        prefs.Set(Prefix(place) + ".blur", on ? "true" : null);
        Changed?.Invoke();
    }

    public void SetCards(bool on)
    {
        prefs.Set(Prefix(BackdropPlace.App) + ".cards", on ? "true" : null);
        Changed?.Invoke();
    }

    public void Reset(BackdropPlace place)
    {
        var p = Prefix(place);
        foreach (var suffix in new[] { ".photo", ".preset", ".color", ".dim", ".blur", ".sameAsApp", ".cards", ".cardStyle" })
            prefs.Set(p + suffix, null);
        Changed?.Invoke();
    }
}
