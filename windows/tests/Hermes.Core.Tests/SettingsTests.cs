using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

/// A preferences file in memory.
internal sealed class MemoryPrefs : IPreferences
{
    public readonly Dictionary<string, string> Values = [];
    public string? Get(string key) => Values.GetValueOrDefault(key);
    public void Set(string key, string? value) { if (value == null) Values.Remove(key); else Values[key] = value; }
}

/// The theme layer's vectors from Tests/Theme/ThemeTests.swift (colour maths, the catalog, the standard look's exact
/// tokens, the Desktop Look's mixes, High Contrast, legibility in every state, the store and its hand-off).
public class ThemeTests
{
    private static bool Close(Rgba a, Rgba b, double tolerance = 0.5 / 255) =>
        Math.Abs(a.R - b.R) <= tolerance && Math.Abs(a.G - b.G) <= tolerance && Math.Abs(a.B - b.B) <= tolerance && Math.Abs(a.A - b.A) <= 0.002;

    private static IEnumerable<ThemeState> AllStates => SkinCatalog.All.SelectMany(s => new[] { (false, false), (true, false), (true, true) }
        .Select(lc => new ThemeState { SkinId = s.Id, DesktopLook = lc.Item1, HighContrast = lc.Item2 }));

    [Fact]
    public void SrgbMixIsCssColorMix()
    {
        Assert.True(Close(Rgba.Hex(0x0053FD).Mix(6, Rgba.White), Rgba.C(239.7, 244.7, 254.9)));
        Assert.True(Close(Rgba.Hex(0x0053FD).Mix(22, Rgba.Clear), Rgba.Hex(0x0053FD, 0.22)));
        Assert.Equal(Rgba.White, Rgba.White.Mix(100, Rgba.Black));
    }

    [Fact]
    public void OklabRoundTripsAndMixesThroughGrey()
    {
        foreach (var hex in new uint[] { 0x000000, 0xFFFFFF, 0x0053FD, 0x00FF41, 0xDDD6FF, 0x808080 })
        {
            var c = Rgba.Hex(hex);
            var lab = c.Oklab;
            Assert.True(Close(Rgba.FromOklab(lab.L, lab.A, lab.B, 1), c, 1.0 / 255));
        }
        var grey = Rgba.White.MixOklab(50, Rgba.Black);
        Assert.True(Math.Abs(grey.R - grey.G) < 0.002 && Math.Abs(grey.G - grey.B) < 0.002);
        Assert.InRange(grey.R, 0.35, 0.45);
    }

    [Fact]
    public void ContrastAndLabLightness()
    {
        Assert.Equal(21, Rgba.White.Contrast(Rgba.Black), 2);
        Assert.Equal(4.54, Rgba.Hex(0x767676).Contrast(Rgba.White), 1);
        Assert.Equal(100, Rgba.White.LabL, 0);
        Assert.True(Rgba.Black.LabL < 0.1);
        Assert.True(Rgba.Hex(0x0053FD).RaisingL(57).LabL > 55.5);
        Assert.Equal(Rgba.Hex(0x9AB8FF), Rgba.Hex(0x9AB8FF).RaisingL(57));
    }

    [Fact]
    public void LegibleFixesCyberpunkOnWhiteAndLeavesNousAlone()
    {
        Rgba page = Rgba.White, text = Rgba.Hex(0x1F2328, 0.94), neon = Rgba.Hex(0x00FF41);
        Assert.True(neon.Contrast(page) < 1.5);
        Assert.True(ThemeMath.LegibleKeep(neon, text, page) < 100);
        Assert.True(ThemeMath.Legible(neon, text, page).Over(page).Contrast(page) >= 4.5);
        Assert.Equal(100, ThemeMath.LegibleKeep(Rgba.Hex(0x0053FD), text, page));
    }

    [Fact]
    public void FourteenSkinsInTheMacsOrderAndWords()
    {
        Assert.Equal(["nous", "paper", "github", "catppuccin", "everforest", "solarized", "rose-pine", "nous-alt", "midnight", "ember",
            "mono", "slate", "cyberpunk", "ios"], SkinCatalog.All.Select(s => s.Id));
        Assert.Equal("Deep blue-violet with cool accents", SkinCatalog.Find("midnight")!.Description);
        Assert.Equal("Apple System", SkinCatalog.Find("ios")!.Label);
        Assert.Equal("Courier New", SkinCatalog.Find("cyberpunk")!.SansFamily);
        Assert.Equal(["midnight", "ember", "mono", "slate", "cyberpunk"], SkinCatalog.All.Where(s => s.HasOneLook).Select(s => s.Id));
        Assert.Equal("Dark Only", SkinCatalog.Find("midnight")!.OnlyModeTag);
        Assert.Null(SkinCatalog.Find("nous")!.OnlyModeTag);
        Assert.Equal(Rgba.Hex(0x0053FD), SkinCatalog.Find("nous")!.Light.Midground);
        Assert.Equal(Rgba.Hex(0x0D1117), SkinCatalog.Find("nous")!.Dark!.Background);
        Assert.Equal(Rgba.Hex(0x242466), SkinCatalog.Find("midnight")!.Light.UserBubbleBorder);
        Assert.Equal(Rgba.Hex(0x0053FD, 0.22), SkinCatalog.Find("nous-alt")!.Light.Border);
        Assert.Equal(["paper", "cyberpunk"], SkinCatalog.All.Where(s => s.AccentReadsAsText).Select(s => s.Id));
        Assert.Equal("nous", SkinCatalog.Resolved("retired-skin").Id);
    }

