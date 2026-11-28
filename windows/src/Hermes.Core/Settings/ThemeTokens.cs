namespace Hermes.Core.Settings;

/// One resolved colour set per mode (HermesKit/Theme/ThemeTokens.swift; spec 3x-desktoplook §4.3, §5.1, §5.5, §6).
public sealed record ThemeTokens
{
    public Rgba Page { get; set; }
    public Rgba Label { get; set; }
    public Rgba Label2 { get; set; }
    public Rgba Label3 { get; set; }
    public Rgba Tint { get; set; }
    public Rgba TintText { get; set; }
    public Rgba OnTint { get; set; }
    public Rgba Separator { get; set; }
    public Rgba Fill1 { get; set; }
    public Rgba Fill2 { get; set; }
    public Rgba Fill2OnPage { get; set; }
    public Rgba Fill3 { get; set; }
    public Rgba Fill4 { get; set; }
    public Rgba CellPressed { get; set; }
    public Rgba GroupedCard { get; set; }
    public Rgba Lifted { get; set; }
    public Rgba SearchFill { get; set; }
    public Rgba Orange { get; set; }
    public Rgba Red { get; set; }
    public Rgba AlertRed { get; set; }
    public Rgba Green { get; set; }
    public Rgba Muted { get; set; }
    public Rgba BotBubble { get; set; }
    /// [cards] A standalone card in the chat (draft, approval, ask, question, order, product, offer, error, expanded
    /// tool or phone card): lifted off Page with a crisp border (PromptEdge) in every skin, look and mode.
    public Rgba PromptCard { get; set; }
    public Rgba PromptEdge { get; set; }
    public Rgba MeBubble { get; set; }
    public Rgba MeText { get; set; }
    public Rgba MeTime { get; set; }
    public Rgba CodeFill { get; set; }
    public Rgba CodeFillOnBubble { get; set; }
    public Rgba CodeText { get; set; }
    public Rgba Grouped { get; set; }
    public Rgba StatusWorking { get; set; }
    /// Cards, the message bar, code: the desktop's editor surface.
    public Rgba Editor { get; set; }
    /// Floating panels.
    public Rgba Elevated { get; set; }
    /// The sidebar's ground.
    public Rgba Sidebar { get; set; }
    /// [WIN-ROW-FACE-RING-PANEL] What the Mac's sidebar rows and rail faces sit on (App/Mac/MacSidebar.swift
    /// `panelColor`): the Desktop Look's raised panel (`Sidebar`), else the glass panel's tint made solid
    /// (`ThemeResolver.GlassTint`). A sidebar face's badges are ringed in it (Mac polish #55).
    public Rgba SidebarPanel { get; set; }
    public Rgba StrokePrimary { get; set; }
    public Rgba StrokeSecondary { get; set; }
    public Rgba StrokeTertiary { get; set; }
    public Rgba MeBorder { get; set; }
    public Rgba ComposerBorder { get; set; }
    public Rgba ComposerGlyph { get; set; }
    public Rgba Caret { get; set; }
    public Rgba TabIdle { get; set; }
    /// [crisp-frosted-chrome] Whisper hairline framing frosted top and bottom bars (App/Theme/DesktopFrost.swift
    /// `whisperLine`): `0.09` dark / `0.07` light alpha of `Label`, or full `Separator` under high contrast.
    public Rgba WhisperLine { get; set; }
    /// A skin's own iOS look, null for the general rules and in the Desktop Look.
    public SkinOwnLook? OwnLook { get; set; }
    /// The colour of the chosen row where it isn't the tint (Paper's warm grey).
    public Rgba? RowAccent { get; set; }

    public Rgba ChosenRow => RowAccent ?? Tint;
    public Rgba IconTile => OwnLook?.IconTile ?? Rgba.Clear;
    // ChatCells.swift:519–546 (Mac 1245). Only the painted reply gets softer, not every
    // consumer of BotBubble. Multiply the resolved skin's alpha rather than replacing it.
    internal bool SoftReply { get; set; }
    public Rgba ReplyFill => SoftReply ? BotBubble.Alpha(BotBubble.A * 0.5) : BotBubble;
    public Rgba ReplyEdge => SoftReply ? Label.Alpha(Label.A * 0.12) : OwnLook?.ReplyEdge ?? Rgba.Clear;

