using System.Text.RegularExpressions;
using Hermes.Core.Capabilities;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-APPEARANCE-WALK] The checks behind the appearance-pages walk (HermesHQ.Windows Services/ProofWalks.Appearance.cs)
/// and its wiring: windows.yml asks for it, with its pictures, on the settings stand-in, whose skills it expects; the
/// app registers it and takes every picture. All data synthetic. Source reads are CRLF-normalised (the Windows runner
/// checks the tree out with CRLF).
public class AppearanceWalkProofTests
{
    // ------------------------------------------------------------------ settings put back

    [Fact]
    public void RestoredNamesEveryKeyThatDiffers()
    {
        var store = new Dictionary<string, string?> { ["hqn.theme.density"] = null, ["hqn.theme.bubbleCorners"] = "16", ["hqn.settings.lastCategory"] = "chat" };
        var before = AppearanceWalkProof.Snapshot(k => store.GetValueOrDefault(k), store.Keys);
        Assert.Null(AppearanceWalkProof.Restored(before, k => store.GetValueOrDefault(k)));

        store["hqn.theme.density"] = "compact";
        store["hqn.theme.bubbleCorners"] = null;
        var wrong = AppearanceWalkProof.Restored(before, k => store.GetValueOrDefault(k));
        Assert.Equal("not put back: hqn.theme.density is “compact”, not unset; hqn.theme.bubbleCorners is unset, not “16”", wrong);
    }

    [Fact]
    public void TheKeysPutBackCoverEveryThemeKeyAndTheSettingsCategory()
    {
        // Every hqn.theme key the walk's switches write (Desktop Look and its skin, Corners for both looks, Tinted,
        // Density), and the category Settings opens on.
        foreach (var key in new[]
        {
            ThemeStore.Key.DesktopLook, ThemeStore.Key.Skin, ThemeStore.Key.SkinBeforeLook, ThemeStore.Key.BubbleCorners,
            ThemeStore.Key.DesktopCorners, ThemeStore.Key.BubbleStyle, ThemeStore.Key.GlassBubbles, ThemeStore.Key.Density,
            SettingsCategories.LastCategoryKey,
        })
            Assert.Contains(key, AppearanceWalkProof.PreferenceKeys);
        Assert.Equal(AppearanceWalkProof.PreferenceKeys.Count, AppearanceWalkProof.PreferenceKeys.Distinct().Count());
    }

    [Fact]
    public void TheWalksStoreRoundTripLeavesAThemeAsItWas()
    {
        // What the walk does to the store, then puts back: the state reads as before.
        var prefs = new MemoryPreferences();
        prefs.Set(ThemeStore.Key.BubbleCorners, "9");
        var store = new ThemeStore(prefs);
        var before = AppearanceWalkProof.Snapshot(prefs.Get, AppearanceWalkProof.PreferenceKeys);
        var was = store.Load();
        store.SetBubbleCorners(AppearanceWalkProof.WalkCorners);
        store.SetBubbleStyle(BubbleStyle.Tinted);
        store.SetDesktopLook(true);
        store.SetDesktopLook(false);
        store.SetDensity(ListDensity.Compact);
        Assert.NotNull(AppearanceWalkProof.Restored(before, prefs.Get));
        foreach (var (key, value) in before) prefs.Set(key, value);
        store.SetDensity(store.Load().Density);
        foreach (var (key, value) in before) prefs.Set(key, value);
        Assert.Null(AppearanceWalkProof.Restored(before, prefs.Get));
        Assert.Equal(was, store.Load());
    }