    [Fact]
    public void TheStandardLookIsTheAppsOwnPalette()
    {
        var set = ThemeResolver.Resolve(ThemeState.Default);
        Assert.Null(set.ForcedDark);
        ThemeTokens light = set.Light, dark = set.Dark;
        Assert.Equal((Rgba.Hex(0xFEFEFE), Rgba.Hex(0x0D1015)), (light.Page, dark.Page));
        Assert.Equal((Rgba.Hex(0x1F2328, 0.94), Rgba.Hex(0xE6EDF3, 0.94)), (light.Label, dark.Label));
        Assert.Equal((Rgba.Hex(0x0053FD), Rgba.Hex(0x4A84FE)), (light.Tint, dark.Tint));
        Assert.Equal((Rgba.Hex(0x0040DD), Rgba.Hex(0x0A84FF)), (light.TintText, dark.TintText));
        Assert.Equal((Rgba.C(60, 60, 67, 0.29), Rgba.C(84, 84, 88, 0.6)), (light.Separator, dark.Separator));
        Assert.Equal((Rgba.Hex(0xF2F2F7), Rgba.Hex(0x1C1C1E)), (light.GroupedCard, dark.GroupedCard));
        Assert.Equal((Rgba.Hex(0xE9E9EB), Rgba.Hex(0x26282C)), (light.BotBubble, dark.BotBubble));
        Assert.Equal((Rgba.Hex(0x0053FD), Rgba.Hex(0x3863BF)), (light.MeBubble, dark.MeBubble));
        Assert.Equal((Rgba.Hex(0xF6F8FA), Rgba.Hex(0x010409)), (light.Grouped, dark.Grouped));
        Assert.Equal((Rgba.White, Rgba.White), (light.MeText, dark.MeText));
    }

    [Fact]
    public void AStoredHighContrastDoesNothingWithTheLookOff()
    {
        var set = ThemeResolver.Resolve(ThemeState.Default with { HighContrast = true });
        var plain = ThemeResolver.Resolve(ThemeState.Default);
        Assert.Equal(plain.Light, set.Light);
        Assert.Equal(plain.Dark, set.Dark);
        Assert.Equal(1.5, (ThemeState.Default with { UiScalePercent = 150 }).Scale);
    }

    [Fact]
    public void EveryStateIsLegible()
    {
        var failures = new List<string>();
        foreach (var state in AllStates)
        {
            var set = ThemeResolver.Resolve(state);
            foreach (var (mode, t) in new[] { ("light", set.Light), ("dark", set.Dark) })
            {
                var page = t.Page.Over(Rgba.White);
                void Check(string name, Rgba colour, Rgba ground, double ratio)
                {
                    var value = colour.Over(ground).Contrast(ground);
                    if (value < ratio) failures.Add($"{state.SkinId} {mode} look={state.DesktopLook} hc={state.HighContrast} {name} {value:F2}");
                }
                Check("label", t.Label, page, 4.5);
                Check("tintText", t.TintText, page, 4.5);
                Check("meText", t.MeText, t.MeBubble.Over(page), state.SkinId == "ios" && !state.DesktopLook ? 4.0 : 4.5);
                if (state.DesktopLook)
                {
                    Check("label2", t.Label2, page, 4.5);
                    Check("red", t.Red, page, 4.5);
                }
            }
        }
        Assert.Empty(failures);
    }

    [Fact]
    public void RosePineAndPaperDrawTheirOwnLooks()
    {
        var rose = ThemeResolver.Resolve(ThemeState.Default with { SkinId = "rose-pine" });
        Assert.Equal((Rgba.Hex(0xFAF4ED), Rgba.Hex(0x191724)), (rose.Light.Page, rose.Dark.Page));
        Assert.Equal((Rgba.Hex(0xFFFAF3), Rgba.Hex(0x1F1D2E)), (rose.Light.BotBubble, rose.Dark.BotBubble));
        Assert.Equal((Rgba.Hex(0xEADCEF), Rgba.Hex(0x4D3357)), (rose.Light.MeBubble, rose.Dark.MeBubble));
        Assert.Equal(rose.Light.Label, rose.Light.MeText);
        var paper = ThemeResolver.Resolve(ThemeState.Default with { SkinId = "paper" });
        Assert.Equal((Rgba.Hex(0xF8F9F3), Rgba.Hex(0x000000)), (paper.Light.Page, paper.Dark.Page));
        Assert.Equal((Rgba.Hex(0x22221F), Rgba.White), (paper.Light.Tint, paper.Light.OnTint));
        Assert.Equal((Rgba.Hex(0xEDECE6), Rgba.Black), (paper.Dark.Tint, paper.Dark.OnTint));
        Assert.Equal(Rgba.Hex(0xE9EAE2), paper.Light.MeBubble);
        Assert.Equal(Rgba.Hex(0xFDFDFA), paper.Light.GroupedCard);
        Assert.Equal(paper.Light.Page, paper.Light.BotBubble);
        Assert.Equal(Rgba.Hex(0xE4E5DD), paper.Light.IconTile);
    }

