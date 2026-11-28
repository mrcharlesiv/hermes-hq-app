using System.Globalization;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Where a background applies (App/Theme/Backdrop.swift `Backdrop.Place`): behind app pages or behind chats.
public enum BackdropPlace { App, Chats }

/// Groups in the Backgrounds picker (App/Theme/BackdropPresets.swift `BackdropPreset.Group`).
public enum BackdropGroup { Classic, Solids, Photographic, Illustrated, Painted, Doodles }

public static class BackdropGroups
{
    public static readonly BackdropGroup[] All =
        [BackdropGroup.Classic, BackdropGroup.Solids, BackdropGroup.Photographic, BackdropGroup.Illustrated, BackdropGroup.Painted, BackdropGroup.Doodles];

    public static string Title(this BackdropGroup g) => g switch
    {
        BackdropGroup.Classic => "Classic",
        BackdropGroup.Solids => "Solids",
        BackdropGroup.Photographic => "Photographic",
        BackdropGroup.Illustrated => "Illustrated",
        BackdropGroup.Painted => "Painted",
        BackdropGroup.Doodles => "Doodles",
        _ => "Classic",
    };

    /// Compact chip label in the Backgrounds category strip (BackgroundSettingsView.swift `shortTitle`).
    public static string ShortTitle(this BackdropGroup g) => g switch
    {
        BackdropGroup.Classic => "Classic",
        BackdropGroup.Solids => "Solids",
        BackdropGroup.Photographic => "Photo",
        BackdropGroup.Illustrated => "Illustrated",
        BackdropGroup.Painted => "Painted",
        BackdropGroup.Doodles => "Doodles",
        _ => "Classic",
    };
}

/// Unified 4-way Soft Cards mode for App Background (BackgroundSettingsView.swift `CardChoice` + SoftCard.swift `SoftCardStyle`).
public enum CardStyle { Off, Tinted, Glass, Solid }

public static class CardStyles
{
    public const string Key = "hqn.appBackground.cardStyle";
    public const string Label = "Cards";
    public const string Note = "Cards lay a theme-matched backing behind each list so text stays readable. With Reduce Transparency on, Glass cards are solid.";

    public static readonly CardStyle[] All = [CardStyle.Off, CardStyle.Tinted, CardStyle.Glass, CardStyle.Solid];

    public static string Raw(this CardStyle s) => s switch
    {
        CardStyle.Off => "off",
        CardStyle.Glass => "glass",
        CardStyle.Solid => "solid",
        _ => "tinted",
    };

    public static string Title(this CardStyle s) => s switch
    {
        CardStyle.Off => "Off",
        CardStyle.Tinted => "Tinted",
        CardStyle.Glass => "Glass",
        CardStyle.Solid => "Solid",
        _ => "Tinted",
    };

    public static string Caption(this CardStyle s) => s switch
    {
        CardStyle.Off => "Text straight on wallpaper",
        CardStyle.Tinted => "Soft theme-tinted blur",
        CardStyle.Glass => "Frosted glass cards",
        CardStyle.Solid => "Opaque theme cards",
        _ => "Soft theme-tinted blur",
    };

    public static CardStyle? Parse(string? raw) => raw switch
    {
        "off" => CardStyle.Off,
        "tinted" => CardStyle.Tinted,
        "glass" => CardStyle.Glass,
        "solid" => CardStyle.Solid,
        _ => null,
    };

