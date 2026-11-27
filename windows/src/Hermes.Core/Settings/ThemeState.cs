using System.Globalization;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// What the person chose (HermesKit/Theme/ThemeState.swift; spec 3x-desktoplook §4.4, §5.6, §6, §7). Kept on this PC
/// only, never sent anywhere. The Windows app keeps the Look, Text Size, Theme and Chat Bubbles choices (`ChatBubbles`); the
/// Mac's backgrounds (Backgrounds) are not on Windows yet.
public sealed record ThemeState
{
    /// The stored skin id resolved against the catalog.
    public string SkinId { get; init; } = SkinCatalog.DefaultId;
    public bool DesktopLook { get; init; }
    /// The stored choice; it only draws while the Desktop Look is on.
    public bool HighContrast { get; init; }
    /// The stored choice (percent), in both looks.
    public int UiScalePercent { get; init; } = 100;
    /// The iOS look's bubble corner (points); the Desktop Look has `DesktopCorners`.
    public int BubbleCorners { get; init; } = DefaultBubbleCorners;
    public int DesktopCorners { get; init; } = DefaultDesktopCorners;
    public bool PlainReplies { get; init; }
    /// [density] Standard, or Compact's smaller faces and shorter rows; only with the Desktop Look off (`compact`).
    public ListDensity Density { get; init; } = ListDensity.Standard;
    /// [top-edge] Hard unless Soft was picked (the default since build 734). Kept, not drawn: see `TopEdgeRow.Offered`.
    public TopEdge TopEdge { get; init; } = TopEdge.Hard;
    /// [glass-bubbles] [tinted-bubbles] Chat Bubbles › Style, the stored choice; only with the Desktop Look off. Solid
    /// unless another was picked.
    public BubbleStyle BubbleStyle { get; init; } = BubbleStyle.Solid;

    public static readonly ThemeState Default = new();
    public static readonly int[] ScalePresets = [90, 100, 110, 125, 150];
    public const int DefaultBubbleCorners = ChatVisualTokens.DefaultCorners;
    public const int DefaultDesktopCorners = ChatVisualTokens.DesktopCorners;
    public const int MinCorners = 0, MaxCorners = 24;

    public Skin Skin => SkinCatalog.Resolved(SkinId);
    public bool ContrastApplies => DesktopLook && HighContrast;
    /// [density] Compact draws only in the iOS look.
    public bool Compact => !DesktopLook && Density == ListDensity.Compact;
    public double Scale => UiScalePercent / 100.0;
    /// The corner bubbles are drawn with: the look in use's own.
    public int AppliedBubbleCorners => DesktopLook ? DesktopCorners : BubbleCorners;
    /// Desktop Look draws plain replies unless its contrast mode boxes them. Otherwise follow the stored choice.
    public bool AppliedPlainReplies => DesktopLook ? !ContrastApplies : PlainReplies;
    /// [glass-bubbles] The Desktop Look keeps its own boxes (`appliedBubbleStyle`).
    public BubbleStyle AppliedBubbleStyle => DesktopLook ? BubbleStyle.Solid : BubbleStyle;
}

/// Reads and writes the `hqn.theme.*` keys (the Mac's names) in this PC's preferences file. A value that isn't one this
/// store writes reads as the default, never overwritten (ThemeStore.load).
public sealed class ThemeStore(IPreferences prefs)
{
    public static class Key
    {
        public const string Skin = "hqn.theme.skin";
        public const string Chosen = "hqn.theme.chosen";
        public const string DesktopLook = "hqn.theme.desktopLook";
        public const string SkinBeforeLook = "hqn.theme.skinBeforeLook";
        public const string HighContrast = "hqn.theme.highContrast";
        public const string UiScale = "hqn.theme.uiScale";
        public const string BubbleCorners = "hqn.theme.bubbleCorners";
        public const string DesktopCorners = "hqn.theme.desktopCorners";
        /// [top-edge] `TopEdge`'s raw value, stored only when it isn't Hard.
        public const string TopEdge = "hqn.theme.topEdge";
        /// [density] `ListDensity`'s raw value, stored only when it isn't Standard.
        public const string Density = "hqn.theme.density";
        /// [glass-bubbles] Stored only when off (`false`), beside `BubbleStyle`, so a build from before Tinted draws solid
        /// bubbles rather than glass. No longer read.
        public const string GlassBubbles = "hqn.theme.glassBubbles";
        /// [tinted-bubbles] `BubbleStyle`'s raw value, stored only when it isn't Solid.
        public const string BubbleStyle = "hqn.theme.bubbleStyle";
        /// [desktop-composer] The Mac's Text Box choice (not offered on a desktop); kept so Reset clears it.
        public const string DesktopComposer = "hqn.theme.desktopComposer";
        /// [message-colour] Chat Bubbles › Color (not on Windows yet); kept so Reset clears it.
        public const string MessageColour = "hqn.theme.messageColour";
        /// [plain-replies] A stored Reply Bubbles off; absent means boxed.
        public const string PlainReplies = "hqn.theme.plainReplies";
        /// The Mac's `Key.all`, in its order.
        public static readonly string[] All = [Skin, Chosen, DesktopLook, SkinBeforeLook, HighContrast, UiScale, BubbleCorners, GlassBubbles, BubbleStyle, TopEdge,
            DesktopCorners, DesktopComposer, Density, MessageColour, PlainReplies];
    }