    [Fact]
    public void DesktopLookUsesTheDesktopsOwnMixes()
    {
        var midnight = ThemeResolver.Resolve(new ThemeState { SkinId = "midnight", DesktopLook = true }).Dark;
        var seeds = SkinCatalog.Find("midnight")!.Light;
        Assert.True(Close(midnight.Page, seeds.Background.Mix(74, Rgba.Hex(0x0D0D0E))));
        Assert.True(Close(midnight.Label, seeds.Foreground.Alpha(0.94)));
        Assert.True(Close(midnight.Editor, seeds.Card.Mix(38, Rgba.Hex(0x161618))));
        Assert.True(Close(midnight.BotBubble, midnight.Editor));
        Assert.True(Close(midnight.StrokeSecondary, Rgba.Hex(0x8B80E8).Mix(16, seeds.Foreground.Faded(7))));
        Assert.True(Close(midnight.MeBubble, Rgba.Hex(0x14143A).Mix(46, Rgba.Hex(0x161618))));
        Assert.Equal(Rgba.Hex(0x242466), midnight.MeBorder);
        Assert.True(Close(midnight.MeText, midnight.Label));
        var set = ThemeResolver.Resolve(new ThemeState { SkinId = "midnight", DesktopLook = true });
        Assert.Equal(set.Light, set.Dark);
        Assert.True(set.ForcedDark);
        Assert.Null(ThemeResolver.Resolve(new ThemeState { SkinId = "github", DesktopLook = true }).ForcedDark);
        Assert.Equal("#FEFEFE", ThemeResolver.Resolve(new ThemeState { DesktopLook = true }).Light.Page.HexString);
        var cyber = ThemeResolver.Resolve(new ThemeState { SkinId = "cyberpunk", DesktopLook = true }).Light;
        Assert.True(cyber.TintText.Over(cyber.Page).Contrast(cyber.Page) >= 4.5);
        Assert.True(Close(ThemeResolver.Resolve(new ThemeState { DesktopLook = true }).Light.TintText, Rgba.Hex(0x0053FD)));
    }

    [Fact]
    public void HighContrastTokens()
    {
        foreach (var skin in SkinCatalog.All)
        {
            var plainSet = ThemeResolver.Resolve(new ThemeState { SkinId = skin.Id, DesktopLook = true });
            var strongSet = ThemeResolver.Resolve(new ThemeState { SkinId = skin.Id, DesktopLook = true, HighContrast = true });
            foreach (var wantsDark in new[] { false, true })
            {
                ThemeTokens plain = plainSet.Tokens(wantsDark), strong = strongSet.Tokens(wantsDark);
                var seeds = skin.Seeds(wantsDark);
                var dark = seeds.RendersDark;
                Rgba ink = seeds.Foreground.Alpha(0.94), page = plain.Page, accent = seeds.Brand;
                Assert.Equal(plain.Page, strong.Page);
                Assert.True(Close(strong.StrokePrimary, ink.Faded(18)) && Close(strong.StrokeSecondary, ink.Faded(13)));
                Assert.True(Close(strong.Separator, ink.Faded(10)));
                Assert.True(Close(strong.Editor, ink.Over(page).MixOklab(dark ? 10 : 5, page)), skin.Id);
                Assert.True(Close(strong.MeBubble, accent.MixOklab(dark ? 28 : 13, page)), skin.Id);
                Assert.True(Close(strong.ComposerBorder, ink.Faded(50)));
                Assert.True(Close(strong.TabIdle, strong.Label2));
                Assert.True(strong.MeBorder.Over(page).Contrast(page) >= 1.5, $"{skin.Id} {wantsDark}");
            }
        }
    }

    [Fact]
    public void TheStoreKeepsTheMacsKeysAndTheNousHandOff()
    {
        var prefs = new MemoryPrefs();
        var store = new ThemeStore(prefs);
        Assert.Equal(ThemeState.Default, store.Load());
        store.PickSkin("ios");
        Assert.Equal("ios", prefs.Values["hqn.theme.skin"]);
        Assert.Equal("picked", prefs.Values["hqn.theme.chosen"]);
        // Apple System has no desktop counterpart: the look moves it to Nous, and back when the look goes off.
        store.SetDesktopLook(true);
        Assert.Equal(("nous", true), (store.Load().SkinId, store.Load().DesktopLook));
        store.SetDesktopLook(false);
        Assert.Equal(("ios", false), (store.Load().SkinId, store.Load().DesktopLook));
        Assert.False(prefs.Values.ContainsKey("hqn.theme.skinBeforeLook"));
        // Defaults are stored as nothing.
        store.SetUiScale(125);
        Assert.Equal("125", prefs.Values["hqn.theme.uiScale"]);
        store.SetUiScale(100);
        Assert.False(prefs.Values.ContainsKey("hqn.theme.uiScale"));
        store.SetHighContrast(true);
        Assert.True(store.Load().HighContrast);
        store.SetBubbleCorners(4, desktop: true);
        Assert.False(prefs.Values.ContainsKey("hqn.theme.desktopCorners"));
        store.Reset();
        Assert.Empty(prefs.Values);
        // A hand-written value outside the range is the default.
        Assert.Equal(100, ThemeStore.ClampedScale("200"));
        Assert.Equal(100, ThemeStore.ClampedScale("abc"));
        Assert.Equal(115, ThemeStore.ClampedScale("115"));
        Assert.Equal(12, ThemeStore.ClampedCorners("99", 12));
        prefs.Set("hqn.theme.skin", "retired");
        Assert.Equal("nous", store.Load().SkinId);
        store.Migrate();
        Assert.Equal("retired", prefs.Get("hqn.theme.skin"));
    }

    [Fact]
    public void TextSizeStepsThroughThePresets()
    {
        Assert.Equal(110, ThemeStore.StepScale(100, 1));
        Assert.Equal(90, ThemeStore.StepScale(100, -1));
        Assert.Null(ThemeStore.StepScale(150, 1));
        Assert.Null(ThemeStore.StepScale(90, -1));
        Assert.Equal(100, ThemeStore.StepScale(125, 0));
        Assert.Equal(125, ThemeStore.StepScale(115, 1));
    }

