using Hermes.Core.Settings;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

/// Wave 2A parity tests: 19 skins + OwnLooks (`5d05f77ba`), DarkInkBubble (`687406870`), configurable Hermes Look
/// border radius & ShapeRadius role scaling (`a78139597`), Reply Bubbles toggle in Hermes Look High Contrast
/// (`1a1f7200d`), WindowTransparency core pref & layered glass colors (`e2f3aaf39`), Crisp Frosted Chrome WhisperLine
/// (`ddcf7975e`), and Backgrounds 4-way CardStyle + 6 preset categories + Wash copy.
public sealed class ThemeAndGlassParityTests
{
    private sealed class MemPrefs : IPreferences
    {
        public readonly Dictionary<string, string> Values = [];
        public string? Get(string key) => Values.GetValueOrDefault(key);
        public void Set(string key, string? value) { if (value == null) Values.Remove(key); else Values[key] = value; }
    }

    // ---------------------------------------------------------------- 19 Skins + OwnLooks (5d05f77ba)

    [Fact]
    public void NineteenSkinsInMacOrderWithFiveNewThemesAndFourNewOwnLooks()
    {
        string[] expected =
        [
            "nous", "paper", "github", "catppuccin", "everforest", "solarized", "rose-pine", "nous-alt",
            "codex", "notion", "vercel",
            "midnight", "ember", "mono", "slate", "cyberpunk", "night-owl", "lobster",
            "ios",
        ];
        Assert.Equal(19, SkinCatalog.All.Count);
        Assert.Equal(expected, SkinCatalog.All.Select(s => s.Id));

        // 7 dark-only one-look skins (5 original + night-owl + lobster).
        Assert.Equal(["midnight", "ember", "mono", "slate", "cyberpunk", "night-owl", "lobster"],
            SkinCatalog.All.Where(s => s.HasOneLook).Select(s => s.Id));

        // 5 new skins metadata & seeds.
        var codex = SkinCatalog.Find("codex")!;
        Assert.Equal("Codex", codex.Label);
        Assert.False(codex.HasOneLook);
        Assert.Equal(Rgba.Hex(0x0169CC), codex.Light.Brand);
        Assert.Equal(Rgba.Hex(0x111111), codex.Dark!.Background);

        var notion = SkinCatalog.Find("notion")!;
        Assert.Equal("Notion", notion.Label);
        Assert.False(notion.HasOneLook);
        Assert.Equal(Rgba.Hex(0x3183D8), notion.Light.Brand);
        Assert.Equal(Rgba.Hex(0x191919), notion.Dark!.Background);

        var vercel = SkinCatalog.Find("vercel")!;
        Assert.Equal("Vercel", vercel.Label);
        Assert.False(vercel.HasOneLook);
        Assert.Equal(Rgba.Hex(0xFFFFFF), vercel.Light.Background);
        Assert.Equal(Rgba.Hex(0x000000), vercel.Dark!.Background);

        var nightOwl = SkinCatalog.Find("night-owl")!;
        Assert.Equal("Night Owl", nightOwl.Label);
        Assert.True(nightOwl.HasOneLook);
        Assert.Equal("Dark Only", nightOwl.OnlyModeTag);
        Assert.Equal(Rgba.Hex(0x011627), nightOwl.Light.Background);

        var lobster = SkinCatalog.Find("lobster")!;
        Assert.Equal("Lobster", lobster.Label);
        Assert.True(lobster.HasOneLook);
        Assert.Equal("Dark Only", lobster.OnlyModeTag);
        Assert.Equal(Rgba.Hex(0xFF5C5C), lobster.Light.Brand);

        // 6 skins with OwnLooks: paper, rose-pine + 4 newly ported (everforest, mono, cyberpunk, vercel).
        Assert.Equal(["paper", "everforest", "rose-pine", "vercel", "mono", "cyberpunk"],
            SkinCatalog.All.Where(s => s.OwnLook != null).Select(s => s.Id));

        var everforest = ThemeResolver.Resolve(ThemeState.Default with { SkinId = "everforest" });
        Assert.Equal(Rgba.Hex(0xFDF6E3), everforest.Light.Page);
        Assert.Equal(Rgba.Hex(0xF4ECD8), everforest.Light.Grouped);
        Assert.Equal(Rgba.White, everforest.Light.MeText);
        Assert.Equal(Rgba.Hex(0x232A2E), everforest.Dark.Grouped);
        Assert.Equal(Rgba.Hex(0xE8DEC8), everforest.Dark.MeText);

        var vercelResolved = ThemeResolver.Resolve(ThemeState.Default with { SkinId = "vercel" });
        Assert.Equal(Rgba.Hex(0xFFFFFF), vercelResolved.Light.Page);
        Assert.Equal(Rgba.Hex(0x000000), vercelResolved.Dark.Page);
        Assert.Equal(Rgba.Hex(0x006AFF), vercelResolved.Light.MeBubble);
        Assert.Equal(Rgba.White, vercelResolved.Light.MeText);
        Assert.Equal(Rgba.Hex(0x005CE0), vercelResolved.Dark.MeBubble);
        Assert.Equal(Rgba.White, vercelResolved.Dark.MeText);

        var monoResolved = ThemeResolver.Resolve(ThemeState.Default with { SkinId = "mono" });
        Assert.Equal(Rgba.Hex(0x0D0D0D), monoResolved.Dark.Page);
        Assert.Equal(Rgba.Hex(0x8E8E8E), monoResolved.Dark.ChosenRow);

        var cyberResolved = ThemeResolver.Resolve(ThemeState.Default with { SkinId = "cyberpunk" });
        Assert.Equal(Rgba.Hex(0x000A00), cyberResolved.Dark.Page);
        Assert.Equal(Rgba.Hex(0xA6FFC0), cyberResolved.Dark.MeText);
    }

