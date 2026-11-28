namespace Hermes.Core.Settings;

/// One palette of a skin: the slots of `ThemePresetColors` the app uses (HermesKit/Theme/Skin.swift `SkinSeeds`).
public sealed record SkinSeeds(
    Rgba Background, Rgba Foreground, Rgba Card, Rgba Muted, Rgba MutedForeground, Rgba Popover, Rgba Primary,
    Rgba Secondary, Rgba Accent, Rgba Border, Rgba Input, Rgba Ring, Rgba? Midground, Rgba? ComposerRing,
    Rgba Destructive, Rgba? SidebarBackground, Rgba? SidebarBorder, Rgba? UserBubble, Rgba? UserBubbleBorder)
{
    /// The brand accent (`c.midground ?? c.ring`, context.tsx).
    public Rgba Brand => Midground ?? Ring;

    /// What the desktop paints for this palette whatever mode was asked (`renderedModeFor`, context.tsx:185-201).
    public bool RendersDark => 0.2126 * Background.R + 0.7152 * Background.G + 0.0722 * Background.B <= 0.5;
}

/// One mode of a skin's own native look (HermesKit/Theme/SkinOwnLooks.swift). Colours from the theme's own palette.
public sealed record SkinOwnLook(
    Rgba Page, Rgba Card, Rgba Pressed, Rgba MeBubble, Rgba CodeFill, Rgba Grey, double[] FillAlphas, Rgba Separator,
    Rgba ReplyEdge, Rgba TableHead, double ReplyGlassTint, Rgba Subtle, Rgba Muted, Rgba? Reply = null,
    Rgba? IconTile = null, bool FlatPills = false, Rgba? ChosenRow = null,
    Rgba? Grouped = null, Rgba? MeText = null, bool PlainIcons = false);

public sealed record SkinOwnLookPair(SkinOwnLook Light, SkinOwnLook Dark)
{
    public SkinOwnLook Pick(bool dark) => dark ? Dark : Light;
}

/// A bundled theme skin (spec 3x-desktoplook §4.2). Labels, descriptions and order are the Mac's.
public sealed record Skin(string Id, string Label, string Description, string? SansFamily, SkinSeeds Light, SkinSeeds? Dark,
    SkinOwnLookPair? OwnLook = null)
{
    /// One palette only (Midnight, Ember, Mono, Slate, Cyberpunk): Light and Dark draw the same.
    public bool HasOneLook => Dark == null;

    /// The theme card's tag for a one-palette skin: "Dark Only" / "Light Only", null otherwise.
    public string? OnlyModeTag => HasOneLook ? (Light.RendersDark ? "Dark Only" : "Light Only") : null;

    public SkinSeeds Seeds(bool dark) => dark ? Dark ?? Light : Light;

    /// The accent can't be told from the text in either palette (ΔE76 under 15): Paper's ink and Cyberpunk's green.
    public bool AccentReadsAsText =>
        new[] { Light, Dark }.OfType<SkinSeeds>().Any(s => s.Brand.LabDistance(s.Foreground) < 15);
}

public static partial class SkinCatalog
{
    public const string DefaultId = "nous";
    /// The default before this layer existed (the migration compares against it, §4.4).
    public const string OldDefaultId = "nous";
    public const string IosId = "ios";
    /// The desktop's default skin: what the Desktop Look hands iOS System over to (§5.6).
    public const string DesktopDefaultId = "nous";

    /// (id, label, description, sans family). The Mac's words: "Apple System" for the iOS System skin.
    private static readonly (string Id, string Label, string Description, string? Sans)[] Meta =
    [
        ("nous", "Nous", "Neutral greys with Nous blue", null),
        ("paper", "Paper", "Warm ivory and ink, easy on the eyes", null),
        ("github", "GitHub", "GitHub Light Default and Dark Default", null),
        ("catppuccin", "Catppuccin", "Soothing pastels — Latte and Mocha", null),
        ("everforest", "Everforest", "Warm, low-contrast forest greens", null),
        ("solarized", "Solarized", "Fixed-contrast light and dark", null),
        ("rose-pine", "Rosé Pine", "Muted pine, rosé and iris — Dawn and Main", null),
        ("nous-alt", "Nous Alt", "Glass neutrals, cream on mission-blue", null),
        // App-only skins from Synara's palette catalog (`5d05f77ba`).
        ("codex", "Codex", "Clean white and deep graphite with crisp Codex blue", null),
        ("notion", "Notion", "Warm editorial ink in light and calm charcoal in dark", null),
        ("vercel", "Vercel", "Pure white and true OLED black with electric blue", null),
        ("midnight", "Midnight", "Deep blue-violet with cool accents", null),
        ("ember", "Ember", "Warm crimson and bronze — forge vibes", null),
        ("mono", "Mono", "Clean grayscale — minimal and focused", null),
        ("slate", "Slate", "Cool slate blue — focused developer theme", null),
        ("cyberpunk", "Cyberpunk", "Neon green on black — matrix terminal", "Courier New"),
        ("night-owl", "Night Owl", "Deep midnight navy with cool ice text and mint syntax", null),
        ("lobster", "Lobster", "Deep slate navy with crisp zinc text and coral red", null),
        ("ios", "Apple System", "Apple’s system colors, true black in dark, system blue", null),
    ];