    [Fact]
    public void LightOrDarkAndOneLookSkins()
    {
        var prefs = new MemoryPrefs();
        Assert.Equal(AppearanceSetting.System, Appearance.Read(prefs));
        Appearance.Write(prefs, AppearanceSetting.Dark);
        Assert.Equal("dark", prefs.Get("hqn.appearance"));
        Assert.Equal(AppearanceSetting.Dark, Appearance.Read(prefs));
        Appearance.Write(prefs, AppearanceSetting.System);
        Assert.Null(prefs.Get("hqn.appearance"));
        Assert.Equal(AppearanceSetting.Dark, Appearance.ForcedBy(SkinCatalog.Find("midnight")!));
        Assert.Null(Appearance.ForcedBy(SkinCatalog.Find("github")!));
        Assert.True(Appearance.DrawsDark(SkinCatalog.Find("cyberpunk")!, AppearanceSetting.Light, false));
        Assert.False(Appearance.DrawsDark(SkinCatalog.Find("nous")!, AppearanceSetting.Light, true));
        Assert.True(Appearance.DrawsDark(SkinCatalog.Find("nous")!, AppearanceSetting.System, true));
        Assert.Equal("Midnight has only a dark look. " + SettingsWords.LookNote,
            SettingsWords.LookFooter(ThemeState.Default with { SkinId = "midnight" }));
        Assert.EndsWith("Set on this PC only.", SettingsWords.LookNote);
    }
}

/// Every vector of the Mac's Tests/Diagnostics/RedactorTests.swift (the web's `diagnostics-redact.test.ts`).
public class RedactorTests
{
    private const string Fixture = "FAKE-private-value";

    public static IEnumerable<(string Input, string Secret)> Planted()
    {
        var keys = new[] { "password", "passwd", "pwd", "passphrase", "secret", "client_secret", "token", "access_token", "refresh_token",
            "id_token", "auth_token", "api_key", "apiKey", "api-key", "x-api-key", "private_key", "credential", "credentials",
            "signature", "sig", "ticket", "otp", "hermes_session", "session", "sessionid", "sid", "Authorization",
            "Proxy-Authorization", "Cookie", "Set-Cookie" };
        foreach (var key in keys)
        {
            yield return ($"{key}={Fixture}", Fixture);
            yield return ($"{key}: {Fixture}", Fixture);
            yield return ($"\"{key}\":\"{Fixture}\"", Fixture);
            yield return ($"'{key}': '{Fixture}'", Fixture);
            yield return ($"{key}=\"{Fixture} with spaces\"", $"{Fixture} with spaces");
            yield return ($"\"{key}\":\n\"{Fixture}\"", Fixture);
        }
        foreach (var header in new[] { "Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie" })
            yield return ($"{header}: first={Fixture}; second=FAKE-cookie-two", Fixture);
        foreach (var scheme in new[] { "Bearer", "Basic", "Token" }) yield return ($"Error: {scheme} {Fixture}", Fixture);
        foreach (var scheme in new[] { "https", "http", "wss", "ws", "capacitor", "custom+app" })
        {
            yield return ($"{scheme}://gateway.example:9119/api/ws?ticket={Fixture}&search=FAKE-search#FAKE-fragment", Fixture);
            yield return ($"{scheme}://user:{Fixture}@gateway.example/api", Fixture);
            yield return ($"{scheme}://{Fixture}@gateway.example/api", Fixture);
        }
        yield return ("prefix_FAKE0123456789abcdef012345_suffix", "FAKE0123456789abcdef012345");
        yield return ("/api/fs/download?path=/Users/x/Private.pdf&profile=inbox", "/Users/x/Private.pdf");
        yield return ("https://gateway.example/api#FAKE-fragment", "FAKE-fragment");
        const string suffix = "FAKE0123456789abcdefFAKE0123456789abcdef";
        foreach (var prefix in new[] { "sk-", "sk-ant-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "xai-", "gsk_", "pplx-", "r8_", "hf_", "ghp_",
                     "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-" })
            yield return ($"Failed with {prefix + suffix}", prefix + suffix);
        foreach (var value in new[] { "AIza" + "FAKE0123456789abcdefFAKE0123456789abc", "AKIAFAKE0123456789AB", "ASIAFAKE0123456789AB",
                     "eyJhbGciOiJGQUtFIn0.eyJzdWIiOiJGQUtFIn0.FAKEsignature", "AbCdEfGhIjKlMnOpQrStUv12",
                     "abcdefabcdefabcdefabcdefabcdefab", "12345678901234567890123456789012", "12345678-abcd-4abc-8abc-123456789abc" })
            yield return ($"Error: {value}", value);
        foreach (var type in new[] { "", "RSA ", "EC ", "ENCRYPTED " })
            yield return ($"-----BEGIN {type}PRIVATE KEY-----\nFAKE-PRIVATE-MATERIAL\n-----END {type}PRIVATE KEY-----", "FAKE-PRIVATE-MATERIAL");
        var chat = string.Concat(Enumerable.Repeat("This is made-up private chat text. ", 4));
        foreach (var (open, close) in new[] { ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("`", "`") })
            yield return ($"Error: echoed {open}{chat}{close}", chat);
        foreach (var key in new[] { "text", "content", "body", "prompt", "transcript", "delta", "input", "output", "arguments" })
        {
            yield return ($"{{\"{key}\":\"FAKE chat \\\"quoted\\\" text\"}}", "FAKE chat");
            yield return ($"{{'{key}':'FAKE short chat'}}", "FAKE short chat");
        }
    }