    [Fact]
    public void AllNineteenSkinsPassLegibilityAndStandaloneCardElevation()
    {
        foreach (var skin in SkinCatalog.All)
        foreach (var (desktop, contrast) in new[] { (false, false), (true, false), (true, true) })
        {
            var set = ThemeResolver.Resolve(new ThemeState { SkinId = skin.Id, DesktopLook = desktop, HighContrast = contrast });
            foreach (var dark in new[] { false, true })
            {
                var t = set.Tokens(dark);
                var page = t.Page.Over(Rgba.White);
                var card = t.PromptCard.Over(page);
                Assert.True(t.Label.Over(page).Contrast(page) >= 4.5, $"{skin.Id} d={desktop} hc={contrast} dark={dark} label");
                Assert.True(t.TintText.Over(page).Contrast(page) >= 4.5, $"{skin.Id} d={desktop} hc={contrast} dark={dark} tintText");
                Assert.True(t.MeText.Over(t.MeBubble.Over(page)).Contrast(t.MeBubble.Over(page)) >= (skin.Id == "ios" && !desktop ? 4.0 : 4.5),
                    $"{skin.Id} d={desktop} hc={contrast} dark={dark} meText");
                Assert.True(card.LabDistance(page) >= 1.5, $"{skin.Id} d={desktop} hc={contrast} dark={dark} promptCard dE");
                Assert.True(t.PromptEdge.A > 0, $"{skin.Id} d={desktop} hc={contrast} dark={dark} promptEdge");
                Assert.True(t.Label.Over(card).Contrast(card) >= 4.5, $"{skin.Id} d={desktop} hc={contrast} dark={dark} label on card");
            }
        }
    }

    // ---------------------------------------------------------------- DarkInkBubble (687406870)