    private sealed class MemoryPreferences : Hermes.Core.Transcripts.IPreferences
    {
        private readonly Dictionary<string, string> _values = [];
        public string? Get(string key) => _values.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, string? value)
        {
            if (value == null) _values.Remove(key); else _values[key] = value;
        }
    }

    // ------------------------------------------------------------------ Chat Bubbles

    [Fact]
    public void CornersMustAgreeEverywhereThePageShowsThem()
    {
        Assert.Null(AppearanceWalkProof.CornersShown(20, "20 pt", 20, 20, "20 points"));
        Assert.Equal("Corners reads 12 pt, not 20 pt", AppearanceWalkProof.CornersShown(20, "12 pt", 20, 20, "20 points"));
        Assert.Equal("the preview's message has 12 pt corners, not 20", AppearanceWalkProof.CornersShown(20, "20 pt", 12, 20, "20 points"));
        Assert.Equal("the slider sits at 12, not 20", AppearanceWalkProof.CornersShown(20, "20 pt", 20, 12, "20 points"));
        Assert.Equal("the slider says 12 points, not 20 points", AppearanceWalkProof.CornersShown(20, "20 pt", 20, 20, "12 points"));
        // The walk's corner is neither look's standard, so a page that never moved fails.
        Assert.NotEqual(ThemeState.DefaultBubbleCorners, AppearanceWalkProof.WalkCorners);
        Assert.NotEqual(ThemeState.DefaultDesktopCorners, AppearanceWalkProof.WalkCorners);
        Assert.InRange(AppearanceWalkProof.WalkCorners, ThemeState.MinCorners, ThemeState.MaxCorners);
    }

    [Fact]
    public void TheIosLooksPageHasTintedAndItsNotes()
    {
        var tinted = ThemeState.Default with { BubbleCorners = 20, BubbleStyle = BubbleStyle.Tinted };
        // Tinted with no Chat Background: the note, then Tinted's own sentence.
        string[] notes = [ChatBubbles.Note + "\n\n" + ChatBubbles.TintedNeedsBackground];
        Assert.Null(AppearanceWalkProof.BubblesPage(tinted, tintedShown: true, tintedOn: true, notes));
        Assert.Equal("the iOS look's Chat Bubbles has no Tinted switch", AppearanceWalkProof.BubblesPage(tinted, false, false, notes));
        Assert.Equal("Tinted shows off with the style Tinted", AppearanceWalkProof.BubblesPage(tinted, true, false, notes));
        Assert.StartsWith("the page's notes don't read", AppearanceWalkProof.BubblesPage(tinted, true, true, [ChatBubbles.Note]));
        // Solid: the note alone, Tinted off.
        Assert.Null(AppearanceWalkProof.BubblesPage(ThemeState.Default, true, false, [ChatBubbles.Note]));
    }

    [Fact]
    public void TheDesktopLooksPageHasNoTintedAndItsOwnNote()
    {
        var desktop = ThemeState.Default with { DesktopLook = true, BubbleStyle = BubbleStyle.Tinted };
        Assert.Null(AppearanceWalkProof.BubblesPage(desktop, tintedShown: false, tintedOn: false, [ChatBubbles.DesktopNote]));
        Assert.Equal("the Desktop Look's Chat Bubbles shows Tinted", AppearanceWalkProof.BubblesPage(desktop, true, true, [ChatBubbles.DesktopNote]));
        Assert.NotNull(AppearanceWalkProof.BubblesPage(desktop, false, false, [ChatBubbles.Note]));
    }

    [Fact]
    public void WhatTheIosLooksPageSaved()
    {
        var saved = ThemeState.Default with { BubbleCorners = 20, BubbleStyle = BubbleStyle.Tinted };
        Assert.Null(AppearanceWalkProof.BubblesSaved(saved, 20, BubbleStyle.Tinted));
        Assert.Equal("the iOS look's Corners is 12, not 20", AppearanceWalkProof.BubblesSaved(saved with { BubbleCorners = 12 }, 20, BubbleStyle.Tinted));
        Assert.Equal("the bubble style is Solid, not Tinted", AppearanceWalkProof.BubblesSaved(saved with { BubbleStyle = BubbleStyle.Solid }, 20, BubbleStyle.Tinted));
        Assert.Equal("the Desktop Look is on", AppearanceWalkProof.BubblesSaved(saved with { DesktopLook = true }, 20, BubbleStyle.Tinted));
    }

    [Fact]
    public void TheChatBubblesRowReadsItsValueForTheLookInUse()
    {
        Assert.Null(AppearanceWalkProof.BubblesRowReads(ThemeState.Default with { BubbleStyle = BubbleStyle.Tinted }, "Chat Bubbles, Tinted"));
        Assert.Null(AppearanceWalkProof.BubblesRowReads(ThemeState.Default with { DesktopLook = true }, "Chat Bubbles, 4 pt"));
        Assert.Equal("the Chat Bubbles row reads “Chat Bubbles, Solid”, not “Chat Bubbles, 4 pt”",
            AppearanceWalkProof.BubblesRowReads(ThemeState.Default with { DesktopLook = true }, "Chat Bubbles, Solid"));
    }

    // ------------------------------------------------------------------ Density

    [Fact]
    public void SidebarRowsMustBeAtCompactsHeights()
    {
        var z = DensitySizes.Sidebar(compact: true);
        var standard = DensitySizes.Sidebar(compact: false);
        Assert.NotEqual(standard.BotRow, z.BotRow);
        Assert.NotEqual(standard.PlaceRow, z.PlaceRow);
        List<(AppearanceWalkProof.SidebarRow, double)> rows =
        [
            (AppearanceWalkProof.SidebarRow.Other, 0), (AppearanceWalkProof.SidebarRow.Bot, z.BotRow), (AppearanceWalkProof.SidebarRow.Chat, z.ChatRow),
            (AppearanceWalkProof.SidebarRow.Room, z.BotRow), (AppearanceWalkProof.SidebarRow.Place, z.PlaceRow),
        ];
        Assert.Null(AppearanceWalkProof.SidebarRowsAt(rows, z));
        // Still at Standard: the bot row says so.
        Assert.Equal($"a bot row is {standard.BotRow:0.#} tall, not {z.BotRow:0.#}",
            AppearanceWalkProof.SidebarRowsAt([(AppearanceWalkProof.SidebarRow.Bot, standard.BotRow), (AppearanceWalkProof.SidebarRow.Place, z.PlaceRow)], z));
        Assert.Equal($"a place row is {standard.PlaceRow:0.#} tall, not {z.PlaceRow:0.#}",
            AppearanceWalkProof.SidebarRowsAt([(AppearanceWalkProof.SidebarRow.Bot, z.BotRow), (AppearanceWalkProof.SidebarRow.Place, standard.PlaceRow)], z));
        Assert.Equal("the sidebar shows no bot", AppearanceWalkProof.SidebarRowsAt([(AppearanceWalkProof.SidebarRow.Place, z.PlaceRow)], z));
        Assert.Equal("the sidebar shows no place", AppearanceWalkProof.SidebarRowsAt([(AppearanceWalkProof.SidebarRow.Bot, z.BotRow)], z));
    }

    [Fact]
    public void SessionsChatRowsMustBeAtCompactsHeightAndPadding()
    {
        var z = DensitySizes.Sessions(compact: true);
        var standard = DensitySizes.Sessions(compact: false);
        Assert.Null(AppearanceWalkProof.SessionRowsAt([(z.Row, z.Pad), (z.Row, z.Pad)], z));
        Assert.Equal($"a chat row is {standard.Row:0.#} tall, not {z.Row:0.#}", AppearanceWalkProof.SessionRowsAt([(standard.Row, z.Pad)], z));
        Assert.Equal($"a chat row has {standard.Pad:0.#} over its words, not {z.Pad:0.#}", AppearanceWalkProof.SessionRowsAt([(z.Row, standard.Pad)], z));
        Assert.Equal("Sessions shows no chat", AppearanceWalkProof.SessionRowsAt([], z));
    }

    // ------------------------------------------------------------------ the Sidebar page

    private static readonly List<PlaceInfo> Places =
    [
        new("sessions", "Sessions", false), new("jobs", "Jobs", false), new("artifacts", "Artifacts", false),
        new("tasks", "Tasks", true), new("files", "Files", true), new("settings", "Settings", true),
    ];

    [Fact]
    public void ASwitchTurnedOnThenMoveUpThenUseDefaultTabs()
    {
        // As the walk drives SidebarLayout through the page: the first Add to Sidebar row on, Move Up, Use Default Tabs.
        var layout = new SidebarLayout();
        var start = layout.Shown(Places);
        Assert.Null(AppearanceWalkProof.UseDefaultShown(layout.IsDefault(Places), shown: false));
        var add = layout.AddRows(Places)[0].Id;
        layout.Add(add, Places);
        var added = layout.Shown(Places);
        Assert.Null(AppearanceWalkProof.Added(start, added, add));
        layout.Move(add, -1, Places);
        Assert.Null(AppearanceWalkProof.MovedUp(added, layout.Shown(Places), add));
        Assert.Equal(["sessions", "jobs", "tasks", "artifacts"], layout.Shown(Places));
        Assert.Null(AppearanceWalkProof.UseDefaultShown(layout.IsDefault(Places), shown: true));
        layout.UseDefault();
        Assert.Null(AppearanceWalkProof.UseDefaultShown(layout.IsDefault(Places), shown: false));
    }

    [Fact]
    public void TheSidebarChecksSayWhatIsWrong()
    {
        string[] start = ["sessions", "jobs", "artifacts"];
        Assert.Equal("the sidebar after turning tasks on shows sessions, jobs, artifacts, not sessions, jobs, artifacts, tasks",
            AppearanceWalkProof.Added(start, start, "tasks"));
        Assert.Equal("jobs was in the sidebar already", AppearanceWalkProof.Added(start, start, "jobs"));
        Assert.Equal("the sidebar after Move Up on artifacts shows sessions, jobs, artifacts, not sessions, artifacts, jobs",
            AppearanceWalkProof.MovedUp(start, start, "artifacts"));
        Assert.Equal("sessions can't move up from the top", AppearanceWalkProof.MovedUp(start, start, "sessions"));
        Assert.Equal("tasks can't move up from outside the sidebar", AppearanceWalkProof.MovedUp(start, start, "tasks"));
        Assert.Equal("Use Default Tabs shows with the default places", AppearanceWalkProof.UseDefaultShown(isDefault: true, shown: true));
        Assert.Equal("no Use Default Tabs with the places changed", AppearanceWalkProof.UseDefaultShown(isDefault: false, shown: false));
    }

    // ------------------------------------------------------------------ Capabilities › Skills

    [Fact]
    public void SkillRowsMustBeOneLineCutAtTheTail()
    {
        var lines = CapabilitiesWords.SkillLineLines(1.0);
        Assert.Equal(1, lines);
        var rows = AppearanceWalkProof.StandInSkills.Select(n => (n, 1, true)).ToList();
        Assert.Null(AppearanceWalkProof.SkillRowsOneLine(rows, AppearanceWalkProof.StandInSkills, lines));
        // The old two lines (Kit.Row's default) fail, as does a missing row or a line not cut.
        var two = AppearanceWalkProof.StandInSkills.Select(n => (n, 2, true)).ToList();
        Assert.Equal("web-search's line takes 2 lines, not 1", AppearanceWalkProof.SkillRowsOneLine(two, AppearanceWalkProof.StandInSkills, lines));
        Assert.Equal("Skills has no row for calendar", AppearanceWalkProof.SkillRowsOneLine(rows[..^1], AppearanceWalkProof.StandInSkills, lines));
        Assert.Equal("web-search's line isn't cut at its tail",
            AppearanceWalkProof.SkillRowsOneLine([.. rows.Select((r, i) => i == 0 ? (r.n, 1, false) : r)], AppearanceWalkProof.StandInSkills, lines));
        // At 150 % text, the rows wrap (no limit).
        Assert.Null(AppearanceWalkProof.SkillRowsOneLine([.. rows.Select(r => (r.n, 0, true))], AppearanceWalkProof.StandInSkills, CapabilitiesWords.SkillLineLines(1.5)));
    }

    // ------------------------------------------------------------------ wiring

    private static string WindowsDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln")))
                return Path.Combine(dir.FullName, "windows");
        throw new InvalidOperationException("repo root not found");
    }

    private static string Read(params string[] parts) => File.ReadAllText(Path.Combine([WindowsDir(), .. parts])).Replace("\r\n", "\n");

    [Fact]
    public void TheStandInStillServesTheSkillsTheWalkExpects()
    {
        var gateway = Read("ci", "fixtures", "settings-gateway.py");
        var start = gateway.IndexOf("def default_skills():", StringComparison.Ordinal);
        Assert.True(start >= 0, "settings-gateway.py has no default_skills");
        var end = gateway.IndexOf("'official':", start, StringComparison.Ordinal);
        var installed = Regex.Matches(gateway[start..end], @"\{'name': '([^']+)'").Select(m => m.Groups[1].Value).ToList();
        Assert.Equal(AppearanceWalkProof.StandInSkills, installed);
        // A chat Sessions lists (not a Bot Chat) and every bot's skills.
        Assert.Contains("trip['title'] = 'Trip ideas'", gateway);
        Assert.Contains("skills[name] = default_skills()", gateway);
    }

    [Fact]
    public void WindowsYmlAsksForTheWalkAndItsPicturesOnTheSettingsStandIn()
    {
        var yml = Read("ci", "windows.yml");
        var entries = Regex.Matches(yml, @"@\{ tag = ""(?<tag>[^""]+)""; args = @\((?<args>[^)]*)\);(?<rest>[^\n]*)\}")
            .Where(m => m.Groups["rest"].Value.Contains($"\"{AppearanceWalkProof.Walk}\"")).ToList();
        var entry = Assert.Single(entries);
        Assert.Equal("settings", entry.Groups["tag"].Value);
        Assert.Contains("windows/ci/fixtures/settings-gateway.py", entry.Groups["args"].Value);
        var shots = Regex.Match(entry.Groups["rest"].Value, @"shots = @\((?<s>[^)]*)\)").Groups["s"].Value;
        foreach (var shot in AppearanceWalkProof.Shots) Assert.Contains($"\"{shot}\"", shots);
    }

    [Fact]
    public void TheAppRegistersTheWalkAndTakesEveryPicture()
    {
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.Appearance.cs");
        Assert.Contains($"Automation.NamedWalks[\"{AppearanceWalkProof.Walk}\"] = AppearancePagesAsync", walk);
        Assert.Contains($"shot(\"{AppearanceWalkProof.Walk}\")", walk);
        foreach (var shot in AppearanceWalkProof.Shots) Assert.Contains($"shot(\"{shot}\")", walk);
        Assert.Contains("RegisterAppearanceWalks();", Read("src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));
        // Driven through the app's own controls: no keys or pointer sent from the OS.
        Assert.DoesNotContain("Keys.Press", walk);
        Assert.DoesNotContain("Mouse.Click", walk);
        Assert.DoesNotContain("SendInput", walk);
        // The Sidebar row's menu opens in the Settings window: its items are looked for among that window's popups
        // (CI run 45084955836 timed out reading the main window's).
        Assert.Contains("MenuItemIn(item.XamlRoot, \"Move Up\")", walk);
        // Everything it changes is put back, whatever happened, and checked.
        Assert.Contains("PutBackAsync(shell, prefs, sidebarFile, wasFolded)", walk);
        Assert.Contains("AppearanceWalkProof.Restored(", walk);
    }
}