    private static readonly string[] Safe =
    [
        "Error: Your gateway took too long to answer. It may be busy — try again. [timeout, NSURLErrorDomain -1001]",
        "Error: Gateway connection failed (code -1001). The request timed out.",
        "TypeError: undefined is not an object (evaluating 'state.sessions.find')",
        "Gateway HTTP 404: Session not found", "Error: Load failed", "Address: 100.101.102.103:9119",
        "https://gateway.example.ts.net:9119/api/sessions", "2026-09-27T04:03:00.000Z",
        "socket.handshake", "auth.restore", "native.loaded", "Connected in 360 ms", "Failed: no connection ticket after 8.0 s",
        "Voice is paused (interrupted)", "Audio session unavailable (iOS error 561017449)",
        "NotAllowedError: The request is not allowed by the user agent or the platform in the current context",
    ];

    private static string R(string s) => DiagnosticRedactor.Redact(s);

    [Fact]
    public void RemovesEveryPlantedValue()
    {
        var planted = Planted().ToList();
        Assert.True(planted.Count > 250);
        var failures = new List<string>();
        foreach (var (input, secret) in planted)
        {
            var output = R(input);
            if (output.Contains(secret) || !output.Contains("[redacted]") || R(output) != output) failures.Add($"{input} → {output}");
        }
        Assert.Empty(failures);
    }

    [Fact]
    public void PreservesUsefulContext()
    {
        foreach (var input in Safe) Assert.Equal(input, R(input));
    }

    [Fact]
    public void IdempotentWhenOverlappingRulesMakeAQuotedRunLonger()
    {
        var output = R("'" + new string('x', 61) + "\"content\":\"a\"'");
        Assert.Equal("'[redacted]'", output);
        Assert.Equal(output, R(output));
    }

    [Fact]
    public void RemovesEveryCookiePairAndWholeQueryAndFragment()
    {
        Assert.Equal("Cookie: [redacted]", R("Cookie: first=FAKE-one; second=FAKE-two"));
        Assert.Equal("Set-Cookie: [redacted]", R("Set-Cookie: first=FAKE-one; Path=/; HttpOnly"));
        Assert.Equal("https://[redacted]@host:9119/path?[redacted]", R("https://user:FAKE-pass@host:9119/path?q=FAKE-query#FAKE-hash"));
        Assert.Equal("/api/fs/download?[redacted]", R("/api/fs/download?path=/Users/x/Private.pdf&profile=inbox"));
    }

    [Fact]
    public void KeepsWordsThatOnlyLookLikeASchemeOrKeyName()
    {
        foreach (var input in new[] { "Error: Token expired", "Basic auth is not enabled on this gateway", "Token refresh failed; sign in again",
                     "Did you mean /help?", "Session setup [native session]: 12 ms", "Connection ticket [native socket.ticket]: 260 ms",
                     "max_tokens: 4096" })
            Assert.Equal(input, R(input));
        foreach (var input in new[] { $"db_password={Fixture}", $"userPassword: {Fixture}", $"refreshToken={Fixture}", $"ws_ticket={Fixture}",
                     $"{{\\\"password\\\":\\\"{Fixture}\\\"}}", $"{{\\\"text\\\":\\\"{Fixture} chat\\\"}}", "Basic dXNlcjpGQUtFMTIz",
                     "Token FAKEabcdefGHIJKL" })
        {
            var output = R(input);
            Assert.False(output.Contains("FAKE") || output.Contains("dXNlcjpGQUtFMTIz"), $"{input} → {output}");
        }
        Assert.Equal("{\\\"password\\\":[redacted]}", R($"{{\\\"password\\\":\\\"{Fixture}\\\"}}"));
    }

    [Fact]
    public void StaysFastOnPathologicalTextAndCutsLongTextFirst()
    {
        const int size = 64 * 1024;
        var rows = Enumerable.Range(0, 3000).Select(i => new Dictionary<string, object> { ["id"] = i, ["body"] = $"x{i}" }).ToList();
        var inner = JsonSerializer.Serialize(rows);
        var twice = JsonSerializer.Serialize(new[] { inner });
        string Rep(string s, int n) => string.Concat(Enumerable.Repeat(s, n));
        var texts = new[] { Rep("-/", size / 2), Rep("a-", size / 2), Rep("-eyJ", size / 4), Rep("“", size), Rep("'\\'", size / 3), twice,
            Rep("“", 65535) + "\"", Rep("\"", 65535), Rep("‘“", 32767) + "`" };
        foreach (var text in texts)
        {
            var started = DateTime.UtcNow;
            _ = R(text);
            Assert.True((DateTime.UtcNow - started).TotalSeconds < 3, $"slow on {text[..8]}");
        }
        Assert.Equal("Error: echoed \"[redacted]", R("Error: echoed \"" + Rep("private chat ", 10_000)));
        Assert.Equal("JSON Parse error: Unexpected token in \"[redacted]", R("JSON Parse error: Unexpected token in \"" + Rep("private chat ", 8)));
        const string apostrophe = "Error: Couldn't reach the gateway. Check that it is running, that Tailscale is on, and that the address is right.";
        Assert.Equal(apostrophe, R(apostrophe));
    }

    [Fact]
    public void MasksACredentialWhoseQuoteWasNeverClosed()
    {
        foreach (var input in new[] { "Error: password=\"hunter2", "{\"password\":\"hunter2", "token='abc123xyz", "Error: secret=“FAKE value",
                     "{\\\"token\\\":\\\"FAKEabc" })
        {
            var output = R(input);
            Assert.False(output.Contains("hunter2") || output.Contains("abc123xyz") || output.Contains("FAKE"), $"{input} → {output}");
        }
    }