    public static IReadOnlyList<Skin> All => AllSkins.Value;

    public static Skin? Find(string? id) => id == null ? null : All.FirstOrDefault(s => s.Id == id);

    /// A stored id that is not in the catalog (retired, corrupt) draws as the default.
    public static Skin Resolved(string? id) => Find(id) ?? Find(DefaultId) ?? All[0];

    // Rosé Pine's palettes (rosepinetheme.com/en/palette): Dawn and Main.
    private static readonly Rgba DawnBase = Rgba.Hex(0xFAF4ED), DawnSurface = Rgba.Hex(0xFFFAF3), DawnOverlay = Rgba.Hex(0xF2E9E1),
        DawnMuted = Rgba.Hex(0x9893A5), DawnSubtle = Rgba.Hex(0x797593);
    private static readonly Rgba MainBase = Rgba.Hex(0x191724), MainSurface = Rgba.Hex(0x1F1D2E), MainOverlay = Rgba.Hex(0x26233A),
        MainMuted = Rgba.Hex(0x6E6A86), MainSubtle = Rgba.Hex(0x908CAA);
    // Paper's palettes: Claude's ivory, and black with warm greys in dark.
    private static readonly Rgba IvoryPage = Rgba.Hex(0xF8F9F3), IvoryCard = Rgba.Hex(0xFDFDFA), IvoryDrawer = Rgba.Hex(0xF2F3EE),
        IvorySelected = Rgba.Hex(0xE4E5DD), IvoryBox = Rgba.Hex(0xE9EAE2), IvoryGrey = Rgba.Hex(0x86857B),
        IvorySubtle = Rgba.Hex(0x4A4A47), IvoryMuted = Rgba.Hex(0x8A897F);
    private static readonly Rgba CharcoalPage = Rgba.Hex(0x000000), CharcoalCard = Rgba.Hex(0x161615), CharcoalDeep = Rgba.Hex(0x0E0E0D),
        CharcoalSelected = Rgba.Hex(0x1E1E1C), CharcoalBox = Rgba.Hex(0x242422), CharcoalGrey = Rgba.Hex(0x8E8D84),
        CharcoalSubtle = Rgba.Hex(0xB7B5AC), CharcoalMuted = Rgba.Hex(0x8A8980);

    private static readonly SkinOwnLook MonoOwnLook = new(
        Rgba.Hex(0x0D0D0D), Rgba.Hex(0x181818), Rgba.Hex(0x262626), Rgba.Hex(0x333333), Rgba.Hex(0x131313),
        Rgba.Hex(0x8E8E8E), [0.32, 0.26, 0.20, 0.12], Rgba.Hex(0x8E8E8E, 0.28), Rgba.Hex(0x8E8E8E, 0.22),
        Rgba.Hex(0x8E8E8E, 0.16), 0.85, Rgba.Hex(0xA3A3A3), Rgba.Hex(0x737373),
        Reply: Rgba.Hex(0x1B1B1B), IconTile: Rgba.Hex(0x242424), ChosenRow: Rgba.Hex(0x8E8E8E),
        Grouped: Rgba.Hex(0x090909), MeText: Rgba.Hex(0xF5F5F5));

    private static readonly SkinOwnLook CyberpunkOwnLook = new(
        Rgba.Hex(0x000A00), Rgba.Hex(0x021704), Rgba.Hex(0x042808), Rgba.Hex(0x063B18), Rgba.Hex(0x011202),
        Rgba.Hex(0x1A8A30), [0.32, 0.26, 0.20, 0.12], Rgba.Hex(0x1A8A30, 0.38), Rgba.Hex(0x1A8A30, 0.34),
        Rgba.Hex(0x1A8A30, 0.18), 0.85, Rgba.Hex(0x38B852), Rgba.Hex(0x1A8A30),
        Reply: Rgba.Hex(0x031B06), IconTile: Rgba.Hex(0x042808),
        Grouped: Rgba.Hex(0x000600), MeText: Rgba.Hex(0xA6FFC0));