    [Fact]
    public void DarkInkBubbleUsesCoolSlateCharcoalOnNousAndHueMatchedStepElsewhere()
    {
        var nousDark = ThemeResolver.Resolve(ThemeState.Default).Dark;
        Assert.Equal(Rgba.Hex(0x363B44), ThemeResolver.DarkInkBubble(nousDark));
        var nousCustom = ThemeResolver.CustomMessageBubble(nousDark, Rgba.Hex(0x0A0A0A), dark: true);
        Assert.Equal(Rgba.Hex(0x363B44), nousCustom);
        Assert.True(Rgba.White.Contrast(nousCustom) >= ThemeResolver.MessageInk);

        // Other dark skins step clearly above reply bubble (dE >= 8) and keep white >= 4.7:1.
        foreach (var skinId in new[] { "codex", "notion", "vercel", "rose-pine", "night-owl", "lobster", "catppuccin" })
        {
            var t = ThemeResolver.Resolve(ThemeState.Default with { SkinId = skinId }).Dark;
            var bubble = ThemeResolver.CustomMessageBubble(t, Rgba.Hex(0x050505), dark: true);
            Assert.True(Rgba.White.Contrast(bubble) >= ThemeResolver.MessageInk, $"{skinId} white contrast < 4.7");
            var reply = t.BotBubble.Over(t.Page.Over(Rgba.White));
            Assert.True(bubble.LabDistance(reply) >= 8.0, $"{skinId} dark ink bubble too close to reply");
        }
    }

    // ---------------------------------------------------------------- DesktopRadius & ShapeRadius (a78139597)

    [Fact]
    public void DesktopRadiusStoresScalesByRoleAndLinksToDesktopBubbleCorners()
    {
        var prefs = new MemPrefs();
        var store = new ThemeStore(prefs);
        Assert.Equal(4.0, store.Load().DesktopRadius);
        Assert.Equal(new double[] { 0, 4, 8, 12, 16, 20 }, ThemeState.DesktopRadiusTicks);
        Assert.Equal("hqn.theme.desktopRadius", ThemeStore.Key.DesktopRadius);
        Assert.Contains(ThemeStore.Key.DesktopRadius, ThemeStore.Key.All);

        store.SetDesktopRadius(12);
        Assert.Equal("12", prefs.Get(ThemeStore.Key.DesktopRadius));
        var state = store.Load() with { DesktopLook = true };
        Assert.Equal(12, state.DesktopRadius);
        Assert.Equal(12, state.AppliedDesktopRadius);
        Assert.False(state.DesktopCornersOverridden);
        Assert.Equal(12, state.AppliedDesktopCorners);
        Assert.Equal(12, state.AppliedBubbleCorners);

        // Role scaling at 4 pt default, 0 pt square, 12 pt, and 20 pt.
        var r4 = ThemeState.Default with { DesktopLook = true, DesktopRadius = 4 };
        Assert.Equal(2, r4.ShapeRadius(ShapeRole.Inline, 10));
        Assert.Equal(3, r4.ShapeRadius(ShapeRole.Control, 10));
        Assert.Equal(3, r4.ShapeRadius(ShapeRole.Tile, 10));
        Assert.Equal(4, r4.ShapeRadius(ShapeRole.Card, 10));
        Assert.Equal(4, r4.ShapeRadius(ShapeRole.Bubble, 12));
        Assert.Equal(4, r4.ShapeRadius(ShapeRole.Field, 10));
        Assert.Equal(4, r4.ShapeRadius(ShapeRole.Capsule, 16));
        Assert.Equal(4, r4.ShapeRadius(ShapeRole.Group, 10));
        Assert.Equal(8, r4.ShapeRadius(ShapeRole.Sheet, 14));

        var r0 = r4 with { DesktopRadius = 0 };
        foreach (var role in Enum.GetValues<ShapeRole>())
            Assert.Equal(0, r0.ShapeRadius(role, 12));

        var r12 = r4 with { DesktopRadius = 12 };
        Assert.Equal(6, r12.ShapeRadius(ShapeRole.Inline, 10));
        Assert.Equal(9, r12.ShapeRadius(ShapeRole.Control, 10));
        Assert.Equal(12, r12.ShapeRadius(ShapeRole.Card, 10));
        Assert.Equal(16, r12.ShapeRadius(ShapeRole.Sheet, 10));

        // Native Look returns nativeBase unchanged.
        var native = ThemeState.Default with { DesktopLook = false, DesktopRadius = 16 };
        Assert.Equal(10, native.ShapeRadius(ShapeRole.Card, 10));
        Assert.Equal(14, native.ShapeRadius(ShapeRole.Sheet, 14));

        // Explicit Chat Bubbles override back to 4 pt while DesktopRadius is 12 pt.
        store.SetBubbleCorners(4, desktop: true);
        Assert.Equal("4", prefs.Get(ThemeStore.Key.DesktopCorners));
        var overridden = store.Load() with { DesktopLook = true };
        Assert.True(overridden.DesktopCornersOverridden);
        Assert.Equal(4, overridden.AppliedDesktopCorners);
        Assert.Equal(12, overridden.DesktopRadius);

        // Matching DesktopRadius clears the override.
        store.SetBubbleCorners(12, desktop: true);
        Assert.Null(prefs.Get(ThemeStore.Key.DesktopCorners));
        Assert.False(store.Load().DesktopCornersOverridden);

        // Clamping, garbage, and ResetDesktopRadius.
        store.SetDesktopRadius(99);
        Assert.Equal(20, store.Load().DesktopRadius);
        store.SetDesktopRadius(-5);
        Assert.Equal(0, store.Load().DesktopRadius);
        prefs.Set(ThemeStore.Key.DesktopRadius, "bad");
        Assert.Equal(4, store.Load().DesktopRadius);
        store.SetDesktopRadius(16);
        store.ResetDesktopRadius();
        Assert.Null(prefs.Get(ThemeStore.Key.DesktopRadius));
        Assert.Equal(4, store.Load().DesktopRadius);
    }