    [Fact]
    public void MasksChatInsideAContentArrayOrObject()
    {
        foreach (var input in new[] { "{\"content\":[\"My private chat\"]}", "{\"arguments\":{\"query\":\"My private search\"}}",
                     "{\"content\":[{\"type\":\"text\",\"text\":\"hello ] there\"}],\"status\":\"ok\"}", "{\"input\":[\"cut off" })
        {
            var output = R(input);
            Assert.False(output.Contains("private") || output.Contains("hello") || output.Contains("cut off"), $"{input} → {output}");
        }
        Assert.Equal("{\"content\":[redacted],\"status\":\"error\"}", R("{\"content\":[\"My private chat\"],\"status\":\"error\"}"));
        Assert.Equal("{\"content\":[redacted]}", R("{\"content\":[redacted]}"));
    }

    [Fact]
    public void FindsAnOpenQuote()
    {
        Assert.Equal("Error: “[redacted]", R("Error: “" + new string('x', 100)));
        Assert.Equal("Error: “quoted” then “[redacted]", R("Error: “quoted” then “" + new string('x', 100)));
        Assert.Equal("Error: “" + new string('x', 10), R("Error: “" + new string('x', 10)));
    }

    [Fact]
    public void PlantedTicketAndBearer()
    {
        Assert.Equal("POST https://x.example/a?[redacted] Authorization: [redacted]",
            R("POST https://x.example/a?ticket=abc123DEF456ghi789JKL012 Authorization: Bearer sk-live-0123456789abcdef"));
    }
}

public class SettingsTests
{
    [Fact]
    public void TheCopiedReportIsRedactedLineByLine()
    {
        var sections = new[]
        {
            new DiagnosticsReport.Section("App", [new("Version", "0.1.0"), new("Windows", "10.0.26100")]),
            new DiagnosticsReport.Section("Gateway", [new("Address", "127.0.0.1:9830"), new("Hermes", "0.21.5", "version")],
                new DiagnosticsReport.RowList("Recent reconnects", [], "None since launch")),
        };
        var at = new DateTimeOffset(2026, 11, 21, 4, 3, 0, TimeSpan.Zero);
        var errors = DiagnosticsReport.RecentErrors([
            ("Gateway HTTP 500 at https://x.example/a?ticket=abc123DEF456ghi789JKL012", at),
            ("Gateway HTTP 500 at https://x.example/a?ticket=abc123DEF456ghi789JKL012", at),
            ("roster failed: timeout", null),
        ]);
        Assert.Equal(2, errors.Count);
        Assert.Equal("roster failed: timeout", errors[0].Message);
        Assert.Equal(2, errors[1].Count);
        var text = DiagnosticsReport.Text(sections, errors, at);
        Assert.Equal("""
            Hermes HQ diagnostics
            2026-11-21T04:03:00.000Z

            App
              Version: 0.1.0
              Windows: 10.0.26100

            Gateway
              Address: 127.0.0.1:9830
              Hermes [version]: 0.21.5
              Recent reconnects:
                None since launch

            Recent errors (3)
              roster failed: timeout
              Gateway HTTP 500 at https://x.example/a?[redacted] (×2 · last 2026-11-21T04:03:00.000Z)
            """.Replace("\r\n", "\n"), text);
        Assert.Equal("Open Connections", DiagnosticsReport.TitleCase("Open connections"));
        Assert.Equal("Most Open at Once", DiagnosticsReport.TitleCase("Most open at once"));
        Assert.Equal("Sign-In Check", DiagnosticsReport.TitleCase("Sign-in check"));
        Assert.Equal("macOS Version", DiagnosticsReport.TitleCase("macOS version"));
        Assert.Equal("a b", DiagnosticsReport.OneLine("  a \n\t b  ", 300));
    }

    [Fact]
    public void SearchFindsRowsByTheirWordsPagesFirst()
    {
        var index = SettingsSearch.Index;
        Assert.Equal(["Theme"], SettingsSearch.Results("rose pine", index).Select(e => e.Label));
        Assert.Contains(SettingsSearch.Results("contrast", index), e => e.Label == "High Contrast");
        var folder = SettingsSearch.Results("folder", index);
        Assert.Equal(SettingsWords.SessionsPageTitle, folder[0].Label);
        Assert.True(folder[0].IsPage);
        Assert.Contains(folder, e => e.Label == "Default Project Folder");
        Assert.Contains(SettingsSearch.Results("BIGGER text", index), e => e.Label == "UI Scale");
        Assert.Contains(SettingsSearch.Results("rosé", index), e => e.Label == "Theme");
        Assert.Empty(SettingsSearch.Results("   ", index));
        Assert.Empty(SettingsSearch.Results("zzzz nothing", index));
        Assert.Equal(SettingsCategory.Appearance, SettingsSearch.Category("row:ui-scale"));
        Assert.Equal(SettingsCategory.About, SettingsSearch.Category("diagnostics"));
        foreach (var e in index) Assert.True(SettingsSearch.Category(e.Target) != null, e.Id);
        Assert.Equal(index.Count, index.Select(e => e.Id).Distinct().Count());
    }

    [Fact]
    public void CategoriesInTheMacsOrderAndNames()
    {
        Assert.Equal(["General", "Appearance", "Chat", "Sounds", "Hermes", "About"], SettingsCategories.All.Select(c => c.Title()));
        Assert.Equal(SettingsCategory.Chat, SettingsCategories.Parse("chat"));
        Assert.Null(SettingsCategories.Parse("tools"));
    }