    private static readonly Dictionary<string, SkinOwnLookPair> OwnLooks = new()
    {
        ["paper"] = new(
            new SkinOwnLook(IvoryPage, IvoryCard, IvorySelected, IvoryBox, IvoryDrawer, IvoryGrey, [0.2, 0.16, 0.12, 0.08],
                IvoryGrey.Alpha(0.3), Rgba.Clear, IvoryDrawer, 0.85, IvorySubtle, IvoryMuted, Reply: IvoryPage,
                IconTile: IvorySelected, FlatPills: true, ChosenRow: IvoryGrey, PlainIcons: true),
            new SkinOwnLook(CharcoalPage, CharcoalCard, CharcoalSelected, CharcoalBox, CharcoalDeep, CharcoalGrey,
                [0.36, 0.32, 0.24, 0.12], CharcoalGrey.Alpha(0.3), Rgba.Clear, CharcoalGrey.Alpha(0.2), 0.85, CharcoalSubtle,
                CharcoalMuted, Reply: CharcoalPage, IconTile: CharcoalSelected, FlatPills: true, ChosenRow: CharcoalGrey, PlainIcons: true)),
        ["rose-pine"] = new(
            new SkinOwnLook(DawnBase, DawnSurface, DawnOverlay, Rgba.Hex(0xEADCEF), DawnOverlay, DawnMuted, [0.2, 0.16, 0.12, 0.08],
                DawnMuted.Alpha(0.35), DawnMuted.Alpha(0.35), DawnOverlay, 0.85, DawnSubtle, DawnMuted),
            new SkinOwnLook(MainBase, MainSurface, MainOverlay, Rgba.Hex(0x4D3357), MainBase, MainMuted, [0.36, 0.32, 0.24, 0.12],
                MainMuted.Alpha(0.3), MainMuted.Alpha(0.3), MainMuted.Alpha(0.2), 0.85, MainSubtle, MainMuted)),
        ["everforest"] = new(
            new SkinOwnLook(Rgba.Hex(0xFDF6E3), Rgba.Hex(0xFFFDF5), Rgba.Hex(0xEAE3CD), Rgba.Hex(0x586B35), Rgba.Hex(0xEBE4CE),
                Rgba.Hex(0x829181), [0.20, 0.16, 0.12, 0.08], Rgba.Hex(0x829181, 0.28), Rgba.Hex(0x939F91, 0.32),
                Rgba.Hex(0x829181, 0.16), 0.85, Rgba.Hex(0x5C6A72), Rgba.Hex(0x829181),
                Reply: Rgba.Hex(0xF4EEDB), IconTile: Rgba.Hex(0xE6E1CB), Grouped: Rgba.Hex(0xF4ECD8), MeText: Rgba.White),
            new SkinOwnLook(Rgba.Hex(0x2D353B), Rgba.Hex(0x343F44), Rgba.Hex(0x3D484D), Rgba.Hex(0x475843), Rgba.Hex(0x272E33),
                Rgba.Hex(0x859289), [0.34, 0.28, 0.22, 0.14], Rgba.Hex(0x859289, 0.30), Rgba.Hex(0x859289, 0.28),
                Rgba.Hex(0x859289, 0.18), 0.85, Rgba.Hex(0x9DA9A0), Rgba.Hex(0x7A8478),
                Reply: Rgba.Hex(0x343F44), IconTile: Rgba.Hex(0x3D484D), Grouped: Rgba.Hex(0x232A2E), MeText: Rgba.Hex(0xE8DEC8))),
        ["mono"] = new(MonoOwnLook, MonoOwnLook),
        ["cyberpunk"] = new(CyberpunkOwnLook, CyberpunkOwnLook),
        ["vercel"] = new(
            new SkinOwnLook(Rgba.Hex(0xFFFFFF), Rgba.Hex(0xF4F4F5), Rgba.Hex(0xE6E6E8), Rgba.Hex(0x006AFF), Rgba.Hex(0xEFEFF1),
                Rgba.Hex(0x737373), [0.20, 0.16, 0.12, 0.08], Rgba.Hex(0x737373, 0.32), Rgba.Hex(0x737373, 0.24),
                Rgba.Hex(0xEAEAEC), 0.85, Rgba.Hex(0x555555), Rgba.Hex(0x737373),
                Reply: Rgba.Hex(0xF4F4F5), Grouped: Rgba.Hex(0xF5F5F6), MeText: Rgba.White),
            new SkinOwnLook(Rgba.Hex(0x000000), Rgba.Hex(0x141414), Rgba.Hex(0x222222), Rgba.Hex(0x005CE0), Rgba.Hex(0x0C0C0C),
                Rgba.Hex(0x888888), [0.34, 0.28, 0.22, 0.14], Rgba.Hex(0x888888, 0.32), Rgba.Hex(0x888888, 0.24),
                Rgba.Hex(0x1A1A1A), 0.85, Rgba.Hex(0xA1A1A1), Rgba.Hex(0x737373),
                Reply: Rgba.Hex(0x141414), Grouped: Rgba.Hex(0x0A0A0A), MeText: Rgba.White)),
    };

    private static readonly Lazy<IReadOnlyList<Skin>> AllSkins = new(Build);

    private static IReadOnlyList<Skin> Build()
    {
        var seeds = Seeds!;
        return Meta.Where(m => seeds.ContainsKey(m.Id))
            .Select(m => new Skin(m.Id, m.Label, m.Description, m.Sans, seeds[m.Id].Light, seeds[m.Id].Dark,
                OwnLooks.GetValueOrDefault(m.Id)))
            .ToList();
    }
}