    // ---------------------------------------------------------------- Reply Bubbles in Hermes Look High Contrast (1a1f7200d)

    [Fact]
    public void AppliedPlainRepliesSupportsHermesLookHighContrastToggle()
    {
        var prefs = new MemPrefs();
        var store = new ThemeStore(prefs);

        // Native Look: follows PlainReplies.
        Assert.False((ThemeState.Default with { DesktopLook = false, PlainReplies = false }).AppliedPlainReplies);
        Assert.True((ThemeState.Default with { DesktopLook = false, PlainReplies = true }).AppliedPlainReplies);

        // Hermes Look without High Contrast: always plain, toggle disabled with note.
        var hermes = ThemeState.Default with { DesktopLook = true, HighContrast = false };
        Assert.True(hermes.AppliedPlainReplies);
        Assert.Equal("Hermes Look draws replies straight on the page unless High Contrast is on.", ChatBubbles.ReplyBubblesDisabledNote(hermes));
        Assert.False(ChatBubbles.ReplyBubblesEnabled(hermes));
        Assert.False(ChatBubbles.ReplyBubblesOn(hermes));

        // Hermes Look + High Contrast: boxed when PlainReplies=false, plain when PlainReplies=true!
        var hcBoxed = hermes with { HighContrast = true, PlainReplies = false };
        Assert.False(hcBoxed.AppliedPlainReplies);
        Assert.Null(ChatBubbles.ReplyBubblesDisabledNote(hcBoxed));
        Assert.True(ChatBubbles.ReplyBubblesEnabled(hcBoxed));
        Assert.True(ChatBubbles.ReplyBubblesOn(hcBoxed));

        store.SetPlainReplies(true);
        Assert.Equal("true", prefs.Get(ThemeStore.Key.PlainReplies));
        var hcPlain = store.Load() with { DesktopLook = true, HighContrast = true };
        Assert.True(hcPlain.AppliedPlainReplies);
        Assert.True(ChatBubbles.ReplyBubblesEnabled(hcPlain));
        Assert.False(ChatBubbles.ReplyBubblesOn(hcPlain));

        store.SetPlainReplies(false);
        Assert.Null(prefs.Get(ThemeStore.Key.PlainReplies));

        // Paper skin in Native Look disables Reply Bubbles with skin note.
        var paper = ThemeState.Default with { SkinId = "paper", DesktopLook = false };
        Assert.True(ChatBubbles.SkinDrawsPlainReplies(paper));
        Assert.Equal("Paper draws replies straight on the page.", ChatBubbles.ReplyBubblesDisabledNote(paper));
    }

    // ---------------------------------------------------------------- WindowTransparency (e2f3aaf39)