    public const int DefaultScale = 100;

    private bool Flag(string key) => prefs.Get(key) == "true";

    /// `DispatchUIScale.clamped`: outside 80…160 or not a number is 100 %. Inside the range a non-preset is kept.
    public static int ClampedScale(string? value)
    {
        if (value == null || !double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var percent)) return DefaultScale;
        if (!double.IsFinite(percent) || percent < 80 || percent > 160) return DefaultScale;
        return (int)Math.Round(percent, MidpointRounding.AwayFromZero);
    }

    /// Outside 0…24 or not a number is the standard (12 pt, or the Desktop Look's 4).
    public static int ClampedCorners(string? value, int standard)
    {
        if (value == null || !double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var points)) return standard;
        points = Math.Round(points, MidpointRounding.AwayFromZero);
        if (!double.IsFinite(points) || points < ThemeState.MinCorners || points > ThemeState.MaxCorners) return standard;
        return (int)points;
    }

    public ThemeState Load() => new()
    {
        SkinId = SkinCatalog.Resolved(prefs.Get(Key.Skin)).Id,
        DesktopLook = Flag(Key.DesktopLook),
        HighContrast = Flag(Key.HighContrast),
        UiScalePercent = ClampedScale(prefs.Get(Key.UiScale)),
        BubbleCorners = ClampedCorners(prefs.Get(Key.BubbleCorners), ThemeState.DefaultBubbleCorners),
        DesktopCorners = ClampedCorners(prefs.Get(Key.DesktopCorners), ThemeState.DefaultDesktopCorners),
        PlainReplies = Flag(Key.PlainReplies),
        Density = ListDensities.Parse(prefs.Get(Key.Density)) ?? ListDensity.Standard,
        TopEdge = TopEdges.Parse(prefs.Get(Key.TopEdge)) ?? TopEdge.Hard,
        // [tinted-bubbles] A style stored as anything but a known name is Solid.
        BubbleStyle = BubbleStyles.Parse(prefs.Get(Key.BubbleStyle)) ?? BubbleStyle.Solid,
    };

    /// [tinted-bubbles] Solid is stored as nothing, the others as their name. The Glass switch stays off except for Glass.
    public void SetBubbleStyle(BubbleStyle style)
    {
        prefs.Set(Key.BubbleStyle, style == BubbleStyle.Solid ? null : style.Raw());
        prefs.Set(Key.GlassBubbles, style == BubbleStyle.Glass ? null : "false");
    }

    /// [density] Standard, the default, is stored as nothing.
    public void SetDensity(ListDensity density) => prefs.Set(Key.Density, density == ListDensity.Standard ? null : density.Raw());

    /// [top-edge] Hard, the default, is stored as nothing.
    public void SetTopEdge(TopEdge edge) => prefs.Set(Key.TopEdge, edge == TopEdge.Hard ? null : edge.Raw());

    /// Port of `migrateUnchosenSkin`: someone who never picked a skin and sits on the old default follows a new default.
    public void Migrate(string defaultId = SkinCatalog.DefaultId, string oldDefaultId = SkinCatalog.OldDefaultId)
    {
        if (prefs.Get(Key.Chosen) != null) return;
        var stored = prefs.Get(Key.Skin);
        if (stored == null || stored == oldDefaultId)
        {
            if (defaultId != oldDefaultId) prefs.Set(Key.Skin, null);
            prefs.Set(Key.Chosen, "migrated");
        }
    }

    /// The person picked a skin (`markSkinChosen`).
    public void PickSkin(string id)
    {
        prefs.Set(Key.Skin, id);
        prefs.Set(Key.Chosen, "picked");
    }

    /// The Nous hand-off (desktop-look-row.tsx:10-25): Apple System has no desktop counterpart, so turning the look on
    /// moves it to Nous, and back when the look goes off if nothing else was picked meanwhile.
    public void SetDesktopLook(bool on)
    {
        var skin = SkinCatalog.Resolved(prefs.Get(Key.Skin)).Id;
        if (on)
        {
            if (skin == SkinCatalog.IosId)
            {
                prefs.Set(Key.SkinBeforeLook, SkinCatalog.IosId);
                prefs.Set(Key.Skin, SkinCatalog.DesktopDefaultId);
            }
            prefs.Set(Key.DesktopLook, "true");
        }
        else
        {
            if (prefs.Get(Key.SkinBeforeLook) == SkinCatalog.IosId && skin == SkinCatalog.DesktopDefaultId)
                prefs.Set(Key.Skin, SkinCatalog.IosId);
            prefs.Set(Key.SkinBeforeLook, null);
            prefs.Set(Key.DesktopLook, null);
        }
    }

    public void SetHighContrast(bool on) => prefs.Set(Key.HighContrast, on ? "true" : null);

    /// Stored only when it is not the default (ui-scale.ts:31-33).
    public void SetUiScale(int percent) =>
        prefs.Set(Key.UiScale, percent == DefaultScale ? null : percent.ToString(CultureInfo.InvariantCulture));

    /// Stored only when it is not the standard 12 pt (or, `desktop`, the Desktop Look's 4 pt).
    public void SetBubbleCorners(int points, bool desktop = false)
    {
        points = Math.Clamp(points, ThemeState.MinCorners, ThemeState.MaxCorners);
        var key = desktop ? Key.DesktopCorners : Key.BubbleCorners;
        var standard = desktop ? ThemeState.DefaultDesktopCorners : ThemeState.DefaultBubbleCorners;
        prefs.Set(key, points == standard ? null : points.ToString(CultureInfo.InvariantCulture));
    }

    public void Reset()
    {
        foreach (var k in Key.All) prefs.Set(k, null);
    }

    /// The View menu's text size steps (App/Mac/MacWindow.swift `stepScale`): the presets in order; 0 is 100 %. Null
    /// when there is no next step that way.
    public static int? StepScale(int current, int by)
    {
        var presets = ThemeState.ScalePresets;
        if (by == 0) return DefaultScale;
        var index = Array.IndexOf(presets, current);
        if (index < 0) index = Array.FindLastIndex(presets, p => p < current);
        if (index < 0) index = 0;
        var next = index + by;
        return next >= 0 && next < presets.Length ? presets[next] : null;
    }
}