    public ThemeTokens Copy() => this with { };
}

/// Light and dark tokens plus the state they came from.
public sealed record ThemeSet(ThemeState State, ThemeTokens Light, ThemeTokens Dark, bool? ForcedDark)
{
    public ThemeTokens Tokens(bool dark) => dark ? Dark : Light;

    /// The app's standard look: no skin picked and the Desktop Look off.
    public bool IsStandardLook => !State.DesktopLook && State.SkinId == SkinCatalog.DefaultId;

    /// True when the grouped page uses the platform's own neutral palette (Nous or Apple System in Native Look;
    /// HermesKit/Theme/ThemeTokens.swift `groupedPageIsSystem`).
    public bool GroupedPageIsSystem =>
        !State.DesktopLook && (State.SkinId == SkinCatalog.DefaultId || State.SkinId == SkinCatalog.IosId);
}

public static class ThemeResolver
{
    /// [bubble-ink] Minimum contrast ratio for white words on a picked or bot message bubble (`ThemeTokens.swift`).
    public const double MessageInk = 4.7;
    /// [crisp-frosted-chrome] Frosted bar veil alphas (`App/Theme/DesktopFrost.swift`, `ddcf7975e`).
    public const double DesktopBarTintAlpha = 0.94;
    public const double CompactBarTintAlpha = 0.72;
    public const double TabBarTintAlpha = 0.76;

    public static ThemeSet Resolve(ThemeState state)
    {
        var skin = state.Skin;
        ThemeTokens Tokens(bool wantsDark, bool contrast)
        {
            var seeds = skin.Seeds(wantsDark);
            // A palette is painted in the mode its own background says (`renderedModeFor`).
            var dark = skin.Id == SkinCatalog.DefaultId && !state.DesktopLook ? wantsDark : seeds.RendersDark;
            var tokens = state.DesktopLook ? Desktop(seeds, dark, contrast) : Ios(skin, seeds, dark);
            tokens.SidebarPanel = SidebarPanel(tokens, state.DesktopLook, dark);
            return tokens;
        }
        bool? forced = skin.HasOneLook ? skin.Light.RendersDark : null;
        return new ThemeSet(state, Tokens(false, state.HighContrast), Tokens(true, state.HighContrast), forced);
    }

    /// [crisp-frosted-chrome] Whisper hairline framing frosted bars (`DesktopFrost.whisperLine`, `ddcf7975e`):
    /// `0.09` dark / `0.07` light alpha of `Label`, or full `Separator` when high contrast is active.
    public static Rgba WhisperLine(ThemeTokens t, bool dark, bool highContrast) =>
        highContrast ? t.Separator : t.Label.Alpha(dark ? 0.09 : 0.07);

    /// [crisp-frosted-chrome] Frosted top bar veil (`DesktopFrost.barAppearance`, `ddcf7975e`):
    /// solid `Page` when `reduceTransparency` is true, else `Page` at `DesktopBarTintAlpha` (0.94).
    public static Rgba FrostedBarVeil(ThemeTokens t, bool reduceTransparency = false) =>
        reduceTransparency ? t.Page.Alpha(1) : t.Page.Alpha(DesktopBarTintAlpha);

    /// [bot-colour] A near-black message colour (an ink face) in dark mode (`687406870`): `#363B44` cool slate
    /// charcoal on Nous dark, and a hue-matched step above the reply bubble on every other skin (ΔE >= 8 while
    /// preserving >= 4.7 white contrast) so it never turns warm or washes out memo cards.
    public static Rgba DarkInkBubble(ThemeTokens t)
    {
        if (t.Page == Rgba.Hex(0x0D1015) && t.BotBubble == Rgba.Hex(0x26282C))
            return Rgba.Hex(0x363B44);
        var page = t.Page.Over(Rgba.White);
        var reply = t.BotBubble.Over(page);
        var ink = t.Label.Over(page);
        var @base = reply.Luminance > page.Luminance ? reply : page.Mix(90, ink);
        var keep = 88.0;
        var bubble = @base.Mix(keep, ink);
        while (keep > 50 && bubble.LabDistance(reply) < 8)
        {
            keep -= 2;
            var next = @base.Mix(keep, ink);
            if (Rgba.White.Contrast(next) < MessageInk) break;
            bubble = next;
        }
        return bubble;
    }