    [Fact]
    public void TheGatewayCardsWords()
    {
        Assert.Equal("Connected · 9 Bots · Hermes 0.21.5", SettingsWords.StatusLine(GatewayConnection.Ready, 9, "0.21.5"));
        Assert.Equal("Offline · 1 Bot", SettingsWords.StatusLine(GatewayConnection.Offline, 1, null));
        Assert.Equal("Connecting…", SettingsWords.StatusLine(GatewayConnection.Connecting, 0, ""));
        Assert.Equal("0.21.5", SettingsWords.CleanVersion(" v0.21.5+git.abc "));
        Assert.Equal("0.22.6", SettingsWords.CleanVersion("0.22.6-dev"));
        Assert.Equal("0.21.5", SettingsWords.Version(JsonNode.Parse("{\"version\":\"v0.21.5\"}")));
        Assert.Null(SettingsWords.Version(JsonNode.Parse("{\"version\":\"  \"}")));
        Assert.Equal("Studio, Connected", SettingsWords.GatewayCardLabel("Studio", "Connected", ""));
        Assert.Equal("Studio, Connected, studio.local:9119", SettingsWords.GatewayCardLabel("Studio", "Connected", "studio.local:9119"));
    }

    [Fact]
    public void CompletionSoundPrefsAndTheCue()
    {
        var prefs = new MemoryPrefs();
        var sound = new CompletionSoundPrefs(prefs);
        Assert.True(sound.IsOn);
        Assert.Equal(1, sound.Variant);
        sound.IsOn = false;
        Assert.Equal("false", prefs.Get(CompletionSoundPrefs.Key));
        sound.Variant = 2;
        Assert.Equal(2, sound.Variant);
        prefs.Set(CompletionSoundPrefs.VariantKey, "99");
        Assert.Equal(1, sound.Variant);
        Assert.Equal(14, CompletionSoundSynth.Presets.Count);
        Assert.Equal("Glass Ping", CompletionSoundSynth.Find(2).Name);
        Assert.Equal("Music Box", CompletionSoundSynth.Find(14).Name);
        foreach (var p in CompletionSoundSynth.Presets)
        {
            var wav = CompletionSoundSynth.Wav(p.Id);
            Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(wav, 0, 4));
            Assert.Equal("WAVE", System.Text.Encoding.ASCII.GetString(wav, 8, 4));
            Assert.Equal(44100, BitConverter.ToInt32(wav, 24));
            Assert.Equal(wav.Length - 44, BitConverter.ToInt32(wav, 40));
            Assert.True(wav.Length > 44 + 44100, p.Name); // at least a second of sound
            Assert.Contains(Enumerable.Range(0, (wav.Length - 44) / 2), i => BitConverter.ToInt16(wav, 44 + i * 2) != 0);
            Assert.Equal(wav, CompletionSoundSynth.Wav(p.Id)); // the same cue every time
        }
        var gate = new CompletionCueGate();
        var t = DateTimeOffset.UtcNow;
        Assert.True(gate.ShouldPlay("a", t, on: true));
        Assert.False(gate.ShouldPlay("a", t.AddSeconds(1), on: true));
        Assert.True(gate.ShouldPlay("b", t.AddSeconds(1), on: true));
        Assert.True(gate.ShouldPlay("a", t.AddSeconds(2.5), on: true));
        Assert.False(gate.ShouldPlay("c", t, on: false));
    }

    [Fact]
    public void NotificationAndVoicePrefsKeepTheMacsShape()
    {
        var prefs = new MemoryPrefs();
        var n = NotificationPrefs.Load(prefs);
        Assert.True(n.Enabled && n.Previews && n.Allows("turnDone"));
        n = n.WithKind("turnDone", false) with { Previews = false };
        n.Save(prefs);
        var raw = JsonNode.Parse(prefs.Get(NotificationPrefs.Key)!)!;
        Assert.False(raw["kinds"]!["turnDone"]!.GetValue<bool>());
        var back = NotificationPrefs.Load(prefs);
        Assert.False(back.Allows("turnDone"));
        Assert.True(back.Allows("approval"));
        Assert.False(back.Previews);
        Assert.False((back with { Enabled = false }).Allows("approval"));
        Assert.Equal(6, NotificationPrefs.Shown.Length);
        Assert.Equal("Response Ready", NotificationPrefs.Label("turnDone"));
        Assert.True(NotificationPrefs.Banners(prefs));
        NotificationPrefs.SetBanners(prefs, false);
        Assert.False(NotificationPrefs.Banners(prefs));
        prefs.Set(NotificationPrefs.Key, "not json");
        Assert.Equal(NotificationPrefs.Default.Enabled, NotificationPrefs.Load(prefs).Enabled);

        Assert.False(VoicePrefs.ReadsRepliesAloud(prefs));
        prefs.Set(VoicePrefs.ReadRepliesGatewayKey, "true");
        Assert.True(VoicePrefs.ReadsRepliesAloud(prefs));
        VoicePrefs.SetReadsRepliesAloud(prefs, false);
        Assert.False(VoicePrefs.ReadsRepliesAloud(prefs));
        Assert.True(VoicePrefs.SendOnRelease(prefs));
        VoicePrefs.SetSendOnRelease(prefs, false);
        Assert.False(VoicePrefs.SendOnRelease(prefs));
        Assert.Contains("click and hold", SettingsWords.MemoNote(true));

        ChatPrefs.Store = prefs;
        Assert.False(ChatPrefs.FileBrowser);
        ChatPrefs.FileBrowser = true;
        Assert.Equal("true", prefs.Get(ChatPrefs.FileBrowserKey));
    }

    [Fact]
    public async Task NewChatAndBotChatUseFolderAndRetryOnlyAnImplicitFolder()
    {
        var previousStore = DefaultProjectFolder.Store;
        var previousAccount = DefaultProjectFolder.ActiveAccount;
        try
        {
            DefaultProjectFolder.Store = new MemoryPrefs();
            DefaultProjectFolder.ActiveAccount = "test-account";
            DefaultProjectFolder.Set("/default", "test-account");
            DefaultProjectFolder.Set("/bot", "test-account", "ivy");
            var gw = new FakeGateway();
            gw.OnCall = (method, p) => method switch
            {
                "session.create" => JsonNode.Parse("""{"session_id":"rt","stored_session_id":"st"}"""),
                "session.list" => JsonNode.Parse("""{"sessions":[]}"""),
                "session.title" => new JsonObject(),
                _ => null,
            };
            var sessions = new Hermes.Core.Sessions.SessionStore(gw, new Hermes.Core.Bots.MemoryDeviceStore());
            Assert.Equal("st", await sessions.NewChatAsync("ivy"));
            Assert.Equal("/bot", gw.Calls.Last().Params.Str("cwd"));
            Assert.Equal("desktop", gw.Calls.Last().Params.Str("source"));
            Assert.True(gw.Calls.Last().Params.Bool("cwd_explicit"));
            await sessions.NewChatAsync("ivy", "/project");
            Assert.Equal("/project", gw.Calls.Last().Params.Str("cwd"));
            var bots = new Hermes.Core.Bots.BotStore(gw, new Hermes.Core.Bots.MemoryDeviceStore());
            Assert.Equal("st", await bots.BotChatIdAsync("ivy"));
            Assert.Equal("/bot", gw.Calls.Last(c => c.Method == "session.create").Params.Str("cwd"));
            Assert.Equal("desktop", gw.Calls.Last(c => c.Method == "session.create").Params.Str("source"));

            var attempts = 0;
            gw.OnCall = (_, _) => ++attempts == 1 ? throw new InvalidOperationException("refused") : new JsonObject { ["session_id"] = "fallback" };
            Assert.Equal("fallback", await sessions.NewChatAsync("ivy"));
            var fallback = gw.Calls.Last().Params;
            Assert.False(fallback.ContainsKey("cwd"));
            Assert.False(fallback.ContainsKey("cwd_explicit"));
            Assert.False(fallback.ContainsKey("source")); // Swift retries the original base unchanged.
            Assert.Equal(2, attempts);
            attempts = 0;
            await Assert.ThrowsAsync<InvalidOperationException>(() => sessions.NewChatAsync("ivy", "/project"));
            Assert.Equal(1, attempts);
            attempts = 0;
            gw.OnCall = (_, _) => { attempts++; throw new OperationCanceledException(); };
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => sessions.NewChatAsync("ivy"));
            Assert.Equal(1, attempts);
            DefaultProjectFolder.ActiveAccount = null;
            gw.OnCall = (_, _) => { attempts++; throw new InvalidOperationException(); };
            attempts = 0;
            await Assert.ThrowsAsync<InvalidOperationException>(() => sessions.NewChatAsync("ivy"));
            Assert.Equal(1, attempts); // No default: there is nothing to drop or retry.
            Assert.Equal("desktop", gw.Calls.Last().Params.Str("source"));
            Assert.False(gw.Calls.Last().Params.ContainsKey("cwd"));
            var original = new JsonObject { ["source"] = "other", ["profile"] = "ivy" };
            var shaped = SessionCreate.Params(original, "ivy", "/project");
            Assert.Equal("other", shaped.Str("source"));
            Assert.Equal("/project", shaped.Str("cwd"));
            Assert.False(original.ContainsKey("cwd"));
        }
        finally { DefaultProjectFolder.Store = previousStore; DefaultProjectFolder.ActiveAccount = previousAccount; }
    }

    [Fact]
    public void DefaultProjectFolderIsPerGatewayAndGoesIntoNewChats()
    {
        var prefs = new MemoryPrefs();
        DefaultProjectFolder.Store = prefs;
        DefaultProjectFolder.ActiveAccount = "gw-a";
        Assert.Null(DefaultProjectFolder.Current("default"));
        DefaultProjectFolder.Set("  /Users/fixture/Projects/app  ", "gw-a");
        Assert.Equal("/Users/fixture/Projects/app", prefs.Get("hqn.defaultProjectFolder.gw-a.default"));
        Assert.Equal("/Users/fixture/Projects/app", DefaultProjectFolder.Current("ivy"));
        var p = SessionCreate.Params(new JsonObject { ["profile"] = "ivy" }, "ivy");
        Assert.Equal("desktop", p.Str("source"));
        Assert.Equal("/Users/fixture/Projects/app", p.Str("cwd"));
        Assert.True(p.Bool("cwd_explicit"));
        DefaultProjectFolder.Set("", "gw-a");
        Assert.Null(DefaultProjectFolder.Current("default"));
        Assert.False(SessionCreate.Params(new JsonObject(), "default").ContainsKey("cwd"));
        DefaultProjectFolder.ActiveAccount = null;
        Assert.True(DefaultProjectFolder.IsFolder(JsonNode.Parse("{\"entries\":[]}")));
        Assert.False(DefaultProjectFolder.IsFolder(JsonNode.Parse("{\"entries\":[],\"error\":\"No such directory\"}")));
        Assert.False(DefaultProjectFolder.IsFolder(JsonNode.Parse("{}")));
    }
}