    [Fact]
    public void WindowTransparencyPersistsFiresChangedAndComputesGlassColors()
    {
        var previousStore = WindowTransparency.Store;
        var prefs = new MemPrefs();
        var changes = 0;
        void OnChanged() => changes++;
        WindowTransparency.Changed += OnChanged;
        try
        {
            WindowTransparency.Store = prefs;
            WindowTransparency.Reset();
            Assert.Equal("hqn.macWindowTransparency", WindowTransparency.PrefKey);
            Assert.Equal(10, WindowTransparency.CanvasInset);
            Assert.Equal(15, WindowTransparency.CanvasCornerRadius);
            Assert.Equal(46, WindowTransparency.TopBarHeight);

            Assert.True(WindowTransparency.IsEnabled);
            Assert.True(WindowTransparency.IsEffective(reduceTransparency: false));
            Assert.False(WindowTransparency.IsEffective(reduceTransparency: true));

            WindowTransparency.IsEnabled = false;
            Assert.False(WindowTransparency.IsEnabled);
            Assert.Equal("false", prefs.Get(WindowTransparency.PrefKey));
            Assert.False(WindowTransparency.IsEffective(reduceTransparency: false));
            Assert.Equal(1, changes);

            WindowTransparency.Reset();
            Assert.True(WindowTransparency.IsEnabled);
            Assert.Null(prefs.Get(WindowTransparency.PrefKey));
            Assert.Equal(2, changes);

            // Layered glass colors on standard look and custom skin.
            var std = ThemeResolver.Resolve(ThemeState.Default);
            Assert.Equal(0.40, WindowTransparency.GlassVeilColor(std, dark: true).A, 3);
            Assert.Equal(0.34, WindowTransparency.GlassVeilColor(std, dark: false).A, 3);
            Assert.Equal(0.76, WindowTransparency.CanvasSurfaceColor(std, dark: true, transparent: true).A, 3);
            Assert.Equal(0.84, WindowTransparency.CanvasSurfaceColor(std, dark: false, transparent: true).A, 3);
            Assert.Equal(std.Dark.Page, WindowTransparency.CanvasSurfaceColor(std, dark: true, transparent: false));
            Assert.Equal(0.42, WindowTransparency.CanvasBarVeilColor(std, dark: true, transparent: true).A, 3);
            Assert.Equal(1.0, WindowTransparency.CanvasBarVeilColor(std, dark: true, transparent: false).A, 3);
            Assert.Equal(0.94, WindowTransparency.CanvasPageBarVeilColor(std, dark: true).A, 3);
            Assert.Equal(0.115, WindowTransparency.CanvasBorderColor(dark: true).A, 3);
            Assert.Equal(0.08, WindowTransparency.CanvasBorderColor(dark: false).A, 3);
            Assert.Equal(1.0, WindowTransparency.FallbackShellColor(std, dark: true).A, 3);

            var custom = ThemeResolver.Resolve(ThemeState.Default with { SkinId = "catppuccin" });
            Assert.Equal(0.52, WindowTransparency.GlassVeilColor(custom, dark: true).A, 3);
            Assert.Equal(0.50, WindowTransparency.GlassVeilColor(custom, dark: false).A, 3);
            Assert.Equal(0.78, WindowTransparency.CanvasSurfaceColor(custom, dark: true, transparent: true).A, 3);
        }
        finally
        {
            WindowTransparency.Changed -= OnChanged;
            WindowTransparency.Store = previousStore;
            WindowTransparency.Reset();
        }
    }

    // ---------------------------------------------------------------- WhisperLine & Frosted Chrome (ddcf7975e)

    [Fact]
    public void WhisperLineUsesSubtleAlphaAndFullSeparatorInHighContrast()
    {
        var plain = ThemeResolver.Resolve(ThemeState.Default with { DesktopLook = true, HighContrast = false });
        Assert.Equal(0.07, plain.Light.WhisperLine.A, 3);
        Assert.Equal(0.09, plain.Dark.WhisperLine.A, 3);
        Assert.Equal(plain.Light.Label.R, plain.Light.WhisperLine.R, 4);
        Assert.Equal(plain.Dark.Label.R, plain.Dark.WhisperLine.R, 4);

        var contrast = ThemeResolver.Resolve(ThemeState.Default with { DesktopLook = true, HighContrast = true });
        Assert.Equal(contrast.Light.Separator, contrast.Light.WhisperLine);
        Assert.Equal(contrast.Dark.Separator, contrast.Dark.WhisperLine);

        Assert.Equal(0.94, ThemeResolver.FrostedBarVeil(plain.Dark, reduceTransparency: false).A, 3);
        Assert.Equal(1.0, ThemeResolver.FrostedBarVeil(plain.Dark, reduceTransparency: true).A, 3);
    }