    /// Resolves a custom message bubble color (`ThemeTokens.swift` `paintMessage(.custom)`): when `dark` and
    /// `seed.LabL < 10`, delegates to `DarkInkBubble(t)`, deepening toward black if needed for `MessageInk` (4.7:1).
    public static Rgba CustomMessageBubble(ThemeTokens t, Rgba seed, bool dark)
    {
        var start = dark && seed.LabL < 10
            ? DarkInkBubble(t)
            : (dark ? seed.RaisingL(57).Mix(75, Rgba.Black) : seed);
        var bubble = start;
        var keep = 100.0;
        while (keep > 0 && Rgba.White.Contrast(bubble) < MessageInk)
        {
            keep -= 1;
            bubble = start.Mix(keep, Rgba.Black);
        }
        return bubble;
    }

    /// [WIN-ROW-FACE-RING-PANEL] The sidebar's panel (MacSidebar.swift `panelColor` at 93f984bb1): `Theme.isDesktop ?
    /// ChatPalette.sidebar : glassTintColor` with its alpha made 1.
    public static Rgba SidebarPanel(ThemeTokens t, bool desktopLook, bool dark) =>
        desktopLook ? t.Sidebar.Alpha(1) : GlassTint(t.Page, t.Label, dark).Alpha(1);

    /// [sidebar-light] The glass panel's tint (MacSidebar.swift `glassTintColor`): the page's colour 10 % of the way to its
    /// ink in light, 14 % in dark, at 0.85. The ink's channels as `getRed` reads them (its own alpha left out).
    public static Rgba GlassTint(Rgba page, Rgba label, bool dark) => ChatVisualTokens.GlassTint(page, label, dark);

    // ---------------------------------------------------------------- the iOS look (the Windows app's standard look)

    /// The Nous palette the app shipped with (spec 06 §1.2).
    public static ThemeTokens Base(bool dark)
    {
        Rgba Pick(Rgba light, Rgba darkValue) => dark ? darkValue : light;
        var chat = dark ? ChatVisualTokens.Dark : ChatVisualTokens.Light;
        var ink = chat.Ink;
        var page = chat.Page;
        var separator = Pick(Rgba.C(60, 60, 67, 0.29), Rgba.C(84, 84, 88, 0.6));
        var groupedCard = Pick(Rgba.Hex(0xF2F2F7), Rgba.Hex(0x1C1C1E));
        var tint = chat.Accent;
        return new ThemeTokens
        {
            Page = page, Label = ink.Alpha(0.94), Label2 = ink.Alpha(0.74), Label3 = ink.Alpha(0.36),
            Tint = tint, TintText = Pick(Rgba.Hex(0x0040DD), Rgba.Hex(0x0A84FF)), OnTint = Rgba.White,
            Separator = separator,
            Fill1 = Pick(Rgba.C(120, 120, 128, 0.2), Rgba.C(120, 120, 128, 0.36)),
            Fill2 = Pick(Rgba.C(120, 120, 128, 0.16), Rgba.C(120, 120, 128, 0.32)),
            Fill2OnPage = Pick(Rgba.C(232.6, 232.6, 233.8), Rgba.C(47.2, 49.3, 55.2)),
            Fill3 = Pick(Rgba.C(118, 118, 128, 0.12), Rgba.C(118, 118, 128, 0.24)),
            Fill4 = Pick(Rgba.C(116, 116, 128, 0.08), Rgba.C(118, 118, 128, 0.18)),
            CellPressed = Pick(Rgba.Hex(0xD1D1D6), Rgba.Hex(0x2C2C2E)),
            GroupedCard = groupedCard, Lifted = Pick(Rgba.Hex(0xFFFFFF), Rgba.Hex(0x1C1C1E)),
            SearchFill = Rgba.C(118, 118, 128, 0.12),
            Orange = Pick(Rgba.Hex(0xC93400), Rgba.Hex(0xFF9F0A)), Red = Pick(Rgba.Hex(0xD70015), Rgba.Hex(0xFF453A)),
            AlertRed = Pick(Rgba.Hex(0xFF3B30), Rgba.Hex(0xFF453A)),
            Green = Pick(Rgba.Hex(0x248A3D), Rgba.Hex(0x30D158)), Muted = Rgba.Hex(0x8E8E93),
            BotBubble = chat.Incoming,
            PromptCard = chat.Incoming,
            PromptEdge = Pick(Rgba.C(60, 60, 67, 0.22), Rgba.C(255, 255, 255, 0.14)),
            MeBubble = chat.Outgoing, MeText = Rgba.White, MeTime = chat.OutgoingTime,
            CodeFill = Pick(Rgba.C(116, 116, 128, 0.08), Rgba.Hex(0x1F2023)),
            CodeFillOnBubble = Pick(Rgba.C(223.6, 223.6, 226.4), Rgba.Hex(0x1F2023)),
            CodeText = Pick(Rgba.Hex(0x1F2328), Rgba.Hex(0xA1ABB5)),
            Grouped = Pick(Rgba.Hex(0xF6F8FA), Rgba.Hex(0x010409)),
            StatusWorking = Pick(Rgba.Hex(0x0040DD), Rgba.Hex(0xE6EDF3, 0.94)),
            Editor = groupedCard, Elevated = groupedCard, Sidebar = Pick(Rgba.Hex(0xF6F8FA), Rgba.Hex(0x010409)),
            StrokePrimary = separator, StrokeSecondary = separator, StrokeTertiary = separator,
            MeBorder = Rgba.Clear, ComposerBorder = separator, ComposerGlyph = ink.Alpha(0.74), Caret = tint,
            TabIdle = ink.Alpha(0.36),
            WhisperLine = ink.Alpha(dark ? 0.09 : 0.07),
        };
    }