/// Settings › Appearance › Light or Dark (App/Settings/AppearanceSetting.swift): System (default), Light or Dark for the
/// whole app, on this PC.
public enum AppearanceSetting { System, Light, Dark }

public static class Appearance
{
    public const string Key = "hqn.appearance";

    public static string Title(this AppearanceSetting a) => a switch
    {
        AppearanceSetting.Light => "Light",
        AppearanceSetting.Dark => "Dark",
        _ => "System",
    };

    public static AppearanceSetting Read(IPreferences prefs) => prefs.Get(Key) switch
    {
        "light" => AppearanceSetting.Light,
        "dark" => AppearanceSetting.Dark,
        _ => AppearanceSetting.System,
    };

    public static void Write(IPreferences prefs, AppearanceSetting value) =>
        prefs.Set(Key, value == AppearanceSetting.System ? null : value.ToString().ToLowerInvariant());

    /// The look a one-look skin (Midnight, Ember, Mono, Slate, Cyberpunk) draws in both modes, or null when the skin has
    /// Light and Dark. The person's own choice is kept and comes back with the next skin that has both.
    public static AppearanceSetting? ForcedBy(Skin skin) =>
        skin.HasOneLook ? skin.Light.RendersDark ? AppearanceSetting.Dark : AppearanceSetting.Light : null;

    /// Whether the app draws dark: the skin's one look, else the choice, else the system's.
    public static bool DrawsDark(Skin skin, AppearanceSetting chosen, bool systemDark) =>
        (ForcedBy(skin) ?? chosen) switch
        {
            AppearanceSetting.Dark => true,
            AppearanceSetting.Light => false,
            _ => systemDark,
        };
}