    // ---------------------------------------------------------------- Backgrounds CardStyle, Categories & Wash

    [Fact]
    public void BackdropCardStyleCategoriesAndResetAppearanceRoundTrip()
    {
        var prefs = new MemPrefs();
        var backdrops = new BackdropPrefs(prefs);
        Assert.Equal("Wash", BackdropPrefs.WashLabel);
        Assert.Equal("hqn.appBackground.cardStyle", CardStyles.Key);
        Assert.Equal(["Classic", "Solids", "Photo", "Illustrated", "Painted", "Doodles"],
            BackdropGroups.All.Select(g => g.ShortTitle()));
        Assert.Equal(10, BackdropCatalog.Classic.Count);
        Assert.Equal(11, BackdropCatalog.Solids.Count);
        Assert.Equal(8, BackdropCatalog.Photographic.Count);
        Assert.Equal(8, BackdropCatalog.Illustrated.Count);
        Assert.Equal(8, BackdropCatalog.Painted.Count);
        Assert.Equal(8, BackdropCatalog.Doodles.Count);
        Assert.Equal(53, BackdropCatalog.All.Count);
        Assert.Equal("photoAlpenglow", BackdropCatalog.Find("alpenglow")?.Id);

        Assert.Equal(CardStyle.Off, backdrops.Load(BackdropPlace.App).CardStyle);

        backdrops.SetCardStyle(CardStyle.Glass);
        Assert.Equal("glass", prefs.Get(CardStyles.Key));
        var loadedGlass = backdrops.Load(BackdropPlace.App);
        Assert.True(loadedGlass.Cards);
        Assert.Equal(CardStyle.Glass, loadedGlass.CardStyle);
        Assert.Equal(CardStyle.Solid, loadedGlass.CardStyle.Effective(reduceTransparency: true));

        backdrops.SetCardStyle(CardStyle.Solid);
        Assert.Equal("solid", prefs.Get(CardStyles.Key));
        Assert.Equal(CardStyle.Solid, backdrops.Load(BackdropPlace.App).CardStyle);

        backdrops.SetCardStyle(CardStyle.Tinted);
        Assert.Null(prefs.Get(CardStyles.Key));
        Assert.Equal(CardStyle.Tinted, backdrops.Load(BackdropPlace.App).CardStyle);

        backdrops.SetCardStyle(CardStyle.Off);
        Assert.False(backdrops.Load(BackdropPlace.App).Cards);
        Assert.Equal(CardStyle.Off, backdrops.Load(BackdropPlace.App).CardStyle);

        // ThemeStore.ResetAppearance clears theme, appearance, backdrops, working ring, and window transparency.
        var store = new ThemeStore(prefs);
        store.PickSkin("codex");
        store.SetDesktopLook(true);
        store.SetDesktopRadius(14);
        store.SetPlainReplies(true);
        Appearance.Write(prefs, AppearanceSetting.Dark);
        backdrops.SetPreset(BackdropPlace.App, "photoAurora");
        backdrops.SetCardStyle(CardStyle.Glass);
        WindowTransparency.Write(prefs, false);
        prefs.Set(WorkingRing.Key, "true");

        store.ResetAppearance();
        Assert.Equal(ThemeState.Default, store.Load());
        Assert.Equal(AppearanceSetting.System, Appearance.Read(prefs));
        Assert.Null(backdrops.Load(BackdropPlace.App).Source);
        Assert.Equal(CardStyle.Off, backdrops.Load(BackdropPlace.App).CardStyle);
        Assert.True(WindowTransparency.Read(prefs));
        Assert.False(WorkingRing.Read(prefs));
    }
}