    /// The desktop's chat surface (`--ui-bg-chrome`): the skin's background pulled toward a neutral.
    public static Rgba Chrome(SkinSeeds seeds, bool dark) =>
        seeds.Background.Mix(dark ? 74 : 92, dark ? Rgba.Hex(0x0D0D0E) : Rgba.Hex(0xF3F3F3));

    /// A skin in the iOS look: it gives the page, the text and the accent; cells, fills, separators and the bot bubble
    /// stay the app's own palette (phone-ui-desktop.css:3-4).
    public static ThemeTokens Ios(Skin skin, SkinSeeds seeds, bool dark)
    {
        var t = Base(dark);
        if (skin.Id == SkinCatalog.DefaultId) return t;
        var ink = seeds.Foreground;
        if (skin.Id == SkinCatalog.IosId)
        {
            t.Page = dark ? Rgba.Black : Rgba.White;
            t.Label = dark ? Rgba.White : Rgba.Black;
            t.Label2 = dark ? Rgba.C(235, 235, 245, 0.6) : Rgba.C(60, 60, 67, 0.6);
            t.Label3 = dark ? Rgba.C(235, 235, 245, 0.3) : Rgba.C(60, 60, 67, 0.3);
            t.Tint = dark ? Rgba.Hex(0x0A84FF) : Rgba.Hex(0x007AFF);
            t.TintText = dark ? Rgba.Hex(0x0A84FF) : Rgba.Hex(0x0040DD);
            t.CellPressed = dark ? Rgba.Hex(0x3A3A3C) : Rgba.Hex(0xD1D1D6);
            t.Grouped = dark ? Rgba.Black : Rgba.Hex(0xF2F2F7);
            t.CodeFill = dark ? Rgba.Hex(0x1C1C1E) : Rgba.Hex(0xF2F2F7);
        }
        else
        {
            var own = skin.OwnLook?.Pick(dark);
            var neutral = seeds.MutedForeground;
            t.Page = own?.Page ?? Chrome(seeds, dark);
            t.Label = ink.Alpha(0.94);
            t.Label2 = ThemeMath.Readable(own?.Subtle ?? ink.Alpha(0.74), ink.Alpha(0.94), t.Page);
            t.Label3 = own?.Muted ?? ink.Alpha(0.36);
            // In dark an accent is brightened to CIELAB L 57, as iOS brightens its tints.
            t.Tint = dark ? seeds.Brand.RaisingL(57) : seeds.Brand;
            t.TintText = ThemeMath.Readable(t.Tint, t.Label, t.Page);
            var rawGrouped = seeds.SidebarBackground ?? seeds.Background;
            t.Grouped = !dark && rawGrouped == seeds.Background ? t.Page.Mix(94, neutral) : rawGrouped;
            t.CodeText = dark ? ink.Mix(72, t.Page) : ink;
            // Hue-matched neutrals for every custom skin (HermesKit/Theme/ThemeTokens.swift:214-225).
            t.Fill1 = neutral.Alpha(dark ? 0.32 : 0.18);
            t.Fill2 = neutral.Alpha(dark ? 0.26 : 0.14);
            t.Fill3 = neutral.Alpha(dark ? 0.20 : 0.11);
            t.Fill4 = neutral.Alpha(dark ? 0.14 : 0.08);
            t.Separator = neutral.Alpha(dark ? 0.36 : 0.28);
            t.StrokePrimary = t.Separator;
            t.StrokeSecondary = t.Separator;
            t.StrokeTertiary = t.Separator;
            t.SearchFill = neutral.Alpha(dark ? 0.18 : 0.12);
            t.Muted = neutral;
            // Cards lift gently off the grouped canvas in light mode and rise a step in ink in dark mode.
            var card = dark ? t.Page.Mix(91, ink) : (t.Page.LabL > 96 ? Rgba.White : t.Page.Mix(32, Rgba.White));
            t.GroupedCard = card;
            t.Lifted = dark ? card : t.Page.Mix(24, Rgba.White);
            t.Editor = card;
            t.Elevated = card;
            t.CellPressed = t.Page.Mix(dark ? 83 : 88, ink);
            t.BotBubble = t.Page.Mix(dark ? 87 : 91, ink);
            // [cards] Standalone cards keep the bubble's elevation when primary text reads at 4.5:1 on it; otherwise
            // they lift cleanly off the page with a border in the skin's hue.
            t.PromptCard = t.Label.Over(t.BotBubble).Contrast(t.BotBubble) >= 4.5
                ? t.BotBubble
                : LiftedCard(t.Page, ink, t.Label, dark, contrast: false);
            t.PromptEdge = ink.Alpha(dark ? 0.16 : 0.14);
            if (dark)
            {
                t.CodeFill = t.Page.Mix(95, ink);
                t.CodeFillOnBubble = t.CodeFill;
            }
            else
            {
                t.CodeFill = t.Page.Mix(94, ink);
                t.CodeFillOnBubble = t.CodeFill.Over(t.BotBubble);
            }
            if (own != null)
            {
                Paint(t, own, ink);
                t.OwnLook = own;
                if (own.ChosenRow is { } row) t.RowAccent = row;
            }
        }
        t.OnTint = t.Tint.LabL >= 60 ? Rgba.Black : Rgba.White;
        if (skin.OwnLook?.Pick(dark) is { } ownLook)
        {
            // Your message is the theme's own soft box with its explicit ink or the theme's text.
            var meInk = ownLook.MeText ?? t.Label;
            var meTimeSeed = ownLook.MeText != null ? meInk.Alpha(dark ? 0.88 : 0.85) : ownLook.Subtle;
            t.MeBubble = ownLook.MeBubble;
            t.MeText = meInk;
            t.MeTime = ThemeMath.Readable(meTimeSeed, meInk, ownLook.MeBubble.Over(t.Page), 3);
        }
        else
        {
            t.MeBubble = dark ? t.Tint.Mix(75, Rgba.Black) : t.Tint;
            // White, as iOS writes on its own blue; an accent white nearly reads on (3:1 or better) is deepened just
            // enough for white to reach 4.5:1, instead of turning the text black.
            if (skin.Id != SkinCatalog.IosId && Rgba.White.Contrast(t.MeBubble.Over(t.Page)) >= 3)
            {
                var accent = t.MeBubble;
                var keep = 100.0;
                while (keep > 60 && Rgba.White.Contrast(t.MeBubble.Over(t.Page)) < 4.5)
                {
                    keep -= 2;
                    t.MeBubble = accent.Mix(keep, Rgba.Black);
                }
            }
            var meGround = t.MeBubble.Over(t.Page);
            var whiteReads = Rgba.White.Contrast(meGround) >= 4.5 || skin.Id == SkinCatalog.IosId;
            var meInk = whiteReads || Rgba.White.Contrast(meGround) >= Rgba.Black.Contrast(meGround) ? Rgba.White : Rgba.Black;
            t.MeText = meInk;
            t.MeTime = meInk.Alpha(dark ? 0.88 : 0.85);
        }
        t.StatusWorking = dark ? t.Label : t.TintText;
        t.Fill2OnPage = t.Fill2.Over(t.Page);
        t.Sidebar = t.Grouped;
        t.TabIdle = t.Label3;
        t.WhisperLine = WhisperLine(t, dark, highContrast: false);
        return t;
    }