    /// Under Reduce Transparency, Glass cards draw as Solid (SoftCard.swift `shown(reduceTransparency:)`).
    public static CardStyle Effective(this CardStyle s, bool reduceTransparency) =>
        s == CardStyle.Glass && reduceTransparency ? CardStyle.Solid : s;
}

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

    public static readonly IReadOnlyList<BackdropPresetInfo> Photographic =
    [
        new("photoLake", "Alpine Lake", BackdropGroup.Photographic, 0xB8D4E8, 0x12263A, 0x7BA3C2, 0x1C3B54),
        new("photoOcean", "Golden Sea", BackdropGroup.Photographic, 0xF3D4A8, 0x2A1F1D, 0x99BED4, 0x162C3D),
        new("photoClouds", "Cloud Deck", BackdropGroup.Photographic, 0xD6E4F2, 0x1B2538, 0xECEEF2, 0x2E3B52),
        new("photoDunes", "Sand Ridges", BackdropGroup.Photographic, 0xF0D2A4, 0x35251A, 0xCE9C64, 0x1F1612),
        new("photoCanyon", "Red Canyon", BackdropGroup.Photographic, 0xE6AD8E, 0x3A1E1A, 0xB86A50, 0x221210),
        new("photoForest", "Fog Valley", BackdropGroup.Photographic, 0xC8D8CE, 0x16241D, 0x8EA89A, 0x24382F),
        new("photoAurora", "Polar Light", BackdropGroup.Photographic, 0xA8E0D4, 0x0B1E28, 0x8AAEE6, 0x1C2444),
        new("photoAlpenglow", "Alpenglow", BackdropGroup.Photographic, 0xF2C2CB, 0x2A1B2E, 0xA6BFE0, 0x1B2642),
    ];

    public static readonly IReadOnlyList<BackdropPresetInfo> Illustrated =
    [
        new("posterLake", "Emerald Lake", BackdropGroup.Illustrated, 0x9CD4C6, 0x102A28, 0x56A096, 0x1E4542),
        new("posterOcean", "Cumulus Coast", BackdropGroup.Illustrated, 0x9ED6F0, 0x10263C, 0xF2D4A6, 0x243A52),
        new("posterClouds", "Summit at Dusk", BackdropGroup.Illustrated, 0xD8B4D8, 0x221A34, 0xF0B298, 0x36243E),
        new("posterMesa", "Mesa", BackdropGroup.Illustrated, 0xF0BE96, 0x381E18, 0xD48060, 0x241414),
        new("northernLights", "Northern Lights", BackdropGroup.Illustrated, 0x96DFC8, 0x0D1E2C, 0x9A96E4, 0x1E1C44),
        new("snowyVillage", "Snowy Village", BackdropGroup.Illustrated, 0xDCE8F4, 0x182438, 0xB8CDE2, 0x283850),
        new("cityDusk", "City at Dusk", BackdropGroup.Illustrated, 0xC4B6DE, 0x1C1830, 0xECA694, 0x322238),
        new("rollingHills", "Rolling Hills", BackdropGroup.Illustrated, 0xB6DA9E, 0x182C1C, 0xE6D89C, 0x283C26),
    ];

    public static readonly IReadOnlyList<BackdropPresetInfo> Painted =
    [
        new("paintLake", "Still Water", BackdropGroup.Painted, 0xBDD6E6, 0x142434, 0x98B8CE, 0x22384C),
        new("paintOcean", "Evening Sea", BackdropGroup.Painted, 0xA8C8DC, 0x122232, 0xE6BFA0, 0x28263A),
        new("paintClouds", "Billows", BackdropGroup.Painted, 0xDAE4EE, 0x202836, 0xF0E6DC, 0x323A4A),
        new("paintHills", "Green Valley", BackdropGroup.Painted, 0xC2DCAC, 0x1A2C1E, 0xE6D8A4, 0x2A3E2A),
        new("paintForest", "Birch Wood", BackdropGroup.Painted, 0xDCE0CC, 0x1E261E, 0xB4C4A2, 0x2E382C),
        new("paintDesert", "Painted Desert", BackdropGroup.Painted, 0xEED0A8, 0x36241C, 0xD69C80, 0x261816),
        new("paintPeaks", "Golden Peaks", BackdropGroup.Painted, 0xF0D8A6, 0x282032, 0xB6C4DC, 0x3A2C3C),
        new("paintHarbor", "Harbor", BackdropGroup.Painted, 0xBCD2E0, 0x162430, 0xE4C6A8, 0x28323E),
    ];

    public static readonly IReadOnlyList<BackdropPresetInfo> Doodles =
    [
        new("doodleForest", "Forest", BackdropGroup.Doodles, 0xCCE2CE, 0x182A1E, 0xAED0B4, 0x223A2A),
        new("doodlePeaks", "Peaks", BackdropGroup.Doodles, 0xCEDCE8, 0x1A2432, 0xB2C8DC, 0x263448),
        new("doodleGaming", "Gaming", BackdropGroup.Doodles, 0xD2CCF0, 0x1E1A36, 0xB6C4EE, 0x2C244C),
        new("doodleSports", "Sports", BackdropGroup.Doodles, 0xD0E4C8, 0x1A2A1C, 0xE6D6A6, 0x283A26),
        new("doodleRose", "Rose", BackdropGroup.Doodles, 0xF4D4DE, 0x361C28, 0xF0C6B8, 0x462634),
        new("doodleLilac", "Lilac", BackdropGroup.Doodles, 0xE2D4F2, 0x261C38, 0xD0C8F0, 0x34284A),
        new("doodleTravel", "Travel", BackdropGroup.Doodles, 0xCBE2EA, 0x162834, 0xE8D8B2, 0x243844),
        new("doodleCafe", "Café", BackdropGroup.Doodles, 0xEFE0C8, 0x30241A, 0xDEC4A2, 0x403022),
    ];

    public static readonly IReadOnlyList<BackdropPresetInfo> All =
        [.. Classic, .. Solids, .. Photographic, .. Illustrated, .. Painted, .. Doodles];

    public static IReadOnlyList<BackdropPresetInfo> ByGroup(BackdropGroup group) => group switch
    {
        BackdropGroup.Classic => Classic,
        BackdropGroup.Solids => Solids,
        BackdropGroup.Photographic => Photographic,
        BackdropGroup.Illustrated => Illustrated,
        BackdropGroup.Painted => Painted,
        BackdropGroup.Doodles => Doodles,
        _ => Classic,
    };

    /// Resolves a stored preset id, including legacy aliases from App/Theme/BackdropPresets.swift (`init(stored:)`).
    public static string? ResolveId(string? id) => id switch
    {
        null or "" => null,
        "doodleMint" => "doodleForest",
        "doodleSky" or "doodleTeal" => "doodleTravel",
        "doodleSand" or "doodleLemon" => "doodleCafe",
        "doodlePeach" => "doodleRose",
        "clouds" or "seaOfClouds" => "photoClouds",
        "retroSun" or "waveTiles" or "oceanSunset" => "photoOcean",
        "terrazzo" => "rollingHills",
        "cityLights" => "cityDusk",
        "snowfall" => "snowyVillage",
        "alpine" or "alpenglow" => "photoAlpenglow",
        "mistyRidges" or "mistyForest" => "photoForest",
        "pinePeaks" => "posterLake",
        "mountainLake" => "photoLake",
        "canyon" => "photoCanyon",
        "lonePeak" => "posterClouds",
        "starlitPeaks" => "paintPeaks",
        "desert" => "photoDunes",
        _ => id,
    };

    public static BackdropPresetInfo? Find(string? id)
    {
        var resolved = ResolveId(id);
        return string.IsNullOrEmpty(resolved) ? null : All.FirstOrDefault(p => p.Id == resolved);
    }

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
public sealed record BackdropState(BackdropPlace Place, BackdropSource? Source, int Dim, bool Blur, bool SameAsApp, bool Cards, CardStyle CardStyle = CardStyle.Off)
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
    public const string WashLabel = "Wash";
    public const string SameAsAppNote = "Chats show the app’s picture, with their own Wash and Blur.";
    public const string DesktopNote = "The Hermes Look is on, so it shows once you switch back to Native.";
    public static string AppNote => $"Behind Sessions, Bots, Jobs, More, Settings and the pages they open. Wash blends the page color over it so rows stay readable. {Gateways.DeviceWord.OnlyHere}";
    public static string ChatNote => $"Behind every chat. Wash blends the page color over it so text and dividers stay readable. {Gateways.DeviceWord.OnlyHere}";

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
            : BackdropCatalog.Find(preset) is { } foundPreset ? new BackdropSource.Preset(foundPreset.Id)
            : color is { } hex ? new BackdropSource.CustomColor(hex)
            : null;
        var dim = ClampedDim(prefs.Get(p + ".dim"), place);
        var blur = prefs.Get(p + ".blur") == "true";
        var rawCardStyle = CardStyles.Parse(prefs.Get(p + ".cardStyle"));
        var cardsFlag = prefs.Get(p + ".cards");
        var cards = place == BackdropPlace.App && (cardsFlag == "true"
            || (cardsFlag == null && rawCardStyle is CardStyle.Tinted or CardStyle.Glass or CardStyle.Solid));
        var cardStyle = !cards
            ? CardStyle.Off
            : (rawCardStyle is null or CardStyle.Off ? CardStyle.Tinted : rawCardStyle.Value);
        var storedSame = prefs.Get(p + ".sameAsApp");
        var sameAsApp = place == BackdropPlace.Chats && (storedSame == null ? source == null : storedSame == "true");
        return new(place, source, dim, blur, sameAsApp, cards, cardStyle);
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
        var p = Prefix(BackdropPlace.App);
        prefs.Set(p + ".cards", on ? "true" : null);
        if (!on) prefs.Set(p + ".cardStyle", null);
        Changed?.Invoke();
    }

    /// Unified 4-way Cards picker for App Background (Off | Tinted | Glass | Solid; key `hqn.appBackground.cardStyle`).
    public void SetCardStyle(CardStyle style)
    {
        var p = Prefix(BackdropPlace.App);
        if (style == CardStyle.Off)
        {
            prefs.Set(p + ".cards", null);
            prefs.Set(p + ".cardStyle", null);
        }
        else
        {
            prefs.Set(p + ".cards", "true");
            prefs.Set(p + ".cardStyle", style == CardStyle.Tinted ? null : style.Raw());
        }
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