    /// A skin's own iOS look over what the general rule made: its surfaces, its greys, its code card.
    private static void Paint(ThemeTokens t, SkinOwnLook own, Rgba ink)
    {
        t.GroupedCard = own.Card; t.Lifted = own.Card; t.Editor = own.Card; t.Elevated = own.Card;
        if (own.Grouped is { } grouped) t.Grouped = grouped;
        t.BotBubble = own.Reply ?? own.Card;
        t.PromptCard = own.Card;
        t.PromptEdge = own.Separator;
        t.CellPressed = own.Pressed;
        t.CodeFill = own.CodeFill; t.CodeFillOnBubble = own.CodeFill;
        t.CodeText = ink;
        t.Fill1 = own.Grey.Alpha(own.FillAlphas[0]);
        t.Fill2 = own.Grey.Alpha(own.FillAlphas[1]);
        t.Fill3 = own.Grey.Alpha(own.FillAlphas[2]);
        t.Fill4 = own.Grey.Alpha(own.FillAlphas[3]);
        t.SearchFill = own.Grey.Alpha(0.12);
        t.Separator = own.Separator;
        t.StrokePrimary = own.Separator;
        t.StrokeSecondary = own.Separator;
        t.StrokeTertiary = own.Separator;
        t.Muted = own.Muted;
    }

    // ---------------------------------------------------------------- the Desktop Look

    /// The desktop's own mixes (styles.css:297-399) mapped to the app's tokens, then High Contrast on top
    /// (phone-ui-contrast.css:10-49).
    public static ThemeTokens Desktop(SkinSeeds seeds, bool dark, bool contrast)
    {
        var t = Base(dark);
        Rgba ink = seeds.Foreground, accent = seeds.Brand;
        var neutralCard = dark ? Rgba.Hex(0x161618) : Rgba.Hex(0xFCFCFC);
        var page = Chrome(seeds, dark);
        var editor = seeds.Card.Mix(dark ? 38 : 22, neutralCard);
        var elevated = seeds.Popover.Mix(dark ? 46 : 28, neutralCard);
        var sidebar = seeds.SidebarBackground ?? seeds.Background;
        Rgba textPrimary = ink.Alpha(0.94), textSecondary = ink.Alpha(0.74), textTertiary = ink.Alpha(0.54);
        var textQuaternary = ink.Alpha(0.36);
        Rgba Tinted(double accentShare, double inkShare) => accent.Mix(accentShare, ink.Faded(inkShare));
        Rgba strokePrimary = Tinted(24, 10), strokeSecondary = Tinted(16, 7), strokeTertiary = Tinted(10, 5);
        Rgba bgTertiary = Tinted(8, 5), bgQuaternary = Tinted(5, 4);
        var bgCard = Tinted(4, 4);
        var rowActive = Tinted(8, 5);
        var meBubble = (seeds.UserBubble ?? seeds.Popover).Mix(dark ? 46 : 0, neutralCard);
        var meBorder = seeds.UserBubbleBorder ?? seeds.Border;
        // Repair skins (such as Everforest) whose seed border equals the page background so the message box keeps an edge.
        var pageGround = page.Over(Rgba.White);
        var bubbleGround = meBubble.Over(pageGround);
        if (meBorder.Over(pageGround).Contrast(pageGround) < 1.15 &&
            meBorder.Over(bubbleGround).Contrast(bubbleGround) < 1.15)
        {
            meBorder = strokePrimary;
        }
        // Legible colours (desktop-look.ts:64-128).
        var accentText = ThemeMath.Legible(accent, textPrimary, page);
        var label2 = ThemeMath.Legible(textSecondary, textPrimary, page);
        var label3 = textTertiary;
        var separator = strokeSecondary;
        var fill1 = bgQuaternary;
        var composerBorder = strokePrimary;
        var tabIdle = textTertiary;
        if (contrast)
        {
            strokePrimary = textPrimary.Faded(18); strokeSecondary = textPrimary.Faded(13); strokeTertiary = textPrimary.Faded(10);
            separator = strokeTertiary;
            label2 = label2.MixOklab(65, textPrimary);
            label3 = textTertiary.MixOklab(70, textPrimary);
            var solidInk = textPrimary.Over(page);
            editor = solidInk.MixOklab(dark ? 10 : 5, page);
            bgCard = editor;
            fill1 = solidInk.MixOklab(12, page);
            rowActive = accent.MixOklab(dark ? 22 : 14, page);
            meBubble = accent.MixOklab(dark ? 28 : 13, page);
            meBorder = accent.MixOklab(dark ? 75 : 65, page);
            composerBorder = textPrimary.Faded(50);
            tabIdle = label2;
        }
        t.Page = page;
        t.Label = textPrimary; t.Label2 = label2; t.Label3 = label3;
        t.Tint = accentText; t.TintText = accentText;
        t.OnTint = accentText.Over(page).LabL >= 60 ? Rgba.Black : Rgba.White;
        t.Separator = separator;
        t.Fill1 = fill1; t.Fill2 = bgTertiary; t.Fill3 = bgTertiary; t.Fill4 = bgCard;
        t.Fill2OnPage = bgTertiary.Over(page);
        t.CellPressed = rowActive.Over(page);
        t.GroupedCard = editor; t.Lifted = editor;
        t.SearchFill = bgTertiary;
        t.Muted = textQuaternary.Over(page);
        t.BotBubble = editor;
        t.PromptCard = LiftedCard(page, ink, textPrimary, dark, contrast);
        t.PromptEdge = contrast ? strokePrimary : strokeSecondary;
        t.SoftReply = contrast;
        // Your message is text on a box. Where a skin's box is too close to its text, the text goes toward plain black
        // or white until it reads.
        var meGround = meBubble.Over(page.Over(Rgba.White));
        var strongest = Rgba.White.Contrast(meGround) >= Rgba.Black.Contrast(meGround) ? Rgba.White : Rgba.Black;
        var meInk = textPrimary;
        for (var keep = 100.0; keep >= 0; keep -= 10)
        {
            meInk = textPrimary.MixOklab(keep, strongest);
            if (meInk.Over(meGround).Contrast(meGround) >= 4.5) break;
        }
        t.MeBubble = meBubble; t.MeText = meInk; t.MeTime = textTertiary;
        t.CodeFill = editor; t.CodeFillOnBubble = editor;
        t.CodeText = ink.Alpha(0.86).Over(editor);
        t.Grouped = page;
        t.StatusWorking = dark ? textPrimary : accentText;
        t.Editor = editor; t.Elevated = elevated; t.Sidebar = sidebar;
        t.StrokePrimary = strokePrimary; t.StrokeSecondary = strokeSecondary; t.StrokeTertiary = strokeTertiary;
        t.MeBorder = meBorder; t.ComposerBorder = composerBorder; t.TabIdle = tabIdle;
        t.ComposerGlyph = label3; t.Caret = textPrimary;
        t.WhisperLine = WhisperLine(t, dark, contrast);
        // Status colours keep the system's own, in the shade that reads on this page.
        t.Red = ThemeMath.Readable(t.Red, textPrimary, page, 4.5);
        t.Orange = ThemeMath.Readable(t.Orange, textPrimary, page, 4.5);
        t.Green = ThemeMath.Readable(t.Green, textPrimary, page, 4.5);
        return t;
    }

    /// [cards] A standalone chat card's surface: clearly separated from `page` in the skin's own hue while keeping
    /// `label` at 4.5:1 or better.
    public static Rgba LiftedCard(Rgba page, Rgba ink, Rgba label, bool dark, bool contrast)
    {
        var ground = page.Over(Rgba.White);
        if (dark)
        {
            var keep = contrast ? 89.0 : 92.0;
            var card = ground.Mix(keep, ink);
            while (keep < 98 && label.Over(card).Contrast(card) < 4.5)
            {
                keep += 1;
                card = ground.Mix(keep, ink);
            }
            return card;
        }
        if (ground.LabL < 97.5)
        {
            var light = Rgba.White.Mix(85, ground);
            if (light.LabDistance(ground) >= 2.2) return light;
        }
        var lKeep = contrast ? 93.0 : 95.0;
        var lCard = ground.Mix(lKeep, ink);
        while (lKeep < 99 && label.Over(lCard).Contrast(lCard) < 4.5)
        {
            lKeep += 1;
            lCard = ground.Mix(lKeep, ink);
        }
        return lCard;
    }
}
